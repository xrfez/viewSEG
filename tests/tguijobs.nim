## The Jobs window in the running frontend, headless, with real pointer
## events: it starts as a tab behind Messages, and a click on the status
## bar's job field brings it forward; it lists the running jobs with their
## progress and the queued ones of both lanes; a click on a queued job's
## "down" button moves it in its lane, "remove" takes it off the list,
## "Cancel" stops a running job; when background jobs end, a notice shows
## in the corner, and the finished jobs are listed until "Clear the list".
##
## Seen to fail: with a click on the progress bar not asking for the
## window, "the job field did not bring the Jobs window forward"; with the
## down button sending the position the job has, "down did not move QC 1";
## with `drawNotices` not called, "no notice". Bringing a docked tab forward
## by focus alone showed it for one frame (`bringForward` now selects the
## tab): "Cancel did not stop Open".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves jobs-window.png there.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/waiting

var gates: array[2, Gate]

proc held(ctx: JobContext) {.gcsafe.} = gates[0].waitAt(ctx)

proc opening(ctx: JobContext) {.gcsafe.} =
  ctx.setPhase "indexing"
  discard ctx.progress(50, 100)
  gates[1].waitAt(ctx)

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))
var
  stage = 0
  wait = 0             # frames since the stage began, at `since`
  since = getMonoTime()
  at: Vec2
  ids: array[4, JobId] # Hold, QC 1, QC 2, Open
  reached: seq[string]
  hiddenFirst, shownAfterClick, moved, removed, cancelled, noticed, cleared = false
  saved = true

proc onFrame(f: FrameInfo) =
  inc wait
  if f.index == 0:
    f.moveMouse(vec2(4, 4))
    ids[0] = f.core.jobs.submit(JobSpec(title: "Hold", lane: jlBackground), held)
    ids[1] = f.core.jobs.submit(JobSpec(title: "QC 1", lane: jlBackground), held)
    ids[2] = f.core.jobs.submit(JobSpec(title: "QC 2", lane: jlBackground), held)
    ids[3] = f.core.jobs.submit(JobSpec(title: "Open", lane: jlInteractive), opening)
  proc click(f: FrameInfo; mark: string): bool =
    ## Moves to `mark`, presses and releases over the next frames; true once
    ## released.
    if wait == 1:
      at = f.markOf(mark).centre
      f.moveMouse(at)
    if wait == 3: f.pressMouse(at, true)
    if wait == 5: f.pressMouse(at, false)
    wait > 6
  proc next(name: string) =
    reached.add name
    inc stage
    wait = 0
    since = getMonoTime()
  case stage
  of 0:
    let open = f.core.jobs.info(ids[3]).get
    if open.state == jsRunning and open.progress.done == 50 and
        f.markOf("status.progress").size.x > 0 and wait > 3:
      hiddenFirst = f.markOf("jobs").size.x == 0
      next "running"
  of 1:
    if f.click("status.progress") and wait > 8:
      shownAfterClick = f.markOf("jobs.queued QC 1").size.x > 0 and
        f.markOf("jobs.running Open").size.x > 0 and f.markOf("jobs.running Hold").size.x > 0
      if getEnv("VIEWSEG_SCREENSHOTS").len > 0:
        createDir(getEnv("VIEWSEG_SCREENSHOTS"))
        saved = f.savePng(getEnv("VIEWSEG_SCREENSHOTS") / "jobs-window.png")
      next "shown"
  of 2:
    if f.click("jobs.down QC 1"):
      moved = f.core.jobs.queued(jlBackground) == @[ids[2], ids[1]]
      next "down"
  of 3:
    if f.click("jobs.remove QC 2"):
      removed = f.core.jobs.info(ids[2]).isNone
      next "remove"
  of 4:
    if f.click("jobs.cancel Open"):
      if wait > 8 and f.core.jobs.info(ids[3]).get.state == jsCancelled:
        cancelled = true
        gates[0].open()
        next "cancel"
  of 5:
    if f.markOf("notice").size.x > 0 and f.markOf("jobs.finished QC 1").size.x > 0:
      noticed = true
      next "notice"
  of 6:
    if f.click("jobs.clear"):
      var left = 0
      for j in f.core.jobs.list:
        if j.state in {jsDone, jsFailed, jsCancelled}: inc left
      cleared = left == 0
      next "clear"
  else: f.stop()
  if overdue(f.index, 2000, since): f.stop()

proc main*() =

  let tmp = getTempDir() / ("viewseg-tguijobs-" & $getCurrentProcessId())

  let code = run(RunOptions(windowSize: (1600, 1000), theme: forceDark,
    indexCacheDir: some(tmp / "cache"), userThemeDir: some(tmp / "no-user-themes"),
    onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0, "run() exit code " & $code
  doAssert hiddenFirst, "the Jobs window was in front from the start"
  doAssert shownAfterClick, "the job field did not bring the Jobs window forward"
  doAssert moved, "down did not move QC 1"
  doAssert removed, "remove did not take QC 2 off the list"
  doAssert cancelled, "Cancel did not stop Open"
  doAssert noticed, "no notice"
  doAssert cleared, "Clear the list left finished jobs"
  doAssert reached.len == 7, "stopped after " & $reached
  doAssert saved
  echo "tguijobs: ", reached

when isMainModule:
  main()
