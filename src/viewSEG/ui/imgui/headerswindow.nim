## The "Headers" window: what the file shown is and what its headers hold,
## in three tabs (`HeadersTab`), read-only.
##
## - **Summary:** what the file is (its standard, sample format, counts,
##   timing, coordinates) and the record shown with its counts, in plain
##   words (`view/headerviews.summaryLines`).
## - **File headers:** a tab per header block, as the format has them. SEG-Y:
##   Text (the textual header's 40 lines of 80 characters, in the fixed-width
##   font), Binary (its fields), Extended (the extended textual headers, when
##   the file has them), and a tape label or a data trailer when there is
##   one. SEG-D, of the record shown: General (its general headers),
##   Channel sets (their descriptors side by side), and the skew, extended,
##   external headers and trailer the record has. SEG-2: File (its file
##   descriptor block). A table lists each field's description, name, bytes
##   and file offset (the columns shown are chosen in its header's
##   right-click menu) and its value; a block without named fields is shown
##   as its bytes, in hexadecimal and as text. A SEG-D record's headers are
##   read off the UI thread (`core/inspector`), only while the tab shows.
##
## What is on screen is told to `core` (`ckInspect`) when it changes, so
## nothing is read for a hidden tab. The tab shown and the columns chosen
## are remembered in the settings (`Settings.headers`). A value is copied
## with Ctrl + C on its row, or from its right-click menu, which also copies
## the whole summary or table. A click that only brings the window forward
## does nothing else (`focus`); Tab moves between its controls.

import std/[strutils, tables]
import imguin/cimgui
from parseSEG import SeismicKind, skSegy, skSegd, skSeg2, skUnknown
import ../../core/state
import ../../view/[headerviews, theme]
import chrome, focus, fonts, style

type
  CachedTable = object
    key: string ## what `table` was made from
    table: FieldTable

  CachedText = object
    key: string
    text: string ## a read-only text box's buffer: kept here, as the box points into it

  HeadersUi* = object
    ## The window's own state between frames.
    focus: FocusClicks
    shownTab: HeadersTab
      ## the tab the window last showed
    selecting: bool
      ## the settings' tab is to be selected (first frame, or it changed)
    started: bool
    picked: int = -1
      ## the summary row picked (Ctrl + C copies it); -1 for none
    pickedFile: string
      ## the file it was picked in
    parts: set[InspectPart]
      ## what is on screen, as told to `core` last
    told: bool
    tables: Table[string, CachedTable]
    texts: Table[string, CachedText]
    applied: Table[string, set[HeaderColumn]] ## the columns each table was given

  HeadersOutput* = object
    commands*: seq[Command]

proc tabItem(ui: var HeadersUi; tab: HeadersTab; wanted: HeadersTab): bool =
  ## A tab of the window's tab bar; selected once when it is the settings'.
  let flags = if ui.selecting and tab == wanted: ImGui_TabItemFlags_SetSelected.cint else: 0.cint
  result = igBeginTabItem(($tab & "##" & $ord(tab)).cstring, nil, flags)

proc dim(t: Theme; text: string) =
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igPushTextWrapPos(0)
  igTextUnformatted(text.cstring, nil)
  igPopTextWrapPos()
  igPopStyleColor(1)

proc shownSession(st: AppState): (int, int) =
  ## The open file the main panel shows and its gather; (-1, -1) for none.
  let k = st.findPanel(MainPanel)
  let s = if k >= 0: st.shownFile(k) else: -1
  if s < 0: (-1, -1) else: (s, st.panels[k].layers[0].source.gather)

# ----------------------------------------------------------------- summary --

proc copyMenu(id: string; value: string; all: proc (): string) =
  ## The right-click menu of a row: copy its value, or everything.
  if igBeginPopupContextItem(id.cstring, ImGui_PopupFlags_MouseButtonRight.cint):
    if igMenuItem_Bool("Copy", "Ctrl+C", false, true): igSetClipboardText(value.cstring)
    if igMenuItem_Bool("Copy the summary", nil, false, true): igSetClipboardText(all().cstring)
    igEndPopup()

proc drawSummary(ui: var HeadersUi; st: AppState; fonts: Fonts; t: Theme; marks: var Marks) =
  ## The Summary tab: a line per fact, headings between.
  let (s, gather) = st.shownSession
  if s < 0:
    igTextDisabled("No file is shown.")
    return
  let ses = st.sessions[s]
  let lines = summaryLines(ses, gather)
  if ses.path != ui.pickedFile:
    ui.picked = -1
    ui.pickedFile = ses.path
  var labelWidth = 0'f32
  for l in lines:
    if not l.heading:
      labelWidth = max(labelWidth, igCalcTextSize(l.label.cstring, nil, false, -1).x)
  const flags = ImGui_TableFlags_ScrollY.cint or ImGui_TableFlags_RowBg.cint or
    ImGui_TableFlags_BordersInnerV.cint
  if igBeginTable("##summary", 2, flags, ImVec2_c(x: 0, y: 0), 0):
    igTableSetupColumn("What", ImGui_TableColumnFlags_WidthFixed.cint,
      labelWidth + igGetFontSize(), 0)
    igTableSetupColumn("Value", ImGui_TableColumnFlags_WidthStretch.cint, 0, 1)
    let all = proc (): string = summaryText(lines)
    for i, l in lines:
      igTableNextRow(0, 0)
      discard igTableNextColumn()
      igPushID_Int(cint(i))
      if l.heading:
        fonts.withFont(frHeading, 0):
          igTextUnformatted(l.label.cstring, nil)
        if i == 0: marks.mark("headers.summary.heading")
      else:
        igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
        if igSelectable_Bool(l.label.cstring, ui.picked == i,
            ImGui_SelectableFlags_SpanAllColumns.cint, ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
          ui.picked = i
        igPopStyleColor(1)
        copyMenu("##copy", l.value, all)
        if igIsItemFocused() and igIsKeyPressed_Bool(ImGui_Key_C, false) and
            igGetIO_Nil().KeyCtrl:
          igSetClipboardText(l.value.cstring)
        marks.mark("headers.summary " & l.label)
        discard igTableNextColumn()
        igPushTextWrapPos(0)
        igTextUnformatted(l.value.cstring, nil)
        igPopTextWrapPos()
        marks.mark("headers.summary value " & l.label)
      igPopID()
    igEndTable()
    marks.mark("headers.summary")
  if ui.picked >= 0 and ui.picked < lines.len and igGetIO_Nil().KeyCtrl and
      igIsKeyPressed_Bool(ImGui_Key_C, false) and
      igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint):
    igSetClipboardText(lines[ui.picked].value.cstring)

# ------------------------------------------------------------ header tables --

proc syncColumns(ui: var HeadersUi; id: string; st: AppState; output: var HeadersOutput) =
  ## After the table's header row (its layout is made there): the settings'
  ## columns are given to a table that has not had them (its first frame,
  ## or the settings changed), from the next frame on; a column the user
  ## showed or hid in the header's right-click menu goes into the settings.
  let want = st.settings.headers.columns
  var now: set[HeaderColumn]
  for c in HeaderColumn:
    if (igTableGetColumnFlags(cint(ord(c))) and ImGui_TableColumnFlags_IsEnabled.cint) != 0:
      now.incl c
  if id notin ui.applied or ui.applied[id] != want:
    for c in HeaderColumn: igTableSetColumnEnabled(cint(ord(c)), c in want)
    ui.applied[id] = want
  elif now != want:
    ui.applied[id] = now
    var s = st.settings
    s.headers.columns = now
    output.commands.add Command(kind: ckSettings, settings: s)
    ui.applied.clear() # the other tables are given them anew
    ui.applied[id] = now

proc valueMenu(table: FieldTable; column: int; value: string) =
  ## The right-click menu of a value: copy it, its column, or the table.
  if igBeginPopupContextItem("##value", ImGui_PopupFlags_MouseButtonRight.cint):
    if igMenuItem_Bool("Copy", "Ctrl+C", false, true): igSetClipboardText(value.cstring)
    if table.columns.len > 1 and igMenuItem_Bool(("Copy the column of " &
        table.columns[column]).cstring, nil, false, true):
      igSetClipboardText(tableText(table, column).cstring)
    if igMenuItem_Bool("Copy the table", nil, false, true):
      igSetClipboardText(tableText(table).cstring)
    igEndPopup()
  if igIsItemFocused() and igGetIO_Nil().KeyCtrl and igIsKeyPressed_Bool(ImGui_Key_C, false):
    igSetClipboardText(value.cstring)

proc drawFieldTable(ui: var HeadersUi; id: string; table: FieldTable; st: AppState;
    fonts: Fonts; t: Theme; marks: var Marks; output: var HeadersOutput; height = 0'f32) =
  ## A header table: a row per field (titles between blocks), its
  ## description, name, bytes and offset (the columns chosen), and a value
  ## column per header; values that differ between the columns in the
  ## warning colour. Only the rows in view are drawn.
  let n = int(HeaderColumn.high) + 1 + table.columns.len
  const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
    ImGui_TableFlags_ScrollX.cint or ImGui_TableFlags_Resizable.cint or
    ImGui_TableFlags_BordersInnerV.cint or ImGui_TableFlags_Hideable.cint or
    ImGui_TableFlags_SizingFixedFit.cint
  if not igBeginTable(id.cstring, cint(n), flags, ImVec2_c(x: 0, y: height), 0): return
  igTableSetupScrollFreeze(1, 1)
  # The description starts narrow enough for the values to show beside it
  # (a long one is cut, and said whole when pointed at); it can be widened.
  igTableSetupColumn(($hcDescription).cstring, ImGui_TableColumnFlags_NoHide.cint or
    ImGui_TableColumnFlags_WidthFixed.cint, 18 * igGetFontSize(), ImGuiID(ord(hcDescription)))
  for c in hcName .. HeaderColumn.high:
    igTableSetupColumn(($c).cstring, 0, 0, ImGuiID(ord(c)))
  for k, label in table.columns:
    igTableSetupColumn(label.cstring, ImGui_TableColumnFlags_NoHide.cint, 0,
      ImGuiID(100 + k))
  fonts.withFont(frHeading, 0):
    igTableHeadersRow()
  ui.syncColumns(id, st, output)
  let warning = vec4(t.roles[rlWarning])
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(table.rows.len), -1)
  while ImGuiListClipper_Step(clipper):
    for i in clipper.DisplayStart ..< clipper.DisplayEnd:
      template row: untyped = table.rows[i]
      igTableNextRow(0, 0)
      igPushID_Int(cint(i))
      if row.title.len > 0:
        igTableSetBgColor(ImGui_TableBgTarget_RowBg1.cint, u32(t.roles[rlBar]), -1)
        discard igTableSetColumnIndex(0)
        fonts.withFont(frHeading, 0):
          igTextUnformatted(row.title.cstring, nil)
      else:
        if row.differs:
          igTableSetBgColor(ImGui_TableBgTarget_RowBg1.cint, u32(withAlpha(t.roles[rlWarning], 30)),
            -1)
        if igTableSetColumnIndex(cint(ord(hcDescription))):
          igTextUnformatted(row.description.cstring, nil)
          if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint):
            igSetTooltip("%s", (row.description & "\n" & row.name & ", bytes " & row.bytes &
              (if row.differs: "\nThe values differ." else: "")).cstring)
        fonts.withFont(frMono, 0):
          igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
          if igTableSetColumnIndex(cint(ord(hcName))):
            igTextUnformatted(row.name.cstring, nil)
            if i < 40: marks.mark(id & " name " & row.name)
          if igTableSetColumnIndex(cint(ord(hcBytes))):
            rightAlign(row.bytes)
            igTextUnformatted(row.bytes.cstring, nil)
          if igTableSetColumnIndex(cint(ord(hcOffset))):
            rightAlign(row.offset)
            igTextUnformatted(row.offset.cstring, nil)
          igPopStyleColor(1)
          if row.differs: igPushStyleColor_Vec4(ImGui_Col_Text.cint, warning)
          for c, v in row.values:
            if igTableSetColumnIndex(cint(ord(HeaderColumn.high) + 1 + c)):
              igPushID_Int(cint(c))
              rightAlign(v)
              discard igSelectable_Bool((v & "##v").cstring, false, 0, ImVec2_c(x: 0, y: 0))
              valueMenu(table, c, v)
              if i < 400: marks.mark(id & " " & row.name & " " & $c)
              igPopID()
          if row.differs:
            igPopStyleColor(1)
            marks.mark(id & " differs " & row.name)
      igPopID()
  ImGuiListClipper_End(clipper)
  ImGuiListClipper_destroy(clipper)
  igEndTable()
  marks.mark(id)

proc cachedTable(ui: var HeadersUi; id, key: string; make: proc (): FieldTable): lent FieldTable =
  ## The table `id`, made again only when what it is made from (`key`) changed.
  if id notin ui.tables or ui.tables[id].key != key:
    ui.tables[id] = CachedTable(key: key, table: make())
  ui.tables[id].table

proc drawText(ui: var HeadersUi; id, key: string; lines: proc (): string; fonts: Fonts;
    marks: var Marks) =
  ## Text from the file in the fixed-width font, as its lines, scrolled both
  ## ways; Ctrl + C or the right-click menu copies it.
  if id notin ui.texts or ui.texts[id].key != key:
    ui.texts[id] = CachedText(key: key, text: lines())
  template text: untyped = ui.texts[id].text
  if igBeginChild_Str(id.cstring, ImVec2_c(x: 0, y: 0), ImGui_ChildFlags_FrameStyle.cint,
      ImGui_WindowFlags_HorizontalScrollbar.cint):
    fonts.withFont(frMono, 0):
      igTextUnformatted(cstring(text), nil)
    if igBeginPopupContextWindow("##copytext", ImGui_PopupFlags_MouseButtonRight.cint):
      if igMenuItem_Bool("Copy the text", "Ctrl+C", false, true): igSetClipboardText(text.cstring)
      igEndPopup()
    if igIsWindowFocused(0) and igGetIO_Nil().KeyCtrl and igIsKeyPressed_Bool(ImGui_Key_C, false):
      igSetClipboardText(text.cstring)
  igEndChild()
  marks.mark(id)

proc drawBytes(id: string; b: RawBlock; t: Theme; fonts: Fonts; marks: var Marks) =
  ## A block without named fields as its bytes: offset, hexadecimal, text.
  dim(t, $b.size & " bytes at offset " & $b.offset & (if b.bytes.len < b.size:
    "; the first " & $b.bytes.len & " are shown" else: "") & ".")
  if igBeginChild_Str(id.cstring, ImVec2_c(x: 0, y: 0), 0, 0):
    fonts.withFont(frMono, 0):
      let clipper = ImGuiListClipper_ImGuiListClipper()
      ImGuiListClipper_Begin(clipper, cint(dumpLines(b.bytes)), -1)
      while ImGuiListClipper_Step(clipper):
        for line in clipper.DisplayStart ..< clipper.DisplayEnd:
          igTextUnformatted(dumpLine(b.bytes, b.offset, line).cstring, nil)
          if line == 0: marks.mark(id & " line 0")
      ImGuiListClipper_End(clipper)
      ImGuiListClipper_destroy(clipper)
  igEndChild()

# ------------------------------------------------------------ file headers --

func blockIs(name, prefix: string): bool =
  name.startsWith(prefix)

proc rowsOf(rows: openArray[FieldRow]; pred: proc (r: FieldRow): bool): seq[FieldRow] =
  for r in rows:
    if pred(r): result.add r

proc subTab(name: string; marks: var Marks): bool =
  result = igBeginTabItem(name.cstring, nil, 0)
  marks.mark("headers.file tab " & name)

func tabName(blockName: string): string =
  ## A block without named fields' tab: "Extended", "External", "Skew" ...
  if blockName.startsWith("st") and blockName.endsWith("skew"):
    result = "Skew" & (if blockName == "st1skew": "" else: " " & blockName[2 .. ^5])
  else:
    result = case blockName
      of "extended": "Extended"
      of "external": "External"
      of "trailer": "Trailer"
      of "label": "Label"
      else: blockName

func setLabel(blockName: string): string =
  ## A channel set's column: "Set 3" ("st1cs3"), "Set 3 of scan type 2".
  let parts = blockName[2 .. ^1].split("cs")
  result = if parts.len != 2: blockName
           elif parts[0] == "1": "Set " & parts[1]
           else: "Set " & parts[1] & " of scan type " & parts[0]

proc drawFileHeaders(ui: var HeadersUi; st: AppState; fonts: Fonts; t: Theme;
    marks: var Marks; output: var HeadersOutput) =
  ## The File headers tab: a tab per header block of the file shown (of the
  ## record shown, for SEG-D).
  let (s, gather) = st.shownSession
  if s < 0:
    igTextDisabled("No file is shown.")
    return
  let ses = st.sessions[s] # a ref: the tables' makers keep it
  template facts: untyped = ses.facts
  let standard = facts.summary.standard
  let fileKey = $int(ses.id)
  if not igBeginTabBar("##filetabs", 0): return
  case standard
  of skSegy:
    if subTab("Text", marks):
      ui.drawText("##text", fileKey, proc (): string = facts.text.join("\n"), fonts, marks)
      igEndTabItem()
    if subTab("Binary", marks):
      let table = ui.cachedTable("headers.binary", fileKey, proc (): FieldTable =
        fieldTable([rowsOf(facts.rows, proc (r: FieldRow): bool = r.blockName == "binary")],
          ["Value"], standard))
      ui.drawFieldTable("headers.binary", table, st, fonts, t, marks, output)
      igEndTabItem()
    if facts.extendedText.len > 0 and subTab("Extended", marks):
      ui.drawText("##extended", fileKey, proc (): string =
        var parts: seq[string]
        for k, lines in facts.extendedText:
          parts.add "Extended textual header " & $(k + 1) & " of " &
            $facts.extendedText.len & "\n" & lines.join("\n")
        parts.join("\n\n"), fonts, marks)
      igEndTabItem()
  of skSegd:
    let r = st.inspection.answer.record
    let mine = st.inspection.answer.recordPath == ses.path and r.record >= 0 and
      gather in 0 ..< ses.gathers.len and
      r.record == ses.file.segdRecordOf(ses.gathers[gather].traces.a)
    if not mine:
      if subTab("General", marks):
        igTextDisabled("Reading the record's headers...")
        igEndTabItem()
    elif r.problem.len > 0 and r.rows.len == 0:
      if subTab("General", marks):
        dim(t, "The record's headers cannot be read: " & r.problem)
        igEndTabItem()
    else:
      let key = fileKey & "." & $r.record & "." & $st.inspection.answer.gen
      if subTab("General", marks):
        if r.problem.len > 0: dim(t, r.problem)
        let table = ui.cachedTable("headers.general", key, proc (): FieldTable =
          fieldTable([rowsOf(r.rows, proc (x: FieldRow): bool = x.blockName.blockIs("gh"))],
            ["Value"], standard))
        ui.drawFieldTable("headers.general", table, st, fonts, t, marks, output)
        igEndTabItem()
      var sets: seq[seq[FieldRow]]
      var labels: seq[string]
      for x in r.rows:
        if x.blockName.blockIs("st") and "cs" in x.blockName:
          if labels.len == 0 or labels[^1] != x.blockName:
            labels.add x.blockName
            sets.add @[]
          sets[^1].add x
      if sets.len > 0 and subTab("Channel sets", marks):
        let table = ui.cachedTable("headers.sets", key, proc (): FieldTable =
          var names: seq[string]
          for l in labels: names.add setLabel(l)
          fieldTable(sets, names, standard, byBlock = false))
        ui.drawFieldTable("headers.sets", table, st, fonts, t, marks, output)
        igEndTabItem()
      for b in r.raw:
        # (an untyped general header block is a row of General)
        if not b.blockName.blockIs("gh") and subTab(tabName(b.blockName), marks):
          drawBytes("headers.bytes " & b.blockName, b, t, fonts, marks)
          igEndTabItem()
  of skSeg2:
    if subTab("File", marks):
      let table = ui.cachedTable("headers.file", fileKey, proc (): FieldTable =
        fieldTable([facts.rows], ["Value"], standard))
      ui.drawFieldTable("headers.file", table, st, fonts, t, marks, output)
      igEndTabItem()
  of skUnknown: discard
  if standard != skSeg2:
    for b in facts.raw:
      if b.blockName notin ["text", "extended"] and subTab(tabName(b.blockName), marks):
        drawBytes("headers.bytes " & b.blockName, b, t, fonts, marks)
        igEndTabItem()
  igEndTabBar()

# ------------------------------------------------------------------ window --

proc drawHeaders*(ui: var HeadersUi; title: string; st: AppState; fonts: Fonts; t: Theme;
    marks: var Marks): HeadersOutput =
  ## The window, docked or floating like any other, titled `title` (its
  ## ImGui ID stays `###headers`), for the file the main panel shows.
  let view = st.settings.headers
  if not ui.started or view.tab != ui.shownTab:
    ui.selecting = true
    ui.started = true
  var parts: set[InspectPart]
  if igBegin(title.cstring, nil, 0):
    ui.focus.watch()
    marks.markWindow("headers")
    if igBeginTabBar("##headerstabs", 0):
      var shown = ui.shownTab
      if ui.tabItem(htSummary, view.tab):
        shown = htSummary
        marks.mark("headers.tab summary")
        ui.drawSummary(st, fonts, t, marks)
        igEndTabItem()
      else: marks.mark("headers.tab summary")
      if ui.tabItem(htFile, view.tab):
        shown = htFile
        marks.mark("headers.tab file")
        parts.incl ipRecord
        ui.drawFileHeaders(st, fonts, t, marks, result)
        igEndTabItem()
      else: marks.mark("headers.tab file")
      if ui.tabItem(htTrace, view.tab):
        shown = htTrace
        marks.mark("headers.tab trace")
        igTextDisabled("The headers and samples of the selected traces.")
        igEndTabItem()
      else: marks.mark("headers.tab trace")
      igEndTabBar()
      if ui.selecting:
        ui.selecting = false
        ui.shownTab = view.tab
      elif shown != ui.shownTab:
        ui.shownTab = shown
        var s = st.settings
        s.headers.tab = shown
        result.commands.add Command(kind: ckSettings, settings: s)
    ui.focus.settle()
  igEnd()
  if parts != ui.parts or not ui.told:
    ui.parts = parts
    ui.told = true
    result.commands.add Command(kind: ckInspect, inspect: parts)
