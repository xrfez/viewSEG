## A pilot taken from the record: a rule stored in the archive, used for each
## record by its own trace.
##
## Seen to fail: with the rule's trace always taken from the first record, "the
## second record's pilot is the first's"; with the window cut one sample short,
## "the cut is not exact"; with a missing auxiliary trace falling back to the
## first trace, "no sentence for a missing trace"; with the reversal not read
## for the pilot, "a reversed pilot is not turned over"; with the rule stored
## with a file, "a rule has a file".

import std/[json, math, os, strutils]
import parseSEG
import viewSEG/core/[analysis, edits, references, state]
import viewSEG/remote/schema
import utils/[chosenref, fixtures, waiting]

const
  DtMs = 2.0
  Samples = 400
  Delay = 10.0

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func pilotSample(record, i: int): float32 =
  ## Record 1's pilot is 25 Hz, record 2's 40 Hz: they differ everywhere.
  let t = float64(i) * DtMs / 1000
  if t > 0.5: return 0
  float32(sin(2 * PI * (if record == 1: 25.0 else: 40.0) * t))

proc twoRecords(fx: Fixtures): string =
  ## Two records: each an auxiliary pilot of its own, then three seismic traces
  ## that are that pilot, each `Delay` ms later than the one before.
  result = fx.dir / "two-records.sgy"
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test: a pilot of its own in each record"]))
  var buf = newSeq[float32](Samples)
  for r in 1 .. 2:
    for c in 0 .. 3:
      let shift = int(round(float64(c) * Delay / DtMs))
      for i in 0 ..< Samples:
        buf[i] = if i < shift: 0'f32 else: pilotSample(r, i - shift)
      var k = initTraceKeys()
      (k.record, k.channel, k.t0Ms, k.intervalUs) = (float64(r), float64(c + 1), 0.0,
        DtMs * 1000)
      if c == 0: (k.traceCode, k.status) = (6'i16, tsAuxiliary)
      else: k.status = tsLive
      w.writeTrace(k, buf)
  doAssert w.close().len == 0

proc shownPilot(st: var AppState; rule: PilotRule): PilotPreview =
  ## Asks for the pilot of the record on show and waits for the answer.
  doAssert st.settle(st.panel(MainPanel).laidOut), "the record is not laid out"
  st.apply Command(kind: ckPilotPreview, refPilot: rule)
  doAssert st.settle(not st.pilotPreview.waiting and
    (st.pilotPreview.samples.len > 0 or st.pilotPreview.problem.len > 0)),
    "the preview did not arrive"
  st.pilotPreview

proc main*() =
  block the_rule_is_kept_and_has_no_samples:
    withFixtures fx:
      let folder = fx.dir / "refs"
      var index = loadIndex(folder)
      doAssert index.entries.len == 0
      let rule = PilotRule(name: "p aux", aux: true, trace: 2, startMs: 100, spanMs: 400)
      let id = storePilotRule(folder, rule)
      index = loadIndex(folder)
      doAssert index.entries.len == 1 and index.findId(id) == 0
      let e = index.entries[0]
      doAssert e.isPilot and e.file.len == 0, "a rule has a file"
      doAssert not e.missing and not e.blocked and e.samples == 0
      doAssert pilotRuleOf(e) == rule, $pilotRuleOf(e)
      doAssert sourceText(e) == "pilot: auxiliary trace 2", sourceText(e)
      doAssert lengthText(e) == "400 ms (of each record)", lengthText(e)
      doAssert index.problems.len == 0, $index.problems
      doAssertRaises ValueError:
        discard storePilotRule(folder, rule) # the name is taken
      doAssertRaises ValueError:
        discard storePilotRule(folder, PilotRule(name: "bad", aux: true, trace: 0,
          startMs: 0, spanMs: 10))
      doAssertRaises ValueError:
        discard storePilotRule(folder, PilotRule(name: "bad", aux: true, trace: 1,
          startMs: 0, spanMs: 0))
      renameIn(folder, id, "p renamed")
      doAssert loadIndex(folder).entries[0].name == "p renamed"
      let copy = copyInto(folder, fx.dir / "other", id)
      let other = loadIndex(fx.dir / "other")
      doAssert other.entries.len == 1 and pilotRuleOf(other.entries[0]).trace == 2 and
        other.findId(copy) == 0
      doAssert deleteIn(folder, id) == "p renamed"
      doAssert loadIndex(folder).entries.len == 0

  block the_trace_and_the_window:
    let isAux = [true, false, false, true, false]
    doAssert pickPilotTrace(PilotRule(aux: true, trace: 1, spanMs: 1), isAux, "FFID 7").at == 0
    doAssert pickPilotTrace(PilotRule(aux: true, trace: 2, spanMs: 1), isAux, "FFID 7").at == 3
    doAssert pickPilotTrace(PilotRule(aux: false, trace: 5, spanMs: 1), isAux, "FFID 7").at == 4
    let third = pickPilotTrace(PilotRule(aux: true, trace: 3, spanMs: 1), isAux, "FFID 7")
    doAssert third.at == -1 and third.problem ==
      "FFID 7 has only 2 auxiliary traces, not an auxiliary trace 3.", third.problem
    let tenth = pickPilotTrace(PilotRule(aux: false, trace: 9, spanMs: 1), isAux, "record 3")
    doAssert tenth.at == -1 and tenth.problem == "Record 3 has 5 traces, not a trace 9.",
      tenth.problem
    let none = pickPilotTrace(PilotRule(aux: true, trace: 1, spanMs: 1), [false, false],
      "FFID 2")
    doAssert none.problem == "FFID 2 has no auxiliary trace, not an auxiliary trace 1.",
      none.problem
    var s = newSeq[float32](101)
    for i in 0 ..< s.len: s[i] = float32(i)
    let cut = cutPilot(s, 2.0, PilotRule(aux: true, trace: 1, startMs: 20, spanMs: 30), "FFID 7")
    doAssert cut.problem == "" and cut.samples.len == 16 and cut.samples[0] == 10 and
      cut.samples[^1] == 25, "the cut is not exact: " & $cut.samples
    let clipped = cutPilot(s, 2.0, PilotRule(aux: true, trace: 1, startMs: 190, spanMs: 100),
      "FFID 7")
    doAssert clipped.samples.len == 6 and clipped.samples[^1] == 100, $clipped.samples
    let past = cutPilot(s, 2.0, PilotRule(aux: true, trace: 1, startMs: 500, spanMs: 100),
      "FFID 7")
    doAssert past.samples.len == 0 and past.problem ==
      "FFID 7's auxiliary trace 1 ends at 200 ms, so a window from 500 ms holds no sample.",
      past.problem

  withFixtures fx:
    var st = initAppState()
    let path = fx.twoRecords()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    st.readyArchive(fx.dir / "refs")
    let base = st.sessions[0].base
    doAssert st.sessions[0].gathers.len == 2, $st.sessions[0].gathers.len

    block each_record_has_its_own_pilot:
      let first = st.shownPilot(PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 1000))
      doAssert first.problem == "", first.problem
      doAssert first.samples.len == Samples, $first.samples.len
      for i in 0 ..< Samples:
        doAssert first.samples[i] == pilotSample(1, i), "record 1, sample " & $i
      doAssert "1" in first.record, first.record
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
      doAssert st.settle(st.panel(MainPanel).layers[0].source.gather == 1 and
        st.panel(MainPanel).laidOut)
      let second = st.shownPilot(PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 1000))
      doAssert second.problem == "", second.problem
      for i in 0 ..< Samples:
        doAssert second.samples[i] == pilotSample(2, i), "record 2, sample " & $i
      doAssert second.samples != first.samples, "the second record's pilot is the first's"
      doAssert second.record != first.record, second.record
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 0)
      doAssert st.settle(st.panel(MainPanel).layers[0].source.gather == 0)

    block the_window_is_cut_exactly:
      let cut = st.shownPilot(PilotRule(aux: true, trace: 1, startMs: 100, spanMs: 50))
      doAssert cut.samples.len == 26, "the cut is not exact: " & $cut.samples.len & " " & cut.problem
      doAssert cut.samples[0] == pilotSample(1, 50) and cut.samples[25] == pilotSample(1, 75)
      let past = st.shownPilot(PilotRule(aux: true, trace: 1, startMs: 700, spanMs: 1000))
      doAssert past.samples.len == 50 and past.problem == "", past.problem
      doAssert past.samples[^1] == pilotSample(1, Samples - 1)
      let nothing = st.shownPilot(PilotRule(aux: true, trace: 1, startMs: 900, spanMs: 100))
      doAssert nothing.samples.len == 0 and "holds no sample" in nothing.problem and
        "FFID" in nothing.problem, nothing.problem
      let seismic = st.shownPilot(PilotRule(aux: false, trace: 2, startMs: 0, spanMs: 1000))
      doAssert seismic.samples.len == Samples and seismic.samples[0] == 0 and
        seismic.samples[5] == pilotSample(1, 0) # the first copy, shifted by Delay (5 samples)

    block a_missing_trace_is_said:
      let aux2 = st.shownPilot(PilotRule(aux: true, trace: 2, startMs: 0, spanMs: 100))
      doAssert aux2.samples.len == 0 and "has only 1 auxiliary trace, not an auxiliary " &
        "trace 2." in aux2.problem, "no sentence for a missing trace: " & aux2.problem
      let tr9 = st.shownPilot(PilotRule(aux: false, trace: 9, startMs: 0, spanMs: 100))
      doAssert tr9.samples.len == 0 and "has 4 traces, not a trace 9." in tr9.problem,
        tr9.problem

    block reversal_follows_the_plot:
      let rule = PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 1000)
      let plain = st.shownPilot(rule)
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[0],
        on: true)
      let own = st.shownPilot(rule)
      doAssert own.samples.len == plain.samples.len
      for i in 0 ..< own.samples.len:
        doAssert own.samples[i] == -plain.samples[i], "a reversed pilot is not turned over"
      st.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: true)
      let both = st.shownPilot(rule)
      doAssert both.samples == plain.samples, "own and reverse-all together are not a " &
        "single reversal"
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[0],
        on: false)
      let all = st.shownPilot(rule)
      doAssert all.samples[10] == -plain.samples[10], "reverse-all does not turn it over"
      st.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: false)
      doAssert st.shownPilot(rule).samples == plain.samples

    block a_correlation_uses_each_records_pilot:
      st.apply Command(kind: ckPilotReference, refPilot: PilotRule(name: "record pilot",
        aux: true, trace: 1, startMs: 0, spanMs: 1000))
      doAssert st.settle(st.references.entries.len == 1), "the rule was not stored"
      let id = st.references.entries[0].id
      doAssert st.references.entries[0].isPilot
      st.apply Command(kind: ckSelectReference, refId: id)
      st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
        plotTraces: @[base + 1, base + 2, base + 3])
      let w = st.plots.high
      doAssert st.settle(st.plots[w].result.gen > 0 and not st.plots[w].waiting),
        st.plots[w].result.problem
      doAssert st.plots[w].result.problem == "", st.plots[w].result.problem
      doAssert st.plots[w].reference == "record pilot"
      doAssert "record pilot (" in st.plots[w].result.note and
        "auxiliary trace 1" in st.plots[w].result.note, st.plots[w].result.note
      for c in 0 .. 2:
        let lag = st.plots[w].result.peakLagMs(c)
        doAssert abs(lag - Delay * float64(c + 1)) < 1e-6, "record 1, trace " & $(c + 2) &
          " peaks at " & $lag & " ms"
      let asks = st.plots[w].asks
      let noteFirst = st.plots[w].result.note
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
      doAssert st.settle(st.plots[w].asks > asks and not st.plots[w].waiting and
        st.plots[w].result.note != noteFirst), "the window did not follow the record"
      doAssert st.plots[w].result.problem == "", st.plots[w].result.problem
      doAssert st.plots[w].result.plots.len > 0
      let peaks = st.plots[w].result.peakLagMs(0)
      doAssert abs(peaks - Delay) < 1e-6, "record 2 peaks at " & $peaks & " ms"
      # the same traces against the first record's pilot would not peak there as
      # sharply: the note names the record whose pilot was used
      doAssert "FFID 2" in st.plots[w].result.note or "record 2" in st.plots[w].result.note,
        st.plots[w].result.note
      # a frozen window keeps the pilot it showed
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id,
        plotParams: st.plots[w].params, plotFrozen: true)
      let frozenNote = st.plots[w].result.note
      let frozenAsks = st.plots[w].asks
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 0)
      doAssert st.settle(st.panel(MainPanel).layers[0].source.gather == 0)
      doAssert st.plots[w].asks == frozenAsks and st.plots[w].result.note == frozenNote,
        "a frozen window followed the record"

    block a_record_without_the_trace_says_so:
      st.apply Command(kind: ckPilotReference, refPilot: PilotRule(name: "second aux",
        aux: true, trace: 2, startMs: 0, spanMs: 100))
      doAssert st.settle(st.references.entries.len == 2)
      var second = ""
      for e in st.references.entries:
        if e.name == "second aux": second = e.id
      st.apply Command(kind: ckSelectReference, refId: second)
      st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
        plotTraces: @[base + 1, base + 2])
      let w = st.plots.high
      doAssert st.settle(st.plots[w].result.gen > 0 and not st.plots[w].waiting)
      doAssert "has only 1 auxiliary trace, not an auxiliary trace 2." in
        st.plots[w].result.problem, st.plots[w].result.problem
      doAssert st.plots[w].result.plots.len == 0, "a missing trace still drew a curve"

    block the_tool_decodes_a_rule:
      var c = newCommand(ckPilotReference)
      var problems: seq[string] = @[]
      decodeFields(%*{"refPilot": {"name": "agent rule", "aux": true, "trace": 3,
        "startMs": 5, "spanMs": 40}}, c, problems)
      doAssert problems.len == 0, $problems
      doAssert c.refPilot == PilotRule(name: "agent rule", aux: true, trace: 3, startMs: 5,
        spanMs: 40)
    discard st.shutdown()

  echo "tpilotref: ok"

when isMainModule: main()
