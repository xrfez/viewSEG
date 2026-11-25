## The job that cuts a continuous recording into one record per shot and
## writes it to a real file. The recording is built here: two components, three
## source traces each of 3000 samples at 2 ms whose values are a ramp (a sample
## names its instant): they start every 2950 samples, so each repeats 50 samples
## of the one before (the files agree in one recording and differ in another),
## and the box was off for one segment after the second, so 2900 samples are
## missing there.
##
## Each was seen to fail with a deliberate fault: the window read from one
## column off ("trace 0 sample 0: 1013.0 vs 1012.0"); the record number
## not set (the writer refused it); the channel left as the source's ("channel
## of trace 0"); the origin of the time left unrecorded ("time zero of record
## 0 ... vs ..."); the overlaps never compared (0 of 4); the gaps not counted
## (0 samples); the file numbers used although they decrease ("record 101
## follows record 105"); the part file not removed on a cancel; the existing
## destination not refused first ("The file appeared while writing"); every row
## dropped after each shot ("read 122100 for a union of 8000"); a record's
## headers counted short (written 50544, estimated 50160).

import std/[assertions, atomics, math, os, sequtils, strutils, times]
import parseSEG
import parseSEG/model/traceindex
import processSEG
import processSEG/continuous/slice
import processSEG/core/[rows, workspace]
import viewSEG/core/[cutgather, cutgatherjobs, filesystem, jobs, recordtime, shotlog]
import utils/waiting

const
  BaseUs = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC
  DtUs = 2000'i64
  SegLen = 3000
  Starts = [0, 2950, 8850, 11800]    ## first sample of each source trace: step 2950, one missed
  StartMs = -100.0
  LengthMs = 2000.0
  Window = 1000                      ## LengthMs / 2 ms

type Recording = object
  path: string
  data: array[2, array[4, seq[float32]]] ## per component, per source trace

func ramp(comp, k: int): float32 =
  float32(100_000 * comp + k)

proc makeRecording(path: string; differ: bool; xy = false; z = false): Recording =
  ## The continuous file. With `differ`, the later trace of each component
  ## disagrees with the earlier one over the 50 overlapping samples.
  result.path = path
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for seg in 0 .. 3:
    for comp in 0 .. 1:
      var samples = newSeq[float32](SegLen)
      for j in 0 ..< SegLen:
        samples[j] = ramp(comp, Starts[seg] + j)
        if differ and seg in [1, 3] and j < 50: samples[j] += 1
      result.data[comp][seg] = samples
      var k = initTraceKeys()
      k.status = tsLive
      k.record = float64(seg + 1)
      k.channel = float64(comp + 11)
      k.intervalUs = 2000
      k.t0Ms = 0
      k.time = float64(BaseUs div 1_000_000) + float64(Starts[seg]) * 0.002
      k.rcvLine = 1
      k.rcvPoint = 7
      if z: k.rcvZ = 5
      if xy:
        k.rcvX = 1000 + float64(comp)
        k.rcvY = 2000
      w.writeTrace(k, samples)
  discard w.close()

func model(rec: Recording; comp, k: int): float32 =
  ## What the recording holds at sample `k`: the later trace wins; 0 in a gap
  ## or outside.
  for seg in 0 .. 3:
    if k >= Starts[seg] and k < Starts[seg] + SegLen:
      result = rec.data[comp][seg][k - Starts[seg]]

func covered(k: int): bool =
  for seg in 0 .. 3:
    if k >= Starts[seg] and k < Starts[seg] + SegLen: return true

func firstSample(shotUs: int64): int =
  ## The nearest sample to the window start, by integer arithmetic.
  let us = shotUs + int64(StartMs * 1000) - BaseUs
  int((us + DtUs div 2) div DtUs)

proc logOf(files: openArray[int]; offsetsUs: openArray[int64]): ShotView =
  ## A log of `file,UTC microseconds` rows.
  var text = ""
  for i in 0 ..< files.len:
    text.add $files[i] & "," & $(BaseUs + offsetsUs[i]) & "\n"
  var m = initShotLogMap()
  m.hasHeader = false
  m.roles = @[crFileNumber, crUtcMicros]
  shots(parseShotLog(text, m), m)

const
  # Windows overlap (2.0 s and 2.6 s; 6.0 s and 6.4 s), the third reaches the
  # overlap of the source traces, the fifth the first 150 samples of the gap, the
  # seventh the second overlap; microseconds are kept.
  Offsets = [2_123_456'i64, 2_600_000, 6_000_000, 6_400_000, 10_300_000, 17_800_000,
    23_700_000]
  Files = [101, 102, 103, 104, 105, 106, 107]

var
  mappedCalls: Atomic[int] ## reads of the recording's map seen by the hook
  failFrom: Atomic[int]    ## from this call on the hook raises (0: never)
  napMs: Atomic[int]       ## each call from `napFrom` on sleeps this long
  napFrom: Atomic[int]
  hookPath: string

proc countingHook(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  var mine = false
  {.cast(gcsafe).}:
    mine = path == hookPath
  if op in {foMapped, foHeaders} and mine:
    let n = mappedCalls.fetchAdd(1) + 1
    let nap = if n >= napFrom.load(): napMs.load() else: high(int)
    if nap > 0 and nap != high(int): sleep nap
    let at = failFrom.load()
    if at > 0 and n >= at: raise newException(OSError, "Input/output error")

type Ran = tuple[st: JobState; res: CutResult; error: string]

proc runCut(jobs: Jobs; f: var SeismicFile; source, dest: string; shots: CutShots;
    opts: CutOptions): Ran =
  let sink = CutSink()
  let id = jobs.submit(cutGatherSpec(source, dest),
    cutGatherWork(addr f, source, dest, shots, opts, sink))
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the cut did not finish"
  let info = jobs.info(id).get
  (info.state, sink.result, info.error)

proc samplesOf(f: SeismicFile; trace: int): seq[float32] =
  let x = f.readTraces(trace .. trace)
  result.setLen x.shape[1]
  for j in 0 ..< result.len: result[j] = x[0, j]

proc partFiles(dir: string): seq[string] =
  for kind, path in walkDir(dir):
    if ".part-" in path: result.add path

proc main*() =
  let dir = getTempDir() / ("viewseg-cutjob-" & $getCurrentProcessId())
  removeDir(dir)
  let outDir = dir / "out"
  createDir(dir / "rec")
  createDir(outDir)
  defer: removeDir(dir)
  let same = makeRecording(dir / "rec" / "same.sgy", differ = false)
  let diff = makeRecording(dir / "rec" / "diff.sgy", differ = true)
  var srcSame = openSeismic(same.path, keys = true)
  var srcDiff = openSeismic(diff.path, keys = true)
  defer:
    srcSame.close()
    srcDiff.close()
  let jobs = initJobs()
  let opts = initCutOptions(LengthMs, StartMs)
  let view = logOf(Files, Offsets)
  let shots = shotsInTime(view.rows)
  doAssert shots.shots.len == 7 and shots.increasing

  block one_segment_of_four_components_is_sliced_right:
    # a Z, an X, a Y and a hydrophone of one station, one start: one continuous segment
    # SEG-D: SEG-Y has no slot for the receiver line
    let path = dir / "rec" / "four.sgd"
    var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
      numSamples: SegLen))
    for comp in 0 .. 3:
      var samples = newSeq[float32](SegLen)
      for j in 0 ..< SegLen: samples[j] = ramp(comp, j)
      var k = initTraceKeys()
      k.status = tsLive
      k.record = 1
      k.channel = float64(comp + 11)
      k.component = uint8(comp + 1)
      k.intervalUs = 2000
      k.t0Ms = 0
      k.time = float64(BaseUs div 1_000_000)
      k.rcvLine = 1
      k.rcvPoint = 7
      w.writeTrace(k, samples)
    discard w.close()
    var src = openSeismic(path, keys = true)
    defer: src.close()
    let one = shotsInTime(logOf([201], [1_500_000'i64]).rows)
    let dest = outDir / "cut-four.sgd"
    let got = runCut(jobs, src, path, dest, one, opts)
    doAssert got.st == jsDone, got.error & " / " & got.res.reason
    doAssert got.res.ok and got.res.shotsWritten == 1 and got.res.components == 4, $got.res
    var f = openSeismic(dest, keys = true)
    defer: f.close()
    doAssert f.len == 4
    let k0 = firstSample(BaseUs + 1_500_000)
    for c in 0 .. 3:
      let samples = samplesOf(f, c)
      doAssert samples.len == Window
      for j in 0 ..< Window:
        doAssert samples[j] == ramp(c, k0 + j), "component " & $c & " sample " & $j

  block samples_numbers_and_time_zero:
    # Fails when the window comes from the wrong column, the record number is
    # not the file number, the channel is the source's, or the time origin
    # stays the shot's instant.
    let dest = outDir / "cut-same.sgd"
    let got = runCut(jobs, srcSame, same.path, dest, shots, opts)
    doAssert got.st == jsDone, got.error & " / " & got.res.reason
    doAssert got.res.ok and got.res.shotsWritten == 7
    doAssert got.res.components == 2 and got.res.samples == Window
    doAssert got.res.recordsFromFileNumbers
    var f = openSeismic(dest, keys = true)
    defer: f.close()
    doAssert f.len == 14
    for s in 0 ..< 7:
      let shotUs = BaseUs + Offsets[s]
      for c in 0 .. 1:
        let t = s * 2 + c
        let keys = f.traceKeys(t)
        doAssert keys.record == float64(Files[s]), "record of trace " & $t & ": " & $keys.record
        doAssert keys.channel == float64(c + 1), "channel of trace " & $t
        let zero = f.timeZeroOfRecord(t)
        doAssert zero.isSome and zero.get == shotUs,
          "time zero of record " & $s & ": " & $zero & " vs " & $shotUs
        let got = samplesOf(f, t)
        doAssert got.len == Window
        let k0 = firstSample(shotUs)
        for j in 0 ..< Window:
          doAssert cast[uint32](got[j]) == cast[uint32](same.model(c, k0 + j)),
            "trace " & $t & " sample " & $j & ": " & $got[j] & " vs " & $same.model(c, k0 + j)

  block segy_output_time_and_samples:
    # SEG-Y output with a start before and after the shot. Fails when the
    # writer is given the first sample's instant as time zero ("time zero of
    # record 0 (start -100): -100000 us off").
    for startMs in [-100.0, 40.0]:
      let dest = outDir / ("cut-segy" & $int(startMs) & ".sgy")
      let o = initCutOptions(LengthMs, startMs, standard = csSegy)
      let got = runCut(jobs, srcSame, same.path, dest, shots, o)
      doAssert got.st == jsDone, got.error & " / " & got.res.reason
      var f = openSeismic(dest, keys = true)
      defer: f.close()
      doAssert f.len == 14
      for s in 0 ..< 7:
        let shotUs = BaseUs + Offsets[s]
        let k0 = int((shotUs + int64(startMs * 1000) - BaseUs + DtUs div 2) div DtUs)
        for c in 0 .. 1:
          let t = s * 2 + c
          let zero = f.timeZeroOfRecord(t)
          doAssert zero.isSome and zero.get == shotUs,
            "time zero of record " & $s & " (start " & $startMs & "): " &
            $(zero.get(0) - shotUs) & " us off"
          let first = f.traceKeys(t).firstSampleUs
          doAssert first.isSome and first.get == shotUs + int64(startMs * 1000),
            "first sample of record " & $s & " (start " & $startMs & "): " &
            $(first.get(0) - shotUs - int64(startMs * 1000)) & " us off"
          let data = samplesOf(f, t)
          for j in 0 ..< Window:
            doAssert cast[uint32](data[j]) == cast[uint32](same.model(c, k0 + j)),
              "trace " & $t & " sample " & $j

  block equals_extract_of_whole_block:
    # The whole source in memory, cut by the library's own `extractInto`.
    var whole = srcSame.readTraces(0 ..< srcSame.len)
    let meta = chunkMeta(srcSame, 0 ..< srcSame.len)
    let plan = planSlices(meta, shots.shots, SliceWindow(startMs: StartMs, lengthMs: LengthMs),
      soShotRecords, saNearest)
    var cutRef = zeros[float32](plan.len, plan.samples)
    var rep = initSliceReport(plan)
    var ws = initWorkspace()
    ws.reserve(sliceWorkspace(float32, plan))
    extractInto(plan, rowBlock(whole), rowBlock(cutRef), meta, rep, ws)
    var f = openSeismic(outDir / "cut-same.sgd", keys = true)
    defer: f.close()
    doAssert f.len == plan.len
    for t in 0 ..< plan.len:
      let got = samplesOf(f, t)
      for j in 0 ..< plan.samples:
        doAssert cast[uint32](got[j]) == cast[uint32](cutRef[t, j]),
          "trace " & $t & " sample " & $j

  block overlaps_and_gap:
    # Fails when overlaps are never compared, a match and a mismatch are not
    # told apart, the later trace does not win, or gaps are not counted.
    let sameRes = runCut(jobs, srcSame, same.path, outDir / "ov-same.sgd", shots, opts)
    doAssert sameRes.st == jsDone, sameRes.error
    doAssert sameRes.res.overlapsCompared == 4 and sameRes.res.overlapsMatched == 4 and
      sameRes.res.overlapsMismatched == 0, $sameRes.res.overlapsCompared
    let diffRes = runCut(jobs, srcDiff, diff.path, outDir / "ov-diff.sgd", shots, opts)
    doAssert diffRes.st == jsDone, diffRes.error
    doAssert diffRes.res.overlapsCompared == 4 and diffRes.res.overlapsMismatched == 4 and
      diffRes.res.overlapsMatched == 0
    doAssert diffRes.res.mismatches.len == 4 and
      "source traces 1 and 3" in diffRes.res.mismatches[0], $diffRes.res.mismatches
    doAssert diffRes.res.lines.anyIt("differ" in it)
    var expectedGap = 0
    for s in 0 ..< 7:
      let k0 = firstSample(BaseUs + Offsets[s])
      for j in 0 ..< Window:
        if not covered(k0 + j): inc expectedGap, 2
    doAssert expectedGap == 300, $expectedGap
    doAssert sameRes.res.gapSamples == expectedGap, $sameRes.res.gapSamples
    # The later trace wins in the output, over the overlapping samples.
    var f = openSeismic(outDir / "ov-diff.sgd", keys = true)
    defer: f.close()
    let got = samplesOf(f, 2 * 2) # shot 3 reaches the overlap at its first samples
    let k0 = firstSample(BaseUs + Offsets[2])
    doAssert k0 == 2950
    doAssert got[0] == ramp(0, 2950) + 1, "the later trace did not win: " & $got[0]
    doAssert got[49] == ramp(0, 2999) + 1 and got[50] == ramp(0, 3000)

  block start_zero_with_both_kinds_of_overlap:
    # The window starts at the shot (start 0). (i) Records overlap each other: the
    # shots 2.12 s and 2.6 s apart by less than the 2 s length, each read on its own, so
    # both records hold the shared samples. (ii) Source segments overlap: the third
    # shot's window (5 s to 7 s) reaches the 50 repeated samples at 5.9 s. Fails when a
    # shared sample is dropped from the later record, when the later trace does not win,
    # or when the overlap is not compared.
    let zeroOpts = initCutOptions(LengthMs, 0.0)
    let early = shotsInTime(logOf([301, 302, 303], [2_123_456'i64, 2_600_000, 5_000_000]).rows)
    for (rec, src, name) in [(same, addr srcSame, "same"), (diff, addr srcDiff, "diff")]:
      let dest = outDir / ("zero-" & name & ".sgd")
      let got = runCut(jobs, src[], rec.path, dest, early, zeroOpts)
      doAssert got.st == jsDone, got.error & " / " & got.res.reason
      if name == "same":
        doAssert got.res.overlapsCompared > 0 and got.res.overlapsMismatched == 0
      else:
        doAssert got.res.overlapsMismatched > 0
      var f = openSeismic(dest, keys = true)
      defer: f.close()
      for s in 0 ..< 3:
        let shotUs = BaseUs + [2_123_456'i64, 2_600_000, 5_000_000][s]
        let k0 = int((shotUs - BaseUs + DtUs div 2) div DtUs)
        for c in 0 .. 1:
          let data = samplesOf(f, s * 2 + c)
          for j in 0 ..< Window:
            doAssert cast[uint32](data[j]) == cast[uint32](rec.model(c, k0 + j)),
              name & " record " & $s & " component " & $c & " sample " & $j
    # the first two records share samples: the 2 s windows 476 ms apart
    var z = openSeismic(outDir / "zero-same.sgd", keys = true)
    defer: z.close()
    let a = samplesOf(z, 0)
    let b = samplesOf(z, 2)
    let shift = int((2_600_000 - 2_123_456) div DtUs) # 238 samples
    for j in shift ..< Window: doAssert a[j] == b[j - shift], "shared sample " & $j

  block numbering_by_sequence:
    # Fails when file numbers are used although they do not increase.
    let bad = logOf([105, 101, 103, 104, 102, 106, 107], Offsets)
    let sh = shotsInTime(bad.rows)
    doAssert not sh.increasing
    let dest = outDir / "seq.sgd"
    let got = runCut(jobs, srcSame, same.path, dest, sh, opts)
    doAssert got.st == jsDone, got.error
    doAssert not got.res.recordsFromFileNumbers
    doAssert got.res.lines.anyIt("numbered 1 to 7" in it), $got.res.lines
    var f = openSeismic(dest, keys = true)
    defer: f.close()
    for s in 0 ..< 7:
      doAssert f.traceKeys(2 * s).record == float64(s + 1)

  block untimed_rows_and_point_index:
    var m = initShotLogMap()
    m.hasHeader = false
    m.roles = @[crFileNumber, crPointIndex, crUtcMicros]
    var raw = ""
    raw.add "101,3," & $(BaseUs + 3_000_000) & "\n"
    raw.add "102,4,\n"
    raw.add "103,300," & $(BaseUs + 4_000_000) & "\n"
    let v = shots(parseShotLog(raw, m), m)
    let sh = shotsInTime(v.rows)
    let got = runCut(jobs, srcSame, same.path, outDir / "pi.sgd", sh, opts)
    doAssert got.st == jsDone, got.error
    doAssert got.res.shotsWritten == 2 and got.res.shotsDropped == 1
    doAssert got.res.pointIndexOutOfRange == 1

  block samples_read_once:
    # 60 shots 100 ms apart, each window 1000 samples: the sum of the windows
    # is 60000 samples a component, the union 1590. Fails when the buffer
    # never drops or does not keep what the next window reads.
    var files: seq[int] = @[]
    var offs: seq[int64] = @[]
    for i in 0 ..< 60:
      files.add 200 + i
      offs.add 2_000_000'i64 + int64(i) * 100_000
    let sh = shotsInTime(logOf(files, offs).rows)
    let got = runCut(jobs, srcSame, same.path, outDir / "many.sgd", sh, opts)
    doAssert got.st == jsDone, got.error
    doAssert got.res.shotsWritten == 60
    let union = 2 * (59 * 50 + Window + 50) # one run of the windows, both components
    doAssert got.res.samplesRead >= union - 2 * 50, $got.res.samplesRead
    doAssert got.res.samplesRead <= union + 2 * 50 + 2 * 100,
      "read " & $got.res.samplesRead & " for a union of " & $union

  block samples_fetched_within_source_length:
    # Four source traces a component, two overlaps, a gap: every shot's window
    # is read from the buffer, so no more than the source is decoded. Fails
    # when every overlap is compared at once or a row is dropped and read again.
    let got = runCut(jobs, srcSame, same.path, outDir / "len.sgd", shots, opts)
    doAssert got.st == jsDone, got.error
    doAssert got.res.overlapsCompared == 4
    doAssert got.res.samplesRead <= 2 * 4 * SegLen,
      "read " & $got.res.samplesRead & " of " & $(2 * 4 * SegLen)

  block size_within_estimate:
    # Fails when a record's headers are counted short (the estimate was 0.8% low).
    let dest = outDir / "size.sgd"
    let got = runCut(jobs, srcSame, same.path, dest, shots, opts)
    doAssert got.st == jsDone, got.error
    doAssert got.res.expectedBytes > 0 and got.res.bytesWritten == getFileSize(dest)
    let off = abs(got.res.bytesWritten - got.res.expectedBytes)
    doAssert off * 1000 <= got.res.expectedBytes, # within 0.1%
      "written " & $got.res.bytesWritten & ", estimated " & $got.res.expectedBytes

  block segy_size_equals_estimate:
    # SEG-Y output with and without source and receiver positions. Fails when
    # the estimate leaves out the extended text block and the 240-byte header
    # extension of every trace ("written 69520, estimated 62960").
    let withXy = makeRecording(dir / "rec" / "xy.sgy", differ = false, xy = true)
    var srcXy = openSeismic(withXy.path, keys = true)
    defer: srcXy.close()
    var m = initShotLogMap()
    m.hasHeader = false
    m.roles = @[crFileNumber, crUtcMicros, crSourceLine, crShotPoint, crX, crY]
    var raw = ""
    for i in 0 ..< 7:
      raw.add $Files[i] & "," & $(BaseUs + Offsets[i]) & ",5," & $(100 + i) & "," &
        $(500 + i) & ",600\n"
    let placed = shotsInTime(shots(parseShotLog(raw, m), m).rows)
    let o = initCutOptions(LengthMs, StartMs, standard = csSegy)
    var n = 0
    for (src, path, sh) in [(addr srcSame, same.path, shots), (addr srcSame, same.path, placed),
        (addr srcXy, withXy.path, shots), (addr srcXy, withXy.path, placed)]:
      inc n
      let dest = outDir / ("est" & $n & ".sgy")
      let got = runCut(jobs, src[], path, dest, sh, o)
      doAssert got.st == jsDone, got.error & " / " & got.res.reason
      doAssert got.res.bytesWritten == getFileSize(dest)
      doAssert got.res.bytesWritten == got.res.expectedBytes,
        "written " & $got.res.bytesWritten & ", estimated " & $got.res.expectedBytes

  block writer_notes_name_the_destination:
    # A receiver elevation without X/Y makes the writer note what it left out.
    # Fails when the note carries the part file's path ("... .sgd.part-3e39...").
    let withZ = makeRecording(dir / "rec" / "z.sgy", differ = false, z = true)
    var srcZ = openSeismic(withZ.path, keys = true)
    defer: srcZ.close()
    let dest = outDir / "note.sgd"
    let got = runCut(jobs, srcZ, withZ.path, dest, shots, opts)
    doAssert got.st == jsDone, got.error & " / " & got.res.reason
    let notes = got.res.lines.filterIt("not written" in it)
    doAssert notes.len == 1, $got.res.lines
    doAssert not (".part-" in notes[0]) and "note.sgd" in notes[0] and
      not (outDir in notes[0]), notes[0]

  block overlaps_outside_every_record:
    # Two early shots reach only the first source trace, so no overlap is
    # needed. Fails when those overlaps are counted as not compared ("4 overlaps
    # were not compared.").
    let early = shotsInTime(logOf([101, 102], [Offsets[0], Offsets[1]]).rows)
    let got = runCut(jobs, srcSame, same.path, outDir / "early.sgd", early, opts)
    doAssert got.st == jsDone, got.error
    doAssert got.res.overlapsCompared == 0 and got.res.overlapsNotRead == 0 and
      got.res.overlapsOutside == 4, $got.res.overlapsOutside
    doAssert not got.res.lines.anyIt("not compared" in it), $got.res.lines
    doAssert got.res.lines.anyIt("4 overlaps between traces lie outside every record" in it and
      it.endsWith("not needed.")), $got.res.lines

  block failure_reasons_read_as_sentences:
    # Fails when a reason without a full stop runs into the sentence about the
    # partial file ("...no space left The partial file was removed.").
    doAssert failureReason("Cancelled.", true, true) ==
      "Cancelled. The partial file was removed."
    doAssert failureReason("The disk is full", true, true) ==
      "The disk is full. The partial file was removed."
    doAssert failureReason("The disk is full", true, false) ==
      "The disk is full. The partial file could not be removed."
    doAssert failureReason("The disk is full", false, false) == "The disk is full."
    doAssert failureReason("", true, true) == "The partial file was removed."
    doAssert writeFailure("No space left on device") ==
      "Writing the file failed: No space left on device."

  block segy_cannot_store_source_line:
    # Fails when the line is silently dropped from SEG-Y output (no line says
    # so) or the line is said for SEG-D, which keeps it.
    var m = initShotLogMap()
    m.hasHeader = false
    m.roles = @[crFileNumber, crUtcMicros, crSourceLine, crShotPoint, crPointIndex]
    var raw = ""
    for i in 0 ..< 7:
      raw.add $Files[i] & "," & $(BaseUs + Offsets[i]) & ",5," & $(100 + i) & "," & $i & "\n"
    let placed = shotsInTime(shots(parseShotLog(raw, m), m).rows)
    let segy = initCutOptions(LengthMs, StartMs, standard = csSegy)
    let withLine = runCut(jobs, srcSame, same.path, outDir / "line.sgy", placed, segy)
    doAssert withLine.st == jsDone, withLine.error
    doAssert withLine.res.lines.countIt("not store the source line" in it) == 1,
      $withLine.res.lines
    let without = runCut(jobs, srcSame, same.path, outDir / "noline.sgy", shots, segy)
    doAssert without.st == jsDone, without.error
    doAssert not without.res.lines.anyIt("source line" in it), $without.res.lines
    let segd = runCut(jobs, srcSame, same.path, outDir / "line.sgd", placed, opts)
    doAssert segd.st == jsDone, segd.error
    doAssert not segd.res.lines.anyIt("source line" in it), $segd.res.lines

  block existing_destination_refused:
    # Fails when the part file is claimed (and the check made) after work.
    let dest = outDir / "keep.sgd"
    writeFile(dest, "keep me")
    let got = runCut(jobs, srcSame, same.path, dest, shots, opts)
    doAssert got.st == jsFailed
    doAssert "already exists" in got.res.reason, got.res.reason
    doAssert readFile(dest) == "keep me"
    doAssert partFiles(outDir).len == 0

  block cancel_leaves_nothing:
    # Fails when the part file stays after a cancel.
    let dest = outDir / "cancel.sgd"
    let sink = CutSink()
    var calls = 0
    let f = addr srcSame
    let id = jobs.submit(cutGatherSpec(same.path, dest), proc (ctx: JobContext) {.gcsafe.} =
      {.cast(gcsafe).}:
        cutGather(ctx, f, same.path, dest, shots, opts, sink, report =
          proc (done, total: int64): bool {.gcsafe.} =
            {.cast(gcsafe).}:
              inc calls
              calls < 4))
    doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
    doAssert jobs.info(id).get.state == jsCancelled, $jobs.info(id).get.state
    doAssert calls == 4, "cancelled at call " & $calls
    doAssert sink.result.removed
    doAssert not fileExists(dest)
    doAssert partFiles(outDir).len == 0, $partFiles(outDir)
    doAssert not walkDir(outDir).toSeq.anyIt(".tmp" in it.path)

  block failure_without_sink_leaves_no_part:
    # Fails when a cut with no result sink leaves its part file after a failure
    # that is not a cancel: the report raises on its second call, which is after
    # the part file was claimed and before any abort.
    let dest = outDir / "nosink.sgd"
    var calls = 0
    let f = addr srcSame
    let id = jobs.submit(cutGatherSpec(same.path, dest), proc (ctx: JobContext) {.gcsafe.} =
      {.cast(gcsafe).}:
        cutGather(ctx, f, same.path, dest, shots, opts, nil, report =
          proc (done, total: int64): bool {.gcsafe.} =
            {.cast(gcsafe).}:
              inc calls
              if calls == 2: raise newException(ValueError, "injected failure")
              true))
    doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
    doAssert jobs.info(id).get.state == jsFailed, $jobs.info(id).get.state
    doAssert calls == 2, "failed at call " & $calls
    doAssert not fileExists(dest)
    var stray: seq[string] = @[]
    for kind, path in walkDir(outDir):
      if extractFilename(path).startsWith("nosink.sgd.part-"): stray.add path
    doAssert stray.len == 0, $stray

  block cutter_failure_and_cancel_end_both_threads:
    # The cutter thread reads the recording and the job thread writes. Fails when a read
    # that fails on the cutter does not reach the job as its failure ("Writing the file
    # failed: Input/output error"), leaves the part file, or leaves a thread running (the
    # job would not end within 10 s); when a cancel while the writer waits for a slow
    # cutter does not end the cutter (the job ends only after it, so it stays running);
    # Seen failing: the cutter's failure not raised on the job thread (the job said it was
    # done); the stop of a failing writer left out (see the block after this one).
    let limit = initDuration(seconds = 10)
    hookPath = same.path
    setFsHook(countingHook)
    defer: setFsHook(nil)
    # how many reads a whole cut makes, to put a failure in its last one
    mappedCalls.store 0
    failFrom.store 0
    napMs.store 0
    napFrom.store 1
    let whole = runCut(jobs, srcSame, same.path, outDir / "count.sgd", shots, opts)
    doAssert whole.st == jsDone, whole.error
    let reads = mappedCalls.load()
    doAssert reads > 3, $reads
    for at in 1 .. reads:
      let what = "read " & $at
      let dest = outDir / "fault.sgd"
      mappedCalls.store 0
      failFrom.store at
      napFrom.store at # the failing read comes late: the writer has written every record
      napMs.store 100
      let sink = CutSink()
      let id = jobs.submit(cutGatherSpec(same.path, dest),
        cutGatherWork(addr srcSame, same.path, dest, shots, opts, sink))
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}, limit),
        what & ": the job did not end"
      doAssert jobs.info(id).get.state == jsFailed, what & ": " & $jobs.info(id).get.state
      doAssert "Writing the file failed: Input/output error" in sink.result.reason and
        "partial file was removed" in sink.result.reason, what & ": " & sink.result.reason
      doAssert not fileExists(dest), what
      doAssert partFiles(outDir).len == 0, what & ": " & $partFiles(outDir)
    failFrom.store 0
    napFrom.store 1
    # a cancel while the writer waits for a slow cutter
    napMs.store 40
    mappedCalls.store 0
    block:
      let dest = outDir / "slowcancel.sgd"
      let sink = CutSink()
      var calls = 0
      let f = addr srcSame
      let id = jobs.submit(cutGatherSpec(same.path, dest), proc (ctx: JobContext) {.gcsafe.} =
        {.cast(gcsafe).}:
          cutGather(ctx, f, same.path, dest, shots, opts, sink, report =
            proc (done, total: int64): bool {.gcsafe.} =
              {.cast(gcsafe).}:
                inc calls
                calls < 3))
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}, limit),
        "the cancelled job did not end"
      doAssert jobs.info(id).get.state == jsCancelled, $jobs.info(id).get.state
      doAssert sink.result.removed and not fileExists(dest)
      doAssert partFiles(outDir).len == 0
      # the cutter stopped at the cancel: it made no more reads once the job had ended
      let seen = mappedCalls.load()
      sleep 200
      doAssert mappedCalls.load() == seen, "the cutter went on after the job ended"
    napMs.store 0
    mappedCalls.store 0

  block writer_failure_stops_a_cutter_waiting_for_a_slot:
    # More shots than the ring holds, and a report that raises on its second call: the
    # cutter waits for a free slot when the job fails. Fails (the job does not end within
    # 10 s) when the failing job does not stop the cutter before it joins it.
    var fs: seq[int] = @[]
    var offs: seq[int64] = @[]
    for i in 0 ..< 30:
      fs.add 500 + i
      offs.add 300_000'i64 * i
    let many = shotsInTime(logOf(fs, offs).rows)
    let dest = outDir / "manyfail.sgd"
    var calls = 0
    let f = addr srcSame
    let id = jobs.submit(cutGatherSpec(same.path, dest), proc (ctx: JobContext) {.gcsafe.} =
      {.cast(gcsafe).}:
        cutGather(ctx, f, same.path, dest, many, opts, nil, report =
          proc (done, total: int64): bool {.gcsafe.} =
            {.cast(gcsafe).}:
              inc calls
              if calls == 2: raise newException(ValueError, "injected failure")
              true))
    doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled},
      initDuration(seconds = 10)), "the failed job did not end"
    doAssert jobs.info(id).get.state == jsFailed
    doAssert partFiles(outDir).len == 0

  block windows_past_both_ends_of_the_recording:
    # One shot's window starts before the first sample, another ends after the
    # last (a file whose traces differ in length is not continuous: refused). Every sample is
    # compared with a model built one sample at a time: what the recording lacks
    # is 0. Fails when the fetch copies a different span than it was asked for
    # (a sample off, the part the source lacks not 0).
    const Lens = [3000, 3000, 3000]
    let path = dir / "rec" / "short.sgy"
    var data: seq[float32] = @[]
    var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
    var at = 0
    for seg in 0 .. 2:
      var samples = newSeq[float32](Lens[seg])
      for j in 0 ..< Lens[seg]:
        samples[j] = ramp(0, at + j)
        data.add samples[j]
      var k = initTraceKeys()
      k.status = tsLive
      k.record = float64(seg + 1)
      k.channel = 11
      k.intervalUs = 2000
      k.t0Ms = 0
      k.time = float64(BaseUs div 1_000_000) + float64(at) * 0.002
      k.rcvLine = 1
      k.rcvPoint = 7
      w.writeTrace(k, samples)
      at += Lens[seg]
    discard w.close()
    var src = openSeismic(path, keys = true)
    defer: src.close()
    let offs = [50_000'i64, 5_000_000, 17_500_000]
    let sh = shotsInTime(logOf([301, 302, 303], offs).rows)
    let dest = outDir / "cut-short.sgd"
    let got = runCut(jobs, src, path, dest, sh, opts)
    doAssert got.st == jsDone, got.error & " / " & got.res.reason
    doAssert got.res.ok and got.res.shotsWritten == 3, $got.res
    var f = openSeismic(dest, keys = true)
    defer: f.close()
    doAssert f.len == 3
    for s in 0 ..< 3:
      # floor division: the first window starts before sample 0
      let k0 = int(floorDiv(BaseUs + offs[s] + int64(StartMs * 1000) - BaseUs + DtUs div 2,
        DtUs))
      let samples = samplesOf(f, s)
      doAssert samples.len == Window
      for j in 0 ..< Window:
        let k = k0 + j
        let want = if k >= 0 and k < data.len: data[k] else: 0'f32
        doAssert cast[uint32](samples[j]) == cast[uint32](want),
          "shot " & $s & " sample " & $j & ": " & $samples[j] & " vs " & $want
    doAssert BaseUs + offs[0] + int64(StartMs * 1000) < BaseUs
    doAssert firstSample(BaseUs + offs[2]) + Window > data.len

  echo "tcutgatherjob ok"

when isMainModule:
  main()
