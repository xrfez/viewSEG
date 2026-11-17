## A reference archive: named traces kept so a plot that needs a pilot can
## use one the file does not hold, or another than the file's.
##
## One archive is a folder of one-trace SEG-Y files (IEEE float, the sample
## interval in the trace header, the name in the textual header) and an
## index document, `index.nif`, in the format of the program's other
## documents. The folder is the project's `references` when a project is
## open, and the program's own (beside the file memory) otherwise. This
## module holds the document and the files. It reads and writes them, so
## a caller on the UI thread does not call the procs that do: a job does
## (`core/referencejobs`). What a dialog shows of an open file's index
## (`indexedSpan`) is already in memory.

import std/[math, os, strutils, times]
import parseSEG
import processSEG/fft/spectrum
import processSEG/vibroseis/[sweep, taper]
import processSEG/core/workspace
import filesystem, nif, threads, wiggle

const
  ReferencesFolder* = "references"
  ReferenceIndexName* = "index.nif"
  ReferenceVersion* = 1
  MaxReferenceName* = 120
  PerUserLockName* = "files.lock"
    ## the lock the other per-user documents use, beside their folder

export taper

type
  ReferenceLaw* = enum
    ## A sweep processSEG can make, as the Generate dialog offers it. A
    ## table sweep is not here: it needs a list of points, not two
    ## frequencies.
    rlLinear = "linear"
    rlExponential = "exponential"
    rlDbPerOctave = "dB/octave"
    rlDbPerHz = "dB/Hz"

  ReferenceOrigin* = object
    ## Where a reference's samples came from.
    case generated*: bool
    of false:
      fileName*: string ## the seismic file's name, not its path
      record*: float64  ## the record number; NaN when the headers name none
      trace*: int       ## the trace, from 1, as the plot names it
      fromMs*, toMs*: float64
      pilot*: bool
        ## a rule, not samples: each record's own trace by `pilotAux`, `trace`
        ## (N from 1), `fromMs` and `spanMs`; there is no file and no sample
      pilotAux*: bool ## `pilot`: auxiliary trace N of the record; else trace N of it
      spanMs*: float64 ## `pilot`: the window's length
    of true:
      law*: ReferenceLaw
      f1Hz*, f2Hz*: float64
      durationMs*, dtMs*: float64
      taperStartMs*, taperEndMs*: float64
      taperShape*: TaperShape = tpCos2
        ## the ramp's shape; an older archive leaves it out and gets cosine
        ## squared, which is what `initSweepTaper` uses
      taperParam*: float64 = NaN
        ## Kaiser beta, Gaussian sigma or the power exponent; NaN is the
        ## shape's default, and is not written (a document has no NaN)
      phaseDeg*: float64
        ## start phase in degrees; 0 starts at zero, and 180 reverses the polarity
      amplitude*: float64
      boostDb*: float64

  ReferenceEntry* = object
    ## One reference, as the index holds it. `missing` is not written: it
    ## is set when the SEG-Y file is not in the folder.
    id*: string
    name*: string
    intervalUs*: float64
    samples*: int
    origin*: ReferenceOrigin
    date*: string ## when it was stored, UTC, `yyyy-MM-ddTHH:mm:ssZ`
    file*: string ## its SEG-Y file's name in the folder
    missing*: bool
    blocked*: bool
      ## `file` is not a single name in the folder: the entry is said and
      ## never deleted, renamed, opened or copied through
    later*: seq[NifNode]

  ReferenceIndex* = object
    ## The archive's index. `problems` says what could not be used;
    ## `damaged` means the file was not a document (it is left as it was
    ## until a write moves it aside); `newer` means a later viewSEG wrote
    ## it (it is not overwritten).
    version*: int
    entries*: seq[ReferenceEntry]
    problems*: seq[string]
    damaged*: bool
    newer*: bool
    later*: seq[NifNode]

  StoredReference* = object
    ## What `store reference` names: a trace, a window of it, a name.
    name*: string
    trace*: int      ## a survey-wide trace id
    fromMs*: float64 ## the window's start; 0 the trace's start
    toMs*: float64   ## its end; below 0: the trace's end

  GeneratedReference* = object
    ## What `generate reference` names. `dtMs` 0: the file on show.
    ## `amplitude` 0: 1.
    name*: string
    law*: ReferenceLaw
    f1Hz*, f2Hz*: float64
    durationMs*, dtMs*: float64
    taperStartMs*, taperEndMs*: float64
    taperShape*: TaperShape = tpCos2
      ## the ramp's shape; left out, cosine squared (`initSweepTaper`)
    taperParam*: float64 = NaN
      ## Kaiser beta, Gaussian sigma or the power exponent; NaN: the shape's default
    phaseDeg*: float64
      ## start phase in degrees (`SweepSpec.startPhaseDeg`); 180 reverses the polarity
    amplitude*: float64
    boostDb*: float64

  PilotRule* = object
    ## What a pilot taken from the record names: which trace of the record
    ## on show (an auxiliary one, or a numbered one), and the window cut from
    ## it. Stored as a rule: each record's own trace is used when this is
    ## the chosen reference.
    name*: string
    aux*: bool ## auxiliary trace N of the record; else trace N of the record
    trace*: int ## N, from 1
    startMs*: float64
    spanMs*: float64 ## more than 0

  RefAct* = enum
    raListed = "listed"
    raStored = "stored"
    raGenerated = "generated"
    raRenamed = "renamed"
    raDeleted = "deleted"
    raCopied = "copied"
    raViewed = "viewed"
    raPilotShown = "pilot shown"
    raRuleStored = "rule stored"
    raFailed = "failed"

  RefView* = object
    ## A window showing one reference: its samples against time, and its
    ## amplitude spectrum. Not a follow window: it shows that reference
    ## until it is closed.
    id*: int
    refId*: string
    name*: string
    gone*: bool
    note*: string
    waiting*: bool
    fromMs*: float64
    dtMs*: float64
    ys*: seq[float64]
    hz*: seq[float64]
    amps*: seq[float64]
    revision*: int
    record*: string ## a pilot of the record: the record it shows
    pilot*: PilotRule ## a pilot of the record: the rule (`pilot.trace` 0: not one)
    pilotTrace*: int ## a pilot of the record: the survey-wide trace id; -1 for none
    pilotTraceMs*: float64 ## ... the length of that whole trace, in ms
    pilotNote*: string ## ... what the plot's filters did to it, in words
    pilotFrom*, pilotTo*: float64 ## a pilot of the record: the window, in ms

  PilotPreview* = object
    ## The pilot the Generate dialog shows for the record on screen: what a
    ## rule would take, as a job read it. `key` is the ask it answers.
    key*: string
    record*: string ## the record it is from; "" when none
    waiting*: bool
    problem*: string ## why there is none; "" when there is one
    samples*: seq[float32]
    dtMs*: float64
    hz*, db*: seq[float64]
    note*: string ## what the plot's filters did to it, in words
    gen*: int ## bumps when the picture changes

  ReferenceNews* = object
    ## What a reference job posts.
    home*: string                 ## the archive folder it acted on
    main*: bool                   ## the program's own archive, listed beside a project's
    index*: ReferenceIndex
    act*: RefAct
    failure*: string
    id*: string
    name*: string
    window*: int                  ## raViewed: the window it is for
    record*: string               ## a pilot of the record: which record it is from
    pilotTrace*: int              ## ... its survey-wide trace id; -1 when there is none
    pilotFrom*, pilotTo*: float64 ## ... the window cut, in ms
    pilotTraceMs*: float64        ## ... the length of the whole trace, in ms
    note*: string                 ## a pilot of the record: what the plot's filters did to it
    key*: string                  ## raPilotShown: the ask it answers
    fromMs*: float64
    dtMs*: float64
    ys*: seq[float64]
    hz*: seq[float64]
    amps*: seq[float64]

func referencesFolder*(home: string): string {.inline.} =
  ## The archive folder of a config folder or a project folder.
  home / ReferencesFolder

func indexPath*(folder: string): string {.inline.} =
  ## The index document of an archive folder.
  folder / ReferenceIndexName

func segyPath*(folder, file: string): string {.inline.} =
  folder / file

func findId*(index: ReferenceIndex; id: string): int =
  ## The entry named `id`, or -1.
  result = -1
  for i, e in index.entries:
    if e.id == id: return i

func findName*(index: ReferenceIndex; name: string): int =
  ## The entry whose name is `name`, or -1. Names are compared as given.
  result = -1
  for i, e in index.entries:
    if e.name == name: return i

func lawTitle*(law: ReferenceLaw): string =
  ## The sweep type as a name starts: "Linear", "dB/octave".
  case law
  of rlLinear: "Linear"
  of rlExponential: "Exponential"
  of rlDbPerOctave: "dB/octave"
  of rlDbPerHz: "dB/Hz"

func plainFieldFormat*(v: float64): string =
  ## The printf format a Generate field shows `v` with: a plain decimal,
  ## never scientific notation.
  if v.isNaN or v.classify in {fcInf, fcNegInf} or abs(v) >= 1e15: return "%.6f"
  let a = abs(v)
  if a == 0 or abs(v - round(v)) <= 1e-9 * max(1.0, a): return "%.0f"
  for d in 1 .. 6:
    let scale = pow(10.0, float64(d))
    if abs(v * scale - round(v * scale)) <= 1e-4 * max(1.0, a):
      return "%." & $d & "f"
  "%.6f"

func plainFieldText*(v: float64): string =
  ## `v` as a Generate field shows it: a plain number ("60000", "0.5",
  ## "-10"), never scientific notation.
  if v.isNaN: return "nan"
  if v.classify == fcInf: return "inf"
  if v.classify == fcNegInf: return "-inf"
  let fmt = plainFieldFormat(v)
  var prec = 6
  if fmt.len > 3 and fmt[0] == '%' and fmt[^1] == 'f':
    try: prec = parseInt(fmt[2 ..< fmt.high])
    except ValueError: discard
  result = formatFloat(v, ffDecimal, prec)
  if result.endsWith('.'): result.setLen result.len - 1

func numberText(x: float64): string =
  ## `x` without a trailing fraction when it is a whole number.
  if x.isNaN: "none"
  elif abs(x - round(x)) < 1e-6 * max(1.0, abs(x)) and abs(x) < 1e9:
    $int(round(x))
  else:
    var s = formatFloat(x, ffDecimal, 3)
    while s.len > 1 and s[^1] == '0': s.setLen s.len - 1
    if s[^1] == '.': s.setLen s.len - 1
    s

func msWords*(ms: float64): string {.inline.} =
  ## A sample interval in the sentence a plot says when it refuses one.
  numberText(ms)

func intervalRefusal*(refMs, fileMs: float64): string =
  ## What a plot says instead of drawing, when the reference's sample
  ## interval is not the file's. Nothing is resampled.
  "the reference is " & msWords(refMs) & " ms, this file is " & msWords(fileMs) & " ms"

const NoReferenceChosen* = "No reference is chosen. Choose one in References."
  ## A cross-correlation with no reference selected in References.

const NoneChoiceLabel* = "None"
  ## The References control that selects no reference.

const NoneChoiceTip* =
  "Vibrator plots then use the file's own pilot. A correlation needs a chosen reference."
  ## What that control says: vibrator plots use the file's pilot; a correlation does not.

func referenceGone*(name: string): string =
  ## A cross-correlation whose chosen reference is not in the archive.
  "The reference \"" & name & "\" is no longer in the archive."

func lengthRule*(refLen, traceLen: int): string =
  ## How a plot uses a reference whose length is not the trace's: the same
  ## rule as a file's own pilot (the longer side sets the length, the
  ## shorter is zero-padded; a longer reference is not cut). "" when they
  ## match.
  if refLen > traceLen:
    "the reference is longer than the trace and is not cut (the same rule as a " &
      "file's own pilot: the shorter side is zero-padded)"
  elif refLen < traceLen:
    "the reference is shorter than the trace: it is zero-padded (the same rule " &
      "as a file's own pilot)"
  else:
    ""

func defaultGenerateName*(g: GeneratedReference): string =
  ## "Linear 8-80 Hz 8 s", from the parameters.
  lawTitle(g.law) & " " & numberText(g.f1Hz) & "-" & numberText(g.f2Hz) & " Hz " &
    numberText(g.durationMs / 1000) & " s"

func pilotWords*(aux: bool; trace: int): string =
  ## Which trace a pilot of the record takes, as the dialog says it.
  if aux: "auxiliary trace " & $trace else: "trace " & $trace & " of the record"

func defaultPilotName*(r: PilotRule): string =
  ## "Pilot: aux 1, 0-12000 ms", from the rule.
  "Pilot: " & (if r.aux: "aux " else: "trace ") & $r.trace & ", " & numberText(r.startMs) &
    "-" & numberText(r.startMs + r.spanMs) & " ms"

func pilotProblem*(r: PilotRule): string =
  ## Why `r` names no pilot; "" when it does (the name is judged apart).
  if r.trace < 1: "a trace is numbered from 1"
  elif r.startMs.isNaN or r.startMs < 0 or r.startMs == Inf:
    "the start is 0 ms or later"
  elif not (r.spanMs > 0 and r.spanMs < Inf): "the length must be more than 0 ms"
  else: ""

func pilotRuleOf*(e: ReferenceEntry): PilotRule =
  ## The rule a pilot entry stores.
  PilotRule(name: e.name, aux: e.origin.pilotAux, trace: e.origin.trace,
    startMs: e.origin.fromMs, spanMs: e.origin.spanMs)

func isPilot*(e: ReferenceEntry): bool {.inline.} =
  ## A pilot taken from the record: a rule with no samples and no file.
  not e.origin.generated and e.origin.pilot

func recordSentence*(record: string): string =
  ## The record's name as a sentence starts: "FFID 5", "Record 3".
  if record.len == 0: "The record" else: capitalizeAscii(record)

func pickPilotTrace*(r: PilotRule; isAux: openArray[bool]; record: string):
    tuple[at: int; problem: string] =
  ## Which trace of a record `r` takes. `isAux` says, for each of the
  ## record's traces in file order, whether it is an auxiliary one. `at` is
  ## the index among them, -1 with a `problem` naming `record` when it has
  ## no such trace. No fallback to another trace.
  result.at = -1
  if r.trace < 1:
    result.problem = pilotProblem(r)
    return
  if r.aux:
    var seen = 0
    for i, a in isAux:
      if a:
        inc seen
        if seen == r.trace:
          result.at = i
          return
    result.problem = recordSentence(record) & " has " & (
      if seen == 0: "no auxiliary trace"
      elif seen == 1: "only 1 auxiliary trace"
      else: "only " & $seen & " auxiliary traces") & ", not an auxiliary trace " & $r.trace & "."
  elif r.trace <= isAux.len:
    result.at = r.trace - 1
  else:
    result.problem = recordSentence(record) & " has " & $isAux.len & " trace" &
      (if isAux.len == 1: "" else: "s") & ", not a trace " & $r.trace & "."

func frequencyText*(e: ReferenceEntry): string =
  ## The frequency range, for a generated reference; "" for a stored trace.
  if e.origin.generated:
    numberText(e.origin.f1Hz) & "-" & numberText(e.origin.f2Hz) & " Hz"
  else:
    ""

func sourceText*(e: ReferenceEntry): string =
  ## Where the row's samples came from, in one line.
  if e.origin.generated:
    "generated, " & lawTitle(e.origin.law)
  elif e.origin.pilot:
    "pilot: " & pilotWords(e.origin.pilotAux, e.origin.trace)
  else:
    let rec = if e.origin.record.isNaN: "none" else: numberText(e.origin.record)
    e.origin.fileName & " rec " & rec & " tr " & $e.origin.trace

func lengthText*(e: ReferenceEntry): string =
  ## The length in time, and the sample count.
  if e.isPilot: return numberText(e.origin.spanMs) & " ms (of each record)"
  let ms = if e.intervalUs > 0 and e.samples > 0:
             float64(e.samples - 1) * e.intervalUs / 1000
           else:
             0.0
  numberText(ms) & " ms (" & $e.samples & ")"

func intervalText*(e: ReferenceEntry): string =
  if e.isPilot: return "the record's"
  if e.intervalUs > 0: numberText(e.intervalUs / 1000) & " ms" else: "none"

func singleFileName*(file: string): bool =
  ## A single file name inside the archive folder: no separator, no "..",
  ## not absolute. A name such as `../outside.sgy` is not one.
  if file.len == 0 or file == "." or file == "..": return false
  if isAbsolute(file): return false
  for c in file:
    if c in {'/', '\\', '\0'}: return false
  ".." notin file

func archiveLockPath*(folder: string): string =
  ## The lock the other per-user documents of this archive's home use.
  folder.parentDir / PerUserLockName

func generateSettingsKey*(g: GeneratedReference): string =
  ## The settings a preview is for, so a result is shown only when it is the
  ## latest ask. The name is not part of it.
  $g.law & " " & $g.f1Hz & " " & $g.f2Hz & " " & $g.durationMs & " " & $g.dtMs & " " &
    $g.taperStartMs & " " & $g.taperEndMs & " " & $g.taperShape & " " & $g.taperParam &
    " " & $g.amplitude & " " & $g.boostDb & " " & $g.phaseDeg

func sweepTooLong*(g: GeneratedReference): string =
  ## Why `g` is too long for processSEG, in plain words; "" when it is not.
  ## Checked before any sweep is made.
  if not (g.dtMs > 0 and g.dtMs < Inf): return ""
  if not (g.durationMs == g.durationMs): return ""
  let steps = g.durationMs / g.dtMs
  if steps > float64(high(int32)):
    "a sweep of " & numberText(g.durationMs) & " ms at " & numberText(g.dtMs) &
      " ms is over 2³¹ samples"
  else: ""

func previewGenerate*(g: GeneratedReference): GeneratedReference =
  ## The sweep a preview draws: the whole of `g`, so both tapers are in the
  ## picture. A dense sweep is drawn as a min/max envelope (`columnEnvelope`),
  ## not by dropping samples.
  g

func timeStart*(e: ReferenceEntry): float64 =
  ## The first sample's time, from the archive: a stored window's From, or
  ## 0 for a generated sweep.
  if e.origin.generated: 0.0
  elif e.origin.fromMs == e.origin.fromMs: e.origin.fromMs
  else: 0.0

proc amplitudeOf*(samples: openArray[float32]; dtMs: float64): tuple[hz, amp: seq[float64]]
    {.gcsafe.} =
  ## The amplitude spectrum of `samples`, from processSEG. Empty when there
  ## is nothing to transform.
  if samples.len < 2 or not (dtMs > 0 and dtMs < Inf): return
  let sp = initSpectrumPlan(float32, dtMs, samples.len)
  var ws = workspace.initWorkspace()
  ws.reserve(sp.workspaceSize)
  var amp = newSeq[float32](sp.bins)
  var phase = newSeq[float32](sp.bins)
  sp.amplitudeInto(samples, amp, phase, ws)
  result.hz = newSeq[float64](sp.bins)
  result.amp = newSeq[float64](sp.bins)
  for k in 0 ..< sp.bins:
    result.hz[k] = sp.binHz(k)
    result.amp[k] = float64(amp[k])

proc nameProblem*(index: ReferenceIndex; name: string): string =
  ## Why `name` cannot be a new reference's; "" when it can.
  let n = name.strip
  if n.len == 0: "a reference needs a name"
  elif n.len > MaxReferenceName: "a reference's name is at most " & $MaxReferenceName &
    " characters"
  elif index.findName(n) >= 0: "a reference named \"" & n & "\" is already in the archive"
  else: ""

func indexedSpan*(f: ptr SeismicFile; trace: int): tuple[samples: int; intervalUs,
    sweepMs: float64] =
  ## What the store dialog shows of trace `trace`, from the index already in
  ## memory: the sample count, the sample interval (0 when the keys were not
  ## read), and the SEG-Y binary header's sweep length in ms (0 when the
  ## headers do not give one). Touches no file.
  if f == nil or trace notin 0 ..< f[].index.entries.len: return
  result.samples = int(f[].index.entries[trace].numSamples)
  if trace < f[].index.keys.len: result.intervalUs = f[].index.keys[trace].intervalUs
  if f[].index.kind == skSegy and f[].index.segy.binary.sweepLength > 0:
    result.sweepMs = float64(f[].index.segy.binary.sweepLength)

proc cutSamples*(samples: openArray[float32]; intervalUs, fromMs, toMs: float64): seq[float32] =
  ## The samples whose time is in `fromMs` .. `toMs` (both ends kept when
  ## they fall on a sample). `toMs` below 0 keeps through the last sample.
  ## `intervalUs` must be positive; otherwise the samples are returned whole.
  if samples.len == 0: return
  if not (intervalUs > 0 and intervalUs < Inf):
    result = newSeq[float32](samples.len)
    for i, v in samples: result[i] = v
    return
  let dt = intervalUs / 1000
  let i0 = clamp(int(round(fromMs / dt)), 0, samples.len)
  let i1 = if toMs < 0: samples.len
           else: clamp(int(round(toMs / dt)) + 1, i0, samples.len)
  result = newSeq[float32](i1 - i0)
  for i in 0 ..< result.len: result[i] = samples[i0 + i]

proc cutPilot*(samples: openArray[float32]; dtMs: float64; r: PilotRule; record: string):
    tuple[samples: seq[float32]; problem: string] =
  ## The window of a pilot trace `r` names: from its start for its length (both
  ## ends kept when they fall on a sample), clipped to the trace's end. A start
  ## past the end, or nothing left, is a `problem` naming `record`; the samples
  ## are copied, not changed.
  let bad = pilotProblem(r)
  if bad.len > 0: return (@[], bad)
  let who = recordSentence(record) & "'s " & pilotWords(r.aux, r.trace)
  if samples.len == 0: return (@[], who & " has no sample.")
  if not (dtMs > 0 and dtMs < Inf): return (@[], who & " has no sample interval.")
  let lastMs = float64(samples.len - 1) * dtMs
  if r.startMs > lastMs + dtMs / 2:
    return (@[], who & " ends at " & numberText(lastMs) & " ms, so a window from " &
      numberText(r.startMs) & " ms is past its end.")
  # clamp before the sample arithmetic: a huge length is the trace's end
  let stopMs = min(r.startMs + r.spanMs, lastMs)
  result.samples = cutSamples(samples, dtMs * 1000, r.startMs, stopMs)
  if result.samples.len == 0:
    result.problem = who & " has no sample from " & numberText(r.startMs) & " ms."

func taperShapeTitle*(shape: TaperShape): string =
  ## The ramp shape as the Generate dialog names it.
  case shape
  of tpLinear: "Linear"
  of tpCosine: "Cosine"
  of tpCos2: "Cosine squared"
  of tpHamming: "Hamming"
  of tpBlackman: "Blackman"
  of tpBlackmanHarris: "Blackman-Harris"
  of tpKaiser: "Kaiser"
  of tpGaussian: "Gaussian"
  of tpPower: "Power"

func taperParamLabel*(shape: TaperShape): string =
  ## The extra field's name for a shape that has a parameter; "" for the rest.
  case shape
  of tpKaiser: "Beta"
  of tpGaussian: "Sigma"
  of tpPower: "Exponent"
  of tpLinear, tpCosine, tpCos2, tpHamming, tpBlackman, tpBlackmanHarris: ""

proc taperDefaultParam*(shape: TaperShape): float64 =
  ## processSEG's default parameter for `shape` (NaN when the shape has none).
  initSweepTaper(0.0, 0.0, shape).param

proc sweepSpec(g: GeneratedReference): SweepSpec =
  ## The processSEG sweep `g` names. Raises `ValueError` as `validate`.
  let amp = if g.amplitude > 0 and g.amplitude < Inf: g.amplitude else: 1.0
  let taper = initSweepTaper(g.taperStartMs, g.taperEndMs, g.taperShape, g.taperParam)
  let phase = g.phaseDeg
  case g.law
  of rlLinear:
    linearSweep(g.f1Hz, g.f2Hz, g.durationMs, g.dtMs, taper, startPhaseDeg = phase,
      amplitude = amp)
  of rlExponential:
    exponentialSweep(g.f1Hz, g.f2Hz, g.durationMs, g.dtMs, taper, startPhaseDeg = phase,
      amplitude = amp)
  of rlDbPerOctave:
    dbPerOctaveSweep(g.f1Hz, g.f2Hz, g.durationMs, g.dtMs, g.boostDb, taper,
      startPhaseDeg = phase, amplitude = amp)
  of rlDbPerHz:
    dbPerHzSweep(g.f1Hz, g.f2Hz, g.durationMs, g.dtMs, g.boostDb, taper,
      startPhaseDeg = phase, amplitude = amp)

proc plainGenerateMessage(msg: string): string =
  ## processSEG's refusal, with its field names as the dialog says them.
  result = msg
  result = result.replace("startPhaseDeg", "the phase")
  result = result.replace("f1Hz", "the start frequency")
  result = result.replace("f2Hz", "the end frequency")
  result = result.replace("lengthMs", "the length")
  result = result.replace("dtMs", "the sample interval")
  result = result.replace("boostDb", "the boost")
  result = result.replace("maxNyquistFraction", "the anti-alias fraction")

proc generateProblem*(g: GeneratedReference): string =
  ## Why `g` cannot be made, in processSEG's words; "" when it can. No
  ## samples are made.
  let tooLong = sweepTooLong(g)
  if tooLong.len > 0: return tooLong
  try:
    discard sweepSpec(g)
    ""
  except CatchableError as e:
    plainGenerateMessage(e.msg)

proc generateSamples*(g: GeneratedReference): seq[float32] {.gcsafe.} =
  ## The sweep `g` names, from processSEG. Raises `ValueError` as that
  ## library does (a frequency past the anti-alias limit, a length that is
  ## not a whole number of samples, tapers that overlap, a parameter or a
  ## phase it refuses). No file is read.
  sweepSpec(g).sweepSamples(float32)

proc columnEnvelope*(values: openArray[float32]; x0, dx: float64; columns: int):
    tuple[xs, ys: seq[float64]] =
  ## The whole series as a line that keeps every peak. Point `i` is at
  ## `x0 + i·dx`. At most `columns` points: every one of them. More: the
  ## minimum and maximum of each column (`minMaxInto`), in the order they
  ## occur, placed inside the column, and the true samples at the two ends.
  ## A later extreme is not moved to t=0 or t=end. Nothing is skipped.
  ## Empty when there is nothing to draw.
  if values.len == 0 or not (dx > 0 and dx < Inf): return
  let cols = max(columns, 1)
  if values.len <= cols:
    result.xs = newSeq[float64](values.len)
    result.ys = newSeq[float64](values.len)
    for i, v in values:
      result.xs[i] = x0 + float64(i) * dx
      result.ys[i] = float64(v)
    return
  let n = max(1, (values.len + cols - 1) div cols)
  let bins = (values.len + n - 1) div n
  var dst = newSeq[float32](bins * 2)
  minMaxInto(values, n, dst)
  let endX = x0 + float64(values.len - 1) * dx
  result.xs = newSeq[float64](dst.len + 2)
  result.ys = newSeq[float64](dst.len + 2)
  result.xs[0] = x0
  result.ys[0] = float64(values[0])
  for b in 0 ..< bins:
    let i0 = b * n
    let i1 = min(values.len - 1, i0 + n - 1)
    let xA = x0 + float64(i0) * dx
    let span = max(x0 + float64(i1) * dx - xA, dx)
    var a = xA + span * 0.25
    var c = xA + span * 0.75
    if a <= x0: a = x0 + dx * 0.25
    if c >= endX: c = endX - dx * 0.25
    if c <= a: c = a + dx * 0.25
    result.xs[1 + b * 2] = a
    result.xs[2 + b * 2] = c
    result.ys[1 + b * 2] = float64(dst[b * 2])
    result.ys[2 + b * 2] = float64(dst[b * 2 + 1])
  result.xs[^1] = endX
  result.ys[^1] = float64(values[^1])
  for i in 1 ..< result.xs.high:
    if result.xs[i] <= result.xs[i - 1]:
      result.xs[i] = result.xs[i - 1] + dx * 0.01
  if result.xs[^1] <= result.xs[^2]:
    result.xs[^2] = result.xs[^1] - dx * 0.25

type SignalBand* = object
  ## A signal prepared for the pixel columns of a plot (`signalBand`).
  exact*: bool
    ## the true samples (one value each: `lo` equals `hi`), because the range
    ## holds about one sample per column or fewer; else the extremes per column
  xs*: seq[float64] ## each column's first sample time (an exact band: each sample's)
  lo*, hi*: seq[float64] ## each column's smallest and largest sample

proc signalBand*(values: openArray[float32]; x0, dx, xLo, xHi: float64; columns: int):
    SignalBand =
  ## The samples of `values` (sample `i` at `x0 + i·dx`) from `xLo` to `xHi`
  ## (one sample beyond each end, so a line enters the view) for a plot
  ## `columns` pixels wide. At most `columns` samples: every one, `exact`.
  ## More: the smallest and largest sample of each column (`minMaxInto`), so
  ## no sample is skipped, and the last point repeats the final column at the
  ## last sample's time. Empty when there is nothing in range.
  if values.len == 0 or not (dx > 0 and dx < Inf) or xLo.isNaN or xHi.isNaN: return
  let cols = max(columns, 1)
  let first = clamp(int(floor((min(xLo, xHi) - x0) / dx)) - 1, 0, values.high)
  let last = clamp(int(ceil((max(xLo, xHi) - x0) / dx)) + 1, 0, values.high)
  if last < first: return
  let m = last - first + 1
  if m <= cols:
    result.exact = true
    result.xs = newSeq[float64](m)
    result.lo = newSeq[float64](m)
    result.hi = newSeq[float64](m)
    for i in 0 ..< m:
      result.xs[i] = x0 + float64(first + i) * dx
      result.lo[i] = float64(values[first + i])
      result.hi[i] = result.lo[i]
    return
  let step = (m + cols - 1) div cols
  let bins = (m + step - 1) div step
  var dst = newSeq[float32](bins * 2)
  minMaxInto(values.toOpenArray(first, last), step, dst)
  result.xs = newSeq[float64](bins + 1)
  result.lo = newSeq[float64](bins + 1)
  result.hi = newSeq[float64](bins + 1)
  for b in 0 ..< bins:
    result.xs[b] = x0 + float64(first + b * step) * dx
    result.lo[b] = float64(min(dst[b * 2], dst[b * 2 + 1]))
    result.hi[b] = float64(max(dst[b * 2], dst[b * 2 + 1]))
  result.xs[bins] = x0 + float64(last) * dx
  result.lo[bins] = result.lo[bins - 1]
  result.hi[bins] = result.hi[bins - 1]

func spectrumAxis*(f1, f2, nyquist: float64): tuple[lo, hi: float64] =
  ## The spectrum plot's frequency axis for a sweep from `f1` to `f2`: the
  ## band plus a quarter of it on each side, held within 0 .. Nyquist. A
  ## band of no width is a short span about that frequency, so the axis is
  ## not a point. A Nyquist that is not a positive number is not a clamp.
  if f1.isNaN or f2.isNaN:
    return (lo: 0.0, hi: (if nyquist > 0 and nyquist < Inf: nyquist else: 1.0))
  let loF = min(f1, f2)
  let hiF = max(f1, f2)
  let band = hiF - loF
  let margin = 0.25 * band
  result.lo = loF - margin
  result.hi = hiF + margin
  if result.lo < 0: result.lo = 0
  if nyquist > 0 and nyquist < Inf:
    if result.lo > nyquist: result.lo = nyquist
    if result.hi > nyquist: result.hi = nyquist
  if result.hi <= result.lo:
    let pad = max(band, 1.0)
    result.lo = max(0.0, loF - pad)
    result.hi = loF + pad
    if nyquist > 0 and nyquist < Inf and result.hi > nyquist: result.hi = nyquist
    if result.hi <= result.lo: result.hi = result.lo + 1

func spectrumFitKey*(gen: int; f1, f2, nyquist: float64): string =
  ## Changes when the frequencies change, so the spectrum plot fits again.
  let axis = spectrumAxis(f1, f2, nyquist)
  "s" & $gen & " " & $axis.lo & " " & $axis.hi

proc previewSpectrum*(samples: openArray[float32]; dtMs: float64):
    tuple[hz, db: seq[float64]] {.gcsafe.} =
  ## The amplitude spectrum of `samples` in dB, peak at 0, from the same
  ## processSEG call a stored reference's window uses (`amplitudeOf`), then
  ## `toDbInto`. Empty when there is nothing to transform.
  let spec = amplitudeOf(samples, dtMs)
  result.hz = spec.hz
  result.db = newSeq[float64](spec.amp.len)
  if spec.amp.len > 0:
    toDbInto(spec.amp, result.db)

proc buildGeneratePreview*(g: GeneratedReference): tuple[samples: seq[float32];
    hz, db: seq[float64]; problem: string] {.gcsafe.} =
  ## The whole sweep `g` names and its amplitude spectrum in dB, or
  ## processSEG's reason it cannot be made (then no samples).
  result.samples = @[]
  result.hz = @[]
  result.db = @[]
  result.problem = generateProblem(g)
  if result.problem.len > 0: return
  result.samples = generateSamples(g)
  let spec = previewSpectrum(result.samples, g.dtMs)
  result.hz = spec.hz
  result.db = spec.db

# ----------------------------------------------------------------- document --

proc nowText(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc newId(index: ReferenceIndex): string =
  let base = "r" & $getTime().toUnix
  var n = index.entries.len + 1
  result = base & "-" & $n
  while index.findId(result) >= 0:
    inc n
    result = base & "-" & $n

proc value(w: var NifWriter; tag, s: string) =
  w.open tag
  w.add s
  w.close

proc value(w: var NifWriter; tag: string; x: float64) =
  w.open tag
  w.add x
  w.close

proc value(w: var NifWriter; tag: string; i: int64) =
  w.open tag
  w.add i
  w.close

proc value(w: var NifWriter; tag: string; i: int) =
  w.open tag
  w.add int64(i)
  w.close

proc value(w: var NifWriter; tag: string; b: bool) =
  w.open tag
  w.add b
  w.close

proc writeOrigin(w: var NifWriter; o: ReferenceOrigin) =
  w.open "source"
  w.value("generated", o.generated)
  if o.generated:
    w.value("law", $o.law)
    w.value("f1Hz", o.f1Hz)
    w.value("f2Hz", o.f2Hz)
    w.value("durationMs", o.durationMs)
    w.value("dtMs", o.dtMs)
    w.value("taperStartMs", o.taperStartMs)
    w.value("taperEndMs", o.taperEndMs)
    w.value("taperShape", $o.taperShape)
    if not o.taperParam.isNaN: w.value("taperParam", o.taperParam)
    w.value("phaseDeg", o.phaseDeg)
    w.value("amplitude", o.amplitude)
    w.value("boostDb", o.boostDb)
  elif o.pilot:
    w.value("pilot", true)
    w.value("pilotAux", o.pilotAux)
    w.value("trace", o.trace)
    w.value("fromMs", o.fromMs)
    w.value("spanMs", o.spanMs)
  else:
    w.value("fileName", o.fileName)
    if not o.record.isNaN: w.value("record", o.record)
    w.value("trace", o.trace)
    w.value("fromMs", o.fromMs)
    w.value("toMs", o.toMs)
  w.close

proc writeEntry(w: var NifWriter; e: ReferenceEntry) =
  w.open "entry"
  w.value("id", e.id)
  w.value("name", e.name)
  w.value("intervalUs", e.intervalUs)
  w.value("samples", e.samples)
  w.value("date", e.date)
  w.value("file", e.file)
  w.writeOrigin e.origin
  for n in e.later: w.add n
  w.close

proc indexDocument(index: ReferenceIndex): string =
  var w = initNifWriter()
  w.open "references"
  w.value("version", int64(ReferenceVersion))
  for e in index.entries: w.writeEntry e
  for n in index.later: w.add n
  w.close
  w.finish

proc kidString(n: NifNode): string =
  if n.kids.len >= 1 and n.kids[0].kind == nkString: n.kids[0].text else: ""

proc kidNumber(n: NifNode): float64 =
  if n.kids.len >= 1:
    case n.kids[0].kind
    of nkFloat: n.kids[0].floatVal
    of nkInt: float64(n.kids[0].intVal)
    else: NaN
  else: NaN

proc kidInt(n: NifNode): int =
  if n.kids.len >= 1 and n.kids[0].kind == nkInt: int(n.kids[0].intVal) else: 0

proc kidBool(n: NifNode): bool =
  n.kids.len >= 1 and n.kids[0].kind == nkIdent and n.kids[0].text == "true"

proc readOrigin(n: NifNode; problems: var seq[string]): ReferenceOrigin =
  var generated = false
  var law = rlLinear
  var shape = tpCos2
  var f1, f2, durationMs, dt, t0, t1, amp, boost, record, fromMs, toMs, param = NaN
  var phase = 0.0
  var fileName = ""
  var trace = 0
  var pilot, pilotAux = false
  var spanMs = NaN
  var sawGenerated = false
  for c in n.kids:
    if c.kind != nkTree: continue
    case c.tag
    of "generated":
      generated = kidBool(c)
      sawGenerated = true
    of "law":
      let s = kidString(c)
      var found = false
      for v in ReferenceLaw:
        if $v == s:
          law = v
          found = true
      if not found and s.len > 0:
        problems.add "a sweep type \"" & s & "\" is not one this version makes: kept as linear"
    of "f1Hz": f1 = kidNumber(c)
    of "f2Hz": f2 = kidNumber(c)
    of "durationMs": durationMs = kidNumber(c)
    of "dtMs": dt = kidNumber(c)
    of "taperStartMs": t0 = kidNumber(c)
    of "taperEndMs": t1 = kidNumber(c)
    of "taperShape":
      let s = kidString(c)
      var found = false
      for v in TaperShape:
        if $v == s:
          shape = v
          found = true
      if not found and s.len > 0:
        problems.add "a taper shape \"" & s &
          "\" is not one this version makes: kept as cosine squared"
    of "taperParam": param = kidNumber(c)
    of "phaseDeg":
      let p = kidNumber(c)
      if p == p: phase = p
    of "amplitude": amp = kidNumber(c)
    of "boostDb": boost = kidNumber(c)
    of "fileName": fileName = kidString(c)
    of "record": record = kidNumber(c)
    of "trace": trace = kidInt(c)
    of "fromMs": fromMs = kidNumber(c)
    of "toMs": toMs = kidNumber(c)
    of "pilot": pilot = kidBool(c)
    of "pilotAux": pilotAux = kidBool(c)
    of "spanMs": spanMs = kidNumber(c)
    else: discard
  if not sawGenerated: generated = f1 == f1 # a frequency was given
  if generated:
    ReferenceOrigin(generated: true, law: law, f1Hz: f1, f2Hz: f2, durationMs: durationMs,
      dtMs: dt, taperStartMs: t0, taperEndMs: t1, taperShape: shape, taperParam: param,
      phaseDeg: phase,
      amplitude: (if amp == amp: amp else: 1.0), boostDb: (if boost == boost: boost else: 0.0))
  else:
    ReferenceOrigin(generated: false, fileName: fileName, record: record, trace: trace,
      fromMs: (if fromMs == fromMs: fromMs else: 0.0), toMs: toMs, pilot: pilot,
      pilotAux: pilotAux, spanMs: (if spanMs == spanMs: spanMs else: 0.0))

proc readEntry(n: NifNode; problems: var seq[string]): ReferenceEntry =
  for c in n.kids:
    if c.kind != nkTree:
      continue
    case c.tag
    of "id": result.id = kidString(c)
    of "name": result.name = kidString(c)
    of "intervalUs": result.intervalUs = kidNumber(c)
    of "samples": result.samples = kidInt(c)
    of "date": result.date = kidString(c)
    of "file": result.file = kidString(c)
    of "source": result.origin = readOrigin(c, problems)
    else: result.later.add c
  if result.id.len == 0 or result.name.len == 0:
    problems.add "an entry with no id or no name was left out"

proc readIndexDoc(text, name: string): ReferenceIndex =
  var doc: seq[NifNode]
  try:
    doc = parseNif(text, name)
  except NifError as e:
    return ReferenceIndex(damaged: true, problems: @[e.msg])
  var root = -1
  for i, n in doc:
    if n.kind == nkTree and n.tag.startsWith("."): discard
    elif root < 0 and n.isTree("references"): root = i
  if root < 0:
    return ReferenceIndex(damaged: true,
      problems: @[name & " holds no reference index"])
  result.version = ReferenceVersion
  for c in doc[root].kids:
    if c.kind != nkTree: continue
    case c.tag
    of "version":
      result.version = kidInt(c)
    of "entry":
      var problems: seq[string]
      let e = readEntry(c, problems)
      result.problems.add problems
      if e.id.len > 0 and e.name.len > 0: result.entries.add e
    else: result.later.add c
  if result.version > ReferenceVersion:
    result.newer = true
    result.problems.add name & " was written by a newer viewSEG (version " &
      $result.version & "): it is not changed"

proc markMissing(folder: string; index: var ReferenceIndex) =
  for e in index.entries.mitems:
    if e.isPilot:
      e.missing = false # a rule: it has no file
    elif not singleFileName(e.file):
      e.blocked = true
      e.missing = true
      index.problems.add "an entry's file \"" & e.file &
        "\" is not a file name in the archive: it was left"
    else:
      e.missing = not fs.fileExists(folder / e.file)

proc noteOrphans(folder: string; index: var ReferenceIndex) =
  ## SEG-Y files in the folder with no index entry, left where they are.
  if not fs.dirExists(folder): return
  var known: seq[string] = @[]
  for e in index.entries:
    if singleFileName(e.file): known.add e.file
  var n = 0
  try:
    for kind, path in fs.walkDir(folder):
      if kind == pcFile and path.extractFilename.endsWith(".sgy") and
          path.extractFilename notin known:
        inc n
  except OSError:
    return
  if n > 0:
    index.problems.add ($n & (if n == 1: " reference file is" else: " reference files are") &
      " not in the index")

proc loadIndex*(folder: string): ReferenceIndex {.gcsafe.} =
  ## The archive in `folder`. A missing folder is an empty archive. A
  ## document that is not one is `damaged` (the file is left as it was) and
  ## its problem is said; an entry that cannot be used is left out and said.
  ## A SEG-Y file that is not there marks its entry `missing`.
  assertWorkerThread()
  let path = indexPath(folder)
  if not fs.fileExists(path): return ReferenceIndex(version: ReferenceVersion)
  try:
    result = readIndexDoc(fs.readFile(path), path)
  except IOError as e:
    return ReferenceIndex(problems: @[path & " cannot be read: " & e.msg])
  markMissing(folder, result)
  noteOrphans(folder, result)

proc writeAtomic(path, text: string) =
  ## `text` written to `path`: a temporary file beside it, flushed, then
  ## renamed over it. A reader sees the old file or the new one.
  let tmp = path & "." & $getCurrentProcessId() & ".tmp"
  var f: File
  if not fs.open(f, tmp, fmWrite):
    raise newException(IOError, "cannot write " & tmp)
  try:
    if text.len > 0 and fs.writeBuffer(f, tmp, unsafeAddr text[0], text.len) != text.len:
      raise newException(IOError, "the disk did not take " & tmp)
    flushFile(f)
  finally:
    close(f)
  fs.moveFile(tmp, path)

proc writeIndex*(folder: string; index: ReferenceIndex) {.gcsafe.} =
  ## Writes `index` atomically. A damaged file already there is moved aside
  ## (`index.nif.damaged`) first, so a write does not destroy what could not
  ## be read. A newer version's file is left alone (`ValueError`).
  assertWorkerThread()
  if index.newer:
    raise newException(ValueError, "the reference index was written by a newer viewSEG: " &
      "it is not changed")
  fs.createDir(folder)
  let path = indexPath(folder)
  if fs.fileExists(path):
    var prior = ReferenceIndex()
    try:
      prior = readIndexDoc(fs.readFile(path), path)
    except IOError:
      prior.damaged = true
    if prior.damaged:
      let aside = path & ".damaged"
      if fs.fileExists(aside): discard fs.tryRemoveFile(aside)
      fs.moveFile(path, aside)
    elif prior.newer:
      raise newException(ValueError, "the reference index was written by a newer viewSEG: " &
        "it is not changed")
  writeAtomic(path, indexDocument(index))

proc writeReferenceFile*(path, name: string; intervalUs: float64; samples: openArray[float32];
    origin: ReferenceOrigin) {.gcsafe.} =
  ## One-trace IEEE-float SEG-Y at `path`: the name in the textual header,
  ## the sample interval in the trace header, a sweep's trace code. The
  ## writer's own close renames its temporary file over `path`.
  assertWorkerThread()
  var lines = @["viewSEG reference: " & name]
  if origin.generated:
    lines.add "generated " & lawTitle(origin.law) & " " & numberText(origin.f1Hz) & "-" &
      numberText(origin.f2Hz) & " Hz, " & numberText(origin.durationMs) & " ms, " &
      numberText(origin.dtMs) & " ms, " & taperShapeTitle(origin.taperShape) &
      " taper, phase " & numberText(origin.phaseDeg) & " deg"
  elif origin.fileName.len > 0:
    lines.add "stored from " & origin.fileName & ", trace " & $origin.trace &
      ", " & numberText(origin.fromMs) & " to " & numberText(origin.toMs) & " ms"
  var problems: seq[string] = @[]
  {.cast(gcsafe).}:
    var w = openSeismicWriter(path, SegyOutputOptions(text: lines))
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs) = (1.0, 1.0, 0.0, intervalUs)
    (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    w.writeTrace(k, samples)
    let said = w.close()
    for d in said: problems.add d.msg
  if problems.len > 0:
    raise newException(IOError, problems.join("; "))

proc copyRow[T](samples: T; row: int): seq[float32] =
  result = newSeq[float32](samples.shape[1])
  for i in 0 ..< result.len:
    result[i] = float32(samples[row, i])
    if not (abs(result[i]) < Inf): result[i] = 0

proc readReferenceFile*(path: string): tuple[samples: seq[float32];
    intervalUs: float64] {.gcsafe.} =
  ## The one trace of a reference's SEG-Y, and its sample interval. Raises
  ## `IOError` when the file cannot be read, and `ValueError` when it holds
  ## no trace.
  assertWorkerThread()
  if not fs.fileExists(path):
    raise newException(IOError, "the reference file is missing")
  var rows: seq[float32] = @[]
  var us = 0.0
  {.cast(gcsafe).}:
    var f = openSeismic(path, keys = true)
    if f.len < 1:
      f.close()
      raise newException(ValueError, "the reference file has no trace")
    us = f.sampleIntervalUs(0)
    fs.mappedRead(path)
    rows = copyRow(f.readTraces(0 .. 0), 0)
    f.close()
  clearCycleRoots()
  (rows, us)

proc readRawTrace*(file: ptr SeismicFile; path: string; trace: int): seq[float32] {.gcsafe.} =
  ## Trace `trace` of an open file, decoded, with no filter, gain or
  ## polarity. A sample that is not a number becomes 0, as the plot draws
  ## one. Empty when the trace cannot be decoded.
  assertWorkerThread()
  fs.mappedRead(path)
  {.cast(gcsafe).}:
    result = copyRow(file[].readTraces(trace .. trace), 0)
  clearCycleRoots()

proc addEntry(index: var ReferenceIndex; name: string; intervalUs: float64;
    samples: openArray[float32]; origin: ReferenceOrigin): ReferenceEntry =
  ## An entry for samples about to be written. Raises `ValueError` for a
  ## name already used or empty. Does not write.
  let problem = index.nameProblem(name)
  if problem.len > 0: raise newException(ValueError, problem)
  let id = newId(index)
  result = ReferenceEntry(id: id, name: name.strip, intervalUs: intervalUs,
    samples: samples.len, origin: origin, date: nowText(), file: id & ".sgy")

proc holdArchive(folder: string): FileLock {.gcsafe.} =
  ## The lock the other per-user documents use, so two writers of this
  ## archive do not drop each other's entry. The index is read again under it.
  let path = archiveLockPath(folder)
  try:
    fs.createDir(path.parentDir)
  except IOError, OSError:
    discard
  fs.lockFile(path, initDuration(seconds = 2))

proc readForChange(folder: string): ReferenceIndex {.gcsafe.} =
  ## The index, read again while the archive lock is held.
  loadIndex(folder)

proc storeSamples*(folder, name: string; intervalUs: float64; samples: openArray[float32];
    origin: ReferenceOrigin): string {.gcsafe.} =
  ## Writes a reference and returns its id. A name already used raises
  ## `ValueError` and writes nothing. The SEG-Y is written first, then the
  ## index, so a failure leaves no index entry for a file that is not there.
  ## The index is read again under the per-user lock, so another writer of
  ## this archive is not dropped.
  assertWorkerThread()
  var lock = holdArchive(folder)
  defer: fs.unlock(lock)
  var index = readForChange(folder)
  if index.newer:
    raise newException(ValueError, index.problems.join("; "))
  # A damaged index is moved aside by the save; what could be read is kept.
  index.damaged = false
  let e = addEntry(index, name, intervalUs, samples, origin)
  fs.createDir(folder)
  writeReferenceFile(folder / e.file, e.name, intervalUs, samples, origin)
  index.entries.add e
  writeIndex(folder, index)
  e.id

proc storePilotRule*(folder: string; r: PilotRule): string {.gcsafe.} =
  ## Stores the rule `r` names (no samples, no file) and returns its id. A
  ## name already used, or a rule that names no pilot, raises `ValueError`
  ## and writes nothing.
  assertWorkerThread()
  let bad = pilotProblem(r)
  if bad.len > 0: raise newException(ValueError, bad)
  var lock = holdArchive(folder)
  defer: fs.unlock(lock)
  var index = readForChange(folder)
  if index.newer:
    raise newException(ValueError, index.problems.join("; "))
  index.damaged = false
  let name = if r.name.strip.len > 0: r.name.strip else: defaultPilotName(r)
  let problem = index.nameProblem(name)
  if problem.len > 0: raise newException(ValueError, problem)
  let id = newId(index)
  index.entries.add ReferenceEntry(id: id, name: name, date: nowText(),
    origin: ReferenceOrigin(generated: false, pilot: true, pilotAux: r.aux, trace: r.trace,
    fromMs: r.startMs, spanMs: r.spanMs, record: NaN, toMs: r.startMs + r.spanMs))
  fs.createDir(folder)
  writeIndex(folder, index)
  id

proc refuseBlocked(e: ReferenceEntry; what: string) =
  if e.blocked:
    raise newException(ValueError, "the reference \"" & e.name &
      "\" names a file outside the archive: it was not " & what)

proc renameIn*(folder, id, name: string) {.gcsafe.} =
  ## Renames the reference `id`. A name already used, or no such reference,
  ## raises `ValueError`. The SEG-Y is written again so its textual header
  ## carries the new name. An entry whose file is not a name in the folder
  ## is left alone.
  assertWorkerThread()
  var lock = holdArchive(folder)
  defer: fs.unlock(lock)
  var index = readForChange(folder)
  if index.damaged or index.newer:
    raise newException(ValueError, index.problems.join("; "))
  let i = index.findId(id)
  if i < 0: raise newException(ValueError, "there is no reference \"" & id & "\"")
  refuseBlocked(index.entries[i], "renamed")
  let problem = index.nameProblem(name)
  if problem.len > 0 and index.findName(name.strip) != i:
    raise newException(ValueError, problem)
  if index.entries[i].isPilot:
    index.entries[i].name = name.strip
    writeIndex(folder, index)
    return
  if index.entries[i].missing:
    raise newException(ValueError, "the reference \"" & index.entries[i].name &
      "\" has no file: it cannot be renamed")
  let path = folder / index.entries[i].file
  let (samples, us) = readReferenceFile(path)
  index.entries[i].name = name.strip
  writeReferenceFile(path, name.strip, us, samples, index.entries[i].origin)
  writeIndex(folder, index)

proc deleteIn*(folder, id: string): string {.gcsafe.} =
  ## Removes the reference `id` and its SEG-Y. Returns its name. No such
  ## reference raises `ValueError`. An entry whose file is not a name in
  ## the folder is left alone, file and all.
  assertWorkerThread()
  var lock = holdArchive(folder)
  defer: fs.unlock(lock)
  var index = readForChange(folder)
  if index.damaged or index.newer:
    raise newException(ValueError, index.problems.join("; "))
  let i = index.findId(id)
  if i < 0: raise newException(ValueError, "there is no reference \"" & id & "\"")
  refuseBlocked(index.entries[i], "deleted")
  result = index.entries[i].name
  if singleFileName(index.entries[i].file):
    discard fs.tryRemoveFile(folder / index.entries[i].file)
  index.entries.delete i
  writeIndex(folder, index)

proc copyInto*(fromFolder, toFolder, id: string): string {.gcsafe.} =
  ## Copies reference `id` from one archive into the other (a new id, the
  ## same name and samples). Returns the new id. A name already in the
  ## destination raises `ValueError` and copies nothing.
  assertWorkerThread()
  let src = loadIndex(fromFolder)
  let i = src.findId(id)
  if i < 0:
    raise newException(ValueError, "there is no reference \"" & id & "\" in the main archive")
  if src.entries[i].isPilot:
    return storePilotRule(toFolder, pilotRuleOf(src.entries[i]))
  if src.entries[i].blocked:
    raise newException(ValueError, "the reference \"" & src.entries[i].name &
      "\" names a file outside the archive: it was not copied")
  if src.entries[i].missing:
    raise newException(ValueError, "the reference \"" & src.entries[i].name &
      "\" has no file: it was not copied")
  if not singleFileName(src.entries[i].file):
    raise newException(ValueError, "the reference \"" & src.entries[i].name &
      "\" names a file outside the archive: it was not copied")
  let (samples, us) = readReferenceFile(fromFolder / src.entries[i].file)
  storeSamples(toFolder, src.entries[i].name, us, samples, src.entries[i].origin)
