## A shot log whose column map names an X and a Y column is a layer of the
## map: "Shots of <log>", one source point for each row that has a position.
##
## - The layer is listed once the log is read, drawn as a diamond in a colour
##   of its own, in the survey's bounds (so fit takes it in), and gone when
##   the log is removed.
## - A row with no X, or at (0, 0), is counted and left off; a row the log
##   lists a problem for (a repeated shot) is drawn like the others.
## - Editing a cell of X rebuilds the layer: the shot moves.
## - A log with no X and Y column makes no layer and no entry.
## - The hover text of a shot gives the row's identifying cells.
## - A hundred thousand shots become a layer on the job's thread within a
##   second, and listing the layers stays cheap.
##
## Runs alone: it measures the time a layer takes to build.
##
## Seen to fail: with the layer never put in the survey, `layer_listed` found
## no "Shots of" entry; with the survey's bounds left out of `incl`, `bounds_take_it_in`
## saw the old extent; with the layer kept after the log's removal, `removal_takes_it_off`
## still listed it.

import std/[monotimes, os, strutils, times]
import viewSEG/core/[geometry, shotlog, shotmap, state, survey]
import viewSEG/view/[maplayers, theme]
import utils/waiting

proc writeLog(path: string; withPositions: bool): ShotLogMap =
  ## Six shots on a line: the third has no X, the fourth is at (0, 0), the fifth
  ## repeats the second's line and point (a problem the log lists).
  var text = "line,point,x,y,file\n"
  let rows = [("10", "100", "1000", "2000"), ("10", "101", "1010", "2000"),
    ("10", "102", "", "2000"), ("10", "103", "0", "0"), ("10", "101", "1040", "2000"),
    ("10", "105", "1050", "2010")]
  for i, r in rows:
    text.add r[0] & "," & r[1] & "," & r[2] & "," & r[3] & "," & $(5000 + i) & "\n"
  writeFile(path, text)
  result = initShotLogMap()
  result.hasHeader = true
  result.roles = @[crSourceLine, crShotPoint, (if withPositions: crX else: crText),
    (if withPositions: crY else: crText), crFileNumber]

proc entries(st: AppState): seq[MapLayerView] =
  for l in mapLayers(st, mapInk(builtinTheme(tmDark), pcPaper)):
    if l.key.kind == mlShotLog: result.add l

proc main*() =
  let dir = getTempDir() / ("viewseg-shotmap-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  let path = dir / "shots.csv"
  let map = writeLog(path, true)

  block layer_listed:
    var st = initAppState()
    st.apply Command(kind: ckImportShotLog, logPath: path, logMap: map, logMapped: true)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0 and
      st.entries.len == 1), "no shot log layer was listed"
    let e = st.entries[0]
    doAssert e.name == "Shots of shots", e.name
    doAssert e.points == 4, "points: " & $e.points
    doAssert e.shape == msDiamond and e.shown and e.own
    let ink = mapInk(builtinTheme(tmDark), pcPaper)
    doAssert e.colour != ink.roles[prSource] and e.colour != ink.roles[prReceiver]
    let at = st.survey.findShotLog(st.shotLogId(0))
    let l = st.survey.layers[at]
    doAssert l.counts[prSource].given == 6 and l.counts[prSource].missing == 1 and
      l.counts[prSource].zero == 1, $l.counts[prSource]
    discard st.shutdown()

  block bounds_take_it_in:
    var st = initAppState()
    doAssert st.survey.bounds.isEmpty
    st.apply Command(kind: ckImportShotLog, logPath: path, logMap: map, logMapped: true)
    doAssert st.settle(st.entries.len == 1), "no layer"
    let b = st.survey.bounds
    doAssert b.minX == 1000 and b.maxX == 1050 and b.minY == 2000 and b.maxY == 2010,
      $(b.minX, b.maxX, b.minY, b.maxY)
    discard st.shutdown()

  block toggle_hides_it:
    var st = initAppState()
    st.apply Command(kind: ckImportShotLog, logPath: path, logMap: map, logMapped: true)
    doAssert st.settle(st.entries.len == 1), "no layer"
    let key = st.entries[0].key
    st.apply Command(kind: ckMapLayer, mapLayer: key, shown: false)
    doAssert not st.entries[0].shown and not st.entries[0].own
    st.apply Command(kind: ckMapLayer, mapLayer: key, shown: true)
    doAssert st.entries[0].shown
    discard st.shutdown()

  block edit_moves_a_shot:
    var st = initAppState()
    st.apply Command(kind: ckImportShotLog, logPath: path, logMap: map, logMapped: true)
    doAssert st.settle(st.entries.len == 1 and st.jobs.active.len == 0), "no layer"
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 5, logCol: 2, logCell: "1500")
    doAssert st.settle(st.jobs.active.len == 0 and st.survey.bounds.maxX == 1500),
      "the layer was not made again: " & $st.survey.bounds.maxX
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 2, logCol: 2, logCell: "1020")
    doAssert st.settle(st.jobs.active.len == 0 and st.entries[0].points == 5),
      "a shot given a position was not added"
    discard st.shutdown()

  block hover_names_the_row:
    var st = initAppState()
    st.apply Command(kind: ckImportShotLog, logPath: path, logMap: map, logMapped: true)
    doAssert st.settle(st.entries.len == 1), "no layer"
    let e = st.entries[0]
    let l = st.survey.layers[st.survey.find(e.layer)]
    var found = false
    for p in 0 ..< l.points[prSource].len:
      if l.points[prSource].index.x(p) == 1050:
        let info = pointInfo(st, PointRef(layer: e.layer, role: prSource, point: p), "m")
        doAssert info.title == "Shot, line 10, point 105", info.title
        doAssert "line: 10" in info.lines and "point: 105" in info.lines and
          "file: 5005" in info.lines, $info.lines
        doAssert not opensRecord(st, PointRef(layer: e.layer, role: prSource, point: p))
        found = true
    doAssert found
    discard st.shutdown()

  block removal_takes_it_off:
    var st = initAppState()
    st.apply Command(kind: ckImportShotLog, logPath: path, logMap: map, logMapped: true)
    doAssert st.settle(st.entries.len == 1), "no layer"
    st.apply Command(kind: ckRemoveShotLog, logIndex: 0)
    doAssert st.entries.len == 0 and st.survey.layers.len == 0 and st.survey.bounds.isEmpty
    discard st.shutdown()

  block no_positions_no_layer:
    let plain = dir / "plain.csv"
    let m = writeLog(plain, false)
    var st = initAppState()
    st.apply Command(kind: ckImportShotLog, logPath: plain, logMap: m, logMapped: true)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0), "not read"
    doAssert st.entries.len == 0 and st.survey.layers.len == 0
    discard st.shutdown()

  block a_hundred_thousand_shots:
    var text = "line,point,x,y\n"
    for i in 0 ..< 100_000:
      text.add "1," & $i & "," & $(1000 + (i mod 400) * 5) & "," & $(2000 + (i div 400) * 5) & "\n"
    let big = dir / "big.csv"
    writeFile(big, text)
    var m = initShotLogMap()
    m.hasHeader = true
    m.roles = @[crSourceLine, crShotPoint, crX, crY]
    let log = parseShotLog(text, m)
    let view = shots(log, m)
    let t0 = getMonoTime()
    let layer = shotLayer(view, m)
    let ms = float64((getMonoTime() - t0).inNanoseconds) / 1e6
    doAssert layer != nil and layer[].points[prSource].len == 100_000
    doAssert ms < 1000, "the layer took " & $ms & " ms"
    var st = initAppState()
    st.apply Command(kind: ckImportShotLog, logPath: big, logMap: m, logMapped: true)
    doAssert st.settle(st.entries.len == 1 and st.jobs.active.len == 0), "not read"
    let t1 = getMonoTime()
    for _ in 0 ..< 100: discard st.entries
    let per = float64((getMonoTime() - t1).inNanoseconds) / 1e6 / 100
    doAssert per < 5, "listing the layers took " & $per & " ms"
    echo "tshotmap: 100000 shots, layer ", ms.formatFloat(ffDecimal, 1), " ms, listing ",
      per.formatFloat(ffDecimal, 3), " ms"
    discard st.shutdown()

when isMainModule:
  main()
