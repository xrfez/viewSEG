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

import std/[math, strutils]
import parseSEG
import jobs, session

type
  BreakSource* = enum
    ## Where the offsets the model used came from.
    bsNone = "none"     ## no trace has an offset
    bsSurvey = "survey" ## the imported survey's (a join derived them)
    bsFile = "file"     ## the file's own headers, or its own coordinates

  BreakState* = enum
    bkComputing, bkDone, bkFailed

  BreakKey* = tuple[file: SessionId; gather, keys: int; killed: seq[int]]
    ## What a result is of: the record, the file's keys as they were read
    ## (a join or a header edit changes them) and the traces killed in it.

  FirstBreaks* = object
    ## One record's first breaks, as its job found them.
    job*: JobId = NoJob       ## the job making it; `NoJob` once it has ended
    key*: BreakKey
    state*: BreakState
    first*: int               ## the file's trace number of the record's first trace
    pickMs*: seq[float64]     ## per trace of the record; NaN for no pick
    modelMs*: seq[float64]    ## per trace of the record; NaN where the model gives none
    confidence*: seq[float64] ## of each pick, 0 .. 1
    dtMs*: float64            ## the record's sample interval
    source*: BreakSource
    used*: int                ## the confident picks the model was fitted to
    picked*: int              ## traces with a pick
    why*: string              ## state `bkFailed`: the reason in words
    revision*: int            ## bumped when the lists change

const
  MinMismatchMs* = 12.0
    ## a pick this far from the model (or 3 samples, if more) is drawn as
    ## a mismatch: processSEG's `ShotFitParams.maxResidualMs`
  ConfidentPick* = 0.5
    ## the confidence from which a pick counts in the model (processSEG's
    ## `ShotFitParams.minConfidence`)
  MaxBreakRecords* = 6 ## results kept, at most, with the jobs in flight

func mismatchMs*(dtMs: float64): float64 =
  ## The difference between pick and model above which they are said to
  ## disagree: 12 ms, or three samples where they are longer.
  if dtMs > 0 and dtMs < Inf: max(MinMismatchMs, 3 * dtMs) else: MinMismatchMs

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
  ## Whether pick and model of file trace `trace` differ by more than `mismatchMs`.
  let d = b.differenceMs(trace)
  known(d) and abs(d) > mismatchMs(b.dtMs)

func hasModel*(b: FirstBreaks): bool =
  ## Whether the model could be fitted: some trace has a model time.
  b.state == bkDone and b.used >= 3 and b.source != bsNone

func modelNote*(b: FirstBreaks): string =
  ## Why the overlay shows no model bars, in plain words; "" when it does
  ## (or while it is being made).
  if b.state != bkDone or b.hasModel: return ""
  if b.source == bsNone:
    "The model needs source-receiver offsets: import a survey, or open a file whose traces " &
      "carry coordinates. Only the picks are shown."
  elif b.picked == 0:
    "No first break could be picked in this record, so there is no model."
  else:
    "Too few confident picks (" & $b.used & ", at least 3 are needed) to fit the model. " &
      "Only the picks are shown."

func statusWords*(b: FirstBreaks): string =
  ## What the overlay says of itself in its key above the plot: that it is
  ## working, why it failed, or why it has no model (`modelNote`, shorter);
  ## "" when it is complete.
  case b.state
  of bkComputing: "Finding the first breaks..."
  of bkFailed: "First breaks: " & b.why
  of bkDone:
    if b.modelNote.len == 0: ""
    elif b.source == bsNone: "The model needs a survey or coordinates: picks only"
    elif b.picked == 0: "No first break could be picked"
    else: "Too few confident picks for a model: picks only"

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
