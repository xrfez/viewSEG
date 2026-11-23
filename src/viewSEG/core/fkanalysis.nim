## The f-k view of New plot: the amplitude spectrum of a box of traces ×
## time (the window's traces, between two times) against frequency and
## wavenumber, in dB from its largest value, as an image in a density
## colour map.
##
## Each trace's samples in the box have their mean removed (`demean`), then
## processSEG's `fkAmplitudeInto` tapers both axes (a cosine over the first
## and last 10 %) and transforms. A trace with no sample in the box still
## takes a slot (one zero), so the taper and the wavenumber axis keep every
## trace. Asked to stop, the call gives up between traces and between
## frequencies (`Stopped`).
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
import parseSEG/model/[keytypes, tracerows]
import processSEG/core/[basic, rows, workspace]
import processSEG/core/types except StopCheck
import processSEG/fft/[fk, spectrum]
import analysis, join

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

func fkLengthOf*(unit: SurveyUnit): tuple[ok: bool; per, velocity: string] =
  ## How an f-k reads a file whose distances are in `unit`: whether its
  ## wavenumber can be per length at all, the unit it is per ("km", "kft"),
  ## and its velocity's ("m/s", "ft/s").
  case unit
  of suMetres: (true, "km", "m/s")
  of suFeet, suUsFeet: (true, "kft", "ft/s")
  else: (false, "", "")

var heldStop {.threadvar.}: StopCheck
var stopError {.threadvar.}: ref Exception

proc libraryStop(): bool {.gcsafe, raises: [].} =
  ## processSEG's stop check cannot be a closure and cannot raise, so it reads
  ## the one `fkOf` held and keeps any error to be raised again after the call.
  if heldStop.isNil: return false
  try:
    heldStop()
  except Exception as e:
    stopError = e
    true

proc fkStopped(plan: FkPlan[float64]; b: RowBlock[float64]; meta: ChunkMeta;
    amp: var openArray[float64]; ws: var Workspace; stop: StopCheck): int =
  ## `fkAmplitudeInto`, with `stop` asked the way the library asks its own.
  if stop.isNil:
    return plan.fkAmplitudeInto(b, meta, 0, amp, ws)
  let saved = heldStop
  let savedErr = stopError
  heldStop = stop
  stopError = nil
  defer:
    heldStop = saved
    stopError = savedErr
  result = plan.fkAmplitudeInto(b, meta, 0, amp, ws, stop = libraryStop)
  if not stopError.isNil:
    let e = stopError
    raise e

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
  var data = newSeq[float64](ntr * n)
  var counts = newSeq[int](ntr)
  var keys = newSeq[TraceKeys](ntr)
  for t in 0 ..< ntr:
    var count = 0
    let at = t * n
    for j in 0 ..< n:
      let s = first + j
      if s < rows[t].len:
        data[at + j] = float64(rows[t][s])
        inc count
    # no sample in the box still occupies a slot, or the taper and the
    # wavenumber axis would drop that trace
    counts[t] = if count == 0: 1 else: count
    keys[t] = initTraceKeys()
  let b = rowBlock(data, ntr, n)
  let meta = initChunkMeta(rowsOf(keys, counts), dtMs)
  var plan: FkPlan[float64]
  try:
    demean(b, meta)
    plan = initFkPlan(float64, dtMs, traces = ntr, samples = n, taperFraction = 0.1)
  except ValueError as e:
    result.problem = e.msg
    return
  var ws = initWorkspace()
  ws.reserve(plan)
  var amp = newSeq[float64](plan.nK * plan.nFreq)
  var used = 0
  try:
    used = fkStopped(plan, b, meta, amp, ws, stop)
  except ValueError as e:
    result.problem = e.msg
    return
  if used == Stopped:
    result.cancelled = true
    return
  if used != plan.traces:
    result.problem = "the f-k used " & $used & " traces, not " & $plan.traces
    return
  let nk = plan.nK
  let nb = plan.nFreq
  let lengths = fkLengthOf(unit)
  let irregular = spacing.isNaN or spacing <= 0
  let perTrace = irregular or not lengths.ok
  let kScale = if perTrace: 1.0 else: 1000 / spacing # cycles per trace -> per km or kft
  let floor = min(p.floorDb, -1)
  var img = AnalysisImage(cols: nk, rows: nb,
    x0: -float64(nk div 2) * plan.dkPerTrace * kScale, dx: kScale * plan.dkPerTrace,
    y0: 0, dy: plan.dfHz,
    xLabel: (if perTrace: "Wavenumber (cycles per trace)"
    else: "Wavenumber (cycles/" & lengths.per & ")"),
    xUnit: (if perTrace: "/trace" else: "/" & lengths.per), yLabel: "Frequency (Hz)", yUnit: "Hz",
    unit: "dB", lo: float32(floor), hi: 0,
    velocityUnit: (if perTrace: "traces/s" else: lengths.velocity),
    velocityScale: (if perTrace: 1.0 else: 1000.0))
  var db = newSeq[float64](amp.len)
  toDbInto(amp, db, dbPeak, floor)
  img.values = newSeq[float32](amp.len)
  for i in 0 ..< amp.len: img.values[i] = float32(db[i])
  result.image = img
  let apart =
    if irregular: "the trace spacing is not regular: wavenumber per trace"
    elif perTrace:
      "the file's distance unit is " & (if unit == suNotGiven: "not given" else: "the " & $unit) &
        ", not a length: wavenumber per trace (the import's unit choice sets it)"
    else: "the traces " & $spacing & " " & $unit & " apart (from their " & spacingFrom & ")"
  result.note = $ntr & " traces × " & $n & " samples (" & $(float64(first) * dtMs + t0Ms) &
    " to " & $(float64(last) * dtMs + t0Ms) & " ms), each trace's mean removed, tapered 10 % at " &
    "each end both ways; " &
    apart & "; dB from the largest" &
      (if p.fkRaw: "; the plot's filters left out" else: "")
