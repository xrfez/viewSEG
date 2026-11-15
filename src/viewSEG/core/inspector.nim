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
## - **A file another program cut short** is not read (its map past the new
##   end would end the program): the answer says so for its traces.
## - **Samples as displayed:** the trace's samples, not numbers set to 0, a
##   trace killed or marked dead blanked, a reversed one negated, then the
##   display processing of the plot that shows it (`flow`, as the panel's
##   reader runs it): what the status bar's amplitude reads. As recorded:
##   the samples as the file holds them.
## - At most `MaxInspectedValues` samples in all are kept per answer; the
##   rest of a trace is left out and its `cut` says how many.

import std/[algorithm, intsets, locks, os, times]
import parseSEG
import processSEG/pipeline
import processSEG/core/[rows, types, workspace]
import edits, headers, inbox, jobs, log, selection, threads

const
  MaxInspectedValues* = 32 * 1024 * 1024
    ## samples (128 MiB) one answer keeps at most, over all its traces
  MaxInspected* = 32 ## traces the Trace tab shows side by side, at most

type
  InspectPart* = enum
    ## What the Headers window has on screen, so what is read for it.
    ipRecord = "record headers"      ## File headers: the SEG-D record's blocks
    ipTraceHeaders = "trace headers" ## Trace, Header: the traces' header fields
    ipTraceSamples = "trace samples" ## Trace, Data: the traces' samples

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
    chosen*: Chosen ## the traces the Trace tab is about now
    answer*: Inspected ## the newest answer taken in
    waiting*: bool ## a request is out that has not been answered yet
    revision*: int ## bumped when `chosen` or `answer` changes

  InspectFile* = object
    ## A file a request reads, held by the caller.
    file*: ptr SeismicFile
    path*: string
    size*: int64 ## its size when it was opened; -1 when not known

  InspectTrace* = object
    ## A trace a request asks about.
    id*: int               ## its survey-wide id
    at*: int               ## its file: an index into `InspectRequest.files`
    trace*: int            ## its index in its file
    edits*: set[TraceEdit] ## as displayed: its edits
    displayed*: bool       ## its samples as displayed (its file is shown in the plot)

  InspectRequest* = object
    ## What the Headers window asks the inspector for.
    gen*: uint64
    files*: seq[InspectFile]
    recordAt*: int = -1 ## the file of the SEG-D record asked for; -1 for none
    record*: int = -1   ## that record's index in its file
    traces*: seq[InspectTrace]
    headers*: bool      ## read the traces' header fields
    samples*: bool      ## read their samples
    flow*: Pipeline     ## the display processing, for samples as displayed

  InspectorObj = object
    lock: Lock
    changed: Cond
    hasRequest, quit: bool
    request: InspectRequest
    poster: Poster
    holds: HoldRelease
    started: bool
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

func chosenTraces*(sel: Selection; followPointer: bool): Chosen =
  ## The traces the Trace tab is about: the selected ones; with none and
  ## `followPointer`, the trace under the plot's pointer, else those of the
  ## point under the map's pointer; the first `MaxInspected` of them, by id.
  var all: seq[int]
  result = Chosen()
  if sel.selected.len > 0:
    result.by = cbSelection
    for t in sel.selected: all.add t
  elif followPointer and sel.hover >= 0:
    result.by = cbPlotPointer
    all.add sel.hover
  elif followPointer and sel.hoverTraces.len > 0:
    result.by = cbMapPointer
    for t in sel.hoverTraces: all.add t
  all.sort()
  result.total = all.len
  if all.len > MaxInspected: all.setLen MaxInspected
  result.traces = all

# ------------------------------------------------------------ the thread --

proc interrupted(p: ptr InspectorObj): bool =
  withLock p.lock:
    result = p.quit or p.hasRequest

proc shorter(f: InspectFile): bool =
  ## Whether the file is shorter now than when it was opened: then nothing
  ## of it is read (`core/reader.cutShort`).
  when defined(windows):
    result = false
  else:
    result = false
    if f.size >= 0:
      try:
        result = getFileInfo(f.path).size < f.size
      except OSError:
        result = false

func usable(x: float64): bool {.inline.} = x > 0 and x < Inf

proc readSamples(d: var TraceDetail; f: ptr SeismicFile; t: InspectTrace; flow: Pipeline;
    room: int; ws: var Workspace) =
  ## Trace `t`'s samples into `d`: at most `room`, as recorded or as
  ## displayed.
  let n = f[].maxSamples([t.trace])
  let kept = min(n, max(room, 0))
  d.cut = n - kept
  if kept == 0: return
  var log: DiagLog
  let block1 = f[].readTraces([t.trace], 0 ..< kept, log)
  d.samples = newSeq[float32](kept)
  copyMem(addr d.samples[0], rowBlock(block1).rowPtr(0), kept * sizeof(float32))
  let failed = log.hasErrors # the trace could not be decoded: it reads as zeros
  if log.len > 0: d.problem = log[0].msg
  if not t.displayed: return
  d.displayed = true
  let blank = teKilled in t.edits or d.keys.status == tsDead or failed
  for x in d.samples.mitems:
    if blank or not (abs(x) < Inf): x = 0
    elif teReversed in t.edits: x = -x
  if not blank and flow.len > 0:
    let list = [t.trace]
    let plan = flow.compile(float32, d.dtMs, kept, recordSamples = n)
    ws.reserve(plan)
    let meta = initChunkMeta(f[].rowsOf(list), d.dtMs, 0)
    plan.apply(rowBlock(d.samples, 1, kept), meta, ws)

proc serve(p: ptr InspectorObj; req: InspectRequest; ws: var Workspace): bool =
  ## Reads and posts what `req` asks for; false when a newer request came
  ## first (then nothing is posted).
  var answer = Inspected(gen: req.gen)
  var cut = newSeq[bool](req.files.len)
  for i, f in req.files: cut[i] = f.shorter
  const shortText = "the file is shorter than when it was opened (another program cut it " &
    "short or is writing it): it is not read until it is opened again"
  if req.recordAt in 0 ..< req.files.len:
    let f = req.files[req.recordAt]
    answer.recordPath = f.path
    if cut[req.recordAt]: answer.record = RecordHeaders(record: req.record, problem: shortText)
    else: answer.record = readRecordHeaders(f.file[], req.record)
  var room = MaxInspectedValues
  for t in req.traces:
    if p.interrupted: return false
    var d = TraceDetail(id: t.id, trace: t.trace, dtMs: 1, t0Ms: 0)
    if t.at notin 0 ..< req.files.len:
      d.problem = "its file is busy"
    else:
      let f = req.files[t.at]
      d.file = f.path.extractFilename
      if cut[t.at]: d.problem = shortText
      else:
        try:
          d.keys = f.file[].traceKeys(t.trace)
          if usable(d.keys.intervalUs): d.dtMs = d.keys.intervalUs / 1000
          else:
            let us = f.file[].sampleIntervalUs(t.trace)
            if usable(us): d.dtMs = us / 1000
          if usable(abs(d.keys.t0Ms)) or d.keys.t0Ms == 0: d.t0Ms = d.keys.t0Ms
          if req.headers: d.rows = traceRows(f.file[], t.trace)
          if req.samples:
            d.readSamples(f.file, t, req.flow, room, ws)
            room -= d.samples.len
        except ValueError as e:
          d.problem = e.msg
    answer.traces.add d
  clearCycleRoots() # the UI thread frees what was made here
  p.poster.post Msg(job: NoJob, kind: mkInspected, inspected: answer)
  true

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
    if quit: break
  clearCycleRoots()

# --------------------------------------------------------------- the UI side --

proc `=destroy`*(x: Inspector) =
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true
      signal(x.p.changed)
    if x.p.started: joinThread(x.p.thread)
    for f in x.p.request.files: # a request never taken: its holds end here
      if x.p.hasRequest: discard x.p.holds.release(f.path)
    deinitCond(x.p.changed)
    deinitLock(x.p.lock)
    `=destroy`(x.p[])
    deallocShared(x.p)

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

proc stop*(x: Inspector) =
  ## Stops the thread and waits for it. Idempotent; destroying the
  ## inspector does it.
  if x.p != nil and x.p.started:
    withLock x.p.lock:
      x.p.quit = true
      signal(x.p.changed)
    joinThread(x.p.thread)
    x.p.started = false
