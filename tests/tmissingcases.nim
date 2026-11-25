## The missing-traces scan on small surveys laid out in many ways, each with
## the figures it must give: shot gathers of one and three components (by
## station and by channel), several records in a file, a receiver index that
## differs between records, duplicate and off-template traces, loaded and
## derived O records, a folder, a record with no source station or a wrong
## record number, files of one receiver (one trace, one station, one slice),
## sliced receivers with a record number for each slice or one for all, two X
## records at one source and two O records at one receiver, and a shot of one
## live receiver among other shots.
##
## Seen to fail: with a file of one receiver checked as a shot,
## `one_receiver_files` rejected 100 in the template, 1 found, 99 missing; with
## the X record at a shared source picked by the record number,
## `two_x_records_at_one_source` rejected found 0, missing 4; with the O record
## of a receiver picked by the record number, `two_o_records_at_one_receiver`
## rejected found 0, missing 3 (record 5) and an unmatched receiver (record 9);
## with any file of one receiver taken for receiver data,
## `a_shot_of_one_live_receiver_among_shots` rejected 4 shots and no missing receiver.

import std/[os, strutils]
import parseSEG
import viewSEG/core/[jobs, missingjobs, missingreport]
import utils/waiting

proc put(line: var string; at: int; text: string) =
  let i = at - 1
  for j, c in text:
    if i + j < line.len: line[i + j] = c

proc xRec(record: int; srcLine, srcPoint: string; fromCh, toCh, rcvLine, fromR,
    toR: int; rcvIndex = 1; chInc = 1): string =
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
  put(result, 49, $chInc)
  put(result, 50, align($rcvLine & ".00", 10))
  put(result, 60, align($fromR & ".00", 10))
  put(result, 70, align($toR & ".00", 10))
  put(result, 80, $rcvIndex)

proc oRec(record: int; rcvLine, rcvPoint, srcLine: string; fromS, toS: int): string =
  ## An O record: the receiver in the source columns, the sources in the receiver ones.
  result = xRec(record, rcvLine, rcvPoint, 1, toS - fromS + 1, parseInt(srcLine), fromS, toS)
  result[0] = 'O'

proc surveyMulti(lines: openArray[string]; multi: bool): ref SurveyGeometry =
  const H00 = "H00 SPS format version number   SPS 2.1;"
  var g = SurveyGeometry()
  g.multiComponent = multi
  g.addSps(parseSps(H00 & "\n" & lines.join("\n")))
  result = new SurveyGeometry
  result[] = g

proc surveyOf(lines: varargs[string]): ref SurveyGeometry = surveyMulti(lines, false)

type Tr = tuple[record: int; srcPoint: float64; rcvPoint: float64; comp: int; rcvIndex: int]

proc traceFile(path: string; traces: openArray[Tr]; noSrcStation = false) =
  ## Traces at source line 1 and receiver line 10, a channel count for each record.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0))
  var ch = 0
  var last = -1
  for t in traces:
    if t.record != last:
      ch = 0
      last = t.record
    inc ch
    var k = initTraceKeys()
    k.record = float64(t.record)
    k.channel = float64(ch)
    k.component = uint8(t.comp)
    if not noSrcStation:
      k.srcLine = 1
      k.srcPoint = t.srcPoint
      k.srcIndex = 1
    k.rcvLine = 10
    k.rcvPoint = t.rcvPoint
    k.rcvIndex = int16(t.rcvIndex)
    k.intervalUs = 2000
    k.status = tsLive
    w.writeTrace(k, @[0'f32])
  doAssert w.close().len == 0, "not written: " & path

proc receiverFile(path: string; record: int; receiver: float64;
    sources: openArray[float64]) =
  ## One receiver gather of one record: a trace from each source.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0, receiverGather: true))
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
    w.writeTrace(k, @[0'f32])
  doAssert w.close().len == 0, "not written: " & path

proc slicedFile(path: string; receiver: float64; sources: openArray[float64];
    recordPerSlice: bool) =
  ## One receiver cut in shot slices a minute apart, a record number for each
  ## slice or the same one for all.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 10, time: 1_700_000_000.0, receiverGather: true))
  for i, src in sources:
    var k = initTraceKeys()
    k.record = if recordPerSlice: float64(100 + i) else: 1.0
    k.channel = float64(i + 1)
    k.srcLine = 1
    k.srcPoint = src
    k.srcIndex = 1
    k.rcvLine = 10
    k.rcvPoint = receiver
    k.rcvIndex = 1
    k.intervalUs = 2000
    k.status = tsLive
    k.time = 1_700_000_000.0 + 60.0 * float64(i)
    w.writeTrace(k, newSeq[float32](10))
  doAssert w.close().len == 0, "not written: " & path

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc run(folder: string; paths: seq[string]; relations: ref SurveyGeometry):
    MissingJobResult =
  let jobs = initJobs()
  let sink = MissingSink()
  let id = jobs.submit(missingSpec(folder, paths),
    scanMissing(folder, paths, relations, sink, ""))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}), "the scan did not end"
  doAssert jobs.state(id) == jsDone, jobs.info(id).get.error
  sink.result

proc figures(r: StationReport): string =
  ## "files records inTemplate found missing | expected present missing", then the
  ## rows as line/point x missing.
  let s = r.stats
  result = $s.files & " " & $s.records & " " & $s.inTemplate & " " & $s.found & " " &
    $s.missing & " | " & $s.expectedInRecords & " " & $s.presentInRecords & " " &
    $s.missingInRecords
  for row in r.rows: result.add " " & $int(row.line) & "/" & $int(row.point) & "x" & $row.missing

proc expect(got, want: string) =
  doAssert got == want, "got " & got & ", want " & want

proc main*() =
  let dir = getTempDir() / ("viewseg-missing-cases-" & $getCurrentProcessId())
  createDir(dir)

  block one_component_shot:
    let sv = surveyOf(xRec(1, "1.00", "1.00", 1, 6, 10, 1, 6))
    let p = dir / "a.sgd"
    traceFile(p, [(1, 1.0, 1.0, 1, 1), (1, 1.0, 2.0, 1, 1), (1, 1.0, 4.0, 1, 1),
      (1, 1.0, 5.0, 1, 1)])
    expect(run(dir, @[p], sv).shot.figures, "1 1 6 4 2 | 6 4 2 10/3x1 10/6x1")

  block three_component_shot_by_station_and_by_channel:
    ## Station 2 lacks component 3, station 5 is absent.
    let sv = surveyMulti([xRec(1, "1.00", "1.00", 1, 18, 10, 1, 6, 1, 3)], true)
    var trs: seq[Tr] = @[]
    for p in 1 .. 6:
      if p != 5:
        for c in 1 .. 3:
          if not (p == 2 and c == 3): trs.add (1, 1.0, float64(p), c, 1)
    let p = dir / "b.sgd"
    traceFile(p, trs)
    expect(run(dir, @[p], sv).shot.figures, "1 1 6 5 1 | 6 5 1 10/5x1")
    let p2 = dir / "b2.sgd"
    var w = openSeismicWriter(p2, SegdOutputOptions(sampleIntervalUs: 2000,
      numSamples: 1, time: 1_700_000_000.0))
    for t in trs:
      var k = initTraceKeys()
      k.record = 1
      k.channel = float64(3 * (int(t.rcvPoint) - 1) + t.comp)
      k.component = uint8(t.comp)
      k.srcLine = 1
      k.srcPoint = 1
      k.srcIndex = 1
      k.intervalUs = 2000
      k.status = tsLive
      w.writeTrace(k, @[0'f32])
    doAssert w.close().len == 0
    expect(run(dir, @[p2], sv).shot.figures, "1 1 6 5 1 | 6 5 1 10/5x1")

  block two_records_in_a_file:
    let sv = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4),
      xRec(2, "1.00", "2.00", 1, 4, 10, 1, 4))
    let p = dir / "c.sgd"
    traceFile(p, [(1, 1.0, 1.0, 1, 1), (1, 1.0, 2.0, 1, 1), (1, 1.0, 3.0, 1, 1),
      (1, 1.0, 4.0, 1, 1), (2, 2.0, 1.0, 1, 1), (2, 2.0, 2.0, 1, 1), (2, 2.0, 4.0, 1, 1)])
    expect(run(dir, @[p], sv).shot.figures, "1 2 4 4 1 | 8 7 1 10/3x1")

  block receiver_index_differs_by_record:
    let sv = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4, 1),
      xRec(2, "1.00", "2.00", 1, 4, 10, 1, 4, 2))
    let p = dir / "d.sgd"
    traceFile(p, [(1, 1.0, 1.0, 1, 1), (1, 1.0, 2.0, 1, 1), (1, 1.0, 3.0, 1, 1),
      (2, 2.0, 1.0, 1, 2), (2, 2.0, 2.0, 1, 2), (2, 2.0, 4.0, 1, 2)])
    expect(run(dir, @[p], sv).shot.figures, "1 2 4 4 2 | 8 6 2 10/3x1 10/4x1")
    # one record calling a point at index 1 and at index 2, the data at index 1
    let sv2 = surveyOf(xRec(1, "1.00", "1.00", 1, 2, 10, 1, 2, 1),
      xRec(1, "1.00", "1.00", 3, 4, 10, 1, 2, 2))
    let p2 = dir / "d2.sgd"
    traceFile(p2, [(1, 1.0, 1.0, 1, 1), (1, 1.0, 2.0, 1, 1)])
    expect(run(dir, @[p2], sv2).shot.figures, "1 1 2 2 0 | 2 2 0")

  block duplicates_and_stations_off_the_template:
    let sv = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4))
    let p = dir / "e.sgd"
    traceFile(p, [(1, 1.0, 1.0, 1, 1), (1, 1.0, 1.0, 1, 1), (1, 1.0, 1.0, 1, 1),
      (1, 1.0, 2.0, 1, 1), (1, 1.0, 99.0, 1, 1), (1, 1.0, 100.0, 1, 1)])
    expect(run(dir, @[p], sv).shot.figures, "1 1 4 2 2 | 4 2 2 10/3x1 10/4x1")

  block loaded_o_records_and_derived_ones_agree:
    let xs = [xRec(1, "1.00", "1.00", 1, 3, 10, 1, 3), xRec(2, "1.00", "2.00", 1, 3, 10, 1, 3),
      xRec(3, "1.00", "3.00", 1, 3, 10, 1, 3), xRec(4, "1.00", "4.00", 1, 2, 10, 1, 2)]
    let p = dir / "g.sgd"
    receiverFile(p, 7, 2.0, [1.0, 3.0])
    let derived = run(dir, @[p], surveyOf(xs)).receiver
    doAssert derived.stats.derived
    expect(derived.figures, "1 1 4 2 2 | 4 2 2 1/2x1 1/4x1")
    let loaded = run(dir, @[p], surveyOf(@xs & @[oRec(50, "10.00", "2.00", "1", 1, 4)])).receiver
    doAssert not loaded.stats.derived
    expect(loaded.figures, "1 1 4 2 2 | 4 2 2 1/2x1 1/4x1")
    let p3 = dir / "g3.sgd"
    receiverFile(p3, 7, 3.0, [1.0, 3.0])
    expect(run(dir, @[p3], surveyOf(xs)).receiver.figures, "1 1 3 2 1 | 3 2 1 1/2x1")

  block a_folder_adds_up:
    let sv = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4),
      xRec(2, "1.00", "2.00", 1, 4, 10, 3, 6))
    createDir(dir / "h")
    let a = dir / "h" / "a.sgd"
    let b = dir / "h" / "b.sgd"
    traceFile(a, [(1, 1.0, 1.0, 1, 1), (1, 1.0, 2.0, 1, 1), (2, 2.0, 3.0, 1, 1),
      (2, 2.0, 5.0, 1, 1)])
    traceFile(b, [(1, 1.0, 1.0, 1, 1), (1, 1.0, 3.0, 1, 1), (1, 1.0, 4.0, 1, 1)])
    expect(run(dir / "h", @[a, b, a], sv).shot.figures,
      "2 3 6 5 4 | 12 7 5 10/2x1 10/3x1 10/4x2 10/6x1")

  block no_source_station_or_a_wrong_record_number:
    ## The shot at source 1 with all of 1..4 and record number 2 (X2 is source 2).
    let sv = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4),
      xRec(2, "1.00", "2.00", 1, 4, 10, 5, 8))
    let shot = [(2, 1.0, 1.0, 1, 1), (2, 1.0, 2.0, 1, 1), (2, 1.0, 3.0, 1, 1),
      (2, 1.0, 4.0, 1, 1)]
    let p = dir / "i.sgd"
    traceFile(p, shot, noSrcStation = true)
    let r = run(dir, @[p], sv)
    expect(r.shot.figures, "0 0 0 0 0 | 0 0 0")
    doAssert r.unmatched.len == 1 and r.unmatched[0].record == 2 and
      r.unmatched[0].why.startsWith("no source station in the trace headers"), $r.unmatched
    let p2 = dir / "j.sgd"
    traceFile(p2, shot)
    expect(run(dir, @[p2], sv).shot.figures, "1 1 4 4 0 | 4 4 0")

  block one_receiver_files:
    ## One shot of receivers 1..100: one trace, or one station's three components,
    ## is receiver 7 (its derived O record: source 1), not a shot lacking 99
    ## receivers. Two receivers of the shot are a shot.
    let sv = surveyOf(xRec(1, "1.00", "1.00", 1, 100, 10, 1, 100))
    let p = dir / "k.sgd"
    traceFile(p, [(1, 1.0, 7.0, 1, 1)])
    var r = run(dir, @[p], sv)
    expect(r.shot.figures, "0 0 0 0 0 | 0 0 0")
    expect(r.receiver.figures, "1 1 1 1 0 | 1 1 0")
    doAssert r.singleSlice
    let p2 = dir / "k2.sgd"
    traceFile(p2, [(1, 1.0, 7.0, 1, 1), (1, 1.0, 7.0, 2, 1), (1, 1.0, 7.0, 3, 1)])
    r = run(dir, @[p2], sv)
    expect(r.shot.figures, "0 0 0 0 0 | 0 0 0")
    expect(r.receiver.figures, "1 1 1 1 0 | 1 1 0")
    let p3 = dir / "k3.sgd"
    traceFile(p3, [(1, 1.0, 7.0, 1, 1), (1, 1.0, 8.0, 1, 1)])
    r = run(dir, @[p3], sv)
    doAssert r.shot.stats.records == 1 and r.shot.stats.found == 2 and
      r.shot.stats.missing == 98, r.shot.figures
    doAssert r.receiver.stats.records == 0 and not r.singleSlice
    # five shots of receivers 1..100: receiver 7 lacks the other four
    var xs: seq[string] = @[]
    for s in 1 .. 5: xs.add xRec(s, "1.00", $s & ".00", 1, 100, 10, 1, 100)
    for (name, n) in [("k4", 3), ("k5", 1)]:
      let path = dir / (name & ".sgd")
      var trs: seq[Tr] = @[]
      for c in 1 .. n: trs.add (1, 1.0, 7.0, c, 1)
      traceFile(path, trs)
      r = run(dir, @[path], surveyOf(xs))
      expect(r.shot.figures, "0 0 0 0 0 | 0 0 0")
      expect(r.receiver.figures, "1 1 5 1 4 | 5 1 4 1/2x1 1/3x1 1/4x1 1/5x1")
      doAssert r.singleSlice

  block a_shot_of_one_live_receiver_among_shots:
    ## Shots 1..5 of receivers 1..100, a file each; shot 1's file holds receiver 7 only
    ## (one trace, or its three components). One receiver and one source cannot say
    ## which it is; the other files are shots, so it is shot 1, lacking 99 receivers,
    ## and nothing is checked as a receiver. Alone, as the File tab checks it, it is
    ## a slice of receiver 7.
    var xs: seq[string] = @[]
    for s in 1 .. 5: xs.add xRec(s, "1.00", $s & ".00", 1, 100, 10, 1, 100)
    let sv = surveyOf(xs)
    for components in [1, 3]:
      let folder = dir / ("shots-" & $components & "c")
      createDir(folder)
      var paths: seq[string] = @[]
      for s in 1 .. 5:
        let p = folder / ("s" & $s & ".sgd")
        var trs: seq[Tr] = @[]
        if s == 1:
          for c in 1 .. components: trs.add (1, 1.0, 7.0, c, 1)
        else:
          for r in 1 .. 100: trs.add (s, float64(s), float64(r), 1, 1)
        traceFile(p, trs)
        paths.add p
      let r = run(folder, paths, sv)
      doAssert r.unmatched.len == 0 and not r.singleSlice, $r.unmatched
      let t = r.shot.stats
      doAssert t.files == 5 and t.records == 5 and t.inTemplate == 100 and t.found == 100 and
        t.missing == 99, $components & " " & $t
      doAssert t.expectedInRecords == 500 and t.presentInRecords == 401 and
        t.missingInRecords == 99, $t
      doAssert r.shot.rows.len == 99 and r.shot.rows[0].point == 1 and r.shot.rows[0].missing == 1
      expect(r.receiver.figures, "0 0 0 0 0 | 0 0 0")
      let one = run(folder, @[paths[0]], sv)
      expect(one.shot.figures, "0 0 0 0 0 | 0 0 0")
      expect(one.receiver.figures, "1 1 5 1 4 | 5 1 4 1/2x1 1/3x1 1/4x1 1/5x1")
      doAssert one.singleSlice

  block a_shot_and_a_receiver_in_one_folder:
    ## A shot of source 1 (receivers 1..3 of 1..4) and receiver 2 cut in slices of
    ## sources 2 and 3: each is checked on its own side.
    var xs: seq[string] = @[]
    for s in 1 .. 3: xs.add xRec(s, "1.00", $s & ".00", 1, 4, 10, 1, 4)
    let sv = surveyOf(xs)
    createDir(dir / "mix")
    let sh = dir / "mix" / "shot1.sgd"
    traceFile(sh, [(1, 1.0, 1.0, 1, 1), (1, 1.0, 2.0, 1, 1), (1, 1.0, 3.0, 1, 1)])
    let sl = dir / "mix" / "slice.sgd"
    slicedFile(sl, 2.0, [2.0, 3.0], true)
    let r = run(dir / "mix", @[sh, sl], sv)
    doAssert r.unmatched.len == 0, $r.unmatched
    expect(r.shot.figures, "1 1 4 3 1 | 4 3 1 10/4x1")
    expect(r.receiver.figures, "1 1 3 2 1 | 3 2 1 1/1x1")

  block sliced_receiver_with_a_record_number_for_each_slice_or_one:
    let xs = [xRec(1, "1.00", "1.00", 1, 3, 10, 1, 3), xRec(2, "1.00", "2.00", 1, 3, 10, 1, 3),
      xRec(3, "1.00", "3.00", 1, 3, 10, 1, 3), xRec(4, "1.00", "4.00", 1, 3, 10, 1, 3)]
    for perSlice in [false, true]:
      let p = dir / ("l" & $perSlice & ".sgd")
      slicedFile(p, 2.0, [1.0, 2.0, 4.0], perSlice)
      let r = run(dir, @[p], surveyOf(xs))
      expect(r.receiver.figures, "1 1 4 3 1 | 4 3 1 1/3x1")
      expect(r.shot.figures, "0 0 0 0 0 | 0 0 0")

  block two_three_component_receivers_sliced:
    ## Receivers 1 and 3, three components each, sources 1 and 2 of 1..3, a record
    ## for each slice.
    let xs = [xRec(1, "1.00", "1.00", 1, 3, 10, 1, 3), xRec(2, "1.00", "2.00", 1, 3, 10, 1, 3),
      xRec(3, "1.00", "3.00", 1, 3, 10, 1, 3)]
    let p = dir / "l2.sgd"
    var w = openSeismicWriter(p, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 10,
      time: 1_700_000_000.0, receiverGather: true))
    var n = 0
    for rcv in [1.0, 3.0]:
      for src in [1.0, 2.0]:
        for comp in 1 .. 3:
          var k = initTraceKeys()
          k.record = float64(100 + n)
          k.channel = float64(comp)
          k.component = uint8(comp)
          k.srcLine = 1
          k.srcPoint = src
          k.srcIndex = 1
          k.rcvLine = 10
          k.rcvPoint = rcv
          k.rcvIndex = 1
          k.intervalUs = 2000
          k.status = tsLive
          k.time = 1_700_000_000.0 + 60.0 * src
          w.writeTrace(k, newSeq[float32](10))
        inc n
    doAssert w.close().len == 0
    let r = run(dir, @[p], surveyOf(xs))
    expect(r.receiver.figures, "1 2 3 2 1 | 6 4 2 1/3x2")
    expect(r.shot.figures, "0 0 0 0 0 | 0 0 0")

  block two_x_records_at_one_source:
    ## X1 and X2 are both source 1, receivers 1..4 and 5..8; the shot holds 1..4 and
    ## has record number 2.
    let sv = surveyOf(xRec(1, "1.00", "1.00", 1, 4, 10, 1, 4),
      xRec(2, "1.00", "1.00", 1, 4, 10, 5, 8))
    let p = dir / "m.sgd"
    traceFile(p, [(2, 1.0, 1.0, 1, 1), (2, 1.0, 2.0, 1, 1), (2, 1.0, 3.0, 1, 1),
      (2, 1.0, 4.0, 1, 1)])
    let r = run(dir, @[p], sv)
    doAssert r.unmatched.len == 0, $r.unmatched
    expect(r.shot.figures, "1 1 4 4 0 | 4 4 0")

  block two_o_records_at_one_receiver:
    ## Receiver 2 has O records for sources 1..3 and 4..6; its data holds 1..3.
    let xs = [xRec(1, "1.00", "1.00", 1, 3, 10, 1, 3), xRec(2, "1.00", "2.00", 1, 3, 10, 1, 3),
      xRec(3, "1.00", "3.00", 1, 3, 10, 1, 3)]
    let sv = surveyOf(@xs & @[oRec(50, "10.00", "2.00", "1", 1, 3),
      oRec(51, "10.00", "2.00", "1", 4, 6)])
    for ffid in [5, 9]:
      let p = dir / ("n" & $ffid & ".sgd")
      receiverFile(p, ffid, 2.0, [1.0, 2.0, 3.0])
      let r = run(dir, @[p], sv)
      doAssert r.unmatched.len == 0, $ffid & " " & $r.unmatched
      expect(r.receiver.figures, "1 1 6 3 3 | 6 3 3 1/4x1 1/5x1 1/6x1")

  removeDir(dir)
  echo "tmissingcases: ok"

when isMainModule:
  main()
