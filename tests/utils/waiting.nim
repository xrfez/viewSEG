## Waiting in tests for something another thread does, and gates that make
## a fake job wait until the test lets it go.
##
## Every wait is for the condition itself, with a deadline far above what the
## event needs (a minute: a machine at a load of 100 makes a job of a tenth
## of a second take seconds), so a loaded machine passes and a broken feature
## fails instead of hanging: the caller's `doAssert` says what was waited for.
##
## - `waitUntil` polls a condition.
## - `settle` polls it as a frame does: the program's inbox drained first,
##   and it must still hold after the next drain. A job posts what it made,
##   then ends, so "no job active" can hold while its last message waits in
##   the inbox; the second drain takes it.
## - `overdue` is the deadline of a step in a frame hook: past both its
##   frames and `Patience`. A count of frames alone is a time under load
##   (the frames go on while the job threads wait for a core); a time alone
##   fails when the frames are what is slow.

import std/[atomics, monotimes, os, times]
import viewSEG/core/jobs

const Patience* = initDuration(seconds = 60) ## the longest any test waits

template waitUntil*(cond: untyped; timeout = Patience): bool =
  ## Polls `cond` every millisecond until it holds (true) or `timeout`
  ## passes (false).
  let deadline = getMonoTime() + timeout
  var met = bool(cond)
  while not met and getMonoTime() < deadline:
    sleep 1
    met = bool(cond)
  met

template settle*(st, cond: untyped): bool =
  ## Polls `cond` after draining the inbox of `st` (an `AppState`), as a
  ## frame does, until it holds after a drain and again after the next one
  ## (true), or `Patience` passes (false). `cond` may declare names: each
  ## look at it is a scope of its own.
  template look(): bool =
    block:
      discard st.drainInbox()
      bool(cond)
  waitUntil(look() and look())

proc overdue*(frames, limit: int; since: MonoTime): bool =
  ## Whether a step in a frame hook that began at `since`, `frames` frames
  ## ago, has waited too long: more than `limit` frames and more than
  ## `Patience`.
  frames > limit and getMonoTime() - since > Patience

type Gate* = Atomic[bool]
  ## Closed until `open`; a global, so job closures use it without capture.

proc open*(g: var Gate) = g.store(true)
proc close*(g: var Gate) = g.store(false)
proc isOpen*(g: var Gate): bool = g.load

proc waitAt*(g: var Gate; ctx: JobContext) =
  ## Waits until `g` opens; raises `JobCancelledError` once the job is
  ## cancelled, and `IOError` past twice `Patience` (a test that forgot the
  ## gate): later than any `waitUntil`, so a test's own check fails first.
  let deadline = getMonoTime() + Patience * 2
  while not g.load:
    ctx.checkCancelled()
    if getMonoTime() > deadline:
      raise newException(IOError, "the gate never opened")
    sleep 1
