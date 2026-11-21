## What each plot tells you, in words: the text of the Explain icon every plot
## carries, and of the user guide's page of plots (`docs/user/plots.md`).
##
## One home for the words: a proc from the kind of plot (`PlotKind`) and the
## plot's current settings (`ExplainFacts`) to a text, with no toolkit types, so
## the interface, the guide, the agents' state and the tests all read the same.
## The text is four short parts, in this order:
##
## - **Shows**: each axis with its unit, and what one curve or one colour is;
## - **Computed from**: which traces and which window, and which of the filters,
##   the reversal, the time shift and the reference are applied now;
## - **Reading it**: what a good result looks like and what a problem looks like;
## - **Careful**: what can mislead, only where it is true of that plot.
##
## Facts that are not known (a plot made without a window, the guide's page) are
## left out of the sentence, and the sentence stays true of every case.
##
## `viewKinds`, `kindOfPane` and `kindsOfSpectrum` say which kinds each window
## shows; the guard test walks the enums so that a new plot or a new view
## cannot be added without its words.

import std/[math, strutils]
import analysis, compare, gainlabel, mapkinds, orientation, panels, phasepicture, processing,
  readout, references, settings, spectra, state, units

export phasepicture

type
  PlotKind* = enum
    ## Every plot the program draws: the Seismic window's, each pane of each
    ## analysis window, the map, the header graph, the previews of Generate and
    ## of a reference's window, and each pane of Compare.
    pkSeismic = "Seismic plot"
    pkSpectrum = "Spectrum: amplitude"
    pkSpectrumPhase = "Spectrum: phase"
    pkSpectrogram = "Spectrogram"
    pkEnvelope = "Envelope: amplitude and envelope"
    pkInstPhase = "Envelope: instantaneous phase"
    pkInstFrequency = "Envelope: instantaneous frequency"
    pkPhaseAmplitude = "Phase spectrum: amplitude"
    pkPhase = "Phase spectrum: phase"
    pkCorrelation = "Cross-correlation: correlation"
    pkCorrelationRatio = "Cross-correlation: amplitude to the reference"
    pkCorrelationPhase = "Cross-correlation: phase to the reference"
    pkVibPhase = "Vibrator signature: phase to the reference"
    pkVibForce = "Vibrator signature: force"
    pkVibForceMB = "Vibrator signature: force from M and B"
    pkVibFrequency = "Vibrator signature: frequency"
    pkVibDistortion = "Vibrator signature: distortion"
    pkFk = "f-k"
    pkOrientation = "Node orientation"
    pkHeaderGraph = "Header graph"
    pkMap = "Map"
    pkGenerateSignal = "Generate: signal"
    pkGenerateSpectrum = "Generate: spectrum"
    pkReferenceSignal = "Reference window: signal"
    pkReferenceSpectrum = "Reference window: spectrum"
    pkCompareSignal = "Compare: signals"
    pkCompareSpectrum = "Compare: spectra"
    pkComparePhase = "Compare: phase of B minus A"
    pkCompareCorrelation = "Compare: correlation"

  ExplainFacts* = object
    ## The plot's current settings, as far as its text names them. Every field
    ## has a neutral default: the text then says it in general.
    live*: bool
      ## made from a real window: the text states what is applied now ("as
      ## recorded", "no reversal"), not what may be
    units*: UnitSystem ## the Units setting
    label*: string ## what the plot is of: "trace 12 · FFID 151 · shot.sgd"
    count*: int ## the traces it is of; 0: not known
    filters*: string ## the plot's filters in words; "" none
    skipped*: string ## what the filters left out, in words ("" nothing)
    own*, reversal*: string ## the traces' own filters, reversal, in words
    # the Seismic plot
    panel*: string = "Seismic"
    mode*: DisplayMode = dmWiggle
    gain*: string ## "AGC 500 ms"
    timeDown*: bool = true
    fills*: set[WiggleFill] = {wfPositive}
    colourMap*: ColourMap = cmGrey
    order*: string ## the trace order in words; "" the file's
    allReversed*: bool
    # a spectrum
    db*: bool = true
    logFrequency*: bool
    curves*: set[SpectrumCurve] = {scRaw, scProcessed}
    wholeTrace*: bool = true
    fromMs*, toMs*: float64 = NaN
    binHz*, nyquistHz*: float64 = NaN
    averaged*: int
    picture*: PhasePicture = ppUnwrapped
    phaseShow*: PhaseShow = psAbsolute ## a phase difference, Absolute or Signed
    # the analysis windows
    windowMs*: float64 = NaN
    overlap*: float64 = NaN
    floorDb*: float64 = NaN
    withinDb*: float64 = NaN
    lagMs*: float64 = NaN
    colour*: string
    reference*: string
    against*: bool
      ## an envelope's phase is the difference from the reference's (else the
      ## trace's own, which turns once per cycle)
    fkFromMs*, fkToMs*: float64 = NaN
    fkRaw*: bool
    wavenumber*, velocity*: string ## an f-k's units
    # the vibrator signature
    roles*: string
    reactionMass*, baseplateMass*: string ## shown in the Units setting's mass unit
    details*: bool ## the vibrator signature shows every signal and the harmonics
    harmonics*: int
    axis*: string ## the force axis as it is labelled now
    # the header graph, the map, a generated or stored reference, Compare
    column*, scope*: string
    coordinates*, lengths*: string
    marks*: seq[string]
    hiddenGroups*: seq[string]
    subject*: string ## a sweep, a pilot, a reference, a pair of traces
    options*: string ## what is set on it, in words
    note*: string

# ---------------------------------------------------------------- helpers --

func num(x: float64): string =
  significant(x, 4)

func known(x: float64): bool {.inline.} = x == x and abs(x) < Inf

func part(label: string; sentences: varargs[string]): string =
  ## "Label: first second", the sentences that are not empty.
  var body = ""
  for s in sentences:
    if s.len > 0:
      if body.len > 0: body.add " "
      body.add s
  if body.len == 0: "" else: label & ": " & body

func join4(shows, computed, reading, careful: string): string =
  result = shows
  for p in [computed, reading, careful]:
    if p.len > 0: result.add "\n\n" & p

func closed(s: string): string =
  ## `s` with a full stop at its end, "" for none.
  if s.len == 0: "" elif s[^1] in {'.', '!', '?'}: s else: s & "."

func what(f: ExplainFacts; generic: string): string =
  ## "Of trace 12 · FFID 151 · shot.sgd." for a real window, else `generic`.
  if f.live and f.label.len > 0: "Of " & f.label & "." else: generic

const RawWords = "Raw: the plot's filters and a trace's own filter are not applied against " &
  "a reference, on either side (the raw trace against the raw reference)."

func filterClause(f: ExplainFacts): string =
  ## Which filters are applied: "As recorded (no filter is on)." or "After your
  ## filters (10-60 Hz)." and what they left out. Against a reference: none.
  if f.against: return RawWords
  if not f.live:
    return "Through the filters set in the Seismic window, if any are on."
  if f.filters.len == 0: "As recorded: no filter is on."
  else: "After your filters (" & f.filters & ")." &
    (if f.skipped.len > 0: " " & closed(f.skipped).capitalizeAscii else: "")

func editsClause(f: ExplainFacts): string =
  ## What was done to single traces: their own filter and their polarity.
  if f.against: return (if f.reversal.len > 0: closed(f.reversal) else: "No trace is reversed.")
  if not f.live: return "A trace's own filter and a reversed polarity are applied as set."
  result = (if f.own.len > 0: closed(f.own) else: "No trace has its own filter.")
  result.add " " & (if f.reversal.len > 0: closed(f.reversal) else: "No trace is reversed.")

func hzGap(binHz: float64): string =
  if known(binHz): "The frequency step is " & num(binHz) & " Hz: lower frequencies are not resolved."
  else: "The window's length sets the frequency step: a short window cannot show low frequencies."

func fillWords(f: ExplainFacts): string =
  if wfPositive in f.fills and wfNegative in f.fills: "both lobes filled"
  elif wfPositive in f.fills: "the positive lobes filled"
  elif wfNegative in f.fills: "the negative lobes filled"
  else: "no fill"

# ------------------------------------------------------------ the kinds' text --

func seismic(f: ExplainFacts): string =
  let across = if f.timeDown:
      "Traces run across the plot in the order shown (the display header names each one), " &
        "and time runs down it, in ms."
    else:
      "Time runs across the plot, in ms, and the traces are stacked down it in the order shown."
  let picture = case f.mode
    of dmWiggle: "One wiggle per trace: its amplitude swings sideways from its baseline, with " &
      f.fillWords & "."
    of dmWiggleDensity: "One wiggle per trace over a density picture of the same traces: the " &
      "colour is the amplitude in the " & $f.colourMap & " colour map."
    of dmDensity: "One column of colour per trace: the colour is the amplitude, in the " &
      $f.colourMap & " colour map, from its most negative end to its most positive."
  let gain = if f.gain.len > 0: "Display gain: " & f.gain & ". It sets which amplitude is " &
               "drawn at full strength; the file is never changed."
             else: "The display gain sets which amplitude is drawn at full strength; the " &
               "file is never changed."
  join4(part("Shows", picture, across),
    part("Computed from", "The samples of the " & f.panel & " traces of the record on show.",
      f.filterClause, f.editsClause,
      (if f.allReversed: "Every trace is reversed." else: ""),
      "Traces in " & (if f.order.len > 0: f.order else: "the file's order") & ".", gain),
    part("Reading it", "Events that run smoothly across neighbouring traces are signal " &
      "(first arrivals, reflections). A trace that stays flat is dead or silent. A trace far " &
      "stronger than its neighbours, or a spike over all times, is noise. A trace whose " &
      "swings mirror its neighbours' may have its polarity reversed."),
    part("Careful", "Amplitudes past the gain's full scale are clipped flat, so strong " &
      "traces look alike. Wiggles keep each pixel's largest and smallest sample when zoomed " &
      "out. Compare traces under one gain."))

func spectrumText(f: ExplainFacts): string =
  let scale = if f.db: "amplitude in dB, 0 dB at the larger peak of the raw and processed " &
                "curves" else: "amplitude in the file's sample units (a sine of amplitude A " &
                "on a bin reads A)"
  var drawn: seq[string] = @[]
  if scRaw in f.curves: drawn.add "raw is the traces as recorded, with their own filters"
  if scProcessed in f.curves: drawn.add "processed is the same through the plot's filters"
  if scResponse in f.curves:
    drawn.add "the faint response is the gain those filters apply at each frequency"
  let axisNote = if f.logFrequency: "The frequency axis is logarithmic (0 Hz left out)."
                 else: ""
  let time = if f.wholeTrace: "the whole trace"
             elif known(f.fromMs) and known(f.toMs): "the time the Seismic window shows (" &
               num(f.fromMs) & " to " & num(f.toMs) & " ms)"
             else: "the time the Seismic window shows"
  let traces = if f.averaged == 1: "One trace"
               elif f.averaged > 1: "The power average of " & $f.averaged &
                 " traces (RMS amplitude)"
               else: "One trace, or the power average of several"
  join4(part("Shows", "Frequency (Hz) across, from 0 Hz to Nyquist" &
      (if known(f.nyquistHz): " (" & num(f.nyquistHz) & " Hz)" else: "") & ", and " & scale &
      " up.", (if drawn.len > 0: "Curves: " & drawn.join("; ") & "." else: ""), axisNote),
    part("Computed from", traces & (if f.live and f.label.len > 0: ", of " & f.label else: "") &
        ".",
      "Over " & time & ", demeaned, tapered 10 % at each end and zero padded.",
      f.filterClause, f.editsClause),
    part("Reading it", "Energy should sit in the band the source makes. A hole or a sharp " &
      "drop shows a missing band; a narrow spike (50 or 60 Hz and its multiples) is power-line " &
      "noise; a processed curve under the raw one shows what your filters remove."),
    part("Careful", f.binHz.hzGap, "Averaging many traces hides a single bad one."))

func spectrumPhaseText(f: ExplainFacts): string =
  join4(part("Shows", "Phase in degrees up, against frequency in Hz across, for one trace.",
      PhaseMeaning[f.picture]),
    part("Computed from", "The same window, filters and trace as the amplitude above it; " &
      "phase is measured from the window's first sample, and drawn only where the amplitude is " &
      "within " & num(-PhaseFloorDb) & " dB of that curve's peak.", f.filterClause,
      f.editsClause),
    part("Reading it", "A straight slope means a pure time delay; a flat line means none. " &
      PhaseHelp),
    part("Careful", "Move the window's start and every slope changes: compare phase only " &
      "between plots cut the same way. Where there is no line the amplitude is too small for " &
      "the phase to mean anything."))

func spectrogramText(f: ExplainFacts): string =
  let frame = if known(f.windowMs): num(f.windowMs) & " ms frames" else: "Hann frames of the " &
    "length set above"
  let resolves = if known(f.windowMs): "about " & num(2000.0 / f.windowMs) & " Hz" else:
    "about 2 / W kHz for a frame of W ms"
  join4(part("Shows", "Time in ms across, frequency in Hz up; the colour is the amplitude in " &
      "dB below the largest amplitude in the picture (0 dB is the brightest cell" &
      (if known(f.floorDb): ", " & num(f.floorDb) & " dB the lowest colour" else: "") & ").",
      "One cell is one frame and one frequency bin."),
    part("Computed from", f.what("The traces chosen."),
      (if f.count > 1: "Several traces are combined as their power average (RMS)." else: ""),
      "Each trace's mean is removed first.",
      closed(frame & " (Hann), overlapping by " & (if known(f.overlap): num(f.overlap) &
        " %" else: "the overlap set above")), f.filterClause, f.editsClause),
    part("Reading it", "A sweep is a line climbing (or falling) across the picture; a " &
      "vertical streak is a short broadband burst such as a spike; a horizontal band is a " &
      "steady tone such as power-line noise; a band that fades shows lost energy at those " &
      "frequencies."),
    part("Careful", "A longer frame resolves frequency finer (" & resolves & ") but blurs " &
      "time. Colours are relative to the one brightest cell, not absolute amplitude."))

func referenceWords(f: ExplainFacts): string =
  if f.live and f.reference.len > 0: "Against the reference " & f.reference & "."
  elif f.live: "No reference is chosen."
  else: "Against the reference chosen in References (a stored trace, a generated sweep, or " &
    "the record's own pilot), or, when you pick it in the window, the record's own " &
    "vibrator reference trace (code 21)."

func envelopeText(f: ExplainFacts): string =
  join4(part("Shows", "Amplitude against time in ms: the trace as a line, and its envelope " &
      "(the trace's strength whatever its sign) over it."),
    part("Computed from", f.what("The first trace chosen."),
      "The envelope is the size of the trace's analytic signal (the trace and its Hilbert " &
      "transform).", f.filterClause, f.editsClause),
    part("Reading it", "The envelope should follow the peaks of the trace smoothly. A sweep " &
      "has a flat envelope between its tapers; a sudden drop or a spike in it shows a dropout " &
      "or a burst."),
    part("Careful", "Only one trace is shown, the first chosen. The envelope rings near " &
      "abrupt starts and ends."))

func showWords(f: ExplainFacts): string =
  ## Which way the phase difference is shown, in words (the option "Phase").
  "Shown " & PhaseShowWords[f.phaseShow] & "; the Phase drop-down above the plot changes it."

func instPhaseText(f: ExplainFacts): string =
  if f.against:
    return join4(part("Shows", "The instantaneous phase of the trace minus the reference's, " &
        "in degrees, against time in ms. " & f.showWords),
      part("Computed from", f.what("The first trace chosen."), f.referenceWords,
        "The angle of the trace's analytic signal times the reference's conjugate, where " &
        "both envelopes are within 60 dB of their peaks; the mean and the largest value of " &
        "the part drawn are under the plot.", f.filterClause, f.editsClause),
      part("Reading it", "0 means the trace keeps step with the reference; a steady value " &
        "is a steady phase lead (above 0, the trace ahead) or lag; a line that climbs or " &
        "falls is a time shift or a different frequency; scatter means noise."),
      part("Careful", "A difference is only known to a turn: Absolute shows its size, so it " &
        "never jumps between -180° and 180°; Signed keeps it around its own mean. Where either signal is weak the difference is not defined and is not " &
        "drawn. A reference shorter or longer than the trace is zero-padded."))
  join4(part("Shows", "The trace's own instantaneous phase in degrees (-180 to 180) against " &
      "time in ms."),
    part("Computed from", f.what("The first trace chosen."),
      "The angle of the trace's analytic signal; no value where the envelope is zero.",
      f.filterClause, f.editsClause),
    part("Reading it", "A steady signal makes a sawtooth that wraps at ±180°; its steepness " &
      "is the frequency. Where the sawtooth steepens or flattens the frequency changes, as " &
      "through a sweep; irregular jumps mean noise or no signal. It turns once per cycle: " &
      "choose a reference to compare."),
    part("Careful", "The phase wraps, so a jump from +180° to -180° is not an event. A " &
      "sweep's own phase moves a lot; that is not a fault, nothing is compared."))

func instFrequencyText(f: ExplainFacts): string =
  join4(part("Shows", "Instantaneous frequency in Hz against time in ms" &
      (if f.against: ", the trace's and, dim, the reference's." else: ".")),
    part("Computed from", f.what("The first trace chosen."),
      "The step of the instantaneous phase per sample; left out where the envelope is more " &
      "than 60 dB below its peak.", f.filterClause, f.editsClause),
    part("Reading it", "A linear sweep is a straight line from its start frequency to its " &
      "end frequency. A line that wanders or jumps means the signal is not the sweep, or " &
      "carries noise."),
    part("Careful", "Frequency is not defined where the signal is weak, so the line has gaps " &
      "there; at the two ends of the trace there is no value. The step is taken over two " &
      "samples, so a frequency above a quarter of the sampling rate wraps and reads " &
      "negative."))

func phaseAmplitudeText(f: ExplainFacts): string =
  join4(part("Shows", "Amplitude in dB below its peak (0 dB at the top) against frequency in Hz."),
    part("Computed from", f.what("The first trace chosen."),
      "The whole trace, its mean removed, with no taper, zero padded to four times its " &
      "length; phase is drawn " &
      "only where this curve is within " & (if known(f.withinDb): num(f.withinDb) else:
    "the dB set above") & " dB of its peak.", f.filterClause, f.editsClause),
    part("Reading it", "It tells where the phase below can be trusted: the phase means " &
      "something only where the amplitude is high."),
    part("Careful", "The whole trace is used, not the part shown in the Seismic window."))

func phaseText(f: ExplainFacts): string =
  join4(part("Shows", "Phase in degrees up, against frequency in Hz across, for one trace.",
      PhaseMeaning[f.picture]),
    part("Computed from", f.what("The first trace chosen."),
      "Phase from the trace's first sample, the trace's mean removed and zero padded to " &
      "four times its length, " &
      "drawn where the amplitude is within " & (if known(f.withinDb): num(f.withinDb) else:
    "the dB set above") & " dB of its peak.", f.filterClause, f.editsClause),
    part("Reading it", "A straight slope means a pure time delay; a flat line none. " &
      PhaseHelp),
    part("Careful", "Phase depends on where the trace starts. Where there is no line the " &
      "amplitude is too low for the phase to mean anything."))

func rawClause(f: ExplainFacts): string =
  ## The words of a window that compares traces with a reference: raw, and the reversal.
  RawWords & " " & (if f.live and f.reversal.len > 0: closed(f.reversal)
    elif f.live: "No trace is reversed." else: "A reversed polarity is applied as set.")

func correlationText(f: ExplainFacts): string =
  join4(part("Shows", "How well each trace matches the reference, up (1 is the reference's " &
      "own shape whatever its amplitude, -1 its mirror image), against the time shift in ms " &
      "across, one line per trace and its envelope over it."),
    part("Computed from", f.what("The traces chosen (the first eight at most)."),
      f.referenceWords, "Lags within ±" & (if known(f.lagMs): num(f.lagMs) & " ms" else:
    "the span set above") & " of zero.", f.rawClause,
    "A trace that is the reference delayed by T peaks at +T."),
    part("Reading it", "One sharp peak at 0 ms near +1 means the trace has the reference's " &
      "shape and timing. A lower peak means a different shape; a peak away from 0 is a time " &
      "shift of that many ms (a positive shift: the trace arrives after the reference). A " &
      "peak near -1 means reversed polarity. The words under the plot give each trace's best " &
      "match (the envelope's peak: the shape's match whatever the phase turn), its shift " &
      "between samples and its phase turn (\"rotated 90°\", \"reversed polarity\"); under " &
      "0.3 there is no clear match, and a peak at an end of the lags means the shift is past " &
      "them. The reference's own trace, among others, is said so and not drawn."),
    part("Careful", "The envelope peaks at the delay even when the phases of trace and " &
      "reference differ, where the line itself peaks lower. A different reference gives a " &
      "different picture."))

func ratioText(f: ExplainFacts): string =
  join4(part("Shows", "Amplitude ratio in dB up, against frequency in Hz across: each trace's " &
      "amplitude over the reference's; 0 dB is the same amplitude."),
    part("Computed from", f.what("The traces chosen."), f.referenceWords,
      "Drawn only where the reference has energy, within " & (if known(f.withinDb):
    num(f.withinDb) else: "the dB set above") & " dB of its peak.", f.rawClause),
    part("Reading it", "A flat line near 0 dB means the trace has the reference's spectrum. " &
      "A line that falls with frequency means high frequencies are lost; a step shows a band " &
      "that is weaker or stronger."),
    part("Careful", "A ratio is only as good as the reference's energy: near the ends of " &
      "its band the values are noisy."))

func ratioPhaseText(f: ExplainFacts): string =
  join4(part("Shows", "Phase difference in degrees up, against frequency in Hz across: each " &
      "trace's phase minus the reference's. " & f.showWords),
    part("Computed from", f.what("The traces chosen."), f.referenceWords,
      "Drawn where the reference has energy, within " & (if known(f.withinDb): num(f.withinDb)
    else: "the dB set above") & " dB of its peak.", f.rawClause),
    part("Reading it", "A flat line at 0° means no phase difference. A straight slope means " &
      "a time delay (a delay T reads -360° × frequency × T). A flat line at 180° means " &
      "reversed polarity."),
    part("Careful", "A phase is only known to a turn: Absolute shows its size, so it never " &
      "jumps between -180° and 180°; Signed keeps it within 180° of its own mean."))

func rolesWords(f: ExplainFacts): string =
  if f.live and f.roles.len > 0: "Roles: " & f.roles & "." else: ""

func failingWords(f: ExplainFacts; which: string): string =
  ## What the error colour means on one plot of the vibrator signature.
  if not f.live: return "A stretch in the error colour is a window past a limit of the verdict."
  case which
  of "phase": "A stretch in the error colour is a window whose mean |phase| is past the peak " &
    "phase limit."
  of "distortion": "A stretch in the error colour is a window whose mean distortion is past " &
    "the peak distortion limit."
  of "force": "A stretch in the error colour is a window whose peak is past the peak force " &
    "limit (in % of the 100 % force)."
  else: ""

func vibTrace(f: ExplainFacts): string =
  f.what("The traces of the window's roles.")

func vibPhaseText(f: ExplainFacts): string =
  join4(part("Shows", "Phase in degrees up, against sweep time in ms across (a point every " &
      "10 ms): the signal judged (GF, or GF (M, B)) measured against the pilot, Ref" &
      (if f.details: ", with the other ground force, M and B" else: "") & ". " & f.showWords),
    part("Computed from", f.vibTrace, f.rolesWords, "Each signal's phase to the reference " &
      "where the pilot's envelope is within 40 dB of its peak.", f.rawClause,
      f.failingWords("phase")),
    part("Reading it", "A ground force within a few degrees of 0° along the sweep means the " &
      "vibrator follows the pilot. A drift means poor control; a steady 180° means the " &
      "polarity is reversed (see Polarity)."),
    part("Careful", "The values are as recorded, with no calibration. M and B take one " &
      "polarity as a pair, because the baseplate moves against the mass."))

func vibForceText(f: ExplainFacts): string =
  join4(part("Shows", "Force against sweep time in ms: the ground force's fundamental " &
      "amplitude and its peak" & (if f.axis.len > 0: ", on the axis " & f.axis else: "") & "."),
    part("Computed from", f.vibTrace, f.rolesWords, "The fundamental is tracked along the " &
      "pilot's frequency.", f.rawClause, f.failingWords("force")),
    part("Reading it", "A steady fundamental through the sweep is a vibrator putting out " &
      "constant force. Dips mean lost output or hold-down; a peak far above the fundamental " &
      "means distortion or bouncing."),
    part("Careful", "Values are as recorded: the axis names the unit, the file's own " &
      "units unless its headers say force."))

func vibForceMBText(f: ExplainFacts): string =
  let masses = if f.live and f.reactionMass.len > 0 and f.baseplateMass.len > 0:
      "Mr = " & f.reactionMass & " (reaction mass), Mb = " & f.baseplateMass & " (baseplate)."
    else: "Needs the reaction mass and the baseplate mass, both entered above."
  join4(part("Shows", "GF (M, B), the ground force generated from the masses' " &
      "accelerations, against sweep time in ms: its fundamental amplitude and its peak" &
      (if f.axis.len > 0: ", on the axis " & f.axis else: "") & "."),
    part("Computed from", f.vibTrace, f.rolesWords, "GF (M, B) = Mr·a(M) + Mb·a(B).", masses,
      f.rawClause),
    part("Reading it", "It should follow the recorded ground force's shape. A large " &
      "difference between the two means a wrong mass or a bad accelerometer channel."),
    part("Careful", "Without the accelerometers' sensitivities this force is uncalibrated and " &
      "on an axis of its own: do not compare its level with the recorded force, and the " &
      "force limits are in % of the judged signal's own 100 % force."))

func vibFrequencyText(f: ExplainFacts): string =
  join4(part("Shows", "Instantaneous frequency in Hz up, against sweep time in ms across: the " &
      "pilot's (Ref) and the ground forces'."),
    part("Computed from", f.vibTrace, f.rolesWords, "Each signal's frequency is tracked along " &
      "the sweep.", f.rawClause),
    part("Reading it", "The ground force's line should lie on the pilot's. A gap between them " &
      "means the vibrator does not follow the sweep."),
    part("Careful", "Tracking is lost where a signal is weak, which leaves gaps."))

func vibDistortionText(f: ExplainFacts): string =
  let upTo = if f.harmonics >= 2: "H2 to H" & $f.harmonics else: "H2 up to the highest harmonic set"
  join4(part("Shows", "Distortion in % up, against sweep time in ms across: the total " &
      "harmonic distortion (THD) of each ground force, and each harmonic (" & upTo & ") of " &
      "the ground force as a % of its fundamental."),
    part("Computed from", f.vibTrace, f.rolesWords, "THD is the in-band distortion a " &
      "vibrator controller reports: it sums the harmonics, from the 2nd, whose frequency " &
      "stays within the top frequency box (the sweep's top, Hz); where none is in band " &
      "it is 0. A harmonic above 80 % of Nyquist is never measured.",
      f.rawClause, f.failingWords("distortion")),
    part("Reading it", "Lower is better. A smooth low THD is a clean sweep; a rise at one " &
      "point is a resonance or a stroke limit; one harmonic standing out is a specific fault."),
    part("Careful", "Distortion falls to 0 in the later part of a sweep, where the 2nd " &
      "harmonic is above the top frequency: that is how the controller reports it. A " &
      "wrong top frequency changes every number (the box and the verdict use it)."))

func fkText(f: ExplainFacts): string =
  let kind = if f.wavenumber.len > 0: "Wavenumber (" & f.wavenumber & ")"
             else: "Wavenumber (cycles per km or per kft with a regular spacing and a length " &
               "unit, else per trace)"
  let box = if known(f.fkFromMs) or known(f.fkToMs):
      "the box from " & (if known(f.fkFromMs): num(f.fkFromMs) else: "the traces' start") &
        " to " & (if known(f.fkToMs): num(f.fkToMs) else: "the traces' end") & " ms"
    else: "the whole time of the traces"
  join4(part("Shows", kind & " across, frequency in Hz up; the colour is the amplitude in dB " &
      "below the largest value" &
      (if known(f.floorDb): " (" & num(f.floorDb) & " dB the lowest colour)" else: "") & "."),
    part("Computed from", f.what("The traces chosen (4 at least)."), "A box of " & box &
      " and every trace, each trace's mean removed, tapered 10 % at each end in both " &
      "directions.",
      (if f.fkRaw: "The plot's filters are left out." else: f.filterClause), f.editsClause,
      (if f.velocity.len > 0: "The cursor reads the apparent velocity (" & f.velocity &
         ") as frequency over wavenumber." else: "")),
    part("Reading it", "An event of constant speed lies on a straight line through the " &
      "origin, steeper for a faster one: its slope is the apparent velocity. Slow events " &
      "such as ground roll lie at high wavenumber, reflections near the frequency axis."),
    part("Careful", "Wavenumbers past the traces' spatial Nyquist wrap around. An irregular " &
      "spacing makes the axis per trace, and the picture only a guide."))

func orientationText(f: ExplainFacts): string =
  join4(part("Shows", "The node's roll (about X, inline), pitch (about Y, crossline) and " &
      "azimuth (about Z, down) in degrees (up), for each trace in the order the plot " &
      "shows them (across): three lines."),
    part("Computed from", f.what("The traces the plot shows."), "The orientation header " &
      "each trace carries: no samples are read, and the plot's filters do not matter. " &
      "A trace without one leaves a gap in the lines.",
      "One point is drawn per trace as shown, so a record with several components per " &
      "shot repeats each reading once for each component."),
    part("Reading it", "A constant line is a node at rest. A step or a drift in the " &
      "lines means the node moved (it was bumped, dragged or settled) at that trace; " &
      "the traces after it were recorded in the new orientation."),
    part("Careful", "Azimuth jumps where it wraps past 180 or 360 degrees without the " &
      "node having moved. A header may state an orientation that was not measured."))

func headerGraphText(f: ExplainFacts): string =
  join4(part("Shows", "The value of " & (if f.column.len > 0: "the column \"" & f.column &
      "\"" else: "the graphed column") & " (up) for each row of the table, the rows in the " &
      "order shown (across): a band from the least to the most of each run of rows, and " &
      "a line along the most."),
    part("Computed from", "The rows of " & (if f.scope.len > 0: f.scope else:
    "the record shown or the whole file") & ", sorted and narrowed as the table is. The " &
    "rows on screen in the table are shaded."),
    part("Reading it", "A smooth line is a steady header; steps are changes (a new line, a " &
      "new record); a spike is one trace that differs, often a mistake in the headers."),
    part("Careful", "Many rows share a pixel: a narrow band hides single traces inside it " &
      "(it keeps each run's least and most)."))

func mapText(f: ExplainFacts): string =
  let hidden = if f.hiddenGroups.len > 0: "Hidden: " & f.hiddenGroups.join(", ") & "." else: ""
  join4(part("Shows", "Sources and receivers at their survey coordinates, north up, at equal " &
      "scale, with no basemap" & (if f.coordinates.len > 0: ". Coordinates are in " &
      f.coordinates else: "") & ". Discs are the surveyed positions (Preplot), rings the " &
      "positions the seismic files carry (Recorded)."),
    part("Computed from", "The survey files you loaded and the open files' own positions.",
      "The record on show is marked on top, its source larger and outlined.",
      (if f.lengths.len > 0: "The scale bar and the ruler read in " & f.lengths & "." else: ""),
      hidden,
      (if f.marks.len > 0: "Marked now: " & f.marks.join(", ") & "." else:
        "No QC filter is marking stations.")),
    part("Reading it", "Receivers should lie in regular lines and sources between or beside " &
      "them. A station off its line, a gap in a line, or two stations on one place suggests a " &
      "positioning problem in the files."),
    part("Careful", "Positions come from headers or files and are taken as given, with no " &
      "check against the real world. Points merge when zoomed out."))

func generateSignalText(f: ExplainFacts): string =
  join4(part("Shows", "Amplitude up, against time in ms across: the sample values of the " &
      (if f.subject.len > 0: f.subject else: "sweep, or the record's pilot, being made") &
      ", as one line."),
    part("Computed from", (if f.subject.len > 0: f.subject.closed else: "The settings in the " &
      "dialog, or the pilot trace of the record on show."), f.options,
      "The whole signal is shown, not the file under QC; nothing is stored until you press " &
      "Generate."),
    part("Reading it", "A sweep fills its length with a steady swing and ramps up and down " &
      "over its tapers; a pilot taken from a record looks like the recording of that sweep. " &
      "A flat or empty line means nothing was cut."),
    part("Careful", "A long sweep at a fine sample interval has far more samples than " &
      "pixels: each pixel shows the largest and smallest sample under it."))

func generateSpectrumText(f: ExplainFacts): string =
  join4(part("Shows", "Amplitude in dB below its peak (0 dB at the top) up, against " &
      "frequency in Hz across."),
    part("Computed from", "The signal above, whole, transformed with its own sample " &
      "interval. The axis spans the sweep's band and a quarter more on each side, within " &
      "Nyquist (a pilot taken from the record: 0 Hz to Nyquist).", f.options),
    part("Reading it", "A linear sweep gives a flat spectrum across its band, with ripple " &
      "at its edges; a boost in dB per octave or per Hz slopes it up or down; tapers round " &
      "the band's ends."),
    part("Careful", "It is the amplitude only, not the phase."))

func referenceSignalText(f: ExplainFacts): string =
  join4(part("Shows", "Amplitude up, against time in ms across: the samples of " &
      (if f.subject.len > 0: f.subject else: "the reference") & "."),
    part("Computed from", f.subject.closed, f.options,
      "It is what a correlation against this reference uses; the file under QC is not " &
      "touched."),
    part("Reading it", "A sweep should look like a sweep: a steady swing between its tapers. " &
      "A flat line or a spike means the wrong trace or window was stored."),
    part("Careful", "Each pixel shows the largest and smallest sample under it when the " &
      "reference is long."))

func referenceSpectrumText(f: ExplainFacts): string =
  join4(part("Shows", "Amplitude (linear, in the reference's own units) up, against " &
      "frequency in Hz across."),
    part("Computed from", "The reference's whole samples, transformed with their own sample " &
      "interval.", f.options),
    part("Reading it", "It shows the band the reference covers. A correlation can only " &
      "judge a trace over that band."),
    part("Careful", "Not in dB: a weak band looks flat. Use Generate's preview, or the " &
      "spectrum window, for dB."))

func compareSignalText(f: ExplainFacts): string =
  join4(part("Shows", "Amplitude up, against time in ms across: trace A, trace B, and B minus " &
      "A when you ask for the difference."),
    part("Computed from", (if f.subject.len > 0: f.subject.closed else:
    "The two traces set as A and B."), f.options),
    part("Reading it", "Matching traces lie over each other and their difference is flat " &
      "near zero. A gap in time is a timing error, a mirror image is reversed polarity, and " &
      "a steady scale factor is a gain difference."),
    part("Careful", "A difference needs both traces on one sample grid: other grids show " &
      "the traces only."))

func compareSpectrumText(f: ExplainFacts): string =
  join4(part("Shows", "Amplitude in dB up (0 dB at amplitude 1), against frequency in Hz " &
      "across, for A and for B, up to the lower of the two Nyquist frequencies."),
    part("Computed from", (if f.subject.len > 0: f.subject.closed else: "The traces A and B."),
      f.options, "Each over the common window, after the alignments you set."),
    part("Reading it", "Matching traces give curves on top of each other. A gap between them " &
      "is a level difference at those frequencies; a band where one drops is a filter or a " &
      "bad channel."),
    part("Careful", "A short window cannot resolve low frequencies; B is shown after " &
      "its flip, scale and shift."))

func comparePhaseText(f: ExplainFacts): string =
  join4(part("Shows", "Phase of B minus A in degrees up, against frequency in Hz across.",
      PhaseMeaning[f.picture]),
    part("Computed from", (if f.subject.len > 0: f.subject.closed else: "The traces A and B."),
      f.options, "Drawn where both spectra are within " & num(-PhaseFloorDb) & " dB of " &
      "their peak."),
    part("Reading it", "A flat line at 0° means the traces are in phase. A straight slope " &
      "means B is delayed against A. A flat line at 180° means B is reversed."),
    part("Careful", "Phase depends on the window; the wrapped picture jumps at ±180°."))

func compareCorrelationText(f: ExplainFacts): string =
  join4(part("Shows", "Correlation coefficient up, against lag in ms across, of A with B."),
    part("Computed from", (if f.subject.len > 0: f.subject.closed else: "The traces A and B."),
      "Before any alignment you set (flip, scale, shift) is applied.", f.options),
    part("Reading it", "One sharp peak near +1 at 0 ms means the traces match. A peak off " &
      "zero is the delay of B against A, in ms. A peak near -1 is reversed polarity."),
    part("Careful", "Needs both traces on one sample grid; otherwise it is not drawn and " &
      "the reason is written under the plots."))

func explain*(kind: PlotKind; f = ExplainFacts()): string =
  ## What plot `kind` tells you, as its settings `f` say.
  case kind
  of pkSeismic: f.seismic
  of pkSpectrum: f.spectrumText
  of pkSpectrumPhase: f.spectrumPhaseText
  of pkSpectrogram: f.spectrogramText
  of pkEnvelope: f.envelopeText
  of pkInstPhase: f.instPhaseText
  of pkInstFrequency: f.instFrequencyText
  of pkPhaseAmplitude: f.phaseAmplitudeText
  of pkPhase: f.phaseText
  of pkCorrelation: f.correlationText
  of pkCorrelationRatio: f.ratioText
  of pkCorrelationPhase: f.ratioPhaseText
  of pkVibPhase: f.vibPhaseText
  of pkVibForce: f.vibForceText
  of pkVibForceMB: f.vibForceMBText
  of pkVibFrequency: f.vibFrequencyText
  of pkVibDistortion: f.vibDistortionText
  of pkFk: f.fkText
  of pkOrientation: f.orientationText
  of pkHeaderGraph: f.headerGraphText
  of pkMap: f.mapText
  of pkGenerateSignal: f.generateSignalText
  of pkGenerateSpectrum: f.generateSpectrumText
  of pkReferenceSignal: f.referenceSignalText
  of pkReferenceSpectrum: f.referenceSpectrumText
  of pkCompareSignal: f.compareSignalText
  of pkCompareSpectrum: f.compareSpectrumText
  of pkComparePhase: f.comparePhaseText
  of pkCompareCorrelation: f.compareCorrelationText

# ------------------------------------------------------ which kinds a window shows --

func viewKinds*(v: AnalysisView): seq[PlotKind] =
  ## The plots an analysis window of view `v` can show, top first.
  case v
  of avSpectrogram: @[pkSpectrogram]
  of avEnvelope: @[pkEnvelope, pkInstPhase, pkInstFrequency]
  of avPhase: @[pkPhaseAmplitude, pkPhase]
  of avCorrelation: @[pkCorrelation, pkCorrelationRatio, pkCorrelationPhase]
  of avVibrator: @[pkVibPhase, pkVibForce, pkVibForceMB, pkVibFrequency, pkVibDistortion]
  of avFk: @[pkFk]
  of avOrientation: @[pkOrientation]

func kindOfPane*(v: AnalysisView; title: string): PlotKind =
  ## The kind of the pane of a window of view `v` that the result calls `title`
  ## (`AnalysisPlot.title`); the view's first kind for a title it does not know.
  let all = v.viewKinds
  case v
  of avSpectrogram, avFk, avOrientation: all[0]
  of avEnvelope:
    case title
    of "Instantaneous phase of the trace", "Phase against the reference": pkInstPhase
    of "Instantaneous frequency": pkInstFrequency
    else: pkEnvelope
  of avPhase: (if title == "Phase": pkPhase else: pkPhaseAmplitude)
  of avCorrelation:
    case title
    of "Amplitude compared with the reference, by frequency": pkCorrelationRatio
    of "Phase compared with the reference, by frequency": pkCorrelationPhase
    else: pkCorrelation
  of avVibrator:
    case title
    of "Force", "Force (GF as recorded)": pkVibForce
    of "Force from M and B": pkVibForceMB
    of "Frequency": pkVibFrequency
    of "Distortion": pkVibDistortion
    else: pkVibPhase

# ------------------------------------------------------- facts from the program --

func massText(kg: float64; u: UnitSystem): string =
  if kg.isNaN or kg <= 0: "" else: num(showMass(kg, u)) & " " & massName(u)

func factsOf*(w: AnalysisWindow; units: UnitSystem): ExplainFacts =
  ## The settings of analysis window `w`, as its plots' text names them.
  let p = w.params
  result = ExplainFacts(live: true, units: units, label: w.label, count: w.traces.len,
    filters: w.filters, own: w.ownLine, reversal: w.reverseLine, picture: p.phasePicture,
    phaseShow: p.phaseShow,
    windowMs: p.windowMs, overlap: p.overlap, floorDb: p.floorDb, withinDb: p.phaseWithinDb,
    lagMs: p.maxLagMs, reference: w.reference, fkFromMs: p.fkFromMs, fkToMs: p.fkToMs,
    fkRaw: p.fkRaw, colourMap: p.colourMap,
    against: w.view == avEnvelope and w.result.plots.len > 1 and
      w.result.plots[1].title == "Phase against the reference", harmonics: p.harmonics,
          details: p.details)
  if w.result.passedBy > 0: result.skipped = passedWords(w.result.passedBy)
  if w.view == avFk:
    result.wavenumber = w.result.image.xUnit
    result.velocity = w.result.image.velocityUnit
    if result.wavenumber.len > 0: result.wavenumber = "cycles " & result.wavenumber
  if w.view == avVibrator:
    result.reactionMass = massText(p.reactionMassKg, units)
    result.baseplateMass = massText(p.baseplateMassKg, units)
    result.roles = "Ref, GF, M and B as the table above sets them"
    for part in w.result.note.split("; "):
      if part.find("Ref ") >= 0 and part.find(" · ") >= 0:
        result.roles = part[part.find("Ref ") .. ^1]
        break
    if w.result.against.len > 0: result.roles = result.roles & ". " & w.result.against

func explainPane*(w: AnalysisWindow; units: UnitSystem; pane: int): string =
  ## What pane `pane` of analysis window `w` tells you (0 for an image).
  var f = w.factsOf(units)
  var kind = w.view.viewKinds[0]
  if pane in 0 ..< w.result.plots.len:
    let title = w.result.plots[pane].title
    kind = kindOfPane(w.view, title)
    if w.view == avVibrator and kind in {pkVibForce, pkVibForceMB}:
      f.axis = axisDisplay(w.result.plots[pane].yLabel, units).label
  explain(kind, f)

func paneKind*(w: AnalysisWindow; pane: int): PlotKind =
  ## The kind of pane `pane` of `w`.
  if pane in 0 ..< w.result.plots.len: kindOfPane(w.view, w.result.plots[pane].title)
  else: w.view.viewKinds[0]

func explainWindow*(w: AnalysisWindow; units: UnitSystem): string =
  ## What every pane of `w` tells you, each under its name: the agents' `explain`.
  if w.result.plots.len == 0: return explainPane(w, units, 0)
  for i, p in w.result.plots:
    if i > 0: result.add "\n\n"
    result.add $paneKind(w, i) & "\n" & explainPane(w, units, i)

func factsOf*(w: SpectrumWindow; units: UnitSystem): ExplainFacts =
  ## The settings of spectrum window `w`.
  template sp: untyped = w.spectrum
  result = ExplainFacts(live: true, units: units, label: w.label, count: w.traces.len,
    filters: (if sp.processed.len > 0: sp.filters else: ""), own: sp.ownNote,
    reversal: sp.reverseNote, db: w.display.scale == ssDb,
    logFrequency: w.display.logFrequency, wholeTrace: w.display.time == stWhole,
    picture: w.display.phasePicture, averaged: sp.averaged, binHz: sp.binHz,
    nyquistHz: (if sp.dtMs > 0: 500.0 / sp.dtMs else: NaN))
  for c in w.drawnCurves: result.curves.incl c
  if w.display.time == stVisible and not w.visibleMs.lo.isNaN:
    (result.fromMs, result.toMs) = (w.visibleMs.lo, w.visibleMs.hi)
  if sp.passedBy > 0: result.skipped = passedWords(sp.passedBy)
  if sp.insteadNote.len > 0:
    result.skipped = sp.insteadNote
  if sp.processed.len == 0 and sp.filters.len > 0:
    result.skipped = "the filters reached none of these traces"

func explainSpectrum*(w: SpectrumWindow; units: UnitSystem; phase: bool): string =
  ## What the amplitude plot of `w` (or its phase plot) tells you.
  explain(if phase: pkSpectrumPhase else: pkSpectrum, w.factsOf(units))

func explainSpectrumWindow*(w: SpectrumWindow; units: UnitSystem): string =
  ## What every plot `w` draws tells you, each under its name: the agents'
  ## `explain`. Its phase plot is there only while it is drawn.
  result = explainSpectrum(w, units, false)
  if w.display.phase and w.spectrum.rawPhase.len > 0:
    result.add "\n\n" & $pkSpectrumPhase & "\n" & explainSpectrum(w, units, true)

func kindsOfSpectrum*(): seq[PlotKind] =
  ## The plots of a spectrum window, top first.
  @[pkSpectrum, pkSpectrumPhase]

func seismicFacts*(st: AppState; k: int): ExplainFacts =
  ## The settings of the Seismic (or Aux) window shown by panel `k`.
  let p = st.panels[k]
  result = ExplainFacts(live: true, units: st.settings.units, panel: p.contentName)
  if p.layers.len == 0: return
  let l = p.layers[0]
  let d = l.display
  result.mode = d.mode
  result.fills = d.fills
  result.colourMap = d.colourMap
  result.timeDown = d.orientation == orTimeDown
  result.gain = gainSetting(d, if d.gain == dgAuto: d.effectiveGain(p.kind) else: d.gain)
  result.order = if l.order.len > 0: describe(l.order) else: ""
  result.allReversed = l.reversed
  if l.processing.hasFilters and not l.processing.raw: result.filters = describe(l.processing)

func mapFacts*(st: AppState; coordinates, lengths: string): ExplainFacts =
  ## The map's settings: the units of its coordinates and of its scale bar come
  ## from the caller (`view/maplayers`).
  result = ExplainFacts(live: true, units: st.settings.units, coordinates: coordinates,
    lengths: lengths)
  for f in MapFilter:
    if f in st.settings.map.filters: result.marks.add $f
  for g in MapGroup:
    if g in st.settings.map.hiddenGroups: result.hiddenGroups.add $g

func graphFacts*(column, scope: string): ExplainFacts =
  ## The header graph's settings: the column graphed and the rows' scope.
  ExplainFacts(live: true, column: column, scope: scope)

func sweepWords*(g: GeneratedReference): string =
  ## A sweep in words: "a linear sweep from 8 to 80 Hz over 10000 ms, sampled every 2 ms".
  result = "a " & $g.law & " sweep from " & num(g.f1Hz) & " to " & num(g.f2Hz) & " Hz over " &
    num(g.durationMs) & " ms"
  if g.dtMs > 0: result.add ", sampled every " & num(g.dtMs) & " ms"

func generateFacts*(g: GeneratedReference): ExplainFacts =
  ## The Generate dialog's sweep settings.
  var o: seq[string] = @[]
  if g.law in {rlDbPerOctave, rlDbPerHz}:
    o.add "The boost is " & num(g.boostDb) & (if g.law == rlDbPerHz: " dB per Hz." else:
      " dB per octave.")
  if g.taperStartMs > 0 or g.taperEndMs > 0:
    o.add "Tapers: " & num(g.taperStartMs) & " ms at the start, " & num(g.taperEndMs) &
      " ms at the end (" & $g.taperShape & ")."
  if g.phaseDeg != 0: o.add "Start phase " & num(g.phaseDeg) & "°."
  if g.amplitude > 0 and g.amplitude != 1: o.add "Amplitude " & num(g.amplitude) & "."
  ExplainFacts(live: true, subject: g.sweepWords, options: o.join(" "))

func pilotFacts*(rule: PilotRule; record, note: string): ExplainFacts =
  ## The Generate dialog's pilot taken from the record.
  let which = if rule.aux: "auxiliary trace " & $rule.trace else: "trace " & $rule.trace
  var o = "Cut from " & num(rule.startMs) & " ms for " & num(rule.spanMs) & " ms."
  if rule.phaseDeg == 180: o.add " Phase 180: turned over."
  if note.len > 0: o.add " " & closed(note).capitalizeAscii
  ExplainFacts(live: true, subject: "the pilot, " & which & " of " &
    (if record.len > 0: record else: "the record on show"), options: o)

func refViewFacts*(w: RefView): ExplainFacts =
  ## A reference window's settings.
  var o = ""
  if w.dtMs > 0: o = "Sampled every " & num(w.dtMs) & " ms from " & num(w.fromMs) & " ms."
  if w.pilotNote.len > 0: o.add " " & closed(w.pilotNote).capitalizeAscii
  ExplainFacts(live: true, subject: "the reference " & w.name, options: o)

func compareFacts*(st: AppState): ExplainFacts =
  ## Compare's settings: the two traces, and what is aligned or left out.
  let opt = st.compareOptions
  let pic = st.comparePicture
  var o: seq[string] = @[]
  if pic.alignNote.len > 0: o.add "Alignment of B: " & pic.alignNote & "."
  else: o.add "B is not aligned: as recorded."
  if opt.difference: o.add "The difference B - A is drawn."
  if known(pic.usedFromMs) and known(pic.usedToMs):
    o.add "Window " & num(pic.usedFromMs) & " to " & num(pic.usedToMs) & " ms."
  if pic.refusal.len > 0: o.add pic.refusal
  var subject = st.compareChip(cwA) & "; " & st.compareChip(cwB)
  ExplainFacts(live: true, units: st.settings.units, picture: opt.phasePicture,
    subject: subject, options: o.join(" "))

func explainCompare*(st: AppState; kind: PlotKind): string =
  explain(kind, st.compareFacts)

func explainSpectrum*(st: AppState; w: SpectrumWindow; phase: bool): string =
  ## What window `w`'s amplitude plot (or its phase plot) tells you now.
  explainSpectrum(w, st.settings.units, phase)

func explainPane*(st: AppState; w: AnalysisWindow; pane: int): string =
  ## What pane `pane` of analysis window `w` tells you now.
  explainPane(w, st.settings.units, pane)

func explainWindow*(st: AppState; w: AnalysisWindow): string =
  ## What every pane of `w` tells you now, each under its name.
  explainWindow(w, st.settings.units)

func explainSeismic*(st: AppState; k: int): string =
  ## What the plot of panel `k` tells you now.
  explain(pkSeismic, st.seismicFacts(k))

# ------------------------------------------------------------ the user guide --

func explainPage*(): string =
  ## The user guide's page of plots (`docs/user/plots.md`): one section per plot
  ## kind, with the words its Explain icon shows when nothing is known of the
  ## window (the icon names the settings in force). `nim plots` writes it;
  ## `tools/plotspage.nim check`, run by tests/texplain.nim, finds a page that
  ## has drifted.
  result = "# What each plot tells you\n\n" &
    "**Right-click any plot and choose Explain.** Every plot has it: the Seismic plot, the " &
    "spectrum, spectrogram, envelope, phase, correlation, vibrator signature and f-k " &
    "windows (each plot of a window on its own), the map, the header graph, the previews in " &
    "Generate and in a reference's window, and each plot of Compare. A popover says what " &
    "that plot shows, what it is computed from, how to read it and what can mislead; Esc " &
    "closes it. Where right-drag already zooms, a right click that does not drag opens the " &
    "menu; the Seismic plot's and the map's menus end with Explain.\n\n" &
    "The text names the settings in force: your filters, the reference, the units. The " &
    "sections below give each text without a window's settings, as it reads in general. " &
    "An agent reads the same words in `state`, as `explain`.\n"
  for kind in PlotKind:
    result.add "\n## " & $kind & "\n"
    for line in kind.explain.splitLines:
      if line.len == 0: continue
      let at = line.find(": ")
      result.add "\n**" & line[0 ..< at] & ".** " & line[at + 2 .. ^1] & "\n"
