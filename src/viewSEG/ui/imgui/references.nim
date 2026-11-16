## Operations > References: the archive window, Generate a reference, and
## Store as reference (the plot's menu). The windows issue commands; they
## do not read a file.

import std/[algorithm, strutils, tables]
import imguin/cimgui
import ../../core/[references, state]
import ../../view/[curveplot, theme]
import curveplot as curves, focus, icons, marks, placement, style

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
    genLaw: ReferenceLaw
    genMessage: string
    preview: seq[float32]
    previewKey: string
    viewPlots: Table[int, tuple[time, spec: CurvePlotUi]]

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
  ui.genF1 = 8
  ui.genF2 = 80
  ui.genLength = 8000
  ui.genDt = if dtMs > 0: dtMs else: 2
  ui.genTaper0 = 200
  ui.genTaper1 = 200
  ui.genAmp = 1
  ui.genBoost = 0
  ui.genMessage = ""
  let g = GeneratedReference(law: ui.genLaw, f1Hz: ui.genF1, f2Hz: ui.genF2,
    durationMs: ui.genLength, dtMs: ui.genDt)
  setBuf(ui.genName, defaultGenerateName(g))

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
  result = igInputDouble(("##" & mark).cstring, addr v, 0, 0, "%.4g", 0)
  marks.mark(mark)

proc drawGenerate(ui: var ReferencesUi; t: Theme; marks: var Marks): ReferencesOutput =
  const id = "Generate a reference###generate-reference"
  if ui.genAsk:
    igOpenPopup_Str(id.cstring, 0)
    ui.genAsk = false
  igSetNextWindowSize(ImVec2_c(x: igGetFontSize() * 36, y: 0), ImGui_Cond_Appearing.cint)
  if not igBeginPopupModal(id.cstring, nil, ImGui_WindowFlags_AlwaysAutoResize.cint): return
  marks.markWindow("generate")
  igTextUnformatted("Name", nil)
  igSameLine(igGetFontSize() * 12, -1)
  igSetNextItemWidth(-1)
  if ui.genName.len < 160: setBuf(ui.genName, "")
  discard igInputText("##gen.name", cast[cstring](addr ui.genName[0]), csize_t(ui.genName.len),
    0, nil, nil)
  marks.mark("generate.name")
  discard number("Start Hz", ui.genF1, "generate.f1", marks)
  discard number("End Hz", ui.genF2, "generate.f2", marks)
  discard number("Length ms", ui.genLength, "generate.length", marks)
  discard number("Sample interval ms", ui.genDt, "generate.dt", marks)
  discard number("Taper start ms", ui.genTaper0, "generate.taper0", marks)
  discard number("Taper end ms", ui.genTaper1, "generate.taper1", marks)
  discard number("Amplitude", ui.genAmp, "generate.amplitude", marks)
  igTextUnformatted("Sweep", nil)
  igSameLine(igGetFontSize() * 12, -1)
  if igBeginCombo("##law", lawTitle(ui.genLaw).cstring, 0):
    for law in ReferenceLaw:
      if igSelectable_Bool(lawTitle(law).cstring, law == ui.genLaw, 0, ImVec2_c(x: 0, y: 0)):
        ui.genLaw = law
    igEndCombo()
  marks.mark("generate.law")
  if ui.genLaw in {rlDbPerOctave, rlDbPerHz}:
    discard number("Boost dB", ui.genBoost, "generate.boost", marks)
  let key = $ui.genLaw & $ui.genF1 & $ui.genF2 & $ui.genLength & $ui.genDt &
    $ui.genTaper0 & $ui.genTaper1 & $ui.genAmp & $ui.genBoost
  if key != ui.previewKey:
    ui.previewKey = key
    let g = GeneratedReference(law: ui.genLaw, f1Hz: ui.genF1, f2Hz: ui.genF2,
      durationMs: ui.genLength, dtMs: ui.genDt, taperStartMs: ui.genTaper0,
      taperEndMs: ui.genTaper1, amplitude: ui.genAmp, boostDb: ui.genBoost)
    let tooLong = sweepTooLong(g)
    if tooLong.len > 0:
      ui.preview.setLen 0
      ui.genMessage = tooLong
    else:
      let shown = previewGenerate(g)
      try:
        ui.preview = generateSamples(shown)
        ui.genMessage = if shown.durationMs < g.durationMs:
            "preview of the first " & msWords(shown.durationMs) & " ms"
          else: ""
      except CatchableError as e:
        ui.preview.setLen 0
        ui.genMessage = e.msg
  if ui.preview.len > 1:
    var xs, ys: seq[float64]
    let step = max(1, ui.preview.len div 400)
    var i = 0
    while i < ui.preview.len:
      xs.add float64(i) * ui.genDt
      ys.add float64(ui.preview[i])
      inc i, step
    if ImPlot_BeginPlot("##preview", ImVec2_c(x: -1, y: igGetFontSize() * 8),
        ImPlot_Flags_NoLegend.cint or ImPlot_Flags_NoMenus.cint):
      ImPlot_SetupAxis(ImAxis_X1.cint, "ms", ImPlot_AxisFlags_AutoFit.cint)
      ImPlot_SetupAxis(ImAxis_Y1.cint, nil, ImPlot_AxisFlags_AutoFit.cint)
      ImPlot_SetupFinish()
      ImPlot_PlotLine_doublePtrdoublePtr("sweep", addr xs[0], addr ys[0], cint(xs.len), 0, 0,
        sizeof(float64).cint)
      ImPlot_EndPlot()
    marks.mark("generate.preview")
  if ui.genMessage.len > 0:
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
    igTextWrapped("%s", ui.genMessage.cstring)
    igPopStyleColor(1)
  let tooLong = sweepTooLong(GeneratedReference(law: ui.genLaw, f1Hz: ui.genF1,
    f2Hz: ui.genF2, durationMs: ui.genLength, dtMs: ui.genDt))
  if igButton("Generate", ImVec2_c(x: 0, y: 0)) and tooLong.len == 0 and
      not ui.genMessage.startsWith("a sweep of"):
    var g = GeneratedReference(name: bufText(ui.genName), law: ui.genLaw, f1Hz: ui.genF1,
      f2Hz: ui.genF2, durationMs: ui.genLength, dtMs: ui.genDt, taperStartMs: ui.genTaper0,
      taperEndMs: ui.genTaper1, amplitude: ui.genAmp, boostDb: ui.genBoost)
    if g.name.len == 0: g.name = defaultGenerateName(g)
    result.commands.add Command(kind: ckGenerateReference, refGenerate: g)
    igCloseCurrentPopup()
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
      tip(if used: "The plots use this reference. Click again for the file's own pilot."
          else: "Use this reference in the plots")
    discard igTableNextColumn()
    igBeginDisabled(e.missing or e.blocked or home.len == 0)
    if igSmallButton("View"):
      res.commands.add Command(kind: ckViewReference, refId: e.id)
    igEndDisabled()
    marks.mark(markPrefix & ".view." & $n)
    tip("Open this reference in its own window")
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
    if igRadioButton_Bool("From the file", st.chosenReference.len == 0):
      result.commands.add Command(kind: ckSelectReference, refId: "")
    marks.mark("references.fromfile")
    tip("The plots use the file's own pilot, as before")
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

proc timesOf(w: RefView): seq[float64] =
  result = newSeq[float64](w.ys.len)
  let dt = if w.dtMs > 0: w.dtMs else: 1.0
  for i in 0 ..< w.ys.len: result[i] = w.fromMs + float64(i) * dt

proc thinPair(xs, ys: seq[float64]): (seq[float64], seq[float64]) =
  if ys.len <= 4000: return (xs, ys)
  let step = max(1, ys.len div 4000)
  var i = 0
  while i < ys.len:
    result[0].add xs[min(i, xs.high)]
    result[1].add ys[i]
    inc i, step

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
        igTextWrapped("%s", w.note.cstring)
      else:
        var uis = ui.viewPlots.getOrDefault(w.id)
        let ink = t.roles[rlAccent]
        let xs = timesOf(w)
        let (tx, ty) = thinPair(xs, w.ys)
        var time = CurvePlot(xLabel: "Time (ms)", xUnit: "ms", yLabel: "Amplitude",
          xs: tx, curves: @[Curve(name: w.name, colour: ink, ys: ty)])
        discard curves.drawCurvePlot(uis.time, "reference.view.time", time, t,
          ImVec2_c(x: -1, y: igGetFontSize() * 12), $w.revision, marks)
        let (hx, hy) = thinPair(w.hz, w.amps)
        var spec = CurvePlot(xLabel: "Frequency (Hz)", xUnit: "Hz", yLabel: "Amplitude",
          xs: hx, curves: @[Curve(name: "amplitude", colour: ink, ys: hy)])
        if hy.len == 0: spec.note = "No spectrum."
        discard curves.drawCurvePlot(uis.spec, "reference.view.spectrum", spec, t,
          ImVec2_c(x: -1, y: igGetFontSize() * 12), "s" & $w.revision, marks)
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
  let gen = ui.drawGenerate(t, marks)
  result.commands.add gen.commands
