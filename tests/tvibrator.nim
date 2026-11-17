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
## - the recorded force and the one generated from the masses are in plots and axes of
##   their own (counts; kg × counts); a force limit is drawn and judged on GF alone;
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

func waveSplit(amp, phaseA, phaseB: float64): seq[float32] =
  ## The sweep at phase A for its first half, phase B for its second.
  result = newSeq[float32](N)
  for j in 0 ..< N:
    let t = float64(j) * Dt / 1000
    let p = 2 * PI * (F0 * t + (F1 - F0) / (2 * T) * t * t)
    let phaseDeg = if t < T / 2: phaseA else: phaseB
    result[j] = float32(amp * taper(t) * sin(p + degToRad(phaseDeg)))

func wave(amp, phaseDeg: float64; h2 = 0.0): seq[float32] =
  result = newSeq[float32](N)
  for j in 0 ..< N:
    let t = float64(j) * Dt / 1000
    let p = 2 * PI * (F0 * t + (F1 - F0) / (2 * T) * t * t)
    result[j] = float32(amp * taper(t) * (sin(p + degToRad(phaseDeg)) + h2 * sin(2 * p)))

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
  let tp = initSweepTrackPlan(float32, TrackParams(thdHarmonics: thAllThatFit), Dt, N)
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

func sizes(deg: seq[float64]): seq[float64] =
  ## the phase as Absolute draws it
  shownPhase(deg, psAbsolute).ys

proc main*() =

  let unitRows = @[wave(1, 0), wave(1000, 15, 0.1), wave(30, 10), wave(25, -170)]
  let names = @["trace 1", "trace 2", "trace 3", "trace 4"]
  let inOrder = [vsReference: 0, vsGroundForce: 1, vsMass: 2, vsBaseplate: 3]
  let params = AnalysisParams(reactionMassKg: Mr, baseplateMassKg: Mb)

  block theLibrarysNumbers:
    let r = vibratorOf(unitRows, names, inOrder, Dt, params)
    doAssert r.problem == "", r.problem
    doAssert r.plots.len == 5 and r.used == 4 and r.plots[2].title == "Force from M and B"
    let lib = library(unitRows, inOrder)
    doAssert r.plots[0].xs.sameAs(lib.tracks[vsReference].timeMs)
    doAssert r.curve(0, "GF").sameAs(sizes(lib.tracks[vsGroundForce].phaseDeg)),
      "GF's phase is not the library's"
    doAssert r.curve(0, "GF (M, B)").sameAs(sizes(lib.tracks[vsWeightedSum].phaseDeg))
    doAssert r.curve(0, "M").sameAs(sizes(lib.tracks[vsMass].phaseDeg))
    doAssert r.curve(0, "B").sameAs(sizes(lib.tracks[vsBaseplate].phaseDeg))
    doAssert r.curve(1, "GF fundamental").sameAs(lib.tracks[vsGroundForce].amplitude[0])
    doAssert r.curve(1, "GF peak").sameAs(lib.tracks[vsGroundForce].peak)
    doAssert r.curve(2, "GF (M, B) fundamental").sameAs(lib.tracks[vsWeightedSum].amplitude[0])
    doAssert r.curve(3, "Ref").sameAs(lib.tracks[vsReference].referenceHz)
    doAssert r.curve(3, "GF").sameAs(lib.tracks[vsGroundForce].frequencyHz)
    doAssert r.curve(4, "GF THD").sameAs(lib.tracks[vsGroundForce].thdPct)
    doAssert r.curve(4, "GF (M, B) THD").sameAs(lib.tracks[vsWeightedSum].thdPct)
    # no limits: none drawn, none judged
    for p in r.plots:
      for c in p.curves:
        doAssert c.style == csLine, "a limit drawn while limits are off: " & c.name
    doAssert r.table.len == 6 and r.table[0][^1] == "Max peak", $r.table[0]
    # each row names the stored unit of its force columns, the one in its axis
    # Seen to fail: with no unit kept, forceUnits was empty and the window
    # could not scale "Max peak" when the axis said lbf.
    doAssert r.forceUnits.len == r.table.len - 1, $r.forceUnits
    for i, row in r.table[1 .. ^1]:
      doAssert r.forceUnits[i].len > 0, row[0]
      if row[0] == "GF":
        doAssert r.forceUnits[i] in r.plots[1].yLabel, r.forceUnits[i] & " / " & r.plots[1].yLabel
      if row[0] == "GF (M, B)":
        doAssert r.forceUnits[i] in r.plots[2].yLabel, r.forceUnits[i] & " / " & r.plots[2].yLabel

  block whatWasMade:
    let r = vibratorOf(unitRows, names, inOrder, Dt, params)
    let xs = r.plots[0].xs
    let phase = r.curve(0, "GF")
    let fund = r.curve(1, "GF fundamental")
    let thd = r.curve(4, "GF THD")
    let h2 = r.curve(4, "GF H2")
    let hz = r.curve(3, "GF")
    # the generated force: Mr·M + Mb·B, as phasors
    let z = Mr * 30.0 * exp(complex(0.0, degToRad(10.0))) +
      Mb * 25.0 * exp(complex(0.0, degToRad(-170.0)))
    let ws = r.curve(2, "GF (M, B) fundamental")
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
    doAssert a.plots.len == b.plots.len
    for p in 0 ..< a.plots.len:
      doAssert a.plots[p].curves.len == b.plots[p].curves.len
      for c in 0 ..< a.plots[p].curves.len:
        doAssert a.plots[p].curves[c].ys.sameAs(b.plots[p].curves[c].ys),
          a.plots[p].curves[c].name & " differs with the roles in another order"
    doAssert "Ref trace 2 · GF trace 4 · M trace 3 · B trace 1" in b.note, b.note

  block limits:
    var p = params
    p.limitsOn = true
    p.limits = VibLimits(phaseDeg: 10)
    p.phaseShow = psSigned
    let signed = vibratorOf(unitRows, names, inOrder, Dt, p)
    var both = 0
    for c in signed.plots[0].curves:
      if c.style == csLimit: inc both
    doAssert both == 2, "Signed: the limit at both ends, " & $both
    p.phaseShow = psAbsolute
    let r = vibratorOf(unitRows, names, inOrder, Dt, p)
    var drawn, marked = 0
    for c in r.plots[0].curves:
      if c.style == csLimit:
        inc drawn
        doAssert c.ys == @[10.0, 10.0], "Absolute: the one size, " & $c.ys
      elif c.style == csLine:
        for y in c.ys: doAssert y.isNaN or y >= 0, "Absolute phase below 0: " & $y
      if c.style == csPast and c.name == "GF past a limit":
        for y in c.ys:
          if not y.isNaN:
            doAssert abs(y) > 10, $y
            inc marked
    doAssert drawn == 1 and marked > 400, $(drawn, marked)
    doAssert r.table[0][^1] == "Limits"
    for row in r.table[1 .. ^1]:
      if row[0] == "GF": doAssert row[^1] == "fail: phase", $row
      if row[0] == "M": doAssert row[^1] == "not judged", $row
    doAssert "judged from " in r.note, r.note
    p.limits = VibLimits(phaseDeg: 20)
    let ok = vibratorOf(unitRows, names, inOrder, Dt, p)
    for row in ok.table[1 .. ^1]:
      if row[0] == "GF": doAssert row[^1] == "pass", $row

  block forceInItsOwnUnit:
    # the recorded GF (1000, as recorded) and the weighted sum (2.4e6, kg x as
    # recorded) are on axes of their own, and a force limit is judged on GF only
    var p = params
    p.limitsOn = true
    p.limits = VibLimits(forceLow: 2000)
    let r = vibratorOf(unitRows, names, inOrder, Dt, p)
    doAssert r.plots[1].title == "Force" and r.plots[2].title == "Force from M and B"
    doAssert "as recorded" in r.plots[1].yLabel and "kg × as recorded" in r.plots[2].yLabel,
      r.plots[1].yLabel & " / " & r.plots[2].yLabel
    for c in r.plots[1].curves: doAssert not c.name.startsWith("GF (M, B)"), c.name
    for c in r.plots[2].curves:
      doAssert c.name.startsWith("GF (M, B)") and c.style == csLine,
        "a force limit on the weighted sum: " & c.name
    var lines = 0
    for c in r.plots[1].curves:
      if c.style == csLimit: inc lines
    doAssert lines == 1, $lines & " force limit lines on GF"
    for row in r.table[1 .. ^1]:
      if row[0] == "GF": doAssert row[^1] == "fail: force low", $row
      if row[0] == "GF (M, B)": doAssert row[^1] == "pass", $row
    doAssert "uncalibrated without accelerometer sensitivities" in r.note and
      "not applied" in r.note, r.note

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

  block meanAbsPhase:
    # the table's mean phase is the mean of |phase|, the one the limit judges:
    # +8° then -8° is 8 on average, not 0
    let rows = @[unitRows[0], waveSplit(1000, 8, -8), unitRows[2], unitRows[3]]
    var p = params
    p.limitsOn = true
    p.limits = VibLimits(phaseDeg: 20, meanPhaseDeg: 5)
    let r = vibratorOf(rows, names, inOrder, Dt, p)
    doAssert r.problem == "", r.problem
    doAssert r.table[0][3] == "Mean |phase| (°)", r.table[0][3]
    var found = false
    for row in r.table[1 .. ^1]:
      if row[0] == "GF":
        found = true
        let mean = parseFloat(row[3])
        doAssert abs(mean - 8) < 0.5, "mean |phase| " & row[3] & ", want about 8"
        doAssert row[^1] == "fail: mean phase", row[^1]
    doAssert found

  block noGroundForce:
    # no recorded ground force, the masses making one: its plot is the force
    # from M and B, labelled in that unit (kg x as recorded), not as the force's.
    # Seen to fail: "Force (as recorded)" as the plot's axis.
    let r = vibratorOf(unitRows, names, [vsReference: 0, vsGroundForce: -1, vsMass: 2,
      vsBaseplate: 3], Dt, params)
    doAssert r.problem == "", r.problem
    let f = r.plots[1]
    doAssert f.title == "Force from M and B" and f.yLabel == "GF (M, B) (kg × as recorded)",
      f.title & " / " & f.yLabel
    doAssert f.curves.len == 2 and f.curves[0].name == "GF (M, B) fundamental", $f.curves.len

  block thdPastNyquist:
    # THD at each time sums the harmonics still below 80 % of Nyquist (400 Hz at 1 ms):
    # with 16 tracked, H16 is measured only below 25 Hz, but THD goes on to where
    # the 2nd is (to 200 Hz, past the sweep's 80 Hz), and the note says so.
    # Seen to fail: with the viewer asking the library for the fixed set (every one of
    # 2 .. 16 or no THD), "GF THD has 0 points past H16's".
    var p = params
    p.harmonics = 16
    let r = vibratorOf(unitRows, names, inOrder, Dt, p)
    doAssert r.problem == "", r.problem
    let thd = r.curve(4, "GF THD")
    let h16 = r.curve(4, "GF H16")
    var (nThd, nH16, thdAfterH16) = (0, 0, 0)
    var lastH16 = -1
    for m in 0 ..< thd.len:
      if not h16[m].isNaN: (inc nH16; lastH16 = m)
    for m in 0 ..< thd.len:
      if not thd[m].isNaN:
        inc nThd
        if m > lastH16: inc thdAfterH16
    doAssert nH16 > 0 and nThd > nH16 and thdAfterH16 > 20,
      "GF THD has " & $thdAfterH16 & " points past H16's (" & $nThd & " against " & $nH16 & ")"
    doAssert "harmonics above Nyquist are left out" in r.note, r.note

  block recordedReference:
    # the project's reference as Ref, the recorded pilot (here 5° off it) measured against
    # it as a signal of its own: a table row after Ref, a line in the phase and the
    # frequency plots; with no recorded row, none of them.
    # Seen to fail: with `recorded` ignored, "no row Ref (recorded)".
    let rows = unitRows & @[wave(1, 5)]
    let all = @["trace 1", "trace 2", "trace 3", "trace 4", "trace 5"]
    let r = vibratorOf(rows, all, inOrder, Dt, params, recorded = 4)
    doAssert r.problem == "", r.problem
    var at = -1
    for i, row in r.table:
      if row[0] == RecordedRef: at = i
    doAssert at == 2 and r.table[1][0] == "Ref", "no row " & RecordedRef & " after Ref: " &
      $r.table
    doAssert r.table[at][1] == "trace 5", $r.table[at]
    doAssert r.forceUnits.len == r.table.len - 1, $r.forceUnits
    let phase = r.curve(0, RecordedRef)
    var sum, n = 0.0
    for m in judged(r.plots[0].xs):
      if not phase[m].isNaN: (sum += phase[m]; n += 1)
    doAssert n > 10 and abs(sum / n - 5) < 0.5, "the recorded pilot's phase " & $(sum / n)
    discard r.curve(3, RecordedRef)
    let plain = vibratorOf(unitRows, names, inOrder, Dt, params)
    doAssert plain.table.len == 6
    for row in plain.table: doAssert row[0] != RecordedRef

  echo "tvibrator: ok"

when isMainModule:
  main()
