## A slice that correlates each shot's record with a stored sweep as it cuts it, in one
## step, equals the two steps it replaces: the slice without the option, then the Output
## write with Correlated on that file.
##
## The recording is built here: three components, four source traces each of 3000 samples
## at 2 ms (each follows the one before except the last, which starts one segment later, so
## 3000 samples are missing between them). A sweep-shaped arrival is added to each component
## after each shot, at a known sample (200 + 30 per component after the window's start),
## so the correlated record peaks at that lag.
##
## For SEG-Y and SEG-D output, each trace of the one-step file is compared with the
## two-step file: every sample bit for bit, the sample count, the interval, the delay and
## time of the trace, and every byte of its headers. Cases: a window across the junction of
## two source traces, a window with a gap inside it (the sweep straddles the gap), a window
## past the recording's end (zero-padded before correlation), three components, a folder of
## two recordings, a SEG-D recording (its headers are not carried), the refusals (a pilot is
## not a stored sweep, the record not longer than the sweep, another sample interval, a
## missing sweep file), a cancel that leaves no part file.
##
## Each was seen to fail with a deliberate fault: the correlation call left out of the cutter
## (the samples differed at trace 0: "0.0 vs -7.916242e-9"); the correlated flag left out of
## the SEG-Y write ("correlated flag of trace 0"); the refusal of a record not longer than
## the sweep left out (the library's own sentence came back, not the one asserted).

import std/[assertions, math, options, os, sequtils, strutils, sets]
import parseSEG
import parseSEG/model/traceindex
import processSEG
import viewSEG/core/[cutcorrelate, cutfolderjobs, cutgather, cutgatherjobs, filesystem, jobs,
  edits, outputjobs, references, shotlog, threads]
import viewSEG/view/cutfolderwords
import utils/waiting

const
  BaseUs = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC
  DtUs = 2000'i64
  SegLen = 3000
  Starts = [0, 3000, 6000, 12000]    ## first sample of each source trace; 9000..11999 is missing
  Total = 15000
  Comps = 3
  SweepLen = 100
  RecordSamples = 600
  Listen = RecordSamples - SweepLen
  LengthMs = 1200.0
  Delay = 200                        ## the arrival's lag after the window's start; 30 more per component
  ShotSamples = [500, 2800, 8700, 12400, 14700]
    ## 0 and 3 lie in one source trace, 1 crosses the junction, 2 has the gap inside it,
    ## 4 runs past the end
  Files = [101, 102, 103, 104, 105]

func delayOf(comp: int): int =
  Delay + 30 * comp

func covered(k: int): bool =
  for s in Starts:
    if k >= s and k < s + SegLen: return true

proc sweepSamples(): seq[float32] =
  linearSweep(8.0, 80.0, float64(SweepLen) * 2.0, 2.0).sweepSamples(float32)

proc series(comp: int; sweep: seq[float32]): seq[float32] =
  ## What the recording holds of component `comp` over the whole time, gaps as zeros.
  result = newSeq[float32](Total)
  for ws in ShotSamples:
    for j in 0 ..< sweep.len:
      let at = ws + delayOf(comp) + j
      if at < Total: result[at] += sweep[j] * float32(comp + 1)
  for k in 0 ..< Total:
    if not covered(k): result[k] = 0

proc makeRecording(path: string; sweep: seq[float32]; segd = false; offsetSamples = 0) =
  let data = (0 ..< Comps).toSeq.mapIt(series(it, sweep))
  var segy = SegyOutputOptions(traceSorting: 1, measurementSystem: 1)
  var w =
    if segd: openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
      numSamples: SegLen))
    else: openSeismicWriter(path, segy)
  for seg in 0 .. 3:
    for comp in 0 ..< Comps:
      var k = initTraceKeys()
      k.status = tsLive
      k.record = float64(seg + 1)
      k.channel = float64(comp + 11)
      k.component = uint8(comp + 1)
      k.intervalUs = 2000
      k.t0Ms = 0
      k.time = float64(BaseUs div 1_000_000) + float64(Starts[seg] + offsetSamples) * 0.002
      k.rcvLine = 1
      k.rcvPoint = 7
      w.writeTrace(k, data[comp][Starts[seg] ..< Starts[seg] + SegLen])
  discard w.close()

proc logOf(files: openArray[int]; samples: openArray[int]): ShotView =
  var text = ""
  for i in 0 ..< files.len:
    text.add $files[i] & "," & $(BaseUs + int64(samples[i]) * DtUs) & "\n"
  var m = initShotLogMap()
  m.hasHeader = false
  m.roles = @[crFileNumber, crTime]
  m.dateTimePattern = EpochMicros
  shots(parseShotLog(text, m), m)

proc samplesOf(f: SeismicFile; trace: int): seq[float32] =
  let x = f.readTraces(trace .. trace)
  result.setLen x.shape[1]
  for j in 0 ..< result.len: result[j] = x[0, j]

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

type Ran = tuple[st: JobState; res: CutResult; error: string]

proc runCut(jobs: Jobs; f: var SeismicFile; source, dest: string; shots: CutShots;
    opts: CutOptions): Ran =
  let sink = CutSink()
  let id = jobs.submit(cutGatherSpec(source, dest),
    cutGatherWork(addr f, source, dest, shots, opts, sink))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}), "the cut did not end"
  (jobs.state(id), sink.result, jobs.info(id).get.error)

proc runOutput(jobs: Jobs; f: var SeismicFile; source, dest: string; opts: OutputOptions):
    tuple[st: JobState; wrote: OutputResult; error: string] =
  let sink = OutputSink()
  let id = jobs.submit(outputSpec(source, dest),
    outputWork(addr f, source, dest, opts, FileEdits(), @[source], sink))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the write did not end"
  (jobs.state(id), sink.result, jobs.info(id).get.error)

proc traceHeaders(path: string): seq[string] =
  ## Each trace's header bytes (the extensions with them), as the file holds them.
  var f = openSeismic(path, keys = true)
  defer: f.close()
  let bytes = readFile(path)
  for t in 0 ..< f.len:
    let e = f.traceEntry(t)
    result.add bytes[int(e.offset) ..< int(e.offset) + int(e.headerBytes)]

proc differing(a, b: string): seq[int] =
  ## The positions at which two strings differ (the shorter one's end counts).
  for i in 0 ..< max(a.len, b.len):
    if i >= a.len or i >= b.len or a[i] != b[i]: result.add i

proc same(one, two: string; segy: bool; traces, listen: int; what: string) =
  ## Every trace of `one` is `two`'s, bit for bit, with the same counts and headers.
  var a = openSeismic(one, keys = true)
  var b = openSeismic(two, keys = true)
  defer:
    a.close()
    b.close()
  doAssert a.len == traces and b.len == traces, what & ": " & $a.len & " and " & $b.len &
    " traces, not " & $traces
  for t in 0 ..< traces:
    let x = samplesOf(a, t)
    let y = samplesOf(b, t)
    doAssert x.len == listen and y.len == listen, what & " trace " & $t & ": " & $x.len &
      " and " & $y.len & " samples, not " & $listen
    for j in 0 ..< x.len:
      doAssert cast[uint32](x[j]) == cast[uint32](y[j]), what & " trace " & $t & " sample " &
        $j & ": " & $x[j] & " vs " & $y[j]
    doAssert int(a.traceEntry(t).numSamples) == listen and
      int(b.traceEntry(t).numSamples) == listen, what & " trace " & $t & " header count"
    let ka = a.traceKeys(t)
    let kb = b.traceKeys(t)
    doAssert ka.intervalUs == kb.intervalUs and ka.intervalUs == 2000.0, what & " interval"
    doAssert ka.t0Ms == kb.t0Ms, what & " t0 " & $ka.t0Ms & " vs " & $kb.t0Ms
    doAssert ka.time == kb.time, what & " time " & $ka.time & " vs " & $kb.time
    doAssert ka.record == kb.record and ka.channel == kb.channel, what & " numbers"
    doAssert ka.status == kb.status and ka.component == kb.component, what & " status"
    for (x, y) in [(ka.srcX, kb.srcX), (ka.srcY, kb.srcY), (ka.srcLine, kb.srcLine),
        (ka.srcPoint, kb.srcPoint), (ka.rcvLine, kb.rcvLine), (ka.rcvPoint, kb.rcvPoint),
        (ka.rcvX, kb.rcvX), (ka.rcvY, kb.rcvY)]:
      doAssert x == y or (x.isNaN and y.isNaN), what & " position " & $x & " vs " & $y
    if segy:
      let fa = a.traceField(t, "trace.correlated")
      doAssert fa.kind == fvInt and fa.intVal == 2, what & " correlated flag of trace " & $t
  block fileLevel:
    # Before the first trace the files differ only by the one line the one-step file adds to
    # the provenance. SEG-Y: card 4 of the text header (bytes 240..319). SEG-D: the external
    # header is three 32-byte blocks longer in each record, and the general headers that say
    # how long it is (bytes 31, 79, 87, 90 and 91) say so.
    let ba = readFile(one)
    let bb = readFile(two)
    let first = int(a.traceEntry(0).offset)
    let firstTwo = int(b.traceEntry(0).offset)
    var d: seq[int] = @[]
    for i in 0 ..< min(first, firstTwo):
      if ba[i] != bb[i]: d.add i
    if segy:
      doAssert first == firstTwo and ba.len == bb.len, what & " sizes"
      doAssert d.len > 0 and d.allIt(it in 240 .. 319), what & " text header bytes " & $d
    else:
      doAssert d == @[31, 79, 87, 90, 91], what & " general header bytes " & $d
      doAssert first - firstTwo == 96 and ba.len - bb.len == 96 * 5, what & " sizes " &
        $(first - firstTwo) & " " & $(ba.len - bb.len)
  let ha = traceHeaders(one)
  let hb = traceHeaders(two)
  var report = ""
  for t in 0 ..< traces:
    let d = differing(ha[t], hb[t])
    if d.len > 0: report.add " trace " & $t & " bytes " & $d & ";"
  doAssert report.len == 0, what & ": the trace headers differ:" & report

proc peakAt(x: seq[float32]): int =
  for j in 0 ..< x.len:
    if abs(x[j]) > abs(x[result]): result = j

proc main*() =
  markWorkerThread() # the sweep file is written by a worker's call
  let dir = getTempDir() / ("viewseg-cutcorr-" & $getCurrentProcessId())
  removeDir(dir)
  let outDir = dir / "out"
  createDir(dir / "rec")
  createDir(outDir)
  let twoDir = dir / "two" ## the Output write goes to another folder than its source
  createDir(twoDir)
  defer: removeDir(dir)
  let sweep = sweepSamples()
  doAssert sweep.len == SweepLen
  let sweepPath = dir / "sweep.sgy"
  writeReferenceFile(sweepPath, "test sweep", 2000.0, sweep, ReferenceOrigin(generated: false))
  let recPath = dir / "rec" / "rec.sgy"
  makeRecording(recPath, sweep)
  var src = openSeismic(recPath, keys = true)
  defer: src.close()
  let jobs = initJobs()
  let view = logOf(Files, ShotSamples)
  let shots = shotsInTime(view.rows)
  doAssert shots.shots.len == 5

  proc options(standard: CutStandard; one: bool): CutOptions =
    result = initCutOptions(LengthMs, 0.0, saNearest, standard)
    if one:
      result.sweepPath = sweepPath
      result.sweepName = "test sweep"

  for standard in [csSegy, csSegdRev3]:
    let segy = standard == csSegy
    let ext = standardExt(standard)
    let tag = if segy: "segy" else: "segd"
    block one_step_equals_two_steps:
      let one = outDir / ("one-" & tag & ext)
      let got = runCut(jobs, src, recPath, one, shots, options(standard, true))
      doAssert got.st == jsDone, got.error & " / " & got.res.reason
      doAssert got.res.ok and got.res.shotsWritten == 5 and got.res.components == 3, $got.res
      doAssert got.res.samples == Listen and got.res.correlatedWith == "test sweep", $got.res
      doAssert not got.res.carried
      doAssert got.res.gapSamples > 0, "the gap inside shot 2 and the end of shot 4 are counted"
      doAssert got.res.bytesWritten == getFileSize(one)
      let plain = outDir / ("plain-" & tag & ext)
      let cut = runCut(jobs, src, recPath, plain, shots, options(standard, false))
      doAssert cut.st == jsDone, cut.error
      doAssert cut.res.samples == RecordSamples
      var sliced = openSeismic(plain, keys = true)
      defer: sliced.close()
      let two = twoDir / ("two-" & tag & ext)
      let corr = OutputCorrelation(reference: sweep, referenceDtMs: 2.0)
      let wrote = runOutput(jobs, sliced, plain, two, OutputOptions(
        format: (if segy: ofSegy else: ofSegd), correlation: some(corr)))
      doAssert wrote.st == jsDone, wrote.error & " / " & wrote.wrote.reason
      same(one, two, segy, 15, Listen, tag)

      # the result is right, not only equal: the peak of each component sits at its arrival
      var f = openSeismic(one, keys = true)
      defer: f.close()
      for s in [0, 1, 3]:
        for c in 0 ..< Comps:
          doAssert peakAt(samplesOf(f, s * Comps + c)) == delayOf(c),
            tag & " shot " & $s & " component " & $c & " peaks at " &
            $peakAt(samplesOf(f, s * Comps + c))
      # the amplitude: an arrival of amplitude a correlates to a peak of a
      doAssert abs(samplesOf(f, 0)[delayOf(0)] - 1.0'f32) < 1e-3
      doAssert abs(samplesOf(f, 2)[delayOf(2)] - 3.0'f32) < 1e-3
      # the shot at the end: its arrival is cut off by the end of the recording
      doAssert f.len == 15

  block refusals:
    # a missing sweep file
    var missing = options(csSegy, true)
    missing.sweepPath = dir / "gone.sgy"
    let gone = runCut(jobs, src, recPath, outDir / "gone.sgy", shots, missing)
    doAssert gone.st == jsFailed and "could not be used" in gone.res.reason and
      "test sweep" in gone.res.reason, gone.res.reason
    # the record is not longer than the sweep
    var short = options(csSegy, true)
    short.recordMs = float64(SweepLen) * 2.0
    let tooShort = runCut(jobs, src, recPath, outDir / "short.sgy", shots, short)
    doAssert tooShort.st == jsFailed and "must be the sweep plus the listen time" in
      tooShort.res.reason and "200 ms" in tooShort.res.reason, tooShort.res.reason
    # another sample interval
    let slowPath = dir / "slow.sgy"
    writeReferenceFile(slowPath, "slow sweep", 4000.0, sweep, ReferenceOrigin(generated: false))
    var odd = options(csSegy, true)
    odd.sweepPath = slowPath
    odd.sweepName = "slow sweep"
    let wrongDt = runCut(jobs, src, recPath, outDir / "odd.sgy", shots, odd)
    doAssert wrongDt.st == jsFailed and "4 ms" in wrongDt.res.reason and
      "2 ms" in wrongDt.res.reason, wrongDt.res.reason
    for name in ["gone.sgy", "short.sgy", "odd.sgy"]:
      doAssert not fileExists(outDir / name)
    doAssert walkDir(outDir).toSeq.allIt(".part-" notin it.path)
    # the window's own sentences, from the facts of the archive's entry
    doAssert correlationWhy(100, 2000.0, 1200.0, 2.0) == ""
    doAssert "sweep plus the listen time" in correlationWhy(600, 2000.0, 1200.0, 2.0)
    doAssert "every 4 ms and the recording every 2 ms" in correlationWhy(100, 4000.0, 1200.0, 2.0)
    doAssert listenSamples(100, 1200.0, 2.0) == 500

  block cancel_leaves_no_part_file:
    let dest = outDir / "cancel.sgy"
    let sink = CutSink()
    var calls = 0
    let f = addr src
    let opts = options(csSegy, true)
    let id = jobs.submit(cutGatherSpec(recPath, dest), proc (ctx: JobContext) {.gcsafe.} =
      {.cast(gcsafe).}:
        cutGather(ctx, f, recPath, dest, shots, opts, sink, report =
          proc (done, total: int64): bool {.gcsafe.} =
            {.cast(gcsafe).}:
              inc calls
              calls < 3))
    doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled})
    doAssert jobs.state(id) == jsCancelled, $jobs.state(id)
    doAssert sink.result.removed and not fileExists(dest)
    doAssert walkDir(outDir).toSeq.allIt(".part-" notin it.path)

  block segd_recording_is_not_carried:
    # a SEG-D recording keeps its headers when sliced; correlated records are not its length
    let segdPath = dir / "rec" / "rec.sgd"
    makeRecording(segdPath, sweep, segd = true)
    var s = openSeismic(segdPath, keys = true)
    defer: s.close()
    let dest = outDir / "from-segd.sgd"
    let got = runCut(jobs, s, segdPath, dest, shots, options(csSegdRev3, true))
    doAssert got.st == jsDone, got.error & " / " & got.res.reason
    doAssert not got.res.carried and got.res.samples == Listen, $got.res
    doAssert got.res.lines.anyIt("not carried" in it), $got.res.lines
    var a = openSeismic(dest, keys = true)
    defer: a.close()
    var b = openSeismic(outDir / "one-segd.sgd", keys = true)
    defer: b.close()
    doAssert a.len == 15
    for t in 0 ..< 15:
      doAssert samplesOf(a, t) == samplesOf(b, t), "trace " & $t

  block folder_of_two_recordings:
    let inDir = dir / "folder-in"
    let toDir = dir / "folder-out"
    createDir(inDir)
    createDir(toDir)
    makeRecording(inDir / "a.sgy", sweep)
    makeRecording(inDir / "b.sgy", sweep)
    var opts = options(csSegy, true)
    var flight = jobs.startFolder(FolderPlan(folder: inDir, destFolder: toDir,
      rows: view.rows, opts: opts, cacheDir: dir / "cache", write: true), KnownFacts())
    doAssert waitUntil(flight.over(jobs)), "the folder job did not end"
    let (res, _) = flight.take()
    doAssert res.countWritten == 2, outcomeWords(res)
    for name in ["a", "b"]:
      let plain = outDir / ("folder-plain-" & name & ".sgy")
      var s = openSeismic(inDir / (name & ".sgy"), keys = true)
      defer: s.close()
      let cut = runCut(jobs, s, inDir / (name & ".sgy"), plain, shots, options(csSegy, false))
      doAssert cut.st == jsDone, cut.error
      var sliced = openSeismic(plain, keys = true)
      defer: sliced.close()
      let two = twoDir / ("folder-two-" & name & ".sgy")
      let wrote = runOutput(jobs, sliced, plain, two, OutputOptions(format: ofSegy,
        correlation: some(OutputCorrelation(reference: sweep, referenceDtMs: 2.0))))
      doAssert wrote.st == jsDone, wrote.error
      same(toDir / (name & "_slice.sgy"), two, true, 15, Listen, "folder " & name)

  # Broken to see it fail: the folder check ignoring the sweep (the file listed as
  # sliceable, then failing in the run), and cutGather accepting a start other than 0.
  block folder_check_says_why_a_file_cannot_be_correlated:
    let inDir = dir / "check-in"
    createDir(inDir)
    makeRecording(inDir / "a.sgy", sweep)
    var short = options(csSegy, true)
    short.recordMs = float64(SweepLen) * 2.0 # the record is the sweep: no listen time
    var flight = jobs.startFolder(FolderPlan(folder: inDir, rows: view.rows, opts: short,
      cacheDir: dir / "cache"), KnownFacts())
    doAssert waitUntil(flight.over(jobs)), "the check did not end"
    let (res, _) = flight.take()
    doAssert res.files.len == 1 and res.countSliceable == 0, outcomeWords(res)
    doAssert "the record must be the sweep plus the listen time" in res.files[0].skip,
      res.files[0].skip
    # the tick off: the same folder is sliceable
    var plain = short
    plain.sweepPath = ""
    flight = jobs.startFolder(FolderPlan(folder: inDir, rows: view.rows, opts: plain,
      cacheDir: dir / "cache"), KnownFacts())
    doAssert waitUntil(flight.over(jobs)), "the check did not end"
    let (res2, _) = flight.take()
    doAssert res2.countSliceable == 1, outcomeWords(res2)

  block a_start_other_than_zero_is_refused:
    var o = options(csSegy, true)
    o.startMs = 10.0
    let got = runCut(jobs, src, recPath, outDir / "start.sgy", shots, o)
    doAssert got.st == jsFailed and CorrelatedStartWhy in got.error & got.res.reason,
      got.error & " / " & got.res.reason
    doAssert not fileExists(outDir / "start.sgy")

  echo "tcutgathercorr ok"

when isMainModule:
  main()
