## Spectra in `core` (`core/spectra`, `core/spectrumreader`, `ckSpectrum`,
## `ckSpectrumDisplay`, `ckCloseSpectrum`, `ckSpectrumPanel`), without a
## window, on `spectrumSegy` (channels 1 to 8 a sine on bin 100 in white
## noise, channel 9 a loud 100 Hz sine):
##
## - the helpers: a time window in samples, traces spread evenly, the
##   lowest free FFT window number, dB on one reference, the curve plot's
##   limits, nearest point and readout, a window's plot and words;
## - an FFT window of one trace peaks on the sine's bin, at its amplitude,
##   from 0 Hz to Nyquist, with the sine's phase there, and says what it is
##   of; of the selection, the
##   average of its traces, counted;
## - a killed trace changes neither the average nor its count (the loud
##   trace killed among the others gives the others' spectrum, bit for
##   bit), and the answer counts it as killed;
## - raw and processed differ as the filter predicts: a band-pass's ratio
##   is 0 below its first corner and above its last, 1 between the second
##   and third, a half at its ramps' middles; a notch's dip at its
##   frequency, none either side; the visible time asked over that time;
## - several windows at once, each its own; one closed while it computes
##   takes no answer; another of the same traces reads nothing again;
## - the live panel works only while on screen and not frozen; follows the
##   view (a request each time it shows other traces, the traces it brings
##   in read, the others not) and the selection; a change of the filters
##   alone reads nothing from the file; a kill asks again without the
##   trace;
## - killed traces hidden (a setting): the panel's layout and positions
##   leave them out, and take them back when shown again or restored;
## - the settings round trip through the settings file;
## - the file is never changed.
##
## Seen to fail: with the killed traces not left out of the request
## (`askSpectrum` giving no `killed`), "the killed trace changed the
## average: 9 averaged"; with the sum's blocks combined by amplitude (not
## power), "two blocks' sum differs from one block's"; with the samples
## never kept at hand, "trace 1 was at hand: 8"; with `followSpectrum`
## asking while hidden, the first FFT window found its trace read already
## (`sp.read == 1` failed: the hidden panel had read the view).

import std/[math, os, sequtils, strutils]
import parseSEG
import processSEG/core/[rows, types]
import viewSEG/core/[settingsnif, state]
import viewSEG/view/[curveplot, spectrumview, theme]
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

block helpers:
  doAssert windowColumns(NaN, NaN, 0, 2, 100) == 0 .. 99
  doAssert windowColumns(10, 20, 0, 2, 100) == 5 .. 10
  doAssert windowColumns(9, 21, 0, 2, 100) == 5 .. 10 # whole samples inside
  doAssert windowColumns(-50, 1000, 0, 2, 100) == 0 .. 99
  doAssert windowColumns(300, 400, 0, 2, 100).len == 0
  doAssert windowColumns(10, 20, 4, 2, 100) == 3 .. 8 # from the trace's own first time
  doAssert evenly(5, 10) == @[0, 1, 2, 3, 4]
  doAssert spectrumTraces(4001) == MaxSpectrumTraces and spectrumTraces(60001) == 559 and
    spectrumTraces(0) == MaxSpectrumTraces and spectrumTraces(high(int)) == 1,
    "a spectrum's traces are bounded by their samples"
  doAssert evenly(10, 5) == @[0, 2, 4, 6, 8]
  doAssert freeSpectrumId([SpectrumWindow(id: 0), SpectrumWindow(id: 1),
    SpectrumWindow(id: 3)]) == 2
  doAssert freeSpectrumId([SpectrumWindow(id: 0)]) == 1
  let db = dbOf([1.0, 0.1, 0.0, 10.0], 10.0)
  doAssert abs(db[0] + 20) < 1e-9 and abs(db[1] + 40) < 1e-9 and db[2] == -120 and
    abs(db[3]) < 1e-9, $db
  doAssert peakBin([0.0, 3.0, 2.0, NaN]) == 1 and peakOf([0.0, 3.0, Inf]) == 3
  var w = SpectrumWindow(id: 2, chosen: soSelection, file: "a.sgy", record: "FFID 5",
    traces: @[3, 4, 5])
  doAssert w.title == "FFT 2: 3 traces · FFID 5 · a.sgy", w.title
  w.id = 1
  w.traces = @[1003] # a survey-wide id: the trace's number in its file is said
  w.first = 3
  doAssert w.title == "FFT: trace 4 · FFID 5 · a.sgy", w.title
  doAssert SpectrumWindow(id: 0).title == "Spectrum"
  var many = SpectrumWindow(id: 3, chosen: soSelection, traces: @[0, 5], chosenCount: 10,
    spectrum: Spectrum(raw: @[1.0, 0.5], averaged: 2, binHz: 1, dtMs: 2, fromMs: 0, toMs: 6))
  doAssert many.summaryText == "2 traces averaged, spread evenly over the 10 selected · " &
    "0 to 6 ms · 2 ms, Nyquist 250 Hz", many.summaryText
  # the curve plot
  var p = CurvePlot(xs: @[0.0, 1, 2, 3, 4], xUnit: "Hz", yUnit: "dB",
    curves: @[Curve(name: "raw", ys: @[-10.0, -20, NaN, -5, -120]),
      Curve(name: "processed", ys: @[-30.0, -1, -2, -3, -4])])
  doAssert p.xLimits == Span(lo: 0, hi: 4)
  let y = p.yLimits
  doAssert abs(y.lo - (-120 - 5.95)) < 1e-9 and abs(y.hi - (-1 + 5.95)) < 1e-9, $y
  p.yFloor = -100
  doAssert abs(p.yLimits.lo - (-100 - 4.95)) < 1e-9
  doAssert p.nearestIndex(2.4) == 2 and p.nearestIndex(2.6) == 3 and p.nearestIndex(-5) == 0 and
    p.nearestIndex(50) == 4
  let r = p.readingAt(1.2)
  doAssert r.index == 1 and r.values == @[-20.0, -1.0]
  doAssert p.readoutText(r) == "1 Hz   raw -20 dB   processed -1 dB", p.readoutText(r)
  p.logX = true # 0 Hz is left out
  doAssert p.xLimits == Span(lo: 1, hi: 4) and p.nearestIndex(0.1) == 1
  doAssert p.nearestIndex(1.9) == 2 # nearer on the screen: log(2/1.9) < log(1.9/1)
  doAssert valueText(24.4140625) == "24.4" and valueText(0.000122) == "0.000122" and
    valueText(-120.0) == "-120" and valueText(250.0) == "250"
  doAssert CurvePlot().isEmpty and not p.isEmpty
  # the sum over blocks of traces: as one block (power, not amplitude)
  var keys = newSeq[TraceKeys](3)
  var lengths = @[64, 64, 64]
  for k in keys.mitems:
    k = initTraceKeys()
    k.status = tsLive
  var data = newSeq[float32](3 * 64)
  for r in 0 ..< 3:
    for i in 0 ..< 64: data[r * 64 + i] = float32(sin(float64(i * (r + 1)) / 3) * float64(r + 1))
  let rows = rowsOf(keys, lengths)
  var one = initSpectrumSum(2, 64)
  doAssert one.add(rowBlock(data, 3, 64), initChunkMeta(rows, 2), 0) == 3
  var two = initSpectrumSum(2, 64)
  let first = keys[0 .. 0]
  let rest = keys[1 .. 2]
  doAssert two.add(rowBlock(data.toOpenArray(0, 63), 1, 64),
    initChunkMeta(rowsOf(first, lengths[0 .. 0]), 2), 0) == 1
  doAssert two.add(rowBlock(data.toOpenArray(64, 191), 2, 64),
    initChunkMeta(rowsOf(rest, lengths[1 .. 2]), 2), 0) == 2
  doAssert two.used == 3
  let (a1, a2) = (one.amplitudes, two.amplitudes)
  for k in 0 ..< a1.len:
    doAssert abs(a1[k] - a2[k]) <= 1e-9 * max(1.0, a1[k]),
      "two blocks' sum differs from one block's at bin " & $k & ": " & $a2[k] & ", " & $a1[k]

proc open(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
    st.panel(MainPanel).shown.len == SpectrumTraces)
  let lay = st.panel(MainPanel).layout
  st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 640, 512))
  doAssert st.settle(st.tiles(0).len > 0)

proc fft(st: var AppState; traces: seq[int]; show = SpectrumDisplay()): int =
  ## Opens an FFT window of `traces` (survey-wide); its index in `spectra`.
  let n = st.spectra.len
  st.apply Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: traces,
    spectrumShow: show)
  doAssert st.spectra.len == n + 1, "no window opened: " & $st.log.len
  result = st.spectra.high

proc answered(st: var AppState; w: int): bool =
  st.settle(not st.spectra[w].waiting and st.spectra[w].spectrum.raw.len > 0)

func ratio(sp: Spectrum; hz: float64): float64 =
  let k = int(round(hz / sp.binHz))
  sp.processed[k] / sp.raw[k]

proc filters(st: var AppState; pr: Processing) =
  st.apply Command(kind: ckProcessing, panel: MainPanel, processing: pr)

withFixtures fx:
  let path = fx.spectrumSegy()
  let before = (readFile(path), getLastModificationTime(path))
  var st = initAppState()
  st.open(path)
  let base = st.sessions[0].base
  doAssert st.spectra.len == 1 and st.spectra[0].id == LiveSpectrum and not st.spectra[0].shown

  block oneTrace:
    let w = st.fft(@[base])
    doAssert st.answered(w)
    let sw = st.spectra[w]
    template sp: untyped = sw.spectrum
    doAssert sw.title == "FFT: trace 1 · FFID 5 · spectrum.sgy", sw.title
    doAssert sp.averaged == 1 and sp.asked == 1 and sp.killed == 0
    doAssert sp.raw.len == SpectrumSamples div 2 + 1 and sp.nfft == SpectrumSamples
    doAssert abs(sp.binHz * float64(sp.raw.high) - 250) < 1e-9, "not to Nyquist"
    doAssert sp.raw.peakBin == SpectrumSineBin, "the sine peaks in bin " & $sp.raw.peakBin
    doAssert abs(sp.raw[SpectrumSineBin] - 1) < 0.05, "its amplitude: " & $sp.raw[SpectrumSineBin]
    doAssert sp.processed.len == 0 and sp.filters == "" # no filters on the plot
    # one trace: its phase too, a sine's -90 degrees on its bin (from the window's start)
    doAssert sp.rawPhase.len == sp.raw.len and abs(sp.rawPhase[SpectrumSineBin] + 90) < 3,
      "the sine's phase: " & $sp.rawPhase[SpectrumSineBin]
    doAssert sw.hasPhase and sw.phasePlot(builtinTheme(tmLight)).curves.len == 1
    doAssert sp.read == 1 and sp.fromMs == 0 and sp.toMs == float64(SpectrumSamples - 1) * DtMs
    let plot = sw.spectrumPlot(builtinTheme(tmLight))
    doAssert plot.curves.len == 1 and plot.curves[0].name == "raw" and
      plot.curves[0].ys[SpectrumSineBin] == 0, "0 dB at the peak"
    doAssert sw.summaryText.startsWith("1 trace · 0 to 4094 ms · 2 ms, Nyquist 250 Hz"),
      sw.summaryText

  var eight: Spectrum
  block selection:
    let ids = toSeq(base ..< base + 8)
    let w = st.fft(ids)
    doAssert st.answered(w)
    eight = st.spectra[w].spectrum
    doAssert eight.averaged == 8 and st.spectra[w].title.startsWith("FFT 2: 8 traces")
    doAssert eight.read == 7, "trace 1 was at hand: " & $eight.read
    doAssert eight.rawPhase.len == 0, "an average has no phase"
    # the power average: the RMS of the traces' own amplitudes
    var each: seq[Spectrum]
    for t in ids:
      let v = st.fft(@[t])
      doAssert st.answered(v)
      each.add st.spectra[v].spectrum
      doAssert st.spectra[v].spectrum.read == 0, "a trace at hand was read again"
    for k in [0, 50, SpectrumSineBin, 700]:
      var s = 0.0
      for e in each: s += e.raw[k] * e.raw[k]
      doAssert abs(sqrt(s / 8) - eight.raw[k]) <= 1e-9 * max(1.0, eight.raw[k]),
        "the selection's average differs from its traces' RMS at bin " & $k
    while st.spectra.len > 3: # close them again
      st.apply Command(kind: ckCloseSpectrum, spectrum: st.spectra[^1].id)
    doAssert st.spectra.len == 3

  block killed:
    let loud = base + 8
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[loud], on: true)
    let w = st.fft(toSeq(base ..< base + 9))
    doAssert st.answered(w)
    template sp: untyped = st.spectra[w].spectrum
    doAssert sp.averaged == 8, "the killed trace changed the average: " & $sp.averaged &
      " averaged"
    doAssert sp.killed == 1 and sp.asked == 9
    doAssert sp.raw == eight.raw, "the killed trace changed the spectrum"
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[loud], on: false)
    let v = st.fft(@[loud])
    doAssert st.answered(v) and st.spectra[v].spectrum.raw.peakBin ==
      int(round(SpectrumLoudHz / st.spectra[v].spectrum.binHz))
    st.apply Command(kind: ckCloseSpectrum, spectrum: st.spectra[v].id)
    st.apply Command(kind: ckCloseSpectrum, spectrum: st.spectra[w].id)

  block bandPass:
    st.filters Processing(band: pbBandPass, f1: 40, f2: 50, f3: 80, f4: 90)
    let w = st.fft(toSeq(base ..< base + 8))
    doAssert st.answered(w)
    template sp: untyped = st.spectra[w].spectrum
    doAssert sp.processed.len == sp.raw.len and sp.filters == "40-50-80-90 Hz", sp.filters
    doAssert st.spectra[w].filterText == "processed: 40-50-80-90 Hz"
    for hz in [5.0, SpectrumSineHz, 37.0, 93.0, 150.0, 240.0]:
      doAssert sp.ratio(hz) < 0.02, "the band-pass passes " & $hz & " Hz: " & $sp.ratio(hz)
    for hz in [52.0, 60.0, 65.0, 78.0]:
      doAssert abs(sp.ratio(hz) - 1) < 0.02, "the band-pass's pass band is not 1 at " & $hz &
        " Hz: " & $sp.ratio(hz)
    for hz in [45.0, 85.0]: # the cos² ramps' middles
      doAssert abs(sp.ratio(hz) - 0.5) < 0.1, "the ramp at " & $hz & " Hz: " & $sp.ratio(hz)
    let plot = st.spectra[w].spectrumPlot(builtinTheme(tmLight))
    doAssert plot.curves.mapIt(it.name) == @["raw", "processed"]
    # Shown raw, the plot's spectrum is still processed: the two compare.
    st.filters Processing(raw: true, band: pbBandPass, f1: 40, f2: 50, f3: 80, f4: 90)
    let v = st.fft(@[base])
    doAssert st.answered(v) and st.spectra[v].spectrum.processed.len > 0
    st.apply Command(kind: ckCloseSpectrum, spectrum: st.spectra[v].id)
    st.apply Command(kind: ckCloseSpectrum, spectrum: st.spectra[w].id)

  block notch:
    st.filters Processing(notches: @[NotchFilter(hz: 60, widthHz: 4)])
    let w = st.fft(toSeq(base ..< base + 8))
    doAssert st.answered(w)
    template sp: untyped = st.spectra[w].spectrum
    doAssert sp.ratio(60) < 0.1, "no dip at 60 Hz: " & $sp.ratio(60)
    for hz in [50.0, 55.0, 65.0, 70.0, SpectrumSineHz]:
      doAssert abs(sp.ratio(hz) - 1) < 0.05, "the notch cuts " & $hz & " Hz: " & $sp.ratio(hz)
    st.apply Command(kind: ckCloseSpectrum, spectrum: st.spectra[w].id)
    st.filters Processing()

  block visibleTime:
    # The plot shows 1000 to 2000 ms: an FFT window over the visible time.
    let lay = st.panel(MainPanel).layout
    var v = fitAll(lay, 640, 512)
    v.timeMs = Span(lo: 1000, hi: 2000)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    let w = st.fft(@[base], SpectrumDisplay(time: stVisible))
    doAssert st.answered(w)
    template sp: untyped = st.spectra[w].spectrum
    doAssert sp.fromMs == 1000 and sp.toMs == 2000 and sp.windowLen == 501, $sp.fromMs
    doAssert sp.nfft == 512 and sp.read == 0
    # The whole trace again: asked again, over the time it had.
    st.apply Command(kind: ckSpectrumDisplay, spectrum: st.spectra[w].id,
      spectrumShow: SpectrumDisplay(time: stWhole))
    doAssert st.spectra[w].waiting and st.answered(w)
    doAssert st.spectra[w].spectrum.windowLen == SpectrumSamples
    # dB or linear, the axis, the curves: shown otherwise, nothing asked
    let asks = st.spectra[w].asks
    st.apply Command(kind: ckSpectrumDisplay, spectrum: st.spectra[w].id,
      spectrumShow: SpectrumDisplay(scale: ssLinear, logFrequency: true))
    doAssert st.spectra[w].asks == asks and not st.spectra[w].waiting
    let plot = st.spectra[w].spectrumPlot(builtinTheme(tmLight))
    doAssert plot.logX and plot.yUnit == "" and
      plot.curves[0].ys[SpectrumSineBin] == st.spectra[w].spectrum.raw[SpectrumSineBin]
    doAssert st.settings.spectrum.window.scale == ssLinear, "a new FFT window starts as the last"
    st.apply Command(kind: ckCloseSpectrum, spectrum: st.spectra[w].id)
    st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 640, 512))

  block closedWhileComputing:
    let w = st.fft(toSeq(base ..< base + 9))
    let id = st.spectra[w].id
    st.apply Command(kind: ckCloseSpectrum, spectrum: id)
    doAssert st.findSpectrum(id) < 0
    # Another window of that number at once: the closed one's answer is not its.
    let again = st.fft(@[base + 3])
    doAssert st.spectra[again].id == id
    doAssert st.answered(again) and st.spectra[again].spectrum.asked == 1,
      "the closed window's answer was taken: " & $st.spectra[again].spectrum.asked
    st.apply Command(kind: ckCloseSpectrum, spectrum: id)
    st.apply Command(kind: ckCloseSpectrum, spectrum: id) # gone: ignored, says so
    var said = ""
    for e in st.log: said = e.text
    doAssert "there is no FFT window" in said, said

  block livePanel:
    let lay = st.panel(MainPanel).layout
    template live: untyped = st.spectra[0]
    # hidden: nothing asked, whatever the view
    var v = fitAll(lay, 640, 512)
    v.traces = Span(lo: -0.5, hi: 3.5)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert live.asks == 0, "the hidden panel asked"
    st.apply Command(kind: ckSpectrumPanel, onScreen: true)
    doAssert live.shown and live.asks == 1 and live.chosen == soVisible
    doAssert st.answered(0)
    doAssert live.spectrum.averaged == 4 and live.traces == toSeq(base ..< base + 4)
    doAssert live.spectrum.fromMs == 0, "the live panel is over the visible time"
    doAssert live.title == "Spectrum" and live.label == "4 visible traces · FFID 5 · spectrum.sgy"
    # a pan: the traces it brings in are read, those at hand not
    v.traces = Span(lo: 1.5, hi: 5.5)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert live.asks == 2 and st.answered(0) and st.settle(live.spectrum.averaged == 4)
    doAssert live.spectrum.read == 0, "traces at hand were read: " & $live.spectrum.read
    v.traces = Span(lo: 4.5, hi: 8.5)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert st.answered(0) and st.settle(live.traces[0] == base + 5)
    doAssert live.spectrum.read <= 1, "read: " & $live.spectrum.read # trace 9 only, once
    # the same view again: nothing asked
    let asks = live.asks
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert live.asks == asks
    # the filters alone: asked again, nothing read from the file
    st.filters Processing(band: pbHighCut, f3: 60, f4: 80)
    doAssert live.asks == asks + 1 and st.answered(0) and
      st.settle(live.spectrum.processed.len > 0)
    doAssert live.spectrum.read == 0, "a filter change read " & $live.spectrum.read & " traces"
    # a kill of a trace in view: asked again without it
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base + 8],
      on: true)
    doAssert live.asks == asks + 2 and st.answered(0) and st.settle(live.spectrum.killed == 1)
    doAssert live.spectrum.averaged == 3
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base + 8],
      on: false)
    # frozen: it keeps what it shows
    st.apply Command(kind: ckSpectrumDisplay, spectrum: 0, frozen: true,
      spectrumShow: st.settings.spectrum.live)
    let frozenAsks = live.asks
    v.traces = Span(lo: -0.5, hi: 2.5)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert live.asks == frozenAsks and live.frozen, "the frozen panel asked"
    st.apply Command(kind: ckSpectrumDisplay, spectrum: 0, frozen: false,
      spectrumShow: st.settings.spectrum.live)
    doAssert live.asks == frozenAsks + 1, $(live.asks, frozenAsks)
    doAssert st.answered(0) and st.settle(live.spectrum.averaged == live.traces.len)
    # the selection wins over the view
    st.apply Command(kind: ckSelect, traces: @[base + 6, base + 7], mode: smReplace)
    doAssert live.chosen == soSelection and live.traces == @[base + 6, base + 7]
    doAssert st.answered(0) and st.settle(live.spectrum.averaged == 2)
    st.apply Command(kind: ckClearSelection)
    doAssert live.chosen == soVisible
    # hidden again: nothing more asked
    st.apply Command(kind: ckSpectrumPanel, onScreen: false)
    let hiddenAsks = live.asks
    v.traces = Span(lo: 2.5, hi: 6.5)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert live.asks == hiddenAsks
    st.filters Processing()
    st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 640, 512))

  block hidden:
    var s = st.settings
    s.hideKilled = true
    st.apply Command(kind: ckSettings, settings: s)
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base + 2],
      on: true)
    doAssert st.settle(st.panel(MainPanel).laidOut and
      st.panel(MainPanel).layout.traces == SpectrumTraces - 1 and
      st.panel(MainPanel).shown.len == SpectrumTraces - 1)
    doAssert 2 notin st.panel(MainPanel).shown and st.panel(MainPanel).hidden == @[2]
    doAssert st.settle(st.tiles(0).len > 0 and 2 notin st.tiles(0)[^1].traces)
    st.apply Command(kind: ckUndoEdit, panel: MainPanel) # restored: back in
    doAssert st.settle(st.panel(MainPanel).shown.len == SpectrumTraces)
    st.apply Command(kind: ckRedoEdit, panel: MainPanel)
    doAssert st.settle(st.panel(MainPanel).shown.len == SpectrumTraces - 1)
    s.hideKilled = false # drawn blank again
    st.apply Command(kind: ckSettings, settings: s)
    doAssert st.settle(st.panel(MainPanel).shown.len == SpectrumTraces and
      st.panel(MainPanel).hidden.len == 0)

  block settingsFile:
    var s = Settings()
    s.hideKilled = true
    s.spectrum.window = SpectrumDisplay(scale: ssLinear, logFrequency: true, time: stVisible,
      raw: false)
    s.spectrum.live.processed = false
    var problems: seq[string]
    let back = readSettings(settingsDocument(s), "settings.nif", Settings(), problems)
    doAssert problems.len == 0, $problems
    doAssert back.hideKilled and back.spectrum == s.spectrum
    doAssert Settings().spectrum.live.time == stVisible and
      Settings().spectrum.window.time == stWhole and not Settings().hideKilled

  st.shutdown()
  doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
echo "tspectra: ok"
