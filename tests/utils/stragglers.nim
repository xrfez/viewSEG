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

import std/[os, strutils]
import viewSEG/core/state
import fixtures, steps, waiting

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

installSteps()
let scenario = if paramCount() >= 1: paramStr(1) else: ""
case scenario
of "joinStep":
  withFixtures fx:
    let job = quitInJoinStep(fx)
    releaseStep("matching")
    doAssert waitUntil(cameBack(job)), "the step came back"
else:
  quit "stragglers: no scenario " & scenario.escape
echo "stragglers: ", scenario, ": ok"
