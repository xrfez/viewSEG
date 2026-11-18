## The plot's time axis: how wide its labels can be, and how the cursor's
## time is written beside them.
##
## **A steady edge.** The time axis is as wide as its widest tick label, so
## labels that grow from "999" to "1000" while the view pans would move the
## plot's left edge, and the picture with it. `timeLabelChars` is the
## longest label a record's ticks can have (its first and last times, and
## the decimals of the finest tick step a view of it can show), and the
## frontend pads every label to that many characters (`printf`'s `%*g` in a
## font whose digits and spaces are equally wide), so the axis keeps one
## width whatever part of the record is in view.
##
## **The cursor's time** (`cursorTimeText`) is written to the record's
## sample interval: whole milliseconds at 1 ms and coarser, one decimal at
## 0.5 ms, two at 0.25 ms.

import std/[math, strutils]
import ../core/[viewport, zoom]

const MaxMajorTicks* = 20
  ## the most major ticks the axis puts on a view (a plot 6000 pixels tall,
  ## at ImPlot's one per 300 pixels)

func niceNum(x: float64; round: bool): float64 =
  ## ImPlot's `NiceNum`: 1, 2 or 5 (or 10) times a power of ten near `x`.
  let e = floor(log10(x))
  let f = x / pow(10.0, e)
  let nf =
    if round:
      if f < 1.5: 1.0 elif f < 3: 2.0 elif f < 7: 5.0 else: 10.0
    else:
      if f <= 1: 1.0 elif f <= 2: 2.0 elif f <= 5: 5.0 else: 10.0
  nf * pow(10.0, e)

func finestStep*(leastSpanMs: float64): float64 =
  ## The smallest tick step ImPlot's axis uses on a view `leastSpanMs` long
  ## (the shortest view the zoom allows), with as many ticks as a very tall
  ## plot gets.
  if not (leastSpanMs > 0 and leastSpanMs < Inf): return 1
  niceNum(niceNum(leastSpanMs * 0.99, false) / float64(MaxMajorTicks - 1), true)

func decimalsOf*(step: float64): int =
  ## The decimals that multiples of `step` need, at most 6.
  result = 0
  var s = step
  while result < 6 and abs(s - round(s)) > 1e-9 * max(1.0, abs(s)):
    s *= 10
    inc result

func intChars(t: float64): int =
  ## The characters of `t`'s whole part, with its sign.
  let a = abs(t)
  result = (if a < 10: 1 else: int(floor(log10(a))) + 1)
  if t < 0: inc result

func timeLabelChars*(layout: PanelLayout): int =
  ## The longest tick label of the time axis of a panel with `layout`, in
  ## characters, as `%g` writes it: the whole part of the record's first or
  ## last time, with its sign, and the decimals of the finest step a view of
  ## the record can show.
  let lim = limitsOf(layout)[axTime]
  let d = decimalsOf(finestStep(lim.least))
  result = max(intChars(lim.bounds.lo), intChars(lim.bounds.hi))
  if d > 0: result += 1 + d
  result = clamp(result, 1, 12)

func cursorTimeText*(tMs, dtMs: float64): string =
  ## The time `tMs` as the cursor's time line shows it at the axis: to the
  ## sample interval `dtMs` (whole ms at 1 ms or coarser); "" for a time that
  ## is not a number.
  if tMs.classify in {fcNan, fcInf, fcNegInf}: return ""
  let d = if dtMs > 0 and dtMs < Inf: min(decimalsOf(dtMs), 3) else: 0
  result = formatFloat(tMs, ffDecimal, d)
  if result.endsWith('.'): result.setLen(result.len - 1) # Nim writes "702." with no decimals
  if result.startsWith("-") and result.strip(chars = {'-', '0', '.'}).len == 0:
    result = result[1 .. ^1] # "-0" from a time just before 0

type
  TimeEnds* = object
    ## The two times the axis always labels: the first and the last in view.
    first*, last*: float64
    firstText*, lastText*: string ## written like the cursor's time, padded to the axis's width
    showFirst*: bool              ## false where the two labels would touch (a view of a few pixels)
    pxPerMs*: float64
    gapPx*: float64               ## a tick closer than this to an end's label gives way to it

func timeEnds*(view, bounds: Span; dtMs: float64; chars: int; pxPerMs, gapPx: float64): TimeEnds =
  ## The end labels of a time axis showing `view` of a record whose times run
  ## over `bounds` (first to last sample): the view's own ends, which are the
  ## first and last sample's times when the whole record is in view. `chars`
  ## is the axis's label width, `pxPerMs` the plot's pixels per ms along it
  ## and `gapPx` the room one label needs along it.
  let lo = max(view.lo, bounds.lo)
  let hi = min(view.hi, bounds.hi)
  result = TimeEnds(first: lo, last: hi, pxPerMs: pxPerMs, gapPx: gapPx,
    firstText: cursorTimeText(lo, dtMs).align(chars),
    lastText: cursorTimeText(hi, dtMs).align(chars))
  result.showFirst = (hi - lo) * pxPerMs >= gapPx

func givesWay*(e: TimeEnds; t: float64): bool =
  ## Whether the ordinary tick at time `t` is left out: it is where an end
  ## label stands, or so near that the two would overlap.
  if not (e.pxPerMs > 0): return false
  abs(t - e.last) * e.pxPerMs < e.gapPx or (e.showFirst and abs(t - e.first) * e.pxPerMs < e.gapPx)
