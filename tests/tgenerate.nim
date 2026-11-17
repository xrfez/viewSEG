## Generate a reference: taper shape, phase, a preview that keeps every peak,
## and settings an older archive does not name.
##
## Seen to fail: with `columnEnvelope` taking every Nth sample again, the
## column extremes were not the samples' min and max; with `sweepSpec`
## forcing cosine squared, "tpLinear is not processSEG's sweep"; with the
## phase forced to zero, "a quarter-cycle phase matches a phase of zero";
## with `spectrumAxis` returning 0 .. Nyquist, "axis is not the band plus
## a margin: (lo: 0.0, hi: 1000.0)"; with a field formatted `%.4g`,
## "6.000e+04" instead of "60000"; with the first column's extreme pinned
## to t=0, "t=0 shows" a later peak instead of the true sample; with a
## negative taper clamped to 0, "got \"\"" instead of processSEG's message.

import std/[json, math, os, strutils]
import processSEG/fft/spectrum
import processSEG/vibroseis/[sweep, taper]
import viewSEG/core/[references, state]
import viewSEG/view/curveplot
import viewSEG/remote/schema

proc tempDir(): string =
  result = getTempDir() / "viewSEG-tgenerate-" & $getCurrentProcessId()
  createDir(result)

proc removeTemp(dir: string) =
  if dirExists(dir): removeDir(dir)

proc base(): GeneratedReference =
  GeneratedReference(law: rlLinear, f1Hz: 8, f2Hz: 40, durationMs: 1000, dtMs: 2,
    taperStartMs: 200, taperEndMs: 200, amplitude: 1, taperShape: tpCos2)

proc main*() =
  block envelope_keeps_every_peak:
    # A stride of 4 lands on the zeros of this sine. Skipping samples draws
    # a flat line; the column envelope must not.
    var s = newSeq[float32](1000)
    for i in 0 ..< s.len:
      s[i] = float32(sin(PI / 2 * float64(i)))
    let env = columnEnvelope(s, 0.0, 1.0, 40)
    var peak = 0.0
    for v in env.ys: peak = max(peak, abs(v))
    doAssert peak > 0.99, "the envelope dropped the peaks, got " & $peak
    doAssert env.xs[0] == 0.0, "the envelope does not start at the first sample"
    doAssert abs(env.xs[^1] - 999.0) < 1e-6, "the envelope does not reach the last sample"
    let n = max(1, (s.len + 39) div 40)
    var i = 0
    var b = 0
    while i < s.len:
      var lo = Inf
      var hi = -Inf
      let up = min(s.len, i + n)
      for j in i ..< up:
        lo = min(lo, float64(s[j]))
        hi = max(hi, float64(s[j]))
      let y0 = env.ys[1 + b * 2]
      let y1 = env.ys[2 + b * 2]
      doAssert abs(y0) == lo or abs(y0) == hi or y0 == lo or y0 == hi
      doAssert min(y0, y1) <= lo + 1e-5
      doAssert max(y0, y1) >= hi - 1e-5
      inc b
      i = up

  block a_long_sweep_is_whole:
    let g = GeneratedReference(law: rlLinear, f1Hz: 10, f2Hz: 40, durationMs: 60_000,
      dtMs: 0.5, taperStartMs: 500, taperEndMs: 500, amplitude: 1, taperShape: tpCos2)
    let samples = generateSamples(g)
    doAssert samples.len == 120_001, $samples.len
    let env = columnEnvelope(samples, 0.0, g.dtMs, 800)
    doAssert env.xs[0] == 0.0
    doAssert abs(env.xs[^1] - 60_000.0) < 1e-3, "the preview is not the whole sweep"
    doAssert abs(env.ys[0]) < 0.05, "the start taper is not in the preview"
    doAssert abs(env.ys[^1]) < 0.05, "the end taper is not in the preview"
    var mid = 0.0
    for i in env.ys.len div 3 ..< env.ys.len * 2 div 3:
      mid = max(mid, abs(env.ys[i]))
    doAssert mid > 0.9, "the middle of the sweep was lost, got " & $mid

  block ends_are_the_true_samples:
    # 60 s at 0.5 ms, 200 ms tapers, 400 columns: a column is wider than the
    # taper. Pinning a later extreme to t=0 shows that peak, not the sample.
    let g = GeneratedReference(law: rlLinear, f1Hz: 8, f2Hz: 80, durationMs: 60_000,
      dtMs: 0.5, taperStartMs: 200, taperEndMs: 200, amplitude: 1, taperShape: tpCos2)
    let samples = generateSamples(g)
    let env = columnEnvelope(samples, 0.0, g.dtMs, 400)
    doAssert env.xs[0] == 0.0
    doAssert abs(env.xs[^1] - 60_000.0) < 1e-3
    doAssert abs(env.ys[0] - float64(samples[0])) < 1e-4,
      "t=0 shows " & $env.ys[0] & " not the true sample " & $samples[0]
    doAssert abs(env.ys[^1] - float64(samples[^1])) < 1e-4,
      "t=end shows " & $env.ys[^1] & " not the true sample " & $samples[^1]
    doAssert abs(float64(samples[0])) < 1e-3, "the taper does not start at 0"
    doAssert abs(float64(samples[^1])) < 1e-3, "the taper does not end at 0"

  block each_shape_is_processSEG:
    var previous: seq[float32] = @[]
    for shape in TaperShape:
      let param = taperDefaultParam(shape)
      doAssert (param.isNaN) == (taperParamLabel(shape).len == 0), $shape
      var g = base()
      g.taperShape = shape
      g.taperParam = param
      let made = generateSamples(g)
      let hand = linearSweep(g.f1Hz, g.f2Hz, g.durationMs, g.dtMs,
        initSweepTaper(g.taperStartMs, g.taperEndMs, shape, param),
        amplitude = 1.0).sweepSamples(float32)
      doAssert made == hand, $shape & " is not processSEG's sweep"
      if previous.len > 0:
        doAssert made != previous, $shape & " matches the previous shape"
      previous = made
    doAssert initSweepTaper(0.0, 0.0).shape == (GeneratedReference()).taperShape,
      "the default shape is not processSEG's"

  block phase_is_processSEG:
    var g = base()
    g.taperStartMs = 0
    g.taperEndMs = 0
    let zero = generateSamples(g)
    g.phaseDeg = 90
    let quarter = generateSamples(g)
    doAssert quarter != zero, "a quarter-cycle phase matches a phase of zero"
    let hand = linearSweep(g.f1Hz, g.f2Hz, g.durationMs, g.dtMs,
      initSweepTaper(0.0, 0.0, g.taperShape), startPhaseDeg = 90,
      amplitude = 1.0).sweepSamples(float32)
    doAssert quarter == hand, "a phase of 90 degrees is not the direct sweep"
    g.phaseDeg = 180
    let flipped = generateSamples(g)
    var worst = 0.0
    for i in 0 ..< zero.len:
      worst = max(worst, abs(flipped[i] + zero[i]))
    doAssert worst < 1e-4, "a reversed phase is not the negated sweep, off by " & $worst

  block a_negative_taper_is_refused:
    var g = base()
    g.taperStartMs = -10
    let why = generateProblem(g)
    var hand = ""
    try:
      discard initSweepTaper(-10.0, g.taperEndMs, g.taperShape, g.taperParam)
    except ValueError as e:
      hand = e.msg
    doAssert hand.len > 0, "processSEG accepted a negative taper"
    doAssert why == hand, "got \"" & why & "\", processSEG says \"" & hand & "\""
    g.taperStartMs = 200
    g.taperEndMs = -5
    let endWhy = generateProblem(g)
    doAssert "endMs" in endWhy, endWhy
    g.taperStartMs = NaN
    g.taperEndMs = NaN
    doAssert generateProblem(g).len == 0, "NaN is a taper, not none: " & generateProblem(g)

  block an_invalid_parameter_makes_nothing:
    var g = base()
    g.taperShape = tpKaiser
    g.taperParam = -1
    let why = generateProblem(g)
    doAssert why.len > 0, "an invalid beta was accepted"
    let preview = buildGeneratePreview(g)
    doAssert preview.problem == why
    doAssert preview.samples.len == 0, "an invalid parameter still made samples"
    doAssertRaises ValueError:
      discard generateSamples(g)
    g.phaseDeg = Inf
    g.taperParam = 6
    doAssert "phase" in generateProblem(g), generateProblem(g)

  block a_field_is_a_plain_number:
    doAssert plainFieldText(60000) == "60000", plainFieldText(60000)
    doAssert plainFieldText(10000) == "10000", plainFieldText(10000)
    doAssert plainFieldText(0.5) == "0.5", plainFieldText(0.5)
    doAssert plainFieldText(2.0) == "2"
    doAssert plainFieldText(-10.0) == "-10"
    doAssert plainFieldText(8.25) == "8.25", plainFieldText(8.25)
    doAssert plainFieldText(1e7) == "10000000", plainFieldText(1e7)
    doAssert 'e' notin plainFieldText(0.00001)
    doAssert 'g' notin plainFieldFormat(60000)
    doAssert 'e' notin plainFieldFormat(1e7)
    for v in [0.0, 1.0, 8.0, 90.0, 180.0, 200.0, 0.25, 6.5, 0.4]:
      doAssert 'e' notin plainFieldText(v), plainFieldText(v)

  block spectrum_axis_fits_the_band:
    # 8–80 Hz on a 0.5 ms sweep (Nyquist 1000 Hz) must not be a sliver of
    # 0..1000. A quarter of the 72 Hz band is 18 Hz on each side.
    let wide = spectrumAxis(8, 80, 1000)
    doAssert abs(wide.lo - 0.0) < 1e-9, $wide
    doAssert abs(wide.hi - 98.0) < 1e-6, "axis is not the band plus a margin: " & $wide
    doAssert wide.hi < 200, "the axis still runs to Nyquist"
    let mid = spectrumAxis(100, 200, 1000)
    doAssert abs(mid.lo - 75.0) < 1e-6 and abs(mid.hi - 225.0) < 1e-6, $mid
    doAssert spectrumAxis(200, 100, 1000) == mid, "a downsweep does not use the same band"
    let high = spectrumAxis(400, 800, 1000)
    doAssert abs(high.lo - 300.0) < 1e-6 and abs(high.hi - 900.0) < 1e-6, $high
    let capped = spectrumAxis(8, 80, 90)
    doAssert capped.lo >= 0 and capped.hi <= 90 and capped.hi > capped.lo, $capped
    doAssert spectrumFitKey(1, 8, 80, 1000) != spectrumFitKey(1, 8, 40, 1000),
      "changing the end frequency does not refit the axis"
    var plotted = CurvePlot(xs: @[0.0, 1000.0], xFloor: wide.lo, xCeil: wide.hi,
      curves: @[Curve(ys: @[0.0, -120.0])])
    doAssert abs(plotted.xLimits.lo - wide.lo) < 1e-9 and
      abs(plotted.xLimits.hi - wide.hi) < 1e-6, $plotted.xLimits

  block spectrum_is_processSEG:
    let g = base()
    let samples = generateSamples(g)
    let shown = previewSpectrum(samples, g.dtMs)
    let spec = amplitudeOf(samples, g.dtMs)
    var db = newSeq[float64](spec.amp.len)
    toDbInto(spec.amp, db)
    doAssert shown.hz == spec.hz
    doAssert shown.db == db, "the preview spectrum is not processSEG's"
    doAssert shown.db.len > 2 and shown.db[0] <= 0.0

  block an_older_archive_keeps_the_old_sweep:
    let dir = tempDir()
    let folder = referencesFolder(dir)
    createDir(folder)
    writeFile(indexPath(folder), """(.nif27)
(references
  (version 1)
  (entry (id "rold") (name "old sweep") (intervalUs 2000.0) (samples 501)
    (date "2026-01-01T00:00:00Z") (file "rold.sgy")
    (source (generated true) (law "linear") (f1Hz 8.0) (f2Hz 40.0)
      (durationMs 1000.0) (dtMs 2.0) (taperStartMs 200.0) (taperEndMs 200.0)
      (amplitude 1.0) (boostDb 0.0))))
""")
    let index = loadIndex(folder)
    doAssert index.entries.len == 1, $index.problems
    let o = index.entries[0].origin
    doAssert o.generated and o.taperShape == tpCos2, "an older archive is not cosine squared"
    doAssert o.phaseDeg == 0.0 and o.taperParam.isNaN
    var g = GeneratedReference(law: o.law, f1Hz: o.f1Hz, f2Hz: o.f2Hz,
      durationMs: o.durationMs, dtMs: o.dtMs, taperStartMs: o.taperStartMs,
      taperEndMs: o.taperEndMs, taperShape: o.taperShape, taperParam: o.taperParam,
      phaseDeg: o.phaseDeg, amplitude: o.amplitude, boostDb: o.boostDb)
    let made = generateSamples(g)
    let hand = linearSweep(8, 40, 1000, 2, initSweepTaper(200, 200),
      amplitude = 1.0).sweepSamples(float32)
    doAssert made == hand, "an older archive does not generate the sweep it used to"
    let id = storeSamples(folder, "kept shape", g.dtMs * 1000, made,
      ReferenceOrigin(generated: true, law: g.law, f1Hz: g.f1Hz, f2Hz: g.f2Hz,
        durationMs: g.durationMs, dtMs: g.dtMs, taperStartMs: 200, taperEndMs: 200,
        taperShape: tpKaiser, taperParam: 8, phaseDeg: 180, amplitude: 1))
    let back = loadIndex(folder)
    let i = back.findId(id)
    doAssert i >= 0 and back.entries[i].origin.taperShape == tpKaiser
    doAssert back.entries[i].origin.taperParam == 8
    doAssert back.entries[i].origin.phaseDeg == 180
    removeTemp(dir)

  block the_tool_keeps_the_defaults:
    var c = newCommand(ckGenerateReference)
    var problems: seq[string] = @[]
    decodeFields(%*{"refGenerate": {"name": "agent sweep", "law": "linear", "f1Hz": 8,
      "f2Hz": 40, "durationMs": 1000, "dtMs": 2, "amplitude": 1}}, c, problems)
    doAssert problems.len == 0, $problems
    doAssert c.refGenerate.taperShape == tpCos2
    doAssert c.refGenerate.phaseDeg == 0.0
    doAssert c.refGenerate.taperParam.isNaN
    decodeFields(%*{"refGenerate": {"taperShape": "tpKaiser", "taperParam": 8,
      "phaseDeg": 180}}, c, problems)
    doAssert problems.len == 0, $problems
    doAssert c.refGenerate.taperShape == tpKaiser
    doAssert c.refGenerate.taperParam == 8
    doAssert c.refGenerate.phaseDeg == 180
    doAssert c.refGenerate.f1Hz == 8, "a later field wiped the ones already read"

  echo "tgenerate: ok"

when isMainModule: main()
