## What a spectrum window draws (`core/spectra`): its curves as a
## `CurvePlot`, amplitude against frequency from 0 Hz to Nyquist, in dB
## (0 dB at the larger peak of the raw and processed curves, so the two
## compare) or linear, and over them the filters' own response, its gain
## 1 at that 0 dB (at the larger peak, linear), so a notch shows at its
## true depth whatever the data; and its lines of words: what it is of,
## what was left out, over which time.

import std/[math, strutils]
import ../core/[orientation, spectra]
import curveplot, theme

const
  FloorDb* = -120.0 ## the lowest level a dB plot shows

func curveColours*(t: Theme): array[3, Rgba] =
  ## The raw curve's colour, the processed one's and the filters'
  ## response's: the theme's dimmed text, its accent, so the filtered curve
  ## stands out, and its second series colour (distinct from the accent,
  ## `deriveSeries`), so the response is told from the processed curve it
  ## runs along.
  [t.roles[rlTextDim], t.roles[rlAccent], t.series[1]]

func responseName*(sp: Spectrum): string =
  ## The response curve's name in the legend: "filter response", and
  ## "(not applied)" when the filters reached none of the traces.
  if sp.filtered > 0: "filter response" else: "filter response (not applied)"

func spectrumPlot*(w: SpectrumWindow; t: Theme; along = saX): CurvePlot =
  ## Window `w`'s curves, as its display asks: the raw one, the processed
  ## one (when the plot has filters), in dB or linear, the frequency axis
  ## linear or logarithmic.
  template sp: untyped = w.spectrum
  let db = w.display.scale == ssDb
  result = CurvePlot(xLabel: "Frequency (Hz)", xUnit: "Hz",
    yLabel: (if db: "Amplitude (dB)" else: "Amplitude"), yUnit: (if db: "dB" else: ""),
    logX: w.display.logFrequency, along: along, yFloor: (if db: FloorDb else: NaN))
  if sp.raw.len == 0:
    result.note = if sp.problem.len > 0: "No spectrum: " & sp.problem & "."
                  elif w.waiting: "Computing the spectrum..."
                  elif w.traces.len == 0: "No trace to show the spectrum of."
                  else: ""
    return
  result.xs = newSeq[float64](sp.raw.len)
  for k in 0 ..< sp.raw.len: result.xs[k] = float64(k) * sp.binHz
  let reference = max(sp.raw.peakOf, sp.processed.peakOf)
  let colours = curveColours(t)
  template add(called: string; amps: seq[float64]; ink: Rgba) =
    result.curves.add Curve(name: called, colour: ink,
      ys: (if db: dbOf(amps, reference, FloorDb) else: amps))
  if w.display.raw: add("raw", sp.raw, colours[0])
  if w.display.processed and sp.processed.len > 0:
    # Of fewer traces than the raw curve when the filters passed some by:
    # the legend says so, as the two then differ by those traces too.
    let called = if sp.passedBy > 0: "processed (" & $sp.filtered & " of " & $sp.averaged & ")"
                 else: "processed"
    add(called, sp.processed, colours[1])
  if w.display.response and sp.response.len == sp.raw.len:
    # Its gain in dB, 0 dB at the top of the curves; linear, a gain of 1 at
    # the larger peak. The readout says the gain in dB either way.
    let gainDb = dbOf(sp.response, 1.0, FloorDb)
    var ys = gainDb
    if not db:
      for k in 0 ..< ys.len: ys[k] = sp.response[k] * reference
    result.curves.add Curve(name: sp.responseName, colour: colours[2], ys: ys,
      reads: gainDb, unit: "dB")
  if result.curves.len == 0: result.note = "The curves are hidden: tick Raw, Processed or Response."

func hasPhase*(w: SpectrumWindow): bool {.inline.} =
  ## Whether `w` has a phase to draw: a spectrum of one trace.
  w.spectrum.rawPhase.len > 0

func phasePlot*(w: SpectrumWindow; t: Theme; along = saX): CurvePlot =
  ## A one-trace window's phase, in degrees against frequency, its raw and
  ## processed curves as its amplitude plot draws them.
  template sp: untyped = w.spectrum
  result = CurvePlot(xLabel: "Frequency (Hz)", xUnit: "Hz", yLabel: "Phase (degrees)",
    yUnit: "deg", logX: w.display.logFrequency, along: along)
  if not w.hasPhase: return
  result.xs = newSeq[float64](sp.rawPhase.len)
  for k in 0 ..< sp.rawPhase.len: result.xs[k] = float64(k) * sp.binHz
  let colours = curveColours(t)
  if w.display.raw: result.curves.add Curve(name: "raw", colour: colours[0], ys: sp.rawPhase)
  if w.display.processed and sp.processedPhase.len > 0:
    result.curves.add Curve(name: "processed", colour: colours[1], ys: sp.processedPhase)

func timeText(sp: Spectrum): string =
  if sp.fromMs.isNaN: "" else: valueText(sp.fromMs) & " to " & valueText(sp.toMs) & " ms"

func summaryText*(w: SpectrumWindow): string =
  ## What the spectrum is of, in a line: "12 traces averaged (2 killed
  ## left out) · 0 to 3998 ms · 2 ms, Nyquist 250 Hz"; while it is computed,
  ## or when there is none, why.
  template sp: untyped = w.spectrum
  if sp.raw.len == 0:
    return if sp.problem.len > 0: "No spectrum: " & sp.problem
           elif w.waiting: "Computing..."
           else: "Nothing to show"
  result = if sp.averaged == 1: "1 trace" else: $sp.averaged & " traces averaged"
  var left: seq[string]
  if sp.killed > 0: left.add $sp.killed & " killed"
  if sp.dead > 0: left.add $sp.dead & " dead"
  if sp.failed > 0: left.add $sp.failed & " unreadable or empty"
  if sp.atOtherInterval > 0: left.add $sp.atOtherInterval & " at another interval"
  if left.len > 0: result.add " (" & left.join(", ") & " left out)"
  if w.chosenCount > w.traces.len:
    result.add ", spread evenly over the " & $w.chosenCount & " " &
      (if w.chosen == soVisible: "in view" else: "selected")
  result.add " · " & timeText(sp)
  result.add " · " & valueText(sp.dtMs) & " ms, Nyquist " & valueText(500 / sp.dtMs) & " Hz"
  if w.display.scale == ssDb:
    # Each window has a 0 dB of its own: which amplitude it is, so that two
    # windows (two records, two times) compare.
    let (raw, processed) = (sp.raw.peakOf, sp.processed.peakOf)
    if max(raw, processed) > 0:
      result.add " · 0 dB = amplitude " & valueText(max(raw, processed)) &
        (if processed > raw: " (processed peak)" else: " (raw peak)")
    else: result.add " · every amplitude is 0"
  if w.waiting: result.add " · updating..."
