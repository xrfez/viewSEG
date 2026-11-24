## The pure first part of cutting a continuous gather by a shot log: the
## options, the shots in time order, the record numbers, the size of the
## output and the checks on the window. No file is read or written here.
##
## The output has one record per shot, holding the node's components as
## channels 1..C.
##
## Cutting reads each source sample once. A `SourceBuffer` holds the decoded
## samples of the rows the windows in flight overlap, filled by a callback the
## caller supplies (so no file is touched here); `cutOne` builds one output
## trace from it with the library's piecewise calls.

import std/[algorithm, math, options, sets, strutils, tables]
import processSEG/continuous/slice
import processSEG/core/workspace
import ./[recordingkind, shotlog]

type
  CutStandard* = enum
    csSegdRev3 ## SEG-D Rev 3.
    csSegy     ## SEG-Y.

  CutOptions* = object
    ## What to cut at each shot.
    recordMs*: float64 ## Record length, ms; a whole number of samples.
    startMs*: float64  ## Start relative to the shot time, ms; may be negative.
    align*: SliceAlign
    standard*: CutStandard

  CutShots* = object
    ## The timed shots of a log, in time order.
    shots*: seq[SliceShot]
    rows*: seq[int]      ## For each shot, the index of its row in the log.
    dropped*: int        ## Rows without a time.
    duplicateTimes*: int ## Shots with the time of the shot before them (kept).
    increasing*: bool    ## The file numbers strictly increase in time order.
    pointIndexOutOfRange*: int
      ## Timed shots with a point index the writer cannot hold (not 0..255).

const
  MaxRecordNumber* = 0xFF_FFFF    ## The writer's largest record number.
  MaxEndUs = float64(high(int32)) ## The writer's limit on a window end, µs.

func initCutOptions*(recordMs: float64, startMs = 0.0, align = saNearest,
    standard = csSegdRev3): CutOptions =
  ## Options for a record of `recordMs`.
  CutOptions(recordMs: recordMs, startMs: startMs, align: align, standard: standard)

func sliceShotOf*(shot: Shot): SliceShot =
  ## The planner's shot for a log row. The time is UTC, so it goes through
  ## `initSliceShot` and the exact microseconds are set on top; the GPS
  ## constructor would shift it by the leap seconds. A shot with no time
  ## gets time 0. A missing file number or value is NaN.
  let us = shot.timeUtcUs.get(0)
  let id =
    if shot.fileNumber.isSome: float64(shot.fileNumber.get)
    else: NaN
  let index =
    if shot.pointIndex.isSome and shot.pointIndex.get in 0'i64..255'i64:
      int16(shot.pointIndex.get)
    else: 0'i16
  result = initSliceShot(toPosixSeconds(us), id, shot.sourceLine, shot.shotPoint,
    shot.x, shot.y, shot.z, index)
  result.timeUs = us
  result.timeUsKnown = shot.timeUtcUs.isSome

func shotsInTime*(rows: openArray[Shot]): CutShots =
  ## The rows with a time, sorted by it (equal times keep the log order).
  ## Rows without a time are counted in `dropped`; equal times are kept and
  ## counted in `duplicateTimes`.
  result = CutShots(increasing: true)
  var keyed: seq[tuple[us: int64, row: int]] = @[]
  for i, r in rows:
    if r.timeUtcUs.isSome: keyed.add (r.timeUtcUs.get, i)
    else: inc result.dropped
  keyed.sort() # the row index breaks ties, so the log order is kept
  var order: seq[int] = @[]
  for k in keyed: order.add k.row
  var prevFile = NaN
  for n, i in order:
    let s = sliceShotOf(rows[i])
    if rows[i].pointIndex.isSome and rows[i].pointIndex.get notin 0'i64 .. 255'i64:
      inc result.pointIndexOutOfRange
    if n > 0:
      if rows[order[n - 1]].timeUtcUs.get == rows[i].timeUtcUs.get:
        inc result.duplicateTimes
      if s.id.isNaN or prevFile.isNaN or not (s.id > prevFile):
        result.increasing = false
    elif s.id.isNaN:
      result.increasing = false
    prevFile = s.id
    result.shots.add s
    result.rows.add i

func recordNumbers*(shots: CutShots): tuple[numbers: seq[int], fromFileNumber: bool] =
  ## The record number of each shot: its file number when all are whole
  ## numbers within the writer's range and strictly increase in time order,
  ## else 1..N (`fromFileNumber` false).
  var ok = shots.increasing
  for s in shots.shots:
    if s.id.isNaN or s.id != round(s.id) or s.id < 0 or s.id > float64(MaxRecordNumber):
      ok = false
  result.fromFileNumber = ok
  result.numbers = newSeq[int](shots.shots.len)
  for i in 0 ..< result.numbers.len:
    result.numbers[i] = if ok: int(shots.shots[i].id) else: i + 1

func estimateBytes*(opts: CutOptions, shots, components, samplesPerTrace: int,
    withSourceStation, withSourceXY, withReceiverXY: bool): int64 =
  ## The size of the output, one record per shot of `components` traces.
  ## SEG-D Rev 3: per record 96 bytes of general headers, 96 of channel-set
  ## descriptor, 64 for the coordinate reference block the writer always adds,
  ## 32 for a source station and 96 for a source position; per trace 20 bytes,
  ## 32 per header extension (2, or 5 with a receiver position) and 4 per
  ## sample. SEG-Y: 3600 bytes of file headers and 3200 of extended text,
  ## then per trace 240 of header, 240 of header extension and 4 per sample.
  let traces = int64(shots) * int64(components)
  let samples = int64(samplesPerTrace)
  case opts.standard
  of csSegy:
    result = 3600'i64 + 3200 + traces * (480'i64 + samples * 4)
  of csSegdRev3:
    var record = 96'i64 + 96 + 64
    if withSourceStation: record += 32
    if withSourceXY: record += 96
    let exts = if withReceiverXY: 5'i64 else: 2'i64
    result = int64(shots) * record + traces * (20'i64 + exts * 32 + samples * 4)

func checkOptions*(opts: CutOptions, dtMs: float64): string =
  ## "" when the options can be cut at sample interval `dtMs`, else a
  ## sentence saying what is wrong.
  if dtMs.isNaN or dtMs <= 0:
    result = "The sample interval is not known."
  elif opts.recordMs.isNaN or opts.startMs.isNaN or opts.recordMs.classify == fcInf or
      opts.startMs.classify in {fcInf, fcNegInf}:
    result = "The start and the length must be numbers."
  elif opts.recordMs <= 0:
    result = "The record length must be more than zero."
  else:
    let n = opts.recordMs / dtMs
    if abs(n - round(n)) > 1e-6 * max(1.0, abs(n)):
      result = "The record length must be a whole number of samples (" & $dtMs &
        " ms each)."
    elif (opts.startMs + opts.recordMs) * 1000 > MaxEndUs:
      result = "The window ends too late for the file: its end must be under 2147 s."

type
  FetchProc* = proc (row, first, count: int, dst: var openArray[float32]): bool {.closure.}
    ## Reads and decodes samples `first ..< first + count` of planning row
    ## `row` into `dst` (`count` long). False: the read failed; `dst` is
    ## then ignored.

  HeldRow = object
    first: int
    data: seq[float32]

  SourceBuffer* = object
    ## Decoded samples of source rows. Per row one contiguous run, so a
    ## request that leaves a gap fetches the gap too. Nothing grows with the
    ## number of shots: the caller drops what no pending window reads.
    rows: Table[int, HeldRow]
    zeros: seq[float32] # the samples handed for a piece that failed to read
    pending: Table[int, int]
      # per row, the `sample` of the last `evictBefore`: the earliest column a
      # window not yet cut reads (`high(int)`: none does)
    failedRows: HashSet[int] # rows a fetch has failed on
    failedOverlaps: HashSet[int] # overlaps whose samples could not be had
    indexed: bool # `byRow` is built (for the one plan this buffer serves)
    byRow: Table[int, seq[int]]
      # per row, the overlaps that touch it and whose two rows the plan reads
    dirty: seq[int] # rows whose `pending` changed since the last overlap check

func initSourceBuffer*(): SourceBuffer =
  ## An empty buffer.
  SourceBuffer(rows: initTable[int, HeldRow](), pending: initTable[int, int](),
    failedRows: initHashSet[int](), failedOverlaps: initHashSet[int](),
    byRow: initTable[int, seq[int]]())

func heldSamples*(buf: SourceBuffer): int =
  ## The samples held, over every row.
  for h in buf.rows.values: result += h.data.len

func heldRange*(buf: SourceBuffer, row: int): Slice[int] =
  ## The columns of `row` held, empty (`a > b`) when none.
  if row in buf.rows:
    let h = buf.rows[row]
    result = h.first .. h.first + h.data.len - 1
  else:
    result = 0 .. -1

func held*(buf: SourceBuffer, row: int): lent seq[float32] =
  ## The samples held of `row`, from column `heldRange(row).a`. Raises
  ## `KeyError` when the row holds none: `need` it first. Valid until the
  ## next `need` on any row (one that adds a row can rehash the table),
  ## `evictBefore` or `evictRow`.
  buf.rows[row].data

proc grow(h: var HeldRow, row, first, count: int, fetch: FetchProc): bool =
  ## Extends `h` to cover `first ..< first + count`; unchanged on failure.
  let newEnd = first + count
  let oldEnd = h.first + h.data.len
  if h.data.len == 0:
    var d = newSeq[float32](count)
    result = fetch(row, first, count, d)
    if result:
      h.first = first
      h.data = move d
  elif first >= h.first and newEnd <= oldEnd:
    result = true
  elif first >= h.first:
    # Only the end moves: append in place.
    h.data.setLen(newEnd - h.first)
    result = fetch(row, oldEnd, newEnd - oldEnd,
      h.data.toOpenArray(oldEnd - h.first, newEnd - h.first - 1))
    if not result: h.data.setLen(oldEnd - h.first)
  else:
    let b = max(newEnd, oldEnd)
    var d = newSeq[float32](b - first)
    copyMem(addr d[h.first - first], addr h.data[0], h.data.len * sizeof(float32))
    result = fetch(row, first, h.first - first, d.toOpenArray(0, h.first - first - 1))
    if result and b > oldEnd:
      result = fetch(row, oldEnd, b - oldEnd, d.toOpenArray(oldEnd - first, b - first - 1))
    if result:
      h.first = first
      h.data = move d

proc need*(buf: var SourceBuffer, row, first, count: int, fetch: FetchProc): int =
  ## Makes `first ..< first + count` of `row` held, calling `fetch` only for
  ## the part not held (a gap between the held run and the request is
  ## fetched too). Returns the index in `buf.held(row)` of column `first`, so
  ## the samples are `toOpenArray(buf.held(row), i, i + count - 1)`; -1 when a
  ## fetch failed (nothing is changed) or the request is empty or negative.
  if count <= 0 or first < 0:
    result = -1
  else:
    let ok = grow(buf.rows.mgetOrPut(row, HeldRow(first: first)), row, first, count,
      fetch)
    result = if ok: first - buf.rows[row].first else: -1
    if not ok: buf.failedRows.incl row

proc evictBefore*(buf: var SourceBuffer, row, sample: int) =
  ## Drops the columns of `row` before `sample`, and notes `sample` as the
  ## earliest column of `row` still wanted (`checkOverlaps` uses it).
  buf.pending[row] = sample
  buf.dirty.add row
  if row in buf.rows:
    let first = buf.rows[row].first
    if sample >= first + buf.rows[row].data.len:
      buf.rows.del row
    elif sample > first:
      buf.rows.withValue(row, h):
        let keep = h.data.len - (sample - first)
        moveMem(addr h.data[0], addr h.data[sample - first], keep * sizeof(float32))
        h.data.setLen(keep)
        h.first = sample

proc evictRow*(buf: var SourceBuffer, row: int) =
  ## Drops everything held of `row`; nothing of it is wanted any more.
  buf.pending[row] = high(int)
  buf.dirty.add row
  buf.rows.del row

func readsRow*(plan: SlicePlan, row: int): bool =
  ## True when some window reads a sample of source row `row`.
  plan.rowsNeeded.binarySearch(row) >= 0

proc indexOverlaps(plan: SlicePlan, buf: var SourceBuffer) =
  ## Lists, per row, the overlaps that touch it and whose rows the plan reads,
  ## once. A buffer serves one plan.
  if not buf.indexed:
    buf.indexed = true
    for i, o in plan.overlaps:
      if plan.readsRow(o.earlier) and plan.readsRow(o.later):
        buf.byRow.mgetOrPut(o.earlier, @[]).add i
        buf.byRow.mgetOrPut(o.later, @[]).add i

func pendingOverlap(buf: SourceBuffer, report: SliceReport, i: int): bool =
  ## Not yet compared and not given up.
  report.overlapCheck(i).status == osNotRead and i notin buf.failedOverlaps

proc evictable*(plan: SlicePlan, buf: var SourceBuffer, report: SliceReport,
    row, earliestPendingStart: int): int =
  ## The first column of `row` that must still be held: every column before
  ## it may go (`evictBefore`). `earliestPendingStart` is the first column of
  ## the row that a window not yet cut reads (a piece's `first`, margin
  ## included). It is lowered for an overlap on the row that is not yet
  ## checked (and not one whose samples could not be had, which would pin
  ## the rows to the end): the earlier row's trimmed tail is in no piece, and the later
  ## row is needed from column 0. Looks only at the overlaps of `row`.
  indexOverlaps(plan, buf)
  result = max(earliestPendingStart, 0)
  buf.byRow.withValue(row, list):
    for i in list[]:
      let o = plan.overlaps[i]
      if o.samples > 0 and buf.pendingOverlap(report, i):
        if o.earlier == row: result = min(result, o.first)
        elif o.later == row: result = 0

proc cutOne*(plan: SlicePlan, trace: int, buf: var SourceBuffer, fetch: FetchProc,
    dst: var openArray[float32], report: var SliceReport, ws: var Workspace): bool =
  ## Cuts output trace `trace` into `dst` (`plan.samples` long) from the
  ## buffer, fetching what it does not hold. Returns true when a piece could
  ## not be read: it is zero-filled and counted in `report.failedSamples`;
  ## a failed read never raises. Raises `ValueError` as the library does for
  ## a bad trace, `dst`, `report` or workspace.
  beginSliceTrace(plan, trace, report)
  let nothing = default(seq[float32])
  for pc in plan.pieces(trace):
    if pc.row < 0 or pc.count <= 0:
      addPiece(plan, trace, pc, nothing, dst, report, ws)
    else:
      # The planner keeps every piece inside its row, so the piece's own end
      # is a row length that gives `pc.count` samples.
      let (first, count) = pieceSource(plan, pc, pc.first + pc.count)
      let i = buf.need(pc.row, first, count, fetch)
      if i >= 0:
        addPiece(plan, trace, pc, buf.held(pc.row).toOpenArray(i, i + count - 1), dst,
          report, ws)
      else:
        # The library wants `pc.count` samples even for a failed piece.
        if buf.zeros.len < pc.count: buf.zeros.setLen(pc.count)
        addPiece(plan, trace, pc, buf.zeros.toOpenArray(0, pc.count - 1), dst, report,
          ws, failed = true)
        result = true
  finishSliceTrace(plan, trace, dst, report, ws)

proc compareOverlap(plan: SlicePlan, buf: var SourceBuffer, fetch: FetchProc,
    report: var SliceReport, i: int, settled: var seq[int]): int =
  ## Compares overlap `i` (due, not yet compared); 1 when it was compared.
  let o = plan.overlaps[i]
  let nothing = default(seq[float32])
  if o.samples == 0:
    if o.earlier in buf.failedRows or o.later in buf.failedRows:
      buf.failedOverlaps.incl i
      settled.add i
    else:
      checkSliceOverlap(plan, i, nothing, nothing, report)
      settled.add i
      result = 1
  else:
    let a = buf.need(o.earlier, o.first, o.samples, fetch)
    let b = if a >= 0: buf.need(o.later, 0, o.samples, fetch) else: -1
    if b >= 0:
      checkSliceOverlap(plan, i, buf.held(o.earlier).toOpenArray(a, a + o.samples - 1),
        buf.held(o.later).toOpenArray(b, b + o.samples - 1), report)
      settled.add i
      result = 1
    else:
      buf.failedOverlaps.incl i
      settled.add i

proc checkOverlaps*(plan: SlicePlan, buf: var SourceBuffer, fetch: FetchProc,
    report: var SliceReport, settled: var seq[int], final = false): int =
  ## Compares the overlaps that are due, not yet compared, whose two rows the
  ## plan reads and whose two runs can be had (through the buffer, so nothing
  ## is read twice), and returns how many it compared. The indices of those
  ## it compared and of those it gave up on are added to `settled`: neither
  ## holds a row any more. An overlap is due when no window still to be cut
  ## reads the earlier row below the overlap (the `sample` of the last
  ## `evictBefore` of that row is at or after `overlap.first`, or the row is
  ## finished): then its tail is an append to the held run or a fresh run, and
  ## the later row is read from its start anyway. Only the overlaps of rows
  ## whose `evictBefore` or `evictRow` came since the last call are looked at
  ## (nothing else can have become due). `final` makes every overlap due
  ## (after the last shot). An overlap whose run cannot be read stays
  ## `osNotRead`, is not tried again and pins nothing; one with no samples is
  ## compared only when neither row has failed to read.
  indexOverlaps(plan, buf)
  if final:
    buf.dirty.setLen 0
    for i, o in plan.overlaps:
      if buf.pendingOverlap(report, i) and plan.readsRow(o.earlier) and
          plan.readsRow(o.later):
        result += compareOverlap(plan, buf, fetch, report, i, settled)
  else:
    let rows = move buf.dirty
    buf.dirty = @[]
    for row in rows:
      var due: seq[int] = @[]
      buf.byRow.withValue(row, list):
        for i in list[]:
          let o = plan.overlaps[i]
          if o.earlier == row and buf.pendingOverlap(report, i) and
              row in buf.pending and buf.pending[row] >= o.first:
            due.add i
      for i in due:
        if buf.pendingOverlap(report, i):
          result += compareOverlap(plan, buf, fetch, report, i, settled)

proc checkOverlaps*(plan: SlicePlan, buf: var SourceBuffer, fetch: FetchProc,
    report: var SliceReport, final = false): int =
  ## As above, without the list of what was settled.
  var settled: seq[int] = @[]
  checkOverlaps(plan, buf, fetch, report, settled, final)

func firstUse*(plan: SlicePlan, shot, row: int): int =
  ## The first column of `row` that any trace of `shot` reads, `high(int)`
  ## when none does.
  result = high(int)
  let c = plan.receiverCount
  for r in 0 ..< c:
    for pc in plan.pieces(shot * c + r):
      if pc.row == row and pc.count > 0: result = min(result, pc.first)

proc settleShot*(plan: SlicePlan, buf: var SourceBuffer, fetch: FetchProc,
    report: var SliceReport, touched: openArray[int], shot: int): int =
  ## The bookkeeping between shot `shot` and the next. `touched` are the rows
  ## the shot read. Drops what the next shot does not read, then compares the
  ## overlaps now due and drops the rows of those, again and again until no
  ## more overlap is due (a comparison frees rows, which can make the overlap
  ## behind them due). Returns the overlaps compared. Its cost follows the
  ## rows touched and the overlaps of those, not the number of overlaps.
  let total = plan.shotCount
  for row in touched:
    let next = if shot + 1 < total: firstUse(plan, shot + 1, row) else: high(int)
    buf.evictBefore(row, evictable(plan, buf, report, row, next))
  var settled: seq[int] = @[]
  while true:
    settled.setLen 0
    result += checkOverlaps(plan, buf, fetch, report, settled)
    if settled.len == 0: break
    for i in settled:
      let o = plan.overlaps[i]
      for row in [o.earlier, o.later]:
        let next = if shot + 1 < total: firstUse(plan, shot + 1, row) else: high(int)
        buf.evictBefore(row, evictable(plan, buf, report, row, next))

func secs(x: float64): string =
  ## Seconds to the digit that tells, without a trailing zero.
  let t = formatFloat(x, ffDecimal, 3)
  result = t.strip(leading = false, chars = {'0'}).strip(leading = false, chars = {'.'}) & " s"

func cutRefusal*(f: RecordingFacts): string =
  ## Why the cut refuses a file: for one that is not a continuous receiver gather what
  ## the file is, then the reason, in sentences; for a continuous one whose like-typed
  ## channels of a station cannot be told apart safely, that; "" when the cut may go on.
  case f.kind
  of rkReceiverContinuous:
    if f.unevenChannels > 0:
      result = "The channels of one component type at a station cannot be told apart and " &
        "one of them misses a segment, so the records cannot be assembled safely."
  of rkShotGather:
    result = "This file is a shot gather (the receiver changes from trace to trace), not a " &
      "continuous receiver gather."
  of rkReceiverSliced:
    result = "This file is a time-sliced receiver gather, not a continuous one."
    case f.slicedWhy
    of swIrregular:
      result.add " Trace " & $f.offTrace & " starts " & secs(f.offSeconds) & " off a whole " &
        "number of steps after the one before it (the traces start every " &
        secs(f.stepSeconds) & ")."
    of swShort:
      result.add " Its traces are " & secs(f.segmentSeconds) & " long but start every " &
        secs(f.stepSeconds) & ", so there is dead time between them."
    of swOverlap:
      result.add " Trace " & $f.offTrace & " overlaps a neighbouring trace by " &
        secs(f.overlapSeconds) & "."
    of swSameStart:
      result.add " Every trace carries the same start time, so their own start times are not " &
        "in the headers viewSEG reads: they may be in a header that a vendor header map " &
        "has to describe."
    of swNone: discard

func skipWords*(skips, missing: int): string =
  ## The sentence for whole segments the recorder did not record.
  func plural(n: int; one, many: string): string =
    $n & " " & (if n == 1: one else: many)
  "The recorder did not record for " & plural(missing, "segment", "segments") & " (in " &
    plural(skips, "place", "places") & "); those times are written as zeros."
