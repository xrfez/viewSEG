## The "Headers" window: what the file shown is and what its headers hold,
## in four tabs (`HeadersTab`), read-only.
##
## - **Summary:** the file's properties: what it is (its standard, sample
##   format, counts, timing, coordinates), how it was opened, and the record
##   shown with its counts, in plain words (`core/properties.summaryLines`),
##   with "Reopen with options..." above them.
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
##   A SEG-Y file's stanzas and User Data attachments have tabs of their
##   own (Stanzas, User data). Above each table, Find keeps the fields whose
##   description, name or value holds what is typed; a click on a value
##   shows its block's bytes below the table, the field's highlighted, read
##   every way a header could hold them (`view/byteview`).
## - **Trace:** the selected traces' (or the pointed one's) header fields and
##   samples.
## - **Trace table:** a row per trace (`ui/imgui/headerstable`).
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
import ../../view/[byteview, headerviews, theme]
import chrome, focus, fonts, headerstable, menus, style

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
    vendorClosed: bool
      ## the "Vendor, trace N" groups of the Trace tab were folded by the user (kept for the
      ## window's life, for every trace)
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
    table: TableUi ## the Trace table tab's
    fieldFind: array[64, char] ## the header tables' Find, being typed
    hex: HexPick ## the field whose bytes the hex pane shows
    stanza: int ## the stanza the Stanzas tab shows
    attachment: int ## the attachment the User data tab shows
    found: Table[string, CachedTable] ## per table, its rows Find keeps
    toldTable: TableView ## the trace table's view as told to `core` last

  HexPick = object
    ## A field picked for the hex pane, and its block's bytes once found.
    id: string       ## the table it was picked in; "" for none
    name: string     ## the field (`binary.sampleInterval`)
    description: string
    column: int      ## its value column
    at: int64        ## the file offset of its first byte
    size: int
    nibbleStart, nibbles: int
      ## a field of some nibbles of its bytes: the first one's place in them,
      ## and how many; `nibbles` 0 for whole bytes
    found: bool ## `bytes` hold its block
    bytes: seq[byte] ## its block's bytes, copied once when picked
    base: int64 ## the file offset of `bytes[0]`
    seek: bool ## scroll the dump to it (picked this frame)
    tableKey: string ## what its table was made from when it was picked

  HeadersOutput* = object
    commands*: seq[Command]
    reopen*: bool ## the Summary's "Reopen with options..." was clicked

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

proc drawSummary(ui: var HeadersUi; st: AppState; fonts: Fonts; t: Theme; marks: var Marks;
    output: var HeadersOutput) =
  ## The Summary tab: "Reopen with options..." (and, for a file not
  ## recognised, why it is wanted), then a line per fact, headings between.
  let (s, gather) = st.shownSession
  if s < 0:
    igTextDisabled("No file is shown.")
    return
  let ses = st.sessions[s]
  if ses.facts.summary.standard == skUnknown:
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
    igPushTextWrapPos(0)
    igTextUnformatted("viewSEG does not recognise this file as SEG-Y, SEG-D or SEG-2. If " &
      "you know which it is, Reopen with options names its standard.", nil)
    igPopTextWrapPos()
    igPopStyleColor(1)
    marks.mark("headers.summary unknown")
  if igButton("Reopen with options...##summary", ImVec2_c(x: 0, y: 0)): output.reopen = true
  marks.mark("headers.summary reopen")
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint):
    igSetTooltip("%s", ReopenTip.cstring)
  # Made again when the file, its gather, its keys or the joins change, and
  # twice a second (the record's counts, a relation file loaded): not every
  # frame.
  let key = $int(ses.id) & "." & $gather & "." & $ses.keysRevision & "." & $st.joins.len
  let now = getMonoTime()
  if key != ui.summaryKey or now - ui.summaryAt > initDuration(milliseconds = 500):
    ui.summary = summaryLines(ses, gather, st.joins, st.unitChoices)
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

proc findCell(ui: var HeadersUi; id: string; marks: var Marks) =
  ## Find, in the Description column's header (it takes no line of its
  ## own): the text typed, shared by every table, and a button that clears it.
  let typed = ui.fieldFind[0] != '\0'
  let clear = if typed: igGetFrameHeight() + igGetStyle().ItemSpacing.x else: 0
  igSetNextItemWidth(max(igGetContentRegionAvail().x - clear, igGetFontSize() * 4))
  discard igInputTextWithHint(("##find" & id).cstring, "Find a field or a value",
    cast[cstring](addr ui.fieldFind[0]), csize_t(ui.fieldFind.len), 0, nil, nil)
  marks.mark(id & " find")
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint):
    igSetTooltip("%s", ("Show only the fields whose description, name or value holds " &
      "this text").cstring)
  if typed:
    igSameLine(0, -1)
    if igButton(("x##clear" & id).cstring, ImVec2_c(x: igGetFrameHeight(), y: 0)):
      zeroMem(addr ui.fieldFind[0], ui.fieldFind.len)
    marks.mark(id & " find clear")
    if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint): igSetTooltip("Every field again")

proc drawFieldTable(ui: var HeadersUi; id: string; whole: FieldTable; st: AppState;
    fonts: Fonts; t: Theme; marks: var Marks; output: var HeadersOutput; height = 0'f32) =
  ## A header table: Find, then a row per field (titles between blocks), its
  ## description, a value column per header, and its name, bytes and
  ## offset (the columns chosen); values that differ between the columns in
  ## the warning colour. Only the rows in view are drawn.
  # (never more than Dear ImGui takes: a caller pages more, `pageOf`)
  let query = $cast[cstring](addr ui.fieldFind[0]) # (typed in the table's header, below)
  let made = (if id in ui.tables: ui.tables[id].key else: "") & "\t" & $whole.rows.len &
    "\t" & query
  if query.len > 0 and (id notin ui.found or ui.found[id].key != made):
    ui.found[id] = CachedTable(key: made, table: filtered(whole, query))
  # (by its address: nothing of a table is copied a frame; `whole` is
  # `ui.tables[id].table`, as every caller passes)
  let shown = if query.len > 0: addr ui.found[id].table else: addr ui.tables[id].table
  template table: untyped = shown[]
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
  # The header row: Find in the description's place, the columns' names
  # (right-click one to show or hide columns).
  igTableNextRow(ImGui_TableRowFlags_Headers.cint, 0)
  for c in 0 ..< n:
    if igTableSetColumnIndex(cint(c)):
      if c == 0: ui.findCell(id, marks)
      else:
        fonts.withFont(frHeading, 0):
          igTableHeader(igTableGetColumnName_Int(cint(c)))
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
              let picked = ui.hex.id == id and ui.hex.name == row.name and ui.hex.column == c
              if igSelectable_Bool((v & "##v").cstring, picked or
                  igIsPopupOpen_Str("##value", 0), 0, ImVec2_c(x: 0, y: 0)) and
                  c < row.at.len and row.at[c] >= 0:
                # a click shows the field's bytes in its block, or hides them
                ui.hex = if picked: HexPick() else: HexPick(id: id, name: row.name, column: c,
                  at: row.at[c], size: row.size, nibbleStart: row.nibbleStart,
                  nibbles: row.nibbles, description: row.description, seek: true,
                  tableKey: ui.tables[id].key)
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

proc drawBytes(id: string; b: RawBlock; t: Theme; fonts: Fonts; marks: var Marks;
    inFile = true) =
  ## A block without named fields as its bytes: offset, hexadecimal, text;
  ## not `inFile` (a stanza's), the offsets are from its first byte.
  dim(t, $b.size & " bytes" & (if inFile: " at offset " & $b.offset else: "") &
    (if b.bytes.len < b.size: "; the first " & $b.bytes.len & " are shown" else: "") & ".")
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

# ---------------------------------------------------------------- hex pane --

func hexHeight(): float32 = igGetTextLineHeightWithSpacing() * 13
  ## the hex pane's height: what the table above it leaves

proc tableHeight(ui: HeadersUi; id: string): float32 =
  ## The height a header table is given: what is left (0), less the hex
  ## pane's when it shows a field of this table (at most half of it).
  if ui.hex.id == id: -min(hexHeight(), 0.5 * igGetContentRegionAvail().y) else: 0

proc drawHex(ui: var HeadersUi; id: string; blocks: openArray[RawBlock]; fonts: Fonts;
    t: Theme; marks: var Marks) =
  ## Below table `id`, when a field of it is picked: its block's bytes (a
  ## line each 16: offset, hexadecimal, text), the field's highlighted, and
  ## its bytes read every way a header could hold them.
  if ui.hex.id != id: return
  template h: untyped = ui.hex
  if id in ui.tables and ui.tables[id].key != h.tableKey:
    # the table was made again (other traces, another record): the field
    # picked, at its place there, or none
    var at = -1'i64
    for row in ui.tables[id].table.rows:
      if row.name == h.name and h.column < row.at.len: at = row.at[h.column]
    if at < 0:
      h = HexPick()
      return
    (h.at, h.found, h.tableKey) = (at, false, ui.tables[id].key)
  if not h.found:
    for b in blocks:
      if h.at >= b.offset and h.at + h.size <= b.offset + b.bytes.len:
        h.bytes = b.bytes
        h.base = b.offset
        h.found = true
  if not h.found:
    igTextDisabled("The bytes of this field were not read.")
    marks.mark("headers.hex none")
    return
  let first = int(h.at - h.base)
  igSeparator()
  dim(t, h.description & " (" & h.name & "): " & $h.size & (if h.size == 1: " byte" else:
    " bytes") & " at " & $h.at & ". Click its value again to hide its bytes.")
  let readingsWidth = min(igGetFontSize() * 22, 0.45 * igGetContentRegionAvail().x)
  if igBeginChild_Str("##hexdump", ImVec2_c(x: -readingsWidth, y: 0), ImGui_ChildFlags_Borders.cint,
      ImGui_WindowFlags_HorizontalScrollbar.cint):
    fonts.withFont(frMono, 0):
      let charW = igCalcTextSize("0", nil, false, -1).x
      let lineH = igGetTextLineHeight()
      let mark = u32(withAlpha(t.roles[rlHighlight], 110))
      let dl = igGetWindowDrawList()
      let clipper = ImGuiListClipper_ImGuiListClipper()
      ImGuiListClipper_Begin(clipper, cint(dumpLines(h.bytes)), -1)
      ImGuiListClipper_IncludeItemByIndex(clipper, cint(first div 16))
      while ImGuiListClipper_Step(clipper):
        for line in clipper.DisplayStart ..< clipper.DisplayEnd:
          let pos = igGetCursorScreenPos()
          for k in max(first, line * 16) ..< min(first + h.size, line * 16 + 16):
            let x = pos.x + charW * float32(dumpColumn(k - line * 16))
            if h.nibbles == 0:
              ImDrawList_AddRectFilled(dl, ImVec2_c(x: x - 1, y: pos.y),
                ImVec2_c(x: x + 2 * charW + 1, y: pos.y + lineH), mark, 0, 0)
              marks.markRect("headers.hex lit " & $(h.base + k), ImVec2_c(x: x, y: pos.y),
                ImVec2_c(x: x + 2 * charW, y: pos.y + lineH))
            else: # only the nibbles the field takes
              for half in 0 .. 1:
                if covers(h.nibbleStart, h.nibbles, k - first, half):
                  let left = x + charW * float32(half)
                  ImDrawList_AddRectFilled(dl, ImVec2_c(x: left - (if half == 0: 1 else: 0),
                    y: pos.y), ImVec2_c(x: left + charW + (if half == 1: 1 else: 0),
                    y: pos.y + lineH), mark, 0, 0)
                  marks.markRect("headers.hex lit " & $(h.base + k) & "." & $half,
                    ImVec2_c(x: left, y: pos.y), ImVec2_c(x: left + charW, y: pos.y + lineH))
          igTextUnformatted(dumpLine(h.bytes, h.base, line).cstring, nil)
          if line == first div 16:
            marks.mark("headers.hex field")
            if h.seek:
              igSetScrollHereY(0.3)
              h.seek = false
      ImGuiListClipper_End(clipper)
      ImGuiListClipper_destroy(clipper)
  igEndChild()
  marks.mark("headers.hex")
  igSameLine(0, -1)
  if igBeginChild_Str("##readings", ImVec2_c(x: 0, y: 0), 0, 0):
    const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_SizingFixedFit.cint
    let readings = byteReadings(h.bytes.toOpenArray(first, first + h.size - 1), h.nibbleStart,
      h.nibbles)
    if readings.len == 0: igTextDisabled("Read as a number: 1, 2, 3, 4 or 8 bytes only.")
    elif igBeginTable("##read", 2, flags, ImVec2_c(x: 0, y: 0), 0):
      for r in readings:
        igTableNextRow(0, 0)
        discard igTableNextColumn()
        igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
        igTextUnformatted(r.label.cstring, nil)
        igPopStyleColor(1)
        discard igTableNextColumn()
        fonts.withFont(frMono, 0):
          igTextUnformatted(r.value.cstring, nil)
        marks.mark("headers.hex read " & r.label)
      igEndTable()
  igEndChild()

# ------------------------------------------------------------------ stanzas --

proc listPane(id: string; names: openArray[string]; picked: var int; marks: var Marks) =
  ## A list on the left of a tab: a click picks a line.
  if igBeginChild_Str(id.cstring, ImVec2_c(x: igGetFontSize() * 16, y: 0),
      ImGui_ChildFlags_Borders.cint or ImGui_ChildFlags_ResizeX.cint, 0):
    for i, n in names:
      if igSelectable_Bool((n & "##" & $i).cstring, picked == i, 0, ImVec2_c(x: 0, y: 0)):
        picked = i
      if i < 64: marks.mark(id & " " & $i)
  igEndChild()
  igSameLine(0, -1)

proc drawStanzas(ui: var HeadersUi; stanzas: openArray[StanzaFact]; fileKey: string;
    fonts: Fonts; t: Theme; marks: var Marks) =
  ## The extended textual headers' stanzas: a list, and the one picked (its
  ## text, or its bytes).
  var names: seq[string]
  for s in stanzas:
    names.add s.company & ": " & s.name & (if s.kind == skText: "" else: " (" & $s.kind & ")")
  ui.stanza = clamp(ui.stanza, 0, stanzas.high)
  listPane("headers.stanzas", names, ui.stanza, marks)
  if igBeginChild_Str("##stanza", ImVec2_c(x: 0, y: 0), 0, 0):
    template s: untyped = stanzas[ui.stanza]
    dim(t, s.key & (if s.contentType.len > 0: ", " & s.contentType else: "") & ", " &
      $s.size & " bytes" & (case s.kind
      of skEnd: ": the end of the extended textual headers"
      of skUserData: ": a User Data attachment (the User data tab shows it)"
      else: ""))
    case s.kind
    of skText:
      let text = addr stanzas[ui.stanza].text # (read once, when it changes: never copied a frame)
      ui.drawText("##stanzatext", fileKey & "." & $ui.stanza, proc (): string = text[], fonts,
        marks)
    of skBinary:
      drawBytes("headers.stanza bytes", RawBlock(blockName: s.key, size: s.size,
        bytes: s.bytes), t, fonts, marks, inFile = false)
    of skUserData, skEnd: discard
  igEndChild()
  marks.mark("headers.stanza")

proc drawUserData(ui: var HeadersUi; data: openArray[UserDataFact]; fileKey: string;
    fonts: Fonts; t: Theme; marks: var Marks) =
  ## The User Data attachments: a list, and the one picked: its description
  ## and its bytes.
  var names: seq[string]
  for u in data: names.add (if u.label.len > 0: u.label else: "(no label)")
  ui.attachment = clamp(ui.attachment, 0, data.high)
  listPane("headers.userdata", names, ui.attachment, marks)
  if igBeginChild_Str("##attachment", ImVec2_c(x: 0, y: 0), 0, 0):
    template u: untyped = data[ui.attachment]
    for (label, value) in [("Format", u.format), ("Description", u.description),
        ("Created", u.created), ("Creator", u.creator), ("Compression", u.compression),
        ("Size", $u.size & " bytes")]:
      if value.len > 0: dim(t, label & ": " & value)
    if u.problem.len > 0: dim(t, "Its bytes are not shown: " & u.problem & ".")
    else:
      drawBytes("headers.userdata bytes", RawBlock(blockName: u.label, size: int(u.size),
        bytes: u.bytes), t, fonts, marks, inFile = false)
  igEndChild()
  marks.mark("headers.userdata")

# ------------------------------------------------------------ file headers --

proc drawVendorBlocks(blocks: openArray[VendorBlockFact]; t: Theme; fonts: Fonts;
    marks: var Marks) =
  ## Each block the vendor maps decode, under the map that did it: its fields
  ## by name with their values.
  for n, b in blocks:
    dim(t, b.name & ", decoded by the map " & b.map &
      (if b.mapFile.len > 0: " (" & b.mapFile & ")" else: ""))
    marks.mark("headers.vendor block " & b.name)
    const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_BordersInnerV.cint or
      ImGui_TableFlags_SizingFixedFit.cint
    if igBeginTable(("##vendor" & $n).cstring, 3, flags, ImVec2_c(x: 0, y: 0), 0):
      for f in b.fields:
        igTableNextRow(0, 0)
        discard igTableNextColumn()
        igTextUnformatted(f.name.cstring, nil)
        marks.mark("headers.vendor field " & f.name)
        discard igTableNextColumn()
        fonts.withFont(frMono, 0):
          igTextUnformatted((f.value & (if f.label.len > 0: " (" & f.label & ")" else: "") &
            (if f.flags.len > 0: " [" & f.flags & "]" else: "")).cstring, nil)
        discard igTableNextColumn()
        igTextUnformatted(f.unit.cstring, nil)
      igEndTable()
    igSpacing()

proc drawVendor(v: VendorShown; t: Theme; fonts: Fonts; marks: var Marks) =
  ## The File headers tab's Vendor tab: what the maps decode of the file.
  if v.rule.len > 0: dim(t, v.rule)
  for p in v.problems: dim(t, p)
  if v.blocks.len == 0:
    dim(t, "No vendor map decodes a block of this file.")
  if igBeginChild_Str("##vendorblocks", ImVec2_c(x: 0, y: 0), 0, 0):
    drawVendorBlocks(v.blocks, t, fonts, marks)
  igEndChild()

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
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted("The channel sets before these", nil)
    igEndTooltip()
  igSameLine(0, -1)
  igBeginDisabled(page.b + 1 >= ui.sets)
  if igSmallButton("Next##setspage"): inc ui.setsPage
  igEndDisabled()
  marks.mark("headers.sets next")
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted("The channel sets after these", nil)
    igEndTooltip()
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
      ui.drawFieldTable(id, ui.tables[id].table, st, fonts, t, marks, output,
        ui.tableHeight(id))
      ui.drawHex(id, facts.blocks, fonts, t, marks)
      igEndTabItem()
    if facts.extendedText.len > 0 and subTab("Extended", marks):
      ui.drawText("##extended", fileKey, proc (): string =
        var parts: seq[string]
        for k, lines in facts.extendedText:
          parts.add "Extended textual header " & $(k + 1) & " of " &
            $facts.extendedText.len & "\n" & lines.join("\n")
        parts.join("\n\n"), fonts, marks)
      igEndTabItem()
    if facts.stanzas.len > 0 and subTab("Stanzas", marks):
      ui.drawStanzas(facts.stanzas, fileKey, fonts, t, marks)
      igEndTabItem()
    if facts.userData.len > 0 and subTab("User data", marks):
      ui.drawUserData(facts.userData, fileKey, fonts, t, marks)
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
        ui.drawFieldTable(id, ui.tables[id].table, st, fonts, t, marks, output,
          ui.tableHeight(id))
        ui.drawHex(id, r.blocks, fonts, t, marks)
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
        ui.drawFieldTable(id, ui.tables[id].table, st, fonts, t, marks, output,
          ui.tableHeight(id))
        ui.drawHex(id, r.blocks, fonts, t, marks)
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
      ui.drawFieldTable(id, ui.tables[id].table, st, fonts, t, marks, output,
        ui.tableHeight(id))
      ui.drawHex(id, facts.blocks, fonts, t, marks)
      igEndTabItem()
  of skUnknown: discard
  block vendor:
    template v: untyped = st.inspection.answer.vendor
    if v.path == ses.path and (v.blocks.len > 0 or v.problems.len > 0 or v.rule.len > 0) and
        (standard != skSegd or (gather in 0 ..< ses.gathers.len and
        v.record == ses.file.segdRecordOf(ses.gathers[gather].traces.a))) and
        subTab("Vendor", marks):
      drawVendor(v, t, fonts, marks)
      igEndTabItem()
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
  # the vendor fields of each trace the maps decode something of, above its header table,
  # with room above (the search box is over it) and the fold remembered
  for k in 0 ..< answer.traces.len:
    template v: untyped = answer.traces[k].vendor
    if v.blocks.len > 0 or v.problems.len > 0 or v.rule.len > 0:
      igDummy(ImVec2_c(x: 0, y: igGetStyle().ItemSpacing.y * 2))
      igSetNextItemOpen(not ui.vendorClosed, ImGui_Cond_Always.cint)
      let open = igCollapsingHeader_TreeNodeFlags(("Vendor, trace " &
        $(answer.traces[k].trace + 1) & "##vendortrace" & $k).cstring, 0)
      if igIsItemToggledOpen(): ui.vendorClosed = not open
      marks.mark("headers.vendor trace " & $k)
      if open:
        if v.rule.len > 0: dim(t, v.rule)
        for p in v.problems: dim(t, p)
        drawVendorBlocks(v.blocks, t, fonts, marks)
        igDummy(ImVec2_c(x: 0, y: igGetStyle().ItemSpacing.y))
  const id = "headers.trace"
  var matched = 0
  for j in st.joins: matched += j.plan.matched + j.plan.unmatched.len
  let key = $answer.gen & ":" & $st.joins.len & ":" & $matched
  if id notin ui.tables or ui.tables[id].key != key:
    ui.tables[id] = CachedTable(key: key,
      table: traceTable(answer.traces, st.surveyStatuses(answer.traces)))
  ui.drawFieldTable(id, ui.tables[id].table, st, fonts, t, marks, output, ui.tableHeight(id))
  # the blocks of the trace whose value was picked (the columns are the
  # traces whose fields were read, in order)
  var c = -1
  for k in 0 ..< answer.traces.len:
    if answer.traces[k].rows.len > 0:
      inc c
      if c == ui.hex.column: ui.drawHex(id, answer.traces[k].blocks, fonts, t, marks)

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
        ui.drawSummary(st, fonts, t, marks, result)
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
      if ui.tabItem(htTable, view.tab):
        shown = htTable
        marks.mark("headers.tab table")
        parts.incl ipTable
        ui.table.drawTraceTable(st, fonts, t, marks, result.commands)
        igEndTabItem()
      else: marks.mark("headers.tab table")
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
  let table = if ipTable in parts: ui.table.view else: TableView()
  if parts != ui.parts or not ui.told or table != ui.toldTable:
    ui.parts = parts
    ui.told = true
    ui.toldTable = table
    result.commands.add Command(kind: ckInspect, inspect: parts, table: table)
