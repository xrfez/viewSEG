## The first-break job gives the same answer as it did before it was made faster
## (`tests/utils/fbreference`: one thread, the passes a chunk at a time, whole traces filtered, the
## trimmed model's start and fits as they were): the picks, confidences, fit, range, flags and
## words of synthetic records hash to the same value (`tests/utils/fbprint`) - a healthy
## two-layer record at 1, 2 and 4 ms, a given model that makes a third pass, killed traces and
## traces with non-finite samples, a record of noise where the guided pass is skipped, an
## interval that leaves no room for the smoothing, one line on the samples as recorded - and with
## one, two, four and the default number of worker threads. A cancelled job stops, and says so.
## No worker thread is left after a normal run, a stop, or an exception from the progress
## callback (Linux counts the entries of /proc/self/task; other systems skip that count).
##
## Also `trimmedModel` against the reference's on random picks (noise picks, repeated
## distances, odd and even counts, a second line).
##
## The pool's smoothing of one chunk equals `smoothedCopy` sample for sample when the traces
## of the chunk have different live lengths: mixed lengths, two sets of lengths, and rows
## skipped, at one, two and eight workers.
##
## `medianLineStart` picks the same line as a full sort of every candidate's distances, on
## random pick sets (small counts, many ties, Inf, NaN; a fixed seed, 2000 trials).
##
## Seen to fail: with the middle distance of an even count taken from the upper of the two
## middle ones only, "trial 80 of 127 picks: used 37 and 37"; with the smoothing filter's corner
## one Hz higher than the reference's, "two-layer 1 ms: 1 workers: 281CAF21DB86C439 is not the
## reference's C4E6D07679752455"; with the pool's high cut one Hz above `smoothedCopy`'s,
## "mixed lengths: 1 workers: 886170 samples differ, worst |d| 0.009104490280151367"; with the
## task count taken in the progress callback while the pool was still up, "during: 5 tasks, was 1";
## with an even count needing one more distance below the best than half, "trial 4 of 12 picks
## differs".

import std/[algorithm, math, os, strutils]
import parseSEG
import processSEG/core/[pool, types, workspace]
import processSEG/filter/[design, iir]
import processSEG/pipeline
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

proc smoothingAgrees(name: string; rows, cols: int; dt: float64; lenOf: proc (r: int): int;
    skip: seq[int]; workers: int) =
  ## The pool's filter of this chunk equals `smoothedCopy`, every sample, skipped rows included.
  var samples = newTensor[float32](rows, cols)
  var st = 7'u64
  var keys = newSeq[TraceKeys](rows)
  var counts = newSeq[int](rows)
  for r in 0 ..< rows:
    counts[r] = lenOf(r)
    for c in 0 ..< counts[r]:
      samples[r, c] = float32(noise(st) + 0.3 * sin(float64(c) * 0.05))
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(r + 1), 0.0,
      dt * 1000, tsLive)
    keys[r] = k
  let cut = pickCutHz(dt)
  doAssert cut > 0, name & ": no high cut at " & $dt & " ms"
  let plan = initIirPlan(float32, butterHighCut(cut, PickHighCutSlope), dt, cols, ipZero)
  let flow = initPipeline([iirOp(butterHighCut(cut, PickHighCutSlope))]).compile(float32, dt,
    cols)
  let meta = initChunkMeta(rowsOf(keys, counts), dt, 0, skip)
  var ws = initWorkspace()
  ws.reserve(plan.workspaceSize)
  let want = smoothedCopy(samples, meta, plan, ws)
  var p = newProcessPool(workers)
  var got = newTensorUninit[float32](rows, cols)
  p.apply(flow, samples, got, meta)
  var diffSamples = 0
  var worst = 0.0
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      if cast[uint32](want[r, c]) != cast[uint32](got[r, c]):
        inc diffSamples
        worst = max(worst, abs(float64(want[r, c]) - float64(got[r, c])))
  doAssert diffSamples == 0, name & ": " & $workers & " workers: " & $diffSamples &
    " samples differ, worst |d| " & $worst

proc mixedLengthsAgree() =
  ## One chunk, traces of different live lengths: the pool and `smoothedCopy` agree.
  let mixed = proc (r: int): int = (if r mod 3 == 0: 2001 else: 1200 + (r * 37) mod 800)
  let twoSets = proc (r: int): int = (if r < 200: 2001 else: 1001)
  let mixed500 = proc (r: int): int = (if r mod 5 == 0: 500 else: 250 + (r * 13) mod 250)
  let mixed4001 = proc (r: int): int = (if r mod 4 == 0: 4001 else: 900 + (r * 131) mod 3100)
  for w in [1, 2, 8]:
    smoothingAgrees("mixed lengths", 512, 2001, 1.0, mixed, @[], w)
    smoothingAgrees("mixed lengths, rows skipped", 512, 2001, 1.0, mixed,
      @[3, 50, 51, 77, 300], w)
    smoothingAgrees("two lengths", 512, 2001, 1.0, twoSets, @[], w)
    smoothingAgrees("two lengths, a row skipped", 512, 2001, 1.0, twoSets, @[5], w)
    smoothingAgrees("mixed 500 at 2 ms", 512, 500, 2.0, mixed500, @[1, 2, 3, 4, 200], w)
    smoothingAgrees("mixed 4001 at 1 ms", 333, 4001, 1.0, mixed4001, @[0, 17, 18], w)

proc sameLine(a, b: seq[(float64, int)]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i][1] != b[i][1] or cast[uint64](a[i][0]) != cast[uint64](b[i][0]): return false
  true

proc sortLineStart(offs, pickMs: openArray[float64]; confident: openArray[bool]):
    seq[(float64, int)] =
  ## The same search as `medianLineStart`, every line's median by a full sort.
  var ids: seq[int]
  for i in 0 ..< pickMs.len:
    if confident[i] and not offs[i].isNaN: ids.add i
  if ids.len < 2: return
  var state = 88172645463325252'u64
  proc draw(n: int): int =
    state = state * 6364136223846793005'u64 + 1442695040888963407'u64
    int((state shr 33) mod uint64(n))
  var best = Inf
  var (bestA, bestS) = (0.0, 0.0)
  var dev = newSeq[float64](ids.len)
  for line in 0 ..< StartLines:
    let (i, j) = (ids[draw(ids.len)], ids[draw(ids.len)])
    if offs[i] != offs[j]:
      let s = (pickMs[j] - pickMs[i]) / (offs[j] - offs[i])
      let a = pickMs[i] - s * offs[i]
      for k, id in ids: dev[k] = abs(pickMs[id] - a - s * offs[id])
      let m = median(dev)
      if m < best: (best, bestA, bestS) = (m, a, s)
  if best == Inf: return
  for id in ids: result.add (abs(pickMs[id] - bestA - bestS * offs[id]), id)
  result.sort()

proc medianStartAgrees() =
  ## `medianLineStart` picks the line a full sort of every line's distances picks.
  var state = 99'u64
  proc draw(n: int): int =
    state = state * 6364136223846793005'u64 + 1442695040888963407'u64
    int((state shr 33) mod uint64(n))
  for trial in 0 ..< 2000:
    let n = 2 + draw(11)
    let levels = 1 + draw(6)
    var offs = newSeq[float64](n)
    var pick = newSeq[float64](n)
    var conf = newSeq[bool](n)
    for i in 0 ..< n:
      let r = draw(100)
      offs[i] = if r < 2: NaN else: float64(draw(levels)) * 25.0
      let q = draw(100)
      pick[i] = if q < 3: Inf elif q < 5 and trial mod 7 == 0: NaN
        else: float64(draw(levels)) * 0.25
      conf[i] = draw(5) != 0
    let want = sortLineStart(offs, pick, conf)
    let got = medianLineStart(offs, pick, conf)
    doAssert sameLine(got, want), "trial " & $trial & " of " & $n & " picks differs"

proc main*() =
  medianStartAgrees()
  trimsAgree()
  mixedLengthsAgree()
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
      for workers in [1, 2, 4, 0]:
        let got = c.breaks(path, workers)
        doAssert got.fingerprint == want.fingerprint, c.name & ": " & $workers & " workers: " &
          got.fingerprint.toHex & " is not the reference's " & want.fingerprint.toHex
    # a stop asked for after the first chunk ends the job, with the pool's threads joined;
    # a normal run and an exception from the progress callback join them too
    block aStopEndsTheJob:
      proc tasks(): int =
        when defined(linux):
          for _ in walkDir("/proc/self/task"): inc result
      proc joined(before: int; what: string) =
        when defined(linux):
          # a joined thread's /proc entry can outlive joinThread by a moment
          var now = tasks()
          var left = 20
          while now != before and left > 0:
            sleep(1)
            dec left
            now = tasks()
          doAssert now == before, what & ": " & $now & " tasks, was " & $before
      let c = Cases[0]
      let path = fx.scene("stop.sgy", c.scene, c.traces, c.samples, c.dtMs)
      var f = openSeismic(path, keys = true)
      let before = tasks()
      let done = breaksOfRecord(addr f, path, 0 ..< f.len, [], workers = 4)
      doAssert done.state == bkDone, $done.state
      joined(before, "normal")
      var calls = 0
      var stopped = false
      try:
        discard breaksOfRecord(addr f, path, 0 ..< f.len, [],
          proc (done, total: int): bool =
          inc calls
          calls < 2, workers = 4)
      except JobCancelledError:
        stopped = true
      doAssert stopped and calls == 2, "stopped " & $stopped & " after " & $calls & " chunks"
      joined(before, "stop")
      var raised = false
      try:
        discard breaksOfRecord(addr f, path, 0 ..< f.len, [],
          proc (done, total: int): bool = raise newException(ValueError, "boom"), workers = 4)
      except ValueError:
        raised = true
      doAssert raised, "the progress callback's error was swallowed"
      joined(before, "exception")
      f.close()
  echo "tfbspeed: ok"

when isMainModule: main()
