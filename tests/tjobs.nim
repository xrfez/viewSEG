## The two job lanes, with fake jobs held at gates so every interleaving is
## the one the test means: a slow background job does not delay an
## interactive one; queued jobs run in order and can be reordered, removed
## and cancelled; a running job sees its cancel; files a job needs to itself
## hold back the jobs that use them, and only those; progress, failures,
## the history limit and `stop`.
##
## Seen to fail: with `submit` queueing every job in the interactive lane,
## `backgroundDoesNotDelayInteractive` timed out ("the interactive job
## waited"); with the runner's `broadcast` after a job finished removed,
## `exclusiveWaitsForReaders` timed out (the interactive runner slept through
## the release of the file); with the `broadcast` of `remove`, of `reorder`
## or of `cancel` removed, `unblockingWakesTheRunner` timed out ("... left
## the runner asleep"); with `cancel` leaving a queued job in its queue,
## `cancelQueuedAndRunning` found it still queued; with `cancel` and `remove`
## not checking `cancellable`, `notCancellable` cancelled a job that must
## run; with `shutdown` no longer marking running jobs as cancelled, or no
## longer joining the runners, `destroyStopsRunningJobs` found that the job
## had not seen its cancel (its earlier form, which only checked that the
## job never finished its work, passed both ways); with `pick` not looking
## at holds, `holdsKeepExclusiveJobsWaiting` found the close run while the
## file was held ("a job had a held file to itself"), and with `release` not
## broadcasting, it timed out ("the last release left the runner asleep").
## With `hold` looking at the queued and running jobs only,
## `anAbandonedJobKeepsReadersOut` let a reader hold the file while the
## abandoned job's work still ran ("a reader let in ..."). With the runner
## telling an abandoned job by the files it held, `anAbandonedJobThatNamesNoFile`
## found it "listed as finished twice" (done, after it was said cancelled),
## and, its record removed, the runner ended the program ("index -1 not in
## 0 .. 1", IndexDefect).

import std/[atomics, monotimes, os, sequtils, strutils, times]
import viewSEG/core/[jobs, threads]
import utils/waiting

var
  gates: array[8, Gate]
  ran: array[16, Atomic[int]]   ## how often fake job `slot` ran
  order: array[16, Atomic[int]] ## the slots in the order they ran
  orderLen: Atomic[int]
  workerRole: Atomic[int]

proc reset() =
  for g in gates.mitems: g.close()
  for r in ran.mitems: r.store(0)
  orderLen.store(0)

proc fake(slot: int; gate = -1): JobWork =
  ## A job that waits at `gate` (if any), then records that it ran.
  result = proc (ctx: JobContext) {.gcsafe.} =
    workerRole.store(ord(threadRole()))
    if gate >= 0: gates[gate].waitAt(ctx)
    ran[slot].atomicInc
    order[orderLen.fetchAdd(1)].store(slot)

proc spec(title: string; lane = jlInteractive; reads: seq[string] = @[];
    exclusive: seq[string] = @[]): JobSpec =
  JobSpec(title: title, lane: lane, reads: reads, exclusive: exclusive)

proc state(jobs: Jobs; id: JobId): JobState =
  jobs.info(id).get.state

proc ranInOrder(): seq[int] =
  for i in 0 ..< orderLen.load: result.add order[i].load

proc stubborn(slot, gate: int): JobWork =
  ## A job that no cancel reaches (a listing held by a folder that does not
  ## answer), until `gate` opens.
  result = proc (ctx: JobContext) {.gcsafe.} =
    let deadline = getMonoTime() + Patience * 2
    while not gates[gate].isOpen and getMonoTime() < deadline: sleep 1
    ran[slot].atomicInc

proc main*() =

  block backgroundDoesNotDelayInteractive:
    reset()
    let jobs = initJobs()
    let slow = jobs.submit(spec("Scan the folder", jlBackground), fake(0, gate = 0))
    doAssert waitUntil(jobs.state(slow) == jsRunning)
    let quick = jobs.submit(spec("Open a file"), fake(1))
    doAssert waitUntil(jobs.state(quick) == jsDone), "the interactive job waited"
    doAssert jobs.state(slow) == jsRunning
    doAssert workerRole.load == ord(trWorker), "a runner is not marked as a worker"
    gates[0].open()
    doAssert waitUntil(jobs.state(slow) == jsDone)

  block orderReorderRemove:
    reset()
    let jobs = initJobs()
    let blocker = jobs.submit(spec("Blocker"), fake(0, gate = 1))
    doAssert waitUntil(jobs.state(blocker) == jsRunning)
    let a = jobs.submit(spec("A"), fake(1))
    let b = jobs.submit(spec("B"), fake(2))
    let c = jobs.submit(spec("C"), fake(3))
    doAssert jobs.queued(jlInteractive) == @[a, b, c]
    doAssert jobs.reorder(c, 0)
    doAssert jobs.queued(jlInteractive) == @[c, a, b]
    doAssert jobs.reorder(a, 99) # clamped: last
    doAssert jobs.queued(jlInteractive) == @[c, b, a]
    doAssert jobs.remove(b)
    doAssert jobs.queued(jlInteractive) == @[c, a]
    doAssert jobs.info(b).isNone
    doAssert not jobs.remove(blocker), "a running job was removed"
    doAssert not jobs.reorder(blocker, 0), "a running job was reordered"
    doAssert jobs.queued(jlBackground).len == 0
    gates[1].open()
    doAssert waitUntil(jobs.state(a) == jsDone)
    doAssert ranInOrder() == @[0, 3, 1]
    doAssert ran[2].load == 0, "a removed job ran"
    doAssert jobs.remove(a) and jobs.info(a).isNone, "a finished job could not be removed"
    doAssert not jobs.remove(b) and not jobs.cancel(b), "an unknown job was found"

  block cancelQueuedAndRunning:
    reset()
    let jobs = initJobs()
    let running = jobs.submit(spec("Runs until cancelled"), fake(0, gate = 2))
    doAssert waitUntil(jobs.state(running) == jsRunning)
    let queued = jobs.submit(spec("Never runs"), fake(1))
    doAssert jobs.cancel(queued)
    doAssert jobs.state(queued) == jsCancelled, "a queued job is cancelled at once"
    doAssert jobs.queued(jlInteractive).len == 0
    doAssert jobs.cancel(running)
    doAssert waitUntil(jobs.state(running) == jsCancelled)
    doAssert jobs.info(running).get.cancelRequested
    doAssert not jobs.cancel(running), "a finished job was cancelled"
    doAssert ran[0].load == 0 and ran[1].load == 0
    # The next job still runs: the lane is not stuck.
    let after = jobs.submit(spec("After"), fake(2))
    doAssert waitUntil(jobs.state(after) == jsDone)

  block outcomes:
    reset()
    let jobs = initJobs()
    let fails = jobs.submit(spec("Fails"), proc (ctx: JobContext) {.gcsafe.} =
      raise newException(IOError, "the disk went away"))
    doAssert waitUntil(jobs.state(fails) == jsFailed)
    doAssert jobs.info(fails).get.error == "the disk went away"
    # Work that returns after a cancel was asked for is done: its results are in.
    let late = jobs.submit(spec("Ignores the cancel"), proc (ctx: JobContext) {.gcsafe.} =
      gates[3].open()
      discard waitUntil(ctx.cancelled)
      ran[5].atomicInc)
    doAssert waitUntil(gates[3].isOpen)
    doAssert jobs.cancel(late)
    doAssert waitUntil(jobs.state(late) == jsDone)
    # Work that fails after a cancel was asked for was cancelled, not failed.
    gates[3].close()
    let stops = jobs.submit(spec("Stops by raising"), proc (ctx: JobContext) {.gcsafe.} =
      gates[3].open()
      discard waitUntil(ctx.cancelled)
      raise newException(ValueError, "stopped half way"))
    doAssert waitUntil(gates[3].isOpen)
    doAssert jobs.cancel(stops)
    doAssert waitUntil(jobs.state(stops) == jsCancelled)
    doAssert jobs.info(stops).get.error == ""

  block exclusiveWaitsForReaders:
    reset()
    let jobs = initJobs()
    let reader = jobs.submit(spec("QC pass", jlBackground, reads = @["x.sgy"]), fake(0, gate = 4))
    doAssert waitUntil(jobs.state(reader) == jsRunning)
    let join = jobs.submit(spec("Join geometry", exclusive = @["x.sgy"]), fake(1))
    let other = jobs.submit(spec("Open another", reads = @["y.sgy"]), fake(2))
    # `other` was queued after `join` in the same lane, so if `join` could
    # start it would have run first: it is held back, and `other` is not.
    doAssert waitUntil(jobs.state(other) == jsDone)
    doAssert jobs.state(join) == jsQueued, "an exclusive job started beside a reader"
    # A reader of x.sgy queued behind the join waits for it, in order.
    let reread = jobs.submit(spec("Read again", reads = @["x.sgy"]), fake(3))
    doAssert jobs.state(reread) == jsQueued
    gates[4].open()
    doAssert waitUntil(jobs.state(reread) == jsDone)
    doAssert ranInOrder() == @[2, 0, 1, 3]
    # And the reverse: a running exclusive job holds back a reader in the other lane.
    reset()
    let edit = jobs.submit(spec("Edit in place", jlBackground, exclusive = @["x.sgy"]),
      fake(4, gate = 5))
    doAssert waitUntil(jobs.state(edit) == jsRunning)
    let look = jobs.submit(spec("Read", reads = @["x.sgy"]), fake(5))
    let free = jobs.submit(spec("Read y", reads = @["y.sgy"]), fake(6))
    doAssert waitUntil(jobs.state(free) == jsDone)
    doAssert jobs.state(look) == jsQueued
    gates[5].open()
    doAssert waitUntil(jobs.state(look) == jsDone)

  block unblockingWakesTheRunner:
    # The interactive lane holds [A, B]: A needs x.sgy to itself, which a
    # background job reads, so A waits; B reads x.sgy, so it waits behind A.
    # Removing, moving or cancelling A frees B, and the lane's runner, asleep
    # by then, must wake for it.
    for way in ["remove", "reorder", "cancel"]:
      reset()
      let jobs = initJobs()
      let reader = jobs.submit(spec("QC pass", jlBackground, reads = @["x.sgy"]),
        fake(0, gate = 0))
      doAssert waitUntil(jobs.state(reader) == jsRunning)
      let a = jobs.submit(spec("Join", exclusive = @["x.sgy"]), fake(1))
      let b = jobs.submit(spec("Read", reads = @["x.sgy"]), fake(2))
      sleep 5 # let the runner look, find nothing to start, and wait
      doAssert jobs.state(a) == jsQueued and jobs.state(b) == jsQueued
      case way
      of "remove": doAssert jobs.remove(a)
      of "reorder": doAssert jobs.reorder(b, 0)
      else: doAssert jobs.cancel(a)
      doAssert waitUntil(jobs.state(b) == jsDone), way & " left the runner asleep"
      gates[0].open()
      doAssert waitUntil(jobs.state(reader) == jsDone)
      if way == "reorder":
        doAssert waitUntil(jobs.state(a) == jsDone)

  block progressAndRevision:
    reset()
    let jobs = initJobs()
    let rev0 = jobs.revision
    let job = jobs.submit(spec("Index"), proc (ctx: JobContext) {.gcsafe.} =
      ctx.setPhase "reading keys"
      doAssert ctx.progress(5, 10)
      gates[6].waitAt(ctx))
    doAssert waitUntil(jobs.info(job).get.progress.done == 5)
    let p = jobs.info(job).get.progress
    doAssert p.total == 10 and p.phase == "reading keys", $p
    doAssert jobs.revision > rev0
    doAssert jobs.cancel(job)
    doAssert waitUntil(jobs.state(job) == jsCancelled)

  block takeFinishedOnceEach:
    reset()
    let jobs = initJobs()
    let a = jobs.submit(spec("A"), fake(0))
    let b = jobs.submit(spec("B", jlBackground), fake(1))
    doAssert waitUntil(jobs.state(a) == jsDone and jobs.state(b) == jsDone)
    let done = jobs.takeFinished()
    doAssert done.len == 2 and a in [done[0].id, done[1].id] and b in [done[0].id, done[1].id]
    doAssert jobs.takeFinished().len == 0

  block historyLimit:
    reset()
    let jobs = initJobs(historyLimit = 2)
    var ids: seq[JobId]
    for i in 0 ..< 4:
      ids.add jobs.submit(spec("Job " & $i), fake(i))
    doAssert waitUntil(ran[3].load == 1)
    doAssert waitUntil(jobs.list.len == 2)
    let listed = jobs.list
    doAssert listed[0].id == ids[2] and listed[1].id == ids[3], $listed.len

  block stopCancelsAndWaits:
    reset()
    var jobs = initJobs()
    let running = jobs.submit(spec("Long"), fake(0, gate = 7))
    let background = jobs.submit(spec("Longer", jlBackground), fake(1, gate = 7))
    doAssert waitUntil(jobs.state(running) == jsRunning and jobs.state(background) == jsRunning)
    let queued = jobs.submit(spec("Queued"), fake(2))
    jobs.stop() # returns only once both runners have ended
    doAssert jobs.state(running) == jsCancelled
    doAssert jobs.state(background) == jsCancelled
    doAssert jobs.state(queued) == jsCancelled
    doAssert ran[0].load + ran[1].load + ran[2].load == 0
    let late = jobs.submit(spec("Too late"), fake(3))
    doAssert jobs.state(late) == jsCancelled
    doAssert "stopped" in jobs.info(late).get.error
    jobs.stop() # idempotent
    sleep 20
    doAssert ran[3].load == 0

  block notCancellable:
    # A job that must run once submitted (closing a file): `cancel` and
    # `remove` refuse it while it is queued or running, it can still be moved,
    # it can be removed once finished, and `stop` still cancels it.
    reset()
    var jobs = initJobs()
    let blocker = jobs.submit(spec("Blocker"), fake(0, gate = 2))
    doAssert waitUntil(jobs.state(blocker) == jsRunning)
    var barrier = spec("Close x.sgy", exclusive = @["x.sgy"])
    barrier.cancellable = false
    let close = jobs.submit(barrier, fake(1, gate = 3))
    doAssert not jobs.cancel(close), "a job that must run was cancelled while queued"
    doAssert not jobs.remove(close), "a job that must run was removed while queued"
    doAssert jobs.state(close) == jsQueued and not jobs.info(close).get.cancelRequested
    doAssert jobs.reorder(close, 0)
    gates[2].open()
    doAssert waitUntil(jobs.state(close) == jsRunning)
    doAssert not jobs.cancel(close), "a job that must run was asked to stop"
    doAssert not jobs.info(close).get.cancelRequested
    gates[3].open()
    doAssert waitUntil(jobs.state(close) == jsDone)
    doAssert jobs.remove(close), "a finished job could not be removed"
    gates[2].close()
    let again = jobs.submit(spec("Blocker again"), fake(2, gate = 2))
    doAssert waitUntil(jobs.state(again) == jsRunning)
    let queued = jobs.submit(barrier, fake(3))
    jobs.stop()
    doAssert jobs.state(queued) == jsCancelled and ran[3].load == 0

  block holdsKeepExclusiveJobsWaiting:
    # A reader that is not a job (a trace panel's thread) holds the file: a
    # job that needs it to itself (closing it) waits until the hold ends, while
    # the jobs behind it that need not wait run. A hold is refused while such a
    # job is queued or running, so readers cannot keep it waiting for ever.
    reset()
    let jobs = initJobs()
    doAssert jobs.hold("x.sgy") and jobs.hold("x.sgy") # two panels show it
    doAssert jobs.held("x.sgy") == 2
    let close = jobs.submit(spec("Close x.sgy", exclusive = @["x.sgy"]), fake(0))
    let other = jobs.submit(spec("Open y.sgy", reads = @["y.sgy"]), fake(1))
    let reader = jobs.submit(spec("QC pass", jlBackground, reads = @["x.sgy"]), fake(2))
    doAssert waitUntil(jobs.state(other) == jsDone and jobs.state(reader) == jsDone)
    doAssert jobs.state(close) == jsQueued, "a job had a held file to itself"
    doAssert not jobs.hold("x.sgy"), "a hold was taken while a close waited"
    doAssert jobs.hold("y.sgy"), "a hold of another file was refused"
    doAssert jobs.release("x.sgy")
    sleep 5
    doAssert jobs.state(close) == jsQueued, "the close ran while a hold was left"
    doAssert jobs.release("x.sgy")
    doAssert waitUntil(jobs.state(close) == jsDone), "the last release left the runner asleep"
    doAssert not jobs.release("x.sgy"), "a file that was not held was released"
    doAssert jobs.held("x.sgy") == 0 and jobs.held("y.sgy") == 1
    # A running job that has the file to itself refuses holds too.
    let edit = jobs.submit(spec("Edit y.sgy", exclusive = @["z.sgy"]), fake(3, gate = 1))
    doAssert waitUntil(jobs.state(edit) == jsRunning)
    doAssert not jobs.hold("z.sgy")
    gates[1].open()
    doAssert waitUntil(jobs.state(edit) == jsDone)
    doAssert jobs.hold("z.sgy"), "a hold was refused after the job ended"

  var sawCancel: Atomic[bool]

  block anAbandonedJobKeepsReadersOut:
    # A job that needs a file to itself and cannot stop once started (a
    # geometry join's step: parseSEG's `applySurvey` is one call) is cancelled
    # and, still running a second later, abandoned (`tend`): no reader may
    # hold the file until its work is back, for it may still be changing the
    # file's keys.
    reset()
    let jobs = initJobs()
    let job = jobs.submit(spec("join", exclusive = @["f.sgy"]), proc (ctx: JobContext) {.gcsafe.} =
      let deadline = getMonoTime() + Patience * 2
      while not gates[0].isOpen and getMonoTime() < deadline: sleep 1 # no cancel reaches it
      ran[0].atomicInc)
    doAssert waitUntil(jobs.state(job) == jsRunning)
    doAssert not jobs.hold("f.sgy"), "a hold while the job runs"
    doAssert jobs.cancel(job)
    doAssert jobs.tend(getMonoTime() + CancelGrace + initDuration(seconds = 1))
    doAssert jobs.info(job).get.abandoned and jobs.state(job) == jsCancelled
    doAssert not jobs.hold("f.sgy"),
      "a reader let in while the abandoned job's work may still change the file"
    gates[0].open()
    doAssert waitUntil(ran[0].load == 1)
    doAssert waitUntil(jobs.hold("f.sgy")), "no hold once the work is back"
    doAssert jobs.release("f.sgy")

  block anAbandonedJobThatNamesNoFile:
    # A job that names no file (a folder's listing) is cancelled and, still
    # running, abandoned: it is listed cancelled once, also when its work comes
    # back, and also when its record went meanwhile (the Jobs window's remove,
    # or the history's limit).
    reset()
    let jobs = initJobs()
    let job = jobs.submit(spec("List a share"), stubborn(0, 0))
    doAssert waitUntil(jobs.state(job) == jsRunning)
    doAssert jobs.cancel(job)
    doAssert jobs.tend(getMonoTime() + CancelGrace + initDuration(seconds = 1))
    doAssert jobs.info(job).get.abandoned and jobs.state(job) == jsCancelled
    doAssert jobs.workingOn(job), "its work is still out"
    doAssert jobs.takeFinished().countIt(it.id == job) == 1
    gates[0].open()
    doAssert waitUntil(ran[0].load == 1 and not jobs.workingOn(job))
    let after = jobs.submit(spec("Open a file"), fake(2))
    doAssert waitUntil(jobs.state(after) == jsDone)
    doAssert jobs.takeFinished().countIt(it.id == job) == 0, "listed as finished twice"
    doAssert jobs.state(job) == jsCancelled
    # Removed while its work is out: the runner, back, finds no record.
    let gone = jobs.submit(spec("List another share"), stubborn(1, 1))
    doAssert waitUntil(jobs.state(gone) == jsRunning)
    doAssert jobs.cancel(gone)
    doAssert jobs.tend(getMonoTime() + CancelGrace + initDuration(seconds = 1))
    doAssert jobs.remove(gone), "a finished job is taken off the list"
    gates[1].open()
    doAssert waitUntil(ran[1].load == 1 and not jobs.workingOn(gone))
    let last = jobs.submit(spec("Open another file"), fake(3))
    doAssert waitUntil(jobs.state(last) == jsDone), "the lane goes on"
    doAssert jobs.info(gone).isNone

  block destroyStopsRunningJobs:
    # Leaving the scope with a job running cancels it and waits for it: by
    # then the job has seen its cancel, long before its gate would give up.
    reset()
    var left: MonoTime
    block:
      let jobs = initJobs()
      let job = jobs.submit(spec("Running at the end"), proc (ctx: JobContext) {.gcsafe.} =
        try:
          gates[0].waitAt(ctx)
        except JobCancelledError:
          sawCancel.store(true)
          raise)
      doAssert waitUntil(jobs.state(job) == jsRunning)
      left = getMonoTime()
    doAssert sawCancel.load, "leaving the scope did not wait for the running job to stop"
    doAssert getMonoTime() - left < Patience, "leaving the scope did not cancel the running job"
    doAssert ran[0].load == 0

when isMainModule:
  main()
