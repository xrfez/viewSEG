## Levels of detail for the map: what to draw of a set of points when they
## outnumber the pixels they fall on.
##
## The points of a layer are kept in the order of their spatial index
## (`core/spatial`): square cells about one point each, a row of cells after
## another. Level 1 has cells twice as wide, level 2 four times, and so on,
## until one cell holds them all; each cell of a level is drawn as one of
## its points (the first, in the index's order: always a real position). A
## level's points are kept row by row of its cells, in column order, so the
## points of a level a view covers are a run per row (`runs`), as the
## index's own are.
##
## A map draws the coarsest level whose cells are no larger than a pixel or
## two (`levelFor`): the picture is the same as with every point, since the
## points of one cell fall on the same pixels, but a level of a million
## points close together draws as many points as the screen has room for.
## Zoomed in past level 1, every point is drawn, from the index.
##
## The levels are made once per layer, on the worker that makes the layer
## (`buildLevels`), so the map never waits for one: every level a view can
## need is there as soon as the layer is. Positions are also kept as
## `float32` relative to the lower-left corner of the index's grid
## (`origin`), ready for the GPU: a survey 100 km across keeps them to a
## centimetre.
##
## **Points far from the rest**, which the index keeps in its edge cells
## beyond its grid (`SpatialIndex.grid`), are each a point of every level:
## a cell's point is always one inside the grid, so a far point neither
## stands for the points of its cell nor is lost.

import std/[algorithm, math]
import spatial

const
  LodFrom* = 4096
    ## a set of fewer points has no levels: every point is drawn

type
  LodLevel* = object
    ## One level: a point per cell of a grid `2^level` times as coarse as
    ## the index's.
    cell*: float64 ## the side of a cell, in survey units
    nx*, ny*: int ## cells across and up
    xy*: seq[float32] ## per point: x and y relative to the origin
    rowStart*: seq[int32] ## per row of cells, and one more: its first point
    col*: seq[int32] ## per point: its cell's column (ascending in a row)

  PointLevels* = object
    ## The levels of one set of points, finest first, and every point.
    origin*: tuple[x, y: float64] ## the lower-left corner of the index's grid
    outside*: bool                ## some points lie beyond the grid (far from the rest)
    xy*: seq[float32]             ## every point, as `LodLevel.xy`, in the index's order
    cell*: float64                ## the side of the index's cells
    spacing*: float64
      ## how far apart neighbouring points typically are (the median distance
      ## from a point to its nearest other, over a sample); NaN for fewer than
      ## two points apart
    levels*: seq[LodLevel] ## level 1 (cells two index cells wide) first

func len*(l: LodLevel): int {.inline.} = l.col.len
  ## The points of level `l`.

const FarAway = 1e30 ## a position (from the origin) is kept to this, so `float32` holds it

proc relative(ix: SpatialIndex; origin: tuple[x, y: float64]): seq[float32] =
  result = newSeq[float32](2 * ix.len)
  for i in 0 ..< ix.len:
    result[2 * i] = float32(clamp(ix.x(i) - origin.x, -FarAway, FarAway))
    result[2 * i + 1] = float32(clamp(ix.y(i) - origin.y, -FarAway, FarAway))

type Grid = tuple[w, h: float32] ## the index's grid, from the origin

func beyond(xy: openArray[float32]; p: int; g: Grid): bool {.inline.} =
  ## Whether point `p` of `xy` lies beyond the index's grid (an edge cell
  ## holds it, but it is far from the rest).
  let (x, y) = (xy[2 * p], xy[2 * p + 1])
  x < 0 or y < 0 or x > g.w or y > g.h

proc emit(l: var LodLevel; xy: openArray[float32]; slot: openArray[int32];
    far: var seq[(int32, int32)]) =
  ## Adds a row of cells: each cell's point (`slot`, -1 for none), and after
  ## it the far points of that cell (`far`: cell, point), in cell order.
  far.sort()
  var k = 0
  for c, p in slot:
    if p >= 0:
      l.xy.add xy[2 * p]
      l.xy.add xy[2 * p + 1]
      l.col.add int32(c)
    while k < far.len and far[k][0] == int32(c):
      l.xy.add xy[2 * far[k][1]]
      l.xy.add xy[2 * far[k][1] + 1]
      l.col.add int32(c)
      inc k
  far.setLen 0

proc coarser(fine: LodLevel; g: Grid): LodLevel =
  ## The level of cells twice as wide as `fine`'s, from its points: a cell's
  ## first point within the grid, and every point beyond it.
  result = LodLevel(cell: fine.cell * 2, nx: (fine.nx + 1) div 2, ny: (fine.ny + 1) div 2)
  result.rowStart = newSeq[int32](result.ny + 1)
  var slot = newSeq[int32](result.nx)
  var far: seq[(int32, int32)]
  for jj in 0 ..< result.ny:
    for s in slot.mitems: s = -1
    for j in 2 * jj .. min(2 * jj + 1, fine.ny - 1):
      for p in fine.rowStart[j] ..< fine.rowStart[j + 1]:
        let c = fine.col[p] shr 1
        if fine.xy.beyond(p, g): far.add (c, p)
        elif slot[c] < 0: slot[c] = p
    result.emit(fine.xy, slot, far)
    result.rowStart[jj + 1] = int32(result.col.len)

proc firstLevel(ix: SpatialIndex; xy: openArray[float32]; g: Grid): LodLevel =
  ## Level 1: a point per 2 × 2 cells of the index (the first within the
  ## grid), and every point beyond the grid (only edge cells hold them).
  let (nx, ny) = ix.cells
  result = LodLevel(cell: ix.cellSize * 2, nx: (nx + 1) div 2, ny: (ny + 1) div 2)
  result.rowStart = newSeq[int32](result.ny + 1)
  var slot = newSeq[int32](result.nx)
  var far: seq[(int32, int32)]
  for jj in 0 ..< result.ny:
    for s in slot.mitems: s = -1
    for j in 2 * jj .. min(2 * jj + 1, ny - 1):
      for i in 0 ..< nx:
        let run = ix.cellPoints(i, j)
        let c = int32(i shr 1)
        if i == 0 or i == nx - 1 or j == 0 or j == ny - 1:
          for p in run:
            if xy.beyond(p, g): far.add (c, int32(p))
            elif slot[c] < 0: slot[c] = int32(p)
        elif run.len > 0 and slot[c] < 0: slot[c] = int32(run.a)
    result.emit(xy, slot, far)
    result.rowStart[jj + 1] = int32(result.col.len)

const SpacingSample = 2000 ## points the spacing is measured at, at most

proc spacingOf*(ix: SpatialIndex): float64 =
  ## How far apart neighbouring points of `ix` typically are: the median,
  ## over up to `SpacingSample` points spread through the index, of the
  ## distance to the nearest other point in the same or a neighbouring cell
  ## (the index's cells hold about a point each, so most points have one
  ## there). NaN when no point has another near it.
  result = NaN
  if ix.len < 2: return
  let (nx, ny) = ix.cells
  let c = ix.cellSize
  let g = ix.grid
  var found: seq[float64]
  let step = max(1, ix.len div SpacingSample)
  var i = 0
  while i < ix.len:
    let (x, y) = (ix.x(i), ix.y(i))
    # (the clamp before `int`: a far point's cell number overflows an int)
    let ci = int(clamp(floor((x - g.minX) / c), 0.0, float64(nx - 1)))
    let cj = int(clamp(floor((y - g.minY) / c), 0.0, float64(ny - 1)))
    var best = Inf
    for j in cj - 1 .. cj + 1:
      for k in ci - 1 .. ci + 1:
        for q in ix.cellPoints(k, j):
          if q != i:
            let d = hypot(ix.x(q) - x, ix.y(q) - y)
            if d > 0 and d < best: best = d
    if best < Inf: found.add best
    i += step
  if found.len > 0:
    found.sort()
    result = found[found.len div 2]

proc buildLevels*(ix: SpatialIndex): PointLevels =
  ## The levels of the points of `ix`: none for fewer than `LodFrom` points,
  ## else level 1, 2 ... until one cell holds them all.
  let g = ix.grid
  if ix.len == 0: return
  result.origin = (g.minX, g.minY)
  result.xy = ix.relative(result.origin)
  result.outside = g != ix.bounds
  result.cell = ix.cellSize
  result.spacing = ix.spacingOf
  if ix.len < LodFrom: return
  let grid: Grid = (float32(g.width), float32(g.height))
  var level = firstLevel(ix, result.xy, grid)
  while true:
    let done = level.nx <= 1 and level.ny <= 1
    result.levels.add level
    if done: break
    level = coarser(result.levels[^1], grid)

func levelFor*(p: PointLevels; perPixel, pixels: float64): int =
  ## The coarsest level whose cells are at most `pixels` pixels wide at
  ## `perPixel` survey units a pixel; -1 for every point (zoomed in past
  ## level 1, or no levels).
  result = -1
  if not (perPixel > 0 and pixels > 0): return
  let widest = perPixel * pixels
  for k, l in p.levels:
    if l.cell <= widest: result = k

func lowerBound(col: openArray[int32]; lo, hi: int; c: int32): int =
  ## The first place in `col[lo ..< hi]` (ascending) holding `c` or more.
  var (a, b) = (lo, hi)
  while a < b:
    let m = (a + b) div 2
    if col[m] < c: a = m + 1 else: b = m
  a

func cellOf(v, cell: float64; n: int): int {.inline.} =
  ## The cell (0 ..< n) along one axis that `v` (from the origin) falls in,
  ## the first or last for one outside.
  let t = floor(v / cell)
  if t.isNaN or t < 0: 0 elif t >= float64(n - 1): n - 1 else: int(t)

iterator runs*(p: PointLevels; level: int; box: Bounds): Slice[int] =
  ## The points of `level` in the cells `box` touches (survey coordinates),
  ## as runs of consecutive points, one per row of cells. `level` -1 is not
  ## served here: every point is drawn from the index's `runs`.
  if level in 0 ..< p.levels.len and not box.isEmpty:
    let l = addr p.levels[level]
    let (lx, ly) = (box.minX - p.origin.x, box.minY - p.origin.y)
    let (hx, hy) = (box.maxX - p.origin.x, box.maxY - p.origin.y)
    # (a box beyond the grid still reaches the far points of the edge cells)
    if p.outside or (hx >= 0 and hy >= 0 and lx <= l.cell * float64(l.nx) and
        ly <= l.cell * float64(l.ny)):
      let (i0, i1) = (cellOf(lx, l.cell, l.nx), cellOf(hx, l.cell, l.nx))
      let (j0, j1) = (cellOf(ly, l.cell, l.ny), cellOf(hy, l.cell, l.ny))
      for j in j0 .. j1:
        let (a, b) = (int(l.rowStart[j]), int(l.rowStart[j + 1]))
        let first = lowerBound(l.col, a, b, int32(i0))
        let last = lowerBound(l.col, first, b, int32(i1) + 1)
        if last > first: yield first ..< last

func bytes*(p: PointLevels): int =
  ## The memory the levels and the positions take.
  result = p.xy.len * 4
  for l in p.levels: result += l.xy.len * 4 + l.col.len * 4 + l.rowStart.len * 4
