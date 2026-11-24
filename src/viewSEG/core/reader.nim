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
##   which nothing changes while the file is held. A correlated view is not a
##   window of the raw file: its samples are listen time, from `correlateRead`,
##   and the virtual path is not mapped.
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

import std/[algorithm, atomics, cpuinfo, locks, math, monotimes, os, strutils, times]
import parseSEG
import processSEG/pipeline
import processSEG/core/[basic, pool, rows, types, workspace]
import processSEG/gain/stats
import channelsets, components, correlateread, cutfile, edits, filesystem, inbox, jobs, log, panels,
  processing, readout, sorting, threads, tiles, viewport, wiggle

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
    view*: ref CorrelateView
      ## Set when `file` is this view of a raw file: the request's window is
      ## listen time, and the samples come from `correlateRead`. Nil: `file`
      ## is read as stored. Threads share the view; each reader keeps its own
      ## workspace.

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
    served: Atomic[int]                         ## tiles posted; a test waits on it without draining
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

  ViewSpare = object
    ## Buffers for one more identical view request, filled when a view tile is
    ## made, so the next one does not allocate. Consumed by that request.
    ready: bool
    count, cols, columns: int
    list, at: seq[int]
    heldFailed: seq[bool]
    work, data: seq[float32]
    keys: seq[TraceKeys]

  Reader = object
    ## The reader thread's own state.
    r: ptr ReaderObj
    src: ReaderSource
    name: string
    shown: Positions                 ## the traces the filter keeps, in the file's order
    positions: Positions             ## the same, in the order shown
    sorted: bool                     ## `positions` follow the newest order taken
    orderGen: uint64                 ## requests from before the newest order are not served
    layout: PanelLayout
    raw: RawCache
    owed: ReaderRequest              ## the record's level to work out when nothing else waits
    hasOwed: bool
    basisRaw: RawCache               ## the samples of the traces `owed` reads, as decoded
    ws: Workspace
    pool: ProcessPool                ## the processing's workers; none until first needed
    toldCut: bool                    ## the file was found cut short while it was open: said once
    toldFile: ptr SeismicFile        ## the file `toldCut` and `toldIo` are about
    toldFilePath: string
    toldIo: bool                     ## a read of the file failed (its drive): said once until one succeeds
    lastIo: bool                     ## the tile just made had rows its drive failed (`serve` says so)
    toldNotNumbers: bool             ## samples that are not numbers were found in the file: said once
    toldFilters: string              ## what was said last of the filters of `toldPath`: said once
    toldPath: string
    viewOf: ref CorrelateView        ## the view `viewWs` was made for; nil when none
    heldView: CorrelateView          ## that view, copied once, so a read does not copy it
    viewWs: CorrelateWorkspace
    viewRow, viewChunk: seq[float32] ## one trace, and a chunk, reused
    spare: ViewSpare

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

proc dropViewWork(rd: var Reader) =
  ## Drops the correlated workspace and the spare tile buffers. Another view
  ## or a file that is not a view does this; the same view keeps them.
  rd.viewWs = CorrelateWorkspace()
  rd.heldView = CorrelateView()
  rd.viewOf = nil
  rd.viewRow.setLen 0
  rd.viewChunk.setLen 0
  rd.spare = ViewSpare()

proc adopt(rd: var Reader; src: sink ReaderSource) =
  ## Starts showing `src`: its positions, its layout, posted; then the
  ## positions are sorted in its order. A different view, or a file that is
  ## not a view, drops the workspace the one before kept.
  if src.view != rd.viewOf: rd.dropViewWork()
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
    # The time axis is the first seismic trace's (auxiliary traces shown
    # among them are drawn at its interval: said when theirs differs).
    var first = 0
    while first < n - 1 and not f[].traceKeys(rd.positions.traceAt(first)).isSeismic:
      inc first
    let k0 = f[].traceKeys(rd.positions.traceAt(first))
    if rd.src.view != nil:
      # Listen time, never the raw record's sample count or interval.
      layout.samples = rd.src.view.listenSamples
      if rd.src.view.dtMs > 0 and rd.src.view.dtMs < Inf:
        layout.dtMs = rd.src.view.dtMs
      else:
        layout.noInterval = true
        rd.note(sevWarning, "The sample interval of " & rd.name & " is not known: the time " &
          "axis counts samples (1 ms each), and the filters' pass band and notches, set in " &
          "Hz, are not applied to it.")
    else:
      layout.samples = if all: f[].maxSamples(g) else: f[].maxSamples(list)
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

proc levelOf(rd: var Reader; tile: Tile; list: openArray[int]; excluded: openArray[int];
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

proc applyDirect(plan: PipelinePlan[float32]; b: RowBlock[float32]; meta: ChunkMeta) =
  var ws = initWorkspace()
  ws.reserve(plan)
  plan.apply(b, meta, ws)

proc applyVia(pool: var ProcessPool; plan: PipelinePlan[float32]; b: RowBlock[float32];
    meta: ChunkMeta) =
  ## `pool.apply`. A separate proc so a pool, which cannot be copied, is
  ## passed as a variable and not through a pointer dereference.
  pool.apply(plan, b, meta)

proc applyPlan(pool: ptr ProcessPool; plan: PipelinePlan[float32]; b: RowBlock[float32];
    meta: ChunkMeta) =
  if pool == nil: applyDirect(plan, b, meta)
  else: applyVia(pool[], plan, b, meta)

func unionAsc(a, b: openArray[int]): seq[int]

proc applyPreparedRows(b: RowBlock[float32]; rows: TraceRows; dtMs: float64;
    edits: openArray[set[TraceEdit]]; editAt: int; shiftRows: openArray[int];
    shiftMs: openArray[float64]; filtering: var bool; filterPlan: PipelinePlan[float32];
    filterAux: bool; ownAt: openArray[int]; ownKeys: openArray[OwnFilter];
    ownPlans: var seq[PipelinePlan[float32]]; ownReady: var seq[bool]; firstSample: int;
    passed: seq[int]; pool: ptr ProcessPool; name: string; noted: var seq[string]): int =
  ## The sample maths of one readied block, without the display gain, in the
  ## plot's order: reversed rows negated, a stored time shift applied (seismic
  ## rows only, positive later, same length), then the plot's filters and each
  ## row's own. `prepare` and `applyPreparedTrace` both call this. Rows in
  ## `passed` (killed, dead or not decoded) are left as they are. A filter that
  ## stops is named in `noted` and switched off. Returns how many rows were
  ## offered to the plot's filters.
  if b.len == 0: return
  let meta = initChunkMeta(rows, dtMs, firstSample, passed)
  if edits.len > 0:
    for k in 0 ..< b.len:
      if editAt + k < edits.len and teReversed in edits[editAt + k] and not meta.isFailed(k):
        reversePolarity(b.row(k, meta.liveSamples(k, b.cols)))
  if shiftRows.len > 0:
    var si = 0
    for k in 0 ..< b.len:
      let row = editAt + k
      while si < shiftRows.len and shiftRows[si] < row: inc si
      if si < shiftRows.len and shiftRows[si] == row and not meta.isFailed(k) and
          rows.keysAt(k).isSeismic:
        applyStoredShift(b.rowPtr(k).toOpenArray(0, b.cols - 1), shiftMs[si], dtMs)
  if filtering:
    try:
      var instead: seq[int]
      if ownAt.len > 0:
        for k in 0 ..< b.len:
          if editAt + k >= ownAt.len: continue
          let oi = ownAt[editAt + k]
          if oi >= 0 and oi < ownKeys.len and ownKeys[oi].place == fpInstead: instead.add k
      if filterAux and rows.hasAuxiliary:
        var keys: seq[TraceKeys]
        var lengths: seq[int]
        let skip = if instead.len == 0: passed else: unionAsc(passed, instead)
        let live = initChunkMeta(rows.auxLiveRows(keys, lengths), dtMs, firstSample, skip)
        applyPlan(pool, filterPlan, b, live)
      elif instead.len == 0:
        applyPlan(pool, filterPlan, b, meta)
      else:
        let skip = unionAsc(passed, instead)
        let plotMeta = initChunkMeta(rows, dtMs, firstSample, skip)
        applyPlan(pool, filterPlan, b, plotMeta)
      result = b.len
    except ValueError as e:
      noted.add "The filters stopped on " & name & ": " & e.msg
      filtering = false
  if ownAt.len == 0 or ownReady.len == 0: return
  for key, ready in ownReady:
    if not ready or key >= ownPlans.len: continue
    var group: seq[int]
    for k in 0 ..< b.len:
      if editAt + k < ownAt.len and ownAt[editAt + k] == key and passed.binarySearch(k) < 0:
        group.add k
    if group.len == 0: continue
    var skip = newSeqOfCap[int](b.len - group.len)
    var g = 0
    for k in 0 ..< b.len:
      if g < group.len and group[g] == k: inc g
      else: skip.add k
    var keys: seq[TraceKeys]
    var lengths: seq[int]
    let live = initChunkMeta(rows.auxLiveRows(keys, lengths), dtMs, firstSample, skip)
    try:
      applyPlan(pool, ownPlans[key], b, live)
    except ValueError as e:
      noted.add "A trace's filter stopped on " & name & ": " & e.msg
      ownReady[key] = false

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

const PlanSlots = 8 ## compiled plans a `TracePlans` keeps of each kind

type
  TracePlans* = object
    ## The compiled filter plans `applyPreparedTrace` reuses from one trace
    ## to the next: the plot's filters per sample interval and length, a
    ## trace's own per filter, interval and length. At most `PlanSlots` of
    ## each are kept, the oldest dropped first, so a long write holds no
    ## more. One value serves one `plot`.
    plot: seq[CachedPlan]
    own: seq[CachedPlan]
  CachedPlan = object
    filter: OwnFilter ## the own filter; unused for the plot's
    dtMs: float64
    samples: int
    plan: PipelinePlan[float32]

proc keep(slots: var seq[CachedPlan]; slot: sink CachedPlan): int =
  ## Adds `slot`, dropping the oldest when full; its index.
  if slots.len >= PlanSlots: slots.delete(0)
  slots.add slot
  slots.high

proc plotPlan(plans: var TracePlans; plot: Processing; dtMs: float64;
    samples: int): lent PipelinePlan[float32] =
  var at = -1
  for i, c in plans.plot:
    if c.dtMs == dtMs and c.samples == samples: at = i
  if at < 0:
    at = plans.plot.keep(CachedPlan(dtMs: dtMs, samples: samples,
      plan: plot.filterPipeline(dtMs).compile(float32, dtMs, samples, recordSamples = samples)))
  plans.plot[at].plan

proc ownPlan(plans: var TracePlans; own: OwnFilter; dtMs: float64; samples: int;
    plan: var PipelinePlan[float32]): bool =
  ## The trace's own filter compiled at `dtMs`, into `plan`; false when it
  ## has no stage there.
  for c in plans.own:
    if c.dtMs == dtMs and c.samples == samples and c.filter == own:
      plan = c.plan
      return true
  let pipe = own.ownPipeline(dtMs)
  if pipe.len == 0: return false
  let at = plans.own.keep(CachedPlan(filter: own, dtMs: dtMs, samples: samples,
    plan: pipe.compile(float32, dtMs, samples, recordSamples = samples)))
  plan = plans.own[at].plan
  true

proc applyPreparedTrace*(samples: var openArray[float32]; keys: TraceKeys; dtMs: float64;
    reversed: bool; shiftMs: float64; plot: Processing; applyPlot: bool; own: OwnFilter;
    applyOwn: bool; plans: var TracePlans) =
  ## One whole trace through `applyPreparedRows`, the proc `prepare` calls,
  ## without the display gain. `dtMs` is this trace's sample interval: the
  ## filters and the shift are designed at it. `plans` keeps the compiled
  ## filters for the next trace. A dead trace is blanked, a sample that is not
  ## a number is set to 0, polarity reversed, a stored time shift applied
  ## (seismic traces, positive later, same length, zeros where no sample
  ## exists), then the plot's filters and the trace's own. Nothing is done
  ## when none of those are asked for, so a trace written as recorded stays
  ## as it was read. An own filter set to "instead" leaves the plot's filters
  ## off that trace. Auxiliary traces take the plot's filters only when
  ## `plot.aux` is on, and are not shifted. A kill is not applied here: a
  ## killed trace that is kept is prepared like any other.
  let plotOn = applyPlot and plot.filtering and own.place != fpInstead
  let ownOn = applyOwn and own.spec.hasFilters
  let shifting = shiftMs != 0.0 and keys.isSeismic
  if samples.len == 0 or not reversed and not plotOn and not ownOn and not shifting: return
  var keySeq = @[keys]
  let counts = @[samples.len]
  let rows = rowsOf(keySeq, counts)
  var view = rowBlock(samples, 1, samples.len)
  discard readyForProcessing(view, rows)
  if keys.status == tsDead: return
  var edits: array[1, set[TraceEdit]]
  if reversed: edits[0].incl teReversed
  var filtering = plotOn
  var filterPlan: PipelinePlan[float32]
  if plotOn: filterPlan = plans.plotPlan(plot, dtMs, samples.len)
  var ownAt: array[1, int] = [-1]
  var ownKeys: seq[OwnFilter]
  var ownPlans: seq[PipelinePlan[float32]]
  var ownReady: seq[bool]
  if ownOn:
    var plan: PipelinePlan[float32]
    if plans.ownPlan(own, dtMs, samples.len, plan):
      ownAt[0] = 0
      ownKeys.add own
      ownPlans.add plan
      ownReady.add true
  var passed: seq[int]
  var noted: seq[string]
  var shiftRows: seq[int] = @[]
  var shiftVals: seq[float64] = @[]
  if shiftMs != 0.0:
    shiftRows.add 0
    shiftVals.add shiftMs
  discard applyPreparedRows(view, rows, dtMs, edits, 0, shiftRows, shiftVals, filtering,
    filterPlan, plot.aux, ownAt, ownKeys, ownPlans, ownReady, 0, passed, nil, "", noted)
  if noted.len > 0: raise newException(ValueError, noted[0])

proc prepare(rd: var Reader; pr: var Preparing; b: RowBlock[float32]; rows: TraceRows;
    first: int; failedRows: openArray[int]) =
  ## Readies rows `first ..< first + b.len` of a request, decoded into `b`
  ## (`rows`: their traces; `failedRows`: those not decoded, 0-based in the
  ## block, ascending) for the tile: killed rows and rows marked dead in the
  ## file blanked, samples that are not numbers set to 0, the samples of
  ## reversed rows negated, a stored time shift applied, then the filters
  ## (the auxiliary rows too when asked) and the display processing, on the
  ## pool, which pass by the blank rows and those not decoded.
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
    var pool: ptr ProcessPool = nil
    if pr.filtering or pr.ownAt.len > 0:
      discard rd.poolOf
      pool = addr rd.pool
    var noted: seq[string]
    pr.filtered += applyPreparedRows(b, rows, rd.layout.dtMs, pr.edits, first, pr.shiftRows,
      pr.shiftMs, pr.filtering, pr.filterPlan, pr.filterAux, pr.ownAt, pr.ownKeys,
      pr.ownPlans, pr.ownReady, pr.firstSample, passed, pool, rd.name, noted)
    for msg in noted: rd.tellFilters(msg)
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

func cacheHolds(raw: RawCache; q: ReadRequest; list: openArray[int]; window: Slice[int]): bool =
  ## Whether `raw` holds every trace of `q` (`list`) and the samples `window`.
  if not raw.valid or raw.stride <= 0 or list.len != q.count or
      window.a < raw.window.a or window.b > raw.window.b:
    return false
  for row in 0 ..< q.count:
    let d = q.position(row) - raw.first
    let i = d div raw.stride
    if d < 0 or d mod raw.stride != 0 or i >= raw.list.len or raw.list[i] != list[row]:
      return false
  true

func spareReady(spare: ViewSpare; raw: RawCache; view: ref CorrelateView; req: ReaderRequest;
    q: ReadRequest; window: Slice[int]; cols: int): bool =
  ## A plain view request whose samples are at hand, and whose spare buffers
  ## are this request's size: filling it allocates nothing. The caches are
  ## taken by value so the reader (and its workspace) is not copied.
  spare.ready and view != nil and not req.basis and not q.envelope and not req.raw and
    req.fields.len == 0 and req.flow.len == 0 and req.filters.len == 0 and
    req.killed.len == 0 and req.reversed.len == 0 and req.excluded.len == 0 and
    req.own.len == 0 and req.shifts.len == 0 and spare.count == q.count and
    spare.cols == cols and spare.columns == q.columns and spare.list.len == raw.list.len and
    cacheHolds(raw, q, spare.list, window)

proc stockSpare(rd: var Reader; list: sink seq[int]; count, cols, columns: int) =
  ## Keeps buffers for one more request of this size. `list` is moved in.
  rd.spare.list = list
  rd.spare.at = newSeq[int](count)
  for i in 0 ..< count: rd.spare.at[i] = i
  rd.spare.heldFailed = newSeq[bool](count)
  rd.spare.work = newSeq[float32](min(HeldTraces, count) * cols)
  rd.spare.data = newSeq[float32](count * columns)
  rd.spare.keys = newSeq[TraceKeys](count)
  rd.spare.count = count
  rd.spare.cols = cols
  rd.spare.columns = columns
  rd.spare.ready = true

func keptCount(cols, skip, samples: int): int {.inline.} =
  ## Decoded samples the kept window still has. None when it starts at or
  ## past the row; otherwise the row's tail, and never more than asked.
  if skip < 0 or cols <= skip: 0
  else: min(samples, cols - skip)

proc zeroFloats(dst: var openArray[float32]) {.inline.} =
  ## Sets every sample of `dst` to 0.
  if dst.len > 0: zeroMem(addr dst[0], dst.len * sizeof(float32))

proc decimateKept(src: ptr UncheckedArray[float32]; cols, skip, samples, decimation: int;
    dst: var openArray[float32]) =
  ## Peak-decimates `samples` of `src` from `skip` into `dst`. A window at or
  ## past the decoded row, or running past it, is zeros from there on: the
  ## slice is never formed past `cols` (an empty row's pointer is nil).
  let n = keptCount(cols, skip, samples)
  if n <= 0: zeroFloats(dst)
  else: decimatePeakInto(src.toOpenArray(skip, skip + n - 1), decimation, dst)

proc extremesKept(src: ptr UncheckedArray[float32]; cols, skip, samples, decimation: int;
    dst: var openArray[float32]) =
  ## `decimateKept` for a wiggle's column extremes.
  let n = keptCount(cols, skip, samples)
  if n <= 0: zeroFloats(dst)
  else: minMaxInto(src.toOpenArray(skip, skip + n - 1), decimation, dst)

proc markRow(rd: Reader; tile: var Tile; row, trace, count: int; keys: TraceKeys;
    fields: openArray[HeaderField]) =
  ## Dead, joined and the channel-set name of row `row` (trace `trace`), and
  ## its display-header values. `cut` and a tile filled from the spare both
  ## use it, so a dead trace stays blank when the samples were already read.
  tile.keys[row] = keys
  let f = rd.src.file
  if keys.status == tsDead:
    if tile.dead.len == 0: tile.dead = newSeq[bool](count)
    tile.dead[row] = true
  let joined = f[].index.joinedGroups(trace)
  if joined != {}:
    if tile.joined.len == 0: tile.joined = newSeq[set[JoinGroup]](count)
    tile.joined[row] = joined
  for i, field in fields:
    tile.header[i][row] = keys.value(field, trace, f[].channelSetNumberOf(trace))
  if f[].kind == skSegd:
    if tile.sets.len == 0: tile.sets = newSeq[string](count)
    tile.sets[row] = f[].channelSetText(trace)
  elif rd.src.traceNames.len > 0:
    if tile.sets.len == 0: tile.sets = newSeq[string](count)
    if trace in 0 ..< rd.src.traceNames.len: tile.sets[row] = rd.src.traceNames[trace]

proc fillFromSpare(rd: var Reader; req: ReaderRequest; q: ReadRequest; window: Slice[int];
    skip, cols: int; tile: var Tile; given: var bool): bool =
  ## The tile of a plain view request, from the samples at hand and buffers
  ## kept for it. Allocates nothing. False when a newer source, order or a
  ## stop came first (`given`).
  let f = rd.src.file
  var list = move rd.spare.list
  var at = move rd.spare.at
  var heldFailed = move rd.spare.heldFailed
  var work = move rd.spare.work
  rd.spare.ready = false
  var pr = Preparing(firstSample: window.a)
  tile = Tile(panel: rd.r.panel, request: q, dtMs: rd.layout.dtMs, t0Ms: rd.layout.t0Ms,
    columns: q.columns, cached: true)
  tile.data = move rd.spare.data
  tile.keys = move rd.spare.keys
  let held = rd.raw.window.len
  let offset = window.a - rd.raw.window.a
  if heldFailed.len > 0: zeroMem(addr heldFailed[0], heldFailed.len * sizeof(bool))
  for r in rd.raw.failed:
    if r < heldFailed.len: heldFailed[r] = true
  var failed: seq[int]
  for row in 0 ..< q.count:
    if heldFailed[at[row]]: failed.add row
  tile.failed = failed.len
  var a = 0
  while a < q.count:
    let n = min(HeldTraces, q.count - a)
    work.setLen n * cols
    if cols > 0:
      for k in 0 ..< n:
        copyMem(addr work[k * cols], addr rd.raw.samples[at[a + k] * held + offset],
          cols * sizeof(float32))
    let rows = f[].rowsOf(list.toOpenArray(a, a + n - 1))
    let b = rowBlock(work, n, cols)
    if failed.len == 0: rd.prepare(pr, b, rows, a, [])
    else:
      var partFailed: seq[int]
      for fr in failed:
        if fr in a ..< a + n: partFailed.add fr - a
      rd.prepare(pr, b, rows, a, partFailed)
    for k in 0 ..< n:
      let row = a + k
      let srcp = b.rowPtr(k)
      let atCol = row * tile.columns
      decimateKept(srcp, cols, skip, q.samples, q.decimation,
        tile.data.toOpenArray(atCol, atCol + tile.columns - 1))
      rd.markRow(tile, row, list[row], q.count, rows.keysAt(k), req.fields)
    a += n
    if rd.r.interrupted and rd.r.superseded:
      given = true
      return
  tile.filtered = pr.filtered
  if failed.len > 0:
    var excluded = failed
    excluded.sort()
    var unique: seq[int]
    for row in excluded:
      if unique.len == 0 or unique[^1] != row: unique.add row
    tile.level = rd.levelOf(tile, list, unique, req.clipPercentile)
  else:
    tile.level = rd.levelOf(tile, list, [], req.clipPercentile)
  tile.traces = move list
  result = true

proc make(rd: var Reader; req: ReaderRequest; level: bool; tile: var Tile;
    given: var bool): bool =
  ## Reads and processes the tile `req` asks for into `tile`; false when
  ## there is none (`given`: a newer note came first). The samples come from
  ## the file through a prefetcher, or, for a correlated view, from
  ## `correlateRead` on this thread, or, when the last request read from the
  ## file had the same traces and these samples among its own, from what it
  ## read (`RawCache`). For the record's `level` (`askLevel`), from those of
  ## the level asked for before when they hold them (`basisRaw`, else what
  ## was read last), else read into them; given up for any newer note.
  result = false
  given = false
  let q = req.read
  let f = rd.src.file
  if q.isEmpty or q.first < 0 or q.last >= rd.positions.len: return
  let window = q.decodeSpan(rd.layout.samples)
  let skip = q.firstSample - window.a # decoded columns before the kept ones
  let cols = window.len
  if not level and spareReady(rd.spare, rd.raw, rd.src.view, req, q, window, cols):
    if rd.fillFromSpare(req, q, window, skip, cols, tile, given): result = true
    return
  var list = newSeq[int](q.count)
  for row in 0 ..< q.count: list[row] = rd.positions.traceAt(q.position(row))
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
        decimateKept(b.rowPtr(k), cols, skip, q.samples, q.decimation,
          tile.raw.toOpenArray(at, at + tile.columns - 1))

  template cut(b: RowBlock[float32]; rows: TraceRows; first: int) =
    ## Rows `first ..< first + b.len` of the tile, from the readied block `b`.
    for k in 0 ..< b.len:
      let row = first + k
      let src = b.rowPtr(k)
      let at = row * tile.columns
      decimateKept(src, cols, skip, q.samples, q.decimation,
        tile.data.toOpenArray(at, at + tile.columns - 1))
      if q.envelope: # the wiggles' peaks, zoomed out in time
        let e = 2 * at
        extremesKept(src, cols, skip, q.samples, q.decimation,
          tile.envelope.toOpenArray(e, e + 2 * tile.columns - 1))
      rd.markRow(tile, row, list[row], q.count, rows.keysAt(k), req.fields)

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
    # A view has no prefetch log, so this bool is what says the file was cut.
    let fileCut = f[].cutShort
    if rd.src.view != nil:
      # Listen time, on this thread: the prefetcher reads raw windows, and the
      # kernel rejects a windowed record. The virtual path is not mapped;
      # `correlateRead` advises the raw file (`view.path`). One workspace for
      # this view, kept until another view or file is shown. Stop between
      # traces, not only between chunks.
      if rd.viewOf != rd.src.view:
        rd.heldView = rd.src.view[]
        rd.viewWs = newWorkspace(rd.heldView)
        rd.viewOf = rd.src.view
      if cols > 0: rd.viewRow.setLen cols
      var rowAt = 0
      while rowAt < q.count and not given:
        if (if level: rd.r.levelSuperseded else: rd.r.interrupted):
          given = true
          break
        let n = min(HeldTraces, q.count - rowAt)
        rd.viewChunk.setLen n * cols # empty when the window is past the row
        var chunkFailed: seq[int]
        for k in 0 ..< n:
          if (if level: rd.r.levelSuperseded else: rd.r.interrupted):
            given = true
            break
          var one: array[1, int]
          one[0] = list[rowAt + k]
          if cols > 0:
            correlateRead(rd.heldView, f, one, window.a, cols, rd.viewRow, rd.viewWs)
            copyMem(addr rd.viewChunk[k * cols], addr rd.viewRow[0], cols * sizeof(float32))
            if keep:
              copyMem(addr into[].samples[(rowAt + k) * cols], addr rd.viewRow[0],
                cols * sizeof(float32))
            if rd.viewWs.failed.len > 0:
              chunkFailed.add k
              failed.add rowAt + k
              inc tile.failed
        if given: break
        tile.readTime += fs.now() - waitFrom
        inc tile.chunks
        let rows = f[].rowsOf(list.toOpenArray(rowAt, rowAt + n - 1))
        let b = rowBlock(rd.viewChunk, n, cols)
        cutRaw(b, rowAt)
        rd.prepare(pr, b, rows, rowAt, chunkFailed)
        cut(b, rows, rowAt)
        rowAt += n
        waitFrom = fs.now()
      clearCycleRoots()
    else:
      var pf = newPrefetcher[float32](f[], list, chunkTraces = chunk, cols = cols,
        firstSample = window.a, workers = DecodeWorkers, quickFirst = true, uniform = true)
      var c: PrefetchChunk[float32]
      while pf.nextInto(c):
        if not f[].inMemory: fs.mappedRead(rd.src.path) # (tests: the chunk's pages come late)
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
    if rd.src.view != nil and not given and tile.failed > 0 and not (cutSeen or ioSeen):
      if f[].readFailed: ioSeen = true
      elif fileCut: cutSeen = true
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
  if rd.src.view != nil and not level and rd.raw.valid and
      spareReady(ViewSpare(ready: true, count: q.count, cols: cols, columns: tile.columns,
        list: list), rd.raw, rd.src.view, req, q, window, cols):
    rd.stockSpare(list, q.count, cols, tile.columns)
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
    discard rd.r.served.fetchAdd(1, moRelease)
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
      rd.dropViewWork()
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
  rd.dropViewWork()
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

proc tilesPosted*(x: PanelReader): int =
  ## Tiles this reader has posted. A test waits on it without draining the
  ## inbox, so the inbox keeps the capacity the next post needs.
  if x.p == nil: 0 else: x.p.served.load(moAcquire)

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
