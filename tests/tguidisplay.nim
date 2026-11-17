## The display controls of the gear popover and the gain drop-down in the
## running frontend, headless, driven by real clicks and typing at the
## default window size (1280 x 800), each checked against the CPU reference
## of the plot's image (`utils/plotref`) and against reads from the file:
##
## - Density colour map: the four maps are in the popover, which fits the
##   window (it is laid out in columns) and stays inside it (opened from the
##   gear near the middle of the window, it is moved left; past the window's
##   edge it would be a window of the desktop's own); a click on viridis's
##   bar, then on the name Red-black, draws
##   density in that map (no pixel off the reference, the map's colours
##   among the pixels), with nothing read again (the same tiles, no new
##   request);
## - Display presets: a name typed and Enter saves the display shown; after
##   the display is changed, a click on the preset draws it again (mode,
##   map, gain), from the samples at hand; the plot turned time across is
##   drawn in the map too;
## - the clip percentile typed into the gain drop-down (95) lowers the
##   reference to the record's 95th percentile, the new tile made from the
##   reader's samples (no prefetch chunk), and the image is what the
##   reference draws with it;
## - a second run in the same settings folder has the preset and the map.
##
## Seen to fail: with the popover in one column (as it was), "the popover
## does not fit" (1074 pixels tall); with the popover placed where Dear
## ImGui puts it (at the pointer), "the popover leaves the window" (x 383 to
## 1597); with the frame's colour map left out
## (`colourMap` not given to `PlotFrame`), "viridis: 35258 of 35258 pixels
## off the reference";
## with the clip percentile box's value not sent (`p.send` left out),
## "clip at 95 did not happen"; with the presets left out of the settings
## file, "saved did not happen" (a change the settings file does not hold
## is none). The second run starts with the pointer where the first left it
## (an X server not reset between runs keeps it), over trace 5, whose edge
## falls on a pixel's centre, drawn as either trace row by row: with that
## allowed for in `utils/plotref` left out, "second run: 67 of 35258 pixels
## off the reference" (the column on the edge).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, plotref, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc display(f: FrameInfo): DisplaySettings = f.panel.layers[0].display

proc tiles(f: FrameInfo): seq[Tile] = f.core.tiles(f.core.findPanel(MainPanel))

proc complete(f: FrameInfo): bool =
  ## The newest request answered and its picture drawn.
  let t = f.tiles
  f.panel.laidOut and t.len > 0 and t[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen and
    f.tracePanel.drawnView.sameSpans(f.panel.view)

proc found(s: Shot; c: Rgba; tol = 12): int =
  for p in s.image:
    if distance(p, c) <= tol: inc result

proc offReference(f: FrameInfo; what: string) =
  let s = f.capture
  doAssert s.display.colourMap == f.display.colourMap
  let (bad, seen) = s.mismatches()
  doAssert bad == 0, what & ": " & $bad & " of " & $seen & " pixels off the reference"

proc runSteps(name: string; config, file: string; steps: seq[Step]) =
  var at = 0
  var started = false
  var wait = 0 # frames since the step's action, at `since`
  var since = getMonoTime()
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
      if wait >= 2 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 400, since):
        failed = name & ": " & steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(persist: true, configDir: some(config),
    logDir: some(config / "logs"), openPaths: @[file], windowSize: (1280, 800),
    theme: forceDark, userThemeDir: some(config / "no-user-themes"),
    indexCacheDir: some(config / "cache"), onFrame: onFrame))
  doAssert code == 0, name & ": run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, name & ": stopped at " & steps[min(at, steps.high)].name

proc main*() =

  withFixtures fx:
    let file = fx.surveySegy()
    let config = fx.dir / "config"
    var steps: seq[Step]
    var pointAt: Vec2
    var ids: seq[uint64]
    var gen: uint64
    var reference = NaN
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    proc click(mark: string) =
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = r.centre
        f.moveMouse(pointAt), after(2))
      step("click " & mark, proc (f: FrameInfo) =
        f.pressMouse(pointAt, true)
        f.pressMouse(pointAt, false), after(3))
    proc key(k: SimKey) =
      step("key " & $k, proc (f: FrameInfo) =
        f.pressKey(k, true)
        f.pressKey(k, false), after(3))
    proc typeInto(mark, text: string) =
      click(mark)
      step("type " & text & " into " & mark, proc (f: FrameInfo) =
        doAssert f.typing, mark & " does not take the keys"
        f.pressKey(skCtrl, true, {smCtrl})
        f.typeText("a")
        f.pressKey(skCtrl, false)
        f.typeText(text), after(2))
      key(skEnter)
    proc held(f: FrameInfo) =
      ## Notes the tiles shown and the request, to see that nothing is read.
      ids.setLen 0
      for t in f.tiles: ids.add t.id
      gen = f.panel.requestGen
    proc nothingRead(f: FrameInfo; what: string) =
      var now: seq[uint64]
      for t in f.tiles: now.add t.id
      doAssert now == ids and f.panel.requestGen == gen, what & " read again"
    proc onlyCached(f: FrameInfo; what: string) =
      for t in f.tiles:
        if t.id notin ids:
          doAssert t.cached and t.chunks == 0, what & ": a tile read from the file"

    # ------------------------------------------------------------ first run --
    step("density, no gain", noop, proc (f: FrameInfo): bool =
      result = f.complete
      if result:
        var d = f.display
        doAssert d.colourMap == cmGrey and d.clipPercentile == 99
        d.mode = dmDensity
        d.gain = dgNone
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d))
    step("drawn in grey", noop, proc (f: FrameInfo): bool =
      result = f.complete and f.display.mode == dmDensity and not f.panel.reference.isNaN
      if result:
        f.offReference("grey")
        f.held())
    click("plot.more")
    step("the colour maps", noop, proc (f: FrameInfo): bool =
      result = f.markOf("plot.colour map.viridis").size.x > 0
      if result:
        let pop = f.markOf("plot.more popover")
        doAssert pop.size.x <= 1280 and pop.size.y <= 800, "the popover does not fit: " & $pop
        # inside the main window, though the gear is near the middle of it:
        # past its edge the popover would be a window of the desktop's own
        doAssert pop.pos.x >= 0 and pop.pos.y >= 0 and pop.pos.x + pop.size.x <= 1280 and
          pop.pos.y + pop.size.y <= 800, "the popover leaves the window: " & $pop
        for m in ColourMap:
          let r = f.markOf("plot.colour map." & $m)
          doAssert r.size.x > 0 and r.pos.y >= pop.pos.y and
            r.pos.y + r.size.y <= pop.pos.y + pop.size.y, $m & " is not in the popover: " & $r)
    click("plot.colour map." & $cmViridis)
    step("viridis", noop, proc (f: FrameInfo): bool =
      result = f.display.colourMap == cmViridis and f.complete
      if result:
        f.offReference("viridis")
        f.nothingRead("viridis")
        doAssert f.capture.found(lutOf(cmViridis)[255]) > 0, "no yellow")
    click("plot.colour map name." & $cmRedBlack)
    step("red-black", noop, proc (f: FrameInfo): bool =
      result = f.display.colourMap == cmRedBlack and f.complete
      if result:
        f.offReference("red-black")
        f.nothingRead("red-black")
        let s = f.capture
        doAssert s.found(lutOf(cmRedBlack)[0]) > 0 and s.found(lutOf(cmRedBlack)[255]) > 0,
          "red-black: no red or no black")
    typeInto("plot.preset name", "Section")
    step("saved", noop, proc (f: FrameInfo): bool =
      result = f.core.settings.displayPresets.len == 1
      if result:
        doAssert f.core.settings.displayPresets[0].name == "Section"
        doAssert f.core.keptSettings.displayPresets.len == 1)
    key(skEscape)
    proc another(f: FrameInfo) =
      var d = f.display
      d.mode = dmWiggle
      d.colourMap = cmGrey
      d.gain = dgAgc
      f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    step("another display", another, proc (f: FrameInfo): bool =
      result = f.complete and f.display.gain == dgAgc
      if result: f.held())
    click("plot.more")
    click("plot.preset.Section")
    step("the preset again", noop, proc (f: FrameInfo): bool =
      let d = f.display
      result = d.mode == dmDensity and d.colourMap == cmRedBlack and d.gain == dgNone and
        f.complete
      if result:
        f.offReference("the preset")
        f.onlyCached("the preset"))
    key(skEscape)
    proc turn(o: Orientation): proc (f: FrameInfo) =
      result = proc (f: FrameInfo) =
        var d = f.display
        d.orientation = o
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    step("time across", turn(orTimeAcross), proc (f: FrameInfo): bool =
      result = f.display.orientation == orTimeAcross and f.complete and
        f.tracePanel.drawnView.columns == f.panel.view.columns
      if result: f.offReference("red-black, time across"))
    step("time down", turn(orTimeDown), proc (f: FrameInfo): bool =
      result = f.display.orientation == orTimeDown and f.complete
      if result:
        reference = f.panel.reference
        f.held())
    click("plot.gain")
    step("the clip box", noop, proc (f: FrameInfo): bool =
      f.markOf("plot.gain clip percentile").size.x > 0)
    typeInto("plot.gain clip percentile", "95")
    step("clip at 95", noop, proc (f: FrameInfo): bool =
      result = f.display.clipPercentile == 95 and f.complete and
        f.panel.reference < 0.95 * reference
      if result:
        f.onlyCached("clip at 95")
        doAssert f.tiles[^1].id notin ids, "no new tile"
        f.offReference("clip at 95"))
    key(skEscape)
    runSteps("first run", config, file, steps)

    # ----------------------------------------------------------- second run --
    steps.setLen 0
    var steady = 0
    # the pointer off the plot: where the first run left it, it could hover
    # the trace whose edge a pixel's centre falls on, where the CPU reference
    # and the GPU may each take the other trace
    proc away(f: FrameInfo) = f.moveMouse(vec2(2, 2))
    step("second run", away, proc (f: FrameInfo): bool =
      steady = if f.complete and f.core.selection.hover < 0: steady + 1 else: 0
      result = steady > 5
      if result:
        doAssert f.core.settings.displayPresets.len == 1, "second run: no preset"
        let d = f.display
        doAssert d.colourMap == cmRedBlack and d.clipPercentile == 95 and d.mode == dmDensity
        f.offReference("second run"))
    runSteps("second run", config, file, steps)
    echo "tguidisplay: colour maps, a preset and the clip percentile, by hand, kept"

when isMainModule:
  main()
