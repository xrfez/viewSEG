## A background job that opens the seismic files of a folder for their trace
## keys and builds the missing-trace report (`missingReport`).
##
## The caller lists the paths (subfolders included) and passes the folder
## they sit under, so each `FileRecords.path` is relative to that folder,
## and the imported survey's relations (`SurveyLayer.relations`, or nil).
## The job does not look at app state and does not change the relations.
## One file's keys are in memory at a time; the per-file
## `RecordCompleteness` values are kept, and `missingReport` runs at the
## end, on the job thread.
##
## A file that cannot be opened, or that has no trace keys, is skipped and
## the scan goes on. A gather whose match is ambiguous is not a row: it is
## listed in `unmatched`, and its survey candidates are not records without
## data. No survey (nil, or no relations) fails the job with one sentence
## (`NoSurvey`). A cancel leaves the sink untouched.
##
## A gather is a receiver gather when its kind is `gkReceiver`, the same
## decision as the record on show; every other kind is checked as a shot.
## `recordCompleteness` reads only the source domain, so a receiver gather
## is checked against the receiver-domain relations stored as source-domain
## records (the receiver as the record's source, the sources as its
## receivers) and keys with those stations swapped. Those relations are the
## loaded O records, or, when none are loaded, the ones `receiverRelations`
## derives from the X records, numbered after the survey's. The match is by
## that station (`rmSourceStation`), not by the derived record number. A
## receiver gather that matches nothing is listed in `unmatched`. The report
## uses that geometry when every
## file is a receiver gather, the survey when every file is a shot, and a
## copy of the survey with those records added (numbered after the
## survey's, so the numbers do not collide) when the folder has both.

import std/[os, sets, strutils]
import parseSEG
import processSEG/qc/record
import filejobs, filesystem, jobs, missingreport, session, threads

const
  NoSurvey* = "Import a survey with a relation file first."
  TraceChunk = 256 ## traces between cancel checks inside one gather

type
  MissingJobResult* = object
    ## What the scan did. `ok` false: `reason` is a sentence for the user,
    ## and `report` is empty. A cancel does not fill this.
    ok*: bool
    report*: MissingReport
    skipped*: seq[tuple[path, why: string]] ## relative to the folder, and why
    unmatched*: seq[tuple[path: string; record: int64; why: string]]
      ## A gather not checked: path relative to the folder, the header record
      ## number (−1 when it has none), and why.
    reason*: string

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

proc openKeys(path: string; ctx: JobContext): Session =
  ## The file at `path`, keys only, closed by the caller. A cancel during
  ## the open is `SegCancelledError`. An unmapped read that fails (`fkIo`)
  ## raises here, before the file is opened.
  fs.unmappedFail(path)
  let progress: Progress = proc (done, total: int64): bool {.gcsafe, raises: [].} =
    try: fs.mappedRead(path)
    except CatchableError: discard
    ctx.progress(done, total)
  openSession(path, progress)

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

proc scanMissing*(folder: string; paths: seq[string]; relations: ref SurveyGeometry;
    sink: MissingSink): JobWork =
  ## The work of a job that scans `paths` (relative to `folder`) against
  ## `relations` and fills `sink` (`missingSpec` is the spec to submit it
  ## with). Worker-only. A cancel raises `JobCancelledError` and leaves
  ## `sink` as it was.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    if relations == nil or not relations[].hasRelations:
      fail(sink, NoSurvey, @[])
    var files: seq[FileRecords] = @[]
    var skipped: seq[tuple[path, why: string]] = @[]
    var unmatched: seq[tuple[path: string; record: int64; why: string]] = @[]
    var drop = initHashSet[int64]()
    var sawShot = false
    var sawReceiver = false
    var receiver: ref SurveyGeometry = nil
    var rels: seq[SpsRelation] = @[]
    try:
      for i, path in paths:
        ctx.setPhase "reading " & path.extractFilename
        ctx.checkCancelled()
        let rel = relTo(folder, path)
        var s: Session = nil
        var skip = ""
        var records: seq[RecordCompleteness] = @[]
        var listed = false
        try:
          s = openKeys(path, ctx)
          if s.file.kind == skUnknown: skip = "not a SEG-Y, SEG-D or SEG-2 file"
          elif s.file.index.keys.len == 0: skip = "has no trace keys"
          else:
            {.cast(gcsafe).}:
              for g in s.gathers:
                if g.traces.len == 0: continue
                beat(ctx, g.traces.len)
                let receiverGather = g.kind == gkReceiver
                if receiverGather and receiver == nil:
                  rels = relations[].receiverRelationsOf(relations[].highestRecord + 1)
                  var built = initSurveyGeometry()
                  built.addSps(SpsFile(relations: rels), rdSource)
                  receiver = new SurveyGeometry
                  receiver[] = built
                let checked =
                  if receiverGather: swappedCompleteness(receiver[], s.file, g.traces, ctx)
                  else: relations[].recordCompleteness(s.file.rowsOf(g.traces))
                if checked.isAmbiguous:
                  listed = true
                  unmatched.add (path: rel, record: fieldId(checked), why: $checked.candidates.len &
                    " survey records share this source and the record number matches neither")
                  for id in checked.candidates: drop.incl id
                elif receiverGather and checked.xpsRecord < 0:
                  listed = true
                  unmatched.add (path: rel, record: fieldId(checked),
                    why: "no survey record matches this gather")
                else:
                  records.add checked
                  if receiverGather: sawReceiver = true
                  else: sawShot = true
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
        elif records.len > 0 or not listed:
          files.add FileRecords(path: rel, records: records)
        if not ctx.progress(i + 1, paths.len):
          raise newException(JobCancelledError, "cancelled")
      var report =
        if not sawReceiver: missingReport(files, relations[])
        elif not sawShot and receiver != nil: missingReport(files, receiver[])
        else:
          var survey = relations[]
          survey.addSps(SpsFile(relations: rels), rdSource)
          missingReport(files, survey)
      clearCycleRoots()
      if drop.len > 0:
        var kept = newSeqOfCap[int64](report.totals.xpsWithoutData.len)
        for id in report.totals.xpsWithoutData:
          if id notin drop: kept.add id
        report.totals.xpsWithoutData = kept
      if sink != nil:
        sink.result = MissingJobResult(ok: true, report: report, skipped: skipped,
          unmatched: unmatched)
    except JobCancelledError:
      raise
    except SegCancelledError:
      raise newException(JobCancelledError, "cancelled")
    except CatchableError as e:
      fail(sink, if e.msg.len > 0: e.msg else: $e.name, skipped)
