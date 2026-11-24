## Trace-quality tables: one row per receiver station and component, one row
## per file and record, and the totals, sorted and written as CSV.
##
## A scan hands in one `TraceNote` per seismic trace (`addTrace`). This
## module does not read files, start jobs or keep state of its own: the
## notes live in a `QualityBuild` the caller owns. An auxiliary trace is
## not a note. A killed trace counts as killed, not as bad, and its
## findings are ignored. Header-dead is its own finding (`findingsOf`);
## it is not also all-zero. Weak and noisy are not findings: the scan
## judges them a field record at a time (the map's test) and hands in what it
## found per trace (`tested`, `noisy`, `weak`); they are counted apart from
## `bad`, and a count is shown only where some trace was tested.
##
## A station is the receiver (line, point, index) and its component.
## Components are never compared across stations: each row counts only
## its own traces. Line and point are rounded to 1/100, and a non-finite
## line or point shares one unknown station per index and component. A
## record is the file path as the caller named it and the header record
## number; a non-finite number shares one row per file. The records a
## station was bad in are compact ranges, one line of text per file.
## Unread files are not a total here.

import std/[algorithm, hashes, math, sets, strutils, tables]
import processSEG/qc/amplitude
from records import stationNumber

type
  Finding* = enum
    ## A trace-quality finding. Weak and noisy are not among them.
    qfHeaderDead = "header-dead" ## `TraceKeys.status == tsDead`.
    qfAllZero = "all-zero"       ## `afDead`: every finite sample is 0.
    qfConstant = "constant"      ## `afConstant`.
    qfClipped = "clipped"        ## `afClipped`.
    qfSpiky = "spiky"            ## `afSpiky`.
    qfDcOffset = "dc offset"     ## `afDcOffset`.
    qfNonFinite = "non-finite"   ## `afNonFinite`.

  TraceNote* = object
    ## One seismic trace. `file` is the path the caller named.
    file*: string
    record*: float64       ## Header record number; NaN when the file has none.
    line*, point*: float64 ## Receiver station; NaN when the headers name none.
    index*: int16
    component*: uint8
    killed*: bool          ## A per-file edit killed it: counted as killed, not bad.
    findings*: set[Finding]
    tested*: bool          ## The noisy and weak test ran on its record and judged this trace.
    noisy*, weak*: bool    ## Only meaningful when `tested`.

  StationRow* = object
    ## One receiver station and component, over every file of the scan.
    line*, point*: float64
    index*: int16
    component*: uint8
    seen*, killed*, bad*: int   ## `seen` includes killed. `bad` does not.
    counts*: array[Finding, int]
    tested*, noisy*, weak*: int ## `tested` traces; the cells show nothing when it is 0.
    badRecords*: string         ## Compact ranges, one line per file the station was bad in.

  RecordRow* = object
    ## One field record of one file.
    file*: string
    record*: float64
    seen*, killed*, bad*: int
    counts*: array[Finding, int]
    tested*, noisy*, weak*: int ## As in `StationRow`.

  Totals* = object
    ## Scan totals over the notes. Unread files are not counted.
    files*, records*, traces*, killed*, bad*, stations*: int
    counts*: array[Finding, int]
    tested*, noisy*, weak*: int ## As in `StationRow`.

  QualityReport* = object
    stations*: seq[StationRow]
    records*: seq[RecordRow]
    totals*: Totals

  StationSortColumn* = enum
    ## A column of `StationRow`.
    ssLine, ssPoint, ssIndex, ssComponent, ssSeen, ssKilled, ssBad,
    ssHeaderDead, ssAllZero, ssConstant, ssClipped, ssSpiky, ssDcOffset,
    ssNonFinite, ssNoisy, ssWeak, ssBadRecords

  RecordSortColumn* = enum
    ## A column of `RecordRow`.
    rsFile, rsRecord, rsSeen, rsKilled, rsBad, rsHeaderDead, rsAllZero,
    rsConstant, rsClipped, rsSpiky, rsDcOffset, rsNonFinite, rsNoisy, rsWeak

  SortSpec*[C] = seq[tuple[column: C, descending: bool]]
    ## Sort keys, first one most significant. A tie keeps the rows' order.

const
  DefaultStationSort*: SortSpec[StationSortColumn] = @[
    (column: ssLine, descending: false), (column: ssPoint, descending: false),
    (column: ssIndex, descending: false), (column: ssComponent, descending: false)]
  DefaultRecordSort*: SortSpec[RecordSortColumn] = @[
    (column: rsFile, descending: false), (column: rsRecord, descending: false)]

func findingsOf*(flags: set[AmplitudeFlag]; headerDead: bool): set[Finding] =
  ## The findings of one trace. Header-dead is only that finding: amplitude
  ## flags, including all-zero, are not added. `afWeak` and `afNoisy` are
  ## dropped. Any other flag maps to its finding.
  if headerDead: return {qfHeaderDead}
  if afDead in flags: result.incl qfAllZero
  if afConstant in flags: result.incl qfConstant
  if afClipped in flags: result.incl qfClipped
  if afSpiky in flags: result.incl qfSpiky
  if afDcOffset in flags: result.incl qfDcOffset
  if afNonFinite in flags: result.incl qfNonFinite

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

func noiseCell*(tested, n: int): string =
  ## A count, or "" when no trace was tested.
  if tested > 0: $n else: ""

func csvLine(fields: varargs[string]): string =
  for i, f in fields:
    if i > 0: result.add ','
    result.add csvField(f)
  result.add '\n'

func cmpNum(a, b: float64): int =
  ## Numeric order; NaN sorts after every number.
  let an = a != a
  let bn = b != b
  if an and bn: 0
  elif an: 1
  elif bn: -1
  else: cmp(a, b)

func kindColumn(column: StationSortColumn): Finding =
  case column
  of ssHeaderDead: qfHeaderDead
  of ssAllZero: qfAllZero
  of ssConstant: qfConstant
  of ssClipped: qfClipped
  of ssSpiky: qfSpiky
  of ssDcOffset: qfDcOffset
  of ssNonFinite: qfNonFinite
  else: qfHeaderDead

func recordKind(column: RecordSortColumn): Finding =
  case column
  of rsHeaderDead: qfHeaderDead
  of rsAllZero: qfAllZero
  of rsConstant: qfConstant
  of rsClipped: qfClipped
  of rsSpiky: qfSpiky
  of rsDcOffset: qfDcOffset
  of rsNonFinite: qfNonFinite
  else: qfHeaderDead

func known(tested, n: int): int =
  ## The count to sort by: rows with nothing tested come before every count.
  if tested > 0: n else: -1

func cmpStation(a, b: StationRow; column: StationSortColumn): int =
  case column
  of ssLine: cmpNum(a.line, b.line)
  of ssPoint: cmpNum(a.point, b.point)
  of ssIndex: cmp(a.index, b.index)
  of ssComponent: cmp(a.component, b.component)
  of ssSeen: cmp(a.seen, b.seen)
  of ssKilled: cmp(a.killed, b.killed)
  of ssBad: cmp(a.bad, b.bad)
  of ssBadRecords: cmp(a.badRecords, b.badRecords)
  of ssNoisy: cmp(known(a.tested, a.noisy), known(b.tested, b.noisy))
  of ssWeak: cmp(known(a.tested, a.weak), known(b.tested, b.weak))
  of ssHeaderDead, ssAllZero, ssConstant, ssClipped, ssSpiky, ssDcOffset, ssNonFinite:
    cmp(a.counts[kindColumn(column)], b.counts[kindColumn(column)])

func cmpRecord(a, b: RecordRow; column: RecordSortColumn): int =
  case column
  of rsFile: cmp(a.file, b.file)
  of rsRecord: cmpNum(a.record, b.record)
  of rsSeen: cmp(a.seen, b.seen)
  of rsKilled: cmp(a.killed, b.killed)
  of rsBad: cmp(a.bad, b.bad)
  of rsNoisy: cmp(known(a.tested, a.noisy), known(b.tested, b.noisy))
  of rsWeak: cmp(known(a.tested, a.weak), known(b.tested, b.weak))
  of rsHeaderDead, rsAllZero, rsConstant, rsClipped, rsSpiky, rsDcOffset, rsNonFinite:
    cmp(a.counts[recordKind(column)], b.counts[recordKind(column)])

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

proc sortStations*(rows: var seq[StationRow]; by: SortSpec[StationSortColumn]) =
  ## Sorts `rows` by `by`. A tie, including a tie on every column, keeps the
  ## rows in the order they had. A NaN line, point or record sorts after
  ## every number.
  sortBy(rows, by, cmpStation)

proc sortRecords*(rows: var seq[RecordRow]; by: SortSpec[RecordSortColumn]) =
  ## Sorts `rows` by `by`, as `sortStations` does.
  sortBy(rows, by, cmpRecord)

func holds(text, word: string): bool =
  if word.len == 0: return true
  if text.len < word.len: return false
  for i in 0 .. text.len - word.len:
    var j = 0
    while j < word.len and text[i + j].toLowerAscii == word[j]: inc j
    if j == word.len: return true
  false

func matchesAll(text, filter: string): bool =
  for word in filter.toLowerAscii.splitWhitespace:
    if not text.holds(word): return false
  true

func stationText(r: StationRow): string =
  stationNumber(r.line) & " " & stationNumber(r.point) & " " & $r.index & " " &
    $r.component & " " & r.badRecords

func recordText(r: RecordRow): string =
  r.file & " " & stationNumber(r.record)

func filterStations*(rows: openArray[StationRow]; filter: string): seq[int] =
  ## Indices of the rows whose line, point, index, component or bad-record
  ## text holds every word of `filter`, in any case. An empty filter, or
  ## one of only spaces, is every row.
  for i, r in rows:
    if matchesAll(stationText(r), filter): result.add i

func filterRecords*(rows: openArray[RecordRow]; filter: string): seq[int] =
  ## Indices of the rows whose file or record number holds every word of
  ## `filter`, in any case. An empty filter is every row.
  for i, r in rows:
    if matchesAll(recordText(r), filter): result.add i

type
  StKey = object
    lineKnown, pointKnown: bool
    lineH, pointH: int64
    index: int16
    component: uint8

  RecKey = object
    file: int
    finite: bool
    record: float64

  FileBad = object
    wholes: HashSet[int64]
    others: seq[float64]

  StAcc = object
    seen, killed, bad: int
    counts: array[Finding, int]
    tested, noisy, weak: int
    fileOrder: seq[int]
    badFiles: Table[int, FileBad]

  RecAcc = object
    seen, killed, bad: int
    counts: array[Finding, int]
    tested, noisy, weak: int

  QualityBuild* = object
    ## Notes gathered for `qualityReport`. Fields are private: add with
    ## `addTrace`.
    files: seq[string]
    fileIds: Table[string, int]
    stOrder: seq[StKey]
    stations: Table[StKey, StAcc]
    recOrder: seq[RecKey]
    records: Table[RecKey, RecAcc]

func hash(k: StKey): Hash =
  var h = hash(k.lineKnown)
  h = h !& hash(k.pointKnown)
  h = h !& hash(k.lineH)
  h = h !& hash(k.pointH)
  h = h !& hash(k.index)
  h = h !& hash(k.component)
  !$h

func `==`(a, b: StKey): bool =
  a.lineKnown == b.lineKnown and a.pointKnown == b.pointKnown and
    a.lineH == b.lineH and a.pointH == b.pointH and a.index == b.index and
    a.component == b.component

func hash(k: RecKey): Hash =
  var h = hash(k.file)
  h = h !& hash(k.finite)
  if k.finite: h = h !& hash(k.record)
  !$h

func `==`(a, b: RecKey): bool =
  a.file == b.file and a.finite == b.finite and (not a.finite or a.record == b.record)

func hundredths(x: float64): tuple[known: bool; n: int64] =
  if x != x or x == Inf or x == -Inf: return (false, 0)
  let h = round(x * 100.0)
  if h != h or abs(h) > 9.0e18: return (false, 0)
  (true, int64(h))

func stKey(line, point: float64; index: int16; component: uint8): StKey =
  let ln = hundredths(line)
  let pt = hundredths(point)
  StKey(lineKnown: ln.known, pointKnown: pt.known, lineH: ln.n, pointH: pt.n,
    index: index, component: component)

func recKey(file: int; record: float64): RecKey =
  if record == record and record != Inf and record != -Inf:
    RecKey(file: file, finite: true, record: if record == 0: 0.0 else: record)
  else:
    RecKey(file: file, finite: false, record: NaN)

func lineOf(k: StKey): float64 =
  if k.lineKnown: float64(k.lineH) / 100.0 else: NaN

func pointOf(k: StKey): float64 =
  if k.pointKnown: float64(k.pointH) / 100.0 else: NaN

func recordOf(k: RecKey): float64 =
  if k.finite: k.record else: NaN

func sameNum(a, b: float64): bool =
  a == b or (a != a and b != b)

func hasOther(s: openArray[float64]; x: float64): bool =
  for y in s:
    if sameNum(y, x): return true
  false

func wholeId(x: float64): tuple[whole: bool; id: int64] =
  if x == x and abs(x) < 9.0e18 and float64(int64(x)) == x: (true, int64(x))
  else: (false, 0)

proc noteBad(acc: var StAcc; file: int; record: float64) =
  let id = wholeId(record)
  acc.badFiles.withValue(file, cell):
    if id.whole: cell[].wholes.incl id.id
    elif not hasOther(cell[].others, record): cell[].others.add record
    return
  acc.fileOrder.add file
  var fresh = FileBad()
  if id.whole: fresh.wholes.incl id.id
  else: fresh.others.add record
  acc.badFiles[file] = fresh

proc fileId(b: var QualityBuild; file: string): int =
  b.fileIds.withValue(file, id):
    return id[]
  result = b.files.len
  b.files.add file
  b.fileIds[file] = result

proc bump(seen, killed, bad: var int; counts: var array[Finding, int];
    tested, noisy, weak: var int; note: TraceNote) =
  inc seen
  if note.killed:
    inc killed
  else:
    if note.findings != {}:
      inc bad
      for f in note.findings: inc counts[f]
    if note.tested:
      inc tested
      if note.noisy: inc noisy
      if note.weak: inc weak

proc noteStation(b: var QualityBuild; note: TraceNote; fid: int) =
  let sk = stKey(note.line, note.point, note.index, note.component)
  b.stations.withValue(sk, acc):
    bump(acc[].seen, acc[].killed, acc[].bad, acc[].counts, acc[].tested,
      acc[].noisy, acc[].weak, note)
    if not note.killed and note.findings != {}: noteBad(acc[], fid, note.record)
    return
  b.stOrder.add sk
  var acc = StAcc()
  bump(acc.seen, acc.killed, acc.bad, acc.counts, acc.tested, acc.noisy, acc.weak,
    note)
  if not note.killed and note.findings != {}: noteBad(acc, fid, note.record)
  b.stations[sk] = acc

proc noteRecord(b: var QualityBuild; note: TraceNote; fid: int) =
  let rk = recKey(fid, note.record)
  b.records.withValue(rk, acc):
    bump(acc[].seen, acc[].killed, acc[].bad, acc[].counts, acc[].tested,
      acc[].noisy, acc[].weak, note)
    return
  b.recOrder.add rk
  var acc = RecAcc()
  bump(acc.seen, acc.killed, acc.bad, acc.counts, acc.tested, acc.noisy, acc.weak,
    note)
  b.records[rk] = acc

proc addTrace*(b: var QualityBuild; note: TraceNote) =
  ## Counts `note`. A killed trace increments `killed` only, whatever
  ## `findings` holds. A trace with several findings increments each of
  ## those counts and `bad` once. The first note of a station or a record
  ## opens its row, including a clean trace and a killed-only station.
  let fid = b.fileId(note.file)
  b.noteStation(note, fid)
  b.noteRecord(note, fid)

func sortedWholes(s: HashSet[int64]): seq[int64] =
  for id in s: result.add id
  result.sort()

func sortedOthers(s: seq[float64]): seq[float64] =
  result = s
  result.sort(cmpNum)

func joinRanges(ids: seq[int64]): string =
  var i = 0
  var first = true
  while i < ids.len:
    let start = ids[i]
    var last = start
    if start >= 0:
      while i + 1 < ids.len and ids[i + 1] == last + 1:
        inc i
        last = ids[i]
    if not first: result.add ", "
    first = false
    result.add $start
    if last != start:
      result.add '-'
      result.add $last
    inc i

func rangeText(wholes: seq[int64]; others: seq[float64]): string =
  let ranges = joinRanges(wholes)
  var rest = ""
  for i, x in others:
    if i > 0: rest.add ", "
    rest.add stationNumber(x)
  if ranges.len == 0: rest
  elif rest.len == 0: ranges
  else: ranges & ", " & rest

func badRecordsText(b: QualityBuild; acc: StAcc): string =
  var first = true
  for fid in acc.fileOrder:
    if not first: result.add '\n'
    first = false
    result.add b.files[fid]
    let cell = acc.badFiles[fid]
    let text = rangeText(sortedWholes(cell.wholes), sortedOthers(cell.others))
    if text.len > 0:
      result.add ' '
      result.add text

proc addCounts[T: StAcc | RecAcc](dst: var T; src: T) =
  dst.seen += src.seen
  dst.killed += src.killed
  dst.bad += src.bad
  for f in Finding: dst.counts[f] += src.counts[f]
  dst.tested += src.tested
  dst.noisy += src.noisy
  dst.weak += src.weak

proc absorb*(b: var QualityBuild; part: QualityBuild) =
  ## Adds everything `part` counted to `b`, its stations and records after those `b` has
  ## (a row both have is summed), as if `part`'s notes had been added to `b` one by one.
  var ids = newSeq[int](part.files.len)
  for i, name in part.files: ids[i] = b.fileId(name)
  for key in part.stOrder:
    let src = part.stations[key]
    if key notin b.stations:
      b.stOrder.add key
      b.stations[key] = StAcc()
    b.stations.withValue(key, dst):
      addCounts(dst[], src)
      for file in src.fileOrder:
        let bad = src.badFiles[file]
        for id in sortedWholes(bad.wholes): noteBad(dst[], ids[file], float64(id))
        for record in bad.others: noteBad(dst[], ids[file], record)
  for key in part.recOrder:
    let src = part.records[key]
    let at = RecKey(file: ids[key.file], finite: key.finite, record: key.record)
    if at notin b.records:
      b.recOrder.add at
      b.records[at] = RecAcc()
    b.records.withValue(at, dst):
      addCounts(dst[], src)

proc initQualityBuild*(): QualityBuild =
  ## An empty set of notes.
  QualityBuild()

proc qualityReport*(b: QualityBuild): QualityReport =
  ## The tables of `b`, in the default sort. A station row is emitted for
  ## every station and component that was seen, and a record row for every
  ## file and record that had a seismic trace.
  var traces, killed, bad, tested, noisy, weak = 0
  var counts: array[Finding, int]
  for key in b.stOrder:
    let acc = b.stations[key]
    result.stations.add StationRow(line: lineOf(key), point: pointOf(key),
      index: key.index, component: key.component, seen: acc.seen, killed: acc.killed,
      bad: acc.bad, counts: acc.counts, tested: acc.tested, noisy: acc.noisy,
      weak: acc.weak, badRecords: badRecordsText(b, acc))
    traces += acc.seen
    killed += acc.killed
    bad += acc.bad
    tested += acc.tested
    noisy += acc.noisy
    weak += acc.weak
    for f in Finding: counts[f] += acc.counts[f]
  for key in b.recOrder:
    let acc = b.records[key]
    result.records.add RecordRow(file: b.files[key.file], record: recordOf(key),
      seen: acc.seen, killed: acc.killed, bad: acc.bad, counts: acc.counts,
      tested: acc.tested, noisy: acc.noisy, weak: acc.weak)
  result.totals = Totals(files: b.files.len, records: result.records.len,
    traces: traces, killed: killed, bad: bad, stations: result.stations.len,
    counts: counts, tested: tested, noisy: noisy, weak: weak)
  sortStations(result.stations, DefaultStationSort)
  sortRecords(result.records, DefaultRecordSort)

proc stationsCsv*(rows: openArray[StationRow]): string =
  ## A header and one line per station. Fields are quoted per RFC 4180.
  result = csvLine("line", "point", "index", "component", "seen", "killed", "bad",
    $qfHeaderDead, $qfAllZero, $qfConstant, $qfClipped, $qfSpiky, $qfDcOffset,
    $qfNonFinite, "noisy", "weak", "badRecords")
  for r in rows:
    result.add csvLine(stationNumber(r.line), stationNumber(r.point), $r.index,
      $r.component, $r.seen, $r.killed, $r.bad, $r.counts[qfHeaderDead],
      $r.counts[qfAllZero], $r.counts[qfConstant], $r.counts[qfClipped],
      $r.counts[qfSpiky], $r.counts[qfDcOffset], $r.counts[qfNonFinite],
      noiseCell(r.tested, r.noisy), noiseCell(r.tested, r.weak), r.badRecords)

proc recordsCsv*(rows: openArray[RecordRow]): string =
  ## A header and one line per record. Fields are quoted per RFC 4180.
  result = csvLine("file", "record", "seen", "killed", "bad", $qfHeaderDead,
    $qfAllZero, $qfConstant, $qfClipped, $qfSpiky, $qfDcOffset, $qfNonFinite,
    "noisy", "weak")
  for r in rows:
    result.add csvLine(r.file, stationNumber(r.record), $r.seen, $r.killed, $r.bad,
      $r.counts[qfHeaderDead], $r.counts[qfAllZero], $r.counts[qfConstant],
      $r.counts[qfClipped], $r.counts[qfSpiky], $r.counts[qfDcOffset],
      $r.counts[qfNonFinite], noiseCell(r.tested, r.noisy), noiseCell(r.tested, r.weak))

proc totalsCsv*(t: Totals): string =
  ## One header and one totals line.
  result = csvLine("files", "records", "traces", "killed", "bad", "stations",
    $qfHeaderDead, $qfAllZero, $qfConstant, $qfClipped, $qfSpiky, $qfDcOffset,
    $qfNonFinite, "noisy", "weak")
  result.add csvLine($t.files, $t.records, $t.traces, $t.killed, $t.bad, $t.stations,
    $t.counts[qfHeaderDead], $t.counts[qfAllZero], $t.counts[qfConstant],
    $t.counts[qfClipped], $t.counts[qfSpiky], $t.counts[qfDcOffset],
    $t.counts[qfNonFinite], noiseCell(t.tested, t.noisy), noiseCell(t.tested, t.weak))
