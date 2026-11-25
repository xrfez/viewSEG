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
## With no leap-second problem, `leapSecond` keeps the rolled instant and
## reports nothing. With the delimiter taken from the header line alone,
## `spacesInHeader` and `headerSplitsOtherwise` guess a role one column to the
## right of its cells and `three-digit year` is reported for a log whose year
## has four digits; with every header name grouped by position only, the
## day-of-year cells land in the year. A per-cell copy in `shots` took 1232 ms and
## 30000005 allocations on 100000 rows of 30 numbers. With `setCell`
## returning void, `oneLine` cannot refuse a newline.

import std/[math, options, os, sequtils, strutils]
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
    clock = tcUtc; skip = 0; pattern = ""): ShotView =
  var m = mapOf(roles, d, header)
  m.clock = clock
  m.skipLines = skip
  m.dateTimePattern = pattern
  shots(parseShotLog(text, m), m)

proc timeOf(text: string; pattern = ""; cols = 1; clock = tcUtc): ShotView =
  ## `text` (no header) with every column a Time (UTC) column.
  read(text, newSeq[ColumnRole](cols).mapIt(crTime), header = false, clock = clock,
    pattern = pattern)

proc kindText(p: ProblemList; k: ProblemKind): string =
  for it in p.items:
    if it.kind == k: return it.text
  ""

proc hasKind(p: ProblemList; k: ProblemKind): bool =
  kindText(p, k).len > 0

proc main*() =
  block plainWords:
    var choices: seq[string] = @[]
    for r in ColumnRole: choices.add label(r)
    doAssert choices == @["Ignore", "Time (UTC)", "GPSTB", "SEQ", "FFID", "Status",
      "SailLine", "SourceLine", "SourcePoint", "Index", "Depth", "Water Depth", "X", "Y",
      "Z", "SourceType", "SourceID", "Uphole", "User defined"]
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
    doAssert g.roles[2] == crText and g.names[2] == "Shot_Point"
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
    doAssert g.roles[0] == crGpsMicros and g.roles[1] == crText
    doAssert g.roles[2] == crText
    let v = shots(parseShotLog(text, g), g)
    doAssert v.rows[0].timeUtcUs.get == UtcMarch
    doAssert v.rows[0].texts == @["2024", "1.5"]

  block eachTimeSource:
    doAssert toPosixSeconds(UtcMarch) == 1_709_251_200.0
    doAssert gpsMicrosToUtcMicros(0) == 315_964_800'i64 * 1_000_000
    doAssert gpsMicrosToUtcMicros(GpsMarch) == UtcMarch
    let gps = read($GpsMarch & "\n", [crGpsMicros], header = false)
    doAssert gps.rows[0].timeUtcUs.get == UtcMarch
    doAssert detectTimePattern($UtcMarch) == EpochMicros
    doAssert timeOf($UtcMarch & "\n").rows[0].timeUtcUs.get == UtcMarch
    doAssert timeOf("1709251200\n").rows[0].timeUtcUs.get == UtcMarch
    doAssert detectTimePattern("1709251200") == EpochSeconds
    let frac = timeOf("1709251200.005\n")
    doAssert frac.rows[0].timeUtcUs.get == UtcMarch + 5_000
    doAssert detectTimePattern("2024 061 00 00 00") == "yyyy ddd hh mi ss"
    let doy = timeOf("2024,61,0,0,0\n", cols = 5)
    doAssert doy.rows[0].timeUtcUs.get == UtcMarch
    doAssert doy.problems.count == 0
    let md = timeOf("2024,3,1,0,0,0\n", cols = 6)
    doAssert md.rows[0].timeUtcUs.get == UtcMarch
    doAssert detectTimePattern("2024 3 1 0 0 0") == "yyyy mm dd hh mi ss"
    let text = timeOf("2024-03-01 00:00:00\n")
    doAssert text.rows[0].timeUtcUs.get == UtcMarch
    let iso = timeOf("2024-03-01T00:00:00Z\n")
    doAssert iso.rows[0].timeUtcUs.get == UtcMarch
    let slash = timeOf("2024/03/01 00:00:00.000000\n")
    doAssert slash.rows[0].timeUtcUs.get == UtcMarch
    doAssert detectTimePattern("2024/03/01 00:00:00.000000") == "yyyy/mm/dd hh:mi:ss.ffffff"
    let dateAndTime = timeOf("2024-03-01,00:00:00.5\n", cols = 2)
    doAssert dateAndTime.rows[0].timeUtcUs.get == UtcMarch + 500_000
    let typed = timeOf("2024/03/01 00:00:00\n", "yyyy/mm/dd hh:mm:ss")
    doAssert typed.rows[0].timeUtcUs.get == UtcMarch
    let spaced = timeOf("2024,361,23,59,59.5,250000\n", "yyyy ddd hh mi ss.f uuuuuu", 6)
    doAssert spaced.rows[0].timeUtcUs.isSome
    let epoch = timeOf("1980,1,6,0,0,0\n", cols = 6)
    doAssert epoch.rows[0].timeUtcUs.get == 315_964_800'i64 * 1_000_000
    let blank = timeOf("2024,,\n", cols = 3)
    doAssert blank.rows[0].timeUtcUs.isNone

  block leapDayAndFraction:
    const doyForm = "yyyy ddd hh mi ss.ffffff"
    let feb = timeOf("2024,60,0,0,0\n", doyForm, 5)
    doAssert feb.rows[0].timeUtcUs.get == UtcFeb29
    let yearEnd = timeOf("2024,366,0,0,0\n2025,1,0,0,0\n", doyForm, 5)
    doAssert yearEnd.rows[0].timeUtcUs.get == UtcDec31
    doAssert yearEnd.rows[1].timeUtcUs.get == UtcJan1
    doAssert yearEnd.rows[1].timeUtcUs.get - yearEnd.rows[0].timeUtcUs.get == DayUs
    let common = timeOf("2023,60,0,0,0\n", doyForm, 5)
    doAssert common.rows[0].timeUtcUs.get == Utc2023Mar
    let frac = timeOf("2024,61,0,0,59.999999\n", doyForm, 5)
    doAssert frac.rows[0].timeUtcUs.get == UtcMarch + 59_999999
    let usec = timeOf("2024,61,0,0,59,999999\n", "yyyy ddd hh mi ss uuuuuu", 6)
    doAssert usec.rows[0].timeUtcUs.get == UtcMarch + 59_999999
    doAssert not hasKind(frac.problems, pkBadNumber)
    let notADay = timeOf("2023,366,0,0,0\n", doyForm, 5)
    doAssert notADay.rows[0].timeUtcUs.isNone
    doAssert "366" in kindText(notADay.problems, pkBadNumber)

  block crossCheck:
    let both = "gps,utc\n" & $GpsMarch & "," & $UtcMarch & "\n"
    let agree = read(both, [crGpsMicros, crTime])
    doAssert agree.rows[0].timeUtcUs.get == UtcMarch
    doAssert agree.problems.count == 0
    let near = read($GpsMarch & "," & $(UtcMarch + 500) & "\n",
      [crGpsMicros, crTime], header = false)
    doAssert not hasKind(near.problems, pkTimeDisagree)
    let gap = read($GpsMarch & "," & $(UtcMarch + 5_000) & "\n",
      [crGpsMicros, crTime], header = false)
    doAssert hasKind(gap.problems, pkTimeDisagree)
    let msg = kindText(gap.problems, pkTimeDisagree)
    doAssert $UtcMarch in msg and $(UtcMarch + 5_000) in msg
    doAssert "5 ms" in msg and "mixed" notin msg
    doAssert "GPSTB" in msg and "Time (UTC)" in msg
    doAssert gap.problems.items[0].row == 0 and gap.problems.items[0].col == 1
    let mixed = read($GpsMarch & ",2024-03-01 00:00:00\n",
      [crGpsMicros, crTime], header = false, clock = tcGps)
    doAssert mixed.rows[0].timeUtcUs.get == UtcMarch
    let mixedMsg = kindText(mixed.problems, pkTimeDisagree)
    doAssert "GPS and UTC mixed" in mixedMsg
    doAssert "18 s" in mixedMsg
    let gpsClock = timeOf("2024,61,0,0,0\n", "yyyy ddd hh mi ss", 5, clock = tcGps)
    doAssert gpsClock.rows[0].timeUtcUs.get == UtcMarch - 18_000_000

  block duplicatesAndOrder:
    let dup = read("file,line,sp,index,utc\n5,1,2,3,100\n5,1,2,3,90\n6,1,2,4,80\n",
      [crFileNumber, crSourceLine, crShotPoint, crPointIndex, crTime],
      pattern = EpochMicros)
    doAssert hasKind(dup.problems, pkDuplicateFile)
    doAssert hasKind(dup.problems, pkDuplicateShot)
    doAssert hasKind(dup.problems, pkTimeBackward)
    doAssert dup.problems.items[0].col >= 0
    doAssert "FFID 5 also on row 0" in kindText(dup.problems, pkDuplicateFile)
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
    doAssert log.setCell(0, 1, "9")
    doAssert log.cell(0, 1) == "9" and log.cell(1, 1) == "4" and log.changed
    doAssert log.toText == "a,b\n1,9\n3,4\n"
    doAssert log.setCell(0, 1, "a,b")
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
    doAssert g.roles[5] == crGpsMicros and g.roles[11] == crTime
    doAssert g.dateTimePattern == "yyyy-mm-dd hh:mi:ss.ffffff"
    doAssert g.roles[6] == crText and g.names[6] == "year"
    doAssert g.roles[18] == crText and g.names[21] == "speed"
    let log = parseShotLog(text, g)
    doAssert log.len == 200 and log.width == 22
    let v = shots(log, g)
    doAssert v.rows[0].shotPoint == 1000.0 and v.rows[0].sourceLine == 10.0
    doAssert v.rows[0].timeUtcUs.get == UtcMarch
    doAssert v.rows[199].timeUtcUs.get == UtcMarch + 199 * 10_000_000
    doAssert v.rows[199].shotPoint == 1199.0
    doAssert v.rows[3].sourceDepth.isNaN and v.rows[5].waterDepth.isNaN
    doAssert v.rows[0].x == 1000.0 and v.rows[0].y == 2000.0
    doAssert v.rows[0].texts.len == 9 and v.rows[0].texts[0] == "2024"
    doAssert not hasKind(v.problems, pkTimeDisagree)
    doAssert not hasKind(v.problems, pkDuplicateShot)

  block overflowAndYearRange:
    let hugeSec = timeOf("1393286418000000\n", EpochSeconds)
    doAssert hugeSec.rows[0].timeUtcUs.isNone
    doAssert hasKind(hugeSec.problems, pkBadNumber)
    let over = read("9223372036854775808\n", [crSequence], header = false)
    doAssert over.rows[0].sequence.isNone
    doAssert "not a whole number" in kindText(over.problems, pkBadNumber)
    doAssert "SEQ '9223372036854775808'" in kindText(over.problems, pkBadNumber)
    let fit = read("9223372036854775807\n", [crSequence], header = false)
    doAssert fit.rows[0].sequence.get == high(int64)
    let nines = timeOf("2024,3,1,0,0,99999999999999999999\n", cols = 6)
    doAssert nines.rows[0].timeUtcUs.isNone
    doAssert hasKind(nines.problems, pkBadNumber)
    discard gpsMicrosToUtcMicros(high(int64))
    let gps = read($high(int64) & "\n", [crGpsMicros], header = false)
    doAssert gps.rows[0].timeUtcUs.isNone
    doAssert hasKind(gps.problems, pkBadNumber)
    let early = timeOf("1899,12,31,23,59,59\n", cols = 6)
    doAssert early.rows[0].timeUtcUs.isNone
    doAssert "1900..2200" in kindText(early.problems, pkBadNumber)
    let start = timeOf("1900,1,1,0,0,0\n", cols = 6)
    doAssert start.rows[0].timeUtcUs.isSome
    let last = timeOf("2200,12,31,23,59,59\n", cols = 6)
    doAssert last.rows[0].timeUtcUs.isSome
    let past = timeOf("2201,1,1,0,0,0\n", cols = 6)
    doAssert past.rows[0].timeUtcUs.isNone
    doAssert "1900..2200" in kindText(past.problems, pkBadNumber)
    let far = timeOf("10000000000\n")
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
    const form = "yyyy mm dd hh mi ss.f uuuuuu"
    let clash = timeOf("2024,3,1,0,0,59.5,0\n", form, 7)
    doAssert clash.rows[0].timeUtcUs.get == UtcMarch + 59_000000
    doAssert hasKind(clash.problems, pkTimeDisagree)
    let named = kindText(clash.problems, pkTimeDisagree)
    doAssert "500000" in named and "microsecond 0" in named
    let same = timeOf("2024,3,1,0,0,59.5,500000\n", form, 7)
    doAssert same.rows[0].timeUtcUs.get == UtcMarch + 59_500000
    doAssert not hasKind(same.problems, pkTimeDisagree)
    let supplied = timeOf("2024,3,1,0,0,59,500000\n", form, 7)
    doAssert supplied.rows[0].timeUtcUs.get == UtcMarch + 59_500000
    doAssert not hasKind(supplied.problems, pkTimeDisagree)
    let close = timeOf("2024,3,1,0,0,59.000001,0\n", form, 7)
    doAssert close.rows[0].timeUtcUs.get == UtcMarch + 59_000000
    doAssert not hasKind(close.problems, pkTimeDisagree)

  block yearPivot:
    let full = timeOf("2016,3,1,0,0,0\n", cols = 6)
    let y16 = timeOf("16,3,1,0,0,0\n", "yy mm dd hh mi ss", 6)
    doAssert y16.rows[0].timeUtcUs.get == full.rows[0].timeUtcUs.get
    doAssert not hasKind(y16.problems, pkBadNumber)
    doAssert detectTimePattern("16 361 10 20 30") == "yy ddd hh mi ss"
    for (yy, year) in [("50", 1950), ("49", 2049), ("99", 1999), ("00", 2000)]:
      let v = timeOf(yy & ",1,1,0,0,0\n", "yy mm dd hh mi ss", 6)
      let want = timeOf($year & ",1,1,0,0,0\n", cols = 6)
      doAssert v.rows[0].timeUtcUs.get == want.rows[0].timeUtcUs.get, yy
    let wide = timeOf("16,3,1,0,0,0\n", "yyyy mm dd hh mi ss", 6)
    doAssert wide.rows[0].timeUtcUs.get == full.rows[0].timeUtcUs.get
    let y216 = timeOf("216,3,1,0,0,0\n", "yyyy mm dd hh mi ss", 6)
    doAssert y216.rows[0].timeUtcUs.isNone
    doAssert "1900..2200" in kindText(y216.problems, pkBadNumber)
    doAssert "three-digit" notin kindText(y216.problems, pkBadNumber)

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
    var m = mapOf([crTime, crTime, crTime, crTime, crTime, crTime],
      dlSemicolon, header = false)
    m.decimalComma = true
    m.dateTimePattern = "yyyy mm dd hh mi ss.f"
    let sec = shots(parseShotLog("2024;3;1;0;0;59,5\n", m), m)
    doAssert sec.rows[0].timeUtcUs.get == UtcMarch + 59_500000
    m.sentinels = @["-999.25"]
    m.roles = @[crShotPoint]
    let missing = shots(parseShotLog("1,5\n-999,25\n", m), m)
    doAssert missing.rows[0].shotPoint == 1.5
    doAssert missing.rows[1].shotPoint.isNaN
    doAssert not hasKind(missing.problems, pkBadNumber)

  block leapSecond:
    let leap = timeOf("2024,3,1,0,0,60\n", cols = 6)
    let next = timeOf("2024,3,1,0,1,0\n", cols = 6)
    doAssert leap.rows[0].timeUtcUs.get == UtcMarch + 60_000000
    doAssert leap.rows[0].timeUtcUs.get == next.rows[0].timeUtcUs.get
    doAssert "has second 60" in kindText(leap.problems, pkBadNumber)
    let asText = timeOf("2024-03-01 00:00:60\n")
    doAssert asText.rows[0].timeUtcUs.get == UtcMarch + 60_000000
    doAssert "has second 60" in kindText(asText.problems, pkBadNumber)
    let ordinary = timeOf("2024,3,1,0,0,59\n", cols = 6)
    doAssert ordinary.rows[0].timeUtcUs.get == UtcMarch + 59_000000
    doAssert "second 60" notin kindText(ordinary.problems, pkBadNumber)

  block badTime:
    let v = timeOf("2024 361 23:59:60\n2024 361 23:59:xx\n", "yyyy ddd hh:mi:ss")
    doAssert v.rows[0].timeUtcUs.isSome
    doAssert v.rows[1].timeUtcUs.isNone
    let said = kindText(v.problems, pkBadNumber)
    doAssert said.len > 0
    var found = false
    for it in v.problems.items:
      if it.row == 1:
        doAssert it.text == "time '2024 361 23:59:xx' does not match yyyy ddd hh:mi:ss"
        doAssert it.col == 0
        found = true
    doAssert found
    let nonsense = timeOf("2024,13,40,0,0,0\n", "yyyy mm dd hh mi ss", 6)
    doAssert "is not a valid date and time" in kindText(nonsense.problems, pkBadNumber)
    let unknown = timeOf("hello\n")
    doAssert "does not match any known form" in kindText(unknown.problems, pkBadNumber)
    let word = read("sp\nabc\n", [crShotPoint])
    doAssert kindText(word.problems, pkBadNumber) == "SourcePoint 'abc' is not a number"

  block uphole:
    let v = read("up,x\n12.5,1\n,2\n", [crUphole, crX])
    doAssert v.rows[0].uphole == 12.5 and v.rows[1].uphole.isNaN
    doAssert v.rows[1].x == 2.0

  block ignoreAndUserDefined:
    let text = "a,b,c,d\n1,2,abc,xyz\n3,4,def,\n"
    let v = read(text, [crSequence, crIgnored, crText, crText])
    doAssert v.rows[0].sequence.get == 1 and v.rows[1].sequence.get == 3
    doAssert v.rows[0].texts == @["abc", "xyz"] and v.rows[1].texts == @["def", ""]
    doAssert v.problems.count == 0
    let junk = read("a,b\nx,2\n", [crIgnored, crSequence])
    doAssert junk.problems.count == 0 and junk.rows[0].sequence.get == 2
    var m = mapOf([crSequence, crIgnored, crText, crText])
    m.names = @["", "", "", "Note"]
    let log = parseShotLog(text, m)
    doAssert columnNames(log, m, 4) == @["SEQ", "b", "c", "Note"]
    m.names = @["", "", "Source Line", ""]
    doAssert mapFault(m).len > 0 and "system's column names" in mapFault(m)
    m.names = @["", "", "water_depth", ""]
    doAssert mapFault(m).len > 0
    m.names = @["", "", "x", ""]
    doAssert mapFault(m).len > 0
    m.names = @["", "", "Ignore", ""]
    doAssert mapFault(m).len > 0
    m.names = @["", "", "Time (UTC)", ""]
    doAssert mapFault(m).len > 0
    m.names = @["", "", "Note", "note"]
    doAssert "Another column is named" in mapFault(m)
    m.names = @["", "", "Note", "Remark"]
    doAssert mapFault(m) == ""
    m.roles = @[crSequence, crSequence, crText, crText]
    doAssert "SEQ is chosen for more than one column" in mapFault(m)
    m.roles = @[crTime, crTime, crText, crText]
    doAssert mapFault(m) == ""
    for bad in ["sourceline", "Source Line", "water_depth", "WATER-DEPTH", "SourceID",
        "time (utc)", "Uphole", "ignore", "FFID"]:
      doAssert isSystemName(bad), bad
    doAssert not isSystemName("Depth 2") and not isSystemName("Note")
    # a header that uses a system name for a user defined column
    var named = mapOf([crText, crText])
    let withHeader = parseShotLog("Depth,Depth\n1,2\n", named)
    doAssert columnNames(withHeader, named, 2) == @["Depth (file)", "Depth (file) 2"]

  block spacesInHeader:
    # the header names hold spaces, so a header cut at spaces has more fields
    # than the rows have columns
    let text = "Sail line Shot point Year Day of year Hour Minute Second\n" &
      "5 1001 2024 361 23 59 59.5\n6 1002 2024 361 23 59 59.75\n"
    let g = guessMap(text)
    doAssert g.delimiter == dlSpaces and g.hasHeader
    doAssert g.roles == @[crSailLine, crShotPoint, crTime, crTime, crTime, crTime, crTime]
    doAssert g.dateTimePattern == "yyyy ddd hh mi ss.f"
    let log = parseShotLog(text, g)
    doAssert log.len == 2 and log.width == 7 and log.problems.count == 0
    let v = shots(log, g)
    doAssert v.problems.count == 0
    doAssert v.rows[0].sailLine == 5.0 and v.rows[0].shotPoint == 1001.0
    doAssert v.rows[0].timeUtcUs.get == UtcDec31 - 5 * DayUs + 86_399_500_000
    # the same header over rows whose names the guess cannot place
    let unplaced = guessMap("Alpha beta gamma delta\n1 2 3\n4 5 6\n")
    doAssert unplaced.roles == @[crText, crText, crText]
    doAssert unplaced.names == @["", "", ""]

  block noThreeDigitYear:
    # the header cut at spaces put "year" on the column of the day of year
    let text = "Sail line Year Day of year Hour Minute Second\n" &
      "5 2024 361 23 59 59.5\n6 2024 361 23 59 59.75\n"
    let g = guessMap(text)
    doAssert g.roles == @[crSailLine, crTime, crTime, crTime, crTime, crTime]
    let v = shots(parseShotLog(text, g), g)
    doAssert v.problems.count == 0
    for p in v.problems.items:
      doAssert "three-digit" notin p.text
    doAssert v.rows[1].timeUtcUs.get == v.rows[0].timeUtcUs.get + 250_000

  block headerSplitsOtherwise:
    # the header line holds a comma, the rows are cut at spaces
    let text = "SEQ,FFID Status\n1 1001 OK\n2 1002 OK\n"
    let g = guessMap(text)
    doAssert g.delimiter == dlSpaces
    doAssert g.roles.len == 3
    doAssert crTime notin g.roles
    let v = shots(parseShotLog(text, g), g)
    doAssert v.problems.count == 0
    # a year of four digits is never called three digits
    let years = "year,day of year,hour,minute,second\n2024,361,12,30,15\n" &
      "2024,362,12,30,15\n"
    let y = guessMap(years)
    doAssert y.roles == @[crTime, crTime, crTime, crTime, crTime]
    let yv = shots(parseShotLog(years, y), y)
    doAssert yv.problems.count == 0
    doAssert yv.rows[0].timeUtcUs.isSome
    # a role whose cells do not read as that role is not assigned
    let words = "sequence,x\nabc,def\nghi,jkl\n"
    let w = guessMap(words)
    doAssert w.roles == @[crText, crText]
    doAssert w.names == @["sequence", "x (file)"]

  block oldMaps:
    # a project saved before the system columns were named
    var m = initShotLogMap()
    var old = @["file number", "UTC microseconds", "gun array", "text", "ignored", "X"]
    doAssert applyRoleNames(m, old, []) == ""
    doAssert m.roles == @[crFileNumber, crTime, crText, crText, crIgnored, crX]
    doAssert m.dateTimePattern == EpochMicros
    doAssert m.names == @["", "", "gun array", "", "", ""]
    var split = initShotLogMap()
    split.hasHeader = false
    let parts = ["year", "day of year", "hour", "minute", "second", "microsecond", "volume"]
    doAssert applyRoleNames(split, parts, []) == ""
    doAssert split.roles == @[crTime, crTime, crTime, crTime, crTime, crTime, crText]
    doAssert split.dateTimePattern == "yyyy ddd hh mi ss.ffffff uuuuuu"
    let oldRead = shots(parseShotLog("2024,61,0,0,59.5,0,7\n", split), split)
    doAssert oldRead.rows[0].timeUtcUs.get == UtcMarch + 59_000_000
    doAssert oldRead.rows[0].texts == @["7"]
    var incomplete = initShotLogMap()
    doAssert applyRoleNames(incomplete, ["year", "hour"], []) == ""
    doAssert incomplete.roles == @[crText, crText]
    doAssert incomplete.names == @["year", "hour"]
    var fresh = initShotLogMap()
    doAssert applyRoleNames(fresh, ["Time (UTC)", "User defined", "SEQ"], ["", "Note"]) == ""
    doAssert fresh.roles == @[crTime, crText, crSequence] and fresh.names[1] == "Note"
    doAssert applyRoleNames(fresh, ["no such role"], []) == "no such role"

  block sliceRead:
    let quoted = read("\"1.5\",2\n", [crShotPoint, crSequence], header = false)
    doAssert quoted.rows[0].shotPoint == 1.5
    doAssert quoted.rows[0].sequence.get == 2
    var m = mapOf([crShotPoint], header = false)
    let log = parseShotLog("1\n", m)
    doAssert log.setCell(0, 0, "4.5")
    doAssert shots(log, m).rows[0].shotPoint == 4.5

  block oneLine:
    let log = parseShotLog("a,b\n1,2\n", dlComma)
    doAssert not log.setCell(0, 1, "x\ny")
    doAssert not log.setCell(0, 1, "x\ry")
    doAssert log.cell(0, 1) == "2"
    doAssert log.toText == "a,b\n1,2\n"
    doAssert not log.changed

  echo "tshotlog ok"

when isMainModule:
  main()
