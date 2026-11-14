## The shell's chrome around the docked panels: the icon toolbar under the menu
## bar, the status bar along the bottom (with the running job's progress bar
## and its Cancel button), and tool buttons (a Nerd Font icon or
## a seismic `Symbol`) with tooltips that name their shortcut. The toolbar holds
## application-level actions only; display and gather controls belong to the
## plot windows, which use `symbolButton`. Also the sample header table that
## shows the look until the real header table exists.
##
## Each piece records where it drew its named parts in `Marks`, so tests can
## look at the right pixels.

import std/[math, strutils]
import imguin/cimgui
import ../../core/[geometry, jobs]
import ../../view/[jobstatus, theme]
import fonts, icons, menus, style, symbols

const IconScale* = 1.3'f32
  ## toolbar icons and symbols, relative to the text size

type
  Marks* = seq[(string, Rect)]
    ## Named screen rectangles of the last frame (framebuffer pixels).

  ChromeInfo* = object
    ## Facts the status bar shows.
    themeName*: string
    scale*: float32

func toRect(a, b: ImVec2_c): Rect =
  Rect(pos: vec2(a.x, a.y), size: vec2(b.x - a.x, b.y - a.y))

proc markRect*(marks: var Marks; name: string; a, b: ImVec2_c) =
  ## Records the screen rectangle `a`..`b` as `name`, in framebuffer pixels of
  ## the main window (ImGui's coordinates are the desktop's, with viewports).
  let s = igGetIO_Nil().DisplayFramebufferScale
  let o = igGetMainViewport().Pos
  marks.add (name, toRect(ImVec2_c(x: (a.x - o.x) * s.x, y: (a.y - o.y) * s.y),
    ImVec2_c(x: (b.x - o.x) * s.x, y: (b.y - o.y) * s.y)))

proc mark*(marks: var Marks; name: string) =
  ## Records the last item's rectangle as `name`.
  marks.markRect(name, igGetItemRectMin(), igGetItemRectMax())

proc markWindow*(marks: var Marks; name: string) =
  ## Records the current window's rectangle as `name`.
  let (pos, size) = (igGetWindowPos(), igGetWindowSize())
  marks.markRect(name, pos, ImVec2_c(x: pos.x + size.x, y: pos.y + size.y))

proc tooltip(text, shortcut: string; t: Theme) =
  ## The last item's tooltip: `text`, then the shortcut in dim text.
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    if shortcut.len > 0:
      igSameLine(0, -1)
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
      igTextUnformatted(shortcut.cstring, nil)
      igPopStyleColor(1)
    igEndTooltip()

proc toolButton(id: string; size: float32; selected: bool; t: Theme): (bool, ImVec2_c) =
  ## A square, frameless button: the hover and selection backgrounds only.
  ## Returns whether it was clicked and its top-left corner.
  let pos = igGetCursorScreenPos()
  let clicked = igInvisibleButton(id.cstring, ImVec2_c(x: size, y: size), 0)
  let bg = if igIsItemActive(): t.roles[rlActive]
           elif igIsItemHovered(0): t.roles[rlHover]
           elif selected: t.roles[rlSelection]
           else: Rgba()
  if bg.a > 0:
    ImDrawList_AddRectFilled(igGetWindowDrawList(), pos,
      ImVec2_c(x: pos.x + size, y: pos.y + size), u32(bg), igGetStyle().FrameRounding, 0)
  (clicked, pos)

proc iconButton*(icon, text, shortcut: string; size: float32; t: Theme;
    marks: var Marks; selected = false): bool =
  ## A toolbar button showing a Nerd Font `icon`, centred.
  let (clicked, pos) = toolButton("##" & text, size, selected, t)
  marks.mark("tool." & text)
  # Codicons sit small in their em box: draw them at two thirds of the button
  let (font, px) = (igGetFont(), round(size * 0.68))
  let ts = ImFont_CalcTextSizeA(font, px, high(float32), 0, icon.cstring, nil, nil)
  let col = if selected: t.roles[rlAccent] else: t.roles[rlText]
  ImDrawList_AddText_FontPtr(igGetWindowDrawList(), font, px,
    ImVec2_c(x: round(pos.x + (size - ts.x) / 2), y: round(pos.y + (size - ts.y) / 2)),
    u32(col), icon.cstring, nil, 0, nil)
  tooltip(text, shortcut, t)
  clicked

proc symbolButton*(sym: Symbol; size: float32; t: Theme; marks: var Marks;
    selected = false; note = ""; markPrefix = "tool."): bool =
  ## A tool button showing a seismic symbol, for a plot window's own controls;
  ## its mark is `markPrefix` and the symbol's name.
  let (clicked, pos) = toolButton("##" & $sym, size, selected, t)
  marks.mark(markPrefix & $sym)
  let inset = round(size * 0.17)
  drawSymbol(igGetWindowDrawList(), sym, ImVec2_c(x: pos.x + inset, y: pos.y + inset),
    size - 2 * inset, symbolColours(t, selected))
  tooltip($sym & note, "", t)
  clicked

const barFlags = ImGui_WindowFlags_NoScrollbar.cint or ImGui_WindowFlags_NoSavedSettings.cint or
  ImGui_WindowFlags_NoScrollWithMouse.cint or ImGui_WindowFlags_NoDecoration.cint

proc beginBar(name: string; dir: ImGuiDir; height: float32; t: Theme): bool =
  ## A strip along an edge of the main viewport, in the bar colour, with a
  ## border line towards the panels.
  let vp = igGetMainViewport()
  igPushStyleColor_Vec4(ImGui_Col_WindowBg.cint, vec4(t.roles[rlBar]))
  igPushStyleVar_Float(ImGui_StyleVar_WindowBorderSize.cint, 0)
  igPushStyleVar_Vec2(ImGui_StyleVar_WindowPadding.cint,
    ImVec2_c(x: igGetStyle().WindowPadding.x, y: 0))
  result = igBeginViewportSideBar(name.cstring, vp, dir, height, barFlags)
  igPopStyleVar(2)
  igPopStyleColor(1)
  if result:
    let wp = igGetWindowPos()
    let ws = igGetWindowSize()
    let y = if dir == ImGui_Dir_Down: wp.y + 0.5 else: wp.y + ws.y - 0.5
    ImDrawList_AddLine(igGetWindowDrawList(), ImVec2_c(x: wp.x, y: y),
      ImVec2_c(x: wp.x + ws.x, y: y), u32(t.roles[rlBorder]), 1)

proc drawToolbar*(t: Theme; marks: var Marks): set[MenuAction] =
  ## The icon toolbar under the menu bar: opening files and folders, and the
  ## theme toggle. Returns the actions it asks for.
  result = {}
  let style = igGetStyle()
  let size = round(igGetFontSize() * IconScale + 2 * style.FramePadding.y + 2)
  let height = size + 2 * round(style.FramePadding.y)
  if beginBar("##toolbar", ImGuiDir_Up, height, t):
    marks.markWindow("toolbar")
    igSetCursorPosY(round((height - size) / 2))
    if iconButton(IconOpenFile, "Open file", shortcutName(maOpenFile), size, t, marks):
      result.incl maOpenFile
    igSameLine(0, 2)
    if iconButton(IconOpenFolder, "Open folder", shortcutName(maOpenFolder), size, t, marks):
      result.incl maOpenFolder
    igSameLine(0, 2)
    # the theme toggle sits at the right end
    let avail = igGetContentRegionAvail().x
    if avail > size:
      igSetCursorPosX(igGetCursorPosX() + avail - size)
    if iconButton(IconTheme, "Light / dark theme", "", size, t, marks):
      result.incl maToggleTheme
  igEnd()

proc field(fonts: Fonts; icon, label, value: string; t: Theme) =
  ## One status-bar field: a dim icon and label, then the value in mono.
  igSameLine(0, -1)
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextUnformatted((if icon.len > 0: icon & " " & label else: label).cstring, nil)
  igPopStyleColor(1)
  igSameLine(0, 6)
  fonts.withFont(frMono, 0):
    igTextUnformatted(value.cstring, nil)
  igSameLine(0, 18)

proc jobField(job: JobStatus; t: Theme; marks: var Marks): JobId =
  ## The running job: a progress bar labelled with what it does and how far
  ## it is, Cancel, and what else runs or waits. Returns the job to cancel,
  ## or `NoJob`.
  result = NoJob
  igSameLine(0, -1)
  if job.job != NoJob:
    let style = igGetStyle()
    let width = round(igGetFontSize() * 22)
    let height = igGetFontSize() + 2 * round(style.FramePadding.y / 2)
    # A negative fraction draws ImGui's moving "busy" bar: progress unknown.
    let fraction = if job.fraction >= 0: job.fraction else: -float32(igGetTime())
    igPushStyleVar_Vec2(ImGui_StyleVar_FramePadding.cint,
      ImVec2_c(x: style.FramePadding.x, y: round(style.FramePadding.y / 2)))
    igProgressBar(fraction, ImVec2_c(x: width, y: height), "")
    marks.mark("status.progress")
    if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
      igTextUnformatted(job.text.cstring, nil)
      igEndTooltip()
    # The label beside the bar, so a long title never hides the bar itself.
    igSameLine(0, 6)
    igTextUnformatted(job.text.cstring, nil)
    marks.mark("status.job")
    if job.cancellable:
      igSameLine(0, 8)
      igBeginDisabled(job.cancelling)
      if igSmallButton((IconClose & " Cancel##job").cstring):
        result = job.job
      igEndDisabled()
      marks.mark("status.cancel")
    igPopStyleVar(1)
  let others = job.others
  if others.len > 0:
    igSameLine(0, 12)
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
    igTextUnformatted(others.cstring, nil)
    igPopStyleColor(1)
    marks.mark("status.others")
  igSameLine(0, 18)

proc drawStatusBar*(fonts: Fonts; t: Theme; info: ChromeInfo; job: JobStatus;
    marks: var Marks): JobId =
  ## The status strip along the bottom of the main window; returns the job
  ## the user asked to cancel, or `NoJob`. The cursor fields are
  ## placeholders until the trace panel exists.
  result = NoJob
  let style = igGetStyle()
  let height = round(igGetFontSize() + 2 * style.FramePadding.y + 2)
  if beginBar("##statusbar", ImGui_Dir_Down, height, t):
    marks.markWindow("statusbar")
    igSetCursorPosY(round((height - igGetFontSize()) / 2))
    igDummy(ImVec2_c(x: 0, y: 0))
    if job.shown:
      result = jobField(job, t, marks)
    field(fonts, IconPulse, "t", "1.284 s", t)
    field(fonts, "", "trace", "128 / 480", t)
    field(fonts, "", "FFID", "1001", t)
    field(fonts, IconLocation, "src", "1201.5", t)
    field(fonts, "", "rcv", "3301.0", t)
    field(fonts, "", "amp", "-0.0412", t)
    let right = info.themeName & "   " & $int(round(info.scale * 100)) & " %"
    let w = igCalcTextSize(right.cstring, nil, false, -1).x
    let avail = igGetContentRegionAvail().x
    if avail > w:
      igSetCursorPosX(igGetCursorPosX() + avail - w)
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
    igTextUnformatted(right.cstring, nil)
    igPopStyleColor(1)
  igEnd()

# ------------------------------------------------------------- samples --

proc rightAlign(text: string) =
  ## Moves the cursor so that `text` ends at the right of the space left.
  let w = igCalcTextSize(text.cstring, nil, false, -1).x
  let avail = igGetContentRegionAvail().x
  if avail > w:
    igSetCursorPosX(igGetCursorPosX() + avail - w)

func sampleRow(r: int): array[6, string] =
  ## Row `r` of the sample header table.
  [$(r + 121), "1001", $(r + 121), formatFloat(-1187.5 + 25.0 * r.float, ffDecimal, 1),
    formatFloat(212.4 + 1.7 * sin(r.float), ffDecimal, 1),
    formatFloat(4.0 * cos(r.float / 3), ffDecimal, 2)]

proc textWidth(fonts: Fonts; role: FontRole; text: string): float32 =
  fonts.withFont(role, 0):
    result = igCalcTextSize(text.cstring, nil, false, -1).x

proc drawSampleTable*(title: string; fonts: Fonts; t: Theme; marks: var Marks) =
  ## A few rows of trace headers: mono numbers, right-aligned, one selected
  ## row and one row lit by the linked selection. The columns share the width
  ## while it holds every number, and scroll sideways when it does not, so a
  ## number is never clipped.
  const
    cols = ["Trace", "FFID", "Chan", "Offset m", "Elev m", "Static ms"]
    rows = 14
  if igBegin(title.cstring, nil, 0):
    var need = 0'f32
    for i, c in cols:
      var w = fonts.textWidth(frHeading, c)
      for r in 0 ..< rows:
        w = max(w, fonts.textWidth(frMono, sampleRow(r)[i]))
      need += w + 2 * igGetStyle().CellPadding.x
    let roomy = igGetContentRegionAvail().x >= need
    let flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
      (if roomy: ImGui_TableFlags_SizingStretchProp.cint
        else: ImGui_TableFlags_ScrollX.cint or ImGui_TableFlags_SizingFixedFit.cint)
    if igBeginTable("##headers", cols.len.cint, flags, ImVec2_c(x: 0, y: 0), 0):
      igTableSetupScrollFreeze(0, 1)
      for c in cols:
        igTableSetupColumn(c.cstring, 0, 0, 0)
      fonts.withFont(frHeading, 0):
        # like igTableHeadersRow, with the labels right-aligned over the numbers
        igTableNextRow(ImGui_TableRowFlags_Headers.cint, 0)
        for i, c in cols:
          if igTableSetColumnIndex(i.cint):
            rightAlign(c)
            igTableHeader(c.cstring)
      fonts.withFont(frMono, 0):
        for r in 0 ..< rows:
          igTableNextRow(0, 0)
          if r == 4:
            igTableSetBgColor(ImGui_TableBgTarget_RowBg1.cint, u32(t.roles[rlSelection]), -1)
          elif r == 7:
            igTableSetBgColor(ImGui_TableBgTarget_RowBg1.cint,
              u32(withAlpha(t.roles[rlHighlight], 70)), -1)
          for v in sampleRow(r):
            discard igTableNextColumn()
            rightAlign(v)
            igTextUnformatted(v.cstring, nil)
      igEndTable()
      marks.mark("table")
  igEnd()
