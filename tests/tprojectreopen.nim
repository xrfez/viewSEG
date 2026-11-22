## A project closed and opened again at once is not found held by the close that has not been
## carried out yet: the lock is let go on a job (a close on a share may wait), so a program that
## opens the project lets a release still waiting go itself. Without that, the second open is
## read-only ("another program has it open", its own owner's note) and what is typed in it is
## not written.
##
## The first program's lane is held by a job that waits for a gate, so its release of the lock
## is queued and cannot run; a second program (its own jobs) opens the project then.
##
## Seen to fail: with the open not letting a staged release go (`letGo` in `openProjectWork`
## left out), the second program's project was read-only.
##
## Quick; headless.

import std/[os, strutils]
import viewSEG/core/[jobs, project, state]
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond))

var gate: Gate

proc start(config: string): AppState =
  result = initAppState()
  result.rememberFilesIn(config)

proc main*() =
  withFixtures fx:
    let job = fx.dir / "Job"
    let config = fx.dir / "config"
    let other = fx.dir / "config2"
    createDir(other)
    var first = start(config)
    first.apply Command(kind: ckNewProject, projectPath: job)
    doAssert first.settle(first.inProject)
    discard first.settle(first.jobs.active.len == 0)
    doAssert not first.project.readOnly
    # the lane is busy: the release the close queues cannot run
    gate.close()
    discard first.jobs.submit(JobSpec(title: "Hold the lane", lane: jlInteractive,
      cancellable: false), proc (ctx: JobContext) {.gcsafe.} =
      {.cast(gcsafe).}: gate.waitAt(ctx))
    first.apply Command(kind: ckCloseProject)
    doAssert not first.inProject
    var second = start(other)
    second.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert second.settle(second.inProject), "the project did not open"
    doAssert not second.project.readOnly, "the project opened read-only: " &
      second.project.whyReadOnly
    gate.open()
    second.apply Command(kind: ckCloseProject)
    discard second.settle(not second.inProject and second.jobs.active.len == 0)
    discard first.settle(first.jobs.active.len == 0)
    discard second.shutdown()
    discard first.shutdown()
    echo "tprojectreopen: ok"

when isMainModule: main()
