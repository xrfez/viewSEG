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

import std/[atomics, math, monotimes, os, times]
import parseSEG
import processSEG
import viewSEG/core/[correlatejobs, correlateread, filesystem, inbox, jobs, log, panels, reader,
  session, tiles, viewport]
import utils/waiting

const
  DtMs = 2.0
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

proc writeRaw(path: string; sweep: openArray[float32]) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
    format: st5, text: @["C01 correlated view reader"]))
  for i in 0 .. 4:
    var buf: seq[float32]
    var k = initTraceKeys()
    if i < Delays.len:
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
      referenceTraces: @[RefAux]), addr result))
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

proc main*() =
  let dir = getTempDir() / ("tcorrview-" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  let path = dir / "raw.sgy"
  let sweep = linearSweep(8.0, 80.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
  doAssert sweep.len == SweepLen
  writeRaw(path, sweep)
  var rawFile = openSeismic(path, keys = true)
  let raw = newSession(path, rawFile)
  let built = initCorrelateView(raw.filePtr, sweep, DtMs, [RefAux])
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

  echo "tcorrview: ok"

when isMainModule:
  main()
