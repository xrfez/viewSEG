## A cross-correlation uses only the reference chosen in References.
##
## A known delay against the stored pilot peaks at that lag. None chosen,
## a deleted choice, and a different sample interval each say so and draw
## no curve. An old window state that still names a `reference` trace loads;
## the field is ignored. Changing the choice redraws an open correlation
## that is not frozen, and a frozen one keeps what it showed.
##
## The correlation's words (titles, a line per trace, the reference's own trace said so
## and not drawn, a table of several traces, the shift in words) are checked in
## `says_what_it_shows` and `shift_in_words`; with the sign of the shift's words
## swapped, "trace 2: best match 1.00 at +10.0 ms (arrives 10.0 ms after the
## reference)" was not in the note.
##
## Seen to fail: with no refusal when none is chosen (`correlationBlock`
## returned no problem), `askPlot` indexed the archive at -1
## ("index -1 not in 0 .. 0"). With `followPlots` discarding a failed
## `askPlot` after the file was closed, "old curves remained after another
## reference". With the interval gate reading `traces[0]` though it was
## killed or dead, "a killed first trace was refused" and "a dead first
## trace was refused". With the deletion log saying the choice is the
## file's own pilot, "the deletion log still claims the file's pilot". With
## the none sentence still "No reference is chosen.", "none does not say to
## choose one". With `carryOver` asking a frozen correlation again, "a frozen
## correlation was asked again".

import std/[json, math, os, sequtils, strutils]
import parseSEG
import viewSEG/core/[analysis, references, state]
import viewSEG/remote/schema
import utils/[chosenref, fixtures, waiting]

const
  DtMs = 2.0
  Samples = 400
  Delay = 10.0

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc answered(st: AppState; w: int): bool =
  st.plots.len > w and st.plots[w].result.gen > 0 and not st.plots[w].waiting

func sweep(i: int): float32 =
  let t = float64(i) * DtMs / 1000
  if t > 0.6: return 0
  float32(sin(2 * PI * 25 * t))

proc twoIntervals(fx: Fixtures; deadFirst: bool): string =
  ## Trace 1 at 4 ms (dead, or live so a test can kill it) and trace 2 at
  ## 2 ms. The reference is stored from trace 2.
  result = fx.dir / (if deadFirst: "dead-first.sgy" else: "kill-first.sgy")
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test: 4 ms then 2 ms"]))
  var buf4 = newSeq[float32](80)
  var buf2 = newSeq[float32](160)
  for i in 0 ..< buf2.len:
    let t = float64(i) * 2.0 / 1000
    buf2[i] = if t > 0.25: 0'f32 else: float32(sin(2 * PI * 30 * t))
  var k = initTraceKeys()
  (k.record, k.channel, k.t0Ms, k.intervalUs) = (1.0, 1.0, 0.0, 4000.0)
  k.status = if deadFirst: tsDead else: tsLive
  w.writeTrace(k, buf4)
  (k.record, k.channel, k.t0Ms, k.intervalUs) = (1.0, 2.0, 0.0, 2000.0)
  k.status = tsLive
  w.writeTrace(k, buf2)
  doAssert w.close().len == 0

proc delayed(fx: Fixtures): string =
  ## A pilot and four copies, each `Delay` ms later than the one before.
  result = fx.dir / "delayed.sgy"
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test: a pilot and delayed copies"]))
  var buf = newSeq[float32](Samples)
  for c in 0 .. 4:
    let shift = int(round(float64(c) * Delay / DtMs))
    for i in 0 ..< Samples:
      buf[i] = if i < shift: 0'f32 else: sweep(i - shift)
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs) = (1.0, float64(c + 1), 0.0, DtMs * 1000)
    if c == 0: (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    else: k.status = tsLive
    w.writeTrace(k, buf)
  doAssert w.close().len == 0

proc openCorr(st: var AppState; traces: seq[int]): int =
  st.apply Command(kind: ckOpenPlot, plotView: avCorrelation, plotTraces: traces)
  result = st.plots.high
  doAssert st.settle(st.answered(result)), "no answer: " & st.plots[result].result.problem

proc main*() =
  withFixtures fx:
    var st = initAppState()
    let path = fx.delayed()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let base = st.sessions[0].base
    let id = st.chooseStored(fx.dir / "refs", base, "the pilot")

    block known_delay:
      let w = st.openCorr(@[base + 1, base + 2, base + 3, base + 4])
      let r = st.plots[w].result
      doAssert r.problem == "" and r.plots.len > 0, r.problem
      doAssert st.plots[w].reference == "the pilot", st.plots[w].reference
      for c in 0 .. 3:
        let lag = r.peakLagMs(c)
        doAssert abs(lag - Delay * float64(c + 1)) < 1e-6, "trace " & $(c + 2) &
          " peaks at " & $lag & " ms"

    block says_what_it_shows:
      # The words: titles that say what is compared, a line per trace (its best
      # match, its shift in words), the reference's own trace said so and not
      # drawn beside others, a table of several traces.
      let w = st.openCorr(@[base, base + 1, base + 2, base + 3])
      let r = st.plots[w].result
      doAssert r.problem == "", r.problem
      doAssert r.plots[0].title.startsWith("How well each trace matches ") and
        r.plots[0].title.endsWith(", by time shift"), r.plots[0].title
      doAssert r.plots[0].xLabel == "Time shift (ms)" and
        r.plots[0].yLabel == "Match (1 = identical shape)"
      doAssert r.plots[1].title == "Amplitude compared with the reference, by frequency"
      doAssert r.plots[2].title == "Phase compared with the reference, by frequency"
      doAssert r.plots[0].curves.len == 6, "the reference's own trace is drawn beside others: " &
        $r.plots[0].curves.len
      doAssert "A peak near 1 at 0 ms means the trace has the reference's shape and timing. " &
        "A lower peak means a different shape; a peak away from 0 means a time shift." in r.note
      doAssert "trace 1 is the reference: compared with itself it matches exactly " &
        "(1.00 at 0 ms)" in r.note, r.note
      doAssert "trace 2: best match 1.00 at +10.0 ms (arrives 10.0 ms after the reference)" in
        r.note, r.note
      doAssert "trace 3: best match 1.00 at +20.0 ms (arrives 20.0 ms after the reference)" in
        r.note, r.note
      doAssert "peaks at" notin r.note and "autocorrelation" notin r.note
      doAssert r.table.len == 5 and r.table[0] == @["Trace", "Best match", "Time shift (ms)",
        "Amplitude (dB)", "Phase (°)"], $r.table
      doAssert r.table[1][0] == "trace 1 (the reference)" and r.table[1][3] == "not drawn" and
        r.table[1][4] == "not drawn", $r.table[1]
      doAssert r.table[2][0] == "trace 2" and r.table[2][2] == "+10.0", $r.table[2]
      # the reference alone is drawn
      let alone = st.openCorr(@[base])
      doAssert st.plots[alone].result.plots[0].curves.len == 2
      doAssert "trace 1 is the reference" in st.plots[alone].result.note

    block shift_in_words:
      # in step whatever the amplitude, and ahead of the reference (before it; a few samples of its start are lost: 0.99)
      var reference, early, loud: seq[float32] = @[]
      for i in 0 ..< Samples:
        reference.add sweep(i)
        early.add sweep(i + 5)
        loud.add 3 * sweep(i)
      let r = correlationOf([("loud", loud), ("early", early)], reference, "ref", DtMs,
        AnalysisParams())
      doAssert r.problem == "", r.problem
      doAssert "loud: best match 1.00 at 0.0 ms (in step with the reference)" in r.note,
        r.note
      doAssert "early: best match 0.99 at -10.0 ms (arrives 10.0 ms before the reference)" in
        r.note, r.note

    block none_chosen:
      st.apply Command(kind: ckSelectReference, refId: "")
      let w = st.openCorr(@[base + 1])
      doAssert st.plots[w].result.problem == NoReferenceChosen, st.plots[w].result.problem
      doAssert st.plots[w].result.plots.len == 0, "none chosen still drew a curve"
      st.apply Command(kind: ckSelectReference, refId: id)

    block deleted:
      let free = st.openCorr(@[base + 1])
      let held = st.openCorr(@[base + 2])
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[held].id,
        plotParams: st.plots[held].params, plotFrozen: true)
      doAssert st.settle(not st.plots[held].waiting)
      let heldCurve = st.plots[held].result.plots[0].curves[0].ys
      let heldAsks = st.plots[held].asks
      st.apply Command(kind: ckDeleteReference, refId: id)
      doAssert st.settle(st.chosenReference.len == 0 and st.plots[free].result.problem ==
        referenceGone("the pilot")), st.plots[free].result.problem
      doAssert st.plots[free].result.plots.len == 0, "a deleted reference still drew"
      doAssert st.plots[held].asks == heldAsks, "a frozen correlation followed the deletion"
      doAssert st.plots[held].result.plots[0].curves[0].ys == heldCurve,
        "a frozen correlation changed its curve"

    block other_interval:
      var g = GeneratedReference(name: "other interval", law: rlLinear, f1Hz: 8, f2Hz: 40,
        durationMs: 200, dtMs: DtMs * 2, amplitude: 1)
      st.apply Command(kind: ckGenerateReference, refGenerate: g)
      doAssert st.settle(st.references.entries.len >= 1), st.log[st.log.len - 1].text
      var other = ""
      for e in st.references.entries:
        if e.name == "other interval": other = e.id
      doAssert other.len > 0
      st.apply Command(kind: ckSelectReference, refId: other)
      let w = st.openCorr(@[base + 1])
      doAssert st.plots[w].result.problem.find("the reference is ") >= 0 and
        st.plots[w].result.problem.find("this file is ") >= 0, st.plots[w].result.problem
      doAssert st.plots[w].result.plots.len == 0, "a different interval was drawn"

    block envelope_takes_the_same_reference:
      # An envelope window uses the reference the correlation does: a trace
      # against the pilot it was stored from is 0; with none chosen, or one at
      # another interval (said), its own phase.
      let again = st.chooseStored(fx.dir / "refs", base, "the pilot again")
      proc openEnvelope(st: var AppState; trace: int): int =
        st.apply Command(kind: ckOpenPlot, plotView: avEnvelope, plotTraces: @[trace])
        result = st.plots.high
        doAssert st.settle(st.answered(result)), "no answer: " & st.plots[result].result.problem
      let w = st.openEnvelope(base)
      doAssert st.plots[w].reference == "the pilot again", st.plots[w].reference
      doAssert st.plots[w].result.plots[1].title == "Phase against the reference"
      for y in st.plots[w].result.plots[1].curves[0].ys:
        doAssert y.isNaN or y == 0.0, "the pilot against itself is " & $y
      let moved = st.openEnvelope(base + 2)
      doAssert st.plots[moved].result.plots[1].title == "Phase against the reference"
      # the difference is not the trace's own phase
      let own = st.plots[moved].result.plots[1].curves[0].ys
      var nonZero = 0
      for y in own:
        if not y.isNaN and y != 0.0: inc nonZero
      doAssert nonZero > 10, "a delayed copy against the pilot is 0 everywhere"
      # asked "Of the trace itself", it is the trace's own, with no reference named
      var params = st.plots[moved].params
      params.phaseAgainst = paSelf
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[moved].id, plotParams: params)
      doAssert st.settle(st.answered(moved)), "no answer"
      doAssert st.plots[moved].result.plots[1].title == "Instantaneous phase of the trace"
      # none chosen: its own phase, and nothing said about a reference not used
      st.apply Command(kind: ckSelectReference, refId: "")
      doAssert st.settle(st.answered(w)), "no answer"
      doAssert st.plots[w].result.plots[1].title == "Instantaneous phase of the trace"
      doAssert "not used" notin st.plots[w].result.note, st.plots[w].result.note
      doAssert st.plots[w].result.problem == "" and st.plots[w].reference == ""
      # another interval: the same words as the correlation's, its own phase
      var g = GeneratedReference(name: "envelope interval", law: rlLinear, f1Hz: 8, f2Hz: 40,
        durationMs: 200, dtMs: DtMs * 2, amplitude: 1)
      st.apply Command(kind: ckGenerateReference, refGenerate: g)
      doAssert st.settle(st.references.entries.anyIt(it.name == "envelope interval"))
      var other = ""
      for e in st.references.entries:
        if e.name == "envelope interval": other = e.id
      st.apply Command(kind: ckSelectReference, refId: other)
      doAssert st.settle(st.answered(w) and "not used" in st.plots[w].result.note),
        st.plots[w].result.note
      doAssert "the reference is " in st.plots[w].result.note and
        "this file is " in st.plots[w].result.note, st.plots[w].result.note
      doAssert st.plots[w].result.plots[1].title == "Instantaneous phase of the trace"
      st.apply Command(kind: ckSelectReference, refId: again)

    block old_window_state:
      var problems: seq[string] = @[]
      var c = newCommand(ckPlotDisplay)
      decodeFields(parseJson("""{"kind":"plot display","plot":1,"plotParams":{
        "maxLagMs":120,"reference":7,"roles":{"reference":1}}}"""), c, problems)
      doAssert problems.len == 0, $problems
      doAssert c.plotParams.maxLagMs == 120 and c.plotParams.roles.reference == 1
      let params = toJson(c.plotParams)
      doAssert "reference" notin params, $params
    discard st.shutdown()

  block closed_file_drops_the_old_curves:
    # Correlate, close the file, choose another reference or none: the old
    # curves and the old reference name must not remain. A frozen window
    # keeps its picture. Showing the file again draws with the choice.
    withFixtures fx:
      var st = initAppState()
      let path = fx.delayed()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let base = st.sessions[0].base
      let id = st.chooseStored(fx.dir / "refs", base, "the pilot")
      var g = GeneratedReference(name: "other pilot", law: rlLinear, f1Hz: 8, f2Hz: 40,
        durationMs: 200, dtMs: DtMs, amplitude: 1)
      st.apply Command(kind: ckGenerateReference, refGenerate: g)
      doAssert st.settle(st.references.entries.len >= 2), st.log[st.log.len - 1].text
      var other = ""
      for e in st.references.entries:
        if e.name == "other pilot": other = e.id
      doAssert other.len > 0, "the second reference was not stored"
      st.apply Command(kind: ckSelectReference, refId: id)
      let free = st.openCorr(@[base + 1])
      let held = st.openCorr(@[base + 2])
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[held].id,
        plotParams: st.plots[held].params, plotFrozen: true)
      doAssert st.settle(not st.plots[held].waiting and st.plots[free].result.plots.len > 0)
      let heldCurve = st.plots[held].result.plots[0].curves[0].ys
      let heldAsks = st.plots[held].asks
      let heldName = st.plots[held].reference
      st.apply Command(kind: ckClose, file: st.sessions[0].id)
      doAssert st.settle(st.sessions.len == 0), "the file did not close"
      doAssert st.plots[free].result.plots.len > 0, "close already cleared the curves"
      st.apply Command(kind: ckSelectReference, refId: other)
      doAssert st.plots[free].result.plots.len == 0,
        "old curves remained after another reference"
      doAssert st.plots[free].reference == "other pilot", st.plots[free].reference
      doAssert st.plots[held].asks == heldAsks, "a frozen window followed a closed file"
      doAssert st.plots[held].result.plots[0].curves[0].ys == heldCurve
      doAssert st.plots[held].reference == heldName, st.plots[held].reference
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and not st.plots[free].waiting and
        st.plots[free].result.plots.len > 0), "showing the file again did not draw: " &
        st.plots[free].result.problem
      st.apply Command(kind: ckClose, file: st.sessions[0].id)
      doAssert st.settle(st.sessions.len == 0)
      st.apply Command(kind: ckSelectReference, refId: "")
      doAssert st.plots[free].result.problem == NoReferenceChosen, st.plots[free].result.problem
      doAssert st.plots[free].result.plots.len == 0, "none chosen left the old curves"
      doAssert st.plots[free].reference.len == 0, st.plots[free].reference
      doAssert st.plots[held].result.plots[0].curves[0].ys == heldCurve,
        "a frozen window changed after the file was closed"
      discard st.shutdown()

  block first_kept_trace_sets_the_interval:
    # The reader skips a killed or dead trace and uses the next one's
    # interval. The gate must do the same, or a live trace at the
    # reference's interval is refused.
    proc check(deadFirst: bool; why: string) =
      withFixtures fx:
        var st = initAppState()
        let path = fx.twoIntervals(deadFirst)
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
        doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut), why
        let base = st.sessions[0].base
        discard st.chooseStored(fx.dir / "refs", base + 1, "two ms")
        if not deadFirst:
          st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
            edited: @[base], on: true)
        let w = st.openCorr(@[base, base + 1])
        doAssert "the reference is " notin st.plots[w].result.problem, why & ": " &
          st.plots[w].result.problem
        doAssert st.plots[w].result.plots.len > 0, why & " drew nothing"
        doAssert st.plots[w].result.leftOut == 1, why & ": left out " &
          $st.plots[w].result.leftOut
        let lag = st.plots[w].result.peakLagMs(0)
        doAssert abs(lag) < 1e-6, why & " peaks at " & $lag & " ms"
        discard st.shutdown()
    check(false, "a killed first trace was refused")
    check(true, "a dead first trace was refused")

  block deleted_choice_does_not_claim_the_pilot:
    # Deleting the choice must not say a correlation then uses the file's
    # pilot. The log uses the none sentence. A vibrator note may keep the
    # pilot clause.
    withFixtures fx:
      var st = initAppState()
      let path = fx.delayed()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let base = st.sessions[0].base
      let id = st.chooseStored(fx.dir / "refs", base, "the pilot")
      let free = st.openCorr(@[base + 1])
      st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[base])
      let vib = st.plots.high
      doAssert st.plots[vib].view == avVibrator
      st.apply Command(kind: ckDeleteReference, refId: id)
      doAssert st.settle(st.chosenReference.len == 0 and st.plots[free].result.plots.len == 0),
        st.plots[free].result.problem
      var said = false
      for e in st.log:
        if "\"the pilot\"" in e.text and "no longer in the archive" in e.text:
          said = true
          doAssert "No reference is chosen. Choose one in References." in e.text, e.text
          doAssert "The choice is the file's own pilot." notin e.text,
            "the deletion log still claims the file's pilot: " & e.text
      doAssert said, "the deletion was not logged"
      doAssert "file's own pilot" in st.plots[vib].goneNote, st.plots[vib].goneNote
      discard st.shutdown()

  block none_says_choose_one:
    # None is the choice's name. A correlation says to choose one in
    # References, and so does the log and the guide.
    const ChooseOne = "No reference is chosen. Choose one in References."
    doAssert NoReferenceChosen == ChooseOne, "none does not say to choose one: " &
      NoReferenceChosen
    doAssert NoneChoiceLabel == "None", NoneChoiceLabel
    doAssert "Vibrator plots then use the file's own pilot" in NoneChoiceTip, NoneChoiceTip
    doAssert "A correlation needs a chosen reference" in NoneChoiceTip, NoneChoiceTip
    let root = currentSourcePath().parentDir.parentDir
    let guide = readFile(root / "docs/user/references.md")
    doAssert ChooseOne in guide, "the guide does not say to choose one"
    doAssert "**None**" in guide, "the guide still calls none From the file"
    doAssert "From the file" notin guide
    doAssert "Vibrator plots then use the file's own pilot" in guide
    let plotDoc = readFile(root / "docs/plot-window.md")
    doAssert ChooseOne in plotDoc, "the plot guide does not say to choose one"
    let ui = readFile(root / "src/viewSEG/ui/imgui/references.nim")
    doAssert "From the file" notin ui, "the none control is still From the file"
    doAssert "NoneChoiceLabel" in ui and "NoneChoiceTip" in ui, "the control does not use None"
    withFixtures fx:
      var st = initAppState()
      st.readyArchive(fx.dir / "refs")
      doAssert st.settle(st.referencesLoaded)
      st.apply Command(kind: ckSelectReference, refId: "")
      var said = false
      for e in st.log:
        if e.text == ChooseOne: said = true
      doAssert said, "choosing none did not say to choose one"
      discard st.shutdown()

  block frozen_reopen_keeps_the_picture:
    # Reopen with options shifts the trace ids. A frozen correlation keeps
    # the picture it had; one that is not frozen is asked again.
    withFixtures fx:
      var st = initAppState()
      let path = fx.delayed()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let base = st.sessions[0].base
      discard st.chooseStored(fx.dir / "refs", base, "the pilot")
      let free = st.openCorr(@[base + 2])
      let held = st.openCorr(@[base + 1])
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[held].id,
        plotParams: st.plots[held].params, plotFrozen: true)
      doAssert st.settle(not st.plots[held].waiting and st.plots[held].result.plots.len > 0 and
        st.plots[free].result.plots.len > 0)
      let heldCurve = st.plots[held].result.plots[0].curves[0].ys
      let heldAsks = st.plots[held].asks
      let heldGen = st.plots[held].result.gen
      let freeAsks = st.plots[free].asks
      st.apply Command(kind: ckReopen, reopenPath: path,
        openChoice: OpenChoice(verifyAll: true))
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].base != base and
        not st.plots[held].waiting and not st.plots[free].waiting), "not reopened"
      doAssert st.plots[held].frozen
      doAssert st.plots[held].asks == heldAsks, "a frozen correlation was asked again"
      doAssert st.plots[held].result.gen == heldGen, "a frozen correlation was answered again"
      doAssert st.plots[held].result.plots[0].curves[0].ys == heldCurve,
        "a frozen correlation changed its curve"
      doAssert st.plots[held].traces[0] == st.sessions[0].base + 1,
        "the frozen window kept the old ids: " & $st.plots[held].traces
      doAssert st.plots[free].asks > freeAsks, "an unfrozen correlation was not asked again"
      discard st.shutdown()
  echo "tcorrref: ok"

when isMainModule: main()
