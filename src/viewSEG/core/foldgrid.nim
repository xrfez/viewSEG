## A fold map (`core/foldjobs`) prepared for drawing and for the pointer:
## the colour of each bin, the coarser levels a zoomed-out map draws, which
## bin lies under a map position, and the words for it.
##
## **Colours.** Fold 0 is left out (alpha 0). Any other fold is its fraction
## of the map's highest fold, looked up in the Viridis colour map the density
## plot uses (`lutOf(cmViridis)`), so the legend's gradient and the bins agree.
##
## The recorded fold ("Actual fold") is coloured the same way. The difference (planned less
## recorded) uses the diverging red, white and blue map (`cmRedWhiteBlue`) centred on 0, the
## largest magnitude at either end: 0 is the neutral colour, positive (short of the plan) goes
## to blue, negative (more than planned) to red; a bin with neither a plan nor a trace is clear.
##
## **Levels.** Level 1 is the grid itself. A bin smaller than `MinBinPixels`
## on the screen would vanish or flicker as a quad, so when the bins are
## smaller than that the map draws a coarser level: blocks of `f x f` bins
## (`f` a power of two, the smallest that makes a block at least
## `MinBinPixels` wide), each the **maximum** of the fold of its bins. The
## maximum rather than the mean: it keeps the edge of the surveyed area where
## it is and does not paint a block darker for a hole beside a covered bin
## (a hole narrower than a block is not drawn at that zoom: zoom in to see it). The
## levels are made by the job that counts the fold (`FoldResult.levels`), so the UI
## thread only looks one up; nothing is allocated per frame.
##
## **Where a bin is.** The grid is rotated to the receiver lines' azimuth `a`
## (degrees clockwise from north). With `u = (sin a, cos a)` along the
## crosslines and `v = (cos a, -sin a)` along the inlines (90 degrees clockwise of `u`),
## bin (inline `i`, crossline `j`) is centred at `(x0, y0) + j * binAlong * u +
## i * binAcross * v` and spans half a bin to each side (`binAt` inverts it).

import std/[math, strutils]
import colourmaps, foldjobs, geometry, spatial

export foldjobs

const
  MinBinPixels* = 3.0 ## the smallest bin, in pixels, a level draws

type
  FoldGrid* = object
    ## A fold map and its levels.
    res*: ref FoldResult

func legendColour*(t: float64): Rgba =
  ## The colour at fraction `t` (0 to 1) of the maximum fold.
  let c = lutOf(cmViridis)[int(round(clamp(t, 0.0, 1.0) * 255))]
  Rgba(r: c.r, g: c.g, b: c.b, a: 255)

func diffLegendColour*(t: float64): Rgba =
  ## The colour at fraction `t` (0 to 1) along the difference's bar: the most negative at 0,
  ## zero in the middle, the most positive at 1.
  let c = lutOf(cmRedWhiteBlue)[int(round(clamp(t, 0.0, 1.0) * 255))]
  Rgba(r: c.r, g: c.g, b: c.b, a: 255)

func foldTitle*(kind: FoldKind): string =
  ## The layer's name in the popover, the legend and the hover.
  case kind
  of fkPreplot: "Pre-plot fold"
  of fkActual: "Actual fold"
  of fkDifference: "Fold difference (planned − recorded)"

func initFoldGrid*(res: ref FoldResult): FoldGrid = FoldGrid(res: res)

func factorFor*(g: FoldGrid; perPixel: float64): int =
  ## The block size that makes the bins at least `MinBinPixels` wide on a
  ## screen showing `perPixel` map units a pixel: 1 when they are.
  result = 1
  if g.res.isNil: return
  let pp = if perPixel > 0: perPixel else: 1e-300
  let bin = min(g.res.binAlong, g.res.binAcross)
  let most = max(g.res.inlines, g.res.crosslines)
  while (float64(result) * bin / pp < MinBinPixels and result < most) or
      (g.res.crosslines + result - 1) div result > MaxCells or
      (g.res.inlines + result - 1) div result > MaxCells:
    result *= 2

func levelIndex(factor: int): int =
  while (1 shl result) < factor: inc result

func level*(g: FoldGrid; factor: int): lent FoldLevel =
  ## The level of blocks of `factor` bins (a power of two), as the job made it;
  ## the coarsest one for a factor beyond the levels.
  let k = min(levelIndex(factor), g.res.levels.high)
  g.res.levels[k]

func binAt*(r: FoldResult; x, y: float64): int =
  ## The bin under map position (`x`, `y`): `inline * crosslines + crossline`,
  ## or -1 outside the grid (a bin holds half a bin to each side of its centre,
  ## the higher bin taking the middle, as the library's `binAt` does).
  let (ux, uy) = (sin(degToRad(r.azimuthDeg)), cos(degToRad(r.azimuthDeg)))
  let (dx, dy) = (x - r.x0, y - r.y0)
  let j = floor((dx * ux + dy * uy) / r.binAlong + 0.5)
  let i = floor((dx * uy - dy * ux) / r.binAcross + 0.5)
  if i >= 0 and i < float64(r.inlines) and j >= 0 and j < float64(r.crosslines):
    int(i) * r.crosslines + int(j)
  else: -1

func foldAt*(r: FoldResult; bin: int): int32 {.inline.} = r.counts[bin]

func sizeText*(v: float64): string =
  ## A bin size to at most six significant digits.
  result = formatFloat(v, ffDefault, 6)
  result.trimZeros()

func plural(n: int; word: string): string = $n & " " & word & (if n == 1: "" else: "s")

func totalsText*(r: FoldResult; unit: string): string =
  ## The totals line of the layer's popover for map `r`, with lengths in `unit`.
  if r.kind != fkPreplot:
    result = "Counted " & plural(r.files, "file") & ", " & plural(r.traces, "trace") & ": " &
      $r.binned & " in the bins; left out " & $r.notLive & " not live, " & $r.killed &
      " killed, " & $r.noCoordinates & " without coordinates and " & $r.outside &
      " outside the grid."
    if r.unplaced > 0:
      result.add " " & plural(r.unplaced, "file") & " give no source or receiver positions " &
        "and the survey does not place them."
    if r.skipped.len > 0: result.add " " & plural(r.skipped.len, "file") & " could not be read."
    result.add " Bins " & sizeText(r.binAlong) & " x " & sizeText(r.binAcross) & " " & unit &
      "; max " & (if r.kind == fkActual: "fold " else: "difference ") & $r.maxFold & "."
  elif r.inlines * r.crosslines == 1:
    result = "One bin holds " & $r.binned & " pairs (" & $r.outside & " outside the grid, " &
      $r.noCoordinates & " without coordinates)."
  else:
    result = $r.binned & " pairs in " & $r.inlines & " x " & $r.crosslines & " bins, max fold " &
      $r.maxFold & "; " & $r.outside & " pairs outside the grid, " & $r.noCoordinates &
      " without coordinates. Bins " & sizeText(r.binAlong) & " x " & sizeText(r.binAcross) &
      " " & unit & "."

func foldText*(r: FoldResult; bin: int): string =
  ## "fold 12 (inline 3, crossline 41)" for bin `bin` (in `0 ..< len`); for the recorded
  ## fold "recorded 10 (planned 12) at inline 3, crossline 41"; for the difference "2 short
  ## of the plan" or "2 more than planned" at the bin.
  let (i, j) = (bin div r.crosslines, bin mod r.crosslines)
  let place = "inline " & $(r.firstInline + float64(i)).int & ", crossline " &
    $(r.firstCrossline + float64(j)).int
  case r.kind
  of fkPreplot: "fold " & $r.counts[bin] & " (" & place & ")"
  of fkActual:
    "recorded " & $r.counts[bin] & " (planned " & $r.planned[bin] & ") at " & place
  of fkDifference:
    let d = r.counts[bin]
    (if d > 0: $d & " short of the plan" elif d < 0: $(-int64(d)) & " more than planned"
      else: "as planned") & " (planned " & $r.planned[bin] & ", recorded " &
       $(int64(r.planned[bin]) - d) & ") at " & place

type
  FoldSpan* = tuple[row, first, last: int] ## blocks `first .. last` of block row `row`

proc visibleSpans*(r: FoldResult; factor: int; area: Bounds; spans: var seq[FoldSpan]) =
  ## The blocks (of `factor`) that map area `area` can touch, as one run of
  ## blocks for each block row: the area's corners are turned into grid
  ## coordinates, and each row's band is cut out of that rectangle, so a
  ## rotated grid draws only the blocks along the diagonal of a zoomed view.
  ## `spans` is emptied first; its room is kept from frame to frame.
  spans.setLen 0
  let (ux, uy) = (sin(degToRad(r.azimuthDeg)), cos(degToRad(r.azimuthDeg)))
  var pu, pv: array[4, float64] # the corners in bins along and across
  var k = 0
  for (x, y) in [(area.minX, area.minY), (area.maxX, area.minY), (area.maxX, area.maxY),
      (area.minX, area.maxY)]:
    pu[k] = ((x - r.x0) * ux + (y - r.y0) * uy) / r.binAlong
    pv[k] = ((x - r.x0) * uy - (y - r.y0) * ux) / r.binAcross
    inc k
  var (vLo, vHi) = (pv[0], pv[0])
  for q in 1 .. 3:
    vLo = min(vLo, pv[q])
    vHi = max(vHi, pv[q])
  let rows = (r.inlines + factor - 1) div factor
  let cols = (r.crosslines + factor - 1) div factor
  let first = max(0, int(floor((vLo + 0.5) / float64(factor))))
  let last = min(rows - 1, int(floor((vHi + 0.5) / float64(factor))))
  for row in first .. last:
    let (b0, b1) = (float64(row * factor) - 0.5, float64((row + 1) * factor) - 0.5)
    var (lo, hi) = (Inf, -Inf)
    for e in 0 .. 3:
      let (a, b) = (e, (e + 1) mod 4)
      # the part of edge a-b with its v between b0 and b1
      let dv = pv[b] - pv[a]
      var (t0, t1) = (0.0, 1.0)
      if dv == 0:
        if pv[a] < b0 or pv[a] > b1: t0 = 2
      else:
        let (ta, tb) = ((b0 - pv[a]) / dv, (b1 - pv[a]) / dv)
        t0 = max(t0, min(ta, tb))
        t1 = min(t1, max(ta, tb))
      if t0 <= t1:
        for t in [t0, t1]:
          let u = pu[a] + t * (pu[b] - pu[a])
          lo = min(lo, u)
          hi = max(hi, u)
    if lo <= hi:
      let c0 = max(0, int(floor((lo + 0.5) / float64(factor))))
      let c1 = min(cols - 1, int(floor((hi + 0.5) / float64(factor))))
      if c0 <= c1: spans.add (row, c0, c1)
