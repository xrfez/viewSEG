## The edit state of a text header template (`view/outputtextedit`), without a
## window: a template loaded and read back, a token inserted at the cursor, at
## the end, and into a multi-byte line, the lines and columns counted, the
## problems of the template and of its preview, and the preview filled in
## from a file's values or from sample values.
##
## Seen to fail: with the cursor ignored, `{stem}` landed at the end of the
## text, not inside the line; with the trailing blank lines kept, "a blank
## line at the end counted as a line"; with the preview problem left out, a
## token the file lacks showed no problem.

import std/strutils
import parseSEG
import viewSEG/core/[outputnames, outputtext]
import viewSEG/view/outputtextedit

proc main*() =
  block roundTrip:
    let t = OutputText(name: "Survey", encoding: teAscii, lines: @["C 1 {stem}", "", "C 3"])
    let e = initTextEdit(t)
    doAssert e.text == "C 1 {stem}\n\nC 3" and e.original == "Survey"
    doAssert e.toTemplate == t, "a template changed in the editor's text"
    doAssert e.problem == ""
    doAssert initTextEdit().problem == "An output text needs a name."

  block trailingBlankLines:
    var e = initTextEdit()
    e.name = "a"
    e.text = "C 1\n\n\n"
    doAssert e.lineCount == 1, "a blank line at the end counted as a line"
    doAssert e.toTemplate.lines == @["C 1"]
    e.text = "C 1\r\nC 2\r\n"
    doAssert e.toTemplate.lines == @["C 1", "C 2"], $e.toTemplate.lines

  block insertAtCursor:
    var e = initTextEdit()
    e.text = "C 1 FROM \nC 2"
    let after = e.insertToken("stem", 9)
    doAssert e.text == "C 1 FROM {stem}\nC 2", e.text
    doAssert after == 15, $after
    doAssert e.insertToken("date", -1) == e.text.len
    doAssert e.text.endsWith("C 2{date}"), "no cursor: the end"
    doAssert e.insertToken("file", 999) == e.text.len, "a cursor past the text: the end"
    var m = initTextEdit()
    m.text = "caf\xc3\xa9"
    doAssert m.insertToken("stem", 4) == 3 + 6, "a cursor inside a character"
    doAssert m.text == "caf{stem}\xc3\xa9", m.text

  block limits:
    var e = initTextEdit()
    e.name = "a"
    var many: seq[string] = @[]
    for i in 1 .. MaxTextLines: many.add "C" & $i
    e.text = many.join("\n")
    doAssert e.problem == "" and e.lineCount == MaxTextLines
    doAssert e.lengthNote == "38 of 38 lines, the longest 3 of 80 characters.", e.lengthNote
    e.text.add "\nC39"
    doAssert e.problem == "An output text has at most 38 lines.", e.problem
    e.text = repeat('x', MaxTextLine + 1)
    doAssert e.problem == "Line 1 is longer than 80 characters.", e.problem
    doAssert e.longestLine == 81
    e.text = "{nope}"
    doAssert e.problem == "Line 1 has the token {nope}, which is not one.", e.problem
    doAssert columnRuler().len == MaxTextLine
    doAssert columnRuler()[9] == '1' and columnRuler()[4] == '+' and columnRuler()[0] == '.'

  block tokensListed:
    for info in TextTokens:
      doAssert info.word.len > 0
    doAssert tokenLabel(TextTokens[0]) == "{stem}"
    var width = false
    for info in TextTokens:
      if info.width: width = tokenLabel(info).endsWith(":n}")
    doAssert width

  block previews:
    var e = initTextEdit()
    e.name = "a"
    e.text = "C 1 {stem} R{record:3}\n{vibrator}\n\n"
    let sample = sampleValues(1_795_478_400_000_000'i64)
    let p = previewOf(e, sample, true)
    doAssert p.sample and p.problem == "", p.problem
    doAssert p.lines == @["C 1 file R007", "1"], $p.lines
    var lacking = sample
    lacking.values[npVibrator] = NameValue(state: nvMissing)
    let q = previewOf(e, lacking, false)
    doAssert q.problem == "Line 2: {vibrator} is not in this file.", q.problem
    doAssert not q.sample
    var late = initTextEdit()
    late.name = "a"
    late.text = "{date}"
    doAssert previewOf(late, sample, true).lines == @["2026-11-24"]
    doAssert previewOf(late, sample, true).lines[0].len == 10
    doAssert wantedParts(late) == {}
    late.text = "{sensorSerial}"
    doAssert npSensorSerial in wantedParts(late)

  block names:
    doAssert matchingName(["Survey", "Other"], " survey ")
    doAssert not matchingName(["Survey"], "")
    doAssert not matchingName([], "x")

  echo "toutputtextedit: ok"

when isMainModule:
  main()
