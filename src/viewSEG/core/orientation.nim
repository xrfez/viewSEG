## Which way a plot is turned, and the one mapping between its data and the
## screen (docs/plot-window.md, "Orientation").
##
## A panel's view (`core/viewport`) is the same whichever way its plot is
## turned: a span of positions, a span of ms, and the plot's pixels along
## each (`Viewport.columns` along the positions, `rows` along time). So the
## limits, the zoom, the scales, the stride and decimation a view is read
## at and its read-ahead never depend on the orientation. Only where those
## two axes lie on the screen does, and every part of the plot asks that of
## a `Turn`:
##
## - **time down** (`orTimeDown`), as seismic is plotted: the positions
##   across the screen from the left, time down it; a positive amplitude
##   swings right, towards the next trace;
## - **time across** (`orTimeAcross`), as a signal is usually drawn: time
##   across from the left, the positions down from the top (or up from the
##   bottom: `FirstTraceAtTop`); a positive amplitude swings up.
##
## `dataAt` and `screenAt` take a point of the plot on the screen to a data
## point and back; `dataDelta` turns a move on the screen (a drag, an arrow
## key) into moves along the data's axes; `axisAlong` names the data axis a
## screen axis shows (the wheel and the keys that zoom along one axis, the
## scroll bars, a box zoom); `sized`, `screenSize` and `screenPixel` lay the
## plot's image out, `ndcOf` and `ndcMap` give the GPU the same mapping, and
## `Turn.swing` says which way a positive amplitude swings along the
## positions. Nothing else in the program knows which way a plot is turned.

import geometry, viewport

const FirstTraceAtTop* = true
  ## time across: the first trace at the top, the others below it in the
  ## order shown; false puts it at the bottom (the time-down picture turned
  ## a quarter turn anticlockwise). Either way a positive amplitude swings
  ## up.

type
  Axis* = enum
    ## A data axis of a panel.
    axTraces = "traces" ## positions
    axTime = "time"     ## ms

  DataPoint* = object
    ## A point of a panel in data coordinates.
    x*: float64   ## positions
    tMs*: float64 ## ms

  Orientation* = enum
    ## Which way a plot is turned.
    orTimeDown = "time down"     ## traces across, time downwards: seismic
    orTimeAcross = "time across" ## time from left to right, the traces stacked: signals

  ScreenAxis* = enum
    ## An axis of the screen.
    saX = "across" ## the plot's width, from its left edge
    saY = "down"   ## its height, from its top edge

  Turn* = object
    ## How a plot's data axes lie on the screen: the one mapping between
    ## data and screen (`turnOf`).
    orientation*: Orientation
    along*: array[Axis, ScreenAxis] ## the screen axis each data axis runs along
    reversed*: array[Axis, bool]
      ## the data axis grows from the plot's right or bottom edge, against
      ## its screen axis
    swing*: float64
      ## 1: a positive amplitude swings towards later positions; -1:
      ## towards earlier ones (time across, the first trace at the top: up)

  NdcMap* = object
    ## Where a point of a view falls in OpenGL's normalised device
    ## coordinates (-1 to 1 across the plot, y up), from its offsets from the
    ## view's first position and earliest time: `x = pos * xPerPos + ms *
    ## xPerMs + x0`, and `y` the same way.
    xPerPos*, xPerMs*, x0*: float64
    yPerPos*, yPerMs*, y0*: float64

const Positive: array[Orientation, (ScreenAxis, float64)] = [(saX, 1.0), (saY, -1.0)]
  ## where a positive amplitude swings on the screen: right, or up

func turnOf*(o: Orientation; firstAtTop = FirstTraceAtTop): Turn =
  ## The mapping of a plot turned `o`; time across with the first trace at
  ## the top (`firstAtTop`) or at the bottom.
  result = Turn(orientation: o)
  case o
  of orTimeDown:
    result.along = [axTraces: saX, axTime: saY]
  of orTimeAcross:
    result.along = [axTraces: saY, axTime: saX]
    result.reversed[axTraces] = not firstAtTop
  # the positive swing along the positions: its screen direction against
  # the one the positions grow in
  let (s, sign) = Positive[o]
  assert s == result.along[axTraces]
  result.swing = if result.reversed[axTraces]: -sign else: sign

const TimeDown* = turnOf(orTimeDown) ## the mapping of a plot that is not turned

func axisAlong*(m: Turn; s: ScreenAxis): Axis {.inline.} =
  ## The data axis that runs along screen axis `s`.
  if m.along[axTraces] == s: axTraces else: axTime

func axesAlong*(m: Turn; screen: set[ScreenAxis]): set[Axis] =
  ## The data axes that run along the screen axes `screen`.
  for s in screen: result.incl m.axisAlong(s)

func sign*(m: Turn; a: Axis): float64 {.inline.} =
  ## 1 where data axis `a` grows rightwards or downwards on the screen, -1
  ## where it grows the other way.
  if m.reversed[a]: -1.0 else: 1.0

func swingOnScreen*(m: Turn): (ScreenAxis, float64) =
  ## Which way a positive amplitude swings on the screen: along which axis,
  ## and 1 rightwards or downwards, -1 leftwards or upwards.
  (m.along[axTraces], m.swing * m.sign(axTraces))

func span*(v: Viewport; a: Axis): Span {.inline.} =
  ## The data `v` shows along `a`.
  if a == axTraces: v.traces else: v.timeMs

func pixels*(v: Viewport; a: Axis): int {.inline.} =
  ## The plot's pixels along data axis `a`.
  if a == axTraces: v.columns else: v.rows

func sized*(v: Viewport; m: Turn; width, height: int): Viewport =
  ## `v` on a plot `width` × `height` pixels on the screen: its pixels along
  ## each data axis.
  result = v
  let along = [saX: width, saY: height]
  result.columns = along[m.along[axTraces]]
  result.rows = along[m.along[axTime]]

func screenSize*(v: Viewport; m: Turn): (int, int) =
  ## The width and height on the screen of the plot of `v`.
  var s: array[ScreenAxis, int]
  s[m.along[axTraces]] = v.columns
  s[m.along[axTime]] = v.rows
  (s[saX], s[saY])

func fraction(v: Viewport; m: Turn; a: Axis; value: float64): float64 {.inline.} =
  ## How far `value` lies across the plot along `a`'s screen axis, from its
  ## left or top edge: 0 to 1 over the view.
  let s = v.span(a)
  let f = if s.width != 0: (value - s.lo) / s.width else: 0.0
  if m.reversed[a]: 1 - f else: f

func valueAt(v: Viewport; m: Turn; a: Axis; f: float64): float64 {.inline.} =
  ## The value along `a` at the fraction `f` of the plot from its left or
  ## top edge along `a`'s screen axis.
  let s = v.span(a)
  s.lo + (if m.reversed[a]: 1 - f else: f) * s.width

func dataAt*(v: Viewport; plot: Rect; p: Vec2; m = TimeDown): DataPoint =
  ## The data point under screen point `p` of a plot drawn in `plot` (any
  ## pixel units, the same for both) turned as `m` says.
  let w = if plot.size.x > 0: float64(plot.size.x) else: 1.0
  let h = if plot.size.y > 0: float64(plot.size.y) else: 1.0
  let f = [saX: (float64(p.x) - float64(plot.pos.x)) / w,
    saY: (float64(p.y) - float64(plot.pos.y)) / h]
  DataPoint(x: v.valueAt(m, axTraces, f[m.along[axTraces]]),
    tMs: v.valueAt(m, axTime, f[m.along[axTime]]))

func screenAt*(v: Viewport; plot: Rect; p: DataPoint; m = TimeDown): Vec2 =
  ## Where data point `p` is drawn in `plot`: the inverse of `dataAt`.
  var f: array[ScreenAxis, float64]
  f[m.along[axTraces]] = v.fraction(m, axTraces, p.x)
  f[m.along[axTime]] = v.fraction(m, axTime, p.tMs)
  vec2(float32(float64(plot.pos.x) + f[saX] * float64(plot.size.x)),
    float32(float64(plot.pos.y) + f[saY] * float64(plot.size.y)))

func dataDelta*(m: Turn; dx, dy: float64): (float64, float64) =
  ## A move of `dx` to the right and `dy` down the screen, as moves along
  ## the positions and along time, in the same unit (a fraction of the
  ## plot, of the view, pixels): positive where later positions or times
  ## lie that way.
  let d = [saX: dx, saY: dy]
  (d[m.along[axTraces]] * m.sign(axTraces), d[m.along[axTime]] * m.sign(axTime))

func screenPixel*(v: Viewport; m: Turn; trace, time: int): (int, int) =
  ## The pixel of the plot's image (`x`, `y` from its top-left corner) that
  ## lies `trace` pixels along the positions and `time` pixels along time
  ## from the view's first position and earliest time.
  var p: array[ScreenAxis, int]
  for (a, k) in [(axTraces, trace), (axTime, time)]:
    p[m.along[a]] = if m.reversed[a]: v.pixels(a) - 1 - k else: k
  (p[saX], p[saY])

func screenRect*(v: Viewport; m: Turn; traces: Slice[int]): Rect =
  ## The part of the plot's image (pixels from its top-left corner) that
  ## pixels `traces` along the positions (from the view's first position)
  ## cover, all along time.
  let (w, h) = v.screenSize(m)
  let first = if m.reversed[axTraces]: v.columns - 1 - traces.b else: traces.a
  if m.along[axTraces] == saX:
    Rect(pos: vec2(float32(first), 0), size: vec2(float32(traces.len), float32(h)))
  else:
    Rect(pos: vec2(0, float32(first)), size: vec2(float32(w), float32(traces.len)))

func ndcOf*(v: Viewport; m: Turn; p: DataPoint): (float32, float32) =
  ## Data point `p` of `v` in OpenGL's normalised device coordinates (-1 to
  ## 1 over the plot, y up).
  var f: array[ScreenAxis, float64]
  f[m.along[axTraces]] = v.fraction(m, axTraces, p.x)
  f[m.along[axTime]] = v.fraction(m, axTime, p.tMs)
  (float32(f[saX] * 2 - 1), float32(-(f[saY] * 2 - 1)))

func ndcMap*(v: Viewport; m: Turn): NdcMap =
  ## The affine form of `ndcOf`, from offsets from the view's first
  ## position and earliest time: what a vertex shader computes.
  for a in Axis:
    let s = m.along[a]
    # x grows rightwards with the fraction, y the other way
    let k = if (s == saX) == not m.reversed[a]: 1.0 else: -1.0
    let per = k * 2 / v.span(a).width
    if s == saX:
      if a == axTraces: result.xPerPos = per else: result.xPerMs = per
      result.x0 = -k
    else:
      if a == axTraces: result.yPerPos = per else: result.yPerMs = per
      result.y0 = -k
