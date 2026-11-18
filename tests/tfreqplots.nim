## The frequency-domain plots: what is drawn, and what they say.
##
## Seen to fail: with the decimation keeping only the sample of largest magnitude
## (the old `peakBins`), "tone is drawn at 0 dB" saw -17 dB, "narrow line" saw a level
## near the noise, and "deep notch" saw no notch.

import std/[math, os, strutils]
import viewSEG/core/[analysis, fkanalysis, panels, processing, spectra, state, viewport]
import viewSEG/view/[curveplot, spectrumview, theme]
import viewSEG/view/analysisview
import utils/[fixtures, waiting]

proc answered(st: var AppState; w: int): bool =
  st.plots[w].result.problem.len > 0 or st.plots[w].result.image.values.len > 0

proc peakK(img: AnalysisImage): float64 =
  ## The wavenumber of the largest cell.
  var (bc, br) = (0, 0)
  for c in 0 ..< img.cols:
    for r in 0 ..< img.rows:
      if img.valueAt(c, r) > img.valueAt(bc, br): (bc, br) = (c, r)
  img.xOf(bc)

proc open(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
    st.panel(MainPanel).shown.len > 0)
  let lay = st.panel(MainPanel).layout
  st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 640, 512))
  doAssert st.settle(st.tiles(0).len > 0)

proc fft(st: var AppState; traces: seq[int]; show = SpectrumDisplay()): int =
  ## Opens an FFT window of `traces` (survey-wide); its index in `spectra`.
  st.apply Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: traces,
    spectrumShow: show)
  result = st.spectra.high
  doAssert st.settle(not st.spectra[result].waiting and st.spectra[result].spectrum.raw.len > 0)

proc bumpy(bins: int; at: int; level: float64): SpectrumWindow =
  ## A window whose raw spectrum is `level` at bin `at` over a floor of 0.001.
  result = SpectrumWindow(id: 1)
  result.spectrum.binHz = 0.5
  result.spectrum.raw = newSeq[float64](bins)
  for k in 0 ..< bins: result.spectrum.raw[k] = 0.001 + 0.0001 * float64(k mod 7)
  result.spectrum.raw[at] = level
  result.spectrum.dtMs = 1.0

proc drawnMax(w: SpectrumWindow; px: int): float64 =
  let plot = spectrumPlot(w, EverforestDark)
  let drawn = plot.forScreen(plot.xs[0], plot.xs[^1], px)
  result = -1e300
  for y in drawn[0].ys:
    if not y.isNaN: result = max(result, y)

proc main*() =
  block toneIsDrawnAtZeroDb:
    var w = bumpy(513, 100, 3.0)
    w.display.scale = ssDb
    doAssert abs(w.drawnMax(470)) < 1e-9, "tone is drawn at " & $w.drawnMax(470)

  block narrowLineAmongManyBins:
    var w = bumpy(16385, 7001, 1.0)
    w.display.scale = ssDb
    doAssert abs(w.drawnMax(480)) < 1e-9, "narrow line drawn at " & $w.drawnMax(480)
    w.display.scale = ssLinear
    doAssert abs(w.drawnMax(480) - 1.0) < 1e-9

  block deepNotchIsDrawn:
    var w = SpectrumWindow(id: 1)
    w.spectrum.binHz = 0.5
    w.spectrum.raw = newSeq[float64](4000)
    for k in 0 ..< 4000: w.spectrum.raw[k] = 1.0
    w.spectrum.raw[2345] = 1e-5
    w.display.scale = ssDb
    let plot = spectrumPlot(w, EverforestDark)
    let drawn = plot.forScreen(plot.xs[0], plot.xs[^1], 400)
    var low = 0.0
    for y in drawn[0].ys:
      if not y.isNaN: low = min(low, y)
    doAssert low < -99, "the notch is drawn at " & $low
    doAssert drawn[0].ys.len <= 400 + 2, "drew " & $drawn[0].ys.len

  block narrowNotchIsWarnedOf:
    # 2000 samples at 2 ms: 4 s, so 1/T is 0.25 Hz
    doAssert "narrower than 1/T, 0.25" in narrowNotchWarning(0.2, 2000, 2.0),
      narrowNotchWarning(0.2, 2000, 2.0)
    doAssert narrowNotchWarning(0.25, 2000, 2.0) == ""
    doAssert narrowNotchWarning(2.0, 2000, 2.0) == ""
    doAssert narrowNotchWarning(0.1, 0, 2.0) == "", "no record length known"

  block degreesToATenth:
    doAssert yText(-7207.04, "°") == "-7207.0" and yText(-7207.04, "deg") == "-7207.0"
    doAssert yText(12.345, "dB") == "12.3"

  block meanIsRemoved:
    # DC 3 + 25 Hz tone, 2000 x 2 ms: the tone is the peak, not the direct current.
    var x = newSeq[float32](2000)
    for i in 0 ..< x.len: x[i] = float32(3 + 2 * cos(2 * PI * 25 * float64(i) * 0.002))
    let sg = spectrogramOf([x], 2.0, 0, AnalysisParams())
    let img = sg.image
    let mid = img.cols div 2
    doAssert img.valueAt(mid, 0) < -40, "0 Hz row of a middle frame: " & $img.valueAt(mid, 0)
    doAssert "mean removed" in sg.note, sg.note
    # Phase spectrum: DC 5 + a cosine on 97.66 Hz (1000 x 2 ms).
    var y = newSeq[float32](1000)
    for i in 0 ..< y.len: y[i] = float32(5 + cos(2 * PI * 97.65625 * float64(i) * 0.002))
    let ph = phaseOf(y, "y", 2.0, AnalysisParams(phaseWithinDb: 40))
    let db = ph.plots[0].curves[0].ys
    var top = 0
    for k in 0 ..< db.len:
      if db[k] > db[top]: top = k
    doAssert abs(ph.plots[0].xs[top] - 97.65625) < 1.5, "the peak is at " & $ph.plots[0].xs[top]
    doAssert db[0] < -30, "the direct current reads " & $db[0] & " dB"
    doAssert "mean removed" in ph.note, ph.note
    # f-k: DC 4 + a dipping 30 Hz event on 8 traces, 25 m apart.
    var rows: seq[seq[float32]]
    for i in 0 ..< 8:
      var r = newSeq[float32](500)
      for j in 0 ..< 500:
        r[j] = float32(4 + cos(2 * PI * 30.0 * (float64(j) * 0.002 - float64(i) * 0.0125)))
      rows.add r
    let fk = fkOf(rows, 25.0, "offsets", suMetres, 2.0, 0, AnalysisParams())
    var best = -1000.0'f32
    var bestRow = 0
    for c in 0 ..< fk.image.cols:
      for r in 0 ..< fk.image.rows:
        if fk.image.valueAt(c, r) > best: (best, bestRow) = (fk.image.valueAt(c, r), r)
    doAssert abs(fk.image.yOf(bestRow) - 30) < 2 * fk.image.dy, "f-k peaks at " &
      $fk.image.yOf(bestRow) & " Hz"
    doAssert "mean removed" in fk.note, fk.note

  withFixtures fx:
    block lateArrivalPhase:
      var spike = newSeq[float32](1000)
      spike[700] = 1 # 1400 ms at 2 ms
      let path = fx.tracesSegy("spike.sgy", [spike])
      var st = initAppState()
      st.open(path)
      let base = st.sessions[0].base
      for picture in [ppUnwrapped, ppDelayRemoved]:
        let w = st.fft(@[base], SpectrumDisplay(phase: true, phasePicture: picture))
        let sw = st.spectra[w]
        let plot = sw.phasePlot(EverforestDark)
        let ys = plot.curves[0].ys
        if picture == ppUnwrapped:
          let k = int(round(100.0 / sw.spectrum.binHz))
          let want = -360.0 * 1.4 * float64(k) * sw.spectrum.binHz
          doAssert abs(ys[k] - want) < 5, "unwrapped at " & $(float64(k) * sw.spectrum.binHz) &
            " Hz: " & $ys[k] & ", want " & $want
        else:
          doAssert "delay 1400.0 ms" in plot.aside or "delay 1399.9" in plot.aside or
            "delay 1400.1" in plot.aside, "the delay: " & plot.aside

    block fkOrderIsTheShownOrder:
      # A dipping 30 Hz event (12.5 ms a trace) on 8 traces 25 m apart, channel 1 .. 8.
      var dip: seq[seq[float32]]
      var offsets: seq[float64]
      for i in 0 ..< 8:
        var r = newSeq[float32](500)
        for j in 0 ..< 500:
          r[j] = float32(cos(2 * PI * 30.0 * (float64(j) * 0.002 - float64(i) * 0.0125)))
        dip.add r
        offsets.add 25.0 * float64(i)
      let path = fx.tracesSegy("dip.sgy", dip, offsets = offsets)
      let byChannel = @[SortKey(field: hfChannel, descending: true)]
      let ascending = @[SortKey(field: hfChannel)]
      var readings: seq[(float64, seq[int])]
      for openFirst in [true, false]:
        var st = initAppState()
        st.open(path)
        let base = st.sessions[0].base
        let ids = @[base, base + 1, base + 2, base + 3, base + 4, base + 5, base + 6, base + 7]
        if openFirst:
          st.apply Command(kind: ckOpenPlot, plotView: avFk, plotTraces: ids)
          doAssert st.settle(st.answered(0))
        st.apply Command(kind: ckSort, panel: MainPanel, order: byChannel)
        doAssert st.settle(st.panel(MainPanel).shown.len == 8 and
          st.panel(MainPanel).shown[0] == 7)
        if not openFirst:
          st.apply Command(kind: ckOpenPlot, plotView: avFk, plotTraces: ids)
        doAssert st.settle(st.plots.len == 1 and st.plots[0].result.image.values.len > 0 and
          st.plots[0].traces[0] == base + 7 and not st.plots[0].waiting and
          st.plots[0].result.gen >= st.plots[0].asked)
        var shown: seq[int]
        for t in st.panel(MainPanel).shown: shown.add t + base
        doAssert st.plots[0].traces == shown, "the f-k's rows: " & $st.plots[0].traces
        readings.add (st.plots[0].result.image.peakK, st.plots[0].traces)
      doAssert readings[0][1] == readings[1][1], "the rows differ with the order of events"
      doAssert abs(abs(readings[0][0]) - 0.375) < 0.1, "k of the event (cycles per trace): " &
          $readings[0][0]
      doAssert readings[0][0] * readings[1][0] > 0,
        "the sign of k: " & $readings[0][0] & " then " & $readings[1][0]

    block visibleTimeIsThePlots:
      # The Seismic plot draws every trace from the first seismic trace's start time (one
      # time axis per panel), so trace 2, which starts 500 ms later, shows its first
      # samples at 0 ms. The visible time of an FFT window cuts what the plot shows.
      var rows: seq[seq[float32]]
      for i in 0 ..< 2:
        var r = newSeq[float32](1000)
        for j in 0 ..< 1000: r[j] = float32(cos(2 * PI * 25.0 * float64(j) * 0.002))
        rows.add r
      let path = fx.tracesSegy("delays.sgy", rows, t0Ms = [0.0, 500.0])
      var st = initAppState()
      st.open(path)
      let base = st.sessions[0].base
      var v = st.panel(MainPanel).view
      v.timeMs = Span(lo: 300, hi: 400)
      st.apply Command(kind: ckView, panel: MainPanel, view: v)
      let w = st.fft(@[base + 1], SpectrumDisplay(time: stVisible))
      let sp = st.spectra[w].spectrum
      doAssert sp.problem == "" and sp.fromMs == 300 and sp.toMs == 400 and sp.windowLen == 51,
        "trace 2 over 300 to 400 ms: " & sp.problem & " " & $sp.fromMs & " " & $sp.windowLen

    block frozenWindowKeepsItsAxis:
      # File A starts at 100 ms and holds a tone only in samples 100 to 150 (300 to 400 ms
      # on the plot's axis); file B starts at 0. A window frozen on A over 300 to 400 ms,
      # the plot then moved to B, still reads A's tone when it asks again.
      var tone = newSeq[float32](1000)
      for j in 100 .. 150: tone[j] = float32(cos(2 * PI * 25.0 * float64(j) * 0.002))
      let pathA = fx.tracesSegy("axis-a.sgy", [tone], t0Ms = [100.0])
      let pathB = fx.tracesSegy("axis-b.sgy", [newSeq[float32](1000)])
      var st = initAppState()
      st.open(pathA)
      let base = st.sessions[0].base
      var v = st.panel(MainPanel).view
      v.timeMs = Span(lo: 300, hi: 400)
      st.apply Command(kind: ckView, panel: MainPanel, view: v)
      let w = st.fft(@[base], SpectrumDisplay(time: stVisible))
      st.apply Command(kind: ckSpectrumDisplay, spectrum: st.spectra[w].id,
        spectrumShow: st.spectra[w].display, frozen: true)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: pathB)
      doAssert st.settle(st.sessions.len == 2 and st.panel(MainPanel).laidOut and
        st.panel(MainPanel).layout.t0Ms == 0)
      for time in [stWhole, stVisible]:
        var d = st.spectra[w].display
        d.time = time
        st.apply Command(kind: ckSpectrumDisplay, spectrum: st.spectra[w].id, spectrumShow: d,
          frozen: true)
        doAssert st.settle(not st.spectra[w].waiting and st.spectra[w].spectrum.raw.len > 0)
      var top = 0.0
      for a in st.spectra[w].spectrum.raw: top = max(top, a)
      doAssert top > 0.3, "the frozen window cut the wrong time: peak " & $top

    block notANumberIsLeftOut:
      # 8 traces of a 25 Hz cosine, trace 3 with one NaN: the New plot windows leave it
      # out and say so (as the FFT window does), rather than draw the NaN as 0.
      var rows: seq[seq[float32]]
      for i in 0 ..< 8:
        var r = newSeq[float32](500)
        for j in 0 ..< 500: r[j] = float32(cos(2 * PI * 25.0 * float64(j) * 0.002))
        rows.add r
      rows[3][200] = NaN
      var spread: seq[float64]
      for i in 0 ..< 8: spread.add 25.0 * float64(i)
      let path = fx.tracesSegy("nan.sgy", rows, offsets = spread)
      var st = initAppState()
      st.open(path)
      let base = st.sessions[0].base
      let ids = @[base, base + 1, base + 2, base + 3, base + 4, base + 5, base + 6, base + 7]
      for view in [avSpectrogram, avFk]:
        let fk = view == avFk
        st.apply Command(kind: ckOpenPlot, plotView: view, plotTraces: ids)
        let w = st.plots.high
        doAssert st.settle(st.answered(w) and not st.plots[w].waiting)
        let r = st.plots[w].result
        doAssert r.problem == "", r.problem
        if fk:
          # the row stays as zeros, so the spacing and units are as for a clean record
          doAssert r.used == 8 and r.leftOut == 0 and r.zeroed == 1, "f-k: used " & $r.used &
            ", left out " & $r.leftOut & ", zeroed " & $r.zeroed
          doAssert "taken as zeros" in r.note and "not regular" notin r.note, r.note
        else:
          doAssert r.used == 7 and r.leftOut == 1 and r.notNumber == 1,
            $view & ": used " & $r.used & ", left out " & $r.leftOut
      # a Phase spectrum of the bad trace alone has nothing to use
      st.apply Command(kind: ckOpenPlot, plotView: avPhase, plotTraces: @[base + 3])
      let w = st.plots.high
      doAssert st.settle(st.answered(w) and not st.plots[w].waiting)
      doAssert st.plots[w].result.leftOut == 1 and
        "not a number" in st.plots[w].result.problem, st.plots[w].result.problem

  echo "tfreqplots: ok"

when isMainModule:
  main()
