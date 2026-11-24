## A named template for the SEG-Y text header of a file the Output window
## writes: up to 38 lines of up to 80 characters (cards 1 to 38; cards 39
## and 40 are always written by the library and are not part of the
## template), in the character set the person chooses. A line is UTF-8 text
## that holds Latin-1 characters only: the header takes one byte a character. A line may hold
## tokens in braces (`{stem}`, `{record:5}`, `{date}`) that take each file's
## own value when the file is written; `TextTokens` lists them. `{{` and `}}`
## are a literal brace.
##
## Nothing is padded or cut silently: a line that is too long once its tokens
## are filled in, a token whose value the file does not have, and a
## character the character set cannot hold are each a problem
## (`renderProblem`), and the file is not written with them. The character
## rule is the library's own (`checkTextHeader`).

import std/[math, options, os, strutils, times, unicode]
import parseSEG
import outputnames

const
  MaxTextLines* = 38            ## template lines, at most (cards 39 and 40 are the writer's)
  MaxTextLine* = 80             ## characters of one line
  MaxTextName* = MaxPatternName ## the template's name, in characters

type
  OutputText* = object
    ## One template, by the name a person picks it by.
    name*: string
    encoding*: TextEncoding ## `teEbcdic` (the traditional one) or `teAscii`
    lines*: seq[string]     ## cards 1 to 38; a short list leaves the rest blank

  TextTokenKind* = enum
    ttStem  ## the source file's name without its extension
    ttFile  ## the source file's name with its extension
    ttDate  ## the day of writing, UTC
    ttClock ## the time of day of writing, UTC
    ttPart  ## a value of the name pattern's kind `TextTokenInfo.part`

  TextTokenInfo* = object
    word*: string       ## what is written between the braces
    about*: string      ## one line for a list of tokens
    kind*: TextTokenKind
    part*: NamePartKind ## `ttPart` only
    width*: bool        ## a width may follow, as `{record:5}`

  TextValues* = object
    ## What one file gives the tokens. `values` is what `nameValuesOf` makes;
    ## a value the file's traces do not share is left out unless `firstLast`
    ## gives the first and the last, and the token is then `first-last`.
    values*: NameValues
    firstLast*: array[NamePartKind, tuple[first, last: NameValue]]
    source*: string ## the source file's name or path
    writtenUs*: int64 ## UTC microseconds since 1970 when the file is written

func part(word, about: string; kind: NamePartKind): TextTokenInfo =
  TextTokenInfo(word: word, about: about, kind: ttPart, part: kind, width: kind != npTime and
    kind != npSensorSerial)

const TextTokens*: seq[TextTokenInfo] = @[
  TextTokenInfo(word: "stem", about: "the source file's name without its extension",
    kind: ttStem),
  TextTokenInfo(word: "file", about: "the source file's name with its extension",
    kind: ttFile),
  TextTokenInfo(word: "date", about: "the day of writing, UTC, as 2026-11-24",
    kind: ttDate),
  TextTokenInfo(word: "clock", about: "the time of writing, UTC, as 10:15:00",
    kind: ttClock),
  part("record", "record number (FFID, or the SEG-D file number); first-last when it differs",
    npRecord),
  part("srcLine", "source line", npSrcLine),
  part("srcPoint", "source point", npSrcPoint),
  part("srcIndex", "source index", npSrcIndex),
  part("rcvLine", "receiver line", npRcvLine),
  part("rcvPoint", "receiver point", npRcvPoint),
  part("rcvIndex", "receiver index", npRcvIndex),
  part("time", "UTC time of the record, as 20261124T101500Z", npTime),
  part("systemSerial", "SEG-D system serial", npSystemSerial),
  part("controller", "signature controller serial", npController),
  part("vibrator", "vibrator number", npVibrator),
  part("fileNumber", "signature file number", npFileNumber),
  part("sigLine", "signature line", npSigLine),
  part("sigStation", "signature station", npSigStation),
  part("shotId", "shot id", npShotId),
  part("sweepId", "sweep id", npSweepId),
  part("sensorSerial", "serial of the unit that recorded the traces", npSensorSerial)]
  ## every token: the word between braces, a line saying what it is, and what
  ## gives its value. `{word:5}` pads a number to 5 digits (0 to 12).

type Seg = object
  literal: string ## a run of text, when `token` is -1
  token: int      ## index into `TextTokens`, or -1
  pad: int

func tokenIndex(word: string): int =
  for i, t in TextTokens:
    if t.word == word: return i
  -1

func capitalised(s: string): string =
  if s.len > 0: s[0].toUpperAscii & s.substr(1) else: s

func sentence(s: string): string =
  ## `s` as a sentence: a capital first, a full stop last.
  let c = capitalised(s)
  if c.endsWith('.'): c else: c & "."

func lineWord(n: int): string = "Line " & $n

func parseLine(line: string; n: int; segs: var seq[Seg]): string =
  ## Cuts `line` into text and tokens. "" when it holds only whole, known
  ## tokens; else one sentence saying which line and what.
  segs.setLen 0
  var lit = ""
  var i = 0
  while i < line.len:
    let c = line[i]
    if c == '{' and i + 1 < line.len and line[i + 1] == '{':
      lit.add '{'
      i += 2
    elif c == '}' and i + 1 < line.len and line[i + 1] == '}':
      lit.add '}'
      i += 2
    elif c == '}':
      return lineWord(n) & " has a } with no { before it."
    elif c == '{':
      let close = line.find('}', i + 1)
      if close < 0: return lineWord(n) & " has a { with no } after it."
      let body = line.substr(i + 1, close - 1)
      let colon = body.find(':')
      let word = if colon < 0: body else: body.substr(0, colon - 1)
      if word.len == 0: return lineWord(n) & " has an empty token."
      let t = tokenIndex(word)
      if t < 0: return lineWord(n) & " has the token {" & word & "}, which is not one."
      var pad = 0
      if colon >= 0:
        let w = body.substr(colon + 1)
        if not TextTokens[t].width:
          return lineWord(n) & ": {" & word & "} takes no width."
        var ok = w.len > 0 and w.len <= 2 and w.allCharsInSet(Digits)
        if ok:
          pad = parseInt(w)
          ok = pad <= MaxPad
        if not ok:
          return lineWord(n) & ": the width in {" & body & "} is from 0 to " & $MaxPad & "."
      if lit.len > 0:
        segs.add Seg(literal: lit, token: -1)
        lit = ""
      segs.add Seg(token: t, pad: pad)
      i = close + 1
    else:
      lit.add c
      inc i
  if lit.len > 0: segs.add Seg(literal: lit, token: -1)

func nameProblem(name: string): string =
  let n = strip(name)
  if n.len == 0: return "An output text needs a name."
  if validateUtf8(n) >= 0: return "An output text's name is not text (not UTF-8)."
  if n.runeLen > MaxTextName:
    return "An output text's name is at most " & $MaxTextName & " characters long."
  for c in n:
    if c in {'\0' .. '\31', '\127'}: return "An output text's name holds no control characters."
  ""

func charProblem(lines: openArray[string]; encoding: TextEncoding): string =
  ## Why a character of `lines` cannot be written; "" when all can. The
  ## lines are UTF-8 and the header takes one Latin-1 byte a character: a
  ## character past U+00FF, or bytes that are not UTF-8, are refused here;
  ## the library's own check (`checkTextHeader`) then gives the reason for
  ## the first character `encoding` cannot hold.
  var latin: seq[string] = @[]
  for i, line in lines:
    var one = ""
    var col = 0
    if validateUtf8(line) >= 0:
      return "Textual header line " & $(i + 1) & " is not text (not UTF-8)."
    for r in line.runes:
      inc col
      if int32(r) > 0xFF:
        return "Textual header line " & $(i + 1) & " column " & $col &
          " holds a character the header cannot hold."
      one.add char(int32(r))
    latin.add one
  for p in checkTextHeader(latin, SegyRevision(), encoding):
    if p.kind == thfBadCharacter: return sentence(p.message)

func textProblem*(t: OutputText): string =
  ## Why `t` cannot be kept; "" when it can. The name follows a name
  ## pattern's rules. At most `MaxTextLines` lines, each at most
  ## `MaxTextLine` characters with its tokens as written, each token one
  ## `TextTokens` knows, and only characters the library's header check
  ## accepts in `t.encoding`.
  result = nameProblem(t.name)
  if result.len > 0: return
  if t.lines.len > MaxTextLines:
    return "An output text has at most " & $MaxTextLines & " lines."
  var segs: seq[Seg] = @[]
  for i, line in t.lines:
    if line.runeLen > MaxTextLine:
      return lineWord(i + 1) & " is longer than " & $MaxTextLine & " characters."
    let why = parseLine(line, i + 1, segs)
    if why.len > 0: return why
  result = charProblem(t.lines, t.encoding)

func pieceOf(v: NameValue; pad: int; word: string): tuple[text, problem: string] =
  case v.state
  of nvMissing: result.problem = "{" & word & "} is not in this file."
  of nvMixed: result.problem = "{" & word & "} is not one value in this file."
  of nvTimeUs:
    let r = formatTime(v.timeUs, v.wholeSeconds)
    result.text = r.name
    result.problem = r.problem
  of nvInt: result.text = formatInt(v.intValue, pad)
  of nvNumber:
    if v.number != v.number or abs(v.number) >= 1e15:
      result.problem = "{" & word & "} is not in this file."
    else: result.text = numberPiece(v.number, pad)
  of nvText: result.text = v.text

proc tokenText(info: TextTokenInfo; pad: int; v: TextValues): tuple[text, problem: string] =
  ## The text of one token for one file; `problem` when it has no value.
  case info.kind
  of ttStem:
    let s = v.values[npStem]
    if s.state == nvText: result.text = s.text
    else: result.text = extractFilename(v.source).changeFileExt("")
  of ttFile: result.text = extractFilename(v.source)
  of ttDate, ttClock:
    let t = fromUnix(floorDiv(v.writtenUs, 1_000_000)).utc
    result.text = t.format(if info.kind == ttDate: "yyyy-MM-dd" else: "HH:mm:ss")
  of ttPart:
    let one = pieceOf(v.values[info.part], pad, info.word)
    if one.problem.len == 0: return one
    let fl = v.firstLast[info.part]
    if v.values[info.part].state == nvMixed and fl.first.state in {nvNumber, nvInt} and
        fl.last.state in {nvNumber, nvInt}:
      let a = pieceOf(fl.first, pad, info.word)
      let b = pieceOf(fl.last, pad, info.word)
      if a.problem.len == 0 and b.problem.len == 0:
        return (a.text & "-" & b.text, "")
    return one

proc expand(t: OutputText; v: TextValues; lines: var seq[string]): string =
  ## Fills the tokens of every line into `lines`; a token with no value is
  ## left as written, and the first such is the result (a sentence).
  lines = @[]
  var segs: seq[Seg] = @[]
  for i, line in t.lines:
    if parseLine(line, i + 1, segs).len > 0:
      lines.add line
      if result.len == 0: result = parseLine(line, i + 1, segs)
    else:
      var one = ""
      for s in segs:
        if s.token < 0: one.add s.literal
        else:
          let info = TextTokens[s.token]
          let piece = tokenText(info, s.pad, v)
          if piece.problem.len > 0:
            one.add "{" & info.word & "}"
            if result.len == 0: result = lineWord(i + 1) & ": " & piece.problem
          else: one.add piece.text
      lines.add one

proc render*(t: OutputText; v: TextValues): seq[string] =
  ## The lines of `t` with each token replaced by `v`'s value. Nothing is
  ## padded or cut: a token with no value stays as written and a long line
  ## stays long; `renderProblem` says so.
  discard expand(t, v, result)

proc renderProblem*(t: OutputText; v: TextValues): string =
  ## Why `t` cannot be written for the file `v` describes; "" when it can: a
  ## token with no value in the file, a line longer than `MaxTextLine`
  ## characters once its tokens are filled in, or a character `t.encoding`
  ## cannot hold (the library's reason).
  var lines: seq[string] = @[]
  result = expand(t, v, lines)
  if result.len > 0: return
  for i, line in lines:
    if line.runeLen > MaxTextLine:
      return lineWord(i + 1) & " is " & $line.runeLen & " characters long once its tokens are " &
        "filled in; at most " & $MaxTextLine & " fit."
  result = charProblem(lines, t.encoding)

proc cardsOf*(t: OutputText; v: TextValues): seq[string] =
  ## The cards the writer takes (`fullText`) for `t` and the file `v`
  ## describes: `render`'s lines one byte a character (UTF-8 to Latin-1).
  ## Call it when `renderProblem` is "": a character past U+00FF is cut to
  ## its low byte otherwise.
  result = @[]
  for line in render(t, v):
    var one = ""
    for r in line.runes: one.add char(int32(r) and 0xFF)
    result.add one

func chosenText*(texts: openArray[OutputText]; name: string): Option[OutputText] =
  ## The template called `name`; none when `name` is "" or names none.
  result = none(OutputText)
  if name.len > 0:
    for t in texts:
      if t.name == name: return some(t)
