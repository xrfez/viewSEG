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
## `stationAtAnotherIndex` rejected, in turn: the check counting receiver 10/3 missing when
## the data holds it at index 2 only (expected 3, missing 1) and the station at indices 1
## and 2 as two (0 recorded twice), presence being taken by index; the shot unmatched when
## its source is at index 2 and the survey has the point at index 1 only; and the receiver
## gather at index 2 unmatched in the Records window (its O records found by index).
## `oneDerivation` rejected the map making O records of its own from the X file, beside the
## ones the Records window is checked against; `oFileLoadedAfterX` the derived O records
## kept once an O file was loaded. `derivationCancelled` rejected the filters saying "no
## relation file is loaded" while the O records were derived, and a cancelled derivation
## started again on its own (run twice, its note gone); `indexNamesNone` the reason "X
## record 21, matched by file number alone, belongs to another source".

import std/[atomics, os, strutils]
import parseSEG
import processSEG/qc/record
import viewSEG/core/[jobs, join, missingjobs, missingreport, recordqc, relationcheck, session,
  settingsnif, spread]
import viewSEG/core/state
import utils/waiting

type Trace = tuple[src, rcv: float64] ## a source point of line 1 (0: none), a receiver of line 10

proc dataFile(path: string; record: int; traces: openArray[Trace]; receiverGather = false;
    srcIndices: openArray[int16] = []; rcvIndices: openArray[int16] = []) =
  ## Trace `i` has source index `srcIndices[i]` and receiver index `rcvIndices[i]` when they
  ## are given, else 1.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0, receiverGather: receiverGather))
  let samples = @[0'f32]
  var ch = 1
  for i, t in traces:
    var k = initTraceKeys()
    k.record = float64(record)
    k.channel = float64(ch)
    if t.src != 0:
      k.srcLine = 1
      k.srcPoint = t.src
      k.srcIndex = if srcIndices.len > 0: srcIndices[i] else: 1
    k.rcvLine = 10
    k.rcvPoint = t.rcv
    k.rcvIndex = if rcvIndices.len > 0: rcvIndices[i] else: 1
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

proc oRecord(record: int; rcv: float64; first, last: int; srcIndex = 1): SpsRelation =
  ## O record `record`: receiver `rcv`, its shots `first` .. `last` of line 1.
  SpsRelation(recordType: 'O', fieldRecord: record, recordIncrement: 1, instrumentCode: '1',
    srcLine: 10, srcPoint: rcv, srcIndex: 1, fromChannel: 1, toChannel: last - first + 1,
    channelIncrement: 1, rcvLine: 1, fromReceiver: float64(first), toReceiver: float64(last),
    rcvIndex: srcIndex)

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

var
  holdDerive: Gate
  deriveHeld: Gate

proc deriveHook(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  ## Holds the derivation of the O records at its phase, so it can be cancelled running.
  discard id
  if phase != "deriving the receivers' shots" or back: return
  deriveHeld.store(true)
  var n = 0
  while not holdDerive.load and n < 30000:
    sleep 1
    inc n

func deriveJobs(st: AppState): int =
  for j in st.jobs.active:
    if j.spec.title == "Derive the receivers' shots from the X records": inc result

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
  let noSources = dir / "nosources.sgd" # a receiver gather whose traces name no source
  dataFile(noSources, 3, [(0.0, 2.0), (0.0, 2.0)], receiverGather = true)
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
      let hover = st.survey.plannedSpread(st.madeRelations(rdReceiver), rdReceiver,
        stationKey(10, 2, 1))
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

    check "receiverWithoutSources", noSources:
      doAssert row.planned == -1 and row.plannedMissing == -1, what & ": planned " & $row.planned
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

  block sourceWithTwoIndices:
    # Receiver 2's O record 1 has shots 5 to 7 (index 1), O record 2 shot 7 (index 2): a
    # station is its line and point, so three sources; the data has 5, 6, 7 of index 1. The
    # Records window, the shown record, the box and the Missing traces report all say 3
    # planned, 0 missing.
    let two = dir / "twoindices.o"
    surveyFile(two, @[oRecord(1, 2, 5, 6), oRecord(2, 2, 7, 7, srcIndex = 2)])
    var st = initAppState()
    st.open(@[xs, two], rcv)
    doAssert st.settle(st.sessions[0].checkedAgainst.len > 0 and st.jobs.active.len == 0 and
      st.filtersDone)
    let row = st.sessions[0].records[0]
    doAssert row.planned == 3 and row.plannedMissing == 0, $row.planned & " planned, " &
      $row.plannedMissing & " missing"
    doAssert st.filterHits[mfMissing].count == 0, st.filterHits[mfMissing].note
    doAssert row.unlisted == 0 and st.filterHits[mfUnlisted].count == 0,
      "unlisted " & $row.unlisted & ": the source 1/7 of index 1 is the O record's 1/7"
    doAssert st.shownSpread.stations == 3, $st.shownSpread.stations
    st.shutdown()
    var g = SurveyGeometry()
    g.addSps(parseSps(readFile(two)), rdReceiver)
    var geo = new SurveyGeometry
    geo[] = g
    let jobs = initJobs()
    let sink = MissingSink()
    let id = jobs.submit(missingSpec(dir, @[rcv]), scanMissing(dir, @[rcv], geo, sink, ""))
    doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
    let r = sink.result.receiver.stats
    doAssert r.inTemplate == 3 and r.missing == 0, $r.inTemplate & " " & $r.missing

  block receiverPointAtTwoIndices:
    # An X record that calls receiver point 2 at two indices plans two stations (points 1 and
    # 2), as the box counts them; the data holds points 1 and 3, so point 2 is missing and 3 unlisted
    let twice = dir / "twice.x"
    var first = xRecord(20, 9, 1, 2)
    var again = xRecord(20, 9, 2, 2)
    again.fromChannel = 3
    again.toChannel = 3
    again.rcvIndex = 2
    surveyFile(twice, @[first, again])
    let one = dir / "one.sgd"
    dataFile(one, 20, [(9.0, 1.0), (9.0, 3.0)])
    var st = initAppState()
    st.open(@[twice], one)
    doAssert st.settle(st.sessions[0].checkedAgainst.len > 0 and st.jobs.active.len == 0 and
      st.filtersDone)
    let row = st.sessions[0].records[0]
    doAssert row.planned == 2 and row.plannedMissing == 1, $row.planned & " planned, " &
      $row.plannedMissing & " missing"
    doAssert st.filterHits[mfMissing].count == 1 and row.unlisted == 1,
      st.filterHits[mfMissing].note & " " & $row.unlisted
    doAssert st.shownSpread.stations == 2, $st.shownSpread.stations
    st.shutdown()

  block stationAtAnotherIndex:
    # The relation record calls points 1..3 at index 1; the data holds point 3 at index 2
    # only, and point 2 at indices 1 and 2 (a shot: its receivers 10/1..3; a receiver gather:
    # its sources 1/5..7), and the gather's own station (the shot's source 1/11, the
    # receiver 10/2) at index 2, which the survey has at index 1 only. A station is its line
    # and point: matched, 3 planned, none missing, none unlisted, one recorded twice, in the
    # check itself, the Records window, the filters, the box and the Missing traces report.
    let x = dir / "index.x"
    surveyFile(x, @[xRecord(40, 11, 1, 3)])
    let o = dir / "index.o"
    surveyFile(o, @[oRecord(1, 2, 5, 7)])
    let shot = dir / "indexshot.sgd"
    dataFile(shot, 40, [(11.0, 1.0), (11.0, 2.0), (11.0, 2.0), (11.0, 3.0)],
      srcIndices = [2'i16, 2, 2, 2], rcvIndices = [1'i16, 1, 2, 2])
    let gather = dir / "indexrcv.sgd"
    dataFile(gather, 3, [(5.0, 2.0), (6.0, 2.0), (6.0, 2.0), (7.0, 2.0)],
      receiverGather = true, srcIndices = [1'i16, 1, 2, 2], rcvIndices = [2'i16, 2, 2, 2])
    block:
      var g = SurveyGeometry()
      g.addSps(parseSps(readFile(x)), rdSource)
      var f = openSeismic(shot, keys = true)
      let (c, why) = g.shotCheck(f.rowsOf(0 ..< f.len), JobContext())
      doAssert why.len == 0, why
      doAssert c.expected == 3 and c.missing == 0 and c.present == 3 and c.unlisted == 0 and
        c.missingStations.len == 0 and c.duplicates == 1, $c.expected & " expected, " &
        $c.missing & " missing, " & $c.unlisted & " unlisted, " & $c.duplicates & " twice"
    for (what, survey, data) in [("shot", x, shot), ("receiver gather", o, gather)]:
      var st = initAppState()
      st.open(@[survey], data)
      doAssert st.settle(st.sessions[0].checkedAgainst.len > 0 and st.jobs.active.len == 0 and
        st.filtersDone), what
      let row = st.sessions[0].records[0]
      doAssert row.planned == 3 and row.plannedMissing == 0 and row.unlisted == 0 and
        row.duplicates == 1, what & ": " & $row.planned & " planned, " & $row.plannedMissing &
        " missing, " & $row.unlisted & " unlisted, " & $row.duplicates & " twice"
      let hits = st.filterHits
      doAssert hits[mfMissing].state == fsDone and hits[mfMissing].count == 0 and
        hits[mfMissing].stations.len == 0, what & ": " & hits[mfMissing].note
      doAssert hits[mfUnlisted].count == 0 and hits[mfUnlisted].traces.len == 0, what & ": " &
        $hits[mfUnlisted].traces
      doAssert hits[mfDuplicate].count == 1 and hits[mfDuplicate].traces.len == 2, what & ": " &
        $hits[mfDuplicate].count & " " & $hits[mfDuplicate].traces
      doAssert st.shownSpread.stations == 3, what & ": " & $st.shownSpread.stations
      st.shutdown()
      var g = SurveyGeometry()
      g.addSps(parseSps(readFile(survey)), rdSource)
      var geo = new SurveyGeometry
      geo[] = g
      let jobs = initJobs()
      let sink = MissingSink()
      let id = jobs.submit(missingSpec(dir, @[data]), scanMissing(dir, @[data], geo, sink, ""))
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}), what
      let r = if data == shot: sink.result.shot.stats else: sink.result.receiver.stats
      doAssert r.records == 1 and r.inTemplate == 3 and r.missing == 0 and
        r.missingInRecords == 0, what & ": " & $r.inTemplate & " in the template, " &
        $r.missing & " missing"

  block twoXLayers:
    # Two X files loaded: a receiver file is checked against the first one's records alone
    let more = dir / "more.x"
    surveyFile(more, @[xRecord(30, 20, 1, 3)])
    var st = initAppState()
    st.open(@[xs, more], rcv)
    doAssert st.settle(st.sessions[0].checkedAgainst.len > 0 and st.jobs.active.len == 0 and
      st.filtersDone)
    doAssert st.sessions[0].records[0].planned == 4, $st.sessions[0].records[0].planned
    st.shutdown()

  block oneDerivation:
    # X records only, the template box and the filters on, a receiver gather shown: the
    # Records window, the record shown and the box read one derivation of the O records
    # (made once, not a second time for the map), and count the same shots.
    var st = initAppState()
    var set = st.settings
    set.map.templateBox = true
    st.apply Command(kind: ckSettings, settings: set)
    st.open(@[xs], rcv)
    doAssert st.settle(st.sessions[0].checkedAgainst.len > 0 and st.jobs.active.len == 0 and
      st.filtersDone)
    doAssert st.derivedRuns == 1, "derived " & $st.derivedRuns & " times"
    doAssert st.spreads.relations.isNil, "the map made O records of its own"
    doAssert not st.derivedReceivers.isNil and
      st.madeRelations(rdReceiver) == st.derivedReceivers
    let row = st.sessions[0].records[0]
    let hover = st.survey.plannedSpread(st.madeRelations(rdReceiver), rdReceiver,
      stationKey(10, 2, 1))
    doAssert row.planned == 4 and st.shownSpread.stations == 4 and hover.stations == 4 and
      "4 O record" in st.filterHits[mfMissing].note, $row.planned & " / " &
      $st.shownSpread.stations & " / " & $hover.stations & " / " & st.filterHits[mfMissing].note
    doAssert row.plannedMissing == st.filterHits[mfMissing].count
    st.shutdown()

  block derivationCancelled:
    # X records only, the template box and the "missing" filter on, a receiver gather shown:
    # while the O records are derived the filters say so; the derivation cancelled is not
    # started again on its own (the cells' note stays), and Retry starts it again.
    var st = initAppState()
    var set = st.settings
    set.map.templateBox = true
    set.map.filters = {mfMissing, mfUnlisted, mfDuplicate}
    st.apply Command(kind: ckSettings, settings: set)
    st.apply Command(kind: ckLoadSurvey, paths: @[xs])
    doAssert st.settle(st.survey.layers.len == 1 and st.jobs.active.len == 0)
    holdDerive.store(false)
    deriveHeld.store(false)
    setJobHook(deriveHook)
    try:
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: rcv)
      doAssert st.settle(deriveHeld.load), "no derivation ran"
      doAssert st.settle(st.sessions.len == 1 and st.filtersDone)
      let waiting = st.filterHits[mfMissing]
      doAssert waiting.state == fsComputing and "being derived" in waiting.note,
        $waiting.state & ": " & waiting.note
      var running = NoJob
      for j in st.jobs.active:
        if j.spec.title == "Derive the receivers' shots from the X records": running = j.id
      doAssert running != NoJob
      st.apply Command(kind: ckCancelJob, job: running)
      holdDerive.store(true)
      doAssert st.settle(st.deriveJobs == 0 and st.sessions[0].checkNote.len > 0)
      let runs = st.derivedRuns
      for _ in 0 ..< 20:
        discard st.drainInbox()
        doAssert st.deriveJobs == 0, "derived again on its own"
        sleep 5
      doAssert st.derivedRuns == runs and "cancelled" in st.sessions[0].checkNote,
        $st.derivedRuns & ": " & st.sessions[0].checkNote
      doAssert st.filterHits[mfMissing].state == fsNotChecked and
        "cancelled" in st.filterHits[mfMissing].note, st.filterHits[mfMissing].note
      # the user asks again
      st.apply Command(kind: ckRetry, panel: MainPanel)
      doAssert st.derivedRuns == runs + 1
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions[0].records[0].planned == 4 and
        st.filtersDone), $st.sessions[0].records[0].planned
      doAssert st.sessions[0].checkNote.len == 0 and st.filterHits[mfMissing].count == 1
    finally:
      holdDerive.store(true)
      setJobHook(nil)
    st.shutdown()

  block indexNamesNone:
    # The survey has source point 1/12 at indices 2 and 3; the headers say index 1 (and the
    # FFID is X record 21's): unmatched, the reason the index, not a record number.
    let two = dir / "twoidx.x"
    var a = xRecord(21, 12, 1, 3)
    a.srcIndex = 2
    var b = xRecord(22, 12, 1, 3)
    b.srcIndex = 3
    surveyFile(two, @[a, b])
    let shot = dir / "idx1.sgd"
    dataFile(shot, 21, [(12.0, 1.0), (12.0, 2.0), (12.0, 3.0)])
    var g = SurveyGeometry()
    g.addSps(parseSps(readFile(two)), rdSource)
    var f = openSeismic(shot, keys = true)
    let (_, why) = g.shotCheck(f.rowsOf(0 ..< f.len), JobContext())
    doAssert why == "the trace headers give source index 1 and the survey has this point " &
      "at indices 2 and 3 only: the index names neither", why
    # the same for a receiver: receiver 10/4's O records at indices 2 and 3, the headers' 1
    var o = SurveyGeometry()
    o.addSps(SpsFile(relations: @[oRecord(5, 4, 5, 6), oRecord(6, 4, 7, 8)]), rdReceiver)
    var p = SurveyGeometry()
    var atTwo = oRecord(5, 4, 5, 6)
    atTwo.srcIndex = 2
    var atThree = oRecord(6, 4, 7, 8)
    atThree.srcIndex = 3
    p.addSps(SpsFile(relations: @[atTwo, atThree]), rdReceiver)
    doAssert o.receiverRecords(stationKey(10, 4, 2)).records.len == 2, "one index: both"
    let r = p.receiverRecords(stationKey(10, 4, 1))
    doAssert r.records.len == 0 and r.why == "the trace headers give receiver index 1 and " &
      "the survey has this point at indices 2 and 3 only: the index names neither", r.why

  block oRecordsOnly:
    # Only an O file loaded: its receiver gathers are checked against it; its shots have
    # no X records to be checked against
    var st = initAppState()
    st.open(@[os], rcv)
    doAssert st.settle(st.sessions[0].checkedAgainst.len > 0 and st.jobs.active.len == 0)
    doAssert st.sessions[0].records[0].planned == 4 and
      st.sessions[0].records[0].plannedMissing == 1, $st.sessions[0].records[0].planned
    st.shutdown()
    var shots = initAppState()
    shots.open(@[os], own)
    doAssert shots.settle(shots.sessions[0].checkedAgainst.len > 0 and
      shots.jobs.active.len == 0)
    doAssert shots.sessions[0].records[0].planned == -1, "a shot with no X records"
    shots.shutdown()

  block oFileLoadedAfterX:
    # X records loaded and a receiver file checked against the O records derived from them;
    # an O file loaded afterwards (receiver 2: shots 5 and 6) checks it again against its own;
    # unloaded, back to the derived
    let late = dir / "late.o"
    surveyFile(late, @[oRecord(1, 2, 5, 6)])
    var st = initAppState()
    st.open(@[xs], rcv)
    doAssert st.settle(st.sessions[0].checkedAgainst.len > 0 and st.jobs.active.len == 0)
    doAssert st.sessions[0].records[0].planned == 4, $st.sessions[0].records[0].planned
    doAssert st.derivedCount == 1
    # a note why it was not checked (a derive job cancelled) goes with the next check
    st.sessions[0].setCheckNote("not checked: the O records were not derived (cancelled)")
    st.apply Command(kind: ckLoadSurvey, paths: @[late])
    doAssert st.settle(st.survey.listedLayer(rdReceiver) >= 0 and
      st.sessions[0].records[0].planned == 2 and st.sessions[0].checkNote.len == 0 and
      st.jobs.active.len == 0), $st.sessions[0].records[0].planned
    doAssert st.derivedCount == 0, "the O file serves: nothing derived is held"
    st.apply Command(kind: ckUnloadSurvey,
      layer: st.survey.layers[st.survey.listedLayer(rdReceiver)].id)
    doAssert st.settle(st.survey.listedLayer(rdReceiver) < 0 and st.sessions[0].records[
        0].planned == 4 and
      st.jobs.active.len == 0), $st.sessions[0].records[0].planned
    # clearing the survey drops what was derived
    st.apply Command(kind: ckClearSurvey)
    doAssert st.settle(st.derivedCount == 0)
    st.shutdown()

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
