## A reversed trace is reversed in every graph, with no option to leave it
## out (`samples/land/shots.sgy`, `samples/vib/vib_uncorrelated.sgd`):
##
## - reversing one trace moves that trace's phase spectrum and instantaneous
##   phase by 180 degrees, turns its correlation peak into a trough of the
##   same size, and leaves the amplitude spectrum, the envelope, the
##   spectrogram and the neighbours alone;
## - the window names it ("Trace 2: reversed", "N traces are reversed");
## - an open window that is not frozen asks again when a shown trace's
##   reversal is set, cleared or undone; a frozen one does not;
## - a correlation uses the chosen reference, which stays as stored;
## - the map's amplitude flags are unchanged.
##
## Reverse-all (`FileEdits.allReversed`) is the same flip: alone, every graph
## moves 180 degrees and says "All traces are reversed" once; together with a
## per-trace reversal it cancels, in every graph, and that trace is not called
## reversed. An unfrozen window asks again when reverse-all is set, cleared,
## undone or redone; a frozen one does not. A correlation's chosen reference
## stays as stored, so reverse-all of the traces flips the coefficient.
##
## Seen to fail: with the sign flip left out of `filtered` and the spectrum
## reader's raw curve, "the phase spectrum did not move 180 degrees". Leaving
## it out of `applyOwnQc` does not fail that check (the amplitude flags use
## the absolute mean). With reverse-all left out of `effectivelyReversed`,
## "reverse-all did not move 180 degrees in phase".

import std/[math, os, strutils]
import viewSEG/core/[analysis, processing, state]
import utils/[chosenref, waiting]

const root = currentSourcePath().parentDir.parentDir

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

proc reverseAll(st: var AppState; on: bool) =
  st.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: on)

proc coeff(r: AnalysisResult; signal: int): seq[float64] =
  r.plots[0].curves[2 * signal].ys

proc saysAll(text: string): bool =
  AllReversedWords in text

proc listsTraces(text: string): bool =
  ## The per-trace wording, not the one line reverse-all uses.
  "Trace " in text or "trace is reversed" in text or
    "traces are reversed" in text.replace(AllReversedWords, "")

proc main*() =
  let land = root / "samples" / "land" / "shots.sgy"
  let vib = root / "samples" / "vib" / "vib_uncorrelated.sgd"

  block words:
    doAssert reverseShownWords(11, [true]) == "Trace 12: reversed"
    doAssert reverseShownWords(0, [false]) == ""
    doAssert reverseShownWords(0, [true, false]) == "1 trace is reversed"
    doAssert reverseShownWords(0, [true, false, true]) == "2 traces are reversed"
    doAssert reverseShownWords(0, [true, true], true) == AllReversedWords
    doAssert reverseShownWords(0, [false], true) == ""
    doAssert reverseShownWords(0, [true, false], true) == "1 trace is reversed"
    var e: FileEdits
    doAssert not e.effectivelyReversed(1)
    discard e.setAllReversed(true)
    doAssert e.effectivelyReversed(1)
    discard e.change(teReversed, [1], true)
    doAssert not e.effectivelyReversed(1) and e.effectivelyReversed(2)

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
    discard st.chooseStored(root / ".scratch" / ("rev-land-" & $getCurrentProcessId()),
      base + 4, "land ref")
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
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[plot].id, plotParams: st.plots[
        plot].params,
      plotFrozen: true)
    doAssert st.settle(not st.spectra[spec].waiting and not st.plots[plot].waiting)
    let asksS3 = st.spectra[spec].asks
    let asksP3 = st.plots[plot].asks
    st.reverse(@[base + 1], false)
    doAssert st.settle(not st.spectra[spec].waiting and not st.plots[plot].waiting)
    doAssert st.spectra[spec].asks == asksS3 and st.plots[plot].asks == asksP3,
      "a frozen window asked again"
    st.shutdown()

  block reverseAllAlone:
    ## Reverse-all alone flips every graph, and the note says so once.
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: land)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let base = st.sessions[0].base
    let lay = st.panel(MainPanel).layout
    st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 800, 2 * lay.samples))
    doAssert st.settle(st.answered)
    let beforeTile = st.tiles(0)[^1]
    let spec = st.spectrumOf(@[base + 1])
    let plainPhase = st.spectra[spec].spectrum.rawPhase
    let plainAmp = st.spectra[spec].spectrum.raw
    let env = st.openPlot(avEnvelope, @[base + 1])
    let envBefore = st.plots[env].result.plots[0].curves[1].ys
    let instBefore = st.plots[env].result.plots[1].curves[0].ys
    let phase = st.openPlot(avPhase, @[base + 1])
    let phaseBefore = st.plots[phase].result.plots[1].curves[0].ys
    discard st.chooseStored(root / ".scratch" / ("rev-all-" & $getCurrentProcessId()),
      base + 4, "all ref")
    let corr = st.openPlot(avCorrelation, @[base, base + 1])
    let corrBefore = st.plots[corr].result.coeff(1)
    let neighCorr = st.plots[corr].result.coeff(0)
    let asksS = st.spectra[spec].asks
    let asksE = st.plots[env].asks
    let asksP = st.plots[phase].asks
    let asksC = st.plots[corr].asks
    st.reverseAll(true)
    doAssert st.settle(st.answered and st.spectra[spec].asks > asksS and
      st.plots[env].asks > asksE and st.plots[phase].asks > asksP and
      st.plots[corr].asks > asksC and not st.spectra[spec].waiting and
      not st.plots[env].waiting and not st.plots[phase].waiting and not st.plots[corr].waiting),
      "an open window did not ask again when reverse-all was set"
    doAssert negated(f64(beforeTile.rowOf(1)), f64(st.tiles(0)[^1].rowOf(1)), 1e-4),
      "the plot did not reverse every trace"
    doAssert closeSeq(plainAmp, st.spectra[spec].spectrum.raw, 1e-4),
      "reverse-all changed the amplitude spectrum"
    let sp = shifted180(plainPhase, st.spectra[spec].spectrum.rawPhase, plainAmp)
    doAssert sp.n > 8 and sp.ok > sp.n * 9 div 10,
      "reverse-all did not move 180 degrees in phase: " & $sp.ok & " of " & $sp.n
    doAssert saysAll(st.spectra[spec].filterText), st.spectra[spec].filterText
    doAssert not listsTraces(st.spectra[spec].filterText), st.spectra[spec].filterText
    doAssert closeSeq(envBefore, st.plots[env].result.plots[0].curves[1].ys, 1e-3),
      "reverse-all changed the envelope"
    let inst = shifted180(instBefore, st.plots[env].result.plots[1].curves[0].ys)
    doAssert inst.n > 8 and inst.ok > inst.n * 9 div 10,
      "reverse-all did not move the instantaneous phase: " & $inst.ok & " of " & $inst.n
    doAssert saysAll(st.plots[env].reverseLine), st.plots[env].reverseLine
    doAssert not listsTraces(st.plots[env].reverseLine), st.plots[env].reverseLine
    let ph = shifted180(phaseBefore, st.plots[phase].result.plots[1].curves[0].ys)
    doAssert ph.n > 8 and ph.ok > ph.n * 9 div 10,
      "reverse-all did not move the phase plot: " & $ph.ok & " of " & $ph.n
    doAssert saysAll(st.plots[phase].reverseLine), st.plots[phase].reverseLine
    # the chosen reference stays as stored, so reverse-all of the traces flips
    doAssert negated(corrBefore, st.plots[corr].result.coeff(1)),
      "reverse-all did not flip the correlation"
    doAssert negated(neighCorr, st.plots[corr].result.coeff(0)),
      "reverse-all did not flip the neighbour's correlation"
    doAssert saysAll(st.plots[corr].reverseLine), st.plots[corr].reverseLine
    doAssert "reference, Trace" notin st.plots[corr].result.note, st.plots[corr].result.note
    # undo asks again and puts the phase back
    let asksS1 = st.spectra[spec].asks
    let asksP1 = st.plots[phase].asks
    st.apply Command(kind: ckUndoEdit, panel: MainPanel)
    doAssert st.settle(st.spectra[spec].asks > asksS1 and st.plots[phase].asks > asksP1 and
      not st.spectra[spec].waiting and not st.plots[phase].waiting),
      "an open window did not ask again when reverse-all was undone"
    doAssert "reversed" notin st.spectra[spec].filterText, st.spectra[spec].filterText
    doAssert closeSeq(plainPhase, st.spectra[spec].spectrum.rawPhase, 1e-3),
      "undo of reverse-all did not put the phase back"
    # redo asks again
    let asksS2 = st.spectra[spec].asks
    st.apply Command(kind: ckRedoEdit, panel: MainPanel)
    doAssert st.settle(st.spectra[spec].asks > asksS2 and not st.spectra[spec].waiting),
      "an open window did not ask again when reverse-all was redone"
    doAssert saysAll(st.spectra[spec].filterText), st.spectra[spec].filterText
    let sp2 = shifted180(plainPhase, st.spectra[spec].spectrum.rawPhase, plainAmp)
    doAssert sp2.n > 8 and sp2.ok > sp2.n * 9 div 10, "redo of reverse-all did not flip the phase"
    st.shutdown()

  block reverseAllCancels:
    ## A per-trace reversal under reverse-all is not reversed, in every graph.
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: land)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let base = st.sessions[0].base
    let spec = st.spectrumOf(@[base + 1])
    let plainPhase = st.spectra[spec].spectrum.rawPhase
    let plainAmp = st.spectra[spec].spectrum.raw
    let env = st.openPlot(avEnvelope, @[base + 1])
    let instBefore = st.plots[env].result.plots[1].curves[0].ys
    let phase = st.openPlot(avPhase, @[base + 1])
    let phaseBefore = st.plots[phase].result.plots[1].curves[0].ys
    discard st.chooseStored(root / ".scratch" / ("rev-cancel-" & $getCurrentProcessId()),
      base + 4, "cancel ref")
    let corr = st.openPlot(avCorrelation, @[base, base + 1])
    doAssert st.settle(st.plots[corr].result.gen == st.plots[corr].asked and not st.plots[corr].waiting)
    let corrBefore = st.plots[corr].result.coeff(1)
    let neighBefore = st.plots[corr].result.coeff(0)
    st.reverse(@[base + 1], true)
    doAssert st.settle(not st.spectra[spec].waiting and not st.plots[env].waiting and
      not st.plots[phase].waiting and not st.plots[corr].waiting)
    st.reverseAll(true)
    doAssert st.settle(not st.spectra[spec].waiting and not st.plots[env].waiting and
      not st.plots[phase].waiting and not st.plots[corr].waiting)
    doAssert closeSeq(plainPhase, st.spectra[spec].spectrum.rawPhase, 1e-3),
      "reverse-all did not cancel the per-trace reversal in the spectrum"
    doAssert closeSeq(plainAmp, st.spectra[spec].spectrum.raw, 1e-4),
      "the cancelled reversal changed the amplitude"
    doAssert "Trace 2: reversed" notin st.spectra[spec].filterText, st.spectra[spec].filterText
    doAssert not saysAll(st.spectra[spec].filterText), st.spectra[spec].filterText
    doAssert "reversed" notin st.spectra[spec].filterText, st.spectra[spec].filterText
    let inst = shifted180(instBefore, st.plots[env].result.plots[1].curves[0].ys)
    doAssert inst.ok < inst.n div 10, "the instantaneous phase stayed flipped: " & $inst.ok &
      " of " & $inst.n
    doAssert "reversed" notin st.plots[env].reverseLine, st.plots[env].reverseLine
    doAssert closeSeq(phaseBefore, st.plots[phase].result.plots[1].curves[0].ys, 1e-3),
      "reverse-all did not cancel the reversal in the phase plot"
    doAssert "reversed" notin st.plots[phase].reverseLine, st.plots[phase].reverseLine
    # trace 2 cancels (as recorded); the neighbour stays reversed; the reference
    # stays as stored, so trace 2's coefficient holds and the neighbour's flips
    doAssert closeSeq(corrBefore, st.plots[corr].result.coeff(1), 1e-3),
      "a cancelled trace against the stored reference flipped"
    doAssert negated(neighBefore, st.plots[corr].result.coeff(0)),
      "the neighbour's correlation did not flip under reverse-all"
    doAssert "Trace 2: reversed" notin st.plots[corr].reverseLine, st.plots[corr].reverseLine
    st.shutdown()

  block reverseAllFrozen:
    ## A frozen window does not ask again when reverse-all is set or undone.
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: land)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let base = st.sessions[0].base
    let spec = st.spectrumOf(@[base + 1])
    let plot = st.openPlot(avPhase, @[base + 1])
    st.apply Command(kind: ckSpectrumDisplay, spectrum: st.spectra[spec].id,
      spectrumShow: st.spectra[spec].display, frozen: true)
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[plot].id, plotParams: st.plots[
        plot].params,
      plotFrozen: true)
    doAssert st.settle(not st.spectra[spec].waiting and not st.plots[plot].waiting)
    let asksS = st.spectra[spec].asks
    let asksP = st.plots[plot].asks
    let phaseBefore = st.plots[plot].result.plots[1].curves[0].ys
    st.reverseAll(true)
    doAssert st.settle(not st.spectra[spec].waiting and not st.plots[plot].waiting)
    doAssert st.spectra[spec].asks == asksS and st.plots[plot].asks == asksP,
      "a frozen window asked again when reverse-all was set"
    doAssert "reversed" notin st.spectra[spec].filterText, st.spectra[spec].filterText
    st.apply Command(kind: ckUndoEdit, panel: MainPanel)
    doAssert st.settle(not st.spectra[spec].waiting and not st.plots[plot].waiting)
    doAssert st.spectra[spec].asks == asksS and st.plots[plot].asks == asksP,
      "a frozen window asked again when reverse-all was undone"
    doAssert closeSeq(phaseBefore, st.plots[plot].result.plots[1].curves[0].ys, 1e-6),
      "a frozen phase plot moved"
    # redo of a frozen window holds too
    st.reverseAll(true)
    doAssert st.settle(not st.plots[plot].waiting)
    st.apply Command(kind: ckUndoEdit, panel: MainPanel)
    doAssert st.settle(not st.plots[plot].waiting)
    st.apply Command(kind: ckRedoEdit, panel: MainPanel)
    doAssert st.settle(not st.spectra[spec].waiting and not st.plots[plot].waiting)
    doAssert st.spectra[spec].asks == asksS and st.plots[plot].asks == asksP,
      "a frozen window asked again when reverse-all was redone"
    st.shutdown()

  block liveReverseAll:
    ## The live panel uses the same flip, and asks again unless frozen.
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: land)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let base = st.sessions[0].base
    st.apply Command(kind: ckSelect, traces: @[base + 1], mode: smReplace)
    st.apply Command(kind: ckSpectrumPanel, onScreen: true)
    doAssert st.settle(st.spectra[0].asks > 0 and st.spectra[0].spectrum.rawPhase.len > 8 and
      not st.spectra[0].waiting)
    let before = st.spectra[0].spectrum.rawPhase
    let amp = st.spectra[0].spectrum.raw
    let asks0 = st.spectra[0].asks
    st.reverseAll(true)
    doAssert st.settle(st.spectra[0].asks > asks0 and not st.spectra[0].waiting),
      "the live panel did not ask again when reverse-all was set"
    let moved = shifted180(before, st.spectra[0].spectrum.rawPhase, amp)
    doAssert moved.n > 8 and moved.ok > moved.n * 9 div 10,
      "the live panel did not move 180 degrees: " & $moved.ok & " of " & $moved.n
    doAssert saysAll(st.spectra[0].filterText), st.spectra[0].filterText
    st.apply Command(kind: ckSpectrumDisplay, spectrum: 0, spectrumShow: st.spectra[0].display,
      frozen: true)
    let asks1 = st.spectra[0].asks
    st.apply Command(kind: ckUndoEdit, panel: MainPanel)
    doAssert st.settle(not st.spectra[0].waiting)
    doAssert st.spectra[0].asks == asks1, "a frozen live panel asked again"
    st.shutdown()

  echo "treverseall: ok"

when isMainModule:
  main()
