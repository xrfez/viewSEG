## Synthetic reference sweeps for the tests of the top-frequency reading: a linear or
## exponential sweep with any taper shape processSEG offers, seeded white noise at a stated
## SNR (sweep rms over noise rms), an optional decaying tail after the sweep.
## Not a test of its own (its name does not start with t).
import std/math
import processSEG/vibroseis/[sweep, taper]

type
  Tail* = enum
    tnNone, tnRing, tnLeak
      ## tnRing: the end frequency goes on, decaying (exp, tau 250 ms) from `tailDb` below
      ## the sweep's amplitude; tnLeak: the sweep's own law goes on at that level, decaying

  Case* = object
    f1*, f2*: float64            ## Hz, start and end
    law*: SweepLaw
    lengthMs*, dtMs*: float64
    startTaperMs*, endTaperMs*: float64
    shape*: TaperShape
    param*: float64 = NaN
    delayMs*: float64            ## zeros before the sweep
    listenMs*: float64           ## after the sweep (zeros, noise, the tail)
    snrDb*: float64 = Inf        ## sweep rms / noise rms; Inf: no noise
    tail*: Tail
    tailDb*: float64 = -40       ## the tail's start, dB below the sweep's amplitude
    seed*: uint64 = 12345
    nyquistShare*: float64 = 0.8 ## the top frequency allowed, of Nyquist
    boostDb*: float64            ## dB per octave of a slDbPerOctave sweep
    dc*: float64                 ## a constant added to every sample, as a share of the amplitude

proc gaussians(n: int; seed: uint64): seq[float64] =
  ## splitmix64 + Box-Muller: the same numbers on every machine
  var s = seed
  func next(s: var uint64): float64 =
    s += 0x9E3779B97F4A7C15'u64
    var z = s
    z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
    z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
    z = z xor (z shr 31)
    (float64(z shr 11) + 0.5) / 9007199254740992.0
  result = newSeq[float64](n)
  var i = 0
  while i < n:
    let (u, v) = (next(s), next(s))
    let r = sqrt(-2 * ln(u))
    result[i] = r * cos(2 * PI * v)
    if i + 1 < n: result[i + 1] = r * sin(2 * PI * v)
    i += 2

proc makeRef*(c: Case): seq[float32] =
  let tp = initSweepTaper(c.startTaperMs, c.endTaperMs, c.shape, c.param)
  let spec = case c.law
    of slExponential: exponentialSweep(c.f1, c.f2, c.lengthMs, c.dtMs, tp,
      maxNyquistFraction = c.nyquistShare)
    of slDbPerOctave: dbPerOctaveSweep(c.f1, c.f2, c.lengthMs, c.dtMs, c.boostDb, tp,
      maxNyquistFraction = c.nyquistShare)
    else: linearSweep(c.f1, c.f2, c.lengthMs, c.dtMs, tp, maxNyquistFraction = c.nyquistShare)
  let sw = sweepSamples(spec)
  let nd = int(round(c.delayMs / c.dtMs))
  let nl = int(round(c.listenMs / c.dtMs))
  var x = newSeq[float64](nd + sw.len + nl)
  for j in 0 ..< sw.len: x[nd + j] = sw[j]
  if c.tail != tnNone:
    let a = pow(10.0, c.tailDb / 20)
    let ph1 = spec.phaseAt(c.lengthMs) # the phase at the sweep's end (radians)
    for j in 0 ..< nl:
      let s = float64(j) * c.dtMs / 1000 # seconds after the end
      let env = a * exp(-s / 0.25)
      let k = (c.f2 - c.f1) / (c.lengthMs / 1000)
      let ph = if c.tail == tnRing: ph1 + 2 * PI * c.f2 * s
        else: ph1 + 2 * PI * (c.f2 * s + 0.5 * k * s * s)
      x[nd + sw.len + j] = env * sin(ph)
  if c.dc != 0:
    for v in x.mitems: v += c.dc
  if c.snrDb < Inf:
    let sigma = (1 / sqrt(2.0)) / pow(10.0, c.snrDb / 20)
    let g = gaussians(x.len, c.seed)
    for j in 0 ..< x.len: x[j] += sigma * g[j]
  result = newSeq[float32](x.len)
  for j in 0 ..< x.len: result[j] = float32(x[j])
