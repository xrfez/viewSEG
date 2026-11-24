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

import std/[math, options, os, random, sequtils, strutils, times]
import parseSEG
import parseSEG/model/traceindex
import processSEG
import processSEG/continuous/slice
import processSEG/core/[rows, workspace]
import cutcarry, cutfile, cutgather, filesystem, jobs, outputjobs, recordingkind, segmentclock,
    shotlog, vendormaps

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
    sourceKeysDropped*: bool
      ## SEG-Y output of shots that have a source line or a point index, which
      ## SEG-Y has no place for
    carried*: bool
      ## SEG-D from SEG-D: the output is in the source's revision, made of the
      ## source's own headers (`cutcarry`)
    sourceFormat*: int
      ## a carried output whose source samples are not IEEE float32: the source's format code
    revision*: string ## the revision of a carried output, "Rev 2.1"
    startRewritten*: int ## carried traces whose vendor start time was set to the slice's
    startMissing*: int ## carried traces with no vendor start time to set
    triggerRewritten*: int ## carried traces whose vendor trigger time was set to the slice's
    triggerLeft*: int ## carried traces with a vendor trigger time that was left as carried
    fallbackWhy*: string
      ## a SEG-D source cut into SEG-D whose headers were built from the options: why
    carryNotes*: seq[string] ## what a carried output keeps or has no place for, as sentences
    sourceXyDropped*: bool
      ## a carried Rev 2 output of shots that have source coordinates, which its
      ## headers have no place for
    shotsRefused*: int ## shots the writer refused (carried output); they are left out
    refusals*: seq[string] ## the first few reasons, with the shot's record number
    components*: int ## traces per record
    samples*: int ## samples per trace
    samplesRead*: int ## source samples decoded, each once (not shots x window)
    overlapsCompared*, overlapsMatched*, overlapsMismatched*: int
    overlapsNotRead*: int
      ## overlaps between two traces the records read whose samples could not be had
    overlapsOutside*: int
      ## overlaps with a trace no record reads: not needed, so not compared
    mismatches*: seq[string]
      ## the first few mismatching overlaps, named by source trace (from 1)
    segmentsFromHeaders*: bool ## the segments' start times were read from the trace headers
    endToEnd*: bool
      ## every trace of a component carries the same start time, so each receiver's traces were
      ## taken to follow one another end to end from the time of its first (the user said the
      ## file is continuous)
    segmentsWithoutTime*: int ## traces whose header had none (they are left out)
    skips*, missingSegments*: int ## places where whole segments were not recorded, and how many
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
  JobSpec(title: "Slice " & extractFilename(source), lane: jlBackground, reads: @[source],
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

func failureReason*(why: string; claimed, removed: bool): string =
  ## `why` as a sentence, then what became of the partial file when there was
  ## one (`claimed`).
  result = why
  if claimed:
    if result.len > 0:
      if result[^1] notin {'.', '!', '?'}: result.add '.'
      result.add ' '
    result.add (if removed: "The partial file was removed." else:
      "The partial file could not be removed.")
  elif result.len > 0 and result[^1] notin {'.', '!', '?'}:
    result.add '.'

func writeFailure*(msg: string): string =
  ## An operating-system error from the output, as a sentence.
  "Writing the file failed: " & msg & (if msg.endsWith('.'): "" else: ".")

proc abort(sink: CutSink; dest, part: string; claimed: bool; why: string; cancel: bool) =
  ## Ends the job. When `claimed`, removes only `part` (ours); `dest` is never
  ## touched.
  var removed = false
  if claimed: removed = dropOurs(part)
  let reason = failureReason(why, claimed, removed)
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
      # One block copy of the row; the check keeps the raw copy inside both buffers.
      let rowsOf = rowBlock(st.tensor)
      if count > 0:
        if count > rowsOf.cols or count > dst.len:
          raise newException(IndexDefect, "a fetch of " & $count & " samples does not fit")
        copyMem(addr dst[0], rowsOf.rowPtr(0), count * sizeof(float32))
      st.fetched += count
      result = true

func named(row: int): string =
  "source trace " & $(row + 1)

func overlapName(o: SliceOverlap): string =
  "source traces " & $(o.earlier + 1) & " and " & $(o.later + 1)

func cutLines(res: CutResult; opts: CutOptions): seq[string] =
  ## The plain sentences of the log for a finished cut.
  let standard =
    if opts.standard == csSegy: "SEG-Y"
    elif res.carried: "SEG-D"
    else: "SEG-D Rev 3"
  result.add "Sliced " & plural(res.shotsWritten, "shot", "shots") & " into " & standard &
    " records of " & plural(res.components, "trace", "traces") & ", " &
    plural(res.samples, "sample", "samples") & " each."
  if res.carried:
    result.add "The output was written in the source's revision (" & res.revision &
      ") with its headers carried: the extended header, the channel sets and each trace's " &
      "header blocks are the source's, taken from the segment that holds the first sample " &
      "of the shot's window (from the first segment the window reads when it starts in a " &
      "gap or before the recording)."
    if opts.startMs != 0:
      result.add "Each record's time is its first sample's: the shot time plus the start of " &
        $opts.startMs & " ms."
    if res.sourceFormat != 0:
      const exact = [8015, 8022, 8024, 8036, 8042, 8044]
      result.add "The source's samples are in format " & $res.sourceFormat &
        "; the output's are written as 32-bit floats (" &
        (if res.sourceFormat in exact: "no value changes" else:
          "values beyond 24 bits of precision are rounded") & ")."
    if res.startRewritten > 0 or res.triggerRewritten > 0:
      var line = "The vendor header's "
      if res.startRewritten > 0:
        line.add "start time was rewritten to the slice's in " &
          plural(res.startRewritten, "trace", "traces")
        if res.triggerRewritten > 0: line.add " and its "
      if res.triggerRewritten > 0:
        line.add "trigger time in " & plural(res.triggerRewritten, "trace", "traces")
      result.add line & "."
    if res.startMissing > 0:
      result.add plural(res.startMissing, "trace has", "traces have") &
        " no start time in its vendor header to rewrite."
    if res.triggerLeft > 0:
      result.add plural(res.triggerLeft, "trace keeps", "traces keep") &
        " the trigger time of the recording: its field is in a unit this program does not " &
        "convert, or has no unit and did not hold the start time's value."
    for n in res.carryNotes: result.add n
    if res.sourceXyDropped:
      result.add "A SEG-D Rev 2 record has no place for the source's coordinates; they are " &
        "left out."
  elif res.fallbackWhy.len > 0:
    result.add "The headers were built from the options, not carried from the source: " &
      res.fallbackWhy & "."
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
  if res.sourceKeysDropped:
    result.add "SEG-Y does not store the source line or the point index; they are left out."
  if res.overlapsCompared > 0:
    var line = "Compared " & plural(res.overlapsCompared, "overlap", "overlaps") &
      " between recording segments: " & $res.overlapsMatched & " match, " &
      $res.overlapsMismatched & " differ."
    if res.mismatches.len > 0:
      line.add " Differing: " & res.mismatches.join("; ") & "."
    result.add line
  if res.shotsRefused > 0:
    result.add plural(res.shotsRefused, "shot was", "shots were") &
      " refused by the writer and left out: " & res.refusals.join("; ") & "."
  if res.overlapsNotRead > 0:
    result.add plural(res.overlapsNotRead, "overlap was", "overlaps were") & " not compared."
  if res.overlapsOutside > 0:
    result.add plural(res.overlapsOutside, "overlap", "overlaps") &
      " between traces " & (if res.overlapsOutside == 1: "lies" else: "lie") &
      " outside every record and " &
      (if res.overlapsOutside == 1: "was" else: "were") & " not needed."
  if res.endToEnd:
    result.add "Every trace of a component carries the same start time, so each receiver's " &
      "traces were taken to follow one another end to end from the time of its first trace, " &
      "as you set the file to be continuous. If the recorder paused or lost traces, the times " &
      "are wrong: a vendor header map that names each trace's start time would give the real " &
      "ones."
  if res.segmentsFromHeaders:
    result.add "Segment times were read from the trace headers."
    if res.segmentsWithoutTime > 0:
      result.add(if res.segmentsWithoutTime == 1:
          "1 trace has no start time in its headers and was left out."
        else:
          $res.segmentsWithoutTime & " traces have no start time in their headers and " &
            "were left out.")
  if res.timingIssues > 0:
    result.add plural(res.timingIssues, "segment starts", "segments start") &
      " off the sample grid of the one before: " & res.timingNames.join("; ") & "."
  if res.skips > 0: result.add skipWords(res.skips, res.missingSegments)
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
      let recording = planRecording(file, source, dtMs, currentVendors(),
        proc () {.gcsafe.} = ctx.checkCancelled())
      # The vendor blocks are read without raising: a recording cut short reads as traces
      # without a start time, so the cut is looked for here, before the plan is judged.
      if file[].cutShort: abort(sink, dest, part, false, cutWhy(file[]), false)
      let clock = recording.clock
      let auto = describeRecording(recording, AllStarts)
      var facts = auto
      if opts.treatKind.isSome:
        facts.kind = opts.treatKind.get
        facts.forced = true
        if facts.kind == rkReceiverContinuous: facts.slicedWhy = swNone
      # forced continuous where the traces of a component all carry one start time: they follow
      # one another end to end from the first one's time
      let endToEnd = facts.forced and facts.kind == rkReceiverContinuous and
        auto.kind != rkReceiverContinuous and auto.slicedWhy == swSameStart
      let streams =
        if endToEnd: initSliceStreams(recording.meta, endToEndTimes(recording), recording.receivers)
        else: recording.streams
      let refusal = cutRefusal(facts)
      if refusal.len > 0: abort(sink, dest, part, false, refusal, false)
      let window = SliceWindow(startMs: opts.startMs, lengthMs: opts.recordMs)
      let plan = planSlices(streams, shots.shots, window, soShotRecords, opts.align)
      let comps = plan.receiverCount
      if plan.len == 0:
        abort(sink, dest, part, false, "The recording has no live trace to slice.", false)
      let numbered = recordNumbers(shots)
      var anyStation, anySourceXY, anyReceiverXY, anySourceKey = false
      for s in shots.shots:
        if not s.srcLine.isNaN or s.srcIndex != 0: anySourceKey = true
        if not (s.srcLine.isNaN or s.srcPoint.isNaN): anyStation = true
        if not (s.srcX.isNaN or s.srcY.isNaN): anySourceXY = true
      for r in 0 ..< comps:
        let k = plan.receiverKeys(r)
        if not (k.rcvX.isNaN or k.rcvY.isNaN): anyReceiverXY = true
      let rows = carryRows(plan)
      let candidate = opts.standard == csSegdRev3 and
        carryRefusal(file[], plan, rows).len == 0
      let keysBytes = estimateBytes(opts, shots.shots.len, comps, plan.samples, anyStation,
        anySourceXY, anyReceiverXY)
      var expected = if candidate: carryBytes(file[], plan, rows, shots.shots.len)
        else: keysBytes
      var res = CutResult(path: dest, shotsDropped: shots.dropped,
        duplicateTimes: shots.duplicateTimes,
        segmentsFromHeaders: clock.fromHeaders and not endToEnd, endToEnd: endToEnd,
        segmentsWithoutTime: clock.leftOut,
        skips: facts.skips, missingSegments: facts.missingSegments,
        recordsFromFileNumbers: numbered.fromFileNumber,
        pointIndexOutOfRange: shots.pointIndexOutOfRange, components: comps,
        samples: plan.samples, expectedBytes: expected,
        sourceKeysDropped: opts.standard == csSegy and anySourceKey)
      ctx.setPhase "slicing"
      if not tell(0, expected): abort(sink, dest, part, false, "Cancelled.", true)

      part = claimPart(dest)
      if part.len == 0:
        abort(sink, dest, part, false, "The destination's folder has no free name.", false)
      claimed = true
      var w: SeismicWriter
      let intervalUs = round(dtMs * 1000)
      let vendors = currentVendors()
      # The one place the way of writing is chosen. A SEG-D source cut into SEG-D is
      # written like the source, so its extended header, channel sets and trace
      # header blocks (a vendor's own among them) are kept and the revision is its
      # own; everything else, and a source the writer cannot copy (multiplexed,
      # several records, extended recording mode), builds its headers from keys.
      let why = if opts.standard == csSegdRev3: openCarry(part, file[], plan, rows, vendors, w)
        else: "the output is SEG-Y"
      let carry = why.len == 0
      if carry:
        res.carried = true
        res.revision = revisionWords(file[], plan)
        res.sourceFormat = sourceFormat(file[], plan)
        let first = plan.tracesNeeded[0]
        if sessionPositions(file[]):
          res.carryNotes.add "Survey and moved receiver positions are not written: the " &
            "output keeps the source's own headers."
        if not isRev3(file[], first):
          res.sourceXyDropped = anySourceXY
          if hasSourceHeader(file[], first):
            if not anyStation and ownSource(file[], first):
              res.carryNotes.add "The shot log has no source line or point: the records " &
                "keep the recording's own."
          elif anyStation or anySourceKey:
            res.carryNotes.add "The recording has no source header block: the shot log's " &
              "source line and point have no place in the output."
        else:
          let blocks = sourceBlocks(file[], first)
          var missing: seq[string] = @[]
          if (anyStation or anySourceKey) and not blocks.description:
            missing.add "source line and point"
          if anySourceXY and not blocks.position: missing.add "source position"
          if missing.len > 0:
            res.carryNotes.add "The recording's traces have no source description or " &
              "position block to write to: the shot's " & missing.join(" and ") &
              " have no place in the output."
      else:
        if opts.standard == csSegdRev3 and file[].kind == skSegd: res.fallbackWhy = why
        if candidate: # the writer refused the source as a template
          expected = keysBytes
          res.expectedBytes = expected
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
      var startCount = StartCount()
      var startsNoted = false
      var lastDetail = fs.now() - DetailEvery
      let total = shots.shots.len
      let perShot = expected div total
      var done = 0'i64

      for s in 0 ..< total:
        let firstUs = shots.shots[s].timeUs + int64(round(opts.startMs * 1000))
        touched.setLen 0
        var shotFailed = false
        var refusal = ""
        var started = false
        var want = CarryShot()
        if carry:
          if not file[].inMemory: fs.mappedRead(source, headers = true)
          want = carryShot(file[], plan, rows, s)
          let sh = shots.shots[s]
          # The record's time zero is its first sample's instant less the start of the
          # carried channel set, which keeps its start: a reader that adds the start finds
          # the first sample (Rev 3 counts both on the GPS clock). With sets of different
          # starts, the earliest; each Rev 3 trace's Timestamp is set to its own first sample.
          let zeroUs = if isRev3(file[], want.traces[0]):
              gpsUsToUtcUs(utcUsToGpsUs(firstUs) - want.startUs)
            else: firstUs - want.startUs
          if want.startsDiffer and not startsNoted:
            startsNoted = true
            res.carryNotes.add "The channel sets' start times differ: each record's time is " &
              "its first sample's less the earliest of them, and " &
              (if isRev3(file[], want.traces[0]):
                "each trace's own time stamp holds its first sample's time."
              else: "the traces of a set that starts later begin that much before the record's " &
                "time plus their set's start.")
          var patch = SubsetPatch(fileNumber: numbered.numbers[s], time: toPosixSeconds(zeroUs))
          if not isRev3(file[], want.traces[0]):
            patch.headers = sourceHeaders(file[], want.traces[0], sh.srcLine, sh.srcPoint,
              sh.srcIndex)
          # `startSubset` also ends the record before it. A record whose traces were all
          # written cannot fail there: each trace's count and end time are checked when it is
          # written, so a refusal here is this shot's own (its patch).
          try:
            w.startSubset(file[], want.traces, patch)
            started = true
          except SegTruncatedError as e:
            # the recording was cut short while the job runs: the job fails, not the shot
            raise newException(IOError, readProblem(e))
          except ValueError, SegFormatError:
            refusal = getCurrentExceptionMsg()
        for i in 0 ..< comps:
          let r = if carry: want.comps[i] else: i
          let trace = s * comps + r
          for pc in plan.pieces(trace):
            if pc.row >= 0 and pc.row notin touched: touched.add pc.row
          if cutOne(plan, trace, buf, fetch, dst, sliceReport, ws): shotFailed = true
          res.gapSamples += sliceReport.gapSamples(trace)
          res.failedSamples += sliceReport.failedSamples(trace)
          if carry:
            if refusal.len == 0:
              let source = want.traces[i]
              var k = plan.sliceKeys(trace)
              k.record = float64(numbered.numbers[s])
              k.channel = float64(r + 1)
              var over = traceOverrides(file[], source, want.ordinals[i], firstUs, vendors,
                clock.fromHeaders, plan.gapSamples(trace) >= plan.samples,
                startCount)
              try:
                if isRev3(file[], source) and hasSourcePlace(k):
                  # the receiver stays the source's own, whatever the session holds
                  k.rcvLine = NaN
                  k.rcvPoint = NaN
                  k.rcvIndex = 0
                  k.rcvX = NaN
                  k.rcvY = NaN
                  k.rcvZ = NaN
                  w.writeTrace(file[], source, dst, k, over, SourceFields)
                else:
                  w.writeTrace(file[], source, dst, over)
              except SegTruncatedError as e:
                raise newException(IOError, readProblem(e))
              except ValueError, SegFormatError:
                # a format refusal is the shot's, like a caller error; an IOError is not
                refusal = getCurrentExceptionMsg()
                if started: w.abandonRecord()
          else:
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
            w.writeTrace(k, dst, channelType = sctSeismic)
        if shotFailed: inc res.shotsWithFailures
        discard settleShot(plan, buf, fetch, sliceReport, touched, s)
        if refusal.len > 0:
          inc res.shotsRefused
          if res.refusals.len < NamedMax:
            res.refusals.add "record " & $numbered.numbers[s] & ": " & refusal
        else:
          inc res.shotsWritten
        done = perShot * int64(s + 1)
        if not tell(done, expected): abort(sink, dest, part, claimed, "Cancelled.", true)
        let now = fs.now()
        if now - lastDetail >= DetailEvery:
          lastDetail = now
          ctx.setDetail $(s + 1) & " of " & $total & " shots"
      ctx.setDetail ""
      if carry and res.shotsWritten == 0:
        abort(sink, dest, part, claimed, "The writer refused every shot: " &
          res.refusals.join("; ") & ".", false)
      discard checkOverlaps(plan, buf, fetch, sliceReport, final = true)
      res.samplesRead = st.fetched
      res.startRewritten = startCount.rewritten
      res.startMissing = startCount.missing
      res.triggerRewritten = startCount.trigger
      res.triggerLeft = startCount.triggerLeft
      let log = w.close()
      res.bytesWritten = try: fs.getFileSize(part) except OSError: expected
      for i, o in plan.overlaps:
        case sliceReport.overlapCheck(i).status
        of osNotRead:
          if plan.readsRow(o.earlier) and plan.readsRow(o.later): inc res.overlapsNotRead
          else: inc res.overlapsOutside
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
      let ownWords = res.carryNotes.anyIt("no place in the output" in it)
      for d in log:
        # The writer names the part file, which is gone by now.
        var line = ($d).replace(part, extractFilename(dest))
        if carry:
          # a carried output's geometry report names the source recording; the sentence
          # about the output's own headers says it already
          if not (ownWords and "not written in" in line):
            res.lines.add line.replace(file[].path, "the recording")
        else: res.lines.add line
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
    elif sink == nil and claimed:
      discard dropOurs(part)
    raise
  except SegTruncatedError as e:
    # a header read of the recording found it cut short (the carried headers among them)
    if sink != nil and sink.result.reason.len == 0:
      abort(sink, dest, part, claimed, readProblem(e), false)
    elif sink == nil and claimed:
      discard dropOurs(part)
    raise
  except OSError as e:
    if sink != nil and sink.result.reason.len == 0:
      abort(sink, dest, part, claimed, writeFailure(e.msg), false)
    elif sink == nil and claimed:
      discard dropOurs(part)
    raise
  except CatchableError as e:
    if sink != nil and sink.result.reason.len == 0:
      abort(sink, dest, part, claimed, e.msg, false)
    elif sink == nil and claimed:
      discard dropOurs(part)
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
