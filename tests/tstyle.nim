## The theme and DPI rules of the ImGui frontend: the pure procs, and
## `applyStyle` on a real ImGui context (no window or GL needed): every ImGui
## and ImPlot colour comes from the theme, none is left at the stock value.

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

block uiScaleRules:
  doAssert uiScale(1, 1) == 1
  doAssert uiScale(2, 1) == 2 # Windows / X11 at 200 %
  doAssert uiScale(1.5, 1) == 1.5
  doAssert uiScale(2, 2) == 1 # Retina, Wayland: ImGui's framebuffer scale does it
  doAssert uiScale(3, 2) == 1.5 # Wayland 300 % with a 2x buffer
  doAssert uiScale(0, 1) == 1 # SDL failed
  doAssert uiScale(2, 0) == 1
  doAssert uiScale(NaN, 1) == 1
  doAssert uiScale(10, 1) == 4 # clamped
  doAssert uiScale(0.25, 1) == 0.5

block windowSize:
  doAssert scaledWindowSize((1280, 800), 1, (1920, 1040)) == (1280, 800)
  doAssert scaledWindowSize((1280, 800), 1.5, (3840, 2100)) == (1920, 1200)
  doAssert scaledWindowSize((1280, 800), 2, (1920, 1040)) == (1728, 936) # 90 % of usable
  doAssert scaledWindowSize((1280, 800), 2, (0, 0)) == (2560, 1600) # unknown display
  # The first window on laptops at 150 % (usable areas in pixels, under a
  # 48-pixel taskbar): 1080p is too small for 1280 x 800 points, so it opens
  # maximized (restored: 90 % of the screen); 4K takes it as it is.
  doAssert scaledWindowSize((1280, 800), 1.5, (1920, 1032)) == (1728, 928)
  doAssert startsMaximized((1280, 800), 1.5, (1920, 1032))
  doAssert scaledWindowSize((1280, 800), 1.5, (3840, 2088)) == (1920, 1200)
  doAssert not startsMaximized((1280, 800), 1.5, (3840, 2088))
  doAssert not startsMaximized((1280, 800), 1, (1920, 1040)) # 1080p at 100 %
  doAssert startsMaximized((1280, 800), 1, (1366, 728)) # a 1366 x 768 screen
  doAssert not startsMaximized((1280, 800), 2, (0, 0)) # unknown display

block colourPacking:
  doAssert u32(Rgba(r: 1, g: 2, b: 3, a: 4)) == 0x04030201'u32
  let v = vec4(rgb(0xff8000))
  doAssert v.x == 1 and v.z == 0 and v.w == 1 and abs(v.y - 128 / 255) < 1e-6

const
  # Colours that are deliberately the same as ImGui's stock ones: transparent,
  # so the surface below shows (no shadows, no child or row backgrounds).
  imguiSameAsStock = [ImGui_Col_ChildBg, ImGui_Col_BorderShadow, ImGui_Col_TableRowBg]
  # ImPlot's automatic colours: each series takes the next colour of the
  # theme's colormap, which is checked separately.
  implotSameAsStock = [ImPlot_Col_Line, ImPlot_Col_Fill, ImPlot_Col_MarkerOutline,
    ImPlot_Col_MarkerFill]
  stockBlue = ImVec4_c(x: 0.26, y: 0.59, z: 0.98, w: 1) # ImGui's accent

func same(a, b: ImVec4_c; tol = 0.003): bool =
  abs(a.x - b.x) <= tol and abs(a.y - b.y) <= tol and abs(a.z - b.z) <= tol and
    abs(a.w - b.w) <= tol

func sameRgb(a, b: ImVec4_c; tol: float32): bool =
  abs(a.x - b.x) <= tol and abs(a.y - b.y) <= tol and abs(a.z - b.z) <= tol

proc stockImgui(mode: ThemeMode): ImGuiStyle =
  let s = ImGuiStyle_ImGuiStyle()
  if mode == tmDark: igStyleColorsDark(s) else: igStyleColorsLight(s)
  result = s[]
  ImGuiStyle_destroy(s)

proc stockImplot(mode: ThemeMode): ImPlotStyle =
  let s = ImPlotStyle_ImPlotStyle()
  if mode == tmDark: ImPlot_StyleColorsDark(s) else: ImPlot_StyleColorsLight(s)
  result = s[]
  ImPlotStyle_destroy(s)

block applyStyleOnContext:
  let ctx = igCreateContext(nil)
  let plotCtx = ImPlot_CreateContext()
  defer:
    ImPlot_DestroyContext(plotCtx)
    igDestroyContext(ctx)
  let style = igGetStyle()
  let plot = ImPlot_GetStyle()

  # A colour the theme forgets is transparent black (`imguiColours` and
  # `implotColours` start from zero), or, if `applyStyle` skipped it, what a
  # fresh style holds: ImGui's dark colours, IMPLOT_AUTO_COL for ImPlot.
  let (fresh, freshPlot) = (stockImgui(tmDark), ImPlotStyle_ImPlotStyle())
  defer: ImPlotStyle_destroy(freshPlot)
  for t in [EverforestDark, EverforestLight]:
    applyStyle(t, 1)
    let (stock, stockPlot) = (stockImgui(t.mode), stockImplot(t.mode))
    var unchanged: seq[string]
    for col in ImGui_Col_Text ..< ImGui_Col_COUNT:
      let (mine, theirs) = (style.Colors[col.int], stock.Colors[col.int])
      let left = same(mine, theirs) or same(mine, fresh.Colors[col.int]) or
        same(mine, ImVec4_c())
      if left != (col in imguiSameAsStock):
        unchanged.add $col
      doAssert not sameRgb(mine, stockBlue, 0.06) or mine.w == 0,
        t.name & ": " & $col & " is ImGui's blue"
    for col in ImPlot_Col_Line ..< ImPlot_Col_COUNT:
      let (mine, theirs) = (plot.Colors[col.int], stockPlot.Colors[col.int])
      let left = same(mine, theirs) or same(mine, freshPlot.Colors[col.int]) or
        same(mine, ImVec4_c())
      if left != (col in implotSameAsStock):
        unchanged.add $col
    doAssert unchanged.len == 0, t.name & ": left at (or wrongly away from) stock: " &
      $unchanged
    doAssert same(style.Colors[ImGui_Col_WindowBg.int], vec4(t.roles[rlWindow]))
    doAssert same(style.Colors[ImGui_Col_Text.int], vec4(t.roles[rlText]))
    doAssert same(plot.Colors[ImPlot_Col_PlotBg.int], vec4(t.roles[rlPlotBackground]))
    # The default colormap is the theme's series palette.
    doAssert ImPlot_GetColormapSize(plot.Colormap) == t.series.len.cint
    for i, c in t.series:
      doAssert same(ImPlot_GetColormapColor(i.cint, plot.Colormap), vec4(c)), $i
    doAssert style.FontSizeBase == t.metrics.fontSize
    doAssert style.WindowRounding == 0 and style.FrameRounding == t.metrics.frameRounding
  # Re-applying a theme reuses its colormap instead of adding another.
  let cmap = plot.Colormap
  applyStyle(EverforestDark, 1)
  applyStyle(EverforestLight, 1)
  doAssert plot.Colormap == cmap

  let pad1 = style.WindowPadding.x
  let scroll1 = style.ScrollbarSize
  let plotPad1 = plot.PlotPadding.x
  doAssert pad1 == EverforestLight.metrics.windowPadding
  # Scaling starts from the defaults each time: applying 2 twice is still 2x.
  style.FontScaleDpi = 2 # set by ImGui per viewport; applyStyle keeps it
  applyStyle(EverforestDark, 2)
  applyStyle(EverforestDark, 2)
  doAssert almostEqual(style.WindowPadding.x, 2 * pad1), $style.WindowPadding.x
  doAssert almostEqual(style.ScrollbarSize, 2 * scroll1), $style.ScrollbarSize
  doAssert almostEqual(plot.PlotPadding.x, 2 * plotPad1), $plot.PlotPadding.x
  doAssert style.FontScaleDpi == 2
  doAssert style.FontSizeBase == EverforestDark.metrics.fontSize # ImGui scales fonts itself
  applyStyle(EverforestDark, 1)
  doAssert style.WindowPadding.x == pad1

block anotherTheme:
  # A theme that is not Everforest maps the same way.
  var messages: seq[string]
  let slate = parseTheme("background = \"#1f2933\"\nforeground = \"#e4e7eb\"\n" &
    "accent = \"#e3a33b\"\n", "Slate", messages)
  let ctx = igCreateContext(nil)
  let plotCtx = ImPlot_CreateContext()
  defer:
    ImPlot_DestroyContext(plotCtx)
    igDestroyContext(ctx)
  applyStyle(slate, 1)
  let style = igGetStyle()
  doAssert same(style.Colors[ImGui_Col_WindowBg.int], vec4(rgb(0x1f2933)))
  doAssert same(style.Colors[ImGui_Col_CheckMark.int], vec4(rgb(0xe3a33b)))
  doAssert same(style.Colors[ImGui_Col_TabSelectedOverline.int], vec4(rgb(0xe3a33b)))
