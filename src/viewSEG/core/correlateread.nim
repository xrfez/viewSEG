## Correlated samples of the traces a plot asks for, without a correlated file.
##
## `correlateWork` correlates every trace into an in-memory file. A gather of
## tens of GB cannot do that. `initCorrelateView` prepares, once, what that job
## uses for one raw file; `correlateRead` then correlates the traces it is
## asked for and copies a listen-time window into the caller's buffer.
## `correlateBlock` is the same for a block of rows at once, across a pool's
## workers. `readListenTraces` is that read for a whole listen trace. The
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
import correlatejobs, correlateview, filesystem, jobs, threads

export correlateview

type
  RowFailure* = enum
    ## Why a row of `correlateRead` could not be read.
    rfOther      ## not decoded, or not a trace of the file
    rfCutShort   ## the file was cut short by another program while it was open
    rfReadFailed ## a read of the file failed (its drive)

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
    why*: seq[RowFailure] ## `failed`'s reasons, element for element
    blockSrc: Tensor[float32] ## `correlateBlock`'s raw rows, grown on demand
    blockDst: Tensor[float32]
    blockKeys: seq[TraceKeys]
    blockCounts: seq[int]
    blockTraces: seq[int] ## the file trace of each row sent to the pool
    blockRows: seq[int] ## the request row of each of those
    blockReadFailed: seq[int] ## rows of those the read could not decode
    blockOut: seq[int] ## rows of those the pool must not use
    blockRaw: seq[bool] ## rows of those answered with their raw samples
    rowBad: seq[bool] ## per request row, and why
    rowWhy: seq[RowFailure]

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

proc readOne(file: ptr SeismicFile; trace: int; ws: var CorrelateWorkspace;
    why: var RowFailure): bool =
  ## The whole raw trace into `ws.raw`, zero-padded or cut to the record.
  ## False when it could not be decoded: the row is left zero, `why` says
  ## why, and this does not raise.
  if ws.raw.size > 0:
    let raw = rowBlock(ws.raw)
    zeroMem(raw.rowPtr(0), raw.cols * sizeof(float32))
  var log: DiagLog
  try:
    result = file[].readTracesInto([trace], ws.raw, log) == 0
  except IOError, OSError:
    (result, why) = (false, rfReadFailed)
  except CatchableError:
    (result, why) = (false, rfOther)
  if not result and why == rfOther:
    for d in log:
      if d.code == dcTruncated: why = rfCutShort
      elif d.code == dcIo: why = rfReadFailed

proc correlateRow(view: CorrelateView; ws: var CorrelateWorkspace) =
  ws.counts[0] = view.recordSamples
  let meta = initChunkMeta(rowsOf(ws.key, ws.counts), view.dtMs)
  view.plan[].correlateInto(ws.raw, ws.correlated, meta, ws.ws)

proc fillRow(view: CorrelateView; file: ptr SeismicFile; trace, firstSample, count: int;
    dst: var openArray[float32]; at: int; ws: var CorrelateWorkspace;
    why: var RowFailure): bool =
  ## One trace's listen-time window. False when the raw read failed.
  if not readOne(file, trace, ws, why): return false
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

type ReadStart = object
  go: bool ## false when nothing is left to read (empty or wholly outside)
  blocked, driveFailed: bool
  nTraces: int

proc startRead(view: CorrelateView; file: ptr SeismicFile; traces: openArray[int];
    firstSample, count: int; dst: var openArray[float32];
    ws: var CorrelateWorkspace): ReadStart =
  ## What `correlateRead` and `correlateBlock` check and settle before a row:
  ## the arguments, a window with nothing to read (its rows are zero), and
  ## whether the file or its drive is already unusable.
  ws.failed.setLen(0)
  ws.why.setLen(0)
  doAssert view.plan != nil, "the view was refused"
  doAssert count >= 0, "count must be >= 0"
  if traces.len == 0 or count == 0:
    doAssert dst.len == 0, "dst must be traces.len * count"
    return
  doAssert traces.len <= high(int) div count, "traces.len * count overflows"
  doAssert dst.len == traces.len * count, "dst must be traces.len * count"
  if whollyOutside(firstSample, count, view.listenSamples):
    zeroMem(addr dst[0], dst.len * sizeof(float32))
    return
  result.go = true
  result.blocked = file == nil or not file[].isOpen
  if not result.blocked and not file[].inMemory:
    try:
      fs.mappedRead(view.path)
    except CatchableError:
      (result.blocked, result.driveFailed) = (true, true)
  result.nTraces = if file == nil: 0 else: file[].len

proc tryRow(view: CorrelateView; file: ptr SeismicFile; trace, r, firstSample, count: int;
    st: ReadStart; dst: var openArray[float32]; ws: var CorrelateWorkspace;
    why: var RowFailure): bool =
  ## Request row `r` (trace `trace`) by itself, zeroed first, then filled.
  ## False, with `why`, when it could not be read.
  zeroRow(dst, r * count, count)
  let bad = st.blocked or trace < 0 or trace >= st.nTraces
  why = if st.driveFailed: rfReadFailed else: rfOther
  if bad: return false
  try:
    result = fillRow(view, file, trace, firstSample, count, dst, r * count, ws, why)
  except IOError, OSError:
    (result, why) = (false, rfReadFailed)
  except CatchableError:
    result = false

proc correlateRead*(view: CorrelateView; file: ptr SeismicFile; traces: openArray[int];
    firstSample, count: int; dst: var openArray[float32]; ws: var CorrelateWorkspace) {.
    raises: [].} =
  ## Correlates each of `traces` (the whole raw trace: the kernel rejects a
  ## window) and copies listen-time samples `firstSample ..< firstSample+count`
  ## into `dst`, `traces.len` rows of `count` float32, row-major, as the
  ## reader's sample buffer. A window past the listen time is clamped; one
  ## wholly outside it is zeros and is not read. A raw read that fails leaves
  ## that row zero and lists it in `ws.failed`, ascending (`ws.why`: why), and does not
  ## raise.
  ## Allocates nothing once `ws` exists. Threads may call it together on one
  ## view when each has its own workspace.
  assertWorkerThread()
  let st = startRead(view, file, traces, firstSample, count, dst, ws)
  if st.go:
    for r, trace in traces:
      var why = rfOther
      if not tryRow(view, file, trace, r, firstSample, count, st, dst, ws, why):
        ws.failed.add r
        ws.why.add why

const
  BlockBudget* = 32 * 1024 * 1024    ## bytes a block's raw and correlated rows may hold
  BlockMostRows* = 256
  BlockLeastRows* = 8                ## one lane batch of the kernel
  BlockHardLimit = 256 * 1024 * 1024 ## past it even `BlockLeastRows` rows are too many

func blockRows*(recordSamples, listenSamples: int): int =
  ## How many rows one `correlateBlock` call should take for a record of
  ## `recordSamples` and a listen time of `listenSamples`: as many as
  ## `BlockBudget` bytes hold of raw plus correlated float32 rows, from
  ## `BlockLeastRows` to `BlockMostRows`; 1 when even the least would pass
  ## `BlockHardLimit`. The workspace's scratch is that big, and a newer request
  ## waits for at most one block.
  const Huge = 1'i64 shl 40 # keeps the sum from overflowing
  let row = 4 * (clamp(int64(recordSamples), 0'i64, Huge) +
    clamp(int64(listenSamples), 0'i64, Huge))
  if row <= 0: return BlockMostRows
  if row * BlockLeastRows > BlockHardLimit: return 1
  int(clamp(BlockBudget div row, int64(BlockLeastRows), int64(BlockMostRows)))

func blockRows*(view: CorrelateView): int =
  blockRows(view.recordSamples, view.listenSamples)

proc blockOf(t: Tensor[float32]): RowBlock[float32] =
  try:
    result = rowBlock(t)
  except ValueError as e:
    raiseAssert e.msg # a tensor of rows

proc keptRaw(view: CorrelateView; keys: TraceKeys; trace: int): bool {.inline.} =
  ## An auxiliary trace that is not a reference: its raw samples are the answer.
  keys.status == tsAuxiliary and trace notin view.refs

proc correlateBlock*(view: CorrelateView; file: ptr SeismicFile; traces: openArray[int];
    firstSample, count: int; dst: var openArray[float32]; ws: var CorrelateWorkspace;
    pool: ProcessPool) {.raises: [].} =
  ## `correlateRead` for a block of rows: the raw traces are read together at
  ## the full record width and correlated across `pool`'s workers, then each
  ## row's listen window is sliced into `dst`. The samples, the failed rows
  ## (`ws.failed`, `ws.why`) and the auxiliary-trace policy are those of
  ## `correlateRead` row by row. Allocates only while `ws` grows to a larger
  ## block. A block of 64 to 256 rows keeps every worker busy.
  assertWorkerThread()
  let st = startRead(view, file, traces, firstSample, count, dst, ws)
  if not st.go: return
  let n = traces.len
  ws.blockTraces.setLen(0)
  ws.blockRows.setLen(0)
  ws.rowBad.setLen(n)
  ws.rowWhy.setLen(n)
  for r, trace in traces:
    zeroRow(dst, r * count, count)
    ws.rowBad[r] = st.blocked or trace < 0 or trace >= st.nTraces
    ws.rowWhy[r] = if st.driveFailed: rfReadFailed else: rfOther
    if not ws.rowBad[r]:
      ws.blockTraces.add trace
      ws.blockRows.add r
  let m = ws.blockTraces.len
  var done = m == 0
  if not done:
    if ws.blockSrc.size == 0 or ws.blockSrc.shape[0] < m:
      ws.blockSrc = zeros[float32](m, view.recordSamples)
      ws.blockDst = zeros[float32](m, view.listenSamples)
    ws.blockReadFailed.setLen(0)
    try:
      discard file[].readTracesInto(ws.blockTraces, ws.blockSrc, ws.blockReadFailed)
    except CatchableError:
      # The read raised: each row goes alone, so only the one that fails is lost.
      for j in 0 ..< m:
        ws.rowBad[ws.blockRows[j]] = not tryRow(view, file, ws.blockTraces[j],
          ws.blockRows[j], firstSample, count, st, dst, ws, ws.rowWhy[ws.blockRows[j]])
      done = true
  if not done:
    ws.blockKeys.setLen(m)
    ws.blockCounts.setLen(m)
    ws.blockRaw.setLen(m)
    ws.blockOut.setLen(0)
    let src = blockOf(ws.blockSrc)
    var next = 0 # the cursor in the ascending `blockReadFailed`
    for j in 0 ..< m:
      let trace = ws.blockTraces[j]
      ws.blockCounts[j] = view.recordSamples
      ws.blockKeys[j] = initTraceKeys()
      ws.blockRaw[j] = false
      var unusable = false
      if next < ws.blockReadFailed.len and ws.blockReadFailed[next] == j:
        inc next
        unusable = true
        # The row goes through the per-row path again, for its reason (a second
        # read may succeed: then it is painted there and the pool skips it).
        let r = ws.blockRows[j]
        ws.rowBad[r] = not tryRow(view, file, trace, r, firstSample, count, st, dst, ws,
          ws.rowWhy[r])
      else:
        try:
          ws.blockKeys[j] = file[].traceKeys(trace)
        except CatchableError:
          unusable = true
          ws.rowBad[ws.blockRows[j]] = true
      if unusable:
        ws.blockOut.add j
      else:
        let keys = ws.blockKeys[j]
        ws.blockRaw[j] = keptRaw(view, keys, trace)
        if trace in view.odd or ws.blockRaw[j]:
          ws.blockKeys[j].status = tsDead
        elif keys.status == tsAuxiliary and view.lag != 0:
          timeShift(src.row(j), view.lag)
    if m > ws.blockOut.len:
      try:
        let meta = initChunkMeta(rowsOf(ws.blockKeys.toOpenArray(0, m - 1),
          ws.blockCounts.toOpenArray(0, m - 1)), view.dtMs, failed = ws.blockOut)
        pool.correlateInto(view.plan[], src.sub(0 ..< m), blockOf(ws.blockDst).sub(0 ..< m),
          meta)
      except ValueError as e:
        raiseAssert e.msg
      let corr = blockOf(ws.blockDst)
      var skip = 0 # the cursor in the ascending `blockOut`
      for j in 0 ..< m:
        if skip < ws.blockOut.len and ws.blockOut[skip] == j: inc skip
        elif ws.blockTraces[j] notin view.odd: # an odd trace stays zero
          let at = ws.blockRows[j] * count
          let source = if ws.blockRaw[j]: src.rowPtr(j) else: corr.rowPtr(j)
          paint(source, view.listenSamples, firstSample, count, dst, at)
  for r in 0 ..< n:
    if ws.rowBad[r]:
      ws.failed.add r
      ws.why.add ws.rowWhy[r]

proc readListenTraces*(view: CorrelateView; file: ptr SeismicFile; traces: openArray[int];
    dst: var openArray[float32]; ws: var CorrelateWorkspace) {.raises: [].} =
  ## Whole listen-time traces into `dst`: `traces.len` rows of
  ## `view.listenSamples`, row-major. A row that could not be read is zero and
  ## listed in `ws.failed`, ascending. `correlateRead` advises `view.path`, the
  ## raw file, not the view's virtual path.
  correlateRead(view, file, traces, 0, view.listenSamples, dst, ws)

proc readListenChunk*(view: CorrelateView; file: ptr SeismicFile; part: Slice[int];
    ws: var CorrelateWorkspace): Tensor[float32] {.raises: [].} =
  ## The whole listen-time traces `part` as a tensor of `part.len` rows of
  ## `view.listenSamples`. A row that could not be read is zero and is in
  ## `ws.failed` (0-based in `part`), as for `readListenTraces`.
  let rows = part.len
  var idx = newSeq[int](rows)
  for i in 0 ..< rows: idx[i] = part.a + i
  var buf = newSeq[float32](rows * view.listenSamples)
  readListenTraces(view, file, idx, buf, ws)
  result = zeros[float32](rows, view.listenSamples)
  if buf.len > 0:
    try:
      copyMem(rowBlock(result).rowPtr(0), addr buf[0], buf.len * sizeof(float32))
    except ValueError as e:
      raiseAssert e.msg # a tensor of rows

proc correlateOrView*(ask: sink CorrelateAsk; load: CorrelateLoad; limit: int64;
    slot: ptr CorrelateResult): JobWork =
  ## `correlateLoaded`, unless the correlated copy would be more than `limit` bytes
  ## (`fitsInMemory`): then no copy is made and `slot` gets the prepared `view`
  ## (`onDemand`, `opened` nil) with the same report lines, or the refusal the job gives.
  ## `slot` is the caller's and must stay alive until the job has finished.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var ready = ask
    var estimate = -1'i64
    try:
      {.cast(gcsafe).}:
        assertWorkerThread()
        let got = loadSweep(ready.file, ready.path, load)
        ready.reference = got.samples
        ready.referenceDtMs = got.dtMs
        try:
          estimate = correlatedBytesEstimate(ready.file, ready.reference.len)
        except ValueError:
          estimate = -1 # the copy's own job gives the refusal
    except CatchableError as e:
      slot[].ok = false
      slot[].cancelled = false
      slot[].opened = nil
      slot[].failure = if e.msg.len == 0: "the reference could not be read." else: e.msg
      raise
    if estimate < 0 or fitsInMemory(estimate, limit):
      correlateWork(ready, slot)(ctx)
      return
    {.cast(gcsafe).}:
      slot[].sourcePath = ready.path
      slot[].ok = false
      slot[].cancelled = false
      slot[].failure = ""
      slot[].opened = nil
      slot[].lines = @[]
      slot[].onDemand = false
      ctx.checkCancelled()
      let made = initCorrelateView(ready.file, ready.reference, ready.referenceDtMs,
        ready.referenceTraces)
      if made.refusal.len > 0:
        slot[].failure = made.refusal
        raise newException(ValueError, made.refusal)
      let shape = listenShape(ready.file, ready.reference, ready.referenceDtMs)
      let refs = referenceSet(ready.file[].len, ready.referenceTraces)
      var delayed = 0
      for t in ready.referenceTraces:
        if ready.file[].traceKeys(t).status == tsAuxiliary and t notin made.view.odd:
          inc delayed
      slot[].traces = ready.file[].len
      slot[].samples = shape.listen
      slot[].listenMs = float64(shape.listen) * shape.dtMs
      slot[].sweepMs = float64(ready.reference.len) * shape.dtMs
      slot[].lines = jobLines(ready, shape, delayed, abs(made.view.lag), refs)
      slot[].view = made.view
      slot[].estimate = estimate
      slot[].onDemand = true
      slot[].ok = true
