## The look of Dear ImGui and ImPlot: `applyStyle` maps a `Theme`
## (`view/theme`) and a UI scale onto every ImGui colour, every ImPlot colour,
## the style variables and a default ImPlot colormap. It is the only place where
## colours and metrics reach the toolkit, so no stock ImGui colour is left.
## The rest are pure helpers that decide which theme mode to use.

import std/strutils
import imguin/cimgui
import ../../core/geometry
import ../../view/theme
import shell

export theme

type
  ThemeChoice* = enum
    ## What the user (or a test) asked for, before any theme file.
    followSystem, ## the OS light/dark setting, also when it changes
    forceDark, forceLight

const ThemeEnvVar* = "VIEWSEG_THEME"
  ## `dark` or `light` forces a mode; any other word names a theme file (with or
  ## without `.toml`, or a path); empty follows the system.

func parseThemeChoice*(s: string): ThemeChoice =
  ## `"dark"` or `"light"` (any case, surrounding blanks ignored); anything
  ## else, including "", means following the system.
  case s.strip.toLowerAscii
  of "dark": forceDark
  of "light": forceLight
  else: followSystem

func resolveTheme*(choice: ThemeChoice; system: SystemTheme): ThemeMode =
  ## The mode to draw with. An unknown system setting gives the dark mode,
  ## which suits seismic displays.
  case choice
  of forceDark: tmDark
  of forceLight: tmLight
  of followSystem: (if system == stLight: tmLight else: tmDark)

func vec4*(c: Rgba): ImVec4_c =
  ImVec4_c(x: c.r.float32 / 255, y: c.g.float32 / 255, z: c.b.float32 / 255,
    w: c.a.float32 / 255)

func u32*(c: Rgba): ImU32 =
  ## ImGui's packed colour (IM_COL32: ABGR in memory order).
  c.r.uint32 or (c.g.uint32 shl 8) or (c.b.uint32 shl 16) or (c.a.uint32 shl 24)

func alpha(c: Rgba; a: float32): Rgba =
  withAlpha(c, uint8(a * 255))

func imguiColours*(t: Theme): array[ImGui_Col_COUNT.int, Rgba] =
  ## Every ImGui colour for theme `t`, by `ImGuiCol` index.
  let r = t.roles
  let clear = alpha(r[rlWindow], 0)
  template set(col: enum_ImGuiCol_private; c: Rgba) = result[col.int] = c
  set ImGui_Col_Text, r[rlText]
  set ImGui_Col_TextDisabled, r[rlTextDisabled]
  set ImGui_Col_WindowBg, r[rlWindow]
  set ImGui_Col_ChildBg, Rgba() # transparent: a child shows its parent
  set ImGui_Col_PopupBg, r[rlPopup]
  set ImGui_Col_Border, r[rlBorder]
  set ImGui_Col_BorderShadow, Rgba() # no shadows
  set ImGui_Col_FrameBg, r[rlFrame]
  set ImGui_Col_FrameBgHovered, r[rlHover]
  set ImGui_Col_FrameBgActive, r[rlActive]
  set ImGui_Col_TitleBg, r[rlBar]
  set ImGui_Col_TitleBgActive, r[rlBar] # focus shows as the tab's accent overline
  set ImGui_Col_TitleBgCollapsed, alpha(r[rlBar], 0.8)
  set ImGui_Col_MenuBarBg, r[rlBar]
  set ImGui_Col_ScrollbarBg, clear
  set ImGui_Col_ScrollbarGrab, r[rlBorder]
  set ImGui_Col_ScrollbarGrabHovered, mix(r[rlBorder], r[rlTextDim], 0.4)
  set ImGui_Col_ScrollbarGrabActive, r[rlTextDim]
  set ImGui_Col_CheckMark, r[rlAccent]
  set ImGui_Col_CheckboxSelectedBg, mix(r[rlFrame], r[rlAccent], 0.2)
  set ImGui_Col_SliderGrab, r[rlAccent]
  set ImGui_Col_SliderGrabActive, mix(r[rlAccent], r[rlText], 0.3)
  set ImGui_Col_Button, r[rlFrame]
  set ImGui_Col_ButtonHovered, r[rlHover]
  set ImGui_Col_ButtonActive, r[rlActive]
  set ImGui_Col_Header, r[rlSelection]
  set ImGui_Col_HeaderHovered, r[rlHover]
  set ImGui_Col_HeaderActive, r[rlActive]
  set ImGui_Col_Separator, r[rlBorder]
  set ImGui_Col_SeparatorHovered, alpha(r[rlAccent], 0.6)
  set ImGui_Col_SeparatorActive, r[rlAccent]
  set ImGui_Col_ResizeGrip, alpha(r[rlBorder], 0.5)
  set ImGui_Col_ResizeGripHovered, alpha(r[rlAccent], 0.6)
  set ImGui_Col_ResizeGripActive, r[rlAccent]
  set ImGui_Col_InputTextCursor, r[rlText]
  set ImGui_Col_TabHovered, r[rlHover]
  set ImGui_Col_Tab, r[rlBar]
  set ImGui_Col_TabSelected, r[rlWindow]
  set ImGui_Col_TabSelectedOverline, r[rlAccent]
  set ImGui_Col_TabDimmed, r[rlBar]
  set ImGui_Col_TabDimmedSelected, r[rlWindow]
  set ImGui_Col_TabDimmedSelectedOverline, r[rlBorder]
  set ImGui_Col_DockingPreview, alpha(r[rlAccent], 0.4)
  set ImGui_Col_DockingEmptyBg, r[rlBackdrop]
  set ImGui_Col_PlotLines, r[rlAccent]
  set ImGui_Col_PlotLinesHovered, r[rlHighlight]
  set ImGui_Col_PlotHistogram, r[rlAccent]
  set ImGui_Col_PlotHistogramHovered, r[rlHighlight]
  set ImGui_Col_TableHeaderBg, r[rlBar]
  set ImGui_Col_TableBorderStrong, r[rlBorder]
  set ImGui_Col_TableBorderLight, mix(r[rlWindow], r[rlBorder], 0.6)
  set ImGui_Col_TableRowBg, Rgba() # transparent: the window shows through
  set ImGui_Col_TableRowBgAlt, alpha(r[rlText], 0.035)
  set ImGui_Col_TextLink, r[rlAccent]
  set ImGui_Col_TextSelectedBg, r[rlTextSelection]
  set ImGui_Col_TreeLines, r[rlBorder]
  set ImGui_Col_DragDropTarget, r[rlHighlight]
  set ImGui_Col_DragDropTargetBg, alpha(r[rlHighlight], 0.15)
  set ImGui_Col_UnsavedMarker, r[rlHighlight]
  set ImGui_Col_NavCursor, r[rlAccent]
  set ImGui_Col_NavWindowingHighlight, alpha(r[rlAccent], 0.7)
  set ImGui_Col_NavWindowingDimBg, alpha(r[rlBackdrop], 0.6)
  set ImGui_Col_ModalWindowDimBg, alpha(r[rlBackdrop], 0.6)

const AutoColour* = ImVec4_c(x: 0, y: 0, z: 0, w: -1)
  ## ImPlot's IMPLOT_AUTO_COL: "the next colour of the colormap".

func implotColours*(t: Theme): array[ImPlot_Col_COUNT.int, ImVec4_c] =
  ## Every ImPlot colour for theme `t`. Line, fill and marker colours stay
  ## automatic, so each series takes the next colour of the theme's colormap.
  let r = t.roles
  template set(col: enum_ImPlotCol_private; c: Rgba) = result[col.int] = vec4(c)
  for col in [ImPlot_Col_Line, ImPlot_Col_Fill, ImPlot_Col_MarkerOutline,
      ImPlot_Col_MarkerFill]:
    result[col.int] = AutoColour
  set ImPlot_Col_ErrorBar, r[rlText]
  set ImPlot_Col_FrameBg, r[rlWindow]
  set ImPlot_Col_PlotBg, r[rlPlotBackground]
  set ImPlot_Col_PlotBorder, r[rlBorder]
  set ImPlot_Col_LegendBg, alpha(r[rlPopup], 0.92)
  set ImPlot_Col_LegendBorder, r[rlBorder]
  set ImPlot_Col_LegendText, r[rlText]
  set ImPlot_Col_TitleText, r[rlText]
  set ImPlot_Col_InlayText, r[rlTextDim]
  set ImPlot_Col_AxisText, r[rlTextDim]
  set ImPlot_Col_AxisGrid, r[rlPlotGrid]
  set ImPlot_Col_AxisTick, r[rlBorder]
  set ImPlot_Col_AxisBg, alpha(r[rlWindow], 0)
  set ImPlot_Col_AxisBgHovered, alpha(r[rlHover], 0.6)
  set ImPlot_Col_AxisBgActive, alpha(r[rlActive], 0.6)
  set ImPlot_Col_Selection, r[rlHighlight]
  set ImPlot_Col_Crosshairs, alpha(r[rlCrosshair], 0.8)

proc themeColormap(t: Theme): ImPlotColormap =
  ## The ImPlot colormap of `t`'s series palette, added once per palette
  ## (ImPlot cannot remove colormaps; the name carries the colours).
  var name = "viewSEG"
  var cols: array[8, ImU32]
  for i, c in t.series:
    cols[i] = u32(c)
    name.add toHex(c)
  result = ImPlot_GetColormapIndex(name.cstring)
  if result == -1:
    result = ImPlot_AddColormap_U32Ptr(name.cstring, addr cols[0], cols.len.cint, true)

func v2(x, y: float32): ImVec2_c = ImVec2_c(x: x, y: y)

func scaled(v: ImVec2_c; s: float32): ImVec2_c = v2(v.x * s, v.y * s)

proc applyStyle*(t: Theme; scale: float32) =
  ## Rebuilds the current ImGui and ImPlot styles for theme `t` at UI scale
  ## `scale` (1 = 100 %), starting from the defaults each time, so it may be
  ## called again whenever the theme or the scale changes. Font sizes are set
  ## here (`t.metrics.fontSize`); ImGui multiplies them per viewport
  ## (`io.ConfigDpiScaleFonts`). The fonts themselves are `fonts.nim`'s.
  let style = igGetStyle()
  let fresh = ImGuiStyle_ImGuiStyle()
  let fontScaleDpi = style.FontScaleDpi # owned by ImGui's per-viewport DPI logic
  style[] = fresh[]
  ImGuiStyle_destroy(fresh)
  style.FontScaleDpi = fontScaleDpi
  let m = t.metrics
  style.FontSizeBase = m.fontSize
  style.internal_NextFrameFontSizeBase = m.fontSize # applied at the next NewFrame
  let colours = imguiColours(t)
  for i, c in colours:
    style.Colors[i] = vec4(c)

  # Flat panels, soft corners, muted borders. Viewport windows are OS windows:
  # keep top-level windows square.
  style.WindowRounding = 0
  style.ChildRounding = m.rounding
  style.PopupRounding = m.rounding
  style.FrameRounding = m.frameRounding
  style.GrabRounding = m.frameRounding
  style.TabRounding = m.frameRounding
  style.SelectableRounding = m.frameRounding
  style.MenuItemRounding = m.frameRounding
  style.ScrollbarRounding = m.scrollbarSize
  style.WindowBorderSize = m.borderWidth
  style.ChildBorderSize = m.borderWidth
  style.PopupBorderSize = m.borderWidth
  style.FrameBorderSize = 0
  style.TabBorderSize = 0
  style.TabBarBorderSize = m.borderWidth
  style.TabBarOverlineSize = 2
  style.SeparatorSize = m.borderWidth
  style.DockingSeparatorSize = 4 # the gap between docked panels
  style.WindowPadding = v2(m.windowPadding, m.windowPadding)
  style.FramePadding = v2(m.framePaddingX, m.framePaddingY)
  style.ItemSpacing = v2(m.itemSpacingX, m.itemSpacingY)
  style.ItemInnerSpacing = v2(6, 4)
  style.CellPadding = v2(8, 3)
  style.IndentSpacing = 18
  style.ScrollbarSize = m.scrollbarSize
  style.ScrollbarPadding = 2
  style.GrabMinSize = 10
  style.WindowTitleAlign = v2(0, 0.5)
  style.WindowMenuButtonPosition = ImGuiDir_None
  style.SeparatorTextBorderSize = m.borderWidth
  style.SeparatorTextPadding = v2(0, 3)
  style.TabMinWidthBase = 4 * m.fontSize
  if scale != 1:
    ImGuiStyle_ScaleAllSizes(style, scale)

  # ImPlot: no borders, the theme's grid and colormap, sizes at this scale.
  let plot = ImPlot_GetStyle()
  let plotFresh = ImPlotStyle_ImPlotStyle()
  plot[] = plotFresh[]
  ImPlotStyle_destroy(plotFresh)
  let pcs = implotColours(t)
  for i, c in pcs:
    plot.Colors[i] = c
  plot.Colormap = themeColormap(t)
  plot.MinorAlpha = 0.4
  plot.PlotBorderSize = 0
  plot.LineWeight = 1.5 * scale
  plot.MarkerSize *= scale
  plot.MarkerWeight *= scale
  plot.PlotPadding = v2(m.windowPadding, m.windowPadding).scaled(scale)
  for v in [addr plot.LabelPadding, addr plot.LegendPadding, addr plot.LegendInnerPadding,
      addr plot.LegendSpacing, addr plot.MousePosPadding, addr plot.AnnotationPadding,
      addr plot.MajorTickLen, addr plot.MinorTickLen, addr plot.MajorTickSize,
      addr plot.MinorTickSize, addr plot.MajorGridSize, addr plot.MinorGridSize,
      addr plot.PlotDefaultSize, addr plot.PlotMinSize]:
    v[] = v[].scaled(scale)
  plot.LegendInnerPadding = v2(8, 5).scaled(scale)
