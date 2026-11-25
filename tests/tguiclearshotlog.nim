## Project > Clear shot log..., headless, driven by real clicks: the item is dim while no log is
## loaded (a click opens nothing); with one loaded it opens the confirmation, Cancel keeps the
## log, and Clear shot log removes it, leaving the log file as it was.
##
## Seen to fail: with the item always enabled, "the confirmation opened with no log"; with the
## command not sent by the button, "Clear shot log did not clear the log"; with Cancel sending
## the command, "Cancel cleared the log".
##
## Needs a display: run under
## `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[faultyfs, fixtures, waiting]

const
  ItemName = "menu.Clear shot log..."
  Sample = currentSourcePath().parentDir.parentDir / "samples" / "land" / "shotlog.csv"

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(r.pos.x + r.size.x / 2, r.pos.y + r.size.y / 2)

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc hasMark(f: FrameInfo; name: string): bool =
  f.markOf(name).size.x > 0

proc main*() =
  withFixtures fx:
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let log = fx.dir / "shots.csv"
    copyFile(Sample, log)
    let original = readFile(log)
    install()
    let opts = RunOptions(windowSize: (1920, 1080), theme: forceDark, persist: true,
      configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]))
    var steps: seq[Step]
    var wait = 0
    var since = getMonoTime()
    var clicks = 0
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc menuItem(f: FrameInfo) =
      if not f.hasMark(ItemName): f.click(f.markOf("menu.Project").centre)
    proc openItem(f: FrameInfo): bool =
      if f.hasMark(ItemName) and not f.hasMark("shotlog.clear"):
        f.click(f.markOf(ItemName).centre)
      f.hasMark("shotlog.clear")
    step("in the main window", proc (f: FrameInfo) = f.keepInMainWindow(),
      proc (f: FrameInfo): bool = true)
    step("Project", proc (f: FrameInfo) = f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool = f.hasMark(ItemName))
    step("the item with no log", proc (f: FrameInfo) =
      clicks = 0
      f.click(f.markOf(ItemName).centre),
      proc (f: FrameInfo): bool =
      inc clicks
      doAssert not f.hasMark("shotlog.clear"), "the confirmation opened with no log"
      clicks >= 5)
    proc importLog(f: FrameInfo) =
      f.apply Command(kind: ckImportShotLog, logPath: log)
    step("a log", importLog,
      proc (f: FrameInfo): bool = f.core.shotLogCount == 1 and f.core.jobs.active.len == 0)
    var menuShot = false
    step("the menu picture", proc (f: FrameInfo) =
      if not f.hasMark(ItemName): f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool =
        if f.hasMark(ItemName) and not menuShot:
          menuShot = true
          let dir = getEnv("VIEWSEG_SCREENSHOTS")
          if dir.len > 0:
            createDir(dir)
            doAssert f.savePng(dir / "project-menu.png"), "cannot save the menu"
        menuShot)
    step("the item opens the confirmation", menuItem, openItem)
    step("Cancel", proc (f: FrameInfo) = f.click(f.markOf("shotlog.clear.cancel").centre),
      proc (f: FrameInfo): bool =
      doAssert f.core.shotLogCount == 1, "Cancel cleared the log"
      not f.hasMark("shotlog.clear"))
    step("the item opens it again", menuItem, openItem)
    var shot = false
    proc picture(f: FrameInfo) =
      let dir = getEnv("VIEWSEG_SCREENSHOTS")
      if dir.len > 0 and not shot:
        createDir(dir)
        doAssert f.savePng(dir / "clear-shot-log.png"), "cannot save the dialog"
      shot = true
    step("the picture", picture, proc (f: FrameInfo): bool = true)
    step("Clear shot log", proc (f: FrameInfo) = f.click(f.markOf("shotlog.clear.confirm").centre),
      proc (f: FrameInfo): bool = f.core.shotLogCount == 0 and not f.hasMark("shotlog.clear"))
    var at = 0
    var started = false
    var failed = ""
    proc onFrame(f: FrameInfo) =
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
        elif overdue(wait, 400, since):
          failed = steps[at].name
          f.stop()
    var o = opts
    o.onFrame = onFrame
    let code = run(o)
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, "Clear shot log did not clear the log: " & failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    doAssert readFile(log) == original, "the log file changed"

when isMainModule:
  main()
