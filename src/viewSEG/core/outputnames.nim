## A file name built from parts: a separator between them, a least width on a
## number so a folder sorts, free text as one part, a time written so it
## sorts and holds no colon: six microsecond digits, or whole seconds.
##
## `render` takes the values a caller already gathered for one file. It
## reads nothing, and it never writes a placeholder for a value that is
## missing or not the same on every trace. The name it returns is the leaf
## only, with the extension the caller passed: empty, or a dot and 1 to 16
## letters or digits (as `.sgy`). A missing dot is not added.

import std/[math, strutils, unicode]

const
  MaxPatternName* = 64
    ## a pattern's label, in characters; not a file name
  MaxPatternParts* = 16
    ## parts in one pattern, at most
  MaxPad* = 12
    ## a width, in digits of the integer part
  MaxFileNameRunes* = 180
    ## a rendered file name, with its extension, in characters

type
  NamePartKind* = enum
    npStem         ## the source file's own name, without its extension
    npText         ## free text, the same for every file
    npRecord       ## record number (FFID, or the SEG-D file number)
    npSrcLine      ## source line
    npSrcPoint     ## source point
    npSrcIndex     ## source index
    npRcvLine      ## receiver line
    npRcvPoint     ## receiver point
    npRcvIndex     ## receiver index
    npTime         ## UTC time of the record or the sweep
    npSystemSerial ## SEG-D system serial
    npController   ## signature controller serial
    npVibrator     ## vibrator number
    npFileNumber   ## signature file number
    npSigLine      ## signature line
    npSigStation   ## signature station
    npShotId       ## shot id
    npSweepId      ## sweep id

  NamePart* = object
    ## One piece of a pattern.
    kind*: NamePartKind
    pad*: int     ## least digits of the integer part; 0 is none; at most 12
    text*: string ## `npText` only

  NameSeparator* = enum
    nsDot = "."        ## parts joined by `.`
    nsUnderscore = "_" ## parts joined by `_`
    nsHyphen = "-"     ## parts joined by `-`

  OutputPattern* = object
    ## How a file written by the Output window is named. `name` is the
    ## label a person picks the pattern by, not a file name.
    name*: string
    separator*: NameSeparator
    parts*: seq[NamePart]

  NameValueState* = enum
    nvMissing ## not in this file
    nvMixed   ## not one value in this file
    nvNumber  ## a float (a line, a station, a record)
    nvInt     ## an integer (an index, a serial, an id)
    nvTimeUs  ## UTC microseconds, and whether only whole seconds count
    nvText    ## a piece already text (the source file's name)

  NameValue* = object
    ## One part's value for one file. Zero is a value: a caller that wants
    ## a blank header refused passes `nvMissing`, not `0`.
    case state*: NameValueState
    of nvMissing, nvMixed:
      discard
    of nvNumber:
      number*: float64
    of nvInt:
      intValue*: int64
    of nvTimeUs:
      timeUs*: int64 ## microseconds since 1970-01-01 00:00:00 UTC
      wholeSeconds*: bool ## no fraction; otherwise six microsecond digits
    of nvText:
      text*: string

  NameValues* = array[NamePartKind, NameValue]
    ## one value per part kind; a kind left unset is missing

  NameResult* = object
    ## A leaf file name, or one sentence saying why it cannot be made.
    ## `problem` empty means `name` is the file name; otherwise `name` is "".
    name*: string
    problem*: string

const
  Forbidden = {'<', '>', ':', '"', '/', '\\', '|', '?', '*', '.'}
  Controls = {'\0' .. '\31', '\127'}

func partWord*(kind: NamePartKind): string =
  ## The word a person sees for `kind`. A source part and a receiver part
  ## do not share a word.
  case kind
  of npStem: "File name"
  of npText: "Text"
  of npRecord: "Record"
  of npSrcLine: "Source line"
  of npSrcPoint: "Source point"
  of npSrcIndex: "Source index"
  of npRcvLine: "Receiver line"
  of npRcvPoint: "Receiver point"
  of npRcvIndex: "Receiver index"
  of npTime: "Time"
  of npSystemSerial: "System serial"
  of npController: "Controller"
  of npVibrator: "Vibrator"
  of npFileNumber: "File number"
  of npSigLine: "Line"
  of npSigStation: "Station"
  of npShotId: "Shot id"
  of npSweepId: "Sweep id"

func refused(sentence: string): NameResult =
  NameResult(problem: sentence)

func accepted(fileName: string): NameResult =
  NameResult(name: fileName)

func deviceSentence(token: string): string =
  "\"" & token & "\" is a name Windows keeps for a device."

func isDeviceName(s: string): bool =
  ## `s` itself, not a name with an extension. Compared without regard to case.
  let u = toUpperAscii(s)
  case u
  of "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$": true
  else:
    u.len == 4 and u[0 .. 2] in ["COM", "LPT"] and u[3] in {'0' .. '9'}

func textProblem(word, s: string; sep: char): string =
  ## Why `s` cannot be a piece of a file name; "" when it can. `sep` is this
  ## pattern's separator: text that holds it is refused, so two values cannot
  ## make one name. A dot is refused whatever `sep` is.
  if s.len == 0: return word & " is empty."
  if validateUtf8(s) >= 0: return word & " is not text."
  if s[0] == ' ' or s[^1] == ' ': return word & " starts or ends with a space."
  for c in s:
    if c in Controls or c in Forbidden:
      return word & " holds a character a file name cannot."
  if sep in s:
    return word & " has the separator " & sep & " in it."
  if isDeviceName(s): return deviceSentence(s)
  ""

func zeroPad(n: int64; width: int): string =
  let s = $n
  if s.len >= width: s
  else: repeat('0', width - s.len) & s

func appliedPad(pad: int): int =
  ## A width render will use. Outside 0..12 is the editor's refusal; here it
  ## cannot ask for a huge run of zeros.
  if pad < 0: 0 elif pad > MaxPad: MaxPad else: pad

func absDigits(n: int64): string =
  if n >= 0: $n
  elif n == low(int64): "9223372036854775808"
  else: $(-n)

func formatInt(n: int64; pad: int): string =
  ## Sign outside the zeros: `-00042`. A value wider than `pad` is whole.
  let digits = absDigits(n)
  let width = appliedPad(pad)
  let padded = if digits.len >= width: digits
               else: repeat('0', width - digits.len) & digits
  if n < 0: "-" & padded else: padded

func formatNumber(x: float64; pad: int): string =
  ## Rounded to 4 decimal places, half away from zero, by scaling into an
  ## integer. The integer digits are padded; a fraction that is not zero
  ## follows `p`, trailing zeros dropped. A value that rounds to zero has
  ## no sign, padded or not.
  let ax = abs(x)
  var whole: int64
  var digits: int64
  if ax < 9.2e14:
    # ax * 10000 fits in int64 here. 1e15 * 10000 does not, so a value
    # above this (still under the 1e15 refusal) scales its fraction alone.
    let scaled = int64(floor(ax * 10_000.0 + 0.5))
    whole = scaled div 10_000
    digits = scaled mod 10_000
  else:
    whole = int64(trunc(ax))
    let frac = ax - float64(whole)
    digits = int64(floor(frac * 10_000.0 + 0.5))
    if digits >= 10_000:
      inc whole
      digits = 0
  let head = formatInt(whole, pad)
  if digits == 0:
    if x < 0.0 and whole != 0: "-" & head else: head
  else:
    var tail = $digits
    if tail.len < 4: tail = repeat('0', 4 - tail.len) & tail
    while tail.len > 0 and tail[^1] == '0': tail.setLen(tail.len - 1)
    let body = head & "p" & tail
    if x < 0.0: "-" & body else: body

func floorDiv(a, b: int64): int64 =
  ## `b` > 0. Toward -infinity, so a time before 1970 stays on its day.
  let q = a div b
  if a mod b < 0: q - 1 else: q

func floorMod(a, b: int64): int64 =
  let r = a mod b
  if r < 0: r + b else: r

func civilFromDays(z0: int64): tuple[y: int64; m, d: int] =
  ## Days since 1970-01-01 to a Gregorian date. Integer only (Howard
  ## Hinnant's civil_from_days), so a date before 1970 is exact.
  let z = z0 + 719468
  let era = if z >= 0: z div 146097 else: (z - 146096) div 146097
  let doe = int(z - era * 146097)
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  var y = int64(yoe) + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = mp + (if mp < 10: 3 else: -9)
  if m <= 2: inc y
  (y, m, d)

func formatTime(us: int64; wholeSeconds: bool): NameResult =
  const
    UsPerSec = 1_000_000'i64
    SecPerDay = 86_400'i64
  let sec = floorDiv(us, UsPerSec)
  let remUs = floorMod(us, UsPerSec)
  let days = floorDiv(sec, SecPerDay)
  let sod = floorMod(sec, SecPerDay)
  let date = civilFromDays(days)
  if date.y < 0 or date.y > 9999:
    return refused("Time is outside the years a file name can hold.")
  let hh = sod div 3600
  let mm = (sod div 60) mod 60
  let ss = sod mod 60
  var name = zeroPad(date.y, 4) & zeroPad(date.m, 2) & zeroPad(date.d, 2) & "T" &
    zeroPad(hh, 2) & zeroPad(mm, 2) & zeroPad(ss, 2)
  if not wholeSeconds:
    name.add zeroPad(remUs, 6)
  name.add "Z"
  accepted(name)

func renderPiece(part: NamePart; v: NameValue; sep: char): NameResult =
  let word = partWord(part.kind)
  if part.kind == npText:
    let why = textProblem(word, part.text, sep)
    if why.len > 0: return refused(why)
    return accepted(part.text)
  case v.state
  of nvMissing: refused(word & " is not in this file.")
  of nvMixed: refused(word & " is not one value in this file.")
  of nvTimeUs:
    if part.kind != npTime: refused(word & " is not in this file.")
    else: formatTime(v.timeUs, v.wholeSeconds)
  of nvInt:
    let piece = formatInt(v.intValue, part.pad)
    if isDeviceName(piece): refused(deviceSentence(piece))
    else: accepted(piece)
  of nvNumber:
    if v.number.isNaN or abs(v.number) >= 1e15:
      refused(word & " is not in this file.")
    else:
      let piece = formatNumber(v.number, part.pad)
      if isDeviceName(piece): refused(deviceSentence(piece))
      else: accepted(piece)
  of nvText:
    let why = textProblem(word, v.text, sep)
    if why.len > 0: refused(why)
    else: accepted(v.text)

func extensionProblem(ext: string): string =
  ## "" when `ext` may end a file name: empty, or one dot and 1 to 16
  ## letters or digits. A missing dot is not added.
  if ext.len == 0: return ""
  if ext[0] != '.' or ext.len < 2 or ext.len > 17:
    return "The extension " & ext & " cannot be used."
  for i in 1 ..< ext.len:
    if ext[i] notin Letters + Digits:
      return "The extension " & ext & " cannot be used."
  ""

func render*(p: OutputPattern; v: NameValues; extension: string): NameResult {.raises: [].} =
  ## The leaf `p` makes from `v`, with `extension` on the end. `problem` is
  ## one sentence when that file cannot be named, and `name` is then "".
  ## A width does not cut a wider number. `extension` is empty, or one dot
  ## and 1 to 16 letters or digits; anything else is refused. Never raises.
  if p.parts.len == 0:
    return refused("The name pattern has no parts.")
  var pieces = newSeq[string]()
  let sep = ($p.separator)[0]
  for part in p.parts:
    let one = renderPiece(part, v[part.kind], sep)
    if one.problem.len > 0: return one
    pieces.add one.name
  let stem = pieces.join($p.separator)
  if isDeviceName(stem): return refused(deviceSentence(stem))
  let extWhy = extensionProblem(extension)
  if extWhy.len > 0: return refused(extWhy)
  let leaf = stem & extension
  if leaf.len == 0 or leaf[^1] in {'.', ' '}:
    return refused("The file name ends with a dot or a space.")
  if '/' in leaf or '\\' in leaf:
    return refused("The file name is not a single name.")
  if validateUtf8(leaf) >= 0:
    return refused("The file name is not text.")
  if leaf.runeLen > MaxFileNameRunes:
    return refused("The file name is longer than " & $MaxFileNameRunes & " characters.")
  accepted(leaf)

func patternProblem*(p: OutputPattern): string =
  ## Why `p` cannot be kept; "" when it can. The label follows the same
  ## rules as a display preset's name. At most 16 parts; a width is 0 to
  ## 12; a text part is a piece of a file name and holds no separator of
  ## the pattern.
  let n = strip(p.name)
  if n.len == 0: return "a name pattern needs a name"
  if validateUtf8(n) >= 0: return "a name pattern's name is not text (not UTF-8)"
  if n.runeLen > MaxPatternName:
    return "a name pattern's name is at most " & $MaxPatternName & " characters long"
  if n.contains(Controls): return "a name pattern's name holds no control characters"
  if p.parts.len == 0: return "a name pattern needs a part"
  if p.parts.len > MaxPatternParts:
    return "a name pattern has at most " & $MaxPatternParts & " parts"
  for part in p.parts:
    if part.pad < 0 or part.pad > MaxPad:
      return partWord(part.kind) & "'s width is from 0 to " & $MaxPad
    if part.kind == npText:
      let why = textProblem(partWord(npText), part.text, ($p.separator)[0])
      if why.len > 0: return why
  ""
