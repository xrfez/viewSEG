## Correlated samples of the traces a plot asks for, without a correlated file.
##
## `correlateWork` correlates every trace into an in-memory file. A gather of
## tens of GB cannot do that. `initCorrelateView` prepares, once, what that job
## uses for one raw file; `correlateRead` then correlates the traces it is
## asked for and copies a listen-time window into the caller's buffer.
## `readListenTraces` is that read for a whole listen trace. The
## result of a window matches that file, including the auxiliary-trace policy
## (a reference auxiliary shifted by `-AuxLeadMs`, any other auxiliary not
## correlated). Correlated samples are IEEE float32.
##
## The kernel rejects a windowed record (`firstSample != 0`), so each trace is
## read whole, correlated from sample 0, and sliced afterwards. One
## `CorrelateWorkspace` per thread; `correlateRead` allocates nothing once it
## exists. Threads share the plan and must not share a workspace.

import std/[math, sets]
import parseSEG
import processSEG
import correlatejobs, correlateview, filesystem, threads

export correlateview

type
  CorrelateWorkspace* = object
    ## Scratch for one thread's `correlateRead` calls. Move-only, like the
    ## `Workspace` it holds. `failed` is the rows of the last call that could
    ## not be read, ascending, left zero: the same mark as the reader's rows.
    ws: Workspace
    raw: Tensor[float32]
    correlated: Tensor[float32]
    key: array[1, TraceKeys]
    counts: array[1, int]
    failed*: seq[int]

proc copySamples(samples: openArray[float32]): seq[float32] =
  result = newSeq[float32](samples.len)
  for i, v in samples: result[i] = v

proc copyPath(file: ptr SeismicFile): string =
  let lent = file[].path
  result = newString(lent.len)
  for i, c in lent: result[i] = c

proc listenOrigin(file: ptr SeismicFile): float64 =
  ## Correlation does not move the origin. Listen sample 0 is the first seismic
  ## trace's finite time zero, or 0 when that trace has none.
  for t in 0 ..< file[].len:
    let k = file[].traceKeys(t)
    if k.status == tsAuxiliary: continue
    let t0 = k.t0Ms
    if t0.classify notin {fcNan, fcInf, fcNegInf}: return t0
    break
  0.0

proc initCorrelateView*(file: ptr SeismicFile; reference: openArray[float32];
    referenceDtMs: float64; referenceTraces: openArray[int]):
    tuple[view: CorrelateView; refusal: string] =
  ## The view `correlateWork` would use for `file` and this sweep, or that
  ## job's refusal (interval mismatch, a record shorter than the sweep, and
  ## the rest of its checks of the samples). The plan is prepared once.
  ## Write-only refusals (a kind that cannot be written in memory) are not
  ## repeated: nothing is written.
  if file == nil or not file[].isOpen: return (result.view, "the file is not open.")
  if not file[].hasKeys: return (result.view, "the file was opened without its keys.")
  try:
    checkReference(reference)
  except ValueError as e:
    return (result.view, e.msg)
  if referenceDtMs.isNaN or referenceDtMs <= 0 or referenceDtMs == Inf:
    return (result.view, "the reference sweep has no sample interval.")
  var shape = RecordShape(odd: @[])
  try:
    shape = recordShape(file)
  except ValueError as e:
    return (result.view, e.msg)
  discard shape.padded
  discard shape.cut
  let dtMs = shape.dtMs
  if not sameInterval(referenceDtMs, dtMs):
    return (result.view, "the reference sweep is sampled every " & msText(referenceDtMs) &
      " ms and the record every " & msText(dtMs) & " ms.")
  let recordSamples = shape.samples
  if reference.len >= recordSamples:
    return (result.view, "the reference sweep is as long as the record or longer, " &
      "so there is no listen time.")
  var refs = initHashSet[int]()
  try:
    refs = referenceSet(file[].len, referenceTraces)
  except ValueError as e:
    return (result.view, e.msg)
  var pilotSamples = copySamples(reference)
  var forPlan = pilotSamples
  var built: CorrelationPlan[float32]
  try:
    let pilot = initPilot(forPlan, referenceDtMs)
    built = initCorrelationPlan(float32, pilot, dtMs, recordSamples)
  except ValueError as e:
    return (result.view, e.msg)
  result.view.plan = new CorrelationPlan[float32]
  result.view.plan[] = built
  result.view.pilot = pilotSamples
  result.view.path = copyPath(file)
  result.view.refs = refs
  result.view.odd = initHashSet[int]()
  for t in shape.odd: result.view.odd.incl(t)
  result.view.recordSamples = recordSamples
  result.view.listenSamples = recordSamples - reference.len
  result.view.dtMs = dtMs
  result.view.t0Ms = listenOrigin(file)
  result.view.lag = wholeSamples(-AuxLeadMs, dtMs)

proc newWorkspace*(view: CorrelateView): CorrelateWorkspace =
  ## Scratch for one thread. Call it once; later `correlateRead` calls on it
  ## allocate nothing. A workspace cannot be copied.
  if view.plan != nil: result.ws.reserve(view.plan[].workspaceSize)
  if view.recordSamples > 0: result.raw = zeros[float32](1, view.recordSamples)
  if view.listenSamples > 0: result.correlated = zeros[float32](1, view.listenSamples)

proc zeroRow(dst: var openArray[float32]; at, count: int) {.inline.} =
  if count > 0: zeroMem(addr dst[at], count * sizeof(float32))

proc paint(src: ptr UncheckedArray[float32]; srcLen, firstSample, count: int;
    dst: var openArray[float32]; at: int) =
  ## Listen-time samples `firstSample ..< firstSample+count`, clamped to
  ## `0 ..< srcLen`, into `dst[at ..< at+count]`. The rest of the row stays
  ## as `zeroRow` left it.
  let start = int64(firstSample)
  let finish = start + int64(count)
  let lo = max(start, 0'i64)
  let hi = min(finish, int64(srcLen))
  if hi <= lo: return
  copyMem(addr dst[at + int(lo - start)], addr src[int(lo)], int(hi - lo) * sizeof(float32))

proc whollyOutside(firstSample, count, listen: int): bool =
  if count <= 0: return true
  let start = int64(firstSample)
  let finish = start + int64(count)
  finish <= 0 or start >= int64(listen) or min(finish, int64(listen)) <= max(start, 0'i64)

proc readOne(file: ptr SeismicFile; trace: int; ws: var CorrelateWorkspace): bool =
  ## The whole raw trace into `ws.raw`, zero-padded or cut to the record.
  ## False when it could not be decoded: the row is left zero, and this does
  ## not raise.
  if ws.raw.size > 0:
    let raw = rowBlock(ws.raw)
    zeroMem(raw.rowPtr(0), raw.cols * sizeof(float32))
  try:
    result = file[].readTracesInto([trace], ws.raw) == 0
  except CatchableError:
    result = false

proc correlateRow(view: CorrelateView; ws: var CorrelateWorkspace) =
  ws.counts[0] = view.recordSamples
  let meta = initChunkMeta(rowsOf(ws.key, ws.counts), view.dtMs)
  view.plan[].correlateInto(ws.raw, ws.correlated, meta, ws.ws)

proc fillRow(view: CorrelateView; file: ptr SeismicFile; trace, firstSample, count: int;
    dst: var openArray[float32]; at: int; ws: var CorrelateWorkspace): bool =
  ## One trace's listen-time window. False when the raw read failed.
  if not readOne(file, trace, ws): return false
  if trace in view.odd: return true
  var keys: TraceKeys
  try:
    keys = file[].traceKeys(trace)
  except CatchableError:
    return false
  let aux = keys.status == tsAuxiliary
  if aux and trace notin view.refs:
    # Not a reference: the listen window of the raw row, not the correlation.
    let raw = rowBlock(ws.raw)
    paint(raw.rowPtr(0), view.listenSamples, firstSample, count, dst, at)
    return true
  if aux and view.lag != 0:
    timeShift(rowBlock(ws.raw).row(0), view.lag)
  ws.key[0] = keys
  try:
    correlateRow(view, ws)
  except ValueError as e:
    raiseAssert e.msg
  let done = rowBlock(ws.correlated)
  paint(done.rowPtr(0), view.listenSamples, firstSample, count, dst, at)
  true

proc correlateRead*(view: CorrelateView; file: ptr SeismicFile; traces: openArray[int];
    firstSample, count: int; dst: var openArray[float32]; ws: var CorrelateWorkspace) {.
    raises: [].} =
  ## Correlates each of `traces` (the whole raw trace: the kernel rejects a
  ## window) and copies listen-time samples `firstSample ..< firstSample+count`
  ## into `dst`, `traces.len` rows of `count` float32, row-major, as the
  ## reader's sample buffer. A window past the listen time is clamped; one
  ## wholly outside it is zeros and is not read. A raw read that fails leaves
  ## that row zero and lists it in `ws.failed`, ascending, and does not raise.
  ## Allocates nothing once `ws` exists. Threads may call it together on one
  ## view when each has its own workspace.
  assertWorkerThread()
  ws.failed.setLen(0)
  doAssert view.plan != nil, "the view was refused"
  doAssert count >= 0, "count must be >= 0"
  if traces.len == 0 or count == 0:
    doAssert dst.len == 0, "dst must be traces.len * count"
    return
  doAssert traces.len <= high(int) div count, "traces.len * count overflows"
  doAssert dst.len == traces.len * count, "dst must be traces.len * count"
  let listen = view.listenSamples
  if whollyOutside(firstSample, count, listen):
    zeroMem(addr dst[0], dst.len * sizeof(float32))
    return
  var blocked = file == nil or not file[].isOpen
  if not blocked and not file[].inMemory:
    try:
      fs.mappedRead(view.path)
    except CatchableError:
      blocked = true
  let nTraces = if file == nil: 0 else: file[].len
  for r, trace in traces:
    let at = r * count
    zeroRow(dst, at, count)
    var bad = blocked or trace < 0 or trace >= nTraces
    if not bad:
      try:
        bad = not fillRow(view, file, trace, firstSample, count, dst, at, ws)
      except CatchableError:
        bad = true
    if bad: ws.failed.add r

proc readListenTraces*(view: CorrelateView; file: ptr SeismicFile; traces: openArray[int];
    dst: var openArray[float32]; ws: var CorrelateWorkspace) {.raises: [].} =
  ## Whole listen-time traces into `dst`: `traces.len` rows of
  ## `view.listenSamples`, row-major. A row that could not be read is zero and
  ## listed in `ws.failed`, ascending. `correlateRead` advises `view.path`, the
  ## raw file, not the view's virtual path.
  correlateRead(view, file, traces, 0, view.listenSamples, dst, ws)
