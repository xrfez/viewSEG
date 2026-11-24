## The folder scan and the map judge the same traces: for one file the noisy and the weak traces
## the scan counts are those the map's record check (`recordQcWork`) marks, and a station is
## tested in a record only where the map judged it.
##
## - a killed trace is not judged and not in the statistics the live traces are judged against,
##   in the map as in the scan (64 traces, every other trace of 20 .. 59 killed and loud);
## - a station inside the exclusion area of every record has empty cells (not tested), not 0.
##
## Seen to fail: with the map reading the killed traces into its statistics, `killed_traces_*`
## saw the map's noisy set empty and its weak set hold traces the scan did not name; with the
## scan's `tested` set for every sample-read trace, `a_station_in_the_area_*` saw 2 tested where
## the map judged the station in neither record.

import std/[algorithm, os, sets, strutils, tables]
import parseSEG
import processSEG
import processSEG/synth
import viewSEG/core/[breakmodel, edits, filejobs, firstbreaks, inbox, jobs, mapkinds,
  noisearea, qualityjobs, qualityreport, recordqc, session]
import utils/[fixtures, waiting]

const
  Smp = 1000
  Step = 2.0

type Spec = object
  recs: seq[int] ## traces per record, in file order
  weak, noisy: seq[int] ## file trace numbers
  extraGain: seq[(int, float64)]
  sameStations: bool ## the stations of every record are 1 .. n

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

proc scan(path: string; edits: Table[string, FileEdits]): QualityReport =
  let jobs = initJobs()
  let sink = QualitySink()
  let id = jobs.submit(qualitySpec(@[path]), scanQuality(@[path], edits, sink, ""))
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the scan did not finish"
  doAssert sink.result.ok, sink.result.reason
  sink.result.report

func sorted(s: HashSet[int]): seq[int] =
  for x in s: result.add x
  result.sort()

proc main*() =
  block killed_traces_are_in_neither_the_map_s_statistics_nor_the_scan_s:
    withFixtures fx:
      var kill: seq[int] = @[]
      for t in 20 ..< 60:
        if t mod 2 == 0: kill.add t
      # the live traces 21 and 23 weak, 25 and 27 noisy, among loud killed ones
      let path = fx.dir / "killedLoud.sgd"
      build(path, Spec(recs: @[64], noisy: kill,
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
      doAssert scanNoisy == @[25, 27] and scanWeak == @[21, 23], $scanNoisy & $scanWeak
      for t in kill:
        doAssert t notin m.noisy and t notin m.weak, "a killed trace was judged: " & $t

  block a_station_in_the_area_of_every_record_has_empty_cells:
    withFixtures fx:
      let path = fx.dir / "areas.sgd"
      build(path, Spec(recs: @[64, 64], sameStations: true))
      let m = mapSets(path, @[])
      let r = scan(path, initTable[string, FileEdits]())
      doAssert m.notJudged.len > 0, "the map judged every trace: no area to test"
      var empty = 0
      for row in r.stations:
        let p = int(row.point) - 1
        var judged = 0
        for rec in 0 ..< 2:
          if p + 64 * rec notin m.notJudged: inc judged
        doAssert row.tested == judged, "station " & $(p + 1) & ": " & $row.tested &
          " tested, the map judged it in " & $judged
        if row.tested == 0: inc empty
      doAssert empty > 0, "no station had an empty cell"

when isMainModule:
  main()
