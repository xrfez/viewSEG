## A receiver gather: the traces one receiver station recorded for each shot, collected from
## the seismic files the Files window lists into one record that is only in memory.
##
## `gatherWork` is the job. Each listed file is opened for its keys (the index cache is read
## when it is current), joined to the project's survey and station moves in memory
## (`joinOwnFile`: a file is never written), and its traces at the station are read: the
## station is a line and a point (the receiver's index never splits it, and a record number
## never names a station), and the trace's component. A file with several such traces gives
## all of them, in file order.
##
## The files are read several at a time on the item pool. An item's result is plain data (the
## traces' keys and samples, or why the file gave none); the job's own thread takes them in
## file order, so the gather is the same on any number of threads. The survey is reached
## read-only through a pointer the caller keeps alive until the work is back; no `ref` is
## shared between threads. The job thread then
##
## - sorts the traces by record time, then by source station (a stable sort: the traces of
##   one shot stay in file order);
## - takes the sample interval and the length of the first file that gave a trace: a trace of
##   another interval is left out and its file named, one of another length is padded with
##   zeros or cut, and that is said;
## - stops at `gatherTraces` traces or `gatherBytes` bytes of samples (traces times samples
##   times 4) and says so;
## - writes the traces as an in-memory SEG-Y file (float32, so the samples are the source
##   traces' own, bit for bit) and opens it as a `Session`, which `asGathered` marks read-only.
##
## Each trace keeps its own source and receiver keys (the file's keys as the join left them,
## not what a SEG-Y header can hold), so the record list, the headers window and the offsets
## show the shots. The files the traces came from are kept by the session (`gatherSource`).
## The session is posted as `mkGathered` with a sentence that says what was gathered and what
## was left out and why; with no trace at all nothing is posted but the sentence. A cancel
## ends the job with no session. Nothing is written to disk, and no source file is opened for
## writing.

import std/[algorithm, math, os, strutils, times]
import parseSEG
import parseSEG/model/traceindex # (`mindex`: the keys of the new file are set below)
import processSEG/core/rows
import filejobs, filesystem, inbox, itempool, jobs, join, session, stationmoves, surveyjobs,
  threads

const
  KeysChunk = 65_536 ## traces whose keys are read at a time
  CancelEvery = 4096 ## traces between cancel checks
  MaxNamed = 5       ## files named one by one in the sentence; the rest are counted

var
  gatherTraces* = 20_000
    ## Most traces one gather holds. Set only by tests.
  gatherBytes* = 512'i64 shl 20
    ## Most bytes of samples one gather holds (traces times samples times 4). Set only by tests.
  gatherReadBudget* = 256'i64 shl 20
    ## Most bytes of files in hand at once. The first file not yet taken runs whatever its size.
    ## Set only by tests.

type
  GatherFile* = object
    path*: string
    size*: int64

  GatherAsk* = object
    ## What the job needs, copied on the UI thread.
    line*, point*: float64           ## the receiver station
    component*: int                  ## the component of its traces
    files*: seq[GatherFile]          ## the listed seismic files, in the Files window's order
    survey*: ptr SurveyGeometry
      ## the project's survey (nil: none), kept alive by the caller until the work is back
    options*: JoinOptions
    moves*: StationMoves
    tableOnly*: bool
    cacheDir*: string
    maxTraces, maxBytes, budget: int ## the limits, as `gatherWork` found them

  GatherTrace = object
    keys: TraceKeys
    samples: seq[float32]

  GatherPart = object
    ## What reading one file came to. `skip`: why it gave nothing, "" when it gave traces.
    skip: string
    traces: seq[GatherTrace]

  GatherItems = object
    ask: ptr GatherAsk

  GatherRow = object
    keys: TraceKeys
    samples: seq[float32]
    file: int32 ## index in `Collected.paths`
    order: int  ## the place in file order

  Collected = object
    ## What the job thread has taken so far.
    rows: seq[GatherRow]
    paths: seq[string]
    intervalUs: float64
    length: int             ## samples per trace; 0 until a trace was taken
    absent, unreadable: int ## files with no trace at the station, files that could not be read
    others: seq[string]     ## sentences of the files left out for another reason
    padded, cut, mismatched, notAdded: int
    capped: string
    maxTraces: int
    maxBytes: int64

static:
  doAssert plainData(GatherPart)

func numText(x: float64): string =
  if x == floor(x) and abs(x) < 1e9: $int64(x) else: $x

func stationText*(line, point: float64): string =
  ## `line`/`point` as the user writes a station.
  numText(line) & "/" & numText(point)

func gatherTitle*(line, point: float64): string =
  ## The title of the gather of station `line`/`point`: not a source file's name.
  "Receiver gather " & stationText(line, point)

func plural(n: int; word: string): string = $n & " " & word & (if n == 1: "" else: "s")

func sameNumber(a, b: float64): bool {.inline.} = abs(a - b) < 0.005

proc openKeys(path, cacheDir: string; it: ItemContext): Session =
  ## The file at `path`, keys only, closed by the caller. A current index cache in `cacheDir`
  ## is read instead of walking the headers; a walk saves one (a failed save is ignored).
  fs.unmappedFail(path)
  let index = indexCacheFile(cacheDir, path)
  let cached = index.len > 0 and fs.fileExists(index)
  let progress: Progress = proc (done, total: int64): bool {.gcsafe, raises: [].} =
    try: fs.mappedRead(path)
    except CatchableError: discard
    it.progress(done, total)
  result = openSession(path, progress, if cached: index else: "")
  if index.len == 0 or result.file.kind == skUnknown or result.file.fromCache or
      result.file.demuxPath.len > 0: return
  try:
    fs.createDir(cacheDir)
    {.cast(gcsafe).}:
      result.file.saveIndex(index)
  except ValueError, IOError, OSError:
    discard

proc readStation(it: ItemContext; a: ptr GatherItems; k: int): GatherPart {.nimcall, gcsafe.} =
  ## Opens file `k`, joins the survey and the moves to its keys in memory, and reads its
  ## traces at the station. The file is closed before this returns; a cancel is raised.
  let ask = a.ask
  let (line, point, component) = (ask.line, ask.point, ask.component)
  let path = ask.files[k].path
  var s: Session = nil
  try:
    {.cast(gcsafe).}:
      s = openKeys(path, ask.cacheDir, it)
      if s.file.kind == skUnknown: result.skip = "not a SEG-Y, SEG-D or SEG-2 file"
      elif s.file.index.keys.len == 0: result.skip = "has no trace keys"
      else:
        let file = s.filePtr
        let progress = proc (done, total: int): bool {.gcsafe, raises: [].} = not it.cancelled
        discard joinOwnFile(file, ask.survey, ask.options, ask.moves, ask.tableOnly, progress)
        let n = file[].len
        var keys = newSeq[TraceKeys](min(n, KeysChunk))
        var at: seq[int] = @[]
        var t = 0
        while t < n:
          let m = min(keys.len, n - t)
          file[].traceKeysInto(t ..< t + m, keys.toOpenArray(0, m - 1))
          for j in 0 ..< m:
            if (t + j) mod CancelEvery == 0: it.checkCancelled()
            template key: untyped = keys[j]
            if key.status != tsAuxiliary and sameNumber(key.rcvLine, line) and
                sameNumber(key.rcvPoint, point) and int(key.component) == component:
              at.add t + j
              result.traces.add GatherTrace(keys: key)
          t += m
        for i, trace in at:
          it.checkCancelled()
          let count = int(file[].index.entries[trace].numSamples)
          var log: DiagLog
          let block1 = file[].readTraces([trace], 0 ..< count, log)
          if log.hasErrors:
            result = GatherPart(skip: "a trace could not be read")
            break
          result.traces[i].samples = newSeq[float32](count)
          if count > 0:
            copyMem(addr result.traces[i].samples[0], rowBlock(block1).rowPtr(0),
              count * sizeof(float32))
  except SegCancelledError:
    raise newException(JobCancelledError, "cancelled")
  except JobCancelledError:
    raise
  except CatchableError as e:
    result = GatherPart(skip: if e.msg.len > 0: e.msg else: $e.name)
  finally:
    s = nil
    clearCycleRoots()

func fits(c: Collected; length: int): bool =
  ## Whether one more trace of `length` samples is within both limits.
  c.rows.len < c.maxTraces and int64(c.rows.len + 1) * int64(length) * 4 <= c.maxBytes

proc add(c: var Collected; path: string; part: sink GatherPart) =
  ## Takes the traces file `path` gave, in file order.
  if part.skip.len > 0:
    inc c.unreadable
    c.others.add path.extractFilename & " (" & part.skip & ")"
  elif part.traces.len == 0: inc c.absent
  elif c.capped.len > 0: inc c.notAdded
  else:
    var named = false
    let file = int32(c.paths.len)
    var added = 0
    for t in part.traces.mitems:
      if c.length == 0 and t.samples.len > 0:
        c.length = t.samples.len
        c.intervalUs = t.keys.intervalUs
      if c.length == 0 or t.samples.len == 0:
        inc c.mismatched # a trace with no samples says nothing
        named = true
      elif not (t.keys.intervalUs == c.intervalUs):
        inc c.mismatched
        if not named:
          c.others.add path.extractFilename & " (sample interval " &
            (if t.keys.intervalUs.isNaN: "not given" else: numText(t.keys.intervalUs / 1000) &
            " ms") & ", the gather's is " & numText(c.intervalUs / 1000) & " ms)"
        named = true
      elif not c.fits(c.length):
        c.capped = if c.rows.len >= c.maxTraces: "the limit of " & plural(c.maxTraces, "trace")
                   else: "the memory limit of " & formatSize(c.maxBytes, includeSpace = true) & " of samples"
        inc c.notAdded
        break
      else:
        if t.samples.len < c.length:
          inc c.padded
          t.samples.setLen c.length
        elif t.samples.len > c.length:
          inc c.cut
          t.samples.setLen c.length
        c.rows.add GatherRow(keys: t.keys, samples: move t.samples, file: file,
          order: c.rows.len)
        inc added
    if added > 0: c.paths.add path

func sentence(c: Collected; ask: GatherAsk; kept, listed: int): string =
  ## What the gather came to, in plain words.
  let station = "receiver station " & stationText(ask.line, ask.point) &
    " (component " & $ask.component & ")"
  if kept == 0:
    result = "No listed file holds " & station & "."
  else:
    result = "Gathered " & plural(kept, "trace") & " of " & station & " from " &
      plural(c.paths.len, "file") & " of the " & $listed & " listed."
  if c.absent > 0:
    result.add " " & plural(c.absent, "file") & (if c.absent == 1: " has" else: " have") &
      " no trace at the station."
  if c.others.len > 0:
    result.add " Left out: "
    for i, o in c.others:
      if i < MaxNamed: result.add (if i > 0: ", " else: "") & o
    if c.others.len > MaxNamed:
      result.add ", and " & plural(c.others.len - MaxNamed, "more file") & "."
    else: result.add "."
  if c.padded > 0 or c.cut > 0:
    result.add " The gather has " & plural(c.length, "sample") & " per trace, as the first " &
      "file has:"
    if c.padded > 0: result.add " " & plural(c.padded, "shorter trace") & " padded with zeros"
    if c.padded > 0 and c.cut > 0: result.add ","
    if c.cut > 0: result.add " " & plural(c.cut, "longer trace") & " cut"
    result.add "."
  if c.capped.len > 0:
    result.add " Stopped at " & c.capped & ": the traces of " &
      plural(c.notAdded, "later file") & " (or the rest of one) were not added."

func compareRows(a, b: GatherRow): int =
  ## Record time first (a trace with none last), then the source station, then file order.
  template timeOf(r: GatherRow): float64 =
    (if r.keys.time.isNaN: Inf else: r.keys.time)
  result = cmp(timeOf(a), timeOf(b))
  if result == 0: result = cmp(a.keys.srcLine, b.keys.srcLine)
  if result == 0: result = cmp(a.keys.srcPoint, b.keys.srcPoint)
  if result == 0: result = cmp(a.order, b.order)

proc buildSession(c: var Collected; ask: GatherAsk): Session =
  ## The gather's traces as an in-memory SEG-Y file, opened and marked as a gather.
  let title = gatherTitle(ask.line, ask.point)
  let key = freshGatherKey(title)
  c.rows.sort(compareRows)
  var w = openSeismicWriterBytes(SegyOutputOptions(traceSorting: 6), key)
  for r in c.rows:
    var k = r.keys
    k.intervalUs = c.intervalUs
    k.ensemble = ask.point # one ensemble: the receiver's
    w.writeTrace(k, r.samples)
  var bytes = w.finishBytes()
  let size = int64(bytes.len)
  var opened = openSeismicBytes(move bytes, key, keys = true)
  # What the SEG-Y headers cannot hold (stations, the receiver's index) is the source traces'
  # own: set on the keys the viewer reads.
  for i, r in c.rows:
    var k = r.keys
    k.intervalUs = c.intervalUs
    k.ensemble = ask.point
    opened.mindex.keys[i] = k
  result = newSession(key, opened, size, getTime())
  var fileOf = newSeq[int32](c.rows.len)
  for i, r in c.rows: fileOf[i] = r.file
  result.asGathered(title, c.paths, fileOf)

proc gatherWork*(ask: sink GatherAsk; to: Poster): JobWork =
  ## The work of a job that collects the traces at `ask`'s station from `ask`'s files and
  ## posts the gather (`mkGathered`), or only the sentence when there is none. A cancel raises
  ## `JobCancelledError` and posts nothing. Nothing is written, and no source file is opened
  ## for writing.
  var mine = ask
  mine.maxTraces = gatherTraces
  mine.maxBytes = gatherBytes
  mine.budget = int(gatherReadBudget)
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    var args = GatherItems(ask: addr mine)
    let total = mine.files.len
    var c = Collected(maxTraces: mine.maxTraces, maxBytes: mine.maxBytes)
    var sizes = newSeq[int64](total)
    for i, f in mine.files: sizes[i] = max(0'i64, f.size)
    ctx.setPhase "reading " & plural(total, "file")
    proc take(k: int; outcome: sink ItemOutcome[GatherPart]) {.closure, gcsafe.} =
      ctx.checkCancelled()
      let path = mine.files[k].path
      ctx.setPhase "reading " & path.extractFilename
      if outcome.ok: c.add(path, move outcome.value)
      elif outcome.failure.cancelled: raise newException(JobCancelledError, "cancelled")
      else:
        inc c.unreadable
        c.others.add path.extractFilename & " (" & (if outcome.failure.msg.len > 0:
          outcome.failure.msg else: outcome.failure.name) & ")"
    let ran = ctx.parallelItems(total, addr args, readStation, take,
      ItemOptions(cost: sizes, budget: int64(mine.budget)))
    if ran.taken < total: raise newException(JobCancelledError, "cancelled")
    let kept = c.rows.len
    let said = sentence(c, mine, kept, total)
    var made: Session = nil
    if kept > 0:
      ctx.setPhase "making the gather"
      {.cast(gcsafe).}:
        made = buildSession(c, mine)
    ctx.checkCancelled()
    clearCycleRoots() # the UI thread may release the file's objects at once
    if not ctx.commit(): raise newException(JobCancelledError, "cancelled")
    to.post Msg(job: ctx.id, kind: mkGathered, gathered: move made, gatherSaid: said)

func gatherSpec*(ask: GatherAsk): JobSpec =
  ## The job's spec: it reads the listed files, so the files' closing waits for it.
  result = JobSpec(title: gatherTitle(ask.line, ask.point), lane: jlBackground)
  for f in ask.files: result.reads.add f.path
