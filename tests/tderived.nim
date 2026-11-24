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
## so this file cannot name it in `compiles`.

import std/[locks, math, monotimes, os, sequtils, strutils, times]
import parseSEG
import processSEG
import viewSEG/core/[correlatejobs, correlateread, filesystem, jobs, session, state]
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
      referenceTraces: @[RefAux]), addr result))
    doAssert finish(jobs, id) == jsDone, result.failure
  finally:
    jobs.stop()
  doAssert result.ok, result.failure

proc rawSampleLeft(rows: openArray[FieldRow]): bool =
  for row in rows:
    if row.field == "samplesPerTrace" and row.number == float64(Record): return true

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
  let built = initCorrelateView(raw.filePtr, sweep, DtMs, [RefAux])
  doAssert built.refusal.len == 0, built.refusal
  let view = asCorrelatedView(raw, built.view)
  doAssert view.isCorrelatedView
  doAssert not raw.isCorrelatedView
  doAssert view.derived
  doAssert view.path == correlatedPath(path)
  doAssert view.diskPath == path
  doAssert view.filePtr == raw.filePtr
  doAssert view.len == raw.len
  doAssert view.listenSamples == Listen
  doAssert abs(view.listenDtMs - DtMs) < 1e-9
  doAssert view.facts.summary.samplesPerTrace == written.facts.summary.samplesPerTrace
  doAssert abs(view.facts.summary.sampleIntervalUs -
    written.facts.summary.sampleIntervalUs) < 1e-6
  doAssert abs(view.facts.summary.recordLengthMs - written.facts.summary.recordLengthMs) < 1e-3
  doAssert abs(view.facts.summary.recordLengthMs - float64(Listen) * DtMs) < 1e-6
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
    doAssert derived.path == forbidden
    doAssert derived.diskPath == raw
    st.adoptDerived(derived)
    let shown = st.shownFile(st.findPanel(MainPanel))
    doAssert shown >= 0 and st.sessions[shown].derived, "the derived view was not shown"
    doAssert st.sessions.anyIt(not it.derived and it.path == raw), "the raw file was closed"
    doAssert st.fileList.chosen == raw, "the chosen file is not the file on disk"
    doAssert forbidden notin st.settings.recentFiles, "the virtual key was remembered"
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
  echo "tderived: ok"

when isMainModule: main()
