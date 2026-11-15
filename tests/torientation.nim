## The plot's orientation in `core`: the one mapping between data and screen
## (`core/orientation`'s `Turn`) and every gesture through it, in both
## orientations and with the first trace at the top or at the bottom when
## time is across:
##
## - each turn's axes, directions and swing; the corners of the plot and a
##   round trip screen -> data -> screen; time down exactly the mapping it
##   was before the orientation (the old formulas, kept here);
## - the plot's size along each data axis, the image's size and its pixels
##   (a transpose), a stripe of traces on the image, and the GPU's form of
##   the mapping against the CPU's;
## - gestures in screen directions: a drag carries the data point under the
##   pointer with it, the arrow keys pan the way they point, the wheel and
##   the keys zoom along a screen axis (the data point under the pointer
##   stays there), a box zoom takes the box drawn, the scroll bars' thumbs
##   lie where the view lies along them and follow the pointer, a click on
##   a track pages towards it;
## - what does not depend on the orientation: the limits, the wiggle
##   limit, the scales and the reads follow the plot's pixels along each
##   data axis, whichever way they lie on the screen;
## - the wiggle's swing mirrored when time is across;
## - in `AppState`: a turn keeps the traces and times shown, its pixels
##   along each axis the other way round, reads nothing when zoomed in,
##   narrows a wiggle view to the plot's new pixels along the traces from
##   its first trace, and is remembered as the user's.
##
## Seen to fail: with time across given the time axis reversed, and with
## the first trace at the bottom as the default, `turns` failed; with
## `dataDelta`'s sign left out, a drag along the reversed axis (the first
## trace at the bottom) carried the data away from the pointer
## (`dragKeepsThePoint`); with `traceInk` ignoring the swing,
## `swingMirrored`; with `ckDisplay` not swapping the plot's pixels at a
## turn, `aTurnKeepsTheView`.

import std/[math, random]
import viewSEG/core/[geometry, scales, viewport, wiggle, zoom]
import viewSEG/core/state {.all.}
import utils/[fixtures, waiting]

const
  Down = TimeDown
  Plot = Rect(pos: Vec2(x: 40, y: 30), size: Vec2(x: 800, y: 500))
  View = Viewport(traces: Span(lo: 9.5, hi: 49.5), timeMs: Span(lo: 200, hi: 1200),
    columns: 800, rows: 500) ## time down on `Plot`

let
  Across = turnOf(orTimeAcross)
  AcrossUp = turnOf(orTimeAcross, firstAtTop = false) # the first trace at the bottom
  Turns = [Down, Across, AcrossUp]

func near(a, b: float64; eps = 1e-9): bool = abs(a - b) <= eps * max(1.0, abs(a) + abs(b))
func near(a, b: DataPoint): bool = near(a.x, b.x) and near(a.tMs, b.tMs)
func near(a, b: Vec2): bool = near(float64(a.x), float64(b.x), 1e-6) and
  near(float64(a.y), float64(b.y), 1e-6)

proc on(m: Turn): Viewport =
  ## `View` on `Plot` turned as `m` says.
  View.sized(m, int(Plot.size.x), int(Plot.size.y))

block turns:
  doAssert Down.along == [axTraces: saX, axTime: saY] and
    Down.reversed == [axTraces: false, axTime: false] and
    Down.swing == 1
  doAssert Across.along == [axTraces: saY, axTime: saX] and Across.swing == -1
  doAssert AcrossUp.reversed == [axTraces: true, axTime: false] and AcrossUp.swing == 1
  doAssert Down.axisAlong(saX) == axTraces and Across.axisAlong(saX) == axTime
  doAssert Across.axesAlong({saY}) == {axTraces}
  # a positive amplitude swings right when time is down, up when across
  doAssert Down.swingOnScreen == (saX, 1.0)
  doAssert Across.swingOnScreen == (saY, -1.0) and AcrossUp.swingOnScreen == (saY, -1.0)
  doAssert turnOf(orTimeAcross).reversed[axTraces] == not FirstTraceAtTop

block corners:
  let tl = Plot.pos
  let tr = vec2(Plot.pos.x + Plot.size.x, Plot.pos.y)
  let bl = vec2(Plot.pos.x, Plot.pos.y + Plot.size.y)
  let (t0, t1) = (View.traces, View.timeMs)
  template at(m: Turn; p: Vec2): DataPoint = on(m).dataAt(Plot, p, m)
  # time down: the first trace at the left, the earliest time at the top
  doAssert near(at(Down, tl), DataPoint(x: t0.lo, tMs: t1.lo))
  doAssert near(at(Down, tr), DataPoint(x: t0.hi, tMs: t1.lo))
  doAssert near(at(Down, bl), DataPoint(x: t0.lo, tMs: t1.hi))
  # time across: the earliest time at the left, the latest at the right
  doAssert near(at(Across, tl), DataPoint(x: t0.lo, tMs: t1.lo)), $at(Across, tl)
  doAssert near(at(Across, tr), DataPoint(x: t0.lo, tMs: t1.hi)), $at(Across, tr)
  doAssert near(at(Across, bl), DataPoint(x: t0.hi, tMs: t1.lo)), $at(Across, bl)
  doAssert near(at(AcrossUp, tl), DataPoint(x: t0.hi, tMs: t1.lo))
  doAssert near(at(AcrossUp, bl), DataPoint(x: t0.lo, tMs: t1.lo))

block theFirstTraceAtTheTop:
  # the taken default: traces stacked from the top down when time is across
  let v = on(Across)
  let first = v.screenAt(Plot, DataPoint(x: 10, tMs: 500), Across)
  let next = v.screenAt(Plot, DataPoint(x: 11, tMs: 500), Across)
  doAssert next.y > first.y and next.x == first.x, $first & " " & $next

block roundTrip:
  var rng = initRand(7)
  for m in Turns:
    let v = on(m)
    for _ in 0 ..< 1000:
      let p = vec2(float32(rng.rand(40 .. 840)), float32(rng.rand(30 .. 530)))
      doAssert near(v.screenAt(Plot, v.dataAt(Plot, p, m), m), p)

block timeDownAsBefore:
  # The formulas of time down before there was an orientation: the same
  # numbers, to the bit.
  func oldDataAt(v: Viewport; plot: Rect; p: Vec2): DataPoint =
    let w = if plot.size.x > 0: float64(plot.size.x) else: 1.0
    let h = if plot.size.y > 0: float64(plot.size.y) else: 1.0
    DataPoint(x: v.traces.lo + (float64(p.x) - float64(plot.pos.x)) / w * v.traces.width,
      tMs: v.timeMs.lo + (float64(p.y) - float64(plot.pos.y)) / h * v.timeMs.width)
  func oldScreenAt(v: Viewport; plot: Rect; p: DataPoint): Vec2 =
    let fx = if v.traces.width != 0: (p.x - v.traces.lo) / v.traces.width else: 0.0
    let fy = if v.timeMs.width != 0: (p.tMs - v.timeMs.lo) / v.timeMs.width else: 0.0
    vec2(float32(float64(plot.pos.x) + fx * float64(plot.size.x)),
      float32(float64(plot.pos.y) + fy * float64(plot.size.y)))
  func oldNdc(s: Span; v: float64; flip: bool): float32 =
    let f = (v - s.lo) / (s.hi - s.lo) * 2 - 1
    float32(if flip: -f else: f)
  var rng = initRand(11)
  for _ in 0 ..< 2000:
    let p = vec2(float32(rng.rand(0.0 .. 900.0)), float32(rng.rand(0.0 .. 600.0)))
    doAssert View.dataAt(Plot, p) == oldDataAt(View, Plot, p)
    let d = DataPoint(x: rng.rand(0.0 .. 60.0), tMs: rng.rand(0.0 .. 1500.0))
    doAssert View.screenAt(Plot, d) == oldScreenAt(View, Plot, d)
    doAssert View.ndcOf(Down, d) == (oldNdc(View.traces, d.x, false),
      oldNdc(View.timeMs, d.tMs, true))
  let lim = limitsOf(PanelLayout(traces: 60, samples: 1000, dtMs: 2))
  for _ in 0 ..< 200:
    let moved = vec2(float32(rng.rand(-300 .. 300)), float32(rng.rand(-300 .. 300)))
    let w = float64(Plot.size.x)
    let h = float64(Plot.size.y)
    doAssert View.dragged(Plot, moved, lim) == panned(View,
      -float64(moved.x) / w * View.traces.width, -float64(moved.y) / h * View.timeMs.width, lim)

block sizes:
  let v = on(Across)
  doAssert v.columns == 500 and v.rows == 800, "pixels along the traces: the plot's height"
  doAssert v.screenSize(Across) == (800, 500) and on(Down).screenSize(Down) == (800, 500)
  doAssert on(Down).columns == 800 and on(Down).rows == 500
  # an image pixel `trace` along the positions and `time` along time
  doAssert v.screenPixel(Across, 3, 7) == (7, 3)
  doAssert on(AcrossUp).screenPixel(AcrossUp, 3, 7) == (7, 500 - 1 - 3)
  doAssert on(Down).screenPixel(Down, 3, 7) == (3, 7)
  doAssert v.screenRect(Across, 10 .. 19) == Rect(pos: vec2(0, 10), size: vec2(800, 10))
  doAssert on(AcrossUp).screenRect(AcrossUp, 10 .. 19) ==
    Rect(pos: vec2(0, 480), size: vec2(800, 10))
  doAssert on(Down).screenRect(Down, 10 .. 19) == Rect(pos: vec2(10, 0), size: vec2(10, 500))

block ndcBothWays:
  # the vertex shader's affine form and the CPU's corners agree
  var rng = initRand(3)
  for m in Turns:
    let v = on(m)
    let n = v.ndcMap(m)
    for _ in 0 ..< 500:
      let d = DataPoint(x: rng.rand(9.5 .. 49.5), tMs: rng.rand(200.0 .. 1200.0))
      let (x, y) = v.ndcOf(m, d)
      let (dp, dt) = (d.x - v.traces.lo, d.tMs - v.timeMs.lo)
      doAssert near(float64(x), dp * n.xPerPos + dt * n.xPerMs + n.x0, 1e-5)
      doAssert near(float64(y), dp * n.yPerPos + dt * n.yPerMs + n.y0, 1e-5)
      # the same place as on the screen: x right, y up
      let s = v.screenAt(Rect(pos: vec2(0, 0), size: vec2(2, 2)), d, m)
      doAssert near(float64(x), float64(s.x) - 1, 1e-5) and
        near(float64(y), 1 - float64(s.y), 1e-5)

let lim = limitsOf(PanelLayout(traces: 60, samples: 1000, dtMs: 2))

block dragKeepsThePoint:
  # the data point under the pointer at the press stays under it
  var rng = initRand(5)
  for m in Turns:
    let v = on(m)
    for _ in 0 ..< 300:
      let press = vec2(float32(rng.rand(100 .. 700)), float32(rng.rand(100 .. 400)))
      let moved = vec2(float32(rng.rand(-60 .. 60)), float32(rng.rand(-60 .. 60)))
      let grabbed = v.dataAt(Plot, press, m)
      let after = v.dragged(Plot, moved, lim, m)
      if after.traces.width == v.traces.width and after.traces.lo > lim[axTraces].bounds.lo and
          after.traces.hi < lim[axTraces].bounds.hi and
          after.timeMs.lo > lim[axTime].bounds.lo and after.timeMs.hi < lim[axTime].bounds.hi:
        let now = after.dataAt(Plot, vec2(press.x + moved.x, press.y + moved.y), m)
        doAssert near(now, grabbed), $m.orientation & " " & $now & " " & $grabbed

block arrowsPanTheWayTheyPoint:
  # Right shows what lies right of the view, Down what lies below it.
  for m in Turns:
    let v = on(m)
    let centre = vec2(Plot.pos.x + Plot.size.x / 2, Plot.pos.y + Plot.size.y / 2)
    for (dx, dy) in [(PanStep, 0.0), (-PanStep, 0.0), (0.0, PanStep), (0.0, -PanStep)]:
      let (a, b) = m.dataDelta(dx, dy)
      let after = v.stepped(a, b, lim)
      # the data that was a tenth of the plot that way is now in the middle
      let ahead = vec2(centre.x + float32(dx) * Plot.size.x, centre.y + float32(dy) * Plot.size.y)
      doAssert near(after.dataAt(Plot, centre, m), v.dataAt(Plot, ahead, m)),
        $m.orientation & " " & $(dx, dy)

block zoomAlongAScreenAxis:
  # Ctrl + wheel zooms up and down only, Shift + wheel across only, about
  # the pointer, which keeps its data point.
  for m in Turns:
    let v = on(m)
    let p = vec2(300, 200)
    let at = v.dataAt(Plot, p, m)
    for screen in [{saX}, {saY}, {saX, saY}]:
      let z = v.zoomed(WheelStep, at, m.axesAlong(screen), lim)
      doAssert near(z.screenAt(Plot, at, m), p)
      for s in ScreenAxis:
        let a = m.axisAlong(s)
        doAssert (z.span(a).width < v.span(a).width) == (s in screen)

block boxZoom:
  for m in Turns:
    let v = on(m)
    let (a, b) = (vec2(100, 300), vec2(400, 120))
    let z = v.boxed(v.dataAt(Plot, a, m), v.dataAt(Plot, b, m), BothAxes, lim)
    # the box's corners are the new view's corners
    doAssert near(z.screenAt(Plot, v.dataAt(Plot, vec2(100, 120), m), m), Plot.pos)
    doAssert near(z.screenAt(Plot, v.dataAt(Plot, vec2(400, 300), m), m),
      vec2(Plot.pos.x + Plot.size.x, Plot.pos.y + Plot.size.y))

block scrollBars:
  # A view at the data's start along an axis has its thumb at the track's
  # end the data starts at on the screen; dragging the thumb moves the
  # view so that the thumb follows; paging goes the way of the click.
  let full = limitsOf(PanelLayout(traces: 200, samples: 1000, dtMs: 2))
  let track = 400.0
  for m in Turns:
    for a in Axis:
      var v = on(m)
      v.traces = Span(lo: -0.5, hi: 19.5)
      v.timeMs = Span(lo: 0, hi: 200)
      let first = v.thumbOf(a, full, track, 20, m)
      if m.reversed[a]: doAssert near(first.start + first.length, track)
      else: doAssert first.start == 0
      if not m.reversed[a]:
        doAssert v.thumbOf(a, full, track, 20) == first, "time down's thumb as before"
      v.traces = Span(lo: 89.5, hi: 109.5) # in the middle: room either way
      v.timeMs = Span(lo: 800, hi: 1000)
      let th = v.thumbOf(a, full, track, 20, m)
      for by in [37.0, -37.0]:
        let moved = v.scrolled(a, full, track, 20, by, m)
        doAssert near(moved.thumbOf(a, full, track, 20, m).start, th.start + by),
          $m.orientation & " " & $a & " " & $by
      for pages in [1.0, -1.0]: # a click after the thumb, before it
        let t = v.paged(a, pages, full, m).thumbOf(a, full, track, 20, m)
        doAssert (t.start > th.start) == (pages > 0), $m.orientation & " " & $a

block notTurnedWithTheScreen:
  # The limits, the wiggle limit, the scales and the reads follow the
  # pixels along each data axis, wherever those lie.
  let layout = PanelLayout(traces: 2000, samples: 4000, dtMs: 1)
  let d = DisplaySettings() # wiggles: at most a trace a pixel
  let across = View.sized(Across, 1200, 300) # a wide, low plot
  doAssert viewLimits(layout, d, across.columns)[axTraces].most == 300
  doAssert near(traceScale(across, 96, ScaleUnits()), View.traces.width / (300 / 96))
  doAssert near(timeScale(across, 96, ScaleUnits()), View.timeMs.width / (1200 / 96))
  var wide = across
  wide.traces = Span(lo: -0.5, hi: 1199.5) # 1200 traces on 300 pixels: every 4th
  wide.timeMs = Span(lo: 0, hi: 3999) # 4000 samples on 1200 pixels: in bins of 2
  let r = requestFor(layout, wide)
  doAssert r.stride == 4 and r.decimation == 2, $r
  var down = wide
  (down.columns, down.rows) = (1200, 300)
  let q = requestFor(layout, down)
  doAssert q.stride == 1 and q.decimation == 8, $q

block swingMirrored:
  # Time across, a positive amplitude swings up, towards the trace before:
  # each wiggle is its time-down self mirrored about its baseline.
  let t = Tile(request: ReadRequest(count: 1, stride: 1, samples: 8, decimation: 1),
    dtMs: 2, columns: 8, data: @[0'f32, 0.4, 0.9, 0.3, -0.6, -0.9, -0.2, 0.1], traces: @[0])
  var d = DisplaySettings()
  d.fills = {wfPositive, wfNegative}
  let v = Viewport(traces: Span(lo: -0.5, hi: 0.5), timeMs: Span(lo: -1, hi: 15), columns: 40,
    rows: 64)
  let ink = WiggleInk(line: Rgba(a: 255), positive: Rgba(b: 200, a: 255),
    negative: Rgba(r: 200, a: 255))
  let st = d.styleFor(v, 1, 1, 2)
  var dt = d
  dt.orientation = orTimeAcross
  let sa = dt.styleFor(v, 1, 1, 2)
  doAssert st.swing == 1 and sa.swing == -1
  let s = t.series
  var inked = 0
  for i in -20 .. 20:
    for j in 0 ..< 64:
      let tm = float64(j) * 0.25
      let a = t.traceInk(s, 0, float64(i), tm, sa, ink)
      let b = t.traceInk(s, 0, -float64(i), tm, st, ink)
      doAssert a == b, $(i, j)
      if a.a > 0 and i != 0: inc inked
  doAssert inked > 100 # the test drew something

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc main(st: AppState): lent Panel = st.panel(MainPanel)

proc turn(st: var AppState; o: Orientation) =
  var d = st.main.layers[0].display
  d.orientation = o
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)

block aTurnKeepsTheView:
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.surveySegy()])
    doAssert st.settle(st.main.laidOut and st.main.layout.traces > 0)
    var v = fitAll(st.main.layout, 800, 600)
    v.traces = Span(lo: 3.5, hi: 11.5)
    v.timeMs = Span(lo: 100, hi: 300)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert st.settle(st.tiles(st.findPanel(MainPanel)).len > 0 and
      st.tiles(st.findPanel(MainPanel))[^1].request == st.main.pending)
    let (gen, taken) = (st.main.requestGen, st.tilesTaken)
    st.turn(orTimeAcross)
    doAssert st.main.view.traces == v.traces and st.main.view.timeMs == v.timeMs
    doAssert st.main.view.columns == 600 and st.main.view.rows == 800
    # the window then says its pixels: still nothing to read, zoomed in
    var turned = st.main.view
    (turned.columns, turned.rows) = (560, 780)
    st.apply Command(kind: ckView, panel: MainPanel, view: turned)
    for _ in 0 ..< 50:
      discard st.drainInbox()
    doAssert st.main.requestGen == gen and st.tilesTaken == taken, "a turn read again"
    doAssert st.settings.plot.display.orientation == orTimeAcross
    doAssert st.keptSettings.plot.display.orientation == orTimeAcross, "the user's turn is kept"
    st.turn(orTimeDown)
    doAssert st.main.view.traces == v.traces and st.main.view.columns == 780
    st.shutdown()

block aTurnNarrowsAWiggleView:
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.longSpreadSegy()])
    doAssert st.settle(st.main.laidOut and st.main.layout.traces > 0)
    var v = fitAll(st.main.layout, 400, 200)
    v.traces = Span(lo: 9.5, hi: 389.5) # 380 traces on 400 pixels
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert st.main.view.traces == v.traces
    let jumps = st.main.jumps
    st.turn(orTimeAcross) # 200 pixels along the traces now: 200 traces at most
    doAssert st.main.view.traces.lo == v.traces.lo, "narrowed from its first trace"
    doAssert near(st.main.view.traces.width, 200), $st.main.view.traces
    doAssert st.main.jumps > jumps, "the window follows"
    st.shutdown()
