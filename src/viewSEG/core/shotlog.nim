## A shot log: delimited text from a navigation or source-controller system,
## one row per shot. The file's text is kept once and cells are slices of it
## (`cell`), so a log of 100 000 rows is an index, not a copy of every cell.
## The caller reads the file; nothing here touches the file system.
##
## A `ShotLogMap` says which column is which (`ColumnRole`: Ignore, a system
## column the code refers to by role, or a user defined column with a name of
## its own), which clock the time is on, and which sentinels mean missing. The
## cells of the Time (UTC) columns are read together as one time. `guessMap`
## is a starting point from the header names and the first rows; the roles can
## be set without it. `shots` turns the rows into
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
    ## What a column of a shot log means. `$` and `label` are the words the
    ## Columns dialog shows. Every role from `crTime` to `crUphole` is a
    ## system column that code refers to by role (one column each, except
    ## `crTime`, which several columns can share); `crText` is a user defined
    ## column, which has a name of its own (`ShotLogMap.names`).
    crIgnored = "Ignore"
    crTime = "Time (UTC)"
    crGpsMicros = "GPSTB"
    crSequence = "SEQ"
    crFileNumber = "FFID"
    crStatus = "Status"
    crSailLine = "SailLine"
    crSourceLine = "SourceLine"
    crShotPoint = "SourcePoint"
    crPointIndex = "Index"
    crSourceDepth = "Depth"
    crWaterDepth = "Water Depth"
    crX = "X"
    crY = "Y"
    crZ = "Z"
    crSourceType = "SourceType"
    crSourceId = "SourceID"
    crUphole = "Uphole"
    crText = "User defined"

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
    names*: seq[string]
      ## one per column, read only where the role is `crText` (user defined):
      ## its name. Empty: the header's name, or "Column N".
    clock*: TimeClock ## a time written as a calendar date; the epoch forms are UTC
    dateTimePattern*: string
      ## How the cells of the `crTime` columns, joined in column order with
      ## one space, read as one time: `yyyy`, `yy`, `ddd` (day of year), `mm`
      ## (month before an hour, else minute), `mi`, `dd`, `hh`, `ss`, `f`
      ## (fraction of a second), `u` (whole microseconds) and literals, as in
      ## `yyyy ddd hh mi ss.ffffff`; or `epoch seconds` or `epoch
      ## microseconds`. Empty: the form is detected from the first rows.
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
    ## A column mapped to Ignore is not here at all.
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
    uphole*: float64 ## the uphole time in ms; NaN when absent
    texts*: seq[string] ## user defined columns, in column order

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
  ## data row, when there is no header, or when the rows are cut at spaces,
  ## where a header's names may hold spaces) is kept and listed. Line endings
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
  if hasHeader and delimiter == dlSpaces:
    # a header's names may hold spaces: its fields are not the rows' columns
    for lineIdx in first ..< result.lineStart.len:
      let a = result.lineStart[lineIdx].int
      let b = result.lineStop[lineIdx].int
      if a != b:
        var starts: seq[int32] = @[]
        var stops: seq[int32] = @[]
        scanFields(result.text, a, b, delimiter, starts, stops)
        if starts.len > 0: result.width = starts.len
        break
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
  ("tb", crGpsMicros), ("gpstb", crGpsMicros),
  ("utcmicroseconds", crTime), ("utcus", crTime), ("unixtimeus", crTime),
  ("utcseconds", crTime), ("epochseconds", crTime), ("unixtime", crTime),
  ("utcs", crTime), ("posix", crTime),
  ("year", crTime), ("yr", crTime),
  ("dayofyear", crTime), ("julianday", crTime), ("julian", crTime),
  ("jday", crTime), ("doy", crTime),
  ("month", crTime), ("mon", crTime),
  ("dayofmonth", crTime), ("dom", crTime), ("day", crTime),
  ("hour", crTime), ("hr", crTime), ("hh", crTime),
  ("minute", crTime), ("min", crTime),
  ("microsecond", crTime), ("microseconds", crTime), ("usec", crTime),
  ("second", crTime), ("sec", crTime), ("ss", crTime),
  ("datetimeutc", crTime), ("datetimetext", crTime),
  ("datetime", crTime), ("timestamp", crTime), ("shottime", crTime),
  ("date", crTime), ("time", crTime), ("timeutc", crTime),
  ("sourcedepth", crSourceDepth), ("gundepth", crSourceDepth),
  ("srcdepth", crSourceDepth), ("depth", crSourceDepth),
  ("waterdepth", crWaterDepth), ("seafloor", crWaterDepth), ("wd", crWaterDepth),
  ("easting", crX), ("longitude", crX), ("lon", crX), ("east", crX), ("x", crX),
  ("northing", crY), ("latitude", crY), ("lat", crY), ("north", crY), ("y", crY),
  ("elevation", crZ), ("elev", crZ), ("height", crZ), ("z", crZ),
  ("sourcetype", crSourceType), ("srctype", crSourceType), ("type", crSourceType),
  ("sourceids", crSourceId), ("sourceid", crSourceId), ("srcid", crSourceId),
  ("gunid", crSourceId), ("id", crSourceId),
  ("uphole", crUphole), ("upholetime", crUphole), ("tuh", crUphole)]

func nameKey*(s: string): string =
  ## `s` compared as a name: lower case letters and digits only, so
  ## "Source Line", "source_line" and "SourceLine" are one name.
  for c in s:
    if c in Letters + Digits: result.add c.toLowerAscii

func isSystemName*(name: string): bool =
  ## Whether `name` is one of the choices of the Columns dialog (Ignore, a
  ## system column, or User defined), compared by `nameKey`.
  let k = nameKey(name)
  for r in ColumnRole:
    if nameKey($r) == k: return true

func nameFault*(name: string): string =
  ## Why `name` cannot be a user defined column's name; "" when it can.
  ## A system name is refused whatever its spaces, case and punctuation.
  if name.strip.len == 0:
    "A user defined column needs a name."
  elif isSystemName(name):
    "\"" & name.strip & "\" is one of the system's column names. Give this column " &
      "another name."
  else: ""

func isSystemRole*(role: ColumnRole): bool {.inline.} =
  ## A column the system refers to by role.
  role in {crTime .. crUphole}

func roleUnique*(role: ColumnRole): bool {.inline.} =
  ## A meaning that belongs to one column only. `crTime` may be on several
  ## columns, which are read together as one time.
  role in {crGpsMicros .. crUphole}

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

func knownHeader(raw: string): bool =
  roleOfName(raw) != crText

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

const
  EpochSeconds* = "epoch seconds"
    ## a `dateTimePattern` for one column of seconds since 1970, fraction allowed
  EpochMicros* = "epoch microseconds"
    ## a `dateTimePattern` for one column of whole microseconds since 1970

type
  TimeParts = object
    ok: bool
    y, m, d, doy, hh, mi, ss: int
    fracUs: int ## the fraction of the second, in microseconds
    micros: int ## the `u` field; -1 when the pattern has none

func isToken(c: char): bool {.inline.} =
  c.toLowerAscii in {'y', 'm', 'd', 'h', 's', 'f', 'u'}

proc matchPattern(text, pattern: string): TimeParts =
  ## Reads `text` as `pattern` says. A field with a literal or the end after
  ## it takes one up to its width in digits, so `5` is an hour for `hh`; a
  ## field followed by another field takes exactly its width. A `.` before
  ## `f` is optional. A two-digit year uses the pivot 50: 50..99 is 19xx.
  let t = text.strip
  var ti = 0
  var pi = 0
  var seenHour = false
  result.micros = -1
  result.ok = pattern.len > 0
  while result.ok and pi < pattern.len:
    let c = pattern[pi]
    var kind = c.toLowerAscii
    var n = 0
    if kind == 'm' and pi + 1 < pattern.len and pattern[pi + 1].toLowerAscii == 'i':
      kind = 'i'
      n = 2
      pi += 2
    elif isToken(c):
      while pi < pattern.len and pattern[pi].toLowerAscii == kind:
        inc n
        inc pi
    if n == 0:
      if c == '.' and pi + 1 < pattern.len and pattern[pi + 1].toLowerAscii == 'f':
        if ti < t.len and t[ti] == '.':
          inc ti
          inc pi
        else:
          inc pi
          while pi < pattern.len and pattern[pi].toLowerAscii == 'f': inc pi
      elif ti < t.len and t[ti] == c:
        inc ti
        inc pi
      else:
        result.ok = false
    elif kind == 'f':
      var seen, used, frac = 0
      while ti < t.len and t[ti] in Digits:
        if used < 6:
          frac = frac * 10 + (ord(t[ti]) - ord('0'))
          inc used
        inc seen
        inc ti
      if seen == 0:
        result.ok = false
      else:
        var scale = 1
        for _ in used ..< 6: scale *= 10
        result.fracUs = frac * scale
    else:
      let exact = pi < pattern.len and isToken(pattern[pi])
      var v, got = 0
      while ti < t.len and t[ti] in Digits and got < n:
        v = v * 10 + (ord(t[ti]) - ord('0'))
        inc got
        inc ti
      if got == 0 or (exact and got != n):
        result.ok = false
      else:
        case kind
        of 'y':
          if got <= 2: v = if v >= 50: 1900 + v else: 2000 + v
          result.y = v
        of 'm':
          if seenHour: result.mi = v else: result.m = v
        of 'i': result.mi = v
        of 'd':
          if n >= 3: result.doy = v else: result.d = v
        of 'h':
          result.hh = v
          seenHour = true
        of 's': result.ss = v
        else: result.micros = v
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

type TimeRead = object
  ok: bool
  us: int64
  leap: bool    ## the second was 60
  clash: string ## the seconds' fraction and the microseconds differ: both, in words
  why: string   ## when not `ok`, how the text fails

proc readTime(text, pattern: string; clock: TimeClock): TimeRead =
  ## One instant from `text` as `pattern` says. The epoch forms are UTC; the
  ## others are on `clock`.
  let key = pattern.strip.toLowerAscii
  if key == EpochSeconds:
    let sec = parseSecondsUs(text)
    if sec.ok: result = TimeRead(ok: true, us: sec.us)
    else: result.why = "does not match " & pattern
  elif key == EpochMicros:
    let whole = parseWhole(text)
    if whole.ok: result = TimeRead(ok: true, us: whole.value)
    else: result.why = "does not match " & pattern
  else:
    let p = matchPattern(text, pattern)
    if not p.ok:
      result.why = "does not match " & pattern
    else:
      var m = p.m
      var d = p.d
      var dateOk = true
      if p.doy > 0:
        let md = doyToMonthDay(p.y, p.doy)
        if md.ok:
          m = md.month
          d = md.day
        else:
          dateOk = false
          result.why = "has day of year " & $p.doy & ", not a day of " & $p.y
      var us = p.fracUs
      if p.micros >= 0:
        if p.fracUs != 0 and abs(p.fracUs - p.micros) > 1:
          result.clash = "second fraction " & $p.fracUs & " us and microsecond " &
            $p.micros & " us differ"
        us = p.micros
      if dateOk:
        let at = civilToUtcUs(p.y, m, d, p.hh, p.mi, p.ss, us, clock)
        if at.isSome:
          result.ok = true
          result.us = at.get
          result.leap = p.ss == 60
        else:
          result.why = "is not a valid date and time"

proc detectTimePattern*(text: string): string =
  ## The pattern of one joined time text, or "" when it has no form this
  ## knows: seconds or microseconds since 1970 (`epoch seconds`, `epoch
  ## microseconds`), or a date (year, then day of year or month and day), an
  ## hour, a minute, a second, then an optional fraction (`.` and digits) or
  ## whole microseconds, with the separators it holds and an optional `Z`.
  let t = text.strip
  if t.len == 0: return ""
  var j = 0
  while j < t.len and t[j] in Digits: inc j
  let whole = j
  var k = j
  if k < t.len and t[k] == '.':
    inc k
    let at = k
    while k < t.len and t[k] in Digits: inc k
    if k == at: k = -1
  if whole > 0 and k == t.len:
    if k == whole and whole in 15 .. 17: return EpochMicros
    if whole in 9 .. 11: return EpochSeconds
    return ""
  var runs: seq[tuple[a, b: int]] = @[]
  var i = 0
  while i < t.len:
    if t[i] in Digits:
      let a = i
      while i < t.len and t[i] in Digits: inc i
      runs.add (a, i)
    else:
      inc i
  if runs.len < 5 or runs[0].a != 0: return ""
  func runLen(r: tuple[a, b: int]): int = r.b - r.a
  var pat = ""
  var at = 0
  proc put(token: string): bool =
    ## The separator before run `at`, then `token`.
    if at > 0:
      let sep = t.substr(runs[at - 1].b, runs[at].a - 1)
      if sep.len > 2: return false
      for c in sep:
        if c in Digits or (c in Letters and c notin {'T', 't'}): return false
      pat.add sep
    pat.add token
    inc at
    true
  var date = false
  if runLen(runs[0]) in [2, 4]:
    let fraction = if runs.len > 5 and
        t.substr(runs[^2].b, runs[^1].a - 1) == ".": 1 else: 0
    let core = runs.len - fraction
    var dayOfYear = false
    if core == 5:
      dayOfYear = true
    elif core == 6:
      let second = t.substr(runs[1].a, runs[1].b - 1)
      dayOfYear = second.len == 3 or (second.len == 2 and second > "12")
    if core in 5 .. 7:
      date = put(if runLen(runs[0]) == 4: "yyyy" else: "yy")
      if date and dayOfYear: date = put("ddd")
      elif date: date = put("mm") and put("dd")
  if not date or runs.len < at + 3: return ""
  for token in ["hh", "mi", "ss"]:
    if runLen(runs[at]) notin 1 .. 2 or not put(token): return ""
  var fractionDone = false
  while at < runs.len:
    let sep = t.substr(runs[at - 1].b, runs[at].a - 1)
    if sep == "." and not fractionDone:
      fractionDone = true
      if not put(repeat('f', runLen(runs[at]))): return ""
    elif runLen(runs[at]) <= 6:
      if not put("uuuuuu"): return ""
    else:
      return ""
  if at != runs.len: return ""
  let rest = t.substr(runs[^1].b)
  if rest.len > 0:
    if rest in ["Z", "z"]: pat.add rest else: return ""
  pat


func uniqueName(base: string; used: var seq[string]; col: int): string =
  ## `base` as a user defined column's name: "Column N" when empty, " (file)"
  ## added to a system name, and a number added to a name another column has.
  ## The name's key is then added to `used`.
  var stem = base.strip
  if stem.len == 0: stem = "Column " & $(col + 1)
  if isSystemName(stem): stem.add " (file)"
  result = stem
  var k = 1
  while nameKey(result) in used:
    inc k
    result = stem & " " & $k
  used.add nameKey(result)

proc columnNames*(log: ShotLog; map: ShotLogMap; count: int): seq[string] =
  ## The name of each of `count` columns as a grid shows it: the system name
  ## of a system column, and for a user defined column its own name, else
  ## the header's, else "Column N", made legal (`uniqueName`). An ignored
  ## column has the header's name or "Column N".
  result = newSeq[string](count)
  var used: seq[string] = @[]
  for c in 0 ..< count:
    let role = if c < map.roles.len: map.roles[c] else: crText
    case role
    of crText:
      var base = if c < map.names.len: map.names[c].strip else: ""
      if base.len == 0 and log != nil: base = log.columnName(c)
      result[c] = uniqueName(base, used, c)
    of crIgnored:
      let h = if log == nil: "" else: log.columnName(c)
      result[c] = if h.len > 0: h else: "Column " & $(c + 1)
    else:
      result[c] = $role

proc nameProblems*(map: ShotLogMap): seq[tuple[col: int; why: string]] =
  ## The user defined columns whose given name cannot be used: a system name,
  ## or a name an earlier column has already. An empty name is not a problem:
  ## the column takes the header's name.
  var named: seq[string] = @[]
  for c, role in map.roles:
    if role == crText and c < map.names.len and map.names[c].strip.len > 0:
      let fault = nameFault(map.names[c])
      if fault.len > 0:
        result.add (c, fault)
      else:
        let key = nameKey(map.names[c])
        if key in named:
          result.add (c, "Another column is named \"" & map.names[c].strip &
            "\". Give each its own name.")
        else:
          named.add key

proc mapFault*(map: ShotLogMap): string =
  ## Why `map` cannot be applied, in words; "" when it can: a system column
  ## chosen for two columns (`crTime` may be on several), or a user defined
  ## name that is a system name or that two columns share.
  var seen: set[ColumnRole] = {}
  for role in map.roles:
    if roleUnique(role):
      if role in seen:
        return $role & " is chosen for more than one column. Choose it for one."
      seen.incl role
  let bad = nameProblems(map)
  if bad.len > 0: "Column " & $(bad[0].col + 1) & ": " & bad[0].why else: ""

type
  LegacyPart = enum
    lpNone, lpUtcUs, lpUtcSec, lpYear, lpDoy, lpMonth, lpDom, lpHour, lpMinute,
    lpSecond, lpMicro, lpText

const LegacyRoles = [
  ("ignored", crIgnored, lpNone), ("sequence", crSequence, lpNone),
  ("file number", crFileNumber, lpNone), ("status", crStatus, lpNone),
  ("sail line", crSailLine, lpNone), ("source line", crSourceLine, lpNone),
  ("shot point", crShotPoint, lpNone), ("point index", crPointIndex, lpNone),
  ("GPS microseconds", crGpsMicros, lpNone), ("UTC microseconds", crTime, lpUtcUs),
  ("UTC seconds", crTime, lpUtcSec), ("year", crTime, lpYear),
  ("day of year", crTime, lpDoy), ("month", crTime, lpMonth),
  ("day of month", crTime, lpDom), ("hour", crTime, lpHour),
  ("minute", crTime, lpMinute), ("second", crTime, lpSecond),
  ("microsecond", crTime, lpMicro), ("date-time text", crTime, lpText),
  ("source depth", crSourceDepth, lpNone), ("water depth", crWaterDepth, lpNone),
  ("X", crX, lpNone), ("Y", crY, lpNone), ("Z", crZ, lpNone),
  ("source type", crSourceType, lpNone), ("source id", crSourceId, lpNone),
  ("gun array", crText, lpNone), ("volume", crText, lpNone),
  ("pressure", crText, lpNone), ("heading", crText, lpNone),
  ("speed", crText, lpNone), ("text", crText, lpNone)]
  ## the words a project saved before the system columns were named used

func legacyToken(part: LegacyPart): string =
  case part
  of lpYear: "yyyy"
  of lpDoy: "ddd"
  of lpMonth: "mm"
  of lpDom: "dd"
  of lpHour: "hh"
  of lpMinute: "mi"
  of lpSecond: "ss.ffffff"
  of lpMicro: "uuuuuu"
  else: ""

proc applyRoleNames*(map: var ShotLogMap; roleNames, columnNames: openArray[string]):
    string =
  ## Sets `map.roles` and `map.names` from the role words a project stored:
  ## the words of `ColumnRole`, and the older words, which are migrated. The
  ## older time roles become `crTime` on those columns, with `dateTimePattern`
  ## set to what reads them the same way (one source, in the order UTC
  ## microseconds, UTC seconds, split fields, date-time text; the columns of
  ## another source become user defined). Gun array, volume, pressure, heading,
  ## speed and text become user defined, named by their old word (text: by the
  ## header). `columnNames` are the stored user defined names, if any. The
  ## result is "" or the first word that is neither.
  map.roles.setLen 0
  map.names.setLen 0
  var parts: seq[LegacyPart] = @[]
  for i, word in roleNames:
    var role = crText
    var part = lpNone
    var name = if i < columnNames.len: columnNames[i] else: ""
    var found = false
    for r in ColumnRole:
      if $r == word:
        role = r
        found = true
        break
    if not found:
      for e in LegacyRoles:
        if e[0] == word:
          role = e[1]
          part = e[2]
          found = true
          if role == crText and word != "text": name = word
          break
    if not found: return word
    map.roles.add role
    map.names.add name
    parts.add part
  var group = lpNone
  var cols: seq[int] = @[]
  for want in [lpUtcUs, lpUtcSec]:
    if group == lpNone:
      for c, p in parts:
        if p == want:
          group = want
          cols = @[c]
          break
  if group == lpNone:
    var have: set[LegacyPart] = {}
    var seenPart: set[LegacyPart] = {}
    var pick: seq[int] = @[]
    for c, p in parts:
      if p in {lpYear .. lpMicro} and p notin seenPart:
        seenPart.incl p
        pick.add c
        have.incl p
    if lpYear in have and (lpDoy in have or (lpMonth in have and lpDom in have)) and
        lpHour in have and lpMinute in have and lpSecond in have:
      group = lpYear
      cols = pick
  if group == lpNone:
    for c, p in parts:
      if p == lpText:
        group = lpText
        cols = @[c]
        break
  var pattern = map.dateTimePattern
  case group
  of lpUtcUs: pattern = EpochMicros
  of lpUtcSec: pattern = EpochSeconds
  of lpYear:
    pattern = ""
    for c in cols:
      if pattern.len > 0: pattern.add ' '
      pattern.add legacyToken(parts[c])
  else: discard
  for c, p in parts:
    if p != lpNone:
      if c in cols:
        map.roles[c] = crTime
        map.names[c] = ""
      else:
        map.roles[c] = crText
        for e in LegacyRoles:
          if e[2] == p: map.names[c] = e[0]
  if group != lpNone: map.dateTimePattern = pattern
  var named = false
  for name in map.names:
    if name.len > 0: named = true
  if not named: map.names.setLen 0

proc guessFromCells(cells: openArray[string]): ColumnRole =
  ## GPSTB or a date-time text, when every non-empty cell agrees. Otherwise
  ## `crText`.
  result = crText
  var n, gps, time = 0
  for c in cells:
    let t = c.strip
    if t.len > 0:
      inc n
      if isGpsMicrosText(t): inc gps
      if detectPattern(t).len > 0: inc time
  if n > 0:
    if time == n: result = crTime
    elif gps == n: result = crGpsMicros

proc cellsFit(role: ColumnRole; cells: openArray[string]): bool =
  ## Whether most non-empty cells read as `role`: whole numbers for SEQ, FFID,
  ## Index and GPSTB, numbers for the number columns. Text columns fit.
  var n, bad = 0
  for c in cells:
    if c.strip.len > 0:
      inc n
      case role
      of crSequence, crFileNumber, crPointIndex, crGpsMicros:
        if not parseWhole(c, true).ok: inc bad
      of crSailLine, crSourceLine, crShotPoint, crSourceDepth, crWaterDepth, crX, crY,
          crZ, crUphole:
        if numShape(c) == nsOther and not parseNum(c).ok: inc bad
      else: discard
  bad * 2 <= n

proc alignHeader(fields: seq[string]; width: int): tuple[ok: bool; names: seq[string]] =
  ## `fields` cut into `width` consecutive groups, each joined by a space,
  ## that are as many known names as possible; a group of several fields must
  ## be a known name. For a header whose names hold spaces in a file cut at
  ## spaces: "Sail line" is one name, not two.
  const MaxGroup = 4
  let n = fields.len
  if width <= 0 or n < width or n > MaxGroup * width: return
  var best = newSeq[seq[int]](n + 1)
  var pick = newSeq[seq[int]](n + 1)
  for i in 0 .. n:
    best[i] = newSeq[int](width + 1)
    pick[i] = newSeq[int](width + 1)
    for j in 0 .. width: best[i][j] = -1
  best[0][0] = 0
  for i in 1 .. n:
    for j in 1 .. min(i, width):
      for k in 1 .. min(MaxGroup, i):
        if best[i - k][j - 1] >= 0:
          let group = fields[i - k ..< i].join(" ")
          let known = knownHeader(group)
          if k == 1 or known:
            let score = best[i - k][j - 1] + (if known: 1 else: 0)
            if score > best[i][j]:
              best[i][j] = score
              pick[i][j] = k
  if best[n][width] < 0: return
  var i = n
  var j = width
  var rev: seq[string] = @[]
  while j > 0:
    let k = pick[i][j]
    rev.add fields[i - k ..< i].join(" ")
    i -= k
    dec j
  result.ok = true
  for g in countdown(rev.high, 0): result.names.add rev[g]

proc guessMap*(text: string): ShotLogMap {.raises: [].} =
  ## A starting map: delimiter, lines to skip, whether a header is there,
  ## and a role per column. The delimiter is the one most of the data rows
  ## use, not the header line's. Header names are matched ignoring case,
  ## spaces, underscores and a leading number prefix such as `07_`. When the
  ## header has more names than the rows have columns (names with spaces, in
  ## a file cut at spaces), the names are grouped to fit, and a header that
  ## cannot be fitted names nothing. A name that is not known, and every
  ## column when there is no header, is judged from the first data rows: a
  ## 16-digit integer near 1.4e15 is GPSTB, and an ISO date-time is Time
  ## (UTC). A role whose cells do not read as that role is not assigned, a
  ## system column found twice is kept once, and the other columns are user
  ## defined, named by their header. The time columns are read as one time,
  ## and the pattern that reads the first rows is `dateTimePattern`; when they
  ## do not read together, the first that reads alone is the time; the others
  ## are user defined. The clock stays UTC and the
  ## length unit stays metres unless a header says feet.
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
  var headerDelim = dlSpaces
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
      headerDelim = d
      break
  let dataFrom = if headerAt >= 0: headerAt + 1 else: 0
  var judged: seq[int] = @[]
  if headerAt >= 0: judged.add headerAt
  for k in dataFrom ..< min(keptStart.len, dataFrom + 12): judged.add k
  result.delimiter = if headerAt >= 0: headerDelim else: dlSpaces
  var bestScore = 0
  for d in [dlTab, dlSemicolon, dlComma, dlSpaces]:
    var perLine: seq[int] = @[]
    for k in judged:
      var starts: seq[int32] = @[]
      var stops: seq[int32] = @[]
      scanFields(text, keptStart[k], keptStop[k], d, starts, stops)
      perLine.add starts.len
    var score = 0
    for c in perLine:
      if c >= 2:
        var same = 0
        for e in perLine:
          if e == c: inc same
        score = max(score, same)
    if score > bestScore:
      bestScore = score
      result.delimiter = d
  var samples: seq[seq[string]] = @[]
  var counts: seq[int] = @[]
  var taken = 0
  for k in dataFrom ..< keptStart.len:
    if taken < 12:
      var starts: seq[int32] = @[]
      var stops: seq[int32] = @[]
      scanFields(text, keptStart[k], keptStop[k], result.delimiter, starts, stops)
      if starts.len > samples.len: samples.setLen starts.len
      for c in 0 ..< starts.len:
        samples[c].add fieldText(text, starts[c].int, stops[c].int)
      counts.add starts.len
      inc taken
  var width = 0
  var mostSeen = 0
  for c in counts:
    var same = 0
    for d in counts:
      if d == c: inc same
    if same > mostSeen:
      mostSeen = same
      width = c
  var headerNames: seq[string] = @[]
  if headerAt >= 0:
    result.hasHeader = true
    result.skipLines = keptPhys[headerAt]
    var hStart: seq[int32] = @[]
    var hStop: seq[int32] = @[]
    scanFields(text, keptStart[headerAt], keptStop[headerAt], result.delimiter,
      hStart, hStop)
    var fieldsOf: seq[string] = @[]
    for c in 0 ..< hStart.len:
      fieldsOf.add fieldText(text, hStart[c].int, hStop[c].int).strip
    if width == 0 or width == fieldsOf.len:
      headerNames = fieldsOf
      width = fieldsOf.len
    else:
      let fit = alignHeader(fieldsOf, width)
      if fit.ok: headerNames = fit.names
  else:
    result.hasHeader = false
    result.skipLines = if keptPhys.len > 0: keptPhys[0] else: 0
  if samples.len < width: samples.setLen width
  result.roles = newSeq[ColumnRole](width)
  result.names = newSeq[string](width)
  var seenRoles: set[ColumnRole] = {}
  for c in 0 ..< width:
    var role = crText
    if c < headerNames.len:
      role = roleOfName(headerNames[c])
      if mentionsFeet(headerNames[c]): result.lengthUnit = luFeet
    if role == crText: role = guessFromCells(samples[c])
    if role != crText and not cellsFit(role, samples[c]): role = crText
    if roleUnique(role) and role in seenRoles: role = crText
    if roleUnique(role): seenRoles.incl role
    result.roles[c] = role
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
  var timeCols: seq[int] = @[]
  for c in 0 ..< width:
    if result.roles[c] == crTime: timeCols.add c
  let decimalComma = result.decimalComma
  proc patternOf(cols: seq[int]): string =
    ## The pattern that reads the joined cells of `cols` in every sample row.
    var joined: seq[string] = @[]
    for r in 0 ..< counts.len:
      var line = ""
      for c in cols:
        if r < samples[c].len and samples[c][r].strip.len > 0:
          if line.len > 0: line.add ' '
          line.add samples[c][r].strip
      if line.len > 0: joined.add dotDecimal(line, decimalComma)
    if joined.len > 0:
      result = detectTimePattern(joined[0])
      for line in joined:
        if result.len > 0 and not readTime(line, result, tcUtc).ok: result = ""
  if timeCols.len > 0:
    var chosen = timeCols
    var pattern = patternOf(timeCols)
    if pattern.len == 0 and timeCols.len > 1:
      for c in timeCols:
        pattern = patternOf(@[c])
        if pattern.len > 0:
          chosen = @[c]
          break
    for c in timeCols:
      if c notin chosen or pattern.len == 0: result.roles[c] = crText
    result.dateTimePattern = pattern
  var used: seq[string] = @[]
  for c in 0 ..< width:
    if result.roles[c] == crText:
      if c < headerNames.len and headerNames[c].len > 0:
        result.names[c] = uniqueName(headerNames[c], used, c)

func blankShot(): Shot =
  result.sailLine = NaN
  result.sourceLine = NaN
  result.shotPoint = NaN
  result.sourceDepth = NaN
  result.waterDepth = NaN
  result.x = NaN
  result.y = NaN
  result.z = NaN
  result.uphole = NaN

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

proc timeText(log: ShotLog; row: int; cols: openArray[int]; sentText: openArray[string];
    sentVal: openArray[float64]; decimalComma: bool): string =
  ## The cells of the time columns of `row`, in column order, one space
  ## between; a missing cell is left out.
  let count = fields(log, row)
  for col in cols:
    if col < count:
      let raw = cell(log, row, col)
      if not isMissing(raw, sentText, sentVal, decimalComma):
        if result.len > 0: result.add ' '
        result.add raw.strip
  if decimalComma: result = dotDecimal(result, true)

proc shotted(chars: openArray[char]): string =
  let sp = trimSpan(chars)
  copySpan(chars, sp.a, sp.b)

proc sentinelLists(map: ShotLogMap): tuple[text: seq[string]; val: seq[float64]] =
  ## The missing-value words in lower case, and those that are numbers.
  for s in map.sentinels:
    let u = s.strip
    if u.len > 0:
      result.text.add u.toLowerAscii
      var n = 0.0
      if parseutils.parseFloat(u, n) == u.len:
        result.val.add n
      elif map.decimalComma:
        let d = dotDecimal(u, true)
        if parseutils.parseFloat(d, n) == d.len and d.len > 0:
          result.val.add n

proc timePattern*(log: ShotLog; map: ShotLogMap): string {.raises: [].} =
  ## The pattern that reads `map`'s Time (UTC) columns: `map.dateTimePattern`,
  ## or, when that is empty, the form of the first row that has a time. Empty
  ## when there is no Time (UTC) column or no row shows a form it knows.
  var cols: seq[int] = @[]
  for col, role in map.roles:
    if role == crTime: cols.add col
  result = map.dateTimePattern.strip
  if cols.len > 0 and result.len == 0 and log != nil:
    let (sentText, sentVal) = sentinelLists(map)
    var row = 0
    while row < log.len and row < 64 and result.len == 0:
      result = detectTimePattern(timeText(log, row, cols, sentText, sentVal,
        map.decimalComma))
      inc row

proc shots*(log: ShotLog; map: ShotLogMap): ShotView {.raises: [].} =
  ## Typed rows. The instant is the first source that parsed, in this order:
  ## GPSTB, then Time (UTC). The cells of the Time (UTC) columns are joined in
  ## column order, one space between, and read as `map.dateTimePattern` says
  ## (empty: the form of the first row that has a time); a calendar time is
  ## read on `map.clock`, the epoch forms are UTC. When both sources are there
  ## and differ by more than a millisecond, that is a problem naming both
  ## values; a gap of 18 s is called out as GPS and UTC mixed. Times that go
  ## backwards, a repeated (source line, source point, index) and a repeated
  ## FFID are problems too. An instant outside years 1900..2200 is a bad
  ## number and is not the row's time. A time that does not read as the
  ## pattern says is a problem naming the row's time text and the pattern. A
  ## second of 60 is kept, rolled into the next minute, and reported. Missing
  ## cells and sentinels are empty, not faults. A column mapped to Ignore is
  ## not read; user defined columns are kept as text in `texts`. A numeric
  ## cell is read from the stored text; it is not copied.
  result.problems = log.problems
  result.rows = newSeq[Shot](log.len)
  let (sentText, sentVal) = sentinelLists(map)
  var sentLo = Inf
  var sentHi = NegInf
  for v in sentVal:
    if v < sentLo: sentLo = v
    if v > sentHi: sentHi = v
  var timeCols: seq[int] = @[]
  for col, role in map.roles:
    if role == crTime: timeCols.add col
  let pattern = timePattern(log, map)
  template readNumber(chars: untyped) =
    case role
    of crSequence, crFileNumber, crPointIndex, crGpsMicros:
      if not isMissing(chars, sentText, sentVal, map.decimalComma):
        let whole = parseWhole(chars, map.decimalComma)
        if not whole.ok:
          addProblem(result.problems, pkBadNumber, row, col,
            $role & " '" & shotted(chars) & "' is not a whole number")
        else:
          case role
          of crSequence: shot.sequence = some(whole.value)
          of crFileNumber: shot.fileNumber = some(whole.value)
          of crPointIndex: shot.pointIndex = some(whole.value)
          else:
            if gps.isNone:
              gps = some(whole.value)
              gpsCol = col
    of crSailLine, crSourceLine, crShotPoint, crSourceDepth, crWaterDepth, crX, crY,
        crZ, crUphole:
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
        else: shot.uphole = num.value
      elif not miss:
        addProblem(result.problems, pkBadNumber, row, col,
          $role & " '" & shotted(chars) & "' is not a number")
    else: discard
  const NumberRoles = {crSequence, crFileNumber, crPointIndex, crGpsMicros, crSailLine,
    crSourceLine, crShotPoint, crSourceDepth, crWaterDepth, crX, crY, crZ, crUphole}
  var seenFile = initTable[int64, int]()
  var seenShot = initTable[(int64, int64, int64), int]()
  var lastTime: Option[int64] = none(int64)
  var lastTimeRow = -1
  for row in 0 ..< log.len:
    var shot = blankShot()
    var gps: Option[int64] = none(int64)
    var gpsCol = -1
    let roleCount = map.roles.len
    let fieldCount = fields(log, row)
    let colsN = max(roleCount, fieldCount)
    var fileCol = -1
    var pointCol = -1
    for col in 0 ..< colsN:
      let role = if col < roleCount: map.roles[col] else: crText
      if role in NumberRoles:
        if col >= fieldCount:
          readNumber("")
        else:
          let base = log.fieldOf[row].int
          let fa = log.fieldStart[base + col].int
          let fb = log.fieldStop[base + col].int
          if log.edits.len == 0 and (fb <= fa or log.text[fa] != '"'):
            if fb <= fa: readNumber("")
            else: readNumber(log.text.toOpenArray(fa, fb - 1))
          else:
            let raw = cell(log, row, col)
            readNumber(raw)
        if role == crFileNumber: fileCol = col
        elif role == crShotPoint: pointCol = col
      elif role in {crText, crStatus, crSourceType, crSourceId}:
        let raw = cell(log, row, col)
        let value = if col >= fieldCount or isMissing(raw, sentText, sentVal,
            map.decimalComma): "" else: raw.strip
        case role
        of crStatus: shot.status = value
        of crSourceType: shot.sourceType = value
        of crSourceId: shot.sourceId = value
        else: shot.texts.add value
    var instants: seq[Instant] = @[]
    if gps.isSome:
      let utc = gpsMicrosToUtcMicros(gps.get)
      keepInstant(instants, result.problems, row, $crGpsMicros, utc, gps.get, gpsCol)
    if timeCols.len > 0:
      let joined = timeText(log, row, timeCols, sentText, sentVal, map.decimalComma)
      if joined.len > 0:
        let read = if pattern.len > 0: readTime(joined, pattern, map.clock)
          else: TimeRead(why: "does not match any known form")
        if not read.ok:
          addProblem(result.problems, pkBadNumber, row, timeCols[0],
            "time '" & joined & "' " & read.why)
        else:
          if read.leap:
            addProblem(result.problems, pkBadNumber, row, timeCols[0],
              "time '" & joined & "' has second 60")
          if read.clash.len > 0:
            addProblem(result.problems, pkTimeDisagree, row, timeCols[0],
              "time '" & joined & "': " & read.clash)
          keepInstant(instants, result.problems, row, $crTime, read.us, read.us,
            timeCols[0])
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
          $crFileNumber & " " & $fn & " also on row " & $seenFile.getOrDefault(fn))
      else:
        seenFile[fn] = row
    if not shot.sourceLine.isNaN and not shot.shotPoint.isNaN:
      let idx = if shot.pointIndex.isSome: shot.pointIndex.get else: low(int64)
      let key = (canonBits(shot.sourceLine), canonBits(shot.shotPoint), idx)
      if seenShot.hasKey(key):
        addProblem(result.problems, pkDuplicateShot, row, pointCol,
          $crSourceLine & " " & $shot.sourceLine & " " & $crShotPoint & " " &
          $shot.shotPoint & " " & $crPointIndex & " " &
          (if shot.pointIndex.isSome: $shot.pointIndex.get else: "none") &
          " also on row " & $seenShot.getOrDefault(key))
      else:
        seenShot[key] = row
    result.rows[row] = shot
