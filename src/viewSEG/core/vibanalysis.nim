## The vibrator signature of New plot (wireline tests): a vibrator unit's
## reference (the pilot, Ref), ground force (GF), reaction-mass (M) and
## baseplate (B) accelerations, each a trace of the window as its roles
## (`VibRoles`) say, measured against the reference along the sweep by
## processSEG's `analyzeVibrators`, and drawn against sweep time:
##
## | Plot | Curves |
## |---|---|
## | Phase to the reference | the judged signal's phase (degrees) |
## | Force | the judged signal's fundamental amplitude and peak, in % of its 100 % force when that is given |
## | Frequency | the reference's and the judged signal's instantaneous frequency |
## | Distortion | THD of the judged signal |
##
## The windows past a peak limit of the verdict (the QC windows of the judged signal) are
## drawn in the error colour (`csFail`), no limit lines. With `AnalysisParams.details` the
## other ground force (its force on a plot and an axis of its own: another unit), M and B,
## the recorded pilot and the harmonics are drawn too, and the table says each signal's numbers.
##
## - **GF (M, B)** is the ground force generated from M and B, `Mr·a_M +
##   Mb·a_B`, once both masses are entered. Its unit is not the recorded
##   force's (kg × counts, uncalibrated without accelerometer sensitivities).
## - The values are as recorded (no calibration): the force in the
##   recorded units, or N from M and B in m/s² (they are not, unscaled).
##
## Pure: samples in, an `AnalysisResult` out; never raises.

import std/[algorithm, math, sequtils, strutils]
import parseSEG
import processSEG/core/[rows, types, units, workspace]
import processSEG/vibroseis/[sweeptrack, vibqc]
import analysis, signalend, sweepedge, vibjudge

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

func forceCell(x: float64): string =
  ## A force for the table: four significant digits whatever its size (a force in volts is
  ## 0.001 2, one in counts 13 202), scientific outside 0.001 to 10 million.
  forceNumber(x)

func addFailing(curves: var seq[AnalysisCurve]; c: AnalysisCurve) =
  ## `c`, the stretches past a limit, when there is any.
  for y in c.ys:
    if not y.isNaN:
      curves.add c
      return

func phaseCurve(name: string; deg: seq[float64]; mode: PhaseShow): AnalysisCurve =
  ## A phase to the reference as `mode` shows it (`phaseshow`); Absolute keeps the signed
  ## value for the readout's brackets.
  let shown = shownPhase(deg, mode)
  result = AnalysisCurve(name: name, ys: shown.ys)
  if mode == psAbsolute: result.brackets = shown.signed

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

func unusable(r: TopReading; chordHz, nyquistHz: float64): string =
  ## Why a reading is not made the band's edge ("" when it is): the median of the estimates that fit stands in.
  if r.hz >= nyquistHz: "it lies at or above half the sampling rate"
  elif not chordHz.isNaN and r.hz < 0.995 * chordHz:
    "it lies below the largest frequency the reference shows"
  elif r.uncertaintyHz > 0.05 * r.hz: "it is uncertain by more than 5 %"
  else: ""

func lineTopHz(track: SweepTrack; e: SweepExtent): float64 =
  ## The top frequency of the line through the reference's frequency track over the flat part
  ## (f or ln f against time, whichever fits better), taken to the sweep's measured end with a
  ## cosine-squared taper's share added (the estimate before `readTop`, unrounded). NaN without
  ## a sweep or enough points.
  result = NaN
  if e.startMs.isNaN or e.endMs.isNaN or e.flatStartMs.isNaN or e.flatEndMs.isNaN: return
  var ts, fs: seq[float64] = @[]
  for m in 0 ..< track.len:
    let (t, f) = (track.timeMs[m], track.referenceHz[m])
    if not f.isNaN and f > 0 and t >= e.flatStartMs and t <= e.flatEndMs:
      ts.add t / 1000
      fs.add f
  if ts.len < 20: return
  func line(xs, ys: seq[float64]): (float64, float64) =
    ## least squares: intercept and slope
    var (sx, sy, sxx, sxy) = (0.0, 0.0, 0.0, 0.0)
    for i in 0 ..< xs.len:
      sx += xs[i]
      sy += ys[i]
      sxx += xs[i] * xs[i]
      sxy += xs[i] * ys[i]
    let n = float64(xs.len)
    let d = n * sxx - sx * sx
    if d == 0: return (sy / n, 0.0)
    let b = (n * sxy - sx * sy) / d
    ((sy - b * sx) / n, b)
  let lf = fs.mapIt(ln(it))
  let (a1, b1) = line(ts, fs)
  let (a2, b2) = line(ts, lf)
  var (e1, e2) = (0.0, 0.0)
  for i in 0 ..< ts.len:
    e1 += (a1 + b1 * ts[i] - fs[i]) ^ 2
    e2 += (exp(a2 + b2 * ts[i]) - fs[i]) ^ 2
  let rising = fs[^1] > fs[0]
  # the sweep's envelope is measured down to `minReferenceDb` below its peak: a cos² taper
  # goes on a little past that point (this fraction of its length, of the rest of it)
  let share = 2 / PI * arcsin(sqrt(pow(10.0, -abs(TrackParams().minReferenceDb) / 20)))
  let more = share / (1 - share)
  func predict(t: float64): float64 =
    if e1 <= e2: a1 + b1 * t else: exp(a2 + b2 * t)
  # the sweep's end: the stretch of the track beyond the flat part that keeps to the line (a
  # window's frequency within 1 % of it), a window longer at most; noise or a transient after
  # the sweep (or before a sweep that falls) lies beyond it and stretches no taper
  let (p0, flatStart, flatEnd) = (TrackParams(), e.flatStartMs, e.flatEndMs)
  var edge = if rising: flatEnd else: flatStart
  var lost = false # the line is lost (not just the end of the measured points)
  for k in 0 ..< track.len:
    let m = if rising: k else: track.len - 1 - k
    let (t, f) = (track.timeMs[m], track.referenceHz[m])
    if not ((rising and t <= flatEnd) or (not rising and t >= flatStart)):
      if (rising and t > e.endMs) or (not rising and t < e.startMs): break
      if f.isNaN: break
      if abs(f - predict(t / 1000)) > 0.01 * f:
        lost = true
        break
      edge = t
  let endHz = max(1.0, if rising: fs[^1] else: fs[0])
  let slack = 500.0 * float64(windowPeriods(p0, endHz)) / endHz
  # the measured points end a half window short of the sweep's own end: the sweep's end is
  # then known (`endMs`); where they stop for another reason the sweep ends about there
  # (a half window on where the line was lost: its taper is down in the noise)
  let toEnd = abs((if rising: e.endMs - edge else: edge - e.startMs) - slack)
  let clean = toEnd <= 0.25 * slack
  let reach = if lost: slack else: 0.0
  let endMs = if clean: e.endMs else: min(e.endMs, edge + reach)
  let startMs = if clean: e.startMs else: max(e.startMs, edge - reach)
  let at = (if rising: endMs + more * max(0.0, endMs - flatEnd)
    else: startMs - more * max(0.0, flatStart - startMs)) / 1000
  let est = if e1 <= e2: a1 + b1 * at else: exp(a2 + b2 * at)
  if not (est > 0 and est < Inf): return
  result = est

func plausible*(hz, chordHz, nyquistHz: float64): bool =
  ## a top frequency below half the sampling rate and not below the largest one measured
  hz > 0 and hz < nyquistHz and (chordHz.isNaN or hz >= 0.995 * chordHz)

func markedTopHz*(readHz, lineHz, libraryHz, chordHz, nyquistHz: float64): float64 =
  ## The band's edge when the reading is marked: the median of those of the reading, the line's
  ## top (`lineTopHz`) and the library's estimate that are plausible (two: their mean); NaN when
  ## none is.
  var c: seq[float64] = @[]
  for v in [readHz, lineHz, libraryHz]:
    if plausible(v, chordHz, nyquistHz): c.add v
  c.sort()
  if c.len == 0: NaN elif c.len == 2: 0.5 * (c[0] + c[1]) else: c[c.len div 2]

func roundedTop*(est: float64): float64 =
  ## `est` rounded to a whole hertz when it lies within 0.5 % of one (a designed 6 to 220 Hz
  ## sweep reads 220, not 220.4), else to a tenth.
  let whole = round(est)
  if abs(est - whole) <= 0.005 * est: whole else: round(est * 10) / 10

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
  var fitted = NaN # the top frequency read from the reference's samples
  var reading = TopReading(hz: NaN) # ... and how far to trust it
  try:
    if pair and masses:
      unit.reactionMass = mass(p.reactionMassKg, muKilogram)
      unit.baseplateMass = mass(p.baseplateMassKg, muKilogram)
    let meta = initChunkMeta(rowsOf(keys, counts), dtMs)
    band = if topHz.isNaN: exactTopHz else: topHz
    func planFor(band: float64): SweepTrackPlan[float32] =
      initSweepTrackPlan(float32, TrackParams(harmonics: clamp(p.harmonics, 2, 16),
        thdHarmonics: thAllThatFit, harmonicBandHz: band, harmonicBandAuto: band.isNaN),
        dtMs, cols)
    var tp = planFor(band)
    var ws = initWorkspace()
    ws.reserve(vibratorWorkspace(tp))
    var units = @[unit]
    if withRecorded:
      units.add VibUnit(rows: [vsReference: at[vsReference], vsGroundForce: recorded,
        vsMass: -1, vsBaseplate: -1])
    var bandSet = not band.isNaN # typed, or a generated reference's own
    var cutLooked = false
    for pass in 0 .. 3:
      tp.analyzeVibrators(rowBlock(work, rows.len, cols), meta, units, limits,
          results, ws)
      if not bandSet:
        # no top frequency given: the reference's own, from its frequency track (the same
        # for every record), and the pass made again with it as the band's edge
        bandSet = true
        reading = readTop(rows[at[vsReference]], dtMs, results[0].tracks[vsReference],
          results[0].reference.extent)
        let (chord0, nyquist) = (largestChordHz(results[0].reference), 500.0 / dtMs)
        var edge = reading.hz
        let why = if reading.hz.isNaN: reading.why else: unusable(reading, chord0, nyquist)
        if why.len > 0 or reading.uncertaintyHz > 0.03 * reading.hz:
          # a reading uncertain by more than 3 %, or unusable: the median of the plausible estimates
          edge = markedTopHz(reading.hz, lineTopHz(results[0].tracks[vsReference],
            results[0].reference.extent), topFrequencyHz(results[0].reference), chord0, nyquist)
        if why.len > 0: reading = TopReading(hz: NaN, why: why)
        if not edge.isNaN:
          let est = roundedTop(edge)
          (band, fitted) = (est, est)
          tp = planFor(band)
          ws.reserve(vibratorWorkspace(tp))
          continue
      if cutLooked: break
      cutLooked = true
      # a trace shorter than the reference ends the judged part: its zero-padded rest is no
      # measurement (a point whose window reaches past its last sample stays out)
      let cut = shortEndMs(results[0].tracks[vsReference], tp.params, counts, at, dtMs, cols)
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
    (if both: (if judged == vsWeightedSum: "GF from M and B" else: "GF as recorded")
      else: ""))
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
  # What is judged, drawn: the judged signal alone (with Details: the other signals, M and B,
  # the recorded pilot and the harmonics too), the windows past a peak limit in the error colour
  let details = p.details
  func nameOf(s: VibSignal): string =
    ## A signal as the plots call it: the ground force judged is simply "GF" (the verdict says
    ## which); with Details, when the unit has both, they are told apart
    if s notin {vsGroundForce, vsWeightedSum}: $s
    elif details and both: (if s == vsGroundForce: "GF as recorded" else: "GF from M and B")
    else: "GF"
  let q = p.qc
  func overlay(name: string; ys: seq[float64]; values: seq[float64]; limit: float64;
      scale = 1.0): AnalysisCurve =
    ## `ys` where the window the point lies in has `values` (one per window) past `limit`.
    result = AnalysisCurve(name: name & " (past a limit)", style: csFail,
      ys: newSeq[float64](ys.len))
    for m in 0 ..< ys.len: result.ys[m] = NaN
    if limit.isNaN or limit == Inf: return
    for i in 0 ..< min(stats.startMs.len, values.len):
      if values[i] * scale > limit:
        for m in 0 ..< min(xs.len, ys.len):
          if xs[m] >= stats.startMs[i] and xs[m] < stats.startMs[i] + stats.windowMs and
              (span.a.isNaN or xs[m] >= span.a) and (span.b.isNaN or xs[m] <= span.b):
            result.ys[m] = ys[m]
  let hundredRaw = if hundredFor > 0 and hundredFor < Inf: hundredFor
                   else: NaN
  let percentScale = if hundredRaw.isNaN: 1.0 else: 100 / hundredRaw
  var others: seq[VibSignal] = @[] # the ground forces that are not judged
  for s in forces:
    if s in u.signals and s != judged: others.add s
  # Phase to the reference
  var phase = AnalysisPlot(title: "Phase to the reference", xLabel: "Sweep time (ms)",
    xUnit: "ms", yLabel: "Phase (°)", yUnit: "°", xs: xs)
  let judgedPhase = phaseCurve(nameOf(judged), u.tracks[judged].phaseDeg, p.phaseShow)
  phase.curves.add judgedPhase
  phase.curves.addFailing overlay(nameOf(judged), judgedPhase.ys, stats.meanAbsPhaseDeg,
    q.peakPhaseDeg)
  if details:
    for s in others & @[vsMass, vsBaseplate]:
      if s in u.signals: phase.curves.add phaseCurve(nameOf(s), u.tracks[s].phaseDeg, p.phaseShow)
    if withRecorded:
      phase.curves.add phaseCurve(RecordedRef, results[1].tracks[vsGroundForce].phaseDeg,
        p.phaseShow)
  block fitPhase:
    # the axis holds the judged curve as drawn, with a margin (signed, it runs up to a turn
    # either side of its centre); the others may run off it, and the legend says so
    var top = 0.0
    for v in judgedPhase.ys:
      if not v.isNaN: top = max(top, abs(v))
    top = max(15.0, min(if p.phaseShow == psSigned: 360.0 else: 180.0, 1.3 * top))
    var off: seq[string] = @[]
    if details:
      for s in [vsMass, vsBaseplate]:
        if s in u.signals and s != judged:
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
  # Force: the judged signal, in % of its 100 % force when that is given, else as recorded
  # (the recorded ground force and the one from M and B are in different units)
  func forcePlotOf(s: VibSignal; percent: bool): AnalysisPlot =
    let fromMasses = s == vsWeightedSum
    result = AnalysisPlot(xLabel: "Sweep time (ms)", xUnit: "ms", xs: xs,
      title: (if fromMasses: "Force from M and B" elif s == judged: "Force"
      else: "Force (GF as recorded)"),
      yLabel: (if percent: "Force (%)"
      elif fromMasses:
        (if details and both: "GF from M and B" else: "Force") & " (" &
          weightedUnit(u.units[vsWeightedSum]) & ")"
      else: "Force (" & forceUnit(u.units[s]) & ")"),
      yUnit: (if percent: "%" else: ""))
    let k = if percent: percentScale else: 1.0
    func scaled(v: seq[float64]): seq[float64] =
      result = newSeq[float64](v.len)
      for m in 0 ..< v.len: result[m] = v[m] * k
    let named = nameOf(s)
    let fundamental = AnalysisCurve(name: named & " fundamental",
      ys: scaled(u.tracks[s].amplitude[0]))
    let peak = AnalysisCurve(name: named & " peak", ys: scaled(u.tracks[s].peak))
    result.curves.add [fundamental, peak]
    if s == judged and not hundredRaw.isNaN:
      result.curves.addFailing overlay(named & " peak", peak.ys, stats.peak, q.peakForcePct,
        percentScale)
  var plots: seq[AnalysisPlot] = @[phase, forcePlotOf(judged, not hundredRaw.isNaN)]
  if details:
    for s in others: plots.add forcePlotOf(s, false)
  # Frequency
  var freq = AnalysisPlot(title: "Frequency", xLabel: "Sweep time (ms)", xUnit: "ms",
    yLabel: "Frequency (Hz)", yUnit: "Hz", xs: xs)
  freq.curves.add AnalysisCurve(name: "Ref", ys: u.tracks[vsReference].referenceHz)
  if details and withRecorded:
    freq.curves.add AnalysisCurve(name: RecordedRef,
      ys: results[1].tracks[vsGroundForce].frequencyHz)
  for s in @[judged] & others:
    if (s == judged or details) and s in u.signals:
      freq.curves.add AnalysisCurve(name: nameOf(s), ys: u.tracks[s].frequencyHz)
  # Distortion: the judged signal's THD; with Details the other's, and each harmonic
  var dist = AnalysisPlot(title: "Distortion", xLabel: "Sweep time (ms)", xUnit: "ms",
    yLabel: "Distortion (%)", yUnit: "%", xs: xs)
  let thd = AnalysisCurve(name: nameOf(judged) & " THD", ys: u.tracks[judged].thdPct)
  dist.curves.add thd
  dist.curves.addFailing overlay(nameOf(judged) & " THD", thd.ys, stats.meanThdPct,
    q.peakDistortionPct)
  if details:
    for s in others: dist.curves.add AnalysisCurve(name: nameOf(s) & " THD", ys: u.tracks[s].thdPct)
    let t = u.tracks[judged]
    # the harmonics drawn: those asked for, of the tracked ones (a band tracks all 16)
    let tracked = trackedHarmonics(TrackParams(harmonics: clamp(p.harmonics, 2, 16),
      harmonicBandHz: band, harmonicBandAuto: band.isNaN))
    for k in 2 .. min(t.amplitude.len, min(tracked, clamp(p.harmonics, 2, 16))):
      var pct = newSeq[float64](xs.len)
      for m in 0 ..< xs.len:
        let a1 = t.amplitude[0][m]
        pct[m] = if a1 > 0: 100 * t.amplitude[k - 1][m] / a1 else: NaN
      dist.curves.add AnalysisCurve(name: nameOf(judged) & " H" & $k, ys: pct)
  plots.add [freq, dist]
  result.plots = plots
  # The table: one row per signal
  var head = @["Signal", "Trace", "Polarity", "Mean |phase| (°)", "Max |phase| (°)",
    "Mean THD (%)", "Max THD (%)", "Mean force", "Min force", "Max peak"]
  result.table.add head
  for s in Shown:
    if s notin u.signals: continue
    let m = u.summaries[s]
    let trace = if s == vsWeightedSum: "M, B" else: names[at[VibRole(s)]]
    var row = @[$s, trace, (if s in u.reversed: "reversed" else: "as recorded"),
      number(m.meanAbsPhaseDeg), number(m.maxAbsPhaseDeg), number(m.meanThdPct),
      number(m.maxThdPct), forceCell(m.meanForce), forceCell(m.minForce),
      forceCell(m.maxPeak)]
    result.table.add row
    result.forceUnits.add(if s == vsWeightedSum: weightedUnit(u.units[s])
                           else: forceUnit(u.units[s]))
  if withRecorded:
    # the recorded pilot, measured against the reference: just after the Ref row
    let m = results[1].summaries[vsGroundForce]
    var row = @[RecordedRef, names[recorded], "as recorded", number(m.meanAbsPhaseDeg),
      number(m.maxAbsPhaseDeg), number(m.meanThdPct), number(m.maxThdPct),
      forceCell(m.meanForce), forceCell(m.minForce), forceCell(m.maxPeak)]
    var at1 = result.table.len
    for i in 1 ..< result.table.len:
      if result.table[i][0] == $vsReference: at1 = i + 1
    result.table.insert(row, at1)
    result.forceUnits.insert(forceUnit(results[1].units[vsGroundForce]), at1 - 1)
  let usedHz = u.tracks[main].bandHz
  let chord = largestChordHz(u.reference)
  result.band = BandReport(hz: usedHz, suggestedHz: (if fitted.isNaN: topFrequencyHz(
      u.reference) else: fitted), chordHz: chord,
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
      # the rate over the last ten points (one difference of two is the noise of a window)
      var o = if atStart: min(m + 10, last) else: max(m - 10, first - 1)
      if hz[o].isNaN: o = m - 1
      if o == m: o = m - 1
      rate = abs(hz[m] - hz[o]) / (abs(xs[m] - xs[o]) / 1000)
      if atStart:
        if not (e0.startMs.isNaN or e0.flatStartMs.isNaN):
          taperS = max(0.0, e0.flatStartMs - e0.startMs) / 1000
      elif not (e0.endMs.isNaN or e0.flatEndMs.isNaN):
        taperS = max(0.0, e0.endMs - e0.flatEndMs) / 1000
    if not reading.hz.isNaN and not e0.flatStartMs.isNaN:
      # read from the samples: the rate and the taper are those of the sweep itself, not of
      # a ring-down after it (whose frequency stands still and whose level stretches the extent)
      rate = reading.rateHzS
      taperS = max(0.0, (if first > 0 and hz[first - 1] > hz[last]: e0.flatStartMs - reading.endMs
        else: reading.endMs - e0.flatEndMs)) / 1000
    let slack = rate * (taperS + 0.125) * 1.25 + 0.01 * chord
    if usedHz < chord * 0.995 or usedHz > chord + slack:
      result.band.warning = "top frequency " & number(usedHz, 1) & " Hz does not fit the " &
        "largest frequency measured in the flat part of the reference (" &
        number(chord, 1) & " Hz, the top lies " & (if usedHz < chord: "not below" else:
        "within " & number(slack, 1) & " Hz above") & " it): check it"
  if topHz.isNaN and exactTopHz.isNaN:
    # the top frequency was read from the reference's samples: say when it is not sure
    var said = ""
    if reading.hz.isNaN:
      said = "the reference's top frequency could not be read reliably (" & reading.why &
        "): the band follows the median of the estimates that fit; type the top frequency to be " &
        "sure"
    elif reading.uncertain:
      result.band.uncertain = true
      result.band.uncertaintyHz = reading.uncertaintyHz
      said = "the top frequency " & number(usedHz, 1) & " Hz, read from the reference, is " &
        "uncertain (about " & number(reading.uncertaintyHz, 1) & " Hz either way; " &
        reading.why & "): check it, or type it"
    if said.len > 0:
      result.band.warning.add (if result.band.warning.len > 0: "; " else: "") & said
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
