## The windows the main window docks, and what the Window menu does with
## them: which are shown (each with a tick: shown or hidden, and brought
## forward), all put back as at a first start (`resetLayout`, in `app`), all
## brought onto the main window's screen, a window that a layout does not
## know docked beside its neighbours and shown, and the windows a layout
## puts off every screen brought back at start. The rules on screens are
## `core/screens`; this module asks SDL for the screens and moves Dear
## ImGui's windows.
##
## Which windows are hidden is part of the layout, kept in Dear ImGui's own
## text in a section of the program's own, which Dear ImGui writes and reads
## through a settings handler (`installHandler`):
##
## ```
## [viewSEG][Windows]
## Hidden=jobs,records
## ```
##
## A layout without it (a preset, one written by an earlier build) shows
## every window, and so does one that does not name a window (one a later
## build added): a window is hidden only when a layout says so.

import std/strutils
import sdl3_nim
import imguin/cimgui
import ../../core/[geometry, screens]

type
  AppWindow* = enum
    ## The windows the main window docks, in the Window menu's order, by
    ## the IDs their titles end with (`"###plot"`): what layouts store.
    awSeismic = "plot", awFiles = "files", awRecords = "records", awMap = "map",
    awHeaders = "headers", awJobs = "jobs", awMessages = "Messages"

  WindowsUi* = object
    ## The windows' state between frames.
    hidden*: set[AppWindow] ## not drawn: unticked in the Window menu
    front: set[AppWindow]   ## brought forward when next drawn
    unknown: set[AppWindow] ## the layout arranged last does not name them
    dockspace*: ImGuiID     ## the main window's dockspace

const
  WindowNames*: array[AppWindow, string] = ["Seismic", "Files", "Records", "Map", "Headers",
    "Jobs", "Messages"]
    ## what the Window menu calls them (the Seismic window's title follows
    ## what it shows: `windowTitle`)
  AlwaysShown* = {awSeismic} ## the plot: brought forward, never hidden
  SectionHeader = "[viewSEG][Windows]"
  neighbours: array[AppWindow, seq[AppWindow]] = [awSeismic: @[], awFiles: @[awRecords],
    awRecords: @[awFiles], awMap: @[awHeaders], awHeaders: @[awMap], awJobs: @[awMessages],
    awMessages: @[awJobs]]
    ## where a window a layout does not know is docked (as a tab): beside
    ## the first of these that is docked, as in the default layout; else
    ## beside the plot

func hiddenSection*(hidden: set[AppWindow]): string =
  ## The layout text's section that says which windows are hidden.
  var ids: seq[string]
  for w in hidden - AlwaysShown: ids.add $w
  SectionHeader & "\nHidden=" & ids.join(",") & "\n\n"

func hiddenOf*(value: string): set[AppWindow] =
  ## The windows named in a `Hidden=` line's value (IDs, by commas); names
  ## not known (a later build's windows) and the plot are left out.
  result = {}
  for id in value.split(','):
    for w in AppWindow:
      if id.strip == $w and w notin AlwaysShown: result.incl w

func named*(text: string; w: AppWindow): bool =
  ## Whether the layout text `text` holds window `w`'s place.
  ("[Window][" & $w & "]") in text or ("[Window][###" & $w & "]") in text

# ------------------------------------------------- the settings handler --

proc readInit(ctx: ptr ImGuiContext; h: ptr ImGuiSettingsHandler) {.cdecl.} =
  # Before a layout is read: every window shown unless it says otherwise.
  cast[ptr WindowsUi](h.UserData).hidden = {}

proc readOpen(ctx: ptr ImGuiContext; h: ptr ImGuiSettingsHandler;
    name: cstring): pointer {.cdecl.} =
  if name == "Windows": h.UserData else: nil

proc readLine(ctx: ptr ImGuiContext; h: ptr ImGuiSettingsHandler; entry: pointer;
    line: cstring) {.cdecl.} =
  let text = $line
  if text.startsWith("Hidden="):
    cast[ptr WindowsUi](entry).hidden = hiddenOf(text.substr("Hidden=".len))

proc writeAll(ctx: ptr ImGuiContext; h: ptr ImGuiSettingsHandler;
    buf: ptr ImGuiTextBuffer) {.cdecl.} =
  let text = hiddenSection(cast[ptr WindowsUi](h.UserData).hidden)
  ImGuiTextBuffer_append(buf, text.cstring, nil)

proc installHandler*(w: var WindowsUi) =
  ## Has Dear ImGui keep which windows are hidden in its layout text, read
  ## into and written from `w`, which must stay where it is until the
  ## context is destroyed. Once per Dear ImGui context, before a layout is
  ## loaded.
  var h = ImGuiSettingsHandler(TypeName: "viewSEG", TypeHash: igImHashStr("viewSEG", 0, 0),
    ReadInitFn: readInit, ReadOpenFn: readOpen, ReadLineFn: readLine, WriteAllFn: writeAll,
    UserData: addr w)
  igAddSettingsHandler(addr h) # Dear ImGui keeps a copy

proc changed() =
  ## The layout changed: Dear ImGui says so (`WantSaveIniSettings`) a
  ## moment later, and the layout is saved.
  igMarkIniSettingsDirty_Nil()

# ------------------------------------------------------- the windows --

proc windowOf(w: AppWindow): ptr ImGuiWindow =
  ## Dear ImGui's window `w`; nil before it was first drawn.
  igFindWindowByName(("###" & $w).cstring)

proc behind(w: AppWindow): bool =
  ## Whether `w` is docked as a tab that another tab hides.
  let win = windowOf(w)
  win != nil and win.DockIsActive and not win.DockTabIsVisible

proc shows*(ws: WindowsUi; w: AppWindow): bool {.inline.} =
  ## Whether `w` is drawn.
  w notin ws.hidden

proc bringForward*(ws: var WindowsUi; w: AppWindow) =
  ## Shows `w` (when it was hidden) in front, with the focus, next frame.
  if w in ws.hidden:
    ws.hidden.excl w
    changed()
  ws.front.incl w

proc hide*(ws: var WindowsUi; w: AppWindow) =
  ## Stops drawing `w`; its place in the layout is kept for when it is
  ## shown again. The plot is never hidden.
  if w notin AlwaysShown and w notin ws.hidden:
    ws.hidden.incl w
    ws.front.excl w
    changed()

proc picked*(ws: var WindowsUi; w: AppWindow) =
  ## Its Window menu entry was clicked: a hidden window is shown in front, a
  ## tab hidden behind another is brought forward, a window in sight is
  ## hidden (the plot is brought forward).
  if w in ws.hidden or w in AlwaysShown or behind(w): ws.bringForward(w)
  else: ws.hide(w)

proc showAll*(ws: var WindowsUi) =
  ## Every window shown, none waiting to be placed (Reset the windows).
  if ws.hidden != {}: changed()
  ws.hidden = {}
  ws.unknown = {}

proc arranged*(ws: var WindowsUi; text: string; docked: bool) =
  ## The layout `text` was applied (and `hidden` read from it): the windows
  ## it does not name are placed beside their neighbours when next drawn.
  ## With `docked` false the default arrangement is built: nothing to place.
  ws.unknown = {}
  if docked:
    for w in AppWindow:
      if not text.named(w): ws.unknown.incl w

proc dockIdOf(w: AppWindow): ImGuiID =
  ## The dock node `w` is in, or was put in by the layout; 0 for none.
  result = 0
  let win = windowOf(w)
  if win != nil:
    result = win.DockId
  else:
    let s = igFindWindowSettingsByID(igImHashStr(("###" & $w).cstring, 0, 0))
    if s != nil: result = s.DockId
  if result != 0 and igDockBuilderGetNode(result) == nil: result = 0

proc beforeDrawing*(ws: var WindowsUi; w: AppWindow) =
  ## Just before `w` is drawn (its `igBegin`): brings it forward when asked;
  ## a window the layout did not know is docked beside its neighbours (or
  ## the plot), as a tab.
  if w in ws.unknown:
    ws.unknown.excl w
    var id: ImGuiID = 0
    for n in neighbours[w]:
      if id == 0 and ws.shows(n): id = dockIdOf(n)
    if id == 0:
      let central = igDockBuilderGetCentralNode(ws.dockspace)
      if central != nil: id = central.ID
    if id != 0:
      igSetNextWindowDockID(id, ImGui_Cond_Always.cint)
      changed()
  if w in ws.front:
    ws.front.excl w
    let win = windowOf(w)
    if win != nil:
      # A tab gets its tab selected, as a click on it does: focus alone
      # shows it for one frame, then an older pending tab choice wins.
      if win.DockNode != nil and win.DockNode.TabBar != nil:
        win.DockNode.TabBar.NextSelectedTabId = win.TabId
      if win.Collapsed: igSetWindowCollapsed_WindowPtr(win, false, ImGui_Cond_Always.cint)
      igFocusWindow(win, 0)

# ----------------------------------------------------------- screens --

proc screensNow*(): (seq[Rect], int) =
  ## The screens' usable areas, in the desktop's coordinates, and which of
  ## them is the primary one (-1 when SDL says none).
  var list: seq[Rect]
  var primary = -1
  var count: cint
  let displays = SDL_GetDisplays(addr count)
  if displays != nil:
    let ids = cast[ptr UncheckedArray[SDL_DisplayID]](displays)
    let first = SDL_GetPrimaryDisplay()
    for i in 0 ..< count.int:
      var b: SDL_Rect
      if SDL_GetDisplayUsableBounds(ids[i], addr b) and b.w > 0 and b.h > 0:
        if ids[i] == first: primary = list.len
        list.add rect(b.x.int, b.y.int, b.w.int, b.h.int)
    SDL_free(displays)
  (list, primary)

proc rectOf(win: ptr ImGuiWindow): Rect =
  Rect(pos: vec2(win.Pos.x, win.Pos.y), size: vec2(win.Size.x, win.Size.y))

func titleText(name: string): string =
  ## A window's title as the user reads it: before its `###` ID, without
  ## the icon in front.
  result = name
  let at = result.find("##")
  if at >= 0: result.setLen at
  var i = 0
  while i < result.len and (result[i].ord >= 0x80 or result[i] == ' '): inc i
  result = result.substr(i).strip

proc apart(ids: openArray[string]): seq[(ptr ImGuiWindow, seq[string])] =
  ## The windows of the desktop's own, outside the main window, that hold
  ## the windows whose ImGui IDs are `ids` (each a window, or a group of
  ## windows docked together), with the names of those each holds.
  let main = cast[pointer](igGetMainViewport())
  for id in ids:
    let win = igFindWindowByName(("###" & id).cstring)
    if win != nil and (win.Active or win.WasActive):
      let top = if win.DockIsActive: win.RootWindowDockTree else: win
      if top != nil and cast[pointer](top.Viewport) != main and
          (top.Flags and ImGui_WindowFlags_NoMove.cint) == 0:
        var known = -1
        for i, (w, _) in result:
          if w == top: known = i
        if known < 0: result.add (top, @[titleText($win.Name)])
        else: result[known][1].add titleText($win.Name)

proc bringOnto*(screen: Rect; onlyUnreachable: bool; screens: openArray[Rect];
    ids: openArray[string]): seq[string] =
  ## Moves every window outside the main window that holds one of the
  ## windows `ids` names wholly onto `screen`, made smaller when it is
  ## larger; with `onlyUnreachable`, only those no screen of `screens` holds
  ## the top edge of. Returns the names of the windows moved.
  for (win, names) in apart(ids):
    let r = win.rectOf
    let to = r.fitOnto(screen)
    if to != r and (not onlyUnreachable or not r.reachable(screens)):
      if to.size != r.size:
        igSetWindowSize_WindowPtr(win, ImVec2_c(x: to.size.x, y: to.size.y),
          ImGui_Cond_Always.cint)
      igSetWindowPos_WindowPtr(win, ImVec2_c(x: to.pos.x, y: to.pos.y), ImGui_Cond_Always.cint)
      result.add names.join(" and ")
  if result.len > 0: changed()
