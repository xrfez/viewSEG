## The map's marks of what its filters found, merged by place
## (`view/maplayers`' `markSpots`), and the hover's count of what lies
## under the pointer (`markedHere`): one spot a place however many things
## it marks there, each thing once a spot; under the pointer, each thing
## once however many spots mark it; the same counts as looking at every
## place (random places, things and reaches); and cheap: a pointer over a
## station with 20 000 marked traces, with a million marked places
## elsewhere, costs well under a millisecond a frame, moving or not.
##
## Seen to fail: with `spotsNear` looking at every spot instead of the
## grid's cells that reach, "the hover costs" found 54 ms a frame (a million
## spots, a debug build); with the count made over the things under the
## pointer in a list (`notin`, as the map first did), the test ran for three
## minutes without finishing the moving pointer's frames.

import std/[algorithm, math, monotimes, random, times]
import viewSEG/core/[mapkinds, mapview]
import viewSEG/view/maplayers

func place(x, y: float64; key: int64): MarkPlace = (mapPoint(x, y), key)

func reachOf(r: float64): proc (f: MapFilter): float64 {.noSideEffect.} =
  result = proc (f: MapFilter): float64 = r

proc brute(places: openArray[MarkPlace]; at: MapPoint; r: float64): int =
  ## What lies within `r` of `at`, each thing once: every place looked at.
  var keys: seq[int64]
  for p in places:
    if hypot(p.at.x - at.x, p.at.y - at.y) <= r and p.key notin keys: keys.add p.key
  keys.len

block mergedByPlace:
  var places: seq[MarkPlace]
  for t in 0 ..< 5000: places.add place(100, 200, int64(t)) # a dead channel at one station
  places.add place(100, 200, 7) # one trace listed twice there
  places.add place(105, 200, 7) # and at its file's own position
  places.add place(NaN, 200, 9) # not drawn
  let m = markSpots(places)
  doAssert m.spots.len == 2, $m.spots.len & " spots"
  doAssert m.positions == @[mapPoint(100, 200), mapPoint(105, 200)]
  doAssert m.spots[0].count == 5000 and m.spots[1].count == 1
  doAssert m.things == 5001
  var near: MarksNear
  let marks = @[(mfDead, m)]
  doAssert near.markedHere(marks, mapPoint(100, 200), reachOf(1)) == @[(mfDead, 5000)]
  # both spots under the pointer: trace 7 once
  doAssert near.markedHere(marks, mapPoint(102, 200), reachOf(4)) == @[(mfDead, 5000)]
  doAssert near.markedHere(marks, mapPoint(105, 200), reachOf(1)) == @[(mfDead, 1)]
  doAssert near.markedHere(marks, mapPoint(200, 200), reachOf(1)).len == 0
  doAssert near.markedHere(marks, mapPoint(NaN, 200), reachOf(1)).len == 0
  doAssert markSpots(newSeq[MarkPlace]()).spots.len == 0
  var none: MarksNear
  doAssert none.markedHere(@[(mfDead, markSpots(newSeq[MarkPlace]()))], mapPoint(0, 0),
    reachOf(1)).len == 0

block asLookingAtEveryPlace:
  var r = initRand(3)
  for round in 0 ..< 20:
    var places: seq[MarkPlace]
    let n = r.rand(1 .. 3000)
    for i in 0 ..< n:
      # on a coarse grid of stations, so places merge; things shared
      places.add place(float64(r.rand(40)) * 25, float64(r.rand(20)) * 25,
        int64(r.rand(-50 .. 800)))
    let m = markSpots(places)
    var near: MarksNear
    for q in 0 ..< 60:
      let at = mapPoint(r.rand(-100.0 .. 1100.0), r.rand(-100.0 .. 600.0))
      let reach = r.rand(0.0 .. 120.0)
      let want = brute(places, at, reach)
      let got = near.markedHere(@[(mfNoisy, m)], at, reachOf(reach))
      doAssert (if want == 0: got.len == 0 else: got == @[(mfNoisy, want)]),
        "at " & $at & " reach " & $reach & ": " & $got & ", looking at every place " & $want

block theHoverCosts:
  var r = initRand(5)
  var places = newSeqOfCap[MarkPlace](1_020_000)
  for i in 0 ..< 1_000_000:
    places.add place(r.rand(50_000.0), r.rand(50_000.0), int64(i + 100_000))
  let station = mapPoint(25_000.5, 25_000.5)
  for t in 0 ..< 20_000: places.add (station, int64(t))
  # a receiver 10 m east with three marked traces, one of them the station's
  for t in [5'i64, 20_001, 20_002]: places.add (mapPoint(station.x + 10, station.y), t)
  let m = markSpots(places)
  let marks = @[(mfDead, m), (mfNoisy, m)]
  var near: MarksNear
  var moving, resting: seq[float64]
  # at a zoom where a 26-pixel mark is 13 m round its place, the pointer
  # moves over the station: 5 m west of it (the station alone under it) and
  # east (both), so each frame counts again; then it rests on the station
  for i in 0 ..< 200:
    let east = i < 100 and i mod 2 == 1
    let at = if i < 100: mapPoint(station.x + (if east: 5.0 else: -5.0), station.y)
             else: station
    let t0 = getMonoTime()
    let counts = near.markedHere(marks, at, reachOf(13))
    let ms = float64((getMonoTime() - t0).inMicroseconds) / 1000
    if i < 100: moving.add ms
    else: resting.add ms
    let want = if east: 20_002 else: 20_000
    doAssert counts.len == 2 and counts[0][1] in want .. want + 5, $counts
  func median(xs: seq[float64]): float64 = xs.sorted[xs.len div 2]
  echo "tmapmarks: ", m.spots.len, " spots; the hover over 20 000 traces with a million ",
    "places elsewhere: median ", median(moving), " ms a frame moving (slowest ", moving.max,
    "), ", median(resting), " resting (slowest ", resting.max, ")"
  doAssert median(moving) < 1.0 and median(resting) < 1.0, "the hover costs " &
    $median(moving) & " ms a frame moving, " & $median(resting) & " resting"
