## The one rule for a phase or a phase difference (`core/phaseshow`): Absolute is the
## size, 0 to 180; Signed is within 180 either side of the circular mean, so a
## reversed trace is flat at 180 and never alternates with -180. Checked on the rule,
## and on the plots that use it: the envelope's phase against the reference, the
## correlation's phase difference, and the vibrator's options kept with the plot.
##
## Seen to fail: with `shownPhase` returning `wrapTurn(v)` for Signed (the old wrapped
## picture), "signed is flat at 180" saw 180 and -180 alternate; with Absolute
## returning the signed value, "absolute never goes below 0" failed.

import std/[math, strutils]
import viewSEG/core/[analysis, phaseshow, plotoptions]

proc main*() =
  block rule:
    let alternating = [179.5, -179.5, 179.9, -179.9, 180.0, -180.0]
    let a = shownPhase(alternating, psAbsolute)
    for v in a.ys: doAssert v >= 0 and v <= 180, "absolute never goes below 0: " & $v
    let s = shownPhase(alternating, psSigned)
    for v in s.ys:
      doAssert abs(abs(v) - 180) < 1.0 and v * s.ys[0] > 0, "signed is flat at 180: " & $v
    let near0 = shownPhase([1.0, -1.0, 0.5], psSigned)
    for k, v in [1.0, -1.0, 0.5]:
      doAssert abs(near0.ys[k] - v) < 1e-9, "around 0 the signed value is as it was"
    doAssert shownPhase([NaN, 10.0], psSigned).ys[0].isNaN
    doAssert meanText([10.0, -20.0], psAbsolute) == "mean |phase| 15.0°"
    doAssert meanText([179.0, -179.0], psSigned) in ["mean 180.0°", "mean -180.0°"]
    doAssert meanText([NaN], psSigned) == ""

  block envelopeReversed:
    var sweep = newSeq[float32](2000)
    for i in 0 ..< sweep.len:
      let t = float64(i) * 0.002
      sweep[i] = float32(sin(2 * PI * (8 * t + 12 * t * t)))
    var rev = newSeq[float32](sweep.len)
    for i in 0 ..< sweep.len: rev[i] = -sweep[i] + float32(0.001 * sin(float64(i)))
    for mode in PhaseShow:
      let r = envelopeOf(rev, "rev", 2.0, 0.0, AnalysisParams(phaseShow: mode), sweep, "ref")
      var n = 0
      var first = 0.0
      for v in r.plots[1].curves[0].ys:
        if not v.isNaN:
          inc n
          if n == 1: first = v
          doAssert abs(abs(v) - 180) < 10 and v * first > 0,
            $mode & " is flat near 180, not alternating: " & $v
      doAssert n > 500
      doAssert ("|phase|" in r.plots[1].aside) == (mode == psAbsolute), r.plots[1].aside

  block correlationItself:
    var x = newSeq[float32](1000)
    var seed = 12345'u32
    for i in 0 ..< x.len: # broadband, so many bins carry a phase
      seed = seed * 1664525'u32 + 1013904223'u32
      x[i] = float32(int(seed shr 16) mod 2001 - 1000) / 1000

    var y = x
    for i in 0 ..< y.len: y[i] = -x[i] # reversed
    for mode in PhaseShow:
      let r = correlationOf([("rev", y)], x, "ref", 2.0, AnalysisParams(phaseShow: mode))
      doAssert r.problem == "", r.problem
      var n, near = 0
      for v in r.plots[2].curves[0].ys:
        if not v.isNaN:
          inc n
          if abs(abs(v) - 180) < 30: inc near
          if mode == psAbsolute: doAssert v >= 0 and v <= 180, $v
      doAssert n > 5 and near * 10 >= n * 9, $mode & ": " & $(near, n)
      doAssert r.table[0][4] == (if mode == psAbsolute: "Mean |phase| (°)"
        else: "Phase, circular mean (°)")

  block options:
    var p = AnalysisParams(phaseShow: psSigned)
    var o = PlotOptions()
    for v in [avEnvelope, avCorrelation, avVibrator]:
      o.remember(v, p)
      doAssert o.applied(v, AnalysisParams()).phaseShow == psSigned, $v
      doAssert builtin(v, p).phaseShow == psAbsolute, "Reset options: Absolute, " & $v

when isMainModule: main()
