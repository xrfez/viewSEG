## Tests of the pure part of cutting a continuous gather by a shot log.
## Each was seen to fail with a deliberate fault: the UTC time passed
## through `initSliceShotGps` (shifted by the leap seconds), the id copied
## from the wrong field, the NaN replaced by 0, untimed rows kept, an
## unstable sort, `increasing` always true, a size term left out, and the
## checks removed.
##
## The sliding buffer and `cutOne` were seen to fail with: a piece's samples
## taken from the wrong buffer index (the equality test), an eviction that
## drops every held column ahead of the next window (the reuse test), the
## overlap rule ignoring unchecked overlaps (the overlap test), a failed
## fetch treated as success (the failed-read test); every overlap checked at
## once (`several_overlaps_checked_when_due`: "fetched 9970 of 6000"); a failed
## overlap tried again and pinning its rows ("held 940 at the end"); one
## overlap compared per shot (`buffer_stays_bounded_over_a_long_run`: "held 9930
## of at most 480"); every shot walking every overlap
## (`bookkeeping_cost_follows_the_shot`: "took 20359 ms").

import std/[assertions, math, monotimes, options, times]
import parseSEG, processSEG
import viewSEG/core/[cutgather, shotlog]

func shotAt(us: int64, file = -1'i64): Shot =
  result = Shot(timeUtcUs: some(us), sourceLine: NaN, shotPoint: NaN, x: NaN, y: NaN,
    z: NaN)
  if file >= 0: result.fileNumber = some(file)

func untimed(file: int64): Shot =
  Shot(fileNumber: some(file), sourceLine: NaN, shotPoint: NaN, x: NaN, y: NaN, z: NaN)

const T0 = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC

type
  Src = ref object
    ## Rows held in memory, counting what the buffer asks for.
    data: seq[seq[float32]]
    keys: seq[TraceKeys] # kept here: the meta's rows view these, they are not copied
    counts: seq[int]
    calls, fetched: int
    failRow: int

const
  Dt = 2.0 # ms
  StreamT0 = 1.7e9 + 0.123

func stream(k: int): float32 = float32(sin(0.05 * float64(k)) + 0.001 * float64(k))

func timeOf(k: float64): float64 = StreamT0 + k * Dt / 1000

proc fetcher(src: Src): FetchProc =
  result = proc (row, first, count: int, dst: var openArray[float32]): bool =
    inc src.calls
    src.fetched += count
    if row == src.failRow:
      false
    else:
      for j in 0 ..< count: dst[j] = src.data[row][first + j]
      true

proc makeSrc(spans: openArray[(int, int)], comps = 1): Src =
  ## `comps` rows per `(first, count)` span of the stream (row = span * comps +
  ## component).
  result = Src(failRow: -1)
  for (first, n) in spans:
    for c in 0 ..< comps:
      var r = newSeq[float32](n)
      for j in 0 ..< n: r[j] = stream(first + j)
      result.data.add r
      var k = initTraceKeys()
      k.status = tsLive
      k.time = timeOf(float64(first))
      k.t0Ms = 0
      k.intervalUs = Dt * 1000
      k.rcvLine = 1
      k.rcvPoint = float64(c + 1)
      k.rcvX = 10
      k.rcvY = 0
      result.keys.add k
      result.counts.add n

proc metaOf(src: Src): ChunkMeta =
  initChunkMeta(rowsOf(src.keys, src.counts), dtMs = Dt)

func window(samples: int): SliceWindow =
  SliceWindow(startMs: 0, lengthMs: float64(samples) * Dt)

proc main*() =
  block utc_not_shifted:
    let s = sliceShotOf(shotAt(T0 + 250_000))
    doAssert s.timeUsKnown
    doAssert s.timeUs == T0 + 250_000
    doAssert s.time == 1_772_323_200.25, "POSIX seconds by hand"

  block field_mapping:
    var sh = shotAt(T0, 77)
    sh.sourceLine = 12.0
    sh.shotPoint = 345.0
    sh.pointIndex = some(3'i64)
    sh.x = 1.5
    sh.y = 2.5
    sh.z = -3.5
    let s = sliceShotOf(sh)
    doAssert s.id == 77.0
    doAssert s.srcLine == 12.0 and s.srcPoint == 345.0 and s.srcIndex == 3
    doAssert s.srcX == 1.5 and s.srcY == 2.5 and s.srcZ == -3.5

  block nan_kept:
    let s = sliceShotOf(shotAt(T0))
    doAssert s.id.isNaN
    doAssert s.srcLine.isNaN and s.srcPoint.isNaN
    doAssert s.srcX.isNaN and s.srcY.isNaN and s.srcZ.isNaN
    doAssert s.srcIndex == 0

  block untimed_dropped:
    let c = shotsInTime([shotAt(T0 + 2_000_000, 2), untimed(9), shotAt(T0, 1)])
    doAssert c.dropped == 1
    doAssert c.shots.len == 2
    doAssert c.rows == @[2, 0]
    doAssert c.shots[0].timeUs == T0

  block equal_times_stable:
    let c = shotsInTime([shotAt(T0, 5), shotAt(T0, 6), shotAt(T0 - 1, 4)])
    doAssert c.rows == @[2, 0, 1]
    doAssert c.duplicateTimes == 1

  block numbers_from_file:
    let c = shotsInTime([shotAt(T0 + 2, 20), shotAt(T0, 10), shotAt(T0 + 1, 15)])
    doAssert c.increasing
    let r = recordNumbers(c)
    doAssert r.fromFileNumber
    doAssert r.numbers == @[10, 15, 20]

  block numbers_sequence:
    let c = shotsInTime([shotAt(T0 + 2, 10), shotAt(T0, 20), shotAt(T0 + 1, 15)])
    doAssert not c.increasing
    let r = recordNumbers(c)
    doAssert not r.fromFileNumber
    doAssert r.numbers == @[1, 2, 3]
    # a missing or fractional number also falls back
    doAssert not recordNumbers(shotsInTime([shotAt(T0, 1), shotAt(T0 + 1)])).fromFileNumber
    doAssert not recordNumbers(shotsInTime([shotAt(T0, 1), shotAt(T0 + 1,
        0x1000000)])).fromFileNumber

  block size_formulas:
    var o = initCutOptions(1000.0)
    # 2 shots, 3 traces, 250 samples: record 256; trace 20 + 64 + 1000 = 1084
    doAssert estimateBytes(o, 2, 3, 250, false, false, false) == 2 * 256 + 6 * 1084
    # source station +32, source XY +96 per record; receiver XY: 5 extensions
    doAssert estimateBytes(o, 2, 3, 250, true, true, true) ==
      2 * (256 + 32 + 96) + 6 * (20 + 160 + 1000)
    o.standard = csSegy
    doAssert estimateBytes(o, 2, 3, 250, true, true, true) == 3600 + 3200 + 6 * (480 + 1000)
    doAssert estimateBytes(o, 3_000_000, 4, 500_000, false, false, false) >
      int64(high(int32)), "int64 throughout"

  block point_index_counted:
    var a = shotAt(T0, 1)
    a.pointIndex = some(300'i64)
    var b = shotAt(T0 + 1, 2)
    b.pointIndex = some(3'i64)
    var c = shotAt(T0 + 2, 3)
    c.pointIndex = some(-1'i64)
    let sh = shotsInTime([a, b, c, untimed(9)])
    doAssert sh.pointIndexOutOfRange == 2, $sh.pointIndexOutOfRange

  block check_options:
    doAssert checkOptions(initCutOptions(1000.0), 2.0) == ""
    doAssert checkOptions(initCutOptions(1001.0), 2.0).len > 0, "not whole"
    doAssert checkOptions(initCutOptions(0.0), 2.0).len > 0, "zero"
    doAssert checkOptions(initCutOptions(-4.0), 2.0).len > 0, "negative"
    doAssert checkOptions(initCutOptions(3_000_000.0), 2.0).len > 0, "too long"
    doAssert checkOptions(initCutOptions(1000.0, startMs = 2_147_000.0), 2.0).len > 0
    doAssert checkOptions(initCutOptions(1000.0), 0.0).len > 0

  block piecewise_equals_whole_block:
    # A gap (197 ..< 210), an overlap (97 ..< 100) where the later row differs,
    # and every alignment.
    let spans = [(0, 100), (97, 100), (210, 100)]
    let src = makeSrc(spans)
    for j in 0 ..< 3: src.data[1][j] = float32(10 + j)
    let meta = metaOf(src)
    let shots = [initSliceShot(timeOf(90.4), 1), initSliceShot(timeOf(190), 2),
      initSliceShot(timeOf(20.25), 3), initSliceShot(timeOf(250.6), 4),
      initSliceShot(timeOf(5), 5)]
    for align in [saNearest, saLinear, saCubic, saSinc]:
      let plan = planSlices(meta, shots, window(40), soShotRecords, align)
      doAssert plan.overlaps.len == 1
      var block0 = zeros[float32](3, 100)
      for i in 0 ..< 3:
        for j in 0 ..< spans[i][1]: block0[i, j] = src.data[i][j]
      var whole = zeros[float32](plan.len, plan.samples)
      var wholeReport = initSliceReport(plan)
      var ws = initWorkspace()
      ws.reserve(sliceWorkspace(float32, plan))
      extractInto(plan, block0, whole, meta, wholeReport, ws)
      var report = initSliceReport(plan)
      prepareSliceReport(plan, report)
      var buf = initSourceBuffer()
      let fetch = fetcher(src)
      var dst = newSeq[float32](plan.samples)
      for t in 0 ..< plan.len:
        doAssert not cutOne(plan, t, buf, fetch, dst, report, ws)
        for j in 0 ..< plan.samples:
          doAssert cast[uint32](dst[j]) == cast[uint32](whole[t, j]),
            $align & " trace " & $t & " column " & $j
        doAssert report.gapSamples(t) == wholeReport.gapSamples(t)
      doAssert checkOverlaps(plan, buf, fetch, report, final = true) == 1
      doAssert report.overlapCheck(0) == wholeReport.overlapCheck(0)
      doAssert report.overlapCheck(0).status == osMismatch
      doAssert report.gapSamples(1) > 0

  block reuse_and_bounded_memory:
    # 60 windows of 1000 samples, 250 apart: each sample is in four windows.
    let spans = [(0, 17000)]
    let src = makeSrc(spans)
    let meta = metaOf(src)
    var shots: seq[SliceShot]
    for i in 0 ..< 60: shots.add initSliceShot(timeOf(float64(i * 250)), float64(i + 1))
    let plan = planSlices(meta, shots, window(1000), soShotRecords, saNearest)
    var report = initSliceReport(plan)
    prepareSliceReport(plan, report)
    var ws = initWorkspace()
    var buf = initSourceBuffer()
    let fetch = fetcher(src)
    var dst = newSeq[float32](plan.samples)
    var peak = 0
    for t in 0 ..< plan.len:
      doAssert not cutOne(plan, t, buf, fetch, dst, report, ws)
      for j in 0 ..< plan.samples: doAssert dst[j] == stream(t * 250 + j)
      peak = max(peak, buf.heldSamples)
      if t + 1 < plan.len:
        var next = 0
        for pc in plan.pieces(t + 1): next = pc.first
        buf.evictBefore(0, evictable(plan, buf, report, 0, next))
    doAssert src.fetched <= 17000, "fetched " & $src.fetched & " samples"
    doAssert src.fetched == 59 * 250 + 1000
    doAssert peak <= 1000 + 250, "held " & $peak

  block overlap_check_and_eviction_rule:
    let spans = [(0, 100), (97, 100)]
    let src = makeSrc(spans)
    let meta = metaOf(src)
    let plan = planSlices(meta, [initSliceShot(timeOf(90), 1)], window(20),
      soShotRecords, saNearest)
    var report = initSliceReport(plan)
    prepareSliceReport(plan, report)
    var ws = initWorkspace()
    var buf = initSourceBuffer()
    let fetch = fetcher(src)
    var dst = newSeq[float32](20)
    doAssert not cutOne(plan, 0, buf, fetch, dst, report, ws)
    # Nothing pending, yet the unchecked tail of row 0 is still needed, and
    # row 1 from its start.
    doAssert evictable(plan, buf, report, 0, 5000) == 97
    doAssert evictable(plan, buf, report, 1, 5000) == 0
    doAssert evictable(plan, buf, report, 0, 50) == 50
    let before = src.fetched
    doAssert checkOverlaps(plan, buf, fetch, report, final = true) == 1
    doAssert report.overlapCheck(0).status == osMatch
    doAssert src.fetched == before + 3, "only the tail of row 0 is read again"
    doAssert checkOverlaps(plan, buf, fetch, report, final = true) == 0, "checked once"
    doAssert evictable(plan, buf, report, 0, 5000) == 5000
    # A differing later row is reported with its count.
    src.data[1][1] = 99
    src.data[1][2] = 98
    var buf2 = initSourceBuffer()
    var report2 = initSliceReport(plan)
    prepareSliceReport(plan, report2)
    doAssert not cutOne(plan, 0, buf2, fetch, dst, report2, ws)
    doAssert checkOverlaps(plan, buf2, fetch, report2, final = true) == 1
    let c = report2.overlapCheck(0)
    doAssert c.status == osMismatch and c.differing == 2 and report2.mismatches == 1

  block failed_fetch_is_zeros:
    let spans = [(0, 100), (97, 100)]
    let src = makeSrc(spans)
    src.failRow = 1
    let meta = metaOf(src)
    let plan = planSlices(meta, [initSliceShot(timeOf(90), 1)], window(20),
      soShotRecords, saNearest)
    var report = initSliceReport(plan)
    prepareSliceReport(plan, report)
    var ws = initWorkspace()
    var buf = initSourceBuffer()
    let fetch = fetcher(src)
    var dst = newSeq[float32](20)
    doAssert cutOne(plan, 0, buf, fetch, dst, report, ws), "the failed read is returned"
    doAssert report.failedSamples(0) == 13
    for j in 0 ..< 7: doAssert dst[j] == stream(90 + j)
    for j in 7 ..< 20: doAssert dst[j] == 0'f32
    doAssert buf.heldSamples == 7 and 1 notin [buf.heldRange(1).a]
    doAssert checkOverlaps(plan, buf, fetch, report, final = true) == 0
    doAssert report.overlapCheck(0).status == osNotRead

  block several_overlaps_checked_when_due:
    # Six rows of 1000 samples, 10-sample overlaps, a window of 200 every 50
    # samples, the job's eviction rule (the next shot's smallest first column
    # per row), checks only for overlaps that are due, then the rest. Each
    # sample is fetched once, the buffer never holds more than a window and an
    # overlap, and every overlap is compared.
    var spans: seq[(int, int)] = @[]
    for k in 0 ..< 6: spans.add (k * 990, 1000)
    let src = makeSrc(spans)
    let meta = metaOf(src)
    var shots: seq[SliceShot]
    var t = 0
    while t + 200 <= 5950:
      shots.add initSliceShot(timeOf(float64(t)), float64(shots.len + 1))
      t += 50
    let plan = planSlices(meta, shots, window(200), soShotRecords, saNearest)
    doAssert plan.overlaps.len == 5
    var report = initSliceReport(plan)
    prepareSliceReport(plan, report)
    var ws = initWorkspace()
    var buf = initSourceBuffer()
    let fetch = fetcher(src)
    var dst = newSeq[float32](plan.samples)
    var peak = 0
    for s in 0 ..< plan.len:
      doAssert not cutOne(plan, s, buf, fetch, dst, report, ws)
      for j in 0 ..< plan.samples: doAssert dst[j] == stream(s * 50 + j)
      discard checkOverlaps(plan, buf, fetch, report)
      for row in plan.rowsNeeded:
        var next = high(int)
        if s + 1 < plan.len:
          for pc in plan.pieces(s + 1):
            if pc.row == row and pc.count > 0: next = min(next, pc.first)
        buf.evictBefore(row, evictable(plan, buf, report, row, next))
      peak = max(peak, buf.heldSamples)
    discard checkOverlaps(plan, buf, fetch, report, final = true)
    for i in 0 ..< 5: doAssert report.overlapCheck(i).status == osMatch, "overlap " & $i
    doAssert src.fetched <= 6000, "fetched " & $src.fetched & " of 6000"
    doAssert peak <= 200 + 10 + 10, "held " & $peak

  block failed_overlap_neither_retried_nor_pinned:
    # Row 2 cannot be read: the overlaps it is in stay osNotRead, are asked
    # for once, and do not keep the rows pinned.
    var spans: seq[(int, int)] = @[]
    for k in 0 ..< 4: spans.add (k * 990, 1000)
    let src = makeSrc(spans)
    src.failRow = 2
    let meta = metaOf(src)
    var shots: seq[SliceShot]
    var t = 0
    while t + 200 <= 3900:
      shots.add initSliceShot(timeOf(float64(t)), float64(shots.len + 1))
      t += 50
    let plan = planSlices(meta, shots, window(200), soShotRecords, saNearest)
    var report = initSliceReport(plan)
    prepareSliceReport(plan, report)
    var ws = initWorkspace()
    var buf = initSourceBuffer()
    var failedCalls = 0
    let inner = fetcher(src)
    let fetch: FetchProc = proc (row, first, count: int, dst: var openArray[float32]): bool =
      if row == 2: inc failedCalls
      inner(row, first, count, dst)
    var dst = newSeq[float32](plan.samples)
    var peak = 0
    for s in 0 ..< plan.len:
      discard cutOne(plan, s, buf, fetch, dst, report, ws)
      discard checkOverlaps(plan, buf, fetch, report)
      for row in plan.rowsNeeded:
        var next = high(int)
        if s + 1 < plan.len:
          for pc in plan.pieces(s + 1):
            if pc.row == row and pc.count > 0: next = min(next, pc.first)
        buf.evictBefore(row, evictable(plan, buf, report, row, next))
      peak = max(peak, buf.heldSamples)
    discard checkOverlaps(plan, buf, fetch, report, final = true)
    doAssert report.overlapCheck(0).status == osMatch
    doAssert report.overlapCheck(1).status == osNotRead and
      report.overlapCheck(2).status == osNotRead
    doAssert failedCalls <= plan.len div 2, "row 2 was asked for " & $failedCalls & " times"
    doAssert buf.heldSamples == 0, "held " & $buf.heldSamples & " at the end"
    doAssert peak <= 200 + 10 + 10, "held " & $peak

  block buffer_stays_bounded_over_a_long_run:
    # 200 rows of 100 samples a component, 10 samples of overlap, the job's
    # bookkeeping after every shot. Fails when an overlap behind another is
    # compared only one per shot, so a window that crosses several source
    # traces holds each later trace whole to the end ("held 9840 of at most 480").
    for (w, step, comps) in [(450, 200, 1), (450, 500, 1), (300, 300, 4)]:
      var spans: seq[(int, int)] = @[]
      for k in 0 ..< 200: spans.add (k * 90, 100)
      let src = makeSrc(spans, comps)
      let meta = metaOf(src)
      var shots: seq[SliceShot]
      var t = 0
      while t + w <= 200 * 90:
        shots.add initSliceShot(timeOf(float64(t)), float64(shots.len + 1))
        t += step
      let plan = planSlices(meta, shots, window(w), soShotRecords, saNearest)
      var report = initSliceReport(plan)
      prepareSliceReport(plan, report)
      var ws = initWorkspace()
      var buf = initSourceBuffer()
      let inner = fetcher(src)
      var seen = newSeq[seq[bool]](src.data.len)
      var again = 0
      let fetch: FetchProc = proc (row, first, count: int, dst: var openArray[float32]): bool =
        if seen[row].len == 0: seen[row] = newSeq[bool](100)
        for j in first ..< first + count:
          if seen[row][j]: inc again
          seen[row][j] = true
        inner(row, first, count, dst)
      var dst = newSeq[float32](plan.samples)
      var peak = 0
      let bound = comps * (w + 10 + 20)
      for s in 0 ..< plan.shotCount:
        var touched: seq[int] = @[]
        for r in 0 ..< comps:
          for pc in plan.pieces(s * comps + r):
            if pc.row >= 0 and pc.row notin touched: touched.add pc.row
          doAssert not cutOne(plan, s * comps + r, buf, fetch, dst, report, ws)
        peak = max(peak, buf.heldSamples)
        discard settleShot(plan, buf, fetch, report, touched, s)
        peak = max(peak, buf.heldSamples)
      doAssert peak <= bound, "held " & $peak & " of at most " & $bound
      doAssert buf.heldSamples == 0, "held " & $buf.heldSamples & " after the last shot"
      discard checkOverlaps(plan, buf, fetch, report, final = true)
      doAssert again == 0, $again & " samples fetched again"
      for i, o in plan.overlaps:
        if o.earlier in plan.rowsNeeded and o.later in plan.rowsNeeded:
          doAssert report.overlapCheck(i).status != osNotRead, "overlap " & $i

  block bookkeeping_cost_follows_the_shot:
    # 4000 shots over 4001 rows with 4000 overlaps and an in-memory fetch.
    # Fails when every shot walks every overlap (about 3.6 s in an optimised
    # build, far more in a debug build: "took 31 s").
    var spans: seq[(int, int)] = @[]
    for k in 0 ..< 4001: spans.add (k * 90, 100)
    let src = makeSrc(spans)
    let meta = metaOf(src)
    var shots: seq[SliceShot]
    var t = 0
    while t + 50 <= 4001 * 90:
      shots.add initSliceShot(timeOf(float64(t)), float64(shots.len + 1))
      t += 90
    let plan = planSlices(meta, shots, window(50), soShotRecords, saNearest)
    doAssert plan.overlaps.len >= 4000 and plan.shotCount >= 3990
    var report = initSliceReport(plan)
    prepareSliceReport(plan, report)
    var ws = initWorkspace()
    var buf = initSourceBuffer()
    let fetch = fetcher(src)
    var dst = newSeq[float32](plan.samples)
    var spent = initDuration()
    var peak = 0
    for s in 0 ..< plan.shotCount:
      var touched: seq[int] = @[]
      for pc in plan.pieces(s):
        if pc.row >= 0 and pc.row notin touched: touched.add pc.row
      doAssert not cutOne(plan, s, buf, fetch, dst, report, ws)
      let t0 = getMonoTime()
      discard settleShot(plan, buf, fetch, report, touched, s)
      spent += getMonoTime() - t0
      peak = max(peak, buf.heldSamples)
    discard checkOverlaps(plan, buf, fetch, report, final = true)
    doAssert spent < initDuration(seconds = 5), "took " & $spent.inMilliseconds & " ms"
    doAssert peak <= 50 + 10 + 20, "held " & $peak
    var compared = 0
    for i in 0 ..< plan.overlaps.len:
      if report.overlapCheck(i).status == osMatch: inc compared
    doAssert compared >= 3990, "compared " & $compared

  block failed_overlap_releases_its_rows:
    # Row 5 cannot be read, so the overlaps it is in are given up. The tail of
    # row 4 (held for the overlap) must go with them, not stay to the end.
    # Fails with "held 10 after the last shot".
    var spans: seq[(int, int)] = @[]
    for k in 0 ..< 20: spans.add (k * 990, 1000)
    let src = makeSrc(spans)
    src.failRow = 5
    let meta = metaOf(src)
    var shots: seq[SliceShot]
    var t = 0
    while t + 200 <= 19 * 990:
      shots.add initSliceShot(timeOf(float64(t)), float64(shots.len + 1))
      t += 50
    let plan = planSlices(meta, shots, window(200), soShotRecords, saNearest)
    var report = initSliceReport(plan)
    prepareSliceReport(plan, report)
    var ws = initWorkspace()
    var buf = initSourceBuffer()
    let fetch = fetcher(src)
    var dst = newSeq[float32](plan.samples)
    for s in 0 ..< plan.shotCount:
      var touched: seq[int] = @[]
      for pc in plan.pieces(s):
        if pc.row >= 0 and pc.row notin touched: touched.add pc.row
      discard cutOne(plan, s, buf, fetch, dst, report, ws)
      discard settleShot(plan, buf, fetch, report, touched, s)
    doAssert buf.heldSamples == 0, "held " & $buf.heldSamples & " after the last shot"

  echo "tcutgather ok"

when isMainModule:
  main()
