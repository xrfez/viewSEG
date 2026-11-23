## The Window menu in the running frontend, headless, driven by real clicks
## on the menu bar (SDL mouse events), with the settings and layouts in a
## folder of the test's own:
##
## - a scrambled layout (the Files window dragged out past the screen's
##   right edge, the map out of the main window beside it, Jobs floating
##   inside the main window, Records and Messages hidden, and the Headers
##   window left on a screen that is not there) is arranged as loading a
##   layout does: the window off every screen is brought onto the main
##   window's screen at once, with a warning that names it; the others stay
##   as the layout says;
## - Window > Reset the windows: every window shown, docked in the main
##   window's dockspace, none outside the main window; Aux and Missing traces
##   stay closed until asked;
## - each window's entry: a click on one in sight hides it, on one hidden
##   shows it in front, on one behind another tab brings it forward; the
##   Seismic window is never hidden; the layout text says which are hidden;
## - Window > Bring all windows onto this screen, with the main window
##   hanging off the screen's left edge and two windows outside it: the
##   main window and every window outside it lie wholly on the screen;
## - the shortcut, Ctrl+Shift+R, resets the windows as the menu does;
## - a second run starts with the window hidden at the first run's exit
##   hidden, and its entry shows it.
##
## Under Xvfb there is one screen and no window manager: what this covers
## of monitors is a window outside the main window (a window of the
## desktop's of its own), one past an edge and one at a place no screen has.
## A second monitor, one unplugged while the program runs, a window manager
## moving windows and per-monitor scales are not covered (the rules are
## tested on made-up screens in `tscreens`).
##
## Seen to fail: with `resetWindows` not showing the hidden windows, the
## reset never showed Records ("Reset the windows did not happen"); with the Files window's entry
## only bringing it forward (never hiding), "files is still drawn"; with the
## settings handler not writing its section, "the layout does not say that
## files is hidden"; with `bringWindows` not moving the windows outside the
## main window, "files is not on the screen"; with the check after a layout
## is arranged left out, "headers is not on the screen"; with the item click
## waiting a frame after an off-screen title (the clamped pointer then rests
## on the next menu and takes the open one), the main window stayed at -300.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, screens, state]
import viewSEG/ui/imgui/app
import viewSEG/view/theme
import privatefiles
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

const ids = ["plot", "files", "records", "map", "headers", "jobs", "Messages"]

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

func blocks(text: string): seq[string] =
  ## Dear ImGui's layout text, a section at a time.
  var cur = ""
  for line in text.splitLines:
    if line.startsWith("[") and cur.len > 0:
      result.add cur
      cur = ""
    if line.len > 0: cur.add line & "\n"
  if cur.len > 0: result.add cur

func rearranged(text: string; floating: openArray[(string, Rect)]; hidden: string): string =
  ## `text` with each window of `floating` undocked, at its rectangle (given
  ## from the main window's top-left corner, as Dear ImGui keeps a window
  ## the main window holds), and `hidden` the windows hidden.
  for b in text.blocks:
    var kept = not b.startsWith("[viewSEG][Windows]")
    for (id, _) in floating:
      if b.startsWith("[Window][" & id & "]"): kept = false
    if kept: result.add b & "\n"
  for (id, r) in floating:
    result.add "[Window][" & id & "]\nPos=" & $int(r.pos.x) & "," & $int(r.pos.y) & "\nSize=" &
      $int(r.size.x) & "," & $int(r.size.y) & "\nCollapsed=0\n\n"
  result.add "[viewSEG][Windows]\nHidden=" & hidden & "\n\n"

var wait = 0 ## frames since the step began, at `since`
var since = getMonoTime()

proc drive(steps: seq[Step]; opts: RunOptions) =
  var at = 0
  var started = false
  var failed = ""
  var o = opts
  o.onFrame = proc (f: FrameInfo) =
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
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(o)
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

# With `VIEWSEG_SCREENSHOTS=<dir>` and the example files present (they are
# local only), the menus are saved open over the private land record: Project
# (menus-project.png), Tools (menus-tools.png) and Window (menus-window.png);
# docs/images/ holds the committed ones.

proc menuShots(dir: string) =
  let record = privateFile("landSegd")
  let shots = [("menu.Project", "", "menus-project.png"),
    ("menu.Tools", "", "menus-tools.png"), ("menu.Window", "", "menus-window.png")]
  var stage = 0
  var wait = 0 # frames since the stage began, at `since`
  var since = getMonoTime()
  var saved: seq[string]
  proc onFrame(f: FrameInfo) =
    inc wait
    template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
    let k = f.core.findPanel(MainPanel)
    if stage == 0:
      if f.core.panels[k].laidOut and f.core.tiles(k).len > 0 and wait > 30:
        next 1
    elif stage <= shots.len:
      let (top, sub, file) = shots[stage - 1]
      if wait == 2: f.click(f.markOf(top).centre)
      if wait == 8 and sub.len > 0: f.click(f.markOf(sub).centre)
      if wait == 20:
        if f.savePng(dir / file): saved.add file
        f.click(f.markOf("statusbar").centre) # closes the menu
      if wait == 30: next(stage + 1)
    else: f.stop()
    if overdue(wait, 3000, since): f.stop()
  let tmp = getTempDir() / ("viewseg-menushots-" & $getCurrentProcessId())
  # Kept settings, so that the presets are listed and a layout can be saved.
  let code = run(RunOptions(openPaths: @[record], windowSize: (1600, 1000),
    theme: forceDark, indexCacheDir: some(tmp), userThemeDir: some(tmp / "no-user-themes"),
    persist: true, configDir: some(tmp / "config"), logDir: some(tmp / "logs"),
    assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]), onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0 and saved.len == shots.len, "screenshots saved: " & $saved
  echo "tguiwindows: saved ", saved.join(", "), " in ", dir

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
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    var screen: Rect
    var main: Rect

    proc menu(name, item: string; then: proc (f: FrameInfo): bool) =
      ## The menu (View for a window's tick, else Window) opened by a click on its title, then a click on `item` while
      ## that item is still drawn. The title can lie off the left of the screen
      ## (the main window hangs there): the pointer warp is clamped to the
      ## screen's edge, which can rest on the next title and take the open
      ## menu, so the pointer is parked past the last title at once.
      var clicked = false
      let bar = if item.startsWith("menu.window."): "menu.View" else: "menu.Window"
      step(name & ": " & bar, proc (f: FrameInfo) =
        clicked = false
        let title = f.markOf(bar)
        f.click(title.centre)
        let last = f.markOf("menu.Help")
        f.moveMouse(vec2(last.pos.x + last.size.x + 40, title.centre.y)),
        proc (f: FrameInfo): bool =
        let it = f.markOf(item)
        if it.size.x > 0 and not clicked:
          f.click(it.centre)
          clicked = true
        result = clicked)
      step(name, noop, then)

    proc onScreen(f: FrameInfo; id: string) =
      let p = f.windowPlace(id)
      doAssert p.rect.inside(screen), id & " is not on the screen: " & $p.rect & " (the screen " &
        $screen & ")"

    proc allDocked(f: FrameInfo; what: string) =
      let m = f.mainWindowRect
      for id in ids:
        let p = f.windowPlace(id)
        doAssert p.shown, id & " is not shown " & what
        doAssert p.docked, id & " is not docked " & what
        doAssert not p.apart, id & " is outside the main window " & what
        doAssert p.rect.inside(m), id & " is not inside the main window " & what & ": " &
          $p.rect & " in " & $m
      doAssert f.hiddenWindows == {awAux, awMissing}, "hidden " & what & ": " & $f.hiddenWindows

    step("the file is shown", noop, proc (f: FrameInfo): bool =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      result = p.laidOut and f.markOf("plot.data").size.x > 0 and f.layoutText.len > 0
      if result:
        doAssert f.screens.len == 1, "screens: " & $f.screens
        screen = f.screens[0]
        main = f.mainWindowRect
        f.allDocked("at the start"))
    # ------------------------------------------------- scrambled, then reset --
    step("scrambled", proc (f: FrameInfo) =
      let m = main.pos
      func at(x, y, w, h: float32): Rect = Rect(pos: vec2(x - m.x, y - m.y), size: vec2(w, h))
      # Files past the screen's right edge, the map over the main window's
      # right edge, Jobs floating inside it, Headers on no screen.
      f.arrangeWindows(f.layoutText.rearranged([
        ("files", at(screen.pos.x + screen.size.x - 150, 300, 400, 300)),
        ("map", at(main.pos.x + main.size.x - 100, 500, 300, 360)),
        ("jobs", at(m.x + 300, m.y + 300, 320, 220)),
        ("headers", at(5000, 4000, 400, 300))], "records,Messages")),
      proc (f: FrameInfo): bool =
      result = wait > 10 and f.windowPlace("files").apart and f.windowPlace("map").apart
      if result:
        for id in ["files", "map", "jobs", "headers"]:
          doAssert not f.windowPlace(id).docked, id & " is docked"
        doAssert not f.windowPlace("jobs").apart, "jobs is outside the main window"
        doAssert not f.windowPlace("files").rect.inside(screen), "files is wholly on the screen"
        f.onScreen("map")
        f.onScreen("headers") # brought back at once
        var said = false
        for e in f.core.log:
          if e.severity == sevWarning and "Headers" in e.text and "off every screen" in e.text:
            said = true
        doAssert said, "nothing says that the Headers window was off every screen"
        for id in ["records", "Messages"]:
          doAssert not f.windowPlace(id).shown, id & " is drawn"
        doAssert f.hiddenWindows == {awRecords, awMessages, awAux, awMissing}, $f.hiddenWindows)
    menu("Reset the windows", "menu.Reset the windows", proc (f: FrameInfo): bool =
      result = wait > 10 and f.windowPlace("records").shown
      if result: f.allDocked("after the reset"))
    # ------------------------------------------------------ each window --
    menu("Files, in sight: hidden", "menu.window.files", proc (f: FrameInfo): bool =
      result = wait > 4
      if result:
        doAssert not f.windowPlace("files").shown, "files is still drawn"
        doAssert awFiles in f.hiddenWindows
        doAssert "Hidden=files" in f.layoutText, "the layout does not say that files is hidden")
    menu("Files, hidden: shown", "menu.window.files", proc (f: FrameInfo): bool =
      result = wait > 4 and f.windowPlace("files").inSight
      if result: doAssert f.windowPlace("files").docked, "files came back undocked")
    step("Jobs is behind Messages", noop, proc (f: FrameInfo): bool =
      f.windowPlace("Messages").inSight and not f.windowPlace("jobs").inSight)
    menu("Jobs, behind a tab: brought forward", "menu.window.jobs", proc (f: FrameInfo): bool =
      result = wait > 4 and f.windowPlace("jobs").inSight
      if result: doAssert not f.windowPlace("Messages").inSight and awJobs notin f.hiddenWindows)
    menu("the Seismic window: never hidden", "menu.window.plot", proc (f: FrameInfo): bool =
      result = wait > 4
      if result: doAssert f.windowPlace("plot").inSight and
        f.hiddenWindows == {awAux, awMissing})
    # ---------------------------------------------- onto this screen --
    step("the main window off the left edge, two windows outside it", proc (f: FrameInfo) =
      f.moveMainWindow(int(screen.pos.x) - 300, int(screen.pos.y) + 80)
      let m = vec2(screen.pos.x - 300, screen.pos.y + 80)
      func at(x, y, w, h: float32): Rect = Rect(pos: vec2(x - m.x, y - m.y), size: vec2(w, h))
      f.arrangeWindows(f.layoutText.rearranged([
        ("files", at(screen.pos.x + screen.size.x - 150, 200, 400, 300)),
        ("map", at(screen.pos.x + screen.size.x - 500, 650, 420, 600))], "")),
      proc (f: FrameInfo): bool =
      result = wait > 10 and f.mainWindowRect.pos.x < screen.pos.x and
        f.windowPlace("files").apart and f.windowPlace("map").apart
      if result:
        doAssert not f.windowPlace("files").rect.inside(screen)
        doAssert not f.windowPlace("map").rect.inside(screen))
    menu("Bring all windows onto this screen", "menu.Bring all windows onto this screen",
      proc (f: FrameInfo): bool =
      result = wait > 10
      if result:
        doAssert f.mainWindowRect.inside(screen), "the main window is not on the screen: " &
          $f.mainWindowRect
        f.onScreen("files")
        f.onScreen("map"))
    # ---------------------------------------------- the shortcut --
    step("Ctrl+Shift+R", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.data").centre)
      f.pressKey(skCtrl, true, {smCtrl})
      f.pressKey(skShift, true, {smCtrl, smShift}), proc (f: FrameInfo): bool =
      if wait == 3:
        f.pressKey(skR, true, {smCtrl, smShift})
        f.pressKey(skR, false, {smCtrl, smShift})
      if wait == 5:
        f.pressKey(skShift, false, {smCtrl})
        f.pressKey(skCtrl, false)
      result = wait > 15 and f.windowPlace("files").docked
      if result:
        f.allDocked("after Ctrl+Shift+R")
        doAssert not f.core.panels[f.core.findPanel(MainPanel)].layers[0].reversed,
          "the shortcut reversed the polarity too")
    menu("Jobs hidden for the next run", "menu.window.jobs", proc (f: FrameInfo): bool =
      wait > 4 and awJobs in f.hiddenWindows)
    step("wait for the layout to be noted", noop, proc (f: FrameInfo): bool = wait > 90)
    drive(steps, opts)

    # ------------------------------------------------------ the next run --
    var next: seq[Step]
    steps = @[]
    step("Jobs starts hidden", noop, proc (f: FrameInfo): bool =
      result = wait > 5
      if result:
        doAssert f.hiddenWindows == {awJobs, awAux, awMissing}, "hidden at start: " &
          $f.hiddenWindows
        doAssert not f.windowPlace("jobs").shown)
    menu("Jobs shown", "menu.window.jobs", proc (f: FrameInfo): bool =
      wait > 4 and f.windowPlace("jobs").inSight and f.hiddenWindows == {awAux, awMissing})
    next = steps
    drive(next, opts)
    echo "tguiwindows: ", next.len, " steps in the second run"

  if getEnv("VIEWSEG_SCREENSHOTS").len > 0 and privateFile("landSegd").len > 0:
    createDir(getEnv("VIEWSEG_SCREENSHOTS"))
    menuShots(getEnv("VIEWSEG_SCREENSHOTS"))

when isMainModule:
  main()
