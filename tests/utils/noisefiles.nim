## A synthetic shot for the noisy-trace tests: 64 traces, offsets 100 m to
## 1675 m, a first break on a 2500 m/s half space, the traces near the source
## far louder (as the ground there is), one far trace planted noisy and one
## planted louder than its neighbours only; the stations' coordinates in the
## headers (`lines` receiver lines), or no offsets and no stations at all, or
## unrotated three-component nodes.

import std/os
import parseSEG
import processSEG/synth
import fixtures

const
  NoisyTraces* = 64
  Smp = 1000
  Step = 2.0
  NearLoud = 12 ## traces nearer than this index are loud
  PlantedNoisy* = 50
  PlantedLouder* = 40

func offsetOf*(i: int): float64 = 100.0 + 25.0 * float64(i)

func arrival(x: float64): float64 = 20.0 + 0.4 * x

proc noisyShot*(fx: Fixtures; name: string; lines = 1; stations = true; offsets = true;
    comps = 1): string =
  ## One shot of `NoisyTraces` traces over `lines` receiver lines (consecutive stations of one
  ## line, then the next, the stations' coordinates in the headers), offsets in the headers
  ## (`offsets`), stations (`stations`); the first `NearLoud` traces loud. `comps` 3: unrotated nodes, three traces a station, the
  ## second component weak (a node's components differ, whichever way the node lies).
  result = fx.dir / name
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 noisy-trace test"]))
  var buf = newSeq[float32](Smp)
  let perLine = NoisyTraces div lines
  for i in 0 ..< NoisyTraces:
    for j in 0 ..< Smp: buf[j] = 0
    let node = i div comps
    var gain = 1.0
    if node < NearLoud div comps: gain = 12.0 - float64(node * comps) * 0.8
    if comps == 1 and i == PlantedNoisy: gain = 30.0
    if comps == 1 and i == PlantedLouder: gain = 2.8
    if comps == 3 and i mod 3 == 1: gain *= 0.02
    buf.addRicker(Step, arrival(offsetOf(node * comps)) + 15, 30, gain)
    buf.addNoise(0.03 * gain, int64(i + 1))
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(i + 1), 0.0,
      Step * 1000, tsLive)
    if offsets: k.offset = offsetOf(node * comps)
    if comps == 3: k.traceCode = int16(12 + i mod 3)
    if stations:
      # lines 500 m apart along x, the stations 25 m apart; the source off the first line's end
      let perNode = perLine div comps
      (k.rcvX, k.rcvY) = (1000.0 + 25.0 * float64(node mod perNode),
        1000.0 + 500.0 * float64(node div perNode))
      (k.srcX, k.srcY) = (900.0, 1000.0)
    w.writeTrace(k, buf)
  doAssert w.close().len == 0

