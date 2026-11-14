## The trace panel: the plot window that shows a record, traces across and
## time down, as greyscale density on white "paper", with the display header
## along the top and the window's own controls in a strip above it.
##
## The window reads the panel from `core` and issues `Command`s; it never
## changes the state itself. ImPlot draws the axes and handles pan and zoom;
## each frame the plot's limits and size go to `core` as the panel's view
## (`ckView`), which decides what to read. The density image comes from
## `gpu/density`: the panel's tiles, uploaded once each, drawn into an image
## the size of the plot, shown with ImPlot's image item. Until a tile for the
## new view arrives, the plot keeps drawing the tiles it has, stretched.
##
## Nothing about a plot sits in the main toolbar: the display mode, the
## gain, fit all and the display header's fields are here, in the strip and
## in the plot's context menu (right click).

import std/[math, strutils, tables]
import imguin/cimgui
import ../../core/[geometry, state]
import ../../gpu/density
import ../../view/[displayheader, theme]
import chrome, fonts, icons, menus, style, symbols

const
  PaperBackground* = Rgba(r: 255, g: 255, b: 255, a: 255)
  PaperInk* = Rgba(r: 0, g: 0, b: 0, a: 255)
  modeSymbols: array[DisplayMode, Symbol] = [syDensity, syWiggle, syWigglePositive,
    syWiggleNegative]
  gainChoices = [dgAuto, dgNone, dgTraceBalance, dgAgc]
  menuId = "##plotmenu"
  moreId = "##plotmore"

type
  TracePanelUi* = object
    ## The plot window's own state between frames: its GPU objects and what
    ## it drew last.
    renderer: DensityRenderer
    textures: seq[TileTextures] ## the GPU copies of the panel's tiles, in their order
    gpuError: string ## why it cannot draw; "" when it can
    started: bool
    maxTexture: int ## 0: the GPU's limit (tests set a small one)
    fits: int ## the panel's `fits` last applied to the plot
    drawn: Viewport ## the view of the last image
    labelChars: Table[uint64, int] ## per tile: the longest header label
    dragged: bool ## the right button moved since it went down
    wanted: Viewport ## a view to give the plot next frame (`show`)
    want: bool

  PanelOutput* = object
    ## What the plot window asks for.
    commands*: seq[Command]
    actions*: set[MenuAction]

func isPaper(d: DisplaySettings): bool = d.colours != pcTheme

func caption(f: HeaderField): string =
  ## A header row's name as it stands left of the plot: short, so it fits
  ## beside the time axis.
  case f
  of hfChannel: "chan"
  of hfSrcLine: "S line"
  of hfSrcPoint: "S point"
  of hfCrossline: "xline"
  else: $f

proc startGpu*(tp: var TracePanelUi; getProc: GetProcAddress; maxTexture = 0): string =
  ## Loads the GL functions and makes the density renderer, with the GL
  ## context current. "" when it can draw, else why not (the window then
  ## says so instead of drawing).
  tp.started = true
  tp.maxTexture = maxTexture
  let missing = initGpu(getProc)
  if missing.len > 0:
    tp.gpuError = "OpenGL functions missing: " & missing
    return tp.gpuError
  let (r, err) = newDensityRenderer(greyLut(), maxTexture)
  tp.renderer = r
  tp.gpuError = err
  err

proc stopGpu*(tp: var TracePanelUi) =
  ## Frees the GPU objects, with the GL context still current.
  for tt in tp.textures.mitems: tt.free()
  tp.textures.setLen 0
  if tp.renderer.ready: tp.renderer.free()

proc show*(tp: var TracePanelUi; v: Viewport) =
  ## Gives the plot the limits of `v` next frame, as a pan or zoom by the
  ## user would (its pixel size is the plot's own).
  tp.wanted = v
  tp.want = true

func drawnView*(tp: TracePanelUi): Viewport {.inline.} = tp.drawn
  ## The view of the last density image (for tests).

proc densityImage*(tp: TracePanelUi): (seq[Rgba], int, int) =
  ## The last density image, row by row from the top, and its size (for
  ## tests; with the GL context current).
  let (w, h) = tp.renderer.imageSize
  (tp.renderer.readImage, w, h)

func textureLimit*(tp: TracePanelUi): int {.inline.} = tp.renderer.maxSize
  ## The largest texture side the renderer uses.

proc sync(tp: var TracePanelUi; tiles: openArray[Tile]) =
  ## Uploads the tiles the GPU does not have and frees the ones `core` no
  ## longer keeps, so `textures[i]` is the copy of `tiles[i]`.
  var kept: seq[TileTextures]
  for t in tiles:
    var found = -1
    for i in 0 ..< tp.textures.len:
      if tp.textures[i].id == t.id: found = i
    if found >= 0:
      kept.add move tp.textures[found]
      tp.textures.delete(found)
    else:
      kept.add tp.renderer.upload(t)
  for tt in tp.textures.mitems: tt.free()
  tp.textures = move kept
  var gone: seq[uint64]
  for id in tp.labelChars.keys:
    var live = false
    for t in tiles:
      if t.id == id: live = true
    if not live: gone.add id
  for id in gone: tp.labelChars.del id

proc labelChars(tp: var TracePanelUi; t: Tile): int =
  ## The length of the longest header label of tile `t`.
  if t.id notin tp.labelChars:
    var n = 1
    for row in t.header:
      for v in row: n = max(n, headerText(v).len)
    tp.labelChars[t.id] = n
  tp.labelChars[t.id]

func headerValue(tiles: openArray[Tile]; fields: openArray[HeaderField]; row,
    position: int): (bool, float64) =
  ## The value of header row `row` at `position`, from the newest tile that
  ## has it with these fields.
  for i in countdown(tiles.high, 0):
    let r = tiles[i].request
    if tiles[i].fields == fields and position >= r.first and position <= r.last and
        (position - r.first) mod r.stride == 0:
      return (true, tiles[i].header[row][(position - r.first) div r.stride])
  (false, NaN)

proc button(label: string; t: Theme; marks: var Marks; mark: string): bool =
  result = igButton(label.cstring, ImVec2_c(x: 0, y: 0))
  marks.mark(mark)

proc gainLabel(d: DisplaySettings; kind: GatherKind): string =
  let g = d.effectiveGain(kind)
  result = case g
    of dgAgc: "AGC " & $int(round(d.agcWindowMs)) & " ms"
    of dgTraceBalance: "trace balance"
    else: "none"
  if d.gain == dgAuto: result.add " (auto)"

proc drawGainCombo(p: Panel; t: Theme; res: var PanelOutput) =
  let d = p.layers[0].display
  let label = "Gain: " & gainLabel(d, p.kind)
  igSetNextItemWidth(round(igCalcTextSize(label.cstring, nil, false, -1).x +
    igGetFrameHeight() + 3 * igGetStyle().FramePadding.x))
  if igBeginCombo("##gain", label.cstring, 0):
    for g in gainChoices:
      let text = case g
        of dgAuto: "Automatic: AGC on pre-stack gathers, none on stacked data"
        of dgNone: "None: the samples as they are"
        of dgTraceBalance: "Trace balance: every trace to the same RMS"
        of dgAgc: "AGC, " & $int(round(d.agcWindowMs)) & " ms window"
      if igSelectable_Bool(text.cstring, d.gain == g, 0, ImVec2_c(x: 0, y: 0)) and
          d.gain != g:
        var nd = d
        nd.gain = g
        res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
    igEndCombo()
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(("Display gain, after any processing; amplitudes past the " &
      formatFloat(d.clipPercentile, ffDecimal, 1) & "th percentile are clipped").cstring, nil)
    igEndTooltip()

proc drawHeaderChoice(p: Panel; res: var PanelOutput) =
  ## The display header's fields: automatic, or the ones ticked.
  var auto = p.header.auto
  if igCheckbox("Automatic fields", addr auto):
    res.commands.add Command(kind: ckHeader, panel: p.id,
      header: HeaderChoice(auto: auto, fields: p.shownFields))
  igBeginDisabled(p.header.auto)
  let shown = p.shownFields
  for f in HeaderField:
    var on = f in shown
    let have = f in p.known
    let label = $f & (if have: "" else: "  (not in this file)")
    if igCheckbox(label.cstring, addr on):
      var fields: seq[HeaderField]
      for g in HeaderField:
        if (g == f and on) or (g != f and g in shown): fields.add g
      if fields.len > 0:
        res.commands.add Command(kind: ckHeader, panel: p.id,
          header: HeaderChoice(auto: false, fields: fields))
  igEndDisabled()

proc drawColours(p: Panel; res: var PanelOutput) =
  let d = p.layers[0].display
  for c in [pcPaper, pcTheme]:
    let text = if c == pcPaper: "Paper: white, black traces" else: "Follow the theme"
    if igRadioButton_Bool(text.cstring, d.colours == c) and d.colours != c:
      var nd = d
      nd.colours = c
      res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
  var reversed = d.reversed
  if igCheckbox("Reverse polarity", addr reversed):
    var nd = d
    nd.reversed = reversed
    res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)

proc drawControls(tp: var TracePanelUi; p: Panel; t: Theme; marks: var Marks;
    res: var PanelOutput; fit: var bool) =
  ## The strip at the top of the window.
  let size = round(igGetFontSize() * IconScale + 2 * igGetStyle().FramePadding.y)
  let mode = p.layers[0].display.mode
  for m in DisplayMode:
    let ready = m == dmDensity
    igBeginDisabled(not ready)
    if symbolButton(modeSymbols[m], size, t, marks, selected = m == mode,
        note = (if ready: "" else: " (not available yet)"), markPrefix = "plot.") and
        m != mode:
      var d = p.layers[0].display
      d.mode = m
      res.commands.add Command(kind: ckDisplay, panel: p.id, display: d)
    igEndDisabled()
    igSameLine(0, 2)
  igSameLine(0, 12)
  igSetCursorPosY(igGetCursorPosY() + round((size - igGetFrameHeight()) / 2))
  drawGainCombo(p, t, res)
  igSameLine(0, 8)
  if button(IconFit & "  Fit all", t, marks, "plot.fit"):
    fit = true
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted("Show every trace and the whole record", nil)
    igEndTooltip()
  igSameLine(0, 8)
  if button(IconSettings & "##more", t, marks, "plot.more"):
    igOpenPopup_Str(moreId, 0)
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted("Colours and display header", nil)
    igEndTooltip()
  if igBeginPopup(moreId, 0):
    igSeparatorText("Colours")
    drawColours(p, res)
    igSeparatorText("Display header")
    drawHeaderChoice(p, res)
    igEndPopup()

proc drawStartScreen(t: Theme; marks: var Marks; res: var PanelOutput) =
  ## What the window shows with no file: the ways to open one.
  let avail = igGetContentRegionAvail()
  let big = ImVec2_c(x: round(igGetFontSize() * 14), y: round(igGetFontSize() * 2.6))
  let top = igGetCursorPos()
  igSetCursorPos(ImVec2_c(x: top.x + max(0, (avail.x - big.x) / 2),
    y: top.y + max(0, avail.y / 2 - big.y * 1.6)))
  if igButton((IconOpenFile & "  Open a file...").cstring, big):
    res.actions.incl maOpenFile
  marks.mark("plot.open file")
  igSetCursorPosX(top.x + max(0, (avail.x - big.x) / 2))
  if igButton((IconOpenFolder & "  Open a folder...").cstring, big):
    res.actions.incl maOpenFolder
  marks.mark("plot.open folder")
  let hint = "Ctrl+O opens a file. Files named on the command line open at start."
  let w = igCalcTextSize(hint.cstring, nil, false, -1).x
  igSetCursorPosX(top.x + max(0, (avail.x - w) / 2))
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextUnformatted(hint.cstring, nil)
  igPopStyleColor(1)

proc centredText(text: string; colour: Rgba) =
  let avail = igGetContentRegionAvail()
  let w = igCalcTextSize(text.cstring, nil, false, -1).x
  let at = igGetCursorPos()
  igSetCursorPos(ImVec2_c(x: at.x + max(0, (avail.x - w) / 2), y: at.y + avail.y / 2 - 10))
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour))
  igTextUnformatted(text.cstring, nil)
  igPopStyleColor(1)

proc drawHeader(tp: var TracePanelUi; tiles: openArray[Tile]; fields: openArray[HeaderField];
    stride: int; view: Viewport; layout: PanelLayout; top, plotPos, plotSize: ImVec2_c;
    t: Theme; paper: bool) =
  ## The display header between `top` and the plot: one row per field, the
  ## field's name left of the plot, values over their traces.
  if fields.len == 0 or tiles.len == 0: return
  let dl = igGetWindowDrawList()
  let lineH = igGetTextLineHeight()
  let ink = u32(t.roles[rlText])
  let dim = u32(t.roles[rlTextDim])
  let charW = igCalcTextSize("0", nil, false, -1).x
  let chars = tp.labelChars(tiles[^1])
  let perPos = plotSize.x / max(view.traces.width, 1e-9)
  let step = headerStep(stride, perPos, (float64(chars) + 2) * charW)
  let vis = visiblePositions(layout, view)
  ImDrawList_PushClipRect(dl, ImVec2_c(x: top.x - 200, y: top.y),
    ImVec2_c(x: plotPos.x + plotSize.x, y: plotPos.y), true)
  for i, f in fields:
    let y = top.y + float32(i) * lineH
    let name = caption(f)
    let nw = igCalcTextSize(name.cstring, nil, false, -1).x
    ImDrawList_AddText_Vec2(dl, ImVec2_c(x: plotPos.x - nw - 6, y: y), dim, name.cstring, nil)
    ImDrawList_PushClipRect(dl, ImVec2_c(x: plotPos.x, y: top.y),
      ImVec2_c(x: plotPos.x + plotSize.x, y: plotPos.y), true)
    for pos in labelled(vis, step):
      let (have, v) = headerValue(tiles, fields, i, pos)
      if have:
        let text = headerText(v)
        if text.len > 0:
          let x = plotPos.x + float32((float64(pos) - view.traces.lo) * perPos)
          let w = igCalcTextSize(text.cstring, nil, false, -1).x
          let left = round(x - w / 2)
          if left >= plotPos.x and left + w <= plotPos.x + plotSize.x: # whole labels only
            ImDrawList_AddText_Vec2(dl, ImVec2_c(x: left, y: y), ink, text.cstring, nil)
    ImDrawList_PopClipRect(dl)
  ImDrawList_PopClipRect(dl)
  discard paper

proc drawPlot(tp: var TracePanelUi; st: AppState; k: int; t: Theme; fonts: Fonts;
    marks: var Marks; res: var PanelOutput; fit: bool) =
  ## The display header and the plot of `panels[k]`.
  # Aliases, not copies: a `let` would copy the panel's tiles every frame.
  template p: untyped = st.panels[k]
  template layer: untyped = st.panels[k].layers[0]
  template tiles: untyped = st.tiles(k)
  let fields = p.shownFields
  let paper = layer.display.isPaper
  let lineH = igGetTextLineHeight()
  let headerTop = igGetCursorScreenPos()
  igDummy(ImVec2_c(x: 1, y: float32(fields.len) * lineH + 2))
  let lastPos = float64(p.layout.traces) - 0.5
  let tEnd = p.layout.t0Ms + float64(max(p.layout.samples - 1, 1)) * p.layout.dtMs
  let span = tEnd - p.layout.t0Ms
  if paper:
    ImPlot_PushStyleColor_Vec4(ImPlot_Col_PlotBg.cint, vec4(PaperBackground))
  const flags = ImPlot_Flags_NoTitle.cint or ImPlot_Flags_NoLegend.cint or
    ImPlot_Flags_NoMenus.cint or ImPlot_Flags_NoMouseText.cint
  if ImPlot_BeginPlot("##traces", ImVec2_c(x: -1, y: -1), flags):
    ImPlot_SetupAxis(ImAxis_X1.cint, nil, ImPlot_AxisFlags_NoDecorations.cint or
      ImPlot_AxisFlags_NoMenus.cint)
    ImPlot_SetupAxis(ImAxis_Y1.cint, "Time (ms)", ImPlot_AxisFlags_Invert.cint or
      ImPlot_AxisFlags_NoMenus.cint or ImPlot_AxisFlags_NoGridLines.cint or
      ImPlot_AxisFlags_NoTickMarks.cint) # nothing drawn over the data
    let n = float64(p.layout.traces)
    ImPlot_SetupAxisLimitsConstraints(ImAxis_X1.cint, -0.5 - 0.05 * n, lastPos + 0.05 * n)
    ImPlot_SetupAxisLimitsConstraints(ImAxis_Y1.cint, p.layout.t0Ms - 0.05 * span,
      tEnd + 0.05 * span)
    ImPlot_SetupAxisZoomConstraints(ImAxis_X1.cint, min(4.0, n), 1.1 * n + 1)
    ImPlot_SetupAxisZoomConstraints(ImAxis_Y1.cint, min(span, 8 * p.layout.dtMs),
      1.1 * span + p.layout.dtMs)
    if fit or tp.want or tp.fits != p.fits:
      let v = if fit: fitAll(p.layout, 0, 0) elif tp.want: tp.wanted else: p.view
      ImPlot_SetupAxesLimits(v.traces.lo, v.traces.hi, v.timeMs.lo, v.timeMs.hi,
        ImPlot_Cond_Always.cint)
      tp.fits = p.fits
      tp.want = false
    ImPlot_SetupFinish()
    let lim = ImPlot_GetPlotLimits(ImAxis_X1.cint, ImAxis_Y1.cint)
    let pos = ImPlot_GetPlotPos()
    let size = ImPlot_GetPlotSize()
    let fb = igGetIO_Nil().DisplayFramebufferScale
    let view = Viewport(traces: Span(lo: lim.X.Min, hi: lim.X.Max),
      timeMs: Span(lo: lim.Y.Min, hi: lim.Y.Max), columns: int(round(size.x * fb.x)),
      rows: int(round(size.y * fb.y)))
    if view != p.view:
      res.commands.add Command(kind: ckView, panel: p.id, view: view)
    marks.markRect("plot.data", pos, ImVec2_c(x: pos.x + size.x, y: pos.y + size.y))
    if tp.gpuError.len == 0 and tp.started:
      tp.sync(tiles)
      let bg = if paper: PaperBackground else: t.roles[rlPlotBackground]
      let scale = displayScale(p.clip, layer.display.reversed)
      let tex = tp.renderer.render(view, view.columns, view.rows, bg, scale, tiles,
        tp.textures)
      tp.drawn = view
      if tex != 0:
        ImPlot_PlotImage("##density", ImTextureRef_c(internal_TexID: ImTextureID(tex)),
          ImPlotPoint_c(x: lim.X.Min, y: lim.Y.Min), ImPlotPoint_c(x: lim.X.Max, y: lim.Y.Max),
          # ImPlot puts uv0 at (x min, y max): the bottom, the image's first row
          ImVec2_c(x: 0, y: 0), ImVec2_c(x: 1, y: 1), ImVec4_c(x: 1, y: 1, z: 1, w: 1),
          ImPlot_ItemFlags_NoFit.cint)
    let stride = if p.pending.isEmpty: 1 else: p.pending.stride
    tp.drawHeader(tiles, fields, stride, view, p.layout, headerTop, pos, size, t, paper)
    # The context menu: a right click that did not drag (a drag is a box zoom).
    let io = igGetIO_Nil()
    if igIsMouseClicked_Bool(ImGui_MouseButton_Right.cint, false): tp.dragged = false
    if igIsMouseDragging(ImGui_MouseButton_Right.cint, -1): tp.dragged = true
    if ImPlot_IsPlotHovered() and igIsMouseReleased_Nil(ImGui_MouseButton_Right.cint) and
        not tp.dragged:
      igOpenPopup_Str(menuId, 0)
    discard io
    ImPlot_EndPlot()
  if paper:
    ImPlot_PopStyleColor(1)
  if igBeginPopup(menuId, 0):
    if igMenuItem_Bool((IconFit & "  Fit all").cstring, nil, false, true):
      tp.show(fitAll(p.layout, p.view.columns, p.view.rows))
    igSeparatorText("Display")
    for m in DisplayMode:
      if igMenuItem_Bool(($m).cstring, nil, m == layer.display.mode, m == dmDensity) and
          m != layer.display.mode:
        var d = layer.display
        d.mode = m
        res.commands.add Command(kind: ckDisplay, panel: p.id, display: d)
    igSeparatorText("Colours")
    drawColours(p, res)
    igSeparatorText("Display header")
    drawHeaderChoice(p, res)
    igEndPopup()

proc drawTracePanel*(tp: var TracePanelUi; title: string; st: AppState; panel: PanelId;
    t: Theme; fonts: Fonts; marks: var Marks): PanelOutput =
  ## The plot window of `panel`: its controls, then the start screen, a
  ## note, or the plot. Returns the commands and actions it asks for.
  if igBegin(title.cstring, nil, 0):
    marks.markWindow("plot")
    let k = st.findPanel(panel)
    if k < 0 or st.panels[k].layers.len == 0:
      drawStartScreen(t, marks, result)
    else:
      template p: untyped = st.panels[k]
      var fit = false
      tp.drawControls(p, t, marks, result, fit)
      let source = p.layers[0].source
      let s = if source.kind == lsRecord: st.findSession(source.file) else: -1
      if tp.gpuError.len > 0:
        centredText("The plot cannot be drawn: " & tp.gpuError, t.roles[rlError])
      elif not p.laidOut:
        centredText("Reading " & (if s >= 0: st.sessions[s].name else: "the file") & "...",
          t.roles[rlTextDim])
      elif p.layout.traces == 0:
        centredText("This gather has no traces the trace filter shows.", t.roles[rlTextDim])
      else:
        tp.drawPlot(st, k, t, fonts, marks, result, fit)
  igEnd()
