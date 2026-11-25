## The geometry filter "header position disagrees with the survey" and the trace table's
## computed columns (`keys.distance`, `keys.offsetError`, the position error), in `core`,
## without a window.
##
## On SEG-Y files made here (24 traces of one record, the source at (1000, 5000), the receivers
## 100 apart east of it):
## - no survey: the position filter is not judged and says so;
## - one trace's offset header 50 off, one receiver moved 30 in its coordinates and not its
##   offset: the table's columns give the offset error and the distance of each trace;
## - coordinates in degrees: not judged, the table's columns empty.
## On `mapSps`'s survey and a SEG-Y shot of it (a receiver's header position 30 east):
## - joined in fill mode, and in replace mode: the position filter flags the moved receiver;
## - coordinates in feet against a survey in metres: not judged, with the sentence, instead of
##   flagging every trace.
## On a SEG-D file joined to a survey whose receivers sit 50 m from its headers: the position
## filter flags the 12 receivers, 50 m off, and says they share one shift; its one source,
## 25 m from the survey's, is said and marked at the source, never on the receivers' traces;
## a second join over the first compares the file's own headers again.
## On a survey of one source and a line of receivers, and a SEG-Y shot of it:
## - receivers laid 2 to 3 m from the pre-plot (30 of them, or 15): none marked at the default
##   tolerance (5 m), all at a tolerance of 1;
## - every receiver 50 m east: all marked, and the shift said with its bearing;
## - 26 receivers 50 m east and 4 at 170 m: the shift said for the 26, the 4 counted apart as
##   further off, all 30 marked and the 4 known (`furtherTraces`);
## - a record of 3 receivers whose every coordinate is in feet against a survey in metres: not
##   judged with the units sentence, never a source said millions of metres off;
## - one receiver 5.5 m off: marked, the trace table's position error says 5.5; moved to its
##   header position, not marked, and counted as moved;
## - a stale index cache: the header positions are not judged, the file is not walked; once the
##   cache is current again, the next check reads them (the "no index" is not kept);
## - the record's own headers read once across filter toggles, and again after the vendor maps
##   are loaded again;
## - a record whose samples cannot be read, or whose read hangs, keeps its geometry filter.
##
## Seen to fail: with the units guard returning `judged` for degrees, every trace of the
## degrees file was flagged; with the positions compared with the keys' (the survey's) and not
## the file's own, a join over a join flagged nothing. With the tolerance back at 1 and the
## rule that a record whose stations nearly all differ is not judged, the 30 and the 15
## receivers laid 2 to 3 m off failed (not judged; all marked), and so did the line 50 m east
## (not judged); with the survey's position compared and not the move's, the moved station
## stayed marked; with a source's error put on every trace, the SEG-D record marked 24; with
## the stale cache followed by a walk, the read was judged; with no cache of the own headers, a
## toggle read them again; with the geometry posted with the samples' result, a hung read left
## it computing. With the stations off the shift not counted, "4 more are further off" was
## missing; with the scale test only for 5 stations and more, the 3-receiver record said "The
## source 1/1001 is 1155306 m from the survey"; with the "no index" answer kept, the record
## stayed not judged after its cache was made current; with the own headers kept over a load
## of the vendor maps, they were not read again.
## With a station counted as further off only when it was also more than the shift away from
## the survey, one 50 m west of a record shifted 50 m east was not counted.

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
  st.recordQc.job == NoJob and st.recordQc.hits[mfPositionOff].state != fsComputing

proc withGeometry(st: var AppState) =
  st.on({mfPositionOff})
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

  block noSurvey:
    withFixtures fx:
      var st = initAppState()
      st.shown fx.geometrySegy("right.sgy")
      st.withGeometry
      let h = st.filterHits
      doAssert st.recordQc.geometry.ready
      # no survey is joined: the position filter says so, and shows no count
      doAssert h[mfPositionOff].state == fsNotChecked and
        "no survey is imported" in h[mfPositionOff].note, $h[mfPositionOff]
      doAssert st.recordQc.geometry.geometryLines ==
        @["Header positions not judged: no survey is imported."],
        $st.recordQc.geometry.geometryLines
      st.shutdown()

  block offsetErrorColumn:
    withFixtures fx:
      let path = fx.geometrySegy("planted.sgy", planted = true)
      var st = initAppState()
      st.shown path
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

  block coordinatesInDegrees:
    withFixtures fx:
      var st = initAppState()
      st.shown fx.geometrySegy("degrees.sgy", units = 3)
      st.withGeometry
      let h = st.filterHits
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
    # a length without a unit, and the bearings
    doAssert lengthWords(1, suNotGiven) == "1 unit" and lengthWords(5, suNotGiven) == "5 units"
    doAssert lengthWords(5, suMetres) == "5 m" and lengthWords(16, suFeet) == "16 ft" and
      lengthWords(5.5, suMetres) == "5.5 m" and lengthWords(49.7, suMetres) == "50 m"
    doAssert bearingWords(50, 0) == "east" and bearingWords(0, 50) == "north" and
      bearingWords(-30, -30) == "south-west" and bearingWords(-50, 1) == "west"
    doAssert positionTolerance(0, suMetres) == 5 and positionTolerance(0, suFeet) == 16 and
      positionTolerance(0, suNotGiven) == 5 and positionTolerance(2, suFeet) == 2
    # the settings keep a tolerance in its range, the default for one that is no number
    doAssert boundedTolerance(0) == 0 and boundedTolerance(2.5) == 2.5 and
      boundedTolerance(0.01) == MinPositionTolerance and
      boundedTolerance(5000) == MaxPositionTolerance and boundedTolerance(NaN) == 0 and
      boundedTolerance(-3) == 0 and boundedTolerance(Inf) == 0
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

  block joinedSegy:
    # `surveySps`'s survey and a SEG-Y shot of it: channel 12's receiver position 30 east of
    # its station
    for mode in [hcFill, hcReplace]:
      withFixtures fx:
        let sps = fx.surveySps()
        let shot = fx.surveyShotSegy("shot.sgy", movedReceiver = 11)
        var st = initAppState(indexCache = fx.dir / "cache")
        st.shown shot
        st.withGeometry
        let base = st.sessions[0].base
        doAssert st.filterHits[mfPositionOff].state == fsNotChecked and
          "no survey is imported" in st.filterHits[mfPositionOff].note
        st.joinTo(sps, mode)
        let h = st.filterHits
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
      # the 12 receivers of line 100, 50 m off, marked and said to share the shift; the one
      # source, 25 m off, said and marked at the source; line 101 is not in the survey
      doAssert h[mfPositionOff].state == fsDone and h[mfPositionOff].count == 12, $h[mfPositionOff]
      var g = st.recordQc.geometry
      doAssert g.receiversOff == 12 and g.sourcesOff == 1 and
        near(g.positionDistance[2], 50.0), $g.positionDistance
      doAssert h[mfPositionOff].sources.len == 1, $h[mfPositionOff].sources
      var lines = g.geometryLines
      doAssert "12 stations sit about 50 m west of the survey (the same shift for all of them: " &
        "check the survey file or the coordinate frame); 1 more is further off." in lines, $lines
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
      lines = g.geometryLines
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
      let lines = st.recordQc.geometry.geometryLines
      doAssert "30 stations sit about 50 m east of the survey (the same shift for all of them: " &
        "check the survey file or the coordinate frame)." in lines, $lines
      doAssert st.recordQc.geometry.furtherOff == 0
      st.shutdown()

  block aShiftAndFurther:
    # 26 receivers 50 m east, 4 at 170 m: the shift said for the 26, the 4 counted apart;
    # all 30 marked, the 4 known
    withFixtures fx:
      const Far = [3, 10, 17, 24]
      var off = shifted(30, 50, 0)
      for i in Far: off[i] = (170.0, 0.0)
      var st = fx.onLine(off)
      let base = st.sessions[0].base
      let h = st.filterHits
      let g = st.recordQc.geometry
      doAssert h[mfPositionOff].state == fsDone and h[mfPositionOff].traces.len == 30,
        $h[mfPositionOff]
      doAssert g.shift.stations == 26 and g.furtherOff == 4, $g.shift & " " & $g.furtherOff
      var further: seq[int] = @[]
      for i in Far: further.add base + i
      doAssert g.furtherTraces == further, $g.furtherTraces
      doAssert "26 stations sit about 50 m east of the survey (the same shift for all of them: " &
        "check the survey file or the coordinate frame); 4 more are further off." in
        g.geometryLines, $g.geometryLines
      st.shutdown()

  block aShiftAndOneTheOtherWay:
    # 29 receivers 50 m east, one 50 m west: its own distance (50 m) is no more than the
    # shift's, but it is 100 m from the shift: counted as further off
    withFixtures fx:
      var off = shifted(30, 50, 0)
      off[12] = (-50.0, 0.0)
      var st = fx.onLine(off)
      let base = st.sessions[0].base
      let g = st.recordQc.geometry
      doAssert g.shift.stations == 29 and g.furtherOff == 1, $g.shift & " " & $g.furtherOff
      doAssert g.furtherTraces == @[base + 12], $g.furtherTraces
      st.shutdown()

  block aSmallRecordInFeet:
    # 3 receivers and the source, every coordinate 3.28084 times the survey's: too few for a
    # share, but each is scaled: not judged with the units, no source said far off
    withFixtures fx:
      let sps = fx.lineSurvey("small", 3)
      var st = initAppState(indexCache = fx.dir / "cache")
      st.shown fx.lineShot("small.sgy", shifted(3, 0, 0), scale = 3.28084)
      st.withGeometry
      st.joinTo(sps, hcFill)
      let h = st.filterHits
      doAssert h[mfPositionOff].state == fsNotChecked and h[mfPositionOff].sources.len == 0 and
        "look like feet and the survey's like metres (4 of 4 stations)" in
        h[mfPositionOff].note, $h[mfPositionOff]
      for line in st.recordQc.geometry.geometryLines:
        doAssert not line.startsWith("The source"), line
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
      let lines = st.recordQc.geometry.geometryLines
      doAssert "1 station moved to agree with the headers." in lines, $lines
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
      # the cache current again: the next check reads the headers (the answer was not kept)
      let s = st.sessions[0]
      var disk = openSeismic(s.path, keys = true)
      disk.saveIndex(indexCacheFile(st.indexCache, s.path))
      disk.close()
      st.tolerance(2)
      doAssert st.filterHits[mfPositionOff].state == fsDone and
        st.filterHits[mfPositionOff].traces.len == 0, $st.filterHits[mfPositionOff]
      st.shutdown()

  # ---- with the file system's calls counted, and failing where asked
  install()

  block ownHeadersReadOnce:
    withFixtures fx:
      var st = fx.onLine(asLaid(24))
      let path = st.sessions[0].path
      let before = calls(foHeaders, path)
      for round in 0 ..< 3:
        for filters in [{mfPositionOff}, {mfDead, mfPositionOff}]:
          st.on(filters)
          doAssert st.settle(st.checked and st.recordQc.geometry.ready)
      doAssert calls(foHeaders, path) == before, "the own headers read again: " &
        $(calls(foHeaders, path) - before)
      doAssert st.filterHits[mfPositionOff].state == fsDone
      # the vendor maps loaded again: what was read with the others is read again
      let gen = st.vendorGen
      st.apply Command(kind: ckReloadVendors)
      doAssert st.settle(st.vendorGen > gen and st.checked and st.recordQc.geometry.ready and
        st.jobs.active.len == 0)
      doAssert calls(foHeaders, path) > before, "the own headers kept over a load of the maps"
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
