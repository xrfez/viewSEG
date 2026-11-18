## Amplitude spectra of traces, for the FFT windows and the live spectrum
## panel: what a spectrum is of, how it is shown, the answer
## (`Spectrum`), and the sum it is made of (`SpectrumSum`).
##
## Every number comes from processSEG's `SpectrumPlan`
## (`processSEG/fft/spectrum`): a window of each trace is demeaned,
## Tukey-tapered (10 % at each end), zero-padded to the next power of two
## (more when the filters have a feature narrower than two bins:
## `spectrumNfft`) and transformed; the amplitudes are one-sided and
## corrected for the taper, so a sinusoid of amplitude A on a bin reads A.
## The filters' response comes with the answer, on a grid of its own
## (`responseGrid`: even steps, dense over each notch and ramp, so a
## notch's centre is never between two points): the gain they apply,
## measured by putting an impulse through them as the traces go
## (`appliedResponse`), so its stop band is what they really leave, not
## the design's zero. A spectrum of
## several traces is the power average (`averageAmplitudeInto`): the RMS
## amplitude over the traces, which the sum keeps across blocks of traces
## as Σ amplitude² · traces.
##
## **What counts.** The traces asked about, less those killed (the file's
## edits: they are left out of spectra as of the levels and the
## processing), those the file marks dead, those that cannot be decoded,
## hold a sample that is not a number in the window, or end before it, and
## those sampled at another interval than the first: the answer counts
## each. Auxiliary traces count as seismic ones do (a pilot's spectrum is
## what the vibrator analysis wants).
##
## **Raw and processed.** The raw curve is the trace as the plot shows it
## before the plot's filters: the file's samples with that trace's own
## filter, which is part of the trace and is never a curve the user can
## untick. The processed one is those samples through the plot's filters
## only (`core/processing`, made for the spectrum's own sample interval),
## run on whole traces before the window is cut, so the filters' edges
## never fall in it. A plot shown raw still gets the processed curve: the
## two compare. It is drawn only when the plot has a filter on. The
## processed curve is of the traces the plot's filters reach only: an
## auxiliary trace goes through them only when the Aux toggle says so
## (`Processing.aux`), so with it off the processed curve leaves an
## auxiliary trace out (`passedBy` counts it). A trace whose own filter
## runs instead of the plot's is left out of the plot's filters, so its
## processed curve equals its raw curve, and the words say so. With no
## trace reached there is none; nor is there when the filters cannot run
## at the traces' interval (`filterProblem`). The answer says which
## (`filtered`, `passedBy`, `filterNote`), so the words never claim a
## filter that was not applied. The response is the plot's filters'
## response, and only when the plot has a filter on. A trace's own filter
## is named apart (`ownNote`): "Trace 12: own filter, band-pass 10-60 Hz",
## or how many.
##
## The work runs on a thread of its own (`core/spectrumreader`); `AppState`
## keeps the windows (`SpectrumWindow`).

import std/[algorithm, math, sequtils]
import parseSEG
import processSEG/pipeline
import processSEG/fft/spectrum
import processSEG/filter/[design, edges]
import processSEG/core/[rows, types, workspace]
import panels, phasepicture, plotcursor, processing, viewport

export phasepicture

export plotcursor

export DbReference

type
  SpectrumTime* = enum
    ## The part of each trace a spectrum is of.
    stWhole = "whole trace"    ## every sample
    stVisible = "visible time" ## the time range the plot shows

  SpectrumScale* = enum
    ## How amplitudes are drawn.
    ssDb = "dB"         ## 20·log10 of the amplitude, 0 dB at the largest of the curves
    ssLinear = "linear" ## the amplitude itself, in the file's sample units

  SpectrumDisplay* = object
    ## How a spectrum window shows its spectrum, and over which time.
    scale*: SpectrumScale = ssDb
    logFrequency*: bool     ## the frequency axis is logarithmic
    time*: SpectrumTime = stWhole
    raw*: bool = true       ## the raw curve is drawn
    processed*: bool = true ## the curve through the filters is drawn
    response*: bool = true  ## the filters' own response is drawn (when there are some)
    phase*: bool            ## a one-trace spectrum's phase is drawn under its amplitude
    phasePicture*: PhasePicture = ppUnwrapped
      ## which picture of that phase is drawn (unwrapped by default)

  SpectrumCurve* = enum
    ## A curve of a spectrum window's plot, in the order drawn (`drawnCurves`).
    scResponse = "response"   ## the filters' response, under the data
    scRaw = "raw"             ## the samples as recorded
    scProcessed = "processed" ## through the plot's filters

  SpectrumOf* = enum
    ## What chose a spectrum's traces.
    soNothing = "nothing"
    soTrace = "trace"            ## the trace under the pointer
    soSelection = "selection"    ## the selected traces
    soVisible = "visible traces" ## the traces the plot shows

  FinePhase* = object
    ## The amplitude and the phase (degrees) of one trace on a finer grid than
    ## the spectrum's bins.
    amp*, phase*: seq[float64]

  Spectrum* = object
    ## An answer: the averaged amplitude spectra of the traces asked about.
    gen*: uint64            ## the request's
    id*: int                ## the window's
    binHz*: float64         ## the bins' spacing; bin k is at k·binHz, the last at Nyquist
    raw*: seq[float64]
      ## per bin, the RMS amplitude of the trace with its own filter, before
      ## the plot's filters
    processed*: seq[float64]
      ## per bin, of the traces through the filters (`filtered`); empty when
      ## there are none, they reach no trace, or they cannot run
    rawPhase*, processedPhase*: seq[float64]
      ## of a spectrum of one trace: per bin, its phase in degrees (-180 to
      ## 180, from the window's first sample); empty for several traces
    rawFine*, processedFine*: FinePhase
      ## the same on a grid `PhaseStep` times finer (the trace zero-padded), where
      ## the phase is unwrapped: between bins the phase of energy arriving after
      ## half the FFT's length steps more than half a turn, so on the bins alone
      ## the unwrap folds it the wrong way; every `PhaseStep`th point is a bin
    asked*: int ## traces asked about
    averaged*: int ## traces averaged
    killed*: int ## left out: killed
    dead*: int ## left out: marked dead in the file
    failed*: int ## left out: not decoded, a sample not a number, or none in the window
    atOtherInterval*: int ## left out: sampled at another interval
    dtMs*: float64 ## the sample interval
    fromMs*, toMs*: float64 ## the window's first and last sample's times
    windowLen*: int ## its samples
    nfft*: int ## the FFT's length
    read*: int ## traces read from the file for it (0: all at hand)
    filters*: string ## the plot's filters asked for, in words; "" for none
    ownNote*: string
      ## the own filters of the traces it is of: "Trace 12: own filter,
      ## band-pass 10-60 Hz", or "N traces have their own filter"; "" for none
    reverseNote*: string
      ## the reversed traces it is of: "Trace 12: reversed", or "N traces
      ## are reversed"; "All traces are reversed" when reverse-all is on and
      ## every trace it shows is; "" for none. A reversal is part of the
      ## trace, as an own filter is: no box turns it off
    insteadNote*: string
      ## "this trace uses its own filter instead of the plot's" when the
      ## plot's filters do not apply because the trace's own filter runs
      ## instead; "" otherwise
    filterAux*: bool ## the auxiliary traces were asked to go through them
    filtered*: int ## of `averaged`, the traces `processed` is of
    passedBy*: int
      ## of `averaged`, the auxiliary traces the filters passed by (the Aux
      ## toggle off): in `raw`, left out of `processed`
    filterNote*: string
      ## what the sample interval cut of the filters (`limitNote`); "" for nothing
    filterProblem*: string
      ## why the filters cannot run on these traces, a clause ("none of them
      ## is below Nyquist"); "" when they did or there are none
    responseHz*: seq[float64]
      ## the frequencies `response` is at, ascending, 0 to Nyquist
      ## (`responseGrid`): not the bins
    response*: seq[float64]
      ## at each of `responseHz`, the gain the filters apply (`appliedResponse`);
      ## empty when they have no pass band or notch, or did not run
    problem*: string ## why there is no spectrum; "" when there is one

  SpectrumWindow* = object
    ## A spectrum window: an FFT window opened from the plot's menu, or the
    ## live panel (`id` 0). Not frozen, it follows the Seismic plot it was
    ## opened from, as a New plot window does: the selection in the record
    ## on show, or the traces in view with none, and the record, the file
    ## and the filters. An FFT window opened on chosen traces keeps those
    ## until the plot changes (`heldOpen`). Frozen, it keeps the traces and
    ## the file it had.
    id*: int ## 0: the live panel; FFT windows from 1
    display*: SpectrumDisplay
    frozen*: bool ## keeps the traces and the file it had when frozen
    heldOpen*: bool
      ## an FFT window: still showing the traces it was opened on, until the
      ## plot changes or it is unfrozen
    shown*: bool ## the live panel: on screen (it works only then)
    front*: int ## bumped when it is to be brought forward (an agent showed it)
    chosen*: SpectrumOf
    file*: string ## the file's name; "" for none
    record*: string ## the record's FFID, or its place in the file
    traces*: seq[int] ## survey-wide ids of the traces it is of, ascending
    first*: int ## the first one's index in its file
    chosenCount*: int
      ## the traces chosen (selected, in view); `traces` spreads over them
      ## evenly when they are more than a spectrum takes (`spectrumTraces`)
    axisT0Ms*: float64 = NaN
      ## the time of sample 0 on that plot's time axis when `visibleMs` was taken; kept
      ## with it, so a window frozen on one file and asked again reads the same times
    visibleMs*: Span
      ## the plot's visible time when the window was opened (FFT), or now (live)
    panel*: PanelId ## the plot it is of (the live panel: the Seismic window)
    filters*: string ## the plot's filters, in words, when asked; "" for none
    processing*: Processing ## them, as asked last (shown raw or not, alike)
    cursor*: PlotCursor
      ## its cursor when held by the keys or an agent, as drawn: the bin
      ## along the frequency axis nearest `cursorHz` (among those the axis
      ## shows), and the place of `cursorCurve` among the curves drawn
      ## (`drawnCurves`; the top one while it is not drawn). Kept so by
      ## `followCursor` whenever the spectrum or the display changes
      ## (`core/plotcursor`)
    cursorHz*: float64 ## the frequency the cursor is held at
    cursorCurve*: SpectrumCurve ## and the curve it reads
    killed*: seq[int] ## its traces killed when it asked last (indices in the file)
    editsSeen*: int ## its file's edits' revision then
    ownKey*: string ## the own filters of its traces when it asked last
    spectrum*: Spectrum ## the newest answer taken in
    asked*: uint64 ## the newest request's gen; 0 for none
    since*: uint64
      ## answers to requests from before this gen are of something else (a
      ## closed window of the same number, what the live panel showed before)
    waiting*: bool ## an answer newer than `spectrum` is on its way
    asks*: int ## requests made (for tests: the work follows the view)
    revision*: int ## bumped on every change
    pickSession*: int = -1 ## the plot's file when the traces were last chosen
    pickGather*: int = -1 ## and the record
    pickSelected*: int = -1 ## the selection's revision then
    pickOrder*: uint64 ## the plot's sort generation then
    pickSource*: uint64 ## the record's generation then
    pickShown*: int = -1 ## how many traces the plot had laid out then

  SpectrumSum* = object
    ## The power average of many traces' spectra, block by block.
    sum: SpectrumAccumulator[float32] ## the power sum (processSEG's)
    plan: SpectrumPlan[float32]       ## for the phase of one window: `PhaseStep` times finer
    ws: Workspace

const
  PhaseStep* = 4
    ## the phase's grid is this many times finer than the bins (the trace
    ## zero-padded to `PhaseStep` times the FFT's length), as New plot's Phase
    ## spectrum pads, so the unwrap does not alias for an arrival at any time in
    ## the window
  LiveSpectrum* = 0 ## the live panel's id
  MaxSpectrumTraces* = 4096
    ## traces a spectrum averages at most: more chosen are taken evenly
  MaxSpectrumSamples* = 32 * 1024 * 1024
    ## decoded samples (128 MiB) a spectrum's traces hold at most, whole,
    ## and its reader keeps at hand: fewer traces of long records
  MaxSpectrumWindows* = 32 ## FFT windows open at once, at most
  MaxSpectrumPadding* = 8
    ## a spectrum's FFT is at most this many times the window's next power of two

func label*(w: SpectrumWindow): string =
  ## What a window shows, in words: "trace 12 · FFID 151 · shot.sgd",
  ## "24 traces · FFID 151 · shot.sgd"; "nothing" when it shows nothing.
  if w.traces.len == 0:
    if w.file.len > 0: return "nothing · " & w.file
    return "nothing"
  result = if w.chosen == soVisible: $w.traces.len & " visible traces"
           elif w.traces.len == 1: "trace " & $(w.first + 1)
           else: $w.traces.len & " traces"
  if w.record.len > 0: result.add " · " & w.record
  if w.file.len > 0: result.add " · " & w.file

func title*(w: SpectrumWindow): string =
  ## A window's title, named for what it shows: "FFT: trace 12 · ...",
  ## "FFT 2: ..." from the second FFT window on; the live panel is
  ## "Spectrum".
  let name = if w.frozen and w.id != LiveSpectrum: "Frozen · " & w.label else: w.label
  if w.id == LiveSpectrum: "Spectrum"
  elif w.id == 1: "FFT: " & name
  else: "FFT " & $w.id & ": " & name

func hasResponse*(sp: Spectrum): bool {.inline.} =
  ## Whether `sp` has a filter response to draw: the filters have a pass
  ## band or a notch and reached some of its traces (one they reached none
  ## of is not drawn: the spectrum would seem filtered).
  sp.response.len > 0 and sp.response.len == sp.responseHz.len and sp.filtered > 0

func drawnCurves*(w: SpectrumWindow): seq[SpectrumCurve] =
  ## The curves `w`'s plot draws, in the legend's order: the response first
  ## (shown, and there is one), so the data is drawn over it, then the raw
  ## curve and the processed one, each when shown and there.
  if w.display.response and w.spectrum.hasResponse: result.add scResponse
  if w.display.raw: result.add scRaw
  if w.display.processed and w.spectrum.processed.len > 0: result.add scProcessed

func shownBins*(w: SpectrumWindow): Slice[int] =
  ## The bins `w`'s frequency axis shows: every one, but 0 Hz on a
  ## logarithmic axis, so a cursor held is never where it is not drawn
  ## (`0 .. -1` for none).
  let n = w.spectrum.raw.len
  (if w.display.logFrequency and n > 1: 1 else: 0) .. n - 1

func cursorAt*(w: SpectrumWindow): PlotCursor =
  ## Where `w`'s held cursor is drawn: the bin nearest the frequency it is
  ## held at among those the axis shows, on its curve's place among those
  ## drawn (the top one while it is not drawn); `PlotCursor()` when not held.
  if not w.cursor.held: return PlotCursor()
  let bins = w.shownBins
  let curves = w.drawnCurves
  let y = curves.find(w.cursorCurve)
  PlotCursor(held: true, x: nearestSample(w.cursorHz, w.spectrum.binHz, bins.b + 1, bins.a),
    y: (if y >= 0: y else: max(curves.high, 0)))

func followCursor*(w: var SpectrumWindow): bool =
  ## After the spectrum or the display changed: `w`'s held cursor drawn at
  ## the frequency and on the curve it is held at (`cursorAt`); whether
  ## that moved it.
  let c = w.cursorAt
  result = c != w.cursor
  if result: w.cursor = c

func holdAt*(w: var SpectrumWindow; at: PlotCursor): seq[string] {.discardable.} =
  ## `w`'s cursor held at bin `at.x` (its frequency) and on the curve drawn
  ## `at.y` (0 the first in the legend), each within those the plot shows
  ## (`shownBins`, `drawnCurves`); let go when `at.held` is false. Returns
  ## what it moved to get within them, in words (none for nothing).
  if not at.held:
    w.cursor = PlotCursor()
    return
  let bins = w.shownBins
  let x = clamp(at.x, bins.a, max(bins.b, bins.a))
  if x != at.x:
    result.add "bin " & $at.x & " is not on its frequency axis (bins " & $bins.a & " to " &
      $bins.b & (if bins.a > 0: ": 0 Hz is off a logarithmic one" else: "") &
      "): held at bin " & $x
  let curves = w.drawnCurves
  if curves.len == 0:
    if at.y != 0: result.add "it draws no curve: curve " & $at.y & " is not there"
  else:
    let y = clamp(at.y, 0, curves.high)
    if y != at.y:
      result.add "curve " & $at.y & " is not drawn (curves 0 to " & $curves.high &
        "): held on curve " & $y & " (" & $curves[y] & ")"
    w.cursorCurve = curves[y]
  w.cursorHz = float64(x) * w.spectrum.binHz
  w.cursor.held = true
  discard w.followCursor()

func auxText(n: int): string =
  if n == 1: "the auxiliary trace is" else: "the " & $n & " auxiliary traces are"

const AuxOff* = "Filters > Filter the Aux traces too is off"
  ## where the plot's Aux toggle is, as the words name it

func filterText*(w: SpectrumWindow): string =
  ## What the processed curve went through, in words, as the answer says
  ## it (never the plot's filters of now): "processed: 4-8-60-80 Hz";
  ## "processed: 4-8-60-80 Hz, 23 of the 24 traces (the auxiliary trace is
  ## not filtered: Filters > Filter the Aux traces too is off)"; "not
  ## processed: the auxiliary trace is not filtered: ... (the plot's
  ## filters: notch 60 Hz)"; "no filters on the plot: the raw curve only";
  ## what Nyquist cut of them after it. A trace's own filter is named after
  ## that (`ownNote`), a reversal the same way (`reverseNote`), and, where
  ## the own filter runs instead of the plot's, that the plot's filters did
  ## not apply (`insteadNote`).
  template sp: untyped = w.spectrum
  if sp.raw.len == 0: return ""
  if sp.filters.len == 0: result = "no filters on the plot: the raw curve only"
  elif sp.filterProblem.len > 0:
    result = "not processed: the plot's filters (" & sp.filters & ") cannot run: " &
      sp.filterProblem
  elif sp.filtered == 0 and sp.passedBy > 0:
    result = "not processed: " & auxText(sp.passedBy) & " not filtered: " & AuxOff &
      " (the plot's filters: " & sp.filters & ")"
  elif sp.processed.len == 0:
    result = "not processed: no trace went through the plot's filters (" & sp.filters & ")"
  else:
    result = "processed: " & sp.filters
    if sp.passedBy > 0:
      result.add ", " & $sp.filtered & " of the " & $sp.averaged & " traces (" &
        auxText(sp.passedBy) & " not filtered: " & AuxOff & ")"
  if sp.filterNote.len > 0: result.add ". " & sp.filterNote
  if sp.insteadNote.len > 0: result.add ". " & sp.insteadNote
  if sp.ownNote.len > 0: result.add ". " & sp.ownNote
  if sp.reverseNote.len > 0: result.add ". " & sp.reverseNote

func auxUnfiltered*(w: SpectrumWindow): bool {.inline.} =
  ## Whether auxiliary traces of `w`'s spectrum were left unfiltered because
  ## the plot's Aux toggle is off (a click can tick it).
  w.spectrum.passedBy > 0 and w.spectrum.filterProblem.len == 0

func freeSpectrumId*(windows: openArray[SpectrumWindow]): int =
  ## The lowest FFT window id not in use, from 1: a window opened again
  ## takes the place a closed one of that number had in the layout.
  result = 1
  var again = true
  while again:
    again = false
    for w in windows:
      if w.id == result:
        inc result
        again = true

func windowColumns*(fromMs, toMs, t0Ms, dtMs: float64; samples: int): Slice[int] =
  ## The samples of a trace (its first at `t0Ms`, `dtMs` apart, `samples`
  ## of them) from `fromMs` to `toMs`, both included as far as the trace
  ## goes; every sample when either is NaN; none when they miss it.
  if samples <= 0 or not (dtMs > 0 and dtMs < Inf): return 0 .. -1
  if fromMs.isNaN or toMs.isNaN: return 0 ..< samples
  let a = max(0.0, ceil((fromMs - t0Ms) / dtMs - 1e-9))
  let b = min(float64(samples - 1), floor((toMs - t0Ms) / dtMs + 1e-9))
  if a > b: 0 .. -1 else: int(a) .. int(b)

func spectrumTraces*(samples: int): int =
  ## The traces of `samples` samples a spectrum takes at most.
  clamp(MaxSpectrumSamples div max(samples, 1), 1, MaxSpectrumTraces)

func evenly*(n, most: int): seq[int] =
  ## Indices into `n` items, at most `most` of them, spread evenly from the
  ## first (every one when `n <= most`).
  if n <= most:
    result = newSeq[int](n)
    for i in 0 ..< n: result[i] = i
  else:
    result = newSeq[int](most)
    for i in 0 ..< most: result[i] = int(float64(i) * float64(n) / float64(most))

func spectrumNfft*(windowLen: int; dtMs, narrowestHz: float64): int =
  ## The FFT length of a spectrum of windows of `windowLen` samples `dtMs`
  ## apart, under filters whose narrowest feature (a ramp, half a notch:
  ## processSEG's `narrowestRampHz`) is `narrowestHz` wide (`Inf` for none):
  ## the next power of two, doubled while a bin is wider than half that
  ## feature, up to `MaxSpectrumPadding` times. A 2 Hz notch over 1 s at
  ## 1 ms (1001 samples) is then sampled every 0.49 Hz, not 0.98: measured
  ## on a record with 60 Hz hum, its depth reads 21 dB below its
  ## neighbours, not 12.
  let base = nextPowerOfTwo(max(windowLen, 1))
  result = base
  if dtMs > 0 and dtMs < Inf:
    while result < MaxSpectrumPadding * base and
        1000 / (float64(result) * dtMs) > narrowestHz / 2:
      result *= 2

const
  ResponseSteps* = 1024
    ## a response's even points from 0 Hz to Nyquist, less one: the
    ## features' own points come on top
  FeaturePoints = 64 ## points over each notch (and 32 over each ramp), at most
  MaxFeaturePoints = 2048 ## over all the features together, at most

func responseGrid*(specs: openArray[FilterSpec]; nyquistHz: float64): seq[float64] =
  ## The frequencies to draw `specs`' response at: 0 to `nyquistHz` in
  ## `ResponseSteps` even steps, and densely over each feature: across each
  ## notch (twice its width) and at its very centre, across each cos² ramp,
  ## and the octave either side of a Butterworth corner; ascending, each
  ## once.
  result = newSeq[float64](ResponseSteps + 1)
  for k in 0 .. ResponseSteps: result[k] = nyquistHz * float64(k) / float64(ResponseSteps)
  var features = 0
  for s in specs: features += s.notches.len + 2
  let each = clamp(MaxFeaturePoints div max(features, 1), 8, FeaturePoints)
  template across(a, b: float64; n: int) =
    for j in 0 .. n: result.add a + (b - a) * float64(j) / float64(n)
  for s in specs:
    for n in s.notches:
      across(n.freqHz - n.widthHz, n.freqHz + n.widthHz, each)
      result.add n.freqHz
    case s.kind
    of rkTrapezoid:
      let c = s.corners
      if c.f2 > 0: across(c.f1, c.f2, each div 2)
      if c.f3 < Inf: across(c.f3, c.f4, each div 2)
    of rkButterworth:
      if s.lowHz > 0: across(s.lowHz / 2, s.lowHz * 2, each div 2)
      if s.highHz < Inf: across(s.highHz / 2, s.highHz * 2, each div 2)
  result.keepItIf(it >= 0 and it <= nyquistHz)
  result.sort()
  var kept = newSeq[float64]()
  for x in result:
    if kept.len == 0 or x - kept[^1] > 1e-9 * max(1.0, nyquistHz): kept.add x
  result = kept

func filterSpecs*(filters: Pipeline): seq[FilterSpec] =
  ## The responses of `filters`' FFT filters (a pass band, notches).
  result = @[]
  for op in filters:
    if op.kind == opFilter: result.add op.filter.spec

proc appliedResponse*(filters: Pipeline; dtMs: float64; samples: int;
    hz: openArray[float64]): seq[float64] =
  ## The gain `filters` apply at each of `hz` (Hz) to traces of `samples`
  ## samples `dtMs` apart: a unit impulse in the middle of such a trace put
  ## through them as the traces go (processSEG's plan, its edges and trend
  ## handling, in float32), then its output's amplitude at each frequency
  ## (a Fourier sum over the trace: the even points by folding it onto
  ## `2·ResponseSteps` samples, the others directly). Raises `ValueError`
  ## when the filters cannot run at `dtMs`.
  let n = max(samples, 1)
  var keys = @[initTraceKeys()]
  keys[0].status = tsLive
  keys[0].intervalUs = dtMs * 1000
  var lengths = @[n]
  var x = newSeq[float32](n)
  x[n div 2] = 1
  # The FFT filters alone, without the trend taken out before them: what
  # depends on the trace's own trend or mean (a DC removal, the trend
  # handling) is no gain an impulse can measure.
  var alone = initPipeline()
  for op in filters:
    if op.kind == opFilter: alone.add filterOp(op.filter.spec, trend = trNone)
  let plan = alone.compile(float32, dtMs, n, recordSamples = n)
  var ws = initWorkspace()
  ws.reserve(plan)
  plan.apply(rowBlock(x, 1, n), initChunkMeta(rowsOf(keys, lengths), dtMs), ws)
  result = newSeq[float64](hz.len)
  let fold = 2 * ResponseSteps
  var folded = newSeq[float64](fold) # the response sampled every 1 / (fold · dt)
  for j in 0 ..< n: folded[j mod fold] += float64(x[j])
  let nyq = nyquistHz(dtMs)
  for i, f in hz:
    let even = f * float64(ResponseSteps) / nyq
    let k = int(round(even))
    let (data, len) = if abs(even - float64(k)) < 1e-9: (0, fold) else: (1, n)
    # the sum of x[j]·e^(-2πi·f·j·dt), by a rotation per sample
    let w = -2 * PI * f * dtMs / 1000
    let (cw, sw) = (cos(w), sin(w))
    var (c, s) = (1.0, 0.0)
    var (re, im) = (0.0, 0.0)
    for j in 0 ..< len:
      let v = if data == 0: folded[j] else: float64(x[j])
      re += v * c
      im += v * s
      (c, s) = (c * cw - s * sw, c * sw + s * cw)
    result[i] = sqrt(re * re + im * im)

proc initSpectrumSum*(dtMs: float64; windowLen: int; nfft = 0): SpectrumSum =
  ## An empty sum of spectra of windows of `windowLen` samples `dtMs` apart,
  ## by FFTs of `nfft` (0: the window's next power of two). Raises
  ## `ValueError` for a window of no sample, an interval that is not
  ## positive and finite, or an `nfft` shorter than the window.
  result = SpectrumSum(sum: initSpectrumAccumulator(float32, dtMs, windowLen, nfft = nfft),
    ws: initWorkspace())
  result.plan = initSpectrumPlan(float32, dtMs, windowLen, nfft = PhaseStep * result.sum.nfft)
  result.ws.reserve(result.sum.workspaceSize)
  result.ws.reserve(result.plan.workspaceSize)

proc add*(s: var SpectrumSum; b: RowBlock[float32]; meta: ChunkMeta; firstCol: int): int =
  ## Adds the spectra of the window from `firstCol` of `b`'s live rows;
  ## the rows it used (dead, auxiliary, failed rows, rows with a sample
  ## that is not a number in the window, or none in it, are left out).
  s.sum.add(b, meta, firstCol, s.ws)

proc phaseOf*(s: var SpectrumSum; x: openArray[float32]): FinePhase =
  ## The amplitude and the phase of one window of a trace (`x`, up to the
  ## window's length), in degrees, on the grid `PhaseStep` times finer than
  ## the bins (processSEG's `amplitudeInto`): bin `k` is point `PhaseStep·k`.
  var amp, phase = newSeq[float32](s.plan.bins)
  s.plan.amplitudeInto(x, amp, phase, s.ws)
  result = FinePhase(amp: newSeq[float64](amp.len), phase: newSeq[float64](phase.len))
  for k, p in phase:
    result.amp[k] = float64(amp[k])
    result.phase[k] = float64(p) * 180 / PI

func atBins*(fine: openArray[float64]; bins: int): seq[float64] =
  ## The values of a grid `PhaseStep` times finer at the spectrum's `bins`
  ## bins: every `PhaseStep`th point.
  if fine.len == 0: return
  result = newSeq[float64](bins)
  for k in 0 ..< bins: result[k] = fine[min(k * PhaseStep, fine.high)]

func used*(s: SpectrumSum): int {.inline.} = s.sum.used
  ## The rows summed so far.

func bins*(s: SpectrumSum): int {.inline.} = s.sum.bins
func binHz*(s: SpectrumSum): float64 {.inline.} = s.sum.binHz(1)
func nfft*(s: SpectrumSum): int {.inline.} = s.sum.nfft

func amplitudes*(s: SpectrumSum): seq[float64] =
  ## The power-averaged amplitude per bin: the RMS amplitude over the rows
  ## summed; all zero for none.
  result = newSeq[float64](s.sum.bins)
  s.sum.amplitudesInto(result)

proc dbOf*(amps: openArray[float64]; reference: float64; floorDb = -120.0): seq[float64] =
  ## `20·log10(amp / reference)` per bin, at least `floorDb`: processSEG's
  ## `toDbInto` against `reference` (an amplitude), so that two curves (raw
  ## and processed) compare on one scale. A reference that is not positive
  ## and finite is one sample unit.
  result = newSeq[float64](amps.len)
  let ref1 = if reference > 0 and reference < Inf: reference else: 1.0
  toDbInto(amps, result, dbAbsolute, floorDb, ref1)

proc levelDb*(amp, reference: float64): float64 =
  ## `amp` in dB against `reference`, `20·log10(amp / reference)`, unclamped
  ## (what a spectrum's cursor reads, the window and agents alike); NaN when
  ## there is no level: an amplitude of 0 (or not finite), or no reference
  ## (a spectrum of zeros).
  if not (reference > 0 and reference < Inf and amp > 0 and amp < Inf): return NaN
  var db = [0.0]
  toDbInto([amp], db, dbAbsolute, -Inf, reference)
  db[0]

func peakOf*(amps: openArray[float64]): float64 =
  ## The largest finite amplitude; 0 for none.
  result = 0.0
  for a in amps:
    if a > result and a < Inf: result = a

func peakBin*(amps: openArray[float64]): int =
  ## The bin of the largest amplitude; -1 for none.
  result = -1
  var best = 0.0
  for k, a in amps:
    if a > best and a < Inf:
      best = a
      result = k
