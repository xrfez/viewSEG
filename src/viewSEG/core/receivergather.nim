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
## Each file is read with its default reading, as the recorded fold reads it. The survey that
## places the traces is the one the recorded fold uses: the survey files loaded on the map, in
## a project and outside one (`GatherAsk.relations` and `stations`; the job lays them out as
## one geometry). A file listed twice (a linked folder among the subfolders) is read once, and
## the traces its edits kill are left out.
##
## The files are read several at a time on the item pool. An item's result is plain data (the
## traces' keys and samples, or why the file gave none); the job's own thread takes them in
## file order, so the gather is the same on any number of threads. The survey is reached
## read-only through a pointer the caller keeps alive until the work is back; no `ref` is
## shared between threads. The job thread then
##
## - sorts the traces by record time, then by source station (a stable sort: the traces of
##   one shot stay in file order);
## - takes the sample interval, the length and the start time of the first trace that has a
##   finite interval above zero: a trace of another interval, or whose start differs by a
##   part of a sample, or so far that none of its samples is in the gather's window, is left
##   out and its file named; one of another length is padded with
##   zeros or cut; one that starts a whole number of samples away is shifted onto the
##   gather's time axis; and that is said;
## - stops at `gatherTraces` traces or `gatherBytes` bytes of samples (traces times samples
##   times 4) and says so; the files after that are neither opened nor read, and a single
##   trace that alone is over the byte limit is refused before it is read;
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

import std/[algorithm, atomics, math, os, sets, strutils, times]
import parseSEG
import parseSEG/model/traceindex # (`mindex`: the keys of the new file are set below)
import processSEG/core/rows
import filejobs, filesystem, inbox, itempool, jobs, join, session, stationmoves, survey,
  surveyjobs, threads

const
  KeysChunk = 65_536 ## traces whose keys are read at a time
  CancelEvery = 4096 ## traces between cancel checks
  MaxNamed = 5       ## files named one by one in the sentence; the rest are counted
  WholeSample = 0.01 ## how far from a whole number of samples a start time may be
  AnyComponent* = -1 ## `GatherAsk.component`: every component at the station, in file order

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
    kills*: seq[int] ## the traces its edits kill, ascending

  GatherStations* = object
    ## The stations of one role of the map's survey files, with their coordinates.
    stations*: seq[Station]
    xs*, ys*: seq[float64]

  GatherAsk* = object
    ## What the job needs, copied on the UI thread.
    line*, point*: float64           ## the receiver station
    component*: int                  ## the component of its traces, or `AnyComponent`
    files*: seq[GatherFile]          ## the listed seismic files, in the Files window's order
    relations*: ptr SurveyGeometry
      ## the relation records of the map's survey (nil: no survey), kept alive by the caller
      ## until the work is back
    stations*: array[PointRole, GatherStations]
    options*: JoinOptions
    moves*: StationMoves
    cacheDir*: string
    maxTraces, maxBytes, budget: int ## the limits, as `gatherWork` found them

  GatherTrace = object
    keys: TraceKeys
    samples: seq[float32]

  GatherPart = object
    ## What reading one file came to. `skip`: why it gave nothing, "" when it gave traces.
    ## `stopped`: the file was not opened, the gather being full.
    skip: string
    stopped: bool
    killed: int
    traces: seq[GatherTrace]

  GatherItems = object
    ask: ptr GatherAsk
    survey: ptr SurveyGeometry
    full: Atomic[bool] ## set by the job thread alone, once a limit is reached

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
    t0Ms: float64           ## the time of sample 0 of the gather
    length: int             ## samples per trace; 0 until a trace was taken
    absent, unreadable: int ## files with no trace at the station, files that could not be read
    others: seq[string]     ## sentences of the files left out for another reason
    padded, cut, mismatched, notAdded, shifted, lostEnds, killed, twice: int
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
  if a.full.load(moRelaxed): # the gather is full: this file is neither opened nor read
    return GatherPart(stopped: true)
  var s: Session = nil
  try:
    {.cast(gcsafe).}:
      s = openKeys(path, ask.cacheDir, it)
      if s.file.kind == skUnknown: result.skip = "not a SEG-Y, SEG-D or SEG-2 file"
      elif s.file.index.keys.len == 0: result.skip = "has no trace keys"
      else:
        let file = s.filePtr
        let progress = proc (done, total: int): bool {.gcsafe, raises: [].} = not it.cancelled
        discard joinOwnFile(file, a.survey, ask.options, ask.moves, false, progress)
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
                sameNumber(key.rcvPoint, point) and
                (component == AnyComponent or int(key.component) == component):
              if ask.files[k].kills.binarySearch(t + j) >= 0: inc result.killed
              else:
                at.add t + j
                result.traces.add GatherTrace(keys: key)
          t += m
        var bytes = 0'i64
        for i, trace in at:
          it.checkCancelled()
          let count = int(file[].index.entries[trace].numSamples)
          if int64(count) * 4 > ask.maxBytes:
            result = GatherPart(skip: "a trace of " & plural(count, "sample") &
              " is over the memory limit of " & formatSize(ask.maxBytes, includeSpace = true))
            break
          bytes += int64(count) * 4
          if i >= ask.maxTraces or bytes > ask.maxBytes:
            result.traces.setLen i # more than the gather can take: the rest is not read
            break
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

func validInterval(us: float64): bool {.inline.} = us > 0 and us < Inf

func startMs(k: TraceKeys): float64 {.inline.} =
  ## The time of the trace's sample 0 in ms; none given counts as 0, as the reader takes it.
  if k.t0Ms.isNaN: 0.0 else: k.t0Ms

func shiftedBy(x: seq[float32]; by, length: int): seq[float32] =
  ## `x` on a time axis that starts `by` samples earlier (a trace that starts `by` samples
  ## later gets zeros in front; `by` below 0 cuts the front), `length` samples long.
  result = newSeq[float32](length)
  for j in 0 ..< length:
    let src = j - by
    if src in 0 ..< x.len: result[j] = x[src]

proc add(c: var Collected; path: string; part: sink GatherPart) =
  ## Takes the traces file `path` gave, in file order.
  if part.stopped: inc c.notAdded
  elif part.skip.len > 0:
    inc c.unreadable
    c.others.add path.extractFilename & " (" & part.skip & ")"
  else:
    c.killed += part.killed
    if part.traces.len == 0: inc c.absent
    elif c.capped.len > 0: inc c.notAdded
    else:
      var named = false
      template nameOnce(why: string) =
        inc c.mismatched
        if not named: c.others.add path.extractFilename & " (" & why & ")"
        named = true
      let file = int32(c.paths.len)
      var added = 0
      for t in part.traces.mitems:
        let usable = t.samples.len > 0 and t.keys.intervalUs.validInterval
        if c.length == 0 and usable:
          c.length = t.samples.len
          c.intervalUs = t.keys.intervalUs
          c.t0Ms = t.keys.startMs
        if t.samples.len == 0:
          inc c.mismatched # a trace with no samples says nothing
          named = true
        elif not t.keys.intervalUs.validInterval:
          nameOnce "sample interval not given"
        elif t.keys.intervalUs != c.intervalUs:
          nameOnce "sample interval " & numText(t.keys.intervalUs / 1000) &
              " ms, the gather's is " &
            numText(c.intervalUs / 1000) & " ms"
        else:
          let off = (t.keys.startMs - c.t0Ms) * 1000.0 / c.intervalUs               ## samples later
          let whole = round(off)
          if abs(off - whole) > WholeSample:
            nameOnce "starts " & numText(t.keys.startMs - c.t0Ms) &
              " ms from the gather's start, not a whole number of samples"
          elif int(whole) >= c.length or int(whole) + t.samples.len <= 0:
            nameOnce "starts outside the gather's time window"
          elif not c.fits(c.length):
            c.capped = if c.rows.len >= c.maxTraces: "the limit of " & plural(c.maxTraces, "trace")
                       else: "the memory limit of " &
                         formatSize(c.maxBytes, includeSpace = true) & " of samples"
            inc c.notAdded
            break
          else:
            if t.samples.len < c.length: inc c.padded
            elif t.samples.len > c.length: inc c.cut
            if whole != 0:
              inc c.shifted
              if whole < 0 or int(whole) + t.samples.len > c.length: inc c.lostEnds
              t.samples = t.samples.shiftedBy(int(whole), c.length)
            else: t.samples.setLen c.length
            t.keys.t0Ms = c.t0Ms
            c.rows.add GatherRow(keys: t.keys, samples: move t.samples, file: file,
              order: c.rows.len)
            inc added
      if added > 0: c.paths.add path

func sentence(c: Collected; ask: GatherAsk; kept, listed: int): string =
  ## What the gather came to, in plain words.
  let station = "receiver station " & stationText(ask.line, ask.point) &
    (if ask.component == AnyComponent: " (any component)"
      else: " (component " & $ask.component & ")")
  if kept == 0:
    result = "No listed file holds " & station & "."
  else:
    result = "Gathered " & plural(kept, "trace") & " of " & station & " from " &
      plural(c.paths.len, "file") & " of the " & $listed & " listed."
  if c.absent > 0:
    result.add " " & plural(c.absent, "file") & (if c.absent == 1: " has" else: " have") &
      " no trace at the station."
  if c.twice > 0:
    result.add " " & plural(c.twice, "file") & " listed twice " &
      (if c.twice == 1: "was" else: "were") & " read once."
  if c.killed > 0: result.add " " & plural(c.killed, "killed trace") & " left out."
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
  if c.shifted > 0:
    result.add " " & plural(c.shifted, "trace") & " start" & (if c.shifted == 1: "s" else: "") &
      " at another time and " & (if c.shifted == 1: "was" else: "were") &
      " shifted to the gather's"
    if c.lostEnds > 0:
      result.add "; " & $c.lostEnds & " of them lost samples at an end"
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

proc geometryOf(rel: ptr SurveyGeometry; stations: array[PointRole, GatherStations]):
    SurveyGeometry =
  ## The relations and the stations as one geometry, as the recorded fold lays them out.
  result = rel[]
  for r in PointRole:
    for k, st in stations[r].stations:
      if r == prSource: result.addSource(st.line, st.point, st.index, stations[r].xs[k],
        stations[r].ys[k])
      else: result.addReceiver(st.line, st.point, st.index, stations[r].xs[k], stations[r].ys[k])

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
    # a file reached twice (a linked folder among the subfolders) is read once
    ctx.setPhase "looking for files listed twice"
    var (once, seen, twice) = (newSeq[GatherFile](), initHashSet[string](), 0)
    for i, f in mine.files:
      if i mod 256 == 0: ctx.checkCancelled()
      var real = f.path
      try: real = fs.expandFilename(real)
      except OSError: discard
      if seen.containsOrIncl(real): inc twice
      else: once.add f
    mine.files = once
    var geometry = initSurveyGeometry()
    var args = GatherItems(ask: addr mine)
    if mine.relations != nil:
      ctx.setPhase "gathering the stations"
      {.cast(gcsafe).}:
        geometry = geometryOf(mine.relations, mine.stations)
      args.survey = addr geometry
    let total = mine.files.len
    var c = Collected(maxTraces: mine.maxTraces, maxBytes: mine.maxBytes, twice: twice)
    var sizes = newSeq[int64](total)
    for i, f in mine.files: sizes[i] = max(0'i64, f.size)
    ctx.setPhase "reading " & plural(total, "file")
    proc take(k: int; outcome: sink ItemOutcome[GatherPart]) {.closure, gcsafe.} =
      ctx.checkCancelled()
      let path = mine.files[k].path
      ctx.setPhase "reading " & path.extractFilename
      if outcome.ok:
        c.add(path, move outcome.value)
        if c.capped.len > 0: args.full.store(true, moRelaxed)
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
  ## The job's spec. It names no file in `reads`, as the recorded fold does: each item opens
  ## its own session, so closing or leaving a listed file never cancels the gather.
  JobSpec(title: gatherTitle(ask.line, ask.point), lane: jlBackground)
