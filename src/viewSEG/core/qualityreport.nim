## Trace-quality table: one row per station (line and point), counting every
## trace of it in every file of the scan, the totals, sorted and written as CSV.
##
## A scan hands in one `TraceNote` per seismic trace (`addTrace`). This
## module does not read files, start jobs or keep state of its own: the
## notes live in a `QualityBuild` the caller owns. An auxiliary trace is
## not a note. A killed trace counts as killed, not as bad, and its
## findings are ignored. Header-dead is its own finding (`findingsOf`);
## it is not also all-zero. Weak and noisy are not findings: the scan
## judges them a field record at a time (the map's test) and hands in what it
## found per trace (`noisyTested`, `weakTested`, `noisy`, `weak`); they are
## counted apart from `bad`. Each has its own tested count: a trace inside the
## exclusion area is tested for weak but not for noisy. A count is shown only
## where some trace was tested for it.
##
## A station is the line and point the caller gives a note (the receiver of a
## shot gather's traces, the source of a receiver gather's: the caller's rule).
## Its components, its indices and its files are not rows of their own: every
## trace of the station counts in its one row, and the row names the components
## it has. Components are never compared across stations: each row counts only
## its own traces. Line and point are rounded to 1/100, and a non-finite line or
## point is the one unknown station: a row of its own, not counted as a station in the
## totals (its traces are in the trace totals). Components are judged file by file: in a
## file, a station that has a trace there lacks the components that file has at other
## stations and it does not (`lacking`, over every file; `lackFiles`, the files it lacked
## one in), so a file of one component, or of another component set, flags nobody in the
## others. A component counts for a file only when at least two of its stations, and at
## least half of them, have it.
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
    line*, point*: float64 ## The station; NaN when the headers name none.
    component*: uint8
    killed*: bool          ## A per-file edit killed it: counted as killed, not bad.
    findings*: set[Finding]
    noisyTested*: bool     ## The noisy test ran on its record and judged this trace.
    weakTested*: bool      ## The weak test did: as noisy, and inside the exclusion area too.
    noisy*, weak*: bool    ## Only meaningful when `noisyTested`, `weakTested`.

  StationRow* = object
    ## One station, over every file of the scan.
    line*, point*: float64
    components*: set[uint8]   ## the components that have a trace here
    lackFiles*: int           ## files in which it lacked a component
    lacking*: set[uint8]      ## components it lacked in some file; {} when it lacked none
    seen*, killed*, bad*: int ## `seen` includes killed. `bad` does not.
    counts*: array[Finding, int]
    noisyTested*, noisy*: int ## `noisy` of `noisyTested` traces; nothing shown when it is 0.
    weakTested*, weak*: int   ## The same for weak.

  Totals* = object
    ## Scan totals over the notes. Unread files are not counted.
    files*, traces*, killed*, bad*, stations*: int
    badStations*: int                             ## stations with at least one bad trace
    lacking*: int                                 ## stations that lacked a component in some file
    components*: int                              ## most components one file has
    counts*: array[Finding, int]
    noisyTested*, noisy*, weakTested*, weak*: int ## As in `StationRow`.

  QualityReport* = object
    stations*: seq[StationRow]
    totals*: Totals

  StationSortColumn* = enum
    ## A column of `StationRow`.
    ssLine, ssPoint, ssLacking, ssLackFiles, ssSeen, ssKilled, ssBad,
    ssHeaderDead, ssAllZero, ssConstant, ssClipped, ssSpiky, ssDcOffset,
    ssNonFinite, ssNoisyTested, ssNoisy, ssWeakTested, ssWeak

  SortSpec*[C] = seq[tuple[column: C, descending: bool]]
    ## Sort keys, first one most significant. A tie keeps the rows' order.

const
  DefaultStationSort*: SortSpec[StationSortColumn] = @[
    (column: ssLine, descending: false), (column: ssPoint, descending: false)]

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

func isUnknown*(r: StationRow): bool =
  ## The row of the traces that name no station.
  r.line != r.line

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

const
  NoisyTestedCsv = "tested (noisy)" ## CSV column: the traces the noisy test judged.
  WeakTestedCsv = "tested (weak)"   ## CSV column: the traces the weak test judged.

func noiseCell*(tested, n: int): string =
  ## A count of `tested` traces, or "" when no trace was tested for it.
  if tested > 0: $n else: ""

func componentList*(components: set[uint8]): string =
  ## The component numbers in order, separated by a comma and a space; "" for none.
  for c in components:
    if result.len > 0: result.add ", "
    result.add $c

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

func known(tested, n: int): int =
  ## The count to sort by: rows with nothing tested come before every count.
  if tested > 0: n else: -1

func cmpStation(a, b: StationRow; column: StationSortColumn): int =
  case column
  of ssLine: cmpNum(a.line, b.line)
  of ssPoint: cmpNum(a.point, b.point)
  of ssLacking: cmp(a.lacking.card, b.lacking.card)
  of ssLackFiles: cmp(a.lackFiles, b.lackFiles)
  of ssSeen: cmp(a.seen, b.seen)
  of ssKilled: cmp(a.killed, b.killed)
  of ssBad: cmp(a.bad, b.bad)
  of ssNoisyTested: cmp(a.noisyTested, b.noisyTested)
  of ssNoisy: cmp(known(a.noisyTested, a.noisy), known(b.noisyTested, b.noisy))
  of ssWeakTested: cmp(a.weakTested, b.weakTested)
  of ssWeak: cmp(known(a.weakTested, a.weak), known(b.weakTested, b.weak))
  of ssHeaderDead, ssAllZero, ssConstant, ssClipped, ssSpiky, ssDcOffset, ssNonFinite:
    cmp(a.counts[kindColumn(column)], b.counts[kindColumn(column)])

proc reorder[T](rows: seq[T]; order: openArray[int]): seq[T] =
  result.setLen(rows.len)
  for i, src in order:
    result[i] = rows[src]

proc sortStations*(rows: var seq[StationRow]; by: SortSpec[StationSortColumn]) =
  ## Sorts `rows` by `by`. A tie, including a tie on every column, keeps the
  ## rows in the order they had. A NaN line or point sorts after every number.
  if rows.len < 2 or by.len == 0: return
  let view = rows
  var order = newSeq[int](view.len)
  for i in 0 ..< order.len: order[i] = i
  order.sort proc (a, b: int): int =
    for spec in by:
      let c = cmpStation(view[a], view[b], spec.column)
      if c != 0: return if spec.descending: -c else: c
    cmp(a, b)
  rows = reorder(view, order)

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

func lineText*(r: StationRow): string =
  ## The line as shown: "unknown" for the traces that name no station.
  if r.isUnknown: "unknown" else: stationNumber(r.line)

func pointText*(r: StationRow): string =
  ## The point as shown: empty for the traces that name no station.
  if r.isUnknown: "" else: stationNumber(r.point)

func stationText(r: StationRow): string =
  lineText(r) & " " & pointText(r) & " " & componentList(r.lacking)

func filterStations*(rows: openArray[StationRow]; filter: string): seq[int] =
  ## Indices of the rows whose line, point or lacking components hold every word of
  ## `filter`, in any case. An empty filter, or one of only spaces, is every row.
  for i, r in rows:
    if matchesAll(stationText(r), filter): result.add i

type
  StKey = object
    known: bool ## false: the one unknown station (a trace with no line or no point)
    lineH, pointH: int64

  StAcc = object
    components: set[uint8]
    lacking: set[uint8]   ## components it lacked in some file
    lackFiles: int        ## files in which it lacked one
    fileComps: set[uint8] ## its components in the file `stamp`
    stamp: int            ## the serial of the file `fileComps` is for
    seen, killed, bad: int
    counts: array[Finding, int]
    noisyTested, noisy, weakTested, weak: int

  QualityBuild* = object
    ## Notes gathered for `qualityReport`. Fields are private: add with
    ## `addTrace`. A file's notes are added together: the next file's first note closes
    ## the file (`closeFile`), working out which stations lacked a component in it.
    ## What is kept for a station does not grow with the number of files.
    files: int
    most: int ## the most components one file had
    serial: int ## the serial of the open file
    current: string ## the open file
    open: bool
    stOrder: seq[StKey]
    stations: Table[StKey, StAcc]
    inFile: seq[StKey] ## the known stations of the open file

const
  MinComponentStations = 2 ## a component counts for a file when at least this many stations

func hash(k: StKey): Hash =
  var h = hash(k.known)
  h = h !& hash(k.lineH)
  h = h !& hash(k.pointH)
  !$h

func `==`(a, b: StKey): bool =
  a.known == b.known and a.lineH == b.lineH and a.pointH == b.pointH

func hundredths(x: float64): tuple[known: bool; n: int64] =
  if x != x or x == Inf or x == -Inf: return (false, 0)
  let h = round(x * 100.0)
  if h != h or abs(h) > 9.0e18: return (false, 0)
  (true, int64(h))

func stKey(line, point: float64): StKey =
  ## A trace with no line, or no point, is the one unknown station.
  let ln = hundredths(line)
  let pt = hundredths(point)
  if ln.known and pt.known: StKey(known: true, lineH: ln.n, pointH: pt.n) else: StKey()

func lineOf(k: StKey): float64 =
  if k.known: float64(k.lineH) / 100.0 else: NaN

func pointOf(k: StKey): float64 =
  if k.known: float64(k.pointH) / 100.0 else: NaN

proc bump(acc: var StAcc; note: TraceNote; serial: int) =
  acc.components.incl note.component
  if acc.stamp != serial:
    acc.stamp = serial
    acc.fileComps = {}
  acc.fileComps.incl note.component
  inc acc.seen
  if note.killed:
    inc acc.killed
  else:
    if note.findings != {}:
      inc acc.bad
      for f in note.findings: inc acc.counts[f]
    if note.noisyTested:
      inc acc.noisyTested
      if note.noisy: inc acc.noisy
    if note.weakTested:
      inc acc.weakTested
      if note.weak: inc acc.weak

proc closeFile(b: var QualityBuild) =
  ## Ends the open file: a component counts for it when at least `MinComponentStations`
  ## of its stations, and at least half of them, have it (one hydrophone on one node is not
  ## a component of the file); a station with a trace in the file lacks those it has none of.
  if b.inFile.len > 0:
    var seenAt: array[256, int]
    for key in b.inFile:
      for c in b.stations[key].fileComps: inc seenAt[int(c)]
    var counted: set[uint8] = {}
    for c in 0 .. 255:
      if seenAt[c] >= MinComponentStations and seenAt[c] * 2 >= b.inFile.len:
        counted.incl uint8(c)
    b.most = max(b.most, counted.card)
    if counted.card > 0:
      for key in b.inFile:
        b.stations.withValue(key, acc):
          let gap = counted - acc[].fileComps
          if gap.card > 0:
            acc[].lacking = acc[].lacking + gap
            inc acc[].lackFiles
    b.inFile.setLen 0
  b.open = false

proc addTrace*(b: var QualityBuild; note: TraceNote) =
  ## Counts `note`. A killed trace increments `killed` only, whatever
  ## `findings` holds. A trace with several findings increments each of
  ## those counts and `bad` once. The first note of a station opens its row,
  ## including a clean trace and a killed-only station.
  if not b.open or note.file != b.current:
    b.closeFile()
    b.open = true
    b.current = note.file
    inc b.serial
    inc b.files
  let sk = stKey(note.line, note.point)
  b.stations.withValue(sk, acc):
    if sk.known and acc[].stamp != b.serial: b.inFile.add sk
    bump(acc[], note, b.serial)
    return
  b.stOrder.add sk
  var acc = StAcc()
  bump(acc, note, b.serial)
  if sk.known: b.inFile.add sk
  b.stations[sk] = acc

proc addCounts(dst: var StAcc; src: StAcc) =
  dst.components = dst.components + src.components
  dst.lacking = dst.lacking + src.lacking
  dst.lackFiles += src.lackFiles
  dst.seen += src.seen
  dst.killed += src.killed
  dst.bad += src.bad
  for f in Finding: dst.counts[f] += src.counts[f]
  dst.noisyTested += src.noisyTested
  dst.noisy += src.noisy
  dst.weakTested += src.weakTested
  dst.weak += src.weak

proc absorb*(b: var QualityBuild; part: QualityBuild) =
  ## Adds everything `part` counted to `b`, its stations after those `b` has
  ## (a station both have is summed), as if `part`'s notes had been added to `b` one by one.
  ## `part` holds whole files.
  var done = part
  done.closeFile()
  b.closeFile()
  b.files += done.files
  b.most = max(b.most, done.most)
  for key in done.stOrder:
    let src = done.stations[key]
    if key notin b.stations:
      b.stOrder.add key
      b.stations[key] = StAcc()
    b.stations.withValue(key, dst):
      addCounts(dst[], src)

proc initQualityBuild*(): QualityBuild =
  ## An empty set of notes.
  QualityBuild()

proc tableOf(b: QualityBuild): QualityReport =
  ## `qualityReport` of a build whose last file is closed.
  var traces, killed, bad, noisyTested, noisy, weakTested, weak, badStations = 0
  var counts: array[Finding, int]
  var lacking, stations = 0
  for key in b.stOrder:
    let acc = b.stations[key]
    result.stations.add StationRow(line: lineOf(key), point: pointOf(key),
      components: acc.components, lacking: acc.lacking, lackFiles: acc.lackFiles,
      seen: acc.seen, killed: acc.killed, bad: acc.bad, counts: acc.counts,
      noisyTested: acc.noisyTested, noisy: acc.noisy, weakTested: acc.weakTested,
      weak: acc.weak)
    traces += acc.seen
    killed += acc.killed
    bad += acc.bad
    if key.known:
      inc stations
      if acc.bad > 0: inc badStations
      if acc.lackFiles > 0: inc lacking
    noisyTested += acc.noisyTested
    noisy += acc.noisy
    weakTested += acc.weakTested
    weak += acc.weak
    for f in Finding: counts[f] += acc.counts[f]
  result.totals = Totals(files: b.files, traces: traces, killed: killed, bad: bad,
    stations: stations, badStations: badStations, lacking: lacking,
    components: b.most, counts: counts, noisyTested: noisyTested, noisy: noisy,
    weakTested: weakTested, weak: weak)
  sortStations(result.stations, DefaultStationSort)

proc qualityReport*(b: QualityBuild): QualityReport =
  ## The table of `b`, in the default sort. A row is emitted for every station
  ## that was seen, and one for the traces that name none (`isUnknown`), which is not
  ## counted as a station in the totals. In each file a station lacks the components the
  ## file has at other stations and the station has no trace of there.
  if b.open:
    var done = b
    done.closeFile()
    tableOf(done)
  else: tableOf(b)

proc stationsCsv*(rows: openArray[StationRow]): string =
  ## A header and one line per station. Fields are quoted per RFC 4180.
  result = csvLine("line", "point", "lacking components", "files lacking", "seen", "killed", "bad",
    $qfHeaderDead, $qfAllZero, $qfConstant, $qfClipped, $qfSpiky, $qfDcOffset,
    $qfNonFinite, NoisyTestedCsv, "noisy", WeakTestedCsv, "weak")
  for r in rows:
    result.add csvLine(lineText(r), pointText(r),
      componentList(r.lacking), $r.lackFiles, $r.seen, $r.killed, $r.bad, $r.counts[qfHeaderDead],
      $r.counts[qfAllZero], $r.counts[qfConstant], $r.counts[qfClipped],
      $r.counts[qfSpiky], $r.counts[qfDcOffset], $r.counts[qfNonFinite], $r.noisyTested,
      noiseCell(r.noisyTested, r.noisy), $r.weakTested, noiseCell(r.weakTested, r.weak))

proc totalsCsv*(t: Totals): string =
  ## One header and one totals line.
  result = csvLine("files", "traces", "killed", "bad", "stations", "stations with a bad trace",
    "stations lacking a component", $qfHeaderDead, $qfAllZero, $qfConstant, $qfClipped,
    $qfSpiky, $qfDcOffset, $qfNonFinite, NoisyTestedCsv, "noisy", WeakTestedCsv, "weak")
  result.add csvLine($t.files, $t.traces, $t.killed, $t.bad, $t.stations, $t.badStations,
    $t.lacking, $t.counts[qfHeaderDead], $t.counts[qfAllZero], $t.counts[qfConstant],
    $t.counts[qfClipped], $t.counts[qfSpiky], $t.counts[qfDcOffset],
    $t.counts[qfNonFinite], $t.noisyTested, noiseCell(t.noisyTested, t.noisy),
    $t.weakTested, noiseCell(t.weakTested, t.weak))
