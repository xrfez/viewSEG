## A background job that reads the seismic files it is given, several at a time on the
## item pool (each measured into a build of its own, merged in file order), and fills a
## trace-quality report (`qualityReport`).
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
## when it is measured. A path already scanned (compared
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
## The survey loaded on the map, the join options and the station moves are joined to each
## file's keys in memory first (`QualityJoin`, as the recorded fold joins them), so a record
## whose headers name no station finds its template by the survey's. A record whose template
## is not found is measured whole and counted by why (`Totals.unknown`): never left unsaid.
##
## `folderScan` lists a folder (its subfolders only when asked) and scans its files.

import std/[algorithm, atomics, math, options, os, sets, sequtils, tables]
import parseSEG
import processSEG/core/[pool, rows, types, workspace]
import processSEG/qc/amplitude
import components, edits, filejobs, filesystem, firstbreakjobs, firstbreaks, foldactual,
  foldjobs, itempool, jobs, join, noisearea, qualityreport, recordingkind, recordqc, relationside,
  reportside, session, settings, state, stationmoves, surveyjobs, threads
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

  QualityJoin* = object
    ## The survey the scan joins to each file's keys in memory before it tells the file's side
    ## and finds its records' templates, as the recorded fold joins it (`foldactual`): the
    ## survey files loaded on the map, the join options and the station moves (`qualityJoin`).
    ## A file is never written.
    relations*: ptr SurveyGeometry
      ## the first survey file's X records, read in place: the caller keeps them alive and
      ## unchanged until the work is back; nil: no survey is joined, only the moves applied
    stations*: array[PointRole, FoldStations] ## the survey files' stations with coordinates
    options*: JoinOptions
    moves*: StationMoves

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

proc fileProgress(it: ItemContext; done, total: int64) =
  ## The item's progress (of `PerFile`) when its file is `done` of `total` traces through (the
  ## open is over). A cancel raises `JobCancelledError`.
  let inside = Opening + (if total > 0: (PerFile - Opening) * min(done, total) div total
    else: 0'i64)
  if not it.progress(inside, PerFile):
    raise newException(JobCancelledError, "cancelled")

proc openKeys(path, cacheDir: string; it: ItemContext): Session =
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
    it.progress(if total > 0: Opening * done div total else: 0'i64, PerFile)
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
    noise: NoiseSettings; outside: openArray[bool]; noisyJudged, weakJudged: var HashSet[int];
    workers: ptr ProcessPool; tick: BreakProgress): bool =
  ## The map's noisy and weak test on the record `traces`, whose statistics are `amps`
  ## (`unread`: rows left out). Sets the flags in `amps`, and puts in `noisyJudged` the
  ## traces the test judged for noisy (not those in the exclusion area, ungrouped, of an
  ## incomplete node or unusable) and in `weakJudged` those it judged for weak (the same and
  ## those in the exclusion area). The traces `outside` the record's template (none given:
  ## empty) are not judged and are not in the statistics the others are judged against, as
  ## the map's check treats them. False when there is nothing to judge or the library
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
      let summary = noiseOfRecord(f[], traces, amps, unread, outside, br, noise)
      for i in 0 ..< traces.len:
        if summary.state[i] == nsJudged: noisyJudged.incl traces.a + i
        if summary.state[i] in {nsJudged, nsInArea}: weakJudged.incl traces.a + i
  except ValueError:
    result = false

func anySeismic(f: ptr SeismicFile; traces: Slice[int]): bool =
  for t in traces:
    if f[].index.keys[t].isSeismic: return true

proc measure(f: ptr SeismicFile; path: string; sides: set[StationSide]; killed: HashSet[int];
    b: var array[StationSide, QualityBuild];
    unread: var seq[tuple[path, why: string]]; gathers: seq[Gather];
    noise: NoiseSettings; it: ItemContext; workers: ptr ProcessPool;
    relation: ptr SurveyGeometry; domain: RelationDomain; traceMatch: TraceMatch;
    templates: bool) =
  ## Measures the file into `b`. With a `relation` (the relation records of `domain`) and
  ## `noise.templateOnly`, only the traces the record's template lists are measured: the
  ## others are counted as left out (`leaveOut`), as the map's check marks them. A record
  ## with a seismic trace whose template is not known is measured whole and counted as such
  ## (`measuredWhole`), with `relation` nil too when `templates` (the scan has relation
  ## records of the other side).
  let n = f[].len
  var first = 0
  var held: seq[TraceAmplitude] = @[] # statistics of the traces from `heldFrom` on
  var heldFrom = 0
  var missedAll = initHashSet[int]()
  # traces of the records judged so far that the test judged for noisy, for weak
  var noisyAt = initHashSet[int]()
  var weakAt = initHashSet[int]()
  var leftAt = initHashSet[int]() # traces of the records judged so far outside the template
  var nextGather = 0
  var noted = 0 # traces before it are in `b`
  template note(upTo: int) =
    # Counts the traces `noted` .. `upTo` from `held`, tested where the test judged them.
    for t in noted .. upTo:
      if t in missedAll: continue
      let k = f[].index.keys[t]
      if t in leftAt:
        leftAt.excl t
        noisyAt.excl t
        weakAt.excl t
        if k.isSeismic:
          for side in sides: b[side].leaveOut(path)
        continue
      let sampled = wantsSamples(k, t in killed)
      let flags = if sampled: held[t - heldFrom].flags else: {}
      noteTrace(b, path, k, sides, t in killed, flags, sampled and t in noisyAt,
        sampled and t in weakAt)
      noisyAt.excl t
      weakAt.excl t
    held = held[(upTo + 1 - heldFrom) .. ^1]
    heldFrom = upTo + 1
    noted = upTo + 1
  it.fileProgress(0, n)
  while first < n:
    it.checkCancelled()
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
    it.fileProgress((last + 1 + noted) div 2, n)
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
      var outside: seq[bool] = @[]
      if noise.templateOnly and (relation != nil or templates) and f.anySeismic(g):
        var found = (known: false, outside: newSeq[bool](), why: tuNoRecord)
        if relation != nil:
          {.cast(gcsafe).}:
            found = leftOutOfTemplate(f[], g, relation[], domain, traceMatch, it)
        if found.known:
          outside = move found.outside
          for i, o in outside:
            if o: leftAt.incl g.a + i
        else:
          for side in sides: b[side].measuredWhole(found.why)
      let tick = proc (done, total: int): bool {.closure, gcsafe.} =
        it.fileProgress((last + 1 + g.a + g.len * done div max(total, 1)) div 2, n)
        true
      if judgeRecord(f, path, g, rec, skip, killed, noise, outside, noisyAt, weakAt, workers,
          tick):
        for i in 0 ..< rec.len: held[g.a - heldFrom + i] = rec[i]
      note(g.b)
      it.fileProgress((last + 1 + noted) div 2, n)
    first = last + 1
  if noted < n: note(n - 1)

var itemBudget* = 256'i64 shl 20
  ## Most bytes of files in hand at once. The pool lets the first file not yet taken run
  ## whatever its size, so a file over the budget runs alone and never waits for ever. Set
  ## only by tests.

type
  QualityFile = object
    ## What the scan knows of one file before it is opened: the traces its edits killed and the
    ## kind the user set for it.
    path: string
    killed: HashSet[int]
    forced: bool
    forcedKind: RecordingKind

  QualityItems = object
    ## What every item of a batch reads, never writes. No `ref` is inside it; the relation
    ## records are reached by `ptr`.
    files: seq[QualityFile]
    cacheDir: string
    noise: NoiseSettings
    shotTemplate, receiverTemplate: ptr SurveyGeometry
      ## the relation records the shot gathers' X records and the receiver gathers' O records
      ## are read from (nil for none); the job keeps them alive and unchanged
    traceMatch: TraceMatch
    templates: bool ## the template is asked for, and some relation records are given
    survey: ptr SurveyGeometry ## the survey joined to each file (nil: none), the job's own
    options: JoinOptions
    moves: StationMoves
    untold: UntoldKind
    folderRun: bool
    sizes: seq[int64] ## the file sizes: what an item can tell of what runs beside it
    budget: int64
    narrow, wide: int
      ## threads for the first-break passes of a file that runs beside others, and of one that
      ## runs alone (the only file, or too large to share the budget)
    mixed: Atomic[bool] ## `take` saw shot and receiver gathers together: nothing is measured now
    round: int ## 0: the files; 1: those whose kind cannot be told, taken as `takenAs`
    takenAs: ReportSide

  QualityOne = object
    ## What one file came to, for `apply` to put with the others in file order: the file's own
    ## stations and notes, nothing kept per trace.
    seismic: bool ## it opened and is a seismic file
    why: string ## why it is unread, in words ("" for it is not)
    sided: bool ## its side was decided
    side: ReportSide
    sideWhy: string
    chose: bool ## its side is the user's choice for the files that cannot be told
    deferred: bool ## left for the second round
    measured: bool
    measureWhy: string ## the measuring failed part-way: it counts nothing
    shortWhy: string ## its walk stopped short
    unread: seq[tuple[path, why: string]] ## the traces whose samples could not be read
    build: QualityBuild ## the file's stations, at its side

  ScanState = object
    ## What the scan has taken of the files so far, in file order.
    builds: array[StationSide, QualityBuild]
    unread, notChecked, deferred: seq[tuple[path, why: string]]
    deferredAt: seq[int]
    read: seq[string] ## the files the scan read as seismic: only these are taken by the CSV refusal
    counts: SideCounts
    taken: int
    takenAs: ReportSide

static:
  doAssert plainData(QualityOne) # (`QualityItems` holds two `ptr` to the relations, no `ref`)

proc qualityFile(edits: Table[string, FileEdits]; forced: Table[string, RecordingKind];
    path: string): QualityFile =
  result = QualityFile(path: path, killed: killedSet(edits, path))
  let key = forcedPath(path)
  if key in forced:
    result.forced = true
    result.forcedKind = forced[key]

proc qualityItem(it: ItemContext; a: ptr QualityItems; i: int): QualityOne
    {.nimcall, gcsafe.} =
  ## Opens file `i`, tells its side and, when it has one, measures it into a build of its own.
  ## A cancel raises; any other failure is the file's `why`.
  let path = a.files[i].path
  var s: Session = nil
  var workers: ProcessPool # (one thread for the first-break passes of this file's records)
  try:
    s = openKeys(path, a.cacheDir, it)
    result.seismic = s.file.kind != skUnknown
    if s.file.kind == skUnknown: result.why = "not a SEG-Y, SEG-D or SEG-2 file"
    elif s.file.len == 0: result.why = "has no trace keys"
    else:
      if a.survey != nil or a.moves.len > 0:
        # the survey on the map and the moves, in memory only, as the recorded fold joins them:
        # a record whose headers name no station finds its template by the survey's
        let progress = proc (done, total: int): bool {.gcsafe, raises: [].} = not it.cancelled
        {.cast(gcsafe).}:
          discard joinOwnFile(s.filePtr, a.survey, a.options, a.moves, false, progress)
      let isForced = a.files[i].forced
      let kind =
        if isForced: some(a.files[i].forcedKind)
        else: autoKindOf(s, path, proc () {.gcsafe.} = it.checkCancelled())
      var whole = initStations()
      for k in s.file.index.keys: whole.note(k)
      var fileSide = reportSide(kind, isForced, whole)
      if a.round == 1: fileSide = (a.takenAs, "")
      elif fileSide.side == rsCannotTell and a.untold != ukNotChecked:
        # the user's choice for the files that cannot be told
        let choice = if a.untold == ukShot: rsShot else: rsReceiver
        fileSide = (choice, "")
        result.chose = true
      (result.side, result.sideWhy) = fileSide
      result.sided = true
      if a.round == 0 and fileSide.side == rsCannotTell and a.folderRun:
        result.deferred = true
      elif fileSide.side != rsCannotTell and not a.mixed.load:
        # (a mix seen by the files before this one leaves the rest only counted)
        # (a continuous recording is measured at its receiver stations)
        let side = if fileSide.side == rsReceiver: ssSources else: ssReceivers
        var part: array[StationSide, QualityBuild] = [initQualityBuild(), initQualityBuild()]
        var partUnread: seq[tuple[path, why: string]] = @[]
        try:
          if s.gathers.len > 0:
            let alone = a.files.len == 1 or a.sizes[i] * 2 > a.budget
            workers = newProcessPool(if alone: a.wide else: a.narrow)
          let shot = fileSide.side == rsShot
          measure(s.filePtr, path, {side}, a.files[i].killed, part, partUnread, s.gathers,
            a.noise, it, addr workers, (if shot: a.shotTemplate else: a.receiverTemplate),
            (if shot: rdSource else: rdReceiver), a.traceMatch, a.templates)
          result.measured = true
          result.build = part[side]
          result.unread = partUnread
          result.shortWhy = cutShortWhy(s.file)
        except SegCancelledError:
          raise newException(JobCancelledError, "cancelled")
        except JobCancelledError:
          raise
        except CatchableError as e:
          # (a file that fails part-way counts nothing)
          result.measureWhy = if e.msg.len > 0: e.msg else: $e.name
  except SegCancelledError:
    raise newException(JobCancelledError, "cancelled")
  except JobCancelledError:
    raise
  except CatchableError as e:
    result.why = if e.msg.len > 0: e.msg else: $e.name
  finally:
    s = nil
    clearCycleRoots()

proc apply(st: var ScanState; path: string; at: int; one: sink QualityOne; round: int;
    untold: UntoldKind) =
  ## Takes what file `path` came to, as the files before it were: the files are taken in
  ## order, so a mix seen by the files before this one leaves it only counted.
  var why = one.why
  var shortWhy = ""
  if round == 0 and one.seismic: st.read.add path
  if one.sided:
    if one.chose:
      st.takenAs = if untold == ukShot: rsShot else: rsReceiver
      inc st.taken
    if one.deferred:
      st.deferred.add (path: path, why: one.sideWhy)
      st.deferredAt.add at
    else:
      st.counts.note one.side
      if one.side == rsCannotTell:
        st.notChecked.add (path: path, why: one.sideWhy)
      elif not st.counts.isMixed:
        # (a mix is not reported: once both sides are seen, files are only counted)
        if one.measureWhy.len > 0:
          why = one.measureWhy
        elif one.measured:
          let side = if one.side == rsReceiver: ssSources else: ssReceivers
          st.builds[side].absorb one.build
          st.unread.add one.unread
          shortWhy = one.shortWhy
  if why.len > 0: st.unread.add (path: path, why: why)
  if shortWhy.len > 0: st.unread.add (path: path, why: shortWhy)

proc runRound(ctx: JobContext; st: ptr ScanState; args: ptr QualityItems; at: seq[int]) =
  ## Measures `args.files` (file `at[k]` of the scan is `args.files[k]`) on the item pool and
  ## takes them in order.
  let count = args.files.len
  var sizes = newSeq[int64](count)
  for k, f in args.files:
    try:
      sizes[k] = max(0'i64, fs.getFileSize(f.path))
    except OSError:
      sizes[k] = 0 # the item says why it cannot be read
  args.sizes = sizes
  args.budget = itemBudget
  let threads = max(1, min(ctx.itemThreads, count))
  args.wide = defaultBreakWorkers()
  args.narrow = max(1, args.wide div threads)
  proc take(k: int; outcome: sink ItemOutcome[QualityOne]) {.closure, gcsafe.} =
    if ctx.cancelled: raise newException(JobCancelledError, "cancelled")
    if outcome.ok:
      st[].apply(args.files[k].path, at[k], outcome.value, args.round, args.untold)
      if st.counts.isMixed: args.mixed.store(true)
    elif outcome.failure.cancelled:
      raise newException(JobCancelledError, "cancelled")
    else:
      let e = outcome.failure
      st.unread.add (path: args.files[k].path, why: if e.msg.len > 0: e.msg else: e.name)
  ctx.setPhase "measuring"
  let ran = ctx.parallelItems(count, args, qualityItem, take,
    ItemOptions(scale: PerFile, cost: sizes, budget: itemBudget))
  if ran.taken < count: raise newException(JobCancelledError, "cancelled")

proc fail(sink: QualitySink; why: string; unread: seq[tuple[path, why: string]]) =
  if sink != nil:
    sink.result = QualityJobResult(ok: false, reason: why, unread: unread)
  raise newException(ValueError, why)

proc scanQuality*(paths: seq[string]; edits: Table[string, FileEdits]; sink: QualitySink;
    cacheDir = ""; noise = NoiseSettings();
    forced = initTable[string, RecordingKind](); untold = ukNotChecked;
    folderRun = false; relations: ptr SurveyGeometry = nil;
    receivers: ptr SurveyGeometry = nil; traceMatch = tmAuto; join = QualityJoin()): JobWork =
  ## The work of a job that scans `paths` and fills `sink` (`qualitySpec`
  ## is the spec to submit it with). Worker-only. `edits` is keyed by the
  ## path strings in `paths`. A cancel raises `JobCancelledError` and leaves
  ## `sink` as it was. `cacheDir` is the index cache folder: "" leaves the
  ## cache alone. A nil `sink` is not filled. `noise` is the user's choice of
  ## exclusion area for the noisy test. `forced` holds the kind the user set for a file in
  ## the Files window, by the canonical path (`reportside.forcedPath`): it replaces the kind
  ## told from the file. Files whose kind cannot be told are taken for what `untold` says;
  ## with "not checked" and `folderRun`, for the side of the files that are told when all of
  ## those are of one (`takenNote` says so), else left out. Up to the item pool's threads of
  ## files are open at once, each measured into a build of its own that is merged in file
  ## order, so the report is the same on one thread and on eight; the files in hand hold at
  ## most 256 MiB together (a file larger than that runs alone). With `noise.templateOnly`
  ## (the setting's default), the traces a record's template does not list are left out: a
  ## shot's X record in `relations`, a receiver gather's O records in `receivers` (nil: the O
  ## records of `relations`, else those derived here from its X records, as the map derives
  ## them: `derivedReceiverRecords`), found as the map's check finds them
  ## (`recordqc.leftOutOfTemplate`, `traceMatch` as the join's). They are not measured, not
  ## counted in a station or a total, and counted apart (`Totals.outside`). Before that,
  ## `join` is joined to each file's keys in memory (a record whose headers name no station
  ## finds its template by the survey's). A record whose template is not found is measured
  ## whole and counted by why (`Totals.unknown`), and so is a record of a side with no
  ## relation records when the other side has some; with `relations` and `receivers` both nil
  ## every record is measured whole and none is counted. They are read in place: the work
  ## holds their addresses, never a `ref`, and the caller keeps them alive and unchanged until
  ## the work is back (`Jobs.workingOn`; the app's `holdGeometry`).
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    var st = ScanState(builds: [initQualityBuild(), initQualityBuild()])
    try:
      var survey = SurveyGeometry() # the survey joined, read by every item
      if join.relations != nil:
        ctx.setPhase "gathering the survey"
        {.cast(gcsafe).}:
          survey = geometryOf(join.relations, join.stations)
        ctx.checkCancelled()
      # no O records given: those of `relations`, else derived here from its X records
      var made = SurveyGeometry()
      var oRecords = receivers
      if oRecords == nil and relations != nil and noise.templateOnly:
        if relations[].relationCount(rdReceiver) > 0: oRecords = relations
        elif relations[].relationCount(rdSource) > 0:
          ctx.setPhase "deriving the receivers' shots"
          {.cast(gcsafe).}:
            made = derivedReceiverRecords(relations[])
          oRecords = addr made
          ctx.checkCancelled()
      # the files, each path once (compared normalised)
      var args = QualityItems(cacheDir: cacheDir, noise: noise, untold: untold,
        folderRun: folderRun, traceMatch: traceMatch,
        shotTemplate: relations, receiverTemplate: oRecords,
        templates: noise.templateOnly and (relations != nil or oRecords != nil),
        survey: (if join.relations != nil: addr survey else: nil), options: join.options,
        moves: join.moves)
      var seen = initHashSet[string]()
      var at: seq[int] = @[]
      for path in paths:
        if not seen.containsOrIncl path.normalizedPath:
          at.add args.files.len
          args.files.add qualityFile(edits, forced, path)
      ctx.runRound(addr st, addr args, at)
      if st.deferred.len > 0:
        # the files that cannot be told: the side of those that are, when all are of one
        let one = unanimousSide(st.counts)
        if one == rsCannotTell:
          st.counts.untold += st.deferred.len
          for d in st.deferred: st.notChecked.add (path: d.path, why: d.why)
          st.deferred.setLen 0
        else:
          st.takenAs = one
          st.taken = st.deferred.len
          var again = QualityItems(cacheDir: cacheDir, noise: noise, untold: untold,
            folderRun: folderRun, round: 1, takenAs: one, traceMatch: traceMatch,
            shotTemplate: args.shotTemplate, receiverTemplate: args.receiverTemplate,
            templates: args.templates, survey: args.survey, options: args.options,
            moves: args.moves)
          for k in st.deferredAt: again.files.add args.files[k]
          st.deferred.setLen 0
          st.deferredAt.setLen 0
          ctx.runRound(addr st, addr again, newSeq[int](again.files.len))
      ctx.setPhase "reporting"
      ctx.checkCancelled()
      if sink != nil:
        sink.result = QualityJobResult(ok: true, unread: st.unread, notChecked: st.notChecked,
          sides: st.counts, paths: st.read.mapIt(it.normalizedPath),
          taken: takenNote(st.taken, st.takenAs, untold != ukNotChecked))
        if st.counts.isMixed:
          sink.result.mixed = mixedNote(st.counts)
        else:
          sink.result.receivers = qualityReport(st.builds[ssReceivers])
          sink.result.sources = qualityReport(st.builds[ssSources])
    except JobCancelledError:
      raise
    except SegCancelledError:
      raise newException(JobCancelledError, "cancelled")
    except CatchableError as e:
      fail(sink, if e.msg.len > 0: e.msg else: $e.name, st.unread)

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
    noise: NoiseSettings; forced = initTable[string, RecordingKind](); untold = ukNotChecked;
    relations: ptr SurveyGeometry = nil; receivers: ptr SurveyGeometry = nil;
    traceMatch = tmAuto; join = QualityJoin()): JobWork =
  ## The work of a job that scans the one file `path`, with the edits `snap` holds for it.
  ## `relations`, `receivers` and `join` as `scanQuality` reads them.
  scanQuality(@[path], editsFor([path], snap), sink, cacheDir, noise, forced, untold,
    relations = relations, receivers = receivers, traceMatch = traceMatch, join = join)

proc folderScan*(folder: string; subfolders: bool; cacheDir: string; snap: EditsSnapshot;
    sink: QualitySink; note: QualityNote; noise: NoiseSettings;
    forced = initTable[string, RecordingKind](); untold = ukNotChecked;
    relations: ptr SurveyGeometry = nil; receivers: ptr SurveyGeometry = nil;
    traceMatch = tmAuto; join = QualityJoin()): JobWork =
  ## The work of a job that lists the seismic files of `folder`, its subfolders only
  ## when `subfolders`, and scans them as `scanQuality` does (`relations`, `receivers` and
  ## `join` read in place as it reads them). `note.capped` says the list
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
    let scan = scanQuality(paths, editsFor(paths, snap), sink, cacheDir, noise, forced, untold,
      true, relations, receivers, traceMatch, join)
    scan(ctx)

proc qualityJoin*(st: AppState): tuple[join: QualityJoin; held: ref SurveyGeometry] =
  ## What a scan joins (`QualityJoin`), taken from `st` on the UI thread as the recorded fold
  ## takes it (`foldInputs`, `actualInputs`): the survey files loaded on the map, in a project
  ## and outside one, the join options (the project's, else the session's) and the station
  ## moves. `held` is the `ref` of `join.relations`: the caller keeps it until the work is back.
  let fold = foldInputs(st.survey, NaN, NaN)
  result.held = fold.relations
  result.join = QualityJoin(relations: (if fold.relations.isNil: nil else: addr fold.relations[]),
    stations: fold.stations, options: st.joinOptions, moves: st.project.doc.stationMoves)

proc qualityJoinKey*(st: AppState): string =
  ## Names what `qualityJoin` gives, cheaply enough for every frame: the survey files loaded
  ## (`surveySignature`), the join options, in a project its revision (the station moves are
  ## its), and the vendor maps' load.
  surveySignature(st.survey) & "|" & $st.joinOptions & "|" &
    (if st.inProject: $st.project.revision else: "-") & "|" & $st.vendorGen
