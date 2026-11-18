## A plot of named curves over one axis, toolkit-neutral: what the spectrum
## windows draw (amplitude against frequency), and what a plot of signals,
## spectra, correlations or phases against time or frequency can draw
## (several curves, each named and coloured, with a legend).
##
## The curves share their x values (`xs`, ascending), unless a curve has
## its own (`Curve.xs`: a response on a grid of its own). The plot is drawn
## with x across from the left (`along = saX`) or turned, x down from the
## top and the values across (`along = saY`), as a signal is drawn beside a
## seismic trace; the frontend lays its axes out by `along`, and
## everything else here is the same either way. The view never shows
## anything past the data (`xLimits`, `yLimits`); the cursor reads the
## nearest point of each curve (`readingAt`, `readingOf`, `readoutText`),
## its numbers rounded as the axes need them (`xText`, `yText`): the x to
## the spacing of the points, dB and degrees to a tenth, other values to
## four significant digits.

import std/[math, strutils]
import ../core/[geometry, orientation, viewport]
import axisfit

export Span

export ScreenAxis, Rgba

type
  Curve* = object
    ## One curve: a value per x of its plot (NaN where it has none).
    name*: string
    colour*: Rgba
    ys*: seq[float64]
    xs*: seq[float64]
      ## its own x values, ascending, one per `ys`; empty: the plot's
    width*: float32 = 1.5 ## its line's width, in points at 100 %
    shadeTo*: float64 = NaN
      ## the value it is shaded down (or up) to, faintly: an area under it,
      ## drawn behind the lines (not when the plot is turned); NaN: none
    reads*: seq[float64]
      ## what the readout says per x, when it is not `ys` (a gain drawn
      ## against amplitudes reads in dB); empty: `ys`
    unit*: string ## the readout's unit of `reads`; "": the plot's `yUnit`
    short*: string ## its name in the readout, when shorter than the legend's; "": `name`
    marks*: bool ## drawn as marks at its points, not a line (points past a limit)
    brackets*: seq[float64]
      ## a second value the readout adds in brackets, per x (a phase's signed
      ## value, when the picture is not the signed one); empty or NaN: none

  DenseSignal* = object
    ## A long signal the frontend draws itself, as a filled band of each pixel
    ## column's extremes when the view holds more samples than columns, and as
    ## a line through the true samples when it does not. The plot's `curves`
    ## keep a coarse copy for the view's limits and the cursor. The samples
    ## belong to the caller, who keeps them alive for the frame.
    values*: ptr UncheckedArray[float32] ## nil: none
    count*: int
    x0*, dx*: float64 ## sample `i` is at `x0 + i·dx`

  CurvePlot* = object
    ## Curves over one shared axis.
    xLabel*, yLabel*: string ## the axes' names with their units: "Frequency (Hz)"
    xUnit*, yUnit*: string   ## for the readout: "Hz", "dB"
    xs*: seq[float64]        ## ascending
    curves*: seq[Curve]
    logX*: bool              ## the x axis is logarithmic (its positive values only)
    along*: ScreenAxis = saX ## x across from the left, or (`saY`) down from the top
    yFloor*: float64 = NaN   ## the lowest value shown (a dB floor); NaN: the data's
    yCeil*: float64 = NaN
      ## with `yFloor`, both numbers: the value axis is exactly that span,
      ## with no padding (a phase magnitude's 0 to 180)
    xFloor*: float64 = NaN
    xCeil*: float64 = NaN
      ## both numbers, with `xCeil` above `xFloor`: the x axis is exactly
      ## that span, not the data's first and last x (a spectrum fitted to a
      ## sweep's band)
    dense*: DenseSignal ## drawn in place of the first curve; none by default
    roomRight*: bool
      ## leave room right of the plot for the last tick label (a plot whose x axis
      ## ends on a number that would be clipped)
    legend*: bool = true ## the legend box; a plot of one series does not need it
    note*: string ## shown over an empty plot: why it is empty
    aside*: string ## appended to the readout (a delay taken off, in ms)

  Reading* = object
    ## What the cursor reads at an x: the nearest point of each curve.
    index*: int           ## into `xs`; -1 for none
    x*: float64
    values*: seq[float64] ## per curve, what the readout says; NaN where it has none
    drawn*: seq[float64]
      ## per curve, its drawn value there (at its own nearest x for a curve
      ## with its own); NaN where it has none
    brackets*: seq[float64]
      ## per curve, the bracketed value there; NaN where it has none

proc spanOf(xs: openArray[float64]; lo, hi: float64): tuple[a, b: int] =
  ## Inclusive indices of `xs` (ascending) in `lo` .. `hi`; (-1, -1) when none.
  if xs.len == 0 or lo.isNaN or hi.isNaN: return (-1, -1)
  var a = 0
  var h = xs.high
  while a < h:
    let mid = (a + h) div 2
    if xs[mid] < lo: a = mid + 1 else: h = mid
  if a >= xs.len or xs[a] > hi or xs[a] < lo: return (-1, -1)
  var b = xs.high
  var l = a
  while l < b:
    let mid = (l + b + 1) div 2
    if xs[mid] > hi: b = mid - 1 else: l = mid
  (a, b)

proc takePoint(c: Curve; xs: openArray[float64]; j: int; outc: var Curve) =
  outc.xs.add if j < xs.len: xs[j] else: NaN
  outc.ys.add if j < c.ys.len: c.ys[j] else: NaN
  if c.brackets.len > 0:
    outc.brackets.add if j < c.brackets.len: c.brackets[j] else: NaN
  if c.reads.len > 0:
    outc.reads.add if j < c.reads.len: c.reads[j] else: NaN

proc forScreen*(p: CurvePlot; xLo, xHi: float64; pixels: int): seq[Curve] =
  ## The curves to draw for x in `xLo` .. `xHi`, at most about `pixels`
  ## points each, of at most `pixels` points in all. Each bin keeps its finite
  ## minimum and maximum in sample order (`extremeBins`), so neither a peak
  ## nor a notch is lost, whatever the sign of the values; a bin with none
  ## stays a gap. A range that fits in `pixels` is every sample, so a zoom
  ## reaches single samples. One sample either side of the range is kept, so
  ## the line enters the view. The caller redoes this when the view changes.
  let px = max(pixels, 1)
  let lo = min(xLo, xHi)
  let hi = max(xLo, xHi)
  for c in p.curves:
    var outc = Curve(name: c.name, colour: c.colour, width: c.width, shadeTo: c.shadeTo,
      unit: c.unit, short: c.short, marks: c.marks)
    let xs = if c.xs.len > 0: c.xs else: p.xs
    let (a0, b0) = spanOf(xs, lo, hi)
    if a0 >= 0 and a0 < c.ys.len:
      let b = min(b0, min(c.ys.high, xs.high))
      let n = b - a0 + 1
      let left = if a0 > 0: a0 - 1 else: -1
      let last = min(c.ys.high, xs.high)
      let right = if b + 1 <= last: b + 1 else: -1
      if n <= px:
        let fromI = if left >= 0: left else: a0
        let toI = if right >= 0: right else: b
        for j in fromI .. toI: c.takePoint(xs, j, outc)
      else:
        if left >= 0: c.takePoint(xs, left, outc)
        let bins = max(px div 2, 1)
        let step = (n + bins - 1) div bins
        var bin = 0
        for (lo, hi) in extremeBins(c.ys.toOpenArray(a0, b), step):
          if lo >= 0:
            c.takePoint(xs, a0 + lo, outc)
            if hi != lo: c.takePoint(xs, a0 + hi, outc)
          else:
            let j = min(b, a0 + bin * step)
            outc.xs.add if j < xs.len: xs[j] else: NaN
            outc.ys.add NaN
            if c.brackets.len > 0: outc.brackets.add NaN
            if c.reads.len > 0: outc.reads.add NaN
          inc bin
        if right >= 0: c.takePoint(xs, right, outc)
    result.add outc

func isEmpty*(p: CurvePlot): bool =
  ## Whether `p` has nothing to draw.
  if p.xs.len == 0: return true
  for c in p.curves:
    if c.ys.len > 0: return false
  true

func xsOf*(p: CurvePlot; c: Curve): lent seq[float64] {.inline.} =
  ## The x values of curve `c` of `p`: its own, else the plot's.
  if c.xs.len > 0: c.xs else: p.xs

func nearestIn(xs: openArray[float64]; x: float64; logX: bool): int =
  ## The index of the value of `xs` (ascending) nearest `x`; -1 for none.
  if xs.len == 0 or x.isNaN: return -1
  var lo = 0
  var hi = xs.high
  while lo < hi:
    let mid = (lo + hi) div 2
    if xs[mid] < x: lo = mid + 1 else: hi = mid
  result = lo
  if result > 0:
    let (u, v) = if logX and x > 0 and xs[result - 1] > 0: (ln(x / xs[result - 1]),
                   ln(xs[result] / x))
                 else: (x - xs[result - 1], xs[result] - x)
    if u < v: dec result

func firstShown(p: CurvePlot): int =
  ## The first point the x axis shows: on a logarithmic axis, the first
  ## positive x.
  result = 0
  if p.logX:
    while result < p.xs.len and not (p.xs[result] > 0): inc result

func xLimits*(p: CurvePlot): Span =
  ## The x axis's limits: exactly `xFloor` to `xCeil` when both are numbers
  ## and the span has width; otherwise the data's first and last x (on a
  ## logarithmic axis, the first positive one); 0 to 1 for none.
  if not p.xFloor.isNaN and not p.xCeil.isNaN and p.xCeil > p.xFloor:
    return Span(lo: p.xFloor, hi: p.xCeil)
  let a = p.firstShown
  if a >= p.xs.len: Span(lo: (if p.logX: 1.0 else: 0.0), hi: (if p.logX: 10.0 else: 1.0))
  elif p.xs[^1] > p.xs[a]: Span(lo: p.xs[a], hi: p.xs[^1])
  else: Span(lo: p.xs[a] - 0.5, hi: p.xs[a] + 0.5)

func yLimits*(p: CurvePlot): Span =
  ## The value axis's limits: exactly `yFloor` to `yCeil` when both are
  ## numbers, else the curves' smallest and largest finite values over the
  ## x shown (from `yFloor` when it is given), with a twentieth of the range
  ## more at each end, and never narrower than `minSpanOf` the y unit; 0 to 1 for none.
  var lo = Inf
  var hi = -Inf
  let a = p.firstShown
  for c in p.curves:
    let xs = p.xsOf(c)
    for i in 0 ..< min(c.ys.len, xs.len):
      let y = c.ys[i]
      if (if c.xs.len > 0: not p.logX or xs[i] > 0 else: i >= a) and
          y.classify notin {fcNan, fcInf, fcNegInf}:
        lo = min(lo, y)
        hi = max(hi, y)
  if not p.yFloor.isNaN and not p.yCeil.isNaN: return Span(lo: p.yFloor, hi: p.yCeil)
  if not p.yFloor.isNaN and lo < p.yFloor: lo = p.yFloor
  if lo > hi: return Span(lo: 0, hi: 1)
  let pad = if hi > lo: (hi - lo) / 20 else: max(abs(hi) / 20, 0.5)
  # a span under what the quantity can show (`minSpanOf`) is rounding noise or a constant
  Span(lo: lo - pad, hi: hi + pad).atLeast(minSpanOf(p.yUnit, lo, hi))

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
      let j = if c.xs.len > 0: c.xs.nearestIn(result.x, p.logX) else: result.index
      let said = if c.reads.len > 0: c.reads else: c.ys
      result.values.add(if j in 0 ..< said.len: said[j] else: NaN)
      result.drawn.add(if j in 0 ..< c.ys.len: c.ys[j] else: NaN)
      result.brackets.add(if j in 0 ..< c.brackets.len: c.brackets[j] else: NaN)

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

func readingOf*(p: CurvePlot; index: int): Reading =
  ## What the cursor at point `index` of `xs` reads (`readingAt` of its x).
  if index notin 0 ..< p.xs.len: Reading(index: -1, x: NaN)
  else: p.readingAt(p.xs[index])

func xText*(p: CurvePlot; x: float64): string =
  ## `x` as the cursor says it, to the spacing of the plot's points (no more
  ## decimals than tell two neighbours apart: "60.1" at 0.24 Hz, "60.00" at
  ## 0.061 Hz, "60" at 1); "-" for NaN.
  if x.isNaN: return "-"
  let step = if p.xs.len > 1: abs(p.xs[1] - p.xs[0]) else: 0.0
  let d = if step > 0 and step < Inf: clamp(int(ceil(-log10(step) - 1e-9)), 0, 9) else: 3
  result = formatFloat(x, ffDecimal, d)
  if result.endsWith('.'): result.setLen result.len - 1
  if result.startsWith("-") and result.strip(chars = {'-', '0', '.'}).len == 0:
    result = result[1 .. ^1]

func yText*(y: float64; unit: string): string =
  ## A value as the cursor says it: in dB and degrees to a tenth ("-23.4",
  ## "0.0", never "-0.0"), others to four significant digits ("0.005513");
  ## "-" for NaN.
  if y.isNaN: return "-"
  if y.classify in {fcInf, fcNegInf}: return valueText(y)
  if unit in ["dB", "deg"]:
    result = formatFloat(y, ffDecimal, 1)
    if result == "-0.0": result = "0.0"
  else: result = valueText(y, 4)

func unitOf(p: CurvePlot; c: Curve): string {.inline.} =
  ## The unit curve `c`'s readings are in.
  if c.reads.len > 0 and c.unit.len > 0: c.unit else: p.yUnit

func readoutText*(p: CurvePlot; r: Reading): string =
  ## A reading in words: "12.5 Hz   raw -23.4 dB   processed -40.1 dB"
  ## ("raw -" where a curve has no value; a bracketed signed value when the
  ## curve has one); "" for none. The plot's `aside` follows, when it has one.
  if r.index < 0: return ""
  result = p.xText(r.x) & (if p.xUnit.len > 0: " " & p.xUnit else: "")
  for i, c in p.curves:
    if i < r.values.len:
      let unit = p.unitOf(c)
      result.add "   " & (if c.short.len > 0: c.short else: c.name) & " " &
        yText(r.values[i], unit) &
        (if unit.len > 0 and not r.values[i].isNaN: " " & unit else: "")
      if i < r.brackets.len and not r.brackets[i].isNaN:
        result.add " (signed " & yText(r.brackets[i], unit) & ")"
  if p.aside.len > 0: result.add "   " & p.aside

func valueBoxText*(p: CurvePlot; r: Reading; curve: int): string =
  ## What the cursor's box on the value axis says for `curve`: its value as
  ## the readout says it (so the two never differ: a curve drawn clamped at
  ## the floor, or a gain in dB drawn on a linear axis, says its reading,
  ## not where it is drawn), with its unit when the axis's is another;
  ## "" when it has none there.
  if curve notin 0 ..< min(p.curves.len, r.values.len) or r.values[curve].isNaN: return ""
  let unit = p.unitOf(p.curves[curve])
  yText(r.values[curve], unit) & (if unit != p.yUnit and unit.len > 0: " " & unit else: "")
