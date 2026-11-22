## The exclusion area of the record's noisy-trace test (`core/noisearea`) as
## geometry: a band across the time axis behind each run of neighbouring
## traces that were not judged for being inside the area, in the plot's
## screen coordinates, whatever the orientation of the plot. A frontend
## draws them quietly (the data stays readable through them); nothing here
## knows a toolkit.
##
## - The bands follow the traces as the plot shows them (`shown`: the sort
##   order and the filter), so a sorted plot has its bands on the right traces.
## - Only the traces in view are looked at; a band that continues out of view
##   runs to the edge of the plot.

import ../core/[geometry, noisearea, orientation, viewport]
import breakbars

type
  AreaBand* = object
    ## A rectangle in screen pixels.
    a*, b*: Vec2
    first*, last*: int ## the plot's positions of its first and last trace

func areaBands*(n: NoiseSummary; shown: openArray[int]; layout: PanelLayout; view: Viewport;
    m: Turn; plot: Rect): seq[AreaBand] =
  ## The bands of the runs of traces of `layout` in `view` that lie inside the
  ## exclusion area of `n`, in `plot` (pixels), turned as `m` says. `shown[position]`
  ## is the file trace at each position. Empty without a result or an area.
  if not n.hasArea or shown.len == 0 or layout.traces <= 0: return
  let ta = m.along[axTraces]
  let tb = m.along[axTime]
  let perPos = plot.size.along(ta) / max(float32(view.traces.hi - view.traces.lo), 1e-9)
  let vis = visiblePositions(layout, view)
  if vis.b < vis.a: return
  let (t0, t1) = (plot.pos.along(tb), plot.pos.along(tb) + plot.size.along(tb))
  var run = -1 # the position a run began at
  func close(result: var seq[AreaBand]; first, last: int) =
    let c0 = screenOf(view, m, plot, axTraces, float64(first))
    let c1 = screenOf(view, m, plot, axTraces, float64(last))
    let (lo, hi) = (min(c0, c1) - perPos / 2, max(c0, c1) + perPos / 2)
    let (p0, p1) = (max(lo, plot.pos.along(ta)), min(hi, plot.pos.along(ta) + plot.size.along(ta)))
    if p1 > p0:
      result.add AreaBand(a: tb.other.at(p0, t0), b: tb.other.at(p1, t1), first: first, last: last)
  let last = min(vis.b, shown.high)
  for p in vis.a .. last:
    let inside = n.insideAt(shown[p])
    if inside and run < 0: run = p
    elif not inside and run >= 0:
      result.close(run, p - 1)
      run = -1
  if run >= 0: result.close(run, last)
