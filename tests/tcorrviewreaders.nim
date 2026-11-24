## Spectrum, analysis, record QC and the Headers window read a correlated view
## in listen time, through `readListenTraces`, matching the in-memory file
## `correlateWork` writes. Returning the raw samples fails. The virtual path
## is not mapped. Noise QC on a view picks first breaks on the correlated samples.
##
## Seen to fail, then restored: the spectrum of the raw chirp (`window 1000
## are the raw record, not the listen time`); analysis rows of length 1000;
## the constant trace flagged `constant` after correlation; inspector samples
## of length 1000 and time zero 0; noise QC picking on the raw record (`view
## picks @[106.0, ...] vs @[80.0, ...]`); rows of a file cut short
## reported undecodable (`a cut view reports undecodable @[6, 7, 8, 9]`); the view's one time zero
## for every trace (`view spectrum time zero 12.0`).

import std/[atomics, locks, math, monotimes, os]
import parseSEG
import processSEG
import processSEG/qc/record
import viewSEG/core/[correlatejobs, correlateread, edits, filesystem, headers, inbox, jobs,
  noisearea, processing, recordqc, session, spectra, spectrumreader]
import viewSEG/core/analysisreader {.all.}
import viewSEG/core/inspector
import utils/waiting

const
  DtMs = 2.0
  T0Ms = 12.0
  OtherT0Ms = 16.0 ## trace 1's own time zero; the auxiliary traces start at 0
  Record = 1000
  SweepLen = 200
  Listen = 800
  RefAux = 3
  Extra = 6        ## live traces after the reference auxiliary
  Constant = 2

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
    format: st5, text: @["C01 correlated view readers"]))
  for i in 0 .. RefAux + Extra:
    var buf: seq[float32]
    var k = initTraceKeys()
    if i == Constant:
      buf = newSeq[float32](Record)
      for j in 0 ..< Record: buf[j] = 1.0
      (k.traceCode, k.status) = (1'i16, tsLive)
    elif i == RefAux:
      buf = delayedSweep(sweep, Record, 0)
      (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    else:
      buf = delayedSweep(sweep, Record, 40 + 60 * i)
      (k.traceCode, k.status) = (1'i16, tsLive)
    k.record = 7.0
    k.channel = float64(i + 1)
    k.offset = 100.0 * float64(i + 1)
    k.t0Ms = if i == 1: OtherT0Ms elif i == RefAux: 0.0 else: T0Ms
    k.intervalUs = DtMs * 1000.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the raw file did not close"

proc finish(jobs: Jobs; id: JobId): JobState =
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "a job did not finish"
  jobs.info(id).get.state

proc correlate(file: ptr SeismicFile; path: string; sweep: seq[float32]): CorrelateResult =
  var jobs = initJobs()
  try:
    let id = jobs.submit(JobSpec(title: "Correlate " & path.extractFilename, lane: jlBackground,
      reads: @[path], cancellable: true), correlateWork(CorrelateAsk(
      file: file, path: path, reference: sweep, referenceDtMs: DtMs,
      referenceTraces: @[RefAux]), addr result))
    doAssert finish(jobs, id) == jsDone, result.failure
  finally:
    jobs.stop()
  doAssert result.ok, result.failure

proc noteOf(m: Msg): string =
  if m.kind == mkLog: m.entry.text else: ""

proc awaitSpectrum(box: Inbox; id: int): Spectrum =
  var found: Spectrum
  var got = false
  var why = ""
  doAssert waitUntil(block:
    var msgs: seq[Msg]
    box.drainInto(msgs)
    for m in msgs:
      let text = noteOf(m)
      if text.len > 0: why.add text & "\n"
      if m.kind == mkSpectrum and m.spectrum.id == id:
        found = m.spectrum
        got = true
    got
  ), "a spectrum did not arrive: " & why
  doAssert found.problem.len == 0, found.problem
  found

proc awaitInspected(box: Inbox): TraceDetail =
  var found: TraceDetail
  var got = false
  var why = ""
  doAssert waitUntil(block:
    var msgs: seq[Msg]
    box.drainInto(msgs)
    for m in msgs:
      let text = noteOf(m)
      if text.len > 0: why.add text & "\n"
      if m.kind == mkInspected and m.inspected.traces.len > 0:
        found = m.inspected.traces[0]
        got = true
    got
  ), "an inspection did not arrive: " & why
  doAssert found.problem.len == 0, found.problem
  found

proc awaitQc(box: Inbox; session: SessionId): Msg =
  var found: Msg
  var got = false
  var why = ""
  doAssert waitUntil(block:
    var msgs: seq[Msg]
    box.drainInto(msgs)
    for m in msgs:
      let text = noteOf(m)
      if text.len > 0: why.add text & "\n"
      if m.kind == mkRecordQc and m.qcSession == session:
        found = m
        got = true
    got
  ), "a record check did not arrive: " & why
  found

proc sameSpectrum(a, b: Spectrum; what: string) =
  doAssert a.dtMs == b.dtMs, what & " interval " & $a.dtMs & " vs " & $b.dtMs
  doAssert a.windowLen == b.windowLen, what & " window " & $a.windowLen & " vs " & $b.windowLen
  doAssert a.fromMs == b.fromMs, what & " from " & $a.fromMs & " vs " & $b.fromMs
  doAssert a.toMs == b.toMs, what & " to " & $a.toMs & " vs " & $b.toMs
  doAssert a.binHz == b.binHz, what & " bin " & $a.binHz & " vs " & $b.binHz
  doAssert a.raw == b.raw, what & " amplitudes differ"

proc rowsOfFile(f: ptr SeismicFile; path: string; list: seq[int];
    view: ref CorrelateView): seq[seq[float32]] =
  var obj: ReaderObj
  let lk = cast[ptr Lock](addr obj)
  initLock(lk[])
  defer: deinitLock(lk[])
  var ws: CorrelateWorkspace
  if view != nil: ws = newWorkspace(view[])
  var failed, nan: seq[bool]
  doAssert readRows(addr obj, f, path, list, 1, result, failed, nan, view, addr ws),
    "the analysis read was given up"
  for i, bad in failed:
    doAssert not bad, "trace " & $list[i] & " could not be read"

proc samePicks(a, b: seq[float64]): bool =
  ## Equal, a NaN (no pick) matching a NaN.
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if not (a[i] == b[i] or (a[i].isNaN and b[i].isNaN)): return false
  true

proc sampleHits(h: array[MapFilter, FilterHits]): seq[seq[int]] =
  for m in SampleFilters: result.add h[m].traces

proc main*() =
  let dir = getTempDir() / ("tcorrviewreaders-" & $getCurrentProcessId())
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
  doAssert built.view.t0Ms == T0Ms, "listen time zero " & $built.view.t0Ms
  doAssert built.view.listenSamples == Listen
  let view = asCorrelatedView(raw, built.view)
  let slot = correlate(raw.filePtr, path, sweep)
  let mem = slot.opened
  defer:
    discard view.close()
    discard mem.close()
    discard raw.close()
  doAssert view.derived and view.isCorrelatedView, "a view is not skipped for first breaks"
  doAssert view.correlatedView.t0Ms == T0Ms

  watchVirt = keep(view.path)
  watchRaw = keep(path)
  defer:
    dealloc watchVirt
    dealloc watchRaw
  virtMaps.store(0)
  rawMaps.store(0)
  setFsHook(countMap)
  defer: setFsHook(nil)

  let traces = @[0, 1]
  let viewRows = rowsOfFile(view.filePtr, view.path, traces, view.correlatedView)
  let memRows = rowsOfFile(mem.filePtr, mem.path, traces, nil)
  let rawRows = rowsOfFile(raw.filePtr, path, traces, nil)
  doAssert viewRows == memRows, "analysis rows are not the correlation"
  doAssert viewRows != rawRows, "analysis returned the raw samples"
  doAssert viewRows[0].len == Listen, "analysis length " & $viewRows[0].len &
    " is the raw record, not the listen time"

  var jobs = initJobs()
  defer: jobs.stop()
  let box = initInbox()
  var spectra = newSpectrumReader(box.poster, jobs.holdRelease)
  var headersWin = newInspector(box.poster, jobs.holdRelease)
  defer:
    spectra.stop()
    headersWin.stop()

  proc askSpectrum(s: Session; id, session: int; correlated: ref CorrelateView;
      list = traces): Spectrum =
    doAssert jobs.hold(s.path), "could not hold " & s.path
    spectra.ask SpectrumAsk(id: id, gen: uint64(id), session: session, file: s.filePtr,
      view: correlated, path: s.path, size: s.size, traces: list)
    awaitSpectrum(box, id)

  let viewSpec = askSpectrum(view, 1, 1, view.correlatedView)
  let memSpec = askSpectrum(mem, 2, 2, nil)
  let rawSpec = askSpectrum(raw, 3, 3, nil)
  sameSpectrum(viewSpec, memSpec, "spectrum")
  doAssert viewSpec.windowLen == Listen, "window " & $viewSpec.windowLen &
    " are the raw record, not the listen time"
  doAssert viewSpec.fromMs == T0Ms, "spectrum time zero " & $viewSpec.fromMs
  doAssert viewSpec.raw != rawSpec.raw, "spectrum returned the raw chirp"
  doAssert viewSpec.windowLen != rawSpec.windowLen, "spectrum window is the raw record"

  # Each trace keeps its own time zero, not the first seismic trace's.
  let viewOther = askSpectrum(view, 11, 11, view.correlatedView, @[1, 0])
  let memOther = askSpectrum(mem, 12, 12, nil, @[1, 0])
  doAssert memOther.fromMs == OtherT0Ms, "the file's spectrum time zero " & $memOther.fromMs
  doAssert viewOther.fromMs == OtherT0Ms, "view spectrum time zero " & $viewOther.fromMs

  proc askInspect(s: Session; correlated: ref CorrelateView; trace = 0): TraceDetail =
    doAssert jobs.hold(s.path), "could not hold " & s.path
    headersWin.ask InspectRequest(gen: 1, samples: true,
      files: @[InspectFile(file: s.filePtr, path: s.path, session: s.id, size: s.size,
        view: correlated)],
      traces: @[InspectTrace(id: 0, trace: trace)])
    awaitInspected(box)

  let viewTrace = askInspect(view, view.correlatedView)
  let memTrace = askInspect(mem, nil)
  let rawTrace = askInspect(raw, nil)
  doAssert viewTrace.samples == memTrace.samples, "inspector samples are not the correlation"
  doAssert viewTrace.samples != rawTrace.samples, "inspector returned the raw samples"
  doAssert viewTrace.samples.len == Listen, "inspector length " & $viewTrace.samples.len
  doAssert viewTrace.dtMs == DtMs and viewTrace.t0Ms == T0Ms, "inspector time " &
    $viewTrace.dtMs & " from " & $viewTrace.t0Ms
  doAssert memTrace.dtMs == DtMs and memTrace.t0Ms == T0Ms

  for t in [1, RefAux]:
    let viewAt = askInspect(view, view.correlatedView, t)
    let memAt = askInspect(mem, nil, t)
    doAssert viewAt.t0Ms == memAt.t0Ms and memAt.t0Ms == (if t == 1: OtherT0Ms else: 0.0),
      "trace " & $t & " time zero " & $viewAt.t0Ms & ", in memory " & $memAt.t0Ms

  proc askQc(s: Session; session: SessionId; correlated: ref CorrelateView;
      noise = NoiseWork()): Msg =
    var placed: Placed
    let id = jobs.submit(JobSpec(title: "Check " & $session, lane: jlBackground, auto: true,
      reads: @[s.path]), recordQcWork(s.filePtr, s.path, session, 0, 0, 0 ..< s.len,
      rdSource, nil, "", rmAuto, tmAuto, placed, true, newSeq[FilterEntry](), newSeq[int](),
      newSeq[ShiftEntry](), noise, box.poster, correlated))
    let hits = awaitQc(box, session)
    doAssert finish(jobs, id) == jsDone, "the record check failed"
    hits

  let viewHits = askQc(view, SessionId(1), view.correlatedView).qcHits
  let memHits = askQc(mem, SessionId(2), nil).qcHits
  let rawHits = askQc(raw, SessionId(3), nil).qcHits
  doAssert sampleHits(viewHits) == sampleHits(memHits), "record QC flags are not the correlation"
  doAssert sampleHits(viewHits) != sampleHits(rawHits), "record QC returned the raw samples"
  doAssert Constant in rawHits[mfConstant].traces, "the raw constant trace was not flagged"
  doAssert Constant notin viewHits[mfConstant].traces, "the correlated constant trace was flagged"

  # Noise QC picks the first breaks on the correlated samples, as the in-memory file does.
  let noiseOn = NoiseWork(on: true, settings: NoiseSettings())
  let viewNoise = askQc(view, SessionId(4), view.correlatedView, noiseOn)
  let memNoise = askQc(mem, SessionId(5), nil, noiseOn)
  let rawNoise = askQc(raw, SessionId(6), nil, noiseOn)
  doAssert memNoise.qcPicked and viewNoise.qcPicked, "the first breaks were not picked"
  doAssert samePicks(viewNoise.qcBreaks.pickMs, memNoise.qcBreaks.pickMs),
    "view picks " & $viewNoise.qcBreaks.pickMs & " vs " & $memNoise.qcBreaks.pickMs
  doAssert not samePicks(viewNoise.qcBreaks.pickMs, rawNoise.qcBreaks.pickMs),
    "view picks are the raw record's"
  doAssert viewNoise.qcNoise.state == memNoise.qcNoise.state, "noise windows differ"
  doAssert sampleHits(viewNoise.qcHits) == sampleHits(memNoise.qcHits),
    "noise QC flags differ"

  # A file cut short while open: its lost rows are unread, not undecodable, on a view as on
  # a plain file.
  block cutShortWhileOpen:
    let cutPath = dir / "cut.sgy"
    writeRaw(cutPath, sweep)
    var plainFile = openSeismic(cutPath, keys = true)
    var viewFile = openSeismic(cutPath, keys = true)
    let plain = newSession(cutPath, plainFile)
    let viewOf = newSession(cutPath, viewFile)
    let cutBuilt = initCorrelateView(viewOf.filePtr, sweep, DtMs, [RefAux])
    doAssert cutBuilt.refusal.len == 0, cutBuilt.refusal
    let cutView = asCorrelatedView(viewOf, cutBuilt.view)
    defer:
      discard cutView.close()
      discard viewOf.close()
      discard plain.close()
    var indexed = openSeismic(cutPath)
    let cutAt = 5
    let start = indexed.index.entries[cutAt].offset
    let size = getFileSize(cutPath)
    indexed.close()
    let mid = start + (size - start) div 4
    doAssert mid > start and mid < size, "the cut is not inside trace " & $cutAt
    writeFile(cutPath, readFile(cutPath)[0 ..< int(mid)])
    let cutPlain = askQc(plain, SessionId(7), nil).qcHits
    let cutViewHits = askQc(cutView, SessionId(8), cutView.correlatedView).qcHits
    doAssert cutPlain[mfUndecodable].traces.len == 0, "the plain file reports undecodable " &
      $cutPlain[mfUndecodable].traces
    doAssert cutViewHits[mfUndecodable].traces == cutPlain[mfUndecodable].traces,
      "a cut view reports undecodable " & $cutViewHits[mfUndecodable].traces

  doAssert virtMaps.load == 0, "the virtual path was mapped " & $virtMaps.load & " times"
  echo "tcorrviewreaders: ok"

when isMainModule:
  main()
