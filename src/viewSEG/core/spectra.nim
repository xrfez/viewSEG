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
## The filters' own response (processSEG's `responseInto`) comes with the
## answer, on the same bins, to be drawn over the curves. A spectrum of
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
## **Raw and processed.** The raw curve is of the samples as the file has
## them; the processed one of the same samples through the plot's filters
## (`core/processing`, made for the spectrum's own sample interval), run on
## whole traces before the window is cut, so the filters' edges never fall
## in it. A plot shown raw still gets the processed curve: the two compare.
## The processed curve is of the traces the filters reach only: an
## auxiliary trace goes through them only when the plot's Aux toggle says
## so (`Processing.aux`), so with it off the processed curve leaves the
## auxiliary traces out (`passedBy` counts them), and with no trace reached
## there is none; nor is there when the filters cannot run at the traces'
## interval (`filterProblem`). The answer says which (`filtered`,
## `passedBy`, `filterNote`), so the words never claim a filter that was
## not applied.
##
## The work runs on a thread of its own (`core/spectrumreader`); `AppState`
## keeps the windows (`SpectrumWindow`).

import std/math
import parseSEG
import processSEG/fft/spectrum
import processSEG/core/[rows, types, workspace]
import panels, processing, viewport

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
    logFrequency*: bool       ## the frequency axis is logarithmic
    time*: SpectrumTime = stWhole
    raw*: bool = true         ## the raw curve is drawn
    processed*: bool = true   ## the curve through the filters is drawn
    response*: bool = true    ## the filters' own response is drawn (when there are some)
    phase*: bool              ## a one-trace spectrum's phase is drawn under its amplitude

  SpectrumOf* = enum
    ## What chose a spectrum's traces.
    soNothing = "nothing"
    soTrace = "trace"             ## the trace under the pointer
    soSelection = "selection"     ## the selected traces
    soVisible = "visible traces"  ## the traces the plot shows

  Spectrum* = object
    ## An answer: the averaged amplitude spectra of the traces asked about.
    gen*: uint64            ## the request's
    id*: int                ## the window's
    binHz*: float64         ## the bins' spacing; bin k is at k·binHz, the last at Nyquist
    raw*: seq[float64]      ## per bin, the RMS amplitude of the samples as recorded
    processed*: seq[float64]
      ## per bin, of the traces through the filters (`filtered`); empty when
      ## there are none, they reach no trace, or they cannot run
    rawPhase*, processedPhase*: seq[float64]
      ## of a spectrum of one trace: per bin, its phase in degrees (-180 to
      ## 180, from the window's first sample); empty for several traces
    asked*: int             ## traces asked about
    averaged*: int          ## traces averaged
    killed*: int            ## left out: killed
    dead*: int              ## left out: marked dead in the file
    failed*: int            ## left out: not decoded, a sample not a number, or none in the window
    atOtherInterval*: int     ## left out: sampled at another interval
    dtMs*: float64          ## the sample interval
    fromMs*, toMs*: float64 ## the window's first and last sample's times
    windowLen*: int         ## its samples
    nfft*: int              ## the FFT's length
    read*: int              ## traces read from the file for it (0: all at hand)
    filters*: string        ## the plot's filters asked for, in words; "" for none
    filterAux*: bool        ## the auxiliary traces were asked to go through them
    filtered*: int          ## of `averaged`, the traces `processed` is of
    passedBy*: int
      ## of `averaged`, the auxiliary traces the filters passed by (the Aux
      ## toggle off): in `raw`, left out of `processed`
    filterNote*: string
      ## what the sample interval cut of the filters (`limitNote`); "" for nothing
    filterProblem*: string
      ## why the filters cannot run on these traces, a clause ("none of them
      ## is below Nyquist"); "" when they did or there are none
    response*: seq[float64]
      ## per bin, the filters' gain, 0 to 1 (processSEG's `responseInto`
      ## for each FFT filter, multiplied): what they do whatever the data;
      ## empty when they have no pass band or notch, or did not run
    problem*: string        ## why there is no spectrum; "" when there is one

  SpectrumWindow* = object
    ## A spectrum window: an FFT window opened from the plot's menu (a
    ## snapshot of the traces it was opened on), or the live panel (`id`
    ## 0), which follows the Seismic window's view or selection.
    id*: int                  ## 0: the live panel; FFT windows from 1
    display*: SpectrumDisplay
    frozen*: bool             ## the live panel keeps what it shows
    shown*: bool              ## the live panel: on screen (it works only then)
    front*: int               ## bumped when it is to be brought forward (an agent showed it)
    chosen*: SpectrumOf
    file*: string             ## the file's name; "" for none
    record*: string           ## the record's FFID, or its place in the file
    traces*: seq[int]         ## survey-wide ids of the traces it is of, ascending
    first*: int               ## the first one's index in its file
    chosenCount*: int
      ## the traces chosen (selected, in view); `traces` spreads over them
      ## evenly when they are more than a spectrum takes (`spectrumTraces`)
    visibleMs*: Span
      ## the plot's visible time when the window was opened (FFT), or now (live)
    panel*: PanelId           ## the plot it is of (the live panel: the Seismic window)
    filters*: string          ## the plot's filters, in words, when asked; "" for none
    processing*: Processing   ## them, as asked last (shown raw or not, alike)
    killed*: seq[int]         ## its traces killed when it asked last (indices in the file)
    editsSeen*: int           ## its file's edits' revision then
    spectrum*: Spectrum       ## the newest answer taken in
    asked*: uint64            ## the newest request's gen; 0 for none
    since*: uint64
      ## answers to requests from before this gen are of something else (a
      ## closed window of the same number, what the live panel showed before)
    waiting*: bool            ## an answer newer than `spectrum` is on its way
    asks*: int                ## requests made (for tests: the work follows the view)
    revision*: int            ## bumped on every change

  SpectrumSum* = object
    ## The power average of many traces' spectra, block by block.
    plan: SpectrumPlan[float32]
    ws: Workspace
    amp: seq[float64]
    power: seq[float64] ## Σ amplitude² · rows over the blocks
    used: int

const
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
  if w.traces.len == 0: return "nothing"
  result = if w.chosen == soVisible: $w.traces.len & " visible traces"
           elif w.traces.len == 1: "trace " & $(w.first + 1)
           else: $w.traces.len & " traces"
  if w.record.len > 0: result.add " · " & w.record
  if w.file.len > 0: result.add " · " & w.file

func title*(w: SpectrumWindow): string =
  ## A window's title, named for what it shows: "FFT: trace 12 · ...",
  ## "FFT 2: ..." from the second FFT window on; the live panel is
  ## "Spectrum".
  if w.id == LiveSpectrum: "Spectrum"
  elif w.id == 1: "FFT: " & w.label
  else: "FFT " & $w.id & ": " & w.label

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
  ## what Nyquist cut of them after it.
  template sp: untyped = w.spectrum
  if sp.raw.len == 0: return ""
  if sp.filters.len == 0: return "no filters on the plot: the raw curve only"
  if sp.filterProblem.len > 0:
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

proc initSpectrumSum*(dtMs: float64; windowLen: int; nfft = 0): SpectrumSum =
  ## An empty sum of spectra of windows of `windowLen` samples `dtMs` apart,
  ## by FFTs of `nfft` (0: the window's next power of two). Raises
  ## `ValueError` for a window of no sample, an interval that is not
  ## positive and finite, or an `nfft` shorter than the window.
  result = SpectrumSum(plan: initSpectrumPlan(float32, dtMs, windowLen, nfft = nfft),
    ws: initWorkspace())
  result.ws.reserve(result.plan.workspaceSize)
  result.amp = newSeq[float64](result.plan.bins)
  result.power = newSeq[float64](result.plan.bins)

proc add*(s: var SpectrumSum; b: RowBlock[float32]; meta: ChunkMeta; firstCol: int): int =
  ## Adds the spectra of the window from `firstCol` of `b`'s live rows;
  ## the rows it used (dead, auxiliary, failed rows, rows with a sample
  ## that is not a number in the window, or none in it, are left out).
  result = s.plan.averageAmplitudeInto(b, meta, firstCol, s.amp, s.ws)
  if result > 0:
    for k in 0 ..< s.amp.len: s.power[k] += s.amp[k] * s.amp[k] * float64(result)
    s.used += result

proc phaseOf*(s: var SpectrumSum; x: openArray[float32]): seq[float64] =
  ## The phase of one window of a trace (`x`, up to the window's length),
  ## in degrees per bin (processSEG's `amplitudeInto`).
  var amp, phase = newSeq[float32](s.plan.bins)
  s.plan.amplitudeInto(x, amp, phase, s.ws)
  result = newSeq[float64](phase.len)
  for k, p in phase: result[k] = float64(p) * 180 / PI

func used*(s: SpectrumSum): int {.inline.} = s.used
  ## The rows summed so far.

func bins*(s: SpectrumSum): int {.inline.} = s.plan.bins
func binHz*(s: SpectrumSum): float64 {.inline.} = s.plan.binHz(1)
func nfft*(s: SpectrumSum): int {.inline.} = s.plan.nfft

func amplitudes*(s: SpectrumSum): seq[float64] =
  ## The power-averaged amplitude per bin: the RMS amplitude over the rows
  ## summed; all zero for none.
  result = newSeq[float64](s.power.len)
  if s.used > 0:
    for k in 0 ..< s.power.len: result[k] = sqrt(s.power[k] / float64(s.used))

proc dbOf*(amps: openArray[float64]; reference: float64; floorDb = -120.0): seq[float64] =
  ## `20·log10(amp / reference)` per bin, at least `floorDb`: processSEG's
  ## `toDbInto` against one sample unit, moved to the caller's reference,
  ## so that two curves (raw and processed) compare on one scale.
  result = newSeq[float64](amps.len)
  toDbInto(amps, result, dbAbsolute, floorDb = -1000.0)
  let shift = if reference > 0 and reference < Inf: 20 * log10(reference) else: 0.0
  for x in result.mitems: x = max(x - shift, floorDb)

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
