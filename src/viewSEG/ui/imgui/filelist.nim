## The "Files" window: the file list (`core/filelist`) as a table at the side
## of the main window. A folder's seismic and survey files, with their type,
## size and date; a filter box; the folders opened before, one click away; a
## refresh. Clicking a seismic file's row shows that file in the plot window
## in place of the one it shows, keeping the display settings; while the
## window has the focus, the arrow keys step to the next or previous seismic
## file and show it, Home and End to the first and last.
## Clicking a survey file's row (SPS, P1) loads it into the survey instead:
## a pin marks it once loaded. The click that only brings the window forward
## does neither (`focus`). Only the rows in view are drawn (ImGui's list
## clipper), so a folder of thousands of files costs a frame no more than a
## few.
##
## **Keys.** Tab and Shift + Tab move between the window's controls (the
## folder's drop-down, its buttons, the filter, "Follow the latest file", the list), as in
## every window; Space or Enter acts on the one Tab reached. The arrow keys,
## Page Up and Page Down (ten files) and Home and End step through the files
## wherever the focus is in the window, but in the filter box (`listkeys`).
##
## The folder is watched (`core/watch`): a file that appears is listed and
## marked new (a dot in the accent colour) until it is shown; one whose size
## or time changed at the last look is marked as being written (a spinner, in
## the warning colour), and one that ends before its last trace as
## incomplete. "Follow the latest", at the foot, shows each new file once it
## is whole; off, the plot stays on the file the user chose.

import std/[os, times]
import imguin/cimgui
import ../../core/[geometry, state]
import ../../view/[filetable, theme]
import chrome, focus, icons, listkeys, menus, style

type
  FileListUi* = object
    ## The window's own state between frames.
    filter: array[128, char]
    table: FileTable
    order: FileOrder
    chosen: string     ## the chosen file last frame: a new one is scrolled into view
    follow: bool
    focus: FocusClicks ## a click on a row acts only in a window that had the focus
    keys: ListFocus    ## the navigation's cursor follows the file shown
    nextOf: string     ## the chosen file the next one was found for
    nextRev: int       ## the list's revision then
    toldNext: string   ## the next file `core` was told to prepare; "" for none

  FileListOutput* = object
    ## What the window asks for.
    commands*: seq[Command]
    actions*: set[MenuAction]
    toggleFollow*: bool ## "Follow the latest" was clicked

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

func filterText(ui: FileListUi): string = $cast[cstring](addr ui.filter[0])

func markOf(e: FileEntry): string =
  ## The glyph before a file's name: being written, incomplete, new, or none.
  case e.status
  of fsWriting: IconLoading
  of fsShort: IconWarning
  of fsSteady: (if e.isNew: IconNew else: "")

func markColour(e: FileEntry; t: Theme): Rgba =
  if e.status == fsSteady: t.roles[rlAccent] else: t.roles[rlWarning]

func markText(e: FileEntry): string =
  ## What a file's mark means, for its tooltip.
  result = case e.status
    of fsWriting: "\nBeing written: its size or time changed at the last look. It is " &
      "not shown by \"Follow the latest\" until it stops changing."
    of fsShort: "\nIncomplete: it ends before its last trace (still being written, or " &
      "cut short)."
    of fsSteady: ""
  if e.isNew: result.add "\nNew: it appeared after the folder was listed."

proc openedText(e: FileEntry; st: AppState): string =
  ## What a file's tooltip says of the options it is opened with this run
  ## ("Reopen with options"); nothing for the defaults.
  let c = st.openChoiceOf(e.path)
  if c.isDefault: "" else: "\nOpened with options: " & choiceText(c) & "."

proc surveyText(e: FileEntry; st: AppState): string =
  ## What a survey file's row says of it, for its tooltip.
  let i = st.survey.findFile(e.path)
  if i >= 0: "\nLoaded into the survey: " & st.survey.layers[i].summary & "."
  elif st.surveyLoading(e.path): "\nBeing loaded into the survey."
  else: "\nA survey file: click to load it into the survey."

proc focused(marks: var Marks) =
  ## Marks the item just drawn "files.focused" while the navigation's cursor
  ## is on it (Tab moved it there), for tests.
  if igIsItemFocused(): marks.mark("files.focused")

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
  ui.keys.beforeFirst()
  if igBeginCombo("##folder", label.cstring, 0):
    if recent.len == 0: igTextDisabled("No folder opened yet")
    for i, d in recent:
      igPushID_Int(cint(i))
      if igSelectable_Bool(d.cstring, d == f.folder, 0, ImVec2_c(x: 0, y: 0)):
        res.commands.add Command(kind: ckBrowse, paths: @[d])
      igPopID()
    igEndCombo()
  ui.keys.afterFirst()
  marks.mark("files.folder")
  focused(marks)
  tip(if f.title.len > 0: f.title & "\nThe folders opened before are in this list."
      else: "The folders opened before are in this list.")
  igSameLine(0, -1)
  if igButton((IconOpenFolder & "##openfolder").cstring, ImVec2_c(x: button, y: button)):
    res.actions.incl maOpenFolder
  marks.mark("files.open folder")
  focused(marks)
  tip(menuLabel(maOpenFolder) & " (" & shortcutName(maOpenFolder) & ")")
  igSameLine(0, -1)
  let asked = if f.folder.len > 0: @[f.folder] else: f.asked
  igBeginDisabled(asked.len == 0)
  if igButton((IconRefresh & "##refresh").cstring, ImVec2_c(x: button, y: button)):
    res.commands.add Command(kind: ckBrowse, paths: asked)
  igEndDisabled()
  marks.mark("files.refresh")
  focused(marks)
  tip("List the folder again")

proc drawRows(ui: var FileListUi; st: AppState; f: FileList; t: Theme; marks: var Marks;
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
  igPushItemFlag(ImGui_ItemFlags_NoTabStop.cint, true) # the list is one stop of Tab
  igTableHeadersRow()
  igPopItemFlag()
  let specs = igTableGetSortSpecs()
  if specs != nil and specs.SpecsCount > 0:
    let s = specs.Specs[]
    ui.order = FileOrder(column: FileColumn(clamp(int(s.ColumnIndex), 0, 3)),
      descending: s.SortDirection == ImGui_SortDirection_Descending)
    specs.SpecsDirty = false
  ui.table.update(f, ui.filterText, ui.order)
  let chosenRow = ui.table.chosenRow(f, f.chosen)
  let today = getTime()
  ui.keys.beforeRows()
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(ui.table.rows.len), -1)
  if ui.follow and chosenRow >= 0:
    ImGuiListClipper_IncludeItemByIndex(clipper, cint(chosenRow))
  while ImGuiListClipper_Step(clipper):
    for r in clipper.DisplayStart ..< clipper.DisplayEnd:
      template e: untyped = f.entries[ui.table.rows[r]]
      igTableNextRow(0, 0)
      discard igTableNextColumn()
      let failed = e.path in f.failed
      let x = igGetCursorPosX()
      igPushID_Int(cint(r))
      let survey = e.kind.isSurvey
      let shown = r == chosenRow
      if shown: ui.keys.beforeShownRow()
      pushRowTabStop(shown)
      if igSelectable_Bool("##row", e.path == f.chosen,
          ImGui_SelectableFlags_SpanAllColumns.cint, ImVec2_c(x: 0, y: 0)) and
          e.path != f.chosen and ui.focus.acts:
        res.commands.add(if survey: Command(kind: ckLoadSurvey, paths: @[e.path])
          else: Command(kind: ckShowFile, panel: MainPanel, path: e.path))
      popRowTabStop()
      ui.keys.afterRow()
      igPopID()
      marks.mark("files.row " & e.name)
      focused(marks)
      if r == chosenRow and ui.follow:
        if not igIsItemVisible(): igSetScrollHereY(0.5)
        ui.follow = false
      tip(e.path & "\n" & sizeText(e.size) & ", modified " & dateText(e.modified) &
        markText(e) & (if survey: surveyText(e, st) else: openedText(e, st)) &
        (if failed: "\nIt could not be " & (if survey: "loaded" else: "opened") &
          ": Messages says why." else: ""))
      # The mark and the name, over the row's selectable.
      igSameLine(0, 0)
      igSetCursorPosX(x)
      let mark = markOf(e)
      if mark.len > 0:
        igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(markColour(e, t)))
        igTextUnformatted(mark.cstring, nil)
        igPopStyleColor(1)
        marks.mark("files.mark " & e.name)
        igSameLine(0, -1)
      if survey and st.survey.findFile(e.path) >= 0:
        igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlAccent]))
        igTextUnformatted(IconLocation.cstring, nil)
        igPopStyleColor(1)
        marks.mark("files.loaded " & e.name)
        igSameLine(0, -1)
      let dim = e.status == fsWriting
      if failed or dim:
        igPushStyleColor_Vec4(ImGui_Col_Text.cint,
          vec4(if failed: t.roles[rlError] else: t.roles[rlTextDim]))
      igTextUnformatted(e.name.cstring, nil)
      if failed or dim: igPopStyleColor(1)
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
  ## What the list holds, or how far the listing is, under the table: how
  ## many files are seismic and survey files, and new and being written.
  var text = ""
  var colour = t.roles[rlTextDim]
  if f.error.len > 0:
    text = "Listing stopped: " & f.error
    colour = t.roles[rlWarning]
  elif f.scanning:
    text = "Listing... " & $f.entries.len & " seismic files so far"
  elif f.title.len == 0:
    text = menuLabel(maOpenFolder) & " to list its seismic files."
  else:
    var surveys = 0
    for e in f.entries:
      if e.kind.isSurvey: inc surveys
    let seismic = f.entries.len - surveys
    text = $seismic & (if seismic == 1: " seismic file" else: " seismic files")
    if surveys == 1: text.add ", 1 survey file"
    elif surveys > 1: text.add ", " & $surveys & " survey files"
    if shown < f.entries.len: text.add ", " & $shown & " shown"
    var fresh, writing = 0
    for e in f.entries:
      if e.isNew: inc fresh
      if e.status == fsWriting: inc writing
    if fresh > 0: text.add ", " & $fresh & " new"
    if writing > 0: text.add ", " & $writing & " being written"
    if f.others > 0: text.add "; " & $f.others & " other files not listed"
    if f.unreadable > 0: text.add "; " & $f.unreadable & " could not be read"
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour))
  igTextUnformatted(text.cstring, nil)
  igPopStyleColor(1)

proc handleKeys(ui: var FileListUi; f: FileList; res: var FileListOutput) =
  ## Up / Down, Page Up / Down, Home / End while the window has the focus
  ## and no text box has the keyboard: the next file is shown.
  let step = stepOf("files keys")
  ui.keys.stepped(step)
  let delta = case step
    of lsNone: 0
    of lsNext: 1
    of lsPrevious: -1
    of lsPageDown: 10
    of lsPageUp: -10
    of lsFirst: -high(int32)
    of lsLast: high(int32)
  if delta != 0:
    let next = ui.table.stepped(f, f.chosen, delta)
    if next.len > 0 and next != f.chosen:
      res.commands.add Command(kind: ckShowFile, panel: MainPanel, path: next)

proc drawFileList*(ui: var FileListUi; title: string; st: AppState; t: Theme;
    marks: var Marks): FileListOutput =
  ## The window, docked or floating like any other, titled `title`. Returns
  ## the commands and actions it asks for.
  # Tab moves between the controls (Dear ImGui's navigation); the arrow keys
  # step through the files (`listkeys`).
  if igBegin(title.cstring, nil, 0):
    ui.focus.watch()
    marks.markWindow("files")
    template f: untyped = st.fileList # a view: a copy would take every entry each frame
    if f.chosen != ui.chosen:
      ui.chosen = f.chosen
      ui.follow = true
    ui.drawFolderRow(f, st.settings.recentFolders, t, marks, result)
    # The filter, then "Follow the latest" at the row's end.
    let following = st.settings.files.followLatest
    let label = IconFollow & " " & FollowWords
    let style = igGetStyle()
    let w = igCalcTextSize(label.cstring, nil, false, -1).x + 2 * style.FramePadding.x
    igSetNextItemWidth(max(4 * igGetFontSize(), igGetContentRegionAvail().x - w -
      style.ItemSpacing.x))
    discard igInputTextWithHint("##filter", (IconFilter & "  Filter by name").cstring,
      cast[cstring](addr ui.filter[0]), csize_t(ui.filter.len), 0, nil, nil)
    marks.mark("files.filter")
    focused(marks)
    tip("Show only the files whose names hold every word typed here")
    igSameLine(0, -1)
    if following: # drawn selected, as the plot's toggles are
      igPushStyleColor_Vec4(ImGui_Col_Button.cint, vec4(t.roles[rlSelection]))
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlAccent]))
    ui.keys.beforeLast()
    if igButton(label.cstring, ImVec2_c(x: 0, y: 0)): result.toggleFollow = true
    ui.keys.afterLast()
    if following: igPopStyleColor(2)
    marks.mark("files.follow")
    focused(marks)
    tip(FollowWords & ": " & (if following: "on" else: "off") & ".\n" & FollowHelp)
    ui.drawRows(st, f, t, marks, result)
    footer(f, ui.table.rows.len, t)
    marks.mark("files.footer")
    let wait = st.listingWait()
    if wait.kind != wkNone:
      # The folder's drive does not answer: said, with Cancel and Retry.
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
      igTextWrapped("%s", (IconWarning & "  " & wait.words).cstring)
      igPopStyleColor(1)
      marks.mark("files.wait")
      if wait.job != NoJob:
        if igSmallButton("Cancel##filewait"):
          result.commands.add Command(kind: ckCancelJob, job: wait.job)
        marks.mark("files.wait.cancel")
        tip("Stop listing the folder")
        igSameLine(0, -1)
      if igSmallButton((IconRefresh & " Retry##filewait").cstring):
        result.commands.add Command(kind: ckRetry, panel: NoPanel)
      marks.mark("files.wait.retry")
      tip("List the folder again")
    ui.handleKeys(f, result)
    # The file a step down would show, prepared in the background (core
    # decides whether, by the setting); found again when the choice changes,
    # or while there was none yet and the list changed.
    if f.chosen.len > 0 and (f.chosen != ui.nextOf or
        (ui.toldNext.len == 0 and f.revision != ui.nextRev)):
      ui.nextOf = f.chosen
      ui.nextRev = f.revision
      let next = ui.table.stepped(f, f.chosen, 1)
      ui.toldNext = if next != f.chosen: next else: ""
      if ui.toldNext.len > 0:
        result.commands.add Command(kind: ckPrepare, panel: MainPanel, path: ui.toldNext)
  ui.focus.settle()
  igEnd()
