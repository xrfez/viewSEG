## The map's thinning of a large highlight (`core/mapthin`): of 842 000
## selected points (a box over most of a dense survey), one a cell of a
## pixel and a half is kept, every selected point in the view's area has a
## kept one in its own cell (the highlight's edge stays where the
## selection's is), points off the area or hidden are left out, the area
## follows the view (`thinFits`), and an area of a huge view is cut into a
## bounded number of cells.
##
## It runs with a 1 MB stack (`ulimit -s`), Windows' default for a program,
## at the closest zoom the map has and at the farthest, so a
## thinning whose teardown or work grows with the number of cells taken
## fails here as it would on Windows.
##
## Seen to fail: with the cells taken kept in an `IntSet` keyed by cell, as
## the map first did (one trunk a cell at a close zoom, freed by recursion),
## the 1 MB stack overflowed at the close zoom (SIGSEGV, exit 139).

import std/[math, random, sets]
import viewSEG/core/[mapthin, mapview, spatial]

when defined(posix):
  import std/os

const
  Selected = 842_000
  Side = 50_000.0 ## the survey's side, survey units
  Columns = 1600
  Rows = 1000

let origin = mapPoint(0, 0)

func view(centre: MapPoint; perPixel: float64; columns = Columns; rows = Rows): MapView =
  MapView(centre: centre, perPixel: perPixel, columns: columns, rows: rows)

func cellOf(a: ThinArea; p: MapPoint): int =
  let cx = min(int((p.x - a.area.minX) / a.cell), a.nx - 1)
  let cy = min(int((p.y - a.area.minY) / a.cell), a.ny - 1)
  cy * a.nx + cx

func inside(a: ThinArea; p: MapPoint): bool =
  p.x >= a.area.minX and p.x < a.area.maxX and p.y >= a.area.minY and p.y < a.area.maxY

proc checkThinned(points, kept: openArray[MapPoint]; a: ThinArea; what: string) =
  ## Every kept point is a selected one inside the area, one a cell, and
  ## every selected point inside the area has its cell's kept point.
  var cells = initHashSet[int]()
  var selected = initHashSet[(float64, float64)]()
  for p in points: selected.incl (p.x, p.y)
  for p in kept:
    doAssert a.inside(p), what & ": a kept point outside the area"
    doAssert (p.x, p.y) in selected, what & ": a kept point that is not selected"
    doAssert not cells.containsOrIncl(a.cellOf(p)), what & ": two kept points in one cell"
  var inArea = 0
  for p in points:
    if a.inside(p):
      inc inArea
      doAssert a.cellOf(p) in cells, what & ": a selected point with no kept point in its cell"
  doAssert inArea == 0 or kept.len > 0, what

proc main() =
  var r = initRand(1)
  var points = newSeq[MapPoint](Selected)
  for p in points.mitems: p = mapPoint(r.rand(Side), r.rand(Side))
  var kept: seq[MapPoint]
  var taken: seq[uint64]
  let centre = mapPoint(Side / 2, Side / 2)

  block closestZoom:
    # the closest zoom of a survey 50 km across: 1e-6 of it a pixel
    let a = thinArea(view(centre, Side * MinShare), origin)
    doAssert a.cell > 0 and a.nx * a.ny < 4 * Columns * Rows
    kept.thinned(points, a, taken)
    checkThinned(points, kept, a, "closest zoom")
    # half a metre a pixel: the area holds a few hundred of the points, each
    # its own cell
    let b = thinArea(view(centre, 0.5), origin)
    kept.thinned(points, b, taken)
    checkThinned(points, kept, b, "0.5 a pixel")
    doAssert kept.len in 300 .. 900, $kept.len & " kept at 0.5 a pixel"

  block farthestZoom:
    # the whole survey in view: about one kept a cell of 1.5 pixels
    let v = view(centre, Side / (Rows - 24))
    let a = thinArea(v, origin)
    kept.thinned(points, a, taken)
    checkThinned(points, kept, a, "at fit")
    let cellsOverSurvey = (Side / a.cell) ^ 2
    doAssert kept.len < Selected div 2 and float64(kept.len) <= cellsOverSurvey * 1.05,
      $kept.len & " kept at fit"
    doAssert float64(kept.len) > cellsOverSurvey * 0.7, $kept.len & " kept at fit"

  block hiddenAndOutside:
    let a = thinArea(view(centre, 1.0), origin)
    var some = @[mapPoint(NaN, NaN), mapPoint(centre.x, NaN), centre,
      mapPoint(centre.x + 1e6, centre.y), mapPoint(-1e9, -1e9)]
    kept.thinned(some, a, taken)
    doAssert kept == @[centre], $kept

  block theAreaFollowsTheView:
    let v = view(centre, 2.0)
    let a = thinArea(v, origin)
    doAssert a.thinFits(v)
    # its corner is on the survey's grid of cells
    doAssert abs(a.area.minX / a.cell - round(a.area.minX / a.cell)) < 1e-6
    let quarter = view(mapPoint(centre.x + v.width / 4, centre.y - v.height / 4), 2.0)
    doAssert a.thinFits(quarter), "a pan of a quarter of the view thins again"
    let whole = view(mapPoint(centre.x + v.width, centre.y), 2.0)
    doAssert not a.thinFits(whole), "a pan of a whole view does not thin again"
    doAssert a.thinFits(view(centre, 2.0 * 1.2)) and a.thinFits(view(centre, 2.0 / 1.2))
    doAssert not a.thinFits(view(centre, 2.0 * 1.6)), "zoomed out by 1.6"
    doAssert not a.thinFits(view(centre, 2.0 / 1.6)), "zoomed in by 1.6"
    doAssert not ThinArea().thinFits(v)
    doAssert thinArea(MapView(), origin).cell == 0

  block aHugeViewIsBounded:
    let v = view(centre, 0.01, 40_000, 40_000)
    let a = thinArea(v, origin)
    doAssert float64(a.nx) * float64(a.ny) <= float64(ThinMaxCells) * 1.05,
      $a.nx & " x " & $a.ny
    doAssert a.thinFits(v), "a huge view's area serves it"
    kept.thinned(points, a, taken)
    checkThinned(points, kept, a, "a huge view")

when defined(posix):
  # the program again, with a 1 MB stack (`ulimit -s` sets the main thread's)
  if paramCount() == 1 and paramStr(1) == "--small-stack": main()
  else:
    let code = execShellCmd("ulimit -s 1024 && exec " & quoteShell(getAppFilename()) &
      " --small-stack")
    doAssert code == 0, "the thinning failed on a 1 MB stack: exit " & $code
else:
  main()
