## The spread planned for a shot (the map's template box) in `core`, without
## a window, on `mapSps`'s spread:
##
## - with its X file loaded, the record shown (found by its source station,
##   as processSEG's `recordCompleteness` finds it) plans its 30 receivers,
##   and the box is their bounds; a source of the other line plans the other
##   ten points of each line; a station no X record names plans nothing;
## - with its O file loaded, a receiver gather plans the 8 sources whose X
##   records list it; with the X file alone, a receiver gather shown has the
##   O records made from the X records on a job, and the same spread;
## - with no relation file, and the template box on, the X records are
##   generated from the template on a job (said to be generated): the box of
##   the record shown is the bounds of the receivers processSEG's
##   `generateRelations` gives that shot with the same template; a new
##   template makes them again; the box off, or a relation file loaded,
##   drops what was made;
## - the box of a patch turned off north lies along its lines;
## - the record's X record is the one the map's filters' check finds
##   (`recordCompleteness`, with the record match the user chose: by
##   default, by source station, by FFID), the source found at its place:
##   the box and the filter "missing from the template" name one record.
##
## The shots are SEG-Y files with coordinates and no stations (SEG-Y keeps
## none without a header layout), so their source is the S file's station
## at its place; their FFIDs are not their X records' numbers.
##
## Seen to fail: with the X record found by the FFID alone (the source
## station passed by), "the record shown" found X record -1; with the
## template's lines and channels swapped in the job, "generated from the
## template" found 6 stations planned, not 8; with the check given the
## record's keys as they are (no station at its place), "the record shown:
## -1" (the box follows the check, which then finds no X record).

import std/[math, os, strutils]
import parseSEG
import processSEG/survey/patch
from processSEG/qc/record import rmFieldRecord, rmSourceStation
import viewSEG/core/state
import utils/[fixtures, waiting]

func near(a, b: float64): bool = abs(a - b) <= 1e-6 * max(1.0, abs(b))

proc boundsOf(b: SpreadBox): Bounds =
  result = Bounds()
  for c in b.corners: result.incl(c.x, c.y)

proc planned(lines: openArray[int]; first, count: int): Bounds =
  ## The bounds of `mapSps`'s receivers `first` .. `first + count - 1` of
  ## receiver lines `lines` (0-based).
  result = Bounds()
  for l in lines:
    for k in first ..< first + count:
      let (x, y) = mapRcv(l, k)
      result.incl(x, y)

proc same(a, b: Bounds): bool =
  near(a.minX, b.minX) and near(a.maxX, b.maxX) and near(a.minY, b.minY) and
    near(a.maxY, b.maxY)

proc loaded(st: var AppState; paths: varargs[string]): bool =
  st.apply Command(kind: ckLoadSurvey, paths: @paths)
  st.settle(st.jobs.active.len == 0 and st.survey.layers.len >= paths.len)

proc show(st: var AppState; path: string): bool =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  st.settle(st.sessions.len > 0 and st.sessions[^1].path == path.expandFilename and
    st.survey.findTraces(st.sessions[^1].id) >= 0 and st.jobs.active.len == 0)

proc boxOn(st: var AppState; filters: set[MapFilter] = {}) =
  var set = st.settings
  set.map.templateBox = true
  set.map.filters = filters
  st.apply Command(kind: ckSettings, settings: set)

proc checked(st: var AppState): bool =
  ## The record shown checked (the box's record found).
  st.settle(st.recordQc.job == NoJob and st.jobs.active.len == 0)

proc sourcePoint(st: AppState; line, k: int): PointRef =
  for i in 0 ..< st.survey.layers.len:
    template l: untyped = st.survey.layers[i]
    if l.origin == loSurveyFile:
      let p = l.stationPoint(prSource, Station(line: MapSrcLines[line], point: 1001 +
        float64(k), index: 1))
      if p >= 0: return PointRef(layer: l.id, role: prSource, point: p)
  doAssert false, "no source " & $line & "/" & $k

proc receiverPoint(st: AppState; line, k: int): PointRef =
  for i in 0 ..< st.survey.layers.len:
    template l: untyped = st.survey.layers[i]
    if l.origin == loSurveyFile:
      let p = l.stationPoint(prReceiver, Station(line: MapRcvLines[line], point: 101 +
        float64(k), index: 1))
      if p >= 0: return PointRef(layer: l.id, role: prReceiver, point: p)
  doAssert false, "no receiver " & $line & "/" & $k

proc main*() =

  block listed:
    withFixtures fx:
      let sps = fx.mapSps()
      var st = initAppState()
      doAssert st.loaded(sps.s, sps.r, fx.mapXps)
      st.boxOn()
      # A shot whose FFID is not its X record's number: found by its source
      # station (the S file's at its place: its headers name none).
      doAssert st.show(fx.mapShotSegy(0, 2)) and st.checked
      var s = st.shownSpread
      doAssert s.domain == rdSource and s.record == mapRecord(0, 2), "the record shown: " &
        $s.record
      doAssert s.byPlace
      doAssert s.stations == 3 * MapPlanned and s.places.len == 30 and s.unplaced == 0
      doAssert not s.generated and s.source == "map.x"
      doAssert s.box.shown and same(boundsOf(s.box), planned([0, 1, 2], 0, MapPlanned)),
        $boundsOf(s.box)
      # a source of the other line, under the pointer
      s = st.spreadAt(st.sourcePoint(1, 3))
      doAssert s.record == mapRecord(1, 3) and same(boundsOf(s.box), planned([0, 1, 2],
        mapPlannedFirst(1), MapPlanned)), $boundsOf(s.box)
      # a receiver plans nothing in a shot record's domain
      doAssert st.spreadAt(st.receiverPoint(0, 3)).record == -1
      doAssert st.spreads.job == NoJob and st.spreads.relations.isNil, "nothing to make"
      doAssert st.spreads.job == NoJob, "no job with X records loaded"

  block oneRecordForBoxAndFilters:
    # A SEG-Y record without stations: the box and the filters' check name
    # the same X record, found by the source at the record's place, with the
    # user's record match.
    withFixtures fx:
      let sps = fx.mapSps()
      var st = initAppState()
      doAssert st.loaded(sps.s, sps.r, fx.mapXps)
      st.boxOn({mfMissing})
      doAssert st.show(fx.mapShotSegy(1, 3)) and st.checked
      let want = mapRecord(1, 3)
      let hits = st.filterHits[mfMissing]
      doAssert hits.state == fsDone, "the filters name no X record: " & hits.note
      doAssert ("X record " & $want & " plans") in hits.note, hits.note
      doAssert st.shownSpread.record == want, $st.shownSpread.record
      # By the FFID only: neither finds one (the FFIDs are not the X records').
      var set = st.settings
      set.join.recordMatch = rmFieldRecord
      st.apply Command(kind: ckSettings, settings: set)
      doAssert st.checked
      doAssert st.shownSpread.record == -1 and st.filterHits[mfMissing].state == fsNotChecked,
        "by its FFID: X record " & $st.shownSpread.record
      set.join.recordMatch = rmSourceStation
      st.apply Command(kind: ckSettings, settings: set)
      doAssert st.checked and st.shownSpread.record == want and
        st.filterHits[mfMissing].state == fsDone

  block receiverGathers:
    withFixtures fx:
      let sps = fx.mapSps()
      var st = initAppState()
      st.boxOn()
      doAssert st.loaded(sps.s, sps.r, fx.mapXps)
      doAssert st.show(fx.mapReceiverSegy(1, 4))
      doAssert st.shownDomain == rdReceiver, "a receiver gather"
      # The O records made from the X records, on a job.
      doAssert st.settle(st.spreads.job == NoJob and not st.spreads.relations.isNil)
      doAssert st.checked
      var s = st.shownSpread
      doAssert s.domain == rdReceiver and s.generated and s.stations == MapSrcPoints,
        "made from the X records: " & $s.stations
      var want = Bounds()
      for k in 0 ..< MapSrcPoints:
        let (x, y) = mapSrc(0, k)
        want.incl(x, y)
      doAssert same(boundsOf(s.box), want), $boundsOf(s.box) & " " & $want
      doAssert st.spreads.words.len == 1, $st.spreads.words
      # A receiver under the pointer of line 1's half: the other source line.
      s = st.spreadAt(st.receiverPoint(2, 15))
      doAssert s.stations == MapSrcPoints and s.places[0].x == mapSrc(1, 0)[0]
      # The O file loaded: read, not made (and the records made go).
      doAssert st.loaded(sps.s, sps.r, fx.mapXps, fx.mapOps)
      doAssert st.settle(st.spreads.relations.isNil) and st.checked
      s = st.shownSpread
      doAssert not s.generated and s.source == "map.o" and s.stations == MapSrcPoints
      doAssert same(boundsOf(s.box), want)

  block generated:
    withFixtures fx:
      let sps = fx.mapSps()
      var st = initAppState()
      doAssert st.loaded(sps.s, sps.r)
      doAssert st.show(fx.mapShotSegy(0, 2))
      doAssert st.shownSpread.record == -1, "no relation file: nothing planned"
      var set = st.settings
      set.map.templateBox = true
      set.map.spreadTemplate = TemplateSpec(shape: tsPatch, lines: 2, channels: 4)
      st.apply Command(kind: ckSettings, settings: set)
      doAssert st.spreads.job != NoJob, "generated on a job"
      doAssert st.settle(st.spreads.job == NoJob and not st.spreads.relations.isNil)
      doAssert st.checked
      var s = st.shownSpread
      doAssert s.generated and s.source == "" and s.stations == 8, $s.stations
      # What processSEG generates for that shot with the same template.
      var g = initSurveyGeometry()
      g.addSps(sps.s)
      g.addSps(sps.r)
      let src = stationKey(MapSrcLines[0], 1003, 1)
      let xs = g.generateRelations([PatchShot(record: 1, source: src)], initPatchTemplate(2, 4))
      var want = Bounds()
      for x in xs:
        for p in int(x.fromReceiver) .. int(x.toReceiver):
          var line = 0
          for i, l in MapRcvLines:
            if l == x.rcvLine: line = i
          let (px, py) = mapRcv(line, p - 101)
          want.incl(px, py)
      doAssert same(boundsOf(s.box), want), "generated from the template: " & $boundsOf(s.box) &
        ", processSEG's " & $want
      doAssert st.spreads.words.len == 1 and "Generated from the template" in st.spreads.words[0],
        $st.spreads.words
      # Another template: made again; meanwhile the records before stay.
      set.map.spreadTemplate = TemplateSpec(shape: tsBox, inlineHalf: 60, crosslineHalf: 250)
      st.apply Command(kind: ckSettings, settings: set)
      doAssert not st.spreads.relations.isNil and st.spreads.job != NoJob
      doAssert st.settle(st.spreads.job == NoJob) and st.checked
      s = st.shownSpread
      for p in s.places:
        doAssert abs(p.x - mapSrc(0, 2)[0]) <= 60 and abs(p.y - mapSrc(0, 2)[1]) <= 250, $p
      doAssert s.stations > 0 and s.generated
      # The box off: what was made goes.
      set.map.templateBox = false
      st.apply Command(kind: ckSettings, settings: set)
      doAssert st.spreads.relations.isNil and st.spreads.job == NoJob
      # On again, then a relation file loaded: read, and what was made goes.
      set.map.templateBox = true
      st.apply Command(kind: ckSettings, settings: set)
      doAssert st.settle(st.spreads.job == NoJob and not st.spreads.relations.isNil)
      doAssert st.loaded(fx.mapXps)
      doAssert st.settle(st.spreads.relations.isNil) and st.checked
      s = st.shownSpread
      doAssert s.record == mapRecord(0, 2) and not s.generated

  block turned:
    # A patch of receivers on lines running north-east: the box lies along
    # them, as small as they allow.
    var places: seq[MapPoint]
    let (ux, uy) = (cos(PI / 6), sin(PI / 6))
    for line in 0 .. 2:
      for k in 0 .. 9:
        let (a, c) = (25.0 * float64(k), 200.0 * float64(line))
        places.add mapPoint(1000 + a * ux - c * uy, 2000 + a * uy + c * ux)
    let b = boxOf(places, mapPoint(ux, uy))
    let side = hypot(b.corners[1].x - b.corners[0].x, b.corners[1].y - b.corners[0].y)
    let across = hypot(b.corners[3].x - b.corners[0].x, b.corners[3].y - b.corners[0].y)
    doAssert near(side, 225) and near(across, 400), $side & " x " & $across

  echo "tspread: ok"

when isMainModule:
  main()
