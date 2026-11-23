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
##   times of the traces, the model's and the pick's: for each pixel column
##   from the earliest to the latest time of the traces in it, so no trace's
##   time is dropped; a flagged trace is drawn on its own as well.
## - A pick the fit finds off the model (`mismatched`) has a link along time
##   between the two bars and a heavier pick bar.
## - Times are drawn where the plot draws that sample: each trace's own time
##   axis moved to the layout's (`shiftOf`).
## - A pick not compared with the model (`faintOf`: low confidence, or no break found) is
##   `faint`.

import std/math
import ../core/[firstbreaks, geometry, orientation, panels, viewport]

const
  LineBelow* = 3.0     ## pixels a trace, under which the marks are lines
  MaxLineMarks* = 2000 ## the most flagged traces drawn on their own in a line

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

func barWidth*(size: BreakSize; perPos, ui: float32): float32 =
  ## How long the model's bar is, in pixels, for traces `perPos` pixels apart on a screen
  ## whose interface scale is `ui` (1 = 100 %): a share of one trace's width, kept between
  ## a least (so it shows on a dense record) and a most. Small is the overlay's first size,
  ## with no least.
  case size
  of bzSmall: min(perPos * 0.8, 40 * ui)
  of bzMedium: clamp(perPos * 0.8, 7 * ui, 40 * ui)
  of bzLarge: clamp(perPos, 10 * ui, 60 * ui)

func pickShare*(size: BreakSize): float32 =
  ## The pick's bar's length as a share of the model's (a little shorter, so a pick on the
  ## model leaves its ends showing).
  if size == bzSmall: 0.7 else: 0.8

func barThickness*(size: BreakSize; kind: MarkKind; heavy, lines: bool): float32 =
  ## A mark's thickness in interface units (a pixel at 100 %; the frontend scales it): at
  ## least 3 for a bar, a pick that disagrees with the model heavier, a line thinner.
  if kind == bmLink: return 1.4
  if lines: return (if size == bzLarge: 2.2 else: 1.8)
  case size
  of bzSmall: (if kind == bmModel: 2.6 elif heavy: 4.0 else: 3.2)
  of bzMedium: (if kind == bmPick and heavy: 5.0 else: 3.4)
  of bzLarge: (if kind == bmPick and heavy: 6.5 else: 4.6)

func shows*(k: MarkKind; picks, model: bool): bool {.inline.} =
  ## Whether a mark of kind `k` is drawn when the picks are shown (`picks`) and the model is
  ## (`model`): each bar by its own switch, the joining line only when both are.
  case k
  of bmModel: model
  of bmPick: picks
  of bmLink: picks and model

func along*(p: Vec2; s: ScreenAxis): float32 {.inline.} =
  if s == saX: p.x else: p.y

func at*(s: ScreenAxis; a, b: float32): Vec2 {.inline.} =
  ## The point `a` along screen axis `s` and `b` along the other.
  if s == saX: Vec2(x: a, y: b) else: Vec2(x: b, y: a)

func other*(s: ScreenAxis): ScreenAxis {.inline.} = (if s == saX: saY else: saX)

func screenOf*(view: Viewport; m: Turn; plot: Rect; axis: Axis; value: float64): float32 =
  ## Where `value` (a position, or ms) lies on the screen along `axis`'s screen axis.
  let s = m.along[axis]
  let span = if axis == axTraces: view.traces else: view.timeMs
  let extent = plot.size.along(s)
  let d = float32((value - span.lo) * float64(extent) / max(span.hi - span.lo, 1e-9))
  if m.reversed[axis]: plot.pos.along(s) + extent - d else: plot.pos.along(s) + d

func breakGeometry*(b: FirstBreaks; shown: openArray[int]; layout: PanelLayout;
    view: Viewport; m: Turn; plot: Rect; size = bzMedium; ui = 1'f32;
    showWeak = true): BreakGeometry =
  ## The marks of the traces of `layout` in `view`, in `plot` (pixels),
  ## turned as `m` says, bars of `size` (`barWidth`; `ui`: the interface scale). `shown[position]`
  ## is the file trace at each position. Without `showWeak` a pick that is `faint` has no mark.
  ## Empty unless `b` is done.
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
    let half = barWidth(size, perPos, ui) / 2
    for p in vis.a .. min(vis.b, shown.high):
      let trace = shown[p]
      let sh = b.shiftOf(trace)
      let (model, pick) = (b.modelOf(trace) + sh, b.pickOf(trace) + sh)
      let c = centre(p)
      let off = b.mismatched(trace)
      var ym, yp = NaN.float32
      if not model.isNaN: ym = screenOf(view, m, plot, axTime, model)
      if not pick.isNaN: yp = screenOf(view, m, plot, axTime, pick)
      if not ym.isNaN and inside(ym):
        result.marks.add BreakMark(kind: bmModel, a: tb.other.at(c - half, ym),
          b: tb.other.at(c + half, ym), position: p, trace: trace)
      if not yp.isNaN and inside(yp) and (showWeak or not b.faintOf(trace)):
        let h = half * pickShare(size)
        result.marks.add BreakMark(kind: bmPick, a: tb.other.at(c - h, yp),
          b: tb.other.at(c + h, yp), position: p, trace: trace,
          faint: b.faintOf(trace), heavy: off)
      if off and not ym.isNaN and not yp.isNaN and (inside(ym) or inside(yp)):
        result.marks.add BreakMark(kind: bmLink, a: tb.other.at(c, ym), b: tb.other.at(c, yp),
          position: p, trace: trace)
  else:
    # a line through the times, drawn per pixel column from the earliest to the
    # latest time any trace of the column has (so no trace's time is dropped when
    # several share a pixel), and each flagged trace on its own
    let width = int(ceil(plot.size.along(ta))) + 1
    var lo, hi: array[bmModel .. bmPick, seq[float32]]
    for k in bmModel .. bmPick:
      lo[k] = newSeq[float32](width)
      hi[k] = newSeq[float32](width)
      for i in 0 ..< width:
        lo[k][i] = Inf
        hi[k][i] = -Inf
    var flagged = 0
    for p in vis.a .. min(vis.b, shown.high):
      let trace = shown[p]
      let sh = b.shiftOf(trace)
      let c = centre(p)
      let col = clamp(int(floor(c - plot.pos.along(ta))), 0, width - 1)
      var ys: array[bmModel .. bmPick, float32]
      for (kind, value) in [(bmModel, b.modelOf(trace) + sh), (bmPick, b.pickOf(trace) + sh)]:
        ys[kind] = NaN.float32
        if not value.isNaN and (showWeak or kind == bmModel or not b.faintOf(trace)):
          ys[kind] = screenOf(view, m, plot, axTime, value)
          if inside(ys[kind]):
            lo[kind][col] = min(lo[kind][col], ys[kind])
            hi[kind][col] = max(hi[kind][col], ys[kind])
      if b.mismatched(trace) and flagged < MaxLineMarks and not ys[bmModel].isNaN and
          not ys[bmPick].isNaN:
        inc flagged
        result.marks.add BreakMark(kind: bmLink, a: tb.other.at(c, ys[bmModel]),
          b: tb.other.at(c, ys[bmPick]), position: p, trace: trace)
        result.marks.add BreakMark(kind: bmPick, a: tb.other.at(c - 2, ys[bmPick]),
          b: tb.other.at(c + 2, ys[bmPick]), position: p, trace: trace, heavy: true)
    for kind in bmModel .. bmPick:
      for col in 0 ..< width:
        if hi[kind][col] >= lo[kind][col]:
          # at least a pixel long, so a column of one time shows
          let (y0, y1) = (lo[kind][col] - 0.6, hi[kind][col] + 0.6)
          let x = plot.pos.along(ta) + float32(col) + 0.5
          result.marks.add BreakMark(kind: kind, a: tb.other.at(x, y0), b: tb.other.at(x, y1),
            position: -1, trace: -1)
