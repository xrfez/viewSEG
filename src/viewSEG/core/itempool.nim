## A pool of worker threads for the independent items of one job: a report over
## 500 files makes 500 items, each read and judged on its own, and the job's
## thread takes their results strictly in item order, so that the report is
## the same on one thread and on eight.
##
## ```nim
## proc judge(it: ItemContext; args: ptr Files; i: int): Row {.nimcall.} = ...
## let run = ctx.parallelItems(files.len, addr files, judge,
##   proc (i: int; outcome: sink ItemOutcome[Row]) = ..., ItemOptions())
## ```
##
## `core/jobs` wraps `runBatch` as `parallelItems` and owns the one pool of the
## process, shared by every lane; this module knows nothing of jobs, only of
## `ItemHooks` (the cancel and the progress report of whoever runs the batch).
##
## **How a batch runs.** One lock, a leaf lock (nothing else is acquired, and no
## hook is called, while it is held), guards the pool and every batch. The
## caller registers its batch, starts the workers it lacks (lazily, never once
## the pool is stopping) and then loops: it takes the finished item `taken` out
## of its slot and hands it to `take` on its own thread, else runs the next item
## itself, else waits on the batch's `ready`. A worker hands out the next item
## of the first batch that has one, runs it unlocked, places the outcome and
## wakes the batch's caller. An item is handed out only while it is fewer than
## `window` items beyond the next to take (so the results held, running or
## finished, never exceed `window`, whatever the number of items) and fewer than
## `maxInFlight` run; the hand-out itself reserves its slot, in the same lock
## region as the test. Every wait is in a predicate loop and every wake-up is a
## broadcast. A batch returns only after every item handed out has come back,
## whichever way it ended (a cancel, a raising `take`, a Defect in the caller's
## own item), so what the job's files and arguments hold stays valid for the
## items. The model is `docs/models/itempool.nif` (one batch) and
## `docs/models/itempoollanes.nif` (two batches, the lazy start, a shrink, the
## shutdown).
##
## **Why the caller runs items too.** It keeps the job moving when every worker
## is busy for another batch, and it is what makes a batch finish when a wake-up
## to the workers is missed: the missing wake-up only makes it slower, never
## hang (the models record that: without it, the take-out's broadcast on `work`
## is load-bearing).
##
## **Rules for an item.** `work` is a `nimcall` with no environment; `args`
## points into the job thread's frame and outlives the batch. An item reads
## plain fields of `A` and copies strings and seqs out of it; it never copies,
## assigns or destroys a `ref` or closure reachable from `A`, never takes `var`
## of its parts and never holds a `JobContext`. Its result `R` is plain data
## (`plainData`: no `ref`, `ptr`, `pointer` or `proc`). An item that raises a
## `CatchableError` arrives at `take` as an `ItemFailure`; a Defect ends the
## program, as on any thread. A batch started from an item is a Defect in every
## build (`doAssert`): the pool is one level.
##
## **Under ORC** every thread that makes objects calls `clearCycleRoots` before
## they change hands (`core/threads`): the wrapper does it after each item, on
## the thread that ran it.

import std/[atomics, bitops, cpuinfo, locks, macros, monotimes, os, times, typetraits]
import parseSEG/common/errors
import threads

const MaxItemThreads* = 8
  ## Most threads that run one batch's items, the job's own thread included.

const ProgressEvery = initDuration(milliseconds = 100)

func defaultItemThreads*(): int =
  ## Threads that run one batch's items, the job's thread included: the cores
  ## but one (the UI thread's), 1 to `MaxItemThreads`. The pool has one worker
  ## fewer.
  clamp(countProcessors() - 1, 1, MaxItemThreads)

proc hasCaseBranch(n: NimNode): bool =
  ## Whether the record list `n` holds a `case` anywhere.
  if n.kind == nnkRecCase: return true
  for c in n:
    if hasCaseBranch(c): return true

proc isVariantType(t: NimNode): bool =
  ## Whether `t` is an object type with a `case` part (a variant object), or an
  ## object that inherits from one: its parent's fields are part of it too.
  var n = getTypeImpl(t)
  if n.kind == nnkBracketExpr and n.len == 2: n = getTypeImpl(n[1]) # typedesc[T]
  if n.kind != nnkObjectTy: return false
  if hasCaseBranch(n[2]): return true
  n[1].kind == nnkOfInherit and isVariantType(n[1][0])

macro isVariantObject(T: typedesc): bool =
  ## Whether `T` is a variant object, see `isVariantType`.
  result = newLit(isVariantType(T))

func plainData*(T: typedesc): bool =
  ## Whether values of `T` can be handed from one thread to another by move: no
  ## `ref`, `ptr`, `pointer`, `cstring` or `proc` anywhere inside it (objects,
  ## tuples, arrays, seqs, sets, strings, numbers, enums and distinct types are
  ## looked into). A variant object (`case`) is refused outright: its other
  ## branches cannot be looked into, so none is vouched for.
  when T is (ref | ptr | pointer | cstring | proc):
    false
  elif T is (string | SomeNumber | bool | char | enum | set):
    true
  elif T is distinct:
    plainData(distinctBase(T))
  elif T is array:
    plainData(typeof(default(T)[low(T)])) # (indexed by an enum or from other than 0 too)
  elif T is (seq | openArray):
    plainData(typeof(default(T)[0]))
  elif T is object and isVariantObject(T):
    false
  elif T is (object | tuple):
    var all = true
    for f in fields(default(T)):
      if not plainData(typeof(f)): all = false
    all
  else:
    false

type
  ItemContext* = object
    ## What an item uses: whether to stop and how far it is. Valid while the
    ## item runs, on whichever thread runs it.
    b: ptr BatchHead
    index*: int ## the item's number, `0 ..< n`
    onCaller: bool ## it runs on the batch's own thread

  ItemFailure* = object
    ## An exception that escaped `work`, as text: the exception object stays on
    ## the thread that made it.
    name*, msg*: string
    cancelled*: bool ## `JobCancelledError` or `SegCancelledError`

  ItemOutcome*[R] = object
    ## What item `i` came to.
    case ok*: bool
    of true: value*: R
    of false: failure*: ItemFailure

  ItemWork*[A, R] = proc (it: ItemContext; args: ptr A; i: int): R {.nimcall, gcsafe.}
    ## Runs item `i`, on any thread.

  ItemTake*[R] = proc (i: int; outcome: sink ItemOutcome[R]) {.closure, gcsafe.}
    ## Takes item `i`'s outcome, on the batch's own thread, items in order.

  ItemOptions* = object
    ## How a batch is limited. All the limits keep the memory of a batch
    ## independent of the number of items.
    maxInFlight*: int = 0 ## items running at once; 0: the pool's threads
    window*: int = 0
      ## items running or finished and not yet taken; 0: twice `maxInFlight`
    cost*: seq[int64] ## per item (the file's size, say); empty: none
    budget*: int64 = 0
      ## the most cost running at once; 0: none. The next item to take may
      ## always run.
    scale*: int64 = 1000 ## progress units per item

  ItemsRun* = object
    ## How a batch ended.
    taken*: int    ## items `0 ..< taken` went to `take`, in order
    stopped*: bool ## a cancel: the items from `taken` on were not taken
    threads*: int  ## threads that ran at least one item

  ItemHooks* = object
    ## The batch's owner: what to ask, from any thread and never under the pool
    ## lock. Both may be nil (never cancelled; no report).
    data*: pointer
    cancelled*: proc (data: pointer): bool {.nimcall, gcsafe, raises: [].}
    report*: proc (data: pointer; done, total: int64): bool {.nimcall, gcsafe, raises: [].}
      ## false once cancelled

  RunProc = proc (h: ptr BatchHead; i, who: int) {.nimcall, gcsafe.}

  BatchHead = object
    ## One batch, on its caller's stack; under the pool's lock apart from the
    ## atomics and the immutable fields.
    owner: ptr ItemPoolObj
    n, window, maxInFlight: int
    scale, budget: int64
    cost: seq[int64]
    next, taken, inFlight, placed: int
      ## next: the next item to hand out; taken: the next to take; placed:
      ## items finished, taken or not
    costInFlight: int64
    stop: Atomic[int] ## 0 none, 1 cancel, 2 `take` raised, 3 ending; set under the lock
    ready: Cond ## an item was placed, a stop was set, or progress moved
    full: seq[bool] ## per slot: an outcome is placed
    fracs: ptr UncheckedArray[Atomic[int64]] ## per slot: how far the running item is
    lastWake: Atomic[int64]
    shown, lastReport: int64 ## the last progress reported and when: the caller's thread only
    ran: Atomic[uint32] ## the threads that ran an item, one bit each
    run: RunProc
    data: pointer
    hooks: ItemHooks

  BatchData[A, R] = object
    args: ptr A
    work: ItemWork[A, R]
    slots: seq[ItemOutcome[R]] ## slot `i mod window` belongs to item `i` from its hand-out to its take

  WorkerObj = object
    ## A pool worker, in shared memory of its own.
    thread: Thread[WorkerArg]
    index: int
    ended: bool ## under the pool's lock

  WorkerArg = object
    pool: ptr ItemPoolObj
    me: ptr WorkerObj

  ItemPoolObj = object
    lock: Lock
    work: Cond ## an item may be startable, the size changed, or the pool is stopping
    batches: seq[ptr BatchHead]                       ## registered, oldest first
    workers: array[MaxItemThreads - 1, ptr WorkerObj] ## started and not yet joined
    size: int                                         ## threads per batch, the caller's included
    stopping: bool

  ItemPool* = ptr ItemPoolObj
    ## The shared pool. Make it with `newItemPool`, end it with `shutdownItemPool`
    ## and free it with `closeItemPool`.

# --------------------------------------------------- shared state, lock held --

func startable(b: ptr BatchHead): bool =
  ## Whether the next item may be handed out now.
  b.stop.load(moRelaxed) == 0 and b.next < b.n and b.next < b.taken + b.window and
    b.inFlight < b.maxInFlight and
    (b.cost.len == 0 or b.budget <= 0 or b.next == b.taken or
      b.costInFlight + b.cost[b.next] <= b.budget)

proc handOut(b: ptr BatchHead): int =
  ## Reserves the next item for the caller of this proc.
  result = b.next
  b.fracs[result mod b.window].store(0, moRelaxed) # the slot's old fraction is not the item's
  inc b.next
  inc b.inFlight
  if b.cost.len > 0: b.costInFlight += b.cost[result]

proc place(b: ptr BatchHead; i: int) =
  ## Item `i` came back and its outcome is in its slot.
  b.full[i mod b.window] = true
  dec b.inFlight
  inc b.placed
  if b.cost.len > 0: b.costInFlight -= b.cost[i]

proc setStop(b: ptr BatchHead; why: int) =
  ## Ends the batch for everyone: the first reason wins. Wakes every waiter.
  if b.stop.load(moRelaxed) == 0:
    b.stop.store(why, moRelease)
  broadcast b.owner.work
  broadcast b.ready

proc firstStartable(p: ItemPool): ptr BatchHead =
  for b in p.batches:
    if startable(b): return b
  nil

proc progressValue(b: ptr BatchHead): int64 =
  ## The batch's progress in `scale` units per item: the finished items whole,
  ## and the mean of the running ones' own fractions, below one item.
  var sum, running = 0'i64
  for i in b.taken ..< b.next:
    let s = i mod b.window
    if not b.full[s]:
      sum += b.fracs[s].load(moRelaxed)
      inc running
  result = int64(b.placed) * b.scale + min(b.scale - 1, sum div max(1'i64, running))

# ------------------------------------------------------------------- workers --

proc workerMain(arg: WorkerArg) {.thread.}

proc startWorkers(p: ItemPool) =
  ## Starts the workers a batch lacks; lock held. Not once the pool is
  ## stopping. A thread that cannot be made leaves the batch with fewer.
  if p.stopping: return
  for k in 0 ..< p.size - 1:
    if p.workers[k] == nil:
      let w = cast[ptr WorkerObj](allocShared0(sizeof(WorkerObj)))
      w.index = k
      try:
        createThread(w.thread, workerMain, WorkerArg(pool: p, me: w))
      except ResourceExhaustedError:
        deallocShared(w)
        return
      p.workers[k] = w

proc reapWorkers(p: ItemPool) =
  ## Joins the workers that left (the size shrank, or the pool stopped).
  var gone: seq[ptr WorkerObj]
  withLock p.lock:
    for k in 0 ..< p.workers.len:
      let w = p.workers[k]
      if w != nil and w.ended:
        gone.add w
        p.workers[k] = nil
  for w in gone:
    joinThread(w.thread)
    deallocShared(w)

proc workerMain(arg: WorkerArg) {.thread.} =
  markWorkerThread()
  markItemThread(true) # a batch started from an item is a Defect
  let p = arg.pool
  let me = arg.me
  acquire p.lock
  while not p.stopping and me.index < p.size - 1:
    let b = p.firstStartable()
    if b == nil:
      wait(p.work, p.lock)
    else:
      let i = b.handOut()
      release p.lock
      b.run(b, i, me.index + 1) # places nothing: the outcome is in its slot
      let seen = b.hooks.cancelled != nil and b.hooks.cancelled(b.hooks.data)
      acquire p.lock
      b.place(i)
      if seen: b.setStop(1)
      broadcast b.ready # b is not touched after the lock is released
  release p.lock
  clearCycleRoots()
  withLock p.lock:
    me.ended = true

# ---------------------------------------------------------------------- pool --

proc newItemPool*(size: int): ItemPool =
  ## A pool for batches of `size` threads (the caller's included), `size`
  ## clamped to `1 .. MaxItemThreads`; no thread starts until a batch needs it.
  result = cast[ItemPool](createShared(ItemPoolObj))
  result.size = clamp(size, 1, MaxItemThreads)
  initLock result.lock
  initCond result.work

proc setSize*(p: ItemPool; size: int) =
  ## Threads per batch from now on, the caller's included, clamped to
  ## `1 .. MaxItemThreads`. Idle workers above it leave and are joined by the
  ## next batch; a batch running goes on with the workers it has.
  withLock p.lock:
    p.size = clamp(size, 1, MaxItemThreads)
    broadcast p.work

proc size*(p: ItemPool): int =
  ## Threads per batch, the caller's included.
  withLock p.lock:
    result = p.size

proc liveWorkers*(p: ItemPool): int =
  ## Workers that are running (started, and not yet left; a worker that left
  ## is joined by the next batch or the shutdown).
  withLock p.lock:
    for w in p.workers:
      if w != nil and not w.ended: inc result

proc unjoinedWorkers*(p: ItemPool): int =
  ## Workers started and not yet joined, those that left included.
  withLock p.lock:
    for w in p.workers:
      if w != nil: inc result

proc shutdownItemPool*(p: ItemPool; deadline: MonoTime): bool =
  ## From now on no worker starts and the workers leave once idle; waits for
  ## them until `deadline` and joins those that ended. True when none is left
  ## (then `closeItemPool` may free the pool). Idempotent. A batch still
  ## running afterwards runs on its caller alone.
  withLock p.lock:
    p.stopping = true
    broadcast p.work
  while true:
    var all = true
    withLock p.lock:
      for w in p.workers:
        if w != nil and not w.ended: all = false
    if all or getMonoTime() >= deadline: break
    sleep 1
  reapWorkers(p)
  withLock p.lock:
    result = true
    for w in p.workers:
      if w != nil: result = false

proc closeItemPool*(p: ItemPool) =
  ## Frees the pool. Call it once, after `shutdownItemPool` returned true and
  ## no batch is running.
  if p == nil: return
  deinitCond p.work
  deinitLock p.lock
  p.batches = @[]
  deallocShared(p)

# ---------------------------------------------------------------------- item --

proc cancelled*(it: ItemContext): bool {.raises: [].} =
  ## Whether the batch stopped, or its owner was cancelled. Takes the owner's
  ## lock (never the pool's): ask per chunk of work, not per sample.
  let h = it.b
  result = h.stop.load(moAcquire) != 0 or
    (h.hooks.cancelled != nil and h.hooks.cancelled(h.hooks.data))

proc checkCancelled*(it: ItemContext) =
  ## Raises `JobCancelledError` once `cancelled`.
  if it.cancelled:
    raise newException(JobCancelledError, "cancelled")

proc reportDue(h: ptr BatchHead): bool =
  ## The caller's thread only: whether a throttled report is due.
  h.hooks.report != nil and (h.lastReport == 0 or
    getMonoTime().ticks - h.lastReport >= ProgressEvery.inNanoseconds)

proc reportNow(h: ptr BatchHead) =
  ## The caller's thread only, no lock held: tells the owner how far the batch is
  ## when that is further than it was told, and stops the batch if it answers false.
  var v: int64
  withLock h.owner.lock:
    v = progressValue(h)
  if v > h.shown:
    h.shown = v
    h.lastReport = getMonoTime().ticks
    if not h.hooks.report(h.hooks.data, v, int64(h.n) * h.scale):
      withLock h.owner.lock:
        setStop(h, 1)

proc progress*(it: ItemContext; done, total: int64): bool {.raises: [].} =
  ## Reports the item's own fraction, `done` of `total` units; false once
  ## `cancelled`. The batch's progress follows, at most every 100 ms: an item
  ## on the batch's own thread tells the owner itself (so a long item there
  ## keeps the job's beat), one on a worker wakes the batch's thread to do it.
  let h = it.b
  let s = it.index mod h.window
  h.fracs[s].store(
    if total > 0: clamp(done, 0, total) * h.scale div total else: 0, moRelaxed)
  let now = getMonoTime().ticks
  var last = h.lastWake.load(moRelaxed)
  if now - last >= ProgressEvery.inNanoseconds and
      h.lastWake.compareExchange(last, now, moRelaxed):
    withLock h.owner.lock:
      broadcast h.ready
  if it.onCaller and h.reportDue: h.reportNow
  result = not it.cancelled

proc runItem[A, R](h: ptr BatchHead; i, who: int) {.nimcall.} =
  ## Runs item `i` and leaves its outcome in its slot, unlocked: the slot is the
  ## item's alone from its hand-out until the caller takes it.
  let d = cast[ptr BatchData[A, R]](h.data)
  discard h.ran.fetchOr(1'u32 shl who, moRelaxed)
  try:
    d.slots[i mod h.window] =
      ItemOutcome[R](ok: true, value: d.work(ItemContext(b: h, index: i, onCaller: who == 0),
          d.args, i))
  except CatchableError as e:
    d.slots[i mod h.window] = ItemOutcome[R](ok: false, failure: ItemFailure(
      name: $e.name, msg: e.msg,
      cancelled: e of JobCancelledError or e of SegCancelledError))
  clearCycleRoots() # what the outcome holds changes threads now

# --------------------------------------------------------------------- batch --

proc runBatch*[A, R](pool: ItemPool; hooks: ItemHooks; n: int; args: ptr A;
    work: ItemWork[A, R]; take: ItemTake[R]; opts = ItemOptions()): ItemsRun =
  ## Runs items `0 ..< n` on the calling thread and the pool's workers and
  ## hands their outcomes to `take`, in order, on the calling thread. Returns
  ## once every item handed out has come back. A `take` that raises ends the
  ## batch, and its exception is raised after that. `hooks.cancelled` is asked
  ## between items. `hooks.report` is told how far the batch is, in `scale`
  ## units per item of `n * scale`: the items finished whole, plus the mean of
  ## the running items' own fractions, below one item (`ItemContext.progress`).
  ## It is called on the calling thread only, never decreasing, when the
  ## calling thread has nothing to take or run and waits, and, at most every
  ## 100 ms, after each `take`, after each item the calling thread ran and from
  ## an item's `progress` on the calling thread, so that a job's beat goes on
  ## while its own thread runs a long item. A cancel (a `false` answer too)
  ## stops the batch (`stopped`).
  static:
    doAssert plainData(R), "an item's result must be plain data: no ref, ptr, pointer, proc or variant object"
  doAssert not inItemThread(), "a batch cannot be started from an item"
  if n <= 0: return
  reapWorkers(pool)
  var data = BatchData[A, R](args: args, work: work)
  var head = BatchHead(owner: pool, n: n, scale: max(1'i64, opts.scale),
    budget: opts.budget, cost: opts.cost, run: runItem[A, R], data: addr data,
    hooks: hooks)
  let hp = addr head
  doAssert opts.cost.len in [0, n], "`cost` is empty or has one entry per item"
  var pending: ref CatchableError = nil
  var locked = false
  initCond head.ready
  acquire pool.lock
  locked = true
  head.maxInFlight = max(1, if opts.maxInFlight > 0: opts.maxInFlight else: pool.size)
  head.window = max(1, if opts.window > 0: opts.window else: 2 * head.maxInFlight)
  data.slots = newSeq[ItemOutcome[R]](head.window)
  head.full = newSeq[bool](head.window)
  head.fracs = cast[ptr UncheckedArray[Atomic[int64]]](
    createShared(Atomic[int64], head.window))
  for s in 0 ..< head.window: head.fracs[s].store(0)
  pool.batches.add hp
  pool.startWorkers()
  broadcast pool.work
  try:
    while head.stop.load(moRelaxed) == 0 and head.taken < head.n:
      let s = head.taken mod head.window
      if head.full[s]:
        let i = head.taken
        var outcome = move data.slots[s]
        head.full[s] = false
        inc head.taken
        broadcast pool.work # the window moved: a worker may start an item
        release pool.lock
        locked = false
        if hooks.cancelled != nil and hooks.cancelled(hooks.data):
          acquire pool.lock
          locked = true
          hp.setStop(1)
        else:
          try:
            result.taken = i + 1
            take(i, move outcome)
          except CatchableError as e:
            pending = e
          acquire pool.lock
          locked = true
          if pending != nil: hp.setStop(2)
          elif hp.reportDue:
            release pool.lock
            locked = false
            hp.reportNow
            acquire pool.lock
            locked = true
      elif startable(hp):
        let i = hp.handOut()
        release pool.lock
        locked = false
        markItemThread(true)
        try:
          head.run(hp, i, 0)
        finally:
          markItemThread(false)
          acquire pool.lock # also when an item raised a Defect: the drain needs it placed
          locked = true
          hp.place(i)
        if hp.reportDue:
          release pool.lock
          locked = false
          hp.reportNow
          acquire pool.lock
          locked = true
      else:
        if hooks.report != nil and hp.progressValue() > head.shown:
          release pool.lock
          locked = false
          hp.reportNow
          acquire pool.lock
          locked = true
        else:
          wait(head.ready, pool.lock)
    result.stopped = head.stop.load(moRelaxed) == 1
  finally:
    if not locked: acquire pool.lock
    if head.stop.load(moRelaxed) == 0: head.stop.store(3, moRelease)
    broadcast pool.work
    while head.inFlight > 0:
      wait(head.ready, pool.lock)
    let at = pool.batches.find(hp)
    if at >= 0: pool.batches.delete(at)
    release pool.lock
    deinitCond head.ready
    deallocShared(head.fracs)
  result.threads = popcount(head.ran.load(moRelaxed))
  if pending != nil: raise pending
