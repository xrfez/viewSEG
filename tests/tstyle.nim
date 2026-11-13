## The theme and DPI rules of the ImGui frontend: the pure procs, and
## `applyStyle` on a real ImGui context (no window or GL needed).

import std/math
import viewSEG/core/geometry
import viewSEG/ui/imgui/[dpi, shell, style]
import imguin/cimgui

block themeChoice:
  doAssert parseThemeChoice("dark") == forceDark
  doAssert parseThemeChoice(" Light\n") == forceLight
  doAssert parseThemeChoice("") == followSystem
  doAssert parseThemeChoice("auto") == followSystem

block resolveThemeRules:
  doAssert resolveTheme(followSystem, stLight) == tmLight
  doAssert resolveTheme(followSystem, stDark) == tmDark
  doAssert resolveTheme(followSystem, stUnknown) == tmDark
  for system in SystemTheme:
    doAssert resolveTheme(forceDark, system) == tmDark
    doAssert resolveTheme(forceLight, system) == tmLight

block clearColours:
  let (dark, light) = (clearColor(tmDark), clearColor(tmLight))
  doAssert dark.r.int + dark.g.int + dark.b.int < 200, $dark
  doAssert light.r.int + light.g.int + light.b.int > 500, $light

block uiScaleRules:
  doAssert uiScale(1, 1) == 1
  doAssert uiScale(2, 1) == 2           # Windows / X11 at 200 %
  doAssert uiScale(1.5, 1) == 1.5
  doAssert uiScale(2, 2) == 1           # Retina, Wayland: ImGui's framebuffer scale does it
  doAssert uiScale(3, 2) == 1.5         # Wayland 300 % with a 2x buffer
  doAssert uiScale(0, 1) == 1           # SDL failed
  doAssert uiScale(2, 0) == 1
  doAssert uiScale(NaN, 1) == 1
  doAssert uiScale(10, 1) == 4          # clamped
  doAssert uiScale(0.25, 1) == 0.5

block windowSize:
  doAssert scaledWindowSize((1280, 800), 1, (1920, 1040)) == (1280, 800)
  doAssert scaledWindowSize((1280, 800), 1.5, (3840, 2100)) == (1920, 1200)
  doAssert scaledWindowSize((1280, 800), 2, (1920, 1040)) == (1728, 936) # 90 % of usable
  doAssert scaledWindowSize((1280, 800), 2, (0, 0)) == (2560, 1600)     # unknown display

block applyStyleOnContext:
  let ctx = igCreateContext(nil)
  let plotCtx = ImPlot_CreateContext()
  defer:
    ImPlot_DestroyContext(plotCtx)
    igDestroyContext(ctx)
  let style = igGetStyle()
  proc windowBg(): float32 =
    let c = style.Colors[ImGui_Col_WindowBg.int]
    (c.x + c.y + c.z) / 3

  applyStyle(tmDark, 1)
  let (darkBg, pad1, scroll1) = (windowBg(), style.WindowPadding.x, style.ScrollbarSize)
  doAssert darkBg < 0.3, $darkBg
  doAssert style.WindowRounding == 0 and style.Colors[ImGui_Col_WindowBg.int].w == 1

  applyStyle(tmLight, 1)
  doAssert windowBg() > 0.8, $windowBg()
  doAssert style.WindowPadding.x == pad1

  # Scaling starts from the defaults each time: applying 2 twice is still 2x.
  style.FontScaleDpi = 2 # set by ImGui per viewport; applyStyle keeps it
  applyStyle(tmDark, 2)
  applyStyle(tmDark, 2)
  doAssert almostEqual(style.WindowPadding.x, 2 * pad1), $style.WindowPadding.x
  doAssert almostEqual(style.ScrollbarSize, 2 * scroll1), $style.ScrollbarSize
  doAssert style.FontScaleDpi == 2
  doAssert windowBg() == darkBg
  applyStyle(tmDark, 1)
  doAssert style.WindowPadding.x == pad1
