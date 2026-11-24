## A shot log's source points written as SPS and read back.
##
## Seen to fail: with the decimal exactness check taken out of `fixedFits`,
## an easting of 10.25 is written as 10.2 instead of reported and skipped.

import std/[math, options, os, strutils]
import parseSEG
import viewSEG/core/[shotlog, shotlogsps]

const
  UtcMarch = 1_709_251_200_000_000'i64
  UtcFeb29 = 1_709_164_800_000_000'i64
  UtcDec31 = 1_735_603_200_000_000'i64
  UtcJan1 = 1_735_689_600_000_000'i64
  Root = currentSourcePath().parentDir.parentDir

proc viewOf(text: string; roles: openArray[ColumnRole]; clock = tcUtc;
    sentinels = true): ShotView =
  var m = initShotLogMap()
  m.hasHeader = true
  m.clock = clock
  m.roles = @roles
  if not sentinels: m.sentinels.setLen(0)
  shots(parseShotLog(text, m), m)

proc options(rev = sps21; time = false; line = NaN; index = 1; code = ""): ShotSpsOptions =
  result = initShotSpsOptions()
  result.revision = rev
  result.withTime = time
  result.defaultLine = line
  result.defaultIndex = index
  result.pointCode = code

proc same(a, b: float64): bool =
  if a.isNaN: b.isNaN else: a == b

proc nameOf(v: float64; rev: SpsRevision): string =
  if rev == sps21: formatFloat(v, ffDecimal, 2)
  elif v == round(v) and abs(v) < 1e15: $int64(v)
  else: $v

proc checkPoint(got: SpsPoint; rev: SpsRevision; line, point: float64; index: int;
    code: string; depth, water, east, north, elev: float64;
    day, hour, minute, second: int) =
  doAssert got.kind == pkSource
  doAssert same(got.line, line), $got.line & " != " & $line
  doAssert same(got.point, point)
  doAssert got.index == index
  doAssert got.code == code
  doAssert same(got.staticCorrection, NaN)
  doAssert same(got.pointDepth, depth), $got.pointDepth
  doAssert same(got.seismicDatum, NaN)
  doAssert same(got.upholeTime, NaN)
  doAssert same(got.waterDepth, water), $got.waterDepth
  doAssert same(got.easting, east)
  doAssert same(got.northing, north)
  doAssert same(got.elevation, elev), $got.elevation
  doAssert got.dayOfYear == day, $got.dayOfYear
  doAssert got.hour == hour
  doAssert got.minute == minute
  doAssert got.second == second
  doAssert got.raw.len == 80
  doAssert got.raw[0] == 'S'
  doAssert got.lineName == nameOf(line, rev), got.lineName
  doAssert got.pointName == nameOf(point, rev), got.pointName
  var expect = initSpsPoint(pkSource)
  expect.line = line
  expect.point = point
  expect.index = index
  expect.code = code
  if not depth.isNaN: expect.pointDepth = depth
  if not water.isNaN: expect.waterDepth = water
  expect.easting = east
  expect.northing = north
  if not elev.isNaN: expect.elevation = elev
  expect.dayOfYear = day
  expect.hour = hour
  expect.minute = minute
  expect.second = second
  doAssert got.raw == encodeSps(expect, rev)

proc readBack(text: string; rev: SpsRevision): SpsFile =
  result = parseSps(text, opts = SpsOptions(revision: rev))
  doAssert not result.log.hasErrors, $result.log

proc hasProblem(r: ShotSpsResult; row: int; field, value: string): bool =
  for p in r.problems:
    if p.row == row and p.field == field and p.value == value: return true
  false

proc main*() =
  block defaults:
    let o = initShotSpsOptions()
    doAssert o.revision == sps21 and o.defaultLine.isNaN
    doAssert o.defaultIndex == 1 and o.pointCode.len == 0 and not o.withTime
    let bare = toSps(viewOf("point\n", [crShotPoint]), ShotSpsOptions())
    doAssert bare.written == 0 and bare.skipped == 0 and bare.text.len == 0
    doAssert bare.error.len == 0
    doAssert hasProblem(bare, -1, "revision", "auto")

  block oneRow:
    let text = "point,line,x,y,z,depth,water,index\n1000,10,1000,2000,12,6,40,1\n"
    let roles = [crShotPoint, crSourceLine, crX, crY, crZ, crSourceDepth,
      crWaterDepth, crPointIndex]
    let view = viewOf(text, roles)
    doAssert view.rows.len == 1
    for rev in [sps21, sps10]:
      let made = toSps(view, options(rev, code = "V1"))
      doAssert made.error.len == 0
      doAssert made.written == 1 and made.skipped == 0 and made.duplicates == 0
      doAssert made.count == 0 and made.problems.len == 0
      doAssert made.fractionDropped == 0 and not made.yearChanged
      doAssert made.firstYear.isNone and made.lastYear.isNone
      doAssert made.file.revision == rev and made.file.points.len == 1
      let back = readBack(made.text, rev)
      doAssert back.revision == rev and back.points.len == 1
      checkPoint(back.points[0], rev, 10, 1000, 1, "V1", 6, 40, 1000, 2000, 12,
        -1, -1, -1, -1)
      doAssert made.written + made.skipped == view.rows.len

  block noTimeBlankElevation:
    let text = "point,line,x,y,z\n10.5,3,1.5,2.5,\n"
    let view = viewOf(text, [crShotPoint, crSourceLine, crX, crY, crZ])
    let made = toSps(view, options(sps10))
    doAssert made.written == 1 and made.skipped == 0
    let p = readBack(made.text, sps10).points[0]
    checkPoint(p, sps10, 3, 10.5, 1, "", NaN, NaN, 1.5, 2.5, NaN, -1, -1, -1, -1)
    doAssert p.elevation.isNaN and p.pointDepth.isNaN and p.waterDepth.isNaN

  block skippedShotPoint:
    let text = "point,line,x,y\n,-999.9,1,2\n1000,10,1,2\n"
    let view = viewOf(text, [crShotPoint, crSourceLine, crX, crY])
    doAssert view.rows[0].shotPoint.isNaN
    let made = toSps(view, options())
    doAssert made.written == 1 and made.skipped == 1 and made.count == 0
    doAssert readBack(made.text, sps21).points[0].point == 1000

  block nanCoordinate:
    let text = "point,line,x,y,z\n1,10,,2,3\n2,10,1,,3\n3,10,1,2,3\n"
    let view = viewOf(text, [crShotPoint, crSourceLine, crX, crY, crZ])
    let made = toSps(view, options())
    doAssert made.written == 1 and made.skipped == 2
    doAssert hasProblem(made, 0, "easting", "nan")
    doAssert hasProblem(made, 1, "northing", "nan")
    doAssert readBack(made.text, sps21).points[0].point == 3

  block doesNotFit:
    let text = "point,line,x,y,z,depth,water\n" &
      "10.256,10,1,2,3,6,40\n" &
      "10,10,10.25,2,3,6,40\n" &
      "10,10000000,1,2,3,6,40\n" &
      "10,10,1,2,10000,6,40\n" &
      "10,10,1,2,3,100,40\n" &
      "10,10,1,2,3,6,1\n"
    let roles = [crShotPoint, crSourceLine, crX, crY, crZ, crSourceDepth, crWaterDepth]
    let view = viewOf(text, roles)
    let made = toSps(view, options(sps21))
    doAssert made.written == 1 and made.skipped == 5
    doAssert hasProblem(made, 0, "point", "10.256")
    doAssert hasProblem(made, 1, "easting", "10.25")
    doAssert hasProblem(made, 2, "line", "10000000.0")
    doAssert hasProblem(made, 3, "elevation", "10000.0")
    doAssert hasProblem(made, 4, "pointDepth", "100.0")
    let back = readBack(made.text, sps21)
    doAssert back.points.len == 1
    checkPoint(back.points[0], sps21, 10, 10, 1, "", 6, 1, 1, 2, 3, -1, -1, -1, -1)

  block bounds:
    let text = "point,line,x,y,z,depth,water\n" &
      "9999999.99,9999999.99,9999999.9,99999999.9,9999.9,99.9,9999.9\n" &
      "-999999.99,-999999.99,-999999.9,-9999999.9,-999.9,-9.9,-999.9\n"
    let roles = [crShotPoint, crSourceLine, crX, crY, crZ, crSourceDepth, crWaterDepth]
    let view = viewOf(text, roles, sentinels = false)
    let made = toSps(view, options(sps21))
    doAssert made.written == 2 and made.skipped == 0 and made.count == 0, $made.problems
    let back = readBack(made.text, sps21)
    checkPoint(back.points[0], sps21, 9999999.99, 9999999.99, 1, "", 99.9, 9999.9,
      9999999.9, 99999999.9, 9999.9, -1, -1, -1, -1)
    checkPoint(back.points[1], sps21, -999999.99, -999999.99, 1, "", -9.9, -999.9,
      -999999.9, -9999999.9, -999.9, -1, -1, -1, -1)
    let over = viewOf("point,line,x,y\n10000000,-1000000,1,2\n",
      [crShotPoint, crSourceLine, crX, crY])
    let bad = toSps(over, options(sps21))
    doAssert bad.written == 0 and hasProblem(bad, 0, "point", "10000000.0")
    doAssert hasProblem(bad, 0, "line", "-1000000.0")

  block revision10:
    let text = "point,line,x,y,z,depth,water\n" &
      "12345678,-999999999999999,1,2,3,6,999\n" &
      "123456789,10,1,2,3,6,10000\n" &
      "10.5,10,1,2,3,6,40\n"
    let roles = [crShotPoint, crSourceLine, crX, crY, crZ, crSourceDepth, crWaterDepth]
    let view = viewOf(text, roles)
    let made = toSps(view, options(sps10))
    doAssert made.written == 2 and made.skipped == 1, $made.problems
    doAssert hasProblem(made, 1, "point", "123456789.0")
    doAssert hasProblem(made, 1, "waterDepth", "10000.0")
    let back = readBack(made.text, sps10)
    doAssert back.points.len == 2
    checkPoint(back.points[0], sps10, -999999999999999.0, 12345678, 1, "", 6, 999,
      1, 2, 3, -1, -1, -1, -1)
    checkPoint(back.points[1], sps10, 10, 10.5, 1, "", 6, 40, 1, 2, 3, -1, -1, -1, -1)

  block defaultLineAndIndex:
    let text = "point,line,x,y,index\n5,,1,2,\n6,4,1,2,2\n7,,1,2,\n"
    let view = viewOf(text, [crShotPoint, crSourceLine, crX, crY, crPointIndex])
    doAssert view.rows[0].sourceLine.isNaN and view.rows[0].pointIndex.isNone
    let made = toSps(view, options(line = 8))
    doAssert made.written == 3 and made.count == 0, $made.problems
    let back = readBack(made.text, sps21)
    doAssert back.points[0].line == 8 and back.points[0].index == 1
    doAssert back.points[1].line == 4 and back.points[1].index == 2
    doAssert back.points[2].line == 8 and back.points[2].index == 1
    let none = toSps(view, options())
    doAssert none.written == 1 and hasProblem(none, 0, "line", "nan")
    doAssert hasProblem(none, 2, "line", "nan")

  block badIndexAndCode:
    let text = "point,line,x,y,index\n1,10,1,2,10\n2,10,1,2,\n"
    let view = viewOf(text, [crShotPoint, crSourceLine, crX, crY, crPointIndex])
    let made = toSps(view, options(index = 15))
    doAssert made.written == 0 and made.skipped == 2
    doAssert hasProblem(made, 0, "index", "10")
    doAssert hasProblem(made, 1, "index", "15")
    let coded = toSps(view, options(code = "ABC"))
    doAssert coded.written == 0 and coded.skipped == 2 and coded.text.len == 0
    doAssert hasProblem(coded, -1, "pointCode", "ABC")
    doAssert coded.file.points.len == 0

  block duplicates:
    let text = "point,line,x,y,index\n1,10,1,2,1\n1,10,3,4,1\n1,10,5,6,2\n1,10,7,8,1\n"
    let view = viewOf(text, [crShotPoint, crSourceLine, crX, crY, crPointIndex])
    let made = toSps(view, options())
    doAssert made.written == 4 and made.duplicates == 2 and made.skipped == 0
    let back = readBack(made.text, sps21)
    doAssert back.points.len == 4
    doAssert back.points[0].easting == 1 and back.points[1].easting == 3
    doAssert back.points[2].index == 2 and back.points[3].easting == 7

  block time:
    let head = "point,line,x,y,utc\n"
    let roles = [crShotPoint, crSourceLine, crX, crY, crUtcMicros]
    proc row(point: int; us: int64): string =
      $point & ",10,1,2," & $us & "\n"
    let before = viewOf(head & row(1, UtcMarch - 1), roles)
    let early = toSps(before, options(time = true))
    doAssert early.written == 1 and early.fractionDropped == 1
    doAssert early.firstYear == some(2024) and early.lastYear == some(2024)
    doAssert not early.yearChanged
    checkPoint(readBack(early.text, sps21).points[0], sps21, 10, 1, 1, "", NaN, NaN,
      1, 2, NaN, 60, 23, 59, 59)
    let at = toSps(viewOf(head & row(1, UtcMarch), roles), options(time = true))
    doAssert at.fractionDropped == 0 and at.firstYear == some(2024)
    checkPoint(readBack(at.text, sps21).points[0], sps21, 10, 1, 1, "", NaN, NaN,
      1, 2, NaN, 61, 0, 0, 0)
    let after = toSps(viewOf(head & row(1, UtcMarch + 1), roles), options(time = true))
    doAssert after.fractionDropped == 1
    checkPoint(readBack(after.text, sps21).points[0], sps21, 10, 1, 1, "", NaN, NaN,
      1, 2, NaN, 61, 0, 0, 0)
    let leap = toSps(viewOf(head & row(1, UtcFeb29), roles), options(time = true))
    checkPoint(readBack(leap.text, sps21).points[0], sps21, 10, 1, 1, "", NaN, NaN,
      1, 2, NaN, 60, 0, 0, 0)
    doAssert leap.firstYear == some(2024)
    let last = toSps(viewOf(head & row(1, UtcDec31), roles), options(time = true))
    checkPoint(readBack(last.text, sps21).points[0], sps21, 10, 1, 1, "", NaN, NaN,
      1, 2, NaN, 366, 0, 0, 0)
    let span = viewOf(head & row(1, UtcDec31) & row(2, UtcJan1), roles)
    let years = toSps(span, options(time = true))
    doAssert years.written == 2 and years.yearChanged
    doAssert years.firstYear == some(2024) and years.lastYear == some(2025)
    let back = readBack(years.text, sps21)
    doAssert back.points[0].dayOfYear == 366 and back.points[1].dayOfYear == 1
    doAssert back.points[1].hour == 0 and back.points[1].second == 0
    let flip = viewOf(head & row(1, UtcJan1) & row(2, UtcDec31) & row(3, UtcJan1), roles)
    let flipped = toSps(flip, options(time = true))
    doAssert flipped.yearChanged
    doAssert flipped.firstYear == some(2025) and flipped.lastYear == some(2025)
    let quiet = toSps(before, options(time = false))
    doAssert quiet.fractionDropped == 0 and quiet.firstYear.isNone and not quiet.yearChanged
    checkPoint(readBack(quiet.text, sps21).points[0], sps21, 10, 1, 1, "", NaN, NaN,
      1, 2, NaN, -1, -1, -1, -1)
    let epoch = toSps(viewOf(head & row(1, 0), roles), options(time = true))
    checkPoint(readBack(epoch.text, sps21).points[0], sps21, 10, 1, 1, "", NaN, NaN,
      1, 2, NaN, 1, 0, 0, 0)
    doAssert epoch.firstYear == some(1970)
    let neg = toSps(viewOf(head & row(1, -1), roles), options(time = true))
    doAssert neg.fractionDropped == 1 and neg.firstYear == some(1969)
    checkPoint(readBack(neg.text, sps21).points[0], sps21, 10, 1, 1, "", NaN, NaN,
      1, 2, NaN, 365, 23, 59, 59)

  block fractionOnSkipped:
    let text = "point,line,x,y,utc\n,10,1,2," & $(UtcMarch + 1) & "\n"
    let view = viewOf(text, [crShotPoint, crSourceLine, crX, crY, crUtcMicros])
    let made = toSps(view, options(time = true))
    doAssert made.written == 0 and made.skipped == 1 and made.fractionDropped == 1
    doAssert made.firstYear.isNone

  block cap:
    var text = "point,line,x,y\n"
    for i in 0 .. ProblemCap:
      text.add $i & ",10,10.25,2\n"
    let view = viewOf(text, [crShotPoint, crSourceLine, crX, crY])
    let made = toSps(view, options())
    doAssert made.written == 0 and made.skipped == ProblemCap + 1
    doAssert made.problems.len == ProblemCap and made.count == ProblemCap + 1
    doAssert made.problems[0].row == 0 and made.problems[0].field == "easting"
    doAssert made.problems[^1].row == ProblemCap - 1

  block bothRevisionsTime:
    let text = "point,line,x,y,utc\n4,8,1,2," & $UtcMarch & "\n"
    let view = viewOf(text, [crShotPoint, crSourceLine, crX, crY, crUtcMicros])
    for rev in [sps10, sps21]:
      let made = toSps(view, options(rev, time = true, code = "A"))
      let back = readBack(made.text, rev)
      doAssert back.revision == rev
      checkPoint(back.points[0], rev, 8, 4, 1, "A", NaN, NaN, 1, 2, NaN, 61, 0, 0, 0)

  block sampleRoundTrip:
    let path = Root / "samples" / "land" / "shotlog.csv"
    doAssert fileExists(path), path
    let roles = [
      crSequence, crFileNumber, crSourceLine, crShotPoint, crPointIndex, crGpsMicros,
      crIgnored, crIgnored, crIgnored, crIgnored, crIgnored, crIgnored,
      crSourceDepth, crWaterDepth, crX, crY, crZ, crSourceType,
      crVolume, crPressure, crHeading, crSpeed]
    let view = viewOf(readFile(path), roles, tcGps)
    doAssert view.rows.len == 200
    doAssert view.rows[0].timeUtcUs == some(UtcMarch)
    doAssert view.rows[3].sourceDepth.isNaN and view.rows[5].waterDepth.isNaN
    for rev in [sps21, sps10]:
      let made = toSps(view, options(rev, time = true))
      doAssert made.written == 200 and made.skipped == 0 and made.duplicates == 0, $made.problems
      doAssert made.count == 0 and made.fractionDropped == 0 and not made.yearChanged
      doAssert made.firstYear == some(2024) and made.lastYear == some(2024)
      let back = readBack(made.text, rev)
      doAssert back.points.len == 200
      for i, row in view.rows:
        let sec = i * 10
        checkPoint(back.points[i], rev, row.sourceLine, row.shotPoint, 1, "",
          row.sourceDepth, row.waterDepth, row.x, row.y, row.z,
          61, 0, sec div 60, sec mod 60)

  block writeFile:
    let dir = getTempDir() / ("shotlogsps-" & $getCurrentProcessId())
    createDir(dir)
    let text = "point,line,x,y,z,depth,water\n1000,10,1000,2000,12,6,40\n"
    let roles = [crShotPoint, crSourceLine, crX, crY, crZ, crSourceDepth, crWaterDepth]
    let view = viewOf(text, roles)
    let path = dir / "out.sps"
    let wrote = writeShotSps(view, options(code = "V1"), path)
    doAssert wrote.error.len == 0, wrote.error
    doAssert fileExists(path)
    let back = readSps(path, SpsOptions(revision: sps21))
    doAssert not back.log.hasErrors
    doAssert back.points.len == 1
    checkPoint(back.points[0], sps21, 10, 1000, 1, "V1", 6, 40, 1000, 2000, 12,
      -1, -1, -1, -1)
    doAssert readFile(path) == wrote.text
    let again = writeShotSps(view, options(), path)
    doAssert again.error.len == 0
    doAssert readSps(path).points[0].code.len == 0
    let blocked = dir / "blocked"
    writeFile(blocked, "keep")
    let failed = writeShotSps(view, options(), blocked / "out.sps")
    doAssert failed.error.len > 0
    doAssert readFile(blocked) == "keep"
    doAssert not dirExists(blocked)
    let onto = writeShotSps(view, options(), dir)
    doAssert onto.error.len > 0
    doAssert dirExists(dir)
    doAssert not fileExists(dir & "." & $getCurrentProcessId() & ".tmp")
    doAssert not fileExists(path & "." & $getCurrentProcessId() & ".tmp")
    discard tryRemoveFile(path)
    discard tryRemoveFile(blocked)
    try: removeDir(dir)
    except OSError: discard

  echo "tshotlogsps ok"

when isMainModule:
  main()
