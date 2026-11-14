## What a trace panel shows, and what it reads for it.
##
## A panel is drawn the way seismic is plotted: traces across, time down.
## Its x axis counts *positions*: the panel's traces in order (a gather
## after its trace filter), position `k` centred on `x = k` and covering
## `k - 0.5 .. k + 0.5`. Its y axis is time in ms, increasing downward;
## sample `j` lies at `t0Ms + j * dtMs` and covers half an interval either
## side.
##
## **The view bounds the work.** `requestFor` turns what is on screen into
## a `ReadRequest`:
##
## - the visible positions, plus a read-ahead of half the visible count on
##   each side, so a pan of up to half a view needs nothing new;
## - zoomed out past one position per pixel column (in density only: the
##   wiggle modes stop at one pixel a trace, `MinTracePixels`), every
##   `stride`-th position only (a power of two, positions that are multiples
##   of it), never more than the panel has columns, read-ahead included; a
##   view no wider than the plot's columns reads every position it shows;
## - the visible samples, plus the same read-ahead in time; zoomed out past
##   one sample per pixel row, the tile keeps one column per `decimation`
##   samples (a power of two; `decimatePeakInto`), at most two per row;
## - `margin` more samples on each side for processing (a filter's edge, an
##   AGC window), decoded but not kept (`decodeWindow`);
## - when the layer draws wiggles and the samples are decimated, each
##   column's extremes as well (`envelope`), so a wiggle keeps its peaks
##   (`core/wiggle`).
##
## Powers of two keep a request the same under small zooms, and aligned
## positions and samples keep it the same under small pans. `covers` says
## whether a request already holds what a view needs, so a pan inside the
## read-ahead asks for nothing.
##
## A tile is drawn from GPU textures, and one texture cannot exceed the
## GPU's size limit: `splitBlocks` cuts a tile into blocks that fit.

import std/math
from processSEG/pipeline import decodeWindow

const
  ReadAhead* = 0.5
    ## positions (and samples) read beyond the view on each side, as a
    ## fraction of the visible count
  MinTracePixels* = 1.0
    ## the narrowest trace spacing, in pixels, of a view in a wiggle mode:
    ## zoomed out as far as it goes, every trace in view has a pixel column
    ## of its own, and none is skipped (density has no such limit)

type
  Span* = object
    ## An interval of data coordinates, `lo` to `hi`.
    lo*, hi*: float64

  Viewport* = object
    ## What a panel shows.
    traces*: Span        ## x, in positions, from the left edge to the right edge
    timeMs*: Span        ## y, in ms, from the top edge to the bottom edge
    columns*, rows*: int ## the plot's size in pixels

  PanelLayout* = object
    ## What a panel's traces span: known once the panel's reader has looked
    ## at the gather. `traces` 0 until then.
    traces*: int ## positions: the traces the filter keeps
    samples*: int ## samples of the longest of them
    dtMs*: float64 ## the sample interval
    t0Ms*: float64 ## the time of sample 0

  ReadRequest* = object
    ## The traces and samples a panel asks its reader for.
    gen*: uint64      ## the panel's `requestGen` when it was made
    first*: int       ## the first position
    count*: int       ## positions `first`, `first + stride`, ...: `count` of them
    stride*: int      ## 1, or every `stride`-th position when zoomed out
    firstSample*: int ## the first sample kept: a multiple of `decimation`
    samples*: int     ## samples kept, from `firstSample`
    decimation*: int  ## samples per tile column: 1, or a power of two
    margin*: int      ## samples decoded on each side and dropped after processing
    envelope*: bool   ## the tile also keeps each column's extremes, for wiggles

  TileBlock* = object
    ## Part of a tile that fits one texture: rows (positions) `row ..< row +
    ## rows` and columns `col ..< col + cols`.
    row*, rows*, col*, cols*: int

func `==`*(a, b: Span): bool = a.lo == b.lo and a.hi == b.hi

func width*(s: Span): float64 {.inline.} = s.hi - s.lo

func isEmpty*(r: ReadRequest): bool {.inline.} = r.count <= 0 or r.samples <= 0

func last*(r: ReadRequest): int {.inline.} =
  ## The last position read.
  r.first + (r.count - 1) * r.stride

func columns*(r: ReadRequest): int {.inline.} =
  ## The tile's columns per trace.
  (r.samples + r.decimation - 1) div r.decimation

func position*(r: ReadRequest; row: int): int {.inline.} =
  ## The position of the tile's row `row`.
  r.first + row * r.stride

func pixelsPerTrace*(view: Viewport): float64 =
  ## The trace spacing of `view` on screen, in pixels; 0 for an empty view.
  if view.traces.width > 0 and view.columns > 0: float64(view.columns) / view.traces.width
  else: 0.0

func covered(s: Span; n: int): Slice[int] =
  ## The cells `0 ..< n` (cell `k` covering `k - 0.5 .. k + 0.5`) that `s`
  ## overlaps; an empty slice when none.
  if n <= 0 or not (s.lo < s.hi) or s.hi.isNaN or s.lo.isNaN:
    return 0 .. -1
  let a = max(0.0, floor(s.lo + 0.5))
  let b = min(float64(n - 1), ceil(s.hi - 0.5))
  if a > b: 0 .. -1
  else: int(a) .. int(b)

func visiblePositions*(layout: PanelLayout; view: Viewport): Slice[int] =
  ## The positions the view shows, at least partly.
  covered(view.traces, layout.traces)

func visibleSamples*(layout: PanelLayout; view: Viewport): Slice[int] =
  ## The samples (of the longest trace) the view shows, at least partly.
  if not (layout.dtMs > 0): return 0 .. -1
  covered(Span(lo: (view.timeMs.lo - layout.t0Ms) / layout.dtMs,
    hi: (view.timeMs.hi - layout.t0Ms) / layout.dtMs), layout.samples)

func strideFor*(visible, columns: int): int =
  ## The smallest power of two that leaves at most `columns` of `visible`
  ## positions.
  result = 1
  if columns > 0:
    while visible > result * columns: result *= 2

func decimationFor*(visible, rows: int): int =
  ## The largest power of two that keeps at least `rows` of `visible`
  ## samples (1 when there are fewer).
  result = 1
  if rows > 0:
    while visible div (result * 2) >= rows: result *= 2

func fitAll*(layout: PanelLayout; columns, rows: int): Viewport =
  ## The view that shows every position and every sample.
  Viewport(traces: Span(lo: -0.5, hi: float64(layout.traces) - 0.5),
    timeMs: Span(lo: layout.t0Ms, hi: layout.t0Ms + float64(max(layout.samples - 1, 1)) *
    layout.dtMs), columns: columns, rows: rows)

func spread(lo, hi, top, ahead: int): (int, int) =
  ## `lo .. hi` (in steps) widened by `ahead` on each side within `0 .. top`.
  (max(0, lo - ahead), min(top, hi + ahead))

func requestFor*(layout: PanelLayout; view: Viewport; margin = 0;
    readAhead = ReadAhead; wiggles = false): ReadRequest =
  ## What to read for `view` of a layer that draws wiggles (`wiggles`) or
  ## not: see the module documentation. Empty (`count` 0) when the panel has
  ## no traces or no size. `gen` is left 0.
  let vis = visiblePositions(layout, view)
  let vs = visibleSamples(layout, view)
  if vis.len == 0 or vs.len == 0 or view.columns <= 0 or view.rows <= 0:
    return ReadRequest(stride: 1, decimation: 1)
  # Positions: multiples of the stride. A view no wider than the plot's
  # columns may touch one more position than it is wide (both edges cut
  # through one), and still reads every one of them.
  let stride = if view.traces.width <= float64(view.columns) * (1 + 1e-9): 1
               else: strideFor(vis.len, view.columns)
  let kLo = (vis.a + stride - 1) div stride
  let kHi = max(kLo, vis.b div stride)
  let shown = kHi - kLo + 1
  var ahead = int(ceil(float64(shown) * readAhead))
  if stride > 1: # zoomed out: never more than the columns
    ahead = min(ahead, max(0, (view.columns - shown) div 2))
  let (k0, k1) = spread(kLo, kHi, (layout.traces - 1) div stride, ahead)
  # Samples: whole decimation bins.
  let dec = decimationFor(vs.len, view.rows)
  let jLo = vs.a div dec
  let jHi = vs.b div dec
  let cols = jHi - jLo + 1
  var aheadS = int(ceil(float64(cols) * readAhead))
  if dec > 1: # at most two columns per row
    aheadS = min(aheadS, max(0, (2 * view.rows - cols) div 2))
  let (j0, j1) = spread(jLo, jHi, (layout.samples - 1) div dec, aheadS)
  let firstSample = j0 * dec
  ReadRequest(first: k0 * stride, count: k1 - k0 + 1, stride: stride,
    firstSample: firstSample, samples: min(layout.samples, (j1 + 1) * dec) - firstSample,
    decimation: dec, margin: max(margin, 0), envelope: dec > 1 and wiggles)

func covers*(r: ReadRequest; layout: PanelLayout; view: Viewport; margin = 0;
    wiggles = false): bool =
  ## Whether `r` holds what `view` shows, at the resolution it needs (with
  ## the extremes wiggles need, for `wiggles`): then nothing new is read.
  let need = requestFor(layout, view, margin, readAhead = 0, wiggles = wiggles)
  not r.isEmpty and not need.isEmpty and r.stride == need.stride and
    r.decimation == need.decimation and r.margin == need.margin and
    (r.envelope or not need.envelope) and
    r.first <= need.first and r.last >= need.last and r.firstSample <= need.firstSample and
    r.firstSample + r.samples >= need.firstSample + need.samples

func decodeSpan*(r: ReadRequest; traceSamples: int): Slice[int] =
  ## The samples to decode for `r`: the kept ones and `margin` more on each
  ## side, within `0 ..< traceSamples` (processSEG's `decodeWindow`).
  decodeWindow(r.firstSample ..< r.firstSample + r.samples, r.margin, traceSamples)

func decimatePeakInto*(src: openArray[float32]; n: int; dst: var openArray[float32]) =
  ## Each `n` samples of `src` into one of `dst`: the sample of largest
  ## magnitude, with its sign (peaks and troughs stay visible when zoomed
  ## out). The last bin may be short. Samples that are not finite count as
  ## 0. `dst` takes `ceil(src.len / n)` values; extra ones are set to 0.
  ## Raises `ValueError` for `n < 1`.
  if n < 1: raise newException(ValueError, "decimation must be at least 1, got " & $n)
  var k = 0
  var i = 0
  while i < src.len and k < dst.len:
    var best = 0'f32
    for j in i ..< min(src.len, i + n):
      let v = src[j]
      if abs(v) < Inf and abs(v) > abs(best): # NaN and Inf fail the first test
        best = v
    dst[k] = best
    inc k
    i += n
  for m in k ..< dst.len: dst[m] = 0

func splitBlocks*(rows, cols, maxSize: int): seq[TileBlock] =
  ## Blocks of at most `maxSize` × `maxSize` that cover a `rows` × `cols`
  ## tile. Blocks side by side in time share their edge column, so each can
  ## interpolate up to its edge without the other. Raises `ValueError` for
  ## `maxSize < 2`.
  if maxSize < 2: raise newException(ValueError, "maxSize must be at least 2, got " & $maxSize)
  var r = 0
  while r < rows:
    let nr = min(maxSize, rows - r)
    var c = 0
    while true:
      let nc = min(maxSize, cols - c)
      result.add TileBlock(row: r, rows: nr, col: c, cols: nc)
      if c + nc >= cols: break
      c += nc - 1
    r += nr
