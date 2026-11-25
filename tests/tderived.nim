## A derived session is shown and closed without the file system seeing its key.
##
## The raw file is opened, then an in-memory copy is bound with `asDerived`
## and shown in its place. The reader lays the panel out, the watch looks at
## the open files, and stepping to another file closes the derived view and
## the raw file.
##
## Seen to fail: with the watch or a reader handed the virtual key, "fs was
## asked about the virtual path". With listen facts not applied,
## `samplesPerTrace` of the view was not the written file's. With the estimate
## forced to 0, `abs(estimate - actual) <= headers` failed (estimate 0,
## actual 25200, headers 9200). With raw close ignoring open views, `not
## close(raw)` failed: the raw file closed while a view existed. With the
## view's destructor not dropping its count, `close(raw2)` failed after the
## view was dropped. With the hold not lowering the count, `close(raw)` failed
## after the view was closed: the raw file stayed open. Copying a view hold is
## a compile error (`=copy` and `=dup` are `{.error.}`). The hold is private,
## so this file cannot name it in `compiles`. With a SEG-D estimate taken from
## the source map, `estimate - actual <= oneHeaderSet` failed: estimate 20772,
## actual 16676, header set 192 (the 4096-byte external header). With listen
## time still labelled "Samples per trace", `summaryValue(lines, "Samples per
## trace (correlated)") == grouped(Listen)` failed.

import std/[locks, math, monotimes, os, sequtils, strutils, times]
import parseSEG
import processSEG
import viewSEG/core/[correlatejobs, correlateread, filesystem, jobs, properties, session, state]
import utils/[fixtures, waiting]

var
  guard: Lock
  armed = false
  forbidden = ""
  seen: seq[string]

proc note(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  if not armed: return
  {.cast(gcsafe).}:
    withLock guard:
      if forbidden.len > 0 and (path == forbidden or '\0' in path):
        seen.add $op & " " & path

proc bytesOf(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

const
  DtMs = 2.0
  AuxLeadMs = 500.0 # the shift given to the marked reference trace
  Record = 1000
  SweepLen = 200
  Listen = 800
  Delays = [40, 100, 200]
  RefAux = 3

proc delayedSweep(sweep: openArray[float32]; samples, delay: int): seq[float32] =
  result = newSeq[float32](samples)
  for i in 0 ..< samples:
    let j = i - delay
    if j >= 0 and j < sweep.len: result[i] = sweep[j]

proc writeRaw(path: string; sweep: openArray[float32]) =
  ## The synthetic sweep file `tests/tcorrelatejobs.nim` correlates: five
  ## traces, three delayed sweeps, one reference auxiliary, one other.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, text: @["C01 correlation job test"]))
  for i in 0 .. 4:
    var buf: seq[float32] = @[]
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
    k.ensemble = 10.0 + float64(i)
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the raw file did not close"

proc jobSpec(path: string): JobSpec =
  JobSpec(title: "Correlate " & path.extractFilename, lane: jlBackground,
    reads: @[path], cancellable: true)

proc finish(jobs: Jobs; id: JobId): JobState =
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the job did not finish"
  jobs.info(id).get.state

proc correlated(file: ptr SeismicFile; path: string; sweep: openArray[float32]): CorrelateResult =
  var jobs = initJobs()
  result.opened = nil
  result.lines = @[]
  try:
    let id = jobs.submit(jobSpec(path), correlateWork(CorrelateAsk(
      file: file, path: path, reference: @sweep, referenceDtMs: DtMs,
      marked: marksOf([RefAux], AuxLeadMs)), addr result))
    doAssert finish(jobs, id) == jsDone, result.failure
  finally:
    jobs.stop()
  doAssert result.ok, result.failure

proc rawSampleLeft(rows: openArray[FieldRow]): bool =
  for row in rows:
    if row.field == "samplesPerTrace" and row.number == float64(Record): return true

proc writeSegdExternal(path: string) =
  ## Five traces, 1000 samples, and a 4096-byte external header the correlated
  ## write does not copy.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: DtMs * 1000.0,
    numSamples: Record, time: 1_700_000_000.0))
  var ext = newSeq[byte](4096)
  for i in 0 ..< ext.len: ext[i] = byte(i and 0xff)
  var buf = newSeq[float32](Record)
  for j in 0 ..< Record: buf[j] = 1
  for i in 0 .. 4:
    var k = initTraceKeys()
    k.record = 1.0
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.time = 1_700_000_000.0
    k.status = tsLive
    k.traceCode = 1
    w.writeTrace(k, buf, channelType = sctSeismic, externalHeader = ext)
  doAssert w.close().len == 0, "the SEG-D file did not close"

proc segdEstimate() =
  ## A SEG-D estimate is the file the job writes, not the source's external header.
  ## One header set is the general headers of one record and one channel-set
  ## descriptor, as `correlatedBytesEstimate` states.
  let dir = getTempDir() / ("tderived-segd-" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  let path = dir / "raw.sgd"
  writeSegdExternal(path)
  var opened = openSeismic(path, keys = true)
  let raw = newSession(path, opened)
  let sweep = linearSweep(8.0, 80.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
  var jobs = initJobs()
  var slot = CorrelateResult(opened: nil, lines: @[])
  try:
    let id = jobs.submit(jobSpec(path), correlateWork(CorrelateAsk(
      file: raw.filePtr, path: path, reference: @sweep, referenceDtMs: DtMs,
      marked: @[]), addr slot))
    doAssert finish(jobs, id) == jsDone, slot.failure
  finally:
    jobs.stop()
  doAssert slot.ok, slot.failure
  let written = slot.opened
  let estimate = correlatedBytesEstimate(raw.filePtr, SweepLen)
  let actual = written.size
  const oneHeaderSet = 2 * 3 * SegdBlockSize
  doAssert estimate >= actual, "estimate " & $estimate & " below actual " & $actual
  doAssert estimate - actual <= int64(oneHeaderSet), "estimate " & $estimate &
    " actual " & $actual & " header set " & $oneHeaderSet
  doAssert estimate < actual + 4096, "estimate includes the source external header: estimate " &
    $estimate & " actual " & $actual
  doAssert close(raw)

proc summaryValue(lines: openArray[SummaryLine]; label: string): string =
  for l in lines:
    if not l.heading and l.label == label: return l.value

proc hasSummary(lines: openArray[SummaryLine]; label: string): bool =
  for l in lines:
    if not l.heading and l.label == label: return true

proc anyValueHas(lines: openArray[SummaryLine]; piece: string): bool =
  for l in lines:
    if piece in l.value: return true

proc storedBinary(rows: openArray[FieldRow]): bool =
  var saw = false
  for row in rows:
    if row.blockName == "binary" or row.blockName.startsWith("gh"):
      saw = true
      if not row.description.startsWith("Stored: "): return false
  saw

proc plainBinary(rows: openArray[FieldRow]): bool =
  for row in rows:
    if row.blockName == "binary" or row.blockName.startsWith("gh"):
      if row.description.startsWith("Stored: "): return false
  true

proc openView(path: string; sweep: openArray[float32]): tuple[raw, view: Session] =
  var opened = openSeismic(path, keys = true)
  result.raw = newSession(path, opened)
  let built = initCorrelateView(result.raw.filePtr, sweep, DtMs, @[])
  doAssert built.refusal.len == 0, built.refusal
  result.view = asCorrelatedView(result.raw, built.view)

proc writeInt16(path: string) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, format: st3, text: @["C01 stored format"]))
  var buf = newSeq[float32](Record)
  for j in 0 ..< Record: buf[j] = float32(j mod 100)
  for i in 0 .. 4:
    var k = initTraceKeys()
    k.record = 7.0
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.time = 1_700_000_000.0
    k.traceCode = 1
    k.status = tsLive
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the integer file did not close"

proc viewLabels() =
  ## A view names listen time as correlated and keeps the raw header's record
  ## length. A file that is not a view is worded as before.
  let dir = getTempDir() / ("tderived-labels-" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  let sweep = linearSweep(8.0, 80.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
  let path = dir / "raw.sgy"
  writeRaw(path, sweep)
  let segy = openView(path, sweep)
  let plain = summaryLines(segy.raw, -1)
  doAssert summaryValue(plain, "Samples per trace") == grouped(Record)
  doAssert not hasSummary(plain, "Samples per trace (correlated)")
  doAssert hasSummary(plain, "Trace length")
  doAssert not hasSummary(plain, "Trace length (correlated)")
  doAssert summaryValue(plain, "Sample format") == "5: IEEE float, 4 bytes"
  doAssert not hasSummary(plain, "Sample format (stored)")
  doAssert plainBinary(segy.raw.facts.rows)
  let lines = summaryLines(segy.view, -1)
  doAssert summaryValue(lines, "Samples per trace (correlated)") == grouped(Listen)
  doAssert not hasSummary(lines, "Samples per trace")
  doAssert "1600 ms" in summaryValue(lines, "Trace length (correlated)")
  doAssert not hasSummary(lines, "Trace length")
  doAssert summaryValue(lines, "Sample format") == "IEEE float32 (correlated)"
  doAssert summaryValue(lines, "Sample format (stored)") == "5: IEEE float, 4 bytes"
  doAssert not hasSummary(lines, "Record length (header)")
  doAssert storedBinary(segy.view.facts.rows)
  doAssert plainBinary(segy.raw.facts.rows)
  var storedSamples = false
  for row in segy.view.facts.rows:
    if row.field == "samplesPerTrace" and row.blockName == "binary":
      storedSamples = row.number == float64(Record) and
        row.description.startsWith("Stored: ")
  doAssert storedSamples, "the stored sample count was not marked stored"
  doAssert abs(segy.view.facts.summary.recordLengthMs -
    segy.raw.facts.summary.recordLengthMs) < 1e-3
  doAssert close(segy.view)
  doAssert close(segy.raw)

  let intPath = dir / "int16.sgy"
  writeInt16(intPath)
  let narrow = openView(intPath, sweep)
  let narrowLines = summaryLines(narrow.view, -1)
  doAssert summaryValue(narrowLines, "Sample format") == "IEEE float32 (correlated)"
  doAssert summaryValue(narrowLines, "Sample format (stored)") == "3: integer, 2 bytes"
  let narrowPlain = summaryLines(narrow.raw, -1)
  doAssert summaryValue(narrowPlain, "Sample format") == "3: integer, 2 bytes"
  doAssert not hasSummary(narrowPlain, "Sample format (stored)")
  doAssert close(narrow.view)
  doAssert close(narrow.raw)

  let segdPath = dir / "raw.sgd"
  writeSegdExternal(segdPath)
  let segd = openView(segdPath, sweep)
  doAssert not segd.raw.facts.summary.recordLengthMs.isNaN
  doAssert abs(segd.view.facts.summary.recordLengthMs -
    segd.raw.facts.summary.recordLengthMs) < 1e-3
  doAssert abs(segd.view.facts.summary.recordLengthMs - float64(Listen) * DtMs) > 1
  doAssert segd.view.records.len > 0
  let segdLines = summaryLines(segd.view, 0)
  let headerLen = summaryValue(segdLines, "Record length (header)")
  doAssert headerLen.startsWith("2000 ms"), headerLen
  doAssert not headerLen.startsWith("1600")
  doAssert summaryValue(segdLines, "Samples per trace (correlated)") == grouped(Listen)
  doAssert "1600 ms" in summaryValue(segdLines, "Trace length (correlated)")
  doAssert anyValueHas(segdLines, $Listen & " (correlated) samples")
  doAssert not anyValueHas(segdLines, $Record & " samples at")
  let segdPlain = summaryLines(segd.raw, 0)
  doAssert not hasSummary(segdPlain, "Samples per trace (correlated)")
  doAssert summaryValue(segdPlain, "Record length (header)").startsWith("2000 ms")
  doAssert anyValueHas(segdPlain, $Record & " samples at")
  doAssert not anyValueHas(segdPlain, "(correlated)")
  doAssert close(segd.view)
  doAssert close(segd.raw)

proc viewOfSweep() =
  ## Listen facts of a view, the copy's size, and closing the raw file under a view.
  let dir = getTempDir() / ("tderived-view-" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  let path = dir / "raw.sgy"
  let sweep = linearSweep(8.0, 80.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
  doAssert sweep.len == SweepLen
  writeRaw(path, sweep)
  var opened = openSeismic(path, keys = true)
  let raw = newSession(path, opened)
  let slot = correlated(raw.filePtr, path, sweep)
  let written = slot.opened
  doAssert written.facts.summary.samplesPerTrace == Listen
  let built = initCorrelateView(raw.filePtr, sweep, DtMs, marksOf([RefAux], AuxLeadMs))
  doAssert built.refusal.len == 0, built.refusal
  let view = asCorrelatedView(raw, built.view)
  doAssert view.isCorrelatedView
  doAssert not raw.isCorrelatedView
  doAssert view.derived
  doAssert view.path.startsWith(correlatedPath(path)) and diskOf(view.path) == path
  doAssert view.diskPath == path
  doAssert view.filePtr == raw.filePtr
  doAssert view.len == raw.len
  doAssert view.listenSamples == Listen
  doAssert abs(view.listenDtMs - DtMs) < 1e-9
  doAssert view.facts.summary.samplesPerTrace == written.facts.summary.samplesPerTrace
  doAssert abs(view.facts.summary.sampleIntervalUs -
    written.facts.summary.sampleIntervalUs) < 1e-6
  doAssert abs(view.facts.summary.recordLengthMs - raw.facts.summary.recordLengthMs) < 1e-3
  doAssert abs(view.facts.summary.recordLengthMs - float64(Record) * DtMs) < 1e-6
  doAssert raw.facts.summary.samplesPerTrace == Record
  doAssert view.facts.text == raw.facts.text
  doAssert rawSampleLeft(view.facts.rows), "the raw sample count was not left in the header rows"
  let estimate = correlatedBytesEstimate(raw.filePtr, SweepLen)
  doAssert correlatedBytesEstimate(raw.filePtr, built.view) == estimate
  doAssert correlatedBytesEstimate(raw.filePtr, view.correlatedView) == estimate
  let actual = written.size
  let headers = actual - int64(written.len) * int64(Listen) * 4
  doAssert headers > 0
  doAssert abs(estimate - actual) <= headers, "estimate " & $estimate & " actual " & $actual &
    " headers " & $headers
  doAssert fitsInMemory(estimate, estimate)
  doAssert not fitsInMemory(estimate, estimate - 1)
  doAssert not fitsInMemory(estimate, 0)
  doAssert not close(raw), "the raw file closed while a view of it existed"
  doAssert raw.file.isOpen
  doAssert view.file.isOpen
  doAssert close(view)
  doAssert not view.isCorrelatedView
  doAssert raw.file.isOpen, "closing the view closed the raw file"
  doAssert close(raw)
  doAssert not raw.file.isOpen

  block drop_then_close:
    var again = openSeismic(path, keys = true)
    let raw2 = newSession(path, again)
    var only: Session = asCorrelatedView(raw2, built.view)
    only = nil
    doAssert raw2.file.isOpen, "dropping the view closed the raw file"
    doAssert close(raw2)
    doAssert not raw2.file.isOpen

  block two_views:
    var third = openSeismic(path, keys = true)
    let raw3 = newSession(path, third)
    let a = asCorrelatedView(raw3, built.view)
    let b = asCorrelatedView(raw3, built.view)
    doAssert not close(raw3)
    doAssert close(a)
    doAssert raw3.file.isOpen
    doAssert not close(raw3), "the raw file closed while a view of it existed"
    doAssert close(b)
    doAssert raw3.file.isOpen, "closing the view closed the raw file"
    doAssert close(raw3)

proc main*() =
  initLock guard
  withFixtures fx:
    let raw = fx.oneTraceSegy()
    let other = fx.surveySegy()
    forbidden = correlatedPath(raw)
    var st = initAppState(watchEvery = initDuration(milliseconds = 20))
    var settings = st.settings
    settings.files.prepareNext = false
    st.apply Command(kind: ckSettings, settings: settings)
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: raw)
    doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == raw and
      st.panel(MainPanel).laidOut), "the raw file was not shown"
    setFsHook(note)
    armed = true
    var copy = openSeismicBytes(bytesOf(raw), "correlated copy", keys = true)
    doAssert copy.inMemory
    let derived = newSession(raw, copy)
    derived.asDerived()
    doAssert derived.path.startsWith(forbidden) and diskOf(derived.path) == raw
    doAssert derived.diskPath == raw
    st.adoptDerived(derived)
    let shown = st.shownFile(st.findPanel(MainPanel))
    doAssert shown >= 0 and st.sessions[shown].derived, "the derived view was not shown"
    doAssert st.sessions.anyIt(not it.derived and it.path == raw), "the raw file was closed"
    doAssert st.fileList.chosen == raw, "the chosen file is not the file on disk"
    doAssert not st.settings.recentFiles.anyIt(it.startsWith(forbidden)), "the virtual key was remembered"
    let since = getMonoTime()
    doAssert st.settle(st.panel(MainPanel).laidOut and st.jobs.active.len == 0 and
      getMonoTime() - since > initDuration(milliseconds = 80)),
      "the derived view was not laid out"
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: other)
    doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == other and
      st.jobs.active.len == 0 and not st.sessions.anyIt(it.derived)),
      "the derived view was still open"
    discard st.shutdown()
    doAssert seen.len == 0, "fs was asked about the virtual path: " & seen.join("; ")
  setFsHook(nil)
  armed = false
  viewOfSweep()
  segdEstimate()
  viewLabels()
  echo "tderived: ok"

when isMainModule: main()
