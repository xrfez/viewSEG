## A fold map (`core/foldjobs`) prepared for drawing and for the pointer:
## the colour of each bin, the coarser levels a zoomed-out map draws, which
## bin lies under a map position, and the words for it.
##
## **Colours.** Fold 0 is left out (alpha 0). Any other fold is its fraction
## of the map's highest fold, looked up in the Viridis colour map the density
## plot uses (`lutOf(cmViridis)`), so the legend's gradient and the bins agree.
##
## **Levels.** Level 1 is the grid itself. A bin smaller than `MinBinPixels`
## on the screen would vanish or flicker as a quad, so when the bins are
## smaller than that the map draws a coarser level: blocks of `f x f` bins
## (`f` a power of two, the smallest that makes a block at least
## `MinBinPixels` wide), each the **maximum** of the fold of its bins. The
## maximum rather than the mean: it keeps the edge of the surveyed area where
## it is and does not paint a block darker for a hole beside a covered bin
## (a hole narrower than a block is not drawn at that zoom: zoom in to see it). A
## level is made once, the first time it is drawn, and kept; nothing is
## allocated per frame.
##
## **Where a bin is.** The grid is rotated to the receiver lines' azimuth `a`
## (degrees clockwise from north). With `u = (sin a, cos a)` along the
## crosslines and `v = (cos a, -sin a)` along the inlines (90 degrees clockwise of `u`),
## bin (inline `i`, crossline `j`) is centred at `(x0, y0) + j * binAlong * u +
## i * binAcross * v` and spans half a bin to each side (`binAt` inverts it).

import std/math
import colourmaps, foldjobs, geometry, spatial

const MinBinPixels* = 2.0 ## the smallest bin, in pixels, a level draws

type
  FoldLevel* = object
    ## Blocks of `factor x factor` bins, row-major, `rows x cols` blocks.
    factor*, cols*, rows*: int
    colours*: seq[uint32]
      ## per block, packed as bytes r, g, b, a (little-endian); alpha 0 for no fold

  FoldGrid* = object
    ## A fold map and its levels.
    res*: ref FoldResult
    levels: seq[FoldLevel] ## index `log2(factor)`; `factor` 0 for one not made yet

func pack(c: Rgba): uint32 {.inline.} =
  uint32(c.r) or (uint32(c.g) shl 8) or (uint32(c.b) shl 16) or (uint32(c.a) shl 24)

func foldColour*(lut: Lut; fold, maxFold: int32): uint32 =
  ## The packed colour of a bin with `fold` pairs; 0 (clear) for none.
  if fold <= 0 or maxFold <= 0: return 0
  let t = min(1.0, float64(fold) / float64(maxFold))
  var c = lut[int(round(t * 255))]
  c.a = 255
  pack(c)

func legendColour*(t: float64): Rgba =
  ## The colour at fraction `t` (0 to 1) of the maximum fold.
  let c = lutOf(cmViridis)[int(round(clamp(t, 0.0, 1.0) * 255))]
  Rgba(r: c.r, g: c.g, b: c.b, a: 255)

func initFoldGrid*(res: ref FoldResult): FoldGrid = FoldGrid(res: res)

func factorFor*(g: FoldGrid; perPixel: float64): int =
  ## The block size that makes the bins at least `MinBinPixels` wide on a
  ## screen showing `perPixel` map units a pixel: 1 when they are.
  result = 1
  if g.res.isNil or not (perPixel > 0): return
  let bin = min(g.res.binAlong, g.res.binAcross)
  let most = max(g.res.inlines, g.res.crosslines)
  while float64(result) * bin / perPixel < MinBinPixels and result < most: result *= 2

func levelIndex(factor: int): int =
  while (1 shl result) < factor: inc result

proc level*(g: var FoldGrid; factor: int): lent FoldLevel =
  ## The level of blocks of `factor` bins (a power of two), made the first time.
  let k = levelIndex(factor)
  if g.levels.len <= k: g.levels.setLen k + 1
  if g.levels[k].factor == 0:
    let r = g.res
    let lut = lutOf(cmViridis)
    var l = FoldLevel(factor: factor, cols: (r.crosslines + factor - 1) div factor,
      rows: (r.inlines + factor - 1) div factor)
    l.colours = newSeq[uint32](l.cols * l.rows)
    if factor == 1:
      for k in 0 ..< r.counts.len: l.colours[k] = lut.foldColour(r.counts[k], r.maxFold)
    else:
      var peak = newSeq[int32](l.cols * l.rows)
      for i in 0 ..< r.inlines:
        let row = (i div factor) * l.cols
        for j in 0 ..< r.crosslines:
          let at = row + j div factor
          peak[at] = max(peak[at], r.counts[i * r.crosslines + j])
      for k in 0 ..< peak.len: l.colours[k] = lut.foldColour(peak[k], r.maxFold)
    g.levels[k] = l
  g.levels[k]

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

func foldText*(r: FoldResult; bin: int): string =
  ## "fold 12 (inline 3, crossline 41)" for bin `bin` (in `0 ..< len`).
  let (i, j) = (bin div r.crosslines, bin mod r.crosslines)
  "fold " & $r.counts[bin] & " (inline " & $(r.firstInline + float64(i)).int &
    ", crossline " & $(r.firstCrossline + float64(j)).int & ")"

func visibleRows*(r: FoldResult; factor: int; area: Bounds): Slice[int] =
  ## The block rows (of `factor`) the map area `area` can touch: the rows
  ## spanned by its corners along the inline axis. Empty when none.
  let (ux, uy) = (sin(degToRad(r.azimuthDeg)), cos(degToRad(r.azimuthDeg)))
  var lo, hi = 0.0
  var first = true
  for (x, y) in [(area.minX, area.minY), (area.maxX, area.minY), (area.minX, area.maxY),
      (area.maxX, area.maxY)]:
    let i = ((x - r.x0) * uy - (y - r.y0) * ux) / r.binAcross
    if first or i < lo: lo = i
    if first or i > hi: hi = i
    first = false
  let blocks = (r.inlines + factor - 1) div factor
  let a = max(0, int(floor((lo + 0.5) / float64(factor))))
  let b = min(blocks - 1, int(floor((hi + 0.5) / float64(factor))))
  a .. b
