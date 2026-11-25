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
import correlatejobs, filejobs, filesystem, jobs, missingreport, recordingkind,
  relationcheck, session, threads, vendormaps

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
    let source = stationKey(k.srcLine, k.srcPoint, 0)         # a station is its line and point
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

func isHeard(m: ReceiverMerge; r: ReceiverAt; source: StationKey;
    indices: openArray[int16]): bool =
  ## Whether the receiver recorded `source` at one of the receiver `indices`.
  ## A source is its line and point, whatever index the template or the headers give.
  let id = m.sourceIds.getOrDefault(stationKey(source.line, source.point, 0), -1)
  if id >= 0:
    for h in r.heard:
      if h.index in indices and int(id) in h.sources: return true
  false

proc checkReceiver(tally: var StationTally; m: ReceiverMerge; r: ReceiverAt;
    records: openArray[ORecord]; indices: openArray[int16]) =
  ## Adds one check of receiver `r` to `tally`: the template is every source
  ## the `records` call for (several O records of one receiver are one
  ## template), present when the receiver recorded it at one of `indices`.
  let calls = calledSources(records)
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

proc checkShot(tally: var StationTally; g: SurveyGeometry; rows: TraceRows; path: string;
    ctx: JobContext; unmatched: var seq[tuple[path: string; record: int64; why: string]]):
    bool =
  ## Checks one shot against its X record and adds it to `tally`, or lists it in
  ## `unmatched`; true when it was checked.
  let (checked, why) = g.shotCheck(rows, ctx)
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
