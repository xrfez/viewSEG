## The Dear ImGui frontend: imguin (Dear ImGui with docking and multi-viewports,
## plus ImPlot) on SDL3 and OpenGL 3. Only `ui/imgui/` may import imguin, ImPlot
## or SDL (docs/architecture.md).
##
## For now the window holds a dockspace over the main viewport and one ImPlot
## window; `-d:imguiDemo` adds the Dear ImGui demo window.

import std/math
import sdl3_nim
import imguin/[cimgui, impl_sdl3, impl_opengl]
import imguin/glad/gl
import ../../core/geometry

const
  ClearColor* = Rgba(r: 28, g: 32, b: 38, a: 255)
    ## The background behind the dockspace: what shows where no window is drawn.
  glslVersion = "#version 330"
  defaultSize = (w: 1280, h: 800)

type
  FrameInfo* = object
    ## What a frame hook sees. The hook runs after the main window is drawn and
    ## before its buffers swap, with its GL context current.
    index*: int ## 0 for the first frame
    width*, height*: int ## framebuffer size in pixels

  FrameHook* = proc (frame: FrameInfo) {.closure.}

  RunOptions* = object
    maxFrames*: int     ## stop after this many frames; 0 runs until the window closes
    onFrame*: FrameHook ## called once per frame, nil for none

  Plot = object
    xs, ys: seq[float32]

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

proc drawUi(plot: Plot) =
  let vp = igGetMainViewport()
  discard igDockSpaceOverViewport(0, vp, ImGui_DockNodeFlags_PassthruCentralNode.cint, nil)
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + 40, y: vp.WorkPos.y + 40),
    ImGui_Cond_FirstUseEver.cint, ImVec2_c(x: 0, y: 0))
  igSetNextWindowSize(ImVec2_c(x: 560, y: 380), ImGui_Cond_FirstUseEver.cint)
  if igBegin("Plot", nil, 0):
    if ImPlot_BeginPlot("Damped sine", ImVec2_c(x: -1, y: -1), 0):
      ImPlot_SetupAxes("t (s)", "amplitude", 0, 0)
      ImPlot_PlotLine_FloatPtrFloatPtr("signal", addr plot.xs[0], addr plot.ys[0],
        plot.xs.len.cint, 0, 0, sizeof(float32).cint)
      ImPlot_EndPlot()
  igEnd()
  when defined(imguiDemo):
    igShowDemoWindow(nil)

proc fail(what: string): int =
  stderr.writeLine "viewSEG: ", what, ": ", SDL_GetError()
  1

proc run*(opts = RunOptions()): int =
  ## Opens the main window and runs the event loop until the window closes or
  ## `opts.maxFrames` frames are drawn. Returns the process exit code: 1 when
  ## SDL, the window or the GL context cannot be set up.
  when defined(linux):
    # ImGui's SDL3 backend creates viewport windows on X11 but not on Wayland,
    # so prefer X11 (Xwayland). SDL_VIDEO_DRIVER in the environment still wins.
    discard SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "x11,wayland")
  if not SDL_Init(SDL_INIT_VIDEO):
    return fail("cannot initialise SDL video")
  defer: SDL_Quit_proc()

  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_FLAGS, 0)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE.cint)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
  discard SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3)
  discard SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1)
  let window = SDL_CreateWindow("viewSEG", defaultSize.w.cint, defaultSize.h.cint,
    SDL_WINDOW_OPENGL or SDL_WINDOW_RESIZABLE or SDL_WINDOW_HIGH_PIXEL_DENSITY)
  if window.isNil:
    return fail("cannot create the window")
  defer: SDL_DestroyWindow(window)
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
  igStyleColorsDark(nil)
  let style = igGetStyle()
  style.WindowRounding = 0 # viewport windows are OS windows: keep them square and opaque
  style.Colors[ImGui_Col_WindowBg.int].w = 1

  discard ImGui_ImplSDL3_InitForOpenGL(window, glContext)
  defer: ImGui_ImplSDL3_Shutdown()
  discard ImGui_Impl_opengl3_Init(glslVersion)
  defer: ImGui_Impl_OpenGL3_Shutdown()

  let plot = dampedSine(1000)
  var
    frame = 0
    running = true
    event: SDL_Event
  while running:
    while SDL_PollEvent(addr event):
      discard ImGui_ImplSDL3_ProcessEvent(addr event)
      if event.type_field == SDL_EVENT_QUIT.uint32 or
          (event.type_field == SDL_EVENT_WINDOW_CLOSE_REQUESTED.uint32 and
          event.window.windowID == SDL_GetWindowID(window)):
        running = false
    if (SDL_GetWindowFlags(window) and SDL_WINDOW_MINIMIZED) != 0:
      SDL_Delay(10)
      continue

    ImGui_Impl_OpenGL3_NewFrame()
    ImGui_ImplSDL3_NewFrame()
    igNewFrame()
    drawUi(plot)
    igRender()

    var w, h: cint
    discard SDL_GetWindowSizeInPixels(window, addr w, addr h)
    glViewport(0, 0, w, h)
    glClearColor(ClearColor.r.float32 / 255, ClearColor.g.float32 / 255,
      ClearColor.b.float32 / 255, ClearColor.a.float32 / 255)
    glClear(GL_COLOR_BUFFER_BIT)
    ImGui_Impl_OpenGL3_RenderDrawData(igGetDrawData())
    if opts.onFrame != nil:
      opts.onFrame(FrameInfo(index: frame, width: w.int, height: h.int))
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
      running = false
  0
