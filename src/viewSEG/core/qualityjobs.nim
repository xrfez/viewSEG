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
## that were not sample-read, traces the test did not judge (ungrouped, of an
## incomplete node, unusable) and records whose test the library refuses are not
## tested: their cells stay empty. A trace inside the exclusion area is tested
## for weak, not for noisy, as the map marks it.
##
## The report keeps each path as the caller named it. Unread files are not
## a total of the report: a file that fails to read part-way adds nothing to it and is
## listed unread once.
##
## A station is a line and point. Which of a trace's two stations names it is the
## file's side (`reportside.reportSide`, the rule the missing-traces scan applies to a
## file: the kind of recording the file is treated as, the one the user set in the Files
## window or else the one told from the file): a shot gather's traces are by their
## receiver stations, a receiver gather's by their source stations, and a file's traces
## all take the one side. A continuous receiver recording, and a file whose kind is not
## told (one receiver and one source) and was not set, are not measured (`notChecked`).
## Shot gathers and receiver gathers together are not reported: the result says so
## (`mixed`). A scan keeps one report for each side (`receivers`, `sources`); a side no
## file took is empty. Nothing is computed from a trace's record number.
##
## `folderScan` lists a folder (its subfolders only when asked) and scans its files.

import std/[algorithm, options, os, sets, sequtils, tables]
import parseSEG
import processSEG/core/[pool, rows, types, workspace]
import processSEG/qc/amplitude
import components, edits, filejobs, filesystem, firstbreakjobs, firstbreaks, jobs, noisearea,
  qualityreport, recordingkind, recordqc, relationside, reportside, session, settings, state, threads
from missingreport import StationSide
export StationSide

const
  Listing* = "Listing the folder."
  CannotList* = "The folder could not be listed."
  QcChunk = 512            ## traces read and measured at a time
  PerFile = 1000'i64       ## the job's progress is this many units for each file
  Opening = PerFile div 10 ## of which the open takes the first

type
  QualityJobResult* = object
    ## What the scan did. `ok` false: `reason` is a sentence, and `report`
    ## is empty. A cancel does not fill this.
    ok*: bool
    receivers*, sources*: QualityReport ## by the side of the file each trace was in
    unread*: seq[tuple[path, why: string]]
    notChecked*: seq[tuple[path, why: string]]
      ## files left out on purpose: a continuous receiver recording, or a file whose kind
      ## is not told (one receiver and one source) and was not set
    sides*: SideCounts ## the files of the scan that were shot gathers, receiver gathers, or untold
    taken*: string
      ## not empty when files whose kind cannot be told were taken for a side, and which
      ## (`reportside.takenNote`)
    mixed*: string
      ## not empty when the files are of both kinds: nothing is measured into a report,
      ## and this says so (`reportside.mixedNote`)
    paths*: seq[string] ## the files the scan was given, normalised (what an export must not replace)
    reason*: string

  QualityNote* = ref object
    ## Set by `folderScan`: the list stopped at the file limit.
    capped*: bool

  QualitySink* = ref object
    ## Filled when the job ends, except when it is cancelled. Read it after
    ## the job is no longer running. Nil is not filled.
    result*: QualityJobResult

proc qualitySpec*(paths: openArray[string]): JobSpec =
  ## The job that scans `paths`: background, reading each path.
  JobSpec(title: "Trace quality", lane: jlBackground, reads: @paths)

func scanProgressWords*(done, total: int64): string =
  ## The progress a scan's job reports (`done` of `total`) in words: the file it is at and
  ## how much of the scan is done, "file 2 of 3, 48%". "" when `total` is not known.
  if total <= 0: return ""
  let count = max(1'i64, total div PerFile)
  let at = min(count, max(0'i64, done) div PerFile + 1)
  let percent = min(100'i64, max(0'i64, done) * 100 div total)
  "file " & $at & " of " & $count & ", " & $percent & "%"

proc fileProgress(ctx: JobContext; at, count: int; done, total: int64) =
  ## The job's progress when file `at` of `count` is `done` of `total` traces through (the
  ## open is over). A cancel raises `JobCancelledError`.
  let inside = Opening + (if total > 0: (PerFile - Opening) * min(done, total) div total
    else: 0'i64)
  if not ctx.progress(PerFile * int64(at) + inside, PerFile * int64(count)):
    raise newException(JobCancelledError, "cancelled")

proc openKeys(path, cacheDir: string; ctx: JobContext; at, count: int): Session =
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
    ctx.progress(PerFile * int64(at) + (if total > 0: Opening * done div total else: 0'i64),
      PerFile * int64(count))
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

proc noteTrace(b: var array[StationSide, QualityBuild]; path: string; k: TraceKeys;
    sides: set[StationSide]; killed: bool; flags: set[AmplitudeFlag];
    noisyTested, weakTested: bool) =
  if not k.isSeismic: return
  var findings: set[Finding] = {}
  if not killed:
    findings = findingsOf(flags, k.status == tsDead)
  for side in sides:
    let sources = side == ssSources
    b[side].addTrace(TraceNote(file: path, line: if sources: k.srcLine else: k.rcvLine,
      point: if sources: k.srcPoint else: k.rcvPoint,
      component: componentOf(k), killed: killed, findings: findings,
      noisyTested: noisyTested, weakTested: weakTested,
      noisy: noisyTested and afNoisy in flags, weak: weakTested and afWeak in flags))

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
    noise: NoiseSettings; ctx: JobContext; noisyJudged, weakJudged: var HashSet[int];
    workers: ptr ProcessPool; tick: BreakProgress): bool =
  ## The map's noisy and weak test on the record `traces`, whose statistics are `amps`
  ## (`unread`: rows left out). Sets the flags in `amps`, and puts in `noisyJudged` the
  ## traces the test judged for noisy (not those in the exclusion area, ungrouped, of an
  ## incomplete node or unusable) and in `weakJudged` those it judged for weak (the same and
  ## those in the exclusion area). False when there is nothing to judge or the library
  ## refuses.
  if unread.len >= traces.len: return false
  var off: seq[int] = @[]
  for t in traces:
    if t in killed: off.add t
  var br = FirstBreaks()
  try:
    {.cast(gcsafe).}:
      br = breaksOfRecord(f, path, traces, off, tick, shared = workers)
      result = true
      let summary = noiseOfRecord(f[], traces, amps, unread, [], br, noise)
      for i in 0 ..< traces.len:
        if summary.state[i] == nsJudged: noisyJudged.incl traces.a + i
        if summary.state[i] in {nsJudged, nsInArea}: weakJudged.incl traces.a + i
  except ValueError:
    result = false

proc measure(f: ptr SeismicFile; path: string; sides: set[StationSide]; killed: HashSet[int];
    b: var array[StationSide, QualityBuild];
    unread: var seq[tuple[path, why: string]]; gathers: seq[Gather];
    noise: NoiseSettings; ctx: JobContext; workers: ptr ProcessPool; at, count: int) =
  let n = f[].len
  var first = 0
  var held: seq[TraceAmplitude] = @[] # statistics of the traces from `heldFrom` on
  var heldFrom = 0
  var missedAll = initHashSet[int]()
  # traces of the records judged so far that the test judged for noisy, for weak
  var noisyAt = initHashSet[int]()
  var weakAt = initHashSet[int]()
  var nextGather = 0
  var noted = 0 # traces before it are in `b`
  template note(upTo: int) =
    # Counts the traces `noted` .. `upTo` from `held`, tested where the test judged them.
    for t in noted .. upTo:
      if t in missedAll: continue
      let k = f[].index.keys[t]
      let sampled = wantsSamples(k, t in killed)
      let flags = if sampled: held[t - heldFrom].flags else: {}
      noteTrace(b, path, k, sides, t in killed, flags, sampled and t in noisyAt,
        sampled and t in weakAt)
      noisyAt.excl t
      weakAt.excl t
    held = held[(upTo + 1 - heldFrom) .. ^1]
    heldFrom = upTo + 1
    noted = upTo + 1
  # one phase for the file: a phase restarts the bar and its time estimate
  ctx.setPhase "measuring"
  ctx.fileProgress(at, count, 0, n)
  while first < n:
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
    # (half of a file's share is for the reads, half for the tests)
    ctx.fileProgress(at, count, (last + 1 + noted) div 2, n)
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
      let tick = proc (done, total: int): bool {.closure, gcsafe.} =
        ctx.fileProgress(at, count, (last + 1 + g.a + g.len * done div max(total, 1)) div 2, n)
        true
      if judgeRecord(f, path, g, rec, skip, killed, noise, ctx, noisyAt, weakAt, workers,
          tick):
        for i in 0 ..< rec.len: held[g.a - heldFrom + i] = rec[i]
      note(g.b)
      ctx.fileProgress(at, count, (last + 1 + noted) div 2, n)
    first = last + 1
  if noted < n: note(n - 1)

proc fail(sink: QualitySink; why: string; unread: seq[tuple[path, why: string]]) =
  if sink != nil:
    sink.result = QualityJobResult(ok: false, reason: why, unread: unread)
  raise newException(ValueError, why)

proc scanQuality*(paths: seq[string]; edits: Table[string, FileEdits]; sink: QualitySink;
    cacheDir = ""; noise = NoiseSettings();
    forced = initTable[string, RecordingKind](); untold = ukNotChecked;
    folderRun = false): JobWork =
  ## The work of a job that scans `paths` and fills `sink` (`qualitySpec`
  ## is the spec to submit it with). Worker-only. `edits` is keyed by the
  ## path strings in `paths`. A cancel raises `JobCancelledError` and leaves
  ## `sink` as it was. `cacheDir` is the index cache folder: "" leaves the
  ## cache alone. A nil `sink` is not filled. `noise` is the user's choice of
  ## exclusion area for the noisy test. `forced` holds the kind the user set for a file in
  ## the Files window, by the canonical path (`reportside.forcedPath`): it replaces the kind
  ## told from the file. Files whose kind cannot be told are taken for what `untold` says;
  ## with "not checked" and `folderRun`, for the side of the files that are told when all of
  ## those are of one (`takenNote` says so), else left out.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    var unread: seq[tuple[path, why: string]] = @[]
    var builds: array[StationSide, QualityBuild] = [initQualityBuild(), initQualityBuild()]
    var notChecked: seq[tuple[path, why: string]] = @[]
    var counts: SideCounts
    var seen = initHashSet[string]()
    # the files the scan read as seismic: only these are taken by the CSV refusal
    var read: seq[string] = @[]
    # one set of threads for every record
    var workers = newProcessPool(defaultBreakWorkers())
    var list = paths
    var round = 0 # 0: the files; 1: those whose kind cannot be told, taken as `takenAs`
    var takenAs = rsCannotTell
    var deferred: seq[tuple[path, why: string]] = @[]
    var taken = 0
    try:
      while true:
        for i, path in list:
          ctx.setPhase "reading " & path.extractFilename
          ctx.checkCancelled()
          let key = path.normalizedPath
          let at = if round == 0: i else: paths.len - 1
          if round == 1 or key notin seen:
            seen.incl key
            var s: Session = nil
            var why = ""
            var shortWhy = ""
            try:
              s = openKeys(path, cacheDir, ctx, at, paths.len)
              if s.file.kind != skUnknown and round == 0: read.add path
              if s.file.kind == skUnknown: why = "not a SEG-Y, SEG-D or SEG-2 file"
              elif s.file.len == 0: why = "has no trace keys"
              else:
                let isForced = forcedPath(path) in forced
                let kind =
                  if isForced: some(forced[forcedPath(path)]) else: autoKindOf(s, path, ctx)
                var whole = initStations()
                for k in s.file.index.keys: whole.note(k)
                var fileSide = reportSide(kind, isForced, whole)
                if round == 1: fileSide = (takenAs, "")
                elif fileSide.side == rsCannotTell and untold != ukNotChecked:
                  # the user's choice for the files that cannot be told
                  takenAs = if untold == ukShot: rsShot else: rsReceiver
                  fileSide = (takenAs, "")
                  inc taken
                if round == 0 and fileSide.side == rsCannotTell and folderRun:
                  # taken for the side of the files that are told, when all are of one
                  deferred.add (path: path, why: fileSide.why)
                else:
                  counts.note fileSide.side
                  if fileSide.side == rsCannotTell:
                    notChecked.add (path: path, why: fileSide.why)
                  elif not counts.isMixed:
                    # (a mix is not reported: once both sides are seen, files are only
                    # counted; a continuous recording is measured at its receiver stations)
                    let side = if fileSide.side == rsReceiver: ssSources else: ssReceivers
                    # (a file that fails part-way counts nothing: it is listed unread, once)
                    var part: array[StationSide, QualityBuild] =
                      [initQualityBuild(), initQualityBuild()]
                    var partUnread: seq[tuple[path, why: string]] = @[]
                    measure(s.filePtr, path, {side}, killedSet(edits, path), part, partUnread,
                      s.gathers, noise, ctx, addr workers, at, paths.len)
                    builds[side].absorb part[side]
                    unread.add partUnread
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
          if round == 0 and not ctx.progress(PerFile * int64(i + 1), PerFile * int64(paths.len)):
            raise newException(JobCancelledError, "cancelled")
        if round == 1 or deferred.len == 0: break
        # the files that cannot be told: the side of those that are, when all are of one
        let one = unanimousSide(counts)
        if one == rsCannotTell:
          counts.untold += deferred.len
          for d in deferred: notChecked.add (path: d.path, why: d.why)
          deferred.setLen 0
          break
        takenAs = one
        taken = deferred.len
        list = @[]
        for d in deferred: list.add d.path
        round = 1
      ctx.setPhase "reporting"
      ctx.checkCancelled()
      if sink != nil:
        sink.result = QualityJobResult(ok: true, unread: unread, notChecked: notChecked,
          sides: counts, paths: read.mapIt(it.normalizedPath),
          taken: takenNote(taken, takenAs, untold != ukNotChecked))
        if counts.isMixed:
          sink.result.mixed = mixedNote(counts)
        else:
          sink.result.receivers = qualityReport(builds[ssReceivers])
          sink.result.sources = qualityReport(builds[ssSources])
    except JobCancelledError:
      raise
    except SegCancelledError:
      raise newException(JobCancelledError, "cancelled")
    except CatchableError as e:
      fail(sink, if e.msg.len > 0: e.msg else: $e.name, unread)

proc editsFor(paths: openArray[string]; snap: EditsSnapshot): Table[string, FileEdits] =
  ## `snap` keyed by each listed path, so a killed trace is found under the
  ## path the scan names. A path with no edits is left out.
  for path in paths:
    var key = ""
    let disk = diskOf(path)
    if disk in snap.alias: key = snap.alias[disk]
    elif path in snap.alias: key = snap.alias[path]
    elif disk in snap.byKey: key = disk
    elif path in snap.byKey: key = path
    else:
      let canon = canonical(path)
      if canon in snap.alias: key = snap.alias[canon]
      elif canon in snap.byKey: key = canon
    if key.len > 0 and key in snap.byKey:
      result[path] = snap.byKey[key]

proc fileScan*(path, cacheDir: string; snap: EditsSnapshot; sink: QualitySink;
    noise: NoiseSettings; forced = initTable[string, RecordingKind](); untold = ukNotChecked):
    JobWork =
  ## The work of a job that scans the one file `path`, with the edits `snap` holds for it.
  scanQuality(@[path], editsFor([path], snap), sink, cacheDir, noise, forced)

proc folderScan*(folder: string; subfolders: bool; cacheDir: string; snap: EditsSnapshot;
    sink: QualitySink; note: QualityNote; noise: NoiseSettings;
    forced = initTable[string, RecordingKind](); untold = ukNotChecked): JobWork =
  ## The work of a job that lists the seismic files of `folder`, its subfolders only
  ## when `subfolders`, and scans them as `scanQuality` does. `note.capped` says the list
  ## stopped at the file limit.
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
    let scan = scanQuality(paths, editsFor(paths, snap), sink, cacheDir, noise, forced, untold, true)
    scan(ctx)
