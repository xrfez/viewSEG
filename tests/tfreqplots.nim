## The frequency-domain plots: what is drawn, and what they say.
##
## Seen to fail: with the decimation keeping only the sample of largest magnitude
## (the old `peakBins`), "tone is drawn at 0 dB" saw -17 dB, "narrow line" saw a level
## near the noise, and "deep notch" saw no notch.

import std/[math, os, strutils]
import viewSEG/core/[spectra, state]
import viewSEG/view/[curveplot, spectrumview, theme]
import utils/[fixtures, waiting]

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

  echo "tfreqplots: ok"

when isMainModule:
  main()
