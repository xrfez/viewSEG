## A correlated view's reader fills tiles with `correlateRead`, in listen time.
##
## The same `ReadRequest` on the view and on the in-memory file `correlateWork`
## writes must match, including a stride and an auxiliary trace. The layout's
## sample count is the listen time, not the raw record. Returning the raw
## samples fails. The virtual path is not mapped. A second identical request
## allocates nothing.
##
## Seen to fail, then restored: the layout taken from the raw record
## (`layout samples 1000 are the raw record, not the listen time`); zeros
## written instead of the correlation (`window 0 ..< 64 sample 0`).
## With the kept window sliced past a decoded row of length 0, a window
## wholly past the listen time killed the reader (`window past the end`,
## SIGSEGV in `decimatePeakInto`). With that slice longer than a short
## decoded row, `window overhanging the listen time sample 10` disagreed.
## A field-less request of a dead trace, asked again from the spare, had
## `isDead` false the second time (`a tile from the spare does not mark the dead trace`).
## `correlateBlock` equals `correlateRead` row by row, bit for bit (seen to fail with the
## reference auxiliary's time shift left out, and with the auxiliary traces' raw rows
## treated as correlated).
## A file cut short while a view of it was open posted only the generic
## count (`1 of the 5 traces shown could not be read`), not that it was
## cut short.

import std/[atomics, math, monotimes, os, strutils, times]
import parseSEG
import processSEG
import viewSEG/core/[correlatejobs, correlateread, filesystem, inbox, jobs, log, panels, reader,
  session, tiles, viewport]
import utils/waiting

const
  DtMs = 2.0
  AuxLeadMs = 500.0 # the shift given to the marked reference trace
  Record = 1000
  SweepLen = 200
  Listen = 800
  Delays = [40, 100, 200]
  RefAux = 3
  OtherAux = 4

var
  watchVirt, watchRaw: cstring
  virtMaps, rawMaps: Atomic[int]

proc keep(s: string): cstring =
  result = cast[cstring](alloc(s.len + 1))
  if s.len > 0: copyMem(result, unsafeAddr s[0], s.len)
  result[s.len] = '\0'

proc samePath(path: string; watched: cstring): bool {.gcsafe.} =
  if watched == nil: return false
  var i = 0
  while i < path.len:
    let c = watched[i]
    if c == '\0' or c != path[i]: return false
    inc i
  watched[path.len] == '\0'

proc countMap(op: FsOp; path: string) {.gcsafe.} =
  if op != foMapped: return
  if samePath(path, watchVirt): discard virtMaps.fetchAdd(1)
  elif samePath(path, watchRaw): discard rawMaps.fetchAdd(1)

proc delayedSweep(sweep: openArray[float32]; samples, delay: int): seq[float32] =
  result = newSeq[float32](samples)
  for i in 0 ..< samples:
    let j = i - delay
    if j >= 0 and j < sweep.len: result[i] = sweep[j]

proc writeRaw(path: string; sweep: openArray[float32]; dead = -1) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
    format: st5, text: @["C01 correlated view reader"]))
  for i in 0 .. 4:
    var buf: seq[float32]
    var k = initTraceKeys()
    if i == dead:
      buf = delayedSweep(sweep, Record, Delays[i])
      (k.traceCode, k.status) = (1'i16, tsDead)
    elif i < Delays.len:
      buf = delayedSweep(sweep, Record, Delays[i])
      (k.traceCode, k.status) = (1'i16, tsLive)
    elif i == RefAux:
      buf = delayedSweep(sweep, Record, 0)
      (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    else:
      buf = newSeq[float32](Record)
      for j in 0 ..< Record: buf[j] = float32(j + 1)
      (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    k.record = 7.0
    k.channel = float64(i + 1)
    k.t0Ms = 0.0
    k.intervalUs = DtMs * 1000.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the raw file did not close"

proc spec(path: string): JobSpec =
  JobSpec(title: "Correlate " & path.extractFilename, lane: jlBackground, reads: @[path],
    cancellable: true)

proc finish(jobs: Jobs; id: JobId): JobState =
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the correlation did not finish"
  jobs.info(id).get.state

proc correlate(file: ptr SeismicFile; path: string; sweep: seq[float32]): CorrelateResult =
  var jobs = initJobs()
  try:
    let id = jobs.submit(spec(path), correlateWork(CorrelateAsk(
      file: file, path: path, reference: sweep, referenceDtMs: DtMs,
      marked: marksOf([RefAux], AuxLeadMs)), addr result))
    doAssert finish(jobs, id) == jsDone, result.failure
  finally:
    jobs.stop()
  doAssert result.ok, result.failure

proc allocations(): int =
  cast[tuple[allocs, deallocs: int]](getAllocStats()).allocs

proc ask(first, count, stride, firstSample, samples: int): ReaderRequest =
  ReaderRequest(read: ReadRequest(gen: 1, first: first, count: count, stride: stride,
    firstSample: firstSample, samples: samples, decimation: 1), clipPercentile: NaN)

proc sourceOf(s: Session; view: ref CorrelateView): ReaderSource =
  ReaderSource(gen: 1, file: s.filePtr, path: s.path, size: s.size, traces: 0 ..< s.len,
    filter: TraceFilter(seismic: true, auxiliary: true), view: view)

proc noteOf(m: Msg): string =
  if m.kind == mkLog: m.entry.text else: ""

proc awaitLayouts(box: Inbox): (PanelLayout, PanelLayout) =
  var viewL, memL: PanelLayout
  var gotV, gotM = false
  var why = ""
  doAssert waitUntil(block:
    var got: seq[Msg]
    box.drainInto(got)
    for m in got:
      let text = noteOf(m)
      if text.len > 0: why.add text & "\n"
      if m.kind == mkLayout and m.panel == PanelId(1):
        viewL = m.layout
        gotV = true
      elif m.kind == mkLayout and m.panel == PanelId(2):
        memL = m.layout
        gotM = true
    gotV and gotM
  ), "a layout did not arrive: " & why
  (viewL, memL)

proc awaitTiles(box: Inbox): (Tile, Tile) =
  var viewT, memT: Tile
  var gotV, gotM = false
  var why = ""
  doAssert waitUntil(block:
    var got: seq[Msg]
    box.drainInto(got)
    for m in got:
      let text = noteOf(m)
      if text.len > 0: why.add text & "\n"
      if m.kind == mkTile and m.tile.panel == PanelId(1):
        viewT = m.tile
        gotV = true
      elif m.kind == mkTile and m.tile.panel == PanelId(2):
        memT = m.tile
        gotM = true
    gotV and gotM
  ), "a tile did not arrive: " & why
  (viewT, memT)

proc sameSamples(a, b: Tile; what: string) =
  doAssert a.failed == b.failed, what & " failed " & $a.failed & " vs " & $b.failed
  doAssert a.data.len == b.data.len, what & " length " & $a.data.len & " vs " & $b.data.len
  for i, v in a.data:
    doAssert v == b.data[i], what & " sample " & $i

const
  BlockTraces = 48
  BlockRefs = [0, 8, 16, 24, 32, 40, 21]
  OddAux = [21, 37]

proc blockLength(i: int): int =
  ## Auxiliary traces of the block file: shorter and longer than the record.
  if i mod 8 == 0 and i mod 16 == 8: Record - 400
  elif i mod 8 == 0 and i mod 32 == 16: Record + 300
  elif i mod 8 == 5 and i mod 16 == 13: Record - 300
  elif i mod 8 == 5 and i mod 16 == 5 and i > 20: Record + 200
  else: Record

proc writeBlockFile(path: string; sweep: openArray[float32]) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
    format: st5, text: @["C01 correlated block"]))
  for i in 0 ..< BlockTraces:
    var k = initTraceKeys()
    var len = Record
    var buf: seq[float32]
    if i in BlockRefs:
      (k.traceCode, k.status) = (5'i16, tsAuxiliary)
      len = blockLength(i)
      buf = delayedSweep(sweep, len, 2 * (i mod 7))
    elif i mod 8 == 5:
      (k.traceCode, k.status) = (6'i16, tsAuxiliary)
      len = blockLength(i)
      buf = newSeq[float32](len)
      for j in 0 ..< len: buf[j] = float32(j + i)
    elif i mod 8 == 3:
      (k.traceCode, k.status) = (1'i16, tsDead)
      buf = delayedSweep(sweep, Record, 30)
    else:
      (k.traceCode, k.status) = (1'i16, tsLive)
      buf = delayedSweep(sweep, Record, 10 + 13 * (i mod 11))
      for j in 0 ..< Record: buf[j] += 0.01'f32 * sin(float32(j * (i + 1)) * 0.37'f32)
    if i in OddAux: k.intervalUs = 4.0 * DtMs * 1000.0
    else: k.intervalUs = DtMs * 1000.0
    k.record = 7.0
    k.channel = float64(i + 1)
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the block file did not close"

proc checkBlockRows() =
  ## The rows of a block are bounded by bytes: 32 MiB of raw plus correlated rows,
  ## 8 to 256 of them, one when even 8 would pass 256 MiB.
  doAssert blockRows(1000, 800) == BlockMostRows, "2 s at 2 ms is not a full block"
  let minute = blockRows(60000, 50000)
  doAssert minute in 60 .. 80, "60 s at 1 ms gives " & $minute & " rows"
  doAssert blockRows(600000, 500000) == BlockLeastRows, "10 min at 1 ms is not the least block"
  doAssert blockRows(300000, 290000) == 14, "10 min at 2 ms gives " & $blockRows(300000, 290000)
  doAssert blockRows(40_000_000, 39_000_000) == 1, "an absurd record is not one row"
  doAssert blockRows(0, 0) == BlockMostRows
  doAssert blockRows(int.high, int.high) == 1, "an overflowing record is not one row"

proc checkBlocks(dir: string; sweep: seq[float32]) =
  ## `correlateBlock` against `correlateRead` row by row, bit for bit.
  let path = dir / "block.sgy"
  writeBlockFile(path, sweep)
  var f = openSeismic(path, keys = true)
  defer: f.close()
  let built = initCorrelateView(addr f, sweep, DtMs, marksOf(BlockRefs, AuxLeadMs))
  doAssert built.refusal.len == 0, built.refusal
  let view = built.view
  doAssert view.odd.len == OddAux.len, "the odd traces were not found"
  var traces: seq[int]
  for i in 0 ..< BlockTraces: traces.add i
  traces.add [-1, 9999, 5, 0, 21, 5] # not traces of the file, then repeats
  var pool = newProcessPool(3)
  var one = newWorkspace(view)
  var ws = newWorkspace(view)
  for (first, count) in [(0, Listen), (300, 100), (-20, 60), (Listen - 30, 60), (Listen + 5, 10),
      (0, 1)]:
    var want = newSeq[float32](traces.len * count)
    var wantFailed: seq[int]
    for r, t in traces:
      var row = newSeq[float32](count)
      correlateRead(view, addr f, [t], first, count, row, one)
      if one.failed.len > 0: wantFailed.add r
      for j in 0 ..< count: want[r * count + j] = row[j]
    for size in [traces.len, blockRows(view), 20, BlockLeastRows, 1]:
      var got = newSeq[float32](want.len)
      var gotFailed: seq[int]
      var at = 0
      while at < traces.len:
        let n = min(size, traces.len - at)
        var part = newSeq[float32](n * count)
        correlateBlock(view, addr f, traces.toOpenArray(at, at + n - 1), first, count, part,
          ws, pool)
        for r in ws.failed: gotFailed.add at + r
        for j in 0 ..< part.len: got[at * count + j] = part[j]
        at += n
      let what = "window " & $first & " +" & $count & " blocks of " & $size
      doAssert gotFailed == wantFailed, what & " failed " & $gotFailed & " vs " & $wantFailed
      for i in 0 ..< want.len:
        doAssert cast[uint32](got[i]) == cast[uint32](want[i]), what & " row " &
          $(i div count) & " sample " & $(i mod count)

proc main*() =
  let dir = getTempDir() / ("tcorrview-" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  let path = dir / "raw.sgy"
  let sweep = linearSweep(8.0, 80.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
  doAssert sweep.len == SweepLen
  writeRaw(path, sweep)
  checkBlockRows()
  checkBlocks(dir, sweep)
  var rawFile = openSeismic(path, keys = true)
  let raw = newSession(path, rawFile)
  let built = initCorrelateView(raw.filePtr, sweep, DtMs, marksOf([RefAux], AuxLeadMs))
  doAssert built.refusal.len == 0, built.refusal
  let view = asCorrelatedView(raw, built.view)
  let slot = correlate(raw.filePtr, path, sweep)
  let mem = slot.opened
  defer:
    discard view.close()
    discard mem.close()
    discard raw.close()

  watchVirt = keep(view.path)
  watchRaw = keep(path)
  defer:
    dealloc watchVirt
    dealloc watchRaw
  virtMaps.store(0)
  rawMaps.store(0)
  setFsHook(countMap)
  defer: setFsHook(nil)

  var jobs = initJobs()
  defer: jobs.stop()
  let box = initInbox()
  var viewRd = newPanelReader(PanelId(1), box.poster, jobs.holdRelease)
  var memRd = newPanelReader(PanelId(2), box.poster, jobs.holdRelease)
  defer:
    viewRd.stop()
    memRd.stop()
  doAssert jobs.hold(view.path), "the view path could not be held"
  doAssert jobs.hold(mem.path), "the correlated file could not be held"
  viewRd.show(sourceOf(view, view.correlatedView))
  memRd.show(sourceOf(mem, nil))

  let (viewLayout, memLayout) = awaitLayouts(box)
  doAssert viewLayout.samples == Listen, "layout samples " & $viewLayout.samples &
    " are the raw record, not the listen time"
  doAssert viewLayout.dtMs == DtMs, "layout interval " & $viewLayout.dtMs
  doAssert not viewLayout.noInterval, "the listen interval was dropped"
  doAssert viewLayout.traces == 5, "layout traces " & $viewLayout.traces
  doAssert memLayout.samples == viewLayout.samples, "the in-memory layout has another length"
  doAssert memLayout.dtMs == viewLayout.dtMs, "the in-memory layout has another interval"

  proc pair(req: ReaderRequest; what: string) =
    viewRd.request(req)
    memRd.request(req)
    let (gotV, gotM) = awaitTiles(box)
    sameSamples(gotV, gotM, what)
    doAssert gotV.failed == 0, what & " marked " & $gotV.failed & " traces failed"

  pair(ask(0, 5, 1, 0, 64), "window 0 ..< 64")
  pair(ask(0, 5, 1, 300, 100), "window 300 ..< 400")
  pair(ask(0, 5, 1, Listen - 50, 50), "window " & $(Listen - 50) & " ..< " & $Listen)
  pair(ask(0, 3, 2, 0, 64), "stride 2")
  pair(ask(RefAux, 2, 1, 0, 64), "auxiliary traces")

  block windowPastTheEnd:
    let req = ask(0, 2, 1, Listen + 10, 20)
    viewRd.request(req)
    memRd.request(req)
    let (gotV, gotM) = awaitTiles(box)
    sameSamples(gotV, gotM, "window past the end")
    doAssert gotV.failed == 0, "window past the end marked " & $gotV.failed & " failed"
    doAssert gotV.data.len == 40, "window past the end length " & $gotV.data.len
    for v in gotV.data:
      doAssert v == 0'f32, "a window past the listen time is not zero"

  block windowOverhangs:
    let req = ask(0, 2, 1, Listen - 10, 40)
    viewRd.request(req)
    memRd.request(req)
    let (gotV, gotM) = awaitTiles(box)
    sameSamples(gotV, gotM, "window overhanging the listen time")
    doAssert gotV.failed == 0, "overhang marked " & $gotV.failed & " failed"
    doAssert gotV.columns == 40, "overhang columns " & $gotV.columns
    let head = ask(0, 2, 1, Listen - 10, 10)
    viewRd.request(head)
    memRd.request(head)
    let (headV, headM) = awaitTiles(box)
    sameSamples(headV, headM, "the last 10 listen samples")
    for row in 0 .. 1:
      for j in 0 ..< 10:
        doAssert gotV.data[row * 40 + j] == headV.data[row * 10 + j],
          "overhang sample " & $row & "," & $j
      for j in 10 ..< 40:
        doAssert gotV.data[row * 40 + j] == 0'f32, "overhang tail " & $row & "," & $j

  block notRaw:
    let req = ask(0, 1, 1, 0, Listen)
    viewRd.request(req)
    memRd.request(req)
    let (got, _) = awaitTiles(box)
    let rawRows = raw.filePtr[].readTraces(0 .. 0, 0 ..< Listen)
    var differ = false
    for j in 0 ..< Listen:
      if got.data[j] != rawRows[0, j]: differ = true
    doAssert differ, "trace 0 is the raw listen window, not the correlation"

  doAssert virtMaps.load == 0, "the virtual path was mapped " & $virtMaps.load & " times"
  doAssert rawMaps.load > 0, "the raw file was not advised"

  block secondRequestAllocatesNothing:
    let req = ask(0, 3, 1, 0, 64)
    let posted = viewRd.tilesPosted
    viewRd.request(req)
    doAssert waitUntil(viewRd.tilesPosted > posted), "the first of the pair did not arrive"
    var hold: seq[Msg]
    box.drainInto(hold)
    var saved: seq[float32]
    var saw = false
    for m in hold:
      if m.kind == mkTile and m.tile.panel == PanelId(1):
        saved = m.tile.data
        saw = true
    doAssert saw, "the first of the pair was not a tile"
    box.drainInto(hold) # the inbox takes this seq's capacity back
    let before = allocations()
    let again = viewRd.tilesPosted
    viewRd.request(req)
    let deadline = getMonoTime() + initDuration(seconds = 60)
    while viewRd.tilesPosted == again and getMonoTime() < deadline: discard
    doAssert viewRd.tilesPosted != again, "the second tile did not arrive"
    doAssert allocations() == before, "the second request allocated " &
      $(allocations() - before)
    var againMsgs: seq[Msg]
    box.drainInto(againMsgs)
    var matched = false
    for m in againMsgs:
      if m.kind == mkTile and m.tile.panel == PanelId(1):
        doAssert m.tile.data == saved, "the second tile's samples differ"
        matched = true
    doAssert matched, "the second tile was not posted"

  block deadTraceFromSpare:
    let deadPath = dir / "dead.sgy"
    writeRaw(deadPath, sweep, dead = 1)
    var deadFile = openSeismic(deadPath, keys = true)
    let deadRaw = newSession(deadPath, deadFile)
    let built = initCorrelateView(deadRaw.filePtr, sweep, DtMs, marksOf([RefAux], AuxLeadMs))
    doAssert built.refusal.len == 0, built.refusal
    let deadView = asCorrelatedView(deadRaw, built.view)
    defer:
      discard deadView.close()
      discard deadRaw.close()
    doAssert jobs.hold(deadView.path), "the dead view could not be held"
    var rd = newPanelReader(PanelId(3), box.poster, jobs.holdRelease)
    defer: rd.stop()
    rd.show(sourceOf(deadView, deadView.correlatedView))
    var laid = false
    doAssert waitUntil(block:
      var msgs: seq[Msg] = @[]
      box.drainInto(msgs)
      for m in msgs:
        if m.kind == mkLayout and m.panel == PanelId(3): laid = true
      laid
    ), "the dead view was not laid out"
    proc oneTile(): Tile =
      var tile: Tile
      var got = false
      var why = ""
      doAssert waitUntil(block:
        var msgs: seq[Msg] = @[]
        box.drainInto(msgs)
        for m in msgs:
          if m.kind == mkLog: why.add m.entry.text & "\n"
          if m.kind == mkTile and m.tile.panel == PanelId(3):
            tile = m.tile
            got = true
        got
      ), "a dead-trace tile did not arrive: " & why
      tile
    let req = ask(0, 2, 1, 0, 64)
    rd.request(req)
    let first = oneTile()
    doAssert first.isDead(1), "the first tile does not mark the dead trace"
    doAssert not first.isDead(0), "a live trace was marked dead"
    rd.request(req)
    let second = oneTile()
    doAssert second.isDead(1), "a tile from the spare does not mark the dead trace"
    doAssert not second.isDead(0), "the spare marked a live trace dead"

  block cutShortOnAView:
    let cutPath = dir / "cut.sgy"
    writeRaw(cutPath, sweep)
    var cutFile = openSeismic(cutPath, keys = true)
    let cutRawS = newSession(cutPath, cutFile)
    let built = initCorrelateView(cutRawS.filePtr, sweep, DtMs, marksOf([RefAux], AuxLeadMs))
    doAssert built.refusal.len == 0, built.refusal
    let cutView = asCorrelatedView(cutRawS, built.view)
    defer:
      discard cutView.close()
      discard cutRawS.close()
    doAssert jobs.hold(cutView.path), "the cut view could not be held"
    var rd = newPanelReader(PanelId(4), box.poster, jobs.holdRelease)
    defer: rd.stop()
    rd.show(sourceOf(cutView, cutView.correlatedView))
    var laid = false
    doAssert waitUntil(block:
      var msgs: seq[Msg] = @[]
      box.drainInto(msgs)
      for m in msgs:
        if m.kind == mkLayout and m.panel == PanelId(4): laid = true
      laid
    ), "the cut view was not laid out"
    let last = cutRawS.len - 1
    var indexed = openSeismic(cutPath)
    let start = indexed.index.entries[last].offset
    let size = getFileSize(cutPath)
    indexed.close()
    let mid = start + (size - start) div 2
    doAssert mid > start and mid < size, "the cut is not inside the last trace"
    writeFile(cutPath, readFile(cutPath)[0 ..< int(mid)])
    rd.request(ask(0, cutRawS.len, 1, 0, 64))
    var tile: Tile
    var notes: seq[string] = @[]
    var got = false
    doAssert waitUntil(block:
      var msgs: seq[Msg] = @[]
      box.drainInto(msgs)
      for m in msgs:
        if m.kind == mkLog: notes.add m.entry.text
        elif m.kind == mkTile and m.tile.panel == PanelId(4):
          tile = m.tile
          got = true
      got
    ), "the cut tile did not arrive"
    doAssert tile.failed == 1, "a cut file failed " & $tile.failed & " traces"
    for j in 0 ..< tile.columns:
      doAssert tile.data[last * tile.columns + j] == 0'f32, "the cut trace is not blank"
    var live = false
    for j in 0 ..< tile.columns:
      if tile.data[j] != 0'f32: live = true
    doAssert live, "an earlier trace was blanked"
    var said = false
    var shown = ""
    for n in notes:
      shown.add n & " | "
      if n.find("was cut short while it was open") >= 0: said = true
    doAssert said, "the cut was not reported: " & shown

  echo "tcorrview: ok"

when isMainModule:
  main()
