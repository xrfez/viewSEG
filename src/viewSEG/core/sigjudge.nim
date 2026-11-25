## What the Vibrator window adds for a vibrator controller's signature file (a `.dat` or a
## `.vib`): the report on the ground force's polarity against the reference (reported, never
## changed), the controller's own QC numbers beside viewSEG's, the force scale, and the
## header weights a `.vib` states (per sweep, and per vibrator across a folder, where a
## mismatch is a finding in words only: nothing is corrected or rescaled from it).
##
## Pure: numbers in, words out.

import std/[algorithm, math, strutils, tables]
import sigtypes, sigvib, units, vibjudge

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
    hundredHint*: string ## what to type for the file to give `hundredN` ("" when it does)
    ctlFrom*: string ## "this file" / "the .dat of this sweep"; "" when there is no QC record
    ctl*: SweepQc
    correlationStored*: bool
    correlationLagZero*: int
    setA*: bool ## a `.vib` judged on accelerometer set A
    madeReaction*, madeBaseplate*: float64 = NaN
      ## the weights the ground force is made from M and B with, as the file stands: a
      ## `.dat`'s two force channels are weighted already (1 and 1: their plain sum), a
      ## `.vib`'s are its header's (pounds); NaN: none

const
  VibSetAMassCode* = 258'i16        ## a .vib's reaction-mass acceleration, set A
  VibSetABaseplateCode* = 257'i16   ## ... baseplate acceleration, set A
  VibSetAGroundForceCode* = 267'i16 ## ... the ground force computed from set A
  MinPolarityPoints = 8
  WeakConsistency = 0.5
  InPhaseWithinDeg = 45.0
  OppositeWithinDeg = 135.0

proc applyFileScale*(into: var SignatureAsk; kind: SignatureKind;
    datCountsPerLbf, vibAccMvPerCount: float64; weights: VibWeights; setA: bool;
    qcValid: bool; targetForceLbf: int; targetPct: float64) =
  ## The force scale and the file's own 100 % force, as the Vibrator window
  ## sets them. A `.dat` takes 100 % from the controller's target force when a
  ## drive level was typed. A `.vib` takes 100 % from the header hold-down when
  ## the accelerometer constant is set.
  case kind
  of sgDat: (into.madeReaction, into.madeBaseplate) = (1.0, 1.0)
  of sgVib: (into.madeReaction, into.madeBaseplate) = (weights.massLb, weights.baseplateLb)
  of sgNone: discard
  case kind
  of sgDat:
    if datCountsPerLbf > 0 and datCountsPerLbf < Inf:
      into.gfToN = NPerLbf / datCountsPerLbf
      into.scaleWords = sensible(datCountsPerLbf) & " counts per lbf"
      if qcValid and targetForceLbf > 0:
        if targetPct > 0 and targetPct < Inf:
          into.hundredN = float64(targetForceLbf) * 100 / targetPct * NPerLbf
          into.hundredWords = "100 % from the controller's target force (" &
            $targetForceLbf & " lbf at " & sensible(targetPct) &
            " % of the full scale)"
        else:
          into.hundredHint = "type the drive level the sweep was set to (Target force " &
            "%): 100 % is then the controller's target force (" & $targetForceLbf & " lbf)"
  of sgVib:
    if vibAccMvPerCount > 0 and vibAccMvPerCount < Inf:
      let factor = gfPoundForcePerPoundCount(weights, setA, vibAccMvPerCount)
      if factor > 0 and factor < Inf:
        into.gfToN = factor * NPerLbf
        into.scaleWords = "accelerometer constant " & sensible(vibAccMvPerCount)
        let hold = weights.holdDownLb
        if hold > 0 and hold < Inf:
          into.hundredN = hold * NPerLbf
          into.hundredWords = "100 % from the file's hold-down weight (" &
            sensible(hold) & " lb)"
  of sgNone: discard

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

func controllerRows*(s: SignatureAsk; q: QcStats; hundred: float64;
    forceComparable: bool): seq[ControllerRow] =
  ## The controller's QC numbers beside viewSEG's: one row per measure. Empty when the file
  ## has none. `forceComparable`: viewSEG's 100 % is the file's own (the target force, the
  ## hold-down weight), so the force percentages compare one to one. The controller's force
  ## numbers are % of the hold-down weight, so viewSEG's are given on that base too: % of
  ## `hundred`, the 100 % force, whatever the drive level (the limits table's average and
  ## minimum are % of the target).
  if s.ctlFrom.len == 0 or not s.ctl.valid: return
  let c = s.ctl
  func pct(x: int16): string = (if x < 0: "—" else: $x & " %")
  func mine(x: float64; digits = 0): string =
    if x.isNaN: "—" else: formatFloat(x, ffDecimal, digits) & " %"
  let noScale = if s.isDat: "set 100 % from the controller's target force to compare"
                else: "needs the accelerometer constant: 100 % is then the file's hold-down weight"
  func force(label: string; ctl: int16; own: float64): ControllerRow =
    let ok = forceComparable and hundred > 0 and hundred < Inf
    ControllerRow(label: label, controller: pct(ctl),
      viewseg: (if ok: mine(100 * own / hundred) else: "—"),
      tip: (if ok: "% of the hold-down weight (the 100 % force), whatever the target level"
      else: s.hundredHint & (if s.hundredHint.len > 0: ". " else: "") & noScale))
  result.add force("Force, max (% of hold-down)", c.forceMaxPct, q.peakForce)
  result.add force("Force, min (% of hold-down)", c.forceMinPct, q.minForce)
  result.add force("Force, average (% of hold-down)", c.forceAvgPct, q.avgForce)
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
  let tripped = limitsWords(c.limits, "\n") # (a line each: the column stays narrow)
  result.add ControllerRow(label: "Limits tripped", viewseg: "—",
    controller: (if tripped.len == 0: "none" else: tripped),
    tip: "the controller's limit letters. " & LimitsProbable)

func controllerNote*(s: SignatureAsk): string =
  ## The words above the table: where the numbers are from, and for a `.vib` judged on set B
  ## which set the controller follows.
  if s.ctlFrom.len == 0: return
  result = "The controller's QC numbers, from " & s.ctlFrom & ", beside this window's"
  if not s.isDat and not s.setA:
    result.add ". The controller's QC report follows set A (probable): choose set A to " &
      "compare like with like"

# ---------------------------------------------------------------- weights --

func massesText(w: VibWeights): string =
  ## "Hold-down 12 000 lb, baseplate 4 000 lb, reaction mass 9 000 lb".
  func lb(x: float64): string = (if x.isNaN: "not stated" else: groupDigits(int64(round(x))) & " lb")
  "Hold-down " & lb(w.holdDownLb) & ", baseplate " & lb(w.baseplateLb) & ", reaction mass " &
    lb(w.massLb)

func sensitivitiesText(w: VibWeights): string =
  ## "accelerometer sensitivities 10.200 and 10.200".
  func sens(x: float64): string = (if x.isNaN: "not stated" else: formatFloat(x, ffDecimal, 3))
  "accelerometer sensitivities " & sens(w.sensitivity1) & " and " & sens(w.sensitivity2)

func weightsText*(w: VibWeights): string =
  ## "Hold-down 12 000 lb, baseplate 4 000 lb, reaction mass 9 000 lb; accelerometer
  ## sensitivities 10.200 and 10.200 (which sensor is not known)".
  massesText(w) & "; " & sensitivitiesText(w) & " (which sensor is not known)"

const WeightsDepend* = "The reference scaled to a force is the counts times the header's " &
  "hold-down weight over full scale: it depends on the hold-down weight, which differs with " &
  "the vibrator type the controller's electronics are set up for. Nothing is corrected or " &
  "rescaled from these weights."

func eq(x, y: float64): bool = x == y or (x.isNaN and y.isNaN)

func sameWeights(a, b: VibWeights): bool =
  ## The three weights alike (the sensitivities apart).
  eq(a.holdDownLb, b.holdDownLb) and eq(a.baseplateLb, b.baseplateLb) and eq(a.massLb, b.massLb)

func sameSensitivities(a, b: VibWeights): bool =
  eq(a.sensitivity1, b.sensitivity1) and eq(a.sensitivity2, b.sensitivity2)

func same(a, b: VibWeights): bool = sameWeights(a, b) and sameSensitivities(a, b)

type
  WeightSet* = tuple[weights: VibWeights; sweeps: int]

  FleetSet* = tuple[weights: VibWeights; vibrators: seq[int]]
    ## one set of weights (or of sensitivities) the vibrators state, and the vibrators that
    ## state it

  VibratorWeights* = object
    ## The weights one vibrator's sweeps state across a folder.
    vibrator*: int
    sweeps*: int
    kinds*: seq[WeightSet] ## the sets, the most used first
    differs*: bool         ## its sweeps state different weights (changing between sweeps)
    sensDiffers*: bool     ## its weights are alike but not its sensitivities
    unlike*: bool          ## its main weights are not those the other vibrators share
    sensUnlike*: bool      ## its main sensitivities are not those the other vibrators share

  FleetWeights* = object
    ## The `.vib` header weights of a folder, per vibrator.
    vibrators*: seq[VibratorWeights] ## vibrators known (from their `.dat`), by number
    unknown*: int                    ## sweeps whose vibrator is not known: listed, never compared
    weightSets*: seq[FleetSet]
      ## the vibrators' weights are not all alike and no single odd one can be named (two
      ## vibrators, three all different, two and two...): each set and who states it
    sensSets*: seq[FleetSet]
      ## the same for the accelerometer sensitivities, when the weights are all alike
    flagged*: bool ## any finding

func oddOne(main: openArray[VibWeights]; i: int; alike: proc (a,
    b: VibWeights): bool {.noSideEffect.}): bool =
  ## Whether `main[i]` is alike to none of the others while some two others are alike (so the
  ## odd one can be told; with only two vibrators nobody can say which one is odd).
  if main.len < 3: return false
  var shared = false
  for a in 0 ..< main.len:
    for b in a + 1 ..< main.len:
      if a != i and b != i and alike(main[a], main[b]): shared = true
  if not shared: return false
  for j in 0 ..< main.len:
    if j != i and alike(main[i], main[j]): return false
  true

func setsOf(vibrators: openArray[VibratorWeights]; alike: proc (a,
    b: VibWeights): bool {.noSideEffect.}): seq[FleetSet] =
  ## The vibrators' main weights grouped by `alike`, in the order first stated.
  result = @[]
  for e in vibrators:
    let w = e.kinds[0].weights
    var at = -1
    for j, s in result:
      if at < 0 and alike(s.weights, w): at = j
    if at < 0: result.add (w, @[e.vibrator])
    else: result[at].vibrators.add e.vibrator

func perVibrator*(sweeps: openArray[tuple[vibrator: int; weights: VibWeights]]): FleetWeights =
  ## The `.vib` header weights grouped per vibrator (0: not known: counted, never grouped or
  ## compared). A vibrator whose sweeps state different weights, or the single one whose weights
  ## differ from those the others share, is a finding for the user, in words; when no single
  ## odd one can be named the sets the vibrators state are the finding (`weightSets`). Nothing
  ## is corrected. A difference in sensitivity alone is told as such (`sensSets`).
  var byV = initOrderedTable[int, VibratorWeights]()
  for (v, w) in sweeps:
    if w.holdDownLb.isNaN and w.baseplateLb.isNaN and w.massLb.isNaN: continue
    if v <= 0:
      inc result.unknown
      continue
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
    e.kinds.sort(proc(a, b: WeightSet): int = cmp(b.sweeps, a.sweeps))
    for k in e.kinds:
      if not sameWeights(k.weights, e.kinds[0].weights): e.differs = true
      elif not sameSensitivities(k.weights, e.kinds[0].weights): e.sensDiffers = true
    result.vibrators.add e
  result.vibrators.sort(proc(a, b: VibratorWeights): int = cmp(a.vibrator, b.vibrator))
  var main: seq[VibWeights] = @[]
  for e in result.vibrators: main.add e.kinds[0].weights
  var odd, sensOdd = 0
  for i in 0 ..< main.len:
    result.vibrators[i].unlike = oddOne(main, i, sameWeights)
    result.vibrators[i].sensUnlike = not result.vibrators[i].unlike and
      oddOne(main, i, sameSensitivities)
    if result.vibrators[i].unlike: inc odd
    if result.vibrators[i].sensUnlike: inc sensOdd
  let sets = setsOf(result.vibrators, sameWeights)
  if sets.len > 1 and odd != 1:
    # no single odd one: the sets are the finding, nobody is named
    result.weightSets = sets
    for e in result.vibrators.mitems: e.unlike = false
  elif sets.len == 1:
    let sens = setsOf(result.vibrators, sameSensitivities)
    if sens.len > 1 and sensOdd != 1:
      result.sensSets = sens
      for e in result.vibrators.mitems: e.sensUnlike = false
  result.flagged = result.weightSets.len > 0 or result.sensSets.len > 0
  for e in result.vibrators:
    if e.differs or e.sensDiffers or e.unlike or e.sensUnlike: result.flagged = true

func vibratorsText(v: openArray[int]): string =
  ## "Vibrator 11", "Vibrators 11 and 12", "Vibrators 11, 12 and 13".
  result = if v.len == 1: "Vibrator " else: "Vibrators "
  for i, n in v:
    if i > 0: result.add(if i == v.high: " and " else: ", ")
    result.add $n

func setsWords*(f: FleetWeights): seq[string] =
  ## The finding when the vibrators state different sets of weights (or, the weights alike, of
  ## sensitivities) and no single odd one can be named: a line that says how many sets, then a
  ## line per set with the vibrators that state it. It names no odd one; empty otherwise.
  if f.weightSets.len > 0:
    result.add "The vibrators state " & $f.weightSets.len & " different sets of weights: a " &
      "controller may be set up for another vibrator type; the headers do not say which"
    for s in f.weightSets: result.add vibratorsText(s.vibrators) & ": " & massesText(s.weights)
  elif f.sensSets.len > 0:
    result.add "The vibrators state " & $f.sensSets.len & " different sets of accelerometer " &
      "sensitivities (their weights are alike)"
    for s in f.sensSets:
      result.add vibratorsText(s.vibrators) & ": " & sensitivitiesText(s.weights)

func unknownWords*(n: int): string =
  ## The line for sweeps whose vibrator is not known.
  if n > 0:
    $n & (if n == 1: " sweep" else: " sweeps") & " of a vibrator that is not known (no .dat " &
      "of its sweep listed): listed, not compared"
  else: ""

func vibratorWords*(v: VibratorWeights): string =
  ## One vibrator's line: its weights, and the finding when it has one.
  result = "Vibrator " & $v.vibrator & " (" & $v.sweeps &
    (if v.sweeps == 1: " sweep" else: " sweeps") & "): " & weightsText(v.kinds[0].weights)
  if v.differs:
    let rest = v.sweeps - v.kinds[0].sweeps
    result.add ". Its sweeps state " & $v.kinds.len & " different sets of weights (" &
      $v.kinds[0].sweeps & (if v.kinds[0].sweeps == 1: " sweep states" else: " sweeps state") &
      " one set, " & $rest & (if rest == 1: " sweep states" else: " sweeps state") &
      " the other" & (if v.kinds.len > 2: "s" else: "") & "): the controller's set-up " &
      "changed between sweeps, or a sweep was set up for another vibrator type"
  elif v.sensDiffers:
    result.add ". Its sweeps state different accelerometer sensitivities (the weights are alike)"
  if v.unlike:
    result.add ". Its weights differ from those the other vibrators state: the controller " &
      "may be set up for the wrong vibrator type"
  elif v.sensUnlike:
    result.add ". Its accelerometer sensitivities differ from those the other vibrators state"
