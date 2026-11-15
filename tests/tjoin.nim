## The geometry join in `core`, without a window (`ckJoin`, File > Join
## geometry), on synthetic SEG-D records and synthetic survey files:
##
## - a record whose headers name stations but give (0, 0) coordinates,
##   joined with the survey's S, R and X files: the coordinates are in the
##   keys, the traces the survey has no receiver for are unmatched and
##   selected on request, the file's positions are read again (the map), the
##   panel shows the joined keys, and **no reader holds the file while its
##   keys change** (the join's own count of holds, and the readers' holds
##   back after it);
## - a record whose headers give the record and channel numbers only, with
##   the X file: matched by record and channel, the R file's receivers then
##   linked to its traces both ways (before the join, none), and its records
##   checked against the joined relation records (the Records window's
##   "missing");
## - a CSV table of stations, with a header row and without;
## - a join that matches nothing says so and why (line numbers 100 times the
##   headers', line names that are text, which the trailing digits then
##   match), and changes nothing;
## - a cancel while the survey files are read, and while the join waits for
##   the file, leaves the file as it was and the plot reading it again (also
##   a record shown meanwhile, which waits for the join without a warning);
## - the survey's units confirmed with the join label the map.
##
## Seen to fail: with the join's second job submitted with the file in
## `reads` (not `exclusive`), the join found a panel reader's hold and
## refused ("a reader still reads the file"), so "joined" failed; with
## `resumeReaders` left out, "the panel reads the file again" did not
## happen; with the automatic replacement of coordinates at (0, 0) left out,
## the join changed nothing and "no reader held the file" found it never ran;
## with a panel shown the file during the join not waiting for it, the log
## said "busy".

import std/[math, os, sequtils, strutils, tables]
import parseSEG
import viewSEG/core/state
import viewSEG/view/maplayers
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func near(a, b: float64; tol = 1e-6): bool = abs(a - b) <= tol * max(1.0, abs(b))

proc sps(paths: varargs[string]): seq[JoinFile] =
  for p in paths: result.add JoinFile(path: p, kind: jkSps)

proc keysOf(st: AppState; t: int): TraceKeys = st.sessions[0].file.index.keys[t]

proc opened(st: var AppState; path: string) =
  ## `path` shown in the main panel, a tile of it taken in, its positions read.
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
    st.survey.findTraces(st.sessions[0].id) >= 0)
  let p = st.panel(MainPanel)
  st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(p.layout, 800, 600))
  doAssert st.settle(st.tiles(st.findPanel(MainPanel)).len > 0)

proc join(st: var AppState; files: seq[JoinFile]; opts = JoinOptions(); units = JoinUnits()) =
  ## Joins `files` to the open file and waits for the join to end.
  let before = st.joinReport.serial
  st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: files,
    joinOptions: opts, joinUnits: units)
  doAssert st.settle(st.joinReport.serial > before and st.joinUnderWay.job == NoJob),
    "the join did not end"

proc words(st: AppState): string = st.joinReport.words.join(" ")

proc readsAgain(st: var AppState; path: string): bool =
  ## The main panel's reader holds the file again and a tile made after the
  ## join came.
  let k = st.findPanel(MainPanel)
  st.settle(st.jobs.held(path) == 1 and st.tiles(k).len > 0 and
    st.tiles(k)[^1].request.gen >= st.panel(MainPanel).samplesGen)

block stationsJoined:
  withFixtures fx:
    let path = fx.stationsSegd()
    let survey = fx.surveySps()
    var st = initAppState()
    st.opened(path)
    doAssert st.jobs.held(path) == 1, "the panel's reader holds the file"
    doAssert st.sessions[0].file.keysRevision == 0
    st.join(sps(survey.s, survey.r, survey.x), units = JoinUnits(survey: suMetres))
    let r = st.joinReport
    doAssert r.outcome == joJoined, $r.outcome & ": " & st.words
    doAssert r.heldAtJoin == 0, "no reader held the file: " & $r.heldAtJoin
    doAssert st.sessions[0].file.keysRevision == 1
    doAssert "12 of 24 seismic traces matched the survey" in st.words, st.words
    doAssert "12 seismic traces are not matched: the survey has no receiver station for them." in
      st.words, st.words
    doAssert "were all (0, 0), so the survey's take their place" in st.words, st.words
    doAssert "1 auxiliary trace is left alone" in st.words, st.words
    doAssert r.unmatched == 12
    # Traces 1 .. 12: line 100, points 101 .. 112, in the R file; 13 .. 24:
    # line 101, in no survey file. The source (1 / 1001) is in the S file.
    for t in 1 .. 2 * SegdChannels:
      let k = st.keysOf(t)
      doAssert near(k.srcX, srcX(0)) and near(k.srcY, OriginY), "trace " & $t & "'s source"
      if t <= SegdChannels:
        doAssert near(k.rcvX, rcvX(t)) and near(k.rcvY, OriginY), "receiver " & $(100 + t) &
          " is placed: trace " & $t & " " & $k.rcvX
        doAssert jgReceiverXy in st.sessions[0].file.index.joinedGroups(t)
        doAssert near(k.offset, abs(rcvX(t) - srcX(0)), 1e-9), "its offset"
      else:
        doAssert k.rcvX == 0 and k.rcvY == 0, "trace " & $t & " keeps its header's (0, 0)"
    doAssert st.keysOf(0).srcX.isNaN or not st.keysOf(0).isSeismic # the time break: alone
    let joined = st.joinedOf(st.sessions[0].id)
    doAssert joined >= 0 and st.joins[joined].plan.unmatched == toSeq(SegdChannels + 1 ..
      2 * SegdChannels)
    # The plot reads the file again, from the joined keys.
    doAssert st.readsAgain(path), "the panel reads the file again"
    let tile = st.tiles(st.findPanel(MainPanel))[^1]
    var lit = 0
    for row in 0 ..< tile.traces.len:
      if tile.traces[row] in 1 .. SegdChannels:
        doAssert near(tile.keys[row].rcvX, rcvX(tile.traces[row]))
        doAssert jgReceiverXy in tile.joinedAt(row)
        inc lit
    doAssert lit == SegdChannels, "the tile's joined keys: " & $lit
    # The map: the file's positions read again from the joined keys.
    doAssert st.settle(st.survey.findTraces(st.sessions[0].id) >= 0 and
      st.survey.layers[st.survey.findTraces(st.sessions[0].id)].keysRevision == 1)
    let own = st.survey.layers[st.survey.findTraces(st.sessions[0].id)]
    doAssert own.points[prReceiver].len == SegdChannels, $own.points[prReceiver].len
    doAssert own.points[prSource].len == 1
    doAssert st.unitsOf == "m", "the units confirmed: " & st.unitsOf
    # Select unmatched traces: line 101's.
    st.apply Command(kind: ckSelectUnmatched, unmatchedOf: st.sessions[0].id)
    doAssert st.selection.selected.len == SegdChannels
    for t in SegdChannels + 1 .. 2 * SegdChannels:
      doAssert st.sessions[0].base + t in st.selection.selected
    doAssert "12 unmatched traces of stations-only.sgd selected, 12 in the record shown" in
      st.log[st.log.len - 1].text, st.log[st.log.len - 1].text
    # Joined again with the same files: nothing more changes, and the plot is not stopped.
    st.join(sps(survey.s, survey.r))
    doAssert st.joinReport.outcome == joJoined and st.joinReport.heldAtJoin == -1
    doAssert st.sessions[0].file.keysRevision == 1
    doAssert "No trace's keys changed" in st.words, st.words
    doAssert "The coordinates the headers give are kept: they are the survey's." in st.words,
      st.words
    echo "tjoin: stations: ", st.words

block byRecordAndChannel:
  withFixtures fx:
    let path = fx.recordOnlySegd()
    let survey = fx.surveySps()
    var st = initAppState()
    st.opened(path)
    doAssert st.keysOf(1).rcvLine.isNaN and st.keysOf(1).rcvX.isNaN
    doAssert st.sessions[0].records[0].planned == -1
    # The R file loaded: its receivers find no trace of a record whose headers
    # name no station, until the join gives them their stations.
    st.apply Command(kind: ckLoadSurvey, paths: @[survey.r])
    doAssert st.settle(st.survey.findFile(survey.r) >= 0)
    proc receiver(st: AppState; point: float64): PointRef =
      let i = st.survey.findFile(survey.r)
      PointRef(layer: st.survey.layers[i].id, role: prReceiver, point: st.survey.layers[
        i].stationPoint(prReceiver, Station(line: RcvLine, point: point, index: 1)))
    let base = st.sessions[0].base
    doAssert st.survey.tracesAt(st.receiver(FirstRcvPoint)).len == 0
    st.join(sps(survey.s, survey.r, fx.segdRelation()))
    doAssert st.joinReport.outcome == joJoined, st.words
    doAssert st.joinReport.heldAtJoin == 0
    let plan = st.joins[0].plan
    doAssert plan.matches[jmRecord] == SegdChannels and plan.matched == SegdChannels, $plan.matches
    doAssert "by record and channel, through the relation file" in st.words, st.words
    for t in 1 .. SegdChannels:
      let k = st.keysOf(t)
      doAssert k.rcvLine == RcvLine and k.rcvPoint == FirstRcvPoint + float64(t - 1)
      doAssert k.srcLine == SrcLine and k.srcPoint == FirstSrcPoint
      doAssert near(k.rcvX, rcvX(t)) and near(k.srcX, srcX(0))
    # The R file's receivers and the traces are linked both ways now.
    doAssert st.settle(st.survey.layers[st.survey.findTraces(st.sessions[0].id)].keysRevision == 1)
    doAssert st.survey.tracesAt(st.receiver(FirstRcvPoint + 4)) == @[base + 5]
    doAssert st.receiver(FirstRcvPoint + 4) in st.survey.tracePointsOf(base + 5)
    # The records are checked against the joined relation records.
    doAssert st.settle(st.sessions[0].records[0].planned == SegdChannels), "records checked"
    doAssert st.sessions[0].records[0].plannedMissing == 0
    doAssert st.sessions[0].records[0].unlisted == 0
    doAssert "segd.x" in st.sessions[0].checkedAgainst, st.sessions[0].checkedAgainst
    echo "tjoin: by record and channel: ", st.words

block csvTable:
  withFixtures fx:
    # Read alone: delimiters, a header row or none, rows that cannot be used.
    var g = initSurveyGeometry()
    var problems: seq[string]
    var skipped = 0
    let text = "# stations\nKind;Line;Station;Easting;Northing;Elevation\nS;1;1001;10;20;3\n" &
      "R;100;101;11;21;\nR;100;x;1;2;3\nQ;100;102;1;2;3\n\nR;100;103;13;23;4\n"
    doAssert g.addCsv(text, "t.csv", crColumn, problems, skipped) == 3
    doAssert skipped == 2 and problems.len == 2, $problems
    doAssert "t.csv line 5: its line or point is not a number" in problems[0], problems[0]
    doAssert "neither S nor R" in problems[1], problems[1]
    doAssert g.sourceCount == 1 and g.receiverCount == 2
    doAssert g.table.receivers[stationKey(100, 103, 0)].x == 13
    var h = initSurveyGeometry()
    problems.setLen 0
    doAssert h.addCsv("100\t101\t5\t6\n100\t102\t7\t8\n", "r.txt", crReceivers, problems,
      skipped) == 2
    doAssert h.receiverCount == 2 and h.sourceCount == 0 and problems.len == 0
    problems.setLen 0
    doAssert h.addCsv("line,point,x,y\n1,2,3,4\n", "k.csv", crColumn, problems, skipped) == 0
    doAssert problems.len == 1 and "choose its role" in problems[0], $problems
    # Joined to a record whose headers name stations.
    let path = fx.stationsSegd()
    var csv = "kind,line,point,x,y,z\nS," & $SrcLine & "," & $FirstSrcPoint & "," & $srcX(0) &
      "," & $OriginY & ",100\n"
    for c in 1 .. SegdChannels:
      csv.add "R," & $RcvLine & "," & $(FirstRcvPoint + float64(c - 1)) & "," & $rcvX(c) & "," &
        $OriginY & ",100\n"
    writeFile(fx.dir / "stations.csv", csv)
    var st = initAppState()
    st.opened(path)
    st.join(@[JoinFile(path: fx.dir / "stations.csv", kind: jkCsv, role: crColumn)])
    doAssert st.joinReport.outcome == joJoined, st.words
    doAssert st.joinReport.heldAtJoin == 0
    doAssert st.joins[0].plan.matched == SegdChannels and st.joins[0].survey.csvRows == 13
    for t in 1 .. SegdChannels:
      doAssert near(st.keysOf(t).rcvX, rcvX(t)) and near(st.keysOf(t).srcX, srcX(0))
    echo "tjoin: CSV: ", st.words

block nothingMatched:
  withFixtures fx:
    let path = fx.stationsSegd()
    # The survey numbers its lines 100 times larger than the headers do.
    let header = SpsHeader(code: "00", description: "SPS format version num.", data: "SPS 2.1;")
    proc point(kind: SpsPointKind; line, pt, x: float64): SpsPoint =
      SpsPoint(kind: kind, line: line, point: pt, index: 1, code: "G1", easting: x,
        northing: OriginY, elevation: Elevation, dayOfYear: -1, hour: -1, minute: -1, second: -1)
    var s, r = SpsFile(headers: @[header])
    s.points.add point(pkSource, SrcLine * 100, FirstSrcPoint, srcX(0))
    for c in 1 .. SegdChannels:
      r.points.add point(pkReceiver, RcvLine * 100, FirstRcvPoint + float64(c - 1), rcvX(c))
    doAssert writeSps(s, fx.dir / "big.s").len == 0 and writeSps(r, fx.dir / "big.r").len == 0
    var st = initAppState()
    st.opened(path)
    st.join(sps(fx.dir / "big.s", fx.dir / "big.r"))
    doAssert st.joinReport.outcome == joNothing, $st.joinReport.outcome
    doAssert st.joinReport.heldAtJoin == -1, "the readers were not stopped"
    doAssert st.sessions[0].file.keysRevision == 0
    doAssert "No seismic trace was matched to the survey" in st.words, st.words
    doAssert "24 seismic traces are not matched: the survey has neither their source nor " &
      "their receiver station." in st.words, st.words
    doAssert "the headers' receiver lines (100 to 101) are not the survey's (10000): the " &
      "survey numbers its lines 100 times larger, so the line numbering differs" in st.words,
      st.words
    doAssert "the headers' source lines (1) are not the survey's (100)" in st.words, st.words
    doAssert st.log[st.log.len - 1].severity == sevWarning
    doAssert "Nothing was joined to stations-only.sgd" in st.log[st.log.len - 1].text
    doAssert st.joinedOf(st.sessions[0].id) < 0
    echo "tjoin: nothing matched: ", st.words
    # Line names that are text (SPS 1.0): passed by, then matched by their trailing digits.
    var s10, r10 = SpsFile(revision: sps10, headers: @[SpsHeader(code: "00",
      description: "SPS format version num.", data: "SPS001,")])
    var p = point(pkSource, NaN, FirstSrcPoint, srcX(0))
    p.lineName = "SL1"
    s10.points.add p
    for c in 1 .. SegdChannels:
      var q = point(pkReceiver, NaN, FirstRcvPoint + float64(c - 1), rcvX(c))
      q.lineName = "RL100"
      r10.points.add q
    doAssert writeSps(s10, fx.dir / "named.s").len == 0
    doAssert writeSps(r10, fx.dir / "named.r").len == 0
    st.join(sps(fx.dir / "named.s", fx.dir / "named.r"))
    doAssert st.joinReport.outcome == joNothing, st.words
    doAssert "the survey files name lines with text (\"SL1\", \"RL100\"), so 13 records were " &
      "passed by: turn on \"Use the trailing digits of line names\"" in st.words, st.words
    st.join(sps(fx.dir / "named.s", fx.dir / "named.r"), JoinOptions(trailingDigits: true))
    doAssert st.joinReport.outcome == joJoined, st.words
    doAssert st.joins[0].plan.matched == SegdChannels
    doAssert near(st.keysOf(1).rcvX, rcvX(1))
    echo "tjoin: matched by trailing digits: ", st.words

var gate: Gate

block cancelled:
  withFixtures fx:
    let path = fx.stationsSegd()
    let survey = fx.surveySps()
    var st = initAppState()
    st.opened(path)
    # While the survey files are read: a million receivers take a while.
    let big = fx.bigSps(1000, 1000)
    st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: sps(big))
    let reading = st.joinUnderWay.job
    doAssert reading != NoJob and st.joinUnderWay.step == jpReading
    st.apply Command(kind: ckCancelJob, job: reading)
    doAssert st.settle(st.joinUnderWay.job == NoJob)
    doAssert st.joinReport.outcome == joCancelled, $st.joinReport.outcome
    doAssert "The join was cancelled: stations-only.sgd is as it was." == st.words, st.words
    doAssert st.sessions[0].file.keysRevision == 0 and st.jobs.held(path) == 1
    # While the join waits for the file: another job reads it.
    gate.close()
    discard st.jobs.submit(JobSpec(title: "Read it", lane: jlBackground, reads: @[path]),
      proc (ctx: JobContext) {.gcsafe.} = gate.waitAt(ctx))
    st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id,
      joinFiles: sps(survey.s, survey.r))
    doAssert st.settle(st.joinUnderWay.step == jpJoining and st.jobs.held(path) == 0),
      "the panel's reader let go of the file"
    let k = st.findPanel(MainPanel)
    doAssert st.tiles(k).len > 0, "the tiles stay drawn meanwhile"
    # The record shown again meanwhile (its auxiliary trace too): it waits for
    # the join, quietly.
    let said = st.log.len
    st.apply Command(kind: ckFilter, panel: MainPanel,
      filter: TraceFilter(seismic: true, auxiliary: true))
    doAssert not st.panel(MainPanel).laidOut
    for e in said ..< st.log.len:
      doAssert "busy" notin st.log[e].text, st.log[e].text
    st.apply Command(kind: ckCancelJob, job: st.joinUnderWay.job)
    doAssert st.settle(st.joinUnderWay.job == NoJob)
    doAssert st.joinReport.outcome == joCancelled
    doAssert st.sessions[0].file.keysRevision == 0
    doAssert st.keysOf(1).rcvX == 0, "the keys as they were"
    doAssert st.readsAgain(path) and st.panel(MainPanel).laidOut,
      "the panel reads the file again"
    gate.open()
    # The same join, let through, does it.
    st.join(sps(survey.s, survey.r))
    doAssert st.joinReport.outcome == joJoined and st.sessions[0].file.keysRevision == 1
    echo "tjoin: cancelled twice, then joined"

echo "tjoin: done"
