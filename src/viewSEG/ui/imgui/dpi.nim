## Per-monitor DPI with Dear ImGui 1.92's own mechanisms:
##
## - `Platform_GetWindowDpiScale` (installed here) gives ImGui each viewport's
##   UI scale, from `SDL_GetWindowDisplayScale` and `SDL_GetWindowPixelDensity`.
## - `io.ConfigDpiScaleFonts`: ImGui sets `style.FontScaleDpi` to the scale of
##   the viewport being drawn, and the 1.92 dynamic font atlas bakes glyphs at
##   that size, so text is sharp on every monitor.
## - `io.ConfigDpiScaleViewports`: ImGui resizes the windows inside a viewport
##   when its scale changes, e.g. when it is dragged to another monitor.
## - Style metrics (padding, spacing, scrollbar sizes) are global in ImGui: they
##   follow the main window's scale (`style.applyStyle`), redone on
##   `SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED`.

import std/math
import sdl3_nim
import imguin/cimgui

func uiScale*(displayScale, pixelDensity: float32): float32 =
  ## The scale of ImGui's units in a window: SDL's display scale (what the user
  ## set, 2 = 200 %) divided by the pixel density (framebuffer pixels per window
  ## unit, which ImGui already applies through the framebuffer scale). So 1 on a
  ## Retina Mac or under Wayland fractional scaling, where the window is sized
  ## in points, and the display scale on Windows and X11, where it is sized in
  ## pixels. Unusable inputs give 1; the result is kept in 0.5 .. 4.
  if displayScale.isNaN or pixelDensity.isNaN or displayScale <= 0 or pixelDensity <= 0:
    result = 1
  else:
    result = clamp(displayScale / pixelDensity, 0.5'f32, 4'f32)

func scaledWindowSize*(base: (int, int); scale: float32; usable: (int, int)): (int, int) =
  ## The first window size: `base` at UI scale `scale`, no larger than 90 % of
  ## the usable display area `usable` (ignored when 0).
  result = (int(base[0].float32 * scale), int(base[1].float32 * scale))
  if usable[0] > 0 and usable[1] > 0:
    result = (min(result[0], usable[0] * 9 div 10), min(result[1], usable[1] * 9 div 10))

proc windowScale*(window: ptr SDL_Window): float32 =
  ## The UI scale of `window` (`uiScale` of its SDL scales).
  uiScale(SDL_GetWindowDisplayScale(window), SDL_GetWindowPixelDensity(window))

proc primaryDisplayScale*(): float32 =
  ## The UI scale of the primary display, before any window exists. Its pixel
  ## density is unknown then: assume 1 (true on Windows and X11).
  uiScale(SDL_GetDisplayContentScale(SDL_GetPrimaryDisplay()), 1)

var mainWindowId: SDL_WindowID

proc viewportScale(vp: ptr ImGuiViewport): cfloat {.cdecl.} =
  ## ImGui's `Platform_GetWindowDpiScale`. The SDL3 backend stores the SDL
  ## window id as the platform handle; without one (no multi-viewport support,
  ## e.g. Wayland) the viewport is the main window.
  let id = if vp.PlatformHandle.isNil: mainWindowId
           else: SDL_WindowID(cast[uint](vp.PlatformHandle))
  let window = SDL_GetWindowFromID(id)
  if window.isNil: 1 else: windowScale(window)

proc installDpiScaling*(mainWindow: ptr SDL_Window) =
  ## Turns on ImGui's per-viewport DPI handling, with the scale from
  ## `windowScale`. Call after `ImGui_ImplSDL3_InitForOpenGL`.
  mainWindowId = SDL_GetWindowID(mainWindow)
  let io = igGetIO_Nil()
  io.ConfigDpiScaleFonts = true
  io.ConfigDpiScaleViewports = true
  igGetPlatformIO_Nil().Platform_GetWindowDpiScale = viewportScale
