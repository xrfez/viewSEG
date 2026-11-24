## A background job reads seismic files and fills the trace-quality report.
## A killed trace is not bad. Header-dead is not all-zero. An unreadable
## file is unread and the scan goes on. A cancel leaves the sink empty.
##
## Seen to fail: with header-dead not recorded, `findings_from_samples`
## rejected a dead station whose bad count was 0. With a chunk measured at
## the first trace's interval, `each_interval_measured_alone` rejected a
## 2000 us trace that was spiky only at 4000 us. With a short last trace
## omitted and not unread, `cut_in_the_last_trace_is_unread` saw a fully
## read file. With dead, killed and auxiliary traces read inside a live
## chunk, `skipped_traces_are_not_sample_read` saw one sample read for
## four live runs.

import std/[os, strutils, tables]
import parseSEG
import processSEG/qc/amplitude
import viewSEG/core/[edits, jobs, qualityjobs, qualityreport]
import utils/[faultyfs, waiting]

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc run(paths: seq[string]; edits: Table[string, FileEdits]; cacheDir = ""):
    tuple[st: JobState; sink: QualitySink; error: string] =
  let jobs = initJobs()
  let sink = QualitySink()
  let id = jobs.submit(qualitySpec(paths), scanQuality(paths, edits, sink, cacheDir))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the scan did not finish: " & $jobs.state(id)
  let info = jobs.info(id).get
  (info.state, sink, info.error)

proc writeTraceAt(w: var SeismicWriter; record, channel: int; line, point: float64;
    component: uint8; status: TraceStatus; samples: openArray[float32];
    channelType = sctSeismic) =
  var k = initTraceKeys()
  k.record = float64(record)
  k.channel = float64(channel)
  k.srcLine = 1
  k.srcPoint = 1
  k.srcIndex = 1
  k.rcvLine = line
  k.rcvPoint = point
  k.rcvIndex = 1
  k.intervalUs = 2000
  k.component = component
  k.sensorType = component
  k.status = status
  w.writeTrace(k, samples, channelType = channelType)

proc seismicFile(path: string; record: int; traces: openArray[tuple[line, point: float64;
    component: uint8; status: TraceStatus; samples: seq[float32]]]) =
  let n = if traces.len == 0: 1 else: traces[0].samples.len
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: n, time: 1_700_000_000.0))
  for i, t in traces:
    writeTraceAt(w, record, i + 1, t.line, t.point, t.component, t.status, t.samples)
  doAssert w.close().len == 0, "file was not written: " & path

proc auxFile(path: string) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0))
  writeTraceAt(w, 1, 1, 40, 1, 1, tsAuxiliary, @[0'f32], sctTimeBreak)
  doAssert w.close().len == 0, "auxiliary file was not written: " & path

proc zeros(n: int): seq[float32] =
  newSeq[float32](n)

proc clippedSamples(): seq[float32] =
  result = newSeq[float32](32)
  for i in 0 ..< 32: result[i] = if i mod 2 == 0: 1 else: -1
  for i in 4 .. 6: result[i] = 1000
  for i in 8 .. 10: result[i] = -1000
  for i in 20 .. 22: result[i] = 1000
  for i in 24 .. 26: result[i] = -1000

proc nanSamples(): seq[float32] =
  result = newSeq[float32](32)
  for i in 0 ..< 32:
    result[i] = if i mod 2 == 0: float32(i + 1) else: -float32(i + 1)
  result[7] = NaN

proc bumped(): seq[float32] =
  ## Spiky at 4 ms, not at 2 ms: a bump in a quiet gap between alternating samples.
  let n = 120
  let mid = n div 2
  result = newSeq[float32](n)
  for i in 0 ..< n: result[i] = if i mod 2 == 0: 2 else: -2
  for i in mid - 8 .. mid + 8: result[i] = 0
  result[mid] = 1

proc quiet(): seq[float32] =
  result = newSeq[float32](120)
  for i in 0 ..< result.len: result[i] = if i mod 2 == 0: 1 else: -1

proc seismos(path: string; traces: openArray[tuple[line, point: float64;
    intervalUs: float64; samples: seq[float32]]]) =
  var w = openSeismicWriter(path, SegyOutputOptions())
  for i, t in traces:
    var k = initTraceKeys()
    k.record = float64(i + 1)
    k.channel = float64(i + 1)
    k.srcLine = 1
    k.srcPoint = 1
    k.srcIndex = 1
    k.rcvLine = t.line
    k.rcvPoint = t.point
    k.rcvIndex = 1
    k.intervalUs = t.intervalUs
    k.component = 1
    k.status = tsLive
    w.writeTrace(k, t.samples)
  doAssert w.close().len == 0, "file was not written: " & path

proc statusFile(path: string; traces: openArray[TraceStatus]) =
  var w = openSeismicWriter(path, SegyOutputOptions())
  var samples = newSeq[float32](32)
  for i in 0 ..< samples.len: samples[i] = float32(i + 1)
  for i, st in traces:
    var k = initTraceKeys()
    k.record = float64(i + 1)
    k.channel = float64(i + 1)
    k.srcLine = 1
    k.srcPoint = 1
    k.srcIndex = 1
    k.rcvIndex = 1
    k.intervalUs = 2000
    k.component = 1
    k.status = st
    if st == tsAuxiliary: k.traceCode = 4
    w.writeTrace(k, samples)
  doAssert w.close().len == 0, "file was not written: " & path

proc matchesAlone(seen, killed, bad: int; counts: array[Finding, int];
    samples: openArray[float32]; dtMs: float64) =
  let want = findingsOf(traceAmplitude(samples, dtMs).flags, false)
  doAssert seen == 1 and killed == 0, $seen & " killed " & $killed
  doAssert bad == ord(want.len > 0), $bad & " want " & $want
  for q in Finding:
    doAssert counts[q] == ord(q in want), $q & " " & $counts[q] & " want " & $want

proc recordAt(rows: openArray[RecordRow]; file: string; record: float64): RecordRow =
  for r in rows:
    if r.file == file and r.record == record: return r
  doAssert false, "no record " & $record & " in " & file

proc stationAt(rows: openArray[StationRow]; line, point: float64; component: uint8): StationRow =
  for r in rows:
    if r.line == line and r.point == point and r.component == component: return r
  doAssert false, "no station " & $line & ":" & $point & " c" & $component

proc unreadWhy(rows: openArray[tuple[path, why: string]]; path: string): string =
  for r in rows:
    if r.path == path: return r.why
  doAssert false, "not unread: " & path

var lane: Jobs
var readings: int

proc stopOnSecond(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if back or not phase.startsWith("reading"): return
  inc readings
  if readings >= 2: discard lane.cancel(id)

proc stopOnReport(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if not back and phase == "reporting": discard lane.cancel(id)

proc stopOnMeasure(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if not back and phase == "measuring": discard lane.cancel(id)

proc main*() =
  let dir = getTempDir() / ("viewseg-quality-" & $getCurrentProcessId())
  createDir(dir)
  let none = initTable[string, FileEdits]()

  block spec_names_the_scan:
    let spec = qualitySpec(@["a.sgd", "b.sgd"])
    doAssert spec.title == "Trace quality", spec.title
    doAssert spec.lane == jlBackground
    doAssert spec.reads == @["a.sgd", "b.sgd"]

  block findings_from_samples:
    let one = dir / "one.sgd"
    let two = dir / "two.sgd"
    let killedPath = dir / "killed.sgd"
    let aux = dir / "aux.sgd"
    let z = zeros(32)
    seismicFile(one, 1, @[
      (line: 10.0, point: 1.0, component: 1'u8, status: tsLive, samples: z),
      (line: 10.0, point: 1.0, component: 1'u8, status: tsLive, samples: clippedSamples()),
      (line: 10.0, point: 1.0, component: 1'u8, status: tsLive, samples: nanSamples()),
      (line: 20.0, point: 1.0, component: 1'u8, status: tsDead, samples: z),
      (line: 10.0, point: 1.0, component: 2'u8, status: tsLive, samples: z)])
    seismicFile(two, 2, @[
      (line: 10.0, point: 1.0, component: 1'u8, status: tsLive, samples: z)])
    seismicFile(killedPath, 1, @[
      (line: 30.0, point: 1.0, component: 1'u8, status: tsLive, samples: z)])
    auxFile(aux)
    var edits = initTable[string, FileEdits]()
    var killed = FileEdits()
    discard killed.change(teKilled, [0], true)
    edits[killedPath] = killed
    let got = run(@[one, two, killedPath, aux], edits, dir / "cache")
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    doAssert got.sink.result.ok
    doAssert got.sink.result.unread.len == 0, $got.sink.result.unread
    let report = got.sink.result.report
    let both = stationAt(report.stations, 10, 1, 1)
    doAssert both.seen == 4 and both.bad == 4 and both.killed == 0, $both
    doAssert both.counts[qfAllZero] == 2, $both.counts[qfAllZero]
    doAssert both.counts[qfClipped] == 1, $both.counts
    doAssert both.counts[qfNonFinite] == 1
    doAssert both.badRecords == one & " 1\n" & two & " 2", both.badRecords
    let other = stationAt(report.stations, 10, 1, 2)
    doAssert other.seen == 1 and other.counts[qfAllZero] == 1 and other.bad == 1
    let dead = stationAt(report.stations, 20, 1, 1)
    doAssert dead.seen == 1 and dead.bad == 1 and dead.counts[qfHeaderDead] == 1, $dead
    doAssert dead.counts[qfAllZero] == 0
    let gone = stationAt(report.stations, 30, 1, 1)
    doAssert gone.seen == 1 and gone.killed == 1 and gone.bad == 0, $gone
    doAssert gone.counts[qfAllZero] == 0
    doAssert report.stations.len == 4, $report.stations.len
    doAssert report.totals.files == 3 and report.totals.records == 3, $report.totals
    doAssert report.totals.traces == 7 and report.totals.killed == 1, $report.totals
    doAssert report.totals.bad == 6 and report.totals.counts[qfHeaderDead] == 1

  block unread_does_not_stop_the_scan:
    let one = dir / "one.sgd"
    let notes = dir / "notes.txt"
    writeFile(notes, "not seismic\n")
    let missing = dir / "missing.sgd"
    let got = run(@[one, notes, missing], none)
    doAssert got.st == jsDone, got.error
    doAssert got.sink.result.ok
    doAssert got.sink.result.report.totals.files == 1
    doAssert unreadWhy(got.sink.result.unread, notes) ==
      "not a SEG-Y, SEG-D or SEG-2 file"
    doAssert unreadWhy(got.sink.result.unread, missing) == "there is no such file",
      unreadWhy(got.sink.result.unread, missing)

  block duplicate_path_is_scanned_once:
    let one = dir / "one.sgd"
    let again = dir / "sub" / ".." / "one.sgd"
    createDir(dir / "sub")
    let got = run(@[one, one, again], none)
    doAssert got.st == jsDone, got.error
    doAssert got.sink.result.report.totals.files == 1, $got.sink.result.report.totals
    doAssert got.sink.result.unread.len == 0

  block nil_sink_is_skipped:
    let jobs = initJobs()
    let id = jobs.submit(qualitySpec(@[]),
      scanQuality(@[], none, nil))
    doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled})
    doAssert jobs.state(id) == jsDone, $jobs.state(id)

  block cancel_between_files:
    readings = 0
    lane = initJobs()
    setJobHook(stopOnSecond)
    defer: setJobHook(nil)
    let sink = QualitySink()
    let one = dir / "one.sgd"
    let two = dir / "two.sgd"
    let id = lane.submit(qualitySpec(@[one, two]), scanQuality(@[one, two], none, sink))
    doAssert waitUntil(lane.state(id) in {jsDone, jsFailed, jsCancelled}),
      "the scan did not finish"
    doAssert lane.state(id) == jsCancelled, $lane.state(id) & " " & lane.info(id).get.error
    doAssert not sink.result.ok
    doAssert sink.result.report.totals.traces == 0
    doAssert sink.result.unread.len == 0

  block cancel_during_reporting:
    lane = initJobs()
    setJobHook(stopOnReport)
    defer: setJobHook(nil)
    let sink = QualitySink()
    let one = dir / "one.sgd"
    let id = lane.submit(qualitySpec(@[one]), scanQuality(@[one], none, sink))
    doAssert waitUntil(lane.state(id) in {jsDone, jsFailed, jsCancelled})
    doAssert lane.state(id) == jsCancelled, $lane.state(id) & " " & lane.info(id).get.error
    doAssert sink.result.report.totals.traces == 0
    doAssert sink.result.unread.len == 0

  block cancel_between_chunks:
    let wide = dir / "wide.sgd"
    var traces: seq[tuple[line, point: float64; component: uint8; status: TraceStatus;
      samples: seq[float32]]] = @[]
    let oneSample = @[0'f32]
    for i in 0 ..< 513:
      traces.add (line: 50.0, point: float64(i + 1), component: 1'u8, status: tsLive,
        samples: oneSample)
    seismicFile(wide, 1, traces)
    lane = initJobs()
    setJobHook(stopOnMeasure)
    defer: setJobHook(nil)
    let sink = QualitySink()
    let id = lane.submit(qualitySpec(@[wide]), scanQuality(@[wide], none, sink))
    doAssert waitUntil(lane.state(id) in {jsDone, jsFailed, jsCancelled})
    doAssert lane.state(id) == jsCancelled, $lane.state(id) & " " & lane.info(id).get.error
    doAssert sink.result.report.totals.traces == 0
    doAssert sink.result.unread.len == 0

  block each_interval_measured_alone:
    let slow = quiet()
    let fast = bumped()
    doAssert traceAmplitude(fast, 2.0).flags != traceAmplitude(fast, 4.0).flags
    let path = dir / "intervals.sgy"
    seismos(path, @[
      (line: 70.0, point: 1.0, intervalUs: 4000.0, samples: slow),
      (line: 70.0, point: 2.0, intervalUs: 2000.0, samples: fast)])
    let got = run(@[path], none)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    doAssert got.sink.result.ok and got.sink.result.unread.len == 0, $got.sink.result.unread
    let report = got.sink.result.report
    let first = recordAt(report.records, path, 1)
    let second = recordAt(report.records, path, 2)
    matchesAlone(first.seen, first.killed, first.bad, first.counts, slow, 4.0)
    matchesAlone(second.seen, second.killed, second.bad, second.counts, fast, 2.0)

  block cut_in_the_last_trace_is_unread:
    let path = dir / "cut.sgy"
    var w = openSeismicWriter(path, SegyOutputOptions())
    var samples = newSeq[float32](32)
    for i in 0 ..< samples.len: samples[i] = float32(i + 1)
    for n in 1 .. 2:
      var k = initTraceKeys()
      k.record = float64(n)
      k.channel = float64(n)
      k.srcLine = 1
      k.srcPoint = 1
      k.srcIndex = 1
      k.rcvIndex = 1
      k.intervalUs = 2000
      k.component = 1
      k.status = tsLive
      w.writeTrace(k, samples)
    doAssert w.close().len == 0, "file was not written: " & path
    let full = readFile(path)
    writeFile(path, full[0 ..< full.len - 10])
    let got = run(@[path], none)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    doAssert got.sink.result.ok
    doAssert got.sink.result.report.totals.traces == 1, $got.sink.result.report.totals
    doAssert got.sink.result.report.totals.files == 1
    doAssert "cut short" in unreadWhy(got.sink.result.unread, path),
      unreadWhy(got.sink.result.unread, path)
    let kept = recordAt(got.sink.result.report.records, path, 1)
    doAssert kept.seen == 1, $kept

  block skipped_traces_are_not_sample_read:
    install()
    defer:
      setFsHook(nil)
      setIoHook(nil)
    let quiet = dir / "dead.sgy"
    let mixed = dir / "mixed.sgy"
    let kinds = [tsDead, tsDead, tsDead, tsDead, tsDead, tsDead, tsDead]
    statusFile(quiet, kinds)
    statusFile(mixed, [tsLive, tsLive, tsLive, tsDead, tsLive, tsAuxiliary, tsLive])
    doAssert getFileSize(quiet) == getFileSize(mixed),
      $getFileSize(quiet) & " " & $getFileSize(mixed)
    var edits = initTable[string, FileEdits]()
    var killed = FileEdits()
    discard killed.change(teKilled, [1], true)
    edits[mixed] = killed
    resetCounts()
    let deadScan = run(@[quiet], none)
    let deadReads = calls(foMapped, quiet)
    doAssert deadScan.st == jsDone, deadScan.error & " / " & deadScan.sink.result.reason
    resetCounts()
    let mixScan = run(@[mixed], edits)
    let mixReads = calls(foMapped, mixed)
    doAssert mixScan.st == jsDone, mixScan.error & " / " & mixScan.sink.result.reason
    doAssert mixScan.sink.result.ok and mixScan.sink.result.unread.len == 0,
      $mixScan.sink.result.unread
    doAssert mixReads - deadReads == 4, $mixReads & " - " & $deadReads
    let report = mixScan.sink.result.report
    doAssert report.totals.traces == 6 and report.totals.killed == 1, $report.totals
    doAssert report.totals.counts[qfHeaderDead] == 1, $report.totals.counts
    var ramp = newSeq[float32](32)
    for i in 0 ..< ramp.len: ramp[i] = float32(i + 1)
    let live = recordAt(report.records, mixed, 1)
    matchesAlone(live.seen, live.killed, live.bad, live.counts, ramp, 2.0)
    let gone = recordAt(report.records, mixed, 2)
    doAssert gone.seen == 1 and gone.killed == 1 and gone.bad == 0, $gone
    let dead = recordAt(report.records, mixed, 4)
    doAssert dead.seen == 1 and dead.counts[qfHeaderDead] == 1, $dead
    for r in report.records:
      doAssert r.file != mixed or r.record != 6, "an auxiliary trace was noted"

when isMainModule:
  main()
