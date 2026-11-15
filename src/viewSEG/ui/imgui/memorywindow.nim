## The "File memory" window (File > File memory...): what viewSEG remembers
## about the files opened (their kills and polarity reversals, kept beside
## them by their content, `core/filememory`), a row per file: the name it
## was last seen under, when it was last opened, what is kept, the file's
## size and its entry's. Entries go only through this window: the one
## selected, those not opened for a number of days, or those whose file is
## gone; each removal first lists what it takes away and waits for a
## confirmation, and each entry removed is said in Messages.
##
## A floating window, as "Import survey" is; it reads the store again
## (`ckFileMemory`) when it opens and on Refresh.

import std/sequtils
import imguin/cimgui
import ../../core/state
import ../../view/[memorylist, theme]
import chrome, focus, icons, style

type
  Removal = enum
    rmNone, rmSelected, rmOld, rmGone

  MemoryUi* = object
    ## The window's own state between frames.
    shown*: bool
    bringUp: bool
    placeAgain: bool
    ask: bool            ## read the store again next frame
    focus: FocusClicks
    selected: string     ## the selected entry's document; "" for none
    days*: int32 = 90    ## "not opened for" this many days
    asked: Removal       ## a removal waiting for its confirmation
    going: seq[MemoryRow]
      ## the entries it takes away, as they were listed when it was asked
      ## for (a listing that comes meanwhile changes the rows, not these)
    popup: bool          ## open the confirmation next frame
    rows: seq[MemoryRow] ## the listing's rows, made again when it changes
    rowsRev: int = -1    ## the listing's revision they were made from

  MemoryOutput* = object
    commands*: seq[Command]

proc open*(ui: var MemoryUi) =
  ## Shows the window, in front, and reads the store again.
  ui.shown = true
  ui.bringUp = true
  ui.ask = true

proc placeAgain*(ui: var MemoryUi) =
  ## Puts the window back at its first place and size when next drawn.
  ui.placeAgain = true

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc button(label, mark, help: string; enabled: bool; marks: var Marks): bool =
  igBeginDisabled(not enabled)
  result = igButton(label.cstring, ImVec2_c(x: 0, y: 0))
  igEndDisabled()
  marks.mark(mark)
  tip(help)

const confirmId = "Remove from the file memory?###memory.confirm"

proc drawConfirm(ui: var MemoryUi; res: var MemoryOutput; marks: var Marks) =
  ## The confirmation: what the removal asked for takes away, then Remove or
  ## Cancel.
  if ui.popup:
    igOpenPopup_Str(confirmId.cstring, 0)
    ui.popup = false
  igSetNextWindowSize(ImVec2_c(x: igGetFontSize() * 30, y: 0), ImGui_Cond_Appearing.cint)
  if igBeginPopupModal(confirmId.cstring, nil, ImGui_WindowFlags_AlwaysAutoResize.cint):
    marks.markWindow("memory.confirm")
    let n = ui.going.len
    igTextWrapped("%s", (if n == 1: "This is forgotten:" else: $n &
      " files are forgotten:").cstring)
    let shownRows = min(n, 12)
    for j in 0 ..< shownRows:
      let r = ui.going[j]
      igBulletText("%s", (r.name & "  (" & r.kept & ")").cstring)
    if n > shownRows: igBulletText("%s", ("and " & $(n - shownRows) & " more").cstring)
    igTextWrapped("%s", ("Their kills and polarity reversals are no longer brought back " &
      "when they are opened. The files themselves are not touched.").cstring)
    igSeparator()
    if igButton((IconTrash & "  Remove").cstring, ImVec2_c(x: 0, y: 0)):
      var docs: seq[string]
      for r in ui.going: docs.add r.doc
      res.commands.add Command(kind: ckForgetFiles, forget: docs)
      if ui.selected in docs: ui.selected = ""
      ui.going.setLen 0
      igCloseCurrentPopup()
    marks.mark("memory.confirm.remove")
    igSameLine(0, -1)
    if igButton("Cancel", ImVec2_c(x: 0, y: 0)) or igIsKeyPressed_Bool(ImGui_Key_Escape,
        false):
      ui.going.setLen 0
      igCloseCurrentPopup()
    marks.mark("memory.confirm.cancel")
    igEndPopup()

proc drawMemory*(ui: var MemoryUi; title: string; st: AppState; t: Theme;
    marks: var Marks): MemoryOutput =
  ## The window, titled `title`, while it is open.
  if not ui.shown: return
  if ui.ask:
    result.commands.add Command(kind: ckFileMemory)
    ui.ask = false
  if ui.bringUp:
    igSetWindowFocus_Str(title.cstring)
    ui.bringUp = false
  let vp = igGetMainViewport()
  let cond = if ui.placeAgain: ImGui_Cond_Always.cint else: ImGui_Cond_FirstUseEver.cint
  ui.placeAgain = false
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + vp.WorkSize.x / 2, y: vp.WorkPos.y +
    vp.WorkSize.y / 2), cond, ImVec2_c(x: 0.5, y: 0.5))
  igSetNextWindowSize(ImVec2_c(x: min(igGetFontSize() * 52, vp.WorkSize.x - 40),
    y: min(igGetFontSize() * 26, vp.WorkSize.y - 40)), cond)
  var open = true
  if igBegin(title.cstring, addr open, ImGui_WindowFlags_NoDocking.cint):
    ui.focus.watch()
    marks.markWindow("memory")
    let list = st.memoryList
    if ui.rowsRev != list.revision: # not every frame: thousands of entries in words
      ui.rows = memoryRows(list.records)
      ui.rowsRev = list.revision
    template rows: untyped = ui.rows
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
    igTextWrapped("%s", ("What viewSEG remembers about the files you opened: their kills " &
      "and polarity reversals, kept by each file's content (so a file renamed or moved " &
      "keeps them) in " & (if st.store.isNowhere: "no folder in this run" else: st.store.home) &
      ". The files themselves are never changed.").cstring)
    igPopStyleColor(1)
    if list.listing: igTextDisabled("Reading...")
    elif list.listed and rows.len == 0: igTextDisabled("Nothing is remembered.")
    for p in list.problems:
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
      igTextWrapped("%s", (IconWarning & "  " & p).cstring)
      igPopStyleColor(1)
    let footer = (igGetFrameHeightWithSpacing() + igGetStyle().ItemSpacing.y) * 2
    const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_BordersInnerV.cint or
      ImGui_TableFlags_ScrollY.cint or ImGui_TableFlags_Resizable.cint
    if rows.len > 0 and igBeginTable("##memory", 6, flags, ImVec2_c(x: 0, y: -footer), 0):
      igTableSetupScrollFreeze(0, 1)
      igTableSetupColumn("File", ImGui_TableColumnFlags_WidthStretch.cint, 0, 0)
      igTableSetupColumn("Last opened", ImGui_TableColumnFlags_WidthFixed.cint, 0, 0)
      igTableSetupColumn("Kept", ImGui_TableColumnFlags_WidthStretch.cint, 0, 0)
      igTableSetupColumn("Size", ImGui_TableColumnFlags_WidthFixed.cint, 0, 0)
      igTableSetupColumn("Entry", ImGui_TableColumnFlags_WidthFixed.cint, 0, 0)
      igTableSetupColumn("Where", ImGui_TableColumnFlags_WidthFixed.cint, 0, 0)
      igTableHeadersRow()
      let clipper = ImGuiListClipper_ImGuiListClipper() # only the rows in view
      ImGuiListClipper_Begin(clipper, cint(rows.len), -1)
      while ImGuiListClipper_Step(clipper):
        for i in clipper.DisplayStart ..< clipper.DisplayEnd:
          template r: untyped = rows[i]
          igPushID_Int(cint(i))
          igTableNextRow(0, 0)
          discard igTableNextColumn()
          if igSelectable_Bool(r.name.cstring, r.doc == ui.selected,
              ImGui_SelectableFlags_SpanAllColumns.cint, ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
            ui.selected = if r.doc == ui.selected: "" else: r.doc
          marks.mark("memory.row." & $i)
          tip(r.path)
          discard igTableNextColumn()
          igTextUnformatted(r.opened.cstring, nil)
          discard igTableNextColumn()
          igTextUnformatted(r.kept.cstring, nil)
          discard igTableNextColumn()
          igTextUnformatted(r.size.cstring, nil)
          discard igTableNextColumn()
          igTextUnformatted(r.entry.cstring, nil)
          discard igTableNextColumn()
          if r.gone:
            igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
            igTextUnformatted("gone", nil)
            igPopStyleColor(1)
            tip("No file of this size is at " & r.path & " any more (moved, renamed or " &
              "deleted). A file moved keeps what is remembered: open it to bring it back")
          elif r.looking:
            igTextDisabled("looking...")
            tip("Looking for it at " & r.path)
          elif r.silent:
            igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
            igTextUnformatted("not answering", nil)
            igPopStyleColor(1)
            tip("The drive of " & r.path & " did not answer within 3 seconds (a network " &
              "drive?), so this is not counted as gone. Refresh looks again")
          elif r.unreached:
            igTextDisabled("not found")
            tip("The folder " & r.path & " was in is not there or cannot be looked at (a " &
              "network drive not connected?), so this is not counted as gone")
          else:
            igTextDisabled("in place")
          igPopID()
      ImGuiListClipper_End(clipper)
      ImGuiListClipper_destroy(clipper)
      igEndTable()
    let at = block:
      var x = -1
      for i, r in rows:
        if r.doc == ui.selected: x = i
      x
    let enabled = not list.listing
    if button(IconTrash & "  Remove", "memory.remove", "Forget the file selected in the " &
        "list", enabled and at >= 0, marks) and ui.focus.acts:
      (ui.asked, ui.going, ui.popup) = (rmSelected, @[rows[at]], true)
    igSameLine(0, -1)
    let gone = goneRows(rows)
    if button(IconTrash & "  Remove the gone (" & $gone.len & ")", "memory.gone",
        "Forget the files that are not where they were last seen", enabled and gone.len > 0,
        marks) and ui.focus.acts:
      (ui.asked, ui.going, ui.popup) = (rmGone, gone.mapIt(rows[it]), true)
    igSameLine(0, -1)
    if button(IconRefresh & "  Refresh", "memory.refresh", "Read the file memory again",
        enabled, marks):
      ui.ask = true
    let old = notOpenedFor(rows, int(ui.days))
    if button(IconTrash & "  Remove those not opened for", "memory.old",
        "Forget the files not opened for this many days or more (" & $old.len & " now)",
        enabled and old.len > 0, marks) and ui.focus.acts:
      (ui.asked, ui.going, ui.popup) = (rmOld, old.mapIt(rows[it]), true)
    igSameLine(0, -1)
    igSetNextItemWidth(igGetFontSize() * 6)
    discard igInputInt("days", addr ui.days, 1, 30, 0)
    ui.days = clamp(ui.days, 0, 100_000)
    marks.mark("memory.days")
    ui.drawConfirm(result, marks)
    ui.focus.settle()
  igEnd()
  if not open: ui.shown = false
