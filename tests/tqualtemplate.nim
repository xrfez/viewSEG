## The Trace quality report judges and counts only the traces the record's template lists
## (a shot's X record, a receiver gather's O records) when a relation file is loaded and the
## noise setting `templateOnly` is on, and says how many traces it left out. The file tab
## (one file), the folder tab (any number of threads) and the CSV give the same figures. With
## `templateOnly` off, or no relation file, every trace is judged as before.
##
## Fixtures: a shot of 8 receiver stations whose X record lists the first 5 (station 5 is
## clipped; 6 is dead in its header, 7 and 8 are clipped), and a receiver recording 5 sources
## whose O record lists the first 3 (source 3 is clipped, 4 is dead, 5 clipped).
##
## A record whose headers name no source station takes it from the survey on the map, joined
## in memory as the recorded fold joins it. A record whose template is still not known is
## measured whole and counted by why, in the totals, the words and the CSV. Given X records
## and no O records, the job derives the receivers' O records from the X records itself.
##
## The job reads the relation records by address: the app keeps them for it until its work is
## back (`holdGeometry`), so the state letting go of its own `ref` meanwhile changes nothing.
##
## Seen to fail: with the leaving out switched off in the scan (`measure` never asking
## `leftOutOfTemplate`), `a_shot_s_unlisted_*` saw 8 traces where 5 were expected. With the
## `holdGeometry` call left out of `the_relations_are_held_*`, the records were freed under the
## job and another geometry took their place: it left out 0 traces where 3 were expected. With
## the join left out of `qualityItem`, `a_record_whose_headers_name_no_source_*` measured 8
## traces where 5 were expected; with `measuredWhole` never called, it counted no record whole.
## With the answer named by the relation records' addresses and Only inside the template alone
## (as the window named it), `an_answer_is_named_by_*` saw no change for another exclusion edge.
## With `absorb` keeping only the last file's count of the traces left out (or of the records
## measured whole), `a_folder_of_six_*` saw 3 where 18 were expected (1 where 6 were).
## With no O records derived in the job, `a_receiver_gather_with_only_x_records_*` measured the
## five records whole.

import std/[atomics, math, os, strutils, tables]
import parseSEG
import viewSEG/core/[edits, filesystem, foldjobs, jobs, state, noisearea, qualityjobs,
  qualityreport, recordingkind, reportside, survey]
import viewSEG/view/qualitywords
import utils/[fixtures, qualityfolders, waiting]

const H00 = "H00 SPS format version number   SPS 2.1;"

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

proc surveyOf(line: string): ref SurveyGeometry =
  var g = SurveyGeometry()
  g.addSps(parseSps(H00 & "\n" & line))
  result = new SurveyGeometry
  result[] = g

proc quiet(): seq[float32] =
  result = newSeq[float32](40)
  for i in 0 ..< 40: result[i] = float32(sin(float64(i) * 0.7) * (1.0 + float64(i) * 0.013))

proc clipped(): seq[float32] =
  result = quiet()
  for i in 4 .. 6: result[i] = 1000
  for i in 8 .. 10: result[i] = -1000
  for i in 20 .. 22: result[i] = 1000
  for i in 24 .. 26: result[i] = -1000

proc writeFile(path: string; rows: openArray[tuple[rcvLine, rcvPoint, srcLine, srcPoint: float64;
    dead, loud: bool]]; perTrace: bool) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 40, time: 1_700_000_000.0))
  for i, r in rows:
    var k = initTraceKeys()
    k.record = float64(if perTrace: i + 1 else: 7)
    k.channel = float64(i + 1)
    k.srcLine = r.srcLine
    k.srcPoint = r.srcPoint
    k.srcIndex = 1
    k.rcvLine = r.rcvLine
    k.rcvPoint = r.rcvPoint
    k.rcvIndex = 1
    k.intervalUs = 2000
    k.component = 1
    k.sensorType = 1
    k.status = if r.dead: tsDead else: tsLive
    w.writeTrace(k, if r.dead: newSeq[float32](40) elif r.loud: clipped() else: quiet())
  doAssert w.close().len == 0, "file was not written: " & path

proc shotFile(path: string) =
  ## Shot 99 of line 1 at receivers 1 .. 8 of line 10; station 5 clipped, 6 dead, 7 and 8 clipped.
  var rows: seq[tuple[rcvLine, rcvPoint, srcLine, srcPoint: float64; dead, loud: bool]]
  for p in 1 .. 8:
    rows.add (rcvLine: 10.0, rcvPoint: float64(p), srcLine: 1.0, srcPoint: 99.0,
      dead: p == 6, loud: p in {5, 7, 8})
  writeFile(path, rows, false)

proc receiverFile(path: string) =
  ## Receiver 90 of line 20 recording sources 1 .. 5 of line 5; 3 clipped, 4 dead, 5 clipped.
  var rows: seq[tuple[rcvLine, rcvPoint, srcLine, srcPoint: float64; dead, loud: bool]]
  for s in 1 .. 5:
    rows.add (rcvLine: 20.0, rcvPoint: 90.0, srcLine: 5.0, srcPoint: float64(s),
      dead: s == 4, loud: s in {3, 5})
  writeFile(path, rows, true)

proc run(work: JobWork; paths: seq[string]; sink: QualitySink; threads = 0) =
  let jobs = initJobs()
  if threads > 0: jobs.setItemThreads(threads)
  let id = jobs.submit(qualitySpec(paths), work)
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the scan did not finish"
  doAssert sink.result.ok, sink.result.reason

proc shotRows(srcLine, srcPoint: float64; rcv: bool): seq[tuple[rcvLine, rcvPoint, srcLine,
    srcPoint: float64; dead, loud: bool]] =
  ## The shot of `shotFile` (record 7), its source station `srcLine`/`srcPoint` (0, 0: none),
  ## its receivers' stations in the headers only when `rcv`.
  for p in 1 .. 8:
    result.add (rcvLine: (if rcv: 10.0 else: 0.0), rcvPoint: (if rcv: float64(p) else: 0.0),
      srcLine: srcLine, srcPoint: srcPoint, dead: p == 6, loud: p in {5, 7, 8})

proc csvCell(csv, column: string): string =
  ## The cell of `column` in the one line of a totals CSV.
  let lines = csv.splitLines
  let at = lines[0].split(',').find(column)
  doAssert at >= 0, "no column " & column & " in " & lines[0]
  lines[1].split(',')[at]

proc mapSurvey(): array[PointRole, FoldStations] =
  ## The survey files' stations as the map holds them: source 1/99, receivers 10/1 .. 10/8.
  result[prSource] = FoldStations(stations: @[Station(line: 1, point: 99, index: 1)],
    xs: @[500.0], ys: @[0.0])
  for p in 1 .. 8:
    result[prReceiver].stations.add Station(line: 10, point: float64(p), index: 1)
    result[prReceiver].xs.add float64(p) * 25
    result[prReceiver].ys.add 100.0

func addrOf(g: ref SurveyGeometry): ptr SurveyGeometry =
  if g.isNil: nil else: addr g[]

proc scanOne(path: string; kind: RecordingKind; relations, receivers: ref SurveyGeometry;
    templateOnly = true; threads = 0; join = QualityJoin()): QualityJobResult =
  let sink = QualitySink()
  run(scanQuality(@[path], initTable[string, FileEdits](), sink, "",
    NoiseSettings(templateOnly: templateOnly), forcedKinds([path], kind),
    relations = relations.addrOf, receivers = receivers.addrOf, join = join), @[path], sink,
    threads)
  sink.result

var gate: Gate
var reached: Atomic[bool]
var mainThread: int

proc holdOpen(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  {.cast(gcsafe).}:
    if op in {foOpen, foMapped} and path.endsWith("held.sgd") and getThreadId() != mainThread:
      reached.store(true)
      var waited = 0
      while not gate.isOpen and waited < 60_000:
        sleep 1
        inc waited

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc main*() =
  block a_shot_s_unlisted_traces_are_left_out_and_counted_apart:
    withFixtures fx:
      let path = fx.dir / "shot.sgd"
      shotFile(path)
      let x = surveyOf(xRec(1, "1.00", "99.00", 1, 5, 10, 1, 5))
      let r = scanOne(path, rkShotGather, x, nil).receivers
      doAssert r.totals.traces == 5, "traces " & $r.totals.traces
      doAssert r.totals.stations == 5 and r.stations.len == 5, "stations " & $r.stations.len
      doAssert r.totals.bad == 1 and r.totals.counts[qfHeaderDead] == 0,
        "bad " & $r.totals.bad & ", " & $r.totals
      doAssert r.totals.outside == 3, "outside " & $r.totals.outside
      for row in r.stations: doAssert row.point <= 5.0, "station " & $row.point
      doAssert csvCell(totalsCsv(r.totals), "outside the template") == "3", totalsCsv(r.totals)
      doAssert r.totals.unknown == default(array[TemplateUnknown, int]), $r.totals
      # the file tab and the folder tab are the same
      let sink = QualitySink()
      run(folderScan(fx.dir, false, "", EditsSnapshot(), sink, QualityNote(),
        NoiseSettings(), forcedKinds([path], rkShotGather), relations = x.addrOf), @[path],
        sink, 4)
      doAssert sink.result.receivers.totals == r.totals
      doAssert stationsCsv(sink.result.receivers.stations) == stationsCsv(r.stations)

  block a_folder_of_six_shots_is_the_same_on_one_thread_and_on_four:
    withFixtures fx:
      let x = surveyOf(xRec(7, "1.00", "99.00", 1, 5, 10, 1, 5))
      for (folder, source, outside, whole) in [("listed", 99.0, 18, 0), ("unnamed", 0.0, 0, 6)]:
        let dir = fx.dir / folder
        createDir(dir)
        var paths: seq[string] = @[]
        for i in 1 .. 6:
          paths.add dir / ("shot" & $i & ".sgd")
          writeFile(paths[^1], shotRows((if source == 0: 0.0 else: 1.0), source, true), false)
        var digests: seq[string] = @[]
        for threads in [1, 4]:
          let sink = QualitySink()
          run(folderScan(dir, false, "", EditsSnapshot(), sink, QualityNote(), NoiseSettings(),
            forcedKinds(paths, rkShotGather), relations = x.addrOf), paths, sink, threads)
          let t = sink.result.receivers.totals
          doAssert t.files == 6 and t.outside == outside and t.unknown[tuNoStation] == whole and
            t.traces == 6 * (8 - outside div 6), folder & " on " & $threads & ": " & $t
          digests.add digest(sink.result)
        doAssert digests[0] == digests[1], folder

  block templateOnly_off_or_no_relation_file_judges_every_trace:
    withFixtures fx:
      let path = fx.dir / "shot.sgd"
      shotFile(path)
      let x = surveyOf(xRec(1, "1.00", "99.00", 1, 5, 10, 1, 5))
      for r in [scanOne(path, rkShotGather, x, nil, templateOnly = false).receivers,
                scanOne(path, rkShotGather, nil, nil).receivers]:
        doAssert r.totals.traces == 8 and r.totals.outside == 0 and r.totals.bad == 4 and
          r.totals.counts[qfHeaderDead] == 1, $r.totals

  block a_receiver_gather_s_unlisted_sources_are_left_out:
    withFixtures fx:
      let path = fx.dir / "receiver.sgd"
      receiverFile(path)
      # an O record: the receiver is in the source columns, the sources in the receiver's
      var o = xRec(1, "20.00", "90.00", 1, 3, 5, 1, 3)
      o[0] = 'O'
      let rec = surveyOf(o)
      let r = scanOne(path, rkReceiverSliced, nil, rec).sources
      doAssert r.totals.traces == 3, "traces " & $r.totals.traces
      doAssert r.totals.bad == 1 and r.totals.counts[qfHeaderDead] == 0, $r.totals
      doAssert r.totals.outside == 2, "outside " & $r.totals.outside
      let all = scanOne(path, rkReceiverSliced, nil, rec, templateOnly = false).sources
      doAssert all.totals.traces == 5 and all.totals.outside == 0, $all.totals

  block a_receiver_gather_with_only_x_records_derives_its_o_records:
    withFixtures fx:
      let path = fx.dir / "receiver.sgd"
      receiverFile(path)
      # sources 1 .. 3 of line 5 each recorded receiver 90 of line 20: its O records, derived
      var lines: seq[string] = @[]
      for s in 1 .. 3: lines.add xRec(s, "5.00", $s & ".00", 1, 1, 20, 90, 90)
      let x = surveyOf(lines.join("\n"))
      let r = scanOne(path, rkReceiverSliced, x, nil).sources
      doAssert r.totals.traces == 3 and r.totals.outside == 2, $r.totals
      doAssert r.totals.unknown == default(array[TemplateUnknown, int]), $r.totals

  block a_record_whose_headers_name_no_source_takes_it_from_the_survey_joined:
    withFixtures fx:
      let path = fx.dir / "shot.sgd"
      writeFile(path, shotRows(0, 0, true), false)
      let x = surveyOf(xRec(7, "1.00", "99.00", 1, 5, 10, 1, 5))
      let joined = scanOne(path, rkShotGather, x, nil,
        join = QualityJoin(relations: addr x[], stations: mapSurvey())).receivers
      doAssert joined.totals.traces == 5 and joined.totals.outside == 3, $joined.totals
      doAssert joined.totals.unknown == default(array[TemplateUnknown, int]), $joined.totals
      doAssert wholeLine(joined.totals, ssReceivers) == ""
      # not joined: measured whole, and said so
      let whole = scanOne(path, rkShotGather, x, nil).receivers
      doAssert whole.totals.traces == 8 and whole.totals.outside == 0, $whole.totals
      doAssert whole.totals.unknown[tuNoStation] == 1, $whole.totals
      doAssert "1 record was measured whole: its template is not known (1 with no source " &
        "station)" in statisticLines(whole.totals, ssReceivers, false), $statisticLines(
        whole.totals, ssReceivers, false)
      doAssert csvCell(totalsCsv(whole.totals), "records measured whole: " & $tuNoStation) ==
        "1", totalsCsv(whole.totals)

  block a_record_whose_template_is_not_known_is_counted_by_why:
    withFixtures fx:
      let path = fx.dir / "shot.sgd"
      let x = surveyOf(xRec(7, "1.00", "99.00", 1, 5, 10, 1, 5))
      writeFile(path, shotRows(0, 0, false), false) # no station at all
      var t = scanOne(path, rkShotGather, x, nil).receivers.totals
      doAssert t.traces == 8 and t.unknown[tuNoStation] == 1, $t
      writeFile(path, shotRows(1, 77, true), false) # a source with no X record
      t = scanOne(path, rkShotGather, x, nil).receivers.totals
      doAssert t.traces == 8 and t.unknown[tuNoRecord] == 1 and t.unknown[tuNoStation] == 0, $t
      doAssert wholeLine(t, ssReceivers) == "1 record was measured whole: its template is not " &
        "known (1 whose X record is not found)", wholeLine(t, ssReceivers)
      # only O records loaded: the shot's side has no template, and that is said too
      var o = xRec(1, "20.00", "90.00", 1, 3, 5, 1, 3)
      o[0] = 'O'
      t = scanOne(path, rkShotGather, nil, surveyOf(o)).receivers.totals
      doAssert t.traces == 8 and t.unknown[tuNoRecord] == 1, $t
      # no relation file at all: every record whole, none counted
      t = scanOne(path, rkShotGather, nil, nil).receivers.totals
      doAssert t.traces == 8 and t.unknown == default(array[TemplateUnknown, int]), $t
      # a receiver whose O records are not found: each of its five records (a trace each)
      let rpath = fx.dir / "receiver.sgd"
      receiverFile(rpath)
      var other = xRec(1, "20.00", "91.00", 1, 3, 5, 1, 3)
      other[0] = 'O'
      let r = scanOne(rpath, rkReceiverSliced, nil, surveyOf(other)).sources.totals
      doAssert r.traces == 5 and r.unknown[tuNoRecord] == 5, $r
      doAssert wholeLine(r, ssSources) == "5 records were measured whole: their template is " &
        "not known (5 whose O records are not found)", wholeLine(r, ssSources)

  block an_answer_is_named_by_its_inputs_never_by_an_address:
    withFixtures fx:
      let plan = fx.dir / "plan.x"
      writeFile(plan, H00 & "\n" & xRec(7, "1.00", "99.00", 1, 5, 10, 1, 5) & "\n")
      var st = initAppState()
      st.rememberFilesIn(fx.dir / "config")
      let none = st.qualityInputsKey
      st.apply Command(kind: ckLoadSurvey, paths: @[plan])
      doAssert st.settle(st.jobs.active.len == 0 and st.survey.layers.len == 1)
      let first = st.qualityInputsKey
      doAssert first != none
      st.apply Command(kind: ckClearSurvey)
      doAssert st.settle(st.jobs.active.len == 0 and st.survey.layers.len == 0)
      doAssert st.qualityInputsKey == none
      # the same file loaded again is another layer: its answers are not the old ones
      st.apply Command(kind: ckLoadSurvey, paths: @[plan])
      doAssert st.settle(st.jobs.active.len == 0 and st.survey.layers.len == 1)
      let again = st.qualityInputsKey
      doAssert again != first
      # every noise setting the figures depend on, not only Only inside the template
      var settings = st.settings
      settings.noise.edgeMs = 250
      st.apply Command(kind: ckSettings, settings: settings)
      doAssert st.qualityInputsKey != again
      st.shutdown()

  block the_relations_are_held_for_the_job_until_its_work_is_back:
    mainThread = getThreadId()
    withFixtures fx:
      let path = fx.dir / "held.sgd"
      shotFile(path)
      var st = initAppState()
      st.rememberFilesIn(fx.dir / "config")
      var x = surveyOf(xRec(1, "1.00", "99.00", 1, 5, 10, 1, 5))
      gate.close()
      reached.store(false)
      setFsHook(holdOpen)
      let sink = QualitySink()
      let id = st.jobs.submit(qualitySpec(@[path]), scanQuality(@[path],
        initTable[string, FileEdits](), sink, "", NoiseSettings(),
        forcedKinds([path], rkShotGather), relations = addr x[]))
      st.holdGeometry(id, x)
      doAssert waitUntil(reached.load), "the job did not reach its file"
      x = nil # the state's own `ref` goes (a layer unloaded): only the hold keeps them
      # a geometry made now takes the memory of one freed: one that lists every station
      let other = surveyOf(xRec(1, "1.00", "99.00", 1, 8, 10, 1, 8))
      gate.open
      doAssert st.settle(st.jobs.info(id).get.state in {jsDone, jsFailed}),
        "the scan did not finish"
      setFsHook(nil)
      doAssert sink.result.ok, sink.result.reason
      doAssert sink.result.receivers.totals.outside == 3,
        "outside " & $sink.result.receivers.totals.outside
      doAssert other[].relationCount(rdSource) == 1
      st.shutdown()

when isMainModule:
  main()
