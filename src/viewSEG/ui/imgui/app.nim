## The Dear ImGui frontend: imguin (Dear ImGui with docking and multi-viewports,
## plus ImPlot) on SDL3 and OpenGL 3. Only `ui/imgui/` may import imguin, ImPlot
## or SDL (docs/architecture.md).
##
## The window holds a menu bar, an icon toolbar, a dockspace with the file
## list (`filelist`), the record list (`recordlist`), the trace panel
## (`tracepanel`), the map (`mapwindow`), the Headers window (`headerswindow`), the Jobs
## window (`jobswindow`), the Messages window, the Missing traces window
## (`missingwindow`), the Trace quality window (`qualitywindow`) and the Vibrator
## QC window (`vibfolderwindow`), and a status bar with the
## running job's progress and its Cancel button, and the readout of what
## lies under the mouse in the plot (or its coordinates on the map); files
## and folders dropped on the window are opened;
## `-d:imguiDemo` adds the Dear ImGui demo window. The look comes from a theme file
## (`view/theme`, `style`, `fonts`); the shell services (dialogs, system theme,
## icon, tray) are in `shell`, DPI handling in `dpi`, the chrome in `chrome`,
## the frames the OS draws around the windows in `frames`.
##
## With `RunOptions.tray` the program's icon is in the system tray while the
## settings say so (`Settings.tray.icon`, Window > Icon in the tray), with a
## menu: Show viewSEG, Open file..., Quit. With `Settings.tray.minimize` too,
## minimizing the main window hides it (and the windows dragged out of it,
## its SDL children) in the tray; Show viewSEG brings it back as it was.
##
## The application state (`core/state`) lives here, on the UI thread: each
## frame drains its inbox, and the Messages window shows its log, where the
## frontend's own messages go too; with `RunOptions.persist` the log is also
## written to this run's session log file (`core/state.logTo`). File > Open file and the files named on the
## command line (`RunOptions.openPaths`) are opened by `core`'s open job, with
## parseSEG's index cache in `RunOptions.indexCacheDir`. Debug builds time
## every frame (`core/watchdog`) and log the frames whose work is over budget,
## with what the frame was doing, at most once a second.
##
## A start-up step that fails (SDL, the window, OpenGL 3.3, either ImGui
## backend) is reported in a message box, on stderr and in
## `<logs>/startup-failure.log`, and `run` returns 1. In release builds a failed
## Dear ImGui check is logged instead of aborting (`asserts`).

import std/[atomics, math, options, os, sequtils, strutils, terminal, times]
import asserts # before imguin: Nim keys its cache of imguin's C++ objects on the
               # C flags in force when imguin is compiled, and this adds one
import sdl3_nim
import imguin/[cimgui, impl_sdl3, impl_opengl]
import imguin/glad/gl
import ../../core/[filesystem, geometry, screens, state, watchdog]
from ../../core/editmarks import shiftWords
import ../../platform/[paths, trayguard, trayhost]
import ../../remote/control
import curveplot as curveplotui
import ../../view/[jobstatus, missingwords, outputwords, qualitywords, vibfolderwords]
import aboutbox, agentshot, chrome, clearsurvey, dpi, filelist, fonts, frames, genpreview,
  headerswindow, icons, settingswindow, shortcutswindow,
  jobswindow, joindialog, mapwindow, memorywindow, menus, messages, missingwindow, outputwindow,
  qualitywindow, vibfolderwindow,
  plotwindows,
  projectwindow,
  placement, references,
  recordlist, reopendialog, shell, shotlogwindow, spectrumwindow, style, tracepanel, windows,
  comparewindow

export ThemeChoice, theme, messages, ImguiCheck, tracepanel, mapwindow, AppWindow, DialogKind,
  SpectraUi, readoutOf

const
  glslVersion = "#version 330"
  defaultSize = (1280, 800)               ## the first window size at 100 %
  plotId = "plot"                         ## the main plot window's ImGui ID: "###plot"
  mapId = "map"                           ## the map window's ImGui ID: "###map"
  headersTitle = IconTable & "  Headers###headers"
  messagesTitle = IconLog & "  Messages###Messages"
  filesTitle = IconList & "  Files###files"
  jobsTitle = IconTasks & "  Jobs###jobs"
  recordsTitle = IconRecords & "  Records###records"
  missingTitle = IconTable & "  Missing traces###missing"
  qualityTitle = IconTable & "  Trace quality###quality"
  vibfolderTitle = IconTable & "  Vibrator QC###vibfolder"
  outputTitle = IconLog & "  Output###output"
  joinTitle = IconSurvey & "  Import survey###join"
  shotLogTitle = IconTable & "  Shot log###shotlog"
  memoryTitle = IconMemory & "  File memory###memory"
  projectTitle = IconProject & "  Project###project"
  newProjectTitle = IconProject & "  New project###newproject"
  noticeSeconds = 5.0                     ## how long a notice stays on screen
  CheckFrames = 8                         ## frames after a layout's arrival to look for windows off screen
  failureLogName* = "startup-failure.log" ## in the log folder; the last failure only

var stopAsked: Atomic[bool] ## Ctrl+C was pressed in the console (`RunOptions.tray`)

type
  QueuedInput = object
    ## A test event waiting for a frame. `owned` is an index into `Ui.typed`
    ## when the event's text points there; -1 otherwise. The pointer is filled
    ## in at delivery, so a later `typed.add` cannot dangle it.
    ev: SDL_Event
    owned: int
  Ui = object
    ## The frontend's own state between frames.
    window: ptr SDL_Window
    choice: ThemeChoice
    system: SystemTheme
    themes: seq[ThemeFile]                     ## the theme files found, user's first
    selected: string                           ## the chosen theme file's name; "" follows the system
    theme: Theme
    scale: float32
    fontDirs: seq[string]
    fonts: Fonts
    messages: Messages                         ## the frontend's messages, on their way to the log
    core: AppState                             ## the application state
    trace: TracePanelUi                        ## the main panel's plot window
    auxTrace: TracePanelUi                     ## the Aux window's plot (its own panel)
    auxSeen: bool                              ## whether the core had the Aux window open last frame
    map: MapUi                                 ## the map window
    headers: HeadersUi                         ## the Headers window
    mapCursor: string                          ## the pointer's coordinates over the map last frame
    files: FileListUi                          ## the file list's window
    records: RecordListUi                      ## the record list's window
    missing: MissingUi                         ## the Missing traces window
    quality: QualityUi                         ## the Trace quality window
    vibfolder: VibFolderUi                     ## the Vibrator QC window
    output: OutputUi                           ## the Output window
    join: JoinUi                               ## the "Import survey" window
    shotLog: ShotLogUi                         ## the "Shot log" window
    clearSurvey: ClearSurveyUi                 ## Clear survey's confirmation
    memory: MemoryUi                           ## the "File memory" window
    refs: ReferencesUi                         ## the Reference archive window and Generate
    project: ProjectUi                         ## the "Project" and "New project" windows
    titled: string                             ## the main window's title, as set last
    reopen: ReopenUi                           ## the "Reopen with options" dialog
    about: AboutUi                             ## Help > About viewSEG
    shortcuts: ShortcutsUi                     ## Help > Keyboard shortcuts
    settingsWin: SettingsUi                    ## Tools > Settings
    spectra: SpectraUi                         ## the spectrum windows: the live panel, the FFT windows
    compare: CompareUi                         ## the compare window: two traces, A and B
    plotWins: PlotWindowsUi                    ## the analysis windows (New plot)
    dropped: seq[string]                       ## paths dropped on the window, until the drop ends
    dropAt: float64                            ## when a drag was last seen over the window
    windows: WindowsUi                         ## which windows are shown (the Window menu)
    checkPlaces: int                           ## frames left to bring back windows off every screen
    offScreen: seq[string]                     ## the windows brought back meanwhile
    arrangeNext: Option[string]                ## a layout text to arrange the windows by (tests)
    noticed: int                               ## the core's notices taken so far (serials)
    shownNotices: seq[(Notice, float64)]       ## notices on screen, and since when
    pick: Pick                                 ## under the mouse in the plot last frame: the readout
    typed: seq[string]                         ## text events pushed by `typeText`, kept until the end
    logView: LogView
    echoed: int                                ## the core log's entries echoed to stdout so far
    echoing: bool                              ## stdout is a terminal
    dog: FrameWatchdog
    slow: SlowFrameDigest
    marks: Marks
    pendingTheme: Option[string]               ## picked in the menu, applied after the frame
    previewWanted: Option[string]
      ## the theme the pointer rests on in View > Theme ("" for Follow system),
      ## drawn after the frame until the submenu closes (`followPreview`)
    previewing: bool ## `theme` is a preview of `previewName`
    previewName: string
    beforePreview: Theme ## the theme the preview replaced, to go back to
    previewKept: bool ## the preview ends with a pick of another theme
    appliedTheme: string ## the settings' theme last followed
    layoutLoads: int ## the core's `layoutLoads` last followed
    layoutName: array[MaxLayoutName + 1, char] ## the name typed in "Save layout"
    askLayoutName: bool ## open the "Save layout" popup this frame
    keepsLayouts: bool
    placed: bool ## the main window moved or changed size this frame
    layoutDone: bool
    running: bool
    agent: AgentControl ## agent control: off until turned on
    agentSocket: string ## where it listens; "" until first needed
    version: string ## the program's version, for agents
    dialogs: DialogHook ## `RunOptions.dialogs`
    trayAllowed: bool ## `RunOptions.tray`
    trayProblem: string ## why the tray icon could not be shown; "" for none
    trayTried: bool ## the icon was asked for since the setting last changed
    trayAsked: bool ## the session bus was asked about a tray since then
    inTray: bool ## the main window is hidden in the tray
    trayHides: int ## times it was hidden there (tests)
    pendingInput: seq[QueuedInput]
      ## test input left this frame (`moveMouse`, `pressMouse`, `scrollWheel`,
      ## `pressKey`, `typeText`, `dropPaths`). Delivered through one button
      ## change a frame, so a press and a release left together are each seen,
      ## and a key released after the click is not seen before it

  FrameInfo* = object
    ## What a frame hook sees. The hook runs after the main window is drawn and
    ## before its buffers swap, with its GL context current.
    index*: int ## 0 for the first frame
    width*, height*: int ## framebuffer size in pixels
    theme*: Theme ## the theme the frame was drawn with
    scale*: float32 ## the main window's UI scale (1 = 100 %)
    ui: ptr Ui

  FrameHook* = proc (frame: FrameInfo) {.closure.}

  StartupStep* = enum
    ## The steps of opening the main window, in order.
    ssVideo = "start SDL's video subsystem"
    ssWindow = "create the main window"
    ssGlContext = "create an OpenGL 3.3 core context"
    ssGlFunctions = "load the OpenGL functions"
    ssImguiSdl = "start Dear ImGui's SDL3 backend"
    ssImguiGl = "start Dear ImGui's OpenGL 3 backend"

  StartupFailure* = object
    ## Why the main window could not be opened.
    step*: StartupStep
    reason*: string  ## the library's own words; "" when it gave none
    text*: string    ## the whole message shown to the user
    logFile*: string ## where `text` was written; "" when it could not be

  FailureHook* = proc (failure: StartupFailure) {.closure.}

  DialogHook* = proc (kind: DialogKind; location: string): seq[string] {.closure.}
    ## Stands for the system's file dialogs (tests): given the dialog asked
    ## for and where it starts, the paths chosen; none for a cancel.

  SimKey* = enum
    ## Keys a test can press (`pressKey`).
    skEquals, skMinus, skKeypadPlus, skKeypadMinus, skLeft, skRight, skUp, skDown,
    skBackspace, skZero, skEscape, skEnter, skCtrl, skShift, skAlt, skTab, skHome, skEnd,
    skPageUp, skPageDown, skW, skG, skR, skK, skZ, skLeftBracket, skRightBracket, skM, skY, skP, skF,
    skF1, skE

  SimMod* = enum
    smCtrl, smShift, smAlt

  RunOptions* = object
    maxFrames*: int            ## stop after this many frames; 0 runs until the window closes
    onFrame*: FrameHook        ## called once per frame, nil for none
    allowToolkitErrors*: bool
      ## a run with `onFrame` (a test) fails on a Dear ImGui check that fails (a Pop...()
      ## too many times, an unbalanced Begin/End or ID stack): a debug build aborts at it,
      ## a release build raises `AssertionDefect` at the end of `run`; true for a test
      ## that causes one on purpose
    theme*: ThemeChoice
      ## `followSystem` (the default) also honours the VIEWSEG_THEME
      ## environment variable.
    themeName*: string
      ## a theme file to use: a name from the theme folders or a path; "" for
      ## the choice above
    assetDirs*: Option[seq[string]]
      ## where `fonts/` and `themes/` are looked up; default `paths.assetDirs()`
    userThemeDir*: Option[string]
      ## the user's own themes, searched first; default `<config>/themes`
    logDir*: Option[string]
      ## where a start-up failure is written; default `paths.logDir()`
    onFailure*: FailureHook
      ## called when start-up fails; nil shows a message box
    openPaths*: seq[string]
      ## seismic files to open once the window is up (the command line's)
    indexCacheDir*: Option[string]
      ## where parseSEG's index caches go; default `<cache>/index`
    persist*: bool
      ## read the settings from `configDir` at start and save them there as
      ## they change, and write this run's session log in `logDir` (the
      ## program does; tests choose)
    configDir*: Option[string]
      ## where the settings are kept; default `paths.configDir()`
    vendorFolders*: Option[seq[VendorFolder]]
      ## where vendor header maps are loaded from (besides the project's), in
      ## order of preference; default: `<configDir>/vendormaps`, the program's
      ## and `PARSESEG_VENDOR_PATH`'s folders. Only with `persist`.
    version*: string
      ## the program's version, logged first ("" for none)
    windowSize*: (int, int)
      ## the main window's size in pixels at 100 %; (0, 0) for the default
    maxTextureSize*: int
      ## the largest texture side the plot uses; 0 for the GPU's limit
      ## (tests set a small one, so that tiles are cut into blocks)
    agent*: bool
      ## start with agent control on (`--mcp`); Tools > Agent control turns it
      ## on and off in any case
    agentSocket*: string
      ## the socket agent control listens on; "" for `paths.agentSocket()`
    dialogs*: DialogHook
      ## answers the file dialogs in place of the system's; nil shows them
    resetWindows*: bool
      ## start with the windows as at a first start (`--reset-windows`): the
      ## saved layout is not used, and the main window opens on the primary
      ## screen at its default size; every other setting is as saved
    tray*: bool
      ## the program's icon may be in the system tray (`Settings.tray`); the
      ## program sets it, tests choose (a tray loads GTK on Linux)
    simulate: set[StartupStep] ## tests: these steps fail without being tried

proc readPixel*(frame: FrameInfo; x, y: int): Rgba =
  ## The colour at (`x`, `y`) of the frame being drawn, in framebuffer pixels
  ## from the top-left corner. Only valid inside a frame hook.
  if x notin 0 ..< frame.width or y notin 0 ..< frame.height:
    raise newException(ValueError, "pixel (" & $x & ", " & $y & ") is outside the " &
      $frame.width & "x" & $frame.height & " framebuffer")
  var px: array[4, uint8]
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  glReadPixels(x.GLint, GLint(frame.height - 1 - y), 1, 1, GL_RGBA, GL_UNSIGNED_BYTE,
    addr px)
  Rgba(r: px[0], g: px[1], b: px[2], a: px[3])

proc readFrame*(frame: FrameInfo): seq[Rgba] =
  ## The whole frame, row by row from the top, opaque. Only valid inside a
  ## frame hook.
  var raw = newSeq[uint8](frame.width * frame.height * 4)
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  glReadPixels(0, 0, frame.width.GLint, frame.height.GLint, GL_RGBA, GL_UNSIGNED_BYTE,
    addr raw[0])
  result = newSeq[Rgba](frame.width * frame.height)
  for y in 0 ..< frame.height:
    let src = (frame.height - 1 - y) * frame.width * 4         # GL rows start at the bottom
    for x in 0 ..< frame.width:
      let i = src + 4 * x
      result[y * frame.width + x] = Rgba(r: raw[i], g: raw[i + 1], b: raw[i + 2], a: 255)

proc savePng*(frame: FrameInfo; path: string): bool =
  ## Writes the frame being drawn to `path` as a PNG (SDL's own encoder).
  ## Only valid inside a frame hook. False, with SDL's error on stderr, when
  ## it cannot be written.
  var pixels = frame.readFrame()
  let surface = SDL_CreateSurfaceFrom(frame.width.cint, frame.height.cint,
    SDL_PIXELFORMAT_RGBA32, addr pixels[0], cint(frame.width * 4))
  result = not surface.isNil and SDL_SavePNG(surface, path.cstring)
  if not surface.isNil:
    SDL_DestroySurface(surface)
  if not result:
    stderr.writeLine "viewSEG: cannot write ", path, ": ", SDL_GetError()

proc markOf*(frame: FrameInfo; name: string): Rect =
  ## Where the named part (`"toolbar"`, `"statusbar"`, `"seismic"`,
  ## `"tool.Open file"`, `"tool.Open folder"` ...) was drawn in this frame, in
  ## framebuffer pixels; an empty rectangle when it was not.
  result = Rect()
  for (n, r) in frame.ui.marks:
    if n == name: result = r

proc modalOpen*(frame: FrameInfo): bool =
  ## A modal popup is open and visible (Dear ImGui dims the rest of the window behind it).
  ## For tests.
  not igGetTopMostAndVisiblePopupModal().isNil

proc workArea*(frame: FrameInfo): Rect =
  ## The main window's work area (under the menu bar), in the marks' units. For tests.
  let vp = igGetMainViewport()
  let k = igGetIO_Nil().DisplayFramebufferScale
  Rect(pos: vec2((vp.WorkPos.x - vp.Pos.x) * k.x, (vp.WorkPos.y - vp.Pos.y) * k.y),
    size: vec2(vp.WorkSize.x * k.x, vp.WorkSize.y * k.y))

proc keepInMainWindow*(frame: FrameInfo) =
  ## Dear ImGui draws every window inside the main one from now on (no window of its own
  ## for a dialog or popup), so a screenshot of the frame holds them. For tests.
  let io = igGetIO_Nil()
  io.ConfigFlags = io.ConfigFlags and not ImGui_ConfigFlags_ViewportsEnable.cint

proc markNames*(frame: FrameInfo; prefix: string): seq[string] =
  ## The names of the parts drawn in this frame that start with `prefix`
  ## (`markOf`), in the order drawn.
  for (n, r) in frame.ui.marks:
    if n.startsWith(prefix): result.add n

proc windowName*(frame: FrameInfo; id: string): string =
  ## The full name of the window whose ImGui ID is `id` (`"plot"`, `"files"`
  ## ...): its title, then `###` and the ID; "" when there is none.
  let w = igFindWindowByName(("###" & id).cstring)
  if w == nil: "" else: $w.Name

proc idConflict*(frame: FrameInfo): bool =
  ## Dear ImGui shows its "visible items with conflicting ID" tooltip this
  ## frame: two items under the pointer share an id (it finds that only for
  ## the item the pointer is on). For tests.
  let w = igFindWindowByName("##Tooltip_Error")
  w != nil and w.Active

proc chooseTheme*(frame: FrameInfo; name: string) =
  ## Picks theme file `name` ("" follows the system) as View > Theme does;
  ## it applies after this frame.
  var s = frame.ui.core.settings
  s.theme = name
  frame.ui.core.apply Command(kind: ckSettings, settings: s)

proc messages*(frame: FrameInfo): seq[Message] =
  ## What the Messages window holds: the log's entries, oldest first, each
  ## as one line.
  for e in frame.ui.core.log:
    result.add Message(level: levelOf(e.severity), text: line(e))

proc shownMessages*(frame: FrameInfo): int =
  ## How many lines the Messages window shows (for tests).
  frame.ui.logView.shown

proc messageScroll*(frame: FrameInfo): float32 =
  ## How far the Messages window's lines are scrolled (for tests).
  frame.ui.logView.scrolled

proc layoutText*(frame: FrameInfo): string =
  ## How Dear ImGui would save the windows' arrangement now (for tests).
  $igSaveIniSettingsToMemory(nil)

proc resetLayout*(frame: FrameInfo) =
  ## Puts the windows back where they are at a first start, as Window >
  ## Reset the windows does; it takes effect next frame.
  frame.ui.layoutDone = false
  frame.ui.windows.showAll()

proc arrangeWindows*(frame: FrameInfo; text: string) =
  ## Arranges the windows as Dear ImGui's layout `text` says, after this
  ## frame, as loading a layout does (for tests).
  frame.ui.arrangeNext = some(text)

type
  WindowPlace* = object
    ## Where one of the windows the main window docks is (`windowPlace`).
    shown*: bool   ## drawn this frame
    inSight*: bool ## drawn and not behind another tab
    docked*: bool  ## docked in the main window's dockspace
    apart*: bool   ## in a window of the desktop's own, outside the main window
    rect*: Rect    ## where, in the desktop's coordinates

proc windowPlace*(frame: FrameInfo; id: string): WindowPlace =
  ## Where the window whose ImGui ID is `id` (`"files"`, `"plot"` ...) is in
  ## this frame (for tests).
  result = WindowPlace()
  let w = igFindWindowByName(("###" & id).cstring)
  if w != nil:
    result.shown = w.Active
    result.inSight = w.Active and not w.Hidden
    result.rect = Rect(pos: vec2(w.Pos.x, w.Pos.y), size: vec2(w.Size.x, w.Size.y))
    result.apart = cast[pointer](w.Viewport) != cast[pointer](igGetMainViewport())
    var node = if w.DockIsActive: w.DockNode else: nil
    while node != nil and node.ParentNode != nil: node = node.ParentNode
    result.docked = node != nil and node.ID == frame.ui.windows.dockspace

proc mainWindowRect*(frame: FrameInfo): Rect =
  ## Where the main window is, in the desktop's coordinates (for tests).
  let vp = igGetMainViewport()
  Rect(pos: vec2(vp.Pos.x, vp.Pos.y), size: vec2(vp.Size.x, vp.Size.y))

proc hiddenWindows*(frame: FrameInfo): set[AppWindow] =
  ## The windows the Window menu shows unticked (for tests).
  frame.ui.windows.hidden

proc screens*(frame: FrameInfo): seq[Rect] =
  ## The screens' usable areas, in the desktop's coordinates (for tests).
  screensNow()[0]

proc moveMainWindow*(frame: FrameInfo; x, y: int) =
  ## Moves the main window to (`x`, `y`) in the desktop's coordinates, as
  ## the user would by its title bar (for tests).
  discard SDL_SetWindowPosition(frame.ui.window, cint(x), cint(y))

proc stop*(frame: FrameInfo) =
  ## Ends the run after this frame, as closing the window does.
  frame.ui.running = false

proc sayMinimized*(frame: FrameInfo) =
  ## Tells the frame loop the main window was minimized, as the desktop does
  ## (an X server without a window manager minimizes nothing). For tests.
  var ev: SDL_Event
  ev.window = struct_SDL_WindowEvent(type_field: SDL_EVENT_WINDOW_MINIMIZED,
    windowID: SDL_GetWindowID(frame.ui.window))
  discard SDL_PushEvent(addr ev)

proc inTray*(frame: FrameInfo): bool =
  ## The main window is hidden in the tray (Window > Minimize to the tray).
  frame.ui.inTray

proc trayHides*(frame: FrameInfo): int =
  ## How many times the main window was hidden in the tray since the start.
  frame.ui.trayHides

proc mainWindowHidden*(frame: FrameInfo): bool =
  ## SDL says the main window is hidden.
  (SDL_GetWindowFlags(frame.ui.window) and SDL_WINDOW_HIDDEN) != 0

proc trayProblem*(frame: FrameInfo): string =
  ## Why the tray icon could not be shown; "" when it could or was not asked.
  frame.ui.trayProblem

proc deliverInput(ui: var Ui) =
  ## Hands the window the input a test queued, through one button change.
  ## A press and a release left in the same frame are each seen by a frame:
  ## together, the release cancels the press and the click is lost. Nothing
  ## after that button is handed over this frame, so a key released after the
  ## click is still held when the click is taken.
  var n = 0
  var sent = false
  while n < ui.pendingInput.len:
    if sent: break
    var ev = ui.pendingInput[n].ev
    let owned = ui.pendingInput[n].owned
    if owned >= 0:
      let s = ui.typed[owned].cstring
      if ev.type_field == SDL_EVENT_TEXT_INPUT.uint32: ev.text.text = s
      elif ev.type_field == SDL_EVENT_DROP_FILE.uint32: ev.drop.data = s
    discard SDL_PushEvent(addr ev)
    let kind = ev.type_field
    inc n
    if kind == SDL_EVENT_MOUSE_BUTTON_DOWN.uint32 or
        kind == SDL_EVENT_MOUSE_BUTTON_UP.uint32:
      sent = true
  if n > 0: ui.pendingInput.delete(0 ..< n)

proc moveMouse*(frame: FrameInfo; at: Vec2) =
  ## Moves the mouse pointer to `at` (framebuffer pixels from the window's
  ## top-left corner), as the user would; the UI sees it from the next frame.
  ## For tests: press with `pressMouse` a frame or two later.
  let w = frame.ui.window
  let density = SDL_GetWindowPixelDensity(w)
  let (x, y) = (at.x / density, at.y / density)
  SDL_WarpMouseInWindow(w, x, y) # gives the window the mouse focus
  var ev: SDL_Event
  ev.motion = SDL_MouseMotionEvent(type_field: SDL_EVENT_MOUSE_MOTION,
    windowID: SDL_GetWindowID(w), x: x, y: y)
  frame.ui.pendingInput.add QueuedInput(ev: ev, owned: -1)

proc pressMouse*(frame: FrameInfo; at: Vec2; down: bool; button = 1) =
  ## Presses (`down`) or releases a mouse button (1 left, 2 middle, 3 right)
  ## at `at`, where `moveMouse` put the pointer. For tests. A press and a
  ## release left in one frame are delivered on two frames (`deliverInput`).
  let w = frame.ui.window
  let density = SDL_GetWindowPixelDensity(w)
  let (x, y) = (at.x / density, at.y / density)
  var ev: SDL_Event
  ev.button = SDL_MouseButtonEvent(type_field: (if down: SDL_EVENT_MOUSE_BUTTON_DOWN
    else: SDL_EVENT_MOUSE_BUTTON_UP), windowID: SDL_GetWindowID(w), button: uint8(button),
    down: down, clicks: 1, x: x, y: y)
  frame.ui.pendingInput.add QueuedInput(ev: ev, owned: -1)

proc scrollWheel*(frame: FrameInfo; at: Vec2; notches: float32; sideways = 0'f32) =
  ## Turns the mouse wheel by `notches` (up is positive) and sideways
  ## (right is positive) with the pointer at `at`. For tests; modifiers come
  ## from the last `pressKey`.
  let w = frame.ui.window
  let density = SDL_GetWindowPixelDensity(w)
  var ev: SDL_Event
  ev.wheel = SDL_MouseWheelEvent(type_field: SDL_EVENT_MOUSE_WHEEL, windowID: SDL_GetWindowID(w),
    x: sideways, y: notches, direction: SDL_MOUSEWHEEL_NORMAL, mouse_x: at.x / density,
    mouse_y: at.y / density, integer_x: int32(sideways), integer_y: int32(notches))
  frame.ui.pendingInput.add QueuedInput(ev: ev, owned: -1)

proc pressKey*(frame: FrameInfo; key: SimKey; down: bool; mods: set[SimMod] = {}) =
  ## Presses (`down`) or releases `key` with `mods` held, as the keyboard
  ## would. For tests. Queued with the pointer, so a key released after a
  ## click is still held when the click is taken.
  const scancodes: array[SimKey, SDL_Scancode] = [SDL_SCANCODE_EQUALS, SDL_SCANCODE_MINUS,
    SDL_SCANCODE_KP_PLUS, SDL_SCANCODE_KP_MINUS, SDL_SCANCODE_LEFT, SDL_SCANCODE_RIGHT,
    SDL_SCANCODE_UP, SDL_SCANCODE_DOWN, SDL_SCANCODE_BACKSPACE, SDL_SCANCODE_0,
    SDL_SCANCODE_ESCAPE, SDL_SCANCODE_RETURN, SDL_SCANCODE_LCTRL, SDL_SCANCODE_LSHIFT,
    SDL_SCANCODE_LALT, SDL_SCANCODE_TAB, SDL_SCANCODE_HOME, SDL_SCANCODE_END,
    SDL_SCANCODE_PAGEUP, SDL_SCANCODE_PAGEDOWN, SDL_SCANCODE_W, SDL_SCANCODE_G, SDL_SCANCODE_R,
    SDL_SCANCODE_K, SDL_SCANCODE_Z, SDL_SCANCODE_LEFTBRACKET, SDL_SCANCODE_RIGHTBRACKET,
    SDL_SCANCODE_M, SDL_SCANCODE_Y, SDL_SCANCODE_P, SDL_SCANCODE_F, SDL_SCANCODE_F1,
    SDL_SCANCODE_E]
  var m = 0'u16
  if smCtrl in mods: m = m or uint16(SDL_KMOD_LCTRL)
  if smShift in mods: m = m or uint16(SDL_KMOD_LSHIFT)
  if smAlt in mods: m = m or uint16(SDL_KMOD_LALT)
  let w = frame.ui.window
  var ev: SDL_Event
  ev.key = SDL_KeyboardEvent(type_field: (if down: SDL_EVENT_KEY_DOWN else: SDL_EVENT_KEY_UP),
    windowID: SDL_GetWindowID(w), scancode: scancodes[key],
    key: SDL_GetKeyFromScancode(scancodes[key], SDL_Keymod(m), true), mod_field: SDL_Keymod(m),
    down: down)
  frame.ui.pendingInput.add QueuedInput(ev: ev, owned: -1)

proc resizeWindow*(frame: FrameInfo; width, height: int) =
  ## Gives the main window a new size in window coordinates, as the user
  ## would by its edge. For tests.
  discard SDL_SetWindowSize(frame.ui.window, cint(width), cint(height))

proc windowSize*(frame: FrameInfo): (int, int) =
  ## The main window's size in window coordinates (for tests).
  var w, h: cint
  discard SDL_GetWindowSize(frame.ui.window, addr w, addr h)
  (w.int, h.int)

proc typeText*(frame: FrameInfo; text: string) =
  ## Types `text` into the item that has the keyboard, as text input
  ## would. For tests.
  let w = frame.ui.window
  frame.ui.typed.add text # the event points at it, filled in at delivery
  var ev: SDL_Event
  ev.text = SDL_TextInputEvent(type_field: SDL_EVENT_TEXT_INPUT, windowID: SDL_GetWindowID(w))
  frame.ui.pendingInput.add QueuedInput(ev: ev, owned: frame.ui.typed.high)

proc dropPaths*(frame: FrameInfo; paths: openArray[string]) =
  ## Drops `paths` (files or folders) on the main window, as a file manager
  ## would. For tests.
  let w = frame.ui.window
  var ev: SDL_Event
  ev.drop = SDL_DropEvent(type_field: SDL_EVENT_DROP_BEGIN, windowID: SDL_GetWindowID(w))
  frame.ui.pendingInput.add QueuedInput(ev: ev, owned: -1)
  for p in paths:
    frame.ui.typed.add p # the event points at it, filled in at delivery
    ev.drop = SDL_DropEvent(type_field: SDL_EVENT_DROP_FILE, windowID: SDL_GetWindowID(w))
    frame.ui.pendingInput.add QueuedInput(ev: ev, owned: frame.ui.typed.high)
  ev.drop = SDL_DropEvent(type_field: SDL_EVENT_DROP_COMPLETE, windowID: SDL_GetWindowID(w))
  frame.ui.pendingInput.add QueuedInput(ev: ev, owned: -1)

proc typing*(frame: FrameInfo): bool =
  ## Whether a text box has the keyboard (for tests).
  igGetIO_Nil().WantTextInput

proc pick*(frame: FrameInfo): Pick =
  ## What lies under the mouse in the plot, as this frame found it: what
  ## the status bar reads out next.
  frame.ui.pick

proc core*(frame: FrameInfo): lent AppState =
  ## The application state as this frame drew it.
  frame.ui.core

proc tracePanel*(frame: FrameInfo): lent TracePanelUi =
  ## The main plot window's state as this frame drew it: `drawnView`,
  ## `densityImage`.
  frame.ui.trace

proc auxTracePanel*(frame: FrameInfo): lent TracePanelUi =
  ## The Aux window's plot state as this frame drew it (`drawnView`, `plotShown`).
  frame.ui.auxTrace

proc joinWindow*(frame: FrameInfo): lent JoinUi =
  ## The "Import survey" window's state (`shown`).
  frame.ui.join

proc projectWindows*(frame: FrameInfo): lent ProjectUi =
  ## The "Project" and "New project" windows' state (`shown`, `making`).
  frame.ui.project

proc windowTitle*(frame: FrameInfo): string =
  ## The main window's title, as set last.
  frame.ui.titled

proc addJoinFiles*(frame: FrameInfo; paths: openArray[string]) =
  ## Adds `paths` to the survey files of the "Import survey" window, as its
  ## "Add files..." dialog does (tests cannot drive the system's dialog).
  frame.ui.join.addFiles(paths)

proc plotWindows*(frame: FrameInfo): lent PlotWindowsUi =
  ## The analysis windows' state (New plot), for tests.
  frame.ui.plotWins

proc spectraWindows*(frame: FrameInfo): lent SpectraUi =
  ## The spectrum windows' frontend state (tests: what each read under the pointer).
  frame.ui.spectra

proc reopenDialog*(frame: FrameInfo): lent ReopenUi =
  ## The "Reopen with options" dialog's state (`shown`).
  frame.ui.reopen

proc headersWindow*(frame: FrameInfo): lent HeadersUi =
  ## The Headers window's state as this frame drew it: `summaryPicked`.
  frame.ui.headers

proc mapWindow*(frame: FrameInfo): lent MapUi =
  ## The map window's state as this frame drew it: `mapShown`,
  ## `hoveredPoints`, `pointTexts`, `rulerText`, `scaleText`.
  frame.ui.map

proc mapCursor*(frame: FrameInfo): lent string =
  ## The coordinates the status bar shows for the pointer over the map;
  ## "" when it is not over the map (for tests).
  frame.ui.mapCursor

proc showView*(frame: FrameInfo; v: Viewport) =
  ## Pans and zooms the main plot to `v` next frame, as the user would.
  frame.ui.trace.show(v)

proc showMapView*(frame: FrameInfo; v: MapView) =
  ## Gives the map the centre and scale of `v` next frame, as a pan or zoom
  ## of the user's would.
  frame.ui.map.show(v)

proc apply*(frame: FrameInfo; cmd: Command) =
  ## Applies `cmd` as a control of the window would (for tests).
  frame.ui.core.apply cmd

proc flush*(frame: FrameInfo) =
  ## Saves the project and what is remembered now, without waiting for
  ## `SaveDelay` (for tests).
  frame.ui.core.flushFiles()

proc agentControl*(frame: FrameInfo): lent AgentControl =
  ## Agent control as this frame left it: `running`, `clients`, `path`.
  frame.ui.agent

proc toggleAgent(ui: var Ui) =
  ## Turns agent control on or off, as Tools > Agent control does. The
  ## default socket is found only now: finding it tries the program's folder.
  if ui.agent.running:
    ui.agent.stop(ui.core)
  else:
    # The default socket is found off this thread: finding it writes a probe
    # in the program's folder, which may be on a drive that does not answer.
    # (`currentContext` was made at start, on this thread; it is only read there.)
    discard ui.agent.start(ui.core, ui.agentSocket, ui.version, encodePng,
      find = proc (): string {.nimcall, gcsafe.} =
      {.cast(gcsafe).}: agentSocket())
    if ui.agent.running: ui.agentSocket = ui.agent.path

proc setAgentControl*(frame: FrameInfo; on: bool) =
  ## Turns agent control on or off, as Tools > Agent control does.
  if on != frame.ui.agent.running: frame.ui[].toggleAgent()

# ------------------------------------------------------------------ themes --

proc themeDirs(userDir: string; assetDirs: openArray[string]): seq[string] =
  result = @[userDir]
  for d in assetDirs:
    result.add d / "themes"

proc pickTheme(ui: var Ui): Theme =
  ## The theme to draw with now: the selected file, else the default file for
  ## the system's (or the forced) mode, else the built-in theme.
  ## A theme named but found nowhere (one viewSEG no longer ships, such as
  ## Retro 82 and Ristretto, or a file since removed) gives way to Follow
  ## system, said once, and the settings follow the system from then on.
  let mode = resolveTheme(ui.choice, ui.system)
  var path = ""
  var listed = -1
  proc find(ui: Ui; wanted: string; path: var string; listed: var int) =
    for i, f in ui.themes:
      if f.name == wanted: (path, listed) = (f.path, i)
    if path.len == 0 and fileExists(wanted):
      path = wanted
  if ui.selected.len > 0:
    find(ui, ui.selected, path, listed)
    if path.len == 0:
      const NoLongerShipped = ["retro-82", "ristretto"] # their licences do not allow it
      ui.messages.add "The theme `" & ui.selected & "` is not here" &
        (if ui.selected in NoLongerShipped: " (it no longer comes with viewSEG)" else: "") &
        ": following the system's theme instead. Its colors.toml in your themes folder " &
        "(viewSEG --paths) brings it back.", mlInfo
      if ui.core.settings.theme == ui.selected:
        var s = ui.core.settings
        s.theme = ""
        ui.core.apply Command(kind: ckSettings, settings: s)
        ui.appliedTheme = ""
      ui.selected = ""
  if ui.selected.len == 0:
    find(ui, DefaultThemeNames[mode], path, listed)
  if path.len == 0:
    result = builtinTheme(mode)
  elif listed >= 0 and themeStamp(path) == ui.themes[listed].stamp:
    # As read at start, so a pick parses nothing on the UI thread; a file
    # changed since (being edited) is read again below.
    result = ui.themes[listed].theme
    for p in ui.themes[listed].problems:
      ui.messages.add p, mlWarning
  else:
    var problems: seq[string] = @[]
    result = loadTheme(path, mode, problems) # at most `MaxThemeBytes`
    for p in problems:
      ui.messages.add p, mlWarning
  ui.messages.add "Theme: " & result.name & " (" &
    (if path.len > 0: path else: "built in") & ")"

proc restyle(ui: var Ui) =
  ## The theme on every widget and on the frames the OS draws around the
  ## windows (a theme set, a preview, a new display scale).
  applyStyle(ui.theme, ui.scale)
  dressWindows(lookOf(ui.theme))

proc say(ui: var Ui; text: string; level = mlInfo) =
  ## Puts one of the frontend's own messages in the log.
  ui.core.report(severityOf(level), "", text)

proc flushMessages(ui: var Ui) =
  ## Moves what the theme and the fonts said into the log.
  for m in ui.messages.items:
    ui.say(m.text, m.level)
  ui.messages.items.setLen 0

proc setTheme(ui: var Ui) =
  ## Loads the theme `pickTheme` names, with its fonts, and restyles.
  ui.theme = ui.pickTheme()
  ui.previewing = false # what is set now replaces a preview
  ui.fonts.load(ui.theme, ui.fontDirs, ui.messages)
  ui.flushMessages()
  ui.restyle()

proc followPreview(ui: var Ui) =
  ## Draws the theme View > Theme's pointer rests on, from the file as read
  ## at start (no message: its problems are said when it is picked), or
  ## goes back to the theme before once the submenu closes without a pick
  ## of another. Between frames: fonts and styles change.
  if ui.previewWanted.isSome:
    let name = ui.previewWanted.get
    if not ui.previewing or name != ui.previewName:
      let wanted = if name.len > 0: name
                   else: DefaultThemeNames[resolveTheme(ui.choice, ui.system)]
      for f in ui.themes:
        if f.name == wanted:
          if not ui.previewing: (ui.beforePreview, ui.previewKept) = (ui.theme, false)
          (ui.previewing, ui.previewName, ui.theme) = (true, name, f.theme)
          ui.fonts.load(ui.theme, ui.fontDirs, ui.messages)
          ui.flushMessages()
          ui.restyle()
  elif ui.previewing:
    ui.previewing = false
    if not ui.previewKept:
      ui.theme = ui.beforePreview
      ui.fonts.load(ui.theme, ui.fontDirs, ui.messages)
      ui.flushMessages()
      ui.restyle()
    ui.previewKept = false

proc chooseTheme(ui: var Ui; name: string) =
  ## Makes theme file `name` ("" follows the system) the settings' theme;
  ## `followSettings` applies it after the frame.
  var s = ui.core.settings
  s.theme = name
  ui.core.apply Command(kind: ckSettings, settings: s)

proc toggleTheme(ui: var Ui) =
  ## Switches to the default theme of the other mode.
  let other = if ui.theme.mode == tmDark: tmLight else: tmDark
  ui.chooseTheme(DefaultThemeNames[other])

proc followSettings(ui: var Ui) =
  ## A theme the settings name now (the menu, an import, a reset) is
  ## applied after this frame.
  let wanted = ui.core.settings.theme
  if wanted != ui.appliedTheme:
    ui.appliedTheme = wanted
    if wanted != ui.selected: ui.pendingTheme = some(wanted)

# ------------------------------------------------------------------- tray --

proc ask(ui: Ui; kind: DialogKind; location = "") =
  ## Shows the file dialog `kind`, starting at `location`; its answer comes
  ## as a shell event (from `RunOptions.dialogs` when a test gives one).
  if ui.dialogs == nil:
    showDialog(kind, SDL_GetWindowID(ui.window), location)
  else:
    let paths = ui.dialogs(kind, location)
    postShellEvent(if paths.len > 0: ShellEvent(kind: sePathsChosen, dialog: kind,
      paths: paths) else: ShellEvent(kind: seCancelled, dialog: kind))

proc askOpenFile(ui: Ui) =
  ## File > Open file: the dialog, in the folder listed last.
  let recent = ui.core.settings.recentFolders
  ui.ask(dkOpenFile, if recent.len > 0: recent[0] & DirSep else: "")

proc showMain(ui: var Ui) =
  ## The main window shown, restored and in front: out of the tray, or from
  ## the taskbar, or from behind other windows.
  if ui.inTray:
    discard SDL_ShowWindow(ui.window) # its SDL children (viewports) come back with it
    ui.inTray = false
  if (SDL_GetWindowFlags(ui.window) and SDL_WINDOW_MINIMIZED) != 0:
    discard SDL_RestoreWindow(ui.window)
  discard SDL_RaiseWindow(ui.window)

proc hideInTray(ui: var Ui) =
  ## Minimizing with Window > Minimize to the tray on: the main window and its
  ## children hidden, off the taskbar, while the tray icon is there and seen.
  ## On Linux the session bus is asked again first (a few milliseconds; the
  ## bar may have gone): a window is never hidden with no icon to bring it
  ## back.
  if ui.core.settings.tray.minimize and trayShown() and not ui.inTray and
      probeTrayHost(timeoutMs = 300) == thPresent:
    discard SDL_HideWindow(ui.window)
    ui.inTray = true
    if (SDL_GetWindowFlags(ui.window) and SDL_WINDOW_HIDDEN) != 0: inc ui.trayHides

proc followTray(ui: var Ui) =
  ## The tray icon shown or taken away as the settings say. First the
  ## session bus is asked whether anything shows tray icons here (off this
  ## thread); with nothing, no tray is made (no GTK loaded either), Messages
  ## says so once, and Window > Minimize to the tray stays off, until the
  ## setting changes.
  let want = ui.trayAllowed and ui.core.settings.tray.icon
  if want and not trayShown() and not ui.trayTried:
    let answer = if ui.trayAsked: trayHostAnswer() else: none(TrayHost)
    if not ui.trayAsked:
      forgetTrayHost() # an answer from before (another run, the setting on before) is old
      askTrayHost()
      ui.trayAsked = true
    elif answer.isSome:
      ui.trayTried = true
      if answer.get != thPresent:
        ui.trayProblem = $answer.get
        ui.core.report(sevInfo, "tray", "No icon in the system tray: " & ui.trayProblem &
          ". Window > Minimize to the tray is off while there is none.")
      else:
        ui.trayProblem = showTray()
        if ui.trayProblem.len > 0:
          ui.core.report(sevWarning, "tray", "The icon cannot be put in the system tray: " &
            ui.trayProblem & (when defined(linux): " (a tray in Linux needs " &
              "libayatana-appindicator3)" else: ""))
  elif not want:
    ui.trayAsked = false
    ui.trayTried = false
    ui.trayProblem = ""
    if trayShown():
      if ui.inTray: ui.showMain() # never hidden with no way back
      hideTray()

# ------------------------------------------------------------------ events --

proc onShellEvent(ui: var Ui; ev: ShellEvent) =
  case ev.kind
  of sePathsChosen:
    case ev.dialog
    of dkOpenFile, dkOpenFiles:
      # One file: shown at once, its folder listed beside it; several: listed
      # together, the first shown.
      if ev.paths.len == 1:
        ui.core.apply Command(kind: ckShowFile, panel: MainPanel, path: ev.paths[0],
          listFolder: true)
      else:
        ui.core.apply Command(kind: ckBrowse, paths: ev.paths, showFirst: true)
    of dkOpenFolder:
      ui.core.apply Command(kind: ckBrowse, paths: ev.paths, showFirst: true)
    of dkOpenProject:
      ui.core.apply Command(kind: ckOpenProject, projectPath: ev.paths[0])
    of dkProjectPlace: ui.project.place = ev.paths[0]
    of dkProjectData:
      if ui.project.making: ui.project.addData(ev.paths[0])
      else: ui.core.apply Command(kind: ckProjectFolder, folderAction: faAdd,
        folderPath: ev.paths[0])
    of dkLocateFolder:
      ui.core.apply Command(kind: ckProjectFolder, folderAction: faLocate,
        folderPath: ev.paths[0], folderWas: ui.project.locating)
    of dkExportSettings:
      # Not every desktop adds the extension the filter names.
      let path = if ev.paths[0].splitFile.ext.len == 0: ev.paths[0] & ".nif" else: ev.paths[0]
      ui.core.apply Command(kind: ckExportSettings, docPath: path)
    of dkImportSettings:
      ui.core.apply Command(kind: ckImportSettings, docPath: ev.paths[0])
    of dkExportLayout:
      let path = if ev.paths[0].splitFile.ext.len == 0: ev.paths[0] & ".nif" else: ev.paths[0]
      # The arrangement on screen now, which Dear ImGui may not have said yet.
      ui.core.apply Command(kind: ckLayout, arrangement: $igSaveIniSettingsToMemory(nil))
      ui.core.apply Command(kind: ckExportLayout, docPath: path)
    of dkImportLayout:
      ui.core.apply Command(kind: ckImportLayout, docPath: ev.paths[0])
    of dkExportLog:
      let path = if ev.paths[0].splitFile.ext.len == 0: ev.paths[0] & ".log" else: ev.paths[0]
      ui.core.apply Command(kind: ckExportLog, docPath: path)
    of dkJoinFiles:
      ui.join.addFiles(ev.paths)
    of dkExportEdits:
      let path = if ev.paths[0].splitFile.ext.len == 0: ev.paths[0] & ".csv" else: ev.paths[0]
      ui.core.apply Command(kind: ckExportEdits, panel: MainPanel, listPath: path)
    of dkImportEdits:
      ui.core.apply Command(kind: ckImportEdits, panel: MainPanel, listPath: ev.paths[0])
    of dkExportMissing:
      ui.missing.startExport(ui.core, ev.paths[0])
    of dkExportQuality:
      ui.quality.startExport(ui.core, ev.paths[0])
    of dkExportVibFolder:
      ui.vibfolder.startExport(ui.core, ev.paths[0])
    of dkOutputSource: ui.output.setSource(ev.paths[0])
    of dkOutputDest: ui.output.setDest(ev.paths[0])
    of dkShotLog:
      ui.core.apply Command(kind: ckImportShotLog, logPath: ev.paths[0])
      ui.shotLog.open()
  of seCancelled:
    discard # the user closed the dialog: nothing to say
  of seDialogFailed:
    const hint = when defined(linux):
        " (Linux needs xdg-desktop-portal with a GTK or KDE backend, or zenity.)"
      else: ""
    ui.say($ev.dialog & ": the dialog could not be shown: " & ev.error & hint, mlError)
  of seThemeChanged:
    ui.say("System theme: " & $ev.theme)
    ui.system = ev.theme
    if ui.selected.len == 0 and resolveTheme(ui.choice, ev.theme) != ui.theme.mode:
      ui.setTheme()
    else:
      dressWindows(lookOf(ui.theme)) # SDL has just set the title bars to the system's mode
  of seTray:
    case ev.action
    of taShow:
      ui.showMain()
    of taOpenFile:
      ui.showMain()
      ui.askOpenFile()
    of taQuit:
      ui.running = false

func everyWindow(core: AppState): seq[string] =
  ## The ImGui IDs of the windows that can be outside the main window: the
  ## docked ones, the "Import survey" window and the FFT windows.
  for w in AppWindow: result.add $w
  result.add "join"
  result.add "memory"
  result.add "shortcuts"
  result.add "settings"
  for w in core.spectra:
    if w.id != LiveSpectrum: result.add "fft-" & $w.id

proc mainRect(ui: Ui): Rect =
  ## Where the main window is, in the desktop's coordinates.
  var x, y, w, h: cint
  discard SDL_GetWindowPosition(ui.window, addr x, addr y)
  discard SDL_GetWindowSize(ui.window, addr w, addr h)
  rect(x.int, y.int, w.int, h.int)

proc placeMain(ui: var Ui; wholly: bool): Rect =
  ## Brings the main window onto a screen: onto the primary one, at its
  ## size, when it is off every screen; with `wholly`, also wholly onto the
  ## one it is on when it hangs over an edge. Returns where it is then.
  ## A maximized or full-screen window is the desktop's to place.
  result = ui.mainRect
  let (screens, primary) = screensNow()
  let flags = SDL_GetWindowFlags(ui.window)
  if screens.len > 0 and (flags and (SDL_WINDOW_MAXIMIZED or SDL_WINDOW_FULLSCREEN)) == 0:
    let was = result
    if not result.reachable(screens):
      result = result.size.centredOn(screens[max(primary, 0)])
    elif wholly:
      result = result.fitOnto(screens[result.homeScreen(screens, primary)])
    if result != was:
      if result.size != was.size:
        discard SDL_SetWindowSize(ui.window, cint(result.size.x), cint(result.size.y))
      discard SDL_SetWindowPosition(ui.window, cint(result.pos.x), cint(result.pos.y))
      ui.placed = true

proc resetWindows(ui: var Ui) =
  ## Window > Reset the windows: the default layout next frame (the windows
  ## docked as at a first start; one closed until asked stays closed), the
  ## "Import survey" window at its first place, and the main window brought
  ## onto a screen when it is off every one.
  ui.windows.showAll()
  ui.layoutDone = false
  ui.join.placeAgain()
  ui.shotLog.placeAgain()
  ui.memory.placeAgain()
  ui.refs.placeAgain()
  discard ui.placeMain(wholly = false)
  ui.say("The windows are back as at a first start.")

proc bringWindows(ui: var Ui) =
  ## Window > Bring all windows onto this screen: the main window wholly on
  ## its screen, and every window outside it moved there.
  let main = ui.placeMain(wholly = true)
  let (screens, primary) = screensNow()
  if screens.len == 0:
    ui.say("The screens are not known: no window was moved.", mlWarning)
  else:
    # every floating window, from Dear ImGui's registry: into the main window's work area
    # (the part of its work area that is on the screen: the main window may have been
    # moved only a moment ago)
    let vp = igGetMainViewport()
    let work = Rect(pos: vec2(vp.WorkPos.x, vp.WorkPos.y),
      size: vec2(vp.WorkSize.x, vp.WorkSize.y))
    let home = screens[main.homeScreen(screens, primary)]
    let (x0, y0) = (max(work.pos.x, home.pos.x), max(work.pos.y, home.pos.y))
    let (x1, y1) = (min(work.pos.x + work.size.x, home.pos.x + home.size.x),
      min(work.pos.y + work.size.y, home.pos.y + home.size.y))
    let moved = bringAllInto(Rect(pos: vec2(x0, y0), size: vec2(max(x1 - x0, 1), max(y1 - y0, 1))))
    ui.say(if moved.len > 0: "Brought onto this screen: " & moved.join(", ") & "."
           else: "Every window is on this screen already.")

proc moveFloatingWindow*(frame: FrameInfo; titlePart: string; x, y: float32): bool =
  ## Puts the floating window whose title holds `titlePart` at (`x`, `y`) on the desktop,
  ## as a layout from a file does. For tests.
  moveFloating(titlePart, x, y)

proc bringAllWindows*(frame: FrameInfo) =
  ## Window > Bring all windows onto this screen. For tests.
  frame.ui[].bringWindows()

proc offScreenCheck(ui: var Ui) =
  ## For a few frames after a layout is applied (the desktop's windows for
  ## those outside the main window come and report where they are), the
  ## windows it put off every screen (one left on a monitor that is gone)
  ## are brought onto the main window's screen; then the log says which.
  if ui.checkPlaces > 0:
    dec ui.checkPlaces
    let (screens, primary) = screensNow()
    if screens.len > 0:
      for name in bringOnto(screens[ui.mainRect.homeScreen(screens, primary)], true, screens,
          everyWindow(ui.core)):
        if name notin ui.offScreen: ui.offScreen.add name
    if ui.checkPlaces == 0 and ui.offScreen.len > 0:
      ui.core.report(sevWarning, "layouts", "The layout put " & ui.offScreen.join(", ") &
        " off every screen (on a monitor that is gone, or past a screen's edge): brought " &
        "onto the main window's screen.")
      ui.offScreen.setLen 0

proc projectsHome(): string =
  ## Where New project makes a project by default: a folder the user sees
  ## and can copy from.
  when defined(windows): getHomeDir() / "Documents" / "viewSEG projects"
  else: getHomeDir() / "viewSEG projects"

proc followTitle(ui: var Ui) =
  ## The main window's title names the project open.
  let title = if ui.core.inProject: "viewSEG - " & ui.core.project.doc.name &
      (if ui.core.project.readOnly: " (read-only)" else: "") else: "viewSEG"
  if title != ui.titled:
    ui.titled = title
    discard SDL_SetWindowTitle(ui.window, title.cstring)
proc openReopen(ui: var Ui) =
  ## "Reopen with options" for the file the Seismic window shows.
  let i = ui.core.shownFile(ui.core.findPanel(MainPanel))
  if i < 0: ui.say("Reopen with options: no file is shown.", mlWarning)
  else:
    let s = ui.core.sessions[i]
    ui.reopen.open(s.path, ui.core.openChoiceOf(s.path), s.facts.opened, s.signature.kind)

proc onActions(ui: var Ui; actions: set[MenuAction]) =
  let recent = ui.core.settings.recentFolders
  let folder = if recent.len > 0: recent[0] & DirSep else: ""
  for a in actions:
    case a
    of maOpenFile: ui.askOpenFile()
    of maOpenFiles: ui.ask(dkOpenFiles, folder)
    of maOpenFolder: ui.ask(dkOpenFolder, folder)
    of maClose:
      let i = ui.core.shownFile(ui.core.findPanel(MainPanel))
      if i >= 0: ui.core.apply Command(kind: ckClose, file: ui.core.sessions[i].id)
    of maImportSurvey: ui.join.open()
    of maImportShotLog: ui.ask(dkShotLog, folder)
    of maClearSurvey: ui.clearSurvey.ask()
    of maReopen: ui.openReopen()
    of maOpenVib, maOpenDat: ui.core.apply Command(kind: ckOpenPair, panel: MainPanel)
    of maReloadVendors: ui.core.apply Command(kind: ckReloadVendors)
    of maAbout: ui.about.open()
    of maShortcuts:
      ui.shortcuts.open()
      ui.windows.shortcutsOpen = true
      igMarkIniSettingsDirty_Nil()
    of maUndo: ui.core.apply Command(kind: ckUndoEdit, panel: MainPanel)
    of maRedo: ui.core.apply Command(kind: ckRedoEdit, panel: MainPanel)
    of maSelectAll: ui.core.apply Command(kind: ckSelect, all: true, mode: smReplace)
    of maClearEdits: ui.core.apply Command(kind: ckClearEdits, panel: MainPanel)
    of maFileMemory:
      if ui.memory.shown: ui.memory.shown = false else: ui.memory.open()
    of maGenerateReference:
      ui.refs.openGenerate(ui.core.shownIntervalMs)
    of maReferenceArchive:
      if ui.refs.shown: ui.refs.shown = false
      else:
        ui.refs.open()
        ui.core.apply Command(kind: ckListReferences)
    of maFirstBreaks:
      let pk = ui.core.findPanel(MainPanel)
      if pk >= 0 and ui.core.panels[pk].layers.len > 0:
        var d = ui.core.panels[pk].layers[0].display
        d.firstBreaks = not d.firstBreaks
        ui.core.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    of maTemplateOnly:
      let pk = ui.core.findPanel(MainPanel)
      if pk >= 0 and ui.core.panels[pk].layers.len > 0:
        var f = ui.core.panels[pk].layers[0].filter
        f.templateOnly = not f.templateOnly
        ui.core.apply Command(kind: ckFilter, panel: MainPanel, filter: f)
    of maCompare:
      ui.core.apply Command(kind: ckCompareWindow, compareOpen: not ui.core.compareOpen)
    of maMissingTraces:
      ui.windows.bringForward(awMissing)
      ui.missing.requestScan()
    of maTraceQuality:
      ui.windows.bringForward(awQuality)
      ui.quality.requestScan()
    of maVibFolder:
      ui.windows.bringForward(awVibFolder)
      ui.vibfolder.requestList()
    of maOutput:
      ui.output.open($(ui.core.fileList.folder))
      ui.windows.bringForward(awOutput)
    of maNewProject:
      ui.project.startNew(projectsHome(), ui.core.fileList.folder)
    of maOpenProject:
      let last = ui.core.settings.recentProjects
      ui.ask(dkOpenProject, if last.len > 0: last[0].parentDir & DirSep else: projectsHome())
    of maProject:
      if ui.project.shown: ui.project.shown = false else: ui.project.open()
    of maCloseProject: ui.core.apply Command(kind: ckCloseProject)
    of maExportEdits:
      let i = ui.core.shownFile(ui.core.findPanel(MainPanel))
      if i < 0: ui.say("Export trace edits: no file is shown.", mlWarning)
      else:
        let s = ui.core.sessions[i]
        ui.ask(dkExportEdits, s.path.parentDir / s.path.splitFile.name & "-edits.csv")
    of maImportEdits:
      let i = ui.core.shownFile(ui.core.findPanel(MainPanel))
      if i < 0: ui.say("Import trace edits: no file is shown.", mlWarning)
      else: ui.ask(dkImportEdits, ui.core.sessions[i].path.parentDir & DirSep)
    of maQuit: ui.running = false
    of maToggleTheme: ui.toggleTheme()
    of maExportSettings:
      let dir = ui.core.settingsFile.parentDir
      ui.ask(dkExportSettings,
        (if dir.len > 0: dir / "viewSEG-settings.nif" else: "viewSEG-settings.nif"))
    of maImportSettings: ui.ask(dkImportSettings)
    of maSettings: ui.settingsWin.open()
    of maResetSettings: ui.core.apply Command(kind: ckResetSettings)
    of maSaveLayout: ui.askLayoutName = true
    of maResetWindows: ui.resetWindows()
    of maBringWindows: ui.bringWindows()
    of maExportLayout:
      let dir = ui.core.settingsFile.parentDir
      ui.ask(dkExportLayout,
        (if dir.len > 0: dir / "viewSEG-layout.nif" else: "viewSEG-layout.nif"))
    of maImportLayout: ui.ask(dkImportLayout)
    of maShowFiles: ui.windows.bringForward(awFiles)
    of maShowRecords: ui.windows.bringForward(awRecords)
    of maShowMap: ui.windows.bringForward(awMap)
    of maShowHeaders: ui.windows.bringForward(awHeaders)
    of maShowJobs: ui.windows.bringForward(awJobs)
    of maShowMessages: ui.windows.bringForward(awMessages)
    of maExportLog:
      let dir = ui.core.settingsFile.parentDir
      ui.ask(dkExportLog, (if dir.len > 0: dir / "viewSEG-messages.log"
        else: "viewSEG-messages.log"))

# ------------------------------------------------------------------- frame --

template mark(ui: var Ui; part: string; idle = false) =
  ## Starts the part of the frame named `part` for the watchdog; `idle` when
  ## the thread waits in it.
  when FrameWatchdogOn:
    ui.dog.phase(part, waiting = idle)

proc echoNewLog(ui: var Ui) =
  ## Echoes what was logged since the last call to stdout when it is a
  ## terminal (the session log file has everything anyway).
  if not ui.echoing:
    ui.echoed = ui.core.log.nextSerial
    return
  for e in ui.core.log.since(ui.echoed):
    try:
      stdout.writeLine (if e.severity == sevInfo: "" else: $levelOf(e.severity) & ": "), line(e)
    except IOError:
      discard # no usable stdout (a desktop start on Windows): the window has it all
  if ui.core.log.nextSerial != ui.echoed:
    try:
      stdout.flushFile()
    except IOError:
      discard
  ui.echoed = ui.core.log.nextSerial

proc buildLayout(ui: var Ui; dockId: ImGuiID; size: ImVec2_c) =
  ## The first layout: the file list at the left over the record list, the
  ## plot beside them with the messages (and the jobs) under it, the map on
  ## the right over the header table.
  igDockBuilderRemoveNode(dockId)
  discard igDockBuilderAddNode(dockId, ImGui_DockNodeFlags_DockSpace.cint)
  igDockBuilderSetNodeSize(dockId, size)
  var side, files, records, rest, left, right, top, bottom, map, table: ImGuiID
  discard igDockBuilderSplitNode(dockId, ImGuiDir_Left, 0.22, addr side, addr rest)
  discard igDockBuilderSplitNode(side, ImGui_Dir_Down, 0.4, addr records, addr files)
  discard igDockBuilderSplitNode(rest, ImGuiDir_Right, 0.34, addr right, addr left)
  discard igDockBuilderSplitNode(left, ImGui_Dir_Down, 0.3, addr bottom, addr top)
  discard igDockBuilderSplitNode(right, ImGui_Dir_Down, 0.35, addr table, addr map)
  igDockBuilderDockWindow(filesTitle, files)
  igDockBuilderDockWindow(recordsTitle, records)
  igDockBuilderDockWindow("###" & plotId, top)
  igDockBuilderDockWindow(SpectrumWindowTitle, map) # a tab behind the map
  igDockBuilderDockWindow("###" & mapId, map)
  igDockBuilderDockWindow(headersTitle, table)
  igDockBuilderDockWindow(jobsTitle, bottom)
  igDockBuilderDockWindow(messagesTitle, bottom) # the tab shown
  igDockBuilderFinish(dockId)
  ui.layoutDone = true
  igMarkIniSettingsDirty_Nil() # saved as the arrangement a moment later

proc drawDockSpace(ui: var Ui) =
  ## The dockspace over the rest of the main window, on the backdrop colour,
  ## with a gap around and between the panels (the splitters).
  let vp = igGetMainViewport()
  let backdrop = vec4(ui.theme.roles[rlBackdrop])
  let gap = igGetStyle().DockingSeparatorSize
  igSetNextWindowPos(vp.WorkPos, 0, ImVec2_c(x: 0, y: 0))
  igSetNextWindowSize(vp.WorkSize, 0)
  igSetNextWindowViewport(vp.ID)
  igPushStyleVar_Vec2(ImGui_StyleVar_WindowPadding.cint, ImVec2_c(x: gap, y: gap))
  igPushStyleVar_Float(ImGui_StyleVar_WindowBorderSize.cint, 0)
  igPushStyleColor_Vec4(ImGui_Col_WindowBg.cint, backdrop)
  const hostFlags = ImGui_WindowFlags_NoDecoration.cint or ImGui_WindowFlags_NoDocking.cint or
    ImGui_WindowFlags_NoBringToFrontOnFocus.cint or ImGui_WindowFlags_NoNavFocus.cint or
    ImGui_WindowFlags_NoSavedSettings.cint or ImGui_WindowFlags_NoMove.cint
  discard igBegin("##dockhost", nil, hostFlags)
  igPopStyleColor(1)
  igPopStyleVar(2)
  let dockId = igGetID_Str("viewSEG.dockspace")
  ui.windows.dockspace = dockId
  if not ui.layoutDone:
    ui.buildLayout(dockId, igGetContentRegionAvail())
  igPushStyleColor_Vec4(ImGui_Col_Border.cint, backdrop) # ImGui draws splitters in it
  discard igDockSpace(dockId, ImVec2_c(x: 0, y: 0), 0, nil)
  igPopStyleColor(1)
  igEnd()

proc drawSaveLayout(ui: var Ui) =
  ## The "Save layout" popup: a name, then Save.
  const id = "Save layout##savelayout"
  if ui.askLayoutName:
    igOpenPopup_Str(id, 0)
    ui.askLayoutName = false
  centreModal(id)
  if igBeginPopupModal(id, nil, ImGui_WindowFlags_AlwaysAutoResize.cint):
    ui.marks.markWindow("save layout")
    igTextUnformatted("A name for the arrangement on screen:", nil)
    if igIsWindowAppearing(): igSetKeyboardFocusHere(0)
    igSetNextItemWidth(igGetFontSize() * 18)
    let entered = igInputText("##name", cast[cstring](addr ui.layoutName[0]),
      csize_t(ui.layoutName.len), ImGui_InputTextFlags_EnterReturnsTrue.cint, nil, nil)
    ui.marks.mark("save layout.name")
    let name = $cast[cstring](addr ui.layoutName[0])
    let why = layoutNameProblem(name)
    if why.len > 0 and name.len > 0:
      igTextColored(vec4(ui.theme.roles[rlWarning]), "%s", why.cstring)
    var taken = false
    for e in ui.core.layouts:
      if not e.preset and e.name.toLowerAscii == name.strip.toLowerAscii: taken = true
    if taken: igTextDisabled("A layout of this name is replaced.")
    igBeginDisabled(why.len > 0)
    if (igButton("Save", ImVec2_c(x: 0, y: 0)) or entered) and why.len == 0:
      ui.core.apply Command(kind: ckLayout, arrangement: $igSaveIniSettingsToMemory(nil))
      ui.core.apply Command(kind: ckSaveLayout, layoutName: name)
      igCloseCurrentPopup()
    igEndDisabled()
    ui.marks.mark("save layout.save")
    igSameLine(0, -1)
    if igButton("Cancel", ImVec2_c(x: 0, y: 0)) or igIsKeyPressed_Bool(ImGui_Key_Escape, false):
      igCloseCurrentPopup()
    igEndPopup()

proc drop(paths: var seq[string]; core: var AppState) =
  ## Opens what was dropped on the window: one file is shown with its folder
  ## listed; a folder, or several files, are listed and the first seismic
  ## file is shown; survey files dropped are loaded into the survey.
  if paths.len > 0:
    core.apply Command(kind: ckBrowse, paths: paths, showFirst: true)
    paths.setLen 0

proc drawDropHint(ui: Ui) =
  ## While files are dragged over the window: a frame and a line saying
  ## what dropping them does.
  if ui.dropAt <= 0 or igGetTime() - ui.dropAt > 0.5: return
  let vp = igGetMainViewport()
  let dl = igGetForegroundDrawList_ViewportPtr(vp)
  let a = vp.WorkPos
  let b = ImVec2_c(x: vp.WorkPos.x + vp.WorkSize.x, y: vp.WorkPos.y + vp.WorkSize.y)
  ImDrawList_AddRectFilled(dl, a, b, u32(withAlpha(ui.theme.roles[rlAccent], 40)), 0, 0)
  ImDrawList_AddRect(dl, a, b, u32(ui.theme.roles[rlAccent]), 0, 4, 0) # 4 pixels thick
  let text = "Drop to open: a folder lists its files; a seismic file is shown, its folder " &
    "listed; survey files (SPS, P1) are loaded into the survey"
  let ts = igCalcTextSize(text.cstring, nil, false, -1)
  let at = ImVec2_c(x: a.x + (vp.WorkSize.x - ts.x) / 2, y: a.y + (vp.WorkSize.y - ts.y) / 2)
  let pad = igGetStyle().FramePadding
  ImDrawList_AddRectFilled(dl, ImVec2_c(x: at.x - 2 * pad.x, y: at.y - 2 * pad.y),
    ImVec2_c(x: at.x + ts.x + 2 * pad.x, y: at.y + ts.y + 2 * pad.y),
    u32(ui.theme.roles[rlPopup]), igGetStyle().FrameRounding, 0)
  ImDrawList_AddText_Vec2(dl, at, u32(ui.theme.roles[rlText]), text.cstring, nil)

proc drawNotices(ui: var Ui) =
  ## The notices of background jobs that ended, each for `noticeSeconds`, in
  ## the main window's bottom-right corner over the status bar; a click
  ## brings the Jobs window forward.
  for n in ui.core.notices:
    if n.serial >= ui.noticed:
      ui.shownNotices.add (n, igGetTime())
      ui.noticed = n.serial + 1
  var kept: seq[(Notice, float64)]
  for x in ui.shownNotices:
    if igGetTime() - x[1] < noticeSeconds: kept.add x
  ui.shownNotices = kept
  if kept.len == 0: return
  let vp = igGetMainViewport()
  let pad = igGetStyle().WindowPadding
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + vp.WorkSize.x - pad.x,
    y: vp.WorkPos.y + vp.WorkSize.y - pad.y), ImGui_Cond_Always.cint, ImVec2_c(x: 1, y: 1))
  igSetNextWindowViewport(vp.ID)
  igPushStyleColor_Vec4(ImGui_Col_WindowBg.cint, vec4(ui.theme.roles[rlPopup]))
  const flags = ImGui_WindowFlags_NoDecoration.cint or ImGui_WindowFlags_AlwaysAutoResize.cint or
    ImGui_WindowFlags_NoSavedSettings.cint or ImGui_WindowFlags_NoFocusOnAppearing.cint or
    ImGui_WindowFlags_NoNav.cint or ImGui_WindowFlags_NoDocking.cint
  if igBegin("##notices", nil, flags):
    ui.marks.markWindow("notice")
    for (n, _) in kept:
      let level = levelOf(n.severity)
      let icon = if level == mlError: IconError else: IconCheck
      let colour = if level == mlError: ui.theme.roles[rlError] else: ui.theme.roles[rlInfo]
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour))
      igTextUnformatted(icon.cstring, nil)
      igPopStyleColor(1)
      igSameLine(0, -1)
      igTextUnformatted(n.text.cstring, nil)
    if igIsWindowHovered(0) and igIsMouseClicked_Bool(ImGui_MouseButton_Left.cint, false):
      ui.windows.bringForward(awJobs)
      ui.shownNotices.setLen 0
  igEnd()
  igPopStyleColor(1)

func shownSignatureFile(st: AppState): int =
  ## The session of the vibrator signature file the Seismic window shows; -1 for none.
  let i = st.shownFile(st.findPanel(MainPanel))
  if i >= 0 and st.sessions[i].isSignature: i else: -1

func signatureWord(st: AppState): string =
  ## "dat" or "vib" for a signature file shown; "" for any other.
  let i = st.shownSignatureFile
  if i < 0: "" elif st.sessions[i].signature.kind == sgDat: "dat" else: "vib"

func pairNameOf(st: AppState): string =
  ## The other file of the sweep shown, by name; "" when unknown.
  let i = st.shownSignatureFile
  if i >= 0: st.partnerOf(st.sessions[i].path).extractFilename else: ""

const auxId = "aux" ## the Aux window's ImGui ID: "###aux"

proc drawAux(ui: var Ui) =
  ## The Aux window: its open state is kept in step with the core's (`ckAuxWindow`: what the
  ## View > Windows tick, or an agent, changed), then its plot is drawn, with its marks named
  ## "aux.<what>" and its pointer reading and commands taken as the Seismic window's.
  let open = ui.core.auxOpen
  if open != ui.auxSeen:
    ui.auxSeen = open # the core changed it (an agent): the window follows
    if open: ui.windows.bringForward(awAux) else: ui.windows.hide(awAux)
  elif ui.windows.shows(awAux) != open:
    ui.core.apply Command(kind: ckAuxWindow, onScreen: ui.windows.shows(awAux))
    ui.auxSeen = ui.core.auxOpen
  let k = ui.core.auxIndex
  if not ui.windows.shows(awAux) or k < 0: return
  ui.windows.beforeDrawing(awAux)
  let before = ui.marks.len
  var aux = ui.auxTrace.drawTracePanel(auxId, ui.core, ui.core.panels[k].id, ui.theme,
    ui.fonts, ui.marks)
  for i in before ..< ui.marks.len:
    if ui.marks[i][0].startsWith("plot."): ui.marks[i][0] = "aux." & ui.marks[i][0].substr(5)
  if aux.pick.found or aux.pick.inside:
    ui.pick = aux.pick
    if ui.pick.found and ui.pick.trace >= 0:
      let shown = ui.core.shownFile(ui.core.findPanel(MainPanel))
      if shown >= 0:
        let (has, f) = ui.core.ownAt(ui.core.sessions[shown].path, ui.pick.trace)
        if has: ui.pick.filterNote = filterWords(f)
        let ms = ui.core.shownShift(ui.core.sessions[shown].base + ui.pick.trace)
        if ms != 0.0: ui.pick.shiftNote = shiftWords(ms)
  for n in aux.notes:
    ui.say(n, mlWarning)
  for c in aux.commands.mitems:
    ui.core.apply move c

proc drawUi(ui: var Ui): set[MenuAction] =
  ui.marks.setLen 0
  let shownAt = ui.core.shownFile(ui.core.findPanel(MainPanel))
  template e: untyped = ui.core.editsOf(ui.core.findPanel(MainPanel))
  let menuInput = MenuInput(undo: e.undoText, redo: e.redoText,
    edited: not e.isEmpty, editedName: (if shownAt >= 0: ui.core.sessions[shownAt].name
    else: ""), memoryShown: ui.memory.shown, themes: ui.themes, theme: ui.selected,
    follows: DefaultThemeNames[resolveTheme(ui.choice, ui.system)],
    recent: ui.core.settings.recentFiles, recentFolders: ui.core.settings.recentFolders,
    canClose: ui.core.shownFile(ui.core.findPanel(MainPanel)) >= 0, layouts: ui.core.layouts,
    signature: signatureWord(ui.core), pairName: pairNameOf(ui.core),
    keepsLayouts: ui.keepsLayouts, followLatest: ui.core.settings.files.followLatest,
    agentOn: ui.agent.running, agentSocket: ui.agentSocket,
    prepareNext: ui.core.settings.files.prepareNext,
    shown: {AppWindow.low .. AppWindow.high} - ui.windows.hidden,
    seismicName: ui.core.windowTitle(MainPanel), joinShown: ui.join.shown,
    shotLogShown: ui.shotLog.shown,
    surveyImported: ui.core.surveyInEffect,
    trayIcon: ui.core.settings.tray.icon, trayMinimize: ui.core.settings.tray.minimize,
    trayProblem: ui.trayProblem, trayAvailable: trayShown(),
    canPlot: ui.core.plotsCanOpen(MainPanel), plotTraces: ui.core.selectedIn(shownAt),
        recentProjects: ui.core.settings.recentProjects,
    projectName: (if ui.core.inProject: ui.core.project.doc.name else: ""),
    vendorMaps: ui.core.vendorLoad.maps.mapIt(it.name),
    vendorChoice: ui.core.vendorChoice.choiceWords,
    projectShown: ui.project.shown, archiveShown: ui.refs.shown,
    compareShown: ui.core.compareOpen, firstBreaksOn: ui.core.breaksOn(MainPanel),
    templateOnlyOn: ui.core.templateView(ui.core.findPanel(MainPanel)).on,
    templateAvailable: ui.core.templateView(ui.core.findPanel(MainPanel)).available,
    missingReady: missingReady(ui.core.fileList.folder.len > 0, ui.core.relationLayer >= 0),
    missingWhy: missingWhy(ui.core.fileList.folder.len > 0, ui.core.relationLayer >= 0),
    qualityReady: qualityReady(ui.core.fileList.folder.len > 0),
    qualityWhy: qualityWhy(ui.core.fileList.folder.len > 0),
    folderReady: folderReady(ui.core.fileList.folder.len > 0),
    folderWhy: folderWhy(ui.core.fileList.folder.len > 0),
    outputReady: ui.core.fileList.folder.len > 0,
    outputWhy: if ui.core.fileList.folder.len > 0: "" else: OutputNeedFolder)
  let menu = drawMainMenu(menuInput, ui.marks)
  if menu.newPlot:
    ui.core.apply Command(kind: ckOpenPlot, plotOf: MainPanel, plotView: menu.newPlotView)
  if menu.openProject.len > 0:
    ui.core.apply Command(kind: ckOpenProject, projectPath: menu.openProject)
  if menu.vendorMap.len > 0:
    ui.core.apply Command(kind: ckVendorMap, vendorMap: menu.vendorMap)
  if menu.toggleAgent: ui.toggleAgent()
  if menu.toggleTrayIcon or menu.toggleTrayMinimize:
    var s = ui.core.settings
    if menu.toggleTrayIcon: s.tray.icon = not s.tray.icon
    if menu.toggleTrayMinimize: s.tray.minimize = not s.tray.minimize
    ui.core.apply Command(kind: ckSettings, settings: s)
  for w in menu.pickedWindows:
    if w == awMissing and ui.windows.willShow(w): ui.missing.requestScan()
    if w == awQuality and ui.windows.willShow(w): ui.quality.requestScan()
    if w == awVibFolder and ui.windows.willShow(w): ui.vibfolder.requestList()
    ui.windows.picked(w)
  if menu.toggleJoin:
    if ui.join.shown: ui.join.shown = false else: ui.join.open()
  if menu.toggleShotLog:
    if ui.shotLog.shown: ui.shotLog.shown = false else: ui.shotLog.open()
  if menu.loadLayout.len > 0:
    ui.core.apply Command(kind: ckLoadLayout, docPath: menu.loadLayout)
  result = menu.actions
  if menu.pickedTheme and menu.theme != ui.selected:
    ui.chooseTheme(menu.theme) # the settings' theme
    # Applied between frames (fonts and styles change), also when the
    # settings named it already (a theme given at start by name).
    ui.pendingTheme = some(menu.theme)
  # Resting on an entry previews it until the submenu closes; a pick of
  # another theme replaces it (`setTheme`), any other pick goes back.
  if menu.pickedTheme:
    ui.previewKept = menu.theme != ui.selected
    ui.previewWanted = none(string)
  elif not menu.themeMenu.open:
    ui.previewWanted = none(string)
  elif menu.themeMenu.rests:
    ui.previewWanted = some(menu.themeMenu.rested)
  if menu.openRecent.len > 0:
    ui.core.apply Command(kind: ckShowFile, panel: MainPanel, path: menu.openRecent,
      listFolder: true)
  if menu.browseRecent.len > 0:
    ui.core.apply Command(kind: ckBrowse, paths: @[menu.browseRecent], showFirst: true)
  if menu.clearRecent:
    var s = ui.core.settings
    s.recentFiles.setLen 0
    s.recentFolders.setLen 0
    ui.core.apply Command(kind: ckSettings, settings: s)
  let p = ui.core.project
  let bar = drawToolbar(ui.theme, ui.marks, menuInput, ProjectBar(
    open: ui.core.inProject, name: p.doc.name, path: p.dir, readOnly: p.readOnly,
    dataFolders: p.doc.data.len, surveyFiles: p.doc.survey.len))
  result.incl bar.actions
  if bar.openProject.len > 0:
    ui.core.apply Command(kind: ckOpenProject, projectPath: bar.openProject)
  if bar.vendorMap.len > 0:
    ui.core.apply Command(kind: ckVendorMap, vendorMap: bar.vendorMap)
  if bar.fft:
    ui.core.apply Command(kind: ckSpectrum, spectrumOf: MainPanel,
      spectrumShow: ui.core.settings.spectrum.window)
  if bar.plot:
    ui.core.apply Command(kind: ckOpenPlot, plotOf: MainPanel, plotView: bar.plotView)
  let job = jobStatus(ui.core.jobs.active, getMonoTime(), fs.now())
  # The readout is last frame's pick: the bar is drawn before the plot.
  let status = drawStatusBar(ui.fonts, ui.theme,
    ChromeInfo(themeName: ui.theme.name, scale: ui.scale, agent: AgentSign(
      on: ui.agent.running, clients: ui.agent.clients, names: ui.agent.clientNames,
      socket: ui.agent.path, lastCall: ui.agent.lastCall,
      lingering: ui.agent.clients == 0 and ui.agent.lingers(getMonoTime()))), job,
    ui.core.settings.readout, ui.pick, ui.marks, ui.mapCursor,
    if ui.core.hoverNote.len > 0: ui.core.hoverNote else: ui.core.correlateNote,
    if ui.core.profileNoted: ProfileStored else: "")
  if status.cancel != NoJob:
    ui.core.apply Command(kind: ckCancelJob, job: status.cancel)
  if status.showJobs: ui.windows.bringForward(awJobs)
  if status.chose:
    var s = ui.core.settings
    s.readout = status.fields
    ui.core.apply Command(kind: ckSettings, settings: s)
  ui.drawDockSpace()
  # Each window is drawn when it is shown (the Window menu), after it is
  # brought forward or placed as asked (`beforeDrawing`).
  ui.windows.beforeDrawing(awSeismic) # always shown
  var plot = ui.trace.drawTracePanel(plotId, ui.core, MainPanel, ui.theme, ui.fonts,
    ui.marks)
  result.incl plot.actions
  ui.pick = plot.pick
  if ui.pick.found and ui.pick.trace >= 0:
    let shown = ui.core.shownFile(ui.core.findPanel(MainPanel))
    if shown >= 0:
      let (has, f) = ui.core.ownAt(ui.core.sessions[shown].path, ui.pick.trace)
      if has: ui.pick.filterNote = filterWords(f)
      let ms = ui.core.shownShift(ui.core.sessions[shown].base + ui.pick.trace)
      if ms != 0.0: ui.pick.shiftNote = shiftWords(ms)
  for n in plot.notes:
    ui.say(n, mlWarning)
  for c in plot.commands.mitems:
    ui.core.apply move c
  ui.drawAux()
  var files = FileListOutput()
  if ui.windows.shows(awFiles):
    ui.windows.beforeDrawing(awFiles)
    files = ui.files.drawFileList(filesTitle, ui.core, ui.theme, ui.marks)
  result.incl files.actions
  if menu.togglePrepare:
    var s = ui.core.settings
    s.files.prepareNext = not s.files.prepareNext
    ui.core.apply Command(kind: ckSettings, settings: s)
  if files.toggleSignatures:
    var s = ui.core.settings
    s.files.listSignatureFiles = not s.files.listSignatureFiles
    ui.core.apply Command(kind: ckSettings, settings: s)
  if plot.stepFile != 0:
    # Page Down after a signature file's last record, Page Up before its first: the Files
    # window's next or previous file, in its order and filters
    let next = ui.files.steppedFile(ui.core, plot.stepFile)
    if next.len > 0:
      ui.core.apply Command(kind: ckShowFile, panel: MainPanel, path: next)
  if files.toggleFollow or menu.toggleFollow:
    var s = ui.core.settings
    s.files.followLatest = not s.files.followLatest
    ui.core.apply Command(kind: ckSettings, settings: s)
  for c in files.commands.mitems:
    ui.core.apply move c
  if ui.windows.shows(awRecords):
    ui.windows.beforeDrawing(awRecords)
    var records = ui.records.drawRecordList(recordsTitle, ui.core, MainPanel, ui.theme,
      ui.marks)
    for c in records.commands.mitems:
      ui.core.apply move c
  if ui.windows.shows(awMissing):
    ui.windows.beforeDrawing(awMissing)
    var missing = ui.missing.drawMissing(missingTitle, ui.core, ui.marks)
    for c in missing.commands.mitems:
      ui.core.apply move c
    if missing.exportAsked: ui.ask(dkExportMissing, missing.exportPath)
  if ui.windows.shows(awQuality):
    ui.windows.beforeDrawing(awQuality)
    var quality = ui.quality.drawQuality(qualityTitle, ui.core, ui.marks)
    for c in quality.commands.mitems:
      ui.core.apply move c
    if quality.exportAsked: ui.ask(dkExportQuality, quality.exportPath)
  if ui.windows.shows(awVibFolder):
    ui.windows.beforeDrawing(awVibFolder)
    var folderQc = ui.vibfolder.drawVibFolder(vibfolderTitle, ui.core, ui.marks)
    for c in folderQc.commands.mitems:
      ui.core.apply move c
    if folderQc.exportAsked: ui.ask(dkExportVibFolder, folderQc.exportPath)
  if ui.windows.shows(awOutput):
    ui.windows.beforeDrawing(awOutput)
    var written = ui.output.drawOutput(outputTitle, ui.core, ui.marks)
    for c in written.commands.mitems:
      ui.core.apply move c
    if written.askSource: ui.ask(dkOutputSource, written.askAt)
    if written.askDest: ui.ask(dkOutputDest, written.askAt)
  if ui.windows.shows(awHeaders):
    ui.windows.beforeDrawing(awHeaders)
    # The pick is this frame's: the plot is drawn first.
    var headers = ui.headers.drawHeaders(headersTitle, ui.core,
      (if ui.pick.inside: ui.pick.at.tMs else: NaN), ui.pick.inside, ui.fonts, ui.theme,
      ui.marks)
    for c in headers.commands.mitems:
      ui.core.apply move c
    if headers.reopen: ui.openReopen()
    if headers.openPair: ui.core.apply Command(kind: ckOpenPair, panel: MainPanel)
  ui.mapCursor = ""
  if ui.windows.shows(awMap):
    # A layout saved before the map came names no map: it joins the Headers
    # window's place (`beforeDrawing`, as any window a layout does not know).
    ui.windows.beforeDrawing(awMap)
    var map = ui.map.drawMap(mapId, ui.core, ui.theme, ui.marks)
    ui.mapCursor = map.cursor
    for c in map.commands.mitems:
      ui.core.apply move c
  # The live spectrum panel (it works only while on screen) and the FFT windows.
  if ui.windows.shows(awSpectrum): ui.windows.beforeDrawing(awSpectrum)
  var spectra = SpectraOutput()
  ui.spectra.drawLive(ui.core, ui.windows.shows(awSpectrum), ui.theme, ui.marks, spectra)
  ui.spectra.drawFfts(ui.core, ui.theme, ui.scale, ui.marks, spectra)
  var plotWins = PlotWindowsOutput()
  ui.plotWins.drawPlotWindows(ui.core, ui.theme, ui.scale, ui.marks, plotWins)
  for n in plotWins.notes: ui.say(n, mlWarning)
  for c in plotWins.commands.mitems:
    ui.core.apply move c
  if plotWins.openReferences:
    ui.refs.open()
    ui.core.apply Command(kind: ckListReferences)
  if spectra.bringForward: ui.windows.bringForward(awSpectrum)
  for c in spectra.commands.mitems:
    ui.core.apply move c
  var join = ui.join.drawJoin(joinTitle, ui.core, ui.theme, ui.marks)
  for c in join.commands.mitems:
    ui.core.apply move c
  var shotLog = ui.shotLog.drawShotLog(shotLogTitle, ui.core, ui.theme, ui.marks)
  for c in shotLog.mitems:
    ui.core.apply move c
  var memory = ui.memory.drawMemory(memoryTitle, ui.core, ui.theme, ui.marks)
  for c in memory.commands.mitems:
    ui.core.apply move c
  let refsTitle = IconReference & "  Reference archive (" & referenceArchiveTitle(ui.core) &
    ")###refs"
  var refs = ui.refs.drawReferences(refsTitle, ui.core, ui.theme, ui.marks)
  for c in refs.commands.mitems:
    ui.core.apply move c
  for c in ui.refs.drawRefViews(ui.core, ui.theme, ui.scale, ui.marks):
    ui.core.apply c
  for c in ui.compare.drawCompare(ui.core, ui.theme, ui.scale, ui.marks):
    ui.core.apply c
  var project = ui.project.drawProjectWindows(projectTitle, newProjectTitle, ui.core, ui.theme,
    ui.marks)
  for c in project.commands.mitems:
    ui.core.apply move c
  case project.ask
  of paNone: discard
  of paPlace: ui.ask(dkProjectPlace, project.askAt)
  of paData: ui.ask(dkProjectData, project.askAt)
  of paLocate: ui.ask(dkLocateFolder, project.askAt)
  if join.clearSurvey: ui.clearSurvey.ask(joinTitle)
  if project.clearSurvey: ui.clearSurvey.ask(projectTitle)
  for c in ui.clearSurvey.drawClearSurvey(ui.marks):
    ui.core.apply c
  if join.addFiles:
    let i = ui.core.shownFile(ui.core.findPanel(MainPanel))
    let folder = if i >= 0: ui.core.sessions[i].path.parentDir & DirSep else: ""
    ui.ask(dkJoinFiles, folder)
  var reopen = ui.reopen.drawReopen(ui.theme, ui.marks)
  for c in reopen.mitems:
    ui.core.apply move c
  ui.about.drawAbout(ui.theme, ui.marks)
  if ui.windows.shortcutsOpen and not ui.shortcuts.shown:
    ui.shortcuts.shown = true
  ui.shortcuts.drawShortcuts(ui.theme, ui.marks)
  var settingsCmds = ui.settingsWin.drawSettingsWindow(ui.core, ui.theme, ui.marks)
  for c in settingsCmds.mitems:
    ui.core.apply move c
  if ui.shortcuts.shown != ui.windows.shortcutsOpen:
    ui.windows.shortcutsOpen = ui.shortcuts.shown
    igMarkIniSettingsDirty_Nil()
  ui.drawSaveLayout()
  ui.drawDropHint()
  if ui.windows.shows(awJobs):
    ui.windows.beforeDrawing(awJobs)
    var jobs = drawJobs(jobsTitle, ui.core, ui.theme, ui.marks)
    for c in jobs.commands.mitems:
      ui.core.apply move c
  if ui.windows.shows(awMessages):
    ui.windows.beforeDrawing(awMessages)
    let log = ui.logView.draw(ui.core.log, messagesTitle, ui.theme, ui.core.settings.messages,
      ui.marks)
    if log.changed:
      var s = ui.core.settings
      s.messages = log.view
      ui.core.apply Command(kind: ckSettings, settings: s)
    if log.exportLog: result.incl maExportLog
    if log.showPath.len > 0:
      ui.core.apply Command(kind: ckShowTrace, panel: MainPanel, path: log.showPath,
        traceIndex: log.showTrace, recordIndex: log.showRecord)
  ui.drawNotices()
  when defined(imguiDemo):
    igShowDemoWindow(nil)
    ImPlot_ShowDemoWindow(nil)

func hint(step: StartupStep): string =
  case step
  of ssVideo:
    "No display was found, or SDL has no video driver for it."
  of ssWindow:
    "The display did not accept a new window."
  of ssGlContext, ssGlFunctions:
    "viewSEG needs OpenGL 3.3. The graphics driver may be missing or too old: " &
      "update it, or use a computer whose graphics support OpenGL 3.3."
  of ssImguiSdl, ssImguiGl:
    "The graphics driver did not accept the display code."

func failureText*(step: StartupStep; reason, logFile: string): string =
  ## The message a start-up failure shows: what failed, the library's words,
  ## a hint, and where the details are kept.
  result = "viewSEG cannot start: it could not " & $step & "."
  if reason.len > 0:
    result.add "\n\n" & reason
  result.add "\n\n" & hint(step)
  if logFile.len > 0:
    result.add "\n\nThis message is saved in " & logFile

proc writeFailureLog(dir, text: string): string =
  ## Writes `text`, dated, to `dir/startup-failure.log`; the file's path, or ""
  ## when it cannot be written.
  result = dir / failureLogName
  try:
    createDir(dir)
    writeFile(result, now().format("yyyy-MM-dd HH:mm:ss") & "\n" & text & "\n")
  except OSError, IOError:
    result = ""

proc toStderr(text: string) =
  ## Writes `text` as a line on stderr if it can. A failed write raises, and a
  ## program started from the desktop (on Windows, say) may have no usable
  ## stderr.
  try:
    stderr.writeLine "viewSEG: ", text
  except IOError:
    discard

proc fail(opts: RunOptions; step: StartupStep; reason: string): int =
  ## Reports a failed start-up step everywhere the user may look; returns the
  ## exit code, 1.
  let dir = if opts.logDir.isSome: opts.logDir.get
            else: currentContext().logDir
  var f = StartupFailure(step: step, reason: reason)
  f.logFile = writeFailureLog(dir, failureText(step, reason, dir / failureLogName))
  f.text = failureText(step, reason, f.logFile)
  toStderr f.text.replace("\n\n", "\n  ")
  if opts.onFailure != nil:
    opts.onFailure(f)
  elif not SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "viewSEG cannot start",
      f.text.cstring, nil):
    toStderr "no message box either: " & $SDL_GetError()
  1

proc sdlError(): string = $SDL_GetError()

proc shoot(ui: var Ui; target: string): Shot =
  ## The pixels of `target` (`ShotTargets`) as this frame drew it, for agent
  ## control: the plot's own image, or a part of the frame's back buffer.
  ## Read back only: agent control's thread scales and encodes them.
  var pixels: seq[Rgba]
  var w, h = 0
  if target in ["plot", "aux plot"]:
    # The image is the plot's last: not what the window shows when it shows
    # no plot now (every trace hidden, a gather being read, behind a tab).
    let aux = target == "aux plot"
    let window = if aux: "Aux" else: "Seismic"
    template tp: untyped = (if aux: ui.auxTrace else: ui.trace)
    if tp.plotShown: (pixels, w, h) = tp.plotImage
    if tp.plotShown and (w <= 1 or h <= 1):
      return Shot(error: "the " & window & " window leaves its plot no room (" & $w & " x " &
        $h & " pixels): make the window larger")
    if w <= 0 or h <= 0:
      let why = tp.instead
      return Shot(error: "the " & window & " window shows no picture of traces now" &
        (if why.len > 0: ": it says \"" & why & "\"" else: ""))
  else:
    var fw, fh: cint
    discard SDL_GetWindowSizeInPixels(ui.window, addr fw, addr fh)
    var r = Rect(pos: vec2(0, 0), size: vec2(fw.float32, fh.float32))
    if target != "window":
      var name = if target == "seismic": ui.core.windowTitle(MainPanel).toLowerAscii
                 else: target
      if target == "fft": # the FFT window opened last
        name = ""
        if ui.core.spectra.len > 1: name = "fft " & $ui.core.spectra[^1].id
      r = Rect()
      for (n, m) in ui.marks:
        if n == name: r = m
      if r.size.x < 1 or r.size.y < 1:
        return Shot(error: "the " & target & " window is not on screen (closed, behind " &
          "another tab, or in a window of its own)")
      if name.startsWith("new plot "):
        # a picture of the frame holds what is in front of the window, not it
        var id = 0
        try: id = parseInt(name["new plot ".len .. ^1])
        except ValueError: discard
        var all: seq[int] = @[]
        for w in ui.core.plots: all.add w.id
        let cover = ui.plotWins.coveredBy(id, r, all)
        if cover.len > 0:
          return Shot(error: name & " is covered by another window (" & cover & "): it " &
            "is being brought forward, ask again")
    let x0 = clamp(int(r.pos.x), 0, fw.int)
    let y0 = clamp(int(r.pos.y), 0, fh.int)
    w = clamp(int(r.pos.x + r.size.x), 0, fw.int) - x0
    h = clamp(int(r.pos.y + r.size.y), 0, fh.int) - y0
    if w <= 0 or h <= 0:
      return Shot(error: "the " & target & " window is outside the main window")
    pixels = readRegion(fh.int, x0, y0, w, h)
  Shot(pixels: move pixels, width: w, height: h)

proc screenshot*(frame: FrameInfo; target: string): Shot =
  ## What an agent's screenshot of `target` gets, as this frame drew it (tests).
  frame.ui[].shoot(target)

proc frontendOf(ui: ptr Ui; minimized: bool): Frontend =
  ## What agent control may ask of this frontend: the main window's
  ## pictures (none while minimized), the main plot's drawn view, and views
  ## shown in the plot and the map as the user's pan or zoom would.
  result.drawnView = proc (panel: PanelId; view: var Viewport): bool =
    result = panel == MainPanel
    if result: view = ui.trace.drawnView
    else:
      let a = ui.core.auxIndex
      result = a >= 0 and ui.core.panels[a].id == panel
      if result: view = ui.auxTrace.drawnView
  result.plotAxes = proc (id: string): PlotAxes =
    let (x, y) = curveplotui.axisLimitsOf(id)
    let (zx, zy) = curveplotui.axisZoomedOf(id)
    PlotAxes(xLo: x.lo, xHi: x.hi, yLo: y.lo, yHi: y.hi, xZoomed: zx, yZoomed: zy)
  result.showView = proc (panel: PanelId; view: Viewport): bool =
    result = panel == MainPanel
    if result: ui.trace.show(view)
    else:
      let a = ui.core.auxIndex
      result = a >= 0 and ui.core.panels[a].id == panel
      if result: ui.auxTrace.show(view)
  result.showMapView = proc (view: MapView): bool =
    ui.map.show(view)
    true
  if minimized:
    result.shoot = proc (target: string): Shot =
      Shot(error: "the window is minimized")
  else:
    result.shoot = proc (target: string): Shot = ui[].shoot(target)

proc frontend*(frame: FrameInfo): Frontend =
  ## What agent control gets of this frontend, as this frame drew it (tests).
  frontendOf(frame.ui, false)

proc glProc(name: cstring): pointer {.cdecl, gcsafe, raises: [].} =
  ## The GL loader the GPU layer uses.
  cast[pointer](SDL_GL_GetProcAddress(name))

func simulating(opts: RunOptions; steps: set[StartupStep]): RunOptions =
  ## `opts` with `steps` failing without being tried (tests import this module
  ## with `{.all.}`).
  result = opts
  result.simulate = steps

type
  MainPlace = object
    ## Where the main window was opened, and what was corrected.
    window: ptr SDL_Window
    moved: bool  ## not where the settings say: to be saved as it is now
    note: string ## what was corrected, for the log; "" for nothing
    severity: Severity

proc createMainWindow(size: (int, int); placed: WindowPlacement; reset: bool): MainPlace =
  ## The main window: `size` (pixels at 100 %) when given; else where and as
  ## large as it was (`placed`) when a screen still holds its top edge (made
  ## to fit the screen it is on when no screen is that large); else, and
  ## with `reset` (`--reset-windows`), at the default size in the middle of
  ## the primary screen; at the default size where the desktop puts it when
  ## it was never saved, maximized when the primary screen is too small for
  ## it (`startsMaximized`).
  const flags = SDL_WINDOW_OPENGL or SDL_WINDOW_RESIZABLE or SDL_WINDOW_HIGH_PIXEL_DENSITY
  result = MainPlace(severity: sevInfo)
  let (screens, primary) = screensNow()
  let home = if primary >= 0: screens[primary] elif screens.len > 0: screens[0] else: Rect()
  let wanted = if size[0] > 0 and size[1] > 0: size else: defaultSize
  let (w, h) = scaledWindowSize(wanted, primaryDisplayScale(), (int(home.size.x),
    int(home.size.y)))
  var at = Rect()
  if size[0] <= 0 and (reset or placed.width > 0):
    let saved = rect(placed.x, placed.y, placed.width, placed.height)
    let (r, how) = if reset: (Rect(), spOffScreen) else: mainWindowAtStart(saved, screens)
    at = r
    if reset:
      result.note = "Started with --reset-windows: the windows are as at a first start " &
        "(every window shown and docked), and the main window is on the primary screen at " &
        "its default size; the other settings are as they were."
    elif how == spOffScreen:
      result.note = "The main window's saved place (" & $placed.x & ", " & $placed.y & ", " &
        $placed.width & " × " & $placed.height & ") is off every screen (on a monitor " &
        "that is not there now?): it opens on the primary screen at its default size."
      result.severity = sevWarning
    elif how == spShrunk:
      result.note = "The main window's saved size (" & $placed.width & " × " &
        $placed.height & ") is larger than any screen: it opens at " & $int(r.size.x) &
        " × " & $int(r.size.y) & " on the screen it was on."
      result.severity = sevWarning
    if at.size.x <= 0 and home.size.x > 0:
      at = vec2(float32(w), float32(h)).centredOn(home)
    result.moved = how != spKept or reset
  if at.size.x > 0:
    # Hidden until it is in place, so it does not jump.
    result.window = SDL_CreateWindow("viewSEG", cint(at.size.x), cint(at.size.y),
      flags or SDL_WINDOW_HIDDEN)
    if result.window != nil:
      discard SDL_SetWindowPosition(result.window, cint(at.pos.x), cint(at.pos.y))
      if placed.maximized and not result.moved: discard SDL_MaximizeWindow(result.window)
      discard SDL_ShowWindow(result.window)
  elif size[0] <= 0 and startsMaximized(wanted, primaryDisplayScale(),
      (int(home.size.x), int(home.size.y))):
    # A small screen (or a large scale): the whole of it, as Windows
    # programs open there; restored, the window is `w` x `h`.
    result.window = SDL_CreateWindow("viewSEG", w.cint, h.cint, flags or SDL_WINDOW_MAXIMIZED)
  else:
    result.window = SDL_CreateWindow("viewSEG", w.cint, h.cint, flags)

proc placement(ui: Ui): WindowPlacement =
  ## Where the main window is now: its place and size, kept from before
  ## while it is maximized or full screen.
  let flags = SDL_GetWindowFlags(ui.window)
  result = ui.core.settings.window
  result.maximized = (flags and SDL_WINDOW_MAXIMIZED) != 0
  if (flags and (SDL_WINDOW_MAXIMIZED or SDL_WINDOW_FULLSCREEN or SDL_WINDOW_MINIMIZED)) == 0:
    var x, y, w, h: cint
    if SDL_GetWindowPosition(ui.window, addr x, addr y) and
        SDL_GetWindowSize(ui.window, addr w, addr h) and w > 0 and h > 0:
      (result.x, result.y, result.width, result.height) = (x.int, y.int, w.int, h.int)

proc notePlacement(ui: var Ui) =
  ## Puts where the main window is now in the settings, if it moved.
  let p = ui.placement
  if p != ui.core.settings.window:
    var s = ui.core.settings
    s.window = p
    ui.core.apply Command(kind: ckSettings, settings: s)

const SavingShownAfter = initDuration(milliseconds = 150)
  ## a quit that waits this long for the disk says so in the window

proc savingFrame(ui: var Ui; window: ptr SDL_Window; opts: RunOptions; frame: int) =
  ## A frame of the quit while the settings are still being written (a slow
  ## disk): the window's backdrop and what it waits for, nothing to act on;
  ## the events are taken, so the desktop does not take the window for one
  ## that hangs. The test hook sees it as frame `frame`.
  var event: SDL_Event
  while SDL_PollEvent(addr event):
    discard ImGui_ImplSDL3_ProcessEvent(addr event)
  ImGui_Impl_OpenGL3_NewFrame()
  ImGui_ImplSDL3_NewFrame()
  igNewFrame()
  let vp = igGetMainViewport()
  igSetNextWindowPos(ImVec2_c(x: vp.Pos.x + vp.Size.x / 2, y: vp.Pos.y + vp.Size.y / 2),
    ImGui_Cond_Always.cint, ImVec2_c(x: 0.5, y: 0.5))
  const flags = ImGui_WindowFlags_NoDecoration.cint or ImGui_WindowFlags_NoMove.cint or
    ImGui_WindowFlags_NoSavedSettings.cint or ImGui_WindowFlags_NoInputs.cint or
    ImGui_WindowFlags_AlwaysAutoResize.cint or ImGui_WindowFlags_NoDocking.cint
  if igBegin("##saving", nil, flags):
    igTextUnformatted("Saving the settings and the window layout...", nil)
    ui.marks.markWindow("saving")
  igEnd()
  igRender()
  var w, h: cint
  discard SDL_GetWindowSizeInPixels(window, addr w, addr h)
  glViewport(0, 0, w, h)
  let bg = ui.theme.roles[rlBackdrop]
  glClearColor(bg.r.float32 / 255, bg.g.float32 / 255, bg.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  ImGui_Impl_OpenGL3_RenderDrawData(igGetDrawData())
  if opts.onFrame != nil:
    opts.onFrame(FrameInfo(index: frame, width: w.int, height: h.int, theme: ui.theme,
      scale: ui.scale, ui: addr ui))
  let (backupWindow, backupContext) = (SDL_GL_GetCurrentWindow(), SDL_GL_GetCurrentContext())
  igUpdatePlatformWindows()
  igRenderPlatformWindowsDefault(nil, nil)
  discard SDL_GL_MakeCurrent(backupWindow, backupContext)
  discard SDL_GL_SwapWindow(window)

proc noteLayout(ui: var Ui) =
  ## Tells `core` how the windows are arranged when Dear ImGui says it
  ## changed (it waits `IniSavingRate` after a change).
  let io = igGetIO_Nil()
  if io.WantSaveIniSettings:
    io.WantSaveIniSettings = false
    ui.core.apply Command(kind: ckLayout, arrangement: $igSaveIniSettingsToMemory(nil))

proc arrange(ui: var Ui; text: string) =
  ## Arranges the windows as Dear ImGui's layout `text` says (which are
  ## hidden too: `windows`); between frames. Text without the dockspace's
  ## arrangement leaves the default one to be built; a window it does not
  ## name is docked beside its neighbours, and after the next frame a
  ## window it puts off every screen is brought onto the main window's.
  igClearIniSettings()
  igLoadIniSettingsFromMemory(text.cstring, csize_t(text.len))
  ui.layoutDone = "[Docking]" in text and "DockSpace" in text
  ui.windows.arranged(text, ui.layoutDone)
  ui.checkPlaces = CheckFrames

proc followLayouts(ui: var Ui) =
  ## A layout `core` loaded (Window > a preset, Load, Import layout) is shown.
  if ui.core.layoutLoads != ui.layoutLoads:
    ui.layoutLoads = ui.core.layoutLoads
    ui.arrange(ui.core.loadedLayout.imgui)
  if ui.arrangeNext.isSome:
    ui.arrange(ui.arrangeNext.get)
    ui.arrangeNext = none(string)

proc defaultVendorFolders(ctx: PathContext; configDir: string): seq[VendorFolder] =
  ## The user's folder (`<configDir>/vendormaps`, there or not), then the
  ## program's and the environment's that exist.
  result = @[VendorFolder(dir: configDir / VendorFolderName, origin: voUser)]
  for (dir, source) in ctx.vendorMapSources:
    case source
    of vsUser: discard
    of vsProgram: result.add VendorFolder(dir: dir, origin: voProgram)
    of vsEnvironment: result.add VendorFolder(dir: dir, origin: voEnvironment)

proc initUi(window: ptr SDL_Window; opts: RunOptions; loaded: LoadedSettings;
    configDir: string): Ui =
  ## The frontend's state: where its assets are, which theme, the fonts; the
  ## settings `loaded` (from `configDir`, saved there when `opts.persist`).
  let ctx = currentContext()
  let assets = if opts.assetDirs.isSome: opts.assetDirs.get else: ctx.assetDirs
  let userThemes = if opts.userThemeDir.isSome: opts.userThemeDir.get
                   else: ctx.configDir / "themes"
  let env = getEnv(ThemeEnvVar).strip
  var choice = opts.theme
  var selected = opts.themeName
  if choice == followSystem and selected.len == 0:
    choice = parseThemeChoice(env)
    if choice == followSystem and env.len > 0:
      selected = env # a theme name or path
  if choice == followSystem and selected.len == 0:
    selected = loaded.settings.theme # neither the caller nor the environment chose
  if selected.endsWith(ThemeExt) and not fileExists(selected):
    selected.setLen selected.len - ThemeExt.len
  let indexCache = if opts.indexCacheDir.isSome: opts.indexCacheDir.get
                   else: ctx.cacheDir / "index"
  result = Ui(window: window, choice: choice, system: systemTheme(), selected: selected,
    themes: themeFiles(themeDirs(userThemes, assets)), scale: windowScale(window),
    core: initAppState(indexCache = indexCache), pick: noPick(), dog: initFrameWatchdog(),
    slow: initSlowFrameDigest(), echoing: isatty(stdout), running: true,
    agentSocket: opts.agentSocket, dialogs: opts.dialogs, trayAllowed: opts.tray,
    version: if opts.version.len > 0: opts.version else: "unknown")
  if opts.version.len > 0:
    result.say("viewSEG " & opts.version)
  if opts.persist:
    result.core.logTo(if opts.logDir.isSome: opts.logDir.get else: ctx.logDir)
    result.say("Session log: " & result.core.logFile)
    result.core.keepSettingsIn(configDir, loaded)
    result.core.rememberFilesIn(configDir)
    result.core.keepLayoutsIn(configDir, assets)
    result.core.setVendorFolders(if opts.vendorFolders.isSome: opts.vendorFolders.get
                                 else: defaultVendorFolders(ctx, configDir))
    result.keepsLayouts = true
  result.appliedTheme = result.core.settings.theme
  var names: seq[string] = @[]
  for f in result.themes: names.add f.name
  result.core.offerThemes(names)
  for d in assets:
    result.fontDirs.add d / "fonts"
  if assets.len == 0:
    result.say("No assets folder found next to the program; using the built-in theme " &
      "and font.", mlWarning)

proc run*(opts = RunOptions()): int =
  ## Opens the main window and runs the event loop until the window closes, the
  ## user quits, or `opts.maxFrames` frames are drawn. Returns the process exit
  ## code: 1 when a `StartupStep` fails, after reporting it (`onFailure`).
  template tried(step: StartupStep; call: untyped): bool =
    step notin opts.simulate and call
  when defined(linux):
    # ImGui's SDL3 backend creates viewport windows on X11 but not on Wayland,
    # so prefer X11 (Xwayland). SDL_VIDEO_DRIVER in the environment still wins.
    discard SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "x11,wayland")
  setIconHints()
  if not tried(ssVideo, SDL_Init(SDL_INIT_VIDEO)):
    return opts.fail(ssVideo, sdlError())
  defer: SDL_Quit_proc()

  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, 0)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE.cint)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3)
  discard SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1)
  # The settings come first: where the window opens is one of them.
  var loaded = LoadedSettings(saveable: true)
  var configDir = ""
  if opts.persist:
    let ctx = currentContext()
    configDir = if opts.configDir.isSome: opts.configDir.get else: ctx.configDir
    # A release that is not portable may carry site defaults in its config/.
    let site = if ctx.isPortable: "" else: ctx.appDir / "config" / SettingsFileName
    loaded = loadSettings(configDir / SettingsFileName, site)
  let place = if ssWindow in opts.simulate: MainPlace()
              else: createMainWindow(opts.windowSize, loaded.settings.window, opts.resetWindows)
  let window = place.window
  if window.isNil:
    return opts.fail(ssWindow, sdlError())
  defer: SDL_DestroyWindow(window)
  when not defined(windows) and not defined(macosx):
    if not setWindowIcon(SDL_GetWindowID(window)):
      toStderr "no window icon: " & $SDL_GetError()
  let glContext = if ssGlContext in opts.simulate: nil else: SDL_GL_CreateContext(window)
  if glContext.isNil:
    return opts.fail(ssGlContext, sdlError())
  defer: discard SDL_GL_DestroyContext(glContext)
  discard SDL_GL_MakeCurrent(window, glContext)
  discard SDL_GL_SetSwapInterval(1) # vsync
  if not tried(ssGlFunctions, gladLoadGL(SDL_GL_GetProcAddress)):
    return opts.fail(ssGlFunctions, sdlError())

  let imgui = igCreateContext(nil)
  defer: igDestroyContext(imgui)
  let implot = ImPlot_CreateContext()
  defer: ImPlot_DestroyContext(implot)
  # No double-click fit: a plot's first click already means something
  # (docs/plot-window.md); "fit all" is a control. Button 4 is never pressed.
  ImPlot_GetInputMap().Fit = 4
  let io = igGetIO_Nil()
  io.ConfigFlags = io.ConfigFlags or ImGui_ConfigFlags_NavEnableKeyboard.cint or
    ImGui_ConfigFlags_DockingEnable.cint or ImGui_ConfigFlags_ViewportsEnable.cint
  io.IniFilename = nil # the layout goes into the settings folder as NIF (`core/layouts`)
  io.IniSavingRate = 1 # seconds after a change before Dear ImGui says it changed
  when RoutedChecks:
    io.ConfigErrorRecoveryEnableTooltip = false # failed checks go to the log instead

  # A backend that failed to start must not be shut down: it registers its
  # shutdown only once it has started.
  if not tried(ssImguiSdl, ImGui_ImplSDL3_InitForOpenGL(window, glContext)):
    return opts.fail(ssImguiSdl, "")
  defer: ImGui_ImplSDL3_Shutdown()
  if not tried(ssImguiGl, ImGui_Impl_opengl3_Init(glslVersion)):
    return opts.fail(ssImguiGl, "")
  defer: ImGui_Impl_OpenGL3_Shutdown()
  installDpiScaling(window)
  installFrames(window) # the OS frames of the viewport windows, in the theme's colours

  # The windows as they were at the last exit: read, as the settings were,
  # before this thread becomes the UI thread, which never reads a file.
  # With --reset-windows the windows start as at a first start: no layout.
  let last = if opts.persist and not opts.resetWindows: loadLayoutFile(configDir /
      LayoutFileName) else: LoadedLayout()
  var ui = initUi(window, opts, loaded, configDir)
  ui.windows.installHandler() # before a layout is read: it says which windows are hidden
  if place.note.len > 0: ui.core.report(place.severity, "window", place.note)
  ui.placed = place.moved # its place now is saved after the first frame
  for (severity, text) in last.notes: ui.core.report(severity, "layouts", text)
  if last.found: ui.arrange(last.layout.imgui)
  ui.setTheme()
  when defined(windows):
    ui.say(framesNote(windowsVersionNow()))
  if opts.tray:
    # Ctrl+C in a console: a clean quit (settings saved, tray icon removed);
    # a second one ends the program at once.
    setControlCHook(proc () {.noconv.} =
      if stopAsked.exchange(true):
        discard removeTrayIcons()
        quit(130))
  let gpuError = ui.trace.startGpu(glProc, opts.maxTextureSize)
  if gpuError.len > 0:
    ui.say("The plot cannot be drawn: " & gpuError, mlError)
  discard ui.auxTrace.startGpu(glProc, opts.maxTextureSize)
  let mapError = ui.map.startGpu()
  if mapError.len > 0:
    ui.say("The map cannot be drawn: " & mapError, mlError)
  if opts.agent: ui.toggleAgent()
  let (awake, asleep) = (frontendOf(addr ui, false), frontendOf(addr ui, true))
  if opts.openPaths.len > 0:
    ui.core.apply Command(kind: ckBrowse, paths: opts.openPaths, showFirst: true)
  elif opts.persist and ui.core.settings.reopenProject and
      ui.core.settings.lastProject.len > 0:
    # The project open at the quit, opened again (it lists its own folder).
    ui.core.apply Command(kind: ckOpenProject, projectPath: ui.core.settings.lastProject)
  elif opts.persist and ui.core.settings.recentFolders.len > 0:
    # The folder listed last, listed again; nothing is opened until chosen.
    # The listing finds out whether it is still there (a drive may not
    # answer: nothing here looks), and says so quietly when it is not.
    ui.core.apply Command(kind: ckBrowse, paths: @[ui.core.settings.recentFolders[0]],
      quiet: true)
  var
    frame = 0
    event: SDL_Event
  # A test slows each frame (a starved machine) without loading the CPU.
  # Unset, or not a number: no wait.
  let frameSleep = block:
    var n = 0
    let v = getEnv("VIEWSEG_FRAME_SLEEP_MS")
    if v.len > 0:
      try:
        n = parseInt(v)
      except ValueError:
        n = 0
    n
  while ui.running:
    if frameSleep > 0: sleep frameSleep
    ui.deliverInput()
    when FrameWatchdogOn:
      ui.dog.beginFrame()
    ui.mark "events"
    while SDL_PollEvent(addr event):
      discard ImGui_ImplSDL3_ProcessEvent(addr event)
      noteSdlEvent(event.type_field)
      let mainWindowEvent = event.window.windowID == SDL_GetWindowID(window)
      if event.type_field == SDL_EVENT_QUIT.uint32 or
          (event.type_field == SDL_EVENT_WINDOW_CLOSE_REQUESTED.uint32 and mainWindowEvent):
        ui.running = false
      elif event.type_field in [SDL_EVENT_WINDOW_FOCUS_GAINED.uint32,
          SDL_EVENT_WINDOW_FOCUS_LOST.uint32]:
        followFocus(event.window.windowID.uint32,
          event.type_field == SDL_EVENT_WINDOW_FOCUS_GAINED.uint32)
      elif mainWindowEvent and event.type_field == SDL_EVENT_WINDOW_MINIMIZED.uint32:
        ui.hideInTray()
      elif mainWindowEvent and event.type_field in [SDL_EVENT_WINDOW_MOVED.uint32,
          SDL_EVENT_WINDOW_RESIZED.uint32, SDL_EVENT_WINDOW_MAXIMIZED.uint32,
          SDL_EVENT_WINDOW_RESTORED.uint32]:
        ui.placed = true
      elif event.type_field == SDL_EVENT_DROP_BEGIN.uint32:
        ui.dropped.setLen 0
        ui.dropAt = igGetTime()
      elif event.type_field == SDL_EVENT_DROP_POSITION.uint32:
        ui.dropAt = igGetTime()
      elif event.type_field == SDL_EVENT_DROP_FILE.uint32:
        if event.drop.data != nil: ui.dropped.add $event.drop.data
      elif event.type_field == SDL_EVENT_DROP_COMPLETE.uint32:
        ui.dropAt = 0
        ui.dropped.drop(ui.core)
      elif event.type_field == SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED.uint32 and
          mainWindowEvent:
        let scale = windowScale(window)
        refreshIcons() # the title bar's and taskbar's icons at the new size
        if scale != ui.scale:
          ui.scale = scale
          ui.restyle()
          ui.say("Display scale: " & $int(round(scale * 100)) & " %")
    for ev in pollShellEvents():
      ui.onShellEvent(ev)
    if stopAsked.load: ui.running = false
    if frame > 0: ui.followTray() # after the first picture: GTK's start takes a moment on Linux
    ui.mark "inbox"
    discard ui.core.drainInbox()
    if (SDL_GetWindowFlags(window) and (SDL_WINDOW_MINIMIZED or SDL_WINDOW_HIDDEN)) != 0:
      ui.mark "agents"
      ui.agent.serve(ui.core, asleep)
      ui.mark("minimized", idle = true)
      SDL_Delay(10)
    else:
      ui.mark "draw"
      ImGui_Impl_OpenGL3_NewFrame()
      ImGui_ImplSDL3_NewFrame()
      igNewFrame()
      # The program was made with a typed number taking effect as it is typed (Dear ImGui 1.92.9
      # turned that off: a number is then written back only when its box is left), so every
      # number box has it back, from this one place.
      igPushItemFlag(ImGui_ItemFlags_LiveEditOnInputScalar.cint, true)
      let actions = ui.drawUi()
      igPopItemFlag()
      ui.mark "render"
      igRender()
      for c in newImguiChecks():
        ui.say(c.describe, mlError)

      var w, h: cint
      discard SDL_GetWindowSizeInPixels(window, addr w, addr h)
      glViewport(0, 0, w, h)
      let bg = ui.theme.roles[rlBackdrop]
      glClearColor(bg.r.float32 / 255, bg.g.float32 / 255, bg.b.float32 / 255, 1)
      glClear(GL_COLOR_BUFFER_BIT)
      ImGui_Impl_OpenGL3_RenderDrawData(igGetDrawData())
      ui.mark "agents" # what agents asked, answered from this frame
      ui.agent.serve(ui.core, awake)
      if opts.onFrame != nil:
        ui.mark("test hook", idle = true) # not the program's own work
        opts.onFrame(FrameInfo(index: frame, width: w.int, height: h.int, theme: ui.theme,
          scale: ui.scale, ui: addr ui))
      ui.mark "viewports"
      if (io.ConfigFlags and ImGui_ConfigFlags_ViewportsEnable.cint) != 0:
        # Viewport windows switch the GL context; restore the main one.
        let (backupWindow, backupContext) = (SDL_GL_GetCurrentWindow(),
          SDL_GL_GetCurrentContext())
        igUpdatePlatformWindows()
        igRenderPlatformWindowsDefault(nil, nil)
        discard SDL_GL_MakeCurrent(backupWindow, backupContext)
      ui.mark("swap", idle = true) # waits for the display under vsync
      discard SDL_GL_SwapWindow(window)
      # Actions change fonts and styles, which ImGui allows only between frames.
      ui.mark "actions"
      ui.onActions(actions)
      if ui.placed:
        ui.notePlacement()
        ui.placed = false
      ui.followSettings()
      ui.followTitle()
      ui.offScreenCheck()
      ui.noteLayout()
      ui.followLayouts()
      ui.followPreview()
      if ui.pendingTheme.isSome:
        ui.selected = ui.pendingTheme.get
        ui.pendingTheme = none(string)
        ui.setTheme()

      inc frame
      if opts.maxFrames > 0 and frame >= opts.maxFrames:
        ui.running = false
    when FrameWatchdogOn:
      let slow = ui.dog.endFrame()
      if slow.isSome:
        ui.slow.note slow.get
      let report = ui.slow.take()
      if report.isSome:
        ui.core.report(sevWarning, "frame", report.get)
    ui.echoNewLog()
    ui.core.persist()
  stopGeneratePreview()
  hideTray() # the icon goes first: the rest of the quit can take a moment
  # The quit waits a fifth of a second for the agents' socket to go (its
  # folder may not answer), then the core's threads (`shutdown`).
  ui.agent.stop(ui.core, getMonoTime() + initDuration(milliseconds = 200))
  ui.map.stopGpu() # while the GL context is current
  ui.auxTrace.stopGpu()
  ui.trace.stopGpu()
  ui.notePlacement()
  ui.core.apply Command(kind: ckLayout, arrangement: $igSaveIniSettingsToMemory(nil))
  # Saves the settings and the layout. A disk slow to write them is waited
  # for (up to `DiskQuitLimit`); past a moment the window says so, and goes
  # on drawing (tried against hiding the window at once: then a slow save,
  # or one given up, was not seen at all).
  let quitAt = getMonoTime()
  ui.core.shutdown(tick = proc () {.raises: [].} =
    if getMonoTime() - quitAt >= SavingShownAfter:
      inc frame
      try: ui.savingFrame(window, opts, frame)
      except Exception: discard) # a frame that fails only stops the message
  when RoutedChecks:
    if opts.onFrame != nil and not opts.allowToolkitErrors and checkCount() > 0:
      raise newException(AssertionDefect, "Dear ImGui's checks failed:\n" & checkReport())
  0
