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
##   end would end the program), nor one that cannot be looked at (its drive
##   went away, or fails): the answer says so for its traces.
## - **A drive that does not answer.** Every call it makes to the file system
##   goes through the seam (`core/filesystem`: a `stat` of each file first,
##   and each read of a header block or of samples from the map marked with
##   `fs.mappedRead`). It *beats* (`fs.now`) before each, with the file it
##   reads next; one that is busy and has not beaten for a while is stuck in
##   that drive (`silentFor`, `readingPath`). The UI thread then says so, and
##   leaves it (`leave`) when the window wants another file read: a new
##   inspector reads that one, and the old one ends on its own once the drive
##   answers, keeping its holds until then (`hasEnded`); its late answer is
##   older than what was taken since, and dropped. `stop` waits until a
##   deadline only.
## - **Samples as displayed:** the trace's samples, not numbers set to 0, a
##   trace killed or marked dead blanked, a reversed one negated, then the
##   display processing of the plot that shows it (`flow`, as the panel's
##   reader runs it): what the status bar's amplitude reads. As recorded:
##   the samples as the file holds them.
## - At most `MaxInspectedValues` samples in all are kept per answer; the
##   rest of a trace is left out and its `cut` says how many.

import std/[algorithm, intsets, locks, monotimes, os, strutils, times]
import parseSEG
import processSEG/pipeline
import processSEG/core/[rows, types, workspace]
import edits, filesystem, headers, inbox, jobs, log, selection, threads

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
  ## the Headers window; the first `MaxInspected` of them, by id.
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
  elif followPointer and last.by in {cbPlotPointer, cbMapPointer}:
    return last
  all.sort()
  result.total = all.len
  if all.len > MaxInspected: all.setLen MaxInspected
  result.traces = all

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

func failedText(e: ref OSError): string =
  ## What the answer says of a read its drive failed.
  var msg = e.msg # its first line: the system's words
  let cut = msg.find('\n')
  if cut >= 0: msg.setLen cut
  "it cannot be read now (" & (if msg.len > 0: msg else: "its drive does not answer") &
    "): its drive went away or fails"

proc unreadable(f: InspectFile): string =
  ## Why nothing of the file is read now; "" when it can be. A file shorter
  ## than when it was opened would end the program when its map is read
  ## past the new end (`core/reader.cutShort`); one that cannot be looked at
  ## is on a drive that went away or fails.
  result = ""
  try:
    let size = fs.getFileInfo(f.path).size
    if f.size >= 0 and size < f.size:
      result = "the file is shorter than when it was opened (another program cut it " &
        "short or is writing it): it is not read until it is opened again"
  except OSError as e:
    result = failedText(e)

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
        fs.mappedRead(f.path, headers = true)
        answer.record = readRecordHeaders(f.file[], req.record)
      except OSError as e:
        answer.record = RecordHeaders(record: req.record, problem: failedText(e))
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
          if usable(d.keys.intervalUs): d.dtMs = d.keys.intervalUs / 1000
          else:
            let us = f.file[].sampleIntervalUs(t.trace)
            if usable(us): d.dtMs = us / 1000
          if usable(abs(d.keys.t0Ms)) or d.keys.t0Ms == 0: d.t0Ms = d.keys.t0Ms
          if req.headers:
            p.beat(f.path)
            fs.mappedRead(f.path, headers = true)
            d.rows = traceRows(f.file[], t.trace)
          if req.samples:
            p.beat(f.path)
            fs.mappedRead(f.path)
            d.readSamples(f.file, t, req.flow, room, ws)
            room -= d.samples.len
        except ValueError as e:
          d.problem = e.msg
        except OSError as e:
          d.problem = failedText(e)
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
