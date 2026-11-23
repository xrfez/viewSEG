## The main menu bar and its keyboard shortcuts. Each item is reachable both
## ways, and its shortcut is shown in the menu and in the toolbar's tooltips.
## Drawing returns what the user asked for; the caller acts on it.
##
## The bar, left to right: File, Project, Edit, View, Analysis, Reports, Tools,
## Window, Help (Process, after Reports, is not here yet).
## File opens, opens again with other options, follows and closes files;
## Project holds the job's folder (New project, Open project, Recent projects,
## the Project window, the vendor map, Import survey and Clear survey, Close
## project); Edit undoes, redoes and clears the trace edits of the file the
## Seismic window shows, whichever window has the focus (Ctrl+Z, Ctrl+Shift+Z
## and Ctrl+Y everywhere but in a text field, which keeps its own undo), imports
## and exports them, and opens the File memory window (what is remembered about
## files: it is about files on disk); View shows, hides and brings forward each
## window and holds the theme; Analysis makes new plots, compares two traces and
## holds the references; Tools holds the settings (with their import and
## export), the vendor maps, the messages' export and Agent control; Window puts
## the windows right (Reset the windows, Bring all windows onto this screen),
## loads, saves, imports and exports layouts, and says whether the program's
## icon is in the tray and whether minimizing hides it there; Help lists the
## keyboard shortcuts (F1) and says what viewSEG is (About: its version and its
## libraries').

import std/os
import imguin/cimgui
import ../../core/[analysis, layouts]
import ../../core/shortcuts as shortcutTable
import ../../view/[missingwords, theme]
import clearsurvey, icons, marks, plotviews, thememenu, windows

type
  MenuAction* = enum
    ## What a menu item, a shortcut or a button asks for; its name is how it
    ## is marked ("menu." and the name), and what it is called outside a
    ## submenu (`shownAs` in one).
    maOpenFile = "Open file...", maOpenFiles = "Open files...",
    maOpenFolder = "Open folder...", maClose = "Close",
    maReopen = "Reopen with options...",
    maOpenVib = "Open the .vib of this sweep", maOpenDat = "Open the .dat of this sweep",
    maReloadVendors = "Reload vendor maps",
    maImportSurvey = "Import survey...", maClearSurvey = "Clear survey",
    maImportSettings = "Import settings...",
    maImportLayout = "Import layout...", maImportEdits = "Import trace edits...",
    maExportLog = "Export messages...", maExportSettings = "Export settings...",
    maExportLayout = "Export layout...", maExportEdits = "Export trace edits...",
    maFileMemory = "File memory...",
    maNewProject = "New project...", maOpenProject = "Open project...",
    maProject = "Project...", maCloseProject = "Close project",
    maSettings = "Settings...",
    maResetSettings = "Reset the settings",
    maQuit = "Quit",
    maUndo = "Undo", maRedo = "Redo", maSelectAll = "Select all traces",
        maClearEdits = "Clear all edits for this file",
    maToggleTheme = "Light / dark",
    maResetWindows = "Reset the windows",
    maBringWindows = "Bring all windows onto this screen",
    maSaveLayout = "Save layout as...",
    maShowFiles = "Files", maShowRecords = "Records", maShowMap = "Map",
    maShowHeaders = "Headers", maShowJobs = "Jobs", maShowMessages = "Messages",
    maShortcuts = "Keyboard shortcuts", maAbout = "About viewSEG",
    maGenerateReference = "Generate a reference...",
    maReferenceArchive = "Reference archive...",
    maCompare = "Compare two traces",
    maFirstBreaks = "First-break overlay",
    maTemplateOnly = "Only traces in the template",
    maMissingTraces = "Missing traces..."

  MenuInput* = object
    ## What the menus show besides their fixed items.
    themes*: seq[ThemeFile]      ## listed under View > Theme
    theme*: string               ## the one checked; "" for following the system
    follows*: string             ## the theme file "Follow system" uses now
    recent*: seq[string]         ## File > Open recent, newest first
    recentFolders*: seq[string]  ## the folders there, newest first
    canClose*: bool              ## a file is shown, so File > Close closes it
    signature*: string           ## the shown file is a vibrator signature file: "dat" or "vib"
    pairName*: string            ## its other file's name when known; "" when not
    layouts*: seq[SavedLayout]   ## Window: the presets, and the user's under Layouts > Load
    keepsLayouts*: bool          ## layouts can be saved by name (the program keeps its settings)
    followLatest*: bool          ## File > Follow the latest file is checked
    agentOn*: bool               ## Tools > Agent control is checked
    agentSocket*: string         ## where agents connect; "" while not known yet
    prepareNext*: bool           ## File > Prepare the next file is checked
    shown*: set[AppWindow]       ## the windows ticked under View
    seismicName*: string         ## what the Seismic window is called now (`windowTitle`)
    joinShown*: bool             ## the "Import survey" window is open
    surveyImported*: bool        ## a survey is in effect (Project > Clear survey)
    undo*, redo*: string
      ## Edit > Undo and Redo: the step each makes, in words ("trace 21
      ## killed"); "" when there is none
    edited*: bool ## the file shown has edits (Edit > Clear all edits)
    editedName*: string ## its name; "" when no file is shown
    memoryShown*: bool ## the File memory window is open
    trayIcon*: bool ## Window > Icon in the tray is checked
    trayMinimize*: bool ## Window > Minimize to the tray is checked
    trayProblem*: string ## why the tray icon cannot be shown; "" when it can
    trayAvailable*: bool ## the icon is in a tray that is seen (minimizing to it can work)
    canPlot*: bool
      ## the Seismic window shows a file: the plots (FFT, New plot) can be opened, with
      ## or without a trace selected
    plotTraces*: int
      ## Analysis > New plot: the selected traces of the file shown; 0: none
      ## (its views are then offered on the trace under the pointer, from
      ## the plot's menu)
    recentProjects*: seq[string] ## Project > Recent projects, newest first
    projectName*: string ## the project open; "" for none
    projectShown*: bool ## the Project window is open
    vendorMaps*: seq[string] ## Project > Vendor map: the maps loaded, by name
    vendorChoice*: string ## the project's rule: "automatic", "none" or a map's name
    archiveShown*: bool ## the Reference archive window is open
    compareShown*: bool ## the compare window is open
    firstBreaksOn*: bool ## the Seismic window's first-break overlay is on
    templateOnlyOn*: bool ## the Seismic window shows only the traces its record's template lists
    templateAvailable*: bool ## a relation file is there for that (the item is enabled)
    missingReady*: bool ## Reports > Missing traces can run
    missingWhy*: string ## why it cannot; "" when it can

  MenuResult* = object
    actions*: set[MenuAction]
    pickedTheme*: bool        ## a theme was chosen under View > Theme
    theme*: string            ## its file name, or "" for "Follow system"
    themeMenu*: ThemeMenu     ## the submenu this frame: open, the entry the pointer rests on
    openRecent*: string       ## a recent file to open; "" for none
    browseRecent*: string     ## a recent folder to list; "" for none
    clearRecent*: bool        ## "Clear the list" under File > Open recent
    loadLayout*: string       ## a layout file to load; "" for none
    toggleFollow*: bool       ## File > Follow the latest file was clicked
    toggleAgent*: bool        ## Tools > Agent control was clicked
    togglePrepare*: bool      ## File > Prepare the next file was clicked
    pickedWindows*: set[AppWindow]
      ## their entries under Window were clicked (`picked`)
    toggleJoin*: bool         ## the "Import survey" window's entry under Window was clicked
    toggleTrayIcon*: bool     ## Window > Icon in the tray was clicked
    toggleTrayMinimize*: bool ## Window > Minimize to the tray was clicked
    newPlot*: bool            ## Analysis > New plot > a view was clicked: `newPlotView`
    newPlotView*: AnalysisView
    openProject*: string      ## a recent project to open; "" for none
    vendorMap*: string        ## Project > Vendor map: the rule chosen ("automatic", "none" or a name); "" for none

const
  shortcuts: array[MenuAction, ImGuiKeyChord] = [
    maOpenFile: ImGui_Mod_Ctrl.cint or ImGui_Key_O.cint,
    maOpenFiles: ImGui_Mod_Ctrl.cint or ImGui_Mod_Shift.cint or ImGui_Key_O.cint,
    maOpenFolder: ImGui_Mod_Ctrl.cint or ImGui_Mod_Alt.cint or ImGui_Key_O.cint,
    maClose: ImGui_Mod_Ctrl.cint or ImGui_Key_W.cint,
    maReopen: 0, maOpenVib: 0, maOpenDat: 0, maReloadVendors: 0,
    maImportSurvey: 0, maClearSurvey: 0, maImportSettings: 0, maImportLayout: 0,
    maImportEdits: 0,
    maExportLog: 0, maExportSettings: 0, maExportLayout: 0, maExportEdits: 0,
    maFileMemory: 0, maNewProject: 0, maOpenProject: 0, maProject: 0, maCloseProject: 0,
    maSettings: 0, maResetSettings: 0,
    maQuit: ImGui_Mod_Ctrl.cint or ImGui_Key_Q.cint,
    maUndo: ImGui_Mod_Ctrl.cint or ImGui_Key_Z.cint,
    maRedo: ImGui_Mod_Ctrl.cint or ImGui_Mod_Shift.cint or ImGui_Key_Z.cint,
    maSelectAll: ImGui_Mod_Ctrl.cint or ImGui_Key_A.cint,
    maClearEdits: 0,
    maToggleTheme: 0,
    maResetWindows: ImGui_Mod_Ctrl.cint or ImGui_Mod_Shift.cint or ImGui_Key_R.cint,
    maBringWindows: 0, maSaveLayout: 0,
    maShowFiles: 0, maShowRecords: 0, maShowMap: 0, maShowHeaders: 0, maShowJobs: 0,
    maShowMessages: 0,
    maShortcuts: ImGui_Key_F1.cint, maAbout: 0, maGenerateReference: 0,
    maReferenceArchive: 0, maCompare: 0, maFirstBreaks: 0, maTemplateOnly: 0,
    maMissingTraces: 0]
    ## ImGui shows Ctrl as Cmd on macOS and matches it there; 0 = none.
  menuIcons: array[MenuAction, string] = [maOpenFile: IconOpenFile,
    maOpenFiles: IconOpenFiles, maOpenFolder: IconOpenFolder, maClose: IconClose,
    maReopen: IconRefresh, maOpenVib: IconStep, maOpenDat: IconStep,
    maReloadVendors: IconRefresh,
    maImportSurvey: IconSurvey, maClearSurvey: IconTrash, maImportSettings: IconSliders,
    maImportLayout: IconLayout,
    maImportEdits: IconWriting, maExportLog: IconExport, maExportSettings: IconSliders,
    maExportLayout: IconLayout, maExportEdits: IconWriting, maFileMemory: IconMemory,
    maNewProject: IconProject, maOpenProject: IconProject, maProject: IconProject,
    maCloseProject: IconClose, maSettings: IconSettings,
    maResetSettings: IconReset, maQuit: IconQuit, maUndo: IconUndo, maRedo: IconRedo,
    maSelectAll: IconList,
    maClearEdits: IconClearAll, maToggleTheme: IconTheme,
    maResetWindows: IconHome, maBringWindows: IconFit, maSaveLayout: IconSave,
    maShowFiles: IconList, maShowRecords: IconRecords, maShowMap: IconMap,
    maShowHeaders: IconTable, maShowJobs: IconTasks, maShowMessages: IconLog,
    maShortcuts: IconList, maAbout: IconInfo, maGenerateReference: IconVibrator,
    maReferenceArchive: IconReference, maCompare: IconPulse, maFirstBreaks: IconTarget,
    maTemplateOnly: IconTable, maMissingTraces: IconTable]
  windowIcons: array[AppWindow, string] = [awSeismic: IconPlot, awFiles: IconList,
    awRecords: IconRecords, awMap: IconMap, awHeaders: IconTable, awJobs: IconTasks,
    awMessages: IconLog, awSpectrum: IconPulse, awAux: IconPlot, awMissing: IconTable]

const
  FollowWords* = "Follow the latest file"
    ## The action's words, in the menu and on the Files button
  FollowHelp* = "On: each file that appears in the folder listed is shown in the " &
    "plot once it is completely written (its size has stopped changing and it is whole). " &
    "Off: the plot stays on the file you chose; new files are marked in Files."
    ## The tooltip of Follow the latest file, in the menu and in Files
  ReopenTip* = "Open the file the plot window shows again, with other options: its " &
    "standard when it is read as the wrong one, every trace header checked, " &
    "two's-complement mantissas, mapped or not. Its kills and polarity reversals stay"
    ## File > Reopen with options... and the Headers Summary button

func menuIcon*(a: MenuAction): string =
  ## The glyph `a` is drawn with, in its menu and wherever that action is.
  menuIcons[a]

proc shortcutName*(a: MenuAction): string =
  ## The shortcut of `a` as shown to the user ("Ctrl+O"), or "".
  if shortcuts[a] == 0: "" else: $igGetKeyChordName(shortcuts[a])

proc redoShortcut*(): string =
  ## Both of Redo's bindings, named as the others are (Ctrl is Cmd on macOS).
  shortcutName(maRedo) & ", " &
    $igGetKeyChordName(ImGui_Mod_Ctrl.cint or ImGui_Key_Y.cint)

proc namedRows*(): seq[shortcutTable.ShortcutRow] =
  ## The shortcut list, menu rows named as this platform names them
  ## (`shortcutName`; Redo keeps both bindings).
  result = shortcutTable.shortcutRows()
  for r in result.mitems:
    if r.menu.len == 0: continue
    for a in MenuAction:
      if $a == r.menu:
        if a == maRedo: r.keys = redoShortcut()
        elif shortcuts[a] != 0: r.keys = shortcutName(a)

func menuLabel*(a: MenuAction): string =
  ## What `a` is called, the same words in its menu, its button and its tooltip.
  ## Import survey opens a window, so it has no ellipsis; the others that open
  ## a dialog keep the one their name has.
  if a == maImportSurvey: "Import survey" else: $a

func shownAs(a: MenuAction): string = menuLabel(a)

proc label(a: MenuAction): string =
  menuIcons[a] & "  " & shownAs(a)

var marked: ptr Marks ## the frame's marks while the menu is drawn (`drawMainMenu`)

proc item(a: MenuAction; res: var MenuResult) =
  if igMenuItem_Bool(label(a).cstring, shortcutName(a).cstring, false, true):
    res.actions.incl a
  if marked != nil: marked[].mark("menu." & $a)

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc drawRecent(recent, folders: openArray[string]; res: var MenuResult) =
  ## File > Open recent: the files, then the folders, newest first.
  let open = igBeginMenu((IconHistory & "  Open recent").cstring, true)
  if marked != nil: marked[].mark("menu.Open recent")
  if open:
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

proc drawRecentProjects*(projects: openArray[string]; chosen: var string;
    marks: ptr Marks; prefix: string; idBase = 0) =
  ## The recent-projects list: each row the project's icon and its folder's
  ## name, or "No project opened yet". `prefix` marks the rows (`prefix` &
  ## the index, `prefix` & "none" when there is none).
  if projects.len == 0:
    igTextDisabled("No project opened yet")
    if marks != nil: marks[].mark(prefix & "none")
  for i, path in projects:
    igPushID_Int(cint(idBase + i))
    let name = path.extractFilename
    if igMenuItem_Bool((IconProject & "  " & (if name.len > 0: name else: path)).cstring, nil,
        false, true):
      chosen = path
    if marks != nil: marks[].mark(prefix & $i)
    tip(path)
    igPopID()

proc drawProjects(input: MenuInput; res: var MenuResult) =
  ## Project's entries: New, Open, the recent ones; the Project window and the
  ## vendor map; the survey (which works without a project); Close.
  item(maNewProject, res)
  tip("A folder of its own for this job: its files' edits, its survey (imported once, " &
    "never again), its filters, presets and windows; copy the folder to hand it over")
  item(maOpenProject, res)
  tip("Open a project's folder (the folder that holds its project.nif)")
  let open = igBeginMenu((IconHistory & "  Recent projects").cstring, true)
  if marked != nil: marked[].mark("menu.Recent projects")
  if open:
    drawRecentProjects(input.recentProjects, res.openProject, marked, "menu.project.", 2000)
    igEndMenu()
  igSeparator()
  if igMenuItem_Bool(label(maProject).cstring, nil, input.projectShown, true):
    res.actions.incl maProject
  if marked != nil: marked[].mark("menu." & $maProject)
  tip(if input.projectName.len > 0: "The project " & input.projectName & ": its data " &
        "folders and its survey" else: "No project is open")
  igBeginDisabled(input.projectName.len == 0)
  if igBeginMenu("Vendor map", true):
    if marked != nil: marked[].mark("menu.project.vendor")
    var rules = @[("Automatic", "automatic")]
    for name in input.vendorMaps: rules.add (name, name)
    rules.add ("None", "none")
    for (words, name) in rules:
      if igMenuItem_Bool(words.cstring, nil, input.vendorChoice == name, true):
        res.vendorMap = name
      if marked != nil: marked[].mark("menu.project.vendor " & name)
    igEndMenu()
  igEndDisabled()
  tip(if input.projectName.len > 0: "Which vendor header map decodes this project's files: " &
        "Automatic (every map loaded is offered; the most specific one that matches a file " &
        "decodes it), one map by name (only that one, and only for the files it matches), or " &
        "None" else: "A vendor map is chosen for a project: outside one, every map loaded is " &
        "offered (Automatic)")
  igSeparator()
  item(maImportSurvey, res)
  tip("A survey's files (SPS, SEG P1, a CSV table of stations) matched to an open file's " &
    "traces, so they have their sources' and receivers' coordinates; in memory only, the " &
    "file is not changed")
  igBeginDisabled(not input.surveyImported)
  item(maClearSurvey, res)
  igEndDisabled()
  tip(if input.surveyImported: ClearSurveyHelp else: NoSurveyHelp)
  igSeparator()
  igBeginDisabled(input.projectName.len == 0)
  item(maCloseProject, res)
  igEndDisabled()
  tip("Go back to working without a project: its files and survey are closed, your own " &
    "windows, presets and filters come back")

proc drawProjectItems*(input: MenuInput; marks: var Marks): MenuResult =
  ## The Project menu's items, for that menu and for the toolbar's project
  ## button. The caller has a menu or a popup open.
  let saved = marked
  marked = addr marks
  drawProjects(input, result)
  marked = saved

proc drawLayouts(input: MenuInput; res: var MenuResult) =
  ## Window's layouts: the presets, the user's own under Load, then saving,
  ## exporting and importing one.
  igSeparatorText("Layouts")
  var mine = false
  for i, e in input.layouts:
    if e.preset:
      igPushID_Int(cint(i))
      if igMenuItem_Bool((IconLayout & "  " & e.name).cstring, nil, false, true):
        res.loadLayout = e.path
      if marked != nil: marked[].mark("menu.layout." & e.name)
      tip("Arrange the windows as this layout, which comes with viewSEG, does")
      igPopID()
    else: mine = true
  let load = igBeginMenu((IconLayout & "  Load").cstring, mine)
  if marked != nil: marked[].mark("menu.Load")
  if load:
    for i, e in input.layouts:
      if not e.preset:
        igPushID_Int(cint(i))
        if igMenuItem_Bool(e.name.cstring, nil, false, true): res.loadLayout = e.path
        tip("Arrange the windows as this layout does.\n" & e.path)
        igPopID()
    igEndMenu()
  tip(if mine: "Arrange the windows as a layout you saved does"
      else: "The layouts you save are listed here")
  igBeginDisabled(not input.keepsLayouts)
  item(maSaveLayout, res)
  tip("Keep the windows as they are now under a name, to load again")
  igEndDisabled()
  item(maImportLayout, res)
  tip("Arrange the windows as a layout file says, and keep it among your layouts " &
    "(Window > Load)")
  item(maExportLayout, res)
  tip("Write the windows' arrangement to a file of your choice")

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
      redoShortcut().cstring, false, input.redo.len > 0):
    res.actions.incl maRedo
  if marked != nil: marked[].mark("menu." & $maRedo)
  tip(if input.redo.len > 0: "Make the change undone last again: " & input.redo
      else: "Nothing undone to make again")
  igSeparator()
  if igMenuItem_Bool((menuIcons[maSelectAll] & "  " & $maSelectAll).cstring,
      shortcutName(maSelectAll).cstring, false, input.canClose):
    res.actions.incl maSelectAll
  if marked != nil: marked[].mark("menu." & $maSelectAll)
  tip("Select every trace the Seismic window shows (as its Seismic / Aux switches and the " &
    "hidden killed traces leave them)")
  igSeparator()
  item(maImportEdits, res)
  tip("Kill and reverse traces of the file shown as a list says (a CSV table with a " &
    "\"trace\" column, or a list exported here); one step, which Edit > Undo takes back")
  item(maExportEdits, res)
  tip("Write the killed and reversed traces of the file shown to a file, to hand to " &
    "processing: a CSV table (trace, record, channel, edit) or viewSEG's own (.nif), " &
    "which Import trace edits reads again here or on another computer")
  if igMenuItem_Bool(label(maClearEdits).cstring, nil, false, input.edited):
    res.actions.incl maClearEdits
  if marked != nil: marked[].mark("menu." & $maClearEdits)
  tip(if input.edited: "Take away every kill, polarity reversal and trace filter of " & input.editedName &
        ", so its traces are shown as the file holds them (Undo brings them back). The " &
        "file itself is never changed"
      else: "No edits to clear")
  igSeparator()
  if igMenuItem_Bool(label(maFileMemory).cstring, nil, input.memoryShown, true):
    res.actions.incl maFileMemory
  if marked != nil: marked[].mark("menu." & $maFileMemory)
  tip("What viewSEG remembers about the files you opened (their kills and polarity " &
    "reversals, kept beside them, never in them): see it, and remove what is no " &
    "longer wanted")

proc drawNewPlot(input: MenuInput; res: var MenuResult) =
  ## Analysis > New plot: a window of the selected traces for each view.
  let open = igBeginMenu((IconPulse & "  New plot").cstring, input.canPlot)
  if marked != nil: marked[].mark("menu.window.newplot")
  tip(if input.plotTraces > 0: "A window of the " & $input.plotTraces & " selected traces: " &
        "a spectrogram, their envelope and instantaneous phase, the phase spectrum, a " &
        "cross-correlation against a pilot. It follows the Seismic window unless frozen"
      elif input.canPlot: "A window of the selected traces: it opens now and shows them " &
        "once you click a trace in the Seismic window"
      else: OpenFileFirst)
  if open:
    for e in PlotEntries:
      if not e.fft:
        if igMenuItem_Bool((e.icon & "  " & e.name).cstring, nil, false, true):
          (res.newPlot, res.newPlotView) = (true, e.view)
        tip(e.sentence)
        if marked != nil: marked[].mark("menu.newplot." & $e.view)
    igEndMenu()

proc drawWindowTicks(input: MenuInput; res: var MenuResult) =
  ## View's window ticks: each window, then the "Import survey" window.
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
  if igMenuItem_Bool((IconSurvey & "  Import survey").cstring, nil, input.joinShown, true):
    res.toggleJoin = true
  if marked != nil: marked[].mark("menu.window.join")
  tip("Ticked while open: a click opens it in front, or closes it")

proc drawWindowMenu(input: MenuInput; res: var MenuResult) =
  ## Window: putting the windows right, the layouts, then the tray.
  item(maResetWindows, res)
  tip("The windows as at a first start, docked in the main window (one closed until " &
    "asked stays closed). The main window is brought onto a screen when it is off every " &
    "one. When the menus cannot be reached, start viewSEG with --reset-windows")
  item(maBringWindows, res)
  tip("The windows dragged out of the main window, wherever they are (on another screen, " &
    "on one that is gone, or past a screen's edge), and the main window itself, brought " &
    "wholly onto the screen the main window is on")
  drawLayouts(input, res)
  igSeparator()
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

proc drawToolsMenu(input: MenuInput; res: var MenuResult) =
  ## Tools: the settings, the vendor maps, the messages, the agent.
  item(maSettings, res)
  tip("Units: metric or imperial, for a plot's masses, forces and velocities")
  item(maImportSettings, res)
  tip("Take in the settings of a file exported before (here or on another computer); " &
    "those it does not hold stay as they are")
  item(maExportSettings, res)
  tip("Write every setting to a file of your choice, to keep or to take to another computer")
  item(maResetSettings, res)
  tip("Every setting back to its default (the recent files and the window's place " &
    "stay); the settings before are kept in a copy")
  igSeparator()
  item(maReloadVendors, res)
  tip("Read the vendor header maps (*.nif) again from their folders: the project's, your " &
    "settings folder, beside the program: a map dropped in while viewSEG runs is used " &
    "without a restart, and the files open show the new decode (Messages says what was " &
    "loaded)")
  igSeparator()
  item(maExportLog, res)
  tip("Write every message of this session to a text file of your choice")
  igSeparator()
  if igMenuItem_Bool((IconAgent & "  Agent control").cstring, nil, input.agentOn, true):
    res.toggleAgent = true
  if marked != nil: marked[].mark("menu.Agent control")
  tip("On: an AI agent (an MCP client) can operate viewSEG while you watch, through " &
    (if input.agentSocket.len > 0: input.agentSocket else: "a socket next to the " &
    "program (viewSEG --paths says where)") & ". Every call it makes is written in " &
    "Messages; it cannot write files. For this run only.")

proc drawReportsMenu(input: MenuInput; res: var MenuResult) =
  ## Reports: the missing-trace scan. The item stays inactive until a folder
  ## is open and a relation file is loaded.
  igBeginDisabled(not input.missingReady)
  item(maMissingTraces, res)
  igEndDisabled()
  tip(if input.missingReady: MenuTip else: input.missingWhy)
  if not input.missingReady and marked != nil:
    marked[].mark("menu.Missing traces.disabled")

proc drawAnalysisMenu(input: MenuInput; res: var MenuResult) =
  ## Analysis: new plots, the comparison, the references.
  drawNewPlot(input, res)
  if igMenuItem_Bool(label(maCompare).cstring, nil, input.compareShown, true):
    res.actions.incl maCompare
  marked[].mark("menu." & $maCompare)
  tip("Overlay two traces, from one file or from two, for QC")
  if igMenuItem_Bool(label(maFirstBreaks).cstring, nil, input.firstBreaksOn, true):
    res.actions.incl maFirstBreaks
  marked[].mark("menu." & $maFirstBreaks)
  tip("Draw, over each trace of the Seismic window, a bar where a refraction model fitted to " &
    "the picks expects the first break and another where it was picked. The model needs " &
    "source-receiver offsets: a survey, or coordinates in the file. Also a button on the " &
    "window's strip.")
  igSeparatorText("References")
  item(maGenerateReference, res)
  tip("Make a sweep and keep it as a reference")
  if igMenuItem_Bool(label(maReferenceArchive).cstring, nil, input.archiveShown, true):
    res.actions.incl maReferenceArchive
  marked[].mark("menu." & $maReferenceArchive)
  tip("The stored references, and which one the plots use")

proc drawMainMenu*(input: MenuInput; marks: var Marks): MenuResult =
  ## The menu bar over the main window, plus the shortcuts, which work whether
  ## or not a menu is open. Its menus are marked "menu.File", "menu.Project",
  ## "menu.Edit", "menu.View", "menu.Analysis", "menu.Reports", "menu.Tools",
  ## "menu.Window" and
  ## "menu.Help", its items "menu." and their
  ## names, the windows' entries "menu.window." and their IDs, the presets
  ## "menu.layout." and their names.
  result = MenuResult()
  marked = addr marks
  let typing = igGetIO_Nil().WantTextInput # a text field keeps its own Ctrl+Z
  for a in MenuAction:
    if shortcuts[a] != 0 and not (typing and a in {maUndo, maRedo, maSelectAll}) and
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
      igBeginDisabled(not input.canClose)
      item(maClose, result)
      igEndDisabled()
      tip("Close the file the plot window shows")
      igBeginDisabled(not input.canClose)
      item(maReopen, result)
      igEndDisabled()
      tip(ReopenTip)
      if input.signature.len > 0:
        let action = if input.signature == "dat": maOpenVib else: maOpenDat
        let label = $action & (if input.pairName.len > 0: " (" & input.pairName & ")" else: "")
        if igMenuItem_Bool((menuIcons[action] & "  " & label).cstring, nil, false, true):
          result.actions.incl action
        marks.mark("menu." & $action)
        tip("Show the other file of this sweep in the Seismic window: the .dat's .vib, the " &
          ".vib's .dat. It is looked for when the list does not know it.")
      igSeparator()
      if igMenuItem_Bool((IconFollow & "  " & FollowWords).cstring, nil,
          input.followLatest, true):
        result.toggleFollow = true
      marks.mark("menu." & FollowWords)
      tip(FollowHelp)
      if igMenuItem_Bool((IconStep & "  Prepare the next file").cstring, nil,
          input.prepareNext, true):
        result.togglePrepare = true
      marks.mark("menu.Prepare the next file")
      tip("While a file is shown, open the next file of the list in the background " &
        "(its index and its first view), so that the next step does not wait for a slow " &
        "or network drive")
      # Future: "Save as SEG-Y / SEG-D..." and a "Tape" submenu go here, before Quit.
      igSeparator()
      item(maQuit, result)
      igEndMenu()
    let project = igBeginMenu("Project", true)
    marks.mark("menu.Project")
    if project:
      drawProjects(input, result)
      igEndMenu()
    let edit = igBeginMenu("Edit", true)
    marks.mark("menu.Edit")
    if edit:
      drawEditMenu(input, result)
      igEndMenu()
    let view = igBeginMenu("View", true)
    marks.mark("menu.View")
    if view:
      drawWindowTicks(input, result)
      igSeparator()
      igBeginDisabled(not input.templateAvailable)
      if igMenuItem_Bool(label(maTemplateOnly).cstring, nil, input.templateOnlyOn, true):
        result.actions.incl maTemplateOnly
      igEndDisabled()
      marks.mark("menu." & $maTemplateOnly)
      tip(if input.templateAvailable:
        "The Seismic window shows only the seismic traces the shot's template lists " &
          "(the relation file): the others are left out of the plot, the traces beside " &
          "them close up. Also a button on the window's strip."
      else: "Needs a relation file in the project: it says which traces each shot's " &
        "template holds.")
      igSeparator()
      result.themeMenu = drawThemeMenu(input.themes, input.theme, input.follows,
        IconTheme & "  Theme", marks)
      (result.pickedTheme, result.theme) = (result.themeMenu.picked, result.themeMenu.theme)
      item(maToggleTheme, result)
      tip("Switch to the other mode's default theme")
      igEndMenu()
    let analysis = igBeginMenu("Analysis", true)
    marks.mark("menu.Analysis")
    if analysis:
      drawAnalysisMenu(input, result)
      igEndMenu()
    let reports = igBeginMenu("Reports", true)
    marks.mark("menu.Reports")
    if reports:
      drawReportsMenu(input, result)
      igEndMenu()
    let tools = igBeginMenu("Tools", true)
    marks.mark("menu.Tools")
    if tools:
      drawToolsMenu(input, result)
      igEndMenu()
    let window = igBeginMenu("Window", true)
    marks.mark("menu.Window")
    if window:
      drawWindowMenu(input, result)
      igEndMenu()
    let help = igBeginMenu("Help", true)
    marks.mark("menu.Help")
    if help:
      item(maShortcuts, result)
      tip("Every key and mouse gesture, and what it does (F1)")
      item(maAbout, result)
      tip("viewSEG's version, and those of the libraries it is built on")
      igEndMenu()
    igEndMainMenuBar()
  marked = nil
