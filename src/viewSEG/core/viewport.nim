## What a trace panel shows, and what it reads for it.
##
## A panel has two data axes, whichever way its plot is turned
## (`core/orientation`: traces across and time down, as seismic is plotted,
## or time across and the traces stacked). One counts *positions*: the
## panel's traces in order (a gather after its trace filter), position `k`
## centred on `x = k` and covering `k - 0.5 .. k + 0.5`. The other is time
## in ms; sample `j` lies at `t0Ms + j * dtMs` and covers half an interval
## either side. A `Viewport` holds a span of each and the plot's pixels
## along each (`columns` along the positions, `rows` along time), so
## everything here (the stride, the decimation, the read-ahead) is the same
## for either orientation.
##
## **The view bounds the work.** `requestFor` turns what is on screen into
## a `ReadRequest`:
##
## - the visible positions, plus a read-ahead of a view and a half on each
##   side (`ReadAhead`), so a pan of up to a whole view finds its data on
##   hand; the panel asks again once less than a view is left on a side
##   where the data goes on (`covers` with `keep`, `KeepAhead`), so the
##   margin stays filled as the view moves; the read-ahead of a large view
##   shrinks to stay within `MaxAheadValues`;
## - zoomed out past one position per pixel (in density only: the wiggle
##   modes stop at one pixel a trace, `MinTracePixels`), every `stride`-th
##   position only (a power of two, positions that are multiples of it),
##   never more than the plot has pixels along the positions (`columns`),
##   read-ahead included; a view no wider than those reads every position
##   it shows;
## - the visible samples, plus the same read-ahead in time; zoomed out past
##   one sample per pixel along time (`rows`), the tile keeps one column per
##   `decimation` samples (a power of two; `decimatePeakInto`), at most two
##   per pixel;
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
  ReadAhead* = 1.5
    ## positions (and samples) read beyond the view on each side, as a
    ## fraction of the visible count: a whole view and a half, so a step of
    ## a whole view (Shift + arrow, a click on a scroll bar's track) finds
    ## its data on hand
  KeepAhead* = 1.0
    ## the read-ahead kept on hand as the view moves, in views on each side:
    ## a new request is made once less is left (`covers` with `keep`), so a
    ## whole view's step never leaves the tiles on hand
  MaxAheadValues* = 16.0 * 1024 * 1024
    ## the values (64 MiB) a request's read-ahead may bring its tile to; the
    ## view itself is always read whole
  SlowReadAhead* = 3.0
    ## `ReadAhead` on a slow drive (`core/state`'s read timing): fewer,
    ## larger reads, so the view stays on hand between them
  SlowKeepAhead* = 2.0 ## `KeepAhead` on a slow drive
  SlowMaxAheadValues* = 32.0 * 1024 * 1024
    ## `MaxAheadValues` on a slow drive (128 MiB: a panel's tiles stay within
    ## its 192 MiB)
  MinTracePixels* = 1.0
    ## the narrowest trace spacing, in pixels, of a view in a wiggle mode:
    ## zoomed out as far as it goes, every trace in view has a pixel of its
    ## own (a column, or a row when time is across), and none is skipped
    ## (density has no such limit)

type
  Span* = object
    ## An interval of data coordinates, `lo` to `hi`.
    lo*, hi*: float64

  Viewport* = object
    ## What a panel shows.
    traces*: Span ## in positions, from the first shown to the last
    timeMs*: Span ## in ms, from the earliest time shown to the latest
    columns*, rows*: int
      ## the plot's pixels along the positions and along time: its width and
      ## height when time is down, its height and width when time is across

  PanelLayout* = object
    ## What a panel's traces span: known once the panel's reader has looked
    ## at the gather. `traces` 0 until then.
    traces*: int ## positions: the traces the filter keeps
    samples*: int ## samples of the longest of them
    dtMs*: float64 ## the sample interval
    t0Ms*: float64 ## the time of sample 0
    noInterval*: bool
      ## the headers give no sample interval: `dtMs` is 1, counting samples

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

type Reach = object
  ## What a view needs and how far a request for it reads ahead, in steps:
  ## positions of `stride`, columns of `decimation` samples.
  stride, dec: int
  kLo, kHi, kTop: int ## the visible positions' steps, the last step of the layout
  jLo, jHi, jTop: int ## the visible columns, the last column of the layout
  aheadK, aheadJ: int ## the read-ahead on each side
  envelope: bool

func reachFor(layout: PanelLayout; view: Viewport; readAhead: float64;
    wiggles: bool; maxValues = MaxAheadValues): Reach =
  ## The steps of `view` and its read-ahead: `readAhead` views on each side
  ## along each axis (less where the data ends), zoomed out never more than
  ## the plot's columns (density) or two columns per pixel row, and no more
  ## in all than `maxValues` values (both axes' read-ahead shrunk alike),
  ## however much the view itself holds.
  let vis = visiblePositions(layout, view)
  let vs = visibleSamples(layout, view)
  # Positions: multiples of the stride. A view no wider than the plot's
  # columns may touch one more position than it is wide (both edges cut
  # through one), and still reads every one of them.
  result.stride = if view.traces.width <= float64(view.columns) * (1 + 1e-9): 1
                  else: strideFor(vis.len, view.columns)
  result.kLo = (vis.a + result.stride - 1) div result.stride
  result.kHi = max(result.kLo, vis.b div result.stride)
  result.kTop = (layout.traces - 1) div result.stride
  let shown = result.kHi - result.kLo + 1
  var ahead = int(ceil(float64(shown) * readAhead))
  if result.stride > 1: # zoomed out: never more than the columns
    ahead = min(ahead, max(0, (view.columns - shown) div 2))
  # Samples: whole decimation bins.
  result.dec = decimationFor(vs.len, view.rows)
  result.jLo = vs.a div result.dec
  result.jHi = vs.b div result.dec
  result.jTop = (layout.samples - 1) div result.dec
  let cols = result.jHi - result.jLo + 1
  var aheadS = int(ceil(float64(cols) * readAhead))
  if result.dec > 1: # at most two columns per row
    aheadS = min(aheadS, max(0, (2 * view.rows - cols) div 2))
  result.envelope = result.dec > 1 and wiggles
  # The budget: the values of the tile (and its envelope's two a column).
  let r = result
  let per = if r.envelope: 3.0 else: 1.0
  proc values(a, b: int): float64 =
    let (k0, k1) = spread(r.kLo, r.kHi, r.kTop, a)
    let (j0, j1) = spread(r.jLo, r.jHi, r.jTop, b)
    float64(k1 - k0 + 1) * float64(j1 - j0 + 1) * per
  var f = 1.0
  if values(ahead, aheadS) > maxValues:
    var (lo, hi) = (0.0, 1.0)
    for _ in 0 ..< 30:
      let m = (lo + hi) / 2
      if values(int(float64(ahead) * m), int(float64(aheadS) * m)) > maxValues: hi = m
      else: lo = m
    f = lo
  result.aheadK = int(float64(ahead) * f)
  result.aheadJ = int(float64(aheadS) * f)

func requestFor*(layout: PanelLayout; view: Viewport; margin = 0;
    readAhead = ReadAhead; wiggles = false; maxValues = MaxAheadValues): ReadRequest =
  ## What to read for `view` of a layer that draws wiggles (`wiggles`) or
  ## not: see the module documentation; `readAhead` views on each side, the
  ## read-ahead within `maxValues` values. Empty (`count` 0) when the panel
  ## has no traces or no size. `gen` is left 0.
  if visiblePositions(layout, view).len == 0 or visibleSamples(layout, view).len == 0 or
      view.columns <= 0 or view.rows <= 0:
    return ReadRequest(stride: 1, decimation: 1)
  let r = reachFor(layout, view, readAhead, wiggles, maxValues)
  let (k0, k1) = spread(r.kLo, r.kHi, r.kTop, r.aheadK)
  let (j0, j1) = spread(r.jLo, r.jHi, r.jTop, r.aheadJ)
  let firstSample = j0 * r.dec
  ReadRequest(first: k0 * r.stride, count: k1 - k0 + 1, stride: r.stride,
    firstSample: firstSample, samples: min(layout.samples, (j1 + 1) * r.dec) - firstSample,
    decimation: r.dec, margin: max(margin, 0), envelope: r.envelope)

func covers*(r: ReadRequest; layout: PanelLayout; view: Viewport; margin = 0;
    wiggles = false; keep = 0.0; readAhead = ReadAhead; maxValues = MaxAheadValues): bool =
  ## Whether `r` holds what `view` shows, at the resolution it needs (with
  ## the extremes wiggles need, for `wiggles`), and with `keep` views on
  ## each side of it as well (of the `readAhead` a request for `view` would
  ## read within `maxValues`, where the data goes on; 0: the view alone):
  ## then nothing new is read.
  if r.isEmpty or visiblePositions(layout, view).len == 0 or
      visibleSamples(layout, view).len == 0 or view.columns <= 0 or view.rows <= 0:
    return false
  let n = reachFor(layout, view, readAhead, wiggles, maxValues)
  let share = if readAhead > 0: clamp(keep / readAhead, 0.0, 1.0) else: 0.0 # (none read ahead)
  let (k0, k1) = spread(n.kLo, n.kHi, n.kTop, int(float64(n.aheadK) * share))
  let (j0, j1) = spread(n.jLo, n.jHi, n.jTop, int(float64(n.aheadJ) * share))
  r.stride == n.stride and r.decimation == n.dec and r.margin == max(margin, 0) and
    (r.envelope or not n.envelope) and r.first <= k0 * n.stride and
    r.last >= k1 * n.stride and r.firstSample <= j0 * n.dec and
    r.firstSample + r.samples >= min(layout.samples, (j1 + 1) * n.dec)

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
