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
##   the same traces and samples among them (after an edit, or a new gain,
##   on the same view, or on one a little shorter) is made from them, with
##   no read from the file.
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

import std/[algorithm, locks, math, monotimes, os, times]
import parseSEG
import processSEG/pipeline
import processSEG/core/[basic, rows, types, workspace]
import processSEG/gain/stats
import edits, filesystem, inbox, jobs, log, panels, sorting, threads, tiles, viewport, wiggle

const
  ChunkTraces = 64    ## traces per prefetch chunk
  DecodeWorkers = 2   ## prefetch threads per reader
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

  ReaderRequest* = object
    ## What a panel asks its reader for.
    read*: ReadRequest
    fields*: seq[HeaderField] ## the display header's rows
    flow*: Pipeline           ## processing for display (`displayPipeline`)
    clipPercentile*: float64
    reversed*: seq[int]       ## the gather's traces whose polarity is reversed, ascending
    killed*: seq[int]         ## the gather's traces killed, ascending
    raw*: bool                ## the tile carries the samples as the file has them too

  ReaderObj = object
    lock: Lock
    changed: Cond
    panel: PanelId
    hasSource, hasOrder, hasRequest, quit: bool ## notes not taken yet
    source: ReaderSource
    order: seq[SortKey]
    orderGen: uint64
    request: ReaderRequest
    poster: Poster
    holds: HoldRelease
    started: bool
    busy: bool         ## serving a note
    beat: MonoTime     ## when it last showed it is alive (`fs.now`)
    ended: bool        ## the thread is done
    abandoned: bool    ## left to end on its own: its memory stays with it
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
    list: seq[int] ## the traces, one per row
    window: Slice[int] ## the samples decoded
    samples: seq[float32] ## `list.len` rows of `window.len` samples
    failed: seq[int] ## the rows that could not be decoded (left zero), ascending

  Reader = object
    ## The reader thread's own state.
    r: ptr ReaderObj
    src: ReaderSource
    name: string
    shown: Positions     ## the traces the filter keeps, in the file's order
    positions: Positions ## the same, in the order shown
    sorted: bool         ## `positions` follow the newest order taken
    orderGen: uint64     ## requests from before the newest order are not served
    layout: PanelLayout
    raw: RawCache
    ws: Workspace
    toldShort: bool      ## the file was found shorter than when it was opened: said once
    toldNotNumbers: bool ## samples that are not numbers were found in the file: said once

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
  rd.toldShort = false
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
    if sortRowsInto(rows, order, perm, proc (): bool = r.superseded):
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
  rd.shown = if all: Positions(traces: g)
             else: Positions(traces: g, listed: true, list: list)
  rd.positions = rd.shown
  let n = rd.shown.len
  var known: set[HeaderField]
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
    if layout.samples == 0:
      rd.note(sevWarning, "The traces shown of " & rd.name & " have no samples, so the plot " &
        "stays empty.")
  rd.layout = layout
  rd.r.poster.post Msg(job: NoJob, kind: mkLayout, panel: rd.r.panel,
    sourceGen: rd.src.gen, layout: layout, known: known)
  # The layout does not depend on the order, so it goes first: the panel can
  # ask for its view while the traces are sorted.
  let order = rd.src.order
  rd.arrange(order)

proc levelOf(rd: var Reader; tile: Tile; list: seq[int]; excluded: seq[int];
    percentile: float64): Level =
  ## The RMS, the peak and the `percentile` of |x| over the tile's live
  ## traces, the rows `excluded` (not decoded, or killed) left out; NaN when
  ## there are none.
  result = Level()
  if tile.request.count == 0 or tile.columns == 0: return
  try:
    let meta = initChunkMeta(rd.src.file[].rowsOf(list), rd.layout.dtMs *
      float64(tile.request.decimation), tile.request.firstSample, excluded)
    rd.ws.reserve(panelStatsWorkspace)
    let s = panelStats(rowBlock(tile.data, tile.request.count, tile.columns), meta, rd.ws,
      percentile)
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

type Preparing = object
  ## What every block of one request is readied with (`prepare`).
  edits: seq[set[TraceEdit]] ## per row of the request; empty: none
  processing: bool
  plan: PipelinePlan[float32]
  firstSample: int           ## the trace sample of column 0
  notNumbers: int            ## rows that held a sample that is not a number

proc prepare(rd: var Reader; pr: var Preparing; b: RowBlock[float32]; rows: TraceRows;
    first: int; failedRows: openArray[int]) =
  ## Readies rows `first ..< first + b.len` of a request, decoded into `b`
  ## (`rows`: their traces; `failedRows`: those not decoded, 0-based in the
  ## block, ascending) for the tile: killed rows and rows marked dead in the
  ## file blanked, samples that are not numbers set to 0, the samples of
  ## reversed rows negated, then the display processing, which passes by
  ## the blank rows and those not decoded.
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
    if pr.processing: pr.plan.apply(b, meta, rd.ws)
  except ValueError as e:
    rd.note(sevError, "The display processing stopped on " & rd.name & ": " & e.msg)
    pr.processing = false

proc cutShort(rd: var Reader): bool =
  ## Whether the file cannot be read now: it is shorter than when it was
  ## opened (another program cut it short, or is writing it again), or it
  ## cannot be looked at (its drive went away, or fails). Reading the map
  ## then would touch pages that are not there, which ends the program
  ## (SIGBUS; an in-page error on Windows), so nothing is read. Said once;
  ## the UI closes a file cut short when the folder's watch sees the change.
  result = false
  var why = ""
  try:
    let size = fs.getFileInfo(rd.src.path).size
    if rd.src.size >= 0 and size < rd.src.size:
      why = rd.name & " is shorter than when it was opened: another program has cut it " &
        "short or is writing it again, so it is not read until it is opened again."
  except OSError as e:
    why = rd.name & " cannot be read now (" & (if e.msg.len > 0: e.msg else: "its drive " &
      "does not answer") & "): its drive went away or fails, so it is not read; the plot " &
      "keeps what it showed."
  result = why.len > 0
  if not result: rd.toldShort = false # (said again if it fails again)
  if result and not rd.toldShort:
    rd.toldShort = true
    rd.note(sevWarning, why)

proc serve(rd: var Reader; req: sink ReaderRequest) =
  ## Reads, processes and posts the tile `req` asks for, unless a newer note
  ## comes first. The samples come from the file through a prefetcher, or,
  ## when the last request read from the file had the same traces and these
  ## samples among its own, from what it read (`RawCache`).
  let q = req.read
  let f = rd.src.file
  if q.isEmpty or q.first < 0 or q.last >= rd.positions.len: return
  var list = newSeq[int](q.count)
  for row in 0 ..< q.count: list[row] = rd.positions.traceAt(q.position(row))
  let window = q.decodeSpan(rd.layout.samples)
  let skip = q.firstSample - window.a # decoded columns before the kept ones
  let cols = window.len
  var pr = Preparing(processing: req.flow.len > 0, firstSample: window.a)
  if pr.processing:
    try:
      pr.plan = req.flow.compile(float32, rd.layout.dtMs, cols,
        recordSamples = rd.layout.samples)
      rd.ws.reserve(pr.plan)
    except ValueError as e:
      rd.note(sevError, "The display processing cannot run on " & rd.name & ": " & e.msg)
      pr.processing = false
  var tile = Tile(panel: rd.r.panel, request: q, dtMs: rd.layout.dtMs, t0Ms: rd.layout.t0Ms,
    columns: q.columns, fields: req.fields)
  tile.data = newSeq[float32](q.count * tile.columns)
  if q.envelope: tile.envelope = newSeq[float32](q.count * 2 * tile.columns)
  tile.keys = newSeq[TraceKeys](q.count)
  if req.raw: tile.raw = newSeq[float32](q.count * tile.columns)
  tile.header = newSeq[seq[float64]](req.fields.len)
  for h in tile.header.mitems: h = newSeq[float64](q.count)
  # the edits of each row
  if req.killed.len > 0 or req.reversed.len > 0:
    pr.edits = newSeq[set[TraceEdit]](q.count)
    var any = false
    for row, t in list:
      if req.killed.binarySearch(t) >= 0: pr.edits[row].incl teKilled
      if req.reversed.binarySearch(t) >= 0: pr.edits[row].incl teReversed
      if pr.edits[row] != {}: any = true
    if any: tile.edits = pr.edits
    else: pr.edits.setLen 0

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
        tile.header[i][row] = keys.value(field, list[row])

  var failed: seq[int]
  var given = false
  if rd.raw.valid and rd.raw.list == list and window.a >= rd.raw.window.a and
      window.b <= rd.raw.window.b:
    # The samples are at hand: nothing is read from the file.
    let held = rd.raw.window.len
    let offset = window.a - rd.raw.window.a
    tile.cached = true
    failed = rd.raw.failed
    tile.failed = failed.len
    var work = newSeq[float32](min(ChunkTraces, q.count) * cols)
    var a = 0
    while a < q.count:
      let n = min(ChunkTraces, q.count - a)
      let part = list[a ..< a + n] # outlives the rows' view
      let rows = f[].rowsOf(part)
      work.setLen n * cols
      if cols > 0:
        for k in 0 ..< n:
          copyMem(addr work[k * cols], addr rd.raw.samples[(a + k) * held + offset],
            cols * sizeof(float32))
      let b = rowBlock(work, n, cols)
      var partFailed: seq[int]
      for fr in failed:
        if fr in a ..< a + n: partFailed.add fr - a
      cutRaw(b, a)
      rd.prepare(pr, b, rows, a, partFailed)
      cut(b, rows, a)
      a += n
      if rd.r.interrupted:
        given = true
        break
  elif rd.cutShort: return
  else:
    let keep = q.count * cols <= MaxRawSamples
    if keep: # its buffer reused
      rd.raw.valid = false
      rd.raw.list = list
      rd.raw.window = window
      rd.raw.samples.setLen q.count * cols
      rd.raw.failed.setLen 0
    else: rd.raw = RawCache() # too large to keep: the one before goes too
    var firstError = ""
    var pf = newPrefetcher[float32](f[], list, chunkTraces = ChunkTraces, cols = cols,
      firstSample = window.a, workers = DecodeWorkers, quickFirst = true, uniform = true)
    var c: PrefetchChunk[float32]
    while pf.nextInto(c):
      fs.mappedRead(rd.src.path) # (tests: the chunk's pages come late, or never)
      let b = rowBlock(c.samples)
      if keep and c.count * cols > 0: # as read, before anything changes them
        copyMem(addr rd.raw.samples[c.first * cols], b.rowPtr(0), c.count * cols *
          sizeof(float32))
      cutRaw(b, c.first)
      rd.prepare(pr, b, c.rows, c.first, c.failedRows)
      cut(b, c.rows, c.first)
      for fr in c.failedRows: failed.add c.first + fr
      tile.failed += c.failed
      if c.failed > 0 and firstError.len == 0 and c.log.len > 0:
        firstError = c.log[0].msg
      if rd.r.interrupted:
        given = true
        break
    pf.close()
    clearCycleRoots()
    if keep and not given:
      rd.raw.failed = failed
      rd.raw.valid = true
    if not given and tile.failed > 0:
      rd.note(sevWarning, $tile.failed & " of the " & $q.count & " traces shown could not " &
        "be read and are drawn blank" & (if firstError.len > 0: ": " & firstError else: "") &
        ".")
  if given: return
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
  rd.r.poster.post Msg(job: NoJob, kind: mkTile, tile: move tile)

proc run(r: ptr ReaderObj) {.thread.} =
  markWorkerThread()
  var rd = Reader(r: r, ws: initWorkspace())
  while true:
    var src: ReaderSource
    var req: ReaderRequest
    var order: seq[SortKey]
    var gotSource, gotOrder, gotRequest, quit = false
    withLock r.lock:
      while not (r.quit or r.hasSource or r.hasOrder or r.hasRequest):
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
      r.hasSource = false
      r.hasOrder = false
      r.hasRequest = false
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
      if gotRequest and rd.src.file != nil and rd.sorted and
          req.read.gen >= max(rd.src.gen, rd.orderGen):
        rd.serve(req)
    except CatchableError as e:
      rd.note(sevError, "Cannot read " & rd.name & ": " & e.msg)
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
