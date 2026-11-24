## Jobs: work that would block the UI thread, run in the background in
## three lanes, visibly, while the user keeps working.
##
## - **Lanes.** The *interactive* lane runs short work the user is waiting on
##   (open, sort, join); the *background* lane runs long work (whole-file QC,
##   conversion, stack, export, workflows); the *hashes* lane reads files
##   whole for their identity (a hash of every byte), seconds for a large
##   file and minutes on a share, so that the background work never waits
##   behind it. Each lane has its own runner thread and its own queue, so a
##   long job of one lane never delays another lane's. Within a lane, jobs
##   run one at a time, in queue order.
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
##   readers never keeps such a job waiting; also once such a job is
##   abandoned (below), until its work comes back: it may still be changing
##   the file's keys (a geometry join, one step that no cancel stops).
## - **Progress and cancel.** The work gets a `JobContext`: it reports
##   progress (`progress`, `setPhase`) and checks `cancelled`, or calls
##   `checkCancelled`, which raises `JobCancelledError`. `progress` returns
##   false once a cancel is asked for, so it serves as parseSEG's `Progress`
##   callback. Work about to start a step that must not stop halfway calls
##   `commit`: a cancel asked for later is refused.
## - **Outcome.** Work that returns is done. Work that raises a
##   `CatchableError` failed, with the exception's message, unless a cancel
##   was asked for first or it raised `JobCancelledError`: then it is
##   cancelled. A `Defect` is a bug and ends the program.
## - **Work that does not answer** (a network drive that stopped answering
##   holds its thread in the kernel, where no cancel reaches it). A running
##   job *beats* each time it reports (`progress`, `setPhase`); one that has
##   not beaten for `StallAfter` is not answering (`notAnsweringFor`), timed
##   on `fs.now`. `tend`, once a frame, gives its lane a new runner when work
##   waits behind it (the job stays running, and its result is taken if it
##   comes), and *abandons* it once a cancel was asked for and it has not
##   stopped within `CancelGrace` (or at once when it does not answer): it is
##   cancelled, its result dropped, and its files stay held until its work
##   comes back, so that nothing that reads them is closed under it. A runner
##   left so ends after that job.
##
## `Jobs` belongs to the UI thread: call its procs from there. They hold one
## lock for a few microseconds and never wait for a job, except `stop`, which
## waits for the running jobs to see their cancel until a deadline, then
## leaves those that do not (`stop` returns false; their memory stays with
## them to the end of the process). The work runs on the
## lane's thread, which is marked as a worker (`core/threads`). The work
## closure is moved to that thread and destroyed there, so it must not share
## a `ref` with the UI thread: move what it needs into it. Work that hands
## objects to the UI thread calls `clearCycleRoots` before it posts them; the
## runner calls it after every job (`core/threads`, "Handing objects to
## another thread").

import std/[atomics, locks, monotimes, options, os, sequtils, strutils, times]
import filesystem, threads

export monotimes, options

const
  DefaultJobHistory* = 100 ## finished jobs kept by `initJobs()`
  StallAfter* = initDuration(seconds = 3)
    ## a running job that has not reported for this long is not answering
  CancelGrace* = initDuration(seconds = 1)
    ## how long a cancelled job that still answers has to stop before it is abandoned
  JobStopWait* = initDuration(milliseconds = 800)
    ## how long `stop` waits, by default, for the running jobs to see their cancel

type
  JobId* = distinct int
    ## Names a job; never reused within one `Jobs`.

  JobLane* = enum
    jlInteractive = "interactive" ## short work the user is waiting on
    jlBackground = "background"   ## long work the user does not wait on
    jlHashes = "hashes"
      ## files read whole for their identity: a lane of their own, so that a
      ## large file's hash never holds the background work
    jlOriginals = "originals"
      ## a project's survey originals looked at (one may be read whole, on a
      ## share): a lane of their own, so that it holds neither a data file's
      ## hash nor the background work
    jlPeeks = "peeks"
      ## a file's headers read for what they say (a survey file's units, the
      ## kind of recording of each listed file): a lane of their own, so that
      ## a file on a drive that does not answer holds no open and no import

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
    auto*: bool
      ## started by the program, not by a command of the user: its end is not
      ## announced when it went well (a failure is)
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
    cancelAt*: MonoTime                          ## when the cancel was asked for (`fs.now`); zero for none
    beat*: MonoTime
      ## when the running work last reported (`fs.now`): `notAnsweringFor`
    abandoned*: bool
      ## cancelled while it did not answer: left to end on its own, its result dropped

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

  JobHook* = proc (id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].}
    ## Tests (`setJobHook`): called on the job's thread each time its work
    ## names a phase (`setPhase`, after the phase is listed; `back` false),
    ## and once its work has returned (`back` true). It may block, as a long
    ## step would hold the thread there.

  JobRec = object
    info: JobInfo
    work: JobWork ## nil once taken by the runner, or once the job finished

  RunnerObj = object
    ## A lane's runner thread, in shared memory of its own: a runner left to
    ## its job (`tend`) outlives its place in the lane. Fields under the
    ## jobs' lock.
    thread: Thread[RunnerArg]
    lane: JobLane
    job: JobId ## the job it runs; `NoJob` while it picks
    abandoned: bool
      ## its job was abandoned (`tend`): listed cancelled already
    held: seq[string] ## its job was abandoned: the holds to end when its work is back
    exclusive: seq[string]
      ## of those, the files its job needed to itself: no reader meanwhile
    ended, joined: bool

  RunnerArg = object
    q: ptr JobsObj
    me: ptr RunnerObj

  JobsObj = object
    ## Shared by the UI thread and the runners; every field under `lock`.
    lock: Lock
    changed: Cond                          ## broadcast on every change a runner may wait for
    recs: seq[JobRec]                      ## every job not removed, in submission order
    queue: array[JobLane, seq[JobId]]      ## the queued jobs of each lane, in run order
    finished: seq[JobInfo]                 ## finished since the last `takeFinished`
    holds: seq[string]                     ## one entry per `hold` not yet released
    nextId: int
    revision: int
    historyLimit: int
    stopping: bool
    waited: bool                           ## `stop` has waited once: a second stop does not
    current: array[JobLane, ptr RunnerObj] ## the runner each lane's next job runs on
    runners: seq[ptr RunnerObj]            ## every runner started, until joined

func `==`*(a, b: JobId): bool {.borrow.}
func `$`*(id: JobId): string = "job " & $int(id)

const NoJob* = JobId(-1) ## names no job

var jobHook: Atomic[pointer] # a `JobHook`; nil for none (the program)

proc setJobHook*(h: JobHook) =
  ## Calls `h` at each phase a job's work names, and when its work has
  ## returned, from now on; nil for none. Tests: a step that takes long (a
  ## join's, which reads no file) is held there, so what happens meanwhile
  ## (a cancel, the quit) is tested without a long job.
  jobHook.store(cast[pointer](h))

template callHook(id: JobId; phase: string; back: bool) =
  let h = cast[JobHook](jobHook.load(moRelaxed))
  if h != nil: h(id, phase, back)

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

proc runner(arg: RunnerArg) {.thread.}

proc startRunner(q: ptr JobsObj; lane: JobLane): bool =
  ## Starts a runner for `lane` and makes it the lane's; lock held. False
  ## when no thread can be made (the lane keeps the runner it has).
  let r = cast[ptr RunnerObj](allocShared0(sizeof(RunnerObj)))
  r.lane = lane
  r.job = JobId(-1)
  try:
    createThread(r.thread, runner, RunnerArg(q: q, me: r))
  except ResourceExhaustedError:
    deallocShared(r)
    return false
  q.runners.add r
  q.current[lane] = r
  true

proc runner(arg: RunnerArg) {.thread.} =
  ## A lane's thread: runs that lane's jobs one at a time until `stop`, or,
  ## once another runner has the lane (`tend`), until its job is done.
  markWorkerThread()
  let q = arg.q
  let me = arg.me
  let lane = me.lane
  # A test delays each job's start (a starved machine). Unset: no wait.
  let jobDelay = block:
    var n = 0
    let v = getEnv("VIEWSEG_JOB_DELAY_MS")
    if v.len > 0:
      try:
        n = parseInt(v)
      except ValueError:
        n = 0
    n
  acquire q.lock
  while q.current[lane] == me:
    var at = q.pick(lane)
    while at < 0 and not q.stopping and q.current[lane] == me:
      wait(q.changed, q.lock)
      at = q.pick(lane)
    if at < 0: break # stopping: `stop` cancelled what was queued
    let id = q.queue[lane][at]
    q.queue[lane].delete(at)
    let i = q.find(id)
    q.recs[i].info.state = jsRunning
    q.recs[i].info.startedAt = getMonoTime()
    q.recs[i].info.progress.since = q.recs[i].info.startedAt
    q.recs[i].info.beat = fs.now()
    me.job = id
    inc q.revision
    var work = move q.recs[i].work
    release q.lock

    var error = ""
    var gaveUp = false
    if jobDelay > 0: sleep jobDelay
    try:
      work(JobContext(q: q, id: id))
    except JobCancelledError:
      gaveUp = true
    except CatchableError as e:
      error = if e.msg.len > 0: e.msg else: $e.name
    work = nil # what the work holds is released here, outside the lock
    clearCycleRoots() # e.g. a caught exception; nothing this thread listed outlives the job
    callHook(id, "", back = true)

    acquire q.lock
    me.job = JobId(-1)
    if me.abandoned:
      # Abandoned (`tend`): already listed as cancelled, and its record may be
      # gone since (removed, or past the history); its files are free now. A
      # job that named no file (a listing) is abandoned too.
      for p in me.held:
        let h = q.holds.find(p)
        if h >= 0: q.holds.delete(h)
      me.held.setLen 0
      me.exclusive.setLen 0
      me.abandoned = false
    else:
      let j = q.find(id) # a running job is never removed or pruned
      let state =
        if gaveUp or (error.len > 0 and q.recs[j].info.cancelRequested): jsCancelled
        elif error.len > 0: jsFailed
        else: jsDone
      q.finish(j, state, if state == jsFailed: error else: "")
    broadcast(q.changed) # its files are free: a job in the other lane may start
  release q.lock
  clearCycleRoots() # and free the list before the thread ends
  withLock q.lock:
    me.ended = true

proc ask(q: ptr JobsObj): seq[JobWork] =
  ## Lock held: from now on no job starts; the queued ones are cancelled
  ## (their work returned, to be destroyed outside the lock) and the
  ## running ones asked to stop.
  if not q.stopping:
    q.stopping = true
    for lane in JobLane:
      for id in q.queue[lane]:
        let i = q.find(id)
        result.add move(q.recs[i].work)
        q.finish(i, jsCancelled, "")
      q.queue[lane].setLen 0
    for r in q.recs.mitems:
      if r.info.state == jsRunning and not r.info.cancelRequested:
        r.info.cancelRequested = true
        r.info.cancelAt = fs.now()
    inc q.revision
    broadcast(q.changed)

proc shutdown(q: ptr JobsObj; deadline: MonoTime): bool =
  ## Cancels every queued job, asks the running ones to stop, and waits for
  ## the runners to end until `deadline`; joins those that did. True when
  ## every runner has ended. Idempotent.
  var doomed: seq[JobWork]
  var deadline = deadline
  withLock q.lock:
    doomed = q.ask()
    if q.waited: deadline = getMonoTime() # those left then are left for good
    q.waited = true
  doomed.setLen 0 # destroyed outside the lock
  while true:
    var all = true
    withLock q.lock:
      for r in q.runners:
        if not r.ended: all = false
    if all or getMonoTime() >= deadline:
      result = all
      break
    sleep 1
  var gone: seq[ptr RunnerObj]
  withLock q.lock:
    var kept: seq[ptr RunnerObj]
    for r in q.runners:
      if r.ended: gone.add r else: kept.add r
    q.runners = kept
  for r in gone:
    joinThread(r.thread)
    deallocShared(r)

# -------------------------------------------------------------------- Jobs --

type
  Jobs* = object
    ## The two lanes and their runners. Move-only; destroying it stops it.
    p: ptr JobsObj

proc `=destroy`*(jobs: Jobs) =
  if jobs.p != nil:
    let all = shutdown(jobs.p, getMonoTime() + JobStopWait)
    var held = 0
    withLock jobs.p.lock:
      held = jobs.p.holds.len
    # A runner left to its job, or a reader that still holds a file, may use
    # the shared state later: then it stays, to the end of the process.
    if all and held == 0:
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
  withLock q.lock:
    for lane in JobLane:
      if not q.startRunner(lane):
        raise newException(ResourceExhaustedError, "cannot start the job runners")

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
        q.recs[i].info.cancelAt = fs.now()
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

proc askStop*(jobs: Jobs) =
  ## Cancels every queued job and asks the running ones to stop, without
  ## waiting: `stop` waits. Later submissions never run.
  var doomed: seq[JobWork]
  withLock jobs.obj.lock:
    doomed = jobs.obj.ask()

proc stop*(jobs: Jobs; deadline = getMonoTime() + JobStopWait): bool {.discardable.} =
  ## Cancels every queued job, asks the running ones to stop, and waits for
  ## them until `deadline`: true when all have ended; the others are left to
  ## end on their own (a drive that does not answer). Later submissions
  ## never run. Idempotent; destroying `jobs` does it.
  shutdown(jobs.obj, deadline)

proc notAnsweringFor*(info: JobInfo; now = fs.now()): Duration =
  ## How long running job `info` has not reported, once that is
  ## `StallAfter` or more; zero for a job that answers or does not run.
  if info.state == jsRunning and not info.abandoned and info.beat != MonoTime() and
      now - info.beat >= StallAfter:
    now - info.beat
  else: initDuration()

proc abandon(q: ptr JobsObj; r: ptr RunnerObj; i: int) =
  ## Lock held: job `i`, run by `r`, cancelled and not answering, is listed
  ## as cancelled now; its files stay held until its work comes back.
  template info: untyped = q.recs[i].info
  for p in info.spec.reads: r.held.add p
  for p in info.spec.exclusive:
    r.held.add p
    r.exclusive.add p
  q.holds.add r.held
  r.abandoned = true
  info.abandoned = true
  q.finish(i, jsCancelled, "")

proc tend*(jobs: Jobs; now = fs.now()): bool {.discardable.} =
  ## Once a frame: gives a lane whose job does not answer a new runner when
  ## work waits behind that job, and abandons a cancelled job that has not
  ## stopped (the module documentation). True when anything changed.
  let q = jobs.obj
  withLock q.lock:
    if q.stopping: return false
    var i = 0
    while i < q.runners.len:
      let r = q.runners[i]
      inc i
      if r.ended or r.abandoned or int(r.job) < 0: continue
      let j = q.find(r.job)
      if j < 0 or q.recs[j].info.state != jsRunning: continue
      template info: untyped = q.recs[j].info
      let silent = now - info.beat >= StallAfter
      let lane = info.spec.lane
      if info.cancelRequested and (silent or now - info.cancelAt >= CancelGrace):
        if q.current[lane] == r and not q.startRunner(lane): continue
        q.abandon(r, j)
        broadcast(q.changed)
        result = true
      elif silent and q.current[lane] == r and q.pick(lane) >= 0:
        if q.startRunner(lane): # it goes on alone; the next job starts beside it
          inc q.revision
          result = true

proc hold*(jobs: Jobs; path: string): bool {.raises: [].} =
  ## Marks `path` as read by something that is not a job, such as a trace
  ## panel's thread: a job that needs it to itself does not start until
  ## `release`. False, and nothing held, while such a job is queued or
  ## running, or was abandoned and its work has not come back. Any thread;
  ## take the hold before handing the file to the reader, so that a close
  ## issued later waits for it.
  let q = jobs.obj
  withLock q.lock:
    for r in q.recs:
      if r.info.state in {jsQueued, jsRunning} and path in r.info.spec.exclusive:
        return false
    for r in q.runners:
      if path in r.exclusive: return false
    q.holds.add path
    result = true

proc endHold(q: ptr JobsObj; path: string): bool {.raises: [].} =
  withLock q.lock:
    let i = q.holds.find(path)
    if i >= 0:
      q.holds.delete(i)
      broadcast(q.changed) # a job that needs the file to itself may start
      result = true

proc release*(jobs: Jobs; path: string): bool {.raises: [].} =
  ## Ends one `hold` of `path`, from any thread, once the reader no longer
  ## touches the file (its prefetchers closed). False when `path` was not
  ## held.
  jobs.obj.endHold(path)

proc held*(jobs: Jobs; path: string): int =
  ## How many holds `path` has.
  let q = jobs.obj
  withLock q.lock:
    result = q.holds.count(path)

proc holdsLeft*(jobs: Jobs): int =
  ## How many holds there are, of every file: once every reader the caller
  ## knows of has ended, those of readers left to end on their own and of
  ## abandoned jobs' work (which may still read the files).
  let q = jobs.obj
  withLock q.lock:
    result = q.holds.len

proc workingOn*(jobs: Jobs; id: JobId): bool =
  ## Whether the work of job `id` still runs, also after the job was listed
  ## cancelled because it did not stop (abandoned, `tend`): what the work
  ## reads must stay until it is back.
  let q = jobs.obj
  withLock q.lock:
    for r in q.runners:
      if r.job == id and not r.ended: return true

type
  HoldRelease* = object
    ## Lets a reader that is not a job end its holds from its own thread
    ## (`release`). Valid while the `Jobs` it came from lives: stop the
    ## reader before the `Jobs` goes.
    q: ptr JobsObj

proc holdRelease*(jobs: Jobs): HoldRelease =
  ## A handle a reader thread ends its holds with.
  HoldRelease(q: jobs.obj)

proc release*(h: HoldRelease; path: string): bool {.raises: [].} =
  ## `Jobs.release`, from any thread. False when `path` was not held.
  h.q != nil and h.q.endHold(path)

proc held*(h: HoldRelease; path: string): int {.raises: [].} =
  ## `Jobs.held`, from any thread: how many holds `path` has (a job that
  ## needs the file to itself checks there are none).
  if h.q != nil:
    withLock h.q.lock:
      result = h.q.holds.count(path)

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

proc queues*(jobs: Jobs): array[JobLane, seq[JobId]] =
  ## The queued jobs of every lane, each in the order they will run.
  let q = jobs.obj
  withLock q.lock:
    result = q.queue

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

proc commit*(ctx: JobContext): bool {.raises: [].} =
  ## From now on the job runs to its end: a cancel asked for later is
  ## refused, as for a job submitted not `cancellable`, so `tend` never
  ## abandons it (`stop` still asks it to stop). For a step that changes
  ## what others read and cannot stop halfway, such as a join's change of a
  ## file's keys: abandoned there, it would be listed cancelled while its
  ## work goes on changing them. False, and nothing changes, when a cancel
  ## was asked for already: the work stops then.
  withLock ctx.q.lock:
    let i = ctx.q.find(ctx.id)
    if i >= 0 and not ctx.q.recs[i].info.cancelRequested:
      ctx.q.recs[i].info.spec.cancellable = false
      inc ctx.q.revision
      result = true

proc progress*(ctx: JobContext; done, total: int64): bool {.raises: [].} =
  ## Reports `done` of `total` units; false once a cancel was asked for (so
  ## the work stops), as parseSEG's `Progress` callbacks expect.
  withLock ctx.q.lock:
    let i = ctx.q.find(ctx.id)
    if i >= 0:
      ctx.q.recs[i].info.progress.done = done
      ctx.q.recs[i].info.progress.total = total
      ctx.q.recs[i].info.beat = fs.now()
      inc ctx.q.revision
      result = not ctx.q.recs[i].info.cancelRequested

proc setPhase*(ctx: JobContext; phase: string) {.raises: [].} =
  ## Names the part of the work now running ("indexing", "reading keys"),
  ## and starts its progress from 0 of unknown.
  withLock ctx.q.lock:
    let i = ctx.q.find(ctx.id)
    if i >= 0:
      ctx.q.recs[i].info.progress = JobProgress(phase: phase, since: getMonoTime())
      ctx.q.recs[i].info.beat = fs.now()
      inc ctx.q.revision
  callHook(ctx.id, phase, back = false)

proc setDetail*(ctx: JobContext; text: string) {.raises: [].} =
  ## Names a detail of the part now running ("412 of 9000 shots") without
  ## restarting its progress: `done`, `total` and the start of the estimate
  ## stay as they are. Empty `text` clears the detail. Safe from the job's
  ## thread at any time.
  withLock ctx.q.lock:
    let i = ctx.q.find(ctx.id)
    if i >= 0:
      ctx.q.recs[i].info.progress.phase = text
      inc ctx.q.revision
