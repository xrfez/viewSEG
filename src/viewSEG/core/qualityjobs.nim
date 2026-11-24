## A background job that reads the seismic files it is given, one at a time,
## and fills a trace-quality report (`qualityReport`).
##
## The caller lists the paths and the per-file edits. A killed trace is
## counted as killed, not as bad, and is not measured. An auxiliary trace
## is not a note. Header-dead is that finding only. Samples are read in
## chunks of 512 traces, through the file-system layer, and each run of
## one sample interval is measured at that interval. Header-dead, killed
## and auxiliary traces are not sample-read for their statistics, even when the chunk also
## holds a live trace (the first-break pass of a record that is judged reads that
## record whole). A trace whose samples
## could not be read is not a note: it is an unread row naming the file,
## the trace and the reader's reason. A file whose walk stopped short is
## unread as cut short; its other traces still count. Each file is closed
## before the next opens. A path already scanned (compared
## normalised) is not scanned again and is not unread. A file that cannot
## be opened, or that is not seismic, is one unread row and the scan goes
## on. A cancel leaves the sink untouched.
##
## Weak and noisy traces are found as the map finds them (`noiseOfRecord`,
## the record's first breaks found as the map's job finds them, the user's
## exclusion area), one field record (a gather of the session) at a time: a
## record holds only its own traces' statistics until it is judged. Traces
## that were not sample-read, traces the test did not judge (inside the exclusion
## area, ungrouped, of an incomplete node, unusable) and records whose test the
## library refuses are not tested: their cells stay empty.
##
## The report keeps each path as the caller named it. Unread files are not
## a total of the report.

import std/[algorithm, os, sets, tables]
import parseSEG
import processSEG/core/[rows, types, workspace]
import processSEG/qc/amplitude
import components, edits, filejobs, filesystem, firstbreakjobs, firstbreaks, jobs, noisearea,
    qualityreport,
  recordqc, session, threads

const QcChunk = 512 ## traces read and measured at a time

type
  QualityJobResult* = object
    ## What the scan did. `ok` false: `reason` is a sentence, and `report`
    ## is empty. A cancel does not fill this.
    ok*: bool
    report*: QualityReport
    unread*: seq[tuple[path, why: string]]
    reason*: string

  QualitySink* = ref object
    ## Filled when the job ends, except when it is cancelled. Read it after
    ## the job is no longer running. Nil is not filled.
    result*: QualityJobResult

proc qualitySpec*(paths: openArray[string]): JobSpec =
  ## The job that scans `paths`: background, reading each path.
  JobSpec(title: "Trace quality", lane: jlBackground, reads: @paths)

proc openKeys(path, cacheDir: string; ctx: JobContext): Session =
  # The file at `path`, keys included, closed by the caller. A cancel during
  # the open is `SegCancelledError`. An unmapped read that fails raises
  # here, before the file is opened. A current index cache in `cacheDir` is
  # read instead of walking the headers; a walk saves one. A save that
  # fails is ignored: the scan still has the keys.
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

proc killedSet(edits: Table[string, FileEdits]; path: string): HashSet[int] =
  if edits.hasKey(path):
    for t in edits[path].shown.lists[teKilled]:
      result.incl t

func wantsSamples(k: TraceKeys; killed: bool): bool =
  k.isSeismic and k.status != tsDead and not killed

proc liveSpans(f: ptr SeismicFile; part: Slice[int]; killed: HashSet[int]): seq[Slice[int]] =
  var start = -1
  for t in part.a .. part.b:
    let on = wantsSamples(f[].index.keys[t], t in killed)
    if on and start < 0: start = t
    elif not on and start >= 0:
      result.add start .. (t - 1)
      start = -1
  if start >= 0: result.add start .. part.b

proc noteTrace(b: var QualityBuild; path: string; k: TraceKeys; killed: bool;
    flags: set[AmplitudeFlag]; tested: bool) =
  if not k.isSeismic: return
  var findings: set[Finding] = {}
  if not killed:
    findings = findingsOf(flags, k.status == tsDead)
  b.addTrace(TraceNote(file: path, record: k.record, line: k.rcvLine, point: k.rcvPoint,
    index: k.rcvIndex, component: componentOf(k), killed: killed, findings: findings,
    tested: tested, noisy: tested and afNoisy in flags, weak: tested and afWeak in flags))

func msOfUs(us: float64): float64 =
  if us > 0 and us < Inf: us / 1000.0 else: 1.0

proc failedRows(log: DiagLog; part: Slice[int]): seq[int] =
  for d in log:
    if d.severity >= sevError and d.loc.trace in part:
      let row = d.loc.trace - part.a
      if row notin result: result.add row
  result.sort(system.cmp[int])

proc readWhy(trace: int; msg: string): string =
  result = "trace " & $(trace + 1) & " could not be read"
  if msg.len > 0: result.add ": " & msg

proc unreadFailed(log: DiagLog; part: Slice[int]; path: string;
    unread: var seq[tuple[path, why: string]]): HashSet[int] =
  for d in log:
    if d.severity >= sevError and d.loc.trace in part and d.loc.trace notin result:
      result.incl d.loc.trace
      unread.add (path: path, why: readWhy(d.loc.trace, d.msg))

func cutShortWhy(f: SeismicFile): string =
  for d in f.log:
    if d.code == dcTruncated and d.severity == sevFatal:
      result = "it is cut short"
      if d.loc.trace >= 0: result.add " at trace " & $(d.loc.trace + 1)
      if d.msg.len > 0: result.add ": " & d.msg
      return

proc judgeRecord(f: ptr SeismicFile; path: string; traces: Slice[int];
    amps: var seq[TraceAmplitude]; unread: openArray[int]; killed: HashSet[int];
    noise: NoiseSettings; ctx: JobContext; judged: var HashSet[int]): bool =
  ## The map's noisy and weak test on the record `traces`, whose statistics are `amps`
  ## (`unread`: rows left out). Sets the flags in `amps`, and puts in `judged` the traces
  ## the test judged (not those in the exclusion area, ungrouped, of an incomplete node or
  ## unusable). False when there is nothing to judge or the library refuses.
  if unread.len >= traces.len: return false
  var off: seq[int] = @[]
  for t in traces:
    if t in killed: off.add t
  var br = FirstBreaks()
  try:
    {.cast(gcsafe).}:
      br = breaksOfRecord(f, path, traces, off, proc (done, total: int): bool =
        ctx.checkCancelled()
        true)
      result = true
      let summary = noiseOfRecord(f[], traces, amps, unread, [], br, noise)
      for i in 0 ..< traces.len:
        if summary.state[i] == nsJudged: judged.incl traces.a + i
  except ValueError:
    result = false

proc measure(f: ptr SeismicFile; path: string; killed: HashSet[int]; b: var QualityBuild;
    unread: var seq[tuple[path, why: string]]; gathers: seq[Gather];
    noise: NoiseSettings; ctx: JobContext) =
  let n = f[].len
  var first = 0
  var chunk = 0
  var held: seq[TraceAmplitude] = @[] # statistics of the traces from `heldFrom` on
  var heldFrom = 0
  var missedAll = initHashSet[int]()
  var judgedAt = initHashSet[int]() # traces of the records judged so far that the test judged
  var nextGather = 0
  var noted = 0 # traces before it are in `b`
  template note(upTo: int) =
    # Counts the traces `noted` .. `upTo` from `held`, tested where the test judged them.
    for t in noted .. upTo:
      if t in missedAll: continue
      let k = f[].index.keys[t]
      let sampled = wantsSamples(k, t in killed)
      let flags = if sampled: held[t - heldFrom].flags else: {}
      noteTrace(b, path, k, t in killed, flags, sampled and t in judgedAt)
      judgedAt.excl t
    held = held[(upTo + 1 - heldFrom) .. ^1]
    heldFrom = upTo + 1
    noted = upTo + 1
  while first < n:
    if chunk > 0: ctx.setPhase "measuring"
    ctx.checkCancelled()
    let last = min(n - 1, first + QcChunk - 1)
    let part = first .. last
    var amps: seq[TraceAmplitude] = @[]
    amps.setLen(part.b - part.a + 1)
    var missed = initHashSet[int]()
    for span in liveSpans(f, part, killed):
      if not f[].inMemory: fs.mappedRead(path)
      let cols = f[].maxSamples(span)
      if cols <= 0: continue
      var log: DiagLog
      var failed: seq[int] = @[]
      {.cast(gcsafe).}:
        let samples = f[].readTraces(span, 0 ..< cols, log)
        failed = failedRows(log, span)
        var ws = initWorkspace()
        ws.reserve(traceAmplitudeWorkspace(cols))
        let read = rowBlock(samples)
        var runAmps: seq[TraceAmplitude] = @[]
        for run in f[].uniformRuns(span):
          let rows = (run.a - span.a) .. (run.b - span.a)
          var runFailed: seq[int] = @[]
          for row in failed:
            if row >= rows.a and row <= rows.b: runFailed.add row - rows.a
          let meta = initChunkMeta(f[].rowsOf(run),
            msOfUs(f[].index.keys[run.a].intervalUs), 0, runFailed)
          let piece = read.sub(rows)
          runAmps.setLen piece.len
          traceAmplitudeInto(piece, meta, AmplitudeParams(), runAmps, ws)
          let at = run.a - part.a
          for row, a in runAmps: amps[at + row] = a
      for t in unreadFailed(log, span, path, unread): missed.incl t
    for t in missed: missedAll.incl t
    held.add amps
    while nextGather < gathers.len and gathers[nextGather].traces.b <= last:
      let g = gathers[nextGather].traces
      inc nextGather
      if g.a < noted or g.b < g.a: continue
      if g.a > noted: note(g.a - 1)
      var rec = held[g.a - heldFrom .. g.b - heldFrom]
      var skip: seq[int] = @[]
      for t in g:
        if t in missedAll or not wantsSamples(f[].index.keys[t], t in killed):
          skip.add t - g.a
      if judgeRecord(f, path, g, rec, skip, killed, noise, ctx, judgedAt):
        for i in 0 ..< rec.len: held[g.a - heldFrom + i] = rec[i]
      note(g.b)
    first = last + 1
    inc chunk
  if noted < n: note(n - 1)

proc fail(sink: QualitySink; why: string; unread: seq[tuple[path, why: string]]) =
  if sink != nil:
    sink.result = QualityJobResult(ok: false, reason: why, unread: unread)
  raise newException(ValueError, why)

proc scanQuality*(paths: seq[string]; edits: Table[string, FileEdits]; sink: QualitySink;
    cacheDir = ""; noise = NoiseSettings()): JobWork =
  ## The work of a job that scans `paths` and fills `sink` (`qualitySpec`
  ## is the spec to submit it with). Worker-only. `edits` is keyed by the
  ## path strings in `paths`. A cancel raises `JobCancelledError` and leaves
  ## `sink` as it was. `cacheDir` is the index cache folder: "" leaves the
  ## cache alone. A nil `sink` is not filled. `noise` is the user's choice of
  ## exclusion area for the noisy test.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    var unread: seq[tuple[path, why: string]] = @[]
    var build = initQualityBuild()
    var seen = initHashSet[string]()
    try:
      for i, path in paths:
        ctx.setPhase "reading " & path.extractFilename
        ctx.checkCancelled()
        let key = path.normalizedPath
        if key notin seen:
          seen.incl key
          var s: Session = nil
          var why = ""
          var shortWhy = ""
          try:
            s = openKeys(path, cacheDir, ctx)
            if s.file.kind == skUnknown: why = "not a SEG-Y, SEG-D or SEG-2 file"
            elif s.file.len == 0: why = "has no trace keys"
            else:
              let f = s.filePtr
              measure(f, path, killedSet(edits, path), build, unread, s.gathers, noise, ctx)
              shortWhy = cutShortWhy(s.file)
          except SegCancelledError:
            raise newException(JobCancelledError, "cancelled")
          except JobCancelledError:
            raise
          except CatchableError as e:
            why = if e.msg.len > 0: e.msg else: $e.name
          finally:
            s = nil
            clearCycleRoots()
          if why.len > 0: unread.add (path: path, why: why)
          if shortWhy.len > 0: unread.add (path: path, why: shortWhy)
        if not ctx.progress(i + 1, paths.len):
          raise newException(JobCancelledError, "cancelled")
      ctx.setPhase "reporting"
      ctx.checkCancelled()
      if sink != nil:
        sink.result = QualityJobResult(ok: true, report: qualityReport(build), unread: unread)
    except JobCancelledError:
      raise
    except SegCancelledError:
      raise newException(JobCancelledError, "cancelled")
    except CatchableError as e:
      fail(sink, if e.msg.len > 0: e.msg else: $e.name, unread)
