## The map's filters on the record shown (`MapFilter`): what reading the
## record finds, on a job (`recordQcWork`), for each filter in `TraceFilters`.
##
## - **Traces that failed:** marked dead in the headers, auxiliary (not
##   seismic), not decodable (parseSEG could not decode their samples).
## - **The amplitude flags** of processSEG's `qc/amplitude` with its default
##   thresholds (`AmplitudeParams()`): each seismic trace's statistics
##   (`traceAmplitudeInto`, a chunk of traces at a time, so a record of any
##   size is read in bounded memory) after a reversed trace is multiplied by
##   -1, shifted by its stored time shift, then that trace's own filter, then
##   the record's noisy-trace test
##   (processSEG's `qc/exclusion`, `noiseQc`, with the area the user chose,
##   `core/noisearea`): the traces near the source (or, in a receiver
##   gather, the shots near the receiver) are left out of the judgement, the
##   noisy and weak ones are found against those outside the area, and
##   the traces louder than their neighbours on the line are their own
##   finding (`mfLouder`). The traces not judged are `mfNotJudged`, and the
##   result says which rule set the area (`NoiseSummary`). The test needs the
##   record's first breaks and their model: the first-break overlay's job
##   (`core/firstbreakjobs`) finds them, and this job takes them from it
##   (`NoiseWork.shared`) or, when none is there, finds them itself and
##   posts them for the overlay, so a record is picked once.
## - **Against the template** (the relation records of the record's domain:
##   a shot's X record, found by its source station (`core/relationcheck`), or
##   a receiver gather's O records, found by its receiver station and checked
##   together; a record number is never used to find one), the stations planned that the record
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
import processSEG/qc/[amplitude, exclusion, record]
import components, correlateread, edits, filesystem, firstbreakjobs, firstbreaks, inbox, jobs,
  mapkinds, noisearea, processing, relationcheck, session, threads

export mapkinds, relationcheck.placeTraces

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
        traceMatch: TraceMatch; placed: Placed; samples: bool;
        own: string; noise: NoiseSettings; breaks: BreakKey; share: int]
      ## what the job, or `hits`, were made from (`noise`, `breaks` and `share` only when the
      ## noisy-trace test runs: `share` 0 finds the first breaks itself, 1 waits for the
      ## overlay's job to end, 2 takes the overlay's result)
    hits*: array[MapFilter, FilterHits] ## of the filters in `TraceFilters`
    record*: int64 = -1
      ## the relation record (X: a shot's; O: the first of a receiver's) the job
      ## checked the record against; -1 for none, or while it runs
    records*: seq[int64]
      ## all the relation records it was checked against: a shot's X record, or
      ## the O records of the receiver's station, together one template
    byPlace*: bool ## found with the station at the record's place (`Placed`)
    onStations*: bool
      ## the traces are matched to the record's stations (not by channel): the traces the
      ## template does not list (`hits[mfUnlisted]`) are known
    noise*: NoiseSummary ## what the noisy-trace test found in the record (`ready` once it has)
    picks*: bool
      ## the job finds the record's first breaks itself, and posts them (`pickKey`): the
      ## overlay waits for them instead of starting a second job
    pickKey*: BreakKey
    revision*: int ## bumped when `hits` change
    replaced*: seq[JobId] ## jobs given up for a newer record: they end quietly

const
  AmplitudeFilters: array[AmplitudeFlag, MapFilter] = [mfNotANumber, mfAllZero,
    mfConstant, mfClipped, mfSpiky, mfDcOffset, mfWeak, mfNoisy]
  SampleFilters* = {mfUndecodable, mfNoisy, mfClipped, mfSpiky, mfConstant, mfWeak,
    mfDcOffset, mfAllZero, mfNotANumber, mfLouder, mfNotJudged}
    ## the filters of `TraceFilters` that read the record's samples

type NoiseWork* = object
  ## What the noisy-trace test of a record's job is given.
  on*: bool      ## run it (a filter of `NoiseFilters` is on)
  settings*: NoiseSettings
  key*: BreakKey ## the first breaks it needs: the record, its keys, its killed traces
  shared*: FirstBreaks
    ## the record's first breaks when they exist (`bkDone`): used, not found again; else
    ## the job finds them and posts them

func namesSource(f: SeismicFile; traces: Slice[int]): bool =
  ## Whether the headers of the record's traces name a source station, as
  ## `recordCompleteness` looks for one (a trace that is not auxiliary).
  for t in traces:
    let k = f.index.keys[t]
    if k.status != tsAuxiliary and hasStation(k.srcLine, k.srcPoint): return true
  false

func hasNoSources(f: SeismicFile; traces: Slice[int]): bool =
  not f.index.keys.namesSource(traces)

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
    traceMatch: TraceMatch; placed: Placed; ctx: JobContext;
    byPlace, onStations: var bool): seq[int64] =
  ## The stations planned that the record lacks, its traces at stations not
  ## planned, and its stations recorded twice; the relation records they are
  ## of (none: empty). A shot has one X record, found by its source station
  ## (`shotCheck`); a receiver gather has the O records of its receiver
  ## station, their union its template. The record's number is never used to
  ## find either. `byPlace`: found with the station `placed`. `onStations`:
  ## the traces are matched to the record's stations (not by channel), so
  ## which are in the template is known.
  result = @[]
  onStations = false
  for m in [mfMissing, mfUnlisted, mfDuplicate]: hits[m].state = fsDone
  template notChecked(why: string) =
    for m in [mfMissing, mfUnlisted, mfDuplicate]:
      (hits[m].state, hits[m].note) = (fsNotChecked, why)
  var byStation = true
  byPlace = false
  if domain == rdSource:
    var checked: tuple[c: RecordCompleteness; why: string]
    if placed.found and not f.namesSource(traces):
      # No source station in the headers: the survey file's at the record's
      # place, given to the check as a join would fill it.
      let keys = f.withSource(traces, placed.station)
      let counts = newSeq[int](keys.len)
      checked = g.shotCheck(rowsOf(keys, counts), ctx, traceMatch)
      byPlace = true
    else:
      checked = g.shotCheck(f.rowsOf(traces), ctx, traceMatch)
    let c = checked.c
    if checked.why.len > 0:
      notChecked("this record is unmatched in " & against & ": " & checked.why)
      return
    let record = c.xpsRecord
    result = @[record]
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
    # A receiver gather: the O records of its receiver station, together.
    var (found, rcv) = f.index.keys.gatherReceiver(traces)
    if not found and placed.found:
      (rcv, found, byPlace) = (placed.station, true, true)
    if not found:
      notChecked("this record is unmatched in " & against & ": the headers name no " &
        "receiver station")
      return
    let (records, why) = g.receiverRecords(rcv)
    if records.len == 0:
      notChecked("this record is unmatched in " & against & ": " & why)
      return
    result = records # (the box names them even when the filters cannot be checked)
    if f.hasNoSources(traces):
      # What the receiver recorded cannot be told: no count of the shots it lacks
      notChecked("this record is unmatched in " & against & ": " & NoSourceStation)
      return
  if not byStation:
    for m in [mfMissing, mfUnlisted, mfDuplicate]:
      hits[m].note.add " (matched by channel: not placed)"
    return
  onStations = true
  hits.placeTraces(f.index.keys, base, traces, g, result, domain)

proc outsideTemplate*(keys: openArray[TraceKeys]; traces: Slice[int]; g: SurveyGeometry;
    records: openArray[int64]; domain: RelationDomain): seq[bool] =
  ## Per trace of `traces`: whether it is outside the template, a live seismic trace at
  ## a station the relation `records` of `domain` do not plan (the traces of the
  ## `mfUnlisted` filter). A trace whose headers name no station is not outside: where
  ## it stands is not known.
  result = newSeq[bool](traces.len)
  let plan = g.plannedOf(records, domain)
  for i in 0 ..< traces.len:
    let k = keys[traces.a + i]
    if k.isSeismic and k.status != tsDead:
      let (line, point, index) = if domain == rdSource: (k.rcvLine, k.rcvPoint, k.rcvIndex)
                                 else: (k.srcLine, k.srcPoint, k.srcIndex)
      if hasStation(line, point):
        let st = stationKey(line, point, max(index, 0'i16))
        result[i] = not plan.planned(st.line, st.point, index)

proc negateQc(samples: var Tensor[float32]; part: Slice[int]; reversed: openArray[int]) =
  ## Multiplies each reversed trace of `part` by -1, before its own filter
  ## and the amplitude flags. A sign flip, not a filter.
  if reversed.len == 0: return
  let b = rowBlock(samples)
  for i in 0 ..< part.len:
    if reversed.binarySearch(part.a + i) >= 0:
      let row = b.rowPtr(i)
      for j in 0 ..< b.cols: row[j] = -row[j]

proc applyShiftsQc(samples: var Tensor[float32]; f: SeismicFile; part: Slice[int];
    shifts: openArray[ShiftEntry]; dtMs = NaN) =
  ## Each seismic trace of `part` moved by its stored shift, after polarity
  ## and before its own filter. An auxiliary trace is left as recorded.
  if shifts.len == 0: return
  let b = rowBlock(samples)
  for i in 0 ..< part.len:
    let ms = shiftAt(shifts, part.a + i)
    if ms == 0.0: continue
    let keys = f.traceKeys(part.a + i)
    if not keys.isSeismic: continue
    let us = if dtMs > 0 and dtMs < Inf: dtMs * 1000.0
             elif keys.intervalUs > 0 and keys.intervalUs < Inf: keys.intervalUs
             else: f.sampleIntervalUs(part.a + i)
    if us > 0 and us < Inf:
      applyStoredShift(b.rowPtr(i).toOpenArray(0, b.cols - 1), ms, us / 1000.0)

proc applyOwnQc(samples: var Tensor[float32]; f: SeismicFile; part: Slice[int];
    own: openArray[FilterEntry]; ws: var Workspace; dtMs = NaN) =
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
      let dt = if dtMs > 0 and dtMs < Inf: dtMs else: f.index.keys[t].intervalUs / 1000
      let pipe = filt.ownPipeline(if dt > 0: dt else: 1.0)
      if pipe.len > 0:
        let plan = pipe.compile(float32, (if dt > 0: dt else: 1.0), b.cols, recordSamples = b.cols)
        ws.reserve(plan)
        plan.apply(b, initChunkMeta(rows, (if dt > 0: dt else: 1.0), 0, skip), ws)

proc noiseOfRecord*(f: SeismicFile; traces: Slice[int]; amps: var seq[TraceAmplitude];
    unread: openArray[int]; outside: openArray[bool]; br: FirstBreaks;
    settings: NoiseSettings): NoiseSummary =
  ## The noisy-trace test of the record `traces` of `f`, on its traces'
  ## statistics `amps` (the rows `unread` could not be read), its first breaks
  ## `br` (none when they failed) and the area `settings` choose. The traces
  ## `outside` the template (none given: empty) are passed to the library as it is
  ## passed a killed trace: not judged, and not in the statistics the others are
  ## judged against. Sets the noisy and weak flags in `amps`. Raises `ValueError`
  ## for what the library refuses.
  let n = traces.len
  var skipped = newSeq[bool](n)
  var outsideCount = 0
  for r in unread: skipped[r] = true
  for i in 0 ..< outside.len:
    if outside[i]:
      skipped[i] = true
      inc outsideCount
  var skip: seq[int]
  for i in 0 ..< n:
    if skipped[i]: skip.add i
  var dt = 1.0
  for t in traces:
    let k = f.index.keys[t]
    if k.isSeismic and k.intervalUs > 0 and k.intervalUs < Inf:
      dt = k.intervalUs / 1000
      break
  let meta = initChunkMeta(f.rowsOf(traces), dt, 0, skip)
  var rotated = newSeq[bool](n)
  var any = false
  for i in 0 ..< n:
    if f.index.keys[traces.a + i].isSeismic:
      try:
        let o = f.traceOrientation(traces.a + i)
        if o.isSome and o.get.rotationApplied != 0:
          rotated[i] = true
          any = true
      except CatchableError:
        discard # no orientation to read: not rotated
  let domain = gatherDomainOf(meta)
  var roles = newSeq[TraceRole](n)
  meta.traceRolesInto(domain, (if any: rotated else: @[]), roles)
  let origin = case br.source
    of bsSurvey: ooSurvey
    of bsFile: ooHeaders
    of bsNone: ooUnknown
  let params = settings.paramsOf(origin)
  var ws = initWorkspace()
  ws.reserve(noiseWorkspace(n))
  var res: NoiseResult
  let picks = if br.state == bkDone: br.picks else: @[]
  if picks.len == n and br.hasFit:
    noiseQc(meta, amps, picks, br.fit, roles, AmplitudeParams(), params, domain, res, ws)
  else:
    noiseQc(meta, amps, picks, roles, AmplitudeParams(), params, domain, res, ws)
  result = NoiseSummary(ready: true, first: traces.a, asked: settings, domain: domain,
    rule: res.rule, reasons: res.reasons, origin: origin, edgeMs: res.edgeMs,
    radius: res.radius, steps: res.steps, lines: res.lines, linesReached: res.linesReached,
    inside: res.inside, state: res.state, louder: res.louder, outsideCount: outsideCount)
  if outsideCount > 0: result.outside = @outside
  for i in 0 ..< n:
    if f.index.keys[traces.a + i].isSeismic:
      case res.state[i]
      of nsJudged: inc result.judged
      of nsInArea: inc result.inArea
      of nsUngrouped: inc result.unknown
      of nsIncompleteNode: inc result.incomplete
      of nsUnusable:
        if not (outside.len > 0 and outside[i]): inc result.unusable
      if res.louder[i]: inc result.louderCount
      if afNoisy in amps[i].flags: inc result.noisy
      if afWeak in amps[i].flags: inc result.weak

proc recordQcWork*(file: ptr SeismicFile; path: string; session: SessionId; base, gather: int;
    traces: Slice[int]; domain: RelationDomain; relations: ptr SurveyGeometry;
    against: string; traceMatch: TraceMatch; placed: Placed;
    samples: bool; own: seq[FilterEntry]; reversed: seq[int]; shifts: seq[ShiftEntry];
    noise: NoiseWork; to: Poster; view: ref CorrelateView = nil): JobWork =
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
  ## amplitude flags. With `noise.on` it also runs the noisy-trace test
  ## (`noise.settings`), on the first breaks `noise.shared` holds or, when it
  ## holds none, on those it finds itself and posts with the result. Submitted
  ## with the file in `reads`; `relations` is read in place, never copied.
  ## When `view` is set, the samples are that view's listen time, not the raw
  ## record, and `path` (the virtual path) is not mapped.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var hits: array[MapFilter, FilterHits]
    for m in TraceFilters: hits[m].state = fsDone
    var revision = 0
    var records: seq[int64] = @[]
    var byPlace = false
    var onStations = false
    var outside: seq[bool] = @[]
    var summary = NoiseSummary()
    var found = FirstBreaks()
    var picked = false
    var noiseError = ""
    {.cast(gcsafe).}:
      template f: untyped = file[]
      revision = f.keysRevision
      let n = traces.len
      var amps = newSeq[TraceAmplitude](n)
      var ws = initWorkspace()
      let cols = if view == nil: max(1, f.maxSamples(traces)) else: view.listenSamples
      if cols > 0: ws.reserve(traceAmplitudeWorkspace(cols))
      var viewWs: CorrelateWorkspace
      if view != nil: viewWs = newWorkspace(view[])
      let wantNoise = samples and noise.on
      var br = FirstBreaks()
      if wantNoise:
        if noise.shared.state == bkDone: br = noise.shared
        else:
          ctx.setPhase "picking the first breaks"
          br = breaksOfRecord(file, path, traces, noise.key.killed,
            proc (done, total: int): bool = ctx.progress(done, 2 * total), noise.key.off,
              noise.key.guide, noise.key.pick, view = view)
          br.key = noise.key
          found = br
          picked = true
      let span = if picked: 2 * n else: n
      let spent = if picked: n else: 0
      var unreadRows: seq[int] # rows of the record whose samples could not be read
      ctx.setPhase "reading the record"
      discard f.cutShort # parseSEG's guard: stale cached bytes are not read past a cut
      var first = if samples and cols > 0: traces.a else: traces.b + 1
      while first <= traces.b:
        let part = first .. min(traces.b, first + QcChunk - 1)
        var samples: Tensor[float32]
        var failed, notDecoded: seq[int]
        var listenKeys: seq[TraceKeys]
        if view == nil:
          if not f.inMemory: fs.mappedRead(path) # (tests: the drive's next pages come late)
          var log: DiagLog
          samples = f.readTraces(part, 0 ..< cols, log)
          for d in log:
            # (a trace the file's cut or its drive made unreadable is not an
            # undecodable one: it is left out of that count)
            if d.loc.trace in part and (d.loc.trace - part.a) notin failed:
              failed.add d.loc.trace - part.a
          for r in failed:
            var unread = false
            for d in log:
              if d.loc.trace == part.a + r and d.code in {dcTruncated, dcIo}: unread = true
            if not unread: notDecoded.add r
          failed.sort()
        else:
          let rows = part.len
          samples = readListenChunk(view[], file, part, viewWs)
          failed = viewWs.failed
          # (as a plain file's: a cut or a failed drive is unread, not undecodable)
          for k, r in failed:
            if viewWs.why[k] == rfOther: notDecoded.add r
          listenKeys.setLen(rows)
          for i in 0 ..< rows:
            listenKeys[i] = f.traceKeys(part.a + i)
        if reversed.len > 0: negateQc(samples, part, reversed)
        let dtOverride = if view == nil: NaN else: view.dtMs
        if shifts.len > 0: applyShiftsQc(samples, f, part, shifts, dtOverride)
        if own.len > 0: applyOwnQc(samples, f, part, own, ws, dtOverride)
        for r in failed: unreadRows.add part.a - traces.a + r
        for r in notDecoded: hits[mfUndecodable].traces.add base + part.a + r
        let dt = if view != nil: view.dtMs else: f.index.keys[part.a].intervalUs / 1000
        let meta = if view == nil:
            initChunkMeta(f.rowsOf(part), (if dt > 0: dt else: 1.0), 0, failed)
          else:
            var counts = newSeq[int](listenKeys.len)
            for i in 0 ..< counts.len: counts[i] = cols
            initChunkMeta(rowsOf(listenKeys, counts), (if dt > 0: dt else: 1.0), 0, failed)
        traceAmplitudeInto(samples, meta, AmplitudeParams(), amps.toOpenArray(part.a - traces.a,
          part.b - traces.a), ws)
        if not ctx.progress(spent + part.b - traces.a + 1, span):
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
      if relations.isNil:
        for m in [mfMissing, mfUnlisted, mfDuplicate]:
          (hits[m].state, hits[m].note) = (fsNotChecked, "no relation file is loaded, and " &
            "no template generated")
      else:
        ctx.setPhase "checking the record against the template"
        try:
          records = hits.completeness(f, base, traces, relations[], against, domain,
            traceMatch, placed, ctx, byPlace, onStations)
        except ValueError as e:
          for m in [mfMissing, mfUnlisted, mfDuplicate]:
            (hits[m].state, hits[m].note) = (fsNotChecked, e.msg)
      if records.len > 0 and onStations and noise.settings.templateOnly:
        outside = outsideTemplate(f.index.keys, traces, relations[], records, domain)
      if wantNoise:
        ctx.setPhase "judging the noisy traces"
        try:
          # a killed trace is not judged and not in the statistics, as an unread one
          var left = unreadRows
          for t in noise.key.killed:
            if t in traces and (t - traces.a) notin left: left.add t - traces.a
          summary = noiseOfRecord(f, traces, amps, left, outside, br, noise.settings)
        except ValueError as e:
          noiseError = e.msg
      if samples:
        for i in seismic:
          for flag in amps[i].flags:
            if wantNoise or flag notin {afNoisy, afWeak}:
              hits[AmplitudeFilters[flag]].traces.add base + traces.a + i
        if summary.ready:
          for i in seismic:
            if summary.louder[i]: hits[mfLouder].traces.add base + traces.a + i
            if summary.state[i] in {nsInArea, nsUngrouped, nsIncompleteNode} or
                summary.outsideAt(traces.a + i):
              hits[mfNotJudged].traces.add base + traces.a + i
      for m in TraceFilters - {mfMissing, mfUnlisted, mfDuplicate}:
        hits[m].count = hits[m].traces.len
        hits[m].note = "traces"
      if noiseError.len > 0:
        for m in NoiseFilters: (hits[m].state, hits[m].note) = (fsNotChecked, noiseError)
      if summary.ready:
        hits[mfNotJudged].note = "traces not judged for noise: " & summary.notJudgedWords
        hits[mfLouder].note = "traces outside the area louder than those beside them"
      if not samples:
        for m in SampleFilters:
          (hits[m].state, hits[m].note) = (fsNotChecked, "the samples were not read")
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkRecordQc, qcSession: session, qcGather: gather,
      qcKeys: revision, qcHits: move hits, qcRecord: (if records.len > 0: records[0] else: -1'i64),
          qcRecords: records,
      qcByPlace: byPlace,
      qcOnStations: onStations,
      qcNoise: move summary, qcBreaks: move found, qcPicked: picked)
