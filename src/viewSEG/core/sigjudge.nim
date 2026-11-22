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
    hundredHint*: string ## what to type for the file to give `hundredN` ("" when it does)
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

func eq(x, y: float64): bool = x == y or (x.isNaN and y.isNaN)

func sameWeights(a, b: VibWeights): bool =
  ## The three weights alike (the sensitivities apart).
  eq(a.holdDownLb, b.holdDownLb) and eq(a.baseplateLb, b.baseplateLb) and eq(a.massLb, b.massLb)

func sameSensitivities(a, b: VibWeights): bool =
  eq(a.sensitivity1, b.sensitivity1) and eq(a.sensitivity2, b.sensitivity2)

func same(a, b: VibWeights): bool = sameWeights(a, b) and sameSensitivities(a, b)

type
  WeightSet* = tuple[weights: VibWeights; sweeps: int]

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
    twoDiffer*: bool                 ## exactly two vibrators, stating different weights
    flagged*: bool                   ## any finding

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

func perVibrator*(sweeps: openArray[tuple[vibrator: int; weights: VibWeights]]): FleetWeights =
  ## The `.vib` header weights grouped per vibrator (0: not known: counted, never grouped or
  ## compared). A vibrator whose sweeps state different weights, whose weights differ from those
  ## the others share (three or more vibrators), or two vibrators that differ, is a finding for
  ## the user, in words; nothing is corrected. A difference in sensitivity alone is told as such.
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
  for i in 0 ..< main.len:
    result.vibrators[i].unlike = oddOne(main, i, sameWeights)
    result.vibrators[i].sensUnlike = not result.vibrators[i].unlike and
      oddOne(main, i, sameSensitivities)
  result.twoDiffer = main.len == 2 and not sameWeights(main[0], main[1])
  result.flagged = result.twoDiffer
  for e in result.vibrators:
    if e.differs or e.sensDiffers or e.unlike or e.sensUnlike: result.flagged = true

func twoDifferWords*(f: FleetWeights): string =
  ## The finding for exactly two vibrators that state different weights; "" otherwise. It does
  ## not say which is the odd one.
  if f.twoDiffer:
    "The two vibrators state different weights: one of the controllers may be set up for " &
      "another vibrator type; the headers do not say which"
  else: ""

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
