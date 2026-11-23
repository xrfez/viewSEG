## A background job scans a folder's seismic files for the missing-trace
## report. Paths come back relative to the folder. A file that is not
## seismic, or that cannot be read, is skipped. No survey fails the job
## with one sentence. A cancel leaves the sink empty.
##
## Seen to fail: with a receiver gather matched by its record number,
## `receiver_matches_by_station` rejected a row of expected 1, present 1
## for the other receiver; with an ambiguous gather stored as a row,
## `ambiguous_is_unmatched` rejected a row of expected 0, present 0, missing 0;
## with the stored path
## left absolute, `shots_and_skips` rejected a file that was not `sub/one.sgd`.
##
## A receiver gather is checked with its stations swapped against the
## receiver relations stored as source records, so the library's
## source-domain check sees the gather's expected sources.

import std/[os, strutils]
when defined(release):
  import std/[monotimes, times]
import parseSEG
import viewSEG/core/[jobs, missingjobs, missingreport]
import utils/[faultyfs, waiting]

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
    receivers: Slice[int]]]) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0))
  let samples = @[0'f32]
  for shot in shots:
    var ch = 1
    for point in shot.receivers:
      var k = initTraceKeys()
      k.record = float64(shot.record)
      k.channel = float64(ch)
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

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc run(folder: string; paths: seq[string]; relations: ref SurveyGeometry):
    tuple[st: JobState; sink: MissingSink; error: string] =
  let jobs = initJobs()
  let sink = MissingSink()
  let id = jobs.submit(missingSpec(folder, paths),
    scanMissing(folder, paths, relations, sink))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the scan did not finish: " & $jobs.state(id)
  let info = jobs.info(id).get
  (info.state, sink, info.error)

proc pointAt(rows: openArray[PointRow]; line, point: float64): PointRow =
  for r in rows:
    if r.line == line and r.point == point: return r
  doAssert false, "no point " & $line & ":" & $point

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
    doAssert got.sink.result.report.records.len == 0
    let empty = new SurveyGeometry
    let again = run(dir, @[], empty)
    doAssert again.st == jsFailed and again.error == NoSurvey, again.error

  block shots_and_skips:
    let survey = surveyOf(
      xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4),
      xRec(2, "1.00", "2.00", 1, 4, 10, 1, 4))
    let one = dir / "sub" / "one.sgd"
    let two = dir / "two.sgd"
    shotFile(one, [(record: 1, src: 1.0, receivers: 1 .. 2)])
    shotFile(two, [
      (record: 1, src: 1.0, receivers: 1 .. 3),
      (record: 2, src: 2.0, receivers: 1 .. 3)])
    writeFile(dir / "notes.txt", "not seismic\n")
    writeFile(dir / "gone.sgd", "x")
    install()
    fault(dir / "gone.sgd", fkIo)
    let got = run(dir, @[one, two, dir / "notes.txt", dir / "gone.sgd"], survey)
    releaseAll()
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    doAssert got.sink.result.ok
    let t = got.sink.result.report.totals
    doAssert t.files == 2 and t.records == 3, $t
    doAssert t.expected == 8 and t.present == 6 and t.missing == 2, $t
    doAssert t.alsoIn == 1 and t.never == 1 and t.duplicates == 0 and t.extras == 0, $t
    doAssert t.xpsWithoutData.len == 0, $t.xpsWithoutData
    doAssert abs(t.percentMissing - 100.0 * 2.0 / 8.0) < 1e-9, $t.percentMissing
    let rows = got.sink.result.report.records
    doAssert rows.len == 3
    doAssert rows[0].file == "sub/one.sgd" or rows[1].file == "sub/one.sgd" or
      rows[2].file == "sub/one.sgd"
    var sawOne = false
    for r in rows:
      doAssert r.file in ["sub/one.sgd", "two.sgd"], r.file
      if r.file == "sub/one.sgd":
        sawOne = true
        doAssert r.record == 1 and r.missing == 2 and r.present == 2 and r.alsoIn == 1, $r
    doAssert sawOne
    let never = pointAt(got.sink.result.report.points, 10, 4)
    doAssert never.never and never.missingIn == 2 and never.expectedIn == 2, $never
    for p in got.sink.result.report.points:
      doAssert not (p.line == 10 and p.point == 3), "recorded in one file: " & $p
    doAssert skippedWhy(got.sink.result.skipped, "notes.txt") ==
      "not a SEG-Y, SEG-D or SEG-2 file"
    doAssert skippedWhy(got.sink.result.skipped, "gone.sgd") == "Input/output error"

  block receiver_gather:
    let survey = surveyOf(
      xRec(1, "1.00", "1.00", 1, 1, 10, 1, 1),
      xRec(2, "1.00", "2.00", 1, 1, 10, 1, 1),
      xRec(3, "1.00", "3.00", 1, 1, 10, 1, 1))
    let path = dir / "node.sgd"
    receiverFile(path, 1, 1.0, [1.0, 2.0])
    let got = run(dir, @[path], survey)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    let t = got.sink.result.report.totals
    doAssert t.files == 1 and t.records == 1, $t
    doAssert t.expected == 3 and t.present == 2 and t.missing == 1, $t
    doAssert t.never == 1, $t
    let miss = pointAt(got.sink.result.report.points, 1, 3)
    doAssert miss.never and miss.missingIn == 1, $miss

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
    let t = got.sink.result.report.totals
    doAssert t.expected == 3 and t.present == 2 and t.missing == 1 and t.never == 1, $t
    doAssert pointAt(got.sink.result.report.points, 1, 3).never

  block mixed_folder:
    let survey = surveyOf(
      xRec(1, "1.00", "1.00", 1, 2, 10, 1, 2),
      xRec(2, "1.00", "2.00", 1, 2, 10, 1, 2),
      xRec(3, "1.00", "3.00", 1, 2, 10, 1, 2))
    let shot = dir / "shot.sgd"
    let node = dir / "node2.sgd"
    shotFile(shot, [(record: 1, src: 1.0, receivers: 1 .. 1)])
    receiverFile(node, 7, 1.0, [1.0, 2.0])
    let got = run(dir, @[shot, node], survey)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    let rows = got.sink.result.report.records
    doAssert rows.len == 2, $rows.len
    var shotMissing, nodeMissing = false
    for r in rows:
      if r.file == "shot.sgd":
        doAssert r.missing == 1 and r.present == 1, $r
        shotMissing = true
      elif r.file == "node2.sgd":
        doAssert r.missing == 1 and r.present == 2, $r
        nodeMissing = true
    doAssert shotMissing and nodeMissing
    doAssert pointAt(got.sink.result.report.points, 10, 2).missingIn >= 1
    doAssert pointAt(got.sink.result.report.points, 1, 3).missingIn >= 1

  block ambiguous_is_unmatched:
    let survey = surveyOf(
      xRec(1, "1.00", "1.00", 1, 2, 10, 1, 2),
      xRec(2, "1.00", "1.00", 1, 2, 10, 1, 2),
      xRec(3, "1.00", "9.00", 1, 1, 10, 1, 1))
    let path = dir / "amb.sgd"
    shotFile(path, [(record: 9, src: 1.0, receivers: 1 .. 1)])
    let got = run(dir, @[path], survey)
    doAssert got.st == jsDone, got.error & " / " & got.sink.result.reason
    doAssert got.sink.result.report.records.len == 0, $got.sink.result.report.records
    doAssert got.sink.result.unmatched.len == 1, $got.sink.result.unmatched.len
    let u = got.sink.result.unmatched[0]
    doAssert u.path == "amb.sgd" and u.record == 9, $u
    doAssert u.why ==
      "2 survey records share this source and the record number matches neither", u.why
    doAssert got.sink.result.report.totals.xpsWithoutData == @[3'i64],
      $got.sink.result.report.totals.xpsWithoutData

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
    doAssert got.sink.result.report.records.len == 0, $got.sink.result.report.records
    doAssert got.sink.result.unmatched.len == 1, $got.sink.result.unmatched
    let u = got.sink.result.unmatched[0]
    doAssert u.path == "wrong-node.sgd" and u.record == 3, $u
    doAssert u.why == "no survey record matches this gather", u.why
    let plain = dir / "plain-node.sgd"
    receiverFile(plain, 9, 99.0, [1.0, 2.0])
    let plainGot = run(dir, @[plain], survey)
    doAssert plainGot.sink.result.report.records.len == 0, $plainGot.sink.result.report.records
    doAssert plainGot.sink.result.unmatched.len == 1
    doAssert plainGot.sink.result.unmatched[0].why == "no survey record matches this gather"
    let right = dir / "right-node.sgd"
    receiverFile(right, 3, 2.0, [2.0, 8.0])
    let rightGot = run(dir, @[right], survey)
    doAssert rightGot.st == jsDone, rightGot.error
    doAssert rightGot.sink.result.unmatched.len == 0, $rightGot.sink.result.unmatched
    let t = rightGot.sink.result.report.totals
    doAssert t.records == 1 and t.expected == 1 and t.present == 1 and t.missing == 0, $t

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
    doAssert sink.result.report.records.len == 0
    doAssert sink.result.skipped.len == 0

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
      doAssert got.sink.result.report.totals.files == 200
      doAssert got.sink.result.report.totals.missing == 0
      echo "tmissingjobs: ", paths.len, " files, ", ms, " ms, ",
        paths.len.float64 * 1000.0 / float64(max(ms, 1)), " files/s"

  echo "tmissingjobs: ok"

when isMainModule:
  main()
