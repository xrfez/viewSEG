## A reversed trace is reversed in every graph, with no option to leave it
## out (`samples/land/shots.sgy`, `samples/vib/vib_uncorrelated.sgd`):
##
## - reversing one trace moves that trace's phase spectrum and instantaneous
##   phase by 180 degrees, turns its correlation peak into a trough of the
##   same size, and leaves the amplitude spectrum, the envelope, the
##   spectrogram and the neighbours alone;
## - a reversed reference flips every trace's coefficient, in this file or
##   another;
## - the window names it ("Trace 2: reversed", "N traces are reversed",
##   "reference, Trace N: reversed");
## - an open window that is not frozen asks again when a shown trace's
##   reversal, or the reference's, is set, cleared or undone; a frozen one
##   does not;
## - the map's amplitude flags are unchanged.
##
## Seen to fail: with the sign flip left out of `filtered`, the spectrum
## reader's raw curve and `applyOwnQc` (the samples used as read), "the phase
## spectrum did not move 180 degrees".

import std/[math, os, strutils]
import viewSEG/core/[analysis, processing, state]
import utils/waiting

const root = currentSourcePath().parentDir.parentDir
let land = root / "samples" / "land" / "shots.sgy"
let vib = root / "samples" / "vib" / "vib_uncorrelated.sgd"
let vibOther = root / "samples" / "vib" / "vib_correlated.sgd"

proc angDiff(a, b: float64): float64 =
  var d = a - b
  while d > 180: d -= 360
  while d <= -180: d += 360
  d

proc shifted180(before, after: openArray[float64]; amp: openArray[float64] = @[]): tuple[n, ok: int] =
  ## How many finite pairs moved by 180 degrees. With `amp`, only where it
  ## is at least 5 % of its peak (a quiet bin's phase is noise).
  var peak = 0.0
  for a in amp:
    if not a.isNaN: peak = max(peak, a)
  let m = min(before.len, after.len)
  for i in 0 ..< m:
    if before[i].isNaN or after[i].isNaN: continue
    if amp.len > 0 and (i >= amp.len or amp[i].isNaN or amp[i] < peak * 0.05): continue
    inc result.n
    if abs(abs(angDiff(after[i], before[i])) - 180) < 2: inc result.ok

proc closeSeq(a, b: openArray[float64]; tol: float64): bool =
  if a.len != b.len or a.len == 0: return false
  var n = 0
  for i, x in a:
    if x.isNaN or b[i].isNaN: continue
    inc n
    if abs(x - b[i]) > tol * max(1.0, abs(x)): return false
  n > 4

proc negated(a, b: openArray[float64]; tol = 1e-3): bool =
  if a.len != b.len or a.len == 0: return false
  var n = 0
  for i, x in a:
    if x.isNaN or b[i].isNaN: continue
    inc n
    if abs(x + b[i]) > tol * max(1.0, abs(x)): return false
  n > 4

proc meanAbs(a, b: openArray[float32]): float64 =
  if a.len != b.len or a.len == 0: return Inf
  for i, v in a: result += abs(float64(v) - float64(b[i]))
  result / float64(a.len)

proc f64(x: openArray[float32]): seq[float64] =
  result = newSeq[float64](x.len)
  for i, v in x: result[i] = float64(v)

proc rowOf(t: Tile; trace: int): seq[float32] =
  let r = t.traces.find(trace)
  doAssert r >= 0, "trace " & $(trace + 1) & " is not in the tile"
  t.data[r * t.columns ..< (r + 1) * t.columns]

proc answered(st: AppState): bool =
  let p = st.panel(MainPanel)
  not p.pending.isEmpty and p.pending.gen == p.requestGen and st.tiles(0).len > 0 and
    st.tiles(0)[^1].request == p.pending

proc openPlot(st: var AppState; view: AnalysisView; traces: seq[int]): int =
  st.apply Command(kind: ckOpenPlot, plotView: view, plotTraces: traces)
  result = st.plots.high
  doAssert st.settle(st.plots[result].result.gen > 0 and not st.plots[result].waiting),
    "no answer for " & $view & ": " & st.plots[result].result.problem

proc spectrumOf(st: var AppState; traces: seq[int]): int =
  st.apply Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: traces)
  result = st.spectra.high
  doAssert st.settle(st.spectra[result].spectrum.raw.len > 0 and not st.spectra[result].waiting)

proc reverse(st: var AppState; traces: seq[int]; on: bool) =
  st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: traces, on: on)

proc coeff(r: AnalysisResult; signal: int): seq[float64] =
  r.plots[0].curves[2 * signal].ys

block words:
  doAssert reverseShownWords(11, [true]) == "Trace 12: reversed"
  doAssert reverseShownWords(0, [false]) == ""
  doAssert reverseShownWords(0, [true, false]) == "1 trace is reversed"
  doAssert reverseShownWords(0, [true, false, true]) == "2 traces are reversed"

block landGraphs:
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: land)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  let base = st.sessions[0].base
  let lay = st.panel(MainPanel).layout
  st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 800, 2 * lay.samples))
  doAssert st.settle(st.answered)
  let beforeTile = st.tiles(0)[^1]
  let neigh = st.spectrumOf(@[base])
  let plain = st.spectrumOf(@[base + 1])
  let plainPhase = st.spectra[plain].spectrum.rawPhase
  let plainAmp = st.spectra[plain].spectrum.raw
  doAssert plainPhase.len > 8, "a one-trace spectrum has no phase"
  let spec = st.openPlot(avSpectrogram, @[base + 1])
  let specBefore = st.plots[spec].result.image.values
  let env = st.openPlot(avEnvelope, @[base + 1])
  let envBefore = st.plots[env].result.plots[0].curves[1].ys
  let instBefore = st.plots[env].result.plots[1].curves[0].ys
  let phase = st.openPlot(avPhase, @[base + 1])
  let phaseBefore = st.plots[phase].result.plots[1].curves[0].ys
  let phaseAmp = st.plots[phase].result.plots[0].curves[0].ys
  let corr = st.openPlot(avCorrelation, @[base, base + 1])
  let corrBefore = st.plots[corr].result.coeff(1)
  let neighCorr = st.plots[corr].result.coeff(0)
  var fkTraces: seq[int]
  for i in 0 .. 7: fkTraces.add base + i
  let fk = st.openPlot(avFk, fkTraces)
  let fkBefore = st.plots[fk].result.image.values
  st.reverse(@[base + 1], true)
  doAssert st.settle(st.answered)
  let afterTile = st.tiles(0)[^1]
  doAssert negated(f64(beforeTile.rowOf(1)), f64(afterTile.rowOf(1)), 1e-4),
    "the plot did not reverse trace 2"
  doAssert closeSeq(f64(beforeTile.rowOf(0)), f64(afterTile.rowOf(0)), 1e-4),
    "the plot changed trace 1"
  doAssert st.reverseLine(st.panel(MainPanel)) == "1 trace is reversed",
    st.reverseLine(st.panel(MainPanel))
  doAssert st.spectra[neigh].asks == 1, "the neighbour spectrum was asked again"
  doAssert st.settle(st.spectra[plain].asks >= 2 and not st.spectra[plain].waiting)
  let filtered = st.spectra[plain].spectrum
  doAssert closeSeq(plainAmp, filtered.raw, 1e-4), "the amplitude spectrum changed"
  let sp = shifted180(plainPhase, filtered.rawPhase, plainAmp)
  doAssert sp.n > 8 and sp.ok > sp.n * 9 div 10, "the phase spectrum did not move 180 degrees: " &
    $sp.ok & " of " & $sp.n
  doAssert "Trace 2: reversed" in st.spectra[plain].filterText, st.spectra[plain].filterText
  doAssert st.settle(st.plots[spec].result.gen == st.plots[spec].asked and not st.plots[spec].waiting)
  doAssert st.plots[spec].result.image.values.meanAbs(specBefore) < 0.05,
    "the spectrogram changed: " & $st.plots[spec].result.image.values.meanAbs(specBefore)
  doAssert st.plots[spec].reverseLine.find("Trace 2: reversed") >= 0, st.plots[spec].reverseLine
  doAssert st.settle(st.plots[env].result.gen == st.plots[env].asked and not st.plots[env].waiting)
  let envAfter = st.plots[env].result.plots[0].curves[1].ys
  doAssert closeSeq(envBefore, envAfter, 1e-3), "the envelope changed"
  let inst = shifted180(instBefore, st.plots[env].result.plots[1].curves[0].ys)
  doAssert inst.n > 8 and inst.ok > inst.n * 9 div 10,
    "the instantaneous phase did not move 180 degrees: " & $inst.ok & " of " & $inst.n
  doAssert st.settle(st.plots[phase].result.gen == st.plots[phase].asked and
    not st.plots[phase].waiting)
  doAssert closeSeq(phaseAmp, st.plots[phase].result.plots[0].curves[0].ys, 1e-3),
    "the phase spectrum's amplitude changed"
  let ph = shifted180(phaseBefore, st.plots[phase].result.plots[1].curves[0].ys)
  doAssert ph.n > 8 and ph.ok > ph.n * 9 div 10, "the phase plot did not move 180 degrees: " &
    $ph.ok & " of " & $ph.n
  doAssert st.settle(st.plots[corr].result.gen == st.plots[corr].asked and not st.plots[corr].waiting)
  doAssert st.plots[corr].result.problem == "", st.plots[corr].result.problem
  doAssert negated(corrBefore, st.plots[corr].result.coeff(1)),
    "the correlation peak did not become a trough"
  doAssert closeSeq(neighCorr, st.plots[corr].result.coeff(0), 1e-3),
    "the neighbour's correlation changed"
  doAssert st.settle(st.plots[fk].result.gen == st.plots[fk].asked and not st.plots[fk].waiting)
  let fkDelta = st.plots[fk].result.image.values.meanAbs(fkBefore)
  doAssert fkDelta > 0.01, "the f-k ignored the one trace's reversal: " & $fkDelta
  # two of three: the count
  let both = st.spectrumOf(@[base, base + 1, base + 2])
  st.reverse(@[base + 2], true)
  doAssert st.settle(st.spectra[both].asks >= 2 and not st.spectra[both].waiting)
  doAssert "2 traces are reversed" in st.spectra[both].filterText, st.spectra[both].filterText
  # amplitude flags unchanged
  var settings = st.settings
  settings.map.filters = {mfWeak, mfAllZero, mfDcOffset, mfNoisy}
  st.apply Command(kind: ckSettings, settings: settings)
  doAssert st.settle(st.recordQc.job == NoJob and st.recordQc.hits[mfWeak].state == fsDone)
  var beforeFlags: array[MapFilter, seq[int]]
  for m in SampleFilters: beforeFlags[m] = st.recordQc.hits[m].traces
  st.reverse(@[base + 3], true)
  doAssert st.settle(st.recordQc.job == NoJob and st.recordQc.hits[mfWeak].state == fsDone)
  for m in SampleFilters:
    doAssert st.recordQc.hits[m].traces == beforeFlags[m], "the amplitude flags changed (" & $m & ")"
  st.shutdown()

block reversedReference:
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: land)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  let base = st.sessions[0].base
  let w = st.openPlot(avCorrelation, @[base, base + 1, base + 2])
  var p = st.plots[w].params
  p.reference = base + 4
  st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p, plotFrozen: false)
  doAssert st.settle(st.plots[w].result.gen == st.plots[w].asked and not st.plots[w].waiting)
  doAssert st.plots[w].result.problem == "", st.plots[w].result.problem
  var before: array[3, seq[float64]]
  for i in 0 .. 2: before[i] = st.plots[w].result.coeff(i)
  st.reverse(@[base + 4], true)
  doAssert st.settle(st.plots[w].asks >= 2 and not st.plots[w].waiting)
  for i in 0 .. 2:
    doAssert negated(before[i], st.plots[w].result.coeff(i)),
      "a reversed reference did not flip trace " & $(i + 1)
  doAssert "reference, Trace 5: reversed" in st.plots[w].result.note, st.plots[w].result.note
  st.shutdown()

block vibrator:
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: vib)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  let base = st.sessions[0].base
  var traces: seq[int]
  for i in 0 .. 3: traces.add base + i
  let w = st.openPlot(avVibrator, traces)
  doAssert st.plots[w].result.problem == "", st.plots[w].result.problem
  var before: seq[float64] = @[]
  for c in st.plots[w].result.plots[0].curves:
    if c.name == "GF": before = c.ys
  doAssert before.len > 8, "no ground-force phase"
  st.reverse(@[base + 1], true)
  doAssert st.settle(st.plots[w].result.gen == st.plots[w].asked and not st.plots[w].waiting)
  var after: seq[float64] = @[]
  for c in st.plots[w].result.plots[0].curves:
    if c.name == "GF": after = c.ys
  let moved = shifted180(before, after)
  doAssert moved.n > 8 and moved.ok > moved.n * 9 div 10,
    "the vibrator phase did not move 180 degrees: " & $moved.ok & " of " & $moved.n
  doAssert st.plots[w].reverseLine.find("reversed") >= 0, st.plots[w].reverseLine
  st.shutdown()

proc baseOf(st: AppState; path: string): int =
  for s in st.sessions:
    if s.path == path: return s.base
  doAssert false, "no open file for " & path

proc correlateOther(reversed: bool): array[3, seq[float64]] =
  ## Vib traces 2-4 against trace 3 of the other file, that trace reversed
  ## or not. The note is checked here; the coefficients are returned.
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: vibOther)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  let refTrace = st.sessions[0].base + 2
  if reversed: st.reverse(@[refTrace], true)
  st.apply Command(kind: ckOpen, paths: @[vib])
  doAssert st.settle(st.sessions.len == 2)
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: vib)
  doAssert st.settle(st.panel(MainPanel).laidOut and st.sessions.len == 2)
  let base = baseOf(st, vib)
  let w = st.openPlot(avCorrelation, @[base + 1, base + 2, base + 3])
  var p = st.plots[w].params
  p.reference = refTrace
  st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p, plotFrozen: false)
  doAssert st.settle(st.plots[w].result.gen == st.plots[w].asked and not st.plots[w].waiting)
  doAssert st.plots[w].result.problem == "", st.plots[w].result.problem
  if reversed:
    doAssert "reference, Trace 3: reversed" in st.plots[w].result.note, st.plots[w].result.note
  else:
    doAssert "reference, " notin st.plots[w].result.note, st.plots[w].result.note
  for i in 0 .. 2: result[i] = st.plots[w].result.coeff(i)
  discard st.shutdown()

block referenceInOtherFile:
  let plain = correlateOther(false)
  let flipped = correlateOther(true)
  for i in 0 .. 2:
    doAssert negated(plain[i], flipped[i]),
      "a reversed reference in another file did not flip trace " & $(i + 1)
  # cleared in its own file: the window asks again, and the line goes
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: vibOther)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  let refTrace = st.sessions[0].base + 2
  st.reverse(@[refTrace], true)
  st.apply Command(kind: ckOpen, paths: @[vib])
  doAssert st.settle(st.sessions.len == 2)
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: vib)
  doAssert st.settle(st.panel(MainPanel).laidOut)
  let base = baseOf(st, vib)
  let w = st.openPlot(avCorrelation, @[base + 1, base + 2, base + 3])
  var p = st.plots[w].params
  p.reference = refTrace
  st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p, plotFrozen: false)
  doAssert st.settle(st.plots[w].result.gen == st.plots[w].asked and not st.plots[w].waiting)
  doAssert "reference, Trace 3: reversed" in st.plots[w].result.note, st.plots[w].result.note
  let asks0 = st.plots[w].asks
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: vibOther)
  st.reverse(@[refTrace], false)
  doAssert st.settle(st.plots[w].asks > asks0 and not st.plots[w].waiting),
    "the correlation did not ask again when the reference's reversal was cleared"
  doAssert "reference, Trace 3: reversed" notin st.plots[w].result.note, st.plots[w].result.note
  st.shutdown()

block referenceAsksAgain:
  ## The pilot is the reference and not one of the shown traces.
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: vib)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  let base = st.sessions[0].base
  let w = st.openPlot(avCorrelation, @[base + 1, base + 2, base + 3])
  doAssert "trace 49" in st.plots[w].reference, st.plots[w].reference
  let pilot = base + 48
  let asks0 = st.plots[w].asks
  st.reverse(@[pilot], true)
  doAssert st.settle(st.plots[w].asks > asks0 and not st.plots[w].waiting),
    "the correlation did not ask again when the reference was reversed"
  doAssert "reference, Trace 49: reversed" in st.plots[w].result.note, st.plots[w].result.note
  let asks1 = st.plots[w].asks
  st.apply Command(kind: ckUndoEdit, panel: MainPanel)
  doAssert st.settle(st.plots[w].asks > asks1 and not st.plots[w].waiting),
    "the correlation did not ask again when the reference's reversal was undone"
  doAssert "reference, Trace 49: reversed" notin st.plots[w].result.note, st.plots[w].result.note
  st.reverse(@[pilot], true)
  doAssert st.settle(not st.plots[w].waiting)
  st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: st.plots[w].params,
    plotFrozen: true)
  doAssert st.settle(not st.plots[w].waiting)
  let asks2 = st.plots[w].asks
  st.apply Command(kind: ckClearEdits, panel: MainPanel)
  doAssert st.settle(not st.plots[w].waiting)
  doAssert st.plots[w].asks == asks2, "a frozen correlation asked again when the reversal was cleared"
  st.shutdown()

block askAgain:
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: land)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  let base = st.sessions[0].base
  let spec = st.spectrumOf(@[base + 1])
  let plot = st.openPlot(avPhase, @[base + 1])
  let asksS = st.spectra[spec].asks
  let asksP = st.plots[plot].asks
  st.reverse(@[base + 1], true)
  doAssert st.settle(st.spectra[spec].asks > asksS and st.plots[plot].asks > asksP and
    not st.spectra[spec].waiting and not st.plots[plot].waiting),
    "an open window did not ask again when a shown trace was reversed"
  doAssert "Trace 2: reversed" in st.spectra[spec].filterText, st.spectra[spec].filterText
  # undo
  let asksS1 = st.spectra[spec].asks
  let asksP1 = st.plots[plot].asks
  st.apply Command(kind: ckUndoEdit, panel: MainPanel)
  doAssert st.settle(st.spectra[spec].asks > asksS1 and st.plots[plot].asks > asksP1 and
    not st.plots[plot].waiting),
    "an open window did not ask again when the reversal was undone"
  doAssert "reversed" notin st.spectra[spec].filterText, st.spectra[spec].filterText
  doAssert st.plots[plot].reverseLine.len == 0, st.plots[plot].reverseLine
  # set, then clear
  st.reverse(@[base + 1], true)
  doAssert st.settle(not st.spectra[spec].waiting and not st.plots[plot].waiting)
  let asksS2 = st.spectra[spec].asks
  st.apply Command(kind: ckClearEdits, panel: MainPanel)
  doAssert st.settle(st.spectra[spec].asks > asksS2 and not st.spectra[spec].waiting),
    "an open window did not ask again when the reversal was cleared"
  doAssert "reversed" notin st.spectra[spec].filterText, st.spectra[spec].filterText
  # frozen: the same change asks nothing
  st.reverse(@[base + 1], true)
  doAssert st.settle(not st.spectra[spec].waiting)
  st.apply Command(kind: ckSpectrumDisplay, spectrum: st.spectra[spec].id,
    spectrumShow: st.spectra[spec].display, frozen: true)
  st.apply Command(kind: ckPlotDisplay, plot: st.plots[plot].id, plotParams: st.plots[plot].params,
    plotFrozen: true)
  doAssert st.settle(not st.spectra[spec].waiting and not st.plots[plot].waiting)
  let asksS3 = st.spectra[spec].asks
  let asksP3 = st.plots[plot].asks
  st.reverse(@[base + 1], false)
  doAssert st.settle(not st.spectra[spec].waiting and not st.plots[plot].waiting)
  doAssert st.spectra[spec].asks == asksS3 and st.plots[plot].asks == asksP3,
    "a frozen window asked again"
  st.shutdown()

echo "treverseall: ok"
