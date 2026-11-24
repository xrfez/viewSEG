## The Shot log window: a table of shots, its column map, and its problems.
## Import is Project > Import shot log...; this window opens once a file is
## chosen, and View shows or hides it. One cell can be edited at a time, and
## only while Allow editing is ticked.

import std/[algorithm, options, os, strutils, tables]
import imguin/cimgui
import ../../core/[geometry, shotlog, state]
import ../../view/[shotlogwords, theme]
import focus, icons, marks, style

const
  ScanBatch = 1600 ## filter rows looked at in one frame
  PatternRoom = 256
  SentinelRoom = 1024
  FilterRoom = 64

type
  ShotLogUi* = object
    ## The window's own state between frames.
    shown*: bool
    bringUp: bool
    placeAgain: bool
    focus: FocusClicks
    haveSeen: bool     ## a loaded log has been followed
    seenMax: int       ## the highest id followed
    currentId: int     ## the log on show
    columnsOpen: bool
    draft: ShotLogMap
    draftWidth: int
    skip: int32
    pattern: array[PatternRoom, char]
    sentinels: array[SentinelRoom, char]
    filter: array[FilterRoom, char]
    filterText: string
    needle: string
    scanAt: int
    matches: seq[int]
    filterDone: bool
    problemsOnly: bool
    allowEditing: bool ## cell edits, undo and revert; off until ticked
    tab: int           ## 0 grid, 1 problems
    forceGrid: bool    ## the grid tab is selected next frame
    selected: int
    selectedCol: int   ## a data column; -1 when the time or status column is selected
    scrollTo: int
    editing: bool
    editRow: int
    editCol: int
    editBuf: seq[char]
    editReason: string
    armEdit: bool      ## the text box takes the keyboard when it is drawn
    pending: bool      ## Tab committed: open the next cell next frame
    pendingRow: int
    pendingCol: int
    bound: bool
    boundId: int
    boundRev: int
    faultRows: seq[int]
    faultText: Table[int, string]

proc open*(ui: var ShotLogUi) =
  ## Shows the window, in front.
  ui.shown = true
  ui.bringUp = true

proc placeAgain*(ui: var ShotLogUi) =
  ## Puts the window back at its first place and size when next drawn.
  ui.placeAgain = true

func focused*(ui: ShotLogUi): bool {.inline.} =
  ## Whether the window had the focus at the end of the last frame.
  ui.focus.focused

func takesUndo*(ui: ShotLogUi): bool {.inline.} =
  ## Whether this window takes Ctrl+Z and Ctrl+Y: it had the focus and
  ## Allow editing is ticked.
  ui.focus.focused and ui.allowEditing

proc setText(buf: var openArray[char]; text: string) =
  let n = min(text.len, buf.len - 1)
  for i in 0 ..< n: buf[i] = text[i]
  for i in n ..< buf.len: buf[i] = '\0'

proc bufText(buf: openArray[char]): string =
  $cast[cstring](unsafeAddr buf[0])

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 32)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc dim(text: string; t: Theme) =
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igPushTextWrapPos(0)
  igTextUnformatted(text.cstring, nil)
  igPopTextWrapPos()
  igPopStyleColor(1)

proc wrapped(text: string; colour: Rgba) =
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour))
  igPushTextWrapPos(0)
  igTextUnformatted(text.cstring, nil)
  igPopTextWrapPos()
  igPopStyleColor(1)

proc whereOf(st: AppState): string =
  if st.inProject: st.project.doc.name else: SessionOnly

proc follow(ui: var ShotLogUi; st: AppState) =
  ## The newest import, or the newest log when the one on show is gone.
  var maxId = -1
  for i in 0 ..< st.shotLogCount:
    let id = st.shotLogId(i)
    if id > maxId: maxId = id
  if maxId < 0:
    ui.currentId = -1
    return
  if not ui.haveSeen or maxId > ui.seenMax:
    ui.haveSeen = true
    ui.seenMax = maxId
    ui.currentId = maxId
  elif st.findShotLog(ui.currentId) < 0:
    ui.currentId = maxId

proc resetScan(ui: var ShotLogUi) =
  ui.scanAt = 0
  ui.matches.setLen 0
  ui.filterDone = ui.needle.len == 0

proc clearFilter(ui: var ShotLogUi) =
  setText(ui.filter, "")
  ui.filterText = ""
  ui.needle = ""
  ui.resetScan()

proc stopEdit(ui: var ShotLogUi) =
  ui.editing = false
  ui.editReason = ""
  ui.armEdit = false
  ui.pending = false

proc beginEdit(ui: var ShotLogUi; row, col: int; text: string) =
  if not ui.allowEditing: return
  ui.editing = true
  ui.editRow = row
  ui.editCol = col
  ui.selected = row
  ui.selectedCol = col
  ui.editReason = ""
  ui.armEdit = true
  ui.pending = false
  let n = max(text.len + 64, 256)
  ui.editBuf = newSeq[char](n)
  let m = min(text.len, n - 1)
  for i in 0 ..< m: ui.editBuf[i] = text[i]
  ui.editBuf[m] = '\0'

proc editText(ui: ShotLogUi): string =
  if ui.editBuf.len == 0: ""
  else: $cast[cstring](unsafeAddr ui.editBuf[0])

proc selectEditedCell(data: ptr ImGuiInputTextCallbackData): cint {.cdecl, raises: [].} =
  ## A multiline box ignores AutoSelectAll. Select the cell once, as it is focused.
  if data != nil and data.EventActivated:
    ImGuiInputTextCallbackData_SelectAll(data)
  0

proc hasBreak(s: string): bool =
  '\n' in s or '\r' in s

proc cacheFaults(ui: var ShotLogUi; st: AppState; i: int) =
  ui.faultRows.setLen 0
  ui.faultText.clear()
  if i < 0: return
  for p in st.shotView(i).problems.items:
    if p.row < 0: continue
    if ui.faultText.hasKey(p.row):
      ui.faultText[p.row].add "; "
      ui.faultText[p.row].add p.text
    else:
      ui.faultText[p.row] = p.text
      ui.faultRows.add p.row
  ui.faultRows.sort()

proc bindLog(ui: var ShotLogUi; st: AppState; i, rev: int) =
  ## Drops a draft and a filter when the log on show changes, and rebuilds
  ## the problem rows when the view does.
  if not ui.bound or ui.boundId != ui.currentId:
    ui.bound = true
    ui.boundId = ui.currentId
    ui.boundRev = rev
    ui.columnsOpen = false
    ui.allowEditing = false
    ui.selected = -1
    ui.selectedCol = -1
    ui.scrollTo = -1
    ui.stopEdit()
    ui.clearFilter()
    ui.cacheFaults(st, i)
  elif ui.boundRev != rev:
    ui.boundRev = rev
    ui.resetScan()
    ui.cacheFaults(st, i)
    ui.stopEdit()

proc loadDraft(ui: var ShotLogUi; map: ShotLogMap; width: int) =
  ui.draft = map
  ui.draftWidth = width
  while ui.draft.roles.len < width: ui.draft.roles.add crText
  if ui.draft.roles.len > width: ui.draft.roles.setLen(width)
  ui.skip = int32(max(0, map.skipLines))
  setText(ui.pattern, map.dateTimePattern)
  setText(ui.sentinels, sentinelsText(map.sentinels))

proc readDraft(ui: var ShotLogUi) =
  ui.draft.skipLines = max(0, int(ui.skip))
  ui.draft.dateTimePattern = bufText(ui.pattern).strip
  ui.draft.sentinels = splitSentinels(bufText(ui.sentinels))

proc rowHits(st: AppState; i, row, width: int; needle: string): bool =
  for c in 0 ..< width:
    let cell = st.shotCell(i, row, c)
    if cell.len >= needle.len and needle in cell.toLowerAscii: return true

proc scanFilter(ui: var ShotLogUi; st: AppState; i, width, n: int) =
  if ui.needle.len == 0 or ui.filterDone or i < 0: return
  let stop = min(n, ui.scanAt + ScanBatch)
  for row in ui.scanAt ..< stop:
    if rowHits(st, i, row, width, ui.needle) and
        (not ui.problemsOnly or ui.faultText.hasKey(row)):
      ui.matches.add row
  ui.scanAt = stop
  ui.filterDone = ui.scanAt >= n

proc listedCount(ui: ShotLogUi; n: int): int =
  if ui.needle.len > 0: ui.matches.len
  elif ui.problemsOnly: ui.faultRows.len
  else: n

proc listedRow(ui: ShotLogUi; i: int): int =
  if ui.needle.len > 0: ui.matches[i]
  elif ui.problemsOnly: ui.faultRows[i]
  else: i

proc listedIndex(ui: ShotLogUi; row, n: int): int =
  ## Where data row `row` sits in the list on show, or -1.
  result = -1
  if ui.needle.len > 0:
    for i, r in ui.matches:
      if r == row: return i
  elif ui.problemsOnly:
    for i, r in ui.faultRows:
      if r == row: return i
  elif row in 0 ..< n:
    result = row

proc nextListed(ui: ShotLogUi; row, col, width, n: int): tuple[row, col: int] =
  ## The next editable cell after (`row`, `col`), or (-1, -1).
  if width <= 0: return (-1, -1)
  if col + 1 < width: return (row, col + 1)
  let at = ui.listedIndex(row, n)
  if at < 0: return (-1, -1)
  if at + 1 >= ui.listedCount(n): return (-1, -1)
  (ui.listedRow(at + 1), 0)

proc copyRow(st: AppState; i, row, width: int; d: Delimiter) =
  var cells = newSeq[string](width)
  for c in 0 ..< width: cells[c] = st.shotCell(i, row, c)
  igSetClipboardText(joinRow(cells, delimChar(d)).cstring)

proc roleCombo(col: int; role: var ColumnRole; marks: var Marks): bool =
  igSetNextItemWidth(-1)
  let open = igBeginCombo(("##role" & $col).cstring, label(role).cstring,
    ImGui_ComboFlags_HeightLargest.cint)
  marks.mark("shotlog.rolecombo " & $col)
  if open:
    for r in ColumnRole:
      if igSelectable_Bool(label(r).cstring, r == role, 0, ImVec2_c(x: 0, y: 0)):
        role = r
        result = true
      marks.mark("shotlog.roleitem " & $col & " " & label(r))
    igEndCombo()

proc enumCombo[T: enum](id: string; v: var T; width: float32): bool =
  igSetNextItemWidth(width)
  if igBeginCombo(id.cstring, ($v).cstring, 0):
    for x in T:
      if igSelectable_Bool(($x).cstring, x == v, 0, ImVec2_c(x: 0, y: 0)):
        v = x
        result = true
    igEndCombo()

proc drawColumns(ui: var ShotLogUi; st: AppState; i: int; t: Theme; marks: var Marks;
    busy: bool): seq[Command] =
  let width = ui.draftWidth
  for r in duplicateRoles(ui.draft.roles):
    wrapped(duplicateSentence(r), t.roles[rlWarning])
    marks.mark("shotlog.duplicate " & label(r))
  igAlignTextToFramePadding()
  igTextUnformatted("Delimiter", nil)
  igSameLine(0, -1)
  discard enumCombo("##delim", ui.draft.delimiter, igGetFontSize() * 8)
  marks.mark("shotlog.delimiter")
  igSameLine(0, -1)
  igTextUnformatted("lines to skip", nil)
  igSameLine(0, -1)
  igSetNextItemWidth(igGetFontSize() * 6)
  discard igInputInt("##skip", addr ui.skip, 1, 10, 0)
  if ui.skip < 0: ui.skip = 0
  marks.mark("shotlog.skip")
  igSameLine(0, -1)
  var header = ui.draft.hasHeader
  if igCheckbox("header row", addr header): ui.draft.hasHeader = header
  marks.mark("shotlog.header")
  igAlignTextToFramePadding()
  igTextUnformatted("Clock", nil)
  igSameLine(0, -1)
  discard enumCombo("##clock", ui.draft.clock, igGetFontSize() * 6)
  marks.mark("shotlog.clock")
  tip("The clock of the split fields and of the date-time text")
  igAlignTextToFramePadding()
  igTextUnformatted("Date-time pattern", nil)
  igSameLine(0, -1)
  igSetNextItemWidth(-1)
  discard igInputText("##pattern", cast[cstring](addr ui.pattern[0]),
    csize_t(ui.pattern.len), 0, nil, nil)
  marks.mark("shotlog.pattern")
  tip("yyyy, mm, dd, hh, ss, f and literals. Empty: the usual forms are recognized.")
  igTextUnformatted("Missing values, one per line", nil)
  discard igInputTextMultiline("##sentinels", cast[cstring](addr ui.sentinels[0]),
    csize_t(ui.sentinels.len), ImVec2_c(x: -1, y: igGetTextLineHeight() * 4), 0, nil, nil)
  marks.mark("shotlog.sentinels")
  let tableH = max(igGetTextLineHeight() * 6,
    igGetContentRegionAvail().y - igGetFrameHeightWithSpacing())
  if igBeginTable("shotlog.columns", 3, ImGui_TableFlags_RowBg.cint or
      ImGui_TableFlags_BordersInnerV.cint or ImGui_TableFlags_ScrollY.cint or
      ImGui_TableFlags_SizingStretchProp.cint, ImVec2_c(x: 0, y: tableH), 0):
    igTableSetupColumn("Column", 0, 0, 0)
    igTableSetupColumn("First values", 0, 0, 1)
    igTableSetupColumn("Meaning", 0, 0, 2)
    igTableHeadersRow()
    for c in 0 ..< width:
      igTableNextRow(0, 0)
      igPushID_Int(cint(c))
      discard igTableNextColumn()
      let name = st.shotLogColumn(i, c)
      igTextUnformatted((if name.len > 0: name else: "Column " & $(c + 1)).cstring, nil)
      marks.mark("shotlog.role " & $c & " " & label(ui.draft.roles[c]))
      discard igTableNextColumn()
      var sample = ""
      for r in 0 ..< min(3, st.shotView(i).rows.len):
        if r > 0: sample.add " | "
        sample.add st.shotCell(i, r, c)
      igTextUnformatted(sample.cstring, nil)
      discard igTableNextColumn()
      discard roleCombo(c, ui.draft.roles[c], marks)
      igPopID()
    igEndTable()
  igBeginDisabled(busy)
  if igButton(ApplyButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts and not busy:
    ui.readDraft()
    result.add Command(kind: ckRemapShotLog, logIndex: i, logMap: ui.draft)
    ui.columnsOpen = false
  igEndDisabled()
  marks.mark("shotlog.apply")
  tip(if busy: "A read is under way" else: "Read the table again with this map")
  igSameLine(0, -1)
  if igButton(CancelButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
    ui.columnsOpen = false
  marks.mark("shotlog.cancel")
  tip("Leave the map as it was")
  igSameLine(0, -1)
  igBeginDisabled(busy)
  if igButton(GuessButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts and not busy:
    ui.loadDraft(st.shotLogGuess(i), width)
  igEndDisabled()
  marks.mark("shotlog.guess")
  tip("Fill the map from the header names and the first rows")

proc commitEdit(ui: var ShotLogUi; i, width, n: int; st: AppState; advance: bool;
    commands: var seq[Command]) =
  let text = ui.editText
  let row = ui.editRow
  let col = ui.editCol
  if hasBreak(text):
    ui.editReason = ShotLogLineBreak
    ui.armEdit = true
    commands.add Command(kind: ckEditShotCell, logIndex: i, logRow: row, logCol: col,
      logCell: text)
    return
  commands.add Command(kind: ckEditShotCell, logIndex: i, logRow: row, logCol: col,
    logCell: text)
  if advance:
    let nxt = ui.nextListed(row, col, width, n)
    if nxt.row >= 0:
      ui.pending = true
      ui.pendingRow = nxt.row
      ui.pendingCol = nxt.col
      ui.scrollTo = nxt.row
  ui.editing = false
  ui.editReason = ""

proc cornerMark(t: Theme) =
  let mn = igGetItemRectMin()
  let mx = igGetItemRectMax()
  let s = igGetFontSize() * 0.4
  ImDrawList_AddTriangleFilled(igGetWindowDrawList(),
    ImVec2_c(x: mx.x, y: mn.y),
    ImVec2_c(x: mx.x - s, y: mn.y),
    ImVec2_c(x: mx.x, y: mn.y + s),
    u32(t.roles[rlHighlight]))

proc cellBox(text: string; acts: bool; copy = true): tuple[clicked, copied: bool] =
  let shown = if text.len == 0: " " else: text
  if igSelectable_Bool((shown & "##c").cstring, false, 0, ImVec2_c(x: 0, y: 0)) and acts:
    result.clicked = true
  if copy and igIsItemClicked(ImGui_MouseButton_Right.cint) and acts:
    igSetClipboardText(text.cstring)
    result.copied = true

proc drawEditor(ui: var ShotLogUi; i, width, n: int; st: AppState; t: Theme;
    marks: var Marks; commands: var seq[Command]) =
  igBeginGroup()
  if ui.armEdit:
    igSetKeyboardFocusHere(0)
    ui.armEdit = false
  igSetNextItemWidth(-1)
  let h = igGetTextLineHeight() + igGetStyle().FramePadding.y * 2
  let flags = ImGui_InputTextFlags_EnterReturnsTrue.cint or
    ImGui_InputTextFlags_CtrlEnterForNewLine.cint or
    ImGui_InputTextFlags_AutoSelectAll.cint or
    ImGui_InputTextFlags_CallbackAlways.cint
  let entered = igInputTextMultiline("##edit", cast[cstring](addr ui.editBuf[0]),
    csize_t(ui.editBuf.len), ImVec2_c(x: 0, y: h), flags, selectEditedCell, nil)
  marks.mark("shotlog.editbox")
  marks.mark("shotlog.edittext " & ui.editText)
  let escape = igIsKeyPressed_Bool(ImGui_Key_Escape, false)
  let tab = igIsKeyPressed_Bool(ImGui_Key_Tab, false) and not igGetIO_Nil().KeyShift
  if entered or tab:
    ui.commitEdit(i, width, n, st, tab, commands)
  elif escape or igIsItemDeactivated():
    ui.stopEdit()
  if ui.editReason.len > 0:
    wrapped(ui.editReason, t.roles[rlWarning])
    marks.mark("shotlog.editreason")
  igEndGroup()

proc drawGrid(ui: var ShotLogUi; st: AppState; i, width, n: int; t: Theme;
    marks: var Marks): seq[Command] =
  if not ui.allowEditing:
    if ui.editing or ui.pending: ui.stopEdit()
  elif ui.pending and not ui.editing:
    ui.beginEdit(ui.pendingRow, ui.pendingCol, st.shotCell(i, ui.pendingRow, ui.pendingCol))
    ui.scrollTo = ui.pendingRow
  ui.scanFilter(st, i, width, n)
  let listed = ui.listedCount(n)
  if ui.needle.len > 0 and not ui.filterDone:
    dim("Filtering...", t)
    marks.mark("shotlog.filtering")
  elif ui.needle.len > 0:
    marks.mark("shotlog.filtered " & $listed)
  if ui.problemsOnly: marks.mark("shotlog.problemsonly")
  marks.mark("shotlog.listed " & $listed)
  let font = igGetFontSize()
  let flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
    ImGui_TableFlags_ScrollX.cint or ImGui_TableFlags_Resizable.cint or
    ImGui_TableFlags_BordersInnerV.cint or ImGui_TableFlags_SizingFixedFit.cint
  if not igBeginChild_Str("##grid", ImVec2_c(x: 0, y: 0), 0, 0): return
  marks.markWindow("shotlog.grid")
  if not igBeginTable("shotlog.grid", cint(2 + width), flags, ImVec2_c(x: 0, y: 0), 0):
    igEndChild()
    return
  igTableSetupScrollFreeze(2, 2)
  igTableSetupColumn(TimeHeader.cstring, ImGui_TableColumnFlags_WidthFixed.cint, font * 16, 0)
  igTableSetupColumn(StatusHeader.cstring, ImGui_TableColumnFlags_WidthFixed.cint, font * 2, 1)
  for c in 0 ..< width:
    let name = st.shotLogColumn(i, c)
    igTableSetupColumn((if name.len > 0: name else: "Column " & $(c + 1)).cstring,
      ImGui_TableColumnFlags_WidthFixed.cint, font * 8, ImGuiID(10 + c))
  igTableNextRow(ImGui_TableRowFlags_Headers.cint, 0)
  for c in 0 ..< 2 + width:
    if igTableSetColumnIndex(cint(c)):
      igTableHeader(igTableGetColumnName_Int(cint(c)))
  igTableNextRow(ImGui_TableRowFlags_Headers.cint, 0)
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  for c in 0 ..< 2 + width:
    if igTableSetColumnIndex(cint(c)):
      let role = if c < 2: "" elif c - 2 < st.shotLogMap(i).roles.len:
        label(st.shotLogMap(i).roles[c - 2]) else: label(crText)
      igTextUnformatted(role.cstring, nil)
      if c >= 2: marks.mark("shotlog.role " & $(c - 2) & " " & role)
  igPopStyleColor(1)
  let highlight = u32(withAlpha(t.roles[rlHighlight], 70))
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(listed), -1)
  let jump = ui.listedIndex(ui.scrollTo, n)
  if jump >= 0: ImGuiListClipper_IncludeItemByIndex(clipper, cint(jump))
  if ui.editing:
    let at = ui.listedIndex(ui.editRow, n)
    if at >= 0: ImGuiListClipper_IncludeItemByIndex(clipper, cint(at))
  var edge = -1
  let delim = st.shotLogMap(i).delimiter
  while ImGuiListClipper_Step(clipper):
    for at in clipper.DisplayStart ..< clipper.DisplayEnd:
      let row = ui.listedRow(at)
      edge = row
      igTableNextRow(0, 0)
      igPushID_Int(cint(row))
      if row == ui.selected:
        igTableSetBgColor(ImGui_TableBgTarget_RowBg1.cint, highlight, -1)
      let us = st.shotView(i).rows[row].timeUtcUs
      let time = if us.isNone: "" else: utcMicrosText(us.get)
      discard igTableNextColumn()
      igPushID_Int(-1)
      let timeHit = cellBox(time, ui.focus.acts)
      igPopID()
      if timeHit.clicked:
        ui.selected = row
        ui.selectedCol = -1
      if row == 0: marks.mark("shotlog.time 0 " & time)
      discard igTableNextColumn()
      let fault = if ui.faultText.hasKey(row): ui.faultText[row] else: ""
      igPushID_Int(-2)
      let statusHit = cellBox(if fault.len > 0: IconWarning else: "", ui.focus.acts)
      igPopID()
      if statusHit.clicked:
        ui.selected = row
        ui.selectedCol = -1
      if fault.len > 0: tip(fault)
      for c in 0 ..< width:
        if igTableNextColumn():
          igPushID_Int(cint(c))
          let text = st.shotCell(i, row, c)
          let editing = ui.editing and row == ui.editRow and c == ui.editCol
          if editing:
            ui.drawEditor(i, width, n, st, t, marks, result)
          else:
            let differs = st.shotCellDiffers(i, row, c)
            if differs:
              igTableSetBgColor(ImGui_TableBgTarget_CellBg.cint, highlight, -1)
            let hit = cellBox(text, ui.focus.acts, not differs)
            if hit.clicked:
              ui.selected = row
              ui.selectedCol = c
            let dbl = ui.allowEditing and igIsItemHovered(0) and
              igIsMouseDoubleClicked_Nil(ImGui_MouseButton_Left.cint) and ui.focus.acts
            if dbl: ui.beginEdit(row, c, text)
            if differs:
              if igBeginPopupContextItem(nil, ImGui_PopupFlags_MouseButtonRight.cint):
                if igMenuItem_Bool("Copy", nil, false, true):
                  igSetClipboardText(text.cstring)
                if ui.allowEditing and igMenuItem_Bool(RevertCell.cstring, nil, false, true):
                  result.add Command(kind: ckEditShotCell, logIndex: i, logRow: row,
                    logCol: c, logCell: st.shotFileCell(i, row, c))
                igEndPopup()
              cornerMark(t)
              marks.mark("shotlog.edited " & $row & " " & $c)
              tip(st.shotFileCell(i, row, c))
          igPopID()
          if row == 0: marks.mark("shotlog.cell 0 " & $c & " " & text)
      if row == ui.selected: marks.mark("shotlog.at " & $row)
      if row == ui.scrollTo:
        if not igIsItemVisible(): igSetScrollHereY(0.5)
        ui.scrollTo = -1
      igPopID()
  if edge >= 0: marks.mark("shotlog.edge " & $edge)
  igEndTable()
  if ui.selected >= 0 and igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint) and
      not igGetIO_Nil().WantTextInput and igGetIO_Nil().KeyCtrl and
      igIsKeyPressed_Bool(ImGui_Key_C, false):
    copyRow(st, i, ui.selected, width, delim)
  if ui.allowEditing and not ui.editing and ui.selected >= 0 and ui.selectedCol >= 0 and
      ui.selectedCol < width and
      igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint) and
      not igGetIO_Nil().WantTextInput and igIsKeyPressed_Bool(ImGui_Key_F2, false):
    ui.scrollTo = ui.selected
    ui.beginEdit(ui.selected, ui.selectedCol, st.shotCell(i, ui.selected, ui.selectedCol))
  igEndChild()

proc drawProblems(ui: var ShotLogUi; st: AppState; i: int; t: Theme; marks: var Marks) =
  let list = st.shotView(i).problems
  if list.items.len == 0:
    dim(EmptyProblems, t)
    marks.mark("shotlog.noproblems")
    return
  if list.count > list.items.len: dim(CappedNote, t)
  for p in list.items:
    let line = if p.row >= 0: "row " & $(p.row + 1) else: "log"
    igPushID_Int(cint(p.row))
    if igButton(line.cstring, ImVec2_c(x: 0, y: 0)) and p.row >= 0:
      ui.selected = p.row
      ui.scrollTo = p.row
      ui.tab = 0
      ui.forceGrid = true
    igPopID()
    if p.row >= 0: marks.mark("shotlog.problem " & $p.row)
    tip("Show this row in the grid")
    igSameLine(0, -1)
    igTextUnformatted(p.text.cstring, nil)

proc drawShotLog*(ui: var ShotLogUi; title: string; st: AppState; t: Theme;
    marks: var Marks): seq[Command] =
  ## The window, titled `title`, while it is open. Edits and a re-map are commands.
  if not ui.shown:
    ui.focus.blur()
    return
  if ui.bringUp:
    igSetWindowFocus_Str(title.cstring)
    ui.bringUp = false
  ui.follow(st)
  let i = st.findShotLog(ui.currentId)
  let rev = if i >= 0: st.shotRevision(i) else: -1
  ui.bindLog(st, i, rev)
  let vp = igGetMainViewport()
  let cond = if ui.placeAgain: ImGui_Cond_Always.cint else: ImGui_Cond_FirstUseEver.cint
  ui.placeAgain = false
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + 16, y: vp.WorkPos.y + 16), cond,
    ImVec2_c(x: 0, y: 0))
  igSetNextWindowSize(ImVec2_c(x: max(igGetFontSize() * 48, vp.WorkSize.x * 0.78),
    y: max(igGetFontSize() * 28, vp.WorkSize.y * 0.84)), cond)
  var open = true
  if igBegin(title.cstring, addr open, ImGui_WindowFlags_NoDocking.cint):
    ui.focus.watch()
    marks.markWindow("shotlog")
    let where = whereOf(st)
    let reading = st.shotLogReading() or (i >= 0 and st.shotLogBusy(i))
    if i < 0:
      let line = if reading: Reading & " " & where else: NoLog & " " & where
      igTextUnformatted(line.cstring, nil)
      marks.mark("shotlog.summary " & line)
      if reading: marks.mark("shotlog.reading")
    else:
      let width = st.shotLogWidth(i)
      let n = st.shotView(i).rows.len
      let problems = st.shotView(i).problems.count
      let file = st.shotLogSource(i).extractFilename
      let name = if file.len > 0: file else: st.shotLogName(i)
      var line = shotLogSummary(name, n, width, problems, where)
      if st.inProject and st.project.readOnly:
        line.add " · "
        line.add ReadOnlyShotLog
      igAlignTextToFramePadding()
      if ui.allowEditing:
        igBeginDisabled(st.shotUndoCount(i) == 0)
        if igButton((IconUndo & "##undoshot").cstring, ImVec2_c(x: 0, y: 0)) and
            ui.focus.acts:
          result.add Command(kind: ckUndoShotEdit, logIndex: i)
        igEndDisabled()
        marks.mark("shotlog.undo")
        tip(UndoCellTip)
        igSameLine(0, -1)
        igBeginDisabled(st.shotRedoCount(i) == 0)
        if igButton((IconRedo & "##redoshot").cstring, ImVec2_c(x: 0, y: 0)) and
            ui.focus.acts:
          result.add Command(kind: ckRedoShotEdit, logIndex: i)
        igEndDisabled()
        marks.mark("shotlog.redo")
        tip(RedoCellTip)
        igSameLine(0, -1)
      igTextUnformatted(line.cstring, nil)
      marks.mark("shotlog.summary")
      marks.mark("shotlog.summary " & line)
      if reading:
        dim(Reading, t)
        marks.mark("shotlog.reading")
      if st.shotLogCount > 1:
        igSetNextItemWidth(igGetFontSize() * 16)
        let shown = st.shotLogName(i)
        if igBeginCombo("##logs", shown.cstring, 0):
          for k in 0 ..< st.shotLogCount:
            let id = st.shotLogId(k)
            if igSelectable_Bool(st.shotLogName(k).cstring, id == ui.currentId, 0,
                ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
              ui.currentId = id
              ui.seenMax = max(ui.seenMax, id)
            marks.mark("shotlog.log " & $id)
          igEndCombo()
        marks.mark("shotlog.logs")
      igSetNextItemWidth(igGetFontSize() * 14)
      discard igInputText("##filter", cast[cstring](addr ui.filter[0]),
        csize_t(ui.filter.len), 0, nil, nil)
      marks.mark("shotlog.filter")
      tip("Show rows whose cells hold this text")
      let typed = bufText(ui.filter).strip
      if typed != ui.filterText:
        ui.filterText = typed
        ui.needle = typed.toLowerAscii
        ui.resetScan()
      igSameLine(0, -1)
      var only = ui.problemsOnly
      if igCheckbox(ProblemsOnly.cstring, addr only) and ui.focus.acts:
        ui.problemsOnly = only
        ui.resetScan()
      marks.mark("shotlog.problemsbox")
      igSameLine(0, -1)
      var allow = ui.allowEditing
      if igCheckbox(AllowEditing.cstring, addr allow) and ui.focus.acts:
        ui.allowEditing = allow
        if not allow: ui.stopEdit()
      marks.mark("shotlog.allowbox")
      if ui.allowEditing: marks.mark("shotlog.allowon")
      tip(AllowEditingTip)
      igSameLine(0, -1)
      igBeginDisabled(reading)
      if igButton(ColumnsButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts and
          not reading:
        if not ui.columnsOpen: ui.loadDraft(st.shotLogMap(i), width)
        ui.columnsOpen = true
      igEndDisabled()
      marks.mark("shotlog.columns")
      tip("How the table was read, and what each column means")
      if ui.columnsOpen:
        result.add ui.drawColumns(st, i, t, marks, reading)
      else:
        if igBeginTabBar("shotlog.tabs", 0):
          let gridFlags = if ui.forceGrid: ImGui_TabItemFlags_SetSelected.cint else: 0
          let gridOn = igBeginTabItem(GridTab.cstring, nil, gridFlags)
          marks.mark("shotlog.tab Grid")
          if gridOn:
            ui.forceGrid = false
            ui.tab = 0
            result.add ui.drawGrid(st, i, width, n, t, marks)
            igEndTabItem()
          let problemsOn = igBeginTabItem(ProblemsTab.cstring, nil, 0)
          marks.mark("shotlog.tab Problems")
          if problemsOn:
            ui.tab = 1
            ui.drawProblems(st, i, t, marks)
            igEndTabItem()
          igEndTabBar()
    if i >= 0 and ui.allowEditing and ui.focus.focused and
        not igGetIO_Nil().WantTextInput:
      let io = igGetIO_Nil()
      if io.KeyCtrl and igIsKeyPressed_Bool(ImGui_Key_Z, false):
        if io.KeyShift:
          result.add Command(kind: ckRedoShotEdit, logIndex: i)
        else:
          result.add Command(kind: ckUndoShotEdit, logIndex: i)
      elif io.KeyCtrl and igIsKeyPressed_Bool(ImGui_Key_Y, false):
        result.add Command(kind: ckRedoShotEdit, logIndex: i)
    ui.focus.settle()
  else:
    ui.focus.blur()
  igEnd()
  if not open: ui.shown = false
