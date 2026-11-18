## The options the New plot windows remember: per kind of plot, the set the
## user set last, which a new window of that kind opens with, and which the
## settings file keeps (`Settings.plotOptions`).
##
## Only a kind's own options are remembered: the spectrogram's frame, overlap,
## floor and colour map; the phase spectrum's threshold and picture; the
## correlation's lags; the vibrator signature's harmonics, masses and limits;
## the f-k's floor, colour map and Raw; the envelope's phase against the reference
## or of the trace itself; for the envelope, correlation and vibrator signature, whether a
## phase is shown Absolute or Signed (`phaseshow`). What is not an option is not: which traces, the
## vibrator's roles, the f-k's time box (they belong to a file), the frozen
## state, the cursor, the axes' zoom. The node orientation has no options.
##
## An `AnalysisParams` holds a window's options with those; `remember` takes
## the options of a kind out of one, `applied` puts them into one, and
## `builtin` puts the built-in values into one (Reset options).

import std/math
import analysis, colourmaps, phasepicture, phaseshow

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
    phaseShow*: PhaseShow = psAbsolute

  VibratorOptions* = object
    reactionMassKg*: float64 = NaN ## NaN: none entered
    baseplateMassKg*: float64 = NaN
    harmonics*: int = 5
    phaseShow*: PhaseShow = psAbsolute
    projectReference*: bool = true
    limitsOn*: bool = false
    rolesOpen*: bool = false
    noteOpen*: bool = false
    limits*: VibLimits = VibLimits(phaseDeg: 10, meanPhaseDeg: 5, thdPct: 40,
      meanThdPct: 20)
    tops*: seq[TopFrequency]
    qcWindowMs*: float64 = 500.0
    qc*: QcLimits
    targetPct*: float64 = 100.0
    forceHundredPct*: float64 = NaN

  EnvelopeOptions* = object
    phaseAgainst*: PhaseAgainst = paReference
    phaseShow*: PhaseShow = psAbsolute

  FkOptions* = object
    floorDb*: float64 = -60.0
    colourMap*: ColourMap = cmViridis
    raw*: bool = false

  PlotOptions* = object
    ## The remembered options, one set per kind that has any.
    spectrogram*: SpectrogramOptions
    phase*: PhaseOptions
    correlation*: CorrelationOptions
    envelope*: EnvelopeOptions
    vibrator*: VibratorOptions
    fk*: FkOptions

const OptionViews* = {avSpectrogram, avEnvelope, avPhase, avCorrelation, avVibrator, avFk}
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
  of avCorrelation: result.correlation = CorrelationOptions(maxLagMs: p.maxLagMs,
    phaseShow: p.phaseShow)
  of avEnvelope: result.envelope = EnvelopeOptions(phaseAgainst: p.phaseAgainst,
    phaseShow: p.phaseShow)
  of avVibrator:
    result.vibrator = VibratorOptions(reactionMassKg: p.reactionMassKg,
      baseplateMassKg: p.baseplateMassKg, harmonics: p.harmonics,
      phaseShow: p.phaseShow, projectReference: p.projectReference,
      limitsOn: p.limitsOn,
      limits: p.limits, rolesOpen: p.rolesOpen, noteOpen: p.noteOpen, tops: p.tops,
      qcWindowMs: p.qcWindowMs, qc: p.qc,
      forceHundredPct: p.forceHundredPct, targetPct: p.targetPct)
  of avFk: result.fk = FkOptions(floorDb: p.floorDb, colourMap: p.colourMap, raw: p.fkRaw)
  of avOrientation: discard

func remember*(o: var PlotOptions; view: AnalysisView; p: AnalysisParams) =
  ## Takes the options of kind `view` out of `p`.
  let got = p.optionsOf(view)
  case view
  of avSpectrogram: o.spectrogram = got.spectrogram
  of avPhase: o.phase = got.phase
  of avCorrelation: o.correlation = got.correlation
  of avEnvelope: o.envelope = got.envelope
  of avVibrator: o.vibrator = got.vibrator
  of avFk: o.fk = got.fk
  of avOrientation: discard

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
  of avCorrelation: (result.maxLagMs, result.phaseShow) = (o.correlation.maxLagMs,
      o.correlation.phaseShow)
  of avEnvelope: (result.phaseAgainst, result.phaseShow) = (o.envelope.phaseAgainst,
      o.envelope.phaseShow)
  of avVibrator:
    (result.reactionMassKg, result.baseplateMassKg, result.harmonics, result.phaseShow,
     result.projectReference,
     result.limitsOn, result.limits) = (o.vibrator.reactionMassKg, o.vibrator.baseplateMassKg,
       o.vibrator.harmonics, o.vibrator.phaseShow, o.vibrator.projectReference, o.vibrator.limitsOn,
       o.vibrator.limits)
    result.targetPct = o.vibrator.targetPct
    (result.rolesOpen, result.noteOpen) = (o.vibrator.rolesOpen, o.vibrator.noteOpen)
    (result.tops, result.qcWindowMs, result.qc, result.forceHundredPct) = (
      o.vibrator.tops, o.vibrator.qcWindowMs, o.vibrator.qc,
          o.vibrator.forceHundredPct)
  of avFk: (result.floorDb, result.colourMap, result.fkRaw) = (o.fk.floorDb,
      o.fk.colourMap, o.fk.raw)
  of avOrientation: discard

func builtin*(view: AnalysisView; p: AnalysisParams): AnalysisParams =
  ## `p` with the options of kind `view` at their built-in values.
  PlotOptions().applied(view, p)
