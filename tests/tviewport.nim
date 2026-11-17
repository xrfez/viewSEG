## The view bounds the work: what a trace panel asks its reader for at
## several zoom levels (never more traces than visible plus read-ahead, never
## more than the pixel columns when zoomed out), when a request already
## covers a view, the decode margin, peak decimation, tiles cut to the GPU's
## texture limit, and the CPU twin of the density shader.
##
## Seen to fail: with no budget on the read-ahead, `readAheadBudget` found
## "12000 traces of 13500 samples asked for"; with `covers` not minding
## `keep`, "less than a view on hand, and no new request"; with the
## read-ahead left uncapped when zoomed out,
## `zoomLevels` asked for 803 traces on 800 columns (801 visible); with
## blocks side by side in time not sharing their edge column,
## `blocksAreSeamless` found a gap no block covers; with `decimatePeakInto`
## keeping the first sample of each bin, `peakDecimation` lost the trough.

import std/[fenv, math, random]
import parseSEG
import viewSEG/core/[geometry, panels, tiles, viewport]

const layout = PanelLayout(traces: 10_000, samples: 4001, dtMs: 1, t0Ms: 0)

func viewOf(first, last: float64; columns = 800; rows = 600; t0 = 0.0;
    t1 = 4000.0): Viewport =
  Viewport(traces: Span(lo: first - 0.5, hi: last + 0.5), timeMs: Span(lo: t0, hi: t1),
    columns: columns, rows: rows)

func isPowerOfTwo(n: int): bool = n > 0 and (n and (n - 1)) == 0

proc testTile(): Tile =
  ## 6 traces of 9 columns: every 2nd position from 4, samples 8 .. 25 in
  ## bins of 2, at 4 ms.
  let r = ReadRequest(first: 4, count: 6, stride: 2, firstSample: 8, samples: 18,
    decimation: 2)
  result = Tile(request: r, dtMs: 4, t0Ms: 100, columns: r.columns)
  for row in 0 ..< r.count:
    for c in 0 ..< result.columns:
      result.data.add float32(row * 10 + c)

func blockValue(t: Tile; b: TileBlock; x, tMs: float64): float32 =
  ## What the shader computes for block `b` at (x, tMs): its quad's texel
  ## coordinates interpolated linearly, then nearest row and linear column.
  let q = t.quad(b)
  let u = q.u0 + (x - q.x0) / (q.x1 - q.x0) * (q.u1 - q.u0)
  let v = q.v0 + (tMs - q.t0) / (q.t1 - q.t0) * (q.v1 - q.v0)
  let row = clamp(int(floor(u)), 0, b.rows - 1)
  let j = floor(v)
  let j0 = clamp(int(j), 0, b.cols - 1)
  let j1 = clamp(int(j) + 1, 0, b.cols - 1)
  let f = float32(clamp(v - j, 0.0, 1.0))
  let base = (b.row + row) * t.columns + b.col
  t.data[base + j0] * (1 - f) + t.data[base + j1] * f

proc main*() =

  block zoomLevels:
    # From 10 traces on screen to all 10 000, on 800 columns.
    for visible in [10, 100, 400, 799, 800, 801, 1600, 3000, 6400, 10_000]:
      let first = 2000.0
      let view = viewOf(first, first + float64(visible) - 1)
      let vis = visiblePositions(layout, view)
      doAssert vis.len == min(visible, layout.traces - 2000), $visible & ": " & $vis
      let r = requestFor(layout, view)
      doAssert r.stride.isPowerOfTwo and r.stride * view.columns >= vis.len
      doAssert r.first mod r.stride == 0
      let shown = vis.b div r.stride - (vis.a + r.stride - 1) div r.stride + 1
      let ahead = int(ceil(float64(shown) * ReadAhead))
      doAssert r.count <= shown + 2 * ahead,
        $visible & " visible: " & $r.count & " requested, " & $shown & " + 2 × " & $ahead
      if vis.len > view.columns:
        doAssert r.count <= view.columns,
          $visible & " visible: " & $r.count & " requested on " & $view.columns & " columns"
      else:
        doAssert r.stride == 1
      # every visible position at the stride is read
      for p in countup((vis.a + r.stride - 1) div r.stride * r.stride, vis.b, r.stride):
        doAssert p >= r.first and p <= r.last, $p & " not in " & $r
      doAssert r.last < layout.traces

  block timeDecimation:
    for (t1, rows) in [(100.0, 600), (600.0, 600), (1300.0, 600), (4000.0, 600), (4000.0, 100)]:
      let r = requestFor(layout, viewOf(0, 99, t1 = t1, rows = rows))
      let vs = visibleSamples(layout, viewOf(0, 99, t1 = t1, rows = rows))
      doAssert r.decimation.isPowerOfTwo
      doAssert vs.len div r.decimation >= min(rows, vs.len), $r
      if r.decimation > 1:
        doAssert r.columns <= 2 * rows + 1, $r.columns & " columns for " & $rows & " rows"
      doAssert r.firstSample mod r.decimation == 0
      doAssert r.firstSample <= vs.a and r.firstSample + r.samples > vs.b
      doAssert r.firstSample + r.samples <= layout.samples

  block coversPansAndZooms:
    let view = viewOf(1000, 1099)
    let r = requestFor(layout, view)
    doAssert r.covers(layout, view)
    doAssert r.covers(layout, viewOf(1040, 1139)), "a pan inside the read-ahead"
    doAssert r.covers(layout, viewOf(1100, 1199)), "a whole view's pan inside the read-ahead"
    doAssert not r.covers(layout, viewOf(1200, 1299)), "a pan past it"
    # a view and a half read ahead on each side; a view kept on hand
    doAssert r.first == 1000 - 150 and r.last == 1099 + 150, $r
    doAssert r.covers(layout, view, keep = KeepAhead)
    doAssert r.covers(layout, viewOf(1040, 1139), keep = KeepAhead), "a view still on hand"
    doAssert not r.covers(layout, viewOf(1060, 1159), keep = KeepAhead),
      "less than a view on hand, and no new request"
    # where the data ends, nothing more is wanted there
    let edge = requestFor(layout, viewOf(9900, 9999))
    doAssert edge.last == layout.traces - 1 and edge.covers(layout, viewOf(9900, 9999),
      keep = KeepAhead)
    doAssert not r.covers(layout, viewOf(0, 1599)), "zoomed out: another stride"
    doAssert not r.covers(layout, viewOf(1000, 1099), margin = 50), "another margin"
    let wide = requestFor(layout, viewOf(0, 9999))
    doAssert wide.stride == 16
    doAssert not wide.covers(layout, viewOf(1000, 1099)), "zoomed in: the stride is too coarse"
    doAssert requestFor(layout, viewOf(0, 99, columns = 0)).isEmpty
    doAssert requestFor(PanelLayout(), view).isEmpty
    doAssert not ReadRequest().covers(layout, view)

  block readAheadBudget:
    # A large view's read-ahead shrinks to keep the tile within the budget
    # (the view itself is always read), alike on both axes, and a request so
    # made still keeps its share on hand (no request every frame).
    let big = PanelLayout(traces: 100_000, samples: 20_001, dtMs: 1, t0Ms: 0)
    let v = Viewport(traces: Span(lo: 40_000 - 0.5, hi: 42_999.5),
      timeMs: Span(lo: 5000, hi: 8399), columns: 3000, rows: 3400)
    let r = requestFor(big, v)
    doAssert r.stride == 1 and r.decimation == 1
    let values = float64(r.count) * float64(r.columns)
    doAssert values * 4 <= 64.0 * 1024 * 1024, $r.count & " traces of " & $r.columns &
      " samples asked for" # 64 MiB of float32
    doAssert r.count > 3000 and r.columns > 3400, "no read-ahead at all: " & $r
    doAssert r.covers(big, v, keep = KeepAhead)
    let huge = Viewport(traces: Span(lo: 0 - 0.5, hi: 5999.5),
      timeMs: Span(lo: 0, hi: 3399), columns: 6000, rows: 3400)
    let h = requestFor(big, huge)
    doAssert h.count >= 6000 and h.columns >= 3400, "the view itself was cut: " & $h

  block decodeMargin:
    let r = requestFor(layout, viewOf(0, 99, t0 = 1000, t1 = 1599), margin = 250)
    doAssert r.margin == 250
    let w = r.decodeSpan(layout.samples)
    doAssert w.a == max(0, r.firstSample - 250) and w.b == min(4000, r.firstSample + r.samples +
      249), $w & " for " & $r
    doAssert r.columns == requestFor(layout, viewOf(0, 99, t0 = 1000, t1 = 1599)).columns
    let edge = requestFor(layout, viewOf(0, 99, t0 = 0, t1 = 99), margin = 250)
    doAssert edge.decodeSpan(layout.samples).a == 0

  block peakDecimation:
    var dst = newSeq[float32](3)
    decimatePeakInto([1'f32, -3, 2, 0.5, NaN, -0.25, 4], 3, dst)
    doAssert dst == @[-3'f32, 0.5, 4], $dst
    var wide = newSeq[float32](4)
    decimatePeakInto([1'f32, 2], 1, wide)
    doAssert wide == @[1'f32, 2, 0, 0]
    doAssertRaises ValueError: decimatePeakInto([1'f32], 0, dst)

  block blocksCoverTheTile:
    for (rows, cols, size) in [(10, 10, 16), (100, 7, 16), (17, 40, 16), (1, 1, 2), (5, 33, 4)]:
      let blocks = splitBlocks(rows, cols, size)
      var seen = newSeq[int](rows * cols)
      for b in blocks:
        doAssert b.rows in 1 .. size and b.cols in 1 .. size, $b
        for r in b.row ..< b.row + b.rows:
          for c in b.col ..< b.col + b.cols: inc seen[r * cols + c]
      for r in 0 ..< rows:
        for c in 0 ..< cols:
          doAssert seen[r * cols + c] >= 1, $(rows, cols, size) & ": cell " & $(r, c)
    doAssert splitBlocks(10, 10, 16).len == 1
    doAssertRaises ValueError: discard splitBlocks(4, 4, 1)

  block blocksAreSeamless:
    let t = testTile()
    let (xs, ts) = t.span
    # samples 8 .. 25 at 4 ms from 100 ms, each covering 2 ms either side
    doAssert xs == Span(lo: 3, hi: 15) and ts.lo == 100 + 8 * 4 - 2 and ts.hi == 100 + 25 * 4 + 2,
      $xs & " " & $ts
    doAssert t.amplitudeAt(4, ts.lo + 4) == 0 # the first column's centre
    doAssert t.amplitudeAt(6.9, ts.lo + 4 + 8) == 11 # row 1, column 1's centre
    doAssert t.amplitudeAt(4, ts.lo + 8) == 0.5 # halfway to column 1
    doAssert t.amplitudeAt(4, ts.lo) == 0 and t.amplitudeAt(4, ts.hi - 0.01) == 8
    var rng = initRand(7)
    for size in [2, 3, 4, 16]:
      let blocks = splitBlocks(t.request.count, t.columns, size)
      for _ in 0 ..< 2000:
        let x = rng.rand(xs.lo .. xs.hi - 1e-6)
        let tm = rng.rand(ts.lo .. ts.hi - 1e-6)
        var found = false
        for b in blocks:
          let q = t.quad(b)
          if x >= q.x0 and x < q.x1 and tm >= q.t0 and tm < q.t1:
            found = true
            let want = t.amplitudeAt(x, tm)
            let got = t.blockValue(b, x, tm)
            doAssert abs(got - want) < 1e-4, "block " & $b & " at " & $(x, tm) & ": " &
              $got & ", the tile " & $want
        doAssert found, "no block at " & $(x, tm) & " with blocks of " & $size

  block greyDensity:
    let lut = greyLut()
    doAssert lut[0] == Rgba(r: 255, g: 255, b: 255, a: 255) # most negative: white
    doAssert lut[255] == Rgba(r: 0, g: 0, b: 0, a: 255) # most positive: black
    doAssert lutIndex(-1) == 0 and lutIndex(-7) == 0 and lutIndex(1) == 255 and lutIndex(3) == 255
    doAssert lutIndex(0) == 128 and lutIndex(NaN) == 128
    let scale = displayScale(2.0)
    doAssert scale == 0.5
    doAssert displayScale(NaN) == 0 and displayScale(0) == 0
    # the gain amount: +6.02 dB doubles the scale, -20 dB is a tenth
    doAssert abs(displayScale(2.0, 20 * log10(2.0)) - 1) < 1e-6
    doAssert abs(displayScale(2.0, -20) - 0.05) < 1e-7
    # past a float32: the largest, never Inf (more gain never draws less)
    doAssert displayScale(1e-300, 60) == maximumPositiveValue(float32)
    doAssert lut.densityColour(2, scale) == lut[255] and lut.densityColour(-1, scale) == lut[64]

  block headerDefaults:
    # stacked or unknown data
    doAssert defaultFields({hfRcvLine, hfRcvPoint, hfChannel}) == @[hfRcvLine, hfRcvPoint]
    doAssert defaultFields({hfRcvPoint, hfInline}) == @[hfInline]
    doAssert defaultFields({hfInline, hfCrossline, hfEnsemble}) == @[hfInline, hfCrossline]
    doAssert defaultFields({hfEnsemble, hfRecord}) == @[hfEnsemble]
    doAssert defaultFields({hfRecord, hfChannel, hfTrace}) == @[hfRecord, hfChannel]
    doAssert defaultFields({}) == @[hfTrace]
    # shots: receiver stations, else field record and channel
    doAssert defaultFields({hfRcvLine, hfRcvPoint, hfEnsemble, hfRecord}, gkShot) ==
      @[hfRcvLine, hfRcvPoint]
    doAssert defaultFields({hfEnsemble, hfRecord, hfChannel}, gkShot) == @[hfRecord, hfChannel]
    # receivers: source stations
    doAssert defaultFields({hfSrcLine, hfSrcPoint, hfRcvLine}, gkReceiver) ==
      @[hfSrcLine, hfSrcPoint]

  block visibleEdges:
    let small = PanelLayout(traces: 5, samples: 10, dtMs: 2, t0Ms: 0)
    doAssert visiblePositions(small, viewOf(-3, 1)) == 0 .. 1
    doAssert visiblePositions(small, viewOf(4.1, 9)) == 4 .. 4
    doAssert visiblePositions(small, viewOf(6, 9)).len == 0
    doAssert visibleSamples(small, viewOf(0, 4, t0 = 3, t1 = 7)) == 2 .. 3 # 4 and 6 ms
    doAssert visibleSamples(small, viewOf(0, 4, t0 = 2.9, t1 = 7.1)) == 1 .. 4
    let fit = fitAll(small, 100, 50)
    doAssert visiblePositions(small, fit) == 0 .. 4 and visibleSamples(small, fit) == 0 .. 9
    doAssert fit.columns == 100 and fit.rows == 50
    doAssert strideFor(800, 800) == 1 and strideFor(801, 800) == 2 and strideFor(3200, 800) == 4
    doAssert decimationFor(599, 600) == 1 and decimationFor(1200, 600) == 2 and
      decimationFor(1199, 600) == 1

when isMainModule:
  main()
