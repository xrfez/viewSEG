## The geometry filters in the running frontend, headless, with real clicks: `surveySps`'s S,
## R and X files, joined to a SEG-Y shot of it whose channel 8's offset header is 50 over its
## distance and whose channel 12's receiver position is 30 east of its station.
##
## - In the Layers popover, under "Filters: the record shown", ticking the three geometry
##   filters lists each with its count (offset 2: the bad one and the moved receiver, whose
##   offset no longer fits where its header puts it; header position 1) and midpoint not
##   checked (the headers give no midpoint of their own).
## - The two receivers are ringed in the filter's colour (a triangle with a dot inside); one
##   along the line is not.
## - The point under the pointer says which filters mark it.
## - Beside the header position filter, the tolerance box says "more than 5 m from the
##   survey"; 40 typed into it, the moved receiver (30 m off) is no longer marked; emptied, the
##   default (5) is back and it is.
##
## Seen to fail: with the offset filter's traces left empty, "counted" found none and the
## receivers were not ringed; with no tolerance box drawn, "the tolerance box" found no mark.
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
  BadChannel = 7    ## the trace (0-based) whose offset header is 50 over its distance
  MovedChannel = 11 ## the trace whose receiver position is 30 east of its station

proc runMain() =
  withFixtures fx:
    let sps = fx.surveySps()
    let shotPath = fx.surveyShotSegy("shot.sgy", badOffset = BadChannel,
      movedReceiver = MovedChannel)
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
    proc receiver(f: FrameInfo; channel: int): Vec2 =
      let p = f.screen(rcvX(channel + 1), OriginY)
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
    proc joinNow(f: FrameInfo) =
      f.apply Command(kind: ckJoin, joinFile: f.core.sessions[0].id,
        joinFiles: @[JoinFile(path: sps.s, kind: jkSps), JoinFile(path: sps.r, kind: jkSps),
          JoinFile(path: sps.x, kind: jkSps)], joinOptions: JoinOptions(),
        joinUnits: JoinUnits(survey: suMetres))
    proc joined(f: FrameInfo): bool =
      f.core.joins.len == 1 and f.core.joinUnderWay.job == NoJob and wait > 8
    step("joined to the survey", joinNow, joined)
    step("the Layers popover", proc (f: FrameInfo) =
      f.click(f.markOf("map.layers").centre), proc (f: FrameInfo): bool =
      wait > 3 and f.markOf("map.filter " & $mfOffsetOff).size.x > 0)
    step("scrolled to the geometry filters", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("map.filter " & $mfDead).centre), proc (f: FrameInfo): bool =
      # (the popover is a window of its own: the pointer rests on it, then the wheel turns)
      if wait in 4 .. 14: f.scrollWheel(f.markOf("map.filter " & $mfDead).centre, -3)
      wait > 18 and f.markOf("map.filter " & $mfOffsetOff).pos.y < 1000)
    for m in [mfOffsetOff, mfMidpointOff, mfPositionOff]: step("ticked " & $m, filterTick(m),
        ticked(m))
    step("counted", noop, proc (f: FrameInfo): bool =
      result = f.core.recordQc.job == NoJob and
        f.core.recordQc.hits[mfPositionOff].state == fsDone and wait > 4
      if result:
        let base = f.core.sessions[0].base
        let h = f.core.filterHits
        doAssert h[mfOffsetOff].traces == @[base + BadChannel, base + MovedChannel],
          $h[mfOffsetOff].traces
        doAssert h[mfPositionOff].traces == @[base + MovedChannel], $h[mfPositionOff].traces
        doAssert filterLabel(mfOffsetOff, h[mfOffsetOff]) ==
          "Offset disagrees with the positions  (2)", filterLabel(mfOffsetOff, h[mfOffsetOff])
        doAssert filterLabel(mfPositionOff, h[mfPositionOff]) ==
          "Header position disagrees with the survey  (1)"
        # (the shot's headers give no midpoint: not judged, never "(0)")
        doAssert h[mfMidpointOff].state == fsNotChecked and
          "(0)" notin filterLabel(mfMidpointOff, h[mfMidpointOff]), $h[mfMidpointOff]
        doAssert f.markOf("map.filter tolerance").size.x > 0, "no tolerance box"
        f.desktop("geomflag.png"))
    proc typeTolerance(text: string; want: float64; marked: int) =
      # click the box, empty it, type, Enter: a key a frame
      var phase = 0
      var held = 0
      step("typed " & text & " as the tolerance", noop, proc (f: FrameInfo): bool =
        let r = f.markOf("map.filter tolerance")
        if r.size.x == 0: return false
        if phase == 0:
          f.click(r.centre)
          phase = 1
        elif phase == 1:
          f.pressKey(skEnd, true)
          f.pressKey(skEnd, false)
          phase = 2
        elif phase == 2:
          f.pressKey(skBackspace, true)
          f.pressKey(skBackspace, false)
          inc held
          if held >= 6: phase = 3
        elif phase == 3:
          if text.len > 0: f.typeText(text)
          phase = 4
        elif phase == 4:
          f.pressKey(skEnter, true)
          f.pressKey(skEnter, false)
          phase = 5
        else:
          let h = f.core.filterHits[mfPositionOff]
          result = f.core.settings.map.positionTolerance == want and
            f.core.recordQc.job == NoJob and h.state == fsDone and h.traces.len == marked and
            f.core.recordQc.geometry.tolerance == (if want > 0: want else: 5.0))
    typeTolerance("40", 40, 0)
    typeTolerance("", 0, 1)
    step("ringed", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false)
      f.moveMouse(vec2(4, 4)), proc (f: FrameInfo): bool =
      result = wait > 4 and f.markOf("map.filter " & $mfOffsetOff).size.x == 0
      if result:
        let c = filterInk(f.theme, mfOffsetOff, ink.background)
        for ch in [BadChannel, MovedChannel]:
          doAssert f.ring(f.receiver(ch), c) >= 6, "no mark round channel " & $ch & ": " &
            $f.ring(f.receiver(ch), c)
        doAssert f.ring(f.receiver(3), c) == 0, "a receiver along its line ringed"
        f.shot("map-geometry-ringed.png"))
    step("the point under the pointer says so", proc (f: FrameInfo) =
      f.moveMouse(f.receiver(MovedChannel)), proc (f: FrameInfo): bool =
      result = wait > 4 and f.mapWindow.hoveredPoints.len > 0
      if result:
        doAssert "Marked: " & $mfOffsetOff & ", " & $mfPositionOff in f.mapWindow.pointTexts,
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
    let code = run(RunOptions(openPaths: @[sps.s, sps.r, sps.x, shotPath],
      windowSize: (1400, 1100), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc main*() =

  runMain()

when isMainModule:
  main()
