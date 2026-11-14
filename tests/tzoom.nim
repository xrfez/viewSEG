## How a panel's view moves: zoom about a point (both axes or one), pan,
## drag, box zoom, the limits every view is kept within, and back to the
## view before a gesture. Zooming changes what is read: zooming in asks for
## fewer traces, zooming out for more, but never more than the plot has
## columns.
##
## No gesture ever shows anything past the data: wheel and key zooms, pans,
## drags, box zooms, typed scales, a new plot size and the scroll bars all
## stop at the first and last trace and at the record's start and end, and
## zoomed out as far as it goes the data fills the plot exactly. A new plot
## size keeps the scale of an axis that hides part of the data; the scroll
## bars' thumbs show the share in view and move the view with them.
##
## In the wiggle modes no view is wider than the plot has pixel columns
## (one pixel a trace), under any gesture, a new plot size included: a
## record of more traces than that opens at the limit from its first trace,
## a change from density to a wiggle mode narrows the view keeping its left
## edge, and back keeps to the limit; density still zooms out to the whole
## record.
##
## Seen to fail: with `viewLimits` giving the wiggle modes no widest view
## (as before), `wiggleLimit` found the wiggle mode's widest view 10 000
## traces on 800 columns; with `ckDisplay` not narrowing the view to the
## new mode's limit, `wiggleLimitInTheState` found the 200 traces of the
## density view still in view after the change to wiggles; with `keptFrom`
## keeping the centre (as `kept` does), `wiggleLimit` found 1999.5 .. 5999.5
## narrowed about its centre, not from its left edge.
## Earlier: with the limits 5 % past the data on each side, as they
## were, `neverPastTheData` found a pan of the whole gather showing up to
## position 10 499.5 where the data ends at 9999.5; with `resized` keeping
## the spans (stretching the view), `resizeKeepsTheScale` found the trace
## width unchanged; with the thumb's length taken from the view's width
## over the track instead of over the data, `scrollBarThumbs` found a thumb
## of 1000 pixels where 200 are due;
## with `scrolled` turning pixels into data over the whole track instead of
## the thumb's room, the thumb did not stay under the pointer.
## Earlier: with `zoomed` holding the anchor at the middle of the span,
## `zoomKeepsTheAnchor` found it drawn at (410, 320) instead of (210, 470);
## with `kept` recentring every span, `validViewsAreLeftAlone` found 0.1 ..
## 0.7 moved; with `remember` keeping a view equal to the last one kept,
## `backGoesToTheViewBeforeAGesture` kept 4 views where 3 differ; with the
## read-ahead cap removed from `requestFor`, `zoomChangesTheTracesRead`
## asked for 1205 traces on 800 columns.

import std/[math, random]
import viewSEG/core/[geometry, scales, viewport, zoom]
import viewSEG/core/state {.all.}
import utils/[fixtures, waiting]

const layout = PanelLayout(traces: 10_000, samples: 4001, dtMs: 1, t0Ms: 0)

let lim = limitsOf(layout)

func near(a, b: float64; eps = 1e-9): bool = abs(a - b) <= eps * max(1.0, abs(b))

block limits:
  # the data itself: the traces' outer edges, the record's start and end
  doAssert lim[axTraces].bounds == Span(lo: -0.5, hi: 9999.5)
  doAssert lim[axTraces].least == MinTraces and lim[axTraces].most == 10_000
  doAssert lim[axTime].bounds == Span(lo: 0, hi: 4000)
  doAssert lim[axTime].least == 8 and lim[axTime].most == 4000
  let fit = fitAll(layout, 800, 600)
  doAssert fit.traces == lim[axTraces].bounds and fit.timeMs == lim[axTime].bounds
  # one trace of one sample: the limits still have a width
  let tiny = limitsOf(PanelLayout(traces: 1, samples: 1, dtMs: 2))
  doAssert tiny[axTraces].least == 1 and tiny[axTime].least == 2 and tiny[axTime].most > 0
  let empty = limitsOf(PanelLayout())
  doAssert empty[axTraces].most > 0 and empty[axTime].most > 0

block validViewsAreLeftAlone:
  let fit = fitAll(layout, 800, 600)
  doAssert kept(fit, lim) == fit
  let v = Viewport(traces: Span(lo: 0.25, hi: 23.5), timeMs: Span(lo: 100, hi: 300),
    columns: 800, rows: 600)
  doAssert kept(v, lim) == v, $kept(v, lim)
  doAssert kept(Span(lo: 0.1, hi: 0.7), Limits(bounds: Span(lo: 0, hi: 1), least: 0.1,
    most: 1)) == Span(lo: 0.1, hi: 0.7)

block keptClampsAndMoves:
  # too narrow: widened about its centre
  let narrow = kept(Span(lo: 100, hi: 101), lim[axTraces])
  doAssert narrow == Span(lo: 98.5, hi: 102.5), $narrow
  # too wide: the whole data
  let wide = kept(Span(lo: -9000, hi: 30_000), lim[axTraces])
  doAssert wide == lim[axTraces].bounds, $wide
  # past an edge: moved back inside, width kept
  let past = kept(Span(lo: 10_400, hi: 10_600), lim[axTraces])
  doAssert past == Span(lo: 9799.5, hi: 9999.5), $past
  let before = kept(Span(lo: -900, hi: -100), lim[axTraces])
  doAssert before == Span(lo: -0.5, hi: 799.5), $before
  let nan = kept(Span(lo: NaN, hi: 5), lim[axTraces])
  doAssert nan == lim[axTraces].bounds

block zoomKeepsTheAnchor:
  let v = fitAll(layout, 800, 600)
  let at = DataPoint(x: 2500, tMs: 3000)
  let z = v.zoomed(2, at, BothAxes, lim)
  doAssert near(z.traces.width, v.traces.width / 2) and near(z.timeMs.width,
    v.timeMs.width / 2)
  # the anchor keeps its place on the screen
  let plot = Rect(pos: vec2(10, 20), size: vec2(800, 600))
  let before = v.screenAt(plot, at)
  let after = z.screenAt(plot, at)
  doAssert abs(before.x - after.x) < 1e-3 and abs(before.y - after.y) < 1e-3,
    $before & " became " & $after
  # in and out again comes back
  let back = z.zoomed(0.5, at, BothAxes, lim)
  doAssert near(back.traces.lo, v.traces.lo, 1e-6) and near(back.traces.hi, v.traces.hi, 1e-6)
  doAssert near(back.timeMs.lo, v.timeMs.lo, 1e-6) and near(back.timeMs.hi, v.timeMs.hi, 1e-6)
  # an anchor that is not a number zooms about the centre
  let c = v.zoomed(4, DataPoint(x: NaN, tMs: NaN), BothAxes, lim)
  doAssert near(c.centre.x, v.centre.x) and near(c.centre.tMs, v.centre.tMs)
  doAssertRaises ValueError: discard v.zoomed(0, at, BothAxes, lim)
  doAssertRaises ValueError: discard v.zoomed(NaN, at, BothAxes, lim)

block zoomAlongOneAxis:
  let v = fitAll(layout, 800, 600)
  let at = DataPoint(x: 100, tMs: 500)
  let t = v.zoomed(WheelStep, at, {axTime}, lim)
  doAssert t.traces == v.traces and near(t.timeMs.width, v.timeMs.width / WheelStep)
  let x = v.zoomed(WheelStep, at, {axTraces}, lim)
  doAssert x.timeMs == v.timeMs and near(x.traces.width, v.traces.width / WheelStep)

block zoomStopsAtTheLimits:
  var v = fitAll(layout, 800, 600)
  for _ in 0 ..< 100: v = v.zoomed(KeyStep, DataPoint(x: 9999, tMs: 4000), BothAxes, lim)
  doAssert v.traces.width == MinTraces and v.timeMs.width == 8, $v
  doAssert v.traces.hi <= lim[axTraces].bounds.hi and v.timeMs.hi <= lim[axTime].bounds.hi
  for _ in 0 ..< 100: v = v.zoomed(1 / KeyStep, DataPoint(x: 0, tMs: 0), BothAxes, lim)
  doAssert v.traces == lim[axTraces].bounds and v.timeMs == lim[axTime].bounds, $v

block panAndDrag:
  let v = Viewport(traces: Span(lo: 100, hi: 200), timeMs: Span(lo: 1000, hi: 2000),
    columns: 400, rows: 500)
  let p = v.panned(10, -100, lim)
  doAssert p.traces == Span(lo: 110, hi: 210) and p.timeMs == Span(lo: 900, hi: 1900)
  let s = v.stepped(PanStep, PanStep, lim)
  doAssert near(s.traces.lo, 110) and near(s.timeMs.lo, 1100), $s
  doAssert v.panned(-1e6, 1e6, lim).traces.lo == lim[axTraces].bounds.lo
  doAssert v.panned(-1e6, 1e6, lim).timeMs.hi == lim[axTime].bounds.hi
  # dragging right by a quarter of the plot shows a quarter of the view earlier
  let plot = Rect(pos: vec2(50, 40), size: vec2(400, 500))
  let d = v.dragged(plot, vec2(100, -125), lim)
  doAssert d.traces == Span(lo: 75, hi: 175) and d.timeMs == Span(lo: 1250, hi: 2250), $d
  # the data point under the pointer stays under it
  let press = vec2(150, 300)
  let grabbed = v.dataAt(plot, press)
  let moved = v.dragged(plot, vec2(37, 51), lim)
  let now = moved.dataAt(plot, vec2(press.x + 37, press.y + 51))
  doAssert near(now.x, grabbed.x, 1e-6) and near(now.tMs, grabbed.tMs, 1e-6)

block screenAndData:
  let v = Viewport(traces: Span(lo: -0.5, hi: 99.5), timeMs: Span(lo: 0, hi: 1000),
    columns: 200, rows: 100)
  let plot = Rect(pos: vec2(10, 10), size: vec2(200, 100))
  doAssert v.dataAt(plot, vec2(10, 10)) == DataPoint(x: -0.5, tMs: 0)
  doAssert v.dataAt(plot, vec2(210, 110)) == DataPoint(x: 99.5, tMs: 1000)
  let q = DataPoint(x: 42.25, tMs: 333)
  let back = v.dataAt(plot, v.screenAt(plot, q))
  doAssert near(back.x, q.x, 1e-5) and near(back.tMs, q.tMs, 1e-5)

block boxZoom:
  let v = fitAll(layout, 800, 600)
  let b = v.boxed(DataPoint(x: 300, tMs: 900), DataPoint(x: 200, tMs: 400), BothAxes, lim)
  doAssert b.traces == Span(lo: 200, hi: 300) and b.timeMs == Span(lo: 400, hi: 900), $b
  let t = v.boxed(DataPoint(x: 300, tMs: 900), DataPoint(x: 200, tMs: 400), {axTime}, lim)
  doAssert t.traces == v.traces and t.timeMs == Span(lo: 400, hi: 900)
  # a box narrower than the limits is widened about its centre
  let thin = v.boxed(DataPoint(x: 10, tMs: 0), DataPoint(x: 11, tMs: 2), BothAxes, lim)
  doAssert thin.traces.width == MinTraces and thin.timeMs.width == 8, $thin

block zoomChangesTheTracesRead:
  # Wheel turns about one point, from the whole gather down to the narrowest
  # view and back, on 800 columns: the traces asked for fall as the view
  # narrows and stay within visible + read-ahead; zoomed out past a trace
  # per column, never more than the columns.
  let at = DataPoint(x: 6000, tMs: 2000)
  var v = fitAll(layout, 800, 600)
  var counts: seq[int]
  var strides: seq[int]
  for _ in 0 ..< 60:
    let r = requestFor(layout, v)
    let vis = visiblePositions(layout, v)
    # zoomed out past a trace per column: every `stride`-th (a view as wide
    # as the columns touches one trace more, and reads it at stride 1:
    # twiggle, wigglesReadEveryTrace)
    if r.stride > 1:
      doAssert r.count <= v.columns, $r.count & " traces read on " & $v.columns & " columns"
    else:
      doAssert r.stride == 1 and r.count <= vis.len + 2 * int(ceil(vis.len.float * ReadAhead))
    counts.add r.count
    strides.add r.stride
    v = v.zoomed(WheelStep, at, BothAxes, lim)
  doAssert strides[0] == 16 and strides[^1] == 1, $strides
  # four positions wide covers five at most, plus three on each side
  doAssert counts[^1] <= 5 + 2 * 3, "narrowest view: " & $counts[^1] & " traces"
  for i in 1 ..< counts.len:
    doAssert strides[i] <= strides[i - 1]
    if strides[i] == 1 and strides[i - 1] == 1:
      doAssert counts[i] <= counts[i - 1], "zooming in read more: " & $counts
  # zooming out again reads more, up to the columns
  var outCounts: seq[int]
  for _ in 0 ..< 60:
    v = v.zoomed(1 / WheelStep, at, BothAxes, lim)
    outCounts.add requestFor(layout, v).count
  doAssert outCounts[^1] == counts[0] and outCounts[^1] <= 800, $outCounts[^1] & " traces"
  # one axis: a time zoom leaves the traces read alone
  let f = fitAll(layout, 800, 600)
  doAssert requestFor(layout, f.zoomed(8, at, {axTime}, lim)).count ==
    requestFor(layout, f).count
  # in traces: first the stride falls (the count stays near the columns),
  # then, at one trace per column or fewer, the count falls with the view
  doAssert requestFor(layout, f.zoomed(8, at, {axTraces}, lim)).count <= 800
  let in64 = requestFor(layout, f.zoomed(64, at, {axTraces}, lim)).count
  let in128 = requestFor(layout, f.zoomed(128, at, {axTraces}, lim)).count
  doAssert in64 < requestFor(layout, f).count and in128 < in64, $in64 & ", " & $in128

func inside(v: Viewport; lay: PanelLayout): bool =
  ## Whether `v` shows nothing past the data of `lay` (as `fitAll` shows
  ## it, not as the limits say).
  let all = fitAll(lay, 1, 1)
  result = true
  for (s, d) in [(v.traces, all.traces), (v.timeMs, all.timeMs)]:
    let eps = 1e-9 * d.width
    if not (s.lo >= d.lo - eps and s.hi <= d.hi + eps and s.width > 0):
      result = false

block neverPastTheData:
  # Gestures of every kind, at random, on a large gather, on one narrower
  # than the narrowest view and on a record that starts late (a SEG-D
  # delay): after each, nothing past the data is in view.
  var rng = initRand(20261114)
  for lay in [layout, PanelLayout(traces: 3, samples: 1501, dtMs: 2, t0Ms: 0),
      PanelLayout(traces: 480, samples: 2001, dtMs: 0.5, t0Ms: 120)]:
    let l = limitsOf(lay)
    let plot = Rect(pos: vec2(40, 30), size: vec2(800, 600))
    var v = fitAll(lay, 800, 600)
    proc anywhere(): DataPoint =
      # also past the data, where a pointer or a box corner may be
      DataPoint(x: rng.rand(-2.0 .. 2.0) * float64(lay.traces),
        tMs: lay.t0Ms + rng.rand(-1.0 .. 2.0) * float64(lay.samples) * lay.dtMs)
    for i in 0 ..< 3000:
      let what = rng.rand(9)
      let was = v
      case what
      of 0: v = v.zoomed(pow(WheelStep, rng.rand(-8.0 .. 8.0)), anywhere(), BothAxes, l)
      of 1: v = v.zoomed(KeyStep, anywhere(), {[axTraces, axTime][rng.rand(1)]}, l)
      of 2: v = v.zoomed(1 / KeyStep, anywhere(), BothAxes, l)
      of 3: v = v.panned(rng.rand(-3.0 .. 3.0) * v.traces.width,
        rng.rand(-3.0 .. 3.0) * v.timeMs.width, l)
      of 4: v = v.stepped(float64(rng.rand(-1 .. 1)), float64(rng.rand(-1 .. 1)), l)
      of 5: v = v.dragged(plot, vec2(float32(rng.rand(-3000 .. 3000)),
        float32(rng.rand(-3000 .. 3000))), l)
      of 6: v = v.boxed(anywhere(), anywhere(), BothAxes, l)
      of 7:
        let value = pow(10.0, rng.rand(-3.0 .. 6.0))
        v = if rng.rand(1) == 0: withTraceScale(v, value, 96, ScaleUnits(), l)
            else: withTimeScale(v, value, 96, ScaleUnits(), l)
      of 8: v = v.resized(rng.rand(1 .. 3000), rng.rand(1 .. 2000), l)
      else:
        let a = [axTraces, axTime][rng.rand(1)]
        v = if rng.rand(1) == 0: v.paged(a, float64(rng.rand(-3 .. 3)), l)
            else: v.scrolled(a, l, 800, 20, float64(rng.rand(-1000 .. 1000)))
      doAssert v.inside(lay), "gesture " & $what & " on " & $lay & " from " & $was & " showed " & $v
    # zoomed out as far as it goes, by any way, the data fills the plot exactly
    for _ in 0 ..< 60: v = v.zoomed(1 / WheelStep, anywhere(), BothAxes, l)
    doAssert v.traces == l[axTraces].bounds and v.timeMs == l[axTime].bounds, $v
    let wide = withTimeScale(withTraceScale(v.zoomed(9, v.centre, BothAxes, l), 1e9, 96,
      ScaleUnits(), l), 1e9, 96, ScaleUnits(), l)
    doAssert wide.traces == l[axTraces].bounds and wide.timeMs == l[axTime].bounds, $wide
    doAssert v.resized(3000, 2000, l).traces == l[axTraces].bounds

block wiggleLimit:
  # one pixel a trace at the most, on 800 columns; density has no such limit
  let wl = limitsOf(layout, widest = 800)
  doAssert wl[axTraces].most == 800 and wl[axTraces].bounds == lim[axTraces].bounds
  doAssert wl[axTime] == lim[axTime], "the time axis has no such limit"
  doAssert limitsOf(layout, widest = NaN) == lim and limitsOf(layout, widest = 0) == lim
  let fit = fitted(wl, 800, 600)
  doAssert fit.traces == Span(lo: -0.5, hi: 799.5) and fit.timeMs == lim[axTime].bounds, $fit
  doAssert fitted(lim, 800, 600) == fitAll(layout, 800, 600)
  # the modes: density, wiggle, wiggle over density on 800 columns
  for (mode, most) in [(dmDensity, 10_000.0), (dmWiggle, 800.0), (dmWiggleDensity, 800.0)]:
    let vl = viewLimits(layout, DisplaySettings(mode: mode), 800)
    doAssert vl[axTraces].most == most, $mode & ": " & $vl[axTraces]
    doAssert viewLimits(layout, DisplaySettings(mode: mode), 0)[axTraces].most == 10_000,
      "a plot of no known size has no limit"
  # fewer traces than columns: all of them
  let few = PanelLayout(traces: 300, samples: 100, dtMs: 2)
  doAssert fitted(viewLimits(few, DisplaySettings(), 800), 800, 600) == fitAll(few, 800, 600)
  # zooming out stops at the limit, about the pointer; a narrower view is
  # widened from its left edge by `keptFrom`, about its centre by `kept`
  var v = fit.zoomed(4, DataPoint(x: 5000, tMs: 100), BothAxes, wl)
  for _ in 0 ..< 40: v = v.zoomed(1 / WheelStep, DataPoint(x: 5000, tMs: 100), BothAxes, wl)
  doAssert near(v.traces.width, 800) and v.timeMs == lim[axTime].bounds, $v
  let wide = Viewport(traces: Span(lo: 1999.5, hi: 5999.5), timeMs: lim[axTime].bounds,
    columns: 800, rows: 600)
  doAssert keptFrom(wide, wl).traces == Span(lo: 1999.5, hi: 2799.5)
  doAssert kept(wide, wl).traces == Span(lo: 3599.5, hi: 4399.5)
  doAssert keptFrom(Span(lo: 9900, hi: 9999.5), wl[axTraces]) == Span(lo: 9900, hi: 9999.5)
  doAssert keptFrom(Span(lo: 9900, hi: 9901), wl[axTraces]) == Span(lo: 9900, hi: 9904)
  doAssert keptFrom(Span(lo: 9900, hi: 12_000), wl[axTraces]) == Span(lo: 9199.5, hi: 9999.5)

block wiggleLimitUnderEveryGesture:
  # gestures of every kind, at random, on a plot whose size changes too:
  # never more traces in view than the plot has columns, never past the
  # data; density, on the same gestures, reaches the whole record
  var rng = initRand(20261115)
  let d = DisplaySettings(mode: dmWiggle)
  let plot = Rect(pos: vec2(40, 30), size: vec2(800, 600))
  var v = fitted(viewLimits(layout, d, 800), 800, 600)
  for i in 0 ..< 3000:
    let l = viewLimits(layout, d, v.columns)
    let what = rng.rand(9)
    let at = DataPoint(x: rng.rand(-1.0 .. 2.0) * 10_000, tMs: rng.rand(-1.0 .. 2.0) * 4000)
    case what
    of 0: v = v.zoomed(pow(WheelStep, rng.rand(-8.0 .. 8.0)), at, BothAxes, l)
    of 1: v = v.zoomed(1 / KeyStep, at, {axTraces}, l)
    of 2: v = v.panned(rng.rand(-3.0 .. 3.0) * v.traces.width, 0, l)
    of 3: v = v.dragged(plot, vec2(float32(rng.rand(-3000 .. 3000)), 0), l)
    of 4: v = v.boxed(at, DataPoint(x: rng.rand(-1.0 .. 2.0) * 10_000, tMs: 0), BothAxes, l)
    of 5: v = withTraceScale(v, pow(10.0, rng.rand(-3.0 .. 6.0)), 96, ScaleUnits(), l)
    of 6:
      let (c, r) = (rng.rand(1 .. 3000), rng.rand(1 .. 2000))
      v = v.resized(c, r, viewLimits(layout, d, c))
    of 7: v = v.paged(axTraces, float64(rng.rand(-3 .. 3)), l)
    of 8: v = v.scrolled(axTraces, l, 800, 20, float64(rng.rand(-1000 .. 1000)))
    else: v = fitted(l, v.columns, v.rows)
    doAssert v.traces.width <= float64(v.columns) * (1 + 1e-9),
      "gesture " & $what & ": " & $v.traces.width & " traces on " & $v.columns & " columns"
    doAssert v.inside(layout), "gesture " & $what & " showed " & $v
  let dl = viewLimits(layout, DisplaySettings(mode: dmDensity), v.columns)
  for _ in 0 ..< 60: v = v.zoomed(1 / WheelStep, v.centre, BothAxes, dl)
  doAssert v.traces == lim[axTraces].bounds, "density: " & $v

block resizeKeepsTheScale:
  let fit = fitAll(layout, 800, 600)
  let v = Viewport(traces: Span(lo: 100, hi: 300), timeMs: Span(lo: 1000, hi: 1600),
    columns: 800, rows: 600)
  # bigger: more of the data at the same scale, from the same top-left corner
  let big = v.resized(1000, 900, lim)
  doAssert big.columns == 1000 and big.rows == 900
  doAssert big.traces == Span(lo: 100, hi: 350) and big.timeMs == Span(lo: 1000, hi: 1900), $big
  # smaller: less of it
  let small = v.resized(400, 300, lim)
  doAssert small.traces == Span(lo: 100, hi: 200) and small.timeMs == Span(lo: 1000, hi: 1300)
  # an axis that shows all the data goes on showing all of it
  var oneAxis = fit
  oneAxis.traces = v.traces
  let r = oneAxis.resized(1200, 300, lim)
  doAssert r.timeMs == fit.timeMs and r.traces == Span(lo: 100, hi: 400), $r
  doAssert fit.resized(1600, 1200, lim).traces == fit.traces
  doAssert fit.resized(200, 100, lim).timeMs == fit.timeMs
  # growing past the data: it stops there, moved back inside
  let late = Viewport(traces: Span(lo: 9900, hi: 9999.5), timeMs: v.timeMs, columns: 800,
    rows: 600)
  let grown = late.resized(1600, 600, lim)
  doAssert grown.traces == Span(lo: 9800.5, hi: 9999.5), $grown
  # a size not known yet (0): the spans as they are
  var unsized = v
  unsized.columns = 0
  doAssert unsized.resized(800, 600, lim).traces == v.traces

block scrollBarThumbs:
  let fit = fitAll(layout, 800, 600)
  doAssert fit.showsAll(axTraces, lim) and fit.showsAll(axTime, lim)
  doAssert fit.thumbOf(axTraces, lim, 2000, 20) == Thumb(start: 0, length: 2000)
  # a tenth of the traces in view, a third of the way in: the thumb is a
  # tenth of the track, a third of the way along the room it has
  let v = Viewport(traces: Span(lo: 2999.5, hi: 3999.5), timeMs: Span(lo: 0, hi: 4000),
    columns: 800, rows: 600)
  doAssert not v.showsAll(axTraces, lim) and v.showsAll(axTime, lim)
  let th = v.thumbOf(axTraces, lim, 2000, 20)
  doAssert near(th.length, 200) and near(th.start, 1800 * 3000 / 9000), $th
  # at least `least` pixels, so it can be grabbed
  let narrow = Viewport(traces: Span(lo: 0, hi: 4), timeMs: v.timeMs)
  doAssert narrow.thumbOf(axTraces, lim, 2000, 20).length == 20
  # dragged: the thumb stays under the pointer, and stops at the track's ends
  for moved in [-50.0, 37.5, 400.0]:
    let s = v.scrolled(axTraces, lim, 2000, 20, moved)
    doAssert near(s.thumbOf(axTraces, lim, 2000, 20).start, th.start + moved, 1e-6), $moved
    doAssert s.timeMs == v.timeMs and near(s.traces.width, v.traces.width)
  doAssert v.scrolled(axTraces, lim, 2000, 20, -1e6).traces.lo == -0.5
  doAssert v.scrolled(axTraces, lim, 2000, 20, 1e6).traces.hi == 9999.5
  # nothing to scroll: nothing moves
  doAssert fit.scrolled(axTime, lim, 600, 20, 100) == fit
  # a click on the track: a whole view towards it, stopping at the end
  doAssert v.paged(axTraces, 1, lim).traces == Span(lo: 3999.5, hi: 4999.5)
  doAssert v.paged(axTraces, -1, lim).traces == Span(lo: 1999.5, hi: 2999.5)
  doAssert v.paged(axTraces, 10, lim).traces == Span(lo: 8999.5, hi: 9999.5)

proc laidOut(st: var AppState; layout: PanelLayout) =
  ## The main panel as a reader would leave it once it has looked at a
  ## gather of `layout`.
  st.mailbox.post Msg(job: NoJob, kind: mkLayout, panel: MainPanel,
    sourceGen: st.panel(MainPanel).sourceGen, layout: layout)
  discard st.drainInbox()

proc view(st: var AppState; v: Viewport; remember = false) =
  st.apply Command(kind: ckView, panel: MainPanel, view: v, remember: remember)

proc density(st: var AppState) =
  ## Shows the main panel in density: its views may hold more traces than
  ## the plot has columns (a wiggle mode stops at one pixel a trace).
  var d = st.panel(MainPanel).layers[0].display
  d.mode = dmDensity
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)

block backGoesToTheViewBeforeAGesture:
  # the main panel shows no file (no layer), so only the data limits it
  var st = initAppState()
  st.laidOut(layout)
  let p = st.panel(MainPanel)
  doAssert p.laidOut and p.jumps == 1 and p.back.len == 0
  let fit = fitAll(layout, 800, 600)
  st.view(fit) # the plot's size arrives: no gesture
  let a = fit.zoomed(2, DataPoint(x: 100, tMs: 100), BothAxes, lim)
  st.view(a, remember = true) # a wheel burst starts
  let a2 = a.zoomed(2, DataPoint(x: 100, tMs: 100), BothAxes, lim)
  st.view(a2) # ... and goes on
  let b = a2.panned(10, 10, lim)
  st.view(b, remember = true) # a drag
  st.view(b, remember = true) # the same view again: nothing new to keep
  doAssert st.panel(MainPanel).back.len == 2, $st.panel(MainPanel).back.len
  # a drag away and back to `b`, then a new gesture: `b` is kept once
  st.view(b.panned(5, 0, lim), remember = true)
  st.view(b)
  st.view(b.panned(0, 5, lim), remember = true)
  doAssert st.panel(MainPanel).back.len == 3, $st.panel(MainPanel).back.len & " views kept"
  st.apply Command(kind: ckBack, panel: MainPanel)
  doAssert st.panel(MainPanel).view.sameSpans(b)
  # back: the view before the drag, with the plot's current size
  var resized = b
  resized.columns = 640
  st.view(resized)
  st.apply Command(kind: ckBack, panel: MainPanel)
  let q = st.panel(MainPanel)
  doAssert q.view.sameSpans(a2) and q.view.columns == 640 and q.jumps == 3, $q.view
  st.apply Command(kind: ckBack, panel: MainPanel)
  doAssert st.panel(MainPanel).view.sameSpans(fit) and st.panel(MainPanel).jumps == 4
  # nothing left: back does nothing and says nothing
  let logged = st.log.len
  st.apply Command(kind: ckBack, panel: MainPanel)
  doAssert st.panel(MainPanel).view.sameSpans(fit) and st.panel(MainPanel).jumps == 4
  doAssert st.log.len == logged
  # a bounded history
  let z = fit.zoomed(4, fit.centre, BothAxes, lim)
  for i in 0 ..< MaxBack + 10:
    st.view(z.panned(float64(i + 1), 0, lim), remember = true)
  doAssert st.panel(MainPanel).back.len == MaxBack
  # an unknown panel is ignored, with a warning
  st.apply Command(kind: ckBack, panel: PanelId(99))
  doAssert st.log.count(sevWarning) == 1
  st.shutdown()

block nothingToRememberBeforeALayout:
  var st = initAppState()
  st.view(fitAll(layout, 800, 600), remember = true)
  st.view(fitAll(layout, 400, 600), remember = true)
  doAssert st.panel(MainPanel).back.len == 0
  st.shutdown()

block wiggleLimitInTheState:
  # the long spread (400 traces) on a plot of 100 columns: the record opens
  # at the limit, from the first trace, all of its time
  withFixtures fx:
    var st = initAppState()
    st.view(Viewport(traces: Span(lo: 0, hi: 1), timeMs: Span(lo: 0, hi: 1), columns: 100,
      rows: 300)) # the plot's size, before a file
    st.apply Command(kind: ckOpen, paths: @[fx.longSpreadSegy()])
    doAssert waitUntil((discard st.drainInbox(); st.panel(MainPanel).laidOut))
    let ll = limitsOf(st.panel(MainPanel).layout)
    doAssert st.panel(MainPanel).layers[0].display.mode == dmWiggle
    var v = st.panel(MainPanel).view
    doAssert v.traces == Span(lo: -0.5, hi: 99.5) and v.timeMs == ll[axTime].bounds, $v
    # a view wider than the limit, from whoever sends it, is narrowed to it
    st.view(Viewport(traces: Span(lo: 99.5, hi: 299.5), timeMs: v.timeMs, columns: 100,
      rows: 300))
    doAssert st.panel(MainPanel).view.traces.width == 100, $st.panel(MainPanel).view
    # density reaches further; back to wiggles narrows it, keeping its left edge
    st.density()
    st.view(Viewport(traces: Span(lo: 159.5, hi: 359.5), timeMs: v.timeMs, columns: 100,
      rows: 300), remember = true)
    doAssert st.panel(MainPanel).view.traces.width == 200
    let jumps = st.panel(MainPanel).jumps
    var d = st.panel(MainPanel).layers[0].display
    d.mode = dmWiggle
    st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    v = st.panel(MainPanel).view
    doAssert v.traces == Span(lo: 159.5, hi: 259.5) and st.panel(MainPanel).jumps == jumps + 1,
      $v
    # back to the density view before: kept to the wiggle limit
    st.view(v.panned(10, 0, ll), remember = true)
    st.apply Command(kind: ckBack, panel: MainPanel)
    doAssert st.panel(MainPanel).view.traces.width == 100
    # density: the whole record, by fit
    st.density()
    st.view(fitted(st.panel(MainPanel).viewLimits(100), 100, 300))
    doAssert st.panel(MainPanel).view.traces == ll[axTraces].bounds
    st.shutdown()

block coreKeepsViewsInside:
  # a view past the data, from whoever sends it, is kept inside
  var st = initAppState()
  st.laidOut(layout)
  var past = fitAll(layout, 800, 600)
  past.traces = Span(lo: -100, hi: 50)
  past.timeMs = Span(lo: 3900, hi: 4500)
  st.view(past)
  let v = st.panel(MainPanel).view
  doAssert v.traces == Span(lo: -0.5, hi: 149.5) and v.timeMs == Span(lo: 3400, hi: 4000), $v
  st.shutdown()
