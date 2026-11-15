## The map's view maths (`core/mapview`) and its levels of detail
## (`core/maplod`): equal aspect always, fit, zoom about a point, pan, drag,
## box zoom, a new plot size, the limits (never the survey lost, never past
## its bounds by more than equal aspect needs), the scale bar, distance and
## bearing; and levels that keep a point per cell, cover every point, and
## are drawn by the runs a view touches.
##
## Seen to fail: with `keptAxis` not centring a view wider than the survey,
## "a wide view is centred" failed; with `levelFor` taking the finest level
## instead of the coarsest that fits, "the coarsest level that fits" failed.

import std/[math, random, sets]
import viewSEG/core/[geometry, maplod, mapview, spatial]

func near(a, b: float64; eps = 1e-9): bool = abs(a - b) <= eps * max(1.0, max(abs(a), abs(b)))

func box(x0, y0, x1, y1: float64): Bounds = Bounds(minX: x0, minY: y0, maxX: x1, maxY: y1)

let survey = box(500_000, 6_000_000, 510_000, 6_002_000) # 10 km by 2 km
let lim = mapLimits(survey)

block fitShowsAllAtEqualAspect:
  let v = fitMap(lim, 1000, 800)
  doAssert v.isSet
  doAssert near(v.centre.x, 505_000) and near(v.centre.y, 6_001_000)
  # the 10 km fill the width but for the margins; the height has room to spare
  doAssert near(v.perPixel, 10_000 / (1000 - 2 * MapMargin))
  doAssert v.showsAll(lim)
  let s = v.visible
  doAssert s.minX < survey.minX and s.maxX > survey.maxX
  doAssert near(s.width / 1000, s.height / 800), "equal aspect"

block aWideViewIsCentred:
  # a tall plot: the survey's height is far from filling it, and the view
  # is centred on the survey along that axis however it is moved
  let v = fitMap(lim, 400, 1200)
  let moved = pannedMap(v, 0, 5000, lim)
  doAssert near(moved.centre.y, 6_001_000), $moved.centre
  doAssert near(moved.centre.x, v.centre.x)

block zoomOutStopsAtFit:
  let v = fitMap(lim, 1000, 800)
  let out1 = zoomedMap(v, 0.5, mapPoint(500_100, 6_000_100), lim)
  doAssert out1 == v, "zooming out at fit changes nothing"
  let inv = zoomedMap(v, 4, mapPoint(502_000, 6_001_500), lim)
  doAssert near(inv.perPixel, v.perPixel / 4)
  doAssert not inv.showsAll(lim)

block zoomKeepsThePointUnderThePointer:
  let plot = Rect(pos: vec2(10, 20), size: vec2(500, 400))       # half the framebuffer's pixels
  var v = fitMap(lim, 1000, 800)
  v = zoomedMap(v, 8, v.centre, lim)
  let p = vec2(200, 150)
  let at = v.mapAt(plot, p)
  let z = zoomedMap(v, 1.25, at, lim)
  let back = z.screenAt(plot, at)
  doAssert abs(back.x - p.x) < 1e-3 and abs(back.y - p.y) < 1e-3, $back
  doAssert near(z.perPixel, v.perPixel / 1.25)

block northIsUp:
  let plot = Rect(pos: vec2(0, 0), size: vec2(1000, 800))
  let v = fitMap(lim, 1000, 800)
  let top = v.mapAt(plot, vec2(500, 0))
  let bottom = v.mapAt(plot, vec2(500, 800))
  doAssert top.y > bottom.y
  let left = v.mapAt(plot, vec2(0, 400))
  let right = v.mapAt(plot, vec2(1000, 400))
  doAssert right.x > left.x

block panStopsAtTheBounds:
  var v = fitMap(lim, 1000, 800)
  v = zoomedMap(v, 10, mapPoint(500_000, 6_000_000), lim)
  let far = pannedMap(v, -1e9, -1e9, lim)
  let s = far.visible
  let m = MapMargin * far.perPixel
  doAssert near(s.minX, survey.minX - m) and near(s.minY, survey.minY - m), $s
  let e = pannedMap(v, 1e9, 1e9, lim).visible
  doAssert near(e.maxX, survey.maxX + m) and near(e.maxY, survey.maxY + m)

block keysStepAView:
  var v = fitMap(lim, 1000, 800)
  v = zoomedMap(v, 10, v.centre, lim)
  let r = steppedMap(v, 0.1, 0, lim)
  doAssert near(r.centre.x - v.centre.x, 0.1 * v.width)
  let u = steppedMap(v, 0, 1, lim) # Shift + Up: a whole view north
  doAssert near(u.centre.y - v.centre.y, min(v.height, survey.maxY + MapMargin * v.perPixel -
    v.centre.y - v.height / 2))

block dragFollowsThePointer:
  let plot = Rect(pos: vec2(0, 0), size: vec2(500, 400))
  var v = fitMap(lim, 1000, 800)
  v = zoomedMap(v, 10, v.centre, lim)
  let at = v.mapAt(plot, vec2(250, 200))
  let d = draggedMap(v, plot, vec2(30, -20), lim)
  let now = d.screenAt(plot, at)
  doAssert abs(now.x - 280) < 1e-3 and abs(now.y - 180) < 1e-3, $now

block boxZoomShowsTheBox:
  let v = fitMap(lim, 1000, 800)
  let a = mapPoint(501_000, 6_000_500)
  let b = mapPoint(502_000, 6_001_000)
  let z = boxedMap(v, a, b, lim)
  doAssert near(z.perPixel, max(1000 / 1000, 500 / 800))
  doAssert near(z.centre.x, 501_500) and near(z.centre.y, 6_000_750)
  let s = z.visible
  doAssert s.minX <= a.x and s.maxX >= b.x and s.minY <= a.y and s.maxY >= b.y

block closestZoom:
  let v = fitMap(lim, 1000, 800)
  let z = zoomedMap(v, 1e12, v.centre, lim)
  doAssert near(z.perPixel, lim.leastPerPixel)

block resizeKeepsScaleAndTopLeft:
  var v = fitMap(lim, 1000, 800)
  v = zoomedMap(v, 5, mapPoint(503_000, 6_001_000), lim)
  let before = v.visible
  let r = resizedMap(v, 800, 600, lim)
  doAssert near(r.perPixel, v.perPixel)
  let after = r.visible
  doAssert near(after.minX, before.minX) and near(after.maxY, before.maxY), $after
  # far larger than the survey at that scale: the scale grows to fit it
  let big = resizedMap(fitMap(lim, 300, 200), 3000, 2000, lim)
  doAssert near(big.perPixel, lim.mostPerPixel(3000, 2000)), $big.perPixel
  doAssert resizedMap(MapView(), 640, 480, lim) == fitMap(lim, 640, 480)

block keptLeavesAGoodViewAlone:
  var v = fitMap(lim, 1000, 800)
  v = zoomedMap(v, 3, mapPoint(504_000, 6_001_000), lim)
  doAssert keptMap(v, lim) == v
  var bad = v
  bad.perPixel = NaN
  doAssert near(keptMap(bad, lim).perPixel, lim.mostPerPixel(1000, 800))

block onePoint:
  let one = mapLimits(box(10, 20, 10, 20))
  let v = fitMap(one, 500, 500)
  doAssert v.isSet and near(v.centre.x, 10) and near(v.centre.y, 20)
  doAssert near(v.perPixel, LoneSpan / (500 - 2 * MapMargin))
  doAssert not fitMap(mapLimits(Bounds()), 500, 500).isSet

block scaleBarIsRound:
  for (pp, longest, want) in [(37.0, 150.0, 5000.0), (1.0, 150.0, 100.0), (0.3, 120.0, 20.0),
      (12.5, 200.0, 2000.0)]:
    let s = scaleBar(pp, longest)
    doAssert near(s.length, want), $pp & ": " & $s.length
    doAssert s.pixels <= longest + 1e-9 and near(s.pixels, s.length / pp)
  doAssert scaleBar(0, 150).length == 0

block distanceAndBearing:
  let a = mapPoint(0, 0)
  doAssert near(distance(a, mapPoint(3, 4)), 5)
  doAssert near(bearing(a, mapPoint(0, 10)), 0)
  doAssert near(bearing(a, mapPoint(10, 0)), 90)
  doAssert near(bearing(a, mapPoint(0, -10)), 180)
  doAssert near(bearing(a, mapPoint(-10, 0)), 270)
  doAssert bearing(a, a).isNaN
  doAssert decimalsFor(37) == 0 and decimalsFor(0.5) == 1 and decimalsFor(0.004) == 3

# ------------------------------------------------------------------ levels --

proc cloud(n: int; seed: int64): (seq[float64], seq[float64]) =
  var r = initRand(seed)
  var xs, ys = newSeq[float64](n)
  for i in 0 ..< n:
    xs[i] = 500_000 + r.rand(20_000.0)
    ys[i] = 6_000_000 + r.rand(8_000.0)
  (xs, ys)

block fewPointsHaveNoLevels:
  var order: seq[int32]
  let (xs, ys) = cloud(LodFrom - 1, 1)
  let ix = initSpatialIndex(xs, ys, order)
  let p = buildLevels(ix)
  doAssert p.levels.len == 0 and p.xy.len == 2 * ix.len
  doAssert p.levelFor(1e9, 2) == -1

block levelsKeepAPointPerCell:
  var order: seq[int32]
  let (xs, ys) = cloud(50_000, 2)
  let ix = initSpatialIndex(xs, ys, order)
  let p = buildLevels(ix)
  doAssert p.levels.len >= 3
  doAssert p.levels[^1].len == 1, "the coarsest level is one cell"
  var before = ix.len
  for k, l in p.levels:
    doAssert near(l.cell, ix.cellSize * pow(2.0, float64(k + 1)))
    doAssert l.len <= before and l.len > 0
    before = l.len
    doAssert l.rowStart.len == l.ny + 1 and l.rowStart[^1] == int32(l.len)
    var cells: HashSet[(int, int)]
    for j in 0 ..< l.ny:
      for q in l.rowStart[j] ..< l.rowStart[j + 1]:
        let (x, y) = (float64(l.xy[2 * q]) + p.origin.x, float64(l.xy[2 * q + 1]) + p.origin.y)
        let c = (min(int(floor((x - p.origin.x) / l.cell)), l.nx - 1),
          min(int(floor((y - p.origin.y) / l.cell)), l.ny - 1))
        doAssert c == (int(l.col[q]), j), "a point in its own cell"
        doAssert c notin cells, "one point a cell"
        cells.incl c
        if q > l.rowStart[j]: doAssert l.col[q] > l.col[q - 1]
    # every point's cell has a point of the level (nothing is lost)
    for i in 0 ..< ix.len:
      let c = (min(int(floor((ix.x(i) - p.origin.x) / l.cell)), l.nx - 1),
        min(int(floor((ix.y(i) - p.origin.y) / l.cell)), l.ny - 1))
      doAssert c in cells

block theCoarsestLevelThatFits:
  var order: seq[int32]
  let (xs, ys) = cloud(50_000, 3)
  let ix = initSpatialIndex(xs, ys, order)
  let p = buildLevels(ix)
  let k = p.levelFor(p.levels[2].cell / 2 * 1.01, 2)
  doAssert k == 2, $k
  doAssert p.levelFor(ix.cellSize * 0.9, 2) == -1, "zoomed in: every point"
  doAssert p.levelFor(1e12, 2) == p.levels.high

block runsHoldThePointsInView:
  var order: seq[int32]
  let (xs, ys) = cloud(50_000, 4)
  let ix = initSpatialIndex(xs, ys, order)
  let p = buildLevels(ix)
  let view = box(503_000, 6_002_000, 507_000, 6_004_500)
  for k in 0 ..< p.levels.len:
    let l = p.levels[k]
    var drawn: HashSet[int]
    for run in p.runs(k, view):
      for q in run: drawn.incl q
    for q in 0 ..< l.len:
      let (x, y) = (float64(l.xy[2 * q]) + p.origin.x, float64(l.xy[2 * q + 1]) + p.origin.y)
      if view.contains(x, y): doAssert q in drawn, "level " & $k & " point " & $q
  # and every point, from the index
  var drawn: HashSet[int]
  for run in ix.runs(view):
    for q in run: drawn.incl q
  for i in 0 ..< ix.len:
    if view.contains(ix.x(i), ix.y(i)): doAssert i in drawn
  var none = 0
  for run in p.runs(0, box(0, 0, 1, 1)): none += run.len
  doAssert none == 0

echo "tmapview: ok"
