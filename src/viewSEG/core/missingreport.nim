## The missing-station report: the stations the survey's relation records call
## for that a seismic file does not hold, counted per station and per record.
##
## A shot gather is checked against the X record of its shot: the receiver
## stations it expects. A receiver gather is checked against the O record of
## its receiver: the source stations it expects (`ssSources`). A `StationTally`
## takes one record at a time (`addGather`), so a folder of files never holds
## more than one line and point per station, and `report` turns it into the
## rows (line, point, and in how many records it is missing) and the figures.
##
## Counts are of stations (a line and point), not traces or channels: the
## components of one station count once, and a station is present when any
## trace of it is in the record, whatever its number of components. This holds
## when the traces were matched by channel too, where the library reports one
## entry for each channel: a station is missing only when all its entries are.
##
## This module does not read files, start jobs or keep state.

import std/[algorithm, math, sets, strutils, tables]
import parseSEG
import processSEG/qc/record
from records import stationNumber

type
  StationSide* = enum
    ssReceivers ## shot gathers: the receiver stations of each X record
    ssSources   ## receiver gathers: the source stations of each O record

  StationRow* = object
    ## A station some record lacks.
    line*, point*: float64
    missing*: int ## records whose template calls for it and that do not hold it

  MissingStats* = object
    ## The figures of one side. `inTemplate`, `found` and `missing` count
    ## distinct stations (line and point); the `Records` figures count a
    ## station once for each record that calls for it.
    side*: StationSide
    derived*: bool ## receiver side: the O records were derived from the X records
    files*, records*: int
    inTemplate*: int ## distinct stations the template calls for
    found*: int ## of those, stations that at least one record holds
    missing*: int ## distinct stations that at least one record lacks
    percentMissing*: float64 ## `100 * missing / inTemplate`, 0 when nothing is expected
    expectedInRecords*, presentInRecords*, missingInRecords*: int
    percentMissingInRecords*: float64

  StationReport* = object
    rows*: seq[StationRow]
    stats*: MissingStats

  StationSortColumn* = enum
    ## A column of `StationRow`.
    scLine, scPoint, scMissing

  SortSpec*[C] = seq[tuple[column: C, descending: bool]]
    ## Sort keys, first one most significant. A tie keeps the rows' order.

  PointKey = tuple[line, point: float64]

  StationCell = object
    found: bool
    missingIn: int

  StationTally* = object
    ## Records added so far. Build with `initTally`.
    side*: StationSide
    derived*: bool
    files, records: int
    expected, present, missing: int
    cells: Table[PointKey, StationCell]

const
  DefaultStationSort*: SortSpec[StationSortColumn] = @[
    (column: scLine, descending: false), (column: scPoint, descending: false)]

func initTally*(side: StationSide; derived = false): StationTally =
  ## An empty tally. `derived` marks O records derived from the X records.
  StationTally(side: side, derived: derived, cells: initTable[PointKey, StationCell]())

proc noteFile*(t: var StationTally) =
  ## One more file has at least one record in the tally.
  inc t.files

proc addGather*(t: var StationTally; calls: openArray[StationKey];
    c: RecordCompleteness) =
  ## Adds one record: `calls` are the entries its relation record calls for (a
  ## station, or a channel when the traces were matched by channel), `c` its
  ## completeness against them (`missingStations` are the entries the record
  ## lacks). The figures are of stations, by line and point: a station is
  ## missing from the record only when all its entries are, so a station that
  ## lacks one component of several, or one of two indices, is found.
  inc t.records
  let byChannel = c.traceMatch == tmChannel
  var entries = initTable[PointKey, int]()
  var counted = initHashSet[StationKey]()
  for st in calls:
    if byChannel or not counted.containsOrIncl(st):
      inc entries.mgetOrPut((line: st.line, point: st.point), 0)
  var lacking = initTable[PointKey, int]()
  for st in c.missingStations: inc lacking.mgetOrPut((line: st.line, point: st.point), 0)
  for key, n in entries:
    let lost = lacking.getOrDefault(key) >= n
    inc t.expected
    if lost: inc t.missing
    else: inc t.present
    t.cells.withValue(key, cell):
      if lost: inc cell[].missingIn
      else: cell[].found = true
    do:
      t.cells[key] = StationCell(found: not lost, missingIn: ord(lost))

func percentOf(part, whole: int): float64 =
  if whole <= 0: 0.0 else: 100.0 * float64(part) / float64(whole)

func cmpNum(a, b: float64): int =
  ## Numeric order; NaN sorts after every number.
  let an = a != a
  let bn = b != b
  if an and bn: 0
  elif an: 1
  elif bn: -1
  else: cmp(a, b)

func cmpRow(a, b: StationRow; column: StationSortColumn): int =
  case column
  of scLine: cmpNum(a.line, b.line)
  of scPoint: cmpNum(a.point, b.point)
  of scMissing: cmp(a.missing, b.missing)

proc sortStations*(rows: var seq[StationRow]; by: SortSpec[StationSortColumn]) =
  ## Sorts `rows` by `by`. A tie, including a tie on every column, keeps the
  ## rows in the order they had. Numbers sort as numbers.
  if rows.len < 2 or by.len == 0: return
  let view = rows
  var order = newSeq[int](view.len)
  for i in 0 ..< order.len: order[i] = i
  order.sort proc (a, b: int): int =
    for spec in by:
      let c = cmpRow(view[a], view[b], spec.column)
      if c != 0: return if spec.descending: -c else: c
    cmp(a, b)
  for i, src in order: rows[i] = view[src]

proc report*(t: StationTally): StationReport =
  ## The rows (every station some record lacks, by line then point) and the
  ## figures of `t`.
  var found = 0
  for key, cell in t.cells:
    if cell.found: inc found
    if cell.missingIn > 0:
      result.rows.add StationRow(line: key.line, point: key.point, missing: cell.missingIn)
  sortStations(result.rows, DefaultStationSort)
  result.stats = MissingStats(side: t.side, derived: t.derived, files: t.files,
    records: t.records, inTemplate: t.cells.len, found: found, missing: result.rows.len,
    percentMissing: percentOf(result.rows.len, t.cells.len),
    expectedInRecords: t.expected, presentInRecords: t.present,
    missingInRecords: t.missing,
    percentMissingInRecords: percentOf(t.missing, t.expected))

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

func percentText*(x: float64): string =
  ## `x` with no fraction when it is a whole number, otherwise two places.
  if x == round(x) and abs(x) < 1e15: $int64(x) else: formatFloat(x, ffDecimal, 2)

proc stationsCsv*(rows: openArray[StationRow]; side = ssReceivers): string =
  ## A header and one line per station: line, point, missing. The header names the
  ## stations: the receivers missing from shot gathers or the sources (shots) missing
  ## from receiver gathers.
  result =
    if side == ssReceivers: csvLine("receiverLine", "receiverPoint", "missing")
    else: csvLine("sourceLine", "sourcePoint", "missing")
  for r in rows:
    result.add csvLine(stationNumber(r.line), stationNumber(r.point), $r.missing)

proc statsCsv*(s: MissingStats; filter = ""): string =
  ## One header and one line of figures. `filter` is the text that narrowed the
  ## rows exported beside it ("" for none); the figures are always of the whole
  ## result.
  result = csvLine("stations", "files", "records", "inTemplate", "found", "missing",
    "percentMissing", "expectedInRecords", "presentInRecords", "missingInRecords",
    "percentMissingInRecords", "filter")
  result.add csvLine(if s.side == ssReceivers: "receivers" else: "sources", $s.files,
    $s.records, $s.inTemplate, $s.found, $s.missing, percentText(s.percentMissing),
    $s.expectedInRecords, $s.presentInRecords, $s.missingInRecords,
    percentText(s.percentMissingInRecords), filter)
