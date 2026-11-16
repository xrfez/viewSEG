## Thinning a large highlight for the map: of hundreds of thousands of
## selected points, one a square cell about a pixel and a half wide is
## drawn (`thinned`), so the highlight costs what the screen has room for,
## not what the selection holds, and looks the same: every selected point
## has a drawn one in its own cell, so the highlight's edge is where the
## selection's is, to within a cell.
##
## Only the points of an area round the view are thinned (`thinArea`: the
## view and half a view more on each side); the others are off the screen
## and are not drawn. The cells that are taken are kept in a bitmap of that
## area, so the work and the memory are those of the view's pixels and one
## pass over the points, however sparse the cells are at a close zoom, and
## freeing it is freeing one block. The map thins again when the view
## leaves the area or its scale changes by half (`thinFits`).

import std/math
import mapview, spatial

const
  ThinCellPixels* = 1.5
    ## a cell's side, in pixels of the view thinned for
  ThinMaxCells* = 1 shl 26
    ## the most cells an area is cut into (8 MB of bitmap); a larger area's
    ## cells are made wider until it fits

type
  ThinArea* = object
    ## Where a highlight was thinned, and at what cell.
    area*: Bounds   ## survey units; points outside it are not drawn
    cell*: float64  ## a cell's side, survey units; 0: not set
    asked*: float64 ## the cell the view asked for (`cell` is wider in a huge area)
    nx*, ny*: int   ## cells across and up

func cellFor(v: MapView): float64 {.inline.} = ThinCellPixels * v.perPixel

func thinArea*(v: MapView; origin: MapPoint): ThinArea =
  ## The area to thin a highlight in for view `v`: the view with half its
  ## width and height more on each side, its corner on the grid of cells
  ## from `origin` (the survey's lower-left corner), so the cells a point
  ## falls in do not move as the area does. An unset view gives an unset
  ## area.
  if not v.isSet: return
  let asked = cellFor(v)
  var cell = asked
  let s = v.visible
  let (mx, my) = (s.width / 2, s.height / 2)
  let (w, h) = (s.width + 2 * mx, s.height + 2 * my)
  if not (cell > 0 and w / cell < 1e12 and h / cell < 1e12): return
  if (w / cell + 1) * (h / cell + 1) > float64(ThinMaxCells):
    cell = sqrt(w * h / float64(ThinMaxCells)) * 1.01
  let x0 = origin.x + floor((s.minX - mx - origin.x) / cell) * cell
  let y0 = origin.y + floor((s.minY - my - origin.y) / cell) * cell
  result.cell = cell
  result.asked = asked
  result.nx = int(ceil((s.maxX + mx - x0) / cell)) + 1
  result.ny = int(ceil((s.maxY + my - y0) / cell)) + 1
  result.area = Bounds(minX: x0, minY: y0, maxX: x0 + float64(result.nx) * cell,
    maxY: y0 + float64(result.ny) * cell)

func thinFits*(a: ThinArea; v: MapView): bool =
  ## Whether a highlight thinned in `a` still serves view `v`: the view is
  ## inside the area, and its cell is within half again of `a`'s, either
  ## way.
  if a.cell <= 0 or not v.isSet: return false
  let c = cellFor(v)
  let s = v.visible
  c <= 1.5 * a.asked and c >= a.asked / 1.5 and s.minX >= a.area.minX and
    s.minY >= a.area.minY and s.maxX <= a.area.maxX and s.maxY <= a.area.maxY

proc thinned*(dst: var seq[MapPoint]; points: openArray[MapPoint]; a: ThinArea;
    taken: var seq[uint64]) =
  ## Into `dst`: of `points` inside `a`'s area, the first in each of its
  ## cells; points outside it and points that are not numbers (hidden) are
  ## left out. `taken` is the bitmap of the cells, kept by the caller
  ## between calls so it is not allocated each time.
  dst.setLen 0
  if a.cell <= 0 or a.nx <= 0 or a.ny <= 0: return
  let words = (a.nx * a.ny + 63) div 64
  taken.setLen words
  for w in taken.mitems: w = 0
  let (x0, y0, inv) = (a.area.minX, a.area.minY, 1 / a.cell)
  for p in points:
    # NaN fails both comparisons, so a hidden point is left out here too
    if p.x >= x0 and p.x < a.area.maxX and p.y >= y0 and p.y < a.area.maxY:
      let cx = min(int((p.x - x0) * inv), a.nx - 1)
      let cy = min(int((p.y - y0) * inv), a.ny - 1)
      let c = cy * a.nx + cx
      let bit = 1'u64 shl (c and 63)
      if (taken[c shr 6] and bit) == 0:
        taken[c shr 6] = taken[c shr 6] or bit
        dst.add p
