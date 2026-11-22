## The first-break overlay's geometry (`view/breakbars`) without a window: a line
## through the times where the traces are closer than a few pixels draws, in each
## pixel column, from the earliest to the latest time of its traces, so no trace's
## pick is dropped (2000 traces in 600 pixels) and a flagged trace is linked on its
## own; the bars of a trace whose time axis starts elsewhere than the plot's are
## where the plot draws its samples (its times moved by `shiftMs`).
##
## Seen to fail: with the line keeping one trace in four (as it first did),
## "trace 1 at 100.3 ms has no mark in its column"; with the shift left out,
## "trace 5's pick bar is at 24.0 px, the plot draws its sample at 14.0".

import std/[math, strutils]
import viewSEG/core/[firstbreaks, geometry, orientation, viewport]
import viewSEG/view/breakbars

proc made(n: int): FirstBreaks =
  result = FirstBreaks(state: bkDone, first: 0, dtMs: 2.0, modelled: n, used: n,
    pickMs: newSeq[float64](n), modelMs: newSeq[float64](n), confidence: newSeq[float64](n),
    shiftMs: newSeq[float64](n), flagged: newSeq[bool](n))
  for i in 0 ..< n:
    result.pickMs[i] = 100 + 0.3 * float64(i)
    result.modelMs[i] = result.pickMs[i]
    result.confidence[i] = 1

proc main*() =
  let plot = Rect(pos: vec2(0, 0), size: vec2(600, 400))

  block lineKeepsEveryTrace:
    const n = 2000
    var b = made(n)
    b.pickMs[1001] += 400 # the planted trace, and the fit says so
    b.flagged[1001] = true
    var shown = newSeq[int](n)
    for i in 0 ..< n: shown[i] = i
    let layout = PanelLayout(traces: n, samples: 1000, dtMs: 2, t0Ms: 0)
    let view = Viewport(traces: Span(lo: -0.5, hi: n.float64 - 0.5),
      timeMs: Span(lo: 0, hi: 2000), columns: 600, rows: 400)
    let g = breakGeometry(b, shown, layout, view, TimeDown, plot)
    doAssert g.lines, "the traces are 0.3 px apart"
    var spans: array[600, (float32, float32)]
    for c in 0 ..< 600: spans[c] = (Inf.float32, -Inf.float32)
    var linked = false
    for m in g.marks:
      if m.kind == bmPick and m.position == -1:
        let c = int(m.a.x)
        spans[c] = (min(spans[c][0], min(m.a.y, m.b.y)), max(spans[c][1], max(m.a.y, m.b.y)))
      if m.kind == bmLink and m.trace == 1001: linked = true
    doAssert linked, "the flagged trace has no link"
    for t in 0 ..< n:
      let c = int(float32(t) * 600 / 2000)
      let y = float32(b.pickOf(t) * 400 / 2000)
      doAssert spans[c][0] - 0.7 <= y and y <= spans[c][1] + 0.7, "trace " & $t & " at " &
        $b.pickOf(t) & " ms has no mark in its column"

  block barsWhereThePlotDrawsTheSample:
    var b = made(60)
    b.shiftMs[5] = -50 # its time axis starts 50 ms later than the plot's
    var shown = newSeq[int](60)
    for i in 0 ..< 60: shown[i] = i
    let layout = PanelLayout(traces: 60, samples: 1000, dtMs: 2, t0Ms: 0)
    let view = Viewport(traces: Span(lo: -0.5, hi: 59.5), timeMs: Span(lo: 0, hi: 2000),
      columns: 600, rows: 400)
    let g = breakGeometry(b, shown, layout, view, TimeDown, plot)
    doAssert not g.lines
    var got = NaN
    for m in g.marks:
      if m.kind == bmPick and m.position == 5: got = m.a.y
    let want = float32((b.pickMs[5] - 50) * 400 / 2000)
    doAssert abs(got - want) < 0.5, "trace 5's pick bar is at " & $got & " px, the plot " &
      "draws its sample at " & $want

  echo "tbreakbars: ok"

when isMainModule:
  main()
