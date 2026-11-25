## Taking a text header in from the bytes of a file (`view/outputtextimport`),
## without a window: a plain text file with long lines and too many lines (the
## note says how many of each), CRLF line ends, Latin-1 bytes, a 3200-byte
## header in EBCDIC and in ASCII, the start of a SEG-Y file, a file over the
## limit and a file that is not text.
##
## Seen to fail: with the cut left out, "a long line was not cut"; with the
## drop count wrong, the note said "4 lines after line 38"; with the EBCDIC
## header read as plain text, "the EBCDIC header was refused".

import std/[os, strutils]
import parseSEG
import viewSEG/core/outputtext
import viewSEG/view/outputtextimport
import utils/fixtures

func bytesOf(h: SegyTextHeader): string =
  for b in h.data: result.add char(b)

proc main*() =
  block plainLongAndMany:
    var lines: seq[string] = @[]
    for i in 1 .. 43:
      lines.add(if i in {2, 5, 7}: repeat('x', 90) else: "C" & $i & " text")
    let text = lines.join("\n") & "\n"
    let got = importHeader(text, text.len)
    doAssert got.ok, got.why
    let back = got.text.split('\n')
    doAssert back.len == 38, $back.len
    doAssert back[1].len == 80, "a long line was not cut"
    doAssert back[0] == "C1 text"
    doAssert got.note == "3 lines were longer than 80 characters and were cut; " &
      "5 lines after line 38 were dropped.", got.note

  block singular:
    let text = repeat('y', 81) & "\nok\n"
    let got = importHeader(text, text.len)
    doAssert got.note == "1 line was longer than 80 characters and was cut.", got.note

  block crlfAndLatin:
    let text = "C 1 caf\xE9\r\nC 2 two\r\n\r\n"
    let got = importHeader(text, text.len)
    doAssert got.ok, got.why
    doAssert got.text == "C 1 caf\xC3\xA9\nC 2 two", got.text
    doAssert got.note == "2 lines were taken in.", got.note
    let utf = "C 1 caf\xC3\xA9\n"
    doAssert importHeader(utf, utf.len).text == "C 1 caf\xC3\xA9"

  block rawEbcdic:
    var h = initTextHeader(teEbcdic)
    h.text = "C 1 FROM THE FIELD" & repeat(' ', 62) & "C 2 SECOND" & repeat(' ', 70)
    let raw = bytesOf(h)
    doAssert raw.len == 3200
    let got = importHeader(raw, raw.len)
    doAssert got.ok, "the EBCDIC header was refused: " & got.why
    doAssert got.raw and got.encoding == teEbcdic
    let lines = got.text.split('\n')
    doAssert lines[0] == "C 1 FROM THE FIELD", lines[0]
    doAssert lines[1] == "C 2 SECOND"
    doAssert lines.len == 38 or lines.len < 38
    doAssert "EBCDIC" in got.note and "cards 1 to 38" in got.note, got.note

  block rawAscii:
    let h = initTextHeader(teAscii)
    let raw = bytesOf(h)
    let got = importHeader(raw, raw.len)
    doAssert got.ok and got.raw and got.encoding == teAscii, got.why
    doAssert got.text.startsWith("C 1\nC 2\n"), got.text

  block segyFile:
    withFixtures fx:
      let path = fx.surveySegy()
      let size = getFileSize(path)
      let f = open(path)
      var b = newString(ImportLimit + 1)
      b.setLen f.readBuffer(addr b[0], b.len)
      f.close()
      let got = importHeader(b, size)
      doAssert got.ok and got.raw, got.why
      doAssert size > 3600

  block tooBig:
    let text = repeat("C 1 text\n", ImportLimit div 9 + 2)
    let got = importHeader(text.substr(0, ImportLimit), int64(text.len))
    doAssert not got.ok and got.why == ImportTooBig, got.why

  block notText:
    let junk = "abc\x00\x01\x02def"
    doAssert importHeader(junk, junk.len).why == ImportNotText
    doAssert importHeader("", 0).why == ImportEmpty
    doAssert importHeader("\n\n  \n", 5).why == ImportEmpty

  block longFilesAreNotAllHeaders:
    # a binary with one control byte, a UTF-16 file and a report with a form feed
    # were all taken for a SEG-Y text header; only a header followed by the binary
    # header (or started as EBCDIC "C ") is one
    var png = "\x89PNG\r\n\x1A\n"
    for i in 0 .. 5000: png.add char((i * 37 + 1) mod 255 + 1)
    let a = importHeader(png, png.len)
    doAssert not a.ok and not a.raw, "a binary file was imported"
    var u = "\xFF\xFE"
    for n in 1 .. 300:
      for c in "line " & $n & "\n":
        u.add c
        u.add '\0'
    let b = importHeader(u, u.len)
    doAssert not b.ok and b.why == ImportUtf16, b.why
    var u2 = ""
    for n in 1 .. 300:
      for c in "line " & $n & "\n":
        u2.add c
        u2.add '\0'
    doAssert importHeader(u2, u2.len).why == ImportUtf16
    var p = ""
    for n in 1 .. 400: p.add "report line " & $n & "\n"
    p[2000] = '\f'
    let c = importHeader(p, p.len)
    doAssert not c.raw, "a text report was taken for a text header"

  block headerThenBinary:
    var h = initTextHeader(teAscii)
    h.text = "C 1 HELLO" & repeat(' ', 71)
    var seg = bytesOf(h) & "\x00\x01\x00\x00" & repeat('\0', 396) & repeat('\1', 500)
    let g = importHeader(seg, seg.len)
    doAssert g.ok and g.raw, "an ASCII header with its binary header was refused"
    var allZero = bytesOf(h) & repeat('\0', 900)
    doAssert importHeader(allZero, allZero.len).raw
    # a header whose binary header holds only EBCDIC blanks still starts as "C "
    var e = initTextHeader(teEbcdic)
    e.text = "C 1 FROM THE FIELD" & repeat(' ', 62)
    let eb = bytesOf(e) & repeat('\x40', 400) & repeat('\x40', 100)
    let r = importHeader(eb, eb.len)
    doAssert r.ok and r.raw and r.encoding == teEbcdic, "the EBCDIC \"C \" start was ignored"

  echo "toutputtextimport: ok"

when isMainModule:
  main()
