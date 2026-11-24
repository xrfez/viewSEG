## Correlated samples of chosen traces, read from the raw file, match the
## in-memory file `correlateWork` writes.
##
## Seen to fail, then restored:
## - first copied sample bumped by 1: `trace 0 window 0 ..< 64`
## - reference auxiliary not shifted: `trace 3 window 0 ..< 64`
## - other auxiliary correlated: `trace 4 window 0 ..< 64`
## - raw listen window painted instead of the correlation:
##   `trace 0 is the raw listen window, not the correlation`
## - a worker wrote zeros: `thread A sample 0`
## - interval refusal shortened: `the reference sweep is sampled every 4 ms and
##   the record every 2 ms.`
## - `newSeq` inside `correlateRead`: `the second call allocated 1`
## - an outside window still read: `a window outside the listen time was read`
## - `mappedRead` left to raise: `mappedRead can raise an unlisted exception: OSError`,
##   and without `{.raises: [].}`: `a failed raw read raised`

import std/[math, os, strutils]
import parseSEG
import processSEG
import viewSEG/core/[correlatejobs, correlateread, jobs, session]
import utils/[faultyfs, waiting]

const
  DtMs = 2.0
  Record = 1000
  SweepLen = 200
  Listen = 800
  Delays = [40, 100, 200]
  RefAux = 3
  OtherAux = 4

proc delayedSweep(sweep: openArray[float32]; samples, delay: int): seq[float32] =
  result = newSeq[float32](samples)
  for i in 0 ..< samples:
    let j = i - delay
    if j >= 0 and j < sweep.len: result[i] = sweep[j]

proc writeRaw(path: string; sweep: openArray[float32]) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, text: @["C01 correlation read test"]))
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
    k.channel = float64(i + 1)
    k.t0Ms = 0.0
    k.intervalUs = DtMs * 1000.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the raw file did not close"

proc writeOdd(path: string) =
  var w = openSeismicWriter(path, SegyOutputOptions())
  for i, dt in [DtMs, 4.0]:
    var k = initTraceKeys()
    if i == 0: (k.traceCode, k.status) = (1'i16, tsLive)
    else: (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    k.record = 4.0
    k.channel = float64(i + 1)
    k.intervalUs = dt * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    var buf = newSeq[float32](Record)
    for j in 0 ..< Record: buf[j] = float32(j + 1)
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the interval file did not close"

proc ones(n: int): seq[float32] =
  result = newSeq[float32](n)
  for i in 0 ..< n: result[i] = 1

proc spec(path: string): JobSpec =
  JobSpec(title: "Correlate " & path.extractFilename, lane: jlBackground,
    reads: @[path], cancellable: true)

proc state(jobs: Jobs; id: JobId): JobState =
  jobs.info(id).get.state

proc finish(jobs: Jobs; id: JobId): JobState =
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}), "the job did not finish"
  jobs.state(id)

proc jobFailure(file: var SeismicFile; path: string; reference: seq[float32]; dtMs: float64;
    refs: seq[int]): string =
  var jobs = initJobs()
  var slot: CorrelateResult
  try:
    let id = jobs.submit(spec(path), correlateWork(CorrelateAsk(
      file: addr file, path: path, reference: reference, referenceDtMs: dtMs,
      referenceTraces: refs), addr slot))
    discard finish(jobs, id)
  finally:
    jobs.stop()
  slot.failure

proc correlate(file: var SeismicFile; path: string; sweep: seq[float32];
    refs: seq[int]): CorrelateResult =
  var jobs = initJobs()
  try:
    let id = jobs.submit(spec(path), correlateWork(CorrelateAsk(
      file: addr file, path: path, reference: sweep, referenceDtMs: DtMs,
      referenceTraces: refs), addr result))
    doAssert finish(jobs, id) == jsDone, result.failure
  finally:
    jobs.stop()
  doAssert result.ok, result.failure

proc allocations(): int =
  cast[tuple[allocs, deallocs: int]](getAllocStats()).allocs

proc sameWindow(dst: openArray[float32]; row, count: int; want: Tensor[float32]): bool =
  result = true
  for j in 0 ..< count:
    if dst[row * count + j] != want[0, j]: return false

type
  Side = object
    view: CorrelateView
    file: ptr SeismicFile
    dst: ptr UncheckedArray[float32]
    n: int

proc sideWork(s: ptr Side) {.thread.} =
  var ws = newWorkspace(s[].view)
  var buf = newSeq[float32](s[].n)
  var traces = [0, 1, 2, RefAux, OtherAux]
  correlateRead(s[].view, s[].file, traces, 0, Listen, buf, ws)
  if s[].n > 0: copyMem(s[].dst, addr buf[0], s[].n * sizeof(float32))

proc main*() =
  let dir = getTempDir() / ("tcorronread-" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  let path = dir / "raw.sgy"
  let sweep = linearSweep(8.0, 80.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
  doAssert sweep.len == SweepLen
  writeRaw(path, sweep)
  var file = openSeismic(path, keys = true)
  defer: file.close()
  doAssert file.path == path

  let built = initCorrelateView(addr file, sweep, DtMs, [RefAux])
  doAssert built.refusal.len == 0, built.refusal
  doAssert built.view.listenSamples == Listen
  doAssert built.view.dtMs == DtMs
  let view = built.view
  let slot = correlate(file, path, sweep, @[RefAux])
  template opened: untyped = session.file(slot.opened)
  var ws = newWorkspace(view)

  block windows:
    let asked = [0, 1, 2, RefAux, OtherAux]
    for w in [(0, 64), (300, 100), (Listen - 50, 50), (0, Listen)]:
      let (first, count) = w
      var dst = newSeq[float32](asked.len * count)
      correlateRead(view, addr file, asked, first, count, dst, ws)
      doAssert ws.failed.len == 0, "a window read failed"
      for r, t in asked:
        let want = opened.readTraces(t .. t, first .. first + count - 1)
        doAssert sameWindow(dst, r, count, want), "trace " & $t & " window " & $first &
          " ..< " & $(first + count)

  block notRaw:
    var dst = newSeq[float32](Listen)
    correlateRead(view, addr file, [0], 0, Listen, dst, ws)
    let raw = file.readTraces(0 .. 0)
    var differ = false
    for j in 0 ..< Listen:
      if dst[j] != raw[0, j]: differ = true
    doAssert differ, "trace 0 is the raw listen window, not the correlation"

  block auxPolicy:
    var dst = newSeq[float32](2 * Listen)
    correlateRead(view, addr file, [RefAux, OtherAux], 0, Listen, dst, ws)
    var peak = 0
    var best = -1.0
    for j in 0 ..< Listen:
      let a = abs(float64(dst[j]))
      if a > best:
        best = a
        peak = j
    doAssert peak == int(round(AuxLeadMs / DtMs)), "reference peak at " & $peak
    let raw = file.readTraces(OtherAux .. OtherAux)
    for j in 0 ..< Listen:
      doAssert dst[Listen + j] == raw[0, j], "other aux sample " & $j
    let correlated = opened.readTraces(OtherAux .. OtherAux)
    var otherDiffers = false
    for j in 0 ..< Listen:
      if raw[0, j] != correlated[0, j]: otherDiffers = true
    doAssert not otherDiffers, "the written other aux is not the raw listen window"
    var refIsRaw = true
    let refRaw = file.readTraces(RefAux .. RefAux)
    for j in 0 ..< Listen:
      if dst[j] != refRaw[0, j]: refIsRaw = false
    doAssert not refIsRaw, "the reference auxiliary trace was not correlated"

  block clamp:
    var dst = newSeq[float32](10)
    correlateRead(view, addr file, [0], -4, 10, dst, ws)
    doAssert ws.failed.len == 0
    for j in 0 .. 3: doAssert dst[j] == 0, "clamped head " & $j
    let head = opened.readTraces(0 .. 0, 0 .. 5)
    for j in 0 .. 5: doAssert dst[4 + j] == head[0, j], "clamped sample " & $j
    correlateRead(view, addr file, [1], Listen - 3, 10, dst, ws)
    let tail = opened.readTraces(1 .. 1, Listen - 3 .. Listen - 1)
    for j in 0 .. 2: doAssert dst[j] == tail[0, j], "clamped tail " & $j
    for j in 3 .. 9: doAssert dst[j] == 0, "clamped past the end " & $j

  block seam:
    install()
    defer:
      release(path)
      setFsHook(nil)
      setIoHook(nil)
    block outside:
      fault(path, fkFail, {foMapped})
      var dst = newSeq[float32](5 * 10)
      correlateRead(view, addr file, [0, 1, 2, RefAux, OtherAux], Listen, 10, dst, ws)
      doAssert ws.failed.len == 0, "a window outside the listen time was read"
      for v in dst: doAssert v == 0
      correlateRead(view, addr file, [0], -30, 10, dst.toOpenArray(0, 9), ws)
      doAssert ws.failed.len == 0, "a window before the listen time was read"
      for j in 0 .. 9: doAssert dst[j] == 0
      release(path)
    block driveFails:
      fault(path, fkFail, {foMapped})
      var dst = newSeq[float32](2 * 16)
      var raised = false
      try:
        correlateRead(view, addr file, [0, 2], 0, 16, dst, ws)
      except CatchableError:
        raised = true
      doAssert not raised, "a failed raw read raised"
      doAssert ws.failed == @[0, 1], "failed rows " & $ws.failed
      for v in dst: doAssert v == 0
      release(path)

  block twoThreads:
    const n = 5 * Listen
    var a = newSeq[float32](n)
    var b = newSeq[float32](n)
    var one = newSeq[float32](n)
    let traces = [0, 1, 2, RefAux, OtherAux]
    correlateRead(view, addr file, traces, 0, Listen, one, ws)
    var sa = Side(view: view, file: addr file, dst: cast[ptr UncheckedArray[float32]](addr a[0]),
      n: n)
    var sb = Side(view: view, file: addr file, dst: cast[ptr UncheckedArray[float32]](addr b[0]),
      n: n)
    var ta, tb: Thread[ptr Side]
    createThread(ta, sideWork, addr sa)
    createThread(tb, sideWork, addr sb)
    joinThread(ta)
    joinThread(tb)
    for i in 0 ..< n:
      doAssert a[i] == one[i], "thread A sample " & $i
      doAssert b[i] == one[i], "thread B sample " & $i

  block refused:
    let refs = @[RefAux]
    let interval = jobFailure(file, path, sweep, 4.0, refs)
    let short = jobFailure(file, path, ones(Record), DtMs, refs)
    doAssert initCorrelateView(addr file, sweep, 4.0, refs).refusal == interval, interval
    doAssert initCorrelateView(addr file, ones(Record), DtMs, refs).refusal == short, short
    doAssert "every" in interval and "ms" in interval, interval
    doAssert "no listen time" in short, short

  block oddTrace:
    let oddPath = dir / "odd.sgy"
    writeOdd(oddPath)
    var oddFile = openSeismic(oddPath, keys = true)
    defer: oddFile.close()
    let oddView = initCorrelateView(addr oddFile, sweep, DtMs, [1])
    doAssert oddView.refusal.len == 0, oddView.refusal
    let oddSlot = correlate(oddFile, oddPath, sweep, @[1])
    template oddOpened: untyped = session.file(oddSlot.opened)
    var oddWs = newWorkspace(oddView.view)
    var dst = newSeq[float32](Listen)
    correlateRead(oddView.view, addr oddFile, [1], 0, Listen, dst, oddWs)
    let want = oddOpened.readTraces(1 .. 1)
    for j in 0 ..< Listen:
      doAssert dst[j] == want[0, j], "odd aux sample " & $j
      doAssert dst[j] == 0, "odd aux sample " & $j & " is not zero"

  block secondCallAllocatesNothing:
    var dst = newSeq[float32](5 * 64)
    let traces = [0, 1, 2, RefAux, OtherAux]
    correlateRead(view, addr file, traces, 0, 64, dst, ws)
    let before = allocations()
    correlateRead(view, addr file, traces, 0, 64, dst, ws)
    doAssert allocations() == before, "the second call allocated " & $(allocations() - before)

  echo "tcorronread: ok"

when isMainModule:
  main()
