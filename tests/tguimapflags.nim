## The map's marks of what its filters found, in the running frontend,
## headless: `mapSps`'s S, R and X files, its SEG-D shot of source 1003 of
## line 1 with `MapDefect`s planted, and one receiver 60 km east
## (`mapFarSps`), so that the map's fit, its farthest zoom out, holds the
## spread in a few pixels, its stations crowded on one another. The
## filters dead, noisy, missing from the template and killed are on, and
## one receiver's trace is killed.
##
## - At the farthest zoom out, each filter's mark is drawn: a glyph in its
##   colour round its station, larger than the stations' discs (20 pixels
##   of its colour or more within 14 pixels of the station, where a disc
##   is a handful), so it is never lost among them.
## - The point under the pointer there says how many of each mark lie
##   under it ("Marked here: 1 dead in the headers, ..."), as the marks
##   fall on one another.
## - Zoomed in as far as the map goes, the mark is the same size on the
##   screen.
## - With every trace of the shot killed, each receiver is one mark, though
##   each trace is marked at its file's own position and its survey
##   station's, one place: the glyphs are merged by place before they go to
##   the GPU.
##
## Seen to fail: with the marks drawn as they were (a disc a pixel larger
## than the stations' where they crowd), "dead in the headers: N pixels of
## its mark round (1, 2) at the farthest zoom" (0); with a glyph uploaded
## for each place marked, as at first, "a mark a receiver" found 124 glyphs
## for 124 places.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves map-flags-*.png there.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[edits, geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/[maplayers, theme]
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

const Shown = {mfDead, mfNoisy, mfMissing, mfKilled}
const Killed = (0, 10) ## the receiver whose trace is killed (line, k: 0-based)

proc screen(f: FrameInfo; d: tuple[line, k: int]): Vec2 =
  let (x, y) = mapRcv(d.line, d.k)
  let p = f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, mapPoint(x, y))
  vec2(round(p.x), round(p.y))

proc marked(img: seq[Rgba]; width: int; at: Vec2; c: Rgba): int =
  ## The pixels of colour `c` (within 12) up to 14 pixels from `at`: a
  ## mark's stroke round the station, where a station's disc of that
  ## colour would be a handful.
  for dy in -14 .. 14:
    for dx in -14 .. 14:
      let (x, y) = (int(at.x) + dx, int(at.y) + dy)
      if hypot(float(dx), float(dy)) <= 14 and distance(img[y * width + x], c) <= 12:
        inc result

proc runMain() =
  withFixtures fx:
    let sps = fx.mapSps()
    let shotPath = fx.mapShotSegd(0, 2, {MapDefect.low .. MapDefect.high})
    let far = fx.mapFarSps()
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
    var failed = ""
    var ink: MapInk
    var killed = -1
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc shot(f: FrameInfo; name: string) =
      if shots.len > 0:
        createDir(shots)
        discard f.savePng(shots / name)
    proc check(f: FrameInfo; where: string) =
      ## Each filter's mark drawn round its station.
      let img = f.readFrame()
      for (m, d) in [(mfDead, MapDefectAt[mdDead]), (mfNoisy, MapDefectAt[mdNoisy]),
          (mfMissing, MapDefectAt[mdMissing]), (mfKilled, Killed)]:
        let n = img.marked(f.width, f.screen(d), filterInk(f.theme, m, ink.background))
        doAssert n >= 20, $m & ": " & $n & " pixels of its mark round " & $d & " " & where

    step("loaded", noop, proc (f: FrameInfo): bool =
      result = f.core.survey.layers.len == 5 and f.core.sessions.len == 1 and
        f.mapWindow.mapShown.isSet and wait > 8 and f.core.jobs.active.len == 0
      if result: ink = mapInk(f.theme, pcPaper))
    step("filters on, a trace killed", proc (f: FrameInfo) =
      var s = f.core.settings
      s.map.filters = Shown
      f.apply Command(kind: ckSettings, settings: s)
      let (x, y) = mapRcv(Killed[0], Killed[1])
      for p in f.core.pointsAt(mapPoint(x, y), 1.0):
        for t in f.core.survey.tracesAt(p):
          if killed < 0: killed = t
      doAssert killed >= 0, "no trace at the receiver to kill"
      f.apply(Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[killed],
        on: true)), proc (f: FrameInfo): bool =
      result = f.core.recordQc.job == NoJob and f.core.filterHits[mfDead].state == fsDone and
        f.core.filterHits[mfKilled].count == 1 and wait > 6
      if result:
        let h = f.core.filterHits
        doAssert h[mfDead].count == 1 and h[mfNoisy].count == 1 and h[mfMissing].count == 2,
          $(h[mfDead].count, h[mfNoisy].count, h[mfMissing].count))
    step("the farthest zoom out", noop, proc (f: FrameInfo): bool =
      let v = f.mapWindow.mapShown
      result = v.showsAll(f.core.map.limits) and wait > 6
      if result:
        # the spread in a few pixels: its receivers 25 m apart less than a pixel
        doAssert v.perPixel > MapRcvSpacing, "not crowded: " & $v.perPixel & " m a pixel"
        f.shot("map-flags-far.png")
        f.check("at the farthest zoom"))
    step("the point there says what is marked", proc (f: FrameInfo) =
      f.moveMouse(f.screen(MapDefectAt[mdDead])), proc (f: FrameInfo): bool =
      result = wait > 4 and f.mapWindow.hoveredPoints.len > 0
      if result:
        var line = ""
        for t in f.mapWindow.pointTexts:
          if t.startsWith("Marked here: "): line = t
        for words in ["1 dead in the headers", "1 noisy", "2 missing from the template",
            "1 killed"]:
          doAssert words in line, "\"" & words & "\" not in " & $f.mapWindow.pointTexts
        f.shot("map-flags-hover.png"))
    step("zoomed in as far as it goes", noop, proc (f: FrameInfo): bool =
      # the wheel over the dead receiver, a few notches a frame
      if wait mod 2 == 0 and f.mapWindow.mapShown.perPixel > f.core.map.limits.leastPerPixel:
        f.moveMouse(f.screen(MapDefectAt[mdDead]))
        f.scrollWheel(f.screen(MapDefectAt[mdDead]), 3)
      let v = f.mapWindow.mapShown
      result = wait > 6 and v.perPixel <= f.core.map.limits.leastPerPixel * 1.0001
      if result:
        let img = f.readFrame()
        let n = img.marked(f.width, f.screen(MapDefectAt[mdDead]),
          filterInk(f.theme, mfDead, ink.background))
        doAssert n >= 20, "zoomed in: " & $n & " pixels of the dead mark"
        f.shot("map-flags-near.png"))
    step("every trace killed: a mark a receiver", proc (f: FrameInfo) =
      var all: seq[int]
      for i in 1 .. 3 * 21: all.add f.core.sessions[0].base + i # (trace 0: the time break)
      f.apply(Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: all,
        on: true)), proc (f: FrameInfo): bool =
      result = f.core.filterHits[mfKilled].count == 63 and wait > 6
      if result:
        let (places, glyphs) = f.mapWindow.mapMarkCounts(mfKilled)
        echo "tguimapflags: 63 traces killed: ", places, " places marked, ", glyphs,
          " glyphs uploaded"
        # each trace at its file's own position and its survey station's, one
        # spot: a glyph a receiver (of the 63, those the map can place: the
        # planted defects move or unplace a few)
        doAssert glyphs in 55 .. 63 and places >= 2 * glyphs - 2, $(places, glyphs))

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
    let code = run(RunOptions(openPaths: @[sps.s, sps.r, fx.mapXps, far, shotPath],
      windowSize: (1400, 1100), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguimapflags: ", steps.len, " steps"

proc main*() =

  runMain()

when isMainModule:
  main()
