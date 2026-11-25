## A synthetic converter-style signature file for the ground force tests: a true ground force
## split into two force channels, written the way the external converter writes them (each
## channel mean-removed and divided by its own weight; the fourth trace the hold-down weight
## times their equal-weight sum, which is no ground force). Every number is made up.

import vibsynth

const
  Wm* = 3600.0 ## the converter's reaction-mass weight
  Wb* = 1400.0
  Wh* = 8000.0 ## ... and its hold-down weight

type Converter* = object
  reference*, truth*, record*, mass*, plate*: seq[float32]

proc converterOf*(): Converter =
  ## A true ground force g, split into a force channel of the reaction mass m (another phase
  ## and a harmonic) and of the baseplate g - m; the converter's traces: each channel
  ## mean-removed and divided by its weight, the fourth the hold-down weight times their sum.
  let g = SynthSweep(amp: 1000, phaseDeg: 1)
  let m = SynthSweep(amp: 700, phaseDeg: 20, h2: 0.05, burstAtS: 2, burstLenS: 3,
    burstGain: 2.5, burstPhaseDeg: 70)
  result.reference = g.referenceOf.sweepRow
  result.truth = g.sweepRow
  let fm = m.sweepRow
  var fb = newSeq[float32](fm.len)
  var (meanM, meanB) = (0.0, 0.0)
  for i in 0 ..< fm.len:
    fb[i] = result.truth[i] - fm[i]
    meanM += fm[i] / float64(fm.len)
    meanB += fb[i] / float64(fm.len)
  for i in 0 ..< fm.len:
    result.mass.add float32((fm[i] - meanM) / Wm)
    result.plate.add float32((fb[i] - meanB) / Wb)
    result.record.add float32(Wh * (result.mass[i] + result.plate[i]))

