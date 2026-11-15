## Jobs held at a phase, as a long step holds a job there: the test side of
## `core/jobs`'s job hook. `installSteps` sets the hook; then a job whose
## work names a phase given to `holdStep` waits in it until `releaseStep`,
## and `cameBack` says when a job's work has returned (also after the `Jobs`
## it ran in is gone: the quit leaves it).
##
## Held jobs wait at most `StepLimit`, so a forgotten release fails a test
## instead of hanging the suite.

import std/[locks, monotimes, os, times]
import viewSEG/core/jobs

const StepLimit* = initDuration(seconds = 60)

var
  lock: Lock
  heldPhases: seq[string]
  inside: seq[tuple[id: JobId; phase: string]]
  back: seq[JobId]

proc hookCall(id: JobId; phase: string; done: bool) {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    acquire lock
    if done:
      back.add id
    elif phase in heldPhases:
      inside.add (id, phase)
      let deadline = getMonoTime() + StepLimit
      while phase in heldPhases and getMonoTime() < deadline:
        release lock
        sleep 1
        acquire lock
      for i in 0 ..< inside.len:
        if inside[i] == (id, phase):
          inside.delete i
          break
    release lock

proc installSteps*() =
  ## Puts the hook in place, holding no phase.
  initLock lock
  setJobHook(hookCall)

proc holdStep*(phase: string) =
  ## From now on, a job whose work names `phase` waits in it.
  withLock lock:
    if phase notin heldPhases: heldPhases.add phase

proc releaseStep*(phase: string) =
  ## The jobs waiting in `phase` go on; it holds no more.
  withLock lock:
    let i = heldPhases.find(phase)
    if i >= 0: heldPhases.delete i

proc inStep*(phase: string): seq[JobId] =
  ## The jobs waiting in `phase` now.
  withLock lock:
    for x in inside:
      if x.phase == phase: result.add x.id

proc cameBack*(id: JobId): bool =
  ## Whether the work of job `id` has returned.
  withLock lock:
    result = id in back
