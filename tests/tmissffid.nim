## A record whose source station has no X record is not judged against the X
## record that merely carries its file number (FFID): that one belongs to
## another source. The three places that check a record agree: the filters'
## check (`recordQc`), the record list's check (`checkWork`, the Missing
## column) and the missing-trace report (`scanMissing`) all say "not checked".
## A matching source still checks, and counts what is missing.
##
## The shots have FFID 7. X record 7 is source 5 and plans receivers 1 to 5; X
## record 1 is source 6 and plans 1 to 3. Source 99 has no X record; source 5
## has one (7).
##
## Seen to fail: with the gate left out of `completeness` (core/recordqc),
## `noBasisFilters` rejected a missing count of 5 (state done); with the gate
## left out of `checkWork`, `noBasisRecordList` rejected planned 5; with the gate
## left out of `scanMissing`, `noBasisReport` rejected a report of one record.

import std/[os, strutils]
import parseSEG
import processSEG/qc/record
import viewSEG/core/[jobs, missingjobs, missingreport, session]
import viewSEG/core/state
import utils/waiting

proc shotFile(path: string; record: int; src: float64; receivers: Slice[int]) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0))
  let samples = @[0'f32]
  var ch = 1
  for point in receivers:
    var k = initTraceKeys()
    k.record = float64(record)
    k.channel = float64(ch)
    k.srcLine = 1
    k.srcPoint = src
    k.srcIndex = 1
    k.rcvLine = 10
    k.rcvPoint = float64(point)
    k.rcvIndex = 1
    k.intervalUs = 2000
    k.status = tsLive
    w.writeTrace(k, samples)
    inc ch
  doAssert w.close().len == 0, "shot file was not written: " & path

proc relation(record: int; src: float64; receivers: int): SpsRelation =
  SpsRelation(fieldRecord: record, recordIncrement: 1, instrumentCode: '1', srcLine: 1,
    srcPoint: src, srcIndex: 1, fromChannel: 1, toChannel: receivers, channelIncrement: 1,
    rcvLine: 10, fromReceiver: 1, toReceiver: float(receivers), rcvIndex: 1)

proc writeX(path: string) =
  var x = SpsFile(headers: @[SpsHeader(code: "00", description: "SPS format version num.",
    data: "SPS 2.1;")])
  x.relations.add relation(7, 5.0, 5)
  x.relations.add relation(1, 6.0, 3)
  doAssert writeSps(x, path).len == 0

proc surveyOf(path: string): ref SurveyGeometry =
  var g = SurveyGeometry()
  g.addSps(parseSps(readFile(path)))
  result = new SurveyGeometry
  result[] = g

proc open(st: var AppState; xp, shot: string) =
  st.apply Command(kind: ckLoadSurvey, paths: @[xp])
  doAssert st.settle(st.survey.layers.len == 1 and st.jobs.active.len == 0)
  var s = st.settings
  s.map.filters = {mfMissing, mfUnlisted, mfDuplicate}
  st.apply Command(kind: ckSettings, settings: s)
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: shot)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
    st.jobs.active.len == 0)

func settled(st: AppState): bool =
  st.recordQc.job == NoJob and st.recordQc.hits[mfMissing].state in {fsDone, fsNotChecked}

proc main*() =
  let dir = getTempDir() / ("viewseg-missffid-" & $getCurrentProcessId())
  createDir(dir)
  let xp = dir / "plan.x"
  writeX(xp)
  let other = dir / "other.sgd" # source 99, FFID 7: no X record of its own
  shotFile(other, 7, 99.0, 1 .. 3)
  let own = dir / "own.sgd" # source 5, FFID 7: X record 7, receivers 4 and 5 missing
  shotFile(own, 7, 5.0, 1 .. 3)

  block noBasisFilters:
    var st = initAppState()
    st.open(xp, other)
    doAssert st.settle(st.settled)
    let h = st.filterHits
    for m in [mfMissing, mfUnlisted, mfDuplicate]:
      doAssert h[m].state == fsNotChecked, $m & ": " & $h[m].state
      doAssert h[m].count == 0 and h[m].traces.len == 0, $m & ": " & $h[m].count
      doAssert "belongs to another source" in h[m].note and "X record 7" in h[m].note and
        "plan.x" in h[m].note, h[m].note
    doAssert h[mfMissing].stations.len == 0
    st.shutdown()

  block matchingSourceStillChecks:
    var st = initAppState()
    st.open(xp, own)
    doAssert st.settle(st.settled)
    let h = st.filterHits
    doAssert h[mfMissing].state == fsDone and h[mfMissing].count == 2, $h[mfMissing].count
    doAssert h[mfMissing].stations.len == 2
    st.shutdown()

  block noBasisRecordList:
    var st = initAppState()
    st.open(xp, other)
    doAssert st.settle(st.sessions[0].records.len == 1 and st.jobs.active.len == 0)
    doAssert st.settle(st.sessions[0].records[0].planned == -1 and st.jobs.active.len == 0),
      $st.sessions[0].records[0].planned
    doAssert st.sessions[0].records[0].plannedMissing == -1
    st.shutdown()
    var ok = initAppState()
    ok.open(xp, own)
    doAssert ok.settle(ok.sessions[0].records.len == 1 and
      ok.sessions[0].records[0].planned == 5 and ok.jobs.active.len == 0),
      $ok.sessions[0].records[0].planned
    doAssert ok.sessions[0].records[0].plannedMissing == 2
    ok.shutdown()

  block noBasisReport:
    let lane = initJobs()
    let sink = MissingSink()
    let survey = surveyOf(xp) # read in place by the job: kept until it ends
    let id = lane.submit(missingSpec(dir, @[other]),
      scanMissing(dir, @[other], addr survey[], sink))
    doAssert waitUntil(lane.info(id).get.state in {jsDone, jsFailed, jsCancelled})
    doAssert lane.info(id).get.state == jsDone, lane.info(id).get.error
    doAssert sink.result.shot.stats.records == 0, $sink.result.shot.stats
    doAssert sink.result.unmatched.len == 1, $sink.result.unmatched.len
    let u = sink.result.unmatched[0]
    doAssert u.path == "other.sgd" and u.record == 7, $u
    doAssert "belongs to another source" in u.why, u.why
    let ok = MissingSink()
    let id2 = lane.submit(missingSpec(dir, @[own]), scanMissing(dir, @[own], addr survey[], ok))
    doAssert waitUntil(lane.info(id2).get.state in {jsDone, jsFailed, jsCancelled})
    doAssert ok.result.shot.stats.records == 1 and ok.result.shot.stats.missing == 2

  removeDir(dir)
  echo "tmissffid: ok"

when isMainModule:
  main()
