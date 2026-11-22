## The recording filter of a generated reference: typed filter parameters, the
## filtered and shifted samples (processSEG's), the archive entry, the agent's
## `filter` field. None is today's sweep, bit for bit. A reference stored from a
## record is never filtered (nothing here touches that path).
##
## Seen to fail: with `generateSamples` ignoring the filter, "a linear-phase filter
## changed nothing"; with the filter left out of `generateSettingsKey`, "the settings key
## ignores the filter"; with `writeFilter` dropping `shiftTyped`, "the typed shift was
## lost"; with the shift's sign flipped in `recordingFilter`, "the stored reference is not
## the filtered sweep".

import std/[json, math, os, strutils, times]
import processSEG/vibroseis/[pilot, recfilter, sweep, taper]
import viewSEG/core/[references, state, threads]
import viewSEG/remote/schema
import utils/[chosenref, fixtures, waiting]

proc raw(dt: float64): GeneratedReference =
  GeneratedReference(law: rlLinear, f1Hz: 6, f2Hz: 200, durationMs: 12000, dtMs: dt,
    taperStartMs: 250, taperEndMs: 250, amplitude: 1, taperShape: tpCos2)

proc minimum(fc: float64; order, shift: int): RefFilter =
  RefFilter(kind: rfMinimum, family: rfButterworth, highCutHz: fc, highOrder: order,
    shiftSamples: shift, shiftTyped: true)

var readBack: seq[float32] # filled by `readStored`'s thread

proc readStored(path: string): seq[float32] =
  ## A stored reference's samples, read on a worker thread as the program does.
  var t: Thread[string]
  proc look(p: string) {.thread.} =
    markWorkerThread()
    {.cast(gcsafe).}:
      readBack = readReferenceFile(p).samples
  createThread(t, look, path)
  joinThread(t)
  result = readBack

proc main*() =
  block none_is_today:
    for dt in [1.0, 2.0]:
      let g = raw(dt)
      let hand = linearSweep(6, 200, 12000, dt, initSweepTaper(250, 250),
        amplitude = 1.0).sweepSamples(float32)
      doAssert generateSamples(g) == hand, "None changed the sweep"
      doAssert RefFilter().kind == rfNone and not RefFilter().filterOn
      doAssert generateSettingsKey(g) == generateSettingsKey(raw(dt))
      doAssert defaultGenerateName(g) == "Linear 6-200 Hz 12 s"

  block each_kind_is_the_processSEG_call:
    for dt in [1.0, 2.0]:
      var g = raw(dt)
      let plain = generateSamples(g)
      g.filter = minimum(100, 6, 2)
      let got = generateSamples(g)
      doAssert got.len == plain.len and got.len == int(12000 / dt)
      let want = initPilot(plain, dt).applyRecordingFilter(RecordingFilter(
        kind: rfkMinimumPhase, family: rffButterworth, highCutHz: 100, highOrder: 6,
        shiftSamples: 2)).samples
      doAssert got == want, "the stored reference is not the filtered sweep"
      doAssert got != plain
      # linear phase: the field is the computed (L - 1) / 2 unless typed
      g.filter = RefFilter(kind: rfLinear, taps: 31, highCutHz: 220, highSlopeDb: 48)
      doAssert effectiveShift(g.filter) == 15
      let lin = generateSamples(g)
      var hand = RecordingFilter(kind: rfkLinearPhase, taps: 31, highCutHz: 220,
        highSlopeDbPerOctave: 48, shiftSamples: 15)
      doAssert lin == initPilot(plain, dt).applyRecordingFilter(hand).samples
      g.filter.shiftTyped = true
      g.filter.shiftSamples = 3
      hand.shiftSamples = 3
      doAssert generateSamples(g) == initPilot(plain, dt).applyRecordingFilter(hand).samples
      # typed coefficients
      g.filter = RefFilter(kind: rfMinimum, coefficients: @[0.5, 0.25, 0.25], shiftTyped: true,
        shiftSamples: 1)
      let fir = generateSamples(g)
      doAssert fir.len == plain.len
      doAssert abs(fir[1000] - (0.5 * plain[1001] + 0.25 * plain[1000] + 0.25 * plain[999])) < 1e-5

  block settings_and_name_carry_the_filter:
    var g = raw(1)
    let key = generateSettingsKey(g)
    g.filter = minimum(207, 6, 1)
    doAssert generateSettingsKey(g) != key, "the settings key ignores the filter"
    let k1 = generateSettingsKey(g)
    g.filter.shiftSamples = 2
    doAssert generateSettingsKey(g) != k1
    g.filter.shiftSamples = 1
    doAssert defaultGenerateName(g) == "Linear 6-200 Hz 12 s, 207 Hz min. phase, shift 1",
      defaultGenerateName(g)
    g.filter = RefFilter(kind: rfMinimum, coefficients: @[1.0, 0.5])
    let c1 = generateSettingsKey(g)
    g.filter.coefficients[1] = 0.25
    doAssert generateSettingsKey(g) != c1

  block problems_in_plain_words:
    var g = raw(1)
    g.filter = minimum(500, 3, 0)
    doAssert "Nyquist" in generateProblem(g), generateProblem(g)
    g.filter = minimum(100, 3, 12000)
    doAssert "does not fit" in generateProblem(g), generateProblem(g)
    g.filter = RefFilter(kind: rfLinear, taps: 2, highCutHz: 100, highSlopeDb: 24)
    doAssert "taps" in generateProblem(g)
    g.filter = RefFilter(kind: rfMinimum, family: rfChebyshev, highCutHz: 100, highOrder: 3)
    doAssert "ripple" in generateProblem(g)
    g.filter = minimum(100, 3, 1)
    doAssert generateProblem(g) == ""
    doAssert "even number of taps" in evenTapsNote(RefFilter(kind: rfLinear, taps: 64))
    doAssert evenTapsNote(RefFilter(kind: rfLinear, taps: 63)) == ""
    doAssert "above 0.8" in topWarning(minimum(207, 6, 1), 200)
    doAssert topWarning(minimum(438, 6, 1), 200) == ""

  block suggestion_is_not_applied:
    var g = raw(1)
    g.filter = minimum(400, 6, 0)
    doAssert abs(suggestedDelay(g.filter, 1, 6, 220) - 0.70) < 0.02
    let built = buildGeneratePreview(g)
    doAssert built.problem == "" and abs(built.delay - 0.70) < 0.02, $built.delay
    doAssert effectiveShift(g.filter) == 0, "a suggestion filled the delay"
    doAssert buildGeneratePreview(raw(1)).delay.isNaN
    doAssert suggestedDelay(RefFilter(kind: rfLinear, taps: 211), 1, 6, 200) == 105

  block pasted_coefficients:
    let ok = parseCoefficients("1, 0.5\n# a comment\n 0.25;-0.125 1e-3\r\n")
    doAssert ok.problem == "" and ok.taps == @[1.0, 0.5, 0.25, -0.125, 0.001], $ok
    let bad = parseCoefficients("1 2\n3 abc")
    doAssert bad.taps.len == 0 and "line 2" in bad.problem and "abc" in bad.problem
    doAssert parseCoefficients("").taps.len == 0 and parseCoefficients("").problem == ""
    doAssert parseCoefficients("1 inf").problem.len > 0
    doAssert parseCoefficients("1 nan").problem.len > 0
    let round = parseCoefficients(coefficientsText(@[0.1, 1.0 / 3, -2e-7, 12345.678]))
    doAssert round.taps == @[0.1, 1.0 / 3, -2e-7, 12345.678]

  block the_archive_keeps_the_filter:
    withFixtures fx:
      let folder = fx.dir / "refs"
      createDir(folder)
      var g = raw(2)
      g.filter = RefFilter(kind: rfMinimum, coefficients: @[0.5, 0.25, 1.0 / 3],
          family: rfChebyshev,
        highCutHz: 150, highSlopeDb: 0, highOrder: 4, lowCutHz: 3, lowOrder: 2, rippleDb: 0.5,
        shiftSamples: -2, shiftTyped: true, taps: 0)
      let origin = ReferenceOrigin(generated: true, law: g.law, f1Hz: g.f1Hz, f2Hz: g.f2Hz,
        durationMs: g.durationMs, dtMs: g.dtMs, taperStartMs: 250, taperEndMs: 250,
        taperShape: tpCos2, amplitude: 1, filter: g.filter)
      let id = storeSamples(folder, "filtered", 2000, generateSamples(g), origin)
      let none = storeSamples(folder, "plain", 2000, generateSamples(raw(2)),
        ReferenceOrigin(generated: true, law: g.law, f1Hz: 6, f2Hz: 200, durationMs: 12000,
        dtMs: 2, taperStartMs: 250, taperEndMs: 250, taperShape: tpCos2, amplitude: 1))
      let back = loadIndex(folder)
      doAssert back.problems.len == 0, $back.problems
      let f = back.entries[back.findId(id)].origin.filter
      doAssert f == g.filter, "the filter did not come back as it went"
      doAssert f.shiftTyped and f.shiftSamples == -2, "the typed shift was lost"
      doAssert back.entries[back.findId(none)].origin.filter.kind == rfNone
      let text = readFile(indexPath(folder))
      doAssert text.count("(filter") == 1, "a plain sweep wrote a filter"
      # a document of this version, but with a filter kind it does not know, reads as none
      writeFile(indexPath(folder), text.replace("\"minimum phase\"", "\"warp\""))
      let odd = loadIndex(folder)
      doAssert odd.entries[odd.findId(id)].origin.filter.kind == rfNone
      doAssert odd.problems.len == 1 and "warp" in odd.problems[0], $odd.problems

  block extreme_integers_through_the_agent_and_the_problem_line:
    for v in [low(int), high(int)]:
      for field in ["taps", "shiftSamples", "highOrder", "lowOrder"]:
        for kind in ["linear phase", "minimum phase"]:
          var c = newCommand(ckGenerateReference)
          var problems: seq[string] = @[]
          decodeFields(%*{"refGenerate": {"law": "linear", "f1Hz": 6, "f2Hz": 200,
            "durationMs": 12000, "dtMs": 1, "amplitude": 1, "filter": {"kind": kind,
            "highCutHz": 100, "highSlopeDb": 24, "lowCutHz": 10, "lowSlopeDb": 24,
            "highOrder": 2, "lowOrder": 2, "taps": 31, "shiftTyped": field == "shiftSamples",
            field: v}}}, c, problems)
          doAssert problems.len == 0, $problems
          let g = c.refGenerate
          discard effectiveShift(g.filter)
          discard filterNameSuffix(g.filter)
          discard filterWords(g.filter)
          discard evenTapsNote(g.filter)
          discard lowCutNote(g.filter, 1)
          discard suggestedDelay(g.filter, 1, 6, 200)
          discard generateSettingsKey(g)
          # taps are for the linear design, orders for the family: the other kind ignores them
          let used = not ((kind == "minimum phase" and field == "taps") or
            (kind == "linear phase" and field in ["highOrder", "lowOrder"]))
          doAssert (generateProblem(g).len > 0) == used, kind & " " & field & " " & $v
          if used:
            doAssertRaises(ValueError): discard generateSamples(g)

  block non_finite_output_and_ripple_floor_are_refused:
    var g = raw(2)
    g.filter = RefFilter(kind: rfMinimum, family: rfChebyshev, highCutHz: 100, highOrder: 4,
      rippleDb: 1e-300)
    doAssert "ripple" in generateProblem(g), generateProblem(g)
    g.filter.rippleDb = 0.001
    doAssert generateProblem(g) == ""
    g.filter = RefFilter(kind: rfMinimum, coefficients: @[1e300])
    doAssertRaises(ValueError): discard generateSamples(g)
    doAssertRaises(ValueError): discard buildGeneratePreview(g)

  block linear_phase_typed_taps_and_the_notes:
    var g = raw(1)
    g.filter = RefFilter(kind: rfLinear, coefficients: @[0.25, 0.5, 0.25])
    doAssert effectiveShift(g.filter) == 1 and symmetryNote(g.filter) == ""
    doAssert generateProblem(g) == ""
    let plain = generateSamples(raw(1))
    let hand = initPilot(plain, 1).applyRecordingFilter(RecordingFilter(
      kind: rfkLinearPhase, coefficients: @[0.25, 0.5, 0.25], shiftSamples: 1)).samples
    doAssert generateSamples(g) == hand
    g.filter.coefficients = @[0.25, 0.5, 0.3]
    doAssert "not symmetric" in symmetryNote(g.filter)
    doAssert generateProblem(g) == "", "an asymmetric set is a note, not a refusal"
    # even counts: floor((L - 1) / 2) in both libraries, and the sentence
    let even = RefFilter(kind: rfLinear, taps: 64, highCutHz: 100, highSlopeDb: 24)
    doAssert effectiveShift(even) == 31
    doAssert "half a sample" in evenTapsNote(even), evenTapsNote(even)
    doAssert suggestedDelay(even, 1, 6, 200) == 31.5
    doAssert recordingFilter(even).suggestedShift(1, 6, 200) == 31
    doAssert effectiveShift(RefFilter(kind: rfLinear, taps: 1)) == 0
    # a low-cut the taps cannot make
    let low = RefFilter(kind: rfLinear, taps: 31, lowCutHz: 5, lowSlopeDb: 24)
    doAssert "cannot make a low-cut" in lowCutNote(low, 2), lowCutNote(low, 2)
    doAssert lowCutNote(RefFilter(kind: rfLinear, taps: 401, lowCutHz: 5, lowSlopeDb: 24), 2) == ""
    # the archive keeps a linear filter's taps and both slopes
    withFixtures fx:
      let folder = fx.dir / "refs"
      createDir(folder)
      let f = RefFilter(kind: rfLinear, taps: 211, highCutHz: 100, highSlopeDb: 48, lowCutHz: 5,
        lowSlopeDb: 12)
      let typed = RefFilter(kind: rfLinear, coefficients: @[0.25, 0.5, 0.25], shiftSamples: 2,
        shiftTyped: true)
      var ids: seq[string] = @[]
      for x in [f, typed]:
        ids.add storeSamples(folder, "lin" & $ids.len, 1000, generateSamples(raw(1)),
          ReferenceOrigin(generated: true, law: rlLinear, f1Hz: 6, f2Hz: 200, durationMs: 12000,
          dtMs: 1, taperStartMs: 250, taperEndMs: 250, taperShape: tpCos2, amplitude: 1,
          filter: x))
      let back = loadIndex(folder)
      doAssert back.problems.len == 0, $back.problems
      let fb = back.entries[back.findId(ids[0])].origin.filter
      doAssert fb.taps == 211 and fb.highSlopeDb == 48 and fb.lowSlopeDb == 12 and
        fb.lowCutHz == 5 and fb.highCutHz == 100, $fb
      doAssert fb == f
      doAssert back.entries[back.findId(ids[1])].origin.filter == typed

  block a_generate_command_end_to_end:
    withFixtures fx:
      var st = initAppState()
      st.readyArchive(fx.dir / "refs")
      doAssert waitUntil((discard st.drainInbox(); st.referencesLoaded))
      var made = 0
      for (dt, want) in [(1.0, 12000), (2.0, 6000)]:
        let name = "filtered " & $dt
        var g = raw(dt)
        g.name = name
        g.filter = minimum(180, 4, 1)
        st.apply Command(kind: ckGenerateReference, refGenerate: g)
        inc made
        doAssert waitUntil((discard st.drainInbox(); st.references.entries.len >= made)),
          "the filtered sweep was not stored"
        var found = false
        for e in st.references.entries:
          if e.name == name:
            found = true
            doAssert e.samples == want, $e.samples
            doAssert e.origin.filter == g.filter
            let stored = readStored(st.referencesHome / e.file)
            doAssert stored == generateSamples(g), "the stored reference is not the " &
              "filtered sweep"
            doAssert stored != generateSamples(raw(dt))
        doAssert found
      # a refused filter stores nothing
      var bad = raw(1)
      bad.name = "bad"
      bad.filter = minimum(900, 4, 0)
      let before = st.references.entries.len
      st.apply Command(kind: ckGenerateReference, refGenerate: bad)
      discard waitUntil((discard st.drainInbox(); st.references.entries.len > before), initDuration(
          milliseconds = 600))
      doAssert st.references.entries.len == before

  block the_agent_command_takes_a_filter:
    var c = newCommand(ckGenerateReference)
    var problems: seq[string] = @[]
    decodeFields(%*{"refGenerate": {"name": "agent", "law": "linear", "f1Hz": 6, "f2Hz": 200,
      "durationMs": 12000, "dtMs": 1, "amplitude": 1, "filter": {"kind": "minimum phase",
      "family": "Chebyshev", "highCutHz": 300, "highOrder": 4, "rippleDb": 1,
      "coefficients": [0.5, 0.25], "shiftSamples": 2, "shiftTyped": true}}}, c, problems)
    doAssert problems.len == 0, $problems
    let f = c.refGenerate.filter
    doAssert f.kind == rfMinimum and f.family == rfChebyshev and f.highOrder == 4
    doAssert f.coefficients == @[0.5, 0.25] and effectiveShift(f) == 2
    # left out: none
    var d = newCommand(ckGenerateReference)
    decodeFields(%*{"refGenerate": {"f1Hz": 8}}, d, problems)
    doAssert d.refGenerate.filter.kind == rfNone and problems.len == 0
    var e = newCommand(ckGenerateReference)
    decodeFields(%*{"refGenerate": {"filter": {"kind": "warp"}}}, e, problems)
    doAssert problems.len == 1, $problems

  echo "treffilter: ok"

when isMainModule: main()
