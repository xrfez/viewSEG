## The job that cuts a continuous recording into one record per shot and
## writes it to a real file. The recording is built here: two components, three
## source traces each of 3000 samples at 2 ms whose values are a ramp (a sample
## names its instant), with one overlap of 50 samples between the first two
## (the files agree in one recording and differ in another) and one gap of 150
## samples after the second.
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

import std/[assertions, math, os, sequtils, strutils]
import parseSEG
import parseSEG/model/traceindex
import processSEG
import processSEG/continuous/slice
import processSEG/core/[rows, workspace]
import viewSEG/core/[cutgather, cutgatherjobs, jobs, shotlog]
import utils/waiting

const
  BaseUs = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC
  DtUs = 2000'i64
  SegLen = 3000
  Starts = [0, 2950, 6100, 9050]     ## first sample of each source trace
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
  # overlap of the source traces, the fifth the gap; microseconds are kept.
  Offsets = [2_123_456'i64, 2_600_000, 6_000_000, 6_400_000, 11_900_000, 12_300_000,
    18_200_000]
  Files = [101, 102, 103, 104, 105, 106, 107]

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
        let zero = f.recordTimeZeroUs(t)
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
          let zero = f.recordTimeZeroUs(t)
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

  echo "tcutgatherjob ok"

when isMainModule:
  main()
