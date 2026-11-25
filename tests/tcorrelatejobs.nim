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
## time-break made the uphole trace read back as 32, not 48. Seismic traces of
## 400 and 800 samples were accepted (the job finished) instead of being refused.
## Skipping the listen-window line fails "listen time 600 ms: the reference
## wavelet shows only 100 ms after its peak." and the peak-outside sentence.
## Omitting the cut-sweep line fails "reference trace 1 holds 600 ms, less
## than the 400 ms sweep plus the 500 ms lead: its wavelet is of a cut sweep."
## Leaving the correlated flag unset fails "trace 0 correlated 1".
## The old interval line fails "reference trace 1 is sampled every 4 ms, the
## record every 2 ms: not correlated, written as zeros."
## Reporting the nominal 500 ms lead fails "delayed by 501 ms".
## With the mapped-read fault left unset, the cut-short job finished and
## adopted a result instead of refusing with the file's reason.
## An int16 source kept format code 3, so the correlation was stored as
## whole numbers (`format code 3`).

import std/[math, options, os, strutils]
import parseSEG
import processSEG
import viewSEG/core/[correlatejobs, cutfile, jobs, session]
import utils/[faultyfs, waiting]

const
  DtMs = 2.0
  AuxLeadMs = 500.0 # the shift given to the marked reference trace
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

proc writeRaw(path: string; sweep: openArray[float32]; fmt = st5) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, format: fmt, text: @["C01 correlation job test"]))
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

proc writeUnequal(path: string) =
  var w = openSeismicWriter(path, SegyOutputOptions())
  for i, n in [400, 800]:
    var k = initTraceKeys()
    (k.traceCode, k.status) = (1'i16, tsLive)
    k.record = 1.0
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    var buf = newSeq[float32](n)
    for j in 0 ..< n: buf[j] = 1
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the unequal file did not close"

proc writeMixed(path: string; sweep: openArray[float32]) =
  var w = openSeismicWriter(path, SegyOutputOptions())
  proc put(w: var SeismicWriter; i, n: int; status: TraceStatus; code: int16;
      buf: openArray[float32]) =
    var k = initTraceKeys()
    (k.traceCode, k.status) = (code, status)
    k.record = 3.0
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf)
  put(w, 0, 800, tsLive, 1, delayedSweep(sweep, 800, 40))
  put(w, 1, 300, tsAuxiliary, 5, delayedSweep(sweep, 300, 0))
  var long = newSeq[float32](900)
  for j in 0 ..< 900: long[j] = float32(j + 1)
  put(w, 2, 900, tsAuxiliary, 6, long)
  doAssert w.close().len == 0, "the mixed file did not close"

proc writeLengths(path: string; record, auxSamples: int; dtMs: float64;
    sweep: openArray[float32]; otherSamples = -1) =
  ## Trace 0 is seismic of `record` samples; trace 1 is a reference auxiliary
  ## of `auxSamples`, holding the start of `sweep`. `otherSamples` >= 0 adds
  ## trace 2, an auxiliary trace that is not a reference.
  var w = openSeismicWriter(path, SegyOutputOptions())
  proc put(w: var SeismicWriter; i, n: int; status: TraceStatus; code: int16;
      fill: openArray[float32]) =
    var k = initTraceKeys()
    (k.traceCode, k.status) = (code, status)
    k.record = 1.0
    k.channel = float64(i + 1)
    k.intervalUs = dtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    var buf = newSeq[float32](n)
    let m = min(n, fill.len)
    for j in 0 ..< m: buf[j] = fill[j]
    w.writeTrace(k, buf)
  var seis = newSeq[float32](record)
  for j in 0 ..< record: seis[j] = 1
  put(w, 0, record, tsLive, 1, seis)
  put(w, 1, auxSamples, tsAuxiliary, 5, sweep)
  if otherSamples >= 0:
    var other = newSeq[float32](otherSamples)
    for j in 0 ..< otherSamples: other[j] = float32(j + 1)
    put(w, 2, otherSamples, tsAuxiliary, 6, other)
  doAssert w.close().len == 0, "the length file did not close"

proc writeOddInterval(path: string; otherDt = 0.0) =
  var w = openSeismicWriter(path, SegyOutputOptions())
  var dts = @[DtMs, 4.0]
  if otherDt > 0: dts.add otherDt
  for i, dt in dts:
    var k = initTraceKeys()
    if i == 0: (k.traceCode, k.status) = (1'i16, tsLive)
    else: (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    k.record = 4.0
    k.channel = float64(i + 1)
    k.intervalUs = dt * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    var buf = newSeq[float32](800)
    for j in 0 ..< 800: buf[j] = float32(j + 1)
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the interval file did not close"

proc fitted(samples: openArray[float32]; record: int): Tensor[float32] =
  result = zeros[float32](1, record)
  let n = min(samples.len, record)
  for j in 0 ..< n: result[0, j] = samples[j]

proc directFitted(samples: openArray[float32]; sweep: seq[float32]; record, listen: int;
    shift: bool): Tensor[float32] =
  var src = fitted(samples, record)
  if shift: timeShift(rowBlock(src).row(0), wholeSamples(-AuxLeadMs, DtMs))
  let plan = initCorrelationPlan(float32, initPilot(sweep, DtMs), DtMs, record)
  result = zeros[float32](1, listen)
  var keys = @[initTraceKeys()]
  keys[0].status = tsLive
  var counts = @[record]
  let meta = initChunkMeta(rowsOf(keys, counts), DtMs)
  var ws = initWorkspace()
  ws.reserve(plan.workspaceSize)
  plan.correlateInto(src, result, meta, ws)

proc spec(path: string): JobSpec =
  JobSpec(title: "Correlate " & path.extractFilename, lane: jlBackground,
    reads: @[path], cancellable: true)

proc finish(jobs: Jobs; id: JobId): JobState =
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}), "the job did not finish"
  jobs.state(id)

proc setCorrelated(path: string; n, traceFlag, binaryFlag: int) =
  var ed = openEditor(path)
  doAssert ed.setFileField("binary.correlated", binaryFlag), "binary.correlated was refused"
  for i in 0 ..< n:
    doAssert ed.setTraceField(i, "trace.correlated", traceFlag),
      "trace.correlated was refused on trace " & $i
  ed.close()

proc correlated(file: var SeismicFile; path: string; sweep: openArray[float32];
    dtMs: float64; refs: openArray[int]): CorrelateResult =
  ## The job, finished. `file` stays the caller's and stays open.
  var jobs = initJobs()
  result.opened = nil
  result.lines = @[]
  try:
    let id = jobs.submit(spec(path), correlateWork(CorrelateAsk(
      file: addr file, path: path, reference: @sweep, referenceDtMs: dtMs,
      marked: marksOf(refs, AuxLeadMs)), addr result))
    doAssert finish(jobs, id) == jsDone, result.failure
  finally:
    jobs.stop()
  doAssert result.ok, result.failure

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
        marked: marksOf([RefAux], AuxLeadMs)), addr slot))
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
          marked: marksOf([RefAux], AuxLeadMs)), addr slot))
        doAssert finish(jobs, id) == jsFailed, slot.failure
        doAssert not slot.ok
        doAssert slot.opened.isNil
        doAssert not slot.cancelled
        doAssert slot.failure == sentence, slot.failure
    finally:
      jobs.stop()

  block cutShort:
    ## A SEG-Y of 2 traces, opened. Trace 1 cannot be read: the job refuses
    ## with the file's reason and adopts nothing. Windows will not shrink a
    ## file a mapping still holds, so the on-disk cut runs only where the OS
    ## allows it. The seam's `mappedRead` hook cannot make parseSEG return a
    ## failed row (it only marks the read), so that cut stays, and a hook case
    ## on every system fails the read the same way.
    let cutPath = dir / "cut.sgy"
    writePair(cutPath, Record)
    var cutFile = openSeismic(cutPath, keys = true)
    defer: cutFile.close()
    block readFails:
      install()
      fault(cutPath, fkFail, {foMapped})
      defer:
        release(cutPath)
        setFsHook(nil)
        setIoHook(nil)
      let why = newOSError(OSErrorCode(5), cutPath).msg
      var jobs = initJobs()
      var slot: CorrelateResult
      try:
        let id = jobs.submit(spec(cutPath), correlateWork(CorrelateAsk(
          file: addr cutFile, path: cutPath, reference: sweep, referenceDtMs: DtMs,
          marked: @[]), addr slot))
        doAssert finish(jobs, id) == jsFailed, slot.failure
      finally:
        jobs.stop()
      doAssert not slot.ok
      doAssert slot.opened.isNil
      doAssert not slot.cancelled
      doAssert slot.failure == why, slot.failure
    when not defined(windows):
      let e0 = cutFile.traceEntry(0)
      let e1 = cutFile.traceEntry(1)
      let data0 = e0.offset + int64(e0.headerBytes)
      let span0 = e1.offset - data0
      doAssert span0 mod int64(e0.numSamples) == 0,
        "trace 0's samples are not a whole number of bytes"
      let sampleBytes = span0 div int64(e0.numSamples)
      let data1 = e1.offset + int64(e1.headerBytes)
      let cutAt = data1 + (int64(e1.numSamples) div 2) * sampleBytes
      doAssert cutAt > data1 and cutAt < getFileSize(cutPath),
        "the cut is not inside trace 1"
      writeFile(cutPath, readFile(cutPath)[0 ..< int(cutAt)])
      let why = cutWhy(cutFile)
      doAssert why.len > 0 and "cut short" in why, why
      var jobs = initJobs()
      var slot: CorrelateResult
      try:
        let id = jobs.submit(spec(cutPath), correlateWork(CorrelateAsk(
          file: addr cutFile, path: cutPath, reference: sweep, referenceDtMs: DtMs,
          marked: @[]), addr slot))
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
        marked: marksOf([4], AuxLeadMs)), addr slot))
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

  block unequalSeismic:
    let badPath = dir / "unequal.sgy"
    writeUnequal(badPath)
    var bad = openSeismic(badPath, keys = true)
    defer: bad.close()
    doAssert int(bad.traceEntry(0).numSamples) == 400
    doAssert int(bad.traceEntry(1).numSamples) == 800
    var jobs = initJobs()
    var slot: CorrelateResult
    try:
      let id = jobs.submit(spec(badPath), correlateWork(CorrelateAsk(
        file: addr bad, path: badPath, reference: sweep, referenceDtMs: DtMs,
        marked: @[]), addr slot))
      doAssert finish(jobs, id) == jsFailed, slot.failure
    finally:
      jobs.stop()
    doAssert not slot.ok
    doAssert slot.opened.isNil
    doAssert not slot.cancelled
    doAssert slot.failure == "the seismic traces do not share one length.", slot.failure

  block mixedLengths:
    ## An 800-sample record, an auxiliary trace of 300 and one of 900.
    const
      Rec = 800
      Short = 300
      Long = 900
      ListenMixed = Rec - SweepLen
    let mixedPath = dir / "mixed.sgy"
    writeMixed(mixedPath, sweep)
    var mixed = openSeismic(mixedPath, keys = true)
    defer: mixed.close()
    doAssert int(mixed.traceEntry(0).numSamples) == Rec
    doAssert int(mixed.traceEntry(1).numSamples) == Short
    doAssert int(mixed.traceEntry(2).numSamples) == Long
    var jobs = initJobs()
    var slot: CorrelateResult
    try:
      let id = jobs.submit(spec(mixedPath), correlateWork(CorrelateAsk(
        file: addr mixed, path: mixedPath, reference: sweep, referenceDtMs: DtMs,
        marked: marksOf([1], AuxLeadMs)), addr slot))
      doAssert finish(jobs, id) == jsDone, slot.failure
    finally:
      jobs.stop()
    doAssert slot.ok, slot.failure
    doAssert slot.samples == ListenMixed
    doAssert slot.lines == @[
      "3 traces, " & $ListenMixed & " samples (" & $(ListenMixed * 2) & " ms of listen time).",
      "sweep 400 ms. 1 reference trace delayed by 500 ms.",
      "1 auxiliary trace was padded. 1 auxiliary trace was cut.",
      "reference trace 1 holds 600 ms, less than the 400 ms sweep plus the " &
        "500 ms lead: its wavelet is of a cut sweep."]
    template got: untyped = session.file(slot.opened)
    doAssert got.len == 3
    let short = mixed.readTraces(1 .. 1)
    let wantRef = directFitted(rowBlock(short).row(0), sweep, Rec, ListenMixed, shift = true)
    let gotRef = got.readTraces(1 .. 1)
    for j in 0 ..< ListenMixed:
      doAssert gotRef[0, j] == wantRef[0, j], "padded reference sample " & $j
    let gotOther = got.readTraces(2 .. 2)
    let cut = fitted(rowBlock(mixed.readTraces(2 .. 2)).row(0), Rec)
    for j in 0 ..< ListenMixed:
      doAssert gotOther[0, j] == cut[0, j], "cut auxiliary sample " & $j

  block oddInterval:
    let oddPath = dir / "odd.sgy"
    writeOddInterval(oddPath)
    var odd = openSeismic(oddPath, keys = true)
    defer: odd.close()
    doAssert odd.traceKeys(1).intervalUs == 4000.0, $odd.traceKeys(1).intervalUs
    var jobs = initJobs()
    var slot: CorrelateResult
    try:
      let id = jobs.submit(spec(oddPath), correlateWork(CorrelateAsk(
        file: addr odd, path: oddPath, reference: sweep, referenceDtMs: DtMs,
        marked: marksOf([1], AuxLeadMs)), addr slot))
      doAssert finish(jobs, id) == jsDone, slot.failure
    finally:
      jobs.stop()
    doAssert slot.ok, slot.failure
    doAssert slot.lines == @[
      "2 traces, 600 samples (1200 ms of listen time).",
      "sweep 400 ms.",
      "reference trace 1 is sampled every 4 ms, the record every 2 ms: " &
        "not correlated, written as zeros."]
    template got: untyped = session.file(slot.opened)
    let row = got.readTraces(1 .. 1)
    doAssert int(got.traceEntry(1).numSamples) == 600
    for j in 0 ..< 600:
      doAssert row[0, j] == 0, "odd-interval sample " & $j & " is " & $row[0, j]

  block oddIntervalOther:
    ## Trace 2 is not a reference, so it is not described as uncorrelated.
    let p = dir / "oddother.sgy"
    writeOddInterval(p, otherDt = 3.0)
    var odd = openSeismic(p, keys = true)
    defer: odd.close()
    doAssert odd.len == 3
    var jobs = initJobs()
    var slot: CorrelateResult
    try:
      let id = jobs.submit(spec(p), correlateWork(CorrelateAsk(
        file: addr odd, path: p, reference: sweep, referenceDtMs: DtMs,
        marked: marksOf([1], AuxLeadMs)), addr slot))
      doAssert finish(jobs, id) == jsDone, slot.failure
    finally:
      jobs.stop()
    doAssert slot.ok, slot.failure
    doAssert slot.lines == @[
      "3 traces, 600 samples (1200 ms of listen time).",
      "sweep 400 ms.",
      "reference trace 1 is sampled every 4 ms, the record every 2 ms: " &
        "not correlated, written as zeros.",
      "auxiliary trace 2 is sampled every 3 ms, the record every 2 ms: " &
        "written as zeros."], $slot.lines
    template got: untyped = session.file(slot.opened)
    for t in [1, 2]:
      let row = got.readTraces(t .. t)
      doAssert int(got.traceEntry(t).numSamples) == 600
      for j in 0 ..< 600:
        doAssert row[0, j] == 0, "odd-interval trace " & $t & " sample " & $j

  block listenLopsided:
    ## Listen 600 ms, delay 500 ms: both sides are not in the window.
    let p = dir / "lopsided.sgy"
    writeLengths(p, 500, 500, DtMs, sweep)
    var f = openSeismic(p, keys = true)
    defer: f.close()
    let slot = correlated(f, p, sweep, DtMs, [1])
    doAssert slot.lines == @[
      "2 traces, 300 samples (600 ms of listen time).",
      "sweep 400 ms. 1 reference trace delayed by 500 ms.",
      "listen time 600 ms: the reference wavelet shows only 100 ms after its peak."],
      $slot.lines

  block listenPeakOutside:
    ## Listen 400 ms is under the 500 ms delay: the peak is not in the output.
    let p = dir / "outside.sgy"
    writeLengths(p, 400, 400, DtMs, sweep)
    var f = openSeismic(p, keys = true)
    defer: f.close()
    let slot = correlated(f, p, sweep, DtMs, [1])
    doAssert slot.lines == @[
      "2 traces, 200 samples (400 ms of listen time).",
      "sweep 400 ms. 1 reference trace delayed by 500 ms.",
      "listen time 400 ms: the reference wavelet's peak (at 500 ms) is outside the record.",
      "reference trace 1 holds 800 ms, less than the 400 ms sweep plus the " &
        "500 ms lead: its wavelet is of a cut sweep."],
      $slot.lines

  block listenEqualsDelay:
    ## The peak sits on the first sample past the window, so it is outside.
    let p = dir / "equal.sgy"
    writeLengths(p, 450, 450, DtMs, sweep)
    var f = openSeismic(p, keys = true)
    defer: f.close()
    let slot = correlated(f, p, sweep, DtMs, [1])
    doAssert slot.lines == @[
      "2 traces, 250 samples (500 ms of listen time).",
      "sweep 400 ms. 1 reference trace delayed by 500 ms.",
      "listen time 500 ms: the reference wavelet's peak (at 500 ms) is outside the record."],
      $slot.lines

  block shortListenNoDelay:
    ## A short listen window with no delayed reference adds no wavelet line.
    let p = dir / "nodelay.sgy"
    writeLengths(p, 400, 400, DtMs, sweep)
    var f = openSeismic(p, keys = true)
    defer: f.close()
    let slot = correlated(f, p, sweep, DtMs, [])
    doAssert slot.lines == @[
      "2 traces, 200 samples (400 ms of listen time).",
      "sweep 400 ms."],
      $slot.lines

  block cutSweep:
    ## Reference trace 1 holds less than the sweep plus the lead. Trace 2 is
    ## short too, and is not a reference, so it is only padded.
    let longSweep = linearSweep(8.0, 80.0, 12000.0, DtMs).sweepSamples(float32)
    doAssert longSweep.len == 6000, $longSweep.len
    let p = dir / "cutsweep.sgy"
    writeLengths(p, 6500, 4000, DtMs, longSweep, otherSamples = 1000)
    var f = openSeismic(p, keys = true)
    defer: f.close()
    let slot = correlated(f, p, longSweep, DtMs, [1])
    doAssert slot.lines == @[
      "3 traces, 500 samples (1000 ms of listen time).",
      "sweep 12000 ms. 1 reference trace delayed by 500 ms.",
      "2 auxiliary traces were padded.",
      "reference trace 1 holds 8000 ms, less than the 12000 ms sweep plus the " &
        "500 ms lead: its wavelet is of a cut sweep."],
      $slot.lines

  block correlatedFlag:
    ## Every written trace's correlated flag (byte 125) reads back as 2.
    ## The binary header's copy stays 1, and the job says so.
    let p = dir / "flag.sgy"
    writeLengths(p, Record, Record, DtMs, sweep, otherSamples = Record)
    setCorrelated(p, 3, 1, 1)
    var f = openSeismic(p, keys = true)
    defer: f.close()
    doAssert f.fileField("binary.correlated") == toFieldValue(1)
    for i in 0 ..< f.len:
      doAssert f.traceField(i, "trace.correlated") == toFieldValue(1), $i
    let slot = correlated(f, p, sweep, DtMs, [1])
    doAssert slot.lines == @[
      "3 traces, 800 samples (1600 ms of listen time).",
      "sweep 400 ms. 1 reference trace delayed by 500 ms.",
      "the binary header still says the data are not correlated (byte 3249 is 1); " &
        "this writer cannot change it."], $slot.lines
    template got: untyped = session.file(slot.opened)
    doAssert got.len == 3
    for i in 0 ..< got.len:
      doAssert got.traceField(i, "trace.correlated") == toFieldValue(2),
        "trace " & $i & " correlated " & $got.traceField(i, "trace.correlated")
    doAssert got.fileField("binary.correlated") == toFieldValue(1)
    for i in 0 ..< f.len:
      doAssert f.traceField(i, "trace.correlated") == toFieldValue(1), "source trace " & $i

  block correlatedFlagAlreadyYes:
    ## A binary flag that does not say "no" adds no line. Traces are still 2.
    let p = dir / "flagyes.sgy"
    writeLengths(p, Record, Record, DtMs, sweep, otherSamples = Record)
    setCorrelated(p, 3, 1, 2)
    var f = openSeismic(p, keys = true)
    defer: f.close()
    let slot = correlated(f, p, sweep, DtMs, [1])
    doAssert slot.lines == @[
      "3 traces, 800 samples (1600 ms of listen time).",
      "sweep 400 ms. 1 reference trace delayed by 500 ms."], $slot.lines
    template got: untyped = session.file(slot.opened)
    for i in 0 ..< got.len:
      doAssert got.traceField(i, "trace.correlated") == toFieldValue(2), $i
    doAssert got.fileField("binary.correlated") == toFieldValue(2)

  block correlatedFlagUnset:
    let p = dir / "flagzero.sgy"
    writeLengths(p, Record, Record, DtMs, sweep, otherSamples = Record)
    var f = openSeismic(p, keys = true)
    defer: f.close()
    doAssert f.fileField("binary.correlated") == toFieldValue(0)
    let slot = correlated(f, p, sweep, DtMs, [1])
    doAssert slot.lines == @[
      "3 traces, 800 samples (1600 ms of listen time).",
      "sweep 400 ms. 1 reference trace delayed by 500 ms."], $slot.lines
    template got: untyped = session.file(slot.opened)
    for i in 0 ..< got.len:
      doAssert got.traceField(i, "trace.correlated") == toFieldValue(2), $i

  block actualDelay:
    ## At 3 ms the 500 ms lead is 167 samples, which is 501 ms.
    let p = dir / "delay3.sgy"
    writeLengths(p, 600, 600, 3.0, sweep)
    var f = openSeismic(p, keys = true)
    defer: f.close()
    let slot = correlated(f, p, sweep, 3.0, [1])
    doAssert slot.lines == @[
      "2 traces, 400 samples (1200 ms of listen time).",
      "sweep 600 ms. 1 reference trace delayed by 501 ms."], $slot.lines

  block integerSource:
    var scaled = newSeq[float32](sweep.len)
    for i, v in sweep: scaled[i] = v * 1000
    let intPath = dir / "int16.sgy"
    writeRaw(intPath, scaled, st3)
    var src = openSeismic(intPath, keys = true)
    defer: src.close()
    let made = correlated(src, intPath, scaled, DtMs, [RefAux])
    template got: untyped = session.file(made.opened)
    doAssert got.summary.formatCode == 5, "format code " & $got.summary.formatCode
    let row = got.readTraces(0 .. 0)
    var whole = true
    for j in 0 ..< Listen:
      if row[0, j] != float32(round(row[0, j])): whole = false
    doAssert not whole, "correlated samples are all whole numbers"

  block cancelled:
    holdCorr.close()
    corrHeld.close()
    setJobHook(corrHook)
    var jobs = initJobs()
    var slot: CorrelateResult
    try:
      let id = jobs.submit(spec(path), correlateWork(CorrelateAsk(
        file: addr file, path: path, reference: sweep, referenceDtMs: DtMs,
        marked: marksOf([RefAux], AuxLeadMs)), addr slot))
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
