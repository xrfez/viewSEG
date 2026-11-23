## The missing-trace report: two tables from per-record completeness, and
## the folder totals, sorted and written as CSV. A folder scan hands in one
## `FileRecords` per seismic file (`path` relative to the chosen folder,
## subfolders included). This module does not read files, start jobs or
## keep state.
##
## `RecordCompleteness` stores how many stations were duplicated, not which
## ones, so a duplicate row is the file, the record and that count
## (`DuplicatesNote`). Stations the survey did not list (`unlisted`) are a
## count on the record row, never a point. `expectedIn` is the records whose
## relation runs list the station, plus any record that lists it missing
## when the survey has no spread for that record. `never` is
## `missingIn == expectedIn`: the station produced no trace in any record
## that expected it. With no survey, that is every record that lists it
## missing.

import std/[algorithm, strutils, tables]
import parseSEG
import processSEG/qc/record
from records import stationNumber

type
  FileRecords* = object
    ## One seismic file of the folder.
    path*: string ## Relative to the chosen folder.
    records*: seq[RecordCompleteness]

  RecordRow* = object
    ## One field record of one file.
    file*: string
    record*: float64       ## Header field-record number; NaN when the file has none.
    expected*, present*, missing*, duplicates*, unlisted*: int
    missingPoints*: string ## Compact ranges, one line of text per receiver line.

  RecordPointRow* = object
    ## One missing station of one record, for a CSV and an expandable row.
    file*: string
    record*: float64
    line*, point*: float64
    index*: int16

  PointRow* = object
    ## A station missing in at least one record of the folder.
    line*, point*: float64
    index*: int16
    expectedIn*: int              ## Records that expected it.
    missingIn*: int               ## Records where it produced no trace.
    never*: bool                  ## `missingIn == expectedIn`: no trace anywhere it was expected.
    firstFile*, lastFile*: string ## Files of the first and last record it is missing in.
    firstRecord*, lastRecord*: float64

  DuplicateRow* = object
    ## A record's duplicate count. The library stores no station list, so
    ## this row has no line, point or index.
    file*: string
    record*: float64
    count*: int

  Totals* = object
    ## Folder totals. Counts other than `files`, `never` and `percentMissing`
    ## are `summarize`'s; they are not added up again here.
    files*, records*: int
    expected*, present*, missing*, never*: int
    duplicates*, extras*: int
    xpsWithoutData*: seq[int64] ## Survey records no file matched, as `summarize` lists them.
    percentMissing*: float64 ## `100 * missing / expected`, or 0 when nothing was expected.

  MissingReport* = object
    records*: seq[RecordRow]
    recordPoints*: seq[RecordPointRow]
    points*: seq[PointRow]
    duplicates*: seq[DuplicateRow]
    totals*: Totals
    duplicatesNote*: string ## Why `duplicates` names no stations.

  RecordSortColumn* = enum
    ## A column of `RecordRow`.
    rsFile, rsRecord, rsExpected, rsPresent, rsMissing, rsDuplicates, rsUnlisted

  PointSortColumn* = enum
    ## A column of `PointRow`.
    psNever, psMissingIn, psExpectedIn, psLine, psPoint, psIndex, psFirstFile,
    psFirstRecord, psLastFile, psLastRecord

  SortSpec*[C] = seq[tuple[column: C, descending: bool]]
    ## Sort keys, first one most significant. A tie keeps the rows' order.

const
  DuplicatesNote* =
    "RecordCompleteness stores a duplicate count, not which stations were duplicated."
  DefaultRecordSort*: SortSpec[RecordSortColumn] = @[
    (column: rsFile, descending: false), (column: rsRecord, descending: false)]
  DefaultPointSort*: SortSpec[PointSortColumn] = @[
    (column: psNever, descending: true), (column: psMissingIn, descending: true),
    (column: psLine, descending: false), (column: psPoint, descending: false),
    (column: psIndex, descending: false)]

func rangesText[T](ranges: openArray[T]): string =
  ## `ranges` as one line of text per receiver line: the line number, then
  ## each run as `n` or `first-last`, joined by ", ".
  var i = 0
  var firstLine = true
  while i < ranges.len:
    if not firstLine: result.add '\n'
    firstLine = false
    let line = ranges[i].line
    result.add stationNumber(line)
    var bit = 0
    while i < ranges.len and ranges[i].line == line:
      let first = ranges[i].firstPoint
      let last = ranges[i].lastPoint
      result.add if bit == 0: ' ' else: ','
      if bit > 0: result.add ' '
      result.add stationNumber(first)
      if first != last:
        result.add '-'
        result.add stationNumber(last)
      inc bit
      inc i

func csvField(s: string): string =
  ## `s` quoted per RFC 4180 when it holds a comma, a quote or a line break.
  var quote = false
  for c in s:
    if c in {',', '"', '\n', '\r'}:
      quote = true
      break
  if not quote: return s
  result = "\""
  for c in s:
    if c == '"': result.add '"'
    result.add c
  result.add '"'

func csvLine(fields: varargs[string]): string =
  for i, f in fields:
    if i > 0: result.add ','
    result.add csvField(f)
  result.add '\n'

func percentText(x: float64): string =
  if x == round(x) and abs(x) < 1e15: $int64(x) else: formatFloat(x, ffDecimal, 2)

func cmpNum(a, b: float64): int =
  ## Numeric order; NaN sorts after every number.
  let an = a != a
  let bn = b != b
  if an and bn: 0
  elif an: 1
  elif bn: -1
  else: cmp(a, b)

func cmpRecord(a, b: RecordRow; column: RecordSortColumn): int =
  case column
  of rsFile: cmp(a.file, b.file)
  of rsRecord: cmpNum(a.record, b.record)
  of rsExpected: cmp(a.expected, b.expected)
  of rsPresent: cmp(a.present, b.present)
  of rsMissing: cmp(a.missing, b.missing)
  of rsDuplicates: cmp(a.duplicates, b.duplicates)
  of rsUnlisted: cmp(a.unlisted, b.unlisted)

func cmpPoint(a, b: PointRow; column: PointSortColumn): int =
  case column
  of psNever: cmp(a.never, b.never)
  of psMissingIn: cmp(a.missingIn, b.missingIn)
  of psExpectedIn: cmp(a.expectedIn, b.expectedIn)
  of psLine: cmpNum(a.line, b.line)
  of psPoint: cmpNum(a.point, b.point)
  of psIndex: cmp(a.index, b.index)
  of psFirstFile: cmp(a.firstFile, b.firstFile)
  of psFirstRecord: cmpNum(a.firstRecord, b.firstRecord)
  of psLastFile: cmp(a.lastFile, b.lastFile)
  of psLastRecord: cmpNum(a.lastRecord, b.lastRecord)

proc reorder[T](rows: seq[T]; order: openArray[int]): seq[T] =
  result.setLen(rows.len)
  for i, src in order:
    result[i] = rows[src]

proc sortBy[T, C](rows: var seq[T]; by: SortSpec[C];
    cmpCol: proc (a, b: T; column: C): int) =
  if rows.len < 2 or by.len == 0: return
  let view = rows
  var order = newSeq[int](view.len)
  for i in 0 ..< order.len: order[i] = i
  order.sort proc (a, b: int): int =
    for spec in by:
      let c = cmpCol(view[a], view[b], spec.column)
      if c != 0: return if spec.descending: -c else: c
    cmp(a, b)
  rows = reorder(view, order)

proc sortRecords*(rows: var seq[RecordRow]; by: SortSpec[RecordSortColumn]) =
  ## Sorts `rows` by `by`. A tie, including a tie on every column, keeps the
  ## rows in the order they had. Numbers sort as numbers.
  sortBy(rows, by, cmpRecord)

proc sortPoints*(rows: var seq[PointRow]; by: SortSpec[PointSortColumn]) =
  ## Sorts `rows` by `by`, as `sortRecords` does.
  sortBy(rows, by, cmpPoint)

type
  Acc = object
    expectedIn, missingIn: int
    expectedAt, missingAt: int
    firstFile, lastFile: string
    firstRecord, lastRecord: float64
    haveMissing: bool

func blank(): Acc =
  Acc(expectedAt: -1, missingAt: -1)

proc noteExpected(acc: var Table[StationKey, Acc]; st: StationKey; ordinal: int) =
  acc.withValue(st, e):
    if e.expectedAt != ordinal:
      e.expectedAt = ordinal
      inc e.expectedIn
    return
  var fresh = blank()
  fresh.expectedAt = ordinal
  fresh.expectedIn = 1
  acc[st] = fresh

proc noteMissing(acc: var Table[StationKey, Acc]; st: StationKey; ordinal: int;
    file: string; record: float64) =
  acc.withValue(st, e):
    if e.missingAt != ordinal:
      e.missingAt = ordinal
      inc e.missingIn
      if not e.haveMissing:
        e.haveMissing = true
        e.firstFile = file
        e.firstRecord = record
      e.lastFile = file
      e.lastRecord = record
    return
  var fresh = blank()
  fresh.missingAt = ordinal
  fresh.missingIn = 1
  fresh.haveMissing = true
  fresh.firstFile = file
  fresh.firstRecord = record
  fresh.lastFile = file
  fresh.lastRecord = record
  acc[st] = fresh

proc lightOf(c: RecordCompleteness): RecordCompleteness =
  ## The fields `summarize` reads, without the station lists.
  RecordCompleteness(fieldRecord: c.fieldRecord, xpsRecord: c.xpsRecord,
    candidates: c.candidates, recordMismatch: c.recordMismatch,
    sourceMismatch: c.sourceMismatch, expected: c.expected, present: c.present,
    presentLive: c.presentLive, missing: c.missing, unlisted: c.unlisted,
    duplicates: c.duplicates)

proc missingReport*(files: openArray[FileRecords]; survey: SurveyGeometry): MissingReport =
  ## The report of `files` against `survey`. Record rows follow
  ## `DefaultRecordSort`; point rows follow `DefaultPointSort` (`never`
  ## first). An empty `survey` still reports every station a record lists
  ## as missing; each of those then counts as expected only where it is
  ## missing, so `never` is true.
  result.duplicatesNote = DuplicatesNote
  var nRecords = 0
  var nPoints = 0
  for f in files:
    nRecords += f.records.len
    for c in f.records:
      nPoints += c.missingStations.len
  result.records.setLen(nRecords)
  result.recordPoints.setLen(nPoints)
  var ri = 0
  var pi = 0
  var acc = initTable[StationKey, Acc]()
  var light = newSeqOfCap[RecordCompleteness](nRecords)
  var ordinal = 0
  for f in files:
    for c in f.records:
      result.records[ri] = RecordRow(file: f.path, record: c.fieldRecord,
        expected: c.expected, present: c.present, missing: c.missing,
        duplicates: c.duplicates, unlisted: c.unlisted,
        missingPoints: rangesText(c.missingRanges))
      inc ri
      if c.duplicates > 0:
        result.duplicates.add DuplicateRow(file: f.path, record: c.fieldRecord,
          count: c.duplicates)
      if c.xpsRecord >= 0:
        for run in survey.relationRuns(c.xpsRecord):
          for i in 0 ..< run.stations:
            noteExpected(acc, run.station(i), ordinal)
      for st in c.missingStations:
        noteMissing(acc, st, ordinal, f.path, c.fieldRecord)
        noteExpected(acc, st, ordinal)
        result.recordPoints[pi] = RecordPointRow(file: f.path, record: c.fieldRecord,
          line: st.line, point: st.point, index: st.index)
        inc pi
      light.add lightOf(c)
      inc ordinal
  for st, e in acc:
    if e.missingIn > 0:
      result.points.add PointRow(line: st.line, point: st.point, index: st.index,
        expectedIn: e.expectedIn, missingIn: e.missingIn,
        never: e.missingIn == e.expectedIn, firstFile: e.firstFile,
        lastFile: e.lastFile, firstRecord: e.firstRecord, lastRecord: e.lastRecord)
  sortRecords(result.records, DefaultRecordSort)
  sortPoints(result.points, DefaultPointSort)
  let summary = summarize(survey, light)
  let percent = if summary.expected == 0: 0.0
    else: 100.0 * float64(summary.missing) / float64(summary.expected)
  var never = 0
  for p in result.points:
    if p.never: inc never
  result.totals = Totals(files: files.len, records: summary.records,
    expected: summary.expected, present: summary.present, missing: summary.missing,
    never: never, duplicates: summary.duplicates, extras: summary.unlisted,
    xpsWithoutData: summary.xpsWithoutData, percentMissing: percent)

proc recordsCsv*(rows: openArray[RecordRow]): string =
  ## A header and one line per row. Fields are quoted per RFC 4180.
  result = csvLine("file", "record", "expected", "present", "missing", "duplicates",
    "unlisted", "missingPoints")
  for r in rows:
    result.add csvLine(r.file, stationNumber(r.record), $r.expected, $r.present,
      $r.missing, $r.duplicates, $r.unlisted, r.missingPoints)

proc recordPointsCsv*(rows: openArray[RecordPointRow]): string =
  ## A header and one line per missing station of a record.
  result = csvLine("file", "record", "line", "point", "index")
  for r in rows:
    result.add csvLine(r.file, stationNumber(r.record), stationNumber(r.line),
      stationNumber(r.point), $r.index)

proc pointsCsv*(rows: openArray[PointRow]): string =
  ## A header and one line per station missing in the folder.
  result = csvLine("line", "point", "index", "expectedIn", "missingIn", "never",
    "firstFile", "firstRecord", "lastFile", "lastRecord")
  for r in rows:
    result.add csvLine(stationNumber(r.line), stationNumber(r.point), $r.index,
      $r.expectedIn, $r.missingIn, $r.never, r.firstFile, stationNumber(r.firstRecord),
      r.lastFile, stationNumber(r.lastRecord))

proc totalsCsv*(t: Totals; duplicatesNote = DuplicatesNote): string =
  ## One header and one totals line. `xpsWithoutData` is the survey record
  ## numbers, separated by spaces. `duplicatesNote` says why duplicates are
  ## a count only.
  result = csvLine("files", "records", "expected", "present", "missing", "never",
    "duplicates", "extras", "xpsWithoutData", "percentMissing", "duplicatesNote")
  var ids = ""
  for i, id in t.xpsWithoutData:
    if i > 0: ids.add ' '
    ids.add $id
  result.add csvLine($t.files, $t.records, $t.expected, $t.present, $t.missing,
    $t.never, $t.duplicates, $t.extras, ids, percentText(t.percentMissing),
    duplicatesNote)
