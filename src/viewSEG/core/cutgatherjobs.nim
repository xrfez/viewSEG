## Cuts one continuous recording into one record per shot and writes it to a
## real file. A background job (`cutGatherWork`): the source is never
## modified, and only its sample windows are read, one source trace at a
## time, through the sliding buffer of `cutgather` (a sample is decoded once,
## however many shot windows cover it).
##
## The output has one record per shot. The record holds the recording's
## components (the receivers of the plan) as its traces, channel 1 to the
## number of components. The record number is the shot's file number when
## every shot has a usable one that increases in time order, else 1 to N in
## time order; the result says which. The output is SEG-D Rev 3 (IEEE
## float32) or SEG-Y, as `CutOptions.standard` says.
##
## Each written trace has the keys of the plan (`sliceKeys`) with the record
## and channel above. Its time is the instant of its first sample, recorded as
## such, so the SEG-D header's time zero is the shot instant to the
## microsecond. A point index that does not fit the writer is written as 0
## and counted.
##
## The plan is made once for the run. One thread does everything: the job's
## own. Shots are cut in time order; after each shot every overlap between
## recording segments that can be compared is compared and the buffer drops
## the samples no later shot reads.
##
## An existing destination is refused before any work. The writer is given a
## part file beside the destination (`<name>.part-<random>`, created
## exclusively so it is ours); `fs.moveNoReplace` moves it onto the
## destination at the end. A cancel or a failure removes only the part file
## (and the writer's own temporary file). A read that fails leaves its piece
## as zeros, and the result counts the samples and the shots affected; a
## source cut short while it is open fails the job, since the output would
## look complete.
##
## Progress is in bytes: the writer reports none, so the bytes of a shot are
## counted from the size estimate as the shot is written, and the result has
## the file's size at the end.

import std/[math, options, os, random, strutils, times]
import parseSEG
import parseSEG/model/traceindex
import processSEG
import processSEG/continuous/slice
import processSEG/core/workspace
import cutfile, cutgather, filesystem, jobs, outputjobs, shotlog

const
  NamedMax* = 5 ## how many overlaps and timing issues the result names
  DetailEvery = initDuration(milliseconds = 100)

type
  CutResult* = object
    ## What a cut found. Filled when the job ends, including when it fails or
    ## is cancelled (then only `path`, `reason` and `removed` are set).
    ok*: bool
    path*, reason*: string
    removed*: bool ## the partial file of ours was removed
    shotsWritten*: int
    shotsDropped*: int ## rows of the log without a time
    duplicateTimes*: int ## shots with the time of the shot before them (kept)
    recordsFromFileNumbers*: bool
      ## true: the record numbers are the shots' file numbers; false: 1 to N
    pointIndexOutOfRange*: int
      ## shots whose point index does not fit the writer (written as 0)
    components*: int ## traces per record
    samples*: int ## samples per trace
    samplesRead*: int ## source samples decoded, each once (not shots x window)
    overlapsCompared*, overlapsMatched*, overlapsMismatched*: int
    overlapsNotRead*: int ## overlaps whose samples could not be had
    mismatches*: seq[string]
      ## the first few mismatching overlaps, named by source trace (from 1)
    timingIssues*: int ## segments off the previous segment's sample grid
    timingNames*: seq[string] ## the first few, named by source trace (from 1)
    gapSamples*: int ## output samples no segment covers, over every trace
    failedSamples*: int ## output samples of pieces that could not be read
    shotsWithFailures*: int
    bytesWritten*, expectedBytes*: int64
    lines*: seq[string] ## plain sentences for the log

  CutSink* = ref object
    ## Filled when the job ends. Read it after the job is no longer running.
    result*: CutResult

  FetchState = object
    ## What the buffer's callback keeps between calls.
    file: ptr SeismicFile
    source: string
    tensor: Tensor[float32] # one row of `width` samples, reused
    width: int
    fetched: int            # samples decoded and handed over

proc cutGatherSpec*(source, dest: string): JobSpec =
  ## The job that cuts `source` into `dest`: background, reading `source`,
  ## needing `dest` to itself. The file must stay open until the job ends.
  JobSpec(title: "Cut " & extractFilename(source), lane: jlBackground, reads: @[source],
    exclusive: @[dest])

proc claimPart(dest: string): string =
  ## An empty file next to `dest`, `<dest>.part-<random>`, created exclusively
  ## so it is ours. "" when every name tried already exists.
  const hex = "0123456789abcdef"
  var rng = initRand(getTime().toUnix * 1_000_000_007 + getTime().nanosecond +
    int64(getCurrentProcessId()) * 7919)
  for attempt in 0 ..< 16:
    var name = dest & ".part-"
    for k in 0 ..< 12: name.add hex[rng.rand(15)]
    if fs.createExclusive(name): return name
  ""

proc dropOurs(part: string): bool =
  ## Removes `part` and the writer's temporary file next to it
  ## (`<part>.<random>.tmp`). Never a destination name: `part` is a file this
  ## job created. True when `part` is gone.
  if part.len == 0: return false
  result = fs.tryRemoveFile(part)
  let folder = part.parentDir
  let dir = if folder.len == 0: "." else: folder
  let prefix = extractFilename(part) & "."
  try:
    for kind, path in fs.walkDir(dir):
      if kind in {pcFile, pcLinkToFile}:
        let name = extractFilename(path)
        if name.startsWith(prefix) and name.endsWith(".tmp"):
          discard fs.tryRemoveFile(path)
  except OSError:
    discard

proc abort(sink: CutSink; dest, part: string; claimed: bool; why: string; cancel: bool) =
  ## Ends the job. When `claimed`, removes only `part` (ours); `dest` is never
  ## touched.
  var removed = false
  if claimed: removed = dropOurs(part)
  var reason = why
  if removed: reason.add " The partial file was removed."
  elif claimed: reason.add " The partial file could not be removed."
  if sink != nil:
    sink.result = CutResult(ok: false, path: dest, reason: reason, removed: removed)
  if cancel: raise newException(JobCancelledError, reason)
  raise newException(ValueError, reason)

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

proc makeFetch(st: ref FetchState): FetchProc =
  ## The buffer's callback: the sample window of one source trace, decoded
  ## alone (`readTracesInto` with a window), never the whole trace. A row of
  ## the planning view is the trace of the same number, as the view starts at
  ## trace 0. A file cut short fails the job; another failed read is `false`.
  result = proc (row, first, count: int; dst: var openArray[float32]): bool =
    let file = st.file
    if st.width != count:
      st.tensor = newTraceTensor[float32](1, count)
      st.width = count
    if not file[].inMemory: fs.mappedRead(st.source)
    var failed = 0
    try:
      failed = file[].readTracesInto(row .. row, first .. first + count - 1, st.tensor)
    except SegTruncatedError as e:
      raise newException(IOError, readProblem(e))
    if failed > 0:
      if file[].cutShort: raise newException(IOError, cutWhy(file[]))
      result = false
    else:
      for j in 0 ..< count: dst[j] = st.tensor[0, j]
      st.fetched += count
      result = true

func named(row: int): string =
  "source trace " & $(row + 1)

func overlapName(o: SliceOverlap): string =
  "source traces " & $(o.earlier + 1) & " and " & $(o.later + 1)

func cutLines(res: CutResult; opts: CutOptions): seq[string] =
  ## The plain sentences of the log for a finished cut.
  let standard = if opts.standard == csSegy: "SEG-Y" else: "SEG-D Rev 3"
  result.add "Cut " & plural(res.shotsWritten, "shot", "shots") & " into " & standard &
    " records of " & plural(res.components, "trace", "traces") & ", " &
    plural(res.samples, "sample", "samples") & " each."
  if res.recordsFromFileNumbers:
    result.add "The records are numbered by the shots' file numbers."
  else:
    result.add "The records are numbered 1 to " & $res.shotsWritten &
      " in time order: the file numbers are missing, not whole or not increasing."
  if res.shotsDropped > 0:
    result.add plural(res.shotsDropped, "row of the shot log has", "rows of the shot log have") &
      " no time and " & (if res.shotsDropped == 1: "was" else: "were") & " left out."
  if res.duplicateTimes > 0:
    result.add plural(res.duplicateTimes, "shot has", "shots have") &
      " the time of the shot before it (kept)."
  if res.pointIndexOutOfRange > 0:
    result.add plural(res.pointIndexOutOfRange, "shot has", "shots have") &
      " a point index the file cannot hold (written as 0)."
  if res.overlapsCompared > 0:
    var line = "Compared " & plural(res.overlapsCompared, "overlap", "overlaps") &
      " between recording segments: " & $res.overlapsMatched & " match, " &
      $res.overlapsMismatched & " differ."
    if res.mismatches.len > 0:
      line.add " Differing: " & res.mismatches.join("; ") & "."
    result.add line
  if res.overlapsNotRead > 0:
    result.add plural(res.overlapsNotRead, "overlap was", "overlaps were") & " not compared."
  if res.timingIssues > 0:
    result.add plural(res.timingIssues, "segment starts", "segments start") &
      " off the sample grid of the one before: " & res.timingNames.join("; ") & "."
  if res.gapSamples > 0:
    result.add plural(res.gapSamples, "sample", "samples") &
      " of the output fall in gaps between segments and are zeros."
  if res.failedSamples > 0:
    result.add plural(res.failedSamples, "sample", "samples") &
        " could not be read and are zeros, in " &
      plural(res.shotsWithFailures, "shot", "shots") & "."

proc cutGather*(ctx: JobContext; file: ptr SeismicFile; source, dest: string;
    shots: CutShots; opts: CutOptions; sink: CutSink; openPaths: seq[string] = @[];
    report: proc (done, total: int64): bool {.gcsafe.} = nil) =
  ## Cuts `file` (open, with its keys or able to read them) at `shots` into
  ## `dest` on `ctx`'s thread, as `cutGatherWork` does. `report` is told the
  ## bytes written of the expected and false from it cancels; nil asks the
  ## job (`ctx.progress`). `sink.result` is set before this returns, fails or
  ## is cancelled.
  if sink != nil: sink.result = CutResult(path: dest)
  var claimed = false
  var part = ""
  var tell = report
  if tell == nil:
    tell = proc (done, total: int64): bool {.gcsafe.} = ctx.progress(done, total)
  try:
    {.cast(gcsafe).}:
      var opens = openPaths
      opens.add source
      let refused = refuseDestination(dest, opens)
      if refused.len > 0: abort(sink, dest, part, false, refused, false)
      if fs.dirExists(dest):
        abort(sink, dest, part, false, "The destination is a folder.", false)
      if fs.fileExists(dest):
        abort(sink, dest, part, false, "The destination already exists.", false)
      if file == nil or not file[].isOpen:
        abort(sink, dest, part, false, "The source file is not open.", false)
      if file[].len == 0:
        abort(sink, dest, part, false, "The file has no traces.", false)
      if shots.shots.len == 0:
        abort(sink, dest, part, false, "The shot log has no shot with a time.", false)
      let dtMs = file[].sampleIntervalUs(0) / 1000
      let wrong = checkOptions(opts, dtMs)
      if wrong.len > 0: abort(sink, dest, part, false, wrong, false)
      if not file[].hasKeys:
        if not file[].inMemory: fs.mappedRead(source, headers = true)
        file[].ensureKeys()

      ctx.setPhase "planning"
      let meta = chunkMeta(file[], 0 ..< file[].len, dtMs = dtMs)
      let streams = initSliceStreams(meta)
      let window = SliceWindow(startMs: opts.startMs, lengthMs: opts.recordMs)
      let plan = planSlices(streams, shots.shots, window, soShotRecords, opts.align)
      let comps = plan.receiverCount
      if plan.len == 0:
        abort(sink, dest, part, false, "The recording has no live trace to cut.", false)
      let numbered = recordNumbers(shots)
      var anyStation, anySourceXY, anyReceiverXY = false
      for s in shots.shots:
        if not (s.srcLine.isNaN or s.srcPoint.isNaN): anyStation = true
        if not (s.srcX.isNaN or s.srcY.isNaN): anySourceXY = true
      for r in 0 ..< comps:
        let k = plan.receiverKeys(r)
        if not (k.rcvX.isNaN or k.rcvY.isNaN): anyReceiverXY = true
      let expected = estimateBytes(opts, shots.shots.len, comps, plan.samples, anyStation,
        anySourceXY, anyReceiverXY)
      var res = CutResult(path: dest, shotsDropped: shots.dropped,
        duplicateTimes: shots.duplicateTimes, recordsFromFileNumbers: numbered.fromFileNumber,
        pointIndexOutOfRange: shots.pointIndexOutOfRange, components: comps,
        samples: plan.samples, expectedBytes: expected)
      ctx.setPhase "cutting"
      if not tell(0, expected): abort(sink, dest, part, false, "Cancelled.", true)

      part = claimPart(dest)
      if part.len == 0:
        abort(sink, dest, part, false, "The destination's folder has no free name.", false)
      claimed = true
      var w: SeismicWriter
      let intervalUs = round(dtMs * 1000)
      case opts.standard
      of csSegdRev3:
        w = openSeismicWriter(part, SegdOutputOptions(sampleIntervalUs: intervalUs,
          numSamples: plan.samples))
      of csSegy:
        w = openSeismicWriter(part, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))

      var ws = initWorkspace()
      ws.reserve(sliceWorkspace(float32, plan))
      var sliceReport = initSliceReport(plan)
      prepareSliceReport(plan, sliceReport)
      var buf = initSourceBuffer()
      var st = new FetchState
      st.file = file
      st.source = source
      let fetch = makeFetch(st)
      var dst = newSeq[float32](plan.samples)
      var touched: seq[int] = @[]
      var lastDetail = fs.now() - DetailEvery
      let total = shots.shots.len
      let perShot = expected div total
      var done = 0'i64

      for s in 0 ..< total:
        let firstUs = shots.shots[s].timeUs + int64(round(opts.startMs * 1000))
        touched.setLen 0
        var shotFailed = false
        for r in 0 ..< comps:
          let trace = s * comps + r
          for pc in plan.pieces(trace):
            if pc.row >= 0 and pc.row notin touched: touched.add pc.row
          if cutOne(plan, trace, buf, fetch, dst, sliceReport, ws): shotFailed = true
          var k = plan.sliceKeys(trace)
          k.record = float64(numbered.numbers[s])
          k.channel = float64(r + 1)
          case opts.standard
          of csSegdRev3:
            k.time = toPosixSeconds(firstUs)
            k.noteRecordedTime(toFirstSample, firstUs)
          of csSegy:
            # The SEG-Y writer takes `time` as time zero.
            k.time = toPosixSeconds(shots.shots[s].timeUs)
            k.noteRecordedTime(toRecordTimeZero, shots.shots[s].timeUs)
          res.gapSamples += sliceReport.gapSamples(trace)
          res.failedSamples += sliceReport.failedSamples(trace)
          w.writeTrace(k, dst, channelType = sctSeismic)
        if shotFailed: inc res.shotsWithFailures
        discard settleShot(plan, buf, fetch, sliceReport, touched, s)
        inc res.shotsWritten
        done = perShot * int64(s + 1)
        if not tell(done, expected): abort(sink, dest, part, claimed, "Cancelled.", true)
        let now = fs.now()
        if now - lastDetail >= DetailEvery:
          lastDetail = now
          ctx.setDetail $(s + 1) & " of " & $total & " shots"
      ctx.setDetail ""
      discard checkOverlaps(plan, buf, fetch, sliceReport, final = true)
      res.samplesRead = st.fetched
      let log = w.close()
      res.bytesWritten = try: fs.getFileSize(part) except OSError: expected
      for i, o in plan.overlaps:
        case sliceReport.overlapCheck(i).status
        of osNotRead: inc res.overlapsNotRead
        of osMatch:
          inc res.overlapsCompared
          inc res.overlapsMatched
        of osMismatch:
          inc res.overlapsCompared
          inc res.overlapsMismatched
          if res.mismatches.len < NamedMax: res.mismatches.add overlapName(o)
      res.timingIssues = plan.timingIssues.len
      for issue in plan.timingIssues:
        if res.timingNames.len < NamedMax:
          res.timingNames.add named(issue.later) & " starts " & $(round(issue.residual * 100) /
            100) & " samples off the grid of " & named(issue.earlier)
      res.lines = cutLines(res, opts)
      for d in log: res.lines.add $d
      if not fs.moveNoReplace(part, dest):
        let kept = "The file appeared while writing; the output is kept as " & part & "."
        if sink != nil:
          res.ok = false
          res.path = part
          res.reason = kept
          sink.result = res
        claimed = false # the part file is the kept output, not a partial to drop
        raise newException(ValueError, kept)
      claimed = false
      res.ok = true
      if sink != nil: sink.result = res
  except JobCancelledError as e:
    if sink != nil and sink.result.reason.len == 0:
      abort(sink, dest, part, claimed, e.msg, true)
    raise
  except CatchableError as e:
    if sink != nil and sink.result.reason.len == 0:
      abort(sink, dest, part, claimed, e.msg, false)
    raise

proc cutGatherWork*(file: ptr SeismicFile; source, dest: string; shots: CutShots;
    opts: CutOptions; sink: CutSink; openPaths: seq[string] = @[]): JobWork =
  ## Cuts `file` at `shots` into `dest` on a job thread (submit it with
  ## `cutGatherSpec`; `file` stays open until the job ends). `sink.result` is
  ## set before the job returns, fails or is cancelled. A cancel is looked for
  ## at each shot; either that or a failure removes the part file and says so.
  ## The destination name is never touched.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      cutGather(ctx, file, source, dest, shots, opts, sink, openPaths)
