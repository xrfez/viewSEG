## Signal-analysis views of a plot's traces, opened from **New plot**: what
## each shows, its settings, and the numbers, worked out from the traces'
## samples (the analysis windows' reader, `core/analysisreader`, reads
## them; `AppState` keeps the windows).
##
## | View | What | From processSEG |
## |---|---|---|
## | Spectrogram | amplitude against time and frequency, in dB, an image | `spectrogramInto` |
## | Envelope | the trace, its envelope, its instantaneous phase and frequency | `hilbertInto` |
## | Phase spectrum | amplitude (dB) and phase against frequency | `amplitudeInto` |
## | Cross-correlation | each trace against a reference: against lag, and compared per frequency | `crossCorrelateInto`, `compareInto` |
##
## Every number here is processSEG's but for what it leaves to the caller:
## the envelope's instantaneous frequency (the analytic signal's phase step
## between samples, `instantaneousHz`), the phase unwrapped along frequency
## and shown only where the amplitude is within `phaseWithinDb` of its peak
## (`unwrapWhere`: elsewhere the phase is noise), and the spectrogram of
## several traces, their power average (as the spectrum windows average).
##
## The procs are pure: they take samples and give an `AnalysisResult`, and
## never raise (a problem is said in `problem`).

import std/math
import processSEG/fft/[hilbert, spectrogram, spectrum]
import processSEG/vibroseis/crosscorrelate
import processSEG/core/workspace
import colourmaps, panels, plotcursor, processing

export ColourMap, PlotCursor

type
  AnalysisView* = enum
    ## What an analysis window shows.
    avSpectrogram = "spectrogram"
    avEnvelope = "envelope"
    avPhase = "phase spectrum"
    avCorrelation = "cross-correlation"

  AnalysisParams* = object
    ## An analysis window's settings (each view uses its own).
    windowMs*: float64 = 128.0
      ## spectrogram: a frame's length (a Hann window): the time against
      ## frequency resolution (a frame of W ms resolves about 2/W kHz)
    overlap*: float64 = 75.0 ## spectrogram: how much a frame overlaps the next, %
    floorDb*: float64 = -60.0 ## spectrogram: the lowest dB drawn (the colour map's low end)
    colourMap*: ColourMap = cmViridis ## spectrogram's colours
    phaseWithinDb*: float64 = 20.0
      ## phase spectrum: the phase is shown where the amplitude is within
      ## this of the peak (elsewhere it is noise)
    unwrap*: bool = true ## phase spectrum: unwrapped along frequency (else -180 to 180)
    reference*: int = -1
      ## cross-correlation: the reference trace, survey-wide id; -1: none
      ## chosen (the first trace of the window then)
    maxLagMs*: float64 = 250.0 ## cross-correlation: the lags shown, either side of 0

  AnalysisCurve* = object
    ## A curve of a plot: a value per x (NaN where there is none).
    name*: string
    ys*: seq[float64]

  AnalysisPlot* = object
    ## Curves over one x axis.
    title*: string
    xLabel*, xUnit*: string
    yLabel*, yUnit*: string
    xs*: seq[float64]
    curves*: seq[AnalysisCurve]

  AnalysisImage* = object
    ## Values over a grid: column `i` at x `x0 + i·dx`, row `j` at y `y0 +
    ## j·dy`; `values[i·rows + j]`.
    cols*, rows*: int
    x0*, dx*, y0*, dy*: float64
    xLabel*, xUnit*, yLabel*, yUnit*, unit*: string
    values*: seq[float32]
    lo*, hi*: float32 ## the values the colour map's ends are drawn at

  AnalysisResult* = object
    ## An answer for an analysis window.
    gen*: uint64
    id*: int
    view*: AnalysisView
    plots*: seq[AnalysisPlot]
    image*: AnalysisImage ## a spectrogram's; empty otherwise
    used*: int            ## traces it is of
    leftOut*: int         ## of those asked about: killed, dead, not decoded
    dtMs*: float64
    note*: string         ## what the numbers are, in words (shown under the plot)
    problem*: string      ## why there is none; "" when there is one

const
  MaxAnalysisCurves* = 8 ## traces a curve view draws at most (the first ones)

func isEmpty*(img: AnalysisImage): bool {.inline.} = img.cols == 0 or img.rows == 0

func valueAt*(img: AnalysisImage; col, row: int): float32 {.inline.} =
  ## The value at column `col` and row `row`.
  img.values[col * img.rows + row]

func toDb(amp, peak: float64): float64 {.inline.} =
  if amp > 0 and peak > 0: 20 * log10(amp / peak) else: -Inf

# ------------------------------------------------------------ spectrogram --

proc spectrogramOf*(rows: openArray[seq[float32]]; dtMs, t0Ms: float64;
    p: AnalysisParams): AnalysisResult =
  ## The spectrogram of `rows` (traces at `dtMs`, the first sample at
  ## `t0Ms`): frames of `p.windowMs` overlapping by `p.overlap` %, in dB
  ## from the largest amplitude; of several traces, the power average.
  result = AnalysisResult(view: avSpectrogram, dtMs: dtMs, used: rows.len)
  var samples = 0
  for r in rows: samples = max(samples, r.len)
  if rows.len == 0 or samples < 2:
    result.problem = "no trace with samples"
    return
  if not (dtMs > 0 and dtMs < Inf):
    result.problem = "the sample interval is not known"
    return
  let windowLen = clamp(int(round(p.windowMs / dtMs)), 2, max(2, samples))
  let hop = max(1, int(round(float64(windowLen) * (1 - clamp(p.overlap, 0, 95) / 100))))
  var sg: SpectrogramPlan[float32]
  try:
    sg = initSpectrogramPlan(float32, windowLen, hop, dtMs, samples)
  except ValueError as e:
    result.problem = e.msg
    return
  var ws = initWorkspace()
  ws.reserve(sg.workspaceSize)
  var amp = newSeq[float64](sg.frames * sg.bins)
  var power = newSeq[float64](amp.len)
  for r in rows:
    sg.spectrogramInto(r, amp, ws)
    for k in 0 ..< amp.len: power[k] += amp[k] * amp[k]
  var peak = 0.0
  for k in 0 ..< power.len:
    power[k] = sqrt(power[k] / float64(rows.len))
    peak = max(peak, power[k])
  let floor = min(p.floorDb, -1)
  var img = AnalysisImage(cols: sg.frames, rows: sg.bins, x0: t0Ms, dx: float64(hop) * dtMs,
    y0: 0, dy: sg.binHz(1), xLabel: "Time (ms)", xUnit: "ms", yLabel: "Frequency (Hz)",
    yUnit: "Hz", unit: "dB", lo: float32(floor), hi: 0)
  img.values = newSeq[float32](power.len)
  for k in 0 ..< power.len: img.values[k] = float32(max(toDb(power[k], peak), floor))
  result.image = img
  result.note = $windowLen & "-sample frames (" & $(float64(windowLen) * dtMs) &
      " ms, Hann) every " &
    $hop & " samples; dB from the largest amplitude" &
    (if rows.len > 1: "; the power average of " & $rows.len & " traces" else: "")

# --------------------------------------------------------------- envelope --

func instantaneousHz*(x, h: openArray[float32]; dtMs: float64): seq[float64] =
  ## The instantaneous frequency of the analytic signal `x + i·h`, per
  ## sample: the step of its phase between the samples either side
  ## (wrapped to one turn), in Hz; NaN where the signal has no amplitude.
  result = newSeq[float64](x.len)
  let n = x.len
  for i in 0 ..< n:
    let a = max(i - 1, 0)
    let b = min(i + 1, n - 1)
    if b == a or (float64(x[a]) == 0 and float64(h[a]) == 0) or
        (float64(x[b]) == 0 and float64(h[b]) == 0):
      result[i] = NaN
    else:
      var d = arctan2(float64(h[b]), float64(x[b])) - arctan2(float64(h[a]), float64(x[a]))
      while d > PI: d -= 2 * PI
      while d <= -PI: d += 2 * PI
      result[i] = d / (2 * PI * float64(b - a) * dtMs / 1000)

proc envelopeOf*(x: openArray[float32]; name: string; dtMs, t0Ms: float64): AnalysisResult =
  ## The trace `x`, its envelope, its instantaneous phase (degrees) and its
  ## instantaneous frequency (Hz), against time: three plots.
  result = AnalysisResult(view: avEnvelope, dtMs: dtMs, used: 1)
  if x.len < 2:
    result.problem = "the trace has no samples"
    return
  var hp: HilbertPlan[float32]
  try:
    hp = initHilbertPlan(float32, x.len)
  except ValueError as e:
    result.problem = e.msg
    return
  var ws = initWorkspace()
  ws.reserve(hp.workspaceSize)
  var h = newSeq[float32](x.len)
  hp.hilbertInto(x, h, ws)
  var times = newSeq[float64](x.len)
  var signal, env, phase = newSeq[float64](x.len)
  for i in 0 ..< x.len:
    times[i] = t0Ms + float64(i) * dtMs
    signal[i] = float64(x[i])
    env[i] = hypot(float64(x[i]), float64(h[i]))
    phase[i] = if env[i] > 0: radToDeg(arctan2(float64(h[i]), float64(x[i]))) else: NaN
  let freq = instantaneousHz(x, h, dtMs)
  result.plots = @[
    AnalysisPlot(title: "Amplitude", xLabel: "Time (ms)", xUnit: "ms", yLabel: "Amplitude",
      xs: times, curves: @[AnalysisCurve(name: name, ys: signal),
      AnalysisCurve(name: "envelope", ys: env)]),
    AnalysisPlot(title: "Instantaneous phase", xLabel: "Time (ms)", xUnit: "ms",
      yLabel: "Phase (°)", yUnit: "°", xs: times,
      curves: @[AnalysisCurve(name: "phase", ys: phase)]),
    AnalysisPlot(title: "Instantaneous frequency", xLabel: "Time (ms)", xUnit: "ms",
      yLabel: "Frequency (Hz)", yUnit: "Hz", xs: times,
      curves: @[AnalysisCurve(name: "frequency", ys: freq)])]
  result.note = "The analytic signal's modulus (envelope) and argument (phase), the " &
    "phase's step per sample (frequency)"

# ---------------------------------------------------------- phase spectrum --

func unwrapWhere*(phaseDeg: openArray[float64]; shown: openArray[bool]): seq[float64] =
  ## `phaseDeg` (per bin, -180 to 180) unwrapped along the bins that are
  ## `shown` (a jump of more than half a turn between one shown bin and
  ## the next is taken as a whole turn the other way); NaN at the others.
  result = newSeq[float64](phaseDeg.len)
  var last = NaN
  var offset = 0.0
  for k in 0 ..< phaseDeg.len:
    if not shown[k] or phaseDeg[k].isNaN:
      result[k] = NaN
    else:
      if not last.isNaN:
        var v = phaseDeg[k] + offset
        while v - last > 180:
          offset -= 360
          v -= 360
        while v - last < -180:
          offset += 360
          v += 360
      result[k] = phaseDeg[k] + offset
      last = result[k]

proc phaseOf*(x: openArray[float32]; name: string; dtMs: float64;
    p: AnalysisParams): AnalysisResult =
  ## The amplitude (dB from its peak) and the phase (degrees, from the
  ## trace's first sample) of the whole trace against frequency; the phase
  ## where the amplitude is within `p.phaseWithinDb` of the peak only,
  ## unwrapped along frequency when `p.unwrap`.
  result = AnalysisResult(view: avPhase, dtMs: dtMs, used: 1)
  if x.len < 2:
    result.problem = "the trace has no samples"
    return
  var sp: SpectrumPlan[float32]
  try:
    sp = initSpectrumPlan(float32, dtMs, x.len, taperFraction = 0.0, demean = false)
  except ValueError as e:
    result.problem = e.msg
    return
  var ws = initWorkspace()
  ws.reserve(sp.workspaceSize)
  var amp, ph = newSeq[float32](sp.bins)
  sp.amplitudeInto(x, amp, ph, ws)
  var peak = 0.0
  for a in amp: peak = max(peak, float64(a))
  var hz, db, deg = newSeq[float64](sp.bins)
  var shown = newSeq[bool](sp.bins)
  let within = abs(p.phaseWithinDb)
  for k in 0 ..< sp.bins:
    hz[k] = sp.binHz(k)
    db[k] = toDb(float64(amp[k]), peak)
    shown[k] = db[k] >= -within
    deg[k] = radToDeg(float64(ph[k]))
  let phase = if p.unwrap: unwrapWhere(deg, shown)
              else:
                var w = newSeq[float64](deg.len)
                for k in 0 ..< deg.len: w[k] = if shown[k]: deg[k] else: NaN
                w
  result.plots = @[
    AnalysisPlot(title: "Amplitude", xLabel: "Frequency (Hz)", xUnit: "Hz",
      yLabel: "Amplitude (dB)", yUnit: "dB", xs: hz,
      curves: @[AnalysisCurve(name: name, ys: db)]),
    AnalysisPlot(title: "Phase", xLabel: "Frequency (Hz)", xUnit: "Hz",
      yLabel: "Phase (°)", yUnit: "°", xs: hz,
      curves: @[AnalysisCurve(name: name, ys: phase)])]
  result.note = "Phase from the trace's first sample, " &
    (if p.unwrap: "unwrapped along frequency, " else: "") &
    "where the amplitude is within " & $within & " dB of its peak"

# ------------------------------------------------------- cross-correlation --

proc correlationOf*(signals: openArray[(string, seq[float32])]; reference: seq[float32];
    referenceName: string; dtMs: float64; p: AnalysisParams): AnalysisResult =
  ## Each of `signals` against `reference`: the correlation coefficient and
  ## its envelope against lag (a signal that is the reference delayed by τ
  ## peaks at +τ), and per frequency the amplitude ratio (dB) and phase
  ## difference (degrees) of each signal to the reference, where the
  ## reference's amplitude is within `p.phaseWithinDb` of its peak.
  result = AnalysisResult(view: avCorrelation, dtMs: dtMs, used: signals.len)
  var samples = reference.len
  for (_, s) in signals: samples = max(samples, s.len)
  if signals.len == 0 or reference.len < 2 or samples < 2:
    result.problem = "no signal, or no reference with samples"
    return
  var cp: CrossCorrelationPlan[float32]
  try:
    let lag = clamp(p.maxLagMs, dtMs, float64(samples - 1) * dtMs)
    cp = initCrossCorrelationPlan(float32, lag, dtMs, samples)
  except ValueError as e:
    result.problem = e.msg
    return
  var ws = initWorkspace()
  ws.reserve(cp.workspaceSize)
  var lagsMs = newSeq[float64](cp.lags)
  for i in 0 ..< cp.lags: lagsMs[i] = cp.lagMs(i)
  var hz = newSeq[float64](cp.bins)
  for k in 0 ..< cp.bins: hz[k] = cp.binHz(k)
  var lagPlot = AnalysisPlot(title: "Correlation with " & referenceName, xLabel: "Lag (ms)",
    xUnit: "ms", yLabel: "Correlation coefficient", xs: lagsMs)
  var ratioPlot = AnalysisPlot(title: "Amplitude to the reference", xLabel: "Frequency (Hz)",
    xUnit: "Hz", yLabel: "Amplitude ratio (dB)", yUnit: "dB", xs: hz)
  var phasePlot = AnalysisPlot(title: "Phase to the reference", xLabel: "Frequency (Hz)",
    xUnit: "Hz", yLabel: "Phase difference (°)", yUnit: "°", xs: hz)
  var c, e = newSeq[float32](cp.lags)
  var ratio, phase = newSeq[float64](cp.bins)
  var peaks = ""
  # Where the reference has its energy: its own spectrum (of its
  # autocorrelation's lag window) within `phaseWithinDb` of its peak;
  # elsewhere the ratio and the phase are noise.
  var refAmp, refPhase = newSeq[float64](cp.bins)
  cp.crossCorrelateInto(reference, reference, c, ws)
  cp.lagSpectrumInto(c, refAmp, refPhase, ws)
  var refPeak = 0.0
  for a in refAmp:
    if not a.isNaN: refPeak = max(refPeak, a)
  var inBand = newSeq[bool](cp.bins)
  for k in 0 ..< cp.bins:
    inBand[k] = refPeak > 0 and toDb(refAmp[k], refPeak) >= -abs(p.phaseWithinDb)
  for (name, s) in signals:
    cp.crossCorrelateInto(s, reference, c, e, ws)
    var cs, es = newSeq[float64](cp.lags)
    var best = -1
    for i in 0 ..< cp.lags:
      (cs[i], es[i]) = (float64(c[i]), float64(e[i]))
      if not es[i].isNaN and (best < 0 or es[i] > es[best]): best = i
    lagPlot.curves.add AnalysisCurve(name: name, ys: cs)
    lagPlot.curves.add AnalysisCurve(name: name & " envelope", ys: es)
    cp.compareInto(s, reference, ratio, phase, ws)
    for k in 0 ..< cp.bins:
      if not inBand[k]: (ratio[k], phase[k]) = (NaN, NaN)
    ratioPlot.curves.add AnalysisCurve(name: name, ys: ratio)
    phasePlot.curves.add AnalysisCurve(name: name, ys: phase)
    if best >= 0:
      if peaks.len > 0: peaks.add "; "
      peaks.add name & " peaks at " & $lagsMs[best] & " ms"
  result.plots = @[lagPlot, ratioPlot, phasePlot]
  result.note = "Against " & referenceName & ": " & peaks

func peakLagMs*(r: AnalysisResult; curve = 0): float64 =
  ## A correlation's lag (ms) where curve `curve`'s envelope peaks; NaN for
  ## none.
  result = NaN
  if r.view == avCorrelation and r.plots.len > 0 and 2 * curve + 1 < r.plots[0].curves.len:
    let e = r.plots[0].curves[2 * curve + 1].ys
    var best = -1
    for i in 0 ..< e.len:
      if not e[i].isNaN and (best < 0 or e[i] > e[best]): best = i
    if best >= 0: result = r.plots[0].xs[best]

# ---------------------------------------------------------------- windows --

type
  AnalysisWindow* = object
    ## An analysis window (New plot): a view of traces of a plot's file,
    ## opened on the plot's selection or the trace under the pointer. Not
    ## frozen, it follows the plot it was opened from: its filters (and
    ## Aux toggle), and the kills of its traces.
    id*: int ## from 1, as `state`'s `plots` lists them
    view*: AnalysisView
    params*: AnalysisParams
    frozen*: bool ## keeps what it shows: follows nothing
    panel*: PanelId ## the plot it is of
    file*: string ## its file's name
    record*: string ## the record's FFID, or its place in the file
    traces*: seq[int] ## survey-wide ids, in the order drawn
    first*: int ## the first one's index in its file
    reference*: string ## a correlation's reference, in words
    processing*: Processing ## the plot's filters when it asked last
    filters*: string ## them in words; "" for none
    killed*: seq[int] ## its traces killed when it asked last (indices in the file)
    editsSeen*: int ## its file's edits' revision then
    result*: AnalysisResult ## the newest answer taken in
    asked*: uint64 ## the newest request's gen
    since*: uint64 ## answers to requests from before this are not its
    waiting*: bool ## an answer newer than `result` is on its way
    asks*: int ## requests made (for tests)
    cursor*: PlotCursor
      ## where the keys hold its cursor: an image's column and row, a curve
      ## plot's point and curve
    cursorOn*: int ## the plot it is held in (curve views: 0 the top one)
    front*: int ## bumped when it is to be brought forward
    revision*: int ## bumped on every change

const MaxAnalysisWindows* = 32 ## analysis windows open at once, at most

func viewName*(v: AnalysisView): string =
  ## A view's name as the menus say it: "Spectrogram".
  case v
  of avSpectrogram: "Spectrogram"
  of avEnvelope: "Envelope and instantaneous phase"
  of avPhase: "Phase spectrum"
  of avCorrelation: "Cross-correlation"

func label*(w: AnalysisWindow): string =
  ## What a window is of, in words: "trace 12 · FFID 151 · shot.sgd".
  if w.traces.len == 0: return "nothing"
  result = if w.traces.len == 1: "trace " & $(w.first + 1) else: $w.traces.len & " traces"
  if w.record.len > 0: result.add " · " & w.record
  if w.file.len > 0: result.add " · " & w.file

func title*(w: AnalysisWindow): string =
  ## A window's title: "Spectrogram 2: trace 12 · FFID 151 · shot.sgd".
  w.view.viewName & " " & $w.id & ": " & w.label

func freePlotId*(windows: openArray[AnalysisWindow]): int =
  ## The smallest id no window has, from 1.
  result = 1
  var taken = true
  while taken:
    taken = false
    for w in windows:
      if w.id == result:
        taken = true
        inc result
