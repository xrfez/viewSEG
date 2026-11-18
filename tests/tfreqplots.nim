## The frequency-domain plots: what is drawn, and what they say.
##
## Seen to fail: with the decimation keeping only the sample of largest magnitude
## (the old `peakBins`), "tone is drawn at 0 dB" saw -17 dB, "narrow line" saw a level
## near the noise, and "deep notch" saw no notch.

import std/[math, strutils]
import viewSEG/core/[spectra]
import viewSEG/view/[curveplot, spectrumview, theme]

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

  echo "tfreqplots: ok"

when isMainModule:
  main()
