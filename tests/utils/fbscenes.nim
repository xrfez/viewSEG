## Synthetic records for the first-break job's identity tests: `traces` traces of `samples`
## samples at `dtMs` and a two-layer refraction (0.4 ms a metre to 2000 m, then 0.2 ms a
## metre), a 30 Hz Ricker wavelet 25 ms after each break in noise, and, beyond 4500 m, noise
## only on every seventh trace. The noise is a fixed generator, not `std/random`, so the
## records are the same on every machine and Nim version.

import std/[math, os]
import parseSEG
import fixtures

type Scene* = enum
  scTwoLayer  ## the record above
  scNonFinite ## the same, with a NaN sample in some traces and one trace all NaN
  scNoise     ## noise only: no model to trust
  scHalfSpace ## one line, 0.4 ms a metre

func sceneOffset*(i, traces: int): float64 = 50.0 + 6000.0 * float64(i) / float64(traces)

func sceneBreak*(x: float64; scene: Scene): float64 =
  if scene == scHalfSpace or x < 2000: 0.4 * x else: 800 + 0.2 * (x - 2000)

proc noiseOf(i, j: int): float64 =
  var x = uint64(i) * 2862933555777941757'u64 + uint64(j) * 3037000493'u64 + 12345
  for k in 0 ..< 12:
    x = x * 6364136223846793005'u64 + 1442695040888963407'u64
    result += float64(x shr 11) / float64(1'u64 shl 53)
  result -= 6

proc scene*(fx: Fixtures; name: string; scene: Scene; traces, samples: int; dtMs: float64): string =
  ## The record as a SEG-Y file in the fixtures' folder.
  result = fx.dir / name
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 first-break identity test: " & name]))
  var buf = newSeq[float32](samples)
  for i in 0 ..< traces:
    let x = sceneOffset(i, traces)
    let centre = sceneBreak(x, scene) + 25
    let wave = scene != scNoise and not (i mod 7 == 3 and x > 4500)
    for j in 0 ..< samples:
      let t = float64(j) * dtMs
      var v = 0.05 * noiseOf(i + 1, j)
      if wave:
        let u = PI * 30.0 * (t - centre) / 1000
        if abs(t - centre) < 100: v += (1 - 2 * u * u) * exp(-u * u)
      buf[j] = float32(v)
    if scene == scNonFinite:
      if i mod 97 == 11: buf[samples div 3] = NaN
      if i == 500:
        for j in 0 ..< samples: buf[j] = NaN
      if i == 600: buf[samples div 2] = Inf
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(i + 1), 0.0,
      dtMs * 1000, tsLive)
    k.offset = x
    w.writeTrace(k, buf)
  let log = w.close()
  doAssert log.len == 0, $log
