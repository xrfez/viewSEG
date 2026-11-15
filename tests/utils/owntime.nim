## The time a thread takes for its own work, for tests that bound it.
##
## A wall-clock bound on what the calling thread does (a frame's drain, a
## command) fails on a loaded machine: the thread waits for a core, and the
## clock goes on. `ownTime` is the wall clock less the time the thread
## waited in the scheduler's queue (Linux keeps it per thread in
## `/proc/thread-self/schedstat`), so it keeps what the thread ran and what
## it waited for (a lock, a read, a sleep), which is what such a bound is
## about, and leaves out the load. Elsewhere it is the wall clock.

import std/[monotimes, strutils, times]

proc queued(): Duration =
  ## How long the calling thread has waited for a core, in all.
  when defined(linux):
    try:
      let fields = readFile("/proc/thread-self/schedstat").splitWhitespace
      if fields.len >= 2:
        return initDuration(nanoseconds = parseBiggestInt(fields[1]))
    except IOError, ValueError:
      discard
  Duration()

proc ownTime*(): Duration =
  ## The calling thread's clock: a monotonic time that stands still while
  ## the thread waits for a core. Only differences of it mean something.
  let wall = getMonoTime().ticks
  initDuration(nanoseconds = wall) - queued()

template ownTimeOf*(body: untyped): Duration =
  ## How long `body` took the calling thread, by `ownTime`.
  let t0 = ownTime()
  body
  ownTime() - t0
