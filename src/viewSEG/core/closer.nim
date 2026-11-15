## The thread that closes files, so the UI thread never does.
##
## Closing a seismic file unmaps it and closes its descriptor. On a network
## share that no longer answers, the close can wait for the share; and
## parseSEG 0.11 unmaps and closes under one lock of its own, so while one
## close waits, every other open and close in the program waits for it too.
## The UI thread hands a file it no longer needs to this thread (`drop`)
## and goes on; the thread releases the files one after another.
##
## - **When.** Only once nothing reads the file: `AppState` drops a file
##   after its close job (which waits for every job and every reader's hold
##   on it), or one it never handed to a reader (an open no longer wanted, a
##   prepared file not stepped to).
## - **ORC.** The UI thread empties its list of cycle roots before it hands
##   a file over (`core/threads`, "Handing objects to another thread"), and
##   the thread empties its own after each file.
## - **Stop.** `stop` waits until a deadline for the files handed over to be
##   closed; a thread held by a share is left to end on its own, with its
##   memory and the files it has not closed yet.

import std/[locks, monotimes, os, times]
import session, threads

const CloserStopWait* = initDuration(milliseconds = 500)
  ## how long `stop` waits by default

type
  CloserObj = object
    lock: Lock
    changed: Cond
    files: seq[Session] ## to close, oldest first
    quit, ended, abandoned: bool
    started: bool
    thread: Thread[ptr CloserObj]

  Closer* = object
    ## The thread. Move-only; a default `Closer` is none (`drop` then
    ## releases the file where it is called).
    p: ptr CloserObj

proc `=destroy`*(x: Closer)
proc `=wasMoved`*(x: var Closer) = x.p = nil
proc `=copy`*(dest: var Closer; src: Closer) {.error.}
proc `=dup`*(src: Closer): Closer {.error.}

func isNil*(x: Closer): bool {.inline.} =
  ## Whether `x` is none.
  x.p == nil

proc run(p: ptr CloserObj) {.thread.} =
  markWorkerThread()
  while true:
    var s: Session
    var quit = false
    withLock p.lock:
      while p.files.len == 0 and not p.quit:
        wait(p.changed, p.lock)
      if p.files.len > 0:
        s = move p.files[0]
        p.files.delete(0)
      else:
        quit = true
    if quit: break
    s = nil # unmapped and closed here
    clearCycleRoots()
  withLock p.lock:
    p.ended = true

proc newCloser*(): Closer =
  ## Starts the thread.
  let p = cast[ptr CloserObj](allocShared0(sizeof(CloserObj)))
  initLock p.lock
  initCond p.changed
  result = Closer(p: p)
  createThread(p.thread, run, p)
  p.started = true

proc drop*(x: Closer; s: sink Session) =
  ## Hands `s`, which nothing reads any more, to the thread, which closes
  ## its file. UI thread.
  if s.isNil: return
  if x.p == nil:
    return # (`s` is released here)
  clearCycleRoots() # nothing of `s` stays listed on this thread
  withLock x.p.lock:
    x.p.files.add s
    signal(x.p.changed)

proc stop*(x: Closer; deadline = getMonoTime() + CloserStopWait): bool {.discardable.} =
  ## Closes what was handed over, then ends the thread, waiting for it
  ## until `deadline`: true when it ended; false when a share holds it (it
  ## is then left, with the files it has not closed). Idempotent.
  if x.p == nil or not x.p.started: return true
  if x.p.abandoned: return false
  withLock x.p.lock:
    x.p.quit = true
    signal(x.p.changed)
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
    x.p.abandoned = true
  ended

proc `=destroy`*(x: Closer) =
  if x.p != nil:
    discard x.stop()
    if not x.p.started: # else the thread still runs: its memory stays with it
      deinitCond(x.p.changed)
      deinitLock(x.p.lock)
      `=destroy`(x.p[])
      deallocShared(x.p)
