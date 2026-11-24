## The project's text header template and binary header set in a SEG-Y slice built from
## header keys. The values a template's tokens take come from what the slice knows (the
## output's name, the shots' record numbers and source line and point, the receivers'
## line and point, the day of writing), not from a source file; the notes the slice writes
## about itself follow the template's last non-empty line, in cards the template leaves
## free.

import std/[math, options, os, strutils, times]
import parseSEG
import processSEG/continuous/slice
import ./[cutfills, outputnames, outputtext]

const LastCard = MaxTextLines ## the last card a template or a note may take

proc nowUs*(): int64 =
  ## UTC microseconds since 1970.
  let t = getTime()
  t.toUnix * 1_000_000 + int64(t.nanosecond div 1000)

func cardLead(n: int): string =
  ## The standard columns 1 to 4 of card `n`: "C 4 ", "C12 ".
  (if n < 10: "C " else: "C") & $n & " "

type Spread = object
  ## What one part takes over the written traces: one value, or the lowest and highest.
  value, first, last: NameValue

func partSpread(xs: openArray[float64]; zeroMissing: bool): Spread =
  ## One value when every number is the same, the lowest and highest when they differ or
  ## some are missing (NaN, huge, or 0 for a record), missing when all are.
  var seen, missing = false
  var lo, hi = 0.0
  for x in xs:
    if x.isNaN or abs(x) >= 1e15 or (zeroMissing and x == 0.0): missing = true
    elif not seen:
      seen = true
      lo = x
      hi = x
    else:
      lo = min(lo, x)
      hi = max(hi, x)
  if not seen: result.value = NameValue(state: nvMissing)
  elif missing or lo != hi:
    result.value = NameValue(state: nvMixed)
    result.first = NameValue(state: nvNumber, number: lo)
    result.last = NameValue(state: nvNumber, number: hi)
  else: result.value = NameValue(state: nvNumber, number: lo)

func sliceTextValues*(dest: string; numbers: openArray[int]; shots: openArray[SliceShot];
    receivers: openArray[TraceKeys]; writtenUs: int64): TextValues =
  ## What the slice written to `dest` gives a template's tokens: its name (`{stem}`, `{file}`),
  ## the record numbers of its shots, the source line and point of the shots and the line and
  ## point of the receivers (one value, or `lowest-highest`), the time of the shots when
  ## there is one, and the day of writing. A SEG-Y file has no source or receiver index, and
  ## the slice has no serial numbers, so those tokens have no value.
  result.source = dest
  result.writtenUs = writtenUs
  result.values[npStem] = NameValue(state: nvText, text: dest.extractFilename.changeFileExt(""))
  var nums, sl, sp, rl, rp = newSeq[float64]()
  for n in numbers: nums.add float64(n)
  for s in shots:
    sl.add s.srcLine
    sp.add s.srcPoint
  for k in receivers:
    rl.add k.rcvLine
    rp.add k.rcvPoint
  for (kind, xs, zero) in [(npRecord, nums, true), (npSrcLine, sl, false),
      (npSrcPoint, sp, false), (npRcvLine, rl, false), (npRcvPoint, rp, false)]:
    let s = partSpread(xs, zero)
    result.values[kind] = s.value
    result.firstLast[kind] = (first: s.first, last: s.last)
  var times: seq[int64] = @[]
  for s in shots:
    if s.timeUsKnown and s.timeUs notin times: times.add s.timeUs
  if times.len == 1:
    result.values[npTime] = NameValue(state: nvTimeUs, timeUs: times[0], wholeSeconds: false)
  elif times.len > 1: result.values[npTime] = NameValue(state: nvMixed)

type Noted* = object
  ## The template's cards, with the slice's notes after them when there is room.
  cards*: seq[string]
  written*: bool    ## the notes are in `cards`
  need*, free*: int ## the cards the notes take, and the cards the template leaves

func withNotes*(rendered: seq[string]; p: Provenance): Noted =
  ## `rendered` (the template's cards) and the lines of `p` after the writer's own, each on a
  ## card of its own after the template's last non-empty line. Not written when they do not all
  ## fit: no card of the template is overwritten.
  var used = 0
  for i, c in rendered:
    if c.strip.len > 0: used = i + 1
  result.cards = rendered[0 ..< used]
  result.need = max(p.lines.len - 1, 0)
  result.free = LastCard - used
  if result.need <= result.free:
    for i in 1 ..< p.lines.len:
      result.cards.add cardLead(result.cards.len + 1) & p.lines[i]
    result.written = true

type Opened* = object
  ## A SEG-Y output opened with what the project chose.
  w*: SeismicWriter
  cards*: seq[string]        ## the cards the header has; empty: the writer's own text
  over*: seq[HeaderOverride] ## the binary fields written; empty: none
  textWhy*, binWhy*: string  ## the library's reason for refusing the template or the set

proc openKeysSegy*(part: string; cards: seq[string]; encoding: TextEncoding;
    plain: seq[string]; over: seq[HeaderOverride]): Opened =
  ## Opens `part` as a SEG-Y output built from keys, with `cards` as its whole text header
  ## (in `encoding`) and `over` as binary fields. The library refuses a combination it cannot
  ## write before it creates a file; the set is dropped first, then the template, until it
  ## opens (the reason of each is kept). `plain` is the text header lines (`text`) of a file
  ## whose template was dropped or never chosen. Raises what the library raises of a file with
  ## neither.
  result.cards = cards
  result.over = over
  template attempt() =
    result.w = openSeismicWriter(part, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
      text: plain, fullText: result.cards,
      textEncoding: (if result.cards.len > 0: encoding else: teEbcdic),
      binaryOverrides: result.over))
  try: attempt()
  except ValueError as e:
    if result.cards.len == 0 and result.over.len == 0: raise
    let kept = result.over
    if result.over.len > 0 and result.cards.len > 0:
      result.over.setLen 0
      try:
        attempt()
        result.binWhy = e.msg
      except ValueError as second:
        result.textWhy = second.msg
        result.cards.setLen 0
        result.over = kept
        try: attempt()
        except ValueError as third:
          result.binWhy = third.msg
          result.over.setLen 0
          attempt()
    elif result.over.len > 0:
      result.binWhy = e.msg
      result.over.setLen 0
      attempt()
    else:
      result.textWhy = e.msg
      result.cards.setLen 0
      attempt()
