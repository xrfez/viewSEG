## The trace panel in the running frontend, headless: a fixture gather opens
## in the plot window as greyscale density on white paper, and the pixels
## read back from the window match a CPU reference of the same colour map
## (`amplitudeAt`, `densityColour`), with tiles cut into blocks of a small
## texture limit, for the whole gather and for a zoom in which each sample
## spans several pixels; outside the data the plot is white; the display
## header shows the gather's values; a view asked for past the data shows
## the data to the plot's edges, no paper beside it; the window's own
## controls are drawn in it (the selected display mode on the selection
## colour), not on the main toolbar, and wrap onto more lines in a narrow
## window instead of running past it; and the file is never changed.
##
## Seen to fail: with the shader taking the nearest sample instead of
## interpolating, `wholeGather` found 1619 of 24960 pixels off the
## reference; with the image's texture coordinates upside down, 5064; with
## blocks side by side in time not sharing a column, 480 (the seams); with
## the view limits 5 % past the data, as they were, `noPaperPastTheData`
## found the view starting at -1.5, a trace's width of paper on the left;
## with the strip never wrapping, `narrowWindowWrapsTheStrip` found the
## trace scale box past the window's right edge.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[options, os, times]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/fixtures

const
  textureLimit = 64 # tiles of 24 x 500 values become 16 blocks
  tolerance = 3     # per channel, for float rounding on the GPU

type
  Shot = object
    pixels: seq[Rgba]
    width: int
    plot: Rect          ## where the density image lies, in framebuffer pixels
    view: Viewport
    tiles: seq[Tile]
    scale: float32
    marks: seq[(string, Rect)]
    header: seq[string] ## the display header's rows

proc reference(s: Shot; px, py: float64): Rgba =
  ## What the pixel centred at (`px`, `py`) should show.
  let x = s.view.traces.lo + (px - s.plot.pos.x) / s.plot.size.x * s.view.traces.width
  let t = s.view.timeMs.lo + (py - s.plot.pos.y) / s.plot.size.y * s.view.timeMs.width
  result = PaperBackground
  for tile in s.tiles: # later tiles are drawn over earlier ones
    if tile.contains(x, t):
      result = greyLut().densityColour(tile.amplitudeAt(x, t), s.scale)

func close(a, b: Rgba): bool =
  abs(a.r.int - b.r.int) <= tolerance and abs(a.g.int - b.g.int) <= tolerance and
    abs(a.b.int - b.b.int) <= tolerance

proc mismatches(s: Shot; step = 3): (int, int) =
  ## Pixels on a grid inside the plot (a few pixels in from its edge) that match
  ## no reference within one pixel of them, and the pixels looked at.
  let x0 = int(s.plot.pos.x) + 3 # the plot's border is drawn over the edge
  let y0 = int(s.plot.pos.y) + 3
  let x1 = int(s.plot.pos.x + s.plot.size.x) - 4
  let y1 = int(s.plot.pos.y + s.plot.size.y) - 4
  for y in countup(y0, y1, step):
    for x in countup(x0, x1, step):
      let got = s.pixels[y * s.width + x]
      var ok = false
      for dy in -1 .. 1:
        for dx in -1 .. 1:
          if not ok and close(got, s.reference(float64(x + dx) + 0.5, float64(y + dy) + 0.5)):
            ok = true
      inc result[1]
      if not ok:
        if result[0] < 5:
          echo "  pixel (", x, ", ", y, "): ", toHex(got), ", reference ",
            toHex(s.reference(float64(x) + 0.5, float64(y) + 0.5))
        inc result[0]

func mark(s: Shot; name: string): Rect =
  for (n, r) in s.marks:
    if n == name: return r
  Rect()

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

proc answered(f: FrameInfo): bool =
  ## Whether the newest tile answers the panel's newest request.
  let k = f.core.findPanel(MainPanel)
  let p = f.core.panels[k]
  let tiles = f.core.tiles(k)
  p.laidOut and not p.pending.isEmpty and p.pending.gen == p.requestGen and tiles.len > 0 and
    tiles[^1].request == p.pending

proc capture(f: FrameInfo): Shot =
  let k = f.core.findPanel(MainPanel)
  let p = f.core.panels[k]
  result = Shot(pixels: f.readFrame, width: f.width, plot: f.markOf("plot.data"),
    view: f.tracePanel.drawnView, scale: displayScale(p.clip, p.layers[0].display.reversed))
  for t in f.core.tiles(k): result.tiles.add t
  for name in ["plot.Greyscale density", "plot.Wiggle", "tool.Greyscale density", "toolbar"]:
    result.marks.add (name, f.markOf(name))
  for field in p.shownFields: result.header.add $field

withFixtures fx:
  let path = fx.surveySegy()
  let before = snapshot(path)
  var stage = 0
  var waited = 0
  var whole, zoomed, wider: Shot
  var theme: Theme
  proc onFrame(f: FrameInfo) =
    inc waited
    let k = f.core.findPanel(MainPanel)
    let p = f.core.panels[k]
    case stage
    of 0: # the file opens; show the samples as they are, for exact values
      if p.laidOut:
        var d = p.layers[0].display
        d.gain = dgNone
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        stage = 1
    of 1:
      if f.answered:
        whole = f.capture
        theme = f.theme
        # traces 5 .. 15, 100 .. 300 ms: several pixels per sample
        var v = p.view
        v.traces = Span(lo: 4.5, hi: 15.5)
        v.timeMs = Span(lo: 100, hi: 300)
        f.showView(v)
        stage = 2
    of 2:
      if f.answered and f.tracePanel.drawnView.timeMs.lo == 100:
        zoomed = f.capture
        var v = p.view
        v.traces = Span(lo: -1.5, hi: 23.5) # a trace's width past the first one
        v.timeMs = Span(lo: -20, hi: 998)
        f.showView(v)
        stage = 3
    of 3:
      if f.answered and f.tracePanel.drawnView.traces.hi > 20:
        wider = f.capture
        stage = 4
        f.stop()
    else: discard
    if waited > 1500: f.stop() # given up: the checks below say what is missing
  let code = run(RunOptions(maxFrames: 2000, openPaths: @[path], theme: forceDark,
    maxTextureSize: textureLimit, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert stage == 4, "stopped at stage " & $stage

  block wholeGather:
    let s = whole
    doAssert s.plot.size.x > 300 and s.plot.size.y > 200, $s.plot
    doAssert s.tiles.len >= 1 and s.tiles[^1].request.count == Channels
    doAssert s.tiles[^1].columns > textureLimit, "the tile fits one texture: no blocks"
    let (bad, seen) = s.mismatches()
    echo "tguipanel: whole gather, ", seen, " pixels, ", bad, " off the reference"
    doAssert bad == 0, $bad & " of " & $seen & " pixels differ from the reference"
    doAssert s.header == @["FFID", "channel"], $s.header

  block zoomedIn:
    let s = zoomed
    let r = s.tiles[^1].request
    doAssert r.stride == 1 and r.decimation == 1, $r
    doAssert s.plot.size.y / (s.view.timeMs.width / DtMs) > 2, "not zoomed in"
    let (bad, seen) = s.mismatches(step = 2)
    echo "tguipanel: zoomed in, ", seen, " pixels, ", bad, " off the reference"
    doAssert bad == 0, $bad & " of " & $seen & " pixels differ from the reference"

  block noPaperPastTheData:
    # asked for a view past the first trace and before the record's start,
    # the plot shows the data to its edges
    let s = wider
    doAssert s.view.traces == Span(lo: -0.5, hi: 23.5) and s.view.timeMs == Span(lo: 0, hi: 998),
      "the view went past the data: " & $s.view
    let (bad, seen) = s.mismatches()
    doAssert bad == 0, $bad & " of " & $seen & " pixels differ from the reference"
    var paper = 0
    let x = int(s.plot.pos.x) + 3 # just inside the left edge (its border is drawn over it)
    for y in int(s.plot.pos.y) + 3 ..< int(s.plot.pos.y + s.plot.size.y) - 3:
      if s.pixels[y * s.width + x] == PaperBackground: inc paper
    doAssert paper < int(s.plot.size.y / 4), $paper & " paper pixels down the left edge"

  block controlsInTheWindow:
    let s = whole
    let density = s.mark("plot.Greyscale density")
    doAssert density.size.x > 0, "no display mode buttons in the plot window"
    doAssert s.mark("plot.Wiggle").size.x > 0
    doAssert s.mark("tool.Greyscale density").size.x == 0, "a display mode on the toolbar"
    let bar = s.mark("toolbar")
    doAssert density.pos.y > bar.pos.y + bar.size.y, "the mode buttons sit on the toolbar"
    # the selected mode's button carries the selection colour behind its symbol
    var lit = 0
    for y in int(density.pos.y) ..< int(density.pos.y + density.size.y):
      for x in int(density.pos.x) ..< int(density.pos.x + density.size.x):
        if distance(s.pixels[y * s.width + x], theme.roles[rlSelection]) <= 2: inc lit
    doAssert lit > int(density.size.x * density.size.y / 4),
      "the selected mode is not marked: " & $lit & " pixels"

  doAssert snapshot(path) == before, "showing the file changed it"

  block narrowWindowWrapsTheStrip:
    # In a narrow window the strip's controls wrap onto more lines, inside
    # the window, above the plot; nothing makes the window scroll.
    const strip = ["plot.Greyscale density", "plot.Wiggle", "plot.trace scale",
      "plot.time scale", "plot.zoom out", "plot.zoom in", "plot.fit", "plot.back", "plot.more"]
    var marks: seq[(string, Rect)]
    proc onNarrow(f: FrameInfo) =
      if f.answered and f.markOf("plot.data").size.x > 0:
        for name in @strip & @["plot", "plot.data"]:
          marks.add (name, f.markOf(name))
        f.stop()
      if f.index > 1500: f.stop()
    let code = run(RunOptions(maxFrames: 2000, openPaths: @[path], windowSize: (640, 720),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onNarrow))
    doAssert code == 0 and marks.len > 0, "the narrow window never showed the plot"
    let s = Shot(marks: marks)
    let win = s.mark("plot")
    let data = s.mark("plot.data")
    var lowest = 0'f32
    for name in strip:
      let m = s.mark(name)
      doAssert m.size.x > 0, name & " is not drawn"
      doAssert m.pos.x >= win.pos.x and m.pos.x + m.size.x <= win.pos.x + win.size.x,
        name & " is outside the window: " & $m & " in " & $win
      lowest = max(lowest, m.pos.y + m.size.y)
    doAssert data.pos.y >= lowest and data.pos.x + data.size.x <= win.pos.x + win.size.x and
      data.pos.y + data.size.y <= win.pos.y + win.size.y, "the plot " & $data & " in " & $win

# ------------------------------------------------- screenshots of real data --
# With `VIEWSEG_SCREENSHOTS=<dir>` and the example files present (they are
# local only), the plot window is saved on real records as record-*.png:
# docs/screenshots/ holds the committed ones.

const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

proc recordShot(path, file: string; traces = Span(); timeMs = Span(); light = false) =
  ## Opens `path` in a 1600 × 1000 window, shows `traces` and `timeMs` (the
  ## whole gather when empty) with the default display, and saves the frame
  ## once the tile for that view is drawn.
  let dir = getEnv("VIEWSEG_SCREENSHOTS")
  var stage = 0
  var saved = false
  proc onFrame(f: FrameInfo) =
    let p = f.core.panels[f.core.findPanel(MainPanel)]
    if stage == 0 and p.laidOut and f.answered:
      if traces.hi > traces.lo:
        var v = p.view
        v.traces = traces
        v.timeMs = timeMs
        f.showView(v)
      stage = 1
    elif stage == 1 and f.answered and (traces.hi <= traces.lo or
        f.tracePanel.drawnView.traces == traces):
      stage = 2
    elif stage == 2:
      saved = f.savePng(dir / file)
      f.stop()
    if f.index > 1500: f.stop()
  let tmp = getTempDir() / ("viewseg-shots-" & $getCurrentProcessId())
  let code = run(RunOptions(maxFrames: 2000, openPaths: @[path], windowSize: (1600, 1000),
    theme: (if light: forceLight else: forceDark), indexCacheDir: some(tmp),
    userThemeDir: some(tmp / "no-user-themes"), onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0 and saved, "no screenshot of " & path
  echo "tguipanel: saved ", dir / file

if getEnv("VIEWSEG_SCREENSHOTS").len > 0:
  let morgantown = examples / "00000151_12900_11300.sgd"
  let inglewood = examples / "BO_3D-Inglewood_rev21_v7.sgy"
  if fileExists(morgantown):
    createDir(getEnv("VIEWSEG_SCREENSHOTS"))
    recordShot(morgantown, "record-morgantown.png")
    recordShot(morgantown, "record-morgantown-lines.png", Span(lo: -0.5, hi: 450.5),
      Span(lo: 0, hi: 2000))
  if fileExists(inglewood):
    recordShot(inglewood, "record-inglewood.png", light = true)
