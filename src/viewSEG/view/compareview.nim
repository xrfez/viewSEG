## What the compare window draws: the two traces, their spectra, the phase
## of B minus A, and the correlation, as curve plots. Colours are the
## theme's: A is the accent, B the second series colour, and both are used
## for every curve of that slot.

import std/math
import ../core/compare
import curveplot, theme

const
  FloorDb = -120.0

func inkA*(t: Theme): Rgba {.inline.} = t.roles[rlAccent]

func inkB*(t: Theme): Rgba {.inline.} = t.series[1]

proc curve(name: string; colour: Rgba; xs, ys: seq[float64]): Curve =
  ## The series whole. The plot keeps the peak of each bin of the range on
  ## screen (`CurvePlot.forScreen`) and redoes that when the view changes,
  ## so a zoom reaches single samples. Nothing is thrown away here.
  Curve(name: name, colour: colour, xs: xs, ys: ys)

func spanOf(a, b: CompareSeries): seq[float64] =
  ## Two points covering both curves, so the axis fits them.
  var lo = Inf
  var hi = -Inf
  for s in [a, b]:
    for x in s.xs:
      if x.classify notin {fcNan, fcInf, fcNegInf}:
        lo = min(lo, x)
        hi = max(hi, x)
  if lo > hi: return
  if hi <= lo: hi = lo + 1
  @[lo, hi]

func signalPlot*(p: ComparePicture; t: Theme): CurvePlot =
  ## Both traces on one time axis, and the difference when it was asked for.
  result = CurvePlot(xLabel: "Time (ms)", xUnit: "ms", yLabel: "Amplitude",
    yUnit: "", xs: spanOf(p.signalA, p.signalB))
  if p.signalA.ys.len > 0:
    result.curves.add curve("A", inkA(t), p.signalA.xs, p.signalA.ys)
  if p.signalB.ys.len > 0:
    result.curves.add curve("B", inkB(t), p.signalB.xs, p.signalB.ys)
  if p.difference.ys.len > 0:
    result.curves.add curve("B − A", t.roles[rlTextDim], p.difference.xs, p.difference.ys)
  if result.curves.len == 0:
    result.note = if p.note.len > 0: p.note else: "No samples in the window."

func spectrumPlot*(p: ComparePicture; t: Theme): CurvePlot =
  ## Both amplitude spectra, dB, up to the lower Nyquist.
  result = CurvePlot(xLabel: "Frequency (Hz)", xUnit: "Hz", yLabel: "Amplitude (dB)",
    yUnit: "dB", yFloor: FloorDb, xs: spanOf(p.specA, p.specB))
  if p.specA.ys.len > 0:
    result.curves.add curve("A", inkA(t), p.specA.xs, p.specA.ys)
  if p.specB.ys.len > 0:
    result.curves.add curve("B", inkB(t), p.specB.xs, p.specB.ys)
  if result.curves.len == 0:
    result.note = "No spectrum."

func phasePlot*(p: ComparePicture; t: Theme): CurvePlot =
  ## Phase of B minus A, in the picture the FFT window uses.
  var ys = p.phase.ys
  let mag = p.phasePicture == ppMagnitude
  result = CurvePlot(xLabel: "Frequency (Hz)", xUnit: "Hz",
    yLabel: "Phase of B − A (degrees)", yUnit: "°", xs: p.phase.xs,
    yFloor: if mag: 0.0 else: NaN, yCeil: if mag: 180.0 else: NaN)
  if p.phase.xs.len == 0:
    result.xs = @[0.0, 1.0]
  if ys.len > 0:
    var c = curve("B − A", inkB(t), p.phase.xs, ys)
    c.brackets = p.phaseSigned
    result.curves.add c
  else:
    result.note = "No phase."
  if not p.delayMs.isNaN: result.aside = delayWords(p.delayMs)

func correlationPlot*(p: ComparePicture; t: Theme): CurvePlot =
  ## The correlation of A with B, before a time shift is applied.
  result = CurvePlot(xLabel: "Lag (ms)", xUnit: "ms", yLabel: "Correlation",
    yUnit: "", xs: p.correlation.xs)
  if p.correlation.ys.len > 0:
    result.curves.add curve("A with B", t.series[2], p.correlation.xs, p.correlation.ys)
  else:
    result.note = if p.table.whyNot.len > 0: p.table.whyNot
                  elif p.refusal.len > 0: p.refusal
                  else: "No correlation."
