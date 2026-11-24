## The ordered hand-over between producer threads and one writer
## (`core/cutpipe`): the writer sees records 0 ..< N once each in order
## whatever the producers' speed; the ring never holds more than its slots;
## the case that hangs when a freed slot wakes only one waiter (three
## producers, chunks of one, one slot); a producer's stop, the writer's stop
## and a cancel each end every thread, and the first stop's reason is kept.
## A watchdog fails the run after 10 s instead of hanging.
##
## Seen to fail, then restored:
## - `broadcast p.slotFree` in `written` replaced by `signal`: the watchdog
##   ends the run (`threads did not end within 10 s: W=2 C=2 Q=2`)
## - `broadcast p.slotFree` in `stopWith` removed: the watchdog ends the
##   cancel that arrives while producers wait for a slot
## - the room check `i >= p.written + p.ring` replaced by "ring holds `ring`
##   records": `record placed twice` (a later record fills the slot an earlier
##   one needs)

import std/[atomics, monotimes, os, random, times]
import viewSEG/core/cutpipe

type
  Payload = seq[int]
  Pipe = CutPipe[Payload]

  Role = enum
    rkNone
    rkProducerStops ## a producer calls `stopWith` instead of placing record `at`
    rkWriterStops   ## the writer stops after writing record `at`

  Args = object
    pipe: Pipe
    id: int
    seed: int64
    maxDelayUs: int     ## producers: a random sleep up to this before each record
    writerDelayUs: int  ## the writer's sleep per record
    role: Role
    at: int
    ended: ptr Atomic[int]
    order: ptr seq[int] ## the writer's record order
    broken: ptr Atomic[int]

proc nap(r: var Rand; maxUs: int) =
  if maxUs > 0:
    let us = r.rand(maxUs)
    if us > 0: sleep((us + 999) div 1000)

proc producer(a: Args) {.thread.} =
  var r = initRand(a.seed + a.id)
  var first, last = 0
  var item: Payload = @[]
  while a.pipe.takeChunk(first, last):
    for i in first ..< last:
      nap(r, a.maxDelayUs)
      if a.role == rkProducerStops and i == a.at:
        a.pipe.stopWith(skProducer, "producer " & $a.id & " failed at " & $i)
        break
      item = @[i]
      if not a.pipe.place(i, item): break
      # the buffer given back is the slot's old one: empty or a taken record
      if item.len > 1: a.broken[].store(1)
  discard a.ended[].fetchAdd(1)

proc writer(a: Args) {.thread.} =
  var item: Payload = @[]
  var r = initRand(a.seed - 1)
  while true:
    let t = a.pipe.takeNext(item)
    if t != tkRecord: break
    nap(r, a.writerDelayUs)
    a.order[].add(if item.len == 1: item[0] else: -1)
    a.pipe.written()
    if a.role == rkWriterStops and a.order[].len - 1 == a.at:
      a.pipe.stopWith(skWriter, "write failed at " & $a.at)
      break
  discard a.ended[].fetchAdd(1)

proc waitAll(ended: var Atomic[int]; count: int; what: string) =
  ## The watchdog: every thread ended within 10 s, or the test fails.
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while ended.load() < count:
    if getMonoTime() > deadline:
      echo "tcutpipe: threads did not end within 10 s: ", what, " (",
        ended.load(), " of ", count, ")"
      quit 1
    sleep 1

type Run = object
  order: seq[int]
  kind: StopKind
  message: string
  peak, written: int

proc run(what: string; workers, records, chunk, ring: int; seed: int64;
    maxDelayUs = 0; writerDelayUs = 0; role = rkNone; at = 0;
    cancelAfterMs = -1): Run =
  var ended: Atomic[int]
  var broken: Atomic[int]
  ended.store(0)
  broken.store(0)
  var order: seq[int] = @[]
  let pipe = newCutPipe[Payload](records, ring, chunk)
  var base = Args(pipe: pipe, seed: seed, maxDelayUs: maxDelayUs,
    writerDelayUs: writerDelayUs, role: role, at: at, ended: addr ended,
    order: addr order, broken: addr broken)
  var threads = newSeq[Thread[Args]](workers + 1)
  for w in 0 ..< workers:
    var a = base
    a.id = w + 1
    createThread(threads[w], producer, a)
  createThread(threads[workers], writer, base)
  if cancelAfterMs >= 0:
    sleep cancelAfterMs
    pipe.stopWith(skCancel, "cancelled")
  waitAll(ended, workers + 1, what)
  joinThreads(threads)
  doAssert broken.load() == 0, what & ": a placed record came back in a buffer"
  result = Run(order: order, kind: pipe.stopped(), message: pipe.stopMessage(),
    peak: pipe.ringPeak(), written: pipe.writtenCount())
  doAssert result.peak <= max(1, ring),
    what & ": the ring held " & $result.peak & " of " & $ring
  pipe.close()

proc inOrder(res: Run; records: int; what: string) =
  doAssert res.kind == skNone, what & ": stopped"
  doAssert res.order.len == records, what & ": wrote " & $res.order.len
  for i, v in res.order:
    doAssert v == i, what & ": position " & $i & " got record " & $v
  doAssert res.written == records

proc main*() =
  # in order, once each, for many shapes and speeds (fixed seeds)
  var n = 0
  for (w, c, q) in [(1, 1, 1), (2, 2, 2), (3, 1, 1), (3, 2, 3), (4, 3, 4),
      (2, 1, 5), (3, 5, 2)]:
    for (d, wd) in [(0, 0), (300, 0), (300, 600), (0, 800)]:
      inc n
      let what = "W=" & $w & " C=" & $c & " Q=" & $q & " d=" & $d & "/" & $wd
      let res = run(what, w, 40, c, q, int64(1000 + n), d, wd)
      inOrder(res, 40, what)
  # the case that hangs when a freed slot wakes one waiter only
  for s in 1 .. 20:
    let res = run("W=3 C=1 Q=1", 3, 30, 1, 1, int64(s), 200, 0)
    inOrder(res, 30, "W=3 C=1 Q=1 seed " & $s)
    doAssert res.peak == 1
  # no records
  inOrder(run("empty", 2, 0, 1, 1, 7), 0, "empty")

  # a producer's stop ends the writer and the other producers
  for (w, q) in [(1, 1), (3, 1), (3, 2)]:
    let res = run("producer stop", w, 20, 1, q, 5, 300, 200, rkProducerStops, 7)
    doAssert res.kind == skProducer
    doAssert res.message.len > 0 and res.message[0 .. 8] == "producer "
    doAssert res.order.len <= 7, "records past the failed one were written: " & $res.order.len
    for i, v in res.order: doAssert v == i
  # the writer's stop ends the producers waiting for a slot
  for (w, q) in [(1, 1), (3, 1), (3, 2)]:
    let res = run("writer stop", w, 20, 1, q, 6, 0, 300, rkWriterStops, 4)
    doAssert res.kind == skWriter
    doAssert res.message == "write failed at 4"
    doAssert res.order.len == 5
    for i, v in res.order: doAssert v == i
  # a cancel while the writer waits for a record, and while producers wait for a slot
  for (what, d, wd) in [("cancel, writer waits", 40_000, 0),
      ("cancel, producers wait", 0, 40_000)]:
    let res = run(what, 3, 100, 1, 1, 8, d, wd, cancelAfterMs = 25)
    doAssert res.kind == skCancel and res.message == "cancelled"
    doAssert res.order.len < 100
    for i, v in res.order: doAssert v == i
  # the first stop wins: a later stop changes nothing
  block:
    let p = newCutPipe[Payload](4, 2, 1)
    p.stopWith(skCancel, "first")
    p.stopWith(skWriter, "second")
    doAssert p.stopped() == skCancel and p.stopMessage() == "first"
    var item: Payload = @[1]
    doAssert not p.place(0, item) and item == @[1]
    doAssert p.takeNext(item) == tkStopped
    var a, b = 0
    doAssert not p.takeChunk(a, b)
    p.close()
  echo "tcutpipe: ok"

when isMainModule:
  main()
