## Frame times of the running frontend while the trace panel pans across a
## file: what the user sees when dragging through a large gather.
##
##   nim c -d:release -r tools/panbench.nim <seismic file> [traces on screen] [frames]
##
## Run it under `xvfb-run -a -s "-screen 0 1920x1080x24"` for software
## OpenGL (Mesa llvmpipe), the floor the viewer must stay usable on. The
## view shows `traces on screen` traces (default 600) of the first gather
## and moves by a fortieth of that each frame, as a steady drag does. It
## prints the time between frames (median, 95th percentile, worst), how many
## frames showed a tile covering the whole view at the resolution it needs,
## and the samples read.

import std/[algorithm, monotimes, options, os, strutils, times]
import ../src/viewSEG/core/[geometry, state]
import ../src/viewSEG/ui/imgui/app

proc main() =
  if paramCount() < 1:
    quit "usage: panbench <seismic file> [traces on screen] [frames]"
  let path = paramStr(1)
  let visible = if paramCount() >= 2: parseInt(paramStr(2)) else: 600
  let frames = if paramCount() >= 3: parseInt(paramStr(3)) else: 600
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
      for t in tiles:
        if t.id > seenTile:
          seenTile = t.id
          read += int64(t.request.count) * int64(t.request.samples)
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
  echo path.extractFilename, ": ", visible, " traces on screen, ", intervals.len, " frames panning"
  echo "  open to layout ", opened, " ms; layout to first tile ", first, " ms"
  echo "  frame interval: median ", at(0.5).formatFloat(ffDecimal, 1), " ms, 95th ",
    at(0.95).formatFloat(ffDecimal, 1), " ms, worst ", intervals[^1].formatFloat(ffDecimal, 1),
    " ms"
  echo "  frames whose newest tile covers the view: ", complete, " of ", intervals.len
  echo "  samples read while panning: ", read

main()
