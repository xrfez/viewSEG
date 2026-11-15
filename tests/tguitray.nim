## The tray icon and the window frames in the running frontend, headless,
## the Window menu driven by real clicks:
##
## - with `RunOptions.tray` the icon is in the tray after the first frame,
##   its menu Show viewSEG, Open file..., a separator, Quit, as SDL holds it;
## - Window > Minimize to the tray: minimizing hides the main window (SDL's
##   flag) and the tray's Show viewSEG brings it back; turned off,
##   minimizing hides nothing;
## - the tray's Open file... asks for the file dialog;
## - Window > Icon in the tray off takes the icon away, on puts it back;
## - the window frames: every theme change gives the open windows the new
##   look (`frames.dressed` counts them; on Linux nothing is set, the
##   reaching is what is checked), and a window dragged out of the main
##   window (a viewport window of its own) gets it when it is made;
## - the tray's Quit ends the run, and the icon is gone after it;
## - without `RunOptions.tray` (every other test) there is no icon.
##
## Under Xvfb SDL's AppIndicator tray has no bar to show in (and no D-Bus
## session: GLib warns on stderr), but its menu exists and its entries click
## (`SDL_ClickTrayEntry`). Where SDL cannot make a tray at all (no
## libayatana-appindicator3), the tray steps are skipped and the frames
## steps still run. What the icon looks like, and Windows' frames, are not
## seen here: docs/windows.md lists what to check on Windows.
##
## Seen to fail: with `hideInTray` not hiding, "minimized: hidden in the tray,
## Show brings it back did not happen"; with the frames' `onCreateWindow`
## not installed, "a window dragged out gets its frame did not happen"; with
## `followTray` not taking the icon away, "Icon in the tray off did not
## happen".

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, settings, state]
import viewSEG/ui/imgui/[app, frames, shell]
import viewSEG/view/theme
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

var wait = 0
var since = getMonoTime()

proc drive(steps: seq[Step]; opts: RunOptions): int =
  ## Runs `steps` in turn; returns how many were done when the run ended.
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
  at

withFixtures fx:
  let config = fx.dir / "config"
  createDir(config)
  var asked: seq[DialogKind]
  let opts = RunOptions(windowSize: (1280, 800), theme: forceDark, persist: true,
    configDir: some(config), logDir: some(fx.dir / "logs"),
    indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
    assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]), tray: true,
    dialogs: proc (kind: DialogKind; location: string): seq[string] =
    asked.add kind
    @[])
  var steps: seq[Step]
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard
  proc menu(name, item: string; then: proc (f: FrameInfo): bool) =
    step(name & ": Window", proc (f: FrameInfo) = f.click(f.markOf("menu.Window").centre),
      proc (f: FrameInfo): bool = f.markOf(item).size.x > 0)
    step(name, proc (f: FrameInfo) = f.click(f.markOf(item).centre), then)

  var trayOk = false
  var dressedBefore = 0
  step("the first frames", noop, proc (f: FrameInfo): bool =
    result = wait > 5 and (trayShown() or f.trayProblem.len > 0)
    if result:
      doAssert dressed >= 1, "the main window was given no frame"
      trayOk = trayShown()
      if not trayOk:
        echo "tguitray: the tray steps are skipped: ", f.trayProblem
      else:
        doAssert trayMenu() == @["Show viewSEG", "Open file...", "", "Quit"], $trayMenu())
  # ------------------------------------------------------------- frames --
  step("a theme change dresses the windows", proc (f: FrameInfo) =
    dressedBefore = dressed
    var s = f.core.settings
    s.theme = "everforest-light"
    f.apply(Command(kind: ckSettings, settings: s)),
    proc (f: FrameInfo): bool = f.theme.mode == tmLight and dressed > dressedBefore)
  step("a window dragged out gets its frame", proc (f: FrameInfo) =
    dressedBefore = dressed
    let m = f.mainWindowRect
    # The Jobs window undocked and moved past the main window's right edge:
    # Dear ImGui gives it an OS window of its own.
    var text = ""
    for b in f.layoutText.split("\n["):
      let b = if b.startsWith("["): b else: "[" & b
      if not b.startsWith("[Window][jobs]") and not b.startsWith("[viewSEG][Windows]"):
        text.add b.strip & "\n\n"
    f.arrangeWindows(text & "[Window][jobs]\nPos=" & $int(m.size.x - 100) &
      ",200\nSize=320,240\nCollapsed=0\n\n"),
    proc (f: FrameInfo): bool = f.windowPlace("jobs").apart and dressed > dressedBefore)
  # --------------------------------------------------------------- tray --
  proc trayStep(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    step(name, proc (f: FrameInfo) =
      if trayOk: act(f),
      proc (f: FrameInfo): bool = not trayOk or done(f))
  proc trayMenuStep(name, item: string; then: proc (f: FrameInfo): bool) =
    trayStep(name & ": Window", proc (f: FrameInfo) = f.click(f.markOf("menu.Window").centre),
      proc (f: FrameInfo): bool = f.markOf(item).size.x > 0)
    trayStep(name, proc (f: FrameInfo) = f.click(f.markOf(item).centre), then)

  trayMenuStep("Window > Minimize to the tray", "menu.tray.minimize", proc (f: FrameInfo): bool =
    f.core.settings.tray.minimize)
  trayStep("minimized: hidden in the tray, Show brings it back", proc (f: FrameInfo) =
    # Both are taken in the frame loop's next turn: the minimize first hides
    # the window (no frames are drawn while it is hidden), then the tray's
    # click shows it again.
    f.sayMinimized()
    clickTray(taShow),
    proc (f: FrameInfo): bool =
      f.trayHides == 1 and not f.inTray and not f.mainWindowHidden)
  trayStep("the tray's Open file...", proc (f: FrameInfo) = clickTray(taOpenFile),
    proc (f: FrameInfo): bool = dkOpenFile in asked)
  trayMenuStep("Minimize to the tray off", "menu.tray.minimize", proc (f: FrameInfo): bool =
    not f.core.settings.tray.minimize)
  trayStep("minimized, not to the tray", proc (f: FrameInfo) = f.sayMinimized(),
    proc (f: FrameInfo): bool =
    result = wait > 6
    if result:
      doAssert f.trayHides == 1 and not f.inTray and not f.mainWindowHidden, "hidden")
  trayMenuStep("Icon in the tray off", "menu.tray.icon", proc (f: FrameInfo): bool =
    not f.core.settings.tray.icon and not trayShown())
  trayMenuStep("Icon in the tray on", "menu.tray.icon", proc (f: FrameInfo): bool =
    f.core.settings.tray.icon and trayShown())
  var quitClicked = false
  trayStep("the tray's Quit", proc (f: FrameInfo) =
    quitClicked = true
    clickTray(taQuit),
    proc (f: FrameInfo): bool = false) # the run ends
  let done = drive(steps, opts)
  if trayOk:
    doAssert quitClicked and done == steps.high, "the tray's Quit did not end the run: step " &
      $done & " of " & $steps.len
    doAssert not trayShown(), "the icon is still in the tray after the quit"
  # The settings were saved with the tray's.
  let saved = readFile(config / "settings.nif")
  doAssert "(tray (icon true) (minimize false))" in saved.splitWhitespace.join(" "), saved

  # Without `RunOptions.tray`, as every other test runs: no icon.
  var o = opts
  o.tray = false
  o.maxFrames = 8
  var seen = false
  o.onFrame = proc (f: FrameInfo) =
    if trayShown(): seen = true
  doAssert run(o) == 0
  doAssert not seen, "a tray icon without RunOptions.tray"

echo "tguitray: ok"
