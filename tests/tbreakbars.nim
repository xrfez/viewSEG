## The first-break overlay's geometry (`view/breakbars`) without a window: a line
## through the times where the traces are closer than a few pixels draws, in each
## pixel column, from the earliest to the latest time of its traces, so no trace's
## pick is dropped (2000 traces in 600 pixels) and a flagged trace is linked on its
## own; the bars of a trace whose time axis starts elsewhere than the plot's are
## where the plot draws its samples (its times moved by `shiftMs`).
##
## Seen to fail: with the line keeping one trace in four (as it first did),
## "trace 1 at 100.3 ms has no mark in its column"; with the shift left out,
## "trace 5's pick bar is at 24.0 px, the plot draws its sample at 14.0";
## with the edit shift left out of the pick bar, "trace 5's pick bar is at
## 20.3 px, the shifted trace is drawn at 21.9"; with the first-pass pick gated
## on a confidence (`firstConf`) the stimulus does not set, "the far-off marker
## did not move" and "the first-pass marker did not move".

import std/[math, strutils]
import viewSEG/core/[breakmodel, edits, firstbreaks, geometry, orientation, panels, session,
  viewport]
import viewSEG/view/breakbars

proc markY(g: BreakGeometry; kind: MarkKind; position: int): float32 =
  result = NaN
  for m in g.marks:
    if m.kind == kind and m.position == position: return m.a.y

proc overlayKey(e: FileEdits; traces: Slice[int]): BreakKey =
  ## What the overlay's job key stores from the edits: killed traces only.
  (SessionId(1), 0, 1, e.listIn(teKilled, traces), newSeq[uint8](), BreakModel(), pbAsRecorded)

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

  block weakPicksAreLeftOutUnlessAsked:
    # Seen to fail: with the weak picks always drawn, "a weak pick has a bar" and "a weak pick
    # is in a line".
    for n in [40, 2000]:
      var b = made(n)
      var weak: seq[int]
      for i in 0 ..< n:
        if (n == 40 and i mod 4 == 0) or (n == 2000 and i in 1000 ..< 1500):
          b.confidence[i] = 0.1
          weak.add i
      var shown = newSeq[int](n)
      for i in 0 ..< n: shown[i] = i
      let layout = PanelLayout(traces: n, samples: 1000, dtMs: 2, t0Ms: 0)
      let view = Viewport(traces: Span(lo: -0.5, hi: n.float64 - 0.5),
        timeMs: Span(lo: 0, hi: 2000), columns: 600, rows: 400)
      let all = breakGeometry(b, shown, layout, view, TimeDown, plot)
      let some = breakGeometry(b, shown, layout, view, TimeDown, plot, showWeak = false)
      doAssert b.faintOf(weak[0]) and not b.faintOf(1)
      var (faintAll, faintSome, picksAll, picksSome) = (0, 0, 0, 0)
      for m in all.marks:
        if m.kind == bmPick:
          inc picksAll
          if m.faint: inc faintAll
      for m in some.marks:
        if m.kind == bmPick:
          inc picksSome
          if m.faint: inc faintSome
      if n == 40:
        doAssert all.lines == false and faintAll == 10 and picksAll == 40, $faintAll
        doAssert faintSome == 0 and picksSome == 30, "a weak pick has a bar: " & $picksSome
      else:
        doAssert all.lines and some.lines
        # a line through the strong picks only: it lacks the pixel columns the weak ones filled
        # (a quarter of the record, whose columns have no other pick)
        doAssert picksSome > 0 and picksSome < picksAll,
          "a weak pick is in a line: " & $picksSome & " of " & $picksAll
      # the models and the strong picks are the same
      var modelsAll, modelsSome = 0
      for m in all.marks:
        if m.kind == bmModel: inc modelsAll
      for m in some.marks:
        if m.kind == bmModel: inc modelsSome
      doAssert modelsAll == modelsSome

  block hiddenKindsDrawNothing:
    # Seen to fail: with the link drawn whenever the pick is, "a link with the model hidden".
    for k in [bmModel, bmPick]:
      doAssert k.shows(true, true)
    doAssert bmModel.shows(false, true) and not bmModel.shows(true, false)
    doAssert bmPick.shows(true, false) and not bmPick.shows(false, true)
    doAssert bmLink.shows(true, true), "no link with both shown"
    doAssert not bmLink.shows(true, false), "a link with the model hidden"
    doAssert not bmLink.shows(false, true), "a link with the picks hidden"
    for k in MarkKind:
      doAssert not k.shows(false, false), "a mark with both hidden"

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

  block barSizes:
    # Seen to fail: with the least left out of Medium, "a bar is 2.4 px on a dense record".
    for ui in [1'f32, 2]:
      doAssert barWidth(bzMedium, 3.2, ui) == 7 * ui, "a bar is " & $barWidth(bzMedium, 3.2, ui)
      doAssert barWidth(bzMedium, 20, ui) == 16, $barWidth(bzMedium, 20, ui)
      doAssert barWidth(bzMedium, 500, ui) == 40 * ui
      doAssert barWidth(bzSmall, 3.2, ui) < 3 and barWidth(bzLarge, 3.2, ui) == 10 * ui
    for k in [bmModel, bmPick]:
      doAssert barThickness(bzMedium, k, false, false) >= 3
      doAssert barThickness(bzSmall, k, false, false) < barThickness(bzLarge, k, false, false)
    var b = made(60)
    var shown = newSeq[int](60)
    for i in 0 ..< 60: shown[i] = i
    let layout = PanelLayout(traces: 60, samples: 1000, dtMs: 2, t0Ms: 0)
    let view = Viewport(traces: Span(lo: -0.5, hi: 59.5), timeMs: Span(lo: 0, hi: 2000),
      columns: 600, rows: 400)
    for size in BreakSize:
      let g = breakGeometry(b, shown, layout, view, TimeDown, plot, size)
      for m in g.marks:
        if m.kind == bmModel:
          doAssert abs((m.b.x - m.a.x) - barWidth(size, 10, 1)) < 0.01, $size
    let dense = breakGeometry(b, shown, layout, Viewport(traces: Span(lo: -0.5, hi: 59.5),
      timeMs: Span(lo: 0, hi: 2000), columns: 600, rows: 400), TimeDown,
      Rect(pos: vec2(0, 0), size: vec2(150, 400)))
    doAssert dense.lines, "2.5 px a trace: two lines, not dashes"

  block anEditShiftMovesThePickNotTheModel:
    # A +8 ms edit (4 samples at 2 ms) draws the pick 8 ms later. The stored
    # pick, the model, a zero shift, a reversal and a killed trace stay put.
    # Undo puts the bar back; the job key, which stores killed traces only, does not change.
    # Trace 4 is far off (first pass 80 ms, guided 200). Trace 9 is compared on its
    # first-pass pick (60 ms, guided 180). Neither sets `firstConf`: the shown pick
    # is `firstMs`, and the marker is that time plus the edit.
    var b = made(60)
    b.rule.farOff = newSeq[bool](60)
    b.rule.farOff[4] = true
    b.rule.firstPick = newSeq[bool](60)
    b.rule.firstPick[9] = true
    b.geometry.firstMs = newSeq[float64](60)
    for i in 0 ..< 60: b.geometry.firstMs[i] = b.pickMs[i]
    b.geometry.firstMs[4] = 80.0
    b.pickMs[4] = 200.0
    b.geometry.firstMs[9] = 60.0
    b.pickMs[9] = 180.0
    let stored = b.pickMs[5]
    var shown = newSeq[int](60)
    for i in 0 ..< 60: shown[i] = i
    let layout = PanelLayout(traces: 60, samples: 1000, dtMs: 2, t0Ms: 0)
    let view = Viewport(traces: Span(lo: -0.5, hi: 59.5), timeMs: Span(lo: 0, hi: 2000),
      columns: 600, rows: 400)
    let today = breakGeometry(b, shown, layout, view, TimeDown, plot)
    var e: FileEdits
    let traces = 0 .. 59
    let key0 = overlayKey(e, traces)
    discard e.setTimeShifts([5], 8.0, 2.0)
    doAssert e.shiftOf(5) == 8.0 and b.pickMs[5] == stored, "the stored pick moved"
    doAssert b.pickOf(5) == stored, "file-time pickOf took the edit"
    doAssert overlayKey(e, traces) == key0, "a shift changed the pick key"
    let g = breakGeometry(b, shown, layout, view, TimeDown, plot, edits = e)
    let want = float32((stored + 8.0) * 400 / 2000)
    let got = markY(g, bmPick, 5)
    doAssert abs(got - want) < 0.5, "trace 5's pick bar is at " & $got &
      " px, the shifted trace is drawn at " & $want
    doAssert abs(markY(g, bmModel, 5) - markY(today, bmModel, 5)) < 0.5, "the model moved"
    doAssert "pick 109.5 ms" in b.readoutText(5, e), b.readoutText(5, e)
    doAssert "model 101.5 ms" in b.readoutText(5, e), b.readoutText(5, e)
    discard e.undo()
    doAssert e.shiftOf(5) == 0.0 and overlayKey(e, traces) == key0, "undo changed the key"
    let back = breakGeometry(b, shown, layout, view, TimeDown, plot, edits = e)
    doAssert abs(markY(back, bmPick, 5) - markY(today, bmPick, 5)) < 0.5,
      "undo did not move the bar back"
    doAssert "pick 101.5 ms" in b.readoutText(5, e), b.readoutText(5, e)
    discard e.setTimeShifts([6], 0.0, 2.0)
    discard e.change(teReversed, [7], true)
    discard e.change(teKilled, [8], true)
    discard e.setTimeShifts([8], 8.0, 2.0)
    discard e.setTimeShifts([4], 8.0, 2.0)
    discard e.setTimeShifts([9], 8.0, 2.0)
    let later = breakGeometry(b, shown, layout, view, TimeDown, plot, edits = e)
    doAssert abs(markY(later, bmPick, 6) - markY(today, bmPick, 6)) < 0.5, "shift 0 moved"
    doAssert abs(markY(later, bmPick, 7) - markY(today, bmPick, 7)) < 0.5, "a reversal moved"
    doAssert abs(markY(later, bmPick, 8) - markY(today, bmPick, 8)) < 0.5,
      "a killed trace moved"
    let far = float32((80.0 + 8.0) * 400 / 2000)
    doAssert abs(markY(later, bmPick, 4) - far) < 0.5, "the far-off marker did not move"
    doAssert b.pickOf(4) == 80.0 and b.pickMs[4] == 200.0, "the stored far-off pick changed"
    doAssert abs(b.differenceMs(4) - (b.pickOf(4) - b.modelOf(4))) < 1e-9
    doAssert "pick 88.0 ms" in b.readoutText(4, e), b.readoutText(4, e)
    let passed = float32((60.0 + 8.0) * 400 / 2000)
    doAssert abs(markY(later, bmPick, 9) - passed) < 0.5, "the first-pass marker did not move"
    doAssert b.pickOf(9) == 60.0 and b.pickMs[9] == 180.0, "the stored first-pass pick changed"
    doAssert "pick 68.0 ms" in b.readoutText(9, e), b.readoutText(9, e)
    doAssert overlayKey(e, traces).killed == @[8], "the key stored more than the kill"

  echo "tbreakbars: ok"

when isMainModule:
  main()
