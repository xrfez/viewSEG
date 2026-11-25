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
##
## Time (UTC) is one column, read by one pattern. Seen to fail: with the check
## that the detected pattern reads every sampled row taken out, `notGuessed`
## proposed a pattern for "2024-13-01 10:00:00"; with the half-up test of
## `parseSecondsUs` made `> 5`, `epochRounding` read ...0000005 as 0; with the
## older sources tried in another order, `oldMaps` took the seconds column;
## with `nameKey` keeping ASCII only, `nameKeys` found two names of another
## script the same; with the instant taken from the last source, `crossCheck`
## read Time (UTC) where GPSTB is chosen; with the fitted header names left
## out, `fittedNames` and `spacesInHeader` showed shifted names; with the
## header's names dropped when the rows have another count,
## `headerAndRowsDiffer` lost every role; with the spread time not noticed,
## `guessRules` found no `tsFound`; with the digits of a field not capped
## (the first mutation the reviewer made), `eachTimeSource` read
## 20240301000000 into the wrong fields.
##
## Seen to fail on the earlier guess: with 16 digits under Time taken as
## GPSTB, `microsAsked` read Unix microseconds of 2023 as 2033 and asked
## nothing, and `noHeaderAndGuess` guessed GPSTB with no header at all. With
## ten digits under Time proposed as epoch seconds, `secondsAsked` read GPS
## seconds of 2024 as 2014. With the shapes compared with their fraction,
## `optionalFraction` read no row of a log whose rows read before. With the
## pattern still made to read every sampled row, `shapesDecide` and
## `guessRules` read no row of a log with one 30 February or hour 25; with
## hour 24 refused, 24:00:00 was not read. With Time (UTC) taken where GPSTB
## is empty, `crossCheck` mixed two clocks in one log and said nothing.

import std/[math, options, os, strutils, times]
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

proc unixUs(y, mo, d, h, mi, s: int): int64 =
  ## An instant worked out by the standard library's own calendar.
  dateTime(y, Month(mo), d, h, mi, s, zone = utc()).toTime.toUnix * 1_000_000

proc timeOf(text: string; pattern = ""; clock = tcUtc): ShotView =
  ## `text` (no header): one Time (UTC) column.
  read(text, [crTime], header = false, clock = clock, pattern = pattern)

proc timeAt(cell, pattern: string; clock = tcUtc): Option[int64] =
  ## The instant of one cell read as `pattern` ("": the pattern its rows decide).
  timeOf("\"" & cell & "\"\n", pattern, clock).rows[0].timeUtcUs

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
    # no header says GPS: the 16 digits are not guessed, and the user is asked
    let text = $GpsMarch & ",2024,1.5\n" & $(GpsMarch + 10_000_000) & ",2024,2.5\n"
    let g = guessMap(text)
    doAssert not g.hasHeader and g.delimiter == dlComma
    doAssert g.roles == @[crText, crText, crText]
    let v = shots(parseShotLog(text, g), g)
    doAssert v.rows[0].timeUtcUs.isNone
    doAssert v.rows[0].texts == @[$GpsMarch, "2024", "1.5"]
    doAssert v.problems.items[0].text == "\"Column 1\" holds microsecond times, GPS or " &
      "Unix: choose GPSTB or Time (UTC)."
    var chosen = g
    chosen.roles[0] = crGpsMicros
    doAssert shots(parseShotLog(text, chosen), chosen).rows[0].timeUtcUs.get == UtcMarch

  block eachTimeSource:
    doAssert toPosixSeconds(UtcMarch) == 1_709_251_200.0
    doAssert gpsMicrosToUtcMicros(0) == 315_964_800'i64 * 1_000_000
    doAssert gpsMicrosToUtcMicros(GpsMarch) == UtcMarch
    let gps = read($GpsMarch & "\n", [crGpsMicros], header = false)
    doAssert gps.rows[0].timeUtcUs.get == UtcMarch
    doAssert detectTimePattern([$UtcMarch]) == ""
    doAssert timeOf($UtcMarch & "\n").rows[0].timeUtcUs.isNone
    doAssert timeOf($UtcMarch & "\n", EpochMicros).rows[0].timeUtcUs.get == UtcMarch
    doAssert timeOf("1709251200\n").rows[0].timeUtcUs.isNone
    doAssert timeOf("1709251200\n").problems.items[0].text == UndecidedNumbers
    doAssert timeOf("1709251200\n", EpochSeconds).rows[0].timeUtcUs.get == UtcMarch
    doAssert detectTimePattern(["1709251200"]) == ""
    let frac = timeOf("1709251200.005\n", EpochSeconds)
    doAssert frac.rows[0].timeUtcUs.get == UtcMarch + 5_000
    # every form that is proposed: found, and typed, read to the same instant
    let feb = unixUs(2024, 2, 29, 13, 14, 15)
    for (cell, pat, want) in [
        ("2024-03-01 00:00:00", "yyyy-mo-dd hh:mi:ss", UtcMarch),
        ("2024-03-01T00:00:00Z", "yyyy-mo-ddThh:mi:ssZ", UtcMarch),
        ("2024/03/01 00:00:00.000000", "yyyy/mo/dd hh:mi:ss.ffffff", UtcMarch),
        ("2024.03.01 00:00:00", "yyyy.mo.dd hh:mi:ss", UtcMarch),
        ("2024-03-01 00:00:00.5", "yyyy-mo-dd hh:mi:ss.ffffff", UtcMarch + 500_000),
        ("2024-03-01 00:00:00,5", "yyyy-mo-dd hh:mi:ss.ffffff", UtcMarch + 500_000),
        ("2024-061 00:00:00", "yyyy-ddd hh:mi:ss", UtcMarch),
        ("2024 061 00:00:00", "yyyy ddd hh:mi:ss", UtcMarch),
        ("2024-3-1 0:0:0", "yyyy-mo-dd hh:mi:ss", UtcMarch),
        ("2024-02-29 13:14:15", "yyyy-mo-dd hh:mi:ss", feb)]:
      doAssert detectTimePattern([cell]) == pat, cell
      doAssert timeAt(cell, "") == some(want), cell
      doAssert timeAt(cell, pat) == some(want), cell
    # forms that are only typed: not proposed, read as typed
    for (cell, pat, want) in [
        ("01/03/2024 00:00:00", "dd/mo/yyyy hh:mi:ss", UtcMarch),
        ("03/01/2024 00:00:00", "mo/dd/yyyy hh:mi:ss", UtcMarch),
        ("24/03/01 00:00:00", "yy/mo/dd hh:mi:ss", UtcMarch),
        ("01.03.24 00:00:00", "dd.mo.yy hh:mi:ss", UtcMarch),
        ("2024 061 00:00:59 999999", "yyyy ddd hh:mi:ss uuuuuu", UtcMarch + 59_999999),
        ("20240301000000", "yyyymoddhhmiss", UtcMarch)]:
      doAssert detectTimePattern([cell]) == "", cell
      doAssert timeAt(cell, "").isNone, cell
      doAssert timeAt(cell, pat) == some(want), cell
    let epoch = timeAt("1980-01-06 00:00:00", "")
    doAssert epoch.get == 315_964_800'i64 * 1_000_000
    doAssert timeOf("\n\n").rows.len == 0
    let blank = read("t,n\n,1\n", [crTime, crSequence], pattern = "yyyy-mo-dd hh:mi:ss")
    doAssert blank.rows[0].timeUtcUs.isNone and blank.problems.count == 0

  block notGuessed:
    # a form that cannot be told apart is not guessed: the user types it
    for cells in [@["01/03/24 10:00:00"], @["01/03/2024 10:00:00"],
        @["2024-03-01 10:00:00+02"], @["2024-03-01 10:00:00-0500"],
        @["2024-03-01 10:00:00 +01"], @["2024-03-01 10:00:00", "2024/03/01 10:00:00"],
        @["2024 05 10:00:00"],
        @["2024 05 10:00:00", "2024 06 11:00:00"], @["2024-13-01 10:00:00"],
        @["2024-03-01 10:00:00", "not a time"], @["1393286418000000"],
        @["1393286418", "x"], @["12"]]:
      doAssert detectTimePattern(cells) == "", $cells
    # a day of year is told from a month by a day above 12, or three digits in every row
    doAssert detectTimePattern(["2024 05 10:00:00", "2024 45 11:00:00"]) == "yyyy ddd hh:mi:ss"
    doAssert detectTimePattern(["2024 005 10:00:00", "2024 006 10:00:00"]) ==
      "yyyy ddd hh:mi:ss"
    doAssert detectTimePattern(["2024 005 10:00:00", "2024 06 10:00:00"]) == ""
    doAssert detectTimePattern(["", "2024-03-01 10:00:00", "  "]) == "yyyy-mo-dd hh:mi:ss"
    # a log with such a time: no time, and one problem that says what to do
    let text = "t\n01/03/24 10:00:00\n02/03/24 10:00:00\n"
    let v = read(text, [crTime])
    doAssert v.rows[0].timeUtcUs.isNone and v.rows[1].timeUtcUs.isNone
    doAssert v.problems.count == 1 and v.problems.items[0].kind == pkNoTime
    doAssert v.problems.items[0].text == UndecidedTime
    doAssert "type the pattern, for example dd/mo/yyyy hh:mi:ss" in UndecidedTime
    let log = parseShotLog(text, mapOf([crTime]))
    doAssert timeNote(log, mapOf([crTime])) == UndecidedTime
    var typed = mapOf([crTime])
    typed.dateTimePattern = "dd/mo/yy hh:mi:ss"
    let ok = shots(log, typed)
    doAssert ok.problems.count == 0
    doAssert ok.rows[0].timeUtcUs.get == unixUs(2024, 3, 1, 10, 0, 0)
    doAssert ok.rows[1].timeUtcUs.get == unixUs(2024, 3, 2, 10, 0, 0)
    doAssert timeNote(log, typed) == "Time (UTC) is read as dd/mo/yy hh:mi:ss"
    # a zone offset is never read as microseconds
    let zone = timeOf("\"2024-03-01 00:00:00 +01\"\n", "yyyy-mo-dd hh:mi:ss")
    doAssert zone.rows[0].timeUtcUs.isNone
    doAssert "does not match" in kindText(zone.problems, pkBadNumber)

  block patternFaults:
    doAssert patternFault("") == "" and patternFault("  ") == ""
    doAssert patternFault("yyyy-mo-dd hh:mi:ss.ffffff") == ""
    doAssert patternFault(EpochSeconds) == "" and patternFault("Epoch Microseconds") == ""
    for bad in ["yyyy-mm-dd hh:mi:ss", "yyyy/mo/dd hh:mm:ss", "yyyy-m-dd hh:mi:ss",
        "yyyy-mmm-dd hh:mi:ss"]:
      doAssert "write mo for the month and mi for the minute" in patternFault(bad), bad
    for bad in ["yyy-mo-dd hh:mi:ss", "yyyy-mo-d hh:mi:ss", "yyyy-mo-dd h:mi:ss",
        "yyyy-mo-dd hh:mi:s", "yyyy-mo-dd hh:mi", "yyyy-mo hh:mi:ss",
        "yyyy ddd mo dd hh:mi:ss", "yyyy yy mo dd hh:mi:ss", "yyyy-mo-dd hh:mi:ss ss"]:
      doAssert patternFault(bad).len > 0, bad
    # a typed pattern with mm reads no time and says why once
    let v = timeOf("2024-03-01 00:00:00\n2024-03-02 00:00:00\n", "yyyy-mm-dd hh:mi:ss")
    doAssert v.rows[0].timeUtcUs.isNone and v.rows[1].timeUtcUs.isNone
    doAssert v.problems.count == 1 and v.problems.items[0].kind == pkNoTime
    doAssert "write mo for the month and mi for the minute" in v.problems.items[0].text
    let log = parseShotLog("2024-03-01 00:00:00\n", mapOf([crTime], header = false))
    var m = mapOf([crTime], header = false)
    m.dateTimePattern = "yyyy-mm-dd hh:mi:ss"
    doAssert "write mo" in timeNote(log, m)

  block longRuns:
    # a run of digits longer than a field is no match, and never overflows
    let nines = "9999999999999999999"
    const dated = "yyyy-mo-dd hh:mi:ss.ffffff"
    for cell in [nines & "-03-01 00:00:00", "2024-" & nines & "-01 00:00:00",
        "2024-03-" & nines & " 00:00:00", "2024-03-01 " & nines & ":00:00",
        "2024-03-01 00:" & nines & ":00", "2024-03-01 00:00:" & nines,
        "2024-03-01 00:00:00." & nines & nines & "x"]:
      doAssert timeAt(cell, dated).isNone, cell
      doAssert detectTimePattern([cell]) == "", cell
    doAssert timeAt("2024 " & nines & " 00:00:00", "yyyy ddd hh:mi:ss").isNone
    doAssert timeAt("2024 061 00:00:00 " & nines, "yyyy ddd hh:mi:ss uuuuuu").isNone
    doAssert timeAt(nines, EpochSeconds).isNone
    doAssert timeAt(nines, EpochMicros).isNone
    # a long fraction is read to the microsecond
    doAssert timeAt("2024-03-01 00:00:00." & nines & nines, dated) ==
      some(UtcMarch + 999_999)

  block leapDayAndFraction:
    const doyForm = "yyyy ddd hh:mi:ss.ffffff"
    doAssert timeAt("2024 060 00:00:00", doyForm).get == UtcFeb29
    let yearEnd = timeOf("2024 366 00:00:00\n2025 001 00:00:00\n", doyForm)
    doAssert yearEnd.rows[0].timeUtcUs.get == UtcDec31
    doAssert yearEnd.rows[1].timeUtcUs.get == UtcJan1
    doAssert yearEnd.rows[1].timeUtcUs.get - yearEnd.rows[0].timeUtcUs.get == DayUs
    doAssert timeAt("2023 060 00:00:00", doyForm).get == Utc2023Mar
    let frac = timeOf("2024 061 00:00:59.999999\n", doyForm)
    doAssert frac.rows[0].timeUtcUs.get == UtcMarch + 59_999999
    doAssert not hasKind(frac.problems, pkBadNumber)
    let notADay = timeOf("2023 366 00:00:00\n", doyForm)
    doAssert notADay.rows[0].timeUtcUs.isNone
    doAssert "366" in kindText(notADay.problems, pkBadNumber)
    doAssert timeAt("2024 061 00:00:59 999999", "yyyy ddd hh:mi:ss uuuuuu").get ==
      UtcMarch + 59_999999

  block epochRounding:
    # the seconds' fraction is read to the microsecond, half up, carrying a second
    doAssert timeAt("1709251200.0000004", EpochSeconds) == some(UtcMarch)
    doAssert timeAt("1709251200.0000005", EpochSeconds) == some(UtcMarch + 1)
    doAssert timeAt("1709251200.1234565", EpochSeconds) == some(UtcMarch + 123_457)
    doAssert timeAt("1709251200.1234564", EpochSeconds) == some(UtcMarch + 123_456)
    doAssert timeAt("1709251200.9999995", EpochSeconds) == some(UtcMarch + 1_000_000)
    doAssert timeAt("1709251200.9999994", EpochSeconds) == some(UtcMarch + 999_999)

  block crossCheck:
    let both = "gps,utc\n" & $GpsMarch & "," & $UtcMarch & "\n"
    let agree = read(both, [crGpsMicros, crTime], pattern = EpochMicros)
    doAssert agree.rows[0].timeUtcUs.get == UtcMarch
    doAssert agree.problems.count == 0
    let near = read($GpsMarch & "," & $(UtcMarch + 500) & "\n",
      [crGpsMicros, crTime], header = false, pattern = EpochMicros)
    doAssert not hasKind(near.problems, pkTimeDisagree)
    let gap = read($GpsMarch & "," & $(UtcMarch + 5_000) & "\n",
      [crGpsMicros, crTime], header = false, pattern = EpochMicros)
    doAssert hasKind(gap.problems, pkTimeDisagree)
    let msg = kindText(gap.problems, pkTimeDisagree)
    doAssert $UtcMarch in msg and $(UtcMarch + 5_000) in msg
    doAssert "5 ms" in msg and "mixed" notin msg
    doAssert "GPSTB" in msg and "Time (UTC)" in msg and msg.endsWith("GPSTB is used")
    doAssert gap.problems.items[0].row == 0 and gap.problems.items[0].col == 1
    doAssert gap.rows[0].timeUtcUs.get == UtcMarch
    # two seconds apart: the instant is GPSTB's, either order of the columns
    let twoSec = read($GpsMarch & "," & $(UtcMarch + 2_000_000) & "\n",
      [crGpsMicros, crTime], header = false, pattern = EpochMicros)
    doAssert twoSec.rows[0].timeUtcUs.get == UtcMarch
    doAssert "2 s" in kindText(twoSec.problems, pkTimeDisagree)
    let swapped = read($(UtcMarch + 2_000_000) & "," & $GpsMarch & "\n",
      [crTime, crGpsMicros], header = false, pattern = EpochMicros)
    doAssert swapped.rows[0].timeUtcUs.get == UtcMarch
    # with GPSTB chosen, a row whose GPSTB is empty, a sentinel, unreadable or outside
    # 1900..2200 has no time, and says so: Time (UTC) is never its instant instead
    let noGps = read("," & $UtcMarch & "\n" & "x," & $(UtcMarch + 10_000_000) & "\n" &
      "-999," & $(UtcMarch + 20_000_000) & "\n" & $high(int64) & "," &
      $(UtcMarch + 30_000_000) & "\n" & $(GpsMarch + 40_000_000) & "," &
      $(UtcMarch + 40_000_000) & "\n", [crGpsMicros, crTime], header = false,
      pattern = EpochMicros)
    for row in 0 .. 3: doAssert noGps.rows[row].timeUtcUs.isNone, $row
    doAssert noGps.rows[4].timeUtcUs.get == UtcMarch + 40_000_000
    doAssert not hasKind(noGps.problems, pkTimeDisagree)
    var said = newSeq[string](5)
    for it in noGps.problems.items:
      doAssert it.col == 0
      said[it.row].add it.text
    doAssert said[0] == "GPSTB missing" and said[2] == "GPSTB missing"
    doAssert said[1] == "GPSTB 'x' is not a whole number; GPSTB missing"
    doAssert "is outside 1900..2200; GPSTB missing" in said[3]
    doAssert said[4] == ""
    let gpsOnly = read("g\n\n" & $GpsMarch & "\n,\n", [crGpsMicros, crText])
    doAssert gpsOnly.rows[0].timeUtcUs.get == UtcMarch
    doAssert gpsOnly.rows[1].timeUtcUs.isNone
    doAssert kindText(gpsOnly.problems, pkNoTime) == "GPSTB missing"
    # neither reads: no time and the usual problem
    let neither = read("x,y\n", [crGpsMicros, crTime], header = false, pattern = EpochMicros)
    doAssert neither.rows[0].timeUtcUs.isNone
    doAssert hasKind(neither.problems, pkBadNumber)
    let mixed = read($GpsMarch & ",\"2024-03-01 00:00:00\"\n",
      [crGpsMicros, crTime], header = false, clock = tcGps)
    doAssert mixed.rows[0].timeUtcUs.get == UtcMarch
    let mixedMsg = kindText(mixed.problems, pkTimeDisagree)
    doAssert "GPS and UTC mixed" in mixedMsg
    doAssert "18 s" in mixedMsg
    let gpsClock = timeOf("2024 061 00:00:00\n", "yyyy ddd hh:mi:ss", clock = tcGps)
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
    # Time (UTC) on the date-time text, GPSTB on its own column, the split ones user defined
    doAssert g.roles[5] == crGpsMicros and g.roles[11] == crTime
    doAssert g.dateTimePattern == "yyyy-mo-dd hh:mi:ss.ffffff"
    for c in 6 .. 10: doAssert g.roles[c] == crText
    doAssert g.names[6] == "year" and g.names[10] == "second"
    doAssert g.roles[18] == crText and g.names[21] == "speed"
    var times = 0
    for r in g.roles:
      if r == crTime: inc times
    doAssert times == 1
    let log = parseShotLog(text, g)
    doAssert log.len == 200 and log.width == 22
    let v = shots(log, g)
    doAssert v.problems.count == 0, v.problems.items[0].text
    doAssert v.rows[0].shotPoint == 1000.0 and v.rows[0].sourceLine == 10.0
    doAssert v.rows[0].timeUtcUs.get == UtcMarch
    doAssert v.rows[199].timeUtcUs.get == UtcMarch + 199 * 10_000_000
    doAssert v.rows[199].shotPoint == 1199.0
    doAssert v.rows[3].sourceDepth.isNaN and v.rows[5].waterDepth.isNaN
    doAssert v.rows[0].x == 1000.0 and v.rows[0].y == 2000.0
    doAssert v.rows[0].texts.len == 9 and v.rows[0].texts[0] == "2024"

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
    discard gpsMicrosToUtcMicros(high(int64))
    let gps = read($high(int64) & "\n", [crGpsMicros], header = false)
    doAssert gps.rows[0].timeUtcUs.isNone
    doAssert hasKind(gps.problems, pkBadNumber)
    const form = "yyyy-mo-dd hh:mi:ss"
    let early = timeOf("1899-12-31 23:59:59\n", form)
    doAssert early.rows[0].timeUtcUs.isNone
    doAssert "1900..2200" in kindText(early.problems, pkBadNumber)
    doAssert timeAt("1900-01-01 00:00:00", form).isSome
    doAssert timeAt("2200-12-31 23:59:59", form).isSome
    let past = timeOf("2201-01-01 00:00:00\n", form)
    doAssert past.rows[0].timeUtcUs.isNone
    doAssert "1900..2200" in kindText(past.problems, pkBadNumber)
    let far = timeOf("10000000000\n", EpochSeconds)
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
    const form = "yyyy-mo-dd hh:mi:ss.f uuuuuu"
    let clash = timeOf("2024-03-01 00:00:59.5 0\n", form)
    doAssert clash.rows[0].timeUtcUs.get == UtcMarch + 59_000000
    doAssert hasKind(clash.problems, pkTimeDisagree)
    let named = kindText(clash.problems, pkTimeDisagree)
    doAssert "500000" in named and "microsecond 0" in named
    let same = timeOf("2024-03-01 00:00:59.5 500000\n", form)
    doAssert same.rows[0].timeUtcUs.get == UtcMarch + 59_500000
    doAssert not hasKind(same.problems, pkTimeDisagree)
    let supplied = timeOf("2024-03-01 00:00:59 500000\n", form)
    doAssert supplied.rows[0].timeUtcUs.get == UtcMarch + 59_500000
    doAssert not hasKind(supplied.problems, pkTimeDisagree)
    let close = timeOf("2024-03-01 00:00:59.000001 0\n", form)
    doAssert close.rows[0].timeUtcUs.get == UtcMarch + 59_000000
    doAssert not hasKind(close.problems, pkTimeDisagree)

  block yearPivot:
    const form = "yy-mo-dd hh:mi:ss"
    let full = timeAt("2016-03-01 00:00:00", "yyyy-mo-dd hh:mi:ss")
    doAssert timeAt("16-03-01 00:00:00", form) == full
    for (yy, year) in [("50", 1950), ("49", 2049), ("99", 1999), ("00", 2000)]:
      doAssert timeAt(yy & "-01-01 00:00:00", form) ==
        timeAt($year & "-01-01 00:00:00", "yyyy-mo-dd hh:mi:ss"), yy
    # a four-digit year is four digits, and a two-digit year two
    doAssert timeAt("16-03-01 00:00:00", "yyyy-mo-dd hh:mi:ss").isNone
    doAssert timeAt("2016-03-01 00:00:00", form).isNone
    doAssert timeAt("216-03-01 00:00:00", "yyyy-mo-dd hh:mi:ss").isNone

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
    var m = mapOf([crTime], dlSemicolon, header = false)
    m.decimalComma = true
    m.dateTimePattern = "yyyy-mo-dd hh:mi:ss.f"
    let sec = shots(parseShotLog("2024-03-01 00:00:59,5\n", m), m)
    doAssert sec.rows[0].timeUtcUs.get == UtcMarch + 59_500000
    m.roles = @[crTime]
    m.dateTimePattern = EpochSeconds
    let epochComma = shots(parseShotLog("1709251200,25\n", m), m)
    doAssert epochComma.rows[0].timeUtcUs.get == UtcMarch + 250_000
    m.sentinels = @["-999.25"]
    m.roles = @[crShotPoint]
    let missing = shots(parseShotLog("1,5\n-999,25\n", m), m)
    doAssert missing.rows[0].shotPoint == 1.5
    doAssert missing.rows[1].shotPoint.isNaN
    doAssert not hasKind(missing.problems, pkBadNumber)

  block leapSecond:
    const form = "yyyy-mo-dd hh:mi:ss"
    let leap = timeOf("2024-03-01 00:00:60\n", form)
    let next = timeOf("2024-03-01 00:01:00\n", form)
    doAssert leap.rows[0].timeUtcUs.get == UtcMarch + 60_000000
    doAssert leap.rows[0].timeUtcUs.get == next.rows[0].timeUtcUs.get
    doAssert "has second 60" in kindText(leap.problems, pkBadNumber)
    let ordinary = timeOf("2024-03-01 00:00:59\n", form)
    doAssert ordinary.rows[0].timeUtcUs.get == UtcMarch + 59_000000
    doAssert "second 60" notin kindText(ordinary.problems, pkBadNumber)

  block badTime:
    let v = timeOf("2024 361 23:59:60\n2024 361 23:59:xx\n", "yyyy ddd hh:mi:ss")
    doAssert v.rows[0].timeUtcUs.isSome
    doAssert v.rows[1].timeUtcUs.isNone
    var found = false
    for it in v.problems.items:
      if it.row == 1:
        doAssert it.text == "time '2024 361 23:59:xx' does not match yyyy ddd hh:mi:ss"
        doAssert it.col == 0
        found = true
    doAssert found
    let nonsense = timeOf("2024-13-40 00:00:00\n", "yyyy-mo-dd hh:mi:ss")
    doAssert "is not a valid date and time" in kindText(nonsense.problems, pkBadNumber)
    let unknown = timeOf("hello\n")
    doAssert unknown.rows[0].timeUtcUs.isNone
    doAssert unknown.problems.items[0].kind == pkNoTime
    let word = read("sp\nabc\n", [crShotPoint])
    doAssert kindText(word.problems, pkBadNumber) == "SourcePoint 'abc' is not a number"

  block guessRules:
    # a column of GPS microseconds is GPSTB when its header says GPS, and reads right
    for header in ["GPSTB", "GPS TB", "GPS time", "TB", "GPS Time Break", "Time break"]:
      let text = "FFID," & header & "\n1,1393249473000000\n2,1393249483000000\n"
      let g = guessMap(text)
      doAssert g.roles == @[crFileNumber, crGpsMicros], header
      let v = shots(parseShotLog(text, g), g)
      doAssert v.problems.count == 0, header
      doAssert v.rows[0].timeUtcUs.get == unixUs(2024, 2, 29, 13, 44, 15), header
      doAssert v.rows[1].timeUtcUs.get == unixUs(2024, 2, 29, 13, 44, 25), header
    # a header that says UTC keeps the same 16 digits as UTC: epoch microseconds
    let utcText = "FFID,UTC microseconds\n1,1699913600000000\n2,1699913610000000\n"
    let ug = guessMap(utcText)
    doAssert ug.roles == @[crFileNumber, crTime] and ug.dateTimePattern == EpochMicros
    let uv = shots(parseShotLog(utcText, ug), ug)
    doAssert uv.rows[0].timeUtcUs.get == 1699913600000000'i64 and uv.problems.count == 0
    # GPS seconds under a header that says GPS are not guessed
    let secText = "FFID,GPS Time\n1,1393249473\n2,1393249483\n"
    let gs = guessMap(secText)
    doAssert gs.roles == @[crFileNumber, crText]
    let secLog = parseShotLog(secText, gs)
    doAssert "looks like a time" in timeNote(secLog, gs)
    doAssert shots(secLog, gs).rows[0].timeUtcUs.isNone
    # the guess keeps Time (UTC) only when the pattern reads every sampled row
    const good = "Stamp,FFID\n2024-03-01 00:00:00,1\n2024-03-01 00:00:10,2\n" &
      "2024-03-01 00:00:20,3\n"
    let gg = guessMap(good & "2024-03-01 00:00:30,4\n")
    doAssert gg.roles == @[crTime, crFileNumber]
    doAssert gg.dateTimePattern == "yyyy-mo-dd hh:mi:ss"
    for bad in ["not a time", "2024-13-01 00:00:00", "2024/03/01 00:00:30",
        "2024-03-01 00:00:30 +01"]:
      let gb = guessMap(good & bad & ",4\n")
      doAssert gb.roles == @[crText, crFileNumber], bad
      doAssert gb.dateTimePattern == "", bad
    # a row whose value does not read does not keep the others from deciding the form
    let lateText = "Time,FFID\n" & "2024-03-01 00:00:00,1\n2024-03-01 00:00:10,2\n" &
      "2024-03-01 25:00:00,3\n"
    let late = guessMap(lateText)
    doAssert late.roles == @[crTime, crFileNumber]
    doAssert late.dateTimePattern == "yyyy-mo-dd hh:mi:ss"
    let lv = shots(parseShotLog(lateText, late), late)
    doAssert lv.rows[1].timeUtcUs.get == UtcMarch + 10_000_000 and lv.rows[2].timeUtcUs.isNone
    doAssert kindText(lv.problems, pkBadNumber) ==
      "time '2024-03-01 25:00:00' is not a valid date and time"
    # a header that says time over a form that cannot be decided: Time (UTC), no pattern
    let amb = "Time,FFID\n01/03/24 10:00:00,1\n02/03/24 10:00:00,2\n"
    let ga = guessMap(amb)
    doAssert ga.roles == @[crTime, crFileNumber] and ga.dateTimePattern == ""
    let ambLog = parseShotLog(amb, ga)
    doAssert timeNote(ambLog, ga) == UndecidedTime
    let av = shots(ambLog, ga)
    doAssert av.rows[0].timeUtcUs.isNone and av.problems.count == 1
    # a header that says time over cells that are not one
    let elapsed = guessMap("Time,FFID\n1,1\n2,2\n3,3\n")
    doAssert elapsed.roles == @[crText, crFileNumber]
    # one Time (UTC): the first column that reads, the other user defined
    let two = guessMap("Start,End,FFID\n2024-03-01 00:00:00,2024-03-01 00:00:05,1\n" &
      "2024-03-01 00:00:10,2024-03-01 00:00:15,2\n")
    doAssert two.roles == @[crTime, crText, crFileNumber]
    doAssert two.names[1] == "End"
    # a typed map that names two Time (UTC) columns is refused in words
    doAssert "Time (UTC) is chosen for more than one column" in
      mapFault(mapOf([crTime, crTime]))
    # the time spread over several columns: none is Time (UTC), and it is said once
    let splitText = "Year,Day of year,Hour,Minute,Second,FFID\n2024,61,0,0,0,1\n" &
      "2024,61,0,0,10,2\n"
    let sg = guessMap(splitText)
    doAssert sg.roles == @[crText, crText, crText, crText, crText, crFileNumber]
    doAssert sg.names[0] == "Year" and sg.names[4] == "Second"
    doAssert sg.timeSplit == tsFound
    let splitLog = parseShotLog(splitText, sg)
    doAssert timeNote(splitLog, sg) == SplitTimeFound
    doAssert SplitTimeFound == "This log's time is spread over several columns. " &
      "Choose GPSTB, or add one Time (UTC) column to the file."
    let sv = shots(splitLog, sg)
    doAssert sv.rows[0].timeUtcUs.isNone
    doAssert sv.problems.count == 1 and sv.problems.items[0].kind == pkNoTime
    doAssert sv.problems.items[0].text == SplitTimeFound
    # with GPSTB chosen its rows have a time and nothing is said
    var withGps = sg
    withGps.roles[5] = crGpsMicros
    let gv = shots(parseShotLog("Year,Day of year,Hour,Minute,Second,GPS\n2024,61,0,0,0," &
      $GpsMarch & "\n", withGps), withGps)
    doAssert gv.rows[0].timeUtcUs.get == UtcMarch and gv.problems.count == 0
    doAssert timeNote(splitLog, withGps) == ""

  block microsAsked:
    # 16 digits are GPS or Unix microseconds, and the number cannot tell which: under a
    # header that says neither nothing is read until the user chooses
    let unix = 1_690_000_000_000_000'i64 ## 2023-07-22 04:26:40 UTC
    for header in ["Time", "Timestamp", "Date Time", "Counter"]:
      let text = "FFID," & header & "\n1," & $unix & "\n2," & $(unix + 10_000_000) & "\n"
      let g = guessMap(text)
      doAssert g.roles == @[crFileNumber, crText], header
      doAssert g.dateTimePattern == "", header
      let log = parseShotLog(text, g)
      let ask = "\"" & header & "\" holds microsecond times, GPS or Unix: choose GPSTB or " &
        "Time (UTC)."
      doAssert timeNote(log, g) == ask, header
      let v = shots(log, g)
      doAssert v.rows[0].timeUtcUs.isNone and v.rows[1].timeUtcUs.isNone, header
      doAssert v.problems.count == 1 and v.problems.items[0].kind == pkNoTime, header
      doAssert v.problems.items[0].text == ask and v.problems.items[0].row == -1, header
      # chosen as GPSTB it is GPS; chosen as Time (UTC) the pattern is typed
      var gps = g
      gps.roles[1] = crGpsMicros
      let gv = shots(log, gps)
      doAssert gv.rows[0].timeUtcUs.get == gpsMicrosToUtcMicros(unix), header
      doAssert gv.problems.count == 0, header
      var utc = g
      utc.roles[1] = crTime
      let undecided = shots(log, utc)
      doAssert undecided.rows[0].timeUtcUs.isNone, header
      doAssert undecided.problems.items[0].text == UndecidedNumbers, header
      doAssert timeNote(log, utc) == UndecidedNumbers, header
      utc.dateTimePattern = EpochMicros
      doAssert shots(log, utc).rows[0].timeUtcUs.get == unix, header
    # a header that says UTC, Unix, epoch or posix: epoch microseconds
    for header in ["UTC microseconds", "Unix time us", "Epoch", "Time (UTC)", "posix",
        "Shot time UTC"]:
      let text = "FFID," & header & "\n1," & $unix & "\n"
      let g = guessMap(text)
      doAssert g.roles == @[crFileNumber, crTime] and g.dateTimePattern == EpochMicros, header
      doAssert shots(parseShotLog(text, g), g).rows[0].timeUtcUs.get == unix, header
    # with a time chosen elsewhere nothing is asked
    let other = "FFID,GPSTB,Counter\n1," & $GpsMarch & "," & $unix & "\n"
    let og = guessMap(other)
    doAssert og.roles == @[crFileNumber, crGpsMicros, crText]
    doAssert shots(parseShotLog(other, og), og).problems.count == 0
    doAssert timeNote(parseShotLog(other, og), og) == ""

  block secondsAsked:
    # ten digits are GPS or Unix seconds: GPS seconds of 2024-02-24 read as Unix seconds
    # would be 2014, so seconds are proposed only under a header that says UTC
    for header in ["Time", "Timestamp", "Shot time"]:
      let text = "FFID," & header & "\n1,1393249473\n2,1393249483\n"
      let g = guessMap(text)
      doAssert g.roles == @[crFileNumber, crText] and g.dateTimePattern == "", header
      let log = parseShotLog(text, g)
      let ask = "\"" & header & "\" holds seconds, GPS or Unix: choose Time (UTC) and " &
        "type epoch seconds if they are Unix seconds; GPS seconds are not read."
      doAssert timeNote(log, g) == ask, header
      let v = shots(log, g)
      doAssert v.rows[0].timeUtcUs.isNone and v.rows[1].timeUtcUs.isNone, header
      doAssert v.problems.count == 1 and v.problems.items[0].text == ask, header
      var utc = g
      utc.roles[1] = crTime
      doAssert shots(log, utc).problems.items[0].text == UndecidedNumbers, header
      utc.dateTimePattern = EpochSeconds
      doAssert shots(log, utc).rows[0].timeUtcUs.get == 1_393_249_473_000_000'i64, header
    for header in ["UTC seconds", "Unix time", "Epoch seconds", "Time (UTC)"]:
      let text = "FFID," & header & "\n1,1709251200.5\n"
      let g = guessMap(text)
      doAssert g.roles == @[crFileNumber, crTime] and g.dateTimePattern == EpochSeconds, header
      doAssert shots(parseShotLog(text, g), g).rows[0].timeUtcUs.get == UtcMarch + 500_000
    # with no header the numbers are not guessed, and nothing is asked of a plain number
    let bare = "1,1709251200\n2,1709251210\n"
    let bg = guessMap(bare)
    doAssert bg.roles == @[crText, crText]
    doAssert shots(parseShotLog(bare, bg), bg).problems.count == 0

  block optionalFraction:
    # a fraction on some rows only, or a Z on some: one form, the fraction optional
    doAssert detectTimePattern(["2024-02-29T13:14:15.5Z", "2024-02-29T13:14:16Z"]) ==
      "yyyy-mo-ddThh:mi:ss.ffffffZ"
    doAssert detectTimePattern(["2024-03-01 10:00:00", "2024-03-01 10:00:00.250"]) ==
      "yyyy-mo-dd hh:mi:ss.ffffff"
    doAssert detectTimePattern(["2024-03-01T10:00:00Z", "2024-03-01T10:00:01"]) ==
      "yyyy-mo-ddThh:mi:ss"
    let g = guessMap("Time,FFID\n2024-03-01 00:00:00,1\n2024-03-01 00:00:10.5,2\n")
    doAssert g.roles == @[crTime, crFileNumber]
    doAssert g.dateTimePattern == "yyyy-mo-dd hh:mi:ss.ffffff"
    # an older project's date-time text column reads every row as before
    var old = initShotLogMap()
    old.hasHeader = false
    doAssert applyRoleNames(old, ["date-time text", "file number"], []) == ""
    let v = shots(parseShotLog("2024-02-29T13:14:15.5Z,1\n2024-02-29T13:14:16Z,2\n" &
      "2024-02-29T13:14:17Z,3\n", old), old)
    let feb = unixUs(2024, 2, 29, 13, 14, 15)
    doAssert v.rows[0].timeUtcUs == some(feb + 500_000)
    doAssert v.rows[1].timeUtcUs == some(feb + 1_000_000)
    doAssert v.rows[2].timeUtcUs == some(feb + 2_000_000)
    doAssert v.problems.count == 0

  block shapesDecide:
    # the form is decided from the rows' shapes: a row that has the form but not a
    # date (30 February, day 366 of a common year) is a problem on that row
    for (cells, pat) in [(@["2024-02-30 13:14:15", "2024-02-29 13:14:15"],
        "yyyy-mo-dd hh:mi:ss"), (@["2023 366 00:00:00", "2024 366 00:00:00"],
        "yyyy ddd hh:mi:ss")]:
      doAssert detectTimePattern(cells) == pat, $cells
      let v = timeOf(cells.join("\n") & "\n")
      doAssert v.rows[0].timeUtcUs.isNone and v.rows[1].timeUtcUs.isSome, $cells
      doAssert v.problems.count == 1 and v.problems.items[0].row == 0, $cells
      doAssert v.problems.items[0].kind == pkBadNumber, $cells
    # a month above 12 may be a day: the order cannot be told, so nothing is proposed
    doAssert detectTimePattern(["2024-02-03 10:00:00", "2024-13-02 10:00:00"]) == ""
    # 24:00:00 is 00:00:00 of the next day; any later time of hour 24 is not a time
    doAssert timeAt("2024-02-29T24:00:00", "") == some(UtcMarch)
    doAssert timeAt("2024-12-30 24:00:00", "yyyy-mo-dd hh:mi:ss") == some(UtcDec31)
    doAssert timeAt("2024 366 24:00:00", "yyyy ddd hh:mi:ss") == some(UtcJan1)
    doAssert timeAt("2024-02-29 24:00:01", "yyyy-mo-dd hh:mi:ss").isNone
    doAssert timeAt("2024-02-29 24:01:00", "yyyy-mo-dd hh:mi:ss").isNone
    doAssert timeAt("2024-02-29 24:00:00.5", "yyyy-mo-dd hh:mi:ss.f").isNone

  block spacesInHeader:
    # the header names hold spaces, so a header cut at spaces has more fields
    # than the rows have columns; the log carries the fitted names
    let text = "Sail line Shot point Year Day of year Hour Minute Second\n" &
      "5 1001 2024 361 23 59 59.5\n6 1002 2024 361 23 59 59.75\n"
    let g = guessMap(text)
    doAssert g.delimiter == dlSpaces and g.hasHeader
    doAssert g.roles == @[crSailLine, crShotPoint, crText, crText, crText, crText, crText]
    doAssert g.timeSplit == tsFound
    let log = parseShotLog(text, g)
    doAssert log.len == 2 and log.width == 7 and log.problems.count == 0
    var named: seq[string] = @[]
    for c in 0 ..< log.width: named.add log.columnName(c)
    doAssert named == @["Sail line", "Shot point", "Year", "Day of year", "Hour", "Minute",
      "Second"]
    doAssert g.names[3] == "Day of year"
    let v = shots(log, g)
    doAssert v.rows[0].sailLine == 5.0 and v.rows[0].shotPoint == 1001.0
    doAssert v.rows[0].timeUtcUs.isNone and v.problems.count == 1
    # the same header over rows whose names the guess cannot place: never a piece of a name
    let unplaced = "Alpha beta gamma delta\n1 2 3\n4 5 6\n"
    let up = guessMap(unplaced)
    doAssert up.roles == @[crText, crText, crText]
    doAssert up.names == @["Column 1", "Column 2", "Column 3"]
    let upLog = parseShotLog(unplaced, up)
    for c in 0 ..< 3: doAssert upLog.columnName(c) == "Column " & $(c + 1)
    doAssert columnNames(upLog, up, 3) == @["Column 1", "Column 2", "Column 3"]

  block fittedNames:
    # a header cut at spaces, fitted: each column keeps its own name
    let text = "SEQ FFID Year Day of year Hour Minute Second Sail Line Shot Point X Y\n" &
      "1 1001 2024 060 13 14 15.0 7 1001 500000.0 6000000.0\n"
    let g = guessMap(text)
    doAssert g.roles == @[crSequence, crFileNumber, crText, crText, crText, crText,
      crText, crSailLine, crShotPoint, crX, crY]
    let log = parseShotLog(text, g)
    var named: seq[string] = @[]
    for c in 0 ..< log.width: named.add log.columnName(c)
    doAssert named == @["SEQ", "FFID", "Year", "Day of year", "Hour", "Minute", "Second",
      "Sail Line", "Shot Point", "X", "Y"]
    doAssert log.cell(0, 7) == "7" and log.columnName(7) == "Sail Line"
    doAssert log.columnName(9) == "X"
    # the fit fails: every column is "Column N", none a shifted fragment
    let odd = "SEQ Alpha beta FFID Gamma delta\n1 2 3 4\n"
    let og = guessMap(odd)
    let oLog = parseShotLog(odd, og)
    for c in 0 ..< oLog.width: doAssert oLog.columnName(c) == "Column " & $(c + 1)
    doAssert og.roles == @[crText, crText, crText, crText]

  block headerAndRowsDiffer:
    # a trailing delimiter: the header's names and roles stay, the rest is "Column N"
    let trailing = "SEQ,FFID,X,Y\n1,1001,1.5,2.5,\n2,1002,1.5,2.5,\n"
    let g = guessMap(trailing)
    doAssert g.roles == @[crSequence, crFileNumber, crX, crY, crText]
    doAssert g.names[4] == "Column 5"
    # rows with more columns than the header names
    let more = "SEQ,FFID\n1,1001,1.5,2.5\n2,1002,1.5,2.5\n"
    let gm = guessMap(more)
    doAssert gm.roles == @[crSequence, crFileNumber, crText, crText]
    doAssert gm.names[2] == "Column 3" and gm.names[3] == "Column 4"
    # a header with more names than the rows: the leading names
    let fewer = "SEQ,FFID,Extra,X,Y\n1,1001,1.5,2.5\n2,1002,1.5,2.5\n"
    let gf = guessMap(fewer)
    doAssert gf.roles == @[crSequence, crFileNumber, crText, crX]
    doAssert gf.names[2] == "Extra"
    # the same with rows cut at spaces
    let spaced = "SEQ FFID\n1 1001 1.5 2.5\n"
    let gs = guessMap(spaced)
    doAssert gs.roles[0] == crSequence and gs.roles[1] == crFileNumber and gs.roles.len == 4
    let sLog = parseShotLog(spaced, gs)
    doAssert sLog.columnName(0) == "SEQ" and sLog.columnName(1) == "FFID"
    doAssert sLog.columnName(2) == "Column 3" and sLog.columnName(3) == "Column 4"

  block nameKeys:
    # a name in another script has a key of its own; punctuation alone has none
    doAssert nameKey("Source Line") == "sourceline"
    doAssert nameKey("Ｘ").len > 0 and nameKey("Х").len > 0
    doAssert nameKey("Ｘ") != nameKey("Х") and nameKey("Х") != nameKey("X")
    doAssert nameKey("...") == "" and nameKey(" - ") == ""
    doAssert not isSystemName("Ｘ") and not isSystemName("Х")
    doAssert nameFault("Ｘ") == "" and nameFault("Х") == ""
    for bad in ["...", "!!!", " - ", "()"]:
      doAssert "needs a letter or a digit" in nameFault(bad), bad
    doAssert nameFault("") == "A user defined column needs a name."
    var m = mapOf([crText, crText, crText, crText])
    m.names = @["...", "!!!", "Ｘ", "Х"]
    let faults = nameProblems(m)
    doAssert faults.len == 2 and faults[0].col == 0 and faults[1].col == 1
    for f in faults:
      doAssert "needs a letter or a digit" in f.why
      doAssert "Another column" notin f.why
    m.names = @["", "", "Ｘ", "Х"]
    doAssert nameProblems(m).len == 0 and mapFault(m) == ""
    m.names = @["", "", "Ｘ", "Ｘ"]
    doAssert "Another column is named" in mapFault(m)
    # a header of punctuation is named by its column
    let punct = parseShotLog("...,---\n1,2\n", dlComma)
    let pm = mapOf([crText, crText])
    doAssert columnNames(punct, pm, 2) == @["Column 1", "Column 2"]

  block oldMaps:
    # a project saved before the system columns were named: one Time (UTC) column
    var m = initShotLogMap()
    var old = @["file number", "UTC microseconds", "gun array", "text", "ignored", "X"]
    doAssert applyRoleNames(m, old, []) == ""
    doAssert m.roles == @[crFileNumber, crTime, crText, crText, crIgnored, crX]
    doAssert m.dateTimePattern == EpochMicros
    doAssert m.names == @["", "", "gun array", "", "", ""]
    doAssert m.timeSplit == tsNone
    # split columns are no longer a source: user defined, named by the old word
    var split = initShotLogMap()
    split.hasHeader = false
    let parts = ["year", "day of year", "hour", "minute", "second", "microsecond", "volume"]
    doAssert applyRoleNames(split, parts, []) == ""
    doAssert split.roles == @[crText, crText, crText, crText, crText, crText, crText]
    doAssert split.names == @["year", "day of year", "hour", "minute", "second",
      "microsecond", "volume"]
    doAssert split.timeSplit == tsOld and split.dateTimePattern == ""
    let oldRead = shots(parseShotLog("2024,61,0,0,59.5,0,7\n", split), split)
    doAssert oldRead.rows[0].timeUtcUs.isNone
    doAssert oldRead.problems.count == 1 and oldRead.problems.items[0].kind == pkNoTime
    doAssert oldRead.problems.items[0].text == SplitTimeOld
    doAssert oldRead.problems.items[0].text == "This log's time was read from several " &
      "columns before; that is no longer done. Choose GPSTB or one Time (UTC) column."
    doAssert oldRead.problems.items[0].row == -1
    # with GPS microseconds it has its instants, and says nothing
    var withGps = initShotLogMap()
    withGps.hasHeader = false
    doAssert applyRoleNames(withGps, ["GPS microseconds", "year", "day of year", "hour",
      "minute", "second"], []) == ""
    doAssert withGps.roles == @[crGpsMicros, crText, crText, crText, crText, crText]
    let gv = shots(parseShotLog($GpsMarch & ",2024,61,0,0,0\n", withGps), withGps)
    doAssert gv.rows[0].timeUtcUs.get == UtcMarch and gv.problems.count == 0
    # a Time (UTC) source with split fields beside it: the source stays
    var both = initShotLogMap()
    both.hasHeader = false
    doAssert applyRoleNames(both, ["year", "UTC seconds", "day of year"], []) == ""
    doAssert both.roles == @[crText, crTime, crText] and both.dateTimePattern == EpochSeconds
    doAssert both.timeSplit == tsNone
    # the order of the older sources: UTC microseconds, UTC seconds, date-time text;
    # of the same kind, the first column
    var order = initShotLogMap()
    doAssert applyRoleNames(order, ["date-time text", "UTC seconds", "UTC microseconds",
      "UTC microseconds"], []) == ""
    doAssert order.roles == @[crText, crText, crTime, crText]
    doAssert order.dateTimePattern == EpochMicros
    doAssert order.names == @["date-time text", "UTC seconds", "", "UTC microseconds"]
    var sec = initShotLogMap()
    doAssert applyRoleNames(sec, ["date-time text", "UTC seconds", "UTC seconds"], []) == ""
    doAssert sec.roles == @[crText, crTime, crText] and sec.dateTimePattern == EpochSeconds
    var txt = initShotLogMap()
    txt.dateTimePattern = "yyyy/mm/dd hh:mm:ss"
    doAssert applyRoleNames(txt, ["date-time text", "date-time text"], []) == ""
    doAssert txt.roles == @[crTime, crText]
    doAssert txt.dateTimePattern == "yyyy/mo/dd hh:mi:ss"
    # each single-column source reads as the earlier reader read it
    for (word, text, pattern, want) in [
        ("UTC microseconds", "1709212455123456\n", "", unixUs(2024, 2, 29, 13, 14, 15) + 123_456),
        ("UTC seconds", "1709212455.5\n", "", unixUs(2024, 2, 29, 13, 14, 15) + 500_000),
        ("date-time text", "\"2024-02-29 13:14:15.25\"\n", "", unixUs(2024, 2, 29, 13, 14, 15) +
            250_000),
        ("date-time text", "\"29/02/2024 13:14:15\"\n", "dd/mm/yyyy hh:mm:ss", unixUs(2024, 2, 29,
            13, 14, 15))]:
      var one = initShotLogMap()
      one.hasHeader = false
      one.dateTimePattern = pattern
      doAssert applyRoleNames(one, [word], []) == ""
      let v = shots(parseShotLog(text, one), one)
      doAssert v.rows[0].timeUtcUs == some(want), word
      doAssert v.problems.count == 0, word
    var incomplete = initShotLogMap()
    doAssert applyRoleNames(incomplete, ["year", "hour"], []) == ""
    doAssert incomplete.roles == @[crText, crText]
    doAssert incomplete.names == @["year", "hour"]
    var fresh = initShotLogMap()
    doAssert applyRoleNames(fresh, ["Time (UTC)", "User defined", "SEQ"], ["", "Note"]) == ""
    doAssert fresh.roles == @[crTime, crText, crSequence] and fresh.names[1] == "Note"
    doAssert applyRoleNames(fresh, ["no such role"], []) == "no such role"
    # a map that already says Time (UTC) on several columns keeps the first
    var several = initShotLogMap()
    several.dateTimePattern = "yyyy ddd hh mi ss"
    doAssert applyRoleNames(several, ["Time (UTC)", "Time (UTC)", "SEQ"], []) == ""
    doAssert several.roles == @[crTime, crText, crSequence]
    doAssert several.dateTimePattern == ""

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
    doAssert "Time (UTC) is chosen for more than one column" in mapFault(m)
    m.roles = @[crTime, crText, crText, crText]
    doAssert mapFault(m) == ""
    for bad in ["sourceline", "Source Line", "water_depth", "WATER-DEPTH", "SourceID",
        "time (utc)", "Uphole", "ignore", "FFID"]:
      doAssert isSystemName(bad), bad
    doAssert not isSystemName("Depth 2") and not isSystemName("Note")
    # a header that uses a system name for a user defined column
    var named = mapOf([crText, crText])
    let withHeader = parseShotLog("Depth,Depth\n1,2\n", named)
    doAssert columnNames(withHeader, named, 2) == @["Depth (file)", "Depth (file) 2"]

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
