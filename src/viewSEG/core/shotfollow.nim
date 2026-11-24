## Match one row of a shot log to a trace, a file or a signature.
##
## Time is the first key. Shots are repeated in receiver-gather data, and a
## log instant is kept to the microsecond, so two rows at one shot point are
## told apart by when they were shot. Numbers (file number, source line and
## point, point index) only narrow a time that hit several rows, or stand in
## when one side has no usable time.
##
## `buildShotIndex` arranges one `ShotView` once, off the UI thread: the rows
## that have a time, in order of that instant, a table by file number, and a
## table by source line and shot point in hundredths (the same `round` to
## 1/100 that `stationKey` uses). `match` is then a binary search or a table
## lookup. It never picks among several rows, and it allocates nothing.
##
## An exact time selects rows within `toleranceUs` of `timeUs`, widened by
## `windowUs` (both ends included). One row is `mrTime`. Several are narrowed
## by every number the query has; exactly one left is `mrTimeAndNumbers`, and
## otherwise the row is -1 with the count from before that narrowing. A time
## known only to the second selects the POSIX second `[s, s+1s)`. A window
## other than `0 .. 0` replaces that second: the range is `timeUs + windowUs`,
## both ends included, and the tolerance is not added. One such row is
## `mrSecond`. An exact query is never widened to the second, so a log row
## that sits on a whole second is a match only when the tolerance reaches it.
##
## With no time, or a time that hits no row, numbers match only when that key
## occurs on exactly one row of the whole log (`mrNumbers`). A file number,
## or a line and point, that occurs more than once is not a match: row -1 and
## that count. A file number the query carries is required, and is not
## narrowed by station when it is duplicated; a unique file number whose
## station disagrees is not a match, and a station is not tried in its place.
## Index 0 on either side matches any index. A point, or a line, alone is not
## a station.
##
## A time that hits nothing falls through to those numbers only when they
## name one row and that row's own time is missing. A row whose time is known
## and differs is not a match.
##
## Arithmetic is in int64 microseconds and saturates at `low(int64)` and
## `high(int64)`. A bound that does not fit is cut to the end, not wrapped.

import std/[algorithm, math, options, tables]
import shotlog

const UsPerSec = 1_000_000'i64

type
  Timed = object
    us: int64
    row: int

  RowBits = object
    fileNumber: int64
    lineH: int64
    pointH: int64
    index: int64
    hasFile: bool
    hasStation: bool
    hasTime: bool

  ShotIndex* = object
    ## One `ShotView` arranged for `match`. Built once, off the UI thread.
    byTime: seq[Timed]
    byFile: Table[int64, seq[int]]
    byStation: Table[(int64, int64), seq[int]]
    bits: seq[RowBits]

  ShotQuery* = object
    ## What is known of the shot to find.
    timeUs*: Option[int64]
      ## The shot instant, time zero or the trigger, UTC microseconds since 1970.
    timeExact*: bool
      ## False when only the whole second is known.
    windowUs*: Slice[int64]
      ## Extra range relative to `timeUs`, both ends included. `0 .. 0` is none.
    fileNumber*: Option[int64]
    line*, point*: float64
      ## NaN when not known. Compared at 1/100, as `stationKey` rounds.
    pointIndex*: int
      ## 0 matches any index.

  MatchRule* = enum
    mrNone           ## nothing to choose
    mrTime           ## one row inside the exact tolerance
    mrTimeAndNumbers ## several in the time range, one left after the numbers
    mrSecond         ## one row in the whole second, or in a start window
    mrNumbers        ## one row by file number or station, no usable time

  ShotMatch* = object
    ## The one row to take, or none. Jump only when `row` is not -1.
    rule*: MatchRule
    row*: int
      ## The unique row, or -1.
    count*: int
      ## How many rows fit. After a narrowing that did not leave one row,
      ## this is the count from before the narrowing.

  Span = object
    lo: int64
    hi: int64
    hiIn: bool
    empty: bool

  Hundredths = tuple[ok: bool, h: int64]

func noneMatch(): ShotMatch {.inline.} =
  ShotMatch(rule: mrNone, row: -1, count: 0)

func satAdd(a, b: int64): int64 {.inline.} =
  ## `a + b`, or the nearer end of int64 when the sum does not fit.
  if b == low(int64):
    if a < 0: low(int64) else: a + b
  elif b < 0:
    if a < low(int64) - b: low(int64) else: a + b
  elif a > high(int64) - b:
    high(int64)
  else:
    a + b

func satSub(a, b: int64): int64 {.inline.} =
  ## `a - b`, or the nearer end of int64 when the difference does not fit.
  if b == low(int64):
    if a >= 0: high(int64) else: a - b
  else:
    satAdd(a, -b)

func nsToUs(ns: int64): int64 {.inline.} =
  ## Floor of nanoseconds to microseconds. The quotient always fits.
  let q = ns div 1000
  if ns mod 1000 != 0 and ns < 0: q - 1 else: q

func posixSecond(us: int64): tuple[start, endEx: int64, openEnd: bool] =
  ## The POSIX second `[start, endEx)` that holds `us`. `openEnd`: the end
  ## does not fit, so every value from `start` through `high(int64)` is in it.
  ## A start before `low(int64)` is cut to `low(int64)`.
  if us >= 0:
    let start = us - us mod UsPerSec
    if start > high(int64) - UsPerSec: (start, high(int64), true)
    else: (start, start + UsPerSec, false)
  else:
    let r = us mod UsPerSec
    if r == 0:
      (us, us + UsPerSec, false)
    else:
      let towardZero = us - r
      if towardZero < low(int64) + UsPerSec: (low(int64), towardZero, false)
      else: (towardZero - UsPerSec, towardZero, false)

func finite(v: float64): bool {.inline.} =
  v - v == 0

func hundredths(v: float64): Hundredths =
  ## `v` in hundredths, the integer `stationKey` rounds to, or not ok.
  if not finite(v): return
  let scaled = v * 100.0
  if not finite(scaled): return
  let r = round(scaled)
  if r < float64(low(int64)) or r >= 9223372036854775808.0: return
  (true, int64(r))

func stationKnown(q: ShotQuery): bool {.inline.} =
  finite(q.line) and finite(q.point)

func indexOk(queryIndex: int; rowIndex: int64): bool {.inline.} =
  ## Index 0 on either side matches any index.
  queryIndex == 0 or rowIndex == 0 or rowIndex == int64(queryIndex)

func hasNumbers(q: ShotQuery): bool {.inline.} =
  q.fileNumber.isSome or stationKnown(q)

func spanOf(q: ShotQuery; toleranceUs: int64): Span =
  let t = q.timeUs.get
  if q.timeExact:
    let tol = if toleranceUs < 0: 0'i64 else: toleranceUs
    result.lo = satSub(satAdd(t, q.windowUs.a), tol)
    result.hi = satAdd(satAdd(t, q.windowUs.b), tol)
    result.hiIn = true
    result.empty = result.lo > result.hi
  elif q.windowUs.a == 0 and q.windowUs.b == 0:
    let sec = posixSecond(t)
    result.lo = sec.start
    if sec.openEnd:
      result.hi = high(int64)
      result.hiIn = true
    else:
      result.hi = sec.endEx
      result.hiIn = false
  else:
    result.lo = satAdd(t, q.windowUs.a)
    result.hi = satAdd(t, q.windowUs.b)
    result.hiIn = true
    result.empty = result.lo > result.hi

func lowerBound(a: openArray[Timed]; us: int64): int =
  var lo = 0
  var hi = a.len
  while lo < hi:
    let mid = lo + (hi - lo) div 2
    if a[mid].us < us: lo = mid + 1
    else: hi = mid
  lo

func upperBound(a: openArray[Timed]; us: int64): int =
  var lo = 0
  var hi = a.len
  while lo < hi:
    let mid = lo + (hi - lo) div 2
    if a[mid].us <= us: lo = mid + 1
    else: hi = mid
  lo

func hits(a: openArray[Timed]; s: Span): tuple[a, b: int] =
  if s.empty or a.len == 0: return (0, 0)
  let i = lowerBound(a, s.lo)
  let j = if s.hiIn: upperBound(a, s.hi) else: lowerBound(a, s.hi)
  if j <= i: (i, i) else: (i, j)

func passes(b: RowBits; q: ShotQuery): bool =
  ## Every number the query has agrees. A number it lacks is not a filter.
  if q.fileNumber.isSome:
    if not b.hasFile or b.fileNumber != q.fileNumber.get: return false
  if stationKnown(q):
    let line = hundredths(q.line)
    let point = hundredths(q.point)
    if not line.ok or not point.ok: return false
    if not b.hasStation or b.lineH != line.h or b.pointH != point.h: return false
    if not indexOk(q.pointIndex, b.index): return false
  true

func oneOf(ix: ShotIndex; q: ShotQuery; a, b: int): int =
  ## The one row in `byTime[a..<b]` that passes the numbers, or -1.
  result = -1
  var n = 0
  for i in a ..< b:
    let row = ix.byTime[i].row
    if passes(ix.bits[row], q):
      inc n
      if n > 1: return -1
      result = row
  if n != 1: result = -1

proc byNumbers(ix: ShotIndex; q: ShotQuery): ShotMatch {.raises: [].} =
  ## Rule 3. A duplicated key is not narrowed further.
  result = noneMatch()
  if q.fileNumber.isSome:
    var n = 0
    var hit = -1
    ix.byFile.withValue(q.fileNumber.get, rows):
      n = rows.len
      if n == 1: hit = rows[0]
    if n == 0: return
    if n > 1: return ShotMatch(rule: mrNumbers, row: -1, count: n)
    if stationKnown(q) and not passes(ix.bits[hit], q): return
    return ShotMatch(rule: mrNumbers, row: hit, count: 1)
  if stationKnown(q):
    let line = hundredths(q.line)
    let point = hundredths(q.point)
    if not line.ok or not point.ok: return
    var n = 0
    var hit = -1
    ix.byStation.withValue((line.h, point.h), rows):
      for r in rows:
        if indexOk(q.pointIndex, ix.bits[r].index):
          inc n
          hit = r
    if n == 1: return ShotMatch(rule: mrNumbers, row: hit, count: 1)
    if n > 1: return ShotMatch(rule: mrNumbers, row: -1, count: n)

proc buildShotIndex*(view: ShotView): ShotIndex {.raises: [].} =
  ## The lookup for `view`. Rows keep their order; a row with no time is
  ## left out of the time order and can be reached only by its numbers.
  let n = view.rows.len
  result.bits = newSeq[RowBits](n)
  result.byTime = newSeqOfCap[Timed](n)
  if n > 0:
    result.byFile = initTable[int64, seq[int]](n)
    result.byStation = initTable[(int64, int64), seq[int]](n)
  for row, shot in view.rows:
    var b: RowBits
    if shot.fileNumber.isSome:
      b.hasFile = true
      b.fileNumber = shot.fileNumber.get
      result.byFile.withValue(b.fileNumber, rows):
        rows[].add row
      do:
        result.byFile[b.fileNumber] = @[row]
    if finite(shot.sourceLine) and finite(shot.shotPoint):
      let line = hundredths(shot.sourceLine)
      let point = hundredths(shot.shotPoint)
      if line.ok and point.ok:
        b.hasStation = true
        b.lineH = line.h
        b.pointH = point.h
        if shot.pointIndex.isSome: b.index = shot.pointIndex.get
        let key = (b.lineH, b.pointH)
        result.byStation.withValue(key, rows):
          rows[].add row
        do:
          result.byStation[key] = @[row]
    if shot.timeUtcUs.isSome:
      b.hasTime = true
      result.byTime.add Timed(us: shot.timeUtcUs.get, row: row)
    result.bits[row] = b
  result.byTime.sort(proc (a, b: Timed): int =
    let c = cmp(a.us, b.us)
    if c != 0: c else: cmp(a.row, b.row))

proc match*(ix: ShotIndex; q: ShotQuery; toleranceUs = 1000'i64): ShotMatch {.raises: [].} =
  ## The one row for `q`, or none.
  ##
  ## Exact time, then a whole second (or a window that replaces it), then
  ## numbers. Numbers narrow a time that hit several rows; they do not veto
  ## a time that hit one. A time that hits nothing uses the numbers only for
  ## a unique row whose own time is missing. A row whose time is known and
  ## differs is not a match. `count` is 1 for a chosen row, 0 when nothing
  ## fits, and otherwise how many rows the time or the number key found
  ## before a narrowing that did not leave one.
  result = noneMatch()
  if q.timeUs.isNone:
    return byNumbers(ix, q)
  let s = spanOf(q, toleranceUs)
  let (a, b) = hits(ix.byTime, s)
  let n = b - a
  let timeRule = if q.timeExact: mrTime else: mrSecond
  if n == 1:
    return ShotMatch(rule: timeRule, row: ix.byTime[a].row, count: 1)
  if n > 1:
    if hasNumbers(q):
      let row = oneOf(ix, q, a, b)
      if row >= 0: return ShotMatch(rule: mrTimeAndNumbers, row: row, count: 1)
    return ShotMatch(rule: timeRule, row: -1, count: n)
  let byNum = byNumbers(ix, q)
  if byNum.row >= 0 and not ix.bits[byNum.row].hasTime: return byNum

proc queryOfKeys*(recordTimeZeroUs: Option[int64]; exact: bool; record, srcLine,
    srcPoint: float64; srcIndex: int): ShotQuery {.raises: [].} =
  ## A trace's query. `recordTimeZeroUs` is time zero, not sample 0; `exact`
  ## is false when only the whole second is known. `record` is the file
  ## number, NaN when unknown, and otherwise the nearest integer that fits.
  ## `srcLine` and `srcPoint` stay as given, NaN when unknown. `srcIndex` 0
  ## is unknown.
  result.timeUs = recordTimeZeroUs
  result.timeExact = exact
  result.windowUs = 0'i64 .. 0'i64
  result.line = srcLine
  result.point = srcPoint
  result.pointIndex = srcIndex
  if finite(record):
    let r = round(record)
    if r >= float64(low(int64)) and r < 9223372036854775808.0:
      result.fileNumber = some(int64(r))

proc queryOfSweep*(triggerNs: int64; timeIsStart: bool; fileNumber: int; line,
    station: float64; sourceIndex: int): ShotQuery {.raises: [].} =
  ## A signature file's query. `triggerNs` is UTC nanoseconds since 1970,
  ## floored to the microsecond.
  ##
  ## `timeIsStart` is a lone start second: the query is not exact, `timeUs`
  ## is the POSIX second that holds that instant, and `windowUs` is
  ## `200_000 .. 1_500_000` after it (recording began that long before the
  ## trigger). Otherwise the trigger is exact and the window is `0 .. 0`.
  ## A file number of 0 or less is not given. A line or station of 0, or one
  ## that is not finite, is not given. `sourceIndex` is the point index.
  result.windowUs = 0'i64 .. 0'i64
  result.pointIndex = sourceIndex
  if fileNumber > 0: result.fileNumber = some(int64(fileNumber))
  if finite(line) and finite(station) and line != 0.0 and station != 0.0:
    result.line = line
    result.point = station
  else:
    result.line = NaN
    result.point = NaN
  let us = nsToUs(triggerNs)
  if timeIsStart:
    result.timeUs = some(posixSecond(us).start)
    result.timeExact = false
    result.windowUs = 200_000'i64 .. 1_500_000'i64
  else:
    result.timeUs = some(us)
    result.timeExact = true
