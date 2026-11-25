## Taking a text header in from a file for the Output window's text header
## editor: a plain text file, or the 3200 bytes of a SEG-Y text header (alone,
## or the start of a SEG-Y file), in EBCDIC or ASCII. The functions work on
## the bytes already read; reading the file is the window's job. No toolkit.
##
## The template holds the cards the writer leaves to the person: cards 1 to
## 38 (`MaxTextLines`) of at most 80 characters (`MaxTextLine`); cards 39 and
## 40 are always written by the library. A longer line is cut, lines past 38
## are dropped, and the note says how many. Lines are not padded: the writer
## pads each card.

import std/[sequtils, strutils, unicode]
import parseSEG
import ../core/outputtext

const
  ImportLimit* = 1 shl 20 ## bytes of a file read to be taken in as plain text
  ImportButton* = "Import..."
  ImportTip* = "Take the text of a file in as this template's lines: a text file, or the " &
    "text header of a SEG-Y file. Nothing is kept until you save."
  UndoImportButton* = "Undo import"
  UndoImportTip* = "Put back the lines that were there before the import."
  ImportReading* = "The file is being read."
  ImportTitle* = "Read a text header file"
  ImportTooBig* = "The file is larger than 1 MiB and does not start with a SEG-Y text " &
    "header: it was not taken in."
  ImportNotText* = "The file is not text and does not start with a SEG-Y text header."
  ImportUtf16* = "The file is UTF-16 text, which is not read: save it as UTF-8 or Latin-1 " &
    "and import it again."
  ImportEmpty* = "The file holds no text."
  ImportNotFile* = "That is not a plain file (a folder, a pipe or a device), so it was not read."
  ImportCancelled* = "The import was stopped."
  ImportUnreadable* = "The file could not be read."

type
  TextImport* = object
    ## `ok`: `text` holds the lines, one `\n` between two, and `note` says what
    ## was done. Not ok: `why` says why nothing is taken in.
    ok*: bool
    text*: string
    raw*: bool ## a SEG-Y text header, whose character set is `encoding`
    encoding*: TextEncoding
    note*: string
    why*: string

func isControl(c: char): bool {.inline.} =
  (c < ' ' and c notin {'\t', '\n', '\r'}) or c == '\x7F'

func latinToUtf8(s: string): string =
  ## `s` as Latin-1, one byte a character, in UTF-8.
  result = newStringOfCap(s.len + s.len div 8)
  for c in s:
    if c < '\x80': result.add c
    else: result.add Rune(ord(c)).toUTF8

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func bytesOf(b: string; first, last: int): seq[byte] =
  ## `b[first ..< last]` as bytes.
  result = newSeq[byte](last - first)
  for i in first ..< last: result[i - first] = byte(b[i])

func bytesOfBlank(b: string; first, last: int): seq[byte] =
  ## `b[first ..< last]` as bytes, a NUL read as a blank: a text header's unused
  ## cards are often NUL-filled, which `looksLikeText` counts as binary.
  result = bytesOf(b, first, last)
  for x in result.mitems:
    if x == 0: x = 0x20

func isUtf16(b: string): bool =
  ## Whether `b` starts with a UTF-16 byte order mark or has a NUL in every
  ## other byte of its start (text in the Latin alphabets).
  if b.len >= 2 and b[0] in {'\xFE', '\xFF'} and b[1] == char(0xFE + 0xFF - ord(b[0])):
    return true
  let n = min(b.len, 512) div 2
  var even, odd = 0
  for i in 0 ..< n:
    if b[2 * i] == '\0': inc even
    if b[2 * i + 1] == '\0': inc odd
  result = n >= 2 and (4 * even >= 3 * n or 4 * odd >= 3 * n)

func utf16Shaped(b: string): bool =
  ## Whether `b` starts with a UTF-16 byte order mark or has NULs in one parity
  ## of its bytes only (text in the Latin alphabets). NUL-filled cards have them
  ## in both.
  if b.len >= 2 and b[0] in {'\xFE', '\xFF'} and b[1] == char(0xFE + 0xFF - ord(b[0])):
    return true
  let n = min(b.len, 512) div 2
  var even, odd = 0
  for i in 0 ..< n:
    if b[2 * i] == '\0': inc even
    if b[2 * i + 1] == '\0': inc odd
  result = n >= 2 and ((4 * even >= 3 * n) != (4 * odd >= 3 * n))

func looksRaw(b: string; size: int64): bool =
  ## Whether `b`, the start of a file of `size` bytes, is a SEG-Y text header:
  ## its first 3200 bytes read as text (EBCDIC or ASCII) and either the whole
  ## file is 3200 bytes with no line feed, or the file goes on with 400 bytes no
  ## text holds (the binary header), or it starts as EBCDIC "C ".
  if b.len < TextHeaderSize or utf16Shaped(b) or
      not looksLikeText(bytesOfBlank(b, 0, TextHeaderSize)):
    return false
  if size == TextHeaderSize: return '\n' notin b.substr(0, TextHeaderSize - 1)
  if b[0] == '\xC3' and b[1] == '\x40': return true
  if b.len < TextHeaderSize + 400: return false
  let tail = bytesOf(b, TextHeaderSize, TextHeaderSize + 400)
  result = not looksLikeText(tail) or tail.allIt(it == 0)

func rawCards(b: string): TextImport =
  var bytes = newSeq[byte](TextHeaderSize)
  for i in 0 ..< TextHeaderSize: bytes[i] = byte(b[i])
  let h = decodeTextHeader(bytes)
  let all = h.text
  var lines: seq[string] = @[]
  for n in 0 ..< MaxTextLines:
    var card = all.substr(n * MaxTextLine, n * MaxTextLine + MaxTextLine - 1)
    for c in card.mitems:
      if c < ' ' or c in {'\x7F' .. '\x9F'}: c = ' '
    lines.add latinToUtf8(card).strip(leading = false, chars = {' '})
  while lines.len > 0 and lines[^1].len == 0: lines.setLen(lines.len - 1)
  result = TextImport(ok: true, text: lines.join("\n"), raw: true, encoding: h.encoding,
    note: "The text header was read as " & (if h.encoding == teAscii: "ASCII" else: "EBCDIC") &
    ": cards 1 to " & $MaxTextLines & " were taken in; cards 39 and 40 are written by the " &
    "library.")

type Changes = object
  ## What making a line fit the template changed, counted over the file.
  tabs, controls, unholdable, braces, cut: int

func fitLine(line: string; ch: var Changes): string =
  ## `line` as the template can hold it: tabs and other controls become
  ## spaces, characters past U+00FF or in U+0080..U+009F become "?", a literal
  ## brace is written twice (so it stays text), and what passes 80 characters
  ## as written (`textProblem` counts them so) is cut.
  var width = 0
  for r in line.runes:
    let c = int32(r)
    let brace = c == int32('{') or c == int32('}')
    let w = if brace: 2 else: 1
    if width + w > MaxTextLine:
      inc ch.cut
      return
    inc width, w
    if c == 9:
      inc ch.tabs
      result.add ' '
    elif c < 0x20 or c == 0x7F:
      inc ch.controls
      result.add ' '
    elif c in 0x80'i32 .. 0x9F or c > 0xFF:
      inc ch.unholdable
      result.add '?'
    elif brace:
      inc ch.braces
      result.add char(c)
      result.add char(c)
    else:
      result.add r.toUTF8

func plainLines(b: string): TextImport =
  var text = b
  if text.startsWith("\xEF\xBB\xBF"): text = text.substr(3)
  if validateUtf8(text) >= 0: text = latinToUtf8(text)
  var lines = text.replace("\r\n", "\n").replace('\r', '\n').split('\n')
  while lines.len > 0 and lines[^1].strip.len == 0: lines.setLen(lines.len - 1)
  if lines.len == 0: return TextImport(why: ImportEmpty)
  var dropped = 0
  if lines.len > MaxTextLines:
    dropped = lines.len - MaxTextLines
    lines.setLen(MaxTextLines)
  var ch = Changes()
  for line in lines.mitems: line = fitLine(line, ch)
  var parts: seq[string] = @[]
  if ch.cut > 0:
    parts.add plural(ch.cut, "line was", "lines were") & " longer than " & $MaxTextLine &
      " characters and " & (if ch.cut == 1: "was" else: "were") & " cut"
  if dropped > 0:
    parts.add plural(dropped, "line", "lines") & " after line " & $MaxTextLines &
      (if dropped == 1: " was" else: " were") & " dropped"
  if ch.tabs > 0:
    parts.add plural(ch.tabs, "tab was", "tabs were") & " made a space"
  if ch.controls > 0:
    parts.add plural(ch.controls, "other control character was", "other control characters were") &
      " made a space"
  if ch.unholdable > 0:
    parts.add plural(ch.unholdable, "character the header cannot hold was", "characters the " &
      "header cannot hold were") & " made a ?"
  if ch.braces > 0:
    parts.add plural(ch.braces, "brace was", "braces were") & " written as {{ or }} so " &
      (if ch.braces == 1: "it stays" else: "they stay") & " text, not tokens"
  let note = if parts.len == 0: plural(lines.len, "line was", "lines were") & " taken in."
    else: capitalizeAscii(parts.join("; ")) & "."
  TextImport(ok: true, text: lines.join("\n"), encoding: teEbcdic, note: note)

func importHeader*(b: string; size: int64): TextImport =
  ## `b`: the first bytes of a file of `size` bytes (at most `ImportLimit` + 1 of
  ## them are read). A SEG-Y text header is recognised first, then plain text.
  if looksRaw(b, size): return rawCards(b)
  if size > ImportLimit: return TextImport(why: ImportTooBig)
  if size == 0 or b.len == 0: return TextImport(why: ImportEmpty)
  if isUtf16(b): return TextImport(why: ImportUtf16)
  var controls = 0
  for c in b:
    if c == '\0': return TextImport(why: ImportNotText)
    if isControl(c): inc controls
  if 10 * controls > b.len: return TextImport(why: ImportNotText)
  plainLines(b)
