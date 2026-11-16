## Help > Keyboard shortcuts: the list from `core/shortcuts`, menu rows named
## as this platform names them. A filter box has the focus when it opens;
## groups are collapsible headers; Escape closes it. An ordinary dockable
## window: its place is Dear ImGui's, and whether it is open is kept with
## the other windows (`windows.shortcutsOpen`).

import imguin/cimgui
import ../../core/shortcuts
import ../../view/theme
import icons, marks, menus, shortcutkeys, style

type
  ShortcutsUi* = object
    shown*: bool
    focusFilter*: bool ## the filter box takes the keyboard when next drawn
    filter: array[64, char]
    placed: bool

const Title = IconList & "  Keyboard shortcuts###shortcuts"

proc open*(ui: var ShortcutsUi) =
  ## Shows the window, with an empty filter and the focus in it.
  ui.shown = true
  ui.focusFilter = true
  zeroMem(addr ui.filter[0], ui.filter.len)

proc drawShortcuts*(ui: var ShortcutsUi; t: Theme; marks: var Marks) =
  ## The window, when it is open.
  if not ui.shown: return
  if not ui.placed:
    # In the main window, over the plot, until the user docks it. A window
    # of its own would not be in the main window's picture.
    let vp = igGetMainViewport()
    igSetNextWindowViewport(vp.ID)
    igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + 180, y: vp.WorkPos.y + 36),
      ImGui_Cond_FirstUseEver.cint, ImVec2_c(x: 0, y: 0))
    igSetNextWindowSize(ImVec2_c(x: 640, y: 480), ImGui_Cond_FirstUseEver.cint)
    ui.placed = true
  var open = true
  if igBegin(Title.cstring, addr open, 0):
    if ui.focusFilter:
      let win = igGetCurrentWindow()
      if win.DockNode != nil and win.DockNode.TabBar != nil:
        win.DockNode.TabBar.NextSelectedTabId = win.TabId
      igSetWindowFocus_Str(Title.cstring)
    marks.markWindow("shortcuts")
    if ui.focusFilter:
      igSetKeyboardFocusHere(0)
      ui.focusFilter = false
    discard igInputTextWithHint("##filter", "Filter, such as zoom or ctrl",
      cast[cstring](addr ui.filter[0]), csize_t(ui.filter.len), 0, nil, nil)
    marks.mark("shortcuts.filter")
    let typed = $cast[cstring](addr ui.filter[0])
    let rows = filtered(namedRows(), typed)
    if typed.len > 0 and rows.len == 0:
      igTextDisabled("Nothing matches.")
      marks.mark("shortcuts.none")
    let filtering = typed.len > 0
    const tableFlags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_BordersInnerV.cint or
      ImGui_TableFlags_SizingStretchProp.cint or ImGui_TableFlags_PadOuterX.cint
    for g in ShortcutGroup:
      var mine: seq[ShortcutRow] = @[]
      for r in rows:
        if r.group == g: mine.add r
      if mine.len == 0: continue
      igSetNextItemOpen(true, (if filtering: ImGui_Cond_Always else: ImGui_Cond_Once).cint)
      if not igCollapsingHeader_TreeNodeFlags(($g).cstring, ImGui_TreeNodeFlags_None.cint):
        continue
      marks.mark("shortcuts.group " & $g)
      if igBeginTable(("##" & $g).cstring, 2, tableFlags, ImVec2_c(x: 0, y: 0), 0):
        igTableSetupColumn("Keys", ImGui_TableColumnFlags_WidthStretch.cint, 0.42, 0)
        igTableSetupColumn("What it does", ImGui_TableColumnFlags_WidthStretch.cint, 0.58, 1)
        for r in mine:
          igTableNextRow(0, 0)
          discard igTableNextColumn()
          igTextUnformatted(r.keys.cstring, nil)
          marks.mark("shortcuts.row " & r.id)
          discard igTableNextColumn()
          igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
          igTextWrapped("%s", r.what.cstring)
          igPopStyleColor(1)
        igEndTable()
    # The filter box would take Escape for itself. The key is the table's,
    # and it closes the window whether or not the box has the focus.
    let escape = imguiKey(chordOf("windows.close"))
    if escape != ImGui_Key_None and
        igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint) and
        igIsKeyPressed_Bool(escape, false):
      open = false
  igEnd()
  if not open: ui.shown = false
