## A synthetic shot whose first break builds slowly, for the first-break picking tests: 60
## traces of 3000 ms at 2 ms (or `dtMs`), offsets 100 m to 3050 m, the break at 40 ms plus 0.4
## ms a metre (`onsetMs`), a zero-phase Gabor wavelet of 25 Hz whose main lobe lies `LobeMs`
## after the onset (the wavelet is 1 % of its peak there), noise of four levels in turn
## (`NoiseLevels`), and on every third trace a later event three times as strong whose main
## lobe lies 60 ms after the first lobe.

import std/[math, os]
import parseSEG
import fixtures

const
  FbTraces* = 60
  FbHz* = 25.0
  LobeMs* = 36.0 ## the main lobe's time after the onset (the wavelet's envelope is 1.1 % there)
  LaterMs* = 60.0                         ## the stronger later event's lobe, after the first lobe
  NoiseLevels* = [0.02, 0.05, 0.10, 0.15] ## sigma, in units of the first wavelet's peak

func fbOffset*(i: int): float64 = 100.0 + 50.0 * float64(i)

func onsetMs*(i: int): float64 = 40.0 + 0.4 * fbOffset(i)

func gabor(t, centre, amp: float64): float64 =
  ## A zero-phase wavelet: a cosine of `FbHz` under a Gaussian whose sigma is a third of
  ## `LobeMs`.
  let s = LobeMs / 3
  let u = (t - centre) / s
  amp * exp(-0.5 * u * u) * cos(2 * PI * FbHz * (t - centre) / 1000)

proc noiseOf(i, j: int): float64 =
  ## A deterministic pseudo-random value of unit variance (a sum of twelve uniforms).
  var x = uint64(i) * 2862933555777941757'u64 + uint64(j) * 3037000493'u64 + 12345
  for k in 0 ..< 12:
    x = x * 6364136223846793005'u64 + 1442695040888963407'u64
    result += float64(x shr 11) / float64(1'u64 shl 53)
  result -= 6

proc fbShot*(fx: Fixtures; name: string; dtMs = 2.0; samples = 1500; later = true;
    nanTrace = -1): string =
  ## The shot as a SEG-Y file in the fixtures' folder; trace `nanTrace` (when not -1) holds one
  ## NaN sample at the middle of its record.
  result = fx.dir / name
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 first-break picking test: a slowly building first break"]))
  var buf = newSeq[float32](samples)
  for i in 0 ..< FbTraces:
    let first = onsetMs(i) + LobeMs
    let strong = later and i mod 3 == 0
    for j in 0 ..< samples:
      let t = float64(j) * dtMs
      var v = gabor(t, first, 1.0) + NoiseLevels[i mod NoiseLevels.len] * noiseOf(i + 1, j)
      if strong: v += gabor(t, first + LaterMs, 3.0)
      buf[j] = float32(v)
    if i == nanTrace: buf[samples div 2] = NaN
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(i + 1), 0.0,
      dtMs * 1000, tsLive)
    k.offset = fbOffset(i)
    w.writeTrace(k, buf)
  let log = w.close()
  doAssert log.len == 0, $log
