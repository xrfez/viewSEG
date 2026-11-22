## Operations > References: the archive window, Generate a reference, and
## Store as reference (the plot's menu). The windows issue commands; they
## do not read a file.

import std/[algorithm, math, strutils, tables]
import imguin/cimgui
import ../../core/[explain, references, state, viewport]
import ../../view/[curveplot, theme]
import curveplot as curves, explainmenu, fittext, focus, genpreview, icons, listkeys, marks,
  placement, style

type
  RefSort* = enum
    rsName, rsLength, rsInterval, rsFrequency, rsSource, rsDate

  ReferencesUi* = object
    shown*: bool
    bringUp: bool
    placeAgain: bool
    focus: FocusClicks
    sort: RefSort
    descending: bool
    renameId: string
    rename: string
    renameProblem: string
    confirmId: string
    confirmAsk: bool
    selected: string          ## the selected row's id: "" for none, `NoneRow` for the None row
    selMain: bool             ## the selection is in the project's main archive table
    scrollToSelected: bool
    renameFocus: bool
    mainOpen: bool            ## the Main archive header was open last frame
    confirmWasOpen: bool      ## the delete confirmation was showing last frame
    genAsk: bool
    genName: string
    genF1, genF2, genLength, genDt, genTaper0, genTaper1, genAmp, genBoost: float64
    genPhase: float64
    genParam: float64
    genLaw: ReferenceLaw
    genShape: TaperShape
    genMessage: string
    genFKind: RefFilterKind   ## the recording filter: every value typed, none by default
    genFFamily: RefFilterFamily
    genFByCoef: bool          ## minimum phase: typed coefficients rather than a family
    genFTaps, genFHigh, genFHighSlope, genFLow, genFLowSlope: float64
    genFHighOrder, genFLowOrder, genFRipple, genFShift: float64
    genFShiftTyped: bool
    genFCoef: string          ## the coefficients' text (a buffer)
    coefText: string          ## the text `coefTaps` was read from
    coefTaps: seq[float64]
    coefProblem: string
    previewDelay: float64     ## the filter's bulk delay in the preview (NaN: none)
    delayKey: string          ## the settings `previewDelay` was computed for
    failKey, failText: string ## settings whose preview failed, and why
    genSource: int            ## 0: the sweep settings; 1: a trace of the record
    autoName: string          ## the name the dialog filled in last (replaced while it is not edited)
    pilotAux: bool
    pilotN, pilotStart, pilotLength: float64
    pilotPhase: float64       ## 0 or 180 degrees
    pilotAsked: string        ## the pilot ask last sent
    pilotLive: string
    pilotStable: int
    pilotLengthFilled: bool   ## the whole trace was put in Length once; a later edit stands
    pilotGen: int             ## the preview's picture this dialog copied last
    fixed: StoreDialog        ## Store this pilot as a fixed reference, from a pilot's window
    previewSamples: seq[float32]
    previewHz, previewDb: seq[float64]
    previewDt, askedDt: float64
    previewF1, previewF2: float64
    previewKey: string        ## the settings the dialog is showing a key for
    askedKey: string          ## the settings last sent to the worker
    liveKey: string
    stable: int               ## frames the settings have stayed put
    askedGen, shownGen: int
    signalPlot, spectrumPlot: CurvePlotUi
    viewPlots: Table[int, tuple[time, spec: CurvePlotUi, ys: seq[float32], rev: int]]

  StoreDialog* = object
    ask: bool
    wasOpen: bool
    trace: int
    name: string
    fromMs, toMs: float64
    samples: int    ## the whole trace's sample count
    dtMs: float64   ## and its interval
    sweep: bool
    phase: float64  ## 0 or 180 degrees
    clamped: string ## said when a typed "To" was brought back to the last sample
    message: string

  ReferencesOutput* = object
    commands*: seq[Command]

const
  SourceSweep = "Sweep settings"
  SourceRecord = "A trace of the record"

proc setBuf(buf: var string; text: string) =
  if buf.len < 160: buf.setLen 160
  let n = min(text.len, 159)
  for i in 0 ..< n: buf[i] = text[i]
  buf[n] = '\0'

proc bufText(buf: string): string =
  if buf.len == 0: "" else: $cast[cstring](unsafeAddr buf[0])

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 32)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc open*(ui: var ReferencesUi) =
  ui.shown = true
  ui.bringUp = true

proc placeAgain*(ui: var ReferencesUi) =
  ui.placeAgain = true

proc openGenerate*(ui: var ReferencesUi; dtMs: float64) =
  ui.genAsk = true
  ui.genLaw = rlLinear
  ui.genShape = initSweepTaper(0.0, 0.0).shape
  ui.genF1 = 8
  ui.genF2 = 80
  ui.genLength = 8000
  ui.genDt = if dtMs > 0: dtMs else: 2
  ui.genTaper0 = 200
  ui.genTaper1 = 200
  ui.genAmp = 1
  ui.genBoost = 0
  ui.genPhase = 0
  ui.genParam = NaN
  ui.genMessage = ""
  ui.genFKind = rfNone
  ui.genFFamily = rfButterworth
  ui.genFByCoef = false
  (ui.genFTaps, ui.genFHigh, ui.genFHighSlope, ui.genFLow, ui.genFLowSlope) = (0.0, 0.0, 0.0, 0.0, 0.0)
  (ui.genFHighOrder, ui.genFLowOrder, ui.genFRipple, ui.genFShift) = (0.0, 0.0, 0.0, 0.0)
  ui.genFShiftTyped = false
  ui.coefText = ""
  ui.coefTaps = @[]
  ui.coefProblem = ""
  ui.previewDelay = NaN
  if ui.genFCoef.len > 0: ui.genFCoef[0] = '\0'
  ui.genSource = 0
  ui.pilotAux = true
  ui.pilotN = 1
  ui.pilotStart = 0
  ui.pilotLength = 0
  ui.pilotPhase = 0
  ui.pilotLengthFilled = false
  ui.pilotAsked = ""
  ui.pilotLive = ""
  ui.pilotStable = 0
  ui.pilotGen = -1
  ui.previewSamples.setLen 0
  ui.previewHz.setLen 0
  ui.previewDb.setLen 0
  ui.previewKey = ""
  ui.askedKey = ""
  ui.liveKey = ""
  ui.stable = 0
  ui.askedGen = 0
  ui.shownGen = 0
  ui.previewDt = 0
  ui.previewF1 = 0
  ui.previewF2 = 0
  let g = GeneratedReference(law: ui.genLaw, f1Hz: ui.genF1, f2Hz: ui.genF2,
    durationMs: ui.genLength, dtMs: ui.genDt, taperShape: ui.genShape)
  setBuf(ui.genName, defaultGenerateName(g))
  ui.autoName = defaultGenerateName(g)

proc openStore*(d: var StoreDialog; trace: int; name: string; fromMs, toMs: float64;
    samples: int; dtMs: float64; sweep: bool; phaseDeg = 0.0) =
  ## Asks for the dialog on trace `trace` of `samples` samples `dtMs` apart: the window is
  ## `fromMs` .. `toMs`, the times of the first and last sample taken.
  d.ask = true
  d.trace = trace
  setBuf(d.name, name)
  (d.fromMs, d.toMs, d.samples, d.dtMs, d.sweep) = (fromMs, toMs, samples, dtMs, sweep)
  d.phase = phaseDeg
  d.message = ""
  d.clamped = ""

proc number(label: string; v: var float64; mark: string; marks: var Marks): bool =
  igTextUnformatted(label.cstring, nil)
  igSameLine(igGetFontSize() * 12, -1)
  igSetNextItemWidth(igGetFontSize() * 8)
  let fmt = plainFieldFormat(v)
  result = igInputDouble(("##" & mark).cstring, addr v, 0, 0, fmt.cstring, 0)
  marks.mark(mark)

func whole(x: float64): int =
  ## A typed number as a whole one; 0 for a number that is not finite or is out of range.
  if x.isNaN: 0
  elif x >= float64(high(int32)): int(high(int32))
  elif x <= float64(low(int32)): int(low(int32))
  else: int(round(x))

func askedFilter(ui: ReferencesUi): RefFilter =
  if ui.genFKind == rfNone: return RefFilter()
  RefFilter(kind: ui.genFKind, taps: whole(ui.genFTaps), highCutHz: ui.genFHigh,
    highSlopeDb: ui.genFHighSlope, lowCutHz: ui.genFLow, lowSlopeDb: ui.genFLowSlope,
    coefficients: (if ui.genFByCoef: ui.coefTaps else: @[]),
    family: ui.genFFamily, highOrder: whole(ui.genFHighOrder), lowOrder: whole(ui.genFLowOrder),
    rippleDb: ui.genFRipple, shiftSamples: whole(ui.genFShift),
    shiftTyped: ui.genFShiftTyped or ui.genFKind == rfMinimum)

proc asked(ui: ReferencesUi): GeneratedReference =
  GeneratedReference(filter: ui.askedFilter, name: bufText(ui.genName), law: ui.genLaw,
      f1Hz: ui.genF1,
    f2Hz: ui.genF2, durationMs: ui.genLength, dtMs: ui.genDt, taperStartMs: ui.genTaper0,
    taperEndMs: ui.genTaper1, taperShape: ui.genShape, taperParam: ui.genParam,
    phaseDeg: ui.genPhase, amplitude: ui.genAmp, boostDb: ui.genBoost)

func pilotRule(ui: ReferencesUi): PilotRule =
  PilotRule(name: bufText(ui.genName), aux: ui.pilotAux,
    trace: (if ui.pilotN.isNaN or abs(ui.pilotN) > 1e9: 0 else: int(ui.pilotN)),
    startMs: ui.pilotStart, spanMs: ui.pilotLength, phaseDeg: ui.pilotPhase)

func settingsKey(g: GeneratedReference): string {.inline.} =
  generateSettingsKey(g)

proc pickShape(ui: var ReferencesUi; shape: TaperShape) =
  if shape == ui.genShape: return
  ui.genShape = shape
  ui.genParam = taperDefaultParam(shape)

proc combo(label, current, mark: string; marks: var Marks; flags = 0'i32): bool =
  igTextUnformatted(label.cstring, nil)
  igSameLine(igGetFontSize() * 12, -1)
  igSetNextItemWidth(igGetFontSize() * 12)
  result = igBeginCombo(("##" & mark).cstring, current.cstring, flags)
  marks.mark(mark)

const CoefBuffer = 400_000 ## room for 16 384 coefficients typed or pasted

func kindTitle(k: RefFilterKind): string =
  case k
  of rfNone: "None"
  of rfLinear: "Linear phase"
  of rfMinimum: "Minimum phase"

proc refreshCoefficients(ui: var ReferencesUi) =
  ## Reads the coefficients' text again when it changed.
  if ui.genFCoef.len < CoefBuffer: ui.genFCoef.setLen CoefBuffer
  if ui.genFKind == rfNone or not ui.genFByCoef: return
  let text = bufText(ui.genFCoef)
  if text == ui.coefText: return
  ui.coefText = text
  let r = parseCoefficients(text)
  ui.coefTaps = r.taps
  ui.coefProblem = r.problem

proc warningText(t: Theme; text, mark: string; marks: var Marks) =
  if text.len == 0: return
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
  igTextWrapped("%s", text.cstring)
  igPopStyleColor(1)
  marks.mark(mark)

proc drawCoefficients(ui: var ReferencesUi; t: Theme; marks: var Marks) =
  igTextUnformatted("Coefficients", nil)
  igSameLine(igGetFontSize() * 12, -1)
  discard igInputTextMultiline("##generate.filter.coef", cast[cstring](addr ui.genFCoef[0]),
    csize_t(ui.genFCoef.len), ImVec2_c(x: -1, y: igGetFontSize() * 6), 0, nil, nil)
  marks.mark("generate.filter.coef")
  tip("One number per line, or separated by spaces or commas; a line's text after # is a " &
    "comment. The filter is used as typed: its gain and delay are the coefficients'.")
  if ui.coefProblem.len > 0:
    warningText(t, ui.coefProblem, "generate.filter.coefproblem", marks)
  else:
    let words = $ui.coefTaps.len & " coefficients"
    igTextUnformatted(words.cstring, nil)
    marks.mark("generate.filter.coefcount:" & words)

proc drawFilter(ui: var ReferencesUi; t: Theme; marks: var Marks) =
  ## "Recording filter": the filter that backs a generated reference through the recorder's
  ## response, and the delay to back out. Every value is typed here; none by default.
  igSeparatorText("Recording filter")
  if combo("Filter", kindTitle(ui.genFKind), "generate.filter.kind", marks):
    for k in RefFilterKinds:
      if igSelectable_Bool(kindTitle(k).cstring, k == ui.genFKind, 0, ImVec2_c(x: 0, y: 0)):
        if k != ui.genFKind:
          # each kind's delay starts from its own: computed (linear) or 0 (minimum)
          ui.genFShift = 0
          ui.genFShiftTyped = false
          ui.previewDelay = NaN
        ui.genFKind = k
      marks.mark("generate.filter.kind " & $k)
    igEndCombo()
  tip("None leaves the sweep as it is. Linear phase and minimum phase pass the generated " &
    "sweep through the recorder's filter, then back out its delay by a bulk shift of whole " &
    "samples, so that the reference matches what the recorder wrote. Every value is typed " &
    "here: nothing is read from a file's headers. Only a generated reference is filtered: " &
    "one stored from a record already went through the recorder's filter.")
  if ui.genFKind == rfNone: return
  let f = ui.askedFilter
  let designLabel = if ui.genFKind == rfLinear: "Design" else: "Family"
  let how = if ui.genFByCoef: "Coefficients" else: designLabel
  if combo("Defined by", how, "generate.filter.by", marks):
    for (byCoef, label) in [(false, designLabel), (true, "Coefficients")]:
      if igSelectable_Bool(label.cstring, byCoef == ui.genFByCoef, 0, ImVec2_c(x: 0, y: 0)):
        ui.genFByCoef = byCoef
      marks.mark("generate.filter.by " & label)
    igEndCombo()
  tip("Type or paste the filter's coefficients (its taps), or give the filter by " &
    (if ui.genFKind == rfLinear: "its number of taps, cutoffs and slopes."
      else: "its type, order and cutoff (Butterworth or Chebyshev)."))
  if ui.genFByCoef:
    ui.drawCoefficients(t, marks)
    warningText(t, symmetryNote(f), "generate.filter.symmetry", marks)
  elif ui.genFKind == rfLinear:
    discard number("Number of taps", ui.genFTaps, "generate.filter.taps", marks)
    ui.genFTaps = round(ui.genFTaps)
    tip("The filter's length: an odd number (it delays by (taps - 1) / 2 samples, a whole " &
      "number). Up to 2047.")
    discard number("High-cut (Hz)", ui.genFHigh, "generate.filter.high", marks)
    discard number("High-cut slope (dB/oct)", ui.genFHighSlope, "generate.filter.highslope",
      marks)
    tip("The roll-off in dB per octave above the cutoff (the gain is -3 dB at the cutoff). " &
      "A filter of N taps cannot roll off faster than its length allows.")
    discard number("Low-cut (Hz)", ui.genFLow, "generate.filter.low", marks)
    discard number("Low-cut slope (dB/oct)", ui.genFLowSlope, "generate.filter.lowslope", marks)
    tip("0 Hz switches a cut off.")
    warningText(t, lowCutNote(f, ui.genDt), "generate.filter.lowcutnote", marks)
  else:
    if combo("Family", $ui.genFFamily, "generate.filter.family", marks):
      for fam in RefFilterFamily:
        if igSelectable_Bool(($fam).cstring, fam == ui.genFFamily, 0, ImVec2_c(x: 0, y: 0)):
          ui.genFFamily = fam
        marks.mark("generate.filter.family " & $fam)
      igEndCombo()
    discard number("High-cut (Hz)", ui.genFHigh, "generate.filter.high", marks)
    discard number("High-cut order", ui.genFHighOrder, "generate.filter.highorder", marks)
    ui.genFHighOrder = round(ui.genFHighOrder)
    tip("The number of poles; the roll-off is 6 dB per octave for each. Up to 32.")
    discard number("Low-cut (Hz)", ui.genFLow, "generate.filter.low", marks)
    discard number("Low-cut order", ui.genFLowOrder, "generate.filter.loworder", marks)
    ui.genFLowOrder = round(ui.genFLowOrder)
    tip("0 Hz switches a cut off.")
    if ui.genFFamily == rfChebyshev:
      discard number("Ripple (dB)", ui.genFRipple, "generate.filter.ripple", marks)
      tip("The passband ripple; the cutoff is where the gain leaves it. From 0.001 to 12 dB.")
  # the bulk delay
  if ui.genFKind == rfLinear:
    if not ui.genFShiftTyped: ui.genFShift = float64(effectiveShift(f))
    if number("Delay (samples)", ui.genFShift, "generate.filter.shift", marks):
      ui.genFShiftTyped = true
      ui.genFShift = round(ui.genFShift)
    tip("The delay to back out, in whole samples. It is floor((taps - 1) / 2) from the " &
      "number of taps, until you type another value.")
    if ui.genFShiftTyped:
      igSameLine(0, -1)
      if igButton("Use (taps - 1) / 2", ImVec2_c(x: 0, y: 0)): ui.genFShiftTyped = false
      marks.mark("generate.filter.shiftcalc")
    warningText(t, evenTapsNote(f), "generate.filter.even", marks)
  else:
    if number("Delay (samples)", ui.genFShift, "generate.filter.shift", marks):
      ui.genFShift = round(ui.genFShift)
    tip("The recorder's bulk delay, which it backs out by moving the data earlier by this " &
      "many whole samples. Type the recorder's number: a minimum-phase filter's delay " &
      "depends on frequency, so only the recorder's own shift matches its data.")
    # a suggestion belongs to the settings it was computed for: never show an older one
    if ui.previewDelay == ui.previewDelay and ui.delayKey == settingsKey(ui.asked):
      let words = "Suggested: " & $(if ui.previewDelay >= 0: int(floor(ui.previewDelay + 0.5))
        else: -int(floor(-ui.previewDelay + 0.5))) & " (" &
        formatFloat(ui.previewDelay, ffDecimal, 2) & " samples over " & plainFieldText(ui.genF1) &
        "-" & plainFieldText(ui.genF2) & " Hz)"
      igTextUnformatted(words.cstring, nil)
      marks.mark("generate.filter.suggested")
      igSameLine(0, -1)
      if igButton("Use it", ImVec2_c(x: 0, y: 0)):
        ui.genFShift = float64(if ui.previewDelay >= 0: int(floor(ui.previewDelay + 0.5))
          else: -int(floor(-ui.previewDelay + 0.5)))
      marks.mark("generate.filter.usesuggested")
      tip("A suggestion only, from the filter you typed (the least-squares delay over the " &
        "sweep's band). It is not used unless you press this or type it.")
  warningText(t, topWarning(f, max(ui.genF1, ui.genF2)), "generate.filter.top", marks)

proc drawPlots(ui: var ReferencesUi; t: Theme; plotH: float32; facts: ExplainFacts;
    marks: var Marks) =
  let ink = t.roles[rlAccent]
  let scale = max(1'f32, igGetIO_Nil().DisplayFramebufferScale.x)
  let cols = max(64, int(igGetContentRegionAvail().x * scale))
  let fit = $ui.shownGen
  if ui.previewSamples.len > 1 and ui.previewDt > 0:
    let env = columnEnvelope(ui.previewSamples, 0.0, ui.previewDt, cols)
    var time = CurvePlot(xLabel: "Time (ms)", xUnit: "ms", yLabel: "Amplitude",
      xs: env.xs, curves: @[Curve(name: "sweep", colour: ink, ys: env.ys)], legend: false,
          roomRight: true,
      dense: DenseSignal(values: cast[ptr UncheckedArray[float32]](addr ui.previewSamples[0]),
      count: ui.previewSamples.len, x0: 0.0, dx: ui.previewDt))
    let o = curves.drawCurvePlot(ui.signalPlot, "generate.preview", time, t,
      ImVec2_c(x: -1, y: plotH), fit, marks)
    explainMenu("generate.explain", o.plotPos, t, marks, explain(pkGenerateSignal, facts))
  if ui.previewDb.len > 1 and ui.previewHz.len > 1:
    let dx = ui.previewHz[1] - ui.previewHz[0]
    let nyquist = if ui.previewDt > 0: 500.0 / ui.previewDt else: ui.previewHz[^1]
    let axis = spectrumAxis(ui.previewF1, ui.previewF2, nyquist)
    var i0 = 0
    var i1 = ui.previewHz.high
    while i0 < i1 and ui.previewHz[i0] < axis.lo: inc i0
    while i1 > i0 and ui.previewHz[i1] > axis.hi: dec i1
    if i1 <= i0:
      i0 = 0
      i1 = ui.previewHz.high
    let n = i1 - i0 + 1
    var db = newSeq[float32](n)
    for i in 0 ..< n: db[i] = float32(ui.previewDb[i0 + i])
    let env = columnEnvelope(db, ui.previewHz[i0], dx, cols)
    var spec = CurvePlot(xLabel: "Frequency (Hz)", xUnit: "Hz", yLabel: "Amplitude (dB)",
      yUnit: "dB", xs: env.xs, xFloor: axis.lo, xCeil: axis.hi, legend: false, roomRight: true,
      curves: @[Curve(name: "amplitude", colour: ink, ys: env.ys)])
    let o = curves.drawCurvePlot(ui.spectrumPlot, "generate.spectrum", spec, t,
      ImVec2_c(x: -1, y: plotH), spectrumFitKey(ui.shownGen, ui.previewF1,
      ui.previewF2, nyquist), marks)
    explainMenu("generate.explain 2", o.plotPos, t, marks,
      explain(pkGenerateSpectrum, facts))

proc followPreview(ui: var ReferencesUi; g: GeneratedReference; key, problem: string) =
  let ready = takeGeneratePreview()
  # A result is shown only when it is the latest ask, not an older one that
  # reused the generation number.
  if ready.got and ready.key == key:
    if ready.problem.len == 0:
      ui.previewSamples = ready.samples
      ui.previewHz = ready.hz
      ui.previewDb = ready.db
      ui.shownGen = ready.gen
      ui.previewDt = ui.askedDt
      ui.previewDelay = ready.delay
      ui.delayKey = ready.key
      if ui.failKey == ready.key: ui.failKey = ""
      ui.previewF1 = g.f1Hz
      ui.previewF2 = g.f2Hz
    elif problem.len == 0:
      ui.genMessage = ready.problem
      ui.failKey = ready.key
      ui.failText = ready.problem
  if problem.len > 0:
    ui.genMessage = problem
    return
  ui.genMessage = ""
  if key != ui.liveKey:
    ui.liveKey = key
    ui.stable = 0
  else:
    inc ui.stable
  let wait = if ui.askedKey.len == 0: 0 else: 4
  if ui.stable >= wait and ui.askedKey != key:
    ui.askedKey = key
    ui.askedDt = g.dtMs
    inc ui.askedGen
    askGeneratePreview(ui.askedGen, g)

proc followPilot(ui: var ReferencesUi; st: AppState; rule: PilotRule;
    output: var ReferencesOutput) =
  ## The pilot of the record on show: asked when the rule or the record moves
  ## (once it has stayed put a few frames), and shown when it arrives.
  let key = $rule.aux & "|" & $rule.trace & "|" & $rule.startMs & "|" & $rule.spanMs & "|" &
    st.pilotShownKey
  if key != ui.pilotLive:
    ui.pilotLive = key
    ui.pilotStable = 0
  else:
    inc ui.pilotStable
  let wait = if ui.pilotAsked.len == 0: 0 else: 4
  if ui.pilotStable >= wait and ui.pilotAsked != key:
    ui.pilotAsked = key
    output.commands.add Command(kind: ckPilotPreview, refPilot: rule)
  let shown = st.pilotPreview
  if shown.gen != ui.pilotGen:
    ui.pilotGen = shown.gen
    ui.previewSamples = shown.samples
    ui.previewHz = shown.hz
    ui.previewDb = shown.db
    ui.previewDt = shown.dtMs
    ui.previewF1 = 0
    ui.previewF2 = if shown.dtMs > 0: 500.0 / shown.dtMs else: 0.0
    ui.shownGen = 1_000_000 + shown.gen

proc drawGenerate(ui: var ReferencesUi; st: AppState; t: Theme; marks: var Marks):
    ReferencesOutput =
  const id = "Generate a reference###generate-reference"
  if ui.genAsk:
    igOpenPopup_Str(id.cstring, 0)
    ui.genAsk = false
  let font = igGetFontSize()
  # font×64 holds the settings, including the optional boost and parameter and the filter choice,
  # both plots and the buttons. The buttons are drawn under a child that
  # takes the rest, so they stay inside at any size.
  igSetNextWindowSize(ImVec2_c(x: font * 46, y: font * 64), ImGui_Cond_FirstUseEver.cint)
  igSetNextWindowSizeConstraints(ImVec2_c(x: font * 36, y: font * 64),
    ImVec2_c(x: 4000, y: 4000), nil, nil)
  if not igBeginPopupModal(id.cstring, nil, 0): return
  marks.markWindow("generate")
  let footer = igGetFrameHeightWithSpacing()
  discard igBeginChild_Str("##generate.body", ImVec2_c(x: 0, y: -footer),
    ImGui_ChildFlags_NavFlattened.cint, 0)
  let before = ui.genSource
  if combo("Source", (if ui.genSource == 0: SourceSweep else: SourceRecord), "generate.source",
      marks):
    for (n, label) in [(0, SourceSweep), (1, SourceRecord)]:
      if igSelectable_Bool(label.cstring, n == ui.genSource, 0, ImVec2_c(x: 0, y: 0)):
        ui.genSource = n
      marks.mark("generate.source " & $n)
    igEndCombo()
  if ui.genSource != before:
    # the other source's picture is not this one's
    ui.previewSamples.setLen 0
    ui.previewHz.setLen 0
    ui.previewDb.setLen 0
    ui.askedKey = ""
    ui.liveKey = ""
    ui.stable = 0
    ui.pilotAsked = ""
    ui.pilotGen = -1
    ui.shownGen = 0
  if ui.genSource == 1 and not ui.pilotLengthFilled and st.shownLengthMs > 0:
    ui.pilotLength = st.shownLengthMs
    ui.pilotLengthFilled = true
  ui.refreshCoefficients()
  let defaultName = if ui.genSource == 0: defaultGenerateName(ui.asked)
                    else: defaultPilotName(ui.pilotRule)
  if bufText(ui.genName).len == 0 or bufText(ui.genName) == ui.autoName:
    if defaultName != ui.autoName or bufText(ui.genName).len == 0:
      setBuf(ui.genName, defaultName)
    ui.autoName = defaultName
  igTextUnformatted("Name", nil)
  igSameLine(font * 12, -1)
  igSetNextItemWidth(-1)
  if ui.genName.len < 160: setBuf(ui.genName, "")
  discard igInputText("##gen.name", cast[cstring](addr ui.genName[0]), csize_t(ui.genName.len),
    0, nil, nil)
  marks.mark("generate.name")
  if ui.genSource == 0:
    igSeparatorText("Sweep")
    discard number("Start frequency (Hz)", ui.genF1, "generate.f1", marks)
    discard number("End frequency (Hz)", ui.genF2, "generate.f2", marks)
    discard number("Length (ms)", ui.genLength, "generate.length", marks)
    tip(lengthTip(ui.genLength, ui.genDt, true))
    discard number("Sample interval (ms)", ui.genDt, "generate.dt", marks)
    discard number("Amplitude", ui.genAmp, "generate.amplitude", marks)
    if combo("Type", lawTitle(ui.genLaw), "generate.law", marks):
      for law in ReferenceLaw:
        if igSelectable_Bool(lawTitle(law).cstring, law == ui.genLaw, 0, ImVec2_c(x: 0, y: 0)):
          ui.genLaw = law
        marks.mark("generate.law " & $law)
      igEndCombo()
    if ui.genLaw in {rlDbPerOctave, rlDbPerHz}:
      discard number("Boost (dB)", ui.genBoost, "generate.boost", marks)
    igSeparatorText("Taper")
    if combo("Shape", taperShapeTitle(ui.genShape), "generate.shape", marks,
        ImGui_ComboFlags_HeightLargest.cint):
      for shape in TaperShape:
        if igSelectable_Bool(taperShapeTitle(shape).cstring, shape == ui.genShape, 0,
            ImVec2_c(x: 0, y: 0)):
          ui.pickShape(shape)
        marks.mark("generate.shape " & $shape)
      igEndCombo()
    let paramLabel = taperParamLabel(ui.genShape)
    if paramLabel.len > 0:
      if ui.genParam.isNaN: ui.genParam = taperDefaultParam(ui.genShape)
      discard number(paramLabel, ui.genParam, "generate.param", marks)
      tip(case ui.genShape
        of tpKaiser: "Kaiser beta, from 0 to 50"
        of tpGaussian: "Gaussian sigma, in ramp lengths, above 0"
        of tpPower: "Power exponent, above 0; 1 is a linear ramp"
        else: "")
    discard number("Taper start (ms)", ui.genTaper0, "generate.taper0", marks)
    discard number("Taper end (ms)", ui.genTaper1, "generate.taper1", marks)
    igSeparatorText("Phase")
    discard number("Start phase (deg)", ui.genPhase, "generate.phase", marks)
    tip("Degrees. 180 reverses the polarity")
    ui.drawFilter(t, marks)
  else:
    igSeparatorText("Pilot")
    let kind = if ui.pilotAux: "Auxiliary trace" else: "Trace of the record"
    if combo("Which trace", kind, "generate.pilot.kind", marks):
      for (aux, label) in [(true, "Auxiliary trace"), (false, "Trace of the record")]:
        if igSelectable_Bool(label.cstring, aux == ui.pilotAux, 0, ImVec2_c(x: 0, y: 0)):
          ui.pilotAux = aux
        marks.mark("generate.pilot.kind " & $aux)
      igEndCombo()
    tip("An auxiliary trace is counted among the record's auxiliary traces " &
      "(a pilot, a time break); a trace of the record is counted among all of its traces, " &
      "in file order. Each record uses its own, by this rule.")
    discard number("Number (from 1)", ui.pilotN, "generate.pilot.n", marks)
    ui.pilotN = round(ui.pilotN)
    discard number("Start (ms)", ui.pilotStart, "generate.pilot.start", marks)
    discard number("Length (ms)", ui.pilotLength, "generate.pilot.length", marks)
    tip("The window from Start for Length, cut to the end of the trace. The whole " &
      "trace is filled in while a file is open. " &
      lengthTip(ui.pilotLength, st.shownIntervalMs, false))
    let phase = if ui.pilotPhase == 180: "180 degrees (polarity reversed)" else: "0 degrees"
    if combo("Phase", phase, "generate.pilot.phase", marks):
      for (deg, label) in [(0.0, "0 degrees"), (180.0, "180 degrees (polarity reversed)")]:
        if igSelectable_Bool(label.cstring, deg == ui.pilotPhase, 0, ImVec2_c(x: 0, y: 0)):
          ui.pilotPhase = deg
        marks.mark("generate.pilot.deg " & $int(deg))
      igEndCombo()
    tip("A recorded trace takes 0 or 180 degrees; 180 reverses its polarity, after the " &
      "trace is taken (as recorded, reversed when the trace is, never with a filter or the " &
      "plot's settings) and cut. A trace you also reversed on the plot is turned twice: back " &
      "as recorded.")
  var g = GeneratedReference()
  var rule = PilotRule()
  var problem = ""
  var key = ""
  if ui.genSource == 0:
    g = ui.asked
    key = settingsKey(g)
    problem = generateProblem(g)
    if problem.len == 0 and ui.failKey == key: problem = ui.failText
    if ui.genFKind != rfNone and ui.genFByCoef:
      if ui.coefProblem.len > 0: problem = ui.coefProblem
      elif ui.coefTaps.len == 0 and problem.len == 0:
        problem = "type or paste the filter's coefficients"
    ui.followPreview(g, key, problem)
  else:
    rule = ui.pilotRule
    key = "record " & $rule.aux & " " & $rule.trace & " " & $rule.startMs & " " &
      $rule.spanMs
    problem = pilotProblem(rule)
    if problem.len == 0: ui.followPilot(st, rule, result)
  ui.previewKey = key
  igDummy(ImVec2_c(x: 1, y: 1))
  marks.mark("generate.previewkey." & key)
  let spacing = igGetStyle().ItemSpacing.y
  let room = igGetContentRegionAvail().y
  let plotH = max(font * 4, (room - spacing) / 2) # a long dialog scrolls
  if problem.len > 0:
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
    igTextWrapped("%s", problem.cstring)
    igPopStyleColor(1)
    marks.mark("generate.message")
  elif ui.genSource == 1:
    let shown = st.pilotPreview
    let where = if shown.record.len > 0: "From " & shown.record & ", the record on show."
                else: "Taken from each record when this reference is chosen."
    igTextWrapped("%s", where.cstring)
    marks.mark("generate.pilot.record")
    if shown.note.len > 0 and shown.problem.len == 0:
      igTextWrapped("%s", ("Pilot: " & shown.note).cstring)
      marks.mark("generate.pilot.note")
    if shown.problem.len > 0:
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
      igTextWrapped("%s", shown.problem.cstring)
      igPopStyleColor(1)
      marks.mark("generate.pilot.message")
    elif ui.previewSamples.len > 1:
      ui.drawPlots(t, max(1'f32, plotH - igGetTextLineHeightWithSpacing() / 2),
        pilotFacts(rule, shown.record, shown.note), marks)
    else:
      igTextUnformatted("Reading the pilot...", nil)
      marks.mark("generate.computing")
  elif ui.previewSamples.len > 1:
    ui.drawPlots(t, plotH, generateFacts(g), marks)
  else:
    igTextUnformatted("Computing the preview...", nil)
    marks.mark("generate.computing")
  igEndChild()
  igBeginDisabled(problem.len > 0)
  if igButton("Generate", ImVec2_c(x: 0, y: 0)) and problem.len == 0:
    if ui.genSource == 0:
      var made = g
      if made.name.len == 0: made.name = defaultGenerateName(made)
      result.commands.add Command(kind: ckGenerateReference, refGenerate: made)
    else:
      var made = rule
      if made.name.strip.len == 0: made.name = defaultPilotName(made)
      result.commands.add Command(kind: ckPilotReference, refPilot: made)
    igCloseCurrentPopup()
  igEndDisabled()
  marks.mark("generate.ok")
  igSameLine(0, -1)
  if igButton("Cancel", ImVec2_c(x: 0, y: 0)): igCloseCurrentPopup()
  marks.mark("generate.cancel")
  igEndPopup()

proc drawStore*(d: var StoreDialog; st: AppState; t: Theme; marks: var Marks): seq[Command] =
  const id = "Store as reference###store-reference"
  if d.ask:
    igOpenPopup_Str(id.cstring, 0)
    d.ask = false
  let vp = igGetMainViewport() # centred on the main window, as it opens, never above it
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + vp.WorkSize.x / 2,
    y: vp.WorkPos.y + vp.WorkSize.y / 2), ImGui_Cond_Appearing.cint, ImVec2_c(x: 0.5, y: 0.5))
  let open = igBeginPopupModal(id.cstring, nil, ImGui_WindowFlags_AlwaysAutoResize.cint)
  if d.wasOpen and not open:
    # The modal had the keys. Give them back to the plot, which this is drawn from.
    igSetWindowFocus_Nil()
  d.wasOpen = open
  if not open: return
  marks.markWindow("store")
  var applied = "stored as recorded"
  let ti = st.findTrace(d.trace)
  if ti >= 0:
    let s = st.sessions[ti]
    let local = d.trace - s.base
    if st.hasEditAt(s.path, local, teReversed): applied = "stored reversed (this trace is reversed)"
    if st.hasEditAt(s.path, local, teKilled):
      applied = "this trace is killed: it cannot be stored"
  igTextWrapped("%s", ("The trace is " & applied &
      ". No filter, reverse-all or gain is applied.").cstring)
  marks.mark("store.raw")
  marks.mark("store.applied:" & applied)
  igTextUnformatted("Name", nil)
  igSameLine(igGetFontSize() * 8, -1)
  igSetNextItemWidth(igGetFontSize() * 22)
  if d.name.len < 160: setBuf(d.name, "")
  discard igInputText("##store.name", cast[cstring](addr d.name[0]), csize_t(d.name.len),
    0, nil, nil)
  marks.mark("store.name")
  igTextUnformatted("Phase", nil)
  igSameLine(igGetFontSize() * 8, -1)
  igSetNextItemWidth(igGetFontSize() * 14)
  let phaseText = if d.phase == 180: "180 degrees (reversed)" else: "0 degrees"
  if igBeginCombo("##store.phase", phaseText.cstring, 0):
    for (deg, label) in [(0.0, "0 degrees"), (180.0, "180 degrees (reversed)")]:
      if igSelectable_Bool(label.cstring, deg == d.phase, 0, ImVec2_c(x: 0, y: 0)):
        d.phase = deg
      marks.mark("store.deg " & $int(deg))
    igEndCombo()
  marks.mark("store.phase")
  tip("A recorded trace takes 0 or 180 degrees; 180 turns the stored window over, after " &
    "the trace's own reversal (a trace you reversed is turned twice: as recorded).")
  igTextUnformatted("From ms", nil)
  igSameLine(igGetFontSize() * 8, -1)
  # (Dear ImGui 1.92.9 writes a typed number back when the box is left; the
  # line under the boxes says what they take as they are typed in)
  igPushItemFlag(ImGui_ItemFlags_LiveEditOnInputScalar.cint, true)
  discard igInputDouble("##store.from", addr d.fromMs, 0, 0, "%.9g", 0)
  marks.mark("store.from")
  tip("The time of the first sample taken (0 is the trace's first sample).")
  igTextUnformatted("To ms", nil)
  igSameLine(igGetFontSize() * 8, -1)
  let lastMs = if d.samples > 0 and d.dtMs > 0: float64(d.samples - 1) * d.dtMs else: Inf
  if igInputDouble("##store.to", addr d.toMs, 0, 0, "%.9g", 0):
    let (to, clamped) = clampedTo(d.toMs, lastMs, d.dtMs)
    d.toMs = to
    d.clamped = if clamped: "The trace's last sample is at " & msWords(lastMs) &
      " ms: To is brought back to it." else: ""
  igPopItemFlag()
  marks.mark("store.to")
  tip("The time of the last sample taken: the window includes it (inclusive). A trace of " &
    "12 000 samples at 1 ms ends at 11 999 ms and is 12 000 ms long.")
  if d.samples > 0 and d.dtMs > 0:
    let r = cutRange(d.samples, d.dtMs * 1000, d.fromMs, d.toMs)
    let taken = max(r.b - r.a + 1, 0)
    let words = if taken > 0: "Takes " & rangeWords(float64(r.a) * d.dtMs, float64(r.b) * d.dtMs,
                  taken, d.dtMs)
                else: "The window holds no sample"
    igTextWrapped("%s", words.cstring)
    marks.mark("store.taken:" & words)
  if d.clamped.len > 0:
    igTextWrapped("%s", d.clamped.cstring)
    marks.mark("store.clamped:" & d.clamped)
  let length = "The whole trace: " & lengthWords(d.samples, d.dtMs) &
    (if d.sweep: " (To is the last sample of the sweep, whose length the file's headers give; " &
      "the rest is listen time)"
      else: " (usually cut to the sweep length; the rest is listen time)")
  igTextWrapped("%s", length.cstring)
  marks.mark("store.length")
  if d.message.len > 0:
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
    igTextWrapped("%s", d.message.cstring)
    igPopStyleColor(1)
    marks.mark("store.message")
  let name = bufText(d.name).strip
  if igButton("Store", ImVec2_c(x: 0, y: 0)):
    let problem = if st.referencesLoaded: st.references.nameProblem(name) else: ""
    if name.len == 0 or problem.len > 0:
      d.message = if name.len == 0: "a reference needs a name" else: problem
    else:
      result.add Command(kind: ckStoreReference, refStore: StoredReference(name: name,
        trace: d.trace, fromMs: d.fromMs, toMs: d.toMs, phaseDeg: d.phase))
      igCloseCurrentPopup()
  marks.mark("store.ok")
  igSameLine(0, -1)
  if igButton("Cancel", ImVec2_c(x: 0, y: 0)): igCloseCurrentPopup()
  marks.mark("store.cancel")
  igEndPopup()

proc orderOf(index: ReferenceIndex; sort: RefSort; descending: bool): seq[int] =
  result = newSeq[int](index.entries.len)
  for i in 0 ..< result.len: result[i] = i
  proc key(i: int): string =
    let e = index.entries[i]
    case sort
    of rsName: e.name.toLowerAscii
    of rsLength: align($e.samples, 12, '0')
    of rsInterval: align($int(e.intervalUs), 12, '0')
    of rsFrequency: frequencyText(e)
    of rsSource: sourceText(e).toLowerAscii
    of rsDate: e.date
  result.sort do (a, b: int) -> int:
    let c = cmp(key(a), key(b))
    if descending: -c else: c

type ArchiveColumns = object
  ## The widths the archive tables give their columns: the text each holds, at its widest.
  ## Name takes what is left; Source is as wide as its text, to 24 characters' room, and
  ## shortens it beyond that.
  name, length, interval, frequency, date, use, source: float32

proc archiveColumns(index: ReferenceIndex): ArchiveColumns =
  ## `index`'s columns sized to their texts and headers (a header takes room for the sort
  ## arrow), the name capped at 28 characters' room (the window's first width).
  let st = igGetStyle()
  let pad = 2 * st.CellPadding.x + 2
  let arrow = igGetFontSize() + st.ItemInnerSpacing.x
  func head(h: string): float32 = textWidth(h) + arrow
  result.name = head("Name")
  result.length = head("Length")
  result.interval = head("Sample interval")
  result.frequency = head("Frequency")
  result.date = head("Date")
  result.source = head("Source")
  for e in index.entries:
    result.name = max(result.name, textWidth(e.name))
    result.length = max(result.length, textWidth(lengthText(e)))
    result.interval = max(result.interval, textWidth(intervalText(e)))
    result.frequency = max(result.frequency, textWidth(frequencyText(e)))
    result.date = max(result.date, textWidth(e.date))
    result.source = max(result.source, textWidth(sourceText(e)))
  result.name = min(result.name, igGetFontSize() * 28)
  result.source = min(result.source, igGetFontSize() * 24)
  for w in [addr result.name, addr result.length, addr result.interval, addr result.frequency,
      addr result.date, addr result.source]:
    w[] = round(w[] + pad)
  result.use = round(max(textWidth("Use"), igGetFontSize()) + pad)

func tableKey(c: ArchiveColumns): string =
  ## Part of the table's id: its widths, so that texts that grew give the columns a fresh fit.
  $int(c.name + c.length + c.interval + c.frequency + c.date)

proc setupArchiveColumns(c: ArchiveColumns) =
  ## The columns, in the order `drawRows` fills them: Use, the name that takes the spare
  ## width, then the fixed ones.
  const fixed = ImGui_TableColumnFlags_WidthFixed.cint
  igTableSetupColumn("Use", ImGui_TableColumnFlags_NoSort.cint or fixed, c.use, 0)
  igTableSetupColumn("Name", ImGui_TableColumnFlags_WidthStretch.cint, 1, 1)
  igTableSetupColumn("Length", fixed, c.length, 2)
  igTableSetupColumn("Sample interval", fixed, c.interval, 3)
  igTableSetupColumn("Frequency", fixed, c.frequency, 4)
  igTableSetupColumn("Source", fixed, c.source, 5)
  igTableSetupColumn("Date", fixed, c.date, 6)

func archiveWindowWidth(c: ArchiveColumns): float32 =
  ## The window's width that holds the table: the columns at their widths, the scroll bar
  ## and the window's padding.
  c.name + c.length + c.interval + c.frequency + c.date + c.use + c.source +
    2 * igGetStyle().WindowPadding.x + igGetStyle().ScrollbarSize + 16

proc markCell(marks: var Marks; prefix: string; row: int; column: string; index: int) =
  ## The last item's rectangle as "<prefix>.<column>.<row>" and its column's cell as
  ## "<prefix>.<column> column.<row>" (tests: the text is inside its column).
  marks.mark(prefix & "." & column & "." & $row)
  let cell = igTableGetCellBgRect(igGetCurrentTable(), cint(index))
  marks.markRect(prefix & "." & column & " column." & $row, ImVec2_c(x: cell.Min.x, y: cell.Min.y),
    ImVec2_c(x: cell.Max.x, y: cell.Max.y))

proc rightText(text: string) =
  ## `text` against the right edge of the cell.
  let room = igGetContentRegionAvail().x - textWidth(text)
  if room > 0: igSetCursorPosX(igGetCursorPosX() + room)
  igTextUnformatted(text.cstring, nil)

type
  ArchiveAct = enum
    aaUse = "Use", aaView = "View", aaRename = "Rename", aaDelete = "Delete",
    aaCompareA = "Compare as A", aaCompareB = "Compare as B", aaCopy = "Copy to project"

  ActState = array[ArchiveAct, tuple[enabled: bool, why: string]]
    ## Which actions the selected row allows, and why one does not (its tooltip).

const NoneRow = "\x01none" ## the selected row's id when it is the None row

const ActMark: array[ArchiveAct, string] = ["use", "view", "rename", "delete", "compareA",
  "compareB", "copy"]

proc actionsOf(st: AppState; id: string; inMain: bool): ActState =
  ## What the row `id` (of the main archive's table when `inMain`) allows.
  const none = "Select a reference in the list first"
  for a in ArchiveAct: result[a] = (false, none)
  let writable = not (st.inProject and st.project.readOnly)
  let index = if inMain: st.mainReferences else: st.references
  if id == NoneRow:
    const notOne = "None is not a reference"
    for a in ArchiveAct: result[a] = (false, notOne)
    result[aaUse] = (st.chosenReference.len > 0, "No reference is in use already")
  elif id.len > 0 and index.findId(id) >= 0:
    let e = index.entries[index.findId(id)]
    let used = e.id == st.chosenReference and not inMain
    let unusable = e.missing or e.blocked
    result[aaUse] = (writable and not inMain and not used,
      if inMain: "Copy it into the project first" elif not writable: "The project is read only"
      else: "The plots already use this reference")
    result[aaView] = (not unusable and st.referencesHome.len > 0 and not inMain,
      if inMain: "Copy it into the project first" else: "Its file is not there")
    result[aaRename] = (writable and not inMain, if inMain: "The main archive is not changed " &
      "from here" else: "The project is read only")
    result[aaDelete] = (writable and not inMain, result[aaRename].why)
    let noCompare = if e.isPilot: "A trace of each record is not one waveform: view it, and " &
        "store it as a fixed reference first" else: "Its file is not there"
    result[aaCompareA] = (not unusable and not e.isPilot, noCompare)
    result[aaCompareB] = result[aaCompareA]
    result[aaCopy] = (inMain, "Only a main archive reference is copied into the project")

proc perform(ui: var ReferencesUi; res: var ReferencesOutput; a: ArchiveAct; id: string;
    st: AppState) =
  ## Does action `a` on the row `id`.
  case a
  of aaUse: res.commands.add Command(kind: ckSelectReference, refId: (if id ==
      NoneRow: "" else: id))
  of aaView: res.commands.add Command(kind: ckViewReference, refId: id)
  of aaRename:
    let i = st.references.findId(id)
    if i >= 0:
      ui.renameId = id
      ui.renameFocus = true
      setBuf(ui.rename, st.references.entries[i].name)
  of aaDelete:
    ui.confirmId = id
    ui.confirmAsk = true
  of aaCompareA:
    res.commands.add Command(kind: ckSetCompare, compareSlot: cwA, compareRef: id,
      compareTrace: -1)
  of aaCompareB:
    res.commands.add Command(kind: ckSetCompare, compareSlot: cwB, compareRef: id,
      compareTrace: -1)
  of aaCopy: res.commands.add Command(kind: ckCopyReference, refId: id)

proc drawActionBar(ui: var ReferencesUi; st: AppState; marks: var Marks;
    res: var ReferencesOutput) =
  ## One row of buttons that act on the selected row, of either table.
  let acts = st.actionsOf(ui.selected, ui.selMain)
  for a in ArchiveAct:
    if a != aaUse: igSameLine(0, -1)
    igBeginDisabled(not acts[a].enabled)
    if igButton(($a).cstring, ImVec2_c(x: 0, y: 0)) and acts[a].enabled:
      ui.perform(res, a, ui.selected, st)
    igEndDisabled()
    marks.mark("references.act." & ActMark[a])
    tip(if acts[a].enabled: ($a & " the selected reference") else: acts[a].why)

proc drawRows(ui: var ReferencesUi; index: ReferenceIndex; inMain: bool; st: AppState;
    marks: var Marks; res: var ReferencesOutput; markPrefix: string) =
  ## The rows of one table. One row is selected (`ui.selected`, in the table `ui.selMain`
  ## names): a click anywhere on it selects it, a double click views it. The radio in the
  ## first column is the reference in use.
  let order = orderOf(index, ui.sort, ui.descending)
  let writable = not (st.inProject and st.project.readOnly) and not inMain
  let chosen = st.chosenReference
  let rows = (if inMain: @[] else: @[-1]) & order
  for n, i in rows:
    let isNone = i < 0
    let id = if isNone: NoneRow else: index.entries[i].id
    let rowMark = if isNone: "references.nonerow" else: markPrefix & ".row." & $(n - (
        if inMain: 0 else: 1))
    igPushID_Str(id.cstring)
    igTableNextRow(0, 0)
    discard igTableNextColumn()
    let start = igGetCursorScreenPos()
    let selected = ui.selected == id and ui.selMain == inMain
    var missing = false
    var name = NoneChoiceLabel
    if not isNone:
      missing = index.entries[i].missing
      name = index.entries[i].name
    # The selectable takes the clicks only; the highlight is the table's row background,
    # which is exactly the row.
    for c in [ImGui_Col_Header, ImGui_Col_HeaderHovered, ImGui_Col_HeaderActive]:
      igPushStyleColor_Vec4(c.cint, ImVec4_c(x: 0, y: 0, z: 0, w: 0))
    if igSelectable_Bool("##row", selected, ImGui_SelectableFlags_SpanAllColumns.cint or
        ImGui_SelectableFlags_AllowOverlap.cint or ImGui_SelectableFlags_AllowDoubleClick.cint,
        ImVec2_c(x: 0, y: 0)):
      ui.selected = id
      ui.selMain = inMain
    igPopStyleColor(3)
    marks.mark(rowMark)
    let table = igGetCurrentTable()
    if selected or igIsItemHovered(0):
      let shade = if selected: ImGui_Col_Header else: ImGui_Col_HeaderHovered
      igTableSetBgColor(ImGui_TableBgTarget_RowBg0.cint, igGetColorU32_Col(shade.cint, 1), -1)
    if igIsItemHovered(0) and igIsMouseDoubleClicked_Nil(ImGui_MouseButton_Left.cint):
      if st.actionsOf(id, inMain)[aaView].enabled: ui.perform(res, aaView, id, st)
    if selected:
      if ui.scrollToSelected:
        if not igIsItemVisible(): igSetScrollHereY(0.5)
        ui.scrollToSelected = false
    if igIsItemClicked(ImGui_MouseButton_Right.cint):
      ui.selected = id
      ui.selMain = inMain
    if igBeginPopupContextItem("##rowmenu", ImGui_PopupFlags_MouseButtonRight.cint):
      let acts = st.actionsOf(id, inMain)
      for a in ArchiveAct:
        if igMenuItem_Bool(($a).cstring, nil, false, acts[a].enabled):
          ui.perform(res, a, id, st)
      igEndPopup()
    # the radio over the row's selectable
    igSetCursorScreenPos(start)
    if writable:
      let used = if isNone: chosen.len == 0 else: id == chosen
      # a ring and a dot the size of the text, no filled disc
      igPushStyleVar_Vec2(ImGui_StyleVar_FramePadding.cint, ImVec2_c(x: 0, y: 0))
      igPushStyleVar_Float(ImGui_StyleVar_FrameBorderSize.cint, 1)
      let ring = igGetStyleColorVec4(ImGui_Col_TextDisabled.cint)[]
      igPushStyleColor_Vec4(ImGui_Col_Border.cint, ring)
      for c in [ImGui_Col_FrameBg, ImGui_Col_FrameBgHovered, ImGui_Col_FrameBgActive]:
        igPushStyleColor_Vec4(c.cint, ImVec4_c(x: 0, y: 0, z: 0, w: 0))
      let picked = igRadioButton_Bool("##use", used)
      igPopStyleColor(4)
      igPopStyleVar(2)
      if picked:
        res.commands.add Command(kind: ckSelectReference,
          refId: (if used or isNone: "" else: id))
      marks.mark(if isNone: "references.none" else: markPrefix & ".use." & $(n - 1))
      tip(if isNone: NoneChoiceTip elif used: "The plots use this reference. Click again for none."
          else: "Use this reference in the plots")
    discard igTableNextColumn()
    if ui.renameId == id and writable and not isNone:
      if ui.renameFocus:
        igSetKeyboardFocusHere(0)
        ui.renameFocus = false
      igSetNextItemWidth(-1)
      let enter = igInputText("##rename", cast[cstring](addr ui.rename[0]),
        csize_t(ui.rename.len), ImGui_InputTextFlags_EnterReturnsTrue.cint, nil, nil)
      marks.mark(markPrefix & ".rename")
      if (igIsItemActive() or igIsItemDeactivated()) and
          igIsKeyPressed_Bool(ImGui_Key_Escape, false):
        ui.renameId = ""
        ui.renameProblem = ""
      elif enter:
        let newName = bufText(ui.rename).strip
        let problem = index.nameProblem(newName)
        if problem.len == 0 or index.findName(newName) == i:
          res.commands.add Command(kind: ckRenameReference, refId: id, refNewName: newName)
          ui.renameId = ""
          ui.renameProblem = ""
        else:
          ui.renameProblem = problem
    else:
      let shown = shortenEnd(name, igGetContentRegionAvail().x)
      if missing: igTextDisabled("%s", shown.cstring) else: igTextUnformatted(shown.cstring, nil)
      if shown != name or missing:
        tip(if missing: "its SEG-Y file is missing" else: name)
    if not isNone:
      let e = index.entries[i]
      let k = n - (if inMain: 0 else: 1)
      discard igTableNextColumn()
      rightText(lengthText(e))
      markCell(marks, markPrefix, k, "length", 2)
      discard igTableNextColumn()
      rightText(intervalText(e))
      markCell(marks, markPrefix, k, "interval", 3)
      discard igTableNextColumn()
      rightText(frequencyText(e))
      markCell(marks, markPrefix, k, "frequency", 4)
      discard igTableNextColumn()
      fittedText(sourceText(e), igGetContentRegionAvail().x)
      discard igTableNextColumn()
      igTextUnformatted(e.date.cstring, nil)
      markCell(marks, markPrefix, k, "date", 6)
    if selected:
      # the highlight: the whole row, known now that every cell is drawn
      let (a, b) = (igTableGetCellBgRect(table, 0), igTableGetCellBgRect(table, 6))
      marks.markRect("references.selected", a.Min, b.Max)
    igPopID()

proc drawTable(ui: var ReferencesUi; index: ReferenceIndex; inMain: bool; st: AppState;
    marks: var Marks; res: var ReferencesOutput; height: float32; markPrefix: string) =
  ## One archive table of `height` (at most 0: what is left, less its size).
  const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_BordersInnerV.cint or
    ImGui_TableFlags_ScrollY.cint or ImGui_TableFlags_Resizable.cint or
    ImGui_TableFlags_Sortable.cint
  let columns = archiveColumns(index)
  if igBeginTable((markPrefix & ".table" & columns.tableKey).cstring, 7, flags,
      ImVec2_c(x: 0, y: height), 0):
    let outer = igGetCurrentTable().OuterRect
    marks.markRect(markPrefix & ".table", outer.Min, outer.Max)
    igTableSetupScrollFreeze(0, 1)
    setupArchiveColumns(columns)
    igTableHeadersRow()
    let specs = igTableGetSortSpecs()
    if specs != nil and specs.SpecsCount > 0:
      let s = specs.Specs[]
      ui.sort = RefSort(clamp(int(s.ColumnIndex) - 1, 0, 5))
      ui.descending = s.SortDirection == ImGui_SortDirection_Descending
      specs.SpecsDirty = false
    ui.drawRows(index, inMain, st, marks, res, markPrefix)
    igEndTable()

proc stepSelection(ui: var ReferencesUi; st: AppState; step: ListStep) =
  ## The arrow, page, Home and End keys move the selection along the table it is in.
  var ids: seq[string]
  let index = if ui.selMain: st.mainReferences else: st.references
  if not ui.selMain: ids.add NoneRow
  for i in orderOf(index, ui.sort, ui.descending): ids.add index.entries[i].id
  if ids.len > 0:
    let at = ids.find(ui.selected)
    let last = ids.high
    let to = case step
      of lsNext: min(at + 1, last)
      of lsPrevious: max(at - 1, 0)
      of lsPageDown: min(max(at, 0) + 10, last)
      of lsPageUp: max(max(at, 0) - 10, 0)
      of lsFirst: 0
      of lsLast: last
      of lsNone: at
    if to != at:
      ui.selected = ids[to]
      ui.scrollToSelected = true

const ConfirmId = "Delete this reference?###refs.confirm"

proc drawArchive(ui: var ReferencesUi; title: string; st: AppState; t: Theme;
    marks: var Marks): ReferencesOutput =
  if not ui.shown: return
  let vp = igGetMainViewport()
  if ui.placeAgain or ui.bringUp:
    igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + 40, y: vp.WorkPos.y + 40),
      ImGui_Cond_Always.cint, ImVec2_c(x: 0, y: 0))
    ui.placeAgain = false
  # wide enough for the table the first time; after that the size is the user's, kept with
  # the layout
  let columns = archiveColumns(st.references)
  igSetNextWindowSize(ImVec2_c(x: min(vp.WorkSize.x - 80, archiveWindowWidth(columns)),
    y: igGetFontSize() * 26), ImGui_Cond_FirstUseEver.cint)
  igSetNextWindowSizeConstraints(ImVec2_c(x: igGetFontSize() * 30, y: igGetFontSize() * 16),
    ImVec2_c(x: 4000, y: 4000), nil, nil)
  if ui.bringUp:
    igSetWindowFocus_Str(title.cstring)
    ui.bringUp = false
  var open = true
  if igBegin(title.cstring, addr open, ImGui_WindowFlags_NoDocking.cint):
    ui.focus.watch()
    marks.markWindow("references")
    if igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint):
      marks.markWindow("references.focused") # for the tests
    let which = referenceArchiveTitle(st)
    igTextUnformatted(("Showing the " & which & " archive.").cstring, nil)
    marks.mark("references.which")
    if not st.referencesLoaded: igTextDisabled("Reading...")
    for p in st.references.problems:
      igTextWrapped("%s", p.cstring)
    # a selection whose row is gone (deleted, another archive) is none
    if ui.selected != NoneRow:
      let index = if ui.selMain: st.mainReferences else: st.references
      if index.findId(ui.selected) < 0: ui.selected = ""
    if ui.renameId.len > 0 and ui.renameId != ui.selected:
      ui.renameId = ""
      ui.renameProblem = ""
    ui.drawActionBar(st, marks, result)
    # The first table takes the height that is left. A project's main archive hangs under
    # it: its header at the window's bottom, and the table, when open, a share of the height.
    let avail = igGetContentRegionAvail().y
    let line = igGetTextLineHeightWithSpacing()
    let mainHeight = max(igGetFontSize() * 7, avail * 0.4)
    var reserve = 0'f32
    if ui.renameProblem.len > 0: reserve += line
    if st.inProject:
      reserve += igGetFrameHeightWithSpacing()
      if ui.mainOpen: reserve += mainHeight + line + igGetStyle().ItemSpacing.y
    ui.drawTable(st.references, false, st, marks, result,
      if reserve > 0: -reserve else: -1e-30'f32, "references")
    if ui.renameProblem.len > 0:
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
      igTextWrapped("%s", ui.renameProblem.cstring)
      igPopStyleColor(1)
      marks.mark("references.rename.problem")
    if st.inProject:
      ui.mainOpen = igCollapsingHeader_TreeNodeFlags("Main archive".cstring, 0)
      marks.mark("references.main.header")
      if ui.mainOpen:
        marks.mark("references.main")
        igTextDisabled("Read-only. Copy one into the project to use it.")
        if st.mainReferences.entries.len == 0: igTextDisabled("The main archive is empty.")
        else:
          ui.drawTable(st.mainReferences, true, st, marks, result, mainHeight,
            "references.main")
    # the keys of the list, while the window has the focus and no name is being typed
    if ui.renameId.len == 0:
      let step = stepOf("references")
      if step != lsNone: ui.stepSelection(st, step)
      if igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint) and
          not igGetIO_Nil().WantTextInput:
        let acts = st.actionsOf(ui.selected, ui.selMain)
        if igIsKeyPressed_Bool(ImGui_Key_Delete, false) and acts[aaDelete].enabled:
          ui.perform(result, aaDelete, ui.selected, st)
        if igIsKeyPressed_Bool(ImGui_Key_F2, false) and acts[aaRename].enabled:
          ui.perform(result, aaRename, ui.selected, st)
  igEnd()
  if not open: ui.shown = false
  if ui.confirmAsk:
    igOpenPopup_Str(ConfirmId.cstring, 0)
    ui.confirmAsk = false
  centreModal(ConfirmId)
  igSetNextWindowSizeConstraints(ImVec2_c(x: igGetFontSize() * 26, y: 0),
    ImVec2_c(x: 4000, y: 4000), nil, nil)
  let confirming = igBeginPopupModal(ConfirmId.cstring, nil,
    ImGui_WindowFlags_AlwaysAutoResize.cint)
  ui.confirmWasOpen.handBack(confirming, title)
  if confirming:
    marks.markWindow("references.confirm")
    var name = ui.confirmId
    let i = st.references.findId(ui.confirmId)
    if i >= 0: name = st.references.entries[i].name
    igTextWrapped("%s", ("Delete the reference \"" & name & "\"? This cannot be undone.").cstring)
    if igButton("Delete", ImVec2_c(x: 0, y: 0)):
      result.commands.add Command(kind: ckDeleteReference, refId: ui.confirmId)
      ui.confirmId = ""
      igCloseCurrentPopup()
    marks.mark("references.confirm.delete")
    igSameLine(0, -1)
    if igButton("Cancel", ImVec2_c(x: 0, y: 0)): igCloseCurrentPopup()
    marks.mark("references.confirm.cancel")
    igEndPopup()

proc thinPair(xs, ys: seq[float64]): (seq[float64], seq[float64]) =
  ## At most about 4000 points that keep every peak and notch (`extremeBins`).
  if ys.len <= 4000: return (xs, ys)
  let step = (ys.len + 1999) div 2000
  for (lo, hi) in extremeBins(ys, step):
    if lo >= 0:
      result[0].add xs[min(lo, xs.high)]
      result[1].add ys[lo]
      if hi != lo:
        result[0].add xs[min(hi, xs.high)]
        result[1].add ys[hi]

proc pilotLine(w: RefView): string =
  ## What a pilot of the record's window says of where it is from: its length and its start.
  "From " & (if w.record.len > 0: w.record else: "the record on show") & ", " &
    pilotWords(w.pilot.aux, w.pilot.trace) & ", " & msWords(w.pilot.spanMs) & " ms from " &
    msWords(w.pilot.startMs) & " ms" &
    (if w.pilot.phaseDeg == 180: ", 180 deg phase" else: "") & ". Another record has its own pilot."

proc drawRefViews*(ui: var ReferencesUi; st: AppState; t: Theme; scale: float32;
    marks: var Marks): seq[Command] =
  ## Each reference opened with View, in its own dockable window. The file
  ## under QC is not touched.
  var ids: seq[int] = @[]
  for w in st.refViews:
    ids.add w.id
    placeNext(w.id + 8, (640'f32, 720'f32), scale)
    var open = true
    let title = IconReference & "  Reference: " & w.name & "###refview-" & $w.id
    if igBegin(title.cstring, addr open, 0):
      marks.markWindow("reference.view")
      if w.gone:
        igTextWrapped("%s", w.note.cstring)
        marks.mark("reference.view.gone")
      elif w.waiting:
        igTextUnformatted("Reading...", nil)
      elif w.note.len > 0 and w.ys.len == 0:
        if w.pilot.trace > 0:
          igTextWrapped("%s", pilotLine(w).cstring)
          marks.mark("reference.view.record")
        igTextWrapped("%s", w.note.cstring)
        marks.mark("reference.view.note")
      else:
        if w.pilot.trace > 0:
          igTextWrapped("%s", pilotLine(w).cstring)
          marks.mark("reference.view.record")
          if w.pilotTrace >= 0 and igButton("Store this pilot as a fixed reference",
              ImVec2_c(x: 0, y: 0)):
            ui.fixed.openStore(w.pilotTrace, w.name & " (" & w.record & ")", w.pilotFrom,
              w.pilotTo, (if w.dtMs > 0: int(round(w.pilotTraceMs / w.dtMs)) else: 0), w.dtMs,
              false, w.pilot.phaseDeg)
          marks.mark("reference.view.fix")
          tip("Saves this record's cut pilot as an ordinary stored waveform, the " &
            "pilot as the rule gives it for this record: the recorded trace, reversed when the " &
            "trace is, the cut, and the rule's phase. No filter, nothing of the plot's.")
        if w.pilotNote.len > 0:
          igTextWrapped("%s", ("Pilot: " & w.pilotNote).cstring)
          marks.mark("reference.view.pilotnote")
        var uis = ui.viewPlots.getOrDefault(w.id)
        let ink = t.roles[rlAccent]
        if uis.rev != w.revision + 1 or uis.ys.len != w.ys.len:
          uis.rev = w.revision + 1
          uis.ys = newSeq[float32](w.ys.len)
          for i, v in w.ys: uis.ys[i] = float32(v)
        let dt = if w.dtMs > 0: w.dtMs else: 1.0
        let env = columnEnvelope(uis.ys, w.fromMs, dt, 1024)
        var time = CurvePlot(xLabel: "Time (ms)", xUnit: "ms", yLabel: "Amplitude",
          xs: env.xs, curves: @[Curve(name: w.name, colour: ink, ys: env.ys)], legend: false,
          roomRight: true)
        if uis.ys.len > 1:
          time.dense = DenseSignal(values: cast[ptr UncheckedArray[float32]](addr uis.ys[0]),
            count: uis.ys.len, x0: w.fromMs, dx: dt)
        let ot = curves.drawCurvePlot(uis.time, "reference.view.time", time, t,
          ImVec2_c(x: -1, y: igGetFontSize() * 12), $w.revision, marks)
        explainMenu("reference.view.explain", ot.plotPos, t, marks,
          explain(pkReferenceSignal, refViewFacts(w)))
        let (hx, hy) = thinPair(w.hz, w.amps)
        var spec = CurvePlot(xLabel: "Frequency (Hz)", xUnit: "Hz", yLabel: "Amplitude",
          xs: hx, curves: @[Curve(name: "amplitude", colour: ink, ys: hy)], legend: false,
          roomRight: true)
        if hy.len == 0: spec.note = "No spectrum."
        let os = curves.drawCurvePlot(uis.spec, "reference.view.spectrum", spec, t,
          ImVec2_c(x: -1, y: igGetFontSize() * 12), "s" & $w.revision, marks)
        explainMenu("reference.view.explain 2", os.plotPos, t, marks,
          explain(pkReferenceSpectrum, refViewFacts(w)))
        ui.viewPlots[w.id] = uis
    igEnd()
    if not open: result.add Command(kind: ckCloseRefView, refWindow: w.id)
  var gone: seq[int] = @[]
  for id in ui.viewPlots.keys:
    if id notin ids: gone.add id
  for id in gone: ui.viewPlots.del id

proc drawReferences*(ui: var ReferencesUi; title: string; st: AppState; t: Theme;
    marks: var Marks): ReferencesOutput =
  ## The archive window and the Generate dialog.
  result = ui.drawArchive(title, st, t, marks)
  let gen = ui.drawGenerate(st, t, marks)
  result.commands.add gen.commands
  result.commands.add drawStore(ui.fixed, st, t, marks)
