## The Headers window's reader: the thread that reads what its tabs show of
## the files' own bytes, so that the UI thread never does.
##
## The UI thread leaves a request (`ask`): a SEG-D record whose headers the
## File headers tab shows, and the traces the Trace tab is about, with their
## header fields, their samples, or both. The inspector reads them
## (`core/headers`: `readRecordHeaders`, `traceRows`; parseSEG's
## `readTraces`) and posts the answer (`mkInspected`). As in a panel's
## reader (`core/reader`):
##
## - **Newest wins.** A request replaces the one before it if the inspector
##   has not taken it yet, and one being served is given up between traces
##   when a newer comes (the pointer moving over the plot asks for a new
##   trace every frame).
## - **Holds.** The caller takes a hold on each file the request names
##   (`Jobs.hold`) before it asks; the inspector ends them (`HoldRelease`)
##   once it has served the request or given it up, and `ask` ends those of
##   a request it replaces untaken. A close or a join of the file waits for
##   that, which is a few milliseconds.
## - **A file another program cut short**, or whose read failed, is found by
##   parseSEG's guard (`cutShort`; nothing reads past the new end of a map):
##   the answer says so for its traces. A drive that went away or fails is
##   found by the read, whose error the answer's part says.
## - **A drive that does not answer.** Every call it makes to the file system
##   goes through the seam (`core/filesystem`: each read of a header block or
##   of samples from the map marked with `fs.mappedRead`). It *beats* (`fs.now`) before each, with the file it
##   reads next; one that is busy and has not beaten for a while is stuck in
##   that drive (`silentFor`, `readingPath`). The UI thread then says so, and
##   leaves it (`leave`) when the window wants another file read: a new
##   inspector reads that one, and the old one ends on its own once the drive
##   answers, keeping its holds until then (`hasEnded`); its late answer is
##   older than what was taken since, and dropped. `stop` waits until a
##   deadline only.
## - **Samples as displayed:** the trace's samples, not numbers set to 0, a
##   trace killed or marked dead blanked, a reversed one negated, then the
##   filters and the display processing of the plot that shows it
##   (`filters`, `flow`, as the panel's reader runs them): what the status bar's amplitude reads. As recorded:
##   the samples as the file holds them.
## - At most `MaxInspectedValues` samples in all are kept per answer; the
  ## rest of a trace is left out and its `cut` says how many. As displayed,
  ## a trace cut so is filtered, shifted and processed whole first (up to
  ## `MaxProcessedValues`), so the samples kept are the plot's.

import std/[heapqueue, intsets, locks, monotimes, os, strutils, times]
import parseSEG
import processSEG/pipeline
import processSEG/core/[basic, rows, types, workspace]
import channelsets, cutfile, edits, filesystem, headers, inbox, jobs, log, processing, selection, session,
  threads, tracetable, vendormaps

export tracetable

const
  MaxInspectedValues* = 32 * 1024 * 1024
    ## samples (128 MiB) one answer keeps at most, over all its traces
  MaxProcessedValues* = 64 * 1024 * 1024
    ## the samples of one trace read and processed whole for the samples as
    ## displayed of a trace cut at `MaxInspectedValues`, at most
  MaxInspected* = 32 ## traces the Trace tab shows side by side, at most

type
  InspectPart* = enum
    ## What the Headers window has on screen, so what is read for it.
    ipRecord = "record headers"      ## File headers: the SEG-D record's blocks
    ipTraceHeaders = "trace headers" ## Trace, Header: the traces' header fields
    ipTraceSamples = "trace samples" ## Trace, Data: the traces' samples
    ipTable = "trace table"          ## Trace table: a row per trace, the fields chosen

  ChosenBy* = enum
    ## What chose the traces the Trace tab is about.
    cbNone = "nothing"
    cbSelection = "the selection"
    cbPlotPointer = "the pointer in the plot"
    cbMapPointer = "the pointer on the map"

  Chosen* = object
    ## The traces the Trace tab is about.
    by*: ChosenBy
    traces*: seq[int]
      ## survey-wide ids, ascending, at most `MaxInspected`
    total*: int
      ## how many `by` holds

  Inspection* = object
    ## What the Headers window is shown of the files' bytes (`AppState`
    ## keeps it; the window reads it).
    parts*: set[InspectPart] ## on screen now (`ckInspect`)
    table*: TableView ## what the trace table shows, when on screen
    chosen*: Chosen ## the traces the Trace tab is about now
    answer*: Inspected ## the newest answer taken in
    waiting*: bool ## a request is out that has not been answered yet
    revision*: int ## bumped when `chosen` or `answer` changes

  InspectFile* = object
    ## A file a request reads, held by the caller.
    file*: ptr SeismicFile
    path*: string
    session*: SessionId ## the open it is read for: a reopen is another one
    size*: int64        ## its size when it was opened; -1 when not known

  InspectTrace* = object
    ## A trace a request asks about.
    id*: int               ## its survey-wide id
    at*: int               ## its file: an index into `InspectRequest.files`
    trace*: int            ## its index in its file
    edits*: set[TraceEdit] ## as displayed: its edits
    own*: OwnFilter        ## as displayed: its own filter, when `hasOwn`
    hasOwn*: bool
    shiftMs*: float64      ## as displayed: its time shift, milliseconds; 0 for none
    displayed*: bool       ## its samples as displayed (its file is shown in the plot)

  InspectRequest* = object
    ## What the Headers window asks the inspector for.
    gen*: uint64
    files*: seq[InspectFile]
    recordAt*: int = -1     ## the file of the SEG-D record asked for; -1 for none
    record*: int = -1       ## that record's index in its file
    vendorAt*: int = -1
      ## the file whose vendor blocks (`core/vendormaps`) are asked for; -1 for none
    vendorRecord*: int = -1 ## its SEG-D record; -1 for another standard
    vendorGen*: int         ## the maps' load the answer is made with (`VendorShown.gen`)
    traces*: seq[InspectTrace]
    headers*: bool          ## read the traces' header fields
    samples*: bool          ## read their samples
    flow*: Pipeline         ## the display processing, for samples as displayed
    filters*: Pipeline      ## the plot's filters, run before `flow`
    filterAux*: bool        ## an auxiliary trace goes through `filters` too
    flowAux*: bool          ## and through `flow`
    table*: TableAsk        ## the trace table's rows and columns

  TableAsk* = object
    ## What the trace table asks the reader for.
    at*: int = -1                 ## its file: an index into `InspectRequest.files`; -1 for no table
    traces*: Slice[int] = 0 .. -1 ## the traces it has a row for (indices in the file)
    view*: TableView
    joins*: int
      ## the geometry joins ended so far: a column of keys read before
      ## another ended is read again

  CachedColumn = object
    ## A column of the trace table read for every row of its scope.
    key: string  ## its file, scope, joins and name
    session: int ## the open it was read for
    values: seq[float64]
    filled: int  ## the rows read so far, from the first

  TableCache = object
    columns: seq[CachedColumn] ## the newest last, at most `MaxCachedColumns`
    orderKey: string           ## what `order` was made of
    orderSession: int
    order: seq[int32]
    catalogueOf: string        ## the file and trace `catalogue` was made of
    catalogueSession: int
    catalogue: seq[CatalogueField]

  InspectorObj = object
    lock: Lock
    changed: Cond
    hasRequest, quit: bool
    request: InspectRequest
    poster: Poster
    holds: HoldRelease
    started: bool
    busy: bool
      ## serving a request
    beat: MonoTime
      ## when it last showed it is alive (`fs.now`)
    reading: string
      ## the file it reads now; "" for none
    ended: bool
      ## the thread is done
    abandoned: bool
      ## left to end on its own: its memory stays with it
    table: TableCache
      ## the trace table's columns read whole, and its order: the thread's own
    dropIds: seq[int]
      ## opens whose cached columns, order and catalogue are to be dropped
    dropped: IntSet
      ## opens dropped this run: a request already queued when one was closed
      ## is served after that drop, and would put its columns back
    thread: Thread[ptr InspectorObj]

  Inspector* = object
    ## The Headers window's reader thread. Move-only; destroying it stops
    ## the thread.
    p: ptr InspectorObj

proc `=destroy`*(x: Inspector)
proc `=wasMoved`*(x: var Inspector) = x.p = nil
proc `=copy`*(dest: var Inspector; src: Inspector) {.error.}
proc `=dup`*(src: Inspector): Inspector {.error.}

func isNil*(x: Inspector): bool {.inline.} =
  ## Whether `x` was never started (a default `Inspector`).
  x.p == nil

func chosenTraces*(sel: Selection; followPointer: bool; last = Chosen()): Chosen =
  ## The traces the Trace tab is about: the selected ones; with none and
  ## `followPointer`, the trace under the plot's pointer, else those of the
  ## point under the map's pointer, else those pointed at last (`last`, when
  ## the pointer chose them), so that they stay while the pointer goes to
  ## the Headers window; the first `MaxInspected` of them, by id (found in
  ## one pass, however many are selected: none of the others is sorted).
  var first = initHeapQueue[int]() # the smallest so far, negated: the largest on top
  template take(t: int) =
    inc result.total
    if first.len < MaxInspected: first.push -t
    elif -t > first[0]: discard first.replace(-t)
  result = Chosen()
  if sel.anySelected:
    result.by = cbSelection
    for t in sel.selected: take(t)
  elif followPointer and sel.hover >= 0:
    result.by = cbPlotPointer
    take(sel.hover)
  elif followPointer and sel.hoverTraces.len > 0:
    result.by = cbMapPointer
    for t in sel.hoverTraces: take(t)
  elif followPointer and last.by in {cbPlotPointer, cbMapPointer}:
    return last
  result.traces = newSeq[int](first.len)
  for i in countdown(first.len - 1, 0): result.traces[i] = -first.pop()

# ------------------------------------------------------------ the thread --

proc interrupted(p: ptr InspectorObj): bool =
  ## Whether a newer request is waiting, or the inspector must stop: then the
  ## request served is given up. A sign of life too.
  let now = fs.now()
  withLock p.lock:
    p.beat = now
    result = p.quit or p.hasRequest

proc beat(p: ptr InspectorObj; reading: string) =
  ## A sign of life before a call to the file system, which reads `reading`.
  let now = fs.now()
  withLock p.lock:
    p.beat = now
    p.reading = reading

proc unreadable(f: InspectFile): string =
  ## Why nothing of the file is read now; "" when it can be: parseSEG's guard
  ## found it cut short, or a read of it failed (`cutWhy`). A drive that
  ## does not answer is found by the read itself (`readProblem`).
  cutWhy(f.file[])

func usable(x: float64): bool {.inline.} = x > 0 and x < Inf

proc readSamples(d: var TraceDetail; f: ptr SeismicFile; t: InspectTrace;
    req: InspectRequest; room: int; ws: var Workspace) =
  ## Trace `t`'s samples into `d`: at most `room`, as recorded or as
  ## displayed. As displayed, a trace with more samples than that is
  ## filtered and processed whole (up to `MaxProcessedValues`), as the
  ## plot's reader does, and then cut: the samples kept are the plot's.
  ## A time shift asks for the same read: it runs before the cut, so a
  ## move does not pad with zeros the file holds.
  let n = f[].maxSamples([t.trace])
  let kept = min(n, max(room, 0))
  d.cut = n - kept
  if kept == 0: return
  let processed = t.displayed and (req.filters.len > 0 or req.flow.len > 0 or
    t.shiftMs != 0.0)
  let whole = if processed and kept < n: min(n, max(kept, MaxProcessedValues)) else: kept
  var log: DiagLog
  let block1 = f[].readTraces([t.trace], 0 ..< whole, log)
  d.samples = newSeq[float32](whole)
  copyMem(addr d.samples[0], rowBlock(block1).rowPtr(0), whole * sizeof(float32))
  let failed = log.hasErrors # the trace could not be decoded: it reads as zeros
  if log.len > 0: d.problem = log[0].msg
  if not t.displayed: return
  d.displayed = true
  let blank = teKilled in t.edits or d.keys.status == tsDead or failed
  for x in d.samples.mitems:
    if blank or not (abs(x) < Inf): x = 0
  if not blank and teReversed in t.edits: reversePolarity(d.samples) # as the reader does
  if not blank and t.shiftMs != 0.0 and d.keys.isSeismic:
    applyStoredShift(d.samples, t.shiftMs, d.dtMs)
  let list = [t.trace]
  let plotIt = not blank and req.filters.len > 0 and teExcluded notin t.edits and
    not (t.hasOwn and t.own.place == fpInstead)
  if plotIt:
    let plan = req.filters.compile(float32, d.dtMs, whole, recordSamples = n)
    ws.reserve(plan)
    var keys: seq[TraceKeys]
    var lengths: seq[int]
    let rows = if req.filterAux: f[].rowsOf(list).auxLiveRows(keys, lengths)
               else: f[].rowsOf(list)
    plan.apply(rowBlock(d.samples, 1, whole), initChunkMeta(rows, d.dtMs, 0), ws)
  if not blank and t.hasOwn and t.own.spec.hasFilters:
    let pipe = t.own.ownPipeline(d.dtMs)
    if pipe.len > 0:
      let plan = pipe.compile(float32, d.dtMs, whole, recordSamples = n)
      ws.reserve(plan)
      var keys: seq[TraceKeys]
      var lengths: seq[int]
      let rows = f[].rowsOf(list).auxLiveRows(keys, lengths)
      plan.apply(rowBlock(d.samples, 1, whole), initChunkMeta(rows, d.dtMs, 0), ws)
  if not blank and req.flow.len > 0:
    let plan = req.flow.compile(float32, d.dtMs, whole, recordSamples = n)
    ws.reserve(plan)
    var keys: seq[TraceKeys]
    var lengths: seq[int]
    let rows = if req.flowAux: f[].rowsOf(list).auxLiveRows(keys, lengths)
               else: f[].rowsOf(list)
    plan.apply(rowBlock(d.samples, 1, whole), initChunkMeta(rows, d.dtMs, 0), ws)
  if whole > kept:
    d.samples.setLen kept # the part kept, of the trace processed whole
  if whole < n and kept < n and processed:
    d.problem = "processed on its first " & $whole & " samples only (it has " & $n & ")"

const MaxCachedColumns = 8
  ## columns of the trace table kept read whole (8 MiB each a million traces)
const MaxTableRows* = 2048 ## rows of the trace table read in one answer, at most

proc readRows(f: ptr SeismicFile; name: string; traces: openArray[int];
    dst: var openArray[float64]) =
  ## Column `name` of `traces` into `dst`. Raises `ValueError` for a field
  ## the file's traces do not have.
  if name.isKey:
    let keyed = f[].index.keys.len == f[].len
    for k, t in traces:
      dst[k] = keyValue(if keyed: f[].index.keys[t] else: f[].traceKeys(t), name,
        f[].channelSetNumberOf(t))
  else:
    let column = f[].traceFieldColumn(name, traces) # (the rows on screen: a few hundred)
    for k in 0 ..< column.len: dst[k] = column[k]

proc readRange(f: ptr SeismicFile; name: string; traces: Slice[int];
    dst: var openArray[float64]) =
  ## Column `name` of the traces `traces` (a range) into `dst`.
  if name.isKey:
    let keyed = f[].index.keys.len == f[].len
    for k in 0 ..< traces.len:
      let t = traces.a + k
      dst[k] = keyValue(if keyed: f[].index.keys[t] else: f[].traceKeys(t), name,
        f[].channelSetNumberOf(t))
  else:
    f[].traceFieldColumnInto(name, traces, dst)

proc columnKey(f: InspectFile; ask: TableAsk; name: string): string =
  ## The key of column `name` read whole for the table's scope.
  f.path & "\t" & $int(f.session) & "\t" & $ask.traces & "\t" & $ask.joins & "\t" & name

proc indexOf(cache: TableCache; key: string): int =
  ## The index in the cache of the column `key`; -1 for none.
  result = -1
  for i, c in cache.columns:
    if c.key == key: return i

proc wholeColumn(p: ptr InspectorObj; f: InspectFile; ask: TableAsk; key, name: string;
    needed: openArray[string]; answer: var TableAnswer; problem: var string): bool =
  ## Reads column `key` (of `name`) whole for every trace of the table's
  ## scope, in steps of `ColumnStep` traces, kept in the cache: false when a
  ## newer request came first (it goes on from there). A column of `needed`
  ## (this request's) is never evicted to make room. A read that fails says
  ## why in `problem`, for this request only: the next one reads it again.
  template cache: untyped = p.table
  if cache.indexOf(key) < 0:
    if cache.columns.len >= MaxCachedColumns:
      for i, c in cache.columns:
        if c.key notin needed:
          cache.columns.delete i
          break
    cache.columns.add CachedColumn(key: key, session: int(f.session),
      values: newSeq[float64](ask.traces.len))
  let at = cache.indexOf(key)
  template c: untyped = cache.columns[at]
  while c.filled < c.values.len:
    if p.interrupted:
      answer.reading = name
      return false
    let step = min(ColumnStep, c.values.len - c.filled)
    let part = ask.traces.a + c.filled .. ask.traces.a + c.filled + step - 1
    p.beat(f.path)
    try:
      if not f.file[].inMemory: fs.mappedRead(f.path, headers = true)
      if not f.file[].inMemory: fs.unmappedFail(f.path)
      readRange(f.file, name, part, c.values.toOpenArray(c.filled, c.filled + step - 1))
      c.filled += step
    except CatchableError as e:
      problem = readProblem(e)
      c.filled = 0 # read again next time: the drive may answer then
      return true
  true

proc serveTable(p: ptr InspectorObj; f: InspectFile; ask: TableAsk; why: string;
    answer: var TableAnswer): bool =
  ## The trace table's rows and columns: false when a newer request came
  ## first (nothing is posted then).
  result = true
  answer = TableAnswer(path: f.path, session: int(f.session), traces: ask.traces, view: ask.view)
  if why.len > 0:
    answer.problems.add why
    return
  let view = ask.view
  let n = ask.traces.len
  template cache: untyped = p.table
  # The fields the scope's first trace has, for the column chooser.
  let catalogueOf = f.path & "\t" & $int(f.session) & "\t" & $ask.traces.a & "\t" & $ask.joins
  if n > 0 and cache.catalogueOf != catalogueOf:
    cache.catalogue.setLen 0
    for (name, label) in KeyColumns:
      cache.catalogue.add CatalogueField(name: name, blockName: "keys", description: label)
    p.beat(f.path)
    try:
      if not f.file[].inMemory: fs.mappedRead(f.path, headers = true)
      if not f.file[].inMemory: fs.unmappedFail(f.path)
      for r in traceRows(f.file[], ask.traces.a):
        if r.field.len > 0 and r.kind != hbRaw:
          cache.catalogue.add CatalogueField(name: r.blockName & "." & r.field,
            blockName: r.blockName, description: r.description)
      cache.catalogueOf = catalogueOf
      cache.catalogueSession = int(f.session)
    except CatchableError:
      discard # the keys only; tried again next time
  answer.catalogue = cache.catalogue
  # The columns read for every row: the sort's, Find's, the graph's. All of
  # them are read (or found) first; then each is looked up by its key, so
  # that no read evicts a column another of them is looked up by.
  let needed = wholeColumns(view)
  var keys: seq[string]
  for name in needed: keys.add f.columnKey(ask, name)
  var whole: seq[(string, string)] # (name, key) of the columns read whole
  for k, name in needed:
    var problem = ""
    if not p.wholeColumn(f, ask, keys[k], name, keys, answer, problem): return false
    if problem.len > 0: answer.problems.add name & ": " & problem
    else: whole.add (name, keys[k])
  proc column(whole: seq[(string, string)]; name: string): string =
    result = ""
    for (n, key) in whole:
      if n == name: result = key
  let find = parseFind(view.findValue)
  let findKey = if view.findField.len > 0 and find.valid: whole.column(view.findField) else: ""
  let sortKey = if view.sortBy.len > 0: whole.column(view.sortBy) else: ""
  let ordered = findKey.len > 0 or sortKey.len > 0
  if ordered:
    let orderKey = findKey & "|" & $find & "|" & sortKey & "|" & $view.descending & "|" &
      $ask.traces & "|" & f.path & "|" & $int(f.session) & "|" & $ask.joins
    if orderKey != cache.orderKey:
      var keep: seq[bool]
      if findKey.len > 0:
        keep = newSeq[bool](n)
        let values = cache.columns[cache.indexOf(findKey)].values
        for i in 0 ..< n: keep[i] = find.matches(values[i])
      cache.order = if sortKey.len > 0:
          orderOf(cache.columns[cache.indexOf(sortKey)].values, keep, view.descending)
        else: orderOf([], keep, false)
      cache.orderKey = orderKey
      cache.orderSession = int(f.session)
  answer.count = if ordered: cache.order.len else: n
  # The rows on screen, at most `MaxTableRows`.
  let a = max(view.rows.a, 0)
  let b = min(min(view.rows.b, answer.count - 1), a + MaxTableRows - 1)
  answer.first = a
  for r in a .. b:
    answer.rowTraces.add ask.traces.a + (if ordered: int(cache.order[r]) else: r)
  answer.values = newSeq[seq[float64]](answer.rowTraces.len)
  for row in answer.values.mitems: row = newSeq[float64](view.fields.len)
  var buf = newSeq[float64](answer.rowTraces.len)
  for c, name in view.fields:
    let key = whole.column(name)
    if key.len > 0:
      let w = cache.indexOf(key)
      for k, t in answer.rowTraces: answer.values[k][c] = cache.columns[w].values[t - ask.traces.a]
    elif answer.rowTraces.len > 0:
      p.beat(f.path)
      try:
        if not f.file[].inMemory: fs.mappedRead(f.path, headers = true)
        if not f.file[].inMemory: fs.unmappedFail(f.path)
        readRows(f.file, name, answer.rowTraces, buf)
        for k in 0 ..< buf.len: answer.values[k][c] = buf[k]
      except CatchableError as e:
        answer.problems.add name & ": " & readProblem(e)
        for k in 0 ..< buf.len: answer.values[k][c] = NaN
  let g = if view.graph.len > 0: whole.column(view.graph) else: ""
  if g.len > 0:
    bucketsOf(cache.columns[cache.indexOf(g)].values, cache.order, ordered,
      answer.graphMin, answer.graphMax)

proc wasDropped(p: ptr InspectorObj; session: int): bool =
  ## Whether open `session` has been dropped. The UI thread adds to `dropped`
  ## under the lock; this reads it there too.
  withLock p.lock:
    result = session in p.dropped

proc serve(p: ptr InspectorObj; req: InspectRequest; ws: var Workspace): bool =
  ## Reads and posts what `req` asks for; false when a newer request came
  ## first (then nothing is posted). Each call to the file system goes
  ## through the seam, after a beat that names the file.
  var answer = Inspected(gen: req.gen)
  var why = newSeq[string](req.files.len)
  for i, f in req.files:
    p.beat(f.path)
    why[i] = f.unreadable
  if req.recordAt in 0 ..< req.files.len:
    let f = req.files[req.recordAt]
    answer.recordPath = f.path
    if why[req.recordAt].len > 0:
      answer.record = RecordHeaders(record: req.record, problem: why[req.recordAt])
    else:
      p.beat(f.path)
      try:
        if not f.file[].inMemory: fs.mappedRead(f.path, headers = true)
        if not f.file[].inMemory: fs.unmappedFail(f.path)
        answer.record = readRecordHeaders(f.file[], req.record)
      except CatchableError as e:
        answer.record = RecordHeaders(record: req.record, problem: readProblem(e))
  if req.vendorAt in 0 ..< req.files.len and why[req.vendorAt].len == 0:
    let f = req.files[req.vendorAt]
    let (reg, choice) = currentVendorSet()
    answer.vendor = vendorBlocks(f.file[], req.vendorRecord, reg, req.vendorGen, choice)
  if req.table.at in 0 ..< req.files.len:
    let f = req.files[req.table.at]
    # Closed already: not read, so its columns are not cached again.
    if not p.wasDropped(int(f.session)):
      if not p.serveTable(f, req.table, why[req.table.at], answer.table):
        return false
  var room = MaxInspectedValues
  for t in req.traces:
    if p.interrupted: return false
    var d = TraceDetail(id: t.id, trace: t.trace, dtMs: 1, t0Ms: 0)
    if t.at notin 0 ..< req.files.len:
      d.problem = "its file is busy"
    else:
      let f = req.files[t.at]
      d.file = f.path.extractFilename
      if why[t.at].len > 0: d.problem = why[t.at]
      else:
        try:
          d.keys = f.file[].traceKeys(t.trace) # (the index, in memory)
          d.joined = f.file[].index.joinedGroups(t.trace)
          if usable(d.keys.intervalUs):
            d.dtMs = d.keys.intervalUs / 1000
            d.intervalKnown = true
          else:
            let us = f.file[].sampleIntervalUs(t.trace)
            if usable(us):
              d.dtMs = us / 1000
              d.intervalKnown = true
          if usable(abs(d.keys.t0Ms)) or d.keys.t0Ms == 0: d.t0Ms = d.keys.t0Ms
          if req.headers:
            p.beat(f.path)
            if not f.file[].inMemory: fs.mappedRead(f.path, headers = true)
            if not f.file[].inMemory: fs.unmappedFail(f.path)
            d.rows = traceRows(f.file[], t.trace)
            d.blocks = namedBlocks(f.file[], d.rows)
            let (reg, choice) = currentVendorSet()
            d.vendor = vendorTrace(f.file[], t.trace, reg, req.vendorGen, choice)
          if req.samples:
            p.beat(f.path)
            if not f.file[].inMemory: fs.mappedRead(f.path)
            if not f.file[].inMemory: fs.unmappedFail(f.path)
            d.readSamples(f.file, t, req, room, ws)
            room -= d.samples.len
        except CatchableError as e:
          d.problem = readProblem(e)
    answer.traces.add d
  clearCycleRoots() # the UI thread frees what was made here
  p.poster.post Msg(job: NoJob, kind: mkInspected, inspected: answer)
  true

proc dropCached(cache: var TableCache; session: int) =
  ## Drops the columns, order and catalogue of open `session`.
  var kept: seq[CachedColumn]
  for c in cache.columns:
    if c.session != session: kept.add c
  cache.columns = move kept
  if cache.orderSession == session:
    cache.order.setLen 0
    cache.orderKey = ""
    cache.orderSession = 0
  if cache.catalogueSession == session:
    cache.catalogue.setLen 0
    cache.catalogueOf = ""
    cache.catalogueSession = 0

proc applyDrops(p: ptr InspectorObj) =
  ## Lock held, or the inspector thread while it is busy. A request already
  ## queued (or taken in this wake) when the close happened is served after
  ## the first drop and would put that open's columns back, so every open
  ## dropped this run is dropped again after the serve.
  for id in p.dropIds: p.table.dropCached(id)
  p.dropIds.setLen 0
  for id in p.dropped: p.table.dropCached(id)

proc run(p: ptr InspectorObj) {.thread.} =
  markWorkerThread()
  var ws = initWorkspace()
  while true:
    var req: InspectRequest
    var got, quit = false
    withLock p.lock:
      while not (p.quit or p.hasRequest):
        wait(p.changed, p.lock)
      quit = p.quit
      got = p.hasRequest
      if got: req = move p.request
      p.hasRequest = false
      p.busy = got and not quit
      p.beat = fs.now()
    if got and not quit:
      try:
        discard p.serve(req, ws)
      except CatchableError as e:
        p.poster.post Msg(job: NoJob, kind: mkLog, entry: LogEntry(time: getTime(),
          severity: sevWarning, source: "headers", text: "The Headers window could not " &
          "read what it shows: " & e.msg))
    if got:
      clearCycleRoots()
      for f in req.files: discard p.holds.release(f.path)
    withLock p.lock:
      p.applyDrops()
      p.busy = false
      p.reading = ""
    if quit: break
  clearCycleRoots()
  withLock p.lock:
    p.busy = false
    p.ended = true

# --------------------------------------------------------------- the UI side --

const InspectorStopWait* = initDuration(milliseconds = 800)
  ## how long `stop` waits for the thread by default

proc stop*(x: Inspector; deadline = getMonoTime() + InspectorStopWait): bool {.discardable,
    raises: [].}

proc dispose(x: Inspector) =
  ## Frees what the thread used, once it has ended: a request it never took
  ## ends its holds here.
  if x.p.hasRequest:
    for f in x.p.request.files: discard x.p.holds.release(f.path)
  deinitCond(x.p.changed)
  deinitLock(x.p.lock)
  `=destroy`(x.p[])
  deallocShared(x.p)

proc `=destroy`*(x: Inspector) =
  if x.p != nil:
    var abandoned = false
    withLock x.p.lock:
      abandoned = x.p.abandoned
    if not abandoned: discard x.stop()
    if not x.p.started: x.dispose() # else it still runs: its memory stays with it

proc newInspector*(poster: sink Poster; holds: HoldRelease): Inspector =
  ## Starts the inspector, which posts through `poster` and ends its holds
  ## through `holds`.
  let p = cast[ptr InspectorObj](allocShared0(sizeof(InspectorObj)))
  initLock p.lock
  initCond p.changed
  p.poster = poster
  p.holds = holds
  result = Inspector(p: p)
  createThread(p.thread, run, p)
  p.started = true

proc dropSession*(x: Inspector; session: int) =
  ## Drops the cached columns, order and catalogue of open `session`. Applied
  ## now when the reader is idle, else when the request it is serving ends.
  if x.p == nil: return
  withLock x.p.lock:
    x.p.dropIds.add session
    x.p.dropped.incl session
    if not x.p.busy: x.p.applyDrops()

proc cachedColumns*(x: Inspector): int =
  ## Cached whole columns, plus one if an order or a catalogue is held.
  if x.p == nil: return 0
  withLock x.p.lock:
    result = x.p.table.columns.len
    if x.p.table.order.len > 0: inc result
    if x.p.table.catalogue.len > 0: inc result

proc ask*(x: Inspector; req: sink InspectRequest) =
  ## Asks for `req`, whose files the caller holds; replaces a request not
  ## yet taken, and ends that one's holds.
  assert x.p != nil
  var dropped: seq[string]
  withLock x.p.lock:
    if x.p.hasRequest:
      for f in x.p.request.files: dropped.add f.path
    x.p.request = req
    x.p.hasRequest = true
    signal(x.p.changed)
  for path in dropped: discard x.p.holds.release(path)

proc askStop*(x: Inspector) =
  ## Asks the thread to end, without waiting (`stop` waits).
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true
      signal(x.p.changed)

proc stop*(x: Inspector; deadline = getMonoTime() + InspectorStopWait): bool {.discardable,
    raises: [].} =
  ## Stops the thread and waits for it until `deadline`: true when it has
  ## ended; false when it is stuck (in a drive that does not answer), and it
  ## is then left to end on its own. Idempotent; destroying the inspector
  ## does it.
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

proc leave*(x: Inspector) =
  ## Leaves the thread to end on its own (it is stuck in a drive that does
  ## not answer): asked to stop, never waited for when destroyed. Its holds
  ## stay until it ends; `hasEnded` says when it has.
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true
      x.p.abandoned = true
      signal(x.p.changed)

proc hasEnded*(x: Inspector): bool =
  ## Whether the thread has ended (joined now, if so); true for none.
  x.stop(getMonoTime())

proc silentFor*(x: Inspector; now = fs.now()): Duration =
  ## How long the inspector has been reading without a sign of life (a read
  ## the drive does not answer); zero when it is idle or none.
  if x.p != nil:
    withLock x.p.lock:
      if x.p.busy: result = now - x.p.beat

proc readingPath*(x: Inspector): string =
  ## The file the inspector reads now; "" when it is idle or none.
  if x.p != nil:
    withLock x.p.lock:
      if x.p.busy: result = x.p.reading
