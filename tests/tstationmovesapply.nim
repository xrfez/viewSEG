## Station moves on an open file's keys (`applyFileMoves`, `setStationMoves`):
## a move wins over the header and over a survey join, offset and midpoint
## follow it, a trace with no source keeps its offset, a station the list does
## not name is left alone, and removing the move puts the position back.
## The same list applied again does not change `keysRevision`.
## The Headers window (Trace tab and a trace table sorted by receiver X) shows
## the move without the selection changing. A project whose survey cannot be
## restored still applies its moves to a file opened after that, and to one
## opened while the restore was still running.
##
## Seen to fail: with `applyFileMoves` returning 0 before it called `applyMoves`,
## `n == 6` (traces changed: 0). With `followInspect` comparing only the join
## serial, the Trace tab kept receiver X 0 after the move; with the table's
## cached column keyed only by the joins, the sorted trace table did too. With
## a failed survey restore leaving the file on the join queue, the opened file's
## receiver X stayed 0.

import std/[math, options, os, strutils]
import parseSEG
import parseSEG/model/traceindex
import viewSEG/core/[state, stationmoves]
import utils/[fixtures, steps, waiting]

func near(a, b: float64; tol = 1e-4): bool =
  abs(a - b) <= tol * max(1.0, abs(b))

proc moveAt(line, point: float64; index: int16; fromTime: Option[float64]; x,
    y: float64): StationMove =
  StationMove(station: StationKey(line: line, point: point, index: index), fromTime: fromTime,
    x: x, y: y)

proc sps(paths: varargs[string]): seq[JoinFile] =
  for p in paths: result.add JoinFile(path: p, kind: jkSps)

proc opened(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
    st.survey.findTraces(st.sessions[0].id) >= 0)

proc join(st: var AppState; files: seq[JoinFile]) =
  let before = st.joinReport.serial
  st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: files,
    joinOptions: JoinOptions(), joinUnits: JoinUnits(survey: suMetres))
  doAssert st.settle(st.joinReport.serial > before and st.joinUnderWay.job == NoJob),
    "the join did not end"

proc keysOf(st: AppState; t: int): TraceKeys = st.sessions[0].file.index.keys[t]

proc stamp(f: var SeismicFile; t: int; line, point: float64; index: int16; time, rx, ry, sx, sy,
    offset: float64) =
  var k = f.mindex.keys[t]
  k.rcvLine = line
  k.rcvPoint = point
  k.rcvIndex = index
  k.time = time
  k.rcvX = rx
  k.rcvY = ry
  k.srcX = sx
  k.srcY = sy
  k.offset = offset
  k.rcvZ = NaN
  k.cmpX = NaN
  k.cmpY = NaN
  f.mindex.keys[t] = k

proc main*() =

  block onTheKeys:
    # Trace 1 is at the fromTime, trace 2 before it, trace 3 has no time.
    # Trace 4's source is unknown. Trace 5 is another station. Index 0 on
    # trace 6 takes a move stored at index 1; index 2 on trace 7 takes a
    # move stored at index 0.
    withFixtures fx:
      var f = openSeismic(fx.stationsSegd(), keys = true)
      let rev = f.keysRevision
      stamp(f, 1, 100, 201, 1, 1_700_000_000, 4000, 1000, 1000, 1000, 9)
      stamp(f, 2, 100, 201, 1, 1_699_999_000, 4000, 1000, 1000, 1000, 9)
      stamp(f, 3, 100, 201, 1, NaN, 4000, 1000, 1000, 1000, 9)
      stamp(f, 4, 100, 202, 1, 1_700_000_000, 4000, 1000, NaN, NaN, 42)
      stamp(f, 5, 100, 203, 1, 1_700_000_000, 4000, 1000, 1000, 1000, 9)
      stamp(f, 6, 100, 204, 0, 1_700_000_000, 4000, 1000, 1000, 1000, 9)
      stamp(f, 7, 100, 205, 2, 1_700_000_000, 4000, 1000, 1000, 1000, 9)
      var moves = StationMoves()
      moves.add moveAt(100, 201, 0, some(1_700_000_000.0), 7000, 1000)
      moves.add moveAt(100, 201, 0, none(float64), 6000, 1000)
      moves.add moveAt(100, 202, 0, none(float64), 7000, 1000)
      moves.add moveAt(100, 204, 1, none(float64), 7100, 1000)
      moves.add moveAt(100, 205, 0, none(float64), 7200, 1000)
      var bases: seq[ReceiverBase] = @[]
      let n = f.applyFileMoves(moves, bases)
      doAssert n == 6, "traces changed: " & $n
      doAssert near(f.traceKeys(1).rcvX, 7000), "at the fromTime the dated move applies"
      doAssert near(f.traceKeys(1).offset, 6000) and near(f.traceKeys(1).cmpX, 4000)
      doAssert near(f.traceKeys(2).rcvX, 6000), "before the fromTime the undated move applies"
      doAssert f.traceKeys(3).rcvX == 6000 or near(f.traceKeys(3).rcvX, 6000),
        "a trace with no time takes the undated move"
      doAssert near(f.traceKeys(4).rcvX, 7000) and near(f.traceKeys(4).offset, 42),
        "an unknown source keeps its offset"
      doAssert near(f.traceKeys(5).rcvX, 4000), "a station the list does not name is left"
      doAssert near(f.traceKeys(6).rcvX, 7100), "index 0 takes the move stored at index 1"
      doAssert near(f.traceKeys(7).rcvX, 7200), "index 2 takes the move stored at index 0"
      doAssert f.keysRevision == rev + 1
      let again = f.keysRevision
      var same = bases
      doAssert f.applyFileMoves(moves, same) == 0, "the same moves change nothing"
      doAssert f.keysRevision == again
      let restored = f.applyFileMoves(StationMoves(), bases)
      doAssert restored == 6, "removing the moves restores " & $restored
      doAssert near(f.traceKeys(1).rcvX, 4000) and near(f.traceKeys(1).offset, 9)
      doAssert near(f.traceKeys(4).offset, 42)
      f.close()

  block winsOverSurvey:
    withFixtures fx:
      let path = fx.stationsSegd()
      let survey = fx.surveySps()
      var st = initAppState()
      st.opened(path)
      st.join(sps(survey.s, survey.r, survey.x))
      doAssert st.joinReport.outcome == joJoined, $st.joinReport.words
      let surveyX = st.keysOf(1).rcvX
      let rev = st.sessions[0].keysRevision
      var moves = StationMoves()
      moves.add moveAt(RcvLine, FirstRcvPoint, 0, none(float64), 7000, OriginY)
      st.setStationMoves(moves)
      doAssert st.settle(near(st.keysOf(1).rcvX, 7000)), "a move wins over the survey"
      doAssert near(st.keysOf(2).rcvX, rcvX(2)), "another station keeps the survey"
      doAssert st.sessions[0].keysRevision == rev + 1
      st.join(sps(survey.s, survey.r, survey.x))
      doAssert near(st.keysOf(1).rcvX, 7000), "a later join still leaves the move in place"
      doAssert near(st.keysOf(2).rcvX, rcvX(2))
      let moved = st.sessions[0].keysRevision
      st.setStationMoves(moves)
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions[0].keysRevision == moved),
        "the same list does not bump the revision"
      st.setStationMoves(StationMoves())
      doAssert st.settle(near(st.keysOf(1).rcvX, surveyX)), "removing the move restores the survey"
      doAssert st.sessions[0].keysRevision == moved + 1

  block headerRestored:
    withFixtures fx:
      let path = fx.stationsSegd()
      var st = initAppState()
      st.opened(path)
      let rev = st.sessions[0].keysRevision
      var moves = StationMoves()
      moves.add moveAt(RcvLine + 1, FirstRcvPoint, 0, none(float64), 7000, OriginY)
      st.setStationMoves(moves)
      doAssert st.settle(near(st.keysOf(13).rcvX, 7000)), "a file with no survey takes the move"
      doAssert st.sessions[0].keysRevision == rev + 1
      var absent = StationMoves()
      absent.add moveAt(9, 9, 0, none(float64), 1, 1)
      st.setStationMoves(absent)
      doAssert st.settle(near(st.keysOf(13).rcvX, 0) and st.sessions[0].keysRevision == rev + 2),
        "taking the move out restores the header"
      # The line above expects a restore (the previous move is gone) and a bump.
      # A second apply of a station the file does not have, with no bases left, does not bump.
      let held = st.sessions[0].keysRevision
      st.setStationMoves(absent)
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions[0].keysRevision == held and
        near(st.keysOf(13).rcvX, 0))

  block headersAfterMove:
    # No survey, one trace selected, the Headers window open. An undated move
    # must show in the Trace tab and in a table sorted by receiver X, with
    # the selection left as it is.
    withFixtures fx:
      var st = initAppState()
      st.opened(fx.stationsSegd())
      let id = st.sessions[0].base + 13
      let view = TableView(fields: @["keys.rcvX"], scope: tsFile, sortBy: "keys.rcvX",
        rows: 0 .. 24)
      st.apply Command(kind: ckInspect, inspect: {ipTraceHeaders, ipTable}, table: view)
      st.apply Command(kind: ckSelect, traces: @[id], mode: smReplace)
      doAssert st.settle(not st.inspection.waiting and st.inspection.answer.traces.len == 1 and
        near(st.inspection.answer.traces[0].keys.rcvX, 0) and
        st.inspection.answer.table.rowTraces.len > 0), "the Headers window did not answer"
      var moves = StationMoves()
      moves.add moveAt(RcvLine + 1, FirstRcvPoint, 0, none(float64), 7000, OriginY)
      st.setStationMoves(moves)
      doAssert st.settle(not st.inspection.waiting and st.inspection.answer.traces.len == 1 and
        st.inspection.answer.traces[0].id == id and
        near(st.inspection.answer.traces[0].keys.rcvX, 7000)),
        "the Trace tab kept the receiver X from before the move"
      var shown = false
      let table = st.inspection.answer.table
      for i, t in table.rowTraces:
        if t == 13 and i < table.values.len and table.values[i].len > 0 and
            near(table.values[i][0], 7000):
          shown = true
      doAssert shown, "the trace table kept the receiver X from before the move"
      st.shutdown()

  proc made(fx: Fixtures): (string, string) =
    ## A closed project whose survey is kept, and the stations-only file it
    ## was joined to. Receiver line 101, point 101 is moved to X 7000.
    let field = fx.dir / "field"
    createDir(field)
    let record = field / "stations-only.sgd"
    moveFile(fx.stationsSegd(), record)
    let job = fx.dir / "Job"
    let survey = fx.surveySps()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: record)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut), "not shown"
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0), "the project was not made"
    let before = st.joinReport.serial
    st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id,
      joinFiles: sps(survey.s, survey.r, survey.x))
    doAssert st.settle(st.joinReport.serial > before and not st.importing and
      st.project.survey == srLoaded and st.project.doc.hasStore),
      "the survey was not kept: " & $st.project.survey & " " & st.project.surveyNote
    var moves = StationMoves()
    moves.add moveAt(RcvLine + 1, FirstRcvPoint, 0, none(float64), 7000, OriginY)
    st.setStationMoves(moves)
    doAssert st.settle(near(st.keysOf(13).rcvX, 7000)), "the move was not applied"
    st.flushFiles()
    st.shutdown()
    (job, record)

  proc newer(job: string) =
    ## A later document version: the project opens read-only, and a damaged
    ## or missing survey.bin is not made again from the copies.
    let path = job.documentOf
    var text = readFile(path)
    doAssert "(version 1)" in text, "no version to bump"
    writeFile(path, text.replace("(version 1)", "(version 2)"))

  block movesWhenSurveyMissing:
    # The survey cannot be restored (its store is gone, and the project is
    # read-only). A file opened after that still takes the moves.
    withFixtures fx:
      let (job, record) = made(fx)
      removeFile(job.partOf(SurveyStoreName))
      newer(job)
      var st = initAppState()
      st.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert st.settle(st.inProject and st.project.survey == srFailed),
        "the missing survey did not fail: " & $st.project.survey & " " & st.project.surveyNote
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: record)
      doAssert st.settle(st.sessions.len == 1 and near(st.keysOf(13).rcvX, 7000)),
        "a file opened after the survey failed kept the header position"
      var again = StationMoves()
      again.add moveAt(RcvLine + 1, FirstRcvPoint, 0, none(float64), 7100, OriginY)
      st.setStationMoves(again)
      doAssert st.settle(near(st.keysOf(13).rcvX, 7100)),
        "a move set after the survey failed was not applied"
      st.shutdown()

  block movesWhenRestoreFails:
    # The file is queued for the join while the restore runs. The store is
    # then damaged and the project is read-only, so the restore fails and
    # is not rebuilt. The queued file still takes the moves.
    withFixtures fx:
      let (job, record) = made(fx)
      newer(job)
      const phase = "making the survey kept in the project"
      installSteps()
      defer: setJobHook(nil)
      holdStep(phase)
      var st = initAppState()
      st.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert st.settle(st.inProject and st.project.survey == srLoading and
        inStep(phase).len > 0), "the restore did not wait"
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: record)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut), "not shown"
      let bin = job.partOf(SurveyStoreName)
      var bytes = readFile(bin)
      for i in 0 ..< min(64, bytes.len): bytes[i] = '\0'
      writeFile(bin, bytes)
      releaseStep(phase)
      doAssert st.settle(st.project.survey == srFailed and near(st.keysOf(13).rcvX, 7000)),
        "a file queued for the join kept the header position: " & $st.project.survey & " " &
        st.project.surveyNote & " rcvX " & $st.keysOf(13).rcvX
      st.shutdown()

when isMainModule:
  main()
