## The pool of worker threads for the items of one job (`core/itempool`, and
## `parallelItems` of `core/jobs`): items run exactly once and their outcomes
## reach `take` strictly in order, for every number of items, threads and
## window; the results held never pass the window; an item that raises arrives
## as a failure, in its place; a `take` that raises, a cancel in long items, a
## cancel while every worker waits for the window and `Jobs.stop` each end the
## batch with no item left running; two batches share the workers; a budget
## that fits one item runs one at a time; a batch inside an item is a Defect;
## a batch allocates nothing that grows with its items; the pool shrinks, ends
## and leaves nothing unjoined. A watchdog fails the run after 10 s in any one
## step instead of hanging.
##
## Seen to fail, then restored (each by a small change in `core/itempool`; the
## models' mutants 1, 4, 5 and 7 of `docs/models/itempool.nif`):
## - the worker's `broadcast b.ready` after placing removed: the watchdog ends
##   the run (`stuck for 10 s in: order and exactly once`)
## - the hand-out as a read of `b.next` and an increment in a later lock region:
##   `n=2 threads=8 window=8: item 1 ran 2 times`
## - the drain's wait for `inFlight == 0` removed: `an item was still running`
##   (the batch returned with an item in hand)
## - `runItem` catching `KeyError` instead of `CatchableError` (an exception
##   escapes the wrapper): the worker dies and the program ends with the
##   item's `ValueError` (`bad item 3`)
## - `std/typetraits` not imported (a distinct field): `undeclared identifier:
##   'distinctBase'`
## - `if p.stopping: return` removed from `startWorkers`: `a worker was started
##   after the shutdown`
## - an item's `progress` on the batch's own thread not forwarding, and no
##   report after a take or the caller's own item: `a long item reported 1
##   times`, and `progress with 1 threads: nothing was reported`
## Not seen to fail: the hand-out (not the start) resetting an item's fraction,
## and the report only when greater: a mean that falls with no item finished
## needs a report between two hand-outs of a start-up, which no test can aim at.
## Under ThreadSanitizer (`-d:useMalloc -d:noSignalHandler --debugger:native
## --passC:-fsanitize=thread --passL:-fsanitize=thread`): no report.

import std/[atomics, monotimes, os, random, strutils, times]
import viewSEG/core/[itempool, jobs, threads]
import utils/waiting

const
  Watchdog = initDuration(seconds = 10)
  Cap = 1024

type
  Probe = object
    ## The items' arguments: counts and checks, all atomic.
    ran: array[Cap, Atomic[int]]
    running, peak, started, finished, takenDone, bad, afterEnd: Atomic[int]
    napMs: int    ## every item sleeps this long
    exact: bool   ## one thread: the progress is exactly the items finished
    window: int
    failing: bool
    napEvery: int ## every this many items one sleeps 1 ms; 0 none

var
  stageStart: Atomic[int64]
  stageName: Atomic[pointer]
  testEnded: Atomic[bool]

proc stage(name: cstring) =
  stageName.store(cast[pointer](name))
  stageStart.store(getMonoTime().ticks)

proc watchdog() {.thread.} =
  while not testEnded.load:
    sleep 50
    if getMonoTime().ticks - stageStart.load > Watchdog.inNanoseconds:
      echo "titempool: stuck for 10 s in: ", cast[cstring](stageName.load)
      quit 1

proc raiseMax(a: var Atomic[int]; v: int) =
  var old = a.load
  while v > old and not a.compareExchange(old, v): discard

proc work(it: ItemContext; a: ptr Probe; i: int): int {.nimcall, gcsafe.} =
  discard a.ran[i mod Cap].fetchAdd(1)
  raiseMax(a.peak, a.running.fetchAdd(1) + 1)
  # the window: an item starts only fewer than `window` beyond the next to take
  # (the take in hand counts as taken: one more)
  if i - a.takenDone.load > a.window: a.bad.store(1)
  discard a.started.fetchAdd(1)
  if a.napMs > 0: sleep a.napMs
  if a.napEvery > 0 and i mod a.napEvery == a.napEvery - 1: sleep 1
  if a.failing:
    if i mod 7 == 3: raise newException(ValueError, "bad item " & $i)
    if i mod 11 == 5: it.checkCancelled() # not cancelled: a no-op
    if i mod 11 == 6: raise newException(JobCancelledError, "cancelled item " & $i)
  discard a.running.fetchAdd(-1)
  discard a.finished.fetchAdd(1)
  i * 3 + 1

type Seen = object
  order: seq[int]
  failures: seq[ItemFailure]
  values: seq[int]

proc newHooks(flag: ptr Atomic[bool]): ItemHooks =
  ItemHooks(data: flag, cancelled: proc (d: pointer): bool {.nimcall, gcsafe, raises: [].} =
    cast[ptr Atomic[bool]](d)[].load)

proc runPlain(pool: ItemPool; p: var Probe; seen: var Seen; n: int;
    opts = ItemOptions(); hooks = ItemHooks()): ItemsRun =
  ## Runs `n` items of `work`; `seen` gets what `take` was given.
  let sp = addr seen
  let pp = addr p
  let take = proc (i: int; outcome: sink ItemOutcome[int]) {.gcsafe.} =
    sp.order.add i
    if outcome.ok: sp.values.add outcome.value
    else: sp.failures.add outcome.failure
    discard pp.takenDone.fetchAdd(1)
  runBatch[Probe, int](pool, hooks, n, pp, work, take, opts)

proc idle(p: var Probe) =
  ## Fails when an item still runs.
  doAssert p.running.load == 0, "an item was still running"

proc inOrder(seen: Seen; n: int; what: string) =
  doAssert seen.order.len == n, what & ": " & $seen.order.len & " items taken"
  for i, v in seen.order:
    doAssert v == i, what & ": position " & $i & " took item " & $v

proc exactlyOnce(p: var Probe; n: int; what: string) =
  for i in 0 ..< n:
    doAssert p.ran[i].load == 1, what & ": item " & $i & " ran " & $p.ran[i].load & " times"

proc ranPast(p: var Probe; n: int): int =
  for i in 0 ..< n: result += p.ran[i].load

proc nested(it: ItemContext; a: ptr Probe; i: int): int {.nimcall, gcsafe.} =
  ## An item that starts a batch of its own.
  var inner: Probe
  var seen: Seen
  let pool: ItemPool = nil # the Defect comes before the pool is looked at
  discard runPlain(pool, inner, seen, 2)
  i

proc plainDataChecks() =
  type
    Row = object
      name: string
      cells: seq[array[3, float32]]
      tag: (int, bool)
    Node = ref object
      next: Node
    Bad = object
      node: Node
    Callback = object
      f: proc ()
    Holder = object
      p: ptr int
    Id = distinct int
    Keyed = object
      id: Id
      ids: seq[Id]
    BadId = distinct Node
    Shape = enum
      sPlain
      sRef
    Plain = object
      case kind: Shape
      of sPlain: n: int
      of sRef: s: string
    RefFirst = object
      case kind: Shape
      of sPlain: n: int
      of sRef: node: Node
    RefDefault = object
      case kind: Shape
      of sPlain: node: Node
      of sRef: n: int
    Nested = object
      inner: seq[RefFirst]
    PdBase = object of RootObj
      case k: bool
      of true: r: ref int
      of false: n: int
    PdSub = object of PdBase
      extra: int
  static:
    doAssert plainData(int) and plainData(string) and plainData(seq[string])
    doAssert plainData(Row) and plainData(seq[Row]) and plainData(ItemFailure)
    doAssert not plainData(Node) and not plainData(Bad) and not plainData(seq[Bad])
    doAssert not plainData(Callback) and not plainData(Holder) and not plainData(pointer)
    # a distinct type is looked through (a `JobId` field is a plain integer)
    doAssert plainData(Id) and plainData(Keyed) and plainData(seq[Keyed])
    doAssert not plainData(BadId)
    # a variant object is refused whichever branch holds the ref, even the one that
    # holds none of it, and so is what holds one
    doAssert not plainData(Plain) and not plainData(RefFirst) and not plainData(RefDefault)
    doAssert not plainData(Nested)
    # an object whose parent is a variant object is refused too
    doAssert not plainData(PdSub), "an object of a variant parent passed"
  # a result type with a ref is refused at compile time
  var pool: ItemPool
  var p: Probe
  doAssert not compiles(runBatch[Probe, Node](pool, ItemHooks(), 1, addr p,
    proc (it: ItemContext; a: ptr Probe; i: int): Node {.nimcall, gcsafe.} = nil,
    proc (i: int; o: sink ItemOutcome[Node]) {.gcsafe.} = discard))
  # nor a variant object, whatever its branches hold
  doAssert not compiles(runBatch[Probe, RefFirst](pool, ItemHooks(), 1, addr p,
    proc (it: ItemContext; a: ptr Probe; i: int): RefFirst {.nimcall, gcsafe.} = RefFirst(),
    proc (i: int; o: sink ItemOutcome[RefFirst]) {.gcsafe.} = discard))
  doAssert not compiles(runBatch[Probe, Plain](pool, ItemHooks(), 1, addr p,
    proc (it: ItemContext; a: ptr Probe; i: int): Plain {.nimcall, gcsafe.} = Plain(),
    proc (i: int; o: sink ItemOutcome[Plain]) {.gcsafe.} = discard))
  # and a distinct integer is accepted
  doAssert compiles(runBatch[Probe, Keyed](pool, ItemHooks(), 1, addr p,
    proc (it: ItemContext; a: ptr Probe; i: int): Keyed {.nimcall, gcsafe.} = Keyed(),
    proc (i: int; o: sink ItemOutcome[Keyed]) {.gcsafe.} = discard))

proc matrix() =
  # order and exactly once, for every shape and speed
  var r = initRand(2024)
  for n in [0, 1, 2, 17, 1000]:
    for threads in [1, 2, 4, 8]:
      for window in [1, 2, 8]:
        let what = "n=" & $n & " threads=" & $threads & " window=" & $window
        stage("order and exactly once")
        let pool = newItemPool(threads)
        var p: Probe
        var seen: Seen
        p.window = window
        p.napEvery = if n >= 1000: 97 else: r.rand(1 .. 4)
        let run = runPlain(pool, p, seen, n, ItemOptions(window: window,
          maxInFlight: min(window, threads)))
        inOrder(seen, n, what)
        exactlyOnce(p, n, what)
        idle(p)
        doAssert seen.failures.len == 0 and seen.values.len == n
        for i, v in seen.values: doAssert v == i * 3 + 1
        doAssert run.taken == n and not run.stopped, what
        doAssert run.threads in (if n == 0: 0 else: 1) .. threads, what & ": threads " & $run.threads
        doAssert p.bad.load == 0, what & ": an item started beyond the window"
        doAssert p.peak.load <= min(window, threads), what & ": " & $p.peak.load & " ran at once"
        doAssert pool.liveWorkers <= threads - 1
        doAssert shutdownItemPool(pool, getMonoTime() + Watchdog)
        doAssert pool.liveWorkers == 0
        closeItemPool(pool)

proc serialMode() =
  # one thread: no worker ever starts, the batch runs on the caller
  stage("serial")
  let pool = newItemPool(1)
  var p: Probe
  var seen: Seen
  p.window = 2
  let run = runPlain(pool, p, seen, 50, ItemOptions(window: 2))
  inOrder(seen, 50, "serial")
  doAssert run.threads == 1 and pool.liveWorkers == 0
  doAssert shutdownItemPool(pool, getMonoTime() + Watchdog)
  closeItemPool(pool)

proc failures() =
  # items that raise arrive in order as failures
  stage("failures")
  for threads in [1, 3]:
    let pool = newItemPool(threads)
    var p: Probe
    var seen: Seen
    p.window = 4
    p.failing = true
    p.napEvery = 3
    let n = 40
    discard runPlain(pool, p, seen, n, ItemOptions(window: 4))
    inOrder(seen, n, "failures")
    exactlyOnce(p, n, "failures")
    var expected: seq[(int, string, bool)]
    for i in 0 ..< n:
      if i mod 7 == 3: expected.add (i, "bad item " & $i, false)
      elif i mod 11 == 6: expected.add (i, "cancelled item " & $i, true)
    doAssert seen.failures.len == expected.len, "failures: " & $seen.failures.len
    for k, f in seen.failures:
      doAssert f.msg == expected[k][1], "failure " & $k & ": " & f.msg
      doAssert f.cancelled == expected[k][2]
      doAssert f.name == (if f.cancelled: "JobCancelledError" else: "ValueError")
    doAssert seen.values.len == n - expected.len
    doAssert shutdownItemPool(pool, getMonoTime() + Watchdog)
    closeItemPool(pool)

proc takeRaises() =
  # a `take` that raises ends the batch after the drain: nothing runs afterwards
  stage("take raises")
  for threads in [1, 4]:
    let pool = newItemPool(threads)
    var p: Probe
    p.window = 3
    p.napEvery = 2
    let pp = addr p
    var raised = false
    var took = 0
    try:
      let take = proc (i: int; outcome: sink ItemOutcome[int]) {.gcsafe.} =
        discard pp.takenDone.fetchAdd(1)
        if i == 5: raise newException(IOError, "take failed at 5")
      discard runBatch[Probe, int](pool, ItemHooks(), 100, pp, work, take)
    except IOError as e:
      raised = e.msg == "take failed at 5"
    doAssert raised, "the exception of `take` did not come out"
    idle(p) # the drain waited for every item handed out
    let after = ranPast(p, Cap)
    sleep 60
    doAssert ranPast(p, Cap) == after, "an item ran after the batch returned"
    doAssert after < 100, "every item ran although the take failed"
    doAssert p.takenDone.load == 6
    doAssert shutdownItemPool(pool, getMonoTime() + Watchdog)
    closeItemPool(pool)

proc cancelling() =
  # a cancel in long items, and while every worker waits for the window
  stage("cancel in long items")
  let pool = newItemPool(4)
  block longItems:
    var flag: Atomic[bool]
    flag.store(false)
    var p: Probe
    var seen: Seen
    p.window = 8
    p.napEvery = 1
    let t0 = getMonoTime()
    var canceller: Thread[ptr Atomic[bool]]
    createThread(canceller, proc (f: ptr Atomic[bool]) {.thread.} =
      sleep 30
      f[].store(true), addr flag)
    let run = runPlain(pool, p, seen, 100_000, hooks = newHooks(addr flag))
    joinThread(canceller)
    doAssert run.stopped and run.taken < 100_000
    doAssert getMonoTime() - t0 < initDuration(seconds = 5)
    doAssert seen.order.len == run.taken
    for i, v in seen.order: doAssert v == i
    idle(p)
  stage("cancel while the workers wait")
  block waiting:
    # window 1: the workers wait for `take`, which is slow; the cancel comes meanwhile
    var flag: Atomic[bool]
    flag.store(false)
    var p: Probe
    p.window = 1
    let pp = addr p
    var order: seq[int]
    let op = addr order
    let fp = addr flag
    let take = proc (i: int; outcome: sink ItemOutcome[int]) {.gcsafe.} =
      op[].add i
      discard pp.takenDone.fetchAdd(1)
      if i == 2:
        fp[].store(true)
        sleep 20
    let run = runBatch[Probe, int](pool, newHooks(fp), 1000, pp, work, take,
      ItemOptions(window: 1, maxInFlight: 4))
    doAssert run.stopped and run.taken in 3 .. 4, "taken " & $run.taken
    doAssert order.len == run.taken
    idle(p)
  doAssert shutdownItemPool(pool, getMonoTime() + Watchdog)
  closeItemPool(pool)

proc twoBatches() =
  # two lanes' batches at once share the workers; each is whole and in order
  stage("two batches")
  let pool = newItemPool(4)
  type Job = object
    pool: ItemPool
    n: int
    p: ptr Probe
    seen: ptr Seen
    ok: Atomic[bool]
  var pa, pb: Probe
  var sa, sb: Seen
  pa.window = 4
  pb.window = 3
  pa.napEvery = 2
  pb.napEvery = 3
  var ja = Job(pool: pool, n: 300, p: addr pa, seen: addr sa)
  var jb = Job(pool: pool, n: 200, p: addr pb, seen: addr sb)
  proc body(j: ptr Job) {.thread.} =
    let w = if j.n == 300: 4 else: 3
    discard runPlain(j.pool, j.p[], j.seen[], j.n, ItemOptions(window: w))
    clearCycleRoots() # a thread of ours ends: the list of cycle roots goes first
    j.ok.store(true)
  var ta, tb: Thread[ptr Job]
  createThread(ta, body, addr ja)
  createThread(tb, body, addr jb)
  joinThread(ta)
  joinThread(tb)
  doAssert ja.ok.load and jb.ok.load
  inOrder(sa, 300, "batch a")
  inOrder(sb, 200, "batch b")
  exactlyOnce(pa, 300, "batch a")
  exactlyOnce(pb, 200, "batch b")
  doAssert pa.bad.load == 0 and pb.bad.load == 0
  doAssert shutdownItemPool(pool, getMonoTime() + Watchdog)
  closeItemPool(pool)

proc budget() =
  # a budget below every item's cost runs one item at a time, and still finishes
  stage("budget")
  let pool = newItemPool(8)
  var p: Probe
  var seen: Seen
  p.window = 8
  p.napEvery = 1
  var cost = newSeq[int64](30)
  for c in cost.mitems: c = 100
  discard runPlain(pool, p, seen, 30, ItemOptions(window: 8, cost: cost, budget: 1))
  inOrder(seen, 30, "budget")
  doAssert p.peak.load == 1, "budget 1: " & $p.peak.load & " items ran at once"
  # a budget for two runs two
  var q: Probe
  var seen2: Seen
  q.window = 8
  q.napEvery = 1
  discard runPlain(pool, q, seen2, 30, ItemOptions(window: 8, cost: cost, budget: 250))
  inOrder(seen2, 30, "budget 250")
  doAssert q.peak.load <= 2, "budget 250: " & $q.peak.load & " items ran at once"
  doAssert shutdownItemPool(pool, getMonoTime() + Watchdog)
  closeItemPool(pool)

var reports: array[4096, Atomic[int64]]
var reportCount, reportTotal: Atomic[int]

proc recordReport(d: pointer; done, total: int64): bool {.nimcall, gcsafe, raises: [].} =
  ## The owner's report hook: keeps what it was told and checks it against the
  ## items: the items taken are finished, and the items finished by now (their
  ## `work` returned) are at least those counted whole; with one thread, exactly.
  let a = cast[ptr Probe](d)
  let k = reportCount.fetchAdd(1)
  if k < reports.len: reports[k].store(done)
  reportTotal.store(int(total))
  let whole = int(done div 1000)
  if whole < a.takenDone.load or whole > a.finished.load or
      (a.exact and whole != a.finished.load):
    a.bad.store(2)
  true

proc checkReports(n: int; what: string) =
  let k = min(reportCount.load, reports.len)
  doAssert k > 0, what & ": nothing was reported"
  var last = 0'i64
  for i in 0 ..< k:
    let v = reports[i].load
    doAssert v > last, what & ": progress went back or stood: " & $last & " then " & $v
    doAssert v <= int64(n) * 1000
    last = v
  doAssert reportTotal.load == n * 1000, what & ": the total"

proc longItem1(it: ItemContext; a: ptr Probe; i: int): int {.nimcall, gcsafe.} =
  ## An item of the batch's own thread that reports its way through.
  for step in 1 .. 40:
    sleep 10
    discard it.progress(step, 40)
  i

proc halfItem(it: ItemContext; a: ptr Probe; i: int): int {.nimcall, gcsafe.} =
  ## An item that is nearly done at once and then lingers: every item that starts
  ## pulls the mean of the running fractions down.
  discard it.progress(900, 1000)
  sleep 15
  discard a.finished.fetchAdd(1)
  i

proc progressInvariant() =
  # the batch's progress is reported from the owner's thread, never goes back,
  # is never ahead of the items finished and never behind the items taken
  for threads in [1, 2, 4]:
    stage("progress")
    let what = "progress with " & $threads & " threads"
    let pool = newItemPool(threads)
    var p: Probe
    var seen: Seen
    p.window = 4
    p.napMs = 25
    p.exact = threads == 1
    reportCount.store(0)
    let hooks = ItemHooks(data: addr p, cancelled: nil, report: recordReport)
    discard runPlain(pool, p, seen, 16, ItemOptions(window: 4), hooks)
    inOrder(seen, 16, what)
    doAssert p.bad.load == 0, what & ": a report disagreed with the items"
    checkReports(16, what)
    if threads == 1: doAssert reportCount.load >= 2, what & ": " & $reportCount.load & " reports"
    doAssert shutdownItemPool(pool, getMonoTime() + Watchdog)
    closeItemPool(pool)
  # items that are nearly done pull the mean of the running fractions down as
  # others start: what is reported still never goes back
  stage("progress of started items")
  block started:
    let pool = newItemPool(4)
    var p: Probe
    reportCount.store(0)
    let pp = addr p
    let take = proc (i: int; outcome: sink ItemOutcome[int]) {.gcsafe.} =
      discard pp.takenDone.fetchAdd(1)
    let hooks = ItemHooks(data: pp, cancelled: nil, report: recordReport)
    discard runBatch[Probe, int](pool, hooks, 40, pp, halfItem, take, ItemOptions(window: 8))
    checkReports(40, "progress of started items")
    doAssert p.bad.load == 0
    doAssert shutdownItemPool(pool, getMonoTime() + Watchdog)
    closeItemPool(pool)
  # a long item on the batch's own thread keeps the beat through its own progress
  stage("progress of a long item")
  for threads in [1, 2]:
    let pool = newItemPool(threads)
    var p: Probe
    reportCount.store(0)
    let pp = addr p
    let take = proc (i: int; outcome: sink ItemOutcome[int]) {.gcsafe.} =
      discard pp.takenDone.fetchAdd(1)
    let hooks = ItemHooks(data: pp, cancelled: nil, report: recordReport)
    discard runBatch[Probe, int](pool, hooks, 1, pp, longItem1, take, ItemOptions(window: 1))
    # 400 ms of item: a report each 100 ms, before the item came back
    doAssert reportCount.load >= 3, "a long item reported " & $reportCount.load & " times"
    doAssert shutdownItemPool(pool, getMonoTime() + Watchdog)
    closeItemPool(pool)

proc noGrowth() =
  # what a batch keeps on its own thread does not grow with its items (it makes
  # and frees transient blocks, as `clearCycleRoots` does after each item)
  stage("allocation")
  let pool = newItemPool(3)
  proc allocs(): int =
    ## Memory blocks held now: made and not yet freed on this thread.
    let st = cast[tuple[allocs, deallocs: int]](getAllocStats())
    st.allocs - st.deallocs
  proc once(n: int): int =
    var p: Probe
    p.window = 4
    let pp = addr p
    let before = allocs()
    let take = proc (i: int; outcome: sink ItemOutcome[int]) {.gcsafe.} =
      discard pp.takenDone.fetchAdd(1)
    discard runBatch[Probe, int](pool, ItemHooks(), n, pp, work, take, ItemOptions(window: 4))
    allocs() - before
  discard once(50) # the workers start
  let small = once(40)
  let large = once(4000)
  doAssert large <= small + 4, "blocks left: " & $small & " for 40 items, " & $large &
    " for 4000"
  doAssert shutdownItemPool(pool, getMonoTime() + Watchdog)
  closeItemPool(pool)

proc poolLifecycle() =
  # shrinking, then ending: workers leave, are joined, and nothing starts after
  stage("lifecycle")
  let pool = newItemPool(6)
  var p: Probe
  var seen: Seen
  p.window = 4
  discard runPlain(pool, p, seen, 100, ItemOptions(window: 4))
  doAssert pool.liveWorkers in 1 .. 5
  pool.setSize(2)
  doAssert pool.size == 2
  var q: Probe
  var seen2: Seen
  q.window = 4
  let run = runPlain(pool, q, seen2, 100, ItemOptions(window: 4))
  inOrder(seen2, 100, "after the shrink")
  doAssert run.threads <= 2, "threads after the shrink: " & $run.threads
  doAssert waitUntil(pool.liveWorkers <= 1)
  doAssert shutdownItemPool(pool, getMonoTime() + Watchdog)
  doAssert pool.liveWorkers == 0
  doAssert shutdownItemPool(pool, getMonoTime() + Watchdog) # idempotent
  # a batch after the shutdown runs on its caller alone
  var r: Probe
  var seen3: Seen
  r.window = 4
  let late = runPlain(pool, r, seen3, 20, ItemOptions(window: 4))
  inOrder(seen3, 20, "after the shutdown")
  doAssert late.threads == 1 and pool.liveWorkers == 0
  doAssert pool.unjoinedWorkers == 0, "a worker was started after the shutdown"
  closeItemPool(pool)

var
  roleSeen: Atomic[int]
  jobEnded: Atomic[bool]
  jobStopped: Atomic[bool]
  jobItems: Atomic[int]
  jobOrder: Atomic[bool]

proc roleItem(it: ItemContext; a: ptr Probe; i: int): int {.nimcall, gcsafe.} =
  # a pool worker is marked as a worker, and every item thread knows it is one
  doAssert threadRole() == trWorker
  doAssert inItemThread()
  roleSeen.store(1)
  i

proc longItem(it: ItemContext; a: ptr Probe; i: int): int {.nimcall, gcsafe.} =
  discard jobItems.fetchAdd(1)
  while not it.cancelled: sleep 1
  it.checkCancelled()
  i

proc withJobs() =
  stage("jobs: parallelItems")
  var jobs = initJobs()
  doAssert jobs.itemThreads >= 1 and jobs.itemThreads <= MaxItemThreads
  jobs.setItemThreads(3)
  doAssert jobs.itemThreads == 3
  # in order on the job's thread, the job's progress is the items taken
  roleSeen.store(0)
  jobEnded.store(false)
  jobOrder.store(false)
  let id = jobs.submit(JobSpec(title: "items", lane: jlBackground), proc (
      ctx: JobContext) {.gcsafe.} =
    var p: Probe
    var order: seq[int]
    let op = addr order
    let me = threadRole()
    let run = ctx.parallelItems(60, addr p, roleItem, proc (i: int; o: sink ItemOutcome[
        int]) {.gcsafe.} =
      doAssert threadRole() == me and not inItemThread()
      op[].add i)
    var ok = run.taken == 60 and not run.stopped
    for i, v in order: ok = ok and v == i
    jobOrder.store(ok)
    jobEnded.store(true))
  doAssert waitUntil(jobEnded.load)
  doAssert waitUntil(jobs.info(id).get.state == jsDone)
  doAssert jobOrder.load and roleSeen.load == 1
  # setItemThreads(1): the items run on the job's thread alone
  jobs.setItemThreads(1)
  doAssert jobs.itemThreads == 1
  # Jobs.stop during a batch: the items see the cancel, the batch returns, the job ends cancelled
  jobs.setItemThreads(4)
  jobItems.store(0)
  jobStopped.store(false)
  let id2 = jobs.submit(JobSpec(title: "long", lane: jlBackground), proc (
      ctx: JobContext) {.gcsafe.} =
    var p: Probe
    let run = ctx.parallelItems(1000, addr p, longItem,
      proc (i: int; o: sink ItemOutcome[int]) {.gcsafe.} = discard)
    jobStopped.store(run.stopped or run.taken < 1000)
    ctx.checkCancelled())
  doAssert waitUntil(jobItems.load >= 1)
  doAssert jobs.stop(), "stop did not wait for the batch"
  doAssert jobs.info(id2).get.state == jsCancelled
  doAssert jobStopped.load
  # a nested batch is a Defect in the program that starts it (checked below)
  jobs.stop()

proc nestedIsADefect() =
  # a batch started from an item raises a Defect in every build: here the item
  # runs on the caller (a pool of one), and the batch still ends and the pool stays usable
  stage("nested batch")
  let pool = newItemPool(1)
  var p: Probe
  var refused = ""
  try:
    discard runBatch[Probe, int](pool, ItemHooks(), 4, addr p, nested,
      proc (i: int; o: sink ItemOutcome[int]) {.gcsafe.} = discard)
  except AssertionDefect as e:
    refused = e.msg
  doAssert "a batch cannot be started from an item" in refused,
    "a batch inside an item went through: " & refused
  doAssert not inItemThread(), "the caller is still marked as running an item"
  var seen: Seen
  p.window = 2
  discard runPlain(pool, p, seen, 10, ItemOptions(window: 2))
  inOrder(seen, 10, "after the Defect")
  doAssert shutdownItemPool(pool, getMonoTime() + Watchdog)
  closeItemPool(pool)

proc main*() =
  testEnded.store(false)
  stage("start")
  var dog: Thread[void]
  createThread(dog, watchdog)
  plainDataChecks()
  matrix()
  serialMode()
  failures()
  takeRaises()
  cancelling()
  twoBatches()
  budget()
  progressInvariant()
  noGrowth()
  poolLifecycle()
  withJobs()
  nestedIsADefect()
  testEnded.store(true)
  joinThread(dog)
  echo "titempool: ok"

when isMainModule:
  main()
