## The geometry filters ("offset disagrees with the positions", "midpoint disagrees with the
## positions", "header position disagrees with the survey") and the trace table's computed
## columns (`keys.distance`, `keys.offsetError`), in `core`, without a window.
##
## On SEG-Y files made here (24 traces of one record, the source at (1000, 5000), the receivers
## 100 apart east of it):
## - correct geometry: nothing flagged, the filters done; no survey: the position filter is not
##   judged and says so;
## - one trace's offset header 50 off, one receiver moved 30 in its coordinates and not its
##   offset, one midpoint 40 off: those traces, and no other, flagged; the counts and the
##   traces equal processSEG's `checkGeometryInto` on the same keys; the table's columns give
##   the offset error and the distance of each trace;
## - no offsets and no coordinates: no filter has a trace to compare, the line says how many
##   traces were not judged, and no "(0)" stands for a comparison never made;
## - coordinates in degrees: not judged, the table's columns empty; offsets that are all the
##   distance times 3.28084 (feet against metres): not judged, with the sentence.
## On `mapSps`'s survey and a SEG-Y shot of it (a trace's offset 50 over, a receiver's header
## position 30 east):
## - joined in fill mode, and in replace mode: the offset is still compared with the file's own
##   header (the keys' were computed), the position filter flags the moved receiver;
## - a second join over the first: the file's own headers are compared again;
## - coordinates in feet against a survey in metres: the position and offset filters are not
##   judged, with the sentences, instead of flagging every trace;
## On a SEG-D file joined to a survey whose receivers sit 50 m from its headers: the offset and
## midpoint filters are not judged (the format has no offset of its own), and the position
## filter flags the 12 receivers, 50 m off, and says they share one shift; its one source,
## 25 m from the survey's, is said and marked at the source, never on the receivers' traces.
## On a survey of one source and a line of receivers, and a SEG-Y shot of it:
## - receivers laid 2 to 3 m from the pre-plot (30 of them, or 15): none marked at the default
##   tolerance (5 m), all at a tolerance of 1;
## - every receiver 50 m east: all marked, and the shift said with its bearing;
## - one receiver 5.5 m off: marked, the trace table's position error says 5.5; moved to its
##   header position, not marked, and counted as moved;
## - headers with no offset and no midpoint after a replace join: neither invented: not given;
## - a stale index cache: the header positions are not judged, the file is not walked;
## - the record's own headers read once across filter toggles;
## - a record whose samples cannot be read, or whose read hangs, keeps its geometry filters.
##
## Seen to fail: with the offset of a joined SEG-Y file compared as the keys give it, a replace
## join showed 0; with the units guard returning `judged` for degrees, every trace of the
## degrees file was flagged; with a SEG-D file's offsets compared, 0 was shown for it; with
## the positions compared with the keys' (the survey's) and not the file's own, a join over a
## join flagged nothing. With the tolerance back at 1 and the rule that a record whose stations
## nearly all differ is not judged, the 30 and the 15 receivers laid 2 to 3 m off failed
## (not judged; all marked), and so did the line 50 m east (not judged); with the survey's
## position compared and not the move's, the moved station stayed marked; with a source's
## error put on every trace, the SEG-D record marked 24; with the keys' offset compared where
## the header gives none, the replace join invented an offset error; with the stale cache
## followed by a walk, the read was judged; with no cache of the own headers, a toggle read
## them again; with the geometry posted with the samples' result, a hung read left it
## computing.

import std/[math, options, os, strutils]
import parseSEG
import parseSEG/model/traceindex
import processSEG/core/rows
import processSEG/qc/geometry
import viewSEG/core/[filejobs, filesystem, geometryqc, state, tracetable]
import utils/[farsurvey, faultyfs, fixtures, waiting]

func near(a, b: float64): bool =
  abs(a - b) <= 0.01

const
  Traces = 24
  Gap = 100.0
  Origin = 1000.0  ## the source's easting (a position at 0, 0 is no position)
  Northing = 5000.0
  BadOffset = 5    ## its offset header is 50 over the distance
  Moved = 9        ## its receiver is 30 east of where its offset says
  BadMidpoint = 12 ## its midpoint is 40 off

proc keysOf(i: int; planted: bool; coordinates = true; angles = false): TraceKeys =
  ## Trace `i` (0-based): the receiver `Gap` · (i + 1) east of the source.
  result = initTraceKeys()
  result.record = 7
  result.channel = float64(i + 1)
  (result.t0Ms, result.intervalUs, result.status) = (0.0, 2000.0, tsLive)
  if angles:
    # degrees east of 12.5, 55.1 north; the offsets stay lengths
    let x = 0.001 * float64(i + 1)
    (result.srcX, result.srcY, result.rcvX, result.rcvY) = (12.5, 55.1, 12.5 + x, 55.1)
    result.offset = Gap * float64(i + 1)
  elif coordinates:
    let x = Gap * float64(i + 1)
    (result.srcX, result.srcY, result.rcvX, result.rcvY) = (Origin, Northing, Origin + x,
      Northing)
    result.offset = x
    (result.cmpX, result.cmpY) = (Origin + x / 2, Northing)
    if planted:
      if i == BadOffset: result.offset += 50
      if i == Moved: result.rcvX += 30
      if i == BadMidpoint: result.cmpX += 40
  else:
    result.offset = 0

proc geometrySegy(fx: Fixtures; name: string; planted = false; coordinates = true;
    units = 0; offsetScale = 1.0; count = Traces): string =
  ## The file; `units` the coordinate units code of its trace headers (0 none, 3 degrees),
  ## `offsetScale` the factor its offsets are the distance times.
  result = fx.dir / name
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    measurementSystem: (if units > 0: 0 else: 1), # (degrees: the offsets name no unit)
    text: @["C01 viewSEG test fixture: a record with its geometry"]))
  var buf = newSeq[float32](16)
  for i in 0 ..< count:
    for j in 0 ..< buf.len: buf[j] = float32(i + 1)
    var overrides: seq[HeaderOverride] = @[]
    if units > 0:
      overrides.add HeaderOverride(name: "trace.coordinateUnits", value: toFieldValue(units))
    var k = keysOf(i, planted, coordinates, angles = units == 3)
    k.offset *= offsetScale
    w.writeTrace(k, buf, overrides)
  let log = w.close()
  doAssert log.len == 0, $log

proc on(st: var AppState; filters: set[MapFilter]) =
  var s = st.settings
  s.map.filters = filters
  st.apply Command(kind: ckSettings, settings: s)

proc shown(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)

template checked(st: AppState): bool =
  st.recordQc.job == NoJob and st.recordQc.hits[mfOffsetOff].state != fsComputing and
    st.recordQc.hits[mfMidpointOff].state != fsComputing and
    st.recordQc.hits[mfPositionOff].state != fsComputing

proc withGeometry(st: var AppState) =
  st.on({mfOffsetOff, mfMidpointOff, mfPositionOff})
  doAssert st.settle(st.checked), "the geometry check did not end"

proc table(st: var AppState; view: TableView): TableAnswer =
  st.apply Command(kind: ckInspect, inspect: {ipTable}, table: view)
  doAssert st.settle(not st.inspection.waiting and st.inspection.answer.table.view == view),
    "no answer for " & $view
  st.inspection.answer.table

proc joinTo(st: var AppState; sps: SpsPaths; mode: HeaderCoordinates) =
  ## Joins the shown file to the survey `sps`, and waits for its geometry checks again.
  let before = st.joinReport.serial
  st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id,
    joinFiles: @[JoinFile(path: sps.s, kind: jkSps), JoinFile(path: sps.r, kind: jkSps),
      JoinFile(path: sps.x, kind: jkSps)], joinOptions: JoinOptions(coordinates: mode),
    joinUnits: JoinUnits(survey: suMetres))
  doAssert st.settle(st.joinReport.serial > before and st.joinUnderWay.job == NoJob)
  doAssert st.joins.len == 1, "joined to nothing: " & $st.joinReport.words
  doAssert st.settle(st.checked and st.filterHits[mfPositionOff].state != fsComputing)

const
  LineFfid = 11
    ## the field record of `lineShot`
  LineSource = (x: OriginX + 100.0, y: OriginY + 60.0) ## `lineSurvey`'s one source

func lineReceiver(i: int): tuple[x, y: float64] =
  ## `lineSurvey`'s receiver `i` (0-based): point 101 + i of line 100, 25 m apart.
  (OriginX + GroupM * float64(i), OriginY)

proc lineSurvey(fx: Fixtures; name: string; n: int): SpsPaths =
  ## A survey of one source (line 1, point 1001) and `n` receivers of line 100 (SPS 2.1, no
  ## grid units), and the X record of field record `LineFfid` from the source to them all.
  result = (fx.dir / (name & ".s"), fx.dir / (name & ".r"), fx.dir / (name & ".x"))
  let header = SpsHeader(code: "00", description: "SPS format version num.", data: "SPS 2.1;")
  proc point(kind: SpsPointKind; line, pt, x, y: float64): SpsPoint =
    SpsPoint(kind: kind, line: line, point: pt, index: 1, code: "G1", easting: x, northing: y,
      elevation: Elevation, dayOfYear: -1, hour: -1, minute: -1, second: -1)
  var sf, rf, xf = SpsFile(headers: @[header])
  sf.points.add point(pkSource, SrcLine, FirstSrcPoint, LineSource.x, LineSource.y)
  for i in 0 ..< n:
    rf.points.add point(pkReceiver, RcvLine, FirstRcvPoint + float64(i), lineReceiver(i).x,
      lineReceiver(i).y)
  xf.relations.add SpsRelation(fieldRecord: LineFfid, recordIncrement: 1, instrumentCode: '1',
    srcLine: SrcLine, srcPoint: FirstSrcPoint, srcIndex: 1, fromChannel: 1, toChannel: n,
    channelIncrement: 1, rcvLine: RcvLine, fromReceiver: FirstRcvPoint,
    toReceiver: FirstRcvPoint + float64(n - 1), rcvIndex: 1)
  for (f, path) in [(sf, result.s), (rf, result.r), (xf, result.x)]:
    let log = writeSps(f, path)
    doAssert log.len == 0, $log

proc lineShot(fx: Fixtures; name: string; off: openArray[tuple[dx, dy: float64]];
    scale = 1.0; offsets = true): string =
  ## The shot of `lineSurvey` with `off.len` receivers as a SEG-Y file (its headers name no
  ## station: the join finds them by the field record): receiver i's header position `off[i]`
  ## from the survey's, every coordinate `scale` times; the offsets and midpoints of the header
  ## positions, or none (0) without `offsets`.
  result = fx.dir / name
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
    text: @["C01 viewSEG test fixture: a shot of a line"]))
  var buf = newSeq[float32](16)
  for i in 0 ..< off.len:
    var k = initTraceKeys()
    (k.record, k.channel, k.srcPoint) = (float64(LineFfid), float64(i + 1), FirstSrcPoint)
    (k.t0Ms, k.intervalUs, k.status) = (0.0, DtMs * 1000, tsLive)
    let (x, y) = (lineReceiver(i).x + off[i].dx, lineReceiver(i).y + off[i].dy)
    (k.srcX, k.srcY, k.rcvX, k.rcvY) = (LineSource.x * scale, LineSource.y * scale, x * scale,
      y * scale)
    if offsets:
      k.offset = hypot(k.rcvX - k.srcX, k.rcvY - k.srcY)
      (k.cmpX, k.cmpY) = ((k.srcX + k.rcvX) / 2, (k.srcY + k.rcvY) / 2)
    else:
      k.offset = 0
    for j in 0 ..< buf.len: buf[j] = float32(i + 1)
    w.writeTrace(k, buf)
  let log = w.close()
  doAssert log.len == 0, $log

func asLaid(n: int): seq[tuple[dx, dy: float64]] =
  ## `n` receivers laid 2 to 3 m from the pre-plot, each its own way.
  for i in 0 ..< n:
    let (r, a) = (2.0 + 0.5 * float64(i mod 3), 2.39996 * float64(i)) # (the golden angle)
    result.add (r * cos(a), r * sin(a))

func shifted(n: int; dx, dy: float64): seq[tuple[dx, dy: float64]] =
  for i in 0 ..< n: result.add (dx, dy)

proc tolerance(st: var AppState; t: float64) =
  var s = st.settings
  s.map.positionTolerance = t
  st.apply Command(kind: ckSettings, settings: s)
  doAssert st.settle(st.checked and st.recordQc.geometry.ready)

proc onLine(fx: Fixtures; off: openArray[tuple[dx, dy: float64]]; mode = hcReplace;
    offsets = true): AppState =
  ## The shot of `off` shown, joined to its line's survey, its geometry checked.
  let sps = fx.lineSurvey("line", off.len)
  result = initAppState(indexCache = fx.dir / "cache")
  result.shown fx.lineShot("line.sgy", off, offsets = offsets)
  result.withGeometry
  result.joinTo(sps, mode)

proc main*() =

  block correctGeometry:
    withFixtures fx:
      var st = initAppState()
      st.shown fx.geometrySegy("right.sgy")
      st.withGeometry
      let h = st.filterHits
      for f in [mfOffsetOff, mfMidpointOff]:
        doAssert h[f].state == fsDone and h[f].count == 0 and h[f].traces.len == 0,
          $f & ": " & $h[f]
      doAssert "1 m or 1%" in h[mfOffsetOff].note,
        "the tolerance in the survey's unit: " & h[mfOffsetOff].note
      doAssert st.recordQc.geometry.ready and st.recordQc.geometry.traces == Traces
      doAssert st.recordQc.geometry.geometryLines(true, true, false) == @[],
        $st.recordQc.geometry.geometryLines(true, true, false)
      # no survey is joined: the position filter says so, and shows no count
      doAssert h[mfPositionOff].state == fsNotChecked and
        "no survey is imported" in h[mfPositionOff].note, $h[mfPositionOff]
      st.shutdown()

  block plantedTraces:
    withFixtures fx:
      let path = fx.geometrySegy("planted.sgy", planted = true)
      var st = initAppState()
      st.shown path
      st.withGeometry
      let base = st.sessions[0].base
      let h = st.filterHits
      doAssert h[mfOffsetOff].traces == @[base + BadOffset, base + Moved],
        "offset: " & $h[mfOffsetOff].traces
      doAssert h[mfOffsetOff].count == 2 and h[mfOffsetOff].state == fsDone
      doAssert h[mfMidpointOff].traces == @[base + Moved, base + BadMidpoint],
        "midpoint: " & $h[mfMidpointOff].traces
      # the library's own, on the same keys
      let f = st.sessions[0].filePtr
      var checks = newSeq[GeometryCheck](Traces)
      checkGeometryInto(f[].rowsOf(0 ..< Traces), checks)
      var offset, midpoint: seq[int]
      for t in flaggedRows(checks, {gfOffsetMismatch}): offset.add base + t
      for t in flaggedRows(checks, {gfMidpointMismatch}): midpoint.add base + t
      doAssert offset == h[mfOffsetOff].traces and midpoint == h[mfMidpointOff].traces,
        "not the library's: " & $offset & " " & $midpoint
      # the table's columns: the offset error (offset less distance) and the distance
      let a = st.table(TableView(fields: @["keys.distance", "keys.offsetError"],
        scope: tsRecord, rows: 0 ..< Traces))
      doAssert a.values.len == Traces, $a.values.len
      doAssert abs(a.values[0][0] - Gap) < 1e-6 and abs(a.values[0][1]) < 1e-6, $a.values[0]
      doAssert abs(a.values[BadOffset][1] - 50) < 1e-6, $a.values[BadOffset]
      doAssert abs(a.values[Moved][0] - (Gap * (Moved + 1) + 30)) < 1e-6 and
        abs(a.values[Moved][1] + 30) < 1e-6, $a.values[Moved]
      doAssert keyLabel("keys.offsetError").len > 0 and keyLabel("keys.distance").len > 0
      st.shutdown()

  block noOffsetsNoPositions:
    withFixtures fx:
      var st = initAppState()
      st.shown fx.geometrySegy("bare.sgy", coordinates = false)
      st.withGeometry
      let h = st.filterHits
      for f in [mfOffsetOff, mfMidpointOff]:
        doAssert h[f].state == fsNotChecked, "no comparison was made, and " & $f & " says (0)"
      let lines = st.recordQc.geometry.geometryLines(true, true, true)
      doAssert "24 traces give no offset; 24 give no midpoint; 24 give no positions: " &
        "not judged." in lines, $lines
      doAssert lines.len == 4 and lines[0].startsWith("Offset not judged"), $lines
      st.shutdown()

  block coordinatesInDegrees:
    withFixtures fx:
      var st = initAppState()
      st.shown fx.geometrySegy("degrees.sgy", units = 3)
      st.withGeometry
      let h = st.filterHits
      for f in [mfOffsetOff, mfMidpointOff]:
        doAssert h[f].state == fsNotChecked and h[f].traces.len == 0 and h[f].count == 0, $h[f]
        doAssert "degrees" in h[f].note, h[f].note
      let lines = st.recordQc.geometry.geometryLines(true, true, true)
      doAssert lines[0].startsWith("Offset not judged:") and "degrees" in lines[0], $lines
      doAssert h[mfPositionOff].state == fsNotChecked and "degrees" in h[mfPositionOff].note
      # the table's columns are empty, not the mismatch of every trace
      let a = st.table(TableView(fields: @["keys.distance", "keys.offsetError", "keys.offset"],
        scope: tsRecord, rows: 0 ..< Traces))
      doAssert a.values.len == Traces and a.values[3][0].isNaN and a.values[3][1].isNaN and
        a.values[3][2] == Gap * 4, $a.values[3]
      st.shutdown()

  block unitsThatDiffer:
    doAssert geometryUnits(suMetres, suMetres).judged
    doAssert geometryUnits(suNotGiven, suFeet).judged and geometryUnits(suMetres,
      suNotGiven).unit == suMetres
    doAssert geometryUnits(suFeet, suUsFeet).judged, "the two feet are one length"
    for u in [suDegrees, suArcSeconds, suDms]:
      for offsets in [suNotGiven, suMetres]:
        let g = geometryUnits(u, offsets)
        doAssert not g.judged and $u in g.why, g.why
    let g = geometryUnits(suFeet, suMetres)
    doAssert not g.judged and "metres" in g.why and "feet" in g.why, g.why

  block wordsAndColumns:
    var g = GeometrySummary(ready: true, noOffset: 1, noPositions: 1)
    doAssert g.geometryLines(true, true, false) ==
      @["1 trace gives no offset; 1 gives no positions: not judged."],
      $g.geometryLines(true, true, false)
    # a length without a unit, and the bearings
    doAssert lengthWords(1, suNotGiven) == "1 unit" and lengthWords(5, suNotGiven) == "5 units"
    doAssert lengthWords(5, suMetres) == "5 m" and lengthWords(16, suFeet) == "16 ft" and
      lengthWords(5.5, suMetres) == "5.5 m" and lengthWords(49.7, suMetres) == "50 m"
    doAssert bearingWords(50, 0) == "east" and bearingWords(0, 50) == "north" and
      bearingWords(-30, -30) == "south-west" and bearingWords(-50, 1) == "west"
    doAssert positionTolerance(0, suMetres) == 5 and positionTolerance(0, suFeet) == 16 and
      positionTolerance(0, suNotGiven) == 5 and positionTolerance(2, suFeet) == 2
    g.noOffset = 0
    doAssert g.geometryLines(true, true, false) == @["1 trace gives no positions: not judged."]
    # where the units differ the distance is still a length; where the coordinates are angles
    # it is not
    var k = keysOf(3, false)
    doAssert near(k.keyValue("keys.distance", lengths = false), Gap * 4) and
      k.keyValue("keys.offsetError", lengths = false).isNaN
    doAssert k.keyValue("keys.distance", angles = true).isNaN and
      k.keyValue("keys.offsetError", angles = true).isNaN
    # a zero offset where the source stands on the receiver agrees with the positions
    k.offset = 0
    (k.rcvX, k.rcvY) = (k.srcX, k.srcY)
    doAssert near(k.keyValue("keys.offsetError"), 0)

  block offsetsInFeet:
    # every offset is the distance times 3.28084: feet against metres, not 24 mismatches
    withFixtures fx:
      var st = initAppState()
      st.shown fx.geometrySegy("feet.sgy", offsetScale = 3.28084, count = 40)
      st.withGeometry
      let h = st.filterHits
      doAssert h[mfOffsetOff].state == fsNotChecked and h[mfOffsetOff].traces.len == 0, $h[mfOffsetOff]
      doAssert "look like feet and the positions like metres" in h[mfOffsetOff].note,
        h[mfOffsetOff].note
      doAssert h[mfMidpointOff].state == fsDone, "the midpoint does not use the offset's unit"
      st.shutdown()

  block joinedSegy:
    # `surveySps`'s survey and a SEG-Y shot of it: channel 8's offset 50 over, channel 12's
    # receiver position 30 east of its station
    for mode in [hcFill, hcReplace]:
      withFixtures fx:
        let sps = fx.surveySps()
        let shot = fx.surveyShotSegy("shot.sgy", badOffset = 7, movedReceiver = 11)
        var st = initAppState(indexCache = fx.dir / "cache")
        st.shown shot
        st.withGeometry
        let base = st.sessions[0].base
        doAssert 7 + base in st.filterHits[mfOffsetOff].traces
        doAssert st.filterHits[mfPositionOff].state == fsNotChecked and
          "no survey is imported" in st.filterHits[mfPositionOff].note
        st.joinTo(sps, mode)
        let h = st.filterHits
        # the file's own header offset is compared, whatever the join did to the keys'
        doAssert h[mfOffsetOff].state == fsDone, $h[mfOffsetOff]
        if mode == hcFill: # the positions in force are the header's: the moved one's offset too
          doAssert h[mfOffsetOff].traces == @[7 + base, 11 + base], $h[mfOffsetOff].traces
        else: # the survey's positions are in force
          doAssert h[mfOffsetOff].traces == @[7 + base], $mode & ": " & $h[mfOffsetOff].traces
        doAssert h[mfPositionOff].state == fsDone and h[mfPositionOff].traces == @[11 + base],
          $mode & ": " & $h[mfPositionOff]
        doAssert st.recordQc.geometry.receiversOff == 1 and
          st.recordQc.geometry.sourcesOff == 0, $st.recordQc.geometry
        doAssert "1 receiver off; 0 sources off" in h[mfPositionOff].note and
          "5 m" in h[mfPositionOff].note, h[mfPositionOff].note
        doAssert near(st.recordQc.geometry.positionDistance[11], 30.0)
        st.shutdown()

  block coordinatesInFeet:
    # every header position 3.28084 times the survey's: not 24 traces off
    withFixtures fx:
      let sps = fx.surveySps()
      var st = initAppState(indexCache = fx.dir / "cache")
      st.shown fx.surveyShotSegy("feet-shot.sgy", coordScale = 3.28084)
      st.joinTo(sps, hcFill)
      st.withGeometry
      let h = st.filterHits
      doAssert h[mfPositionOff].state == fsNotChecked and h[mfPositionOff].traces.len == 0 and
        "look like feet and the survey's like metres" in h[mfPositionOff].note,
        $h[mfPositionOff]
      doAssert h[mfOffsetOff].state == fsNotChecked and
        "look like metres and the positions like feet" in h[mfOffsetOff].note,
        $h[mfOffsetOff]
      st.shutdown()

  block segdAndASecondJoin:
    withFixtures fx:
      let own = fx.twoSetSegd()
      let far = fx.surveyFarther()
      let near = fx.surveySps()
      var st = initAppState(indexCache = fx.dir / "cache")
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: own)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
        st.survey.findTraces(st.sessions[0].id) >= 0)
      proc join(st: var AppState; s, r, x: string) =
        let before = st.joinReport.serial
        st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id,
          joinFiles: @[JoinFile(path: s, kind: jkSps), JoinFile(path: r, kind: jkSps),
            JoinFile(path: x, kind: jkSps)], joinOptions: JoinOptions(),
          joinUnits: JoinUnits(survey: suMetres))
        doAssert st.settle(st.joinReport.serial > before and st.joinUnderWay.job == NoJob)
        doAssert st.settle(st.checked and st.filterHits[mfPositionOff].state != fsNotChecked),
          "not checked after the join: " & $st.filterHits[mfPositionOff]
      st.withGeometry
      doAssert st.filterHits[mfPositionOff].state == fsNotChecked, "no survey is imported"
      st.join(far.s, far.r, far.x)
      var h = st.filterHits
      # SEG-D has no offset of its own: not judged, never "(0)"
      for f in [mfOffsetOff, mfMidpointOff]:
        doAssert h[f].state == fsNotChecked and "computed from the positions" in h[f].note,
          $f & ": " & $h[f]
      # the 12 receivers of line 100, 50 m off, marked and said to share the shift; the one
      # source, 25 m off, said and marked at the source; line 101 is not in the survey
      doAssert h[mfPositionOff].state == fsDone and h[mfPositionOff].count == 12, $h[mfPositionOff]
      var g = st.recordQc.geometry
      doAssert g.receiversOff == 12 and g.sourcesOff == 1 and
        near(g.positionDistance[2], 50.0), $g.positionDistance
      doAssert h[mfPositionOff].sources.len == 1, $h[mfPositionOff].sources
      var lines = g.geometryLines(false, false, true)
      doAssert "12 stations sit about 50 m west of the survey (the same shift for all: check " &
        "the survey file or the coordinate frame)." in lines, $lines
      doAssert "The source 1/1001 is 25 m from the survey." in lines, $lines
      doAssert "12 traces' stations are not in the survey: not judged." in lines, $lines
      # a second join over the first compares the file's own headers again: none off, then
      st.join(near.s, near.r, near.x)
      # one source off: said, marked at the source, and no receiver's trace marked
      g = st.recordQc.geometry
      h = st.filterHits
      doAssert g.receiversOff == 0 and g.sourcesOff == 1 and g.positionOff == 0, $g
      doAssert h[mfPositionOff].state == fsDone and h[mfPositionOff].traces.len == 0 and
        h[mfPositionOff].count == 0 and h[mfPositionOff].sources ==
        @[stationKey(SrcLine, FirstSrcPoint, 1)], $h[mfPositionOff]
      doAssert "1 source off" in h[mfPositionOff].note and "0 receivers off" in
        h[mfPositionOff].note, h[mfPositionOff].note
      lines = g.geometryLines(false, false, true)
      doAssert lines == @["The source 1/1001 is 25 m from the survey.",
        "12 traces' stations are not in the survey: not judged."], $lines
      st.join(far.s, far.r, far.x)
      doAssert st.recordQc.geometry.receiversOff == 12, $st.recordQc.geometry
      st.shutdown()

  block laidAsPlanned:
    # receivers laid 2 to 3 m from the pre-plot are where they should be at the default 5 m,
    # 30 of them or 15; at a tolerance of 1 every one is marked, and nothing is "not judged"
    for n in [30, 15]:
      withFixtures fx:
        var st = fx.onLine(asLaid(n))
        var h = st.filterHits
        doAssert h[mfPositionOff].state == fsDone and h[mfPositionOff].traces.len == 0,
          $n & ": " & $h[mfPositionOff]
        doAssert st.recordQc.geometry.tolerance == 5 and st.recordQc.geometry.shift.stations == 0
        st.tolerance(1)
        h = st.filterHits
        doAssert h[mfPositionOff].state == fsDone and h[mfPositionOff].traces.len == n,
          $n & " at 1: " & $h[mfPositionOff]
        doAssert st.recordQc.geometry.receiversOff == n and st.recordQc.geometry.tolerance == 1
        doAssert "more than 1 m" in h[mfPositionOff].note, h[mfPositionOff].note
        st.shutdown()

  block aLineEast:
    # every receiver 50 m east: all marked, the shift said with its bearing
    withFixtures fx:
      var st = fx.onLine(shifted(30, 50, 0))
      let h = st.filterHits
      doAssert h[mfPositionOff].state == fsDone and h[mfPositionOff].traces.len == 30,
        $h[mfPositionOff]
      let lines = st.recordQc.geometry.geometryLines(false, false, true)
      doAssert "30 stations sit about 50 m east of the survey (the same shift for all: check " &
        "the survey file or the coordinate frame)." in lines, $lines
      st.shutdown()

  block movedToItsHeaders:
    # one receiver 5.5 m north of its station: marked, its position error in the table; moved
    # to its header position, not marked and counted as moved (a SEG-Y file, a replace join)
    withFixtures fx:
      var off = shifted(24, 0, 0)
      off[6] = (0.0, 5.5)
      var st = fx.onLine(off)
      let base = st.sessions[0].base
      doAssert st.filterHits[mfPositionOff].traces == @[base + 6], $st.filterHits[mfPositionOff]
      let a = st.table(TableView(fields: @[PositionErrorColumn], scope: tsRecord, rows: 0 ..< 24))
      doAssert a.values.len == 24 and near(a.values[6][0], 5.5) and near(a.values[5][0], 0),
        $a.values
      doAssert keyLabel(PositionErrorColumn).len > 0
      let (x, y) = (lineReceiver(6).x, lineReceiver(6).y + 5.5)
      st.apply Command(kind: ckStationMove, moveLine: RcvLine, movePoint: FirstRcvPoint + 6,
        moveIndex: 0, moveX: x, moveY: y)
      doAssert st.settle(st.jobs.active.len == 0 and st.checked and
        st.recordQc.geometry.movedAgree == 1), "the move did not clear the station: " &
        $st.recordQc.geometry
      doAssert st.filterHits[mfPositionOff].traces.len == 0, $st.filterHits[mfPositionOff]
      let lines = st.recordQc.geometry.geometryLines(false, false, true)
      doAssert "1 station moved to agree with the headers." in lines, $lines
      st.shutdown()

  block noOffsetGiven:
    # headers that give no offset and no midpoint, after a replace join with a receiver 5.5 m
    # off: its position marked, the offset and midpoint not given, none invented
    withFixtures fx:
      var off = shifted(24, 0, 0)
      off[4] = (5.5, 0.0)
      var st = fx.onLine(off, offsets = false)
      let base = st.sessions[0].base
      let h = st.filterHits
      doAssert h[mfPositionOff].traces == @[base + 4], $h[mfPositionOff]
      for f in [mfOffsetOff, mfMidpointOff]:
        doAssert h[f].state == fsNotChecked and h[f].traces.len == 0, $f & ": " & $h[f]
      let g = st.recordQc.geometry
      doAssert g.noOffset == 24 and g.noMidpoint == 24 and g.offsetCompared == 0, $g
      let lines = g.geometryLines(true, true, false)
      doAssert "24 traces give no offset; 24 give no midpoint: not judged." in lines, $lines
      st.shutdown()

  block staleIndexCache:
    # a cache the open cannot use, on a file that may not be walked: not judged, and the walk
    # stops at its first step (a whole walk of this 3 MB file asks at every MiB)
    withFixtures fx:
      let path = fx.manyTracesSegy(400, samples = 2000)
      var st = initAppState(indexCache = fx.dir / "cache")
      st.ownReadLimit = 1
      st.shown path
      let s = st.sessions[0]
      let cache = indexCacheFile(st.indexCache, s.path)
      doAssert fileExists(cache), "no index cache written"
      let how = OwnOpen(choice: s.facts.opened.choice, cache: cache, limit: 1)
      var asked = 0
      let count = proc (): bool {.gcsafe, raises: [].} =
        inc asked
        false
      var rows: seq[OwnHeader]
      doAssert ownRowsOf(s.filePtr, s.path, 0 .. 9, how, count, rows) == "", "the cache not used"
      doAssert rows.len == 10 and asked <= 1, $asked
      writeFile(cache, "not an index cache")
      asked = 0
      doAssert ownRowsOf(s.filePtr, s.path, 0 .. 9, how, count, rows) == OwnRecordNoIndexWhy
      doAssert rows.len == 0 and asked == 1, "walked on: asked " & $asked
      st.shutdown()
    withFixtures fy:
      # in the filters: not judged, and said why (a small file, walked to its end at once, is
      # not taken either)
      let sps = fy.lineSurvey("line", 24)
      var st = initAppState(indexCache = fy.dir / "cache")
      st.shown fy.lineShot("line.sgy", shifted(24, 0, 0))
      writeFile(indexCacheFile(st.indexCache, st.sessions[0].path), "not an index cache")
      st.ownReadLimit = 1
      st.withGeometry
      st.joinTo(sps, hcFill)
      doAssert st.filterHits[mfPositionOff].state == fsNotChecked and
        "the file's own headers could not be read (no index for this file)" in
        st.filterHits[mfPositionOff].note, $st.filterHits[mfPositionOff]
      st.shutdown()

  # ---- with the file system's calls counted, and failing where asked
  install()

  block ownHeadersReadOnce:
    withFixtures fx:
      var st = fx.onLine(asLaid(24))
      let path = st.sessions[0].path
      let before = calls(foHeaders, path)
      for round in 0 ..< 3:
        for filters in [{mfPositionOff}, {mfOffsetOff, mfMidpointOff, mfPositionOff}]:
          st.on(filters)
          doAssert st.settle(st.checked and st.recordQc.geometry.ready)
      doAssert calls(foHeaders, path) == before, "the own headers read again: " &
        $(calls(foHeaders, path) - before)
      doAssert st.filterHits[mfPositionOff].state == fsDone
      st.shutdown()

  block samplesUnread:
    # the samples cannot be read: the job fails, the geometry filters stand
    withFixtures fx:
      var off = shifted(24, 0, 0)
      off[3] = (0.0, 20.0)
      var st = fx.onLine(off)
      let base = st.sessions[0].base
      let path = st.sessions[0].path
      fault(path, fkFail, {foMapped})
      st.on({mfClipped, mfPositionOff})
      doAssert st.settle(st.recordQc.job == NoJob and
        st.recordQc.hits[mfClipped].state == fsNotChecked), $st.recordQc.hits[mfClipped]
      doAssert st.filterHits[mfPositionOff].state == fsDone and
        st.filterHits[mfPositionOff].traces == @[base + 3], $st.filterHits[mfPositionOff]
      # the read hangs: the geometry filters are there while it does
      fault(path, fkHang, {foMapped})
      st.on({mfClipped, mfWeak, mfPositionOff})
      doAssert st.settle(st.recordQc.job != NoJob and
        st.recordQc.hits[mfPositionOff].state == fsDone), $st.recordQc.hits[mfPositionOff]
      doAssert st.recordQc.hits[mfClipped].state == fsComputing
      release(path)
      doAssert st.settle(st.recordQc.job == NoJob)
      st.shutdown()

  echo "tgeometryqc: ok"

when isMainModule:
  main()
