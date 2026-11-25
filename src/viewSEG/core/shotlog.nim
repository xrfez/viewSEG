## A shot log: delimited text from a navigation or source-controller system,
## one row per shot. The file's text is kept once and cells are slices of it
## (`cell`), so a log of 100 000 rows is an index, not a copy of every cell.
## The caller reads the file; nothing here touches the file system.
##
## A `ShotLogMap` says which column is which (`ColumnRole`: Ignore, a system
## column the code refers to by role, or a user defined column with a name of
## its own), which clock the time is on, and which sentinels mean missing. The
## cell of the one Time (UTC) column is read by one pattern. `guessMap`
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
    ## system column that code refers to by role (one column each); `crText`
    ## is a user defined column, which has a name of its own
    ## (`ShotLogMap.names`).
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
    pkNoTime = "no time"

  TimeSplit* = enum
    ## Whether a log's time was found spread over several columns, which are
    ## not read: `tsFound` by `guessMap`, `tsOld` in a project saved when
    ## they were.
    tsNone = ""
    tsFound = "found"
    tsOld = "old"

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
    timeSplit*: TimeSplit
      ## the log's time is spread over several columns, which are not read
    dateTimePattern*: string
      ## How the cell of the one `crTime` column reads as a time: `yyyy` (four
      ## digits), `yy` (two), `ddd` (day of year), `mo` (month), `dd` (day of
      ## month), `hh`, `mi` (minute), `ss`, `f` (the digits of a fraction of a
      ## second, after a `.` or a `,`), `u` (whole microseconds) and any other
      ## character as written, as in `yyyy-mo-dd hh:mi:ss.ffffff`; a trailing
      ## `Z` is accepted; or `epoch seconds` or `epoch microseconds`. `mm` is
      ## not a token. Empty: the form is detected from the sampled rows, and
      ## when it cannot be decided no time is read from the column.
    sentinels*: seq[string] ## cell text that means missing, besides a blank
    decimalComma*: bool
      ## When set, a comma in a numeric cell is the decimal point. Default
      ## false. `guessMap` sets it only when the delimiter is not a comma and
      ## number columns use `digits,digits` rather than `digits.digits`.
    lengthUnit*: LengthUnit

  Shot* = object
    ## Typed values of one row. An integer is `none` when missing or a
    ## sentinel; a float is NaN. `timeUtcUs` is the one instant, UTC
    ## microseconds since 1970: GPSTB's when GPSTB is chosen (`none` where its
    ## cell does not read), else Time (UTC)'s.
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
    headerNames: seq[string] ## one per data column; "" where it has no name

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

proc fitHeaderNames(fields: seq[string]; width: int; spaces: bool): seq[string] {.raises: [], gcsafe.}

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
  ## where a header's names may hold spaces: they are fitted to the columns,
  ## and a name that cannot be fitted is "Column N") is kept and listed. Line endings
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
  if result.headerLine >= 0:
    var raw: seq[string] = @[]
    for k in 0 ..< result.headerCount:
      let at = result.headerField.int + k
      raw.add unquoteRange(result.text, result.fieldStart[at].int,
        result.fieldStop[at].int).strip()
    result.headerNames = fitHeaderNames(raw, result.width, delimiter == dlSpaces)

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
  ## The header name of data column `col`, quotes removed and ends trimmed.
  ## In a file cut at spaces the names are fitted to the columns, so a name
  ## with a space is one name; a name that could not be fitted is "Column N".
  ## Empty when there is no header, the header's cell is blank, or `col` is
  ## beyond the header.
  if col < 0 or col >= log.headerNames.len: "" else: log.headerNames[col]

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

const ExplicitEpoch = ["utc", "unix", "epoch", "posix"]
  ## words of a header name that say its numbers are on the UTC clock, not GPS

const SplitNames = ["year", "yr", "dayofyear", "julianday", "julian", "jday", "doy",
  "month", "mon", "dayofmonth", "dom", "day", "hour", "hr", "hh", "minute", "min",
  "microsecond", "microseconds", "usec", "second", "sec", "ss"]
  ## header names of one part of a time that is spread over several columns

func nameKey*(s: string): string =
  ## `s` compared as a name: lower case ASCII letters and digits, and every
  ## byte that is not ASCII as it is, so "Source Line", "source_line" and
  ## "SourceLine" are one name and two names in another script are not.
  ## Empty when `s` has only spaces and punctuation.
  for c in s:
    if c in Letters + Digits: result.add c.toLowerAscii
    elif c >= '\x80': result.add c

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
  elif nameKey(name).len == 0:
    "A user defined column's name needs a letter or a digit."
  elif isSystemName(name):
    "\"" & name.strip & "\" is one of the system's column names. Give this column " &
      "another name."
  else: ""

func isSystemRole*(role: ColumnRole): bool {.inline.} =
  ## A column the system refers to by role.
  role in {crTime .. crUphole}

func roleUnique*(role: ColumnRole): bool {.inline.} =
  ## A meaning that belongs to one column only: every system column,
  ## Time (UTC) too.
  role in {crTime .. crUphole}

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

func isSplitName(raw: string): bool =
  ## Whether `raw` names one part of a time spread over several columns:
  ## year, day of year, month, day, hour, minute, second or microsecond.
  let n = normHeader(raw)
  n in SplitNames

func gpsHeader(raw: string): bool =
  ## Whether the header name says GPS time: a GPSTB name ("GPS TB", "Time
  ## break") or a name with "gps" in it.
  roleOfName(raw) == crGpsMicros or "gps" in nameKey(raw)

func utcHeader(raw: string): bool =
  ## Whether the header name says its numbers are UTC: "utc", "unix", "epoch"
  ## or "posix" in it, parentheses included ("Time (UTC)"), and no "gps".
  let k = nameKey(raw)
  if "gps" in k: return false
  for w in ExplicitEpoch:
    if w in k: return true
  false

func knownHeader(raw: string): bool =
  roleOfName(raw) != crText or isSplitName(raw)

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
    ## a `dateTimePattern` for a column of seconds since 1970, a fraction allowed
  EpochMicros* = "epoch microseconds"
    ## a `dateTimePattern` for a column of whole microseconds since 1970
  PatternExample* = "dd/mo/yyyy hh:mi:ss"
  UndecidedTime* = "The time's form could not be decided: type the pattern, for example " &
    PatternExample
    ## said when a Time (UTC) column has no pattern the sampled rows decide
  UndecidedNumbers* = "Time (UTC) holds plain numbers, which may be GPS or Unix times: " &
    "type epoch seconds or epoch microseconds if they are Unix times, or choose GPSTB " &
    "for GPS microseconds."
    ## said instead when those cells are plain numbers: GPS or Unix cannot be told
  SplitTimeFound* = "This log's time is spread over several columns. Choose GPSTB, or " &
    "add one Time (UTC) column to the file."
  SplitTimeOld* = "This log's time was read from several columns before; that is no " &
    "longer done. Choose GPSTB or one Time (UTC) column."
  MmFault = "A pattern cannot have mm: write mo for the month and mi for the minute."
  GpsMissing* = "GPSTB missing"
    ## said on a row with no GPSTB when GPSTB is chosen: that row has no time
  GpsMissingAfter = "; " & GpsMissing
  SampleRows* = 64 ## rows whose cells decide a time's form

type
  TimeFieldKind = enum
    fkYear4, fkYear2, fkDoy, fkMonth, fkDay, fkHour, fkMinute, fkSecond, fkFraction,
    fkMicros, fkLiteral

  PatField = object
    kind: TimeFieldKind
    lit: char

  TimePattern = object
    ## A `dateTimePattern` taken apart once.
    text: string
    epoch: int    ## 1: epoch seconds, 2: epoch microseconds, 0: fields
    fault: string ## why the pattern cannot be used; "" when it can
    fields: seq[PatField]

  TimeParts = object
    y, m, d, doy, hh, mi, ss: int
    fracUs: int
      ## the fraction of the second, in microseconds, half up: 1_000_000 when
      ## it rounds up to the next second
    micros: int ## the `u` field; -1 when the pattern has none

func tokenOf(kind: TimeFieldKind): string =
  case kind
  of fkYear4: "yyyy"
  of fkYear2: "yy"
  of fkDoy: "ddd"
  of fkMonth: "mo"
  of fkDay: "dd"
  of fkHour: "hh"
  of fkMinute: "mi"
  of fkSecond: "ss"
  of fkFraction: "f"
  of fkMicros: "u"
  of fkLiteral: ""

func notAToken(p: string; at, run: int): string =
  "\"" & p.substr(at, at + run - 1) & "\" is not a field of a pattern: use yyyy, yy, " &
    "ddd, mo, dd, hh, mi, ss, f or u."

proc checkFields(pat: var TimePattern) =
  ## Each field once, and a year, a day, an hour, a minute and a second.
  var have: set[TimeFieldKind] = {}
  for f in pat.fields:
    if f.kind != fkLiteral:
      let slot = if f.kind == fkYear2: fkYear4 else: f.kind
      if slot in have:
        pat.fault = "\"" & tokenOf(f.kind) & "\" is written twice."
        return
      have.incl slot
  if fkDoy in have and (fkMonth in have or fkDay in have):
    pat.fault = "ddd is the day of the year: leave out mo and dd, or write mo and dd " &
      "and leave out ddd."
  elif fkYear4 notin have or fkHour notin have or fkMinute notin have or
      fkSecond notin have or (fkDoy notin have and (fkMonth notin have or
      fkDay notin have)):
    pat.fault = "The pattern must say the year, the day (ddd, or mo and dd), the hour " &
      "(hh), the minute (mi) and the second (ss)."

proc compilePattern(pattern: string): TimePattern =
  ## `pattern` taken apart. Its `fault` says why it cannot be used.
  let p = pattern.strip
  result.text = p
  let key = p.toLowerAscii
  if key == EpochSeconds:
    result.epoch = 1
  elif key == EpochMicros:
    result.epoch = 2
  else:
    var i = 0
    while i < p.len and result.fault.len == 0:
      let c = p[i].toLowerAscii
      var run = 1
      while i + run < p.len and p[i + run].toLowerAscii == c: inc run
      var kind = fkLiteral
      var width = 1
      case c
      of 'y':
        if run == 4: kind = fkYear4
        elif run == 2: kind = fkYear2
        else: result.fault = notAToken(p, i, run)
        width = run
      of 'd':
        if run == 3: kind = fkDoy
        elif run == 2: kind = fkDay
        else: result.fault = notAToken(p, i, run)
        width = run
      of 'h':
        if run == 2: kind = fkHour else: result.fault = notAToken(p, i, run)
        width = run
      of 's':
        if run == 2: kind = fkSecond else: result.fault = notAToken(p, i, run)
        width = run
      of 'f':
        kind = fkFraction
        width = run
      of 'u':
        kind = fkMicros
        width = run
      of 'm':
        let next = if i + 1 < p.len: p[i + 1].toLowerAscii else: ' '
        if run == 1 and next == 'o':
          kind = fkMonth
          width = 2
        elif run == 1 and next == 'i':
          kind = fkMinute
          width = 2
        else:
          result.fault = MmFault
      else: discard
      if result.fault.len == 0:
        result.fields.add PatField(kind: kind, lit: p[i])
        i += width
    if result.fault.len == 0: checkFields(result)

proc patternFault*(pattern: string): string =
  ## Why a typed `dateTimePattern` cannot be used, in words; "" when it can,
  ## and when it is empty (the form is then detected).
  if pattern.strip.len == 0: "" else: compilePattern(pattern).fault

func fieldWidth(kind: TimeFieldKind): tuple[lo, hi: int] =
  ## Digits a field takes: at most `hi`, so a digit run can never overflow.
  case kind
  of fkYear4: (4, 4)
  of fkYear2: (2, 2)
  of fkDoy: (1, 3)
  of fkMicros: (1, 6)
  else: (1, 2)

proc matchTime(text: string; pat: TimePattern; parts: var TimeParts): bool =
  ## Reads `text` as `pat` says. A `.` before `f` is also matched by a `,`,
  ## and the dot with its fraction may be absent (a whole second); a fraction
  ## is read to the microsecond, half up. A two-digit year uses the pivot 50:
  ## 50..99 is 19xx. A trailing `Z` is accepted.
  let t = text.strip
  var ti = 0
  parts = TimeParts(micros: -1)
  var noFraction = false
  for k, f in pat.fields:
    case f.kind
    of fkLiteral:
      let beforeFraction = f.lit == '.' and k + 1 < pat.fields.len and
        pat.fields[k + 1].kind == fkFraction
      if ti < t.len and (t[ti] == f.lit or (beforeFraction and t[ti] == ',')):
        inc ti
      elif beforeFraction:
        noFraction = true
      else:
        return false
    of fkFraction:
      if noFraction:
        noFraction = false
      else:
        var seen, used, frac = 0
        var roundUp = false
        while ti < t.len and t[ti] in Digits:
          if used < 6:
            frac = frac * 10 + (ord(t[ti]) - ord('0'))
            inc used
          elif seen == 6:
            roundUp = t[ti] >= '5'
          inc seen
          inc ti
        if seen == 0: return false
        var scale = 1
        for _ in used ..< 6: scale *= 10
        parts.fracUs = frac * scale + ord(roundUp)
    else:
      let (lo, hi) = fieldWidth(f.kind)
      var v, got = 0
      while ti < t.len and t[ti] in Digits and got < hi:
        v = v * 10 + (ord(t[ti]) - ord('0'))
        inc got
        inc ti
      if got < lo: return false
      case f.kind
      of fkYear4: parts.y = v
      of fkYear2: parts.y = if v >= 50: 1900 + v else: 2000 + v
      of fkDoy: parts.doy = v
      of fkMonth: parts.m = v
      of fkDay: parts.d = v
      of fkHour: parts.hh = v
      of fkMinute: parts.mi = v
      of fkSecond: parts.ss = v
      of fkMicros: parts.micros = v
      else: discard
  if ti < t.len and t[ti] in {'Z', 'z'}: inc ti
  ti == t.len

proc civilToUtcUs(y, m, d, hh, mm, ss, us: int; clock: TimeClock): Option[int64] =
  ## The instant of a calendar date and time on `clock`. 24:00:00 is 00:00:00
  ## of the next day; a second of 60 rolls into the next minute, and `us` of
  ## 1_000_000 (a fraction rounded up) into the next second.
  if not validDate(y, m, d): return none(int64)
  let midnight = hh == 24 and mm == 0 and ss == 0 and us == 0
  if (hh notin 0 .. 23 and not midnight) or mm notin 0 .. 59 or ss notin 0 .. 60 or
      us notin 0 .. 1_000_000:
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

proc readTime(text: string; pat: TimePattern; clock: TimeClock;
    decimalComma = false): TimeRead =
  ## One instant from `text` as `pat` says. The epoch forms are UTC; the
  ## others are on `clock`.
  let mismatch = "does not match " & pat.text
  if pat.epoch == 1:
    let sec = parseSecondsUs(text, decimalComma)
    if sec.ok: result = TimeRead(ok: true, us: sec.us) else: result.why = mismatch
  elif pat.epoch == 2:
    let whole = parseWhole(text)
    if whole.ok: result = TimeRead(ok: true, us: whole.value) else: result.why = mismatch
  else:
    var p: TimeParts
    if not matchTime(text, pat, p):
      result.why = mismatch
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

func plainNumber(t: string): bool =
  ## Digits, and a fraction after a dot.
  var i = 0
  while i < t.len and t[i] in Digits: inc i
  if i == 0: return false
  if i == t.len: return true
  if t[i] != '.': return false
  inc i
  let at = i
  while i < t.len and t[i] in Digits: inc i
  i == t.len and i > at

type Shape = object
  pattern: string ## "" when the cell has no form this proposes; no fraction, no Z
  fraction: bool  ## a fraction of the second follows
  zulu: bool      ## a `Z` ends the cell
  doy: bool       ## the date is a year and a day of year
  second: string  ## the digits of that day
  month: int      ## the month, of a year, a month and a day

proc shapeOf(t: string): Shape =
  ## The form of one date-time cell: a four-digit year first, then yyyy-mo-dd
  ## (`-`, `/` or `.`) or a day of year, an hour, a minute and a second with
  ## `:`, a fraction after `.` or `,`, and a `Z`. Anything else (a leading
  ## one or two digit run, a zone offset, a stray run of digits) has none.
  var runs: seq[tuple[a, b: int]] = @[]
  var i = 0
  while i < t.len:
    if t[i] in Digits:
      let a = i
      while i < t.len and t[i] in Digits: inc i
      runs.add (a, i)
    else:
      inc i
  if runs.len < 5 or runs[0].a != 0 or runs[0].b != 4: return
  proc width(k: int): int = runs[k].b - runs[k].a
  proc sep(k: int): string = t.substr(runs[k].b, runs[k + 1].a - 1)
  let rest = t.substr(runs[^1].b)
  if rest notin ["", "Z", "z"]: return
  let fraction = if runs.len >= 6 and sep(runs.len - 2) in [".", ","]: 1 else: 0
  let core = runs.len - fraction
  var pat = "yyyy"
  var timeAt = 0
  if core == 6:
    let s = sep(0)
    if width(1) notin 1 .. 2 or width(2) notin 1 .. 2 or s != sep(1) or
        s notin ["-", "/", "."]:
      return
    pat.add s & "mo" & s & "dd"
    for k in runs[1].a ..< runs[1].b: result.month = result.month * 10 + (ord(t[k]) - ord('0'))
    timeAt = 3
  elif core == 5:
    let s = sep(0)
    if width(1) notin 1 .. 3 or s notin ["-", "/", ".", " "]: return
    pat.add s & "ddd"
    result.doy = true
    result.second = t.substr(runs[1].a, runs[1].b - 1)
    timeAt = 2
  else:
    return
  let glue = sep(timeAt - 1)
  if glue notin [" ", "T", "t"]: return
  pat.add glue & "hh:mi:ss"
  for k in timeAt .. timeAt + 2:
    if width(k) notin 1 .. 2: return
  if sep(timeAt) != ":" or sep(timeAt + 1) != ":": return
  result.fraction = fraction == 1
  result.zulu = rest.len > 0
  result.pattern = pat

proc detectWith(cells: openArray[string]; epochLike: bool): string =
  ## `detectTimePattern`; with `epochLike` (the column's header says UTC), a
  ## column of seconds or microseconds since 1970 is epoch seconds or epoch
  ## microseconds. Without it, the same digits may be GPS seconds or
  ## microseconds, and no form is proposed for plain numbers.
  var vals: seq[string] = @[]
  for c in cells:
    let t = c.strip
    if t.len > 0: vals.add t
  if vals.len == 0: return ""
  var numbers = 0
  for t in vals:
    if plainNumber(t): inc numbers
  if numbers > 0:
    if numbers != vals.len: return ""
    var micros = epochLike
    var seconds = epochLike
    for t in vals:
      let whole = parseWhole(t)
      micros = micros and whole.ok and whole.value in 946_684_800_000_000'i64 ..
        4_102_444_800_000_000'i64
      let dot = t.find('.')
      let head = if dot < 0: t else: t.substr(0, dot - 1)
      let secs = parseWhole(head)
      seconds = seconds and secs.ok and secs.value in 946_684_800'i64 .. 4_102_444_800'i64
    if micros: return EpochMicros
    if seconds: return EpochSeconds
    return ""
  let first = shapeOf(vals[0])
  if first.pattern.len == 0: return ""
  var threeWide = true
  var over12 = false
  var fraction = false
  var zulu = true
  for t in vals:
    let shape = shapeOf(t)
    if shape.pattern != first.pattern: return ""
    fraction = fraction or shape.fraction
    zulu = zulu and shape.zulu
    if shape.month > 12: return "" # it may be the day: the order cannot be told
    if shape.doy:
      if shape.second.len != 3: threeWide = false
      var day = 0
      for ch in shape.second: day = day * 10 + (ord(ch) - ord('0'))
      if day > 12: over12 = true
  if first.doy and not (threeWide or over12): return ""
  # the fraction is optional in `matchTime`, and a trailing Z is accepted
  var pattern = first.pattern
  if fraction: pattern.add ".ffffff"
  if zulu: pattern.add "Z"
  # a row of this form whose value is not a time is a problem on that row
  pattern

proc detectTimePattern*(cells: openArray[string]): string =
  ## The pattern of the form of the non-blank cells of one column, or ""
  ## when the cells do not decide one. The form is decided from the cells'
  ## shapes: a cell of that form whose value is not a time (30 February, hour
  ## 25) is a problem on its row in `shots`, not a reason to refuse the form. Plain numbers are never proposed: seconds or
  ## microseconds may be on the GPS clock or since 1970, and the number cannot
  ## tell (`timePattern` proposes them under a header that says UTC).
  ## Proposed: a date and a time, as `shapeOf` says, when every cell has the
  ## same form, a fraction of the second and a trailing `Z` aside (a fraction
  ## on some rows makes it optional on all), and, for a year and a day of
  ## year, a day above 12 is there or every day has three digits. Not
  ## proposed: a leading
  ## one or two digit run (dd/mo/yy, mo/dd/yy, yy/mo/dd), a four-digit year
  ## in the third place (dd/mo/yyyy or mo/dd/yyyy), a month above 12 in any
  ## cell (it may be the day), a zone offset, and forms that differ between
  ## cells; the pattern is then typed.
  detectWith(cells, false)

proc nameLike(s: string): bool =
  ## A header cell: a letter, and not a date-time such as an ISO instant.
  hasLetter(s) and detectTimePattern([s]).len == 0

func uniqueName(base: string; used: var seq[string]; col: int): string =
  ## `base` as a user defined column's name: "Column N" when empty, " (file)"
  ## added to a system name, and a number added to a name another column has.
  ## The name's key is then added to `used`.
  var stem = base.strip
  if nameKey(stem).len == 0: stem = "Column " & $(col + 1)
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

func modernPattern(p: string): string =
  ## A stored pattern written as the earlier readers took it, where a run of
  ## y, m, d, h, s or f was a field of exactly that many digits: `mm`, and a
  ## lone `m`, is the month before an hour, else the minute; a lone `h`, `d`
  ## or `s` is `hh`, `dd` or `ss`. A lone letter before another field took
  ## exactly one digit, which no pattern says now: it is kept, and refused in
  ## words. The epoch forms, and today's `mo` and `mi`, are kept.
  const OldFields = {'y', 'm', 'd', 'h', 's', 'f'}
  let key = p.strip.toLowerAscii
  if key == EpochSeconds or key == EpochMicros: return p
  var seenHour = false
  var i = 0
  while i < p.len:
    let c = p[i].toLowerAscii
    var run = 1
    while i + run < p.len and p[i + run].toLowerAscii == c: inc run
    let next = if i + run < p.len: p[i + run].toLowerAscii else: '\0'
    let alone = run == 1 and next notin OldFields
    if c == 'm' and run == 1 and next in {'o', 'i'}:
      result.add p.substr(i, i + 1)
      i += 2
    elif c == 'm' and (run == 2 or alone):
      result.add if seenHour: "mi" else: "mo"
      i += run
    elif c in {'h', 'd', 's'} and alone:
      result.add c
      result.add c
      if c == 'h': seenHour = true
      inc i
    else:
      if c == 'h': seenHour = true
      result.add p.substr(i, i + run - 1)
      i += run

proc applyRoleNames*(map: var ShotLogMap; roleNames, columnNames: openArray[string]):
    string =
  ## Sets `map.roles` and `map.names` from the role words a project stored:
  ## the words of `ColumnRole`, and the older words, which are migrated.
  ## Time (UTC) is on one column. An older map's time becomes `crTime` on
  ## one column, with `dateTimePattern` set to read it the same way: UTC
  ## microseconds (`epoch microseconds`), else UTC seconds (`epoch seconds`),
  ## else date-time text (its pattern, `modernPattern`: `mm` written `mo` or
  ## `mi`, a lone `h`, `d` or `s` doubled); the
  ## first column of that kind, as the earlier reader took it. A map that
  ## already has a Time (UTC) column keeps its first, and its pattern. Every
  ## other older time column, and the year, day of year, month, day of month,
  ## hour, minute, second and microsecond columns, become user defined, named
  ## by their old word, and are not read. When a map had only those split
  ## columns for its time, `map.timeSplit` is `tsOld`. Gun array, volume,
  ## pressure, heading, speed and text become user defined, named by their
  ## old word (text: by the header). `columnNames` are the stored user
  ## defined names, if any. The result is "" or the first word that is neither.
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
  var current: seq[int] = @[] ## columns that already say Time (UTC)
  for c, role in map.roles:
    if role == crTime and parts[c] == lpNone: current.add c
  var chosen = -1
  var group = lpNone
  if current.len > 0:
    chosen = current[0]
    if current.len > 1: map.dateTimePattern = ""
    map.dateTimePattern = modernPattern(map.dateTimePattern)
  else:
    for want in [lpUtcUs, lpUtcSec, lpText]:
      if group == lpNone:
        for c, p in parts:
          if p == want:
            group = want
            chosen = c
            break
    case group
    of lpUtcUs: map.dateTimePattern = EpochMicros
    of lpUtcSec: map.dateTimePattern = EpochSeconds
    else: map.dateTimePattern = modernPattern(map.dateTimePattern)
  var split = false
  for c, p in parts:
    if p != lpNone:
      if c == chosen:
        map.roles[c] = crTime
        map.names[c] = ""
      else:
        map.roles[c] = crText
        for e in LegacyRoles:
          if e[2] == p: map.names[c] = e[0]
        if p in {lpYear .. lpMicro}: split = true
    elif map.roles[c] == crTime and c != chosen:
      map.roles[c] = crText
  if split and chosen < 0: map.timeSplit = tsOld
  var named = false
  for name in map.names:
    if name.len > 0: named = true
  if not named: map.names.setLen 0

func gpsPlausible(cells: openArray[string]): bool =
  ## Every non-empty cell is a whole number of microseconds on the GPS clock
  ## in 1999..2081 (a column of GPS seconds is not).
  var n = 0
  for c in cells:
    let t = c.strip
    if t.len > 0:
      inc n
      let whole = parseWhole(t)
      if not (whole.ok and whole.value in 600_000_000_000_000'i64 ..
          3_300_000_000_000_000'i64):
        return false
  n > 0

func secondsLike(cells: openArray[string]): bool =
  ## Every non-empty cell is a plain number whose whole part reads as seconds
  ## in about 1999..2100 on the GPS clock or since 1970, and there is one.
  var n = 0
  for c in cells:
    let t = c.strip
    if t.len > 0:
      inc n
      if not plainNumber(t): return false
      let dot = t.find('.')
      let whole = parseWhole(if dot < 0: t else: t.substr(0, dot - 1))
      if not (whole.ok and whole.value in 600_000_000'i64 .. 4_102_444_800'i64):
        return false
  n > 0

func microsLike(cells: openArray[string]): bool =
  ## Every non-empty cell is a whole number that reads as microseconds in
  ## about 1999..2100 on the GPS clock or since 1970, and there is one: the
  ## number cannot tell which.
  var n = 0
  for c in cells:
    let t = c.strip
    if t.len > 0:
      inc n
      let whole = parseWhole(t)
      if not (whole.ok and whole.value in 600_000_000_000_000'i64 ..
          4_102_444_800_000_000'i64):
        return false
  n > 0

proc timeLike(cells: openArray[string]): bool =
  ## Every non-empty cell has at least three runs of digits, as a date or a
  ## time has, and there is one.
  var n = 0
  for c in cells:
    let t = c.strip
    if t.len > 0:
      inc n
      var runs = 0
      var i = 0
      while i < t.len:
        if t[i] in Digits:
          inc runs
          while i < t.len and t[i] in Digits: inc i
        else:
          inc i
      if runs < 3: return false
  n > 0

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

proc fitHeaderNames(fields: seq[string]; width: int; spaces: bool): seq[string] {.raises: [], gcsafe.} =
  ## The names of `width` data columns from the header's `fields`. Equal
  ## counts, or more columns than names, or more names than columns in a file
  ## cut at a character: the leading names, and "Column N" for the rest. In a
  ## file cut at spaces a name may hold spaces: the fields are fitted into
  ## `width` names (`alignHeader`), and when that cannot be done every name
  ## is "Column N", never a piece of another name.
  result = newSeq[string](max(width, 0))
  for c in 0 ..< result.len: result[c] = "Column " & $(c + 1)
  if not spaces or fields.len <= width:
    for c in 0 ..< min(result.len, fields.len): result[c] = fields[c]
  else:
    let fit = alignHeader(fields, width)
    if fit.ok: result = fit.names

proc guessMap*(text: string): ShotLogMap {.raises: [].} =
  ## A starting map: delimiter, lines to skip, whether a header is there,
  ## and a role per column. The delimiter is the one most of the data rows
  ## use, not the header line's. Header names are matched ignoring case,
  ## spaces, underscores and a leading number prefix such as `07_`. When the
  ## header has more names than the rows have columns (names with spaces, in
  ## a file cut at spaces), the names are grouped to fit, and a header that
  ## cannot be fitted names nothing. A name that is not known, and every
  ## column when there is no header, is judged from the first data rows: an
  ## ISO date-time is Time (UTC). Whole microseconds are GPSTB only under a
  ## header that says GPS, and Time (UTC) (`epoch microseconds`) only under
  ## one that says UTC, Unix, epoch or posix; under any other header, or none,
  ## the number cannot tell GPS from Unix, so the column is user defined and
  ## `timeNote` and `shots` ask which it is. A role whose cells do not read
  ## as that role is not assigned, a system column found twice is kept once,
  ## and the other columns are user defined, named by their header. Of the
  ## columns that read as a time, the first whose form the sampled rows
  ## decide is Time (UTC), its pattern `dateTimePattern` (with none decided,
  ## the only one, with no pattern); the others are user defined. The clock stays UTC and the length unit stays metres unless a
  ## header says feet.
  result = initShotLogMap()
  if text.len > high(int32): return
  var phys = 0
  var keptPhys: seq[int] = @[]
  var keptStart: seq[int] = @[]
  var keptStop: seq[int] = @[]
  var i = 0
  let n = text.len
  while i < n and keptPhys.len < 80:
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
    if taken < SampleRows:
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
    if width == 0: width = fieldsOf.len
    headerNames = fitHeaderNames(fieldsOf, width, result.delimiter == dlSpaces)
  else:
    result.hasHeader = false
    result.skipLines = if keptPhys.len > 0: keptPhys[0] else: 0
  if samples.len < width: samples.setLen width
  result.roles = newSeq[ColumnRole](width)
  result.names = newSeq[string](width)
  var seenRoles: set[ColumnRole] = {}
  var timeCols: seq[int] = @[] ## columns that read as Time (UTC)
  var decided: seq[int] = @[] ## those whose cells decide a pattern
  var patterns = newSeq[string](width)
  var splitNamed = 0
  for c in 0 ..< width:
    var role = crText
    let name = if c < headerNames.len: headerNames[c] else: ""
    let cells = samples[c]
    var split = false
    if name.len > 0:
      role = roleOfName(name)
      split = role == crText and isSplitName(name)
      if mentionsFeet(name): result.lengthUnit = luFeet
    if split:
      inc splitNamed
    else:
      let utcName = name.len > 0 and utcHeader(name)
      var skipTime = false ## the header says GPS over cells that are not GPSTB
      if role in {crText, crTime, crGpsMicros} and name.len > 0 and gpsHeader(name):
        role = if gpsPlausible(cells): crGpsMicros else: crText
        skipTime = role == crText
      elif role in {crText, crTime} and not utcName and microsLike(cells):
        role = crText # GPS or Unix microseconds: the user is asked (`timeAsk`)
        skipTime = true
      if role == crText and not skipTime and detectWith(cells, utcName).len > 0:
        role = crTime
      if role == crTime:
        patterns[c] = detectWith(cells, utcName)
        if patterns[c].len > 0: decided.add c
        elif not timeLike(cells): role = crText
        if role == crTime: timeCols.add c
      elif role != crText and not cellsFit(role, cells): role = crText
    if role == crTime:
      result.roles[c] = crTime
    else:
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
  var keep = -1
  if decided.len > 0: keep = decided[0]
  elif timeCols.len == 1: keep = timeCols[0]
  elif timeCols.len > 1: result.timeSplit = tsFound
  if keep >= 0 and patterns[keep].len == 0 and crGpsMicros in seenRoles:
    keep = -1 # GPSTB is the time: an undecided form is user defined (`timeNote`)
  for c in timeCols:
    if c != keep: result.roles[c] = crText
  if keep >= 0: result.dateTimePattern = patterns[keep]
  if splitNamed >= 3: result.timeSplit = tsFound
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
    name: string; us, named: int64; col: int; outside = ""): bool =
  ## Adds the instant, or, outside years 1900..2200, a problem that ends with
  ## `outside`. True when it was added.
  if us < InstantLo or us > InstantHi:
    addProblem(problems, pkBadNumber, row, col,
      name & " " & $named & " is outside 1900..2200" & outside)
    false
  else:
    instants.add Instant(name: name, us: us, col: col)
    true

func fmtDiff(us: int64): string =
  let a = abs(us)
  if a mod UsPerSec == 0: $(a div UsPerSec) & " s"
  elif a mod 1000 == 0: $(a div 1000) & " ms"
  else: $a & " us"

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

func timeColumn*(map: ShotLogMap): int =
  ## The column mapped to Time (UTC), or -1. A map with several has the first.
  result = -1
  for col, role in map.roles:
    if role == crTime: return col

proc sampleCells(log: ShotLog; map: ShotLogMap; col: int): seq[string] =
  ## The cells of column `col` in the first `SampleRows` rows that are not
  ## blank or a sentinel.
  let (sentText, sentVal) = sentinelLists(map)
  for row in 0 ..< min(log.len, SampleRows):
    let raw = cell(log, row, col)
    if not isMissing(raw, sentText, sentVal, map.decimalComma): result.add raw

func allPlainNumbers(cells: openArray[string]): bool =
  ## Every cell is digits with an optional fraction, and there is one.
  for c in cells:
    if not plainNumber(c.strip): return false
  cells.len > 0

proc timePattern*(log: ShotLog; map: ShotLogMap): string {.raises: [].} =
  ## The pattern that reads `map`'s Time (UTC) column: `map.dateTimePattern`,
  ## or, when that is empty, the one the cells of its first rows decide
  ## (`detectTimePattern`; seconds or microseconds since 1970 only when the
  ## column's header says UTC, Unix, epoch or posix). Empty when there is no
  ## Time (UTC) column or the cells decide none.
  let col = timeColumn(map)
  result = map.dateTimePattern.strip
  if col >= 0 and result.len == 0 and log != nil:
    result = detectWith(sampleCells(log, map, col), utcHeader(log.columnName(col)))

proc undecidedWords(log: ShotLog; map: ShotLogMap): string =
  ## What is said when the Time (UTC) column's form is not decided.
  let col = timeColumn(map)
  if log != nil and col >= 0 and allPlainNumbers(sampleCells(log, map, col)):
    UndecidedNumbers
  else:
    UndecidedTime

proc timeAsk(log: ShotLog; map: ShotLogMap): tuple[col: int; text: string] =
  ## With neither GPSTB nor Time (UTC) chosen: the first user defined column
  ## that holds a time that is not read, and what to choose, in words.
  ## (-1, "") when there is none.
  result = (-1, "")
  if log == nil: return
  for col, role in map.roles:
    if role == crText:
      let header = log.columnName(col)
      let name = if header.len > 0: header else: "Column " & $(col + 1)
      let cells = sampleCells(log, map, col)
      if microsLike(cells):
        return (col, "\"" & name & "\" holds microsecond times, GPS or Unix: choose " &
          "GPSTB or Time (UTC).")
      let timeNamed = header.len > 0 and roleOfName(header) == crTime
      if timeNamed and not gpsHeader(header) and secondsLike(cells):
        return (col, "\"" & name & "\" holds seconds, GPS or Unix: choose Time (UTC) and " &
          "type epoch seconds if they are Unix seconds; GPS seconds are not read.")
      if timeNamed or (header.len > 0 and gpsHeader(header)):
        return (col, "\"" & name & "\" looks like a time, but its values are not in a " &
          "form that is read (GPS seconds are not). Choose Time (UTC) for it and type " &
          "the pattern, or choose GPSTB.")

proc timeNote*(log: ShotLog; map: ShotLogMap): string {.raises: [].} =
  ## The sentence the Columns dialog shows about the time, true of `map`:
  ## how Time (UTC) is read, that its form could not be decided or its
  ## pattern cannot be used, that the log's time is spread over several
  ## columns, or that a column that looks like a time is not read (numbers
  ## that may be GPS or Unix microseconds: which to choose; beside GPSTB, a
  ## time whose form was not decided). "" when there is nothing to say.
  if timeColumn(map) >= 0:
    let fault = patternFault(map.dateTimePattern)
    if fault.len > 0: return fault
    let used = timePattern(log, map)
    return if used.len > 0: "Time (UTC) is read as " & used else: undecidedWords(log, map)
  if crGpsMicros in map.roles:
    if log != nil:
      for col, role in map.roles:
        let header = log.columnName(col)
        if role == crText and header.len > 0 and roleOfName(header) == crTime and
            timeLike(sampleCells(log, map, col)):
          return "\"" & header & "\" is user defined: its time's form could not be " &
            "decided, and GPSTB is the time. Choose Time (UTC) for it and type the " &
            "pattern to check it against GPSTB."
    return ""
  if map.timeSplit == tsOld: return SplitTimeOld
  if map.timeSplit == tsFound: return SplitTimeFound
  timeAsk(log, map).text

proc shots*(log: ShotLog; map: ShotLogMap): ShotView {.raises: [].} =
  ## Typed rows. With GPSTB chosen the instant is GPSTB's: a row whose GPSTB
  ## is empty, a sentinel, unreadable or outside 1900..2200 has no time and a
  ## problem that says `GpsMissing`, and Time (UTC) is never its instant
  ## instead. Without GPSTB the instant is Time (UTC)'s, which is one column.
  ## Its cell is read as `map.dateTimePattern` says (empty: the pattern the
  ## first rows decide; when they decide none, no time is read from the
  ## column and one problem at the top says so); a calendar time is read on
  ## `map.clock`, the epoch forms are UTC. A log whose time was found spread
  ## over several columns (`map.timeSplit`), or that has a user defined
  ## column holding a time that is not read (`timeNote`), with neither GPSTB
  ## nor Time (UTC) mapped, has one problem at the top and no times. When
  ## both sources are there and differ by more than a millisecond, that is a
  ## problem naming both values and saying GPSTB is used; a gap of 18 s is
  ## called out as GPS and UTC mixed. Times that go backwards, a repeated (source line, source point, index) and a repeated
  ## FFID are problems too. An instant outside years 1900..2200 is a bad
  ## number and is not the row's time. A time that does not read as the
  ## pattern says is a problem naming the row's time text and the pattern. A
  ## second of 60 is kept, rolled into the next minute, and reported. Missing
  ## cells and sentinels are empty, not faults. A column mapped to Ignore is
  ## not read; user defined columns are kept as text in `texts`. A numeric
  ## cell is read from the stored text; it is not copied.
  let timeCol = timeColumn(map)
  let pat = if timeCol >= 0 and map.dateTimePattern.strip.len > 0:
      compilePattern(map.dateTimePattern)
    else: compilePattern(timePattern(log, map))
  var top = ProblemList()
  if timeCol >= 0:
    if pat.text.len == 0:
      addProblem(top, pkNoTime, -1, timeCol, undecidedWords(log, map))
    elif pat.fault.len > 0:
      addProblem(top, pkNoTime, -1, timeCol, "Time (UTC) cannot be read: " & pat.fault)
  elif crGpsMicros notin map.roles and map.timeSplit != tsNone:
    addProblem(top, pkNoTime, -1, -1,
      if map.timeSplit == tsOld: SplitTimeOld else: SplitTimeFound)
  elif crGpsMicros notin map.roles:
    let ask = timeAsk(log, map)
    if ask.col >= 0: addProblem(top, pkNoTime, -1, ask.col, ask.text)
  for p in log.problems.items: addProblem(top, p.kind, p.row, p.col, p.text)
  top.count += log.problems.count - log.problems.items.len
  result.problems = top
  result.rows = newSeq[Shot](log.len)
  let (sentText, sentVal) = sentinelLists(map)
  var sentLo = Inf
  var sentHi = NegInf
  for v in sentVal:
    if v < sentLo: sentLo = v
    if v > sentHi: sentHi = v
  template readNumber(chars: untyped) =
    case role
    of crSequence, crFileNumber, crPointIndex, crGpsMicros:
      if not isMissing(chars, sentText, sentVal, map.decimalComma):
        let whole = parseWhole(chars, map.decimalComma)
        if not whole.ok:
          addProblem(result.problems, pkBadNumber, row, col,
            $role & " '" & shotted(chars) & "' is not a whole number" &
            (if role == crGpsMicros: GpsMissingAfter else: ""))
          if role == crGpsMicros: gpsSaid = true
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
  let gpsColumn = map.roles.find(crGpsMicros)
  var seenFile = initTable[int64, int]()
  var seenShot = initTable[(int64, int64, int64), int]()
  var lastTime: Option[int64] = none(int64)
  var lastTimeRow = -1
  for row in 0 ..< log.len:
    var shot = blankShot()
    var gps: Option[int64] = none(int64)
    var gpsCol = -1
    var gpsSaid = false ## a problem already says the row's GPSTB is missing
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
    var gpsKept = false
    if gps.isSome:
      let utc = gpsMicrosToUtcMicros(gps.get)
      gpsKept = keepInstant(instants, result.problems, row, $crGpsMicros, utc, gps.get,
        gpsCol, GpsMissingAfter)
      gpsSaid = not gpsKept
    if gpsColumn >= 0 and not gpsSaid and not gpsKept:
      addProblem(result.problems, pkNoTime, row, gpsColumn, GpsMissing)
    if timeCol >= 0 and pat.text.len > 0 and pat.fault.len == 0 and
        timeCol < fieldCount:
      let raw = cell(log, row, timeCol)
      if not isMissing(raw, sentText, sentVal, map.decimalComma):
        let text = raw.strip
        let read = readTime(text, pat, map.clock, map.decimalComma)
        if not read.ok:
          addProblem(result.problems, pkBadNumber, row, timeCol,
            "time '" & text & "' " & read.why)
        else:
          if read.leap:
            addProblem(result.problems, pkBadNumber, row, timeCol,
              "time '" & text & "' has second 60")
          if read.clash.len > 0:
            addProblem(result.problems, pkTimeDisagree, row, timeCol,
              "time '" & text & "': " & read.clash)
          discard keepInstant(instants, result.problems, row, $crTime, read.us, read.us,
            timeCol)
    if gpsColumn >= 0 and not gpsKept:
      instants.setLen 0 # with GPSTB chosen, Time (UTC) is never the instant instead
    if instants.len > 0:
      shot.timeUtcUs = some(instants[0].us)
      for k in 1 ..< instants.len:
        let diff = instants[k].us - instants[0].us
        if abs(diff) > DisagreeUs:
          var msg = instants[0].name & " " & $instants[0].us & " and " &
            instants[k].name & " " & $instants[k].us & " differ by " & fmtDiff(diff)
          if abs(abs(diff) - MixedClockUs) <= DisagreeUs:
            msg.add "; GPS and UTC mixed"
          msg.add ": " & instants[0].name & " is used"
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
