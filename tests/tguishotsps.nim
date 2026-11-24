## The Export SPS button of the Shot log window, in the running frontend,
## headless: the button is there and not dim for a log with shot points; it
## opens the panel; Export is refused until a file is chosen and while the chosen
## file exists (and says why); with a new name Export writes the file the core
## writes for the log, and the outcome line says how many rows were written and
## left out; a log with no shot point leaves the button dim, with its reason.
##
## Seen to fail: with the button's dim state left off, "the button was not dim for
## a log with no shot point". With the name in use not refused, "Export was not
## refused for a file that exists". With the chosen name never reaching the
## command, "the SPS file was not written".
##
## Needs a display: run under
## `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[monotimes, options, os, strutils, times]
import parseSEG
import viewSEG/core/[geometry, shotlog, shotlogsps, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc hasMark(f: FrameInfo; prefix: string): bool =
  f.markNames(prefix).len > 0

type Step = object
  name: string
  limit: int
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

proc main*() =
  withFixtures fx:
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let root = currentSourcePath().parentDir.parentDir
    let good = fx.dir / "good.csv"
    let blank = fx.dir / "blank.csv"
    # The third row has no easting: it is left out and said so.
    writeFile(good, "source line,shot point,X,Y\n10,1000,500.5,2000.5\n10,1001,501.5,2001.5\n" &
      "10,1002,,2002.5\n")
    writeFile(blank, "shot point,X,Y\n,1,2\n,3,4\n")
    let taken = fx.dir / "taken.sps"
    writeFile(taken, "keep me\n")
    let fresh = fx.dir / "fresh.sps"
    let shot = root / ".scratch" / "shotlog-sps.png"
    createDir(shot.parentDir)

    var nextLog = good
    var nextDest = taken
    var asked: seq[DialogKind]
    let hook = proc (kind: DialogKind; location: string): seq[string] =
      asked.add kind
      case kind
      of dkShotLog: @[nextLog]
      of dkExportShotSps: @[nextDest]
      else: @[]
    var steps: seq[Step]
    var wait = 0
    var since = getMonoTime()
    var why = ""
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool;
        limit = 600) =
      steps.add Step(name: name, limit: limit, act: act, done: done)
    proc importNext(f: FrameInfo) = f.click(f.markOf("menu.Import shot log...").centre)

    step("the bar", proc (f: FrameInfo) =
      f.resizeWindow(1920, 1080)
      f.keepInMainWindow(),
      proc (f: FrameInfo): bool =
        f.markOf("menu.Project").size.x > 0 and f.windowSize == (1920, 1080))
    step("Project", proc (f: FrameInfo) = f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool = f.markOf("menu.Import shot log...").size.x > 0)
    step("import the log", importNext,
      proc (f: FrameInfo): bool =
      f.core.shotLogCount == 1 and f.markOf("shotlog.exportsps").size.x > 0 and
        not f.hasMark("shotlog.exportsps.dim") and not f.hasMark("shotlog.sps.run"))
    step("open the panel", proc (f: FrameInfo) = f.click(f.markOf("shotlog.exportsps").centre),
      proc (f: FrameInfo): bool =
      if not f.hasMark("shotlog.sps.run") and wait mod 8 == 0:
        f.click(f.markOf("shotlog.exportsps").centre)
      f.hasMark("shotlog.sps.run") and f.hasMark("shotlog.sps.why Choose the file"))
    step("choose a file that exists", proc (f: FrameInfo) =
      f.click(f.markOf("shotlog.sps.choose").centre),
      proc (f: FrameInfo): bool =
        why = $f.markNames("shotlog.sps.")
        asked == @[dkShotLog, dkExportShotSps] and
          f.hasMark("shotlog.sps.file " & taken) and f.hasMark("shotlog.sps.why That file exists"))
    step("Export is refused", proc (f: FrameInfo) = f.click(f.markOf("shotlog.sps.run").centre),
      proc (f: FrameInfo): bool =
      doAssert readFile(taken) == "keep me\n", "an existing file was replaced"
      doAssert not f.core.spsRunning and f.core.spsOutcome.len == 0,
        "Export was not refused for a file that exists"
      wait > 10)
    step("choose a new file", proc (f: FrameInfo) =
      nextDest = fresh
      f.click(f.markOf("shotlog.sps.choose").centre),
      proc (f: FrameInfo): bool =
        f.hasMark("shotlog.sps.file " & fresh) and not f.hasMark("shotlog.sps.why"))
    step("Export", proc (f: FrameInfo) = f.click(f.markOf("shotlog.sps.run").centre),
      proc (f: FrameInfo): bool =
      why = f.core.spsOutcome
      if f.hasMark("shotlog.sps.outcome Wrote 2 rows to fresh.sps"):
        doAssert fileExists(fresh), "the SPS file was not written"
        var opts = initShotSpsOptions()
        doAssert readFile(fresh) == toSps(f.core.shotView(0), opts).text,
          "the file is not what the core writes"
        doAssert "1 row was left out" in f.core.spsOutcome, f.core.spsOutcome
        doAssert f.savePng(shot), "the screenshot was not written"
        return true
      false, 2000)
    step("another log, no shot point", proc (f: FrameInfo) =
      nextLog = blank
      f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool =
        if f.markOf("menu.Import shot log...").size.x > 0 and f.core.shotLogCount == 1:
          f.click(f.markOf("menu.Import shot log...").centre)
        f.core.shotLogCount == 2 and f.hasMark("shotlog.exportsps.dim"), 2000)

    var at = 0
    var started = false
    var failed = ""
    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.keepInMainWindow()
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if not started:
        steps[at].act(f)
        started = true
        (wait, since) = (0, getMonoTime())
      else:
        inc wait
        if wait >= 3 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, steps[at].limit, since):
          failed = steps[at].name & " did not happen: " & why
          f.stop()
    var opts = RunOptions(windowSize: (1920, 1080), theme: forceDark, persist: true,
      configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"),
      userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[root / "assets"]), dialogs: hook)
    opts.onFrame = onFrame
    let code = run(opts)
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguishotsps: ", steps.len, " steps"

when isMainModule:
  main()
