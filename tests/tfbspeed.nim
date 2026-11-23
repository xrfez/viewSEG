## The first-break job gives the same answer as it did before it was made faster
## (`tests/utils/fbreference`: one thread, the passes a chunk at a time, whole traces filtered, the
## trimmed model's start and fits as they were): the picks, confidences, fit, range, flags and
## words of synthetic records hash to the same value (`tests/utils/fbprint`) - a healthy
## two-layer record at 1, 2 and 4 ms, a given model that makes a third pass, killed traces and
## traces with non-finite samples, a record of noise where the guided pass is skipped, an
## interval that leaves no room for the smoothing, one line on the samples as recorded - and with
## one, two, four and the default number of worker threads. A cancelled job stops, and says so.
##
## Also `trimmedModel` against the reference's on random picks (noise picks, repeated
## distances, odd and even counts, a second line).
##
## Seen to fail: with the middle distance of an even count taken from the upper of the two
## middle ones only, "trial 80 of 127 picks: used 37 and 37"; with the smoothing filter's corner
## one Hz higher than the reference's, "two-layer 1 ms: 1 workers: 281CAF21DB86C439 is not the
## reference's C4E6D07679752455".

import std/[math, strutils]
import parseSEG
import viewSEG/core/[breakmodel, breakrule, firstbreakjobs, firstbreaks, jobs]
import utils/[fbprint, fbreference, fbscenes, fixtures]

type Case = object
  name: string
  scene: Scene
  traces, samples: int
  dtMs: float64
  killed: seq[int]
  guide: BreakModel
  pick: PickBasis

const Cases = [
  Case(name: "two-layer 1 ms", scene: scTwoLayer, traces: 640, samples: 2001, dtMs: 1.0,
    pick: pbSmoothed),
  Case(name: "two-layer 2 ms", scene: scTwoLayer, traces: 640, samples: 1000, dtMs: 2.0,
    pick: pbSmoothed),
  Case(name: "two-layer 4 ms", scene: scTwoLayer, traces: 640, samples: 500, dtMs: 4.0,
    pick: pbSmoothed),
  Case(name: "given model", scene: scTwoLayer, traces: 640, samples: 2001, dtMs: 1.0,
    guide: BreakModel(source: bmGiven, v1: 2500, interceptMs: 0, v2: 5000, crossover: 2000),
    pick: pbSmoothed),
  Case(name: "killed and non-finite", scene: scNonFinite, traces: 640, samples: 2001,
    dtMs: 1.0, killed: @[50, 51, 52, 300, 601], pick: pbSmoothed),
  Case(name: "noise only", scene: scNoise, traces: 600, samples: 2001, dtMs: 1.0,
    pick: pbSmoothed),
  Case(name: "one line as recorded", scene: scHalfSpace, traces: 640, samples: 1000,
    dtMs: 2.0, pick: pbAsRecorded),
  Case(name: "12 ms, smoothing left out", scene: scTwoLayer, traces: 700, samples: 500,
    dtMs: 12.0, pick: pbSmoothed),
  Case(name: "small", scene: scTwoLayer, traces: 120, samples: 4001, dtMs: 1.0,
    pick: pbSmoothed)]

proc breaks(c: Case; path: string; workers: int; reference = false): FirstBreaks =
  var f = openSeismic(path, keys = true)
  defer: f.close()
  if reference:
    breaksOfRecordReference(addr f, path, 0 ..< f.len, c.killed, guide = c.guide, pick = c.pick)
  else:
    breaksOfRecord(addr f, path, 0 ..< f.len, c.killed, guide = c.guide, pick = c.pick,
      workers = workers)

proc noise(state: var uint64): float64 =
  state = state * 6364136223846793005'u64 + 1442695040888963407'u64
  float64(state shr 11) / float64(1'u64 shl 53)

proc trimsAgree() =
  ## `trimmedModel` finds what the reference's does on random picks: a line with noise picks
  ## among them, odd and even counts, picks repeated (equal distances), a second line.
  var state = 12345'u64
  for trial in 0 ..< 120:
    let n = 12 + int(noise(state) * 200)
    var offs, pick, conf = newSeq[float64](n)
    let step = if trial mod 3 == 0: 1.0 else: 0.25 # a coarse time grid repeats distances
    for i in 0 ..< n:
      offs[i] = 100 + 25 * float64(i div (1 + trial mod 2)) # a repeated offset now and then
      pick[i] = round((50 + 0.4 * offs[i]) / step) * step
      if noise(state) < 0.3: pick[i] = round(noise(state) * 3000 / step) * step # a noise pick
      if trial mod 5 == 0 and offs[i] > 100 + 25 * float64(n div 2):
        pick[i] += 0.3 * (offs[i] - 100 - 25 * float64(n div 2)) # a second line
      conf[i] = if noise(state) < 0.8: 0.9 else: 0.2
      if trial mod 7 == 0 and i mod 11 == 0: pick[i] = NaN
    let fit = proc (use: openArray[bool]): seq[float64] =
      let line = lineFit(offs, pick, use)
      if not line.ok: return @[]
      result = newSeq[float64](n)
      for i in 0 ..< n: result[i] = line.interceptMs + line.msPerUnit * offs[i]
    let want = trimmedModelReference(offs, pick, conf, fit)
    let got = trimmedModel(offs, pick, conf, fit)
    doAssert got.trusted == want.trusted and got.kept == want.kept and got.used == want.used and
      got.rounds == want.rounds and got.model == want.model and
      (got.sigmaMs == want.sigmaMs or (got.sigmaMs.isNaN and want.sigmaMs.isNaN)),
      "trial " & $trial & " of " & $n & " picks: used " & $got.used & " and " & $want.used

proc main*() =
  trimsAgree()
  withFixtures fx:
    for i, c in Cases:
      let path = fx.scene("s" & $i & ".sgy", c.scene, c.traces, c.samples, c.dtMs)
      let want = c.breaks(path, 1, reference = true)
      doAssert want.state == bkDone, c.name
      if c.name == "noise only":
        doAssert not want.twoPass and want.passNote.len > 0, "the guided pass was made"
      elif c.name == "12 ms, smoothing left out":
        doAssert want.pickNote.len > 0, "the picks were smoothed"
      else:
        doAssert want.twoPass, c.name & ": no guided pass"
      for workers in [1, 2, 0]:
        let got = c.breaks(path, workers)
        doAssert got.fingerprint == want.fingerprint, c.name & ": " & $workers & " workers: " &
          got.fingerprint.toHex & " is not the reference's " & want.fingerprint.toHex
    # a stop asked for after the first chunk ends the job, with the pool's threads joined
    block aStopEndsTheJob:
      let c = Cases[0]
      let path = fx.scene("stop.sgy", c.scene, c.traces, c.samples, c.dtMs)
      var f = openSeismic(path, keys = true)
      var calls = 0
      var stopped = false
      try:
        discard breaksOfRecord(addr f, path, 0 ..< f.len, [],
          proc (done, total: int): bool =
          inc calls
          calls < 2)
      except JobCancelledError:
        stopped = true
      f.close()
      doAssert stopped and calls == 2, "stopped " & $stopped & " after " & $calls & " chunks"
  echo "tfbspeed: ok"

when isMainModule: main()
