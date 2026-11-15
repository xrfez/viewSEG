## The analysis windows (New plot): each a window of its own that docks,
## titled by what it shows ("Spectrogram 2: trace 12 · FFID 151 ·
## shot.sgd"), opened from Window > New plot or the plot's right-click menu
## on the selection or the trace under the pointer.
##
## Each shows a line of its view's settings (a spectrogram's frame length,
## overlap, floor and colour map; a phase spectrum's dB threshold and
## unwrapping; a correlation's reference and lags) and Freeze, what it is
## of and through which filters, then its plots: an image in a density
## colour map with its scale (a spectrogram), or curve plots (`curveplot`)
## one under another, and what the cursor reads. The image's cursor follows
## the pointer, or is held by the keys while the window has the focus: Left
## and Right step a column (a frame), Up and Down a row (a frequency bin),
## Home and End go to the ends, Esc lets it go; its lines run to the axes,
## where its exact values are written. The windows read `core` and issue
## `Command`s: `ckPlotDisplay` for a setting, `ckPlotCursor` for a key,
## `ckClosePlot` when one is closed.

import std/[math, strutils, tables]
import imguin/cimgui
import ../../core/[colourmaps, plotcursor, state]
import ../../view/[analysisview, curveplot, theme]
import curveplot as curves, icons, marks, spectrumwindow, style

const PlotSize = (640'f32, 620'f32) ## a window's first size, at 100 %

type
  PlotWindowsUi* = object
    ## The analysis windows' state between frames.
    curves: Table[int, seq[CurvePlotUi]] ## per window id, per plot
    under: Table[int, PlotCursor]        ## per window id: the cell under the pointer last frame
    readout*: Table[int, string]         ## per window id: what its cursor read last frame (tests)
    maps: array[ColourMap, int]          ## ImPlot's index of each density colour map + 1; 0: not added

  PlotWindowsOutput* = object
    commands*: seq[Command]

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

func markName*(w: AnalysisWindow): string =
  ## The window's mark (and screenshot target): "new plot 2".
  "new plot " & $w.id

func windowTitle*(w: AnalysisWindow): string =
  ## Its ImGui title: its name, then its identity, which a layout keeps.
  IconPulse & "  " & w.title & "###newplot-" & $w.id

type Keys = object
  ## The cursor keys pressed this frame, while the window has the focus.
  left, right, up, down, home, ending, escape: bool

proc keysNow(focused: bool): Keys =
  ## The keys that move a cursor (repeating while held, as the spectrum
  ## windows' do); none while a box takes the keys or the window has no
  ## focus.
  if not focused or igGetIO_Nil().WantTextInput: return
  template held(k: untyped): bool = igShortcut_Nil(k.cint, ImGui_InputFlags_Repeat.cint)
  template once(k: untyped): bool = igShortcut_Nil(k.cint, 0)
  Keys(left: held(ImGui_Key_LeftArrow), right: held(ImGui_Key_RightArrow),
    up: held(ImGui_Key_UpArrow), down: held(ImGui_Key_DownArrow), home: once(ImGui_Key_Home),
    ending: once(ImGui_Key_End), escape: once(ImGui_Key_Escape))

proc numberBox(id: string; value: float64; width: float32; typed: var float64): bool =
  ## A box for a number: true once the user has finished typing into it.
  var v = cdouble(value)
  igSetNextItemWidth(width)
  discard igInputDouble(id.cstring, addr v, 0, 0, "%.4g", 0)
  typed = float64(v)
  igIsItemDeactivatedAfterEdit()

proc drawSettings(st: AppState; w: AnalysisWindow; name: string; marks: var Marks;
    res: var PlotWindowsOutput) =
  ## The view's settings and Freeze, on a line that wraps; a change is a
  ## `ckPlotDisplay`.
  var p = w.params
  var frozen = w.frozen
  var changed = false
  let box = round(igCalcTextSize("00000.0", nil, false, -1).x + 2 * igGetStyle().FramePadding.x)
  var typed = 0.0
  template label(text: string) =
    igAlignTextToFramePadding()
    igTextUnformatted(text, nil)
    igSameLine(0, -1)
  case w.view
  of avSpectrogram:
    label("Frame")
    if numberBox("##window", p.windowMs, box, typed) and typed > 0:
      (p.windowMs, changed) = (typed, true)
    marks.mark(name & ".frame")
    tip("Each frame's length (a Hann window): longer resolves frequency finer and time " &
      "coarser (a frame of W ms resolves about 2/W kHz)")
    igSameLine(0, -1)
    label("ms  overlap")
    if numberBox("##overlap", p.overlap, box, typed) and typed >= 0 and typed <= 95:
      (p.overlap, changed) = (typed, true)
    marks.mark(name & ".overlap")
    tip("How much a frame overlaps the next, % (0 to 95)")
    igSameLine(0, -1)
    label("%  floor")
    if numberBox("##floor", p.floorDb, box, typed) and typed < 0:
      (p.floorDb, changed) = (typed, true)
    marks.mark(name & ".floor")
    tip("The lowest dB drawn: the colour map's low end (0 dB is the largest amplitude)")
    igSameLine(0, -1)
    label("dB")
    igSetNextItemWidth(round(igCalcTextSize("Red-white-blue", nil, false, -1).x +
      igGetFrameHeight() + 2 * igGetStyle().FramePadding.x))
    if igBeginCombo("##map", ($p.colourMap).cstring, 0):
      for m in ColourMap:
        if igSelectable_Bool(($m).cstring, m == p.colourMap, 0, ImVec2_c(x: 0, y: 0)) and
            m != p.colourMap:
          (p.colourMap, changed) = (m, true)
      igEndCombo()
    marks.mark(name & ".map")
    tip("The colour map, as density's")
  of avEnvelope: discard
  of avPhase:
    label("Phase where within")
    if numberBox("##within", p.phaseWithinDb, box, typed) and typed > 0:
      (p.phaseWithinDb, changed) = (typed, true)
    marks.mark(name & ".within")
    tip("The phase is drawn where the amplitude is within this many dB of its peak: " &
      "elsewhere it is noise")
    igSameLine(0, -1)
    label("dB of the peak")
    if igCheckbox("Unwrapped", addr p.unwrap): changed = true
    marks.mark(name & ".unwrap")
    tip("On: the phase unwrapped along frequency (a delay is a straight line). Off: within " &
      "-180 to 180 degrees")
  of avCorrelation:
    label("Reference: " & (if w.reference.len > 0: w.reference else: "the first trace"))
    let sel = st.selection
    var first = -1
    for t in sel.selected:
      if first < 0 or t < first: first = t
    igBeginDisabled(first < 0)
    if igSmallButton("The selected trace"):
      (p.reference, changed) = (first, true)
    igEndDisabled()
    marks.mark(name & ".reference selected")
    tip("Correlate against the selected trace (the first, when several are): a pilot, in " &
      "this file or another one open (Sweep0's pilot, say)")
    igSameLine(0, -1)
    igBeginDisabled(p.reference < 0)
    if igSmallButton("The record's pilot"):
      (p.reference, changed) = (-1, true)
    igEndDisabled()
    marks.mark(name & ".reference pilot")
    tip("Correlate against the record's first auxiliary trace (its pilot), else the " &
      "first trace of the window")
    igSameLine(0, -1)
    label("lags ±")
    if numberBox("##lags", p.maxLagMs, box, typed) and typed > 0:
      (p.maxLagMs, changed) = (typed, true)
    marks.mark(name & ".lags")
    tip("The lags shown either side of 0, ms")
    igSameLine(0, -1)
    label("ms")
  if w.view != avEnvelope: igSameLine(0, -1)
  if igCheckbox("Freeze", addr frozen): changed = true
  marks.mark(name & ".freeze")
  tip("On: the window keeps what it shows. Off: it follows the Seismic window's filters " &
    "(and Aux toggle) and the kills of its traces")
  if changed:
    res.commands.add Command(kind: ckPlotDisplay, plot: w.id, plotParams: p,
      plotFrozen: frozen)

proc colourMapOf(ui: var PlotWindowsUi; m: ColourMap): int =
  ## ImPlot's index of density colour map `m`, added once.
  if ui.maps[m] == 0:
    let name = "viewSEG " & $m
    var index = int(ImPlot_GetColormapIndex(name.cstring))
    if index < 0:
      let lut = lutOf(m)
      var cols = newSeq[ImU32](lut.len)
      for i, c in lut: cols[i] = u32(c)
      index = int(ImPlot_AddColormap_U32Ptr(name.cstring, addr cols[0], cint(cols.len), false))
    ui.maps[m] = index + 1
  ui.maps[m] - 1

proc axisBox(dl: ptr ImDrawList; text: string; across: bool; at: float32; pos,
    area: ImVec2_c; t: Theme) =
  ## `text` in a box on the plot's bottom axis (`across`: centred at x `at`)
  ## or its left axis (centred at y `at`), over the tick labels, as the
  ## Seismic window's cursor writes its time.
  let ts = igCalcTextSize(text.cstring, nil, false, -1)
  var lo, hi: ImVec2_c
  if across:
    lo = ImVec2_c(x: round(at - ts.x / 2) - 3, y: pos.y + area.y + 1)
    hi = ImVec2_c(x: lo.x + ts.x + 6, y: lo.y + ts.y + 4)
  else:
    lo = ImVec2_c(x: pos.x - ts.x - 8, y: round(at - ts.y / 2) - 2)
    hi = ImVec2_c(x: pos.x - 1, y: lo.y + ts.y + 4)
  ImDrawList_AddRectFilled(dl, lo, hi, u32(t.roles[rlWindow]), 0, 0)
  ImDrawList_AddRect(dl, lo, hi, u32(t.roles[rlCrosshair]), 0, 1, 0)
  ImDrawList_AddText_Vec2(dl, ImVec2_c(x: lo.x + 3, y: lo.y + 2), u32(t.roles[rlText]),
    text.cstring, nil)

func axisNumber(x: float64): string =
  if abs(x) >= 100 or x == round(x): formatFloat(x, ffDecimal, 1)
  else: formatFloat(x, ffDecimal, 2)

proc drawImage(ui: var PlotWindowsUi; w: AnalysisWindow; name: string; t: Theme;
    size: ImVec2_c; marks: var Marks; focused: bool; res: var PlotWindowsOutput): string =
  ## The image (a spectrogram) in its colour map with its scale beside, the
  ## cursor's lines and values; what the cursor reads.
  result = ""
  let img = w.result.image
  if img.isEmpty: return
  let scaleW = round(igGetFontSize() * 4.5)
  let cmap = ui.colourMapOf(w.params.colourMap)
  ImPlot_PushColormap_PlotColormap(ImPlotColormap(cmap))
  let x0 = img.x0 - img.dx / 2
  let x1 = img.xOf(img.cols - 1) + img.dx / 2
  let y0 = img.y0 - img.dy / 2
  let y1 = img.yOf(img.rows - 1) + img.dy / 2
  const flags = ImPlot_Flags_NoLegend.cint or ImPlot_Flags_NoMenus.cint or
    ImPlot_Flags_NoMouseText.cint or ImPlot_Flags_NoTitle.cint
  var under = PlotCursor(x: -1, y: -1)
  if ImPlot_BeginPlot(("##" & name).cstring, ImVec2_c(x: max(80, size.x - scaleW), y: size.y),
      flags):
    ImPlot_SetupAxes(img.xLabel.cstring, img.yLabel.cstring, 0, 0)
    ImPlot_SetupAxesLimits(x0, x1, y0, y1, ImPlot_Cond_Once.cint)
    ImPlot_SetupAxisLimitsConstraints(ImAxis_X1.cint, x0, x1)
    ImPlot_SetupAxisLimitsConstraints(ImAxis_Y1.cint, y0, y1)
    var values = img.topDown
    ImPlot_PlotHeatmap_FloatPtr("##image", addr values[0], cint(img.rows), cint(img.cols),
      cdouble(img.lo), cdouble(img.hi), nil, ImPlotPoint_c(x: x0, y: y0),
      ImPlotPoint_c(x: x1, y: y1), 0)
    let pos = ImPlot_GetPlotPos()
    let area = ImPlot_GetPlotSize()
    marks.markRect(name & ".image", pos, ImVec2_c(x: pos.x + area.x, y: pos.y + area.y))
    if ImPlot_IsPlotHovered():
      let m = ImPlot_GetPlotMousePos(ImAxis_X1.cint, ImAxis_Y1.cint)
      under = img.cellAt(m.x, m.y)
    let c = if w.cursor.held: w.cursor.clamped([img.cols, img.rows]) else: under
    if c.x >= 0:
      let dl = ImPlot_GetPlotDrawList()
      let q = ImPlot_PlotToPixels_double(img.xOf(c.x), img.yOf(c.y), ImAxis_X1.cint,
        ImAxis_Y1.cint)
      let cross = u32(t.roles[rlCrosshair])
      ImDrawList_PushClipRect(dl, pos, ImVec2_c(x: pos.x + area.x, y: pos.y + area.y), true)
      ImDrawList_AddLine(dl, ImVec2_c(x: round(q.x) + 0.5, y: pos.y),
        ImVec2_c(x: round(q.x) + 0.5, y: pos.y + area.y), cross, 1)
      ImDrawList_AddLine(dl, ImVec2_c(x: pos.x, y: round(q.y) + 0.5),
        ImVec2_c(x: pos.x + area.x, y: round(q.y) + 0.5), cross, 1)
      ImDrawList_PopClipRect(dl)
      let fg = igGetForegroundDrawList_ViewportPtr(igGetWindowViewport())
      axisBox(fg, axisNumber(img.xOf(c.x)), true, q.x, pos, area, t)
      axisBox(fg, axisNumber(img.yOf(c.y)), false, q.y, pos, area, t)
      result = img.readingText(c)
    ImPlot_EndPlot()
  igSameLine(0, -1)
  ImPlot_ColormapScale(("dB##" & name).cstring, cdouble(img.lo), cdouble(img.hi),
    ImVec2_c(x: scaleW - igGetStyle().ItemSpacing.x, y: size.y), "%g", 0, ImPlotColormap(cmap))
  ImPlot_PopColormap(1)
  ui.under[w.id] = under
  # The keys, while the window has the focus: a step from where the cursor
  # is held, else from the cell under the pointer.
  let k = keysNow(focused)
  let move = keyMove(k.up, k.down, k.left, k.right, k.home, k.ending)
  if move != cmNone:
    let start = if w.cursor.held: w.cursor
                elif under.x >= 0: under
                else: PlotCursor()
    res.commands.add Command(kind: ckPlotCursor, plot: w.id,
      plotCursor: start.moved(move, [img.cols, img.rows]))
  elif w.cursor.held and k.escape:
    res.commands.add Command(kind: ckPlotCursor, plot: w.id, plotCursor: PlotCursor())
  if w.cursor.held and under.x >= 0 and igGetIO_Nil().MouseDelta.x != 0:
    # the pointer moved over the image: it takes the cursor back
    res.commands.add Command(kind: ckPlotCursor, plot: w.id, plotCursor: PlotCursor())

proc drawBody(ui: var PlotWindowsUi; st: AppState; w: AnalysisWindow; t: Theme;
    marks: var Marks; res: var PlotWindowsOutput) =
  ## A window's contents: its settings, its words, its plots and reading.
  let name = w.markName
  marks.markWindow(name)
  drawSettings(st, w, name, marks, res)
  let r = w.result
  var words = w.label
  if w.filters.len > 0: words.add " · filters: " & w.filters
  if r.leftOut > 0: words.add " · " & $r.leftOut & " left out (killed, dead or unreadable)"
  if w.waiting: words.add " · working it out..."
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextWrapped("%s", words.cstring)
  if r.problem.len > 0: igTextWrapped("%s", ("Nothing to show: " & r.problem).cstring)
  elif r.note.len > 0: igTextWrapped("%s", r.note.cstring)
  igPopStyleColor(1)
  marks.mark(name & ".summary")
  let focused = igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint)
  let lineH = igGetTextLineHeightWithSpacing()
  let avail = igGetContentRegionAvail()
  var text = ""
  if not r.image.isEmpty:
    text = ui.drawImage(w, name, t, ImVec2_c(x: avail.x, y: max(80'f32, avail.y - lineH)),
      marks, focused, res)
  else:
    let plots = r.curvePlots(t)
    var uis = ui.curves.getOrDefault(w.id)
    if uis.len != plots.len: uis.setLen plots.len
    let gap = igGetStyle().ItemSpacing.y
    let each = max(60'f32, (avail.y - lineH - gap * float32(max(plots.len - 1, 0))) /
      float32(max(plots.len, 1)))
    # The cursor: held by the keys in one plot (and at the same x in the
    # plots that share its x axis), else under the pointer.
    let on = clamp(w.cursorOn, 0, max(plots.len - 1, 0))
    func sameXs(a, b: CurvePlot): bool =
      a.xs.len == b.xs.len and (a.xs.len == 0 or (a.xs[0] == b.xs[0] and a.xs[^1] == b.xs[^1]))
    var hoveredOn = -1
    var under = PlotCursor(x: -1, y: -1)
    var moved = false
    for i, p in plots:
      let key = $w.view & $i & $p.xs.len & (if p.xs.len > 0: $p.xs[0] & $p.xs[^1] else: "")
      let held = if w.cursor.held and plots.len > 0 and (i == on or p.sameXs(plots[on])):
                   PlotCursor(held: true, x: w.cursor.x, y: (if i == on: w.cursor.y else: 0))
                 else: PlotCursor()
      let o = uis[i].drawCurvePlot(name & ".plot " & $i, p, t, ImVec2_c(x: avail.x, y: each),
        key, marks, held)
      if o.hovered:
        (hoveredOn, under, moved) = (i, o.under, o.moved)
        text = p.readoutText(o.reading)
      elif held.held and i == on:
        text = p.readoutText(o.reading)
    ui.curves[w.id] = uis
    if w.cursor.held and text.len > 0: text = HeldNote & text
    # The keys: Left / Right a point, Home / End the ends, Up / Down another
    # curve, from where the cursor is held, else from under the pointer.
    let k = keysNow(focused)
    var move = cmNone
    if k.left: move = cmPrevious
    if k.right: move = cmNext
    if k.home: move = cmFirst
    if k.ending: move = cmLast
    if k.up: move = cmUp
    if k.down: move = cmDown
    let at = if w.cursor.held: on elif hoveredOn >= 0: hoveredOn else: 0
    if move != cmNone and at < plots.len and plots[at].xs.len > 0:
      var start = if w.cursor.held: w.cursor
                  elif hoveredOn >= 0 and under.x >= 0: under
                  else: PlotCursor()
      if start.y < 0: start.y = 0
      res.commands.add Command(kind: ckPlotCursor, plot: w.id, plotCursorOn: at,
        plotCursor: start.moved(move, [plots[at].xs.len, plots[at].curves.len]))
    elif w.cursor.held and (k.escape or (hoveredOn >= 0 and moved)):
      res.commands.add Command(kind: ckPlotCursor, plot: w.id, plotCursor: PlotCursor())
  ui.readout[w.id] = text
  igTextUnformatted((if text.len > 0: text else: " ").cstring, nil)
  marks.mark(name & ".readout")

proc drawPlotWindows*(ui: var PlotWindowsUi; st: AppState; t: Theme; scale: float32;
    marks: var Marks; res: var PlotWindowsOutput) =
  ## The analysis windows, each with its close button; the first time one
  ## of a number is shown, beside the middle of the main window, a little
  ## lower and to the right for each number.
  var ids: seq[int] = @[]
  for w in st.plots:
    ids.add w.id
    let vp = igGetMainViewport()
    let step = 28 * scale * float32((w.id - 1) mod 8)
    igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + vp.WorkSize.x / 2 + step,
      y: vp.WorkPos.y + vp.WorkSize.y / 2 + step), ImGui_Cond_FirstUseEver.cint,
      ImVec2_c(x: 0.5, y: 0.5))
    igSetNextWindowSize(ImVec2_c(x: PlotSize[0] * scale, y: PlotSize[1] * scale),
      ImGui_Cond_FirstUseEver.cint)
    var open = true
    if igBegin(w.windowTitle.cstring, addr open, 0):
      ui.drawBody(st, w, t, marks, res)
    igEnd()
    if not open: res.commands.add Command(kind: ckClosePlot, plot: w.id)
  var gone: seq[int] = @[]
  for id in ui.readout.keys:
    if id notin ids: gone.add id
  for id in gone:
    ui.curves.del id
    ui.under.del id
    ui.readout.del id

func readoutOf*(ui: PlotWindowsUi; id: int): string =
  ## What window `id`'s cursor read last frame; "" for nothing (tests).
  ui.readout.getOrDefault(id, "")
