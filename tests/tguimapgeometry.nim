## The position filter in the running frontend, headless, with real clicks: `surveySps`'s S,
## R and X files, joined to a SEG-Y shot of it whose channel 12's receiver position is 30 east
## of its station.
##
## - In the Layers popover, under "Filters: the record shown", ticking "header position
##   disagrees with the survey" lists it with its count (1: the moved receiver).
## - That receiver is marked in the filter's colour; one along the line is not.
## - The point under the pointer says the filter marks it.
## - Beside the filter, the tolerance box says "more than 5 m from the survey"; 40 typed into
##   it, the moved receiver (30 m off) is no longer marked; emptied, the default (5) is back and
##   it is. The keys are typed once the box has the keyboard (`typing`), and typed again when
##   the box did not take them. The box sends the default (0) for an empty box; the fault was
##   the test's: with no window manager the keyboard follows the pointer, and on a loaded
##   machine the display server moves it into the popover's own window some frames after the
##   pointer went there, while the keys are on their way; the main window's loss of the
##   keyboard makes ImGui let go of the box and drop what was typed (logged: the text and
##   Enter delivered at frames 75 and 76, the main window's focus lost at 81, the box never
##   given them).
##
## Seen to fail: with no tolerance box drawn, "the tolerance box" found no mark; with the keys
## typed once a frame after the click (no wait for the keyboard, no second try), "typed 40 as
## the tolerance did not happen" in 2 to 3 of 16 runs side by side on a 32-core machine (every
## run that tried again then passed).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves map-geometry-ringed.png there.

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

const MovedChannel = 11 ## the trace (0-based) whose receiver position is 30 east of its station

proc runMain() =
  withFixtures fx:
    let sps = fx.surveySps()
    let shotPath = fx.surveyShotSegy("shot.sgy", movedReceiver = MovedChannel)
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
      wait > 3 and f.markOf("map.filter " & $mfPositionOff).size.x > 0)
    step("scrolled to the geometry filters", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("map.filter " & $mfDead).centre), proc (f: FrameInfo): bool =
      # (the popover is a window of its own: the pointer rests on it, then the wheel turns)
      if wait in 4 .. 14: f.scrollWheel(f.markOf("map.filter " & $mfDead).centre, -3)
      wait > 18 and f.markOf("map.filter " & $mfPositionOff).pos.y < 1000)
    step("ticked " & $mfPositionOff, filterTick(mfPositionOff), ticked(mfPositionOff))
    step("counted", noop, proc (f: FrameInfo): bool =
      result = f.core.recordQc.job == NoJob and
        f.core.recordQc.hits[mfPositionOff].state == fsDone and wait > 4
      if result:
        let base = f.core.sessions[0].base
        let h = f.core.filterHits
        doAssert h[mfPositionOff].traces == @[base + MovedChannel], $h[mfPositionOff].traces
        doAssert filterLabel(mfPositionOff, h[mfPositionOff]) ==
          "Header position disagrees with the survey  (1)"
        doAssert f.markOf("map.filter tolerance").size.x > 0, "no tolerance box")
    proc typeTolerance(text: string; want: float64; marked: int) =
      # point at the box, click it, wait for the keyboard, empty it, type, Enter: a key a
      # frame; when the setting has not followed after a while, Escape and all again
      var phase, held, tries = 0
      var at = 0 # the frame (of `wait`) the phase began
      step("typed " & (if text.len > 0: text else: "(empty)") & " as the tolerance", noop,
          proc (f: FrameInfo): bool =
        let r = f.markOf("map.filter tolerance")
        if r.size.x == 0: return false
        proc next(p: int) =
          (phase, at) = (p, wait)
        case phase
        of 0:
          f.moveMouse(r.centre)
          next 1
        of 1:
          if wait - at >= 3:
            f.click(r.centre)
            next 2
        of 2:
          if f.typing: next 3
          elif wait - at > 30: next 8 # (the click was not taken: again)
        of 3:
          f.pressKey(skEnd, true)
          f.pressKey(skEnd, false)
          (held, phase) = (0, 4)
        of 4:
          f.pressKey(skBackspace, true)
          f.pressKey(skBackspace, false)
          inc held
          if held >= 6: phase = 5
        of 5:
          if text.len > 0: f.typeText(text)
          next 6
        of 6:
          if wait - at >= 2:
            f.pressKey(skEnter, true)
            f.pressKey(skEnter, false)
            next 7
        of 7:
          let h = f.core.filterHits[mfPositionOff]
          result = f.core.settings.map.positionTolerance == want and
            f.core.recordQc.job == NoJob and h.state == fsDone and h.traces.len == marked and
            f.core.recordQc.geometry.tolerance == (if want > 0: want else: 5.0)
          if not result and wait - at > 90 and f.core.settings.map.positionTolerance != want:
            next 8
        else:
          # the keys were lost on their way: leave the box as it was (Escape while it has the
          # keyboard; not after, which would close the popover), and try again
          doAssert tries < 5, "the box never took the keys"
          inc tries
          if f.typing:
            f.pressKey(skEscape, true)
            f.pressKey(skEscape, false)
          next 0)
    typeTolerance("40", 40, 0)
    typeTolerance("", 0, 1)
    step("ringed", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false)
      f.moveMouse(vec2(4, 4)), proc (f: FrameInfo): bool =
      result = wait > 4 and f.markOf("map.filter " & $mfPositionOff).size.x == 0
      if result:
        let c = filterInk(f.theme, mfPositionOff, ink.background)
        doAssert f.ring(f.receiver(MovedChannel), c) >= 6, "no mark round channel " &
          $MovedChannel & ": " & $f.ring(f.receiver(MovedChannel), c)
        doAssert f.ring(f.receiver(3), c) == 0, "a receiver along its line ringed"
        f.shot("map-geometry-ringed.png"))
    step("the point under the pointer says so", proc (f: FrameInfo) =
      f.moveMouse(f.receiver(MovedChannel)), proc (f: FrameInfo): bool =
      result = wait > 4 and f.mapWindow.hoveredPoints.len > 0
      if result:
        doAssert "Marked: " & $mfPositionOff in f.mapWindow.pointTexts,
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
