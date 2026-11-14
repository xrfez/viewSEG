## Jobs: work that would block the UI thread, run in the background in two
## lanes, visibly, while the user keeps working.
##
## - **Lanes.** The *interactive* lane runs short work the user is waiting on
##   (open, sort, join); the *background* lane runs long work (whole-file QC,
##   conversion, stack, export, workflows). Each lane has its own runner
##   thread and its own queue, so a long background job never delays an
##   interactive one. Within a lane, jobs run one at a time, in queue order.
## - **States.** A job is queued, then running, then done, failed or
##   cancelled. A queued job can be moved in its queue (`reorder`), removed
##   (`remove`) or cancelled (`cancel`); a running job can be asked to stop
##   (`cancel`); a finished job stays listed until it is removed or the
##   history is full (`initJobs(historyLimit)`), so the Jobs window can show
##   it. A job submitted with `cancellable = false` (closing a file, which
##   waits until no job reads it) can only be reordered until it has run;
##   `stop` still cancels it.
## - **Files.** A job names the files it reads and the files it needs to
##   itself (`JobSpec.reads`, `exclusive`). A job does not start while a
##   running job, or a job queued ahead of it in its lane, holds one of its
##   files in a way that conflicts: reading is shared, exclusive use is not.
##   A job that cannot start yet does not hold up the jobs behind it that
##   can. Files are compared as given: pass the path the file was opened
##   with.
## - **Holds.** A reader that is not a job (a trace panel's thread) holds
##   the file instead (`hold`, then `release`): a job that needs the file to
##   itself does not start while it is held. A hold is refused while a job
##   that needs the file to itself is queued or running, so a stream of
##   readers never keeps such a job waiting.
## - **Progress and cancel.** The work gets a `JobContext`: it reports
##   progress (`progress`, `setPhase`) and checks `cancelled`, or calls
##   `checkCancelled`, which raises `JobCancelledError`. `progress` returns
##   false once a cancel is asked for, so it serves as parseSEG's `Progress`
##   callback.
## - **Outcome.** Work that returns is done. Work that raises a
##   `CatchableError` failed, with the exception's message, unless a cancel
##   was asked for first or it raised `JobCancelledError`: then it is
##   cancelled. A `Defect` is a bug and ends the program.
##
## `Jobs` belongs to the UI thread: call its procs from there. They hold one
## lock for a few microseconds and never wait for a job, except `stop`, which
## waits for the running jobs to see their cancel. The work runs on the
## lane's thread, which is marked as a worker (`core/threads`). The work
## closure is moved to that thread and destroyed there, so it must not share
## a `ref` with the UI thread: move what it needs into it. Work that hands
## objects to the UI thread calls `clearCycleRoots` before it posts them; the
## runner calls it after every job (`core/threads`, "Handing objects to
## another thread").

import std/[locks, monotimes, options, sequtils]
import threads

export monotimes, options

const DefaultJobHistory* = 100 ## finished jobs kept by `initJobs()`

type
  JobId* = distinct int
    ## Names a job; never reused within one `Jobs`.

  JobLane* = enum
    jlInteractive = "interactive" ## short work the user is waiting on
    jlBackground = "background"   ## long work the user does not wait on

  JobState* = enum
    jsQueued = "queued"
    jsRunning = "running"
    jsDone = "done"
    jsFailed = "failed"
    jsCancelled = "cancelled"

  JobSpec* = object
    ## What a job is.
    title*: string          ## in plain words: "Open survey.sgy"
    lane*: JobLane
    reads*: seq[string]     ## files it reads; other jobs may read them too
    exclusive*: seq[string] ## files it needs to itself: no other job may use them meanwhile
    cancellable*: bool = true
      ## false for a job that must run once submitted: `cancel` and `remove`
      ## refuse it (until it has finished), `stop` does not

  JobProgress* = object
    ## How far a job is: `done` of `total` units (bytes, traces), and the
    ## part it is in. `total` 0 means unknown.
    done*, total*: int64
    phase*: string
    since*: MonoTime ## when the job, or its phase, started; zero while queued

  JobInfo* = object
    ## What the Jobs window and the status bar show about a job.
    id*: JobId
    spec*: JobSpec
    state*: JobState
    progress*: JobProgress
    error*: string                               ## why it failed; "" otherwise
    cancelRequested*: bool                       ## a cancel was asked for while it ran
    queuedAt*, startedAt*, finishedAt*: MonoTime ## zero until they happen

  JobCancelledError* = object of CatchableError
    ## Raised by `checkCancelled`; a job that raises it is cancelled.

  JobContext* = object
    ## What a job's work uses to report progress and to see a cancel. Valid
    ## while the work runs; it may be captured by callbacks the work makes,
    ## as long as they do not outlive the work.
    q: ptr JobsObj
    id: JobId

  JobWork* = proc (ctx: JobContext) {.closure, gcsafe.}
    ## The work of a job, run on its lane's thread.

  JobRec = object
    info: JobInfo
    work: JobWork ## nil once taken by the runner, or once the job finished

  RunnerArg = object
    q: ptr JobsObj
    lane: JobLane

  JobsObj = object
    ## Shared by the UI thread and the runners; every field under `lock`.
    lock: Lock
    changed: Cond                     ## broadcast on every change a runner may wait for
    recs: seq[JobRec]                 ## every job not removed, in submission order
    queue: array[JobLane, seq[JobId]] ## the queued jobs of each lane, in run order
    finished: seq[JobInfo]            ## finished since the last `takeFinished`
    holds: seq[string]                ## one entry per `hold` not yet released
    nextId: int
    revision: int
    historyLimit: int
    stopping: bool
    started: bool
    runners: array[JobLane, Thread[RunnerArg]]

func `==`*(a, b: JobId): bool {.borrow.}
func `$`*(id: JobId): string = "job " & $int(id)

const NoJob* = JobId(-1) ## names no job

# ------------------------------------------------- shared state, lock held --

func find(q: ptr JobsObj; id: JobId): int =
  for i in 0 ..< q.recs.len:
    if q.recs[i].info.id == id: return i
  -1

func conflicts(a, b: JobSpec): bool =
  ## Whether `a` and `b` may not run at the same time: one needs to itself a
  ## file the other uses.
  for p in a.exclusive:
    if p in b.reads or p in b.exclusive: return true
  for p in b.exclusive:
    if p in a.reads: return true
  false

proc pick(q: ptr JobsObj; lane: JobLane): int =
  ## The position in `lane`'s queue of the first job that may start now; -1
  ## when none may.
  for k in 0 ..< q.queue[lane].len:
    let spec = q.recs[q.find(q.queue[lane][k])].info.spec.addr
    var free = true
    for p in spec.exclusive:
      if p in q.holds: free = false
    for r in q.recs:
      if r.info.state == jsRunning and conflicts(spec[], r.info.spec):
        free = false
        break
    for m in 0 ..< k:
      if not free: break
      if conflicts(spec[], q.recs[q.find(q.queue[lane][m])].info.spec):
        free = false
    if free: return k
  -1

proc prune(q: ptr JobsObj) =
  ## Drops the oldest finished jobs beyond the history limit.
  var finished = 0
  for r in q.recs:
    if r.info.state in {jsDone, jsFailed, jsCancelled}: inc finished
  var i = 0
  while finished > q.historyLimit and i < q.recs.len:
    if q.recs[i].info.state in {jsDone, jsFailed, jsCancelled}:
      q.recs.delete(i)
      dec finished
    else:
      inc i

proc finish(q: ptr JobsObj; i: int; state: JobState; error: string) =
  ## Ends job `i` in `state`.
  q.recs[i].info.state = state
  q.recs[i].info.error = error
  q.recs[i].info.finishedAt = getMonoTime()
  q.finished.add q.recs[i].info
  inc q.revision
  q.prune()

proc unqueue(q: ptr JobsObj; i: int) =
  ## Takes queued job `i` out of its lane's queue.
  let lane = q.recs[i].info.spec.lane
  let k = q.queue[lane].find(q.recs[i].info.id)
  q.queue[lane].delete(k)

# ------------------------------------------------------------------ runner --

proc runner(arg: RunnerArg) {.thread.} =
  ## A lane's thread: runs that lane's jobs one at a time until `stop`.
  markWorkerThread()
  let q = arg.q
  acquire q.lock
  while true:
    var at = q.pick(arg.lane)
    while at < 0 and not q.stopping:
      wait(q.changed, q.lock)
      at = q.pick(arg.lane)
    if at < 0: break # stopping: `stop` cancelled what was queued
    let id = q.queue[arg.lane][at]
    q.queue[arg.lane].delete(at)
    let i = q.find(id)
    q.recs[i].info.state = jsRunning
    q.recs[i].info.startedAt = getMonoTime()
    q.recs[i].info.progress.since = q.recs[i].info.startedAt
    inc q.revision
    var work = move q.recs[i].work
    release q.lock

    var error = ""
    var gaveUp = false
    try:
      work(JobContext(q: q, id: id))
    except JobCancelledError:
      gaveUp = true
    except CatchableError as e:
      error = if e.msg.len > 0: e.msg else: $e.name
    work = nil # what the work holds is released here, outside the lock
    clearCycleRoots() # e.g. a caught exception; nothing this thread listed outlives the job

    acquire q.lock
    let j = q.find(id) # a running job is never removed or pruned
    let state =
      if gaveUp or (error.len > 0 and q.recs[j].info.cancelRequested): jsCancelled
      elif error.len > 0: jsFailed
      else: jsDone
    q.finish(j, state, if state == jsFailed: error else: "")
    broadcast(q.changed) # its files are free: a job in the other lane may start
  release q.lock
  clearCycleRoots() # and free the list before the thread ends

proc shutdown(q: ptr JobsObj) =
  ## Cancels every queued job, asks the running ones to stop, and waits for
  ## both runners to end. Idempotent.
  var doomed: seq[JobWork]
  withLock q.lock:
    if not q.stopping:
      q.stopping = true
      for lane in JobLane:
        for id in q.queue[lane]:
          let i = q.find(id)
          doomed.add move(q.recs[i].work)
          q.finish(i, jsCancelled, "")
        q.queue[lane].setLen 0
      for r in q.recs.mitems:
        if r.info.state == jsRunning: r.info.cancelRequested = true
      inc q.revision
      broadcast(q.changed)
  doomed.setLen 0 # destroyed outside the lock
  if q.started:
    joinThreads(q.runners)
    q.started = false

# -------------------------------------------------------------------- Jobs --

type
  Jobs* = object
    ## The two lanes and their runners. Move-only; destroying it stops it.
    p: ptr JobsObj

proc `=destroy`*(jobs: Jobs) =
  if jobs.p != nil:
    shutdown(jobs.p)
    deinitCond(jobs.p.changed)
    deinitLock(jobs.p.lock)
    `=destroy`(jobs.p[])
    deallocShared(jobs.p)

proc `=wasMoved`*(jobs: var Jobs) =
  jobs.p = nil

proc `=copy`*(dest: var Jobs; src: Jobs) {.error.}
proc `=dup`*(src: Jobs): Jobs {.error.}

template obj(jobs: Jobs): ptr JobsObj =
  assert jobs.p != nil, "a Jobs made with initJobs"
  jobs.p

proc initJobs*(historyLimit: Natural = DefaultJobHistory): Jobs =
  ## Starts both lanes' runners. `historyLimit` finished jobs stay listed;
  ## older ones are dropped.
  let q = cast[ptr JobsObj](allocShared0(sizeof(JobsObj)))
  initLock q.lock
  initCond q.changed
  q.historyLimit = historyLimit
  result = Jobs(p: q)
  for lane in JobLane:
    createThread(q.runners[lane], runner, RunnerArg(q: q, lane: lane))
  q.started = true

proc submit*(jobs: Jobs; spec: sink JobSpec; work: sink JobWork): JobId =
  ## Queues `work` at the end of its lane. After `stop`, the job is listed
  ## as cancelled and never runs.
  assert work != nil
  let q = jobs.obj
  let lane = spec.lane
  var doomed: JobWork
  withLock q.lock:
    result = JobId(q.nextId)
    inc q.nextId
    q.recs.add JobRec(info: JobInfo(id: result, spec: spec, state: jsQueued,
      queuedAt: getMonoTime()))
    if q.stopping:
      doomed = work
      q.finish(q.recs.high, jsCancelled, "not started: the job queue has stopped")
    else:
      q.recs[^1].work = work
      q.queue[lane].add result
      inc q.revision
      broadcast(q.changed)

proc cancel*(jobs: Jobs; id: JobId): bool =
  ## Cancels a queued job, or asks a running one to stop. False when `id` is
  ## finished, unknown or not `cancellable`.
  let q = jobs.obj
  var doomed: JobWork
  withLock q.lock:
    let i = q.find(id)
    if i < 0 or not q.recs[i].info.spec.cancellable: return false
    case q.recs[i].info.state
    of jsQueued:
      q.unqueue(i)
      doomed = move q.recs[i].work
      q.finish(i, jsCancelled, "")
      broadcast(q.changed) # a job queued behind it may now start
      result = true
    of jsRunning:
      if not q.recs[i].info.cancelRequested:
        q.recs[i].info.cancelRequested = true
        inc q.revision
      result = true
    of jsDone, jsFailed, jsCancelled:
      result = false

proc reorder*(jobs: Jobs; id: JobId; position: int): bool =
  ## Moves queued job `id` to `position` in its lane's queue (0 runs next;
  ## clamped to the queue). False when `id` is not queued.
  let q = jobs.obj
  withLock q.lock:
    let i = q.find(id)
    if i < 0 or q.recs[i].info.state != jsQueued: return false
    let lane = q.recs[i].info.spec.lane
    q.unqueue(i)
    q.queue[lane].insert(id, clamp(position, 0, q.queue[lane].len))
    inc q.revision
    broadcast(q.changed)
    result = true

proc remove*(jobs: Jobs; id: JobId): bool =
  ## Takes a queued or finished job off the list; a queued one never runs.
  ## False when `id` is running (cancel it first), queued but not
  ## `cancellable`, or unknown.
  let q = jobs.obj
  var doomed: JobWork
  withLock q.lock:
    let i = q.find(id)
    if i < 0 or q.recs[i].info.state == jsRunning: return false
    if q.recs[i].info.state == jsQueued:
      if not q.recs[i].info.spec.cancellable: return false
      q.unqueue(i)
      doomed = move q.recs[i].work
      broadcast(q.changed)
    q.recs.delete(i)
    inc q.revision
    result = true

proc stop*(jobs: Jobs) =
  ## Cancels every queued job, asks the running ones to stop, and waits for
  ## them. Later submissions never run. Idempotent; destroying `jobs` does it.
  shutdown(jobs.obj)

proc hold*(jobs: Jobs; path: string): bool {.raises: [].} =
  ## Marks `path` as read by something that is not a job, such as a trace
  ## panel's thread: a job that needs it to itself does not start until
  ## `release`. False, and nothing held, while such a job is queued or
  ## running. Any thread; take the hold before handing the file to the
  ## reader, so that a close issued later waits for it.
  let q = jobs.obj
  withLock q.lock:
    for r in q.recs:
      if r.info.state in {jsQueued, jsRunning} and path in r.info.spec.exclusive:
        return false
    q.holds.add path
    result = true

proc release*(jobs: Jobs; path: string): bool {.raises: [].} =
  ## Ends one `hold` of `path`, from any thread, once the reader no longer
  ## touches the file (its prefetchers closed). False when `path` was not
  ## held.
  let q = jobs.obj
  withLock q.lock:
    let i = q.holds.find(path)
    if i >= 0:
      q.holds.delete(i)
      broadcast(q.changed) # a job that needs the file to itself may start
      result = true

proc held*(jobs: Jobs; path: string): int =
  ## How many holds `path` has.
  let q = jobs.obj
  withLock q.lock:
    result = q.holds.count(path)

proc list*(jobs: Jobs): seq[JobInfo] =
  ## Every job listed, oldest first.
  let q = jobs.obj
  withLock q.lock:
    for r in q.recs: result.add r.info

proc info*(jobs: Jobs; id: JobId): Option[JobInfo] =
  ## Job `id`, while it is listed.
  let q = jobs.obj
  withLock q.lock:
    let i = q.find(id)
    if i >= 0: result = some(q.recs[i].info)

proc queued*(jobs: Jobs; lane: JobLane): seq[JobId] =
  ## The queued jobs of `lane`, in the order they will run.
  let q = jobs.obj
  withLock q.lock:
    result = q.queue[lane]

proc active*(jobs: Jobs): seq[JobInfo] =
  ## The running jobs, oldest first, then the queued ones in the order they
  ## will run, the interactive lane's first: what the status bar shows each
  ## frame, without copying the finished ones.
  let q = jobs.obj
  withLock q.lock:
    for r in q.recs:
      if r.info.state == jsRunning: result.add r.info
    for lane in JobLane:
      for id in q.queue[lane]: result.add q.recs[q.find(id)].info

proc takeFinished*(jobs: Jobs): seq[JobInfo] =
  ## The jobs that finished since the last call, in the order they finished.
  let q = jobs.obj
  withLock q.lock:
    swap(result, q.finished)

proc revision*(jobs: Jobs): int =
  ## A number that changes whenever anything listed changes.
  let q = jobs.obj
  withLock q.lock:
    result = q.revision

# ------------------------------------------------------------- the worker --

proc id*(ctx: JobContext): JobId {.inline.} =
  ## The job being run.
  ctx.id

proc cancelled*(ctx: JobContext): bool {.raises: [].} =
  ## Whether a cancel was asked for. Takes a lock: check it per chunk of
  ## work, not per sample.
  withLock ctx.q.lock:
    let i = ctx.q.find(ctx.id)
    result = i < 0 or ctx.q.recs[i].info.cancelRequested

proc checkCancelled*(ctx: JobContext) =
  ## Raises `JobCancelledError` once a cancel was asked for.
  if ctx.cancelled:
    raise newException(JobCancelledError, "cancelled")

proc progress*(ctx: JobContext; done, total: int64): bool {.raises: [].} =
  ## Reports `done` of `total` units; false once a cancel was asked for (so
  ## the work stops), as parseSEG's `Progress` callbacks expect.
  withLock ctx.q.lock:
    let i = ctx.q.find(ctx.id)
    if i >= 0:
      ctx.q.recs[i].info.progress.done = done
      ctx.q.recs[i].info.progress.total = total
      inc ctx.q.revision
      result = not ctx.q.recs[i].info.cancelRequested

proc setPhase*(ctx: JobContext; phase: string) {.raises: [].} =
  ## Names the part of the work now running ("indexing", "reading keys"),
  ## and starts its progress from 0 of unknown.
  withLock ctx.q.lock:
    let i = ctx.q.find(ctx.id)
    if i >= 0:
      ctx.q.recs[i].info.progress = JobProgress(phase: phase, since: getMonoTime())
      inc ctx.q.revision
