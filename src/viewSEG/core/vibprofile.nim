## A vibrator QC profile: the settings one Vibrator window is using, kept so a
## QC run can apply them to other files. One profile per project (the job).
##
## It holds the six limits and the statistics window, the harmonics, the
## accelerometer set, the force scale, the project's one 100 % force with the unit it
## was given in and, for pound-counts, the accelerometer set it was given on, where it
## came from (typed, or set on a sweep: its file and its vibrator), a drive level when the
## user typed it, the reference's archive id (never its samples) and the top frequency
## typed for that reference.
##
## It does not hold anything read from a file: a controller or vibrator id, a
## serial, header weights and sensitivities, a polarity finding, a fitted top,
## an alignment shift, a sweep-fit residual, `swapForces`, `fromFirstFrame`, or
## roles taken from trace codes. The job's own weights are project fields, not
## part of this snapshot.

import std/math
import analysis, nif, settings, units

type
  VibHundred* = object
    ## A 100 % force with the unit and accelerometer set it was given in, and how and where it
    ## was given. The value keeps its own unit: it is never read in another.
    vibrator*: int
      ## the vibrator (the QC record's vibrator ID) of the sweep it was set on; 0: not known.
      ## Information only: the value is used for every vibrator
    pct*: float64 = NaN
    unit*: string
      ## the unit `pct` was given in (`HundredUnits`); "": not known, so it is not applied
      ## until it is set again
    accelSet*: AccelSet = asB ## the accelerometer set a pound-counts value was given on
    setKnown*: bool ## `accelSet` is known
    how*: HundredHow = hhTyped
    atPct*: float64 = NaN ## the target force (%) it was given at
    file*: string ## the file the window showed when it was given

  VibQcProfile* = object
    ## Settings taken from one Vibrator window. A project without
    ## `hasVibProfile` has none of these, whatever the defaults below.
    limits*: QcLimits
    qcWindowMs*: float64 = 500.0
    harmonics*: int = 5
    accelSet*: AccelSet = asB
    forceScale*: ForceScale
    forceHundredPct*: float64 = NaN
      ## the project's one 100 % force, used for every vibrator; NaN: none
    forceHundredUnit*: string ## the unit `forceHundredPct` was typed in; "": not said
    forceHundredSet*: AccelSet = asB
      ## the accelerometer set a 100 % force in pound-counts was typed on.
      ## Meaningful only when `forceHundredSetKnown`.
    forceHundredSetKnown*: bool
      ## the document stored `forceHundredSet`. An older project that leaves
      ## the field out is unknown: not the default set, and not the set judged.
    targetPct*: float64 = NaN ## NaN: the user did not type a drive level
    hundredHow*: HundredHow = hhTyped ## how `forceHundredPct` (the default) was given
    hundredAtPct*: float64 = NaN ## the target force (%) it was given at
    hundredFile*: string ## the file the window showed when it was set or typed; "": not known
    hundredVibrator*: int ## the vibrator of that file's sweep; 0: not known
    olderHundreds*: seq[VibHundred]
      ## 100 % forces an older version kept per vibrator that differ from each other (or from
      ## `forceHundredPct`): the project then has no 100 % force (`forceHundredPct` is NaN)
      ## and these are kept as read until one is set again, which drops them
    olderSingle*: VibHundred
      ## the one value an older document held beside `olderHundreds` that differ from it,
      ## kept as read with them
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
    hundredConflict*: string
      ## `hundredConflict` of the profile: why there is no 100 % force; "": no reason to say
    judge*: JudgeOn = joRecorded
      ## the ground force judged (`VibQcProfile.judge`) on a file whose layout has no choice of
      ## its own (`layouts`)
    layouts*: seq[string]
      ## the roles chosen by hand per file layout (`choiceText`), the ones the Vibrator window
      ## uses: a file of a layout with a choice is judged on its places (Swap mass and
      ## baseplate among them) and its polarities (a signature file: the ground force's);
      ## not part of the profile
    tops*: seq[string]
      ## the top frequencies typed in the project (`topTexts`): a file measured against its
      ## recorded reference takes the one typed for its layout (`recordedTopKey`), as a window
      ## does; not part of the profile
    segyHundredPct*: float64 = NaN
      ## the 100 % force a Vibrator window on a SEG-Y file opens with (the one typed last on
      ## one, in that file's unit; NaN: none): the external converter's SEG-Y's recorded ground
      ## force is judged with it, never with the signature files' value; not part of the profile
    segyTargetPct*: float64 = 100.0 ## ... and its drive level
    problems*: seq[string]

const ForceNotJudged* = "No 100 % force: the force limits are not judged."
  ## What a run's table says above the rows when any file's force limits were not
  ## judged. A profile with no typed 100 % force is not a problem of its own: each
  ## file may give its force (a `.dat` from its target force, a `.vib` from its
  ## hold-down weight), and the file that cannot says why.

const OneSetOfWeights* = "One set of weights for the project: the folder QC uses them too. " &
  "The Ground force choice (In the record or Made from mass and baseplate) is one for the " &
  "project as well: the folder QC judges every file with the one set last in any Vibrator " &
  "window, .dat and .vib files included. The 100 % force is one for the project too: it is " &
  "used for every vibrator."
  ## The note beside a converter's weight boxes in a project.

func sameFloat(x, y: float64): bool {.inline.} =
  x == y or (x.isNaN and y.isNaN)

func sameLimits(a, b: QcLimits): bool =
  sameFloat(a.avgPhaseDeg, b.avgPhaseDeg) and
    sameFloat(a.peakPhaseDeg, b.peakPhaseDeg) and
    sameFloat(a.avgDistortionPct, b.avgDistortionPct) and
    sameFloat(a.peakDistortionPct, b.peakDistortionPct) and
    sameFloat(a.avgForcePct, b.avgForcePct) and
    sameFloat(a.peakForcePct, b.peakForcePct)

func sameHundred*(a, b: VibHundred): bool =
  ## Whether `a` and `b` are the same value, given in the same way (a NaN equal to a NaN).
  a.vibrator == b.vibrator and sameFloat(a.pct, b.pct) and a.unit == b.unit and
    a.accelSet == b.accelSet and a.setKnown == b.setKnown and a.how == b.how and
    sameFloat(a.atPct, b.atPct) and a.file == b.file

func sameHundreds(a, b: seq[VibHundred]): bool =
  result = a.len == b.len
  for i in 0 ..< min(a.len, b.len):
    if not sameHundred(a[i], b[i]): result = false

func hundredOf*(p: VibQcProfile): VibHundred =
  ## The project's one 100 % force with its unit, set and where it came from; `pct` NaN when
  ## there is none.
  VibHundred(vibrator: p.hundredVibrator, pct: p.forceHundredPct, unit: p.forceHundredUnit,
    accelSet: p.forceHundredSet, setKnown: p.forceHundredSetKnown, how: p.hundredHow,
    atPct: p.hundredAtPct, file: p.hundredFile)

func setHundred*(p: var VibQcProfile; h: VibHundred) =
  ## `h` as the project's one 100 % force (an empty one clears it).
  p.forceHundredPct = h.pct
  p.forceHundredUnit = h.unit
  p.forceHundredSet = h.accelSet
  p.forceHundredSetKnown = h.setKnown
  p.hundredHow = h.how
  p.hundredAtPct = h.atPct
  p.hundredFile = h.file
  p.hundredVibrator = h.vibrator

func sameKind*(a, b: VibHundred): bool =
  ## Whether two values are the same force: the same number in the same unit and, in
  ## pound-counts (the one unit that depends on the accelerometer set), the same set.
  sameFloat(a.pct, b.pct) and a.unit == b.unit and (a.unit != "pound-counts" or
    a.setKnown == b.setKnown and (not a.setKnown or a.accelSet == b.accelSet))

func takeOlder*(p: var VibQcProfile) =
  ## Reads what an older document kept, in `forceHundredPct` and `olderHundreds` (a value per
  ## vibrator): one value, or values that all agree (the same number, unit and set), are the
  ## project's one 100 % force. Values that differ are taken as none: the profile has no 100 %
  ## force, and keeps them as read until one is set again.
  var all = p.olderHundreds
  let single = p.hundredOf
  if not single.pct.isNaN: all.insert(single, 0)
  if all.len > 0:
    var agree = true
    for h in all:
      if not sameKind(h, all[0]): agree = false
    if agree:
      p.olderHundreds = @[]
      if single.pct.isNaN: p.setHundred(all[0])
    elif not single.pct.isNaN:
      p.olderSingle = single
      p.setHundred(VibHundred())

const MaxConflictNames* = 8
  ## the vibrators the conflict sentence names at most; the rest are counted

func hundredConflict*(p: VibQcProfile): string =
  ## The sentence for a project whose older document kept 100 % forces that differ, so that it
  ## has none until one is set from a sweep; "" when there is nothing to say. It names at most
  ## `MaxConflictNames` vibrators and counts the others, however many the document kept.
  if p.forceHundredPct.isNaN and p.olderHundreds.len > 0:
    let shown = min(p.olderHundreds.len, MaxConflictNames)
    let more = p.olderHundreds.len - shown
    let last = more == 0 and p.olderSingle.pct.isNaN # (the last name follows "and")
    var words = if p.olderHundreds.len == 1: "vibrator " else: "vibrators "
    for i in 0 ..< shown:
      if i > 0: words.add(if i == shown - 1 and last: " and " else: ", ")
      words.add $p.olderHundreds[i].vibrator
    if more > 0: words.add " and " & $more & (if more == 1: " other" else: " others")
    elif not p.olderSingle.pct.isNaN: words.add " and the others"
    result = "This project kept different 100 % forces for " & words &
      "; it now keeps one: set it again from a sweep."

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
    sameFloat(a.forceHundredWeighted, b.forceHundredWeighted) and
    a.hundredHow == b.hundredHow and sameFloat(a.hundredAtPct, b.hundredAtPct) and
    a.hundredFile == b.hundredFile and a.hundredVibrator == b.hundredVibrator and
    sameHundreds(a.olderHundreds, b.olderHundreds) and sameHundred(a.olderSingle, b.olderSingle)

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
  # (a unit or set that moves with no value given is no change of a value)
  let hundredChanged = not sameFloat(had.forceHundredPct, now.forceHundredPct) or
    not now.forceHundredPct.isNaN and (had.forceHundredUnit != now.forceHundredUnit or
      had.forceHundredSet != now.forceHundredSet or
      had.forceHundredSetKnown != now.forceHundredSetKnown or
      had.hundredHow != now.hundredHow or had.hundredFile != now.hundredFile or
      had.hundredVibrator != now.hundredVibrator)
  if hundredChanged:
    # the one 100 % force, whatever vibrator's sweep it was set on; what an older document
    # kept per vibrator goes
    result.setHundred(now.hundredOf)
    result.olderHundreds = @[]
    result.olderSingle = VibHundred()
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
    madeBaseplateKg = NaN; forceHundredWeighted = NaN; hundredHow = hhTyped;
    hundredAtPct = NaN; hundredVibrator = 0; forceHundredSetKnown = true;
    hundredFile = ""): VibQcProfile =
  ## The profile a Vibrator window is using. Pass that window's values, not a
  ## signature file's built-in reset (which clears a typed 100 % force and drive
  ## level). `referenceId` is the archive id, never samples. `topHz` is the top
  ## typed for that reference; NaN when none is. A 100 % force or drive level
  ## left NaN was not typed. `forceHundredUnit` is the unit that force was typed
  ## in; empty when none was said. `forceHundredSet` is the accelerometer set a
  ## pound-counts force was typed on; the window's, so it is known unless the window took
  ## the value from a project that did not record it (`forceHundredSetKnown`). `fromFile`
  ## names the file the window showed. `judge` is the ground force switch, with the masses
  ## (weights) and the 100 % force it needs. `hundredFile` and `hundredVibrator` say which
  ## sweep a 100 % force was set on.
  VibQcProfile(limits: limits, qcWindowMs: qcWindowMs, harmonics: harmonics,
    accelSet: accelSet, forceScale: scale, forceHundredPct: forceHundredPct,
    forceHundredUnit: forceHundredUnit, forceHundredSet: forceHundredSet,
    forceHundredSetKnown: forceHundredSetKnown, targetPct: targetPct,
    referenceId: referenceId, topHz: topHz, fromFile: fromFile, judge: judge,
    madeReactionKg: madeReactionKg, madeBaseplateKg: madeBaseplateKg,
    forceHundredWeighted: forceHundredWeighted, hundredHow: hundredHow,
    hundredAtPct: hundredAtPct, hundredFile: hundredFile, hundredVibrator: hundredVibrator)

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
    forceHundredSetKnown: p.forceHundredSetKnown, judge: p.judge,
    hundredConflict: p.hundredConflict)
  # the masses and the made signal's own 100 % force go to the run whatever the profile judges:
  # a file layout may have its own choice, as its window does
  result.options.reactionMassKg = p.madeReactionKg
  result.options.baseplateMassKg = p.madeBaseplateKg
  result.options.forceHundredWeighted = p.forceHundredWeighted
  if p.referenceId.len == 0 or p.referenceId notin archiveIds:
    result.problems.add referenceProblem(p.referenceId)
  if not typedForce(p.forceHundredPct):
    result.options.forceHundredPct = NaN
