## When a graph's axes are fitted to its data again, one rule for every
## graph window (the helper `drawCurvePlot` calls each frame).
##
## - A change of the graph's **options** (its `optionKey`: the scale, the
##   phase picture, the traces' kind, the units ...) fits both axes to the
##   new data, even when the user had zoomed: the old zoom is in other
##   units.
## - **New data** under the same options (another trace, record or file; a
##   filter): an axis whose limits changed is fitted again unless the user
##   has zoomed or panned it since it was last fitted, and then it is kept.
##   The x axis is the exception: its range changing (another file's sample
##   interval or length) fits it whatever the zoom.
## - **Fit** (ImPlot's double click) puts an axis back on the data's limits,
##   which clears its "zoomed" state, as the next `seen` finds the view on
##   them.
##
## The caller keeps one `AxisFit` per plot, asks `plan` before it sets the
## axes up, and reports the view it ended the frame with to `seen`.

import std/math
import ../core/viewport

export Span

type
  AxisFit* = object
    ## What the axes of one plot were last fitted to.
    started: bool
    optionKey: string
    data: array[2, Span]   ## the data's limits, x then y, at the last plan
    fitted: array[2, Span] ## the limits the axes were last fitted to
    zoomed: array[2, bool] ## the view is not the one last fitted
    fresh: array[2, bool]  ## fitted this frame: its view is the fit, whatever it reads

  FitPlan* = object
    ## Which axes to set to the data's limits this frame.
    x*, y*: bool

const RelativeMinSpan* = 1e-3
  ## the smallest span of an axis of a quantity with no unit of its own (as recorded):
  ## this fraction of the larger limit's magnitude

func minSpanOf*(unit: string; lo, hi: float64): float64 =
  ## The smallest span an auto-fitted axis of a quantity in `unit` shows, so that constant
  ## data is a flat line and rounding noise is not stretched to fill the pane: a phase
  ## 2° (±1°), dB 1, percent 1, Hz 1; any other (a dimensionless or "as recorded" quantity):
  ## a thousandth of the larger limit's magnitude, and 1e-12 at the least.
  case unit
  of "°", "deg", "degrees": 2.0
  of "dB", "%", "Hz": 1.0
  else: max(RelativeMinSpan * max(abs(lo), abs(hi)), 1e-12)

func atLeast*(s: Span; minSpan: float64): Span =
  ## `s`, widened about its middle to span `minSpan` when it is narrower.
  if not (s.hi - s.lo < minSpan): return s
  let mid = (s.lo + s.hi) / 2
  Span(lo: mid - minSpan / 2, hi: mid + minSpan / 2)

func near(a, b: Span): bool =
  let tol = 1e-9 * max(1.0, max(abs(b.hi - b.lo), max(abs(b.lo), abs(b.hi))))
  abs(a.lo - b.lo) <= tol and abs(a.hi - b.hi) <= tol

func plan*(f: var AxisFit; optionKey: string; x, y: Span; follow = true): FitPlan =
  ## What to fit this frame for data with limits `x` and `y` under
  ## `optionKey`. `follow` false: only an option change fits (the view stays
  ## where the user left it for new data).
  let now = [x, y]
  if not f.started or optionKey != f.optionKey:
    f.started = true
    f.optionKey = optionKey
    f.data = now
    f.fitted = now
    f.zoomed = [false, false]
    f.fresh = [true, true]
    return FitPlan(x: true, y: true)
  var fit = [false, false]
  if follow:
    if not near(now[0], f.data[0]): fit[0] = true
    if not near(now[1], f.data[1]) and not f.zoomed[1]: fit[1] = true
  f.data = now
  for i in 0 .. 1:
    if fit[i]:
      f.fitted[i] = now[i]
      f.zoomed[i] = false
      f.fresh[i] = true
  FitPlan(x: fit[0], y: fit[1])

func seen*(f: var AxisFit; x, y: Span) =
  ## The view the frame ended with: an axis not on the limits it was
  ## fitted to has been zoomed or panned by the user.
  if not f.started: return
  let now = [x, y]
  for i in 0 .. 1:
    f.zoomed[i] = not f.fresh[i] and not near(now[i], f.fitted[i])
    f.fresh[i] = false

func userZoomed*(f: AxisFit; x: bool): bool =
  ## Whether the user moved axis x (else y) off its fit.
  f.zoomed[if x: 0 else: 1]

func finite(x: float64): bool {.inline.} = x.classify in {fcNormal, fcSubnormal, fcZero, fcNegZero}

func degenerate*(view, data: Span; zoomed: bool): bool =
  ## Whether an axis showing `view` is one the user cannot read, for data
  ## spanning `data` (finite, or nothing is judged): the view's limits are not
  ## numbers or have no span; or, the user not having zoomed it, it holds no
  ## part of the data. The caller fits the axis to the data again.
  if not (data.lo.finite and data.hi.finite): return false
  if not (view.lo.finite and view.hi.finite) or not (view.hi > view.lo): return true
  not zoomed and (view.hi < data.lo or view.lo > data.hi)
