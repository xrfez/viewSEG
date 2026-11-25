## Background jobs that open seismic files for their trace keys and count the
## stations the survey's relation records call for that the files do not hold
## (`missingreport`).
##
## `scanMissing` is the work: the caller lists the paths and passes the folder
## they sit under, so a path in a message is relative to that folder, and the
## imported survey's relations (`SurveyGeometry`, or nil). The job does not
## look at app state and does not change the relations. One file's keys are
## in memory at a time; each shot gather is added to a `StationTally` as it
## is checked. The receiver side keeps, for each receiver station of the whole
## scan, only the source stations it recorded, a bit for each source station
## of the scan (`IdSet`), and checks each receiver once when every file is read. The File tab runs it on
## one path, the Folder tab on the paths `folderScan` lists (subfolders only
## when asked).
##
## A file that cannot be opened, or that has no trace keys, is skipped and
## the scan goes on. A path already scanned (compared normalised) is not
## scanned again. A gather whose template record cannot be told is not
## counted: it is listed in `unmatched` with the reason. No survey (nil, or
## no relations) fails the job with one sentence (`NoSurvey`). A cancel,
## also while the receivers are checked, leaves the sink untouched.
##
## What a file is (`sideOf`, the one rule; stations are by line and point): a
## continuous receiver recording (`rkReceiverContinuous`, as the program shows
## the file) is not checked (`notChecked`). Otherwise the file's stations
## decide. Several receivers and one source (or none) is a shot, checked
## against its X record, receivers expected; one receiver and several sources
## (or none) is a receiver, checked against its O record, sources expected. One
## receiver and one source is open: one shot slice and a shot that one receiver
## recorded look alike, so it is kept as one trace's keys and, when every file
## is read, takes the side most of the files that were not open took; with none
## (one file alone, or a folder of slices only) it is a slice. Several of both:
## the recording kind (`planRecording` and `describeRecording`: shot gather or
## sliced receiver gather) decides, or, when it cannot be told, the same rule
## for each gather, a gather of one receiver and one source being a slice and
## one of several of both listed in `unmatched`. Every trace of one receiver
## station, in any file and any number of gathers (one for each shot slice), is
## one check, so a receiver side's `records` are receivers checked, and its
## `Missing` for a source is the receivers that lack it.
##
## Several X records at a shot's source station: the record number does not
## pick one (`recordCompleteness` would). The shot is checked against each, a
## template shared by several records (a reshoot of one patch) once, and takes
## the one that shares the most stations with the data, then the one that lacks
## the fewest; a tie on both between different templates is listed in
## `unmatched` (`SeveralFit`).
##
## A receiver is checked here rather than by `recordCompleteness`: its
## template is every source its O records call for (two O records of one
## receiver are one template), so no record number ever picks between them.
## The O records are the loaded ones, or, when none are loaded, the ones
## `receiverRelations` derives from the X records, both stored as
## source-domain records (the receiver as the record's source, the sources as
## its receivers). A receiver is its line and point: traces of it with index 0
## and index 1 are one receiver, and the index splits it only where the survey
## has the point at several indices.

import std/[math, os, sets, strutils, tables]
import parseSEG
import processSEG/qc/record
import processSEG/survey/relwalk
import correlatejobs, filejobs, filesystem, jobs, missingreport, recordingkind, session,
  threads, vendormaps

const
  NoSurvey* = "Import a survey with relation records (X records) first."
  Listing* = "Listing the folder."
  CannotList* = "The folder could not be listed."
  TraceChunk = 256 ## traces between cancel checks inside one gather

type
  MissingJobResult* = object
    ## What the scan did. `ok` false: `reason` is a sentence for the user,
    ## and the reports are empty. A cancel does not fill this. `shot` counts
    ## receiver stations of shot gathers, `receiver` source stations of
    ## receiver gathers; a side with no record has `stats.records` 0.
    ok*: bool
    shot*, receiver*: StationReport
    notChecked*: seq[tuple[path, why: string]]
      ## files left out on purpose (a continuous receiver recording)
    skipped*: seq[tuple[path, why: string]] ## relative to the folder, and why
    unmatched*: seq[tuple[path: string; record: int64; why: string]]
      ## A gather not checked: path relative to the folder, the header record
      ## number (−1 when it has none), and why.
    singleSlice*: bool
      ## The scan was of one file, and it holds one shot slice of one receiver
      ## (one receiver and one source station, one trace for each component).
    reason*: string

  ScanNote* = ref object
    ## Set by `folderScan`: the list stopped at the file limit.
    capped*: bool

  MissingSink* = ref object
    ## Filled when the job ends, except when it is cancelled. Read it after
    ## the job is no longer running.
    result*: MissingJobResult

proc missingSpec*(folder: string; paths: openArray[string]): JobSpec =
  ## The job that scans `paths` under `folder`: background, reading each
  ## path. The file list is the caller's (this job does not list a folder).
  let name = folder.extractFilename
  JobSpec(title: if name.len == 0: "Missing traces" else: "Missing traces in " & name,
    lane: jlBackground, reads: @paths)

func hasRelations(g: SurveyGeometry): bool =
  g.relationCount(rdSource) > 0 or g.relationCount(rdReceiver) > 0

proc relTo(folder, path: string): string =
  ## `path` relative to `folder`, or `path` when it is not under that folder.
  if folder.len == 0: return path
  var base = folder
  while base.len > 1 and base.endsWith(DirSep): base.setLen(base.len - 1)
  let prefix = base & DirSep
  if path.startsWith(prefix): return path[prefix.len .. ^1]
  if path == base: return path.extractFilename
  try: relativePath(path, base)
  except ValueError: path

proc highestRecord(g: SurveyGeometry): int64 =
  for r in g.records(rdSource):
    if r > result: result = r

proc receiverRelationsOf(g: SurveyGeometry; first: int64): seq[SpsRelation] =
  ## The receiver-domain relations as source-domain X records, numbered from
  ## `first`, so `recordCompleteness` can read them. Loaded O records are
  ## used as they are; otherwise they are derived from the X records.
  if g.relationCount(rdReceiver) > 0:
    var n = 0
    for rec in g.records(rdReceiver):
      let id = first + int64(n)
      inc n
      for run in g.relationRuns(rec, rdReceiver):
        if run.stations <= 0 or run.toChannel < run.fromChannel: continue
        var r = initSpsRelation()
        r.recordType = 'X'
        r.fieldRecord = id
        (r.srcLine, r.srcPoint, r.srcIndex) =
          (run.fixed.line, run.fixed.point, int(run.fixed.index))
        r.fromChannel = run.fromChannel
        r.toChannel = run.toChannel
        r.channelIncrement = max(int(run.channelStep), 1)
        (r.rcvLine, r.fromReceiver, r.toReceiver, r.rcvIndex) =
          (run.line, run.firstPoint, run.lastPoint, int(run.index))
        result.add r
  else:
    result = g.receiverRelations(first, 'X')

proc beat(ctx: JobContext; n: int) =
  ## A cancel check every `TraceChunk` traces of a gather, so a long file
  ## stops before its completeness is computed.
  var i = 0
  while i < n:
    ctx.checkCancelled()
    i += TraceChunk

proc openKeys(path, cacheDir: string; ctx: JobContext): Session =
  ## The file at `path`, keys only, closed by the caller. A cancel during
  ## the open is `SegCancelledError`. An unmapped read that fails (`fkIo`)
  ## raises here, before the file is opened. A current index cache in
  ## `cacheDir` is read instead of walking the headers; a walk saves one.
  ## A save that fails is ignored: the scan still has the keys.
  fs.unmappedFail(path)
  let index = indexCacheFile(cacheDir, path)
  let cached = index.len > 0 and fs.fileExists(index)
  let progress: Progress = proc (done, total: int64): bool {.gcsafe, raises: [].} =
    try: fs.mappedRead(path)
    except CatchableError: discard
    ctx.progress(done, total)
  result = openSession(path, progress, if cached: index else: "")
  if index.len == 0 or result.file.kind == skUnknown or result.file.fromCache or
      result.file.demuxPath.len > 0: return
  try:
    fs.createDir(cacheDir)
    {.cast(gcsafe).}:
      result.file.saveIndex(index)
  except ValueError, IOError, OSError:
    discard

func hasStation(line, point: float64): bool {.inline.} =
  ## A finite line and point that are not both 0 (a header left empty), as the
  ## record check reads a station.
  line == line and point == point and abs(line) < Inf and abs(point) < Inf and
    not (line == 0 and point == 0)

func wholeRecord(f: float64): int64 =
  ## The record number `f`, or −1 when it is not a whole number.
  if f == f and abs(f) < 9e18 and float64(int64(f)) == f: int64(f) else: -1

func fieldId(c: RecordCompleteness): int64 =
  ## The header record number, or −1 when it is not a whole number.
  wholeRecord(c.fieldRecord)

func unmatchedWhy(c: RecordCompleteness): string =
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

const
  NoReceiverStation = "no receiver station in the trace headers: it could only be " &
    "matched to the survey by its record number, which is not trusted"
  NoSourceStation = "no source station in the trace headers: the sources this receiver " &
    "recorded cannot be told"
  NoORecord = "no O record matches this receiver"
  UnknownIndex = "the trace headers give no receiver index (0) and the survey has this " &
    "point at several indices"

type
  Side = enum
    sdShot     ## one shot: checked against its X record
    sdReceiver ## one receiver, or slices of it: checked against its O record
    sdOpen     ## one receiver and one source: one slice, or a shot of one receiver
    sdNeither  ## several sources and several receivers (or none)

  Verdict = tuple[known: bool; receiver: bool; continuous: bool]

  Stations = object
    ## The receiver and source stations (line and point) of some traces,
    ## counted up to two, and whether no component of them has two traces.
    receivers, sources: int
    receiver, source: StationKey
    components: set[uint8]
    oneEach: bool

func initStations(): Stations = Stations(oneEach: true)

proc note(st: var Stations; k: TraceKeys) =
  if k.status != tsAuxiliary:
    if hasStation(k.rcvLine, k.rcvPoint):
      let r = stationKey(k.rcvLine, k.rcvPoint, 0)
      if st.receivers == 0: (st.receivers, st.receiver) = (1, r)
      elif st.receivers == 1 and r != st.receiver: st.receivers = 2
    if hasStation(k.srcLine, k.srcPoint):
      let s = stationKey(k.srcLine, k.srcPoint, 0)
      if st.sources == 0: (st.sources, st.source) = (1, s)
      elif st.sources == 1 and s != st.source: st.sources = 2
    if k.component in st.components: st.oneEach = false
    else: st.components.incl k.component

func sideOf(st: Stations; verdict: Verdict): Side =
  ## Which check the traces counted in `st` get, the rule for a file and for a
  ## gather of a file it leaves to its gathers (`verdict` unknown). One receiver
  ## and several sources (or none, which leaves it unmatched) is a receiver;
  ## several receivers (or none) and one source (or none) is a shot; one of each
  ## is open, as one slice and a shot of one live receiver look alike; several
  ## of both is the recording kind's, or else neither.
  if st.receivers == 1: (if st.sources == 1: sdOpen else: sdReceiver)
  elif st.sources <= 1: sdShot
  elif verdict.known: (if verdict.receiver: sdReceiver else: sdShot)
  else: sdNeither

func stationSide*(keys: openArray[TraceKeys]): StationSide =
  ## The side whose stations name a file's traces, by the rule `sideOf` applies to a
  ## file: one receiver and several sources is a receiver gather (`ssSources`: its
  ## stations are the sources); anything else, including a file `sideOf` leaves open or
  ## cannot tell, names its receivers (`ssReceivers`). A receiver and no source station at
  ## all is read as receivers too: the sources would have no stations to name.
  var st = initStations()
  for k in keys: st.note(k)
  if st.sideOf((known: false, receiver: false, continuous: false)) == sdReceiver and
      st.sources >= 2: ssSources
  else: ssReceivers

func isOneSlice(st: Stations): bool =
  ## One receiver, one source and one trace for each component: one shot slice.
  st.receivers == 1 and st.sources == 1 and st.oneEach

func neitherWhy(st: Stations): string =
  "the traces hold several source stations and " &
    (if st.receivers == 0: "no receiver station" else: "several receiver stations") &
    ": it is neither one shot nor one receiver, so no one relation record is theirs"

type
  IdSet* = object
    ## Numbers from 0 up, a bit each: a set takes one bit for each number up to the
    ## highest it holds, so a receiver's sources take an eighth of a byte each.
    bits: seq[uint64]

func incl*(s: var IdSet; id: int) =
  ## Adds `id` (0 or more), growing the set to it.
  let word = id shr 6
  if word >= s.bits.len: s.bits.setLen(word + 1)
  s.bits[word] = s.bits[word] or (1'u64 shl (id and 63))

func contains*(s: IdSet; id: int): bool =
  ## Whether `id` is in the set.
  let word = id shr 6
  word < s.bits.len and (s.bits[word] and (1'u64 shl (id and 63))) != 0

func byteSize*(s: IdSet): int =
  ## The bytes the set's bits take.
  s.bits.len * sizeof(uint64)

func meets(a, b: IdSet): bool =
  ## Whether `a` and `b` hold a number in common.
  for i in 0 ..< min(a.bits.len, b.bits.len):
    if (a.bits[i] and b.bits[i]) != 0: return true
  false

type
  ReceiverAt = object
    ## One receiver station (line and point) of the data: the source stations
    ## it holds traces of (by number, `ReceiverMerge.sourceIds`), a set for each
    ## receiver index its traces have, the first file it is in, and the record
    ## number it was first seen with, for Unmatched.
    station: StationKey ## line and point; index 0
    heard: seq[tuple[index: int16; sources: IdSet]]
    firstFile: int
    firstRecord: int64

  ReceiverFile = object
    ## A file of receiver data: its receivers (by number in `ReceiverMerge.list`),
    ## the first one, and all of them only when there are several.
    path: string ## relative to the folder
    first: int ## −1: none yet
    more: IdSet

  ReceiverMerge = object
    ## The receiver side of the data, by receiver station, over every file of a
    ## scan. A source station is kept as a number (`sourceIds`), so a receiver
    ## holds a bit for each source of the scan, whatever its number of traces and
    ## files, and a file a bit for each receiver only when it holds several.
    at: Table[StationKey, int]
    list: seq[ReceiverAt]
    sourceIds: Table[StationKey, int32]
    files: seq[ReceiverFile]

proc initReceiverMerge(): ReceiverMerge =
  ReceiverMerge(at: initTable[StationKey, int](), sourceIds: initTable[StationKey, int32]())

proc addFile(m: var ReceiverMerge; path: string): int =
  ## The number of a file of receiver data, or of an open one.
  result = m.files.len
  m.files.add ReceiverFile(path: path, first: -1)

proc add(m: var ReceiverMerge; file: int; k: TraceKeys) =
  ## Adds a trace that has a receiver station. A trace with no source station
  ## adds its receiver only.
  let station = stationKey(k.rcvLine, k.rcvPoint, 0)
  var slot = m.at.getOrDefault(station, -1)
  if slot < 0:
    slot = m.list.len
    m.at[station] = slot
    m.list.add ReceiverAt(station: station, firstFile: file,
      firstRecord: wholeRecord(k.record))
  template f: untyped = m.files[file]
  if f.first < 0: f.first = slot
  elif f.first != slot:
    if f.more.bits.len == 0: f.more.incl f.first
    f.more.incl slot
  if hasStation(k.srcLine, k.srcPoint):
    let source = stationKey(k.srcLine, k.srcPoint, k.srcIndex)
    var id = m.sourceIds.getOrDefault(source, -1)
    if id < 0:
      id = int32(m.sourceIds.len)
      m.sourceIds[source] = id
    let index = max(k.rcvIndex, 0'i16)
    var at = -1
    for i, h in m.list[slot].heard:
      if h.index == index: at = i
    if at < 0:
      at = m.list[slot].heard.len
      m.list[slot].heard.add (index: index, sources: IdSet())
    m.list[slot].heard[at].sources.incl int(id)

type ORecord = tuple[index: int16; sources: seq[StationKey]]

proc oRecordsAt(g: SurveyGeometry; station: StationKey): seq[ORecord] =
  ## The O records (stored as source-domain records, see `receiverRelationsOf`)
  ## of the receiver at `station`'s line and point, at any index: the receiver
  ## index each is for (0 read as 1) and the sources it calls for.
  for rec in g.recordsAt(station):
    var r: ORecord = (index: -1'i16, sources: @[])
    for (_, rel) in g.channelRelations(rec):
      if r.index < 0: r.index = (if rel.source.index == 0: 1'i16 else: rel.source.index)
      r.sources.add rel.receiver
    if r.index >= 0: result.add r

func isHeard(m: ReceiverMerge; r: ReceiverAt; source: StationKey;
    indices: openArray[int16]): bool =
  ## Whether the receiver recorded `source` at one of the receiver `indices`.
  ## The source matches as a record check matches a station: with its index,
  ## else with none (0) in the headers; a template index 0 takes the usual 1.
  let key = stationKey(source.line, source.point, source.index)
  let alt = stationKey(source.line, source.point, (if source.index == 0: 1'i16 else: 0'i16))
  for k in [key, alt]:
    let id = m.sourceIds.getOrDefault(k, -1)
    if id >= 0:
      for h in r.heard:
        if h.index in indices and int(id) in h.sources: return true
  false

proc checkReceiver(tally: var StationTally; m: ReceiverMerge; r: ReceiverAt;
    records: openArray[ORecord]; indices: openArray[int16]) =
  ## Adds one check of receiver `r` to `tally`: the template is every source
  ## the `records` call for (several O records of one receiver are one
  ## template), present when the receiver recorded it at one of `indices`.
  var calls: seq[StationKey] = @[]
  var listed = initHashSet[StationKey]()
  for rec in records:
    for s in rec.sources:
      if not listed.containsOrIncl(s): calls.add s
  var c = RecordCompleteness(fieldRecord: float64(r.firstRecord), source: r.station,
    hasSource: true, recordMatch: rmSourceStation, traceMatch: tmStation, xpsRecord: -1)
  for s in calls:
    inc c.expected
    if m.isHeard(r, s, indices): inc c.present
    else: c.missingStations.add s
  c.missing = c.missingStations.len
  tally.addGather(calls, c)

proc checkReceivers(tally: var StationTally; m: ReceiverMerge; g: SurveyGeometry;
    ctx: JobContext; unmatched: var seq[tuple[path: string; record: int64; why: string]]):
    int =
  ## Checks each receiver of `m` once against its O records in `g`, and gives the
  ## number of files that hold a receiver checked. The receiver index
  ## splits a receiver into several checks only where the survey has its point at
  ## several indices. A receiver not checked is listed in `unmatched` under the
  ## first file it is in.
  var checked = IdSet()
  for slot, r in m.list:
    ctx.checkCancelled()
    var data: seq[int16] = @[]
    for h in r.heard: data.add h.index
    let records = g.oRecordsAt(r.station)
    var indices: seq[int16] = @[]
    for rec in records:
      if rec.index notin indices: indices.add rec.index
    let path = m.files[r.firstFile].path
    if r.heard.len == 0:
      unmatched.add (path: path, record: r.firstRecord, why: NoSourceStation)
    elif records.len == 0:
      unmatched.add (path: path, record: r.firstRecord, why: NoORecord)
    elif indices.len == 1:
      tally.checkReceiver(m, r, records, data)
      checked.incl slot
    else:
      for i in data:
        var chosen: seq[ORecord] = @[]
        for rec in records:
          if rec.index == i: chosen.add rec
        if i == 0:
          unmatched.add (path: path, record: r.firstRecord, why: UnknownIndex)
        elif chosen.len == 0:
          unmatched.add (path: path, record: r.firstRecord, why: NoORecord)
        else:
          tally.checkReceiver(m, r, chosen, [i])
          checked.incl slot
  for f in m.files:
    if (if f.more.bits.len > 0: f.more.meets(checked) else: f.first >= 0 and f.first in checked):
      inc result

proc fail(sink: MissingSink; why: string; skipped: seq[tuple[path, why: string]]) =
  if sink != nil:
    sink.result = MissingJobResult(ok: false, reason: why, skipped: skipped)
  raise newException(ValueError, why)

func templateStations(g: SurveyGeometry; record: int64): seq[StationKey] =
  ## The entries the relation record `record` calls for, one for each channel
  ## relation (`addGather` counts the stations in them).
  for (_, rel) in g.channelRelations(record): result.add rel.receiver

const SeveralFit = "several survey records at this source station fit equally: the " &
  "record number alone would decide, and it is not trusted"

proc templateOf(g: SurveyGeometry; record: int64; byChannel: bool):
    HashSet[tuple[channel: int64; station: StationKey]] =
  ## What X record `record` calls for, as compared between records: its
  ## stations, and their channels when traces are matched by channel.
  result = initHashSet[tuple[channel: int64; station: StationKey]]()
  for (channel, rel) in g.channelRelations(record):
    result.incl (channel: (if byChannel: int64(channel) else: 0'i64), station: rel.receiver)

proc bestOfSeveral(g: SurveyGeometry; rows: TraceRows; first: RecordCompleteness;
    ctx: JobContext): tuple[c: RecordCompleteness; why: string] =
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
      var c = g.recordCompleteness(rowsOf(keys, counts), rmSourceStation)
      if c.present > best.present or (c.present == best.present and c.missing < best.missing):
        c.fieldRecord = first.fieldRecord
        (best, tied, result.c) = ((present: c.present, missing: c.missing), false, c)
      elif c.present == best.present and c.missing == best.missing:
        tied = true
  result.why = if tied: SeveralFit else: ""

proc checkShot(tally: var StationTally; g: SurveyGeometry; rows: TraceRows; path: string;
    ctx: JobContext; unmatched: var seq[tuple[path: string; record: int64; why: string]]):
    bool =
  ## Checks one shot against its X record and adds it to `tally`, or lists it in
  ## `unmatched`; true when it was checked.
  var checked = g.recordCompleteness(rows)
  var why = ""
  if checked.recordMatch == rmSourceStation and checked.candidates.len > 1:
    # Several X records at this source: the data decides, never the record number.
    (checked, why) = g.bestOfSeveral(rows, checked, ctx)
  if why.len == 0: why = unmatchedWhy(checked)
  if why.len > 0:
    unmatched.add (path: path, record: fieldId(checked), why: why)
  else:
    tally.addGather(g.templateStations(checked.xpsRecord), checked)
  why.len == 0

proc verdictOf(s: Session; path: string; ctx: JobContext): Verdict =
  ## The recording kind of the open file, as the program shows it; not known
  ## when the file has no sample interval or no live trace, when the plan
  ## cannot be made, or when it reads as continuous only for want of a boundary
  ## between segments to judge by.
  let dtMs = seismicDtMs(s.filePtr)
  if dtMs.isNaN or dtMs <= 0: return
  try:
    {.cast(gcsafe).}:
      let facts = describeRecording(planRecording(s.filePtr, path, dtMs, currentVendors(),
        proc () {.gcsafe.} = ctx.checkCancelled()))
      # One segment for each receiver and no boundary between segments leaves nothing to
      # judge continuity by (one live trace, or the components of one station at one
      # start): the kind is not told, and the gather's own kind decides.
      if facts.ready and not (facts.kind == rkReceiverContinuous and facts.boundaries == 0):
        result = (known: true, receiver: facts.kind == rkReceiverSliced,
          continuous: facts.kind == rkReceiverContinuous)
  except JobCancelledError, SegCancelledError:
    raise
  except CatchableError:
    result = (known: false, receiver: false, continuous: false)

proc scanMissing*(folder: string; paths: seq[string]; relations: ref SurveyGeometry;
    sink: MissingSink; cacheDir = ""): JobWork =
  ## The work of a job that scans `paths` (relative to `folder` in messages)
  ## against `relations` and fills `sink` (`missingSpec` is the spec to
  ## submit it with). Worker-only. A cancel raises `JobCancelledError` and
  ## leaves `sink` as it was. `cacheDir` is the index cache folder: a current
  ## cache is read instead of walking the file, and a walk saves one.
  ## "" leaves the cache alone.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    if relations == nil or not relations[].hasRelations:
      fail(sink, NoSurvey, @[])
    var skipped: seq[tuple[path, why: string]] = @[]
    var notChecked: seq[tuple[path, why: string]] = @[]
    var unmatched: seq[tuple[path: string; record: int64; why: string]] = @[]
    let derived = relations[].relationCount(rdReceiver) == 0
    var shot = initTally(ssReceivers)
    var recv = initTally(ssSources, derived)
    var merge = initReceiverMerge()
    # open files, one trace's keys each
    var opened: seq[tuple[file: int; keys: TraceKeys]] = @[]
    var decided = [0, 0] # files that were not open: shots, receivers
    var sliceFiles = 0
    var seen = initHashSet[string]()
    try:
      for i, path in paths:
        ctx.setPhase "reading " & path.extractFilename
        ctx.checkCancelled()
        let key = path.normalizedPath
        if key notin seen:
          seen.incl key
          let rel = relTo(folder, path)
          var s: Session = nil
          var skip = ""
          var anyShot = false
          try:
            s = openKeys(path, cacheDir, ctx)
            if s.file.kind == skUnknown: skip = "not a SEG-Y, SEG-D or SEG-2 file"
            elif s.file.index.keys.len == 0: skip = "has no trace keys"
            else:
              let verdict = verdictOf(s, path, ctx)
              if verdict.continuous:
                notChecked.add (path: rel,
                  why: "a continuous receiver recording is not checked")
              else:
                {.cast(gcsafe).}:
                  let gathers = s.gathers
                  var whole = initStations()
                  for k in s.file.index.keys: whole.note(k)
                  if whole.isOneSlice: inc sliceFiles
                  let fileSide = whole.sideOf(verdict)
                  var fileId = -1
                  if fileSide == sdOpen:
                    # Told after the pass, by the files that are not open; kept as one
                    # trace's keys, which is all a check of one station needs.
                    fileId = merge.addFile(rel)
                    var kept = false
                    for k in s.file.index.keys:
                      if not kept and k.status != tsAuxiliary and
                          hasStation(k.rcvLine, k.rcvPoint) and hasStation(k.srcLine, k.srcPoint):
                        opened.add (file: fileId, keys: k)
                        kept = true
                  var votes = [0, 0] # gathers checked as shots, as receivers
                  for g in gathers:
                    if g.traces.len > 0 and fileSide != sdOpen:
                      beat(ctx, g.traces.len)
                      var side = fileSide
                      if side == sdNeither:
                        var own = initStations()
                        for t in g.traces: own.note(s.file.index.keys[t])
                        side = own.sideOf((known: false, receiver: false, continuous: false))
                        # One slice of a file of several receivers and sources.
                        if side == sdOpen: side = sdReceiver
                        if side == sdNeither:
                          let k = s.file.index.keys[g.traces.a]
                          unmatched.add (path: rel, record: wholeRecord(k.record),
                            why: neitherWhy(own))
                      case side
                      of sdNeither, sdOpen: discard
                      of sdShot:
                        inc votes[0]
                        if shot.checkShot(relations[], s.file.rowsOf(g.traces), rel, ctx,
                            unmatched):
                          anyShot = true
                      of sdReceiver:
                        # Kept by receiver station over the whole scan: each receiver is
                        # checked once at the end, over every slice and file of it.
                        inc votes[1]
                        if fileId < 0: fileId = merge.addFile(rel)
                        var stations = 0
                        for t in g.traces:
                          let k = s.file.index.keys[t]
                          if k.status != tsAuxiliary and hasStation(k.rcvLine, k.rcvPoint):
                            merge.add(fileId, k)
                            inc stations
                        if stations == 0:
                          let k = s.file.index.keys[g.traces.a]
                          unmatched.add (path: rel, record: wholeRecord(k.record),
                            why: NoReceiverStation)
                  if votes[0] > votes[1]: inc decided[0]
                  elif votes[1] > votes[0]: inc decided[1]
          except SegCancelledError:
            raise newException(JobCancelledError, "cancelled")
          except JobCancelledError:
            raise
          except CatchableError as e:
            skip = if e.msg.len > 0: e.msg else: $e.name
          finally:
            s = nil
            clearCycleRoots()
          if skip.len > 0: skipped.add (path: rel, why: skip)
          if anyShot: shot.noteFile()
        if not ctx.progress(i + 1, paths.len):
          raise newException(JobCancelledError, "cancelled")
      # An open file takes the side most of the files that were not open took; with
      # none, it is a slice.
      let openAsShot = decided[0] > decided[1]
      for o in opened:
        ctx.checkCancelled()
        if openAsShot:
          if shot.checkShot(relations[], rowsOf([o.keys], [0]), merge.files[o.file].path,
              ctx, unmatched):
            shot.noteFile()
        else:
          merge.add(o.file, o.keys)
      if merge.list.len > 0:
        ctx.setPhase "checking the receivers"
        let rels = relations[].receiverRelationsOf(relations[].highestRecord + 1)
        var receiver = initSurveyGeometry()
        receiver.addSps(SpsFile(relations: rels), rdSource)
        for _ in 1 .. checkReceivers(recv, merge, receiver, ctx, unmatched): recv.noteFile()
      ctx.setPhase "reporting"
      ctx.checkCancelled()
      clearCycleRoots()
      if sink != nil:
        sink.result = MissingJobResult(ok: true, shot: shot.report, receiver: recv.report,
          skipped: skipped, notChecked: notChecked, unmatched: unmatched,
          singleSlice: seen.len == 1 and sliceFiles == 1)
    except JobCancelledError:
      raise
    except SegCancelledError:
      raise newException(JobCancelledError, "cancelled")
    except CatchableError as e:
      fail(sink, if e.msg.len > 0: e.msg else: $e.name, skipped)

proc folderScan*(folder: string; subfolders: bool; cacheDir: string;
    relations: ref SurveyGeometry; sink: MissingSink; note: ScanNote = nil): JobWork =
  ## The work of a job that lists the seismic files of `folder`, its
  ## subfolders only when `subfolders`, and scans them as `scanMissing` does.
  ## `note.capped` says the list stopped at the file limit.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    ctx.setPhase Listing
    var capped = false
    var paths: seq[string] = @[]
    try:
      paths = listedNames(@[folder], subfolders, capped,
        proc (found: int): bool {.gcsafe, raises: [].} = ctx.progress(int64(found), 0))
    except OSError:
      raise newException(ValueError, CannotList)
    if note != nil: note.capped = capped
    ctx.checkCancelled()
    let scan = scanMissing(folder, paths, relations, sink, cacheDir)
    scan(ctx)
