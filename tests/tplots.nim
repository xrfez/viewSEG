## The analysis windows (New plot) in `core`, without a window, on a record
## of a pilot sweep (an auxiliary trace) and four seismic traces, each the
## sweep 10 ms later than the one before:
##
## - a cross-correlation of the seismic traces takes the record's pilot as
##   its reference when none is chosen, and each trace peaks at its delay
##   (10, 20, 30, 40 ms); with a seismic trace chosen as the reference, the
##   delays are from it, and the note says the reference is one of the
##   signals (its autocorrelation);
## - a spectrogram of the pilot rises with the sweep; the envelope and the
##   phase spectrum of a trace come back with their curves;
## - not frozen, a window follows the plot it was opened from: new filters
##   ask again (and the note says what they are), a kill of one of its
##   traces asks again and leaves it out; frozen, it asks nothing;
## - a reference in another file (a pilot sweep's own) is taken, and that
##   file stays open while the window uses it, when the record is shown
##   again (showing a file closes the one shown before otherwise);
## - its cursor is held where a command puts it; closed, it goes; a window
##   with no trace to show is refused.
##
## Seen to fail: with `followPlots` not called, "the filters were not
## followed: 1 asks"; with the record's pilot not taken as the default
## reference (`firstAux`), `"pilot" in st.plots[0].reference` (the first
## trace asked about taken instead); with `showReplacing` not asking
## `plotsUse`, "the pilot's file was closed under its window"; without the
## note of a signal that is the reference, "Against trace 2: trace 2 peaks
## at 0.0 ms; trace 3 peaks at 10.0 ms; ..."; with a vibrator signature
## opened on one trace kept to it, `traces == @[...]` "@[0]"; with the
## settings compared field by field as Nim does (NaN unequal to itself),
## "the same settings asked again".

import std/[math, os, strutils]
import parseSEG
import viewSEG/core/[edits, log, processing, state]
import utils/[fixtures, waiting]

const
  DtMs = 2.0
  Samples = 1500
  Delay = 10.0 ## ms, from one trace to the next

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func sweep(i: int): float32 =
  ## A 10 to 60 Hz linear sweep over 2 s, tapered, then silence.
  let t = float64(i) * DtMs / 1000
  if t > 2: return 0
  let taper = min(1.0, min(t, 2 - t) / 0.1)
  float32(taper * sin(2 * PI * (10 * t + 50 / 4 * t * t)))

proc pilotRecord(fx: Fixtures): string =
  result = fx.dir / "pilot-record.sgy"
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: a pilot and four delayed copies"]))
  var buf = newSeq[float32](Samples)
  for c in 0 .. 4:
    let shift = int(round(float64(c) * Delay / DtMs))
    for i in 0 ..< Samples: buf[i] = if c == 0: sweep(i) else: sweep(i - shift + 0)
    for i in 0 ..< min(shift, Samples): buf[i] = 0
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs) = (1.0, float64(c + 1), 0.0, DtMs * 1000)
    if c == 0: (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    else: k.status = tsLive
    w.writeTrace(k, buf)
  doAssert w.close().len == 0

proc lastText(log: MessageLog): string = log[log.len - 1].text

proc answered(st: AppState; w: int): bool =
  st.plots[w].result.gen > 0 and not st.plots[w].waiting

withFixtures fx:
  var st = initAppState()
  let path = fx.pilotRecord()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  var s = st.sessions[0]
  # the trace filter shows the auxiliary trace too
  st.apply Command(kind: ckFilter, panel: MainPanel, filter: TraceFilter(seismic: true,
    auxiliary: true))
  doAssert st.settle(st.panel(MainPanel).laidOut)

  block correlation:
    st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
      plotTraces: @[s.base + 1, s.base + 2, s.base + 3, s.base + 4])
    doAssert st.plots.len == 1, st.log.lastText
    doAssert st.settle(st.answered(0)), "no answer"
    let r = st.plots[0].result
    doAssert r.problem == "", r.problem
    doAssert "pilot" in st.plots[0].reference, st.plots[0].reference
    for c in 0 .. 3:
      let lag = r.peakLagMs(c)
      doAssert abs(lag - Delay * float64(c + 1)) < 1e-9, "trace " & $(c + 2) & " peaks at " &
        $lag & " ms, want " & $(Delay * float64(c + 1))
    # a seismic trace as the reference: the delays are from it
    var p = st.plots[0].params
    p.reference = s.base + 1
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: p)
    doAssert st.settle(st.answered(0) and st.plots[0].result.gen == st.plots[0].asked)
    doAssert abs(st.plots[0].result.peakLagMs(1) - Delay) < 1e-9,
      "the delays are from trace 2: " & $st.plots[0].result.peakLagMs(1) & " ms"
    # trace 2 is one of the signals: the window says it is the reference itself
    doAssert "trace 2 is the reference itself" in st.plots[0].result.note,
      st.plots[0].result.note

  block aPilotOfAnotherFile:
    # the reference in another file (a pilot sweep's own file): chosen while
    # that file is shown, kept open when the record is shown again
    let pilot = fx.pilotSegy()
    st.apply Command(kind: ckOpen, paths: @[pilot])
    doAssert st.settle(st.sessions.len == 2 and st.panel(MainPanel).laidOut and
      st.sessions[st.shownFile(st.findPanel(MainPanel))].path == pilot)
    let other = st.sessions[st.findSession(st.sessions[1].id)]
    var p = st.plots[0].params
    p.reference = other.base
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: p)
    doAssert st.settle(st.answered(0) and st.plots[0].result.gen == st.plots[0].asked)
    doAssert st.plots[0].result.problem == "", st.plots[0].result.problem
    doAssert "pilot.sgy" in st.plots[0].reference, st.plots[0].reference
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.panel(MainPanel).laidOut and
      st.sessions[st.shownFile(st.findPanel(MainPanel))].path == path)
    doAssert st.findTrace(other.base) >= 0, "the pilot's file was closed under its window"
    s = st.sessions[st.findSession(s.id)]
    # back to the record's own pilot
    p.reference = -1
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: p)
    doAssert st.settle(st.answered(0) and st.plots[0].result.gen == st.plots[0].asked)

  block otherViews:
    for v in [avSpectrogram, avEnvelope, avPhase]:
      st.apply Command(kind: ckOpenPlot, plotView: v, plotTraces: @[s.base])
    doAssert st.plots.len == 4
    doAssert st.settle(st.answered(1) and st.answered(2) and st.answered(3))
    for w in 1 .. 3: doAssert st.plots[w].result.problem == "", st.plots[w].result.problem
    let img = st.plots[1].result.image
    proc peakHz(col: int): float64 =
      var best = 0
      for row in 0 ..< img.rows:
        if img.valueAt(col, row) > img.valueAt(col, best): best = row
      img.y0 + float64(best) * img.dy
    let early = int((300 - img.x0) / img.dx)
    let late = int((1700 - img.x0) / img.dx)
    doAssert peakHz(late) > peakHz(early) + 20, "the sweep does not rise: " & $peakHz(early) &
      " Hz at 300 ms, " & $peakHz(late) & " at 1700"
    doAssert st.plots[2].result.plots.len == 3 and st.plots[3].result.plots.len == 2
    st.apply Command(kind: ckOpenPlot, plotView: avEnvelope, plotTraces: @[s.base + 2,
      s.base + 1])
    doAssert st.plots[^1].traces == @[s.base + 2], "an envelope of " & $st.plots[^1].traces
    st.apply Command(kind: ckClosePlot, plot: st.plots[^1].id)
    doAssert st.plots[1].title.startsWith("Spectrogram 2: trace 1")

  block follows:
    # frozen: asks nothing
    var p = st.plots[3].params
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[3].id, plotParams: p, plotFrozen: true)
    let frozenAsks = st.plots[3].asks
    let asks = st.plots[1].asks
    st.apply Command(kind: ckProcessing, panel: MainPanel,
      processing: Processing(band: pbBandPass, f1: 5, f2: 8, f3: 40, f4: 50, aux: true))
    doAssert st.plots[1].asks == asks + 1, "the filters were not followed: " & $st.plots[1].asks &
      " asks"
    doAssert st.plots[3].asks == frozenAsks, "a frozen window followed the filters"
    doAssert st.settle(st.answered(1))
    doAssert "through" in st.plots[1].result.note, st.plots[1].result.note
    # a kill of one of its traces: asked again, left out
    let corrAsks = st.plots[0].asks
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[s.base + 3],
      on: true)
    discard st.drainInbox()
    doAssert st.plots[0].asks == corrAsks + 1, "the kill was not followed"
    doAssert st.settle(st.answered(0))
    doAssert st.plots[0].result.leftOut == 1, $st.plots[0].result.leftOut

  block cursorAndClose:
    let id = st.plots[1].id
    st.apply Command(kind: ckPlotCursor, plot: id, plotCursor: PlotCursor(held: true, x: 5,
      y: 7))
    doAssert st.plots[1].cursor == PlotCursor(held: true, x: 5, y: 7)
    st.apply Command(kind: ckClosePlot, plot: id)
    doAssert st.findPlot(id) < 0 and st.plots.len == 3
    st.apply Command(kind: ckClearSelection)
    st.apply Command(kind: ckOpenPlot, plotView: avEnvelope)
    doAssert st.plots.len == 3 and "no trace is selected" in st.log.lastText, st.log.lastText

  block vibrator:
    # opened on the pilot alone: it and the record's next three, as Ref,
    # GF, M, B; trace 4 (B) is killed above: left out, said
    st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[s.base])
    let w = st.plots.high
    doAssert st.plots[w].traces == @[s.base, s.base + 1, s.base + 2, s.base + 3],
      $st.plots[w].traces
    doAssert st.settle(st.answered(w))
    var r = st.plots[w].result
    doAssert r.problem == "", r.problem
    doAssert r.plots.len == 4 and r.plots[0].title == "Phase to the reference"
    doAssert "Ref trace 1 · GF trace 2 · M trace 3" in r.note and "B left out" in r.note and
      "enter both masses" notin r.note, r.note
    # the roles assigned otherwise: trace 2 the reference, the pilot its GF
    var p = st.plots[w].params
    p.roles.reference = 1
    p.roles.groundForce = 0
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p)
    doAssert st.settle(st.answered(w) and st.plots[w].result.gen == st.plots[w].asked)
    r = st.plots[w].result
    doAssert "Ref trace 2 · GF trace 1" in r.note, r.note
    # the same settings again (NaN masses and limits among them): not asked again
    let asks = st.plots[w].asks
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p)
    doAssert st.plots[w].asks == asks, "the same settings asked again"
  discard st.shutdown()
echo "tplots: ok"
