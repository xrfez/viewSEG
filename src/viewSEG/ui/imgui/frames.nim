## The frames the OS draws around viewSEG's windows, in the theme's colours:
## `platform/chrome` on the main window and on every window Dear ImGui's
## SDL3 backend opens for a viewport (a window dragged out of the main one,
## a menu or tooltip past its edge). The backend's `Platform_CreateWindow`
## is wrapped (`installFrames`), so each such window gets the look before it
## is first shown; `dressWindows` gives every open window a new look (a
## theme change, or the system's light/dark switch, after which SDL resets
## the title bar's mode itself). Windows only in effect: elsewhere
## `platform/chrome` does nothing, and the count `dressed` still says which
## windows were reached (tests).

import sdl3_nim
import imguin/cimgui
import ../../core/geometry
import ../../platform/chrome
import ../../view/theme

func chromeRgb(c: Rgba): ChromeRgb = ChromeRgb(r: c.r, g: c.g, b: c.b)

func lookOf*(t: Theme): ChromeLook =
  ## The frame for theme `t`: dark when it is dark; the title bar in the
  ## colour of the menu bar just under it (`bar`), so the two read as one
  ## band; the title in the text colour; the border in the theme's. While
  ## another window is active, as Windows does with its own colours: the
  ## title in the secondary text colour (`text_dim`) and the border halfway
  ## to the bar.
  ChromeLook(dark: t.mode == tmDark, caption: chromeRgb(t.roles[rlBar]),
    captionText: chromeRgb(t.roles[rlText]), border: chromeRgb(t.roles[rlBorder]),
    inactiveText: chromeRgb(t.roles[rlTextDim]),
    inactiveBorder: chromeRgb(mix(t.roles[rlBorder], t.roles[rlBar], 0.5)))

var
  look: ChromeLook
  haveLook = false
  version = UnknownVersion
  mainWindowId: SDL_WindowID
  backendCreate: proc (vp: ptr ImGuiViewport) {.cdecl.}
  dressed*: int ## windows given a look since the start (tests)

proc hwndOf(window: ptr SDL_Window): pointer =
  ## The native handle of `window`; nil elsewhere than Windows.
  when defined(windows):
    SDL_GetPointerProperty(SDL_GetWindowProperties(window), SDL_PROP_WINDOW_WIN32_HWND_POINTER,
      nil)
  else:
    nil

proc windowOf(vp: ptr ImGuiViewport): ptr SDL_Window =
  ## The SDL window of a viewport: the backend keeps its id as the handle.
  if vp.isNil or vp.PlatformHandle.isNil: nil
  else: SDL_GetWindowFromID(SDL_WindowID(cast[uint](vp.PlatformHandle)))

func kindOf(vp: ptr ImGuiViewport): FrameKind =
  if (vp.Flags and ImGui_ViewportFlags_NoDecoration.cint) != 0: fkFrameless else: fkFramed

proc dress(window: ptr SDL_Window; kind: FrameKind; redraw: bool) =
  if window.isNil: return
  inc dressed
  let hwnd = hwndOf(window)
  let active = (SDL_GetWindowFlags(window) and SDL_WINDOW_INPUT_FOCUS) != 0
  discard applyChrome(hwnd, look, kind, version, redraw, active)
  if kind == fkFramed:
    discard setWindowIcons(hwnd)

proc onCreateWindow(vp: ptr ImGuiViewport) {.cdecl.} =
  ## The backend's `Platform_CreateWindow`, then the look (the window is still
  ## hidden: the backend shows it later).
  backendCreate(vp)
  if haveLook:
    dress(windowOf(vp), kindOf(vp), redraw = false)

proc installFrames*(mainWindow: ptr SDL_Window) =
  ## Wraps the backend's window creation. Call once, after
  ## `ImGui_ImplSDL3_InitForOpenGL`.
  mainWindowId = SDL_GetWindowID(mainWindow)
  version = windowsVersion()
  let pio = igGetPlatformIO_Nil()
  if pio.Platform_CreateWindow != nil and pio.Platform_CreateWindow != onCreateWindow:
    backendCreate = pio.Platform_CreateWindow
    pio.Platform_CreateWindow = onCreateWindow

proc dressWindows*(l: ChromeLook) =
  ## Gives the main window and every open viewport window the look `l`, and
  ## each window opened from now on. Main thread, between frames.
  look = l
  haveLook = true
  let main = SDL_GetWindowFromID(mainWindowId)
  dress(main, fkFramed, redraw = true)
  let pio = igGetPlatformIO_Nil()
  let mainVp = igGetMainViewport()
  if pio.Viewports.Data != nil:
    let vps = cast[ptr UncheckedArray[ptr ImGuiViewport]](pio.Viewports.Data)
    for i in 0 ..< pio.Viewports.Size.int:
      let vp = vps[i]
      if vp != mainVp:
        let w = windowOf(vp)
        if w != nil and w != main:
          dress(w, kindOf(vp), redraw = true)

proc followFocus*(windowId: uint32; active: bool) =
  ## A framed window became active or inactive (`SDL_EVENT_WINDOW_FOCUS_GAINED`
  ## and `..._LOST`): its title and border as Windows would show them.
  if not haveLook: return
  let window = SDL_GetWindowFromID(SDL_WindowID(windowId))
  if window.isNil: return
  var kind = fkFrameless
  if SDL_WindowID(windowId) == mainWindowId:
    kind = fkFramed
  else:
    let vp = igFindViewportByPlatformHandle(cast[pointer](uint(windowId)))
    if vp != nil: kind = kindOf(vp)
  if kind == fkFramed:
    inc dressed
    discard applyChrome(hwndOf(window), look, kind, version, active = active)

proc refreshIcons*() =
  ## The main window's icons again at its screen's size (after a DPI change).
  discard setWindowIcons(hwndOf(SDL_GetWindowFromID(mainWindowId)))

func framesNote*(v: WindowsVersion): string =
  ## What the frames can do on Windows `v`, for the log.
  if v.build == 0: "Window frames: Windows version unknown; every attribute is tried"
  elif v.build >= Windows11Build: "Window frames: Windows 11 (build " & $v.build &
    "): title bar in the theme's colours, rounded corners"
  elif v.build >= DarkModeBuild: "Window frames: Windows 10 (build " & $v.build &
    "): dark or light title bar as the theme; no caption colours before Windows 11"
  else: "Window frames: Windows build " & $v.build & " has no dark title bar"

proc windowsVersionNow*(): WindowsVersion =
  ## The version `installFrames` found (`UnknownVersion` elsewhere).
  version
