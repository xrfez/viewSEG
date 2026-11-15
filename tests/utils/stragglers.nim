## A thread the quit leaves running must find what it reads still there when
## it goes on: built under AddressSanitizer by `tests/tstragglers.nim`, which
## runs one scenario a process (`stragglers <scenario>`). Each scenario
## quits an `AppState` while a thread is held where a drive that does not
## answer, or a long step, would hold it, destroys the state, then lets the
## thread go on and waits until it has returned: a read of what the quit
## freed is a heap-use-after-free report, and the process fails.
##
## - `joinStep`: the quit comes while a join's step changes the file's keys
##   (`joinApplyWork`, past its cancel check); the step then reads the
##   survey it applies.
## - `leftReader`: a panel's reader is stuck in a read of the map (the
##   drive), the user stops waiting for it (it is left, none of the panels'
##   readers any more), then quits; the reader then reads the file.
## - `leftCheck`: no quit: a record check is cancelled and, not stopping,
##   abandoned; the user unloads the relation file it reads; the check then
##   reads it.
## - `leftInspector`: the Headers window's reader is stuck in a trace header
##   read of the drive, a trace of another file is asked for (it is left,
##   and a new reader started), then the quit; the left reader then reads
##   the header, posts its answer and ends its holds (the jobs').

import std/[os, strutils, times]
import viewSEG/core/state
import faultyfs, fixtures, steps, waiting

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc opened(st: var AppState; path: string) =
  ## `path` shown in the main panel, a tile of it taken in, its positions read.
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
    st.survey.findTraces(st.sessions[0].id) >= 0)
  let p = st.panel(MainPanel)
  st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(p.layout, 800, 600))
  doAssert st.settle(st.tiles(st.findPanel(MainPanel)).len > 0)

proc quitInJoinStep(fx: Fixtures): JobId =
  ## Quits while a join's step runs; returns the step's job, left running.
  let path = fx.stationsSegd()
  let survey = fx.surveySps()
  var st = initAppState()
  st.opened(path)
  holdStep("matching")
  st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
    JoinFile(path: survey.s, kind: jkSps), JoinFile(path: survey.r, kind: jkSps),
    JoinFile(path: survey.x, kind: jkSps)], joinUnits: JoinUnits(survey: suMetres))
  doAssert st.settle(inStep("matching").len == 1), "the join's step runs"
  result = inStep("matching")[0]
  doAssert st.joinUnderWay.step == jpJoining
  doAssert not st.shutdown(), "the quit leaves the step running"
  # `st` is destroyed here, with whatever the quit did not keep.

proc look(st: var AppState; first, last: float64) =
  var v = fitAll(st.panel(MainPanel).layout, 800, 600)
  v.traces = Span(lo: first - 0.5, hi: last + 0.5)
  st.apply Command(kind: ckView, panel: MainPanel, view: v)

proc quitAfterALeftReader(far: string) =
  ## Quits once the main panel's reader, stuck in the map of `far`'s file,
  ## was left by the user.
  var st = initAppState(watchEvery = initDuration(seconds = 60))
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: far / "c.sgy")
  doAssert st.settle(st.panel(MainPanel).laidOut)
  st.look(0, 99)
  doAssert st.settle(st.tiles(st.findPanel(MainPanel)).len > 0)
  fault(far, fkHang, {foMapped})
  st.look(1000, 1099)
  doAssert st.settle(hung() == 1), "the reader's read hangs"
  advanceFsClock(StallAfter + initDuration(seconds = 1))
  st.apply Command(kind: ckStopReading, panel: MainPanel) # the reader is left
  doAssert not st.shutdown(), "the quit leaves the reader, which still reads the file"

proc quitAfterALeftInspector(far, near: string) =
  ## Quits once the Headers window's reader, stuck in a trace header read
  ## of `far`'s file, was left for a trace of `near`'s.
  var st = initAppState(watchEvery = initDuration(seconds = 60))
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: far)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  st.apply Command(kind: ckOpen, paths: @[near]) # (not shown)
  doAssert st.settle(st.sessions.len == 2)
  let (a, b) = if st.sessions[0].path == far: (st.sessions[0], st.sessions[1])
               else: (st.sessions[1], st.sessions[0])
  fault(far, fkHang, {foHeaders})
  st.apply Command(kind: ckSelect, traces: @[a.base + 3], mode: smReplace)
  st.apply Command(kind: ckInspect, inspect: {ipTraceHeaders})
  doAssert st.settle(hung() == 1), "the inspector's header read hangs"
  advanceFsClock(StallAfter + initDuration(seconds = 1))
  st.apply Command(kind: ckSelect, traces: @[b.base + 1], mode: smReplace)
  doAssert st.settle(st.inspection.answer.traces.len == 1 and
    st.inspection.answer.traces[0].id == b.base + 1), "the other file's trace is read"
  doAssert not st.shutdown(), "the quit leaves the stuck reader, which still holds the file"

proc leaveACheck(fx: Fixtures): JobId =
  ## A record check cancelled and abandoned, then its relation file
  ## unloaded; returns the check's job, held in its first step.
  let sps = fx.surveySps()
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.patchySegy())
  doAssert st.settle(st.sessions.len == 1)
  holdStep("checking the records")
  st.apply Command(kind: ckLoadSurvey, paths: @[sps.x])
  doAssert st.settle(inStep("checking the records").len == 1), "the check runs"
  result = inStep("checking the records")[0]
  st.apply Command(kind: ckCancelJob, job: result)
  advanceFsClock(CancelGrace + initDuration(seconds = 1))
  doAssert st.settle(st.jobs.info(result).get.abandoned), "the check is left"
  let x = st.survey.findFile(sps.x)
  doAssert x >= 0, "the relation file is loaded"
  st.apply Command(kind: ckUnloadSurvey, layer: st.survey.layers[x].id)
  doAssert st.survey.findFile(sps.x) < 0, "the relation file is unloaded"
  for _ in 1 .. 3: discard st.drainInbox()
  releaseStep("checking the records")
  doAssert waitUntil(cameBack(result)), "the check came back"
  discard st.shutdown()

install()
installSteps()
let scenario = if paramCount() >= 1: paramStr(1) else: ""
case scenario
of "joinStep":
  withFixtures fx:
    let job = quitInJoinStep(fx)
    releaseStep("matching")
    doAssert waitUntil(cameBack(job)), "the step came back"
of "leftReader":
  withFixtures fx:
    let far = fx.dir / "far"
    createDir(far)
    copyFile(fx.wideShotSegy, far / "c.sgy")
    quitAfterALeftReader(far)
    releaseAll()
    doAssert waitUntil(hung() == 0)
    sleep 500 # the reader reads on, then ends
of "leftInspector":
  withFixtures fx:
    let far = fx.dir / "far"
    createDir(far)
    copyFile(fx.surveySegy, far / "a.sgy")
    quitAfterALeftInspector(far / "a.sgy", fx.wideShotSegy)
    releaseAll()
    doAssert waitUntil(hung() == 0)
    sleep 500 # the inspector reads on, posts, ends its holds, then ends
of "leftCheck":
  withFixtures fx:
    discard leaveACheck(fx)
else:
  quit "stragglers: no scenario " & scenario.escape
echo "stragglers: ", scenario, ": ok"
