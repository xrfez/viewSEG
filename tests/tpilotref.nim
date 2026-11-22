## A pilot taken from the record: a rule stored in the archive, used for each
## record by its own trace.
##
## Seen to fail: with the rule's trace always taken from the first record, "the
## second record's pilot is the first's"; with the window cut one sample short,
## "the cut is not exact"; with a missing auxiliary trace falling back to the
## first trace, "no sentence for a missing trace"; with the reversal not read
## for the pilot, "a reversed pilot is not turned over"; with the rule stored
## with a file, "a rule has a file"; with the note not naming the pilot's own
## filter (the plot's filters off), "the pilot's own filter is not named" (now: a filter
## of its own reaches nothing); with the plot's filters or reverse-all let reach the pilot, "the plot's filters reached the pilot" and
## "reverse-all reached the pilot"; with the rule's phase left out, "a phase of 180 does not
## negate the pilot"; with a store not applying the trace's own reversal or filter, "a
## reversed trace is not stored negated". With the close not clearing the dialog's preview (`closeSession`), "the preview holds
## the closed file's pilot".

import std/[json, math, monotimes, os, sequtils, strutils, times]
import parseSEG
import viewSEG/core/[analysis, edits, processing, references, state]
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

proc chirpRecord(fx: Fixtures): string =
  ## An auxiliary pilot (a 10 to 50 Hz chirp over 0.5 s) and two seismic traces,
  ## the pilot `Delay` and twice `Delay` ms later.
  result = fx.dir / "chirp-record.sgy"
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test: a chirp pilot and two delayed copies"]))
  var buf = newSeq[float32](Samples)
  for c in 0 .. 2:
    let shift = int(round(float64(c) * Delay / DtMs))
    for i in 0 ..< Samples:
      let t = float64(i - shift) * DtMs / 1000
      buf[i] = if i < shift or t > 0.5: 0'f32 else: float32(sin(2 * PI * (10 * t + 40 * t * t)))
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs) = (1.0, float64(c + 1), 0.0, DtMs * 1000)
    if c == 0: (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    else: k.status = tsLive
    w.writeTrace(k, buf)
  doAssert w.close().len == 0

func peakValue(r: AnalysisResult; curve = 0): float64 =
  ## The cross-correlation's value at its peak lag, with its sign.
  result = NaN
  if r.plots.len > 0 and 2 * curve + 1 < r.plots[0].curves.len:
    let e = r.plots[0].curves[2 * curve + 1].ys
    var best = -1
    for i in 0 ..< e.len:
      if not e[i].isNaN and (best < 0 or e[i] > e[best]): best = i
    if best >= 0: result = r.plots[0].curves[2 * curve].ys[best]

proc shownPilot(st: var AppState; rule: PilotRule): PilotPreview =
  ## Asks for the pilot of the record on show and waits for the answer.
  doAssert st.settle(st.panel(MainPanel).laidOut), "the record is not laid out"
  st.apply Command(kind: ckPilotPreview, refPilot: rule)
  doAssert st.settle(not st.pilotPreview.waiting and
    (st.pilotPreview.samples.len > 0 or st.pilotPreview.problem.len > 0)),
    "the preview did not arrive"
  st.pilotPreview

proc main*() =

  block an_old_rule_reads_as_phase_0:
    withFixtures fx2:
      let folder = fx2.dir / "refs-old"
      discard storePilotRule(folder, PilotRule(name: "old", aux: true, trace: 1, spanMs: 100))
      let old = loadIndex(folder)
      doAssert old.entries.len == 1 and pilotRuleOf(old.entries[0]).phaseDeg == 0
      discard storePilotRule(folder, PilotRule(name: "new", aux: true, trace: 1, spanMs: 100,
        phaseDeg: 180))
      let back = loadIndex(folder)
      var got = -1.0
      for e in back.entries:
        if e.name == "new": got = pilotRuleOf(e).phaseDeg
      doAssert got == 180


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
    doAssert cut.problem == "" and cut.samples.len == 15 and cut.samples[0] == 10 and
      cut.samples[^1] == 24, "the cut is not exact: " & $cut.samples
    let clipped = cutPilot(s, 2.0, PilotRule(aux: true, trace: 1, startMs: 190, spanMs: 100),
      "FFID 7")
    doAssert clipped.samples.len == 6 and clipped.samples[^1] == 100, $clipped.samples
    let past = cutPilot(s, 2.0, PilotRule(aux: true, trace: 1, startMs: 500, spanMs: 100),
      "FFID 7")
    let huge = cutPilot(s, 2.0, PilotRule(aux: true, trace: 1, startMs: 190, spanMs: 1e300),
      "FFID 7")
    doAssert huge.problem == "" and huge.samples.len == 6, "a huge length is not clamped: " &
      $huge.samples.len & huge.problem
    let farOff = cutPilot(s, 2.0, PilotRule(aux: true, trace: 1, startMs: 1e300, spanMs: 1e300),
      "FFID 7")
    doAssert farOff.samples.len == 0 and "is past its end" in farOff.problem, farOff.problem
    doAssert past.samples.len == 0 and past.problem ==
      "FFID 7's auxiliary trace 1 ends at 200 ms, so a window from 500 ms is past its end.",
      past.problem

  withFixtures fx:
    var st = initAppState()
    let path = fx.twoRecords()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    st.readyArchive(fx.dir / "refs")
    let base = st.sessions[0].base
    doAssert st.sessions[0].gathers.len == 2, $st.sessions[0].gathers.len

    block the_shown_length_is_n_times_dt:
      # 400 samples at 2 ms are 800 ms (the pilot Length field starts there), not 798.
      doAssert st.shownLengthMs == float64(Samples) * DtMs, $st.shownLengthMs

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
      doAssert cut.samples.len == 25, "the cut is not exact: " & $cut.samples.len & " " & cut.problem
      doAssert cut.samples[0] == pilotSample(1, 50) and cut.samples[24] == pilotSample(1, 74)
      let past = st.shownPilot(PilotRule(aux: true, trace: 1, startMs: 700, spanMs: 1000))
      doAssert past.samples.len == 50 and past.problem == "", past.problem
      doAssert past.samples[^1] == pilotSample(1, Samples - 1)
      let nothing = st.shownPilot(PilotRule(aux: true, trace: 1, startMs: 900, spanMs: 100))
      doAssert nothing.samples.len == 0 and "is past its end" in nothing.problem and
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

    block reversal_is_the_traces_own:
      let rule = PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 1000)
      let plain = st.shownPilot(rule)
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[0],
        on: true)
      let own = st.shownPilot(rule)
      doAssert own.samples.len == plain.samples.len
      for i in 0 ..< own.samples.len:
        doAssert own.samples[i] == -plain.samples[i], "a reversed pilot is not turned over"
      # nothing the plot decides reaches a pilot taken by a rule
      st.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: true)
      doAssert st.shownPilot(rule).samples == own.samples, "reverse-all reached the pilot"
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[0],
        on: false)
      doAssert st.shownPilot(rule).samples == plain.samples, "reverse-all reached the pilot"
      st.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: false)
      doAssert st.shownPilot(rule).samples == plain.samples

    block the_rules_phase_turns_the_cut_over:
      let rule = PilotRule(aux: true, trace: 1, startMs: 100, spanMs: 50)
      let plain = st.shownPilot(rule)
      let turned = st.shownPilot(PilotRule(aux: true, trace: 1, startMs: 100, spanMs: 50,
        phaseDeg: 180))
      doAssert turned.samples.len == plain.samples.len and plain.samples.len == 25
      for i in 0 ..< turned.samples.len:
        doAssert turned.samples[i] == -plain.samples[i], "a phase of 180 does not negate the pilot"
      doAssert "180 deg phase" in turned.note, turned.note
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[0],
        on: true)
      let twice = st.shownPilot(PilotRule(aux: true, trace: 1, startMs: 100, spanMs: 50,
        phaseDeg: 180))
      doAssert twice.samples == plain.samples, "a trace reversed and a phase of 180 are not " &
        "turned twice"
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[0],
        on: false)
      doAssert pilotProblem(PilotRule(aux: true, trace: 1, spanMs: 5, phaseDeg: 90)).len > 0
      doAssert defaultPilotName(PilotRule(aux: true, trace: 1, spanMs: 5, phaseDeg: 180)).endsWith(
        "180 deg phase")

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
        doAssert abs(lag - Delay * float64(c + 1)) < 1.0, "record 1, trace " & $(c + 2) &
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

    block the_window_follows_the_pilots_edits:
      st.apply Command(kind: ckSelectReference, refId: st.references.entries[0].id)
      st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
        plotTraces: @[base + 1, base + 2, base + 3])
      let w = st.plots.high
      doAssert st.settle(st.plots[w].result.gen > 0 and not st.plots[w].waiting)
      let plain = st.plots[w].result.peakValue(0)
      doAssert plain > 0.5, "the peak is not near +1: " & $plain
      proc edited(st: var AppState; w: int; act: proc (st: var AppState)): bool =
        let asks = st.plots[w].asks
        act(st)
        st.settle(st.plots[w].asks > asks and not st.plots[w].waiting)
      doAssert st.edited(w, proc (st: var AppState) =
        st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[base],
          on: true)), "reversing the pilot did not ask again"
      let flipped = st.plots[w].result.peakValue(0)
      doAssert abs(flipped + plain) < 1e-6, "a reversed pilot does not show " & $(-plain) &
        ", it shows " & $flipped
      doAssert st.edited(w, proc (st: var AppState) =
        st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[base],
          on: false))
      doAssert abs(st.plots[w].result.peakValue(0) - plain) < 1e-6
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base],
        on: true)
      doAssert st.settle("is killed." in st.plots[w].result.problem),
        "killing the pilot did not reach the window"
      doAssert "is killed." in st.plots[w].result.problem and
        st.plots[w].result.plots.len == 0, st.plots[w].result.problem
      doAssert st.edited(w, proc (st: var AppState) =
        st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base],
          on: false)), "making the pilot live again did not ask again"
      doAssert st.plots[w].result.plots.len > 0
      # a reference is never filtered: a filter of the pilot's own asks nothing again
      let asksNow = st.plots[w].asks
      st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base], on: true,
        processing: Processing(band: pbBandPass, f1: 4, f2: 8, f3: 12, f4: 16),
        filterPlace: fpAfter)
      for _ in 0 ..< 40:
        discard st.drainInbox()
        sleep(10)
      doAssert st.plots[w].asks == asksNow and abs(st.plots[w].result.peakValue(0) - plain) < 1e-6,
        "a filter of the pilot's own reached the correlation"
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)

    block the_preview_is_what_the_correlation_uses:
      let rule = PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 1000)
      let plain = st.shownPilot(rule)
      let spec = Processing(band: pbBandPass, f1: 4, f2: 8, f3: 12, f4: 16)
      st.apply Command(kind: ckProcessing, panel: MainPanel, processing: spec)
      let off = st.shownPilot(rule)
      doAssert off.samples == plain.samples and off.note.len == 0,
        "the plot's filters reached the pilot: " & off.note
      st.apply Command(kind: ckProcessing, panel: MainPanel,
        processing: Processing(band: pbBandPass, f1: 4, f2: 8, f3: 12, f4: 16, aux: true))
      doAssert st.shownPilot(rule).samples == plain.samples,
        "Filter the Aux traces too reached the pilot"
      st.apply Command(kind: ckProcessing, panel: MainPanel, processing: spec)
      st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base], on: true,
        processing: spec, filterPlace: fpAfter)
      let own = st.shownPilot(rule)
      doAssert own.samples == plain.samples and own.note.len == 0,
        "the pilot's own filter is in the preview"
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      st.apply Command(kind: ckProcessing, panel: MainPanel, processing: Processing())
      doAssert st.shownPilot(rule).samples == plain.samples

    block the_note_says_the_recorded_trace:
      let rule = PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 1000)
      let spec = Processing(band: pbBandPass, f1: 4, f2: 8, f3: 12, f4: 16)
      doAssert st.shownPilot(rule).note.len == 0, "a plain pilot has a note"
      st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base], on: true,
        processing: spec, filterPlace: fpAfter)
      doAssert st.shownPilot(rule).note.len == 0, "a filter of the pilot's own is named"
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[0], on: true)
      doAssert "the recorded trace, reversed" in st.shownPilot(rule).note
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[0], on: false)

    block a_killed_pilot_is_not_used:
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base],
        on: true)
      let dead = st.shownPilot(PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 100))
      doAssert dead.samples.len == 0 and "auxiliary trace 1 is killed." in dead.problem,
        dead.problem
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base],
        on: false)

    block traces_of_two_records_are_refused:
      st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
        plotTraces: @[base + 1, base + 5])
      let w = st.plots.high
      doAssert st.settle(st.plots[w].result.gen > 0 and not st.plots[w].waiting)
      doAssert st.plots[w].result.problem == "These traces come from 2 records; a record's " &
        "pilot needs traces of one record.", st.plots[w].result.problem

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
    block a_stored_trace_is_the_trace_as_set_on_it:
      # Store (and a pilot's fixed copy): the recorded samples, the trace's own reversal,
      # the cut and a phase; no filter of any kind, never reverse-all or gain
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 0)
      doAssert st.settle(st.panel(MainPanel).layers[0].source.gather == 0 and
        st.panel(MainPanel).laidOut)
      var n = st.references.entries.len
      proc stored(st: var AppState; n: var int; trace: int; phase = 0.0): seq[float32] =
        let name = "stored " & $n
        st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: name,
          trace: trace, fromMs: 0, toMs: -1, phaseDeg: phase))
        doAssert st.settle(st.references.entries.len == n + 1), "not stored: " &
          st.log[st.log.len - 1].text
        inc n
        for e in st.references.entries:
          if e.name == name:
            var f = openSeismic(st.referencesHome / e.file, keys = true)
            let rows = f.readTraces(0 .. 0)
            result = newSeq[float32](rows.shape[1])
            for i in 0 ..< result.len: result[i] = rows[0, i]
            f.close()
        doAssert result.len > 0
      let raw = st.stored(n, base)
      for i in 0 ..< Samples: doAssert raw[i] == pilotSample(1, i), "stored is not the file's"
      st.apply Command(kind: ckProcessing, panel: MainPanel, processing: Processing(aux: true,
        band: pbBandPass, f1: 4, f2: 8, f3: 12, f4: 16))
      st.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: true)
      doAssert st.stored(n, base) == raw, "the plot's filters or reverse-all reached what is stored"
      st.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: false)
      st.apply Command(kind: ckProcessing, panel: MainPanel, processing: Processing())
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[base], on: true)
      let flipped = st.stored(n, base)
      for i in 0 ..< Samples:
        doAssert flipped[i] == -raw[i], "a reversed trace is not stored negated"
      let rule = PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 1000, phaseDeg: 180)
      let fixed = st.stored(n, base, 180)
      doAssert fixed == raw, "a reversed trace with a phase of 180 is not stored as recorded"
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[base], on: false)
      let spec = Processing(band: pbBandPass, f1: 4, f2: 8, f3: 12, f4: 16)
      st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base], on: true,
        processing: spec, filterPlace: fpAfter)
      let filteredOwn = st.stored(n, base)
      doAssert filteredOwn == raw, "a trace's own filter reached what is stored"
      let fixedPhase = st.stored(n, base, 180)
      doAssert fixedPhase == raw.mapIt(-it)
      doAssert st.shownPilot(rule).samples == fixedPhase,
        "the pilot's fixed copy is not the rule's pilot, sample for sample"
      doAssert st.shownPilot(PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 1000)).samples ==
        filteredOwn
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      # a killed trace is refused
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base], on: true)
      let count = st.references.entries.len
      st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "no",
        trace: base, fromMs: 0, toMs: -1))
      doAssert "killed" in st.log[st.log.len - 1].text, st.log[st.log.len - 1].text
      doAssert st.references.entries.len == count
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base], on: false)

    block a_correlation_with_phase_180_flips_sign:
      st.apply Command(kind: ckPilotReference, refPilot: PilotRule(name: "turned pilot",
        aux: true, trace: 1, startMs: 0, spanMs: 1000, phaseDeg: 180))
      doAssert st.settle(st.references.entries.anyIt(it.name == "turned pilot"))
      var turned = ""
      var plainId = ""
      for e in st.references.entries:
        if e.name == "turned pilot": turned = e.id
        if e.name == "record pilot": plainId = e.id
      doAssert st.references.entries.anyIt(it.id == turned and it.origin.pilotPhaseDeg == 180 and
        sourceText(it).endsWith("180 deg phase"))
      st.apply Command(kind: ckSelectReference, refId: plainId)
      st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
        plotTraces: @[base + 1, base + 2, base + 3])
      let w1 = st.plots.high
      doAssert st.settle(st.plots[w1].result.gen > 0 and not st.plots[w1].waiting)
      let plain = st.plots[w1].result.peakValue(0)
      st.apply Command(kind: ckSelectReference, refId: turned)
      st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
        plotTraces: @[base + 1, base + 2, base + 3])
      let w2 = st.plots.high
      doAssert st.settle(st.plots[w2].result.gen > 0 and not st.plots[w2].waiting)
      doAssert abs(st.plots[w2].result.peakValue(0) + plain) < 1e-6 and plain > 0.5,
        "a phase of 180 did not flip the correlation: " & $plain & " and " &
        $st.plots[w2].result.peakValue(0)

    block closing_the_file_releases_its_pilot:
      # Before this was handled the dialog's preview, a reference's View window and the
      # correlation against the rule went on showing the closed file's pilot.
      var turned = ""
      for e in st.references.entries:
        if e.name == "turned pilot": turned = e.id
      let rule = PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 1000)
      doAssert st.shownPilot(rule).samples.len == Samples
      st.apply Command(kind: ckViewReference, refId: turned)
      let view = st.refViews.high
      doAssert st.settle(st.refViews[view].ys.len > 0 and not st.refViews[view].waiting)
      let free = st.plots.high # the unfrozen correlation against the rule
      doAssert not st.plots[free].frozen and st.plots[free].result.plots.len > 0
      var frozen = -1
      for k, p in st.plots:
        if p.frozen and p.result.plots.len > 0: frozen = k
      doAssert frozen >= 0, "no frozen window to keep what it showed"
      let keptCurves = st.plots[frozen].result.plots.len
      # a rule whose read FAILS (a window from 900 ms of a 800 ms trace), closed over at once:
      # the late failure must not land in the window of the closed file
      st.apply Command(kind: ckPilotReference, refPilot: PilotRule(name: "failing pilot",
        aux: true, trace: 1, startMs: 700, spanMs: 100))
      doAssert st.settle(st.references.entries.anyIt(it.name == "failing pilot"))
      var failingId = ""
      for e in st.references.entries:
        if e.name == "failing pilot": failingId = e.id
      st.apply Command(kind: ckViewReference, refId: failingId)
      let failing = st.refViews.high
      st.apply Command(kind: ckClose, file: st.sessions[0].id)
      doAssert st.settle(st.sessions.len == 0)
      for _ in 0 ..< 30:
        discard st.drainInbox()
        sleep(10)
      doAssert st.refViews[failing].note == NoFilePilot and st.refViews[failing].ys.len == 0,
        "a late failure landed in the window of the closed file: " & st.refViews[failing].note
      doAssert st.pilotPreview.samples.len == 0 and st.pilotPreview.hz.len == 0 and
        st.pilotPreview.problem == NoFilePilot, "the preview holds the closed file's pilot"
      doAssert st.refViews[view].ys.len == 0 and st.refViews[view].amps.len == 0 and
        st.refViews[view].pilotTrace < 0 and st.refViews[view].note == NoFilePilot,
        "the View window shows the closed file's pilot"
      doAssert st.plots[free].result.plots.len == 0 and st.plots[free].result.problem ==
          NoFilePilot,
        "the correlation shows the closed file's pilot: " & st.plots[free].result.problem
      doAssert st.plots[frozen].result.plots.len == keptCurves, "a frozen window lost what it showed"
      doAssert st.references.entries.anyIt(it.id == turned), "the rule left the archive"
      # another file: the rule gives that file's pilot
      withFixtures fx3:
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx3.chirpRecord())
        doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
        let again = st.shownPilot(rule)
        doAssert again.problem == "" and again.samples.len == Samples, again.problem
        # the View windows pick up the next file's pilot
        doAssert st.settle(st.refViews[view].ys.len > 0 and not st.refViews[view].waiting),
          "the View window did not take the next file's pilot"
        doAssert st.refViews[view].note.len == 0
        # it follows the pilot trace's own reversal, and the fixed copy is what it shows
        let shown = st.refViews[view].ys
        let b2 = st.sessions[0].base
        st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[b2],
          on: true)
        doAssert st.settle(st.refViews[view].ys.len == shown.len and
          st.refViews[view].ys[5] == -shown[5] and not st.refViews[view].waiting),
          "the View window did not follow the trace's reversal"
        let w = st.refViews[view]
        let n0 = st.references.entries.len
        st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "fixed copy",
          trace: w.pilotTrace, fromMs: w.pilotFrom, toMs: w.pilotTo, phaseDeg: w.pilot.phaseDeg))
        doAssert st.settle(st.references.entries.len == n0 + 1)
        for e in st.references.entries:
          if e.name == "fixed copy":
            var f = openSeismic(st.referencesHome / e.file, keys = true)
            let rows = f.readTraces(0 .. 0)
            doAssert rows.shape[1] == w.ys.len
            for i in 0 ..< w.ys.len:
              doAssert float64(rows[0, i]) == w.ys[i], "the fixed copy is not the window's pilot"
            f.close()

    discard st.shutdown()

  block a_cut_pilot_keeps_its_place_in_time:
    # a pilot cut from 20 ms is the pilot from there, not placed at the trace's
    # first sample: the delays are still read as the delays
    withFixtures fx:
      var g = initAppState()
      g.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.chirpRecord())
      doAssert g.settle(g.sessions.len == 1 and g.panel(MainPanel).laidOut)
      let base = g.sessions[0].base
      g.readyArchive(fx.dir / "refs-chirp")
      g.apply Command(kind: ckPilotReference, refPilot: PilotRule(name: "late pilot",
        aux: true, trace: 1, startMs: 20, spanMs: 400))
      doAssert g.settle(g.references.entries.len == 1), "the rule was not stored"
      g.apply Command(kind: ckSelectReference, refId: g.references.entries[0].id)
      g.apply Command(kind: ckOpenPlot, plotView: avCorrelation, plotTraces: @[base + 1, base + 2])
      doAssert g.settle(g.plots[0].result.gen > 0 and not g.plots[0].waiting)
      doAssert g.plots[0].result.problem == "", g.plots[0].result.problem
      for c in 0 .. 1:
        let lag = g.plots[0].result.peakLagMs(c)
        doAssert abs(lag - Delay * float64(c + 1)) < 1.0, "a cut pilot put at the trace's " &
          "start: trace " & $(c + 2) & " peaks at " & $lag & " ms"
      doAssert "taken to start with the trace" in g.plots[0].result.note
      discard g.shutdown()

  echo "tpilotref: ok"

when isMainModule: main()
