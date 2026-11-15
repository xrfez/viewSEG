## The main menu bar and its keyboard shortcuts. Each item is reachable both
## ways, and its shortcut is shown in the menu and in the toolbar's tooltips.
## Drawing returns what the user asked for; the caller acts on it.
##
## File opens, follows and closes files, holds every import (File >
## Import: a survey, settings, a layout, trace edits) and every export (File
## > Export: the messages, the settings, the layout, trace edits), each in
## that one place, and opens the File memory window (what is remembered
## about files: it is about files on disk, so File, not Window, which only
## arranges windows); Edit undoes, redoes and clears the trace edits of the
## file the Seismic window shows, whichever window has the focus (Ctrl+Z,
## Ctrl+Shift+Z and Ctrl+Y everywhere but in a text field, which keeps its
## own undo); View holds the theme; Window puts the windows right (Reset the
## windows, Bring all windows onto this screen), says whether the program's
## icon is in the tray and whether minimizing hides it there, shows, hides
## and brings forward each window, and loads and saves layouts.

import std/os
import imguin/cimgui
import ../../core/[analysis, layouts]
import ../../view/theme
import icons, marks, thememenu, windows

type
  MenuAction* = enum
    ## What a menu item, a shortcut or a button asks for; its name is how it
    ## is marked ("menu." and the name), and what it is called outside a
    ## submenu (`shownAs` in one).
    maOpenFile = "Open file...", maOpenFiles = "Open files...",
    maOpenFolder = "Open folder...", maClose = "Close",
    maImportSurvey = "Import survey...", maImportSettings = "Import settings...",
    maImportLayout = "Import layout...", maImportEdits = "Import trace edits...",
    maExportLog = "Export messages...", maExportSettings = "Export settings...",
    maExportLayout = "Export layout...", maExportEdits = "Export trace edits...",
    maFileMemory = "File memory...",
    maNewProject = "New project...", maOpenProject = "Open project...",
    maProject = "Project...", maCloseProject = "Close project",
    maResetSettings = "Reset the settings",
    maQuit = "Quit",
    maUndo = "Undo", maRedo = "Redo", maClearEdits = "Clear all edits for this file",
    maToggleTheme = "Light / dark",
    maResetWindows = "Reset the windows",
    maBringWindows = "Bring all windows onto this screen",
    maSaveLayout = "Save layout as...",
    maShowFiles = "Files", maShowRecords = "Records", maShowMap = "Map",
    maShowHeaders = "Headers", maShowJobs = "Jobs", maShowMessages = "Messages"

  MenuInput* = object
    ## What the menus show besides their fixed items.
    themes*: seq[ThemeFile]     ## listed under View > Theme
    theme*: string              ## the one checked; "" for following the system
    follows*: string            ## the theme file "Follow system" uses now
    recent*: seq[string]        ## File > Open recent, newest first
    recentFolders*: seq[string] ## the folders there, newest first
    canClose*: bool             ## a file is shown, so File > Close closes it
    layouts*: seq[SavedLayout]  ## Window: the presets, and the user's under Load
    keepsLayouts*: bool         ## layouts can be saved by name (the program keeps its settings)
    followLatest*: bool         ## File > Follow the latest file is checked
    agentOn*: bool              ## File > Agent control is checked
    agentSocket*: string        ## where agents connect; "" while not known yet
    prepareNext*: bool          ## File > Prepare the next file is checked
    shown*: set[AppWindow]      ## the windows ticked under Window
    seismicName*: string        ## what the Seismic window is called now (`windowTitle`)
    joinShown*: bool            ## the "Import survey" window is open
    undo*, redo*: string
      ## Edit > Undo and Redo: the step each makes, in words ("trace 21
      ## killed"); "" when there is none
    edited*: bool               ## the file shown has edits (Edit > Clear all edits)
    editedName*: string         ## its name; "" when no file is shown
    memoryShown*: bool          ## the File memory window is open
    trayIcon*: bool             ## Window > Icon in the tray is checked
    trayMinimize*: bool         ## Window > Minimize to the tray is checked
    trayProblem*: string        ## why the tray icon cannot be shown; "" when it can
    trayAvailable*: bool        ## the icon is in a tray that is seen (minimizing to it can work)
    plotTraces*: int
      ## Window > New plot: the selected traces of the file shown; 0: none
      ## (its views are then offered on the trace under the pointer, from
      ## the plot's menu)
    recentProjects*: seq[string] ## File > Recent projects, newest first
    projectName*: string        ## the project open; "" for none
    projectShown*: bool         ## the Project window is open

  MenuResult* = object
    actions*: set[MenuAction]
    pickedTheme*: bool    ## a theme was chosen under View > Theme
    theme*: string        ## its file name, or "" for "Follow system"
    themeMenu*: ThemeMenu ## the submenu this frame: open, the entry the pointer rests on
    openRecent*: string   ## a recent file to open; "" for none
    browseRecent*: string ## a recent folder to list; "" for none
    clearRecent*: bool    ## "Clear the list" under File > Open recent
    loadLayout*: string   ## a layout file to load; "" for none
    toggleFollow*: bool   ## File > Follow the latest file was clicked
    toggleAgent*: bool    ## File > Agent control was clicked
    togglePrepare*: bool  ## File > Prepare the next file was clicked
    pickedWindows*: set[AppWindow]
      ## their entries under Window were clicked (`picked`)
    toggleJoin*: bool     ## the "Import survey" window's entry under Window was clicked
    toggleTrayIcon*: bool     ## Window > Icon in the tray was clicked
    toggleTrayMinimize*: bool ## Window > Minimize to the tray was clicked
    newPlot*: bool        ## Window > New plot > a view was clicked: `newPlotView`
    newPlotView*: AnalysisView
    openProject*: string  ## a recent project to open; "" for none

const
  shortcuts: array[MenuAction, ImGuiKeyChord] = [
    maOpenFile: ImGui_Mod_Ctrl.cint or ImGui_Key_O.cint,
    maOpenFiles: ImGui_Mod_Ctrl.cint or ImGui_Mod_Shift.cint or ImGui_Key_O.cint,
    maOpenFolder: ImGui_Mod_Ctrl.cint or ImGui_Mod_Alt.cint or ImGui_Key_O.cint,
    maClose: ImGui_Mod_Ctrl.cint or ImGui_Key_W.cint,
    maImportSurvey: 0, maImportSettings: 0, maImportLayout: 0, maImportEdits: 0,
    maExportLog: 0, maExportSettings: 0, maExportLayout: 0, maExportEdits: 0,
    maFileMemory: 0, maNewProject: 0, maOpenProject: 0, maProject: 0, maCloseProject: 0,
    maResetSettings: 0,
    maQuit: ImGui_Mod_Ctrl.cint or ImGui_Key_Q.cint,
    maUndo: ImGui_Mod_Ctrl.cint or ImGui_Key_Z.cint,
    maRedo: ImGui_Mod_Ctrl.cint or ImGui_Mod_Shift.cint or ImGui_Key_Z.cint,
    maClearEdits: 0,
    maToggleTheme: 0,
    maResetWindows: ImGui_Mod_Ctrl.cint or ImGui_Mod_Shift.cint or ImGui_Key_R.cint,
    maBringWindows: 0, maSaveLayout: 0,
    maShowFiles: 0, maShowRecords: 0, maShowMap: 0, maShowHeaders: 0, maShowJobs: 0,
    maShowMessages: 0]
    ## ImGui shows Ctrl as Cmd on macOS and matches it there; 0 = none.
  menuIcons: array[MenuAction, string] = [maOpenFile: IconOpenFile,
    maOpenFiles: IconOpenFiles, maOpenFolder: IconOpenFolder, maClose: IconClose,
    maImportSurvey: IconMap, maImportSettings: IconSettings, maImportLayout: IconLayers,
    maImportEdits: IconWriting, maExportLog: IconLog, maExportSettings: IconSettings,
    maExportLayout: IconLayers, maExportEdits: IconWriting, maFileMemory: IconHistory,
    maNewProject: IconFolder, maOpenProject: IconOpenFolder, maProject: IconFolder,
    maCloseProject: IconClose,
    maResetSettings: IconRefresh, maQuit: IconQuit, maUndo: IconUndo, maRedo: IconRedo,
    maClearEdits: IconClearAll, maToggleTheme: IconTheme,
    maResetWindows: IconRefresh, maBringWindows: IconFit, maSaveLayout: IconSave,
    maShowFiles: IconList, maShowRecords: IconRecords, maShowMap: IconMap,
    maShowHeaders: IconTable, maShowJobs: IconTasks, maShowMessages: IconLog]
  windowIcons: array[AppWindow, string] = [awSeismic: IconPlot, awFiles: IconList,
    awRecords: IconRecords, awMap: IconMap, awHeaders: IconTable, awJobs: IconTasks,
    awMessages: IconLog, awSpectrum: IconPulse]

const FollowHelp* = "On: each file that appears in the folder listed is shown in the " &
  "plot once it is completely written (its size has stopped changing and it is whole). " &
  "Off: the plot stays on the file you chose; new files are marked in Files."
  ## The tooltip of "Follow the latest", in the menu and in Files

proc shortcutName*(a: MenuAction): string =
  ## The shortcut of `a` as shown to the user ("Ctrl+O"), or "".
  if shortcuts[a] == 0: "" else: $igGetKeyChordName(shortcuts[a])

func shownAs(a: MenuAction): string =
  ## What `a` is called in its menu: in File > Import and File > Export,
  ## what is imported or exported.
  case a
  of maImportSurvey: "Survey..."
  of maImportSettings, maExportSettings: "Settings..."
  of maImportLayout, maExportLayout: "Layout..."
  of maExportLog: "Messages..."
  of maImportEdits, maExportEdits: "Trace edits..."
  else: $a

proc label(a: MenuAction): string =
  menuIcons[a] & "  " & shownAs(a)

var marked: ptr Marks ## the frame's marks while the menu is drawn (`drawMainMenu`)

proc item(a: MenuAction; res: var MenuResult) =
  if igMenuItem_Bool(label(a).cstring, shortcutName(a).cstring, false, true):
    res.actions.incl a
  if marked != nil: marked[].mark("menu." & $a)

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc drawRecent(recent, folders: openArray[string]; res: var MenuResult) =
  ## File > Open recent: the files, then the folders, newest first.
  if igBeginMenu((IconHistory & "  Open recent").cstring, true):
    if recent.len == 0 and folders.len == 0:
      igTextDisabled("Nothing opened yet")
    if recent.len > 0: igSeparatorText("Files")
    for i, path in recent:
      igPushID_Int(cint(i))
      if igMenuItem_Bool((IconOpenFile & "  " & path.extractFilename).cstring, nil, false, true):
        res.openRecent = path
      tip(path & "\nShown with its folder in the file list")
      igPopID()
    if folders.len > 0: igSeparatorText("Folders")
    for i, path in folders:
      igPushID_Int(cint(1000 + i))
      let name = if path.extractFilename.len > 0: path.extractFilename else: path
      if igMenuItem_Bool((IconFolder & "  " & name).cstring, nil, false, true):
        res.browseRecent = path
      tip(path & "\nIts seismic files in the file list")
      igPopID()
    if recent.len > 0 or folders.len > 0:
      igSeparator()
      if igMenuItem_Bool("Clear the list", nil, false, true):
        res.clearRecent = true
    igEndMenu()

proc drawProjects(input: MenuInput; res: var MenuResult) =
  ## File's project entries: New, Open, the recent ones, the Project window
  ## and Close.
  item(maNewProject, res)
  tip("A folder of its own for this job: its files' edits, its survey (imported once, " &
    "never again), its filters, presets and windows; copy the folder to hand it over")
  item(maOpenProject, res)
  tip("Open a project's folder (the folder that holds its project.nif)")
  let open = igBeginMenu((IconHistory & "  Recent projects").cstring, true)
  if marked != nil: marked[].mark("menu.Recent projects")
  if open:
    if input.recentProjects.len == 0: igTextDisabled("No project opened yet")
    for i, path in input.recentProjects:
      igPushID_Int(cint(2000 + i))
      let name = path.extractFilename
      if igMenuItem_Bool((IconFolder & "  " & (if name.len > 0: name else: path)).cstring, nil,
          false, true):
        res.openProject = path
      if marked != nil: marked[].mark("menu.project." & $i)
      tip(path)
      igPopID()
    igEndMenu()
  if igMenuItem_Bool(label(maProject).cstring, nil, input.projectShown, true):
    res.actions.incl maProject
  if marked != nil: marked[].mark("menu." & $maProject)
  tip(if input.projectName.len > 0: "The project " & input.projectName & ": its data " &
        "folders and its survey" else: "No project is open")
  igBeginDisabled(input.projectName.len == 0)
  item(maCloseProject, res)
  igEndDisabled()
  tip("Go back to working without a project: its files and survey are closed, your own " &
    "windows, presets and filters come back")

proc drawImports(res: var MenuResult) =
  ## File > Import: everything that is read in, each from here only.
  let open = igBeginMenu((IconOpenFile & "  Import").cstring, true)
  if marked != nil: marked[].mark("menu.Import")
  if open:
    item(maImportSurvey, res)
    tip("A survey's files (SPS, SEG P1, a CSV table of stations) matched to an open file's " &
      "traces, so they have their sources' and receivers' coordinates; in memory only, the " &
      "file is not changed")
    item(maImportSettings, res)
    tip("Take in the settings of a file exported before (here or on another computer); " &
      "those it does not hold stay as they are")
    item(maImportLayout, res)
    tip("Arrange the windows as a layout file says, and keep it among your layouts " &
      "(Window > Load)")
    item(maImportEdits, res)
    tip("Kill and reverse traces of the file shown as a list says (a CSV table with a " &
      "\"trace\" column, or a list exported here); one step, which Edit > Undo takes back")
    igEndMenu()

proc drawExports(res: var MenuResult) =
  ## File > Export: everything that is written out, each from here only.
  let open = igBeginMenu((IconExport & "  Export").cstring, true)
  if marked != nil: marked[].mark("menu.Export")
  if open:
    item(maExportLog, res)
    tip("Write every message of this session to a text file of your choice")
    item(maExportSettings, res)
    tip("Write every setting to a file of your choice, to keep or to take to another computer")
    item(maExportLayout, res)
    tip("Write the windows' arrangement to a file of your choice")
    item(maExportEdits, res)
    tip("Write the killed and reversed traces of the file shown to a file, to hand to " &
      "processing: a CSV table (trace, record, channel, edit) or viewSEG's own (.nif), " &
      "which Import reads again here or on another computer")
    igEndMenu()

proc drawLayouts(input: MenuInput; res: var MenuResult) =
  ## Window's layouts: the presets, the user's own under Load, then saving,
  ## exporting and importing one.
  igSeparatorText("Layouts")
  var mine = false
  for i, e in input.layouts:
    if e.preset:
      igPushID_Int(cint(i))
      if igMenuItem_Bool((IconLayers & "  " & e.name).cstring, nil, false, true):
        res.loadLayout = e.path
      if marked != nil: marked[].mark("menu.layout." & e.name)
      tip("Arrange the windows as this layout, which comes with viewSEG, does")
      igPopID()
    else: mine = true
  if igBeginMenu((IconFolder & "  Load").cstring, mine):
    for i, e in input.layouts:
      if not e.preset:
        igPushID_Int(cint(i))
        if igMenuItem_Bool(e.name.cstring, nil, false, true): res.loadLayout = e.path
        tip(e.path)
        igPopID()
    igEndMenu()
  tip(if mine: "Arrange the windows as a layout you saved does"
      else: "The layouts you save are listed here")
  igBeginDisabled(not input.keepsLayouts)
  item(maSaveLayout, res)
  tip("Keep the windows as they are now under a name, to load again (a layout file is " &
    "written and read under File > Export and File > Import)")
  igEndDisabled()

proc drawEditMenu(input: MenuInput; res: var MenuResult) =
  ## Edit: the trace edits of the file the Seismic window shows.
  let on = input.editedName.len > 0
  let undo = if input.undo.len > 0: "Undo " & input.undo else: "Undo"
  if igMenuItem_Bool((menuIcons[maUndo] & "  " & undo).cstring, shortcutName(maUndo).cstring,
      false, input.undo.len > 0):
    res.actions.incl maUndo
  if marked != nil: marked[].mark("menu." & $maUndo)
  tip(if input.undo.len > 0: "Take back the last change to the edits of " &
        input.editedName & ": " & input.undo
      elif on: "Nothing to undo in this session for " & input.editedName
      else: "No file is shown")
  let redo = if input.redo.len > 0: "Redo " & input.redo else: "Redo"
  if igMenuItem_Bool((menuIcons[maRedo] & "  " & redo).cstring,
      (shortcutName(maRedo) & ", Ctrl+Y").cstring, false, input.redo.len > 0):
    res.actions.incl maRedo
  if marked != nil: marked[].mark("menu." & $maRedo)
  tip(if input.redo.len > 0: "Make the change undone last again: " & input.redo
      else: "Nothing undone to make again")
  igSeparator()
  if igMenuItem_Bool(label(maClearEdits).cstring, nil, false, input.edited):
    res.actions.incl maClearEdits
  if marked != nil: marked[].mark("menu." & $maClearEdits)
  tip(if input.edited: "Take away every kill and polarity reversal of " & input.editedName &
        ", so its traces are shown as the file holds them (Undo brings them back). The " &
        "file itself is never changed"
      else: "No edits to clear")

proc drawNewPlot(input: MenuInput; res: var MenuResult) =
  ## Window > New plot: a window of the selected traces for each view.
  let open = igBeginMenu((IconPulse & "  New plot").cstring, input.plotTraces > 0)
  if marked != nil: marked[].mark("menu.window.newplot")
  tip(if input.plotTraces > 0: "A window of the " & $input.plotTraces & " selected traces: " &
        "a spectrogram, their envelope and instantaneous phase, the phase spectrum, a " &
        "cross-correlation against a pilot. It follows the Seismic window's filters and kills"
      else: "Select traces in the Seismic window first (or right-click one there)")
  if open:
    for v in AnalysisView:
      if igMenuItem_Bool(v.viewName.cstring, nil, false, true):
        (res.newPlot, res.newPlotView) = (true, v)
      if marked != nil: marked[].mark("menu.newplot." & $v)
    igEndMenu()

proc drawWindowMenu(input: MenuInput; res: var MenuResult) =
  ## Window: putting the windows right first, then each window with a tick,
  ## then the layouts.
  item(maResetWindows, res)
  tip("Every window shown and docked in the main window, as at a first start (the " &
    "default layout); the main window is brought onto a screen when it is off every one. " &
    "When the menus cannot be reached, start viewSEG with --reset-windows")
  item(maBringWindows, res)
  tip("The windows dragged out of the main window, wherever they are (on another screen, " &
    "on one that is gone, or past a screen's edge), and the main window itself, brought " &
    "wholly onto the screen the main window is on")
  if igMenuItem_Bool((IconTray & "  Icon in the tray").cstring, nil, input.trayIcon, true):
    res.toggleTrayIcon = true
  if marked != nil: marked[].mark("menu.tray.icon")
  tip(if input.trayProblem.len > 0 and input.trayIcon:
        "The tray icon cannot be shown here: " & input.trayProblem
      else: "viewSEG's icon in the system tray, with a menu: Show viewSEG, Open file..., Quit")
  if igMenuItem_Bool((IconMinimize & "  Minimize to the tray").cstring, nil,
      input.trayMinimize and input.trayAvailable, input.trayAvailable):
    res.toggleTrayMinimize = true
  if marked != nil: marked[].mark("menu.tray.minimize")
  tip(if input.trayAvailable: "On: minimizing the main window hides it, and its windows, " &
        "in the tray instead of the taskbar; the tray icon's Show viewSEG brings it back"
      elif input.trayIcon and input.trayProblem.len > 0: "Not here: " & input.trayProblem
      elif input.trayIcon: "Needs the icon in a tray that is seen"
      else: "Needs the icon in the tray")
  igSeparatorText("Windows")
  for w in AppWindow:
    let name = if w == awSeismic and input.seismicName.len > 0: input.seismicName
               else: WindowNames[w]
    if igMenuItem_Bool((windowIcons[w] & "  " & name).cstring, nil, w in input.shown, true):
      res.pickedWindows.incl w
    if marked != nil: marked[].mark("menu.window." & $w)
    tip(if w in AlwaysShown: "Always shown: a click brings it forward"
        else: "Ticked while shown. A click shows it in front when it is hidden or behind " &
          "another tab, and hides it when it is in sight")
  if igMenuItem_Bool((IconMap & "  Import survey").cstring, nil, input.joinShown, true):
    res.toggleJoin = true
  if marked != nil: marked[].mark("menu.window.join")
  tip("Ticked while open: a click opens it in front, or closes it")
  drawNewPlot(input, res)
  drawLayouts(input, res)

proc drawMainMenu*(input: MenuInput; marks: var Marks): MenuResult =
  ## The menu bar over the main window, plus the shortcuts, which work whether
  ## or not a menu is open. Its menus are marked "menu.File", "menu.Edit",
  ## "menu.View" and "menu.Window", its items "menu." and their names, the windows' entries
  ## "menu.window." and their IDs, the presets "menu.layout." and their names.
  result = MenuResult()
  marked = addr marks
  let typing = igGetIO_Nil().WantTextInput # a text field keeps its own Ctrl+Z
  for a in MenuAction:
    if shortcuts[a] != 0 and not (typing and a in {maUndo, maRedo}) and
        igShortcut_Nil(shortcuts[a], ImGui_InputFlags_RouteGlobal.cint):
      result.actions.incl a
  if not typing and igShortcut_Nil(ImGui_Mod_Ctrl.cint or ImGui_Key_Y.cint,
      ImGui_InputFlags_RouteGlobal.cint):
    result.actions.incl maRedo
  igPushStyleVar_Float(ImGui_StyleVar_WindowBorderSize.cint, 0) # one block with the toolbar
  let open = igBeginMainMenuBar()
  igPopStyleVar(1)
  if open:
    let file = igBeginMenu("File", true)
    marks.mark("menu.File")
    if file:
      for a in maOpenFile .. maOpenFolder:
        item(a, result)
      drawRecent(input.recent, input.recentFolders, result)
      igSeparator()
      drawProjects(input, result)
      igSeparator()
      igBeginDisabled(not input.canClose)
      item(maClose, result)
      igEndDisabled()
      tip("Close the file the plot window shows")
      if igMenuItem_Bool((IconFollow & "  Follow the latest file").cstring, nil,
          input.followLatest, true):
        result.toggleFollow = true
      tip(FollowHelp)
      if igMenuItem_Bool((IconStep & "  Prepare the next file").cstring, nil,
          input.prepareNext, true):
        result.togglePrepare = true
      tip("While a file is shown, open the next file of the list in the background " &
        "(its index and its first view), so that the next step does not wait for a slow " &
        "or network drive")
      igSeparator()
      drawImports(result)
      drawExports(result)
      if igMenuItem_Bool(label(maFileMemory).cstring, nil, input.memoryShown, true):
        result.actions.incl maFileMemory
      marks.mark("menu." & $maFileMemory)
      tip("What viewSEG remembers about the files you opened (their kills and polarity " &
        "reversals, kept beside them, never in them): see it, and remove what is no " &
        "longer wanted")
      item(maResetSettings, result)
      tip("Every setting back to its default (the recent files and the window's place " &
        "stay); the settings before are kept in a copy")
      igSeparator()
      if igMenuItem_Bool((IconAgent & "  Agent control").cstring, nil, input.agentOn, true):
        result.toggleAgent = true
      tip("On: an AI agent (an MCP client) can operate viewSEG while you watch, through " &
        (if input.agentSocket.len > 0: input.agentSocket else: "a socket next to the " &
        "program (viewSEG --paths says where)") & ". Every call it makes is written in " &
        "Messages; it cannot write files. For this run only.")
      igSeparator()
      item(maQuit, result)
      igEndMenu()
    let edit = igBeginMenu("Edit", true)
    marks.mark("menu.Edit")
    if edit:
      drawEditMenu(input, result)
      igEndMenu()
    let view = igBeginMenu("View", true)
    marks.mark("menu.View")
    if view:
      result.themeMenu = drawThemeMenu(input.themes, input.theme, input.follows,
        IconTheme & "  Theme", marks)
      (result.pickedTheme, result.theme) = (result.themeMenu.picked, result.themeMenu.theme)
      if igMenuItem_Bool(label(maToggleTheme).cstring, nil, false, true):
        result.actions.incl maToggleTheme
      igEndMenu()
    let window = igBeginMenu("Window", true)
    marks.mark("menu.Window")
    if window:
      drawWindowMenu(input, result)
      igEndMenu()
    igEndMainMenuBar()
  marked = nil
