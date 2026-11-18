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
import analysis, signalend, vibjudge

export VibRole, VibSignal

const
  RecordedRef* = "Ref (recorded)"
    ## the recorded pilot measured against the project's reference: its name in the plots
    ## and the table
  RecordedMean = "window means, "
    ## the start of the name of a stepped curve of the window means of the judged signal
  Shown = [vsReference, vsGroundForce, vsWeightedSum, vsMass, vsBaseplate]
    ## the signals in the order the plots and the table give them

func number(x: float64; digits = 1): string =
  if x.isNaN or abs(x) == Inf: "–"
  elif digits == 0: $int64(round(x))
  else: formatFloat(x, ffDecimal, digits)

func forceCell(x: float64): string =
  ## A force for the table: four significant digits whatever its size (a force in volts is
  ## 0.001 2, one in counts 13 202), scientific outside 0.001 to 10 million.
  forceNumber(x)

func past(name: string; xs, ys: seq[float64]; at: seq[bool]): AnalysisCurve =
  ## The points of `ys` where `at`, marked.
  result = AnalysisCurve(name: name & " past a limit", style: csPast,
    ys: newSeq[float64](ys.len))
  for m in 0 ..< ys.len: result.ys[m] = if at[m]: ys[m] else: NaN

func phaseCurve(name: string; deg: seq[float64]; mode: PhaseShow): AnalysisCurve =
  ## A phase to the reference as `mode` shows it (`phaseshow`); Absolute keeps the signed
  ## value for the readout's brackets.
  let shown = shownPhase(deg, mode)
  result = AnalysisCurve(name: name, ys: shown.ys)
  if mode == psAbsolute: result.brackets = shown.signed

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

func windowPeriods(p: TrackParams; f: float64): int =
  ## The periods of the tracker's window at reference frequency `f`: `cycles`, or where
  ## those are shorter than `minWindowMs` the smallest even number that reaches it.
  result = p.cycles
  let need = p.minWindowMs * f / 1000
  if float64(result) / f * 1000 < p.minWindowMs: result = 2 * int(ceil(need / 2))

func shortEndMs(track: SweepTrack; p: TrackParams; counts: openArray[int];
    at: array[VibRole, int]; dtMs: float64; cols: int): float64 =
  ## The last point (ms) of the reference's track whose window lies inside the shortest
  ## of the signal rows, when one is shorter than the reference (or than the longest row);
  ## NaN when none is, or no point does.
  result = NaN
  var shortest = cols
  for role in [vsGroundForce, vsMass, vsBaseplate]:
    if at[role] >= 0: shortest = min(shortest, counts[at[role]])
  if shortest < cols and shortest > 0:
    let last = float64(shortest - 1) * dtMs
    for m in countdown(track.len - 1, 0):
      let f = track.referenceHz[m]
      if result.isNaN and not f.isNaN and f > 0 and
          track.timeMs[m] + 500.0 * float64(windowPeriods(p, f)) / f <= last:
        result = track.timeMs[m]

proc vibratorOf*(rows: openArray[seq[float32]]; names: openArray[string];
    at: array[VibRole, int]; dtMs: float64; p: AnalysisParams;
    recorded = -1; topHz = NaN; exactTopHz = NaN): AnalysisResult =
  ## The vibrator signature of the unit whose role `r` is row `at[r]` of
  ## `rows` (traces from their first sample at `dtMs`, named `names`; -1:
  ## the unit has none), with the masses, polarities, harmonics and limits
  ## of `p`: four plots against sweep time (five when the force generated from the
  ## masses has an axis of its own), and the table per signal. `recorded` (a
  ## row, -1: none): the unit's recorded pilot when the reference is another
  ## (the project's); it is measured against the reference as a signal of its own,
  ## "Ref (recorded)": a row in the table, a line in the phase and frequency plots.
  ## Distortion is the harmonics within a band whose edge is `topHz` (typed; NaN: none
  ## typed), else `exactTopHz` (a generated reference's end frequency; NaN: not generated),
  ## else the reference's own estimated top (`result.band` says which).
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
  var limits = VibLimits()
  var cutMs = NaN # the judged part ends here: the shortest trace's last measurable point
  var band = NaN
  try:
    if pair and masses:
      unit.reactionMass = mass(p.reactionMassKg, muKilogram)
      unit.baseplateMass = mass(p.baseplateMassKg, muKilogram)
    limits = if p.limitsOn: p.limits else: VibLimits()
    let meta = initChunkMeta(rowsOf(keys, counts), dtMs)
    band = if topHz.isNaN: exactTopHz else: topHz
    let tp = initSweepTrackPlan(float32, TrackParams(harmonics: clamp(
        p.harmonics, 2, 16),
      thdHarmonics: thAllThatFit, harmonicBandHz: band,
          harmonicBandAuto: band.isNaN),
      dtMs, cols)
    var ws = initWorkspace()
    ws.reserve(vibratorWorkspace(tp))
    var units = @[unit]
    if withRecorded:
      units.add VibUnit(rows: [vsReference: at[vsReference], vsGroundForce: recorded,
        vsMass: -1, vsBaseplate: -1])
    for pass in 0 .. 1:
      tp.analyzeVibrators(rowBlock(work, rows.len, cols), meta, units, limits,
          results, ws)
      # a trace shorter than the reference ends the judged part: its zero-padded rest is no
      # measurement (a point whose window reaches past its last sample stays out)
      let cut = if pass == 0: shortEndMs(results[0].tracks[vsReference], tp.params, counts, at,
                  dtMs, cols) else: NaN
      if cut.isNaN: break
      cutMs = cut
      limits.toMs = if limits.toMs.isNaN: cutMs else: min(limits.toMs, cutMs)
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
  # The verdict: statistics per window of the sweep, judged against the QC limits. The
  # judged part is the sweep less its tapers (or the skips of the point limits), to the
  # trace's end when it is shorter than the reference. With both ground forces the
  # choice is the user's (`roles.judge`); the recorded one is the default.
  let both = vsGroundForce in u.signals and vsWeightedSum in u.signals
  let judged = if both and p.roles.judge == joWeighted: vsWeightedSum else: main
  let judging = VibLimits(skipStartMs: limits.skipStartMs,
    skipEndMs: limits.skipEndMs,
    fromMs: limits.fromMs, toMs: limits.toMs)
  let span = u.reference.extent.judgedPart(judging)
  func statsOf(t: SweepTrack): WindowStats =
    try: windowStats(t, judging, p.qcWindowMs)
    except ValueError: windowStats(t, judging)
  let stats = statsOf(u.tracks[judged])
  # each signal has its own full scale (counts, or kg × counts)
  let hundredFor = if judged == vsWeightedSum: p.forceHundredWeighted else: p.forceHundredPct
  result.qc = judge(stats.summary, p.qcWindowMs, p.qc, hundredFor, p.targetPct,
    (if both: $judged else: ""))
  result.judged = $judged
  result.bothSignals = both
  result.judgedAxis = if judged == vsWeightedSum:
      "GF (M, B) (" & weightedUnit(u.units[vsWeightedSum]) & ")"
    else: "Force (" & forceUnit(u.units[vsGroundForce]) & ")"
  if both and p.roles.judge == joRecorded:
    # the recorded GF is the weighted sum the recorder wrote with its own masses: say so when
    # the sum formed here with the typed masses tells another story (phase by window, the
    # level ratio's range in dB)
    let other = statsOf(u.tracks[vsWeightedSum])
    # window by window: the level ratio recorded / formed here in dB (its range along the
    # sweep: a constant gain is no mismatch) and the difference of the signed phases
    var lo, hi = NaN
    for i in 0 ..< min(stats.startMs.len, other.startMs.len):
      if stats.meanForce[i] > 0 and other.meanForce[i] > 0:
        let r = 20 * log10(stats.meanForce[i] / other.meanForce[i])
        lo = if lo.isNaN: r else: min(lo, r)
        hi = if hi.isNaN: r else: max(hi, r)
    let rangeDb = if lo.isNaN: NaN else: hi - lo
    var maxPhase = NaN
    let tg = u.tracks[vsGroundForce]
    let tw = u.tracks[vsWeightedSum]
    for i in 0 ..< min(stats.startMs.len, other.startMs.len):
      var sx, sy = 0.0
      var n = 0
      for m in 0 ..< tg.len:
        let t = tg.timeMs[m]
        if t >= stats.startMs[i] and t < stats.startMs[i] + stats.windowMs and
            not (tg.phaseDeg[m].isNaN or tw.phaseDeg[m].isNaN):
          let d = degToRad(tg.phaseDeg[m] - tw.phaseDeg[m])
          sx += cos(d)
          sy += sin(d)
          inc n
      if n > 0:
        let d = abs(radToDeg(arctan2(sy, sx)))
        maxPhase = if maxPhase.isNaN: d else: max(maxPhase, d)
    if rangeDb > 3 or maxPhase > 10:
      result.judgeWarning = "the recorded GF does not match M and B with the typed masses " &
        "(level ratio varies by " & number(rangeDb, 1) & " dB along the sweep, phase differs " &
        "by up to " & number(maxPhase, 0) & " degrees): check the masses, or judge GF from " &
        "M and B"
  # Phase to the reference
  var phase = AnalysisPlot(title: "Phase to the reference", xLabel: "Sweep time (ms)",
    xUnit: "ms", yLabel: "Phase (°)", yUnit: "°", xs: xs)
  for s in [vsGroundForce, vsWeightedSum, vsMass, vsBaseplate]:
    if s in u.signals: phase.curves.add phaseCurve($s, u.tracks[s].phaseDeg, p.phaseShow)
  if withRecorded:
    phase.curves.add phaseCurve(RecordedRef, results[1].tracks[vsGroundForce].phaseDeg,
      p.phaseShow)
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
  # the harmonics drawn: those asked for, of the tracked ones (a band tracks all 16)
  let tracked = trackedHarmonics(TrackParams(harmonics: clamp(p.harmonics, 2, 16),
    harmonicBandHz: band, harmonicBandAuto: band.isNaN))
  for k in 2 .. (if main in u.signals: min(t.amplitude.len, min(tracked,
      clamp(p.harmonics, 2, 16))) else: 0):
    var pct = newSeq[float64](xs.len)
    for m in 0 ..< xs.len:
      let a1 = t.amplitude[0][m]
      pct[m] = if a1 > 0: 100 * t.amplitude[k - 1][m] / a1 else: NaN
      if not pct[m].isNaN and (largest[m].isNaN or pct[m] > largest[m]): largest[m] = pct[m]
    dist.curves.add AnalysisCurve(name: $main & " H" & $k, ys: pct)
  # What is judged, drawn: the window means as steps, the limits as lines, and the phase
  # axis fitted to them (M and B may run off it: the legend says so)
  proc steps(name: string; values: seq[float64]): AnalysisCurve =
    result = AnalysisCurve(name: name, style: csLine)
    for i in 0 ..< min(stats.startMs.len, values.len):
      for x in [stats.startMs[i], stats.startMs[i] + stats.windowMs]:
        result.xs.add x
        result.ys.add values[i]
  let hundredRaw = if hundredFor > 0 and hundredFor < Inf: hundredFor
                   else: NaN
  let forcePlot = if judged == vsWeightedSum and main != vsWeightedSum: addr generated
                  else: addr force
  if stats.startMs.len > 0:
    if p.phaseShow == psAbsolute:
      phase.curves.add steps(RecordedMean & $judged, stats.meanAbsPhaseDeg)
    dist.curves.add steps(RecordedMean & $judged & " THD", stats.meanThdPct)
    if not hundredRaw.isNaN:
      forcePlot[].curves.add steps(RecordedMean & $judged & " force", stats.meanForce)
  let q = p.qc
  if q.peakPhaseDeg < Inf:
    phase.curves.add limitLine("peak phase limit " & plain(q.peakPhaseDeg) & "°", xs,
      q.peakPhaseDeg)
    if p.phaseShow == psSigned:
      phase.curves.add limitLine("peak phase limit -" & number(q.peakPhaseDeg) & "°", xs,
        -q.peakPhaseDeg)
  if q.avgPhaseDeg < Inf and p.phaseShow == psAbsolute:
    phase.curves.add limitLine("average phase limit " & plain(q.avgPhaseDeg) & "°", xs,
      q.avgPhaseDeg)
  if q.peakDistortionPct < Inf:
    dist.curves.add limitLine("peak distortion limit " & plain(q.peakDistortionPct) & " %", xs,
      q.peakDistortionPct)
  if q.avgDistortionPct < Inf:
    dist.curves.add limitLine("average distortion limit " & plain(q.avgDistortionPct) & " %",
      xs, q.avgDistortionPct)
  if not hundredRaw.isNaN:
    let target = if p.targetPct > 0: p.targetPct else: 100.0
    if q.avgForcePct < Inf:
      forcePlot[].curves.add limitLine("average force limit", xs,
        hundredRaw * target / 100 * q.avgForcePct / 100)
    if q.peakForcePct < Inf:
      forcePlot[].curves.add limitLine("peak force limit", xs, hundredRaw * q.peakForcePct / 100)
  block fitPhase:
    # the axis holds the judged signal and its limits, with a margin
    var top = 0.0
    for v in u.tracks[judged].phaseDeg:
      if not v.isNaN: top = max(top, abs(v))
    for l in [q.peakPhaseDeg, q.avgPhaseDeg]:
      if l < Inf: top = max(top, l)
    top = max(15.0, min(180.0, 1.3 * top))
    var off: seq[string] = @[]
    for s in [vsMass, vsBaseplate]:
      if s in u.signals:
        var m = 0.0
        for v in u.tracks[s].phaseDeg:
          if not v.isNaN: m = max(m, abs(v))
        if m > top: off.add $s
    if off.len > 0:
      phase.curves.add AnalysisCurve(name: off.join(", ") & " off scale",
        ys: newSeq[float64](0))
    if p.phaseShow == psAbsolute:
      (phase.yLo, phase.yHi) = (-0.04 * top, top) # a line at 0 is clear of the border
    else: (phase.yLo, phase.yHi) = (-top, top)
  # Limits: drawn, and the points past them marked
  if p.limitsOn:
    let l = p.limits
    if l.phaseDeg < Inf:
      phase.curves.add limitLine("limit" & (if p.phaseShow == psSigned: " ±" else: " ") &
        number(l.phaseDeg) & "°", xs, l.phaseDeg)
      if p.phaseShow == psSigned:
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
      if ph.anyOf: phase.curves.add past($s, xs,
        shownPhase(u.tracks[s].phaseDeg, p.phaseShow).ys, ph)
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
      number(m.maxThdPct), forceCell(m.meanForce), forceCell(m.minForce),
      forceCell(m.maxPeak)]
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
      forceCell(m.meanForce), forceCell(m.minForce), forceCell(m.maxPeak)]
    if p.limitsOn: row.add "not judged"
    var at1 = result.table.len
    for i in 1 ..< result.table.len:
      if result.table[i][0] == $vsReference: at1 = i + 1
    result.table.insert(row, at1)
    result.forceUnits.insert(forceUnit(results[1].units[vsGroundForce]), at1 - 1)
  let usedHz = u.tracks[main].bandHz
  let chord = largestChordHz(u.reference)
  result.band = BandReport(hz: usedHz, suggestedHz: topFrequencyHz(u.reference),
      chordHz: chord,
    typed: not topHz.isNaN, exact: topHz.isNaN and not exactTopHz.isNaN)
  if not usedHz.isNaN and not chord.isNaN and chord > 0:
    # the chord is a lower bound of the top, short of it by the sweep's rate over its end
    # (a down sweep's start) taper and half the chord's length: below it by more than 0.5 % is wrong, above it by
    # more than that slack (with 25 % over and 1 % of the chord) is
    let e0 = u.reference.extent
    let hz = u.tracks[vsReference].referenceHz
    var first, last = -1
    for m in 1 ..< xs.len:
      if not hz[m].isNaN and not hz[m - 1].isNaN:
        if first < 0: first = m
        last = m
    # the top is where the frequency is highest: the end of an up sweep, the start of a down
    # sweep (the rate and the taper are those of that side)
    var rate = 0.0
    var taperS = 0.0
    if first > 0:
      let atStart = hz[first - 1] > hz[last]
      let m = if atStart: first else: last
      rate = abs(hz[m] - hz[m - 1]) / ((xs[m] - xs[m - 1]) / 1000)
      if atStart:
        if not (e0.startMs.isNaN or e0.flatStartMs.isNaN):
          taperS = max(0.0, e0.flatStartMs - e0.startMs) / 1000
      elif not (e0.endMs.isNaN or e0.flatEndMs.isNaN):
        taperS = max(0.0, e0.endMs - e0.flatEndMs) / 1000
    let slack = rate * (taperS + 0.125) * 1.25 + 0.01 * chord
    if usedHz < chord * 0.995 or usedHz > chord + slack:
      result.band.warning = "top frequency " & number(usedHz, 1) & " Hz does not fit the " &
        "largest frequency measured in the flat part of the reference (" &
        number(chord, 1) & " Hz, the top lies " & (if usedHz < chord: "not below" else:
        "within " & number(slack, 1) & " Hz above") & " it): check it"
  # the tapers, dimmed on the plots that run along the sweep
  if not (span.a.isNaN or span.b.isNaN):
    for plot in result.plots.mitems:
      if plot.xs.len > 0:
        if plot.xs[0] < span.a: plot.dimmed.add plot.xs[0] .. span.a
        if plot.xs[^1] > span.b: plot.dimmed.add span.b .. plot.xs[^1]
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
  words.add "; phase plot: " & PhaseShowWords[p.phaseShow] & "; the table's phases are " &
    "sizes (|phase|)"
  words.add "; values as recorded; distortion is the in-band one, as a vibrator controller " &
    "reports it: the harmonics (to the 16th) whose frequency stays within the top frequency " &
    (if usedHz.isNaN: "(none set: every harmonic to the " & $clamp(p.harmonics,
        2, 16) &
       "th counts)" else: number(usedHz, 1) & " Hz (" & (
           if not topHz.isNaN: "typed"
      elif not exactTopHz.isNaN: "the generated sweep's end frequency"
      else: "estimated from the reference's frequency track") & ")") &
    ", never one above 80 % of Nyquist"
  if vsWeightedSum in u.signals:
    words.add "; GF (M, B) is uncalibrated without accelerometer sensitivities: in " &
      weightedUnit(u.units[vsWeightedSum]) & ", on an axis of its own"
    if p.limitsOn and main != vsWeightedSum:
      words.add " (the force limits are in " & forceUnit(u.units[main]) &
        " and are not applied to it)"
  let e = u.reference.extent
  words.add "; judged from " & number(span.a, 0) & " to " & number(span.b, 0) &
      " ms (" &
    (if judging.skipStartMs.isNaN and judging.skipEndMs.isNaN: "the sweep less its tapers"
      else: "the sweep less " & (if judging.skipStartMs.isNaN: "its start taper"
        else: number(max(0.0, judging.skipStartMs), 0) & " ms at its start") &
            " and " &
        (if judging.skipEndMs.isNaN: "its end taper"
        else: number(max(0.0, judging.skipEndMs), 0) & " ms at its end")) &
    (if not cutMs.isNaN: "; judged to the trace's end" else: "") & ")"
  words.add "; verdict: windows of " & number(p.qcWindowMs, 0) & " ms from the sweep's start"
  if u.tracks[vsReference].fundamentalCut:
    words.add "; the fundamental is measured only below 80 % of Nyquist (to " &
      number(u.tracks[vsReference].lastFundamentalMs, 0) & " ms of the reference)"
  for s in said: words.add "; " & s
  result.note = words
  # a trace that cannot be matched to the whole of the reference: shorter than it, or its
  # signal stopped early (the force's fundamental, measured by the tracker, ends at about
  # the time shown, the reference's sweep at `extent.endMs`)
  let traceRow = if main == vsGroundForce: at[vsGroundForce] else: at[vsMass]
  if traceRow in 0 ..< rows.len:
    let traceMs = float64(rows[traceRow].len) * dtMs
    result.warning = shortWords("trace", traceMs, float64(rows[at[
        vsReference]].len) * dtMs)
    # where the reference's own fundamental is last measured, not the sweep's end: above 80 %
    # of Nyquist (2 and 4 ms sampling) the fundamental is not measured, and that is no
    # signal ending
    let refEnd = if u.tracks[vsReference].fundamentalCut and
                   not u.tracks[vsReference].lastFundamentalMs.isNaN:
                   u.tracks[vsReference].lastFundamentalMs
                 else: e.endMs
    let early = endWords("", lastLoudMs(u.tracks[main].amplitude[0], xs),
        refEnd, traceMs)
    if early.len > 0:
      result.warning.add (if result.warning.len > 0: "\n" else: "") & early
