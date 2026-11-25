## The geometry filters in the running frontend, headless, with real clicks: `mapSps`'s S, R
## and X files and a SEG-Y shot of source 1003 of line 0 whose receiver (1, 2)'s trace has an
## offset header 50 over the distance its positions give.
##
## - In the Layers popover, under "Filters: the record shown", ticking "offset disagrees with
##   the positions" and "midpoint disagrees with the positions" lists each with its count: 1
##   and 0.
## - The receiver of the trace is ringed in the filter's colour (a triangle with a dot inside);
##   one further along its line is not.
## - The point under the pointer says which filter marks it.
##
## Seen to fail: with the offset filter's traces left empty ("hits" never filled), "counted"
## found 0 and the receiver was not ringed.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves map-geometry-ringed.png, and geomflag.png (the whole
## display, where the popover shows; it needs `scrot`), there.

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

const
  BadReceiver = (line: 1, k: 2)                              ## the receiver whose trace's offset header is 50 over
  BadTrace = BadReceiver.line * MapRcvPoints + BadReceiver.k ## its trace in the file

proc runMain() =
  withFixtures fx:
    let sps = fx.mapSps()
    let shotPath = fx.mapShotSegy(0, 2, "bad-offset.sgy", badOffset = BadTrace)
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
    proc desktop(f: FrameInfo; name: string) =
      ## The whole display, where an open popover (a window of its own) shows.
      if shots.len > 0:
        createDir(shots)
        discard execShellCmd("scrot -o " & quoteShell(shots / name))
    proc filterTick(f: MapFilter): proc (f: FrameInfo) =
      result = proc (fr: FrameInfo) = fr.click(fr.markOf("map.filter " & $f).tick)
    proc ticked(f: MapFilter): proc (f: FrameInfo): bool =
      # (a proc of its own: a closure made in a loop would see the loop's last value)
      result = proc (fr: FrameInfo): bool =
        f in fr.core.settings.map.filters

    step("loaded", noop, proc (f: FrameInfo): bool =
      result = f.core.survey.layers.len == 4 and f.core.sessions.len == 1 and
        f.mapWindow.mapShown.isSet and wait > 8 and f.core.jobs.active.len == 0
      if result: ink = mapInk(f.theme, pcPaper))
    step("the Layers popover", proc (f: FrameInfo) =
      f.click(f.markOf("map.layers").centre), proc (f: FrameInfo): bool =
      wait > 3 and f.markOf("map.filter " & $mfOffsetOff).size.x > 0)
    step("scrolled to the geometry filters", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("map.filter " & $mfDead).centre), proc (f: FrameInfo): bool =
      # (the popover is a window of its own: the pointer rests on it, then the wheel turns)
      if wait in 4 .. 14: f.scrollWheel(f.markOf("map.filter " & $mfDead).centre, -3)
      wait > 18 and f.markOf("map.filter " & $mfOffsetOff).pos.y < 1000)
    for m in [mfOffsetOff, mfMidpointOff]: step("ticked " & $m, filterTick(m), ticked(m))
    step("counted", noop, proc (f: FrameInfo): bool =
      result = f.core.recordQc.job == NoJob and
        f.core.recordQc.hits[mfOffsetOff].state == fsDone and wait > 4
      if result:
        let h = f.core.filterHits
        doAssert h[mfOffsetOff].count == 1 and h[mfMidpointOff].count == 0,
          $(h[mfOffsetOff].count, h[mfMidpointOff].count)
        doAssert filterLabel(mfOffsetOff, h[mfOffsetOff]) ==
          "Offset disagrees with the positions  (1)", filterLabel(mfOffsetOff, h[mfOffsetOff])
        doAssert filterLabel(mfMidpointOff, h[mfMidpointOff]) ==
          "Midpoint disagrees with the positions  (0)"
        f.desktop("geomflag.png"))
    step("ringed", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false)
      f.moveMouse(vec2(4, 4)), proc (f: FrameInfo): bool =
      result = wait > 4 and f.markOf("map.filter " & $mfOffsetOff).size.x == 0
      if result:
        let c = filterInk(f.theme, mfOffsetOff, ink.background)
        doAssert f.ring(f.receiver(BadReceiver), c) >= 6, "no mark round the receiver: " &
          $f.ring(f.receiver(BadReceiver), c)
        doAssert f.ring(f.receiver((1, 12)), c) == 0, "a receiver along its line ringed"
        f.shot("map-geometry-ringed.png"))
    step("the point under the pointer says so", proc (f: FrameInfo) =
      f.moveMouse(f.receiver(BadReceiver)), proc (f: FrameInfo): bool =
      result = wait > 4 and f.mapWindow.hoveredPoints.len > 0
      if result:
        doAssert "Marked: " & $mfOffsetOff in f.mapWindow.pointTexts, $f.mapWindow.pointTexts)

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

proc main*() =

  runMain()

when isMainModule:
  main()
