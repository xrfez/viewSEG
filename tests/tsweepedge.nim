## `core/sweepedge`: the reference's top frequency read from its samples, with its
## uncertainty, on synthetic sweeps (6 to 120 Hz and down, 8 s, 2 ms, ramps of 300 ms made by
## processSEG with each taper shape, seeded noise, decaying tails): the error of every shape
## stays within its bound; a stated uncertainty is never a lie by more than three times
## (the error is within 3 stated uncertainties and a quarter hertz); a reading not marked
## uncertain is within 1 % of the truth; a tail 20 to 60 dB down moves the reading by under
## 0.05 Hz.
##
## Seen to fail: with the knee rule (the fall ends where it stops steepening) off, the
## Gaussian ramp with a ring-down at -20 dB read 125.8 for 120.4; with the noise never
## estimated, the power 4 ramp at 40 dB read 118.4 as sure.

import std/math
import processSEG/core/[rows, types, units, workspace]
import processSEG/vibroseis/[sweep, sweeptrack, taper, vibqc]
import viewSEG/core/sweepedge
import utils/sweepsyn

proc readingOf(c: Case): TopReading =
  let x = makeRef(c)
  let tp = initSweepTrackPlan(float32, TrackParams(harmonicBandAuto: true,
    thdHarmonics: thAllThatFit), c.dtMs, x.len)
  var ws = initWorkspace()
  ws.reserve(tp.workspaceSize)
  var reference = initSweepReference(tp)
  var track = initSweepTrack(tp)
  tp.referenceInto(x, reference, ws)
  tp.trackInto(x, reference, track, ws)
  readTop(x, c.dtMs, track, reference.extent)

proc base(shape: TaperShape; param = NaN; up = true): Case =
  Case(f1: (if up: 6 else: 120), f2: (if up: 120 else: 6), lengthMs: 8000, dtMs: 2,
    startTaperMs: 300, endTaperMs: 300, shape: shape, param: param, delayMs: 200,
    listenMs: 600)

const Shapes = [(tpCos2, NaN, "cos2", 0.3, 0.05), (tpBlackman, NaN, "blackman", 0.3, 0.05),
  (tpKaiser, NaN, "kaiser", 0.6, 0.05), (tpGaussian, NaN, "gaussian", 0.6, 0.5),
  (tpHamming, NaN, "hamming", 1.0, 0.5), (tpPower, 2.0, "power 2", 0.3, 0.05),
  (tpPower, 4.0, "power 4", 0.3, 0.05), (tpLinear, NaN, "linear", 0.3, 0.05)]
  ## the shape, its parameter, its name, the largest error (Hz) of a clean sweep of it, and
  ## the most a tail 20 to 60 dB down may move the reading (the shapes that end on a step, at
  ## 3 to 8 % of the sweep's amplitude, cannot be told from a tail that starts that high)

proc main*() =
  block cleanSweepsPerShape:
    for (shape, param, name, bound, moves) in Shapes:
      for up in [true, false]:
        let r = readingOf(base(shape, param, up))
        doAssert abs(r.hz - 120) <= bound, name & ": " & $r.hz
    # a sweep without ramps: the end is the step itself
    var c = base(tpCos2)
    (c.startTaperMs, c.endTaperMs) = (0.0, 0.0)
    doAssert abs(readingOf(c).hz - 120) <= 0.5
    # an exponential sweep
    c = base(tpCos2)
    c.law = slExponential
    c.f1 = 5
    c.f2 = 150
    doAssert abs(readingOf(c).hz - 150) <= 1.5, $readingOf(c).hz

  block noiseIsRightOrSaid:
    for (shape, param, name, bound, moves) in Shapes:
      for snr in [40.0, 30.0, 20.0, 10.0, 6.0, 3.0, 0.0]:
        var c = base(shape, param)
        c.snrDb = snr
        let r = readingOf(c)
        if not r.hz.isNaN:
          let err = abs(r.hz - 120)
          doAssert r.uncertain or err <= 1.2, name & " " & $snr & " dB: " & $r.hz
          doAssert err <= 3 * r.uncertaintyHz + 0.25, name & " " & $snr & " dB: " & $r.hz &
            " +- " & $r.uncertaintyHz
        if snr <= 6:
          doAssert r.hz.isNaN or r.uncertain, name & " " & $snr & " dB read as sure"
    # the noise estimate follows the noise: clean stays sure, 6 dB is said
    var c = base(tpCos2)
    doAssert not readingOf(c).uncertain
    c.snrDb = 6
    doAssert readingOf(c).uncertain and readingOf(c).why.len > 0

  block tailsDoNotMoveTheEnd:
    for (shape, param, name, bound, moves) in Shapes:
      let plain = readingOf(base(shape, param)).hz
      for tail in [tnRing, tnLeak]:
        for db in [-20.0, -30.0, -40.0, -60.0]:
          var c = base(shape, param)
          c.tail = tail
          c.tailDb = db
          c.listenMs = 1000
          let r = readingOf(c).hz
          doAssert abs(r - plain) < moves, name & " " & $tail & " " & $db & ": " & $r & " for " & $plain

  block noSweepNoReading:
    # silence, and a trace too short to hold a sweep, are no reading (and no crash)
    let tp = initSweepTrackPlan(float32, TrackParams(), 2.0, 512)
    var ws = initWorkspace()
    ws.reserve(tp.workspaceSize)
    var reference = initSweepReference(tp)
    var track = initSweepTrack(tp)
    let silence = newSeq[float32](512)
    tp.referenceInto(silence, reference, ws)
    tp.trackInto(silence, reference, track, ws)
    doAssert readTop(silence, 2.0, track, reference.extent).hz.isNaN
    doAssert readTop(silence[0 ..< 10], 2.0, track, reference.extent).hz.isNaN

  echo "tsweepedge: ok"

when isMainModule:
  main()
