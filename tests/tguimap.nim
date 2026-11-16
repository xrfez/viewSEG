## The map window in the running frontend, headless, driven by SDL events
## as the user's mouse and keyboard send them, on a small 3D land spread
## (`mapSps`: receiver lines running east, source lines running north
## across them):
##
## - the survey files named on the command line are drawn at fit, every
##   source in the sources' colour and every receiver in the receivers' at
##   the pixel equal aspect puts it on, the background between them;
## - the axes show no values: the margins beside and below the plot are a
##   few pixels of one or two colours, and the plot area holds still;
## - the click that brings the window forward selects nothing;
## - the point under the pointer is described (station, coordinates with
##   units, its file) in a popup, drawn in the hover colour, and the status
##   bar shows the pointer's coordinates with their units;
## - a click selects the point (drawn in the selection colour), the wheel
##   zooms about the pointer (Ctrl + click adds a point, and takes it out
##   again), `-` zooms out, the arrows pan, Ctrl + 0 fits,
##   Backspace goes back, a right drag zooms to the box, a Shift drag
##   selects the points in its box, a Ctrl drag measures (length and
##   bearing) until Esc, and Esc then clears the selection; the Ruler button
##   turns the Ruler on, a plain drag then measures the same reading, a click
##   still selects, and Esc drops the line and leaves the button on;
## - the right-click menu over a receiver names it and hides its layer;
## - the strip along the bottom describes the point instead of the popup
##   when the settings say so; a scale bar says its length;
## - panning as far as it goes never loses the survey;
## - with the survey's seismic file open too, its own positions are drawn
##   as rings, and the trace under the pointer in the plot lights up its
##   receiver on the map.
##
## Seen to fail: with the sources' draw left out of the frame, "colours at
## fit" found the background at the first source; with the wheel zooming
## about the view's centre, "wheel zooms about the pointer" found the source
## 112 pixels from where it was; with the box select's points not sent, "a
## Shift drag selects" found no point selected; with the axes' values back,
## "no values on the axes" found a left margin of 94 px; with a Ctrl press
## always starting the ruler (as it did), "Ctrl + click adds the point"
## found 1 point selected; with a plain drag not measuring under the Ruler
## button, "a plain drag measures" found no reading.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves map-*.png there.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/maplayers
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func near(a, b: float64; eps = 1e-6): bool = abs(a - b) <= eps * max(1.0, abs(b))

proc chord(f: FrameInfo; key: SimKey; mods: set[SimMod] = {}) =
  ## `key` pressed and released with `mods` held.
  const modKeys: array[SimMod, SimKey] = [skCtrl, skShift, skAlt]
  var held: set[SimMod]
  for m in mods:
    held.incl m
    f.pressKey(modKeys[m], true, held)
  f.pressKey(key, true, held)
  f.pressKey(key, false, held)
  for m in mods:
    held.excl m
    f.pressKey(modKeys[m], false, held)

proc screen(f: FrameInfo; x, y: float64): Vec2 =
  ## Where survey point (`x`, `y`) is drawn now, framebuffer pixels.
  f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, mapPoint(x, y))

proc pixel(f: FrameInfo; at: Vec2): Rgba = f.readPixel(int(floor(at.x)), int(floor(at.y)))

func same(a, b: Rgba): bool = a.r == b.r and a.g == b.g and a.b == b.b

proc main() =
  withFixtures fx:
    let sps = fx.mapSps()
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
    var failed = ""
    var ink: MapInk
    var was: MapView
    var p, q: Vec2
    var backs = 0
    var saved: seq[string]
    var measured = "" # the Ctrl drag's reading, which a plain drag with the Ruler must match

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc shot(f: FrameInfo; name: string) =
      if shots.len > 0:
        createDir(shots)
        if f.savePng(shots / name): saved.add name
    proc settled(f: FrameInfo): bool =
      f.mapWindow.mapShown.isSet and sameMapView(f.mapWindow.mapShown, f.core.map.view)

    step("loaded", noop, proc (f: FrameInfo): bool =
      result = f.core.survey.layers.len == 2 and f.mapWindow.mapImagesDrawn > 0 and
        f.settled and f.markOf("map.data").size.x > 0 and wait > 4
      if result:
        ink = mapInk(f.theme, pcPaper)
        doAssert f.mapWindow.mapShown.showsAll(f.core.map.limits), "not at fit")

    step("colours at fit", noop, proc (f: FrameInfo): bool =
      for line in 0 ..< MapSrcLines.len:
        for k in 0 ..< MapSrcPoints:
          let (x, y) = mapSrc(line, k)
          let c = f.pixel(f.screen(x, y))
          doAssert same(c, ink.roles[prSource]), "source " & $line & "/" & $k & ": " & $c &
            ", wanted " & $ink.roles[prSource]
      for line in 0 ..< MapRcvLines.len:
        for k in 0 ..< MapRcvPoints:
          let (x, y) = mapRcv(line, k)
          let c = f.pixel(f.screen(x, y))
          doAssert same(c, ink.roles[prReceiver]), "receiver " & $line & "/" & $k & ": " & $c
      # between the lines: the background
      let empty = f.pixel(f.screen(OriginX + MapRcvSpacing * 2, OriginY + MapLineGap / 2))
      doAssert same(empty, ink.background), $empty
      doAssert f.mapWindow.scaleText.endsWith(" m"), f.mapWindow.scaleText
      f.shot("map-fixture.png")
      true)

    var held: seq[Rect]
    step("no values on the axes, and the plot holds still", noop, proc (f: FrameInfo): bool =
      # The map's plot area on ten frames in a row: the same. No axis values
      # sit beside it: the margins between the map window's edges and the
      # plot are a few pixels, of one or two colours (the frame), no text.
      held.add f.markOf("map.data")
      result = held.len >= 10
      if result:
        for r in held: doAssert r == held[0], "the plot moved: " & $held
        let (w, d) = (f.markOf("map"), held[0])
        doAssert d.pos.x - w.pos.x < 24, "a left margin of " & $(d.pos.x - w.pos.x) & " px"
        doAssert w.pos.y + w.size.y - (d.pos.y + d.size.y) < 24,
          "a bottom margin of " & $(w.pos.y + w.size.y - (d.pos.y + d.size.y)) & " px"
        proc colours(x0, x1, y: int): int =
          var seen: seq[Rgba]
          for x in x0 ..< x1:
            let c = f.readPixel(x, y)
            var known = false
            for o in seen:
              if same(o, c): known = true
            if not known: seen.add c
          seen.len
        for y in countup(int(d.pos.y) + 4, int(d.pos.y + d.size.y) - 4, 3):
          let n = colours(int(w.pos.x) + 2, int(d.pos.x) - 1, y)
          doAssert n <= 3, "row " & $y & " left of the plot holds " & $n & " colours (text)"
        for x in countup(int(d.pos.x) + 4, int(d.pos.x + d.size.x) - 4, 3):
          var seen: seq[Rgba]
          for y in int(d.pos.y + d.size.y) + 1 ..< int(w.pos.y + w.size.y) - 2:
            let c = f.readPixel(x, y)
            var known = false
            for o in seen:
              if same(o, c): known = true
            if not known: seen.add c
          doAssert seen.len <= 3, "column " & $x & " below the plot holds " & $seen.len &
            " colours (text)")

    step("a focusing click selects nothing", proc (f: FrameInfo) =
      let (x, y) = mapRcv(1, 10)
      p = f.screen(x, y)
      f.moveMouse(p)
      f.pressMouse(p, true)
      f.pressMouse(p, false), proc (f: FrameInfo): bool =
      result = wait > 6
      if result:
        doAssert f.core.selection.points.len == 0, "the focusing click selected")

    step("the point under the pointer", noop, proc (f: FrameInfo): bool =
      result = f.mapWindow.hoveredPoints.len > 0 and f.markOf("map.info").size.x > 0
      if result:
        let t = f.mapWindow.pointTexts
        doAssert t[0] == "Receiver, line 102, point 111", $t
        doAssert t[1] == "E 500250.0   N 6000200.0   Z 100.0 m", $t
        doAssert t[2] == "In map.r", $t
        let c = f.mapCursor.splitWhitespace # E x N y m: the pointer, within a pixel
        let pp = f.mapWindow.mapShown.perPixel
        doAssert c.len == 5 and c[0] == "E" and c[2] == "N" and c[4] == "m", f.mapCursor
        doAssert abs(parseFloat(c[1]) - 500250) <= pp and abs(parseFloat(c[3]) - 6000200) <= pp,
          f.mapCursor
        doAssert f.markOf("status.map").size.x > 0
        doAssert same(f.pixel(p), ink.hover), "not drawn in the hover colour: " & $f.pixel(p))

    step("a click selects the point", proc (f: FrameInfo) =
      f.pressMouse(p, true)
      f.pressMouse(p, false), proc (f: FrameInfo): bool =
      result = f.core.selection.points.len == 1
      if result:
        doAssert f.core.selection.points[0].role == prReceiver)

    step("drawn in the selection colour", proc (f: FrameInfo) =
      let (x, y) = mapSrc(0, 4)
      q = f.screen(x, y)
      f.moveMouse(vec2(round(q.x), round(q.y))), proc (f: FrameInfo): bool =
      result = wait > 4 and f.mapWindow.hoveredPoints.len > 0
      if result:
        doAssert same(f.pixel(p), ink.selected), $f.pixel(p) & " wanted " & $ink.selected
        doAssert f.mapWindow.pointTexts[0] == "Source, line 1, point 1005",
          $f.mapWindow.pointTexts
        was = f.mapWindow.mapShown
        backs = f.core.map.back.len)

    proc ctrlClick(f: FrameInfo; at: Vec2) =
      f.pressKey(skCtrl, true, {smCtrl})
      f.pressMouse(at, true)
      f.pressMouse(at, false)
      f.pressKey(skCtrl, false)
    step("Ctrl + click adds the point", proc (f: FrameInfo) =
      f.ctrlClick(vec2(round(q.x), round(q.y))), proc (f: FrameInfo): bool =
      result = wait > 4
      if result:
        doAssert f.core.selection.points.len == 2, "Ctrl + click selected " &
          $f.core.selection.points.len & " points"
        doAssert f.core.selection.points[1].role == prSource
        doAssert f.mapWindow.rulerText.len == 0, "a Ctrl + click is no ruler")
    step("Ctrl + click again takes it out", proc (f: FrameInfo) =
      f.ctrlClick(vec2(round(q.x), round(q.y))), proc (f: FrameInfo): bool =
      result = wait > 4
      if result:
        doAssert f.core.selection.points.len == 1, $f.core.selection.points.len
        doAssert f.core.selection.points[0].role == prReceiver)

    step("wheel zooms about the pointer", proc (f: FrameInfo) =
      f.scrollWheel(vec2(round(q.x), round(q.y)), 4), proc (f: FrameInfo): bool =
      result = f.settled and not sameMapView(f.mapWindow.mapShown, was) and wait > 3
      if result:
        let v = f.mapWindow.mapShown
        let k = pow(1.25, 4)
        doAssert near(v.perPixel, was.perPixel / k, 1e-9), $v.perPixel
        let (x, y) = mapSrc(0, 4)
        let now = f.screen(x, y)
        # The survey point under the pointer (on a whole pixel) stays there; the
        # source, a fraction of a pixel from it, moves k times as far from it.
        let m = vec2(round(q.x), round(q.y))
        let want = vec2(m.x + (q.x - m.x) * k, m.y + (q.y - m.y) * k)
        doAssert abs(now.x - want.x) < 1 and abs(now.y - want.y) < 1, $now & " wanted " &
          $want & " (it was at " & $q & ")"
        doAssert same(f.pixel(now), ink.hover)
        doAssert f.core.map.back.len == backs + 1
        was = v)

    step("minus zooms out", proc (f: FrameInfo) = f.chord(skMinus), proc (f: FrameInfo): bool =
      result = f.settled and not sameMapView(f.mapWindow.mapShown, was)
      if result:
        doAssert near(f.mapWindow.mapShown.perPixel, was.perPixel * 1.5, 1e-9)
        was = f.mapWindow.mapShown)

    step("the arrow pans east", proc (f: FrameInfo) = f.chord(skRight), proc (f: FrameInfo): bool =
      result = f.settled and not sameMapView(f.mapWindow.mapShown, was)
      if result:
        let v = f.mapWindow.mapShown
        doAssert v.centre.x > was.centre.x and near(v.centre.y, was.centre.y), $v
        doAssert v.centre.x - was.centre.x <= 0.1 * was.width + 1e-6
        was = v
        backs = f.core.map.back.len)

    step("Ctrl + 0 fits", proc (f: FrameInfo) = f.chord(skZero, {smCtrl}),
      proc (f: FrameInfo): bool =
      result = f.settled and f.mapWindow.mapShown.showsAll(f.core.map.limits))

    step("Backspace goes back", proc (f: FrameInfo) = f.chord(skBackspace),
      proc (f: FrameInfo): bool =
      result = f.settled and sameMapView(f.mapWindow.mapShown, was))

    step("a right drag zooms to the box", proc (f: FrameInfo) =
      f.chord(skZero, {smCtrl}), proc (f: FrameInfo): bool =
      result = f.settled and f.mapWindow.mapShown.showsAll(f.core.map.limits)
      if result:
        let (x0, y0) = mapRcv(0, 0)
        let (x1, y1) = mapRcv(0, 8)
        p = f.screen(x0 - 10, y0 - 10)
        q = f.screen(x1 + 10, y1 + 10)
        was = f.mapWindow.mapShown)
    step("the box", proc (f: FrameInfo) =
      f.moveMouse(p)
      f.pressMouse(p, true, button = 3)
      f.moveMouse(vec2((p.x + q.x) / 2, (p.y + q.y) / 2))
      f.moveMouse(q), proc (f: FrameInfo): bool =
      if wait == 3: f.pressMouse(q, false, button = 3)
      result = wait > 3 and f.settled and not sameMapView(f.mapWindow.mapShown, was)
      if result:
        let v = f.mapWindow.mapShown
        doAssert v.perPixel < was.perPixel / 2, $v.perPixel
        let s = v.visible
        let (x0, y0) = mapRcv(0, 0)
        let (x1, _) = mapRcv(0, 8)
        doAssert s.minX <= x0 and s.maxX >= x1 and s.minY <= y0 and s.maxY >= y0, $s
        f.shot("map-fixture-zoomed.png"))

    step("a Shift drag selects the points in its box", proc (f: FrameInfo) =
      let (x0, y0) = mapRcv(0, 0)
      let (x1, _) = mapRcv(0, 8)
      p = f.screen(x0 - 5, y0 - 8)
      q = f.screen(x1 + 5, y0 + 8)
      f.moveMouse(p)
      f.pressKey(skShift, true, {smShift})
      f.pressMouse(p, true)
      f.moveMouse(vec2((p.x + q.x) / 2, (p.y + q.y) / 2))
      f.moveMouse(q), proc (f: FrameInfo): bool =
      if wait == 3:
        f.pressMouse(q, false)
        f.pressKey(skShift, false)
      result = wait > 5 and f.core.selection.points.len > 1
      if result:
        doAssert f.core.selection.points.len == 9, $f.core.selection.points.len
        for pt in f.core.selection.points: doAssert pt.role == prReceiver)

    step("a Ctrl drag measures", proc (f: FrameInfo) =
      let (x0, y0) = mapRcv(0, 0)
      let (x1, y1) = mapRcv(0, 8)
      p = f.screen(x0, y0)
      q = f.screen(x1, y1)
      (p, q) = (vec2(round(p.x), round(p.y)), vec2(round(q.x), round(q.y))) # where SDL puts it
      f.moveMouse(p)
      f.pressKey(skCtrl, true, {smCtrl})
      f.pressMouse(p, true)
      f.moveMouse(vec2((p.x + q.x) / 2, p.y))
      f.moveMouse(q), proc (f: FrameInfo): bool =
      if wait == 3:
        f.pressMouse(q, false)
        f.pressKey(skCtrl, false)
      result = wait > 5 and f.mapWindow.rulerText.len > 0 and f.markOf("map.ruler").size.x > 0
      if result:
        let v = f.mapWindow.mapShown
        let plot = f.mapWindow.mapPlot
        let want = distance(v.mapAt(plot, p), v.mapAt(plot, q))
        let parts = f.mapWindow.rulerText.split(' ')
        doAssert abs(parseFloat(parts[0]) - want) < 0.051, f.mapWindow.rulerText & " " & $want
        doAssert abs(parseFloat(parts[0]) - 200) < 2 * v.perPixel, f.mapWindow.rulerText
        doAssert parts[1] == "m," and parts[2] == "bearing", f.mapWindow.rulerText
        doAssert abs(parseFloat(parts[3].strip(chars = {'\xC2', '\xB0'})) - 90) < 1,
          f.mapWindow.rulerText
        doAssert f.core.selection.points.len == 9, "the ruler changed the selection"
        measured = f.mapWindow.rulerText
        f.shot("map-fixture-ruler.png"))

    step("Esc takes the ruler away", proc (f: FrameInfo) = f.chord(skEscape),
      proc (f: FrameInfo): bool =
      result = wait > 3 and f.mapWindow.rulerText.len == 0
      if result: doAssert f.core.selection.points.len == 9)

    step("Esc again clears the selection", proc (f: FrameInfo) = f.chord(skEscape),
      proc (f: FrameInfo): bool =
      f.core.selection.points.len == 0)

    # the Ruler button: a plain drag measures while it is on, as a Ctrl drag does
    proc stripButtonAt(f: FrameInfo; mark: string): Vec2 =
      let r = f.markOf(mark)
      doAssert r.size.x > 0, mark & " is not shown"
      vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))
    step("the Ruler button turns it on", proc (f: FrameInfo) =
      let r = f.markOf("map.ruler button")
      # the name is drawn beside the icon: a button about twice as wide as high
      doAssert r.size.x > 2 * r.size.y, "the Ruler button is an icon alone: " & $r
      p = stripButtonAt(f, "map.ruler button")
      f.moveMouse(p), proc (f: FrameInfo): bool =
      if wait == 3: f.pressMouse(p, true)
      if wait == 5: f.pressMouse(p, false)
      result = wait > 6 and f.mapWindow.rulerOn
      if result: doAssert f.mapWindow.rulerText.len == 0)
    step("a plain drag measures as the Ctrl drag did", proc (f: FrameInfo) =
      let (x0, y0) = mapRcv(0, 0)
      let (x1, y1) = mapRcv(0, 8)
      p = f.screen(x0, y0)
      q = f.screen(x1, y1)
      (p, q) = (vec2(round(p.x), round(p.y)), vec2(round(q.x), round(q.y)))
      was = f.mapWindow.mapShown
      f.moveMouse(p)
      f.pressMouse(p, true)
      f.moveMouse(vec2((p.x + q.x) / 2, p.y))
      f.moveMouse(q), proc (f: FrameInfo): bool =
      if wait == 3: f.pressMouse(q, false)
      result = wait > 5 and f.mapWindow.rulerText.len > 0 and f.markOf("map.ruler").size.x > 0
      if result:
        doAssert f.mapWindow.rulerText == measured,
          "a plain drag reads " & f.mapWindow.rulerText & ", a Ctrl drag " & measured
        doAssert sameMapView(f.mapWindow.mapShown, was), "a plain drag panned the map"
        doAssert f.core.selection.points.len == 0, "the ruler changed the selection")
    step("a click without a drag still selects a station", proc (f: FrameInfo) =
      # on the measured line's receiver line, in view (the view has moved on since fit)
      let (x, y) = mapRcv(0, 4)
      p = f.screen(x, y)
      f.moveMouse(p), proc (f: FrameInfo): bool =
      if wait == 3: f.pressMouse(p, true)
      if wait == 5: f.pressMouse(p, false)
      result = wait > 6 and f.core.selection.points.len == 1
      if result:
        doAssert f.core.selection.points[0].role == prReceiver
        doAssert f.mapWindow.rulerOn)
    step("Esc drops the line and the Ruler stays on", proc (f: FrameInfo) = f.chord(skEscape),
      proc (f: FrameInfo): bool =
      result = wait > 3 and f.mapWindow.rulerText.len == 0
      if result:
        doAssert f.mapWindow.rulerOn, "Esc turned the Ruler off"
        doAssert f.core.selection.points.len == 1, "Esc cleared the selection")
    step("the Ruler button turns it off", proc (f: FrameInfo) =
      p = stripButtonAt(f, "map.ruler button")
      f.moveMouse(p), proc (f: FrameInfo): bool =
      if wait == 3: f.pressMouse(p, true)
      if wait == 5: f.pressMouse(p, false)
      result = wait > 6 and not f.mapWindow.rulerOn)
    step("Esc clears the selection again", proc (f: FrameInfo) = f.chord(skEscape),
      proc (f: FrameInfo): bool =
      f.core.selection.points.len == 0)

    step("the menu over a receiver", proc (f: FrameInfo) =
      let (x, y) = mapRcv(0, 3)
      p = f.screen(x, y)
      f.moveMouse(p), proc (f: FrameInfo): bool =
      if wait == 3: f.pressMouse(p, true, button = 3)
      if wait == 5: f.pressMouse(p, false, button = 3)
      result = wait > 6 and f.markOf("map menu.hide").size.x > 0
      if result:
        doAssert f.mapWindow.mapMenuTitle == "Receiver, line 100, point 104",
          f.mapWindow.mapMenuTitle)

    step("it hides the receivers", proc (f: FrameInfo) =
      let m = f.markOf("map menu.hide")
      let c = vec2(m.pos.x + m.size.x / 2, m.pos.y + m.size.y / 2)
      f.moveMouse(c), proc (f: FrameInfo): bool =
      let m = f.markOf("map menu.hide")
      let c = vec2(m.pos.x + m.size.x / 2, m.pos.y + m.size.y / 2)
      if wait == 3: f.pressMouse(c, true)
      if wait == 5: f.pressMouse(c, false)
      if wait == 6: f.moveMouse(f.screen(OriginX + 62.5, OriginY + 100)) # nothing there
      result = wait > 10 and f.core.map.hidden.len == 1
      if result:
        doAssert f.core.map.hidden[0].role == prReceiver
        let (x, y) = mapRcv(0, 3)
        doAssert same(f.pixel(f.screen(x, y)), ink.background), "a hidden receiver is drawn"
        let (sx, sy) = mapSrc(0, 1)
        doAssert same(f.pixel(f.screen(sx, sy)), ink.roles[prSource]))

    step("the strip describes the point", proc (f: FrameInfo) =
      var s = f.core.settings
      s.map.info = miStrip
      f.apply Command(kind: ckSettings, settings: s)
      f.apply Command(kind: ckMapLayer, mapLayer: f.core.map.hidden[0], shown: true)
      let (x, y) = mapSrc(0, 1)
      p = f.screen(x, y)
      f.moveMouse(p), proc (f: FrameInfo): bool =
      let info = f.markOf("map.info")
      let win = f.markOf("map")
      result = wait > 6 and f.mapWindow.hoveredPoints.len > 0 and info.size.x > 0
      if result:
        doAssert f.mapWindow.pointTexts[0] == "Source, line 1, point 1002",
          $f.mapWindow.pointTexts
        doAssert info.pos.y > f.mapWindow.mapPlot.pos.y + f.mapWindow.mapPlot.size.y - 1 and
          info.pos.y + info.size.y <= win.pos.y + win.size.y + 1, "the strip is not under the map"
        f.shot("map-fixture-strip.png"))

    step("panning never loses the survey", proc (f: FrameInfo) =
      f.scrollWheel(p, 6)
      for i in 0 ..< 30: f.chord(skRight, {smShift}), proc (f: FrameInfo): bool =
      result = wait > 40 and f.settled
      if result:
        let s = f.mapWindow.mapShown.visible
        let b = f.core.survey.bounds
        doAssert s.minX < b.maxX and s.maxX > b.maxX, $s & " " & $b
        doAssert s.maxX <= b.maxX + MapMargin * f.mapWindow.mapShown.perPixel + 1e-6)

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
        elif overdue(wait, 300, since):
          failed = steps[at].name & " did not happen"
          f.stop()

    let code = run(RunOptions(openPaths: @[sps.s, sps.r],
      windowSize: (1600, 1000), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguimap: ", steps.len, " steps", (if saved.len > 0: "; saved " & saved.join(", ")
      else: "")

proc linked() =
  ## The survey's seismic file and its SPS files: the file's own positions
  ## as rings, and the trace under the pointer in the plot lit up on the map.
  withFixtures fx:
    let sps = fx.surveySps()
    let segy = fx.surveySegy()
    var stage = 0
    var wait = 0 # frames since the stage began, at `since`
    let start = getMonoTime()
    var since = start
    var ink: MapInk
    var traced = -1
    var done = false
    proc onFrame(f: FrameInfo) =
      inc wait
      case stage
      of 0:
        let k = f.core.findPanel(MainPanel)
        if f.core.survey.layers.len == 3 and f.core.panels[k].laidOut and
            f.core.tiles(k).len > 0 and f.mapWindow.mapShown.isSet and
            f.markOf("plot.data").size.x > 0 and wait > 10:
          ink = mapInk(f.theme, pcPaper)
          # a receiver's ring round the SPS receiver's disc: the ring's colour
          # just inside its edge, on the right of the point
          let v = f.mapWindow.mapShown
          # (the last receiver: far from the sources, which the plot's hovered
          # trace may light up)
          let c = v.screenAt(f.mapWindow.mapPlot, mapPoint(rcvX(Channels), OriginY))
          var ring = false # the ring's colour just inside its edge, 3.5 to 4 pixels out
          for dx in 3 .. 5:
            if same(f.readPixel(int(floor(c.x)) + dx, int(floor(c.y))), ink.roles[prReceiver]):
              ring = true
          doAssert ring, "no ring round the receiver"
          let plot = f.markOf("plot.data")
          f.moveMouse(vec2(plot.pos.x + plot.size.x * 0.3, plot.pos.y + plot.size.y / 2))
          (stage, wait, since) = (1, 0, getMonoTime())
      of 1:
        if wait > 4 and f.core.selection.hover >= 0 and f.pick.found:
          traced = f.core.selection.hover
          let pts = f.core.survey.tracePointsOf(traced)
          var rcv = -1.0
          for p in pts:
            if p.role == prReceiver:
              rcv = f.core.positionOf(p).x
          doAssert rcv > 0, "no receiver for the trace"
          let v = f.mapWindow.mapShown
          let c = v.screenAt(f.mapWindow.mapPlot, mapPoint(rcv, OriginY))
          let px = f.readPixel(int(floor(c.x)), int(floor(c.y)))
          if same(px, ink.hover):
            done = true
            f.stop()
        if overdue(wait, 200, since): f.stop()
      else: discard
      if overdue(f.index, 3000, start): f.stop()
    let code = run(RunOptions(openPaths: @[segy, sps.s, sps.r],
      windowSize: (1600, 1000), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0
    doAssert done, "the hovered trace's receiver was not lit up (stage " & $stage & ")"
    echo "tguimap: the plot's trace ", traced, " lit up on the map"

main()
linked()

# ------------------------------------------------- screenshots of real data --
# With `VIEWSEG_SCREENSHOTS=<dir>` and the example files present (they are
# local only), the Morgantown survey (its S, R and X files) is drawn with
# its record open, in the "Plot and map" layout: at fit with the pointer on
# a trace in the plot (its source and receiver lit up on the map), and
# zoomed in on the record's source with the pointer on a receiver (what the
# map says of it): docs/images/ holds the committed ones.

const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

proc morgantown(dir: string) =
  let base = examples / "sps" / "PGI_NNE_West_Morgantown_3D_Post261019_NAD27_SPCS_WV_N_USFeet"
  let record = examples / "00000151_12900_11300.sgd"
  let preset = currentSourcePath().parentDir.parentDir / "assets" / "layouts" / "Plot and map.nif"
  var stage = 0
  var wait = 0
  var saved = 0
  var loads = 0
  let start = getMonoTime()
  var at: Vec2
  proc onFrame(f: FrameInfo) =
    inc wait
    let k = f.core.findPanel(MainPanel)
    case stage
    of 0:
      if f.index == 2:
        loads = f.core.layoutLoads
        f.apply Command(kind: ckLoadLayout, docPath: preset)
      if f.core.survey.layers.len >= 3 and f.core.panels[k].laidOut and
          f.core.tiles(k).len > 0 and f.core.layoutLoads > loads and wait > 30 and
          f.mapWindow.mapShown.isSet:
        let plot = f.markOf("plot.data")
        at = vec2(round(plot.pos.x + plot.size.x * 0.62), round(plot.pos.y + plot.size.y * 0.4))
        f.moveMouse(at)
        (stage, wait) = (1, 0)
    of 1:
      if wait > 20 and f.core.selection.hover >= 0:
        if f.savePng(dir / "map-morgantown-1.png"): inc saved
        # zoom in about the record's source, and point at a receiver near it
        let hl = f.core.highlightOf
        var src, rcv = mapPoint(NaN, NaN)
        for p in hl.hovered:
          if p.role == prSource: src = f.core.positionOf(p)
          else: rcv = f.core.positionOf(p)
        doAssert not src.x.isNaN and not rcv.x.isNaN, "the hovered trace lit nothing up"
        let v = f.mapWindow.mapShown
        let s = v.screenAt(f.mapWindow.mapPlot, src)
        at = vec2(round(s.x), round(s.y))
        f.moveMouse(at)
        (stage, wait) = (2, 0)
    of 2:
      if wait == 3: f.scrollWheel(at, 9)
      if wait == 12:
        # the receiver nearest the source, a little way off
        let v = f.mapWindow.mapShown
        let src = v.mapAt(f.mapWindow.mapPlot, at)
        var best = mapPoint(NaN, NaN)
        var bestD = Inf
        for k in 0 ..< f.core.survey.layers.len:
          template l: untyped = f.core.survey.layers[k]
          let q = l.points[prReceiver].index.nearest(src.x + 600, src.y - 300, Inf)
          if q >= 0:
            let d = hypot(l.points[prReceiver].index.x(q) - src.x - 600,
              l.points[prReceiver].index.y(q) - src.y + 300)
            if d < bestD:
              bestD = d
              best = mapPoint(l.points[prReceiver].index.x(q), l.points[prReceiver].index.y(q))
        let p = v.screenAt(f.mapWindow.mapPlot, best)
        f.moveMouse(vec2(round(p.x), round(p.y)))
      if wait > 30 and f.mapWindow.hoveredPoints.len > 0:
        if f.savePng(dir / "map-morgantown-2.png"): inc saved
        echo "tguimap: Morgantown: ", f.mapWindow.pointTexts.join(" | "), "; scale bar ",
          f.mapWindow.scaleText, "; ", f.mapCursor
        f.stop()
    else: discard
    if overdue(f.index, 6000, start): f.stop()
  let tmp = getTempDir() / ("viewseg-mapshots-" & $getCurrentProcessId())
  let code = run(RunOptions(openPaths: @[record, base & ".sps", base & ".rps",
    base & ".xps"], windowSize: (1600, 1000), theme: forceDark, indexCacheDir: some(tmp),
    userThemeDir: some(tmp / "no-user-themes"), onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0 and saved == 2, "no screenshots of Morgantown (stage " & $stage & ")"
  echo "tguimap: saved ", dir / "map-morgantown-1.png", " and -2.png"

if getEnv("VIEWSEG_SCREENSHOTS").len > 0 and fileExists(examples / "00000151_12900_11300.sgd"):
  createDir(getEnv("VIEWSEG_SCREENSHOTS"))
  morgantown(getEnv("VIEWSEG_SCREENSHOTS"))
