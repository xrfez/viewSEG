## The one rule for checking a shot or a receiver gather against the survey's
## relation records (X: a shot's receivers, `rdSource`; O: a receiver's shots,
## `rdReceiver`, loaded or made from the X records), used by the Missing traces
## report, the Records window and the record shown.
##
## A shot is checked against the X records at its source station, a receiver
## gather against the O records at its receiver station (`relationside` tells
## which a gather is, from its stations). The record number in an X or O record
## and a file's FFID are never used to find or choose a relation record, not as
## a fallback or a tie-breaker: a gather that cannot be matched by station is
## unmatched, with the reason in words.
##
## - Several X records at one source (a reshoot): each distinct template is
##   checked, the one that shares the most stations with the data wins, then the
##   one that lacks the fewest; a tie between different templates is unmatched
##   (`bestOfSeveral`).
## - A receiver with several O records: their union is the template
##   (`calledSources`), found by `receiverRecords`; where the survey has the
##   receiver's point at several indices the data's index must say which.

import std/[math, sets, tables]
import parseSEG
import processSEG/qc/record
import processSEG/survey/relwalk
import components, jobs, mapkinds, relationside

export relationside

const
  NoReceiverStation* = "no receiver station in the trace headers: it could only be " &
    "matched to the survey by its record number, which is not trusted"
  NoSourceStation* = "no source station in the trace headers: the sources this receiver " &
    "recorded cannot be told"
  NoXRecords* = "the survey has no X records"
  NoORecord* = "no O record matches this receiver"
  UnknownIndex* = "the trace headers give no receiver index (0) and the survey has this " &
    "point at several indices"

func wholeRecord*(f: float64): int64 =
  ## The record number `f`, or −1 when it is not a whole number.
  if f == f and abs(f) < 9e18 and float64(int64(f)) == f: int64(f) else: -1

func fieldId*(c: RecordCompleteness): int64 =
  ## The header record number, or −1 when it is not a whole number.
  wholeRecord(c.fieldRecord)

func unmatchedWhy*(c: RecordCompleteness): string =
  ## Why a shot record could not be checked against an X record; "" when it
  ## can. A record is never matched to the survey by its record number alone:
  ## without the source station in the trace headers it is not checked.
  if not c.hasSource:
    "no source station in the trace headers: it could only be matched to the survey by " &
      "its record number, which is not trusted"
  elif c.recordMatch == rmFieldRecord and c.sourceMismatch:
    "the record's source station has no X record; X record " & $c.xpsRecord &
      ", matched by file number alone, belongs to another source"
  elif c.xpsRecord < 0: "no X record matches this source"
  else: ""

func templateStations*(g: SurveyGeometry; record: int64): seq[StationKey] =
  ## The entries the relation record `record` calls for, one for each channel
  ## relation (`addGather` counts the stations in them).
  for (_, rel) in g.channelRelations(record): result.add rel.receiver

const SeveralFit* = "several survey records at this source station fit equally: the " &
  "record number alone would decide, and it is not trusted"

proc templateOf*(g: SurveyGeometry; record: int64; byChannel: bool):
    HashSet[tuple[channel: int64; station: StationKey]] =
  ## What X record `record` calls for, as compared between records: its
  ## stations, and their channels when traces are matched by channel.
  result = initHashSet[tuple[channel: int64; station: StationKey]]()
  for (channel, rel) in g.channelRelations(record):
    result.incl (channel: (if byChannel: int64(channel) else: 0'i64), station: rel.receiver)

proc bestOfSeveral*(g: SurveyGeometry; rows: TraceRows; first: RecordCompleteness;
    ctx: JobContext; traceMatch = tmAuto): tuple[c: RecordCompleteness; why: string] =
  ## The shot `rows` checked against each X record at its source station
  ## (`first.candidates`, more than one), the record number left out: the one
  ## whose template shares the most stations with the data, and of those the one
  ## that lacks the fewest. Records with the same template (a reshoot of one
  ## patch) are checked once. A tie on both between different templates is
  ## `why` (`SeveralFit`).
  var keys = newSeq[TraceKeys](rows.len)
  for i in 0 ..< keys.len: keys[i] = rows.keysAt(i)
  let counts = newSeq[int](keys.len)
  let byChannel = first.traceMatch == tmChannel
  var templates: seq[HashSet[tuple[channel: int64; station: StationKey]]] = @[]
  var tied = false
  result = (c: first, why: SeveralFit)
  var best = (present: -1, missing: 0)
  for record in first.candidates:
    ctx.checkCancelled()
    let calls = g.templateOf(record, byChannel)
    if calls notin templates:
      templates.add calls
      # The number put in the keys only makes the library check that one record.
      for k in keys.mitems: k.record = float64(record)
      var c = g.recordCompleteness(rowsOf(keys, counts), rmSourceStation, traceMatch)
      if c.present > best.present or (c.present == best.present and c.missing < best.missing):
        c.fieldRecord = first.fieldRecord
        (best, tied, result.c) = ((present: c.present, missing: c.missing), false, c)
      elif c.present == best.present and c.missing == best.missing:
        tied = true
  result.why = if tied: SeveralFit else: ""


proc shotCheck*(g: SurveyGeometry; rows: TraceRows; ctx: JobContext; traceMatch = tmAuto):
    tuple[c: RecordCompleteness; why: string] =
  ## The shot `rows` checked against its X record, found by its source station
  ## alone (`recordCompleteness`; one record's result when the station has
  ## one, `bestOfSeveral` when it has several). `why` is not empty when the
  ## shot is unmatched: the reason in words, and `c` is not a basis for a check.
  ## A match the library made by the FFID (a source with no X record, or no
  ## source in the headers) is refused by `unmatchedWhy`.
  if g.relationCount(rdSource) == 0:
    result.why = NoXRecords
    return
  result.c = g.recordCompleteness(rows, rmAuto, traceMatch)
  if result.c.recordMatch == rmSourceStation and result.c.candidates.len > 1:
    # Several X records at this source: the data decides, never the record number.
    (result.c, result.why) = g.bestOfSeveral(rows, result.c, ctx, traceMatch)
  if result.why.len == 0: result.why = unmatchedWhy(result.c)

type ORecord* = tuple[index: int16; sources: seq[StationKey]]

proc oRecordsAt*(g: SurveyGeometry; station: StationKey): seq[ORecord] =
  ## The O records of the receiver at `station`'s line and point, at any index,
  ## when they are stored as source-domain records (the receiver as the record's
  ## source, the sources as its receivers: the Missing traces report's form): the
  ## receiver index each is for (0 read as 1) and the sources it calls for.
  for rec in g.recordsAt(station):
    var r: ORecord = (index: -1'i16, sources: @[])
    for (_, rel) in g.channelRelations(rec):
      if r.index < 0: r.index = (if rel.source.index == 0: 1'i16 else: rel.source.index)
      r.sources.add rel.receiver
    if r.index >= 0: result.add r

func calledSources*(records: openArray[ORecord]): seq[StationKey] =
  ## The sources every one of `records` calls for, each once: several O
  ## records of one receiver are one template.
  var listed = initHashSet[StationKey]()
  for rec in records:
    for s in rec.sources:
      if not listed.containsOrIncl(s): result.add s

func namesSource*(keys: openArray[TraceKeys]; traces: Slice[int]): bool =
  ## Whether the headers of `traces` name a source station (a trace that is not
  ## auxiliary): a receiver gather with none cannot be told what it recorded.
  for t in traces:
    if keys[t].status != tsAuxiliary and hasStation(keys[t].srcLine, keys[t].srcPoint):
      return true

func sourceAlternatives*(source: StationKey): array[2, StationKey] =
  ## The keys a source station of a template is heard under: its own, else the same
  ## point with no index (0) in the headers, an index 0 of the template taking the
  ## usual 1. The one rule of Missing traces and of the Records window.
  [stationKey(source.line, source.point, source.index),
   stationKey(source.line, source.point, (if source.index == 0: 1'i16 else: 0'i16))]

proc calledOf*(g: SurveyGeometry; records: openArray[int64]): seq[StationKey] =
  ## The sources the O `records` (`rdReceiver`) call for together, each station
  ## once: a station is its line and point, as the Missing traces report counts it, so
  ## a point called at two indices is one station (the first entry's). The template of a
  ## receiver; the Records window, the shown record and the box all count these.
  var listed = initHashSet[(float64, float64)]()
  for record in records:
    for run in g.relationRuns(record, rdReceiver):
      for i in 0 ..< run.stations:
        let st = run.station(i)
        if not listed.containsOrIncl((st.line, st.point)): result.add st

proc gatherReceiver*(keys: openArray[TraceKeys]; traces: Slice[int]):
    tuple[found: bool; station: StationKey] =
  ## The receiver station (line, point and index) of the first seismic trace of
  ## `traces` whose headers name one.
  for t in traces:
    let k = keys[t]
    if not result.found and k.isSeismic and hasStation(k.rcvLine, k.rcvPoint):
      result = (true, stationKey(k.rcvLine, k.rcvPoint, k.rcvIndex))

proc receiverRecords*(g: SurveyGeometry; rcv: StationKey):
    tuple[records: seq[int64]; why: string] =
  ## The O records (`rdReceiver`) of receiver `rcv`, by its station alone: all
  ## of them, their union being the template. Where the survey has the point at
  ## several receiver indices and `rcv` names none (0), the records are not
  ## told, and `why` says so; `why` is empty when they are.
  result.records = g.recordsAt(rcv, rdReceiver)
  if result.records.len == 0:
    result.why = NoORecord
    return
  if rcv.index == 0:
    var indices: seq[int16] = @[]
    for rec in result.records:
      for run in g.relationRuns(rec, rdReceiver):
        let i = if run.fixed.index == 0: 1'i16 else: run.fixed.index
        if i notin indices: indices.add i
        break
    if indices.len > 1:
      result.records = @[]
      result.why = UnknownIndex

type Plan* = Table[(float64, float64), set[int16]]
  ## the stations a record plans, by line and point: their indices

func planned*(p: Plan; line, point: float64; index: int16): bool =
  ## Whether the plan lists the station: a header index 0 (not known) any
  ## index, an index 1 also one the plan gives without (0).
  let key = (line, point)
  if key notin p: return false
  let indices = p[key]
  index <= 0 or index in indices or (index == 1 and 0'i16 in indices)

proc plannedOf*(g: SurveyGeometry; records: openArray[int64]; domain: RelationDomain): Plan =
  ## What `records` plan together (several O records of one receiver: their union).
  for record in records:
    for run in g.relationRuns(record, domain):
      for i in 0 ..< run.stations:
        let st = run.station(i)
        result.mgetOrPut((st.line, st.point), {}).incl st.index

func recordsWords(records: openArray[int64]): string =
  for i, r in records:
    if i > 0: result.add ", "
    result.add $r

proc placeTraces*(hits: var array[MapFilter, FilterHits]; keys: openArray[TraceKeys];
    base: int; traces: Slice[int]; g: SurveyGeometry; records: openArray[int64];
    domain: RelationDomain) =
  ## The record's (`traces` of `keys`; trace 0 survey-wide `base`) traces at
  ## stations the relation `records` of `domain` (one X record; the O records of
  ## one receiver, their union) do not plan
  ## (`mfUnlisted`) and recorded twice (`mfDuplicate`), placed by their
  ## receiver (a shot) or source (a receiver gather) station, keyed as
  ## parseSEG keys stations (to 1/100: a SEG-D station decoded from a binary
  ## fraction is the survey file's). For a receiver gather also the counts,
  ## and the stations planned it lacks (`mfMissing`); a shot's are
  ## `recordCompleteness`'s, set before.
  let plan = g.plannedOf(records, domain)
  var seen: Table[(StationKey, uint8), int] # station (index 0 for none) and component: first trace
  var have: HashSet[(float64, float64)] # the sources heard, by line and point
  var dupStations: HashSet[(float64, float64)]
  var firsts: HashSet[int] # the first trace of each key recorded twice, listed
  for t in traces:
    let k = keys[t]
    if k.isSeismic:
      let (line, point, index) = if domain == rdSource: (k.rcvLine, k.rcvPoint, k.rcvIndex)
                                 else: (k.srcLine, k.srcPoint, k.srcIndex)
      if hasStation(line, point):
        let st = stationKey(line, point, max(index, 0'i16))
        have.incl (st.line, st.point)
        if not plan.planned(st.line, st.point, index) and k.status != tsDead:
          hits[mfUnlisted].traces.add base + t
        let key = (st, componentOf(k))
        if key in seen:
          dupStations.incl (st.line, st.point)
          if not firsts.containsOrIncl(seen[key]):
            hits[mfDuplicate].traces.add base + seen[key]
          hits[mfDuplicate].traces.add base + t
        else: seen[key] = t
  if domain == rdReceiver:
    # Counted here: the O records' sources the gather lacks, by line and point as the
    # Missing traces report counts them (`calledOf`).
    var unlisted: HashSet[(float64, float64)]
    let called = g.calledOf(records)
    for st in called:
      if (st.line, st.point) notin have: hits[mfMissing].stations.add st
    for t in hits[mfUnlisted].traces:
      let k = keys[t - base]
      let st = stationKey(k.srcLine, k.srcPoint, 0)
      unlisted.incl (st.line, st.point)
    hits[mfMissing].count = hits[mfMissing].stations.len
    let which = (if records.len == 1: "O record " else: "O records ") & recordsWords(records)
    hits[mfMissing].note = "shots of the " & $called.len & " " & which & " plans"
    hits[mfUnlisted].count = unlisted.len
    hits[mfUnlisted].note = "sources of its traces that " & which & " does not list"
    hits[mfDuplicate].count = dupStations.len
    hits[mfDuplicate].note = "sources with two traces of one component"

proc placeTraces*(hits: var array[MapFilter, FilterHits]; keys: openArray[TraceKeys];
    base: int; traces: Slice[int]; g: SurveyGeometry; record: int64; domain: RelationDomain) =
  ## `placeTraces` for one relation record.
  hits.placeTraces(keys, base, traces, g, [record], domain)
