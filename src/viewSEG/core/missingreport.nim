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
## relation runs list the station, plus a missing station those runs left
## out. A record with no spread is not evidence the station was expected:
## `expectedUnknown` is set and `never` stays false. `never` means a known
## expected set and no trace in any record that expected it.

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
    expectedIn*: int              ## Records whose spread expected it.
    missingIn*: int               ## Records where it produced no trace.
    never*: bool                  ## Known expected set, and missing in every one of those records.
    expectedUnknown*: bool        ## Missing with no spread: not evidence it was expected.
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
    firstFile, lastFile: int
    firstRecord, lastRecord: float64
    haveMissing, expectedUnknown: bool

  IndexAcc = object
    index: int16
    acc: Acc

  PointCell = object
    point: float64
    live: bool
    head: IndexAcc
    extra: seq[IndexAcc]

  LineSlots = object
    line: float64
    origin: int64
    cells: seq[PointCell]
    touched: seq[int64]
    useExtra: bool
    extra: Table[StationKey, Acc]

  Store = object
    lines: Table[int64, int]
    lineSlots: seq[LineSlots]
    lastIdx: int
    lastLineKey: int64
    lastLine: float64
    odd: Table[StationKey, Acc]

const
  MaxSpan = 100_000
  FracBias = 1'i64 shl 42

func blank(): Acc =
  Acc(expectedAt: -1, missingAt: -1, firstFile: -1, lastFile: -1)

func isNever(e: Acc): bool =
  e.expectedIn > 0 and e.missingIn == e.expectedIn and not e.expectedUnknown

func denseKey(x: float64): tuple[ok: bool, key: int64] =
  ## An int key for a station number that round-trips, or not ok. Whole
  ## numbers stay whole; fractions use a centi key below `FracBias`, so the
  ## two never share a slot. NaN and values that do not round-trip are not ok.
  if x != x or abs(x) >= 1e15: return (false, 0)
  if x == round(x): return (true, int64(x))
  let c = int64(round(x * 100.0))
  if float64(c) / 100.0 == x: return (true, c - FracBias)
  (false, 0)

template bump(e: var Acc; ordinal, file: int; record: float64;
    expect, missing, unknown: bool) =
  if expect and e.expectedAt != ordinal:
    e.expectedAt = ordinal
    inc e.expectedIn
  if missing and e.missingAt != ordinal:
    e.missingAt = ordinal
    inc e.missingIn
    if not e.haveMissing:
      e.haveMissing = true
      e.firstFile = file
      e.firstRecord = record
    e.lastFile = file
    e.lastRecord = record
  if unknown: e.expectedUnknown = true

proc noteTable(acc: var Table[StationKey, Acc]; st: StationKey; ordinal, file: int;
    record: float64; expect, missing, unknown: bool) =
  acc.withValue(st, e):
    bump(e[], ordinal, file, record, expect, missing, unknown)
    return
  var fresh = blank()
  bump(fresh, ordinal, file, record, expect, missing, unknown)
  acc[st] = fresh

proc spill(store: var Store; li: int) =
  ## Moves a line's array into its table when the point span is too wide.
  if store.lineSlots[li].useExtra: return
  store.lineSlots[li].useExtra = true
  let lineF = store.lineSlots[li].line
  let origin = store.lineSlots[li].origin
  for key in store.lineSlots[li].touched:
    let cell = store.lineSlots[li].cells[int(key - origin)]
    if cell.live:
      var st = StationKey(line: lineF, point: cell.point, index: cell.head.index)
      store.lineSlots[li].extra[st] = cell.head.acc
      for ex in cell.extra:
        st.index = ex.index
        store.lineSlots[li].extra[st] = ex.acc
  store.lineSlots[li].cells.setLen(0)
  store.lineSlots[li].touched.setLen(0)

proc lineIndex(store: var Store; key: int64; line: float64): int {.inline.} =
  if store.lastIdx >= 0 and store.lastLineKey == key:
    return store.lastIdx
  store.lines.withValue(key, i):
    store.lastIdx = i[]
    store.lastLineKey = key
    store.lastLine = store.lineSlots[i[]].line
    return i[]
  result = store.lineSlots.len
  store.lineSlots.add LineSlots(line: line, extra: initTable[StationKey, Acc]())
  store.lines[key] = result
  store.lastIdx = result
  store.lastLineKey = key
  store.lastLine = line

proc ensureCell(store: var Store; li: int; key: int64): int =
  ## Index of `key` in the line's cells, or -1 when the line uses a table.
  if store.lineSlots[li].useExtra: return -1
  let n = store.lineSlots[li].cells.len
  if n == 0:
    store.lineSlots[li].origin = key
    store.lineSlots[li].cells.setLen(1)
    store.lineSlots[li].touched.add key
    return 0
  let origin = store.lineSlots[li].origin
  let i64 = key - origin
  if i64 >= 0 and i64 < n:
    if not store.lineSlots[li].cells[int(i64)].live:
      store.lineSlots[li].touched.add key
    return int(i64)
  let newLen = if i64 >= 0: i64 + 1 else: origin - key + int64(n)
  if newLen <= 0 or newLen > MaxSpan:
    store.spill(li)
    return -1
  if i64 >= n:
    store.lineSlots[li].cells.setLen(int(newLen))
    store.lineSlots[li].touched.add key
    return int(i64)
  let shift = int(origin - key)
  var grown = newSeq[PointCell](int(newLen))
  for j, c in store.lineSlots[li].cells:
    grown[j + shift] = c
  store.lineSlots[li].cells = grown
  store.lineSlots[li].origin = key
  store.lineSlots[li].touched.add key
  0

proc applyCell(cell: var PointCell; point: float64; index: int16; ordinal, file: int;
    record: float64; expect, missing, unknown: bool) {.inline.} =
  if not cell.live:
    cell.live = true
    cell.point = point
    cell.head = IndexAcc(index: index, acc: blank())
    bump(cell.head.acc, ordinal, file, record, expect, missing, unknown)
    return
  if cell.head.index == index:
    bump(cell.head.acc, ordinal, file, record, expect, missing, unknown)
    return
  for i in 0 ..< cell.extra.len:
    if cell.extra[i].index == index:
      bump(cell.extra[i].acc, ordinal, file, record, expect, missing, unknown)
      return
  var fresh = IndexAcc(index: index, acc: blank())
  bump(fresh.acc, ordinal, file, record, expect, missing, unknown)
  cell.extra.add fresh

template note(store: var Store; st: StationKey; ordinal, file: int; record: float64;
    expect, missing, unknown: bool) =
  ## One expected or missing visit. Inlined so a repeated whole-number point
  ## on the current line is an array bump, not a float hash or a call.
  block noteStation:
    if store.lastIdx >= 0 and st.line == store.lastLine:
      let point = st.point
      if point == point and abs(point) < 1e15:
        let key = int64(point)
        if float64(key) == point:
          let li = store.lastIdx
          if not store.lineSlots[li].useExtra:
            let i64 = key - store.lineSlots[li].origin
            let n = int64(store.lineSlots[li].cells.len)
            if i64 >= 0 and i64 < n:
              let ci = int(i64)
              if store.lineSlots[li].cells[ci].live and
                  store.lineSlots[li].cells[ci].head.index == st.index:
                bump(store.lineSlots[li].cells[ci].head.acc, ordinal, file, record,
                  expect, missing, unknown)
              else:
                if not store.lineSlots[li].cells[ci].live:
                  store.lineSlots[li].touched.add key
                applyCell(store.lineSlots[li].cells[ci], point, st.index, ordinal, file,
                  record, expect, missing, unknown)
              break noteStation
    let lk = denseKey(st.line)
    let pk = denseKey(st.point)
    if not lk.ok or not pk.ok:
      noteTable(store.odd, st, ordinal, file, record, expect, missing, unknown)
      break noteStation
    let li = store.lineIndex(lk.key, st.line)
    if store.lineSlots[li].useExtra:
      noteTable(store.lineSlots[li].extra, st, ordinal, file, record, expect, missing,
        unknown)
      break noteStation
    let ci = store.ensureCell(li, pk.key)
    if ci < 0:
      noteTable(store.lineSlots[li].extra, st, ordinal, file, record, expect, missing,
        unknown)
      break noteStation
    applyCell(store.lineSlots[li].cells[ci], st.point, st.index, ordinal, file, record,
      expect, missing, unknown)

proc reserve(store: var Store; stations: openArray[StationKey]) =
  ## Sizes the first line's array from `stations` when they share one modest span.
  if stations.len == 0 or store.lineSlots.len > 0: return
  var lineKey, lo, hi: int64
  var line = 0.0
  var have = false
  for st in stations:
    let lk = denseKey(st.line)
    let pk = denseKey(st.point)
    if not lk.ok or not pk.ok: return
    if not have:
      have = true
      lineKey = lk.key
      line = st.line
      lo = pk.key
      hi = pk.key
    elif lk.key != lineKey:
      return
    else:
      if pk.key < lo: lo = pk.key
      if pk.key > hi: hi = pk.key
  let span = hi - lo + 1
  if span <= 0 or span > MaxSpan: return
  store.lineSlots.add LineSlots(line: line, origin: lo,
    cells: newSeq[PointCell](int(span)), extra: initTable[StationKey, Acc]())
  store.lines[lineKey] = 0
  store.lastIdx = 0
  store.lastLineKey = lineKey
  store.lastLine = line

proc addPoint(points: var seq[PointRow]; paths: openArray[string]; line, point: float64;
    index: int16; e: Acc) =
  if e.missingIn <= 0: return
  let first = if e.firstFile >= 0: paths[e.firstFile] else: ""
  let last = if e.lastFile >= 0: paths[e.lastFile] else: ""
  points.add PointRow(line: line, point: point, index: index, expectedIn: e.expectedIn,
    missingIn: e.missingIn, never: isNever(e), expectedUnknown: e.expectedUnknown,
    firstFile: first, lastFile: last, firstRecord: e.firstRecord, lastRecord: e.lastRecord)

proc emitPoints(points: var seq[PointRow]; paths: openArray[string]; store: Store) =
  for line in store.lineSlots:
    if not line.useExtra:
      for key in line.touched:
        let cell = line.cells[int(key - line.origin)]
        if cell.live:
          addPoint(points, paths, line.line, cell.point, cell.head.index, cell.head.acc)
          for ex in cell.extra:
            addPoint(points, paths, line.line, cell.point, ex.index, ex.acc)
    for st, e in line.extra:
      addPoint(points, paths, st.line, st.point, st.index, e)
  for st, e in store.odd:
    addPoint(points, paths, st.line, st.point, st.index, e)

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
  ## as missing, with `expectedUnknown` set and `never` false: a missing
  ## list alone is not evidence the station was expected.
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
  var paths = newSeq[string](files.len)
  for i, f in files: paths[i] = f.path
  var store = Store(lastIdx: -1, lines: initTable[int64, int](),
    odd: initTable[StationKey, Acc]())
  var reserved = false
  var light = newSeqOfCap[RecordCompleteness](nRecords)
  var ordinal = 0
  for fi, f in files:
    for c in f.records:
      result.records[ri] = RecordRow(file: f.path, record: c.fieldRecord,
        expected: c.expected, present: c.present, missing: c.missing,
        duplicates: c.duplicates, unlisted: c.unlisted,
        missingPoints: rangesText(c.missingRanges))
      inc ri
      if c.duplicates > 0:
        result.duplicates.add DuplicateRow(file: f.path, record: c.fieldRecord,
          count: c.duplicates)
      if not reserved and c.missingStations.len > 0:
        reserved = true
        store.reserve(c.missingStations)
      var spread = false
      if c.xpsRecord >= 0:
        for run in survey.relationRuns(c.xpsRecord):
          spread = true
          for i in 0 ..< run.stations:
            note(store, run.station(i), ordinal, fi, c.fieldRecord, true, false, false)
      for st in c.missingStations:
        note(store, st, ordinal, fi, c.fieldRecord, false, true, not spread)
        if spread:
          note(store, st, ordinal, fi, c.fieldRecord, true, false, false)
        result.recordPoints[pi] = RecordPointRow(file: f.path, record: c.fieldRecord,
          line: st.line, point: st.point, index: st.index)
        inc pi
      light.add lightOf(c)
      inc ordinal
  emitPoints(result.points, paths, store)
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
    "expectedUnknown", "firstFile", "firstRecord", "lastFile", "lastRecord")
  for r in rows:
    result.add csvLine(stationNumber(r.line), stationNumber(r.point), $r.index,
      $r.expectedIn, $r.missingIn, $r.never, $r.expectedUnknown, r.firstFile,
      stationNumber(r.firstRecord), r.lastFile, stationNumber(r.lastRecord))

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
