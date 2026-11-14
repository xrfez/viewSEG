## A trace panel's reader: the thread that reads what the panel shows.
##
## Each panel that shows a file has one reader (docs/architecture.md,
## "Threads"). The reader owns the panel's parseSEG `Prefetcher` (a
## prefetcher is used only by the thread that made it), runs the display
## pipeline (processSEG) on each chunk, cuts the result down to the tile the
## request asks for, and posts the tile to the UI thread's inbox. The UI
## thread never waits for it: `show` and `request` only leave a note under a
## lock and wake the thread.
##
## - **Newest wins.** A note replaces the one before it if the reader has
##   not taken it yet, and a reader serving a request gives it up as soon as
##   a newer note arrives (between chunks; a prefetcher gives up a chunk
##   within 8 traces), so a burst of pans costs one read, not one per frame.
## - **Holds.** The caller takes a hold on the file (`Jobs.hold`) before it
##   names the file in `show`. The reader ends it (`HoldRelease`) once it no
##   longer touches the file: when it is shown something else or nothing,
##   after its prefetcher is closed, or at once for a file it never took. A
##   close or a join of the file waits for that.
## - **What it reads.** Through the prefetcher only, plus the in-memory index
##   (the gather's trace keys, for the trace filter and the display header),
##   which nothing changes while the file is held.
## - **Layout.** When it is shown a gather, the reader applies the layer's
##   trace filter (seismic or auxiliary traces) and posts the panel's
##   `PanelLayout` (`mkLayout`), with the header fields the traces have
##   values for. Requests come after that.
## - **Threads and ORC.** The reader is a worker (`core/threads`); it
##   empties its list of cycle roots after closing a prefetcher, before it
##   ends a hold, and before it exits. A tile holds no `ref`.

import std/[locks, math, os, times]
import parseSEG
import processSEG/[adapters, pipeline]
import processSEG/core/[rows, types, workspace]
import processSEG/gain/stats
import inbox, jobs, log, panels, threads, tiles, viewport

const
  ChunkTraces = 64    ## traces per prefetch chunk
  DecodeWorkers = 2   ## prefetch threads per reader
  HeaderScan = 10_000 ## traces looked at for the header fields a gather has

type
  ReaderSource* = object
    ## What a panel shows, for its reader.
    gen*: uint64           ## the panel's `sourceGen`: its layout carries it
    file*: ptr SeismicFile ## nil: nothing
    path*: string          ## the file's path, as held
    traces*: Slice[int]    ## the gather
    filter*: TraceFilter

  ReaderRequest* = object
    ## What a panel asks its reader for.
    read*: ReadRequest
    fields*: seq[HeaderField] ## the display header's rows
    flow*: Pipeline           ## processing for display (`displayPipeline`)
    clipPercentile*: float64

  ReaderObj = object
    lock: Lock
    changed: Cond
    panel: PanelId
    hasSource, hasRequest, quit: bool ## notes not taken yet
    source: ReaderSource
    request: ReaderRequest
    poster: Poster
    holds: HoldRelease
    started: bool
    thread: Thread[ptr ReaderObj]

  PanelReader* = object
    ## A panel's reader thread. Move-only; destroying it stops the thread.
    p: ptr ReaderObj

  Positions = object
    ## The traces of a panel's positions: `traces.a + k`, or `list[k]`.
    traces: Slice[int]
    list: seq[int] ## empty when every trace of `traces` is shown

  Reader = object
    ## The reader thread's own state.
    r: ptr ReaderObj
    src: ReaderSource
    name: string
    positions: Positions
    layout: PanelLayout
    ws: Workspace

proc `=destroy`*(x: PanelReader)
proc `=wasMoved`*(x: var PanelReader) = x.p = nil
proc `=copy`*(dest: var PanelReader; src: PanelReader) {.error.}
proc `=dup`*(src: PanelReader): PanelReader {.error.}

func isNil*(x: PanelReader): bool {.inline.} =
  ## Whether `x` was never started (a default `PanelReader`).
  x.p == nil

func len(p: Positions): int =
  if p.list.len > 0: p.list.len else: p.traces.len

func traceAt(p: Positions; k: int): int {.inline.} =
  if p.list.len > 0: p.list[k] else: p.traces.a + k

# ------------------------------------------------------------ the thread --

proc note(rd: Reader; severity: Severity; text: string) =
  ## Posts `text` for the log, about the panel's file.
  rd.r.poster.post Msg(job: NoJob, kind: mkLog, entry: LogEntry(time: getTime(),
    severity: severity, source: rd.name, text: text))

proc interrupted(r: ptr ReaderObj): bool =
  ## Whether a newer note is waiting: then the current work is given up.
  withLock r.lock:
    result = r.quit or r.hasSource or r.hasRequest

proc letGo(rd: var Reader) =
  ## Stops touching the file and ends its hold.
  if rd.src.file != nil:
    clearCycleRoots()
    discard rd.r.holds.release(rd.src.path)
  rd.src = ReaderSource()
  rd.positions = Positions()
  rd.layout = PanelLayout()

proc adopt(rd: var Reader; src: sink ReaderSource) =
  ## Starts showing `src`: its positions, its layout, posted.
  rd.src = src
  rd.name = rd.src.path.extractFilename
  if rd.src.file == nil: return
  let f = rd.src.file
  let g = rd.src.traces
  if not f[].hasKeys: # files are opened with their keys; without them nothing here works
    raise newException(ValueError, "it was opened without its trace keys")
  let rows = f[].rowsOf(g)
  var list: seq[int]
  var all = true
  for k in 0 ..< rows.len:
    let seismic = rows.keysAt(k).isSeismic
    if (seismic and rd.src.filter.seismic) or (not seismic and rd.src.filter.auxiliary):
      list.add g.a + k
    else:
      all = false
  rd.positions = if all: Positions(traces: g) else: Positions(traces: g, list: list)
  let n = rd.positions.len
  var known: set[HeaderField]
  var layout = PanelLayout(traces: n, dtMs: 1, t0Ms: 0)
  if n > 0:
    layout.samples = if all: f[].maxSamples(g) else: f[].maxSamples(list)
    let k0 = f[].traceKeys(rd.positions.traceAt(0))
    if k0.intervalUs > 0 and k0.intervalUs < Inf:
      layout.dtMs = k0.intervalUs / 1000
    else:
      rd.note(sevWarning, "The sample interval of " & rd.name & " is not known: the time " &
        "axis counts samples (1 ms each).")
    if k0.t0Ms.classify notin {fcNan, fcInf, fcNegInf}: layout.t0Ms = k0.t0Ms
    let step = max(1, n div HeaderScan)
    var k = 0
    while k < n:
      let t = rd.positions.traceAt(k)
      let keys = f[].traceKeys(t)
      for field in HeaderField:
        if not keys.value(field, t).isNaN: known.incl field
      k += step
  rd.layout = layout
  rd.r.poster.post Msg(job: NoJob, kind: mkLayout, panel: rd.r.panel,
    sourceGen: rd.src.gen, layout: layout, known: known)

proc clipOf(rd: var Reader; tile: Tile; list: seq[int]; failed: seq[int];
    percentile: float64): float64 =
  ## The `percentile` of |x| over the tile's live traces; NaN when none.
  result = NaN
  if tile.request.count == 0 or tile.columns == 0: return
  try:
    let meta = initChunkMeta(rd.src.file[].rowsOf(list), rd.layout.dtMs *
      float64(tile.request.decimation), tile.request.firstSample, failed)
    rd.ws.reserve(panelStatsWorkspace)
    let s = panelStats(rowBlock(tile.data, tile.request.count, tile.columns), meta, rd.ws,
      percentile)
    if s.rows > 0: result = s.clip
  except ValueError as e:
    rd.note(sevWarning, "Cannot work out the display gain of " & rd.name & ": " & e.msg)

proc serve(rd: var Reader; req: sink ReaderRequest) =
  ## Reads, processes and posts the tile `req` asks for, unless a newer note
  ## comes first.
  let q = req.read
  let f = rd.src.file
  if q.isEmpty or q.first < 0 or q.last >= rd.positions.len: return
  var list = newSeq[int](q.count)
  for row in 0 ..< q.count: list[row] = rd.positions.traceAt(q.position(row))
  let window = q.decodeSpan(rd.layout.samples)
  let skip = q.firstSample - window.a # decoded columns before the kept ones
  var processing = req.flow.len > 0
  var plan: PipelinePlan[float32]
  if processing:
    try:
      plan = req.flow.compile(float32, rd.layout.dtMs, window.len,
        recordSamples = rd.layout.samples)
      rd.ws.reserve(plan)
    except ValueError as e:
      rd.note(sevError, "The display processing cannot run on " & rd.name & ": " & e.msg)
      processing = false
  var tile = Tile(panel: rd.r.panel, request: q, dtMs: rd.layout.dtMs, t0Ms: rd.layout.t0Ms,
    columns: q.columns, fields: req.fields)
  tile.data = newSeq[float32](q.count * tile.columns)
  tile.header = newSeq[seq[float64]](req.fields.len)
  for h in tile.header.mitems: h = newSeq[float64](q.count)
  var failed: seq[int]
  var firstError = ""
  var pf = newPrefetcher[float32](f[], list, chunkTraces = ChunkTraces, cols = window.len,
    firstSample = window.a, workers = DecodeWorkers, quickFirst = true, uniform = true)
  var c: PrefetchChunk[float32]
  var given = false
  while pf.nextInto(c):
    if processing:
      try:
        plan.apply(c.samples, chunkMeta(c, rd.layout.dtMs), rd.ws)
      except ValueError as e:
        rd.note(sevError, "The display processing stopped on " & rd.name & ": " & e.msg)
        processing = false
    let b = rowBlock(c.samples)
    for k in 0 ..< c.count:
      let row = c.first + k
      let src = b.rowPtr(k)
      let at = row * tile.columns
      decimatePeakInto(src.toOpenArray(skip, skip + q.samples - 1), q.decimation,
        tile.data.toOpenArray(at, at + tile.columns - 1))
      let keys = c.rows.keysAt(k)
      for i, field in req.fields:
        tile.header[i][row] = keys.value(field, list[row])
    for fr in c.failedRows: failed.add c.first + fr
    tile.failed += c.failed
    if c.failed > 0 and firstError.len == 0 and c.log.len > 0:
      firstError = c.log[0].msg
    if rd.r.interrupted:
      given = true
      break
  pf.close()
  clearCycleRoots()
  if given: return
  tile.clip = rd.clipOf(tile, list, failed, req.clipPercentile)
  if tile.failed > 0:
    rd.note(sevWarning, $tile.failed & " of the " & $q.count & " traces shown could not be " &
      "read and are drawn blank" & (if firstError.len > 0: ": " & firstError else: "") & ".")
  rd.r.poster.post Msg(job: NoJob, kind: mkTile, tile: move tile)

proc run(r: ptr ReaderObj) {.thread.} =
  markWorkerThread()
  var rd = Reader(r: r, ws: initWorkspace())
  while true:
    var src: ReaderSource
    var req: ReaderRequest
    var gotSource, gotRequest, quit = false
    withLock r.lock:
      while not (r.quit or r.hasSource or r.hasRequest):
        wait(r.changed, r.lock)
      quit = r.quit
      gotSource = r.hasSource
      gotRequest = r.hasRequest
      if gotSource: src = move r.source
      if gotRequest: req = move r.request
      r.hasSource = false
      r.hasRequest = false
    if gotSource or quit:
      rd.letGo()
    if quit:
      if gotSource and src.file != nil: discard r.holds.release(src.path) # never taken
      break
    try:
      if gotSource: rd.adopt(src)
      if gotRequest and rd.src.file != nil and req.read.gen >= rd.src.gen:
        rd.serve(req)
    except CatchableError as e:
      rd.note(sevError, "Cannot read " & rd.name & ": " & e.msg)
      clearCycleRoots()
  rd.letGo()
  clearCycleRoots()

# --------------------------------------------------------------- the UI side --

proc `=destroy`*(x: PanelReader) =
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true
      signal(x.p.changed)
    if x.p.started: joinThread(x.p.thread)
    deinitCond(x.p.changed)
    deinitLock(x.p.lock)
    `=destroy`(x.p[])
    deallocShared(x.p)

proc newPanelReader*(panel: PanelId; poster: sink Poster; holds: HoldRelease): PanelReader =
  ## Starts the reader of `panel`, which posts through `poster` and ends its
  ## holds through `holds`.
  let p = cast[ptr ReaderObj](allocShared0(sizeof(ReaderObj)))
  initLock p.lock
  initCond p.changed
  p.panel = panel
  p.poster = poster
  p.holds = holds
  result = PanelReader(p: p)
  createThread(p.thread, run, p)
  p.started = true

proc show*(x: PanelReader; source: sink ReaderSource) =
  ## Shows `source` (a file the caller holds, or nothing): the reader lets
  ## go of what it showed, then posts the new layout. A request not yet
  ## taken is dropped; a source not yet taken is replaced, and its hold
  ## ended here.
  assert x.p != nil
  var dropped = ""
  withLock x.p.lock:
    if x.p.hasSource and x.p.source.file != nil:
      dropped = move x.p.source.path
    x.p.source = source
    x.p.hasSource = true
    x.p.hasRequest = false
    signal(x.p.changed)
  if dropped.len > 0: discard x.p.holds.release(dropped)

proc request*(x: PanelReader; req: sink ReaderRequest) =
  ## Asks for a tile; replaces a request not yet taken.
  assert x.p != nil
  withLock x.p.lock:
    x.p.request = req
    x.p.hasRequest = true
    signal(x.p.changed)

proc stop*(x: PanelReader) =
  ## Stops the thread and waits for it: it lets go of its file first.
  ## Idempotent; destroying the reader does it.
  if x.p != nil and x.p.started:
    withLock x.p.lock:
      x.p.quit = true
      signal(x.p.changed)
    joinThread(x.p.thread)
    x.p.started = false
