## What the user sets in the running program survives a restart, headless:
## a first run (with its settings in a folder of its own) opens a file,
## switches the plot to density with a real click, picks the light theme as
## View > Theme does, makes the window larger, and drags the splitter
## between the plot and the Headers window with the mouse, then quits. The
## second run starts in the light theme at that size, with the windows
## where they were, lists the file on its start screen, and a real click
## there opens it as density. Then it saves the arrangement under a name,
## resets the layout (the Headers window goes back to its share of the
## width), and loads the saved one (it comes back). Both runs write their session
## log.
##
## Seen to fail: with `initUi` ignoring the settings' theme, the second run
## was dark; with `createMainWindow` ignoring the saved size, it was 1280 x
## 800; with the start screen not listing recent files, "no recent file";
## with `layout.nif` not applied at start, the Headers window came back 71
## pixels narrower; with `followLayouts` not arranging the windows, the
## loaded layout left them as the reset put them.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/[app, symbols]
import utils/[fixtures, waiting]

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

func near(a, b: Rect): bool =
  abs(a.pos.x - b.pos.x) <= 1 and abs(a.pos.y - b.pos.y) <= 1 and
    abs(a.size.x - b.size.x) <= 1 and abs(a.size.y - b.size.y) <= 1

proc mode(f: FrameInfo): DisplayMode =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  if p.layers.len == 0: dmWiggle else: p.layers[0].display.mode

proc laidOut(f: FrameInfo): bool =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  p.layers.len > 0 and p.laidOut and f.markOf("plot.data").size.x > 0

proc main*() =

  withFixtures fx:
    let file = fx.surveySegy()
    let config = fx.dir / "config"
    let logs = fx.dir / "logs"
    let wanted = (1500, 900)
    const drag = 150'f32
    var arranged: (Rect, Rect) # the plot and the Headers window when the first run quit
    block firstRun:
      var stage = 0
      var wait = 0 # frames since the stage began, at `since`
      var since = getMonoTime()
      var at: Vec2
      var tableBefore: Rect
      proc onFrame(f: FrameInfo) =
        inc wait
        template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
        case stage
        of 0: # the file shown: click "density"
          if f.laidOut and wait > 3:
            doAssert f.mode == dmWiggle
            at = f.markOf("plot." & $syDensity).centre
            f.moveMouse(at)
            next 1
        of 1:
          if wait == 2: f.pressMouse(at, true)
          if wait == 3: f.pressMouse(at, false)
          if f.mode == dmDensity:
            f.chooseTheme("everforest-light")
            f.resizeWindow(wanted[0], wanted[1])
            next 2
          doAssert not overdue(wait, 60, since), "the click did not switch to density"
        of 2:
          if f.theme.mode == tmLight and f.windowSize == wanted and wait > 3:
            # The splitter: the gap between the plot window and the Headers window.
            let plot = f.markOf("seismic")
            tableBefore = f.markOf("headers")
            doAssert tableBefore.pos.x > plot.pos.x + plot.size.x, "the Headers window is not right"
            at = vec2(round((plot.pos.x + plot.size.x + tableBefore.pos.x) / 2),
              round(tableBefore.pos.y + tableBefore.size.y / 2))
            f.moveMouse(at)
            next 3
          doAssert not overdue(wait, 60, since), "no light theme, or no new size: " & $f.windowSize
        of 3: # drag it to the left, in steps, as a hand would
          if wait == 2: f.pressMouse(at, true)
          if wait in 3..8: f.moveMouse(vec2(at.x - drag * float32(wait - 2) / 6, at.y))
          if wait == 10: f.pressMouse(vec2(at.x - drag, at.y), false)
          if wait == 14:
            let table = f.markOf("headers")
            doAssert abs(table.size.x - (tableBefore.size.x + drag)) <= 2,
              "the drag did not widen the Headers window: " & $tableBefore & " -> " & $table
            arranged = (f.markOf("seismic"), table)
            f.stop()
            stage = 4
        else: discard
        doAssert stage > 0 or not overdue(wait, 400, since), "the file was not shown"
      doAssert run(RunOptions(persist: true, configDir: some(config),
        logDir: some(logs), openPaths: @[file], onFrame: onFrame)) == 0
      doAssert stage == 4, "the first run stopped at stage " & $stage
    let saved = readFile(config / SettingsFileName)
    doAssert "(theme \"everforest-light\")" in saved and "(mode density)" in saved, saved
    doAssert "(width 1500)" in saved and "(height 900)" in saved, saved
    doAssert fileExists(config / LayoutFileName), "no layout saved"
    block secondRun:
      var stage = 0
      var wait = 0 # frames since the stage began, at `since`
      var since = getMonoTime()
      var at: Vec2
      var reset: Rect
      proc onFrame(f: FrameInfo) =
        inc wait
        template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
        case stage
        of 0:
          if wait == 3:
            doAssert f.theme.mode == tmLight, "the theme was not restored"
            doAssert f.windowSize == wanted, "the size was not restored: " & $f.windowSize
            doAssert near(f.markOf("seismic"), arranged[0]) and
              near(f.markOf("headers"), arranged[1]), "the windows are not where they were: " &
              $f.markOf("headers") & ", not " & $arranged[1]
            let recent = f.markOf("plot.recent 0")
            doAssert recent.size.x > 0, "no recent file on the start screen"
            at = recent.centre
            f.moveMouse(at)
          if wait == 5: f.pressMouse(at, true)
          if wait == 6:
            f.pressMouse(at, false)
            next 1
        of 1:
          if f.laidOut:
            doAssert f.core.sessions[0].path == file
            doAssert f.mode == dmDensity, "the plot did not start as density"
            # Save the arrangement under a name (as the "Save layout" popup does), then reset.
            f.apply Command(kind: ckLayout, arrangement: f.layoutText)
            f.apply Command(kind: ckSaveLayout, layoutName: "Mine")
            f.resetLayout()
            next 2
          doAssert not overdue(wait, 200, since), "the recent file did not open"
        of 2:
          if wait == 4:
            reset = f.markOf("headers")
            doAssert abs(reset.size.x - arranged[1].size.x) > 50,
              "the reset left the Headers window as it was: " & $reset
            doAssert f.core.layouts.len >= 1 and f.core.layouts[0].name == "Mine"
            f.apply Command(kind: ckLoadLayout, docPath: f.core.layouts[0].path)
            next 3
        of 3:
          if wait > 3 and near(f.markOf("headers"), arranged[1]):
            f.stop()
            stage = 4
          doAssert not overdue(wait, 100, since), "the loaded layout did not come back: " &
            $f.markOf("headers")
        else: discard
      doAssert run(RunOptions(persist: true, configDir: some(config),
        logDir: some(logs), onFrame: onFrame)) == 0
      doAssert stage == 4, "the second run stopped at stage " & $stage
    # Both runs are in this process, perhaps in one second: one log file or two.
    var logged = ""
    for kind, f in walkDir(logs):
      if f.extractFilename.startsWith(SessionLogPrefix): logged.add readFile(f)
    doAssert logged.count("Opened " & file.extractFilename) == 2, logged
    doAssert "Layout \"Mine\" loaded." in logged

when isMainModule:
  main()
