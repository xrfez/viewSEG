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
##   not taken it yet, and a reader reading a request from the file gives it
##   up as soon as a newer note arrives (between chunks; a prefetcher gives
##   up a chunk within 8 traces), so a burst of pans costs one read, not one
##   per frame. A tile made from the samples at hand is finished first (only
##   a new source, order or a stop ends it): a slider dragged asks for a new
##   one every frame, and the plot must follow it while it moves.
## - **Holds.** The caller takes a hold on the file (`Jobs.hold`) before it
##   names the file in `show`. The reader ends it (`HoldRelease`) once it no
##   longer touches the file: when it is shown something else or nothing,
##   after its prefetcher is closed, or at once for a file it never took. A
##   close or a join of the file waits for that.
## - **What it reads.** Through the prefetcher only, plus the in-memory index
##   (the gather's trace keys, for the trace filter and the display header),
##   which nothing changes while the file is held.
## - **Layout.** When it is shown a gather, the reader applies the layer's
##   trace filter (seismic or auxiliary traces, and the components switched off;
##   the killed ones left out when they are hidden, `ReaderSource.hidden`)
##   and posts the panel's
##   `PanelLayout` (`mkLayout`), with the header fields the traces have
##   values for. Requests come after that.
## - **Order.** Then it sorts the traces by the layer's keys
##   (`core/sorting`), and again whenever it is given a new order (`sortBy`),
##   without letting go of the file: a position is the place of a trace in
##   that order, so every request, and the tile's traces, keys and display
##   header values, follow it. A newer note stops a sort between runs of
##   traces; until a sort is done, no request is served.
## - **The tile.** Each row is cut to the kept samples and peak-decimated
##   (`decimatePeakInto`); with `envelope`, its columns' extremes are kept
##   too (`minMaxInto`), so a wiggle zoomed out in time keeps its peaks.
## - **Dead traces and bad samples** (`readyForProcessing`), before any
##   processing: a trace marked dead in the file is blanked, passed by like a
##   trace that could not be decoded (so neither the processing nor the
##   tile's level sees it) and marked in the tile (`Tile.dead`), so it is
##   never drawn, under any gain; a sample that is not a number (NaN, ±Inf)
##   is set to 0, and the first gather of a file that has such samples is
##   said in the log once, with how many traces hold them.
## - **Edits** (`core/edits`, with each request): a killed trace is blanked
##   and passed by, like a trace that could not be decoded, so neither the
##   processing nor the tile's level sees it; a reversed trace's samples are
##   negated (processSEG's `reversePolarity`, on its live samples, as
##   `polarityOp` does) before the processing and the gain.
## - **Raw samples at hand.** The decoded samples of the last request read
##   from the file are kept, as read (up to `MaxRawSamples`); a request for
##   traces and samples among them (after an edit, or a new gain, on the
##   same view, or on one a little shorter; fewer of its traces, or every
##   second or fourth of them, as a turn or a coarser stride asks; at any
##   decimation) is made from them, with no read from the file.
## - **Processing.** The layer's filters (`core/processing`), then its
##   display pipeline (the polarity, the CPU part of its gain), each a
##   compiled processSEG plan run on the reader's own `ProcessPool`, its
##   rows shared out among the pool's workers (made when first needed, ended
##   with the thread). Only the tile's traces and samples are processed
##   (`Tile.filtered` counts the traces passed to the filters), so a
##   change costs what the view holds, not what the file does; a change of
##   the filters alone is made from the raw samples at hand, with no read
##   from the file (the panel asks for whole traces while it filters, so
##   the samples at hand stay enough as the filters' margin changes). The
##   auxiliary traces go through the filters only when the layer asks
##   (`Processing.aux`): processSEG passes them by otherwise. The display gain
##   reaches them when it sets each trace's own size (Normalized for each trace,
##   AGC: `flowReachesAux`), so a trace of 60 000 and one of 1 are drawn alike;
##   the other types are a scale of the record or a curve in time, and leave
##   them as they are.
## - **A drive that does not answer.** The reader *beats* (`fs.now`) as it
##   takes each chunk; one that is busy and has not beaten for a while is
##   stuck in the file system (`silentFor`), where no note reaches it. The
##   UI thread then leaves it (`abandon`) and starts a new reader: the old
##   one ends on its own once the drive answers, posting nothing that is
##   still taken (its tiles answer an old request), and keeps its hold on
##   the file until then. `stop` waits for the thread until a deadline only.
## - **Threads and ORC.** The reader is a worker (`core/threads`); it
##   empties its list of cycle roots after closing a prefetcher, before it
##   ends a hold, and before it exits. A tile holds no `ref`.

import std/[algorithm, cpuinfo, locks, math, monotimes, os, strutils, times]
import parseSEG
import processSEG/pipeline
import processSEG/core/[basic, pool, rows, types, workspace]
import processSEG/gain/stats
import channelsets, components, cutfile, edits, filesystem, inbox, jobs, log, panels, processing, readout,
  sorting, threads, tiles, viewport, wiggle

const
  ChunkTraces = 64    ## traces per prefetch chunk
  HeldTraces = 256
    ## traces processed at a time from the samples at hand: enough rows for
    ## every worker of the pool, few enough that a newer note is seen soon
  DecodeWorkers = 2 ## prefetch threads per reader
  HeaderScan = 10_000 ## traces looked at for the header fields a gather has
  MaxRawSamples* = 32 * 1024 * 1024
    ## decoded samples (128 MiB) a reader keeps of its last request, at most

type
  ReaderSource* = object
    ## What a panel shows, for its reader.
    gen*: uint64           ## the panel's `sourceGen`: its layout carries it
    file*: ptr SeismicFile ## nil: nothing
    path*: string          ## the file's path, as held
    size*: int64           ## the file's size when it was opened; -1 when not known
    traces*: Slice[int]    ## the gather
    filter*: TraceFilter
    order*: seq[SortKey]   ## the layer's order; empty: the file's
    hidden*: seq[int]      ## traces of the gather left out (killed, hidden), ascending
    traceNames*: seq[string]
      ## a signature file's name of each trace, by its index in the file (empty for any other
      ## file): the tile's `sets` carry them, so the readout and the display header say them

  ReaderRequest* = object
    ## What a panel asks its reader for.
    read*: ReadRequest
    fields*: seq[HeaderField] ## the display header's rows
    flow*: Pipeline           ## processing for display (`displayPipeline`)
    filters*: Pipeline
      ## the layer's filters (`filterPipeline`), run before `flow`; empty for none
    filterAux*: bool          ## the auxiliary traces go through `filters` too
    flowAux*: bool            ## and through `flow` (`flowReachesAux`)
    clipPercentile*: float64
    reversed*: seq[int]       ## the gather's traces whose polarity is reversed, ascending
    excluded*: seq[int]
      ## the gather's traces the plot's filters never touch, ascending (the readers get
      ## them as own filters that run instead: `own`; this is for the tile's marks)
    killed*: seq[int] ## the gather's traces killed, ascending
    own*: seq[FilterEntry]
      ## the gather's traces that carry a filter of their own, ascending
    shifts*: seq[ShiftEntry]
      ## the gather's traces that carry a time shift, ascending
    raw*: bool ## the tile carries the samples as the file has them too
    chunkTraces*: int ## traces per read from the file; 0: `ChunkTraces`
    basis*: bool
      ## the record's level is taken over these traces and samples: the
      ## reader keeps them apart (`askLevel` reads nothing when it asks for them)

  ReaderObj = object
    lock: Lock
    changed: Cond
    panel: PanelId
    hasSource, hasOrder, hasRequest, quit: bool ## notes not taken yet
    source: ReaderSource
    order: seq[SortKey]
    orderGen: uint64
    request: ReaderRequest
    hasLevel: bool                              ## a level asked for, not taken yet
    level: ReaderRequest
    poster: Poster
    holds: HoldRelease
    started: bool
    busy: bool                                  ## serving a note
    beat: MonoTime                              ## when it last showed it is alive (`fs.now`)
    ended: bool                                 ## the thread is done
    abandoned: bool                             ## left to end on its own: its memory stays with it
    thread: Thread[ptr ReaderObj]

  PanelReader* = object
    ## A panel's reader thread. Move-only; destroying it stops the thread.
    p: ptr ReaderObj

  Positions = object
    ## The traces of a panel's positions: `traces.a + k`, or `list[k]`.
    traces: Slice[int]
    listed: bool ## `list` holds the traces shown, maybe none; else every trace of `traces`
    list: seq[int]

  RawCache = object
    ## The decoded samples of the last request read from the file, as read,
    ## before any edit or processing.
    valid: bool
    first, stride: int ## the positions of its rows: `first + row * stride`
    list: seq[int] ## the traces, one per row
    window: Slice[int] ## the samples decoded
    samples: seq[float32] ## `list.len` rows of `window.len` samples
    failed: seq[int] ## the rows that could not be decoded (left zero), ascending

  Reader = object
    ## The reader thread's own state.
    r: ptr ReaderObj
    src: ReaderSource
    name: string
    shown: Positions          ## the traces the filter keeps, in the file's order
    positions: Positions      ## the same, in the order shown
    sorted: bool              ## `positions` follow the newest order taken
    orderGen: uint64          ## requests from before the newest order are not served
    layout: PanelLayout
    raw: RawCache
    owed: ReaderRequest       ## the record's level to work out when nothing else waits
    hasOwed: bool
    basisRaw: RawCache        ## the samples of the traces `owed` reads, as decoded
    ws: Workspace
    pool: ProcessPool         ## the processing's workers; none until first needed
    toldCut: bool             ## the file was found cut short while it was open: said once
    toldFile: ptr SeismicFile ## the file `toldCut` and `toldIo` are about
    toldFilePath: string
    toldIo: bool              ## a read of the file failed (its drive): said once until one succeeds
    lastIo: bool              ## the tile just made had rows its drive failed (`serve` says so)
    toldNotNumbers: bool      ## samples that are not numbers were found in the file: said once
    toldFilters: string       ## what was said last of the filters of `toldPath`: said once
    toldPath: string

proc `=destroy`*(x: PanelReader)
proc `=wasMoved`*(x: var PanelReader) = x.p = nil
proc `=copy`*(dest: var PanelReader; src: PanelReader) {.error.}
proc `=dup`*(src: PanelReader): PanelReader {.error.}

func isNil*(x: PanelReader): bool {.inline.} =
  ## Whether `x` was never started (a default `PanelReader`).
  x.p == nil

func len(p: Positions): int =
  if p.listed: p.list.len else: p.traces.len

func traceAt(p: Positions; k: int): int {.inline.} =
  if p.listed: p.list[k] else: p.traces.a + k

# ------------------------------------------------------------ the thread --

proc note(rd: Reader; severity: Severity; text: string) =
  ## Posts `text` for the log, about the panel's file.
  rd.r.poster.post Msg(job: NoJob, kind: mkLog, entry: LogEntry(time: getTime(),
    severity: severity, source: rd.name, text: text))

proc tellFilters(rd: var Reader; text: string) =
  ## Says why the filters do not run on the panel's file, once for the file
  ## and that reason: a slider dragged asks again every frame.
  if rd.toldPath != rd.src.path or rd.toldFilters != text:
    rd.toldPath = rd.src.path
    rd.toldFilters = text
    rd.note(sevError, text)

proc interrupted(r: ptr ReaderObj): bool =
  ## Whether a newer note is waiting: then the current work is given up.
  ## A sign of life too.
  let now = fs.now()
  withLock r.lock:
    r.beat = now
    result = r.quit or r.hasSource or r.hasOrder or r.hasRequest

proc superseded(r: ptr ReaderObj): bool {.raises: [].} =
  ## Whether a newer source or order is waiting, or the reader must stop: a
  ## sort gives up then (a newer request alone does not stop it).
  withLock r.lock:
    result = r.quit or r.hasSource or r.hasOrder

proc letGo(rd: var Reader) =
  ## Stops touching the file and ends its hold.
  if rd.src.file != nil:
    clearCycleRoots()
    discard rd.r.holds.release(rd.src.path)
  rd.src = ReaderSource()
  rd.shown = Positions()
  rd.positions = Positions()
  rd.sorted = false
  rd.layout = PanelLayout()
  rd.raw = RawCache()
  rd.owed = ReaderRequest()
  rd.hasOwed = false
  rd.basisRaw = RawCache()
  rd.lastIo = false
  rd.toldNotNumbers = false

proc arrange(rd: var Reader; order: seq[SortKey]) =
  ## Puts the positions in `order` (the traces the filter keeps, sorted),
  ## unless a newer note comes first: then they stay as they were and
  ## `sorted` is false until the next order is taken.
  rd.src.order = order
  rd.sorted = false
  if order.len == 0:
    rd.positions = rd.shown
    rd.sorted = true
  else:
    let f = rd.src.file
    template base: untyped = rd.shown # not copied: `rows` points into its list
    let rows = if base.listed: f[].rowsOf(base.list) else: f[].rowsOf(base.traces)
    var perm: seq[int]
    let r = rd.r
    let setNumber = proc (t: int): int {.gcsafe, raises: [].} = f[].channelSetNumberOf(t)
    if sortRowsInto(rows, order, perm, proc (): bool = r.superseded, setNumber):
      var list = newSeq[int](perm.len)
      for k, row in perm: list[k] = base.traceAt(row)
      rd.positions = Positions(traces: base.traces, listed: true, list: list)
      rd.sorted = true
  if rd.sorted:
    # The traces in the order shown, for the panel (a Shift + click's range).
    var shown = newSeq[int](rd.positions.len)
    for k in 0 ..< shown.len: shown[k] = rd.positions.traceAt(k)
    rd.r.poster.post Msg(job: NoJob, kind: mkOrder, orderPanel: rd.r.panel,
      orderGen: max(rd.src.gen, rd.orderGen), positions: shown)

proc adopt(rd: var Reader; src: sink ReaderSource) =
  ## Starts showing `src`: its positions, its layout, posted; then the
  ## positions are sorted in its order.
  rd.src = src
  rd.name = rd.src.path.extractFilename
  if rd.src.file == nil: return
  if rd.src.file != rd.toldFile or rd.src.path != rd.toldFilePath:
    # another file, or the same opened again: what was said of the one before
    # is said again (a gather, a filter or a hidden trace is the same file)
    (rd.toldFile, rd.toldFilePath) = (rd.src.file, rd.src.path)
    rd.toldCut = false
    rd.toldIo = false
  let f = rd.src.file
  let g = rd.src.traces
  if not f[].hasKeys: # files are opened with their keys; without them nothing here works
    raise newException(ValueError, "it was opened without its trace keys")
  let rows = f[].rowsOf(g)
  var list: seq[int] = @[]
  var all = true
  var counts: array[256, int]
  var sensors: array[256, uint8]
  var mixed: set[uint8]
  var excluded = 0
  var want = rd.src.filter.components
  for k in 0 ..< rows.len:
    let keys = rows.keysAt(k)
    let seismic = keys.isSeismic
    let kindOk = (seismic and rd.src.filter.seismic) or
      (not seismic and rd.src.filter.auxiliary)
    if kindOk and rd.src.hidden.binarySearch(g.a + k) < 0:
      let c = componentOf(keys)
      if c != 0:
        if counts[c] == 0: sensors[c] = keys.sensorType
        elif sensors[c] != keys.sensorType: mixed.incl c
        inc counts[c]
      if passesComponent(c, want): list.add g.a + k
      else:
        all = false
        inc excluded
    else:
      all = false
  # Every component present is off, and that leaves no trace: show them all.
  var cleared = false
  if list.len == 0 and excluded > 0:
    cleared = true
    want = {}
    rd.src.filter.components = {}
    rd.note(sevInfo, ComponentsRestored)
    list.setLen 0
    all = true
    for k in 0 ..< rows.len:
      let keys = rows.keysAt(k)
      let seismic = keys.isSeismic
      let kindOk = (seismic and rd.src.filter.seismic) or
        (not seismic and rd.src.filter.auxiliary)
      if kindOk and rd.src.hidden.binarySearch(g.a + k) < 0: list.add g.a + k
      else: all = false
  var rawCodes, rawSensors: seq[uint8] = @[]
  var rawCounts: seq[int] = @[]
  for code in 1'u8 .. 255'u8:
    if counts[code] > 0:
      rawCodes.add code
      rawSensors.add if code in mixed: 0'u8 else: sensors[code]
      rawCounts.add counts[code]
  let present = buttonFaces(rawCodes, rawSensors, rawCounts)
  rd.shown = if all: Positions(traces: g)
             else: Positions(traces: g, listed: true, list: list)
  rd.positions = rd.shown
  let n = rd.shown.len
  var known: set[HeaderField]
  var widest: array[HeaderField, int]
  var layout = PanelLayout(traces: n, dtMs: 1, t0Ms: 0)
  if n > 0:
    layout.samples = if all: f[].maxSamples(g) else: f[].maxSamples(list)
    # The time axis is the first seismic trace's (auxiliary traces shown
    # among them are drawn at its interval: said when theirs differs).
    var first = 0
    while first < n - 1 and not f[].traceKeys(rd.positions.traceAt(first)).isSeismic:
      inc first
    let k0 = f[].traceKeys(rd.positions.traceAt(first))
    if k0.intervalUs > 0 and k0.intervalUs < Inf:
      layout.dtMs = k0.intervalUs / 1000
      if rd.src.filter.auxiliary and rd.src.filter.seismic:
        var other = 0
        for k in 0 ..< n:
          let keys = f[].traceKeys(rd.positions.traceAt(k))
          if not keys.isSeismic and keys.intervalUs != k0.intervalUs: inc other
        if other > 0:
          rd.note(sevWarning, $other & " auxiliary traces of " & rd.name & " have another " &
            "sample interval than the seismic traces, and are drawn at theirs (" &
            $(k0.intervalUs / 1000) & " ms): their times are not to scale.")
    else:
      layout.noInterval = true
      rd.note(sevWarning, "The sample interval of " & rd.name & " is not known: the time " &
        "axis counts samples (1 ms each), and the filters' pass band and notches, set in " &
        "Hz, are not applied to it.")
    if k0.t0Ms.classify notin {fcNan, fcInf, fcNegInf}: layout.t0Ms = k0.t0Ms
    let step = max(1, n div HeaderScan)
    var k = 0
    while k < n:
      let t = rd.positions.traceAt(k)
      let keys = f[].traceKeys(t)
      for field in HeaderField:
        if not keys.value(field, t, f[].channelSetNumberOf(t)).isNaN: known.incl field
      k += step
    # The longest value of each field the traces have, over all of them: the
    # header's columns, time across, keep their widths as the view pans.
    for k in 0 ..< n:
      let t = rd.positions.traceAt(k)
      let keys = f[].traceKeys(t)
      for field in known:
        widest[field] = max(widest[field],
          numberChars(keys.value(field, t, f[].channelSetNumberOf(t))))
    if layout.samples == 0:
      rd.note(sevWarning, "The traces shown of " & rd.name & " have no samples, so the plot " &
        "stays empty.")
  rd.layout = layout
  var codes, compSensors: seq[uint8] = @[]
  var compCounts: seq[int] = @[]
  for t in present:
    codes.add t.code
    compCounts.add t.count
    compSensors.add t.sensor
  rd.r.poster.post Msg(job: NoJob, kind: mkLayout, panel: rd.r.panel,
    sourceGen: rd.src.gen, layout: layout, known: known, widest: widest,
    components: codes, componentCounts: compCounts, componentSensors: compSensors,
    componentsCleared: cleared)
  # The layout does not depend on the order, so it goes first: the panel can
  # ask for its view while the traces are sorted.
  let order = rd.src.order
  rd.arrange(order)

proc levelOf(rd: var Reader; tile: Tile; list: seq[int]; excluded: seq[int];
    percentile: float64): Level =
  ## The RMS, the peak and the `percentile` of |x| over the tile's live
  ## traces, the rows `excluded` (not decoded, or killed) left out; over its
  ## auxiliary traces when it has no live one (a plot of a pilot alone); NaN
  ## when there are none.
  result = Level()
  if tile.request.count == 0 or tile.columns == 0: return
  try:
    let rows = rd.src.file[].rowsOf(list)
    let dt = rd.layout.dtMs * float64(tile.request.decimation)
    let b = rowBlock(tile.data, tile.request.count, tile.columns)
    rd.ws.reserve(panelStatsWorkspace)
    var s = panelStats(b, initChunkMeta(rows, dt, tile.request.firstSample, excluded), rd.ws,
      percentile)
    if s.rows == 0 and rows.hasAuxiliary:
      var keys: seq[TraceKeys]
      var lengths: seq[int]
      s = panelStats(b, initChunkMeta(rows.auxLiveRows(keys, lengths), dt,
        tile.request.firstSample, excluded), rd.ws, percentile)
    if s.rows > 0: result = Level(rms: s.rms, peak: s.maxAbs, clip: s.clip)
  except ValueError as e:
    rd.note(sevWarning, "Cannot work out the display gain of " & rd.name & ": " & e.msg)

proc readyForProcessing(b: RowBlock[float32]; rows: TraceRows): int =
  ## Blanks the rows of `b` marked dead in the file and sets every sample
  ## that is not a number to 0: the display processing leaves such a row as
  ## it is, and it would stand out at its raw amplitude. Returns how many
  ## rows held a sample that is not a number.
  for k in 0 ..< b.len:
    let row = b.rowPtr(k)
    if rows.keysAt(k).status == tsDead:
      for i in 0 ..< b.cols: row[i] = 0
    else:
      var bad = false
      for i in 0 ..< b.cols:
        if not (abs(row[i]) < Inf): # NaN fails the test too
          row[i] = 0
          bad = true
      if bad: inc result

proc applyPipe(samples: var seq[float32]; keys: TraceKeys; dtMs: float64; pipe: Pipeline;
    aux: bool) =
  ## `pipe` on one whole trace, in place. Auxiliary traces are passed by
  ## unless `aux` (the plot's filters do that; a trace's own filter does not).
  if pipe.len == 0 or samples.len == 0 or not (dtMs > 0): return
  var keySeq = @[keys]
  let counts = @[samples.len]
  let rows = rowsOf(keySeq, counts)
  var spareKeys: seq[TraceKeys] = @[]
  var spareLens: seq[int] = @[]
  let meta = if aux: initChunkMeta(rows.auxLiveRows(spareKeys, spareLens), dtMs)
             else: initChunkMeta(rows, dtMs)
  let plan = pipe.compile(float32, dtMs, samples.len, recordSamples = samples.len)
  var ws = initWorkspace()
  ws.reserve(plan)
  var view = rowBlock(samples, 1, samples.len)
  plan.apply(view, meta, ws)

proc applyPreparedTrace*(samples: var seq[float32]; keys: TraceKeys; dtMs: float64;
    reversed: bool; plot: Processing; applyPlot: bool; own: OwnFilter; applyOwn: bool) =
  ## The sample maths `prepare` runs on one whole trace, without the display
  ## gain: a dead trace blanked, a sample that is not a number set to 0,
  ## polarity reversed, then the plot's filters and the trace's own. Nothing
  ## is done when none of those are asked for, so a trace written as recorded
  ## stays as it was read. An own filter set to "instead" leaves the plot's
  ## filters off that trace. Auxiliary traces take the plot's filters only
  ## when `plot.aux` is on.
  let plotOn = applyPlot and plot.filtering and own.place != fpInstead
  let ownOn = applyOwn and own.spec.hasFilters
  if samples.len == 0 or not reversed and not plotOn and not ownOn: return
  var keySeq = @[keys]
  let counts = @[samples.len]
  let rows = rowsOf(keySeq, counts)
  var view = rowBlock(samples, 1, samples.len)
  discard readyForProcessing(view, rows)
  if keys.status == tsDead: return
  if reversed: reversePolarity(samples)
  if plotOn: applyPipe(samples, keys, dtMs, plot.filterPipeline(dtMs), plot.aux)
  if ownOn: applyPipe(samples, keys, dtMs, own.ownPipeline(dtMs), true)

type Preparing = object
  ## What every block of one request is readied with (`prepare`).
  edits: seq[set[TraceEdit]] ## per row of the request; empty: none
  filtering: bool
  filterPlan: PipelinePlan[float32]
  filterAux: bool
  flowAux: bool
  filtered: int              ## rows passed to the pool for the filters
  ownAt: seq[int]            ## per row of the request: index into `ownKeys`, or -1
  ownKeys: seq[OwnFilter]
  ownPlans: seq[PipelinePlan[float32]]
  ownReady: seq[bool]
  shiftRows: seq[int]        ## rows of the request that carry a shift, ascending
  shiftMs: seq[float64]      ## their shifts, in milliseconds
  processing: bool
  plan: PipelinePlan[float32]
  firstSample: int           ## the trace sample of column 0
  notNumbers: int            ## rows that held a sample that is not a number

proc poolOf(rd: var Reader): lent ProcessPool =
  ## The reader's pool, started on first use: up to 4 workers, half the
  ## cores (several panels' readers share the machine).
  if rd.pool.workers == 0:
    rd.pool = newProcessPool(clamp(countProcessors() div 2, 1, 4))
  rd.pool

func unionAsc(a, b: openArray[int]): seq[int] =
  ## The values of `a` and of `b` (both ascending), ascending, each once.
  result = newSeqOfCap[int](a.len + b.len)
  var i, j = 0
  while i < a.len or j < b.len:
    let x = if j >= b.len or (i < a.len and a[i] <= b[j]): a[i] else: b[j]
    if result.len == 0 or result[^1] != x: result.add x
    if i < a.len and a[i] == x: inc i
    if j < b.len and b[j] == x: inc j

func ownIndex(own: openArray[FilterEntry]; trace: int): int =
  ## Where `trace` sits in `own` (ascending); -1 when it has no filter.
  var lo = 0
  var hi = own.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if own[mid].trace < trace: lo = mid + 1
    else: hi = mid
  if lo < own.len and own[lo].trace == trace: lo else: -1

proc applyOwn(rd: var Reader; pr: var Preparing; b: RowBlock[float32]; rows: TraceRows;
    first: int; passed: openArray[int]) =
  ## Each row's own filter, after the plot's (a row set to "instead" was
  ## left out of those). A killed, dead or undecoded row stays blank.
  for key, ready in pr.ownReady:
    if ready:
      var group: seq[int]
      for k in 0 ..< b.len:
        if pr.ownAt[first + k] == key and passed.binarySearch(k) < 0: group.add k
      if group.len > 0:
        var skip = newSeqOfCap[int](b.len - group.len)
        var g = 0
        for k in 0 ..< b.len:
          if g < group.len and group[g] == k: inc g
          else: skip.add k
        var keys: seq[TraceKeys]
        var lengths: seq[int]
        let live = initChunkMeta(rows.auxLiveRows(keys, lengths), rd.layout.dtMs,
          pr.firstSample, skip)
        try:
          rd.poolOf.apply(pr.ownPlans[key], b, live)
        except ValueError as e:
          rd.tellFilters("A trace's filter stopped on " & rd.name & ": " & e.msg)
          pr.ownReady[key] = false

proc prepare(rd: var Reader; pr: var Preparing; b: RowBlock[float32]; rows: TraceRows;
    first: int; failedRows: openArray[int]) =
  ## Readies rows `first ..< first + b.len` of a request, decoded into `b`
  ## (`rows`: their traces; `failedRows`: those not decoded, 0-based in the
  ## block, ascending) for the tile: killed rows and rows marked dead in the
  ## file blanked, samples that are not numbers set to 0, the samples of
  ## reversed rows negated, then the filters (the auxiliary rows too when
  ## asked) and the display processing, on the pool, which pass by the
  ## blank rows and those not decoded.
  pr.notNumbers += readyForProcessing(b, rows)
  var passed: seq[int] # rows of the block not decoded, killed or dead, ascending
  var fi = 0
  for k in 0 ..< b.len:
    while fi < failedRows.len and failedRows[fi] < k: inc fi
    let killed = pr.edits.len > 0 and teKilled in pr.edits[first + k]
    if killed:
      let row = b.rowPtr(k)
      for i in 0 ..< b.cols: row[i] = 0
    if killed or rows.keysAt(k).status == tsDead or
        (fi < failedRows.len and failedRows[fi] == k):
      passed.add k
  try:
    let meta = initChunkMeta(rows, rd.layout.dtMs, pr.firstSample, passed)
    if pr.edits.len > 0:
      for k in 0 ..< b.len:
        if teReversed in pr.edits[first + k] and not meta.isFailed(k):
          reversePolarity(b.row(k, meta.liveSamples(k, b.cols)))
    if pr.shiftRows.len > 0 and b.len > 0:
      var si = 0
      for k in 0 ..< b.len:
        let row = first + k
        while si < pr.shiftRows.len and pr.shiftRows[si] < row: inc si
        if si < pr.shiftRows.len and pr.shiftRows[si] == row and not meta.isFailed(k) and
            rows.keysAt(k).isSeismic:
          applyStoredShift(b.rowPtr(k).toOpenArray(0, b.cols - 1), pr.shiftMs[si],
            rd.layout.dtMs)
    if pr.filtering and b.len > 0:
      try:
        var instead: seq[int]
        if pr.ownAt.len > 0:
          for k in 0 ..< b.len:
            let oi = pr.ownAt[first + k]
            if oi >= 0 and pr.ownKeys[oi].place == fpInstead: instead.add k
        if pr.filterAux and rows.hasAuxiliary:
          var keys: seq[TraceKeys]
          var lengths: seq[int]
          let skip = if instead.len == 0: passed else: unionAsc(passed, instead)
          let live = initChunkMeta(rows.auxLiveRows(keys, lengths), rd.layout.dtMs,
            pr.firstSample, skip)
          rd.poolOf.apply(pr.filterPlan, b, live)
        elif instead.len == 0:
          rd.poolOf.apply(pr.filterPlan, b, meta)
        else:
          let skip = unionAsc(passed, instead)
          let plotMeta = initChunkMeta(rows, rd.layout.dtMs, pr.firstSample, skip)
          rd.poolOf.apply(pr.filterPlan, b, plotMeta)
        pr.filtered += b.len
      except ValueError as e:
        rd.tellFilters("The filters stopped on " & rd.name & ": " & e.msg)
        pr.filtering = false
    if pr.ownAt.len > 0 and b.len > 0:
      rd.applyOwn(pr, b, rows, first, passed)
    if pr.processing:
      if pr.flowAux and rows.hasAuxiliary:
        var keys: seq[TraceKeys]
        var lengths: seq[int]
        rd.poolOf.apply(pr.plan, b, initChunkMeta(rows.auxLiveRows(keys, lengths),
          rd.layout.dtMs, pr.firstSample, passed))
      else: rd.poolOf.apply(pr.plan, b, meta)
  except ValueError as e:
    rd.note(sevError, "The display processing stopped on " & rd.name & ": " & e.msg)
    pr.processing = false

proc tellUnread(rd: var Reader; failed, shown: int; cut, io: bool) =
  ## Says, once, that `failed` of the `shown` traces could not be read, as
  ## parseSEG's guard found: the file was cut short while it was open (rows
  ## past the cut), or a read of it failed (its drive). The rows are blank;
  ## a cut stays so until the file is opened again (said once for the
  ## file), a drive's failure is read again (Retry), said once until a read
  ## succeeds.
  let what = $failed & " of the " & $shown & " traces shown"
  if io:
    rd.lastIo = true
    if not rd.toldIo:
      rd.toldIo = true
      let again = if rd.src.file[].readFailed:
          "A file read through a map stays unread until it is opened again: Retry opens it again."
        else: "They are read again with Retry, or when the plot moves, once it answers."
      rd.note(sevWarning, rd.name & ": " & what & " could not be read and are drawn blank: " &
        "its drive is not answering (a read of the file failed). " & again)
  elif cut and not rd.toldCut:
    rd.toldCut = true
    rd.note(sevWarning, rd.name & " was cut short while it was open (another program cut it " &
      "or is writing it again): " & what & " lie past its new end and are drawn blank. Open " &
      "it again to see what it holds now.")

func heldRows(raw: RawCache; q: ReadRequest; list: seq[int]; window: Slice[int]): seq[int] =
  ## Where each row of request `q` (its traces `list`, its samples `window`)
  ## is in the raw samples `raw`: when they hold every one of its traces
  ## (the same view, or a part of it: fewer traces, every second one, ...,
  ## as a turn or a zoom out to a coarser stride asks) and its samples;
  ## none otherwise.
  if not raw.valid or raw.stride <= 0 or window.a < raw.window.a or
      window.b > raw.window.b:
    return
  result = newSeq[int](q.count)
  for row in 0 ..< q.count:
    let d = q.position(row) - raw.first
    let i = d div raw.stride
    if d < 0 or d mod raw.stride != 0 or i >= raw.list.len or raw.list[i] != list[row]:
      return @[] # not held, or another trace there now (a sort)
    result[row] = i

proc levelWaits(r: ptr ReaderObj): bool =
  ## Whether a work out of the record's level is to be given up: any newer
  ## note, a newer level among them.
  result = r.interrupted
  if not result:
    withLock r.lock:
      result = r.hasLevel

proc levelSuperseded(r: ptr ReaderObj): bool =
  ## Whether a read of the record's level's samples from the file is to be
  ## given up: a new source or order, a stop, or a newer level (a view asked
  ## for meanwhile waits for its few reads instead: begun again, they would
  ## never end while the user pans).
  result = r.superseded
  if not result:
    withLock r.lock:
      result = r.hasLevel

proc make(rd: var Reader; req: ReaderRequest; level: bool; tile: var Tile;
    given: var bool): bool =
  ## Reads and processes the tile `req` asks for into `tile`; false when
  ## there is none (`given`: a newer note came first). The samples come from
  ## the file through a prefetcher, or, when the last request read from the
  ## file had the same traces and these samples among its own, from what it
  ## read (`RawCache`). For the record's `level` (`askLevel`), from those of
  ## the level asked for before when they hold them (`basisRaw`, else what
  ## was read last), else read into them; given up for any newer note.
  result = false
  given = false
  let q = req.read
  let f = rd.src.file
  if q.isEmpty or q.first < 0 or q.last >= rd.positions.len: return
  var list = newSeq[int](q.count)
  for row in 0 ..< q.count: list[row] = rd.positions.traceAt(q.position(row))
  let window = q.decodeSpan(rd.layout.samples)
  let skip = q.firstSample - window.a # decoded columns before the kept ones
  let cols = window.len
  var pr = Preparing(processing: req.flow.len > 0, filtering: req.filters.len > 0,
    filterAux: req.filterAux, flowAux: req.flowAux, firstSample: window.a)
  if pr.filtering:
    try:
      pr.filterPlan = req.filters.compile(float32, rd.layout.dtMs, cols,
        recordSamples = rd.layout.samples)
    except ValueError as e:
      rd.tellFilters("The filters cannot run on " & rd.name & ": " & e.msg)
      pr.filtering = false
  if pr.processing:
    try:
      pr.plan = req.flow.compile(float32, rd.layout.dtMs, cols,
        recordSamples = rd.layout.samples)
    except ValueError as e:
      rd.note(sevError, "The display processing cannot run on " & rd.name & ": " & e.msg)
      pr.processing = false
  if level and rd.r.levelWaits: # (compiling the filters can take long)
    given = true
    return
  tile = Tile(panel: rd.r.panel, request: q, dtMs: rd.layout.dtMs, t0Ms: rd.layout.t0Ms,
    columns: q.columns, fields: req.fields)
  tile.data = newSeq[float32](q.count * tile.columns)
  if q.envelope: tile.envelope = newSeq[float32](q.count * 2 * tile.columns)
  tile.keys = newSeq[TraceKeys](q.count)
  if req.raw: tile.raw = newSeq[float32](q.count * tile.columns)
  tile.header = newSeq[seq[float64]](req.fields.len)
  for h in tile.header.mitems: h = newSeq[float64](q.count)
  # the edits of each row
  if req.killed.len > 0 or req.reversed.len > 0 or req.excluded.len > 0:
    pr.edits = newSeq[set[TraceEdit]](q.count)
    var any = false
    for row, t in list:
      if req.killed.binarySearch(t) >= 0: pr.edits[row].incl teKilled
      if req.reversed.binarySearch(t) >= 0: pr.edits[row].incl teReversed
      if req.excluded.binarySearch(t) >= 0: pr.edits[row].incl teExcluded
      if pr.edits[row] != {}: any = true
    if any: tile.edits = pr.edits
    else: pr.edits.setLen 0
  if req.own.len > 0:
    pr.ownAt = newSeq[int](q.count)
    for i in pr.ownAt.mitems: i = -1
    for row, t in list:
      let at = ownIndex(req.own, t)
      if at >= 0:
        let f = req.own[at].filter
        var key = -1
        for i, k in pr.ownKeys:
          if k == f: key = i
        if key < 0:
          pr.ownKeys.add f
          key = pr.ownKeys.high
          var plan: PipelinePlan[float32]
          var ready = false
          if f.spec.hasFilters:
            try:
              let pipe = f.ownPipeline(rd.layout.dtMs)
              if pipe.len > 0:
                plan = pipe.compile(float32, rd.layout.dtMs, cols,
                  recordSamples = rd.layout.samples)
                ready = true
            except ValueError as e:
              rd.tellFilters("A trace's filter cannot run on " & rd.name & ": " & e.msg)
          pr.ownPlans.add plan
          pr.ownReady.add ready
        pr.ownAt[row] = key
  if req.shifts.len > 0:
    for row, t in list:
      let ms = shiftAt(req.shifts, t)
      if ms != 0.0:
        pr.shiftRows.add row
        pr.shiftMs.add ms

  template cutRaw(b: RowBlock[float32]; first: int) =
    ## Rows `first ..< first + b.len` of the tile's raw samples, from `b` as
    ## decoded (before `prepare`).
    if req.raw:
      for k in 0 ..< b.len:
        let at = (first + k) * tile.columns
        decimatePeakInto(b.rowPtr(k).toOpenArray(skip, skip + q.samples - 1), q.decimation,
          tile.raw.toOpenArray(at, at + tile.columns - 1))

  template cut(b: RowBlock[float32]; rows: TraceRows; first: int) =
    ## Rows `first ..< first + b.len` of the tile, from the readied block `b`.
    for k in 0 ..< b.len:
      let row = first + k
      let src = b.rowPtr(k)
      let at = row * tile.columns
      decimatePeakInto(src.toOpenArray(skip, skip + q.samples - 1), q.decimation,
        tile.data.toOpenArray(at, at + tile.columns - 1))
      if q.envelope: # the wiggles' peaks, zoomed out in time
        let e = 2 * at
        minMaxInto(src.toOpenArray(skip, skip + q.samples - 1), q.decimation,
          tile.envelope.toOpenArray(e, e + 2 * tile.columns - 1))
      let keys = rows.keysAt(k)
      tile.keys[row] = keys
      if keys.status == tsDead:
        if tile.dead.len == 0: tile.dead = newSeq[bool](q.count)
        tile.dead[row] = true
      let joined = rd.src.file[].index.joinedGroups(list[row])
      if joined != {}:
        if tile.joined.len == 0: tile.joined = newSeq[set[JoinGroup]](q.count)
        tile.joined[row] = joined
      for i, field in req.fields:
        tile.header[i][row] = keys.value(field, list[row], f[].channelSetNumberOf(list[row]))
      if f[].kind == skSegd:
        if tile.sets.len == 0: tile.sets = newSeq[string](q.count)
        tile.sets[row] = f[].channelSetText(list[row])
      elif rd.src.traceNames.len > 0:
        if tile.sets.len == 0: tile.sets = newSeq[string](q.count)
        if list[row] in 0 ..< rd.src.traceNames.len: tile.sets[row] = rd.src.traceNames[list[row]]

  var failed: seq[int]
  var atHand = addr rd.raw # the samples at hand that hold the request's, if any
  var at = heldRows(rd.raw, q, list, window)
  if level:
    let inBasis = heldRows(rd.basisRaw, q, list, window)
    if inBasis.len > 0: (atHand, at) = (addr rd.basisRaw, inBasis)
  if at.len > 0:
    # The samples are at hand: nothing is read from the file.
    let held = atHand[].window.len
    let offset = window.a - atHand[].window.a
    tile.cached = true
    var heldFailed = newSeq[bool](atHand[].list.len)
    for r in atHand[].failed: heldFailed[r] = true
    for row in 0 ..< q.count:
      if heldFailed[at[row]]: failed.add row
    tile.failed = failed.len
    var work = newSeq[float32](min(HeldTraces, q.count) * cols)
    var a = 0
    while a < q.count:
      let n = min(HeldTraces, q.count - a)
      let part = list[a ..< a + n] # outlives the rows' view
      let rows = f[].rowsOf(part)
      work.setLen n * cols
      if cols > 0:
        for k in 0 ..< n:
          copyMem(addr work[k * cols], addr atHand[].samples[at[a + k] * held + offset],
            cols * sizeof(float32))
      let b = rowBlock(work, n, cols)
      var partFailed: seq[int]
      for fr in failed:
        if fr in a ..< a + n: partFailed.add fr - a
      cutRaw(b, a)
      rd.prepare(pr, b, rows, a, partFailed)
      cut(b, rows, a)
      a += n
      # Finished even when a newer request waits (it is taken next): work on
      # samples at hand is bounded, and a slider dragged sends a request
      # every frame, which would otherwise stop every tile before its end
      # and draw none until the slider stops. A new source or order, or a
      # stop, still ends it.
      if (if level: rd.r.levelWaits else: rd.r.interrupted and rd.r.superseded):
        given = true
        break
  else:
    let into = if level: addr rd.basisRaw else: addr rd.raw
    let keep = q.count * cols <= (if level: MaxBasisValues else: MaxRawSamples)
    if keep: # its buffer reused
      into[].valid = false
      into[].first = q.first
      into[].stride = q.stride
      into[].list = list
      into[].window = window
      into[].samples.setLen q.count * cols
      into[].failed.setLen 0
    else: into[] = RawCache() # too large to keep: the one before goes too
    var firstError = ""
    var cutSeen, ioSeen = false # parseSEG's guard: rows past a cut, rows a drive failed
    var waitFrom = fs.now()
    let chunk = if req.chunkTraces > 0: req.chunkTraces else: ChunkTraces
    # Asks parseSEG's guard first: a mapped file's read past a cut finds it
    # by itself, but an unmapped one's cache keeps the bytes it holds until
    # something asks (`cutShort`: one `fstat`), and it must not draw them.
    discard f[].cutShort
    var pf = newPrefetcher[float32](f[], list, chunkTraces = chunk, cols = cols,
      firstSample = window.a, workers = DecodeWorkers, quickFirst = true, uniform = true)
    var c: PrefetchChunk[float32]
    while pf.nextInto(c):
      fs.mappedRead(rd.src.path) # (tests: the chunk's pages come late, or never)
      tile.readTime += fs.now() - waitFrom
      inc tile.chunks
      let b = rowBlock(c.samples)
      if keep and c.count * cols > 0: # as read, before anything changes them
        copyMem(addr into[].samples[c.first * cols], b.rowPtr(0), c.count * cols *
          sizeof(float32))
      cutRaw(b, c.first)
      rd.prepare(pr, b, c.rows, c.first, c.failedRows)
      cut(b, c.rows, c.first)
      for fr in c.failedRows: failed.add c.first + fr
      tile.failed += c.failed
      if c.failed > 0 and firstError.len == 0 and c.log.len > 0:
        firstError = c.log[0].msg
      for d in c.log:
        if d.code == dcTruncated: cutSeen = true
        elif d.code == dcIo: ioSeen = true
      if (if level: rd.r.levelSuperseded else: rd.r.interrupted):
        given = true
        break
      waitFrom = fs.now()
    discard pf.close() # false when a worker stuck in a read is left to finish
    clearCycleRoots()
    if keep and not given:
      into[].failed = failed
      into[].valid = not ioSeen # rows a drive failed are read again, not kept blank
    rd.lastIo = false
    if not given and tile.failed > 0:
      if cutSeen or ioSeen: rd.tellUnread(tile.failed, q.count, cutSeen, ioSeen)
      else:
        rd.note(sevWarning, $tile.failed & " of the " & $q.count & " traces shown could not " &
          "be read and are drawn blank" & (if firstError.len > 0: ": " & firstError else: "") &
          ".")
    elif not given and not level and not f[].readFailed:
      rd.toldIo = false # (said again if its drive fails again)
  if given: return
  tile.filtered = pr.filtered
  tile.traces = list
  var excluded = failed # rows left out of the level: not decoded, killed or dead
  for row in 0 ..< q.count:
    if tile.isBlank(row): excluded.add row
  excluded.sort()
  var unique: seq[int]
  for row in excluded:
    if unique.len == 0 or unique[^1] != row: unique.add row
  tile.level = rd.levelOf(tile, list, unique, req.clipPercentile)
  if pr.notNumbers > 0 and not rd.toldNotNumbers:
    rd.toldNotNumbers = true
    rd.note(sevWarning, $pr.notNumbers & " of the " & $q.count & " traces shown of " & rd.name &
      " hold samples that are not numbers (NaN or infinite), which are drawn as 0: the file " &
      "may hold a bad conversion or a damaged block.")
  if req.basis and not level and rd.raw.samples.len <= MaxBasisValues and
      heldRows(rd.raw, q, list, window).len > 0:
    rd.basisRaw = rd.raw # the record's level is taken over them again, read once
  result = true

proc serve(rd: var Reader; req: sink ReaderRequest) =
  ## Reads, processes and posts the tile `req` asks for, unless a newer note
  ## comes first.
  var tile: Tile
  var given = false
  rd.lastIo = false
  if rd.make(req, level = false, tile, given):
    rd.r.poster.post Msg(job: NoJob, kind: mkTile, tile: move tile)
    if rd.lastIo: # after the tile, which clears it: the plot says its drive is not answering
      rd.r.poster.post Msg(job: NoJob, kind: mkUnread, unreadPanel: rd.r.panel,
        unreadGen: rd.src.gen, cause: ucFailed, why: "Reading " & rd.name & ": its drive is " &
        "not answering, so some traces are blank. Retry reads them again when it answers.")

proc serveLevel(rd: var Reader) =
  ## Works out the record's level owed (`askLevel`) and posts it, as a tile
  ## that holds no samples (`levelOnly`), unless a newer note comes first:
  ## then it is still owed, for when nothing else waits. When there is none
  ## (the file cannot be read now, or the read fails), a tile that asks for
  ## nothing says so, and the panel keeps the level it has.
  var tile: Tile
  var given, made = false
  rd.hasOwed = false
  try:
    made = rd.make(rd.owed, level = true, tile, given)
  finally:
    if given: rd.hasOwed = true
    elif made:
      rd.r.poster.post Msg(job: NoJob, kind: mkTile, tile: Tile(panel: tile.panel,
        request: tile.request, dtMs: tile.dtMs, t0Ms: tile.t0Ms, level: tile.level,
        cached: tile.cached, levelOnly: true))
    else:
      rd.r.poster.post Msg(job: NoJob, kind: mkTile, tile: Tile(panel: rd.r.panel,
        request: ReadRequest(gen: rd.owed.read.gen), levelOnly: true))

proc run(r: ptr ReaderObj) {.thread.} =
  markWorkerThread()
  var rd = Reader(r: r, ws: initWorkspace())
  while true:
    var src: ReaderSource
    var req, lvl: ReaderRequest
    var order: seq[SortKey]
    var gotSource, gotOrder, gotRequest, gotLevel, quit = false
    let owing = rd.hasOwed and rd.src.file != nil and rd.sorted
    withLock r.lock:
      while not (r.quit or r.hasSource or r.hasOrder or r.hasRequest or r.hasLevel or owing):
        wait(r.changed, r.lock)
      quit = r.quit
      gotSource = r.hasSource
      gotOrder = r.hasOrder
      gotRequest = r.hasRequest
      if gotSource: src = move r.source
      if gotOrder:
        order = move r.order
        rd.orderGen = r.orderGen
      if gotRequest: req = move r.request
      gotLevel = r.hasLevel
      if gotLevel: lvl = move r.level
      r.hasSource = false
      r.hasOrder = false
      r.hasRequest = false
      r.hasLevel = false
      r.busy = not quit
      r.beat = fs.now()
    if gotSource or quit:
      rd.letGo()
    if quit:
      if gotSource and src.file != nil: discard r.holds.release(src.path) # never taken
      break
    try:
      if gotSource: rd.adopt(src)
      if gotOrder and rd.src.file != nil: rd.arrange(order)
      if gotLevel and rd.src.file != nil and lvl.read.gen >= rd.src.gen:
        rd.owed = move lvl
        rd.hasOwed = true
      if gotRequest and rd.src.file != nil and rd.sorted and
          req.read.gen >= max(rd.src.gen, rd.orderGen):
        rd.serve(req)
      # The record's level once nothing else waits: a view asked for comes
      # first, so the plot follows the user.
      if rd.hasOwed and rd.src.file != nil and rd.sorted and not r.levelWaits:
        rd.serveLevel()
    except CatchableError as e:
      # parseSEG's guard fails rows rather than raising; what raises is the
      # seam's drive (an `OSError` or `IOError`) or a call that reads headers
      # of a file already found cut short (`SegTruncatedError`). Said once.
      let cut = e of SegTruncatedError and not ("could not be read" in e.msg)
      let why = if cut: rd.name & " was cut short while it was open (another program cut " &
          "it or is writing it again): it is not read until it is opened again."
        else: "Cannot read " & rd.name & ": " & firstLine(e.msg) & ". Its drive is not " &
          "answering or fails; Retry reads again when it answers."
      if rd.src.file != nil:
        if (cut and not rd.toldCut) or (not cut and not rd.toldIo):
          if cut: rd.toldCut = true
          else: rd.toldIo = true
          rd.note(sevWarning, why)
        r.poster.post Msg(job: NoJob, kind: mkUnread, unreadPanel: r.panel,
          unreadGen: rd.src.gen, cause: (if cut: ucCutShort else: ucFailed), why: why)
      clearCycleRoots()
    withLock r.lock:
      r.busy = false
  rd.letGo()
  clearCycleRoots()
  withLock r.lock:
    r.busy = false
    r.ended = true

# --------------------------------------------------------------- the UI side --

const ReaderStopWait* = initDuration(milliseconds = 800)
  ## how long `stop` waits for the thread by default

proc stop*(x: PanelReader; deadline = getMonoTime() + ReaderStopWait): bool {.discardable, raises: [].}

proc `=destroy`*(x: PanelReader) =
  if x.p != nil:
    var abandoned = false
    withLock x.p.lock:
      abandoned = x.p.abandoned
    if not abandoned: discard x.stop()
    if not x.p.started: # else the thread still runs: its memory stays with it
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
    x.p.hasOrder = false # the source carries the layer's order
    x.p.hasRequest = false
    x.p.hasLevel = false
    signal(x.p.changed)
  if dropped.len > 0: discard x.p.holds.release(dropped)

proc sortBy*(x: PanelReader; gen: uint64; order: sink seq[SortKey]) =
  ## Puts the traces shown in `order` (empty: the file's order), keeping the
  ## file; requests made before `gen` are not served after it. Replaces an
  ## order not yet taken.
  assert x.p != nil
  withLock x.p.lock:
    x.p.order = order
    x.p.orderGen = gen
    x.p.hasOrder = true
    signal(x.p.changed)

proc request*(x: PanelReader; req: sink ReaderRequest) =
  ## Asks for a tile; replaces a request not yet taken.
  assert x.p != nil
  withLock x.p.lock:
    x.p.request = req
    x.p.hasRequest = true
    signal(x.p.changed)

proc askLevel*(x: PanelReader; req: sink ReaderRequest) =
  ## Asks for the record's level: the tile `req` asks for (every trace of
  ## the record, at most `MaxBasisValues` decoded), processed as it says,
  ## of which only the level is posted (`Tile.levelOnly`), once no view
  ## asked for waits; replaces a level asked for before. Its samples are
  ## kept apart from the view's, so a level asked for again (another clip
  ## percentile, a kill, a filter) reads nothing from the file.
  assert x.p != nil
  withLock x.p.lock:
    x.p.level = req
    x.p.hasLevel = true
    signal(x.p.changed)

proc askStop*(x: PanelReader) =
  ## Asks the thread to end, without waiting (`stop` waits).
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true
      signal(x.p.changed)

proc stop*(x: PanelReader; deadline = getMonoTime() + ReaderStopWait): bool {.discardable, raises: [].} =
  ## Stops the thread and waits for it until `deadline`: it lets go of its
  ## file first. True when it has ended; false when it is stuck (in a drive
  ## that does not answer), and it is then left to end on its own.
  ## Idempotent; destroying the reader does it.
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

proc abandon*(x: var PanelReader) =
  ## Leaves the thread to end on its own (it is stuck in a drive that does
  ## not answer): asked to stop, never waited for; `x` is none afterwards.
  ## Its hold on the file stays until it ends.
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true
      x.p.abandoned = true
      signal(x.p.changed)
    var ended = false
    withLock x.p.lock:
      ended = x.p.ended
    if ended: discard x.stop() # it had ended meanwhile: joined and freed below
    if not x.p.started:
      deinitCond(x.p.changed)
      deinitLock(x.p.lock)
      `=destroy`(x.p[])
      deallocShared(x.p)
    x.p = nil

proc silentFor*(x: PanelReader; now = fs.now()): Duration =
  ## How long the reader has been busy without a sign of life (a read that
  ## the drive does not answer); zero when it is idle or none.
  if x.p != nil:
    withLock x.p.lock:
      if x.p.busy: result = now - x.p.beat
