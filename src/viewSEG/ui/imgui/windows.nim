## The windows the main window docks, and what the Window menu does with
## them: which are shown (each with a tick: shown or hidden, and brought
## forward), all put back as at a first start (`resetWindows`, in `app`), all
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
## Shortcuts=1
## ```
##
## `Shortcuts` is whether Help > Keyboard shortcuts is open (1 or 0). A
## layout that does not say is closed.
##
## A layout without it (a preset, one written by an earlier build) shows
## every window, and so does one that does not name a window (one a later
## build added): a window is hidden only when a layout says so. The live
## spectrum panel (`OffUnlessNamed`) works while it is on screen, so a layout
## from before it came keeps it hidden until the Window menu shows it. The Aux
## window, Missing traces, Trace quality and Vibrator QC (`ClosedAtStart`) are
## closed unless a layout shows them, also at a first start and after Reset the
## windows. Missing traces, Trace quality, Vibrator QC and Output, the first time
## each is opened, dock as a tab beside the Seismic window.

import std/strutils
import sdl3_nim
import imguin/cimgui
import ../../core/[geometry, screens]

type
  AppWindow* = enum
    ## The windows the main window docks, in the Window menu's order, by
    ## the IDs their titles end with (`"###plot"`): what layouts store.
    awSeismic = "plot", awFiles = "files", awRecords = "records", awMap = "map",
    awHeaders = "headers", awJobs = "jobs", awMessages = "Messages", awSpectrum = "spectrum",
    awAux = "aux", awMissing = "missing", awQuality = "quality",
    awVibFolder = "vibfolder", awOutput = "output", awShotLog = "shotlog"

  WindowsUi* = object
    ## The windows' state between frames.
    hidden*: set[AppWindow] = {awAux, awMissing, awQuality, awVibFolder, awOutput, awShotLog}
      ## not drawn: unticked in the Window menu (the same set as `ClosedAtStart`)
    front: set[AppWindow]   ## brought forward when next drawn
    unknown: set[AppWindow] ## the layout arranged last does not name them
    placeAux: bool = true
      # dock the Aux window to the right the next time it is shown with no dock
      # node (a first open, and after Reset the windows)
    placeMissing: bool = true
      # dock Missing traces beside the Seismic window the next time it is shown
      # with no dock node (a first open, and after Reset the windows)
    placeQuality: bool = true
      # dock Trace quality beside the Seismic window the next time it is shown
      # with no dock node (a first open, and after Reset the windows)
    placeVibFolder: bool = true
      # dock Vibrator QC beside the Seismic window the next time it is shown
      # with no dock node (a first open, and after Reset the windows)
    placeOutput: bool = true
      # dock Output beside the Seismic window the next time it is shown with no
      # dock node (a first open, and after Reset the windows)
    placeShotLog: bool = true
      # dock the Shot log beside the Headers window the next time it is shown with no
      # dock node (a first open, and after Reset the windows)
    shortcutsOpen*: bool ## Help > Keyboard shortcuts is open
    dockspace*: ImGuiID ## the main window's dockspace

const
  WindowNames*: array[AppWindow, string] = ["Seismic", "Files", "Records", "Map", "Headers",
    "Jobs", "Messages", "Spectrum", "Aux", "Missing traces", "Trace quality",
    "Vibrator QC", "Output", "Shot log"]
    ## what the Window menu calls them (the Seismic window's title follows
    ## what it shows: `windowTitle`)
  AlwaysShown* = {awSeismic} ## the plot: brought forward, never hidden
  OffUnlessNamed* = {awSpectrum, awAux, awMissing, awQuality, awVibFolder, awOutput, awShotLog}
    ## hidden when a layout does not name them (it was written before they came,
    ## or it never opened a window that stays closed until asked)
  ClosedAtStart* = {awAux, awMissing, awQuality, awVibFolder, awOutput, awShotLog}
    ## hidden until opened: a first start, a layout that does not say, and Reset the
    ## windows. The Aux window shows a second plot, which most work does not want;
    ## Missing traces, Trace quality and Vibrator QC are reports, opened from the
    ## Reports menu; Output is opened from the File menu; the Shot log opens when a shot
    ## log is imported.
  SectionHeader = "[viewSEG][Windows]"
  neighbours: array[AppWindow, seq[AppWindow]] = [awSeismic: @[], awFiles: @[awRecords],
    awRecords: @[awFiles], awMap: @[awHeaders], awHeaders: @[awMap], awJobs: @[awMessages],
    awMessages: @[awJobs], awSpectrum: @[awMap, awHeaders], awAux: @[awSeismic],
    awMissing: @[awSeismic], awQuality: @[awSeismic], awVibFolder: @[awSeismic],
    awOutput: @[awSeismic], awShotLog: @[awHeaders, awSeismic]]
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
  # Before a layout is read: every window shown unless it says otherwise,
  # and the shortcut list closed unless the layout says it is open.
  cast[ptr WindowsUi](h.UserData).hidden = ClosedAtStart
  cast[ptr WindowsUi](h.UserData).shortcutsOpen = false

proc readOpen(ctx: ptr ImGuiContext; h: ptr ImGuiSettingsHandler;
    name: cstring): pointer {.cdecl.} =
  if name == "Windows": h.UserData else: nil

proc readLine(ctx: ptr ImGuiContext; h: ptr ImGuiSettingsHandler; entry: pointer;
    line: cstring) {.cdecl.} =
  let text = $line
  if text.startsWith("Hidden="):
    cast[ptr WindowsUi](entry).hidden = hiddenOf(text.substr("Hidden=".len))
  elif text.startsWith("Shortcuts="):
    cast[ptr WindowsUi](entry).shortcutsOpen = text.substr("Shortcuts=".len).strip == "1"

proc writeAll(ctx: ptr ImGuiContext; h: ptr ImGuiSettingsHandler;
    buf: ptr ImGuiTextBuffer) {.cdecl.} =
  let w = cast[ptr WindowsUi](h.UserData)
  var text = hiddenSection(w.hidden)
  if text.endsWith("\n\n"): text.setLen(text.len - 1)
  text.add "Shortcuts=" & (if w.shortcutsOpen: "1" else: "0") & "\n\n"
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

var closeAsked: set[AppWindow] ## close buttons clicked this frame, not yet applied

proc askClose*(w: AppWindow) =
  ## Window `w`'s close button was clicked (`closeClicked` hides it).
  closeAsked.incl w

proc beginClosable*(w: AppWindow; title: cstring; flags: cint = 0): bool =
  ## `igBegin` for window `w` with a close button in its title bar (a docked tab too).
  ## Clicking it is asked of `closeClicked`; the caller still calls `igEnd`.
  var open = true
  result = igBegin(title, addr open, flags)
  if not open: askClose(w)

proc shows*(ws: WindowsUi; w: AppWindow): bool {.inline.} =
  ## Whether `w` is drawn.
  w notin ws.hidden

proc willShow*(ws: WindowsUi; w: AppWindow): bool =
  ## Whether a Window-menu click on `w` shows it (hidden, always shown, or a
  ## tab behind another) rather than hiding it.
  w in ws.hidden or w in AlwaysShown or behind(w)

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

proc closeClicked*(ws: var WindowsUi) =
  ## Once a frame, after the windows are drawn: hides each window whose close button was
  ## clicked, as unticking it in the Window menu does.
  let asked = closeAsked
  closeAsked = {}
  for w in asked: ws.hide(w)

proc picked*(ws: var WindowsUi; w: AppWindow) =
  ## Its Window menu entry was clicked: a hidden window is shown in front, a
  ## tab hidden behind another is brought forward, a window in sight is
  ## hidden (the plot is brought forward).
  if w in ws.hidden or w in AlwaysShown or behind(w): ws.bringForward(w)
  else: ws.hide(w)

proc showAll*(ws: var WindowsUi) =
  ## Every window shown but the ones closed at start, none waiting to be placed (Reset the
  ## windows).
  if ws.hidden != ClosedAtStart: changed()
  ws.hidden = ClosedAtStart
  ws.unknown = {}
  ws.placeAux = true
  ws.placeMissing = true
  ws.placeQuality = true
  ws.placeVibFolder = true
  ws.placeOutput = true
  ws.placeShotLog = true

proc arranged*(ws: var WindowsUi; text: string; docked: bool) =
  ## The layout `text` was applied (and `hidden` read from it): the windows
  ## it does not name are placed beside their neighbours when next drawn.
  ## With `docked` false the default arrangement is built: nothing to place.
  ws.unknown = {}
  if docked:
    for w in AppWindow:
      if not text.named(w):
        if w in OffUnlessNamed: ws.hidden.incl w
        ws.unknown.incl w
    # a layout that names the Aux window, Missing traces, Trace quality or
    # Vibrator QC keeps its place
    ws.placeAux = not text.named(awAux)
    ws.placeMissing = not text.named(awMissing)
    ws.placeQuality = not text.named(awQuality)
    ws.placeVibFolder = not text.named(awVibFolder)
    ws.placeOutput = not text.named(awOutput)
    ws.placeShotLog = not text.named(awShotLog)

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
  ## the plot), as a tab. Missing traces, Trace quality, Vibrator QC and Output,
  ## the first time, are a tab of the Seismic window and are selected.
  if w == awMissing and ws.placeMissing and dockIdOf(w) == 0:
    # first opened, and after Reset the windows: a tab beside the Seismic
    # window. A window that already has a dock node, or that the user undocked,
    # keeps that place.
    ws.unknown.excl w
    var id = dockIdOf(awSeismic)
    if id == 0:
      let centre = igDockBuilderGetCentralNode(ws.dockspace)
      if centre != nil: id = centre.ID
    if id != 0:
      igSetNextWindowDockID(id, ImGui_Cond_Always.cint)
      igSetNextWindowFocus()
      changed()
  elif w == awMissing and dockIdOf(w) != 0:
    ws.placeMissing = false
  if w == awQuality and ws.placeQuality and dockIdOf(w) == 0:
    ws.unknown.excl w
    var id = dockIdOf(awSeismic)
    if id == 0:
      let centre = igDockBuilderGetCentralNode(ws.dockspace)
      if centre != nil: id = centre.ID
    if id != 0:
      igSetNextWindowDockID(id, ImGui_Cond_Always.cint)
      igSetNextWindowFocus()
      changed()
  elif w == awQuality and dockIdOf(w) != 0:
    ws.placeQuality = false
  if w == awVibFolder and ws.placeVibFolder and dockIdOf(w) == 0:
    ws.unknown.excl w
    var id = dockIdOf(awSeismic)
    if id == 0:
      let centre = igDockBuilderGetCentralNode(ws.dockspace)
      if centre != nil: id = centre.ID
    if id != 0:
      igSetNextWindowDockID(id, ImGui_Cond_Always.cint)
      igSetNextWindowFocus()
      changed()
  elif w == awVibFolder and dockIdOf(w) != 0:
    ws.placeVibFolder = false
  if w == awOutput and ws.placeOutput and dockIdOf(w) == 0:
    ws.unknown.excl w
    var id = dockIdOf(awSeismic)
    if id == 0:
      let centre = igDockBuilderGetCentralNode(ws.dockspace)
      if centre != nil: id = centre.ID
    if id != 0:
      igSetNextWindowDockID(id, ImGui_Cond_Always.cint)
      igSetNextWindowFocus()
      changed()
  elif w == awOutput and dockIdOf(w) != 0:
    ws.placeOutput = false
  if w == awShotLog and ws.placeShotLog and dockIdOf(w) == 0:
    # a tab of the Headers window (the table beside the map), so that opening it
    # does not cover the plot; the plot's node when Headers is not docked
    ws.unknown.excl w
    var id = if ws.shows(awHeaders): dockIdOf(awHeaders) else: 0
    if id == 0: id = dockIdOf(awSeismic)
    if id == 0:
      let centre = igDockBuilderGetCentralNode(ws.dockspace)
      if centre != nil: id = centre.ID
    if id != 0:
      igSetNextWindowDockID(id, ImGui_Cond_Always.cint)
      igSetNextWindowFocus()
      changed()
  elif w == awShotLog and dockIdOf(w) != 0:
    ws.placeShotLog = false
  if w == awAux and dockIdOf(w) == 0 and (windowOf(w) == nil or ws.placeAux):
    # first opened, and after Reset the windows: a strip to the right of the
    # Seismic window, 30 % of its width (a window of its own, or a layout that
    # places it, keeps its place)
    ws.unknown.excl w
    let plot = dockIdOf(awSeismic)
    if plot != 0:
      ws.placeAux = false
      var right, left: ImGuiID
      discard igDockBuilderSplitNode(plot, ImGuiDir_Right, 0.3, addr right, addr left)
      igSetNextWindowDockID(right, ImGui_Cond_Always.cint)
      changed()
  elif w == awAux and dockIdOf(w) != 0:
    ws.placeAux = false
  elif w in ws.unknown:
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
    let win = windowOf(w)
    if win == nil:
      # not drawn yet: ask for the focus now, and select its tab next frame
      igSetNextWindowFocus()
    else:
      ws.front.excl w
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

proc windowNames(): seq[string] =
  ## The names of every window Dear ImGui keeps settings for: the "[Window][name]" lines of
  ## its layout text. Whatever window the program opens is in it, with no list of ours.
  for line in splitLines($igSaveIniSettingsToMemory(nil)):
    if line.startsWith("[Window][") and line.endsWith("]"):
      result.add line[9 ..< line.high]

proc floatingWindows(): seq[(ptr ImGuiWindow, string)] =
  ## Every window the program has on screen that is a window of its own: not a child, a
  ## popup or a tooltip, not one that cannot be moved (the dock host, the menu bar, the
  ## overlays). A window docked in a tree of its own stands for that tree. Found from
  ## `windowNames`, so a new kind of window is covered without being listed anywhere.
  const apart = ImGui_WindowFlags_ChildWindow.cint or ImGui_WindowFlags_Popup.cint or
    ImGui_WindowFlags_Tooltip.cint or ImGui_WindowFlags_NoMove.cint
  const noInputs = ImGui_WindowFlags_NoInputs.cint # (a combination: all of its bits)
  for name in windowNames():
    var win = igFindWindowByName(("###" & name).cstring) # a window named by its ID alone
    if win == nil: win = igFindWindowByName(name.cstring)
    if win != nil and (win.Active or win.WasActive):
      let top = if win.DockIsActive and win.RootWindowDockTree != nil: win.RootWindowDockTree
                else: win
      if top != nil and (top.Flags and apart) == 0 and (top.Flags and noInputs) != noInputs and
          not ($win.Name).startsWith("##"):
        var known = false
        for (w, _) in result:
          if w == top: known = true
        if not known: result.add (top, titleText($win.Name))

proc bringAllInto*(area: Rect): seq[string] =
  ## Moves every floating window (`floatingWindows`: the analysis windows, the FFT windows,
  ## the reference archive, About, the dialogs, and any window that is an OS window of its
  ## own) wholly into `area`, made smaller when larger than it; a window that lay outside the
  ## main window is then in it. Returns the names of the windows moved.
  for (win, name) in floatingWindows():
    let r = win.rectOf
    let to = r.fitOnto(area)
    if to != r:
      if to.size != r.size:
        igSetWindowSize_WindowPtr(win, ImVec2_c(x: to.size.x, y: to.size.y),
          ImGui_Cond_Always.cint)
      igSetWindowPos_WindowPtr(win, ImVec2_c(x: to.pos.x, y: to.pos.y), ImGui_Cond_Always.cint)
      result.add name
  if result.len > 0: changed()

proc moveFloating*(titlePart: string; x, y: float32): bool =
  ## Puts the window whose title holds `titlePart` at (`x`, `y`) in the desktop's coordinates,
  ## taking it out of its dock first: the state a dragged window or a loaded layout leaves
  ## (tests).
  let ctx = igGetCurrentContext()
  for name in windowNames():
    var win = igFindWindowByName(("###" & name).cstring)
    if win == nil: win = igFindWindowByName(name.cstring)
    if win != nil and (win.Active or win.WasActive) and
        (win.Flags and ImGui_WindowFlags_ChildWindow.cint) == 0 and
        titlePart in titleText($win.Name) and not result:
      if win.DockIsActive: igDockContextProcessUndockWindow(ctx, win, true)
      igSetWindowPos_WindowPtr(win, ImVec2_c(x: x, y: y), ImGui_Cond_Always.cint)
      result = true
