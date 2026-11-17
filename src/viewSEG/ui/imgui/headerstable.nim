## The Headers window's Trace table tab: a row per trace of the record the
## plot shows (or of the whole file), the header fields the user chose as
## columns (Columns...: the file's keys and every field of its traces, with
## a filter), sorted by a click on a column's header, the rows narrowed by
## Find to those whose field holds a value or a range, a field graphed
## along the rows above the table (Graph). Only the rows on screen are
## read, off the UI thread (`core/inspector`, `core/tracetable`); a column
## the rows are sorted, narrowed or graphed by is read whole once.
##
## The rows are linked with the plot and the map: the pointer over a row
## points at its trace (the plot and the map light it up), a click selects
## it (Ctrl + click adds or takes it away, Shift + click a range), a
## double-click shows its record in the plot; selected traces' rows are
## marked, and the trace under the plot's pointer too. A value is copied from
## its right-click menu, with its row or every row read.

import std/[math, strutils]
import imguin/cimgui
from parseSEG import SeismicKind
import ../../core/[explain, state]
import ../../view/[headerviews, theme]
import chrome, explainicon, fonts, icons, marks, style

const FindRangeExample* = "10..20"
  ## The range example, in the Find hint and in its tooltip

func findValueTip*(): string =
  ## The Find box's tooltip: the same range example as the hint.
  "Keep the rows whose field holds this value, or a value in this range (" &
    FindRangeExample & "); empty: every row"

type
  TableUi* = object
    ## The tab's own state between frames.
    view*: TableView         ## what the tab asks for (`ckInspect`)
    find: array[64, char]    ## Find's value, being typed
    chooser: array[64, char] ## the column chooser's filter
    hovered: int = -1        ## the trace id the pointer was over last, as told; -1 for none
    lastClicked: int = -1    ## the row clicked last, for Shift + click
    onScreen: (int, int)     ## the rows on screen last frame, which the graph shades

const RowMargin = 200 ## rows read on each side of those on screen

func cellText(x: float64): string =
  if x.isNaN: "" else: exactText(x)

func columnLabel(name: string; catalogue: openArray[CatalogueField]): string =
  ## A column's header: a key's label, else the field's description (its
  ## name when it has none, or the file has no such field).
  result = keyLabel(name)
  if result.len == 0:
    for c in catalogue:
      if c.name == name and c.description.len > 0: return c.description
    result = name

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc sameLineIfRoom(text: string; ems = 1.0) =
  ## On the line of the item before when `text` (and `ems` em more) fits
  ## there, else on the next.
  let edge = igGetCursorScreenPos().x + igGetContentRegionAvail().x
  let need = igCalcTextSize(text.cstring, nil, false, -1).x + igGetFontSize() * ems +
    igGetStyle().ItemSpacing.x * 2
  if edge - igGetItemRectMax().x > need: igSameLine(0, -1)

proc setFields(st: AppState; fields: seq[string]; commands: var seq[Command]) =
  var s = st.settings
  s.headers.tableFields = fields
  commands.add Command(kind: ckSettings, settings: s)

proc drawChooser(ui: var TableUi; st: AppState; answer: TableAnswer; standard: SeismicKind;
    t: Theme; marks: var Marks; commands: var seq[Command]) =
  ## Columns...: a tick per field of the file's traces (its keys first), a
  ## filter above them.
  if igButton("Columns...", ImVec2_c(x: 0, y: 0)): igOpenPopup_Str("##columns", 0)
  marks.mark("table.columns")
  tip("Choose the header fields shown as columns")
  if igBeginPopup("##columns", 0):
    marks.markWindow("table.chooser")
    igSetNextItemWidth(igGetFontSize() * 18)
    if igIsWindowAppearing(): igSetKeyboardFocusHere(0)
    discard igInputTextWithHint("##filter", "Filter fields", cast[cstring](addr ui.chooser[0]),
      csize_t(ui.chooser.len), 0, nil, nil)
    tip("Show only the fields whose name or description holds this text")
    let filter = ($cast[cstring](addr ui.chooser[0])).toLowerAscii
    igSameLine(0, -1)
    if igSmallButton("Defaults"): st.setFields(@DefaultTableFields, commands)
    marks.mark("table.chooser defaults")
    tip("The columns a trace table shows at first")
    var fields = st.settings.headers.tableFields
    var changed = false
    if igBeginChild_Str("##fields", ImVec2_c(x: igGetFontSize() * 30, y: igGetFontSize() * 24),
        0, 0):
      var group = ""
      for c in answer.catalogue:
        if filter.len == 0 or filter in c.name.toLowerAscii or
            filter in c.description.toLowerAscii:
          if c.blockName != group:
            group = c.blockName
            igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
            igTextUnformatted((if group == "keys": "Keys (as the plot and the map use them)"
              else: blockTitle(group, standard)).cstring, nil)
            igPopStyleColor(1)
          var on = c.name in fields
          if igCheckbox((c.description & "##" & c.name).cstring, addr on):
            changed = true
            if on and fields.len < MaxTableColumns: fields.add c.name
            elif not on: fields.delete(fields.find(c.name))
          marks.mark("table.field " & c.name)
          if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint):
            igSetTooltip("%s", c.name.cstring)
    igEndChild()
    if changed: st.setFields(fields, commands)
    igEndPopup()

proc drawGraph(answer: TableAnswer; label, scope: string; first, last: int; t: Theme;
    marks: var Marks) =
  ## The graphed field along the rows: each bucket's least and most, the
  ## rows on screen shaded.
  let n = answer.graphMin.len
  if n == 0 or answer.count == 0: return
  # at most a third of the room left, so that rows stay in view
  let h = max(igGetFontSize() * 3, min(igGetFontSize() * 6, igGetContentRegionAvail().y / 3))
  const flags = ImPlot_Flags_NoTitle.cint or ImPlot_Flags_NoMenus.cint or
    ImPlot_Flags_NoMouseText.cint or ImPlot_Flags_NoLegend.cint or
    ImPlot_Flags_NoBoxSelect.cint
  if ImPlot_BeginPlot("##graph", ImVec2_c(x: -1, y: h), flags):
    ImPlot_SetupAxis(ImAxis_X1.cint, "row", ImPlot_AxisFlags_NoMenus.cint)
    ImPlot_SetupAxis(ImAxis_Y1.cint, label.cstring, ImPlot_AxisFlags_NoMenus.cint or
      ImPlot_AxisFlags_AutoFit.cint)
    ImPlot_SetupAxisLimits(ImAxis_X1.cint, 0, float64(answer.count), ImPlot_Cond_Always.cint)
    ImPlot_SetupFinish()
    var xs, lo, hi: seq[float64]
    for b in 0 ..< n:
      xs.add (float64(b) + 0.5) * float64(answer.count) / float64(n)
      lo.add answer.graphMin[b]
      hi.add answer.graphMax[b]
    ImPlot_SetNextFillStyle(vec4(t.roles[rlAccent]), 0.35)
    ImPlot_PlotShaded_doublePtrdoublePtrdoublePtr("##range", addr xs[0], addr lo[0], addr hi[0],
      cint(n), 0, 0, sizeof(float64).cint)
    ImPlot_SetNextLineStyle(vec4(t.roles[rlAccent]), 1)
    ImPlot_PlotLine_doublePtrdoublePtr("##most", addr xs[0], addr hi[0], cint(n), 0, 0,
      sizeof(float64).cint)
    let dl = ImPlot_GetPlotDrawList()
    let a = ImPlot_PlotToPixels_double(float64(first), 0, ImAxis_X1.cint, ImAxis_Y1.cint)
    let b = ImPlot_PlotToPixels_double(float64(last + 1), 0, ImAxis_X1.cint, ImAxis_Y1.cint)
    let pos = ImPlot_GetPlotPos()
    let size = ImPlot_GetPlotSize()
    ImDrawList_AddRectFilled(dl, ImVec2_c(x: a.x, y: pos.y), ImVec2_c(x: max(b.x, a.x + 2),
      y: pos.y + size.y), u32(withAlpha(t.roles[rlHighlight], 50)), 0, 0)
    ImPlot_EndPlot()
    explainIcon("table.explain", pos, t, marks, explain(pkHeaderGraph, graphFacts(label, scope)))
  marks.mark("table.graph")

proc drawTraceTable*(ui: var TableUi; st: AppState; fonts: Fonts; t: Theme; marks: var Marks;
    commands: var seq[Command]) =
  ## The tab, for the file the main panel shows.
  let k = st.findPanel(MainPanel)
  let shown = if k >= 0: st.shownFile(k) else: -1
  if shown < 0:
    igTextDisabled("No file is shown.")
    return
  let ses = st.sessions[shown]
  let settings = st.settings.headers
  ui.view.fields = settings.tableFields
  ui.view.scope = settings.tableScope
  template answer: untyped = st.inspection.answer.table
  # Rows: the record or the file; the columns; the graph.
  igAlignTextToFramePadding()
  igTextUnformatted("Rows", nil)
  for s in TableScope:
    igSameLine(0, -1)
    if igRadioButton_Bool((if s == tsRecord: "The record shown" else: "The whole file").cstring,
        settings.tableScope == s) and settings.tableScope != s:
      var x = st.settings
      x.headers.tableScope = s
      commands.add Command(kind: ckSettings, settings: x)
      ui.view.rows = 0 .. -1
    marks.mark("table.scope " & $s)
    tip(if s == tsRecord: "Show one row per trace of the record shown"
        else: "Show one row per trace of the whole file")
  sameLineIfRoom("Columns...", 2)
  ui.drawChooser(st, answer, ses.facts.summary.standard, t, marks, commands)
  sameLineIfRoom("Graph: Receiver point")
  igSetNextItemWidth(igGetFontSize() * 12)
  let graphLabel = if ui.view.graph.len == 0: "No graph"
                   else: "Graph: " & columnLabel(ui.view.graph, answer.catalogue)
  if igBeginCombo("##graph", graphLabel.cstring, 0):
    if igSelectable_Bool("No graph", ui.view.graph.len == 0, 0, ImVec2_c(x: 0, y: 0)):
      ui.view.graph = ""
    marks.mark("table.graph none")
    for f in ui.view.fields:
      if igSelectable_Bool(("Graph: " & columnLabel(f, answer.catalogue) & "##" & f).cstring,
          ui.view.graph == f, 0, ImVec2_c(x: 0, y: 0)):
        ui.view.graph = f
      marks.mark("table.graph " & f)
    igEndCombo()
  marks.mark("table.graph choice")
  tip("A column drawn along the rows above the table, in the order shown")
  # Find: a column and a value or a range.
  igAlignTextToFramePadding()
  igTextUnformatted("Find", nil)
  igSameLine(0, -1)
  if ui.view.findField.len > 0 and ui.view.findField notin ui.view.fields:
    ui.view.findField = ""
  if ui.view.findField.len == 0 and ui.view.fields.len > 0: ui.view.findField = ui.view.fields[0]
  igSetNextItemWidth(igGetFontSize() * 10)
  if igBeginCombo("##findfield", columnLabel(ui.view.findField, answer.catalogue).cstring, 0):
    for f in ui.view.fields:
      if igSelectable_Bool((columnLabel(f, answer.catalogue) & "##" & f).cstring,
          ui.view.findField == f, 0, ImVec2_c(x: 0, y: 0)):
        ui.view.findField = f
      marks.mark("table.find field " & f)
    igEndCombo()
  marks.mark("table.find field")
  igSameLine(0, -1)
  igSetNextItemWidth(igGetFontSize() * 10)
  discard igInputTextWithHint("##findvalue", ("a value, or " & FindRangeExample).cstring,
    cast[cstring](addr ui.find[0]), csize_t(ui.find.len), 0, nil, nil)
  marks.mark("table.find value")
  tip(findValueTip())
  let typed = $cast[cstring](addr ui.find[0])
  if typed != ui.view.findValue:
    ui.view.findValue = typed
    ui.view.rows = 0 .. -1
  let finding = parseFind(typed).valid
  if typed.strip.len > 0:
    igSameLine(0, -1)
    if igSmallButton("Clear##find"):
      zeroMem(addr ui.find[0], ui.find.len)
      ui.view.findValue = ""
    marks.mark("table.find clear")
  # What the answer is of: this open, and this view's columns, scope, order
  # and Find. Another open of the same file is not current: "Reading..."
  # until its rows arrive.
  let gather = st.panels[k].layers[0].source.gather
  let wanted = if settings.tableScope == tsFile: 0 ..< ses.len
               elif gather in 0 ..< ses.gathers.len: ses.gathers[gather].traces
               else: 0 .. -1
  let current = answer.isAnswerOf(ses.path, int(ses.id), wanted, ui.view)
  let count = if current: answer.count else: 0
  let words = if not current: (if st.inspection.waiting: "Reading..." else: "")
              elif finding: grouped(count) & " of " & grouped(answer.traces.len) & " traces"
              elif typed.strip.len > 0: "not a number nor a range"
              else: grouped(count) & (if count == 1: " trace" else: " traces")
  sameLineIfRoom(words)
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextUnformatted(words.cstring, nil)
  igPopStyleColor(1)
  marks.mark("table.count")
  for p in answer.problems:
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
    igPushTextWrapPos(0)
    igTextUnformatted(p.cstring, nil)
    igPopTextWrapPos()
    igPopStyleColor(1)
  # The graph, above the rows.
  var visible = (a: ui.view.rows.a + RowMargin, b: ui.view.rows.a + RowMargin)
  # The table: the trace's number, then the columns.
  let n = 1 + ui.view.fields.len
  const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
    ImGui_TableFlags_ScrollX.cint or ImGui_TableFlags_Resizable.cint or
    ImGui_TableFlags_BordersInnerV.cint or ImGui_TableFlags_SizingFixedFit.cint or
    ImGui_TableFlags_Sortable.cint
  if current and ui.view.graph.len > 0:
    drawGraph(answer, columnLabel(ui.view.graph, answer.catalogue),
      (if settings.tableScope == tsRecord: "the record shown" else: "the whole file"),
      ui.onScreen[0], ui.onScreen[1], t, marks)
  # (one ID whatever the columns: the sort stays when a column is added)
  if not igBeginTable("##tracetable", cint(n), flags, ImVec2_c(x: 0, y: 0), 0):
    return
  igTableSetupScrollFreeze(1, 1)
  igTableSetupColumn("#", ImGui_TableColumnFlags_DefaultSort.cint or
    ImGui_TableColumnFlags_NoHide.cint, igGetFontSize() * 5, 0)
  for c, f in ui.view.fields:
    igTableSetupColumn((columnLabel(f, answer.catalogue) & "##" & f).cstring, 0, 0,
      ImGuiID(1 + c))
  igPushItemFlag(ImGui_ItemFlags_NoTabStop.cint, true)
  igTableNextRow(ImGui_TableRowFlags_Headers.cint, 0)
  for c in 0 ..< n:
    if igTableSetColumnIndex(cint(c)):
      let name = igTableGetColumnName_Int(cint(c))
      fonts.withFont(frHeading, 0):
        igTableHeader(name)
      if c > 0:
        marks.mark("table.header " & ui.view.fields[c - 1])
        if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint):
          igSetTooltip("%s", (ui.view.fields[c - 1] & "\nClick to sort by it").cstring)
  igPopItemFlag()
  let specs = igTableGetSortSpecs()
  if specs != nil and specs.SpecsCount > 0 and specs.SpecsDirty:
    let spec = specs.Specs[]
    let c = int(spec.ColumnUserID)
    ui.view.sortBy = if c in 1 .. ui.view.fields.len: ui.view.fields[c - 1] else: ""
    ui.view.descending = spec.SortDirection == ImGui_SortDirection_Descending
    specs.SpecsDirty = false
    ui.view.rows = 0 .. -1
  let selectedBg = u32(withAlpha(t.roles[rlSelected], 70))
  let pointedBg = u32(withAlpha(t.roles[rlHighlight], 60))
  var over = -1
  igPushItemFlag(ImGui_ItemFlags_NoTabStop.cint, true)
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(count), -1)
  var seen = false
  while ImGuiListClipper_Step(clipper):
    # the rows on screen: the clipper's largest step (others measure a row,
    # or bring in one asked for)
    if not seen or clipper.DisplayEnd - clipper.DisplayStart > visible.b - visible.a + 1:
      visible = (int(clipper.DisplayStart), int(clipper.DisplayEnd) - 1)
      seen = true
    for row in clipper.DisplayStart ..< clipper.DisplayEnd:
      let r = row - answer.first
      let read = r in 0 ..< answer.rowTraces.len
      let trace = if read: answer.rowTraces[r] else: -1
      let id = if trace >= 0: ses.base + trace else: -1
      igTableNextRow(0, 0)
      igPushID_Int(cint(row))
      if id >= 0 and id in st.selection.selected:
        igTableSetBgColor(ImGui_TableBgTarget_RowBg1.cint, selectedBg, -1)
        if row < 400: marks.mark("table.selected " & $row)
      elif id >= 0 and id == st.selection.hover:
        igTableSetBgColor(ImGui_TableBgTarget_RowBg1.cint, pointedBg, -1)
        if row < 400: marks.mark("table.pointed " & $row)
      discard igTableNextColumn()
      let (hasF, filt) = if trace >= 0: st.ownAt(ses.path, trace) else: (false, OwnFilter())
      let killed = trace >= 0 and st.hasEditAt(ses.path, trace, teKilled)
      let reversed = trace >= 0 and st.hasEditAt(ses.path, trace, teReversed)
      var number = if trace >= 0: $(trace + 1) else: ""
      if killed: number.add " K"
      if reversed: number.add " R"
      if hasF: number.add " " & IconFilter
      if igSelectable_Bool((number & "##row").cstring, false,
          ImGui_SelectableFlags_SpanAllColumns.cint or
          ImGui_SelectableFlags_AllowDoubleClick.cint, ImVec2_c(x: 0, y: 0)) and id >= 0:
        let io = igGetIO_Nil()
        if igIsMouseDoubleClicked_Nil(ImGui_MouseButton_Left.cint):
          commands.add Command(kind: ckShowTrace, panel: MainPanel, path: ses.path,
            traceIndex: trace, recordIndex: -1)
        elif io.KeyShift and ui.lastClicked >= 0:
          var ids: seq[int]
          for x in min(ui.lastClicked, row) .. max(ui.lastClicked, row):
            let y = x - answer.first
            if y in 0 ..< answer.rowTraces.len: ids.add ses.base + answer.rowTraces[y]
          commands.add Command(kind: ckSelect, traces: ids, mode: smReplace)
        else:
          commands.add Command(kind: ckSelect, traces: @[id],
            mode: (if io.KeyCtrl: smToggle else: smReplace))
          ui.lastClicked = row
      if igIsItemHovered(0) and id >= 0: over = id
      if hasF and igIsItemHovered(0):
        let words = filterWords(filt)
        igSetTooltip("%s", words.cstring)
        if row < 400: marks.mark("table.filter tip " & words)
      if hasF and row < 400: marks.mark("table.filter " & $row)
      if row < 400: marks.mark("table.row " & $row)
      if id >= 0 and igBeginPopupContextItem("##rowmenu", ImGui_PopupFlags_MouseButtonRight.cint):
        marks.markWindow("table.menu")
        var labels: seq[string]
        for f in ui.view.fields: labels.add columnLabel(f, answer.catalogue)
        if igMenuItem_Bool("Copy the row", nil, false, true):
          igSetClipboardText(traceTableText(labels, answer, r .. r).cstring)
        if igMenuItem_Bool(("Copy the rows read (" & $answer.rowTraces.len & ")").cstring, nil,
            false, true):
          igSetClipboardText(traceTableText(labels, answer).cstring)
        marks.mark("table.copy rows")
        igEndPopup()
      fonts.withFont(frMono, 0):
        for c in 0 ..< ui.view.fields.len:
          if igTableNextColumn() and read and c < answer.values[r].len:
            let v = cellText(answer.values[r][c])
            rightAlign(v)
            igTextUnformatted(v.cstring, nil)
            if row < 400 and c < 8: marks.mark("table.cell " & $row & " " & $c)
      igPopID()
  ImGuiListClipper_End(clipper)
  ImGuiListClipper_destroy(clipper)
  igPopItemFlag()
  igEndTable()
  marks.mark("table")
  # The rows read: those on screen and `RowMargin` on each side, asked for
  # again when the rows on screen come near the edge of those read.
  if seen:
    ui.onScreen = (visible.a, visible.b)
    let edge = RowMargin div 4
    if visible.a < ui.view.rows.a + edge and ui.view.rows.a > 0 or
        visible.b > ui.view.rows.b - edge and ui.view.rows.b < count - 1 or
        ui.view.rows.b < ui.view.rows.a:
      ui.view.rows = max(0, visible.a - RowMargin) .. visible.b + RowMargin
  elif ui.view.rows.b < ui.view.rows.a:
    ui.view.rows = 0 .. 2 * RowMargin
  # The pointer over a row points at its trace, as the plot's does.
  if over != ui.hovered and (over >= 0 or ui.hovered >= 0):
    commands.add Command(kind: ckHover, trace: over)
    ui.hovered = over
