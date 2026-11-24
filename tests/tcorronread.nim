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
## - empty-sweep refusal lost its period: view `the reference sweep is empty`
##   job `the reference sweep is empty.`
## - int16 source rounded on write: `format 3 trace 0 sample 0`
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

proc writeRaw(path: string; sweep: openArray[float32]; fmt = st5) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, format: fmt, text: @["C01 correlation read test"]))
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

proc sameRefusal(file: var SeismicFile; path: string; reference: seq[float32];
    dtMs: float64; refs: seq[int]; sentence: string) =
  let fromJob = jobFailure(file, path, reference, dtMs, refs)
  let fromView = initCorrelateView(addr file, reference, dtMs, refs).refusal
  doAssert fromView == fromJob, sentence & ": view `" & fromView & "` job `" & fromJob & "`"
  doAssert fromJob == sentence, fromJob

proc writeEmpty(path: string) =
  var w = openSeismicWriter(path, SegyOutputOptions())
  doAssert w.close().len == 0, "the empty file did not close"

proc clearIntervals(path: string) =
  var f = openSeismic(path, keys = true)
  var spots = @[3216]
  var wide: seq[int] = @[]
  for i in 0 ..< f.len:
    let e = f.traceEntry(i)
    spots.add int(e.offset) + 116
    if e.headerBytes > 240: wide.add int(e.offset) + 384
  f.close()
  var bytes = readFile(path)
  for at in spots:
    bytes[at] = '\0'
    bytes[at + 1] = '\0'
  for at in wide:
    for j in 0 .. 7: bytes[at + j] = '\0'
  writeFile(path, bytes)

proc writePairShape(path: string; a, b: int; dtA, dtB: float64; aux: bool) =
  var w = openSeismicWriter(path, SegyOutputOptions())
  for i, n in [a, b]:
    var k = initTraceKeys()
    if aux: (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    else: (k.traceCode, k.status) = (1'i16, tsLive)
    k.record = 1.0
    k.channel = float64(i + 1)
    k.intervalUs = (if i == 0: dtA else: dtB) * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    var buf = newSeq[float32](n)
    buf[0] = 1
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the shaped file did not close"

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
    let interval = "the reference sweep is sampled every 4 ms and the record every 2 ms."
    let short = "the reference sweep is as long as the record or longer, " &
      "so there is no listen time."
    sameRefusal(file, path, sweep, 4.0, refs, interval)
    sameRefusal(file, path, ones(Record), DtMs, refs, short)
    sameRefusal(file, path, newSeq[float32](), DtMs, refs, "the reference sweep is empty.")
    var one = newSeq[float32](1)
    one[0] = 1
    sameRefusal(file, path, one, DtMs, refs,
      "the reference sweep needs at least two samples.")
    var nanSweep = @[1'f32, 1'f32]
    nanSweep[1] = NaN
    sameRefusal(file, path, nanSweep, DtMs, refs,
      "the reference sweep has a sample that is not a number.")
    sameRefusal(file, path, newSeq[float32](4), DtMs, refs, "the reference sweep is all zeros.")
    sameRefusal(file, path, sweep, NaN, refs, "the reference sweep has no sample interval.")
    sameRefusal(file, path, sweep, DtMs, @[9], "reference trace 9 is outside 0 .. 4.")
    sameRefusal(file, path, sweep, DtMs, @[RefAux, RefAux],
      "reference trace 3 is listed twice.")
    var closed = openSeismic(path, keys = true)
    closed.close()
    sameRefusal(closed, path, sweep, DtMs, refs, "the file is not open.")
    var bare = openSeismic(path)
    defer: bare.close()
    sameRefusal(bare, path, sweep, DtMs, refs, "the file was opened without its keys.")
    let emptyPath = dir / "empty.sgy"
    writeEmpty(emptyPath)
    var empty = openSeismic(emptyPath, keys = true)
    defer: empty.close()
    sameRefusal(empty, emptyPath, sweep, DtMs, @[], "the file has no traces.")
    let zeroDtPath = dir / "zerodt.sgy"
    writePairShape(zeroDtPath, 8, 8, DtMs, DtMs, false)
    clearIntervals(zeroDtPath)
    var zeroDt = openSeismic(zeroDtPath, keys = true)
    defer: zeroDt.close()
    sameRefusal(zeroDt, zeroDtPath, sweep, DtMs, @[], "the file has no sample interval.")
    let unequalPath = dir / "unequal.sgy"
    writePairShape(unequalPath, 400, 800, DtMs, DtMs, false)
    var unequal = openSeismic(unequalPath, keys = true)
    defer: unequal.close()
    sameRefusal(unequal, unequalPath, sweep, DtMs, @[],
      "the seismic traces do not share one length.")
    let splitPath = dir / "splitdt.sgy"
    writePairShape(splitPath, Record, Record, DtMs, 4.0, false)
    var splitDt = openSeismic(splitPath, keys = true)
    defer: splitDt.close()
    sameRefusal(splitDt, splitPath, sweep, DtMs, @[],
      "the traces do not share one sample interval.")
    let auxPath = dir / "auxonly.sgy"
    writePairShape(auxPath, Record, Record, DtMs, DtMs, true)
    var auxOnly = openSeismic(auxPath, keys = true)
    defer: auxOnly.close()
    sameRefusal(auxOnly, auxPath, sweep, DtMs, @[], "the file has no seismic traces.")

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

  block integerBits:
    var scaled = newSeq[float32](sweep.len)
    for i, v in sweep: scaled[i] = v * 1000
    for fmt in [st3, st2]:
      let p = dir / ("src" & $ord(fmt) & ".sgy")
      writeRaw(p, scaled, fmt)
      var src = openSeismic(p, keys = true)
      defer: src.close()
      let built = initCorrelateView(addr src, scaled, DtMs, [RefAux])
      doAssert built.refusal.len == 0, built.refusal
      let made = correlate(src, p, scaled, @[RefAux])
      template opened: untyped = session.file(made.opened)
      var iws = newWorkspace(built.view)
      let asked = [0, 1, 2, RefAux, OtherAux]
      var dst = newSeq[float32](asked.len * Listen)
      correlateRead(built.view, addr src, asked, 0, Listen, dst, iws)
      doAssert iws.failed.len == 0, "an integer-source read failed"
      for r, t in asked:
        let want = opened.readTraces(t .. t)
        for j in 0 ..< Listen:
          doAssert cast[uint32](dst[r * Listen + j]) == cast[uint32](want[0, j]),
            "format " & $ord(fmt) & " trace " & $t & " sample " & $j

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
