## How the map's view moves: zoom about a point, pan, drag, box zoom, fit
## and a new plot size, always at equal aspect (one survey unit is as many
## pixels across as down) and never away from the survey.
##
## A `MapView` is the survey point at the plot's centre and the survey units
## per framebuffer pixel (`perPixel`), the same along both axes, so no
## gesture can stretch the map. Survey coordinates: easting across (east to
## the right), northing up (north at the top of the plot).
##
## **Limits** (`MapLimits`: the survey's bounds and a margin in pixels, room
## for the markers of the points at its edges):
##
## - zoomed out as far as it goes, the survey fits the plot (`fitMap`): its
##   longer side, as the plot's shape decides, fills the plot but for the
##   margin; equal aspect leaves room along the other, with the survey
##   centred. No view shows the survey smaller, so the map never loses it;
## - zoomed in, never closer than `MinShare` of the survey's extent across a
##   pixel;
## - along an axis where the view is narrower than the survey (and margin),
##   it stays inside them; along one where it is wider, the survey is centred
##   on it. So no view goes past the survey's bounds by more than equal
##   aspect needs.
##
## A view that is within the limits is left exactly as it is. A zoom keeps
## the point it is about where it is on the screen; one that reaches a limit
## stops there. **A new plot size** (`resizedMap`) keeps the scale and the
## top-left corner, as the plot window does: a larger plot shows more of the
## survey, a smaller one less, and only where the plot becomes larger than
## the whole survey at that scale does the scale grow, as far as fits it.
##
## The frontend turns the pointer into survey coordinates with `mapAt` and
## back with `screenAt`, and draws the scale bar `scaleBar` gives.

import std/math
import geometry, spatial

const
  MapMargin* = 12.0
    ## pixels kept round the survey's bounds at fit: the markers of the
    ## points on its edges are drawn whole
  MinShare* = 1e-6
    ## the closest zoom: a pixel is this share of the survey's extent
  LoneSpan* = 100.0
    ## the extent given to a survey of one point (or of points on one spot),
    ## in its units: what fit shows around it

type
  MapPoint* = object
    ## A place in survey coordinates.
    x*: float64 ## easting
    y*: float64 ## northing

  MapView* = object
    ## What the map shows.
    centre*: MapPoint    ## the survey point at the plot's centre
    perPixel*: float64   ## survey units per framebuffer pixel, across and down; 0: not set
    columns*, rows*: int ## the plot's size in framebuffer pixels

  MapLimits* = object
    ## What a map view is kept within.
    bounds*: Bounds              ## of the survey's points; empty for none
    margin*: float64 = MapMargin ## pixels the view may reach past them

  ScaleBar* = object
    ## A scale bar: `length` survey units, drawn `pixels` long.
    length*: float64
    pixels*: float64

func mapPoint*(x, y: float64): MapPoint {.inline.} = MapPoint(x: x, y: y)

func isSet*(v: MapView): bool {.inline.} =
  ## Whether `v` shows anything: a scale and a plot size.
  v.perPixel > 0 and v.perPixel < Inf and v.columns > 0 and v.rows > 0

func width*(v: MapView): float64 {.inline.} = float64(v.columns) * v.perPixel
  ## Survey units across the plot.

func height*(v: MapView): float64 {.inline.} = float64(v.rows) * v.perPixel
  ## Survey units down the plot.

func visible*(v: MapView): Bounds =
  ## The survey area the plot shows.
  let (hw, hh) = (v.width / 2, v.height / 2)
  Bounds(minX: v.centre.x - hw, minY: v.centre.y - hh, maxX: v.centre.x + hw,
    maxY: v.centre.y + hh)

func mapLimits*(b: Bounds; margin = MapMargin): MapLimits =
  ## The limits of a map of points within `b`.
  MapLimits(bounds: b, margin: margin)

func spans(lim: MapLimits): tuple[lo, hi: MapPoint] =
  ## The bounds, opened up to `LoneSpan` where they have no extent at all
  ## (one point): what fit shows.
  let b = lim.bounds
  result = (mapPoint(b.minX, b.minY), mapPoint(b.maxX, b.maxY))
  if b.width == 0 and b.height == 0:
    let (cx, cy) = (b.minX, b.minY)
    result = (mapPoint(cx - LoneSpan / 2, cy - LoneSpan / 2),
      mapPoint(cx + LoneSpan / 2, cy + LoneSpan / 2))

func extent(lim: MapLimits): float64 =
  let (lo, hi) = lim.spans
  max(hi.x - lo.x, hi.y - lo.y)

func room(pixels: int; margin: float64): float64 =
  ## Pixels the survey may fill along an axis of `pixels`: all but the
  ## margins, but at least half of them.
  max(max(float64(pixels) - 2 * margin, float64(pixels) / 2), 1.0)

func mostPerPixel*(lim: MapLimits; columns, rows: int): float64 =
  ## The farthest zoom on a plot of `columns` × `rows` pixels: the survey
  ## fits it, margins included. 0 for a survey with no points.
  if lim.bounds.isEmpty: return 0
  let (lo, hi) = lim.spans
  max((hi.x - lo.x) / room(columns, lim.margin), (hi.y - lo.y) / room(rows, lim.margin))

func leastPerPixel*(lim: MapLimits): float64 =
  ## The closest zoom: `MinShare` of the survey's extent a pixel.
  lim.extent * MinShare

func centreOf(lim: MapLimits): MapPoint =
  let (lo, hi) = lim.spans
  mapPoint((lo.x + hi.x) / 2, (lo.y + hi.y) / 2)

func fitMap*(lim: MapLimits; columns, rows: int): MapView =
  ## The whole survey on a plot of `columns` × `rows` pixels, centred. A
  ## view of nothing (`isSet` false) for a survey with no points.
  MapView(centre: lim.centreOf, perPixel: lim.mostPerPixel(columns, rows), columns: columns,
    rows: rows)

func keptAxis(c, half, lo, hi, margin: float64): float64 =
  ## A centre along one axis: inside `lo - margin .. hi + margin` with a
  ## view `2 * half` wide, or centred on it when the view is wider.
  let (a, b) = (lo - margin, hi + margin)
  if 2 * half >= b - a: (a + b) / 2
  elif c.isNaN: (a + b) / 2
  else: clamp(c, a + half, b - half)

func keptMap*(v: MapView; lim: MapLimits): MapView =
  ## `v` within `lim`: its scale between the closest zoom and the fit of the
  ## survey, then its centre where no view goes past the survey's bounds by
  ## more than equal aspect needs. Unchanged when it is within them already;
  ## a scale that is not a number becomes the fit. Its pixel size is kept.
  ## A survey with no points keeps any view.
  result = v
  if lim.bounds.isEmpty or v.columns <= 0 or v.rows <= 0: return
  let most = lim.mostPerPixel(v.columns, v.rows)
  let least = min(lim.leastPerPixel, most)
  result.perPixel = if v.perPixel > 0 and v.perPixel < Inf: clamp(v.perPixel, least, most)
                    else: most
  let (lo, hi) = lim.spans
  let m = lim.margin * result.perPixel
  result.centre.x = keptAxis(v.centre.x, result.width / 2, lo.x, hi.x, m)
  result.centre.y = keptAxis(v.centre.y, result.height / 2, lo.y, hi.y, m)

func showsAll*(v: MapView; lim: MapLimits): bool =
  ## Whether `v` shows the whole survey (as fit does).
  if lim.bounds.isEmpty or not v.isSet: return true
  let b = lim.bounds
  let s = v.visible
  s.minX <= b.minX and s.maxX >= b.maxX and s.minY <= b.minY and s.maxY >= b.maxY and
    v.perPixel >= lim.mostPerPixel(v.columns, v.rows) * (1 - 1e-9)

func checkFactor(factor: float64) =
  if not (factor > 0 and factor < Inf):
    raise newException(ValueError, "a zoom factor must be positive and finite, got " & $factor)

func zoomedMap*(v: MapView; factor: float64; at: MapPoint; lim: MapLimits): MapView =
  ## `v` zoomed in by `factor` (above 1 zooms in, below 1 out) about `at`,
  ## which stays where it is on the screen (as far as the limits let it),
  ## then kept within `lim`. About the centre when `at` is not a number.
  ## Raises `ValueError` for a factor that is not positive and finite.
  checkFactor(factor)
  if not v.isSet: return keptMap(v, lim)
  let anchor = if at.x.isNaN or at.y.isNaN or abs(at.x) == Inf or abs(at.y) == Inf: v.centre
               else: at
  var next = keptMap(MapView(centre: v.centre, perPixel: v.perPixel / factor,
    columns: v.columns, rows: v.rows), lim)
  let k = next.perPixel / v.perPixel
  next.centre = mapPoint(anchor.x + (v.centre.x - anchor.x) * k,
    anchor.y + (v.centre.y - anchor.y) * k)
  keptMap(next, lim)

func pannedMap*(v: MapView; dx, dy: float64; lim: MapLimits): MapView =
  ## `v` moved by `dx` east and `dy` north (survey units), stopping at the
  ## limits.
  result = v
  result.centre = mapPoint(v.centre.x + dx, v.centre.y + dy)
  result = keptMap(result, lim)

func steppedMap*(v: MapView; fx, fy: float64; lim: MapLimits): MapView =
  ## `v` moved by `fx` of its width east and `fy` of its height north (the
  ## arrow keys: a tenth, or a whole view with Shift).
  pannedMap(v, fx * v.width, fy * v.height, lim)

func mapAt*(v: MapView; plot: Rect; p: Vec2): MapPoint =
  ## The survey point under screen point `p` of the plot drawn in `plot`
  ## (any pixel units, the same for both).
  let w = if plot.size.x > 0: float64(plot.size.x) else: 1.0
  let h = if plot.size.y > 0: float64(plot.size.y) else: 1.0
  let fx = (float64(p.x) - float64(plot.pos.x)) / w - 0.5
  let fy = (float64(p.y) - float64(plot.pos.y)) / h - 0.5
  mapPoint(v.centre.x + fx * v.width, v.centre.y - fy * v.height)

func screenAt*(v: MapView; plot: Rect; q: MapPoint): Vec2 =
  ## Where survey point `q` is drawn in `plot`: the inverse of `mapAt`.
  let fx = if v.width > 0: (q.x - v.centre.x) / v.width else: 0.0
  let fy = if v.height > 0: (v.centre.y - q.y) / v.height else: 0.0
  vec2(float32(float64(plot.pos.x) + (fx + 0.5) * float64(plot.size.x)),
    float32(float64(plot.pos.y) + (fy + 0.5) * float64(plot.size.y)))

func draggedMap*(start: MapView; plot: Rect; moved: Vec2; lim: MapLimits): MapView =
  ## The view while the map is dragged: `start` (the view at the press)
  ## with the pointer `moved` from where it was pressed (in `plot`'s
  ## units), so the survey point under it stays under it.
  let w = if plot.size.x > 0: float64(plot.size.x) else: 1.0
  let h = if plot.size.y > 0: float64(plot.size.y) else: 1.0
  pannedMap(start, -float64(moved.x) / w * start.width, float64(moved.y) / h * start.height,
    lim)

func boxedMap*(v: MapView; a, b: MapPoint; lim: MapLimits): MapView =
  ## The view of the box with corners `a` and `b`: as close as shows all of
  ## it at equal aspect, centred on it, kept within the limits.
  if not v.isSet: return keptMap(v, lim)
  let pp = max(abs(b.x - a.x) / float64(v.columns), abs(b.y - a.y) / float64(v.rows))
  keptMap(MapView(centre: mapPoint((a.x + b.x) / 2, (a.y + b.y) / 2), perPixel: pp,
    columns: v.columns, rows: v.rows), lim)

func resizedMap*(v: MapView; columns, rows: int; lim: MapLimits): MapView =
  ## `v` on a plot of `columns` × `rows` pixels: the same scale and the
  ## same top-left corner, so more or less of the survey comes into view
  ## (never less than all of it at the farthest zoom: the scale then grows
  ## as far as fits it). A view that was not set fits the survey.
  if not v.isSet: return fitMap(lim, columns, rows)
  let left = v.centre.x - v.width / 2
  let top = v.centre.y + v.height / 2
  let pp = v.perPixel
  keptMap(MapView(centre: mapPoint(left + float64(columns) * pp / 2,
    top - float64(rows) * pp / 2), perPixel: pp, columns: columns, rows: rows), lim)

func sameMapView*(a, b: MapView): bool =
  ## Whether `a` and `b` show the same survey area, whatever their sizes.
  a.centre == b.centre and a.perPixel == b.perPixel

# ------------------------------------------------------------ measuring --

func distance*(a, b: MapPoint): float64 =
  ## The grid distance from `a` to `b`, in survey units.
  hypot(b.x - a.x, b.y - a.y)

func bearing*(a, b: MapPoint): float64 =
  ## The grid bearing from `a` to `b`: degrees clockwise from grid north,
  ## 0 to below 360; NaN when they are one place.
  if a == b: return NaN
  result = radToDeg(arctan2(b.x - a.x, b.y - a.y))
  if result < 0: result += 360
  if result >= 360: result -= 360

func scaleBar*(perPixel, longest: float64): ScaleBar =
  ## The scale bar for a map at `perPixel` units a pixel, at most `longest`
  ## pixels long: the longest 1, 2 or 5 times a power of ten that fits.
  ## None (0 long) when the scale is not set.
  if not (perPixel > 0 and perPixel < Inf and longest >= 1): return
  let most = perPixel * longest
  var p = pow(10.0, floor(log10(most)))
  var len = p
  for m in [5.0, 2.0, 1.0]:
    if m * p <= most * (1 + 1e-12):
      len = m * p
      break
  ScaleBar(length: len, pixels: len / perPixel)

func decimalsFor*(perPixel: float64): int =
  ## The decimals a coordinate needs at `perPixel` units a pixel: enough
  ## that a pixel's step shows, 0 to 3.
  if not (perPixel > 0 and perPixel < Inf): return 0
  clamp(int(ceil(-log10(perPixel))), 0, 3)
