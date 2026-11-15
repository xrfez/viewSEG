## Wiggles: how the plot draws a trace as a line with its fills, as plain
## procs (docs/architecture.md, rule 4). The GPU's wiggle shader
## (`gpu/wiggle`) computes per pixel what `traceInk` computes here; these
## are what it is tested against, and what an export can draw with.
##
## **The line.** A trace's wiggle is a polyline in time through the
## vertices of its tile row (`Series`): one per tile column (the samples
## themselves when they are not decimated) or, when the tile keeps each
## column's extremes (`ReadRequest.envelope`, made by `minMaxInto`), two per
## column, the smallest and the largest sample of the column in the order
## they occur, a quarter of a column either side of its centre. So a trace
## drawn in fewer pixels along time than it has samples keeps every peak and
## trough. Between vertices the line is straight; before the first and
## after the last it is held.
##
## **The swing.** A value `a` swings the trace `swing(a, scale, overlap)`
## trace spacings from its baseline towards the next trace (towards the
## trace before when negative): `a * scale` (the display gain,
## `displayScale`) clipped to ±1, times the overlap. So the reference
## amplitude, the one density draws full black, swings a trace `overlap`
## trace spacings, and nothing swings further: the clip. Overlap 1 reaches
## the next trace's baseline. A plot turned so that a positive amplitude
## swings towards the trace before (time across, the first trace at the
## top: up) draws each wiggle mirrored about its baseline
## (`WiggleStyle.swing`, from `core/orientation`).
##
## **A pixel.** The line covers the part of a pixel between its smallest
## and largest swing over the pixel's span of time (`lineExtent`), widened
## by half the line's width on each side; a fill covers the part between
## the baseline and the swing at the pixel's centre time, on the side
## chosen (`WiggleFill`). Fill and line are drawn with that coverage, the
## line over the fill, so their edges are smooth.
##
## **Killed traces** put no ink at all: they are drawn blank.
##
## **Order.** Traces are drawn in their order, each over the ones before
## it; then the hovered and selected traces once more, on top, in their
## colours (`TraceMark`), so a highlighted trace is never hidden by its
## neighbour's fill. Each tile is drawn over the older ones, its own area
## painted first.

import std/math
import geometry, panels, selection, tiles, viewport

type
  Series* = object
    ## The vertices of a tile's wiggles: `count` per row, the first at
    ## `firstMs`, one every `stepMs`.
    perColumn*: int ## vertices per tile column: 1, or 2 from the envelope
    count*: int
    firstMs*, stepMs*: float64

  TraceMark* = enum
    tmNone = "none"
    tmSelected = "selected" ## in the selection
    tmHovered = "hovered"   ## under the pointer (or its station under the map's)

  WiggleStyle* = object
    ## How the wiggles of a view are drawn.
    scale*: float32          ## the display gain (`displayScale`)
    overlap*: float64        ## the largest swing, in trace spacings
    pixelsPerTrace*: float64 ## the trace spacing on screen
    msPerPixel*: float64     ## the time one pixel spans
    lineWidth*: float64      ## pixels; 0 draws no line
    markedWidth*: float64    ## pixels, for a hovered or selected trace's line
    fills*: set[WiggleFill]
    swing*: float64 = 1
      ## 1: a positive amplitude swings towards later positions; -1: towards
      ## earlier ones, each wiggle mirrored about its baseline (`Turn.swing`)

  WiggleInk* = object
    ## The colours of a wiggle display.
    line*, positive*, negative*: Rgba
    hover*, selected*: Rgba ## line and fills of a hovered or selected trace

  Ink* = object
    ## A colour with its coverage, premultiplied: 0 .. 1 each.
    r*, g*, b*, a*: float64

const
  MaxRowVertices* = 32
    ## vertices inside one pixel's time that a line's extent looks at, at most
    ## (a tile has at most four per row; an older, finer one may have more)

func finite(v: float32): float32 {.inline.} =
  if abs(v) < Inf: v else: 0'f32 # NaN fails the test too

func minMaxInto*(src: openArray[float32]; n: int; dst: var openArray[float32]) =
  ## Each `n` samples of `src` into two values of `dst`: their smallest and
  ## largest, in the order they occur, so a line through them keeps every
  ## peak and trough. The last bin may be short. Samples that are not
  ## finite count as 0. `dst` takes `2 * ceil(src.len / n)` values; extra
  ## ones are set to 0. Raises `ValueError` for `n < 1`.
  if n < 1: raise newException(ValueError, "decimation must be at least 1, got " & $n)
  var k = 0
  var i = 0
  while i < src.len and k + 1 < dst.len:
    var lo = finite(src[i])
    var hi = lo
    var (loAt, hiAt) = (i, i)
    for j in i + 1 ..< min(src.len, i + n):
      let v = finite(src[j])
      if v < lo:
        lo = v
        loAt = j
      if v > hi:
        hi = v
        hiAt = j
    if loAt <= hiAt:
      (dst[k], dst[k + 1]) = (lo, hi)
    else:
      (dst[k], dst[k + 1]) = (hi, lo)
    k += 2
    i += n
  for m in k ..< dst.len: dst[m] = 0

func hasEnvelope*(t: Tile): bool {.inline.} =
  ## Whether `t` keeps each column's extremes for its wiggles.
  t.columns > 0 and t.envelope.len == t.request.count * 2 * t.columns

func series*(t: Tile): Series =
  ## The vertices `t`'s wiggles go through.
  let columnMs = float64(t.request.decimation) * t.dtMs
  if t.hasEnvelope:
    Series(perColumn: 2, count: 2 * t.columns, firstMs: t.timeOf(0) - columnMs / 4,
      stepMs: columnMs / 2)
  else:
    Series(perColumn: 1, count: t.columns, firstMs: t.timeOf(0), stepMs: columnMs)

func vertex*(t: Tile; s: Series; row, k: int): float32 {.inline.} =
  ## Vertex `k` of row `row`'s wiggle.
  if s.perColumn == 2: t.envelope[row * s.count + k] else: t.data[row * s.count + k]

func index(s: Series; tMs: float64): float64 {.inline.} =
  ## Where `tMs` lies among the vertices, held just outside them (a time far
  ## off would not convert to an int); before them for a time that is not a
  ## number.
  let u = (tMs - s.firstMs) / s.stepMs
  if not (u >= -1): -1.0 else: min(u, float64(s.count))

func valueAt*(t: Tile; s: Series; row: int; tMs: float64): float32 =
  ## Row `row`'s wiggle at `tMs`: straight between vertices, held before the
  ## first and after the last. 0 for a tile with none.
  if s.count <= 0 or row notin 0 ..< t.request.count: return 0
  let u = s.index(tMs)
  let j = floor(u)
  let j0 = clamp(int(j), 0, s.count - 1)
  let j1 = clamp(int(j) + 1, 0, s.count - 1)
  let f = float32(clamp(u - j, 0.0, 1.0))
  t.vertex(s, row, j0) * (1 - f) + t.vertex(s, row, j1) * f

func swing*(a, scale: float32; overlap: float64): float64 {.inline.} =
  ## The swing of value `a`, in trace spacings: `a * scale` clipped to ±1,
  ## times `overlap`.
  float64(clamp(a * scale, -1'f32, 1'f32)) * overlap

func lineExtent*(t: Tile; s: Series; row: int; tA, tB: float64; scale: float32;
    overlap: float64): (float64, float64) =
  ## The smallest and the largest swing of row `row`'s line between times
  ## `tA` and `tB` (one pixel's time), in trace spacings: at both ends and at
  ## the vertices between them (at most `MaxRowVertices`).
  let dA = swing(t.valueAt(s, row, tA), scale, overlap)
  let dB = swing(t.valueAt(s, row, tB), scale, overlap)
  result = (min(dA, dB), max(dA, dB))
  if s.count <= 0 or row notin 0 ..< t.request.count: return
  var k = max(0, int(floor(s.index(tA))) + 1)
  let last = min(s.count - 1, int(ceil(s.index(tB))) - 1)
  var seen = 0
  while k <= last and seen < MaxRowVertices:
    let d = swing(t.vertex(s, row, k), scale, overlap)
    result = (min(result[0], d), max(result[1], d))
    inc k
    inc seen

func covered*(lo, hi, x0, x1: float64): float64 {.inline.} =
  ## How much of the pixel `x0 .. x1` (one pixel wide) lies between `lo` and
  ## `hi`: 0 .. 1.
  clamp(min(hi, x1) - max(lo, x0), 0.0, 1.0)

func ink*(c: Rgba; coverage: float64): Ink {.inline.} =
  ## Colour `c` (opaque) covering `coverage` of a pixel.
  let k = clamp(coverage, 0.0, 1.0) / 255
  Ink(r: float64(c.r) * k, g: float64(c.g) * k, b: float64(c.b) * k,
    a: clamp(coverage, 0.0, 1.0))

func over*(top, below: Ink): Ink {.inline.} =
  ## `top` drawn over `below`.
  let k = 1 - top.a
  Ink(r: top.r + below.r * k, g: top.g + below.g * k, b: top.b + below.b * k,
    a: top.a + below.a * k)

func onto*(top: Ink; below: Rgba): Rgba =
  ## `top` drawn over the opaque colour `below`.
  func channel(v: float64; b: uint8; a: float64): uint8 =
    uint8(clamp(round((v + float64(b) / 255 * (1 - a)) * 255), 0, 255))
  Rgba(r: channel(top.r, below.r, top.a), g: channel(top.g, below.g, top.a),
    b: channel(top.b, below.b, top.a), a: 255)

func traceInk*(t: Tile; s: Series; row: int; xPx, tMs: float64; st: WiggleStyle;
    ink: WiggleInk; mark = tmNone): Ink =
  ## What row `row`'s trace puts on the pixel whose centre lies `xPx` pixels
  ## from the trace's baseline towards later positions at time `tMs`: its
  ## fill, then its line over it, in the colours of `mark`; nothing for a
  ## killed or dead trace, which is drawn blank. With `st.swing` -1 the
  ## wiggle is mirrored about its baseline.
  if t.isBlank(row): return Ink()
  let xPx = xPx * st.swing # pixels towards where a positive amplitude swings
  let (line, positive, negative, width) = case mark
    of tmHovered: (ink.hover, ink.hover, ink.hover, st.markedWidth)
    of tmSelected: (ink.selected, ink.selected, ink.selected, st.markedWidth)
    of tmNone: (ink.line, ink.positive, ink.negative, st.lineWidth)
  let (x0, x1) = (xPx - 0.5, xPx + 0.5)
  var fill = Ink()
  if st.fills != {}:
    let d = swing(t.valueAt(s, row, tMs), st.scale, st.overlap) * st.pixelsPerTrace
    if d > 0 and wfPositive in st.fills: fill = ink(positive, covered(0, d, x0, x1))
    elif d < 0 and wfNegative in st.fills: fill = ink(negative, covered(d, 0, x0, x1))
  result = fill
  if width > 0:
    let half = st.msPerPixel / 2
    let (lo, hi) = t.lineExtent(s, row, tMs - half, tMs + half, st.scale, st.overlap)
    let c = covered(lo * st.pixelsPerTrace - width / 2, hi * st.pixelsPerTrace + width / 2,
      x0, x1)
    result = ink(line, c).over(fill)

func reach*(st: WiggleStyle): float64 =
  ## How far from its baseline a trace can put ink, in trace spacings: the
  ## overlap, the line's half width and a pixel of smoothing.
  st.overlap + (max(st.lineWidth, st.markedWidth) / 2 + 1) / max(st.pixelsPerTrace, 1e-9)

const LineShare* = 0.25
  ## the most of a trace spacing a wiggle's line takes: where traces are a
  ## few pixels apart, a full-width line would cover the fills, and at one
  ## pixel a trace every column would be line (a black plot)

func lineWidthFor*(width, pixelsPerTrace: float64): float64 {.inline.} =
  ## The line width drawn for a line `width` pixels wide where traces are
  ## `pixelsPerTrace` apart: at most `LineShare` of a trace spacing (a
  ## coverage below a pixel, so a close record shows its fills, not a band
  ## of lines).
  min(width, LineShare * pixelsPerTrace)

func styleFor*(d: DisplaySettings; view: Viewport; scale: float32; lineWidth,
    markedWidth: float64): WiggleStyle =
  ## The wiggle style of a layer drawn with `d` in `view` at display gain
  ## `scale`, lines `lineWidth` pixels wide (`markedWidth` when hovered or
  ## selected), at its `effectiveOverlap`, swinging as its orientation says.
  ## The plain line is never wider than `LineShare` of a trace spacing
  ## (`lineWidthFor`); a hovered or selected trace keeps `markedWidth`, so
  ## it stands out.
  let ppt = pixelsPerTrace(view)
  WiggleStyle(scale: scale, overlap: d.effectiveOverlap, pixelsPerTrace: ppt,
    msPerPixel: view.timeMs.width / float64(max(view.rows, 1)),
    lineWidth: lineWidthFor(lineWidth, ppt), markedWidth: markedWidth, fills: d.fills,
    swing: d.turn.swing)

func hoverRow*(t: Tile; base, hover: int): int =
  ## The row of `t` that holds survey-wide trace `hover` (`Selection.hover`)
  ## of a file whose trace 0 is `base`; -1 when none does.
  result = -1
  if hover >= base:
    for row, trace in t.traces:
      if base + trace == hover: return row

proc selectedRowsInto*(t: Tile; base: int; s: Selection; dst: var seq[bool]) =
  ## For each row of `t` (of a file whose trace 0 is `base`), whether its
  ## trace is in the selection.
  dst.setLen t.traces.len
  for row, trace in t.traces: dst[row] = (base + trace) in s.selected

proc hoveredRowsInto*(t: Tile; base: int; s: Selection; dst: var seq[bool]) =
  ## For each row of `t` (of a file whose trace 0 is `base`), whether its
  ## trace was recorded at a point under the map's pointer (`hoverTraces`):
  ## drawn as the hovered trace is. Empty when there is none.
  if s.hoverTraces.len == 0:
    dst.setLen 0
    return
  dst.setLen t.traces.len
  for row, trace in t.traces: dst[row] = (base + trace) in s.hoverTraces

func markOf*(row, hover: int; selected: openArray[bool];
    hovered: openArray[bool] = []): TraceMark {.inline.} =
  ## The mark of `row`, given the hovered row, the selected ones and those
  ## the map's pointer lights up (`hovered`, drawn as the hovered row).
  if row == hover or (row in 0 ..< hovered.len and hovered[row]): tmHovered
  elif row in 0 ..< selected.len and selected[row]: tmSelected
  else: tmNone

func blend*(a, b: Rgba; t: float32): Rgba =
  ## `a` moved by the fraction `t` (0 .. 1) towards `b`, as the shaders mix.
  func channel(x, y: uint8): uint8 =
    uint8(clamp(round(float32(x) + (float32(y) - float32(x)) * t), 0, 255))
  Rgba(r: channel(a.r, b.r), g: channel(a.g, b.g), b: channel(a.b, b.b), a: channel(a.a, b.a))

func densityTint*(c: Rgba; mark: TraceMark; ink: WiggleInk; tint: float32;
    map: ColourMap): Rgba =
  ## Density colour `c` (of `map`) of a trace with `mark`, tinted by `tint`
  ## towards the hover or selection colour `map` takes for them
  ## (`highlights`: what density alone shows of a highlight).
  let (hover, selected) = highlights(map, ink.hover, ink.selected)
  case mark
  of tmHovered: blend(c, hover, tint)
  of tmSelected: blend(c, selected, tint)
  of tmNone: c
