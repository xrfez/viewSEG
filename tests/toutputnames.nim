## File names from a pattern (`core/outputnames`): parts joined by a
## separator, a number padded and never cut, a fraction written with `p`,
## a time in UTC with no colon, a missing or mixed value refused by name.
##
## Seen to fail: with a wider number cut to the pad, `got "345.sgy" wanted
## "12345.sgy"`; with the sign put inside the pad, `got "0004-2.sgy" wanted
## "-00042.sgy"`; with the fraction point left as `.`, `got "1234.5.sgy"
## wanted "1234p5.sgy"`; with `1e15` and NaN written out, `named
## "1000000000000000.sgy" instead of "Source line is not in this file."`;
## with the time written with colons, `got "1969-12-31T23:59:59Z.sgy" wanted
## "19691231T235959Z.sgy"` (the leap day the same way); with a missing value
## written as a word, `named "missing.sgy" instead of "Station is not in this
## file."` and mixed the same; with device names allowed, `named "nul.sgy"`
## and `named "CON.sgy"`; with a `.` in text allowed, `named "a.b.sgy"`; with
## every separator forced to `.`, `got "101.205.007.sgd" wanted
## "101_205_007.sgd"`; with a long name cut, the 181-rune name was written;
## with an empty pattern accepted, `got "" wanted "The name pattern has no
## parts."`; with `patternProblem` returning "", every bad pattern was kept;
## with the pattern's separator left in text, `named "a--1.sgy" instead of
## refusing` (stem `a-` and record 1 is the same leaf as stem `a` and -1);
## with the sign kept on a zero, `got "-0.sgy" wanted "0.sgy"`; with the
## old whole-within-1e-3 window, `got "-0042.sgy" wanted "-0042p0001.sgy"`;
## with zero microseconds omitted, `got "19700101T000000Z.sgy" wanted
## "19700101T000000000000Z.sgy"`; with a dotless extension appended,
## `named "7sgy" instead of refusing`.

import std/[math, strutils, unicode]
import viewSEG/core/outputnames

proc part(kind: NamePartKind; pad = 0; text = ""): NamePart =
  NamePart(kind: kind, pad: pad, text: text)

proc pat(sep: NameSeparator; parts: varargs[NamePart]; name = "Shot"): OutputPattern =
  OutputPattern(name: name, separator: sep, parts: @parts)

proc num(x: float64): NameValue = NameValue(state: nvNumber, number: x)
proc iv(n: int64): NameValue = NameValue(state: nvInt, intValue: n)
proc tv(s: string): NameValue = NameValue(state: nvText, text: s)
proc tm(us: int64; whole = false): NameValue =
  NameValue(state: nvTimeUs, timeUs: us, wholeSeconds: whole)

proc vals(pairs: varargs[(NamePartKind, NameValue)]): NameValues =
  for (k, v) in pairs: result[k] = v

proc expectName(p: OutputPattern; v: NameValues; ext, want: string) =
  let r = render(p, v, ext)
  doAssert r.problem.len == 0, "wanted " & want & " but " & r.problem
  doAssert r.name == want, "got \"" & r.name & "\" wanted \"" & want & "\""
  doAssert ':' notin r.name, r.name
  doAssert r.name.runeLen <= MaxFileNameRunes

proc expectProblem(p: OutputPattern; v: NameValues; ext, sentence: string) =
  let r = render(p, v, ext)
  doAssert r.name.len == 0, "named \"" & r.name & "\" instead of refusing"
  doAssert r.problem == sentence, "got \"" & r.problem & "\" wanted \"" & sentence & "\""

proc main*() =

  block words:
    doAssert partWord(npStem) == "File name"
    doAssert partWord(npText) == "Text"
    doAssert partWord(npRecord) == "Record"
    doAssert partWord(npTime) == "Time"
    doAssert partWord(npSigLine) == "Line"
    doAssert partWord(npSigStation) == "Station"
    doAssert partWord(npSrcLine) == "Source line"
    doAssert partWord(npRcvLine) == "Receiver line"
    doAssert partWord(npSrcPoint) == "Source point"
    doAssert partWord(npRcvPoint) == "Receiver point"
    doAssert partWord(npSrcLine) != partWord(npRcvLine)
    doAssert partWord(npSrcPoint) != partWord(npRcvPoint)
    doAssert partWord(npSrcIndex) != partWord(npRcvIndex)
    for k in NamePartKind:
      doAssert partWord(k).len > 0, $k

  block padNotCut:
    let p = pat(nsDot, part(npRecord, pad = 3))
    expectName(p, vals((npRecord, iv(12345))), ".sgy", "12345.sgy")
    expectName(p, vals((npRecord, iv(42))), ".sgy", "042.sgy")
    expectName(p, vals((npRecord, iv(7))), "", "007")
    expectName(pat(nsDot, part(npRecord, pad = 0)), vals((npRecord, iv(7))), ".sgy", "7.sgy")
    # a zero index is a value, not a blank
    expectName(pat(nsDot, part(npSrcIndex, pad = 2)), vals((npSrcIndex, iv(0))), ".sgy", "00.sgy")

  block negativePadded:
    let p = pat(nsUnderscore, part(npSrcPoint, pad = 5))
    expectName(p, vals((npSrcPoint, iv(-42))), ".sgy", "-00042.sgy")
    expectName(p, vals((npSrcPoint, iv(-123456))), ".sgy", "-123456.sgy")
    # assumed the old "whole within 1e-3" window, which wrote -0042
    expectName(pat(nsDot, part(npRecord, pad = 4)), vals((npRecord, num(-42.0001))),
      ".sgy", "-0042p0001.sgy")

  block noNegativeZero:
    expectName(pat(nsDot, part(npSrcPoint)), vals((npSrcPoint, num(-0.00004))),
      ".sgy", "0.sgy")
    expectName(pat(nsDot, part(npSrcPoint, pad = 3)), vals((npSrcPoint, num(-0.00004))),
      ".sgy", "000.sgy")
    expectName(pat(nsDot, part(npSrcPoint)), vals((npSrcPoint, num(0.0))), ".sgy", "0.sgy")
    expectName(pat(nsDot, part(npSrcPoint, pad = 4)), vals((npSrcPoint, num(-0.0))),
      ".sgy", "0000.sgy")
    expectName(pat(nsDot, part(npSrcPoint)), vals((npSrcPoint, num(-0.5))), ".sgy", "-0p5.sgy")

  block fractionP:
    expectName(pat(nsDot, part(npSrcLine)), vals((npSrcLine, num(1234.5))), ".sgy", "1234p5.sgy")
    expectName(pat(nsDot, part(npSrcLine, pad = 6)), vals((npSrcLine, num(-1234.5))),
      ".sgy", "-001234p5.sgy")
    expectName(pat(nsDot, part(npSrcPoint)), vals((npSrcPoint, num(0.5))), ".sgd", "0p5.sgd")
    expectName(pat(nsDot, part(npSrcPoint)), vals((npSrcPoint, num(-0.5))), ".sgy", "-0p5.sgy")
    expectName(pat(nsDot, part(npSrcPoint, pad = 3)), vals((npSrcPoint, num(0.5))),
      ".sgy", "000p5.sgy")
    # rounded to 4 decimal places, half away from zero; trailing zeros dropped
    expectName(pat(nsDot, part(npRecord)), vals((npRecord, num(1000.001))), ".sgy", "1000p001.sgy")
    expectName(pat(nsDot, part(npRecord)), vals((npRecord, num(1000.0004))), ".sgy",
      "1000p0004.sgy")
    expectName(pat(nsDot, part(npRecord)), vals((npRecord, num(1000.00004))), ".sgy", "1000.sgy")
    expectName(pat(nsDot, part(npRecord)), vals((npRecord, num(10.5))), ".sgy", "10p5.sgy")
    expectName(pat(nsDot, part(npRecord)), vals((npRecord, num(10.00005))), ".sgy", "10p0001.sgy")
    # assumed the old "whole within 1e-3" window: 0.03125 was 0p03125, 10.0009 was 10
    expectName(pat(nsDot, part(npSrcLine)), vals((npSrcLine, num(0.03125))), ".sgy", "0p0313.sgy")
    expectName(pat(nsDot, part(npRecord)), vals((npRecord, num(1.5))), ".sgy", "1p5.sgy")
    expectName(pat(nsDot, part(npRecord)), vals((npRecord, num(10.0009))), ".sgy", "10p0009.sgy")
    expectName(pat(nsDot, part(npRecord)), vals((npRecord, num(42.002))), ".sgy", "42p002.sgy")
    let wide = render(pat(nsDot, part(npRecord)), vals((npRecord, num(1e14))), ".sgy")
    doAssert wide.problem.len == 0 and wide.name == "100000000000000.sgy", wide.name
    doAssert 'e' notin wide.name and 'E' notin wide.name

  block missingFloat:
    let p = pat(nsDot, part(npSrcLine))
    expectProblem(p, vals((npSrcLine, num(1e15))), ".sgy", "Source line is not in this file.")
    expectProblem(p, vals((npSrcLine, num(-1e15))), ".sgy", "Source line is not in this file.")
    expectProblem(p, vals((npSrcLine, num(NaN))), ".sgy", "Source line is not in this file.")
    expectProblem(p, vals((npSrcLine, num(Inf))), ".sgy", "Source line is not in this file.")
    expectProblem(p, vals((npSrcLine, num(-Inf))), ".sgy", "Source line is not in this file.")
    # just under the cut is still a number, written whole
    expectName(p, vals((npSrcLine, num(1e15 - 1.0))), ".sgy", "999999999999999.sgy")

  block timeUtc:
    let p = pat(nsDot, part(npTime, pad = 6)) # pad does not apply
    expectName(p, vals((npTime, tm(0))), ".sgy", "19700101T000000000000Z.sgy")
    expectName(p, vals((npTime, tm(-1_000_000))), ".sgy", "19691231T235959000000Z.sgy")
    expectName(p, vals((npTime, tm(68_169_600_000_000))), ".sgy", "19720229T000000000000Z.sgy")
    expectName(p, vals((npTime, tm(-58_060_800_000_000))), ".sgy", "19680229T000000000000Z.sgy")
    expectName(p, vals((npTime, tm(-58_015_504_000_000))), ".sgy", "19680229T123456000000Z.sgy")
    expectName(p, vals((npTime, tm(1_709_251_199_123_000))), ".sgy", "20240229T235959123000Z.sgy")
    expectName(p, vals((npTime, tm(-877_000))), ".sgy", "19691231T235959123000Z.sgy")
    # whole seconds: the fraction is dropped
    expectName(p, vals((npTime, tm(1_709_251_199_123_000, whole = true))), ".sgy",
      "20240229T235959Z.sgy")
    expectName(p, vals((npTime, tm(0, whole = true))), ".sgy", "19700101T000000Z.sgy")
    # 5000 us is six digits, zeros included; a leap-century day too
    expectName(p, vals((npTime, tm(5_000))), ".sgy", "19700101T000000005000Z.sgy")
    expectName(p, vals((npTime, tm(951_782_400_000_000))), ".sgy", "20000229T000000000000Z.sgy")
    expectName(p, vals((npTime, tm(-2_203_891_200_000_000))), ".sgy", "19000301T000000000000Z.sgy")
    for us in [0'i64, -1_000_000, 68_169_600_000_000, -877_000, 1_709_251_199_123_000]:
      let r = render(p, vals((npTime, tm(us))), ".sgy")
      doAssert r.problem.len == 0 and ':' notin r.name, r.name

  block timeMicros:
    let p = pat(nsDot, part(npTime))
    var names: seq[string] = @[]
    for us in [0'i64, 1, 400, 500, 999]:
      let r = render(p, vals((npTime, tm(us))), "")
      doAssert r.problem.len == 0, r.problem
      names.add r.name
    doAssert names == @[
      "19700101T000000000000Z",
      "19700101T000000000001Z",
      "19700101T000000000400Z",
      "19700101T000000000500Z",
      "19700101T000000000999Z"]
    for i in 0 ..< names.len - 1:
      doAssert names[i] < names[i + 1], names[i] & " then " & names[i + 1]
    var before: seq[string] = @[]
    for us in [-999'i64, -500, -400, -1, 0]:
      let r = render(p, vals((npTime, tm(us))), "")
      doAssert r.problem.len == 0, r.problem
      before.add r.name
    doAssert before == @[
      "19691231T235959999001Z",
      "19691231T235959999500Z",
      "19691231T235959999600Z",
      "19691231T235959999999Z",
      "19700101T000000000000Z"]
    for i in 0 ..< before.len - 1:
      doAssert before[i] < before[i + 1], before[i] & " then " & before[i + 1]
    expectName(p, vals((npTime, tm(999, whole = true))), "", "19700101T000000Z")
    expectName(p, vals((npTime, tm(-1, whole = true))), "", "19691231T235959Z")

  block missingAndMixed:
    expectProblem(pat(nsDot, part(npSigStation)), vals(), ".sgy", "Station is not in this file.")
    expectProblem(pat(nsDot, part(npSigLine)),
      vals((npSigLine, NameValue(state: nvMixed))), ".sgy", "Line is not one value in this file.")
    expectProblem(pat(nsDot, part(npRecord)), vals(), ".sgd", "Record is not in this file.")
    expectProblem(pat(nsHyphen, part(npRcvLine)),
      vals((npRcvLine, NameValue(state: nvMixed))), ".sgy",
      "Receiver line is not one value in this file.")
    expectProblem(pat(nsDot, part(npTime)), vals(), ".sgy", "Time is not in this file.")
    # a label is not a file name: an empty label still renders
    expectName(pat(nsDot, part(npRecord), name = ""), vals((npRecord, iv(3))), ".sgy", "3.sgy")

  block deviceNames:
    for bad in ["CON", "con", "Con", "COM0", "com9", "LPT0", "lpt9", "NUL", "aux", "prn",
        "CONIN$", "conout$"]:
      expectProblem(pat(nsDot, part(npText, text = bad)), vals(), ".sgy",
        "\"" & bad & "\" is a name Windows keeps for a device.")
      expectProblem(pat(nsDot, part(npStem)), vals((npStem, tv(bad))), ".sgy",
        "\"" & bad & "\" is a name Windows keeps for a device.")
    expectProblem(pat(nsDot, part(npStem)), vals((npStem, tv("nul"))), ".sgy",
      "\"nul\" is a name Windows keeps for a device.")
    expectProblem(pat(nsDot, part(npStem)), vals((npStem, tv("NUL"))), "",
      "\"NUL\" is a name Windows keeps for a device.")
    # not a device name
    expectName(pat(nsDot, part(npText, text = "COM10")), vals(), ".sgy", "COM10.sgy")
    expectName(pat(nsDot, part(npText, text = "CONX")), vals(), ".sgy", "CONX.sgy")
    expectName(pat(nsDot, part(npText, text = "LPT")), vals(), ".sgy", "LPT.sgy")

  block textRefused:
    expectProblem(pat(nsDot, part(npText, text = "a.b")), vals(), ".sgy",
      "Text holds a character a file name cannot.")
    expectProblem(pat(nsDot, part(npStem)), vals((npStem, tv("shot.sgy"))), ".sgy",
      "File name holds a character a file name cannot.")
    for c in ['<', '>', ':', '"', '/', '\\', '|', '?', '*', '.']:
      expectProblem(pat(nsDot, part(npText, text = "a" & c & "b")), vals(), ".sgy",
        "Text holds a character a file name cannot.")
    expectProblem(pat(nsDot, part(npText, text = "a\nb")), vals(), ".sgy",
      "Text holds a character a file name cannot.")
    expectProblem(pat(nsDot, part(npText, text = "a\x7Fb")), vals(), ".sgy",
      "Text holds a character a file name cannot.")
    expectProblem(pat(nsDot, part(npText, text = "")), vals(), ".sgy", "Text is empty.")
    expectProblem(pat(nsDot, part(npText, text = " hello")), vals(), ".sgy",
      "Text starts or ends with a space.")
    expectProblem(pat(nsDot, part(npText, text = "hello ")), vals(), ".sgy",
      "Text starts or ends with a space.")
    expectProblem(pat(nsDot, part(npStem)), vals((npStem, tv(""))), ".sgy", "File name is empty.")
    # a space in the middle is a name; so is a letter outside ASCII
    expectName(pat(nsDot, part(npText, text = "line 12")), vals(), ".sgy", "line 12.sgy")
    expectName(pat(nsUnderscore, part(npText, text = "линия")), vals(), ".sgy", "линия.sgy")

  block sensorSerial:
    doAssert partWord(npSensorSerial) == "Sensor serial"
    doAssert NamePartKind.high == npSensorSerial, "the new kind is last"
    let p = pat(nsDot, part(npSensorSerial, pad = 6))
    expectName(p, vals((npSensorSerial, tv("N0042"))), ".sgd", "N0042.sgd")
    expectName(pat(nsUnderscore, [part(npStem), part(npSensorSerial)]),
      vals((npStem, tv("line")), (npSensorSerial, tv("00123"))), ".sgd", "line_00123.sgd")
    expectProblem(p, vals(), ".sgd", "Sensor serial is not in this file.")
    expectProblem(p, vals((npSensorSerial, NameValue(state: nvMixed))), ".sgd",
      "Sensor serial is not one value in this file.")
    expectProblem(p, vals((npSensorSerial, tv("A.B"))), ".sgd",
      "Sensor serial holds a character a file name cannot.")
    expectProblem(pat(nsHyphen, part(npSensorSerial)), vals((npSensorSerial, tv("A-B"))),
      ".sgd", "Sensor serial has the separator - in it.")

  block separatorInText:
    # "a-" & "-" & "1" is the same leaf as "a" & "-" & "-1"; the first is refused.
    let hyphen = pat(nsHyphen, [part(npStem), part(npRecord)])
    let withSep = render(hyphen, vals((npStem, tv("a-")), (npRecord, iv(1))), ".sgy")
    let withSign = render(hyphen, vals((npStem, tv("a")), (npRecord, iv(-1))), ".sgy")
    doAssert withSep.name.len == 0, "named \"" & withSep.name & "\" instead of refusing"
    doAssert withSep.problem == "File name has the separator - in it.", withSep.problem
    doAssert withSign.problem.len == 0, withSign.problem
    doAssert withSign.name == "a--1.sgy", withSign.name
    doAssert withSep.name != withSign.name
    expectProblem(pat(nsUnderscore, part(npText, text = "a_b")), vals(), ".sgy",
      "Text has the separator _ in it.")
    expectProblem(pat(nsUnderscore, part(npStem)), vals((npStem, tv("a_b"))), ".sgy",
      "File name has the separator _ in it.")
    doAssert patternProblem(pat(nsUnderscore, part(npText, text = "a_b"))) ==
      "Text has the separator _ in it."
    doAssert patternProblem(pat(nsHyphen, part(npText, text = "shot-a"))) ==
      "Text has the separator - in it."
    # the other separators, and a dot pattern, still keep a hyphen or underscore
    expectName(pat(nsDot, part(npStem)), vals((npStem, tv("line-12"))), ".sgy", "line-12.sgy")
    expectName(pat(nsDot, part(npStem)), vals((npStem, tv("line_12"))), ".sgy", "line_12.sgy")
    expectName(pat(nsHyphen, part(npStem)), vals((npStem, tv("line_12"))), ".sgy", "line_12.sgy")
    expectName(pat(nsUnderscore, part(npText, text = "line-12")), vals(), ".sgy", "line-12.sgy")
    doAssert patternProblem(pat(nsDot, part(npText, text = "line_12"))) == ""

  block separators:
    let parts = [part(npSigLine), part(npSigStation), part(npController, pad = 3)]
    let v = vals((npSigLine, iv(101)), (npSigStation, iv(205)), (npController, iv(7)))
    expectName(pat(nsDot, parts), v, ".sgd", "101.205.007.sgd")
    expectName(pat(nsUnderscore, parts), v, ".sgd", "101_205_007.sgd")
    expectName(pat(nsHyphen, parts), v, ".sgd", "101-205-007.sgd")
    doAssert $nsDot == "." and $nsUnderscore == "_" and $nsHyphen == "-"

  block length:
    let okStem = repeat("ж", 176)
    doAssert okStem.runeLen == 176 and okStem.len == 352
    expectName(pat(nsDot, part(npText, text = okStem)), vals(), ".sgy", okStem & ".sgy")
    doAssert (okStem & ".sgy").runeLen == 180
    let longStem = repeat("ж", 177)
    expectProblem(pat(nsDot, part(npText, text = longStem)), vals(), ".sgy",
      "The file name is longer than 180 characters.")
    doAssert (longStem & ".sgy").runeLen == 181
    expectName(pat(nsDot, part(npText, text = repeat('a', 176))), vals(), ".sgy",
      repeat('a', 176) & ".sgy")
    expectProblem(pat(nsDot, part(npText, text = repeat('a', 177))), vals(), ".sgy",
      "The file name is longer than 180 characters.")

  block emptyPattern:
    expectProblem(OutputPattern(name: "Shot", separator: nsDot), vals(), ".sgy",
      "The name pattern has no parts.")

  block extension:
    let p = pat(nsDot, part(npRecord))
    let v = vals((npRecord, iv(7)))
    expectProblem(p, v, "sgy", "The extension sgy cannot be used.")
    expectProblem(p, v, ".", "The extension . cannot be used.")
    expectProblem(p, v, " ", "The extension " & " " & " cannot be used.")
    expectProblem(p, v, ".sgy/x", "The extension .sgy/x cannot be used.")
    expectProblem(p, v, "." & repeat('b', 17),
      "The extension ." & repeat('b', 17) & " cannot be used.")
    expectProblem(p, v, "..sgy", "The extension ..sgy cannot be used.")
    expectProblem(p, v, ".sg_y", "The extension .sg_y cannot be used.")
    expectProblem(p, v, ".sgy.txt", "The extension .sgy.txt cannot be used.")
    expectName(p, v, "", "7")
    expectName(p, v, ".sgy", "7.sgy")
    expectName(p, v, ".SGY", "7.SGY")
    expectName(p, v, ".sgy2", "7.sgy2")
    expectName(p, v, ".a", "7.a")
    let sixteen = "." & repeat('a', 16)
    doAssert sixteen.len == 17
    expectName(p, v, sixteen, "7" & sixteen)

  block endsAndLeaf:
    expectProblem(pat(nsDot, part(npRecord)), vals((npRecord, iv(1))), ".",
      "The extension . cannot be used.")
    expectProblem(pat(nsDot, part(npRecord)), vals((npRecord, iv(1))), " ",
      "The extension " & " " & " cannot be used.")
    expectProblem(pat(nsDot, part(npRecord)), vals((npRecord, iv(1))), ".sgy/x",
      "The extension .sgy/x cannot be used.")

  block patternProblems:
    doAssert patternProblem(pat(nsDot, part(npRecord), name = "  Shot  ")) == ""
    doAssert patternProblem(pat(nsDot, part(npRecord), name = "")) == "a name pattern needs a name"
    doAssert patternProblem(pat(nsDot, part(npRecord), name = "   ")) ==
      "a name pattern needs a name"
    doAssert patternProblem(pat(nsDot, part(npRecord), name = "CON")) == ""
    doAssert patternProblem(pat(nsDot, part(npRecord), name = "Line.Station")) == ""
    let longName = repeat("ж", 64)
    doAssert longName.runeLen == 64 and longName.len == 128
    doAssert patternProblem(pat(nsDot, part(npRecord), name = longName)) == ""
    doAssert patternProblem(pat(nsDot, part(npRecord), name = repeat("ж", 65))) ==
      "a name pattern's name is at most 64 characters long"
    doAssert patternProblem(pat(nsDot, part(npRecord), name = "tab\there")) ==
      "a name pattern's name holds no control characters"
    doAssert patternProblem(pat(nsDot, part(npRecord), name = "bad\xFF")) ==
      "a name pattern's name is not text (not UTF-8)"
    var many: seq[NamePart] = @[]
    for i in 0 ..< 16: many.add part(npText, text = $i)
    doAssert patternProblem(pat(nsDot, many)) == ""
    many.add part(npText, text = "x")
    doAssert patternProblem(pat(nsDot, many)) == "a name pattern has at most 16 parts"
    doAssert patternProblem(OutputPattern(name: "Shot", separator: nsDot)) ==
      "a name pattern needs a part"
    doAssert patternProblem(pat(nsDot, part(npRecord, pad = 0))) == ""
    doAssert patternProblem(pat(nsDot, part(npRecord, pad = 12))) == ""
    doAssert patternProblem(pat(nsDot, part(npSrcLine, pad = -1))) ==
      "Source line's width is from 0 to 12"
    doAssert patternProblem(pat(nsDot, part(npRecord, pad = 13))) ==
      "Record's width is from 0 to 12"
    doAssert patternProblem(pat(nsDot, part(npText, text = ""))) == "Text is empty."
    doAssert patternProblem(pat(nsDot, part(npText, text = "a.b"))) ==
      "Text holds a character a file name cannot."
    doAssert patternProblem(pat(nsDot, part(npText, text = " hello"))) ==
      "Text starts or ends with a space."
    doAssert patternProblem(pat(nsDot, part(npText, text = "CON"))) ==
      "\"CON\" is a name Windows keeps for a device."
    doAssert patternProblem(pat(nsDot, part(npText, text = "line-12"))) == ""

  echo "toutputnames: ok"

when isMainModule:
  main()
