## The station move command (`ckStationMove`) and the read of a trace's own header position
## (`ckOwnPosition`): a move is added, replaced by the same station and time, forgotten; with no
## project, or a read-only one, it holds for this run only and says so, and the file on disk is
## not changed; the message gives the distance; the open file's receiver keys follow the move and
## are restored when it is forgotten; the header position of a trace is the file's own after a
## survey join has overwritten the keys and a move has replaced them.
##
## Seen to fail: with `ownPositionOf` answering from the keys in memory, the header position
## after the join was the survey's 500050 and not the file's 500000.
## With `queueOpenMoves` forgetting a move while its job had not yet posted what it replaced,
## the keys stayed moved (about 2 runs in 10, then the wait for the restore ran out).

import std/[math, options, os, sequtils, strutils]
import parseSEG
import viewSEG/core/[project, projectnif, state, stationmoves]
import utils/[farsurvey, fixtures, waiting]

func near(a, b: float64): bool =
  abs(a - b) <= 0.01

proc said(st: AppState; words: string): bool =
  st.log.anyIt(words in it.text)

proc moveCmd(point, x, y: float64; was = (x: NaN, y: NaN); fromTime = none(float64)): Command =
  ## A move of receiver line 100, `point`, index 1.
  Command(kind: ckStationMove, moveLine: 100, movePoint: point, moveIndex: 1, moveX: x,
    moveY: y, moveWasX: was.x, moveWasY: was.y, moveHasWas: was.x == was.x,
    moveHasFrom: fromTime.isSome, moveFrom: fromTime.get(0.0), moveNote: "moved in the field")

proc main*() =
  block commandOnTheList:
    withFixtures fx:
      var st = initAppState()
      st.apply moveCmd(101, 500050, 6000000, (x: 500000.0, y: 6000000.0))
      doAssert st.project.doc.stationMoves.len == 1
      doAssert st.said("Receiver 100/101 is moved 50.0 units") and st.said(
          "(500050.00, 6000000.00)") and
        st.said("for this run only (no project is open)"), $st.log.mapIt(it.text)
      st.apply moveCmd(101, 7100, 1)
      doAssert st.project.doc.stationMoves.len == 1 and
        near(st.project.doc.stationMoves[0].x, 7100), "the same station and time replaces"
      st.apply moveCmd(101, 7200, 1, fromTime = some(1.7e9))
      doAssert st.project.doc.stationMoves.len == 2
      doAssert st.said("from 2023-11-14 22:13:20 UTC on")
      var forget = moveCmd(101, 0, 0, fromTime = some(1.7e9))
      forget.moveForget = true
      st.apply forget
      doAssert st.project.doc.stationMoves.len == 1 and st.said("is removed")
      st.apply forget
      doAssert st.said("no move of receiver 100/101 from 2023-11-14 22:13:20 UTC on is kept")
      var bad = moveCmd(101, NaN, 1)
      st.apply bad
      doAssert st.project.doc.stationMoves.len == 1, "a position that is no number was kept"
      bad = moveCmd(101, 1, 1)
      bad.moveIndex = -1
      st.apply bad
      doAssert st.project.doc.stationMoves.len == 1
      st.shutdown()

  block inAProject:
    withFixtures fx:
      var st = initAppState()
      st.rememberFilesIn(fx.dir / "config")
      let field = fx.dir / "field"
      let job = fx.dir / "job"
      createDir(field)
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0 and
        not st.project.readOnly), "the project was not made"
      let rev = st.project.revision
      st.apply moveCmd(101, 7000, 1)
      doAssert st.project.revision > rev, "the project was not marked changed"
      doAssert st.said("in the project") and not st.said("for this run only")
      st.flushFiles()
      doAssert "stationMoves" in readFile(documentOf(job)), "the move was not saved"
      # a second program opens the project read-only: the move holds for the run only
      var other = initAppState()
      other.rememberFilesIn(fx.dir / "config")
      other.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert other.settle(other.inProject and other.project.readOnly)
      let before = readFile(documentOf(job))
      other.apply moveCmd(102, 7000, 1)
      doAssert other.project.doc.stationMoves.len == 2
      doAssert other.said("read-only") and other.said(
          "for this run only (the project is read-only)"),
        $other.log.mapIt(it.text)
      other.flushFiles()
      doAssert readFile(documentOf(job)) == before, "a read-only project's file changed"
      other.shutdown()
      st.shutdown()

  block keysFollowAndOwnPosition:
    withFixtures fx:
      let own = fx.twoSetSegd()
      let sps = fx.surveyFarther()
      var st = initAppState(indexCache = fx.dir / "cache")
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: own)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
        st.survey.findTraces(st.sessions[0].id) >= 0)
      let id = st.sessions[0].base + 2 # receiver line 100, point 101
      template keys(t: int): untyped = st.sessions[0].file.index.keys[t]
      doAssert near(keys(2).rcvX, 500000), "the header's own position"
      let before = st.joinReport.serial
      st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id,
        joinFiles: @[JoinFile(path: sps.s, kind: jkSps), JoinFile(path: sps.r, kind: jkSps),
          JoinFile(path: sps.x, kind: jkSps)], joinOptions: JoinOptions(coordinates: hcReplace),
        joinUnits: JoinUnits(survey: suMetres))
      doAssert st.settle(st.joinReport.serial > before and st.joinUnderWay.job == NoJob)
      doAssert near(keys(2).rcvX, 500050), "the survey did not replace the header: " &
        $keys(2).rcvX
      doAssert st.ownPositionOf(id).isNone, "read before it was asked"
      st.apply Command(kind: ckOwnPosition, ownTrace: id)
      doAssert st.settle(st.ownPositionOf(id).isSome), "the header position was not read"
      let header = st.ownPositionOf(id).get
      doAssert near(header.x, 500000) and near(header.y, 6000000),
        "the position is not the file's own: " & $header
      # a move replaces the keys; the header position stays the file's
      st.apply moveCmd(101, 500100, 6000000, (x: 500050.0, y: 6000000.0))
      doAssert st.said("Receiver 100/101 is moved 50.0 m:"), $st.log.mapIt(it.text)
      doAssert st.settle(near(keys(2).rcvX, 500100)), "the move did not reach the keys"
      doAssert near(keys(3).rcvX, rcvX(2) + 50.0), "another station kept the survey's position"
      doAssert near(st.ownPositionOf(id).get.x, 500000)
      var forget = moveCmd(101, 0, 0)
      forget.moveForget = true
      st.apply forget
      doAssert st.settle(near(keys(2).rcvX, 500050)), "forgetting did not restore the survey"
      doAssert near(st.ownPositionOf(id).get.x, 500000)
      st.shutdown()

when isMainModule:
  main()
