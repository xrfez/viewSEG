## A shot log kept as one text plus a field index, a column map, one UTC
## instant per row, and cell overlays that do not rewrite the text.
##
## Seen to fail: with the doubled-quote collapse taken out of `unquoteRange`,
## `quotedFields` still sees two quotes. With `abs(diff) > DisagreeUs` inverted,
## `crossCheck` flags a row whose sources agree. With `toText` appending a
## space when nothing changed, `quotedFields` is no longer byte-identical.
## With the digit check in `parseWhole` left as `v > high(int64) div 10`,
## `overflowAndYearRange` raises OverflowDefect on 9223372036854775808.
## With the length guard in `parseShotLog` lowered to 8 bytes and then
## taken out, a 20-byte text was indexed instead of refused with
## `pkTooLong`. With the fraction left replaced by the microsecond
## column, `fractionAndMicros` keeps 59.000000 and reports no problem.
## With the year column stored as parsed, `yearColumnPivot` keeps 16.
## With no decimal-comma reading, `decimalComma` leaves `1,5` unparsed.

import std/[math, options, os, strutils]
import viewSEG/core/shotlog

const
  UtcMarch = 1_709_251_200_000_000'i64   ## 2024-03-01 00:00:00 UTC
  GpsMarch = 1_393_286_418_000_000'i64   ## GPS microseconds of that instant
  UtcFeb29 = 1_709_164_800_000_000'i64   ## 2024-02-29 00:00:00 UTC
  UtcDec31 = 1_735_603_200_000_000'i64   ## 2024-12-31 00:00:00 UTC
  UtcJan1 = 1_735_689_600_000_000'i64    ## 2025-01-01 00:00:00 UTC
  Utc2023Mar = 1_677_628_800_000_000'i64 ## 2023-03-01, doy 60 of a common year
  DayUs = 86_400_000_000'i64

proc mapOf(roles: openArray[ColumnRole]; d = dlComma; header = true): ShotLogMap =
  result = initShotLogMap()
  result.delimiter = d
  result.hasHeader = header
  result.roles = @roles

proc read(text: string; roles: openArray[ColumnRole]; d = dlComma; header = true;
    clock = tcUtc; skip = 0): ShotView =
  var m = mapOf(roles, d, header)
  m.clock = clock
  m.skipLines = skip
  shots(parseShotLog(text, m), m)

proc kindText(p: ProblemList; k: ProblemKind): string =
  for it in p.items:
    if it.kind == k: return it.text
  ""

proc hasKind(p: ProblemList; k: ProblemKind): bool =
  kindText(p, k).len > 0

proc main*() =
  block plainWords:
    doAssert label(crFileNumber) == "file number"
    doAssert $crGpsMicros == "GPS microseconds"
    doAssert $crPointIndex == "point index"
    doAssert $crDateTime == "date-time text"
    let m = initShotLogMap()
    doAssert m.delimiter == dlComma and m.hasHeader and m.clock == tcUtc
    doAssert m.lengthUnit == luMetres and m.sentinels.len > 0

  block quotedFields:
    let raw = "name,note\r\na,\"hello, world\"\r\nb,\"say \"\"hi\"\"\"\r\n"
    let log = parseShotLog(raw, dlComma)
    doAssert log.len == 2 and log.width == 2
    doAssert log.cell(0, 1) == "hello, world"
    doAssert log.cell(1, 1) == "say \"hi\""
    doAssert log.toText == raw
    doAssert not log.changed

  block lineEndingsAndShape:
    let crlf = "a,b\r\n1,2\r\n"
    doAssert parseShotLog(crlf, dlComma).toText == crlf
    let short = parseShotLog("a,b\n1\n", dlComma)
    doAssert short.len == 1 and short.fields(0) == 1 and short.width == 2
    doAssert short.cell(0, 1) == ""
    doAssert short.problems.count == 1
    doAssert short.problems.items[0].kind == pkShortRow
    doAssert short.problems.items[0].row == 0
    let long = parseShotLog("a,b\n1,2,3\n", dlComma)
    doAssert long.len == 1 and long.fields(0) == 3 and long.cell(0, 2) == "3"
    doAssert long.problems.items[0].kind == pkLongRow
    let skipped = parseShotLog("note\nnote\na,b\n1,2\n", dlComma, skipLines = 2)
    doAssert skipped.len == 1 and skipped.cell(0, 0) == "1"
    doAssert parseShotLog("a,b\n\n1,2\n", dlComma).len == 1

  block otherDelimiters:
    let tab = parseShotLog("sequence\tshot point\tX\n4\t5\t6\n", dlTab)
    doAssert tab.len == 1 and tab.cell(0, 1) == "5" and tab.delimiter == dlTab
    let semi = parseShotLog("sequence;shot point;X\n4;5;6\n", dlSemicolon)
    doAssert semi.cell(0, 2) == "6"
    let spaces = parseShotLog("sequence shot X\n1    2   3\n", dlSpaces)
    doAssert spaces.width == 3 and spaces.cell(0, 0) == "1"
    doAssert spaces.cell(0, 1) == "2" and spaces.cell(0, 2) == "3"

  block sentinelsAndPadding:
    let v = read("x,sp,seq\n-999.9,-999,  0012\n", [crX, crShotPoint, crSequence])
    doAssert v.rows[0].x.isNaN and v.rows[0].shotPoint.isNaN
    doAssert v.rows[0].sequence.get == 12
    doAssert not hasKind(v.problems, pkBadNumber)
    let bad = read("sp\nabc\n", [crShotPoint])
    doAssert bad.rows[0].shotPoint.isNaN and hasKind(bad.problems, pkBadNumber)
    let padded = read("sp\n00100.50\n", [crShotPoint])
    doAssert padded.rows[0].shotPoint == 100.5

  block numberPrefixedHeader:
    let g = guessMap("07_shot_point,07-file number,Shot_Point\n1,2,3\n")
    doAssert g.hasHeader and g.skipLines == 0 and g.delimiter == dlComma
    doAssert g.roles[0] == crShotPoint and g.roles[1] == crFileNumber
    doAssert g.roles[2] == crShotPoint
    let feet = guessMap("source depth (ft),X\n6,10\n")
    doAssert feet.lengthUnit == luFeet and feet.roles[0] == crSourceDepth
    doAssert feet.roles[1] == crX
    var forced = initShotLogMap()
    forced.roles = @[crX, crY]
    let manual = shots(parseShotLog("a,b\n3,4\n", forced), forced)
    doAssert manual.rows[0].x == 3.0 and manual.rows[0].y == 4.0

  block noHeaderAndGuess:
    let text = $GpsMarch & ",2024,1.5\n" & $(GpsMarch + 10_000_000) & ",2024,2.5\n"
    let g = guessMap(text)
    doAssert not g.hasHeader and g.delimiter == dlComma
    doAssert g.roles[0] == crGpsMicros and g.roles[1] == crYear
    doAssert g.roles[2] == crText
    let v = shots(parseShotLog(text, g), g)
    doAssert v.rows[0].timeUtcUs.get == UtcMarch
    doAssert v.rows[0].year.get == 2024

  block eachTimeSource:
    doAssert toPosixSeconds(UtcMarch) == 1_709_251_200.0
    doAssert gpsMicrosToUtcMicros(0) == 315_964_800'i64 * 1_000_000
    doAssert gpsMicrosToUtcMicros(GpsMarch) == UtcMarch
    let gps = read($GpsMarch & "\n", [crGpsMicros], header = false)
    doAssert gps.rows[0].timeUtcUs.get == UtcMarch
    let us = read($UtcMarch & "\n", [crUtcMicros], header = false)
    doAssert us.rows[0].timeUtcUs.get == UtcMarch
    let sec = read("1709251200\n", [crUtcSeconds], header = false)
    doAssert sec.rows[0].timeUtcUs.get == UtcMarch
    let frac = read("1709251200.005\n", [crUtcSeconds], header = false)
    doAssert frac.rows[0].timeUtcUs.get == UtcMarch + 5_000
    let doy = read("2024,61,0,0,0\n",
      [crYear, crDayOfYear, crHour, crMinute, crSecond], header = false)
    doAssert doy.rows[0].timeUtcUs.get == UtcMarch
    let md = read("2024,3,1,0,0,0\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond], header = false)
    doAssert md.rows[0].timeUtcUs.get == UtcMarch
    let text = read("2024-03-01 00:00:00\n", [crDateTime], header = false)
    doAssert text.rows[0].timeUtcUs.get == UtcMarch
    let iso = read("2024-03-01T00:00:00Z\n", [crDateTime], header = false)
    doAssert iso.rows[0].timeUtcUs.get == UtcMarch
    let slash = read("2024/03/01 00:00:00.000000\n", [crDateTime], header = false)
    doAssert slash.rows[0].timeUtcUs.get == UtcMarch
    var custom = mapOf([crDateTime], header = false)
    custom.dateTimePattern = "yyyy/mm/dd hh:mm:ss"
    let used = shots(parseShotLog("2024/03/01 00:00:00\n", custom), custom)
    doAssert used.rows[0].timeUtcUs.get == UtcMarch
    let epoch = read("1980,1,6,0,0,0\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond], header = false)
    doAssert epoch.rows[0].timeUtcUs.get == 315_964_800'i64 * 1_000_000

  block leapDayAndFraction:
    let feb = read("2024,60,0,0,0\n",
      [crYear, crDayOfYear, crHour, crMinute, crSecond], header = false)
    doAssert feb.rows[0].timeUtcUs.get == UtcFeb29
    let yearEnd = read("2024,366,0,0,0\n2025,1,0,0,0\n",
      [crYear, crDayOfYear, crHour, crMinute, crSecond], header = false)
    doAssert yearEnd.rows[0].timeUtcUs.get == UtcDec31
    doAssert yearEnd.rows[1].timeUtcUs.get == UtcJan1
    doAssert yearEnd.rows[1].timeUtcUs.get - yearEnd.rows[0].timeUtcUs.get == DayUs
    let common = read("2023,60,0,0,0\n",
      [crYear, crDayOfYear, crHour, crMinute, crSecond], header = false)
    doAssert common.rows[0].timeUtcUs.get == Utc2023Mar
    let frac = read("2024,61,0,0,59.999999\n",
      [crYear, crDayOfYear, crHour, crMinute, crSecond], header = false)
    doAssert frac.rows[0].timeUtcUs.get == UtcMarch + 59_999999
    doAssert frac.rows[0].second == 59.999999
    let usec = read("2024,61,0,0,59,999999\n",
      [crYear, crDayOfYear, crHour, crMinute, crSecond, crMicrosecond], header = false)
    doAssert usec.rows[0].timeUtcUs.get == UtcMarch + 59_999999
    doAssert not hasKind(frac.problems, pkBadNumber)

  block crossCheck:
    let both = "gps,utc,sec,text\n" & $GpsMarch & "," & $UtcMarch &
      ",1709251200,2024-03-01 00:00:00\n"
    let agree = read(both, [crGpsMicros, crUtcMicros, crUtcSeconds, crDateTime])
    doAssert agree.rows[0].timeUtcUs.get == UtcMarch
    doAssert agree.problems.count == 0
    let near = read($GpsMarch & "," & $(UtcMarch + 500) & "\n",
      [crGpsMicros, crUtcMicros], header = false)
    doAssert not hasKind(near.problems, pkTimeDisagree)
    let gap = read($GpsMarch & "," & $(UtcMarch + 5_000) & "\n",
      [crGpsMicros, crUtcMicros], header = false)
    doAssert hasKind(gap.problems, pkTimeDisagree)
    let msg = kindText(gap.problems, pkTimeDisagree)
    doAssert $UtcMarch in msg and $(UtcMarch + 5_000) in msg
    doAssert "5 ms" in msg and "mixed" notin msg
    doAssert gap.problems.items[0].row == 0 and gap.problems.items[0].col == 1
    let mixed = read($UtcMarch & ",2024-03-01 00:00:00\n",
      [crUtcMicros, crDateTime], header = false, clock = tcGps)
    doAssert mixed.rows[0].timeUtcUs.get == UtcMarch
    let mixedMsg = kindText(mixed.problems, pkTimeDisagree)
    doAssert "GPS and UTC mixed" in mixedMsg
    doAssert "18 s" in mixedMsg
    let gpsClock = read("2024,61,0,0,0\n",
      [crYear, crDayOfYear, crHour, crMinute, crSecond], header = false, clock = tcGps)
    doAssert gpsClock.rows[0].timeUtcUs.get == UtcMarch - 18_000_000

  block duplicatesAndOrder:
    let dup = read("file,line,sp,index,utc\n5,1,2,3,100\n5,1,2,3,90\n6,1,2,4,80\n",
      [crFileNumber, crSourceLine, crShotPoint, crPointIndex, crUtcMicros])
    doAssert hasKind(dup.problems, pkDuplicateFile)
    doAssert hasKind(dup.problems, pkDuplicateShot)
    doAssert hasKind(dup.problems, pkTimeBackward)
    doAssert dup.problems.items[0].col >= 0
    let otherIndex = read("line,sp,index\n1,2,3\n1,2,4\n",
      [crSourceLine, crShotPoint, crPointIndex])
    doAssert not hasKind(otherIndex.problems, pkDuplicateShot)

  block problemCap:
    var text = "n\n"
    for i in 0 ..< 150: text.add "x\n"
    let v = read(text, [crSequence])
    doAssert v.rows.len == 150
    doAssert v.problems.items.len == ProblemCap
    doAssert v.problems.count == 150

  block edits:
    let raw = "a,b\n1,2\n3,4\n"
    let log = parseShotLog(raw, dlComma)
    doAssert log.toText == raw and not log.changed
    log.setCell(0, 1, "9")
    doAssert log.cell(0, 1) == "9" and log.cell(1, 1) == "4" and log.changed
    doAssert log.toText == "a,b\n1,9\n3,4\n"
    log.setCell(0, 1, "a,b")
    doAssert log.toText == "a,b\n1,\"a,b\"\n3,4\n"
    log.revert(0, 1)
    doAssert log.cell(0, 1) == "2" and log.toText == raw and not log.changed
    let quoted = "a,b\r\n\"x,y\",2\r\n"
    doAssert parseShotLog(quoted, dlComma).toText == quoted

  block manyRows:
    var b = newStringOfCap(4_000_000)
    for i in 0 ..< 100_000:
      b.addInt i
      for c in 1 .. 29:
        b.add ','
        b.addInt c
      b.add '\n'
    let log = parseShotLog(b, dlComma, hasHeader = false)
    doAssert log.len == 100_000 and log.width == 30
    doAssert log.cell(0, 0) == "0" and log.cell(99_999, 0) == "99999"
    doAssert log.cell(50_000, 29) == "29" and log.problems.count == 0

  block sampleFile:
    let path = currentSourcePath().parentDir.parentDir / "samples" / "land" / "shotlog.csv"
    let text = readFile(path)
    let g = guessMap(text)
    doAssert g.delimiter == dlComma and g.hasHeader
    doAssert g.roles[0] == crSequence and g.roles[1] == crFileNumber
    doAssert g.roles[5] == crGpsMicros and g.roles[11] == crDateTime
    let log = parseShotLog(text, g)
    doAssert log.len == 200 and log.width == 22
    let v = shots(log, g)
    doAssert v.rows[0].shotPoint == 1000.0 and v.rows[0].sourceLine == 10.0
    doAssert v.rows[0].timeUtcUs.get == UtcMarch
    doAssert v.rows[199].timeUtcUs.get == UtcMarch + 199 * 10_000_000
    doAssert v.rows[199].shotPoint == 1199.0
    doAssert v.rows[3].sourceDepth.isNaN and v.rows[5].waterDepth.isNaN
    doAssert v.rows[0].x == 1000.0 and v.rows[0].y == 2000.0
    doAssert not hasKind(v.problems, pkTimeDisagree)
    doAssert not hasKind(v.problems, pkDuplicateShot)

  block overflowAndYearRange:
    let hugeSec = read("1393286418000000\n", [crUtcSeconds], header = false)
    doAssert hugeSec.rows[0].timeUtcUs.isNone
    doAssert hasKind(hugeSec.problems, pkBadNumber)
    let over = read("9223372036854775808\n", [crSequence], header = false)
    doAssert over.rows[0].sequence.isNone
    doAssert "not a whole number" in kindText(over.problems, pkBadNumber)
    let fit = read("9223372036854775807\n", [crSequence], header = false)
    doAssert fit.rows[0].sequence.get == high(int64)
    let nines = read("2024,3,1,0,0,99999999999999999999\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond], header = false)
    doAssert nines.rows[0].timeUtcUs.isNone
    doAssert hasKind(nines.problems, pkBadNumber)
    discard gpsMicrosToUtcMicros(high(int64))
    let gps = read($high(int64) & "\n", [crGpsMicros], header = false)
    doAssert gps.rows[0].timeUtcUs.isNone
    doAssert hasKind(gps.problems, pkBadNumber)
    let early = read("1899,12,31,23,59,59\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond], header = false)
    doAssert early.rows[0].timeUtcUs.isNone
    doAssert "1900..2200" in kindText(early.problems, pkBadNumber)
    let start = read("1900,1,1,0,0,0\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond], header = false)
    doAssert start.rows[0].timeUtcUs.isSome
    let last = read("2200,12,31,23,59,59\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond], header = false)
    doAssert last.rows[0].timeUtcUs.isSome
    let past = read("2201,1,1,0,0,0\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond], header = false)
    doAssert past.rows[0].timeUtcUs.isNone
    doAssert "1900..2200" in kindText(past.problems, pkBadNumber)
    let far = read("10000000000\n", [crUtcSeconds], header = false)
    doAssert far.rows[0].timeUtcUs.isNone
    doAssert "1900..2200" in kindText(far.problems, pkBadNumber)

  block textLongerThanInt32:
    let n = high(int32).int + 1
    var raw = newStringUninit(n)
    raw[0] = 'x'
    raw[n - 1] = '\n'
    let g = guessMap(raw)
    doAssert g.roles.len == 0
    let log = parseShotLog(raw, dlComma)
    doAssert log.len == 0
    doAssert log.width == 0
    doAssert log.toText.len == 0
    doAssert log.problems.count == 1
    doAssert log.problems.items[0].kind == pkTooLong
    doAssert log.problems.items[0].row == -1
    doAssert "2147483647" in log.problems.items[0].text

  block fractionAndMicros:
    let clash = read("2024,3,1,0,0,59.5,0\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond, crMicrosecond],
      header = false)
    doAssert clash.rows[0].timeUtcUs.get == UtcMarch + 59_000000
    doAssert clash.rows[0].microsecond.get == 0
    doAssert clash.rows[0].second == 59.5
    doAssert hasKind(clash.problems, pkTimeDisagree)
    let named = kindText(clash.problems, pkTimeDisagree)
    doAssert "59.5" in named and "0" in named
    let same = read("2024,3,1,0,0,59.5,500000\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond, crMicrosecond],
      header = false)
    doAssert same.rows[0].timeUtcUs.get == UtcMarch + 59_500000
    doAssert not hasKind(same.problems, pkTimeDisagree)
    let supplied = read("2024,3,1,0,0,59,500000\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond, crMicrosecond],
      header = false)
    doAssert supplied.rows[0].timeUtcUs.get == UtcMarch + 59_500000
    doAssert not hasKind(supplied.problems, pkTimeDisagree)
    let close = read("2024,3,1,0,0,59.000001,0\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond, crMicrosecond],
      header = false)
    doAssert close.rows[0].timeUtcUs.get == UtcMarch + 59_000000
    doAssert not hasKind(close.problems, pkTimeDisagree)

  block yearColumnPivot:
    let full = read("2016,3,1,0,0,0\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond], header = false)
    let y16 = read("16,3,1,0,0,0\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond], header = false)
    doAssert y16.rows[0].year.get == 2016
    doAssert y16.rows[0].timeUtcUs.get == full.rows[0].timeUtcUs.get
    doAssert not hasKind(y16.problems, pkBadNumber)
    let y50 = read("50\n", [crYear], header = false)
    doAssert y50.rows[0].year.get == 1950
    let y49 = read("49\n", [crYear], header = false)
    doAssert y49.rows[0].year.get == 2049
    let y99 = read("99\n", [crYear], header = false)
    doAssert y99.rows[0].year.get == 1999
    let y00 = read("0\n", [crYear], header = false)
    doAssert y00.rows[0].year.get == 2000
    let y2024 = read("2024\n", [crYear], header = false)
    doAssert y2024.rows[0].year.get == 2024
    let y216 = read("216,3,1,0,0,0\n",
      [crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond], header = false)
    doAssert y216.rows[0].year.isNone
    doAssert y216.rows[0].timeUtcUs.isNone
    doAssert hasKind(y216.problems, pkBadNumber)
    doAssert "216" in kindText(y216.problems, pkBadNumber)

  block decimalComma:
    doAssert not initShotLogMap().decimalComma
    let semi = guessMap("shot;depth\n1;1,5\n2;2,25\n")
    doAssert semi.delimiter == dlSemicolon
    doAssert semi.decimalComma
    let readSemi = shots(parseShotLog("shot;depth\n1;1,5\n2;2,25\n", semi), semi)
    doAssert readSemi.rows[0].shotPoint == 1.0
    doAssert readSemi.rows[0].sourceDepth == 1.5
    doAssert readSemi.rows[1].sourceDepth == 2.25
    let dotted = guessMap("shot;depth\n1;1.5\n")
    doAssert dotted.delimiter == dlSemicolon
    doAssert not dotted.decimalComma
    let mixed = guessMap("shot;depth\n1,5;1.5\n")
    doAssert not mixed.decimalComma
    let commas = guessMap("shot,depth\n1,1.5\n")
    doAssert commas.delimiter == dlComma
    doAssert not commas.decimalComma
    let tabs = guessMap("shot\tdepth\n1\t1,5\n")
    doAssert tabs.delimiter == dlTab
    doAssert tabs.decimalComma
    var m = mapOf([crYear, crMonth, crDayOfMonth, crHour, crMinute, crSecond],
      dlSemicolon, header = false)
    m.decimalComma = true
    let sec = shots(parseShotLog("2024;3;1;0;0;59,5\n", m), m)
    doAssert sec.rows[0].second == 59.5
    doAssert sec.rows[0].timeUtcUs.get == UtcMarch + 59_500000
    m.sentinels = @["-999.25"]
    m.roles = @[crShotPoint]
    let missing = shots(parseShotLog("1,5\n-999,25\n", m), m)
    doAssert missing.rows[0].shotPoint == 1.5
    doAssert missing.rows[1].shotPoint.isNaN
    doAssert not hasKind(missing.problems, pkBadNumber)

  echo "tshotlog ok"

when isMainModule:
  main()
