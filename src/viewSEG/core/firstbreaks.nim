## The first-break overlay's data: for each trace of a record, the time of
## the first break as picked (processSEG's `qc/firstbreak`) and the time a
## refraction model fitted to the confident picks expects it at the trace's
## source-receiver offset (processSEG's `qc/shotfit`, `ShotFit.modelMs`).
## Both are in ms on the record's time axis, NaN where unknown; the lists
## are indexed by the trace's place in the file less `first`, so they hold
## whatever order the plot shows the traces in.
##
## The job that makes them is `core/firstbreakjobs`. Nothing here reads a
## file or draws: the view maps these times to the plot's traces and
## the cursor readout (`readoutText`) tells them in words.
##
## - A trace with no pick has only the model time; a trace the model cannot
##   place (no offset, or too few confident picks to fit) only the pick.
## - The offsets are the trace keys': the survey's when one is joined to
##   the file (`bsSurvey`), else the headers' own, or derived from the
##   file's own coordinates (`bsFile`); with neither (`bsNone`) there is no
##   model and `modelNote` says what is missing.
## - What the model is, in words (`modelWords`, for the key's tooltip) and as
##   numbers (`velocityUnit`, `segments`): a refraction fit to the record's own
##   picks, its velocity or velocities in the offsets' unit per second.

import std/[math, strutils]
import parseSEG
import processSEG/qc/[firstbreak, shotfit]
import breakmodel, breakrule, components, jobs, join, session

export breakrule

type
  BreakSource* = enum
    ## Where the offsets the model used came from.
    bsNone = "none"     ## no trace has an offset
    bsSurvey = "survey" ## the imported survey's (a join derived them)
    bsFile = "file"     ## the file's own headers, or its own coordinates

  BreakState* = enum
    bkComputing, bkDone, bkFailed

  GuideState* = enum
    ## Whether the picks shown were guided by the model shown (`shownBreaks` in the state
    ## shows another model's picks while those of the one asked for are made, or could not be).
    gdOwn ## guided by the model shown (or by the record's fit, when it is fitted)
    gdMaking ## guided by another model; the picks guided by this one are being made
    gdFailed ## guided by another model; picking for this one failed or was stopped

  BreakKey* = tuple[file: SessionId; gather, keys: int; killed: seq[int]; off: seq[uint8];
      guide: BreakModel; pick: PickBasis]
    ## What a result is of: the record, the file's keys as they were read
    ## (a join or a header edit changes them), the traces killed in it, the
    ## components the panel's filter switches off (which traces a node
    ## record's model is fitted from, `fitMask`), and the given model that
    ## guides the second pass of picking (`BreakModel()` when none is given).

  FirstBreaks* = object
    ## One record's first breaks, as its job found them.
    job*: JobId = NoJob       ## the job making it; `NoJob` once it has ended
    key*: BreakKey
    state*: BreakState
    first*: int               ## the file's trace number of the record's first trace
    pickMs*: seq[float64]     ## per trace of the record; NaN for no pick
    modelMs*: seq[float64]    ## per trace of the record; NaN where the model gives none
    confidence*: seq[float64] ## of each pick, 0 .. 1
    shiftMs*: seq[float64]
      ## per trace: what to add to its times (they are on its own time axis)
      ## for the plot's, which draws every trace from the layout's first time
    flagged*: seq[bool]
      ## per trace: off the model or off its neighbours (`rule`: `core/breakrule`)
    dtMs*: float64 ## the record's sample interval
    source*: BreakSource
    used*: int ## the confident picks the model was fitted to
    modelled*: int ## traces the model gives a time for
    picked*: int ## traces with a pick
    fittedFrom*: string
      ## which traces the model was fitted from when not all of them ("the
      ## hydrophone traces", "the components shown"); "" for all
    thresholdMs*: float64 ## the record's limit (ms): `rule.limitMs`
    why*: string ## state `bkFailed`: the reason in words
    picks*: seq[FirstBreakPick]
      ## the picker's result per trace of the record, as picked: the record's noisy-trace
      ## test (`core/recordqc`) uses it, so a record is picked once for both
    fit*: ShotFit ## the model's fit to the confident picks, shared with that test
    hasFit*: bool ## `fit` was made (the traces have offsets)
    offsetAbs*: seq[float64]
      ## per trace of the record: the size of its offset the model used; NaN for none (the
      ## given model is evaluated at these)
    given*: BreakModel
      ## the model the user gave, when `withModel` made this result's times from it: the
      ## fit's numbers (`fit`) are then not what the bars show
    isGiven*: bool ## the model times are the given model's (`withModel`)
    compared*: int ## traces whose pick is comparable with the model (`rule.nComparable`)
    offModel*: int ## traces flagged, off the model or off their neighbours (`rule.nFlagged`)
    medianDiffMs*: float64 ## of the comparable, the median of pick less model; NaN for none
    rule*: BreakRule ## what the rule found, per trace and for the record
    geometry*: RuleGeometry ## where the traces are, as the rule needs it
    pickedOn*: PickBasis
      ## what the guided passes read: the smoothed copy, or the samples as recorded (also when
      ## smoothing was asked and could not be done: `pickNote` says why)
    highCutHz*: float64 ## with `pbSmoothed`: the high cut's corner (Hz); 0 for none
    pickWindowMs*: float64 ## the picker's window in the guided passes (ms)
    pickNote*: string ## when smoothing was asked and not done, why, in words
    twoPass*: bool ## the picks are those of the second, guided pass
    passNote*: string
      ## when the second pass was not made, why, in words (the first-pass picks stand)
    guided*: GuideState ## whether the picks are the model shown's (`guideNote`)
    guidedBy*: BreakModel
      ## with `gdMaking` or `gdFailed`: the model the picks shown were guided by (`BreakModel()`:
      ## the record's fit)
    guideWhy*: string ## with `gdFailed`: why picking for the model shown did not finish
    revision*: int ## bumped when the lists change

func sameRecord*(a, b: BreakKey): bool =
  ## Whether `a` and `b` are of the same record as it is now: everything but the guide (the
  ## given model the second pass was guided by). What the guided passes read (`pick`) is of
  ## the record: its picks, and the noisy-trace test's, differ with it. A result stays the record's when the given
  ## model changes; only its guided picks are made again.
  a.file == b.file and a.gather == b.gather and a.keys == b.keys and a.killed == b.killed and
    a.off == b.off and a.pick == b.pick

const
  PickHighCutHz* = 60.0
    ## the corner (-6 dB, zero phase) of the high cut the guided passes pick on, at most
  PickHighCutSlope* = 24.0   ## its slope, dB per octave (effective: two passes of two poles)
  PickCutNyquistShare* = 0.8 ## the cut is at most this share of the record's Nyquist frequency
  PickMinCutHz* = 40.0
    ## the cut must lie two octaves above 10 Hz, the lowest break frequency the picker
    ## expects, else the picks are made on the samples as loaded
  GuidedWindowMs* = 40.0
    ## the picker's window in the guided passes (its energy and amplitude windows): a
    ## wavelet that builds over some 50 ms needs more than the first pass's 20 ms

func pickCutHz*(dtMs: float64): float64 =
  ## The corner of the high cut the guided passes pick on at sample interval `dtMs`: the
  ## smaller of `PickHighCutHz` and `PickCutNyquistShare` of the Nyquist frequency; 0 when
  ## that leaves less than `PickMinCutHz` (a coarse interval) or `dtMs` is not usable.
  if not (dtMs > 0 and dtMs < Inf): return 0
  let cut = min(PickHighCutHz, PickCutNyquistShare * 500.0 / dtMs)
  if cut >= PickMinCutHz: cut else: 0

const
  OffModelMs* = LimitFloorMs
    ## the smallest limit (ms) beyond which a trace is off: the record's limit is this or three
    ## sigmas of its comparable residuals, whichever is larger (`core/breakrule`)
  MaxBreakRecords* = 6 ## results kept, at most, with the jobs in flight
  MaxGuidesPerRecord* = 3
    ## results of one record (each guided by another model) kept, at most, unless more are wanted

func isHydrophone(k: TraceKeys): bool =
  if k.sensorType == 1: true
  elif k.sensorType == 0: kindOf(componentOf(k)) == ckHydrophone and componentOf(k) != 0
  else: false

func fitMask*(keys: openArray[TraceKeys]; off: openArray[uint8]): tuple[mask: seq[bool];
    what: string] =
  ## Which traces of a record the model is fitted from: all of them, unless
  ## the record has several components (distinct, non-zero). The model is
  ## a function of offset alone, so one kind of sensor serves every trace;
  ## geophone components of unrotated nodes are never fitted together: the
  ## hydrophone traces when there are any, else the one component shown
  ## (`off` are those the panel switches off) that comes first in button
  ## order (vertical, inline, crossline, others), whatever the others.
  result.mask = newSeq[bool](keys.len)
  var seen: seq[uint8]
  var hydro = false
  for k in keys:
    if k.isSeismic:
      let c = componentOf(k)
      if c != 0 and c notin seen: seen.add c
      if isHydrophone(k): hydro = true
  if seen.len <= 1:
    for i in 0 ..< keys.len: result.mask[i] = true
    return
  var chosen = 0'u8
  var best = high(int)
  for c in seen:
    if c notin off and (rankOf(c) < best or (rankOf(c) == best and c < chosen)):
      (chosen, best) = (c, rankOf(c))
  for i, k in keys:
    result.mask[i] = if hydro: isHydrophone(k) else: chosen != 0 and componentOf(k) == chosen
  result.what = if hydro: "the hydrophone traces" else: "the " & nameOf(chosen) & " traces"

func known(x: float64): bool {.inline.} = not x.isNaN

func place*(b: FirstBreaks; trace: int): int {.inline.} =
  ## The index of file trace `trace` in the lists; -1 when it is not in the record.
  let i = trace - b.first
  if i >= 0 and i < b.pickMs.len and b.state == bkDone: i else: -1

func pickOf*(b: FirstBreaks; trace: int): float64 =
  ## The pick of file trace `trace` (ms); NaN for none.
  ## For a trace far off the model (`rule.farOff`) it is the first pass's pick, which is where
  ## the break was found; the guided pass found none in its window.
  let i = b.place(trace)
  if i < 0: NaN
  elif i < b.rule.farOff.len and b.rule.farOff[i] and i < b.geometry.firstMs.len:
    b.geometry.firstMs[i]
  else: b.pickMs[i]

func modelOf*(b: FirstBreaks; trace: int): float64 =
  ## The model's time for file trace `trace` (ms); NaN for none.
  let i = b.place(trace)
  if i >= 0 and i < b.modelMs.len: b.modelMs[i] else: NaN

func confidenceOf*(b: FirstBreaks; trace: int): float64 =
  ## The confidence of the pick of file trace `trace`; 0 for none.
  let i = b.place(trace)
  if i >= 0 and i < b.rule.farOff.len and b.rule.farOff[i] and i < b.geometry.firstConf.len:
    b.geometry.firstConf[i]
  elif i >= 0 and i < b.confidence.len: b.confidence[i]
  else: 0.0

func differenceMs*(b: FirstBreaks; trace: int): float64 =
  ## Pick less model for file trace `trace`; NaN unless it has both.
  let (p, m) = (b.pickOf(trace), b.modelOf(trace))
  if known(p) and known(m): p - m else: NaN

func mismatched*(b: FirstBreaks; trace: int): bool =
  ## Whether file trace `trace` is flagged: off the model (its residual past the record's
  ## limit) or off its neighbours (`core/breakrule`). A trace with no break found never is.
  let i = b.place(trace)
  i >= 0 and i < b.flagged.len and b.flagged[i]

func comparableOf*(b: FirstBreaks; trace: int): bool =
  ## Whether the pick of file trace `trace` was compared with the model: confident and not
  ## grossly off it.
  let i = b.place(trace)
  i >= 0 and i < b.rule.comparable.len and b.rule.comparable[i]

func faintOf*(b: FirstBreaks; trace: int): bool =
  ## Whether the pick of file trace `trace` is drawn faint: of low confidence, or (with a model)
  ## no break found at it, or the trace lies beyond the offsets where breaks are seen. A trace
  ## far off the model is not: its pick is a confident one.
  let i = b.place(trace)
  if i < 0 or i >= b.confidence.len: false
  elif i < b.rule.farOff.len and b.rule.farOff[i]: false
  elif b.confidence[i] < ConfidentPick: true
  else:
    (i < b.rule.noBreak.len and b.rule.noBreak[i]) or
      (i < b.rule.beyond.len and b.rule.beyond[i])

func setRule*(b: var FirstBreaks) =
  ## Applies the rule (`applyRule`) to the picks and the model times of `b`, and sets
  ## `flagged`, `thresholdMs`, `compared`, `offModel` and `medianDiffMs` from it, so the
  ## flags, the counts and the words are one finding.
  let n = b.pickMs.len
  let intercept = if b.isGiven: b.given.interceptMs
                  elif b.hasFit: b.fit.interceptMs
                  else: NaN
  b.rule = applyRule(b.pickMs, b.confidence, b.modelMs, b.geometry, b.isGiven, intercept)
  b.flagged = b.rule.flagged
  b.flagged.setLen n
  b.thresholdMs = b.rule.limitMs
  b.compared = b.rule.nComparable
  b.offModel = b.rule.nFlagged
  b.medianDiffMs = b.rule.medianMs

func shiftOf*(b: FirstBreaks; trace: int): float64 =
  ## What to add to the times of file trace `trace` for the plot's axis.
  let i = b.place(trace)
  if i >= 0 and i < b.shiftMs.len and not b.shiftMs[i].isNaN: b.shiftMs[i] else: 0.0

func withModel*(b: FirstBreaks; m: BreakModel): FirstBreaks =
  ## `b` as the overlay shows it with the model `m`: unchanged when `m` is not given (or
  ## has no velocity) or `b` is not done. Otherwise the model times are `m`'s at each
  ## trace that has an offset (no model at one without), and the rule (`setRule`) is applied
  ## to them: the traces off it are flagged, the record is summed up. The picks, and `fit` (the
  ## noisy-trace test's), are unchanged.
  if b.state != bkDone or not m.given or b.offsetAbs.len != b.pickMs.len: return b
  result = b
  result.given = m
  result.isGiven = true
  result.modelled = 0
  for i in 0 ..< b.pickMs.len:
    let t = m.modelMs(b.offsetAbs[i])
    result.modelMs[i] = t
    if not t.isNaN: inc result.modelled
  result.setRule()

func hasModel*(b: FirstBreaks): bool =
  ## Whether the model could be fitted: some trace has a model time.
  b.state == bkDone and b.modelled > 0

func signedMs(x: float64): string =
  (if x >= 0: "+" else: "") & formatFloat(x, ffDecimal, 1) & " ms"

func flaggedWords*(r: BreakRule): string =
  ## The flagged count and what it is made of: "N flagged (M of K compared off the model, P off
  ## their neighbours, F far off)". The far-off traces are not among the K compared.
  $r.nFlagged & " flagged (" & $r.nOffModel & " of " & $r.nComparable &
    " compared off the model, " & $r.nOffNeighbours & " off their neighbours, " & $r.nFarOff &
    " far off)"

func givenWords*(b: FirstBreaks): string =
  ## What the given model finds in the record, in a line: the median of pick less model and
  ## the traces flagged (`flaggedWords`); "" when the model is not the given one.
  if not b.isGiven: return ""
  if b.compared == 0:
    return if b.rule.nNoBreak + b.rule.nFarOff > 0: "Given model: no pick lies within " & $int(
        GrossBandMs) & " ms of it: it does not fit this record; " & b.rule.flaggedWords
    else: "Given model: no confident pick to compare it with"
  "Given model: median pick less model " & b.medianDiffMs.signedMs & ", " &
    b.rule.flaggedWords & ", limit " & formatFloat(b.thresholdMs, ffDecimal, 1) & " ms"

func givenShort(b: FirstBreaks): string =
  ## `givenWords` for the strip's note, which is short.
  if b.compared == 0:
    if b.rule.nNoBreak + b.rule.nFarOff > 0: "no pick within " & $int(GrossBandMs) & " ms of it"
    else: "no pick to compare"
  else: "median " & b.medianDiffMs.signedMs & ", " & $b.offModel & " flagged"

func modelNote*(b: FirstBreaks): string =
  ## Why the overlay shows no model bars, in plain words; "" when it does
  ## (or while it is being made).
  if b.state != bkDone or b.hasModel: return ""
  if b.source == bsNone:
    "The model needs source-receiver offsets: import a survey, or open a file whose traces " &
      "carry coordinates. Only the picks are shown."
  elif b.picked == 0:
    "No first break could be picked in this record, so there is no model."
  elif b.used < MinTrimmedPicks:
    "Too few confident picks that hold together (" & $b.used & ", at least " &
      $MinTrimmedPicks & " are needed) to fit a model. Only the picks are shown, as the " &
      "first pass found them."
  else:
    "The confident picks all lie at one offset, so no model can be fitted. " &
      "Only the picks are shown."

func statusWords*(b: FirstBreaks): string =
  ## What the overlay says of itself in its key above the plot: that it is
  ## working, why it failed, or why it has no model (`modelNote`, shorter);
  ## "" when it is complete.
  case b.state
  of bkComputing: "Finding the first breaks..."
  of bkFailed: "First breaks: " & b.why
  of bkDone:
    if b.isGiven and b.hasModel: b.givenShort
    elif b.modelNote.len == 0:
      if b.fittedFrom.len > 0: "Model fitted to " & b.fittedFrom else: ""
    elif b.source == bsNone: "The model needs a survey or coordinates: picks only"
    elif b.picked == 0: "No first break could be picked"
    elif b.used < MinTrimmedPicks: "Too few confident picks for a model: picks only"
    else: "No model: the confident picks share one offset"

func ms(x: float64): string = formatFloat(x, ffDecimal, 1) & " ms"

func readoutText*(b: FirstBreaks; trace: int): string =
  ## The overlay's words for file trace `trace`, for the status bar: model
  ## time, pick time and their difference; "" when the record has no
  ## result for it, or the trace has neither time.
  let (p, m) = (b.pickOf(trace), b.modelOf(trace))
  if not (known(p) or known(m)): return ""
  result = "first break: "
  if known(m): result.add "model " & ms(m) else: result.add "no model"
  result.add ", "
  if known(p): result.add "pick " & ms(p) else: result.add "no pick"
  let d = p - m
  if known(d):
    result.add ", " & (if d >= 0: "+" else: "") & formatFloat(d, ffDecimal, 1) & " ms"
  let i = b.place(trace)
  if i >= 0 and i < b.rule.flagged.len:
    if b.rule.offModel[i]: result.add ", off the model"
    if b.rule.offNeighbours[i]: result.add ", off its neighbours"
    if b.rule.farOff[i]: result.add ", far off the model"
    if b.rule.noBreak[i]: result.add ", no break found"
    if b.rule.beyond[i]: result.add ", beyond the offsets where breaks are seen"

func velocityUnit*(u: SurveyUnit): string =
  ## The unit the fitted velocity is read in, as the f-k's velocity label follows the
  ## file's units: "m/s", "ft/s", else "offset units per second" (the unit is not named).
  case u
  of suMetres: "m/s"
  of suFeet, suUsFeet: "ft/s"
  else: "offset units per second"

func velocityShort*(u: SurveyUnit): string =
  ## `velocityUnit` as the key writes it: "units/s" where the unit is not named.
  case u
  of suMetres: "m/s"
  of suFeet, suUsFeet: "ft/s"
  else: "units/s"

func lengthUnit(u: SurveyUnit): string =
  case u
  of suMetres: "m"
  of suFeet, suUsFeet: "ft"
  else: "offset units"

func offsetsFrom*(b: FirstBreaks): string =
  ## Where the offsets the model used came from, in words; "" when it has none.
  case b.source
  of bsSurvey: "the imported survey"
  of bsFile: "the file's own headers"
  of bsNone: ""

func fitModel*(fit: ShotFit): BreakModel =
  ## `fit`'s velocity or velocities, intercept and crossover as a given model; the default
  ## model (not given) without a velocity.
  if not (fit.v1 > 0 and fit.v1 < Inf): return BreakModel()
  let two = fit.v2 > 0 and fit.v2 < Inf and fit.crossover > 0 and fit.crossover < Inf
  BreakModel(source: bmGiven, v1: fit.v1, interceptMs: fit.interceptMs,
    v2: (if two: fit.v2 else: 0.0), crossover: (if two: fit.crossover else: 0.0)).bounded

func fitAsModel*(b: FirstBreaks): BreakModel =
  ## The record's fit (its velocity or velocities, intercept and crossover) as a given
  ## model: what "Use this record's fit" keeps, to hold for the other records. It is the fit
  ## to the trimmed picks of the second pass, so a stretch of noise picks does not set a
  ## segment. Without a fit (no velocity), the default model (not given).
  if not b.hasFit: BreakModel() else: b.fit.fitModel

func segments*(b: FirstBreaks): int =
  ## The model's straight segments: 0 when it has no fit, 1 or 2.
  if not (b.hasModel and b.hasFit): 0
  elif b.fit.v2.isNaN or b.fit.crossover.isNaN or b.fit.crossover == Inf: 1
  else: 2

func number(x: float64): string =
  if x.isNaN or abs(x) == Inf: "?" else: $int(round(x))

const UnitFromSurvey* =
  "The unit is taken from the project's survey: the file names none."

func guideWords(m: BreakModel): string =
  if m.given: "another given model" else: "the record's fit"

func guideNote*(b: FirstBreaks): string =
  ## When the picks shown were guided by another model than the one shown (`guided`), in words;
  ## "" when they are the model shown's.
  case b.guided
  of gdOwn: ""
  of gdMaking:
    "The picks shown were guided by " & guideWords(b.guidedBy) &
      ": those guided by this model are being made."
  of gdFailed:
    "The picks guided by this model could not be made (" & b.guideWhy &
      "): the picks shown were guided by " & guideWords(b.guidedBy) & "."

func ruleWords*(b: FirstBreaks; unit: SurveyUnit): string =
  ## What the rule found in the record, in plain words, with the limits and the statements about
  ## the model and the source; "" without a model.
  if not b.hasModel: return ""
  let r = b.rule
  result = $r.nComparable & " traces compared with the model, " & $r.nNoBreak &
    " with no break found within the offsets where breaks are seen, " & $r.nBeyond &
    " beyond those offsets (never a finding), " & $r.nFarOff & " far off the model (a break " &
    $int(GrossBandMs) & " to " & $int(FarOffMaxMs) & " ms from it), " & $r.nOffModel &
    " off the model, " & $r.nOffNeighbours & " off their neighbours; " & $r.nFlagged & " flagged"
  if not r.limitMs.isNaN:
    result.add "\nOff the model: more than " & formatFloat(r.limitMs, ffDecimal, 1) &
      " ms away (3 sigmas of the picks' own scatter, " & formatFloat(r.sigmaMs, ffDecimal, 1) &
      " ms, not less than " & $int(LimitFloorMs) & " ms)"
    if not r.stationLimitMs.isNaN:
      result.add "\nOff its neighbours: more than " & formatFloat(r.stationLimitMs, ffDecimal, 1) &
        " ms from what the stations beside it say"
  if b.isGiven and r.mismatch:
    # the model is the likelier fault: the rule says nothing of the source then
    result.add "\nThe given model does not match this record's breaks"
    if b.hasFit:
      result.add ": the record's own fit is " & number(b.fit.v1) & " " & unit.velocityUnit
      if b.segments == 2:
        result.add " (" & number(b.fit.v2) & " beyond " & number(b.fit.crossover) & ")"
      result.add " with an intercept of " & formatFloat(b.fit.interceptMs, ffDecimal, 1) & " ms"
  let s = r.statementWords
  if s.len > 0: result.add "\nThe record: " & s
  if b.passNote.len > 0: result.add "\n" & b.passNote
  let g = b.guideNote
  if g.len > 0: result.add "\n" & g

func modelWordsOf(b: FirstBreaks; unit: SurveyUnit): string =
  ## What the model is, for the key's tooltip: a straight-line refraction fit to this
  ## record's own picks against offset, with no velocity typed in, the fitted velocity or
  ## velocities (`unit`: the offsets' unit, per second), the intercept, the crossover offset
  ## with two segments, the picks it was fitted to and where the offsets came from.
  ## "" without a model.
  let (v, len) = (unit.velocityUnit, unit.lengthUnit)
  if b.isGiven:
    if not b.hasModel: return ""
    let m = b.given
    result = "The model is the one you gave, the same for every record: the expected " &
      "first break is the intercept plus the offset over the velocity" &
      (if m.segments == 2: ", then the second velocity beyond the crossover" else: "") &
      ". It is not fitted to the picks, so a trace whose pick is off it points to a source " &
      "named or placed wrongly, or a wrong station."
    result.add "\nVelocity: " & number(m.v1) & " " & v
    if m.segments == 2:
      result.add "\nBeyond " & number(m.crossover) & " " & len & " offset: " & number(m.v2) &
        " " & v
    result.add "\nIntercept: " & formatFloat(m.interceptMs, ffDecimal, 1) & " ms"
    result.add "\n" & b.givenWords
    result.add "\nOffsets from " & b.offsetsFrom & "."
    let w = b.ruleWords(unit)
    if w.len > 0: result.add "\n" & w
    return
  let n = b.segments
  if n == 0: return ""
  result = "The model is a straight-line refraction fit to this record's own picks " &
    "against offset. No velocity is typed in: it is found from the picks."
  if n == 1:
    result.add "\nVelocity: " & number(b.fit.v1) & " " & v
  else:
    result.add "\nVelocities: " & number(b.fit.v1) & " " & v & " near the source, " &
      number(b.fit.v2) & " " & v & " beyond " & number(b.fit.crossover) & " " & len &
      " offset"
  result.add "\nIntercept: " & formatFloat(b.fit.interceptMs, ffDecimal, 1) & " ms"
  result.add "\nFitted to " & $b.used & " confident picks that agree with it (picks far from " &
    "the line are left out, so noise at long offsets does not set it)"
  if b.fittedFrom.len > 0: result.add " (" & b.fittedFrom & ")"
  result.add "\nOffsets from " & b.offsetsFrom & "."
  let w = b.ruleWords(unit)
  if w.len > 0: result.add "\n" & w

func modelWords*(b: FirstBreaks; unit: SurveyUnit; fromSurvey = false): string =
  ## `modelWordsOf`, with a line saying where the unit came from when it is the survey's
  ## (`fromSurvey`: the file names none).
  result = b.modelWordsOf(unit)
  if result.len > 0 and fromSurvey: result.add "\n" & UnitFromSurvey

type KeyParts* = object
  ## What the overlay's key shows (it is one width whatever the model).
  given*: bool ## the model is the given one: a small marker says so
  off*: string ## "358 off" when some traces are off the given model; else ""

func keyParts*(b: FirstBreaks): KeyParts =
  ## The key's two small extras: the marker for a given model and the count of traces
  ## off it. The velocity, intercept, median and where offsets came from are the tooltip's.
  result = KeyParts(given: b.isGiven and b.hasModel)
  if result.given and b.offModel > 0: result.off = $b.offModel & " off"

func keyNote*(b: FirstBreaks): string =
  ## The words the key shows beside itself: the overlay's own words while it is working,
  ## failed or has no model, or that the picks shown were guided by another model; "" once it
  ## has its own (the tooltip says the rest).
  if b.state == bkDone and b.hasModel:
    case b.guided
    of gdOwn: ""
    of gdMaking: "picking again for this model..."
    of gdFailed: "picks of " & guideWords(b.guidedBy) & ": " & b.guideWhy
  else: b.statusWords
