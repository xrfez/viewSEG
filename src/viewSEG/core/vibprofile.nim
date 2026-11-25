## A vibrator QC profile: the settings one Vibrator window is using, kept so a
## QC run can apply them to other files. One profile per project (the job).
##
## It holds the six limits and the statistics window, the harmonics, the
## accelerometer set, the force scale, a 100 % force, the unit it was typed
## in and, for pound-counts, the accelerometer set that force was typed on,
## a drive level when the user typed them, the reference's archive id
## (never its samples) and the top frequency typed for that reference.
##
## It does not hold anything read from a file: a controller or vibrator id, a
## serial, header weights and sensitivities, a polarity finding, a fitted top,
## an alignment shift, a sweep-fit residual, `swapForces`, `fromFirstFrame`, or
## roles taken from trace codes. The job's own weights are project fields, not
## part of this snapshot.

import std/math
import analysis, nif, settings, units

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
    forceHundredUnit*: string ## the unit that force was typed in; "": not said
    forceHundredSet*: AccelSet = asB
      ## the accelerometer set a 100 % force in pound-counts was typed on.
      ## Meaningful only when `forceHundredSetKnown`.
    forceHundredSetKnown*: bool
      ## the document stored `forceHundredSet`. An older project that leaves
      ## the field out is unknown: not the default set, and not the set judged.
    targetPct*: float64 = NaN ## NaN: the user did not type a drive level
    judge*: JudgeOn = joRecorded
      ## the ground force the run judges: in the record, or made from mass and baseplate
    madeReactionKg*, madeBaseplateKg*: float64 = NaN
      ## the masses (a converter's file: its weights) the ground force is made from M and B with
    forceHundredWeighted*: float64 = NaN
      ## the 100 % force of the ground force made from M and B (NaN: none typed)
    referenceId*: string ## the reference's archive id; "" is none; never samples
    topHz*: float64 = NaN ## the top typed for `referenceId`; NaN: none
    fromFile*: string
      ## the name of the signature file the window that set these was showing;
      ## a label for the user, never read back as a setting
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
    forceHundredUnit*: string ## the unit of the typed 100 % force; "": not said
    forceHundredSet*: AccelSet = asB
      ## the set a pound-counts 100 % force was typed on, when known
    forceHundredSetKnown*: bool
      ## `forceHundredSet` was stored. False: an older project, the set unknown.
    judge*: JudgeOn = joRecorded ## the ground force judged (`VibQcProfile.judge`)
    problems*: seq[string]

const ForceNotJudged* = "No 100 % force: the force limits are not judged."
  ## What a run's table says above the rows when any file's force limits were not
  ## judged. A profile with no typed 100 % force is not a problem of its own: each
  ## file may give its force (a `.dat` from its target force, a `.vib` from its
  ## hold-down weight), and the file that cannot says why.

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
    a.forceHundredUnit == b.forceHundredUnit and
    a.forceHundredSet == b.forceHundredSet and
    a.forceHundredSetKnown == b.forceHundredSetKnown and
    sameFloat(a.targetPct, b.targetPct) and a.referenceId == b.referenceId and
    sameFloat(a.topHz, b.topHz) and a.fromFile == b.fromFile and a.judge == b.judge and
    sameFloat(a.madeReactionKg, b.madeReactionKg) and
    sameFloat(a.madeBaseplateKg, b.madeBaseplateKg) and
    sameFloat(a.forceHundredWeighted, b.forceHundredWeighted)

func merged*(stored, had, now: VibQcProfile): VibQcProfile =
  ## The stored profile with only what the user changed in one window written into
  ## it: a field that differs between `had` (the window's settings before the
  ## change) and `now` (after it) takes `now`'s value; every other field keeps its
  ## stored value, so a window that never had a drive level cannot wipe one set
  ## in another. `fromFile` follows only a change of the 100 % force, its unit or
  ## the drive level.
  result = stored
  template take(field: untyped) =
    if had.field != now.field: result.field = now.field
  func takeFloat(into: var float64; was, became: float64) =
    if not sameFloat(was, became): into = became
  takeFloat(result.limits.avgPhaseDeg, had.limits.avgPhaseDeg, now.limits.avgPhaseDeg)
  takeFloat(result.limits.peakPhaseDeg, had.limits.peakPhaseDeg, now.limits.peakPhaseDeg)
  takeFloat(result.limits.avgDistortionPct, had.limits.avgDistortionPct,
    now.limits.avgDistortionPct)
  takeFloat(result.limits.peakDistortionPct, had.limits.peakDistortionPct,
    now.limits.peakDistortionPct)
  takeFloat(result.limits.avgForcePct, had.limits.avgForcePct, now.limits.avgForcePct)
  takeFloat(result.limits.peakForcePct, had.limits.peakForcePct, now.limits.peakForcePct)
  takeFloat(result.qcWindowMs, had.qcWindowMs, now.qcWindowMs)
  take(harmonics)
  take(accelSet)
  take(forceScale)
  takeFloat(result.forceHundredPct, had.forceHundredPct, now.forceHundredPct)
  take(forceHundredUnit)
  take(forceHundredSet)
  take(forceHundredSetKnown)
  takeFloat(result.targetPct, had.targetPct, now.targetPct)
  take(referenceId)
  takeFloat(result.topHz, had.topHz, now.topHz)
  take(judge)
  takeFloat(result.madeReactionKg, had.madeReactionKg, now.madeReactionKg)
  takeFloat(result.madeBaseplateKg, had.madeBaseplateKg, now.madeBaseplateKg)
  takeFloat(result.forceHundredWeighted, had.forceHundredWeighted, now.forceHundredWeighted)
  if had.referenceId != now.referenceId: result.topHz = now.topHz
  if not sameFloat(had.forceHundredPct, now.forceHundredPct) or
      had.forceHundredUnit != now.forceHundredUnit or
      not sameFloat(had.targetPct, now.targetPct):
    result.fromFile = now.fromFile

func changeWords*(a, b: VibQcProfile): seq[string] =
  ## What differs between two profiles, in words, one bit per setting: "drive level
  ## 60 %", "average phase limit off". Empty when they hold the same settings.
  result = @[]
  proc limitBit(name: string; x, y: float64; unit: string; into: var seq[string]) =
    if not sameFloat(x, y):
      into.add name & " limit " & (if y.isNaN: "off" else: sensible(y) & unit)
  limitBit("average phase", a.limits.avgPhaseDeg, b.limits.avgPhaseDeg, "°", result)
  limitBit("peak phase", a.limits.peakPhaseDeg, b.limits.peakPhaseDeg, "°", result)
  limitBit("average distortion", a.limits.avgDistortionPct, b.limits.avgDistortionPct, " %",
    result)
  limitBit("peak distortion", a.limits.peakDistortionPct, b.limits.peakDistortionPct, " %",
    result)
  limitBit("average force", a.limits.avgForcePct, b.limits.avgForcePct, " %", result)
  limitBit("peak force", a.limits.peakForcePct, b.limits.peakForcePct, " %", result)
  if not sameFloat(a.qcWindowMs, b.qcWindowMs):
    result.add "statistics window " & sensible(b.qcWindowMs) & " ms"
  if a.harmonics != b.harmonics: result.add "harmonics " & $b.harmonics
  if a.accelSet != b.accelSet: result.add "accelerometer set " & $b.accelSet
  if a.forceScale != b.forceScale: result.add "force scale"
  if not sameFloat(a.forceHundredPct, b.forceHundredPct) or
      a.forceHundredUnit != b.forceHundredUnit:
    result.add (if b.forceHundredPct.isNaN: "100 % force cleared"
      else: "100 % force " & sensible(b.forceHundredPct) &
        (if b.forceHundredUnit.len > 0: " " & b.forceHundredUnit else: ""))
  if not sameFloat(a.targetPct, b.targetPct):
    result.add (if b.targetPct.isNaN: "drive level cleared"
      else: "drive level " & sensible(b.targetPct) & " %")
  if a.referenceId != b.referenceId:
    result.add (if b.referenceId.len == 0: "no reference" else: "reference " & b.referenceId)
  if not sameFloat(a.topHz, b.topHz):
    result.add (if b.topHz.isNaN: "top frequency cleared"
      else: "top frequency " & sensible(b.topHz) & " Hz")
  if a.judge != b.judge:
    result.add (if b.judge == joWeighted: "ground force made from mass and baseplate"
      else: "ground force in the record")
  if not sameFloat(a.madeReactionKg, b.madeReactionKg) or
      not sameFloat(a.madeBaseplateKg, b.madeBaseplateKg):
    result.add "masses for the made ground force"
  if not sameFloat(a.forceHundredWeighted, b.forceHundredWeighted):
    result.add (if b.forceHundredWeighted.isNaN: "100 % force of the made ground force cleared"
      else: "100 % force of the made ground force " & sensible(b.forceHundredWeighted))

func referenceProblem*(id: string): string =
  ## What `applied` says when `id` is not among the archive ids it was given.
  if id.len == 0: "The reference is not in the archive."
  else: "The reference \"" & id & "\" is not in the archive."

func profileOf*(limits: QcLimits; qcWindowMs: float64; harmonics: int;
    accelSet: AccelSet; scale: ForceScale; forceHundredPct, targetPct: float64;
    referenceId: string; topHz: float64; forceHundredUnit = "";
    forceHundredSet = asB; fromFile = ""; judge = joRecorded; madeReactionKg = NaN;
    madeBaseplateKg = NaN; forceHundredWeighted = NaN): VibQcProfile =
  ## The profile a Vibrator window is using. Pass that window's values, not a
  ## signature file's built-in reset (which clears a typed 100 % force and drive
  ## level). `referenceId` is the archive id, never samples. `topHz` is the top
  ## typed for that reference; NaN when none is. A 100 % force or drive level
  ## left NaN was not typed. `forceHundredUnit` is the unit that force was typed
  ## in; empty when none was said. `forceHundredSet` is the accelerometer set a
  ## pound-counts force was typed on; the window's, so it is known. `fromFile`
  ## names the file the window showed. `judge` is the ground force switch, with the masses
  ## (weights) and the 100 % force it needs.
  VibQcProfile(limits: limits, qcWindowMs: qcWindowMs, harmonics: harmonics,
    accelSet: accelSet, forceScale: scale, forceHundredPct: forceHundredPct,
    forceHundredUnit: forceHundredUnit, forceHundredSet: forceHundredSet,
    forceHundredSetKnown: true, targetPct: targetPct,
    referenceId: referenceId, topHz: topHz, fromFile: fromFile, judge: judge,
    madeReactionKg: madeReactionKg, madeBaseplateKg: madeBaseplateKg,
    forceHundredWeighted: forceHundredWeighted)

func typedForce(x: float64): bool {.inline.} =
  x > 0 and x < Inf

func applied*(p: VibQcProfile; archiveIds: openArray[string]): VibQcAsk =
  ## The plot options and ask parameters a QC run on another file must use.
  ## A reference id that is not in `archiveIds` is named in `problems` and is
  ## not a failure: the other settings are still applied. A profile with no
  ## typed 100 % force leaves it unset; each file may give its own.
  result = VibQcAsk(options: VibratorOptions(harmonics: p.harmonics,
    qcWindowMs: p.qcWindowMs, qc: p.limits, forceHundredPct: p.forceHundredPct,
    targetPct: p.targetPct), accelSet: p.accelSet, forceScale: p.forceScale,
    referenceId: p.referenceId, topHz: p.topHz,
    forceHundredUnit: p.forceHundredUnit, forceHundredSet: p.forceHundredSet,
    forceHundredSetKnown: p.forceHundredSetKnown, judge: p.judge)
  if p.judge == joWeighted:
    # the masses and the made signal's own 100 % force go to the run only when it is made
    result.options.reactionMassKg = p.madeReactionKg
    result.options.baseplateMassKg = p.madeBaseplateKg
    result.options.forceHundredWeighted = p.forceHundredWeighted
  if p.referenceId.len == 0 or p.referenceId notin archiveIds:
    result.problems.add referenceProblem(p.referenceId)
  if not typedForce(p.forceHundredPct):
    result.options.forceHundredPct = NaN
