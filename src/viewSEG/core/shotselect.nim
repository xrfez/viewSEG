## Choosing shots of a shot log from the map, and finding their traces.
##
## A shot can be taken twice: the log then has several rows at one source
## point. `rowsAtPoint` gives all of them, by the station the log names
## (source line and shot point, to a hundredth, as `stationKey` rounds), or,
## for a row without one, by position. `shotTraces` finds the traces of a
## file that belong to chosen rows with the rule the Shot log window's
## follow uses (`traceQuery` and `matched`, then `ShotIndex.match`), so the
## answer is the same as the row that trace is followed to.
##
## The kept answer is `ShotRows`: the rows chosen, in one loaded log.

import std/[algorithm, math, options, sets]
import parseSEG
import ./[shotfollow, shotfollowtarget, shotlog, spatial, survey]

const
  SamePlace* = 0.01
    ## Rows of a log without line and point at positions this near (survey
    ## units) are one source point.

type
  ShotRows* = object
    ## The rows chosen in loaded shot log `log` (its id; -1 for none).
    log*: int
    rows*: seq[int] ## ascending, each once
    revision*: int  ## goes up each time the choice changes

  TraceMatch* = object
    traces*: seq[int] ## the file's trace indices (local), in file order
    tried*: int       ## the traces whose time was readable
    unreadable*: bool ## the file has no stored keys: nothing was tried

func hundredth(v: float64): int64 =
  if v.isNaN or abs(v) > 1e12: low(int64) else: int64(round(v * 100.0))

func sameStation(a, b: Station): bool =
  a.known and b.known and hundredth(a.line) == hundredth(b.line) and
    hundredth(a.point) == hundredth(b.point)

func rowsAtPoint*(l: SurveyLayer; point: int): seq[int] =
  ## Every row of shot log layer `l` taken at its source point `point`:
  ## those with the same station, or, when the point has none, those at the
  ## same place (`SamePlace`). Ascending; none when `l` is not a shot log's
  ## or `point` is not one of its points.
  if l.origin != loShotLog or point notin 0 ..< l.points[prSource].len: return
  let ps = addr l.points[prSource]
  let station = ps.station[point]
  if station.known:
    for q in 0 ..< ps.station.len:
      if sameStation(ps.station[q], station):
        for row in l.shotRows(q): result.add row
  else:
    let (x, y) = (ps.index.x(point), ps.index.y(point))
    let box = Bounds(minX: x - SamePlace, minY: y - SamePlace, maxX: x + SamePlace,
      maxY: y + SamePlace)
    for q in ps.index.within(box):
      if not ps.station[q].known:
        for row in l.shotRows(q): result.add row
  result.sort()

func pointsOfRows*(l: SurveyLayer; rows: openArray[int]): seq[int] =
  ## The source points of shot log layer `l` that hold `rows` (a row without
  ## a position has none), each once, ascending.
  if l.origin != loShotLog: return
  var seen = initHashSet[int]()
  for row in rows:
    let p = l.shotPoint(row)
    if p >= 0 and not seen.containsOrIncl(p): result.add p
  result.sort()

proc shotTraces*(f: SeismicFile; index: ref ShotIndex; rows: openArray[int]): TraceMatch
    {.raises: [].} =
  ## The traces of `f` (indices in the file) whose shot is one of `rows`:
  ## each trace's query (`traceQuery`) matched in `index` (`matched`) to one
  ## row, as the Shot log window's follow does. A SEG-Y opened without keys is
  ## not read (`unreadable`); a trace whose shot is no row, or several, is not
  ## taken. Reads no file.
  result = TraceMatch()
  if index == nil or rows.len == 0: return
  var wanted = initHashSet[int]()
  for r in rows: wanted.incl r
  if f.kind == skSegy and not f.hasKeys:
    result.unreadable = true
    return
  for t in 0 ..< f.len:
    let m = matched(index, traceQuery(f, t))
    if m.rule != mrNone: inc result.tried
    if m.row >= 0 and m.row in wanted: result.traces.add t
