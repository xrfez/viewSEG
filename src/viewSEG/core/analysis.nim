## Signal-analysis views of a plot's traces, opened from **New plot**: what
## each shows, its settings, and the numbers, worked out from the traces'
## samples (the analysis windows' reader, `core/analysisreader`, reads
## them; `AppState` keeps the windows).
##
## | View | What | From processSEG |
## |---|---|---|
## | Spectrogram | amplitude against time and frequency, in dB, an image | `spectrogramInto` |
## | Envelope | the trace, its envelope, its instantaneous phase and frequency | `analyticInto` |
## | Phase spectrum | amplitude (dB) and phase against frequency | `amplitudeInto` |
## | Cross-correlation | each trace against a reference: against lag, and compared per frequency | `crossCorrelateInto`, `compareInto` |
## | Vibrator signature | a unit's Ref, GF, M and B against sweep time: phase, force, frequency, distortion (`core/vibanalysis`) | `analyzeVibrators` |
## | f-k | a box of traces × time: amplitude against frequency and wavenumber, an image (`core/fkanalysis`) | `forward` (composed) |
## | Node orientation | roll, pitch and azimuth from the traces' orientation headers, one point per trace; no samples are read | parseSEG's `traceOrientation` |
##
## Every number here is processSEG's but for what it leaves to the caller:
## the phase spectrum drawn as its
## picture asks (`phasepicture`: unwrapped by default, magnitude, signed or
## with the delay taken off) and only where the amplitude is within
## `phaseWithinDb` of its peak (elsewhere the phase is noise), and the
## spectrogram of several traces, their power average (as the spectrum
## windows average), summed trace by trace so that it can be stopped between
## traces (processSEG's `averageSpectrogramInto` is one call).
##
## The procs are pure: they take samples and give an `AnalysisResult`, and
## never raise (a problem is said in `problem`).

import std/[math, strutils]
import processSEG/fft/[hilbert, plan, spectrogram, spectrum]
import processSEG/vibroseis/[crosscorrelate, sweeptrack, vibqc]
import processSEG/core/workspace
import colourmaps, matchpeak, panels, phasepicture, phaseshow, plotcursor, processing, signalend, traceids

export ColourMap, PlotCursor, Polarity, VibLimits
export phasepicture, phaseshow
export matchpeak.NoClearMatch

type
  AnalysisView* = enum
    ## What an analysis window shows.
    avSpectrogram = "spectrogram"
    avEnvelope = "envelope"
    avPhase = "phase spectrum"
    avCorrelation = "cross-correlation"
    avVibrator = "vibrator signature"
    avFk = "f-k"
    avOrientation = "node orientation"

  RoleSource* = enum
    ## Where a vibrator signature's roles came from.
    rsPosition = "window order" ## the order Ref, GF, M, B, nothing said otherwise
    rsCodes = "trace identification codes"
      ## the traces carry the SEG-Y vibrator codes (21 reference, 20 ground force,
      ## 18 reaction mass, 19 baseplate), which say who is who
    rsHand = "chosen by hand" ## a choice made in the window (or given by a command)
    rsRemembered = "remembered for this file layout"
      ## a choice made by hand on an earlier file of the same layout (the trace count of
      ## the record and its code sequence), kept in the project or the user's settings

  VibRoles* = object
    ## A vibrator signature's roles: each one's place among the window's
    ## traces (0: the first), -1 for none; by default the order Ref, GF,
    ## M, B, or, when the traces carry the vibrator codes, as they say
    ## (`withCodeRoles`). M and B take one polarity, as a pair (the baseplate
    ## moves against the mass: one reversed alone would turn the force they
    ## make into a difference).
    reference*: int = 0 ## the pilot (required)
    groundForce*: int = 1 ## the ground force, recorded
    mass*: int = 2 ## the reaction mass's acceleration
    baseplate*: int = 3 ## the baseplate's acceleration
    groundForcePolarity*: Polarity = poAsRecorded
    massPolarity*: Polarity = poAsRecorded ## M's and B's
    source*: RoleSource = rsPosition ## where the places above came from
    handFile*: string
      ## when `source` is `rsHand`: the file the choice was made on, whose roles it
      ## stays for; on another file the codes decide when the traces have them

  PhaseAgainst* = enum
    ## What an envelope window's phase plot shows.
    paReference = "Against the reference" ## the trace's phase minus the reference's
    paSelf = "Of the trace itself"        ## the trace's own instantaneous phase

  AnalysisParams* = object
    ## An analysis window's settings (each view uses its own).
    windowMs*: float64 = 128.0
      ## spectrogram: a frame's length (a Hann window): the time against
      ## frequency resolution (a frame of W ms resolves about 2/W kHz)
    overlap*: float64 = 75.0 ## spectrogram: how much a frame overlaps the next, %
    floorDb*: float64 = -60.0
      ## spectrogram, f-k: the lowest dB drawn (the colour map's low end)
    colourMap*: ColourMap = cmViridis ## spectrogram's and f-k's colours
    phaseWithinDb*: float64 = 20.0
      ## phase spectrum: the phase is shown where the amplitude is within
      ## this of the peak (elsewhere it is noise)
    phasePicture*: PhasePicture = ppUnwrapped
      ## phase spectrum: which picture is drawn (unwrapped by default)
    phaseShow*: PhaseShow = psAbsolute
      ## envelope (against the reference), correlation, vibrator signature: a phase
      ## difference shown as its size (0 to 180) or signed around its circular mean
    maxLagMs*: float64 = 250.0 ## cross-correlation: the lags shown, either side of 0
    fileReference*: bool = false
      ## envelope (against the reference), correlation: measured against the record's own
      ## reference trace (the SEG-Y vibrator reference, code 21) instead of the project's
      ## chosen reference; never chosen for the user
    phaseAgainst*: PhaseAgainst = paReference
      ## envelope: the phase against the chosen reference when there is one, or
      ## the trace's own
    fkFromMs*: float64 = NaN ## f-k: the box's first time, ms; NaN: the traces' start
    fkToMs*: float64 = NaN ## f-k: its last time, ms; NaN: the traces' end
    fkRaw*: bool = false
      ## f-k: the plot's filters left out. A trace's own filter still runs.
    roles*: VibRoles ## vibrator signature: which trace is which
    projectReference*: bool = true
      ## vibrator signature: measured against the project's chosen reference when it has
      ## one (the default: what the unit was meant to sweep); false: against the Ref role's
      ## recorded trace (what it says it swept)
    reactionMassKg*: float64 = NaN
      ## vibrator signature: the reaction mass, kg, for the ground force
      ## generated from M and B; NaN: none entered (no generated force)
    baseplateMassKg*: float64 = NaN ## vibrator signature: the baseplate's mass, kg
    harmonics*: int = 5 ## vibrator signature: the highest harmonic tracked (2 .. 16)
    limitsOn*: bool = false
      ## vibrator signature: the limits drawn, the points past them marked
      ## and a pass or fail table shown
    limits*: VibLimits = VibLimits(phaseDeg: 10, meanPhaseDeg: 5, thdPct: 40,
      meanThdPct: 20)
      ## vibrator signature: the limits (NaN: none); judged on the ground
      ## forces over the sweep less its tapers

  CurveStyle* = enum
    ## How a curve is drawn.
    csLine = "line"           ## a line: the data
    csLimit = "limit"         ## a limit: a thin line in the colour of a failure
    csPast = "past a limit"   ## the points past a limit, marked
    csReference = "reference" ## the reference's own, drawn dim beside the data

  AnalysisCurve* = object
    ## A curve of a plot: a value per x (NaN where there is none).
    name*: string
    ys*: seq[float64]
    xs*: seq[float64] ## its own xs, ascending (a limit's two ends); empty: the plot's
    brackets*: seq[float64]
      ## a second value the readout adds in brackets, per x (a phase's signed
      ## value); empty or NaN: none
    style*: CurveStyle

  AnalysisPlot* = object
    ## Curves over one x axis.
    title*: string
    xLabel*, xUnit*: string
    yLabel*, yUnit*: string
    xs*: seq[float64]
    curves*: seq[AnalysisCurve]
    yLo*, yHi*: float64 = NaN
      ## the value axis, fixed, when both are numbers (a phase magnitude's
      ## 0 to 180); NaN: the data's
    aside*: string ## appended to the cursor readout (a delay taken off, in ms)

  AnalysisImage* = object
    ## Values over a grid: column `i` at x `x0 + i·dx`, row `j` at y `y0 +
    ## j·dy`; `values[i·rows + j]`.
    cols*, rows*: int
    x0*, dx*, y0*, dy*: float64
    xLabel*, xUnit*, yLabel*, yUnit*, unit*: string
    values*: seq[float32]
    lo*, hi*: float32 ## the values the colour map's ends are drawn at
    velocityUnit*: string
      ## an f-k's: the unit of the apparent velocity a point reads, `y / x`
      ## times `velocityScale` ("m/s"); "": it reads none
    velocityScale*: float64 = 1.0

  AnalysisResult* = object
    ## An answer for an analysis window.
    gen*: uint64
    id*: int
    view*: AnalysisView
    plots*: seq[AnalysisPlot]
    image*: AnalysisImage ## a spectrogram's; empty otherwise
    table*: seq[seq[string]]
      ## a vibrator signature's summary per signal, the first row the
      ## columns' names; empty for none. The force columns stay in the
      ## stored unit; `forceUnits` names it so the window can show them.
    forceUnits*: seq[string]
      ## the stored unit of each table row after the header, for the force
      ## columns ("N", "as recorded", "kg × m/s²", ...); empty when the
      ## table has none
    used*: int ## traces it is of
    leftOut*: int ## of those asked about: killed, dead, not decoded, or (a Spectrogram or
                    ## Phase spectrum) with a sample that is not a number
    notNumber*: int ## of `leftOut`, those with a sample that is not a number
    zeroed*: int ## an f-k: traces with a sample that is not a number, taken as zeros
    atOtherInterval*: int ## of those asked about: sampled at another interval, or none
    notDrawn*: int
      ## live traces asked about that were not read at all, because the view draws
      ## no more than `MaxAnalysisCurves` (a correlation's)
    matches*: seq[Match]
      ## a correlation's verdict per drawn trace (the order of its curves): match, shift
      ## between samples, rotation (`core/matchpeak`)
    cancelled*: bool ## given up part way (the caller's `StopCheck` said so): no numbers
    passedBy*: int
      ## the auxiliary traces (the reference included) the plot's filters passed
      ## by because Filters > Filter the Aux traces too is off
    dtMs*: float64
    note*: string ## what the numbers are, in words (shown under the plot)
    warning*: string
      ## a trace that cannot be matched to the whole of its reference, one line each (shown
      ## first, in the warning colour): shorter than it, or its signal stops early
      ## (`core/signalend`); "" for none
    against*: string
      ## a vibrator signature's reference in one sentence: "Measured against the project
      ## reference X" or "Measured against the recorded reference, trace N"; "" for none
    problem*: string ## why there is none; "" when there is one

type StopCheck* = proc (): bool {.closure, gcsafe.}
  ## Asked between the steps of a long computation: true to give it up now.

func samePlaces*(a, b: VibRoles): bool =
  ## Whether `a` and `b` give every role the same trace.
  a.reference == b.reference and a.groundForce == b.groundForce and a.mass == b.mass and
    a.baseplate == b.baseplate

func withCodeRoles*(roles: VibRoles; codes: openArray[int16]; file: string): VibRoles =
  ## `roles` for a window whose traces have the trace identification `codes`
  ## (in the window's order) and are of `file`. A choice made by hand on this
  ## same file stays. Else, when the traces carry the vibrator reference code
  ## (21) and at least one of the ground force (20), reaction mass (18) and
  ## baseplate (19) codes, each role is the first trace with its code (-1: none
  ## has it), and `source` says so. Otherwise `roles` stand as they were.
  result = roles
  if roles.source == rsHand and roles.handFile == file: return
  var places = VibRoles(reference: -1, groundForce: -1, mass: -1, baseplate: -1)
  for i, c in codes:
    if c == VibReferenceCode and places.reference < 0: places.reference = i
    elif c == VibGroundForceCode and places.groundForce < 0: places.groundForce = i
    elif c == VibReactionMassCode and places.mass < 0: places.mass = i
    elif c == VibBaseplateCode and places.baseplate < 0: places.baseplate = i
  if places.reference >= 0 and (places.groundForce >= 0 or places.mass >= 0 or
      places.baseplate >= 0):
    result.reference = places.reference
    result.groundForce = places.groundForce
    result.mass = places.mass
    result.baseplate = places.baseplate
    result.source = rsCodes
    result.handFile = ""

const MaxLayoutKeyCodes = 64

func layoutKey*(codes: openArray[int16]; count = -1): string =
  ## A file layout: how many traces the record has (`count`; default `codes.len`) and
  ## their identification codes in order ("4/21.19.18.20"; the first 64 codes of a longer
  ## record).
  result = $(if count >= 0: count else: codes.len) & "/"
  for i, c in codes:
    if i >= MaxLayoutKeyCodes: break
    if i > 0: result.add '.'
    result.add $c

func choiceText*(layout: string; places: array[4, int]): string =
  ## A hand choice of roles kept for `layout`, as text: the layout, then the record's
  ## trace (from 0, -1 none) of Ref, GF, M and B: "4/21.19.18.20 0.3.1.2".
  result = layout & " "
  for i, p in places:
    if i > 0: result.add '.'
    result.add $p

func parseChoice*(text: string; layout: var string; places: var array[4, int]): bool =
  ## Reads what `choiceText` wrote.
  let parts = text.split(' ')
  if parts.len != 2 or parts[0].len == 0: return false
  let ps = parts[1].split('.')
  if ps.len != 4: return false
  var got: array[4, int]
  for i, x in ps:
    try: got[i] = parseInt(x)
    except ValueError: return false
    if got[i] notin -1 .. 100_000_000: return false
  (layout, places) = (parts[0], got)
  true

func choiceFor*(choices: openArray[string]; layout: string; places: var array[4, int]): bool =
  ## Whether `choices` hold one for `layout`, and its places.
  for c in choices:
    var l = ""
    var p: array[4, int]
    if parseChoice(c, l, p) and l == layout:
      places = p
      return true

func withChoice*(choices: seq[string]; layout: string; places: array[4, int]): seq[string] =
  ## `choices` with the one for `layout` set (the newest last; the oldest of 256 goes).
  for c in choices:
    var l = ""
    var p: array[4, int]
    if parseChoice(c, l, p) and l != layout: result.add c
  result.add choiceText(layout, places)
  if result.len > 256: result.delete 0

func withoutChoice*(choices: seq[string]; layout: string): seq[string] =
  ## `choices` without the one for `layout`.
  for c in choices:
    var l = ""
    var p: array[4, int]
    if parseChoice(c, l, p) and l != layout: result.add c

template stopped*(stop: StopCheck): bool =
  not stop.isNil and stop()

const RawAgainstReference* = "the plot's and the traces' own filters are not applied here: " &
  "raw trace against the raw reference"

const AuxFilterOff* = "Filters > Filter the Aux traces too is off"
  ## where the plot's Aux toggle is, as the words name it

func passedWords*(n: int): string =
  ## What `n` auxiliary traces the filters passed by are told as: "the 2
  ## auxiliary traces are not filtered: Filters > Filter the Aux traces too is
  ## off"; "" for none.
  if n <= 0: ""
  elif n == 1: "the auxiliary trace is not filtered: " & AuxFilterOff
  else: "the " & $n & " auxiliary traces are not filtered: " & AuxFilterOff

func `==`*(a, b: AnalysisParams): bool =
  ## Whether two settings are the same, a NaN (a limit or a mass not set)
  ## equal to a NaN.
  func same(x, y: float64): bool {.inline.} = x == y or (x.isNaN and y.isNaN)
  for x, y in fields(a, b):
    when x is float64:
      if not same(x, y): return false
    elif x is VibLimits:
      for u, v in fields(x, y):
        if not same(u, v): return false
    else:
      if x != y: return false
  true

type
  SettingRange* = object
    ## The values an analysis window's setting may take: the GUI's boxes and
    ## an agent's `plotParams` alike judge a value by it, so they agree.
    ## Finite always; `lo` and `hi` are included unless `loOpen` or `hiOpen`.
    lo*, hi*: float64
    loOpen*, hiOpen*: bool
    words*: string ## the range in words, for a message

const
  MaxTimeMs* = 3_600_000.0 ## the longest time a setting may be: an hour
  MaxLimit* = 1e9          ## the largest limit or mass a setting may be
  WindowMsRange* = SettingRange(lo: 0, loOpen: true, hi: MaxTimeMs,
    words: "above 0 and at most 3600000 ms")
  OverlapRange* = SettingRange(lo: 0, hi: 95, words: "from 0 to 95 %")
  FloorDbRange* = SettingRange(lo: -400, hi: 0, hiOpen: true,
    words: "from -400 to below 0 dB")
  PhaseWithinRange* = SettingRange(lo: 0, loOpen: true, hi: 400,
    words: "above 0 and at most 400 dB")
  LagMsRange* = SettingRange(lo: 0, loOpen: true, hi: MaxTimeMs,
    words: "above 0 and at most 3600000 ms")
  TimeMsRange* = SettingRange(lo: -MaxTimeMs, hi: MaxTimeMs,
    words: "from -3600000 to 3600000 ms")
  HarmonicRange* = SettingRange(lo: 2, hi: 16, words: "from 2 to 16")
  MassKgRange* = SettingRange(lo: 0, loOpen: true, hi: MaxLimit,
    words: "above 0 and at most 1000000000 kg")
  NumberRange* = SettingRange(lo: -MaxLimit, hi: MaxLimit,
    words: "from -1000000000 to 1000000000")
    ## a limit: any value in its range

func allows*(r: SettingRange; v: float64): bool =
  ## Whether `v` is a finite value within `r`; NaN (a setting that may be
  ## none) is not one.
  if v.isNaN or abs(v) == Inf: return false
  (if r.loOpen: v > r.lo else: v >= r.lo) and (if r.hiOpen: v < r.hi else: v <= r.hi)

func settingProblem*(p: AnalysisParams; view: AnalysisView): string =
  ## Why `p` cannot be the settings of a window of `view`, naming the first
  ## setting the view uses that is out of its range, and that range; ""
  ## when it can. A null (NaN) is refused, except where the setting may be
  ## none: an f-k's box ends, the vibrator's masses and limits.
  template check(name: string; v: float64; r: SettingRange; none = false) =
    if not (r.allows(v) or (none and v.isNaN)):
      return name & " must be " & r.words & ", not " &
        (if v.isNaN: "null" else: $v)
  case view
  of avSpectrogram:
    check("windowMs", p.windowMs, WindowMsRange)
    check("overlap", p.overlap, OverlapRange)
    check("floorDb", p.floorDb, FloorDbRange)
  of avEnvelope, avOrientation: discard
  of avPhase:
    check("phaseWithinDb", p.phaseWithinDb, PhaseWithinRange)
  of avCorrelation:
    check("maxLagMs", p.maxLagMs, LagMsRange)
  of avFk:
    check("fkFromMs", p.fkFromMs, TimeMsRange, none = true)
    check("fkToMs", p.fkToMs, TimeMsRange, none = true)
    check("floorDb", p.floorDb, FloorDbRange)
  of avVibrator:
    check("reactionMassKg", p.reactionMassKg, MassKgRange, none = true)
    check("baseplateMassKg", p.baseplateMassKg, MassKgRange, none = true)
    check("harmonics", float64(p.harmonics), HarmonicRange)
    for name, v in fieldPairs(p.limits):
      check(name, v, NumberRange, none = true)
  ""

const
  MinFkTraces* = 4       ## an f-k needs at least these many traces
  MaxAnalysisCurves* = 8 ## traces a curve view draws at most (the first ones)

func isEmpty*(img: AnalysisImage): bool {.inline.} = img.cols == 0 or img.rows == 0

func valueAt*(img: AnalysisImage; col, row: int): float32 {.inline.} =
  ## The value at column `col` and row `row`.
  img.values[col * img.rows + row]

# ------------------------------------------------------------ orientation --

const NoOrientation* = "These traces carry no orientation header."
  ## said by a node orientation plot of traces none of which has one

proc orientationOf*(angles: openArray[array[3, float64]]): AnalysisResult =
  ## Roll, pitch and azimuth, degrees, against the traces in the order given
  ## (x = 1, 2, ...): `angles[i]` is trace `i`'s, NaN for each angle of a
  ## trace with no orientation header (a gap in the lines, never a zero).
  result = AnalysisResult(view: avOrientation, used: angles.len)
  var any = false
  var plot = AnalysisPlot(title: "Node orientation", xLabel: "Trace in the plot",
    yLabel: "Angle (degrees)", yUnit: "deg")
  for name in ["roll", "pitch", "azimuth"]:
    plot.curves.add AnalysisCurve(name: name, style: csLine)
  for i, a in angles:
    plot.xs.add float64(i + 1)
    for c in 0 .. 2:
      plot.curves[c].ys.add a[c]
      if not a[c].isNaN: any = true
  if not any:
    result.problem = NoOrientation
    return
  var missing = 0
  for a in angles:
    if a[0].isNaN and a[1].isNaN and a[2].isNaN: inc missing
  result.plots = @[plot]
  result.note = "Roll about X (inline), pitch about Y (crossline), azimuth about Z (down), " &
    "from each trace's orientation header; one point per trace as shown" &
    (if missing > 0: "; " & $missing & " without one (a gap)" else: "")

# ------------------------------------------------------------ spectrogram --

proc spectrogramOf*(rows: openArray[seq[float32]]; dtMs, t0Ms: float64;
    p: AnalysisParams; stop: StopCheck = nil): AnalysisResult =
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
  var work: seq[float32] = @[]
  for r in rows:
    if stop.stopped:
      result.cancelled = true
      return
    # each trace's mean removed first, as the FFT window does: a direct current
    # offset is not the brightest row
    var mean = 0.0
    for v in r: mean += float64(v)
    if r.len > 0: mean /= float64(r.len)
    work.setLen r.len
    for i, v in r: work[i] = float32(float64(v) - mean)
    sg.spectrogramInto(work, amp, ws)
    for k in 0 ..< amp.len: power[k] += amp[k] * amp[k]
  for k in 0 ..< power.len: power[k] = sqrt(power[k] / float64(rows.len))
  var db = newSeq[float64](power.len)
  let floor = min(p.floorDb, -1)
  var img = AnalysisImage(cols: sg.frames, rows: sg.bins, x0: t0Ms, dx: float64(hop) * dtMs,
    y0: 0, dy: sg.binHz(1), xLabel: "Time (ms)", xUnit: "ms", yLabel: "Frequency (Hz)",
    yUnit: "Hz", unit: "dB", lo: float32(floor), hi: 0)
  img.values = newSeq[float32](power.len)
  toDbInto(power, db, dbPeak, floor)
  for k in 0 ..< power.len: img.values[k] = float32(db[k])
  result.image = img
  result.note = $windowLen & "-sample frames (" & $(float64(windowLen) * dtMs) &
      " ms, Hann) every " &
    $hop & " samples; each trace's mean removed; dB from the largest amplitude" &
    (if rows.len > 1: "; the power average of " & $rows.len & " traces" else: "")

# --------------------------------------------------------------- envelope --

const EnvelopeFloorDb* = -60.0
  ## the envelope plot draws a phase, a difference of phases and a frequency only
  ## where the envelope is within this of its peak

proc paddedTo(x: openArray[float32]; n: int): seq[float32] =
  ## `x` as `n` samples: the shorter side zero-padded, as a correlation does.
  result = newSeq[float32](n)
  for i in 0 ..< min(x.len, n): result[i] = x[i]

proc envelopeOf*(x: openArray[float32]; name: string; dtMs, t0Ms: float64;
    p = AnalysisParams(); reference: openArray[float32] = []; referenceName = "";
    notUsed = ""; haveReference = false): AnalysisResult =
  ## The trace `x`, its envelope, its instantaneous phase (degrees) and its
  ## instantaneous frequency (Hz), against time: three plots.
  ##
  ## With a `reference` (and `p.phaseAgainst` `paReference`) the phase plot is
  ## the instantaneous phase difference, trace minus reference, in degrees
  ## wrapped to -180 to 180 (`wrapDeg`: the argument of the trace's analytic
  ## signal times the reference's conjugate), where both envelopes are within
  ## `EnvelopeFloorDb` of their peaks; its mean and its largest magnitude are
  ## in the plot's `aside` and the note. The frequency plot keeps the trace's
  ## own, with the reference's dim beside it. The shorter of the two is
  ## zero-padded to the longer. Otherwise the trace's own phase, as ever.
  ## `notUsed` says why a reference given to the window was not used;
  ## `haveReference` that the window has one, which the own-phase help names.
  result = AnalysisResult(view: avEnvelope, dtMs: dtMs, used: 1)
  if x.len < 2:
    result.problem = "the trace has no samples"
    return
  if not (dtMs > 0 and dtMs < Inf):
    result.problem = "the sample interval is not known"
    return
  let against = reference.len >= 2 and p.phaseAgainst == paReference
  let n = if against: max(x.len, reference.len) else: x.len
  var hp: HilbertPlan[float32]
  try:
    hp = initHilbertPlan(float32, n)
  except ValueError as e:
    result.problem = e.msg
    return
  var ws = initWorkspace()
  ws.reserve(hp.workspaceSize)
  let trace = if n == x.len: @x else: x.paddedTo(n)
  var env, phase, freq = newSeq[float64](n)
  hp.analyticInto(trace, dtMs, env, phase, freq, ws, EnvelopeFloorDb)
  var times = newSeq[float64](n)
  var signal = newSeq[float64](n)
  for i in 0 ..< n:
    times[i] = t0Ms + float64(i) * dtMs
    signal[i] = float64(trace[i])
  var phasePlot = AnalysisPlot(title: "Instantaneous phase of the trace", xLabel: "Time (ms)",
    xUnit: "ms", yLabel: "Phase (°)", yUnit: "°", xs: times,
    curves: @[AnalysisCurve(name: "phase", ys: phase)])
  var freqPlot = AnalysisPlot(title: "Instantaneous frequency", xLabel: "Time (ms)",
    xUnit: "ms", yLabel: "Frequency (Hz)", yUnit: "Hz", xs: times,
    curves: @[AnalysisCurve(name: "frequency", ys: freq)])
  result.note = "The analytic signal's modulus (envelope) and argument (phase), the " &
    "phase's step per sample (frequency); no frequency where the envelope is 60 dB " &
    "below its peak"
  if against:
    let ref32 = reference.paddedTo(n)
    var renv, rphase, rfreq = newSeq[float64](n)
    hp.analyticInto(ref32, dtMs, renv, rphase, rfreq, ws, EnvelopeFloorDb)
    var peak, refPeak = 0.0
    for i in 0 ..< n:
      peak = max(peak, env[i])
      refPeak = max(refPeak, renv[i])
    let floor = pow(10.0, EnvelopeFloorDb / 20.0)
    var diff = newSeq[float64](n)
    var worst = 0.0
    var drawn = 0
    # past the end of the shorter one is padding, not signal
    let both = min(x.len, reference.len)
    for i in 0 ..< n:
      diff[i] = NaN
      let loud = env[i] > 0 and renv[i] > 0 and env[i] >= peak * floor and
        renv[i] >= refPeak * floor
      if i < both and loud and not phase[i].isNaN and not rphase[i].isNaN:
        diff[i] = wrapDeg(phase[i] - rphase[i])
        worst = max(worst, abs(diff[i]))
        inc drawn
    # Absolute: the sizes, the signed value in brackets; Signed: around the circular mean,
    # so a reversed trace is flat at 180
    let shown = shownPhase(diff, p.phaseShow)
    let centre = shown.centre
    worst = 0.0
    for d in shown.signed:
      if not d.isNaN: worst = max(worst, abs(d))
    # the axis fits what is drawn, at least ±10° (of the centre), 0 in view for the sizes
    var lo, hi = centre
    for d in shown.ys:
      if not d.isNaN:
        lo = min(lo, d)
        hi = max(hi, d)
    let pad = max(2.0, (hi - lo) / 20)
    let (floorAt, ceilAt) = if p.phaseShow == psSigned: (centre - 180, centre + 180)
                            else: (0.0, 185.0) # sizes: a half turn is not on the border
    phasePlot = AnalysisPlot(title: "Phase against the reference", xLabel: "Time (ms)",
      xUnit: "ms", yLabel: "Phase difference (°)", yUnit: "°", xs: times,
      yLo: max(floorAt, min(lo - pad, centre - 10)),
      yHi: min(ceilAt, max(hi + pad, centre + 10)),
      curves: @[AnalysisCurve(name: "trace minus reference", ys: shown.ys,
      brackets: (if p.phaseShow == psAbsolute: shown.signed else: @[]))])
    freqPlot.curves.add AnalysisCurve(name: "reference frequency", ys: rfreq,
      style: csReference)
    var words = "no time where both envelopes are within 60 dB of their peaks"
    if drawn > 0:
      words = meanText(diff, p.phaseShow) & ", largest " &
        formatFloat(worst, ffDecimal, 1) & "°"
      phasePlot.aside = "Phase against the reference over the part drawn: " & words
    result.warning = shortWords("trace", float64(x.len) * dtMs, float64(reference.len) * dtMs)
    let early = endWords("", x, dtMs, signalEndMs(reference, dtMs))
    if early.len > 0: result.warning.add (if result.warning.len > 0: "\n" else: "") & early
    result.note = "Phase against " & referenceName & ": the trace's instantaneous phase " &
      "minus the reference's (the argument of the trace's analytic signal times the " &
      "reference's conjugate), wrapped to a turn, drawn where both envelopes are within " &
      "60 dB of their peaks, shown " & PhaseShowWords[p.phaseShow] & ": " & words & ". " &
      result.note
    # the shorter signal's padding is not drawn: the plots end with the trace
    for plot in [addr phasePlot, addr freqPlot]:
      plot[].xs.setLen x.len
      for cv in plot[].curves.mitems: cv.ys.setLen x.len
  else:
    result.note = "This turns once per cycle; " & (if haveReference or reference.len >= 2:
      "choose \"Against the reference\" to compare" else: "choose a reference to compare") &
      ". " & result.note
  if notUsed.len > 0 and p.phaseAgainst == paReference:
    result.note = "The reference was not used: " & notUsed & ". " & result.note
  if against:
    times.setLen x.len
    signal.setLen x.len
    env.setLen x.len
  result.plots = @[
    AnalysisPlot(title: "Amplitude", xLabel: "Time (ms)", xUnit: "ms", yLabel: "Amplitude",
      xs: times, curves: @[AnalysisCurve(name: name, ys: signal),
      AnalysisCurve(name: "envelope", ys: env)]),
    phasePlot, freqPlot]

# ---------------------------------------------------------- phase spectrum --

func unwrapWhere*(phaseDeg: openArray[float64]; shown: openArray[bool]): seq[float64] =
  ## `phaseDeg` (per bin, -180 to 180) unwrapped along the bins that are
  ## `shown` (`unwrapPhase`): a jump of more than half a turn from the last
  ## drawn bin is a whole turn the other way, and a gap is not crossed.
  unwrapPhase(phaseDeg, shown)

const PhasePadding* = 4
  ## the phase spectrum's transform is this many times the trace's length
  ## (zero-padded): between bins `1/(PhasePadding·T)` apart the phase of
  ## energy arriving at `t` steps `360°·t/(PhasePadding·T)`, at most a
  ## quarter turn for `t` within the trace (length `T`), so the unwrap
  ## cannot alias. Unpadded it does past `t = T/2`: a sweep's phase, which
  ## falls all the way, turned and rose from there.

proc phaseOf*(x: openArray[float32]; name: string; dtMs: float64;
    p: AnalysisParams): AnalysisResult =
  ## The amplitude (dB from its peak) and the phase (degrees, from the
  ## trace's first sample) of the whole trace against frequency, the trace
  ## zero-padded to `PhasePadding` times its length; the phase where the
  ## amplitude is within `p.phaseWithinDb` of the peak only, drawn as
  ## `p.phasePicture` asks.
  result = AnalysisResult(view: avPhase, dtMs: dtMs, used: 1)
  if x.len < 2:
    result.problem = "the trace has no samples"
    return
  var sp: SpectrumPlan[float32]
  try:
    sp = initSpectrumPlan(float32, dtMs, x.len, taperFraction = 0.0,
      nfft = nextFastLen(PhasePadding * x.len), demean = true)
  except ValueError as e:
    result.problem = e.msg
    return
  var ws = initWorkspace()
  ws.reserve(sp.workspaceSize)
  var amp, ph = newSeq[float32](sp.bins)
  sp.amplitudeInto(x, amp, ph, ws)
  var hz, db, deg, ampHz = newSeq[float64](sp.bins)
  var shown = newSeq[bool](sp.bins)
  let within = abs(p.phaseWithinDb)
  for k in 0 ..< sp.bins: ampHz[k] = float64(amp[k])
  toDbInto(ampHz, db, dbPeak, -Inf)
  for k in 0 ..< sp.bins:
    hz[k] = sp.binHz(k)
    shown[k] = db[k] >= -within
    deg[k] = radToDeg(float64(ph[k]))
  let drawn = drawnPhase(deg, shown, hz, p.phasePicture)
  var phaseCurve = AnalysisCurve(name: name, ys: drawn.ys)
  if p.phasePicture != ppSigned: phaseCurve.brackets = drawn.signed
  var phasePlot = AnalysisPlot(title: "Phase", xLabel: "Frequency (Hz)", xUnit: "Hz",
    yLabel: "Phase (°)", yUnit: "°", xs: hz, curves: @[phaseCurve])
  if p.phasePicture == ppMagnitude:
    (phasePlot.yLo, phasePlot.yHi) = (0.0, 180.0)
  if p.phasePicture == ppDelayRemoved: phasePlot.aside = delayWords(drawn.delayMs)
  result.plots = @[
    AnalysisPlot(title: "Amplitude", xLabel: "Frequency (Hz)", xUnit: "Hz",
      yLabel: "Amplitude (dB)", yUnit: "dB", xs: hz,
      curves: @[AnalysisCurve(name: name, ys: db)]),
    phasePlot]
  let picture = case p.phasePicture
    of ppMagnitude: "as its absolute value (0 to 180 degrees), "
    of ppSigned: "within -180 to 180 degrees, "
    of ppUnwrapped: "unwrapped along frequency, "
    of ppDelayRemoved: "unwrapped, with its best straight line (a pure time delay) taken off, "
  result.note = "Phase from the trace's first sample (the trace's mean removed, then " &
    "zero-padded to " & $PhasePadding & " times its length), " & picture &
    "where the amplitude is within " & $within & " dB of its peak. " & PhaseHelp
  if phasePlot.aside.len > 0: result.note.add " " & phasePlot.aside & "."

# ------------------------------------------------------- cross-correlation --

const CorrelationHelp* =
  "A peak near 1 at 0 ms means the trace has the reference's shape and timing. A lower " &
  "peak means a different shape; a peak away from 0 means a time shift."
  ## said under the correlation's title: the match is the correlation divided by
  ## `√(Σtrace²·Σreference²)` (processSEG's `cnCoefficient`), so it is 1 for the
  ## reference's shape whatever the amplitude, and -1 for its mirror image

func shiftWords(m: Match): string =
  ## What a time shift of the trace against the reference says in words: in step
  ## when it reads 0.0 ms.
  if m.inStep: "in step with the reference"
  else: "arrives " & m.shiftSize & (if m.shiftMs > 0: " after" else: " before") &
    " the reference"

func movedEarlier(x: openArray[float32]; samples: int): seq[float32] =
  ## `x` moved `samples` earlier (later when negative), zeros where nothing comes.
  result = newSeq[float32](x.len)
  for j in 0 ..< x.len:
    let at = j + samples
    if at >= 0 and at < x.len: result[j] = x[at]

func sameSamples(a, b: openArray[float32]): bool =
  ## Whether the two are the same signal, sample for sample.
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i] != b[i]: return false
  true

func meanOf(x: openArray[float64]): float64 =
  ## The mean of the finite values; NaN for none.
  var sum = 0.0
  var n = 0
  for v in x:
    if not v.isNaN:
      sum += v
      inc n
  if n == 0: NaN else: sum / float64(n)

proc correlationOf*(signals: openArray[(string, seq[float32])]; reference: seq[float32];
    referenceName: string; dtMs: float64; p: AnalysisParams;
    stop: StopCheck = nil): AnalysisResult =
  ## Each of `signals` against `reference`: how well it matches, from -1 to 1
  ## (the correlation divided by `√(Σsignal²·Σreference²)`: 1 for the
  ## reference's shape whatever the amplitude), and its envelope, against the
  ## time shift (a signal that is the reference delayed by τ peaks at +τ), and
  ## per frequency the amplitude ratio (dB) and phase difference (degrees) of
  ## each signal to the reference, where the reference's amplitude is within
  ## `p.phaseWithinDb` of its peak.
  ##
  ## The match is the envelope's peak (the shape's match whatever the constant
  ## phase turn of the signal), its time shift that peak's place, found between
  ## samples by a parabola through the peak and its two neighbours. The phase
  ## turn is the argument of the correlation's analytic signal at the peak
  ## (90° for a signal that is the reference's Hilbert transform; 180° is a
  ## mirror image). A peak under `NoClearMatch` is no clear match (no shift is
  ## said); a peak at an end of the lags shown is no peak at all (the shift is
  ## past them). The phase difference per frequency, and the table's mean of it,
  ## are taken after the found shift is removed (a whole number of samples by
  ## moving the signal, the rest as a linear phase term), so a delay is not read as a
  ## phase error; a signal with no clear match or no peak is not shifted. The note says,
  ## per signal, all this in words; a signal that is the reference itself is
  ## said so and drawn only when no other trace is; `table` has a row per
  ## signal: the match, the time shift, the amplitude and phase means inside
  ## the reference's band, and the phase turn.
  result = AnalysisResult(view: avCorrelation, dtMs: dtMs, used: signals.len)
  var samples = reference.len
  for (_, s) in signals: samples = max(samples, s.len)
  if signals.len == 0 or reference.len < 2 or samples < 2:
    result.problem = "no signal, or no reference with samples"
    return
  var cp, cpw: CrossCorrelationPlan[float32]
  try:
    let lag = clamp(p.maxLagMs, dtMs, float64(samples - 1) * dtMs)
    cp = initCrossCorrelationPlan(float32, lag, dtMs, samples)
    # the phase turn is read from the correlation over every lag: its analytic signal
    # is the same wherever the lags shown end
    cpw = initCrossCorrelationPlan(float32, float64(samples - 1) * dtMs, dtMs, samples)
  except ValueError as e:
    result.problem = e.msg
    return
  var ws = initWorkspace()
  ws.reserve(cp.workspaceSize)
  var wsw = initWorkspace()
  wsw.reserve(cpw.workspaceSize)
  var lagsMs = newSeq[float64](cp.lags)
  for i in 0 ..< cp.lags: lagsMs[i] = cp.lagMs(i)
  let shownMs = max(abs(lagsMs[0]), abs(lagsMs[^1]))
  var hz = newSeq[float64](cp.bins)
  for k in 0 ..< cp.bins: hz[k] = cp.binHz(k)
  var lagPlot = AnalysisPlot(title: "How well each trace matches " & referenceName &
    ", by time shift", xLabel: "Time shift (ms)", xUnit: "ms",
    yLabel: "Match, 1 = identical shape", xs: lagsMs)
  var ratioPlot = AnalysisPlot(title: "Amplitude compared with the reference, by frequency",
    xLabel: "Frequency (Hz)", xUnit: "Hz", yLabel: "Amplitude ratio (dB)", yUnit: "dB", xs: hz)
  var phasePlot = AnalysisPlot(title: "Phase compared with the reference, by frequency",
    xLabel: "Frequency (Hz)", xUnit: "Hz", yLabel: "Phase difference (°)", yUnit: "°", xs: hz)
  var c, e = newSeq[float32](cp.lags)
  var cw = newSeq[float32](cpw.lags)
  var ratio, phase, phaseMoved, ratioMoved = newSeq[float64](cp.bins)
  var lines: seq[string] = @[]
  # the reference's own trace is drawn only when it is all there is to draw
  var others = false
  for (_, s) in signals:
    if not sameSamples(s, reference): others = true
  result.table = @[@["Trace", "Best match", "Shift (ms)", "Amplitude (dB)",
    (if p.phaseShow == psAbsolute: "Mean |phase| (°)" else: "Phase, circular mean (°)"),
    "Rotation (°)"]]
  # Where the reference has its energy: its own spectrum (of its
  # autocorrelation's lag window) within `phaseWithinDb` of its peak;
  # elsewhere the ratio and the phase are noise.
  var refAmp, refPhase = newSeq[float64](cp.bins)
  cp.crossCorrelateInto(reference, reference, c, ws)
  cp.lagSpectrumInto(c, refAmp, refPhase, ws)
  var refDb = newSeq[float64](cp.bins)
  toDbInto(refAmp, refDb, dbPeak, -Inf)
  var inBand = newSeq[bool](cp.bins)
  for k in 0 ..< cp.bins: inBand[k] = refDb[k] >= -abs(p.phaseWithinDb)
  let refEnd = signalEndMs(reference, dtMs)
  let refLength = float64(reference.len) * dtMs
  var anyShifted = false
  var anyUnshifted = false
  for (name, s) in signals:
    if stop.stopped:
      result.cancelled = true
      return
    if sameSamples(s, reference):
      lines.add name & " is the reference: compared with itself it matches exactly " &
        "(1.00 at 0 ms)"
      if others:
        result.table.add @[name & " (the reference)", "1.00", "0.0", "not drawn", "not drawn",
          "0"]
        continue
    cp.crossCorrelateInto(s, reference, c, e, ws)
    var cs, es = newSeq[float64](cp.lags)
    var best = -1 # the envelope's peak: the time shift, as `peakLagMs` says it
    for i in 0 ..< cp.lags:
      (cs[i], es[i]) = (float64(c[i]), float64(e[i]))
      if not es[i].isNaN and not cs[i].isNaN and (best < 0 or es[i] > es[best]): best = i
    lagPlot.curves.add AnalysisCurve(name: name, ys: cs)
    lagPlot.curves.add AnalysisCurve(name: name & " envelope", ys: es)
    # the verdict: no peak (at an end of the lags), no clear match, or a match
    var m = matchOf(es, lagsMs)
    if m.verdict == mvClear:
      # the correlation's phase there, between the two samples round the peak
      cpw.crossCorrelateInto(s, reference, cw, wsw)
      m.rotationDeg = rotationOf(cw, dtMs, best - (cp.lags - 1) div 2 + (cpw.lags - 1) div 2,
        (m.shiftMs - lagsMs[best]) / dtMs)
    if not sameSamples(s, reference):
      let who = if signals.len > 1: name else: "trace"
      var said = shortWords(who, float64(s.len) * dtMs, refLength)
      # a trace arriving by the found shift is not early: its end is the reference's plus it
      let early = endWords((if signals.len > 1: name else: ""), s, dtMs, refEnd,
        (if m.verdict == mvClear: m.shiftMs else: 0.0))
      if early.len > 0: said.add (if said.len > 0: "\n" else: "") & early
      if said.len > 0:
        result.warning.add (if result.warning.len > 0: "\n" else: "") & said
    result.matches.add m
    let (match, shift, rotation) = (m.match, m.shiftMs, m.rotationDeg)
    let noPeak = m.verdict == mvNoPeak
    let clear = m.verdict == mvClear
    cp.compareInto(s, reference, ratio, phase, ws)
    if clear:
      # the phase with the shift taken off: whole samples by moving the signal, the rest
      # as a linear phase term (a delay of τ turns the phase by -360·f·τ)
      let whole = int(round(shift / dtMs))
      var left = shift - float64(whole) * dtMs
      if whole != 0:
        cp.compareInto(s.movedEarlier(whole), reference, ratioMoved, phaseMoved, ws)
        phase = phaseMoved
      for k in 0 ..< cp.bins:
        if not phase[k].isNaN: phase[k] = wrapDeg(phase[k] + 360 * hz[k] * left / 1000)
      anyShifted = true
    else:
      anyUnshifted = true
    for k in 0 ..< cp.bins:
      if not inBand[k]: (ratio[k], phase[k]) = (NaN, NaN)
      elif noPeak: phase[k] = NaN # the shift is past the lags: no phase to claim
    ratioPlot.curves.add AnalysisCurve(name: name, ys: ratio)
    let shownDiff = shownPhase(phase, p.phaseShow)
    phasePlot.curves.add AnalysisCurve(name: name, ys: shownDiff.ys,
      brackets: (if p.phaseShow == psAbsolute: shownDiff.signed else: @[]))
    let meanRatio = ratio.meanOf
    let meanPhase = meanOfPhase(phase, p.phaseShow)
    var row = @[name, "-", "-", "-", "-", "-"]
    if best >= 0:
      lines.add name & ": " & verdictWords(m, shownMs, shiftWords(m))
      if not noPeak: row[1] = twoDecimals(match)
      if clear:
        let turn = rotationWords(rotation)
        if turn == "reversed polarity": row[1].add " (" & turn & ")"
        row[2] = m.shiftText
        row[5] = rotationCell(rotation)
    if not meanRatio.isNaN: row[3] = signedMs(meanRatio)
    if not meanPhase.isNaN:
      row[4] = if p.phaseShow == psAbsolute: formatFloat(meanPhase, ffDecimal, 1)
               else: signedMs(meanPhase)
      if row[4] == "-180.0": row[4] = "180.0" # a mirror image is 180, whichever side it fell
    result.table.add row
  result.plots = @[lagPlot, ratioPlot, phasePlot]
  let phaseAfter =
    if anyShifted and anyUnshifted:
      "phase after removing each trace's found time shift (a trace with no clear match or " &
        "no peak is not shifted)"
    elif anyShifted: "phase after removing the time shift found for each trace"
    elif anyUnshifted: "phase measured unshifted (no trace has a clear match and a peak)"
    else: ""
  result.note = CorrelationHelp & "\nTime shifts shown: ±" & formatFloat(shownMs, ffDecimal, 1) &
    " ms (whole samples of " & formatFloat(dtMs, ffDecimal, 1) & " ms).\nPhase plot: " &
    PhaseShowWords[p.phaseShow] & (if phaseAfter.len > 0: "; " & phaseAfter else: "") & ".\n" &
    lines.join("\n")

func peakLagMs*(r: AnalysisResult; curve = 0): float64 =
  ## A correlation's time shift (ms) of curve `curve`, as the window words it (between samples,
  ## to the whole millisecond when it says "about"); NaN for none: no clear match, or no peak
  ## within the lags (`verdictOf` says which).
  result = NaN
  if r.view == avCorrelation and curve in 0 ..< r.matches.len:
    result = r.matches[curve].shownShiftMs

func verdictOf*(r: AnalysisResult; curve = 0): string =
  ## "match" (a clear one), "no clear match", "no peak" (it is past the lags) or "" for none.
  result = ""
  if r.view == avCorrelation and curve in 0 ..< r.matches.len:
    case r.matches[curve].verdict
    of mvClear: result = "match"
    of mvWeak: result = "no clear match"
    of mvNoPeak: result = "no peak"
    of mvNothing: discard

# ---------------------------------------------------------------- windows --

type
  AnalysisWindow* = object
    ## An analysis window (New plot): a view of traces of a plot's file,
    ## opened on the plot's selection or the trace under the pointer. Not
    ## frozen, it follows that plot: the selection, or what the view shows
    ## of the record with none, and the record, the sort, the kills and the
    ## filters. Frozen, it keeps the traces and the file it had.
    id*: int ## from 1, as `state`'s `plots` lists them
    view*: AnalysisView
    params*: AnalysisParams
    frozen*: bool ## keeps the traces and the file it had when frozen
    panel*: PanelId ## the plot it is of
    file*: string ## its file's name
    record*: string ## the record's FFID, or its place in the file
    traces*: seq[int] ## survey-wide ids, in the order drawn
    first*: int ## the first one's index in its file
    reference*: string ## a correlation's reference, in words
    archiveSeen*: string ## the chosen reference it was asked with; "" for none
    archiveRev*: int = -1 ## the archive's revision then
    fileRef*: bool
      ## its record has a trace with the vibrator reference code (21), found when the
      ## window asked (a correlation's, an envelope's): the button is offered
    pilotKey*: string
      ## a correlation against a pilot of the record: its trace and what changes it
      ## (reversal, a kill, its own filter) when it was asked; "" for none
    processing*: Processing ## the plot's filters when it asked last
    filters*: string ## them in words; "" for none
    killed*: seq[int] ## its traces killed when it asked last (indices in the file)
    editsSeen*: int ## its file's edits' revision then
    ownKey*: string ## the own filters of its traces when it asked last
    own*: seq[FilterEntry] ## those filters, kept while the window is frozen
    reversed*: seq[int]
      ## file indices effectively reversed when it asked last, ascending, kept
      ## while frozen
    allReversed*: bool
      ## reverse-all was on when it asked last, kept while frozen
    goneNote*: string
      ## set when the window's reference was deleted: one sentence, the name
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
    pickSession*: int = -1 ## the plot's file when the traces were last chosen
    pickGather*: int = -1 ## and the record
    pickSelected*: int = -1 ## the selection's revision then
    pickOrder*: uint64 ## the plot's sort generation then
    pickSource*: uint64 ## the record's generation then
    pickShown*: int = -1 ## how many traces the plot had laid out then

const MaxAnalysisWindows* = 32 ## analysis windows open at once, at most

func viewName*(v: AnalysisView): string =
  ## A view's name as the menus say it: "Spectrogram".
  case v
  of avSpectrogram: "Spectrogram"
  of avEnvelope: "Envelope and instantaneous phase"
  of avPhase: "Phase spectrum"
  of avCorrelation: "Cross-correlation"
  of avVibrator: "Vibrator signature"
  of avFk: "f-k"
  of avOrientation: "Node orientation"

func ownLine*(w: AnalysisWindow): string =
  ## What the window says of its traces' own filters, in the place it names
  ## them: "Trace 12: own filter, band-pass 10-60 Hz", or how many. "" for none.
  if w.traces.len == 0: return ""
  let base = w.traces[0] - w.first
  var own = newSeq[OwnFilter](w.traces.len)
  for i, t in w.traces:
    let at = entryAt(w.own, t - base)
    if at >= 0: own[i] = w.own[at].filter
  ownShownWords(w.first, own)

func reverseLine*(w: AnalysisWindow): string =
  ## What the window says of its traces' reversal, in the place it names an
  ## own filter: "Trace 12: reversed", or how many; "All traces are reversed"
  ## when reverse-all is on and every trace it shows is. "" for none.
  if w.traces.len == 0: return ""
  let base = w.traces[0] - w.first
  var on = newSeq[bool](w.traces.len)
  for i, t in w.traces:
    let fileTrace = t - base
    for r in w.reversed:
      if r == fileTrace: on[i] = true
  reverseShownWords(w.first, on, w.allReversed)

func label*(w: AnalysisWindow): string =
  ## What a window is of, in words: "trace 12 · FFID 151 · shot.sgd".
  if w.traces.len == 0:
    if w.file.len > 0: return "nothing · " & w.file
    return "nothing"
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
