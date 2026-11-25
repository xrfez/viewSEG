## Choosing shots of a shot log from the map, and finding their traces.
##
## A shot can be taken twice: the log then has several rows at one source
## point. `rowsAtPoint` gives all of them: the rows of the log at the point's
## source line and shot point (`ShotIndex.rowsAtStation`, to a hundredth, as
## `match` compares them), or, for a point with no station, the rows with
## none at the same place. A row with a station is never grouped with one
## without.
##
## `buildTraceMap` reads a file's trace keys once, on a job, and tells each
## trace's shot with the rule the Shot log window's follow uses
## (`queryOfTrace`, `matched`, then `ShotIndex.match`), so the answer is the
## row that trace is followed to. `ShotTraceMap` then gives the traces of
## chosen rows by look-up, whatever the file's size.

import std/[algorithm, options, sets]
import parseSEG
import ./[shotfollow, shotfollowtarget, shotlog, spatial, survey]

const
  SamePlace* = 0.01
    ## Rows of a log without line and point at positions this near (survey
    ## units) are one source point.
  KeyChunk = 4096 ## traces whose keys are read in one go

type
  ShotRows* = object
    ## The rows chosen in loaded shot log `log` (its id; -1 for none).
    log*: int
    rows*: seq[int] ## ascending, each once
    revision*: int  ## goes up each time the choice changes

  ShotTraceMap* = object
    ## Which traces of one file belong to which row of one log: the traces of row `r`
    ## are `list[start[r] ..< start[r + 1]]`, ascending (indices in the file).
    start*: seq[int32]
    list*: seq[int32]
    traces*: int ## the traces of the file
    unreadable*: bool ## the file has no stored keys: nothing was tried

  ShotTraceSink* = ref object
    ## Filled by the job that builds the map; read once it has ended.
    map*: ShotTraceMap

func rowsAtPoint*(l: SurveyLayer; point: int; index: ref ShotIndex): seq[int] =
  ## Every row of the log taken at source point `point` of shot log layer `l`: with a station,
  ## all rows at that line and point (rows without a position too), found in `index`; a point
  ## with none, the rows with none at the same place (`SamePlace`). A station `index` cannot
  ## compare (not a finite number that fits) gives the point's own rows. Ascending; none when `l`
  ## is not a shot log's or `point` is not one of its points.
  if l.origin != loShotLog or point notin 0 ..< l.points[prSource].len: return
  let ps = addr l.points[prSource]
  let station = ps.station[point]
  if station.known:
    if index != nil: result = index[].rowsAtStation(station.line, station.point)
    if result.len == 0:
      for row in l.shotRows(point): result.add row
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

proc buildTraceMap*(f: ptr SeismicFile; index: ref ShotIndex; rows: int;
    stop: proc () {.gcsafe.}): ShotTraceMap =
  ## The map of file `f` against `index`, a log of `rows` rows. Reads the keys a chunk at a time
  ## and no file; `stop` is called between chunks (it may raise to leave). A SEG-Y opened
  ## without keys is not read (`unreadable`).
  result = ShotTraceMap(start: newSeq[int32](rows + 1), traces: f[].len)
  if index == nil or rows == 0 or result.traces == 0: return
  if f[].kind == skSegy and not f[].hasKeys:
    result.unreadable = true
    return
  var rowOf = newSeq[int32](result.traces)
  var keys = newSeq[TraceKeys](KeyChunk)
  var a = 0
  while a < result.traces:
    let b = min(a + KeyChunk, result.traces) - 1
    stop()
    var ok = true
    try: f[].traceKeysInto(a .. b, keys.toOpenArray(0, b - a))
    except CatchableError: ok = false
    for t in a .. b:
      rowOf[t] = -1
      if ok:
        let m = matched(index, queryOfTrace(f[], t, keys[t - a]))
        if m.row in 0 ..< rows: rowOf[t] = int32(m.row)
    a = b + 1
  for r in rowOf:
    if r >= 0: inc result.start[r + 1]
  for r in 1 .. rows: result.start[r] += result.start[r - 1]
  result.list = newSeq[int32](result.start[rows])
  var fill = result.start
  for t, r in rowOf:
    if r >= 0:
      result.list[fill[r]] = int32(t)
      inc fill[r]

func tracesOfRows*(m: ShotTraceMap; rows: openArray[int]): seq[int] =
  ## The traces (indices in the file) of `rows`, ascending, each once.
  for r in rows:
    if r in 0 ..< m.start.len - 1:
      for i in m.start[r] ..< m.start[r + 1]: result.add int(m.list[i])
  result.sort()
