## What the user told viewSEG to treat a file as, against what is told from the file: its kind
## of recording and the order of its traces. Kept per file (`core/filememory`, by the file's
## identity) and shown beside the automatic answer in the Files panel. Each part is its own
## choice: unset means the automatic answer.

import std/options
import ./[recordingkind, traceorder]

type
  TreatAs* = object
    kind*: Option[RecordingKind]
    grouping*: Option[TraceGrouping] ## only `tgNone`, `tgByFlag` or `tgByComponent`
    subSort*: Option[TraceSubSort]   ## only `tsByStation` or `tsByTime`

func isSet*(t: TreatAs): bool =
  ## Whether anything is forced.
  t.kind.isSome or t.grouping.isSome or t.subSort.isSome

func orderSet*(t: TreatAs): bool =
  ## Whether the order is forced, in either part.
  t.grouping.isSome or t.subSort.isSome

func kindName*(k: RecordingKind): string =
  ## The word a kind is kept and commanded by.
  case k
  of rkShotGather: "shot"
  of rkReceiverContinuous: "continuous"
  of rkReceiverSliced: "sliced"

func parseKindName*(s: string; k: var RecordingKind): bool =
  for x in RecordingKind:
    if kindName(x) == s:
      k = x
      return true

func groupingName*(g: TraceGrouping): string =
  case g
  of tgNone: "none"
  of tgByFlag: "flag"
  of tgByComponent: "component"
  of tgNotKnown: "unknown"

func parseGroupingName*(s: string; g: var TraceGrouping): bool =
  for x in [tgNone, tgByFlag, tgByComponent]:
    if groupingName(x) == s:
      g = x
      return true

func subSortName*(s: TraceSubSort): string =
  case s
  of tsByStation: "station"
  of tsByTime: "time"
  of tsNotKnown: "unknown"

func parseSubSortName*(s: string; v: var TraceSubSort): bool =
  for x in [tsByStation, tsByTime]:
    if subSortName(x) == s:
      v = x
      return true

func applied*(auto: TraceOrder; t: TreatAs): TraceOrder =
  ## The order shown for a file whose automatic order is `auto`: each part forced replaces its
  ## own.
  result = auto
  if t.grouping.isSome: result.grouping = t.grouping.get
  if t.subSort.isSome: result.subSort = t.subSort.get

func applied*(auto: RecordingFacts; t: TreatAs): RecordingFacts =
  ## `auto` with the kind and the order forced (`forced` says the kind is).
  result = auto
  if t.kind.isSome:
    result.kind = t.kind.get
    result.forced = true
    if result.kind == rkReceiverContinuous: result.slicedWhy = swNone
  result.order = applied(auto.order, t)
