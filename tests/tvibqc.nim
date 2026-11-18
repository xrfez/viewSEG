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
## Seen to fail: with the window statistics left at the point maxima (judged part and
## `windowStats` unused), "the peak phase of a stretch of 25 degrees" read 30 for the peak
## and the average phase test of the 8 degree sweep still passed but the window-average
## tests did not; with `toMs` not set for a short trace, "a cut trace is judged to its end"
## failed (mean force 62 % for 100 %); with the fundamental's cut ignored, "no false signal
## ends at 2 ms" failed; with the stored reference unplaced, "aligned: the recorded
## reference measures 0 degrees" failed (90 degrees mean).
##
## Peak values read a little higher or lower with processSEG 0.8.0's 16-tap peak
## interpolator; the tolerances below (1 %) are its error, not the old 8-tap one.

import std/[math, strutils]
import viewSEG/core/[analysis, vibalign, vibanalysis, vibjudge]
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

proc main*() =
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
    for x in r.qc.tableOf[1 .. ^1]: doAssert x[3] == "✓", $x
    # the tapers are dimmed on every plot and left out of the judged part
    for p in r.plots:
      doAssert p.dimmed.len == 2, p.title & ": " & $p.dimmed
    doAssert "judged from" in r.note and "the sweep less its tapers" in r.note, r.note

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
    # D9: skips of 1000 ms are not "the sweep less its tapers"
    var p = AnalysisParams(limitsOn: true)
    p.limits.skipStartMs = 1000
    p.limits.skipEndMs = 1000
    let r = judgeOf(good(), p)
    doAssert "less 1000 ms at its start and 1000 ms at its end" in r.note, r.note
    doAssert "less its tapers" notin r.note, r.note
    let tapers = judgeOf(good())
    doAssert "less its tapers" in tapers.note

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
    # (the chord reads a little under the top: 3 % on this short, steep sweep: said)
    doAssert own.band.warning.len > 0
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
    doAssert "% from the largest frequency measured" in off.band.warning,
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
    let moved = stored.placed(int(round(al.shiftMs)))
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

when isMainModule:
  main()
