## The ordered hand-over between several producer threads and one writer: the
## producers make the records `0 ..< records` in any order, the writer takes
## them strictly in order. A record's payload is any type `T`; the pipe knows
## nothing of seismic data.
##
## One lock and two condition variables guard a ring of `ring` slots addressed
## by record index (record `i` lives in slot `i mod ring`). A producer places
## record `i` only while `i < written + ring`, so the ring never holds more than
## `ring` records and the record the writer waits for is never kept out: the
## producer holding the lowest unplaced record always has room once every record
## before it is written. Payloads are swapped in and out, never copied, so each
## side gets an empty buffer back to reuse.
##
## `stopWith` ends the run for everyone: the first reason wins, and both
## condition variables are broadcast, so every waiting thread leaves. A waiting
## writer is woken by a producer's record, a waiting producer by the writer's
## `written` (a broadcast: with several waiting, only the one holding record
## `written + ring - 1` may go, and a single wake-up could go to another).
## The model is `docs/models/cutpipe.nif`.
##
## The payload `T` must hold no `ref` the producer keeps a way to: a moved value is
## owned by one thread at a time, and a cyclic ref aliased by the producer is unsafe
## under ORC. Plain seqs, strings and values are fine.
##
## Shared by `ptr`: make it with `newCutPipe` before starting the threads, and
## `close` it after joining them all.

import std/locks

type
  StopKind* = enum
    ## Why a run ended early.
    skNone     ## Running.
    skCancel   ## The user cancelled.
    skProducer ## A producer failed.
    skWriter   ## The writer failed.

  CutPipeObj[T] = object
    lock: Lock
    slotFree: Cond    ## signalled when `written` grew or a stop was set
    recordReady: Cond ## signalled when a record was placed or a stop was set
    records, ring, chunk: int
    nextChunk: int    ## first record of the next chunk
    written: int      ## records taken and written so far (the next to take)
    full: seq[bool]   ## per slot: holds a record not yet taken
    slots: seq[T]
    inRing: int       ## records placed and not yet taken
    peak: int         ## the most `inRing` ever was
    stop: StopKind
    message: string

  CutPipe*[T] = ptr CutPipeObj[T]
    ## The shared pipe. Create with `newCutPipe`, free with `close`.

  Taken* = enum
    ## What `takeNext` found.
    tkRecord  ## A record was taken.
    tkDone    ## Every record was taken. This does not mean the run succeeded: a stop
              ## may have come since (a producer failing after its last record), so read
              ## `stopped` after joining the producers.
    tkStopped ## The run was stopped.

proc newCutPipe*[T](records, ring, chunk: int): CutPipe[T] =
  ## A pipe for `records` records with `ring` slots, handing out chunks of
  ## `chunk` records. `ring` and `chunk` below 1 are taken as 1.
  result = cast[CutPipe[T]](createShared(CutPipeObj[T]))
  let ring = max(1, ring)
  result.records = max(0, records)
  result.ring = ring
  result.chunk = max(1, chunk)
  result.full = newSeq[bool](ring)
  result.slots = newSeq[T](ring)
  initLock result.lock
  initCond result.slotFree
  initCond result.recordReady

proc close*[T](p: CutPipe[T]) =
  ## Frees the pipe. Call it once, after every thread using it has been joined.
  if p == nil: return
  deinitCond p.slotFree
  deinitCond p.recordReady
  deinitLock p.lock
  p.full = @[]
  p.slots = @[]
  p.message = ""
  deallocShared(p)

proc takeChunk*[T](p: CutPipe[T]; first, last: var int): bool =
  ## A producer takes the next chunk of records, `first ..< last`; false when
  ## every record is handed out or the run was stopped.
  acquire p.lock
  result = p.stop == skNone and p.nextChunk < p.records
  if result:
    first = p.nextChunk
    last = min(p.records, first + p.chunk)
    p.nextChunk = last
  release p.lock

proc place*[T](p: CutPipe[T]; i: int; item: var T): bool =
  ## A producer puts record `i` (swapping `item` with the slot's buffer) once
  ## `i < written + ring`, waiting until then. False, with `item` untouched,
  ## when the run was stopped. Each `i` in `0 ..< records` is placed once.
  acquire p.lock
  doAssert i >= p.written and i < p.records, "record placed twice or out of range"
  while p.stop == skNone and i >= p.written + p.ring:
    wait(p.slotFree, p.lock)
  result = p.stop == skNone
  if result:
    let s = i mod p.ring
    doAssert not p.full[s], "record placed twice"
    swap(item, p.slots[s])
    p.full[s] = true
    inc p.inRing
    p.peak = max(p.peak, p.inRing)
    broadcast p.recordReady
  release p.lock

proc takeNext*[T](p: CutPipe[T]; item: var T): Taken =
  ## The writer takes the next record in order (swapping it into `item`),
  ## waiting until a producer placed it. Call `written` after writing it and
  ## before the next `takeNext`.
  acquire p.lock
  if p.written >= p.records:
    result = tkDone
  else:
    let s = p.written mod p.ring
    while p.stop == skNone and not p.full[s]:
      wait(p.recordReady, p.lock)
    if p.stop != skNone: result = tkStopped
    else:
      swap(item, p.slots[s])
      p.full[s] = false
      dec p.inRing
      result = tkRecord
  release p.lock

proc written*[T](p: CutPipe[T]) =
  ## The writer has written the record it took: the slot's index is free for
  ## the record `ring` further on. Wakes every waiting producer.
  acquire p.lock
  inc p.written
  broadcast p.slotFree
  release p.lock

proc stopWith*[T](p: CutPipe[T]; kind: StopKind; message = "") =
  ## Ends the run: the first reason, and its message, win. Wakes every thread
  ## waiting in `place` or `takeNext`.
  acquire p.lock
  if p.stop == skNone and kind != skNone:
    p.stop = kind
    p.message = message
  broadcast p.slotFree
  broadcast p.recordReady
  release p.lock

proc stopped*[T](p: CutPipe[T]): StopKind =
  ## Why the run was stopped; `skNone` while it runs.
  acquire p.lock
  result = p.stop
  release p.lock

proc stopMessage*[T](p: CutPipe[T]): string =
  ## The first stop's message.
  acquire p.lock
  result = p.message
  release p.lock

proc writtenCount*[T](p: CutPipe[T]): int =
  ## Records written so far.
  acquire p.lock
  result = p.written
  release p.lock

proc ringPeak*[T](p: CutPipe[T]): int =
  ## The most records the ring held at once (never above `ring`).
  acquire p.lock
  result = p.peak
  release p.lock
