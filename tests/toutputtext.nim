## SEG-Y text header templates (`core/outputtext`): a template's problems in
## one sentence each, every token filled in, `first-last` for a value a file
## does not hold once, a line too long once filled in, a token with no value
## named, `{{` and `}}` as braces, and a character the character set cannot
## hold refused with the library's reason.
##
## Seen to fail: with the 38-line cap at 40, "a 39-line template was kept";
## with the length checks skipped, a line of 81 characters was kept; with an
## unknown token let through, `{nope}` was kept; with the library's character
## check skipped, the ASCII template with an accented letter was kept; with
## a token's mixed value always refused, `{record}` of a file with records 5
## and 9 did not say `5-9`.

import std/[strutils]
import parseSEG
import viewSEG/core/[outputnames, outputtext]

proc tx(lines: varargs[string]): OutputText =
  OutputText(name: "Survey", encoding: teEbcdic, lines: @lines)

proc named(name: string): OutputText = OutputText(name: name, lines: @["x"])

proc ascii(line: string): OutputText =
  OutputText(name: "Survey", encoding: teAscii, lines: @[line])

proc num(x: float64): NameValue = NameValue(state: nvNumber, number: x)
proc iv(n: int64): NameValue = NameValue(state: nvInt, intValue: n)

const Written = 1_795_478_400_000_000'i64 + 3_723_000_000'i64
  ## 2026-11-24 00:00:00 UTC is 1795478400; plus 1 h 2 min 3 s

proc values(): TextValues =
  result.source = "/data/field/L101.sgy"
  result.values[npStem] = NameValue(state: nvText, text: "L101")
  result.values[npRecord] = num(12)
  result.values[npSrcLine] = num(101.5)
  result.values[npVibrator] = iv(7)
  result.values[npTime] = NameValue(state: nvTimeUs, timeUs: 0, wholeSeconds: true)
  result.writtenUs = Written

proc main*() =

  block valid:
    doAssert textProblem(OutputText(name: "a", lines: @["C 1 SURVEY {stem}", "", "{{literal}}"])) == ""
    doAssert textProblem(tx()) == "", "an empty template is a template"

  block nameRules:
    doAssert textProblem(named("  ")) == "An output text needs a name."
    doAssert textProblem(named("\xff")) == "An output text's name is not text (not UTF-8)."
    doAssert textProblem(named(repeat('a', 65))) ==
      "An output text's name is at most 64 characters long."
    doAssert textProblem(named("a\tb")) == "An output text's name holds no control characters."

  block lineRules:
    var many: seq[string] = @[]
    for i in 1 .. 38: many.add "C" & $i
    doAssert textProblem(OutputText(name: "a", lines: many)) == ""
    many.add "C39"
    doAssert textProblem(OutputText(name: "a", lines: many)) ==
      "An output text has at most 38 lines.", "a 39-line template was kept"
    doAssert textProblem(tx(repeat('x', 80))) == ""
    doAssert textProblem(tx("ok", repeat('x', 81))) == "Line 2 is longer than 80 characters."

  block tokenRules:
    doAssert textProblem(tx("{nope}")) == "Line 1 has the token {nope}, which is not one."
    doAssert textProblem(tx("a {stem")) == "Line 1 has a { with no } after it."
    doAssert textProblem(tx("ok", "a } b")) == "Line 2 has a } with no { before it."
    doAssert textProblem(tx("{}")) == "Line 1 has an empty token."
    doAssert textProblem(tx("{record:13}")) == "Line 1: the width in {record:13} is from 0 to 12."
    doAssert textProblem(tx("{record:x}")) == "Line 1: the width in {record:x} is from 0 to 12."
    doAssert textProblem(tx("{stem:3}")) == "Line 1: {stem} takes no width."
    doAssert textProblem(tx("{record:5} {srcLine:0}")) == ""
    doAssert textProblem(tx("{{x}}")) == "", "{{ was read as a token"
    for t in TextTokens:
      doAssert t.about.len > 0 and t.word.len > 0
      doAssert textProblem(tx("{" & t.word & "}")) == "", t.word

  block characters:
    # Latin-1 as UTF-8 is one character a column; EBCDIC holds all of Latin-1.
    doAssert textProblem(tx("caf\xc3\xa9 {stem}")) == ""
    let greek = textProblem(tx("C 1 \xce\xb1"))
    doAssert greek == "Line 1 column 5 holds a character the header cannot hold.",
      greek
    doAssert textProblem(tx("\xff")) == "Line 1 is not text (not UTF-8)."
    # ASCII: the library's reason, with its column.
    let acc = textProblem(ascii("caf\xc3\xa9"))
    doAssert acc == "Line 1 column 4 holds a character ASCII cannot hold.", acc
    let tab = textProblem(ascii("a\tb"))
    doAssert tab == "Line 1 column 2 holds a character the header cannot hold.", tab
    # A control character is refused in either character set.
    for bad in ["a\tb", "a\0b", "a\x7fb", "a\xc2\x85b", "a\xc2\x9fb"]:
      let col = textProblem(tx(bad))
      doAssert col == "Line 1 column 2 holds a character the header cannot hold.", col
      doAssert textProblem(ascii(bad)) == col, "ASCII: " & textProblem(ascii(bad))
    doAssert textProblem(tx("a\xc2\xa0b")) == "", "U+00A0 is not a control character"
    doAssert textProblem(ascii("a {{ b ~")) == ""
    doAssert textProblem(tx("{{ and }}", "a~b")) == ""
    # 80 characters of two bytes each fit.
    doAssert textProblem(tx(repeat("\xc3\xa9", 80))) == ""

  block rendering:
    let v = values()
    doAssert render(tx("{stem}|{file}|{date}|{clock}"), v) ==
      @["L101|L101.sgy|2026-11-24|01:02:03"]
    doAssert render(tx("{record}|{record:5}|{srcLine}|{srcLine:4}"), v) ==
      @["12|00012|101p5|0101p5"]
    doAssert render(tx("{vibrator}|{time}"), v) == @["7|19700101T000000Z"]
    doAssert render(tx("{{{stem}}}"), v) == @["{L101}"]
    doAssert render(tx("a", "", "b"), v) == @["a", "", "b"]
    doAssert renderProblem(tx("{stem} {record}"), v) == ""

  block firstLast:
    var v = values()
    v.values[npRecord] = NameValue(state: nvMixed)
    doAssert renderProblem(tx("{record}"), v) == "Line 1: {record} is not one value in this file."
    v.firstLast[npRecord] = (first: num(5), last: num(9))
    doAssert render(tx("{record}"), v) == @["5-9"], "a mixed value was written as one"
    doAssert render(tx("{record:3}"), v) == @["005-009"]
    doAssert renderProblem(tx("{record}"), v) == ""

  block missing:
    var v = values()
    doAssert renderProblem(tx("ok", "{rcvLine}"), v) == "Line 2: {rcvLine} is not in this file."
    doAssert render(tx("{rcvLine}"), v) == @["{rcvLine}"], "a missing value was replaced"

  block tooLong:
    var v = values()
    v.values[npStem] = NameValue(state: nvText, text: repeat('s', 70))
    doAssert renderProblem(tx("C 1 {stem}"), v) == ""
    doAssert renderProblem(tx("C 1 {stem} ok"), v) == ""
    doAssert renderProblem(tx("C 1 FILE {stem}E"), v) == "", "80 characters fit"
    let long = renderProblem(tx("C 1 FILE {stem}EN"), v)
    doAssert long == "Line 1 is 81 characters long once its tokens are filled in; at most 80 fit.",
      long
    doAssert render(tx("C 1 FILE {stem}EN"), v)[0].len == 81, "a long line was cut"

  block renderedCharacters:
    var v = values()
    v.values[npStem] = NameValue(state: nvText, text: "caf\xc3\xa9")
    let why = renderProblem(tx("{stem}"), v)
    doAssert why == "", why
    var w = values()
    w.values[npStem] = NameValue(state: nvText, text: "\xce\xb1")
    doAssert renderProblem(tx("ab {stem}"), w) ==
      "Line 1 column 4 holds a character the header cannot hold."
    doAssert renderProblem(OutputText(name: "a", encoding: teAscii, lines: @["{stem}"]), v) ==
      "Line 1 column 4 holds a character ASCII cannot hold."

  echo "toutputtext: ok"

when isMainModule:
  main()
