## The map's filters on the record shown (`MapFilter`): what reading the
## record finds, on a job (`recordQcWork`), for each filter in `TraceFilters`.
##
## - **Traces that failed:** marked dead in the headers, auxiliary (not
##   seismic), not decodable (parseSEG could not decode their samples).
## - **The amplitude flags** of processSEG's `qc/amplitude` with its default
##   thresholds (`AmplitudeParams()`): each seismic trace's statistics
##   (`traceAmplitudeInto`, a chunk of traces at a time, so a record of any
##   size is read in bounded memory), then the record's (`recordAmplitude`,
##   over its seismic traces: weak and noisy against their median).
## - **Against the template** (the relation records of the record's domain:
##   a shot's X record, found as processSEG's `recordCompleteness` finds it,
##   or a receiver gather's O record), the stations planned that the record
##   lacks (`missingStations`), its traces at stations the record does not
##   list, and its stations recorded twice. The counts are the library's
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
import processSEG/core/[types, workspace]
import processSEG/qc/[amplitude, record]
import filesystem, inbox, jobs, mapkinds, session, threads

export mapkinds

const QcChunk* = 512 ## traces read and measured at a time

type
  RecordQc* = object
    ## The record shown's filters, as its job found them.
    job*: JobId = NoJob                 ## the job reading it; `NoJob` for none
    key*: tuple[file: SessionId; gather, keys: int; relations: pointer; domain: RelationDomain]
      ## what the job, or `hits`, were made from
    hits*: array[MapFilter, FilterHits] ## of the filters in `TraceFilters`
    revision*: int                      ## bumped when `hits` change
    replaced*: seq[JobId]               ## jobs given up for a newer record: they end quietly

const AmplitudeFilters: array[AmplitudeFlag, MapFilter] = [mfNotANumber, mfAllZero,
  mfConstant, mfClipped, mfSpiky, mfDcOffset, mfWeak, mfNoisy]

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

proc completeness(hits: var array[MapFilter, FilterHits]; f: SeismicFile; base: int;
    traces: Slice[int]; g: SurveyGeometry; against: string; domain: RelationDomain;
    recordMatch: RecordMatch; traceMatch: TraceMatch) =
  ## The stations planned that the record lacks, its traces at stations not
  ## planned, and its stations recorded twice.
  for m in [mfMissing, mfUnlisted, mfDuplicate]: hits[m].state = fsDone
  template notChecked(why: string) =
    for m in [mfMissing, mfUnlisted, mfDuplicate]:
      (hits[m].state, hits[m].note) = (fsNotChecked, why)
  var record = -1'i64
  var byStation = true
  if domain == rdSource:
    let c = g.recordCompleteness(f.rowsOf(traces), recordMatch, traceMatch)
    if c.xpsRecord < 0:
      notChecked("no X record of " & against & " is this record's (" &
        (if c.candidates.len > 1: "its source has " & $c.candidates.len & " and the FFID " &
          "chooses none" else: "by its source station or its FFID") & ")")
      return
    record = c.xpsRecord
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
    let records = if found: g.recordsAt(rcv, rdReceiver) else: @[]
    if records.len == 0:
      notChecked(if found: "no O record of " & against & " is this receiver's"
        else: "its headers name no receiver station")
      return
    record = records[0]
  if not byStation:
    for m in [mfMissing, mfUnlisted, mfDuplicate]:
      hits[m].note.add " (matched by channel: not placed)"
    return
  # The traces, placed: by their receiver (a shot) or source (a receiver gather) station.
  let plan = g.plannedOf(record, domain)
  var seen: Table[(float64, float64, int16, uint8), int]       # station and component: first trace
  var have: HashSet[(float64, float64)]
  var dup: HashSet[int]
  for t in traces:
    let k = f.index.keys[t]
    if k.isSeismic:
      let (line, point, index) = if domain == rdSource: (k.rcvLine, k.rcvPoint, k.rcvIndex)
                                 else: (k.srcLine, k.srcPoint, k.srcIndex)
      if hasStation(line, point):
        have.incl (line, point)
        if not plan.planned(line, point, index) and k.status != tsDead:
          hits[mfUnlisted].traces.add base + t
        let key = (line, point, max(index, 0'i16), k.component)
        if key in seen:
          if seen[key] notin dup:
            dup.incl seen[key]
            hits[mfDuplicate].traces.add base + seen[key]
          hits[mfDuplicate].traces.add base + t
        else: seen[key] = t
  if domain == rdReceiver:
    # Counted here: the O record's stations the gather lacks (as stations).
    var planned: seq[StationKey]
    for run in g.relationRuns(record, domain):
      for i in 0 ..< run.stations: planned.add run.station(i)
    var counted: HashSet[(float64, float64)]
    var unlisted: HashSet[(float64, float64)]
    for st in planned:
      if (st.line, st.point) notin have and not counted.containsOrIncl((st.line, st.point)):
        hits[mfMissing].stations.add st
    for t in hits[mfUnlisted].traces:
      let k = f.index.keys[t - base]
      unlisted.incl (k.srcLine, k.srcPoint)
    hits[mfMissing].count = hits[mfMissing].stations.len
    hits[mfMissing].note = "shots of the " & $plan.len & " O record " & $record & " plans"
    hits[mfUnlisted].count = unlisted.len
    hits[mfUnlisted].note = "sources of its traces that O record " & $record & " does not list"
    hits[mfDuplicate].count = dup.len div 2
    hits[mfDuplicate].note = "sources with two traces of one component"

proc recordQcWork*(file: ptr SeismicFile; path: string; session: SessionId; base, gather: int;
    traces: Slice[int]; domain: RelationDomain; relations: ptr SurveyGeometry;
    against: string; recordMatch: RecordMatch; traceMatch: TraceMatch; to: Poster): JobWork =
  ## The work of a job that reads gather `gather` (`traces`) of open file
  ## `session` (`file`, at `path`; its trace 0 is survey-wide `base`) and
  ## posts what the filters in `TraceFilters` find in it (`mkRecordQc`):
  ## the record's traces dead in the headers, auxiliary, not decodable, the
  ## amplitude flags, and, with `relations` (named `against`; nil for none),
  ## what the template of `domain` plans that the record lacks, its traces
  ## not in it and its stations recorded twice. Submitted with the file in
  ## `reads`; `relations` is read in place, never copied.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var hits: array[MapFilter, FilterHits]
    for m in TraceFilters: hits[m].state = fsDone
    var revision = 0
    {.cast(gcsafe).}:
      template f: untyped = file[]
      revision = f.keysRevision
      let n = traces.len
      var amps = newSeq[TraceAmplitude](n)
      var ws = initWorkspace()
      let cols = max(1, f.maxSamples(traces))
      ws.reserve(traceAmplitudeWorkspace(cols))
      ctx.setPhase "reading the record"
      var first = traces.a
      while first <= traces.b:
        let part = first .. min(traces.b, first + QcChunk - 1)
        fs.mappedRead(path) # (tests: the drive's next pages come late)
        var log: DiagLog
        var samples = f.readTraces(part, 0 ..< cols, log)
        var failed: seq[int]
        for d in log:
          if d.loc.trace in part and (d.loc.trace - part.a) notin failed:
            failed.add d.loc.trace - part.a
        failed.sort()
        for r in failed: hits[mfUndecodable].traces.add base + part.a + r
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
      ws.reserve(recordAmplitudeWorkspace(stats.len))
      discard recordAmplitude(stats, AmplitudeParams(), ws)
      for j, i in seismic:
        for flag in stats[j].flags: hits[AmplitudeFilters[flag]].traces.add base + traces.a + i
      for m in TraceFilters - {mfMissing, mfUnlisted, mfDuplicate}:
        hits[m].count = hits[m].traces.len
        hits[m].note = "traces"
      if relations.isNil:
        for m in [mfMissing, mfUnlisted, mfDuplicate]:
          (hits[m].state, hits[m].note) = (fsNotChecked, "no relation file is loaded, and " &
            "no template generated")
      else:
        ctx.setPhase "checking the record against the template"
        try:
          hits.completeness(f, base, traces, relations[], against, domain, recordMatch,
            traceMatch)
        except ValueError as e:
          for m in [mfMissing, mfUnlisted, mfDuplicate]:
            (hits[m].state, hits[m].note) = (fsNotChecked, e.msg)
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkRecordQc, qcSession: session, qcGather: gather,
      qcKeys: revision, qcHits: move hits)
