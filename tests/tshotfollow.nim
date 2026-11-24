## Match a shot-log row by time first, then by file number or station
## (`core/shotfollow`). Rows are built here; nothing is read from a file.
##
## Seen to fail: an exclusive upper bound (`<` for `<=` in `upperBound`) dropped a
## row whose time equals the span's high bound. First failure was "two rows at
## one instant", which came back `mrNone` row -1 count 0.
##
## Seen to fail: with `spanOf` saturating `t + window` and the tolerance as
## two adds, "window 1 past high is empty" came back `mrTime` row 0 count 1.
## A window before `low` did the same, a tolerance after that clamp widened
## the span (`mrTime` row 0 count 1), and a non-exact window past `high`
## came back `mrSecond` row 0 count 1.
##
## Runs alone: it times 100000 matches.

import std/[math, monotimes, options, times]
import parseSEG
import viewSEG/core/[shotfollow, shotlog]

proc allocations(): int =
  cast[tuple[allocs, deallocs: int]](getAllocStats()).allocs

proc row(timeUs: Option[int64] = none(int64); fileNo: Option[int64] = none(int64);
    line = NaN; point = NaN; index: Option[int64] = none(int64)): Shot =
  Shot(sailLine: NaN, sourceLine: line, shotPoint: point, sourceDepth: NaN,
    waterDepth: NaN, x: NaN, y: NaN, z: NaN, volume: NaN, pressure: NaN,
    heading: NaN, speed: NaN, second: NaN, timeUtcUs: timeUs, fileNumber: fileNo,
    pointIndex: index)

proc viewOf(rows: varargs[Shot]): ShotView =
  result.rows = @rows

proc qTime(us: int64; exact = true; fileNo: Option[int64] = none(int64);
    line = NaN; point = NaN; index = 0; window: Slice[int64] = 0'i64 .. 0'i64): ShotQuery =
  ShotQuery(timeUs: some(us), timeExact: exact, windowUs: window, fileNumber: fileNo,
    line: line, point: point, pointIndex: index)

proc qNums(fileNo: Option[int64] = none(int64); line = NaN; point = NaN; index = 0): ShotQuery =
  ShotQuery(windowUs: 0'i64 .. 0'i64, fileNumber: fileNo, line: line, point: point,
    pointIndex: index)

proc expect(m: ShotMatch; rule: MatchRule; at, count: int; what: string) =
  doAssert m.rule == rule and m.row == at and m.count == count,
    what & ": " & $m.rule & " row " & $m.row & " count " & $m.count

proc main*() =
  const
    T = 1_700_000_000_000_000'i64
    Sec = 1_000_000'i64

  block sameInstant:
    let ix = buildShotIndex(viewOf(
      row(some(T), some(2'i64)),
      row(some(T), some(1'i64))))
    expect(match(ix, qTime(T), 0), mrTime, -1, 2, "two rows at one instant")
    expect(match(ix, qTime(T, fileNo = some(1'i64)), 0), mrTimeAndNumbers, 1, 1,
      "same instant narrowed")
    let reversed = buildShotIndex(viewOf(row(some(T + Sec)), row(some(T))))
    expect(match(reversed, qTime(T)), mrTime, 1, 1, "later row listed first")

  block emptyLog:
    let ix = buildShotIndex(viewOf())
    expect(match(ix, qTime(T)), mrNone, -1, 0, "empty exact")
    expect(match(ix, qTime(T, exact = false)), mrNone, -1, 0, "empty second")
    expect(match(ix, qNums(some(1'i64), 10, 20)), mrNone, -1, 0, "empty numbers")
    expect(match(ix, qTime(high(int64), window = -1000'i64 .. 1000'i64)), mrNone, -1, 0,
      "empty extreme")

  block eachRule:
    let ix = buildShotIndex(viewOf(
      row(some(T), some(1'i64), 10, 20, some(1'i64)),
      row(some(T + 10 * Sec), some(2'i64), 10, 21, some(1'i64))))
    expect(match(ix, qTime(T + 400)), mrTime, 0, 1, "one exact")
    expect(match(ix, qTime(T + 400_000, exact = false)), mrSecond, 0, 1, "one second")
    expect(match(ix, qNums(some(2'i64))), mrNumbers, 1, 1, "one file number")
    expect(match(ix, qNums(line = 10, point = 21, index = 1)), mrNumbers, 1, 1, "one station")

  block samePointApartByTime:
    let ix = buildShotIndex(viewOf(
      row(some(T + 50_000), some(7'i64), 100.5, 200.25, some(1'i64)),
      row(some(T + 80_000_000), some(8'i64), 100.5, 200.25, some(1'i64))))
    expect(match(ix, qTime(T + 50_000, fileNo = some(8'i64), line = 100.5, point = 200.25,
      index = 1)), mrTime, 0, 1, "time wins over the other file")
    expect(match(ix, qTime(T + 80_000_000, line = 100.5, point = 200.25)), mrTime, 1, 1,
      "the later shot")
    expect(match(ix, qNums(line = 100.5, point = 200.25, index = 1)), mrNumbers, -1, 2,
      "same point, no time")

  block twoWithinTolerance:
    let ix = buildShotIndex(viewOf(
      row(some(T), some(1'i64), 10, 1),
      row(some(T + 500), some(2'i64), 10, 2)))
    expect(match(ix, qTime(T)), mrTime, -1, 2, "500 us apart")
    expect(match(ix, qTime(T, fileNo = some(2'i64))), mrTimeAndNumbers, 1, 1, "narrowed by file")
    expect(match(ix, qTime(T, line = 10, point = 2)), mrTimeAndNumbers, 1, 1, "narrowed by station")
    expect(match(ix, qTime(T, fileNo = some(9'i64))), mrTime, -1, 2, "file matches neither")

  block wholeSecondTwoRows:
    let ix = buildShotIndex(viewOf(
      row(some(T), some(1'i64)),
      row(some(T + Sec - 1), some(2'i64)),
      row(some(T + Sec), some(3'i64))))
    expect(match(ix, qTime(T + 400_000, exact = false)), mrSecond, -1, 2, "two in the second")
    expect(match(ix, qTime(T + Sec, exact = false)), mrSecond, 2, 1, "the next second is one")
    expect(match(ix, qTime(T + 400_000, exact = false, fileNo = some(1'i64))),
      mrTimeAndNumbers, 0, 1, "second narrowed by file")

  block exactDoesNotWiden:
    let ix = buildShotIndex(viewOf(row(some(T)), row(some(T + 500_000))))
    expect(match(ix, qTime(T + 500_000)), mrTime, 1, 1, "exact stays on its row")
    expect(match(ix, qTime(T + 500_000, exact = false)), mrSecond, -1, 2, "the second holds both")
    expect(match(ix, qTime(T - 500, exact = false)), mrNone, -1, 0, "tolerance does not cross a second")

  block numberOnly:
    let ix = buildShotIndex(viewOf(
      row(some(T), some(4'i64), 30, 1, some(1'i64)),
      row(some(T + Sec), some(4'i64), 30, 1, some(2'i64)),
      row(some(T + 2 * Sec), some(5'i64), 30, 3, some(1'i64)),
      row(none(int64), some(6'i64), 40, 1),
      row(some(T + 3 * Sec), line = 50, point = 1, index = some(1'i64)),
      row(some(T + 4 * Sec), line = 50, point = 1, index = some(2'i64)),
      row(some(T + 5 * Sec), line = 60, point = 1, index = some(1'i64))))
    expect(match(ix, qNums(some(4'i64))), mrNumbers, -1, 2, "duplicated file")
    expect(match(ix, qNums(some(4'i64), 30, 1, 2)), mrNumbers, -1, 2,
      "duplicated file is not narrowed")
    expect(match(ix, qNums(some(5'i64))), mrNumbers, 2, 1, "unique file")
    expect(match(ix, qNums(some(5'i64), 30, 9)), mrNone, -1, 0, "unique file, station disagrees")
    expect(match(ix, qNums(some(9'i64), 60, 1)), mrNone, -1, 0, "missing file does not fall through")
    expect(match(ix, qNums(line = 30, point = 1)), mrNumbers, -1, 2, "duplicated shot point")
    expect(match(ix, qNums(line = 60, point = 1)), mrNumbers, 6, 1, "unique station")
    expect(match(ix, qNums(line = 50, point = 1, index = 2)), mrNumbers, 5, 1, "index picks one")
    expect(match(ix, qNums(line = 50, point = 1)), mrNumbers, -1, 2, "index 0 is any")
    expect(match(ix, qNums(line = 40, point = 1, index = 7)), mrNumbers, 3, 1,
      "stored index missing matches any")
    expect(match(ix, qNums(some(6'i64))), mrNumbers, 3, 1, "row without time")

  block timeMissesAKnownTime:
    let ix = buildShotIndex(viewOf(
      row(some(T), some(1'i64), 10, 1),
      row(none(int64), some(2'i64), 10, 2),
      row(none(int64), some(3'i64)),
      row(none(int64), some(3'i64))))
    expect(match(ix, qTime(T + 50_000, fileNo = some(1'i64))), mrNone, -1, 0,
      "a known time that differs is not a match")
    expect(match(ix, qTime(T + 50_000, fileNo = some(2'i64))), mrNumbers, 1, 1,
      "no time hit, unique row whose time is missing")
    expect(match(ix, qTime(T + 50_000, fileNo = some(3'i64))), mrNone, -1, 0,
      "duplicated missing time is not a fallback")
    expect(match(ix, qTime(T + 2 * Sec, exact = false, fileNo = some(2'i64))), mrNumbers, 1, 1,
      "a missed second falls through the same way")

  block toleranceEdges:
    let ix = buildShotIndex(viewOf(
      row(some(T - 1000)),
      row(some(T - 1001)),
      row(some(T + 1000)),
      row(some(T + 1001))))
    expect(match(ix, qTime(T, fileNo = some(1'i64))), mrTime, -1, 2, "both edges, before narrowing")
    let low = buildShotIndex(viewOf(row(some(T - 1000), some(1'i64))))
    expect(match(low, qTime(T)), mrTime, 0, 1, "exactly 1000 us early")
    let past = buildShotIndex(viewOf(row(some(T - 1001), some(1'i64))))
    expect(match(past, qTime(T)), mrNone, -1, 0, "one microsecond further early")
    let high = buildShotIndex(viewOf(row(some(T + 1000), some(1'i64))))
    expect(match(high, qTime(T)), mrTime, 0, 1, "exactly 1000 us late")
    let later = buildShotIndex(viewOf(row(some(T + 1001), some(1'i64))))
    expect(match(later, qTime(T)), mrNone, -1, 0, "one microsecond past")
    expect(match(high, qTime(T), 0), mrNone, -1, 0, "zero tolerance misses a neighbour")
    expect(match(buildShotIndex(viewOf(row(some(T)))), qTime(T), 0), mrTime, 0, 1, "zero tolerance exact")

  block windowPlusTolerance:
    let ix = buildShotIndex(viewOf(
      row(some(T + 90)),
      row(some(T + 89)),
      row(some(T + 210)),
      row(some(T + 211))))
    let w = 100'i64 .. 200'i64
    expect(match(ix, qTime(T, window = w), 10), mrTime, -1, 2, "window edges")
    expect(match(buildShotIndex(viewOf(row(some(T + 89)))), qTime(T, window = w), 10),
      mrNone, -1, 0, "one us before the widened window")
    expect(match(buildShotIndex(viewOf(row(some(T + 211)))), qTime(T, window = w), 10),
      mrNone, -1, 0, "one us after the widened window")

  block loneStartWindow:
    let ns = T * 1000
    let start = queryOfSweep(ns, true, 0, 0, 0, 0)
    doAssert start.timeExact == false
    doAssert start.timeUs.get == T
    doAssert start.windowUs.a == 200_000 and start.windowUs.b == 1_500_000
    doAssert start.fileNumber.isNone and start.line.isNaN and start.point.isNaN
    doAssert start.pointIndex == 0
    let one = buildShotIndex(viewOf(row(some(T + 1_200_000), some(9'i64), 3, 4)))
    expect(match(one, start), mrSecond, 0, 1, "one row in the start window, next second")
    expect(match(buildShotIndex(viewOf(row(some(T + 200_000)))), start), mrSecond, 0, 1,
      "window start included")
    expect(match(buildShotIndex(viewOf(row(some(T + 1_500_000)))), start), mrSecond, 0, 1,
      "window end included")
    expect(match(buildShotIndex(viewOf(row(some(T + 199_000)))), start), mrNone, -1, 0,
      "inside a tolerance of the window, still out")
    expect(match(buildShotIndex(viewOf(row(some(T + 100_000)))), start), mrNone, -1, 0,
      "in the start second but before 0.2 s")
    expect(match(buildShotIndex(viewOf(row(some(T + 1_501_000)))), start), mrNone, -1, 0,
      "one us past 1.5 s")
    let two = buildShotIndex(viewOf(
      row(some(T + 300_000), some(1'i64)),
      row(some(T + 1_400_000), some(2'i64))))
    expect(match(two, queryOfSweep(ns, true, 0, 0, 0, 0)), mrSecond, -1, 2, "two in the window")
    expect(match(two, queryOfSweep(ns, true, 2, 0, 0, 0)), mrTimeAndNumbers, 1, 1,
      "start window narrowed by file")
    let exact = queryOfSweep(ns + 2_500_000, false, 12, 10, 20, 3)
    doAssert exact.timeExact and exact.timeUs.get == T + 2_500
    doAssert exact.fileNumber.get == 12 and exact.line == 10 and exact.point == 20
    doAssert exact.pointIndex == 3 and exact.windowUs.a == 0 and exact.windowUs.b == 0
    let given = queryOfSweep(ns, false, -1, 0, 20, 0)
    doAssert given.fileNumber.isNone and given.line.isNaN and given.point.isNaN

  block helpers:
    let q = queryOfKeys(some(T + 20), true, 42.0, 10.0, NaN, 0)
    doAssert q.timeUs.get == T + 20 and q.timeExact and q.fileNumber.get == 42
    doAssert q.line == 10.0 and q.point.isNaN and q.pointIndex == 0
    let noneTime = queryOfKeys(none(int64), false, NaN, NaN, NaN, 0)
    doAssert noneTime.timeUs.isNone and noneTime.fileNumber.isNone
    let key = stationKey(10.006, 20.004, 1'i16)
    let ix = buildShotIndex(viewOf(row(none(int64), line = 10.006, point = 20.004, index = some(1'i64))))
    expect(match(ix, qNums(line = key.line, point = key.point, index = 1)), mrNumbers, 0, 1,
      "stationKey rounding")
    expect(match(ix, qNums(line = 10.004, point = 20.004)), mrNone, -1, 0, "a hundredth away")

  block negativeSecond:
    let ix = buildShotIndex(viewOf(
      row(some(-2_000_000'i64)),
      row(some(-1_000_001'i64)),
      row(some(-1_000_000'i64))))
    expect(match(ix, qTime(-1_500_000, exact = false)), mrSecond, -1, 2, "negative second holds two")
    expect(match(ix, qTime(-1_000_000, exact = false)), mrSecond, 2, 1, "the boundary is the next second")

  block int64Extremes:
    let hiStart = 9_223_372_036_854_000_000'i64
    let ix = buildShotIndex(viewOf(
      row(some(low(int64))),
      row(some(high(int64))),
      row(some(hiStart - 1)),
      row(some(hiStart))))
    expect(match(ix, qTime(high(int64))), mrTime, 1, 1, "high exact")
    expect(match(ix, qTime(low(int64))), mrTime, 0, 1, "low exact")
    expect(match(ix, qTime(high(int64) - 500)), mrTime, 1, 1, "within tolerance of high")
    expect(match(ix, qTime(high(int64) - 1001)), mrNone, -1, 0, "1001 us from high is past")
    expect(match(ix, qTime(low(int64), exact = false)), mrSecond, 0, 1, "low second")
    expect(match(ix, qTime(high(int64), exact = false)), mrSecond, -1, 2, "high second holds its start")
    expect(match(ix, qTime(hiStart - 1, exact = false)), mrSecond, 2, 1, "the second before high")
    expect(match(ix, qTime(high(int64) - 100, window = 0'i64 .. 1000'i64)), mrTime, 1, 1,
      "window saturates at high")
    expect(match(ix, qTime(low(int64) + 100, window = -1000'i64 .. 0'i64)), mrTime, 0, 1,
      "window saturates at low")
    let sweep = queryOfSweep(high(int64), true, 1, 1, 1, 1)
    expect(match(ix, sweep), mrNone, -1, 0, "start window at high does not raise")
    expect(match(ix, queryOfSweep(low(int64), false, 0, 0, 0, 0)), mrNone, -1, 0,
      "nanoseconds at low do not wrap onto low")
    expect(match(buildShotIndex(viewOf()), qTime(low(int64), window = low(int64) .. high(int64),
      fileNo = some(low(int64)))), mrNone, -1, 0, "full-range window on an empty log")

  block windowPastEnds:
    let atHigh = buildShotIndex(viewOf(row(some(high(int64)))))
    expect(match(atHigh, qTime(high(int64), window = 1'i64 .. 1'i64), 0), mrNone, -1, 0,
      "window 1 past high is empty")
    let atLow = buildShotIndex(viewOf(row(some(low(int64)))))
    expect(match(atLow, qTime(low(int64), window = -1'i64 .. -1'i64), 0), mrNone, -1, 0,
      "window 1 before low is empty")
    let nearHigh = buildShotIndex(viewOf(row(some(high(int64) - 2))))
    expect(match(nearHigh, qTime(high(int64) - 1, window = 2'i64 .. 2'i64), 2), mrNone, -1, 0,
      "tolerance after a clamped add must not widen")
    expect(match(atHigh, qTime(high(int64), exact = false, window = 1'i64 .. 5'i64)),
      mrNone, -1, 0, "non-exact window past high is not the endpoint")

  block manyRows:
    const N = 100_000
    var rows = newSeq[Shot](N)
    for i in 0 ..< N:
      rows[i] = row(some(int64(i) * 10_000), some(int64(i) + 1), 1.0, float64(i))
    let ix = buildShotIndex(ShotView(rows: rows))
    discard match(ix, qTime(0))
    let before = allocations()
    let t0 = getMonoTime()
    for i in 0 ..< N:
      let m = match(ix, qTime(int64(i) * 10_000, fileNo = some(int64(i) + 1)))
      doAssert m.row == i and m.count == 1 and m.rule == mrTime
    let us = (getMonoTime() - t0).inMicroseconds
    let made = allocations() - before
    echo "tshotfollow: ", N, " matches in ", us, " us, allocations ", made
    doAssert made == 0, $made & " allocations in match"
    doAssert us < 30_000_000, "matches took " & $us & " us"
    let a0 = allocations()
    for i in 0 ..< N:
      let m = match(ix, qNums(some(int64(i) + 1)))
      doAssert m.row == i and m.rule == mrNumbers
    doAssert allocations() - a0 == 0, "file-number match allocated"

  echo "tshotfollow ok"

when isMainModule:
  main()
