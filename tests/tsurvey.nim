## The survey model (`core/survey`) and its spatial index (`core/spatial`),
## without jobs: the index finds what a search of every point finds, also
## for points on one spot or one line and places far outside; land traces
## share their receivers across shots and marine ones do not; missing,
## zero and auxiliary positions are counted and never raise; the planted
## SPS files and the P1 file give the stations, the duplicates and the
## counts the fixtures say; a trace finds its points in every layer (its
## file's, by trace; the survey files', by station, filled from the X
## relations when its keys have none) and a point its traces; and a
## million traces are made into a layer in under a second.
##
## Seen to fail: with `nearest`'s rings stopping one ring early (`k *
## cell` for `(k - 1) * cell`), `indexAgreesWithBruteForce` found a farther
## point than the search of every point; with the station left out of a
## point's key (its hash and its comparison), `landReceiversRepeat` merged
## two stations at one place; with `addPoint` keeping the first of a station
## given twice, `plantedSpsFile` found receiver 110 at its first place; with
## `tracePoints` not filling stations from the relations, `linksBothWays`
## found no survey point for the traces without stations.
##
## Runs alone: it bounds the time a million traces take into a layer (2 s,
##   by `ownTime`: the thread's own time, not the time it waited for a core).

import std/[math, monotimes, os, random, strutils, times]
import parseSEG
import viewSEG/core/[filekinds, session, spatial, survey]
import utils/[fixtures, owntime]

func near(a, b: float64): bool = abs(a - b) <= 1e-6 * max(1.0, abs(b))

proc bruteNearest(ix: SpatialIndex; x, y, radius: float64): int =
  result = -1
  var best = Inf
  for i in 0 ..< ix.len:
    let d = (ix.x(i) - x) ^ 2 + (ix.y(i) - y) ^ 2
    if d <= radius * radius and d < best: (best, result) = (d, i)

block indexAgreesWithBruteForce:
  var r = initRand(7)
  for trial in 0 ..< 200:
    let n = r.rand(0 .. 300)
    var xs, ys: seq[float64]
    for i in 0 ..< n:
      case trial mod 4
      of 0:
        xs.add r.rand(1000.0)
        ys.add r.rand(1000.0)
      of 1: # a 2-D line
        xs.add float64(r.rand(40)) * 25
        ys.add 6e6
      of 2: # a few spots, many points on each
        xs.add 5e5 + float64(r.rand(2))
        ys.add 6e6 + float64(r.rand(2))
      else: # long and thin
        xs.add r.gauss(0, 1) * 1e4
        ys.add r.gauss(0, 1) * 10
    var order: seq[int32]
    let ix = initSpatialIndex(xs, ys, order)
    doAssert ix.len == n and order.len == n
    for i in 0 ..< n:
      doAssert ix.x(i) == xs[order[i]] and ix.y(i) == ys[order[i]]
    for q in 0 ..< 40:
      let at = if n > 0: r.rand(n - 1) else: 0
      let qx = (if n > 0: xs[at] else: 0.0) + r.gauss(0, 60)
      let qy = (if n > 0: ys[at] else: 0.0) + r.gauss(0, 60)
      let radius = [Inf, 10.0, 0.0, 100.0, 1e9][q mod 5]
      doAssert ix.nearest(qx, qy, radius) == bruteNearest(ix, qx, qy, radius),
        $(trial, q, radius)
    if n > 0:
      let box = Bounds(minX: xs[0] - 100, maxX: xs[0] + 100, minY: ys[0] - 5, maxY: ys[0] + 5)
      var found, want: seq[int]
      for p in ix.within(box): found.add p
      for i in 0 ..< n:
        if box.contains(ix.x(i), ix.y(i)): want.add i
      doAssert found == want, $trial

block indexEdges:
  var order: seq[int32]
  let none = initSpatialIndex(newSeq[float64](), newSeq[float64](), order)
  doAssert none.len == 0 and none.bounds.isEmpty and none.nearest(0, 0, Inf) == -1
  for p in none.within(Bounds(minX: -1, minY: -1, maxX: 1, maxY: 1)): doAssert false
  let one = initSpatialIndex([3.0], [4.0], order)
  doAssert one.nearest(0, 0, 5) == 0 and one.nearest(0, 0, 4.99) == -1
  doAssert one.nearest(NaN, 0, Inf) == -1 and one.nearest(0, 0, NaN) == -1
  doAssert one.nearest(1e300, -1e300, Inf) == 0, "far outside, any distance"
  doAssert one.bounds == Bounds(minX: 3, minY: 4, maxX: 3, maxY: 4)
  # Points whose span overflows a float share one cell, and are still found.
  let wide = initSpatialIndex([-1e308, 1e308, 0.0], [0.0, 0.0, 1.0], order)
  doAssert wide.cells == (1, 1) and wide.nearest(1e308, 1, Inf) == wide.nearest(1e308, 1, 1e10)
  doAssertRaises(ValueError): discard initSpatialIndex([1.0, NaN], [1.0, 2.0], order)
  doAssertRaises(ValueError): discard initSpatialIndex([1.0], [Inf], order)
  doAssertRaises(ValueError): discard initSpatialIndex([1.0], [1.0, 2.0], order)
  # Edges are inside.
  let grid = initSpatialIndex([0.0, 10, 10, 0], [0.0, 0, 10, 10], order)
  var n = 0
  for _ in grid.within(Bounds(minX: 0, minY: 0, maxX: 10, maxY: 10)): inc n
  doAssert n == 4
  let (cx, cy) = grid.cells
  doAssert cx * cy <= CellsPerPoint * 4 + 16

proc landKeys(shot, channel: int): TraceKeys =
  ## A trace of the fixture survey with its stations, as a SEG-D record has.
  result = initTraceKeys()
  (result.record, result.channel, result.status) = (float64(FirstRecord + shot),
    float64(channel), tsLive)
  (result.srcLine, result.srcPoint, result.srcIndex) = (SrcLine, FirstSrcPoint + float64(shot),
    1'i16)
  (result.srcX, result.srcY, result.srcZ) = (srcX(shot), OriginY, Elevation)
  (result.rcvLine, result.rcvPoint, result.rcvIndex) = (RcvLine,
    FirstRcvPoint + float64(channel - 1), 1'i16)
  (result.rcvX, result.rcvY, result.rcvZ) = (rcvX(channel), OriginY, Elevation)

proc tracesLayer(keys: openArray[TraceKeys]; base = 0; session = SessionId(1)): SurveyLayer =
  var b = initTraceLayerBuilder("/data/test.sgd", fkSegd, session, base, keys.len, 0)
  b.add(keys)
  b.finish()

block landReceiversRepeat:
  var keys: seq[TraceKeys]
  for shot in 0 ..< Shots:
    for channel in 1 .. Channels: keys.add landKeys(shot, channel)
  let l = tracesLayer(keys)
  doAssert l.points[prSource].len == Shots and l.points[prReceiver].len == Channels
  doAssert l.counts[prReceiver].placed == SurveyTraces and
    l.counts[prReceiver].merged == SurveyTraces - Channels
  doAssert l.counts[prSource].merged == SurveyTraces - Shots
  for shot in 0 ..< Shots:
    for channel in 1 .. Channels:
      let t = shot * Channels + channel - 1
      let (s, r) = (l.pointOf(prSource, t), l.pointOf(prReceiver, t))
      doAssert l.points[prSource].index.x(s) == srcX(shot)
      doAssert l.points[prReceiver].index.x(r) == rcvX(channel)
      doAssert l.points[prReceiver].station[r] ==
        Station(line: RcvLine, point: FirstRcvPoint + float64(channel - 1), index: 1)
      doAssert l.points[prReceiver].z[r] == Elevation
  # Receiver 5 was recorded by every shot.
  let r5 = l.pointOf(prReceiver, 4)
  var at: seq[int]
  for t in l.tracesAt(prReceiver, r5): at.add t
  doAssert at == @[4, Channels + 4, 2 * Channels + 4], $at
  doAssert l.bounds == Bounds(minX: rcvX(1), minY: OriginY, maxX: rcvX(Channels), maxY: OriginY)
  # Two stations at one place stay two points.
  var two = @[landKeys(0, 1), landKeys(0, 1)]
  two[1].rcvPoint = 999
  doAssert tracesLayer(two).points[prReceiver].len == 2

block marineReceiversMove:
  # A streamer: channel c's receiver is 25 m further on with every shot.
  var keys: seq[TraceKeys]
  for shot in 0 ..< 4:
    for channel in 1 .. 6:
      var k = initTraceKeys()
      (k.record, k.channel, k.status) = (float64(shot + 1), float64(channel), tsLive)
      (k.srcLine, k.srcPoint) = (1.0, float64(1000 + shot))
      (k.srcX, k.srcY) = (OriginX + 25 * float64(shot), OriginY)
      (k.rcvLine, k.rcvPoint) = (1.0, float64(channel)) # the streamer's station: its channel
      (k.rcvX, k.rcvY) = (OriginX + 25 * float64(shot) + 100 * float64(channel), OriginY + 3)
      keys.add k
  let l = tracesLayer(keys)
  doAssert l.points[prSource].len == 4 and l.points[prReceiver].len == 24
  doAssert l.counts[prReceiver].merged == 0
  doAssert l.stationCount(prReceiver) == 6
  var ofChannel3: seq[int]
  for t in l.stationTraces(prReceiver, Station(line: 1, point: 3, index: 0)): ofChannel3.add t
  doAssert ofChannel3 == @[2, 8, 14, 20], $ofChannel3

block missingZeroAndAuxiliary:
  var keys = @[landKeys(0, 1), landKeys(0, 2), landKeys(0, 3), landKeys(0, 4), landKeys(0, 5)]
  (keys[1].rcvX, keys[1].rcvY) = (NaN, NaN)
  (keys[2].rcvX, keys[2].rcvY) = (0.0, 0.0)
  (keys[2].srcX, keys[2].srcY) = (-0.0, 0.0)
  keys[3].rcvX = Inf
  keys[4].status = tsAuxiliary
  (keys[0].rcvLine, keys[0].rcvPoint) = (NaN, NaN)
  let l = tracesLayer(keys)
  let c = l.counts[prReceiver]
  doAssert c.given == 4 and c.placed == 1 and c.missing == 2 and c.zero == 1 and
    c.noStation == 1, $c
  doAssert l.counts[prSource].zero == 1 and l.counts[prSource].placed == 3
  doAssert l.auxiliary == 1
  doAssert l.pointOf(prReceiver, 1) == -1 and l.pointOf(prReceiver, 2) == -1 and
    l.pointOf(prReceiver, 4) == -1 and l.pointOf(prReceiver, 99) == -1
  doAssert not l.stationOf(prReceiver, 0).known and l.stationOf(prReceiver, 1).known
  doAssert l.problems.len == 3, $l.problems
  # Nothing at all: still a layer.
  let empty = tracesLayer(newSeq[TraceKeys]())
  doAssert empty.points[prSource].len == 0 and empty.bounds.isEmpty
  doAssert empty.summary == "0 traces at no point", empty.summary

block fromTheSurveyFixture:
  withFixtures fx:
    var f = openSeismic(fx.surveySegy(pdZeroCoordinates), keys = true)
    var keys: seq[TraceKeys]
    for i in 0 ..< f.len: keys.add f.traceKeys(i)
    f.close()
    let l = tracesLayer(keys)
    # parseSEG reads a source at (0, 0) back as unknown: shot 1's are missing.
    doAssert l.counts[prSource].missing == Channels and l.counts[prSource].zero == 0
    doAssert l.points[prSource].len == Shots - 1 and l.points[prReceiver].len == Channels
    doAssert l.pointOf(prSource, Channels) == -1 and l.pointOf(prReceiver, Channels) >= 0

proc fileLayer(path: string; kind: FileKind): SurveyLayer =
  ## A survey file's layer, made as the load job makes it (in one part).
  var b = initSurveyFileBuilder(path, kind, getFileSize(path), getLastModificationTime(path))
  if kind == fkP1:
    let f = readP1(path)
    doAssert f.log.len == 0, $f.log
    for lf in f.files:
      for r in lf.records:
        let index = if r.reshoot in {'A' .. 'Z'}: int16(ord(r.reshoot) - ord('A') + 2) else: 0'i16
        b.addPoint(prSource, parseFloat(r.lineName), r.point, index, r.easting, r.northing, NaN)
  else:
    var f = readSps(path)
    doAssert f.log.count(sevError) + f.log.count(sevFatal) == 0, $f.log
    for p in f.points:
      b.addPoint(if p.kind == pkSource: prSource else: prReceiver, p.line, p.point,
        int16(p.index), p.easting, p.northing, p.elevation)
    b.addRelations(f)
  b.finish()

block plantedSpsFile:
  withFixtures fx:
    let paths = fx.plantedSps()
    let p = PlantedSps
    let s = fileLayer(paths.s, fkSpsSource)
    let cs = s.counts[prSource]
    doAssert cs.given == Shots + 3 and cs.placed == Shots + 1 and cs.zero == 1 and
      cs.missing == 1 and cs.replaced == 1 and cs.moved == 0, $cs
    doAssert s.points[prSource].len == Shots and s.points[prReceiver].len == 0
    let r = fileLayer(paths.r, fkSpsReceiver)
    let cr = r.counts[prReceiver]
    doAssert cr.given == Channels + 4 and cr.placed == Channels + 2 and cr.zero == 1 and
      cr.missing == 1 and cr.replaced == 2 and cr.moved == 1, $cr
    doAssert r.points[prReceiver].len == Channels
    let moved = r.stationPoint(prReceiver, Station(line: RcvLine, point: p.receiverMoved,
      index: 1))
    doAssert moved >= 0 and r.points[prReceiver].index.x(moved) == rcvX(10) + 1,
      "the station given last is kept"
    # As parseSEG's join finds a station: index 0 (none) takes the first position.
    doAssert r.stationPoint(prReceiver, Station(line: RcvLine, point: FirstRcvPoint,
      index: 0)) >= 0
    doAssert r.stationPoint(prReceiver, Station(line: RcvLine, point: FirstRcvPoint,
      index: 2)) == -1
    doAssert r.stationPoint(prReceiver, Station(line: RcvLine, point: p.receiverZero,
      index: 1)) == -1, "(0, 0) is left off the map"
    doAssert r.stationPoint(prSource, Station(line: RcvLine, point: FirstRcvPoint,
      index: 1)) == -1
    doAssert r.problems.len == 3, $r.problems
    doAssert r.summary == $Channels & " receiver points", r.summary
    let x = fileLayer(paths.x, fkSpsRelation)
    doAssert x.relationRuns == Shots and x.relationRecords == Shots
    doAssert x.points[prSource].len == 0 and x.points[prReceiver].len == 0
    doAssert x.summary == $Shots & " relation records for " & $Shots & " field records",
      x.summary

block p1File:
  withFixtures fx:
    let l = fileLayer(fx.surveyP1(), fkP1)
    let c = l.counts[prSource]
    doAssert c.given == P1Shots + 2 and c.placed == P1Shots + 1 and c.zero == 1, $c
    doAssert l.points[prSource].len == P1Shots + 1, "the reshoot is a station of its own"
    let reshot = l.stationPoint(prSource, Station(line: P1Line, point: P1Reshot, index: 2))
    doAssert reshot >= 0 and l.points[prSource].index.y(reshot) == P1Y + 10
    let first = l.stationPoint(prSource, Station(line: P1Line, point: 1, index: 1))
    doAssert first >= 0 and l.points[prSource].index.x(first) == p1X(1),
      "a P1 shotpoint without reshoot code is any index"

block linksBothWays:
  withFixtures fx:
    let paths = fx.surveySps()
    var sv: Survey
    var withStations, bare: seq[TraceKeys]
    for shot in 0 ..< Shots:
      for channel in 1 .. Channels:
        var k = landKeys(shot, channel)
        (k.srcX, k.srcY, k.rcvX, k.rcvY) = (NaN, NaN, NaN, NaN) # SEG-D: stations only
        withStations.add k
        (k.srcLine, k.srcPoint, k.rcvLine, k.rcvPoint) = (NaN, NaN, NaN, NaN)
        bare.add k # record and channel only
    let a = sv.add tracesLayer(withStations, base = 0, session = SessionId(1))
    let b = sv.add tracesLayer(bare, base = 1000, session = SessionId(2))
    let s = sv.add fileLayer(paths.s, fkSpsSource)
    let r = sv.add fileLayer(paths.r, fkSpsReceiver)
    discard sv.add fileLayer(paths.x, fkSpsRelation)
    doAssert sv.layers.len == 5 and sv.find(a) == 0 and sv.find(b) == 1
    doAssert not sv.bounds.isEmpty
    for (keys, base) in [(withStations, 0), (bare, 1000)]:
      let t = Channels + 6 # shot 1, channel 7
      let found = sv.tracePoints(base + t, keys[t])
      doAssert found.len == 2, $found
      let rl = sv.layers[sv.find(r)]
      doAssert found[0].layer == s and found[1].layer == r and found[1].role == prReceiver
      doAssert rl.points[prReceiver].index.x(found[1].point) == rcvX(7)
      doAssert sv.layers[sv.find(s)].points[prSource].index.x(found[0].point) == srcX(1)
      # Back: the receiver's point names the traces with that station.
      let back = sv.tracesAt(found[1])
      doAssert back == @[6, Channels + 6, 2 * Channels + 6], $back
    # A traces layer with coordinates links by trace.
    let c = sv.add tracesLayer(@[landKeys(0, 3)], base = 5000, session = SessionId(3))
    let all = sv.tracePoints(5000, landKeys(0, 3))
    doAssert all.len == 4, $all # the survey files' two, then its own two
    let own = all[2 .. 3]
    doAssert own[0].layer == c and own[0].role == prSource and own[1].role == prReceiver
    doAssert sv.tracesAt(own[1]) == @[5000]
    doAssert sv.tracesAt(PointRef(layer: c, role: prReceiver, point: 7)).len == 0
    doAssert sv.remove(c) and not sv.remove(c) and sv.find(c) == -1
    # A layer of the same file takes the place of the one before.
    let again = sv.add fileLayer(paths.r, fkSpsReceiver)
    doAssert sv.find(r) == -1 and sv.find(again) == 3 and sv.layers.len == 5

proc measured(keys: openArray[TraceKeys]): (SurveyLayer, float64) =
  ## The layer of `keys`, and the seconds it took this thread (`ownTime`:
  ## not the time it waited for a core on a loaded machine).
  let start = ownTime()
  var b = initTraceLayerBuilder("/data/big.sgy", fkSegy, SessionId(1), 0, keys.len, 0)
  for i in countup(0, keys.high, 65_536):
    b.add(keys.toOpenArray(i, min(i + 65_535, keys.high)))
  let layer = b.finish()
  (layer, (ownTime() - start).inMicroseconds.float64 / 1e6)

block millionTraces:
  # Land: 1000 shots of 1000 channels on a spread of 20 lines of 250
  # stations, rolling along; marine: every receiver at a place of its own.
  const shots = 1000
  const channels = 1000
  var land = newSeq[TraceKeys](shots * channels)
  for shot in 0 ..< shots:
    for c in 0 ..< channels:
      var k = initTraceKeys()
      k.status = tsLive
      (k.srcLine, k.srcPoint) = (float64(shot div 50), float64(shot mod 50))
      (k.srcX, k.srcY) = (5e5 + float64(shot mod 50) * 50, 6e6 + float64(shot div 50) * 300)
      let station = (shot * 5 + c) mod 5000
      (k.rcvLine, k.rcvPoint) = (float64(station div 250), float64(station mod 250))
      (k.rcvX, k.rcvY) = (5e5 + float64(station mod 250) * 25,
        6e6 + float64(station div 250) * 300)
      land[shot * channels + c] = k
  let (landLayer, landSeconds) = measured(land)
  doAssert landLayer.points[prReceiver].len == 5000 and landLayer.points[prSource].len == 1000
  var marine = land
  for t, k in marine.mpairs:
    (k.rcvX, k.rcvY) = (5e5 + float64(t div channels) * 25 + float64(t mod channels) * 12.5,
      6e6 + float64(t mod 7))
  let (marineLayer, marineSeconds) = measured(marine)
  doAssert marineLayer.points[prReceiver].len == shots * channels
  # The index answers a hover at once.
  let ix = marineLayer.points[prReceiver].index
  let start = getMonoTime()
  var hits = 0
  for q in 0 ..< 10_000:
    if ix.nearest(5e5 + float64(q) * 3.1, 6e6 + 3, 20) >= 0: inc hits
  let perHover = (getMonoTime() - start).inMicroseconds.float64 / 10_000
  doAssert hits == 10_000
  echo "  1e6 traces into a layer: land ", formatFloat(landSeconds, ffDecimal, 3), " s, marine ",
    formatFloat(marineSeconds, ffDecimal, 3), " s; nearest ", formatFloat(perHover, ffDecimal, 2),
    " us"
  # The target is for the program as shipped (an optimised build: about 0.1
  # and 0.25 s here); a debug build runs these loops three to four times
  # slower, so it is given twice the time.
  const limit = when defined(release) or defined(danger): 1.0 else: 2.0
  doAssert landSeconds < limit and marineSeconds < limit,
    "1e6 traces took " & $landSeconds & " s (land), " & $marineSeconds & " s (marine)"
