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

import std/[algorithm, math, strutils]
import parseSEG
import processSEG/qc/[firstbreak, shotfit]
import breakmodel, components, jobs, join, session

type
  BreakSource* = enum
    ## Where the offsets the model used came from.
    bsNone = "none"     ## no trace has an offset
    bsSurvey = "survey" ## the imported survey's (a join derived them)
    bsFile = "file"     ## the file's own headers, or its own coordinates

  BreakState* = enum
    bkComputing, bkDone, bkFailed

  BreakKey* = tuple[file: SessionId; gather, keys: int; killed: seq[int]; off: seq[uint8]]
    ## What a result is of: the record, the file's keys as they were read
    ## (a join or a header edit changes them), the traces killed in it, and
    ## the components the panel's filter switches off (which traces a node
    ## record's model is fitted from, `fitMask`).

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
    flagged*: seq[bool] ## per trace: the fit finds its pick off the model (`ShotFit.suspect`)
    dtMs*: float64 ## the record's sample interval
    source*: BreakSource
    used*: int ## the confident picks the model was fitted to
    modelled*: int ## traces the model gives a time for
    picked*: int ## traces with a pick
    fittedFrom*: string
      ## which traces the model was fitted from when not all of them ("the
      ## hydrophone traces", "the components shown"); "" for all
    thresholdMs*: float64 ## the fit's `|localMs|` above which a trace is flagged
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
    compared*: int ## given: traces with a confident pick and a model time
    offModel*: int ## of them, those more than `OffModelMs` off
    medianDiffMs*: float64 ## of them, the median of pick less model; NaN for none
    revision*: int ## bumped when the lists change

const
  ConfidentPick* = 0.5
    ## the confidence from which a pick counts in the model (processSEG's
    ## `ShotFitParams.minConfidence`)
  OffModelMs* = 12.0 ## a pick this far (ms) from the model is joined to it by a line
  MaxBreakRecords* = 6 ## results kept, at most, with the jobs in flight

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
  let i = b.place(trace)
  if i >= 0: b.pickMs[i] else: NaN

func modelOf*(b: FirstBreaks; trace: int): float64 =
  ## The model's time for file trace `trace` (ms); NaN for none.
  let i = b.place(trace)
  if i >= 0 and i < b.modelMs.len: b.modelMs[i] else: NaN

func confidenceOf*(b: FirstBreaks; trace: int): float64 =
  ## The confidence of the pick of file trace `trace`; 0 for none.
  let i = b.place(trace)
  if i >= 0 and i < b.confidence.len: b.confidence[i] else: 0.0

func differenceMs*(b: FirstBreaks; trace: int): float64 =
  ## Pick less model for file trace `trace`; NaN unless it has both.
  let (p, m) = (b.pickOf(trace), b.modelOf(trace))
  if known(p) and known(m): p - m else: NaN

func mismatched*(b: FirstBreaks; trace: int): bool =
  ## Whether the fit finds the pick of file trace `trace` off the model:
  ## processSEG's `suspect` (its residual against the neighbours' median
  ## past `thresholdMs`, so a residual that drifts smoothly along the
  ## spread is not).
  let i = b.place(trace)
  i >= 0 and i < b.flagged.len and b.flagged[i]

func shiftOf*(b: FirstBreaks; trace: int): float64 =
  ## What to add to the times of file trace `trace` for the plot's axis.
  let i = b.place(trace)
  if i >= 0 and i < b.shiftMs.len and not b.shiftMs[i].isNaN: b.shiftMs[i] else: 0.0

func withModel*(b: FirstBreaks; m: BreakModel): FirstBreaks =
  ## `b` as the overlay shows it with the model `m`: unchanged when `m` is not given (or
  ## has no velocity) or `b` is not done. Otherwise the model times are `m`'s at each
  ## trace that has an offset (no model at one without), the traces whose pick is more than
  ## `OffModelMs` from it are flagged (not the fit's `suspect`), and the record is
  ## summed up: the median of pick less model and how many are off, over the traces with a
  ## confident pick. The picks, and `fit` (the noisy-trace test's), are unchanged.
  if b.state != bkDone or not m.given or b.offsetAbs.len != b.pickMs.len: return b
  result = b
  result.given = m
  result.isGiven = true
  result.modelled = 0
  result.thresholdMs = OffModelMs
  result.medianDiffMs = NaN
  result.compared = 0
  result.offModel = 0
  var diffs: seq[float64]
  for i in 0 ..< b.pickMs.len:
    let t = m.modelMs(b.offsetAbs[i])
    result.modelMs[i] = t
    result.flagged[i] = false
    if not t.isNaN:
      inc result.modelled
      let d = b.pickMs[i] - t
      if not d.isNaN:
        result.flagged[i] = abs(d) > OffModelMs
        if b.confidence[i] >= ConfidentPick:
          diffs.add d
          if abs(d) > OffModelMs: inc result.offModel
  result.compared = diffs.len
  if diffs.len > 0:
    diffs.sort()
    let h = diffs.len div 2
    result.medianDiffMs = if diffs.len mod 2 == 1: diffs[h] else: (diffs[h - 1] + diffs[h]) / 2

func hasModel*(b: FirstBreaks): bool =
  ## Whether the model could be fitted: some trace has a model time.
  b.state == bkDone and b.modelled > 0

func signedMs(x: float64): string =
  (if x >= 0: "+" else: "") & formatFloat(x, ffDecimal, 1) & " ms"

func givenWords*(b: FirstBreaks): string =
  ## What the given model finds in the record, in a line: the median of pick less model and
  ## the traces off by more than `OffModelMs`; "" when the model is not the given one.
  if not b.isGiven: return ""
  if b.compared == 0: return "Given model: no confident pick to compare it with"
  "Given model: median pick less model " & b.medianDiffMs.signedMs & ", " & $b.offModel &
    " of " & $b.compared & " traces off by more than " & $int(OffModelMs) & " ms"

func givenShort(b: FirstBreaks): string =
  ## `givenWords` for the strip's note, which is short.
  if b.compared == 0: "no pick to compare"
  else: "median " & b.medianDiffMs.signedMs & ", " & $b.offModel & " of " & $b.compared & " off"

func modelNote*(b: FirstBreaks): string =
  ## Why the overlay shows no model bars, in plain words; "" when it does
  ## (or while it is being made).
  if b.state != bkDone or b.hasModel: return ""
  if b.source == bsNone:
    "The model needs source-receiver offsets: import a survey, or open a file whose traces " &
      "carry coordinates. Only the picks are shown."
  elif b.picked == 0:
    "No first break could be picked in this record, so there is no model."
  elif b.used < 3:
    "Too few confident picks (" & $b.used & ", at least 3 are needed) to fit the model. " &
      "Only the picks are shown."
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
    elif b.used < 3: "Too few confident picks for a model: picks only"
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

func fitAsModel*(b: FirstBreaks): BreakModel =
  ## The record's fit (its velocity or velocities, intercept and crossover) as a given
  ## model: what "Use this record's fit" keeps, to hold for the other records. Without a
  ## fit (no velocity), the default model (not given).
  if not b.hasFit or not (b.fit.v1 > 0 and b.fit.v1 < Inf): return BreakModel()
  let two = b.fit.v2 > 0 and b.fit.v2 < Inf and b.fit.crossover > 0 and b.fit.crossover < Inf
  BreakModel(source: bmGiven, v1: b.fit.v1, interceptMs: b.fit.interceptMs,
    v2: (if two: b.fit.v2 else: 0.0), crossover: (if two: b.fit.crossover else: 0.0)).bounded

func keyWord*(b: FirstBreaks; unit: SurveyUnit): string =
  ## The key's word for the model bar: "model", or, for the given model, "model (given: 2500
  ## m/s)" so it is never taken for the fit.
  if b.isGiven and b.hasModel:
    "model (given: " & $int(round(b.given.v1)) & " " & unit.velocityShort & ")"
  else: "model"

func segments*(b: FirstBreaks): int =
  ## The model's straight segments: 0 when it has no fit, 1 or 2.
  if not (b.hasModel and b.hasFit): 0
  elif b.fit.v2.isNaN or b.fit.crossover.isNaN or b.fit.crossover == Inf: 1
  else: 2

func number(x: float64): string =
  if x.isNaN or abs(x) == Inf: "?" else: $int(round(x))

func modelWords*(b: FirstBreaks; unit: SurveyUnit): string =
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
  result.add "\nFitted to " & $b.used & " confident picks"
  if b.fittedFrom.len > 0: result.add " (" & b.fittedFrom & ")"
  result.add "\nOffsets from " & b.offsetsFrom & "."
