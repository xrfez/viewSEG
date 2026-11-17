## The thread guards: a worker-only proc called on the UI thread fails at
## once, naming its call site; a UI-only check fails on a worker; threads
## nobody marked pass the worker check. Release builds compile the guards
## out (unless `-d:threadGuards`), and the same calls then simply run.
##
## And handing a file to another thread: opening one on a worker leaves
## parseSEG's objects on that thread's ORC list of possible cycles;
## `clearCycleRoots` empties the list, so the file can be released on the
## thread it was handed to.
##
## Seen to fail: with `assertWorkerThread()` taken out of `openSession`,
## `workerOnlyOnUi` opened the file on the UI thread without complaint; with
## `clearCycleRoots` doing nothing, `handOverAfterOpen` found the list still
## full, and under `nim asan` releasing the file on the main thread wrote
## outside the main thread's list (heap-buffer-overflow).
##
## A caught exception can stay on ORC's list of possible cycles; the test
## empties the list (`clearCycleRoots`) so `nim asan` reports no leak.

import std/[atomics, strutils]
import parseSEG
import viewSEG/core/[filejobs, inbox, jobs, session, threads]
import utils/fixtures

var
  failedOnWorker: Atomic[bool]
  listedAfterOpen, listedAfterClear: Atomic[int]

proc uiCheckOnWorker() {.thread.} =
  markWorkerThread()
  try:
    assertUiThread()
  except AssertionDefect:
    failedOnWorker.store(true)
  clearCycleRoots() # the caught exception, before the thread ends

proc workerCheckUnmarked() {.thread.} =
  assertWorkerThread() # an unmarked thread may do worker things
  doAssert threadRole() == trUnknown

proc openAndHandOver(arg: (string, Poster)) {.thread.} =
  markWorkerThread()
  var s = openSession(arg[0])
  when defined(gcOrc):
    listedAfterOpen.store(GC_prepareOrc())
  clearCycleRoots()
  when defined(gcOrc):
    listedAfterClear.store(GC_prepareOrc())
  arg[1].post Msg(job: NoJob, kind: mkOpened, session: move s)

proc main*() =

  block workerOnlyOnUi:
    withFixtures fx:
      let path = fx.surveySegy()
      markUiThread()
      doAssert threadRole() == trUi
      when ThreadGuards:
        var message = ""
        try:
          discard openSession(path)
        except AssertionDefect as e:
          message = e.msg
        clearCycleRoots()
        doAssert "filejobs.nim(" in message and "off the UI thread" in message and
          "marked UI" in message, message
      else:
        doAssert openSession(path).len > 0 # compiled out: it just runs
      markWorkerThread()
      let s = openSession(path) # on a worker it is fine
      doAssert s.len > 0
      s.filePtr[].close()

  block uiOnlyOnWorker:
    var t: Thread[void]
    createThread(t, uiCheckOnWorker)
    joinThread(t)
    doAssert failedOnWorker.load == ThreadGuards

  block handOverAfterOpen:
    withFixtures fx:
      let box = initInbox()
      var t: Thread[(string, Poster)]
      createThread(t, openAndHandOver, (fx.surveySegy(), box.poster))
      joinThread(t)
      var mail: seq[Msg]
      box.drainInto(mail)
      doAssert mail.len == 1 and mail[0].session.len == SurveyTraces
      when defined(gcOrc):
        if listedAfterOpen.load == 0:
          echo "tthreadguards: opening listed no possible cycles any more"
        doAssert listedAfterClear.load == 0, "the worker still lists " &
          $listedAfterClear.load & " objects it handed over"
      mail.setLen 0 # the file is released here, on the main thread

  block unmarked:
    var t: Thread[void]
    createThread(t, workerCheckUnmarked)
    joinThread(t)

when isMainModule:
  main()
