## The analysis windows' reader (New plot): the thread that reads the
## traces an analysis window is of, puts them through the plot's filters
## and works its view out (`core/analysis`), so that the UI thread never
## does either.
##
## - **One request per window, newest wins.** A request replaces the one of
##   the same window that waits; one being served is given up between
##   traces when a newer one of its window comes, or its window closes
##   (`cancel`). Windows' requests are served in turn.
## - **What is read.** The traces asked about, whole, less those killed, those
##   the file marks dead and those that cannot be decoded (the answer counts
##   them, `leftOut`), at the first one's sample interval (a trace sampled at
##   another interval, or with none, is left out and counted, `atOtherInterval`,
##   as the spectrum reader does); a reference trace
##   for a correlation, from the same file or another one.
## - **Filters.** The plot's filters (`Processing`, shown raw or not alike),
##   made for the traces' interval, run on whole traces; an auxiliary trace
##   goes through them only when the Aux toggle says so, as in the plot.
## - **Holds.** The caller holds the files (`Jobs.hold`) before it asks; the
##   reader ends the holds (`HoldRelease`) once it has served the request or
##   given it up, and `ask` and `cancel` end those of the requests they drop.
## - **A file cut short, or that cannot be looked at,** is not read: the
##   answer says why. Each read is marked through the seam (`fs.mappedRead`).

import std/[algorithm, locks, monotimes, os, strutils, times]
import parseSEG
import processSEG/pipeline
import processSEG/core/[rows, types, workspace]
import analysis, filesystem, fkanalysis, inbox, jobs, join, log, processing, threads, vibanalysis

type
  AnalysisAsk* = object
    ## What an analysis window asks the reader for.
    id*: int                  ## the window's
    gen*: uint64
    view*: AnalysisView
    params*: AnalysisParams
    file*: ptr SeismicFile    ## held by the caller
    path*: string
    size*: int64              ## its size when it was opened; -1 when not known
    traces*: seq[int]         ## indices in the file, in the order drawn
    unit*: SurveyUnit         ## the unit of the file's distances (offsets, coordinates)
    names*: seq[string]       ## per trace, what the curves call it: "trace 12"
    killed*: seq[int]         ## those of `traces` killed, ascending: left out
    processing*: Processing   ## the plot's filters and its Aux toggle
    refFile*: ptr SeismicFile ## a correlation's reference's file (held); nil: none
    refPath*: string
    refSize*: int64 = -1
    refTrace*: int = -1       ## its index in `refFile`
    refName*: string

  ReaderObj = object
    lock: Lock
    changed: Cond
    queue: seq[AnalysisAsk]
    quit: bool
    serving: int     ## the window whose request is served; -1 for none
    dropServed: bool ## that request is given up
    poster: Poster
    holds: HoldRelease
    started, busy, ended, abandoned: bool
    beat: MonoTime
    reading: string
    thread: Thread[ptr ReaderObj]

  AnalysisReader* = object
    ## The analysis windows' reader thread. Move-only; destroying it stops
    ## the thread.
    p: ptr ReaderObj

proc `=destroy`*(x: AnalysisReader)
proc `=wasMoved`*(x: var AnalysisReader) = x.p = nil
proc `=copy`*(dest: var AnalysisReader; src: AnalysisReader) {.error.}
proc `=dup`*(src: AnalysisReader): AnalysisReader {.error.}

func isNil*(x: AnalysisReader): bool {.inline.} =
  ## Whether `x` was never started.
  x.p == nil

# ------------------------------------------------------------ the thread --

proc interrupted(p: ptr ReaderObj; id: int): bool =
  ## Whether the request of window `id` being served is to be given up: a
  ## newer one of its window waits, it closed, or the reader stops. A sign
  ## of life too.
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

proc unreadable(path: string; size: int64): string =
  ## Why the file is not read now; "" when it can be.
  result = ""
  try:
    let now = fs.getFileInfo(path).size
    if size >= 0 and now < size:
      result = "the file is shorter than when it was opened (another program cut it " &
        "short or is writing it): it is not read until it is opened again"
  except OSError as e:
    var msg = e.msg
    let cut = msg.find('\n')
    if cut >= 0: msg.setLen cut
    result = "it cannot be read now (" & (if msg.len > 0: msg else: "its drive does not " &
      "answer") & "): its drive went away or fails"

func sameDt(a, b: float64): bool {.inline.} = abs(a - b) <= 1e-9 * max(a, b)

proc readRows(p: ptr ReaderObj; f: ptr SeismicFile; path: string; list: seq[int];
    id: int; rows: var seq[seq[float32]]; failed: var seq[bool]): bool =
  ## Traces `list` of `f`, whole, into `rows` (in its order; a trace that
  ## cannot be decoded is empty and `failed`); false when a newer request
  ## came first.
  result = true
  rows = newSeq[seq[float32]](list.len)
  failed = newSeq[bool](list.len)
  if list.len == 0: return
  p.beat(path)
  var pf = newPrefetcher[float32](f[], list, chunkTraces = 16, workers = 2, uniform = true)
  var c: PrefetchChunk[float32]
  while pf.nextInto(c):
    fs.mappedRead(path)
    let b = rowBlock(c.samples)
    for r in c.failedRows: failed[c.first + r] = true
    for k in 0 ..< c.count:
      let n = min(c.rows.numSamples(k), b.cols)
      var s = newSeq[float32](max(n, 0))
      if n > 0: copyMem(addr s[0], b.rowPtr(k), n * sizeof(float32))
      for v in s.mitems:
        if not (abs(v) < Inf): v = 0 # a sample that is not a number: as the plot draws it
      rows[c.first + k] = move s
    if c.first + c.count < list.len and p.interrupted(id):
      result = false
      break
    p.beat(path)
  discard pf.close()
  clearCycleRoots()

proc filtered(rows: var seq[seq[float32]]; f: ptr SeismicFile; list: seq[int];
    pr: Processing; dtMs: float64): string =
  ## `rows` (traces `list` of `f`) through the filters `pr` at `dtMs`,
  ## whole; an auxiliary trace only when `pr.aux`. What the filters are, in
  ## words, or why they did not run; "" for none.
  var q = pr
  q.raw = false
  if not q.hasFilters or rows.len == 0: return ""
  let filters = q.filterPipeline(dtMs)
  if filters.len == 0: return "the filters (none of them below Nyquist) did not run"
  var cols = 0
  for r in rows: cols = max(cols, r.len)
  if cols == 0: return ""
  var work = newSeq[float32](rows.len * cols)
  for i, r in rows:
    if r.len > 0: copyMem(addr work[i * cols], addr r[0], r.len * sizeof(float32))
  let b = rowBlock(work, rows.len, cols)
  try:
    let plan = filters.compile(float32, dtMs, cols, recordSamples = cols)
    var ws = initWorkspace()
    ws.reserve(plan)
    let traceRows = f[].rowsOf(list)
    if q.aux and traceRows.hasAuxiliary:
      var keys: seq[TraceKeys] = @[]
      var lengths: seq[int] = @[]
      plan.apply(b, initChunkMeta(traceRows.auxLiveRows(keys, lengths), dtMs), ws)
    else:
      plan.apply(b, initChunkMeta(traceRows, dtMs), ws)
  except ValueError as e:
    return "the filters could not run: " & e.msg
  for i in 0 ..< rows.len:
    if rows[i].len > 0: copyMem(addr rows[i][0], addr work[i * cols], rows[i].len * 4)
  "through " & q.describe

proc serve(p: ptr ReaderObj; a: AnalysisAsk): bool =
  ## Reads, works out and posts what `a` asks for; false when a newer
  ## request came first (nothing is posted).
  var answer = AnalysisResult(gen: a.gen, id: a.id, view: a.view)
  let f = a.file
  var why = unreadable(a.path, a.size)
  if why.len == 0 and a.refFile != nil and a.refPath != a.path:
    why = unreadable(a.refPath, a.refSize)
  if why.len > 0:
    answer.problem = why
  else:
    # the traces to read: live, not killed, at the first one's interval
    var list: seq[int] = @[]
    var names: seq[string] = @[]
    var dtMs = NaN
    var t0Ms = 0.0
    for i, t in a.traces:
      if t notin 0 ..< f[].len or a.killed.binarySearch(t) >= 0 or
          f[].traceKeys(t).status == tsDead:
        inc answer.leftOut
      else:
        let k = f[].traceKeys(t)
        # the interval as the spectrum reader resolves it: the trace's, else the file's
        let us = if k.intervalUs > 0 and k.intervalUs < Inf: k.intervalUs
                 else: f[].sampleIntervalUs(t)
        if not (us > 0 and us < Inf):
          inc answer.atOtherInterval
        else:
          let dt = us / 1000
          if dtMs.isNaN:
            dtMs = dt
            if abs(k.t0Ms) < Inf: t0Ms = k.t0Ms
          if sameDt(dt, dtMs):
            list.add t
            names.add (if i < a.names.len: a.names[i] else: "trace " & $(t + 1))
          else: inc answer.atOtherInterval
    answer.dtMs = dtMs
    if list.len == 0:
      answer.problem = "no trace to work it out on (" &
        (if a.traces.len == 0: "none asked about" else: "every one left out: killed, " &
        "marked dead, or at another interval") & ")"
    else:
      try:
        var rows: seq[seq[float32]] = @[]
        var failed: seq[bool] = @[]
        if not p.readRows(f, a.path, list, a.id, rows, failed): return false
        var kept: seq[seq[float32]] = @[]
        var keptNames: seq[string] = @[]
        var keptList: seq[int] = @[]
        for i in 0 ..< rows.len:
          if failed[i] or rows[i].len == 0: inc answer.leftOut
          else:
            kept.add move rows[i]
            keptNames.add names[i]
            keptList.add list[i]
        let raw = a.view == avFk and a.params.fkRaw # (f-k: raw or processed, chosen)
        let through = if kept.len > 0 and not raw: filtered(kept, f, keptList, a.processing,
          dtMs) else: ""
        if kept.len == 0:
          answer.problem = "none of the traces could be read"
        else:
          case a.view
          of avSpectrogram:
            let n = (answer.leftOut, answer.atOtherInterval)
            answer = spectrogramOf(kept, dtMs, t0Ms, a.params)
            (answer.leftOut, answer.atOtherInterval) = n
          of avEnvelope:
            let n = (answer.leftOut, answer.atOtherInterval)
            answer = envelopeOf(kept[0], keptNames[0], dtMs, t0Ms)
            (answer.leftOut, answer.atOtherInterval) = n
          of avPhase:
            let n = (answer.leftOut, answer.atOtherInterval)
            answer = phaseOf(kept[0], keptNames[0], dtMs, a.params)
            (answer.leftOut, answer.atOtherInterval) = n
          of avCorrelation:
            # the reference: its own trace, read and filtered as the others
            let rf = if a.refFile != nil: a.refFile else: f
            let rt = if a.refTrace >= 0: a.refTrace else: keptList[0]
            let rpath = if a.refFile != nil: a.refPath else: a.path
            var refRows: seq[seq[float32]] = @[]
            var refFailed: seq[bool] = @[]
            if rt notin 0 ..< rf[].len:
              answer.problem = "the reference trace is not in its file"
            else:
              if not p.readRows(rf, rpath, @[rt], a.id, refRows, refFailed): return false
              let rk = rf[].traceKeys(rt)
              let rus = if rk.intervalUs > 0 and rk.intervalUs < Inf: rk.intervalUs
                        else: rf[].sampleIntervalUs(rt)
              let rdt = rus / 1000
              if refFailed[0] or refRows[0].len == 0:
                answer.problem = "the reference trace could not be read"
              elif not (rus > 0 and rus < Inf):
                answer.problem = "the reference trace is at another interval: it has " &
                  "no sample interval"
              elif not sameDt(rdt, dtMs):
                answer.problem = "the reference is sampled at " & $rdt & " ms, the traces at " &
                  $dtMs & " ms"
              else:
                discard filtered(refRows, rf, @[rt], a.processing, dtMs)
                var signals: seq[(string, seq[float32])] = @[]
                for i in 0 ..< min(kept.len, MaxAnalysisCurves):
                  signals.add (keptNames[i], kept[i])
                let refName = if a.refName.len > 0: a.refName else: keptNames[0]
                let n = (answer.leftOut, answer.atOtherInterval)
                answer = correlationOf(signals, refRows[0], refName, dtMs, a.params)
                (answer.leftOut, answer.atOtherInterval) = n
                # a signal that is the reference itself: its autocorrelation
                let own = if rf == f: keptList.find(rt) else: -1
                if own in 0 ..< signals.len and answer.problem.len == 0:
                  answer.note.add "; " & keptNames[own] & " is the reference itself: its " &
                    "autocorrelation (a peak at 0 ms, 0 dB, 0°)"
          of avFk:
            # the trace spacing, from the keys of the traces read
            var offsets, xs, ys: seq[float64] = @[]
            for t in keptList:
              let k = f[].traceKeys(t)
              offsets.add k.offset
              xs.add k.rcvX
              ys.add k.rcvY
            let (spacing, source) = spacingOf(offsets, xs, ys)
            let n = (answer.leftOut, answer.atOtherInterval)
            answer = fkOf(kept, spacing, source, a.unit, dtMs, t0Ms, a.params)
            (answer.leftOut, answer.atOtherInterval) = n
          of avVibrator:
            # each role's trace: its place among those asked about, then
            # among those read (one left out has no role)
            let places = [vsReference: a.params.roles.reference,
              vsGroundForce: a.params.roles.groundForce, vsMass: a.params.roles.mass,
              vsBaseplate: a.params.roles.baseplate]
            var at: array[VibRole, int]
            var missing: seq[string] = @[]
            for role in VibRole:
              let q = places[role]
              at[role] = if q in 0 ..< a.traces.len: keptList.find(a.traces[q]) else: -1
              if q in 0 ..< a.traces.len and at[role] < 0: missing.add $role
            let n = (answer.leftOut, answer.atOtherInterval)
            answer = vibratorOf(kept, keptNames, at, dtMs, a.params)
            (answer.leftOut, answer.atOtherInterval) = n
            if missing.len > 0:
              let words = missing.join(", ") & " left out (killed, dead or unreadable)"
              if answer.problem.len > 0: answer.problem.add "; " & words
              else: answer.note.add "; " & words
          answer.gen = a.gen
          answer.id = a.id
          if through.len > 0 and answer.problem.len == 0:
            answer.note = (if answer.note.len > 0: answer.note & "; " else: "") & through
      except OSError as e:
        answer.problem = "it cannot be read now: " & e.msg
      except ValueError as e:
        answer.problem = e.msg
  answer.gen = a.gen
  answer.id = a.id
  answer.view = a.view
  clearCycleRoots() # the UI thread frees what was made here
  p.poster.post Msg(job: NoJob, kind: mkAnalysis, analysis: answer)
  true

proc release(p: ptr ReaderObj; a: AnalysisAsk) =
  discard p.holds.release(a.path)
  if a.refFile != nil: discard p.holds.release(a.refPath)

proc run(p: ptr ReaderObj) {.thread.} =
  markWorkerThread()
  while true:
    var a: AnalysisAsk
    var got, quit = false
    withLock p.lock:
      while not (p.quit or p.queue.len > 0):
        wait(p.changed, p.lock)
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
        discard p.serve(a)
      except CatchableError as e:
        p.poster.post Msg(job: NoJob, kind: mkLog, entry: LogEntry(time: getTime(),
          severity: sevWarning, source: "New plot", text: "A plot could not be worked " &
          "out: " & e.msg))
      clearCycleRoots()
      p.release(a)
    withLock p.lock:
      p.busy = false
      p.serving = -1
      p.reading = ""
    if quit: break
  clearCycleRoots()
  withLock p.lock:
    p.busy = false
    p.ended = true

# --------------------------------------------------------------- the UI side --

const AnalysisStopWait* = initDuration(milliseconds = 800)

proc stop*(x: AnalysisReader; deadline = getMonoTime() + AnalysisStopWait): bool {.
  discardable, raises: [].}

proc `=destroy`*(x: AnalysisReader) =
  if x.p != nil:
    var abandoned = false
    withLock x.p.lock:
      abandoned = x.p.abandoned
    if not abandoned: discard x.stop()
    if not x.p.started:
      for a in x.p.queue:
        discard x.p.holds.release(a.path)
        if a.refFile != nil: discard x.p.holds.release(a.refPath)
      deinitCond(x.p.changed)
      deinitLock(x.p.lock)
      `=destroy`(x.p[])
      deallocShared(x.p)

proc newAnalysisReader*(poster: sink Poster; holds: HoldRelease): AnalysisReader =
  ## Starts the reader, which posts through `poster` and ends its holds
  ## through `holds`.
  let p = cast[ptr ReaderObj](allocShared0(sizeof(ReaderObj)))
  initLock p.lock
  initCond p.changed
  p.poster = poster
  p.holds = holds
  p.serving = -1
  result = AnalysisReader(p: p)
  createThread(p.thread, run, p)
  p.started = true

proc dropOf(x: AnalysisReader; id: int): seq[AnalysisAsk] =
  ## Window `id`'s requests waiting, taken out of the queue (under the lock).
  var i = 0
  while i < x.p.queue.len:
    if x.p.queue[i].id == id:
      result.add move x.p.queue[i]
      x.p.queue.delete i
    else: inc i

proc ask*(x: AnalysisReader; a: sink AnalysisAsk) =
  ## Asks for `a`, whose files the caller holds; replaces a request of the
  ## same window not yet taken (ending its holds), and has one being served
  ## given up.
  assert x.p != nil
  var dropped: seq[AnalysisAsk] = @[]
  withLock x.p.lock:
    dropped = x.dropOf(a.id)
    x.p.queue.add a
    signal(x.p.changed)
  for d in dropped: x.p.release(d)

proc cancel*(x: AnalysisReader; id: int) =
  ## Drops window `id`'s requests: one waiting (its holds ended), and one
  ## being served is given up.
  if x.p == nil: return
  var dropped: seq[AnalysisAsk] = @[]
  withLock x.p.lock:
    dropped = x.dropOf(id)
    if x.p.serving == id: x.p.dropServed = true
  for d in dropped: x.p.release(d)

proc askStop*(x: AnalysisReader) =
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true
      signal(x.p.changed)

proc stop*(x: AnalysisReader; deadline = getMonoTime() + AnalysisStopWait): bool {.
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

proc leave*(x: AnalysisReader) =
  ## Leaves the thread to end on its own (stuck in a drive that does not
  ## answer); its holds stay until it ends.
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true
      x.p.abandoned = true
      signal(x.p.changed)

proc silentFor*(x: AnalysisReader; now = fs.now()): Duration =
  ## How long the reader has been busy without a sign of life; zero when
  ## idle or none.
  if x.p != nil:
    withLock x.p.lock:
      if x.p.busy: result = now - x.p.beat

proc readingPath*(x: AnalysisReader): string =
  ## The file the reader reads now; "" when it is idle or none.
  if x.p != nil:
    withLock x.p.lock:
      if x.p.busy: result = x.p.reading
