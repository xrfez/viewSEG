## The NIF reader and writer of the program's own documents: what is
## written reads back the same (every byte of a string, numbers, nesting);
## both line endings, comments and a byte order mark are read; and a
## damaged, truncated or hostile document raises `NifError`, with its line,
## and nothing else: every cut of a document, 20 000 random mutations of
## one, random bytes, and documents past each bound (size, nesting, nodes,
## words, numbers).
##
## Seen to fail: with `parseNif` not counting nodes, `bounds` read a node
## of 100 000 children; with `stringLit` taking a control byte,
## `controlBytes` read one; with `nifString` leaving `(` raw, `nifkitSafe`
## found it in the output; with the depth check gone, `bounds` read 33
## levels, and 100 000 hit the debug build's call depth limit (a stack
## overflow in release builds).

import std/[random, strutils]
import viewSEG/core/nif

proc sample(): string =
  var w = initNifWriter()
  w.open("settings")
  w.open("version")
  w.add 1'i64
  w.close()
  w.open("theme")
  w.add "C:\\Data (x86)\\a#b:c\"d Données"
  w.close()
  w.open("plot")
  w.open("mode")
  w.ident "wiggleDensity"
  w.close()
  w.open("overlap")
  w.add 1.0
  w.close()
  w.open("gainDb")
  w.add -3.5
  w.close()
  w.open("big")
  w.add 1e300
  w.add -9223372036854775807'i64
  w.close()
  w.open("on")
  w.add true
  w.close()
  w.close()
  w.open("text")
  w.add "[Window][x]\nPos=1,2\n"
  w.close()
  w.close()
  w.finish

proc expectError(text: string; what: string) =
  try:
    discard parseNif(text, "doc")
    doAssert false, what & ": no NifError for " & text.escape
  except NifError as e:
    doAssert e.msg.startsWith("doc"), e.msg

block roundTrip:
  let doc = parseNif(sample(), "doc")
  doAssert doc.len == 3
  doAssert doc[0].isTree(".nif27") and doc[1].isTree(".vendor")
  let s = doc[2]
  doAssert s.isTree("settings") and s.kids.len == 4
  doAssert s.kids[0].kids[0].kind == nkInt and s.kids[0].kids[0].intVal == 1
  doAssert s.kids[1].kids[0].text == "C:\\Data (x86)\\a#b:c\"d Données"
  let plot = s.kids[2]
  doAssert plot.kids[0].kids[0].kind == nkIdent and plot.kids[0].kids[0].text == "wiggleDensity"
  doAssert plot.kids[1].kids[0].kind == nkFloat and plot.kids[1].kids[0].floatVal == 1.0
  doAssert plot.kids[2].kids[0].floatVal == -3.5
  doAssert plot.kids[3].kids[0].floatVal == 1e300
  doAssert plot.kids[3].kids[1].intVal == -9223372036854775807'i64
  doAssert plot.kids[4].kids[0].text == "true"
  doAssert s.kids[3].kids[0].text == "[Window][x]\nPos=1,2\n"
  doAssert s.kids[3].line == 12, $s.kids[3].line

block everyByte:
  var all = ""
  for i in 0 .. 255: all.add char(i)
  for s in [all, "", "\n\n", "\\", "\"\"", "é€😀", "\xff\xfe broken UTF-8"]:
    let doc = parseNif(nifString(s), "doc")
    doAssert doc.len == 1 and doc[0].kind == nkString and doc[0].text == s, s.escape

block nifkitSafe:
  # What other NIF readers refuse raw in a string is written escaped.
  let lit = nifString("()[]{}~'\"\\@\t\r\x01\x7f")
  for c in "()[]{}~'@\t\r\x01\x7f":
    doAssert c notin lit, $c & " in " & lit
  doAssert nifString("#:") == "\"#:\""

block lineEndingsAndComments:
  let unix = sample()
  let windows = unix.replace("\n", "\r\n")
  let a = parseNif(unix, "doc")
  let b = parseNif("\xEF\xBB\xBF; a comment\r\n" & windows & "; trailing", "doc")
  doAssert a.len == b.len
  # A raw line feed in a string reads back as CR LF from the Windows copy.
  doAssert b[2].kids[3].kids[0].text == "[Window][x]\r\nPos=1,2\r\n"
  doAssert b[2].kids[1].kids[0].text == a[2].kids[1].kids[0].text
  doAssert parseNif("(a \"x\\0Ay\" \"x\\ny\" \"\\|\\^\")", "doc")[0].kids[0].text == "x\ny"
  doAssert parseNif("(a \"x\\ny\" \"\\|\\^\")", "doc")[0].kids[1].text == "\\\""

block numbers:
  let doc = parseNif("(n 0 -1 +7 1_000 1.5 -2.5e-3 1e3 3.)", "doc")[0]
  doAssert doc.kids[0].intVal == 0 and doc.kids[1].intVal == -1 and doc.kids[2].intVal == 7
  doAssert doc.kids[3].intVal == 1000
  doAssert doc.kids[4].floatVal == 1.5 and doc.kids[5].floatVal == -2.5e-3
  doAssert doc.kids[6].kind == nkFloat and doc.kids[6].floatVal == 1000
  doAssert doc.kids[7].floatVal == 3
  for bad in ["(n 1e400)", "(n -1e999)", "(n 99999999999999999999)", "(n 1e)", "(n -)",
      "(n 1.2.3)", "(n --1)"]:
    expectError(bad, "bad number")
  doAssert nifFloat(3) == "3.0" and nifFloat(1e20).contains('e')

block controlBytes:
  for c in {'\x00'..'\x1f'} - {'\t', '\r', '\n'}:
    expectError("(a \"x" & c & "y\")", "control byte " & $ord(c))

block damaged:
  for bad in ["(", ")", "(a", "(a))", "(a \"x)", "(a \"x\\", "(a \"\\G0\")",
      "(a \"\\0\")", "(a b@1)", "(a.b c)", "(a 'c')", "(a [b])", "\x01", "(a ~)",
      "(a \"ok\"#c)"]:
    expectError(bad, "damaged")

block truncated:
  # Every cut of a document either reads (a cut between nodes) or raises
  # NifError, and nothing else.
  let text = sample()
  var reads = 0
  for cut in 0 ..< text.len:
    try:
      discard parseNif(text[0 ..< cut], "doc")
      inc reads
    except NifError:
      discard
  doAssert reads > 0 and reads < text.len div 4, $reads

block mutated:
  var rng = initRand(20261114)
  let text = sample()
  const alphabet = "()\" \\\n;.#@-+0123456789eEaZ_\x00\xff"
  for round in 0 ..< 20_000:
    var t = text
    for _ in 0 .. rng.rand(4):
      let at = rng.rand(t.high)
      case rng.rand(2)
      of 0: t[at] = alphabet[rng.rand(alphabet.high)]
      of 1: t.delete(at .. at)
      else: t.insert($alphabet[rng.rand(alphabet.high)], at)
    try:
      discard parseNif(t, "doc")
    except NifError:
      discard

block randomBytes:
  var rng = initRand(7)
  for round in 0 ..< 2000:
    var t = newString(rng.rand(400))
    for c in t.mitems: c = char(rng.rand(255))
    try:
      discard parseNif(t, "doc")
    except NifError:
      discard

block bounds:
  expectError(repeat("(a ", MaxNifDepth + 1) & repeat(")", MaxNifDepth + 1), "too deep")
  discard parseNif(repeat("(a ", MaxNifDepth) & repeat(")", MaxNifDepth), "doc")
  expectError(repeat("(a ", 100_000), "far too deep")
  expectError("(a " & repeat("1 ", MaxNifNodes) & ")", "too many nodes")
  expectError("(" & repeat("a", MaxNifWord + 1) & ")", "a long tag")
  expectError("(a " & repeat("b", MaxNifWord + 1) & ")", "a long identifier")
  expectError("(a " & repeat("1", MaxNifNumber + 1) & ")", "a long number")
  expectError("(a \"" & repeat("x", MaxNifBytes) & "\")", "a large document")
  try:
    discard parseNif(repeat(" ", MaxNifBytes + 1), "doc")
    doAssert false
  except NifError as e:
    doAssert "larger than 4 MB" in e.msg, e.msg

block errorLine:
  try:
    discard parseNif("(a\n (b 1)\n (c \"x\\G\"))", "settings.nif")
    doAssert false
  except NifError as e:
    doAssert e.line == 3 and e.msg.startsWith("settings.nif line 3: bad escape"), e.msg

block idents:
  doAssert isNifIdent("rcvLine") and isNifIdent("_a1")
  for bad in ["", "1a", "a.b", "a-b", "é", repeat("a", MaxNifWord + 1)]:
    doAssert not isNifIdent(bad), bad
