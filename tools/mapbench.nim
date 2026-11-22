## Frame times of the running frontend while a survey at real scale is
## imported and then looked at on the map: what the user sees while the
## files are read (the UI thread must not stall), and the map with every
## source and receiver of the survey (millions of points) while it is
## zoomed, panned, hovered and selected from.
##
##   nim c -d:release -r tools/mapbench.nim <seismic file> <survey files...>
##
## Run it under `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"` for
## software OpenGL (Mesa llvmpipe), the floor the viewer must stay usable
## on. The surveys of `tests/utils/bigsurvey` (`tools/surveybench gen`) are
## what it was made for. The window is 1600 x 1000 in the "Plot and map"
## layout. It opens the seismic file, imports the survey files for it
## (Project > Import survey), then: idle frames; 60 frames of zooming, a
## wheel notch a frame; 60 of panning (arrow keys); 60 of hovering, the
## pointer moving across the map; a box selection (Shift + drag); a click on
## a point. For each it prints the time between frames (median, 95th
## percentile, worst) and, for the import, how long it took; the points the
## map drew.

import std/[algorithm, math, monotimes, options, os, strutils, times]
import ../src/viewSEG/core/[geometry, join, selection, state, survey]
import ../src/viewSEG/ui/imgui/app

func stats(xs: seq[float64]): string =
  if xs.len == 0: return "no frames"
  let s = xs.sorted
  "median " & formatFloat(s[s.len div 2], ffDecimal, 1) & " ms, 95% " &
    formatFloat(s[min(s.high, s.len * 95 div 100)], ffDecimal, 1) & " ms, worst " &
    formatFloat(s[^1], ffDecimal, 1) & " ms (" & $s.len & " frames)"

proc main() =
  if paramCount() < 2: quit "usage: mapbench <seismic file> <survey files...>"
  let segy = paramStr(1)
  var files: seq[JoinFile]
  for i in 2 .. paramCount(): files.add JoinFile(path: paramStr(i), kind: jkSps)
  let preset = currentSourcePath().parentDir.parentDir / "assets" / "layouts" /
    "Plot and map.nif"
  var stage, wait = 0
  var last = getMonoTime()
  var stageStart = getMonoTime()
  var importMs = 0.0
  var importing, idle, zooming, panning, hovering, boxing, clicking: seq[float64]
  var drawnAtFit, drawnClose, selected, selectedPoints = 0
  var at, a, b: Vec2
  var loads, serial = 0
  var plot: Rect
  proc onFrame(f: FrameInfo) =
    let now = getMonoTime()
    let ms = float64((now - last).inMicroseconds) / 1000
    last = now
    inc wait
    case stage
    of 0: # the file open, the layout loaded
      if f.index == 2:
        loads = f.core.layoutLoads
        f.apply Command(kind: ckLoadLayout, docPath: preset)
      if f.core.sessions.len == 1 and f.core.layoutLoads > loads and f.core.jobs.active.len == 0 and
          wait > 10:
        serial = f.core.joinReport.serial
        f.apply Command(kind: ckJoin, joinFile: f.core.sessions[0].id, joinFiles: files)
        (stage, wait, stageStart) = (1, 0, now)
    of 1: # the import: every frame while it runs
      importing.add ms
      if f.core.joinReport.serial > serial and f.core.jobs.active.len == 0:
        importMs = float64((now - stageStart).inMicroseconds) / 1000
        (stage, wait) = (2, 0)
    of 2: # the map drawn, idle
      if wait == 1:
        plot = f.markOf("map.data")
        at = vec2(round(plot.pos.x + plot.size.x / 2), round(plot.pos.y + plot.size.y / 2))
        f.moveMouse(at)
      if wait == 3: f.pressMouse(at, true)
      if wait == 5: f.pressMouse(at, false)
      if wait in 20 ..< 50: idle.add ms
      if wait == 50:
        drawnAtFit = f.mapWindow.mapPointsDrawn
        (stage, wait) = (3, 0)
    of 3: # zoom in and out, a notch a frame
      if wait > 1: zooming.add ms
      f.scrollWheel(at, (if wait < 30: 1 else: -1))
      if wait == 60: (stage, wait) = (4, 0)
    of 4: # zoomed in a little, pan a tenth of the view a frame
      if wait == 1: f.scrollWheel(at, 3)
      if wait > 4:
        if wait > 5: panning.add ms
        f.pressKey(skRight, true)
        f.pressKey(skRight, false)
      if wait == 64:
        drawnClose = f.mapWindow.mapPointsDrawn
        f.scrollWheel(at, -3)
        (stage, wait) = (5, 0)
    of 5: # hover: the pointer across the map, a step a frame
      if wait > 5:
        let t = float32(wait - 5) / 60
        f.moveMouse(vec2(plot.pos.x + plot.size.x * (0.1 + 0.8 * t),
          plot.pos.y + plot.size.y * (0.3 + 0.4 * t)))
        if wait > 6: hovering.add ms
      if wait == 66:
        a = vec2(plot.pos.x + plot.size.x * 0.3, plot.pos.y + plot.size.y * 0.3)
        b = vec2(plot.pos.x + plot.size.x * 0.7, plot.pos.y + plot.size.y * 0.7)
        (stage, wait) = (6, 0)
    of 6: # a box selection: Shift + drag
      case wait
      of 1: f.moveMouse(a)
      of 2: f.pressKey(skShift, true, {smShift})
      of 3: f.pressMouse(a, true)
      of 4 .. 13:
        let t = float32(wait - 3) / 10
        f.moveMouse(vec2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
      of 14: f.pressMouse(b, false)
      of 15: f.pressKey(skShift, false)
      else: discard
      if wait > 3: boxing.add ms
      if wait == 45:
        (selected, selectedPoints) = (f.core.selection.selectedCount,
          f.core.selection.points.len)
        (stage, wait) = (7, 0)
    of 7: # a click on the point under the pointer
      case wait
      of 1: f.moveMouse(at)
      of 3: f.pressMouse(at, true)
      of 4: f.pressMouse(at, false)
      else: discard
      if wait > 2: clicking.add ms
      if wait == 30: f.stop()
    else: discard
    if (now - stageStart).inSeconds > 600: f.stop()
  let code = run(RunOptions(openPaths: @[segy], windowSize: (1600, 1000), theme: forceDark,
    onFrame: onFrame))
  doAssert code == 0
  echo "mapbench: stopped at stage ", stage, " of 7"
  echo "  import ", formatFloat(importMs, ffDecimal, 0), " ms; frames meanwhile: ",
    stats(importing)
  echo "  idle: ", stats(idle)
  echo "  zooming: ", stats(zooming)
  echo "  panning: ", stats(panning)
  echo "  hovering: ", stats(hovering)
  echo "  box selection: ", stats(boxing), "; ", selectedPoints, " points and ", selected,
    " traces selected"
  echo "  click: ", stats(clicking)
  echo "  points drawn at fit ", drawnAtFit, ", zoomed in ", drawnClose

main()
