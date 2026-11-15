## How a panel's view moves: zoom about a point, along one axis or both,
## pan, drag, box zoom, a new plot size and the scroll bars, all kept within
## the limits the panel's traces set.
##
## Views are moved in data coordinates (`core/viewport`): positions and ms,
## whichever way the plot is turned (`core/orientation`). Every change
## keeps the view within `limitsOf(layout)`:
##
## - its edges inside the data: from the first trace's outer edge to the
##   last trace's, from the record's start to its last sample. Nothing
##   past the data is ever shown, and zoomed out as far as it goes the data
##   fills the plot exactly. The one exception is `margin`: the wiggle modes
##   reach past the first and last trace by the swing the trace overlap
##   allows (`core/panels.viewLimits`), so those traces' outer lobes are
##   shown whole, and nothing else is drawn there;
## - never narrower than `MinTraces` positions or `MinSamples` samples;
## - never wider than the data, nor than `widest` positions (the wiggle
##   modes: the plot's pixels along the positions, so every trace in view
##   is drawn; `core/panels.viewLimits`). Zoomed out as far as it goes, such a
##   view shows `widest` positions of a larger record, and the scroll bar
##   the rest. The time axis has no such limit.
##
## A zoom keeps the point it is about where it is on the screen; a zoom
## that reaches a limit stops there. A view that is already within the
## limits is left exactly as it is. `fitted` is the widest view the limits
## allow, from the first trace.
##
## **A new plot size** (`resized`) always keeps the scale (data per pixel)
## and the corner of the first position and the earliest time (the top-left
## one): a smaller plot shows less, with scroll bars, a larger one more, as
## a sheet of paper would. Only where the plot becomes larger than all the
## data at that scale does the scale grow, as far as fills the plot. A view
## that the limits make narrower (`keptFrom`) keeps its first position or
## its earliest time.
##
## **The next gather** (`carried`) is shown at the same scales: the same
## positions and times, or all of it along an axis that showed all of the
## gather before (as much as the limits allow, from its start).
##
## **Scroll bars.** Along an axis where part of the data is out of view
## (`showsAll` is false) the plot has a scroll bar. Its thumb (`thumbOf`) is
## as long as the share of the data in view and lies where the view lies;
## dragging it (`scrolled`) or clicking the track (`paged`) pans.
##
## The frontend turns the pointer into data coordinates with `dataAt`
## (`core/orientation`: which way the plot is turned) and calls these. The
## gestures that start on the screen (`dragged`, the scroll bars) take the
## plot's `Turn`, so they act in the screen's directions whichever way it
## is turned. A map view can use the `Span` forms.

import std/math
import geometry, orientation, viewport

export orientation

const
  MinTraces* = 4.0  ## the narrowest view, in positions
  MinSamples* = 8.0 ## the shortest view, in samples
  WheelStep* = 1.25 ## the zoom of one wheel notch
  KeyStep* = 1.5    ## the zoom of one key press or button click
  PanStep* = 0.1    ## the fraction of the view an arrow key pans by

type
  Limits* = object
    ## What a view is kept within along one axis: its edges inside
    ## `bounds`, its width from `least` to `most`.
    bounds*: Span
    least*, most*: float64

  ViewLimits* = array[Axis, Limits]

  Thumb* = object
    ## Where a scroll bar's thumb lies on its track, in pixels from the
    ## track's start (its left or top end).
    start*, length*: float64

const BothAxes* = {axTraces, axTime}

func limitsOf*(layout: PanelLayout; widest = Inf; margin = 0.0): ViewLimits =
  ## The limits of a panel with `layout`: the data's extent, positions
  ## `-0.5 .. traces - 0.5` and `t0Ms` to the last sample's time (what
  ## `fitAll` shows), the positions reaching `margin` further on each side;
  ## a view at most `widest` positions wide (a value that is not positive
  ## counts as no limit). A panel with no traces or no sample interval gets
  ## limits for one trace and 1 ms samples.
  let n = float64(max(layout.traces, 1))
  let dt = if layout.dtMs > 0 and layout.dtMs < Inf: layout.dtMs else: 1.0
  let t0 = if layout.t0Ms.classify in {fcNan, fcInf, fcNegInf}: 0.0 else: layout.t0Ms
  let extent = float64(max(layout.samples - 1, 1)) * dt
  let m = if margin > 0 and margin < Inf: margin else: 0.0
  let across = n + 2 * m
  let most = if widest > 0: min(across, widest) else: across # NaN fails the test too
  result[axTraces] = Limits(bounds: Span(lo: -0.5 - m, hi: n - 0.5 + m),
    least: min(MinTraces, most), most: most)
  result[axTime] = Limits(bounds: Span(lo: t0, hi: t0 + extent),
    least: min(MinSamples * dt, extent), most: extent)

func fitted*(lim: ViewLimits; columns, rows: int): Viewport =
  ## The widest view `lim` allows on a plot of `columns` × `rows` pixels,
  ## from the first trace and the record's start: all the data, unless a
  ## wiggle mode's limit (`widest`) makes it narrower.
  let b = lim[axTraces].bounds
  Viewport(traces: Span(lo: b.lo, hi: b.lo + min(lim[axTraces].most, b.width)),
    timeMs: lim[axTime].bounds, columns: columns, rows: rows)

proc setSpan(v: var Viewport; a: Axis; s: Span) {.inline.} =
  if a == axTraces: v.traces = s else: v.timeMs = s

func coord(p: DataPoint; a: Axis): float64 {.inline.} =
  if a == axTraces: p.x else: p.tMs

func placed(lo, w: float64; b: Span): Span =
  ## A span `w` wide from `lo`, moved inside `b` where it is not; `b` itself,
  ## exactly, when `w` is as wide as `b` or wider. The width is the one
  ## given, never taken back from a span made with it (`(lo + w) - lo` is
  ## not always `w`, and an optimised build that fuses `a - f * w` rounds
  ## differently again), so the widest view is the bounds in every build.
  if not (w < b.width): b
  elif lo <= b.lo: Span(lo: b.lo, hi: min(b.lo + w, b.hi))
  elif lo + w >= b.hi: Span(lo: max(b.hi - w, b.lo), hi: b.hi)
  else: Span(lo: lo, hi: lo + w)

func notFinite(s: Span): bool {.inline.} =
  s.lo.classify in {fcNan, fcInf, fcNegInf} or s.hi.classify in {fcNan, fcInf, fcNegInf}

func kept*(s: Span; lim: Limits): Span =
  ## `s` within `lim`: its width clamped about its centre, then moved inside
  ## the bounds. Unchanged when it is within them already; a span that is
  ## not a number becomes the widest one, centred.
  let b = lim.bounds
  if s.notFinite:
    let c = (b.lo + b.hi) / 2
    return Span(lo: c - lim.most / 2, hi: c + lim.most / 2)
  let w = clamp(s.width, lim.least, lim.most)
  if w == s.width and s.lo >= b.lo and s.hi <= b.hi:
    return s
  let lo = if w != s.width: (s.lo + s.hi) / 2 - w / 2 else: s.lo
  placed(lo, w, b)

func kept*(v: Viewport; lim: ViewLimits): Viewport =
  ## `v` within `lim` along both axes; its pixel size unchanged.
  result = v
  for a in Axis:
    result.setSpan(a, kept(v.span(a), lim[a]))

func keptFrom*(lo, width: float64; lim: Limits): Span =
  ## A span `width` wide from `lo` within `lim`: the width clamped, keeping
  ## `lo`, then moved inside the bounds; the bounds exactly when it is as
  ## wide as they are. `width` is taken as given (see `placed`).
  if lo.classify in {fcNan, fcInf, fcNegInf} or width.classify in {fcNan, fcInf, fcNegInf}:
    return kept(Span(lo: lo, hi: lo + width), lim)
  placed(lo, clamp(width, lim.least, lim.most), lim.bounds)

func keptFrom*(s: Span; lim: Limits): Span =
  ## `s` within `lim`, as `kept`, but a span too wide or too narrow keeps
  ## its start (`lo`: the left or top edge), as a page does when its scale
  ## changes, before it is moved inside the bounds.
  if s.notFinite:
    return kept(s, lim)
  let b = lim.bounds
  let w = clamp(s.width, lim.least, lim.most)
  if w == s.width and w < b.width and s.lo >= b.lo and s.hi <= b.hi: s
  else: placed(s.lo, w, b)

func keptFrom*(v: Viewport; lim: ViewLimits): Viewport =
  ## `v` within `lim` along both axes from its top-left corner (`keptFrom`
  ## of each span); its pixel size unchanged.
  result = v
  for a in Axis:
    result.setSpan(a, keptFrom(v.span(a), lim[a]))

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
  placed(anchor - f * w, w, lim.bounds)

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

func moved(s: Span; d: float64; lim: Limits): Span =
  ## `s` moved by `d` and kept within `lim`, as wide as `s` (`placed`).
  if d == 0 or s.notFinite or d.classify in {fcNan, fcInf, fcNegInf}:
    kept(Span(lo: s.lo + d, hi: s.hi + d), lim)
  else:
    placed(s.lo + d, clamp(s.width, lim.least, lim.most), lim.bounds)

func panned*(v: Viewport; dx, dtMs: float64; lim: ViewLimits): Viewport =
  ## `v` moved by `dx` positions and `dtMs` ms (positive: later traces and
  ## later times come into view), stopping at the bounds.
  result = v
  result.traces = moved(v.traces, dx, lim[axTraces])
  result.timeMs = moved(v.timeMs, dtMs, lim[axTime])

func stepped*(v: Viewport; fx, fy: float64; lim: ViewLimits): Viewport =
  ## `v` moved by `fx` of its width and `fy` of its height (the arrow keys:
  ## `PanStep`, or 1 for a whole view).
  panned(v, fx * v.traces.width, fy * v.timeMs.width, lim)

func dragged*(start: Viewport; plot: Rect; moved: Vec2; lim: ViewLimits;
    m = TimeDown): Viewport =
  ## The view while the data is dragged: `start` (the view at the press)
  ## with the pointer `moved` pixels from where it was pressed, so the data
  ## point under it stays under it, on a plot turned as `m` says.
  let w = if plot.size.x > 0: float64(plot.size.x) else: 1.0
  let h = if plot.size.y > 0: float64(plot.size.y) else: 1.0
  let (fx, ft) = m.dataDelta(float64(moved.x) / w, float64(moved.y) / h)
  panned(start, -fx * start.traces.width, -ft * start.timeMs.width, lim)

func boxed*(v: Viewport; a, b: DataPoint; axes: set[Axis]; lim: ViewLimits): Viewport =
  ## The view of the box with corners `a` and `b` along `axes` (the other
  ## axis as it is), kept within the limits.
  result = v
  for ax in Axis:
    if ax in axes:
      let (p, q) = (a.coord(ax), b.coord(ax))
      result.setSpan(ax, Span(lo: min(p, q), hi: max(p, q)))
  result = kept(result, lim)

func showsAll*(v: Viewport; a: Axis; lim: ViewLimits): bool =
  ## Whether `v` shows all the data along `a` (then the plot has no scroll
  ## bar along it).
  let s = v.span(a)
  let b = lim[a].bounds
  let eps = 1e-9 * b.width
  s.lo <= b.lo + eps and s.hi >= b.hi - eps

func resized*(v: Viewport; columns, rows: int; lim: ViewLimits): Viewport =
  ## `v` on a plot of `columns` × `rows` pixels: along each axis it keeps
  ## its scale (data per pixel) and its left or top edge, so more or less of
  ## the data comes into view, never more than there is (then the scale
  ## grows as far as fills the plot). Along an axis whose old or new size is
  ## unknown (0) the span is only kept within the limits (`lim`: the limits
  ## on the new size), from its left or top edge.
  result = v
  result.columns = columns
  result.rows = rows
  for a in Axis:
    let (was, now) = if a == axTraces: (v.columns, columns) else: (v.rows, rows)
    let s = v.span(a)
    if was > 0 and now > 0 and now != was:
      result.setSpan(a, keptFrom(s.lo, s.width * float64(now) / float64(was), lim[a]))
    else:
      result.setSpan(a, keptFrom(s, lim[a]))

func relimited*(v: Viewport; was, now: ViewLimits): Viewport =
  ## `v`, a view within `was`, within new limits `now` of the same data (the
  ## display mode or the trace overlap changed): along an axis where it
  ## showed all the data it shows all of it again (as much as `now` allows,
  ## from its start); along the others it stays where it is, narrowed from
  ## its left or top edge, or moved inside, only where `now` makes it.
  result = v
  for a in Axis:
    if v.showsAll(a, was): result.setSpan(a, keptFrom(now[a].bounds, now[a]))
    else: result.setSpan(a, keptFrom(v.span(a), now[a]))

func carried*(v: Viewport; was, now: ViewLimits): Viewport =
  ## `v`, a view of data within `was`, on the next gather, within `now`, at
  ## the same scales: along an axis where it showed all the data it shows
  ## all of the new (as much as `now` allows, from its start); along the
  ## others the same positions or times, kept within `now` (so they
  ## compare, record after record). Its pixel size unchanged.
  result = v
  for a in Axis:
    if v.showsAll(a, was): result.setSpan(a, keptFrom(now[a].bounds, now[a]))
    else: result.setSpan(a, kept(v.span(a), now[a]))

func thumbOf*(v: Viewport; a: Axis; lim: ViewLimits; track, least: float64;
    m = TimeDown): Thumb =
  ## The thumb of the scroll bar along `a` on a track `track` pixels long:
  ## as long as the share of the data in view, but at least `least` pixels
  ## (so it can be grabbed), and as far along the track as the view is along
  ## the data, from the track's left or top end (`m`: the end where the
  ## data starts on the screen). The whole track when everything is in view.
  let s = kept(v.span(a), lim[a])
  let b = lim[a].bounds
  if not (track > 0): return Thumb(start: 0, length: 0)
  let length = clamp(track * s.width / b.width, min(least, track), track)
  let room = track - length # pixels the thumb can move through
  let free = b.width - s.width # data the view can move through
  let start = if free > 0 and room > 0: room * (s.lo - b.lo) / free else: 0.0
  let along = clamp(start, 0, room)
  Thumb(start: (if m.reversed[a]: room - along else: along), length: length)

func scrolled*(start: Viewport; a: Axis; lim: ViewLimits; track, least, moved: float64;
    m = TimeDown): Viewport =
  ## The view while the thumb along `a` is dragged: `start` (the view when it
  ## was grabbed) with the thumb `moved` pixels further along its track
  ## (rightwards or downwards; `track`, `least` and `m` as for `thumbOf`), so
  ## the thumb stays under the pointer, stopping at the track's ends.
  let th = thumbOf(start, a, lim, track, least)
  let room = track - th.length
  let free = lim[a].bounds.width - kept(start.span(a), lim[a]).width
  let d = if room > 0 and free > 0: moved * m.sign(a) / room * free else: 0.0
  if a == axTraces: panned(start, d, 0, lim) else: panned(start, 0, d, lim)

func paged*(v: Viewport; a: Axis; pages: float64; lim: ViewLimits; m = TimeDown): Viewport =
  ## `v` moved by `pages` of its own width along `a`, rightwards or
  ## downwards on the screen (`m`): a click on a scroll bar's track before
  ## the thumb is -1, after it +1.
  let d = pages * m.sign(a)
  if a == axTraces: stepped(v, d, 0, lim) else: stepped(v, 0, d, lim)

func sameSpans*(a, b: Viewport): bool =
  ## Whether `a` and `b` show the same data, whatever their pixel sizes.
  a.traces == b.traces and a.timeMs == b.timeMs
