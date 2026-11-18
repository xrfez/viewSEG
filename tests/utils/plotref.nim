## The CPU reference of the plot's image, for GUI tests: what each pixel of
## the image `gpu/plotimage` draws should be, from the tiles it drew, by the
## plain procs of `core/tiles` and `core/wiggle` the shaders are tested
## against.
##
## `capture` takes the image and what it was drawn from in a frame hook;
## `mismatches` counts the pixels that differ from `expected`. Pixels are
## named along the data's axes: `i` along the traces, `j` along time, from
## the view's first position and earliest time; `at` finds such a pixel in
## the image through the plot's `Turn`, so a plot turned time across is
## compared with the same reference, transposed.

import std/math
import viewSEG/core/[geometry, state, wiggle]
import viewSEG/view/[plotink, theme]
import viewSEG/ui/imgui/app

const Tolerance* = 6 ## per channel: float rounding and 8-bit blending on the GPU

type
  Shot* = object
    ## A plot image and what it was drawn from.
    image*: seq[Rgba] ## as drawn, rows from the top
    width*: int       ## the image's width
    w*, h*: int       ## pixels along the traces and along time (the view's)
    turn*: Turn
    view*: Viewport
    tiles*: seq[Tile]
    display*: DisplaySettings
    ink*: PlotInk
    style*: WiggleStyle
    scale*: float32
    density*, wiggles*: bool
    hover*: int
    selection*: Selection

proc capture*(f: FrameInfo): Shot =
  ## The main panel's last plot image and what it was drawn from. Density
  ## and wiggles as the mode says: density only in the modes that name it,
  ## wiggles in the wiggle modes, at every trace spacing.
  let k = f.core.findPanel(MainPanel)
  let p = f.core.panels[k]
  let d = p.layers[0].display
  let (img, width, _) = f.tracePanel.plotImage
  let v = f.tracePanel.drawnView
  let scale = displayScale(p.reference, d.gainDb)
  result = Shot(image: img, width: width, w: v.columns, h: v.rows, turn: d.turn, view: v,
    display: d, ink: plotInk(f.theme, d),
    style: d.styleFor(v, scale, 1, 2), scale: scale, density: d.mode != dmWiggle,
    wiggles: d.mode != dmDensity, hover: f.core.selection.hover, selection: f.core.selection)
  for t in f.core.tiles(k): result.tiles.add t

proc at*(s: Shot; i, j: int): Rgba =
  ## The image's pixel `i` along the traces and `j` along time.
  let (x, y) = s.view.screenPixel(s.turn, i, j)
  s.image[y * s.width + x]

func xOf*(s: Shot; i: int): float64 =
  ## The position at the centre of image column `i`.
  s.view.traces.lo + (float64(i) + 0.5) / float64(s.w) * s.view.traces.width

func tOf*(s: Shot; j: int): float64 =
  ## The time at the centre of image row `j`.
  s.view.timeMs.lo + (float64(j) + 0.5) / float64(s.h) * s.view.timeMs.width

func column*(s: Shot; position: float64): int =
  ## The image column whose centre is nearest to `position`.
  int(round((position - s.view.traces.lo) / s.view.traces.width * float64(s.w) - 0.5))

func row*(s: Shot; tMs: float64): int =
  ## The image row holding `tMs`.
  int(floor((tMs - s.view.timeMs.lo) / s.view.timeMs.width * float64(s.h)))

proc expected*(s: Shot; i, j: int; nudge = 0.0): Rgba =
  ## What image pixel (`i`, `j`) should show: the tiles oldest first (but
  ## for those a newer one covers in view: `hidden`), each its area
  ## (density, blank on a killed trace, or the background) then its wiggles
  ## (none for a killed trace), the marked traces (hovered, selected, lit up
  ## from the map) again on top. `nudge`: positions added to the pixel's
  ## centre along the traces.
  let (x, t) = (s.xOf(i) + nudge, s.tOf(j))
  result = s.ink.background
  for k, tile in s.tiles:
    if not s.tiles.hidden(k, s.view):
      let hover = tile.hoverRow(0, s.hover)
      var selected, lit: seq[bool]
      tile.selectedRowsInto(0, s.selection, selected)
      tile.hoveredRowsInto(0, s.selection, lit) # the traces the map's pointer lights up
      if tile.contains(x, t):
        result = s.ink.background
        if s.density:
          let c = tile.densityAt(lutOf(s.display.colourMap), x, t, s.scale,
            s.ink.background)
          result = if s.wiggles: c
                   else: densityTint(c, markOf(tile.rowAt(x), hover, selected, lit),
                     s.ink.wiggle, DensityTint, s.display.colourMap)
      let (_, ts) = tile.span
      if s.wiggles and t >= ts.lo and t < ts.hi:
        let ser = tile.series
        for r in 0 ..< tile.request.count: # the marked traces' tint, under the traces
          let m = markOf(r, hover, selected, lit)
          let pos = float64(tile.request.position(r))
          if m != tmNone and abs(x - pos) <= s.style.reach:
            result = tintInk((x - pos) * s.style.pixelsPerTrace, s.style, s.ink.wiggle,
              m).onto(result)
        for pass in 0 .. 1:
          for r in 0 ..< tile.request.count:
            let m = markOf(r, hover, selected, lit)
            let pos = float64(tile.request.position(r))
            if (pass == 0 or m != tmNone) and abs(x - pos) <= s.style.reach:
              let ink = tile.traceInk(ser, r, (x - pos) * s.style.pixelsPerTrace, t, s.style,
                s.ink.wiggle, m)
              result = ink.onto(result)

func close*(a, b: Rgba; tol = Tolerance): bool = distance(a, b) <= tol

const Edge = 1e-6
  ## positions: a pixel whose centre is this close to the edge between two
  ## traces may be drawn as either (the GPU's float32 decides, row by row)

proc mismatches*(s: Shot; step = 2; columns = 0 .. int.high): (int, int) =
  ## Image pixels on a grid (every `step`-th row and column, of `columns`)
  ## that differ from `expected`, and the pixels looked at. A pixel whose
  ## centre lies on the edge between two traces matches either trace's
  ## colour.
  for j in countup(0, s.h - 1, step):
    for i in countup(max(columns.a, 0), min(columns.b, s.w - 1), step):
      inc result[1]
      let want = s.expected(i, j)
      if not close(s.at(i, j), want) and not close(s.at(i, j), s.expected(i, j, -Edge)) and
          not close(s.at(i, j), s.expected(i, j, Edge)):
        if result[0] < 5:
          echo "  pixel (", i, ", ", j, "): ", toHex(s.at(i, j)), ", expected ", toHex(want)
        inc result[0]
