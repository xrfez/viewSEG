## The map's filters in the running frontend, headless, with real clicks:
## `mapSps`'s S, R and X files and the SEG-D shot of source 1003 of line 1
## with every `MapDefect` planted.
##
## - In the Layers popover, under "Filters: the record shown", ticking
##   "dead in the headers", "noisy" and "missing from the template" marks
##   their points with a ring in each filter's colour, and each line says
##   its count once the record is read: the receiver marked dead, the noisy
##   one, and the two receivers the template plans that the record lacks;
##   a receiver beside them is not ringed.
## - The point under the pointer says which filters mark it.
## - Select selects the filter's traces in the plot.
##
## Seen to fail: with no style given for the filters' sets (so they are not
## drawn), "ringed" found no ring of the dead filter's colour at (1, 2).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves map-filters-*.png there.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/[maplayers, theme]
import utils/[fixtures, waiting]

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

proc main() =
  withFixtures fx:
    let sps = fx.mapSps()
    let shotPath = fx.mapShotSegd(0, 2, {MapDefect.low .. MapDefect.high})
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
    proc click(f: FrameInfo; p: Vec2) =
      f.moveMouse(p)
      f.pressMouse(p, true)
      f.pressMouse(p, false)
    proc receiver(f: FrameInfo; d: tuple[line, k: int]): Vec2 =
      let (x, y) = mapRcv(d.line, d.k)
      let p = f.screen(x, y)
      vec2(round(p.x), round(p.y))
    proc filterTick(f: MapFilter): proc (f: FrameInfo) =
      result = proc (fr: FrameInfo) = fr.click(fr.markOf("map.filter " & $f).tick)
    proc ticked(f: MapFilter): proc (f: FrameInfo): bool =
      # (a proc of its own: a closure made in a loop would see the loop's last value)
      result = proc (fr: FrameInfo): bool = f in fr.core.settings.map.filters

    step("loaded", noop, proc (f: FrameInfo): bool =
      result = f.core.survey.layers.len == 4 and f.core.sessions.len == 1 and
        f.mapWindow.mapShown.isSet and wait > 8 and f.core.jobs.active.len == 0
      if result: ink = mapInk(f.theme, pcPaper))
    step("the Layers popover", proc (f: FrameInfo) =
      f.click(f.markOf("map.layers").centre), proc (f: FrameInfo): bool =
      result = wait > 3 and f.markOf("map.filter " & $mfDead).size.x > 0
      if result: f.shot("map-filters-opened.png"))
    for m in [mfDead, mfNoisy, mfMissing]: step("ticked " & $m, filterTick(m), ticked(m))
    step("counted", noop, proc (f: FrameInfo): bool =
      result = f.core.recordQc.job == NoJob and f.core.recordQc.hits[mfDead].state == fsDone and
        wait > 4
      if result:
        let h = f.core.filterHits
        doAssert h[mfDead].count == 1 and h[mfNoisy].count == 1 and h[mfMissing].count == 2,
          $(h[mfDead].count, h[mfNoisy].count, h[mfMissing].count)
        doAssert filterLabel(mfDead, h[mfDead]) == "Dead in the headers  (1)"
        f.shot("map-filters-popover.png"))
    step("ringed", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false)
      f.moveMouse(vec2(4, 4)), proc (f: FrameInfo): bool =
      result = wait > 4 and f.markOf("map.filter " & $mfDead).size.x == 0
      if result:
        for (m, d) in [(mfDead, MapDefectAt[mdDead]), (mfNoisy, MapDefectAt[mdNoisy]),
            (mfMissing, MapDefectAt[mdMissing]), (mfMissing, MapDefectAt[mdUnplaced])]:
          let c = filterInk(f.theme, m, ink.background)
          doAssert f.ring(f.receiver(d), c) >= 6, $m & " not ringed at " & $d & ": " &
            $f.ring(f.receiver(d), c)
        let c = filterInk(f.theme, mfDead, ink.background)
        doAssert f.ring(f.receiver((1, 3)), c) == 0, "a receiver beside it ringed"
        f.shot("map-filters-ringed.png"))
    step("the point under the pointer says so", proc (f: FrameInfo) =
      f.moveMouse(f.receiver(MapDefectAt[mdDead])), proc (f: FrameInfo): bool =
      result = wait > 4 and f.mapWindow.hoveredPoints.len > 0
      if result:
        doAssert "Marked: " & $mfDead in f.mapWindow.pointTexts, $f.mapWindow.pointTexts)
    step("the popover again", proc (f: FrameInfo) =
      f.click(f.markOf("map.layers").centre), proc (f: FrameInfo): bool =
      wait > 3 and f.markOf("map.filter select " & $mfDead).size.x > 0)
    step("Select", proc (f: FrameInfo) =
      f.click(f.markOf("map.filter select " & $mfDead).centre), proc (f: FrameInfo): bool =
      result = f.core.selection.selected.len == 1 and wait > 2
      if result:
        for t in f.core.selection.selected:
          doAssert t in f.core.filterHits[mfDead].traces)

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
    let code = run(RunOptions(openPaths: @[sps.s, sps.r, fx.mapXps, shotPath],
      windowSize: (1400, 1100), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

main()
