## The plot's image in both orientations, drawn straight through
## `PlotRenderer` from synthetic tiles, headless: time down, time across
## (the first trace at the top, a positive amplitude up) and time across
## with the first trace at the bottom, each against the CPU reference of
## the same tiles (`densityAt`, `densityTint`, `traceInk`), computed along
## the data's axes and read through the plot's `Turn`:
##
## - every display mode (density, wiggles, wiggles over density) and fill
##   (positive, negative, both), with a hovered trace, two selected ones, a
##   killed one and one the file marks dead;
## - a tile with each column's extremes (zoomed out in time), and a tile
##   cut into blocks of traces by a small texture limit;
## - a pixel of the time-across image is the matching pixel of the
##   time-down image transposed, drawn with each wiggle swung the other
##   way (GPU against GPU);
## - a hover that moves draws only the stripes of the two traces (rows of
##   the image when time is across), and leaves the image a whole drawing
##   makes.
##
## Seen to fail: with density's quads placed time down whatever the turn,
## time across had 36 730 of 43 200 pixels off the reference in density;
## with the wiggle shader ignoring the swing, 25 297 in wiggles with the
## positive fill; with the wiggles placed with the trace order reversed,
## 24 724 (and 30 844 off the transposed time-down image); with a hover's
## scissor box taken as columns when time is across, the image after the
## hover differed from a whole drawing in 1 584 pixels.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, options, os, strutils]
import viewSEG/core/[geometry, state, wiggle]
import viewSEG/gpu/[plotimage, textures]
import viewSEG/view/plotink
import viewSEG/ui/imgui/app
import utils/fixtures

const tolerance = 6 ## per channel: float rounding and 8-bit blending on the GPU

let ink = WiggleInk(line: Rgba(r: 0, g: 0, b: 0, a: 255),
  positive: Rgba(r: 0, g: 0, b: 200, a: 255), negative: Rgba(r: 200, g: 0, b: 0, a: 255),
  hover: Rgba(r: 255, g: 128, b: 0, a: 255), selected: Rgba(r: 0, g: 160, b: 0, a: 255))
let paper = Rgba(r: 255, g: 255, b: 255, a: 255)
let turns = [TimeDown, turnOf(orTimeAcross), turnOf(orTimeAcross, firstAtTop = false)]

proc tileOf(count, columns: int; decimation = 1): Tile =
  ## `count` traces of `columns` values each (a sine, shifted per trace),
  ## with each column's extremes when `decimation` > 1; trace 3 killed,
  ## trace 7 dead in the file.
  result = Tile(id: 1, request: ReadRequest(first: 0, count: count, stride: 1,
    samples: columns * decimation, decimation: decimation, envelope: decimation > 1),
    dtMs: 2, t0Ms: 0, columns: columns)
  result.data = newSeq[float32](count * columns)
  if decimation > 1: result.envelope = newSeq[float32](count * 2 * columns)
  for r in 0 ..< count:
    result.traces.add r
    for c in 0 ..< columns:
      let v = float32(sin(float64(c) * 0.45 + float64(r) * 0.8)) * 1.3 # clipped in places
      result.data[r * columns + c] = v
      if decimation > 1:
        let (a, b) = if c mod 2 == 0: (-abs(v), abs(v)) else: (abs(v), -0.5 * abs(v))
        result.envelope[r * 2 * columns + 2 * c] = a
        result.envelope[r * 2 * columns + 2 * c + 1] = b
  result.edits = newSeq[set[TraceEdit]](count)
  if count > 3: result.edits[3] = {teKilled}
  result.dead = newSeq[bool](count)
  if count > 7: result.dead[7] = true

type Picture = object
  ## What one image is drawn with.
  view: Viewport
  display: DisplaySettings
  style: WiggleStyle
  hover: int
  selected: seq[bool]

proc pictureOf(v: Viewport; mode: DisplayMode; fills: set[WiggleFill]; m: Turn;
    hover: int; selected: seq[bool]): Picture =
  ## The picture of `v` on a plot turned `m` (the style swings as `m` does:
  ## a display's orientation has the turn of `FirstTraceAtTop`).
  let d = DisplaySettings(mode: mode, fills: fills, orientation: m.orientation)
  result = Picture(view: v, display: d, style: d.styleFor(v, 1, 1, 2), hover: hover,
    selected: selected)
  if m.reversed[axTraces] != turnOf(m.orientation).reversed[axTraces]:
    result.style.swing = m.swing

proc expected(t: Tile; p: Picture; i, j: int): Rgba =
  ## The pixel `i` pixels along the traces and `j` along time from the
  ## view's first position and earliest time, as the CPU draws it: as
  ## `tests/utils/plotref` does, for one tile.
  let v = p.view
  let x = v.traces.lo + (float64(i) + 0.5) / float64(v.columns) * v.traces.width
  let tm = v.timeMs.lo + (float64(j) + 0.5) / float64(v.rows) * v.timeMs.width
  let (density, wiggles) = (p.display.drawsDensity, p.display.drawsWiggles)
  result = paper
  if t.contains(x, tm):
    if density:
      let c = t.densityAt(greyLut(), x, tm, 1, paper)
      result = if wiggles: c
               else: densityTint(c, markOf(t.rowAt(x), p.hover, p.selected), ink, DensityTint)
  let (_, ts) = t.span
  if wiggles and tm >= ts.lo and tm < ts.hi:
    let ser = t.series
    for pass in 0 .. 1:
      for r in 0 ..< t.request.count:
        let m = markOf(r, p.hover, p.selected)
        let pos = float64(t.request.position(r))
        if (pass == 0 or m != tmNone) and abs(x - pos) <= p.style.reach:
          result = t.traceInk(ser, r, (x - pos) * p.style.pixelsPerTrace, tm, p.style, ink,
            m).onto(result)

proc frameOf(p: Picture; m: Turn): PlotFrame =
  PlotFrame(view: p.view, turn: m, background: paper, density: p.display.drawsDensity,
    wiggles: p.display.drawsWiggles, scale: 1, style: p.style, ink: ink, tint: DensityTint)

proc draw(r: var PlotRenderer; t: Tile; tt: var TileTextures; f: PlotFrame;
    p: Picture): seq[Rgba] =
  tt.hoverRow = p.hover
  doAssert r.render(f, [t], [tt]) != 0
  result = r.readImage
  let (w, h) = f.view.screenSize(f.turn)
  doAssert result.len == w * h and r.imageSize == (w, h)

proc offReference(t: Tile; p: Picture; m: Turn; name: string; maxSize = 0): (int, int) =
  ## The pixels of `t` drawn as `p` says on a plot turned `m` that differ
  ## from the reference, and the pixels looked at.
  var (r, err) = newPlotRenderer(greyLut(), maxSize)
  doAssert err.len == 0, err
  var tt = r.upload(t)
  tt.setMarks(t, p.selected)
  let img = r.draw(t, tt, p.frameOf(m), p)
  let (w, _) = p.view.screenSize(m)
  for j in 0 ..< p.view.rows:
    for i in 0 ..< p.view.columns:
      let (x, y) = p.view.screenPixel(m, i, j)
      let want = t.expected(p, i, j)
      inc result[1]
      if distance(img[y * w + x], want) > tolerance:
        if result[0] < 3:
          echo "  ", name, ": pixel (", i, ", ", j, ") at (", x, ", ", y, "): ",
            toHex(img[y * w + x]),
            ", expected ", toHex(want)
        inc result[0]
  tt.free()
  r.free()

proc transposed(t: Tile; p: Picture; m: Turn): int =
  ## The pixels of the image turned `m` that differ from the time-down
  ## image drawn with each wiggle swung as `m` swings them (GPU against GPU).
  var (r, err) = newPlotRenderer(greyLut())
  doAssert err.len == 0, err
  var tt = r.upload(t)
  tt.setMarks(t, p.selected)
  var f = p.frameOf(m)
  let turned = r.draw(t, tt, f, p)
  f.turn = TimeDown
  f.style.swing = m.swing
  let down = r.draw(t, tt, f, p)
  let (w, _) = p.view.screenSize(m)
  for j in 0 ..< p.view.rows:
    for i in 0 ..< p.view.columns:
      let (x, y) = p.view.screenPixel(m, i, j)
      if distance(turned[y * w + x], down[j * p.view.columns + i]) > 2: inc result
  tt.free()
  r.free()

proc hoverStripes(t: Tile; p: Picture; m: Turn): (int, int) =
  ## A hover moving from trace 2 to trace 29 on a plot turned `m`: the
  ## pixels along the traces it drew again, and the pixels of the image
  ## that then differ from a whole drawing with trace 29 hovered.
  var (r, err) = newPlotRenderer(greyLut())
  doAssert err.len == 0, err
  var tt = r.upload(t)
  tt.setMarks(t, p.selected)
  var q = p
  q.hover = 2
  discard r.draw(t, tt, q.frameOf(m), q)
  q.hover = 29
  let after = r.draw(t, tt, q.frameOf(m), q)
  result[0] = r.columnsDrawn
  var (whole, err2) = newPlotRenderer(greyLut())
  doAssert err2.len == 0, err2
  var wt = whole.upload(t)
  wt.setMarks(t, p.selected)
  let want = whole.draw(t, wt, q.frameOf(m), q)
  doAssert whole.columnsDrawn == p.view.columns
  for k in 0 ..< want.len:
    if distance(after[k], want[k]) > 0: inc result[1]
  wt.free()
  whole.free()
  tt.free()
  r.free()

var results: seq[(string, int, int)]

proc onFrame(f: FrameInfo) =
  if f.index < 2: return # the renderer's GL functions are loaded by then
  let selected = @[false, true, false, false, false, false, false, false, false, true]
  let t = tileOf(12, 64)
  # 12 traces 20 pixels apart, 64 samples on 180 pixels along time
  let v = Viewport(traces: Span(lo: -0.5, hi: 11.5), timeMs: Span(lo: -1, hi: 127),
    columns: 240, rows: 180)
  for m in turns:
    let name = $m.orientation & (if m.reversed[axTraces]: " (first at the bottom)" else: "")
    for mode in DisplayMode:
      for fills in [{wfPositive}, {wfNegative}, {wfPositive, wfNegative}]:
        if mode == dmDensity and fills != {wfPositive}: continue
        let p = pictureOf(v, mode, fills, m, 5, selected)
        let what = name & ", " & $mode & " " & $fills
        let (off, seen) = t.offReference(p, m, what)
        results.add (what, off, seen)
    let p = pictureOf(v, dmWiggle, {wfPositive, wfNegative}, m, 5, selected)
    # zoomed out in time: the columns' extremes
    let e = tileOf(12, 100, decimation = 4)
    let ve = Viewport(traces: v.traces, timeMs: Span(lo: 0, hi: 798), columns: 240, rows: 90)
    let pe = pictureOf(ve, dmWiggle, {wfPositive, wfNegative}, m, 5, selected)
    let (offE, seenE) = e.offReference(pe, m, name & ", the columns' extremes")
    results.add (name & ", the columns' extremes", offE, seenE)
    # 40 traces of 8 columns in blocks of 8 traces (one block along time:
    # where blocks meet in time, a pixel at the seam sees only its own
    # block's vertices, as `tguiplotimage` says)
    let b = tileOf(40, 8)
    let vb = Viewport(traces: Span(lo: -0.5, hi: 39.5), timeMs: Span(lo: -1, hi: 15),
      columns: 240, rows: 120)
    let (offB, seenB) = b.offReference(pictureOf(vb, dmWiggleDensity, {wfPositive}, m, 5,
      selected), m, name & ", in blocks", maxSize = 8)
    results.add (name & ", in blocks", offB, seenB)
    results.add (name & ", transposed", t.transposed(p, m), v.columns * v.rows)
    # 40 traces 6 pixels apart: the stripes of two traces are a small part
    let many = tileOf(40, 64)
    let vm = Viewport(traces: Span(lo: -0.5, hi: 39.5), timeMs: v.timeMs, columns: 240,
      rows: 180)
    let (drawn, differ) = many.hoverStripes(pictureOf(vm, dmWiggle, {wfPositive, wfNegative},
      m, 5, selected), m)
    doAssert drawn > 0 and drawn < v.columns div 2, name & ": the hover drew " & $drawn &
      " pixels along the traces of " & $v.columns
    results.add (name & ", after a hover", differ, v.columns * v.rows)
  f.stop()

withFixtures fx:
  let code = run(RunOptions(maxFrames: 100, windowSize: (640, 480), theme: forceDark,
    userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
    onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert results.len == 3 * (1 + 3 + 3 + 4), "only " & $results.len & " checks ran"
  for (name, off, seen) in results:
    echo "tguiplotturn: ", name, ": ", off, " of ", seen, " pixels off"
  for (name, off, seen) in results:
    doAssert off == 0, name & ": " & $off & " of " & $seen & " pixels off"
