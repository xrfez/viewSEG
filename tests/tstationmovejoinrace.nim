## A station move forgotten while the join that applies it is at its applying step (project
## with a survey): the keys go back to the survey's, with the list empty. Also a manual survey
## import (ckJoin) racing a move job (a join's plan job reads the file and a move job holds it alone, so the two
## are run one after the other, in both orders of asking): the move holds after both, and
## forgetting it restores the survey's position.
##
## Seen to fail: with `queueOpenMoves` not counting a join at its applying step as work to do,
## "LOST: keys moved with no move in the list".

import std/[os, options]
import parseSEG
import viewSEG/core/[state, stationmoves]
import utils/[fixtures, waiting]

func near(a, b: float64): bool = abs(a - b) <= 0.01

proc forgetRace() =
  withFixtures fx:
    let field = fx.dir / "field"
    createDir(field)
    let record = field / "stations-only.sgd"
    moveFile(fx.stationsSegd(), record)
    let job = fx.dir / "Job"
    let survey = fx.surveySps()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: record)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0)
    let before = st.joinReport.serial
    st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id,
      joinFiles: @[JoinFile(path: survey.s, kind: jkSps), JoinFile(path: survey.r, kind: jkSps),
        JoinFile(path: survey.x, kind: jkSps)])
    doAssert st.settle(st.joinReport.serial > before and not st.importing and
      st.project.survey == srLoaded)
    template keys(t: int): untyped = st.sessions[0].file.index.keys[t]
    let surveyX = keys(13).rcvX
    let mv = Command(kind: ckStationMove, moveLine: keys(13).rcvLine,
      movePoint: keys(13).rcvPoint, moveIndex: 0, moveX: 7000, moveY: OriginY)
    st.apply mv
    var forget = mv
    forget.moveForget = true
    # wait for the join that applies the move to reach its applying step
    doAssert waitUntil((discard st.drainInbox(); st.joinUnderWay.job != NoJob and
      st.joinUnderWay.step == jpJoining)), "no join applying the move"
    st.apply forget
    doAssert st.project.doc.stationMoves.len == 0
    doAssert st.settle(st.jobs.active.len == 0 and st.joinUnderWay.job == NoJob)
    doAssert near(keys(13).rcvX, surveyX), "LOST: keys moved with no move in the list"
    st.shutdown()

proc importRace() =
  ## A manual import asked for right after a move: whichever job runs first, the move holds
  ## after both, and forgetting it gives the survey's position back.
  for round in 0 ..< 6:
    withFixtures fx:
      let survey = fx.surveySps()
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.stationsSegd())
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      template keys(t: int): untyped = st.sessions[0].file.index.keys[t]
      let mv = Command(kind: ckStationMove, moveLine: RcvLine, movePoint: FirstRcvPoint,
        moveIndex: 0, moveX: 7000, moveY: OriginY)
      st.apply mv
      if round mod 2 == 1: doAssert st.settle(near(keys(1).rcvX, 7000) and st.jobs.active.len == 0)
      let before = st.joinReport.serial
      st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
        JoinFile(path: survey.s, kind: jkSps), JoinFile(path: survey.r, kind: jkSps),
        JoinFile(path: survey.x, kind: jkSps)], joinOptions: JoinOptions(coordinates: hcReplace),
        joinUnits: JoinUnits(survey: suMetres))
      doAssert st.settle(st.joinReport.serial > before and st.joinUnderWay.job == NoJob and
        st.jobs.active.len == 0), "the import did not end"
      doAssert near(keys(1).rcvX, 7000), "round " & $round & ": the move was lost: " & $keys(1).rcvX
      var forget = mv
      forget.moveForget = true
      st.apply forget
      doAssert st.settle(st.jobs.active.len == 0 and near(keys(1).rcvX, rcvX(1))),
        "round " & $round & ": forgetting left " & $keys(1).rcvX
      st.shutdown()

proc main*() =
  forgetRace()
  importRace()

when isMainModule:
  main()
