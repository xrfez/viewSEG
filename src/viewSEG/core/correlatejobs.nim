## A background job that correlates one open raw vibrator file with a reference
## sweep into a new in-memory seismic file of the listen time only: the record
## length minus the sweep length.
##
## Submit `correlateWork` on the background lane, cancellable, with the source
## path in `reads`, and keep the open file alive until the job has finished.
## `opened` is in memory (`inMemory`). Its path is the source path, which is
## where the headers were read, not where the correlated samples live. The next
## task adopts that file in place of the raw one: register a new id, and do not
## watch the path as if the correlated bytes had been written there.
##
## SEG-Y is written like the source, so a different sample count is kept and
## the trace headers are the source's. SEG-D cannot change a trace's sample
## count, so it is written from keys: the channel type is the source trace's
## (0 means seismic), and channel-set descriptors, external headers,
## general-header blocks and trace-header extensions are not copied. A start
## time the headers cannot give may read back as 0. SEG-2 cannot be written
## in memory.

import std/[algorithm, cpuinfo, formatfloat, math, sets, strutils]
import parseSEG
import processSEG
import cutfile, filesystem, jobs, session, threads

const
  AuxLeadMs* = 500.0
    ## Reference auxiliary traces are shifted later by this many milliseconds
    ## before they are correlated: zeros in front, the end cut, the record
    ## length kept, then the same reference and the same listen length, so
    ## both sides of the wavelet show.
  BlockTraces = 64

type
  CorrelateAsk* = object
    ## One correlation. The file stays the caller's, and must stay open until
    ## the job has finished.
    file*: ptr SeismicFile
    path*: string ## The file's path, for the result and for `reads`.
    reference*: seq[float32] ## The sweep, at `referenceDtMs`.
    referenceDtMs*: float64 ## The sweep's sample interval, in ms.
    referenceTraces*: seq[int]
      ## Auxiliary traces that hold a reference. Any other auxiliary trace is
      ## cut to the listen time and not correlated.

  CorrelateResult* = object
    ## Filled when the job ends. Read it only then. `opened` is nil unless
    ## `ok`.
    ok*: bool
    cancelled*: bool
    failure*: string
    opened*: Session
    sourcePath*: string
    traces*: int
    samples*: int
    listenMs*: float64
    sweepMs*: float64
    lines*: seq[string]

proc workerCount(): int =
  clamp(countProcessors() div 2, 1, 4)

proc msText(ms: float64): string =
  var s = formatFloat(ms, ffDecimal, 6)
  if '.' in s:
    while s.len > 0 and s[^1] == '0': s.setLen(s.len - 1)
    if s.len > 0 and s[^1] == '.': s.setLen(s.len - 1)
  if s.len == 0: "0" else: s

proc refuse(msg: string) {.noinline, noreturn.} =
  raise newException(ValueError, msg)

proc traceDt(file: ptr SeismicFile; trace: int): float64 =
  let us = file[].traceKeys(trace).intervalUs
  let got = if us > 0 and us < Inf: us else: file[].sampleIntervalUs(trace)
  if got.isNaN or got <= 0 or got == Inf: NaN else: got / 1000.0

proc fileDt(file: ptr SeismicFile): float64 =
  let n = file[].len
  if n == 0: refuse("the file has no traces.")
  result = traceDt(file, 0)
  if result.isNaN: refuse("the file has no sample interval.")
  for i in 1 ..< n:
    let d = traceDt(file, i)
    if d.isNaN or not sameInterval(d, result):
      refuse("the traces do not share one sample interval.")

proc checkReference(samples: openArray[float32]) =
  if samples.len == 0: refuse("the reference sweep is empty.")
  if samples.len < 2: refuse("the reference sweep needs at least two samples.")
  var energy = 0.0
  for i, v in samples:
    let x = float64(v)
    if x.isNaN or abs(x) == Inf:
      refuse("the reference sweep has a sample that is not a number.")
    energy += x * x
  if energy == 0: refuse("the reference sweep is all zeros.")

proc referenceSet(n: int; traces: openArray[int]): HashSet[int] =
  result = initHashSet[int]()
  for t in traces:
    if t < 0 or t >= n:
      refuse("reference trace " & $t & " is outside 0 .. " & $(n - 1) & ".")
    if t in result: refuse("reference trace " & $t & " is listed twice.")
    result.incl(t)

proc firstTime(file: ptr SeismicFile): float64 =
  result = NaN
  for i in 0 ..< file[].len:
    let t = file[].traceKeys(i).time
    if not t.isNaN and t != Inf and t != -Inf: return t

proc openOut(file: ptr SeismicFile; name: string; listen: int; dtMs, time: float64):
    SeismicWriter =
  case file[].kind
  of skSegy:
    result = openSeismicWriterBytes(file[], name)
  of skSegd:
    let us = round(dtMs * 1000.0)
    if us != dtMs * 1000.0 or us < 1 or us > float64(high(uint32)):
      refuse("the sample interval is not a whole number of microseconds, " &
        "so the file cannot be written.")
    let sum = file[].summary
    var units = sum.coordinateUnits
    if units notin {cuMeters, cuFeet, cuUnknown}: units = cuUnknown
    var crs = ""
    if sum.crsFormat != ctNone: crs = file[].crsText
    result = openSeismicWriterBytes(SegdOutputOptions(sampleIntervalUs: us,
      numSamples: listen, units: units, crsText: crs, time: time), name)
  of skSeg2, skUnknown:
    refuse("the file cannot be written in memory.")

proc writtenChannelType(code: uint8): SegdChannelType =
  ## 0 is seismic: a SEG-Y trace, and an unknown set, has no channel type.
  ## The enum has holes, so it cannot be walked.
  if code == 0: return sctSeismic
  case code
  of 0x10: sctSeismic
  of 0x11: sctEm
  of 0x20: sctTimeBreak
  of 0x21: sctClockTimeBreak
  of 0x22: sctFieldTimeBreak
  of 0x30: sctUpHole
  of 0x40: sctWaterBreak
  of 0x50: sctTimeCounter
  of 0x60: sctExternalData
  of 0x61: sctAcousticRange
  of 0x62: sctAcousticRefMeasured
  of 0x63: sctAcousticRefNominal
  of 0x70: sctOther
  of 0x80: sctSignatureUnfiltered
  of 0x90: sctSignatureFiltered
  of 0x91: sctSourceSigUnfiltered
  of 0x92: sctSourceSigFiltered
  of 0x93: sctSourceSigEstimated
  of 0x94: sctSourceSigMeasured
  of 0x95: sctSourceBasePlate
  of 0x96: sctSourceRefSweep
  of 0x97: sctSourceOther
  of 0x98: sctSourceRefPilot
  of 0x99: sctSourceMass
  of 0x9A: sctSourceExcitation
  of 0x9B: sctSourceValve
  of 0x9C: sctSourceOverload
  of 0xA0: sctAuxDataTrailer
  of 0xB0: sctTrueRefSweep
  of 0xB1: sctRadioRefSweep
  of 0xB2: sctRadioSimilarity
  of 0xB3: sctWirelineRefSweep
  of 0xC0: sctDepth
  of 0xC1: sctWind
  of 0xC2: sctCurrent
  of 0xC3: sctVoltage
  of 0xC4: sctVelocity
  of 0xC5: sctAcceleration
  of 0xC6: sctPressure
  of 0xC7: sctTension
  of 0xC8: sctTilt
  of 0xC9: sctAngle
  of 0xF0: sctCalibration
  else: refuse("channel type 0x" & toHex(int(code), 2) & " cannot be written.")

proc sweepLine(sweepMs: float64; delayed: int): string =
  let n = if delayed == 1: "1 reference trace" else: $delayed & " reference traces"
  "sweep " & msText(sweepMs) & " ms. " & n & " delayed by " & msText(AuxLeadMs) & " ms."

proc writeRow(w: var SeismicWriter; file: ptr SeismicFile; trace, row, listen: int;
    src, dst: Tensor[float32]; keys: TraceKeys; fromSrc, segd: bool; intervalUs: float64) =
  if segd:
    var k = keys
    k.intervalUs = intervalUs
    let ct = writtenChannelType(file[].traceEntry(trace).channelType)
    let rows = if fromSrc: rowBlock(src) else: rowBlock(dst)
    w.writeTrace(k, rows.row(row, listen), channelType = ct)
  elif fromSrc:
    w.writeTrace(file[], trace, src, row, count = listen)
  else:
    w.writeTrace(file[], trace, dst, row, count = listen)

proc run(ask: CorrelateAsk; slot: ptr CorrelateResult; ctx: JobContext) =
  if ask.path.len == 0: refuse("the file has no path.")
  let file = ask.file
  if file == nil or not file[].isOpen: refuse("the file is not open.")
  if file[].kind in {skSeg2, skUnknown}: refuse("the file cannot be written in memory.")
  if not file[].hasKeys: refuse("the file was opened without its keys.")
  fs.mappedRead(ask.path)
  let modified = fs.getFileInfo(ask.path).lastWriteTime
  checkReference(ask.reference)
  if ask.referenceDtMs.isNaN or ask.referenceDtMs <= 0 or ask.referenceDtMs == Inf:
    refuse("the reference sweep has no sample interval.")
  let dtMs = fileDt(file)
  if not sameInterval(ask.referenceDtMs, dtMs):
    refuse("the reference sweep is sampled every " & msText(ask.referenceDtMs) &
      " ms and the record every " & msText(dtMs) & " ms.")
  let nTraces = file[].len
  let recordSamples = file[].maxSamples
  let sweepLen = ask.reference.len
  if sweepLen >= recordSamples:
    refuse("the reference sweep is as long as the record or longer, " &
      "so there is no listen time.")
  let listen = recordSamples - sweepLen
  let refs = referenceSet(nTraces, ask.referenceTraces)
  var delayed = 0
  for t in ask.referenceTraces:
    if file[].traceKeys(t).status == tsAuxiliary: inc delayed
  let pilot = initPilot(ask.reference, ask.referenceDtMs)
  let plan = initCorrelationPlan(float32, pilot, dtMs, recordSamples)
  let segd = file[].kind == skSegd
  var time = NaN
  if segd:
    time = firstTime(file)
    if time.isNaN: refuse("the file has no recording time, so it cannot be written.")
  var w = openOut(file, ask.path, listen, dtMs, time)
  var src = zeros[float32](BlockTraces, recordSamples)
  var dst = zeros[float32](BlockTraces, listen)
  var pool = newProcessPool(workerCount())
  var keys = newSeq[TraceKeys](BlockTraces)
  var workKeys = newSeq[TraceKeys](BlockTraces)
  var counts = newSeq[int](BlockTraces)
  var failed = newSeq[int]()
  let lag = wholeSamples(-AuxLeadMs, dtMs)
  let outUs = round(dtMs * 1000.0)
  ctx.setPhase("correlating")
  ctx.checkCancelled()
  var start = 0
  while start < nTraces:
    ctx.checkCancelled()
    let n = min(BlockTraces, nTraces - start)
    let span = start ..< start + n
    discard file[].readTracesInto(span, src, failed)
    if failed.len > 0:
      let why = cutWhy(file[])
      refuse(if why.len > 0: why else: "a trace could not be read.")
    file[].traceKeysInto(span, keys.toOpenArray(0, n - 1))
    if lag != 0:
      let rows = rowBlock(src)
      for r in 0 ..< n:
        if (start + r) in refs and keys[r].status == tsAuxiliary:
          timeShift(rows.row(r), lag)
    for r in 0 ..< n:
      workKeys[r] = keys[r]
      if keys[r].status == tsAuxiliary and (start + r) notin refs:
        workKeys[r].status = tsDead
      counts[r] = int(file[].traceEntry(start + r).numSamples)
    let meta = initChunkMeta(rowsOf(workKeys.toOpenArray(0, n - 1),
      counts.toOpenArray(0, n - 1)), dtMs, failed = failed)
    pool.correlateInto(plan, rowBlock(src).sub(0 ..< n), rowBlock(dst).sub(0 ..< n), meta)
    for r in 0 ..< n:
      let fromSrc = keys[r].status == tsAuxiliary and (start + r) notin refs
      w.writeRow(file, start + r, r, listen, src, dst, keys[r], fromSrc, segd, outUs)
    let done = start + n
    if not ctx.progress(int64(done), int64(nTraces)):
      raise newException(JobCancelledError, "cancelled")
    start = done
  ctx.setPhase("writing the correlated record")
  ctx.checkCancelled()
  var bytes = w.finishBytes()
  let nBytes = bytes.len
  var opened = openSeismicBytes(bytes, ask.path, keys = true)
  let made = newSession(ask.path, opened, int64(nBytes), modified)
  clearCycleRoots()
  slot[].traces = nTraces
  slot[].samples = listen
  slot[].listenMs = float64(listen) * dtMs
  slot[].sweepMs = float64(sweepLen) * dtMs
  slot[].lines = @[
    $nTraces & " traces, " & $listen & " samples (" & msText(slot[].listenMs) &
      " ms of listen time).",
    sweepLine(slot[].sweepMs, delayed)]
  slot[].opened = made
  slot[].ok = true

proc correlateWork*(ask: sink CorrelateAsk; slot: ptr CorrelateResult): JobWork =
  ## The work of one correlation. `ask` is moved in; do not use it again.
  ## `slot` is the caller's, kept alive until the job has finished, and read
  ## only then. A cancel or a failure leaves `opened` nil and no file.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      assertWorkerThread()
      slot[].sourcePath = ask.path
      slot[].ok = false
      slot[].cancelled = false
      slot[].failure = ""
      slot[].opened = nil
      slot[].lines = @[]
      try:
        run(ask, slot, ctx)
      except JobCancelledError:
        slot[].opened = nil
        slot[].ok = false
        slot[].cancelled = true
        slot[].failure = ""
        raise
      except CatchableError:
        slot[].opened = nil
        slot[].ok = false
        slot[].cancelled = false
        let msg = getCurrentExceptionMsg()
        slot[].failure = if msg.len == 0: "the correlation failed." else: msg
        raise
      finally:
        clearCycleRoots()
