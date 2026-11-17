## The map's filters on the record shown (`MapFilter`): what reading the
## record finds, on a job (`recordQcWork`), for each filter in `TraceFilters`.
##
## - **Traces that failed:** marked dead in the headers, auxiliary (not
##   seismic), not decodable (parseSEG could not decode their samples).
## - **The amplitude flags** of processSEG's `qc/amplitude` with its default
##   thresholds (`AmplitudeParams()`): each seismic trace's statistics
##   (`traceAmplitudeInto`, a chunk of traces at a time, so a record of any
##   size is read in bounded memory) after a reversed trace is multiplied by
##   -1 and that trace's own filter, then the
##   record's (`recordAmplitude`, over its seismic traces: weak and noisy
##   against their median).
## - **Against the template** (the relation records of the record's domain:
##   a shot's X record, found as processSEG's `recordCompleteness` finds it,
##   or a receiver gather's O record), the stations planned that the record
##   lacks (`missingStations`), its traces at stations the record does not
##   list, and its stations recorded twice. A record whose headers name no
##   station of the role its record is found by (a SEG-Y file without a
##   header layout naming them) is checked with the station the state found
##   at its place (`placed`, the survey file's station there): the check is
##   given the record's keys with that station in them, as a join would fill
##   them. The record checked against is posted (`RecordQc.record`), and the
##   map's template box draws that record's spread: the box and the filters
##   never name two records. The counts are the library's
##   (stations); the traces are found here by the same rules (the header's
##   station with its index, index 0 any; one component counted once), so
##   that the map can place them. Without stations in the headers (traces
##   matched by channel) the counts are given and the traces not placed.
##
## The job reads the file (it is in its `reads`) and the relation records in
## place: the caller keeps them alive and unchanged until it ends.
## Everything else the filters show (killed and reversed traces, traces
## without a position, shots whose spread differs) is the state's own
## (`core/state`'s `filterHits`).

import std/[algorithm, math, sets, tables]
import parseSEG
import processSEG/core/[rows, types, workspace]
import processSEG/pipeline
import processSEG/qc/[amplitude, record]
import components, filesystem, inbox, jobs, mapkinds, processing, session, threads

export mapkinds

const QcChunk* = 512 ## traces read and measured at a time

type
  Placed* = tuple[found: bool; station: StationKey]
    ## the station of the role a record's relation record is found by (a
    ## shot's source, a receiver gather's receiver) at the record's place,
    ## when its headers name none: the survey file's station there

  RecordQc* = object
    ## The record shown's filters, as its job found them.
    job*: JobId = NoJob                 ## the job reading it; `NoJob` for none
    key*: tuple[file: SessionId; gather, keys: int; relations: pointer; domain: RelationDomain;
        recordMatch: RecordMatch; traceMatch: TraceMatch; placed: Placed; samples: bool;
        own: string]
      ## what the job, or `hits`, were made from
    hits*: array[MapFilter, FilterHits] ## of the filters in `TraceFilters`
    record*: int64 = -1
      ## the relation record (X: a shot's; O: a receiver gather's) the job
      ## checked the record against; -1 for none, or while it runs
    byPlace*: bool ## found with the station at the record's place (`Placed`)
    revision*: int ## bumped when `hits` change
    replaced*: seq[JobId] ## jobs given up for a newer record: they end quietly

const
  AmplitudeFilters: array[AmplitudeFlag, MapFilter] = [mfNotANumber, mfAllZero,
    mfConstant, mfClipped, mfSpiky, mfDcOffset, mfWeak, mfNoisy]
  SampleFilters* = {mfUndecodable, mfNoisy, mfClipped, mfSpiky, mfConstant, mfWeak,
    mfDcOffset, mfAllZero, mfNotANumber}
    ## the filters of `TraceFilters` that read the record's samples

func hasStation(line, point: float64): bool {.inline.} =
  # As processSEG's completeness: both zero is a header left empty.
  abs(line) < Inf and abs(point) < Inf and not (line == 0 and point == 0)

type Plan = Table[(float64, float64), set[int16]]
  ## the stations a record plans, by line and point: their indices

func planned(p: Plan; line, point: float64; index: int16): bool =
  ## Whether the plan lists the station: a header index 0 (not known) any
  ## index, an index 1 also one the plan gives without (0).
  let key = (line, point)
  if key notin p: return false
  let indices = p[key]
  index <= 0 or index in indices or (index == 1 and 0'i16 in indices)

proc plannedOf(g: SurveyGeometry; record: int64; domain: RelationDomain): Plan =
  for run in g.relationRuns(record, domain):
    for i in 0 ..< run.stations:
      let st = run.station(i)
      result.mgetOrPut((st.line, st.point), {}).incl st.index

proc placeTraces*(hits: var array[MapFilter, FilterHits]; keys: openArray[TraceKeys];
    base: int; traces: Slice[int]; g: SurveyGeometry; record: int64; domain: RelationDomain) =
  ## The record's (`traces` of `keys`; trace 0 survey-wide `base`) traces at
  ## stations relation record `record` of `domain` does not plan
  ## (`mfUnlisted`) and recorded twice (`mfDuplicate`), placed by their
  ## receiver (a shot) or source (a receiver gather) station, keyed as
  ## parseSEG keys stations (to 1/100: a SEG-D station decoded from a binary
  ## fraction is the survey file's). For a receiver gather also the counts,
  ## and the stations planned it lacks (`mfMissing`); a shot's are
  ## `recordCompleteness`'s, set before.
  let plan = g.plannedOf(record, domain)
  var seen: Table[(StationKey, uint8), int] # station (index 0 for none) and component: first trace
  var have: HashSet[(float64, float64)]
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
    # Counted here: the O record's stations the gather lacks (as stations).
    var counted: HashSet[(float64, float64)]
    var unlisted: HashSet[(float64, float64)]
    for run in g.relationRuns(record, domain):
      for i in 0 ..< run.stations:
        let st = run.station(i)
        if (st.line, st.point) notin have and not counted.containsOrIncl((st.line, st.point)):
          hits[mfMissing].stations.add st
    for t in hits[mfUnlisted].traces:
      let k = keys[t - base]
      let st = stationKey(k.srcLine, k.srcPoint, 0)
      unlisted.incl (st.line, st.point)
    hits[mfMissing].count = hits[mfMissing].stations.len
    hits[mfMissing].note = "shots of the " & $plan.len & " O record " & $record & " plans"
    hits[mfUnlisted].count = unlisted.len
    hits[mfUnlisted].note = "sources of its traces that O record " & $record & " does not list"
    hits[mfDuplicate].count = dupStations.len
    hits[mfDuplicate].note = "sources with two traces of one component"

func namesSource(f: SeismicFile; traces: Slice[int]): bool =
  ## Whether the headers of the record's traces name a source station, as
  ## `recordCompleteness` looks for one (a trace that is not auxiliary).
  for t in traces:
    let k = f.index.keys[t]
    if k.status != tsAuxiliary and hasStation(k.srcLine, k.srcPoint): return true
  false

proc withSource(f: SeismicFile; traces: Slice[int]; st: StationKey): seq[TraceKeys] =
  ## The keys of the record's traces with source station `st` in them.
  result = newSeq[TraceKeys](traces.len)
  for t in traces:
    let i = t - traces.a
    result[i] = f.index.keys[t]
    if result[i].status != tsAuxiliary:
      (result[i].srcLine, result[i].srcPoint, result[i].srcIndex) = (st.line, st.point, st.index)

proc completeness(hits: var array[MapFilter, FilterHits]; f: SeismicFile; base: int;
    traces: Slice[int]; g: SurveyGeometry; against: string; domain: RelationDomain;
    recordMatch: RecordMatch; traceMatch: TraceMatch; placed: Placed;
    byPlace: var bool): int64 =
  ## The stations planned that the record lacks, its traces at stations not
  ## planned, and its stations recorded twice; the relation record they are
  ## of (-1 for none). `byPlace`: found with the station `placed`.
  result = -1
  for m in [mfMissing, mfUnlisted, mfDuplicate]: hits[m].state = fsDone
  template notChecked(why: string) =
    for m in [mfMissing, mfUnlisted, mfDuplicate]:
      (hits[m].state, hits[m].note) = (fsNotChecked, why)
  var record = -1'i64
  var byStation = true
  byPlace = false
  if domain == rdSource:
    var c: RecordCompleteness
    if placed.found and not f.namesSource(traces):
      # No source station in the headers: the survey file's at the record's
      # place, given to the check as a join would fill it.
      let keys = f.withSource(traces, placed.station)
      let counts = newSeq[int](keys.len)
      c = g.recordCompleteness(rowsOf(keys, counts), recordMatch, traceMatch)
      byPlace = true
    else:
      c = g.recordCompleteness(f.rowsOf(traces), recordMatch, traceMatch)
    if c.xpsRecord < 0:
      notChecked("no X record of " & against & " is this record's (" &
        (if c.candidates.len > 1: "its source has " & $c.candidates.len & " and the FFID " &
          "chooses none" else: "by its source station or its FFID") & ")")
      return
    record = c.xpsRecord
    result = record
    byStation = c.traceMatch == tmStation
    hits[mfMissing].stations = c.missingStations
    hits[mfMissing].count = c.missing
    hits[mfMissing].note = "stations of the " & $c.expected & " X record " & $record &
      " plans"
    hits[mfUnlisted].count = c.unlisted
    hits[mfUnlisted].note = "stations with live traces that X record " & $record &
      " does not list"
    hits[mfDuplicate].count = c.duplicates
    hits[mfDuplicate].note = "stations with two traces of one component"
  else:
    # A receiver gather: its O record, by its receiver station.
    var rcv: StationKey
    var found = false
    for t in traces:
      let k = f.index.keys[t]
      if not found and k.isSeismic and hasStation(k.rcvLine, k.rcvPoint):
        (rcv, found) = (stationKey(k.rcvLine, k.rcvPoint, k.rcvIndex), true)
    if not found and placed.found:
      (rcv, found, byPlace) = (placed.station, true, true)
    let records = if found: g.recordsAt(rcv, rdReceiver) else: @[]
    if records.len == 0:
      notChecked(if found: "no O record of " & against & " is this receiver's"
        else: "its headers name no receiver station")
      return
    record = records[0]
    result = record
  if not byStation:
    for m in [mfMissing, mfUnlisted, mfDuplicate]:
      hits[m].note.add " (matched by channel: not placed)"
    return
  hits.placeTraces(f.index.keys, base, traces, g, record, domain)

proc negateQc(samples: var Tensor[float32]; part: Slice[int]; reversed: openArray[int]) =
  ## Multiplies each reversed trace of `part` by -1, before its own filter
  ## and the amplitude flags. A sign flip, not a filter.
  if reversed.len == 0: return
  let b = rowBlock(samples)
  for i in 0 ..< part.len:
    if reversed.binarySearch(part.a + i) >= 0:
      let row = b.rowPtr(i)
      for j in 0 ..< b.cols: row[j] = -row[j]

proc applyOwnQc(samples: var Tensor[float32]; f: SeismicFile; part: Slice[int];
    own: openArray[FilterEntry]; ws: var Workspace) =
  ## Each trace of `part`'s own frequency filter, on `samples`, before the
  ## amplitude flags. A filter that only runs instead of the plot's, with no
  ## frequency filter of its own, changes nothing here: the check has no
  ## plot filters.
  if own.len == 0: return
  var list = newSeq[int](part.len)
  for i in 0 ..< part.len: list[i] = part.a + i
  var any = false
  for t in list:
    let at = entryAt(own, t)
    if at >= 0 and own[at].filter.spec.hasFilters: any = true
  if not any: return
  let b = rowBlock(samples)
  var keys: seq[TraceKeys] = @[]
  var lengths: seq[int] = @[]
  let rows = f.rowsOf(part).auxLiveRows(keys, lengths)
  var seen: seq[int]
  for k, t in list:
    let at = entryAt(own, t)
    if at >= 0 and own[at].filter.spec.hasFilters and k notin seen:
      let filt = own[at].filter
      var group = @[k]
      seen.add k
      for j in k + 1 ..< list.len:
        let aj = entryAt(own, list[j])
        if aj >= 0 and own[aj].filter == filt:
          group.add j
          seen.add j
      var skip = newSeqOfCap[int](b.len - group.len)
      var g = 0
      for row in 0 ..< b.len:
        if g < group.len and group[g] == row: inc g
        else: skip.add row
      let dt = f.index.keys[t].intervalUs / 1000
      let pipe = filt.ownPipeline(if dt > 0: dt else: 1.0)
      if pipe.len > 0:
        let plan = pipe.compile(float32, (if dt > 0: dt else: 1.0), b.cols, recordSamples = b.cols)
        ws.reserve(plan)
        plan.apply(b, initChunkMeta(rows, (if dt > 0: dt else: 1.0), 0, skip), ws)

proc recordQcWork*(file: ptr SeismicFile; path: string; session: SessionId; base, gather: int;
    traces: Slice[int]; domain: RelationDomain; relations: ptr SurveyGeometry;
    against: string; recordMatch: RecordMatch; traceMatch: TraceMatch; placed: Placed;
    samples: bool; own: seq[FilterEntry]; reversed: seq[int]; to: Poster): JobWork =
  ## The work of a job that reads gather `gather` (`traces`) of open file
  ## `session` (`file`, at `path`; its trace 0 is survey-wide `base`) and
  ## posts what the filters in `TraceFilters` find in it (`mkRecordQc`):
  ## the record's traces dead in the headers, auxiliary, not decodable, the
  ## amplitude flags, and, with `relations` (named `against`; nil for none),
  ## what the template of `domain` plans that the record lacks, its traces
  ## not in it and its stations recorded twice, with the relation record
  ## that is (found with station `placed` when the headers name none).
  ## Without `samples` (only the template box, or filters of the keys, ask),
  ## from the keys alone: the filters that need the samples (not decodable,
  ## the amplitude flags) are said not checked. `own` is each trace's own
  ## filter; `reversed` the traces multiplied by -1 first, both before the
  ## amplitude flags. Submitted with the file in
  ## `reads`; `relations` is read in place, never copied.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var hits: array[MapFilter, FilterHits]
    for m in TraceFilters: hits[m].state = fsDone
    var revision = 0
    var record = -1'i64
    var byPlace = false
    {.cast(gcsafe).}:
      template f: untyped = file[]
      revision = f.keysRevision
      let n = traces.len
      var amps = newSeq[TraceAmplitude](n)
      var ws = initWorkspace()
      let cols = max(1, f.maxSamples(traces))
      ws.reserve(traceAmplitudeWorkspace(cols))
      ctx.setPhase "reading the record"
      discard f.cutShort # parseSEG's guard: stale cached bytes are not read past a cut
      var first = if samples: traces.a else: traces.b + 1
      while first <= traces.b:
        let part = first .. min(traces.b, first + QcChunk - 1)
        fs.mappedRead(path) # (tests: the drive's next pages come late)
        var log: DiagLog
        var samples = f.readTraces(part, 0 ..< cols, log)
        if reversed.len > 0: negateQc(samples, part, reversed)
        if own.len > 0: applyOwnQc(samples, f, part, own, ws)
        var failed: seq[int]
        for d in log:
          # (a trace the file's cut or its drive made unreadable is not an
          # undecodable one: it is left out of that count)
          if d.loc.trace in part and (d.loc.trace - part.a) notin failed:
            failed.add d.loc.trace - part.a
        var notDecoded: seq[int]
        for r in failed:
          var unread = false
          for d in log:
            if d.loc.trace == part.a + r and d.code in {dcTruncated, dcIo}: unread = true
          if not unread: notDecoded.add r
        failed.sort()
        for r in notDecoded: hits[mfUndecodable].traces.add base + part.a + r
        let dt = f.index.keys[part.a].intervalUs / 1000
        let meta = initChunkMeta(f.rowsOf(part), (if dt > 0: dt else: 1.0), 0, failed)
        traceAmplitudeInto(samples, meta, AmplitudeParams(), amps.toOpenArray(part.a - traces.a,
          part.b - traces.a), ws)
        if not ctx.progress(part.b - traces.a + 1, n):
          raise newException(JobCancelledError, "cancelled")
        first = part.b + 1
      # The record's statistics over its seismic traces.
      var seismic: seq[int]
      for i in 0 ..< n:
        let k = f.index.keys[traces.a + i]
        if not k.isSeismic: hits[mfAuxiliary].traces.add base + traces.a + i
        else:
          seismic.add i
          if k.status == tsDead: hits[mfDead].traces.add base + traces.a + i
      var stats = newSeq[TraceAmplitude](seismic.len)
      for j, i in seismic: stats[j] = amps[i]
      if samples:
        ws.reserve(recordAmplitudeWorkspace(stats.len))
        discard recordAmplitude(stats, AmplitudeParams(), ws)
        for j, i in seismic:
          for flag in stats[j].flags: hits[AmplitudeFilters[flag]].traces.add base + traces.a + i
      for m in TraceFilters - {mfMissing, mfUnlisted, mfDuplicate}:
        hits[m].count = hits[m].traces.len
        hits[m].note = "traces"
      if not samples:
        for m in SampleFilters:
          (hits[m].state, hits[m].note) = (fsNotChecked, "the samples were not read")
      if relations.isNil:
        for m in [mfMissing, mfUnlisted, mfDuplicate]:
          (hits[m].state, hits[m].note) = (fsNotChecked, "no relation file is loaded, and " &
            "no template generated")
      else:
        ctx.setPhase "checking the record against the template"
        try:
          record = hits.completeness(f, base, traces, relations[], against, domain,
            recordMatch, traceMatch, placed, byPlace)
        except ValueError as e:
          for m in [mfMissing, mfUnlisted, mfDuplicate]:
            (hits[m].state, hits[m].note) = (fsNotChecked, e.msg)
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkRecordQc, qcSession: session, qcGather: gather,
      qcKeys: revision, qcHits: move hits, qcRecord: record, qcByPlace: byPlace)
