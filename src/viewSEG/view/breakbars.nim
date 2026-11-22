## The first-break overlay as geometry: for each trace in view, a short bar
## across the trace's column at the time the model expects the first break,
## and another at the time it was picked (`core/firstbreaks`), in the plot's
## screen coordinates, whatever the orientation of the plot. A frontend draws
## the marks; nothing here knows a toolkit.
##
## - The bars follow the traces as the plot shows them: a position of the
##   plot is the trace the reader put there (`shown`: the sort order and the
##   filter), so a sorted or filtered plot has its bars on the right traces.
## - Only the traces in view are looked at.
## - Where the traces are closer than `LineBelow` pixels, a bar would be
##   narrower than its own thickness: the bars become a line through the
##   times of the traces (one per pixel or so), the model's and the pick's.
## - A pick that differs from the model by more than the tolerance
##   (`mismatched`) has a link along time between the two bars and a heavier
##   pick bar.
## - A pick of low confidence (below `ConfidentPick`) is `faint`.

import std/math
import ../core/[firstbreaks, geometry, orientation, viewport]

const
  LineBelow* = 3.0     ## pixels a trace, under which the marks are lines
  MaxBarShare* = 0.8   ## of the trace's column a bar spans, at most
  MaxBarPixels* = 40.0 ## the longest a bar is
  MaxLineMarks* = 4000 ## the most segments of a line

type
  MarkKind* = enum
    bmModel ## the model's bar or line
    bmPick  ## the pick's
    bmLink  ## joins the two of a mismatched trace

  BreakMark* = object
    ## A segment, in screen pixels.
    kind*: MarkKind
    a*, b*: Vec2
    position*: int ## the plot's position of the trace (a line's: of its first end)
    trace*: int    ## the trace's number in its file (-1 for a line)
    faint*: bool   ## a pick of low confidence
    heavy*: bool   ## a pick that disagrees with the model

  BreakGeometry* = object
    marks*: seq[BreakMark]
    lines*: bool          ## the marks are lines through the traces, not a bar each
    perPosition*: float32 ## the pixels between two traces

func along(p: Vec2; s: ScreenAxis): float32 {.inline.} =
  if s == saX: p.x else: p.y

func at(s: ScreenAxis; a, b: float32): Vec2 {.inline.} =
  ## The point `a` along screen axis `s` and `b` along the other.
  if s == saX: Vec2(x: a, y: b) else: Vec2(x: b, y: a)

func other(s: ScreenAxis): ScreenAxis {.inline.} = (if s == saX: saY else: saX)

func screenOf(view: Viewport; m: Turn; plot: Rect; axis: Axis; value: float64): float32 =
  ## Where `value` (a position, or ms) lies on the screen along `axis`'s screen axis.
  let s = m.along[axis]
  let span = if axis == axTraces: view.traces else: view.timeMs
  let extent = plot.size.along(s)
  let d = float32((value - span.lo) * float64(extent) / max(span.hi - span.lo, 1e-9))
  if m.reversed[axis]: plot.pos.along(s) + extent - d else: plot.pos.along(s) + d

func breakGeometry*(b: FirstBreaks; shown: openArray[int]; layout: PanelLayout;
    view: Viewport; m: Turn; plot: Rect): BreakGeometry =
  ## The marks of the traces of `layout` in `view`, in `plot` (pixels),
  ## turned as `m` says. `shown[position]` is the file trace at each
  ## position. Empty unless `b` is done.
  result = BreakGeometry()
  if b.state != bkDone or shown.len == 0 or layout.traces <= 0: return
  let ta = m.along[axTraces]
  let tb = m.along[axTime]
  let perPos = plot.size.along(ta) / max(float32(view.traces.hi - view.traces.lo), 1e-9)
  result.perPosition = perPos
  let vis = visiblePositions(layout, view)
  if vis.b < vis.a: return
  let (t0, t1) = (plot.pos.along(tb), plot.pos.along(tb) + plot.size.along(tb))
  func inside(y: float32): bool = y >= t0 - 2 and y <= t1 + 2
  func centre(p: int): float32 = screenOf(view, m, plot, axTraces, float64(p))
  result.lines = perPos < LineBelow
  if not result.lines:
    let half = min(perPos * MaxBarShare, MaxBarPixels) / 2
    for p in vis.a .. min(vis.b, shown.high):
      let trace = shown[p]
      let (model, pick) = (b.modelOf(trace), b.pickOf(trace))
      let c = centre(p)
      let off = b.mismatched(trace)
      var ym, yp = NaN.float32
      if not model.isNaN: ym = screenOf(view, m, plot, axTime, model)
      if not pick.isNaN: yp = screenOf(view, m, plot, axTime, pick)
      if not ym.isNaN and inside(ym):
        result.marks.add BreakMark(kind: bmModel, a: tb.other.at(c - half, ym),
          b: tb.other.at(c + half, ym), position: p, trace: trace)
      if not yp.isNaN and inside(yp):
        let h = half * 0.7
        result.marks.add BreakMark(kind: bmPick, a: tb.other.at(c - h, yp),
          b: tb.other.at(c + h, yp), position: p, trace: trace,
          faint: b.confidenceOf(trace) < ConfidentPick, heavy: off)
      if off and not ym.isNaN and not yp.isNaN and (inside(ym) or inside(yp)):
        result.marks.add BreakMark(kind: bmLink, a: tb.other.at(c, ym), b: tb.other.at(c, yp),
          position: p, trace: trace)
  else:
    # a line through the times: one point about a pixel, joined where the
    # traces next to each other both have a time
    let step = max(1, int(ceil(1.0 / max(perPos, 1e-3))))
    var prevModel, prevPick: (bool, Vec2, int)
    var p = vis.a
    while p <= min(vis.b, shown.high) and result.marks.len < MaxLineMarks:
      let trace = shown[p]
      let c = centre(p)
      for (kind, value) in [(bmModel, b.modelOf(trace)), (bmPick, b.pickOf(trace))]:
        var pt: (bool, Vec2, int)
        pt[0] = not value.isNaN
        pt[2] = p
        if pt[0]:
          pt[1] = tb.other.at(c, screenOf(view, m, plot, axTime, value))
        let prev = if kind == bmModel: prevModel else: prevPick
        if pt[0] and prev[0] and inside(pt[1].along(tb)) and inside(prev[1].along(tb)) and
            p - prev[2] <= 2 * step:
          result.marks.add BreakMark(kind: kind, a: prev[1], b: pt[1], position: prev[2],
            trace: -1, faint: false)
        if kind == bmModel: prevModel = pt else: prevPick = pt
      p += step
