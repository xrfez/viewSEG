## The trace panel: the plot window that shows a record, traces across and
## time down, as greyscale density on white "paper", with the display header
## along the top and the window's own controls in a strip above it.
##
## The window reads the panel from `core` and issues `Command`s; it never
## changes the state itself. ImPlot only draws the axes: the window handles
## the mouse and keys itself (docs/plot-window.md, "The plot") and moves the
## view with `core/zoom`: wheel zoom about the cursor (Ctrl: time only,
## Shift or the sideways wheel: traces only), `+` / `-`, Ctrl + arrows for
## one axis, drag to pan (left or middle button), right drag to zoom to a
## box, arrows to pan, Ctrl + 0 to fit, Backspace or Alt + Left for back,
## Esc to cancel a drag, and the scroll bars (`plotbars`) beside the plot
## when part of the data is out of view. No view ever shows anything past
## the data, and a new plot size keeps the scale from the top-left corner
## (`core/zoom`). Each new view goes to `core` (`ckView`), which
## decides what to read; the first view of a gesture is sent with
## `remember`, so back returns to the view before it.
##
## The scale boxes state the view as traces per inch and ms per inch (or per
## cm, or inches per second: `core/scales`), at the pixels per inch of the
## monitor the window is on (96 times its display scale unless it is
## calibrated, in the "more" popover). Typing a value sets the zoom; every
## other zoom updates them.
##
## The density image comes from `gpu/density`: the panel's tiles, uploaded
## once each, drawn into an image the size of the plot, shown with ImPlot's
## image item. Until a tile for the new view arrives, the plot keeps drawing
## the tiles it has, stretched. What lies under the mouse (`core/pick`) goes
## back to the caller for the status bar.
##
## Nothing about a plot sits in the main toolbar: the display mode, the
## gain (`plotgain`: the type and the amount in dB), the scales, zoom, fit,
## back, the trace order (`plotsort`: the sort buttons, and the user's own
## keys from the menu) and the display header's fields are here, in the
## strip (which wraps in a narrow window) and in the plot's context menu
## (right click).

import std/[math, strutils, tables]
import imguin/cimgui
import ../../core/[geometry, state]
import ../../gpu/density
import ../../view/[displayheader, theme]
import chrome, dpi, fonts, icons, menus, plotbars, plotgain, plotsort, style, symbols

const
  PaperBackground* = Rgba(r: 255, g: 255, b: 255, a: 255)
  PaperInk* = Rgba(r: 0, g: 0, b: 0, a: 255)
  modeSymbols: array[DisplayMode, Symbol] = [syDensity, syWiggle, syWigglePositive,
    syWiggleNegative]
  menuId = "##plotmenu"
  moreId = "##plotmore"
  burstSeconds = 0.6   ## wheel turns or key presses closer than this are one gesture
  boxMinPixels = 4'f32 ## a box zoom narrower than this zooms the other axis only

type
  DragKind = enum
    dkNone, dkPan, dkBox

  Drag = object
    ## A mouse button held down over the plot.
    kind: DragKind
    button: cint
    press: ImVec2_c ## where it went down, in ImGui's coordinates
    start: Viewport ## the view then
    moved: bool     ## the pointer moved past ImGui's drag threshold

  Gesture = enum
    gsNone, gsWheel, gsKeyZoom, gsKeyPan, gsPage, gsBarWheel

  ViewAskKind = enum
    vaNone, vaFit, vaZoomIn, vaZoomOut, vaTraceScale, vaTimeScale

  ViewAsk = object
    ## A change of view asked for by the controls.
    kind: ViewAskKind
    value: float64 ## the scale typed

  ScaleBox = object
    text: array[24, char] ## what the box holds while it is edited
    editing: bool

  CalibrationUi = object
    ## The calibration controls' values between frames.
    diagonal: cdouble = 24    ## inches
    rulerPx: cfloat           ## the bar's length in framebuffer pixels; 0 until shown
    rulerLength: cdouble = 10 ## what the bar measures on a ruler
    rulerUnit: LengthUnit = luCm

  TracePanelUi* = object
    ## The plot window's own state between frames: its GPU objects, the
    ## view it shows, the gesture in progress and what it drew last.
    renderer: DensityRenderer
    textures: seq[TileTextures] ## the GPU copies of the panel's tiles, in their order
    gpuError: string ## why it cannot draw; "" when it can
    started: bool
    maxTexture: int ## 0: the GPU's limit (tests set a small one)
    cur: Viewport ## the view the plot shows, with the plot's size last frame
    jumps: int ## the panel's `jumps` last followed
    drawn: Viewport ## the view of the last image
    labelChars: Table[uint64, int] ## per tile: the longest header label
    drag: Drag
    bars: ScrollBars
    gesture: Gesture ## the last wheel or key gesture, and when
    gestureAt: float64
    wanted: Viewport ## a view to give the plot next frame (`show`)
    want: bool
    traceBox, timeBox: ScaleBox
    calib: CalibrationUi
    sortKeys: SortKeysUi
    stripWidths: array[6, float32] ## the strip's groups as drawn last frame

  PanelOutput* = object
    ## What the plot window asks for.
    commands*: seq[Command]
    actions*: set[MenuAction]
    pick*: Pick         ## what lies under the mouse; `noPick()` when it is not over the plot
    notes*: seq[string] ## warnings for the log (a scale that is not a number)

func isPaper(d: DisplaySettings): bool = d.colours != pcTheme

func caption(f: HeaderField): string =
  ## A header row's name as it stands left of the plot: short, so it fits
  ## beside the time axis.
  case f
  of hfComponent: "comp"
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

func scaleTexts*(tp: TracePanelUi): (string, string) =
  ## What the trace and time scale boxes hold (for tests).
  var a, b: string
  for c in tp.traceBox.text:
    if c == '\0': break
    a.add c
  for c in tp.timeBox.text:
    if c == '\0': break
    b.add c
  (a, b)

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

proc tip(text: string) =
  ## The last item's tooltip.
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc fill(box: var ScaleBox; text: string) =
  let n = min(text.len, box.text.len - 1)
  for i in 0 ..< n: box.text[i] = text[i]
  box.text[n] = '\0'

func typed(box: ScaleBox): string =
  for c in box.text:
    if c == '\0': break
    result.add c

proc scaleBox(box: var ScaleBox; id, units, tipText: string; value: float64;
    marks: var Marks; mark: string): bool =
  ## A box showing `value`, its units after it. True when the user has just
  ## finished typing into it (Enter, or clicking away): `box.typed` holds
  ## what they typed.
  if not box.editing: box.fill(significant(value, 4))
  let style = igGetStyle()
  igSetNextItemWidth(round(igCalcTextSize("0000.00", nil, false, -1).x +
    2 * style.FramePadding.x))
  discard igInputText(id.cstring, cast[cstring](addr box.text[0]), csize_t(box.text.len),
    ImGui_InputTextFlags_CharsScientific.cint or ImGui_InputTextFlags_AutoSelectAll.cint,
    nil, nil)
  box.editing = igIsItemActive()
  result = igIsItemDeactivatedAfterEdit()
  marks.mark(mark)
  tip(tipText)
  igSameLine(0, 4)
  igTextUnformatted(units.cstring, nil)

proc askScale(box: ScaleBox; kind: ViewAskKind; what: string; ask: var ViewAsk;
    res: var PanelOutput) =
  ## The view asked for by a value typed into `box`, or a note why not.
  let text = box.typed.strip
  var v = NaN
  try:
    v = parseFloat(text)
  except ValueError:
    discard
  if v > 0 and v < Inf:
    ask = ViewAsk(kind: kind, value: v)
  else:
    res.notes.add "The " & what & " needs a positive number, not \"" & text & "\"."

func lengthName(u: LengthUnit): string =
  if u == luInch: "inch" else: "cm"

proc drawScaleSettings(tp: var TracePanelUi; st: AppState; res: var PanelOutput;
    ppi: float64; mon: MonitorInfo) =
  ## The scale units, and the calibration of the monitor the window is on.
  var s = st.settings
  igTextUnformatted("Scales per", nil)
  for u in LengthUnit:
    igSameLine(0, -1)
    if igRadioButton_Bool(lengthName(u).cstring, s.scale.length == u) and
        s.scale.length != u:
      s.scale.length = u
      res.commands.add Command(kind: ckSettings, settings: s)
  var speed = s.scale.speed
  if igCheckbox(("Time as speed (" & $s.scale.length & "/s, not ms/" & $s.scale.length &
      ")").cstring, addr speed):
    s.scale.speed = speed
    res.commands.add Command(kind: ckSettings, settings: s)
  igSeparatorText("Screen")
  let cal = s.calibration(mon.name)
  igTextUnformatted((mon.name & ": " & formatFloat(ppi, ffDecimal, 1) & " pixels per inch " &
    (if cal.isNaN: "(assumed: 96 x the display scale, " &
      $int(round(mon.displayScale * 100)) & " %)" else: "(calibrated)")).cstring, nil)
  let style = igGetStyle()
  let numberWidth = round(igCalcTextSize("00000.0", nil, false, -1).x + 2 * style.FramePadding.x)
  # from the monitor's diagonal
  igBeginDisabled(mon.widthPx <= 0 or mon.heightPx <= 0)
  igSetNextItemWidth(numberWidth)
  discard igInputDouble("##diagonal", addr tp.calib.diagonal, 0, 0, "%.1f", 0)
  igSameLine(0, 4)
  igTextUnformatted("inch diagonal", nil)
  igSameLine(0, -1)
  if igButton("Use the diagonal", ImVec2_c(x: 0, y: 0)):
    try:
      s.calibrate(mon.name, ppiFromDiagonal(mon.widthPx, mon.heightPx, tp.calib.diagonal))
      res.commands.add Command(kind: ckSettings, settings: s)
    except ValueError as e:
      res.notes.add "Cannot calibrate the screen: " & e.msg & "."
  tip("The picture's size corner to corner, as the monitor's specification gives it")
  igEndDisabled()
  # by matching a bar to a ruler
  let fb = igGetIO_Nil().DisplayFramebufferScale.x
  if not (tp.calib.rulerPx > 0):
    tp.calib.rulerPx = cfloat(ppi * (if tp.calib.rulerUnit == luInch: tp.calib.rulerLength
      else: tp.calib.rulerLength / CmPerInch))
  igTextUnformatted("Or hold a ruler to the screen and make this bar", nil)
  igSetNextItemWidth(numberWidth)
  discard igInputDouble("##rulerlength", addr tp.calib.rulerLength, 0, 0, "%.1f", 0)
  for u in LengthUnit:
    igSameLine(0, -1)
    if igRadioButton_Bool(($u & "##ruler").cstring, tp.calib.rulerUnit == u):
      tp.calib.rulerUnit = u
  igSameLine(0, -1)
  igTextUnformatted("long:", nil)
  igSetNextItemWidth(round(igGetFontSize() * 24))
  discard igSliderFloat("##rulerpx", addr tp.calib.rulerPx, 50, 2400, "%.0f pixels",
    ImGui_SliderFlags_AlwaysClamp.cint)
  let dl = igGetWindowDrawList()
  let at = igGetCursorScreenPos()
  let w = tp.calib.rulerPx / max(fb, 0.01)
  let h = round(igGetFontSize() * 0.6)
  let ink = igGetColorU32_Col(ImGui_Col_Text.cint, 1)
  ImDrawList_AddRectFilled(dl, ImVec2_c(x: at.x, y: at.y + h / 3),
    ImVec2_c(x: at.x + w, y: at.y + 2 * h / 3), ink, 0, 0)
  for x in [at.x, at.x + w]:
    ImDrawList_AddLine(dl, ImVec2_c(x: x, y: at.y), ImVec2_c(x: x, y: at.y + h), ink, 1)
  igDummy(ImVec2_c(x: w + 1, y: h))
  if igButton("Use the bar", ImVec2_c(x: 0, y: 0)):
    try:
      s.calibrate(mon.name, ppiFromRuler(tp.calib.rulerPx, tp.calib.rulerLength,
        tp.calib.rulerUnit))
      res.commands.add Command(kind: ckSettings, settings: s)
    except ValueError as e:
      res.notes.add "Cannot calibrate the screen: " & e.msg & "."
  if not cal.isNaN:
    igSameLine(0, -1)
    if igButton("Forget the calibration", ImVec2_c(x: 0, y: 0)):
      s.calibrate(mon.name, NaN)
      tp.calib.rulerPx = 0
      res.commands.add Command(kind: ckSettings, settings: s)

template stripGroup(tp: var TracePanelUi; i: int; right, spacing, lift: float32;
    body: untyped) =
  ## Group `i` of the strip, its controls `lift` below the top of its line,
  ## on the line of the group before it when it fits left of `right` (its
  ## width as drawn last frame), else on a new line: the strip wraps, so the
  ## window never needs to scroll.
  if i > 0 and igGetItemRectMax().x + spacing + tp.stripWidths[i] <= right:
    igSameLine(0, spacing)
  igBeginGroup()
  if lift > 0: # a gap item, so every control of the group starts below it
    igPushStyleVar_Vec2(ImGui_StyleVar_ItemSpacing.cint,
      ImVec2_c(x: igGetStyle().ItemSpacing.x, y: 0))
    igDummy(ImVec2_c(x: 0, y: lift))
    igPopStyleVar(1)
  body
  igEndGroup()
  tp.stripWidths[i] = igGetItemRectSize().x

proc drawControls(tp: var TracePanelUi; st: AppState; p: Panel; t: Theme; marks: var Marks;
    res: var PanelOutput; ask: var ViewAsk; ppi: float64; mon: MonitorInfo) =
  ## The strip at the top of the window, in groups that wrap onto more lines
  ## when the window is narrow.
  let size = round(igGetFontSize() * IconScale + 2 * igGetStyle().FramePadding.y)
  let lift = round((size - igGetFrameHeight()) / 2) # centres a text control on the symbols
  let right = igGetCursorScreenPos().x + igGetContentRegionAvail().x
  let mode = p.layers[0].display.mode
  tp.stripGroup(0, right, 0, 0):
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
      if m != DisplayMode.high: igSameLine(0, 2)
  tp.stripGroup(1, right, 12, lift):
    drawGainControls(p, t, marks, res.commands, res.notes)
  # the scales
  let u = st.settings.scale
  let per = lengthName(u.length)
  tp.stripGroup(2, right, 14, lift):
    if tp.traceBox.scaleBox("##tracescale", traceLabel(u), "Traces per " & per &
        ": type a value and press Enter", traceScale(tp.cur, ppi, u), marks, "plot.trace scale"):
      askScale(tp.traceBox, vaTraceScale, "trace scale", ask, res)
    igSameLine(0, 10)
    let timeTip = if u.speed: per & "es per second" else: "Milliseconds per " & per
    if tp.timeBox.scaleBox("##timescale", timeLabel(u), timeTip & ": type a value and " &
        "press Enter", timeScale(tp.cur, ppi, u), marks, "plot.time scale"):
      askScale(tp.timeBox, vaTimeScale, "time scale", ask, res)
  # zoom, fit, back
  tp.stripGroup(3, right, 14, lift):
    if button(IconZoomOut & "##zoomout", t, marks, "plot.zoom out"):
      ask = ViewAsk(kind: vaZoomOut)
    tip("Zoom out (-, or the wheel)")
    igSameLine(0, 2)
    if button(IconZoomIn & "##zoomin", t, marks, "plot.zoom in"): ask = ViewAsk(kind: vaZoomIn)
    tip("Zoom in (+, or the wheel; Ctrl: time only, Shift: traces only)")
    igSameLine(0, 2)
    if button(IconFit & "##fit", t, marks, "plot.fit"): ask = ViewAsk(kind: vaFit)
    tip("Fit all: every trace and the whole record (Ctrl+0)")
    igSameLine(0, 2)
    igBeginDisabled(p.back.len == 0)
    if button(IconPrevious & "##back", t, marks, "plot.back"):
      res.commands.add Command(kind: ckBack, panel: p.id)
    igEndDisabled()
    if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
        ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
      igTextUnformatted("Back to the view before (Backspace, Alt+Left)", nil)
      igEndTooltip()
  tp.stripGroup(4, right, 14, lift):
    drawSortButtons(p, t, marks, res.commands)
  tp.stripGroup(5, right, 8, lift):
    if button(IconSettings & "##more", t, marks, "plot.more"):
      igOpenPopup_Str(moreId, 0)
    tip("Colours, display header, scale units and screen calibration")
  if igBeginPopup(moreId, 0):
    igSeparatorText("Colours")
    drawColours(p, res)
    igSeparatorText("Display header")
    drawHeaderChoice(p, res)
    igSeparatorText("Scales")
    tp.drawScaleSettings(st, res, ppi, mon)
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

proc burst(tp: var TracePanelUi; g: Gesture): bool =
  ## Whether a wheel turn or key press of kind `g` starts a new gesture (for
  ## back): another kind, or a pause since the last one. Notes it.
  let now = igGetTime()
  result = tp.gesture != g or now - tp.gestureAt > burstSeconds
  tp.gesture = g
  tp.gestureAt = now

func wheelOf(io: ptr ImGuiIO): (float64, set[Axis]) =
  ## Wheel notches this frame and the axes they zoom: both; Ctrl, time
  ## only; Shift or the sideways wheel, traces only.
  if io.MouseWheel != 0:
    let axes = if io.KeyCtrl: {axTime} elif io.KeyShift: {axTraces} else: BothAxes
    (float64(io.MouseWheel), axes)
  elif io.MouseWheelH != 0: (float64(io.MouseWheelH), {axTraces})
  else: (0.0, {})

func clampTo(p: ImVec2_c; r: Rect): Vec2 =
  vec2(clamp(p.x, r.pos.x, r.pos.x + r.size.x), clamp(p.y, r.pos.y, r.pos.y + r.size.y))

proc handleMouse(tp: var TracePanelUi; after: var Viewport; view: Viewport; plot: Rect;
    lim: ViewLimits; hovered: bool; t: Theme; remember, menu: var bool) =
  ## The wheel and the buttons over the plot (the invisible button just
  ## drawn over it).
  let io = igGetIO_Nil()
  let mouse = io.MousePos
  if hovered:
    let (notches, axes) = wheelOf(io)
    if notches != 0 and axes.card > 0:
      after = after.zoomed(pow(WheelStep, notches), view.dataAt(plot, vec2(mouse.x, mouse.y)),
        axes, lim)
      if tp.burst(gsWheel): remember = true
      if tp.drag.kind == dkPan: # go on dragging from here
        tp.drag.start = after
        tp.drag.press = mouse
  if igIsItemActivated():
    for b in [ImGui_MouseButton_Left, ImGui_MouseButton_Middle, ImGui_MouseButton_Right]:
      if tp.drag.kind == dkNone and igIsMouseClicked_Bool(b.cint, false):
        tp.drag = Drag(kind: (if b == ImGui_MouseButton_Right: dkBox else: dkPan),
          button: b.cint, press: mouse, start: after)
  if tp.drag.kind == dkNone: return
  let moved = vec2(mouse.x - tp.drag.press.x, mouse.y - tp.drag.press.y)
  if not tp.drag.moved and max(abs(moved.x), abs(moved.y)) > io.MouseDragThreshold:
    tp.drag.moved = true
    if tp.drag.kind == dkPan:
      remember = true
      tp.gesture = gsNone
  let down = igIsMouseDown_Nil(tp.drag.button)
  case tp.drag.kind
  of dkNone: discard
  of dkPan:
    if tp.drag.moved:
      after = dragged(tp.drag.start, plot, moved, lim)
      igSetMouseCursor(ImGui_MouseCursor_ResizeAll.cint)
    if not down: tp.drag = Drag()
  of dkBox:
    let a = clampTo(tp.drag.press, plot)
    let b = clampTo(mouse, plot)
    if tp.drag.moved and down:
      let dl = igGetWindowDrawList()
      let (lo, hi) = (ImVec2_c(x: min(a.x, b.x), y: min(a.y, b.y)),
        ImVec2_c(x: max(a.x, b.x), y: max(a.y, b.y)))
      ImDrawList_AddRectFilled(dl, lo, hi, u32(withAlpha(t.roles[rlAccent], 40)), 0, 0)
      ImDrawList_AddRect(dl, lo, hi, u32(t.roles[rlAccent]), 0, 1.5, 0)
    if not down:
      if tp.drag.moved:
        var axes: set[Axis]
        if abs(a.x - b.x) >= boxMinPixels: axes.incl axTraces
        if abs(a.y - b.y) >= boxMinPixels: axes.incl axTime
        if axes.card > 0:
          after = view.boxed(view.dataAt(plot, a), view.dataAt(plot, b), axes, lim)
          remember = true
          tp.gesture = gsNone
      elif hovered:
        menu = true # a right click: the context menu
      tp.drag = Drag()

proc handleKeys(tp: var TracePanelUi; after: var Viewport; view: Viewport; plot: Rect;
    lim: ViewLimits; hovered: bool; p: Panel; remember: var bool; res: var PanelOutput) =
  ## The plot's keys, while its window has the focus (docs/plot-window.md).
  let io = igGetIO_Nil()
  if io.WantTextInput: return # typing into a box
  template held(chord: cint): bool = igShortcut_Nil(chord, ImGui_InputFlags_Repeat.cint)
  template once(chord: cint): bool = igShortcut_Nil(chord, 0)
  const
    ctrl = ImGui_Mod_Ctrl.cint
    shift = ImGui_Mod_Shift.cint
    alt = ImGui_Mod_Alt.cint
  let zoomIn = held(ImGui_Key_Equal.cint) or held(shift or ImGui_Key_Equal.cint) or
    held(ImGui_Key_KeypadAdd.cint)
  let zoomOut = held(ImGui_Key_Minus.cint) or held(ImGui_Key_KeypadSubtract.cint)
  let timeIn = held(ctrl or ImGui_Key_UpArrow.cint)
  let timeOut = held(ctrl or ImGui_Key_DownArrow.cint)
  let tracesIn = held(ctrl or ImGui_Key_RightArrow.cint)
  let tracesOut = held(ctrl or ImGui_Key_LeftArrow.cint)
  let at = if hovered: view.dataAt(plot, vec2(io.MousePos.x, io.MousePos.y)) else: after.centre
  var zooms: seq[(float64, set[Axis])]
  if zoomIn: zooms.add (KeyStep, BothAxes)
  if zoomOut: zooms.add (1 / KeyStep, BothAxes)
  if timeIn: zooms.add (KeyStep, {axTime})
  if timeOut: zooms.add (1 / KeyStep, {axTime})
  if tracesIn: zooms.add (KeyStep, {axTraces})
  if tracesOut: zooms.add (1 / KeyStep, {axTraces})
  for (factor, axes) in zooms:
    after = after.zoomed(factor, at, axes, lim)
  if zooms.len > 0 and tp.burst(gsKeyZoom): remember = true
  var fx, fy = 0.0
  for (key, dx, dy) in [(ImGui_Key_LeftArrow, -1.0, 0.0), (ImGui_Key_RightArrow, 1.0, 0.0),
      (ImGui_Key_UpArrow, 0.0, -1.0), (ImGui_Key_DownArrow, 0.0, 1.0)]:
    if held(key.cint):
      fx += dx * PanStep
      fy += dy * PanStep
    if held(shift or key.cint):
      fx += dx
      fy += dy
  if fx != 0 or fy != 0:
    after = after.stepped(fx, fy, lim)
    if tp.burst(gsKeyPan): remember = true
  if once(ctrl or ImGui_Key_0.cint) or once(ctrl or ImGui_Key_Keypad0.cint):
    after = fitAll(p.layout, after.columns, after.rows)
    remember = true
    tp.gesture = gsNone
  if once(ImGui_Key_Backspace.cint) or once(alt or ImGui_Key_LeftArrow.cint):
    res.commands.add Command(kind: ckBack, panel: p.id)
  gainKeys(p, res.commands)
  if once(ImGui_Key_Escape.cint):
    if tp.drag.kind != dkNone:
      if tp.drag.kind == dkPan and tp.drag.moved: after = tp.drag.start
      tp.drag = Drag()
    else:
      discard tp.bars.cancel(after)

proc drawPlot(tp: var TracePanelUi; st: AppState; k: int; t: Theme; fonts: Fonts;
    marks: var Marks; res: var PanelOutput; ask: ViewAsk; ppi: float64) =
  ## The display header and the plot of `panels[k]`, and the mouse and keys
  ## over it.
  # Aliases, not copies: a `let` would copy the panel's tiles every frame.
  template p: untyped = st.panels[k]
  template layer: untyped = st.panels[k].layers[0]
  template tiles: untyped = st.tiles(k)
  let lim = limitsOf(p.layout)
  let fields = p.shownFields
  let paper = layer.display.isPaper
  let lineH = igGetTextLineHeight()
  let headerTop = igGetCursorScreenPos()
  igDummy(ImVec2_c(x: 1, y: float32(fields.len) * lineH + 2))
  # This frame's view: what `core` set itself (back, a new gather), else
  # what a control or a test asked for, else last frame's.
  var remember = false
  if tp.jumps != p.jumps:
    tp.cur = p.view
    tp.jumps = p.jumps
    tp.drag = Drag()
  var next = tp.cur
  if tp.want:
    next.traces = tp.wanted.traces
    next.timeMs = tp.wanted.timeMs
    tp.want = false
    remember = true
  let units = st.settings.scale
  case ask.kind
  of vaNone: discard
  of vaFit: next = fitAll(p.layout, next.columns, next.rows)
  of vaZoomIn: next = next.zoomed(KeyStep, next.centre, BothAxes, lim)
  of vaZoomOut: next = next.zoomed(1 / KeyStep, next.centre, BothAxes, lim)
  of vaTraceScale: next = withTraceScale(next, ask.value, ppi, units, lim)
  of vaTimeScale: next = withTimeScale(next, ask.value, ppi, units, lim)
  case ask.kind
  of vaNone: discard
  of vaZoomIn, vaZoomOut: (if tp.burst(gsKeyZoom): remember = true)
  else:
    remember = true
    tp.gesture = gsNone
  next = kept(next, lim)
  if paper:
    ImPlot_PushStyleColor_Vec4(ImPlot_Col_PlotBg.cint, vec4(PaperBackground))
  # ImPlot only draws: the mouse and keys are handled below.
  const flags = ImPlot_Flags_NoTitle.cint or ImPlot_Flags_NoLegend.cint or
    ImPlot_Flags_NoMenus.cint or ImPlot_Flags_NoMouseText.cint or ImPlot_Flags_NoInputs.cint
  var menu = false
  # Room for the scroll bars is always kept, so the plot does not move or
  # change size when one appears.
  let avail = igGetContentRegionAvail()
  let room = barRoom()
  if ImPlot_BeginPlot("##traces", ImVec2_c(x: max(1, avail.x - room.x),
      y: max(1, avail.y - room.y)), flags):
    ImPlot_SetupAxis(ImAxis_X1.cint, nil, ImPlot_AxisFlags_NoDecorations.cint or
      ImPlot_AxisFlags_NoMenus.cint)
    # Tick values only: the unit is in the ms/in box and the status bar.
    ImPlot_SetupAxis(ImAxis_Y1.cint, nil, ImPlot_AxisFlags_Invert.cint or
      ImPlot_AxisFlags_NoMenus.cint or ImPlot_AxisFlags_NoGridLines.cint or
      ImPlot_AxisFlags_NoTickMarks.cint) # nothing drawn over the data
    ImPlot_SetupAxesLimits(next.traces.lo, next.traces.hi, next.timeMs.lo, next.timeMs.hi,
      ImPlot_Cond_Always.cint)
    ImPlot_SetupFinish()
    let lim2 = ImPlot_GetPlotLimits(ImAxis_X1.cint, ImAxis_Y1.cint)
    let pos = ImPlot_GetPlotPos()
    let size = ImPlot_GetPlotSize()
    let fb = igGetIO_Nil().DisplayFramebufferScale
    var view = next
    view.columns = int(round(size.x * fb.x))
    view.rows = int(round(size.y * fb.y))
    marks.markRect("plot.data", pos, ImVec2_c(x: pos.x + size.x, y: pos.y + size.y))
    if tp.gpuError.len == 0 and tp.started:
      tp.sync(tiles)
      let bg = if paper: PaperBackground else: t.roles[rlPlotBackground]
      let scale = displayScale(p.reference, layer.display.gainDb, layer.display.reversed)
      let shown = Viewport(traces: Span(lo: lim2.X.Min, hi: lim2.X.Max),
        timeMs: Span(lo: lim2.Y.Min, hi: lim2.Y.Max), columns: view.columns, rows: view.rows)
      let tex = tp.renderer.render(shown, shown.columns, shown.rows, bg, scale, tiles,
        tp.textures)
      tp.drawn = shown
      if tex != 0:
        ImPlot_PlotImage("##density", ImTextureRef_c(internal_TexID: ImTextureID(tex)),
          ImPlotPoint_c(x: lim2.X.Min, y: lim2.Y.Min),
          ImPlotPoint_c(x: lim2.X.Max, y: lim2.Y.Max),
          # ImPlot puts uv0 at (x min, y max): the bottom, the image's first row
          ImVec2_c(x: 0, y: 0), ImVec2_c(x: 1, y: 1), ImVec4_c(x: 1, y: 1, z: 1, w: 1),
          ImPlot_ItemFlags_NoFit.cint)
    let stride = if p.pending.isEmpty: 1 else: p.pending.stride
    tp.drawHeader(tiles, fields, stride, view, p.layout, headerTop, pos, size, t, paper)
    ImPlot_EndPlot()
    if st.sorting(k): # the old order stays drawn until the new one comes
      let dl = igGetWindowDrawList()
      let text = if layer.order.len == 0: "Back to the file's order..."
                 else: "Sorting by " & describe(layer.order) & "..."
      let ts = igCalcTextSize(text.cstring, nil, false, -1)
      let pad = igGetStyle().FramePadding
      let at = ImVec2_c(x: pos.x + 6, y: pos.y + 6)
      ImDrawList_AddRectFilled(dl, at, ImVec2_c(x: at.x + ts.x + 2 * pad.x,
        y: at.y + ts.y + 2 * pad.y), u32(t.roles[rlPopup]), igGetStyle().FrameRounding, 0)
      ImDrawList_AddText_Vec2(dl, ImVec2_c(x: at.x + pad.x, y: at.y + pad.y),
        u32(t.roles[rlText]), text.cstring, nil)
      marks.markRect("plot.sorting", at, ImVec2_c(x: at.x + ts.x + 2 * pad.x,
        y: at.y + ts.y + 2 * pad.y))
    # The mouse and keys, over the plot's data area.
    let plot = Rect(pos: vec2(pos.x, pos.y), size: vec2(size.x, size.y))
    igSetCursorScreenPos(pos)
    discard igInvisibleButton("##plotinput", size, ImGui_ButtonFlags_MouseButtonLeft.cint or
      ImGui_ButtonFlags_MouseButtonRight.cint or ImGui_ButtonFlags_MouseButtonMiddle.cint)
    let hovered = igIsItemHovered(0)
    # A new plot size keeps the scale (or the whole data) from the top left.
    var after = if view.columns != next.columns or view.rows != next.rows:
        next.resized(view.columns, view.rows, lim)
      else: view
    tp.handleMouse(after, view, plot, lim, hovered, t, remember, menu)
    case tp.bars.drawScrollBars(after, view, pos, size, lim, t, marks)
    of beNone, beDrag: discard
    of beGrab:
      remember = true
      tp.gesture = gsNone
    of bePage: (if tp.burst(gsPage): remember = true)
    of beWheel: (if tp.burst(gsBarWheel): remember = true)
    tp.handleKeys(after, view, plot, lim, hovered, p, remember, res)
    if hovered:
      let m = igGetIO_Nil().MousePos
      res.pick = pick(tiles, p.layout, view, plot, vec2(m.x, m.y))
    tp.cur = after
    if after != p.view:
      res.commands.add Command(kind: ckView, panel: p.id, view: after, remember: remember)
  if paper:
    ImPlot_PopStyleColor(1)
  var sortKeys = false
  if menu:
    igOpenPopup_Str(menuId, 0)
  if igBeginPopup(menuId, 0):
    if igMenuItem_Bool((IconFit & "  Fit all").cstring, "Ctrl+0", false, true):
      tp.show(fitAll(p.layout, p.view.columns, p.view.rows))
    if igMenuItem_Bool((IconPrevious & "  Back").cstring, "Backspace", false, p.back.len > 0):
      res.commands.add Command(kind: ckBack, panel: p.id)
    igSeparatorText("Sort")
    let order = layer.order
    if igMenuItem_Bool("Sort by keys...", nil, order.len > 0 and presetOf(order) < 0, true):
      sortKeys = true
    marks.mark("plot.menu.sort keys")
    if igMenuItem_Bool("File order", nil, order.len == 0, true) and order.len > 0:
      res.commands.add Command(kind: ckSort, panel: p.id)
    marks.mark("plot.menu.file order")
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
  # Opened here, not in the menu, so that it has the window's ID, as below.
  if sortKeys: tp.sortKeys.openSortKeys(p)
  tp.sortKeys.drawSortKeys(p, marks, res.commands)

proc drawTracePanel*(tp: var TracePanelUi; title: string; st: AppState; panel: PanelId;
    t: Theme; fonts: Fonts; marks: var Marks): PanelOutput =
  ## The plot window of `panel`: its controls, then the start screen, a
  ## note, or the plot. Returns the commands and actions it asks for, and
  ## what lies under the mouse.
  result.pick = noPick()
  # Arrow keys pan the plot, so they do not move ImGui's keyboard focus here;
  # the wheel zooms, so it does not scroll the window.
  const windowFlags = ImGui_WindowFlags_NoNavInputs.cint or
    ImGui_WindowFlags_NoScrollWithMouse.cint or ImGui_WindowFlags_NoScrollbar.cint
  if igBegin(title.cstring, nil, windowFlags):
    # The window never scrolls as a whole: the strip wraps and the plot fits.
    igSetScrollX_Float(0)
    igSetScrollY_Float(0)
    marks.markWindow("plot")
    let k = st.findPanel(panel)
    if k < 0 or st.panels[k].layers.len == 0:
      drawStartScreen(t, marks, result)
    else:
      template p: untyped = st.panels[k]
      let mon = monitorOf(igGetWindowViewport())
      let ppi = st.settings.ppiFor(mon.name, mon.displayScale)
      var ask = ViewAsk()
      tp.drawControls(st, p, t, marks, result, ask, ppi, mon)
      let source = p.layers[0].source
      let s = if source.kind == lsRecord: st.findSession(source.file) else: -1
      let name = if s >= 0: st.sessions[s].name else: "the file"
      if tp.gpuError.len > 0:
        centredText("The plot cannot be drawn: " & tp.gpuError, t.roles[rlError])
      elif not p.laidOut:
        centredText("Reading " & name & "...", t.roles[rlTextDim])
      elif s >= 0 and st.sessions[s].gathers.len == 0:
        centredText(name & " has no traces to show (see Messages).", t.roles[rlTextDim])
      elif p.layout.traces == 0:
        let f = p.layers[0].filter
        let which = if f.seismic and not f.auxiliary: " (it shows seismic traces only)"
                    elif f.auxiliary and not f.seismic: " (it shows auxiliary traces only)"
                    else: ""
        centredText("The trace filter hides every trace of this gather" & which & ".",
          t.roles[rlTextDim])
      elif p.layout.samples == 0:
        centredText("The traces of this gather have no samples (see Messages).",
          t.roles[rlTextDim])
      else:
        tp.drawPlot(st, k, t, fonts, marks, result, ask, ppi)
  igEnd()
