## Frame times of the running frontend while the trace panel pans across a
## file, or zooms in and out of it: what the user sees when dragging or
## turning the wheel through a large gather.
##
##   nim c -d:release -r tools/panbench.nim <seismic file> [traces on screen] [frames] [pan|zoom]
##     [spectrum]
##
## Run it under `xvfb-run -a -s "-screen 0 1920x1080x24"` for software
## OpenGL (Mesa llvmpipe), the floor the viewer must stay usable on. The
## view starts on `traces on screen` traces (default 600) of the first
## gather. `pan` (the default) moves it by a fortieth of that each frame, as
## a steady drag does. `zoom` turns the mouse wheel a quarter notch each
## frame, 40 frames in, 80 out, 40 in again, about a pointer that drifts
## across the plot, so the view also moves; the events go through SDL as a
## real wheel's do. It prints the time between frames (median, 95th
## percentile, worst), how many frames showed a tile covering the whole
## view at the resolution it needs, the samples read, and for `zoom` the
## range of traces on screen and asked for. With `spectrum`, the live
## Spectrum panel is on screen meanwhile, following the view; it prints
## the spectra asked for and answered, and the traces they read.

import std/[algorithm, math, monotimes, options, os, strutils, times]
import ../src/viewSEG/core/[geometry, state]
import ../src/viewSEG/ui/imgui/app

proc main() =
  if paramCount() < 1:
    quit "usage: panbench <seismic file> [traces on screen] [frames] [pan|zoom]"
  let path = paramStr(1)
  let visible = if paramCount() >= 2: parseInt(paramStr(2)) else: 600
  let frames = if paramCount() >= 3: parseInt(paramStr(3)) else: 600
  let zooming = paramCount() >= 4 and paramStr(4) == "zoom"
  let spectrum = paramCount() >= 5 and paramStr(5) == "spectrum"
  var answers = 0
  var answered = 0'u64
  var spectrumRead = 0
  var requests = 0
  var shown = (high(int), 0)
  var asked = (high(int), 0)
  var stage = 0
  var last: MonoTime
  var intervals: seq[float64]
  var complete = 0
  var read = 0'i64
  var seenTile = 0'u64
  var x = 0.0
  var waited = 0
  var openedAt, firstTileAt: MonoTime
  let start = getMonoTime()
  let code = run(RunOptions(maxFrames: frames + 3000, openPaths: @[path],
    windowSize: (1600, 1000), indexCacheDir: some(getTempDir() / "viewseg-panbench-cache"),
    onFrame: proc (f: FrameInfo) =
    inc waited
    let k = f.core.findPanel(MainPanel)
    let p = f.core.panels[k]
    let tiles = f.core.tiles(k)
    case stage
    of 0:
      if p.laidOut:
        openedAt = getMonoTime()
        stage = 1
    of 1:
      if tiles.len > 0:
        firstTileAt = getMonoTime()
        var v = p.view
        v.traces = Span(lo: -0.5, hi: float64(visible) - 0.5)
        f.showView(v)
        if spectrum:
          f.apply(Command(kind: ckSpectrumPanel, onScreen: true, origin: coAgent))
        stage = 2
    of 2:
      if tiles.len > 0 and tiles[^1].request == p.pending and p.view.traces.lo == -0.5:
        stage = 3
        last = getMonoTime()
    of 3:
      let now = getMonoTime()
      intervals.add float64((now - last).inNanoseconds) / 1e6
      last = now
      let drawn = f.tracePanel.drawnView
      if tiles.len > 0 and tiles[^1].request.covers(p.layout, drawn,
          tiles[^1].request.margin):
        inc complete
      if spectrum:
        let live = f.core.spectra[0]
        requests = live.asks
        if live.spectrum.gen > answered:
          answered = live.spectrum.gen
          inc answers
          spectrumRead += live.spectrum.read
      for t in tiles:
        if t.id > seenTile:
          seenTile = t.id
          read += int64(t.request.count) * int64(t.request.samples)
      if zooming:
        # a quarter notch a frame: 40 in, 80 out, 40 in; the pointer drifts
        let plot = f.markOf("plot.data")
        let n = intervals.len mod 160
        let notch = if n < 40 or n >= 120: 0.25'f32 else: -0.25'f32
        let along = 0.2 + 0.6 * (0.5 + 0.5 * sin(float64(intervals.len) / 50))
        let at = vec2(round(plot.pos.x + plot.size.x * along), round(plot.pos.y +
          plot.size.y * 0.3))
        f.moveMouse(at)
        f.scrollWheel(at, notch)
        let w = int(p.view.traces.width)
        shown = (min(shown[0], w), max(shown[1], w))
        if not p.pending.isEmpty:
          asked = (min(asked[0], p.pending.count), max(asked[1], p.pending.count))
      else:
        x += float64(visible) / 40
        if x + float64(visible) > float64(p.layout.traces): x = 0
        var v = p.view
        v.traces = Span(lo: x - 0.5, hi: x + float64(visible) - 0.5)
        f.showView(v)
      if intervals.len >= frames: f.stop()
    else: discard
    if waited > frames + 2900: f.stop()))
  if code != 0: quit "run() failed: " & $code
  if intervals.len == 0: quit "the file never showed a tile"
  let opened = float64((openedAt - start).inMilliseconds)
  let first = float64((firstTileAt - openedAt).inMilliseconds)
  intervals.sort()
  proc at(q: float64): float64 = intervals[min(intervals.high, int(q * float64(intervals.len)))]
  echo path.extractFilename, ": ", visible, " traces on screen, ", intervals.len, " frames ",
    (if zooming: "zooming" else: "panning")
  echo "  open to layout ", opened, " ms; layout to first tile ", first, " ms"
  echo "  frame interval: median ", at(0.5).formatFloat(ffDecimal, 1), " ms, 95th ",
    at(0.95).formatFloat(ffDecimal, 1), " ms, worst ", intervals[^1].formatFloat(ffDecimal, 1),
    " ms"
  echo "  frames whose newest tile covers the view: ", complete, " of ", intervals.len
  echo "  samples read: ", read
  if zooming:
    echo "  traces on screen from ", shown[0], " to ", shown[1], "; asked for from ", asked[0],
      " to ", asked[1]
  if spectrum:
    echo "  the live spectrum panel: ", requests, " requests, ", answers,
      " answers shown; traces read for them: ", spectrumRead

main()
