## What the user sets in the running program survives a restart, headless:
## a first run (with its settings in a folder of its own) opens a file,
## switches the plot to density with a real click, picks the light theme as
## View > Theme does, and makes the window larger, then quits; the second
## run starts in the light theme at that size, lists the file on its start
## screen, and a real click there opens it as density. Both runs write
## their session log.
##
## Seen to fail: with `initUi` ignoring the settings' theme, the second run
## was dark; with `createMainWindow` ignoring the saved size, it was 1280 x
## 800; with the start screen not listing recent files, "no recent file".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/[app, symbols]
import utils/fixtures

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc mode(f: FrameInfo): DisplayMode =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  if p.layers.len == 0: dmWiggle else: p.layers[0].display.mode

proc laidOut(f: FrameInfo): bool =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  p.layers.len > 0 and p.laidOut and f.markOf("plot.data").size.x > 0

withFixtures fx:
  let file = fx.surveySegy()
  let config = fx.dir / "config"
  let logs = fx.dir / "logs"
  let wanted = (1500, 900)
  block firstRun:
    var stage = 0
    var wait = 0
    var at: Vec2
    proc onFrame(f: FrameInfo) =
      inc wait
      case stage
      of 0: # the file shown: click "density"
        if f.laidOut and wait > 3:
          doAssert f.mode == dmWiggle
          at = f.markOf("plot." & $syDensity).centre
          f.moveMouse(at)
          (stage, wait) = (1, 0)
      of 1:
        if wait == 2: f.pressMouse(at, true)
        if wait == 3: f.pressMouse(at, false)
        if f.mode == dmDensity:
          f.chooseTheme("everforest-light")
          f.resizeWindow(wanted[0], wanted[1])
          (stage, wait) = (2, 0)
        doAssert wait < 60, "the click did not switch to density"
      of 2:
        if f.theme.mode == tmLight and f.windowSize == wanted and wait > 3:
          f.stop()
        doAssert wait < 60, "no light theme, or no new size: " & $f.windowSize
      else: discard
    doAssert run(RunOptions(maxFrames: 600, persist: true, configDir: some(config),
      logDir: some(logs), openPaths: @[file], onFrame: onFrame)) == 0
    doAssert stage == 2, "the first run stopped at stage " & $stage
  let saved = readFile(config / SettingsFileName)
  doAssert "(theme \"everforest-light\")" in saved and "(mode density)" in saved, saved
  doAssert "(width 1500)" in saved and "(height 900)" in saved, saved
  block secondRun:
    var stage = 0
    var wait = 0
    var at: Vec2
    proc onFrame(f: FrameInfo) =
      inc wait
      case stage
      of 0:
        if wait == 3:
          doAssert f.theme.mode == tmLight, "the theme was not restored"
          doAssert f.windowSize == wanted, "the size was not restored: " & $f.windowSize
          let recent = f.markOf("plot.recent 0")
          doAssert recent.size.x > 0, "no recent file on the start screen"
          at = recent.centre
          f.moveMouse(at)
        if wait == 5: f.pressMouse(at, true)
        if wait == 6:
          f.pressMouse(at, false)
          (stage, wait) = (1, 0)
      of 1:
        if f.laidOut:
          doAssert f.core.sessions[0].path == file
          doAssert f.mode == dmDensity, "the plot did not start as density"
          f.stop()
          stage = 2
        doAssert wait < 200, "the recent file did not open"
      else: discard
    doAssert run(RunOptions(maxFrames: 600, persist: true, configDir: some(config),
      logDir: some(logs), onFrame: onFrame)) == 0
    doAssert stage == 2, "the second run stopped at stage " & $stage
  # Both runs are in this process, perhaps in one second: one log file or two.
  var logged = ""
  for kind, f in walkDir(logs):
    if f.extractFilename.startsWith(SessionLogPrefix): logged.add readFile(f)
  doAssert logged.count("Opened " & file.extractFilename) == 2, logged
