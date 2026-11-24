## The structure of the main menu bar in the running frontend, headless, driven
## by real clicks: the bar reads File, Project, Edit, View, Analysis, Reports,
## Tools, Window, Help, and each menu, opened, shows its items in one order. A menu's
## items are told by their marks ("menu." and the item's name; the submenus
## and the window ticks by their own marks), in the order they are drawn, so
## an item moved to another menu, or within its menu, fails here. Every
## item's tooltip and every doc names its place, so a move is a change to
## make on purpose.
##
## Seen to fail: with "Reload vendor maps" drawn in File too, "File shows
## @[..., "Prepare the next file", "Reload vendor maps", "Quit"]"; with Reports
## left out of the bar's names, "File shows @[..., "Quit", "Reports"]"; with the
## Missing traces window left out of View, "View shows @[..., "window.aux",
## "window.missing", "window.quality", "window.vibfolder", "window.join", ...]".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
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

const
  Bar = ["File", "Project", "Edit", "View", "Analysis", "Reports", "Tools", "Window",
    "Help"]
  Items = [
    ("File", @["Open file...", "Open files...", "Open folder...", "Open recent", "Close",
      "Reopen with options...", "Follow the latest file", "Prepare the next file", "Output...",
      "Quit"]),
    ("Project", @["New project...", "Open project...", "Recent projects", "Project...",
      "Import survey...", "Import shot log...", "Clear survey", "Close project"]),
    ("Edit", @["Undo", "Redo", "Select all traces", "Import trace edits...",
      "Export trace edits...", "Clear all edits for this file", "File memory..."]),
    ("View", @["window.plot", "window.files", "window.records", "window.map", "window.headers",
      "window.jobs", "window.Messages", "window.spectrum", "window.aux", "window.missing",
      "window.quality", "window.vibfolder", "window.output", "window.join", "window.shotlog",
      "Only traces in the template", "Theme",
      "Light / dark"]),
    ("Analysis", @["window.newplot", "Compare two traces", "First-break overlay",
      "Generate a reference...",
      "Reference archive..."]),
    ("Reports", @["Missing traces...", "Missing traces.disabled", "Trace quality",
      "Vibrator QC of a folder"]),
    ("Tools", @["Settings...", "Import settings...", "Export settings...",
      "Reset the settings", "Reload vendor maps", "Leap seconds...", "Export messages...",
      "Agent control"]),
    ("Window", @["Reset the windows", "Bring all windows onto this screen", "Load",
      "Save layout as...", "Import layout...", "Export layout...", "tray.icon",
      "tray.minimize"])]
  # The presets ("menu.layout.<name>") come between Bring and Load.

proc shown(f: FrameInfo): seq[string] =
  ## The item marks drawn this frame, in order, without the bar's titles and
  ## the presets.
  for n in f.markNames("menu."):
    let name = n["menu.".len .. ^1]
    if name notin Bar and not name.startsWith("layout."):
      result.add name

proc main*() =
  withFixtures fx:
    let path = fx.surveySegy()
    let config = fx.dir / "config"
    createDir(config)
    let opts = RunOptions(openPaths: @[path], windowSize: (1400, 900),
      theme: forceDark, persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]))
    var steps: seq[Step]
    var wait = 0
    var got: seq[string]
    var since = getMonoTime()
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard

    step("the bar", noop, proc (f: FrameInfo): bool =
      var order: seq[string]
      for n in f.markNames("menu."):
        if n["menu.".len .. ^1] in Bar: order.add n["menu.".len .. ^1]
      result = f.core.panels[f.core.findPanel(MainPanel)].laidOut and order.len == Bar.len
      if result:
        doAssert order == @Bar, "the bar reads " & $order)
    proc menuSteps(menu: string; items: seq[string]) =
      ## Opens `menu` and expects `items`, then closes it.
      step(menu, proc (f: FrameInfo) =
        f.click(f.markOf("menu." & menu).centre), proc (f: FrameInfo): bool =
        got = f.shown
        got == items)
      step(menu & " closed", proc (f: FrameInfo) = f.pressKey(skEscape, true),
        proc (f: FrameInfo): bool =
        f.pressKey(skEscape, false)
        f.shown.len == 0)
    for (menu, items) in Items:
      menuSteps(menu, items)

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
        elif overdue(wait, 300, since):
          failed = steps[at].name & " shows " & $got
          f.stop()
    var o = opts
    o.onFrame = onFrame
    let code = run(o)
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

when isMainModule:
  main()
