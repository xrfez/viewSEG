## A shot log's source points as an SPS file (revision 1.0 or 2.1).
##
## `toSps` writes one S record per row that has a shot point and whose line,
## point, index, coordinates and depths fit that revision's columns. A value
## the columns would round or cut is a problem, not a record. `writeShotSps`
## writes the text through a temporary file beside the path, then renames it.
## When no row was written it leaves the path untouched. Neither proc raises.
##
## A missing elevation is left blank (the writer can). A missing easting or
## northing is reported and the row is skipped. SPS has no year: the result
## carries the first and last year of the times it wrote. The fraction of a
## second does not fit in the time columns and is dropped.

import std/[math, options, sets, strutils]
from std/os import getCurrentProcessId, parentDir
import parseSEG
import filesystem, shotlog

const
  UsPerSec = 1_000_000'i64
  SecPerDay = 86_400'i64
  UsPerDay = SecPerDay * UsPerSec
  FitTol = 1e-12

type
  ShotSpsOptions* = object
    ## How `toSps` turns a shot log into source points. Start from
    ## `initShotSpsOptions`: a zero value has revision `spsAuto`, which is
    ## reported and writes nothing.
    revision*: SpsRevision
      ## `sps10` or `sps21`. `spsAuto` is reported, not guessed.
    defaultLine*: float64
      ## Used where `sourceLine` is NaN. NaN means there is no default.
    defaultIndex*: int
      ## Used where `pointIndex` is `none`. One digit, 0 to 9.
    pointCode*: string
      ## Two bytes at most, each in ' '..'~'. A longer code, or a byte
      ## outside that range, is one problem and no records.
    withTime*: bool
      ## Write the day of year and the time from `timeUtcUs`.

  ShotSpsProblem* = object
    ## One value that does not fit, or one bad option. `row` is the 0-based
    ## row, or -1 when the option itself is the problem.
    row*: int
    field*: string
    value*: string

  ShotSpsResult* = object
    ## The records that fit, and what was left out. `count` is every problem;
    ## `problems` keeps the first `ProblemCap`.
    file*: SpsFile
    text*: string
      ## The S records, from `spsText`. Empty when none fit, or when a record
      ## still did not encode.
    problems*: seq[ShotSpsProblem]
    count*: int
    written*: int
    skipped*: int
    fractionDropped*: int
      ## Rows whose `timeUtcUs` had a non-zero fraction of a second, when
      ## `withTime` is set, whether or not the row was written.
    duplicates*: int
      ## Extra rows that repeat a line, point and index already written.
      ## Every one of them is still in `file`.
    firstYear*: Option[int]
      ## Year of the first written row that carried a time. `none` when no
      ## such row was written. SPS has no year column.
    lastYear*: Option[int]
      ## Year of the last written row that carried a time.
    yearChanged*: bool
      ## A written time is not in `firstYear`.
    error*: string
      ## Set by `writeShotSps` when the file was not replaced. Empty otherwise.
      ## When no row was written, it starts with "No row could be written."

  UtcParts = object
    ok: bool
    year: int
    doy: int
    hour: int
    minute: int
    second: int
    fraction: int64

proc initShotSpsOptions*(): ShotSpsOptions =
  ## Revision 2.1, no default line, point index 1, no point code, no time.
  result.revision = sps21
  result.defaultLine = NaN
  result.defaultIndex = 1

proc addProblem(r: var ShotSpsResult; row: int; field, value: string) =
  inc r.count
  if r.problems.len < ProblemCap:
    r.problems.add ShotSpsProblem(row: row, field: field, value: value)

proc plain(v: float64): float64 =
  if v == 0.0: 0.0 else: v

proc exactAt(v: float64; decimals: int): bool =
  let shown = formatFloat(v, ffDecimal, decimals)
  try:
    let back = parseFloat(shown)
    abs(v - back) <= max(abs(v), abs(back)) * FitTol + FitTol
  except ValueError:
    false

proc fixedFits(v: float64; width, decimals: int): bool =
  ## True when `v` is already an Fw.d number and that text fits `width`.
  ## A value the writer would round, or whose text is wider, does not.
  if v.isNaN or abs(v) > 1e15: return false
  let shown = formatFloat(v, ffDecimal, decimals)
  shown.len > 0 and shown.len <= width and exactAt(v, decimals)

proc numText(v: float64): string =
  if v == round(v) and abs(v) < 1e15: $int64(v) else: $v

proc nameFits(v: float64; width: int): bool =
  if classify(v) in {fcNan, fcInf, fcNegInf}: return false
  let t = numText(v)
  t.len in 1 .. width

proc intTextFits(v: float64; width: int): bool =
  v == round(v) and abs(v) < 1e15 and ($int64(v)).len in 1 .. width

proc lineFits(v: float64; rev: SpsRevision): bool =
  if rev == sps21: fixedFits(v, 10, 2) else: nameFits(v, 16)

proc pointFits(v: float64; rev: SpsRevision): bool =
  if rev == sps21: fixedFits(v, 10, 2) else: nameFits(v, 8)

proc waterFits(v: float64; rev: SpsRevision): bool =
  if v.isNaN: return true
  if rev == sps10: fixedFits(v, 4, 1) or intTextFits(v, 4)
  else: fixedFits(v, 6, 1)

proc pointCodeFits(code: string): bool =
  ## Two bytes at most, each a printable ASCII character.
  if code.len > 2: return false
  for c in code:
    if c < ' ' or c > '~': return false
  true

proc ident(rev: SpsRevision; line, point: float64; index: int): string =
  if rev == sps21:
    formatFloat(line, ffDecimal, 2) & " " & formatFloat(point, ffDecimal, 2) &
      " " & $index
  else:
    numText(line) & " " & numText(point) & " " & $index

proc floorDiv(a, b: int64): int64 =
  let q = a div b
  if a >= 0 or a mod b == 0: q else: q - 1

proc floorMod(a, b: int64): int64 =
  let m = a mod b
  if m < 0: m + b else: m

proc isLeap(y: int64): bool =
  y mod 4 == 0 and (y mod 100 != 0 or y mod 400 == 0)

proc dayOfYear(y: int64; month, day: int): int =
  const before = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
  result = before[month - 1] + day
  if month > 2 and isLeap(y): inc result

proc civil(days: int64): tuple[ok: bool; year: int; doy: int] =
  ## Howard Hinnant's `civil_from_days`: `days` since 1970-01-01, proleptic
  ## Gregorian, 86400-second days.
  let z = days + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  var y = yoe + era * 400
  let doy0 = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy0 + 2) div 153
  let d = int(doy0 - (153 * mp + 2) div 5 + 1)
  let m = int(if mp < 10: mp + 3 else: mp - 9)
  if m <= 2: y += 1
  if y < low(int).int64 or y > high(int).int64 or m < 1 or m > 12 or d < 1:
    return (false, 0, 0)
  (true, int(y), dayOfYear(y, m, d))

proc utcParts(us: int64): UtcParts =
  let days = floorDiv(us, UsPerDay)
  let rem = floorMod(us, UsPerDay)
  result.fraction = rem mod UsPerSec
  let sec = rem div UsPerSec
  result.hour = int(sec div 3600)
  result.minute = int((sec div 60) mod 60)
  result.second = int(sec mod 60)
  let c = civil(days)
  result.ok = c.ok
  result.year = c.year
  result.doy = c.doy

proc indexOf(row: Shot; defaultIndex: int): tuple[ok: bool; value: int; shown: string] =
  if row.pointIndex.isSome:
    let v = row.pointIndex.get
    if v < 0 or v > 9: return (false, 0, $v)
    (true, int(v), $v)
  elif defaultIndex < 0 or defaultIndex > 9:
    (false, 0, $defaultIndex)
  else:
    (true, defaultIndex, $defaultIndex)

proc noteYear(r: var ShotSpsResult; year: int) =
  if r.firstYear.isNone:
    r.firstYear = some(year)
  elif r.firstYear.get != year:
    r.yearChanged = true
  r.lastYear = some(year)

proc buildPoint(row: Shot; opts: ShotSpsOptions; line: float64; index: int;
    parts: UtcParts; timed: bool): SpsPoint =
  result = initSpsPoint(pkSource)
  result.line = line
  result.point = plain(row.shotPoint)
  result.index = index
  result.code = opts.pointCode
  if not row.sourceDepth.isNaN: result.pointDepth = plain(row.sourceDepth)
  if not row.waterDepth.isNaN: result.waterDepth = plain(row.waterDepth)
  result.easting = plain(row.x)
  result.northing = plain(row.y)
  if not row.z.isNaN: result.elevation = plain(row.z)
  if timed and parts.ok:
    result.dayOfYear = parts.doy
    result.hour = parts.hour
    result.minute = parts.minute
    result.second = parts.second

proc toSps*(view: ShotView; opts: ShotSpsOptions): ShotSpsResult {.raises: [].} =
  ## One S record per row that has a shot point and fits. A NaN shot point is
  ## skipped and counted, and is not a problem. A NaN `x` or `y` is skipped
  ## and reported. A NaN `z` is written blank. Depths are written when present.
  ##
  ## Revision 2.1 holds a line and a point in 10 columns and 2 decimals
  ## (-999999.99 to 9999999.99). Revision 1.0 holds them as text, 16 and 8
  ## columns, an integer without a fraction. A non-finite value does not fit.
  ## An index is one digit. A point
  ## depth is 4 columns and 1 decimal (-9.9 to 99.9). Water depth is 6 columns
  ## and 1 decimal in 2.1, and 4 in 1.0 (an integer whose text fits in 4
  ## columns is kept, so 999 and 9999 fit 1.0). Easting is 9 columns and 1
  ## decimal, northing 10, elevation 6. A value that is not already that
  ## number of decimals does not fit: it is not rounded.
  ##
  ## When `withTime` is set, the day of year and the time are UTC, from integer
  ## arithmetic on the microseconds. The fraction of a second is dropped and
  ## `fractionDropped` counts those rows. Years are `firstYear` and `lastYear`;
  ## `yearChanged` is set when the written times are not all in one year.
  ## Duplicate line, point and index are all written and counted.
  var optsOk = true
  if opts.revision notin {sps10, sps21}:
    addProblem(result, -1, "revision", $opts.revision)
    optsOk = false
  if not pointCodeFits(opts.pointCode):
    addProblem(result, -1, "pointCode", opts.pointCode)
    optsOk = false
  if optsOk:
    result.file.revision = opts.revision
    result.file.points = newSeqOfCap[SpsPoint](view.rows.len)
  var seen = initHashSet[string]()
  for i, row in view.rows:
    var parts = UtcParts()
    let timed = opts.withTime and row.timeUtcUs.isSome
    if timed:
      parts = utcParts(row.timeUtcUs.get)
      if parts.ok and parts.fraction != 0:
        inc result.fractionDropped
    if not optsOk or row.shotPoint.isNaN:
      inc result.skipped
    else:
      var bad = false
      let line = plain(if row.sourceLine.isNaN: opts.defaultLine else: row.sourceLine)
      if not lineFits(line, opts.revision):
        addProblem(result, i, "line", $line)
        bad = true
      let point = plain(row.shotPoint)
      if not pointFits(point, opts.revision):
        addProblem(result, i, "point", $point)
        bad = true
      let idx = indexOf(row, opts.defaultIndex)
      if not idx.ok:
        addProblem(result, i, "index", idx.shown)
        bad = true
      let easting = plain(row.x)
      if easting.isNaN or not fixedFits(easting, 9, 1):
        addProblem(result, i, "easting", $easting)
        bad = true
      let northing = plain(row.y)
      if northing.isNaN or not fixedFits(northing, 10, 1):
        addProblem(result, i, "northing", $northing)
        bad = true
      let elevation = plain(row.z)
      if not elevation.isNaN and not fixedFits(elevation, 6, 1):
        addProblem(result, i, "elevation", $elevation)
        bad = true
      let depth = plain(row.sourceDepth)
      if not depth.isNaN and not fixedFits(depth, 4, 1):
        addProblem(result, i, "pointDepth", $depth)
        bad = true
      let water = plain(row.waterDepth)
      if not waterFits(water, opts.revision):
        addProblem(result, i, "waterDepth", $water)
        bad = true
      if timed and not parts.ok:
        addProblem(result, i, "time", $row.timeUtcUs.get)
        bad = true
      if bad:
        inc result.skipped
      else:
        let key = ident(opts.revision, line, point, idx.value)
        if key in seen: inc result.duplicates
        else: seen.incl key
        result.file.points.add buildPoint(row, opts, line, idx.value, parts, timed)
        if timed and parts.ok: noteYear(result, parts.year)
        inc result.written
  if result.file.points.len == 0: return
  try:
    let written = spsText(result.file)
    if written.log.hasErrors:
      addProblem(result, -1, "record", "a record does not fit its columns")
    else:
      result.text = written.text
  except CatchableError as e:
    addProblem(result, -1, "record", e.msg)

proc nothingError(r: ShotSpsResult): string {.raises: [].} =
  ## "No row could be written." plus the problems `toSps` listed.
  result = "No row could be written."
  if r.problems.len == 0: return
  result.add " "
  for i, p in r.problems:
    if i > 0: result.add "; "
    result.add "row " & $p.row & " " & p.field & " " & p.value
  if r.count > r.problems.len:
    result.add "; "
    result.add $(r.count - r.problems.len) & " more"

proc writeBeside(path, text: string): string {.raises: [].} =
  ## `text` to a temporary file beside `path`, flushed, then renamed over
  ## `path`. Empty when `path` was replaced.
  let parent = path.parentDir
  let tmp = path & "." & $getCurrentProcessId() & ".tmp"
  var f: File = nil
  try:
    if parent.len > 0: fs.createDir(parent)
    if not fs.open(f, tmp, fmWrite):
      return "cannot write " & path
    try:
      if text.len > 0 and
          fs.writeBuffer(f, tmp, unsafeAddr text[0], text.len) != text.len:
        raise newException(IOError, "the disk did not take " & path)
      flushFile(f)
    finally:
      close(f)
    fs.moveFile(tmp, path)
  except Exception as e:
    discard fs.tryRemoveFile(tmp)
    result = if e.msg.len > 0: e.msg else: "cannot write " & path

proc writeShotSps*(view: ShotView; opts: ShotSpsOptions; path: string): ShotSpsResult {.
    raises: [].} =
  ## `toSps`, then that text written to `path` through a temporary file beside
  ## it and a rename. `error` is empty when `path` was replaced. When no row
  ## was written, `path` is left untouched and `error` is "No row could be
  ## written." plus the problems listed. A failure leaves `path` as it was
  ## and does not raise.
  result = toSps(view, opts)
  if result.written == 0:
    result.error = nothingError(result)
  elif result.text.len == 0:
    result.error = "the SPS text could not be built"
  else:
    result.error = writeBeside(path, result.text)
