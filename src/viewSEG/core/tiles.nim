## Tiles: the samples a panel's reader sends the UI thread, and how they are
## drawn.
##
## A `Tile` answers one `ReadRequest`: `count` traces of `columns` values,
## trace by trace, processed for display, with each trace's index in its
## file and its keys (what the cursor readout shows), the values of the
## display header's fields for each trace and the amplitude the display
## clips at. It is made on the reader's thread, moved through the inbox and
## kept by `AppState`; it holds no `ref`, so it may be freed on any thread.
##
## The pixels come from these procs (docs/architecture.md, rule 4): the GPU
## draws a tile as `quad`s, one per `TileBlock`, with a shader that does
## what `amplitudeAt` and `densityColour` do here. The CPU forms are the
## reference the GPU is tested against, and what an export draws with.

import std/math
from parseSEG import TraceKeys
import geometry, panels, viewport

type
  Tile* = object
    ## The samples of one request, ready to draw.
    id*: uint64           ## given by `AppState` when it takes the tile in; 0 before
    panel*: PanelId
    request*: ReadRequest ## what it answers (`request.gen`: the panel's request)
    dtMs*, t0Ms*: float64 ## the panel's time axis
    columns*: int         ## values per trace: `request.columns`
    data*: seq[float32]   ## `request.count` traces of `columns` values, trace by trace
    traces*: seq[int]     ## per row: the trace's index in its file
    keys*: seq[TraceKeys] ## per row: the trace's keys
    fields*: seq[HeaderField]
    header*: seq[seq[float64]]
      ## per field, one value per trace (NaN when unknown)
    clip*: float64        ## the clip percentile of |x| over the live traces; NaN for none
    failed*: int          ## traces that could not be decoded (zero rows)

  Quad* = object
    ## Where a block of a tile is drawn, in data coordinates (positions and
    ## ms), and the texel coordinates at its corners: `u` counts rows (one
    ## per trace, nearest), `v` columns (interpolated in time).
    x0*, x1*, t0*, t1*: float64
    u0*, u1*, v0*, v1*: float64

  Lut* = array[256, Rgba]
    ## A colour map: index 0 for the most negative amplitude, 255 for the
    ## most positive.

func timeOf*(t: Tile; column: float64): float64 {.inline.} =
  ## The time of column `column`'s centre.
  let r = t.request
  t.t0Ms + (float64(r.firstSample) + column * float64(r.decimation) +
    float64(r.decimation - 1) / 2) * t.dtMs

func span*(t: Tile): (Span, Span) =
  ## The data rectangle the tile covers: positions, then ms.
  let r = t.request
  let half = float64(r.decimation) * t.dtMs / 2
  (Span(lo: float64(r.first) - r.stride / 2, hi: float64(r.last) + r.stride / 2),
    Span(lo: t.timeOf(0) - half, hi: t.timeOf(float64(t.columns - 1)) + half))

func quad*(t: Tile; b: TileBlock): Quad =
  ## Where block `b` of `t` is drawn. Blocks side by side in time meet at
  ## the centre of the column they share; the tile's first and last columns
  ## reach half a column beyond their centres.
  let r = t.request
  let first = b.col == 0
  let last = b.col + b.cols >= t.columns
  result = Quad(x0: float64(r.position(b.row)) - r.stride / 2,
    x1: float64(r.position(b.row + b.rows - 1)) + r.stride / 2,
    u0: 0, u1: float64(b.rows),
    v0: (if first: -0.5 else: 0.0),
    v1: float64(b.cols - 1) + (if last: 0.5 else: 0.0))
  result.t0 = t.timeOf(float64(b.col) + result.v0)
  result.t1 = t.timeOf(float64(b.col) + result.v1)

func contains*(t: Tile; x, tMs: float64): bool =
  ## Whether the point (`x`, `tMs`) lies on the tile.
  let (xs, ts) = t.span
  x >= xs.lo and x < xs.hi and tMs >= ts.lo and tMs < ts.hi

func rowAt*(t: Tile; x: float64): int =
  ## The row drawn at position `x` (the nearest trace the tile holds, as
  ## `amplitudeAt` takes it); -1 when `x` is off the tile's traces.
  let (xs, _) = t.span
  if t.request.count <= 0 or not (x >= xs.lo and x < xs.hi): return -1
  let r = t.request
  clamp(int(floor((x - (float64(r.first) - r.stride / 2)) / float64(r.stride))), 0,
    r.count - 1)

func amplitudeAt*(t: Tile; x, tMs: float64): float32 =
  ## The value drawn at (`x`, `tMs`): the nearest trace, interpolated
  ## linearly in time between column centres (the end columns held to the
  ## tile's edge). What the shader computes. 0 for an empty tile.
  if t.request.count <= 0 or t.columns <= 0: return 0
  let r = t.request
  let u = (x - (float64(r.first) - r.stride / 2)) / float64(r.stride)
  let row = clamp(int(floor(u)), 0, r.count - 1)
  let v = (tMs - t.timeOf(0)) / (float64(r.decimation) * t.dtMs)
  let j = floor(v)
  let j0 = clamp(int(j), 0, t.columns - 1)
  let j1 = clamp(int(j) + 1, 0, t.columns - 1)
  let f = float32(clamp(v - j, 0.0, 1.0))
  let base = row * t.columns
  t.data[base + j0] * (1 - f) + t.data[base + j1] * f

func lutIndex*(scaled: float32): int {.inline.} =
  ## The colour-map entry of an amplitude times the display gain: -1 and
  ## below give 0, +1 and above give 255. NaN gives the middle.
  let u = if scaled.isNaN: 0'f32 else: clamp(scaled, -1'f32, 1'f32)
  int(floor((u + 1) * 127.5'f32 + 0.5'f32))

func densityColour*(lut: Lut; amplitude, scale: float32): Rgba {.inline.} =
  ## The colour of `amplitude` at display gain `scale` (1 / the clip;
  ## negative for reversed polarity).
  lut[lutIndex(amplitude * scale)]

func greyLut*(): Lut =
  ## The grey density map of seismic plots: positive amplitudes black,
  ## negative white, zero mid grey.
  for i in 0 .. 255:
    let g = uint8(255 - i)
    result[i] = Rgba(r: g, g: g, b: g, a: 255)

func displayScale*(clip: float64; reversed: bool): float32 =
  ## The display gain for a clip amplitude: the clip maps to full black or
  ## white. 0 when the clip is unknown or 0 (everything mid grey).
  result = if clip > 0 and clip < Inf: float32(1 / clip) else: 0'f32
  if reversed: result = -result
