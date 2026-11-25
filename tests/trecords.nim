## Record navigation in `core`: each open file carries one row per record
## (its gathers, from parseSEG's navigation tree) with the FFID, CDP, source
## and receiver that tell it apart and its size, made on the open job's
## thread; stepping through a fixture's records (next, previous, first,
## last, a place typed, an FFID typed) shows each in the same plot window,
## which keeps its scales, its display (gain included) and its order; a
## file of 100 000 records is listed whole, and found by FFID. A row holds
## only what its gather's kind keeps constant (a shot's FFID and source),
## its traces (seismic, auxiliary, dead) and those missing from its patch
## (`keyInformation`).
##
## Seen to fail: with a shot's row taking its first trace's CDP too,
## `rowsOfAShot` found CDP 0 on every shot of the survey; with the view
## fitted to each new gather (`carry` not set), `stepThroughRecords` found
## the scales changed at the second record; with `columnsOf` listing the CDP
## column whatever the rows hold, `rowsOfAShot` found it.
##
## Runs alone: it measures how long writing 100 000 records and finding one take.

import std/[math, monotimes, os, times]
import viewSEG/core/state
import utils/[fixtures, waiting]

proc laidOut(st: AppState): bool =
  let p = st.panel(MainPanel)
  p.laidOut and p.layout.traces > 0

proc gatherShown(st: AppState): int = st.panel(MainPanel).layers[0].source.gather

proc main*() =

  block rowsOfAShot:
    withFixtures fx:
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.surveySegy())
      doAssert st.settle(st.sessions.len == 1)
      let s = st.sessions[0]
      doAssert s.records.len == Shots
      for k, r in s.records:
        doAssert r.kind == gkShot and r.traces == Channels and r.first == k * Channels
        doAssert r.record == float64(FirstRecord + k), $r
        doAssert r.srcPoint == FirstSrcPoint + float64(k)
        doAssert r.ensemble.isNaN and r.rcvLine.isNaN, $r
      doAssert rcRecord in s.recordColumns and rcSource in s.recordColumns
      doAssert rcEnsemble notin s.recordColumns and rcReceiver notin s.recordColumns
      doAssert findRecord(s.records, float64(FirstRecord + 2)) == 2
      doAssert findRecord(s.records, 999) == -1
      doAssert station(1, 1001) == "1:1001" and station(NaN, 1001) == "1001" and
        station(NaN, NaN) == "" and station(100, 101.5) == "100:101.5"
      # A SEG-D record whose first traces are auxiliary: the FFID of a seismic one.
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.twoSetSegd())
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == fx.twoSetSegd())
      let segd = st.sessions[0]
      doAssert segd.records.len >= 1
      doAssert segd.records[0].record == float64(SegdRecordNo), $segd.records[0]
      st.shutdown()

  block keyInformation:
    # Each record's seismic, auxiliary and dead traces, and the traces
    # missing from its patch: against what the file declares (a SEG-Y file's
    # data traces per ensemble, a SEG-D record's seismic channel sets), and,
    # once the survey's relation file is loaded, against its X records
    # (processSEG's `recordCompleteness`, on a job): empty (-1), never 0,
    # where nothing says what was expected. Taking the relation file out of
    # the survey takes its check away.
    #
    # Seen to fail: with the declared count left out (no binary header
    # field read), the first row's "declared: -1"; with the check against the X file
    # never made (`checkRecords` not called when a relation file comes),
    # "no check against survey.x".
    withFixtures fx:
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.patchySegy())
      doAssert st.settle(st.sessions.len == 1)
      block fromTheFile:
        let rows = st.sessions[0].records
        doAssert rows.len == Shots
        for k, r in rows:
          doAssert r.seismic == (if k == PatchyShort: 19 else: Channels) and r.aux == 0, $r
          doAssert r.dead == (if k == 1: PatchyDead.len else: 0), $r
          doAssert r.declared == Channels and r.missingSource == msFile, $r
          doAssert r.missing == (if k == PatchyShort: 5 else: 0),
            "record " & $(FirstRecord + k) & ": missing " & $r.missing
      # the survey's relation file: the same, against the plan
      let sps = fx.surveySps()
      st.apply Command(kind: ckLoadSurvey, paths: @[sps.x])
      doAssert st.settle(st.sessions[0].checkedAgainst.len > 0), "no check against survey.x"
      block fromTheSurvey:
        let rows = st.sessions[0].records
        doAssert st.sessions[0].checkedAgainst == "survey.x"
        # this file's traces name no source line: a record is never matched to an X
        # record by its record number alone, so nothing is planned for it and its
        # missing traces stay counted against the file's own declaration
        for k, r in rows:
          doAssert r.planned == -1 and r.missingSource == msFile, $r
          doAssert r.missing == (if k == PatchyShort: 5 else: 0), $r
      st.apply Command(kind: ckUnloadSurvey, layer: st.survey.layers[^1].id)
      doAssert st.sessions[0].checkedAgainst == "" and
        st.sessions[0].records[0].missingSource == msFile
      # a file that says nothing: an empty cell, never 0
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.pilotSegy())
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == fx.pilotSegy())
      let pilot = st.sessions[0].records[0]
      doAssert pilot.missing == -1 and pilot.missingSource == msNone and pilot.aux == 1, $pilot
      # SEG-D: the seismic channel sets declare the record's seismic traces
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.twoSetSegd())
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == fx.twoSetSegd())
      let segd = st.sessions[0].records[0]
      doAssert segd.declared == segd.seismic and segd.seismic > 0 and segd.missing == 0, $segd
      st.shutdown()

  block stepThroughRecords:
    # The acceptance test of record navigation: next, previous, first, last
    # and a typed place, as the keys and the record list do, on a fixture of
    # three shots; scales, gain and order are kept.
    withFixtures fx:
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.surveySegy())
      doAssert st.settle(st.laidOut)
      var d = st.panel(MainPanel).layers[0].display
      d.gain = dgExponential
      d = d.withGainDb(-4.5)
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      let order = @[SortKey(field: hfOffset)]
      st.apply Command(kind: ckSort, panel: MainPanel, order: order)
      var v = st.panel(MainPanel).view
      (v.traces, v.timeMs, v.columns, v.rows) = (Span(lo: 3.5, hi: 9.5), Span(lo: 200, hi: 600),
        900, 700)
      st.apply Command(kind: ckView, panel: MainPanel, view: v)
      let session = st.sessions[0].id
      for target in [1, 2, 1, 0, Shots - 1, 0]:
        st.apply Command(kind: ckGather, panel: MainPanel, gather: target)
        doAssert st.gatherShown == target
        doAssert st.selection.activeGather == GatherRef(file: session, gather: target)
        doAssert st.settle(st.laidOut), $target
        let p = st.panel(MainPanel)
        doAssert p.view.traces == v.traces and p.view.timeMs == v.timeMs,
          "record " & $target & ": the scales changed: " & $p.view
        doAssert p.layers[0].display.gain == dgExponential and p.layers[0].display.gainDb == -4.5
        doAssert p.layers[0].order == order
      # A view of all the traces stays a view of all of them.
      var all = st.panel(MainPanel).view
      all.traces = Span(lo: -0.5, hi: float64(Channels) - 0.5)
      st.apply Command(kind: ckView, panel: MainPanel, view: all)
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
      doAssert st.settle(st.laidOut and st.gatherShown == 1)
      doAssert st.panel(MainPanel).view.traces == all.traces
      st.apply Command(kind: ckGather, panel: MainPanel, gather: Shots)
      doAssert st.gatherShown == 1, "a record past the last is refused"
      st.shutdown()

  block aHundredThousandRecords:
    withFixtures fx:
      let t0 = getMonoTime()
      let path = fx.manyRecordsSegy()
      let written = getMonoTime() - t0
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1)
      let s = st.sessions[0]
      doAssert s.records.len == ManyRecords
      doAssert s.records[^1].record == float64(1000 + ManyRecords)
      doAssert s.records[54_321].srcPoint == float64(5001 + 54_321), $s.records[54_321]
      let t1 = getMonoTime()
      doAssert findRecord(s.records, float64(1001 + 99_998)) == 99_998
      let found = getMonoTime() - t1
      st.apply Command(kind: ckGather, panel: MainPanel, gather: ManyRecords - 1)
      doAssert st.settle(st.laidOut and st.gatherShown == ManyRecords - 1)
      echo "trecords: ", ManyRecords, " records; written in ", written.inMilliseconds,
        " ms; an FFID found in ", found.inMicroseconds, " us"
      st.shutdown()

when isMainModule:
  main()
