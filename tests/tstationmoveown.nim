## What a station move asks of its neighbours: the header position of a trace is read once for
## a trace (a header of (0, 0) too) with the options the file was opened with; it is offered
## only when the file's units are the survey's; "Remove" takes only the moves that serve this
## station's index; a hostile note or position is refused or cleaned; moves made with no project
## are kept in the project made next; a header move says that a dated move of the station keeps
## its time.
##
## Seen to fail: with `askOwnPosition` not remembering a "no position" answer, the second ask of
## a (0, 0) header started a second read; with `movesAppliedTo` listing every index's move, the
## "any index" move was returned for a station with a move of its own.

import std/[math, options, os, sequtils, strutils, unicode]
import parseSEG
import viewSEG/core/[openchoice, project, state, stationmoves]
import utils/[farsurvey, fixtures, waiting]

func near(a, b: float64): bool =
  abs(a - b) <= 0.01

proc said(st: AppState; words: string): bool =
  st.log.anyIt(words in it.text)

proc moveCmd(point, x, y: float64; index = 1; fromTime = none(float64)): Command =
  Command(kind: ckStationMove, moveLine: 100, movePoint: point, moveIndex: index, moveX: x,
    moveY: y, moveHasFrom: fromTime.isSome, moveFrom: fromTime.get(0.0))

proc joined(st: var AppState; fx: Fixtures; units: JoinUnits) =
  let sps = fx.surveyFarther()
  let before = st.joinReport.serial
  st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
    JoinFile(path: sps.s, kind: jkSps), JoinFile(path: sps.r, kind: jkSps),
    JoinFile(path: sps.x, kind: jkSps)], joinOptions: JoinOptions(coordinates: hcReplace),
    joinUnits: units)
  doAssert st.settle(st.joinReport.serial > before and st.joinUnderWay.job == NoJob)

proc main*() =
  block zeroHeaderReadOnce:
    withFixtures fx:
      var st = initAppState(indexCache = fx.dir / "cache")
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.stationsSegd())
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let id = st.sessions[0].base + 1
      st.apply Command(kind: ckOwnPosition, ownTrace: id)
      st.apply Command(kind: ckOwnPosition, ownTrace: id) # while it is being read
      doAssert st.settle(st.jobs.active.len == 0)
      st.apply Command(kind: ckOwnPosition, ownTrace: id) # once it is known to give none
      doAssert st.settle(st.jobs.active.len == 0)
      doAssert st.ownPositionOf(id).isNone, "a header of (0, 0) gave a position"
      doAssert st.ownPositionReads == 1, "the header was read " & $st.ownPositionReads & " times"
      st.shutdown()

  block unitsAndOptions:
    withFixtures fx:
      var st = initAppState(indexCache = fx.dir / "cache")
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.twoSetSegd())
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let id = st.sessions[0].base + 2
      doAssert st.headerUnitsProblem(id).len == 0, "no join, no problem"
      st.joined(fx, JoinUnits(survey: suFeet, file: suMetres))
      let why = st.headerUnitsProblem(id)
      doAssert "metres" in why and "feet" in why and "type the position" in why, why
      st.shutdown()
    withFixtures fz:
      # opened again as SEG-Y forced: the read takes the session's own choice
      var st = initAppState(indexCache = fz.dir / "cache")
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fz.surveySegy())
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      st.apply Command(kind: ckReopen, reopenPath: st.sessions[0].path,
        openChoice: OpenChoice(standard: scSegy))
      doAssert st.settle(st.sessions.len == 1 and
        st.sessions[0].facts.opened.choice.standard == scSegy and st.panel(MainPanel).laidOut),
        "not reopened"
      let id = st.sessions[0].base + 3
      let kept = st.sessions[0].file.index.keys[3].rcvX
      st.apply Command(kind: ckOwnPosition, ownTrace: id)
      doAssert st.settle(st.ownPositionOf(id).isSome), "no position read with the forced standard"
      doAssert near(st.ownPositionOf(id).get.x, kept) and kept > 1000
      st.shutdown()
    withFixtures fy:
      var st = initAppState(indexCache = fy.dir / "cache")
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fy.twoSetSegd())
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      st.joined(fy, JoinUnits(survey: suMetres, file: suMetres))
      doAssert st.headerUnitsProblem(st.sessions[0].base + 2).len == 0
      st.shutdown()

  block removeOnlyThisIndex:
    var st = initAppState()
    st.apply moveCmd(101, 1, 1, index = 0) # any index
    st.apply moveCmd(101, 2, 2, index = 1)
    let one = stationKey(100, 101, 1)
    let two = stationKey(100, 101, 2)
    doAssert st.movesAppliedTo(one).mapIt(it.x) == @[2.0], "index 1 has its own move"
    doAssert st.movesAppliedTo(two).mapIt(it.x) == @[1.0], "index 2 takes the any-index move"
    st.apply moveCmd(101, 3, 3, index = 1, fromTime = some(1.7e9))
    doAssert st.movesAppliedTo(one).len == 2
    st.shutdown()

  block hostile:
    var st = initAppState()
    var c = moveCmd(101, 1, 1)
    c.moveNote = "a\nb\x01c" & repeat("é", 200)
    st.apply c
    let note = st.project.doc.stationMoves[0].note
    doAssert note.len <= 256 and '\n' notin note and '\x01' notin note and
      note.startsWith("a b c"), note
    doAssert note.validateUtf8 == -1, "the note was cut inside a character"
    st.apply moveCmd(102, 2e9, 1)
    st.apply moveCmd(103, 1, -2e9)
    var far = moveCmd(104, 1, 1)
    far.movePoint = 1e9
    st.apply far
    far = moveCmd(104, 1, 1)
    far.moveLine = -1e8
    st.apply far
    doAssert st.project.doc.stationMoves.len == 1, "a hostile move was kept"
    doAssert st.said("within 1000000000") and st.said("below 100000000")
    st.shutdown()

  block datedKept:
    var st = initAppState()
    st.apply moveCmd(101, 5, 5, fromTime = some(1.7e9))
    st.apply moveCmd(101, 6, 6)
    doAssert st.said("A move of this station from a time on is kept")
    st.shutdown()

  block carriedIntoNewProject:
    withFixtures fx:
      var st = initAppState()
      st.rememberFilesIn(fx.dir / "config")
      st.apply moveCmd(101, 7000, 1)
      st.apply moveCmd(102, 7100, 1)
      let field = fx.dir / "field"
      let job = fx.dir / "job"
      createDir(field)
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0 and
        not st.project.readOnly), "the project was not made"
      doAssert st.project.doc.stationMoves.len == 2, "the moves did not come along"
      doAssert st.said("2 station moves made before the project are kept in it")
      st.flushFiles()
      doAssert readFile(documentOf(job)).count("(move") >= 2, "the moves were not saved"
      st.shutdown()

when isMainModule:
  main()
