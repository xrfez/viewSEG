## The first-break overlay's data (`core/firstbreaks`, `core/firstbreakjobs`):
## the pick and the model's time of each trace of a synthetic shot with a known
## geometry and a known velocity, the offsets from the headers or from the
## file's coordinates (and no model without either), a planted mis-positioned
## trace that shows as a difference, killed traces left out, and the job on
## the state: made off the UI thread, kept per record, a newer key cancelling
## the older job and its late answer dropped.
##
## Seen to fail: with the model's time taken from the pick, "the model is off by
## 10.0 ms"; with the killed traces not passed as not live, "killed trace picked";
## with the offsets taken from nowhere, "coordinates: source none"; with the state
## filling the entry of the newer key from the older job's answer, "stale answer
## kept: the newer key's entry was filled by the older job's"; with a trace of another
## interval left live, "a trace of another interval is live"; with the node record fitted
## whole, "vertical 3"; with the raw residual against 12 ms for the flag, "trace 0 flagged,
## difference 23.9"; with a header offset of 0 fitted, the zero-offset trace modelled; with
## `hasModel` counting the picks used, "not b.hasModel"; with the second record's rows not
## taken from the record's start, "trace 650: 572.0, pickInto nan".

import std/[math, os, strutils]
import parseSEG
import processSEG/core/[types, workspace]
import processSEG/qc/firstbreak
import viewSEG/core/[displaypresets, firstbreakjobs, firstbreaks]
import viewSEG/core/state {.all.}
import utils/[breakfiles, fixtures, waiting]

var
  holdBreaks, breaksHeld: Gate

proc breaksHook(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  ## Holds the first-break job at its phase, so a newer key can replace it.
  discard id
  if phase != "picking and fitting the first breaks" or back: return
  breaksHeld.open()
  var n = 0
  while not holdBreaks.isOpen and n < 30000:
    sleep 1
    inc n

proc breaksOf(path: string; killed: openArray[int] = []): FirstBreaks =
  var f = openSeismic(path, keys = true)
  result = breaksOfRecord(addr f, path, 0 ..< f.len, killed)
  f.close()

proc main*() =

  block modelAndPicksMatchTheGeometry:
    withFixtures fx:
      let b = breaksOf(fx.shotSegy("header.sgy", gHeaderOffset))
      doAssert b.state == bkDone and b.source == bsFile and b.hasModel,
        "source " & $b.source & " used " & $b.used
      doAssert b.modelNote == "" and b.statusWords == ""
      var worstModel, worstPick = 0.0
      for i in 0 ..< Traces:
        if i == PlantedTrace: continue
        let truth = arrivalMs(offsetOf(i))
        worstModel = max(worstModel, abs(b.modelOf(i) - truth))
        worstPick = max(worstPick, abs(b.pickOf(i) - truth))
        doAssert not b.mismatched(i), "trace " & $i & " differs by " & $b.differenceMs(i)
      doAssert worstModel <= 8, "the model is off by " & $worstModel & " ms"
      doAssert worstPick <= 12, "a pick is off by " & $worstPick & " ms"

  block plantedTraceShowsADifference:
    withFixtures fx:
      let b = breaksOf(fx.shotSegy("planted.sgy", gHeaderOffset))
      let d = b.differenceMs(PlantedTrace)
      doAssert abs(d - PlantedMs) <= 12, "planted difference " & $d
      doAssert b.mismatched(PlantedTrace)
      let truth = arrivalMs(offsetOf(PlantedTrace))
      doAssert abs(b.modelOf(PlantedTrace) - truth) <= 8, "the model followed the planted trace"
      let say = b.readoutText(PlantedTrace)
      doAssert "model" in say and "pick" in say and "+" in say, say
      doAssert b.readoutText(Traces + 5) == "", "a trace outside the record has no words"

  block offsetsFromTheFilesOwnCoordinates:
    withFixtures fx:
      let b = breaksOf(fx.shotSegy("coords.sgy", gCoordinates))
      doAssert b.source == bsFile and b.hasModel, "coordinates: source " & $b.source
      let truth = arrivalMs(offsetOf(3))
      doAssert abs(b.modelOf(3) - truth) <= 8, "model " & $b.modelOf(3)

  block withoutOffsetsThePicksAloneAndWhy:
    withFixtures fx:
      let b = breaksOf(fx.shotSegy("none.sgy", gNothing))
      doAssert b.state == bkDone and b.source == bsNone and not b.hasModel
      doAssert b.picked >= Traces - 2, "picks " & $b.picked
      for i in 0 ..< Traces: doAssert b.modelOf(i).isNaN
      doAssert not b.pickOf(10).isNaN
      doAssert "survey" in b.modelNote and "coordinates" in b.modelNote, b.modelNote
      doAssert "pick" in b.readoutText(10) and "no model" in b.readoutText(10),
        b.readoutText(10)

  block killedTracesAreSkipped:
    withFixtures fx:
      let path = fx.shotSegy("killed.sgy", gHeaderOffset)
      let all = breaksOf(path)
      let some = breaksOf(path, [10, 11])
      for t in [10, 11]:
        doAssert some.pickOf(t).isNaN, "killed trace picked"
        doAssert some.modelOf(t).isNaN, "killed trace modelled"
      doAssert some.picked == all.picked - 2
      doAssert abs(some.modelOf(30) - all.modelOf(30)) <= 2, "the others' model moved"

  block cancelledByTheProgressHook:
    withFixtures fx:
      let path = fx.shotSegy("cancel.sgy", gHeaderOffset)
      var f = openSeismic(path, keys = true)
      var stopped = false
      try:
        discard breaksOfRecord(addr f, path, 0 ..< f.len, [],
          proc (done, total: int): bool = false)
      except JobCancelledError: stopped = true
      f.close()
      doAssert stopped, "a stop from the progress hook did not stop the work"

  block theJobKeepsOneResultPerRecordAndDropsStaleAnswers:
    withFixtures fx:
      let path = fx.shotSegy("job.sgy", gHeaderOffset)
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
        st.jobs.active.len == 0)
      doAssert st.firstBreaks.len == 0, "work was done with the overlay off"
      var d = st.panel(MainPanel).layers[0].display
      doAssert not d.firstBreaks
      d.firstBreaks = true
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      let first = st.breaksIndex(0)
      doAssert first >= 0 and st.firstBreaks[first].state == bkComputing,
        "the overlay did not ask for its job"
      doAssert st.settle(st.firstBreaks.len == 1 and st.firstBreaks[0].state == bkDone and
        st.firstBreaks[0].job == NoJob and st.jobs.active.len == 0)
      doAssert st.firstBreaks[0].hasModel
      doAssert abs(st.firstBreaks[0].modelOf(st.sessions[0].base) - arrivalMs(offsetOf(0))) <= 8
      # a kill is a new key: the old result goes, a new one is made without the trace
      let base = st.sessions[0].base
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base + 5],
        on: true)
      doAssert st.settle(st.firstBreaks.len == 1 and st.firstBreaks[0].state == bkDone and
        st.firstBreaks[0].key.killed == @[5] and st.jobs.active.len == 0)
      doAssert st.firstBreaks[0].pickOf(5).isNaN, "killed trace picked"
      # off: the result may stay (stepping back is instant), nothing new is asked
      d.firstBreaks = false
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      doAssert st.settle(st.jobs.active.len == 0)
      st.shutdown()

  block aNewKeyCancelsTheRunningJobAndItsLateAnswerIsDropped:
    withFixtures fx:
      let path = fx.shotSegy("late.sgy", gHeaderOffset)
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
        st.jobs.active.len == 0)
      holdBreaks.close()
      breaksHeld.close()
      setJobHook(breaksHook)
      var d = st.panel(MainPanel).layers[0].display
      d.firstBreaks = true
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      doAssert waitUntil(breaksHeld.isOpen), "the first breaks were not found on a job"
      doAssert st.firstBreaks.len == 1 and st.firstBreaks[0].state == bkComputing
      let old = st.firstBreaks[0].job
      # a kill changes the key while the job is held: it is given up and a new one asked for
      let base = st.sessions[0].base
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base + 7],
        on: true)
      doAssert st.firstBreaks.len == 1 and st.firstBreaks[0].job != old and
        st.firstBreaks[0].key.killed == @[7], "the older job was not replaced"
      # the older job's answer, late (as one that did not stop in time would post it):
      # the entry of the newer key, still being made, is not filled by it
      var stale = FirstBreaks(state: bkDone, first: 0, dtMs: Dt, pickMs: newSeq[float64](Traces),
        modelMs: newSeq[float64](Traces), confidence: newSeq[float64](Traces))
      for i in 0 ..< Traces: stale.pickMs[i] = 1.0
      st.mailbox.post Msg(job: old, kind: mkFirstBreaks, breaks: stale)
      discard st.drainInbox()
      doAssert st.firstBreaks[0].state == bkComputing and st.firstBreaks[0].pickMs.len == 0,
        "stale answer kept: the newer key's entry was filled by the older job's"
      holdBreaks.open()
      setJobHook(nil)
      doAssert st.settle(st.firstBreaks.len == 1 and st.firstBreaks[0].state == bkDone and
        st.jobs.active.len == 0)
      doAssert st.firstBreaks[0].key.killed == @[7] and st.firstBreaks[0].pickOf(7).isNaN,
        "stale answer kept: trace 7 has a pick"
      st.shutdown()

  block aTraceOfAnotherIntervalIsNotLive:
    # the plot's axis is the first seismic trace's interval: a trace of another one is
    # drawn at it, so it is not picked (the writer refuses a trace without an interval,
    # so the record without any, `bkFailed`, is not a file to make)
    withFixtures fx:
      let path = fx.customShot("interval.sgy", Traces, proc (i: int; k: var TraceKeys): float64 =
        if i == 5: k.intervalUs = 4000
        arrivalMs(k.offset))
      let b = breaksOf(path)
      doAssert b.state == bkDone and abs(b.dtMs - Dt) < 1e-9, "dt " & $b.dtMs
      doAssert b.pickOf(5).isNaN and b.modelOf(5).isNaN, "a trace of another interval is live"
      doAssert abs(b.pickOf(20) - arrivalMs(offsetOf(20))) <= 12, "pick " & $b.pickOf(20)

  block twoRecordsADelayAndKilledTracesPickOnTheirOwnAxes:
    # the second record starts at trace 600 of the file, past a read chunk, and its data
    # start at 100 ms: every killed trace has no pick, and every other trace whose break
    # lies in the data is picked on that record's time axis (the picks are the second,
    # guided pass's: the record's first-pass model guides them)
    withFixtures fx:
      let path = fx.customShot("two.sgy", 1200, proc (i: int; k: var TraceKeys): float64 =
        k.record = float64(1 + i div 600)
        if i >= 600: k.t0Ms = 100
        arrivalMs(k.offset))
      let killed = [650, 1111, 1112]
      var f = openSeismic(path, keys = true)
      let rec = 600 .. 1199
      let b = breaksOfRecord(addr f, path, rec, killed)
      var none: seq[int]
      var checked, near = 0
      for t in rec:
        let got = b.pickOf(t)
        if got.isNaN: none.add t
        elif arrivalMs(offsetOf(t mod Traces)) >= 100 + 30:
          inc checked
          if abs(got - arrivalMs(offsetOf(t mod Traces))) <= 12: inc near
      doAssert none == @killed, "no pick at " & $none
      doAssert b.twoPass and checked > 400 and near * 100 >= checked * 95,
        $near & " of " & $checked & " picks within 12 ms of the arrival"
      doAssert abs(b.pickOf(700) - arrivalMs(offsetOf(700 mod Traces))) <= 12,
        "delayed record: " & $b.pickOf(700)
      doAssert b.shiftOf(700) == 0.0
      f.close()

  block aTraceThatStartsLaterIsDrawnWhereItsSamplesAre:
    withFixtures fx:
      let path = fx.customShot("t0.sgy", Traces, proc (i: int; k: var TraceKeys): float64 =
        if i == 5: k.t0Ms = 50
        arrivalMs(k.offset))
      let b = breaksOf(path)
      doAssert b.shiftOf(5) == -50.0 and b.shiftOf(6) == 0.0, $b.shiftOf(5)
      # its time is on its own axis (its break is at the true time), the plot's is 50 ms earlier
      doAssert abs(b.pickOf(5) - arrivalMs(offsetOf(5))) <= 12 and
        abs(b.modelOf(5) - arrivalMs(offsetOf(5))) <= 8

  block aSmoothDriftIsNotOffItsNeighbours:
    # the residual from the model drifts past 12 ms along the spread (the record's limit may
    # flag its largest), the residual against the neighbours' does not: no trace is off its
    # neighbours. (Before the rule had two parts, the fit's `suspect` alone was the test and
    # nothing was flagged.)
    withFixtures fx:
      let path = fx.customShot("drift.sgy", Traces, proc (i: int; k: var TraceKeys): float64 =
        let u = (float64(i) - 24) / 14
        arrivalMs(k.offset) + (if abs(u) < 1: 80 * (0.5 + 0.5 * cos(PI * u)) else: 0.0))
      let b = breaksOf(path)
      var worst = 0.0
      for t in 0 ..< Traces:
        doAssert not b.rule.offNeighbours[t], "trace " & $t & " off its neighbours, difference " &
          $b.differenceMs(t)
        if not b.differenceMs(t).isNaN: worst = max(worst, abs(b.differenceMs(t)))
      doAssert worst > 12, "the drift is only " & $worst & " ms: the test is not one"
      doAssert b.rule.nOffModel < Traces div 2, $b.rule.nOffModel & " off the model"

  block offsetZeroIsUnset:
    withFixtures fx:
      let path = fx.customShot("zero.sgy", Traces, proc (i: int; k: var TraceKeys): float64 =
        if i < 4: k.offset = 0
        arrivalMs(offsetOf(i)))
      let b = breaksOf(path)
      for t in 0 ..< 4:
        doAssert b.modelOf(t).isNaN and not b.mismatched(t), "trace " & $t & " modelled at 0"
        doAssert not b.pickOf(t).isNaN
      doAssert b.modelled == Traces - 4, "modelled " & $b.modelled
      doAssert abs(b.modelOf(10) - arrivalMs(offsetOf(10))) <= 8

  block noModelWhenAllPicksShareAnOffset:
    withFixtures fx:
      let path = fx.customShot("same.sgy", Traces, proc (i: int; k: var TraceKeys): float64 =
        k.offset = 1000
        arrivalMs(1000))
      let b = breaksOf(path)
      doAssert b.used >= 3 and b.modelled == 0, "used " & $b.used & " modelled " & $b.modelled
      doAssert not b.hasModel and b.modelNote.len > 0 and b.statusWords.len > 0

  block nodesAreFittedFromOneSensor:
    # unrotated node components are never fitted together: the horizontals here arrive late
    withFixtures fx:
      let vertical = fx.customShot("nodes.sgy", Traces, proc (i: int; k: var TraceKeys): float64 =
        k.traceCode = int16(12 + i mod 3) # vertical, crossline, inline
        if i mod 3 == 0: arrivalMs(k.offset) else: 20 + 0.8 * k.offset)
      var b = breaksOf(vertical)
      doAssert b.fittedFrom == "the vertical traces", "fitted from " & b.fittedFrom
      for t in [0, 3, 30]:
        doAssert abs(b.modelOf(t) - arrivalMs(offsetOf(t))) <= 8, "vertical " & $t
      doAssert abs(b.modelOf(4) - arrivalMs(offsetOf(4))) <= 8, "the model is a function " &
        "of offset: a horizontal trace is given the vertical's"
      doAssert abs(b.pickOf(4) - (20 + 0.8 * offsetOf(4))) <= 12, "its own pick is shown"
      # the panel's filter: the verticals switched off, the next kind in order is fitted
      var f = openSeismic(vertical, keys = true)
      b = breaksOfRecord(addr f, vertical, 0 ..< f.len, [], nil, [12'u8])
      f.close()
      doAssert b.fittedFrom == "the inline traces" or b.fittedFrom == "the crossline traces",
        b.fittedFrom
      # a hydrophone, when there is one
      let hydro = fx.customShot("hydro.sgy", Traces, proc (i: int; k: var TraceKeys): float64 =
        k.traceCode = int16(11 + i mod 3)
        if i mod 3 == 0: arrivalMs(k.offset) else: 20 + 0.8 * k.offset)
      b = breaksOf(hydro)
      doAssert b.fittedFrom == "the hydrophone traces", b.fittedFrom
      doAssert abs(b.modelOf(5) - arrivalMs(offsetOf(5))) <= 8, "model " & $b.modelOf(5)
      doAssert "hydrophone" in b.statusWords, b.statusWords

  block theOverlayIsPerPanelAndOneResultServesBoth:
    withFixtures fx:
      let path = fx.shotSegy("panels.sgy", gHeaderOffset)
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
        st.jobs.active.len == 0)
      let second = st.addPanel()
      st.apply Command(kind: ckShowFile, panel: second, path: path)
      doAssert st.settle(st.panel(second).laidOut and st.jobs.active.len == 0)
      var d = st.panel(MainPanel).layers[0].display
      d.firstBreaks = true
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      doAssert st.breaksOn(MainPanel) and not st.breaksOn(second), "the overlay is not per panel"
      doAssert st.settle(st.firstBreaks.len == 1 and st.firstBreaks[0].state == bkDone and
        st.jobs.active.len == 0)
      doAssert st.breaksIndex(st.findPanel(second)) == 0,
        "the same record's result is not found for the other panel"
      let asked = st.firstBreaks[0].revision
      d.firstBreaks = true
      st.apply Command(kind: ckDisplay, panel: second, display: d)
      doAssert st.breaksOn(second)
      doAssert st.settle(st.jobs.active.len == 0)
      doAssert st.firstBreaks.len == 1 and st.firstBreaks[0].revision == asked,
        "a second panel on the same record made its own job"
      # a display preset does not carry the overlay
      doAssert not asPreset(st.panel(MainPanel).layers[0].display).firstBreaks
      st.shutdown()

  echo "tfirstbreaks: ok"

when isMainModule:
  main()
