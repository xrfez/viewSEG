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
## filter flags the 12 receivers, 50 m off.
##
## Seen to fail: with the offset of a joined SEG-Y file compared as the keys give it, a replace
## join showed 0; with the units guard returning `judged` for degrees, every trace of the
## degrees file was flagged; with a SEG-D file's offsets compared, 0 was shown for it; with
## the positions compared with the keys' (the survey's) and not the file's own, a join over a
## join flagged nothing.

import std/[math, os, strutils]
import parseSEG
import parseSEG/model/traceindex
import processSEG/core/rows
import processSEG/qc/geometry
import viewSEG/core/[geometryqc, state, tracetable]
import utils/[farsurvey, fixtures, waiting]

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
      doAssert "metres" in h[mfOffsetOff].note and "1%" in h[mfOffsetOff].note,
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
      doAssert "24 traces give no offset; 24 give no positions: not judged." in lines,
        $lines
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
      @["1 trace gives no offset; 1 gives no positions: not judged."], $g.geometryLines(true, true, false)
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
        "the units or the frame differ" in h[mfPositionOff].note, $h[mfPositionOff]
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
      # (this file's one source is 25 m from the survey's: every trace has that too)
      doAssert h[mfPositionOff].state == fsDone and h[mfPositionOff].count == 24, $h[mfPositionOff]
      doAssert st.recordQc.geometry.receiversOff == 12 and
        near(st.recordQc.geometry.positionDistance[2], 50.0), $st.recordQc.geometry.positionDistance
      # a second join over the first compares the file's own headers again: none off, then
      st.join(near.s, near.r, near.x)
      doAssert st.recordQc.geometry.receiversOff == 0, $st.recordQc.geometry
      st.join(far.s, far.r, far.x)
      doAssert st.recordQc.geometry.receiversOff == 12, $st.recordQc.geometry
      st.shutdown()

  echo "tgeometryqc: ok"

when isMainModule:
  main()
