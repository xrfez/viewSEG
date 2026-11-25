## Which side of the survey's relation records a FILE is checked against by the reports
## that need it (missing traces, trace quality): from the kind of recording the file is
## treated as, the one the user forced in the Files window or else the one told from the
## file (`filelist.recordingOf`).
##
## A shot gather (`rkShotGather`) is checked against the X record of its shot, its
## receivers expected; a receiver gather (`rkReceiverSliced`, such as a node's record
## sliced by shot) against the O record of its receiver, its shots expected; a continuous
## receiver recording (`rkReceiverContinuous`) is neither. A file whose kind is not told
## (no sample interval, or a record with nothing to judge it by) and is not forced takes
## the side its stations show when they show it (`relationside.sideOf`, the rule the
## automatic kind is built on); one receiver and one source cannot be told and is left to
## the user to set. A folder (or list) holding both shot and receiver gathers is not
## calculated (`SideCounts`).

import std/[math, options, os]
import parseSEG
import correlatejobs, jobs, recordingkind, relationside, session, settings, vendormaps

type
  ReportSide* = enum
    rsShot       ## a shot gather: checked against X records, receivers expected
    rsReceiver   ## a receiver gather: checked against O records, shots expected
    rsNotGather  ## continuous receiver recording: not checked
    rsCannotTell ## the kind is not told and the stations do not say

  FileSide* = tuple[side: ReportSide; why: string]
    ## `why` is a sentence for the user for the two sides that are not checked

  SideCounts* = object
    ## The files of a scan by side. Files that are neither a gather nor told are not in
    ## `shots` or `receivers`.
    shots*, receivers*, untold*: int

const
  ContinuousWhy* = "a continuous receiver recording is not checked"
  SetKindHint* = "set its kind in the Files window (right-click the file)"

func reportSide*(kind: Option[RecordingKind]; forced: bool; st: Stations): FileSide =
  ## The side of a file treated as `kind` (`forced`: set by the user), whose traces
  ## have the stations `st`. The one place that turns a file's kind into a side.
  if kind.isSome:
    case kind.get
    of rkReceiverContinuous: return (rsNotGather, ContinuousWhy)
    of rkReceiverSliced: return (rsReceiver, "")
    of rkShotGather:
      if forced or st.sideOf((known: false, receiver: false, continuous: false)) != sdOpen:
        return (rsShot, "")
      return (rsCannotTell, "one receiver and one source: it may be one slice of a " &
        "receiver or a shot of one receiver; " & SetKindHint)
  case st.sideOf((known: false, receiver: false, continuous: false))
  of sdShot: (rsShot, "")
  of sdReceiver: (rsReceiver, "")
  of sdOpen: (rsCannotTell, "one receiver and one source: it may be one slice of a " &
    "receiver or a shot of one receiver; " & SetKindHint)
  of sdNeither: (rsCannotTell, neitherWhy(st) & "; " & SetKindHint)

func note*(c: var SideCounts; side: ReportSide) =
  ## Counts one file of `side`.
  case side
  of rsShot: inc c.shots
  of rsReceiver: inc c.receivers
  of rsCannotTell: inc c.untold
  of rsNotGather: discard

func isMixed*(c: SideCounts): bool =
  ## Whether files of both sides were read: nothing is calculated then.
  c.shots > 0 and c.receivers > 0

func countText(n: int; one, many: string): string =
  $n & (if n == 1: one else: many)

func mixedNote*(c: SideCounts): string =
  ## What the report says instead of its figures for a mix of shot and receiver gathers.
  result = "The files are not all of one kind, so nothing is calculated: " &
    countText(c.shots, " is a shot gather", " are shot gathers") & ", " &
    countText(c.receivers, " is a receiver gather", " are receiver gathers")
  if c.untold > 0:
    result.add " and " & countText(c.untold, " could not be told", " could not be told")
  result.add ". Set the kind of each file in the Files window (right-click the file) " &
    "so that they are all shot gathers or all receiver gathers."

func unanimousSide*(c: SideCounts): ReportSide =
  ## The side every file whose kind is told is on, when they are all on one; `rsCannotTell`
  ## when none is told or both sides are (a mix, not a vote).
  if c.shots > 0 and c.receivers == 0: rsShot
  elif c.receivers > 0 and c.shots == 0: rsReceiver
  else: rsCannotTell

func takenNote*(n: int; side: ReportSide; chosen: bool): string =
  ## What the report says of `n` files that cannot be told and were taken for `side`: as the
  ## user chose, or like the others in the folder; "" for none.
  if n == 0 or side notin {rsShot, rsReceiver}: return ""
  let kind = if side == rsShot: "shot" else: "receiver"
  $n & (if n == 1: " file of one receiver and one source is" else:
    " files of one receiver and one source are") & " taken as " & kind & " gathers" &
    (if chosen: ", as chosen." else: ", like the others in the folder.")

proc forcedPath*(path: string): string =
  ## `path` as the kinds set in the Files window are keyed (`state.forcedKinds`): absolute
  ## and normalised.
  try: absolutePath(path).normalizedPath
  except OSError, ValueError: path.normalizedPath

proc autoKindOf*(s: Session; path: string; ctx: JobContext): Option[RecordingKind] =
  ## The kind of the open file told from itself, as the Files window tells it; none when
  ## the file has no sample interval or no live trace, when the plan cannot be made, or
  ## when it reads as continuous only for want of a boundary between segments to judge
  ## by (one segment for each receiver: one live trace, or the components of one station
  ## at one start). Runs on a job's thread.
  let dtMs = seismicDtMs(s.filePtr)
  if dtMs.isNaN or dtMs <= 0: return
  try:
    {.cast(gcsafe).}:
      let facts = describeRecording(planRecording(s.filePtr, path, dtMs, currentVendors(),
        proc () {.gcsafe.} = ctx.checkCancelled()))
      if facts.ready and not (facts.kind == rkReceiverContinuous and facts.boundaries == 0):
        result = some(facts.kind)
  except JobCancelledError, SegCancelledError:
    raise
  except CatchableError:
    discard
