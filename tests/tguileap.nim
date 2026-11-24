## Tools > Leap seconds, headless, driven by real clicks: the window shows the
## table, Apply adds a leap second, and the log says so. Remove stays dim
## until a leap was added here.
##
## Seen to fail: with Tools > Leap seconds... opening nothing, "open did not finish".
## With the Set checked-to button still marked `leap.setchecked`, "no checked-to
## control" did not finish.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, leapfile, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

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
  for n in f.markNames(""):
    if n == name: return true

proc said(f: FrameInfo; bit: string): bool =
  for e in f.core.log:
    if bit in e.text: return true

proc main*() =
  let shipped = defaultLeapTable()
  defer: useLeapTable(shipped)
  withFixtures fx:
    let config = fx.dir / "config"
    createDir(config)
    let opts = RunOptions(windowSize: (1400, 900), theme: forceDark, persist: true,
      configDir: some(config), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]))
    var steps: seq[Step]
    var wait = 0
    var since = getMonoTime()
    var shot = false
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    step("in the main window", proc (f: FrameInfo) = f.keepInMainWindow(),
      proc (f: FrameInfo): bool = true)
    step("Tools", proc (f: FrameInfo) = f.click(f.markOf("menu.Tools").centre),
      proc (f: FrameInfo): bool = f.hasMark("menu.Leap seconds..."))
    step("open", proc (f: FrameInfo) = f.click(f.markOf("menu.Leap seconds...").centre),
      proc (f: FrameInfo): bool =
      let rows = f.markNames("leap.row ")
      let last = shipped.entries[^1]
      let newest = "leap.row " & dateText(LeapDate(year: last.year, month: last.month,
        day: last.day))
      f.hasMark("leap") and f.hasMark("leap.apply") and f.hasMark("leap.why") and
        f.hasMark("leap.checked") and rows.len > 0 and rows[0].startsWith(newest))
    step("no checked-to control", proc (f: FrameInfo) = discard,
      proc (f: FrameInfo): bool =
      not f.hasMark("leap.setchecked") and not f.hasMark("leap.unchecked"))
    var clicked = false
    step("apply", proc (f: FrameInfo) =
      if not shot:
        let dir = getEnv("VIEWSEG_SCREENSHOTS")
        if dir.len > 0:
          createDir(dir)
          doAssert f.savePng(dir / "leap-seconds.png"), "cannot save the leap window"
        shot = true
      f.moveMouse(f.markOf("leap.apply").centre), proc (f: FrameInfo): bool =
      if not clicked:
        f.click(f.markOf("leap.apply").centre)
        clicked = true
        return false
      currentLeapTable().entries.len == shipped.entries.len + 1 and
        f.said("Added a leap second") and f.said("19"))
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
          failed = steps[at].name & " (table has " & $currentLeapTable().entries.len & " entries)"
          f.stop()
    var o = opts
    o.onFrame = onFrame
    let code = run(o)
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed & " did not finish"
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    doAssert currentLeapTable().entries[^1].gpsMinusUtc == 19

when isMainModule:
  main()
