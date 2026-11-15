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
## nothing is read for a hidden tab; when its reader does not answer (a
## drive that is slow or gone), a line above the tabs says so, and the tabs
## keep what was read before. The tab shown and the columns chosen
## are remembered in the settings (`Settings.headers`). A value is copied
## with Ctrl + C on its row, or from its right-click menu, which also copies
## the whole summary or table. A click that only brings the window forward
## does nothing else (`focus`); Tab moves between its controls.

import std/[math, monotimes, strutils, tables, times]
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
    pickedIn: string
      ## the file and gather it was picked in
    summary: seq[SummaryLine] ## the Summary's lines, made at most twice a second
    summaryKey: string ## what they were made of
    summaryAt: MonoTime ## when
    parts: set[InspectPart]
      ## what is on screen, as told to `core` last
    shownTraceTab: TraceTab
      ## the Trace tab's own tab the window last showed
    selectingTrace: bool
      ## the settings' Trace tab is to be selected
    told: bool
    tables: Table[string, CachedTable]
    texts: Table[string, CachedText]
    applied: Table[string, set[HeaderColumn]] ## the columns each table was given
    setsPage: int ## the page of the Channel sets tab's columns shown
    widths: Table[string, float32]
      ## per table, the window's width its description was last fitted to
    sets: int ## how many channel sets the record shown has

  HeadersOutput* = object
    commands*: seq[Command]

const JoinedTip = "From the survey, not the trace header"
  ## what a value a geometry join gave says when pointed at, as in the plot

func summaryPicked*(ui: HeadersUi): int {.inline.} =
  ## The Summary line picked (Ctrl + C copies it); -1 for none (for tests).
  ui.picked

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

proc copyMenu(id: string; value: string; lines: openArray[SummaryLine]) =
  ## The right-click menu of a row: copy its value, or every line.
  if igBeginPopupContextItem(id.cstring, ImGui_PopupFlags_MouseButtonRight.cint):
    if igMenuItem_Bool("Copy", "Ctrl+C", false, true): igSetClipboardText(value.cstring)
    if igMenuItem_Bool("Copy the summary", nil, false, true):
      igSetClipboardText(summaryText(lines).cstring)
    igEndPopup()

proc drawSummary(ui: var HeadersUi; st: AppState; fonts: Fonts; t: Theme; marks: var Marks) =
  ## The Summary tab: a line per fact, headings between.
  let (s, gather) = st.shownSession
  if s < 0:
    igTextDisabled("No file is shown.")
    return
  let ses = st.sessions[s]
  # Made again when the file, its gather, its keys or the joins change, and
  # twice a second (the record's counts, a relation file loaded): not every
  # frame.
  let key = $int(ses.id) & "." & $gather & "." & $ses.keysRevision & "." & $st.joins.len
  let now = getMonoTime()
  if key != ui.summaryKey or now - ui.summaryAt > initDuration(milliseconds = 500):
    ui.summary = summaryLines(ses, gather, st.joins)
    ui.summaryKey = key
    ui.summaryAt = now
  template lines: untyped = ui.summary
  let pickedIn = ses.path & "#" & $gather # the line picked is of this record's summary
  if pickedIn != ui.pickedIn:
    ui.picked = -1
    ui.pickedIn = pickedIn
  var labelWidth = 0'f32
  for l in lines:
    if not l.heading:
      labelWidth = max(labelWidth, igCalcTextSize(l.label.cstring, nil, false, -1).x)
  # A heading above each section's table, whole (a table's cell would cut
  # it), and the tables in one scrolled child.
  const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_BordersInnerV.cint
  if igBeginChild_Str("##summary", ImVec2_c(x: 0, y: 0), 0, 0):
    igPushItemFlag(ImGui_ItemFlags_NoTabStop.cint, true) # the lines are no stops of Tab
    var open = false
    for i, l in lines:
      if l.heading:
        if open: igEndTable()
        open = false
        fonts.withFont(frHeading, 0):
          igTextUnformatted(l.label.cstring, nil)
        if i == 0: marks.mark("headers.summary.heading")
      else:
        if not open:
          open = igBeginTable(cstring("##section" & $i), 2, flags, ImVec2_c(x: 0, y: 0), 0)
          if open:
            igTableSetupColumn("What", ImGui_TableColumnFlags_WidthFixed.cint,
              labelWidth + igGetFontSize(), 0)
            igTableSetupColumn("Value", ImGui_TableColumnFlags_WidthStretch.cint, 0, 1)
        if open:
          igPushID_Int(cint(i))
          igTableNextRow(0, 0)
          discard igTableNextColumn()
          igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
          # (drawn as picked while its menu is open, as it was under the pointer)
          if igSelectable_Bool(l.label.cstring, ui.picked == i or igIsPopupOpen_Str("##copy", 0),
              ImGui_SelectableFlags_SpanAllColumns.cint, ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
            ui.picked = i
          igPopStyleColor(1)
          copyMenu("##copy", l.value, lines)
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
    if open: igEndTable()
    igPopItemFlag()
  igEndChild()
  marks.mark("headers.summary")
  if ui.picked >= 0 and ui.picked < lines.len and igGetIO_Nil().KeyCtrl and
      igIsKeyPressed_Bool(ImGui_Key_C, false) and
      igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint):
    igSetClipboardText(lines[ui.picked].value.cstring)

# ------------------------------------------------------------ header tables --

func columnOf(c: HeaderColumn; values: int): cint =
  ## The table column of `c` in a table of `values` value columns: the
  ## description first, the values next, then the name, bytes and offset.
  if c == hcDescription: 0 else: cint(values + ord(c))

proc syncColumns(ui: var HeadersUi; id: string; values: int; st: AppState;
    output: var HeadersOutput) =
  ## After the table's header row (its layout is made there): the settings'
  ## columns are given to a table that has not had them (its first frame,
  ## or the settings changed), from the next frame on; a column the user
  ## showed or hid in the header's right-click menu goes into the settings.
  let want = st.settings.headers.columns
  var now: set[HeaderColumn]
  for c in HeaderColumn:
    if (igTableGetColumnFlags(columnOf(c, values)) and
        ImGui_TableColumnFlags_IsEnabled.cint) != 0:
      now.incl c
  if id notin ui.applied or ui.applied[id] != want:
    for c in HeaderColumn: igTableSetColumnEnabled(columnOf(c, values), c in want)
    ui.applied[id] = want
  elif now != want:
    ui.applied[id] = now
    var s = st.settings
    s.headers.columns = now
    output.commands.add Command(kind: ckSettings, settings: s)
    ui.applied.clear() # the other tables are given them anew
    ui.applied[id] = now

proc valueMenu(table: FieldTable; column: int; value: string; marks: var Marks) =
  ## The right-click menu of a value: copy it, its column, or the table.
  if igBeginPopupContextItem("##value", ImGui_PopupFlags_MouseButtonRight.cint):
    marks.markWindow("headers.value menu")
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
  ## description, a value column per header, and its name, bytes and
  ## offset (the columns chosen); values that differ between the columns in
  ## the warning colour. Only the rows in view are drawn.
  # (never more than Dear ImGui takes: a caller pages more, `pageOf`)
  let values = min(table.columns.len, MaxSideBySide)
  let n = int(HeaderColumn.high) + 1 + values
  const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
    ImGui_TableFlags_ScrollX.cint or ImGui_TableFlags_Resizable.cint or
    ImGui_TableFlags_BordersInnerV.cint or ImGui_TableFlags_Hideable.cint or
    ImGui_TableFlags_SizingFixedFit.cint
  # The description is at most 18 em, and 40 % of the window, so
  # that the first values show beside it in a narrow window (a long one is
  # cut, and said whole when pointed at); it can be widened, until the
  # window's width changes. (The columns' order changed: "v2", so a width
  # Dear ImGui kept for the old order is not taken for another column.)
  let avail = igGetContentRegionAvail().x
  let describe = round(clamp(0.4 * avail, 8 * igGetFontSize(), 18 * igGetFontSize()))
  if not igBeginTable((id & "##v2").cstring, cint(n), flags, ImVec2_c(x: 0, y: height), 0):
    return
  igTableSetupScrollFreeze(1, 1)
  igTableSetupColumn(($hcDescription).cstring, ImGui_TableColumnFlags_NoHide.cint or
    ImGui_TableColumnFlags_WidthFixed.cint, describe, ImGuiID(ord(hcDescription)))
  for k in 0 ..< values:
    igTableSetupColumn(table.columns[k].cstring, ImGui_TableColumnFlags_NoHide.cint, 0,
      ImGuiID(100 + k))
  for c in hcName .. HeaderColumn.high:
    igTableSetupColumn(($c).cstring, 0, 0, ImGuiID(ord(c)))
  # The window's width changed since the description was fitted: fitted
  # again. (Not in the table's first frame, which takes `describe` as it
  # is set up, and before Dear ImGui has laid it out once.)
  if igGetCurrentTable().MinColumnWidth > 0 and ui.widths.getOrDefault(id, avail) != avail:
    igTableSetColumnWidth(0, describe)
  ui.widths[id] = avail
  fonts.withFont(frHeading, 0):
    igTableHeadersRow()
  ui.syncColumns(id, values, st, output)
  let warning = vec4(t.roles[rlWarning])
  # The cells are no stops of Tab (it moves between the window's controls,
  # not through every value); the arrow keys reach them.
  igPushItemFlag(ImGui_ItemFlags_NoTabStop.cint, true)
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
        if igTableSetColumnIndex(columnOf(hcDescription, values)):
          igTextUnformatted(row.description.cstring, nil)
          if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint):
            igSetTooltip("%s", (row.description & "\n" & row.name & (if row.joined.len > 0:
              ": " & JoinedTip else: ", bytes " & row.bytes) &
              (if row.differs: "\nThe values differ." else: "")).cstring)
        fonts.withFont(frMono, 0):
          igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
          if igTableSetColumnIndex(columnOf(hcName, values)):
            igTextUnformatted(row.name.cstring, nil)
            if i < 40: marks.mark(id & " name " & row.name)
          if igTableSetColumnIndex(columnOf(hcBytes, values)):
            rightAlign(row.bytes)
            igTextUnformatted(row.bytes.cstring, nil)
          if igTableSetColumnIndex(columnOf(hcOffset, values)):
            rightAlign(row.offset)
            igTextUnformatted(row.offset.cstring, nil)
          igPopStyleColor(1)
          if row.differs: igPushStyleColor_Vec4(ImGui_Col_Text.cint, warning)
          for c, v in row.values:
            if c < values and igTableSetColumnIndex(cint(1 + c)):
              igPushID_Int(cint(c))
              let joined = c < row.joined.len and row.joined[c] # (the join's accent colour)
              if joined: igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlAccent]))
              rightAlign(v)
              # (drawn as chosen while its menu is open, as it was under the pointer)
              discard igSelectable_Bool((v & "##v").cstring, igIsPopupOpen_Str("##value", 0), 0,
                ImVec2_c(x: 0, y: 0))
              if joined:
                igPopStyleColor(1)
                if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint):
                  igSetTooltip("%s", JoinedTip.cstring)
                if i < 400: marks.mark(id & " joined " & row.name & " " & $c)
              valueMenu(table, c, v, marks)
              if i < 400: marks.mark(id & " " & row.name & " " & $c)
              igPopID()
          if row.differs:
            igPopStyleColor(1)
            marks.mark(id & " differs " & row.name)
      igPopID()
  ImGuiListClipper_End(clipper)
  ImGuiListClipper_destroy(clipper)
  igPopItemFlag()
  igEndTable()
  marks.mark(id)

func stale(ui: HeadersUi; id, key: string): bool =
  ## Whether table `id` is to be made again: what it is made from (`key`)
  ## changed. (It is then made in place and drawn from there: nothing of it,
  ## or of what it is made from, is copied a frame.)
  id notin ui.tables or ui.tables[id].key != key

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

proc drawSetsPage(ui: var HeadersUi; t: Theme; marks: var Marks) =
  ## Above a record's channel sets when there are more than a table shows
  ## side by side: buttons to the pages before and after, and which are shown.
  let page = pageOf(ui.sets, ui.setsPage)
  igBeginDisabled(page.a == 0)
  if igSmallButton("Previous##setspage"): dec ui.setsPage
  igEndDisabled()
  marks.mark("headers.sets previous")
  igSameLine(0, -1)
  igBeginDisabled(page.b + 1 >= ui.sets)
  if igSmallButton("Next##setspage"): inc ui.setsPage
  igEndDisabled()
  marks.mark("headers.sets next")
  igSameLine(0, -1)
  dim(t, "Sets " & $(page.a + 1) & " to " & $(page.b + 1) & " of " & $ui.sets)
  marks.mark("headers.sets page")

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
      const id = "headers.binary"
      if ui.stale(id, fileKey):
        ui.tables[id] = CachedTable(key: fileKey, table: fieldTable([rowsOf(facts.rows,
          proc (r: FieldRow): bool = r.blockName == "binary")], ["Value"], standard))
      ui.drawFieldTable(id, ui.tables[id].table, st, fonts, t, marks, output)
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
    template r: untyped = st.inspection.answer.record # not copied a frame
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
        const id = "headers.general"
        if ui.stale(id, key):
          ui.tables[id] = CachedTable(key: key, table: fieldTable([rowsOf(r.rows,
            proc (x: FieldRow): bool = x.blockName.blockIs("gh"))], ["Value"], standard))
        ui.drawFieldTable(id, ui.tables[id].table, st, fonts, t, marks, output)
        igEndTabItem()
      func isSet(x: FieldRow): bool = x.blockName.blockIs("st") and "cs" in x.blockName
      var anySet = false
      for i in 0 ..< r.rows.len:
        if r.rows[i].isSet: anySet = true
      if anySet and subTab("Channel sets", marks):
        const id = "headers.sets"
        if ui.stale(id, key & "." & $ui.setsPage):
          # The page's sets side by side (`MaxSideBySide` a page).
          var count = 0
          for i in 0 ..< r.rows.len:
            if r.rows[i].isSet and (i == 0 or r.rows[i - 1].blockName != r.rows[i].blockName):
              inc count
          ui.sets = count
          let page = pageOf(count, ui.setsPage)
          ui.setsPage = page.a div MaxSideBySide
          var sets: seq[seq[FieldRow]]
          var names: seq[string]
          var k = -1
          for i in 0 ..< r.rows.len:
            template x: untyped = r.rows[i]
            if x.isSet:
              if i == 0 or r.rows[i - 1].blockName != x.blockName:
                inc k
                if k in page:
                  names.add setLabel(x.blockName)
                  sets.add @[]
              if k in page: sets[^1].add x
          ui.tables[id] = CachedTable(key: key & "." & $ui.setsPage, table: fieldTable(sets,
            names, standard, byBlock = false))
        if ui.sets > MaxSideBySide: ui.drawSetsPage(t, marks)
        ui.drawFieldTable(id, ui.tables[id].table, st, fonts, t, marks, output)
        igEndTabItem()
      for i in 0 ..< r.raw.len:
        template b: untyped = r.raw[i]
        # (an untyped general header block is a row of General)
        if not b.blockName.blockIs("gh") and subTab(tabName(b.blockName), marks):
          drawBytes("headers.bytes " & b.blockName, b, t, fonts, marks)
          igEndTabItem()
  of skSeg2:
    if subTab("File", marks):
      const id = "headers.file"
      if ui.stale(id, fileKey):
        ui.tables[id] = CachedTable(key: fileKey, table: fieldTable([facts.rows], ["Value"],
          standard))
      ui.drawFieldTable(id, ui.tables[id].table, st, fonts, t, marks, output)
      igEndTabItem()
  of skUnknown: discard
  if standard != skSeg2:
    for i in 0 ..< ses.facts.raw.len:
      template b: untyped = ses.facts.raw[i]
      if b.blockName notin ["text", "extended"] and subTab(tabName(b.blockName), marks):
        drawBytes("headers.bytes " & b.blockName, b, t, fonts, marks)
        igEndTabItem()
  igEndTabBar()

# ------------------------------------------------------------------- trace --

proc toggle(st: AppState; label, tip: string; on: bool; marks: var Marks; mark: string): bool =
  ## A checkbox; true when it was clicked.
  var v = on
  result = igCheckbox(label.cstring, addr v)
  marks.mark(mark)
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(tip.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc problems(traces: openArray[TraceDetail]; t: Theme; marks: var Marks) =
  ## A line for each trace that could not be read whole.
  for d in traces:
    if d.problem.len > 0:
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
      igPushTextWrapPos(0)
      igTextUnformatted(("Trace " & $(d.trace + 1) & " of " & d.file & ": " & d.problem).cstring,
        nil)
      igPopTextWrapPos()
      igPopStyleColor(1)
      marks.mark("headers.problem")
    if d.cut > 0:
      dim(t, "Trace " & $(d.trace + 1) & ": its last " & $d.cut & " samples are left out " &
        "(too many samples at once).")

proc drawTraceHeader(ui: var HeadersUi; st: AppState; fonts: Fonts; t: Theme; marks: var Marks;
    output: var HeadersOutput) =
  ## Trace, Header: every header field of the traces, a value column each;
  ## first, the values a geometry join gave them, in the accent colour.
  template answer: untyped = st.inspection.answer
  var shown = 0
  for k in 0 ..< answer.traces.len: # (an index: nothing of the answer is copied a frame)
    if answer.traces[k].rows.len > 0: inc shown
  if shown == 0:
    if st.inspection.waiting: igTextDisabled("Reading the trace headers...")
    return
  const id = "headers.trace"
  let key = $answer.gen
  if id notin ui.tables or ui.tables[id].key != key:
    ui.tables[id] = CachedTable(key: key, table: traceTable(answer.traces))
  ui.drawFieldTable(id, ui.tables[id].table, st, fonts, t, marks, output)

func cutWords(rows, columns: int): string =
  ## What a copy of the Data tab's `rows` rows of `columns` columns of
  ## samples leaves out, said in its menu item: "" when it takes them all.
  let n = copiedRows(rows, columns)
  if n >= rows: ""
  else: " (its first " & grouped(n) & " of " & grouped(rows) & " rows: " &
    grouped(MaxCopiedValues) & " samples at most)"

proc drawTraceData(ui: var HeadersUi; st: AppState; cursorMs: float64; pointerInPlot: bool;
    fonts: Fonts; t: Theme; marks: var Marks; output: var HeadersOutput) =
  ## Trace, Data: the traces' samples, a row per sample: its index, its time
  ## and a column per trace; the row at the plot's cursor time marked.
  template answer: untyped = st.inspection.answer
  let view = st.settings.headers
  if st.toggle("As displayed", "The samples after the edits (kills, polarity reversals), " &
      "the polarity of the plot and its gain's processing, as the status bar's amplitude " &
      "reads them; off, as the file holds them.", view.asDisplayed, marks, "headers.displayed"):
    var s = st.settings
    s.headers.asDisplayed = not view.asDisplayed
    output.commands.add Command(kind: ckSettings, settings: s)
  var n = 0
  var traces: seq[int] # the answer's traces with samples
  for k in 0 ..< answer.traces.len: # (an index: nothing of the answer is copied a frame)
    template d: untyped = answer.traces[k]
    if d.samples.len > 0:
      traces.add k
      n = max(n, d.samples.len)
    elif ipTraceSamples in st.inspection.parts and not st.inspection.waiting and d.cut == 0 and
        d.problem.len == 0: # (read for the samples, and none)
      dim(t, "Trace " & $(d.trace + 1) & " of " & d.file & " has no samples.")
      marks.mark("headers.data none")
  if traces.len == 0:
    if st.inspection.waiting: igTextDisabled("Reading the samples...")
    return
  template first: untyped = answer.traces[traces[0]]
  var other = false
  for k in traces:
    if answer.traces[k].dtMs != first.dtMs or answer.traces[k].t0Ms != first.t0Ms: other = true
  if other: dim(t, "The traces have other sample intervals or start times: the times are " &
    "those of the first.")
  if not first.intervalKnown:
    dim(t, "The file gives no sample interval for " & traceLabel(first, false) & ": the " &
      "times count its samples, 1 ms each.")
    marks.mark("headers.data no interval")
  let withFile = answer.traces.manyFiles
  let cursor = if cursorMs.isNaN or first.dtMs <= 0: -1
               else: int(round((cursorMs - first.t0Ms) / first.dtMs))
  const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
    ImGui_TableFlags_ScrollX.cint or ImGui_TableFlags_Resizable.cint or
    ImGui_TableFlags_BordersInnerV.cint or ImGui_TableFlags_SizingFixedFit.cint
  if not igBeginTable("headers.data", cint(2 + traces.len), flags, ImVec2_c(x: 0, y: 0), 0):
    return
  igTableSetupScrollFreeze(2, 1)
  igTableSetupColumn("Index", 0, 0, 0)
  igTableSetupColumn("Time (ms)", 0, 0, 1)
  for c, k in traces:
    igTableSetupColumn((traceLabel(answer.traces[k], withFile) & (if answer.traces[k].displayed:
      " as displayed" else: "")).cstring, 0, 0, ImGuiID(100 + c))
  fonts.withFont(frHeading, 0):
    igTableHeadersRow()
  marks.mark("headers.data header")
  let mark = u32(withAlpha(t.roles[rlHighlight], 70))
  igPushItemFlag(ImGui_ItemFlags_NoTabStop.cint, true) # the samples are no stops of Tab
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(n), -1)
  if pointerInPlot and cursor in 0 ..< n: ImGuiListClipper_IncludeItemByIndex(clipper, cint(cursor))
  fonts.withFont(frMono, 0):
    while ImGuiListClipper_Step(clipper):
      for i in clipper.DisplayStart ..< clipper.DisplayEnd:
        igTableNextRow(0, 0)
        igPushID_Int(cint(i))
        if i == cursor:
          igTableSetBgColor(ImGui_TableBgTarget_RowBg1.cint, mark, -1)
        discard igTableNextColumn()
        let index = $i
        rightAlign(index)
        igTextUnformatted(index.cstring, nil)
        if i == cursor:
          marks.mark("headers.data cursor")
          if pointerInPlot and not igIsItemVisible(): igSetScrollHereY(0.5)
        if i == clipper.DisplayStart: marks.mark("headers.data first")
        discard igTableNextColumn()
        let time = exactText(first.t0Ms + float64(i) * first.dtMs)
        rightAlign(time)
        igTextUnformatted(time.cstring, nil)
        for c, k in traces:
          if igTableNextColumn():
            template d: untyped = answer.traces[k]
            if i < d.samples.len:
              let v = sampleText(d.samples[i])
              igPushID_Int(cint(c))
              rightAlign(v)
              discard igSelectable_Bool((v & "##s").cstring, igIsPopupOpen_Str("##sample", 0), 0,
                ImVec2_c(x: 0, y: 0))
              if i < 64: marks.mark("headers.data " & $i & " " & $c)
              if igBeginPopupContextItem("##sample", ImGui_PopupFlags_MouseButtonRight.cint):
                marks.markWindow("headers.data menu")
                if igMenuItem_Bool("Copy", "Ctrl+C", false, true): igSetClipboardText(v.cstring)
                if igMenuItem_Bool(("Copy the column of " & traceLabel(d, withFile) &
                    cutWords(n, 1)).cstring, nil, false, true):
                  var all: seq[TraceDetail]
                  for kk in traces: all.add answer.traces[kk]
                  igSetClipboardText(dataText(all, c).cstring)
                marks.mark("headers.data copy column")
                if igMenuItem_Bool(("Copy the table" & cutWords(n, traces.len)).cstring, nil,
                    false, true):
                  var all: seq[TraceDetail]
                  for kk in traces: all.add answer.traces[kk]
                  igSetClipboardText(dataText(all).cstring)
                marks.mark("headers.data copy table")
                igEndPopup()
              if igIsItemFocused() and igGetIO_Nil().KeyCtrl and
                  igIsKeyPressed_Bool(ImGui_Key_C, false):
                igSetClipboardText(v.cstring)
              igPopID()
        igPopID()
  ImGuiListClipper_End(clipper)
  ImGuiListClipper_destroy(clipper)
  igPopItemFlag()
  igEndTable()
  marks.mark("headers.data")

proc drawTrace(ui: var HeadersUi; st: AppState; cursorMs: float64; pointerInPlot: bool;
    fonts: Fonts; t: Theme; marks: var Marks; output: var HeadersOutput;
    parts: var set[InspectPart]) =
  ## The Trace tab: the traces chosen (the selection, or the one under the
  ## pointer), with Header and Data.
  let view = st.settings.headers
  if st.toggle("Follow the pointer", "With no trace selected, show the trace under the " &
      "pointer in the plot (or the traces of the receiver under it on the map). Off: only " &
      "the traces selected.", view.followPointer, marks, "headers.follow"):
    var s = st.settings
    s.headers.followPointer = not view.followPointer
    output.commands.add Command(kind: ckSettings, settings: s)
  dim(t, chosenLine(st, view.followPointer))
  marks.mark("headers.chosen")
  problems(st.inspection.answer.traces, t, marks)
  if st.inspection.chosen.traces.len == 0: return
  if igBeginTabBar("##tracetabs", 0):
    let wanted = view.traceTab
    let select = ui.selectingTrace
    ui.selectingTrace = false
    var shown = ui.shownTraceTab
    let headerFlags = if select and wanted == ttHeader: ImGui_TabItemFlags_SetSelected.cint
                      else: 0.cint
    let header = igBeginTabItem("Header", nil, headerFlags)
    marks.mark("headers.trace tab header")
    if header:
      shown = ttHeader
      parts.incl ipTraceHeaders
      ui.drawTraceHeader(st, fonts, t, marks, output)
      igEndTabItem()
    let dataFlags = if select and wanted == ttData: ImGui_TabItemFlags_SetSelected.cint
                    else: 0.cint
    let data = igBeginTabItem("Data", nil, dataFlags)
    marks.mark("headers.trace tab data")
    if data:
      shown = ttData
      parts.incl ipTraceSamples
      ui.drawTraceData(st, cursorMs, pointerInPlot, fonts, t, marks, output)
      igEndTabItem()
    igEndTabBar()
    if select: ui.shownTraceTab = wanted
    elif shown != ui.shownTraceTab:
      ui.shownTraceTab = shown
      var s = st.settings
      s.headers.traceTab = shown
      output.commands.add Command(kind: ckSettings, settings: s)

# ------------------------------------------------------------------ window --

proc drawHeaders*(ui: var HeadersUi; title: string; st: AppState; cursorMs: float64;
    pointerInPlot: bool; fonts: Fonts; t: Theme; marks: var Marks): HeadersOutput =
  ## The window, docked or floating like any other, titled `title` (its
  ## ImGui ID stays `###headers`), for the file the main panel shows;
  ## `cursorMs` is the time under the pointer in the plot (NaN for none),
  ## whose row the Data tab marks, and scrolls to while `pointerInPlot`.
  let view = st.settings.headers
  if not ui.started or view.tab != ui.shownTab:
    ui.selecting = true
  if not ui.started or view.traceTab != ui.shownTraceTab:
    ui.selectingTrace = true
  ui.started = true
  var parts: set[InspectPart]
  if igBegin(title.cstring, nil, 0):
    ui.focus.watch()
    marks.markWindow("headers")
    let waiting = st.headersWait()
    if waiting.kind != wkNone: # its reader is stuck in a drive that does not answer
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
      igPushTextWrapPos(0)
      igTextUnformatted(waiting.words.cstring, nil)
      igPopTextWrapPos()
      igPopStyleColor(1)
      marks.mark("headers.waiting")
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
        ui.drawTrace(st, cursorMs, pointerInPlot, fonts, t, marks, result, parts)
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
