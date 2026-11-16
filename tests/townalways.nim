## A trace's own filter is part of the trace in every graph, with no option
## to leave it out (`samples/land/shots.sgy`, `samples/vib/vib_uncorrelated.sgd`):
##
## - a narrow own band-pass on one trace, no plot filter: the Seismic plot,
##   the spectrum's raw curve (Processed and Response locked), the spectrogram,
##   the envelope, the phase spectrum, the cross-correlation, the vibrator
##   signature and the f-k (Raw on and off) show the filter, energy outside
##   the band gone; the neighbour is unchanged;
## - the spectrum's line names the own filter; an own filter that runs instead
##   of the plot's leaves the processed curve equal to the raw one and says so;
## - the map's amplitude flags, computed for display, see the filter.
##
## Seen to fail: with the spectrum's raw curve taken from the file's samples
## (the own filter applied only on the processed path), "the spectrum's raw
## curve does not show the own filter".
##
## A reversal is applied by the Seismic plot and by Headers shown as displayed.
## These graphs ignore it, as they did before (not changed here): spectrum and
## FFT, spectrogram, envelope, phase spectrum, cross-correlation, vibrator
## signature, f-k, and the map's amplitude flags.

import std/[math, os, strutils]
import viewSEG/core/[analysis, processing, state]
import utils/waiting

const root = currentSourcePath().parentDir.parentDir
let land = root / "samples" / "land" / "shots.sgy"
let vib = root / "samples" / "vib" / "vib_uncorrelated.sgd"

proc band(lo, hi: float64; place = fpAfter): OwnFilter =
  bounded(OwnFilter(spec: Processing(band: pbBandPass, f1: lo - 4, f2: lo, f3: hi, f4: hi + 4),
    place: place))

proc spectrumOutside(sp: Spectrum; hz: float64): float64 =
  ## Power of `sp`'s raw curve below `hz`.
  for i, a in sp.raw:
    if float64(i) * sp.binHz < hz and a > 0 and a < Inf: result += a * a

proc imageOutside(img: AnalysisImage; hz: float64): float64 =
  ## Power of `img` below `hz` (its values are dB from the peak).
  for row in 0 ..< img.rows:
    if img.y0 + float64(row) * img.dy < hz:
      for col in 0 ..< img.cols:
        let db = float64(img.valueAt(col, row))
        if db > float64(img.lo): result += pow(10.0, db / 10.0)

proc refHz(r: AnalysisResult): seq[float64] =
  for p in r.plots:
    if p.title == "Frequency" and p.curves.len > 0: return p.curves[0].ys

proc ampOutside(plot: AnalysisPlot; hz: float64): float64 =
  ## Power of an amplitude-in-dB curve below `hz`.
  let ys = plot.curves[0].ys
  for i, f in plot.xs:
    if f < hz and i < ys.len and ys[i] > -200:
      result += pow(10.0, ys[i] / 10.0)

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

proc spectrumOf(st: var AppState; trace: int): int =
  st.apply Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: @[trace])
  result = st.spectra.high
  doAssert st.settle(st.spectra[result].spectrum.raw.len > 0 and not st.spectra[result].waiting)

block landGraphs:
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: land)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  let base = st.sessions[0].base
  let lay = st.panel(MainPanel).layout
  st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 800, 2 * lay.samples))
  doAssert st.settle(st.answered)
  let beforeTile = st.tiles(0)[^1]
  let neigh = st.spectrumOf(base)
  let neighPower = st.spectra[neigh].spectrum.spectrumOutside(20)
  doAssert neighPower > 0, "trace 1 has no energy below 20 Hz"
  let plain = st.spectrumOf(base + 1)
  let plainPower = st.spectra[plain].spectrum.spectrumOutside(20)
  doAssert plainPower > 0, "trace 2 has no energy below 20 Hz"
  let spec = st.openPlot(avSpectrogram, @[base + 1])
  let specPower = st.plots[spec].result.image.imageOutside(20)
  let env = st.openPlot(avEnvelope, @[base + 1])
  let phase = st.openPlot(avPhase, @[base + 1])
  let phasePower = st.plots[phase].result.plots[0].ampOutside(20)
  let corr = st.openPlot(avCorrelation, @[base, base + 1])
  var fkTraces: seq[int]
  for i in 0 .. 7: fkTraces.add base + i
  let fk = st.openPlot(avFk, fkTraces)
  let fkPower = st.plots[fk].result.image.imageOutside(20)
  let own = band(40, 60)
  st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base + 1], on: true,
    processing: own.spec, filterPlace: fpAfter)
  doAssert st.settle(st.answered)
  let afterTile = st.tiles(0)[^1]
  doAssert afterTile.rowOf(1) != beforeTile.rowOf(1), "the plot did not filter trace 2"
  doAssert afterTile.rowOf(0) == beforeTile.rowOf(0), "the plot changed trace 1"
  doAssert st.ownLine(st.panel(MainPanel)).len > 0
  # the spectrum of the filtered trace asks again; the neighbour does not
  doAssert st.spectra[neigh].spectrum.raw.len > 0
  doAssert st.spectra[neigh].asks == 1, "the neighbour spectrum was asked again"
  doAssert st.settle(st.spectra[plain].spectrum.gen > 0 and not st.spectra[plain].waiting and
    st.spectra[plain].asks >= 2)
  let filtered = st.spectra[plain].spectrum
  let cut = filtered.spectrumOutside(20)
  doAssert cut < plainPower * 0.25, "the spectrum's raw curve does not show the own filter: " &
    $cut & " against " & $plainPower
  doAssert filtered.processed.len == 0 and not filtered.hasResponse,
    "an own filter alone unlocked processing"
  doAssert "Trace 2: own filter, band-pass 40-60 Hz" in st.spectra[plain].filterText,
    st.spectra[plain].filterText
  doAssert st.spectra[plain].display.processed, "the stored Processed choice was cleared"
  doAssert st.settle(st.plots[spec].result.gen == st.plots[spec].asked and
    not st.plots[spec].waiting)
  let specCut = st.plots[spec].result.image.imageOutside(20)
  doAssert specCut < specPower * 0.25, "the spectrogram does not show the own filter: " &
    $specCut & " against " & $specPower
  doAssert st.plots[spec].ownLine.find("Trace 2: own filter, band-pass 40-60 Hz") >= 0,
    st.plots[spec].ownLine
  doAssert st.settle(st.plots[env].result.gen == st.plots[env].asked and not st.plots[env].waiting)
  let freq = st.plots[env].result.plots[2].curves[0].ys
  var inBand, loud = 0
  let envY = st.plots[env].result.plots[0].curves[1].ys
  var peak = 0.0
  for e in envY: peak = max(peak, e)
  for i, f in freq:
    if envY[i] > peak * 0.1 and not f.isNaN:
      inc loud
      if f >= 30 and f <= 70: inc inBand
  doAssert loud > 20 and inBand > loud * 8 div 10, "the envelope's frequency left the band: " &
    $inBand & " of " & $loud
  doAssert st.settle(st.plots[phase].result.gen == st.plots[phase].asked and
    not st.plots[phase].waiting)
  let phaseCut = st.plots[phase].result.plots[0].ampOutside(20)
  doAssert phaseCut < phasePower * 0.25, "the phase spectrum does not show the own filter: " &
    $phaseCut & " against " & $phasePower
  doAssert st.settle(st.plots[corr].result.gen == st.plots[corr].asked and
    not st.plots[corr].waiting)
  doAssert st.plots[corr].result.problem == "", st.plots[corr].result.problem
  let ratio = st.plots[corr].result.plots[1]
  var low = 0.0
  var nLow = 0
  for i, f in ratio.xs:
    if (f < 35 or f > 70) and f > 2 and i < ratio.curves[1].ys.len and
        not ratio.curves[1].ys[i].isNaN:
      low += ratio.curves[1].ys[i]
      inc nLow
  doAssert nLow > 4 and low / float64(nLow) < -12, "the correlation does not show the filter: " &
    $nLow & " points, " & $(low / float64(max(nLow, 1))) & " dB"
  doAssert st.settle(st.plots[fk].result.gen == st.plots[fk].asked and not st.plots[fk].waiting)
  let fkCut = st.plots[fk].result.image.imageOutside(20)
  doAssert abs(fkCut - fkPower) / fkPower > 0.05, "the f-k ignored the one trace's own filter: " &
    $fkCut & " against " & $fkPower
  var rawParams = st.plots[fk].params
  rawParams.fkRaw = true
  st.apply Command(kind: ckPlotDisplay, plot: st.plots[fk].id, plotParams: rawParams)
  doAssert st.settle(st.plots[fk].result.gen == st.plots[fk].asked and not st.plots[fk].waiting)
  doAssert st.plots[fk].result.note.find("the plot's filters left out") >= 0,
    st.plots[fk].result.note
  let fkRawCut = st.plots[fk].result.image.imageOutside(20)
  doAssert abs(fkRawCut - fkPower) / fkPower > 0.05, "f-k Raw left the own filter out: " &
    $fkRawCut & " against " & $fkPower
  # four traces, all with the filter: energy below the band is gone
  var four: seq[int]
  for i in 10 .. 13: four.add base + i
  let plainFk = st.openPlot(avFk, four)
  let plainFkPower = st.plots[plainFk].result.image.imageOutside(20)
  st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: four, on: true,
    processing: own.spec, filterPlace: fpAfter)
  doAssert st.settle(st.plots[plainFk].result.gen == st.plots[plainFk].asked and
    not st.plots[plainFk].waiting)
  let fourCut = st.plots[plainFk].result.image.imageOutside(20)
  doAssert fourCut < plainFkPower * 0.25, "an f-k of filtered traces kept energy below the band: " &
    $fourCut & " against " & $plainFkPower
  # the map's amplitude flags, for display
  var settings = st.settings
  settings.map.filters = {mfWeak, mfAllZero}
  st.apply Command(kind: ckSettings, settings: settings)
  doAssert st.settle(st.recordQc.job == NoJob and st.recordQc.hits[mfWeak].state == fsDone)
  let flagged = base + 1 in st.recordQc.hits[mfWeak].traces or
    base + 1 in st.recordQc.hits[mfAllZero].traces
  doAssert flagged, "the amplitude flags did not see the own filter"
  doAssert base notin st.recordQc.hits[mfWeak].traces and
    base notin st.recordQc.hits[mfAllZero].traces, "the neighbour was flagged"
  st.shutdown()

block insteadEquals:
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: land)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  let base = st.sessions[0].base
  st.apply Command(kind: ckProcessing, panel: MainPanel,
    processing: Processing(band: pbHighCut, f3: 80, f4: 100))
  let own = band(40, 60, fpInstead)
  st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base + 1], on: true,
    processing: own.spec, filterPlace: fpInstead)
  let w = st.spectrumOf(base + 1)
  let sp = st.spectra[w].spectrum
  doAssert sp.processed == sp.raw, "instead: processed is not the raw curve"
  doAssert st.spectra[w].filterText.find("this trace uses its own filter instead of the plot's") >= 0,
    st.spectra[w].filterText
  doAssert sp.filters == "high-cut 80-100 Hz", sp.filters
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
  let before = st.plots[w].result.refHz
  let own = band(40, 60)
  st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base], on: true,
    processing: own.spec, filterPlace: fpAfter)
  doAssert st.settle(st.plots[w].result.gen == st.plots[w].asked and not st.plots[w].waiting)
  doAssert st.plots[w].result.problem == "", st.plots[w].result.problem
  let after = st.plots[w].result.refHz
  doAssert after != before, "the vibrator signature ignored the own filter"
  var inBand, loud = 0
  for f in after:
    if not f.isNaN and f > 1:
      inc loud
      if f >= 30 and f <= 70: inc inBand
  doAssert loud > 10 and inBand > loud * 8 div 10, "the sweep's frequency left the band: " &
    $inBand & " of " & $loud
  doAssert st.plots[w].ownLine.find("own filter") >= 0, st.plots[w].ownLine
  st.shutdown()

block referenceOwnFollows:
  ## Seen to fail: with the reference's own filter left out of the follow
  ## test (`followFilters`), "the correlation did not ask again when the
  ## reference's own filter changed" (the pilot is not one of its traces).
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: vib)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  let base = st.sessions[0].base
  let w = st.openPlot(avCorrelation, @[base + 1, base + 2, base + 3])
  doAssert "trace 49" in st.plots[w].reference, st.plots[w].reference
  let pilot = base + 48
  let asks0 = st.plots[w].asks
  st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[pilot], on: true,
    processing: band(40, 60).spec, filterPlace: fpAfter)
  doAssert st.settle(st.plots[w].asks > asks0 and not st.plots[w].waiting),
    "the correlation did not ask again when the reference's own filter changed"
  doAssert "own filter" in st.plots[w].result.note, st.plots[w].result.note
  # frozen: the same change asks nothing
  st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: st.plots[w].params,
    plotFrozen: true)
  doAssert st.settle(not st.plots[w].waiting)
  let asks1 = st.plots[w].asks
  st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[pilot], on: true,
    processing: band(50, 70).spec, filterPlace: fpAfter)
  doAssert st.settle(not st.plots[w].waiting)
  doAssert st.plots[w].asks == asks1, "a frozen correlation asked again"
  st.shutdown()

echo "townalways: ok"
