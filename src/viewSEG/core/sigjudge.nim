## What the Vibrator window adds for a vibrator controller's signature file (a `.dat` or a
## `.vib`): the report on the ground force's polarity against the reference (reported, never
## changed), the controller's own QC numbers beside viewSEG's, the force scale, and the
## header weights a `.vib` states (per sweep, and per vibrator across a folder, where a
## mismatch is a finding in words only: nothing is corrected or rescaled from it).
##
## Pure: numbers in, words out.

import std/[algorithm, math, strutils, tables]
import sigtypes, vibjudge

type
  AccelSet* = enum
    ## The two accelerometer sets of a `.vib`: B is the set the `.dat` file records (the
    ## default); A is the set the controller's QC report follows (probable).
    asB = "B"
    asA = "A"

  PolarityKind* = enum
    pkUnknown = "unknown"
    pkInPhase = "in phase"
    pkOpposite = "opposite"
    pkOther = "neither"
    pkUnclear = "unclear"

  PolarityReport* = object
    ## The ground force's relation to the reference over the judged part, as recorded.
    kind*: PolarityKind
    meanPhaseDeg*: float64 = NaN ## the circular mean, as recorded, in (-180, 180]
    consistency*: float64 = NaN
      ## the mean resultant length of the phases (1: they all agree; near 0: no relation)
    reversed*: bool              ## the analysis reverses the ground force, by the user's choice
    line*: string                ## the words, one line

  ControllerRow* = object
    label*, viewseg*, controller*, tip*: string

  SignatureAsk* = object
    ## What a signature file adds to a vibrator ask. `given` false: any other file.
    given*, isDat*: bool
    gfToN*: float64 = NaN
      ## the factor that turns the ground force's samples (counts, or pound-counts) into
      ## newtons, from the user's scale; NaN: none given, the force stays as recorded
    scaleWords*: string ## "8 counts per lbf" / "the accelerometer constant 12.5": "" for none
    hundredN*: float64 = NaN
      ## the force that is 100 % when the user typed none, from the file itself (the
      ## controller's target force, the header's hold-down weight), in newtons
    hundredWords*: string ## where `hundredN` comes from
    ctlFrom*: string ## "this file" / "the .dat of this sweep"; "" when there is no QC record
    ctl*: SweepQc
    correlationStored*: bool
    correlationLagZero*: int
    setA*: bool ## a `.vib` judged on accelerometer set A

const
  VibSetAMassCode* = 258'i16        ## a .vib's reaction-mass acceleration, set A
  VibSetABaseplateCode* = 257'i16   ## ... baseplate acceleration, set A
  VibSetAGroundForceCode* = 267'i16 ## ... the ground force computed from set A
  MinPolarityPoints = 8
  WeakConsistency = 0.5
  InPhaseWithinDeg = 45.0
  OppositeWithinDeg = 135.0

func wrapDeg(x: float64): float64 =
  result = x
  while result > 180: result -= 360
  while result <= -180: result += 360

func degText(x: float64): string =
  let r = int(round(x))
  (if r < 0: "−" & $(-r) else: $r) & "°"

func polarityOf*(phasesDeg: openArray[float64]; reversed, byUser: bool;
    s: SignatureAsk): PolarityReport =
  ## The report from the phases of the ground force to the reference as the analysis got them
  ## (`reversed`: the analysis turned the ground force over, so the phase as recorded is half
  ## a turn from these; `byUser`: it was the user's choice, not the Automatic polarity of a
  ## SEG-Y window). NaN phases are left out.
  var (sx, sy, n) = (0.0, 0.0, 0)
  for p in phasesDeg:
    if not p.isNaN:
      sx += cos(degToRad(p))
      sy += sin(degToRad(p))
      inc n
  result.reversed = reversed
  if n < MinPolarityPoints:
    result.kind = pkUnclear
    result.line = "Ground force against the reference: unclear: no part of the sweep could " &
      "be compared with the reference"
    return
  result.consistency = sqrt(sx * sx + sy * sy) / float64(n)
  var mean = radToDeg(arctan2(sy, sx))
  if reversed: mean += 180
  result.meanPhaseDeg = wrapDeg(mean)
  let size = abs(result.meanPhaseDeg)
  result.kind = if result.consistency < WeakConsistency: pkUnclear
    elif size <= InPhaseWithinDeg: pkInPhase
    elif size >= OppositeWithinDeg: pkOpposite
    else: pkOther
  let head = "Ground force against the reference: "
  if result.kind == pkUnclear:
    result.line = head & "unclear: the ground force follows the reference weakly (phase " &
      "consistency " & formatFloat(result.consistency, ffDecimal, 2) & ")"
  else:
    let words = case result.kind
      of pkInPhase: "in phase"
      of pkOpposite: "opposite"
      else: "neither in phase nor opposite"
    # (an opposite ground force is half a turn off either way round: its size is told)
    let shown = if result.kind == pkOther: " (mean phase " & degText(result.meanPhaseDeg) &
        ")" elif result.kind == pkOpposite: " (mean phase " & degText(abs(result.meanPhaseDeg)) &
        ")" else: " (" & degText(result.meanPhaseDeg) & ")"
    if reversed:
      result.line = head & words & " as recorded" & shown &
        (if byUser: "; reversed for the analysis, as you chose"
          else: "; reversed for the analysis by the Automatic polarity")
    else:
      result.line = head & words & shown
  if s.isDat and s.correlationStored and result.kind != pkUnclear:
    let v = s.correlationLagZero
    let sign = if v < 0: "negative" elif v > 0: "positive" else: "zero"
    result.line.add ". The controller's own correlation has its peak at lag 0 " & sign & " (" &
      (if v < 0: "−" & $(-v) else: $v) & ")"
    if result.kind == pkOpposite and v < 0:
      result.line.add ": it records the same relation and counts it as in phase"
    elif result.kind == pkOpposite and v > 0:
      result.line.add ": it counts the relation the other way from this analysis"

func controllerRows*(s: SignatureAsk; q: QcStats; forceComparable: bool): seq[ControllerRow] =
  ## The controller's QC numbers beside viewSEG's: one row per measure. Empty when the file
  ## has none. `forceComparable`: viewSEG's 100 % is the file's own (the target force, the
  ## hold-down weight), so the force percentages compare one to one.
  if s.ctlFrom.len == 0 or not s.ctl.valid: return
  let c = s.ctl
  func pct(x: int16): string = (if x < 0: "—" else: $x & " %")
  func mine(x: float64; digits = 0): string =
    if x.isNaN: "—" else: formatFloat(x, ffDecimal, digits) & " %"
  let noScale = if s.isDat: "set 100 % from the controller's target force to compare"
                else: "needs the accelerometer constant: 100 % is then the file's hold-down weight"
  func force(label: string; ctl: int16; own: float64): ControllerRow =
    ControllerRow(label: label, controller: pct(ctl),
      viewseg: (if forceComparable: mine(own) else: "—"),
      tip: (if forceComparable: "" else: noScale))
  result.add force("Force, max", c.forceMaxPct, q.peakForcePct)
  result.add force("Force, min", c.forceMinPct, q.minForcePct)
  result.add force("Force, average", c.forceAvgPct, q.avgForcePct)
  const thd = "the controller's distortion is defined differently (not reproduced): compare " &
    "its trend, not its value"
  result.add ControllerRow(label: "THD, max", controller: pct(c.thdMaxPct),
    viewseg: mine(q.peakDistortionPct, 1), tip: thd)
  result.add ControllerRow(label: "THD, average", controller: pct(c.thdAvgPct),
    viewseg: mine(q.avgDistortionPct, 1), tip: thd)
  result.add ControllerRow(label: "Phase, max",
    controller: (if c.phaseMaxDeg.isNaN: "—" else: formatFloat(c.phaseMaxDeg, ffDecimal, 1) &
      "°"), viewseg: (if q.peakPhaseDeg.isNaN: "—" else: formatFloat(q.peakPhaseDeg,
      ffDecimal, 1) & "°"),
    tip: "compares once the polarity is as the controller treats it (see the line above)")
  var tripped = ""
  for l in c.limits: tripped.add $l
  result.add ControllerRow(label: "Limits tripped", viewseg: "—",
    controller: (if tripped.len == 0: "none" else: tripped),
    tip: "the controller's limit letters; their meanings are not known")

func controllerNote*(s: SignatureAsk): string =
  ## The words above the table: where the numbers are from, and for a `.vib` judged on set B
  ## which set the controller follows.
  if s.ctlFrom.len == 0: return
  result = "The controller's QC numbers, from " & s.ctlFrom & ", beside this window's"
  if not s.isDat and not s.setA:
    result.add ". The controller's QC report follows set A (probable): choose set A to " &
      "compare like with like"

# ---------------------------------------------------------------- weights --

func weightsText*(w: VibWeights): string =
  ## "Hold-down 12 000 lb, baseplate 4 000 lb, reaction mass 9 000 lb; accelerometer
  ## sensitivities 10.2 and 10.2 (which sensor is not known)".
  func lb(x: float64): string = (if x.isNaN: "not stated" else: groupDigits(int64(round(x))) & " lb")
  func sens(x: float64): string = (if x.isNaN: "not stated" else: formatFloat(x, ffDecimal, 3))
  "Hold-down " & lb(w.holdDownLb) & ", baseplate " & lb(w.baseplateLb) & ", reaction mass " &
    lb(w.massLb) & "; accelerometer sensitivities " & sens(w.sensitivity1) & " and " &
    sens(w.sensitivity2) & " (which sensor is not known)"

const WeightsDepend* = "The reference scaled to a force is the counts times the header's " &
  "hold-down weight over full scale: it depends on the hold-down weight, which differs with " &
  "the vibrator type the controller's electronics are set up for. Nothing is corrected or " &
  "rescaled from these weights."

func same(a, b: VibWeights): bool =
  func eq(x, y: float64): bool = x == y or (x.isNaN and y.isNaN)
  eq(a.holdDownLb, b.holdDownLb) and eq(a.baseplateLb, b.baseplateLb) and
    eq(a.massLb, b.massLb) and eq(a.sensitivity1, b.sensitivity1) and
    eq(a.sensitivity2, b.sensitivity2)

type
  VibratorWeights* = object
    ## The weights one vibrator's sweeps state across a folder.
    vibrator*: int                                       ## 0: sweeps whose vibrator is not known (grouped as one)
    sweeps*: int
    kinds*: seq[tuple[weights: VibWeights; sweeps: int]] ## the sets, the most used first
    differs*: bool                                       ## its sets are not all alike (changing between sweeps)
    unlike*: bool                                        ## its main set is not the main set of the other vibrators

func perVibrator*(sweeps: openArray[tuple[vibrator: int; weights: VibWeights]]):
    seq[VibratorWeights] =
  ## The `.vib` header weights grouped per vibrator. A vibrator whose sets are not all alike,
  ## or whose main set is not one that any other vibrator's main set is, is flagged: a finding
  ## for the user, never a correction.
  var byV = initOrderedTable[int, VibratorWeights]()
  for (v, w) in sweeps:
    if w.holdDownLb.isNaN and w.baseplateLb.isNaN and w.massLb.isNaN: continue
    var e = byV.getOrDefault(v, VibratorWeights(vibrator: v))
    inc e.sweeps
    var found = false
    for d in e.kinds.mitems:
      if same(d.weights, w):
        inc d.sweeps
        found = true
        break
    if not found: e.kinds.add (w, 1)
    byV[v] = e
  for v, e in byV.mpairs:
    e.kinds.sort(proc(a, b: tuple[weights: VibWeights; sweeps: int]): int = cmp(b.sweeps, a.sweeps))
    e.differs = e.kinds.len > 1
    result.add e
  result.sort(proc(a, b: VibratorWeights): int = cmp(a.vibrator, b.vibrator))
  if result.len > 1:
    for i in 0 ..< result.len:
      var others = false
      var alike = false
      for j in 0 ..< result.len:
        if j != i:
          others = true
          if same(result[i].kinds[0].weights, result[j].kinds[0].weights): alike = true
      result[i].unlike = others and not alike
  # a set that no other vibrator shares is only a finding when some other vibrators share one
  var shared = false
  for i in 0 ..< result.len:
    for j in i + 1 ..< result.len:
      if same(result[i].kinds[0].weights, result[j].kinds[0].weights): shared = true
  if not shared:
    for e in result.mitems: e.unlike = false

func vibratorWords*(v: VibratorWeights): string =
  ## One vibrator's line: its weights, and the finding when it has one.
  result = (if v.vibrator > 0: "Vibrator " & $v.vibrator else: "Vibrator not known") & " (" &
    $v.sweeps & (if v.sweeps == 1: " sweep" else: " sweeps") & "): " &
    weightsText(v.kinds[0].weights)
  if v.differs:
    result.add ". Its sweeps state " & $v.kinds.len & " different sets of weights (" &
      $v.kinds[0].sweeps & " of one, the others of " & $(v.sweeps - v.kinds[0].sweeps) &
      " sweeps): the controller's set-up changed between sweeps, or a sweep was set up for " &
      "another vibrator type"
  if v.unlike:
    result.add ". Its weights differ from those the other vibrators state: the controller " &
      "may be set up for the wrong vibrator type"
