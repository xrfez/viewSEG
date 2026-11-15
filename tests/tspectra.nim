## Spectra in `core` (`core/spectra`, `core/spectrumreader`, `ckSpectrum`,
## `ckSpectrumDisplay`, `ckCloseSpectrum`, `ckSpectrumPanel`), without a
## window, on `spectrumSegy` (channels 1 to 8 a sine on bin 100 in white
## noise, channel 9 a loud 100 Hz sine):
##
## - the helpers: a time window in samples, traces spread evenly, the
##   lowest free FFT window number, dB on one reference, the curve plot's
##   limits, nearest point and readout, a window's plot and words; which of
##   a plot's traces its filters reach;
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
##   frequency, none either side; the response the filter applies, on a
##   grid of its own with the notch's centre on it, is processSEG's design
##   wherever that passes more than 1 % and nearly 0 at the centre; it is
##   drawn first, under the data, thinner and faint, at its true gain in dB
##   (clamped at the floor only, its name saying so) or linear (1 at the
##   larger peak), read in dB, and hidden by its toggle; a band-pass's stop
##   band is what the filter leaves, not the design's 0; the visible time
##   asked over that time; a narrow notch over it gives finer bins
##   (`spectrumNfft`); a response the filters did not apply is not drawn;
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
## - in dB, the words say which amplitude 0 dB is (each window has its own);
## - the samples at hand are let go once no spectrum window needs them;
## - a file opened under two paths (a link): a kill made under one is left
##   out of the spectra of the other's traces;
## - a request read and computed whole is answered even when a newer one of
##   its window came meanwhile (the reader held in its read by the seam);
## - one served `KeepServing` already is finished when a newer one comes,
##   between chunks too (the reader's clock moved on by the seam);
## - the processed curve is of the traces the filters reach: with the
##   plot's Aux toggle off, a record's auxiliary trace is left out of it
##   (counted as passed by, and said), a pilot alone has none (and the
##   words say why), and filters none of which is below Nyquist give none;
##   with the toggle on, every trace;
## - an open FFT window follows the plot's filters and its Aux toggle (the
##   samples at hand, nothing read), unless frozen, and again once not;
##   and the kills of its traces (an edit of another trace asks nothing);
## - the plot's filters' reach counts the traces it shows: with the seismic
##   ones killed and hidden, the auxiliary one alone is not reached;
## - the file is never changed.
##
## Seen to fail: with the killed traces not left out of the request
## (`askSpectrum` giving no `killed`), "the killed trace changed the
## average: 9 averaged"; with the sum's blocks combined by amplitude (not
## power), "two blocks' sum differs from one block's"; with the samples
## never kept at hand, "trace 1 was at hand: 8"; with `followSpectrum`
## asking while hidden, the first FFT window found its trace read already
## (`sp.read == 1` failed: the hidden panel had read the view). With the
## words as before, the summary without "0 dB = amplitude 1 (raw peak)";
## with no `forget` when the last window closed, "the reader keeps 18432
## samples"; with the kills looked up by the link's own path (not
## `editsAt`), "the link's kill was taken into its spectrum: 0 killed, 9
## averaged"; with the reader giving up after its last chunk and block,
## "the first answer ... was dropped for the newer request (1 answer
## taken)". With the processed sum taking the auxiliary rows as live again
## (as before), "the auxiliary trace counted as processed: (5, 5, 0)";
## with the FFT windows keeping the filters they were opened with (as
## before), "the FFT window did not follow the plot's filters". With the
## reader's FFT at the next power of two whatever the filters, "the narrow
## notch's spectrum is not padded: nfft 512"; with no response in the
## answer, the band-pass's curves were only "raw" and "processed". With
## the words as before, "not processed: the plot's filters (low-cut 4-8 Hz)
## a low cut needs ..." (no verb). With `followFfts` blind to kills (as
## before), "the FFT window did not take the kill in". With the reach
## counted from the record's totals (as before), "the hidden killed traces
## counted as shown: seismic". With the response on the spectrum's bins
## (as before), "the notch's centre is not on the response's grid"; drawn
## after the data (as before), the curves were not response, raw,
## processed; drawn when the filters reached no trace, "a response the
## filters did not apply is drawn"; with the design's response, "the stop
## band is the design's zero". With a request given up for a newer one
## however long it was served (as before), "the request served 200 ms was
## given up for the newer one (1 answer taken)".

import std/[math, os, sequtils, strutils, times]
import parseSEG
import processSEG/core/[rows, types]
import processSEG/filter/design
import viewSEG/core/[settingsnif, spectrumreader, state]
import viewSEG/view/[curveplot, spectrumview, theme]
import utils/[faultyfs, fixtures, waiting]

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
  # finer bins for a narrow filter: a bin at most half its narrowest feature
  doAssert spectrumNfft(1001, 1, Inf) == 1024 and spectrumNfft(1001, 1, 1) == 2048 and
    spectrumNfft(4001, 1, 1) == 4096 and spectrumNfft(100, 1, 1e-6) == 8 * 128 and
    spectrumNfft(501, 2, 1) == 1024, $spectrumNfft(501, 2, 1)
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
  # filters that did not run say why in a sentence
  let failing = SpectrumWindow(spectrum: Spectrum(raw: @[1.0], averaged: 1,
    filters: "low-cut 4-8 Hz", filterProblem: "a low cut needs 0 ≤ f1 < f2"))
  doAssert failing.filterText == "not processed: the plot's filters (low-cut 4-8 Hz) cannot " &
    "run: a low cut needs 0 ≤ f1 < f2", failing.filterText
  # which of a plot's traces its filters reach
  let n = Processing(notches: @[NotchFilter()])
  doAssert Processing().reach(3, 1) == frNone and Processing(raw: true, dc: dcMean).reach(3, 1) ==
    frNone
  doAssert n.reach(3, 0) == frAll and n.reach(3, 1) == frSeismic and n.reach(0, 1) == frNoTrace
  doAssert Processing(aux: true, dc: dcMean).reach(0, 1) == frAll and n.reach(0, 0) == frAll
  var many = SpectrumWindow(id: 3, chosen: soSelection, traces: @[0, 5], chosenCount: 10,
    spectrum: Spectrum(raw: @[1.0, 0.5], averaged: 2, binHz: 1, dtMs: 2, fromMs: 0, toMs: 6))
  doAssert many.summaryText == "2 traces averaged, spread evenly over the 10 selected · " &
    "0 to 6 ms · 2 ms, Nyquist 250 Hz · 0 dB = amplitude 1 (raw peak)", many.summaryText
  # In dB each window has its own 0 dB (the larger peak of its curves): it
  # says which amplitude that is, so that two windows compare; in linear
  # the amplitudes speak for themselves. Curves of zeros have no peak.
  many.spectrum.processed = @[0.0, 2.5e-5]
  doAssert many.summaryText.endsWith(" · 0 dB = amplitude 1 (raw peak)"), many.summaryText
  many.spectrum.processed = @[0.0, 25.0]
  doAssert many.summaryText.endsWith(" · 0 dB = amplitude 25 (processed peak)"),
    many.summaryText
  many.display.scale = ssLinear
  doAssert "0 dB" notin many.summaryText, many.summaryText
  many.display.scale = ssDb
  many.spectrum.raw = @[0.0, 0.0]
  many.spectrum.processed = @[0.0, 0.0]
  doAssert many.summaryText.endsWith(" · every amplitude is 0"), many.summaryText
  many.spectrum.raw = @[1.0, 0.5]
  many.spectrum.processed.setLen 0
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

  block followsKills:
    # An FFT window open when one of its traces is killed asks again
    # without it, from the samples at hand, and with it once restored; an
    # edit of a trace it is not of asks nothing.
    let w = st.fft(toSeq(base ..< base + 8))
    doAssert st.answered(w) and st.spectra[w].spectrum.averaged == 8
    template sw: untyped = st.spectra[w]
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base + 2], on: true)
    doAssert sw.waiting, "the FFT window did not take the kill in"
    doAssert st.answered(w) and st.settle(sw.spectrum.killed == 1)
    doAssert sw.spectrum.averaged == 7 and sw.spectrum.read == 0
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base + 2], on: false)
    doAssert st.answered(w) and st.settle(sw.spectrum.killed == 0 and sw.spectrum.averaged == 8)
    let asks = sw.asks
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base + 8], on: true)
    doAssert sw.asks == asks, "an edit of another trace asked again"
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base + 8], on: false)
    st.apply Command(kind: ckCloseSpectrum, spectrum: sw.id)

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
    doAssert plot.curves.mapIt(it.name)[1 .. 2] == @["raw", "processed"]
    # Its stop band is what the filter leaves (the design's gain there is
    # 0), drawn at that level when it is above the floor.
    var k20 = 0
    while sp.responseHz[k20] < 20: inc k20
    doAssert sp.response[k20] > 0, "the stop band is the design's zero"
    let leaves = 20 * log10(sp.response[k20])
    doAssert leaves < -40 and (leaves < FloorDb or abs(plot.curves[0].ys[k20] - leaves) < 1e-9),
      "the stop band at 20 Hz: " & $leaves & " dB, drawn at " & $plot.curves[0].ys[k20]
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
    # The response the filter applies, on a grid of its own: the notch's
    # centre is on it whatever the bins, and its gain there is the
    # filter's (an impulse through it); elsewhere it is processSEG's design.
    let spec = bandPass(Corners(f1: 0, f2: 0, f3: Inf, f4: Inf)).withNotch(60, 4)
    doAssert sp.response.len == sp.responseHz.len and sp.response.len > 1000,
      "no response: " & $sp.response.len
    let c60 = sp.responseHz.find(60.0)
    doAssert c60 >= 0, "the notch's centre is not on the response's grid"
    doAssert sp.response[c60] < 1e-3, "the notch's depth: " & $sp.response[c60]
    for i, f in sp.responseHz:
      let design = spec.response(f, DtMs)
      if design > 0.01:
        doAssert abs(sp.response[i] - design) <= 0.05 * design,
          "the response at " & $f & " Hz is not the filter's: " & $sp.response[i] & " for " &
          $design
    let plot = st.spectra[w].spectrumPlot(builtinTheme(tmLight))
    doAssert plot.curves.mapIt(it.name)[1 .. 2] == @["raw", "processed"] and
      plot.curves[0].name.startsWith("filter response"),
      "the response is not drawn first, under the data: " & $plot.curves.mapIt(it.name)
    template resp: untyped = plot.curves[0]
    doAssert resp.width < plot.curves[2].width and resp.colour.a < 255 and
      resp.xs == sp.responseHz
    # drawn at its true gain in dB, clamped at the floor only, which its name says
    var below = false
    for i, g in sp.response:
      let d = 20 * log10(g)
      doAssert abs(resp.reads[i] - max(d, -1000.0)) < 1e-9 and
        abs(resp.ys[i] - max(d, FloorDb)) < 1e-9
      if d < FloorDb: below = true
    doAssert below == ("below" in resp.name), resp.name
    # the reading is at a bin; the response's there, at its point nearest it
    let r = plot.readingAt(60.0)
    var j = 0
    for i, f in sp.responseHz:
      if abs(f - r.x) < abs(sp.responseHz[j] - r.x): j = i
    doAssert r.values[0] == resp.reads[j] and r.drawn[0] == resp.ys[j],
      "the reading at " & $r.x & " Hz is not the response's there"
    # linear: a gain of 1 at the larger peak, read in dB all the same
    var linear = st.spectra[w]
    linear.display.scale = ssLinear
    let lp = linear.spectrumPlot(builtinTheme(tmLight))
    let top = max(sp.raw.peakOf, sp.processed.peakOf)
    let k20 = sp.responseHz.find(sp.responseHz[100])
    doAssert abs(lp.curves[0].ys[k20] - sp.response[k20] * top) < 1e-12 and
      abs(lp.curves[0].reads[k20] - 20 * log10(sp.response[k20])) < 1e-9
    linear.display.response = false
    doAssert linear.spectrumPlot(builtinTheme(tmLight)).curves.len == 2
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
    # A 2 Hz notch over the visible time (501 samples, bins of 0.98 Hz): the
    # window follows the plot's filters, with bins of 0.49 Hz.
    st.apply Command(kind: ckSpectrumDisplay, spectrum: st.spectra[w].id,
      spectrumShow: SpectrumDisplay(time: stVisible))
    st.filters Processing(notches: @[NotchFilter(hz: 60, widthHz: 2)])
    doAssert st.spectra[w].waiting and st.answered(w) and
      st.settle(st.spectra[w].spectrum.filters == "notch 60 Hz")
    doAssert st.spectra[w].spectrum.nfft == 1024 and st.spectra[w].spectrum.windowLen == 501,
      "the narrow notch's spectrum is not padded: nfft " & $st.spectra[w].spectrum.nfft
    st.filters Processing()
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
    s.spectrum.live.response = false
    var problems: seq[string]
    let back = readSettings(settingsDocument(s), "settings.nif", Settings(), problems)
    doAssert problems.len == 0, $problems
    doAssert back.hideKilled and back.spectrum == s.spectrum
    doAssert Settings().spectrum.live.time == stVisible and
      Settings().spectrum.window.time == stWhole and not Settings().hideKilled

  block released:
    # The samples kept at hand go once no spectrum window needs them: the
    # last FFT window closed while the live panel is hidden, or the panel
    # hidden with no FFT window open.
    while st.spectra.len > 1: # the windows still open
      st.apply Command(kind: ckCloseSpectrum, spectrum: st.spectra[^1].id)
    let w = st.fft(toSeq(base ..< base + 4))
    doAssert st.answered(w) and st.settle(st.spectrumSamplesHeld > 0)
    st.apply Command(kind: ckCloseSpectrum, spectrum: st.spectra[w].id)
    doAssert st.settle(st.spectrumSamplesHeld == 0),
      "the last FFT window closed, the reader keeps " & $st.spectrumSamplesHeld & " samples"
    discard st.fft(@[base])
    st.apply Command(kind: ckSpectrumPanel, onScreen: true)
    doAssert st.answered(0) and st.answered(st.spectra.high)
    st.apply Command(kind: ckCloseSpectrum, spectrum: st.spectra[^1].id)
    doAssert st.settle(st.spectrumSamplesHeld > 0), "dropped while the live panel is shown"
    st.apply Command(kind: ckSpectrumPanel, onScreen: false)
    doAssert st.settle(st.spectrumSamplesHeld == 0),
      "the live panel hidden, the reader keeps " & $st.spectrumSamplesHeld & " samples"

  st.shutdown()

  block twoPaths:
    # One file opened under two paths (a symbolic link): one set of edits,
    # kept under the first path. A kill made with the link on show is left
    # out of the link's spectra too, in an FFT window and in the live panel.
    let link = fx.dir / "spectrum-link.sgy"
    createSymlink(path, link)
    var two = initAppState()
    two.rememberFilesIn(fx.dir / "config")
    template ready(cond: untyped): bool =
      waitUntil((discard two.drainInbox(); two.persist(); cond))
    for p in [path, link]:
      two.apply Command(kind: ckShowFile, panel: MainPanel, path: p)
      doAssert ready(two.sessions.len >= 1 and two.sessions[^1].path == p and
        two.panel(MainPanel).laidOut and two.remembering(p).known), "not shown: " & p
    let b = two.sessions[^1].base
    two.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[b + 8], on: true)
    doAssert teKilled in two.traceEdits(b + 8), "the kill was not made"
    two.apply Command(kind: ckSpectrum, spectrumOf: MainPanel,
      spectrumTraces: toSeq(b ..< b + SpectrumTraces))
    let w = two.spectra.high
    doAssert ready(not two.spectra[w].waiting and two.spectra[w].spectrum.raw.len > 0)
    doAssert two.spectra[w].spectrum.killed == 1 and two.spectra[w].spectrum.averaged == 8,
      "the link's kill was taken into its spectrum: " & $two.spectra[w].spectrum.killed &
      " killed, " & $two.spectra[w].spectrum.averaged & " averaged"
    two.apply Command(kind: ckSpectrumPanel, onScreen: true)
    doAssert ready(not two.spectra[0].waiting and two.spectra[0].spectrum.raw.len > 0)
    doAssert two.spectra[0].spectrum.killed == 1,
      "the live panel took in the link's kill: " & $two.spectra[0].spectrum.killed & " killed"
    two.shutdown()

  block finishedNotDropped:
    # An answer read and computed whole is posted even when a newer request
    # of its window came meanwhile (the window shows it while it waits for
    # the newer one), and work on it is given up only between blocks. The
    # reader is held in its read (the seam, `faultyfs`) while the newer
    # request comes.
    var three = initAppState()
    three.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert three.settle(three.sessions.len == 1 and three.panel(MainPanel).laidOut and
      three.panel(MainPanel).shown.len == SpectrumTraces)
    three.apply Command(kind: ckView, panel: MainPanel,
      view: fitAll(three.panel(MainPanel).layout, 640, 512))
    doAssert three.settle(three.tiles(0).len > 0)
    let b = three.sessions[0].base
    install()
    fault(path, fkHang, {foMapped})
    three.apply Command(kind: ckSpectrum, spectrumOf: MainPanel,
      spectrumTraces: toSeq(b + 3 .. b + 6))
    let w = three.spectra.high
    doAssert waitUntil(hung() == 1), "the spectrum's read was not held"
    three.apply Command(kind: ckSpectrumDisplay, spectrum: three.spectra[w].id,
      spectrumShow: SpectrumDisplay(time: stVisible)) # a newer request of the window
    let (first, revision) = (three.spectra[w].asked - 1, three.spectra[w].revision)
    release(path)
    doAssert three.settle(not three.spectra[w].waiting and
      three.spectra[w].spectrum.gen == three.spectra[w].asked)
    doAssert three.spectra[w].revision == revision + 2,
      "the first answer, read and computed whole, was dropped for the newer request (" &
      $(three.spectra[w].revision - revision) & " answer taken; request " & $first & ")"
    doAssert uiCalls().len == 0, "the file system was called on the UI thread: " & $uiCalls()
    three.shutdown()

  block keptServing:
    # A request already served `KeepServing` is finished when a newer one
    # of its window comes, between chunks too: a window asked faster than
    # it is answered (the live panel following a pan) still shows answers.
    # Its first chunk's read is held, a newer request comes, then the read
    # goes on with the reader's clock moved on 200 ms (`fkSlow`).
    doAssert givesUp(initDuration(milliseconds = 10), true, false, false) and
      not givesUp(KeepServing, true, false, false) and
      givesUp(KeepServing, false, true, false) and not givesUp(initDuration(), false, false, false)
    let long = fx.longSpreadSegy()
    var six = initAppState()
    six.apply Command(kind: ckShowFile, panel: MainPanel, path: long)
    doAssert six.settle(six.sessions.len == 1 and six.panel(MainPanel).laidOut)
    let b = six.sessions[0].base
    fault(long, fkHang, {foMapped})
    six.apply Command(kind: ckSpectrum, spectrumOf: MainPanel,
      spectrumTraces: toSeq(b ..< b + LongSpread))
    let w = six.spectra.high
    doAssert waitUntil(hung() == 1), "the spectrum's read was not held"
    six.apply Command(kind: ckSpectrumDisplay, spectrum: six.spectra[w].id,
      spectrumShow: SpectrumDisplay(time: stVisible)) # a newer request of the window
    let revision = six.spectra[w].revision
    fault(long, fkSlow, {foMapped}, delay = initDuration(milliseconds = 200))
    doAssert six.settle(not six.spectra[w].waiting and
      six.spectra[w].spectrum.gen == six.spectra[w].asked)
    doAssert six.spectra[w].revision == revision + 2,
      "the request served 200 ms was given up for the newer one (" &
      $(six.spectra[w].revision - revision) & " answer taken)"
    release(long)
    six.shutdown()

  block auxiliary:
    # The filters reach an auxiliary trace only with the plot's Aux toggle
    # on: with it off, the processed curve is of the seismic traces alone
    # (and there is none of a pilot alone), and the words say so.
    let notch = Processing(notches: @[NotchFilter(hz: 60, widthHz: 4)])
    var four = initAppState()
    template ready(cond: untyped): bool =
      waitUntil((discard four.drainInbox(); cond))
    proc answer(st: var AppState; traces: seq[int]): int =
      st.apply Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: traces)
      result = st.spectra.high
      let w = result
      doAssert waitUntil((discard st.drainInbox(); not st.spectra[w].waiting and
        st.spectra[w].spectrum.raw.len > 0))
    four.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.spectrumAuxSegy())
    doAssert ready(four.sessions.len == 1 and four.panel(MainPanel).laidOut)
    let b = four.sessions[0].base
    four.filters notch
    let w = four.answer(toSeq(b ..< b + 5))
    template sp: untyped = four.spectra[w].spectrum
    doAssert sp.averaged == 5 and sp.filtered == 4 and sp.passedBy == 1,
      "the auxiliary trace counted as processed: " & $(sp.averaged, sp.filtered, sp.passedBy)
    doAssert four.spectra[w].filterText == "processed: notch 60 Hz, 4 of the 5 traces (the " &
      "auxiliary trace is not filtered: Filters > Filter the Aux traces too is off)",
      four.spectra[w].filterText
    doAssert four.spectra[w].spectrumPlot(builtinTheme(tmLight)).curves.mapIt(it.name) ==
      @["filter response", "raw", "processed (4 of 5)"], "the legend does not say of which"
    # its processed curve is the seismic traces' alone: an FFT window of them
    let v = four.answer(toSeq(b ..< b + 4))
    template seismic: untyped = four.spectra[v].spectrum
    doAssert seismic.filtered == 4 and seismic.passedBy == 0 and
      four.spectra[v].filterText == "processed: notch 60 Hz"
    for k in 0 ..< sp.processed.len:
      doAssert abs(sp.processed[k] - seismic.processed[k]) <= 1e-6 * max(1.0, seismic.raw[k]),
        "the unfiltered auxiliary trace is in the processed curve at bin " & $k
    # The Aux toggle ticked on the plot: the open FFT windows follow, all
    # five through the filters now, from the samples at hand.
    var withAux = notch
    withAux.aux = true
    let asks = four.spectra[w].asks
    four.filters withAux
    doAssert four.spectra[w].asks == asks + 1, "the FFT window did not follow the plot's filters"
    doAssert ready(not four.spectra[w].waiting and sp.filterAux)
    doAssert sp.filtered == 5 and sp.passedBy == 0 and sp.read == 0 and
      four.spectra[w].filterText == "processed: notch 60 Hz",
      $(sp.filtered, sp.passedBy, sp.read) & " " & four.spectra[w].filterText
    doAssert four.spectra[w].filters == "notch 60 Hz" and four.spectra[w].processing == withAux
    # The plot's reach counts the traces it shows: the four seismic ones
    # killed and hidden, the auxiliary one is all it shows, and the filters
    # (Aux off) reach none of them.
    var hide = four.settings
    hide.hideKilled = true
    four.apply Command(kind: ckSettings, settings: hide)
    four.apply Command(kind: ckFilter, panel: MainPanel,
      filter: TraceFilter(seismic: true, auxiliary: true))
    four.filters notch
    four.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
      edited: toSeq(b ..< b + 4), on: true)
    doAssert ready(four.panel(MainPanel).laidOut and four.panel(MainPanel).shown == @[4])
    doAssert four.filterReach(four.panel(MainPanel)) == frNoTrace,
      "the hidden killed traces counted as shown: " & $four.filterReach(four.panel(MainPanel))
    four.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
      edited: toSeq(b ..< b + 4), on: false)
    doAssert ready(four.panel(MainPanel).shown.len == 5)
    doAssert four.filterReach(four.panel(MainPanel)) == frSeismic
    four.filters withAux
    doAssert ready(not four.spectra[w].waiting and sp.filterAux and sp.killed == 0)
    # Frozen, it keeps the filters it went through; the other follows.
    let fid = four.spectra[w].id
    four.apply Command(kind: ckSpectrumDisplay, spectrum: fid, frozen: true,
      spectrumShow: four.spectra[w].display)
    doAssert four.spectra[w].frozen
    var fifty = withAux
    fifty.notches[0].hz = 50
    let frozenAsks = four.spectra[w].asks
    four.filters fifty
    doAssert four.spectra[w].asks == frozenAsks, "the frozen FFT window asked again"
    doAssert ready(not four.spectra[v].waiting and seismic.filters == "notch 50 Hz")
    doAssert sp.filters == "notch 60 Hz"
    # Unfrozen, it follows again.
    four.apply Command(kind: ckSpectrumDisplay, spectrum: fid, frozen: false,
      spectrumShow: four.spectra[w].display)
    doAssert four.spectra[w].asks == frozenAsks + 1 and not four.spectra[w].frozen
    doAssert ready(not four.spectra[w].waiting and sp.filters == "notch 50 Hz")
    four.shutdown()
    # A pilot alone with the toggle off: no processed curve, and why.
    var five = initAppState()
    five.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.pilotSegy())
    doAssert waitUntil((discard five.drainInbox(); five.sessions.len == 1 and
      five.panel(MainPanel).laidOut))
    five.apply Command(kind: ckFilter, panel: MainPanel,
      filter: TraceFilter(seismic: true, auxiliary: true))
    five.filters notch
    let p = five.answer(@[five.sessions[0].base])
    template pilot: untyped = five.spectra[p]
    doAssert pilot.spectrum.processed.len == 0 and pilot.spectrum.filtered == 0 and
      pilot.spectrum.passedBy == 1 and pilot.spectrum.processedPhase.len == 0,
      "a pilot the filters passed by has a processed curve: " & $pilot.spectrum.filtered
    doAssert pilot.filterText == "not processed: the auxiliary trace is not filtered: " &
      "Filters > Filter the Aux traces too is off (the plot's filters: notch 60 Hz)",
      pilot.filterText
    doAssert pilot.auxUnfiltered
    doAssert pilot.spectrumPlot(builtinTheme(tmLight)).curves.mapIt(it.name) ==
      @["raw"], "a response the filters did not apply is drawn"
    doAssert not pilot.spectrum.hasResponse and pilot.spectrum.response.len > 0
    # A notch above Nyquist alone: no filter can run at this interval, said.
    five.filters Processing(aux: true, notches: @[NotchFilter(hz: 300, widthHz: 4)])
    let q = five.answer(@[five.sessions[0].base])
    template above: untyped = five.spectra[q].spectrum
    doAssert above.processed.len == 0 and above.filterProblem == "none of them is below Nyquist" and
      above.filterNote == "Nyquist is 250 Hz at 2 ms: a notch is not below Nyquist and left out.",
      above.filterNote
    doAssert five.spectra[q].filterText == "not processed: the plot's filters (notch 300 Hz) " &
      "cannot run: none of them is below Nyquist. Nyquist is 250 Hz at 2 ms: a notch is not " &
      "below Nyquist and left out.", five.spectra[q].filterText
    five.shutdown()
  doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
echo "tspectra: ok"
