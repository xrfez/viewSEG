## A vibrator QC profile: the settings one Vibrator window is using, kept so a
## QC run can apply them to other files. One profile per project (the job).
##
## It holds the six limits and the statistics window, the harmonics, the
## accelerometer set, the force scale, a 100 % force and a drive level when
## the user typed them, the reference's archive id (never its samples) and the
## top frequency typed for that reference.
##
## It does not hold anything read from a file: a controller or vibrator id, a
## serial, header weights and sensitivities, a polarity finding, a fitted top,
## an alignment shift, a sweep-fit residual, `swapForces`, `fromFirstFrame`, or
## roles taken from trace codes. The job's own weights are project fields, not
## part of this snapshot.

import std/math
import analysis, nif, settings

type
  VibQcProfile* = object
    ## Settings taken from one Vibrator window. A project without
    ## `hasVibProfile` has none of these, whatever the defaults below.
    limits*: QcLimits
    qcWindowMs*: float64 = 500.0
    harmonics*: int = 5
    accelSet*: AccelSet = asB
    forceScale*: ForceScale
    forceHundredPct*: float64 = NaN ## NaN: the user did not type a 100 % force
    targetPct*: float64 = NaN ## NaN: the user did not type a drive level
    referenceId*: string ## the reference's archive id; "" is none; never samples
    topHz*: float64 = NaN ## the top typed for `referenceId`; NaN: none
    later*: seq[NifNode]
      ## fields of the profile tree this version does not know, written back

  VibQcAsk* = object
    ## The plot options and ask parameters a QC run on another file must use.
    ## `problems` says what cannot be applied; the rest is still filled.
    options*: VibratorOptions
    accelSet*: AccelSet
    forceScale*: ForceScale
    referenceId*: string
    topHz*: float64
    problems*: seq[string]

const ForceNotJudged* = "No 100 % force: the force limits are not judged."
  ## What `applied` says when the profile has no 100 % force. The force limits
  ## are then not judged (`forceHundredPct` stays unset); the run does not fail.

func sameFloat(x, y: float64): bool {.inline.} =
  x == y or (x.isNaN and y.isNaN)

func sameLimits(a, b: QcLimits): bool =
  sameFloat(a.avgPhaseDeg, b.avgPhaseDeg) and
    sameFloat(a.peakPhaseDeg, b.peakPhaseDeg) and
    sameFloat(a.avgDistortionPct, b.avgDistortionPct) and
    sameFloat(a.peakDistortionPct, b.peakDistortionPct) and
    sameFloat(a.avgForcePct, b.avgForcePct) and
    sameFloat(a.peakForcePct, b.peakForcePct)

func `==`*(a, b: VibQcProfile): bool =
  ## Whether two profiles hold the same settings, a NaN (unset) equal to a NaN.
  ## `later` is what a newer document kept, not a setting, so it is not compared.
  sameLimits(a.limits, b.limits) and sameFloat(a.qcWindowMs, b.qcWindowMs) and
    a.harmonics == b.harmonics and a.accelSet == b.accelSet and
    a.forceScale == b.forceScale and
    sameFloat(a.forceHundredPct, b.forceHundredPct) and
    sameFloat(a.targetPct, b.targetPct) and a.referenceId == b.referenceId and
    sameFloat(a.topHz, b.topHz)

func referenceProblem*(id: string): string =
  ## What `applied` says when `id` is not among the archive ids it was given.
  if id.len == 0: "The reference is not in the archive."
  else: "The reference \"" & id & "\" is not in the archive."

func profileOf*(limits: QcLimits; qcWindowMs: float64; harmonics: int;
    accelSet: AccelSet; scale: ForceScale; forceHundredPct, targetPct: float64;
    referenceId: string; topHz: float64): VibQcProfile =
  ## The profile a Vibrator window is using. Pass that window's values, not a
  ## signature file's built-in reset (which clears a typed 100 % force and drive
  ## level). `referenceId` is the archive id, never samples. `topHz` is the top
  ## typed for that reference; NaN when none is. A 100 % force or drive level
  ## left NaN was not typed.
  VibQcProfile(limits: limits, qcWindowMs: qcWindowMs, harmonics: harmonics,
    accelSet: accelSet, forceScale: scale, forceHundredPct: forceHundredPct,
    targetPct: targetPct, referenceId: referenceId, topHz: topHz)

func typedForce(x: float64): bool {.inline.} =
  x > 0 and x < Inf

func applied*(p: VibQcProfile; archiveIds: openArray[string]): VibQcAsk =
  ## The plot options and ask parameters a QC run on another file must use.
  ## A reference id that is not in `archiveIds`, and a profile with no 100 %
  ## force, are named in `problems` and are not a failure: the force limits are
  ## then not judged, and the other settings are still applied.
  result = VibQcAsk(options: VibratorOptions(harmonics: p.harmonics,
    qcWindowMs: p.qcWindowMs, qc: p.limits, forceHundredPct: p.forceHundredPct,
    targetPct: p.targetPct), accelSet: p.accelSet, forceScale: p.forceScale,
    referenceId: p.referenceId, topHz: p.topHz)
  if p.referenceId.len == 0 or p.referenceId notin archiveIds:
    result.problems.add referenceProblem(p.referenceId)
  if not typedForce(p.forceHundredPct):
    result.problems.add ForceNotJudged
    result.options.forceHundredPct = NaN
