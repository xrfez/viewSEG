## A background job that correlates one open raw vibrator file with a reference
## sweep into a new in-memory seismic file of the listen time only: the record
## length minus the sweep length. The record length is the seismic traces'
## sample count. An auxiliary trace of another length is padded or cut to that
## count before it is handled; one whose sample interval differs is written
## as zeros of the listen length.
##
## Submit `correlateWork` on the background lane, cancellable, with the source
## path in `reads`, and keep the open file alive until the job has finished.
## `opened` is in memory (`inMemory`). Its path is the source path, which is
## where the headers were read, not where the correlated samples live. The next
## task adopts that file in place of the raw one: register a new id, and do not
## watch the path as if the correlated bytes had been written there.
##
## Correlated samples are IEEE float32 (SEG-Y format code 5), whatever the
## source sample format, and the binary header's format code matches each
## trace. A different sample count is kept and the trace headers are the
## source's, except the correlated flag (byte 125, `trace.correlated`), which
## is set to yes (2). The binary header's copy (byte 3249) is left as it was.
## SEG-D cannot change a trace's sample
## count, so it is written from keys: the channel type is the source trace's
## (0 means seismic), and channel-set descriptors, external headers,
## general-header blocks and trace-header extensions are not copied. A start
## time the headers cannot give may read back as 0. SEG-2 cannot be written
## in memory.
##
## `correlatedBytesEstimate` is the byte length that in-memory copy would have.
## The job still writes the copy; `fitsInMemory` is how a caller decides whether
## it fits.

import std/[algorithm, cpuinfo, formatfloat, math, sets, strutils]
import parseSEG
import parseSEG/model/traceindex
import processSEG
import cutfile, filesystem, jobs, processing, references, session, threads, traceids

const
  AuxLeadMs* = 500.0
    ## Reference auxiliary traces are shifted later by this many milliseconds
    ## before they are correlated: zeros in front, the end cut, the record
    ## length kept, then the same reference and the same listen length, so
    ## both sides of the wavelet show.
  BlockTraces = 64
  CorrelatedYes* = 2 ## SEG-Y trace header byte 125: 2 = yes.

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

proc msText*(ms: float64): string =
  ## The interval in ms, trailing zeros dropped, so a refusal reads the same
  ## wherever it is built.
  var s = formatFloat(ms, ffDecimal, 6)
  if '.' in s:
    while s.len > 0 and s[^1] == '0': s.setLen(s.len - 1)
    if s.len > 0 and s[^1] == '.': s.setLen(s.len - 1)
  if s.len == 0: "0" else: s

proc refuse(msg: string) {.noinline, noreturn.} =
  raise newException(ValueError, msg)

proc traceDt*(file: ptr SeismicFile; trace: int): float64 =
  ## The trace's sample interval in ms, or NaN when it has none.
  let us = file[].traceKeys(trace).intervalUs
  let got = if us > 0 and us < Inf: us else: file[].sampleIntervalUs(trace)
  if got.isNaN or got <= 0 or got == Inf: NaN else: got / 1000.0

type
  RecordShape* = object
    ## The seismic traces' length and interval. `padded` and `cut` count
    ## auxiliary traces fitted to that length. `odd` lists auxiliary traces
    ## at another interval.
    samples*: int
    dtMs*: float64
    padded*, cut*: int
    odd*: seq[int]

proc isSeismic*(status: TraceStatus): bool {.inline.} =
  ## A trace that is not auxiliary.
  status != tsAuxiliary

proc recordShape*(file: ptr SeismicFile): RecordShape =
  ## The seismic traces' length and interval. A shorter or longer auxiliary
  ## trace is counted as padded or cut; one at another known interval is
  ## listed in `odd` and not counted.
  let n = file[].len
  if n == 0: refuse("the file has no traces.")
  result.odd = @[]
  var seismic = 0
  for i in 0 ..< n:
    if not isSeismic(file[].traceKeys(i).status): continue
    let d = traceDt(file, i)
    let samples = int(file[].traceEntry(i).numSamples)
    if seismic == 0:
      if d.isNaN: refuse("the file has no sample interval.")
      result.samples = samples
      result.dtMs = d
    else:
      if samples != result.samples:
        refuse("the seismic traces do not share one length.")
      if d.isNaN or not sameInterval(d, result.dtMs):
        refuse("the traces do not share one sample interval.")
    inc seismic
  if seismic == 0: refuse("the file has no seismic traces.")
  for i in 0 ..< n:
    if isSeismic(file[].traceKeys(i).status): continue
    let d = traceDt(file, i)
    if not d.isNaN and not sameInterval(d, result.dtMs):
      result.odd.add i
    else:
      let samples = int(file[].traceEntry(i).numSamples)
      if samples < result.samples: inc result.padded
      elif samples > result.samples: inc result.cut

proc checkReference*(samples: openArray[float32]) =
  ## Refuses an empty sweep, one of a single sample, one with a sample that
  ## is not a number, or one that is all zeros.
  if samples.len == 0: refuse("the reference sweep is empty.")
  if samples.len < 2: refuse("the reference sweep needs at least two samples.")
  var energy = 0.0
  for i, v in samples:
    let x = float64(v)
    if x.isNaN or abs(x) == Inf:
      refuse("the reference sweep has a sample that is not a number.")
    energy += x * x
  if energy == 0: refuse("the reference sweep is all zeros.")

proc referenceSet*(n: int; traces: openArray[int]): HashSet[int] =
  ## The reference traces, or the refusal a repeated or out-of-range index gets.
  result = initHashSet[int]()
  for t in traces:
    if t < 0 or t >= n:
      refuse("reference trace " & $t & " is outside 0 .. " & $(n - 1) & ".")
    if t in result: refuse("reference trace " & $t & " is listed twice.")
    result.incl(t)

type
  ListenShape* = object
    ## The record a correlation writes. `samples` is the seismic length;
    ## `listen` is that length minus the sweep. `odd` lists auxiliary traces
    ## at another interval. `padded` and `cut` count auxiliary traces fitted
    ## to the seismic length.
    samples*: int
    dtMs*: float64
    listen*: int
    odd*: seq[int]
    padded*: int
    cut*: int

proc listenShape*(file: ptr SeismicFile; reference: openArray[float32];
    referenceDtMs: float64): ListenShape =
  ## What `correlateWork` needs before it writes, or the same refusal.
  ## A record that is not longer than the sweep, or a sample interval that
  ## differs, is refused here. No file is written.
  checkReference(reference)
  if referenceDtMs.isNaN or referenceDtMs <= 0 or referenceDtMs == Inf:
    refuse("the reference sweep has no sample interval.")
  let shape = recordShape(file)
  if not sameInterval(referenceDtMs, shape.dtMs):
    refuse("the reference sweep is sampled every " & msText(referenceDtMs) &
      " ms and the record every " & msText(shape.dtMs) & " ms.")
  if reference.len >= shape.samples:
    refuse("the reference sweep is as long as the record or longer, " &
      "so there is no listen time.")
  result.samples = shape.samples
  result.dtMs = shape.dtMs
  result.listen = shape.samples - reference.len
  result.odd = shape.odd
  result.padded = shape.padded
  result.cut = shape.cut

proc addSat(a, b: int64): int64 {.inline.} =
  if b > 0 and a > high(int64) - b: high(int64) else: a + b

proc mulSat(a, b: int64): int64 {.inline.} =
  if a > 0 and b > high(int64) div a: high(int64) else: a * b

proc bytesOfListen(file: ptr SeismicFile; listen: int): int64 =
  ## Headers the open file is not using for samples, plus `listen` IEEE
  ## float32 samples on every trace. A SEG-Y writer keeps those headers and
  ## replaces the sample bytes, so this is that file's length. A count that
  ## would overflow is `high(int64)`, which does not fit in memory.
  let n = file[].len
  var payload = 0'i64
  let ix = file[].index
  for i in 0 ..< n:
    payload = addSat(payload, int64(ix.dataBytes(i)))
  var headers = 0'i64
  let mapped = file[].mappedSize
  if mapped > payload: headers = mapped - payload
  let samples = mulSat(int64(n), int64(listen))
  addSat(headers, mulSat(samples, 4))

type
  ListenCount = concept v
    v.listenSamples is int

proc correlatedBytesEstimate*(file: ptr SeismicFile; sweepLen: int): int64 =
  ## Bytes the in-memory correlated copy of `file` would have for a sweep of
  ## `sweepLen` samples. Listen time is the record length minus the sweep, as
  ## `correlateWork` writes it. Raises `ValueError` for a closed file, a file
  ## the job would refuse, or a sweep that leaves no listen time.
  if file == nil or not file[].isOpen: refuse("the file is not open.")
  let shape = recordShape(file)
  if sweepLen < 0 or sweepLen >= shape.samples:
    refuse("the reference sweep is as long as the record or longer, " &
      "so there is no listen time.")
  bytesOfListen(file, shape.samples - sweepLen)

proc correlatedBytesEstimate*(file: ptr SeismicFile; view: ListenCount): int64 =
  ## Bytes the in-memory copy would have for a view already built: its
  ## `listenSamples`, not a sweep length recomputed here. Raises `ValueError`
  ## for a closed file or a view that was not built.
  if file == nil or not file[].isOpen: refuse("the file is not open.")
  let listen = view.listenSamples
  if listen <= 0: refuse("the correlated view was not built.")
  bytesOfListen(file, listen)

proc fitsInMemory*(estimate, limit: int64): bool {.inline.} =
  ## Whether a correlated copy of `estimate` bytes is at most `limit` (pass
  ## `MaxPrepareBytes`). A negative estimate does not fit.
  estimate >= 0 and estimate <= limit

proc wholeMicroseconds*(dtMs: float64): float64 =
  ## The interval in microseconds, or the refusal a SEG-D correlation write
  ## gives when it is not a whole number the writer can store.
  result = round(dtMs * 1000.0)
  if result != dtMs * 1000.0 or result < 1 or result > float64(high(uint32)):
    refuse("the sample interval is not a whole number of microseconds, " &
      "so the file cannot be written.")

proc firstTime(file: ptr SeismicFile): float64 =
  result = NaN
  for i in 0 ..< file[].len:
    let t = file[].traceKeys(i).time
    if not t.isNaN and t != Inf and t != -Inf: return t

proc openOut(file: ptr SeismicFile; name: string; listen: int; dtMs, time: float64):
    SeismicWriter =
  case file[].kind
  of skSegy:
    result = openSeismicWriterBytes(file[], name, segyFormat = st5)
  of skSegd:
    let us = wholeMicroseconds(dtMs)
    let sum = file[].summary
    var units = sum.coordinateUnits
    if units notin {cuMeters, cuFeet, cuUnknown}: units = cuUnknown
    var crs = ""
    if sum.crsFormat != ctNone: crs = file[].crsText
    result = openSeismicWriterBytes(SegdOutputOptions(sampleIntervalUs: us,
      numSamples: listen, units: units, crsText: crs, time: time), name)
  of skSeg2, skUnknown:
    refuse("the file cannot be written in memory.")

proc writtenChannelType*(code: uint8): SegdChannelType =
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

proc sweepLine(sweepMs: float64; delayed: int; delayMs: float64): string =
  let n = if delayed == 1: "1 reference trace" else: $delayed & " reference traces"
  "sweep " & msText(sweepMs) & " ms. " & n & " delayed by " & msText(delayMs) & " ms."

proc waveletLine(listenMs, delayMs: float64): string =
  if listenMs <= delayMs:
    "listen time " & msText(listenMs) &
      " ms: the reference wavelet's peak (at " & msText(delayMs) &
      " ms) is outside the record."
  else:
    "listen time " & msText(listenMs) &
      " ms: the reference wavelet shows only " & msText(listenMs - delayMs) &
      " ms after its peak."

proc fitLine(padded, cut: int): string =
  var parts: seq[string] = @[]
  if padded == 1: parts.add "1 auxiliary trace was padded"
  elif padded > 1: parts.add $padded & " auxiliary traces were padded"
  if cut == 1: parts.add "1 auxiliary trace was cut"
  elif cut > 1: parts.add $cut & " auxiliary traces were cut"
  if parts.len > 0: result = parts.join(". ") & "."

proc cutSweepLine(trace: int; heldMs, sweepMs, leadMs: float64): string =
  "reference trace " & $trace & " holds " & msText(heldMs) &
    " ms, less than the " & msText(sweepMs) & " ms sweep plus the " &
    msText(leadMs) & " ms lead: its wavelet is of a cut sweep."

proc intervalLine(trace: int; reference: bool; traceMs, recordMs: float64): string =
  let kind = if reference: "reference" else: "auxiliary"
  let tail = if reference: "not correlated, written as zeros." else: "written as zeros."
  kind & " trace " & $trace & " is sampled every " & msText(traceMs) &
    " ms, the record every " & msText(recordMs) & " ms: " & tail

proc alreadyCorrelated*(file: ptr SeismicFile): bool =
  ## Whether the file's own headers say the data are already correlated.
  ## SEG-Y: binary header byte 3249, or trace header byte 125 of the first
  ## seismic trace, is 2. Another kind: that field when the headers have it,
  ## otherwise nothing.
  if file == nil: return false
  let binary = file[].fileField("binary.correlated")
  if binary.kind == fvInt and binary.intVal == CorrelatedYes: return true
  if file[].kind != skSegy: return false
  for t in 0 ..< file[].len:
    if file[].traceKeys(t).status != tsAuxiliary:
      let v = file[].traceField(t, "trace.correlated")
      return v.kind == fvInt and v.intVal == CorrelatedYes
  false

proc binaryUncorrelatedLine*(file: ptr SeismicFile): string =
  ## Empty unless the SEG-Y binary header says the data are not correlated.
  ## That copy (byte 3249) has no override in this writer. It reads the
  ## file's header: raises `SegTruncatedError` for a file found cut short.
  if file[].kind != skSegy: return
  let v = file[].fileField("binary.correlated")
  if v.kind == fvInt and v.intVal == 1:
    result = "the binary header still says the data are not correlated " &
      "(byte 3249 is 1); this writer cannot change it."

proc correlationLines*(file: ptr SeismicFile; nTraces, listen, sweepLen: int;
    listenMs, sweepMs, dtMs: float64; delayed, leadSamples, padded, cut: int;
    refs: HashSet[int]; odd: openArray[int]): seq[string] =
  ## The notes `correlateWork` gives for this file, in its order, but the
  ## binary header's (`binaryUncorrelatedLine`, which follows them). Only the
  ## in-memory index and keys are read. `odd` is that job's list, so an
  ## odd-interval note keeps its place.
  let leadMs = float64(leadSamples) * dtMs
  var oddSet = initHashSet[int]()
  for t in odd: oddSet.incl(t)
  result = @[
    $nTraces & " traces, " & $listen & " samples (" & msText(listenMs) &
      " ms of listen time).",
    sweepLine(sweepMs, delayed, leadMs)]
  if delayed > 0 and listenMs < 2.0 * leadMs:
    result.add waveletLine(listenMs, leadMs)
  let fitted = fitLine(padded, cut)
  if fitted.len > 0: result.add fitted
  for t in 0 ..< nTraces:
    if t in refs and file[].traceKeys(t).status == tsAuxiliary and t notin oddSet:
      let held = int(file[].traceEntry(t).numSamples)
      if held < sweepLen + leadSamples:
        result.add cutSweepLine(t, float64(held) * dtMs, sweepMs, leadMs)
  for t in odd:
    result.add intervalLine(t, t in refs, traceDt(file, t), dtMs)

proc unreadWhy*(file: SeismicFile): string =
  ## Why a trace of `file` could not be read, in the words `correlateWork`
  ## fails with: the file was cut short or its drive failed (`cutWhy`), or
  ## "a trace could not be read."
  let why = cutWhy(file)
  if why.len > 0: why else: "a trace could not be read."

proc writeRow(w: var SeismicWriter; file: ptr SeismicFile; trace, row, listen: int;
    src, dst: Tensor[float32]; keys: TraceKeys; fromSrc, segd: bool; intervalUs: float64) =
  if segd:
    var k = keys
    k.intervalUs = intervalUs
    let ct = writtenChannelType(file[].traceEntry(trace).channelType)
    let rows = if fromSrc: rowBlock(src) else: rowBlock(dst)
    w.writeTrace(k, rows.row(row, listen), channelType = ct)
  elif fromSrc:
    w.writeTrace(file[], trace, src, row, count = listen,
      overrides = [headerOverride("trace.correlated", CorrelatedYes)])
  else:
    w.writeTrace(file[], trace, dst, row, count = listen,
      overrides = [headerOverride("trace.correlated", CorrelatedYes)])

proc run(ask: CorrelateAsk; slot: ptr CorrelateResult; ctx: JobContext) =
  if ask.path.len == 0: refuse("the file has no path.")
  let file = ask.file
  if file == nil or not file[].isOpen: refuse("the file is not open.")
  if file[].kind in {skSeg2, skUnknown}: refuse("the file cannot be written in memory.")
  if not file[].hasKeys: refuse("the file was opened without its keys.")
  fs.mappedRead(ask.path)
  let modified = fs.getFileInfo(ask.path).lastWriteTime
  let ready = listenShape(file, ask.reference, ask.referenceDtMs)
  let dtMs = ready.dtMs
  let nTraces = file[].len
  let recordSamples = ready.samples
  var odd = initHashSet[int]()
  for t in ready.odd: odd.incl(t)
  let sweepLen = ask.reference.len
  let listen = ready.listen
  let refs = referenceSet(nTraces, ask.referenceTraces)
  var delayed = 0
  for t in ask.referenceTraces:
    if file[].traceKeys(t).status == tsAuxiliary and t notin odd: inc delayed
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
    if failed.len > 0: refuse(unreadWhy(file[]))
    file[].traceKeysInto(span, keys.toOpenArray(0, n - 1))
    if lag != 0:
      let rows = rowBlock(src)
      for r in 0 ..< n:
        let trace = start + r
        if trace in refs and keys[r].status == tsAuxiliary and trace notin odd:
          timeShift(rows.row(r), lag)
    for r in 0 ..< n:
      let trace = start + r
      workKeys[r] = keys[r]
      if keys[r].status == tsAuxiliary and (trace notin refs or trace in odd):
        workKeys[r].status = tsDead
      counts[r] = recordSamples
    let meta = initChunkMeta(rowsOf(workKeys.toOpenArray(0, n - 1),
      counts.toOpenArray(0, n - 1)), dtMs, failed = failed)
    pool.correlateInto(plan, rowBlock(src).sub(0 ..< n), rowBlock(dst).sub(0 ..< n), meta)
    for r in 0 ..< n:
      let trace = start + r
      let fromSrc = keys[r].status == tsAuxiliary and trace notin refs and trace notin odd
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
  let leadSamples = abs(lag)
  slot[].lines = correlationLines(file, nTraces, listen, sweepLen, slot[].listenMs,
    slot[].sweepMs, dtMs, delayed, leadSamples, ready.padded, ready.cut, refs, ready.odd)
  let uncorrelated = binaryUncorrelatedLine(file)
  if uncorrelated.len > 0: slot[].lines.add uncorrelated
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

type
  CorrelateLoad* = object
    ## The reference `correlateLoaded` reads before `correlateWork`. An archive
    ## file is `refPath`. A pilot is `pilotTrace` (0 or above) with `pilot`.
    refPath*: string
    pilotTrace*: int
    pilot*: PilotRule
    flip*: bool ## the trace's own reversal, before the cut; not reverse-all
    shiftMs*: float64
    record*: string

proc loadSweep(file: ptr SeismicFile; path: string; load: CorrelateLoad):
    tuple[samples: seq[float32]; dtMs: float64] =
  ## The sweep `load` names, and its sample interval in ms. Raises when it
  ## cannot be read. On the worker: `readReferenceFile` and `readRawTrace` assert that.
  if load.refPath.len > 0:
    let read = readReferenceFile(load.refPath)
    if read.samples.len == 0:
      raise newException(ValueError, "the reference file has no sample.")
    let dt = if read.intervalUs > 0 and read.intervalUs < Inf: read.intervalUs / 1000.0
             else: 0.0
    return (read.samples, dt)
  if load.pilotTrace < 0:
    raise newException(ValueError, "no reference was given.")
  var samples = readRawTrace(file, path, load.pilotTrace)
  var us = 0.0
  let k = file[].traceKeys(load.pilotTrace)
  us = if k.intervalUs > 0 and k.intervalUs < Inf: k.intervalUs
       else: file[].sampleIntervalUs(load.pilotTrace)
  if samples.len == 0:
    raise newException(IOError, "the trace could not be read.")
  let dt = if us > 0 and us < Inf: us / 1000.0 else: 0.0
  if load.flip:
    for v in samples.mitems: v = -v
  applyStoredShift(samples, load.shiftMs, dt)
  let (cut, problem) = cutPilot(samples, dt, load.pilot, load.record)
  if problem.len > 0: raise newException(ValueError, problem)
  (turnedOver(cut, load.pilot), dt)

proc referenceTraces*(file: ptr SeismicFile): seq[int] =
  ## Auxiliary traces that hold a reference: trace code 5, or a vibrator reference (21).
  ## The keys already read; no file is opened.
  result = @[]
  if file == nil: return
  for t in 0 ..< file[].len:
    let k = file[].traceKeys(t)
    if k.status == tsAuxiliary and (k.traceCode == 5'i16 or k.traceCode == VibReferenceCode):
      result.add t

proc seismicDtMs*(file: ptr SeismicFile): float64 =
  ## The seismic traces' sample interval, from keys already read; NaN when none is known.
  if file == nil: return NaN
  for t in 0 ..< file[].len:
    let k = file[].traceKeys(t)
    if k.status != tsAuxiliary and k.intervalUs > 0 and k.intervalUs < Inf:
      return k.intervalUs / 1000.0
  NaN

proc correlateLoaded*(ask: sink CorrelateAsk; load: CorrelateLoad;
    slot: ptr CorrelateResult): JobWork =
  ## Loads the reference `load` names, then runs `correlateWork`. `slot` is
  ## the caller's and must stay alive until the job has finished. A reference
  ## that cannot be read fails the job and leaves `opened` nil.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var ready = ask
    var got: tuple[samples: seq[float32]; dtMs: float64]
    try:
      {.cast(gcsafe).}:
        assertWorkerThread()
        got = loadSweep(ready.file, ready.path, load)
      ready.reference = got.samples
      ready.referenceDtMs = got.dtMs
    except CatchableError as e:
      slot[].ok = false
      slot[].cancelled = false
      slot[].opened = nil
      let msg = e.msg
      slot[].failure = if msg.len == 0: "the reference could not be read." else: msg
      raise
    correlateWork(ready, slot)(ctx)
