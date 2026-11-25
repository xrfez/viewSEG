## The vibrator signature's verdict (`core/vibjudge`, `core/vibalign`, and `vibratorOf`'s
## window statistics) on synthetic sweeps of known phase, amplitude, harmonics and delay
## (`utils/vibsynth`: a linear sweep, 6 to 100 Hz in 8 s, 0.1 s tapers). Each number the
## window shows is compared with one worked out here:
##
## - a good sweep passes all six limits; the phase is the phase put in, the force the
##   amplitude put in, % of the 100 % force typed, the distortion the level of the harmonics
##   put in that lie in band (2nd up to 50 Hz, 3rd up to 33.3 Hz of a sweep with a top of 100 Hz);
## - each limit fails alone, by a sweep made to fail that one (the other five hold): a phase
##   offset, a bad stretch of phase, a 2nd harmonic all along or in one stretch, a low
##   amplitude, a stretch of high amplitude;
## - the verdict line names the worst failing value and its time, `not judged` when there
##   is no 100 % force (the force limits) or no window;
## - the window's length is the one typed;
## - a trace cut short is judged to its end (D3), and says so;
## - at 2 ms and 4 ms sampling the fundamental is not measured above 80 % of Nyquist, and
##   that is no "signal ends" warning (D4);
## - force numbers keep four significant digits whatever their size (D8), the note says what
##   sets the judged part (D9);
## - the top frequency: typed, exact (a generated reference), or estimated; a warning when it
##   is 2 % off the largest frequency seen;
## - a stored reference is aligned to the recorded one by correlation, by the lead-in found
##   (D1); against none, it starts at its own stored time.
##
## Seen to fail: with `toMs` not set for a trace shorter than its reference, "a cut trace is
## judged to its end" read an average force of 60 % for 100 %; with the fundamental's cut
## ignored (the reference's own last measured point not used), "no false signal end at 2 and
## 4 ms" read "signal ends at about 9 010 ms; the reference runs to 9 9..."; the alignment
## block's unaligned half (the stored reference as it comes) shows what the shift cures: the
## recorded reference measures over 45 degrees to it.
##
## Peak values read a little higher or lower with processSEG 0.8.0's 16-tap peak
## interpolator; the tolerances below (1 %) are its error, not the old 8-tap one.

import std/[math, random, strutils]
import viewSEG/core/[analysis, vibalign, vibanalysis, vibjudge]
import processSEG/core/shift
import processSEG/vibroseis/vibqc
import utils/vibsynth

const
  Hundred = 1000.0 ## the 100 % force, in the traces' own unit

func good(): SynthSweep =
  SynthSweep(amp: 1000, phaseDeg: 1, h2: 0.02, h3: 0.0)

proc judgeOf(gf: SynthSweep; p = AnalysisParams();
    topHz = 100.0): AnalysisResult =
  ## The window's numbers for a unit of Ref, GF (no M and B), top frequency `topHz`.
  let ref0 = gf.referenceOf
  let rows = @[ref0.sweepRow, gf.sweepRow]
  var q = p
  if q.forceHundredPct.isNaN: q.forceHundredPct = Hundred
  result = vibratorOf(rows, @["R", "GF"], [vsReference: 0, vsGroundForce: 1,
    vsMass: -1,
    vsBaseplate: -1], gf.dtMs, q, -1, topHz)
  doAssert result.problem == "", result.problem

func row(r: AnalysisResult; l: QcLimit): QcRow = r.qc.rows[ord(l)]

func failing(r: AnalysisResult): seq[QcLimit] =
  for x in r.qc.rows:
    if x.status == qsFail: result.add x.limit

func near(a, b, tol: float64): bool = abs(a - b) <= tol

proc baseTests() =
  block good_sweep_passes:
    var spec = good()
    spec.phaseDeg = 2
    spec.h2 = 0.05
    spec.h3 = 0.02
    let r = judgeOf(spec)
    doAssert r.qc.verdict == qvPass, r.qc.line
    doAssert r.qc.rows.len == 6 and r.failing.len == 0, r.qc.line
    let s = r.qc.stats
    doAssert near(s.avgPhaseDeg, 2, 0.2) and near(s.peakPhaseDeg, 2, 0.3),
      "phase " & $s.avgPhaseDeg & " " & $s.peakPhaseDeg
    # the force is the amplitude put in: 100 % of 1000
    doAssert near(s.avgForcePct, 100, 1), "average force " & $s.avgForcePct
    # in-band distortion, worked out: the 2nd (5 %) up to 50 Hz, the 3rd (2 %) up to 33.3 Hz,
    # 6 + 94 t / 8 Hz: 5.39 % to 2.30 s, 5 % to 3.745 s, none after; the flat part is
    # 0.1 .. 7.9 s
    let early = sqrt(0.05 ^ 2 + 0.02 ^ 2) * 100
    let expected = (early * (2.30 - 0.1) + 5.0 * (3.745 - 2.30)) / (7.9 - 0.1)
    doAssert near(s.avgDistortionPct, expected, 0.4), "average distortion " &
      $s.avgDistortionPct & " not " & $expected
    doAssert near(s.peakDistortionPct, early, 0.4), "peak distortion " &
        $s.peakDistortionPct
    doAssert s.peakDistortionAtMs < 2300, "worst distortion at " &
        $s.peakDistortionAtMs
    # peak force: the waveform's largest |sample| of the flat part, within the interpolator's 1 %
    let row = spec.sweepRow
    var top = 0.0
    for j in 100 ..< 7900: top = max(top, abs(float64(row[j])))
    doAssert near(s.peakForce, top, 0.01 * top), "peak force " & $s.peakForce &
        " not " & $top
    doAssert near(s.peakForcePct, 100 * top / Hundred, 1)
    doAssert r.qc.line.startsWith("✓ PASS"), r.qc.line
    # the table has a mark as text on every row
    for x in r.qc.tableOf[1 .. ^1]: doAssert x[0] == "✓", $x
    # the tapers are dimmed on every plot and left out of the judged part
    for p in r.plots:
      doAssert p.dimmed.len == 2, p.title & ": " & $p.dimmed
    doAssert "judged from" in r.note and "the sweep less its tapers" in r.note, r.note

  block peak_force_shows_the_fundamental_beside:
    # a 2nd harmonic of 40 % lifts the waveform's envelope peak to about 120 % of the 100 %
    # force while the fundamental holds 100 %: the peak force verdict stays on the envelope's
    # peak (it exposes distortion), the fundamental's peak is shown beside it and decides nothing
    var spec = good()
    spec.h2 = 0.4
    let r = judgeOf(spec, topHz = 200)
    let s = r.qc.stats
    doAssert near(s.fundamentalPeakPct, 100, 1.5), "fundamental peak " & $s.fundamentalPeakPct
    doAssert s.peakForcePct > 115, "peak force " & $s.peakForcePct
    doAssert near(r.row(qlPeakForce).measured, s.peakForcePct, 1e-9)
    doAssert "peak fundamental force 100" in r.note and "peak force (with harmonics)" in r.note,
      r.note
    doAssert "points at distortion or decoupling" in r.note

  block phase_limits:
    var spec = good()
    spec.phaseDeg = 8
    let r = judgeOf(spec)
    doAssert r.failing == @[qlAvgPhase], $r.failing
    doAssert near(r.row(qlAvgPhase).measured, 8, 0.3)
    doAssert r.qc.verdict == qvFail and "average phase" in r.qc.line and
        "8°" in r.qc.line,
      r.qc.line
    # a stretch of 25 degrees from 3 to 4 s: a window of its own (the mean 26 the peak), the
    # average about 4.4
    spec = good()
    spec.burstAtS = 3.0
    spec.burstLenS = 1.0
    spec.burstPhaseDeg = 25
    let b = judgeOf(spec)
    doAssert b.failing == @[qlPeakPhase], $b.failing
    let peak = b.row(qlPeakPhase)
    doAssert peak.measured > 22 and peak.measured <= 26.5, "peak phase " & $peak.measured
    doAssert peak.atMs >= 2400 and peak.atMs <= 4000, "worst at " & $peak.atMs
    doAssert near(b.row(qlAvgPhase).measured, 1 + 25 * 1.0 / 7.8, 0.8),
      "average phase " & $b.row(qlAvgPhase).measured
    doAssert "peak phase" in b.qc.line and "at " in b.qc.line and " s" in
        b.qc.line, b.qc.line

  block distortion_limits:
    # a 2nd harmonic of 40 % all along, a band to 200 Hz: it is all in band
    # (the harmonic makes the waveform's peak high: the peak force limit is off here)
    var noPeak = AnalysisParams()
    noPeak.qc.peakForcePct = NaN
    var spec = good()
    spec.h2 = 0.4
    let r = judgeOf(spec, noPeak, topHz = 200)
    doAssert r.failing == @[qlAvgDistortion], $r.failing
    doAssert near(r.row(qlAvgDistortion).measured, 40, 1)
    doAssert near(r.row(qlPeakDistortion).measured, 40, 1)
    # the same sweep with the band at its own top (100 Hz): in band to 50 Hz only, so the
    # average is the 40 % over the first 3.645 s of 7.8 and passes
    let narrow = judgeOf(spec, noPeak, topHz = 100)
    doAssert narrow.failing.len == 0, $narrow.failing
    doAssert near(narrow.row(qlAvgDistortion).measured, 40 * (3.745 - 0.1) /
        7.8, 1.5),
      $narrow.row(qlAvgDistortion).measured
    # a stretch of 90 %: its window is over the peak limit, the average is not over its own
    spec = good()
    spec.burstAtS = 3.0
    spec.burstLenS = 1.0
    spec.burstH2 = 0.9
    let b = judgeOf(spec, noPeak, topHz = 200)
    doAssert b.failing == @[qlPeakDistortion], $b.failing
    doAssert b.row(qlPeakDistortion).measured > 75 and b.row(
        qlPeakDistortion).measured < 91
    doAssert near(b.row(qlAvgDistortion).measured, (90 * 1.0 + 2 * 6.8) / 7.8, 2.5)

  block force_limits:
    var spec = good()
    spec.amp = 800
    let r = judgeOf(spec)
    doAssert r.failing == @[qlAvgForce], $r.failing
    doAssert near(r.row(qlAvgForce).measured, 80, 1), $r.row(
        qlAvgForce).measured
    doAssert "average force" in r.qc.line and "<" in r.qc.line and "%" in
        r.qc.line, r.qc.line
    spec = good()
    spec.burstAtS = 3.0
    spec.burstLenS = 1.0
    spec.burstGain = 1.6
    let b = judgeOf(spec)
    doAssert b.failing == @[qlPeakForce], $b.failing
    doAssert b.row(qlPeakForce).measured > 155 and b.row(qlPeakForce).measured < 165,
      $b.row(qlPeakForce).measured
    doAssert near(b.row(qlAvgForce).measured, (1000 * 6.8 + 1600 * 1.0) / 7.8 /
        10, 2.5)
    doAssert b.row(qlPeakForce).atMs >= 2400 and b.row(qlPeakForce).atMs <= 4000
    doAssert b.qc.line.startsWith("✗ FAIL: peak force") and ">" in
        b.qc.line and
      "120 %" in b.qc.line, b.qc.line
    # the force at its own scale: the same sweep, 100 % = 2000, is 50 % and 80 %: fails the average
    var p = AnalysisParams()
    p.forceHundredPct = 2000
    let half = judgeOf(good(), p)
    doAssert near(half.row(qlAvgForce).measured, 50, 1) and half.failing == @[
        qlAvgForce],
      $half.failing

  block worst_failing_value_is_the_furthest_past_its_limit:
    var spec = good()
    spec.phaseDeg = 8 # 160 % of the 5 degree limit
    spec.amp = 500 # average force 50 %: 180 % of the 90 % bound, the worse
    let r = judgeOf(spec)
    doAssert r.failing.len == 2 and r.qc.rows[r.qc.worst].limit == qlAvgForce, $r.qc.line
    doAssert "(and 1 more)" in r.qc.line, r.qc.line

  block no_force_scale_is_said:
    var p = AnalysisParams()
    let rows = @[good().referenceOf.sweepRow, good().sweepRow]
    var q = p
    q.forceHundredPct = NaN
    let r = vibratorOf(rows, @["R", "GF"], [vsReference: 0, vsGroundForce: 1,
      vsMass: -1,
      vsBaseplate: -1], 1.0, q, -1, 100.0)
    doAssert r.qc.verdict == qvPass, r.qc.line
    for l in [qlAvgForce, qlPeakForce]:
      doAssert r.row(l).status == qsNotJudged and "100 % force" in r.row(l).why,
          r.row(l).why
    doAssert "not judged" in r.qc.line and "100 % force" in r.qc.line, r.qc.line
    doAssert r.qc.forceNote.len > 0

  block limits_off_and_not_judged:
    var p = AnalysisParams()
    p.qc.avgPhaseDeg = NaN
    var spec = good()
    spec.phaseDeg = 8
    let r = judgeOf(spec, p)
    doAssert r.row(qlAvgPhase).status == qsNotJudged and r.row(
        qlAvgPhase).why == "limit off"
    doAssert r.qc.verdict == qvPass, r.qc.line

  block the_window_is_the_one_typed:
    var p = AnalysisParams()
    let w500 = judgeOf(good(), p)
    p.qcWindowMs = 250
    let w250 = judgeOf(good(), p)
    doAssert w500.qc.stats.windowMs == 500 and w250.qc.stats.windowMs == 250
    doAssert w500.qc.stats.windows in 14 .. 16, $w500.qc.stats.windows
    doAssert w250.qc.stats.windows in 29 .. 32, $w250.qc.stats.windows

  block a_cut_trace_is_judged_to_its_end:
    # D3: the GF stops at 5 s of an 8 s reference: its zero-padded rest is no measurement
    var spec = good()
    spec.cutAtS = 5.0
    let r = judgeOf(spec)
    doAssert near(r.row(qlAvgForce).measured, 100, 2), "average force " &
      $r.row(qlAvgForce).measured
    doAssert r.qc.stats.minForce > 0.9 * 1000, "minimum force " &
        $r.qc.stats.minForce
    doAssert r.qc.verdict == qvPass, r.qc.line
    doAssert "judged to the trace's end" in r.note, r.note
    doAssert "the last 3 500 ms of the reference have no data" in r.warning, r.warning

  block force_numbers_keep_four_digits:
    doAssert forceNumber(1e-30) == "1.000e-30" and forceNumber(1e30) == "1.000e+30"
    doAssert forceNumber(0.0012) == "0.001200", forceNumber(0.0012)
    doAssert forceNumber(13202.4) == "13202" and forceNumber(662.93) == "662.9"
    doAssert forceNumber(0) == "0" and forceNumber(NaN) == "–"
    # the table says the same of a force in volts and one in counts
    let volts = judgeOf(SynthSweep(amp: 0.0012, phaseDeg: 1, h2: 0.02),
      AnalysisParams(forceHundredPct: 0.0012))
    var found = false
    for x in volts.table[1 .. ^1]:
      if x[0] == "GF":
        found = true
        doAssert x[7] == "0.001200", "mean force " & x[7]
    doAssert found

  block the_note_says_what_sets_the_judged_part:
    # the judged part is the sweep less its tapers, and the note says so (there is no other
    # judged span: the point limits and their skips are gone)
    let tapers = judgeOf(good())
    doAssert "less its tapers" in tapers.note, tapers.note
    doAssert "judged from " in tapers.note, tapers.note

  block no_false_signal_end_at_2_and_4_ms:
    # D4: the fundamental is measured to 80 % of Nyquist only (200 Hz at 2 ms, 100 Hz at 4 ms)
    for (dt, f1, seconds) in [(2.0, 220.0, 10.0), (4.0, 120.0, 10.0), (1.0,
        100.0, 8.0)]:
      var spec = good()
      (spec.dtMs, spec.f0, spec.f1, spec.seconds) = (dt, 6.0, f1, seconds)
      let r = judgeOf(spec, topHz = f1)
      doAssert "signal ends" notin r.warning,
        $dt & " ms: a false warning: " & r.warning
      if dt > 1:
        doAssert "below 80 % of Nyquist" in r.note, r.note
    # a signal that really stops early still says so
    var spec = good()
    spec.dtMs = 2
    spec.f1 = 220
    spec.seconds = 10
    var row = spec.sweepRow
    for j in 3500 ..< row.len: row[j] = 0
    let rows = @[spec.referenceOf.sweepRow, row]
    let r = vibratorOf(rows, @["R", "GF"], [vsReference: 0, vsGroundForce: 1,
      vsMass: -1,
      vsBaseplate: -1], 2.0, AnalysisParams(forceHundredPct: Hundred), -1, 220.0)
    doAssert "signal ends" in r.warning, "a stopped GF said nothing: " & r.warning

  block the_top_frequency:
    let spec = good()
    # the estimate: the chord fit of the reference, within 2 % of the sweep's 100 Hz
    let own = judgeOf(spec, topHz = NaN)
    doAssert not own.band.typed and not own.band.exact
    doAssert near(own.band.hz, 100, 2), "estimated top " & $own.band.hz
    doAssert near(own.band.suggestedHz, 100, 2) and not own.band.chordHz.isNaN
    # (the chord reads a little under the top, by the rate over the end taper: not a warning)
    doAssert own.band.warning.len == 0, own.band.warning
    var slow = good()
    slow.seconds = 20
    doAssert judgeOf(slow, topHz = 100).band.warning.len == 0
    doAssert judgeOf(slow, topHz = 99).band.warning.len == 0
    # typed
    let typed = judgeOf(spec, topHz = 100)
    doAssert typed.band.typed and typed.band.hz == 100
    # exact, as a generated reference gives it
    let rows = @[spec.referenceOf.sweepRow, spec.sweepRow]
    let exact = vibratorOf(rows, @["R", "GF"], [vsReference: 0,
      vsGroundForce: 1, vsMass: -1,
      vsBaseplate: -1], 1.0, AnalysisParams(forceHundredPct: Hundred), -1, NaN, 100.0)
    doAssert exact.band.exact and exact.band.hz == 100 and not exact.band.typed
    # a typed edge more than 2 % from the largest frequency seen is warned about
    let off = judgeOf(spec, topHz = 150)
    doAssert "does not fit the largest frequency measured" in off.band.warning,
        off.band.warning
    # the note says the distortion is the in-band one
    doAssert "in-band" in own.note and "top frequency" in own.note, own.note

  block stored_reference_is_aligned_to_the_recorded_one:
    # D1: the recorded reference and the force begin 115 ms into the record; the stored
    # reference is the sweep from its own start
    var late = good()
    late.delayMs = 115
    let stored = good().referenceOf.sweepRow
    let recorded = late.referenceOf.sweepRow
    let al = alignStored(recorded, stored, 1.0)
    doAssert al.found and near(al.shiftMs, 115, 1), "shift " & $al.shiftMs
    doAssert al.words == "stored reference aligned to the recorded reference: +115 ms",
      al.words
    # the other way: the recorded reference starts before the stored one's start
    let before = alignStored(stored, late.referenceOf.sweepRow, 1.0)
    doAssert before.found and near(before.shiftMs, -115, 1), "shift " &
        $before.shiftMs
    let moved = stored.placedWhole(int(round(al.shiftMs)))
    doAssert moved.len == stored.len + 115 and moved[114] == 0 and moved[115] ==
        stored[0]
    # aligned: the recorded reference measures 0 degrees to it (mean |phase| of Ref (recorded)),
    # the force the 1 degree put in; unaligned, about 90
    let gf = late.sweepRow
    func recordedPhase(r: AnalysisResult): float64 =
      for x in r.table[1 .. ^1]:
        if x[0] == RecordedRef: return parseFloat(x[3])
      NaN
    proc measured(ref0: seq[float32]): AnalysisResult =
      vibratorOf(@[recorded, gf, ref0], @["R", "GF", "stored"], [vsReference: 2,
        vsGroundForce: 1, vsMass: -1, vsBaseplate: -1], 1.0,
        AnalysisParams(forceHundredPct: Hundred), 0, 100.0)
    let aligned = measured(moved)
    doAssert aligned.problem == "", aligned.problem
    doAssert recordedPhase(aligned) < 1, "aligned recorded phase " &
        $recordedPhase(aligned)
    doAssert aligned.qc.verdict == qvPass, aligned.qc.line
    let unaligned = measured(stored)
    doAssert recordedPhase(unaligned) > 45, "unaligned recorded phase " &
      $recordedPhase(unaligned)
    # no clear peak (noise against a sweep): not aligned, said
    var noise = newSeq[float32](stored.len)
    var seed = 12345'u32
    for v in noise.mitems:
      seed = seed * 1664525'u32 + 1013904223'u32
      v = float32(int(seed shr 8) mod 2000 - 1000)
    let none = alignStored(noise, stored, 1.0)
    doAssert not none.found and "taken to start together" in none.words, none.words
    # no recorded reference: the stored one at its own start time
    doAssert stored.startedAt(100, 1.0).len == stored.len + 100
    doAssert startsTogether(0).len > 0 and "start together" in startsTogether(0)
    doAssert "+100 ms" in startsTogether(100), startsTogether(100)

proc fourRows(gf, m, b: SynthSweep; p: AnalysisParams; topHz = 100.0): AnalysisResult =
  ## Ref, GF, M and B with the masses 3000 and 1000 kg typed: GF (M, B) = 3000·M + 1000·B.
  let rows = @[gf.referenceOf.sweepRow, gf.sweepRow, m.sweepRow, b.sweepRow]
  var q = p
  (q.reactionMassKg, q.baseplateMassKg) = (3000.0, 1000.0)
  if q.forceHundredPct.isNaN: q.forceHundredPct = Hundred
  if q.forceHundredWeighted.isNaN: q.forceHundredWeighted = Hundred
  result = vibratorOf(rows, @["R", "GF", "M", "B"], [vsReference: 0, vsGroundForce: 1,
    vsMass: 2, vsBaseplate: 3], gf.dtMs, q, -1, topHz)
  doAssert result.problem == "", result.problem

proc massesFor(phaseDeg: float64): (SynthSweep, SynthSweep) =
  ## M of amplitude 1 and B of amplitude 2 against it: 3000·1 − 1000·2 = 1000 at `phaseDeg`.
  var m = good()
  (m.amp, m.phaseDeg, m.h2) = (1.0, phaseDeg, 0.0)
  var b = m
  (b.amp, b.phaseDeg) = (2.0, phaseDeg + 180)
  (m, b)

proc judgeChoice() =
  block the_judged_ground_force_is_named_and_chosen:
    # the recorded GF and the sum of M and B with the typed masses agree: no warning, the
    # recorded GF judged, named in the line; the choice moves the verdict to the other
    let (m, b) = massesFor(1)
    var p = AnalysisParams()
    let r = fourRows(good(), m, b, p)
    doAssert r.bothSignals and r.judged == "GF" and r.judgeWarning.len == 0, r.judgeWarning
    doAssert r.qc.line.startsWith("✓ PASS on GF as recorded:"), r.qc.line
    p.roles.judge = joWeighted
    let w = fourRows(good(), m, b, p)
    doAssert w.judged == "GF (M, B)" and w.qc.line.startsWith("✓ PASS on GF from M and B:"),
      w.qc.line
    doAssert near(w.qc.stats.avgPhaseDeg, 1, 0.3), $w.qc.stats.avgPhaseDeg
    doAssert near(w.qc.stats.avgForcePct, 100, 1.5), $w.qc.stats.avgForcePct
    # a recorded GF that does not match the masses: one warning, the default kept
    let (m2, b2) = massesFor(40)
    let off = fourRows(good(), m2, b2, AnalysisParams())
    doAssert off.judged == "GF" and off.qc.verdict == qvPass, off.qc.line
    doAssert "the recorded GF does not match M and B with the typed masses (" in
      off.judgeWarning and "or judge GF from M and B" in off.judgeWarning, off.judgeWarning
    doAssert "phase differs by up to 39 degrees" in off.judgeWarning or
      "phase differs by up to 40 degrees" in off.judgeWarning, off.judgeWarning
    # chosen by the user: judged on the sum, no warning
    var q = AnalysisParams()
    q.roles.judge = joWeighted
    let chosen = fourRows(good(), m2, b2, q)
    doAssert chosen.judgeWarning.len == 0 and chosen.judged == "GF (M, B)"
    doAssert near(chosen.qc.stats.avgPhaseDeg, 40, 0.5), $chosen.qc.stats.avgPhaseDeg
    # a phase that swings either way (+15 degrees for a second against a flat sum) is a
    # mismatch by window though the averages agree; a constant gain offset alone is none
    var swing = good()
    swing.burstAtS = 3.0
    swing.burstLenS = 1.0
    swing.burstPhaseDeg = 15
    let sw = fourRows(swing, m, b, AnalysisParams())
    doAssert "phase differs by up to" in sw.judgeWarning, "no warning: " & sw.judgeWarning
    var half = good()
    half.amp = 500 # the sum is 1000: a factor of two everywhere
    let gain = fourRows(half, m, b, AnalysisParams())
    doAssert gain.judgeWarning.len == 0, gain.judgeWarning
    # one ground force only: no choice, no name in the line
    let single = judgeOf(good())
    doAssert not single.bothSignals and single.qc.line.startsWith("✓ PASS:")

proc fullScalePerSignal() =
  block each_judged_signal_has_its_own_full_scale:
    let (m, b) = massesFor(1)
    # only the recorded GF's full scale typed: judging GF (M, B) leaves the force rows not
    # judged (not 2000 % of a number in another unit)
    let rows = @[good().referenceOf.sweepRow, good().sweepRow, m.sweepRow, b.sweepRow]
    var p = AnalysisParams(reactionMassKg: 3000, baseplateMassKg: 1000, forceHundredPct: 500)
    p.roles.judge = joWeighted
    let at = [vsReference: 0, vsGroundForce: 1, vsMass: 2, vsBaseplate: 3]
    let none = vibratorOf(rows, @["R", "GF", "M", "B"], at, 1.0, p, -1, 100.0)
    doAssert none.judged == "GF (M, B)"
    for l in [qlAvgForce, qlPeakForce]:
      doAssert none.row(l).status == qsNotJudged, $l & ": " & $none.row(l).measured
    # its own typed: judged on it; the recorded GF's 500 is used when that is judged
    p.forceHundredWeighted = 1000
    let weighted = vibratorOf(rows, @["R", "GF", "M", "B"], at, 1.0, p, -1, 100.0)
    doAssert near(weighted.row(qlAvgForce).measured, 100, 1.5), $weighted.row(qlAvgForce).measured
    p.roles.judge = joRecorded
    let recorded = vibratorOf(rows, @["R", "GF", "M", "B"], at, 1.0, p, -1, 100.0)
    doAssert near(recorded.row(qlAvgForce).measured, 200, 3), $recorded.row(qlAvgForce).measured

proc targetForce() =
  block the_target_force_is_the_drive_level:
    # a 60 % drive: full scale 1000 typed, target 60, the amplitude 600: the average force is
    # 100 % of the target
    var spec = good()
    spec.amp = 600
    var p = AnalysisParams()
    p.targetPct = 60
    let r = judgeOf(spec, p)
    doAssert r.failing.len == 0, r.qc.line
    doAssert near(r.row(qlAvgForce).measured, 100, 1.5), $r.row(qlAvgForce).measured
    doAssert near(r.row(qlPeakForce).measured, 60, 1.5), $r.row(qlPeakForce).measured
    doAssert "of target" in r.row(qlAvgForce).boundText and
      "of 100 %" in r.row(qlPeakForce).boundText
    # with the target at 100 the same sweep is 60 % of it
    p.targetPct = 100
    doAssert judgeOf(spec, p).failing == @[qlAvgForce]
    # a peak of 125 % of full scale fails the peak whatever the target
    spec.burstAtS = 3.0
    spec.burstLenS = 1.0
    spec.burstGain = 2.1
    p.targetPct = 60
    let hi = judgeOf(spec, p)
    doAssert hi.failing == @[qlPeakForce], $hi.failing
    doAssert hi.row(qlPeakForce).measured > 120 and hi.row(qlPeakForce).measured < 135,
      $hi.row(qlPeakForce).measured

proc bandWarnings() =
  block the_top_frequency_warning_fits_the_sweeps_it_sees:
    # a correct top never warns, whatever the sweep: the chord reads under the top by the
    # rate over the end taper; a top 10 % low or 10 % high does
    for (f0, f1, seconds, taper, dt) in [(6.0, 220.0, 12.0, 0.2, 1.0), (10.0, 100.0, 8.0, 0.1, 1.0),
        (8.0, 80.0, 8.0, 0.1, 1.0), (2.0, 96.0, 30.0, 0.5, 1.0), (1.0, 300.0, 10.0, 0.1, 1.0),
        (220.0, 6.0, 12.0, 0.2, 1.0)]:
      var spec = good()
      (spec.f0, spec.f1, spec.seconds, spec.taperS, spec.dtMs) = (f0, f1, seconds, taper, dt)
      let top = max(f0, f1)
      let tag = $f0 & "-" & $f1 & " Hz in " & $seconds & " s"
      doAssert judgeOf(spec, topHz = top).band.warning.len == 0, tag & ": " &
        judgeOf(spec, topHz = top).band.warning
      doAssert judgeOf(spec, topHz = 0.9 * top).band.warning.len > 0, tag & ": 10 % low"
      doAssert judgeOf(spec, topHz = 1.1 * top).band.warning.len > 0, tag & ": 10 % high"

proc downSweepBand() =
  block a_down_sweeps_top_is_at_its_start:
    for (taper, expo, seconds) in [(0.5, false, 12.0), (1.0, false, 12.0), (0.5, true, 12.0)]:
      var spec = good()
      (spec.f0, spec.f1, spec.seconds, spec.taperS, spec.expo) = (220.0, 6.0, seconds, taper,
        expo)
      let tag = "220-6 Hz " & (if expo: "exponential" else: "linear") & ", taper " & $taper
      doAssert judgeOf(spec, topHz = 220).band.warning.len == 0, tag & ": " &
        judgeOf(spec, topHz = 220).band.warning
      # (an exponential sweep's chord reads 14 % under its top: the rate over the taper is
      # large, so only a top further off than that can be told wrong)
      let (low, high) = if expo: (0.8, 1.15) else: (0.9, 1.1)
      doAssert judgeOf(spec, topHz = 220 * low).band.warning.len > 0, tag & ": too low"
      doAssert judgeOf(spec, topHz = 220 * high).band.warning.len > 0, tag & ": too high"

proc topFromTheReference() =
  block with_no_top_typed_the_reference_gives_its_own:
    # the top frequency comes from the reference's frequency track alone (a line to the sweep's
    # end, in f or in ln f, rounded to a whole hertz within 0.5 % of one): the designed top
    # comes back, up or down, linear or exponential, and is the same for every record; a
    # typed one still wins
    # Seen to fail: with the library's own estimate (220.4 Hz on a linear 6-220 Hz sweep with
    # tapers), "6.0-220.0 Hz ... 220.4".
    for (f0, f1, seconds, taper, expo) in [(6.0, 220.0, 12.0, 0.2, false),
        (6.0, 220.0, 12.0, 0.5, false), (220.0, 6.0, 12.0, 0.5, false),
        (8.0, 80.0, 8.0, 0.1, false), (6.0, 220.0, 12.0, 0.5, true)]:
      var spec = good()
      (spec.f0, spec.f1, spec.seconds, spec.taperS, spec.expo) = (f0, f1, seconds, taper, expo)
      let tag = $f0 & "-" & $f1 & " Hz, taper " & $taper & (if expo: ", exponential" else: "")
      let r = judgeOf(spec, topHz = NaN)
      let top = max(f0, f1)
      doAssert r.band.hz == top and r.band.suggestedHz == top and not r.band.typed and
        not r.band.exact, tag & ": the band is " & $r.band.hz & " (" & $r.band.suggestedHz & ")"
      let again = judgeOf(spec, topHz = NaN)
      doAssert again.band.hz == r.band.hz, tag & ": not the same twice"
      doAssert judgeOf(spec, topHz = 150).band.hz == 150, tag & ": a typed top is not used"

proc noisyBandOf(spec: SynthSweep; noise: float64; spikeAtMs = -1.0): float64 =
  ## The band the reference's own track gives with no top typed, for a reference with
  ## pseudo-random noise of standard deviation `noise` (of the sweep's amplitude 1) all over
  ## the record, and a spike of 0.1 at `spikeAtMs` (when not negative).
  var x = spec.referenceOf.sweepRow
  var seed = 12345'u32
  func next(s: var uint32): float64 =
    s = s * 1664525'u32 + 1013904223'u32
    float64(s shr 8) / 16777216.0
  for j in 0 ..< x.len:
    var g = -6.0
    for k in 0 ..< 12: g += seed.next
    x[j] += float32(noise * g)
  if spikeAtMs >= 0: x[int(spikeAtMs / spec.dtMs)] += 0.1
  let r = vibratorOf(@[x, x], @["R", "GF"], [vsReference: 0, vsGroundForce: 1, vsMass: -1,
    vsBaseplate: -1], spec.dtMs, AnalysisParams(forceHundredPct: 1.0), -1, NaN)
  doAssert r.problem == "", r.problem
  r.band.hz

proc topInNoise() =
  block noise_or_a_spike_outside_the_sweep_does_not_stretch_its_end_taper:
    # Seen to fail: with the extrapolation to the last sample above -40 dB anywhere, a
    # 120 Hz sweep with listen-time noise read 130 Hz, a 220 Hz one 277 Hz, a spike 1.5 s
    # after the sweep 249 Hz, a down sweep with noise before it 130 Hz.
    var up = SynthSweep(f0: 6, f1: 120, seconds: 12, dtMs: 2, taperS: 0.3, tailS: 3)
    doAssert near(noisyBandOf(up, 0.007), 120, 0.5), "120 Hz: " & $noisyBandOf(up, 0.007)
    var high = SynthSweep(f0: 6, f1: 220, seconds: 12, dtMs: 1, taperS: 0.3, tailS: 3)
    doAssert near(noisyBandOf(high, 0.007), 220, 0.5), "220 Hz: " & $noisyBandOf(high, 0.007)
    doAssert near(noisyBandOf(high, 0.0, 13500), 220, 0.5), "spike: " & $noisyBandOf(high, 0.0, 13500)
    var down = SynthSweep(f0: 120, f1: 6, seconds: 12, dtMs: 2, taperS: 0.3, delayMs: 1000,
      tailS: 0)
    doAssert near(noisyBandOf(down, 0.007), 120, 0.5), "down: " & $noisyBandOf(down, 0.007)

    # a clean sweep's end is the reference's own: the top reads as designed (Seen to fail: with
    # the end taken 5 to 8 ms short, these read 149, 149, 199, 99, 99 and 79.5)
    for (f0, f1, seconds, expo, want) in [(5.0, 150.0, 8.0, true, 150.0),
        (150.0, 5.0, 8.0, true, 150.0), (3.0, 200.0, 6.0, true, 200.0),
        (2.0, 100.0, 4.0, true, 100.0), (6.0, 100.0, 0.5, false, 100.0),
        (8.0, 79.6, 8.0, false, 79.6)]:
      var spec = SynthSweep(f0: f0, f1: f1, seconds: seconds, dtMs: 1, taperS: seconds / 10,
        expo: expo)
      # (a sweep of half a second is read to a hundredth, not a thousandth, of its top)
      doAssert near(noisyBandOf(spec, 0.0), want, if seconds < 1: 1.1 else: 0.05),
        $f0 & "-" & $f1 & " Hz: " & $noisyBandOf(spec, 0.0)

proc failingStretchStaysInTheJudgedPart() =
  block the_failing_window_is_not_painted_over_the_taper:
    # Seen to fail: with the whole last window painted, the error-colour curve had points past
    # the judged part's end (7 900 ms) in the taper.
    var spec = good()
    (spec.burstAtS, spec.burstLenS, spec.burstPhaseDeg) = (7.0, 0.8, 30.0)
    let r = judgeOf(spec)
    var painted = 0
    for plot in r.plots:
      for c in plot.curves:
        if c.style == csFail:
          for m in 0 ..< c.ys.len:
            if not c.ys[m].isNaN:
              inc painted
              doAssert plot.xs[m] >= 100 and plot.xs[m] <= 7900, plot.title & ": painted at " &
                $plot.xs[m]
    doAssert painted > 0, "no failing stretch drawn"

proc bandWarningOnCleanSweeps() =
  block clean_sweeps_raise_no_false_top_frequency_warning:
    for (f0, f1, dt) in [(8.0, 110.0, 2.0), (8.0, 110.0, 4.0), (110.0, 8.0, 2.0)]:
      for taper in [0.1, 0.5]:
        var spec = good()
        (spec.f0, spec.f1, spec.dtMs, spec.taperS) = (f0, f1, dt, taper)
        let r = judgeOf(spec, topHz = max(f0, f1))
        doAssert r.band.warning.len == 0, $f0 & "-" & $f1 & " Hz at " & $dt & " ms, taper " &
          $taper & ": " & r.band.warning

proc fractionalShift() =
  block the_stored_reference_is_placed_to_a_fraction_of_a_sample:
    for (delay, dt) in [(100.3, 1.0), (100.5, 1.0), (145.2, 0.5)]:
      var late = good()
      (late.delayMs, late.dtMs, late.phaseDeg) = (delay, dt, 10.0)
      let recorded = late.referenceOf.sweepRow
      let stored = (block:
        var o = late.referenceOf
        o.delayMs = 0
        o.sweepRow)
      let al = alignStored(recorded, stored, dt)
      doAssert al.found and near(al.shiftMs, delay, 0.2), $delay & ": shift " & $al.shiftMs
      let moved = placedSinc(stored, al.shiftMs, dt)
      let r = vibratorOf(@[recorded, late.sweepRow, moved], @["R", "GF", "stored"],
        [vsReference: 2, vsGroundForce: 1, vsMass: -1, vsBaseplate: -1], dt,
        AnalysisParams(forceHundredPct: Hundred), 0, 100.0)
      doAssert r.problem == "", r.problem
      var recordedPhase, gfPhase = NaN
      for x in r.table[1 .. ^1]:
        if x[0] == RecordedRef: recordedPhase = parseFloat(x[3])
        if x[0] == "GF": gfPhase = parseFloat(x[3])
      doAssert recordedPhase < 0.5, $delay & " ms at " & $dt & ": recorded " & $recordedPhase
      doAssert near(gfPhase, 10, 0.5), $delay & " ms at " & $dt & ": GF " & $gfPhase

proc zeroPhaseIsClearOfTheBorder() =
  block a_trace_against_itself_is_a_line_at_zero_above_the_floor:
    let x = good().sweepRow
    let e = envelopeOf(x, "t", 1.0, 0.0, AnalysisParams(), x, "itself", "", true)
    doAssert e.problem == "", e.problem
    var found = false
    for plot in e.plots:
      if plot.title == "Phase against the reference":
        found = true
        doAssert plot.yLo < 0 and plot.yLo > -10, "floor " & $plot.yLo
    doAssert found

proc verdictWords() =
  block a_value_that_reads_as_its_limit_shows_two_decimals:
    let s = WindowSummary(windows: 3, meanAbsPhaseDeg: 5.04, maxAbsPhaseDeg: 5.04,
      maxAbsPhaseAtMs: 1000, meanThdPct: 1, maxThdPct: 1, meanForce: 1000, minForce: 1000,
      maxPeak: 1000)
    let r = judge(s, 500, QcLimits(), 1000)
    doAssert "5.04° > 5°" in r.line, r.line
    # a value that rounds to its limit however long it is cut shows its digits
    let tiny = judge(WindowSummary(windows: 3, meanAbsPhaseDeg: 5.0001, maxAbsPhaseDeg: 5.0001,
      maxAbsPhaseAtMs: 1000, meanThdPct: 1, maxThdPct: 1, meanForce: 1000, minForce: 1000,
      maxPeak: 1000), 500, QcLimits(), 1000)
    doAssert "5.0001° > 5°" in tiny.line, tiny.line
    let low = judge(WindowSummary(windows: 3, meanAbsPhaseDeg: 1, maxAbsPhaseDeg: 1,
      maxAbsPhaseAtMs: 1000, meanThdPct: 1, maxThdPct: 1, meanForce: 899.99, minForce: 899.99,
      maxPeak: 1000), 500, QcLimits(), 1000)
    doAssert "89.999 % < 90 %" in low.line, low.line

proc plotsShowWhatIsJudged() =
  block the_phase_plot_holds_the_judged_signal:
    # the judged signal's curve alone (no limit lines, no window means), the axis fitted to it;
    # with Details the others too, B off the scale and said so
    var spec = good()
    spec.phaseDeg = 2
    var m = good()
    (m.amp, m.phaseDeg) = (1.0, 10.0)
    var b = m
    b.phaseDeg = -170
    let r = fourRows(spec, m, b, AnalysisParams())
    let phase = r.plots[0]
    # (the floor is a little under 0: a line at 0 is not on the plot's border)
    doAssert phase.yLo < 0 and phase.yLo > -3 and phase.yHi >= 13 and phase.yHi < 40,
      $[phase.yLo, phase.yHi]
    var names: seq[string] = @[]
    for c in phase.curves: names.add c.name
    doAssert names == @["GF " & AgainstFile], $names
    var dist: seq[string] = @[]
    for c in r.plots[^1].curves: dist.add c.name
    doAssert dist == @["GF THD"], $dist
    var detailed = AnalysisParams(details: true)
    let all = fourRows(spec, m, b, detailed)
    names = @[]
    for c in all.plots[0].curves: names.add c.name
    doAssert "GF as recorded " & AgainstFile in names and "M" in names and "B" in names and
        "B off scale" in names,
      $names
    for c in all.plots[0].curves: doAssert c.style != csLimit, c.name

func planSweep(seconds = 10.0; f1 = 80.0; tailS = 0.001; delayMs = 0.0; f0 = 8.0;
    taperS = 0.1): SynthSweep =
  ## The file's sweep for the plan tests: `f0` (8) to `f1` Hz in `seconds`, the ground force 1°
  ## off its own pilot.
  SynthSweep(f0: f0, f1: f1, seconds: seconds, tailS: tailS, delayMs: delayMs, amp: 1000,
    phaseDeg: 1, h2: 0.02, taperS: taperS)

proc againstPlan(file: SynthSweep; stored: seq[float32]; p = AnalysisParams();
    pilot: seq[float32] = @[]): AnalysisResult =
  ## The file's ground force against the stored reference `stored` as the window reads it:
  ## the stored samples aligned to the file's recorded pilot (`pilot`, else the file's own
  ## reference), that pilot judged against them.
  let recorded = if pilot.len > 0: pilot else: file.referenceOf.sweepRow
  let al = alignStored(recorded, stored, file.dtMs)
  let placed = if al.found: placedSinc(stored, al.shiftMs, file.dtMs) else: stored
  var q = p
  if q.forceHundredPct.isNaN: q.forceHundredPct = Hundred
  result = vibratorOf(@[recorded, file.sweepRow, placed], @["R", "GF", "stored"],
    [vsReference: 2, vsGroundForce: 1, vsMass: -1, vsBaseplate: -1], file.dtMs, q, 0, 80.0,
    plan = PlanAsk(stored: true, shiftMs: (if al.found: al.shiftMs else: NaN),
      storedRow: stored))
  doAssert result.problem == "", result.problem

proc noisy(x: seq[float32]; share: float64; seed: int64): seq[float32] =
  ## `x` with uniform noise of `share` of its peak (1) added, from `seed`.
  var g = initRand(seed)
  result = x
  for v in result.mitems: v += float32(share * (g.rand(2.0) - 1.0))

func curveOf(r: AnalysisResult; plot: int; name: string): seq[float64] =
  for c in r.plots[plot].curves:
    if c.name == name: return c.ys
  doAssert false, "no curve " & name & " in " & r.plots[plot].title & ": " &
    $r.plots[plot].curves.len

func meanAbs(r: AnalysisResult; ys: seq[float64]): float64 =
  ## The mean |value| of `ys` over the judged part (not dimmed).
  var (sum, n) = (0.0, 0)
  let p = r.plots[0]
  for m in 0 ..< min(p.xs.len, ys.len):
    var dim = false
    for d in p.dimmed:
      if p.xs[m] >= d.a and p.xs[m] <= d.b: dim = true
    if not dim and not ys[m].isNaN:
      sum += abs(ys[m])
      inc n
  if n == 0: NaN else: sum / float64(n)

proc againstThePlan() =
  ## The vibrator window answers whether the vibrator did what it should (the project's
  ## stored reference, the plan), not only what its recorded pilot said.
  ## Seen to fail: with the recorded pilot never judged, "a longer planned sweep fails" read
  ## "✗ FAIL: average phase ..." with no word on the pilot; with the plan's verdict not
  ## applied (`withBasis` keeping the ground force's), "another end frequency" passed the pilot;
  ## with the listen-time test left out, the listen tail warned "the last 2 000 ms of the
  ## reference have no data"; with `recordedPct` not read, "traces shorter than the sweep"
  ## read a clean "✓ PASS"; with the file's reference unit dropped, the phase plot had one line;
  ## with the share taken to the traces' last sample, not the judged part's end, "traces
  ## shorter than the sweep" read 80 % (8 s of 10) where 7.95 s was judged; with every gap
  ## in tenths of a second, "a short gap is said in ms" read "the last 0.0 s".
  block same_sweep_longer_listen_tail_is_no_difference:
    # 12 001 samples stored, the same 10 s sweep and 2 s of listen time: nothing to say
    let file = planSweep()
    let stored = planSweep(tailS = 2.001).referenceOf.sweepRow
    doAssert stored.len == 12001 and file.sweepRow.len == 10001
    let r = againstPlan(file, stored)
    doAssert r.qc.verdict == qvPass, r.qc.line
    doAssert r.qc.plan.compared and r.qc.plan.verdict == qvPass and r.qc.plan.sameSweep,
      r.qc.plan.sweep
    doAssert r.qc.plan.sweep == "" and r.qc.lengthWords == "" and r.qc.recordedPct.isNaN,
      r.qc.line
    doAssert "part recorded" notin r.qc.line and OwnPilotWords notin r.qc.line, r.qc.line
    doAssert r.qc.line.startsWith("✓ PASS"), r.qc.line
    doAssert "have no data" notin r.warning, r.warning
    doAssert "only by time after its sweep" in r.note, r.note
    # both phase lines lie together (the file's reference and the stored one are the same)
    let mine = r.curveOf(0, "GF " & AgainstFile)
    let theirs = r.curveOf(0, "GF " & AgainstStored)
    doAssert abs(r.meanAbs(mine) - r.meanAbs(theirs)) < 0.3,
      $(r.meanAbs(mine), r.meanAbs(theirs))
    doAssert r.qc.plan.fileRows.len == 2 and r.qc.plan.fileRows[0].status == qsPass
  block a_longer_planned_sweep_fails:
    # the user's case: the plan sweeps 8-80 Hz in 12 s (12 001 samples), the file's pilot in
    # 10 s, and the ground force follows its pilot
    let file = planSweep()
    let r = againstPlan(file, planSweep(seconds = 12).referenceOf.sweepRow)
    doAssert r.qc.verdict == qvFail and r.qc.plan.verdict == qvFail, r.qc.line
    doAssert r.qc.line.startsWith("✗ FAIL: the recorded pilot is not the project's " &
      "reference sweep (average phase "), r.qc.line
    doAssert r.qc.plan.sweep == "the project reference sweeps 8-80 Hz in 12.0 s; the " &
      "recorded pilot sweeps 8-80 Hz in 10.0 s", r.qc.plan.sweep
    doAssert r.qc.plan.sweep in r.qc.line, r.qc.line
    # the ground force, which followed the file's 10 s pilot, fails against the plan
    doAssert "FAIL" in r.qc.forceLine and r.qc.rows[ord(qlAvgPhase)].status == qsFail,
      r.qc.forceLine
    doAssert "ground force FAIL: " in r.qc.line, r.qc.line
    doAssert "the last 2.0 s of the reference sweep lie past the end of this file's " &
      "traces: not judged" in r.qc.line, r.qc.line
    # the plots: the phase against the file's reference near zero, against the stored one
    # large; the pilot's own curve drawn without Details (it failed); three frequency lines
    let mine = r.curveOf(0, "GF " & AgainstFile)
    let theirs = r.curveOf(0, "GF " & AgainstStored)
    doAssert r.meanAbs(mine) < 3 and r.meanAbs(theirs) > 20,
      $(r.meanAbs(mine), r.meanAbs(theirs))
    discard r.curveOf(0, RecordedRef)
    var names: seq[string] = @[]
    for c in r.plots[2].curves: names.add c.name
    doAssert names == @[FileRefName, StoredRefName, "GF"], $names
    let fileHz = r.curveOf(2, FileRefName)
    let storedHz = r.curveOf(2, StoredRefName)
    doAssert abs(fileHz[500] - storedHz[500]) > 5, $(fileHz[500], storedHz[500])
    # the limits table has the pilot's rows and the ground force's to the file's reference
    let table = tableOf(r.qc)
    doAssert table.len == 1 + 6 + 2 + 2, $table.len
    doAssert table[7][1] == PlanRowPrefix & "average phase" and table[7][0] == "✗", $table[7]
    doAssert table[9][1] == FileRowPrefix & "average phase" and table[9][0] == "✓", $table[9]
  block another_end_frequency:
    let r = againstPlan(planSweep(), planSweep(f1 = 60).referenceOf.sweepRow)
    doAssert r.qc.plan.verdict == qvFail and r.qc.verdict == qvFail, r.qc.line
    doAssert r.qc.plan.sweep == "the project reference sweeps 8-60 Hz in 10.0 s; the " &
      "recorded pilot sweeps 8-80 Hz in 10.0 s", r.qc.plan.sweep
  block another_start_within_the_alignment_range:
    # the file's sweep begins 500 ms into its record: aligned, passed, the shift kept
    let r = againstPlan(planSweep(delayMs = 500), planSweep().referenceOf.sweepRow)
    doAssert r.qc.verdict == qvPass and r.qc.plan.verdict == qvPass, r.qc.line
    doAssert near(r.qc.plan.shiftMs, 500, 1) and r.qc.plan.sameSweep, $r.qc.plan.shiftMs
  block another_start_beyond_the_alignment_range:
    # 2 600 ms: past the 2 s alignment looks through (it takes a peak at its edge, 1 995 ms),
    # the same sweep out of step: failed, and said
    let r = againstPlan(planSweep(delayMs = 2600), planSweep().referenceOf.sweepRow)
    doAssert r.qc.plan.verdict == qvFail and r.qc.verdict == qvFail, r.qc.line
    doAssert r.qc.plan.sweep.startsWith("the two are the same sweep (8-80 Hz in 10.0 s) but " &
      "not in step: the recorded pilot's sweep starts "), r.qc.plan.sweep
    doAssert "alignment looks no further than 2.0 s either way" in r.qc.line, r.qc.line
  block traces_shorter_than_the_sweep_pass_on_the_part_recorded:
    # the force traces end at 8 s of a 10 s sweep (the pilot and the plan the whole sweep)
    var file = planSweep()
    file.cutAtS = 8
    let r = againstPlan(file, planSweep().referenceOf.sweepRow)
    doAssert r.qc.verdict == qvPass and r.qc.plan.verdict == qvPass, r.qc.line
    # the judged part ends where the last window still lies in the traces (half a 100 ms
    # window before 8 s): 7.95 s of a 10 s sweep
    doAssert near(r.qc.recordedPct, 79.5, 0.2), $r.qc.recordedPct
    doAssert r.qc.line.startsWith("✓ pass on the part recorded (79 % of the reference " &
      "sweep): "), r.qc.line
    doAssert "the last 2.0 s of the reference sweep lie past the end of this file's " &
      "traces: not judged" in r.qc.line, r.qc.line
  block a_short_gap_is_said_in_ms:
    # the traces end 30 ms before the reference sweep: more than one tracked step (10 ms), so
    # part recorded, said in ms ("0.0 s" before)
    var file = planSweep()
    file.cutAtS = 9.97
    let r = againstPlan(file, planSweep().referenceOf.sweepRow)
    doAssert r.qc.verdict == qvPass and not r.qc.recordedPct.isNaN, r.qc.line
    doAssert " ms of the reference sweep lie past the end of this file's traces" in r.qc.line,
      r.qc.line
    doAssert "0.0 s" notin r.qc.line, r.qc.line
  block a_gap_under_one_step_is_whole:
    # 5 ms short of the sweep's end: under one tracked step, the whole sweep
    var file = planSweep()
    file.cutAtS = 9.995
    let r = againstPlan(file, planSweep().referenceOf.sweepRow)
    doAssert r.qc.verdict == qvPass and r.qc.recordedPct.isNaN, r.qc.line
    doAssert r.qc.line.startsWith("✓ PASS") and "part recorded" notin r.qc.line, r.qc.line
  block judged_against_the_files_own_pilot:
    let r = judgeOf(good())
    doAssert r.qc.ownPilot and r.qc.line.endsWith("; " & OwnPilotWords), r.qc.line
    doAssert not r.qc.plan.compared and r.qc.plan.rows.len == 0
    var names: seq[string] = @[]
    for c in r.plots[2].curves: names.add c.name
    doAssert names == @[FileRefName, "GF"], $names

proc sweepTolerances() =
  ## `sweepDifference` on both sides of each tolerance: for the length the most of one tracked
  ## step, 1 % of the planned length and 50 ms; for each end the most of one step's change of
  ## frequency, 0.5 Hz and 1 % of the band.
  ## Seen to fail: with `>=` for `>`, a length 100 ms off read as another sweep; with the
  ## floors left out, a length 11 ms off and a start 0.08 Hz off read as another sweep.
  let plan = SweepShape(startHz: 8, endHz: 80, lengthMs: 10000, startStepHz: 0.072,
    endStepHz: 0.072, stepMs: 10)
  block lengths:
    var pilot = plan
    pilot.lengthMs = 10100
    doAssert sweepDifference(plan, pilot).same
    pilot.lengthMs = 10101
    let d = sweepDifference(plan, pilot)
    doAssert not d.same and d.words == "the project reference sweeps 8-80 Hz in 10.0 s; " &
      "the recorded pilot sweeps 8-80 Hz in 10.1 s", d.words
    doAssert d.readAs == "sweeps read as 8-80 Hz in 10.0 s (the project reference) and " &
      "8-80 Hz in 10.1 s (the recorded pilot)", d.readAs
  block short_sweep_floor:
    # a 2 s sweep: 1 % is 20 ms, the floor 50 ms
    var short = plan
    short.lengthMs = 2000
    var pilot = short
    pilot.lengthMs = 2050
    doAssert sweepDifference(short, pilot).same
    pilot.lengthMs = 2051
    doAssert not sweepDifference(short, pilot).same
  block frequencies:
    # 8-80 Hz: 1 % of the band is 0.72 Hz, more than 0.5 Hz and a step's 0.072 Hz
    var pilot = plan
    pilot.startHz = 8.71
    doAssert sweepDifference(plan, pilot).same
    pilot.startHz = 8.73
    doAssert not sweepDifference(plan, pilot).same
    pilot = plan
    pilot.endHz = 79.29
    doAssert sweepDifference(plan, pilot).same
    pilot.endHz = 79.2
    let d = sweepDifference(plan, pilot)
    doAssert not d.same and "8-79.2 Hz" in d.words, d.words
  block narrow_band_floor:
    # 8-20 Hz: 1 % is 0.12 Hz, the floor 0.5 Hz
    var narrow = plan
    narrow.endHz = 20
    var pilot = narrow
    pilot.endHz = 20.5
    doAssert sweepDifference(narrow, pilot).same
    pilot.endHz = 20.51
    doAssert not sweepDifference(narrow, pilot).same
  block not_compared:
    let d = sweepDifference(SweepShape(why: "too few points of it could be tracked"), plan)
    doAssert not d.same and d.words.startsWith("sweeps not compared: the project " &
      "reference's sweep cannot be read"), d.words

proc sameSweepReadsTheSame() =
  ## The same planned sweep read off a recorded pilot with noise on it, or with another taper,
  ## is the same sweep: no sentence that they differ; a sweep 2 s longer, 2 Hz higher at its
  ## end or 1 Hz higher at its start still differs.
  ## Seen to fail: with the ends read at -40 dB (in the noise), the fit through every tracked
  ## point and one step's frequency (0.07 Hz) the tolerance, 1 % noise on the pilot read
  ## "the recorded pilot sweeps 7.8-80.1 Hz in 10.0 s", 20 % "15.7-81 Hz", and a 0.5 s taper
  ## against 0.1 s "7.7-80 Hz in 10.04 s"; with a difference put in the verdict whatever the
  ## pilot's phase, the linear fade-in read "✓ PASS: 6 of 6 limits met; the project reference
  ## sweeps ..."; with the plan's sweep read off the stored samples as moved to the pilot,
  ## "the plan is read as stored" read "8.4-80 Hz in 9.9 s", a 2 Hz higher end "7.9-82 Hz".
  let base = planSweep().referenceOf.sweepRow
  for (share, seed) in [(0.01, 7'i64), (0.05, 8'i64), (0.2, 9'i64)]:
    let r = againstPlan(planSweep(), base, pilot = noisy(base, share, seed))
    doAssert r.qc.plan.verdict == qvPass and r.qc.verdict == qvPass, r.qc.line
    doAssert r.qc.plan.sameSweep and r.qc.plan.sweep == "", $share & ": " & r.qc.plan.sweep
    doAssert "sweeps" notin r.qc.line and "sweeps read as" notin r.note, r.qc.line
  for taper in [0.25, 0.5, 0.0001]:
    let r = againstPlan(planSweep(taperS = taper), base)
    doAssert r.qc.plan.verdict == qvPass and r.qc.verdict == qvPass, r.qc.line
    doAssert r.qc.plan.sameSweep and r.qc.plan.sweep == "", $taper & ": " & r.qc.plan.sweep
    doAssert "sweeps" notin r.qc.line and "sweeps read as" notin r.note, r.qc.line
  block a_pass_in_phase_keeps_a_reading_in_the_note:
    # a pilot faded in linearly over 2 s (no cos² taper): its ends read 0.4 s apart from the
    # plan's, but it follows the plan in phase. No word in the verdict, a reading in the note
    var pilot = base
    for i in 0 ..< 2000: pilot[i] *= float32(i / 2000)
    let r = againstPlan(planSweep(), base, pilot = pilot)
    doAssert r.qc.plan.verdict == qvPass and r.qc.verdict == qvPass, r.qc.line
    doAssert not r.qc.plan.sameSweep and r.qc.plan.sweep == "", r.qc.plan.sweep
    doAssert "sweeps" notin r.qc.line and "differ" notin r.note, r.qc.line
    doAssert "; sweeps read as 8-80 Hz in 10.0 s (the project reference) and " in r.note, r.note
  block longer:
    let r = againstPlan(planSweep(), planSweep(seconds = 12).referenceOf.sweepRow)
    doAssert not r.qc.plan.sameSweep and r.qc.plan.sweep == "the project reference sweeps " &
      "8-80 Hz in 12.0 s; the recorded pilot sweeps 8-80 Hz in 10.0 s", r.qc.plan.sweep
  block higher_end:
    let r = againstPlan(planSweep(), planSweep(f1 = 82).referenceOf.sweepRow)
    doAssert r.qc.plan.verdict == qvFail and not r.qc.plan.sameSweep, r.qc.line
    doAssert r.qc.plan.sweep == "the project reference sweeps 8-82 Hz in 10.0 s; the " &
      "recorded pilot sweeps 8-80 Hz in 10.0 s", r.qc.plan.sweep
    doAssert r.qc.plan.sweep in r.qc.line, r.qc.line
  block the_plan_is_read_as_stored_not_as_moved:
    # the file sweeps 8-88 Hz in 11 s at the plan's rate: the plan is moved 64 ms earlier to
    # it, which cuts its first 64 ms; the plan is still 8-80 Hz in 10 s
    let r = againstPlan(planSweep(seconds = 11, f1 = 88), base)
    doAssert r.qc.plan.shiftMs < -50, $r.qc.plan.shiftMs
    doAssert r.qc.plan.sweep == "the project reference sweeps 8-80 Hz in 10.0 s; the " &
      "recorded pilot sweeps 8-88 Hz in 11.0 s", r.qc.plan.sweep
  block higher_start:
    let r = againstPlan(planSweep(), planSweep(f0 = 9).referenceOf.sweepRow)
    doAssert r.qc.plan.verdict == qvFail and not r.qc.plan.sameSweep, r.qc.line
    doAssert r.qc.plan.sweep == "the project reference sweeps 9-80 Hz in 10.0 s; the " &
      "recorded pilot sweeps 8-80 Hz in 10.0 s", r.qc.plan.sweep

proc main*() =
  againstThePlan()
  sameSweepReadsTheSame()
  sweepTolerances()
  baseTests()
  judgeChoice()
  fullScalePerSignal()
  targetForce()
  bandWarnings()
  downSweepBand()
  topFromTheReference()
  topInNoise()
  failingStretchStaysInTheJudgedPart()
  bandWarningOnCleanSweeps()
  fractionalShift()
  verdictWords()
  zeroPhaseIsClearOfTheBorder()
  plotsShowWhatIsJudged()

when isMainModule:
  main()
