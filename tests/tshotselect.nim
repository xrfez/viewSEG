## Choosing a shot on the map: a click on a point of a shot log's layer chooses every
## row of the log taken there (a shot taken twice has two), and the traces of the file
## shown that belong to those shots, matched as the Shot log window's follow matches a
## trace to a row.
##
## The file is a time-sliced receiver gather built here: six traces of one receiver, one
## per shot instant. The log has the shot of line 10, point 101 twice (rows 1 and 4).
##
## The hover text of a shot taken twice says so and gives both times.
##
## Seen to fail: with `rowsAtPoint` taking the clicked point's own row alone,
## `taken_twice_selects_both_rows` held [1]; with `shotTraces` matching on the first row of
## the pair only, `traces_of_both_shots` held trace 1 alone; with the continuous-gather
## sentence left out, `unmatched_says_why` found no message; with a log without line and
## point grouped by row, `no_line_point_groups_by_place` held one row; with the source
## layer's click not asking for a jump, `source_click_jumps_in_receiver_gather` stayed on
## the first receiver gather.

import std/[os, strutils]
import parseSEG
import viewSEG/core/[shotlog, shotselect, state, survey]
import viewSEG/view/maplayers
import utils/waiting

const
  BaseS = 1_772_323_200'i64           # 2026-03-01T00:00:00 UTC
  Times = [0'i64, 10, 20, 30, 40, 50] ## seconds after BaseS, one shot per trace

proc writeSliced(path: string) =
  ## One receiver, six traces of 20 samples at 2 ms, each starting at a shot's time.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for i, t in Times:
    var k = initTraceKeys()
    k.status = tsLive
    k.record = float64(i + 1)
    k.channel = 1
    k.intervalUs = 2000
    k.t0Ms = 0
    k.time = float64(BaseS + t)
    k.rcvLine = 1
    k.rcvPoint = 7
    var samples = newSeq[float32](20)
    for j in 0 ..< 20: samples[j] = float32(i * 100 + j)
    w.writeTrace(k, samples)
  discard w.close()

proc writeTwoReceivers(path: string) =
  ## Two receivers' gathers (records 1 and 2): four shots at the first, three at the second
  ## (the fourth shot is in the first gather only), every shot at its own source point.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for rec in 1 .. 2:
    for shot in 0 .. (if rec == 1: 3 else: 2):
      var k = initTraceKeys()
      k.status = tsLive
      k.record = float64(rec)
      k.channel = float64(shot + 1)
      k.intervalUs = 2000
      k.t0Ms = 0
      k.time = float64(BaseS + shot * 10)
      k.rcvLine = 1
      k.rcvPoint = float64(rec)
      k.rcvX = 5000 + float64(rec * 10)
      k.rcvY = 6000
      k.srcLine = 10
      k.srcPoint = float64(100 + shot)
      k.srcX = 1000 + float64(shot * 10)
      k.srcY = 2000
      w.writeTrace(k, newSeq[float32](20))
  discard w.close()

proc writeLog(path: string; withStation: bool) =
  ## Rows 0 to 5; rows 1 and 4 are the same shot (line 10, point 101) at 10 s and 40 s.
  var text = "line,point,x,y,time\n"
  let at = [0, 10, 20, 30, 40, 50]
  let point = [100, 101, 102, 103, 101, 105]
  let x = [1000, 1010, 1020, 1030, 1010, 1050]
  for i in 0 .. 5:
    let line = if withStation: "10" else: ""
    let pt = if withStation: $point[i] else: ""
    text.add line & "," & pt & "," & $x[i] & ",2000," & $((BaseS + at[i]) * 1_000_000) & "\n"
  writeFile(path, text)

proc logMap(): ShotLogMap =
  result = initShotLogMap()
  result.hasHeader = true
  result.roles = @[crSourceLine, crShotPoint, crX, crY, crUtcMicros]

proc layerOf(st: AppState): SurveyLayer =
  st.survey.layers[st.survey.findShotLog(st.shotLogId(0))]

proc pointWithX(st: AppState; x: float64): PointRef =
  let l = st.layerOf
  for p in 0 ..< l.points[prSource].len:
    if l.points[prSource].index.x(p) == x:
      return PointRef(layer: l.id, role: prSource, point: p)
  doAssert false, "no point at x " & $x

proc openBoth(st: var AppState; sliced, log: string) =
  st.apply Command(kind: ckOpen, paths: @[sliced])
  doAssert st.settle(st.sessions.len == 1 and st.jobs.active.len == 0), "the file did not open"
  st.apply Command(kind: ckImportShotLog, logPath: log, logMap: logMap(), logMapped: true)
  doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0 and
    st.survey.layers.len >= 1), "the log did not load"

proc main*() =
  let dir = getTempDir() / ("viewseg-shotselect-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  let sliced = dir / "sliced.sgy"
  let log = dir / "log.csv"
  let plain = dir / "plain.csv"
  writeSliced(sliced)
  writeLog(log, true)
  writeLog(plain, false)

  block taken_twice_selects_both_rows:
    var st = initAppState()
    st.openBoth(sliced, log)
    let p = st.pointWithX(1010)
    doAssert st.layerOf.rowsAtPoint(p.point) == @[1, 4], $st.layerOf.rowsAtPoint(p.point)
    st.apply Command(kind: ckSelectPoints, points: @[p], pointMode: smReplace)
    doAssert st.shotRowsChosen.log == st.shotLogId(0) and st.shotRowsChosen.rows == @[1, 4],
      $st.shotRowsChosen.rows
    let once = st.pointWithX(1030)
    st.apply Command(kind: ckSelectPoints, points: @[once], pointMode: smReplace)
    doAssert st.shotRowsChosen.rows == @[3], $st.shotRowsChosen.rows
    discard st.shutdown()

  block traces_of_both_shots:
    var st = initAppState()
    st.openBoth(sliced, log)
    st.apply Command(kind: ckSelectPoints, points: @[st.pointWithX(1010)],
      pointMode: smReplace)
    var picked: seq[int]
    for t in 0 ..< 6:
      if t + st.sessions[0].base in st.selection.selected: picked.add t
    doAssert picked == @[1, 4], $picked
    doAssert st.selection.points.len == 2, "both rows' points are selected on the map: " &
      $st.selection.points.len
    discard st.shutdown()

  block unmatched_says_why:
    var st = initAppState()
    st.apply Command(kind: ckImportShotLog, logPath: log, logMap: logMap(), logMapped: true)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0 and
      st.survey.layers.len == 1), "the log did not load"
    st.apply Command(kind: ckSelectPoints, points: @[st.pointWithX(1010)],
      pointMode: smReplace)
    doAssert st.shotRowsChosen.rows == @[1, 4], "rows are chosen with no file shown"
    var said = false
    for e in st.log:
      if "No file is shown" in e.text: said = true
    doAssert said, "no message said why no trace was chosen"
    discard st.shutdown()

  block no_line_point_groups_by_place:
    var st = initAppState()
    st.apply Command(kind: ckImportShotLog, logPath: plain, logMap: logMap(),
      logMapped: true)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0 and
      st.survey.layers.len == 1), "the log did not load"
    let l = st.layerOf
    # rows 1 and 4 are at the same place (x 1010, y 2000): one source point
    doAssert l.rowsAtPoint(st.pointWithX(1010).point) == @[1, 4],
      $l.rowsAtPoint(st.pointWithX(1010).point)
    doAssert l.rowsAtPoint(st.pointWithX(1030).point) == @[3]
    discard st.shutdown()

  block hover_says_taken_twice:
    var st = initAppState()
    st.openBoth(sliced, log)
    let twice = st.pointInfo(st.pointWithX(1010), "m")
    doAssert "Taken 2 times" in twice.lines, $twice.lines
    var times = ""
    for l in twice.lines:
      if l.startsWith("At "): times = l
    doAssert times.count(',') == 1 and "2026-03-01" in times, times
    let once = st.pointInfo(st.pointWithX(1030), "m")
    for l in once.lines: doAssert not l.startsWith("Taken"), l
    discard st.shutdown()

  block explicit_rows_and_clear:
    var st = initAppState()
    st.openBoth(sliced, log)
    let id = st.shotLogId(0)
    st.apply Command(kind: ckSelectShotRows, shotLogId: id, shotRows: @[4, 2, 4, 99],
      shotTraces: false)
    doAssert st.shotRowsChosen.rows == @[2, 4], $st.shotRowsChosen.rows
    doAssert st.selection.points.len == 2
    st.apply Command(kind: ckSelectShotRows, shotLogId: id, shotRows: @[])
    doAssert st.shotRowsChosen.log == -1 and st.shotRowsChosen.rows.len == 0
    discard st.shutdown()

  block source_click_jumps_in_receiver_gather:
    let two = dir / "two.sgy"
    writeTwoReceivers(two)
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: two)
    doAssert st.settle(st.sessions.len == 1 and st.jobs.active.len == 0 and
      st.survey.layers.len == 1 and st.sessions[0].gathers.len == 2), "the file did not open"
    let l = st.survey.layers[0]
    var src: PointRef
    for p in 0 ..< l.points[prSource].len:
      if l.points[prSource].index.x(p) == 1030:
        src = PointRef(layer: l.id, role: prSource, point: p)
    doAssert st.survey.tracesAt(src).len == 1
    # the second receiver's gather is shown; the shot's one trace is in the first
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
    doAssert st.settle(st.panels[0].layers[0].source.gather == 1)
    st.apply Command(kind: ckSelectPoints, points: @[src], pointMode: smReplace)
    doAssert st.selection.selected.len == 1 and st.panels[0].layers[0].source.gather == 1,
      "a click that does not ask for it does not move the record"
    st.apply Command(kind: ckSelectPoints, points: @[src], pointMode: smReplace, jump: true)
    doAssert st.selection.selected.len == 1, "the trace stays selected"
    doAssert st.panels[0].layers[0].source.gather == 0, "the gather that holds it is shown"
    discard st.shutdown()

when isMainModule:
  main()
