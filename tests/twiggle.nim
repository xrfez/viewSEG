## The wiggle kernels of `core/wiggle` and what feeds them: the min/max
## decimation keeps every peak and trough in the order they occur; a
## request keeps the columns' extremes exactly when the layer draws wiggles
## (at any trace spacing) and the samples are decimated, and one without
## them does not cover a view that needs them; a view as wide as the plot
## has pixel columns reads every trace it shows, also when its edges cut
## through two; the panel's reader fills the extremes from the
## file's own samples; the wiggle's line and fills cover a pixel as the
## shader is to (straight between vertices, clipped at the overlap,
## the other way for a negative scale); a style's overlap is in its range, whatever
## the settings hold; density is drawn only in the modes that name it, at
## any trace spacing; the hovered and selected rows of a tile are found from
## survey-wide trace ids; a Shift + click's range is the traces from the
## anchor (the trace clicked last) to the one clicked, in the order shown; and a hover on a trace no open file has clears
## the hover without a warning.
##
## Seen to fail: with `minMaxInto` keeping the extremes smallest first
## whatever their order, `minMaxKeepsOrder` found (-1, 5) for a bin that
## peaks at 5 before it falls to -1; with the envelope asked for whatever
## the mode, `envelopeOnlyForWiggles` found it on a density view; with the
## stride taken from the positions the view touches (as it was),
## `wigglesReadEveryTrace` found stride 2 on a view 640 positions wide on
## 640 columns; with `drawsWiggles` true in the wiggle mode only,
## `densityOnlyWhenAsked` found no wiggles over density; with `covers` ignoring the envelope, `envelopeIsCovered` found a
## request without it covering a view that needs it; with the reader never
## filling the envelope, `readerFillsTheEnvelope` found row 0 all zeros;
## with the swing not clipped, `swingIsClipped` found 4.5 trace spacings at
## overlap 1.5; with `ckHover` warning about an unknown trace, as it did,
## `staleHoverIsQuiet` found "Ignored "hover": no open file has trace 7.";
## with `styleFor` only clamping the overlap (as it did), `overlapInRange`
## found an overlap that is not a number drawn as one (nothing drawn); with
## `rangeOf` giving the clicked trace alone, `rangesInTheOrderShown` found no
## range.

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
  var r = requestFor(layout, v, wiggles = true)
  doAssert r.decimation > 1 and r.envelope, $r
  v.columns = 100 # 1 px a trace: still wiggles, still the extremes
  r = requestFor(layout, v, wiggles = true)
  doAssert r.decimation > 1 and r.envelope, $r
  r = requestFor(layout, v, wiggles = false) # density: no extremes
  doAssert r.decimation > 1 and not r.envelope, $r
  v.columns = 800
  v.timeMs = Span(lo: 0, hi: 400) # 200 samples on 500 rows: not decimated
  r = requestFor(layout, v, wiggles = true)
  doAssert r.decimation == 1 and not r.envelope, $r

block wigglesReadEveryTrace:
  # a wiggle mode's widest view, as many positions as columns, read at
  # stride 1, wherever its edges fall
  let layout = PanelLayout(traces: 4000, samples: 1000, dtMs: 2)
  for lo in [-0.5, 0.0, 0.3, 1999.7]:
    let v = Viewport(traces: Span(lo: lo, hi: lo + 640), timeMs: Span(lo: 0, hi: 1998),
      columns: 640, rows: 400)
    let r = requestFor(layout, v, wiggles = true)
    doAssert r.stride == 1, $lo & ": " & $r
    let vis = visiblePositions(layout, v)
    doAssert r.first <= vis.a and r.last >= vis.b, $lo & ": " & $r
  # a little wider than the columns (density): every other one
  let wider = Viewport(traces: Span(lo: 0, hi: 641), timeMs: Span(lo: 0, hi: 1998),
    columns: 640, rows: 400)
  doAssert requestFor(layout, wider).stride == 2

block envelopeIsCovered:
  let layout = PanelLayout(traces: 100, samples: 4000, dtMs: 2)
  let v = fitAll(layout, 800, 500)
  let withIt = requestFor(layout, v, wiggles = true)
  let without = requestFor(layout, v, wiggles = false)
  doAssert withIt.envelope and not without.envelope
  doAssert withIt.stride == without.stride and withIt.decimation == without.decimation
  doAssert not without.covers(layout, v, wiggles = true),
    "no envelope covers a view that needs one"
  doAssert withIt.covers(layout, v, wiggles = false) and withIt.covers(layout, v, wiggles = true)

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
  doAssert swing(0.5, -1, 1.5) == -0.75, "a negative scale swings the other way"

block overlapInRange:
  # the overlap a style gets is within its range, also from settings that
  # did not come through the strip's box
  let v = fitAll(PanelLayout(traces: 10, samples: 100, dtMs: 2), 400, 300)
  for (given, want) in [(1.5, 1.5), (0.0, MinOverlap), (1e9, MaxOverlap), (NaN, 1.0),
      (-Inf, MinOverlap), (Inf, MaxOverlap)]:
    var d = DisplaySettings()
    d.overlap = given
    let st = d.styleFor(v, 1, 1, 2)
    doAssert st.overlap == want, "overlap " & $given & " drawn as " & $st.overlap

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

block densityOnlyWhenAsked:
  # the mode alone decides; the trace spacing never does (the wiggle modes
  # never zoom out past a pixel a trace instead: tzoom, wiggleLimit)
  var d = DisplaySettings()
  doAssert d.mode == dmWiggle and d.fills == {wfPositive}, "wiggles first, positive fill"
  doAssert d.drawsWiggles and not d.drawsDensity
  d.mode = dmWiggleDensity
  doAssert d.drawsWiggles and d.drawsDensity
  d.mode = dmDensity
  doAssert not d.drawsWiggles and d.drawsDensity

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

block rangesInTheOrderShown:
  # a Shift + click's range: the traces from the anchor to the one clicked,
  # in the order shown (here every trace of a file whose trace 0 is 100, in
  # reverse)
  let p = Panel(shown: @[5, 4, 3, 2, 1, 0])
  doAssert p.rangeOf(100, 104, 101) == @[104, 103, 102, 101]
  doAssert p.rangeOf(100, 101, 104) == @[104, 103, 102, 101], "either way"
  doAssert p.rangeOf(100, 103, 103) == @[103]
  doAssert p.rangeOf(100, -1, 102) == @[102], "no anchor: the trace alone"
  doAssert p.rangeOf(100, 7, 102) == @[102], "an anchor not shown: the trace alone"
  doAssert Panel().rangeOf(100, 104, 102) == @[102], "the order not known yet"
  # the anchor: the one trace clicked or toggled last; a range leaves it
  var sel = Selection()
  doAssert sel.anchor == -1
  sel.select([7], smReplace)
  doAssert sel.anchor == 7
  sel.select([9], smToggle)
  doAssert sel.anchor == 9 and sel.selected.len == 2
  sel.select([1, 2, 3], smRange)
  doAssert sel.anchor == 9 and sel.selected.len == 3 and 9 notin sel.selected
  sel.select([4, 5], smReplace)
  doAssert sel.anchor == 9, "many traces at once are no click"
  sel.forget(SessionId(1), 0 .. 10)
  doAssert sel.anchor == -1, "the anchor goes with its file"

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
