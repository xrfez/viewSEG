## The map's first-break filters in the running frontend, headless, with real clicks:
## `breakfiles`' shot (48 traces along a line east of the source, the coordinates in the
## headers), whose trace 20's data arrive 80 ms late.
##
## - In the Layers popover, at the end of "Filters: the record shown", "first break off the
##   model" and "first break off its neighbours" are listed with their marks; ticked, each says
##   its count once the overlay's picks are made, the same as the core's, and the overlay stays
##   off on the plot.
## - Trace 20's receiver is marked in the filters' colour; trace 5's is not.
## - The point under the pointer says the filter marks it; Select selects its traces.
##
## Seen to fail: with the filters asking for no first-break job while the overlay is off,
## "counted did not happen" (they stayed computing).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves map-breaks-ringed.png, and geomflag.png (the whole display,
## where the popover shows the filter list's end; it needs `scrot`), there.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/[maplayers, theme]
import utils/[breakfiles, fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

proc screen(f: FrameInfo; x, y: float64): Vec2 =
  f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, mapPoint(x, y))

proc centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc tick(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.y / 2), round(r.pos.y + r.size.y / 2))

func same(a, b: Rgba): bool = a.r == b.r and a.g == b.g and a.b == b.b

proc ring(f: FrameInfo; at: Vec2; c: Rgba): int =
  ## The pixels of colour `c` between 3 and 9 pixels from `at`.
  for dy in -9 .. 9:
    for dx in -9 .. 9:
      let d = hypot(float(dx), float(dy))
      if d >= 3 and d <= 9 and same(f.readPixel(int(round(at.x)) + dx,
          int(round(at.y)) + dy), c): inc result

const Clear = 5 ## a trace neither filter marks

proc runMain() =
  withFixtures fx:
    let path = fx.shotSegy("shot.sgy", gCoordinates)
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0 # frames since the step began, at `since`
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
    proc desktop(f: FrameInfo; name: string) =
      ## The whole display, where an open popover (a window of its own) shows.
      if shots.len > 0:
        createDir(shots)
        discard execShellCmd("scrot -o " & quoteShell(shots / name))
    proc click(f: FrameInfo; p: Vec2) =
      f.moveMouse(p)
      f.pressMouse(p, true)
      f.pressMouse(p, false)
    proc receiver(f: FrameInfo; trace: int): Vec2 =
      # (`shotSegy`'s coordinates: the source at (1000, 500), the receivers east of it)
      let p = f.screen(1000.0 + offsetOf(trace), 500.0)
      vec2(round(p.x), round(p.y))
    proc filterTick(f: MapFilter): proc (f: FrameInfo) =
      result = proc (fr: FrameInfo) = fr.click(fr.markOf("map.filter " & $f).tick)
    proc ticked(f: MapFilter): proc (f: FrameInfo): bool =
      # (a proc of its own: a closure made in a loop would see the loop's last value)
      result = proc (fr: FrameInfo): bool =
        f in fr.core.settings.map.filters

    step("loaded", noop, proc (f: FrameInfo): bool =
      result = f.core.sessions.len == 1 and f.mapWindow.mapShown.isSet and wait > 8 and
        f.core.jobs.active.len == 0
      if result: ink = mapInk(f.theme, pcPaper))
    step("the Layers popover", proc (f: FrameInfo) =
      f.click(f.markOf("map.layers").centre), proc (f: FrameInfo): bool =
      wait > 3 and f.markOf("map.filter " & $mfDead).size.x > 0)
    step("scrolled to the list's end", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("map.filter " & $mfDead).centre), proc (f: FrameInfo): bool =
      # (the popover is a window of its own: the pointer rests on it, then the wheel turns)
      if wait in 4 .. 14: f.scrollWheel(f.markOf("map.filter " & $mfDead).centre, -3)
      wait > 18 and f.markOf("map.filter " & $mfBreakOffNeighbours).size.x > 0 and
        f.markOf("map.filter " & $mfBreakOffNeighbours).pos.y < 1000)
    step("the first-break filters listed", noop, proc (f: FrameInfo): bool =
      result = true
      for m in BreakFilters:
        doAssert f.markOf("map.filter mark " & $m).size.x > 0, "no mark for " & $m)
    for m in BreakFilters: step("ticked " & $m, filterTick(m), ticked(m))
    step("counted", noop, proc (f: FrameInfo): bool =
      let h = f.core.filterHits
      result = f.core.jobs.active.len == 0 and h[mfBreakOffModel].state == fsDone and
        h[mfBreakOffNeighbours].state == fsDone and wait > 4
      if result:
        let base = f.core.sessions[0].base
        doAssert base + PlantedTrace in h[mfBreakOffModel].traces, $h[mfBreakOffModel]
        doAssert base + Clear notin h[mfBreakOffModel].traces and
          base + Clear notin h[mfBreakOffNeighbours].traces
        for m in BreakFilters:
          doAssert filterLabel(m, h[m]).endsWith("  (" & $h[m].count & ")"), filterLabel(m, h[m])
        let k = f.core.findPanel(MainPanel)
        doAssert not f.core.panels[k].layers[0].display.firstBreaks, "the overlay came on"
        f.desktop("geomflag.png"))
    step("Select", proc (f: FrameInfo) =
      f.click(f.markOf("map.filter select " & $mfBreakOffModel).centre),
      proc (f: FrameInfo): bool =
      let h = f.core.filterHits[mfBreakOffModel]
      result = f.core.selection.selected.len == h.traces.len and wait > 2
      if result:
        for t in f.core.selection.selected: doAssert t in h.traces)
    step("ringed", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false)
      f.moveMouse(vec2(4, 4)), proc (f: FrameInfo): bool =
      result = wait > 4 and f.markOf("map.filter " & $mfBreakOffModel).size.x == 0
      if result:
        let c = filterInk(f.theme, mfBreakOffModel, ink.background)
        doAssert f.ring(f.receiver(PlantedTrace), c) >= 6, "no mark round trace " &
          $PlantedTrace & ": " & $f.ring(f.receiver(PlantedTrace), c)
        doAssert f.ring(f.receiver(Clear), c) == 0, "trace " & $Clear & " ringed"
        f.shot("map-breaks-ringed.png"))
    step("the point under the pointer says so", proc (f: FrameInfo) =
      f.moveMouse(f.receiver(PlantedTrace)), proc (f: FrameInfo): bool =
      result = wait > 4 and f.mapWindow.hoveredPoints.len > 0
      if result:
        doAssert "Marked: " & $mfBreakOffModel in f.mapWindow.pointTexts,
            $f.mapWindow.pointTexts)

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
    let code = run(RunOptions(openPaths: @[path], windowSize: (1400, 1100), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc main*() =

  runMain()

when isMainModule:
  main()
