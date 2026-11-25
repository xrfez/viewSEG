## The geometry filters ("offset disagrees with the positions", "midpoint disagrees with the
## positions") and the trace table's computed columns (`keys.distance`, `keys.offsetError`), in
## `core`, without a window, on SEG-Y files made here (24 traces of one record, the source at
## (1000, 5000), the receivers 100 apart east of it):
##
## - correct geometry: nothing flagged, both filters done;
## - one trace's offset header 50 off, one receiver moved 30 in its coordinates and not its
##   offset, one midpoint 40 off: those traces, and no other, flagged; the counts and the
##   traces equal processSEG's `checkGeometryInto` on the same keys; the table's columns give
##   the offset error and the distance of each trace;
## - no offsets and no coordinates in the headers: neither filter finds anything, and the
##   line says how many traces were not judged;
## - coordinates in degrees: not judged, with the reason in the filters' note and the line, the
##   table's columns empty; offsets and coordinates in different units: not judged;
## - a station move re-runs the check on the moved keys, and forgetting it again.
##
## Seen to fail: with the job's key leaving out the file's `keysRevision`, the station move
## left the flagged trace flagged; with the units guard returning `judged` for degrees, every
## trace of the degrees file was flagged for its offset; with `checkGeometryOf` marking the
## traces of the midpoint filter with the offset's flags, trace 12 (midpoint 40 off) was not
## marked.

import std/[math, os, strutils]
import parseSEG
import parseSEG/model/traceindex
import processSEG/core/rows
import processSEG/qc/geometry
import viewSEG/core/[state, tracetable]
import utils/[farsurvey, fixtures, waiting]

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
    units = 0): string =
  ## The file; `units` the coordinate units code of its trace headers (0 none, 3 degrees).
  result = fx.dir / name
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    measurementSystem: (if units > 0: 0 else: 1), # (degrees: the offsets name no unit)
    text: @["C01 viewSEG test fixture: a record with its geometry"]))
  var buf = newSeq[float32](16)
  for i in 0 ..< Traces:
    for j in 0 ..< buf.len: buf[j] = float32(i + 1)
    var overrides: seq[HeaderOverride] = @[]
    if units > 0:
      overrides.add HeaderOverride(name: "trace.coordinateUnits", value: toFieldValue(units))
    w.writeTrace(keysOf(i, planted, coordinates, angles = units == 3), buf, overrides)
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
    st.recordQc.hits[mfMidpointOff].state != fsComputing

proc withGeometry(st: var AppState) =
  st.on({mfOffsetOff, mfMidpointOff})
  doAssert st.settle(st.checked), "the geometry check did not end"

proc table(st: var AppState; view: TableView): TableAnswer =
  st.apply Command(kind: ckInspect, inspect: {ipTable}, table: view)
  doAssert st.settle(not st.inspection.waiting and st.inspection.answer.table.view == view),
    "no answer for " & $view
  st.inspection.answer.table

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
      doAssert st.recordQc.geometry.geometryWords == "", st.recordQc.geometry.geometryWords
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
      doAssert h[mfOffsetOff].count == 0 and h[mfMidpointOff].count == 0
      let words = st.recordQc.geometry.geometryWords
      doAssert words == "24 traces give no offset; 24 give no positions: not judged.", words
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
      let words = st.recordQc.geometry.geometryWords
      doAssert words.startsWith("Geometry not judged:") and "degrees" in words, words
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

  block aStationMove:
    withFixtures fx:
      let own = fx.twoSetSegd()
      var st = initAppState(indexCache = fx.dir / "cache")
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: own)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
        st.survey.findTraces(st.sessions[0].id) >= 0)
      let base = st.sessions[0].base
      # a header offset 50 off, on the trace of receiver line 100, point 101
      st.sessions[0].filePtr[].mindex.keys[2].offset += 50
      st.withGeometry
      doAssert st.filterHits[mfOffsetOff].traces == @[base + 2], $st.filterHits[mfOffsetOff]
      st.apply Command(kind: ckStationMove, moveLine: 100, movePoint: 101, moveIndex: 1,
        moveX: 500100, moveY: 6000000, moveWasX: 500000.0, moveWasY: 6000000.0,
        moveHasWas: true, moveNote: "moved in the field")
      doAssert st.settle(st.sessions[0].file.index.keys[2].rcvX == 500100)
      doAssert st.settle(st.checked), "not checked again"
      # the move recomputes the trace's offset from the new position: it agrees now
      doAssert st.filterHits[mfOffsetOff].traces.len == 0, $st.filterHits[mfOffsetOff]
      st.apply Command(kind: ckStationMove, moveLine: 100, movePoint: 101, moveIndex: 1,
        moveForget: true)
      doAssert st.settle(st.sessions[0].file.index.keys[2].rcvX == 500000)
      doAssert st.settle(st.checked and st.filterHits[mfOffsetOff].traces == @[base + 2]),
        "forgetting the move did not bring the flag back: " & $st.filterHits[mfOffsetOff]
      st.shutdown()

  echo "tgeometryqc: ok"

when isMainModule:
  main()
