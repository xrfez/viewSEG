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
## scan, only the source stations it recorded (and the files it is in), and
## checks each receiver once when every file is read. The File tab runs it on
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
## What a file is (receiver and source stations are by line and point): a file
## whose traces hold one receiver station is receiver data, one slice or many,
## whatever else it reads as, so it is never one shot lacking all but one
## receiver. Otherwise the recording kind the program shows for it
## (`planRecording` and `describeRecording`) decides: a shot gather
## (`rkShotGather`) is checked against its X record, by source station,
## receivers expected; a sliced receiver gather (`rkReceiverSliced`) against the
## O record of each receiver, sources expected; a continuous receiver recording
## (`rkReceiverContinuous`) is not checked (`notChecked`). When the kind cannot
## be told (no sample interval or no live trace, or one segment for each
## receiver, which no continuity can be judged from), the stations decide, for
## the file and else for each gather: one source station (or none) and several
## receivers is a shot; several of both is neither, and is listed in
## `unmatched`. Every trace of one receiver station, in any file and any number
## of gathers (one for each shot slice), is one check, so a receiver side's
## `records` are receivers checked, and its `Missing` for a source is the
## receivers that lack it.
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
  elif c.xpsRecord < 0 and c.candidates.len > 1:
    $c.candidates.len & " survey records share this source and the record number matches " &
      "neither"
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
    sdNeither  ## several sources and several receivers (or none)

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

func sideOf(st: Stations): Side =
  ## One receiver station is a receiver, with one or more sources; otherwise one
  ## source station (or none, which leaves it unmatched) is a shot.
  if st.receivers == 1: sdReceiver
  elif st.sources <= 1: sdShot
  else: sdNeither

func isOneSlice(st: Stations): bool =
  ## One receiver, one source and one trace for each component: one shot slice.
  st.receivers == 1 and st.sources == 1 and st.oneEach

func neitherWhy(st: Stations): string =
  "the traces hold several source stations and " &
    (if st.receivers == 0: "no receiver station" else: "several receiver stations") &
    ": it is neither one shot nor one receiver, so no one relation record is theirs"

type
  ReceiverAt = object
    ## One receiver station (line and point) of the data: the source stations
    ## it holds traces of, each with the receiver index of its trace (`heardKey`),
    ## the files it is in, and the record number it was first seen with, for
    ## Unmatched.
    station: StationKey ## line and point; index 0
    heard: HashSet[int64]
    files: seq[int] ## ascending: files are added in scan order
    firstRecord: int64

  ReceiverMerge = object
    ## The receiver side of the data, by receiver station, over every file of a
    ## scan. A source station is kept as a number (`sourceIds`), so a receiver
    ## holds one integer for each source it recorded and one for each file it is
    ## in, whatever its number of traces.
    at: Table[StationKey, int]
    list: seq[ReceiverAt]
    sourceIds: Table[StationKey, int32]

func heardKey(source: int32; index: int16): int64 {.inline.} =
  (int64(cast[uint16](index)) shl 32) or int64(source)

func heardIndex(key: int64): int16 {.inline.} = cast[int16](uint16((key shr 32) and 0xFFFF))

proc initReceiverMerge(): ReceiverMerge =
  ReceiverMerge(at: initTable[StationKey, int](), sourceIds: initTable[StationKey, int32]())

proc add(m: var ReceiverMerge; file: int; k: TraceKeys) =
  ## Adds a trace that has a receiver station. A trace with no source station
  ## adds its receiver only.
  let station = stationKey(k.rcvLine, k.rcvPoint, 0)
  var slot = m.at.getOrDefault(station, -1)
  if slot < 0:
    slot = m.list.len
    m.at[station] = slot
    m.list.add ReceiverAt(station: station, heard: initHashSet[int64](),
      files: @[file], firstRecord: wholeRecord(k.record))
  elif m.list[slot].files[^1] != file:
    m.list[slot].files.add file
  if hasStation(k.srcLine, k.srcPoint):
    let source = stationKey(k.srcLine, k.srcPoint, k.srcIndex)
    var id = m.sourceIds.getOrDefault(source, -1)
    if id < 0:
      id = int32(m.sourceIds.len)
      m.sourceIds[source] = id
    m.list[slot].heard.incl heardKey(id, max(k.rcvIndex, 0'i16))

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
      for i in indices:
        if heardKey(id, i) in r.heard: return true
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
    paths: openArray[string]; ctx: JobContext;
    unmatched: var seq[tuple[path: string; record: int64; why: string]]): HashSet[int] =
  ## Checks each receiver of `m` once against its O records in `g`, and gives the
  ## files (indices into `paths`) of the receivers checked. The receiver index
  ## splits a receiver into several checks only where the survey has its point at
  ## several indices. A receiver not checked is listed in `unmatched` under the
  ## first file it is in.
  result = initHashSet[int]()
  for r in m.list:
    ctx.checkCancelled()
    var data: seq[int16] = @[]
    for key in r.heard:
      let i = heardIndex(key)
      if i notin data: data.add i
    let records = g.oRecordsAt(r.station)
    var indices: seq[int16] = @[]
    for rec in records:
      if rec.index notin indices: indices.add rec.index
    let path = paths[r.files[0]]
    var checked = false
    if r.heard.len == 0:
      unmatched.add (path: path, record: r.firstRecord, why: NoSourceStation)
    elif records.len == 0:
      unmatched.add (path: path, record: r.firstRecord, why: NoORecord)
    elif indices.len == 1:
      tally.checkReceiver(m, r, records, data)
      checked = true
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
          checked = true
    if checked:
      for f in r.files: result.incl f

proc fail(sink: MissingSink; why: string; skipped: seq[tuple[path, why: string]]) =
  if sink != nil:
    sink.result = MissingJobResult(ok: false, reason: why, skipped: skipped)
  raise newException(ValueError, why)

func templateStations(g: SurveyGeometry; record: int64): seq[StationKey] =
  ## The entries the relation record `record` calls for, one for each channel
  ## relation (`addGather` counts the stations in them).
  for (_, rel) in g.channelRelations(record): result.add rel.receiver

type Verdict = tuple[known: bool; receiver: bool; continuous: bool]

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
    var receiverPaths: seq[string] = @[] ## the files `merge` names by number
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
                  # One receiver station in the file is receiver data, whatever its
                  # kind reads as: never one shot that lacks all but one receiver.
                  let fileSide =
                    if whole.receivers == 1: sdReceiver
                    elif verdict.known: (if verdict.receiver: sdReceiver else: sdShot)
                    else: whole.sideOf
                  var fileId = -1
                  for g in gathers:
                    if g.traces.len > 0:
                      beat(ctx, g.traces.len)
                      var side = fileSide
                      if side == sdNeither:
                        var own = initStations()
                        for t in g.traces: own.note(s.file.index.keys[t])
                        side = own.sideOf
                        if side == sdNeither:
                          let k = s.file.index.keys[g.traces.a]
                          unmatched.add (path: rel, record: wholeRecord(k.record),
                            why: neitherWhy(own))
                      case side
                      of sdNeither: discard
                      of sdShot:
                        let checked = relations[].recordCompleteness(s.file.rowsOf(g.traces))
                        let why = unmatchedWhy(checked)
                        if why.len > 0:
                          unmatched.add (path: rel, record: fieldId(checked), why: why)
                        else:
                          shot.addGather(relations[].templateStations(checked.xpsRecord),
                            checked)
                          anyShot = true
                      of sdReceiver:
                        # Kept by receiver station over the whole scan: each receiver is
                        # checked once at the end, over every slice and file of it.
                        if fileId < 0:
                          fileId = receiverPaths.len
                          receiverPaths.add rel
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
      if merge.list.len > 0:
        ctx.setPhase "checking the receivers"
        let rels = relations[].receiverRelationsOf(relations[].highestRecord + 1)
        var receiver = initSurveyGeometry()
        receiver.addSps(SpsFile(relations: rels), rdSource)
        let files = checkReceivers(recv, merge, receiver, receiverPaths, ctx, unmatched)
        for _ in 1 .. files.len: recv.noteFile()
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
