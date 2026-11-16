## A network drive that is slow, stops answering or goes away, through the
## file-system seam (`tests/utils/faultyfs`): a folder whose listing hangs, a
## file whose open hangs, a read that hangs and a drive that fails mid-read
## each leave every call the UI thread makes quick, another file can be shown
## meanwhile, a cancel is taken at once, the quit ends within a second (the
## settings' folder hung too: the quit says they were not written), and
## nothing the UI thread calls reaches the file system. The same for the
## Headers window: its reader's read of a trace header that hangs is said
## not to answer while another file's trace is read meanwhile (its late
## answer dropped), one that fails says why; the file's own headers, read
## with its open, leave the file open without them when the drive fails, and
## hold the open (said, cancelled) when it hangs.
##
## An agent's `headers` call reads the trace on a job too, and is told when
## the drive does not answer.
##
## Seen to fail: with the watch's `dirExists` back under its lock,
## `watchStatsOutsideItsLock` found `watchOpen` held as long as the stat hung
## (60 s, the fault's limit); with `tend` not called from `drainInbox`,
## `aHungOpenIsLeft` never showed the second file (the lane stayed with the
## hung open). With the stuck Headers reader not left for a new one
## (`leave` taken out of `followInspect`), `aHungHeaderRead` found "another
## file's trace is not read meanwhile"; with its header reads not marked
## (`fs.mappedRead` taken out of `serve`), "the header read hangs" never came.
## With the disk thread waited for up to its 5 s limit whatever it does (no
## bound on one write), "the quit took 4 seconds, 922 milliseconds...".
##
## Under ThreadSanitizer only thread leaks are reported: the threads left in
## the hung drive, by design.
##
## Runs alone: it bounds the time the UI thread's calls take (50 ms) and the
## quit (1.5 s).

import std/[monotimes, os, strutils, times]
import viewSEG/core/[inbox, state, watch]
import viewSEG/remote/tools
import utils/[faultyfs, fixtures, owntime, waiting]

const Budget = initDuration(milliseconds = 50) ## a frame's work, at most

template quick(body: untyped): Duration =
  ## How long `body` took.
  let t0 = ownTime()
  body
  ownTime() - t0

func has(log: MessageLog; part: string; severity = sevInfo): bool =
  for e in log:
    if part in e.text and e.severity == severity: return true
  false

proc main(st: AppState): lent Panel = st.panel(MainPanel)

proc tilesOf(st: AppState): int = st.tiles(st.findPanel(MainPanel)).len

proc shownPath(st: AppState): string =
  let i = st.shownFile(st.findPanel(MainPanel))
  if i >= 0: st.sessions[i].path else: ""

proc idOf(st: AppState; path: string; index: int): int =
  ## The survey-wide id of trace `index` of open file `path`.
  for s in st.sessions:
    if s.path == path: return s.base + index
  -1

proc select(st: var AppState; path: string; index: int) =
  st.apply Command(kind: ckSelect, traces: @[st.idOf(path, index)], mode: smReplace)

proc look(st: var AppState; first, last: float64) =
  var v = fitAll(st.main.layout, 800, 600)
  v.traces = Span(lo: first - 0.5, hi: last + 0.5)
  st.apply Command(kind: ckView, panel: MainPanel, view: v)

proc silent() =
  ## As much time on the seam's clock as a drive that stopped answering
  ## takes to be said not to answer.
  advanceFsClock(StallAfter + initDuration(seconds = 1))

install()

withFixtures fx:
  let far = fx.dir / "far" # the network drive
  let near = fx.dir / "near" # a local disk
  createDir(far)
  createDir(near)
  let survey = fx.surveySegy
  copyFile(survey, far / "a.sgy")
  copyFile(fx.wideShotSegy, far / "c.sgy") # 2000 traces: views apart need reads of their own
  copyFile(survey, near / "b.sgy")

  block watchStatsOutsideItsLock:
    # A new listing makes the watch stat its folder: a folder that does not
    # answer must not hold the lock the UI thread takes in `watchOpen`.
    var st = initAppState() # (marks this thread the UI thread)
    let box = initInbox()
    var w = newFolderWatch(box.poster, initDuration(milliseconds = 10))
    fault(far, fkHang, {foStat, foList})
    w.watch(1, @[far], @[])
    doAssert waitUntil(hung() >= 1), "the watch's stat hangs"
    let t = quick: w.watchOpen(@[far / "a.sgy"])
    doAssert t < Budget, "watchOpen waited " & $t & " for a stat"
    doAssert w.lookingFor() > initDuration(), "a look under way"
    let s = quick: w.stop(getMonoTime() + initDuration(milliseconds = 300))
    doAssert s < initDuration(seconds = 1), "stop waited " & $s
    release(far)
    doAssert waitUntil(hung() == 0)
    st.shutdown()

  block aHungOpenIsLeft:
    # The open of a file on the drive hangs; the user picks a local file:
    # it is shown, and the hung open's late file is dropped.
    var st = initAppState(watchEvery = initDuration(milliseconds = 20))
    fault(far / "a.sgy", fkHang, {foStat})
    var t = quick: st.apply Command(kind: ckShowFile, panel: MainPanel, path: far / "a.sgy")
    doAssert t < Budget
    doAssert waitUntil(hung() == 1), "the open hangs"
    silent()
    var stuck = NoJob
    for j in st.jobs.active:
      if "a.sgy" in j.spec.title: stuck = j.id
    doAssert st.jobs.info(stuck).get.notAnsweringFor > initDuration(), "said not to answer"
    t = quick: st.apply Command(kind: ckShowFile, panel: MainPanel, path: near / "b.sgy")
    doAssert t < Budget
    var worst = initDuration()
    doAssert waitUntil((block:
      let d = quick: discard st.drainInbox()
      worst = max(worst, d)
      st.shownPath == near / "b.sgy" and st.main.laidOut)), "the local file is shown"
    doAssert worst < Budget, "a frame's inbox took " & $worst
    doAssert st.jobs.info(stuck).get.state == jsCancelled and st.jobs.info(stuck).get.abandoned
    # The drive answers again: the open comes back late and is dropped.
    release(far / "a.sgy")
    doAssert waitUntil(hung() == 0)
    sleep 100
    discard st.drainInbox()
    doAssert st.shownPath == near / "b.sgy"
    doAssert st.sessions.len == 1, "the late open is dropped: " & $st.sessions.len
    doAssert not st.log.has("Opened a.sgy")
    st.shutdown()

  block aHungListing:
    # Listing the drive's folder hangs: the listing says it does not answer,
    # cancel takes it out, and another folder lists meanwhile.
    var st = initAppState(watchEvery = initDuration(milliseconds = 20))
    fault(far, fkHang, {foList})
    st.apply Command(kind: ckBrowse, paths: @[far])
    doAssert waitUntil(hung() == 1), "the listing hangs"
    let scan = st.fileList.job
    silent()
    doAssert st.jobs.info(scan).get.notAnsweringFor > initDuration()
    let t = quick: st.apply Command(kind: ckCancelJob, job: scan)
    doAssert t < Budget
    doAssert st.settle(not st.fileList.scanning), "cancel takes the listing out"
    doAssert st.jobs.info(scan).get.state == jsCancelled
    st.apply Command(kind: ckBrowse, paths: @[near])
    doAssert st.settle(not st.fileList.scanning and st.fileList.entries.len == 1),
      "another folder lists meanwhile"
    release(far)
    doAssert waitUntil(hung() == 0)
    st.shutdown()

  block aDriveThatFails:
    # A file is shown, then its drive goes away: nothing more is read of it,
    # the plot keeps what it showed, and the log says why.
    var st = initAppState(watchEvery = initDuration(seconds = 30))
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: far / "c.sgy")
    doAssert st.settle(st.main.laidOut)
    st.look(0, 99)
    doAssert st.settle(st.tilesOf > 0)
    fault(far, fkFail)
    st.look(1000, 1099)
    doAssert st.settle(st.log.has("c.sgy cannot be read now", sevWarning))
    doAssert st.tilesOf > 0, "the plot keeps its tiles"
    # A read that fails in the map itself: the reader says so and goes on.
    release(far)
    fault(far, fkFail, {foMapped})
    st.look(1500, 1599)
    doAssert st.settle(st.log.has("Cannot read c.sgy", sevError))
    release(far)
    st.look(600, 699)
    let before = st.tilesTaken
    doAssert st.settle(st.tilesTaken > before), "read again once the drive is back"
    st.shutdown()

  block aHungHeaderRead:
    # The Headers window's reader hangs on a trace header of the drive's
    # file: said not to answer; a trace of a local file is read meanwhile by
    # a new reader; the old one's late answer is dropped.
    var st = initAppState(watchEvery = initDuration(seconds = 30))
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: far / "a.sgy")
    doAssert st.settle(st.main.laidOut)
    st.apply Command(kind: ckOpen, paths: @[near / "b.sgy"])
    doAssert st.settle(st.sessions.len == 2)
    st.apply Command(kind: ckInspect, inspect: {ipTraceHeaders})
    fault(far / "a.sgy", fkHang, {foHeaders})
    var t = quick: st.select(far / "a.sgy", 2)
    doAssert t < Budget
    doAssert waitUntil(hung() == 1), "the header read hangs"
    doAssert st.headersWait.kind == wkNone, "said not to answer at once"
    silent()
    let w = st.headersWait
    doAssert w.kind == wkHeaders and w.path == far / "a.sgy" and
      "a.sgy for the Headers window: not answering for" in w.words, $w
    let b = st.idOf(near / "b.sgy", 4)
    t = quick: st.select(near / "b.sgy", 4)
    doAssert t < Budget
    var worst = initDuration()
    doAssert waitUntil((block:
      let d = quick: discard st.drainInbox()
      worst = max(worst, d)
      st.inspection.answer.traces.len == 1 and st.inspection.answer.traces[0].id == b and
        st.inspection.answer.traces[0].rows.len > 0)),
      "another file's trace is not read meanwhile"
    doAssert worst < Budget, "a frame's inbox took " & $worst
    doAssert st.headersWait.kind == wkNone, "the new reader answers"
    release(far / "a.sgy")
    doAssert waitUntil(hung() == 0)
    sleep 100
    discard st.drainInbox()
    doAssert st.inspection.answer.traces[0].id == b, "the late answer is dropped"
    doAssert st.shutdown(), "the reader left in the drive has ended"

  block aFailingHeaderRead:
    # The drive fails the reads of a trace's header and samples: the answer
    # says why, and the next trace is read once the drive is back.
    var st = initAppState(watchEvery = initDuration(seconds = 30))
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: far / "a.sgy")
    doAssert st.settle(st.main.laidOut)
    st.apply Command(kind: ckInspect, inspect: {ipTraceHeaders, ipTraceSamples})
    fault(far / "a.sgy", fkFail, {foHeaders, foMapped})
    st.select(far / "a.sgy", 3)
    doAssert st.settle(not st.inspection.waiting and st.inspection.answer.traces.len == 1)
    let d = st.inspection.answer.traces[0]
    doAssert d.rows.len == 0 and d.samples.len == 0 and
      "cannot be read now" in d.problem and "drive went away or fails" in d.problem, d.problem
    release(far / "a.sgy")
    st.select(far / "a.sgy", 4)
    doAssert st.settle(not st.inspection.waiting and st.inspection.answer.traces.len == 1 and
      st.inspection.answer.traces[0].rows.len > 0 and
      st.inspection.answer.traces[0].problem.len == 0), "read once the drive is back"
    st.shutdown()

  block theOpensHeaderReads:
    # The file's own headers (its textual and binary headers, for the
    # Headers window) are read with its open: a drive that fails them leaves
    # the file open without them, and the Summary says why; one that hangs
    # holds the open, which is said not to answer and is cancelled.
    var st = initAppState(watchEvery = initDuration(seconds = 30))
    fault(far / "a.sgy", fkFail, {foHeaders})
    st.apply Command(kind: ckOpen, paths: @[far / "a.sgy"])
    doAssert st.settle(st.sessions.len == 1), "the file is opened"
    let f = st.sessions[0].facts
    doAssert f.text.len == 0 and f.rows.len == 0 and f.summary.traceCount > 0, $f.summary
    doAssert f.problems.len == 1 and "headers cannot be read now" in f.problems[0], $f.problems
    release(far / "a.sgy")
    st.shutdown()
    var again = initAppState(watchEvery = initDuration(seconds = 30))
    fault(far / "a.sgy", fkHang, {foHeaders})
    let t = quick: again.apply Command(kind: ckOpen, paths: @[far / "a.sgy"])
    doAssert t < Budget
    doAssert waitUntil(hung() == 1), "the open's header read hangs"
    silent()
    var stuck = NoJob
    for j in again.jobs.active:
      if "a.sgy" in j.spec.title: stuck = j.id
    doAssert stuck != NoJob and again.jobs.info(stuck).get.notAnsweringFor > initDuration()
    let c = quick: again.apply Command(kind: ckCancelJob, job: stuck)
    doAssert c < Budget
    doAssert again.settle(again.jobs.info(stuck).get.state == jsCancelled)
    release(far / "a.sgy")
    doAssert waitUntil(hung() == 0)
    sleep 100
    discard again.drainInbox()
    doAssert again.sessions.len == 0, "the cancelled open is dropped"
    again.shutdown()

  block anAgentAsksForHeaders:
    # An agent asks for a trace's headers while the file's drive does not
    # answer: the map is read on a job, never on the UI thread, every call
    # stays quick, and the agent is told the drive does not answer; once it
    # answers, the headers come.
    var st = initAppState(watchEvery = initDuration(seconds = 30))
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: far / "a.sgy")
    doAssert st.settle(st.main.laidOut)
    let args = """{"file":""" & $int(st.sessions[0].id) & ""","index":3}"""
    fault(far, fkHang, {foHeaders})
    var ask: HeaderCall
    var t = quick: ask = st.askTraceHeaders(args)
    doAssert t < Budget, "the call took " & $t
    doAssert ask.answer.len == 0, "answered at once, so read on the UI thread: " & ask.answer
    doAssert waitUntil(hung() == 1), "the trace's read hangs, on a job"
    t = quick: discard st.headersAnswer(ask)
    doAssert t < Budget and ask.answer.len == 0
    silent()
    doAssert st.settle(st.headersAnswer(ask))
    doAssert "\"isError\":true" in ask.answer and "has not answered for" in ask.answer,
      ask.answer
    release(far)
    doAssert waitUntil(hung() == 0)
    var again = st.askTraceHeaders(args)
    doAssert st.settle(st.headersAnswer(again))
    doAssert "\"isError\":true" notin again.answer and "\\\"headers\\\":[{" in again.answer,
      again.answer.substr(0, 300)
    st.shutdown()

  block quitWithin:
    # Everything hangs at once: an open, a read, the listing, the watch and
    # the folder the settings go to. The quit ends within a second.
    let config = fx.dir / "config"
    createDir(config)
    var st = initAppState(watchEvery = initDuration(milliseconds = 20))
    st.keepSettingsIn(config, LoadedSettings(saveable: true))
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: far / "c.sgy")
    doAssert st.settle(st.main.laidOut)
    st.apply Command(kind: ckBrowse, paths: @[near])
    doAssert st.settle(not st.fileList.scanning)
    fault(far, fkHang)
    fault(near, fkHang, {foStat, foList})
    fault(config, fkHang)
    st.look(1000, 1099) # the reader's stat hangs
    st.apply Command(kind: ckOpen, paths: @[far / "a.sgy"]) # the open hangs
    st.apply Command(kind: ckInspect, inspect: {ipTraceHeaders})
    st.select(far / "c.sgy", 5) # the Headers window's reader hangs
    var s = st.settings
    s.theme = "changed"
    st.apply Command(kind: ckSettings, settings: s)
    doAssert waitUntil(hung() >= 4), "the read, the open, the Headers window's reader and " &
      "the watch hang: " & $hung()
    let t = quick:
      let ended = st.shutdown()
      doAssert not ended, "something was left"
    echo "quit with an open, a read, the Headers window's reader and the watch hung: ",
      t.inMilliseconds, " ms"
    doAssert t < initDuration(milliseconds = 1500), "the quit took " & $t
    var said = false # what was not written
    for e in st.log:
      if "Quit without waiting longer" in e.text and "the settings" in e.text: said = true
    doAssert said, "the settings not written, not said"
    releaseAll() # the stuck threads come back and end on their own
    doAssert waitUntil(hung() == 0)
    sleep 50

  block noUiCalls:
    doAssert uiCalls().len == 0, "the UI thread called the file system:\n" &
      uiCalls().join("\n")

echo "tnetwork: ok"
