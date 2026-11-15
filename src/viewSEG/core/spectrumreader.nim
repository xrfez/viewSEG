## The spectrum windows' reader: the thread that reads the traces a
## spectrum is of and computes it (`core/spectra`), so that the UI thread
## never does either.
##
## The UI thread leaves a request per window (`ask`): an open file, the
## traces, the time window, the plot's filters. The reader reads what it
## does not hold of those traces (a selection-mode `Prefetcher` over whole
## traces), keeps their samples as decoded, computes the raw and the
## processed spectrum, and posts the answer (`mkSpectrum`). The filters
## are made here, for the traces' own sample interval, and the answer says
## what they reached (`core/spectra`, "Raw and processed").
##
## - **One request per window, newest wins.** A request replaces the one of
##   the same window that waits, and one being served is given up between
##   blocks of traces when a newer one of its window comes, or the window
##   closes (`cancel`); one read and computed whole is posted all the same
##   (the window shows it while the newer one is served). Requests of
##   different windows are served in turn.
## - **Samples at hand.** The samples of the traces read last are kept, as
##   decoded, whole (up to `MaxSpectrumSamples`, of the file read last;
##   let go when no window needs them, `forget`):
##   another time window, other filters, or the same traces asked again by
##   another window read nothing from the file, and a pan reads only the
##   traces it brings into view. The answer counts the traces read
##   (`Spectrum.read`).
## - **Holds.** The caller takes a hold on the request's file (`Jobs.hold`)
##   before it asks; the reader ends it (`HoldRelease`) once it has served
##   the request or given it up, and `ask` and `cancel` end those of the
##   requests they drop untaken.
## - **A file another program cut short** (shorter than when it was opened)
##   or that cannot be looked at is not read: the answer says why.
## - **A drive that does not answer.** Each read is marked through the seam
##   (`fs.mappedRead`), after a beat that names the file; a reader that is
##   busy and has not beaten for a while is stuck (`silentFor`). The UI
##   thread then leaves it (`leave`) for a new one, as it does the Headers
##   window's reader.

import std/[algorithm, locks, monotimes, os, strutils, tables, times]
import parseSEG
import processSEG/pipeline
import processSEG/core/[rows, types, workspace]
import processSEG/filter/design
import filesystem, inbox, jobs, log, processing, spectra, threads

const
  ReadTraces = 64  ## traces per prefetch chunk
  BlockTraces = 256 ## traces put through the FFT (and the filters) at a time

type
  SpectrumAsk* = object
    ## What a spectrum window asks the reader for.
    id*: int               ## the window's
    gen*: uint64
    session*: int          ## the open file's id: what the samples at hand are of
    file*: ptr SeismicFile ## held by the caller
    path*: string
    size*: int64           ## its size when it was opened; -1 when not known
    traces*: seq[int]      ## indices in the file
    killed*: seq[int]      ## those of them killed, ascending: left out
    fromMs*, toMs*: float64 = NaN
      ## the time window; NaN: the whole trace
    processing*: Processing
      ## the plot's filters (shown raw or not, alike), with whether an
      ## auxiliary trace goes through them too

  Held = object
    ## A trace's samples as decoded.
    samples: seq[float32]
    failed: bool

  ReaderObj = object
    lock: Lock
    changed: Cond
    queue: seq[SpectrumAsk]
    quit: bool
    serving: int      ## the window whose request is served; -1 for none
    dropServed: bool  ## that request is given up (its window closed)
    poster: Poster
    holds: HoldRelease
    started, busy, ended, abandoned: bool
    beat: MonoTime
    reading: string
    held: int         ## samples kept at hand
    forget: bool      ## no window needs them: let them go once the queue is empty
    thread: Thread[ptr ReaderObj]

  SpectrumReader* = object
    ## The spectrum windows' reader thread. Move-only; destroying it stops
    ## the thread.
    p: ptr ReaderObj

  Cache = object
    session: int
    traces: Table[int, Held]
    values: int

proc `=destroy`*(x: SpectrumReader)
proc `=wasMoved`*(x: var SpectrumReader) = x.p = nil
proc `=copy`*(dest: var SpectrumReader; src: SpectrumReader) {.error.}
proc `=dup`*(src: SpectrumReader): SpectrumReader {.error.}

func isNil*(x: SpectrumReader): bool {.inline.} =
  ## Whether `x` was never started.
  x.p == nil

# ------------------------------------------------------------ the thread --

proc interrupted(p: ptr ReaderObj; id: int): bool =
  ## Whether the request of window `id` being served is to be given up: a
  ## newer one of its window waits, its window closed, or the reader stops.
  ## A sign of life too.
  let now = fs.now()
  withLock p.lock:
    p.beat = now
    result = p.quit or p.dropServed
    for a in p.queue:
      if a.id == id: result = true

proc beat(p: ptr ReaderObj; reading: string) =
  let now = fs.now()
  withLock p.lock:
    p.beat = now
    p.reading = reading

func failedText(e: ref OSError): string =
  var msg = e.msg
  let cut = msg.find('\n')
  if cut >= 0: msg.setLen cut
  "it cannot be read now (" & (if msg.len > 0: msg else: "its drive does not answer") &
    "): its drive went away or fails"

proc unreadable(a: SpectrumAsk): string =
  ## Why the file is not read now; "" when it can be.
  result = ""
  try:
    let size = fs.getFileInfo(a.path).size
    if a.size >= 0 and size < a.size:
      result = "the file is shorter than when it was opened (another program cut it " &
        "short or is writing it): it is not read until it is opened again"
  except OSError as e:
    result = failedText(e)

proc readMissing(p: ptr ReaderObj; a: SpectrumAsk; list: seq[int]; cache: var Cache): int =
  ## Reads the traces of `list` that are not at hand into `cache`; how many
  ## it read, or -1 when a newer request came first.
  var missing: seq[int]
  for t in list:
    if t notin cache.traces: missing.add t
  if missing.len == 0: return 0
  let f = a.file
  p.beat(a.path)
  # parseSEG's prefetcher keeps the readers it gave up on in a list of its
  # own, under a lock, which makes `newPrefetcher` and `close` not gcsafe.
  var pf = block:
    {.cast(gcsafe).}:
      newPrefetcher[float32](f[], missing, chunkTraces = ReadTraces,
        workers = 2, uniform = true)
  var c: PrefetchChunk[float32]
  var given = false
  while pf.nextInto(c):
    fs.mappedRead(a.path)
    let b = rowBlock(c.samples)
    var failed = newSeq[bool](c.count)
    for r in c.failedRows: failed[r] = true
    for k in 0 ..< c.count:
      let n = min(c.rows.numSamples(k), b.cols)
      var h = Held(samples: newSeq[float32](max(n, 0)), failed: failed[k])
      if n > 0: copyMem(addr h.samples[0], b.rowPtr(k), n * sizeof(float32))
      cache.values += n
      cache.traces[missing[c.first + k]] = move h
    inc result, c.count
    # given up between chunks only: what is read whole is served
    if result < missing.len and p.interrupted(a.id):
      given = true
      break
    p.beat(a.path)
  {.cast(gcsafe).}:
    pf.close() # false when a worker stuck in a read is left to finish
    discard
  clearCycleRoots()
  if given: result = -1

proc compute(p: ptr ReaderObj; a: SpectrumAsk; list: seq[int]; dtMs: float64;
    cache: Cache; answer: var Spectrum): bool =
  ## The raw and processed spectra of `list` (traces at hand, live, of one
  ## interval) into `answer`; false when a newer request came first.
  let f = a.file
  var longest = 0
  for t in list: longest = max(longest, cache.traces[t].samples.len)
  let t0 = f[].traceKeys(list[0]).t0Ms
  let t0Ms = if t0.classify in {fcNan, fcInf, fcNegInf}: 0.0 else: t0
  let window = windowColumns(a.fromMs, a.toMs, t0Ms, dtMs, longest)
  if window.len == 0:
    answer.problem = "the time window holds no sample of these traces"
    return true
  answer.fromMs = t0Ms + float64(window.a) * dtMs
  answer.toMs = t0Ms + float64(window.b) * dtMs
  answer.windowLen = window.len
  var pr = a.processing
  pr.raw = false
  var filtering = pr.hasFilters
  let filters = if filtering: pr.filterPipeline(dtMs) else: initPipeline()
  if filtering:
    answer.filters = pr.describe
    answer.filterAux = pr.aux
    answer.filterNote = pr.limitNote(dtMs)
    if filters.len == 0:
      answer.filterProblem = "none of them is below Nyquist"
      filtering = false
  # Finer bins for a narrow filter (`spectrumNfft`), and its own response on them.
  var narrowest = Inf
  if filtering:
    for op in filters:
      if op.kind == opFilter: narrowest = min(narrowest, op.filter.spec.narrowestRampHz)
  let nfft = spectrumNfft(window.len, dtMs, narrowest)
  var raw = initSpectrumSum(dtMs, window.len, nfft)
  var processed = initSpectrumSum(dtMs, window.len, nfft)
  var response: seq[float64]
  if filtering:
    var gain = newSeq[float64](raw.bins)
    for op in filters:
      if op.kind == opFilter:
        op.filter.spec.responseInto(dtMs, nfft, gain)
        if response.len == 0: response = gain
        else:
          for k in 0 ..< response.len: response[k] *= gain[k]
  var plan: PipelinePlan[float32]
  var planCols = -1
  var ws = initWorkspace()
  var work: seq[float32]
  var at = 0
  while at < list.len:
    let n = min(BlockTraces, list.len - at)
    let part = list[at ..< at + n] # outlives the rows' views
    var cols = 0
    for t in part: cols = max(cols, cache.traces[t].samples.len)
    work.setLen n * cols
    var failed: seq[int]
    for k, t in part:
      let h = cache.traces[t]
      let row = k * cols
      if h.samples.len > 0: copyMem(addr work[row], addr h.samples[0], h.samples.len * 4)
      for j in h.samples.len ..< cols: work[row + j] = 0
      if h.failed: failed.add k
    let b = rowBlock(work, n, cols)
    var keys: seq[TraceKeys]
    var lengths: seq[int]
    let rows = f[].rowsOf(part)
    let live = rows.auxLiveRows(keys, lengths) # a pilot counts as a trace
    discard raw.add(b, initChunkMeta(live, dtMs, 0, failed), window.a)
    template phaseOf(sum: var SpectrumSum): seq[float64] =
      # one trace: its phase too (what the vibrator analysis compares)
      let n = min(cache.traces[part[0]].samples.len - window.a, window.len)
      if list.len == 1 and failed.len == 0 and n > 0: sum.phaseOf(work.toOpenArray(window.a,
        window.a + n - 1))
      else: @[]
    answer.rawPhase = raw.phaseOf()
    if filtering and cols != planCols:
      try:
        plan = filters.compile(float32, dtMs, cols, recordSamples = cols)
        ws.reserve(plan)
        planCols = cols
      except ValueError as e:
        answer.filterProblem = "they cannot run on these traces (" & e.msg & ")"
        filtering = false
    if filtering:
      # Through the filters, and in the processed curve, only the rows they
      # reach: with the Aux toggle off processSEG passes an auxiliary row by,
      # and the sum leaves it out (it is not live), so it is not counted as
      # processed.
      let meta = if pr.aux: initChunkMeta(live, dtMs, 0, failed)
                 else: initChunkMeta(rows, dtMs, 0, failed)
      plan.apply(b, meta, ws)
      discard processed.add(b, meta, window.a)
      answer.processedPhase = processed.phaseOf()
    at += n
    # given up between blocks only: a spectrum computed whole is posted, so
    # the live panel moves on while a pan sends newer requests
    if at < list.len and p.interrupted(a.id): return false
  answer.binHz = raw.binHz
  answer.nfft = raw.nfft
  answer.raw = raw.amplitudes
  answer.averaged = raw.used
  answer.failed += list.len - raw.used
  if filtering:
    answer.filtered = processed.used
    if not pr.aux: answer.passedBy = raw.used - processed.used
    if processed.used > 0: answer.processed = processed.amplitudes
    answer.response = move response
  if answer.processed.len == 0: answer.processedPhase.setLen 0
  true

proc serve(p: ptr ReaderObj; a: SpectrumAsk; cache: var Cache): bool =
  ## Reads what `a` needs, computes and posts its answer; false when it was
  ## given up first (then nothing is posted).
  var answer = Spectrum(gen: a.gen, id: a.id, asked: a.traces.len, fromMs: NaN, toMs: NaN)
  p.beat(a.path)
  answer.problem = a.unreadable
  if answer.problem.len == 0:
    let f = a.file
    if cache.session != a.session:
      cache = Cache(session: a.session)
    # Left out: killed, dead, and sampled at another interval than the first.
    var list: seq[int]
    var dtMs = NaN
    for t in a.traces:
      if t notin 0 ..< f[].len: inc answer.failed
      elif a.killed.binarySearch(t) >= 0: inc answer.killed
      else:
        let k = f[].traceKeys(t)
        let us = if k.intervalUs > 0 and k.intervalUs < Inf: k.intervalUs
                 else: f[].sampleIntervalUs(t)
        if k.status == tsDead: inc answer.dead
        elif not (us > 0 and us < Inf): inc answer.atOtherInterval
        elif dtMs.isNaN or sameInterval(us / 1000, dtMs):
          if dtMs.isNaN: dtMs = us / 1000
          list.add t
        else: inc answer.atOtherInterval
    answer.dtMs = dtMs
    if list.len == 0:
      answer.problem = "no trace to take the spectrum of (" &
        (if a.traces.len == 0: "none asked about" else: "every one left out") & ")"
    else:
      try:
        let read = p.readMissing(a, list, cache)
        if read < 0: return false
        answer.read = read
        if not p.compute(a, list, dtMs, cache, answer): return false
      except OSError as e:
        answer.problem = failedText(e)
      except ValueError as e:
        answer.problem = e.msg
    # Kept at hand: this request's traces; the others too while they fit.
    if cache.values > MaxSpectrumSamples:
      var gone: seq[int]
      for t in cache.traces.keys:
        if t notin list: gone.add t
      for t in gone:
        cache.values -= cache.traces[t].samples.len
        cache.traces.del t
      if cache.values > MaxSpectrumSamples: cache = Cache(session: a.session)
  clearCycleRoots() # the UI thread frees what was made here
  p.poster.post Msg(job: NoJob, kind: mkSpectrum, spectrum: answer)
  true

proc run(p: ptr ReaderObj) {.thread.} =
  markWorkerThread()
  var cache = Cache()
  while true:
    var a: SpectrumAsk
    var got, quit, forget = false
    withLock p.lock:
      while not (p.quit or p.queue.len > 0 or p.forget):
        wait(p.changed, p.lock)
      forget = p.forget and p.queue.len == 0 # a window that asks needs them
      p.forget = false
      quit = p.quit
      got = p.queue.len > 0 and not quit
      if got:
        a = move p.queue[0]
        p.queue.delete 0
        p.serving = a.id
        p.dropServed = false
      p.busy = got
      p.beat = fs.now()
    if got:
      try:
        discard p.serve(a, cache)
      except CatchableError as e:
        p.poster.post Msg(job: NoJob, kind: mkLog, entry: LogEntry(time: getTime(),
          severity: sevWarning, source: "spectrum", text: "A spectrum could not be " &
          "computed: " & e.msg))
      clearCycleRoots()
      discard p.holds.release(a.path)
    if forget:
      cache = Cache()
      clearCycleRoots()
    withLock p.lock:
      p.busy = false
      p.serving = -1
      p.reading = ""
      p.held = cache.values
    if quit: break
  cache = Cache()
  clearCycleRoots()
  withLock p.lock:
    p.busy = false
    p.ended = true

# --------------------------------------------------------------- the UI side --

const SpectrumStopWait* = initDuration(milliseconds = 800)

proc stop*(x: SpectrumReader; deadline = getMonoTime() + SpectrumStopWait): bool {.
  discardable, raises: [].}

proc dispose(x: SpectrumReader) =
  for a in x.p.queue: discard x.p.holds.release(a.path)
  deinitCond(x.p.changed)
  deinitLock(x.p.lock)
  `=destroy`(x.p[])
  deallocShared(x.p)

proc `=destroy`*(x: SpectrumReader) =
  if x.p != nil:
    var abandoned = false
    withLock x.p.lock:
      abandoned = x.p.abandoned
    if not abandoned: discard x.stop()
    if not x.p.started: x.dispose()

proc newSpectrumReader*(poster: sink Poster; holds: HoldRelease): SpectrumReader =
  ## Starts the reader, which posts through `poster` and ends its holds
  ## through `holds`.
  let p = cast[ptr ReaderObj](allocShared0(sizeof(ReaderObj)))
  initLock p.lock
  initCond p.changed
  p.poster = poster
  p.holds = holds
  p.serving = -1
  result = SpectrumReader(p: p)
  createThread(p.thread, run, p)
  p.started = true

proc ask*(x: SpectrumReader; a: sink SpectrumAsk) =
  ## Asks for `a`, whose file the caller holds; replaces a request of the
  ## same window not yet taken (ending its hold), and has one being served
  ## given up.
  assert x.p != nil
  var dropped: seq[string]
  withLock x.p.lock:
    var i = 0
    while i < x.p.queue.len:
      if x.p.queue[i].id == a.id:
        dropped.add x.p.queue[i].path
        x.p.queue.delete i
      else: inc i
    x.p.queue.add a
    signal(x.p.changed)
  for path in dropped: discard x.p.holds.release(path)

proc cancel*(x: SpectrumReader; id: int) =
  ## Drops window `id`'s requests: one waiting (its hold ended), and one
  ## being served is given up between blocks.
  if x.p == nil: return
  var dropped: seq[string]
  withLock x.p.lock:
    var i = 0
    while i < x.p.queue.len:
      if x.p.queue[i].id == id:
        dropped.add x.p.queue[i].path
        x.p.queue.delete i
      else: inc i
    if x.p.serving == id: x.p.dropServed = true
  for path in dropped: discard x.p.holds.release(path)

proc forget*(x: SpectrumReader) =
  ## No window needs the samples at hand any more: they are let go (unless
  ## a request comes first).
  if x.p != nil:
    withLock x.p.lock:
      x.p.forget = true
      signal(x.p.changed)

proc askStop*(x: SpectrumReader) =
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true
      signal(x.p.changed)

proc stop*(x: SpectrumReader; deadline = getMonoTime() + SpectrumStopWait): bool {.
    discardable, raises: [].} =
  ## Stops the thread and waits for it until `deadline`: true when it has
  ## ended; false when it is stuck, and it is then left to end on its own.
  if x.p == nil or not x.p.started: return true
  x.askStop()
  var ended = false
  while true:
    withLock x.p.lock:
      ended = x.p.ended
    if ended or getMonoTime() >= deadline: break
    sleep 1
  if ended:
    joinThread(x.p.thread)
    x.p.started = false
  else:
    withLock x.p.lock:
      x.p.abandoned = true
  ended

proc leave*(x: SpectrumReader) =
  ## Leaves the thread to end on its own (stuck in a drive that does not
  ## answer); its holds stay until it ends.
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true
      x.p.abandoned = true
      signal(x.p.changed)

proc hasEnded*(x: SpectrumReader): bool =
  ## Whether the thread has ended (joined now, if so); true for none.
  x.stop(getMonoTime())

proc silentFor*(x: SpectrumReader; now = fs.now()): Duration =
  ## How long the reader has been busy without a sign of life; zero when
  ## idle or none.
  if x.p != nil:
    withLock x.p.lock:
      if x.p.busy: result = now - x.p.beat

proc held*(x: SpectrumReader): int =
  ## The samples the reader keeps at hand; 0 for none.
  if x.p != nil:
    withLock x.p.lock:
      result = x.p.held

proc readingPath*(x: SpectrumReader): string =
  ## The file the reader reads now; "" when it is idle or none.
  if x.p != nil:
    withLock x.p.lock:
      if x.p.busy: result = x.p.reading
