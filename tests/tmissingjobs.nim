## A background job counts, for the seismic files it is given, the stations the
## survey's relation records call for that the files do not hold. A shot gather
## is checked against its X record (receiver stations), a sliced receiver
## gather against its O record, loaded or derived from the X records (source
## stations); a continuous receiver recording is not checked. The components of
## a station count once. Paths come back relative to the folder; a file that
## is not seismic or cannot be read is skipped; no survey fails the job with
## one sentence; a cancel leaves the sink empty; the folder walk goes into
## subfolders only when asked.
##
## Seen to fail: with the record number allowed to match a gather with no source station,
## `record_number_alone_never_matches` rejected a checked record; with a receiver checked in
## each gather alone,
## `receiver_slices_are_one_check` rejected 3 records for 1; with the subfolder flag ignored (always on),
## `subfolders_only_when_asked` rejected 3 files for the walk without them;
## with the continuous kind not looked for, `continuous_is_not_checked`
## rejected a checked record of 4 missing stations; with no stored index cache,
## `second_scan_uses_the_index` rejected a second scan that walked headers
## (3 then 3); with a cancel during the report still stored,
## `cancel_during_the_report` rejected a job that finished done.

import std/[os, strutils, times]
when defined(release):
  import std/[monotimes, times]
import parseSEG
import viewSEG/core/[jobs, missingjobs, missingreport]
import utils/[faultyfs, kindfiles, waiting]

proc put(line: var string; at: int; text: string) =
  let i = at - 1
  for j, c in text:
    if i + j < line.len: line[i + j] = c

proc xRec(record: int; srcLine, srcPoint: string; fromCh, toCh, rcvLine, fromR,
    toR: int): string =
  result = repeat(' ', 80)
  result[0] = 'X'
  put(result, 2, "T1")
  put(result, 8, align($record, 8))
  put(result, 16, "11")
  put(result, 18, align(srcLine, 10))
  put(result, 28, align(srcPoint, 10))
  put(result, 38, "1")
  put(result, 39, align($fromCh, 5))
  put(result, 44, align($toCh, 5))
  put(result, 49, "1")
  put(result, 50, align($rcvLine & ".00", 10))
  put(result, 60, align($fromR & ".00", 10))
  put(result, 70, align($toR & ".00", 10))
  put(result, 80, "1")

proc oRec(record: int; rcvLine, rcvPoint, srcLine: string; fromS, toS: int): string =
  ## An O record: the receiver is in the source columns, the sources in the
  ## receiver columns, as SPS lays an O record out.
  result = xRec(record, rcvLine, rcvPoint, 1, toS - fromS + 1, parseInt(srcLine), fromS, toS)
  result[0] = 'O'

proc surveyOf(lines: varargs[string]): ref SurveyGeometry =
  const H00 = "H00 SPS format version number   SPS 2.1;"
  var g = SurveyGeometry()
  g.addSps(parseSps(H00 & "\n" & lines.join("\n")))
  result = new SurveyGeometry
  result[] = g

proc shotFile(path: string; shots: openArray[tuple[record: int; src: float64;
    receivers: Slice[int]]]; components = 1) =
  ## Each receiver station is written once for each component (1 to `components`).
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0))
  let samples = @[0'f32]
  for shot in shots:
    var ch = 1
    for point in shot.receivers:
      for comp in 1 .. components:
        var k = initTraceKeys()
        k.record = float64(shot.record)
        k.channel = float64(ch)
        k.component = uint8(comp)
        k.srcLine = 1
        k.srcPoint = shot.src
        k.srcIndex = 1
        k.rcvLine = 10
        k.rcvPoint = float64(point)
        k.rcvIndex = 1
        k.intervalUs = 2000
        k.status = tsLive
        w.writeTrace(k, samples)
        inc ch
  doAssert w.close().len == 0, "shot file was not written: " & path

proc receiverFile(path: string; record: int; receiver: float64;
    sources: openArray[float64]) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0, receiverGather: true))
  let samples = @[0'f32]
  for i, src in sources:
    var k = initTraceKeys()
    k.record = float64(record)
    k.channel = float64(i + 1)
    k.srcLine = 1
    k.srcPoint = src
    k.srcIndex = 1
    k.rcvLine = 10
    k.rcvPoint = receiver
    k.rcvIndex = 1
    k.intervalUs = 2000
    k.status = tsLive
    w.writeTrace(k, samples)
  doAssert w.close().len == 0, "receiver file was not written: " & path

proc slicedFile(path: string; stations: openArray[tuple[receiver: float64;
    sources: seq[float64]]]; oneRecord = false) =
  ## Receiver gathers cut in slices, as the slicer writes them: each receiver
  ## has a record for each shot slice (one trace), or all its traces in one
  ## record (`oneRecord`).
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 10, time: 1_700_000_000.0, receiverGather: true))
  let samples = newSeq[float32](10)
  var ch = 0
  var rec = 0
  for st in stations:
    for slice, src in st.sources:
      inc ch
      if not oneRecord or slice == 0: inc rec
      var k = initTraceKeys()
      k.record = float64(100 + rec)
      k.channel = float64(ch)
      k.srcLine = 1
      k.srcPoint = src
      k.srcIndex = 1
      k.rcvLine = 10
      k.rcvPoint = st.receiver
      k.rcvIndex = 1
      k.intervalUs = 2000
      k.time = 1_700_000_000.0 + 60.0 * float64(slice)
      k.status = tsLive
      w.writeTrace(k, samples)
  doAssert w.close().len == 0, "sliced file was not written: " & path

proc plainFile(path: string; record: int; receivers: Slice[int]; stationless = false;
    sourceless = false) =
  ## One shot record (source 1) of the receivers; `sourceless`: no source station in
  ## the headers, `stationless`: no receiver station either.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0))
  var ch = 0
  for point in receivers:
    inc ch
    var k = initTraceKeys()
    k.record = float64(record)
    k.channel = float64(ch)
    if not sourceless:
      k.srcLine = 1
      k.srcPoint = 1
      k.srcIndex = 1
    if not stationless:
      k.rcvLine = 10
      k.rcvPoint = float64(point)
      k.rcvIndex = 1
    k.intervalUs = 2000
    k.status = tsLive
    w.writeTrace(k, @[0'f32])
  doAssert w.close().len == 0, "file was not written: " & path

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc run(folder: string; paths: seq[string]; relations: ref SurveyGeometry; cacheDir = ""):
    tuple[st: JobState; sink: MissingSink; error: string] =
  let jobs = initJobs()
  let sink = MissingSink()
  let id = jobs.submit(missingSpec(folder, paths),
    scanMissing(folder, paths, relations, sink, cacheDir))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the scan did not finish: " & $jobs.state(id)
  let info = jobs.info(id).get
  (info.state, sink, info.error)

proc rowAt(rows: openArray[StationRow]; line, point: float64): StationRow =
  for r in rows:
    if r.line == line and r.point == point: return r
  doAssert false, "no station " & $line & ":" & $point

proc skippedWhy(rows: openArray[tuple[path, why: string]]; path: string): string =
  for r in rows:
    if r.path == path: return r.why
  doAssert false, "not skipped: " & path

var lane: Jobs
var reads: int

proc stopOnSecond(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if back or not phase.startsWith("reading"): return
  inc reads
  if reads >= 2: discard lane.cancel(id)

proc stopOnReport(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if not back and phase == "reporting": discard lane.cancel(id)

proc main*() =
  let dir = getTempDir() / ("viewseg-missing-" & $getCurrentProcessId())
  createDir(dir)
  createDir(dir / "sub")

  block spec_names_the_folder:
    let spec = missingSpec(dir / "line12", @["a.sgd"])
    doAssert spec.title == "Missing traces in line12", spec.title
    doAssert spec.lane == jlBackground
    doAssert spec.reads == @["a.sgd"]
    doAssert missingSpec("", @[]).title == "Missing traces"

  block no_survey:
    let got = run(dir, @[], nil)
    doAssert got.st == jsFailed, $got.st & " " & got.error
    doAssert got.error == NoSurvey, got.error
    doAssert not got.sink.result.ok
    doAssert got.sink.result.reason == NoSurvey, got.sink.result.reason
    doAssert got.sink.result.shot.stats.records == 0
    let empty = new SurveyGeometry
    let again = run(dir, @[], empty)
    doAssert again.st == jsFailed and again.error == NoSurvey, again.error

  block shot_gather_against_x:
    let survey = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4))
    let path = dir / "sub" / "one.sgd"
    shotFile(path, [(record: 1, src: 1.0, receivers: 1 .. 2)])
    writeFile(dir / "notes.txt", "not seismic\n")
    writeFile(dir / "gone.sgd", "x")
    install()
    fault(dir / "gone.sgd", fkIo)
    let got = run(dir, @[path, dir / "notes.txt", dir / "gone.sgd"], survey)
    releaseAll()
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    let r = got.sink.result
    doAssert r.ok and r.receiver.stats.records == 0
    let t = r.shot.stats
    doAssert t.side == ssReceivers and t.files == 1 and t.records == 1, $t
    doAssert t.inTemplate == 4 and t.found == 2 and t.missing == 2, $t
    doAssert abs(t.percentMissing - 50.0) < 1e-9, $t
    doAssert t.expectedInRecords == 4 and t.presentInRecords == 2 and
      t.missingInRecords == 2 and abs(t.percentMissingInRecords - 50.0) < 1e-9, $t
    doAssert r.shot.rows.len == 2, $r.shot.rows
    doAssert rowAt(r.shot.rows, 10, 3).missing == 1 and rowAt(r.shot.rows, 10, 4).missing == 1
    doAssert skippedWhy(r.skipped, "notes.txt") == "not a SEG-Y, SEG-D or SEG-2 file"
    doAssert skippedWhy(r.skipped, "gone.sgd") == "Input/output error"

  block records_of_one_file:
    ## Two records of one file: the figures are the stations once and the
    ## station-records both ways.
    let survey = surveyOf(
      xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4),
      xRec(2, "1.00", "2.00", 1, 4, 10, 1, 4))
    let path = dir / "two.sgd"
    shotFile(path, [
      (record: 1, src: 1.0, receivers: 1 .. 3),
      (record: 2, src: 2.0, receivers: 2 .. 3)])
    let got = run(dir, @[path], survey)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    let t = got.sink.result.shot.stats
    doAssert t.files == 1 and t.records == 2, $t
    doAssert t.inTemplate == 4 and t.found == 3 and t.missing == 2, $t
    doAssert t.expectedInRecords == 8 and t.presentInRecords == 5 and
      t.missingInRecords == 3, $t
    let rows = got.sink.result.shot.rows
    doAssert rowAt(rows, 10, 4).missing == 2 and rowAt(rows, 10, 1).missing == 1, $rows
    doAssert rows.len == 2

  block components_count_a_station_once:
    ## The same stations written with one, three and four traces each give the
    ## same station figures: a station is present when any trace of it is.
    let survey = surveyOf(xRec(1, "1.00", "1.00", 1, 12, 10, 1, 12))
    for components in [1, 3, 4]:
      let path = dir / ("comp" & $components & ".sgd")
      shotFile(path, [(record: 1, src: 1.0, receivers: 1 .. 8)], components)
      let got = run(dir, @[path], survey)
      doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
      let t = got.sink.result.shot.stats
      doAssert t.inTemplate == 12 and t.found == 8 and t.missing == 4, $components & " " & $t
      doAssert t.expectedInRecords == 12 and t.presentInRecords == 8 and
        t.missingInRecords == 4, $components & " " & $t
      doAssert abs(t.percentMissing - 100.0 / 3.0) < 1e-9, $t
      doAssert got.sink.result.shot.rows.len == 4 and
        rowAt(got.sink.result.shot.rows, 10, 12).missing == 1

  block receiver_gather_against_derived_o:
    let survey = surveyOf(
      xRec(1, "1.00", "1.00", 1, 1, 10, 1, 1),
      xRec(2, "1.00", "2.00", 1, 1, 10, 1, 1),
      xRec(3, "1.00", "3.00", 1, 1, 10, 1, 1))
    let path = dir / "node.sgd"
    receiverFile(path, 1, 1.0, [1.0, 2.0])
    let got = run(dir, @[path], survey)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    let t = got.sink.result.receiver.stats
    doAssert t.side == ssSources and t.derived and t.files == 1 and t.records == 1, $t
    doAssert t.inTemplate == 3 and t.found == 2 and t.missing == 1, $t
    doAssert got.sink.result.shot.stats.records == 0
    doAssert rowAt(got.sink.result.receiver.rows, 1, 3).missing == 1

  block loaded_o_records:
    ## The same gather, with the O record loaded rather than derived.
    let survey = surveyOf(
      xRec(1, "1.00", "1.00", 1, 1, 10, 1, 1),
      xRec(2, "1.00", "2.00", 1, 1, 10, 1, 1),
      xRec(3, "1.00", "3.00", 1, 1, 10, 1, 1),
      oRec(9, "10.00", "1.00", "1", 1, 3))
    let path = dir / "node-o.sgd"
    receiverFile(path, 1, 1.0, [1.0, 2.0])
    let got = run(dir, @[path], survey)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    let t = got.sink.result.receiver.stats
    doAssert not t.derived, $t
    doAssert t.inTemplate == 3 and t.found == 2 and t.missing == 1, $t
    doAssert rowAt(got.sink.result.receiver.rows, 1, 3).missing == 1

  block folder_adds_up_across_files:
    ## One more file lacking a station adds one to its Missing.
    let survey = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4))
    createDir(dir / "add")
    let a = dir / "add" / "a.sgd"
    let b = dir / "add" / "b.sgd"
    let c = dir / "add" / "c.sgd"
    shotFile(a, [(record: 1, src: 1.0, receivers: 1 .. 2)])
    shotFile(b, [(record: 1, src: 1.0, receivers: 1 .. 3)])
    shotFile(c, [(record: 1, src: 1.0, receivers: 1 .. 2)])
    let got = run(dir / "add", @[a, b, c], survey)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    let r = got.sink.result.shot
    doAssert r.stats.files == 3 and r.stats.records == 3, $r.stats
    doAssert rowAt(r.rows, 10, 3).missing == 2 and rowAt(r.rows, 10, 4).missing == 3, $r.rows
    doAssert r.stats.inTemplate == 4 and r.stats.found == 3 and r.stats.missing == 2, $r.stats
    doAssert r.stats.expectedInRecords == 12 and r.stats.presentInRecords == 7, $r.stats

  block subfolders_only_when_asked:
    let survey = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4))
    let root = dir / "walk"
    createDir(root / "inner")
    shotFile(root / "top.sgd", [(record: 1, src: 1.0, receivers: 1 .. 4)])
    shotFile(root / "inner" / "deep.sgd", [(record: 1, src: 1.0, receivers: 1 .. 2)])
    shotFile(root / "inner" / "deeper.sgd", [(record: 1, src: 1.0, receivers: 1 .. 3)])
    for subfolders in [false, true]:
      let lane = initJobs()
      let sink = MissingSink()
      let id = lane.submit(missingSpec(root, @[root]),
        folderScan(root, subfolders, "", survey, sink))
      doAssert waitUntil(lane.state(id) in {jsDone, jsFailed, jsCancelled}),
        "the walk did not finish"
      doAssert lane.state(id) == jsDone, lane.info(id).get.error
      let t = sink.result.shot.stats
      doAssert t.files == (if subfolders: 3 else: 1), "subfolders " & $subfolders & ": " & $t
      doAssert sink.result.shot.rows.len == (if subfolders: 2 else: 0), $sink.result.shot.rows

  block continuous_is_not_checked:
    let survey = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4))
    let path = writeSpecs(dir / "cont", "cont", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
    let got = run(dir, @[path], survey)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    let r = got.sink.result
    doAssert r.shot.stats.records == 0 and r.receiver.stats.records == 0, $r.shot.stats
    doAssert r.notChecked.len == 1 and r.notChecked[0].path == "cont" / "cont.sgd", $r.notChecked
    doAssert "continuous" in r.notChecked[0].why

  block ambiguous_is_unmatched:
    let survey = surveyOf(
      xRec(1, "1.00", "1.00", 1, 2, 10, 1, 2),
      xRec(2, "1.00", "1.00", 1, 2, 10, 1, 2),
      xRec(3, "1.00", "9.00", 1, 1, 10, 1, 1))
    let path = dir / "amb.sgd"
    shotFile(path, [(record: 9, src: 1.0, receivers: 1 .. 2)])
    let got = run(dir, @[path], survey)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    doAssert got.sink.result.shot.stats.records == 0
    doAssert got.sink.result.unmatched.len == 1, $got.sink.result.unmatched.len
    let u = got.sink.result.unmatched[0]
    doAssert u.path == "amb.sgd" and u.record == 9, $u
    doAssert u.why ==
      "2 survey records share this source and the record number matches neither", u.why

  block receiver_matches_by_station:
    ## Derived receiver records are numbered after the survey's. A gather
    ## whose record number equals one of those is not that other receiver.
    let survey = surveyOf(
      xRec(1, "1.00", "1.00", 1, 1, 10, 1, 1),
      xRec(2, "1.00", "2.00", 1, 1, 10, 2, 2))
    let wrong = dir / "wrong-node.sgd"
    receiverFile(wrong, 3, 99.0, [1.0, 2.0])
    let got = run(dir, @[wrong], survey)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    doAssert got.sink.result.receiver.stats.records == 0
    doAssert got.sink.result.unmatched.len == 1, $got.sink.result.unmatched
    let u = got.sink.result.unmatched[0]
    doAssert u.path == "wrong-node.sgd" and u.record == 3, $u
    doAssert u.why == "no O record matches this receiver", u.why
    let right = dir / "right-node.sgd"
    receiverFile(right, 3, 2.0, [2.0, 8.0])
    let rightGot = run(dir, @[right], survey)
    doAssert rightGot.st == jsDone, rightGot.error
    doAssert rightGot.sink.result.unmatched.len == 0, $rightGot.sink.result.unmatched
    let t = rightGot.sink.result.receiver.stats
    doAssert t.records == 1 and t.inTemplate == 1 and t.found == 1 and t.missing == 0, $t

  block receiver_slices_are_one_check:
    ## A receiver that recorded sources 1, 2 and 4 of 1..4 as three records is one
    ## check of that receiver: template 4, found 3, missing 1; the same traces as
    ## one record give the same answer; two receivers in one file are two checks.
    let survey = surveyOf(
      xRec(1, "1.00", "1.00", 1, 1, 10, 7, 7),
      xRec(2, "1.00", "2.00", 1, 1, 10, 7, 7),
      xRec(3, "1.00", "3.00", 1, 1, 10, 7, 7),
      xRec(4, "1.00", "4.00", 1, 1, 10, 7, 7))
    for oneRecord in [false, true]:
      let path = dir / ("slices" & $oneRecord & ".sgd")
      slicedFile(path, [(receiver: 7.0, sources: @[1.0, 2.0, 4.0])], oneRecord)
      let got = run(dir, @[path], survey)
      doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
      let r = got.sink.result
      let t = r.receiver.stats
      doAssert r.unmatched.len == 0, $r.unmatched
      doAssert t.files == 1 and t.records == 1, $oneRecord & " " & $t
      doAssert t.inTemplate == 4 and t.found == 3 and t.missing == 1, $oneRecord & " " & $t
      doAssert t.expectedInRecords == 4 and t.presentInRecords == 3, $t
      doAssert r.receiver.rows.len == 1 and rowAt(r.receiver.rows, 1, 3).missing == 1,
        $r.receiver.rows
    let two = dir / "two-receivers.sgd"
    slicedFile(two, [(receiver: 7.0, sources: @[1.0, 2.0, 4.0]),
      (receiver: 8.0, sources: @[1.0, 2.0])])
    let survey2 = surveyOf(
      xRec(1, "1.00", "1.00", 1, 2, 10, 7, 8),
      xRec(2, "1.00", "2.00", 1, 2, 10, 7, 8),
      xRec(3, "1.00", "3.00", 1, 1, 10, 7, 7),
      xRec(4, "1.00", "4.00", 1, 1, 10, 7, 7))
    let got2 = run(dir, @[two], survey2)
    doAssert got2.st == jsDone, got2.error & " / " & got2.sink.result.reason
    let t2 = got2.sink.result.receiver.stats
    doAssert got2.sink.result.unmatched.len == 0, $got2.sink.result.unmatched
    doAssert t2.files == 1 and t2.records == 2, $t2
    doAssert t2.expectedInRecords == 6 and t2.presentInRecords == 5 and
      t2.missingInRecords == 1, $t2

  block record_number_alone_never_matches:
    ## X1 is source 1 with receivers 1..4, X2 source 2 with receivers 5..8. The file is
    ## shot 1 with all of 1..4, no source station in the headers, file number 2: it is
    ## not checked against X2 by its number; it is listed as unmatched, nothing counted.
    let survey = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4),
      xRec(2, "1.00", "2.00", 1, 4, 10, 5, 8))
    let path = dir / "no-source.sgd"
    plainFile(path, 2, 1 .. 4, sourceless = true)
    let got = run(dir, @[path], survey)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    let r = got.sink.result
    doAssert r.shot.stats.records == 0 and r.shot.rows.len == 0, $r.shot.stats
    doAssert r.unmatched.len == 1, $r.unmatched
    doAssert r.unmatched[0].path == "no-source.sgd" and r.unmatched[0].record == 2
    doAssert r.unmatched[0].why == "no source station in the trace headers: it could " &
      "only be matched to the survey by its record number, which is not trusted",
      r.unmatched[0].why
    let same = dir / "with-source.sgd"
    plainFile(same, 2, 1 .. 4)
    let ok = run(dir, @[same], survey).sink.result
    doAssert ok.unmatched.len == 0 and ok.shot.stats.records == 1 and
      ok.shot.stats.missing == 0, $ok.shot.stats

  block cancel_leaves_the_sink:
    reads = 0
    lane = initJobs()
    let sink = MissingSink()
    setJobHook(stopOnSecond)
    defer: setJobHook(nil)
    let one = dir / "sub" / "one.sgd"
    let two = dir / "two.sgd"
    let survey = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4))
    let id = lane.submit(missingSpec(dir, @[one, two]),
      scanMissing(dir, @[one, two], survey, sink))
    doAssert waitUntil(lane.state(id) in {jsDone, jsFailed, jsCancelled}),
      "the scan did not finish: " & $lane.state(id)
    doAssert lane.state(id) == jsCancelled, $lane.state(id) & " " & lane.info(id).get.error
    doAssert not sink.result.ok
    doAssert sink.result.reason.len == 0
    doAssert sink.result.shot.stats.records == 0
    doAssert sink.result.skipped.len == 0

  block cancel_during_the_report:
    lane = initJobs()
    let sink = MissingSink()
    setJobHook(stopOnReport)
    defer: setJobHook(nil)
    let one = dir / "sub" / "one.sgd"
    let survey = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4))
    let id = lane.submit(missingSpec(dir, @[one]), scanMissing(dir, @[one], survey, sink))
    doAssert waitUntil(lane.state(id) in {jsDone, jsFailed, jsCancelled}),
      "the scan did not finish: " & $lane.state(id)
    doAssert lane.state(id) == jsCancelled, $lane.state(id) & " " & lane.info(id).get.error
    doAssert not sink.result.ok
    doAssert sink.result.reason.len == 0
    doAssert sink.result.shot.stats.records == 0
    doAssert sink.result.skipped.len == 0
    doAssert sink.result.unmatched.len == 0

  block second_scan_uses_the_index:
    install()
    let cache = dir / "index"
    let one = dir / "sub" / "cached.sgd"
    shotFile(one, [(record: 1, src: 1.0, receivers: 1 .. 4)])
    let survey = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4))
    resetCounts()
    let first = run(dir, @[one], survey, cache)
    doAssert first.st == jsDone, first.error
    doAssert first.sink.result.shot.stats.missing == 0
    let walked = calls(foMapped, one)
    resetCounts()
    let again = run(dir, @[one], survey, cache)
    let reread = calls(foMapped, one)
    doAssert again.st == jsDone, again.error
    doAssert again.sink.result.shot.stats.missing == 0
    doAssert reread < walked, "second scan walked headers: " & $reread & " then " & $walked
    shotFile(one, [(record: 1, src: 1.0, receivers: 1 .. 2)])
    setLastModificationTime(one, getTime() + initDuration(seconds = 5))
    let changed = run(dir, @[one], survey, cache)
    doAssert changed.st == jsDone, changed.error
    doAssert changed.sink.result.shot.stats.missing == 2, "a changed file was not seen: " &
      $changed.sink.result.shot.stats.missing

  when defined(release):
    block folder_of_two_hundred:
      var lines: seq[string] = @[]
      lines.add xRec(1, "1.00", "1.00", 1, 1000, 10, 1, 1000)
      let survey = surveyOf(lines)
      var paths: seq[string] = @[]
      for n in 1 .. 200:
        let path = dir / ("f" & $n & ".sgd")
        var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
          numSamples: 1, time: 1_700_000_000.0))
        let samples = @[0'f32]
        for ch in 1 .. 1000:
          var k = initTraceKeys()
          k.record = 1
          k.channel = float64(ch)
          k.srcLine = 1
          k.srcPoint = 1
          k.srcIndex = 1
          k.rcvLine = 10
          k.rcvPoint = float64(ch)
          k.rcvIndex = 1
          k.intervalUs = 2000
          k.status = tsLive
          w.writeTrace(k, samples)
        doAssert w.close().len == 0, path
        paths.add path
      let t0 = getMonoTime()
      let got = run(dir, paths, survey)
      let ms = (getMonoTime() - t0).inMilliseconds
      doAssert got.st == jsDone, got.error
      doAssert got.sink.result.shot.stats.files == 200
      doAssert got.sink.result.shot.stats.missing == 0
      echo "tmissingjobs: ", paths.len, " files, ", ms, " ms, ",
        paths.len.float64 * 1000.0 / float64(max(ms, 1)), " files/s"

  echo "tmissingjobs: ok"

when isMainModule:
  main()
