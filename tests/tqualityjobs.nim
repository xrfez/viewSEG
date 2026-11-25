## A background job reads seismic files and fills the trace-quality report.
## A killed trace is not bad. Header-dead is not all-zero. An unreadable
## file is unread and the scan goes on. A cancel leaves the sink empty.
##
## A station is a line and point: its components and files are not rows, and the side of a
## file (receivers of a shot, sources of a receiver gather) decides which of a trace's
## two stations it is counted at. A folder scan reads its subfolders only when asked.
## The measures are those of the scan before the table was one row per station: the
## `measures_are_unchanged` figures were taken from it on the same data.
##
## Seen to fail: with the folder walk always taking subfolders,
## `a_folder_scan_takes_subfolders_only_when_asked` saw 2 files for the folder alone. With
## every file counted at the receivers, `a_receiver_gather_is_counted_at_its_sources` saw
## its three traces at the receivers.
##
## Seen to fail: with header-dead not recorded, `findings_from_samples`
## rejected a dead station whose bad count was 0. With a chunk measured at
## the first trace's interval, `each_interval_measured_alone` rejected a
## 2000 us trace that was spiky only at 4000 us. With a short last trace
## omitted and not unread, `cut_in_the_last_trace_is_unread` saw a fully
## read file. With dead, killed and auxiliary traces read inside a live
## chunk, `skipped_traces_are_not_sample_read` saw one sample read for
## four live runs. With the bar's text the job's own units,
## `the_progress_reads_*` saw "1450 / 3000". With a measuring phase for each chunk after the
## first, `one_measuring_phase_a_file` saw 3 for two files.

import std/[os, strutils, tables]
import parseSEG
import processSEG/qc/amplitude
import viewSEG/core/[edits, jobs, noisearea, qualityjobs, qualityreport, state]
import utils/[faultyfs, fixtures, noisefiles, waiting]

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
    channelType = sctSeismic; srcLine = 1.0; srcPoint = 1.0) =
  var k = initTraceKeys()
  k.record = float64(record)
  k.channel = float64(channel)
  k.srcLine = srcLine
  k.srcPoint = srcPoint
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
    k.rcvLine = 60
    k.rcvPoint = float64(i + 1)
    k.rcvIndex = 1
    k.intervalUs = 2000
    k.component = 1
    k.status = st
    if st == tsAuxiliary: k.traceCode = 4
    w.writeTrace(k, samples)
  doAssert w.close().len == 0, "file was not written: " & path

proc stationAt(rows: openArray[StationRow]; line, point: float64): StationRow =
  for r in rows:
    if r.line == line and r.point == point: return r
  doAssert false, "no station " & $line & ":" & $point

proc runFolder(folder: string; subfolders: bool; cacheDir = ""):
    tuple[st: JobState; sink: QualitySink; error: string] =
  let jobs = initJobs()
  let sink = QualitySink()
  let id = jobs.submit(qualitySpec(@[folder]), folderScan(folder, subfolders, cacheDir,
    EditsSnapshot(), sink, QualityNote(), NoiseSettings()))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the folder scan did not finish: " & $jobs.state(id)
  let info = jobs.info(id).get
  (info.state, sink, info.error)

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

var measuringId: JobId
var wideReads: int

proc noteMeasuring(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  # the scan's id, and the reads of its file counted from its measuring phase on
  if not back and phase == "measuring":
    {.cast(gcsafe).}:
      measuringId = id
      wideReads = 0

proc cancelOnSecondRead(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  # the first chunk's mapped read is the first; the cancel lands on the second, chunk 2
  {.cast(gcsafe).}:
    if op == foMapped and path.endsWith("wide.sgd"):
      inc wideReads
      if wideReads == 2: discard lane.cancel(measuringId)

var measurings: int

proc countMeasuring(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if not back and phase == "measuring": inc measurings

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
    let report = got.sink.result.receivers
    let both = stationAt(report.stations, 10, 1)
    # two components of one station, over two files: one row
    doAssert both.seen == 5 and both.bad == 5 and both.killed == 0, $both
    doAssert both.counts[qfAllZero] == 3, $both.counts[qfAllZero]
    doAssert both.counts[qfClipped] == 1, $both.counts
    doAssert both.counts[qfNonFinite] == 1
    doAssert both.components == {1'u8, 2'u8} and both.lacking == {}, $both
    let dead = stationAt(report.stations, 20, 1)
    doAssert dead.seen == 1 and dead.bad == 1 and dead.counts[qfHeaderDead] == 1, $dead
    doAssert dead.counts[qfAllZero] == 0
    doAssert dead.lacking == {2'u8} and dead.lackFiles == 1,
      "one.sgd has component 2 at another station, not at this one"
    let gone = stationAt(report.stations, 30, 1)
    doAssert gone.seen == 1 and gone.killed == 1 and gone.bad == 0, $gone
    doAssert gone.counts[qfAllZero] == 0
    doAssert report.stations.len == 3, $report.stations.len
    doAssert report.totals.files == 3 and report.totals.stations == 3, $report.totals
    doAssert gone.lacking == {}, "killed.sgd has one component: nothing to lack there"
    doAssert report.totals.lacking == 1 and report.totals.components == 2, $report.totals
    doAssert report.totals.traces == 7 and report.totals.killed == 1, $report.totals
    doAssert report.totals.bad == 6 and report.totals.counts[qfHeaderDead] == 1
    doAssert got.sink.result.sources.totals.traces == 0, "a source side with no file"

  block unread_does_not_stop_the_scan:
    let one = dir / "one.sgd"
    let notes = dir / "notes.txt"
    writeFile(notes, "not seismic\n")
    let missing = dir / "missing.sgd"
    let got = run(@[one, notes, missing], none)
    doAssert got.st == jsDone, got.error
    doAssert got.sink.result.ok
    doAssert got.sink.result.receivers.totals.files == 1
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
    doAssert got.sink.result.receivers.totals.files == 1, $got.sink.result.receivers.totals
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
    doAssert sink.result.receivers.totals.traces == 0
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
    doAssert sink.result.receivers.totals.traces == 0
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
    setJobHook(noteMeasuring)
    setFsHook(cancelOnSecondRead)
    defer:
      setJobHook(nil)
      setFsHook(nil)
    let sink = QualitySink()
    let id = lane.submit(qualitySpec(@[wide]), scanQuality(@[wide], none, sink))
    doAssert waitUntil(lane.state(id) in {jsDone, jsFailed, jsCancelled})
    doAssert lane.state(id) == jsCancelled, $lane.state(id) & " " & lane.info(id).get.error
    doAssert sink.result.receivers.totals.traces == 0
    doAssert sink.result.unread.len == 0

  block one_measuring_phase_a_file:
    # two files of 1100 and 600 traces, three and two chunks: a phase restarts the bar and
    # its time estimate, so each file has one
    var paths: seq[string] = @[]
    for (name, n) in [("long1.sgd", 1100), ("long2.sgd", 600)]:
      var traces: seq[tuple[line, point: float64; component: uint8; status: TraceStatus;
        samples: seq[float32]]] = @[]
      for i in 0 ..< n:
        traces.add (line: 50.0, point: float64(i + 1), component: 1'u8, status: tsLive,
          samples: @[0'f32, 1'f32])
      seismicFile(dir / name, 1, traces)
      paths.add dir / name
    measurings = 0
    setJobHook(countMeasuring)
    defer: setJobHook(nil)
    let got = run(paths, none)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    doAssert got.sink.result.receivers.totals.traces == 1700, $got.sink.result.receivers.totals
    doAssert measurings == 2, $measurings & " measuring phases for two files"

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
    # the file has no line and point: its two traces are the one unknown station, so the
    # counts are the two traces' findings, each measured at its own interval
    let report = got.sink.result.receivers
    doAssert report.stations.len == 1 and report.stations[0].seen == 2, $report.stations
    let row = report.stations[0]
    let a = findingsOf(traceAmplitude(slow, 4.0).flags, false)
    let b = findingsOf(traceAmplitude(fast, 2.0).flags, false)
    doAssert row.bad == ord(a.len > 0) + ord(b.len > 0), $row.bad & " want " & $a & $b
    for q in Finding:
      doAssert row.counts[q] == ord(q in a) + ord(q in b), $q & " " & $row.counts[q]

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
    doAssert got.sink.result.receivers.totals.traces == 1, $got.sink.result.receivers.totals
    doAssert got.sink.result.receivers.totals.files == 1
    doAssert "cut short" in unreadWhy(got.sink.result.unread, path),
      unreadWhy(got.sink.result.unread, path)
    let kept = got.sink.result.receivers.stations[0]
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
    # each of the four live traces (a record of its own) is read once for its samples and
    # once to find its record's first breaks; the dead, killed and auxiliary ones are records
    # of their own that are not judged, so they are not read at all (the first-break pass reads
    # a judged record whole, skipped traces inside it included: that is not counted here)
    doAssert mixReads - deadReads == 8, $mixReads & " - " & $deadReads
    let report = mixScan.sink.result.receivers
    doAssert report.totals.traces == 6 and report.totals.killed == 1, $report.totals
    doAssert report.totals.counts[qfHeaderDead] == 1, $report.totals.counts
    var ramp = newSeq[float32](32)
    for i in 0 ..< ramp.len: ramp[i] = float32(i + 1)
    let want = findingsOf(traceAmplitude(ramp, 2.0).flags, false)
    # the file has no line and point: one unknown station holds the four measured live
    # traces, the killed one and the dead one; the auxiliary trace is not a note
    doAssert report.stations.len == 1, $report.stations
    let row = report.stations[0]
    doAssert row.seen == 6 and row.killed == 1, $row
    doAssert row.bad == 4 * ord(want.len > 0) + 1, $row.bad & " want " & $want
    for q in Finding:
      doAssert row.counts[q] == 4 * ord(q in want) + ord(q == qfHeaderDead), $q

  block noisy_and_weak_traces_are_counted_as_the_map_finds_them:
    withFixtures fx:
      # 64 traces of one record: traces 40 and 50 are the noisy ones (the map's test, on the
      # same shot, names the same two), trace 60 planted weak
      let shot = fx.noisyShot("both.sgy", weakAt = 60)
      let plain = fx.noisyShot("plain.sgy")
      let got = run(@[shot, plain], none)
      doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
      let report = got.sink.result.receivers
      # each file alone is one station of 64 traces (the fixture has no line and point)
      let one = run(@[shot], none).sink.result.receivers
      let a = one.stations[0]
      # the loud traces near the source are inside the area: not judged, so not tested
      # (they are tested for weak)
      doAssert a.noisyTested in NoisyTraces div 2 ..< NoisyTraces and a.noisy == 2 and
        a.weakTested > a.noisyTested and a.weak == 1, $a
      let b = run(@[plain], none).sink.result.receivers.stations[0]
      doAssert b.noisyTested == a.noisyTested and b.weakTested == a.weakTested and
        b.noisy == 2 and b.weak == 0, $b
      doAssert report.totals.noisyTested == 2 * a.noisyTested and report.totals.noisy == 4 and
        report.totals.weakTested == 2 * a.weakTested and report.totals.weak == 1,
        $report.totals
      doAssert report.totals.bad == 0, "noisy and weak are not findings: " & $report.totals.bad
      doAssert stationsCsv(report.stations).splitLines[0].endsWith(",noisy,tested (weak),weak")
      doAssert totalsCsv(report.totals).splitLines[1].endsWith(",4," &
        $report.totals.weakTested & ",1")

  block a_trace_not_tested_leaves_its_cells_empty:
    withFixtures fx:
      let shot = fx.noisyShot("killed.sgy")
      var edits = initTable[string, FileEdits]()
      var killed = FileEdits()
      for t in 0 ..< NoisyTraces: discard killed.change(teKilled, [t], true)
      edits[shot] = killed
      let got = run(@[shot], edits)
      doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
      let report = got.sink.result.receivers
      doAssert report.totals.killed == NoisyTraces and report.totals.noisyTested == 0 and
        report.totals.weakTested == 0, $report.totals
      doAssert totalsCsv(report.totals).splitLines[1].endsWith(",0,,0,"), "cells not empty"
      doAssert stationsCsv(report.stations).splitLines[1].endsWith(",0,,0,"), "cells not empty"

  block measures_are_unchanged:
    # The figures below were taken from the scan before the table was by station, on this
    # data: the measures of every trace are the same, only the rows they are counted in differ.
    let a = dir / "b1.sgd"
    let b = dir / "b2.sgd"
    let z = zeros(32)
    seismicFile(a, 1, @[
      (line: 10.0, point: 1.0, component: 1'u8, status: tsLive, samples: z),
      (line: 10.0, point: 1.0, component: 1'u8, status: tsLive, samples: clippedSamples()),
      (line: 10.0, point: 1.0, component: 1'u8, status: tsLive, samples: nanSamples()),
      (line: 20.0, point: 1.0, component: 1'u8, status: tsDead, samples: z),
      (line: 10.0, point: 1.0, component: 2'u8, status: tsLive, samples: z)])
    seismicFile(b, 2, @[(line: 10.0, point: 1.0, component: 1'u8, status: tsLive, samples: z)])
    let t = run(@[a, b], none).sink.result.receivers.totals
    doAssert (t.files, t.traces, t.killed, t.bad) == (2, 6, 0, 6), $t
    doAssert t.counts == [1, 3, 0, 1, 0, 0, 1], $t.counts
    doAssert (t.noisyTested, t.noisy, t.weakTested, t.weak) == (2, 0, 2, 0), $t
    withFixtures fx:
      let shot = fx.noisyShot("both.sgy", weakAt = 60)
      let plain = fx.noisyShot("plain.sgy")
      let n = run(@[shot, plain], none).sink.result.receivers.totals
      doAssert (n.files, n.traces, n.killed, n.bad) == (2, 128, 0, 0), $n
      doAssert n.counts == [0, 0, 0, 0, 0, 0, 0], $n.counts
      doAssert (n.noisyTested, n.noisy, n.weakTested, n.weak) == (102, 4, 128, 1), $n

  block a_station_missing_a_component_is_listed:
    let path = dir / "three.sgd"
    let z = zeros(32)
    seismicFile(path, 1, @[
      (line: 10.0, point: 1.0, component: 1'u8, status: tsLive, samples: z),
      (line: 10.0, point: 1.0, component: 2'u8, status: tsLive, samples: z),
      (line: 10.0, point: 1.0, component: 3'u8, status: tsLive, samples: z),
      (line: 10.0, point: 2.0, component: 1'u8, status: tsLive, samples: z),
      (line: 10.0, point: 2.0, component: 3'u8, status: tsLive, samples: z)])
    let got = run(@[path], none)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    let report = got.sink.result.receivers
    doAssert stationAt(report.stations, 10, 1).lacking == {}
    doAssert stationAt(report.stations, 10, 2).lacking == {2'u8}, $report.stations
    doAssert report.totals.lacking == 1 and report.totals.components == 3, $report.totals

  block a_folder_scan_takes_subfolders_only_when_asked:
    let folder = dir / "tree"
    createDir(folder / "inner")
    let z = zeros(32)
    seismicFile(folder / "top.sgd", 1, @[
      (line: 10.0, point: 1.0, component: 1'u8, status: tsLive, samples: z),
      (line: 10.0, point: 2.0, component: 1'u8, status: tsLive, samples: z)])
    seismicFile(folder / "inner" / "low.sgd", 2, @[
      (line: 10.0, point: 2.0, component: 1'u8, status: tsLive, samples: clippedSamples()),
      (line: 10.0, point: 3.0, component: 1'u8, status: tsLive, samples: z)])
    let flat = runFolder(folder, false)
    doAssert flat.st == jsDone, flat.error & " / " & flat.sink.result.reason
    doAssert flat.sink.result.receivers.totals.files == 1,
      "the folder alone read " & $flat.sink.result.receivers.totals.files & " files"
    doAssert flat.sink.result.receivers.stations.len == 2
    let deep = runFolder(folder, true)
    doAssert deep.st == jsDone, deep.error & " / " & deep.sink.result.reason
    let report = deep.sink.result.receivers
    doAssert report.totals.files == 2 and report.stations.len == 3, $report.totals
    # station 10:2 is in both files: one row, the counts of both
    let both = stationAt(report.stations, 10, 2)
    doAssert both.seen == 2 and both.counts[qfAllZero] == 1 and both.counts[qfClipped] == 1,
      $both

  block a_receiver_gather_is_counted_at_its_sources:
    # one receiver, three sources: its traces are named by the source stations
    let path = dir / "gather.sgd"
    var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
      numSamples: 32, time: 1_700_000_000.0))
    for i in 0 ..< 3:
      writeTraceAt(w, i + 1, 1, 5, 5, 1, tsLive, zeros(32), srcLine = 80,
        srcPoint = float64(i + 1))
    doAssert w.close().len == 0
    let got = run(@[path], none)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    doAssert got.sink.result.receivers.totals.traces == 0
    let report = got.sink.result.sources
    doAssert report.stations.len == 3 and report.totals.traces == 3, $report.totals
    doAssert stationAt(report.stations, 80, 2).seen == 1

  block the_progress_reads_as_files_and_a_share:
    # the job counts 1000 units a file: 1450 of 3000 is in the second file of three
    doAssert scanProgressWords(1450, 3000) == "file 2 of 3, 48%", scanProgressWords(1450, 3000)
    doAssert scanProgressWords(0, 3000) == "file 1 of 3, 0%"
    doAssert scanProgressWords(3000, 3000) == "file 3 of 3, 100%"
    doAssert scanProgressWords(12, 0) == "", "a total not known has no words"

when isMainModule:
  main()
