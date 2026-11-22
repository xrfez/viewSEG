## The record QC's noisy-trace test, as the viewer holds and says it:
## the user's choice of exclusion area (`NoiseSettings`, saved with the
## settings), what the test found for the record shown (`NoiseSummary`), and
## the words for it (`areaWords`, `notJudgedWords`, `notesWords`).
##
## processSEG's `qc/exclusion` does the test (`core/recordqc` calls it): it
## leaves the traces near the source or the receiver out of the judgement,
## so the loud traces there are not called noisy, and compares what is left
## against its neighbours on the same line. This module only maps the
## viewer's settings onto its parameters, and its findings onto the words
## the windows use; the library's own names are never shown.
##
## Whatever the choice, the library never compares the geophone components
## of unrotated nodes with those of other nodes (the hydrophone is a group of
## its own, nodes are compared on the summed energy of their motion traces,
## rotated components one by one): the viewer has no setting for it.

import std/[math, strutils]
import processSEG/qc/exclusion

export exclusion.AreaRule, exclusion.AreaReason, exclusion.OffsetOrigin, exclusion.NoiseState,
  exclusion.GatherDomain

type
  NoiseChoice* = enum
    ## How the exclusion area is set.
    ncAuto = "Automatic"
    ncTime = "A fixed time"
    ncRadius = "A radius"
    ncSteps = "A number of stations"

  NoiseSettings* = object
    ## The user's choice (Tools > Settings); automatic by default.
    choice*: NoiseChoice
    edgeMs*: float64 = 100.0 ## `ncTime`: the edge, on the first-break model's arrival
    radius*: float64 = 500.0 ## `ncRadius`: in the length unit of the offsets
    steps*: int = 8          ## `ncSteps`, and what the automatic choice falls back to
    allLines*: bool          ## `ncSteps` on every line, not only the lines the shot reaches

  NoiseSummary* = object
    ## What the noisy-trace test found in one record (`ready`), per trace of
    ## the record and in counts.
    ready*: bool
    first*: int ## the file's trace number of the record's first trace
    asked*: NoiseSettings
    domain*: GatherDomain
    rule*: AreaRule
    reasons*: set[AreaReason]
    origin*: OffsetOrigin
    edgeMs*, radius*: float64 ## NaN when the rule has none
    steps*, lines*, linesReached*: int
    inside*: seq[bool] ## per trace: inside the exclusion area
    state*: seq[NoiseState] ## per trace: judged, or why not
    louder*: seq[bool] ## per trace: louder than its neighbours
    judged*, inArea*, unknown*, incomplete*, unusable*: int ## traces, by state
    noisy*, weak*, louderCount*: int

const
  MaxStations* = 1000 ## the most stations a count may be
  NoiseChoiceNames*: array[NoiseChoice, string] = ["auto", "time", "radius", "steps"]
    ## each choice's name in the settings file, the agent's `state` and the tests' marks

func finite(x: float64): bool {.inline.} = x - x == 0

func bounded*(s: NoiseSettings): NoiseSettings =
  ## `s` with each number in its range: a time and a radius positive and
  ## finite (else their defaults), a count of 0 to `MaxStations` stations.
  result = s
  if not (s.edgeMs > 0 and finite(s.edgeMs)): result.edgeMs = NoiseSettings().edgeMs
  if not (s.radius > 0 and finite(s.radius)): result.radius = NoiseSettings().radius
  result.steps = clamp(s.steps, 0, MaxStations)

func paramsOf*(s: NoiseSettings; origin: OffsetOrigin): ExclusionParams =
  ## processSEG's parameters for `s`. The first-break trend, which the
  ## library offers as an experiment, is never chosen.
  let b = s.bounded
  result = ExclusionParams(offsetOrigin: origin, steps: b.steps, stepsOnAllLines: b.allLines)
  case b.choice
  of ncAuto: result.choice = acAuto
  of ncTime:
    result.choice = acFixedTime
    result.edgeMs = b.edgeMs
  of ncRadius:
    result.choice = acFixedRadius
    result.radius = b.radius
  of ncSteps: result.choice = acSteps

func number(x: float64): string =
  if not finite(x): "?"
  elif abs(x) < 10: formatFloat(x, ffDecimal, 1)
  else: $int(round(x))

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func pointWord(d: GatherDomain): string = (if d == gdCommonReceiver: "receiver" else: "source")

func joined(parts: seq[string]): string =
  case parts.len
  of 0: ""
  of 1: parts[0]
  else: parts[0 ..< parts.high].join(", ") & " and " & parts[^1]

func whyNot(reasons: set[AreaReason]): seq[string] =
  ## Why the rules before the one used did not apply, in words.
  if rnNoPicks in reasons: result.add "no first breaks"
  if rnFewPicks in reasons: result.add "too few coherent first breaks"
  if rnBadModel in reasons: result.add "the model did not fit physically"
  if rnNoHeaderOffsets in reasons: result.add "no offsets in the headers for the model"
  if rnNoOffsets in reasons and rnNoPosition notin reasons: result.add "no offsets"

func areaWords*(n: NoiseSummary): string =
  ## Which rule set the exclusion area, and why not the others, in plain
  ## words: "Area set by the first-break model", "Area set by 8 stations either
  ## side of the source on each line", "No area: every trace judged (no
  ## offsets, coordinates or station numbers)". "" before there is a result.
  if not n.ready: return ""
  let d = n.domain
  let skipped = n.reasons.whyNot
  case n.rule
  of arModel, arTrend:
    result = "Area set by the first-break model"
    if rnNoLoudness in n.reasons:
      result.add ": nothing is louder near the " & d.pointWord & ", so no trace is left out"
    elif finite(n.edgeMs): result.add " (edge at " & number(n.edgeMs) & " ms)"
  of arRadius:
    result = "Area set by a radius from " & (case n.origin
      of ooSurvey: "the survey's offsets"
      of ooHeaders: "the offsets or coordinates in the trace headers"
      else: "the offsets")
    if finite(n.radius): result.add " (radius " & number(n.radius) & ")"
    if rnNoLoudness in n.reasons:
      result.add ": nothing is louder near the " & d.pointWord & ", so no trace is left out"
  of arSteps:
    result = "Area set by " & (if d == gdCommonReceiver: plural(n.steps, "shot", "shots")
      else: plural(n.steps, "station", "stations")) & " either side of the " & d.pointWord &
      " on each line"
    if n.asked.choice == ncSteps and n.asked.allLines: result.add ", on every line"
    elif n.lines > 0: result.add ", on the " & $n.linesReached & " of " & $n.lines &
      " lines the " & (if d == gdCommonReceiver: "receiver" else: "shot") & " reaches"
  of arFixedTime:
    result = "Area set by the time you chose (" & number(n.edgeMs) & " ms on the first-break model)"
  of arFixedRadius:
    result = "Area set by the radius you chose (" & number(n.radius) & ")"
  of arNone:
    var because: seq[string]
    if rnOverrideNeedsModel in n.reasons:
      because.add "a fixed time needs the first-break model, and this record has none"
    if rnOverrideNeedsOffsets in n.reasons:
      because.add "a fixed radius needs offsets, and this record has none"
    if rnNoOffsets in n.reasons and rnNoPosition in n.reasons:
      because.add "no offsets, coordinates or station numbers"
    elif rnNoPosition in n.reasons: because.add "no " & d.pointWord & " position along a line"
    elif rnNoOffsets in n.reasons and because.len == 0: because.add "no offsets"
    if rnOneStation in n.reasons: because.add "every far end at one station"
    if rnFewTraces in n.reasons: because.add "too few usable traces"
    if rnNoLoudness in n.reasons: because.add "nothing is louder near the " & d.pointWord
    result = "No area: every trace judged"
    if because.len > 0: result.add " (" & because.joined & ")"
    return
  if skipped.len > 0 and n.asked.choice == ncAuto:
    result.add "; the first-break model was not used: " & skipped.joined

func notesWords*(n: NoiseSummary): string =
  ## What else the test says of how it judged, in words; "" for nothing.
  if not n.ready: return ""
  var parts: seq[string]
  if rnUnknownSensors in n.reasons:
    parts.add "the sensors are not named, so each station is judged on the energy of all its traces"
  if rnNoStationIds in n.reasons: parts.add "the stations are not identified"
  if rnAllInside in n.reasons: parts.add "the area covers a whole group of traces"
  if rnFewArrivals in n.reasons: parts.add "too few first breaks in a group for an edge"
  result = parts.joined
  if result.len > 0: result[0] = result[0].toUpperAscii

func notJudgedWords*(n: NoiseSummary): string =
  ## The traces not judged for noise and why, in words: "12 inside the
  ## area, 3 with the sensor or station unknown, 1 node incomplete". A trace
  ## with no usable samples is not counted here: it has its own flags.
  if not n.ready: return ""
  var parts: seq[string]
  if n.inArea > 0: parts.add $n.inArea & " inside the area"
  if n.unknown > 0: parts.add $n.unknown & " with the sensor or station unknown"
  if n.incomplete > 0: parts.add plural(n.incomplete, "trace", "traces") & " of an incomplete node"
  result = if parts.len == 0: "none" else: parts.join(", ")

func notJudged*(n: NoiseSummary): int =
  ## The traces not judged for noise: inside the area, with the sensor or
  ## station unknown, or of an incomplete node.
  n.inArea + n.unknown + n.incomplete

func insideAt*(n: NoiseSummary; trace: int): bool =
  ## Whether file trace `trace` lies inside the exclusion area.
  let i = trace - n.first
  n.ready and i >= 0 and i < n.inside.len and n.inside[i]

func hasArea*(n: NoiseSummary): bool =
  ## Whether the area leaves any trace out.
  n.ready and n.inArea > 0
