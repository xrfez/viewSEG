## The vibrator signature of New plot (wireline tests): a vibrator unit's
## reference (the pilot, Ref), ground force (GF), reaction-mass (M) and
## baseplate (B) accelerations, each a trace of the window as its roles
## (`VibRoles`) say, measured against the reference along the sweep by
## processSEG's `analyzeVibrators`, and drawn against sweep time:
##
## | Plot | Curves |
## |---|---|
## | Phase to the reference | GF, GF (M, B), M, B (degrees) |
## | Force | the fundamental's amplitude and the peak, of GF |
## | Force from M and B | the same of GF (M, B), on an axis of its own (kg × recorded) |
## | Frequency | the reference's and the ground forces' instantaneous frequency |
## | Distortion | THD of GF and GF (M, B); each harmonic of the ground force, % of the fundamental |
##
## - **GF (M, B)** is the ground force generated from M and B, `Mr·a_M +
##   Mb·a_B`, once both masses are entered. Its unit is not the recorded
##   force's (kg × counts, uncalibrated without accelerometer sensitivities),
##   so its force is a plot of its own and the force limits are not applied to it.
## - **Limits** (`AnalysisParams.limitsOn`, off at first) are drawn on the
##   plots (thin lines), the points past them marked, and judged on the two
##   ground forces over the sweep less its tapers; the table says pass or
##   fail per signal.
## - The values are as recorded (no calibration): the force in the
##   recorded units, or N from M and B in m/s² (they are not, unscaled).
##
## Pure: samples in, an `AnalysisResult` out; never raises.

import std/[math, strutils]
import parseSEG
import processSEG/core/[rows, types, units, workspace]
import processSEG/vibroseis/[sweeptrack, vibqc]
import analysis

export VibRole, VibSignal

const
  RecordedRef* = "Ref (recorded)"
    ## the recorded pilot measured against the project's reference: its name in the plots
    ## and the table
  Shown = [vsReference, vsGroundForce, vsWeightedSum, vsMass, vsBaseplate]
    ## the signals in the order the plots and the table give them

func number(x: float64; digits = 1): string =
  if x.isNaN or abs(x) == Inf: "–"
  elif digits == 0: $int64(round(x))
  else: formatFloat(x, ffDecimal, digits)

func past(name: string; xs, ys: seq[float64]; at: seq[bool]): AnalysisCurve =
  ## The points of `ys` where `at`, marked.
  result = AnalysisCurve(name: name & " past a limit", style: csPast,
    ys: newSeq[float64](ys.len))
  for m in 0 ..< ys.len: result.ys[m] = if at[m]: ys[m] else: NaN

func limitLine(name: string; xs: seq[float64]; value: float64): AnalysisCurve =
  ## A limit across the sweep: its two ends.
  AnalysisCurve(name: name, style: csLimit, xs: @[xs[0], xs[^1]], ys: @[value, value])

func anyOf(s: seq[bool]): bool =
  for v in s:
    if v: return true
  false

func forceUnit(u: AmplitudeUnit): string =
  if u == auForce: "N" elif u == auRecorded: "as recorded" else: $u

func weightedUnit(u: AmplitudeUnit): string =
  ## The unit of the weighted sum of the masses: the masses are in kg, the
  ## traces as recorded (counts) unless calibrated.
  if u == auForce: "N" elif u == auRecorded: "kg × as recorded" else: "kg × " & $u

proc vibratorOf*(rows: openArray[seq[float32]]; names: openArray[string];
    at: array[VibRole, int]; dtMs: float64; p: AnalysisParams;
    recorded = -1): AnalysisResult =
  ## The vibrator signature of the unit whose role `r` is row `at[r]` of
  ## `rows` (traces from their first sample at `dtMs`, named `names`; -1:
  ## the unit has none), with the masses, polarities, harmonics and limits
  ## of `p`: four plots against sweep time (five when the force generated from the
  ## masses has an axis of its own), and the table per signal. `recorded` (a
  ## row, -1: none): the unit's recorded pilot when the reference is another
  ## (the project's); it is measured against the reference as a signal of its own,
  ## "Ref (recorded)": a row in the table, a line in the phase and frequency plots.
  result = AnalysisResult(view: avVibrator, dtMs: dtMs)
  if at[vsReference] notin 0 ..< rows.len:
    result.problem = "no reference (Ref): give the pilot's trace that role"
    return
  var cols = 0
  for r in rows: cols = max(cols, r.len)
  if cols < 2:
    result.problem = "the traces have no samples"
    return
  for role in VibRole:
    if at[role] >= rows.len: return AnalysisResult(view: avVibrator, dtMs: dtMs,
      problem: "the " & $role & " role's trace is not among the window's")
    if at[role] >= 0: inc result.used
  var work = newSeq[float32](rows.len * cols)
  var keys = newSeq[TraceKeys](rows.len)
  var counts = newSeq[int](rows.len)
  for i, r in rows:
    keys[i] = initTraceKeys()
    counts[i] = r.len
    if r.len > 0: copyMem(addr work[i * cols], unsafeAddr r[0], r.len * sizeof(float32))
  var unit = VibUnit()
  unit.rows = at
  let pair = at[vsMass] >= 0 and at[vsBaseplate] >= 0
  let masses = p.reactionMassKg > 0 and p.reactionMassKg < Inf and p.baseplateMassKg > 0 and
    p.baseplateMassKg < Inf
  var said: seq[string] = @[]
  unit.polarity[vsGroundForce] = p.roles.groundForcePolarity
  var mb = p.roles.massPolarity
  if mb == poAutomatic and not (pair and masses):
    mb = poAsRecorded
    said.add "M and B as recorded (their automatic polarity is decided from the force " &
      "they make: it needs both, and both masses)"
  unit.polarity[vsMass] = mb
  unit.polarity[vsBaseplate] = mb
  var results: seq[UnitSignature[float32]] = @[]
  let withRecorded = recorded in 0 ..< rows.len and recorded != at[vsReference]
  try:
    if pair and masses:
      unit.reactionMass = mass(p.reactionMassKg, muKilogram)
      unit.baseplateMass = mass(p.baseplateMassKg, muKilogram)
    let limits = if p.limitsOn: p.limits else: VibLimits()
    let meta = initChunkMeta(rowsOf(keys, counts), dtMs)
    let tp = initSweepTrackPlan(float32, TrackParams(harmonics: clamp(p.harmonics, 2, 16),
      thdHarmonics: thAllThatFit),
      dtMs, cols)
    var ws = initWorkspace()
    ws.reserve(vibratorWorkspace(tp))
    var units = @[unit]
    if withRecorded:
      units.add VibUnit(rows: [vsReference: at[vsReference], vsGroundForce: recorded,
        vsMass: -1, vsBaseplate: -1])
    tp.analyzeVibrators(rowBlock(work, rows.len, cols), meta, units, limits, results, ws)
  except ValueError as e:
    result.problem = e.msg
    return
  template u: untyped = results[0]
  let xs = u.tracks[vsReference].timeMs
  var measured = 0
  for f in u.tracks[vsReference].referenceHz:
    if not f.isNaN: inc measured
  if xs.len == 0 or u.reference.extent.startMs.isNaN or measured == 0:
    result.problem = names[at[vsReference]] & ", the reference, is not a sweep: no point " &
      "of it could be measured (" & (if u.reference.extent.startMs.isNaN: "its envelope " &
      "is nowhere within " & $TrackParams().minReferenceDb & " dB of its peak" else:
      "no frequency rises or falls through it: an impulse, a time break?") & ")"
    return
  let forces = [vsGroundForce, vsWeightedSum]
  let main = if vsGroundForce in u.signals: vsGroundForce else: vsWeightedSum
  # Phase to the reference
  var phase = AnalysisPlot(title: "Phase to the reference", xLabel: "Sweep time (ms)",
    xUnit: "ms", yLabel: "Phase (°)", yUnit: "°", xs: xs)
  for s in [vsGroundForce, vsWeightedSum, vsMass, vsBaseplate]:
    if s in u.signals: phase.curves.add AnalysisCurve(name: $s, ys: u.tracks[s].phaseDeg)
  if withRecorded:
    phase.curves.add AnalysisCurve(name: RecordedRef, ys: results[1].tracks[vsGroundForce].phaseDeg)
  # Force: the recorded ground force and the weighted sum of the masses are in
  # different units (counts; kg x counts): a plot, an axis and a unit each
  # (with no recorded ground force, the force is the one from M and B: its unit)
  let fromMasses = main == vsWeightedSum
  var force = AnalysisPlot(xLabel: "Sweep time (ms)", xUnit: "ms", xs: xs,
    title: (if fromMasses: "Force from M and B" else: "Force"),
    yLabel: (if fromMasses: "GF (M, B) (" & weightedUnit(u.units[vsWeightedSum]) & ")"
    else: "Force (" & forceUnit(u.units[main]) & ")"))
  var generated = AnalysisPlot(title: "Force from M and B", xLabel: "Sweep time (ms)",
    xUnit: "ms", yLabel: "GF (M, B) (" & weightedUnit(u.units[vsWeightedSum]) & ")", xs: xs)
  for s in forces:
    if s in u.signals:
      let (plot, name) = if s == vsWeightedSum and main != vsWeightedSum: (addr generated, $s)
                         else: (addr force, $s)
      plot[].curves.add AnalysisCurve(name: name & " fundamental",
        ys: u.tracks[s].amplitude[0])
      plot[].curves.add AnalysisCurve(name: name & " peak", ys: u.tracks[s].peak)
  # Frequency
  var freq = AnalysisPlot(title: "Frequency", xLabel: "Sweep time (ms)", xUnit: "ms",
    yLabel: "Frequency (Hz)", yUnit: "Hz", xs: xs)
  freq.curves.add AnalysisCurve(name: "Ref", ys: u.tracks[vsReference].referenceHz)
  if withRecorded:
    freq.curves.add AnalysisCurve(name: RecordedRef,
      ys: results[1].tracks[vsGroundForce].frequencyHz)
  for s in forces:
    if s in u.signals: freq.curves.add AnalysisCurve(name: $s, ys: u.tracks[s].frequencyHz)
  # Distortion: THD, and each harmonic of the main ground force
  var dist = AnalysisPlot(title: "Distortion", xLabel: "Sweep time (ms)", xUnit: "ms",
    yLabel: "Distortion (%)", yUnit: "%", xs: xs)
  for s in forces:
    if s in u.signals: dist.curves.add AnalysisCurve(name: $s & " THD", ys: u.tracks[s].thdPct)
  let t = u.tracks[main]
  var largest = newSeq[float64](xs.len) # the largest harmonic per point, %
  for m in 0 ..< xs.len: largest[m] = NaN
  for k in 2 .. (if main in u.signals: t.amplitude.len else: 0):
    var pct = newSeq[float64](xs.len)
    for m in 0 ..< xs.len:
      let a1 = t.amplitude[0][m]
      pct[m] = if a1 > 0: 100 * t.amplitude[k - 1][m] / a1 else: NaN
      if not pct[m].isNaN and (largest[m].isNaN or pct[m] > largest[m]): largest[m] = pct[m]
    dist.curves.add AnalysisCurve(name: $main & " H" & $k, ys: pct)
  # Limits: drawn, and the points past them marked
  if p.limitsOn:
    let l = p.limits
    if l.phaseDeg < Inf:
      phase.curves.add limitLine("limit ±" & number(l.phaseDeg) & "°", xs, l.phaseDeg)
      phase.curves.add limitLine("limit ±" & number(l.phaseDeg) & "°", xs, -l.phaseDeg)
    # the force limits are in the unit of the signal the force plot is of (`main`):
    # never drawn or judged on a curve in another unit
    if l.forceLow < Inf: force.curves.add limitLine("lowest force", xs, l.forceLow)
    if l.forceHigh < Inf: force.curves.add limitLine("highest force", xs, l.forceHigh)
    if l.peakForce < Inf: force.curves.add limitLine("highest peak", xs, l.peakForce)
    if l.thdPct < Inf: dist.curves.add limitLine("THD limit", xs, l.thdPct)
    if l.harmonicPct < Inf: dist.curves.add limitLine("harmonic limit", xs, l.harmonicPct)
    for s in forces:
      if s notin u.signals: continue
      template flagged(kinds: set[LimitKind]): seq[bool] =
        var f = newSeq[bool](xs.len)
        for m in 0 ..< xs.len: f[m] = (u.flags[s][m] * kinds) != {}
        f
      let ph = flagged({lkPhase})
      if ph.anyOf: phase.curves.add past($s, xs, u.tracks[s].phaseDeg, ph)
      let lowHigh = flagged({lkForceLow, lkForceHigh})
      if lowHigh.anyOf and s == main:
        force.curves.add past($s & " fundamental", xs, u.tracks[s].amplitude[0], lowHigh)
      let pk = flagged({lkPeakForce})
      if pk.anyOf and s == main: force.curves.add past($s & " peak", xs, u.tracks[s].peak, pk)
      let th = flagged({lkThd})
      if th.anyOf: dist.curves.add past($s & " THD", xs, u.tracks[s].thdPct, th)
      if s == main:
        let hk = flagged({lkHarmonic})
        if hk.anyOf: dist.curves.add past($s & " harmonic", xs, largest, hk)
  result.plots = @[phase, force]
  if generated.curves.len > 0: result.plots.add generated
  result.plots.add [freq, dist]
  # The table: one row per signal
  var head = @["Signal", "Trace", "Polarity", "Mean |phase| (°)", "Max |phase| (°)",
    "Mean THD (%)", "Max THD (%)", "Mean force", "Min force", "Max peak"]
  if p.limitsOn: head.add "Limits"
  result.table.add head
  for s in Shown:
    if s notin u.signals: continue
    let m = u.summaries[s]
    let trace = if s == vsWeightedSum: "M, B" else: names[at[VibRole(s)]]
    var row = @[$s, trace, (if s in u.reversed: "reversed" else: "as recorded"),
      number(m.meanAbsPhaseDeg), number(m.maxAbsPhaseDeg), number(m.meanThdPct),
      number(m.maxThdPct), number(m.meanForce, 3), number(m.minForce, 3),
      number(m.maxPeak, 3)]
    # the force limits are not applied to a force in another unit than theirs
    let ownUnit = if s == vsWeightedSum and main != vsWeightedSum:
                    {lkForceLow, lkForceHigh, lkPeakForce, lkMeanForce}
                  else: {}
    if p.limitsOn:
      row.add(if s notin forces: "not judged"
              elif m.points == 0: "not judged (no point)"
              elif m.failed - ownUnit == {}: "pass"
              else:
                var what: seq[string] = @[]
                for k in m.failed - ownUnit: what.add $k
                "fail: " & what.join(", "))
    result.table.add row
    result.forceUnits.add(if s == vsWeightedSum: weightedUnit(u.units[s])
                           else: forceUnit(u.units[s]))
  if withRecorded:
    # the recorded pilot, measured against the reference: just after the Ref row
    let m = results[1].summaries[vsGroundForce]
    var row = @[RecordedRef, names[recorded], "as recorded", number(m.meanAbsPhaseDeg),
      number(m.maxAbsPhaseDeg), number(m.meanThdPct), number(m.maxThdPct),
      number(m.meanForce, 3), number(m.minForce, 3), number(m.maxPeak, 3)]
    if p.limitsOn: row.add "not judged"
    var at1 = result.table.len
    for i in 1 ..< result.table.len:
      if result.table[i][0] == $vsReference: at1 = i + 1
    result.table.insert(row, at1)
    result.forceUnits.insert(forceUnit(results[1].units[vsGroundForce]), at1 - 1)
  # The words: which trace is which, and how
  var roles: seq[string] = @[]
  for role in VibRole:
    if at[role] >= 0: roles.add $role & " " & names[at[role]]
  var words = roles.join(" · ")
  if vsWeightedSum in u.signals:
    words.add "; GF (M, B) = " & number(p.reactionMassKg, 0) & " kg·M + " &
      number(p.baseplateMassKg, 0) & " kg·B"
  elif pair:
    words.add "; enter both masses to generate GF from M and B"
  words.add "; values as recorded; THD sums harmonics 2 to " & $clamp(p.harmonics, 2, 16) &
    " while below 80 % of Nyquist (harmonics above Nyquist are left out)"
  if vsWeightedSum in u.signals:
    words.add "; GF (M, B) is uncalibrated without accelerometer sensitivities: in " &
      weightedUnit(u.units[vsWeightedSum]) & ", on an axis of its own"
    if p.limitsOn and main != vsWeightedSum:
      words.add " (the force limits are in " & forceUnit(u.units[main]) &
        " and are not applied to it)"
  let e = u.reference.extent
  if p.limitsOn:
    let span = e.judgedPart(p.limits)
    words.add "; judged from " & number(span.a, 0) & " to " & number(span.b, 0) &
      " ms (the sweep less its tapers)"
  for s in said: words.add "; " & s
  result.note = words
