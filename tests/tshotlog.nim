## A shot log kept as one text plus a field index, a column map, one UTC
## instant per row, and cell overlays that do not rewrite the text.
##
## Seen to fail: with the doubled-quote collapse taken out of `unquoteRange`,
## `quotedFields` still sees two quotes. With `abs(diff) > DisagreeUs` inverted,
## `crossCheck` flags a row whose sources agree. With `toText` appending a
## space when nothing changed, `quotedFields` is no longer byte-identical.

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

  echo "tshotlog ok"

when isMainModule:
  main()
