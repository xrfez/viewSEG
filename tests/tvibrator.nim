## The vibrator signature (New plot, `core/vibanalysis`) on a synthetic
## unit made apart from the library: a linear sweep (8 to 80 Hz over 6 s,
## cos² tapers of 300 ms) as the reference; a ground force of 1000 at +15°
## to it with a 2nd harmonic of 10 %; M at 30 and +10°, B at 25 and -170°:
##
## - the plots' numbers are the library's (`analyzeVibrators` on the same
##   rows, called here);
## - and they are what was made: GF at 15° to the reference, its
##   fundamental 1000, its THD 10 %, its frequency the sweep's; GF (M, B)
##   the weighted sum's amplitude and phase worked out here from the masses;
## - the roles in another order (B, Ref, M, GF) give the same numbers;
## - limits: off, nothing is drawn or judged; a phase limit of 10° fails GF
##   (its points past it marked, the table says "fail: phase"), one of 20°
##   passes it;
## - without masses there is no generated force, and the words say how to
##   have one; without a reference, or with an impulse as the reference,
##   nothing (the problem said).
##
## Seen to fail: with the phase plot fed the reference's phase instead of
## each signal's, "GF's phase is not the library's"; with the harmonics
## taken as a fraction rather than %, "GF H2 0.10002390139435 %, want 10";
## with the limits applied while off, "a limit drawn while limits are off:
## limit ±10.0°"; with a reference that has an extent but no measured
## point taken as a sweep, `"trace 1, the reference, is not a sweep" in
## impulse.problem` (no problem said: every number a dash).

import std/[complex, math, strutils]
import parseSEG
import processSEG/core/[rows, types, units, workspace]
import processSEG/vibroseis/[sweeptrack, vibqc]
import viewSEG/core/[analysis, vibanalysis]

const
  Dt = 1.0
  (F0, F1, T) = (8.0, 80.0, 6.0) # Hz, Hz, s
  Ramp = 0.3                     # s
  N = 7000
  (Mr, Mb) = (2450.0, 1180.0)

func taper(t: float64): float64 =
  if t < 0 or t > T: 0.0
  elif t < Ramp: cos(PI / 2 * (1 - t / Ramp)) ^ 2
  elif T - t < Ramp: cos(PI / 2 * (1 - (T - t) / Ramp)) ^ 2
  else: 1.0

func wave(amp, phaseDeg: float64; h2 = 0.0): seq[float32] =
  result = newSeq[float32](N)
  for j in 0 ..< N:
    let t = float64(j) * Dt / 1000
    let p = 2 * PI * (F0 * t + (F1 - F0) / (2 * T) * t * t)
    result[j] = float32(amp * taper(t) * (sin(p + degToRad(phaseDeg)) + h2 * sin(2 * p)))

let unitRows = @[wave(1, 0), wave(1000, 15, 0.1), wave(30, 10), wave(25, -170)]
let names = @["trace 1", "trace 2", "trace 3", "trace 4"]
let inOrder = [vsReference: 0, vsGroundForce: 1, vsMass: 2, vsBaseplate: 3]
let params = AnalysisParams(reactionMassKg: Mr, baseplateMassKg: Mb)

func curve(r: AnalysisResult; plot: int; name: string): seq[float64] =
  for c in r.plots[plot].curves:
    if c.name == name: return c.ys
  doAssert false, "no curve " & name & " in " & r.plots[plot].title

proc library(rows: seq[seq[float32]]; at: array[VibRole, int]): UnitSignature[float32] =
  ## The library's own measures of the same rows.
  var work = newSeq[float32](rows.len * N)
  for i, r in rows:
    for j in 0 ..< N: work[i * N + j] = r[j]
  var keys = newSeq[TraceKeys](rows.len)
  for k in keys.mitems: k = initTraceKeys()
  var counts = newSeq[int](rows.len)
  for c in counts.mitems: c = N
  let meta = initChunkMeta(rowsOf(keys, counts), Dt)
  let tp = initSweepTrackPlan(float32, TrackParams(), Dt, N)
  var ws = initWorkspace()
  ws.reserve(vibratorWorkspace(tp))
  var unit = initVibUnit(at[vsReference], at[vsGroundForce], at[vsMass], at[vsBaseplate],
    mass(Mr, muKilogram), mass(Mb, muKilogram))
  var res: seq[UnitSignature[float32]] = @[]
  tp.analyzeVibrators(rowBlock(work, rows.len, N), meta, [unit], VibLimits(), res, ws)
  res[0]

func sameAs(a, b: seq[float64]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if not (a[i] == b[i] or (a[i].isNaN and b[i].isNaN)): return false
  true

func judged(xs: seq[float64]): seq[int] =
  ## The points well inside the flat part of the sweep.
  for m, x in xs:
    if x >= 600 and x <= 5400: result.add m

block theLibrarysNumbers:
  let r = vibratorOf(unitRows, names, inOrder, Dt, params)
  doAssert r.problem == "", r.problem
  doAssert r.plots.len == 4 and r.used == 4
  let lib = library(unitRows, inOrder)
  doAssert r.plots[0].xs.sameAs(lib.tracks[vsReference].timeMs)
  doAssert r.curve(0, "GF").sameAs(lib.tracks[vsGroundForce].phaseDeg),
    "GF's phase is not the library's"
  doAssert r.curve(0, "GF (M, B)").sameAs(lib.tracks[vsWeightedSum].phaseDeg)
  doAssert r.curve(0, "M").sameAs(lib.tracks[vsMass].phaseDeg)
  doAssert r.curve(0, "B").sameAs(lib.tracks[vsBaseplate].phaseDeg)
  doAssert r.curve(1, "GF fundamental").sameAs(lib.tracks[vsGroundForce].amplitude[0])
  doAssert r.curve(1, "GF peak").sameAs(lib.tracks[vsGroundForce].peak)
  doAssert r.curve(1, "GF (M, B) fundamental").sameAs(lib.tracks[vsWeightedSum].amplitude[0])
  doAssert r.curve(2, "Ref").sameAs(lib.tracks[vsReference].referenceHz)
  doAssert r.curve(2, "GF").sameAs(lib.tracks[vsGroundForce].frequencyHz)
  doAssert r.curve(3, "GF THD").sameAs(lib.tracks[vsGroundForce].thdPct)
  doAssert r.curve(3, "GF (M, B) THD").sameAs(lib.tracks[vsWeightedSum].thdPct)
  # no limits: none drawn, none judged
  for p in r.plots:
    for c in p.curves:
      doAssert c.style == csLine, "a limit drawn while limits are off: " & c.name
  doAssert r.table.len == 6 and r.table[0][^1] == "Max peak", $r.table[0]

block whatWasMade:
  let r = vibratorOf(unitRows, names, inOrder, Dt, params)
  let xs = r.plots[0].xs
  let phase = r.curve(0, "GF")
  let fund = r.curve(1, "GF fundamental")
  let thd = r.curve(3, "GF THD")
  let h2 = r.curve(3, "GF H2")
  let hz = r.curve(2, "GF")
  # the generated force: Mr·M + Mb·B, as phasors
  let z = Mr * 30.0 * exp(complex(0.0, degToRad(10.0))) +
    Mb * 25.0 * exp(complex(0.0, degToRad(-170.0)))
  let ws = r.curve(1, "GF (M, B) fundamental")
  let wsPhase = r.curve(0, "GF (M, B)")
  let points = judged(xs)
  doAssert points.len > 400, $points.len
  for m in points:
    let t = xs[m] / 1000
    doAssert abs(phase[m] - 15) < 0.5, "GF phase " & $phase[m] & " at " & $xs[m] & " ms"
    doAssert abs(fund[m] - 1000) < 10, "GF fundamental " & $fund[m] & " at " & $xs[m] & " ms"
    doAssert abs(thd[m] - 10) < 0.3, "GF THD " & $thd[m] & " % at " & $xs[m] & " ms"
    doAssert abs(h2[m] - 10) < 0.3, "GF H2 " & $h2[m] & " %, want 10"
    doAssert abs(hz[m] - (F0 + (F1 - F0) * t / T)) < 0.2, "GF at " & $hz[m] & " Hz"
    doAssert abs(ws[m] - abs(z)) < 0.01 * abs(z), "GF (M, B) " & $ws[m] & ", want " & $abs(z)
    doAssert abs(wsPhase[m] - radToDeg(phase(z))) < 0.5, "GF (M, B) at " & $wsPhase[m] &
      "°, want " & $radToDeg(phase(z))
  doAssert "GF (M, B) = 2450 kg·M + 1180 kg·B" in r.note, r.note

block anotherOrder:
  # B, Ref, M, GF
  let shuffled = @[unitRows[3], unitRows[0], unitRows[2], unitRows[1]]
  let at = [vsReference: 1, vsGroundForce: 3, vsMass: 2, vsBaseplate: 0]
  let a = vibratorOf(unitRows, names, inOrder, Dt, params)
  let b = vibratorOf(shuffled, names, at, Dt, params)
  for p in 0 ..< 4:
    doAssert a.plots[p].curves.len == b.plots[p].curves.len
    for c in 0 ..< a.plots[p].curves.len:
      doAssert a.plots[p].curves[c].ys.sameAs(b.plots[p].curves[c].ys),
        a.plots[p].curves[c].name & " differs with the roles in another order"
  doAssert "Ref trace 2 · GF trace 4 · M trace 3 · B trace 1" in b.note, b.note

block limits:
  var p = params
  p.limitsOn = true
  p.limits = VibLimits(phaseDeg: 10)
  let r = vibratorOf(unitRows, names, inOrder, Dt, p)
  var drawn, marked = 0
  for c in r.plots[0].curves:
    if c.style == csLimit:
      inc drawn
      doAssert c.ys == @[10.0, 10.0] or c.ys == @[-10.0, -10.0], $c.ys
    if c.style == csPast and c.name == "GF past a limit":
      for y in c.ys:
        if not y.isNaN:
          doAssert abs(y) > 10, $y
          inc marked
  doAssert drawn == 2 and marked > 400, $(drawn, marked)
  doAssert r.table[0][^1] == "Limits"
  for row in r.table[1 .. ^1]:
    if row[0] == "GF": doAssert row[^1] == "fail: phase", $row
    if row[0] == "M": doAssert row[^1] == "not judged", $row
  doAssert "judged from " in r.note, r.note
  p.limits = VibLimits(phaseDeg: 20)
  let ok = vibratorOf(unitRows, names, inOrder, Dt, p)
  for row in ok.table[1 .. ^1]:
    if row[0] == "GF": doAssert row[^1] == "pass", $row

block noMassesNoReference:
  let r = vibratorOf(unitRows, names, inOrder, Dt, AnalysisParams())
  doAssert r.problem == ""
  for c in r.plots[0].curves: doAssert c.name != "GF (M, B)"
  doAssert "enter both masses" in r.note, r.note
  let none = vibratorOf(unitRows, names, [vsReference: -1, vsGroundForce: 1, vsMass: 2,
    vsBaseplate: 3], Dt, params)
  doAssert none.problem.startsWith("no reference"), none.problem
  # an impulse as the reference: not a sweep, said
  var spike = newSeq[float32](N)
  spike[100] = 1
  let impulse = vibratorOf(@[spike, unitRows[1]], names, [vsReference: 0, vsGroundForce: 1,
    vsMass: -1, vsBaseplate: -1], Dt, params)
  doAssert "trace 1, the reference, is not a sweep" in impulse.problem, impulse.problem
  # NaN settings compare equal (a window asks again only on a change)
  doAssert AnalysisParams() == AnalysisParams()

echo "tvibrator: ok"
