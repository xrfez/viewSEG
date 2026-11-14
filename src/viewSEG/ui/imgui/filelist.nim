## The "Files" window: the file list (`core/filelist`) as a table at the side
## of the main window. A folder's seismic files, with their type, size and
## date; a filter box; the folders opened before, one click away; a refresh.
## Clicking a row shows that file in the plot window in place of the one it
## shows, keeping the display settings; while the window has the focus, the
## arrow keys, Tab and Shift + Tab step to the next or previous file and
## show it, Home and End to the first and last. Only the rows in view are
## drawn (ImGui's list clipper), so a folder of thousands of files costs a
## frame no more than a few.

import std/[os, times]
import imguin/cimgui
import ../../core/[geometry, state]
import ../../view/[filetable, theme]
import chrome, icons, menus, style

type
  FileListUi* = object
    ## The window's own state between frames.
    filter: array[128, char]
    table: FileTable
    order: FileOrder
    chosen: string ## the chosen file last frame: a new one is scrolled into view
    follow: bool

  FileListOutput* = object
    ## What the window asks for.
    commands*: seq[Command]
    actions*: set[MenuAction]

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

func filterText(ui: FileListUi): string = $cast[cstring](addr ui.filter[0])

func folderLabel(f: FileList): string =
  if f.folder.len > 0: f.folder.extractFilename
  elif f.title.len > 0: f.title
  else: "No folder"

proc drawFolderRow(ui: var FileListUi; f: FileList; recent: openArray[string]; t: Theme;
    marks: var Marks; res: var FileListOutput) =
  ## The folder listed, with the folders opened before in its drop-down, the
  ## "open folder" and the refresh buttons.
  let style = igGetStyle()
  let button = igGetFrameHeight()
  igSetNextItemWidth(max(button, igGetContentRegionAvail().x - 2 * (button + style.ItemSpacing.x)))
  let label = IconFolder & "  " & folderLabel(f)
  if igBeginCombo("##folder", label.cstring, 0):
    if recent.len == 0: igTextDisabled("No folder opened yet")
    for i, d in recent:
      igPushID_Int(cint(i))
      if igSelectable_Bool(d.cstring, d == f.folder, 0, ImVec2_c(x: 0, y: 0)):
        res.commands.add Command(kind: ckBrowse, paths: @[d])
      igPopID()
    igEndCombo()
  marks.mark("files.folder")
  tip(if f.title.len > 0: f.title & "\nThe folders opened before are in this list."
      else: "The folders opened before are in this list.")
  igSameLine(0, -1)
  if igButton((IconOpenFolder & "##openfolder").cstring, ImVec2_c(x: button, y: button)):
    res.actions.incl maOpenFolder
  marks.mark("files.open folder")
  tip("Open a folder (" & shortcutName(maOpenFolder) & ")")
  igSameLine(0, -1)
  let asked = if f.folder.len > 0: @[f.folder] else: f.asked
  igBeginDisabled(asked.len == 0)
  if igButton((IconRefresh & "##refresh").cstring, ImVec2_c(x: button, y: button)):
    res.commands.add Command(kind: ckBrowse, paths: asked)
  igEndDisabled()
  marks.mark("files.refresh")
  tip("List the folder again")

proc drawRows(ui: var FileListUi; f: FileList; t: Theme; marks: var Marks;
    res: var FileListOutput) =
  ## The table, sorted as its headers say, with only the rows in view drawn.
  # The name takes the room the others leave; a column can be hidden from
  # the headers' context menu.
  const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
    ImGui_TableFlags_Sortable.cint or ImGui_TableFlags_Resizable.cint or
    ImGui_TableFlags_Hideable.cint or ImGui_TableFlags_BordersInnerV.cint or
    ImGui_TableFlags_SizingFixedFit.cint
  let footer = igGetTextLineHeightWithSpacing() + igGetStyle().ItemSpacing.y
  if not igBeginTable("##files", 4, flags, ImVec2_c(x: 0, y: -footer), 0): return
  igTableSetupScrollFreeze(0, 1)
  igTableSetupColumn("Name", ImGui_TableColumnFlags_DefaultSort.cint or
    ImGui_TableColumnFlags_WidthStretch.cint or ImGui_TableColumnFlags_NoHide.cint, 1, 0)
  igTableSetupColumn("Type", 0, 0, 1)
  igTableSetupColumn("Size", ImGui_TableColumnFlags_PreferSortDescending.cint, 0, 2)
  igTableSetupColumn("Modified", ImGui_TableColumnFlags_PreferSortDescending.cint, 0, 3)
  igTableHeadersRow()
  let specs = igTableGetSortSpecs()
  if specs != nil and specs.SpecsCount > 0:
    let s = specs.Specs[]
    ui.order = FileOrder(column: FileColumn(clamp(int(s.ColumnIndex), 0, 3)),
      descending: s.SortDirection == ImGui_SortDirection_Descending)
    specs.SpecsDirty = false
  ui.table.update(f, ui.filterText, ui.order)
  let chosenRow = ui.table.rowOf(f, f.chosen)
  let today = getTime()
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(ui.table.rows.len), -1)
  if ui.follow and chosenRow >= 0:
    ImGuiListClipper_IncludeItemByIndex(clipper, cint(chosenRow))
  while ImGuiListClipper_Step(clipper):
    for r in clipper.DisplayStart ..< clipper.DisplayEnd:
      let e = f.entries[ui.table.rows[r]]
      igTableNextRow(0, 0)
      discard igTableNextColumn()
      let failed = e.path in f.failed
      if failed: igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlError]))
      igPushID_Int(cint(r))
      if igSelectable_Bool(e.name.cstring, e.path == f.chosen,
          ImGui_SelectableFlags_SpanAllColumns.cint, ImVec2_c(x: 0, y: 0)) and
          e.path != f.chosen:
        res.commands.add Command(kind: ckShowFile, panel: MainPanel, path: e.path)
      igPopID()
      if failed: igPopStyleColor(1)
      marks.mark("files.row " & e.name)
      if r == chosenRow and ui.follow:
        if not igIsItemVisible(): igSetScrollHereY(0.5)
        ui.follow = false
      tip(e.path & "\n" & sizeText(e.size) & ", modified " & dateText(e.modified) &
        (if failed: "\nIt could not be opened: Messages says why." else: ""))
      discard igTableNextColumn()
      igTextUnformatted(typeText(e).cstring, nil)
      discard igTableNextColumn()
      let size = sizeText(e.size)
      let w = igCalcTextSize(size.cstring, nil, false, -1).x
      igSetCursorPosX(igGetCursorPosX() + max(0, igGetContentRegionAvail().x - w))
      igTextUnformatted(size.cstring, nil)
      discard igTableNextColumn()
      igTextUnformatted(shortDateText(e.modified, today).cstring, nil)
  ImGuiListClipper_End(clipper)
  ImGuiListClipper_destroy(clipper)
  igEndTable()
  marks.mark("files.table")

proc footer(f: FileList; shown: int; t: Theme) =
  ## What the list holds, or how far the listing is, under the table.
  var text = ""
  var colour = t.roles[rlTextDim]
  if f.error.len > 0:
    text = "Listing stopped: " & f.error
    colour = t.roles[rlWarning]
  elif f.scanning:
    text = "Listing... " & $f.entries.len & " seismic files so far"
  elif f.title.len == 0:
    text = "Open a folder to list its seismic files."
  else:
    text = $f.entries.len & (if f.entries.len == 1: " seismic file" else: " seismic files")
    if shown < f.entries.len: text.add ", " & $shown & " shown"
    if f.others > 0: text.add "; " & $f.others & " other files not listed"
    if f.unreadable > 0: text.add "; " & $f.unreadable & " could not be read"
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour))
  igTextUnformatted(text.cstring, nil)
  igPopStyleColor(1)

proc handleKeys(ui: FileListUi; f: FileList; res: var FileListOutput) =
  ## Up / Down, Tab / Shift + Tab, Home / End while the window has the
  ## focus and no text box has the keyboard: the next file is shown.
  if igGetIO_Nil().WantTextInput: return
  template held(chord: cint): bool = igShortcut_Nil(chord, ImGui_InputFlags_Repeat.cint)
  let shift = ImGui_Mod_Shift.cint
  var delta = 0
  if held(ImGui_Key_DownArrow.cint) or held(ImGui_Key_Tab.cint): delta = 1
  if held(ImGui_Key_UpArrow.cint) or held(shift or ImGui_Key_Tab.cint): delta = -1
  if held(ImGui_Key_PageDown.cint): delta = 10
  if held(ImGui_Key_PageUp.cint): delta = -10
  if igShortcut_Nil(ImGui_Key_Home.cint, 0): delta = -high(int32)
  if igShortcut_Nil(ImGui_Key_End.cint, 0): delta = high(int32)
  if delta != 0:
    let next = ui.table.stepped(f, f.chosen, delta)
    if next.len > 0 and next != f.chosen:
      res.commands.add Command(kind: ckShowFile, panel: MainPanel, path: next)

proc drawFileList*(ui: var FileListUi; title: string; st: AppState; t: Theme;
    marks: var Marks): FileListOutput =
  ## The window, docked or floating like any other, titled `title`. Returns
  ## the commands and actions it asks for.
  # The arrow keys and Tab step through the files, so ImGui's keyboard
  # navigation does not move between the rows here.
  if igBegin(title.cstring, nil, ImGui_WindowFlags_NoNavInputs.cint):
    marks.markWindow("files")
    let f = st.fileList
    if f.chosen != ui.chosen:
      ui.chosen = f.chosen
      ui.follow = true
    ui.drawFolderRow(f, st.settings.recentFolders, t, marks, result)
    igSetNextItemWidth(-1)
    discard igInputTextWithHint("##filter", (IconFilter & "  Filter by name").cstring,
      cast[cstring](addr ui.filter[0]), csize_t(ui.filter.len), 0, nil, nil)
    marks.mark("files.filter")
    tip("Show only the files whose names hold every word typed here")
    ui.drawRows(f, t, marks, result)
    footer(f, ui.table.rows.len, t)
    marks.mark("files.footer")
    if igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint):
      ui.handleKeys(f, result)
  igEnd()
