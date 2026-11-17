## Opening files in the running frontend, headless: a file named on the
## command line and one chosen in File > Open file (the dialog's event) both
## open through the open job and appear in the Messages window, which shows
## the application's log; the one chosen last is shown, in place of the
## first, which is closed; the index caches land in the folder the run is
## given; a running job shows a progress bar with Cancel in the status bar,
## and clicking Cancel (a real pointer move and button press) cancels it;
## the files are never changed.
##
## Seen to fail: with the status bar not drawing the job field, "no progress
## bar"; with the Cancel click not applied as a command, "Cancel did
## nothing"; with `onShellEvent` ignoring the dialog's paths, "the files did
## not both open".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves open-progress.png there.

import std/[monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/[app, shell]
import utils/[fixtures, waiting]

var gate: Gate

proc scanning(ctx: JobContext) {.gcsafe.} =
  ## A job half done, until it is cancelled.
  ctx.setPhase "scanning"
  discard ctx.progress(50, 100)
  gate.waitAt(ctx)

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

func centre(r: Rect): Vec2 = vec2(r.pos.x + r.size.x / 2, r.pos.y + r.size.y / 2)

func has(lines: seq[Message]; part: string; level = mlInfo): bool =
  for m in lines:
    if part in m.text and m.level == level: return true
  false

proc main*() =

  withFixtures fx:
    let survey = fx.surveySegy()
    let segd = fx.twoSetSegd()
    let before = (snapshot(survey), snapshot(segd))
    let cache = fx.dir / "cache" / "index"
    var
      opened = -1           # the frame both files were open in
      scan = NoJob
      bar, cancel: Rect
      accent, barPixels = 0
      clickAt = -1
      posted = false
      cancelled = -1
      since = getMonoTime() # when the frames the give-up counts began
      lines: seq[Message]
    proc onFrame(f: FrameInfo) =
      let k = f.core.findPanel(MainPanel)
      let shown = f.core.shownFile(k)
      if not posted and shown >= 0 and f.core.sessions[shown].path == survey:
        postShellEvent ShellEvent(kind: sePathsChosen, dialog: dkOpenFile, paths: @[segd])
        posted = true
      if opened < 0 and shown >= 0 and f.core.sessions[shown].path == segd and
          f.core.sessions.len == 1 and f.messages.has("Opened " & survey.extractFilename):
        opened = f.index
        since = getMonoTime()
        scan = f.core.jobs.submit(JobSpec(title: "Scan the folder", lane: jlBackground),
          scanning)
      elif scan != NoJob and clickAt < 0 and f.core.jobs.info(scan).get.state == jsRunning and
          f.core.jobs.info(scan).get.progress.done == 50 and f.markOf("status.cancel").size.x > 0:
        bar = f.markOf("status.progress")
        cancel = f.markOf("status.cancel")
        let pixels = f.readFrame()
        let a = f.theme.roles[rlAccent]
        let y = int(bar.pos.y + bar.size.y / 2)
        for x in int(bar.pos.x) ..< int(bar.pos.x + bar.size.x):
          inc barPixels
          if distance(pixels[y * f.width + x], a) <= 2: inc accent
        let dir = getEnv("VIEWSEG_SCREENSHOTS")
        if dir.len > 0:
          createDir(dir)
          doAssert f.savePng(dir / "open-progress.png")
        clickAt = f.index
        since = getMonoTime()
        f.moveMouse(cancel.centre)
      elif clickAt >= 0 and f.index == clickAt + 2:
        f.pressMouse(cancel.centre, down = true)
      elif clickAt >= 0 and f.index == clickAt + 4:
        f.pressMouse(cancel.centre, down = false)
      elif clickAt >= 0 and cancelled < 0 and f.core.jobs.info(scan).get.state == jsCancelled:
        cancelled = f.index
      elif cancelled >= 0 and f.index > cancelled + 1 and
          f.messages.has("Scan the folder was cancelled."):
        lines = f.messages
        f.stop()
      elif overdue(f.index - (if clickAt >= 0: clickAt elif opened >= 0: opened else: 0), 600,
          since):
        lines = f.messages # given up: the checks below say what is missing
        f.stop()

    let code = run(RunOptions(openPaths: @[survey], indexCacheDir: some(cache),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert opened >= 0, "the files did not both open: " & $lines.len
    doAssert lines.has("Opened " & survey.extractFilename & ": 72 traces in 3 gathers."),
      $lines
    doAssert lines.has("Opened " & segd.extractFilename & ": ")
    doAssert not lines.has("Closed "), "the file shown first was closed, quietly"
    doAssert bar.size.x > 50, "no progress bar: " & $bar
    doAssert accent >= barPixels div 2 - 8 and accent <= barPixels div 2 + 8,
      "the bar is not half full: " & $accent & " of " & $barPixels & " pixels"
    doAssert cancel.size.x > 0, "no Cancel button"
    doAssert cancelled >= 0, "Cancel did nothing"
    doAssert lines.has("Scan the folder was cancelled."), $lines
    var caches = 0
    for _ in walkFiles(cache / "*.pidx"): inc caches
    doAssert caches == 2, $caches & " index caches in " & cache
    doAssert (snapshot(survey), snapshot(segd)) == before, "opening changed a file"
    echo "tguiopen: opened both files by frame ", opened, ", cancelled at frame ", cancelled

when isMainModule:
  main()
