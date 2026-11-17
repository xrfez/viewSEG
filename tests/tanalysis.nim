## The signal-analysis views' numbers (`core/analysis`), against what is
## known of synthetic traces, worked out apart:
##
## - spectrogram: a linear chirp (20 to 120 Hz over 2 s) peaks, frame by
##   frame, at the frequency it sweeps through at the frame's centre (to a
##   bin), and the image is in dB from its largest amplitude, 0 at the top;
## - envelope: of `A(t)·cos(2π·f·t)` with a slow Gaussian `A`, the envelope
##   is `A` and the instantaneous frequency `f` away from the ends;
## - phase spectrum: an impulse at sample m has the phase `-360·f·m·dt`
##   (degrees, unwrapped) where the amplitude is within the threshold, and
##   none (NaN) where it is not; wrapped, it stays within ±180; of a linear
##   sweep over most of its trace, the unwrapped phase falls all the way
##   and by the sweep's own amount;
## - cross-correlation: a Ricker wavelet delayed 40 ms against itself peaks
##   at +40 ms, scaled by 0.5 its amplitude ratio is -6 dB in band, and
##   none is given where the reference has no energy (past 150 Hz).
##
## - envelope, faded: a 20 to 60 Hz sweep whose amplitude falls 100 dB over
##   its length has no instantaneous frequency where the envelope is 60 dB
##   below its peak (said in the note), and the frequencies it has stay in
##   the sweep's band;
##
## Seen to fail: with the frames' times taken at their start rather than
## their centre, "frame 4: peak 31.25 Hz, the chirp at 17.6"; with the
## instantaneous frequency not divided by the two samples' span, "frequency
## 60.00009145758993 at 1000.0 ms, want 30.0"; with the unwrap's offset not
## kept between bins, "phase at 6.8359375 Hz: 177.89..., want -182.109375";
## with the comparison not cut to the reference's band, "a ratio at 150.39
## Hz: -6.02" (noise read as a ratio); with the phase's transform not
## zero-padded (the power of two past the trace), "the phase rises from
## -102735.49838558499 at 77.63671875 Hz to -102555.57570173252 at
## 77.69775390625 Hz" (the unwrap aliases past half the trace's length).

import std/[math, strutils]
import viewSEG/core/analysis

const DtMs = 2.0

func near(a, b, tol: float64): bool = abs(a - b) <= tol

proc main*() =

  block spectrogramRidge:
    let n = 1001 # 2 s
    var x = newSeq[float32](n)
    let (f0, f1, T) = (20.0, 120.0, 2.0)
    for i in 0 ..< n:
      let t = float64(i) * DtMs / 1000
      x[i] = float32(sin(2 * PI * (f0 * t + (f1 - f0) / (2 * T) * t * t)))
    let r = spectrogramOf([x], DtMs, 0, AnalysisParams(windowMs: 512, overlap: 90))
    doAssert r.problem == "", r.problem
    let img = r.image
    doAssert img.cols > 20 and img.rows > 20, $(img.cols, img.rows)
    var top = -Inf
    for v in img.values: top = max(top, float64(v))
    doAssert near(top, 0, 1e-6), "the image's largest is " & $top & " dB"
    # frames well inside the trace: the peak bin is the chirp's frequency at
    # the frame's centre
    for col in 4 ..< img.cols - 4:
      let t = (img.x0 + float64(col) * img.dx) / 1000
      let want = f0 + (f1 - f0) / T * t
      var best = 0
      for row in 0 ..< img.rows:
        if img.valueAt(col, row) > img.valueAt(col, best): best = row
      let got = img.y0 + float64(best) * img.dy
      doAssert near(got, want, 1.0 * img.dy), "frame " & $col & ": peak " & $got &
        " Hz, the chirp at " & $want
    # two traces: their power average
    let two = spectrogramOf([x, x], DtMs, 0, AnalysisParams())
    doAssert two.image.values == spectrogramOf([x], DtMs, 0, AnalysisParams()).image.values

  block envelopeOfAModulatedCosine:
    let n = 2001
    let f = 30.0
    var x = newSeq[float32](n)
    var a = newSeq[float64](n)
    for i in 0 ..< n:
      let t = float64(i) * DtMs
      a[i] = exp(-(((t - 2000) / 600) ^ 2))
      x[i] = float32(a[i] * cos(2 * PI * f * t / 1000))
    let r = envelopeOf(x, "trace 1", DtMs, 0)
    doAssert r.problem == "" and r.plots.len == 3
    let env = r.plots[0].curves[1].ys
    let freq = r.plots[2].curves[0].ys
    for i in countup(500, 1500, 50):
      doAssert near(env[i], a[i], 0.01), "envelope at " & $(float64(i) * DtMs) & " ms: " &
        $env[i] & ", want " & $a[i]
      doAssert near(freq[i], f, 0.2), "frequency " & $freq[i] & " at " & $(float64(i) * DtMs) &
        " ms, want " & $f
    doAssert r.plots[0].xs[10] == 20.0

  block envelopeWithoutASampleInterval:
    # Seen to fail: "analyticInto" asserts on a sample interval of 0 and the
    # envelope raises instead of reporting the problem.
    let x = @[1'f32, 0, -1, 0, 1, 0, -1, 0]
    let r = envelopeOf(x, "trace", 0.0, 0)
    doAssert r.problem == "the sample interval is not known", r.problem
    doAssert r.plots.len == 0

  block frequencyWhereTheSignalFades:
    # envelope below 0.001 of its peak (60 dB): no frequency; the phase of a
    # signal that is nearly nothing is noise. Seen to fail: with the blanking
    # only where the signal is exactly zero, "frequency 43.55 at 2306.0 ms,
    # where the envelope is 0.00092 of the peak", and no note on the rule.
    let n = 2001
    var x = newSeq[float32](n)
    for i in 0 ..< n:
      let t = float64(i) * DtMs / 1000
      x[i] = float32(exp(-2.88 * t) * cos(2 * PI * (20 * t + 5 * t * t)))
    let r = envelopeOf(x, "sweep", DtMs, 0)
    doAssert r.problem == "", r.problem
    let env = r.plots[0].curves[1].ys
    let freq = r.plots[2].curves[0].ys
    var peak = 0.0
    for e in env: peak = max(peak, e)
    for i in 0 ..< n:
      if env[i] < peak * 0.001:
        doAssert freq[i].isNaN, "frequency " & $freq[i] & " at " & $(float64(i) * DtMs) &
          " ms, where the envelope is " & $(env[i] / peak) & " of the peak"
      elif not freq[i].isNaN:
        doAssert freq[i] in 10.0 .. 70.0, "frequency " & $freq[i] & " at " &
          $(float64(i) * DtMs) & " ms, outside the sweep's band"
    doAssert freq[n - 1].isNaN
    doAssert not freq[n div 4].isNaN and abs(freq[n div 4] - 30) < 1,
      "frequency " & $freq[n div 4] & " at 1000 ms, want 30"
    doAssert "60 dB" in r.note, r.note

  block phaseOfAnImpulse:
    let n = 512
    let m = 37
    var x = newSeq[float32](n)
    x[m] = 1
    # an impulse's amplitude is flat: every bin within 20 dB, the phase a line
    let r = phaseOf(x, "impulse", DtMs, AnalysisParams(phaseWithinDb: 20,
      phasePicture: ppUnwrapped))
    doAssert r.problem == ""
    let hz = r.plots[1].xs
    let ph = r.plots[1].curves[0].ys
    for k in 1 ..< hz.len - 1:
      let want = -360 * hz[k] * float64(m) * DtMs / 1000
      doAssert near(ph[k], want, 1e-3), "phase at " & $hz[k] & " Hz: " & $ph[k] & ", want " & $want
    let wrapped = phaseOf(x, "impulse", DtMs, AnalysisParams(phasePicture: ppSigned))
    var lo, hi = 0.0
    for v in wrapped.plots[1].curves[0].ys:
      if not v.isNaN:
        lo = min(lo, v)
        hi = max(hi, v)
    doAssert hi - lo <= 360 + 1e-3, "the signed picture spans a turn at most: " & $(lo, hi)
    # a band-limited pulse: no phase where its amplitude is 20 dB under its peak
    var y = newSeq[float32](n)
    for i in 0 ..< n:
      let t = (float64(i - 200) * DtMs / 1000) * PI * 25
      y[i] = float32((1 - 2 * t * t) * exp(-t * t)) # a 25 Hz Ricker
    let rp = phaseOf(y, "ricker", DtMs, AnalysisParams(phaseWithinDb: 20))
    let db = rp.plots[0].curves[0].ys
    let yp = rp.plots[1].curves[0].ys
    var shown, hidden = 0
    for k in 0 ..< db.len:
      if db[k] >= -20:
        doAssert not yp[k].isNaN
        inc shown
      else:
        doAssert yp[k].isNaN, "a phase at " & $db[k] & " dB"
        inc hidden
    doAssert shown > 5 and hidden > 5, $(shown, hidden)
    doAssert unwrapWhere([170.0, -170, -150, 170], [true, true, true, true]) ==
      @[170.0, 190, 210, 170]

  block phaseOfALongSweep:
    # A linear up-sweep (8 to 110 Hz) over 12 s of a 12.5 s trace: frequency
    # f arrives at t(f) = 12·(f - 8)/102 s, so the phase falls with
    # frequency all the way (its slope is -360°·t(f)), steeper and steeper,
    # past half the trace's length: the unwrap must not alias there.
    let n = 6251
    let (f0, f1, T) = (8.0, 110.0, 12.0)
    var x = newSeq[float32](n)
    for i in 0 ..< n:
      let t = float64(i) * DtMs / 1000
      if t <= T:
        let taper = min(1.0, min(t, T - t) / 0.25) # 250 ms ramps
        x[i] = float32(taper * sin(2 * PI * (f0 * t + (f1 - f0) / (2 * T) * t * t)))
    let r = phaseOf(x, "sweep", DtMs, AnalysisParams(phaseWithinDb: 20,
      phasePicture: ppUnwrapped))
    doAssert r.problem == "", r.problem
    let hz = r.plots[1].xs
    let ph = r.plots[1].curves[0].ys
    var last = NaN
    var lastHz = NaN
    var shown = 0
    for k in 0 ..< hz.len:
      if not ph[k].isNaN:
        inc shown
        if not last.isNaN:
          doAssert ph[k] < last, "the phase rises from " & $last & " at " & $lastHz &
            " Hz to " & $ph[k] & " at " & $hz[k] & " Hz"
        (last, lastHz) = (ph[k], hz[k])
    doAssert shown > 100, $shown & " bins shown"
    # and it is the sweep's: from 12 to 100 Hz it falls by 360°·∫t(f)df,
    # within 1 %
    var at100 = -1
    for k in 0 ..< hz.len:
      if at100 < 0 and hz[k] >= 100: at100 = k
    var firstK = -1
    for k in 0 ..< hz.len:
      if firstK < 0 and not ph[k].isNaN and hz[k] >= 12: firstK = k
    proc integral(f: float64): float64 = T * (f - f0) * (f - f0) / (2 * (f1 - f0))
    let want = -360 * (integral(hz[at100]) - integral(hz[firstK]))
    let got = ph[at100] - ph[firstK]
    doAssert abs(got - want) < 0.01 * abs(want), "the phase falls " & $got & "° from " &
      $hz[firstK] & " to " & $hz[at100] & " Hz, the sweep's " & $want & "°"

  block correlationLag:
    let n = 1001
    var r, s, half = newSeq[float32](n)
    for i in 0 ..< n:
      let t = (float64(i - 300) * DtMs / 1000) * PI * 25
      r[i] = float32((1 - 2 * t * t) * exp(-t * t))
    for i in 0 ..< n:
      let j = i - 20 # 40 ms later
      s[i] = if j >= 0: r[j] else: 0
      half[i] = 0.5'f32 * r[i]
    let c = correlationOf([("delayed", s), ("half", half)], r, "the reference", DtMs,
      AnalysisParams(maxLagMs: 200))
    doAssert c.problem == "", c.problem
    doAssert c.plots.len == 3 and c.plots[0].curves.len == 4
    doAssert near(c.peakLagMs(0), 40, 1e-9), "peak at " & $c.peakLagMs(0) & " ms, want 40"
    doAssert near(c.peakLagMs(1), 0, 1e-9)
    # the half-amplitude copy: -6.02 dB where the reference has energy
    let hz = c.plots[1].xs
    let ratio = c.plots[1].curves[1].ys
    for k in 0 ..< hz.len:
      if hz[k] >= 15 and hz[k] <= 40:
        doAssert near(ratio[k], 20 * log10(0.5), 0.05), "ratio at " & $hz[k] & " Hz: " & $ratio[k]
    # where the reference has no energy (a 25 Hz Ricker at 150 Hz): no ratio, no phase
    for k in 0 ..< hz.len:
      if hz[k] >= 150:
        doAssert ratio[k].isNaN and c.plots[2].curves[1].ys[k].isNaN, "a ratio at " & $hz[k] &
          " Hz: " & $ratio[k]

  echo "tanalysis: ok"

when isMainModule:
  main()
