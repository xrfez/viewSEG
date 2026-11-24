## A shot log: delimited text from a navigation or source-controller system,
## one row per shot. The file's text is kept once and cells are slices of it
## (`cell`), so a log of 100 000 rows is an index, not a copy of every cell.
## The caller reads the file; nothing here touches the file system.
##
## A `ShotLogMap` says which column is which (`ColumnRole`), which clock the
## split fields and the date-time text are on, and which sentinels mean
## missing. `guessMap` is a starting point from the header names and the
## first rows; the roles can be set without it. `shots` turns the rows into
## typed values and one UTC instant per row (microseconds since 1970).
## A row that is short, long, unreadable or inconsistent is kept, and the
## fault is a `ShotProblem`, not an exception. The first 100 are kept and
## `count` is the rest as well.
##
## `setCell` overlays one line on a cell and refuses a newline. `toText`
## writes the log back with the same delimiter and the same header; an
## unedited log is the text that was parsed, byte for byte.

import std/[hashes, math, options, parseutils, strutils, tables]
import parseSEG

const
  ProblemCap* = 100
    ## problems kept, with row and column; `count` still grows past this
  DefaultSentinels* = [
    "-999.9", "-999.99", "-999.999", "-999", "-9999", "-9999.0", "-99999"]
    ## values `initShotLogMap` treats as missing, besides a blank cell
  UsPerSec = 1_000_000'i64
  DisagreeUs = 1_000'i64        ## sources further apart than this are a problem
  MixedClockUs = 18_000_000'i64 ## GPS ahead of UTC by 18 s since 2017

type
  Delimiter* = enum
    dlComma = "comma"
    dlTab = "tab"
    dlSemicolon = "semicolon"
    dlSpaces = "spaces"

  ColumnRole* = enum
    ## What a column of a shot log means. `$` and `label` are the plain words.
    crIgnored = "ignored"
    crSequence = "sequence"
    crFileNumber = "file number"
    crStatus = "status"
    crSailLine = "sail line"
    crSourceLine = "source line"
    crShotPoint = "shot point"
    crPointIndex = "point index"
    crGpsMicros = "GPS microseconds"
    crUtcMicros = "UTC microseconds"
    crUtcSeconds = "UTC seconds"
    crYear = "year"
    crDayOfYear = "day of year"
    crMonth = "month"
    crDayOfMonth = "day of month"
    crHour = "hour"
    crMinute = "minute"
    crSecond = "second"
    crMicrosecond = "microsecond"
    crDateTime = "date-time text"
    crSourceDepth = "source depth"
    crWaterDepth = "water depth"
    crX = "X"
    crY = "Y"
    crZ = "Z"
    crSourceType = "source type"
    crSourceId = "source id"
    crGunArray = "gun array"
    crVolume = "volume"
    crPressure = "pressure"
    crHeading = "heading"
    crSpeed = "speed"
    crText = "text"

  TimeClock* = enum
    ## The clock of the split fields and of the date-time text.
    tcUtc = "UTC"
    tcGps = "GPS"

  LengthUnit* = enum
    ## The unit note for depth and XY. Stored, not converted.
    luMetres = "metres"
    luFeet = "feet"

  ProblemKind* = enum
    pkShortRow = "short row"
    pkLongRow = "long row"
    pkBadNumber = "bad number"
    pkTimeDisagree = "time disagreement"
    pkTimeBackward = "time going backwards"
    pkDuplicateShot = "duplicate shot"
    pkDuplicateFile = "duplicate file number"
    pkTooLong = "too long"

  ShotProblem* = object
    ## One fault in a log or in the typed view of it.
    kind*: ProblemKind
    row*: int     ## data row, 0-based; -1 when it is not a row
    col*: int     ## column, 0-based; -1 when it is not a column
    text*: string ## what is wrong, naming the values

  ProblemList* = object
    ## The first `ProblemCap` faults, and how many there were in all.
    items*: seq[ShotProblem]
    count*: int

  ShotLogMap* = object
    ## How to read a shot log. Every field can be set without `guessMap`.
    delimiter*: Delimiter
    skipLines*: int         ## physical lines before the header (or the first row)
    hasHeader*: bool
    roles*: seq[ColumnRole] ## one per column; a missing entry is `crText`
    clock*: TimeClock       ## split fields and date-time text
    dateTimePattern*: string
      ## `yyyy`, `mm`, `dd`, `hh`, `ss`, `f` and literals, as in
      ## `yyyy/mm/dd hh:mm:ss.ffffff`. Empty: recognize that form and ISO.
    sentinels*: seq[string] ## cell text that means missing, besides a blank
    decimalComma*: bool
      ## When set, a comma in a numeric cell is the decimal point. Default
      ## false. `guessMap` sets it only when the delimiter is not a comma and
      ## number columns use `digits,digits` rather than `digits.digits`.
    lengthUnit*: LengthUnit

  Shot* = object
    ## Typed values of one row. An integer is `none` when missing or a
    ## sentinel; a float is NaN. `timeUtcUs` is the one instant, UTC
    ## microseconds since 1970, from the most trusted source that parsed.
    sequence*: Option[int64]
    fileNumber*: Option[int64]
    status*: string
    sailLine*: float64
    sourceLine*: float64
    shotPoint*: float64
    pointIndex*: Option[int64]
    timeUtcUs*: Option[int64]
    sourceDepth*: float64
    waterDepth*: float64
    x*: float64
    y*: float64
    z*: float64
    sourceType*: string
    sourceId*: string
    gunArray*: string
    volume*: float64
    pressure*: float64
    heading*: float64
    speed*: float64
    year*: Option[int64]
    dayOfYear*: Option[int64]
    month*: Option[int64]
    dayOfMonth*: Option[int64]
    hour*: Option[int64]
    minute*: Option[int64]
    second*: float64 ## the second column, fraction kept; NaN when absent
    microsecond*: Option[int64]
    dateTime*: string
    texts*: seq[string] ## columns whose role is `crText`, in column order

  ShotView* = object
    ## `shots`: one entry per data row, and every fault of the log and of
    ## the typed reading.
    rows*: seq[Shot]
    problems*: ProblemList

  ShotLog* = ref object
    ## The text and an index of field bounds. Edits live in `edits` and do
    ## not rewrite `text` until `toText`.
    text: string
    delimiter: Delimiter
    skipLines: int
    hasHeader: bool
    lineStart: seq[int32]
    lineStop: seq[int32]
    lineNext: seq[int32]
    headerLine: int
    headerField: int32
    headerCount: int
    width: int
    dataLine: seq[int32]
    fieldStart: seq[int32]
    fieldStop: seq[int32]
    fieldOf: seq[int32] ## row r starts at fieldOf[r]; fieldOf[^1] is the end
    problems: ProblemList
    edits: Table[int64, string]

  Instant = object
    name: string
    us: int64
    col: int

func label*(role: ColumnRole): string {.inline.} =
  ## The plain words a later column map shows for `role`.
  $role

func initShotLogMap*(): ShotLogMap =
  ## A comma log with a header, UTC times, metres, and `DefaultSentinels`.
  result = ShotLogMap(delimiter: dlComma, hasHeader: true, clock: tcUtc,
    lengthUnit: luMetres)
  result.sentinels = @DefaultSentinels

func toPosixSeconds*(utcUs: int64): float64 {.inline.} =
  ## POSIX seconds of UTC microseconds since 1970, the unit of
  ## `TraceKeys.time`. The integer microseconds stay exact; this float is
  ## the seconds.
  float64(utcUs) / float64(UsPerSec)

func mulUs(v: int64): tuple[ok: bool; us: int64] =
  ## `v` microseconds-per-unit, or not ok when `v * 1_000_000` does not fit.
  const lim = high(int64) div UsPerSec
  const limLo = low(int64) div UsPerSec
  if v > lim or v < limLo: return
  (true, v * UsPerSec)

func add64(a, b: int64): tuple[ok: bool; v: int64] =
  if b > 0 and a > high(int64) - b: return
  if b < 0 and a < low(int64) - b: return
  (true, a + b)

func accDigit[T: int | int64](v: var T; digit: int): bool =
  ## False when the next digit would overflow `T`. `v` stays unchanged then.
  if digit notin 0 .. 9: return false
  if v > (high(T) - T(digit)) div 10: return false
  v = v * 10 + T(digit)
  true

proc gpsMicrosToUtcMicros*(gpsUs: int64): int64 {.raises: [].} =
  ## UTC microseconds since 1970 of `gpsUs` microseconds since the GPS
  ## epoch (1980-01-06). parseSEG exports `gpsMinusUtc` (GPS minus UTC,
  ## whole seconds) and `GpsEpochUnix`; the leap table itself is not
  ## exported, so the integer instant is `gpsUs` plus the epoch minus that
  ## offset. The float form `timestampToUnix` is the check, not the value.
  ## When that instant does not fit in an int64, the result is `low(int64)`,
  ## which is not a time in 1900..2200.
  var leap = 0
  try:
    leap = gpsMinusUtc(gpsUs)
  except CatchableError:
    let unix = timestampToUnix(gpsUs)
    let raw = round(float64(gpsUs) / 1e6 + float64(GpsEpochUnix) - unix)
    if raw != raw or raw < float64(low(int)) or raw > float64(high(int)):
      return low(int64)
    leap = int(raw)
  let epochUs = mulUs(GpsEpochUnix)
  let leapUs = mulUs(int64(leap))
  if not epochUs.ok or not leapUs.ok: return low(int64)
  let shifted = add64(gpsUs, epochUs.us)
  if not shifted.ok: return low(int64)
  let utc = add64(shifted.v, -leapUs.us)
  if not utc.ok: return low(int64)
  utc.v

proc addProblem(list: var ProblemList; kind: ProblemKind; row, col: int;
    text: string) =
  inc list.count
  if list.items.len < ProblemCap:
    list.items.add ShotProblem(kind: kind, row: row, col: col, text: text)

func daysFromCivil(y, m, d: int): int64 =
  ## Days since 1970-01-01 of a proleptic Gregorian date. Integer only.
  var yy = y
  if m <= 2: dec yy
  let era = if yy >= 0: yy else: yy - 399
  let era400 = era div 400
  let yoe = yy - era400 * 400
  let mp = (m + 9) mod 12
  let doy = (153 * mp + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  int64(era400) * 146097 + int64(doe) - 719468

const
  InstantLo = daysFromCivil(1900, 1, 1) * 86_400 * UsPerSec
  InstantHi = daysFromCivil(2201, 1, 1) * 86_400 * UsPerSec - 1
    ## UTC microseconds of years 1900..2200, inclusive of the last microsecond.

func isLeap(y: int): bool {.inline.} =
  (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0

func daysInMonth(y, m: int): int =
  const md = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  if m == 2 and isLeap(y): 29
  elif m in 1 .. 12: md[m]
  else: 0

func validDate(y, m, d: int): bool {.inline.} =
  y in 1 .. 9999 and d in 1 .. daysInMonth(y, m)

func doyToMonthDay(year, doy: int): tuple[ok: bool; month, day: int] =
  let last = if isLeap(year): 366 else: 365
  if doy < 1 or doy > last: return
  const
    plain = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365]
    leap = [0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366]
  let cum = if isLeap(year): leap else: plain
  var month = 1
  while month <= 12 and doy > cum[month]: inc month
  (true, month, doy - cum[month - 1])

func fitsOffset(v: int): bool {.inline.} =
  v >= 0 and v <= high(int32)

func delimChar(d: Delimiter): char =
  case d
  of dlComma: ','
  of dlTab: '\t'
  of dlSemicolon: ';'
  of dlSpaces: ' '

func closeQuote(text: string; open, stop: int): int =
  ## Index just after the quote that closes the one at `open`, or `stop`.
  result = open + 1
  while result < stop:
    if text[result] == '"':
      if result + 1 < stop and text[result + 1] == '"':
        result += 2
      else:
        inc result
        return
    else:
      inc result

proc scanFields(text: string; start, stop: int; d: Delimiter; starts,
    stops: var seq[int32]) =
  ## Field bounds in `text[start ..< stop]`, quotes included. A run of
  ## spaces is one delimiter; a comma, tab or semicolon is one each, so an
  ## empty field is kept.
  if start >= stop: return
  if d == dlSpaces:
    var i = start
    while i < stop and text[i] == ' ': inc i
    while i < stop:
      let fs = i
      if text[i] == '"':
        i = closeQuote(text, i, stop)
      else:
        while i < stop and text[i] != ' ': inc i
      if not fitsOffset(fs) or not fitsOffset(i): return
      starts.add int32(fs)
      stops.add int32(i)
      while i < stop and text[i] == ' ': inc i
  else:
    let ch = delimChar(d)
    var i = start
    while true:
      let fs = i
      if i < stop and text[i] == '"':
        i = closeQuote(text, i, stop)
      else:
        while i < stop and text[i] != ch: inc i
      if not fitsOffset(fs) or not fitsOffset(i): return
      starts.add int32(fs)
      stops.add int32(i)
      if i < stop and text[i] == ch: inc i
      else: break

proc unquoteRange(text: string; a, b: int): string =
  if b - a >= 2 and text[a] == '"' and text[b - 1] == '"':
    result = newStringOfCap(b - a - 2)
    var i = a + 1
    let last = b - 1
    while i < last:
      if text[i] == '"' and i + 1 < last and text[i + 1] == '"':
        result.add '"'
        i += 2
      else:
        result.add text[i]
        inc i
  elif b > a:
    result = text.substr(a, b - 1)

func cellKey(row, col: int): int64 {.inline.} =
  (int64(row) shl 32) or (int64(uint32(col)))

func addSlice(buf: var string; s: string; a, b: int) =
  if b > a: buf.add s.substr(a, b - 1)

proc needsQuote(s: string; d: Delimiter): bool =
  let ch = delimChar(d)
  for c in s:
    if c == ch or c == '"' or c == '\n' or c == '\r': return true
  false

proc quoteField(s: string; d: Delimiter): string =
  if not needsQuote(s, d): return s
  result = newStringOfCap(s.len + 2)
  result.add '"'
  for c in s:
    if c == '"': result.add '"'
    result.add c
  result.add '"'

proc tooLongLog(delimiter: Delimiter; skip: int; hasHeader: bool): ShotLog =
  result = ShotLog(delimiter: delimiter, skipLines: skip, hasHeader: hasHeader,
    headerLine: -1, headerField: -1, edits: initTable[int64, string]())
  addProblem(result.problems, pkTooLong, -1, -1,
    "text longer than " & $high(int32) & " bytes")

proc parseShotLog*(text: sink string; delimiter: Delimiter; skipLines = 0;
    hasHeader = true): ShotLog {.raises: [].} =
  ## Indexes `text`. `skipLines` physical lines are ignored, then a header
  ## line if `hasHeader`, then one data row per remaining non-blank line.
  ## A row with fewer or more fields than the header (or than the first
  ## data row, when there is no header) is kept and listed. Line endings
  ## may be LF or CRLF. Quoted fields may contain the delimiter and a
  ## doubled quote. A text longer than `high(int32)` bytes is not indexed:
  ## the log is empty and one problem names the limit.
  let skip = if skipLines < 0: 0 else: skipLines
  if text.len > high(int32):
    return tooLongLog(delimiter, skip, hasHeader)
  result = ShotLog(text: text, delimiter: delimiter, skipLines: skip,
    hasHeader: hasHeader, headerLine: -1, headerField: -1,
    edits: initTable[int64, string]())
  let capFields = max(16, result.text.len div 4)
  result.fieldStart = newSeqOfCap[int32](capFields)
  result.fieldStop = newSeqOfCap[int32](capFields)
  let n = result.text.len
  var i = 0
  while i < n:
    let start = i
    var j = i
    while j < n and result.text[j] != '\n' and result.text[j] != '\r':
      inc j
    let stop = j
    if j < n and result.text[j] == '\r':
      inc j
      if j < n and result.text[j] == '\n': inc j
    elif j < n and result.text[j] == '\n':
      inc j
    if not fitsOffset(start) or not fitsOffset(stop) or not fitsOffset(j):
      return tooLongLog(delimiter, skip, hasHeader)
    result.lineStart.add int32(start)
    result.lineStop.add int32(stop)
    result.lineNext.add int32(j)
    i = j
  if hasHeader and skip < result.lineStart.len:
    result.headerLine = skip
    let hs = result.lineStart[skip].int
    let he = result.lineStop[skip].int
    if not fitsOffset(result.fieldStart.len):
      return tooLongLog(delimiter, skip, hasHeader)
    result.headerField = int32(result.fieldStart.len)
    if he > hs:
      scanFields(result.text, hs, he, delimiter, result.fieldStart, result.fieldStop)
    result.headerCount = result.fieldStart.len - result.headerField.int
    result.width = result.headerCount
  let first = skip + (if hasHeader: 1 else: 0)
  var row = 0
  if first < result.lineStart.len:
    for lineIdx in first ..< result.lineStart.len:
      let a = result.lineStart[lineIdx].int
      let b = result.lineStop[lineIdx].int
      if a != b:
        let before = result.fieldStart.len
        scanFields(result.text, a, b, delimiter, result.fieldStart, result.fieldStop)
        let count = result.fieldStart.len - before
        if count > 0:
          if not fitsOffset(before) or not fitsOffset(lineIdx):
            return tooLongLog(delimiter, skip, hasHeader)
          result.fieldOf.add int32(before)
          result.dataLine.add int32(lineIdx)
          if not hasHeader and result.width == 0:
            result.width = count
          if count < result.width:
            addProblem(result.problems, pkShortRow, row, count,
              $count & " fields, expected " & $result.width)
          elif count > result.width:
            addProblem(result.problems, pkLongRow, row, result.width,
              $count & " fields, expected " & $result.width)
          inc row
  if not fitsOffset(result.fieldStart.len):
    return tooLongLog(delimiter, skip, hasHeader)
  result.fieldOf.add int32(result.fieldStart.len)

proc parseShotLog*(text: sink string; map: ShotLogMap): ShotLog {.raises: [].} =
  ## Indexes `text` with `map.delimiter`, `map.skipLines` and `map.hasHeader`.
  ## The roles are not applied here; `shots` does that.
  parseShotLog(text, map.delimiter, map.skipLines, map.hasHeader)

func len*(log: ShotLog): int {.inline.} =
  ## Data rows. The header is not one of them.
  if log.fieldOf.len == 0: 0 else: log.fieldOf.len - 1

func width*(log: ShotLog): int {.inline.} =
  ## Columns of the header, or of the first data row when there is no header.
  log.width

func delimiter*(log: ShotLog): Delimiter {.inline.} = log.delimiter

func hasHeader*(log: ShotLog): bool {.inline.} = log.hasHeader

func skipLines*(log: ShotLog): int {.inline.} = log.skipLines

func fields*(log: ShotLog; row: int): int {.inline.} =
  ## Fields stored for data row `row`, which may be less or more than `width`.
  if row < 0 or row + 1 >= log.fieldOf.len: 0
  else: int(log.fieldOf[row + 1] - log.fieldOf[row])

func problems*(log: ShotLog): ProblemList {.inline.} =
  ## Short and long rows found while indexing.
  log.problems

proc columnName*(log: ShotLog; col: int): string {.raises: [].} =
  ## The header cell, quotes removed and ends trimmed. Empty when there is
  ## no header or `col` is outside it.
  if log.headerLine < 0 or col < 0 or col >= log.headerCount: return ""
  let a = log.fieldStart[log.headerField.int + col].int
  let b = log.fieldStop[log.headerField.int + col].int
  unquoteRange(log.text, a, b).strip()

func text*(log: ShotLog): lent string =
  ## The text that was parsed. An edit is not in it until `toText`.
  log.text

proc cell*(log: ShotLog; row, col: int): string {.raises: [].} =
  ## The cell a grid shows: the overlay if `setCell` changed it, otherwise
  ## the field with its quotes removed and a doubled quote collapsed to one.
  ## Spaces around an unquoted field are kept. An absent field is empty.
  let k = cellKey(row, col)
  if log.edits.hasKey(k): return log.edits.getOrDefault(k)
  if row < 0 or row + 1 >= log.fieldOf.len: return ""
  let base = log.fieldOf[row].int
  let count = log.fieldOf[row + 1].int - base
  if col < 0 or col >= count: return ""
  unquoteRange(log.text, log.fieldStart[base + col].int, log.fieldStop[base + col].int)

proc fileCell*(log: ShotLog; row, col: int): string {.raises: [].} =
  ## The cell as the file has it, quotes removed. An overlay from `setCell`
  ## is ignored. An absent field is empty.
  if row < 0 or row + 1 >= log.fieldOf.len: return ""
  let base = log.fieldOf[row].int
  let count = log.fieldOf[row + 1].int - base
  if col < 0 or col >= count: return ""
  unquoteRange(log.text, log.fieldStart[base + col].int, log.fieldStop[base + col].int)

proc cellDiffers*(log: ShotLog; row, col: int): bool {.raises: [].} =
  ## True when the text a grid shows is not the file's own text.
  log.cell(row, col) != log.fileCell(row, col)

proc setCell*(log: ShotLog; row, col: int; text: sink string): bool {.raises: [].} =
  ## Remembers `text` as the cell a later `cell` and `toText` use, without
  ## rewriting the stored file text. One line: a newline is refused, the
  ## cell is left unchanged, and the result is false.
  if '\n' in text or '\r' in text: return false
  log.edits[cellKey(row, col)] = text
  true

proc revert*(log: ShotLog; row, col: int) {.raises: [].} =
  ## Drops the overlay on one cell. A cell that was not changed is left as it is.
  log.edits.del(cellKey(row, col))

func changed*(log: ShotLog): bool {.inline.} =
  ## True when any cell has an overlay.
  log.edits.len > 0

proc emitRow(log: ShotLog; row, line: int; buf: var string) =
  let base = log.fieldOf[row].int
  let count = log.fieldOf[row + 1].int - base
  let lineStart = log.lineStart[line].int
  let lineStop = log.lineStop[line].int
  let lineNext = log.lineNext[line].int
  var maxCol = count - 1
  for k, _ in log.edits:
    if int(k shr 32) == row:
      let c = int(uint32(k))
      if c > maxCol: maxCol = c
  var prev = lineStart
  if count > 0:
    for f in 0 ..< count:
      let fs = log.fieldStart[base + f].int
      let fe = log.fieldStop[base + f].int
      addSlice(buf, log.text, prev, fs)
      let k = cellKey(row, f)
      if log.edits.hasKey(k):
        buf.add quoteField(log.edits.getOrDefault(k), log.delimiter)
      else:
        addSlice(buf, log.text, fs, fe)
      prev = fe
  addSlice(buf, log.text, prev, lineStop)
  if maxCol >= count:
    for f in count .. maxCol:
      buf.add delimChar(log.delimiter)
      let k = cellKey(row, f)
      if log.edits.hasKey(k):
        buf.add quoteField(log.edits.getOrDefault(k), log.delimiter)
  addSlice(buf, log.text, lineStop, lineNext)

proc toText*(log: ShotLog): string {.raises: [].} =
  ## The log as delimited text: the same delimiter, the same header, and
  ## the overlay where a cell was changed. With no overlay this is the text
  ## that was parsed, byte for byte.
  if log.edits.len == 0: return log.text
  result = newStringOfCap(log.text.len + 32)
  var row = 0
  for line in 0 ..< log.lineStart.len:
    if row < log.dataLine.len and log.dataLine[row].int == line:
      var touched = false
      for k, _ in log.edits:
        if int(k shr 32) == row:
          touched = true
          break
      if touched:
        emitRow(log, row, line, result)
      else:
        addSlice(result, log.text, log.lineStart[line].int, log.lineNext[line].int)
      inc row
    else:
      addSlice(result, log.text, log.lineStart[line].int, log.lineNext[line].int)

const Aliases = [
  ("sequence", crSequence), ("seq", crSequence), ("shotsequence", crSequence),
  ("sequencenumber", crSequence), ("seqno", crSequence),
  ("filenumber", crFileNumber), ("fileno", crFileNumber), ("ffid", crFileNumber),
  ("fieldfile", crFileNumber), ("fieldfilenumber", crFileNumber),
  ("file", crFileNumber),
  ("status", crStatus), ("shotstatus", crStatus),
  ("sailline", crSailLine), ("saillinenumber", crSailLine), ("sail", crSailLine),
  ("sourceline", crSourceLine), ("srcline", crSourceLine),
  ("sourcelinenumber", crSourceLine),
  ("shotpoint", crShotPoint), ("sourcepoint", crShotPoint),
  ("srcpoint", crShotPoint), ("sp", crShotPoint), ("shot", crShotPoint),
  ("point", crShotPoint),
  ("pointindex", crPointIndex), ("shotindex", crPointIndex),
  ("srcindex", crPointIndex), ("index", crPointIndex), ("idx", crPointIndex),
  ("gpsmicroseconds", crGpsMicros), ("gpstimemicroseconds", crGpsMicros),
  ("timebreakmicroseconds", crGpsMicros), ("timebreakus", crGpsMicros),
  ("gpsus", crGpsMicros), ("gpstime", crGpsMicros), ("timebreak", crGpsMicros),
  ("tb", crGpsMicros),
  ("utcmicroseconds", crUtcMicros), ("utcus", crUtcMicros),
  ("unixtimeus", crUtcMicros),
  ("utcseconds", crUtcSeconds), ("epochseconds", crUtcSeconds),
  ("unixtime", crUtcSeconds), ("utcs", crUtcSeconds), ("posix", crUtcSeconds),
  ("year", crYear), ("yr", crYear),
  ("dayofyear", crDayOfYear), ("julianday", crDayOfYear), ("julian", crDayOfYear),
  ("jday", crDayOfYear), ("doy", crDayOfYear),
  ("month", crMonth), ("mon", crMonth),
  ("dayofmonth", crDayOfMonth), ("dom", crDayOfMonth), ("day", crDayOfMonth),
  ("hour", crHour), ("hr", crHour), ("hh", crHour),
  ("minute", crMinute), ("min", crMinute),
  ("microsecond", crMicrosecond), ("microseconds", crMicrosecond),
  ("usec", crMicrosecond),
  ("second", crSecond), ("sec", crSecond), ("ss", crSecond),
  ("datetimeutc", crDateTime), ("datetimetext", crDateTime),
  ("datetime", crDateTime), ("timestamp", crDateTime), ("shottime", crDateTime),
  ("date", crDateTime), ("time", crDateTime),
  ("sourcedepth", crSourceDepth), ("gundepth", crSourceDepth),
  ("srcdepth", crSourceDepth), ("depth", crSourceDepth),
  ("waterdepth", crWaterDepth), ("seafloor", crWaterDepth), ("wd", crWaterDepth),
  ("easting", crX), ("longitude", crX), ("lon", crX), ("east", crX), ("x", crX),
  ("northing", crY), ("latitude", crY), ("lat", crY), ("north", crY), ("y", crY),
  ("elevation", crZ), ("elev", crZ), ("height", crZ), ("z", crZ),
  ("sourcetype", crSourceType), ("srctype", crSourceType), ("type", crSourceType),
  ("sourceids", crSourceId), ("sourceid", crSourceId), ("srcid", crSourceId),
  ("gunid", crSourceId), ("id", crSourceId),
  ("gunarray", crGunArray), ("subarray", crGunArray), ("array", crGunArray),
  ("gunvolume", crVolume), ("volume", crVolume), ("vol", crVolume),
  ("airpressure", crPressure), ("pressure", crPressure), ("pres", crPressure),
  ("heading", crHeading), ("bearing", crHeading), ("gyro", crHeading),
  ("hdg", crHeading),
  ("vesselspeed", crSpeed), ("speed", crSpeed), ("sog", crSpeed)]

func normHeader(s: string): string =
  ## Letters only, lower case, with a leading number prefix such as `07_`
  ## and a parenthetical unit dropped.
  var i = 0
  var j = 0
  while j < s.len and s[j] in Digits: inc j
  if j > 0 and j < s.len and s[j] in {'_', '-', ' ', '.'}:
    i = j + 1
  result = newStringOfCap(s.len - i)
  var k = i
  while k < s.len:
    let c = s[k]
    if c == '(':
      let close = s.find(')', k)
      if close >= 0: k = close + 1
      else: inc k
    elif c in Letters:
      result.add c.toLowerAscii
      inc k
    else:
      inc k

func roleOfName(raw: string): ColumnRole =
  let n = normHeader(raw)
  if n.len == 0: return crText
  for a in Aliases:
    if a[0] == n: return a[1]
  crText

func hasLetter(s: string): bool =
  for c in s:
    if c in Letters: return true
  false

func mentionsFeet(name: string): bool =
  let n = name.toLowerAscii
  "feet" in n or "(ft)" in n or "_ft" in n or " ft" in n or n.endsWith("ft")

proc countDelim(text: string; a, b: int; ch: char): int =
  var i = a
  var inQuote = false
  while i < b:
    if text[i] == '"':
      if inQuote and i + 1 < b and text[i + 1] == '"': i += 2
      else:
        inQuote = not inQuote
        inc i
    else:
      if not inQuote and text[i] == ch: inc result
      inc i

func firstChar(text: string; a, b: int): char =
  var i = a
  while i < b and text[i] == ' ': inc i
  if i < b: text[i] else: '\0'

proc detectPattern(s: string): string =
  ## `yyyy/mm/dd hh:mm:ss.f` or an ISO form, or "" when `s` is neither.
  let t = s.strip
  if t.len < 10: return ""
  for k in 0 .. 3:
    if t[k] notin Digits: return ""
  let sep = t[4]
  if sep notin {'/', '-'}: return ""
  if t[7] != sep: return ""
  for k in [5, 6, 8, 9]:
    if t[k] notin Digits: return ""
  result = "yyyy" & sep & "mm" & sep & "dd"
  var i = 10
  if i >= t.len or t[i] notin {' ', 'T'}: return ""
  result.add t[i]
  inc i
  if i + 8 > t.len: return ""
  for k in 0 .. 7:
    let c = t[i + k]
    if k in {2, 5}:
      if c != ':': return ""
    elif c notin Digits:
      return ""
  result.add "hh:mm:ss"
  i += 8
  if i < t.len and t[i] == '.':
    result.add '.'
    inc i
    var f = 0
    while i < t.len and t[i] in Digits:
      result.add 'f'
      inc i
      inc f
    if f == 0: return ""
  if i < t.len and t[i] in {'Z', 'z'}:
    result.add 'Z'
    inc i
  if i != t.len: result = ""

proc isGpsMicrosText(s: string): bool =
  let t = s.strip
  if t.len != 16: return false
  for c in t:
    if c notin Digits: return false
  let head = (ord(t[0]) - ord('0')) * 10 + (ord(t[1]) - ord('0'))
  head in 11 .. 16

proc isYearText(s: string): bool =
  let t = s.strip
  if t.len != 4: return false
  var y = 0
  for c in t:
    if c notin Digits: return false
    y = y * 10 + (ord(c) - ord('0'))
  y in 1900 .. 2099

proc guessFromCells(cells: openArray[string]): tuple[role: ColumnRole; pattern: string] =
  ## GPS microseconds, a year, or date-time text, when every non-empty cell
  ## agrees. Otherwise `crText`.
  result = (crText, "")
  var n = 0
  var gps, year, time = 0
  var pattern = ""
  for c in cells:
    let t = c.strip
    if t.len == 0: discard
    else:
      inc n
      if isGpsMicrosText(t): inc gps
      if isYearText(t): inc year
      let p = detectPattern(t)
      if p.len > 0:
        inc time
        if pattern.len == 0: pattern = p
  if n == 0: return
  if time == n:
    return (crDateTime, pattern)
  if gps == n:
    return (crGpsMicros, "")
  if year == n:
    return (crYear, "")

type NumShape = enum
  nsBlank, nsInt, nsDot, nsComma, nsOther

func numShape(s: string): NumShape =
  ## `digits`, `digits.digits` or `digits,digits`, with an optional sign.
  let t = s.strip
  if t.len == 0: return nsBlank
  var i = 0
  if t[0] in {'+', '-'}: inc i
  if i >= t.len or t[i] notin Digits: return nsOther
  while i < t.len and t[i] in Digits: inc i
  if i == t.len: return nsInt
  let sep = t[i]
  if sep notin {'.', ','}: return nsOther
  inc i
  if i >= t.len or t[i] notin Digits: return nsOther
  while i < t.len and t[i] in Digits: inc i
  if i != t.len: nsOther elif sep == '.': nsDot else: nsComma

proc fieldText(text: string; a, b: int): string =
  unquoteRange(text, a, b)

proc lineDelimiter(text: string; a, b: int): Delimiter =
  ## The delimiter of one line: a tab if any, else a semicolon if it beats
  ## commas, else a comma, else runs of spaces.
  let tabs = countDelim(text, a, b, '\t')
  let semis = countDelim(text, a, b, ';')
  let commas = countDelim(text, a, b, ',')
  if tabs > 0 and tabs >= commas and tabs >= semis: dlTab
  elif semis > commas and semis > 0: dlSemicolon
  elif commas > 0: dlComma
  else: dlSpaces

proc nameLike(s: string): bool =
  ## A header cell: a letter, and not a date-time such as an ISO instant.
  hasLetter(s) and detectPattern(s).len == 0

proc guessMap*(text: string): ShotLogMap {.raises: [].} =
  ## A starting map: delimiter, lines to skip, whether a header is there,
  ## and a role per column. Header names are matched ignoring case, spaces,
  ## underscores and a leading number prefix such as `07_`. A name that is
  ## not known, and every column when there is no header, is judged from
  ## the first data rows: a 16-digit integer near 1.4e15 is GPS microseconds,
  ## a 4-digit 19xx or 20xx is a year, and `yyyy/mm/dd hh:mm:ss.f` or an ISO
  ## form is date-time text. Anything else is `crText`. The clock stays UTC
  ## and the length unit stays metres unless a header says feet.
  result = initShotLogMap()
  if text.len > high(int32): return
  var phys = 0
  var keptPhys: seq[int] = @[]
  var keptStart: seq[int] = @[]
  var keptStop: seq[int] = @[]
  var i = 0
  let n = text.len
  while i < n and keptPhys.len < 40:
    let start = i
    var j = i
    while j < n and text[j] != '\n' and text[j] != '\r': inc j
    let stop = j
    if j < n and text[j] == '\r':
      inc j
      if j < n and text[j] == '\n': inc j
    elif j < n and text[j] == '\n':
      inc j
    if stop > start and firstChar(text, start, stop) != '#':
      keptPhys.add phys
      keptStart.add start
      keptStop.add stop
    inc phys
    i = j
  var headerAt = -1
  for k in 0 ..< keptStart.len:
    let d = lineDelimiter(text, keptStart[k], keptStop[k])
    var starts: seq[int32] = @[]
    var stops: seq[int32] = @[]
    scanFields(text, keptStart[k], keptStop[k], d, starts, stops)
    var names = 0
    for c in 0 ..< starts.len:
      if nameLike(fieldText(text, starts[c].int, stops[c].int)): inc names
    if names >= 2:
      headerAt = k
      result.delimiter = d
      break
  if headerAt < 0:
    var commas, tabs, semis = 0
    for k in 0 ..< keptStart.len:
      if countDelim(text, keptStart[k], keptStop[k], ',') > 0: inc commas
      if countDelim(text, keptStart[k], keptStop[k], '\t') > 0: inc tabs
      if countDelim(text, keptStart[k], keptStop[k], ';') > 0: inc semis
    if tabs > 0 and tabs >= commas and tabs >= semis:
      result.delimiter = dlTab
    elif semis > commas and semis > 0:
      result.delimiter = dlSemicolon
    elif commas > 0:
      result.delimiter = dlComma
    else:
      result.delimiter = dlSpaces
  var dataFrom = 0
  if headerAt >= 0:
    result.hasHeader = true
    result.skipLines = keptPhys[headerAt]
    dataFrom = headerAt + 1
    var hStart: seq[int32] = @[]
    var hStop: seq[int32] = @[]
    scanFields(text, keptStart[headerAt], keptStop[headerAt], result.delimiter,
      hStart, hStop)
    result.roles.setLen hStart.len
    for c in 0 ..< hStart.len:
      let name = fieldText(text, hStart[c].int, hStop[c].int)
      result.roles[c] = roleOfName(name)
      if mentionsFeet(name): result.lengthUnit = luFeet
  else:
    result.hasHeader = false
    result.skipLines = if keptPhys.len > 0: keptPhys[0] else: 0
    dataFrom = 0
  var samples: seq[seq[string]] = @[]
  var taken = 0
  var k = dataFrom
  while k < keptStart.len and taken < 12:
    var starts: seq[int32] = @[]
    var stops: seq[int32] = @[]
    scanFields(text, keptStart[k], keptStop[k], result.delimiter, starts, stops)
    if starts.len > samples.len: samples.setLen starts.len
    for c in 0 ..< starts.len:
      samples[c].add fieldText(text, starts[c].int, stops[c].int)
    inc taken
    inc k
  if result.roles.len < samples.len:
    let old = result.roles.len
    result.roles.setLen samples.len
    for c in old ..< result.roles.len:
      result.roles[c] = crText
  for c in 0 ..< result.roles.len:
    if c < samples.len and (headerAt < 0 or result.roles[c] == crText):
      let g = guessFromCells(samples[c])
      if g.role != crText:
        result.roles[c] = g.role
      if g.pattern.len > 0 and result.dateTimePattern.len == 0:
        result.dateTimePattern = g.pattern
    elif result.roles[c] == crDateTime and c < samples.len and
        result.dateTimePattern.len == 0:
      let g = guessFromCells(samples[c])
      if g.pattern.len > 0: result.dateTimePattern = g.pattern
  if result.delimiter != dlComma:
    var commaDec, dotDec = false
    for col in samples:
      var numeric = false
      var other = false
      var colComma, colDot = false
      for cell in col:
        let shape = numShape(cell)
        if shape == nsOther:
          other = true
          break
        elif shape == nsComma:
          numeric = true
          colComma = true
        elif shape == nsDot:
          numeric = true
          colDot = true
        elif shape == nsInt:
          numeric = true
      if numeric and not other:
        if colComma: commaDec = true
        if colDot: dotDec = true
    if commaDec and not dotDec:
      result.decimalComma = true

const White = {' ', '\t', '\v', '\r', '\n', '\f'}

func trimSpan(s: openArray[char]): tuple[a, b: int] {.inline.} =
  result.a = 0
  result.b = s.len
  while result.a < result.b and s[result.a] in White: inc result.a
  while result.b > result.a and s[result.b - 1] in White: dec result.b

func copySpan(s: openArray[char]; a, b: int): string =
  result = newString(b - a)
  for i in a ..< b: result[i - a] = s[i]

func sameText(s: openArray[char]; a, b: int; lower: string): bool =
  if b - a != lower.len: return false
  for i in 0 ..< lower.len:
    if s[a + i].toLowerAscii != lower[i]: return false
  true

func dotDecimal(s: string; decimalComma: bool): string =
  ## `s`, with a comma written as a dot when `decimalComma`.
  if not decimalComma or ',' notin s: return s
  result = newString(s.len)
  for i, c in s:
    result[i] = if c == ',': '.' else: c

func parseSimple(s: openArray[char]; a, b: int; decimalComma: bool): tuple[ok: bool;
    value: float64] =
  var i = a
  if i >= b: return
  var neg = false
  if s[i] == '+': inc i
  elif s[i] == '-':
    neg = true
    inc i
  if i >= b or s[i] notin Digits: return
  var v = 0.0
  while i < b and s[i] in Digits:
    v = v * 10 + float64(ord(s[i]) - ord('0'))
    inc i
  let dec = if decimalComma: ',' else: '.'
  if i < b and s[i] == dec:
    inc i
    if i >= b: return
    var scale = 0.1
    while i < b and s[i] in Digits:
      v += float64(ord(s[i]) - ord('0')) * scale
      scale *= 0.1
      inc i
  if i != b: return
  if neg: v = -v
  (true, v)

func parseNum(s: openArray[char]; decimalComma = false): tuple[ok: bool; value: float64] =
  let span = trimSpan(s)
  if span.a >= span.b: return (false, NaN)
  let simple = parseSimple(s, span.a, span.b, decimalComma)
  if simple.ok: return simple
  var n = 0.0
  if not decimalComma:
    let c = parseutils.parseFloat(s.toOpenArray(span.a, span.b - 1), n)
    if c == span.b - span.a and c > 0: (true, n) else: (false, NaN)
  else:
    var comma = false
    for i in span.a ..< span.b:
      if s[i] == ',':
        comma = true
        break
    if not comma:
      let c = parseutils.parseFloat(s.toOpenArray(span.a, span.b - 1), n)
      if c == span.b - span.a and c > 0: (true, n) else: (false, NaN)
    elif span.b - span.a <= 128:
      var buf: array[128, char]
      var k = 0
      for i in span.a ..< span.b:
        buf[k] = if s[i] == ',': '.' else: s[i]
        inc k
      let c = parseutils.parseFloat(toOpenArray(buf, 0, k - 1), n)
      if c == k and c > 0: (true, n) else: (false, NaN)
    else:
      let t = dotDecimal(copySpan(s, span.a, span.b), true)
      let c = parseutils.parseFloat(t, n)
      if c == t.len and c > 0: (true, n) else: (false, NaN)

func isMissing(cell: openArray[char]; sentText: openArray[string];
    sentVal: openArray[float64]; decimalComma: bool): bool =
  let span = trimSpan(cell)
  if span.a >= span.b: return true
  let num = parseNum(cell, decimalComma)
  if num.ok:
    for v in sentVal:
      if num.value == v: return true
  for u in sentText:
    if sameText(cell, span.a, span.b, u): return true
  false

proc parseWhole(s: openArray[char]; decimalComma = false): tuple[ok: bool; value: int64] =
  let span = trimSpan(s)
  var i = span.a
  let n = span.b
  if i >= n: return
  var neg = false
  if s[i] == '+': inc i
  elif s[i] == '-':
    neg = true
    inc i
  if i >= n or s[i] notin Digits: return
  var v = 0'i64
  while i < n and s[i] in Digits:
    if not accDigit(v, ord(s[i]) - ord('0')): return
    inc i
  let dec = if decimalComma: ',' else: '.'
  if i < n and s[i] == dec:
    inc i
    if i >= n: return
    while i < n and s[i] == '0': inc i
  if i != n: return
  if neg: v = -v
  (true, v)

proc parseSecondsUs(s: openArray[char]; decimalComma = false): tuple[ok: bool; us: int64] =
  ## Microseconds from a seconds field, digits only, so a fraction is not
  ## rounded through `float64`. At most six fraction digits, then half-up.
  let span = trimSpan(s)
  if span.a >= span.b: return
  var i = span.a
  var neg = false
  if s[i] == '+': inc i
  elif s[i] == '-':
    neg = true
    inc i
  if i >= span.b or s[i] notin Digits: return
  var whole = 0'i64
  while i < span.b and s[i] in Digits:
    if not accDigit(whole, ord(s[i]) - ord('0')): return
    inc i
  var frac = 0'i64
  var digits = 0
  let dec = if decimalComma: ',' else: '.'
  if i < span.b and s[i] == dec:
    inc i
    if i >= span.b: return
    while i < span.b and s[i] in Digits and digits < 6:
      frac = frac * 10 + int64(ord(s[i]) - ord('0'))
      inc digits
      inc i
    var roundUp = false
    if i < span.b and s[i] in Digits:
      roundUp = ord(s[i]) - ord('0') >= 5
      while i < span.b and s[i] in Digits: inc i
    var scale = 1'i64
    for _ in digits ..< 6: scale *= 10
    frac *= scale
    if roundUp:
      inc frac
      if frac >= UsPerSec:
        frac -= UsPerSec
        if whole == high(int64): return
        inc whole
  if i != span.b: return
  let scaled = mulUs(whole)
  if not scaled.ok: return
  let summed = add64(scaled.us, frac)
  if not summed.ok: return
  var us = summed.v
  if neg: us = -us
  (true, us)

proc parseSecond(s: openArray[char]; decimalComma = false): tuple[ok: bool; sec, us: int] =
  ## Whole seconds and microseconds from a second field. The fraction is
  ## taken from the digits, so 59.999999 stays 59 s + 999999 us.
  let span = trimSpan(s)
  var i = span.a
  if i >= span.b: return
  if s[i] == '+': inc i
  if i >= span.b or s[i] notin Digits: return
  var sec = 0
  while i < span.b and s[i] in Digits:
    if not accDigit(sec, ord(s[i]) - ord('0')): return
    inc i
  var us = 0
  let dec = if decimalComma: ',' else: '.'
  if i < span.b and s[i] == dec:
    inc i
    var digits = 0
    var frac = 0
    while i < span.b and s[i] in Digits and digits < 6:
      frac = frac * 10 + (ord(s[i]) - ord('0'))
      inc digits
      inc i
    while i < span.b and s[i] in Digits: inc i
    if digits == 0: return
    var scale = 1
    for _ in digits ..< 6: scale *= 10
    us = frac * scale
  if i != span.b: return
  (true, sec, us)

proc matchPattern(text, pattern: string): tuple[ok: bool; y, m, d, hh, mm, ss, us: int] =
  let t = text.strip
  var ti = 0
  var pi = 0
  var seenHour = false
  result.ok = pattern.len > 0
  while result.ok and pi < pattern.len:
    let c = pattern[pi]
    let kind = c.toLowerAscii
    if kind in {'y', 'm', 'd', 'h', 's', 'f'}:
      var n = 0
      while pi < pattern.len and pattern[pi].toLowerAscii == kind:
        inc n
        inc pi
      if kind == 'f':
        var digits = 0
        var frac = 0
        while ti < t.len and t[ti] in Digits and digits < max(n, 6):
          if digits < 6:
            frac = frac * 10 + (ord(t[ti]) - ord('0'))
          inc digits
          inc ti
        if digits == 0:
          result.ok = false
        else:
          var scale = 1
          let used = min(digits, 6)
          for _ in used ..< 6: scale *= 10
          result.us = frac * scale
      elif ti + n > t.len:
        result.ok = false
      else:
        var v = 0
        for _ in 0 ..< n:
          if t[ti] notin Digits:
            result.ok = false
            break
          v = v * 10 + (ord(t[ti]) - ord('0'))
          inc ti
        if result.ok:
          case kind
          of 'y':
            if n <= 2: v = if v >= 50: 1900 + v else: 2000 + v
            result.y = v
          of 'm':
            if seenHour: result.mm = v else: result.m = v
          of 'd': result.d = v
          of 'h':
            result.hh = v
            seenHour = true
          of 's': result.ss = v
          else: discard
    elif ti < t.len and t[ti] == c:
      inc ti
      inc pi
    else:
      result.ok = false
  if result.ok and ti < t.len and t[ti] in {'Z', 'z'}: inc ti
  if result.ok and ti != t.len: result.ok = false

proc civilToUtcUs(y, m, d, hh, mm, ss, us: int; clock: TimeClock): Option[int64] =
  if not validDate(y, m, d): return none(int64)
  if hh notin 0 .. 23 or mm notin 0 .. 59 or ss notin 0 .. 60 or us notin 0 .. 999999:
    return none(int64)
  let days = daysFromCivil(y, m, d)
  if days > high(int64) div 86_400 or days < low(int64) div 86_400:
    return none(int64)
  var dayUs = int64(us)
  for part in [mulUs(days * 86_400), mulUs(int64(hh) * 3_600),
      mulUs(int64(mm) * 60), mulUs(int64(ss))]:
    if not part.ok: return none(int64)
    let summed = add64(dayUs, part.us)
    if not summed.ok: return none(int64)
    dayUs = summed.v
  if clock == tcUtc:
    return some(dayUs)
  let epochDays = daysFromCivil(1980, 1, 6)
  if epochDays > high(int64) div 86_400 or epochDays < low(int64) div 86_400:
    return none(int64)
  let epochUs = mulUs(epochDays * 86_400)
  if not epochUs.ok: return none(int64)
  let gpsUs = add64(dayUs, -epochUs.us)
  if not gpsUs.ok: return none(int64)
  some(gpsMicrosToUtcMicros(gpsUs.v))

func blankShot(): Shot =
  result.sailLine = NaN
  result.sourceLine = NaN
  result.shotPoint = NaN
  result.sourceDepth = NaN
  result.waterDepth = NaN
  result.x = NaN
  result.y = NaN
  result.z = NaN
  result.volume = NaN
  result.pressure = NaN
  result.heading = NaN
  result.speed = NaN
  result.second = NaN

func canonBits(x: float64): int64 =
  if x == 0.0: 0'i64 else: cast[int64](x)

proc keepInstant(instants: var seq[Instant]; problems: var ProblemList; row: int;
    name: string; us, named: int64; col: int) =
  if us < InstantLo or us > InstantHi:
    addProblem(problems, pkBadNumber, row, col,
      name & " " & $named & " is outside 1900..2200")
  else:
    instants.add Instant(name: name, us: us, col: col)

func fmtDiff(us: int64): string =
  let a = abs(us)
  if a mod UsPerSec == 0: $(a div UsPerSec) & " s"
  elif a mod 1000 == 0: $(a div 1000) & " ms"
  else: $a & " us"

proc shots*(log: ShotLog; map: ShotLogMap): ShotView {.raises: [].} =
  ## Typed rows. The instant is the first source that parsed, in this order:
  ## GPS microseconds, UTC microseconds, UTC seconds, the split fields, the
  ## date-time text. Split fields and text are read on `map.clock`. When a
  ## row has more than one source and two of them differ by more than a
  ## millisecond, that is a problem naming both values; a gap of 18 s is
  ## called out as GPS and UTC mixed. Times that go backwards, a repeated
  ## (source line, shot point, index) and a repeated file number are problems
  ## too. An instant outside years 1900..2200 is a bad number and is not the
  ## row's time. A microsecond column replaces a fraction in the seconds
  ## cell; a non-zero fraction that differs from it by more than one
  ## microsecond is a disagreement naming both values. A year column of
  ## two digits uses the same pivot as `yy` in a date-time pattern; a
  ## three-digit year is a bad number and is not stored. A second of 60 is
  ## kept, rolled into the next minute, and reported as `second 60`. Missing
  ## cells and sentinels are empty, not faults. A numeric cell is read from
  ## the stored text; it is not copied.
  result.problems = log.problems
  result.rows = newSeq[Shot](log.len)
  var sentText: seq[string] = @[]
  var sentVal: seq[float64] = @[]
  for s in map.sentinels:
    let u = s.strip
    if u.len == 0: continue
    sentText.add u.toLowerAscii
    var n = 0.0
    if parseutils.parseFloat(u, n) == u.len and u.len > 0:
      sentVal.add n
    elif map.decimalComma:
      let d = dotDecimal(u, true)
      if parseutils.parseFloat(d, n) == d.len and d.len > 0:
        sentVal.add n
  var sentLo = Inf
  var sentHi = NegInf
  for v in sentVal:
    if v < sentLo: sentLo = v
    if v > sentHi: sentHi = v
  const FastRoles = {crSequence, crFileNumber, crPointIndex, crGpsMicros,
    crUtcMicros, crYear, crDayOfYear, crMonth, crDayOfMonth, crHour, crMinute,
    crMicrosecond, crSailLine, crSourceLine, crShotPoint, crUtcSeconds,
    crSecond, crSourceDepth, crWaterDepth, crX, crY, crZ, crVolume,
    crPressure, crHeading, crSpeed}
  template readFast(chars: openArray[char]) =
    case role
    of crSequence, crFileNumber, crPointIndex, crGpsMicros, crUtcMicros, crYear,
        crDayOfYear, crMonth, crDayOfMonth, crHour, crMinute, crMicrosecond:
      let missing = isMissing(chars, sentText, sentVal, map.decimalComma)
      if cols[3] < 0 and role in {crYear, crDayOfYear, crMonth, crDayOfMonth,
          crHour, crMinute, crMicrosecond}:
        cols[3] = col
      if not missing:
        let whole = parseWhole(chars, map.decimalComma)
        if not whole.ok:
          addProblem(result.problems, pkBadNumber, row, col,
            "not a whole number: " & copySpan(chars, trimSpan(chars).a,
            trimSpan(chars).b))
        else:
          case role
          of crSequence: shot.sequence = some(whole.value)
          of crFileNumber: shot.fileNumber = some(whole.value)
          of crPointIndex: shot.pointIndex = some(whole.value)
          of crGpsMicros:
            if gps.isNone:
              gps = some(whole.value)
              cols[0] = col
          of crUtcMicros:
            if utcUs.isNone:
              utcUs = some(whole.value)
              cols[1] = col
          of crYear:
            if whole.value >= 0 and whole.value <= 99:
              year = some(if whole.value >= 50: 1900 + whole.value
                else: 2000 + whole.value)
            elif whole.value >= 100 and whole.value <= 999:
              addProblem(result.problems, pkBadNumber, row, col,
                "three-digit year " & $whole.value)
            else:
              year = some(whole.value)
          of crDayOfYear: doy = some(whole.value)
          of crMonth: month = some(whole.value)
          of crDayOfMonth: day = some(whole.value)
          of crHour: hour = some(whole.value)
          of crMinute: minute = some(whole.value)
          of crMicrosecond:
            let sp = trimSpan(chars)
            micros = some(whole.value)
            microsRaw = copySpan(chars, sp.a, sp.b)
            microsCol = col
          else: discard
    of crSailLine, crSourceLine, crShotPoint, crSourceDepth, crWaterDepth, crX,
        crY, crZ, crVolume, crPressure, crHeading, crSpeed:
      let num = parseNum(chars, map.decimalComma)
      var miss = false
      if num.ok:
        if num.value >= sentLo and num.value <= sentHi:
          for v in sentVal:
            if num.value == v:
              miss = true
              break
      else:
        miss = isMissing(chars, sentText, sentVal, map.decimalComma)
      if not miss and num.ok:
        case role
        of crSailLine: shot.sailLine = num.value
        of crSourceLine: shot.sourceLine = num.value
        of crShotPoint: shot.shotPoint = num.value
        of crSourceDepth: shot.sourceDepth = num.value
        of crWaterDepth: shot.waterDepth = num.value
        of crX: shot.x = num.value
        of crY: shot.y = num.value
        of crZ: shot.z = num.value
        of crVolume: shot.volume = num.value
        of crPressure: shot.pressure = num.value
        of crHeading: shot.heading = num.value
        of crSpeed: shot.speed = num.value
        else: discard
      elif not miss:
        let sp = trimSpan(chars)
        addProblem(result.problems, pkBadNumber, row, col,
          "not a number: " & copySpan(chars, sp.a, sp.b))
    of crUtcSeconds, crSecond:
      let missing = isMissing(chars, sentText, sentVal, map.decimalComma)
      if cols[3] < 0 and role == crSecond: cols[3] = col
      if not missing:
        if role == crUtcSeconds:
          let sec = parseSecondsUs(chars, map.decimalComma)
          if not sec.ok:
            let sp = trimSpan(chars)
            addProblem(result.problems, pkBadNumber, row, col,
              "not a number: " & copySpan(chars, sp.a, sp.b))
          elif utcSecUs.isNone:
            utcSecUs = some(sec.us)
            cols[2] = col
        elif role == crSecond:
          let sec = parseSecond(chars, map.decimalComma)
          if not sec.ok:
            let sp = trimSpan(chars)
            addProblem(result.problems, pkBadNumber, row, col,
              "not a number: " & copySpan(chars, sp.a, sp.b))
          else:
            let sp = trimSpan(chars)
            haveSecond = true
            secPart = sec.sec
            secUs = sec.us
            secRaw = copySpan(chars, sp.a, sp.b)
            secCol = col
            shot.second = float64(sec.sec) + float64(sec.us) / 1e6
        else:
          let num = parseNum(chars, map.decimalComma)
          if not num.ok:
            let sp = trimSpan(chars)
            addProblem(result.problems, pkBadNumber, row, col,
              "not a number: " & copySpan(chars, sp.a, sp.b))
          else:
            case role
            of crSailLine: shot.sailLine = num.value
            of crSourceLine: shot.sourceLine = num.value
            of crShotPoint: shot.shotPoint = num.value
            of crSourceDepth: shot.sourceDepth = num.value
            of crWaterDepth: shot.waterDepth = num.value
            of crX: shot.x = num.value
            of crY: shot.y = num.value
            of crZ: shot.z = num.value
            of crVolume: shot.volume = num.value
            of crPressure: shot.pressure = num.value
            of crHeading: shot.heading = num.value
            of crSpeed: shot.speed = num.value
            else: discard
    else: discard
    if role == crYear: shot.year = year
    elif role == crDayOfYear: shot.dayOfYear = doy
    elif role == crMonth: shot.month = month
    elif role == crDayOfMonth: shot.dayOfMonth = day
    elif role == crHour: shot.hour = hour
    elif role == crMinute: shot.minute = minute
    elif role == crMicrosecond: shot.microsecond = micros
    elif role == crFileNumber: fileCol = col
    elif role == crShotPoint: pointCol = col
  var seenFile = initTable[int64, int]()
  var seenShot = initTable[(int64, int64, int64), int]()
  var lastTime: Option[int64] = none(int64)
  var lastTimeRow = -1
  for row in 0 ..< log.len:
    var shot = blankShot()
    var gps: Option[int64] = none(int64)
    var utcUs: Option[int64] = none(int64)
    var utcSecUs: Option[int64] = none(int64)
    var year, doy, month, day, hour, minute, micros: Option[int64] = none(int64)
    var secPart = 0
    var secUs = 0
    var haveSecond = false
    var secRaw = ""
    var secCol = -1
    var microsRaw = ""
    var microsCol = -1
    var dateText = ""
    var haveDate = false
    var cols = [0, 0, 0, 0, 0]
    # gps, utcUs, utcSec, split, text
    for i in 0 .. 4: cols[i] = -1
    let roleCount = map.roles.len
    let fieldCount = fields(log, row)
    let colsN = max(roleCount, fieldCount)
    var fileCol = -1
    var pointCol = -1
    for col in 0 ..< colsN:
      let role = if col < roleCount: map.roles[col] else: crText
      var tookFast = false
      if role != crIgnored and log.edits.len == 0 and role in FastRoles:
        if col >= fieldCount:
          readFast("")
          tookFast = true
        else:
          let base = log.fieldOf[row].int
          let fa = log.fieldStart[base + col].int
          let fb = log.fieldStop[base + col].int
          if fb <= fa or log.text[fa] != '"':
            if fb <= fa: readFast("")
            else: readFast(log.text.toOpenArray(fa, fb - 1))
            tookFast = true
      if role == crIgnored or tookFast: discard
      else:
        let raw = cell(log, row, col)
        let missing = col >= fieldCount or isMissing(raw, sentText, sentVal,
          map.decimalComma)
        case role
        of crIgnored: discard
        of crText:
          shot.texts.add(if missing: "" else: raw.strip)
        of crStatus: shot.status = if missing: "" else: raw.strip
        of crSourceType: shot.sourceType = if missing: "" else: raw.strip
        of crSourceId: shot.sourceId = if missing: "" else: raw.strip
        of crGunArray: shot.gunArray = if missing: "" else: raw.strip
        of crDateTime:
          if not missing:
            shot.dateTime = raw.strip
            if not haveDate:
              haveDate = true
              dateText = raw.strip
              cols[4] = col
        of crSequence, crFileNumber, crPointIndex, crGpsMicros, crUtcMicros,
            crYear, crDayOfYear, crMonth, crDayOfMonth, crHour, crMinute,
            crMicrosecond:
          if cols[3] < 0 and role in {crYear, crDayOfYear, crMonth, crDayOfMonth,
              crHour, crMinute, crMicrosecond}:
            cols[3] = col
          if not missing:
            let whole = parseWhole(raw, map.decimalComma)
            if not whole.ok:
              addProblem(result.problems, pkBadNumber, row, col,
                "not a whole number: " & raw.strip)
            else:
              case role
              of crSequence: shot.sequence = some(whole.value)
              of crFileNumber: shot.fileNumber = some(whole.value)
              of crPointIndex: shot.pointIndex = some(whole.value)
              of crGpsMicros:
                if gps.isNone:
                  gps = some(whole.value)
                  cols[0] = col
              of crUtcMicros:
                if utcUs.isNone:
                  utcUs = some(whole.value)
                  cols[1] = col
              of crYear:
                if whole.value >= 0 and whole.value <= 99:
                  year = some(if whole.value >= 50: 1900 + whole.value
                    else: 2000 + whole.value)
                elif whole.value >= 100 and whole.value <= 999:
                  addProblem(result.problems, pkBadNumber, row, col,
                    "three-digit year " & $whole.value)
                else:
                  year = some(whole.value)
              of crDayOfYear: doy = some(whole.value)
              of crMonth: month = some(whole.value)
              of crDayOfMonth: day = some(whole.value)
              of crHour: hour = some(whole.value)
              of crMinute: minute = some(whole.value)
              of crMicrosecond:
                micros = some(whole.value)
                microsRaw = raw.strip
                microsCol = col
              else: discard
        of crSailLine, crSourceLine, crShotPoint, crUtcSeconds, crSecond,
            crSourceDepth, crWaterDepth, crX, crY, crZ, crVolume, crPressure,
            crHeading, crSpeed:
          if cols[3] < 0 and role == crSecond: cols[3] = col
          if not missing:
            if role == crUtcSeconds:
              let sec = parseSecondsUs(raw, map.decimalComma)
              if not sec.ok:
                addProblem(result.problems, pkBadNumber, row, col,
                  "not a number: " & raw.strip)
              elif utcSecUs.isNone:
                utcSecUs = some(sec.us)
                cols[2] = col
            elif role == crSecond:
              let sec = parseSecond(raw, map.decimalComma)
              if not sec.ok:
                addProblem(result.problems, pkBadNumber, row, col,
                  "not a number: " & raw.strip)
              else:
                haveSecond = true
                secPart = sec.sec
                secUs = sec.us
                secRaw = raw.strip
                secCol = col
                shot.second = float64(sec.sec) + float64(sec.us) / 1e6
            else:
              let num = parseNum(raw, map.decimalComma)
              if not num.ok:
                addProblem(result.problems, pkBadNumber, row, col,
                  "not a number: " & raw.strip)
              else:
                case role
                of crSailLine: shot.sailLine = num.value
                of crSourceLine: shot.sourceLine = num.value
                of crShotPoint: shot.shotPoint = num.value
                of crSourceDepth: shot.sourceDepth = num.value
                of crWaterDepth: shot.waterDepth = num.value
                of crX: shot.x = num.value
                of crY: shot.y = num.value
                of crZ: shot.z = num.value
                of crVolume: shot.volume = num.value
                of crPressure: shot.pressure = num.value
                of crHeading: shot.heading = num.value
                of crSpeed: shot.speed = num.value
                else: discard
        if role == crYear: shot.year = year
        elif role == crDayOfYear: shot.dayOfYear = doy
        elif role == crMonth: shot.month = month
        elif role == crDayOfMonth: shot.dayOfMonth = day
        elif role == crHour: shot.hour = hour
        elif role == crMinute: shot.minute = minute
        elif role == crMicrosecond: shot.microsecond = micros
        elif role == crFileNumber: fileCol = col
        elif role == crShotPoint: pointCol = col
    var instants: seq[Instant] = @[]
    if gps.isSome:
      let utc = gpsMicrosToUtcMicros(gps.get)
      keepInstant(instants, result.problems, row, "GPS microseconds", utc, gps.get,
        cols[0])
    if utcUs.isSome:
      keepInstant(instants, result.problems, row, "UTC microseconds", utcUs.get,
        utcUs.get, cols[1])
    if utcSecUs.isSome:
      keepInstant(instants, result.problems, row, "UTC seconds", utcSecUs.get,
        utcSecUs.get, cols[2])
    if haveSecond and secPart == 60:
      addProblem(result.problems, pkBadNumber, row, secCol, "second 60")
    var splitUs: Option[int64] = none(int64)
    if year.isSome and (doy.isSome or (month.isSome and day.isSome)) and
        hour.isSome and minute.isSome and haveSecond:
      var us = secUs
      var ss = secPart
      if micros.isSome:
        if secUs != 0 and abs(int64(secUs) - micros.get) > 1:
          addProblem(result.problems, pkTimeDisagree, row, microsCol,
            "second " & secRaw & " and microsecond " & microsRaw)
        us = int(micros.get)
      var y = int(year.get)
      var m = 0
      var d = 0
      var splitOk = false
      if doy.isSome:
        let md = doyToMonthDay(y, int(doy.get))
        if md.ok:
          m = md.month
          d = md.day
          splitOk = true
        else:
          addProblem(result.problems, pkBadNumber, row, -1,
            "day of year " & $doy.get & " is not a day of " & $y)
      elif month.isSome and day.isSome:
        m = int(month.get)
        d = int(day.get)
        splitOk = true
      if splitOk and month.isSome and day.isSome and doy.isSome:
        let other = civilToUtcUs(y, int(month.get), int(day.get), int(hour.get),
          int(minute.get), ss, us, map.clock)
        let fromDoy = civilToUtcUs(y, m, d, int(hour.get), int(minute.get), ss, us,
          map.clock)
        if other.isSome and fromDoy.isSome and abs(other.get - fromDoy.get) > DisagreeUs:
          addProblem(result.problems, pkTimeDisagree, row, -1,
            "day of year " & $fromDoy.get & " and month and day " & $other.get &
            " differ by " & fmtDiff(other.get - fromDoy.get))
      if splitOk:
        splitUs = civilToUtcUs(y, m, d, int(hour.get), int(minute.get), ss, us,
          map.clock)
        if splitUs.isNone:
          addProblem(result.problems, pkBadNumber, row, -1,
            "split fields are not a time")
    if splitUs.isSome:
      keepInstant(instants, result.problems, row, "split fields", splitUs.get,
        splitUs.get, cols[3])
    if haveDate:
      var pattern = map.dateTimePattern
      if pattern.len == 0: pattern = detectPattern(dateText)
      let parsed = matchPattern(dateText, pattern)
      if not parsed.ok:
        addProblem(result.problems, pkBadNumber, row, cols[4],
          "date-time text does not match " &
          (if map.dateTimePattern.len > 0: map.dateTimePattern else: "a known form"))
      else:
        if parsed.ss == 60:
          addProblem(result.problems, pkBadNumber, row, cols[4], "second 60")
        let textUs = civilToUtcUs(parsed.y, parsed.m, parsed.d, parsed.hh, parsed.mm,
          parsed.ss, parsed.us, map.clock)
        if textUs.isSome:
          keepInstant(instants, result.problems, row, "date-time text", textUs.get,
            textUs.get, cols[4])
        else:
          addProblem(result.problems, pkBadNumber, row, cols[4],
            "date-time text is not a time")
    if instants.len > 0:
      shot.timeUtcUs = some(instants[0].us)
      for k in 1 ..< instants.len:
        let diff = instants[k].us - instants[0].us
        if abs(diff) > DisagreeUs:
          var msg = instants[0].name & " " & $instants[0].us & " and " &
            instants[k].name & " " & $instants[k].us & " differ by " & fmtDiff(diff)
          if abs(abs(diff) - MixedClockUs) <= DisagreeUs:
            msg.add "; GPS and UTC mixed"
          addProblem(result.problems, pkTimeDisagree, row, instants[k].col, msg)
      if lastTime.isSome and shot.timeUtcUs.get < lastTime.get:
        addProblem(result.problems, pkTimeBackward, row, instants[0].col,
          $shot.timeUtcUs.get & " us is before row " & $lastTimeRow & " at " &
          $lastTime.get & " us")
      lastTime = shot.timeUtcUs
      lastTimeRow = row
    if shot.fileNumber.isSome:
      let fn = shot.fileNumber.get
      if seenFile.hasKey(fn):
        addProblem(result.problems, pkDuplicateFile, row, fileCol,
          "file number " & $fn & " also on row " & $seenFile.getOrDefault(fn))
      else:
        seenFile[fn] = row
    if not shot.sourceLine.isNaN and not shot.shotPoint.isNaN:
      let idx = if shot.pointIndex.isSome: shot.pointIndex.get else: low(int64)
      let key = (canonBits(shot.sourceLine), canonBits(shot.shotPoint), idx)
      if seenShot.hasKey(key):
        addProblem(result.problems, pkDuplicateShot, row, pointCol,
          "source line " & $shot.sourceLine & " shot point " & $shot.shotPoint &
          " index " & (if shot.pointIndex.isSome: $shot.pointIndex.get else: "none") &
          " also on row " & $seenShot.getOrDefault(key))
      else:
        seenShot[key] = row
    result.rows[row] = shot
