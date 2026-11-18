## The plot image's wiggle shader against its CPU reference (`traceInk`) on
## synthetic tiles drawn straight through `PlotRenderer`, headless, where
## the fixtures of `tguiwiggle` cannot reach:
##
## - far positions and late times: traces 10 000 000 and up (a large gather
##   shown whole, or a cube shown as one gather), and 8 samples of a 20 s
##   record zoomed in to 200 pixel rows;
## - a tile with each column's extremes (`envelope`, zoomed out in time),
##   also cut into blocks of traces by a small texture limit (blocks side
##   by side in time are left out: a pixel row at their seam sees only its
##   own block's vertices, so its line can be a pixel short there, which
##   happens only where a tile has more columns than the GPU's texture
##   limit);
## - a hovered and a selected trace (the second pass), far out;
## - a one-trace record and one-sample traces.
##
## Seen to fail: with the shader given absolute positions and times in
## float32 (as it was), the traces at 10 000 000 had 13 991 of 60 000
## pixels off the reference (the wiggles a trace away from their
## baselines), and the 20 s record zoomed in 986 (pixel rows a sample
## apart drawn at one time).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, options, os, strutils]
import viewSEG/core/[geometry, state, wiggle]
import viewSEG/gpu/[plotimage, textures]
import viewSEG/ui/imgui/app
import utils/fixtures

const tolerance = 6 ## per channel: float rounding and 8-bit blending on the GPU

let ink = WiggleInk(line: Rgba(r: 0, g: 0, b: 0, a: 255),
  positive: Rgba(r: 0, g: 0, b: 200, a: 255), negative: Rgba(r: 200, g: 0, b: 0, a: 255),
  hover: Rgba(r: 255, g: 128, b: 0, a: 255), selected: Rgba(r: 0, g: 160, b: 0, a: 255))
let paper = Rgba(r: 255, g: 255, b: 255, a: 255)

proc tileAt(first, count, columns: int; t0Ms, dtMs: float64; decimation = 1): Tile =
  ## `count` traces at positions `first`, `first + 1`, ... of `columns`
  ## values each (a sine, shifted per trace), from `t0Ms`; with each
  ## column's extremes when `decimation` > 1.
  result = Tile(id: 1, request: ReadRequest(first: first, count: count, stride: 1,
    samples: columns * decimation, decimation: decimation, envelope: decimation > 1),
    dtMs: dtMs, t0Ms: t0Ms, columns: columns)
  result.data = newSeq[float32](count * columns)
  if decimation > 1: result.envelope = newSeq[float32](count * 2 * columns)
  for r in 0 ..< count:
    result.traces.add first + r
    for c in 0 ..< columns:
      let v = float32(sin(float64(c) * 0.7 + float64(r)))
      result.data[r * columns + c] = v
      if decimation > 1: # the extremes, falling first in odd columns
        let (a, b) = if c mod 2 == 0: (-abs(v), abs(v)) else: (abs(v), -0.5 * abs(v))
        result.envelope[r * 2 * columns + 2 * c] = a
        result.envelope[r * 2 * columns + 2 * c + 1] = b

proc expected(t: Tile; v: Viewport; st: WiggleStyle; hover: int; selected: seq[bool];
    i, j: int): Rgba =
  ## Image pixel (`i`, `j`) as `traceInk` draws it: paper, each trace over
  ## the ones before it, the marked ones again on top.
  let x = v.traces.lo + (float64(i) + 0.5) / float64(v.columns) * v.traces.width
  let tm = v.timeMs.lo + (float64(j) + 0.5) / float64(v.rows) * v.timeMs.width
  result = paper
  let (_, ts) = t.span
  if tm >= ts.lo and tm < ts.hi:
    let ser = t.series
    for r in 0 ..< t.request.count: # the marked traces' tint, under the traces
      let m = markOf(r, hover, selected)
      let pos = float64(t.request.position(r))
      if m != tmNone and abs(x - pos) <= st.reach:
        result = tintInk((x - pos) * st.pixelsPerTrace, st, ink, m).onto(result)
    for pass in 0 .. 1:
      for r in 0 ..< t.request.count:
        let m = markOf(r, hover, selected)
        let pos = float64(t.request.position(r))
        if (pass == 0 or m != tmNone) and abs(x - pos) <= st.reach:
          result = t.traceInk(ser, r, (x - pos) * st.pixelsPerTrace, tm, st, ink, m).onto(result)

proc offReference(t: Tile; v: Viewport; maxSize = 0; hover = -1;
    selected: seq[bool] = @[]): int =
  ## The pixels of `t` drawn as wiggles with both fills in view `v` that
  ## differ from the reference.
  var (r, err) = newPlotRenderer(maxSize)
  doAssert err.len == 0, err
  var tt = r.upload(t)
  tt.hoverRow = hover
  if selected.len > 0: tt.setMarks(t, selected)
  var d = DisplaySettings()
  d.fills = {wfPositive, wfNegative}
  let st = d.styleFor(v, 1, 1, 2)
  doAssert r.render(PlotFrame(view: v, background: paper, density: false, wiggles: true,
    scale: 1, style: st, ink: ink), [t], [tt]) != 0
  let img = r.readImage
  doAssert img.len == v.columns * v.rows
  for j in 0 ..< v.rows:
    for i in 0 ..< v.columns:
      let want = t.expected(v, st, hover, selected, i, j)
      if distance(img[j * v.columns + i], want) > tolerance:
        if result < 3:
          echo "  pixel (", i, ", ", j, "): ", toHex(img[j * v.columns + i]), ", expected ",
            toHex(want)
        inc result
  tt.free()
  r.free()

func view(lo, hi, t0, t1: float64; columns, rows: int): Viewport =
  Viewport(traces: Span(lo: lo, hi: hi), timeMs: Span(lo: t0, hi: t1), columns: columns,
    rows: rows)

var results: seq[(string, int)]

proc onFrame(f: FrameInfo) =
  if f.index < 2: return # the renderer's GL functions are loaded by then
  template check(name: string; off: int) = results.add (name, off)
  for first in [0, 100_000, 10_000_000]:
    check("traces at " & $first, tileAt(first, 3, 64, 0, 2).offReference(
      view(float64(first) - 0.5, float64(first) + 2.5, 0, 126, 300, 200)))
  for t0 in [0.0, 20_000.0]:
    check("8 samples at " & $t0 & " ms", tileAt(0, 3, 64, t0, 0.25).offReference(
      view(-0.5, 2.5, t0 + 4, t0 + 6, 300, 200)))
  check("the columns' extremes", tileAt(0, 3, 200, 0, 2, decimation = 4).offReference(
    view(-0.5, 2.5, 0, 1598, 300, 150)))
  # 40 traces of 8 columns in blocks of 8 traces (16 / 2: two texels a column)
  check("the columns' extremes in blocks", tileAt(0, 40, 8, 0, 2, decimation = 4).offReference(
    view(-0.5, 39.5, 0, 62, 400, 150), maxSize = 16))
  check("hovered and selected, far out", tileAt(10_000_000, 3, 64, 0, 2).offReference(
    view(10_000_000 - 0.5, 10_000_002.5, 0, 126, 300, 200), hover = 1,
    selected = @[false, false, true]))
  check("one trace", tileAt(0, 1, 64, 0, 2).offReference(view(-0.5, 0.5, 0, 126, 300, 200)))
  check("one sample", tileAt(0, 3, 1, 0, 2).offReference(view(-0.5, 2.5, -1, 1, 300, 20)))
  f.stop()

proc main*() =

  withFixtures fx:
    let code = run(RunOptions(maxFrames: 100, windowSize: (640, 480), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert results.len == 10, "only " & $results.len & " checks ran"
    for (name, off) in results:
      echo "tguiplotimage: ", name, ": ", off, " pixels off the reference"
    for (name, off) in results:
      doAssert off == 0, name & ": " & $off & " pixels off the reference"

when isMainModule:
  main()
