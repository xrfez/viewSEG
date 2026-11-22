## `core/sweepedge`: the reference's top frequency read from its samples, with its
## uncertainty, on synthetic sweeps (6 to 120 Hz and down, 8 s, 2 ms, ramps of 300 ms made by
## processSEG with each taper shape, seeded noise, decaying tails): the error of every shape
## stays within its bound; a stated uncertainty is never a lie by more than three times
## (the error is within 3 stated uncertainties and a quarter hertz); a reading not marked
## uncertain is within 1 % of the truth; a tail 20 to 60 dB down moves the reading by under
## 0.05 Hz.
##
## Seen to fail: with the end not kept at or past the last point fitted, `notBefore`'s own
## assertions; with the shapes weighted by the best one alone, "kaiser tnRing -20.0: 120.73"
## moving the reading; with the law always a line in f, the exponential sweep read 138 for 150;
## with the knee rule off, a Gaussian ramp with a ring-down at -20 dB read 125.8 for 120.4;
## with the noise never estimated, a power 4 ramp at 40 dB read 118.4 as sure.

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

const Shapes = [(tpCos2, NaN, "cos2", 0.3, 0.3), (tpBlackman, NaN, "blackman", 0.3, 0.3),
  (tpKaiser, NaN, "kaiser", 0.6, 0.3), (tpGaussian, NaN, "gaussian", 0.6, 0.5),
  (tpHamming, NaN, "hamming", 1.0, 0.5), (tpPower, 2.0, "power 2", 0.3, 0.3),
  (tpPower, 4.0, "power 4", 0.3, 0.3), (tpLinear, NaN, "linear", 0.3, 0.3)]
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
          let r = readingOf(c)
          doAssert r.uncertain or abs(r.hz - plain) < moves, name & " " & $tail & " " & $db &
            ": " & $r.hz & " for " & $plain & " as sure"

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

  block conditionsAnotherReviewFound:
    # each is right (within 1 %) or says it is not: a sure reading is never more than 1 % off
    func shaped(f1, f2, seconds, dt, ramp: float64; shape = tpCos2; law = slLinear): Case =
      Case(f1: f1, f2: f2, law: law, nyquistShare: 1.0, lengthMs: seconds * 1000, dtMs: dt,
        startTaperMs: ramp * 1000,
        endTaperMs: ramp * 1000, shape: shape, delayMs: 200, listenMs: 600)
    var cases: seq[(string, Case, float64)] = @[]
    cases.add ("4 ms", shaped(6, 100, 8, 4, 0.3), 100.0)
    cases.add ("4 ms, top near Nyquist", shaped(6, 110, 8, 4, 0.3), 110.0)
    cases.add ("2 ms, top near Nyquist", shaped(8, 230, 10, 2, 0.5, tpBlackman), 230.0)
    cases.add ("exponential, 2 ms", shaped(5, 150, 8, 2, 0.3, law = slExponential), 150.0)
    cases.add ("short sweep, short ramps", shaped(6, 120, 2, 1, 0.3), 120.0)
    cases.add ("ramps of 1 s", shaped(6, 120, 12, 1, 1.0), 120.0)
    cases.add ("ramps of 1 s, Blackman", shaped(6, 120, 12, 2, 1.0, tpBlackman), 120.0)
    cases.add ("ramps of 1 s, power 2", shaped(6, 120, 20, 1, 1.0, tpPower), 120.0)
    cases.add ("Gaussian, ramps of 1 s", shaped(6, 120, 12, 1, 1.0, tpGaussian), 120.0)
    cases.add ("Hamming, ramps of 0.5 s", shaped(6, 120, 12, 1, 0.5, tpHamming), 120.0)
    cases.add ("no ramps", shaped(6, 120, 8, 2, 0.0), 120.0)
    cases.add ("down, 4 ms", shaped(110, 6, 8, 4, 0.3), 110.0)
    for (db, f1, f2) in [(3.0, 8.0, 160.0), (6.0, 10.0, 90.0)]:
      var c = shaped(f1, f2, 8, 1, 0.3, law = slDbPerOctave)
      c.boostDb = db
      cases.add ($db & " dB per octave", c, f2)
      var d = shaped(f2, f1, 8, 1, 0.3, law = slDbPerOctave)
      d.boostDb = -db
      cases.add ($db & " dB per octave, down", d, f2)
    for (name, c, truth) in cases:
      let r = readingOf(c)
      doAssert not r.hz.isNaN, name & ": no reading"
      doAssert r.uncertain or abs(r.hz - truth) <= 0.01 * truth, name & ": " & $r.hz & " for " &
        $truth & " as sure"
      doAssert not r.uncertain or r.why.len > 0, name & ": marked without words"
    # the plain ones are right to within half a percent, and not marked
    for (name, c, truth) in cases:
      if name in ["4 ms", "no ramps", "3.0 dB per octave",
          "6.0 dB per octave", "short sweep, short ramps"]:
        let r = readingOf(c)
        doAssert abs(r.hz - truth) <= 0.005 * truth, name & ": " & $r.hz & " for " & $truth

  block noQuietStretchAndDc:
    # a reference stored at the sweep's length has no quiet part to take the noise from; a
    # constant added to it is no part of the sweep
    for snr in [40.0, 30.0, 20.0]:
      for (shape, param) in [(tpCos2, NaN), (tpBlackman, NaN), (tpLinear, NaN), (tpPower, 4.0)]:
        var c = base(shape, param)
        (c.delayMs, c.listenMs, c.snrDb) = (0.0, 0.0, snr)
        let r = readingOf(c)
        doAssert r.uncertain or abs(r.hz - 120) <= 1.8, $shape & " " & $snr & " dB, no quiet: " &
          $r.hz
    for dc in [0.05, 0.3, 2.0]:
      var c = base(tpCos2)
      c.dc = dc
      let r = readingOf(c)
      doAssert abs(r.hz - 120) <= 0.6, "dc " & $dc & ": " & $r.hz

  block theFallbackIsNotSure:
    # a fall that cannot be fitted (here: a ramp the sampling leaves a handful of points of)
    # may end anywhere between the plateau's edge and its last point: the reading says so
    var c = base(tpCos2)
    (c.dtMs, c.lengthMs, c.startTaperMs, c.endTaperMs, c.f2, c.nyquistShare) = (4.0, 2000.0,
      400.0, 400.0, 110.0, 1.0)
    let r = readingOf(c)
    doAssert r.uncertain or abs(r.hz - 110) <= 1.1, "short fall: " & $r.hz & " as sure"

  block theEndIsNotBeforeTheLastPointFitted:
    doAssert notBefore(8.1, 8.2, 1) == 8.2 and notBefore(8.3, 8.2, 1) == 8.3
    doAssert notBefore(0.3, 0.2, -1) == 0.2 and notBefore(0.1, 0.2, -1) == 0.1
    # and in every reading: the end lies at or past the last point of the fall, in the sweep's
    # direction
    for up in [true, false]:
      let r = readingOf(base(tpCos2, NaN, up))
      doAssert (if up: r.endMs >= r.lastMs else: r.endMs <= r.lastMs),
        "end " & $r.endMs & " before the last point " & $r.lastMs

  block theWeighedEndIsNotBeforeTheLastPoint:
    # roots all before the last point fitted: the end is that point, in either direction (the
    # call in `readTop` that keeps it there is what this fails without)
    let up = weighShapes([8.0, 8.1], [1e-6, 2e-6], [1e-6, 1e-6], [0.01, 0.01], 40, 5.0, 8.5, 1)
    doAssert up.tEnd == 8.5 and up.best == 0
    let down = weighShapes([0.3, 0.25], [1e-6, 2e-6], [1e-6, 1e-6], [0.01, 0.01], 40, 5.0, 0.1, -1)
    doAssert down.tEnd == 0.1
    # a root past it stands
    let past = weighShapes([8.6, 8.7], [1e-6, 1e-3], [1e-6, 1e-6], [0.01, 0.01], 40, 5.0, 8.5, 1)
    doAssert abs(past.tEnd - 8.6) < 1e-6

  echo "tsweepedge: ok"

when isMainModule:
  main()
