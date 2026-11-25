## What an analysis window (New plot) draws, toolkit-neutral: its curve
## plots (`core/analysis`'s `AnalysisPlot` as `CurvePlot`s, coloured from
## the theme's series), and for an image view (a spectrogram) the cell
## under a point, the cursor's reading and the rows in the order a
## frontend draws them (the highest y first, at the top).

import std/[math, strutils]
import ../core/[analysis, plotcursor, units]
from ../core/vibanalysis import AgainstFile, AgainstStored
import curveplot, theme

func scaled(ys: seq[float64]; divisor: float64): seq[float64] =
  ## `ys` divided by `divisor` (1: as they are). A NaN stays a NaN.
  if divisor == 1.0: return ys
  result = newSeq[float64](ys.len)
  for i, y in ys:
    result[i] = if y.isNaN: NaN else: y / divisor

func scaleBound(y, divisor: float64): float64 {.inline.} =
  if divisor == 1.0 or y.isNaN: y else: y / divisor

func forceAxisLabel*(plots: openArray[AnalysisPlot]): string =
  ## The y label of the plot the force limits are drawn on; "" when there is
  ## none yet. With a recorded ground force that plot is "Force"; without one
  ## it is "Force from M and B".
  var fromMasses = ""
  for p in plots:
    if p.title == "Force": return p.yLabel
    if p.title == "Force from M and B": fromMasses = p.yLabel
  fromMasses

func readoutName(name: string): string =
  ## A curve's name in the one-line readout under the plots when its legend name is long
  ## ("GF/file ref" for "GF against the file's reference"); "": the name itself.
  result = ""
  for (long, short) in [(" " & AgainstFile, "/file ref"), (" " & AgainstStored, "/stored ref")]:
    if name.endsWith(long): return name[0 ..< name.len - long.len] & short

func curvePlots*(r: AnalysisResult; t: Theme; units = usMetric): seq[CurvePlot] =
  ## The result's plots as curve plots: each data curve a colour of the
  ## theme's series, in order; a limit a thin line in the error colour, the
  ## points past one marked in it; a reference's own curve thin and dim; a NaN
  ## where a curve has no value. `units`
  ## renames an axis that states a metric unit and scales its values; the
  ## stored result stays in SI.
  for p in r.plots:
    let axis = axisDisplay(p.yLabel, units)
    let yUnit = if p.yUnit.len > 0: p.yUnit else: unitOfLabel(axis.label)
    var c = CurvePlot(xLabel: p.xLabel, yLabel: axis.label, xUnit: p.xUnit, yUnit: yUnit,
      xs: p.xs, yFloor: scaleBound(p.yLo, axis.divisor),
      yCeil: scaleBound(p.yHi, axis.divisor), aside: p.aside, dimmed: p.dimmed)
    var i = 0
    for curve in p.curves:
      let ys = scaled(curve.ys, axis.divisor)
      case curve.style
      of csLine:
        c.curves.add Curve(name: curve.name, colour: t.series[i mod t.series.len],
          ys: ys, xs: curve.xs, brackets: scaled(curve.brackets, axis.divisor),
          short: readoutName(curve.name))
        inc i
      of csLimit:
        c.curves.add Curve(name: curve.name, colour: t.roles[rlError], ys: ys,
          xs: curve.xs, width: 1)
      of csFail:
        c.curves.add Curve(name: curve.name, colour: t.roles[rlError], ys: ys,
          xs: curve.xs, width: 3, overlay: true)
      of csReference:
        c.curves.add Curve(name: curve.name, colour: t.roles[rlTextDim], ys: ys,
          xs: curve.xs, width: 1)
    result.add c
  # a vibrator's plots share one sweep time: only the last names it, so each has the room;
  # their legends are small and inside the plot (none for a plot of one curve), so that every
  # plot has the whole width
  if r.view == avVibrator:
    for i in 0 ..< result.high: result[i].bareX = true
    for i, c in result.mpairs:
      var shown = 0
      for k in c.curves:
        if not k.overlay: inc shown
      c.legendInside = true
      # (the phase plot's one line has a legend too: it says which reference it is against)
      c.legend = shown > 1 or (i == 0 and shown == 1)
      # the phase plot's names are long ("GF against the stored reference"): in the corner
      # they cover its lines, so they go in rows above it
      c.legendAbove = i == 0 and shown > 1

func cellAt*(img: AnalysisImage; x, y: float64): PlotCursor =
  ## The cell whose centre is nearest (`x`, `y`), within the image; `x` -1
  ## when the image is empty or the point is not a number.
  if img.isEmpty or x.isNaN or y.isNaN: return PlotCursor(x: -1, y: -1)
  let col = int(round((x - img.x0) / img.dx))
  let row = int(round((y - img.y0) / img.dy))
  PlotCursor(x: clamp(col, 0, img.cols - 1), y: clamp(row, 0, img.rows - 1))

func xOf*(img: AnalysisImage; col: int): float64 {.inline.} = img.x0 + float64(col) * img.dx
func yOf*(img: AnalysisImage; row: int): float64 {.inline.} = img.y0 + float64(row) * img.dy

func number(x: float64): string =
  if x.classify in {fcNan, fcInf, fcNegInf}: "–"
  elif abs(x) >= 100 or x == round(x): formatFloat(x, ffDecimal, 1)
  else: formatFloat(x, ffDecimal, 2)

func readingText*(img: AnalysisImage; c: PlotCursor): string =
  ## What the cursor at cell `c` reads: "512.0 ms · 47.85 Hz: -12.30 dB",
  ## and an f-k's apparent velocity after ("· 2000.0 m/s"); "" for none.
  if img.isEmpty or c.x < 0 or c.y < 0 or c.x >= img.cols or c.y >= img.rows: return ""
  result = number(img.xOf(c.x)) & " " & img.xUnit & " · " & number(img.yOf(c.y)) & " " &
    img.yUnit & ": " & number(float64(img.valueAt(c.x, c.y))) & " " & img.unit
  if img.velocityUnit.len > 0:
    # the apparent velocity: f / k (none at k = 0)
    let k = img.xOf(c.x)
    if k == 0: result.add " · no velocity (k = 0)"
    else: result.add " · " & number(img.velocityScale * img.yOf(c.y) / k) & " " & img.velocityUnit

func topDown*(img: AnalysisImage): seq[float32] =
  ## The values row by row from the highest y (drawn at the top), each row
  ## left to right: as a heat map draws them.
  result = newSeq[float32](img.values.len)
  var k = 0
  for row in countdown(img.rows - 1, 0):
    for col in 0 ..< img.cols:
      result[k] = img.valueAt(col, row)
      inc k

const MaxDrawnCells* = 300_000
  ## the most cells an image view hands the toolkit to draw: a plot has a few
  ## hundred thousand pixels at most, and a cell drawn is a rectangle a frame

type ImageReduction* = object
  ## The part of an image in view, cut down to about the plot's pixels: each
  ## cell the largest value of the bin of image cells it stands for.
  cols*, rows*: int ## the cells drawn
  values*: seq[float32] ## row by row, the highest y first, as `topDown`
  xMin*, xMax*, yMin*, yMax*: float64 ## where they are drawn, in the image's x and y
  binCols*, binRows*: int ## image cells to a drawn one, along x and along y

func reduceImage*(img: AnalysisImage; xLo, xHi, yLo, yHi: float64; pxW, pxH: int): ImageReduction =
  ## The cells of `img` in view (x from `xLo` to `xHi`, y from `yLo` to `yHi`)
  ## cut down to at most `pxW` x `pxH` drawn cells (and `MaxDrawnCells`),
  ## each the largest of its bin, so that a bright cell is never averaged
  ## away. Bins are whole numbers of cells from the first in view; the last
  ## bin may reach past the image (filled with its floor, drawn off it).
  if img.isEmpty or xHi.isNaN or xLo.isNaN or yHi.isNaN or yLo.isNaN: return
  let c0 = clamp(int(floor((min(xLo, xHi) - img.x0) / img.dx)), 0, img.cols - 1)
  let c1 = clamp(int(ceil((max(xLo, xHi) - img.x0) / img.dx)), c0, img.cols - 1)
  let r0 = clamp(int(floor((min(yLo, yHi) - img.y0) / img.dy)), 0, img.rows - 1)
  let r1 = clamp(int(ceil((max(yLo, yHi) - img.y0) / img.dy)), r0, img.rows - 1)
  let (nc, nr) = (c1 - c0 + 1, r1 - r0 + 1)
  var (fx, fy) = ((nc + max(pxW, 1) - 1) div max(pxW, 1), (nr + max(pxH, 1) - 1) div max(pxH, 1))
  fx = max(fx, 1)
  fy = max(fy, 1)
  while ((nc + fx - 1) div fx) * ((nr + fy - 1) div fy) > MaxDrawnCells:
    if (nc + fx - 1) div fx >= (nr + fy - 1) div fy: inc fx else: inc fy
  let (oc, orows) = ((nc + fx - 1) div fx, (nr + fy - 1) div fy)
  result = ImageReduction(cols: oc, rows: orows, binCols: fx, binRows: fy,
    values: newSeq[float32](oc * orows))
  for v in result.values.mitems: v = img.lo
  for c in c0 .. c1:
    let bx = (c - c0) div fx
    let base = c * img.rows
    for by in 0 ..< orows:
      let at = (orows - 1 - by) * oc + bx
      var m = result.values[at]
      for r in r0 + by * fy ..< min(r0 + (by + 1) * fy, r1 + 1):
        m = max(m, img.values[base + r])
      result.values[at] = m
  result.xMin = img.xOf(c0) - img.dx / 2
  result.xMax = result.xMin + float64(oc * fx) * img.dx
  result.yMin = img.yOf(r0) - img.dy / 2
  result.yMax = result.yMin + float64(orows * fy) * img.dy

func keyMove*(up, down, left, right, home, ending: bool): CursorMove =
  ## The cursor's move for the keys pressed in an image view, whose second
  ## axis grows upwards (Up: a row higher, the next one): none for no key.
  if left: cmPrevious
  elif right: cmNext
  elif up: cmDown # (`moved`'s Down is the next row: higher on the screen here)
  elif down: cmUp
  elif home: cmFirst
  elif ending: cmLast
  else: cmNone

type MassTyped* = object
  ## What a mass box does with a number typed into it.
  changed*: bool
    ## `kg` is a new mass to store
  kg*: float64
    ## the kilograms kept: the new ones, or the stored ones (NaN: none)
  refused*: bool
    ## outside `MassKgRange`: nothing is stored, and the box says so

func massTyped*(typed, shown, stored: float64; u: UnitSystem): MassTyped =
  ## The box showed `shown` (`massBoxValue` of the `stored` kilograms in `u`) and now holds
  ## `typed`. A number left as the box showed it is no edit, so switching the unit back and
  ## forth never stores the rounding of a conversion; another number is stored in kilograms
  ## (`storeMass`) when `MassKgRange` allows it, and an emptied box stores none.
  func same(a, b: float64): bool = a == b or (a.isNaN and b.isNaN)
  result = MassTyped(kg: stored)
  if not same(typed, shown):
    let kg = storeMass(typed, u)
    if typed.isNaN or MassKgRange.allows(kg):
      result = MassTyped(changed: not same(kg, stored), kg: kg)
    else: result.refused = true
