## A shot log with positions as a layer of the map, in the running frontend,
## headless, with real clicks: the survey's S and R files and its seismic file
## are open; a shot log whose X and Y columns place five shots north of the
## survey is imported.
##
## - The Layers popover lists "Shot log" with the log's layer under it; with no
##   shot log loaded it has no such entry.
## - The layer is drawn (the diamonds' colour is found at a shot), and the map's
##   limits, which fit shows, include the shots.
## - Unticking the layer takes the diamonds off the map; ticking it brings them back.
## - Removing the log takes the layer and its entry away.
##
## Seen to fail: with the layer never put in the survey, "the shot log layer was not
## listed"; with `drawn` taking the layer's tick as set, "the shots were still drawn
## after the layer was unticked".
##
## Needs a display: run under `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves map-shotlog-*.png there.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, shotlog, state]
import viewSEG/ui/imgui/app
import viewSEG/view/maplayers
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func same(a, b: Rgba): bool = a.r == b.r and a.g == b.g and a.b == b.b

proc screen(f: FrameInfo; x, y: float64): Vec2 =
  f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, mapPoint(x, y))

proc around(f: FrameInfo; at: Vec2; c: Rgba; reach = 7): int =
  for dy in -reach .. reach:
    for dx in -reach .. reach:
      if same(f.readPixel(int(floor(at.x)) + dx, int(floor(at.y)) + dy), c): inc result

proc centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc tick(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.y / 2), round(r.pos.y + r.size.y / 2))

proc shotEntries(f: FrameInfo; ink: MapInk): seq[MapLayerView] =
  for l in mapLayers(f.core, ink):
    if l.key.kind == mlShotLog: result.add l

proc runMain() =
  withFixtures fx:
    let sps = fx.mapSps()
    let segy = fx.surveySegy()
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    let logPath = fx.dir / "shots.csv"
    const NorthOf = 1400.0 # metres north of the survey's receiver line
    var text = "line,point,x,y,file\n"
    for i in 0 ..< 5:
      text.add "7," & $(100 + i) & "," & $(OriginX + 200.0 * float64(i)) & "," & $(OriginY +
          NorthOf) & "," &
        $(900 + i) & "\n"
    writeFile(logPath, text)
    var map = initShotLogMap()
    map.hasHeader = true
    map.roles = @[crSourceLine, crShotPoint, crX, crY, crFileNumber]
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var ink: MapInk
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc shot(f: FrameInfo; name: string) =
      if shots.len > 0:
        createDir(shots)
        discard f.savePng(shots / name)
    proc click(f: FrameInfo; p: Vec2) =
      f.moveMouse(p)
      f.pressMouse(p, true)
      f.pressMouse(p, false)
    proc drawn(f: FrameInfo): int =
      f.around(f.screen(OriginX + 400.0, OriginY + NorthOf), f.shotEntries(ink)[0].colour, 6)
    proc popoverOpen(f: FrameInfo; mark: string): bool =
      ## Whether the Layers popover shows `mark`; a click that did not open it
      ## (the pointer had not reached the button) is made again.
      result = f.markOf(mark).size.x > 0
      if not result and wait mod 8 == 7: f.click(f.markOf("map.layers").centre)
    proc closePopover(f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false)
    proc closed(f: FrameInfo): bool = wait > 4 and f.markOf("map.shotlogs").size.x == 0

    step("loaded", noop, proc (f: FrameInfo): bool =
      result = f.core.survey.layers.len == 3 and f.mapWindow.mapImagesDrawn > 0 and
        f.mapWindow.mapShown.isSet and wait > 8 and f.core.sessions.len == 1
      if result:
        ink = mapInk(f.theme, pcPaper)
        doAssert f.shotEntries(ink).len == 0)

    step("the popover with no shot log", proc (f: FrameInfo) =
      f.click(f.markOf("map.layers").centre), proc (f: FrameInfo): bool =
      result = wait > 3 and f.popoverOpen("map.group preplot")
      if result: doAssert f.markOf("map.shotlogs").size.x == 0, "an entry with no shot log")
    step("closed", closePopover, proc (f: FrameInfo): bool =
      wait > 4 and f.markOf("map.group preplot").size.x == 0)

    var before: Bounds
    proc importLog(f: FrameInfo) =
      before = f.core.map.limits.bounds
      f.apply Command(kind: ckImportShotLog, logPath: logPath, logMap: map, logMapped: true)
    proc imported(f: FrameInfo): bool =
      result = f.shotEntries(ink).len == 1 and f.core.survey.layers.len == 4 and wait > 8
      if result:
        doAssert f.core.map.limits.bounds.maxY >= OriginY + NorthOf,
          "the fit extent leaves the shots out"
        doAssert f.core.map.limits.bounds.maxY > before.maxY
    step("the log imported", importLog, imported)

    proc fitted(f: FrameInfo): bool =
      result = wait > 8
      if result:
        doAssert f.drawn > 0, "the shots were not drawn"
        f.shot("map-shotlog-drawn.png")
    step("fit", proc (f: FrameInfo) = f.click(f.markOf("map.fit").centre), fitted)

    step("the Layers popover lists the layer", proc (f: FrameInfo) =
      f.click(f.markOf("map.layers").centre), proc (f: FrameInfo): bool =
      result = wait > 3 and f.popoverOpen("map.shotlogs")
      if result:
        let head = f.markOf("map.shotlogs")
        let own = f.markOf("map.layer shots sources")
        doAssert own.size.x > 0, "the shot log layer was not listed"
        doAssert own.pos.y > head.pos.y and own.pos.x > head.pos.x, "under its heading"
        f.shot("map-shotlog-popover.png"))

    step("unticked", proc (f: FrameInfo) =
      f.click(f.markOf("map.layer shots sources").tick), proc (f: FrameInfo): bool =
      not f.shotEntries(ink)[0].own)
    step("hidden", closePopover, proc (f: FrameInfo): bool =
      result = f.closed
      if result: doAssert f.drawn == 0, "the shots were still drawn after the layer was unticked")
    step("the popover again", proc (f: FrameInfo) =
      f.click(f.markOf("map.layers").centre), proc (f: FrameInfo): bool =
      wait > 3 and f.popoverOpen("map.layer shots sources"))
    step("ticked", proc (f: FrameInfo) =
      f.click(f.markOf("map.layer shots sources").tick), proc (f: FrameInfo): bool =
      f.shotEntries(ink)[0].own)
    step("shown again", closePopover, proc (f: FrameInfo): bool =
      result = f.closed
      if result: doAssert f.drawn > 0, "the shots did not come back")

    proc removed(f: FrameInfo): bool =
      result = f.shotEntries(ink).len == 0 and f.core.survey.layers.len == 3 and wait > 4
      if result:
        doAssert f.core.map.limits.bounds.maxY <= before.maxY + 1,
          "the extent still holds the shots"
    proc removeLog(f: FrameInfo) = f.apply Command(kind: ckRemoveShotLog, logIndex: 0)
    step("the log removed", removeLog, removed)

    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
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
        elif overdue(wait, 600, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(openPaths: @[sps.s, sps.r, segy],
      windowSize: (1400, 900), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc main*() =
  runMain()

when isMainModule:
  main()
