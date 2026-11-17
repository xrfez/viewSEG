## The options the New plot windows remember: per kind of plot, the set the
## user set last, which a new window of that kind opens with, and which the
## settings file keeps (`Settings.plotOptions`).
##
## Only a kind's own options are remembered: the spectrogram's frame, overlap,
## floor and colour map; the phase spectrum's threshold and picture; the
## correlation's lags; the vibrator signature's harmonics, masses and limits;
## the f-k's floor, colour map and Raw. What is not an option is not: which
## traces, the vibrator's roles, the f-k's time box (they belong to a file),
## the frozen state, the cursor, the axes' zoom. The envelope and the node
## orientation have no options.
##
## An `AnalysisParams` holds a window's options with those; `remember` takes
## the options of a kind out of one, `applied` puts them into one, and
## `builtin` puts the built-in values into one (Reset options).

import std/math
import analysis, colourmaps, phasepicture

type
  SpectrogramOptions* = object
    windowMs*: float64 = 128.0
    overlap*: float64 = 75.0
    floorDb*: float64 = -60.0
    colourMap*: ColourMap = cmViridis

  PhaseOptions* = object
    phaseWithinDb*: float64 = 20.0
    phasePicture*: PhasePicture = ppUnwrapped

  CorrelationOptions* = object
    maxLagMs*: float64 = 250.0

  VibratorOptions* = object
    reactionMassKg*: float64 = NaN ## NaN: none entered
    baseplateMassKg*: float64 = NaN
    harmonics*: int = 5
    limitsOn*: bool = false
    limits*: VibLimits = VibLimits(phaseDeg: 10, meanPhaseDeg: 5, thdPct: 40,
      meanThdPct: 20)

  FkOptions* = object
    floorDb*: float64 = -60.0
    colourMap*: ColourMap = cmViridis
    raw*: bool = false

  PlotOptions* = object
    ## The remembered options, one set per kind that has any.
    spectrogram*: SpectrogramOptions
    phase*: PhaseOptions
    correlation*: CorrelationOptions
    vibrator*: VibratorOptions
    fk*: FkOptions

const OptionViews* = {avSpectrogram, avPhase, avCorrelation, avVibrator, avFk}
  ## the kinds of plot that have options to remember

func `==`*(a, b: PlotOptions): bool =
  ## Whether two are the same, a NaN (a mass or a limit not set) equal to a NaN.
  func same(x, y: float64): bool {.inline.} = x == y or (x.isNaN and y.isNaN)
  func equal[T: object](x, y: T): bool =
    for u, v in fields(x, y):
      when u is float64:
        if not same(u, v): return false
      elif u is object:
        if not equal(u, v): return false
      else:
        if u != v: return false
    true
  equal(a, b)

func hasOptions*(view: AnalysisView): bool = view in OptionViews

func optionsOf*(p: AnalysisParams; view: AnalysisView): PlotOptions =
  ## The options of kind `view` that `p` holds, the other kinds' left built in.
  result = PlotOptions()
  case view
  of avSpectrogram:
    result.spectrogram = SpectrogramOptions(windowMs: p.windowMs, overlap: p.overlap,
      floorDb: p.floorDb, colourMap: p.colourMap)
  of avPhase:
    result.phase = PhaseOptions(phaseWithinDb: p.phaseWithinDb, phasePicture: p.phasePicture)
  of avCorrelation: result.correlation = CorrelationOptions(maxLagMs: p.maxLagMs)
  of avVibrator:
    result.vibrator = VibratorOptions(reactionMassKg: p.reactionMassKg,
      baseplateMassKg: p.baseplateMassKg, harmonics: p.harmonics, limitsOn: p.limitsOn,
      limits: p.limits)
  of avFk: result.fk = FkOptions(floorDb: p.floorDb, colourMap: p.colourMap, raw: p.fkRaw)
  of avEnvelope, avOrientation: discard

func remember*(o: var PlotOptions; view: AnalysisView; p: AnalysisParams) =
  ## Takes the options of kind `view` out of `p`.
  let got = p.optionsOf(view)
  case view
  of avSpectrogram: o.spectrogram = got.spectrogram
  of avPhase: o.phase = got.phase
  of avCorrelation: o.correlation = got.correlation
  of avVibrator: o.vibrator = got.vibrator
  of avFk: o.fk = got.fk
  of avEnvelope, avOrientation: discard

func applied*(o: PlotOptions; view: AnalysisView; p: AnalysisParams): AnalysisParams =
  ## `p` with the options of kind `view` as `o` has them; the rest as it was.
  result = p
  case view
  of avSpectrogram:
    (result.windowMs, result.overlap, result.floorDb, result.colourMap) =
      (o.spectrogram.windowMs, o.spectrogram.overlap, o.spectrogram.floorDb,
       o.spectrogram.colourMap)
  of avPhase:
    (result.phaseWithinDb, result.phasePicture) = (o.phase.phaseWithinDb, o.phase.phasePicture)
  of avCorrelation: result.maxLagMs = o.correlation.maxLagMs
  of avVibrator:
    (result.reactionMassKg, result.baseplateMassKg, result.harmonics, result.limitsOn,
     result.limits) = (o.vibrator.reactionMassKg, o.vibrator.baseplateMassKg,
       o.vibrator.harmonics, o.vibrator.limitsOn, o.vibrator.limits)
  of avFk: (result.floorDb, result.colourMap, result.fkRaw) = (o.fk.floorDb, o.fk.colourMap, o.fk.raw)
  of avEnvelope, avOrientation: discard

func builtin*(view: AnalysisView; p: AnalysisParams): AnalysisParams =
  ## `p` with the options of kind `view` at their built-in values.
  PlotOptions().applied(view, p)
