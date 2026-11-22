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
## kept: the newer key's entry was filled by the older job's".

import std/[math, os, strutils]
import parseSEG
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
