## Two traces compared for QC. Each slot holds its own copy of one trace
## (file name, trace number, header identity, sample interval, start time
## and time window). It is replaced only on purpose: it does not follow the
## plot, a selection, a file change or a file close.
##
## The numbers are processSEG's: a spectrum and its phase
## (`amplitudeInto`), decibels (`toDbInto`), a correlation coefficient
## (`crossCorrelateInto`), a sample shift (`timeShift`), a polarity flip
## (`reversePolarity`), an RMS (`traceStats`) and a scale (`scale`). The
## phase picture is the one the FFT window already draws (`phasepicture`).
## Nothing here resamples. A shift is a whole number of samples, either
## sign: the samples move, the gap is zeros, and what moves off the end is
## left out. A typed time snaps to the nearest sample. A difference and a
## correlation need both traces on one sample grid; otherwise they are left
## out and the reason is said in plain words. Windowing is by sample index.

import std/[math, strutils]
import processSEG/core/[basic, timeshift, workspace]
import processSEG/fft/spectrum
import processSEG/gain/stats
import processSEG/vibroseis/[crosscorrelate, sweeptrack]
import matchpeak, phasepicture

export phasepicture, matchpeak.Match

type
  CompareWhich* = enum
    ## Which slot a command names.
    cwA = "A"
    cwB = "B"
    cwBoth = "both"

  CompareSlot* = object
    ## One trace, copied. `trace` is from 1, as the plot names it.
    filled*: bool
    waiting*: bool
    problem*: string
    path*: string       ## the file that fed it; "" for a reference
    fileName*: string
    trace*: int
    recordText*: string
    channelText*: string
    stationText*: string
    dtMs*: float64
    t0Ms*: float64      ## time of `samples[0]`, in ms
    fromMs*: float64    ## the copied window, in ms
    toMs*: float64
    samples*: seq[float32]
    reversed*: bool     ## polarity reversed, as the plot shows the trace
    filtered*: bool     ## the trace's own filter was applied
    filterWords*: string
    shiftWords*: string ## its time shift, in words; "" for none
    gen*: uint64        ## the fill this slot is waiting for, or the one it holds

  CompareOptions* = object
    ## What the window draws, and how B is aligned. Each alignment is off
    ## until asked. `fromMs` and `toMs` NaN: the span of both traces.
    difference*: bool
    shiftPeak*: bool ## shift B by the correlation peak
    shiftMs*: float64 = NaN ## a typed shift, ms; NaN: not typed
    matchRms*: bool
    flip*: bool
    fromMs*: float64 = NaN
    toMs*: float64 = NaN
    phasePicture*: PhasePicture = ppUnwrapped

  CompareTable* = object
    ## The correlation's peak, the shift it sits at, and the polarity.
    available*: bool
    whyNot*: string
    peak*: float64 = NaN ## the correlation's largest magnitude (`shiftMs` is where)
    shiftMs*: float64 = NaN
    polarity*: string
    match*: Match
      ## the correlation envelope's peak, shift and rotation, as the Cross-correlation
      ## window finds them (`matchpeak`)
    matchWords*: string
      ## the same in the same words: "best match 1.00 at +4.0 ms (B lags A by 4.0 ms; rotated 90°)"

  CompareSeries* = object
    ## One curve: a value per x (NaN where it has none).
    xs*: seq[float64]
    ys*: seq[float64]

  ComparePicture* = object
    ## What the window draws, arranged from the two slots. Times in ms,
    ## spectra in dB (0 dB at amplitude 1), phase in degrees, correlation
    ## as a coefficient.
    signalA*, signalB*, difference*: CompareSeries
    specA*, specB*: CompareSeries
    phase*: CompareSeries
    phaseSigned*: seq[float64]
    correlation*: CompareSeries
    table*: CompareTable
    sameGrid*: bool
    refusal*: string ## why the difference and the correlation are not shown
    alignNote*: string ## named on B's chip when an alignment is on
    appliedShiftMs*: float64 = NaN
    delayMs*: float64 = NaN
    phasePicture*: PhasePicture
    usedFromMs*: float64 = NaN ## the common window the curves were cut to
    usedToMs*: float64 = NaN
    note*: string

  CompareNews* = object
    ## What a compare job posts: the samples it copied, or why it could not.
    gen*: uint64
    samples*: seq[float32]
    dtMs*: float64
    t0Ms*: float64
    fromMs*, toMs*: float64
    channelText*: string
    stationText*: string
    reversed*: bool
    filtered*: bool
    filterWords*: string
    shiftWords*: string
    failure*: string

func secondsText*(ms: float64): string =
  ## `ms` as seconds, three decimals, for a chip.
  if ms.isNaN: return "?"
  var t = formatFloat(ms / 1000.0, ffDecimal, 3)
  if t == "-0.000": t = "0.000"
  t

func chipText*(slot: CompareSlot; which: CompareWhich; align = ""): string =
  ## "A: <file>, trace N, <from>-<to> s", and the alignment on B when it is on.
  if which == cwBoth: return ""
  let name = $which
  if slot.waiting: return name & ": reading..."
  if slot.problem.len > 0 and not slot.filled: return name & ": " & slot.problem
  if not slot.filled or slot.samples.len == 0:
    return name & ": empty"
  let file = if slot.fileName.len > 0: slot.fileName else: "unnamed"
  result = name & ": " & file & ", trace " & $slot.trace & ", " &
    secondsText(slot.fromMs) & "-" & secondsText(slot.toMs) & " s"
  if slot.reversed: result.add ", reversed"
  if slot.filtered: result.add ", own filter"
  if align.len > 0: result.add " (" & align & ")"

func appliedShiftMs*(ms, dtMs: float64): float64 =
  ## `ms` snapped to the nearest sample of `dtMs`. NaN when `ms` is: no
  ## typed shift. The box and the chip show this, not the number typed.
  if ms.isNaN: return NaN
  if not (dtMs > 0): return ms
  float64(wholeSamples(ms, dtMs)) * dtMs

func shiftBoxMs*(typed, applied, dtMs: float64): float64 =
  ## What the shift box shows. Nothing typed: 0. A typed time: the applied
  ## whole-sample time, once known, else `typed` snapped to `dtMs`.
  if typed.isNaN: return 0.0
  if not applied.isNaN: return applied
  appliedShiftMs(typed, dtMs)

func lowerNyquistHz(dtMs: float64): float64 =
  ## The Nyquist frequency of a trace sampled every `dtMs` ms.
  if dtMs > 0: 500.0 / dtMs else: 0.0

func gridsMatch(a, b: CompareSlot): bool =
  ## Whether the two copies sit on one sample grid: the same interval, and
  ## start times an integer number of samples apart. A fraction of a sample
  ## would need resampling, which this window does not do.
  if not (a.dtMs > 0 and b.dtMs > 0): return false
  if abs(a.dtMs - b.dtMs) > 1e-4 * max(a.dtMs, 1e-9): return false
  let steps = (a.t0Ms - b.t0Ms) / a.dtMs
  abs(steps - round(steps)) < 1e-3

func endsOf(s: CompareSlot): tuple[lo, hi: float64] =
  if s.samples.len == 0 or not (s.dtMs > 0): return (NaN, NaN)
  (s.t0Ms, s.t0Ms + float64(s.samples.len - 1) * s.dtMs)

func windowOf(a, b: CompareSlot; opt: CompareOptions): tuple[lo, hi: float64] =
  ## The common window: what was typed, else the span of both traces.
  let (a0, a1) = endsOf(a)
  let (b0, b1) = endsOf(b)
  var lo = opt.fromMs
  var hi = opt.toMs
  if lo.isNaN: lo = min(a0, b0)
  if hi.isNaN: hi = max(a1, b1)
  (lo, hi)

proc windowed(s: CompareSlot; lo, hi: float64): tuple[samples: seq[float32]; t0: float64] =
  ## The samples whose time falls in `lo` .. `hi`, and the time of the first.
  result.t0 = NaN
  if s.samples.len == 0 or not (s.dtMs > 0) or lo.isNaN or hi.isNaN or hi < lo:
    return
  let i0 = max(0, int(ceil((lo - s.t0Ms) / s.dtMs - 1e-6)))
  let i1 = min(s.samples.high, int(floor((hi - s.t0Ms) / s.dtMs + 1e-6)))
  if i0 > i1 or i0 >= s.samples.len: return
  result.samples = s.samples[i0 .. i1]
  result.t0 = s.t0Ms + float64(i0) * s.dtMs

proc paired(a, b: CompareSlot; lo, hi: float64): tuple[aa, bb: seq[float32];
    t0, dt: float64] =
  ## Both traces' samples on one grid inside the window. Empty when the
  ## grids do not coincide or the window holds none of both.
  result.t0 = NaN
  result.dt = NaN
  if not gridsMatch(a, b): return
  let dt = a.dtMs
  let i0 = max(0, int(ceil((lo - a.t0Ms) / dt - 1e-6)))
  let i1 = min(a.samples.high, int(floor((hi - a.t0Ms) / dt + 1e-6)))
  if i0 > i1: return
  var aa: seq[float32] = @[]
  var bb: seq[float32] = @[]
  var t0 = NaN
  for i in i0 .. i1:
    let t = a.t0Ms + float64(i) * dt
    let j = int(round((t - b.t0Ms) / dt))
    let onB = j >= 0 and j < b.samples.len and
      abs(b.t0Ms + float64(j) * dt - t) < 1e-3 * dt
    if onB:
      if aa.len == 0: t0 = t
      aa.add a.samples[i]
      bb.add b.samples[j]
    elif aa.len > 0:
      break
  if aa.len == 0: return
  result = (aa, bb, t0, dt)

proc timesOf(t0, dt: float64; n: int): seq[float64] =
  result = newSeq[float64](n)
  if not (dt > 0): return
  for i in 0 ..< n: result[i] = t0 + float64(i) * dt

proc asFloat(x: openArray[float32]): seq[float64] =
  result = newSeq[float64](x.len)
  for i, v in x: result[i] = float64(v)

proc seriesOf(xs: seq[float64]; ys: seq[float64]): CompareSeries =
  CompareSeries(xs: xs, ys: ys)

type
  OneSpectrum = object
    hz: seq[float64]
    amp: seq[float64]
    phase: seq[float64] ## degrees, wrapped
    db: seq[float64]

proc spectrumOf(x: openArray[float32]; dtMs: float64): OneSpectrum =
  ## Amplitude, phase and absolute dB of one window. Empty when it cannot
  ## be formed (said nowhere: the caller draws what it got).
  if x.len < 1 or not (dtMs > 0): return
  try:
    let plan = initSpectrumPlan(float32, dtMs, x.len)
    var ws = initWorkspace()
    ws.reserve(plan.workspaceSize)
    var amp = newSeq[float32](plan.bins)
    var phase = newSeq[float32](plan.bins)
    plan.amplitudeInto(x, amp, phase, ws)
    result.hz = newSeq[float64](plan.bins)
    result.amp = newSeq[float64](plan.bins)
    result.phase = newSeq[float64](plan.bins)
    for k in 0 ..< plan.bins:
      result.hz[k] = plan.binHz(k)
      result.amp[k] = float64(amp[k])
      result.phase[k] = float64(phase[k]) * 180.0 / PI
    result.db = newSeq[float64](plan.bins)
    toDbInto(result.amp, result.db, dbAbsolute, floorDb = -120.0)
  except ValueError:
    result = OneSpectrum()

proc cutNyquist(s: var OneSpectrum; hz: float64) =
  ## Drops bins above `hz` (the lower of the two Nyquist frequencies).
  if s.hz.len == 0 or not (hz > 0): return
  var n = 0
  while n < s.hz.len and s.hz[n] <= hz + 1e-6: inc n
  s.hz.setLen n
  s.amp.setLen n
  s.phase.setLen n
  s.db.setLen n

func nearestBin(hz: openArray[float64]; f: float64): int =
  ## The bin of `hz` nearest `f`; -1 when there is none.
  if hz.len == 0 or f.isNaN: return -1
  var lo = 0
  var hi = hz.high
  while lo < hi:
    let mid = (lo + hi) div 2
    if hz[mid] < f: lo = mid + 1 else: hi = mid
  result = lo
  if result > 0 and abs(hz[result - 1] - f) <= abs(hz[result] - f):
    dec result

proc peakAt(ys: openArray[float64]; xs: openArray[float64]): tuple[value, at: float64] =
  ## The finite sample of largest magnitude, and its x. NaN when there is none.
  result = (NaN, NaN)
  var best = -1.0
  for i, y in ys:
    if y.classify notin {fcNan, fcInf, fcNegInf} and abs(y) > best:
      best = abs(y)
      result = (y, if i < xs.len: xs[i] else: NaN)

proc correlate(a, b: openArray[float32]; dtMs: float64): tuple[xs, ys: seq[float64];
    match: Match; why: string] =
  ## The correlation coefficient of `b` against `a` (a copy of `a` delayed
  ## by τ peaks at +τ), over every lag, and its match (`matchOf`, with the rotation).
  ## `why` when it cannot be formed.
  result.match = matchOf([], [])
  if a.len < 2 or b.len < 2 or not (dtMs > 0):
    return (newSeq[float64](), newSeq[float64](), matchOf([], []),
      "fewer than two samples in the window")
  let n = min(a.len, b.len)
  let lag = float64(n - 1) * dtMs
  try:
    let cp = initCrossCorrelationPlan(float32, lag, dtMs, n)
    var ws = initWorkspace()
    ws.reserve(cp.workspaceSize)
    var lags, env = newSeq[float32](cp.lags)
    cp.crossCorrelateInto(b.toOpenArray(0, n - 1), a.toOpenArray(0, n - 1), lags, env, ws)
    result.xs = newSeq[float64](cp.lags)
    result.ys = newSeq[float64](cp.lags)
    var es = newSeq[float64](cp.lags)
    for i in 0 ..< cp.lags:
      result.xs[i] = cp.lagMs(i)
      result.ys[i] = float64(lags[i])
      es[i] = float64(env[i])
    result.match = matchOf(es, result.xs)
    if result.match.verdict == mvClear:
      result.match.rotationDeg = rotationOf(lags, dtMs, result.match.at, result.match.offset)
  except ValueError as e:
    result.why = e.msg

func directionWords(m: Match): string =
  ## Which way B is from A: "B lags A by 4.0 ms" (a copy of A delayed by τ peaks at +τ),
  ## "B leads A by", "B is in step with A".
  if m.inStep: "B is in step with A"
  else: "B " & (if m.shiftMs > 0: "lags" else: "leads") & " A by " & m.shiftSize

proc applyAlign(b: var seq[float32]; a: openArray[float32]; dtMs: float64;
    opt: CompareOptions; peakMs: float64): tuple[note: string; shiftMs: float64] =
  ## Flip, RMS match and shift, on `b` in place. A typed shift wins over the
  ## correlation peak. `shiftMs` is what was applied (NaN when none).
  result.shiftMs = NaN
  var parts: seq[string] = @[]
  if opt.flip and b.len > 0:
    reversePolarity(b)
    parts.add "polarity flipped"
  if opt.matchRms and b.len > 0 and a.len > 0:
    let ra = traceStats(a).rms
    let rb = traceStats(b).rms
    if ra.classify == fcNormal and rb.classify == fcNormal and rb > 0:
      scale(b, ra / rb)
      parts.add "amplitudes matched"
    else:
      parts.add "amplitudes not matched (no RMS)"
  let typed = not opt.shiftMs.isNaN
  let want = opt.shiftPeak or typed
  if want and b.len > 0 and dtMs > 0:
    var ms = NaN
    if typed: ms = opt.shiftMs
    elif not peakMs.isNaN: ms = peakMs
    if ms.isNaN:
      parts.add "not shifted (no clear match)"
    else:
      # A whole number of samples is a move: exact, no interpolation.
      let n = wholeSamples(ms, dtMs)
      timeShift(b, n)
      result.shiftMs = float64(n) * dtMs
      var text = formatFloat(result.shiftMs, ffDecimal, 1)
      if text == "-0.0": text = "0.0"
      # a positive shift moves B earlier (processSEG's `timeShift`), a negative one later
      let way = if text == "0.0": "" elif result.shiftMs > 0: " (earlier)" else: " (later)"
      parts.add "shifted " & text & " ms" & way
  result.note = parts.join(", ")

proc phaseDiff(a, b: OneSpectrum; picture: PhasePicture): tuple[hz, ys, signed: seq[float64];
    delayMs: float64] =
  ## Phase of B minus phase of A, on A's bins, up to the bins both still
  ## have. The picture and the amplitude floor are the FFT window's.
  result.delayMs = NaN
  if a.hz.len == 0 or b.hz.len == 0: return
  let showA = shownAbove(a.amp, PhaseFloorDb)
  let showB = shownAbove(b.amp, PhaseFloorDb)
  var df = 0.0
  if a.hz.len > 1: df = max(df, a.hz[1] - a.hz[0])
  if b.hz.len > 1: df = max(df, b.hz[1] - b.hz[0])
  let tol = if df > 0: df * 0.6 else: 0.0
  var wrapped = newSeq[float64](a.hz.len)
  var shown = newSeq[bool](a.hz.len)
  for k, f in a.hz:
    let kb = nearestBin(b.hz, f)
    let close = kb >= 0 and (tol == 0 or abs(b.hz[kb] - f) <= tol + 1e-6)
    let draw = close and k < showA.len and showA[k] and kb < showB.len and showB[kb] and
      not a.phase[k].isNaN and not b.phase[kb].isNaN
    if draw:
      shown[k] = true
      wrapped[k] = wrapDeg(b.phase[kb] - a.phase[k])
    else:
      wrapped[k] = NaN
  let drawn = drawnPhase(wrapped, shown, a.hz, picture)
  result = (a.hz, drawn.ys, drawn.signed, drawn.delayMs)

proc pictureOf*(a, b: CompareSlot; opt: CompareOptions): ComparePicture =
  ## The curves and the table of slots `a` and `b` under `opt`. Either slot
  ## empty: a note, and the one signal that is there. Different sample
  ## grids: signal, spectra and phase still, and a sentence for the
  ## difference and the correlation.
  result.phasePicture = opt.phasePicture
  if not a.filled and not b.filled:
    result.note = "Set a trace as A and one as B."
    return
  if not a.filled or a.samples.len == 0:
    result.note = "Set a trace as A."
  elif not b.filled or b.samples.len == 0:
    result.note = "Set a trace as B."
  let (lo, hi) = windowOf(a, b, opt)
  result.usedFromMs = lo
  result.usedToMs = hi
  let wa = windowed(a, lo, hi)
  let wb = windowed(b, lo, hi)
  if wa.samples.len > 0:
    result.signalA = seriesOf(timesOf(wa.t0, a.dtMs, wa.samples.len), asFloat(wa.samples))
  let pair = paired(a, b, lo, hi)
  result.sameGrid = pair.aa.len > 0
  var workA: seq[float32] = @[]
  var workB: seq[float32] = @[]
  var workT0 = NaN
  var workDt = NaN
  if pair.aa.len > 0:
    workA = pair.aa
    workB = pair.bb
    workT0 = pair.t0
    workDt = pair.dt
  else:
    workA = wa.samples
    workB = wb.samples
    workT0 = wb.t0
    workDt = b.dtMs
    if a.filled and b.filled and a.samples.len > 0 and b.samples.len > 0:
      if not gridsMatch(a, b):
        if abs(a.dtMs - b.dtMs) > 1e-4 * max(a.dtMs, 1e-9):
          result.refusal = "A is sampled every " & formatFloat(a.dtMs, ffDecimal, 3) &
            " ms and B every " & formatFloat(b.dtMs, ffDecimal, 3) &
            " ms. The difference and the cross-correlation need both on one sample grid, " &
            "and this window does not resample."
        else:
          result.refusal = "A and B do not share a sample grid: their start times differ by " &
            "a fraction of a sample. The difference and the cross-correlation would need " &
            "resampling, which this window does not do."
      else:
        result.refusal = "The window holds no sample of both traces, so the difference and " &
          "the cross-correlation are not shown."
  var peakMs = NaN
  if result.sameGrid:
    let corr = correlate(workA, workB, workDt)
    if corr.why.len > 0:
      result.table.whyNot = corr.why
      # The difference is a subtract and is still drawn. Do not say it is hidden.
      result.refusal = "The cross-correlation is not shown: " & corr.why & "."
    else:
      result.correlation = seriesOf(corr.xs, corr.ys)
      let peak = peakAt(corr.ys, corr.xs)
      if peak.value.isNaN:
        result.table.whyNot = "the correlation has no peak"
      else:
        result.table.available = true
        result.table.peak = peak.value
        result.table.shiftMs = peak.at
        result.table.polarity = if peak.value < 0: "reversed" else: "same"
        # B is shifted by where the envelope peaks (a quarter turn leaves the correlation
        # itself small there, and its largest magnitude elsewhere)
        peakMs = corr.match.shiftMs
        result.table.match = corr.match
        let shownMs = max(abs(corr.xs[0]), abs(corr.xs[^1]))
        result.table.matchWords = verdictWords(corr.match, shownMs,
          directionWords(corr.match))
  elif result.refusal.len > 0:
    result.table.whyNot = result.refusal
  let aligned = applyAlign(workB, workA, workDt, opt, if result.sameGrid: peakMs else: NaN)
  result.alignNote = aligned.note
  result.appliedShiftMs = aligned.shiftMs
  if workB.len > 0 and workDt > 0:
    result.signalB = seriesOf(timesOf(workT0, workDt, workB.len), asFloat(workB))
  if opt.difference and result.sameGrid and workA.len > 0 and workB.len == workA.len:
    var diff = newSeq[float64](workA.len)
    for i in 0 ..< workA.len:
      diff[i] = float64(workB[i]) - float64(workA[i])
    result.difference = seriesOf(timesOf(workT0, workDt, diff.len), diff)
  let ny = min(lowerNyquistHz(a.dtMs), lowerNyquistHz(b.dtMs))
  var specA = spectrumOf(if result.sameGrid: workA else: wa.samples,
    if result.sameGrid: workDt else: a.dtMs)
  var specB = spectrumOf(workB, workDt)
  if ny > 0:
    cutNyquist(specA, ny)
    cutNyquist(specB, ny)
  if specA.hz.len > 0:
    result.specA = seriesOf(specA.hz, specA.db)
  if specB.hz.len > 0:
    result.specB = seriesOf(specB.hz, specB.db)
  if specA.hz.len > 0 and specB.hz.len > 0:
    let ph = phaseDiff(specA, specB, opt.phasePicture)
    result.phase = seriesOf(ph.hz, ph.ys)
    result.phaseSigned = ph.signed
    result.delayMs = ph.delayMs
