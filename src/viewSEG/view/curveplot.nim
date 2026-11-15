## A plot of named curves over one axis, toolkit-neutral: what the spectrum
## windows draw (amplitude against frequency), and what a plot of signals,
## spectra, correlations or phases against time or frequency can draw
## (several curves, each named and coloured, with a legend).
##
## The curves share their x values (`xs`, ascending). The plot is drawn
## with x across from the left (`along = saX`) or turned, x down from the
## top and the values across (`along = saY`), as a signal is drawn beside a
## seismic trace; the frontend lays its axes out by `along`, and
## everything else here is the same either way. The view never shows
## anything past the data (`xLimits`, `yLimits`); the cursor reads the
## nearest point of each curve (`readingAt`, `readoutText`).

import std/[math, strutils]
import ../core/[geometry, orientation, viewport]

export Span

export ScreenAxis, Rgba

type
  Curve* = object
    ## One curve: a value per x of its plot (NaN where it has none).
    name*: string
    colour*: Rgba
    ys*: seq[float64]

  CurvePlot* = object
    ## Curves over one shared axis.
    xLabel*, yLabel*: string ## the axes' names with their units: "Frequency (Hz)"
    xUnit*, yUnit*: string   ## for the readout: "Hz", "dB"
    xs*: seq[float64]        ## ascending
    curves*: seq[Curve]
    logX*: bool              ## the x axis is logarithmic (its positive values only)
    along*: ScreenAxis = saX ## x across from the left, or (`saY`) down from the top
    yFloor*: float64 = NaN   ## the lowest value shown (a dB floor); NaN: the data's
    note*: string            ## shown over an empty plot: why it is empty

  Reading* = object
    ## What the cursor reads at an x: the nearest point of each curve.
    index*: int              ## into `xs`; -1 for none
    x*: float64
    values*: seq[float64]    ## per curve, NaN where it has none

func isEmpty*(p: CurvePlot): bool =
  ## Whether `p` has nothing to draw.
  if p.xs.len == 0: return true
  for c in p.curves:
    if c.ys.len > 0: return false
  true

func firstShown(p: CurvePlot): int =
  ## The first point the x axis shows: on a logarithmic axis, the first
  ## positive x.
  result = 0
  if p.logX:
    while result < p.xs.len and not (p.xs[result] > 0): inc result

func xLimits*(p: CurvePlot): Span =
  ## The x axis's limits: the data's first and last x (on a logarithmic
  ## axis, the first positive one); 0 to 1 for none.
  let a = p.firstShown
  if a >= p.xs.len: Span(lo: (if p.logX: 1.0 else: 0.0), hi: (if p.logX: 10.0 else: 1.0))
  elif p.xs[^1] > p.xs[a]: Span(lo: p.xs[a], hi: p.xs[^1])
  else: Span(lo: p.xs[a] - 0.5, hi: p.xs[a] + 0.5)

func yLimits*(p: CurvePlot): Span =
  ## The value axis's limits: the curves' smallest and largest finite
  ## values over the x shown (from `yFloor` when it is given), with a
  ## twentieth of the range more at each end; 0 to 1 for none.
  var lo = Inf
  var hi = -Inf
  let a = p.firstShown
  for c in p.curves:
    for i in a ..< min(c.ys.len, p.xs.len):
      let y = c.ys[i]
      if y.classify notin {fcNan, fcInf, fcNegInf}:
        lo = min(lo, y)
        hi = max(hi, y)
  if not p.yFloor.isNaN and lo < p.yFloor: lo = p.yFloor
  if lo > hi: return Span(lo: 0, hi: 1)
  let pad = if hi > lo: (hi - lo) / 20 else: max(abs(hi) / 20, 0.5)
  Span(lo: lo - pad, hi: hi + pad)

func nearestIndex*(p: CurvePlot; x: float64): int =
  ## The index of the x nearest `x` (on a logarithmic axis, nearest on the
  ## screen); -1 when there is none or `x` is not a number.
  if p.xs.len == 0 or x.isNaN: return -1
  let a = p.firstShown
  if a >= p.xs.len: return -1
  var lo = a
  var hi = p.xs.high
  while lo < hi:
    let mid = (lo + hi) div 2
    if p.xs[mid] < x: lo = mid + 1 else: hi = mid
  result = lo
  if result > a:
    let (u, v) = if p.logX and x > 0: (ln(x / p.xs[result - 1]), ln(p.xs[result] / x))
                 else: (x - p.xs[result - 1], p.xs[result] - x)
    if u < v: dec result

func readingAt*(p: CurvePlot; x: float64): Reading =
  ## What the cursor at `x` reads: the nearest x and each curve's value there.
  result = Reading(index: p.nearestIndex(x), x: NaN)
  if result.index >= 0:
    result.x = p.xs[result.index]
    for c in p.curves:
      result.values.add(if result.index < c.ys.len: c.ys[result.index] else: NaN)

func valueText*(x: float64; digits = 3): string =
  ## `x` with `digits` significant digits at least, and none past the point
  ## it does not need ("12.5", "0.0123", "4000"); "-" for NaN.
  if x.isNaN: return "-"
  if x.classify == fcInf: return "inf"
  if x.classify == fcNegInf: return "-inf"
  let a = abs(x)
  let decimals = if a == 0 or a >= pow(10.0, float64(digits - 1)): 0
                 else: digits - 1 - int(floor(log10(a)))
  result = formatFloat(x, ffDecimal, min(decimals, 12))
  if '.' in result:
    result = result.strip(leading = false, chars = {'0'})
    if result.endsWith("."): result.setLen result.len - 1
  if result == "-0": result = "0"

func readoutText*(p: CurvePlot; r: Reading): string =
  ## A reading in words: "12.5 Hz   raw -23.4 dB   processed -40.1 dB"; ""
  ## for none.
  if r.index < 0: return ""
  result = valueText(r.x) & (if p.xUnit.len > 0: " " & p.xUnit else: "")
  for i, c in p.curves:
    if i < r.values.len:
      result.add "   " & c.name & " " & valueText(r.values[i]) &
        (if p.yUnit.len > 0: " " & p.yUnit else: "")
