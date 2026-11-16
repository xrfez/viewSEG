## A million points on the map, in the running frontend, headless (in the
## "Plot and map" layout, so the map is large): an R
## file of 1000 lines of 1000 receivers, 5 m apart both ways (a square of
## points as dense as a survey gets, the worst case for drawing them), is
## read, made into a layer with its levels of detail on a worker, and drawn;
## then the map is panned with the arrow keys and zoomed with the wheel, a
## step a frame, and the frames are timed: moving the map costs little
## more than an idle frame and stays under 33 ms, the floor for software
## OpenGL (the times are printed; an optimised build's are in
## docs/plot-window.md). The receivers are
## drawn (their colour at a receiver's pixel), and each frame draws far
## fewer points than the layer has.
##
## Then a box over most of the map selects hundreds of thousands of points,
## and their highlight is drawn about one a pixel and a half, not each; the
## map is zoomed in on them, a notch a frame, as far as it goes, panned
## there and zoomed out again to fit: the highlight is thinned again for
## each view, drawn round the view at the closest zoom and as before at fit.
##
## Seen to fail: with the highlight's cells kept in an `IntSet`, as the map
## first did, zooming in on the 842 000 selected points crashed the program
## (a stack overflow freeing the set, SIGSEGV) at 0.0057 m a pixel.
##
## Seen to fail: with every point drawn whatever the scale (`levelFor`
## always -1), "few points drawn" found 1 000 000 drawn at fit; with the
## highlight never thinned (`ThinAbove` fifty million), "highlighted" found
## 842 000 of 842 000; with the map's view models looping over the survey's
## layers by value (a copy of every layer, 100 MB, each frame), "the map
## lags" found 73 ms frames.
##
## Runs alone: it bounds the frame times while the map moves (under 33 ms, and
## at most 15 ms over an idle frame).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[algorithm, math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/maplayers
import utils/[fixtures, waiting]

const
  Lines = 1000
  Points = 1000
  Spacing = 5.0

func same(a, b: Rgba): bool =
  ## Within 2 of each other: the smoothed edges of discs drawn over one
  ## another round the colour by a step or two.
  abs(int(a.r) - int(b.r)) <= 2 and abs(int(a.g) - int(b.g)) <= 2 and
    abs(int(a.b) - int(b.b)) <= 2

func median(xs: seq[float64]): float64 =
  let s = xs.sorted
  s[s.len div 2]

proc main() =
  withFixtures fx:
    let t0 = getMonoTime()
    let path = fx.bigSps(Lines, Points, Spacing, Spacing)
    let written = (getMonoTime() - t0).inMilliseconds
    var stage = 0
    var wait = 0
    var last = getMonoTime()
    var loadStart = getMonoTime()
    var loadMs = 0'i64
    var idle, panning, zooming: seq[float64]
    var drawnAtFit, drawnClose, selectedPoints, selectedDrawn = 0
    var selectedFrames, closeFrames: seq[float64]
    var lastPerPixel = 0.0
    var still = 0
    var closest = 0.0
    var drawnClosest, drawnAway, drawnPanned, drawnRefit = -1
    var at: Vec2
    var coloured = false
    var loads = 0
    var mapSize: Vec2
    let preset = currentSourcePath().parentDir.parentDir / "assets" / "layouts" /
      "Plot and map.nif"
    proc onFrame(f: FrameInfo) =
      let now = getMonoTime()
      let ms = float64((now - last).inMicroseconds) / 1000
      last = now
      inc wait
      case stage
      of 0:
        if f.index == 0: loadStart = now
        if f.index == 2: # a large map: the plot and the map side by side
          loads = f.core.layoutLoads
          f.apply Command(kind: ckLoadLayout, docPath: preset)
        if f.core.survey.layers.len == 1 and f.mapWindow.mapShown.isSet and
            f.mapWindow.mapImagesDrawn > 0 and f.core.layoutLoads > loads and wait > 10:
          loadMs = (now - loadStart).inMilliseconds
          let plot = f.markOf("map.data")
          mapSize = plot.size
          at = vec2(round(plot.pos.x + plot.size.x / 2), round(plot.pos.y + plot.size.y / 2))
          f.moveMouse(at)
          (stage, wait) = (1, 0)
      of 1: # focus the map, then idle frames
        if wait == 3: f.pressMouse(at, true)
        if wait == 5: f.pressMouse(at, false)
        if wait in 20 ..< 50: idle.add ms
        if wait == 50:
          drawnAtFit = f.mapWindow.mapPointsDrawn
          let ink = mapInk(f.theme, pcPaper)
          let v = f.mapWindow.mapShown
          # three quarters of the way north-east: away from the pointer, which
          # lights its point up, and from the description beside it
          let p = v.screenAt(f.mapWindow.mapPlot, mapPoint(OriginX + Spacing * 750,
            OriginY + Spacing * 750))
          # zoomed out, the markers are small and smoothed: some pixel near it
          # is wholly the receivers' colour
          for dy in -3 .. 3:
            for dx in -3 .. 3:
              if same(f.readPixel(int(floor(p.x)) + dx, int(floor(p.y)) + dy),
                  ink.roles[prReceiver]):
                coloured = true
          (stage, wait) = (2, 0)
      of 2: # zoom in and out, a notch a frame
        if wait > 1: zooming.add ms
        f.scrollWheel(at, (if wait < 30: 1 else: -1))
        if wait == 60: (stage, wait) = (3, 0)
      of 3: # zoomed in a little, pan a tenth of the view a frame
        if wait == 1: f.scrollWheel(at, 3)
        if wait > 4:
          if wait > 5: panning.add ms
          f.pressKey(skRight, true)
          f.pressKey(skRight, false)
        if wait == 64:
          drawnClose = f.mapWindow.mapPointsDrawn
          f.scrollWheel(at, -3)
          (stage, wait) = (4, 0)
      of 4: # Shift + drag a box over most of the map: hundreds of thousands selected
        let (a, b) = (vec2(round(at.x - mapSize.x * 0.4), round(at.y - mapSize.y * 0.4)),
          vec2(round(at.x + mapSize.x * 0.4), round(at.y + mapSize.y * 0.4)))
        case wait
        of 20: f.moveMouse(a)
        of 22: f.pressKey(skShift, true, {smShift})
        of 23: f.pressMouse(a, true)
        of 24 .. 33:
          let t = float32(wait - 23) / 10
          f.moveMouse(vec2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
        of 34: f.pressMouse(b, false)
        of 35: f.pressKey(skShift, false)
        else: discard
        if wait in 40 ..< 70: selectedFrames.add ms
        if wait == 70:
          (selectedPoints, selectedDrawn) = (f.core.selection.points.len,
            f.mapWindow.mapSelectedDrawn)
          (stage, wait) = (5, 0)
      of 5, 7: # zoom in (5) or out (7), a notch a frame, as far as the map goes
        let pp = f.mapWindow.mapShown.perPixel
        if wait > 1: closeFrames.add ms
        if pp == lastPerPixel: inc still
        else: still = 0
        lastPerPixel = pp
        if (still >= 3 and wait > 10) or wait > 200:
          if stage == 5:
            (closest, drawnClosest) = (pp, f.mapWindow.mapSelectedDrawn)
            (stage, wait) = (6, 0)
          else:
            drawnRefit = f.mapWindow.mapSelectedDrawn
            f.stop()
        else:
          # zoomed out away from the receiver in the middle: its description
          # under the pointer would take the wheel
          let o = if stage == 5: at else: vec2(round(at.x + mapSize.x * 0.3), at.y)
          if wait == 1: f.moveMouse(o)
          f.scrollWheel(o, (if stage == 5: 1 else: -1))
      of 6: # at the closest zoom, on a receiver; a tenth of the view every other
        # frame (a press and a release take ImGui two), two views away and back
        let receiver = mapPoint(OriginX + Spacing * 500, OriginY + Spacing * 500)
        if wait == 1: f.showMapView(MapView(centre: receiver, perPixel: closest))
        if wait == 5:
          drawnClosest = f.mapWindow.mapSelectedDrawn
          doAssert distance(f.mapWindow.mapShown.centre, receiver) < 0.01
        if wait mod 2 == 0 and (wait in 6 .. 44 or wait in 50 .. 88):
          let key = if wait <= 44: skRight else: skLeft
          f.pressKey(key, true)
          f.pressKey(key, false)
        if wait == 48: drawnAway = f.mapWindow.mapSelectedDrawn
        if wait == 94:
          drawnPanned = f.mapWindow.mapSelectedDrawn
          (stage, wait, still) = (7, 0, 0)
      else: discard
      if overdue(f.index, 4600, loadStart): f.stop()
    let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0
    doAssert stage == 7, "stopped at stage " & $stage
    let (mi, mz, mp) = (median(idle), median(zooming), median(panning))
    echo "tguimapload: ", Lines * Points, " points on a ", int(mapSize.x), " x ", int(mapSize.y),
      " map: file written in ", written, " ms, loaded ",
      "and drawn in ", loadMs, " ms; frames idle ", formatFloat(mi, ffDecimal, 1),
      " ms, zooming median ", formatFloat(mz, ffDecimal, 1), " (slowest ",
      formatFloat(zooming.max, ffDecimal, 1), "), panning median ",
      formatFloat(mp, ffDecimal, 1), " (slowest ", formatFloat(panning.max, ffDecimal, 1),
      "); points drawn at fit ", drawnAtFit, ", zoomed in ", drawnClose, "; ", selectedPoints,
      " selected, ", selectedDrawn, " of them highlighted, frames ",
      formatFloat(median(selectedFrames), ffDecimal, 1), " ms; zoomed in on them to ",
      closest, " a pixel and out: ", drawnClosest, " highlighted at the closest on a receiver, ",
      drawnAway, " two views away, ", drawnPanned, " back, ", drawnRefit, " at fit again, ",
      "frames median ",
      formatFloat(median(closeFrames), ffDecimal, 1), " ms (slowest ",
      formatFloat(closeFrames.max, ffDecimal, 1), ")"
    doAssert coloured, "no receiver drawn three quarters of the way into the survey"
    doAssert drawnAtFit < Lines * Points div 4, "few points drawn: " & $drawnAtFit
    # The suite runs files side by side, so a frame's time is noisy: what is
    # held is that moving the map costs little more than an idle frame, and
    # stays within the floor for software OpenGL (33 ms).
    doAssert mz < mi + 15 and mp < mi + 15 and mz < 33 and mp < 33, "the map lags: zooming " &
      $mz & " ms, panning " & $mp & " ms a frame, idle " & $mi
    # A selection of hundreds of thousands of points is highlighted about one
    # a pixel and a half, not every one of them.
    doAssert selectedPoints > 100_000, $selectedPoints & " points selected"
    doAssert selectedDrawn > 1000 and selectedDrawn < selectedPoints div 2,
      $selectedDrawn & " of " & $selectedPoints & " highlighted"
    # Zoomed in as far as the map goes (the program would have crashed on the
    # way): the few selected points round the view are drawn (the receiver
    # in view, and again after a pan away and back: thinned for each view),
    # and zoomed out to fit, about as many as before (the scale they were
    # thinned for may be up to half again finer: up to 2.25 times as many).
    doAssert closest > 0 and closest < 0.01, "zoomed in to " & $closest & " a pixel"
    doAssert drawnClosest in 1 .. 100, $drawnClosest & " highlighted at the closest zoom"
    doAssert drawnAway in 0 .. 100, $drawnAway & " highlighted two views away"
    doAssert drawnPanned in 1 .. 100, $drawnPanned & " highlighted, panned back"
    doAssert drawnRefit >= selectedDrawn * 9 div 10 and drawnRefit <= selectedDrawn * 9 div 4 and
      drawnRefit < selectedPoints div 2,
      $drawnRefit & " highlighted at fit again, " & $selectedDrawn & " before"

main()
