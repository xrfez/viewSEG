## The Dear ImGui and ImPlot look: dark or light, at a UI scale. `applyStyle` is
## the one place where a theme and a scale become a style; the rest are pure
## helpers that decide which theme to use.

import std/strutils
import imguin/cimgui
import ../../core/geometry
import shell

type
  ThemeMode* = enum
    ## Which variant of the look to draw: dark or light.
    tmDark = "dark", tmLight = "light"

  ThemeChoice* = enum
    ## What the user (or a test) asked for.
    followSystem, ## the OS light/dark setting, also when it changes
    forceDark, forceLight

const ThemeEnvVar* = "VIEWSEG_THEME"
  ## `dark` or `light` forces a theme; anything else follows the system.

func parseThemeChoice*(s: string): ThemeChoice =
  ## `"dark"` or `"light"` (any case, surrounding blanks ignored); anything
  ## else, including "", means following the system.
  case s.strip.toLowerAscii
  of "dark": forceDark
  of "light": forceLight
  else: followSystem

func resolveTheme*(choice: ThemeChoice; system: SystemTheme): ThemeMode =
  ## The theme to draw with. An unknown system setting gives the dark theme,
  ## which suits seismic displays.
  case choice
  of forceDark: tmDark
  of forceLight: tmLight
  of followSystem: (if system == stLight: tmLight else: tmDark)

func clearColor*(t: ThemeMode): Rgba =
  ## The background behind the dockspace: what shows where no window is drawn.
  case t
  of tmDark: Rgba(r: 28, g: 32, b: 38, a: 255)
  of tmLight: Rgba(r: 214, g: 219, b: 226, a: 255)

proc applyStyle*(t: ThemeMode; scale: float32) =
  ## Rebuilds the current ImGui and ImPlot styles for theme `t` at UI scale
  ## `scale` (1 = 100 %), starting from the defaults each time, so it may be
  ## called again whenever the theme or the scale changes. Fonts are not
  ## touched: with `io.ConfigDpiScaleFonts` ImGui scales them per viewport.
  let style = igGetStyle()
  let fresh = ImGuiStyle_ImGuiStyle()
  let fontScaleDpi = style.FontScaleDpi # owned by ImGui's per-viewport DPI logic
  style[] = fresh[]
  ImGuiStyle_destroy(fresh)
  style.FontScaleDpi = fontScaleDpi
  case t
  of tmDark:
    igStyleColorsDark(style)
    ImPlot_StyleColorsDark(ImPlot_GetStyle())
  of tmLight:
    igStyleColorsLight(style)
    ImPlot_StyleColorsLight(ImPlot_GetStyle())
  # Viewport windows are OS windows: keep them square and opaque.
  style.WindowRounding = 0
  style.Colors[ImGui_Col_WindowBg.int].w = 1
  if scale != 1:
    ImGuiStyle_ScaleAllSizes(style, scale)
