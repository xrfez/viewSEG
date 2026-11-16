## The map's ruler and its button are one state, on the land survey
## (`samples/land/shots.sgy` with `samples/land/land.s`, `land.r` and
## `land.x`), headless, driven as the user's mouse is.
##
## Ctrl+click at one point of the map and release at another (the measure
## drag) draws the ruler and lights the Ruler button, in the selection
## colour the bar's other on toggles use. Clicking that lit button turns
## the ruler off: the line, its reading and the `map.ruler` item go at
## once, the button is unlit, and no accent pixel of the line remains.
##
## Seen to fail: with a Ctrl drag leaving `rulerOn` false and a click of
## the button only flipping that flag, "the button is lit" found the
## button off while the line was drawn, and "the button is unlit" found
## the line still on the map.
##
## Needs a display: the tester gives it one.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/theme
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

const root = currentSourcePath().parentDir.parentDir

proc centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc accentOnLine(f: FrameInfo; a, b: Vec2; ink: Rgba): int =
  ## Pixels of `ink` along the segment `a`..`b` and one pixel beside it:
  ## the ruler's stroke.
  let n = 48
  for i in 0 .. n:
    let t = i.float / n.float
    let x = int(floor(a.x + (b.x - a.x) * t))
    let y = int(floor(a.y + (b.y - a.y) * t))
    if distance(f.readPixel(x, y), ink) <= 40: inc result
    if distance(f.readPixel(x, y + 1), ink) <= 40: inc result

proc fillOf(f: FrameInfo; mark: string): Rgba =
  ## A pixel of the button's fill, below the label and clear of the corners.
  let r = f.markOf(mark)
  f.readPixel(int(r.pos.x + r.size.x / 2), int(r.pos.y + r.size.y) - 3)

proc main() =
  withFixtures fx:
    let land = root / "samples" / "land"
    let shots = land / "shots.sgy"
    let sps = @[land / "land.s", land / "land.r", land / "land.x"]
    for pth in @[shots] & sps: doAssert fileExists(pth), pth
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var a, b, press: Vec2
    var accent, selection, frame: Rgba

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard

    step("loaded", noop, proc (f: FrameInfo): bool =
      result = f.core.survey.layers.len >= 2 and f.mapWindow.mapImagesDrawn > 0 and
        f.mapWindow.mapShown.isSet and f.markOf("map.data").size.x > 0 and
        f.markOf("map.ruler button").size.x > 0 and wait > 8
      if result:
        accent = f.theme.roles[rlAccent]
        selection = f.theme.roles[rlSelection]
        frame = f.theme.roles[rlFrame]
        let plot = f.markOf("map.data")
        # inset, so the stroke stays inside the plot and off the scale bar
        a = vec2(round(plot.pos.x + plot.size.x * 0.28), round(plot.pos.y + plot.size.y * 0.32))
        b = vec2(round(plot.pos.x + plot.size.x * 0.72), round(plot.pos.y + plot.size.y * 0.68))
        doAssert not f.mapWindow.rulerOn, "the ruler starts on")

    step("Ctrl+click draws the ruler and lights the button", proc (f: FrameInfo) =
      f.moveMouse(a)
      f.pressKey(skCtrl, true, {smCtrl})
      f.pressMouse(a, true)
      f.moveMouse(vec2((a.x + b.x) / 2, (a.y + b.y) / 2))
      f.moveMouse(b), proc (f: FrameInfo): bool =
      if wait == 3:
        f.pressMouse(b, false)
        f.pressKey(skCtrl, false)
      let line = f.accentOnLine(a, b, accent)
      result = wait > 6 and f.mapWindow.rulerOn and f.mapWindow.rulerText.len > 0 and
        f.markOf("map.ruler").size.x > 0 and line > 8
      if result:
        let fill = f.fillOf("map.ruler button")
        doAssert distance(fill, selection) < distance(fill, frame),
          "the button is not lit: " & $fill)

    step("clicking the lit button takes the ruler away", proc (f: FrameInfo) =
      press = f.markOf("map.ruler button").centre
      f.moveMouse(press), proc (f: FrameInfo): bool =
      if wait == 3: f.pressMouse(press, true)
      if wait == 5: f.pressMouse(press, false)
      if wait == 6: f.moveMouse(vec2(4, 4)) # off the button, so its fill is not the hover
      let line = f.accentOnLine(a, b, accent)
      let item = f.markOf("map.ruler")
      result = wait > 8 and not f.mapWindow.rulerOn and f.mapWindow.rulerText.len == 0 and
        item.size.x == 0 and item.size.y == 0 and line == 0
      if result:
        let fill = f.fillOf("map.ruler button")
        doAssert distance(fill, frame) < distance(fill, selection),
          "the button is still lit: " & $fill)

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
          failed = steps[at].name & " did not happen"
          f.stop()

    let code = run(RunOptions(openPaths: @[shots] & sps, windowSize: (1600, 1000),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguiruler: the button follows the ruler"

main()
