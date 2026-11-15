## What an analysis window (New plot) draws, toolkit-neutral: its curve
## plots (`core/analysis`'s `AnalysisPlot` as `CurvePlot`s, coloured from
## the theme's series), and for an image view (a spectrogram) the cell
## under a point, the cursor's reading and the rows in the order a
## frontend draws them (the highest y first, at the top).

import std/[math, strutils]
import ../core/[analysis, plotcursor]
import curveplot, theme

func curvePlots*(r: AnalysisResult; t: Theme): seq[CurvePlot] =
  ## The result's plots as curve plots: each curve a colour of the theme's
  ## series, in order; a NaN where a curve has no value.
  for p in r.plots:
    var c = CurvePlot(xLabel: p.xLabel, yLabel: p.yLabel, xUnit: p.xUnit, yUnit: p.yUnit,
      xs: p.xs)
    for i, curve in p.curves:
      c.curves.add Curve(name: curve.name, colour: t.series[i mod t.series.len], ys: curve.ys)
    result.add c

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
  ## What the cursor at cell `c` reads: "512.0 ms · 47.85 Hz: -12.30 dB";
  ## "" for none.
  if img.isEmpty or c.x < 0 or c.y < 0 or c.x >= img.cols or c.y >= img.rows: return ""
  number(img.xOf(c.x)) & " " & img.xUnit & " · " & number(img.yOf(c.y)) & " " & img.yUnit &
    ": " & number(float64(img.valueAt(c.x, c.y))) & " " & img.unit

func topDown*(img: AnalysisImage): seq[float32] =
  ## The values row by row from the highest y (drawn at the top), each row
  ## left to right: as a heat map draws them.
  result = newSeq[float32](img.values.len)
  var k = 0
  for row in countdown(img.rows - 1, 0):
    for col in 0 ..< img.cols:
      result[k] = img.valueAt(col, row)
      inc k

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
