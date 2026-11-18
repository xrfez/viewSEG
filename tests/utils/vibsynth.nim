## Synthetic vibrator sweeps with known values, for the tests of the vibrator signature's
## verdict: a linear sweep of a known amplitude and phase to the reference, with a
## known 2nd and 3rd harmonic, an optional lead-in (the sweep starts late in the record)
## and an optional burst (a stretch of the sweep with a phase, amplitude or 2nd harmonic of
## its own: one bad window among good ones).
##
## The reference is `sin(p)` with `p = 2π(f0·t + (f1 − f0)/(2T)·t²)`; a trace of
## phase φ is `sin(p + φ)` (a phase of +φ to the reference), times the taper, plus the
## harmonics `h2·sin(2p)` and `h3·sin(3p)` in the trace's own amplitude.

import std/[math, os]
import parseSEG

type
  SynthSweep* = object
    f0*: float64 = 6
    f1*: float64 = 100
    seconds*: float64 = 8          ## the sweep's length
    dtMs*: float64 = 1
    taperS*: float64 = 0.1         ## cos² taper at each end
    amp*: float64 = 1000
    phaseDeg*: float64 = 0
    h2*, h3*: float64              ## the harmonics, as fractions of the fundamental
    delayMs*: float64              ## lead-in: the sweep starts this long after the record's first sample
    tailS*: float64 = 0.5          ## record left after the sweep's end
    burstAtS*, burstLenS*: float64 ## a burst (sweep time, s); length 0: none
    burstPhaseDeg*: float64        ## added phase in the burst
    burstGain*: float64 = 1.0      ## times the amplitude in the burst
    burstH2*: float64              ## the burst's 2nd harmonic (replaces `h2`)
    expo*: bool                    ## an exponential sweep (f1/f0 to the power of t/T) instead of a linear one
    cutAtS*: float64 = Inf         ## the record ends at this sweep time (a trace cut short)

func samples*(s: SynthSweep): int =
  ## The record's length in samples.
  let last = min(s.delayMs / 1000 + s.seconds + s.tailS, s.cutAtS + s.delayMs / 1000)
  int(ceil(last * 1000 / s.dtMs))

func phaseAt*(s: SynthSweep; tau: float64): float64 =
  ## The sweep's phase (radians) `tau` seconds into it.
  if s.expo:
    let k = ln(s.f1 / s.f0)
    2 * PI * s.f0 * s.seconds / k * (exp(k * tau / s.seconds) - 1)
  else: 2 * PI * (s.f0 * tau + (s.f1 - s.f0) / (2 * s.seconds) * tau * tau)

func hzAt*(s: SynthSweep; tau: float64): float64 =
  if s.expo: s.f0 * exp(ln(s.f1 / s.f0) * tau / s.seconds)
  else: s.f0 + (s.f1 - s.f0) * tau / s.seconds

func taperAt*(s: SynthSweep; tau: float64): float64 =
  if tau < 0 or tau > s.seconds: 0.0
  elif tau < s.taperS: pow(sin(PI / 2 * tau / s.taperS), 2)
  elif tau > s.seconds - s.taperS: pow(sin(PI / 2 * (s.seconds - tau) /
      s.taperS), 2)
  else: 1.0

func inBurst*(s: SynthSweep; tau: float64): bool =
  s.burstLenS > 0 and tau >= s.burstAtS and tau < s.burstAtS + s.burstLenS

func sweepRow*(s: SynthSweep): seq[float32] =
  ## The trace of `s`.
  result = newSeq[float32](s.samples)
  for j in 0 ..< result.len:
    let tau = float64(j) * s.dtMs / 1000 - s.delayMs / 1000
    let burst = s.inBurst(tau)
    let p = s.phaseAt(tau)
    let phi = degToRad(s.phaseDeg + (if burst: s.burstPhaseDeg else: 0.0))
    let gain = if burst: s.burstGain else: 1.0
    let h2 = if burst and s.burstH2 > 0: s.burstH2 else: s.h2
    result[j] = float32(s.amp * gain * s.taperAt(tau) *
      (sin(p + phi) + h2 * sin(2 * p) + s.h3 * sin(3 * p)))

func referenceOf*(s: SynthSweep): SynthSweep =
  ## The reference of a sweep: amplitude 1, no phase offset, no harmonic, no burst, no cut.
  result = s
  result.amp = 1
  result.phaseDeg = 0
  result.h2 = 0
  result.h3 = 0
  result.burstLenS = 0
  result.cutAtS = Inf

proc writeVibSegy*(path: string; rows: openArray[seq[float32]]; dtMs: float64;
    codes: openArray[int16] = [21'i16, 20, 18, 19]) =
  ## A SEG-Y of one record: `rows` in order, with the vibrator identification codes `codes`
  ## (reference 21, ground force 20, reaction mass 18, baseplate 19).
  var w = openSeismicWriter(path, SegyOutputOptions(revision: SegyRevision(
      major: 1, minor: 0),
    traceSorting: 1, measurementSystem: 1, text: @[
        "C01 viewSEG test fixture: synthetic sweeps"]))
  for n, row in rows:
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs) = (1.0, float64(n + 1), 0.0,
        dtMs * 1000)
    k.traceCode = codes[n]
    k.status = tsAuxiliary
    w.writeTrace(k, row)
  let log = w.close()
  doAssert log.len == 0, $log
