## Operations > References: the archive window, Generate a reference, and
## Store as reference (the plot's menu). The windows issue commands; they
## do not read a file.

import std/[algorithm, math, strutils, tables]
import imguin/cimgui
import ../../core/[explain, references, state]
import ../../view/[curveplot, theme]
import curveplot as curves, explainicon, focus, genpreview, icons, marks, placement, style

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
    genAsk: bool
    genName: string
    genF1, genF2, genLength, genDt, genTaper0, genTaper1, genAmp, genBoost: float64
    genPhase: float64
    genParam: float64
    genLaw: ReferenceLaw
    genShape: TaperShape
    genMessage: string
    genSource: int          ## 0: the sweep settings; 1: a trace of the record
    autoName: string        ## the name the dialog filled in last (replaced while it is not edited)
    pilotAux: bool
    pilotN, pilotStart, pilotLength: float64
    pilotAsked: string      ## the pilot ask last sent
    pilotLive: string
    pilotStable: int
    pilotLengthFilled: bool ## the whole trace was put in Length once; a later edit stands
    pilotGen: int           ## the preview's picture this dialog copied last
    fixed: StoreDialog      ## Store this pilot as a fixed reference, from a pilot's window
    previewSamples: seq[float32]
    previewHz, previewDb: seq[float64]
    previewDt, askedDt: float64
    previewF1, previewF2: float64
    previewKey: string      ## the settings the dialog is showing a key for
    askedKey: string        ## the settings last sent to the worker
    liveKey: string
    stable: int             ## frames the settings have stayed put
    askedGen, shownGen: int
    signalPlot, spectrumPlot: CurvePlotUi
    viewPlots: Table[int, tuple[time, spec: CurvePlotUi, ys: seq[float32], rev: int]]

  StoreDialog* = object
    ask: bool
    wasOpen: bool
    trace: int
    name: string
    fromMs, toMs, durationMs: float64
    sweep: bool
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
  ui.genSource = 0
  ui.pilotAux = true
  ui.pilotN = 1
  ui.pilotStart = 0
  ui.pilotLength = 0
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

proc openStore*(d: var StoreDialog; trace: int; name: string; fromMs, toMs, durationMs: float64;
    sweep: bool) =
  d.ask = true
  d.trace = trace
  setBuf(d.name, name)
  (d.fromMs, d.toMs, d.durationMs, d.sweep) = (fromMs, toMs, durationMs, sweep)
  d.message = ""

proc number(label: string; v: var float64; mark: string; marks: var Marks): bool =
  igTextUnformatted(label.cstring, nil)
  igSameLine(igGetFontSize() * 12, -1)
  igSetNextItemWidth(igGetFontSize() * 8)
  let fmt = plainFieldFormat(v)
  result = igInputDouble(("##" & mark).cstring, addr v, 0, 0, fmt.cstring, 0)
  marks.mark(mark)

proc asked(ui: ReferencesUi): GeneratedReference =
  GeneratedReference(name: bufText(ui.genName), law: ui.genLaw, f1Hz: ui.genF1,
    f2Hz: ui.genF2, durationMs: ui.genLength, dtMs: ui.genDt, taperStartMs: ui.genTaper0,
    taperEndMs: ui.genTaper1, taperShape: ui.genShape, taperParam: ui.genParam,
    phaseDeg: ui.genPhase, amplitude: ui.genAmp, boostDb: ui.genBoost)

func pilotRule(ui: ReferencesUi): PilotRule =
  PilotRule(name: bufText(ui.genName), aux: ui.pilotAux,
    trace: (if ui.pilotN.isNaN or abs(ui.pilotN) > 1e9: 0 else: int(ui.pilotN)),
    startMs: ui.pilotStart, spanMs: ui.pilotLength)

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
    explainIcon("generate.explain", o.plotPos, t, marks, explain(pkGenerateSignal, facts))
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
    explainIcon("generate.explain 2", o.plotPos, t, marks,
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
      ui.previewF1 = g.f1Hz
      ui.previewF2 = g.f2Hz
    elif problem.len == 0:
      ui.genMessage = ready.problem
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
  # font×62 holds the settings, including the optional boost and parameter,
  # both plots and the buttons. The buttons are drawn under a child that
  # takes the rest, so they stay inside at any size.
  igSetNextWindowSize(ImVec2_c(x: font * 46, y: font * 64), ImGui_Cond_FirstUseEver.cint)
  igSetNextWindowSizeConstraints(ImVec2_c(x: font * 36, y: font * 62),
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
      "trace is filled in while a file is open.")
  var g = GeneratedReference()
  var rule = PilotRule()
  var problem = ""
  var key = ""
  if ui.genSource == 0:
    g = ui.asked
    key = settingsKey(g)
    problem = generateProblem(g)
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
  let plotH = max(1'f32, (room - spacing) / 2)
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
  let open = igBeginPopupModal(id.cstring, nil, ImGui_WindowFlags_AlwaysAutoResize.cint)
  if d.wasOpen and not open:
    # The modal had the keys. Give them back to the plot, which this is drawn from.
    igSetWindowFocus_Nil()
  d.wasOpen = open
  if not open: return
  marks.markWindow("store")
  igTextWrapped("%s", "The stored samples are the file's raw samples: no plot filters, " &
    "no trace filter, no gain, no polarity edit.")
  marks.mark("store.raw")
  igTextUnformatted("Name", nil)
  igSameLine(igGetFontSize() * 8, -1)
  igSetNextItemWidth(igGetFontSize() * 22)
  if d.name.len < 160: setBuf(d.name, "")
  discard igInputText("##store.name", cast[cstring](addr d.name[0]), csize_t(d.name.len),
    0, nil, nil)
  marks.mark("store.name")
  igTextUnformatted("From ms", nil)
  igSameLine(igGetFontSize() * 8, -1)
  discard igInputDouble("##store.from", addr d.fromMs, 0, 0, "%.4g", 0)
  marks.mark("store.from")
  igTextUnformatted("To ms", nil)
  igSameLine(igGetFontSize() * 8, -1)
  discard igInputDouble("##store.to", addr d.toMs, 0, 0, "%.4g", 0)
  marks.mark("store.to")
  let length = "Trace length " & msWords(d.durationMs) & " ms" &
    (if d.sweep: " (To is the sweep length from the file's headers; the rest is listen time)"
      else: " (usually cut to the sweep length; the rest is listen time)")
  igTextWrapped("%s", length.cstring)
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
        trace: d.trace, fromMs: d.fromMs, toMs: d.toMs))
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

proc drawRows(ui: var ReferencesUi; index: ReferenceIndex; home: string; writable: bool;
    chosen: string; st: AppState; marks: var Marks; res: var ReferencesOutput;
    markPrefix: string) =
  let order = orderOf(index, ui.sort, ui.descending)
  for n, i in order:
    let e = index.entries[i]
    igPushID_Str(e.id.cstring)
    igTableNextRow(0, 0)
    discard igTableNextColumn()
    if ui.renameId == e.id and writable:
      if ui.rename.len < 160: setBuf(ui.rename, e.name)
      igSetNextItemWidth(-1)
      let enter = igInputText("##rename", cast[cstring](addr ui.rename[0]),
        csize_t(ui.rename.len), ImGui_InputTextFlags_EnterReturnsTrue.cint, nil, nil)
      marks.mark(markPrefix & ".rename")
      if enter:
        let name = bufText(ui.rename).strip
        let problem = index.nameProblem(name)
        if problem.len == 0 or index.findName(name) == i:
          res.commands.add Command(kind: ckRenameReference, refId: e.id, refNewName: name)
          ui.renameId = ""
          ui.renameProblem = ""
        else:
          ui.renameId = e.id
          ui.renameProblem = problem
    elif igSelectable_Bool(e.name.cstring, e.id == chosen,
        ImGui_SelectableFlags_SpanAllColumns.cint, ImVec2_c(x: 0, y: 0)):
      if writable:
        ui.renameId = e.id
        setBuf(ui.rename, e.name)
    marks.mark(markPrefix & ".row." & $n)
    tip(if e.missing: "its SEG-Y file is missing" else: e.name)
    discard igTableNextColumn()
    igTextUnformatted(lengthText(e).cstring, nil)
    discard igTableNextColumn()
    igTextUnformatted(intervalText(e).cstring, nil)
    discard igTableNextColumn()
    igTextUnformatted(frequencyText(e).cstring, nil)
    discard igTableNextColumn()
    igTextUnformatted(sourceText(e).cstring, nil)
    discard igTableNextColumn()
    igTextUnformatted(e.date.cstring, nil)
    discard igTableNextColumn()
    if writable:
      let used = e.id == chosen
      if igRadioButton_Bool("##use", used):
        res.commands.add Command(kind: ckSelectReference, refId: (if used: "" else: e.id))
      marks.mark(markPrefix & ".use." & $n)
      tip(if used: "The plots use this reference. Click again for none."
          else: "Use this reference in the plots")
    discard igTableNextColumn()
    igBeginDisabled(e.missing or e.blocked or home.len == 0)
    if igSmallButton("View"):
      res.commands.add Command(kind: ckViewReference, refId: e.id)
    igEndDisabled()
    marks.mark(markPrefix & ".view." & $n)
    tip(if e.isPilot: "Open the pilot of the record on show in its own window"
        else: "Open this reference in its own window")
    igSameLine(0, -1)
    igBeginDisabled(e.missing or e.blocked or e.isPilot)
    if igSmallButton("Compare as A"):
      res.commands.add Command(kind: ckSetCompare, compareSlot: cwA, compareRef: e.id,
        compareTrace: -1)
    igEndDisabled()
    marks.mark(markPrefix & ".compareA." & $n)
    tip(if e.isPilot: "A trace of each record is not one waveform: view it, and store it " &
          "as a fixed reference first" else: "Copy this reference into compare slot A")
    igSameLine(0, -1)
    igBeginDisabled(e.missing or e.blocked or e.isPilot)
    if igSmallButton("Compare as B"):
      res.commands.add Command(kind: ckSetCompare, compareSlot: cwB, compareRef: e.id,
        compareTrace: -1)
    igEndDisabled()
    marks.mark(markPrefix & ".compareB." & $n)
    tip(if e.isPilot: "A trace of each record is not one waveform: view it, and store it " &
          "as a fixed reference first" else: "Copy this reference into compare slot B")
    if writable:
      igSameLine(0, -1)
      if igSmallButton("Delete"):
        ui.confirmId = e.id
        ui.confirmAsk = true
      marks.mark(markPrefix & ".delete." & $n)
    else:
      igSameLine(0, -1)
      if igSmallButton("Copy into the project"):
        res.commands.add Command(kind: ckCopyReference, refId: e.id)
      marks.mark(markPrefix & ".copy." & $n)
      tip("Copy this reference into the project")
    igPopID()

proc drawArchive(ui: var ReferencesUi; title: string; st: AppState; t: Theme;
    marks: var Marks): ReferencesOutput =
  if not ui.shown: return
  let vp = igGetMainViewport()
  if ui.placeAgain or ui.bringUp:
    igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + 40, y: vp.WorkPos.y + 40),
      ImGui_Cond_Always.cint, ImVec2_c(x: 0, y: 0))
    igSetNextWindowSize(ImVec2_c(x: min(vp.WorkSize.x - 80, igGetFontSize() * 72),
      y: igGetFontSize() * 22), ImGui_Cond_Always.cint)
    ui.placeAgain = false
  if ui.bringUp:
    igSetWindowFocus_Str(title.cstring)
    ui.bringUp = false
  var open = true
  if igBegin(title.cstring, addr open, ImGui_WindowFlags_NoDocking.cint):
    ui.focus.watch()
    marks.markWindow("references")
    let which = referenceArchiveTitle(st)
    igTextUnformatted(("Showing the " & which & " archive.").cstring, nil)
    marks.mark("references.which")
    if not st.referencesLoaded: igTextDisabled("Reading...")
    for p in st.references.problems:
      igTextWrapped("%s", p.cstring)
    if igRadioButton_Bool(NoneChoiceLabel, st.chosenReference.len == 0):
      result.commands.add Command(kind: ckSelectReference, refId: "")
    marks.mark("references.none")
    tip(NoneChoiceTip)
    let writable = not (st.inProject and st.project.readOnly)
    const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_Borders.cint or
      ImGui_TableFlags_ScrollY.cint or ImGui_TableFlags_Resizable.cint or
      ImGui_TableFlags_Sortable.cint
    let height = igGetFontSize() * 12
    if igBeginTable("##refs", 8, flags, ImVec2_c(x: 0, y: height), 0):
      igTableSetupScrollFreeze(0, 1)
      igTableSetupColumn("Name", ImGui_TableColumnFlags_WidthStretch.cint, 0, 0)
      igTableSetupColumn("Length", ImGui_TableColumnFlags_WidthFixed.cint, 0, 1)
      igTableSetupColumn("Sample interval", ImGui_TableColumnFlags_WidthFixed.cint, 0, 2)
      igTableSetupColumn("Frequency", ImGui_TableColumnFlags_WidthFixed.cint, 0, 3)
      igTableSetupColumn("Source", ImGui_TableColumnFlags_WidthStretch.cint, 0, 4)
      igTableSetupColumn("Date", ImGui_TableColumnFlags_WidthFixed.cint, 0, 5)
      igTableSetupColumn("Use", ImGui_TableColumnFlags_NoSort.cint or
        ImGui_TableColumnFlags_WidthFixed.cint, 0, 6)
      igTableSetupColumn("", ImGui_TableColumnFlags_NoSort.cint or
        ImGui_TableColumnFlags_WidthFixed.cint, 0, 7)
      igTableHeadersRow()
      let specs = igTableGetSortSpecs()
      if specs != nil and specs.SpecsCount > 0:
        let s = specs.Specs[]
        ui.sort = RefSort(clamp(int(s.ColumnIndex), 0, 5))
        ui.descending = s.SortDirection == ImGui_SortDirection_Descending
        specs.SpecsDirty = false
      ui.drawRows(st.references, st.referencesHome, writable, st.chosenReference, st, marks,
        result, "references")
      igEndTable()
    if ui.renameProblem.len > 0:
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
      igTextWrapped("%s", ui.renameProblem.cstring)
      igPopStyleColor(1)
      marks.mark("references.rename.problem")
    if st.inProject:
      if igCollapsingHeader_TreeNodeFlags("Main archive".cstring, 0):
        marks.mark("references.main")
        igTextDisabled("Read-only. Copy one into the project to use it.")
        if st.mainReferences.entries.len == 0: igTextDisabled("The main archive is empty.")
        elif igBeginTable("##mainrefs", 8, flags, ImVec2_c(x: 0, y: igGetFontSize() * 8), 0):
          igTableSetupColumn("Name", 0, 0, 0)
          igTableSetupColumn("Length", 0, 0, 1)
          igTableSetupColumn("Sample interval", 0, 0, 2)
          igTableSetupColumn("Frequency", 0, 0, 3)
          igTableSetupColumn("Source", 0, 0, 4)
          igTableSetupColumn("Date", 0, 0, 5)
          igTableSetupColumn("Use", ImGui_TableColumnFlags_NoSort.cint, 0, 6)
          igTableSetupColumn("", ImGui_TableColumnFlags_NoSort.cint, 0, 7)
          igTableHeadersRow()
          ui.drawRows(st.mainReferences, "", false, "", st, marks, result, "references.main")
          igEndTable()
  igEnd()
  if not open: ui.shown = false
  if ui.confirmAsk:
    igOpenPopup_Str("Delete this reference?###refs.confirm", 0)
    ui.confirmAsk = false
  if igBeginPopupModal("Delete this reference?###refs.confirm", nil,
      ImGui_WindowFlags_AlwaysAutoResize.cint):
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
  if ys.len <= 4000: return (xs, ys)
  let step = max(1, ys.len div 4000)
  var i = 0
  while i < ys.len:
    result[0].add xs[min(i, xs.high)]
    result[1].add ys[i]
    inc i, step

proc pilotLine(w: RefView): string =
  ## What a pilot of the record's window says of where it is from.
  "From " & (if w.record.len > 0: w.record else: "the record on show") & ", " &
    pilotWords(w.pilot.aux, w.pilot.trace) & ", " & msWords(w.pilot.startMs) & " to " &
    msWords(w.pilot.startMs + w.pilot.spanMs) & " ms. Another record has its own pilot."

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
              w.pilotTo, w.pilotTraceMs, false)
          marks.mark("reference.view.fix")
          tip("Saves this record's cut pilot as an ordinary stored waveform: the file's " &
            "raw samples, as Store does (not turned over, not filtered)")
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
        explainIcon("reference.view.explain", ot.plotPos, t, marks,
          explain(pkReferenceSignal, refViewFacts(w)))
        let (hx, hy) = thinPair(w.hz, w.amps)
        var spec = CurvePlot(xLabel: "Frequency (Hz)", xUnit: "Hz", yLabel: "Amplitude",
          xs: hx, curves: @[Curve(name: "amplitude", colour: ink, ys: hy)], legend: false,
          roomRight: true)
        if hy.len == 0: spec.note = "No spectrum."
        let os = curves.drawCurvePlot(uis.spec, "reference.view.spectrum", spec, t,
          ImVec2_c(x: -1, y: igGetFontSize() * 12), "s" & $w.revision, marks)
        explainIcon("reference.view.explain 2", os.plotPos, t, marks,
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
