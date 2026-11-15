## The headers of an open file, of its SEG-D records and of its traces, as
## the Headers window shows them: plain rows of text, made off the UI thread
## from parseSEG's header listings.
##
## - `fileFacts`, on the open job's thread, before the file is handed over:
##   what the Summary tab says of the file (parseSEG's `summary`,
##   `channelSets`, the SEG-Y textual header's character set; its CRS text
##   is the session's, `Session.crs`, as the join window shows it) and
##   its file headers: the SEG-Y textual header as its 40 lines, the binary
##   header's fields, the extended textual headers; a SEG-2 file's
##   descriptor block; the blocks without named fields (a tape or storage
##   unit label, a data trailer) as their bytes.
## - `readRecordHeaders` and `traceRows`, on the inspector's thread
##   (`core/inspector`): a SEG-D record's general, channel set, extended and
##   external headers, and a trace's header blocks.
##
## Every field becomes a `FieldRow`: its block, its name, its description in
## plain words (`core/fielddocs`), its value as text and as a number, and
## the bytes it takes in its block, counted from 1 as the standards count
## them. A block without named fields gives one row and its bytes
## (`RawBlock`, at most `MaxRawBytes`). Text from the file is made valid
## UTF-8 (the headers are Latin-1), with control characters as dots.

import std/[math, strutils]
import parseSEG
import fielddocs

export FileSummary, ChannelSetSummary, JoinGroup

const
  MaxRawBytes* = 1024 * 1024 ## the bytes of a block without named fields kept to show, at most

type
  FieldRow* = object
    ## One field of a header block, as a header table shows it.
    blockName*: string   ## `trace`, `ext1`, `gh1`, `binary`, `st1cs2`, ...
    kind*: HeaderBlock   ## the block's type; `hbRaw` for a block without named fields
    field*: string       ## parseSEG's name of the field; "" for a block without named fields
    description*: string ## in plain words
    value*: string       ## as text (a block without named fields: what it is)
    number*: float64     ## the value as a number; NaN for text
    first*, last*: int   ## the bytes it takes in its block, from 1
    offset*: int64       ## the file offset of its first byte
    size*: int
    blockOffset*: int64  ## the file offset of its block
    blockSize*: int

  RawBlock* = object
    ## A header block without named fields, as its bytes.
    blockName*: string
    offset*: int64    ## in the file
    size*: int        ## the block's size
    bytes*: seq[byte] ## its first `MaxRawBytes` at most

  FileFacts* = object
    ## What the Summary and File headers tabs show of a file, read when it
    ## is opened.
    summary*: FileSummary
    channelSets*: seq[ChannelSetSummary] ## SEG-D: every record's
    textEncoding*: string ## SEG-Y: "EBCDIC" or "ASCII"; "" otherwise
    text*: seq[string] ## SEG-Y: the textual header's 40 lines
    extendedText*: seq[seq[string]] ## SEG-Y: each extended textual header's lines
    rows*: seq[FieldRow] ## the file-level header blocks, in file order
    raw*: seq[RawBlock] ## those without named fields
    problems*: seq[string] ## what could not be read, in plain words

  RecordHeaders* = object
    ## The headers of one SEG-D record.
    record*: int = -1    ## its index in the file; -1 for none
    rows*: seq[FieldRow] ## general headers, channel sets, skew, extended, external, trailer
    raw*: seq[RawBlock]
    problem*: string     ## why they could not be read; "" when they were

  TraceDetail* = object
    ## What the Trace tab shows of one trace: its headers, its samples.
    id*: int               ## its survey-wide id
    trace*: int            ## its index in its file
    file*: string          ## its file's name
    keys*: TraceKeys       ## its keys, as the index holds them
    rows*: seq[FieldRow]   ## every header field (when asked for)
    samples*: seq[float32] ## its samples (when asked for)
    displayed*: bool       ## `samples` as displayed: after the edits, the polarity and
                           ## the display gain's processing; false: as recorded
    cut*: int              ## samples left out of `samples` (too many at once); 0 for none
    dtMs*, t0Ms*: float64  ## its sample interval and the time of its first sample
    intervalKnown*: bool   ## its file gives `dtMs`; else it is 1 (the times count samples)
    problem*: string       ## what could not be read; "" when all was
    joined*: set[JoinGroup]
      ## the groups of its keys a geometry join gave (parseSEG's
      ## `joinedGroups`): those values are not its headers'

  Inspected* = object
    ## The inspector's answer to one request (`core/inspector`).
    gen*: uint64              ## the request's
    recordPath*: string       ## the file of `record`; "" for none
    record*: RecordHeaders    ## a SEG-D record's headers (when asked for)
    traces*: seq[TraceDetail] ## the traces asked for, in the order asked

func latin1*(text: openArray[char]): string =
  ## `text` (Latin-1, as headers hold it) as UTF-8, control characters as
  ## dots.
  result = newStringOfCap(text.len)
  for c in text:
    let b = ord(c)
    if b < 0x20 or b == 0x7F or b in 0x80 .. 0x9F: result.add '.'
    elif b < 0x80: result.add c
    else:
      result.add chr(0xC0 or (b shr 6))
      result.add chr(0x80 or (b and 0x3F))

func exactText*(x: float64): string =
  ## `x` in its shortest form: a whole number without a decimal point.
  if x.isNaN: "NaN"
  elif x == round(x) and abs(x) < 1e15: $int64(x)
  else: $x

func valueText*(v: FieldValue): string =
  ## A field's value as text: a text field without its trailing blanks and
  ## NULs.
  case v.kind
  of fvInt: $v.intVal
  of fvFloat: exactText(v.floatVal)
  of fvText:
    var n = v.text.len
    while n > 0 and v.text[n - 1] in {' ', '\0'}: dec n
    latin1(v.text.toOpenArray(0, n - 1))

func valueNumber(v: FieldValue): float64 =
  case v.kind
  of fvInt: float64(v.intVal)
  of fvFloat: v.floatVal
  of fvText: NaN

func fieldRow*(r: HeaderRow): FieldRow =
  ## One row of a parseSEG header listing as the tables show it.
  let first = int(r.offset - r.blockOffset) + 1
  result = FieldRow(blockName: r.blockName, kind: r.kind, field: r.field, value: valueText(r.value),
    number: valueNumber(r.value), first: first, last: first + max(r.size, 1) - 1,
    offset: r.offset, size: r.size, blockOffset: r.blockOffset, blockSize: r.blockSize)
  result.description = if r.field.len > 0: fieldDescription(r.kind, r.field)
                       else: wordsOf(result.value)

func fieldRows*(rows: openArray[HeaderRow]): seq[FieldRow] =
  ## A parseSEG header listing as the tables show it.
  result = newSeqOfCap[FieldRow](rows.len)
  for r in rows: result.add fieldRow(r)

proc rawBlocks(f: SeismicFile; rows: openArray[FieldRow]; problems: var seq[string]):
    seq[RawBlock] =
  ## The bytes of the blocks of `rows` without named fields.
  for r in rows:
    if r.kind == hbRaw and r.field.len == 0:
      var b = RawBlock(blockName: r.blockName, offset: r.blockOffset, size: r.blockSize)
      try:
        b.bytes = f.copyBytes(r.blockOffset, min(r.blockSize, MaxRawBytes))
      except ValueError as e:
        problems.add "the " & r.blockName & " block cannot be read: " & e.msg
      result.add b

func cardLines(text: string): seq[string] =
  ## A decoded text block (lines joined by '\n') as UTF-8 lines.
  for line in text.split('\n'): result.add latin1(line)

proc fileFacts*(f: SeismicFile; headers = true): FileFacts =
  ## What the Summary and File headers tabs show of `f`. Reads the index and,
  ## with `headers`, the file's own header blocks (no trace): call it on the
  ## thread that holds the file, before it is handed to another. What cannot
  ## be read is said in `problems`; nothing raises.
  result = FileFacts()
  try:
    result.summary = f.summary
  except ValueError as e:
    result.problems.add "the summary cannot be read: " & e.msg
  try:
    result.channelSets = f.channelSets
  except ValueError as e:
    result.problems.add "the channel sets cannot be read: " & e.msg
  if not headers: return
  if f.kind == skSegy:
    result.textEncoding = if f.index.segy.text.encoding == teEbcdic: "EBCDIC" else: "ASCII"
    try:
      result.text = cardLines(f.textHeader)
      for t in f.extendedTextHeaders: result.extendedText.add cardLines(t)
    except ValueError as e:
      result.problems.add "the textual headers cannot be read: " & e.msg
  if f.kind != skUnknown:
    try:
      result.rows = fieldRows(f.fileHeaders)
      result.raw = rawBlocks(f, result.rows, result.problems)
    except ValueError as e:
      result.problems.add "the file headers cannot be read: " & e.msg

proc readRecordHeaders*(f: SeismicFile; record: int): RecordHeaders =
  ## The headers of SEG-D record `record` of `f`, with the bytes of its
  ## blocks without named fields; nothing for another standard. Reads the
  ## file's header bytes: call it on a thread that may (it holds the file).
  result = RecordHeaders(record: record)
  if f.kind != skSegd: return
  try:
    result.rows = fieldRows(f.recordHeaders(record))
    var problems: seq[string]
    result.raw = rawBlocks(f, result.rows, problems)
    if problems.len > 0: result.problem = problems.join("; ")
  except ValueError as e:
    result.problem = e.msg

proc traceRows*(f: SeismicFile; trace: int): seq[FieldRow] =
  ## Every header field of trace `trace` of `f`, its extensions included.
  ## Raises `ValueError` for a trace out of range or a closed file.
  fieldRows(f.traceHeaders(trace))

func segdRecordOf*(f: SeismicFile; trace: int): int =
  ## The index of the SEG-D record trace `trace` is in (the index in memory);
  ## -1 for another standard or a trace out of range.
  if f.kind == skSegd and trace in 0 ..< f.len: int(f.index.entries[trace].record) else: -1

func blockTitle*(name: string; standard: SeismicKind): string =
  ## A header block's name in words: "trace" is "Trace header", "gh2"
  ## "General header 2", "st1cs3" "Channel set 3 (scan type 1)".
  func digits(s: string): bool = s.len > 0 and s.allCharsInSet(Digits)
  if standard == skSeg2:
    result = case name
      of "file": "File descriptor block"
      of "trace": "Trace descriptor block"
      else: wordsOf(name)
  elif name == "trace": result = "Trace header"
  elif name.startsWith("ext") and digits(name[3 .. ^1]):
    result = "Trace header extension " & name[3 .. ^1]
  elif name.startsWith("gh") and digits(name[2 .. ^1]):
    result = "General header " & name[2 .. ^1]
  elif name.startsWith("st") and "cs" in name:
    let parts = name[2 .. ^1].split("cs")
    result = if parts.len == 2 and digits(parts[0]) and digits(parts[1]):
        "Channel set " & parts[1] & " (scan type " & parts[0] & ")"
      else: wordsOf(name)
  elif name.startsWith("st") and name.endsWith("skew") and digits(name[2 .. ^5]):
    result = "Skew (scan type " & name[2 .. ^5] & ")"
  else:
    result = case name
      of "binary": "Binary header"
      of "text": "Textual header"
      of "label": (if standard == skSegd: "Storage unit label" else: "Tape label")
      of "extended": (if standard == skSegy: "Extended textual headers" else: "Extended header")
      of "external": "External header"
      of "trailer": (if standard == skSegy: "Data trailer" else: "General trailer")
      else: wordsOf(name)

func formatName*(standard: SeismicKind; code: int): string =
  ## The sample format of code `code` in words ("IEEE float, 4 bytes"); ""
  ## for a code the standard does not define.
  case standard
  of skSegy:
    result = case code
      of 1: "IBM float, 4 bytes"
      of 2: "integer, 4 bytes"
      of 3: "integer, 2 bytes"
      of 4: "fixed point with gain, 4 bytes"
      of 5: "IEEE float, 4 bytes"
      of 6: "IEEE float, 8 bytes"
      of 7: "integer, 3 bytes"
      of 8: "integer, 1 byte"
      of 9: "integer, 8 bytes"
      of 10: "unsigned integer, 4 bytes"
      of 11: "unsigned integer, 2 bytes"
      of 12: "unsigned integer, 8 bytes"
      of 15: "unsigned integer, 3 bytes"
      of 16: "unsigned integer, 1 byte"
      else: ""
  of skSegd:
    result = case code
      of 8015: "20-bit binary, demultiplexed"
      of 8022: "8-bit quaternary, demultiplexed"
      of 8024: "16-bit quaternary, demultiplexed"
      of 8036: "24-bit integer, demultiplexed"
      of 8038: "32-bit integer, demultiplexed"
      of 8042: "8-bit hexadecimal, demultiplexed"
      of 8044: "16-bit hexadecimal, demultiplexed"
      of 8048: "32-bit hexadecimal, demultiplexed"
      of 8058: "IEEE float, 4 bytes, demultiplexed"
      of 8080: "IEEE float, 8 bytes, demultiplexed"
      of 15: "20-bit binary, multiplexed"
      of 22: "8-bit quaternary, multiplexed"
      of 24: "16-bit quaternary, multiplexed"
      of 36: "24-bit integer, multiplexed"
      of 38: "32-bit integer, multiplexed"
      of 42: "8-bit hexadecimal, multiplexed"
      of 44: "16-bit hexadecimal, multiplexed"
      of 48: "32-bit hexadecimal, multiplexed"
      of 58: "IEEE float, 4 bytes, multiplexed"
      else: ""
  of skSeg2:
    result = case code
      of 1: "integer, 2 bytes"
      of 2: "integer, 4 bytes"
      of 3: "20-bit float"
      of 4: "IEEE float, 4 bytes"
      of 5: "IEEE float, 8 bytes"
      else: ""
  of skUnknown: result = ""

func channelTypeName*(revision3: bool; code: int): string =
  ## A SEG-D channel set's type in words ("seismic", "time break").
  if revision3:
    result = case code
      of 0x10: "seismic"
      of 0x11: "electromagnetic"
      of 0x20: "time break"
      of 0x21: "clock timebreak"
      of 0x22: "field timebreak"
      of 0x30: "up hole"
      of 0x40: "water break"
      of 0x50: "time counter"
      of 0x60: "external data"
      of 0x61: "acoustic range measurement"
      of 0x62: "acoustic reference (measured)"
      of 0x63: "acoustic reference (nominal)"
      of 0x70: "other"
      of 0x80: "signature, unfiltered"
      of 0x90: "signature, filtered"
      of 0x91: "source signature / guidance"
      of 0x98: "auxiliary data trailer (pilot)"
      else: "type 0x" & toHex(code, 2)
  else:
    result = case code
      of 1: "seismic"
      of 2: "time break"
      of 3: "up hole"
      of 4: "water break"
      of 5: "time counter"
      of 6: "external data"
      of 7: "other"
      of 8: "signature, unfiltered"
      of 9: "signature, filtered"
      of 12: "auxiliary data trailer"
      else: "type " & $code
