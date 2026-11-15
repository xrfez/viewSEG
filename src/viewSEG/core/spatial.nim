## A spatial index of points in the plane, for the map: the point nearest a
## place within a radius (`nearest`), the points in a box (`within`), and
## the points' bounds.
##
## A uniform grid of square cells over the points' bounds, about one point a
## cell on average (at most `CellsPerPoint` cells a point), so a lookup
## looks at the few cells near the place it is asked about. The points are
## kept in cell order: cell `c` holds points `starts[c] ..< starts[c + 1]`,
## so a cell's points lie side by side in memory and need no list of their
## own. `initSpatialIndex` gives the order it put them in, for the caller to
## put whatever else it keeps per point in the same order.
##
## Built in two passes over the points (a counting sort). Every coordinate
## must be finite: the survey model counts missing ones and leaves them out
## before it builds an index. Points that all lie on one spot, or on one
## line, still get cells along what they span; points whose span overflows
## a float share one cell.

import std/math

const
  CellsPerPoint* = 4 ## an index has at most this many cells a point (and 16 more)
  MaxPoints* = (int(high(int32)) - 16) div CellsPerPoint
    ## the most points an index takes (its cells are numbered in an `int32`)

type
  Bounds* = object
    ## An axis-aligned box. The default holds nothing (`isEmpty`).
    minX*, minY*: float64 = Inf
    maxX*, maxY*: float64 = -Inf

  SpatialIndex* = object
    ## Points in the plane, in cell order (point `i` is at `x(i)`, `y(i)`).
    xs, ys: seq[float64]
    bounds: Bounds
    cell: float64 ## the side of a cell
    nx, ny: int   ## cells across and down; 0 for no points
    starts: seq[int32]

func isEmpty*(b: Bounds): bool {.inline.} =
  ## Whether `b` holds no point.
  not (b.minX <= b.maxX and b.minY <= b.maxY)

func width*(b: Bounds): float64 {.inline.} = (if b.isEmpty: 0.0 else: b.maxX - b.minX)
func height*(b: Bounds): float64 {.inline.} = (if b.isEmpty: 0.0 else: b.maxY - b.minY)

func incl*(b: var Bounds; x, y: float64) {.inline.} =
  ## Grows `b` to hold (`x`, `y`).
  b.minX = min(b.minX, x)
  b.minY = min(b.minY, y)
  b.maxX = max(b.maxX, x)
  b.maxY = max(b.maxY, y)

func incl*(b: var Bounds; other: Bounds) =
  ## Grows `b` to hold `other`.
  if not other.isEmpty:
    b.incl(other.minX, other.minY)
    b.incl(other.maxX, other.maxY)

func contains*(b: Bounds; x, y: float64): bool {.inline.} =
  ## Whether (`x`, `y`) lies in `b`, edges included.
  x >= b.minX and x <= b.maxX and y >= b.minY and y <= b.maxY

func overlaps*(a, b: Bounds): bool =
  ## Whether `a` and `b` share a point, edges included.
  not (a.isEmpty or b.isEmpty) and a.minX <= b.maxX and b.minX <= a.maxX and
    a.minY <= b.maxY and b.minY <= a.maxY

func len*(ix: SpatialIndex): int {.inline.} = ix.xs.len
func x*(ix: SpatialIndex; i: int): float64 {.inline.} = ix.xs[i]
func y*(ix: SpatialIndex; i: int): float64 {.inline.} = ix.ys[i]
func bounds*(ix: SpatialIndex): Bounds {.inline.} = ix.bounds
  ## The points' bounds; empty for none.
func cellSize*(ix: SpatialIndex): float64 {.inline.} = ix.cell
func cells*(ix: SpatialIndex): (int, int) {.inline.} = (ix.nx, ix.ny)
  ## Cells across and down.

func cellAt(v, lo, cell: float64; n: int): int {.inline.} =
  ## The cell (0 ..< n) along one axis that coordinate `v` falls in, the
  ## first or last for one outside; NaN (an overflowed span) goes to 0.
  let t = (v - lo) / cell
  if t >= float64(n - 1): n - 1
  elif t > 0: int(t)
  else: 0

func gridOf(b: Bounds; n: int): tuple[cell: float64; nx, ny: int] =
  ## Square cells over `b` for `n` points: about one a cell, at most
  ## `CellsPerPoint` a point and 16 more.
  let (w, h) = (b.width, b.height)
  if n <= 1 or not (w < Inf and h < Inf) or (w == 0 and h == 0):
    return (1.0, 1, 1)
  var cell = if w > 0 and h > 0: sqrt(w / float64(n) * h) else: max(w, h) / float64(n)
  cell = max(cell, max(w, h) / float64(n))
  if not (cell > 0 and cell < Inf): return (1.0, 1, 1)
  let limit = CellsPerPoint * n + 16
  while true:
    let (qx, qy) = (w / cell, h / cell)
    if qx < float64(limit) and qy < float64(limit):
      let (nx, ny) = (int(qx) + 1, int(qy) + 1)
      if nx * ny <= limit: return (cell, nx, ny)
    cell *= 2

proc initSpatialIndex*(xs, ys: openArray[float64]; order: var seq[int32]): SpatialIndex =
  ## An index of the points (`xs[i]`, `ys[i]`). `order` is set to the order
  ## it keeps them in: its point `i` is the given point `order[i]`. Raises
  ## `ValueError` when `xs` and `ys` differ in length, a coordinate is not
  ## finite, or there are more than `MaxPoints` points.
  if xs.len != ys.len:
    raise newException(ValueError, "xs and ys differ in length")
  if xs.len > MaxPoints:
    raise newException(ValueError, "too many points for one index")
  let n = xs.len
  var b = Bounds()
  for i in 0 ..< n:
    let (x, y) = (xs[i], ys[i])
    if not (abs(x) < Inf and abs(y) < Inf):
      raise newException(ValueError, "point " & $i & " is not finite")
    b.incl(x, y)
  result = SpatialIndex(bounds: b)
  order.setLen n
  if n == 0:
    result.starts = @[0'i32]
    return
  let (cell, nx, ny) = gridOf(b, n)
  (result.cell, result.nx, result.ny) = (cell, nx, ny)
  var cellOf = newSeq[int32](n)
  result.starts = newSeq[int32](nx * ny + 1)
  for i in 0 ..< n:
    let c = cellAt(ys[i], b.minY, cell, ny) * nx + cellAt(xs[i], b.minX, cell, nx)
    cellOf[i] = int32(c)
    inc result.starts[c + 1]
  for c in 1 .. nx * ny: result.starts[c] += result.starts[c - 1]
  var fill = result.starts # the next free place of each cell
  result.xs = newSeq[float64](n)
  result.ys = newSeq[float64](n)
  for i in 0 ..< n:
    let at = fill[cellOf[i]]
    inc fill[cellOf[i]]
    order[at] = int32(i)
    result.xs[at] = xs[i]
    result.ys[at] = ys[i]

func gap(v, lo, hi: float64): float64 {.inline.} =
  ## How far `v` lies outside `lo .. hi`; 0 inside.
  if v < lo: lo - v elif v > hi: v - hi else: 0.0

func nearest*(ix: SpatialIndex; x, y, radius: float64): int =
  ## The point nearest (`x`, `y`) no farther than `radius` (in the points'
  ## units; `Inf` for any distance); of two as near, the one first in the
  ## index's order. -1 for none, and for a place or radius that is not a
  ## number.
  result = -1
  if ix.xs.len == 0 or not (radius >= 0) or x.isNaN or y.isNaN: return
  let b = ix.bounds
  let r2 = radius * radius
  if gap(x, b.minX, b.maxX) ^ 2 + gap(y, b.minY, b.maxY) ^ 2 > r2: return
  let one = ix.nx == 1 and ix.ny == 1 # one cell: it holds every point, whatever its size
  let (ci, cj) = (cellAt(x, b.minX, ix.cell, ix.nx), cellAt(y, b.minY, ix.cell, ix.ny))
  var best = Inf
  template visit(i, j: int) =
    let (left, top) = (b.minX + float64(i) * ix.cell, b.minY + float64(j) * ix.cell)
    let d2 = gap(x, left, left + ix.cell) ^ 2 + gap(y, top, top + ix.cell) ^ 2
    if one or d2 <= min(best, r2):
      let c = j * ix.nx + i
      for p in int(ix.starts[c]) ..< int(ix.starts[c + 1]):
        let d = (ix.xs[p] - x) ^ 2 + (ix.ys[p] - y) ^ 2
        if d <= r2 and (result < 0 or d < best or (d == best and p < result)):
          (best, result) = (d, p)
  # Rings of cells around the place's cell (the nearest cell, for a place
  # outside): every point in ring k is at least k - 1 cells away.
  for k in 0 .. max(ix.nx, ix.ny):
    if float64(k - 1) * ix.cell > sqrt(min(best, r2)): break
    for j in max(cj - k, 0) .. min(cj + k, ix.ny - 1):
      if j == cj - k or j == cj + k:
        for i in max(ci - k, 0) .. min(ci + k, ix.nx - 1): visit(i, j)
      else:
        if ci - k >= 0: visit(ci - k, j)
        if k > 0 and ci + k < ix.nx: visit(ci + k, j)

iterator runs*(ix: SpatialIndex; box: Bounds): Slice[int] =
  ## The points of the cells `box` touches, as runs of consecutive points
  ## (one per row of cells): every point in `box` is in one, with others
  ## near it. Nothing for a box that misses the points' bounds.
  if ix.xs.len > 0 and overlaps(ix.bounds, box):
    let b = ix.bounds
    let (i0, i1) = (cellAt(box.minX, b.minX, ix.cell, ix.nx),
      cellAt(box.maxX, b.minX, ix.cell, ix.nx))
    let (j0, j1) = (cellAt(box.minY, b.minY, ix.cell, ix.ny),
      cellAt(box.maxY, b.minY, ix.cell, ix.ny))
    for j in j0 .. j1:
      let run = int(ix.starts[j * ix.nx + i0]) ..< int(ix.starts[j * ix.nx + i1 + 1])
      if run.len > 0: yield run

iterator within*(ix: SpatialIndex; box: Bounds): int =
  ## The points in `box`, edges included, in the index's order.
  for run in ix.runs(box):
    for p in run:
      if box.contains(ix.xs[p], ix.ys[p]): yield p

func cellPoints*(ix: SpatialIndex; i, j: int): Slice[int] =
  ## The points of cell (`i`, `j`) (`i` across, `j` down from the bounds'
  ## lower corner); empty outside the grid.
  if i in 0 ..< ix.nx and j in 0 ..< ix.ny:
    int(ix.starts[j * ix.nx + i]) ..< int(ix.starts[j * ix.nx + i + 1])
  else: 0 ..< 0
