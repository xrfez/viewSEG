## Waiting in tests for something another thread does, and gates that make
## a fake job wait until the test lets it go.
##
## Every wait has a deadline far above what the event needs (seconds, not
## milliseconds), so a slow CI machine passes and a broken feature fails
## instead of hanging.

import std/[atomics, monotimes, os, times]
import viewSEG/core/jobs

const Patience* = initDuration(seconds = 20) ## the longest any test waits

template waitUntil*(cond: untyped; timeout = Patience): bool =
  ## Polls `cond` every millisecond until it holds (true) or `timeout`
  ## passes (false).
  let deadline = getMonoTime() + timeout
  var met = bool(cond)
  while not met and getMonoTime() < deadline:
    sleep 1
    met = bool(cond)
  met

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
