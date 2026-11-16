## The f-k view of New plot: the amplitude spectrum of a box of traces ×
## time (the window's traces, between two times) against frequency and
## wavenumber, in dB from its largest value, as an image in a density
## colour map.
##
## processSEG has no 2-D f-k call: it is composed here of its real FFT
## (`FftPlan.forward`). Each trace's samples in the box, tapered (a cosine
## over the first and last 10 %), go through `forward` along time; then,
## for each frequency, the traces' complex values, tapered across the
## traces alike and zero-padded to twice their number, go across the
## traces: a complex transform made of two real ones, `F(a + ib) = F(a) +
## i·F(b)`, each real one's negative wavenumbers its positive ones'
## conjugates.
##
## - **Wavenumber.** From the trace spacing when it is regular (`spacingOf`:
##   the offsets, else the receivers' distances along the line) and the
##   file's distance unit: in cycles per km for metres, in cycles per kft
##   (1000 feet of the file's own foot, international or US survey) for
##   feet. Otherwise (irregular, an angular unit, a unit not given) in
##   cycles per trace, and the axis says so and why.
## - **Sign.** An event arriving later on the later traces (a positive dip)
##   is at a positive wavenumber.
## - **Apparent velocity** at a point: `f / k` (m/s for metres, ft/s for
##   feet, or traces/s per trace).
##
## Pure: samples in, an `AnalysisResult` out; never raises.

import std/math
import processSEG/fft/plan
import processSEG/core/workspace
import analysis, join

const
  FkTaper* = 0.1 ## the fraction of the box tapered at each end, on both axes

func regularSpacing*(positions: openArray[float64]): float64 =
  ## The step of `positions` when each one is within max(1 % of the step,
  ## one header unit) of its place on the even line from the first to the
  ## last, so whole numbers of a fractional step pass and a gap does not;
  ## NaN otherwise, for fewer than two, any NaN, or no step (0).
  if positions.len < 2: return NaN
  for p in positions:
    if p.isNaN: return NaN
  let step = (positions[^1] - positions[0]) / float64(positions.len - 1)
  if step == 0: return NaN
  let tolerance = max(0.01 * abs(step), 1.0)
  for i, p in positions:
    if abs(p - (positions[0] + float64(i) * step)) > tolerance: return NaN
  abs(step)

func spacingOf*(offsets: openArray[float64]; rcvX, rcvY: openArray[float64]):
    tuple[spacing: float64; source: string] =
  ## The trace spacing of traces with these keys: from their (signed)
  ## offsets when those are regular, else from their receivers' distances
  ## along the line (from the first) when those are; NaN and "" otherwise.
  let fromOffsets = regularSpacing(offsets)
  if not fromOffsets.isNaN: return (fromOffsets, "offsets")
  if rcvX.len == rcvY.len and rcvX.len >= 2:
    var along = newSeq[float64](rcvX.len)
    for i in 1 ..< rcvX.len:
      along[i] = along[i - 1] + hypot(rcvX[i] - rcvX[i - 1], rcvY[i] - rcvY[i - 1])
    let d = regularSpacing(along)
    if not d.isNaN: return (d, "receiver coordinates")
  (NaN, "")

func cosTaper(i, n: int; fraction: float64): float64 =
  ## A cosine taper's weight at `i` of `n`, over `fraction` of `n` at each end.
  let ramp = max(1, int(round(fraction * float64(n))))
  let d = min(i, n - 1 - i)
  if d >= ramp: 1.0 else: 0.5 - 0.5 * cos(PI * (float64(d) + 0.5) / float64(ramp))

func fkLengthOf*(unit: SurveyUnit): tuple[ok: bool; per, velocity: string] =
  ## How an f-k reads a file whose distances are in `unit`: whether its
  ## wavenumber can be per length at all, the unit it is per ("km", "kft"),
  ## and its velocity's ("m/s", "ft/s").
  case unit
  of suMetres: (true, "km", "m/s")
  of suFeet, suUsFeet: (true, "kft", "ft/s")
  else: (false, "", "")

proc fkOf*(rows: openArray[seq[float32]]; spacing: float64; spacingFrom: string;
    unit: SurveyUnit; dtMs, t0Ms: float64; p: AnalysisParams;
    stop: StopCheck = nil): AnalysisResult =
  ## The f-k amplitude of `rows` (traces at `dtMs`, the first sample at
  ## `t0Ms`, `spacing` apart, NaN: not regular) between `p.fkFromMs` and
  ## `p.fkToMs` (NaN: the ends), in dB from its largest, floored at
  ## `p.floorDb`. `unit` is the unit of the distances `spacing` is in
  ## (`fkLengthOf`).
  result = AnalysisResult(view: avFk, dtMs: dtMs, used: rows.len)
  if rows.len < MinFkTraces:
    result.problem = "an f-k needs " & $MinFkTraces & " traces at least, it has " & $rows.len
    return
  if not (dtMs > 0 and dtMs < Inf):
    result.problem = "the sample interval is not known"
    return
  var samples = 0
  for r in rows: samples = max(samples, r.len)
  let first = if p.fkFromMs.isNaN: 0 else: clamp(int(round((p.fkFromMs - t0Ms) / dtMs)), 0,
    samples)
  let last = if p.fkToMs.isNaN: samples - 1 else: clamp(int(round((p.fkToMs - t0Ms) / dtMs)),
    -1, samples - 1)
  let n = last - first + 1
  if n < 8:
    result.problem = "the box holds " & $max(n, 0) & " samples: too few (8 at least)"
    return
  let ntr = rows.len
  let nt = nextFastLen(n)
  let nk = nextFastLen(2 * ntr)
  var tp, kp: FftPlan[float64]
  try:
    tp = initFftPlan(float64, nt)
    kp = initFftPlan(float64, nk)
  except ValueError as e:
    result.problem = e.msg
    return
  var ws = initWorkspace()
  ws.reserve(tp.workspaceSize(batched = false))
  ws.reserve(kp.workspaceSize(batched = false))
  let nb = tp.bins
  # along time: each trace's spectrum, tapered across the traces too
  var re, im = newSeq[float64](ntr * nb) # [trace * nb + bin]
  var x = newSeq[float64](nt)
  var r1, i1 = newSeq[float64](nb)
  for t in 0 ..< ntr:
    if stop.stopped:
      result.cancelled = true
      return
    for j in 0 ..< nt: x[j] = 0
    let across = cosTaper(t, ntr, FkTaper)
    for j in 0 ..< n:
      let s = first + j
      let v = if s < rows[t].len: float64(rows[t][s]) else: 0.0
      x[j] = v * cosTaper(j, n, FkTaper) * across
    tp.forward(x, r1, i1, ws)
    for b in 0 ..< nb: (re[t * nb + b], im[t * nb + b]) = (r1[b], i1[b])
  # across the traces, per frequency: X = F(a) + i·F(b)
  let kb = kp.bins
  var a, b = newSeq[float64](nk)
  var ar, ai, br, bi = newSeq[float64](kb)
  var amp = newSeq[float64](nk * nb) # [col * nb + bin]
  var peak = 0.0
  for f in 0 ..< nb:
    if stop.stopped:
      result.cancelled = true
      return
    for t in 0 ..< nk:
      (a[t], b[t]) = if t < ntr: (re[t * nb + f], im[t * nb + f]) else: (0.0, 0.0)
    kp.forward(a, ar, ai, ws)
    kp.forward(b, br, bi, ws)
    for k in 0 ..< nk:
      # the full transforms of the real a and b: negative k the conjugates
      let (aR, aI, bR, bI) = if k < kb: (ar[k], ai[k], br[k], bi[k])
                             else: (ar[nk - k], -ai[nk - k], br[nk - k], -bi[nk - k])
      let xr = aR - bI
      let xi = aI + bR
      # k (cycles per trace, k/nk) as signed, then turned: later on later
      # traces is a positive wavenumber
      let signed = if k < nk div 2: k else: k - nk
      let col = (-signed + nk div 2 + nk) mod nk
      let v = hypot(xr, xi)
      amp[col * nb + f] = v
      peak = max(peak, v)
  let lengths = fkLengthOf(unit)
  let irregular = spacing.isNaN or spacing <= 0
  let perTrace = irregular or not lengths.ok
  let kScale = if perTrace: 1.0 else: 1000 / spacing # cycles per trace -> per km or kft
  let floor = min(p.floorDb, -1)
  var img = AnalysisImage(cols: nk, rows: nb,
    x0: -float64(nk div 2) / float64(nk) * kScale, dx: kScale / float64(nk),
    y0: 0, dy: 1000 / (float64(nt) * dtMs),
    xLabel: (if perTrace: "Wavenumber (cycles per trace)"
    else: "Wavenumber (cycles/" & lengths.per & ")"),
    xUnit: (if perTrace: "/trace" else: "/" & lengths.per), yLabel: "Frequency (Hz)", yUnit: "Hz",
    unit: "dB", lo: float32(floor), hi: 0,
    velocityUnit: (if perTrace: "traces/s" else: lengths.velocity),
    velocityScale: (if perTrace: 1.0 else: 1000.0))
  img.values = newSeq[float32](amp.len)
  for i in 0 ..< amp.len:
    img.values[i] = float32(if peak > 0 and amp[i] > 0: max(20 * log10(amp[i] / peak), floor)
                            else: floor)
  result.image = img
  let apart =
    if irregular: "the trace spacing is not regular: wavenumber per trace"
    elif perTrace:
      "the file's distance unit is " & (if unit == suNotGiven: "not given" else: "the " & $unit) &
        ", not a length: wavenumber per trace (the import's unit choice sets it)"
    else: "the traces " & $spacing & " " & $unit & " apart (from their " & spacingFrom & ")"
  result.note = $ntr & " traces × " & $n & " samples (" & $(float64(first) * dtMs + t0Ms) &
    " to " & $(float64(last) * dtMs + t0Ms) & " ms), tapered 10 % at each end both ways; " &
    apart & "; dB from the largest" &
      (if p.fkRaw: "; the plot's filters left out" else: "")
