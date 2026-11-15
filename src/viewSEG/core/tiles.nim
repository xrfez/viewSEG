## Tiles: the samples a panel's reader sends the UI thread, and how they are
## drawn.
##
## A `Tile` answers one `ReadRequest`: `count` traces of `columns` values,
## trace by trace, processed for display, with each trace's index in its
## file and its keys (what the cursor readout shows), the values of the
## display header's fields for each trace, the edits it was made with (a
## trace killed or reversed: `core/edits`), the traces the file marks dead
## and the amplitude statistics of its live traces that are not killed (its
## `Level`). Killed and dead traces are drawn blank. It is made on the
## reader's thread, moved through the inbox and
## kept by `AppState`; it holds no `ref`, so it may be freed on any thread.
## Zoomed out in time with traces wide enough for wiggles, it also keeps
## each column's extremes (`envelope`), which the wiggles are drawn through.
##
## The pixels come from these procs (docs/architecture.md, rule 4): the GPU
## draws a tile as `quad`s, one per `TileBlock`, with a shader that does
## what `amplitudeAt` and `densityColour` do here. The CPU forms are the
## reference the GPU is tested against, and what an export draws with.

import std/[fenv, math, times]
from parseSEG import TraceKeys, JoinGroup
from processSEG/gain/gain import dbToFactor
from processSEG/gain/stats import percentileAbs, percentileWorkspace, traceStats
from processSEG/core/workspace import Workspace, reserve
import edits, geometry, panels, viewport

export TraceEdit

type
  Tile* = object
    ## The samples of one request, ready to draw.
    id*: uint64             ## given by `AppState` when it takes the tile in; 0 before
    panel*: PanelId
    request*: ReadRequest   ## what it answers (`request.gen`: the panel's request)
    dtMs*, t0Ms*: float64   ## the panel's time axis
    columns*: int           ## values per trace: `request.columns`
    data*: seq[float32]     ## `request.count` traces of `columns` values, trace by trace
    envelope*: seq[float32] ## with `request.envelope`: the columns' extremes (`core/wiggle`)
    traces*: seq[int]       ## per row: the trace's index in its file
    keys*: seq[TraceKeys]   ## per row: the trace's keys
    fields*: seq[HeaderField]
    header*: seq[seq[float64]]
      ## per field, one value per trace (NaN when unknown)
    edits*: seq[set[TraceEdit]]
      ## per row: the edits its samples were made with; empty when none has any
    level*: Level           ## RMS, peak and clip percentile of |x| over the live traces
    failed*: int            ## traces that could not be decoded (zero rows)
    cached*: bool           ## the reader made it from samples it held, not from the file
    readTime*: Duration
      ## how long its reader waited for the file's samples (`fs.now`): the
      ## drive and the decoding, not the processing; zero when cached
    chunks*: int            ## the reads (prefetch chunks) it took from the file
    filtered*: int
      ## the traces its reader passed to the filters (`ProcessPool.apply`):
      ## those of its request, or none without filters
    raw*: seq[float32]
      ## when asked for (`ReaderRequest.raw`): the samples as the file has
      ## them, before polarity, edits, processing and gain, cut and
      ## decimated as `data`; empty otherwise
    dead*: seq[bool]
      ## per row: the trace is marked dead in the file, so it is drawn blank;
      ## empty when none is
    joined*: seq[set[JoinGroup]]
      ## per row: the groups of its keys a geometry join filled or changed
      ## (parseSEG's `joinedGroups`); empty when none was

  Quad* = object
    ## Where a block of a tile is drawn, in data coordinates (positions and
    ## ms), and the texel coordinates at its corners: `u` counts rows (one
    ## per trace, nearest), `v` columns (interpolated in time).
    x0*, x1*, t0*, t1*: float64
    u0*, u1*, v0*, v1*: float64

  Lut* = array[256, Rgba]
    ## A colour map: index 0 for the most negative amplitude, 255 for the
    ## most positive.

func joinedAt*(t: Tile; row: int): set[JoinGroup] {.inline.} =
  ## The groups of row `row`'s keys a geometry join gave.
  if row in 0 ..< t.joined.len: t.joined[row] else: {}

func editsAt*(t: Tile; row: int): set[TraceEdit] {.inline.} =
  ## The edits row `row`'s samples were made with.
  if row in 0 ..< t.edits.len: t.edits[row] else: {}

func isKilled*(t: Tile; row: int): bool {.inline.} =
  ## Whether row `row`'s trace was killed when `t` was made: it is drawn
  ## blank (the plot's background), and left out of the levels.
  teKilled in t.editsAt(row)

func isDead*(t: Tile; row: int): bool {.inline.} =
  ## Whether row `row`'s trace is marked dead in the file: drawn blank, and
  ## left out of the levels, under every gain.
  row in 0 ..< t.dead.len and t.dead[row]

func isBlank*(t: Tile; row: int): bool {.inline.} =
  ## Whether row `row` is drawn blank (the plot's background, no wiggle):
  ## its trace was killed, or the file marks it dead.
  t.isKilled(row) or t.isDead(row)

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

func hidden*(tiles: openArray[Tile]; i: int; view: Viewport): bool =
  ## Whether tile `i` of `tiles` (oldest first, as drawn) shows nothing in
  ## `view`: a newer tile covers all of it that lies in view, so it paints
  ## over the tile's area, and its own traces' lobes over the ones of the
  ## same traces that reach out of it. Drawing it would cost the GPU a whole
  ## pass and change nothing but where it drew a trace's lobe twice.
  let (xs, ts) = tiles[i].span
  let x = Span(lo: max(xs.lo, view.traces.lo), hi: min(xs.hi, view.traces.hi))
  let t = Span(lo: max(ts.lo, view.timeMs.lo), hi: min(ts.hi, view.timeMs.hi))
  if not (x.lo < x.hi and t.lo < t.hi): return true # nothing of it in view
  for j in i + 1 .. tiles.high:
    let (nx, nt) = tiles[j].span
    if nx.lo <= x.lo and nx.hi >= x.hi and nt.lo <= t.lo and nt.hi >= t.hi: return true
  false

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

func cellsIn(s: Span; first, step: float64; n: int): Slice[int] =
  ## The cells `0 ..< n`, centred at `first + k * step`, whose centres lie
  ## in `s`; the one nearest its middle when none does.
  let a = max(0, int(ceil((s.lo - first) / step)))
  let b = min(n - 1, int(floor((s.hi - first) / step)))
  if a <= b: a .. b
  else:
    let c = clamp(int(round(((s.lo + s.hi) / 2 - first) / step)), 0, n - 1)
    c .. c

proc valuesInView*(t: Tile; view: Viewport; most: int; dst: var seq[float32]) =
  ## Adds to `dst` the values of `t` whose trace and time lie in `view`, on
  ## an even grid of at most about `most` of them (all of them when they are
  ## fewer): what the Float gain takes its level from. Killed and dead
  ## traces are left out. Nothing when the tile and the view do not meet.
  let r = t.request
  if r.count <= 0 or t.columns <= 0 or most <= 0: return
  let (xs, ts) = t.span
  if view.traces.hi <= xs.lo or view.traces.lo >= xs.hi or view.timeMs.hi <= ts.lo or
      view.timeMs.lo >= ts.hi:
    return
  let rows = cellsIn(view.traces, float64(r.first), float64(r.stride), r.count)
  let cols = cellsIn(view.timeMs, t.timeOf(0), float64(r.decimation) * t.dtMs, t.columns)
  let thin = max(1, int(ceil(sqrt(float64(rows.len) * float64(cols.len) / float64(most)))))
  var row = rows.a
  while row <= rows.b:
    if not t.isBlank(row):
      var c = cols.a
      while c <= cols.b:
        dst.add t.data[row * t.columns + c]
        c += thin
    row += thin

proc levelOf*(values: openArray[float32]; percentile: float64; ws: var Workspace): Level =
  ## The RMS, the peak and the `percentile` of |x| of the finite `values`
  ## (processSEG's `traceStats` and `percentileAbs` on them); NaN when there
  ## are none. `ws` grows to what it needs.
  var finite = newSeqOfCap[float32](values.len)
  for v in values:
    if abs(v) < Inf: finite.add v # NaN fails too
  if finite.len == 0: return Level()
  let s = traceStats(finite)
  ws.reserve(percentileWorkspace(finite.len))
  Level(rms: s.rms, peak: s.maxAbs, clip: percentileAbs(finite,
    (if percentile.isNaN: 99.0 else: clamp(percentile, 0.0, 100.0)), ws))

func lutIndex*(scaled: float32): int {.inline.} =
  ## The colour-map entry of an amplitude times the display gain: -1 and
  ## below give 0, +1 and above give 255. NaN gives the middle.
  let u = if scaled.isNaN: 0'f32 else: clamp(scaled, -1'f32, 1'f32)
  int(floor((u + 1) * 127.5'f32 + 0.5'f32))

func densityColour*(lut: Lut; amplitude, scale: float32): Rgba {.inline.} =
  ## The colour of `amplitude` at display gain `scale` (1 / the clip).
  lut[lutIndex(amplitude * scale)]

func densityAt*(t: Tile; lut: Lut; x, tMs: float64; scale: float32; background: Rgba): Rgba =
  ## The density colour drawn at (`x`, `tMs`): the colour of `amplitudeAt`
  ## at display gain `scale`, or `background` on a killed or dead trace
  ## (drawn blank). What the density shader computes.
  if t.isBlank(t.rowAt(x)): background else: lut.densityColour(t.amplitudeAt(x, tMs), scale)

func greyLut*(): Lut =
  ## The grey density map of seismic plots: positive amplitudes black,
  ## negative white, zero mid grey.
  for i in 0 .. 255:
    let g = uint8(255 - i)
    result[i] = Rgba(r: g, g: g, b: g, a: 255)

func displayScale*(reference: float64; gainDb = 0.0): float32 =
  ## The display gain: `reference` (`Panel.reference`), raised or lowered by
  ## `gainDb`, maps to full black or white. 0 when the reference is unknown
  ## or 0 (everything mid grey). A scale past what a float32 holds is the
  ## largest float32, so more gain never draws less: every sample that is not
  ## 0 is drawn full black or white (`a * scale` may then overflow to an
  ## infinity, which the clip to ±1 takes, on the GPU as here).
  let f = if reference > 0 and reference < Inf: dbToFactor(gainDb) / reference else: 0.0
  if f < maximumPositiveValue(float32): float32(f)
  elif f >= maximumPositiveValue(float32): maximumPositiveValue(float32) # high() is Inf
  else: 0'f32
