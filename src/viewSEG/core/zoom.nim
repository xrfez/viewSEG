## How a panel's view moves: zoom about a point, along one axis or both,
## pan, drag, box zoom, all kept within the limits the panel's traces set.
##
## Views are moved in data coordinates (`core/viewport`): positions across,
## ms down. Every change keeps the view within `limitsOf(layout)`:
##
## - its edges at most `EdgeMargin` of the data's extent past the data, so
##   the first and last traces can be seen clear of the window's edge;
## - never narrower than `MinTraces` positions or `MinSamples` samples;
## - never wider than those bounds.
##
## A zoom keeps the point it is about where it is on the screen; a zoom
## that reaches a limit stops there. A view that is already within the
## limits is left exactly as it is.
##
## The frontend turns the pointer into data coordinates with `dataAt` and
## calls these. A map view can use the `Span` forms.

import std/math
import geometry, viewport

const
  EdgeMargin* = 0.05 ## how far past the data a view may reach, as a fraction of its extent
  MinTraces* = 4.0   ## the narrowest view, in positions
  MinSamples* = 8.0  ## the shortest view, in samples
  WheelStep* = 1.25  ## the zoom of one wheel notch
  KeyStep* = 1.5     ## the zoom of one key press or button click
  PanStep* = 0.1     ## the fraction of the view an arrow key pans by

type
  Axis* = enum
    axTraces = "traces" ## across: positions
    axTime = "time"     ## down: ms

  Limits* = object
    ## What a view is kept within along one axis: its edges inside
    ## `bounds`, its width from `least` to `most`.
    bounds*: Span
    least*, most*: float64

  ViewLimits* = array[Axis, Limits]

  DataPoint* = object
    ## A point of a panel in data coordinates.
    x*: float64   ## positions
    tMs*: float64 ## ms

const BothAxes* = {axTraces, axTime}

func limitsOf*(layout: PanelLayout): ViewLimits =
  ## The limits of a panel with `layout`. A panel with no traces or no
  ## sample interval gets limits for one trace and 1 ms samples.
  let n = float64(max(layout.traces, 1))
  let dt = if layout.dtMs > 0 and layout.dtMs < Inf: layout.dtMs else: 1.0
  let t0 = if layout.t0Ms.classify in {fcNan, fcInf, fcNegInf}: 0.0 else: layout.t0Ms
  let extent = float64(max(layout.samples - 1, 1)) * dt
  result[axTraces] = Limits(bounds: Span(lo: -0.5 - EdgeMargin * n,
    hi: n - 0.5 + EdgeMargin * n), least: min(MinTraces, n), most: (1 + 2 * EdgeMargin) * n)
  result[axTime] = Limits(bounds: Span(lo: t0 - EdgeMargin * extent,
    hi: t0 + extent + EdgeMargin * extent), least: min(MinSamples * dt, extent),
    most: (1 + 2 * EdgeMargin) * extent)

func span(v: Viewport; a: Axis): Span {.inline.} =
  if a == axTraces: v.traces else: v.timeMs

proc setSpan(v: var Viewport; a: Axis; s: Span) {.inline.} =
  if a == axTraces: v.traces = s else: v.timeMs = s

func coord(p: DataPoint; a: Axis): float64 {.inline.} =
  if a == axTraces: p.x else: p.tMs

func kept*(s: Span; lim: Limits): Span =
  ## `s` within `lim`: its width clamped about its centre, then moved inside
  ## the bounds. Unchanged when it is within them already; a span that is
  ## not a number becomes the widest one, centred.
  let b = lim.bounds
  if s.lo.isNaN or s.hi.isNaN or s.lo.classify in {fcInf, fcNegInf} or
      s.hi.classify in {fcInf, fcNegInf}:
    let c = (b.lo + b.hi) / 2
    return Span(lo: c - lim.most / 2, hi: c + lim.most / 2)
  let w = clamp(s.width, lim.least, lim.most)
  result = s
  if w != s.width:
    let c = (s.lo + s.hi) / 2
    result = Span(lo: c - w / 2, hi: c + w / 2)
  if result.lo < b.lo:
    result = Span(lo: b.lo, hi: b.lo + w)
  elif result.hi > b.hi:
    result = Span(lo: b.hi - w, hi: b.hi)

func kept*(v: Viewport; lim: ViewLimits): Viewport =
  ## `v` within `lim` along both axes; its pixel size unchanged.
  result = v
  for a in Axis:
    result.setSpan(a, kept(v.span(a), lim[a]))

func checkFactor(factor: float64) =
  if not (factor > 0 and factor < Inf):
    raise newException(ValueError, "a zoom factor must be positive and finite, got " & $factor)

func zoomed*(s: Span; factor, at: float64; lim: Limits): Span =
  ## `s` zoomed in by `factor` (above 1 zooms in, below 1 out) about `at`,
  ## which stays at the same place in the span, then kept within `lim`.
  ## About the centre when `at` is not a number. Raises `ValueError` for a
  ## factor that is not positive and finite.
  checkFactor(factor)
  if not (s.width > 0):
    return kept(s, lim)
  let anchor = if at.isNaN or at.classify in {fcInf, fcNegInf}: (s.lo + s.hi) / 2 else: at
  let w = clamp(s.width / factor, lim.least, lim.most)
  let f = (anchor - s.lo) / s.width # the anchor's place in the span, 0 to 1 on screen
  let lo = anchor - f * w
  kept(Span(lo: lo, hi: lo + w), lim)

func zoomed*(v: Viewport; factor: float64; at: DataPoint; axes: set[Axis];
    lim: ViewLimits): Viewport =
  ## `v` zoomed by `factor` about `at` along `axes`; the other axis is only
  ## kept within its limits.
  result = v
  for a in Axis:
    if a in axes: result.setSpan(a, zoomed(v.span(a), factor, at.coord(a), lim[a]))
    else: result.setSpan(a, kept(v.span(a), lim[a]))

func centre*(v: Viewport): DataPoint =
  ## The middle of the view.
  DataPoint(x: (v.traces.lo + v.traces.hi) / 2, tMs: (v.timeMs.lo + v.timeMs.hi) / 2)

func panned*(v: Viewport; dx, dtMs: float64; lim: ViewLimits): Viewport =
  ## `v` moved by `dx` positions and `dtMs` ms (positive: later traces and
  ## later times come into view), stopping at the bounds.
  result = v
  result.traces = kept(Span(lo: v.traces.lo + dx, hi: v.traces.hi + dx), lim[axTraces])
  result.timeMs = kept(Span(lo: v.timeMs.lo + dtMs, hi: v.timeMs.hi + dtMs), lim[axTime])

func stepped*(v: Viewport; fx, fy: float64; lim: ViewLimits): Viewport =
  ## `v` moved by `fx` of its width and `fy` of its height (the arrow keys:
  ## `PanStep`, or 1 for a whole view).
  panned(v, fx * v.traces.width, fy * v.timeMs.width, lim)

func dataAt*(v: Viewport; plot: Rect; p: Vec2): DataPoint =
  ## The data point under screen point `p` of a plot drawn in `plot` (any
  ## pixel units, the same for both).
  let w = if plot.size.x > 0: float64(plot.size.x) else: 1.0
  let h = if plot.size.y > 0: float64(plot.size.y) else: 1.0
  DataPoint(x: v.traces.lo + (float64(p.x) - float64(plot.pos.x)) / w * v.traces.width,
    tMs: v.timeMs.lo + (float64(p.y) - float64(plot.pos.y)) / h * v.timeMs.width)

func screenAt*(v: Viewport; plot: Rect; p: DataPoint): Vec2 =
  ## Where data point `p` is drawn in `plot`: the inverse of `dataAt`.
  let fx = if v.traces.width != 0: (p.x - v.traces.lo) / v.traces.width else: 0.0
  let fy = if v.timeMs.width != 0: (p.tMs - v.timeMs.lo) / v.timeMs.width else: 0.0
  vec2(float32(float64(plot.pos.x) + fx * float64(plot.size.x)),
    float32(float64(plot.pos.y) + fy * float64(plot.size.y)))

func dragged*(start: Viewport; plot: Rect; moved: Vec2; lim: ViewLimits): Viewport =
  ## The view while the data is dragged: `start` (the view at the press)
  ## with the pointer `moved` pixels from where it was pressed, so the data
  ## point under it stays under it.
  let w = if plot.size.x > 0: float64(plot.size.x) else: 1.0
  let h = if plot.size.y > 0: float64(plot.size.y) else: 1.0
  panned(start, -float64(moved.x) / w * start.traces.width,
    -float64(moved.y) / h * start.timeMs.width, lim)

func boxed*(v: Viewport; a, b: DataPoint; axes: set[Axis]; lim: ViewLimits): Viewport =
  ## The view of the box with corners `a` and `b` along `axes` (the other
  ## axis as it is), kept within the limits.
  result = v
  for ax in Axis:
    if ax in axes:
      let (p, q) = (a.coord(ax), b.coord(ax))
      result.setSpan(ax, Span(lo: min(p, q), hi: max(p, q)))
  result = kept(result, lim)

func sameSpans*(a, b: Viewport): bool =
  ## Whether `a` and `b` show the same data, whatever their pixel sizes.
  a.traces == b.traces and a.timeMs == b.timeMs
