## The folder scan and the map judge the same traces: for one file the noisy and the weak traces
## the scan counts are those the map's record check (`recordQcWork`) marks, and a station is
## tested for noisy in a record only where the map judged it, for weak inside the exclusion area
## too.
##
## - a killed trace is not judged and not in the statistics the live traces are judged against,
##   in the map as in the scan (64 traces, every other trace of 20 .. 59 killed and loud, one
##   weak trace inside the area);
## - a station inside the exclusion area of every record has an empty noisy cell (not tested),
##   not 0, and its weak cell counts a weak trace there;
## - a weak trace near the source of a long record (records of 300 and 700 traces) is counted;
##   a station weak near a fixed source is weak in each record;
## - a file that fails to read part-way adds nothing to the totals and is listed unread once;
## - one big file moves the job's progress while it is measured; threads given to the first-break
##   picker do not change its answer.
##
## Seen to fail: with the map reading the killed traces into its statistics, `killed_traces_*`
## saw the map's noisy set empty and its weak set hold traces the scan did not name; with the
## scan's `tested` set for every sample-read trace, `a_station_in_the_area_*` saw 2 tested where
## the map judged the station in neither record; with the failed file's rows kept, `a_file_that_
## fails_*` saw 128 traces counted for the unread file; with the progress reported once a file,
## `one_big_file_*` saw the bar never between its ends while measuring; with weak counted only
## where the noisy test judged a trace, `killed_traces_*` saw the scan without weak trace 3,
## `a_station_in_the_area_*` station 4 with no weak trace, `a_weak_trace_near_*` trace 400 not
## weak and `a_station_weak_near_*` station 3 weak in no record.

import std/[algorithm, atomics, math, monotimes, os, sets, tables, times]
import parseSEG
import processSEG
import processSEG/synth
import processSEG/core/pool
import viewSEG/core/[breakmodel, edits, filejobs, filesystem, firstbreakjobs, firstbreaks, inbox, jobs,
  mapkinds, noisearea, qualityjobs, qualityreport, recordqc, session]
import utils/[fixtures, waiting]

const
  Smp = 1000
  Step = 2.0

type Spec = object
  recs: seq[int]        ## traces per record, in file order
  weak, noisy: seq[int] ## file trace numbers
  extraGain: seq[(int, float64)]
  sameStations: bool    ## the stations of every record are 1 .. n

proc build(path: string; sp: Spec) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: Step * 1000,
    numSamples: Smp, time: 1_700_000_000.0))
  var buf = newSeq[float32](Smp)
  var t = 0
  for ri, n in sp.recs:
    let dx = min(25.0, 1600.0 / float64(max(n, 1)))
    for i in 0 ..< n:
      for j in 0 ..< Smp: buf[j] = 0
      var gain = 1.0
      let nearN = max(1, n * 12 div 64)
      if i < nearN: gain = 12.0 - float64(i) * (11.0 / float64(nearN))
      if n >= 8 and i == n * 50 div 64: gain = 30.0
      if n >= 8 and i == n * 40 div 64: gain = 2.8
      if t in sp.weak: gain *= 0.02
      if t in sp.noisy: gain *= 25.0
      for (at, g) in sp.extraGain:
        if at == t: gain *= g
      let x = 100.0 + dx * float64(i)
      buf.addRicker(Step, 20.0 + 0.4 * x + 15, 30, gain)
      buf.addNoise(0.03 * gain, int64(t + 1))
      var k = initTraceKeys()
      (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (float64(ri + 1),
        float64(i + 1), 0.0, Step * 1000, tsLive)
      k.offset = x
      k.rcvLine = 1
      k.rcvPoint = float64(if sp.sameStations: i + 1 else: t + 1)
      k.rcvIndex = 1
      (k.rcvX, k.rcvY) = (1000.0 + x, 1000.0)
      (k.srcX, k.srcY) = (1000.0, 1000.0)
      (k.srcLine, k.srcPoint, k.srcIndex) = (1.0, float64(ri + 1), 1'i16)
      w.writeTrace(k, buf)
      inc t
  doAssert w.close().len == 0

proc awaitQc(box: Inbox; session: SessionId): Msg =
  var got = false
  doAssert waitUntil(block:
    var msgs: seq[Msg]
    box.drainInto(msgs)
    for m in msgs:
      if m.kind == mkRecordQc and m.qcSession == session:
        result = m
        got = true
    got
  ), "no record check"

type MapSets = object
  noisy, weak, notJudged: HashSet[int] ## file trace numbers

var nextId = 1000

proc mapSets(path: string; killed: seq[int]): MapSets =
  ## What the map's record check marks, every gather of `path`, the user's `killed` traces
  ## given to it as the viewer gives them.
  let jobs = initJobs()
  let box = initInbox()
  let s = openSession(path)
  for gi, g in s.gathers:
    var kin: seq[int] = @[]
    for t in killed:
      if t in g.traces: kin.add t
    inc nextId
    let sid = SessionId(nextId)
    let work = NoiseWork(on: true, settings: NoiseSettings(),
      key: (sid, gi, s.keysRevision, kin, newSeq[uint8](), BreakModel(), pbSmoothed))
    var placed: Placed
    let id = jobs.submit(JobSpec(title: "map", lane: jlBackground, auto: true,
      reads: @[path]), recordQcWork(s.filePtr, path, sid, 0, gi, g.traces, rdSource, nil, "",
        rmAuto, tmAuto, placed, true, newSeq[FilterEntry](), newSeq[int](),
        newSeq[ShiftEntry](), work, box.poster, nil))
    let m = awaitQc(box, sid)
    doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
    for t in m.qcHits[mfNoisy].traces: result.noisy.incl t
    for t in m.qcHits[mfWeak].traces: result.weak.incl t
    for t in m.qcHits[mfNotJudged].traces: result.notJudged.incl t

proc scanAll(paths: seq[string]; edits: Table[string, FileEdits]): QualityJobResult =
  let jobs = initJobs()
  let sink = QualitySink()
  let id = jobs.submit(qualitySpec(paths), scanQuality(paths, edits, sink, ""))
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the scan did not finish"
  doAssert sink.result.ok, sink.result.reason
  sink.result

proc scan(path: string; edits: Table[string, FileEdits]): QualityReport =
  scanAll(@[path], edits).report

var mappedCalls, failAt: Atomic[int]
var failing: string

proc countingHook(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  ## Counts the mapped reads of `failing`; the `failAt`th is an I/O error.
  {.cast(gcsafe).}:
    if op == foMapped and path == failing and mappedCalls.fetchAdd(1) + 1 == failAt.load:
      raise newException(OSError, "Input/output error (planted)")

func sorted(s: HashSet[int]): seq[int] =
  for x in s: result.add x
  result.sort()

proc main*() =
  block killed_traces_are_in_neither_the_map_s_statistics_nor_the_scan_s:
    withFixtures fx:
      var kill: seq[int] = @[]
      for t in 20 ..< 60:
        if t mod 2 == 0: kill.add t
      # the live traces 21 and 23 weak, 25 and 27 noisy, among loud killed ones; trace 3 weak
      # inside the exclusion area
      let path = fx.dir / "killedLoud.sgd"
      build(path, Spec(recs: @[64], noisy: kill, weak: @[3],
        extraGain: @[(21, 0.25), (23, 0.3), (25, 4.0), (27, 5.0)]))
      var e = FileEdits()
      discard e.change(teKilled, kill, true)
      let m = mapSets(path, kill)
      let r = scan(path, {path: e}.toTable)
      var scanNoisy, scanWeak: seq[int]
      for row in r.stations:
        let t = int(row.point) - 1
        if row.noisy > 0: scanNoisy.add t
        if row.weak > 0: scanWeak.add t
      scanNoisy.sort()
      scanWeak.sort()
      doAssert m.noisy.sorted == scanNoisy, $m.noisy.sorted & " / " & $scanNoisy
      doAssert m.weak.sorted == scanWeak, $m.weak.sorted & " / " & $scanWeak
      doAssert scanNoisy == @[25, 27] and scanWeak == @[3, 21, 23], $scanNoisy & $scanWeak
      doAssert 3 in m.notJudged, "trace 3 is not inside the area"
      for t in kill:
        doAssert t notin m.noisy and t notin m.weak, "a killed trace was judged: " & $t

  block a_station_in_the_area_of_every_record_has_empty_cells:
    withFixtures fx:
      let path = fx.dir / "areas.sgd"
      # station 4 weak in the first record, inside the area
      build(path, Spec(recs: @[64, 64], sameStations: true, weak: @[3]))
      let m = mapSets(path, @[])
      let r = scan(path, initTable[string, FileEdits]())
      doAssert m.notJudged.len > 0, "the map judged every trace: no area to test"
      doAssert 3 in m.notJudged and 3 in m.weak, "trace 3 is not weak inside the area"
      var empty = 0
      for row in r.stations:
        let p = int(row.point) - 1
        var judged = 0
        for rec in 0 ..< 2:
          if p + 64 * rec notin m.notJudged: inc judged
        doAssert row.noisyTested == judged, "station " & $(p + 1) & ": " & $row.noisyTested &
          " tested, the map judged it in " & $judged
        # inside the area a trace is still tested for weak
        doAssert row.weakTested == 2, "station " & $(p + 1) & ": " & $row.weakTested &
          " tested for weak"
        if row.noisyTested == 0: inc empty
        var weak = 0
        for rec in 0 ..< 2:
          if p + 64 * rec in m.weak: inc weak
        doAssert row.weak == weak, "station " & $(p + 1) & ": " & $row.weak &
          " weak, the map marks it in " & $weak
      doAssert empty > 0, "no station had an empty cell"

  block a_weak_trace_near_the_source_of_a_long_record_is_counted:
    withFixtures fx:
      # one file, records of 300 and 700 traces, trace 400 weak near the second's source
      let path = fx.dir / "long.sgd"
      build(path, Spec(recs: @[300, 700], weak: @[400]))
      let m = mapSets(path, @[])
      let r = scan(path, initTable[string, FileEdits]())
      var scanWeak: seq[int] = @[]
      for row in r.stations:
        if row.weak > 0: scanWeak.add int(row.point) - 1
      scanWeak.sort()
      doAssert 400 in m.weak, "the map does not mark trace 400 weak: " & $m.weak.sorted
      doAssert m.weak.sorted == scanWeak, $m.weak.sorted & " / " & $scanWeak

  block a_station_weak_near_a_fixed_source_is_weak_in_every_record:
    withFixtures fx:
      # two records of the same stations and source, stations 3 and 6 weak in both
      let path = fx.dir / "fixed.sgd"
      build(path, Spec(recs: @[64, 64], sameStations: true, weak: @[2, 5, 66, 69]))
      let m = mapSets(path, @[])
      let r = scan(path, initTable[string, FileEdits]())
      for t in [2, 5, 66, 69]:
        doAssert t in m.weak, "the map does not mark trace " & $t & " weak"
      for row in r.stations:
        let p = int(row.point)
        if p in [3, 6]:
          doAssert row.weak == 2, "station " & $p & ": weak in " & $row.weak & " records"

  block a_file_that_fails_part_way_counts_nothing_and_is_unread_once:
    withFixtures fx:
      let whole = fx.dir / "whole.sgd"
      let broken = fx.dir / "broken.sgd"
      build(whole, Spec(recs: @[64]))
      build(broken, Spec(recs: @[64, 64]))
      failing = broken
      setFsHook(countingHook)
      defer: setFsHook(nil)
      # a run that fails nowhere counts the file's mapped reads; the last one is in the
      # second record, after the first was judged and counted
      mappedCalls.store(0)
      failAt.store(0)
      let clean = scanAll(@[whole, broken], initTable[string, FileEdits]())
      doAssert clean.unread.len == 0 and clean.report.totals.traces == 64 + 128, $clean.unread
      let last = mappedCalls.load
      mappedCalls.store(0)
      failAt.store(last)
      let got = scanAll(@[whole, broken], initTable[string, FileEdits]())
      var named = 0
      for u in got.unread:
        if u.path == broken: inc named
      doAssert named == 1 and got.unread.len == 1, $got.unread
      doAssert got.report.totals.traces == 64 and got.report.totals.files == 1,
        "the unread file is counted: " & $got.report.totals
      for r in got.report.records:
        doAssert r.file == whole, "a row of the unread file: " & r.file

  block one_big_file_moves_the_progress_before_it_ends:
    withFixtures fx:
      let path = fx.dir / "big.sgd"
      build(path, Spec(recs: @[1500]))
      let jobs = initJobs()
      let sink = QualitySink()
      let id = jobs.submit(qualitySpec(@[path]), scanQuality(@[path], initTable[string,
        FileEdits](), sink, ""))
      # the one file is the whole job: while its traces are measured the bar is neither at 0 nor
      # at its end
      var inside = 0
      let deadline = getMonoTime() + initDuration(seconds = 120)
      while jobs.info(id).get.state notin {jsDone, jsFailed, jsCancelled}:
        doAssert getMonoTime() < deadline, "the scan did not finish"
        let p = jobs.info(id).get.progress
        if p.phase == "measuring" and p.total > 0 and p.done > 0 and p.done < p.total:
          inc inside
        sleep 1
      doAssert jobs.info(id).get.state == jsDone
      doAssert inside > 0, "the bar did not move inside the file"

  block threads_given_to_the_picker_do_not_change_its_answer:
    withFixtures fx:
      let path = fx.dir / "pool.sgd"
      build(path, Spec(recs: @[64, 64]))
      let s = openSession(path)
      var shared = newProcessPool(2)
      for g in s.gathers:
        let own = breaksOfRecord(s.filePtr, path, g.traces, [])
        # one pool serves the records one after the other
        let given = breaksOfRecord(s.filePtr, path, g.traces, [], shared = addr shared)
        doAssert own.state == bkDone and given.state == bkDone
        for i in 0 ..< g.traces.len:
          doAssert own.pickMs[i].classify == given.pickMs[i].classify and
            (own.pickMs[i].isNaN or own.pickMs[i] == given.pickMs[i]), "pick " & $i

when isMainModule:
  main()
