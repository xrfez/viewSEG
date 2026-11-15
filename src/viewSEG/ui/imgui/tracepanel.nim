## The trace panel: the plot window that shows a record, traces across and
## time down, as wiggles (with a positive fill by default) or density (in
## its colour map) on white "paper", with the display header along the top and the
## window's own controls in a strip above it; or turned, time from left to
## right and the traces stacked from the top down, the display header in
## columns beside it (the orientation, a toggle in the strip). Everything
## the window places on the screen, and every gesture, goes through the
## plot's `Turn` (`core/orientation`): the axes and their values, the
## image, the header, the scroll bars, the cursor's line and boxes, a box
## zoom, the trace under the pointer; the mouse and keys act in the
## screen's directions.
##
## The window reads the panel from `core` and issues `Command`s; it never
## changes the state itself. ImPlot only draws the axes: the window handles
## the mouse and keys itself (docs/plot-window.md, "The plot") and moves the
## view with `core/zoom`: wheel zoom about the cursor (Ctrl: up and down
## only, Shift or the sideways wheel: across only), `+` / `-`, Ctrl + arrows
## for one axis, drag to pan (left or middle button), right drag to zoom to a
## box, arrows to pan, Ctrl + 0 to fit, Backspace or Alt + Left for back,
## Esc to cancel a drag, and the scroll bars (`plotbars`) beside the plot
## when part of the data is out of view. No view ever shows anything past
## the data, and a new plot size keeps the scale from the top-left corner
## (`core/zoom`). In the wiggle modes no view is zoomed out past one pixel a
## trace (`viewLimits`), so every trace in view is drawn as a wiggle;
## density, which shows a whole large record at once, is drawn only in the
## modes that name it. Each new view goes to `core` (`ckView`), which
## decides what to read; the first view of a gesture is sent with
## `remember`, so back returns to the view before it.
##
## The scale boxes state the view as traces per inch and ms per inch (or per
## cm, or inches per second: `core/scales`), at the pixels per inch of the
## monitor the window is on (96 times its display scale unless it is
## calibrated, in the "more" popover). Typing a value sets the zoom; every
## other zoom updates them.
##
## The image comes from `gpu/plotimage`: the panel's tiles, uploaded once
## each, drawn into an image the size of the plot as density, wiggles or
## wiggles over density, shown with ImPlot's image item. Until a tile for
## the new view arrives, the plot keeps
## drawing the tiles it has, stretched. What lies under the mouse
## (`core/pick`) goes back to the caller for the status bar.
##
## **Highlighting.** The trace under the pointer is the selection's hover
## (`ckHover`), a click selects it (`ckSelect`; Ctrl + click adds it or
## takes it out, Shift + click selects every trace from the one clicked
## last, in the order shown) and Esc clears the selection, all as
## survey-wide trace ids,
## so another view (the map) shows the same traces. The hovered trace is
## drawn in the highlight colour and the selected ones in the selection
## colour, line and fill (under density alone, their columns are tinted):
## a uniform and a small texture of marks per tile, so a hover reads and
## uploads nothing. The traces recorded at the point under the map's pointer
## (`Selection.hoverTraces`) are drawn as the hovered trace is, through a bit
## of the same marks (a byte per trace uploaded when they change). `M` over
## a trace selects its station on the map (the receiver; in a receiver
## gather, the source), as does the plot's menu.
##
## **The cursor's time line** (a toggle in the strip, a setting): a thin
## line from the pointer across to the time axis and the pointer's time at
## the axis, and the display header's values of the trace under the
## pointer, each in a box over its row, drawn over the image each frame, so
## it reads and redraws nothing. The time axis's labels are all as wide as the record's longest
## (`view/timeaxis`), so the plot's left edge stays put as they change.
##
## Nothing about a plot sits in the main toolbar: the display mode and the
## fills, the trace overlap (a box, - and +, greyed in density), the
## gain (`plotgain`: the type and the amount in dB), the scales, zoom, fit,
## back, the record shown (previous, next, and "Go to record" by place or
## FFID; Page Up / Page Down, Home / End and Ctrl + G) and the trace order
## (`plotsort`: the sort buttons and Custom...) are in the strip, which
## wraps in a narrow window; the colours (a swatch for each of the six,
## always shown), the trace overlap again, the display
## header's fields and the scales in its gear popover, the display header's
## fields also in the header's own menu (a right click on it). The plot's
## own menu (right click) holds only functions on the data: the trace
## operations, on the trace under the pointer or the selection, the
## polarity of every trace, and the undo of the file's last edit and the
## clearing of all its edits.
##
## **Trace operations.** Reverse polarity (`R`) and Kill / Restore (`K`)
## act on the trace under the pointer, or on the whole selection when that
## trace is in it (`ckEdit`); Ctrl + Z undoes the file's last edit. The
## edited traces are marked in a row of the display header that is there
## only while the gather has an edit: "K" killed, "R" reversed. Killed
## traces are drawn blank, or left out of the plot (the gear popover's
## "Hide killed traces", a setting). "FFT in a new window" (`F`) opens the
## amplitude spectrum of the same traces (`ckSpectrum`, `spectrumwindow`).

import std/[math, os, strutils, tables]
import imguin/cimgui
import ../../core/[geometry, state, wiggle]
import ../../gpu/[plotimage, textures]
import ../../view/[displayheader, maplayers, plotink, theme, timeaxis]
import chrome, dpi, focus, fonts, icons, menus, plotbars, plotfilters, plotgain, plotsort, style,
  symbols

export PaperBackground, PaperInk

const
  modeSymbols: array[DisplayMode, Symbol] = [syDensity, syWiggle, syWiggleDensity]
  fillSymbols: array[WiggleFill, Symbol] = [syWigglePositive, syWiggleNegative]
  menuId = "##plotmenu"
  headerMenuId = "##headermenu"
  gotoId = "Go to record##goto"
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

  ClickKind = enum
    clNone, clClick, clCtrlClick, clShiftClick

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

  GoToUi = object
    ## The "Go to record" popup.
    open: bool                ## open it this frame (Ctrl+G, or the record's number clicked)
    position: array[16, char] ## a place in the file, from 1
    ffid: array[16, char]     ## a field record number
    problem: string           ## why the last number typed went nowhere

  TracePanelUi* = object
    ## The plot window's own state between frames: its GPU objects, the
    ## view it shows, the gesture in progress and what it drew last.
    renderer: PlotRenderer
    textures: seq[TileTextures] ## the GPU copies of the panel's tiles, in their order
    uploads: int ## tiles uploaded so far (for tests)
    marks: int ## bumped whenever a tile's marks of selected traces change
    selected: seq[bool] ## scratch: a tile's selected rows
    lit: seq[bool] ## scratch: a tile's rows the map's pointer lights up
    hovering: bool ## the selection's hover was set by this plot
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
    stripWidths: array[11, float32] ## the strip's groups as drawn last frame
    goto: GoToUi
    menuTarget: string ## what the plot's menu acts on, said when it opened
    menuUnder: int = -1 ## the trace under the pointer when it opened (survey-wide); -1 for none
    menuStations: Command = Command(kind: ckSelectPoints)
      ## what its "Select its receiver on the map" sends, found when it opened
    cursorText: string ## the time the cursor's time line showed last; "" for none
    cursorHeader: seq[string] ## the header values it showed over the rows; none for none
    focus: FocusClicks ## a click selects only in a window that had the focus
    turned: Orientation ## the orientation the plot was drawn in last frame
    headerExtent: float32
      ## how much of the plot's length along time the display header took
      ## last frame (its rows, or its columns when time is across)
    fieldChars: Table[uint64, seq[int]] ## per tile: each header field's longest label
    bandChars: seq[int]
      ## time across: each header column's longest label so far, for the
      ## gather and fields `bandKey` names (they only grow, so the columns
      ## do not jump as the view pans)
    bandKey: (uint64, seq[HeaderField])
    picking: int ## the colour whose picker is open (as `colourKeys` lists them)
    hex: array[12, char] ## what the picker's `#rrggbb` box holds
    presetBox: array[MaxPresetName + 1, char] ## the Display presets section's name box
    presetPicked: string ## the preset clicked last there: Rename and Delete act on it
    moreSize: ImVec2_c ## the gear popover's size, as drawn last

  PanelOutput* = object
    ## What the plot window asks for.
    commands*: seq[Command]
    actions*: set[MenuAction]
    pick*: Pick         ## what lies under the mouse; `noPick()` when it is not over the plot
    notes*: seq[string] ## warnings for the log (a scale that is not a number)

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
  let (r, err) = newPlotRenderer(maxTexture)
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
  ## The view of the last plot image (for tests).

func cursorText*(tp: TracePanelUi): lent string {.inline.} = tp.cursorText
  ## The time the cursor's time line showed at the axis last frame; "" when
  ## it was not drawn (for tests).

func cursorHeader*(tp: TracePanelUi): lent seq[string] {.inline.} = tp.cursorHeader
  ## The values the cursor's boxes showed over the display header's rows
  ## last frame, top row first ("" where the trace has none); empty when
  ## they were not drawn (for tests).

func menuTarget*(tp: TracePanelUi): lent string {.inline.} = tp.menuTarget
  ## What the plot's menu said it acts on when it last opened: "Trace 12",
  ## "3 selected traces", "No trace here" (for tests).

proc plotImage*(tp: TracePanelUi): (seq[Rgba], int, int) =
  ## The last plot image, row by row from the top, and its size (for tests;
  ## with the GL context current).
  let (w, h) = tp.renderer.imageSize
  (tp.renderer.readImage, w, h)

func imagesDrawn*(tp: TracePanelUi): int {.inline.} = tp.renderer.imagesDrawn
  ## How many plot images were drawn: a frame in which nothing changed draws
  ## none (for tests).

func columnsDrawn*(tp: TracePanelUi): int {.inline.} = tp.renderer.columnsDrawn
  ## How many columns of the plot image the last drawing drew: all, or the
  ## stripes of the traces a hover left and reached (for tests).

func tilesUploaded*(tp: TracePanelUi): int {.inline.} = tp.uploads
  ## How many tiles were uploaded to the GPU: each once (for tests).

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

proc sync(tp: var TracePanelUi; tiles: openArray[Tile]; base: int; sel: Selection) =
  ## Uploads the tiles the GPU does not have and frees the ones `core` no
  ## longer keeps, so `textures[i]` is the copy of `tiles[i]`; marks each
  ## one's hovered and selected traces, and those the map's pointer lights
  ## up (`base`: the survey-wide id of the file's first trace), when the
  ## selection or the map's hover has changed since.
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
      inc tp.uploads
  for tt in tp.textures.mitems: tt.free()
  tp.textures = move kept
  for i, t in tiles:
    template tt: untyped = tp.textures[i]
    if tt.hoverRevision != sel.revision:
      tt.hoverRow = t.hoverRow(base, sel.hover)
      tt.hoverRevision = sel.revision
    if tt.selectionRevision != sel.selectedRevision or
        tt.hoveredRevision != sel.hoveredRevision:
      t.selectedRowsInto(base, sel, tp.selected)
      t.hoveredRowsInto(base, sel, tp.lit)
      tt.setMarks(t, tp.selected, tp.lit)
      tt.selectionRevision = sel.selectedRevision
      tt.hoveredRevision = sel.hoveredRevision
      inc tp.marks
  var gone: seq[uint64]
  for id in tp.labelChars.keys:
    var live = false
    for t in tiles:
      if t.id == id: live = true
    if not live: gone.add id
  for id in gone:
    tp.labelChars.del id
    tp.fieldChars.del id

proc labelChars(tp: var TracePanelUi; t: Tile): int =
  ## The length of the longest header label of tile `t`.
  if t.id notin tp.labelChars:
    var n = 1
    for row in t.header:
      for v in row: n = max(n, headerText(v).len)
    tp.labelChars[t.id] = n
  tp.labelChars[t.id]

proc bandChars(tp: var TracePanelUi; tiles: openArray[Tile]; fields: openArray[HeaderField];
    gen: uint64): seq[int] =
  ## Time across: the longest label of each of `fields` in `tiles`, never
  ## less than before for the same gather (`gen`: the panel's `sourceGen`)
  ## and fields, so the header's columns keep their widths as the view pans.
  let key = (gen, @fields)
  if key != tp.bandKey or tp.bandChars.len != fields.len:
    tp.bandKey = key
    tp.bandChars = newSeq[int](fields.len)
  for t in tiles:
    if t.fields == fields:
      if t.id notin tp.fieldChars:
        var chars = newSeq[int](t.header.len)
        for i, row in t.header:
          for v in row: chars[i] = max(chars[i], headerText(v).len)
        tp.fieldChars[t.id] = chars
      for i, n in tp.fieldChars[t.id]:
        if i < tp.bandChars.len: tp.bandChars[i] = max(tp.bandChars[i], n)
  tp.bandChars

func along(p: ImVec2_c; s: ScreenAxis): float32 {.inline.} =
  ## `p`'s coordinate along screen axis `s`.
  if s == saX: p.x else: p.y

func other(s: ScreenAxis): ScreenAxis {.inline.} =
  if s == saX: saY else: saX

func vec(s: ScreenAxis; a, b: float32): ImVec2_c {.inline.} =
  ## The point `a` along screen axis `s` and `b` along the other.
  if s == saX: ImVec2_c(x: a, y: b) else: ImVec2_c(x: b, y: a)

func ordered(a, b: ImVec2_c): (ImVec2_c, ImVec2_c) {.inline.} =
  ## The rectangle between `a` and `b` as its top-left and bottom-right.
  (ImVec2_c(x: min(a.x, b.x), y: min(a.y, b.y)), ImVec2_c(x: max(a.x, b.x), y: max(a.y, b.y)))

func traceAt(view: Viewport; m: Turn; plotPos, plotSize: ImVec2_c; position: float64): float32 =
  ## Where the centre of `position` lies on the screen along the traces'
  ## screen axis, for a plot at `plotPos`, `plotSize` showing `view` turned
  ## as `m` says.
  let s = m.along[axTraces]
  let perPos = plotSize.along(s) / max(view.traces.width, 1e-9)
  let d = float32((position - view.traces.lo) * perPos)
  if m.reversed[axTraces]: plotPos.along(s) + plotSize.along(s) - d else: plotPos.along(s) + d

type HeaderBands = object
  ## Where the display header's rows lie (its columns, when time is
  ## across): a band per field, then the edits band, along the screen axis
  ## time runs on, before the plot's start along it.
  axis: ScreenAxis ## the bands' axis: time's
  start: seq[float32] ## each band's start along it
  size: seq[float32] ## its thickness

proc inBand(b: HeaderBands; i: int; extent: float32): float32 =
  ## Where a label `extent` long along the bands' axis starts in band `i`:
  ## a row's top; a column's right end, less a gap (numbers in a column
  ## stand right-aligned).
  if b.axis == saY: b.start[i]
  else: b.start[i] + b.size[i] - extent - round(igGetFontSize() * 0.4)

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

func headerJoined(tiles: openArray[Tile]; fields: openArray[HeaderField]; row,
    position: int): bool =
  ## Whether the value of header row `row` at `position` (as `headerValue`
  ## finds it) was given by a geometry join, not by the trace's header.
  for i in countdown(tiles.high, 0):
    let r = tiles[i].request
    if tiles[i].fields == fields and position >= r.first and position <= r.last and
        (position - r.first) mod r.stride == 0:
      return (tiles[i].joinedAt((position - r.first) div r.stride) *
        joinGroupsOf(fields[row])) != {}
  false

proc button(label: string; t: Theme; marks: var Marks; mark: string): bool =
  result = igButton(label.cstring, ImVec2_c(x: 0, y: 0))
  marks.mark(mark)

proc drawHeaderChoice(p: Panel; marks: var Marks; prefix: string; res: var PanelOutput) =
  ## The display header's fields: automatic, or the ones ticked; each box
  ## marked `prefix` and "auto" or the field's name.
  var auto = p.header.auto
  if igCheckbox("Automatic fields", addr auto):
    res.commands.add Command(kind: ckHeader, panel: p.id,
      header: HeaderChoice(auto: auto, fields: p.shownFields))
  marks.mark(prefix & "auto")
  igBeginDisabled(p.header.auto)
  let shown = p.shownFields
  for f in HeaderField:
    var on = f in shown
    let have = f in p.known
    let label = $f & (if have: "" else: "  (not in this file)")
    let clicked = igCheckbox(label.cstring, addr on)
    marks.mark(prefix & $f)
    if clicked:
      var fields: seq[HeaderField]
      for g in HeaderField:
        if (g == f and on) or (g != f and g in shown): fields.add g
      if fields.len > 0:
        res.commands.add Command(kind: ckHeader, panel: p.id,
          header: HeaderChoice(auto: false, fields: fields))
  igEndDisabled()

proc tip(text: string) =
  ## The last item's tooltip.
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc tipAlways(text: string) =
  ## A tooltip that shows on a disabled item too.
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

const
  colourKeys = ["background", "line", "positive", "negative", "hover", "selected"]
    ## each of the plot's colours, as its swatch is marked
  pickerId = "##colourpicker"

func colourName(i: int; m: Turn): string =
  ## The name of the plot's colour `i` (as `colourKeys` lists them), the
  ## fills' sides as the plot is turned (`m`).
  let (axis, sign) = m.swingOnScreen
  let (positive, negative) = if axis == saX: (if sign > 0: ("right of", "left of")
                                              else: ("left of", "right of"))
                             elif sign < 0: ("above", "below")
                             else: ("below", "above")
  case i
  of 0: "Background"
  of 1: "Wiggle line"
  of 2: "Positive fill (the lobes " & positive & " a trace)"
  of 3: "Negative fill (the lobes " & negative & " it)"
  of 4: "The trace under the pointer"
  else: "Selected traces"

func colourOf(ink: PlotInk; i: int): Rgba =
  ## The plot's colour `i` (as `colourKeys` lists them).
  case i
  of 0: ink.background
  of 1: ink.wiggle.line
  of 2: ink.wiggle.positive
  of 3: ink.wiggle.negative
  of 4: ink.wiggle.hover
  else: ink.wiggle.selected

proc setColour(c: var CustomColours; i: int; v: Rgba) =
  case i
  of 0: c.background = v
  of 1: c.line = v
  of 2: c.positive = v
  of 3: c.negative = v
  of 4: c.hover = v
  else: c.selected = v

func chosen(c: CustomColours): bool =
  ## Whether the user has chosen colours of their own (`plotInk` takes a
  ## colour with no alpha for one not chosen).
  c.background.a != 0 or c.line.a != 0 or c.positive.a != 0 or c.negative.a != 0 or
    c.hover.a != 0 or c.selected.a != 0

proc fillHex(tp: var TracePanelUi; c: Rgba) =
  let text = toHex(Rgba(r: c.r, g: c.g, b: c.b, a: 255))
  zeroMem(addr tp.hex[0], tp.hex.len)
  copyMem(addr tp.hex[0], text.cstring, min(text.len, tp.hex.len - 1))

proc drawColours(tp: var TracePanelUi; p: Panel; t: Theme; marks: var Marks;
    res: var PanelOutput) =
  ## The plot's colours: the two ready-made schemes (paper, the theme's),
  ## which also reset them, or the user's own; then each of the six colours
  ## of the scheme in use, a swatch with its name. A click on a swatch opens
  ## a colour picker with a box for `#rrggbb`; changing a colour makes the
  ## scheme the user's own, starting from the colours shown.
  let d = p.layers[0].display
  let ink = plotInk(t, d)
  for c in PlotColours:
    let (text, help) = case c
      of pcPaper: ("Paper", "White paper, black wiggles and fill, red negative fill, " &
        "whatever the theme")
      of pcTheme: ("Follow the theme", "The theme's plot colours")
      of pcCustom: ("My own", "The colours you chose below")
    if c != pcPaper: igSameLine(0, -1)
    if igRadioButton_Bool(text.cstring, d.colours == c) and d.colours != c:
      var nd = d
      nd.colours = c
      if c == pcCustom and not d.custom.chosen:
        nd.custom = customOf(ink) # none chosen yet: start from what is shown
      res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
    marks.mark("plot.colours." & $c)
    tip(help)
  let size = igGetFrameHeight()
  for i in 0 ..< colourKeys.len:
    let shown = ink.colourOf(i)
    if igColorButton(("##colour" & colourKeys[i]).cstring, vec4(shown),
        ImGui_ColorEditFlags_NoAlpha.ImGuiColorEditFlags, ImVec2_c(x: size, y: size)):
      tp.picking = i
      tp.fillHex(shown)
      igOpenPopup_Str(pickerId, 0)
    marks.mark("plot.colour." & colourKeys[i])
    igSameLine(0, -1)
    igTextUnformatted(colourName(i, d.turn).cstring, nil)
  if igBeginPopup(pickerId, 0):
    marks.markWindow("plot.colour picker")
    let i = clamp(tp.picking, 0, colourKeys.high)
    let was = ink.colourOf(i)
    igTextUnformatted(colourName(i, d.turn).cstring, nil)
    var col: array[3, cfloat] = [cfloat(was.r) / 255, cfloat(was.g) / 255, cfloat(was.b) / 255]
    var picked = was
    var changed = false
    if igColorPicker3("##picker", col, (ImGui_ColorEditFlags_NoInputs.cint or
        ImGui_ColorEditFlags_NoSidePreview.cint).ImGuiColorEditFlags):
      func byte(v: cfloat): uint8 = uint8(clamp(round(v * 255), 0, 255))
      picked = Rgba(r: byte(col[0]), g: byte(col[1]), b: byte(col[2]), a: 255)
      changed = true
    igSetNextItemWidth(round(igCalcTextSize("#0000000", nil, false, -1).x +
      2 * igGetStyle().FramePadding.x))
    let hexActive = igInputText("##hex", cast[cstring](addr tp.hex[0]), csize_t(tp.hex.len),
      ImGui_InputTextFlags_EnterReturnsTrue.cint or ImGui_InputTextFlags_AutoSelectAll.cint,
      nil, nil) or igIsItemDeactivatedAfterEdit()
    let typing = igIsItemActive()
    marks.mark("plot.colour hex")
    tip("The colour as #rrggbb: type one and press Enter")
    if hexActive:
      var c: Rgba
      let text = $cast[cstring](addr tp.hex[0])
      if parseColor(text.strip, c):
        picked = Rgba(r: c.r, g: c.g, b: c.b, a: 255)
        changed = true
      else:
        res.notes.add "A colour is written #rrggbb (as #ff8000), not \"" & text.strip & "\"."
    if changed and picked != was:
      var nd = d
      if d.colours != pcCustom: nd.custom = customOf(ink) # from the colours shown
      nd.custom.setColour(i, picked)
      nd.colours = pcCustom
      res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
    if not typing and not hexActive: tp.fillHex(if changed: picked else: was)
    igEndPopup()

func mapHelp(m: ColourMap): string =
  case m
  of cmGrey: "Grey: positive amplitudes black, negative white, zero mid grey"
  of cmRedWhiteBlue: "Red-white-blue: negative red, zero white, positive blue"
  of cmViridis: "Viridis: dark purple (negative) to yellow (positive), readable in grey " &
    "and by most colour-blind viewers"
  of cmRedBlack: "Red-black: negative red, zero white, positive black"

proc drawColourMaps(p: Panel; t: Theme; marks: var Marks; res: var PanelOutput) =
  ## Density's colour maps, each its colour bar (the most negative amplitude
  ## at the left) and its name; a click on either draws density in it.
  let d = p.layers[0].display
  let h = igGetFrameHeight()
  let barWidth = round(8 * h)
  for m in ColourMap:
    let pos = igGetCursorScreenPos()
    let clicked = igInvisibleButton(("##colourmap" & $m).cstring,
      ImVec2_c(x: barWidth, y: h), 0)
    marks.mark("plot.colour map." & $m)
    tip(mapHelp(m))
    let dl = igGetWindowDrawList()
    let lut = lutOf(m)
    const bands = 64
    for b in 0 ..< bands:
      let c = lut[(b * 255 + (bands - 1) div 2) div (bands - 1)]
      let x0 = pos.x + float32(b) * barWidth / bands
      ImDrawList_AddRectFilled(dl, ImVec2_c(x: x0, y: pos.y + 2),
        ImVec2_c(x: pos.x + float32(b + 1) * barWidth / bands, y: pos.y + h - 2), u32(c), 0, 0)
    let edge = if m == d.colourMap: t.roles[rlAccent] else: t.roles[rlBorder]
    ImDrawList_AddRect(dl, ImVec2_c(x: pos.x, y: pos.y + 1),
      ImVec2_c(x: pos.x + barWidth, y: pos.y + h - 1), u32(edge), 0,
      (if m == d.colourMap: 2'f32 else: 1'f32), 0)
    igSameLine(0, -1)
    let name = case m
      of cmGrey: "Grey"
      of cmRedWhiteBlue: "Red-white-blue"
      of cmViridis: "Viridis"
      of cmRedBlack: "Red-black"
    let picked = igRadioButton_Bool((name & "##colourmapname").cstring, m == d.colourMap)
    marks.mark("plot.colour map name." & $m)
    tip(mapHelp(m))
    if (clicked or picked) and m != d.colourMap:
      var nd = d
      nd.colourMap = m
      res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)

const OverlapSteps = [0.1, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0,
  10.0] ## the values the overlap's - and + step through

func overlapStep(now: float64; up: bool): float64 =
  ## The next of `OverlapSteps` above (`up`) or below `now`; `now` at the end.
  result = now
  if up:
    for v in OverlapSteps:
      if v > now + 1e-9: return v
  else:
    for i in countdown(OverlapSteps.high, 0):
      if OverlapSteps[i] < now - 1e-9: return OverlapSteps[i]

proc drawOverlapControls(p: Panel; t: Theme; marks: var Marks; res: var PanelOutput) =
  ## The trace overlap in the strip, as the gain amount is: -, a box, +.
  ## Greyed in the density mode, so that the strip keeps its shape.
  let d = p.layers[0].display
  let o = d.effectiveOverlap
  const help = "Trace overlap: how far the strongest amplitudes swing a wiggle, in " &
    "trace spacings (1 reaches the next trace; anything stronger is clipped there)"
  template send(o: float64) =
    var nd = d
    nd.overlap = o
    res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
  igBeginDisabled(d.mode == dmDensity)
  if igButton("-##overlapless", ImVec2_c(x: 0, y: 0)) and o > MinOverlap:
    send(overlapStep(o, up = false))
  marks.mark("plot.overlap less")
  tipAlways("Less overlap: " & significant(overlapStep(o, up = false)) & " trace spacings")
  igSameLine(0, 2)
  var v = cdouble(o)
  igSetNextItemWidth(round(igCalcTextSize("00.00", nil, false, -1).x +
    2 * igGetStyle().FramePadding.x))
  discard igInputDouble("##overlap", addr v, 0, 0, "%.2f", 0)
  if igIsItemDeactivatedAfterEdit() and float64(v) != o:
    if v >= MinOverlap and v <= MaxOverlap: send(float64(v))
    else:
      res.notes.add "The trace overlap needs " & significant(MinOverlap) & " to " &
        significant(MaxOverlap) & " trace spacings, not " & significant(float64(v)) & "."
  marks.mark("plot.overlap")
  tipAlways(help & (if d.mode == dmDensity: " (with wiggles)" else: ""))
  igSameLine(0, 2)
  if igButton("+##overlapmore", ImVec2_c(x: 0, y: 0)) and o < MaxOverlap:
    send(overlapStep(o, up = true))
  marks.mark("plot.overlap more")
  tipAlways("More overlap: " & significant(overlapStep(o, up = true)) & " trace spacings")
  igSameLine(0, 4)
  igTextUnformatted("overlap", nil)
  tipAlways(help)
  igEndDisabled()

proc drawWiggleSettings(p: Panel; res: var PanelOutput) =
  ## The trace overlap: how far the reference amplitude swings a trace.
  let d = p.layers[0].display
  igTextUnformatted("Trace overlap", nil)
  igSameLine(0, -1)
  var v = cdouble(d.overlap)
  igSetNextItemWidth(round(igCalcTextSize("000.00", nil, false, -1).x +
    2 * igGetStyle().FramePadding.x))
  discard igInputDouble("##overlap", addr v, 0, 0, "%.2f", 0)
  if igIsItemDeactivatedAfterEdit():
    if v >= MinOverlap and v <= MaxOverlap:
      var nd = d
      nd.overlap = float64(v)
      res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
    else:
      res.notes.add "The trace overlap needs " & significant(MinOverlap) & " to " &
        significant(MaxOverlap) & " trace spacings, not " & significant(float64(v)) & "."
  tip("The largest swing of a wiggle, in trace spacings (1 reaches the next trace):\n" &
    "amplitudes drawn full black in density swing this far, and none further.")
  igSameLine(0, -1)
  igTextUnformatted("trace spacings", nil)

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

func hasAux(st: AppState; p: Panel): bool =
  ## Whether the record `p` shows holds auxiliary traces (the record list's
  ## count, from the index).
  if p.layers.len > 0 and p.layers[0].source.kind == lsRecord:
    let i = st.findSession(p.layers[0].source.file)
    let g = p.layers[0].source.gather
    result = i >= 0 and g in 0 ..< st.sessions[i].records.len and
      st.sessions[i].records[g].aux > 0

func recordOf(st: AppState; p: Panel): (int, int) =
  ## The record (gather) `p` shows and how many its file has; (0, 0) for
  ## none.
  result = (0, 0)
  if p.layers.len > 0 and p.layers[0].source.kind == lsRecord:
    let i = st.findSession(p.layers[0].source.file)
    if i >= 0: result = (max(p.layers[0].source.gather, 0), st.sessions[i].gathers.len)

proc drawGoTo(tp: var TracePanelUi; st: AppState; p: Panel; marks: var Marks;
    res: var PanelOutput) =
  ## The "Go to record" popup: a place in the file, or a field record
  ## number (FFID); Enter or Go shows it.
  let (current, count) = recordOf(st, p)
  if tp.goto.open:
    igOpenPopup_Str(gotoId, 0)
    tp.goto.open = false
    tp.goto.problem = ""
    let text = $(current + 1)
    zeroMem(addr tp.goto.position[0], tp.goto.position.len)
    copyMem(addr tp.goto.position[0], text.cstring, min(text.len, tp.goto.position.len - 1))
  if igBeginPopup(gotoId, 0):
    marks.markWindow("goto")
    igTextUnformatted(("Go to a record of " & $count).cstring, nil)
    const flags = ImGui_InputTextFlags_EnterReturnsTrue.cint or
      ImGui_InputTextFlags_CharsDecimal.cint or ImGui_InputTextFlags_AutoSelectAll.cint
    if igIsWindowAppearing(): igSetKeyboardFocusHere(0)
    igSetNextItemWidth(igGetFontSize() * 8)
    var go = igInputText("Place in the file##gotoposition", cast[cstring](
      addr tp.goto.position[0]), csize_t(tp.goto.position.len), flags, nil, nil)
    var byFfid = false
    marks.mark("goto.position")
    igSetNextItemWidth(igGetFontSize() * 8)
    if igInputText("or FFID##gotoffid", cast[cstring](addr tp.goto.ffid[0]),
        csize_t(tp.goto.ffid.len), flags, nil, nil):
      (go, byFfid) = (true, true)
    marks.mark("goto.ffid")
    if igButton("Go", ImVec2_c(x: 0, y: 0)): go = true
    marks.mark("goto.go")
    igSameLine(0, -1)
    if igButton("Cancel", ImVec2_c(x: 0, y: 0)): igCloseCurrentPopup()
    if go:
      let i = st.findSession(p.layers[0].source.file)
      let typed = if byFfid: strip($cast[cstring](addr tp.goto.ffid[0]))
                  else: strip($cast[cstring](addr tp.goto.position[0]))
      var to = -1
      try:
        if byFfid:
          if i >= 0: to = findRecord(st.sessions[i].records, parseFloat(typed))
          if to < 0: tp.goto.problem = "No record has FFID " & typed & "."
        else:
          let n = parseInt(typed)
          if n in 1 .. count: to = n - 1
          else: tp.goto.problem = "Type a place from 1 to " & $count & "."
      except ValueError:
        tp.goto.problem = "Type a number."
      if to >= 0:
        if to != current: res.commands.add Command(kind: ckGather, panel: p.id, gather: to)
        igCloseCurrentPopup()
    if tp.goto.problem.len > 0:
      igTextDisabled("%s", tp.goto.problem.cstring)
    igEndPopup()

proc drawPresets(tp: var TracePanelUi; st: AppState; p: Panel; marks: var Marks;
    res: var PanelOutput) =
  ## The display presets: each a line to click, which draws the plot as it
  ## says (the one shown now drawn selected); a box for a name, Save (the
  ## display shown, under that name), Rename and Delete (the preset clicked
  ## last).
  let presets = st.settings.displayPresets
  let shown = presets.shownPreset(p.layers[0].display)
  template command(action: PresetAction; name: string; newName = "") =
    res.commands.add Command(kind: ckDisplayPreset, panel: p.id, presetAction: action,
      presetName: name, presetNewName: newName)
  if presets.len == 0:
    igTextUnformatted("None yet: name the display shown and Save it.", nil)
  for i, q in presets:
    if igSelectable_Bool((q.name & "##preset" & $i).cstring, i == shown,
        ImGui_SelectableFlags_NoAutoClosePopups.cint, ImVec2_c(x: 0, y: 0)):
      tp.presetPicked = q.name
      zeroMem(addr tp.presetBox[0], tp.presetBox.len)
      copyMem(addr tp.presetBox[0], q.name.cstring, min(q.name.len, tp.presetBox.len - 1))
      command(paApply, q.name)
    marks.mark("plot.preset." & q.name)
    tip("Draw the plot as \"" & q.name & "\" says (it stays turned as it is)")
  igSetNextItemWidth(round(igCalcTextSize("A preset's long name", nil, false, -1).x +
    2 * igGetStyle().FramePadding.x))
  let entered = igInputTextWithHint("##presetname", "a name", cast[cstring](addr tp.presetBox[0]),
    csize_t(tp.presetBox.len), ImGui_InputTextFlags_EnterReturnsTrue.cint, nil, nil)
  marks.mark("plot.preset name")
  tip("The name to save the display shown under, or to give the preset clicked last")
  let typed = ($cast[cstring](addr tp.presetBox[0])).strip
  igSameLine(0, -1)
  igBeginDisabled(typed.len == 0)
  if igButton("Save##preset", ImVec2_c(x: 0, y: 0)) or (entered and typed.len > 0):
    command(paSave, typed)
    tp.presetPicked = typed
  igEndDisabled()
  marks.mark("plot.preset save")
  tipAlways("Keep the display shown under the name in the box (a preset so named is replaced)")
  let known = presets.find(tp.presetPicked) >= 0
  igSameLine(0, -1)
  igBeginDisabled(not known or typed.len == 0 or typed == tp.presetPicked)
  if igButton("Rename##preset", ImVec2_c(x: 0, y: 0)):
    command(paRename, tp.presetPicked, typed)
    tp.presetPicked = typed
  igEndDisabled()
  marks.mark("plot.preset rename")
  tipAlways(if known: "Give \"" & tp.presetPicked & "\" the name in the box"
            else: "Click a preset first, then type its new name")
  igSameLine(0, -1)
  igBeginDisabled(not known)
  if igButton("Delete##preset", ImVec2_c(x: 0, y: 0)):
    command(paDelete, tp.presetPicked)
    tp.presetPicked = ""
  igEndDisabled()
  marks.mark("plot.preset delete")
  tipAlways(if known: "Forget \"" & tp.presetPicked & "\"" else: "Click a preset first")

proc drawControls(tp: var TracePanelUi; st: AppState; p: Panel; t: Theme; marks: var Marks;
    res: var PanelOutput; ask: var ViewAsk; ppi: float64; mon: MonitorInfo) =
  ## The strip at the top of the window, in groups that wrap onto more lines
  ## when the window is narrow.
  let size = round(igGetFontSize() * IconScale + 2 * igGetStyle().FramePadding.y)
  let lift = round((size - igGetFrameHeight()) / 2) # centres a text control on the symbols
  let right = igGetCursorScreenPos().x + igGetContentRegionAvail().x
  let d = p.layers[0].display
  let turn = d.turn
  let turned = d.orientation == orTimeAcross # the plot's symbols turn with it
  tp.stripGroup(0, right, 0, 0):
    for m in DisplayMode:
      if symbolButton(modeSymbols[m], size, t, marks, selected = m == d.mode,
          markPrefix = "plot.", turned = turned) and m != d.mode:
        var nd = d
        nd.mode = m
        res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
      igSameLine(0, 2)
    # the fills belong to the wiggles: either, both or none
    igSameLine(0, 6)
    igBeginDisabled(d.mode == dmDensity)
    for f in WiggleFill:
      if symbolButton(fillSymbols[f], size, t, marks, selected = f in d.fills and
          d.mode != dmDensity, note = (if d.mode == dmDensity: " (with wiggles)" else: ""),
          markPrefix = "plot.", turned = turned):
        var nd = d
        if f in nd.fills: nd.fills.excl f else: nd.fills.incl f
        res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
      if f != WiggleFill.high: igSameLine(0, 2)
    igEndDisabled()
    # the cursor's time line: on the symbols' line, so the strip keeps its height
    igSameLine(0, 6)
    let on = st.settings.cursorLine
    let way = if turn.along[axTraces] == saX: "across" else: "down"
    let note = if on: " (on): a line from the pointer " & way & " to the time axis, and its time"
               else: " (off): click for a line from the pointer " & way & " to the time axis"
    if symbolButton(syCursorTime, size, t, marks, selected = on, note = note,
        markPrefix = "plot.", turned = turned):
      var s = st.settings
      s.cursorLine = not on
      res.commands.add Command(kind: ckSettings, settings: s)
    # the plot's orientation: time down, or time across
    igSameLine(0, 6)
    const stacked = if FirstTraceAtTop: "from the top down" else: "from the bottom up"
    let turnNote = if turned: " (on): time runs from left to right, the traces stacked " &
                     stacked & "; click to draw time downwards again"
                   else: " (off): click to draw time from left to right, the traces " &
                     "stacked " & stacked & ", a positive amplitude up"
    if symbolButton(syTimeAcross, size, t, marks, selected = turned, note = turnNote,
        markPrefix = "plot."):
      var nd = d
      nd.orientation = if turned: orTimeDown else: orTimeAcross
      res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
  # which traces: seismic, auxiliary or both, for a record that has auxiliary traces
  let f = p.layers[0].filter
  if hasAux(st, p) or not f.seismic or f.auxiliary:
    tp.stripGroup(9, right, 6, lift):
      for (aux, name, what) in [(false, "Seismic", "seismic"), (true, "Aux", "auxiliary")]:
        let on = if aux: f.auxiliary else: f.seismic
        let other = if aux: f.seismic else: f.auxiliary
        if toggle(name & "##traces", on, t) and (not on or other):
          var nf = f
          if aux: nf.auxiliary = not on else: nf.seismic = not on
          res.commands.add Command(kind: ckFilter, panel: p.id, filter: nf)
        marks.mark("plot.traces." & name)
        tip("Show the record's " & what & " traces" & (if on: " (on)" else: " (off)") &
          (if on and not other: ": the plot shows them alone, so this one stays on" else: "") &
          ". With both, the auxiliary traces stand in the file's order among the seismic ones.")
        if not aux: igSameLine(0, 2)
  tp.stripGroup(1, right, 6, lift):
    drawOverlapControls(p, t, marks, res)
  # the filters, then the gain: the order the samples go through them
  tp.stripGroup(10, right, 12, lift):
    drawFilterControls(p, hasAux(st, p), t, marks, res.commands)
  tp.stripGroup(2, right, 12, lift):
    drawGainControls(p, t, marks, res.commands, res.notes)
  # the scales
  let u = st.settings.scale
  let per = lengthName(u.length)
  tp.stripGroup(3, right, 14, lift):
    if tp.traceBox.scaleBox("##tracescale", traceLabel(u), "Traces per " & per &
        ": type a value and press Enter", traceScale(tp.cur, ppi, u), marks, "plot.trace scale"):
      askScale(tp.traceBox, vaTraceScale, "trace scale", ask, res)
    igSameLine(0, 10)
    let timeTip = if u.speed: per & "es per second" else: "Milliseconds per " & per
    if tp.timeBox.scaleBox("##timescale", timeLabel(u), timeTip & ": type a value and " &
        "press Enter", timeScale(tp.cur, ppi, u), marks, "plot.time scale"):
      askScale(tp.timeBox, vaTimeScale, "time scale", ask, res)
  # zoom, fit, back
  tp.stripGroup(4, right, 14, lift):
    if button(IconZoomOut & "##zoomout", t, marks, "plot.zoom out"):
      ask = ViewAsk(kind: vaZoomOut)
    tip("Zoom out (-, or the wheel)")
    igSameLine(0, 2)
    if button(IconZoomIn & "##zoomin", t, marks, "plot.zoom in"): ask = ViewAsk(kind: vaZoomIn)
    tip("Zoom in (+, or the wheel; Ctrl: " & $turn.axisAlong(saY) & " only, Shift: " &
      $turn.axisAlong(saX) & " only)")
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
  # the record shown, the one before and after
  let (current, count) = recordOf(st, p)
  tp.stripGroup(5, right, 14, lift):
    igBeginDisabled(current <= 0)
    if button(IconRecordBack & "##prevrecord", t, marks, "plot.previous record"):
      res.commands.add Command(kind: ckGather, panel: p.id, gather: current - 1)
    igEndDisabled()
    tipAlways("Previous record (Page Up; Home: the first)")
    igSameLine(0, 2)
    if button($(current + 1) & " / " & $count & "##record", t, marks, "plot.record"):
      tp.goto.open = true
    tip("Record " & $(current + 1) & " of " & $count & " in the file: click to go to " &
      "another (Ctrl+G)")
    igSameLine(0, 2)
    igBeginDisabled(current >= count - 1)
    if button(IconRecordNext & "##nextrecord", t, marks, "plot.next record"):
      res.commands.add Command(kind: ckGather, panel: p.id, gather: current + 1)
    igEndDisabled()
    tipAlways("Next record (Page Down; End: the last)")
  tp.stripGroup(6, right, 14, lift):
    drawSortButtons(p, st.settings.sortPresets, t, marks, res.commands)
  tp.stripGroup(7, right, 2, lift): # on a line of its own in a narrow window
    if drawCustomSort(p, st.settings.sortPresets, t, marks):
      tp.sortKeys.openSortKeys(p, st.settings) # in the window's ID scope, as it is drawn
  tp.stripGroup(8, right, 8, lift):
    if button(IconSettings & "##more", t, marks, "plot.more"):
      igOpenPopup_Str(moreId, 0)
    tip("Display presets, colours, density's colour map, killed traces, display header, " &
      "scale units and screen calibration")
  if igIsPopupOpen_Str(moreId, 0):
    # below the gear, its right edge at the gear's, moved as far as needed to
    # stay inside the main window: the gear is near the middle of it, and
    # past its edge the popover would be a window of the desktop's own
    let vp = igGetMainViewport()
    let (gear, size) = (igGetItemRectMax(), tp.moreSize)
    let x = max(vp.WorkPos.x, min(gear.x - size.x, vp.WorkPos.x + vp.WorkSize.x - size.x))
    let y = max(vp.WorkPos.y, min(gear.y, vp.WorkPos.y + vp.WorkSize.y - size.y))
    igSetNextWindowPos(ImVec2_c(x: x, y: y), ImGui_Cond_Always.cint, ImVec2_c(x: 0, y: 0))
  if igBeginPopup(moreId, 0):
    tp.moreSize = igGetWindowSize()
    marks.markWindow("plot.more popover")
    # in columns, so the popover fits a laptop's screen: how the traces
    # look; the wiggles, killed traces and the header; the scales
    let table = igBeginTable("##more", 3, ImGui_TableFlags_SizingFixedFit.ImGuiTableFlags,
      ImVec2_c(x: 0, y: 0), 0)
    template nextColumn() =
      if table:
        discard igTableNextColumn()
        igDummy(ImVec2_c(x: round(igGetFontSize()), y: 0)) # a gutter between the columns
        igSameLine(0, 0)
        igBeginGroup()
    if table: discard igTableNextColumn()
    igSeparatorText("Display presets")
    tp.drawPresets(st, p, marks, res)
    igSeparatorText("Colours")
    tp.drawColours(p, t, marks, res)
    igSeparatorText("Density colour map")
    drawColourMaps(p, t, marks, res)
    nextColumn()
    igSeparatorText("Wiggles")
    drawWiggleSettings(p, res)
    igSeparatorText("Killed traces")
    var hide = st.settings.hideKilled
    if igCheckbox("Hide killed traces", addr hide):
      var s = st.settings
      s.hideKilled = hide
      res.commands.add Command(kind: ckSettings, settings: s)
    marks.mark("plot.more.hide killed")
    tip("On: killed traces are left out of the plot, the traces beside them close up. " &
      "Off: they are drawn blank. Either way they are left out of the levels and spectra.")
    igSeparatorText("Display header")
    drawHeaderChoice(p, marks, "plot.more.header.", res)
    if table: igEndGroup()
    nextColumn()
    igSeparatorText("Scales")
    tp.drawScaleSettings(st, res, ppi, mon)
    if table:
      igEndGroup()
      igEndTable()
    igEndPopup()

proc drawStartScreen(t: Theme; recent, folders: openArray[string]; marks: var Marks;
    res: var PanelOutput) =
  ## What the window shows with no file: the ways to open one, and the
  ## folders and files opened last.
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
  let hint = "Ctrl+O opens a file, Ctrl+Alt+O a folder; files and folders can also be " &
    "dropped on the window."
  let w = igCalcTextSize(hint.cstring, nil, false, -1).x
  igSetCursorPosX(top.x + max(0, (avail.x - w) / 2))
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextUnformatted(hint.cstring, nil)
  igPopStyleColor(1)
  if folders.len > 0:
    igDummy(ImVec2_c(x: 0, y: igGetFontSize()))
    igSetCursorPosX(top.x + max(0, (avail.x - big.x) / 2))
    igTextDisabled("Recent folders")
    for i in 0 ..< min(folders.len, 4):
      igSetCursorPosX(top.x + max(0, (avail.x - big.x) / 2))
      igPushID_Int(cint(100 + i))
      let name = if folders[i].extractFilename.len > 0: folders[i].extractFilename
                 else: folders[i]
      if igSelectable_Bool((IconFolder & "  " & name).cstring, false, 0,
          ImVec2_c(x: big.x, y: 0)):
        res.commands.add Command(kind: ckBrowse, paths: @[folders[i]], showFirst: true)
      marks.mark("plot.recent folder " & $i)
      tip(folders[i] & "\nIts seismic files in the file list, the first one shown")
      igPopID()
  if recent.len > 0:
    igDummy(ImVec2_c(x: 0, y: igGetFontSize()))
    igSetCursorPosX(top.x + max(0, (avail.x - big.x) / 2))
    igTextDisabled("Recent files")
    for i in 0 ..< min(recent.len, 5):
      igSetCursorPosX(top.x + max(0, (avail.x - big.x) / 2))
      igPushID_Int(cint(i))
      if igSelectable_Bool((IconOpenFile & "  " & recent[i].extractFilename).cstring, false,
          0, ImVec2_c(x: big.x, y: 0)):
        res.commands.add Command(kind: ckShowFile, panel: MainPanel, path: recent[i],
          listFolder: true)
      marks.mark("plot.recent " & $i)
      tip(recent[i])
      igPopID()

proc centredText(text: string; colour: Rgba) =
  let avail = igGetContentRegionAvail()
  let w = igCalcTextSize(text.cstring, nil, false, -1).x
  let at = igGetCursorPos()
  igSetCursorPos(ImVec2_c(x: at.x + max(0, (avail.x - w) / 2), y: at.y + avail.y / 2 - 10))
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour))
  igTextUnformatted(text.cstring, nil)
  igPopStyleColor(1)

proc drawHeader(tp: var TracePanelUi; tiles: openArray[Tile]; fields: openArray[HeaderField];
    stride: int; view: Viewport; layout: PanelLayout; m: Turn; bands: HeaderBands;
    top, plotPos, plotSize: ImVec2_c; t: Theme; marks: var Marks) =
  ## The display header between `top` and the plot: a band per field (a row
  ## above the plot, or a column left of it when time is across), the
  ## field's name before the plot's start along the traces (left of it, or
  ## above it), values at their traces.
  if fields.len == 0 or tiles.len == 0: return
  let dl = igGetWindowDrawList()
  let lineH = igGetTextLineHeight()
  let ink = u32(t.roles[rlText])
  let joinedInk = u32(t.roles[rlAccent]) # values a geometry join gave
  let dim = u32(t.roles[rlTextDim])
  let charW = igCalcTextSize("0", nil, false, -1).x
  let chars = tp.labelChars(tiles[^1])
  let ta = m.along[axTraces] # where the traces run on the screen
  let perPos = plotSize.along(ta) / max(view.traces.width, 1e-9)
  # a label and the gap to the next, along the traces
  let room = if ta == saX: (float64(chars) + 2) * charW else: float64(lineH) + 2
  let step = headerStep(stride, perPos, room)
  let vis = visiblePositions(layout, view)
  let (t0, t1) = (plotPos.along(ta), plotPos.along(ta) + plotSize.along(ta))
  let (b0, b1) = (top.along(bands.axis), plotPos.along(bands.axis))
  let names = if ta == saX: 200'f32 else: 0'f32 # room for the names before the plot
  ImDrawList_PushClipRect(dl, vec(ta, top.along(ta) - names, b0), vec(ta, t1, b1), true)
  for i, f in fields:
    let (r0, r1) = ordered(vec(ta, t0, bands.start[i]), vec(ta, t1, bands.start[i] +
      bands.size[i]))
    marks.markRect("plot.header." & $f, r0, r1) # the band's values, for tests
    let name = caption(f)
    let ns = igCalcTextSize(name.cstring, nil, false, -1)
    let at = if ta == saX: vec(ta, t0 - ns.x - 6, bands.inBand(i, ns.y))
             else: vec(ta, t0 - lineH - 2, bands.inBand(i, ns.x))
    ImDrawList_AddText_Vec2(dl, at, dim, name.cstring, nil)
    ImDrawList_PushClipRect(dl, vec(ta, t0, b0), vec(ta, t1, b1), true)
    for pos in labelled(vis, step):
      let (have, v) = headerValue(tiles, fields, i, pos)
      if have:
        let text = headerText(v)
        if text.len > 0:
          let c = traceAt(view, m, plotPos, plotSize, float64(pos))
          let ts = igCalcTextSize(text.cstring, nil, false, -1)
          let w = ts.along(ta)
          let left = round(c - w / 2)
          if left >= t0 and left + w <= t1: # whole labels only
            let colour = if headerJoined(tiles, fields, i, pos): joinedInk else: ink
            ImDrawList_AddText_Vec2(dl, vec(ta, left, bands.inBand(i, ts.along(bands.axis))),
              colour, text.cstring, nil)
    ImDrawList_PopClipRect(dl)
  ImDrawList_PopClipRect(dl)

func targetOf(under: int; pick: Pick; sel: Selection): string =
  ## What the plot's menu acts on, in words: the selection when the trace
  ## under the pointer (`under`, survey-wide) is in it, else that trace.
  if under < 0: "No trace here"
  elif under in sel.selected:
    let n = sel.selectedCount
    if n == 1: "1 selected trace" else: $n & " selected traces"
  else: "Trace " & $(pick.trace + 1)

func editCommand(st: AppState; p: Panel; under: int; edit: TraceEdit): Command =
  ## Edit `edit` of what a trace operation acts on with the pointer over
  ## trace `under` (survey-wide; the selection when `under` is in it): given
  ## when `under` lacks it, taken away when `under` has it.
  Command(kind: ckEdit, panel: p.id, edit: edit, edited: st.selection.targets(under),
    on: edit notin st.traceEdits(under))

func fftCommand(st: AppState; p: Panel; under: int): Command =
  ## An FFT window of what a trace operation acts on with the pointer over
  ## trace `under`: the selection when `under` is in it, else `under`.
  Command(kind: ckSpectrum, spectrumOf: p.id, spectrumTraces: st.selection.targets(under),
    spectrumShow: st.settings.spectrum.window)

proc drawTraceMenu(tp: var TracePanelUi; st: AppState; k: int; marks: var Marks;
    res: var PanelOutput) =
  ## The plot's right-click menu: functions on the data only. Its first
  ## line says what the trace operations act on; then the operations on
  ## that trace or the selection (its FFT in a new window), those on every
  ## trace, and the undo and clearing of the file's edits.
  template p: untyped = st.panels[k]
  if not igBeginPopup(menuId, 0): return
  marks.markWindow("plot.menu")
  igTextDisabled("%s", tp.menuTarget.cstring)
  marks.mark("plot.menu.target")
  igSeparator()
  let under = tp.menuUnder
  let has = st.traceEdits(under)
  # Ticked while the trace under the pointer is reversed: a click puts it back.
  if igMenuItem_Bool("Reverse polarity", "R", teReversed in has, under >= 0):
    res.commands.add editCommand(st, p, under, teReversed)
  marks.mark("plot.menu.reverse")
  if igMenuItem_Bool((if teKilled in has: "Restore" else: "Kill").cstring, "K", false,
      under >= 0):
    res.commands.add editCommand(st, p, under, teKilled)
  marks.mark("plot.menu.kill")
  if igMenuItem_Bool("FFT in a new window", "F", false, under >= 0):
    res.commands.add fftCommand(st, p, under)
  marks.mark("plot.menu.fft")
  tip("The amplitude spectrum of this trace (of the selection: their average), raw and " &
    "through the filters, in a window of its own; killed traces are left out")
  # Its station on the map: the receiver (in a receiver gather, the source).
  let role = $st.stationRole(k)
  let many = under >= 0 and under in st.selection.selected and st.selection.selectedCount > 1
  let station = if many: "Select their " & role & "s on the map" else: "Select its " & role &
    " on the map"
  if igMenuItem_Bool(station.cstring, "M", false, tp.menuStations.points.len > 0):
    res.commands.add tp.menuStations
  marks.mark("plot.menu.station")
  igSeparator()
  # An operation on the samples (processSEG's polarityOp), not a colour.
  let reversed = p.layers[0].reversed
  if igMenuItem_Bool("Reverse polarity of all traces", nil, reversed, true):
    res.commands.add Command(kind: ckReverseAll, panel: p.id, reverse: not reversed)
  marks.mark("plot.menu.reverse all")
  igSeparator()
  template e: untyped = st.editsOf(k) # not copied
  let undo = if e.canUndo: "Undo " & e.undoText else: "Undo"
  if igMenuItem_Bool(undo.cstring, "Ctrl+Z", false, e.canUndo):
    res.commands.add Command(kind: ckUndoEdit, panel: p.id)
  marks.mark("plot.menu.undo")
  let redo = if e.canRedo: "Redo " & e.redoText else: "Redo"
  if igMenuItem_Bool(redo.cstring, "Ctrl+Shift+Z", false, e.canRedo):
    res.commands.add Command(kind: ckRedoEdit, panel: p.id)
  marks.mark("plot.menu.redo")
  if igMenuItem_Bool("Clear all edits for this file", nil, false, not e.isEmpty):
    res.commands.add Command(kind: ckClearEdits, panel: p.id)
  marks.mark("plot.menu.clear")
  tipAlways("Kills and polarity reversals are remembered beside the file, never written " &
    "into it;\nclearing them shows the traces as the file has them (Ctrl+Z brings them back).")
  igEndPopup()

func stationCommand(st: AppState; k, under: int): Command =
  ## `M` over trace `under` (survey-wide): its station selected on the map
  ## (with the station's traces), or those of the selection that holds it;
  ## the receiver, or in a receiver gather the source.
  Command(kind: ckSelectPoints, points: st.stationsOf(st.selection.targets(under),
    st.stationRole(k)), pointMode: smReplace)

proc editKeys(st: AppState; k, under: int; res: var PanelOutput) =
  ## The trace operations' keys, while the plot has the focus: `R` reverses
  ## the polarity of the trace under the pointer (or of the selection that
  ## holds it) or puts it back, `K` kills or restores it, `M` selects its
  ## station on the map, `F` opens its FFT window. Undo and redo are the
  ## Edit menu's, from any window.
  if igGetIO_Nil().WantTextInput: return
  template p: untyped = st.panels[k]
  if under >= 0:
    if igShortcut_Nil(ImGui_Key_R.cint, 0):
      res.commands.add editCommand(st, p, under, teReversed)
    if igShortcut_Nil(ImGui_Key_K.cint, 0):
      res.commands.add editCommand(st, p, under, teKilled)
    if igShortcut_Nil(ImGui_Key_M.cint, 0):
      let c = stationCommand(st, k, under)
      if c.points.len > 0: res.commands.add c
    if igShortcut_Nil(ImGui_Key_F.cint, 0):
      res.commands.add fftCommand(st, p, under)

func holds(t: Tile; position: int): bool {.inline.} =
  ## Whether `t` has a row at `position`.
  let r = t.request
  r.count > 0 and position >= r.first and position <= r.last and
    (position - r.first) mod r.stride == 0

proc drawEditRow(e: FileEdits; tiles: openArray[Tile]; view: Viewport;
    layout: PanelLayout; m: Turn; bands: HeaderBands; plotPos, plotSize: ImVec2_c; t: Theme;
    marks: var Marks) =
  ## The display header's band of edits, its last (a row under its other
  ## rows; a column next to the plot when time is across): over each edited
  ## trace in view, as the file's edits `e` are now, "K" (killed, in the
  ## theme's error colour) or "R" (reversed, in its accent colour), "KR" for
  ## both; a thin bar where traces are too close for the letters. An edit
  ## shown but not remembered (an agent's, for the session) has a "*" after
  ## it, its bar an outline; one remembered but hidden for the session (an
  ## agent's undo of the user's) is in brackets, "(K)", in the dim text
  ## colour: it comes back at the next run.
  let dl = igGetWindowDrawList()
  let lineH = igGetTextLineHeight()
  let ta = m.along[axTraces]
  let i = bands.start.high
  let (bs, bz) = (bands.start[i], bands.size[i])
  let name = "edits"
  let ns = igCalcTextSize(name.cstring, nil, false, -1)
  let t0 = plotPos.along(ta)
  let (nlo, nhi) = if ta == saX:
      (vec(ta, t0 - ns.x - 6, bs), vec(ta, t0, bs + lineH))
    else: (vec(ta, t0 - lineH - 2, bands.inBand(i, ns.x)),
      vec(ta, t0 - 2, bands.inBand(i, ns.x) + ns.x))
  ImDrawList_AddText_Vec2(dl, nlo, u32(t.roles[rlTextDim]), name.cstring, nil)
  marks.markRect("plot.header.edits", nlo, nhi)
  let perPos = plotSize.along(ta) / max(view.traces.width, 1e-9)
  ImDrawList_PushClipRect(dl, vec(ta, t0, bs), vec(ta, t0 + plotSize.along(ta), bs + bz), true)
  var marked = 0
  let vis = visiblePositions(layout, view)
  # Each tile's rows in view that no newer tile has (as drawn): bounded by
  # the rows the tiles hold, not by the traces of the gather.
  for k in countdown(tiles.high, 0):
    for row in 0 ..< min(tiles[k].request.count, tiles[k].traces.len):
      let pos = tiles[k].request.position(row)
      var newer = false
      for j in k + 1 .. tiles.high:
        if tiles[j].holds(pos): newer = true
      let trace = tiles[k].traces[row]
      let has = if pos in vis and not newer: e.editsOf(trace) else: {}
      let kept = if pos in vis and not newer: e.keptOf(trace) else: {}
      if has != {} or kept != {}:
        func letters(s: set[TraceEdit]): string =
          (if teKilled in s: "K" else: "") & (if teReversed in s: "R" else: "")
        let session = has - kept # shown, not remembered
        let hidden = kept - has  # remembered, not shown
        var text = letters(has)
        if session != {}: text.add "*"
        if hidden != {}: text.add "(" & letters(hidden) & ")"
        let colour = if has == {}: u32(t.roles[rlTextDim])
                     else: u32(t.roles[if teKilled in has: rlError else: rlAccent])
        let c = traceAt(view, m, plotPos, plotSize, float64(pos))
        let ts = igCalcTextSize(text.cstring, nil, false, -1)
        let w = ts.along(ta)
        var lo, hi: ImVec2_c
        if perPos >= w + 2:
          let b = bands.inBand(i, ts.along(bands.axis))
          lo = vec(ta, round(c - w / 2), b)
          hi = vec(ta, lo.along(ta) + w, b + ts.along(bands.axis))
          ImDrawList_AddText_Vec2(dl, lo, colour, text.cstring, nil)
        else:
          let half = max(0.5'f32, perPos / 2 - 0.5'f32)
          lo = vec(ta, c - half, bs + round(bz * 0.2))
          hi = vec(ta, c + half, bs + round(bz * 0.8))
          if has == {} or session == has: ImDrawList_AddRect(dl, lo, hi, colour, 0, 1, 0)
          else: ImDrawList_AddRectFilled(dl, lo, hi, colour, 0, 0)
        if marked < 200: # for tests
          marks.markRect("plot.header.edit " & $(trace + 1), lo, hi)
          if session != {}: marks.markRect("plot.header.edit " & $(trace + 1) & " session", lo, hi)
          if hidden != {}: marks.markRect("plot.header.edit " & $(trace + 1) & " hidden", lo, hi)
          inc marked
  ImDrawList_PopClipRect(dl)

proc drawHeaderMenu(p: Panel; marks: var Marks; res: var PanelOutput) =
  ## The display header's own menu (a right click on its rows or their
  ## names): its fields, automatic or the ones ticked.
  if not igBeginPopup(headerMenuId, 0): return
  marks.markWindow("plot.header menu")
  igSeparatorText("Display header")
  drawHeaderChoice(p, marks, "plot.header menu.", res)
  igEndPopup()

proc drawCursorLine(tp: var TracePanelUi; at, pos, size: ImVec2_c; m: Turn; tMs, dtMs: float64;
    ink: PlotInk; t: Theme; marks: var Marks) =
  ## The cursor's time line: a thin line from the pointer at `at`, along the
  ## traces (across, or down when time is across), to the edge of the plot
  ## at `pos`, `size` where the time axis's values are (its left edge, or
  ## its bottom edge), and the pointer's time there, over those values.
  ## Drawn over the plot's image, so nothing is read or drawn again for it.
  ## The line takes the theme's crosshair colour made readable on the plot's
  ## background, with a halo of the background around it, so it shows over
  ## wiggles and over density's black and white alike.
  let dl = igGetWindowDrawList()
  let ta = m.along[axTraces] # the line runs along the traces, at one time
  let ba = other(ta)
  let fb = igGetIO_Nil().DisplayFramebufferScale.along(ba)
  let px = 1 / max(fb, 0.01) # one framebuffer pixel
                             # the pointer's pixel, drawn as rectangles, so there is no blur
  let top = floor(at.along(ba) * fb) / fb
  # ImPlot writes the y axis's values left of the plot, the x axis's below it
  let edge = if ta == saX: pos.x else: pos.y + size.y
  let colour = readableOn(t.roles[rlCrosshair], ink.background)
  let (h0, h1) = ordered(vec(ta, edge, top - px), vec(ta, at.along(ta), top + 2 * px))
  ImDrawList_AddRectFilled(dl, h0, h1, u32(withAlpha(ink.background, 150)), 0, 0)
  let (l0, l1) = ordered(vec(ta, edge, top), vec(ta, at.along(ta), top + px))
  ImDrawList_AddRectFilled(dl, l0, l1, u32(colour), 0, 0)
  marks.markRect("plot.cursor line", l0, l1)
  let mid = top + px / 2
  tp.cursorText = cursorTimeText(tMs, dtMs)
  let ts = igCalcTextSize(tp.cursorText.cstring, nil, false, -1)
  let pad = ImPlot_GetStyle().LabelPadding
  var lo, hi, text: ImVec2_c
  if ta == saX: # right-aligned left of the plot, as the tick values are
    let right = pos.x - pad.x # where the tick values end
    lo = ImVec2_c(x: right - ts.x - 3, y: round(mid - ts.y / 2) - 1)
    hi = ImVec2_c(x: pos.x, y: lo.y + ts.y + 2)
    text = ImVec2_c(x: right - ts.x, y: lo.y + 1)
  else: # centred under the line, below the plot, over the tick values
    lo = ImVec2_c(x: round(mid - ts.x / 2) - 3, y: edge)
    hi = ImVec2_c(x: lo.x + ts.x + 6, y: edge + pad.y + ts.y + 2)
    text = ImVec2_c(x: lo.x + 3, y: edge + pad.y)
  ImDrawList_AddRectFilled(dl, lo, hi, u32(t.roles[rlWindow]), 0, 0)
  ImDrawList_AddRect(dl, lo, hi, u32(colour), 0, 1, 0)
  ImDrawList_AddText_Vec2(dl, text, u32(t.roles[rlText]), tp.cursorText.cstring, nil)
  marks.markRect("plot.cursor time", lo, hi)

proc drawCursorHeader(tp: var TracePanelUi; tiles: openArray[Tile];
    fields: openArray[HeaderField]; position: int; view: Viewport; m: Turn;
    bands: HeaderBands; plotPos, plotSize: ImVec2_c; ink: PlotInk; t: Theme;
    marks: var Marks) =
  ## With the cursor's time line, the display header's value of each band
  ## for the trace at `position` (the pointer's), in a box over its row at
  ## the trace's column (in its column at the trace's row, when time is
  ## across), in the style of the time at the axis: the value is there when
  ## the band's labels are thinned because the traces are close. The trace's
  ## highlight marks the trace; no line is drawn. From the tiles' header
  ## values: nothing is read.
  let dl = igGetWindowDrawList()
  let ta = m.along[axTraces]
  let ba = bands.axis
  let colour = readableOn(t.roles[rlCrosshair], ink.background)
  let c = traceAt(view, m, plotPos, plotSize, float64(position))
  let (t0, t1) = (plotPos.along(ta), plotPos.along(ta) + plotSize.along(ta))
  let pad = if ta == saX: 6'f32 else: 2'f32 # around the text, along the traces
  for i, f in fields:
    let (have, v) = headerValue(tiles, fields, i, position)
    let text = if have: headerText(v) else: ""
    tp.cursorHeader.add text
    if text.len > 0:
      let ts = igCalcTextSize(text.cstring, nil, false, -1)
      let w = ts.along(ta)
      let first = clamp(round(c - w / 2) - pad / 2, t0, t1 - w - pad)
      let b0 = bands.start[i] - 1
      let lo = vec(ta, first, b0)
      let hi = vec(ta, first + w + pad, b0 + bands.size[i] + 1)
      ImDrawList_AddRectFilled(dl, lo, hi, u32(t.roles[rlWindow]), 0, 0)
      ImDrawList_AddRect(dl, lo, hi, u32(colour), 0, 1, 0)
      let ink = if headerJoined(tiles, fields, i, position): t.roles[rlAccent] else: t.roles[rlText]
      let at = if ba == saY: vec(ta, first + pad / 2, b0 + 1)
               else: vec(ta, first + pad / 2, bands.inBand(i, ts.x))
      ImDrawList_AddText_Vec2(dl, at, u32(ink), text.cstring, nil)
      marks.markRect("plot.cursor header " & $f, lo, hi)

proc burst(tp: var TracePanelUi; g: Gesture): bool =
  ## Whether a wheel turn or key press of kind `g` starts a new gesture (for
  ## back): another kind, or a pause since the last one. Notes it.
  let now = igGetTime()
  result = tp.gesture != g or now - tp.gestureAt > burstSeconds
  tp.gesture = g
  tp.gestureAt = now

func wheelOf(io: ptr ImGuiIO; m: Turn): (float64, set[Axis]) =
  ## Wheel notches this frame and the data axes they zoom on a plot turned
  ## `m`: both; Ctrl, up and down only (time, or the traces when time is
  ## across); Shift or the sideways wheel, across only.
  if io.MouseWheel != 0:
    let axes = if io.KeyCtrl: m.axesAlong({saY}) elif io.KeyShift: m.axesAlong({saX})
               else: BothAxes
    (float64(io.MouseWheel), axes)
  elif io.MouseWheelH != 0: (float64(io.MouseWheelH), m.axesAlong({saX}))
  else: (0.0, {})

func clampTo(p: ImVec2_c; r: Rect): Vec2 =
  vec2(clamp(p.x, r.pos.x, r.pos.x + r.size.x), clamp(p.y, r.pos.y, r.pos.y + r.size.y))

proc handleMouse(tp: var TracePanelUi; after: var Viewport; view: Viewport; plot: Rect;
    m: Turn; lim: ViewLimits; hovered: bool; t: Theme; remember, menu: var bool;
    click: var ClickKind) =
  ## The wheel and the buttons over the plot (the invisible button just
  ## drawn over it), turned as `m` says. A left press released where it went
  ## down is a click.
  let io = igGetIO_Nil()
  let mouse = io.MousePos
  if hovered:
    let (notches, axes) = wheelOf(io, m)
    if notches != 0 and axes.card > 0:
      after = after.zoomed(pow(WheelStep, notches),
        view.dataAt(plot, vec2(mouse.x, mouse.y), m), axes, lim)
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
      after = dragged(tp.drag.start, plot, moved, lim, m)
      igSetMouseCursor(ImGui_MouseCursor_ResizeAll.cint)
    if not down:
      if not tp.drag.moved and tp.drag.button == ImGui_MouseButton_Left.cint and hovered:
        # The click that brings the window forward selects nothing.
        click = if not tp.focus.acts: clNone
                elif io.KeyShift: clShiftClick
                elif io.KeyCtrl: clCtrlClick
                else: clClick
      tp.drag = Drag()
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
        if abs(a.x - b.x) >= boxMinPixels: axes.incl m.axisAlong(saX)
        if abs(a.y - b.y) >= boxMinPixels: axes.incl m.axisAlong(saY)
        if axes.card > 0:
          after = view.boxed(view.dataAt(plot, a, m), view.dataAt(plot, b, m), axes, lim)
          remember = true
          tp.gesture = gsNone
      elif hovered:
        menu = true # a right click: the context menu
      tp.drag = Drag()

proc handleKeys(tp: var TracePanelUi; after: var Viewport; view: Viewport; plot: Rect;
    m: Turn; lim: ViewLimits; hovered: bool; p: Panel; selected: bool; record: (int, int);
    remember: var bool; res: var PanelOutput) =
  ## The plot's keys, while its window has the focus (docs/plot-window.md),
  ## in the screen's directions on a plot turned `m`.
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
  let upIn = held(ctrl or ImGui_Key_UpArrow.cint)
  let upOut = held(ctrl or ImGui_Key_DownArrow.cint)
  let acrossIn = held(ctrl or ImGui_Key_RightArrow.cint)
  let acrossOut = held(ctrl or ImGui_Key_LeftArrow.cint)
  let at = if hovered: view.dataAt(plot, vec2(io.MousePos.x, io.MousePos.y), m)
           else: after.centre
  let (upDown, sideways) = (m.axesAlong({saY}), m.axesAlong({saX}))
  var zooms: seq[(float64, set[Axis])]
  if zoomIn: zooms.add (KeyStep, BothAxes)
  if zoomOut: zooms.add (1 / KeyStep, BothAxes)
  if upIn: zooms.add (KeyStep, upDown)
  if upOut: zooms.add (1 / KeyStep, upDown)
  if acrossIn: zooms.add (KeyStep, sideways)
  if acrossOut: zooms.add (1 / KeyStep, sideways)
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
    # the way the keys point, on the screen
    let (alongTraces, alongTime) = m.dataDelta(fx, fy)
    after = after.stepped(alongTraces, alongTime, lim)
    if tp.burst(gsKeyPan): remember = true
  if once(ctrl or ImGui_Key_0.cint) or once(ctrl or ImGui_Key_Keypad0.cint):
    after = fitted(lim, after.columns, after.rows)
    remember = true
    tp.gesture = gsNone
  if once(ImGui_Key_Backspace.cint) or once(alt or ImGui_Key_LeftArrow.cint):
    res.commands.add Command(kind: ckBack, panel: p.id)
  # Records: Page Down / Up, Home / End, Ctrl+G.
  let (current, count) = record
  var to = current
  if held(ImGui_Key_PageDown.cint): to = current + 1
  if held(ImGui_Key_PageUp.cint): to = current - 1
  if once(ImGui_Key_Home.cint): to = 0
  if once(ImGui_Key_End.cint): to = count - 1
  if count > 0 and clamp(to, 0, count - 1) != current:
    res.commands.add Command(kind: ckGather, panel: p.id, gather: clamp(to, 0, count - 1))
  if once(ctrl or ImGui_Key_G.cint): tp.goto.open = true
  gainKeys(p, res.commands)
  filterKeys(p, res.commands)
  if once(ImGui_Key_Escape.cint): # innermost first: a drag, a thumb, the selection
    if tp.drag.kind != dkNone:
      if tp.drag.kind == dkPan and tp.drag.moved: after = tp.drag.start
      tp.drag = Drag()
    elif not tp.bars.cancel(after) and selected:
      res.commands.add Command(kind: ckClearSelection)

proc drawPlot(tp: var TracePanelUi; st: AppState; k: int; t: Theme; fonts: Fonts;
    marks: var Marks; res: var PanelOutput; ask: ViewAsk; ppi: float64) =
  ## The display header and the plot of `panels[k]`, and the mouse and keys
  ## over it, turned as its display says.
  # Aliases, not copies: a `let` would copy the panel's tiles every frame.
  template p: untyped = st.panels[k]
  template layer: untyped = st.panels[k].layers[0]
  template tiles: untyped = st.tiles(k)
  # The limits on the plot's size last frame; `limNow` on this frame's.
  let lim = p.viewLimits(tp.cur.columns)
  let fields = p.shownFields
  let ink = plotInk(t, layer.display)
  let turn = layer.display.turn # the one mapping between the data and the screen
  let source = st.findSession(layer.source.file)
  let base = if source >= 0: st.sessions[source].base else: -1
  let lineH = igGetTextLineHeight()
  let headerTop = igGetCursorScreenPos()
  # The display header: a row per field above the plot, or a column per
  # field left of it when time is across (their names above them), and a
  # band for the edits while the gather has one.
  let edited = st.gatherEdited(k)
  var bands = HeaderBands(axis: turn.along[axTime])
  var headerExtent = 0'f32 # what the header takes of the plot's length along time
  if bands.axis == saY:
    for i in 0 ..< fields.len + ord(edited):
      bands.start.add headerTop.y + float32(i) * lineH
      bands.size.add lineH
    igDummy(ImVec2_c(x: 1, y: float32(fields.len + ord(edited)) * lineH + 2))
    headerExtent = float32(fields.len + ord(edited)) * lineH
  else:
    let charW = igCalcTextSize("0", nil, false, -1).x
    let gap = round(igGetFontSize() * 0.8)
    # Each column as wide as its field's longest value over the gather (the
    # reader's count; a tile's own, if longer: keys a join changed), so the
    # columns, and the plot's start, stay put as the view pans.
    let chars = tp.bandChars(tiles, fields, p.sourceGen)
    var at = headerTop.x
    for i, f in fields:
      let caption = igCalcTextSize(caption(f).cstring, nil, false, -1).x
      bands.start.add at
      bands.size.add round(max(caption, float32(max(max(chars[i], p.widest[f]), 1)) * charW)) +
        gap
      at += bands.size[^1]
    if edited:
      bands.start.add at
      bands.size.add round(max(igCalcTextSize("edits", nil, false, -1).x, 2 * charW)) + gap
      at += bands.size[^1]
    igDummy(ImVec2_c(x: 1, y: lineH + 2)) # the columns' names
    igSetCursorScreenPos(ImVec2_c(x: at, y: igGetCursorScreenPos().y))
    headerExtent = at - headerTop.x
  # This frame's view: what `core` set itself (back, a new gather), else
  # what a control or a test asked for, else last frame's.
  var remember = false
  if tp.jumps != p.jumps: # a drag or a held scroll bar does not undo it
    tp.cur = p.view
    tp.jumps = p.jumps
    tp.drag = Drag()
    tp.bars = ScrollBars()
  var next = tp.cur
  if tp.want:
    next.traces = tp.wanted.traces
    next.timeMs = tp.wanted.timeMs
    tp.want = false
    remember = true
  let units = st.settings.scale
  case ask.kind
  of vaNone: discard
  of vaFit: next = fitted(lim, next.columns, next.rows)
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
  ImPlot_PushStyleColor_Vec4(ImPlot_Col_PlotBg.cint, vec4(ink.background))
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
    # ImPlot's x axis is the screen's width, its y axis the height (its
    # values growing upwards): each shows the data axis the turn puts there.
    var inverted: array[ScreenAxis, bool]
    for (implot, s) in [(ImAxis_X1.cint, saX), (ImAxis_Y1.cint, saY)]:
      let a = turn.axisAlong(s)
      inverted[s] = (s == saY) != turn.reversed[a]
      # Tick values only, for time: the unit is in the ms/in box and the
      # status bar; nothing drawn over the data. The traces: none.
      let flags = ImPlot_AxisFlags_NoMenus.cint or
        (if a == axTraces: ImPlot_AxisFlags_NoDecorations.cint
          else: ImPlot_AxisFlags_NoGridLines.cint or ImPlot_AxisFlags_NoTickMarks.cint) or
        (if inverted[s]: ImPlot_AxisFlags_Invert.cint else: 0)
      ImPlot_SetupAxis(implot, nil, flags)
    if turn.along[axTime] == saY:
      # Every label as wide as the longest the record can have, so the axis,
      # and the plot's left edge, stay put as the labels change length.
      ImPlot_SetupAxisFormat_Str(ImAxis_Y1.cint, ("%" & $timeLabelChars(p.layout) & "g").cstring)
    let (xs, ys) = (next.span(turn.axisAlong(saX)), next.span(turn.axisAlong(saY)))
    ImPlot_SetupAxesLimits(xs.lo, xs.hi, ys.lo, ys.hi, ImPlot_Cond_Always.cint)
    ImPlot_SetupFinish()
    let lim2 = ImPlot_GetPlotLimits(ImAxis_X1.cint, ImAxis_Y1.cint)
    let pos = ImPlot_GetPlotPos()
    let size = ImPlot_GetPlotSize()
    let fb = igGetIO_Nil().DisplayFramebufferScale
    let view = next.sized(turn, int(round(size.x * fb.x)), int(round(size.y * fb.y)))
    marks.markRect("plot.data", pos, ImVec2_c(x: pos.x + size.x, y: pos.y + size.y))
    if tp.gpuError.len == 0 and tp.started:
      tp.sync(tiles, base, st.selection)
      let d = layer.display
      let scale = displayScale(p.reference, d.gainDb)
      var shown = view # what ImPlot shows along each screen axis
      let (sx, sy) = (Span(lo: lim2.X.Min, hi: lim2.X.Max), Span(lo: lim2.Y.Min, hi: lim2.Y.Max))
      (shown.traces, shown.timeMs) = if turn.axisAlong(saX) == axTraces: (sx, sy) else: (sy, sx)
      # one pixel of line at 100 % (no more than a quarter of a trace spacing:
      # `styleFor`), two for a hovered or selected trace
      let width = max(1.0, round(float64(fb.x)))
      let tex = tp.renderer.render(PlotFrame(view: shown, turn: turn,
        background: ink.background, density: d.drawsDensity, colourMap: d.colourMap,
        wiggles: d.drawsWiggles, scale: scale,
        style: d.styleFor(shown, scale, width, 2 * width), ink: ink.wiggle,
        tint: DensityTint, marks: tp.marks), tiles, tp.textures)
      tp.drawn = shown
      if tex != 0:
        # ImPlot puts uv0 at (x min, y max); the image's first row is the
        # plot's bottom, its first column the left
        let u0 = if inverted[saX]: 1'f32 else: 0'f32
        let v0 = if inverted[saY]: 0'f32 else: 1'f32
        ImPlot_PlotImage("##traces", ImTextureRef_c(internal_TexID: ImTextureID(tex)),
          ImPlotPoint_c(x: lim2.X.Min, y: lim2.Y.Min),
          ImPlotPoint_c(x: lim2.X.Max, y: lim2.Y.Max),
          ImVec2_c(x: u0, y: v0), ImVec2_c(x: 1 - u0, y: 1 - v0),
          ImVec4_c(x: 1, y: 1, z: 1, w: 1), ImPlot_ItemFlags_NoFit.cint)
    let stride = if p.pending.isEmpty: 1 else: p.pending.stride
    tp.drawHeader(tiles, fields, stride, view, p.layout, turn, bands, headerTop, pos, size, t,
      marks)
    if edited:
      drawEditRow(st.editsOf(k), tiles, view, p.layout, turn, bands, pos, size, t, marks)
    ImPlot_EndPlot()
    # the bar along the width goes under the values of the axis there, if any
    let barsUnder = if turn.axisAlong(saX) == axTime:
                  igGetItemRectMax().y - ImPlot_GetStyle().PlotPadding.y
                else: pos.y + size.y
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
    # The display header's own menu: a right click on its bands of values or
    # on their names (nothing else happens there): from the header's top-left
    # to the plot's start along time and its end along the traces.
    let ta = turn.along[axTraces]
    let corner = vec(ta, pos.along(ta) + size.along(ta), pos.along(other(ta)))
    let headerSize = ImVec2_c(x: corner.x - headerTop.x, y: corner.y - headerTop.y)
    if headerSize.x >= 1 and headerSize.y >= 1:
      igSetCursorScreenPos(headerTop)
      if igInvisibleButton("##headerinput", headerSize,
          ImGui_ButtonFlags_MouseButtonRight.cint):
        igOpenPopup_Str(headerMenuId, 0)
      marks.mark("plot.header")
    # The mouse and keys, over the plot's data area.
    let plot = Rect(pos: vec2(pos.x, pos.y), size: vec2(size.x, size.y))
    igSetCursorScreenPos(pos)
    discard igInvisibleButton("##plotinput", size, ImGui_ButtonFlags_MouseButtonLeft.cint or
      ImGui_ButtonFlags_MouseButtonRight.cint or ImGui_ButtonFlags_MouseButtonMiddle.cint)
    let hovered = igIsItemHovered(0)
    # A new plot size keeps the scale from the top left (the whole data where
    # the plot becomes larger than it), within the limits on the new size; a
    # turn keeps the traces and times shown (narrowed from the first trace
    # where the limits say), and so does a plot made shorter or longer
    # along time by the display header (other fields, the edits' band, time
    # across another gather's values): the time span chosen stays whole.
    let limNow = p.viewLimits(view.columns)
    var after = if turn.orientation != tp.turned or headerExtent != tp.headerExtent:
        keptFrom(view, limNow)
      elif view.columns != next.columns or view.rows != next.rows:
        next.resized(view.columns, view.rows, limNow)
      else: view
    tp.turned = turn.orientation
    tp.headerExtent = headerExtent
    var click = clNone
    tp.handleMouse(after, view, plot, turn, limNow, hovered, t, remember, menu, click)
    case tp.bars.drawScrollBars(after, view, pos, size, barsUnder, limNow, turn, t, marks)
    of beNone, beDrag: discard
    of beGrab:
      remember = true
      tp.gesture = gsNone
    of bePage: (if tp.burst(gsPage): remember = true)
    of beWheel: (if tp.burst(gsBarWheel): remember = true)
    tp.handleKeys(after, view, plot, turn, limNow, hovered, p,
      st.selection.anySelected, recordOf(st, p), remember, res)
    tp.cursorText = ""
    tp.cursorHeader.setLen 0
    if hovered:
      let mouse = igGetIO_Nil().MousePos
      res.pick = pick(tiles, p.layout, view, plot, vec2(mouse.x, mouse.y), turn)
      if st.settings.cursorLine and res.pick.inside:
        tp.drawCursorLine(mouse, pos, size, turn, res.pick.at.tMs, p.layout.dtMs, ink, t, marks)
        if res.pick.found and res.pick.position >= 0:
          tp.drawCursorHeader(tiles, fields, res.pick.position, view, turn, bands, pos, size,
            ink, t, marks)
    # The trace under the pointer is the hover; a click selects it.
    let under = if res.pick.found and res.pick.trace >= 0 and base >= 0: base + res.pick.trace
                else: -1
    if hovered and under != st.selection.hover:
      res.commands.add Command(kind: ckHover, trace: under)
      tp.hovering = under >= 0
    elif not hovered and tp.hovering:
      res.commands.add Command(kind: ckHover, trace: -1)
      tp.hovering = false
    # A click selects the trace, Ctrl + click adds it or takes it out, Shift
    # + click selects the traces from the one clicked last, in the order shown.
    if under >= 0:
      case click
      of clNone: discard
      of clClick: res.commands.add Command(kind: ckSelect, traces: @[under], mode: smReplace)
      of clCtrlClick: res.commands.add Command(kind: ckSelect, traces: @[under], mode: smToggle)
      of clShiftClick:
        res.commands.add Command(kind: ckSelect, mode: smRange,
          traces: p.rangeOf(base, st.selection.anchor, under))
    editKeys(st, k, if hovered: under else: -1, res)
    if menu:
      tp.menuTarget = targetOf(under, res.pick, st.selection)
      tp.menuUnder = under
      tp.menuStations = if under >= 0: stationCommand(st, k, under)
                        else: Command(kind: ckSelectPoints)
    tp.cur = after
    if after != p.view:
      res.commands.add Command(kind: ckView, panel: p.id, view: after, remember: remember)
  ImPlot_PopStyleColor(1)
  if menu: igOpenPopup_Str(menuId, 0)
  tp.drawTraceMenu(st, k, marks, res)
  drawHeaderMenu(p, marks, res)
  tp.sortKeys.drawSortKeys(p, marks, res.commands)
  tp.drawGoTo(st, p, marks, res)

proc drawWaiting(w: Waiting; panel: PanelId; t: Theme; marks: var Marks;
    res: var PanelOutput; centred: bool) =
  ## What the panel waits for that its drive does not answer, with Cancel
  ## and Retry: in the middle of an empty plot (`centred`), else as a line
  ## above the plot, which keeps what it showed: the buttons first, so a
  ## narrow window wraps the words, never the buttons.
  let text = IconWarning & "  " & w.words
  let colour = if w.kind == wkUnreadable and w.cause == ucFailed: t.roles[rlError]
               else: t.roles[rlWarning]
  template words() =
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour))
    igTextWrapped("%s", text.cstring)
    igPopStyleColor(1)
    marks.mark("plot.wait")
  template buttons() =
    if w.kind in {wkOpening, wkReading}:
      if igSmallButton("Cancel##wait"):
        res.commands.add(if w.kind == wkOpening: Command(kind: ckCancelJob, job: w.job)
                         else: Command(kind: ckStopReading, panel: panel))
      marks.mark("plot.wait.cancel")
      tip(if w.kind == wkOpening: "Stop opening the file: the plot stays as it was"
          else: "Stop waiting for this read: the plot keeps what it shows")
      igSameLine(0, -1)
    if igSmallButton((IconRefresh & " Retry##wait").cstring):
      res.commands.add Command(kind: ckRetry, panel: panel)
    marks.mark("plot.wait.retry")
    tip("Try the drive again")
  if centred:
    let avail = igGetContentRegionAvail()
    let at = igGetCursorPos()
    let width = min(avail.x, igCalcTextSize(text.cstring, nil, false, -1).x)
    igSetCursorPos(ImVec2_c(x: at.x + max(0, (avail.x - width) / 2), y: at.y + avail.y / 2 - 20))
    igPushTextWrapPos(igGetCursorPosX() + width)
    words()
    igPopTextWrapPos()
    igSetCursorPosX(at.x + max(0, avail.x / 2 - 4 * igGetFontSize()))
    buttons()
  else:
    buttons()
    igSameLine(0, -1)
    words()

proc drawTracePanel*(tp: var TracePanelUi; id: string; st: AppState; panel: PanelId;
    t: Theme; fonts: Fonts; marks: var Marks): PanelOutput =
  ## The plot window of `panel`, titled for what it shows ("Seismic", "Aux":
  ## `windowTitle`) with the ImGui ID `id` (`"###" & id`), so that a new
  ## title keeps the window's place in the layout; marked as its title in
  ## lower case ("seismic"). Its controls, then the start screen, a note, or
  ## the plot. Returns the commands and actions it asks for, and what lies
  ## under the mouse.
  result.pick = noPick()
  let name = st.windowTitle(panel)
  let title = IconPlot & "  " & name & "###" & id
  # Arrow keys pan the plot, so they do not move ImGui's keyboard focus here;
  # the wheel zooms, so it does not scroll the window.
  const windowFlags = ImGui_WindowFlags_NoNavInputs.cint or
    ImGui_WindowFlags_NoScrollWithMouse.cint or ImGui_WindowFlags_NoScrollbar.cint
  var plotted = false
  if igBegin(title.cstring, nil, windowFlags):
    tp.focus.watch()
    # The window never scrolls as a whole: the strip wraps and the plot fits.
    igSetScrollX_Float(0)
    igSetScrollY_Float(0)
    marks.markWindow(name.toLowerAscii)
    let k = st.findPanel(panel)
    if k < 0 or st.panels[k].layers.len == 0:
      drawStartScreen(t, st.settings.recentFiles, st.settings.recentFolders, marks, result)
    else:
      template p: untyped = st.panels[k]
      let mon = monitorOf(igGetWindowViewport())
      let ppi = st.settings.ppiFor(mon.name, mon.displayScale)
      var ask = ViewAsk()
      tp.drawControls(st, p, t, marks, result, ask, ppi, mon)
      let source = p.layers[0].source
      let s = if source.kind == lsRecord: st.findSession(source.file) else: -1
      let name = if s >= 0: st.sessions[s].name else: "the file"
      let again = if s < 0: st.reopening(panel) else: ("", false)
      let wait = st.waiting(k)
      if tp.gpuError.len > 0:
        centredText("The plot cannot be drawn: " & tp.gpuError, t.roles[rlError])
      elif wait.kind != wkNone and not p.laidOut:
        drawWaiting(wait, panel, t, marks, result, centred = true)
      elif again.path.len > 0:
        let changed = again.path.extractFilename
        centredText(if again.waiting: changed & " is being changed by another program: it " &
            "is shown again once it stops changing."
          else: "Opening " & changed & " again...", t.roles[rlTextDim])
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
        if wait.kind != wkNone:
          drawWaiting(wait, panel, t, marks, result, centred = false)
        tp.drawPlot(st, k, t, fonts, marks, result, ask, ppi)
        plotted = true
  tp.focus.settle()
  igEnd()
  # No plot this frame (a new gather or file is being read, the window is
  # hidden): the trace this plot hovered is not shown, so it is not hovered.
  if not plotted and tp.hovering:
    result.commands.add Command(kind: ckHover, trace: -1)
    tp.hovering = false
