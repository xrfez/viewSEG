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
##   with no trace to show is refused;
## - a trace with no sample interval of its own is left out and counted, and
##   the window's interval is the others' 2 ms, not 1 ms.
##
## - an agent's settings out of the GUI's ranges (a null window, an overlap
##   of 120 %, a floor above 0 dB, one harmonic) are ignored and said with
##   their range; a setting the view does not use is not judged.
##
## - a frozen window keeps the kills it was frozen with, a kill made after
##   the freeze not taken when a setting changes.
##
## Seen to fail: with a frozen window's kills taken from the plot again, "the
## kill made after the freeze is taken: (3, 1)"; with the agent's settings not
## judged, "plots.len == before + 1" (the zero window taken); with the trace with
## no interval taken as 1 ms, "the reference is sampled at 2.0 ms, the traces at
## 1.0 ms"; with `followPlots` not called, "the filters were not followed: 1
## asks"; with the record's pilot not taken as the default reference
## (`firstAux`), `"pilot" in st.plots[0].reference` (the first trace asked about
## taken instead); with `showReplacing` not asking `plotsUse`, "the pilot's file
## was closed under its window"; without the note of a signal that is the
## reference, "Against trace 2: trace 2 peaks at 0.0 ms; trace 3 peaks at 10.0
## ms; ..."; with a vibrator signature opened on one trace kept to it, `traces ==
## @[...]` "@[0]"; with the settings compared field by field as Nim does (NaN
## unequal to itself), "the same settings asked again"; with an f-k's Raw not
## heeded, `"raw (the filters left out)" in r.note and "through" notin r.note`.

import std/[math, os, strutils]
import parseSEG
import viewSEG/core/[edits, log, processing, state]
import viewSEG/view/analysisview
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

proc pilotRecord(fx: Fixtures; name = "pilot-record.sgy"; noInterval = -1): string =
  ## The record; trace `noInterval` (a file index) given no sample interval
  ## of its own after writing (its header's bytes made zero: the writer
  ## refuses such a trace).
  result = fx.dir / name
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
  if noInterval >= 0:
    var f = openSeismic(result, keys = true)
    let at = int(f.index.entries[noInterval].offset) + 116         # the interval, bytes 117-118
    f.close()
    var data = readFile(result)
    data[at] = '\0'
    data[at + 1] = '\0'
    writeFile(result, data)

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

  block noIntervalOfItsOwn:
    # the trace with no sample interval of its own (the file's is not used
    # for it, the header has none) is left out and counted, as the spectrum
    # view counts one at another interval; the first trace asked about is
    # that one, so the window's interval is the others' (2 ms), not 1 ms
    var g = initAppState()
    let gap = fx.pilotRecord("gap-record.sgy", noInterval = 3)
    g.apply Command(kind: ckShowFile, panel: MainPanel, path: gap)
    doAssert g.settle(g.sessions.len == 1 and g.panel(MainPanel).laidOut)
    let gs = g.sessions[0]
    g.apply Command(kind: ckOpenPlot, plotView: avCorrelation, plotTraces: @[gs.base + 3,
      gs.base + 1, gs.base + 2, gs.base + 4])
    doAssert g.plots.len == 1, g.log.lastText
    doAssert g.settle(g.answered(0)), "no answer"
    let r = g.plots[0].result
    doAssert r.problem == "", r.problem
    doAssert r.dtMs == DtMs, "the interval is " & $r.dtMs & " ms, want " & $DtMs
    doAssert r.used == 3 and r.leftOut == 0, $(r.used, r.leftOut)
    doAssert r.atOtherInterval == 1, "the trace at another interval is not counted: " &
        $r.atOtherInterval
    discard g.shutdown()

  block frozenKeepsItsKills:
    # frozen, a window keeps the kills it was frozen with: a kill made after
    # the freeze is not taken when one of its settings changes (trace 4 is
    # restored here, and killed again after, as the vibrator block expects)
    let w = 0
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[s.base + 3],
      on: false)
    discard st.drainInbox()
    doAssert st.settle(st.answered(w) and st.plots[w].killed.len == 0), $st.plots[w].killed
    var p = st.plots[w].params
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p,
      plotFrozen: true)
    doAssert st.plots[w].frozen and st.settle(st.answered(w))
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[s.base + 3],
      on: true)
    discard st.drainInbox()
    p.maxLagMs = 200
    let asks = st.plots[w].asks
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p,
      plotFrozen: true)
    doAssert st.plots[w].asks == asks + 1, "the setting was not asked again"
    doAssert st.settle(st.answered(w) and st.plots[w].result.gen == st.plots[w].asked)
    let r = st.plots[w].result
    doAssert r.leftOut == 0 and r.used == 4, "the kill made after the freeze is taken: " &
      $(r.used, r.leftOut)
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p,
      plotFrozen: false)
    discard st.drainInbox()

  block auxPassedBy:
    # the Aux toggle off: the filters pass the auxiliary trace (the record's
    # pilot, trace 1) by, and the windows say so rather than "through ..."
    let band = Processing(band: pbBandPass, f1: 5, f2: 8, f3: 40, f4: 50, aux: false)
    st.apply Command(kind: ckProcessing, panel: MainPanel, processing: band)
    doAssert st.settle(st.answered(1) and st.plots[1].result.gen == st.plots[1].asked and
      st.answered(0) and st.plots[0].result.gen == st.plots[0].asked)
    let spec = st.plots[1].result # a spectrogram of the pilot alone
    doAssert spec.passedBy == 1 and "the auxiliary trace is not filtered" in spec.note and
      "through" notin spec.note, $spec.passedBy & ": " & spec.note
    let corr = st.plots[0].result # the traces filtered, the pilot not
    doAssert corr.passedBy == 1 and "the reference" in corr.note and
      "is not filtered: Filters > Filter the Aux traces too is off" in corr.note and
      "through" in corr.note, $corr.passedBy & ": " & corr.note
    # the same filters with Aux on: nothing passed by
    var on = band
    on.aux = true
    st.apply Command(kind: ckProcessing, panel: MainPanel, processing: on)
    doAssert st.settle(st.answered(1) and st.plots[1].result.gen == st.plots[1].asked)
    doAssert st.plots[1].result.passedBy == 0 and "through" in st.plots[1].result.note,
      st.plots[1].result.note

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

  block fk:
    # opened on one trace: the seismic traces of its record (the pilot
    # left out; the killed one restored first); raw: the filters left out,
    # said
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[s.base + 3],
      on: false)
    discard st.drainInbox()
    st.apply Command(kind: ckOpenPlot, plotView: avFk, plotTraces: @[s.base + 1])
    let w = st.plots.high
    doAssert st.plots[w].traces == @[s.base + 1, s.base + 2, s.base + 3, s.base + 4],
      $st.plots[w].traces
    doAssert st.settle(st.answered(w))
    var r = st.plots[w].result
    doAssert r.problem == "" and not r.image.isEmpty and r.leftOut == 0,
      r.problem & " " & $r.leftOut
    doAssert "through" in r.note and "raw" notin r.note, r.note
    var p = st.plots[w].params
    p.fkRaw = true
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p)
    doAssert st.settle(st.answered(w) and st.plots[w].result.gen == st.plots[w].asked)
    r = st.plots[w].result
    doAssert "raw (the filters left out)" in r.note and "through" notin r.note, r.note
  block agentSettings:
    # an agent's settings are judged as the GUI's boxes judge them: null, not
    # finite or out of the range the boxes allow is ignored, said with the
    # range; a value in range is taken
    let before = st.plots.len
    var ok = AnalysisParams()
    st.apply Command(kind: ckOpenPlot, plotView: avSpectrogram, plotTraces: @[s.base],
      plotParams: ok)
    doAssert st.plots.len == before + 1, st.log.lastText
    let shown = st.plots.len - 1
    var bad = AnalysisParams()
    bad.windowMs = 0
    st.apply Command(kind: ckOpenPlot, plotView: avSpectrogram, plotTraces: @[s.base],
      plotParams: bad)
    doAssert st.plots.len == before + 1 and "windowMs must be above 0 ms, not 0.0" in
      st.log.lastText, st.log.lastText
    bad.windowMs = NaN
    st.apply Command(kind: ckOpenPlot, plotView: avSpectrogram, plotTraces: @[s.base],
      plotParams: bad)
    doAssert st.plots.len == before + 1 and "windowMs must be above 0 ms, not null" in
      st.log.lastText, st.log.lastText
    bad = AnalysisParams()
    bad.overlap = 120
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[shown].id, plotParams: bad)
    doAssert st.plots[shown].params.overlap == 75.0 and
      "overlap must be from 0 to 95 %, not 120.0" in st.log.lastText, st.log.lastText
    bad = AnalysisParams()
    bad.floorDb = 3
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[shown].id, plotParams: bad)
    doAssert st.plots[shown].params.floorDb == -60.0 and
      "floorDb must be below 0 dB, not 3.0" in st.log.lastText, st.log.lastText
    # a vibrator's harmonics are judged on it; a setting the view does not use is not
    var vib = AnalysisParams()
    vib.harmonics = 1
    st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[s.base],
      plotParams: vib)
    doAssert st.plots.len == before + 1 and "harmonics must be from 2 to 16, not 1.0" in
      st.log.lastText, st.log.lastText
    var env = AnalysisParams()
    env.windowMs = NaN
    st.apply Command(kind: ckOpenPlot, plotView: avEnvelope, plotTraces: @[s.base],
      plotParams: env)
    doAssert st.plots.len == before + 2, st.log.lastText
    discard st.drainInbox()
  discard st.shutdown()

proc planeWaveRecord(fx: Fixtures; name: string; system: int16; spacing: float64): string =
  ## 16 traces `spacing` apart (offsets, in the file's unit), a 30 Hz plane wave
  ## at 3000 m/s: the file says its unit by the binary header's measurement system.
  result = fx.dir / name
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    measurementSystem: system, text: @["C01 viewSEG test fixture: a plane wave"]))
  var buf = newSeq[float32](500)
  let metres = spacing * (if system == 2: 0.3048 else: 1.0)
  for c in 0 ..< 16:
    for i in 0 ..< 500:
      buf[i] = float32(cos(2 * PI * 30 * (float64(i) * 0.002 - float64(c) * metres / 3000)))
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs) = (1.0, float64(c + 1), 0.0, 2000.0)
    k.offset = float64(c + 1) * spacing
    k.status = tsLive
    w.writeTrace(k, buf)
  doAssert w.close().len == 0

block feetAndMetres:
  # the unit of the file's distances reaches the f-k: the same wave, 10
  # cycles/km at 3000 m/s, in a file of feet and in one of metres
  withFixtures fx:
    for (name, system, spacing, label, velocity) in [("ft.sgy", 2'i16, 110.0,
        "Wavenumber (cycles/kft)", "ft/s"), ("m.sgy", 1'i16, 33.528,
        "Wavenumber (cycles/km)", "m/s")]:
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel,
        path: fx.planeWaveRecord(name, system, spacing))
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      st.apply Command(kind: ckOpenPlot, plotView: avFk, plotTraces: @[st.sessions[0].base])
      doAssert st.settle(st.answered(0)), "no answer"
      let img = st.plots[0].result.image
      doAssert st.plots[0].result.problem == "" and img.xLabel == label and
        img.velocityUnit == velocity, st.plots[0].result.problem & img.xLabel
      var best = (0, 0)
      for c in 0 ..< img.cols:
        for r in 0 ..< img.rows:
          if img.valueAt(c, r) > img.valueAt(best[0], best[1]): best = (c, r)
      let k = img.xOf(best[0])
      let want = if system == 2: 3.048 else: 10.0
      doAssert abs(k - want) <= 2 * img.dx, name & ": peak at " & $k & ", want " & $want
      discard st.shutdown()
echo "tplots: ok"
