## A shot is checked against the X records at its source station, a receiver
## gather against the O records at its receiver station, in the Records
## window (`checkWork`) and for the record shown (`recordQc`, the map's
## filters and template box); a record number (an FFID, or the number in an X
## or O record) never finds or chooses a relation record. A survey with X and O
## records loaded together, and with X records only (the O records are then
## made from them).
##
## The survey: receivers 1 to 5 of line 10; sources of line 1. X record 7 is
## source 5 (receivers 1..5), 1 is source 6 (1..3); sources 7 and 8 were shot
## twice: X records 8 (1..4) and 9 (1..2) at source 7, 10 (1..2) and 11 (3..4)
## at source 8. O record 2 is receiver 2's shots 5 and 6, O record 3 its shots
## 7 and 8: the receiver's template is their union, four shots.
##
## Seen to fail (with the old code: the FFID breaking the tie between X
## records, the FFID standing in for a missing source, the X records read for
## every gather, a gather's side taken from its kind alone):
## `receiverAgainstO` rejected a receiver gather checked against X record 7
## (planned 5, not 4); `reshoot` rejected X record 9 picked by the FFID
## (planned 2, not 4); `reshootTie` rejected a tie picked by the FFID (planned 2,
## not unmatched); `noSourceStation` rejected a record matched by its FFID
## (planned 5, not unmatched); `oneSlice` rejected a slice of one receiver and
## one shot shown as a shot (the domain was `rdSource`); `oldSettings` rejected the
## match choice written again. `shotWithAnotherRecordsFfid` guards what already held.

import std/[os, strutils]
import parseSEG
import processSEG/qc/record
import viewSEG/core/[jobs, join, recordqc, session, settingsnif, spread]
import viewSEG/core/state
import utils/waiting

type Trace = tuple[src, rcv: float64] ## a source point of line 1 (0: none), a receiver of line 10

proc dataFile(path: string; record: int; traces: openArray[Trace]; receiverGather = false) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0, receiverGather: receiverGather))
  let samples = @[0'f32]
  var ch = 1
  for t in traces:
    var k = initTraceKeys()
    k.record = float64(record)
    k.channel = float64(ch)
    if t.src != 0:
      k.srcLine = 1
      k.srcPoint = t.src
      k.srcIndex = 1
    k.rcvLine = 10
    k.rcvPoint = t.rcv
    k.rcvIndex = 1
    k.intervalUs = 2000
    k.status = tsLive
    w.writeTrace(k, samples)
    inc ch
  doAssert w.close().len == 0, "file was not written: " & path

proc xRecord(record: int; src: float64; first, last: int): SpsRelation =
  SpsRelation(recordType: 'X', fieldRecord: record, recordIncrement: 1, instrumentCode: '1',
    srcLine: 1, srcPoint: src, srcIndex: 1, fromChannel: 1, toChannel: last - first + 1,
    channelIncrement: 1, rcvLine: 10, fromReceiver: float64(first), toReceiver: float64(last),
    rcvIndex: 1)

proc oRecord(record: int; rcv: float64; first, last: int): SpsRelation =
  ## O record `record`: receiver `rcv`, its shots `first` .. `last` of line 1.
  SpsRelation(recordType: 'O', fieldRecord: record, recordIncrement: 1, instrumentCode: '1',
    srcLine: 10, srcPoint: rcv, srcIndex: 1, fromChannel: 1, toChannel: last - first + 1,
    channelIncrement: 1, rcvLine: 1, fromReceiver: float64(first), toReceiver: float64(last),
    rcvIndex: 1)

proc surveyFile(path: string; relations: seq[SpsRelation]) =
  let f = SpsFile(headers: @[SpsHeader(code: "00", description: "SPS format version num.",
    data: "SPS 2.1;")], relations: relations)
  doAssert writeSps(f, path).len == 0

proc open(st: var AppState; surveys: seq[string]; data: string) =
  st.apply Command(kind: ckLoadSurvey, paths: surveys)
  doAssert st.settle(st.survey.layers.len == surveys.len and st.jobs.active.len == 0)
  var s = st.settings
  s.map.filters = {mfMissing, mfUnlisted, mfDuplicate}
  st.apply Command(kind: ckSettings, settings: s)
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: data)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
    st.jobs.active.len == 0)

func filtersDone(st: AppState): bool =
  st.recordQc.job == NoJob and st.recordQc.hits[mfMissing].state in {fsDone, fsNotChecked}

proc main*() =
  let dir = getTempDir() / ("viewseg-xorec-" & $getCurrentProcessId())
  createDir(dir)
  let xs = dir / "plan.x"
  surveyFile(xs, @[xRecord(7, 5, 1, 5), xRecord(1, 6, 1, 3), xRecord(8, 7, 1, 4),
    xRecord(9, 7, 1, 2), xRecord(10, 8, 1, 2), xRecord(11, 8, 3, 4)])
  let os = dir / "plan.o"
  surveyFile(os, @[oRecord(1, 1, 5, 7), oRecord(2, 2, 5, 6), oRecord(3, 2, 7, 8)])
  let surveys = [("X and O records", @[xs, os]), ("X records only", @[xs])]

  # (data, FFID, traces) by case name
  let rcv = dir / "rcv.sgd" # receiver 2 of shots 5, 6, 7: its FFID is X record 1's number
  dataFile(rcv, 1, [(5.0, 2.0), (6.0, 2.0), (7.0, 2.0)], receiverGather = true)
  let reshoot = dir / "reshoot.sgd" # source 7, receivers 1..4: X record 8 fits, 9 has the FFID
  dataFile(reshoot, 9, [(7.0, 1.0), (7.0, 2.0), (7.0, 3.0), (7.0, 4.0)])
  let tie = dir / "tie.sgd" # source 8, receivers 1 and 3: records 10 and 11 fit alike
  dataFile(tie, 10, [(8.0, 1.0), (8.0, 3.0)])
  let noSource = dir / "nosource.sgd" # receivers 1..5, no source station: FFID 7 is a record's
  dataFile(noSource, 7, [(0.0, 1.0), (0.0, 2.0), (0.0, 3.0), (0.0, 4.0), (0.0, 5.0)])
  let slice = dir / "slice.sgd" # one trace: receiver 2 of shot 5
  dataFile(slice, 7, [(5.0, 2.0)], receiverGather = true)
  let own = dir / "own.sgd" # source 5 with the FFID of source 6's X record
  dataFile(own, 1, [(5.0, 1.0), (5.0, 2.0), (5.0, 3.0), (5.0, 4.0)])

  for (what, loaded) in surveys:
    template check(name: string; data: string; body: untyped) =
      block:
        var st {.inject.} = initAppState()
        st.open(loaded, data)
        doAssert st.settle(st.sessions[0].records.len == 1 and st.sessions[0].checkedAgainst.len >
            0 and
          st.jobs.active.len == 0 and st.filtersDone), what & ", " & name
        let row {.inject.} = st.sessions[0].records[0]
        let hits {.inject.} = st.filterHits
        body
        st.shutdown()

    check "receiverAgainstO", rcv:
      # The union of O records 2 and 3 (or of the X records at the receiver): shots 5 to 8.
      doAssert st.shownDomain == rdReceiver, what
      doAssert row.planned == 4 and row.plannedMissing == 1, what & ": " & $row.planned &
        " planned, " & $row.plannedMissing & " missing"
      doAssert hits[mfMissing].state == fsDone and hits[mfMissing].count == 1, what & ": " &
        hits[mfMissing].note
      # the box and the filters name the same shots: the hover box's (all records)
      let hover = st.survey.plannedSpread(st.spreads, rdReceiver, stationKey(10, 2, 1))
      doAssert st.shownSpread.stations == 4 and hover.stations == 4, what & ": " &
        $st.shownSpread.stations & " / " & $hover.stations

    check "reshoot", reshoot:
      # Two X records at the source: the one the data fits (8, not the FFID's 9).
      doAssert st.shownDomain == rdSource, what
      doAssert row.planned == 4 and row.plannedMissing == 0, what & ": " & $row.planned &
        " planned, " & $row.plannedMissing & " missing"
      doAssert hits[mfMissing].count == 0 and "X record 8" in hits[mfMissing].note, what &
        ": " & hits[mfMissing].note

    check "reshootTie", tie:
      doAssert row.planned == -1 and row.plannedMissing == -1, what & ": " & $row.planned
      doAssert hits[mfMissing].state == fsNotChecked and
        "fit equally" in hits[mfMissing].note, what & ": " & hits[mfMissing].note

    check "noSourceStation", noSource:
      doAssert row.planned == -1, what & ": matched by its FFID, planned " & $row.planned
      doAssert hits[mfMissing].state == fsNotChecked and
        "no source station" in hits[mfMissing].note, what & ": " & hits[mfMissing].note

    check "oneSlice", slice:
      # one receiver, one shot: a slice of the receiver, against its four shots
      doAssert st.shownDomain == rdReceiver, what
      doAssert row.planned == 4 and row.plannedMissing == 3, what & ": " & $row.planned &
        " planned, " & $row.plannedMissing & " missing"
      doAssert hits[mfMissing].state == fsDone and hits[mfMissing].count == 3, what & ": " &
        hits[mfMissing].note

    check "shotWithAnotherRecordsFfid", own:
      # the FFID is X record 1's (source 6): the source station finds record 7
      doAssert row.planned == 5 and row.plannedMissing == 1, what & ": " & $row.planned &
        " planned, " & $row.plannedMissing & " missing"
      doAssert "X record 7" in hits[mfMissing].note, what & ": " & hits[mfMissing].note

  block derivedOnce:
    # X records only, no map filter: the O records are derived once for two receiver files
    var st = initAppState()
    st.apply Command(kind: ckLoadSurvey, paths: @[xs])
    doAssert st.settle(st.survey.layers.len == 1 and st.jobs.active.len == 0)
    for f in [rcv, slice]:
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: f)
      doAssert st.settle(st.sessions.len > 0 and st.sessions[^1].path == f.expandFilename and
        st.jobs.active.len == 0 and st.sessions[^1].checkedAgainst.len > 0), f
      doAssert st.sessions[^1].records[0].planned == 4, f & ": " &
        $st.sessions[^1].records[0].planned
    doAssert st.derivedRuns == 1, "derived " & $st.derivedRuns & " times"
    st.shutdown()

  block oldSettings:
    # a settings file written when a record could be matched by its FFID: read as station
    # matching, the choice dropped without a word
    var problems: seq[string]
    let s = readSettings("(settings (version 1) (join (recordMatch ffid) (traceMatch channel)))",
      "old.nif", Settings(), problems)
    doAssert problems.len == 0, $problems
    doAssert s.join.traceMatch == tmChannel
    doAssert "recordMatch" notin settingsDocument(s), "written again"

  removeDir(dir)
  echo "txorec: ok"

when isMainModule:
  main()
