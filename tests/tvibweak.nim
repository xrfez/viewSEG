## The Vibrator window's top frequency, read from the reference when none is typed, on
## synthetic sweeps (6 to 120 Hz over 8 s, 2 ms, tapers of 300 ms, made by processSEG with
## every taper shape, white noise from a fixed seed, a decaying tail after the sweep):
##
## - a sweep with a long ramp of any shape reads its end frequency within half a hertz, the
##   shapes' own (a power 4 ramp, 1.2 Hz low before the reading followed the fall);
## - a sweep whose end is lost in noise reads right or says so in the band's warning: a
##   confident number 0.6 Hz or more off, with no warning, is never shown (before: 1 to 3 Hz
##   low at 30 to 10 dB with no warning);
## - a ring-down or leakage 20 to 60 dB below the sweep, after the end taper, does not move
##   the reading (before: up to 9 Hz high);
## - a generated reference's stored end frequency is used as it is, however noisy the
##   reference (the reading is not made).
##
## Seen to fail: on the reading as it was (the cos² extension from the measured extent) the
## power 4 case read 119 for 120, the 30 dB noise case 118 with no warning, and the ring-down
## at -20 dB read 121 with a warning that the top does not fit the sweep (each block run
## alone against that code; the stored-parameter block passed there too).

import std/strutils
import parseSEG
import processSEG/vibroseis/[sweep, taper]
import viewSEG/core/[analysis, vibanalysis]
import utils/sweepsyn

const
  Tol = 0.6  # 0.5 % of 120 Hz
  Sure = 1.2 # 1 %: what a reading not said to be uncertain may be off by

proc windowBand(c: Case; exact = NaN): BandReport =
  ## the band the window reports for `c` as the reference (and as the recorded signal)
  let x = makeRef(c)
  let r = vibratorOf(@[x, x], @["ref", "gf"],
    [vsReference: 0, vsGroundForce: 1, vsMass: -1, vsBaseplate: -1], c.dtMs, AnalysisParams(),
    exactTopHz = exact)
  doAssert r.problem == "", r.problem
  r.band

proc base(shape: TaperShape; param = NaN; up = true): Case =
  Case(f1: (if up: 6 else: 120), f2: (if up: 120 else: 6), lengthMs: 8000, dtMs: 2,
    startTaperMs: 300, endTaperMs: 300, shape: shape, param: param, delayMs: 200,
    listenMs: 600)

func isSaid(warning: string): bool =
  ## the band's warning says the top frequency is not sure, or not read
  "uncertain" in warning or "could not be read reliably" in warning

proc rightOrSaid(b: BandReport; truth: float64; what: string) =
  doAssert abs(b.hz - truth) < Sure or isSaid(b.warning),
    what & ": " & $b.hz & " for " & $truth & " with " & (if b.warning.len >
        0: b.warning else: "no warning")

proc main*() =
  block shapesOfTheEndTaper:
    for (shape, param, name) in [(tpCos2, NaN, "cos2"), (tpBlackman, NaN, "blackman"),
        (tpKaiser, NaN, "kaiser"), (tpPower, 2.0, "power 2"), (tpPower, 4.0, "power 4"),
        (tpLinear, NaN, "linear")]:
      for up in [true, false]:
        let b = windowBand(base(shape, param, up))
        doAssert abs(b.hz - 120) < Tol, name & (if up: " up: " else: " down: ") & $b.hz &
          " " & b.warning

  block lostInNoise:
    for snr in [30.0, 20.0, 10.0, 6.0, 3.0]:
      for up in [true, false]:
        for (shape, param) in [(tpCos2, NaN), (tpLinear, NaN), (tpBlackman, NaN)]:
          var c = base(shape, param, up)
          c.snrDb = snr
          windowBand(c).rightOrSaid(120, $shape & " at " & $snr & " dB " & (
              if up: "up" else: "down"))
    # the noise is said in words that name the uncertainty
    var c = base(tpCos2)
    c.snrDb = 6
    let said = windowBand(c).warning
    doAssert ("uncertain" in said and "Hz either way" in said) or
      "could not be read reliably" in said, said

  block tailAfterTheEndTaper:
    for tail in [tnRing, tnLeak]:
      for db in [-20.0, -30.0, -40.0, -60.0]:
        for (shape, param) in [(tpCos2, NaN), (tpKaiser, NaN), (tpBlackman, NaN)]:
          var c = base(shape, param)
          c.tail = tail
          c.tailDb = db
          c.listenMs = 1000
          let b = windowBand(c)
          b.rightOrSaid(120, $shape & " " & $tail & " " & $db & " dB")

  block storedParametersAreUsed:
    # a noisy reference, its generated end frequency given: that is the band, exactly
    var c = base(tpCos2)
    c.snrDb = 3
    let b = windowBand(c, exact = 120.0)
    doAssert b.hz == 120 and b.exact and b.warning.len == 0, $b.hz & " " & b.warning

  block anAbsurdReadingIsNotTheBand:
    # a reference the noise has swallowed: whatever the reading, the band is a frequency the
    # sweep allows (below Nyquist, not below what the reference shows), the words say what
    # happened, and no number in them is absurd
    for snr in [3.0, 0.0]:
      var c = base(tpCos2)
      c.snrDb = snr
      let b = windowBand(c)
      doAssert b.hz < 250 and b.hz > 0, "band " & $b.hz & " at " & $snr & " dB"
      doAssert b.warning.len > 0, "nothing said at " & $snr & " dB"
      doAssert "198746654" notin b.warning and (not b.uncertain or b.uncertaintyHz < 0.05 * b.hz),
        b.warning

  block theMarkAndTheBandWhenMarked:
    # a Gaussian ramp with a ring-down at -30 dB: the reading is a little over 1 % off and its
    # uncertainty about 0.9 %: marked by the 0.6 % bound (not by one of 1.2 %), and, below 3 %,
    # still the band's edge
    var c = base(tpGaussian)
    c.tail = tnRing
    c.tailDb = -30
    c.listenMs = 1000
    let ring = windowBand(c)
    doAssert "uncertain" in ring.warning, "not marked: " & ring.warning
    doAssert "median of the estimates" notin ring.warning, ring.warning
    # a noisy ramp is honest about the noise: marked at 30 dB (the shapes' spread is kept)
    for shape in [tpBlackman, tpCos2]:
      var d = base(shape)
      d.snrDb = 30
      doAssert "uncertain" in windowBand(d).warning, $shape & " at 30 dB not marked"
    # a reading uncertain by more than 3 % (the noise at 3 dB) gives the band to the median of
    # the estimates that fit, and the words say so
    var e = base(tpCos2)
    e.snrDb = 3
    let lost = windowBand(e)
    doAssert "median of the estimates that fit" in lost.warning, lost.warning
    doAssert plausible(lost.hz, NaN, 250.0), $lost.hz

  block shapesAreWeighedNotPicked:
    # a cosine squared ramp at 30 dB (the noise of seed 1): the shapes that fit alike share the
    # weight, so the band is right (the best shape alone read 123)
    var c = base(tpCos2)
    (c.snrDb, c.seed) = (30.0, 1'u64)
    let b = windowBand(c)
    doAssert abs(b.hz - 120) < Sure, $b.hz & " " & b.warning

  block theMedianOfThePlausibleEstimates:
    let (nyq, chord) = (250.0, 100.0)
    doAssert markedTopHz(NaN, NaN, NaN, chord, nyq).isNaN # none
    doAssert markedTopHz(120.0, 300.0, 50.0, chord, nyq) == 120.0 # one
    doAssert markedTopHz(120.0, 118.0, 50.0, chord, nyq) == 119.0 # two: their mean
    doAssert markedTopHz(120.0, 118.0, 140.0, chord, nyq) == 120.0 # three: the median
    doAssert markedTopHz(NaN, 118.0, 122.0, NaN, nyq) == 120.0 # no chord: every one fits
    doAssert not plausible(250.0, chord, nyq) and not plausible(99.0, chord, nyq)
    doAssert plausible(99.6, chord, nyq)

  echo "tvibweak: ok"

when isMainModule:
  main()
