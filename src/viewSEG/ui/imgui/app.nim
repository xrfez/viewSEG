## The Dear ImGui frontend: imguin (Dear ImGui with docking and multi-viewports,
## plus ImPlot) on SDL3 and OpenGL 3. Only `ui/imgui/` may import imguin, ImPlot
## or SDL (docs/architecture.md).
##
## For now the window holds a menu bar, a dockspace over the main viewport, one
## ImPlot window and a "Messages" window; `-d:imguiDemo` adds the Dear ImGui
## demo window. The shell services (dialogs, theme, icon) are in `shell`, the
## look in `style`, DPI handling in `dpi`.

import std/[math, os, strutils]
import sdl3_nim
import imguin/[cimgui, impl_sdl3, impl_opengl]
import imguin/glad/gl
import ../../core/geometry
import dpi, menus, messages, shell, style

export ThemeMode, ThemeChoice, clearColor

const
  glslVersion = "#version 330"
  defaultSize = (1280, 800) ## the first window size at 100 %

type
  FrameInfo* = object
    ## What a frame hook sees. The hook runs after the main window is drawn and
    ## before its buffers swap, with its GL context current.
    index*: int ## 0 for the first frame
    width*, height*: int ## framebuffer size in pixels
    theme*: ThemeMode ## the theme the frame was drawn with
    scale*: float32 ## the main window's UI scale (1 = 100 %)

  FrameHook* = proc (frame: FrameInfo) {.closure.}

  RunOptions* = object
    maxFrames*: int     ## stop after this many frames; 0 runs until the window closes
    onFrame*: FrameHook ## called once per frame, nil for none
    theme*: ThemeChoice
      ## `followSystem` (the default) also honours the VIEWSEG_THEME
      ## environment variable (`dark` or `light`).

  Plot = object
    xs, ys: seq[float32]

  Ui = object
    ## The frontend's own state between frames.
    window: ptr SDL_Window
    choice: ThemeChoice
    theme: ThemeMode
    scale: float32
    messages: Messages
    running: bool

func dampedSine(n: int): Plot =
  ## A small line series for the placeholder plot.
  result = Plot(xs: newSeq[float32](n), ys: newSeq[float32](n))
  for i in 0 ..< n:
    let t = i.float32 / 100
    result.xs[i] = t
    result.ys[i] = exp(-t / 2) * sin(2 * PI * t)

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

proc restyle(ui: var Ui) =
  applyStyle(ui.theme, ui.scale)

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
    ui.messages.add($ev.dialog & ": the dialog could not be shown: " & ev.error & hint)
  of seThemeChanged:
    ui.messages.add("System theme: " & $ev.theme)
    let theme = resolveTheme(ui.choice, ev.theme)
    if theme != ui.theme:
      ui.theme = theme
      ui.restyle()

proc onMenu(ui: var Ui; actions: set[MenuAction]) =
  let parent = SDL_GetWindowID(ui.window)
  for a in actions:
    case a
    of maOpenFile: showOpenDialog(dkOpenFile, parent)
    of maOpenFiles: showOpenDialog(dkOpenFiles, parent)
    of maOpenFolder: showOpenDialog(dkOpenFolder, parent)
    of maQuit: ui.running = false

proc drawUi(ui: var Ui; plot: Plot) =
  ui.onMenu(drawMainMenu())
  let
    vp = igGetMainViewport()
    s = ui.scale
    margin = 40 * s
    messagesHeight = 180 * s
    # First placement: plot at the top left, messages along the bottom, both
    # inside the main window at any scale.
    plotHeight = max(min(380 * s, vp.WorkSize.y - messagesHeight - 3 * margin), 100 * s)
  discard igDockSpaceOverViewport(0, vp, ImGui_DockNodeFlags_PassthruCentralNode.cint, nil)
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + margin, y: vp.WorkPos.y + margin),
    ImGui_Cond_FirstUseEver.cint, ImVec2_c(x: 0, y: 0))
  igSetNextWindowSize(ImVec2_c(x: 560 * s, y: plotHeight), ImGui_Cond_FirstUseEver.cint)
  if igBegin("Plot", nil, 0):
    if ImPlot_BeginPlot("Damped sine", ImVec2_c(x: -1, y: -1), 0):
      ImPlot_SetupAxes("t (s)", "amplitude", 0, 0)
      ImPlot_PlotLine_FloatPtrFloatPtr("signal", addr plot.xs[0], addr plot.ys[0],
        plot.xs.len.cint, 0, 0, sizeof(float32).cint)
      ImPlot_EndPlot()
  igEnd()
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + margin,
    y: vp.WorkPos.y + vp.WorkSize.y - messagesHeight - margin),
    ImGui_Cond_FirstUseEver.cint, ImVec2_c(x: 0, y: 0))
  igSetNextWindowSize(ImVec2_c(x: 560 * s, y: messagesHeight), ImGui_Cond_FirstUseEver.cint)
  ui.messages.draw()
  when defined(imguiDemo):
    igShowDemoWindow(nil)

proc fail(what: string): int =
  stderr.writeLine "viewSEG: ", what, ": ", SDL_GetError()
  1

proc createMainWindow(): ptr SDL_Window =
  ## The main window, sized for the primary display's scale.
  var usable: SDL_Rect
  if not SDL_GetDisplayUsableBounds(SDL_GetPrimaryDisplay(), addr usable):
    usable = SDL_Rect()
  let (w, h) = scaledWindowSize(defaultSize, primaryDisplayScale(), (usable.w.int, usable.h.int))
  SDL_CreateWindow("viewSEG", w.cint, h.cint,
    SDL_WINDOW_OPENGL or SDL_WINDOW_RESIZABLE or SDL_WINDOW_HIGH_PIXEL_DENSITY)

proc run*(opts = RunOptions()): int =
  ## Opens the main window and runs the event loop until the window closes, the
  ## user quits, or `opts.maxFrames` frames are drawn. Returns the process exit
  ## code: 1 when SDL, the window or the GL context cannot be set up.
  when defined(linux):
    # ImGui's SDL3 backend creates viewport windows on X11 but not on Wayland,
    # so prefer X11 (Xwayland). SDL_VIDEO_DRIVER in the environment still wins.
    discard SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "x11,wayland")
  setIconHints()
  if not SDL_Init(SDL_INIT_VIDEO):
    return fail("cannot initialise SDL video")
  defer: SDL_Quit_proc()

  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, 0)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE.cint)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3)
  discard SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1)
  let window = createMainWindow()
  if window.isNil:
    return fail("cannot create the window")
  defer: SDL_DestroyWindow(window)
  when not defined(windows) and not defined(macosx):
    if not setWindowIcon(SDL_GetWindowID(window)):
      stderr.writeLine "viewSEG: no window icon: ", SDL_GetError()
  let glContext = SDL_GL_CreateContext(window)
  if glContext.isNil:
    return fail("cannot create an OpenGL 3.3 core context")
  defer: discard SDL_GL_DestroyContext(glContext)
  discard SDL_GL_MakeCurrent(window, glContext)
  discard SDL_GL_SetSwapInterval(1) # vsync
  if not gladLoadGL(SDL_GL_GetProcAddress):
    return fail("cannot load the OpenGL functions")

  let imgui = igCreateContext(nil)
  defer: igDestroyContext(imgui)
  let implot = ImPlot_CreateContext()
  defer: ImPlot_DestroyContext(implot)
  let io = igGetIO_Nil()
  io.ConfigFlags = io.ConfigFlags or ImGui_ConfigFlags_NavEnableKeyboard.cint or
    ImGui_ConfigFlags_DockingEnable.cint or ImGui_ConfigFlags_ViewportsEnable.cint
  io.IniFilename = nil # no layout file until the config paths exist

  discard ImGui_ImplSDL3_InitForOpenGL(window, glContext)
  defer: ImGui_ImplSDL3_Shutdown()
  discard ImGui_Impl_opengl3_Init(glslVersion)
  defer: ImGui_Impl_OpenGL3_Shutdown()
  installDpiScaling(window)

  let choice = if opts.theme != followSystem: opts.theme
               else: parseThemeChoice(getEnv(ThemeEnvVar))
  var ui = Ui(window: window, choice: choice, theme: resolveTheme(choice, systemTheme()),
    scale: windowScale(window), running: true)
  ui.restyle()
  let plot = dampedSine(1000)
  var
    frame = 0
    event: SDL_Event
  while ui.running:
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
          ui.messages.add("Display scale: " & formatFloat(scale * 100, ffDecimal, 0) & " %")
    for ev in pollShellEvents():
      ui.onShellEvent(ev)
    if (SDL_GetWindowFlags(window) and SDL_WINDOW_MINIMIZED) != 0:
      SDL_Delay(10)
    else:
      ImGui_Impl_OpenGL3_NewFrame()
      ImGui_ImplSDL3_NewFrame()
      igNewFrame()
      ui.drawUi(plot)
      igRender()

      var w, h: cint
      discard SDL_GetWindowSizeInPixels(window, addr w, addr h)
      glViewport(0, 0, w, h)
      let bg = clearColor(ui.theme)
      glClearColor(bg.r.float32 / 255, bg.g.float32 / 255, bg.b.float32 / 255,
        bg.a.float32 / 255)
      glClear(GL_COLOR_BUFFER_BIT)
      ImGui_Impl_OpenGL3_RenderDrawData(igGetDrawData())
      if opts.onFrame != nil:
        opts.onFrame(FrameInfo(index: frame, width: w.int, height: h.int, theme: ui.theme,
          scale: ui.scale))
      if (io.ConfigFlags and ImGui_ConfigFlags_ViewportsEnable.cint) != 0:
        # Viewport windows switch the GL context; restore the main one.
        let (backupWindow, backupContext) = (SDL_GL_GetCurrentWindow(),
          SDL_GL_GetCurrentContext())
        igUpdatePlatformWindows()
        igRenderPlatformWindowsDefault(nil, nil)
        discard SDL_GL_MakeCurrent(backupWindow, backupContext)
      discard SDL_GL_SwapWindow(window)

      inc frame
      if opts.maxFrames > 0 and frame >= opts.maxFrames:
        ui.running = false
  0
