## How a panel's view moves: zoom about a point (both axes or one), pan,
## drag, box zoom, the limits every view is kept within, and back to the
## view before a gesture. Zooming changes what is read: zooming in asks for
## fewer traces, zooming out for more, but never more than the plot has
## columns.
##
## Seen to fail: with `zoomed` holding the anchor at the middle of the span,
## `zoomKeepsTheAnchor` found it drawn at (410, 320) instead of (210, 470);
## with `kept` recentring every span, `validViewsAreLeftAlone` found 0.1 ..
## 0.7 moved; with `remember` keeping a view equal to the last one kept,
## `backGoesToTheViewBeforeAGesture` kept 4 views where 3 differ; with the
## read-ahead cap removed from `requestFor`, `zoomChangesTheTracesRead`
## asked for 1205 traces on 800 columns.

import std/math
import viewSEG/core/[geometry, viewport, zoom]
import viewSEG/core/state {.all.}

const layout = PanelLayout(traces: 10_000, samples: 4001, dtMs: 1, t0Ms: 0)

let lim = limitsOf(layout)

func near(a, b: float64; eps = 1e-9): bool = abs(a - b) <= eps * max(1.0, abs(b))

block limits:
  doAssert lim[axTraces].bounds == Span(lo: -0.5 - 500, hi: 9999.5 + 500)
  doAssert lim[axTraces].least == MinTraces and lim[axTraces].most == 11_000
  doAssert lim[axTime].bounds == Span(lo: -200, hi: 4200)
  doAssert lim[axTime].least == 8 and lim[axTime].most == 4400
  # one trace of one sample: the limits still have a width
  let tiny = limitsOf(PanelLayout(traces: 1, samples: 1, dtMs: 2))
  doAssert tiny[axTraces].least == 1 and tiny[axTime].least == 2 and tiny[axTime].most > 0
  let empty = limitsOf(PanelLayout())
  doAssert empty[axTraces].most > 0 and empty[axTime].most > 0

block validViewsAreLeftAlone:
  let fit = fitAll(layout, 800, 600)
  doAssert kept(fit, lim) == fit
  let v = Viewport(traces: Span(lo: -1.5, hi: 23.5), timeMs: Span(lo: 100, hi: 300),
    columns: 800, rows: 600)
  doAssert kept(v, lim) == v, $kept(v, lim)
  doAssert kept(Span(lo: 0.1, hi: 0.7), Limits(bounds: Span(lo: 0, hi: 1), least: 0.1,
    most: 1)) == Span(lo: 0.1, hi: 0.7)

block keptClampsAndMoves:
  # too narrow: widened about its centre
  let narrow = kept(Span(lo: 100, hi: 101), lim[axTraces])
  doAssert narrow == Span(lo: 98.5, hi: 102.5), $narrow
  # too wide: the widest view, inside the bounds
  let wide = kept(Span(lo: -9000, hi: 30_000), lim[axTraces])
  doAssert wide.width == 11_000 and wide.lo >= lim[axTraces].bounds.lo and
    wide.hi <= lim[axTraces].bounds.hi, $wide
  # past an edge: moved back inside, width kept
  let past = kept(Span(lo: 10_400, hi: 10_600), lim[axTraces])
  doAssert past == Span(lo: 10_299.5, hi: 10_499.5), $past
  let before = kept(Span(lo: -900, hi: -100), lim[axTraces])
  doAssert before == Span(lo: -500.5, hi: 299.5), $before
  let nan = kept(Span(lo: NaN, hi: 5), lim[axTraces])
  doAssert nan.width == 11_000 and not nan.lo.isNaN

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
    if vis.len > v.columns:
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

proc laidOut(st: var AppState; layout: PanelLayout) =
  ## The main panel as a reader would leave it once it has looked at a
  ## gather of `layout`.
  st.mailbox.post Msg(job: NoJob, kind: mkLayout, panel: MainPanel,
    sourceGen: st.panel(MainPanel).sourceGen, layout: layout)
  discard st.drainInbox()

proc view(st: var AppState; v: Viewport; remember = false) =
  st.apply Command(kind: ckView, panel: MainPanel, view: v, remember: remember)

block backGoesToTheViewBeforeAGesture:
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
  for i in 0 ..< MaxBack + 10:
    st.view(fit.panned(float64(i + 1), 0, lim), remember = true)
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
