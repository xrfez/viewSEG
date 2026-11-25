## Background jobs that open seismic files for their trace keys and count the
## stations the survey's relation records call for that the files do not hold
## (`missingreport`).
##
## `scanMissing` is the work: the caller lists the paths and passes the folder
## they sit under, so a path in a message is relative to that folder, and the
## imported survey's relations (`SurveyGeometry`, or nil). The job does not
## look at app state and does not change the relations. One file's keys are
## in memory at a time; each gather is added to a `StationTally` as it is
## checked. The File tab runs it on one path, the Folder tab on the paths
## `folderScan` lists (subfolders only when asked).
##
## A file that cannot be opened, or that has no trace keys, is skipped and
## the scan goes on. A path already scanned (compared normalised) is not
## scanned again. A gather whose template record cannot be told is not
## counted: it is listed in `unmatched` with the reason. No survey (nil, or
## no relations) fails the job with one sentence (`NoSurvey`). A cancel
## leaves the sink untouched.
##
## What a file is: the recording kind the program shows for it (`planRecording`
## and `describeRecording`) decides. A shot gather (`rkShotGather`) is checked
## against its X record, by source station, receivers expected. A sliced
## receiver gather (`rkReceiverSliced`) is checked against the O record of its
## receiver, sources expected. A continuous receiver recording
## (`rkReceiverContinuous`) is not checked: it is in `notChecked`. When the
## kind cannot be told (no sample interval or no live trace) a gather is a
## receiver gather when its own kind is `gkReceiver`, as the record on show.
##
## `recordCompleteness` reads only the source domain, so a receiver gather
## is checked against the receiver-domain relations stored as source-domain
## records (the receiver as the record's source, the sources as its
## receivers) and keys with those stations swapped. Those relations are the
## loaded O records, or, when none are loaded, the ones `receiverRelations`
## derives from the X records, numbered after the survey's. The match is by
## that station (`rmSourceStation`), not by the derived record number.

import std/[os, sets, strutils]
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

proc exchange(a, b: var float64) =
  let t = a
  a = b
  b = t

proc exchangeIndex(a, b: var int16) =
  let t = a
  a = b
  b = t

proc swappedCompleteness(g: SurveyGeometry; f: SeismicFile; traces: Slice[int];
    ctx: JobContext): RecordCompleteness =
  ## `recordCompleteness` of a receiver gather: the receiver station stands
  ## in as the source, and each trace's source stands in as a receiver, so
  ## the source-domain check sees the gather's expected sources.
  let n = traces.len
  var keys = newSeq[TraceKeys](n)
  var counts = newSeq[int](n)
  for i in 0 ..< n:
    if i mod TraceChunk == 0: ctx.checkCancelled()
    var k = f.index.keys[traces.a + i]
    exchange(k.srcLine, k.rcvLine)
    exchange(k.srcPoint, k.rcvPoint)
    exchangeIndex(k.srcIndex, k.rcvIndex)
    keys[i] = k
  g.recordCompleteness(rowsOf(keys, counts), rmSourceStation)

func fieldId(c: RecordCompleteness): int64 =
  ## The header record number, or −1 when it is not a whole number.
  let f = c.fieldRecord
  if f == f and abs(f) < 9e18 and float64(int64(f)) == f: int64(f) else: -1

func isAmbiguous(c: RecordCompleteness): bool =
  c.xpsRecord < 0 and c.candidates.len > 1

proc fail(sink: MissingSink; why: string; skipped: seq[tuple[path, why: string]]) =
  if sink != nil:
    sink.result = MissingJobResult(ok: false, reason: why, skipped: skipped)
  raise newException(ValueError, why)

func templateStations(g: SurveyGeometry; record: int64): seq[StationKey] =
  ## The stations the relation record `record` calls for, each once.
  var seen = initHashSet[StationKey]()
  for (_, rel) in g.channelRelations(record):
    if not seen.containsOrIncl(rel.receiver): result.add rel.receiver

type Verdict = tuple[known: bool, receiver: bool, continuous: bool]

proc verdictOf(s: Session; path: string; ctx: JobContext): Verdict =
  ## The recording kind of the open file, as the program shows it; not known
  ## when the file has no sample interval or no live trace, or when the plan
  ## cannot be made.
  let dtMs = seismicDtMs(s.filePtr)
  if dtMs.isNaN or dtMs <= 0: return
  try:
    {.cast(gcsafe).}:
      let facts = describeRecording(planRecording(s.filePtr, path, dtMs, currentVendors(),
        proc () {.gcsafe.} = ctx.checkCancelled()))
      if facts.ready:
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
    var receiver: ref SurveyGeometry = nil
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
          var anyReceiver = false
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
                  for g in s.gathers:
                    if g.traces.len == 0: continue
                    beat(ctx, g.traces.len)
                    let asReceiver =
                      if verdict.known: verdict.receiver else: g.kind == gkReceiver
                    if asReceiver and receiver == nil:
                      let rels = relations[].receiverRelationsOf(
                        relations[].highestRecord + 1)
                      var built = initSurveyGeometry()
                      built.addSps(SpsFile(relations: rels), rdSource)
                      receiver = new SurveyGeometry
                      receiver[] = built
                    let checked =
                      if asReceiver: swappedCompleteness(receiver[], s.file, g.traces, ctx)
                      else: relations[].recordCompleteness(s.file.rowsOf(g.traces))
                    if checked.isAmbiguous:
                      unmatched.add (path: rel, record: fieldId(checked),
                        why: $checked.candidates.len &
                        " survey records share this source and the record number matches neither")
                    elif not asReceiver and checked.recordMatch == rmFieldRecord and
                        checked.hasSource and checked.sourceMismatch:
                      unmatched.add (path: rel, record: fieldId(checked),
                        why: "the record's source station has no X record; X record " &
                        $checked.xpsRecord &
                        ", matched by file number alone, belongs to another source")
                    elif checked.xpsRecord < 0:
                      unmatched.add (path: rel, record: fieldId(checked),
                        why: if asReceiver: "no O record matches this receiver"
                          else: "no X record matches this source")
                    elif asReceiver:
                      recv.addRecord(receiver[].templateStations(checked.xpsRecord), checked)
                      anyReceiver = true
                    else:
                      shot.addRecord(relations[].templateStations(checked.xpsRecord), checked)
                      anyShot = true
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
          if anyReceiver: recv.noteFile()
        if not ctx.progress(i + 1, paths.len):
          raise newException(JobCancelledError, "cancelled")
      ctx.setPhase "reporting"
      ctx.checkCancelled()
      clearCycleRoots()
      if sink != nil:
        sink.result = MissingJobResult(ok: true, shot: shot.report, receiver: recv.report,
          skipped: skipped, notChecked: notChecked, unmatched: unmatched)
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
