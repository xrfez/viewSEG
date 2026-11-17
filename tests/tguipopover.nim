## The plot's gear popover in the running frontend, headless, at 125 % in a
## window of 1152 x 720 pixels (what a 1280 x 800 laptop screen opens), driven
## by real clicks and typing:
##
## - the strip, six lines at this size, scrolls above the plot, which keeps
##   its room (`tguismall`): the gear is scrolled to;
## - it is in tabs (Look, Traces, Scales), and each tab is inside the
##   window: past its edge the popover would be a window of the desktop's
##   own, cut at the screen's edge;
## - an unticked checkbox in it ("Hide killed traces") shows: its box is
##   drawn in a colour of its own, not the popover's background;
## - a preset is deleted, and another renamed, from its right-click menu
##   without the plot being drawn as it first: the display stays as it was;
##   the new name is typed into the menu itself (one trip).
##
## Seen to fail: with the popover in its three columns (as it was), held
## to the window's size, "Look: 1152.0 x 605.0, cut to the window" (the
## review measured it 1 207 wide in this window, at 100 %); with the theme's
## frames the colour of the popover in the dark theme (as they were), "the
## unticked box: 0 of 729 pixels off the popover's background"; with a
## right-click applying the preset (`command(paApply, ...)` when the menu
## opens), "deleted from its menu: the display changed"; with the menu's
## Rename taking the name from the box below (as it was), "plot.preset menu
## name is not shown".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, options, os]
import viewSEG/core/[displaypresets, geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/fixtures

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc display(f: FrameInfo): DisplaySettings = f.panel.layers[0].display

proc complete(f: FrameInfo): bool =
  let t = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and t.len > 0 and t[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

proc presetNames(f: FrameInfo): seq[string] =
  for p in f.core.settings.displayPresets: result.add p.name

proc main*() =

  if getEnv("SDL_VIDEO_DRIVER") notin ["", "x11"]:
    # SDL's X11 driver takes its content scale from SDL_VIDEO_X11_SCALING_FACTOR
    echo "tguipopover: skipped (SDL_VIDEO_DRIVER=", getEnv("SDL_VIDEO_DRIVER"), ")"
    quit 0

  withFixtures fx:
    let file = fx.surveySegy()
    let config = fx.dir / "config"
    var steps: seq[Step]
    var pointAt: Vec2
    var before: DisplaySettings
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    proc click(mark: string; button = 1) =
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = r.centre
        f.moveMouse(pointAt), after(2))
      step("click " & mark, proc (f: FrameInfo) =
        f.pressMouse(pointAt, true, button)
        f.pressMouse(pointAt, false, button), after(3))
    proc key(k: SimKey) =
      step("key " & $k, proc (f: FrameInfo) =
        f.pressKey(k, true)
        f.pressKey(k, false), after(3))
    proc typeInto(mark, text: string; enter: bool) =
      ## Clicks the box, empties it (End, then Backspace) and types `text`.
      click(mark)
      key(skEnd)
      for i in 0 ..< 12: key(skBackspace)
      step("type " & text & " into " & mark, proc (f: FrameInfo) =
        doAssert f.typing, mark & " does not take the keys"
        f.typeText(text), after(2))
      if enter: key(skEnter)
    proc inside(what: string): proc (f: FrameInfo): bool =
      result = proc (f: FrameInfo): bool =
        let pop = f.markOf("plot.more popover")
        result = pop.size.x > 0
        if result:
          doAssert pop.pos.x >= 0 and pop.pos.y >= 0 and
            pop.pos.x + pop.size.x <= float32(f.width) and
            pop.pos.y + pop.size.y <= float32(f.height),
            what & ": the popover leaves the window: x " & $pop.pos.x & " to " &
            $(pop.pos.x + pop.size.x) & " of " & $f.width & ", y " & $pop.pos.y & " to " &
            $(pop.pos.y + pop.size.y) & " of " & $f.height
          echo "tguipopover: ", what, ": ", pop.size.x, " x ", pop.size.y, " in ", f.width,
            " x ", f.height
          # held to the window's size, a popover too large for it would be cut
          doAssert pop.size.x <= 0.75 * float32(f.width) and
            pop.size.y <= 0.9 * float32(f.height), what & ": " & $pop.size.x & " x " &
            $pop.size.y & ", cut to the window"

    step("the record", noop, proc (f: FrameInfo): bool =
      result = f.complete
      if result:
        doAssert abs(f.scale - 1.25) < 0.01, "the scale is " & $f.scale
        doAssert f.width >= 1150 and f.width <= 1154, "the window is " & $f.width & " wide")
    # at this size the strip's six lines scroll above the plot (which keeps
    # its room): the gear, on the last one, is scrolled to with the wheel
    step("the gear in view", noop, proc (f: FrameInfo): bool =
      let (strip, gear) = (f.markOf("plot.strip scrolls"), f.markOf("plot.more"))
      result = gear.size.y > 0 and (strip.size.y == 0 or (gear.pos.y >= strip.pos.y and
        gear.pos.y + gear.size.y <= strip.pos.y + strip.size.y))
      if not result and strip.size.y > 0:
        f.moveMouse(strip.centre)
        f.scrollWheel(strip.centre, -1))
    click("plot.more")
    step("Look", noop, inside("Look"))
    click("plot.more tab traces")
    step("Traces", noop, inside("Traces"))
    step("the unticked box", noop, proc (f: FrameInfo): bool =
      let r = f.markOf("plot.more.hide killed")
      result = r.size.x > 0
      if result:
        doAssert not f.core.settings.hideKilled
        let pixels = f.readFrame()
        let side = int(r.size.y) # the box is as high as the line, at its left
        let bg = f.theme.roles[rlPopup]
        var off, seen = 0
        for y in int(r.pos.y) + 2 ..< int(r.pos.y) + side - 2:
          for x in int(r.pos.x) + 2 ..< int(r.pos.x) + side - 2:
            inc seen
            if distance(pixels[y * f.width + x], bg) >= 8: inc off
        doAssert seen > 0 and off * 2 > seen, "the unticked box: " & $off & " of " & $seen &
          " pixels off the popover's background")
    click("plot.more tab scales")
    step("Scales", noop, inside("Scales"))
    click("plot.more tab look")
    typeInto("plot.preset name", "First", enter = true)
    step("First saved", noop, proc (f: FrameInfo): bool = f.presetNames == @["First"])
    proc another(f: FrameInfo) =
      var d = f.display
      d.mode = dmDensity
      d.gain = dgAgc
      d.colourMap = cmViridis
      f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    step("another display", another, proc (f: FrameInfo): bool =
      f.display.gain == dgAgc and f.complete)
    typeInto("plot.preset name", "Second", enter = true)
    step("Second saved", noop, proc (f: FrameInfo): bool =
      result = f.presetNames == @["First", "Second"]
      if result:
        var d = f.display
        d.colourMap = cmRedBlack # shown as neither preset
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        before = d)
    click("plot.preset.First", button = 3)
    step("the menu", noop, proc (f: FrameInfo): bool =
      result = f.markOf("plot.preset menu delete").size.x > 0
      if result: doAssert f.display.sameLook(before), "right-clicked: the display changed")
    click("plot.preset menu delete")
    step("deleted from its menu", noop, proc (f: FrameInfo): bool =
      result = f.presetNames == @["Second"]
      if result: doAssert f.display.sameLook(before), "deleted from its menu: the display changed")
    # renamed in one trip: the new name typed into the menu itself, Enter
    click("plot.preset.Second", button = 3)
    typeInto("plot.preset menu name", "Third", enter = true)
    step("renamed from its menu", noop, proc (f: FrameInfo): bool =
      result = f.presetNames == @["Third"]
      if result: doAssert f.display.sameLook(before), "renamed from its menu: the display changed")
    key(skEscape)

    var at = 0
    var started = false
    var wait = 0
    var failed = ""
    proc onFrame(f: FrameInfo) =
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if not started:
        steps[at].act(f)
        started = true
        wait = 0
      else:
        inc wait
        if wait >= 2 and steps[at].done(f):
          inc at
          started = false
        elif wait > 400:
          var said = ""
          for m in f.messages: said.add m.text & " | "
          failed = steps[at].name & " did not happen (presets " & $f.presetNames & "; " & said &
            ")"
          f.stop()
    putEnv("SDL_VIDEO_X11_SCALING_FACTOR", "1.25")
    let code = run(RunOptions(maxFrames: 6000, persist: true, configDir: some(config),
      logDir: some(config / "logs"), openPaths: @[file], windowSize: (922, 576),
      theme: forceDark, userThemeDir: some(config / "no-user-themes"),
      indexCacheDir: some(config / "cache"), onFrame: onFrame))
    delEnv("SDL_VIDEO_X11_SCALING_FACTOR")
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguipopover: ok"

when isMainModule:
  main()
