## A raw vibrator file correlated into an in-memory file of the listen time.
##
## Seen to fail: a listen length equal to the record is refused ("dst must be
## 800 samples wide, got 1000"); omitting the reference shift fails "the
## reference auxiliary trace was not shifted"; writing that other auxiliary
## trace from the correlated rows fails "other aux sample 0". Discarding the
## failed rows of a block read let a SEG-Y cut inside trace 1's samples fail
## with the library's words ("was cut short while it was open (15760 bytes
## mapped, 13760 left); open it again") instead of the file's own reason, and
## those zeros would otherwise be adopted. Writing every auxiliary trace as
## time-break made the uphole trace read back as 32, not 48.

import std/[math, options, os, strutils]
import parseSEG
import processSEG
import viewSEG/core/[correlatejobs, cutfile, jobs, session]
import utils/waiting

const
  DtMs = 2.0
  Record = 1000
  SweepLen = 200
  Listen = 800
  Delays = [40, 100, 200]
  RefAux = 3
  OtherAux = 4

template sameF(a, b: TraceKeys; i: int; field: untyped) =
  let x = a.field
  let y = b.field
  doAssert (x.isNaN and y.isNaN) or x == b.field, "trace " & $i & " " & astToStr(field) &
    ": " & $x & " vs " & $y

template sameI(a, b: TraceKeys; i: int; field: untyped) =
  doAssert a.field == b.field, "trace " & $i & " " & astToStr(field) & ": " & $a.field &
    " vs " & $b.field

proc state(jobs: Jobs; id: JobId): JobState =
  jobs.info(id).get.state

proc peakAt(x: openArray[float32]): int =
  var best = -1.0
  for i, v in x:
    let a = abs(float64(v))
    if a > best:
      best = a
      result = i

proc sameRow(a, b: Tensor[float32]; n: int): bool =
  result = true
  for j in 0 ..< n:
    if a[0, j] != b[0, j]: return false

proc delayedSweep(sweep: openArray[float32]; samples, delay: int): seq[float32] =
  result = newSeq[float32](samples)
  for i in 0 ..< samples:
    let j = i - delay
    if j >= 0 and j < sweep.len: result[i] = sweep[j]

proc writePair(path: string; samples: int) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, text: @["C01 correlation cut test"]))
  var buf = newSeq[float32](samples)
  for j in 0 ..< samples: buf[j] = float32(j + 1)
  for i in 0 .. 1:
    var k = initTraceKeys()
    (k.traceCode, k.status) = (1'i16, tsLive)
    k.record = 7.0
    k.ensemble = 10.0 + float64(i)
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the pair did not close"

proc writeChannels(path: string; samples: int) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: DtMs * 1000.0,
    numSamples: samples, time: 1_700_000_000.0))
  let types = [sctSeismic, sctSeismic, sctUpHole, sctWaterBreak, sctSourceRefSweep,
    sctTimeBreak]
  var buf = newSeq[float32](samples)
  for j in 0 ..< samples: buf[j] = 1
  for i, ct in types:
    var k = initTraceKeys()
    k.record = 1
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.t0Ms = 0
    k.time = 1_700_000_000.0
    k.status = if ct == sctSeismic: tsLive else: tsAuxiliary
    k.traceCode = if ct == sctSeismic: 1'i16 else: 5'i16
    w.writeTrace(k, buf, channelType = ct)
  doAssert w.close().len == 0, "the channel file did not close"

proc writeRaw(path: string; sweep: openArray[float32]) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, text: @["C01 correlation job test"]))
  for i in 0 .. 4:
    var buf: seq[float32]
    var k = initTraceKeys()
    if i < Delays.len:
      buf = delayedSweep(sweep, Record, Delays[i])
      (k.traceCode, k.status) = (1'i16, tsLive)
    elif i == RefAux:
      buf = delayedSweep(sweep, Record, 0)
      (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    else:
      buf = newSeq[float32](Record)
      for j in 0 ..< Record: buf[j] = float32(j + 1)
      (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    k.record = 7.0
    k.ensemble = 10.0 + float64(i)
    k.offset = 100.0 + float64(i) * 25.0
    k.srcX = 500_000.0 + float64(i)
    k.srcY = 4_000_000.0
    k.rcvX = 500_100.0 + float64(i) * 10.0
    k.rcvY = 4_000_100.0
    k.srcZ = 100.0
    k.rcvZ = 50.0 + float64(i)
    k.channel = float64(i + 1)
    k.t0Ms = 0.0
    k.intervalUs = DtMs * 1000.0
    k.time = 1_700_000_000.0 + float64(i)
    k.inline = 100.0
    k.crossline = 200.0 + float64(i)
    k.traceCodeRev = tcrRev2
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the raw file did not close"

proc spec(path: string): JobSpec =
  JobSpec(title: "Correlate " & path.extractFilename, lane: jlBackground,
    reads: @[path], cancellable: true)

proc finish(jobs: Jobs; id: JobId): JobState =
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}), "the job did not finish"
  jobs.state(id)

proc direct(file: SeismicFile; trace: int; sweep: seq[float32]; shift: bool): Tensor[float32] =
  let plan = initCorrelationPlan(float32, initPilot(sweep, DtMs), DtMs, Record)
  var src = file.readTraces(trace .. trace)
  if shift:
    timeShift(rowBlock(src).row(0), wholeSamples(-AuxLeadMs, DtMs))
  result = zeros[float32](1, Listen)
  var keys = @[file.traceKeys(trace)]
  var counts = @[Record]
  let meta = initChunkMeta(rowsOf(keys, counts), DtMs)
  var ws = initWorkspace()
  ws.reserve(plan.workspaceSize)
  plan.correlateInto(src, result, meta, ws)

template keysMatch(src, got: SeismicFile) =
  for i in 0 ..< src.len:
    let a = src.traceKeys(i)
    let b = got.traceKeys(i)
    sameF(a, b, i, record)
    sameF(a, b, i, ensemble)
    sameF(a, b, i, offset)
    sameF(a, b, i, srcLine)
    sameF(a, b, i, srcPoint)
    sameF(a, b, i, srcX)
    sameF(a, b, i, srcY)
    sameF(a, b, i, rcvLine)
    sameF(a, b, i, rcvPoint)
    sameF(a, b, i, rcvX)
    sameF(a, b, i, rcvY)
    sameF(a, b, i, srcZ)
    sameF(a, b, i, rcvZ)
    sameF(a, b, i, cmpX)
    sameF(a, b, i, cmpY)
    sameF(a, b, i, channel)
    sameF(a, b, i, time)
    sameF(a, b, i, t0Ms)
    sameF(a, b, i, intervalUs)
    sameF(a, b, i, inline)
    sameF(a, b, i, crossline)
    sameI(a, b, i, srcIndex)
    sameI(a, b, i, rcvIndex)
    sameI(a, b, i, depthIndex)
    sameI(a, b, i, reshootIndex)
    sameI(a, b, i, sensorType)
    sameI(a, b, i, component)
    sameI(a, b, i, traceCode)
    sameI(a, b, i, status)
    sameI(a, b, i, traceCodeRev)

var
  holdCorr: Gate
  corrHeld: Gate

proc corrHook(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  discard id
  if phase != "correlating" or back: return
  corrHeld.open()
  var n = 0
  while not holdCorr.isOpen and n < 60_000:
    sleep 1
    inc n

proc main*() =
  let dir = getTempDir() / ("tcorrelatejobs-" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  let path = dir / "raw.sgy"
  let specSweep = linearSweep(8.0, 80.0, float64(SweepLen) * DtMs, DtMs)
  let sweep = specSweep.sweepSamples(float32)
  doAssert sweep.len == SweepLen
  writeRaw(path, sweep)
  var file = openSeismic(path, keys = true)
  defer: file.close()
  let before = file.readTraces(0 .. 0)

  block correlated:
    var jobs = initJobs()
    var slot: CorrelateResult
    try:
      let id = jobs.submit(spec(path), correlateWork(CorrelateAsk(
        file: addr file, path: path, reference: sweep, referenceDtMs: DtMs,
        referenceTraces: @[RefAux]), addr slot))
      doAssert finish(jobs, id) == jsDone, slot.failure
    finally:
      jobs.stop()
    doAssert slot.ok, slot.failure
    doAssert not slot.cancelled
    doAssert slot.failure.len == 0
    doAssert slot.sourcePath == path
    doAssert slot.traces == 5
    doAssert slot.samples == Listen
    doAssert abs(slot.listenMs - float64(Listen) * DtMs) < 1e-9
    doAssert abs(slot.sweepMs - float64(SweepLen) * DtMs) < 1e-9
    doAssert slot.lines == @[
      "5 traces, 800 samples (1600 ms of listen time).",
      "sweep 400 ms. 1 reference trace delayed by 500 ms."]
    doAssert not slot.opened.isNil
    template opened: untyped = session.file(slot.opened)
    doAssert opened.inMemory
    doAssert opened.kind == skSegy
    doAssert opened.len == 5
    for i in 0 ..< 5:
      doAssert int(opened.traceEntry(i).numSamples) == Listen
      doAssert int(file.traceEntry(i).numSamples) == Record
    keysMatch(file, opened)
    for i, d in Delays:
      let t = int(i)
      let got = opened.readTraces(t .. t)
      let want = direct(file, t, sweep, shift = false)
      doAssert sameRow(got, want, Listen), "trace " & $t & " differs from a direct call"
      doAssert peakAt(rowBlock(got).row(0)) == d, "trace " & $t & " peaks at " &
        $peakAt(rowBlock(got).row(0))
      doAssert abs(got[0, d]) > abs(got[0, d - 1]) and abs(got[0, d]) > abs(got[0, d + 1])
    block referenceAux:
      let got = opened.readTraces(RefAux .. RefAux)
      let want = direct(file, RefAux, sweep, shift = true)
      doAssert sameRow(got, want, Listen), "the reference auxiliary trace was not shifted"
      let peak = peakAt(rowBlock(got).row(0))
      doAssert peak == int(round(AuxLeadMs / DtMs)), "reference peak at " & $peak
      doAssert got[0, peak - 1] != 0 and got[0, peak + 1] != 0, "a side of the wavelet is empty"
      var worst = 0.0
      for k in 1 .. 40:
        worst = max(worst, abs(float64(got[0, peak + k] - got[0, peak - k])))
      doAssert worst < 1e-3, "the wavelet's sides differ by " & $worst
    block otherAux:
      let got = opened.readTraces(OtherAux .. OtherAux)
      let raw = file.readTraces(OtherAux .. OtherAux)
      for j in 0 ..< Listen:
        doAssert got[0, j] == raw[0, j], "other aux sample " & $j
      let correlated = direct(file, OtherAux, sweep, shift = false)
      doAssert not sameRow(got, correlated, Listen), "the other aux trace was correlated"
    let after = file.readTraces(0 .. 0)
    doAssert sameRow(before, after, Record), "the source file was modified"

  block refused:
    var jobs = initJobs()
    try:
      proc ones(n: int): seq[float32] =
        result = newSeq[float32](n)
        for i in 0 ..< n: result[i] = 1
      for (reference, dt, sentence) in @[
          (newSeq[float32](), DtMs, "the reference sweep is empty."),
          (ones(Record), DtMs,
            "the reference sweep is as long as the record or longer, so there is no listen time."),
          (ones(Record + 1), DtMs,
            "the reference sweep is as long as the record or longer, so there is no listen time."),
          (sweep, 4.0,
            "the reference sweep is sampled every 4 ms and the record every 2 ms.")]:
        var slot: CorrelateResult
        let id = jobs.submit(spec(path), correlateWork(CorrelateAsk(
          file: addr file, path: path, reference: reference, referenceDtMs: dt,
          referenceTraces: @[RefAux]), addr slot))
        doAssert finish(jobs, id) == jsFailed, slot.failure
        doAssert not slot.ok
        doAssert slot.opened.isNil
        doAssert not slot.cancelled
        doAssert slot.failure == sentence, slot.failure
    finally:
      jobs.stop()

  block cutShort:
    ## A SEG-Y of 2 traces, opened, then cut inside trace 1's samples.
    let cutPath = dir / "cut.sgy"
    writePair(cutPath, Record)
    var cutFile = openSeismic(cutPath, keys = true)
    defer: cutFile.close()
    let e0 = cutFile.traceEntry(0)
    let e1 = cutFile.traceEntry(1)
    let data0 = e0.offset + int64(e0.headerBytes)
    let span0 = e1.offset - data0
    doAssert span0 mod int64(e0.numSamples) == 0,
      "trace 0's samples are not a whole number of bytes"
    let sampleBytes = span0 div int64(e0.numSamples)
    let data1 = e1.offset + int64(e1.headerBytes)
    let cutAt = data1 + (int64(e1.numSamples) div 2) * sampleBytes
    doAssert cutAt > data1 and cutAt < getFileSize(cutPath), "the cut is not inside trace 1"
    writeFile(cutPath, readFile(cutPath)[0 ..< int(cutAt)])
    let why = cutWhy(cutFile)
    doAssert why.len > 0 and "cut short" in why, why
    var jobs = initJobs()
    var slot: CorrelateResult
    try:
      let id = jobs.submit(spec(cutPath), correlateWork(CorrelateAsk(
        file: addr cutFile, path: cutPath, reference: sweep, referenceDtMs: DtMs,
        referenceTraces: @[]), addr slot))
      doAssert finish(jobs, id) == jsFailed, slot.failure
    finally:
      jobs.stop()
    doAssert not slot.ok
    doAssert slot.opened.isNil
    doAssert not slot.cancelled
    doAssert slot.failure == why, slot.failure

  block channelTypes:
    ## Up hole, water break, reference sweep, time break, and two seismic traces.
    let chPath = dir / "channels.sgd"
    writeChannels(chPath, Record)
    var chFile = openSeismic(chPath, keys = true)
    defer: chFile.close()
    doAssert chFile.len == 6
    var jobs = initJobs()
    var slot: CorrelateResult
    try:
      let id = jobs.submit(spec(chPath), correlateWork(CorrelateAsk(
        file: addr chFile, path: chPath, reference: sweep, referenceDtMs: DtMs,
        referenceTraces: @[4]), addr slot))
      doAssert finish(jobs, id) == jsDone, slot.failure
    finally:
      jobs.stop()
    doAssert slot.ok, slot.failure
    doAssert not slot.opened.isNil
    template got: untyped = session.file(slot.opened)
    doAssert got.len == chFile.len
    for i in 0 ..< chFile.len:
      doAssert got.traceEntry(i).channelType == chFile.traceEntry(i).channelType,
        "trace " & $i & " channel type " & $got.traceEntry(i).channelType &
        " is not " & $chFile.traceEntry(i).channelType

  block cancelled:
    holdCorr.close()
    corrHeld.close()
    setJobHook(corrHook)
    var jobs = initJobs()
    var slot: CorrelateResult
    try:
      let id = jobs.submit(spec(path), correlateWork(CorrelateAsk(
        file: addr file, path: path, reference: sweep, referenceDtMs: DtMs,
        referenceTraces: @[RefAux]), addr slot))
      doAssert waitUntil(corrHeld.isOpen), "the job never reached correlating"
      doAssert jobs.cancel(id)
      holdCorr.open()
      doAssert waitUntil(jobs.state(id) == jsCancelled), "the job was not cancelled"
      doAssert slot.cancelled
      doAssert not slot.ok
      doAssert slot.opened.isNil
      doAssert slot.failure.len == 0
    finally:
      holdCorr.open()
      setJobHook(nil)
      jobs.stop()

when isMainModule:
  main()
  echo "tcorrelatejobs: ok"
