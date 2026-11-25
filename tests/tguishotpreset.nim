## The Columns dialog's Time pattern pick-list, in the running frontend, headless. A log
## holding Unix microseconds in a column that is not yet a time: choosing Time (UTC) for
## the column fills in `epoch microseconds` (two clicks), and nothing is read until Apply;
## the pick-list's items fill the free text box (Unix seconds, then back to Unix
## microseconds) and the box stays editable; Apply reads the times.
##
## Seen to fail: with the role choice not filling the pattern, `Time (UTC) for the column` found the box
## empty; with the pick-list's item not filling the box, `Unix seconds` found the old
## pattern.
##
## Needs a display: run under
## `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    limit: int
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc patternText(f: FrameInfo): string =
  for n in f.markNames("shotlog.patterntext "): return n["shotlog.patterntext ".len .. ^1]
  "(none)"

proc main*() =
  withFixtures fx:
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let root = currentSourcePath().parentDir.parentDir
    let log = fx.dir / "unixlog.csv"
    writeFile(log, "shot,stamp\n1,1709251200000000\n2,1709251210000000\n")
    let shots = root / ".scratch" / "slogtable-shots"
    let listShot = shots / "pattern-presets.png"
    createDir(shots)
    var steps: seq[Step]
    var wait = 0
    var since = getMonoTime()
    var why = ""
    var stampCol = -1
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool;
        limit = 600) =
      steps.add Step(name: name, limit: limit, act: act, done: done)
    proc noop(f: FrameInfo) = discard

    step("the bar", proc (f: FrameInfo) =
      f.resizeWindow(1920, 1080)
      f.keepInMainWindow(),
      proc (f: FrameInfo): bool =
        f.markOf("menu.Project").size.x > 0 and f.windowSize == (1920, 1080))
    step("Project", proc (f: FrameInfo) = f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool = f.markOf("menu.Import shot log...").size.x > 0)
    step("import the log", proc (f: FrameInfo) =
      f.click(f.markOf("menu.Import shot log...").centre),
      proc (f: FrameInfo): bool =
        why = f.markNames("shotlog.summary ").join("|")
        "unixlog.csv" in why and "2 rows" in why
      , 2000)
    step("room", proc (f: FrameInfo) =
      f.arrangeWindows(f.layoutText & "[Window][###shotlog]\nPos=20,80\nSize=1500,850\n" &
        "Collapsed=0\n\n[viewSEG][Windows]\nHidden=aux,missing,quality,vibfolder,output\n\n"),
      proc (f: FrameInfo): bool =
        f.windowPlace("shotlog").inSight and not f.windowPlace("shotlog").docked and
          f.markOf("shotlog.columns").size.x > 0)
    step("no time is read yet", noop, proc (f: FrameInfo): bool =
      f.core.shotView(0).rows[0].timeUtcUs.isNone)
    step("Columns...", proc (f: FrameInfo) = f.click(f.markOf("shotlog.columns").centre),
      proc (f: FrameInfo): bool =
      if f.markOf("shotlog.presets").size.x == 0 and wait mod 8 == 0:
        f.click(f.markOf("shotlog.columns").centre)
      for n in f.markNames("shotlog.role "):
        if n.endsWith(" User defined") and stampCol < 0:
          let c = parseInt(n["shotlog.role ".len .. ^1].split(' ')[0])
          if c == 1: stampCol = c
      why = $f.markNames("shotlog.role ")
      stampCol == 1 and f.markOf("shotlog.rolecombo 1").size.x > 0 and wait > 6)
    step("Time (UTC) for the column", proc (f: FrameInfo) =
      f.click(f.markOf("shotlog.rolecombo 1").centre),
      proc (f: FrameInfo): bool =
        let item = f.markOf("shotlog.roleitem 1 Time (UTC)")
        if item.size.x > 0 and wait == 4: f.click(item.centre)
        why = f.patternText
        f.patternText == "epoch microseconds" and f.core.shotView(0).rows[0].timeUtcUs.isNone)
    step("open the pick-list", proc (f: FrameInfo) = f.click(f.markOf("shotlog.presets").centre),
      proc (f: FrameInfo): bool =
      if f.markOf("shotlog.presetitem Unix seconds").size.x == 0 and wait mod 10 == 0:
        f.click(f.markOf("shotlog.presets").centre)
      result = f.markOf("shotlog.presetitem Unix seconds").size.x > 0 and
        f.markOf("shotlog.presetitem Unix microseconds").size.x > 0
      if result:
        doAssert f.savePng(listShot), "the pick-list screenshot was not written")
    step("Unix seconds", proc (f: FrameInfo) =
      f.click(f.markOf("shotlog.presetitem Unix seconds").centre),
      proc (f: FrameInfo): bool =
        why = f.patternText
        f.patternText == "epoch seconds")
    step("Unix microseconds again", proc (f: FrameInfo) =
      f.click(f.markOf("shotlog.presets").centre),
      proc (f: FrameInfo): bool =
        let item = f.markOf("shotlog.presetitem Unix microseconds")
        if item.size.x == 0 and wait mod 10 == 0: f.click(f.markOf("shotlog.presets").centre)
        if item.size.x > 0 and f.patternText != "epoch microseconds" and wait mod 10 == 3:
          f.click(item.centre)
        why = f.patternText
        f.patternText == "epoch microseconds" and
          f.markOf("shotlog.presetitem Unix seconds").size.x == 0)
    step("Apply", proc (f: FrameInfo) = f.click(f.markOf("shotlog.apply").centre),
      proc (f: FrameInfo): bool =
      if f.markOf("shotlog.apply").size.x > 0 and wait mod 10 == 0:
        f.click(f.markOf("shotlog.apply").centre)
      f.core.shotView(0).rows[0].timeUtcUs == some(1_709_251_200_000_000'i64) and
        f.core.shotView(0).rows[1].timeUtcUs == some(1_709_251_210_000_000'i64)
    , 1000)

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
    let hook = proc (kind: DialogKind; location: string): seq[string] =
      if kind == dkShotLog: @[log] else: @[]
    let opts = RunOptions(windowSize: (1920, 1080), theme: forceDark, persist: true,
      configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"),
      userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[root / "assets"]), dialogs: hook, onFrame: onFrame)
    let code = run(opts)
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguishotpreset: ", steps.len, " steps"

when isMainModule:
  main()
