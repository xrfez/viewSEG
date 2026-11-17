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
