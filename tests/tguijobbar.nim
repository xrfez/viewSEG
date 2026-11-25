## The status bar's job field keeps still, headless in the running frontend:
## while a job reports progress with phases of very different lengths (and
## for a while no total at all) and another job runs beside it, the Cancel
## button's and the progress bar's rectangles are the same on every frame; a
## click on Cancel at that place stops the job the bar shows.
##
## Seen to fail: with the bar placed after a gap that grows with the label's
## length, "the progress bar moved or changed size on 94 frames"; with the bar
## showing whichever running job came first in the list on each frame instead
## of the one shown last, the label alternates (see tjobstatus).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves job-bar.png there.

import std/[atomics, math, monotimes, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/waiting

const Phases = ["a", "indexing the headers of a file with a very long name indeed.sgy",
  "counting", "reading every trace of the survey folder, file by file, in order"]

var
  steps: Atomic[int]
  gate: Gate

proc varying(ctx: JobContext) {.gcsafe.} =
  ## Progress that jumps in size and in words, until it is cancelled.
  var i = 0
  while true:
    ctx.setPhase Phases[i mod Phases.len]
    let total = if i mod 9 < 3: 0'i64 else: 1000'i64
    if not ctx.progress(int64((i * 37) mod 1000), total): break
    steps.store i
    inc i
    sleep 2

proc beside(ctx: JobContext) {.gcsafe.} = gate.waitAt(ctx)

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc main*() =

  var
    scan, other = NoJob
    cancel, bar: Rect
    frames, moved, changed = 0
    clickAt = -1
    cancelled = false
    saved = true
    since = getMonoTime()
  let tmp = getTempDir() / ("viewseg-tguijobbar-" & $getCurrentProcessId())

  proc onFrame(f: FrameInfo) =
    if f.index == 0:
      f.moveMouse(vec2(4, 4))
      scan = f.core.jobs.submit(JobSpec(title: "Scan the folder", lane: jlInteractive,
        cancellable: true), varying)
      other = f.core.jobs.submit(JobSpec(title: "QC pass", lane: jlBackground), beside)
    elif clickAt < 0 and scan != NoJob and steps.load > 3 and
        f.markOf("status.cancel").size.x > 0 and f.markOf("status.progress").size.x > 0:
      let c = f.markOf("status.cancel")
      let b = f.markOf("status.progress")
      if frames == 0:
        cancel = c
        bar = b
      else:
        if c != cancel: inc moved
        if b != bar: inc changed
      inc frames
      if frames == 120:
        let dir = getEnv("VIEWSEG_SCREENSHOTS")
        if dir.len > 0:
          createDir(dir)
          saved = f.savePng(dir / "job-bar.png")
        clickAt = f.index
        f.moveMouse(cancel.centre)
    elif clickAt >= 0 and f.index == clickAt + 2:
      f.pressMouse(cancel.centre, down = true)
    elif clickAt >= 0 and f.index == clickAt + 4:
      f.pressMouse(cancel.centre, down = false)
    elif clickAt >= 0 and f.core.jobs.info(scan).get.state in {jsCancelled, jsDone}:
      # It ends by returning once `progress` says stop: done, after a cancel.
      cancelled = f.core.jobs.info(scan).get.cancelRequested and
        f.core.jobs.info(other).get.state == jsRunning
      gate.open()
      f.stop()
    if overdue(f.index, 1500, since): f.stop()

  let code = run(RunOptions(windowSize: (1600, 1000), theme: forceDark,
    indexCacheDir: some(tmp / "cache"), userThemeDir: some(tmp / "no-user-themes"),
    onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0, "run() exit code " & $code
  doAssert frames >= 120, "the job field was not drawn: " & $frames
  doAssert moved == 0, "the Cancel button moved on " & $moved & " frames"
  doAssert changed == 0, "the progress bar moved or changed size on " & $changed & " frames"
  doAssert cancelled, "the click on Cancel did not stop the job shown"
  doAssert saved
  echo "tguijobbar: ", frames, " frames, cancel at ", cancel, ", bar at ", bar

when isMainModule:
  main()
