## The Dear ImGui frontend: imguin (Dear ImGui with docking and multi-viewports,
## plus ImPlot) on SDL3 and OpenGL 3. Only `ui/imgui/` may import imguin, ImPlot
## or SDL (docs/architecture.md).
##
## The window holds a menu bar, an icon toolbar, a dockspace with a sample plot,
## a sample table and the Messages window, and a status bar; `-d:imguiDemo`
## adds the Dear ImGui demo window. The look comes from a theme file
## (`view/theme`, `style`, `fonts`); the shell services (dialogs, system theme,
## icon) are in `shell`, DPI handling in `dpi`, the chrome in `chrome`.
##
## The application state (`core/state`) lives here, on the UI thread: each
## frame drains its inbox, and what it logs is shown in the Messages window
## until the log window replaces it. Debug builds time every frame
## (`core/watchdog`) and log the frames whose work is over budget, with what
## the frame was doing.
##
## A start-up step that fails (SDL, the window, OpenGL 3.3, either ImGui
## backend) is reported in a message box, on stderr and in
## `<logs>/startup-failure.log`, and `run` returns 1. In release builds a failed
## Dear ImGui check is logged instead of aborting (`asserts`).

import std/[math, options, os, strutils, times]
import asserts # before imguin: Nim keys its cache of imguin's C++ objects on the
               # C flags in force when imguin is compiled, and this adds one
import sdl3_nim
import imguin/[cimgui, impl_sdl3, impl_opengl]
import imguin/glad/gl
import ../../core/[geometry, state, watchdog]
import ../../platform/paths
import chrome, dpi, fonts, icons, menus, messages, shell, style

export ThemeChoice, theme, messages, ImguiCheck

const
  glslVersion = "#version 330"
  defaultSize = (1280, 800)               ## the first window size at 100 %
  plotTitle = IconPlot & "  Plot###plot"
  tableTitle = IconTable & "  Headers###headers"
  messagesTitle = IconLog & "  Messages###Messages"
  failureLogName* = "startup-failure.log" ## in the log folder; the last failure only

type
  Ui = object
    ## The frontend's own state between frames.
    window: ptr SDL_Window
    choice: ThemeChoice
    system: SystemTheme
    themes: seq[ThemeFile]       ## the theme files found, user's first
    selected: string             ## the chosen theme file's name; "" follows the system
    theme: Theme
    scale: float32
    fontDirs: seq[string]
    fonts: Fonts
    messages: Messages
    core: AppState               ## the application state
    logSeen: int                 ## the core log's entries shown in `messages` so far
    dog: FrameWatchdog
    marks: Marks
    pendingTheme: Option[string] ## picked in the menu, applied after the frame
    layoutDone: bool
    running: bool

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

  RunOptions* = object
    maxFrames*: int            ## stop after this many frames; 0 runs until the window closes
    onFrame*: FrameHook        ## called once per frame, nil for none
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
  ## Where the named part (`"toolbar"`, `"statusbar"`, `"plot"`,
  ## `"tool.Open file"`, `"tool.Open folder"` ...) was drawn in this frame, in
  ## framebuffer pixels; an empty rectangle when it was not.
  result = Rect()
  for (n, r) in frame.ui.marks:
    if n == name: result = r

proc chooseTheme*(frame: FrameInfo; name: string) =
  ## Picks theme file `name` ("" follows the system) as View > Theme does;
  ## it applies after this frame.
  frame.ui.pendingTheme = some(name)

proc messages*(frame: FrameInfo): lent Messages =
  ## The Messages window's contents so far.
  frame.ui.messages

proc core*(frame: FrameInfo): lent AppState =
  ## The application state as this frame drew it.
  frame.ui.core

# ------------------------------------------------------------------ themes --

proc themeDirs(userDir: string; assetDirs: openArray[string]): seq[string] =
  result = @[userDir]
  for d in assetDirs:
    result.add d / "themes"

proc pickTheme(ui: var Ui): Theme =
  ## The theme to draw with now: the selected file, else the default file for
  ## the system's (or the forced) mode, else the built-in theme.
  let mode = resolveTheme(ui.choice, ui.system)
  let wanted = if ui.selected.len > 0: ui.selected else: DefaultThemeNames[mode]
  var path = ""
  for f in ui.themes:
    if f.name == wanted: path = f.path
  if path.len == 0 and fileExists(wanted):
    path = wanted
  if path.len == 0:
    result = builtinTheme(mode)
    if ui.selected.len > 0:
      ui.messages.add "Theme `" & ui.selected & "` not found; using the built-in " &
        result.name & ".", mlWarning
  else:
    var problems: seq[string]
    result = loadTheme(path, mode, problems)
    for p in problems:
      ui.messages.add p, mlWarning
  ui.messages.add "Theme: " & result.name & " (" &
    (if path.len > 0: path else: "built in") & ")"

proc restyle(ui: var Ui) =
  applyStyle(ui.theme, ui.scale)

proc setTheme(ui: var Ui) =
  ## Loads the theme `pickTheme` names, with its fonts, and restyles.
  ui.theme = ui.pickTheme()
  ui.fonts.load(ui.theme, ui.fontDirs, ui.messages)
  ui.restyle()

proc toggleTheme(ui: var Ui) =
  ## Switches to the default theme of the other mode.
  let other = if ui.theme.mode == tmDark: tmLight else: tmDark
  ui.selected = DefaultThemeNames[other]
  ui.setTheme()

# ------------------------------------------------------------------ events --

proc onShellEvent(ui: var Ui; ev: ShellEvent) =
  case ev.kind
  of sePathsChosen:
    for p in ev.paths:
      ui.messages.add($ev.dialog & ": " & p)
  of seCancelled:
    ui.messages.add($ev.dialog & ": cancelled")
  of seDialogFailed:
    const hint = when defined(linux):
        " (Linux needs xdg-desktop-portal with a GTK or KDE backend, or zenity.)"
      else: ""
    ui.messages.add($ev.dialog & ": the dialog could not be shown: " & ev.error & hint,
      mlError)
  of seThemeChanged:
    ui.messages.add("System theme: " & $ev.theme)
    ui.system = ev.theme
    if ui.selected.len == 0 and resolveTheme(ui.choice, ev.theme) != ui.theme.mode:
      ui.setTheme()

proc onActions(ui: var Ui; actions: set[MenuAction]) =
  let parent = SDL_GetWindowID(ui.window)
  for a in actions:
    case a
    of maOpenFile: showOpenDialog(dkOpenFile, parent)
    of maOpenFiles: showOpenDialog(dkOpenFiles, parent)
    of maOpenFolder: showOpenDialog(dkOpenFolder, parent)
    of maQuit: ui.running = false
    of maToggleTheme: ui.toggleTheme()

# ------------------------------------------------------------------- frame --

template mark(ui: var Ui; part: string; idle = false) =
  ## Starts the part of the frame named `part` for the watchdog; `idle` when
  ## the thread waits in it.
  when FrameWatchdogOn:
    ui.dog.phase(part, waiting = idle)

proc showNewLog(ui: var Ui) =
  ## Shows what the core logged since the last call in the Messages window.
  const level: array[Severity, MessageLevel] = [mlInfo, mlWarning, mlError, mlError]
  for e in ui.core.log.since(ui.logSeen):
    ui.messages.add(e.text, level[e.severity])
  ui.logSeen = ui.core.log.nextSerial

proc buildLayout(ui: var Ui; dockId: ImGuiID; size: ImVec2_c) =
  ## The first layout: the plot top left, the messages under it, the header
  ## table on the right.
  igDockBuilderRemoveNode(dockId)
  discard igDockBuilderAddNode(dockId, ImGui_DockNodeFlags_DockSpace.cint)
  igDockBuilderSetNodeSize(dockId, size)
  var left, right, top, bottom: ImGuiID
  discard igDockBuilderSplitNode(dockId, ImGuiDir_Right, 0.36, addr right, addr left)
  discard igDockBuilderSplitNode(left, ImGui_Dir_Down, 0.3, addr bottom, addr top)
  igDockBuilderDockWindow(plotTitle, top)
  igDockBuilderDockWindow(tableTitle, right)
  igDockBuilderDockWindow(messagesTitle, bottom)
  igDockBuilderFinish(dockId)
  ui.layoutDone = true

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
  if not ui.layoutDone:
    ui.buildLayout(dockId, igGetContentRegionAvail())
  igPushStyleColor_Vec4(ImGui_Col_Border.cint, backdrop) # ImGui draws splitters in it
  discard igDockSpace(dockId, ImVec2_c(x: 0, y: 0), 0, nil)
  igPopStyleColor(1)
  igEnd()

proc drawUi(ui: var Ui; plot: SamplePlot): set[MenuAction] =
  ui.marks.setLen 0
  let menu = drawMainMenu(ui.themes, ui.selected)
  result = menu.actions
  if menu.pickedTheme and menu.theme != ui.selected:
    ui.pendingTheme = some(menu.theme) # fonts and styles change between frames
  result.incl drawToolbar(ui.theme, ui.marks)
  drawStatusBar(ui.fonts, ui.theme,
    ChromeInfo(themeName: ui.theme.name, scale: ui.scale), ui.marks)
  ui.drawDockSpace()
  drawSamplePlot(plotTitle, plot, ui.marks)
  drawSampleTable(tableTitle, ui.fonts, ui.theme, ui.marks)
  ui.messages.draw(messagesTitle, ui.theme)
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

proc fail(opts: RunOptions; step: StartupStep; reason: string): int =
  ## Reports a failed start-up step everywhere the user may look; returns the
  ## exit code, 1.
  let dir = if opts.logDir.isSome: opts.logDir.get
            else: currentContext().logDir
  var f = StartupFailure(step: step, reason: reason)
  f.logFile = writeFailureLog(dir, failureText(step, reason, dir / failureLogName))
  f.text = failureText(step, reason, f.logFile)
  stderr.writeLine "viewSEG: ", f.text.replace("\n\n", "\n  ")
  if opts.onFailure != nil:
    opts.onFailure(f)
  elif not SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "viewSEG cannot start",
      f.text.cstring, nil):
    stderr.writeLine "viewSEG: no message box either: ", SDL_GetError()
  1

proc sdlError(): string = $SDL_GetError()

func simulating(opts: RunOptions; steps: set[StartupStep]): RunOptions =
  ## `opts` with `steps` failing without being tried (tests import this module
  ## with `{.all.}`).
  result = opts
  result.simulate = steps

proc createMainWindow(): ptr SDL_Window =
  ## The main window, sized for the primary display's scale.
  var usable: SDL_Rect
  if not SDL_GetDisplayUsableBounds(SDL_GetPrimaryDisplay(), addr usable):
    usable = SDL_Rect()
  let (w, h) = scaledWindowSize(defaultSize, primaryDisplayScale(), (usable.w.int, usable.h.int))
  SDL_CreateWindow("viewSEG", w.cint, h.cint,
    SDL_WINDOW_OPENGL or SDL_WINDOW_RESIZABLE or SDL_WINDOW_HIGH_PIXEL_DENSITY)

proc initUi(window: ptr SDL_Window; opts: RunOptions): Ui =
  ## The frontend's state: where its assets are, which theme, the fonts.
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
  if selected.endsWith(ThemeExt) and not fileExists(selected):
    selected.setLen selected.len - ThemeExt.len
  result = Ui(window: window, choice: choice, system: systemTheme(), selected: selected,
    themes: themeFiles(themeDirs(userThemes, assets)), scale: windowScale(window),
    core: initAppState(), dog: initFrameWatchdog(), running: true)
  for d in assets:
    result.fontDirs.add d / "fonts"
  if assets.len == 0:
    result.messages.add "No assets folder found next to the program; using the " &
      "built-in theme and font.", mlWarning

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
  let window = if ssWindow in opts.simulate: nil else: createMainWindow()
  if window.isNil:
    return opts.fail(ssWindow, sdlError())
  defer: SDL_DestroyWindow(window)
  when not defined(windows) and not defined(macosx):
    if not setWindowIcon(SDL_GetWindowID(window)):
      stderr.writeLine "viewSEG: no window icon: ", SDL_GetError()
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
  let io = igGetIO_Nil()
  io.ConfigFlags = io.ConfigFlags or ImGui_ConfigFlags_NavEnableKeyboard.cint or
    ImGui_ConfigFlags_DockingEnable.cint or ImGui_ConfigFlags_ViewportsEnable.cint
  io.IniFilename = nil # no layout file until the config paths exist
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

  var ui = initUi(window, opts)
  ui.setTheme()
  let plot = samplePlot(1000)
  var
    frame = 0
    event: SDL_Event
  while ui.running:
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
      elif event.type_field == SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED.uint32 and
          mainWindowEvent:
        let scale = windowScale(window)
        if scale != ui.scale:
          ui.scale = scale
          ui.restyle()
          ui.messages.add("Display scale: " & $int(round(scale * 100)) & " %")
    for ev in pollShellEvents():
      ui.onShellEvent(ev)
    ui.mark "inbox"
    discard ui.core.drainInbox()
    ui.showNewLog()
    if (SDL_GetWindowFlags(window) and SDL_WINDOW_MINIMIZED) != 0:
      ui.mark("minimized", idle = true)
      SDL_Delay(10)
    else:
      ui.mark "draw"
      ImGui_Impl_OpenGL3_NewFrame()
      ImGui_ImplSDL3_NewFrame()
      igNewFrame()
      let actions = ui.drawUi(plot)
      ui.mark "render"
      igRender()
      for c in newImguiChecks():
        ui.messages.add c.describe, mlError

      var w, h: cint
      discard SDL_GetWindowSizeInPixels(window, addr w, addr h)
      glViewport(0, 0, w, h)
      let bg = ui.theme.roles[rlBackdrop]
      glClearColor(bg.r.float32 / 255, bg.g.float32 / 255, bg.b.float32 / 255, 1)
      glClear(GL_COLOR_BUFFER_BIT)
      ImGui_Impl_OpenGL3_RenderDrawData(igGetDrawData())
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
        ui.core.report(sevWarning, "frame", describe(slow.get))
  0
