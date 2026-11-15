## Frame times of the running frontend while a filter's slider is dragged:
## what the user sees when setting a band-pass on a large record.
##
##   nim c -d:release -r tools/filterbench.nim <seismic file> [frames] [wiggle|density]
##
## Run it under `xvfb-run -a -s "-screen 0 1920x1080x24"` for software
## OpenGL (Mesa llvmpipe), the floor the viewer must stay usable on. It
## shows the file's first record (in density: the whole of it), sets a
## 4-8-60-80 Hz band-pass, opens the strip's Filters drop-down with a click
## and drags its f2 slider to and fro with the mouse for `frames` frames
## (default 600), the events going through SDL as a real mouse's do. It
## prints the time between frames (median, 95th percentile, worst), the
## filtered tiles drawn meanwhile and the time between them, how many
## traces each filtered, and the reads from the file (none is expected:
## the reader filters the samples it holds).

import std/[algorithm, math, monotimes, options, os, strutils, times]
import ../src/viewSEG/core/[geometry, state]
import ../src/viewSEG/ui/imgui/app

proc main() =
  if paramCount() < 1:
    quit "usage: filterbench <seismic file> [frames] [wiggle|density]"
  let path = paramStr(1)
  let frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 600
  let density = paramCount() >= 3 and paramStr(3) == "density"
  var stage = 0
  var last, lastTile: MonoTime
  var intervals, tileGaps: seq[float64]
  var tiles, reads = 0
  var filtered = (high(int), 0)
  var seenTile = 0'u64
  var waited = 0
  var slider: Rect
  var f2 = (Inf, 0.0)
  var pause = 0 # frames to wait before the next stage: the pointer is seen a frame late
  let code = run(RunOptions(maxFrames: frames + 3000, openPaths: @[path],
    windowSize: (1600, 1000), indexCacheDir: some(getTempDir() / "viewseg-filterbench-cache"),
    onFrame: proc (f: FrameInfo) =
    inc waited
    let k = f.core.findPanel(MainPanel)
    let p = f.core.panels[k]
    let ts = f.core.tiles(k)
    let answered = ts.len > 0 and ts[^1].request == p.pending
    if pause > 0:
      dec pause
      return
    case stage
    of 0:
      if p.laidOut and answered:
        if density:
          var d = p.layers[0].display
          d.mode = dmDensity
          f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        f.apply Command(kind: ckProcessing, panel: MainPanel, processing: Processing(
          band: pbBandPass, f1: 4, f2: 8, f3: 60, f4: 80))
        stage = 1
    of 1:
      if answered and ts[^1].filtered > 0:
        if density:
          f.showView(fitAll(p.layout, p.view.columns, p.view.rows))
        let r = f.markOf("plot.filters")
        f.moveMouse(vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2)))
        stage = 2
        pause = 3
    of 2:
      let r = f.markOf("plot.filters")
      let at = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))
      f.pressMouse(at, true)
      f.pressMouse(at, false)
      stage = 3
      pause = 3
    of 3:
      slider = f.markOf("plot.filters f2")
      if slider.size.x > 0 and answered:
        let at = vec2(round(slider.pos.x + slider.size.x * 0.3), round(slider.pos.y +
          slider.size.y / 2))
        f.moveMouse(at)
        stage = 5
        pause = 3
    of 5:
      let at = vec2(round(slider.pos.x + slider.size.x * 0.3), round(slider.pos.y +
        slider.size.y / 2))
      f.pressMouse(at, true)
      stage = 6
    of 6: # the press is taken in: the drag starts here
      last = getMonoTime()
      lastTile = last
      seenTile = ts[^1].id
      stage = 4
    of 4:
      let now = getMonoTime()
      intervals.add float64((now - last).inNanoseconds) / 1e6
      last = now
      for t in ts:
        if t.id > seenTile:
          seenTile = t.id
          inc tiles
          tileGaps.add float64((now - lastTile).inNanoseconds) / 1e6
          lastTile = now
          filtered = (min(filtered[0], t.filtered), max(filtered[1], t.filtered))
          if not t.cached: inc reads
      let pr = p.layers[0].processing
      f2 = (min(f2[0], pr.f2), max(f2[1], pr.f2))
      # to and fro across the slider, a full sweep every 120 frames
      let phase = float64(intervals.len mod 120) / 120
      let along = 0.1 + 0.8 * (if phase < 0.5: 2 * phase else: 2 - 2 * phase)
      f.moveMouse(vec2(round(slider.pos.x + slider.size.x * along), round(slider.pos.y +
        slider.size.y / 2)))
      if intervals.len >= frames:
        f.pressMouse(vec2(round(slider.pos.x + slider.size.x * along), round(slider.pos.y +
          slider.size.y / 2)), false)
        f.stop()
    else: discard
    if waited > frames + 2900: f.stop()))
  if code != 0: quit "run() failed: " & $code
  if intervals.len == 0: quit "the slider was never dragged"
  intervals.sort()
  tileGaps.sort()
  proc at(xs: seq[float64]; q: float64): float64 =
    if xs.len == 0: NaN else: xs[min(xs.high, int(q * float64(xs.len)))]
  echo path.extractFilename, ": f2 dragged from ", f2[0].formatFloat(ffDecimal, 1), " to ",
    f2[1].formatFloat(ffDecimal, 1), " Hz over ", intervals.len, " frames",
    (if density: " (density, the whole record)" else: " (wiggles)")
  echo "  frame interval: median ", intervals.at(0.5).formatFloat(ffDecimal, 1), " ms, 95th ",
    intervals.at(0.95).formatFloat(ffDecimal, 1), " ms, worst ",
    intervals[^1].formatFloat(ffDecimal, 1), " ms"
  echo "  filtered tiles drawn: ", tiles, ", one every ", tileGaps.at(0.5).formatFloat(
    ffDecimal, 1), " ms (median; 95th ", tileGaps.at(0.95).formatFloat(ffDecimal, 1),
    " ms); traces filtered per tile: ", filtered[0], " to ", filtered[1]
  echo "  tiles read from the file while dragging: ", reads

main()
