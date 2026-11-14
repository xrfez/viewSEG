## The wiggle kernels of `core/wiggle` and what feeds them: the min/max
## decimation keeps every peak and trough in the order they occur; a
## request keeps the columns' extremes exactly when traces are wide enough
## for wiggles and the samples are decimated, and one without them does not
## cover a view that needs them; the panel's reader fills them from the
## file's own samples; the wiggle's line and fills cover a pixel as the
## shader is to (straight between vertices, clipped at the overlap,
## reversed with the polarity); density takes over below four pixels a
## trace; the hovered and selected rows of a tile are found from
## survey-wide trace ids; and a hover on a trace no open file has clears
## the hover without a warning.
##
## Seen to fail: with `minMaxInto` keeping the extremes smallest first
## whatever their order, `minMaxKeepsOrder` found (-1, 5) for a bin that
## peaks at 5 before it falls to -1; with the envelope asked for at any
## trace width, `envelopeOnlyForWiggles` found it on a view of 2 pixels a
## trace; with `covers` ignoring the envelope, `envelopeIsCovered` found a
## request without it covering a view that needs it; with the reader never
## filling the envelope, `readerFillsTheEnvelope` found row 0 all zeros;
## with the swing not clipped, `swingIsClipped` found 4.5 trace spacings at
## overlap 1.5; with `ckHover` warning about an unknown trace, as it did,
## `staleHoverIsQuiet` found "Ignored "hover": no open file has trace 7."

import std/[math, random]
import viewSEG/core/[geometry, state, wiggle]
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc main(st: AppState): lent Panel = st.panel(MainPanel)

proc lastText(log: MessageLog): string = log[log.len - 1].text

func tileOf(values: openArray[float32]; rows: int; dtMs = 2.0; decimation = 1): Tile =
  ## A tile of `rows` traces at positions 0, 1, ... (traces 10, 11, ... of
  ## their file) holding `values`.
  let cols = values.len div rows
  result = Tile(request: ReadRequest(count: rows, stride: 1, samples: cols * decimation,
    decimation: decimation), dtMs: dtMs, columns: cols, data: @values)
  for r in 0 ..< rows: result.traces.add 10 + r

block minMaxKeepsOrder:
  var dst = newSeq[float32](8)
  minMaxInto([1'f32, -3, 2, 5, -1, 0, 4], 3, dst)
  doAssert dst == @[-3'f32, 2, 5, -1, 4, 4, 0, 0], $dst
  # a bin that rises and then falls keeps the peak first
  var two = newSeq[float32](2)
  minMaxInto([0'f32, 5, -3], 3, two)
  doAssert two == @[5'f32, -3], $two
  # samples that are not numbers count as 0
  minMaxInto([NaN.float32, 3, Inf.float32, 1], 4, two)
  doAssert two == @[0'f32, 3], $two
  minMaxInto([2'f32, 7, 7, 2], 2, two)
  doAssert two == @[2'f32, 7], $two # the first bin only: dst holds one
  doAssertRaises(ValueError):
    minMaxInto([1'f32], 0, two)

block minMaxKeepsEveryPeak:
  var r = initRand(7)
  var src = newSeq[float32](1000)
  for v in src.mitems: v = float32(r.gauss())
  for n in [1, 2, 3, 16, 64, 1000]:
    var dst = newSeq[float32](2 * ((src.len + n - 1) div n))
    minMaxInto(src, n, dst)
    for k in 0 ..< dst.len div 2:
      let bin = src[k * n ..< min(src.len, (k + 1) * n)]
      doAssert min(dst[2 * k], dst[2 * k + 1]) == min(bin) and
        max(dst[2 * k], dst[2 * k + 1]) == max(bin), "bin " & $k & " of " & $n
      # the extremes in the order they occur
      doAssert (dst[2 * k] == min(bin)) == (bin.find(min(bin)) <= bin.find(max(bin)))

block envelopeOnlyForWiggles:
  let layout = PanelLayout(traces: 100, samples: 4000, dtMs: 2)
  var v = fitAll(layout, 800, 500) # 8 px a trace, 8 samples a row
  doAssert pixelsPerTrace(v) == 8
  var r = requestFor(layout, v)
  doAssert r.decimation > 1 and r.envelope, $r
  v.columns = 200 # 2 px a trace: density, no envelope
  r = requestFor(layout, v)
  doAssert r.decimation > 1 and not r.envelope, $r
  v.columns = 800
  v.timeMs = Span(lo: 0, hi: 400) # 200 samples on 500 rows: not decimated
  r = requestFor(layout, v)
  doAssert r.decimation == 1 and not r.envelope, $r

block envelopeIsCovered:
  let layout = PanelLayout(traces: 100, samples: 4000, dtMs: 2)
  var wide = fitAll(layout, 800, 500)
  var narrow = wide
  narrow.columns = 396 # 3.96 px a trace, the same decimation and stride
  let withIt = requestFor(layout, wide)
  let without = requestFor(layout, narrow)
  doAssert withIt.envelope and not without.envelope
  doAssert withIt.stride == without.stride and withIt.decimation == without.decimation
  doAssert not without.covers(layout, wide), "no envelope covers a view that needs one"
  doAssert withIt.covers(layout, narrow)

block seriesAndValues:
  # one trace, columns at 0, 2, 4, 6 ms (dt 2, no decimation)
  let t = tileOf([0'f32, 1, 0, -1], 1)
  let s = t.series
  doAssert s == Series(perColumn: 1, count: 4, firstMs: 0, stepMs: 2), $s
  doAssert t.valueAt(s, 0, 2) == 1 and t.valueAt(s, 0, 3) == 0.5
  doAssert t.valueAt(s, 0, -10) == 0 and t.valueAt(s, 0, 50) == -1 # held at the ends
  doAssert t.valueAt(s, 0, NaN) == 0 and t.valueAt(s, 0, 1e300) == -1
  # with the envelope: two vertices per column, a quarter column either side
  var e = tileOf([0'f32, 0], 1, decimation = 4)
  e.request.envelope = true
  e.envelope = @[-1'f32, 3, 2, -2]
  let se = e.series
  doAssert e.hasEnvelope and se.perColumn == 2 and se.count == 4
  doAssert se.stepMs == 4 and se.firstMs == e.timeOf(0) - 2, $se
  doAssert e.valueAt(se, 0, se.firstMs + 4) == 3

block swingIsClipped:
  doAssert swing(0.5, 1, 1.5) == 0.75
  doAssert swing(3, 1, 1.5) == 1.5 and swing(-3, 1, 1.5) == -1.5
  doAssert swing(0.5, -1, 1.5) == -0.75, "reversed polarity swings the other way"

block lineAndFillCoverage:
  # one trace: a positive lobe then a negative one, 1 ms samples
  let t = tileOf([0'f32, 1, 0, -1, 0], 1, dtMs = 1)
  let s = t.series # vertices at 0, 1, 2, ... ms
  let st = WiggleStyle(scale: 1, overlap: 1, pixelsPerTrace: 20, msPerPixel: 0.1,
    lineWidth: 1, markedWidth: 2, fills: {wfPositive})
  let ink = WiggleInk(line: Rgba(r: 0, g: 0, b: 0, a: 255),
    positive: Rgba(r: 0, g: 0, b: 255, a: 255), negative: Rgba(r: 255, g: 0, b: 0, a: 255),
    hover: Rgba(r: 255, g: 128, b: 0, a: 255), selected: Rgba(r: 0, g: 160, b: 0, a: 255))
  let white = Rgba(r: 255, g: 255, b: 255, a: 255)
  # at the positive peak (1 ms) the swing is 20 px: filled from the
  # baseline, the line at 20 px, paper beyond
  doAssert t.traceInk(s, 0, 10, 1, st, ink).onto(white) == ink.positive
  doAssert t.traceInk(s, 0, 20, 1, st, ink).onto(white) == ink.line
  doAssert t.traceInk(s, 0, 22, 1, st, ink).onto(white) == white
  # at the negative peak (3 ms): no positive fill, the line at -20 px
  doAssert t.traceInk(s, 0, -10, 3, st, ink).onto(white) == white
  doAssert t.traceInk(s, 0, -20, 3, st, ink).onto(white) == ink.line
  # with both fills, the negative lobe in its own colour
  var both = st
  both.fills = {wfPositive, wfNegative}
  doAssert t.traceInk(s, 0, -10, 3, both, ink).onto(white) == ink.negative
  # a pixel row spanning the steep part covers every swing it passes
  var coarse = st
  coarse.msPerPixel = 1
  let (lo, hi) = t.lineExtent(s, 0, 1.5, 2.5, 1, 1)
  doAssert lo == -0.5 and hi == 0.5, $(lo, hi)
  doAssert t.traceInk(s, 0, 5, 2, coarse, ink).a == 1
  # a hovered trace in the hover colour, line and fill
  doAssert t.traceInk(s, 0, 10, 1, st, ink, tmHovered).onto(white) == ink.hover
  doAssert t.traceInk(s, 0, 20, 1, st, ink, tmSelected).onto(white) == ink.selected
  # half a pixel of line at its edge
  let edge = t.traceInk(s, 0, 20.5, 1, st, ink)
  doAssert abs(edge.a - 0.5) < 1e-9, $edge

block densityBelowFourPixels:
  var d = DisplaySettings()
  doAssert d.mode == dmWiggle and d.fills == {wfPositive}, "wiggles first, positive fill"
  let layout = PanelLayout(traces: 100, samples: 100, dtMs: 2)
  var v = fitAll(layout, 400, 300) # 4 px a trace
  doAssert d.drawsWiggles(v) and not d.drawsDensity(v)
  v.columns = 399
  doAssert not d.drawsWiggles(v) and d.drawsDensity(v), "density takes over"
  d.mode = dmWiggleDensity
  v.columns = 800
  doAssert d.drawsWiggles(v) and d.drawsDensity(v)
  d.mode = dmDensity
  doAssert not d.drawsWiggles(v) and d.drawsDensity(v)

block marksFromTraceIds:
  let t = tileOf([0'f32, 0, 0, 0, 0, 0], 3) # traces 10, 11, 12 of their file
  doAssert t.hoverRow(100, 111) == 1 and t.hoverRow(100, 99) == -1 and t.hoverRow(100, -1) == -1
  var sel = Selection()
  sel.select([110, 112, 500], smReplace)
  var rows: seq[bool]
  t.selectedRowsInto(100, sel, rows)
  doAssert rows == @[true, false, true], $rows
  doAssert markOf(1, 1, rows) == tmHovered and markOf(0, 1, rows) == tmSelected and
    markOf(1, -1, rows) == tmNone

block readerFillsTheEnvelope:
  withFixtures fx:
    let path = fx.surveySegy()
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[path])
    doAssert st.settle(st.main.laidOut and st.main.layout.traces > 0)
    var d = st.main.layers[0].display
    d.gain = dgNone # the samples as they are
    st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    # every trace, 10 px each; 500 samples on 100 rows: 4 samples a column
    st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(st.main.layout,
      10 * Channels, 100))
    let k = st.findPanel(MainPanel)
    doAssert st.settle(st.tiles(k).len > 0 and st.tiles(k)[^1].request == st.main.pending)
    let t = st.tiles(k)[^1]
    doAssert t.request.envelope and t.request.decimation == 4 and t.hasEnvelope, $t.request
    var raw = newSeq[float32](Samples)
    var want = newSeq[float32](2 * t.columns)
    for row in 0 ..< t.request.count:
      for i in 0 ..< Samples: raw[i] = surveySample(0, t.traces[row] + 1, i)
      let r = t.request
      minMaxInto(raw.toOpenArray(r.firstSample, r.firstSample + r.samples - 1), r.decimation,
        want)
      doAssert t.envelope[row * 2 * t.columns ..< (row + 1) * 2 * t.columns] == want,
        "row " & $row
    st.shutdown()

block staleHoverIsQuiet:
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.surveySegy()])
    doAssert st.settle(st.sessions.len == 1)
    st.apply Command(kind: ckHover, trace: 5)
    doAssert st.selection.hover == 5
    let warnings = st.log.count(sevWarning)
    st.apply Command(kind: ckHover, trace: 1_000_000) # a trace of no open file
    doAssert st.selection.hover == -1
    st.apply Command(kind: ckHover, trace: 7)
    st.apply Command(kind: ckClose, file: st.sessions[0].id)
    st.apply Command(kind: ckHover, trace: 7) # the frame after a close
    doAssert st.selection.hover == -1
    doAssert st.log.count(sevWarning) == warnings, "a stale hover warned: " & st.log.lastText
    st.shutdown()
