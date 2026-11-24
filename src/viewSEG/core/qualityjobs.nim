## A background job that reads the seismic files it is given, one at a time,
## and fills a trace-quality report (`qualityReport`).
##
## The caller lists the paths and the per-file edits. A killed trace is
## counted as killed, not as bad, and is not measured. An auxiliary trace
## is not a note. Header-dead is that finding only. Samples are read in
## chunks of 512 traces, through the file-system layer, and each run of
## one sample interval is measured at that interval. Each file is closed
## before the next opens. A path already scanned (compared
## normalised) is not scanned again and is not unread. A file that cannot
## be opened, or that is not seismic, is one unread row and the scan goes
## on. A cancel leaves the sink untouched.
##
## The report keeps each path as the caller named it. Unread files are not
## a total of the report.

import std/[algorithm, os, sets, tables]
import parseSEG
import processSEG/core/[rows, types, workspace]
import processSEG/qc/amplitude
import components, edits, filejobs, filesystem, jobs, qualityreport, session, threads

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

proc skipSamples(f: ptr SeismicFile; part: Slice[int]; killed: HashSet[int]): bool =
  for t in part.a .. part.b:
    let k = f[].index.keys[t]
    if k.isSeismic and k.status != tsDead and t notin killed:
      return false
  true

proc noteTrace(b: var QualityBuild; path: string; k: TraceKeys; killed: bool;
    flags: set[AmplitudeFlag]) =
  if not k.isSeismic: return
  var findings: set[Finding] = {}
  if not killed:
    findings = findingsOf(flags, k.status == tsDead)
  b.addTrace(TraceNote(file: path, record: k.record, line: k.rcvLine, point: k.rcvPoint,
    index: k.rcvIndex, component: componentOf(k), killed: killed, findings: findings))

func intervalMs(us: float64): float64 =
  if us > 0 and us < Inf: us / 1000.0 else: 1.0

proc failedRows(log: DiagLog; part: Slice[int]): seq[int] =
  for d in log:
    if d.loc.trace in part:
      let row = d.loc.trace - part.a
      if row notin result: result.add row
  result.sort(system.cmp[int])

proc measure(f: ptr SeismicFile; path: string; killed: HashSet[int]; b: var QualityBuild;
    ctx: JobContext) =
  let n = f[].len
  var first = 0
  var chunk = 0
  while first < n:
    if chunk > 0: ctx.setPhase "measuring"
    ctx.checkCancelled()
    let last = min(n - 1, first + QcChunk - 1)
    let part = first .. last
    if skipSamples(f, part, killed):
      for t in part.a .. part.b:
        noteTrace(b, path, f[].index.keys[t], t in killed, {})
    else:
      if not f[].inMemory: fs.mappedRead(path)
      let cols = f[].maxSamples(part)
      if cols <= 0:
        for t in part.a .. part.b:
          noteTrace(b, path, f[].index.keys[t], t in killed, {})
      else:
        var log: DiagLog
        var failed: seq[int] = @[]
        var amps: seq[TraceAmplitude] = @[]
        {.cast(gcsafe).}:
          let samples = f[].readTraces(part, 0 ..< cols, log)
          failed = failedRows(log, part)
          var ws = initWorkspace()
          ws.reserve(traceAmplitudeWorkspace(cols))
          let read = rowBlock(samples)
          amps.setLen(part.b - part.a + 1)
          var runAmps: seq[TraceAmplitude] = @[]
          for run in f[].uniformRuns(part):
            let rows = (run.a - part.a) .. (run.b - part.a)
            var runFailed: seq[int] = @[]
            for row in failed:
              if row >= rows.a and row <= rows.b: runFailed.add row - rows.a
            let meta = initChunkMeta(f[].rowsOf(run),
              intervalMs(f[].index.keys[run.a].intervalUs), 0, runFailed)
            let piece = read.sub(rows)
            runAmps.setLen piece.len
            traceAmplitudeInto(piece, meta, AmplitudeParams(), runAmps, ws)
            for row, a in runAmps: amps[rows.a + row] = a
        for row in 0 ..< amps.len:
          let t = part.a + row
          let flags = if t in killed or f[].index.keys[t].status == tsDead: {} else: amps[row].flags
          noteTrace(b, path, f[].index.keys[t], t in killed, flags)
    first = last + 1
    inc chunk

proc fail(sink: QualitySink; why: string; unread: seq[tuple[path, why: string]]) =
  if sink != nil:
    sink.result = QualityJobResult(ok: false, reason: why, unread: unread)
  raise newException(ValueError, why)

proc scanQuality*(paths: seq[string]; edits: Table[string, FileEdits]; sink: QualitySink;
    cacheDir = ""): JobWork =
  ## The work of a job that scans `paths` and fills `sink` (`qualitySpec`
  ## is the spec to submit it with). Worker-only. `edits` is keyed by the
  ## path strings in `paths`. A cancel raises `JobCancelledError` and leaves
  ## `sink` as it was. `cacheDir` is the index cache folder: "" leaves the
  ## cache alone. A nil `sink` is not filled.
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
          try:
            s = openKeys(path, cacheDir, ctx)
            if s.file.kind == skUnknown: why = "not a SEG-Y, SEG-D or SEG-2 file"
            elif s.file.len == 0: why = "has no trace keys"
            else:
              let f = s.filePtr
              measure(f, path, killedSet(edits, path), build, ctx)
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
