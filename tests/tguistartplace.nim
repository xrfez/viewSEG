## Where the windows are at start, headless, with the settings and the
## layout in a folder of the test's own, written as an earlier run would:
##
## - `--reset-windows` (`RunOptions.resetWindows`) over a scrambled layout
##   file (Files dragged out past the screen's edge, Jobs floating, Records
##   hidden) and a settings file that puts the main window off every
##   screen: every window shown and docked in the main window, the main
##   window at its default size in the middle of the primary screen, a line
##   in Messages saying so, every other setting as the file has it; what is
##   saved at exit is the arrangement it started with;
## - a start over a settings file whose main window is off every screen (a
##   monitor that is gone) and a layout that leaves the Headers window off
##   every screen too: both brought onto the screen, each with a warning;
##   the other windows as the layout says;
## - a start over a settings file whose main window is larger than any
##   screen: made to fit the screen, with a warning.
##
## Under Xvfb there is one screen and no window manager: a second monitor,
## one unplugged and the desktop's own placing are not covered (the rules
## are tested on made-up screens in `tscreens`).
##
## Seen to fail: with the layout file read in spite of `resetWindows`,
## "files is not docked after --reset-windows"; with `createMainWindow`
## opening at the saved place when it is off every screen, "the main window
## is not on the screen after --reset-windows: (pos: (x: 6000.0 ..."; with
## the size of a main window larger than any screen kept, "the main window
## is not on the screen" (3000 wide).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[monotimes, options, os, strutils]
import viewSEG/core/[geometry, layouts, screens, settings, settingsnif, state]
import viewSEG/ui/imgui/app
import viewSEG/view/theme
import utils/[fixtures, waiting]

const ids = ["plot", "files", "records", "map", "headers", "jobs", "Messages"]

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
  ## `text` with each window of `floating` undocked at its rectangle (from
  ## the main window's top-left corner) and `hidden` the windows hidden.
  for b in text.blocks:
    var kept = not b.startsWith("[viewSEG][Windows]")
    for (id, _) in floating:
      if b.startsWith("[Window][" & id & "]"): kept = false
    if kept: result.add b & "\n"
  for (id, r) in floating:
    result.add "[Window][" & id & "]\nPos=" & $int(r.pos.x) & "," & $int(r.pos.y) & "\nSize=" &
      $int(r.size.x) & "," & $int(r.size.y) & "\nCollapsed=0\n\n"
  result.add "[viewSEG][Windows]\nHidden=" & hidden & "\n\n"

func withHook(o: RunOptions; hook: FrameHook): RunOptions =
  result = o
  result.onFrame = hook

var began: MonoTime ## a run's first frame

proc shown(f: FrameInfo): bool =
  ## Whether the file the run opens is shown (a job opens it); a failure
  ## past 3000 frames and `Patience`.
  if f.index == 0: began = getMonoTime()
  result = f.core.panels[f.core.findPanel(MainPanel)].laidOut
  doAssert result or not overdue(f.index, 3000, began), "the file was not shown"

proc said(f: FrameInfo; words: string; severity: Severity): bool =
  result = false
  for e in f.core.log:
    if e.severity == severity and words in e.text: return true

proc main*() =

  withFixtures fx:
    let path = fx.surveySegy()
    let config = fx.dir / "config"
    createDir(config)
    let assets = currentSourcePath().parentDir.parentDir / "assets"
    proc options(reset = false): RunOptions =
      RunOptions(openPaths: @[path], theme: forceDark, persist: true,
        configDir: some(config), logDir: some(fx.dir / "logs"),
        indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
        assetDirs: some(@[assets]), resetWindows: reset)

    # A first run: the default arrangement, as Dear ImGui writes it.
    var plain = ""
    var screen: Rect
    proc first(f: FrameInfo) =
      if f.index == 20:
        plain = f.layoutText
        screen = f.screens[0]
        f.stop()
    doAssert run(RunOptions(maxFrames: 100, windowSize: (1400, 900), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      onFrame: first)) == 0
    doAssert "[Docking]" in plain and screen.size.x > 0, plain

    proc writeFiles(window: WindowPlacement; imgui: string) =
      var s = Settings()
      s.window = window
      s.files.followLatest = true # a setting --reset-windows leaves alone
      writeFile(config / SettingsFileName, settingsDocument(s))
      writeFile(config / LayoutFileName, layoutDocument(Layout(imgui: imgui)))

    proc defaultPlace(f: FrameInfo; what: string) =
      let m = f.mainWindowRect
      doAssert m.inside(screen), "the main window is not on the screen " & what & ": " & $m
      let c = vec2(1280, 800).centredOn(screen)
      doAssert abs(m.pos.x - c.pos.x) <= 1 and abs(m.pos.y - c.pos.y) <= 1 and
        m.size == c.size, "the main window is not in the middle of the screen at its " &
        "default size " & what & ": " & $m & ", not " & $c

    # ----------------------------------------------- --reset-windows --
    writeFiles(WindowPlacement(x: 6000, y: 4000, width: 1300, height: 850), plain.rearranged([
      ("files", Rect(pos: vec2(screen.size.x - 150, 300), size: vec2(400, 300))),
      ("jobs", Rect(pos: vec2(300, 300), size: vec2(320, 220)))], "records"))
    var checked = false
    proc reset(f: FrameInfo) =
      if f.shown and f.index >= 30:
        for id in ids:
          let w = f.windowPlace(id)
          doAssert w.shown, id & " is not shown after --reset-windows"
          doAssert w.docked and not w.apart, id & " is not docked after --reset-windows"
          doAssert w.rect.inside(f.mainWindowRect), id & " is outside the main window"
        doAssert f.hiddenWindows == {awAux, awMissing, awQuality, awOutput}, $f.hiddenWindows
        f.defaultPlace("after --reset-windows")
        doAssert f.said("Started with --reset-windows", sevInfo), "nothing says so"
        doAssert f.core.settings.files.followLatest, "another setting was reset"
        checked = true
        f.stop()
    doAssert run(options(reset = true).withHook(reset)) == 0
    doAssert checked, "the run ended before the windows were checked"
    var problems: seq[string]
    let saved = readLayout(readFile(config / LayoutFileName), LayoutFileName, problems).imgui
    doAssert "Hidden=aux,missing,quality,output\n" in saved and
      "Pos=" & $int(screen.size.x - 150) notin saved,
      "the scrambled layout is still saved: " & saved

    # ------------------------------- the main window off every screen --
    writeFiles(WindowPlacement(x: 6000, y: 4000, width: 1300, height: 850), plain.rearranged([
      ("headers", Rect(pos: vec2(5000, 4000), size: vec2(400, 300)))], ""))
    checked = false
    proc offScreen(f: FrameInfo) =
      if f.shown and f.index >= 30:
        f.defaultPlace("when its saved place is off every screen")
        doAssert f.said("off every screen (on a monitor that is not there now?)", sevWarning),
          "nothing says the main window was off every screen"
        let h = f.windowPlace("headers")
        doAssert h.apart and h.rect.inside(screen), "headers is not on the screen: " & $h.rect
        doAssert f.said("The layout put Headers", sevWarning), "nothing says headers was"
        for id in ["plot", "files", "records", "map", "jobs", "Messages"]:
          doAssert f.windowPlace(id).docked, id & " is not docked as the layout says"
        checked = true
        f.stop()
    doAssert run(options().withHook(offScreen)) == 0
    doAssert checked, "the run ended before the windows were checked"
    let kept = readFile(config / SettingsFileName)
    doAssert "(x 6000)" notin kept, "the place off every screen is still saved: " & kept

    # ------------------------------- larger than any screen --
    writeFiles(WindowPlacement(x: 100, y: 50, width: 3000, height: 2000), plain)
    checked = false
    proc large(f: FrameInfo) =
      if f.shown and f.index >= 20:
        let m = f.mainWindowRect
        doAssert m.inside(screen), "the main window is not on the screen: " & $m
        doAssert m.size == screen.size, "the main window does not fill the screen: " & $m
        doAssert f.said("is larger than any screen", sevWarning), "nothing says so"
        checked = true
        f.stop()
    doAssert run(options().withHook(large)) == 0
    doAssert checked, "the run ended before the window was checked"
    echo "tguistartplace: the screen ", screen

when isMainModule:
  main()
