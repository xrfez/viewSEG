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
## box, arrows to pan, Ctrl + 0 to fit, Backspace for back (Alt + arrows
## step through the record's traces), Esc to cancel a drag, and the scroll bars (`plotbars`) beside the plot
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
## only while the gather has an edit: "K" killed, "R" reversed, "E" excluded from the plot's filters. A right
## click on a mark opens a menu for that trace's edits (and, zoomed out,
## for the traces that share its pixel); a right click elsewhere is the
## plot's menu or the header's, as before. Killed
## traces are drawn blank, or left out of the plot (the gear popover's
## "Hide killed traces", a setting). New plot > FFT (`F`) opens the
## amplitude spectrum of the same traces (`ckSpectrum`, `spectrumwindow`).

import std/[algorithm, math, options, os, strutils, tables]
import imguin/cimgui
import ../../core/[components, editmarks, explain, geometry, openchoice, state, wiggle]
import ../../gpu/[plotimage, textures]
import ../../view/[areabands, breakbars, displayheader, maplayers, plotink, strip, theme, timeaxis,
  vendorfieldmenu]
from windows import awAux, beginClosable
import auxmarkmenu, stationmovemenu, breakdraw, chrome, dpi, explainmenu, fittext, focus, fonts,
    icons, menus, plotbars, plotfilters, plotgain, plotsort,
  shortcutkeys,
  plotviews, references, style,
  symbols

export PaperBackground, PaperInk

const
  modeSymbols: array[DisplayMode, Symbol] = [syDensity, syWiggle, syWiggleDensity]
  fillSymbols: array[WiggleFill, Symbol] = [syWigglePositive, syWiggleNegative]
  menuId = "##plotmenu"
  headerMenuId = "##headermenu"
  markMenuId = "##editmark"
  gotoId = "Go to record##goto"
  MinPlotLines = 10.0
    ## the plot's least height, in lines of text: the strip scrolls rather
    ## than take it
  moreId = "##plotmore"
  compPickerId = "##compcolour"
  burstSeconds = 0.6 ## wheel turns or key presses closer than this are one gesture
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

  MarkChoice = object
    ## One line of the edits-mark menu, snapshotted when it opened.
    text: string
    item: MarkItem
    traces: seq[int] ## survey-wide ids

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
    plotted: bool ## the plot was drawn last frame (else nothing, or `instead`)
    instead: string ## what the window said last frame in place of the plot
    marks: int ## bumped whenever a tile's marks of selected traces change
    selected: seq[bool] ## scratch: a tile's selected rows
    markerKey: (int, seq[uint64], int) ## what `markerAt` was found for: revision, tiles, base
    markerAt: seq[int] ## the positions of the selected traces the tiles hold, sorted
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
    gainBox: GainBox
    openSort: bool ## Custom... was picked: open the keys popover next frame
    sortShown: string ## the sort drop-down's label, as drawn (for tests)
    calib: CalibrationUi
    sortKeys: SortKeysUi
    stripWidths: array[StripGroup, float32] ## the strip's groups as drawn last frame
    gearWidth: float32 ## the gear button's width as drawn last frame
    stripHeight: float32 ## the strip's height as drawn last frame, all its lines
    goto: GoToUi
    menuTarget: string ## what the plot's menu acts on, said when it opened
    menuUnder: int = -1 ## the trace under the pointer when it opened (survey-wide); -1 for none
    menuStations: Command = Command(kind: ckSelectPoints)
      ## what its "Select its receiver on the map" sends, found when it opened
    menuPick: Pick ## what lay under the pointer when it opened, held while it is open
    menuMouse: ImVec2_c ## where the pointer was then
    ownAsk: bool ## the menu asked for the filter popover: open it next frame
    ownTraces: seq[int] ## survey-wide ids the popover sets a filter on
    ownDraft: OwnFilter ## the filter the popover is editing
    ownMixed: bool ## the selection holds different filters: the draft starts empty
    ownPos: ImVec2_c ## where the popover opens
    shiftAsk: bool ## the menu asked for the time-shift popover: open it next frame
    shiftTraces: seq[int] ## survey-wide ids the popover shifts
    shiftText: array[32, char] ## the milliseconds being typed
    shiftMixed: bool ## the selection holds different shifts: the field starts empty
    shiftPos: ImVec2_c ## where the popover opens
    editMarks: seq[EditMark] ## the edits row as drawn this frame
    editBand0, editBand1: float32 ## the row across the traces, this frame
    editAxis: ScreenAxis ## the traces' axis, this frame
    markAsk: bool ## open the mark menu this frame
    markTitle: string
    markChoices: seq[MarkChoice]
    markMouse: ImVec2_c ## where it opened, for the filter popover
    store: StoreDialog ## Store as reference, opened from the plot's menu
    aux: AuxMarkUi ## the auxiliary trace's mark and shift, from the plot's menu
    station: StationMoveUi ## the station move's dialog, from the plot's menu
    menuAux: int ## the auxiliary position of the trace under the menu; 0 for none
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
    bandKey: (uint64, seq[HeaderRef])
    picking: int ## the colour whose picker is open (as `colourKeys` lists them)
    hex: array[12, char] ## what the picker's `#rrggbb` box holds
    componentPicking: int ## the component colour whose picker is open (0..3)
    componentHex: array[12, char]
    presetBox: array[4 * MaxPresetName + 1, char]
    renameBox: array[4 * MaxPresetName + 1, char]
      ## a preset's right-click menu's name box: its new name
      ## the Display presets section's name box: UTF-8, up to 4 bytes a character
    presetPicked: string ## the preset clicked last there: Rename and Delete act on it
    moreSize: ImVec2_c ## the gear popover's size, as drawn last

  PanelOutput* = object
    ## What the plot window asks for.
    commands*: seq[Command]
    actions*: set[MenuAction]
    pick*: Pick         ## what lies under the mouse; `noPick()` when it is not over the plot
    notes*: seq[string] ## warnings for the log (a scale that is not a number)
    stepFile*: int
      ## Page Down (1) or Page Up (-1) at the last or first record of a signature file: the
      ## Files window's next or previous file is wanted (its order and filters), as its arrow
      ## keys would show it

func setOf(t: Tile; row: int): string {.inline.} =
  ## The channel set in words of row `row` of tile `t`; "" for none.
  if row < t.sets.len: t.sets[row] else: ""

func caption(h: HeaderRef): string =
  ## A header row's name as it stands left of the plot: short, so it fits
  ## beside the time axis; a vendor field's own name.
  case h.field
  of hfComponent: "comp"
  of hfChannel: "chan"
  of hfChannelSet: "set"
  of hfTraceId: "id"
  of hfSrcLine: "S line"
  of hfSrcPoint: "S point"
  of hfCrossline: "xline"
  else: $h

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

func plotShown*(tp: TracePanelUi): bool {.inline.} = tp.plotted
  ## Whether the plot was drawn last frame: else its image is of an earlier
  ## one, not what the window shows (`instead` says what it showed).

func instead*(tp: TracePanelUi): lent string {.inline.} = tp.instead
  ## What the window said last frame in place of the plot; "" when it
  ## showed the start screen or was not on screen.

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

func sortShown*(tp: TracePanelUi): string {.inline.} = tp.sortShown
  ## The sort drop-down's label, as drawn last (for tests).

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

proc sync(tp: var TracePanelUi; tiles: openArray[Tile]; base: int; sel: Selection;
    slots: array[256, uint8]; useSlots: bool) =
  ## Uploads the tiles the GPU does not have and frees the ones `core` no
  ## longer keeps, so `textures[i]` is the copy of `tiles[i]`; marks each
  ## one's hovered and selected traces, and those the map's pointer lights
  ## up (`base`: the survey-wide id of the file's first trace), when the
  ## selection or the map's hover has changed since. `slots` is each
  ## component's colour when `useSlots`.
  var kept: seq[TileTextures]
  for t in tiles:
    var found = -1
    for i in 0 ..< tp.textures.len:
      if tp.textures[i].id == t.id: found = i
    if found >= 0:
      kept.add move tp.textures[found]
      tp.textures.delete(found)
    else:
      kept.add tp.renderer.upload(t, slots, useSlots)
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
      tt.setMarks(t, tp.selected, tp.lit, slots, useSlots)
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
    for i, row in t.header:
      for r, v in row: n = max(n, headerLabel(t.fields[i], v, setOf(t, r)).len)
    tp.labelChars[t.id] = n
  tp.labelChars[t.id]

proc bandChars(tp: var TracePanelUi; tiles: openArray[Tile]; fields: openArray[HeaderRef];
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
          for r, v in row:
            chars[i] = max(chars[i], headerLabel(t.fields[i], v, setOf(t, r)).len)
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

func headerValue(tiles: openArray[Tile]; fields: openArray[HeaderRef]; row,
    position: int): (bool, float64, string) =
  ## The value of header row `row` at `position`, from the newest tile that
  ## has it with these fields, and the trace's channel set in words (""
  ## when the tile has none).
  for i in countdown(tiles.high, 0):
    let r = tiles[i].request
    if tiles[i].fields == fields and position >= r.first and position <= r.last and
        (position - r.first) mod r.stride == 0:
      let at = (position - r.first) div r.stride
      return (true, tiles[i].header[row][at], tiles[i].setOf(at))
  (false, NaN, "")

func headerJoined(tiles: openArray[Tile]; fields: openArray[HeaderRef]; row,
    position: int): bool =
  ## Whether the value of header row `row` at `position` (as `headerValue`
  ## finds it) was given by a geometry join, not by the trace's header.
  for i in countdown(tiles.high, 0):
    let r = tiles[i].request
    if tiles[i].fields == fields and position >= r.first and position <= r.last and
        (position - r.first) mod r.stride == 0:
      return (tiles[i].joinedAt((position - r.first) div r.stride) *
        joinGroupsOf(fields[row].field)) != {}
  false

const MarkerSize = 6'f32 ## a selection marker's height, in pixels (its bar's thickness)

proc selectedPositions(tp: var TracePanelUi; tiles: openArray[Tile]; base: int;
    sel: Selection): seq[int] =
  ## The positions of the selected traces the tiles hold, ascending, each
  ## once; found again only when the selection or the tiles change.
  var ids = newSeq[uint64](tiles.len)
  for i, t in tiles: ids[i] = t.id
  let key = (sel.selectedRevision, ids, base)
  if key != tp.markerKey:
    tp.markerKey = key
    tp.markerAt.setLen 0
    if base >= 0 and sel.selected.len > 0:
      for t in tiles:
        let r = t.request
        for row, trace in t.traces:
          if row < r.count and base + trace in sel.selected: tp.markerAt.add r.position(row)
      tp.markerAt.sort()
      var n = 0
      for p in tp.markerAt:
        if n == 0 or tp.markerAt[n - 1] != p:
          tp.markerAt[n] = p
          inc n
      tp.markerAt.setLen n
  tp.markerAt

proc drawSelectionMarkers(tp: var TracePanelUi; tiles: openArray[Tile]; base: int;
    sel: Selection; view: Viewport; layout: PanelLayout; m: Turn; plotPos, plotSize: ImVec2_c;
    t: Theme; marks: var Marks) =
  ## A marker above (time down) or left of (time across) each selected trace,
  ## in the selection colour, on the strip the display header's values stand
  ## in: a small triangle for a lone trace, a bar for traces so close that
  ## their markers meet. One draw list entry per run, never per trace beyond
  ## what is visible.
  let at = tp.selectedPositions(tiles, base, sel)
  if at.len == 0: return
  let dl = igGetWindowDrawList()
  let ta = m.along[axTraces]
  let ba = m.along[axTime]
  let perPos = plotSize.along(ta) / max(view.traces.width, 1e-9)
  let vis = visiblePositions(layout, view)
  let colour = u32(readableOn(t.roles[rlSelected], t.roles[rlBackdrop]))
  let (t0, t1) = (plotPos.along(ta), plotPos.along(ta) + plotSize.along(ta))
  let edge = plotPos.along(ba) # the plot's edge the markers stand against
  let (e0, e1) = (edge - MarkerSize, edge)
  var runs: seq[(float32, float32)] # the screen extent of each run along the traces
  var runLo, runHi = -1'f32
  for p in at:
    if p < vis.a or p > vis.b: continue
    let c = traceAt(view, m, plotPos, plotSize, float64(p))
    if runLo < 0: (runLo, runHi) = (c, c)
    elif c - runHi <= 6: runHi = c
    else:
      runs.add (runLo, runHi)
      (runLo, runHi) = (c, c)
  if runLo >= 0: runs.add (runLo, runHi)
  for i, (lo, hi) in runs:
    let (a, b) = (clamp(lo - 3, t0 - 3, t1 + 3), clamp(hi + 3, t0 - 3, t1 + 3))
    if hi - lo < 1: # a lone trace: a triangle pointing at it
      let c = (a + b) / 2
      ImDrawList_AddTriangleFilled(dl, vec(ta, c - 3.5, e0), vec(ta, c + 3.5, e0),
        vec(ta, c, e1), colour)
    else:
      ImDrawList_AddRectFilled(dl, vec(ta, a, e0 + 2), vec(ta, b, e1), colour, 0, 0)
    marks.markRect("plot.selection marker " & $(i + 1), vec(ta, a, e0), vec(ta, b, e1))
  if runs.len > 0:
    marks.markRect("plot.selection markers", vec(ta, t0, e0), vec(ta, t1, e1))

proc button(label: string; t: Theme; marks: var Marks; mark: string): bool =
  result = igButton(label.cstring, ImVec2_c(x: 0, y: 0))
  marks.mark(mark)

var
  axisEnds: TimeEnds # the time axis's end labels this frame, read by `axisLabel`
  axisChars: int

proc snprintf(buf: cstring; n: csize_t; fmt: cstring): cint {.importc, header: "<stdio.h>",
  varargs.}

proc axisLabel(v: cdouble; buf: cstring; size: cint; data: pointer): cint {.cdecl.} =
  ## ImPlot's formatter for the time axis: `%g` padded to the axis's width,
  ## blank where the tick gives way to an end label.
  if axisEnds.givesWay(v):
    snprintf(buf, csize_t(size), "%*s", cint(axisChars), "")
  else:
    snprintf(buf, csize_t(size), "%*g", cint(axisChars), v)

func auxHint(st: AppState; k: int): string =
  ## What to do when the shown file holds auxiliary traces only and none is marked for
  ## correlation; "" otherwise.
  let i = st.shownFile(k)
  if i >= 0 and st.sessions[i].noSeismic and
      not anyMarked(st.editsAt(st.sessions[i].diskPath).auxMarks, st.projectAuxMarks):
    AuxMarkHint
  else: ""

proc tip(text: string; dim = Rgba()) =
  ## The last item's tooltip. A line that starts "Shortcut: " is drawn in
  ## `dim` when that colour is set.
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    var rest = text
    while rest.len > 0:
      let nl = rest.find('\n')
      let row = if nl >= 0: rest[0 ..< nl] else: rest
      rest = if nl >= 0: rest[nl + 1 .. ^1] else: ""
      let shade = dim.a > 0 and row.startsWith("Shortcut: ")
      if shade: igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(dim))
      igTextUnformatted(row.cstring, nil)
      if shade: igPopStyleColor(1)
    igEndTooltip()

proc tipAlways(text: string) =
  ## A tooltip that shows on a disabled item too.
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

var vendorFilter: array[64, char] # the filter box of the vendor fields submenu

proc drawVendorFields(p: Panel; st: AppState; marks: var Marks; prefix: string;
    res: var PanelOutput) =
  ## The "Vendor fields" submenu: the shown file's numeric vendor fields, ticked when a
  ## line of the display header (`vendorFieldMenu` makes the list).
  let shown = p.shownFields
  let at = st.findPanel(p.id)
  let file = if at >= 0: st.shownFile(at) else: -1
  let list = if file < 0: some(VendorFieldList())
             else: st.vendorFields(st.sessions[file].id)
  igSeparator()
  let open = igBeginMenu("Vendor fields", true)
  marks.mark(prefix & "vendor")
  tip("Fields of the vendor header maps that the shown file has: tick one to show it as a " &
    "line of the display header, over the traces")
  if open:
    let first = vendorFieldMenu(list, shown, "")
    if first.filtered:
      igSetNextItemWidth(igGetFontSize() * 16)
      discard igInputTextWithHint("##vendorfilter", "Filter fields",
        cast[cstring](addr vendorFilter[0]), csize_t(vendorFilter.len), 0, nil, nil)
      marks.mark(prefix & "vendor filter")
      tip("Show only the fields whose name holds this text")
    let menu = vendorFieldMenu(list, shown,
      if first.filtered: ($cast[cstring](addr vendorFilter[0])).strip else: "")
    case menu.kind
    of vmReading, vmNone, vmNoMatch:
      let (words, why) = case menu.kind
        of vmReading: (ReadingWords, ReadingTip)
        of vmNone: (NoFieldsWords, NoFieldsTip)
        else: (NoMatchWords, "Change the filter to see more fields")
      igBeginDisabled(true)
      discard igMenuItem_Bool(words.cstring, nil, false, false)
      igEndDisabled()
      tipAlways(why)
    of vmItems:
      for item in menu.items:
        var on = item.ticked
        igBeginDisabled(not item.enabled)
        let clicked = igCheckbox(item.label.cstring, addr on)
        igEndDisabled()
        marks.mark(prefix & "vendor " & item.name)
        tipAlways(item.tip)
        if clicked:
          res.commands.add Command(kind: ckHeader, panel: p.id,
            header: HeaderChoice(auto: false, fields: shown.withVendorLine(item.name, on)))
    igEndMenu()

proc drawHeaderChoice(p: Panel; st: AppState; marks: var Marks; prefix: string;
    res: var PanelOutput) =
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
    if f == hfVendor: continue # a vendor line is chosen by name, not from this list
    var on = f in shown
    let have = f in p.known
    let label = $f & (if have: "" else: "  (not in this file)")
    let clicked = igCheckbox(label.cstring, addr on)
    marks.mark(prefix & $f)
    if clicked:
      var fields: seq[HeaderRef]
      for g in HeaderField:
        if g != hfVendor and ((g == f and on) or (g != f and g in shown)): fields.add g
      for g in shown: # the vendor lines already chosen stay, after the built-in ones
        if g.field == hfVendor: fields.add g
      if fields.len > 0:
        res.commands.add Command(kind: ckHeader, panel: p.id,
          header: HeaderChoice(auto: false, fields: fields))
  p.drawVendorFields(st, marks, prefix, res)
  igEndDisabled()

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
    if c == pcRedPaper: continue # the Aux window's start, not a scheme to pick
    let (text, help) = case c
      of pcPaper: ("Paper", "White paper, black wiggles and fill, red negative fill, " &
        "whatever the theme")
      of pcTheme: ("Follow the theme", "The theme's plot colours")
      of pcCustom: ("My own", "The colours you chose below")
      of pcRedPaper: ("", "")
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

proc fillComponentHex(tp: var TracePanelUi; c: Rgba) =
  let text = toHex(Rgba(r: c.r, g: c.g, b: c.b, a: 255))
  zeroMem(addr tp.componentHex[0], tp.componentHex.len)
  copyMem(addr tp.componentHex[0], text.cstring, min(text.len, tp.componentHex.len - 1))

proc drawComponentColours(tp: var TracePanelUi; st: AppState; t: Theme; marks: var Marks;
    res: var PanelOutput) =
  ## The four component colours, stored with the settings, and Reset.
  const
    names = ["Hydrophone", "Vertical", "Inline", "Crossline"]
    keys = ["hydrophone", "vertical", "inline", "crossline"]
  let stored = st.settings.componentColours
  let size = igGetFrameHeight()
  # One row, so the Look tab still fits the default window with the colour maps.
  for i in 0 ..< names.len:
    if i > 0: igSameLine(0, 8)
    let shown = stored[i]
    if igColorButton(("##compcolour" & keys[i]).cstring, vec4(shown),
        ImGui_ColorEditFlags_NoAlpha.ImGuiColorEditFlags, ImVec2_c(x: size, y: size)):
      tp.componentPicking = i
      tp.fillComponentHex(shown)
      igOpenPopup_Str(compPickerId, 0)
    marks.mark("plot.component colour." & keys[i])
    igSameLine(0, 4)
    igTextUnformatted(names[i].cstring, nil)
    tip(names[i] & ": the colour of that component's traces and its button")
  igSameLine(0, 12)
  if igButton("Reset##compcolours", ImVec2_c(x: 0, y: 0)):
    var s = st.settings
    s.componentColours = DefaultComponentColours
    res.commands.add Command(kind: ckSettings, settings: s)
  marks.mark("plot.component colour.reset")
  tip("The component colours back to hydrophone blue, vertical green, inline yellow, " &
    "crossline teal")
  if igBeginPopup(compPickerId, 0):
    marks.markWindow("plot.component colour picker")
    let i = clamp(tp.componentPicking, 0, names.high)
    let was = stored[i]
    igTextUnformatted(names[i].cstring, nil)
    var col: array[3, cfloat] = [cfloat(was.r) / 255, cfloat(was.g) / 255, cfloat(was.b) / 255]
    var picked = was
    var changed = false
    if igColorPicker3("##comppicker", col, (ImGui_ColorEditFlags_NoInputs.cint or
        ImGui_ColorEditFlags_NoSidePreview.cint).ImGuiColorEditFlags):
      func byte(v: cfloat): uint8 = uint8(clamp(round(v * 255), 0, 255))
      picked = Rgba(r: byte(col[0]), g: byte(col[1]), b: byte(col[2]), a: 255)
      changed = true
    igSetNextItemWidth(round(igCalcTextSize("#0000000", nil, false, -1).x +
      2 * igGetStyle().FramePadding.x))
    let hexActive = igInputText("##comphex", cast[cstring](addr tp.componentHex[0]),
      csize_t(tp.componentHex.len), ImGui_InputTextFlags_EnterReturnsTrue.cint or
      ImGui_InputTextFlags_AutoSelectAll.cint, nil, nil) or igIsItemDeactivatedAfterEdit()
    let typing = igIsItemActive()
    marks.mark("plot.component colour hex")
    tip("The colour as #rrggbb: type one and press Enter")
    if hexActive:
      var c: Rgba
      let text = $cast[cstring](addr tp.componentHex[0])
      if parseColor(text.strip, c):
        picked = Rgba(r: c.r, g: c.g, b: c.b, a: 255)
        changed = true
      else:
        res.notes.add "A colour is written #rrggbb (as #ff8000), not \"" & text.strip & "\"."
    if changed and picked != was:
      var s = st.settings
      s.componentColours[i] = picked
      res.commands.add Command(kind: ckSettings, settings: s)
    if not typing and not hexActive: tp.fillComponentHex(if changed: picked else: was)
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

proc drawWiggleSettings(p: Panel; marks: var Marks; res: var PanelOutput) =
  ## The trace overlap: -, a box, +, as the strip had them, greyed in density.
  let d = p.layers[0].display
  let o = d.effectiveOverlap
  const help = "Trace overlap: how far the strongest amplitudes swing a wiggle, in " &
    "trace spacings (1 reaches the next trace; anything stronger is clipped there)"
  let note = if d.mode == dmDensity: " (with wiggles)" else: ""
  template send(o: float64) =
    var nd = d
    nd.overlap = o
    res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
  igBeginDisabled(d.mode == dmDensity)
  igTextUnformatted("Trace overlap", nil)
  tipAlways(help & note)
  igSameLine(0, -1)
  if igButton("-##overlapless", ImVec2_c(x: 0, y: 0)) and o > MinOverlap:
    send(overlapStep(o, up = false))
  marks.mark("plot.overlap less")
  tipAlways("Less overlap: " & significant(overlapStep(o, up = false)) & " trace spacings")
  igSameLine(0, 2)
  var v = cdouble(o)
  igSetNextItemWidth(round(igCalcTextSize("000.00", nil, false, -1).x +
    2 * igGetStyle().FramePadding.x))
  discard igInputDouble("##overlap", addr v, 0, 0, "%.2f", 0)
  if igIsItemDeactivatedAfterEdit() and float64(v) != o:
    if v >= MinOverlap and v <= MaxOverlap: send(float64(v))
    else:
      res.notes.add "The trace overlap needs " & significant(MinOverlap) & " to " &
        significant(MaxOverlap) & " trace spacings, not " & significant(float64(v)) & "."
  marks.mark("plot.overlap")
  tipAlways(help & note)
  igSameLine(0, 2)
  if igButton("+##overlapmore", ImVec2_c(x: 0, y: 0)) and o < MaxOverlap:
    send(overlapStep(o, up = true))
  marks.mark("plot.overlap more")
  tipAlways("More overlap: " & significant(overlapStep(o, up = true)) & " trace spacings")
  igSameLine(0, -1)
  igTextUnformatted("trace spacings", nil)
  tipAlways(help & note)
  igEndDisabled()

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

proc refreshScaleText(tp: var TracePanelUi; u: ScaleUnits; ppi: float64) =
  ## What the scale boxes show, kept while the gear is closed so a test can
  ## read it.
  if not tp.traceBox.editing:
    tp.traceBox.fill(significant(traceScale(tp.cur, ppi, u), 4))
  if not tp.timeBox.editing:
    tp.timeBox.fill(significant(timeScale(tp.cur, ppi, u), 4))

proc drawScaleBoxes(tp: var TracePanelUi; u: ScaleUnits; ppi: float64; marks: var Marks;
    ask: var ViewAsk; res: var PanelOutput) =
  ## The two scale boxes: traces per inch or cm, and ms per inch or cm (or
  ## in/s). Enter applies.
  let per = lengthName(u.length)
  if tp.traceBox.scaleBox("##tracescale", traceLabel(u), "Traces per " & per &
      ": type a value and press Enter", traceScale(tp.cur, ppi, u), marks, "plot.trace scale"):
    askScale(tp.traceBox, vaTraceScale, "trace scale", ask, res)
  igSameLine(0, 10)
  let timeTip = if u.speed: per & "es per second" else: "Milliseconds per " & per
  if tp.timeBox.scaleBox("##timescale", timeLabel(u), timeTip & ": type a value and press Enter",
      timeScale(tp.cur, ppi, u), marks, "plot.time scale"):
    askScale(tp.timeBox, vaTimeScale, "time scale", ask, res)

proc drawScaleSettings(tp: var TracePanelUi; st: AppState; marks: var Marks;
    res: var PanelOutput; ppi: float64; mon: MonitorInfo; ask: var ViewAsk) =
  ## The scale boxes, then the scale units and the calibration of the monitor
  ## the window is on.
  tp.drawScaleBoxes(st.settings.scale, ppi, marks, ask, res)
  var s = st.settings
  igSeparatorText("Scales")
  igTextUnformatted("Scales per", nil)
  for u in LengthUnit:
    igSameLine(0, -1)
    if igRadioButton_Bool(lengthName(u).cstring, s.scale.length == u) and
        s.scale.length != u:
      s.scale.length = u
      res.commands.add Command(kind: ckSettings, settings: s)
    tip("Show the scales in " & (if u == luInch: "inches" else: "centimetres"))
  var speed = s.scale.speed
  if igCheckbox(("Time as speed (" & $s.scale.length & "/s, not ms/" & $s.scale.length &
      ")").cstring, addr speed):
    s.scale.speed = speed
    res.commands.add Command(kind: ckSettings, settings: s)
  tip("Show time as a speed instead of milliseconds per inch or centimetre")
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
  tip("The monitor's diagonal, in inches, as its specification gives it")
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
  tip("How long the ruler you hold to the screen is")
  for u in LengthUnit:
    igSameLine(0, -1)
    if igRadioButton_Bool(($u & "##ruler").cstring, tp.calib.rulerUnit == u):
      tp.calib.rulerUnit = u
    tip("The ruler's unit")
  igSameLine(0, -1)
  igTextUnformatted("long:", nil)
  igSetNextItemWidth(round(igGetFontSize() * 24))
  var px = cdouble(tp.calib.rulerPx)
  igSetNextItemWidth(numberWidth)
  discard igInputDouble("##rulerpx", addr px, 0, 0, "%.0f", 0)
  if igIsItemDeactivatedAfterEdit(): tp.calib.rulerPx = cfloat(clamp(px, 50.0, 2400.0))
  igSameLine(0, -1)
  igTextUnformatted("pixels", nil)
  tip("Type the bar's length in pixels (50 to 2400) until it matches the ruler you hold to the screen")
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
  tip("Use the bar's length as this monitor's calibration")
  if not cal.isNaN:
    igSameLine(0, -1)
    if igButton("Forget the calibration", ImVec2_c(x: 0, y: 0)):
      s.calibrate(mon.name, NaN)
      tp.calib.rulerPx = 0
      res.commands.add Command(kind: ckSettings, settings: s)
    tip("Forget this monitor's calibration and use the assumed size")

template stripGroup(tp: var TracePanelUi; g: StripGroup; firstEdge, fullEdge, spacing,
    lift: float32; started, onFirst: var bool; body: untyped) =
  ## Group `g` of the strip, its controls `lift` below the top of its line.
  ## On the first line a group wraps when it would pass `firstEdge` (the
  ## gear's place, kept free at the right of that line); later lines use
  ## `fullEdge`. A group that does not fit goes to a new line, whole: the
  ## strip wraps, so the window never needs to scroll.
  let edge = if onFirst: firstEdge else: fullEdge
  if started and igGetItemRectMax().x + spacing + tp.stripWidths[g] <= edge:
    igSameLine(0, spacing)
  elif started:
    onFirst = false
  started = true
  igBeginGroup()
  if lift > 0: # a gap item, so every control of the group starts below it
    igPushStyleVar_Vec2(ImGui_StyleVar_ItemSpacing.cint,
      ImVec2_c(x: igGetStyle().ItemSpacing.x, y: 0))
    igDummy(ImVec2_c(x: 0, y: lift))
    igPopStyleVar(1)
  body
  igEndGroup()
  tp.stripWidths[g] = igGetItemRectSize().x

func hasAux(st: AppState; p: Panel): bool =
  ## Whether the record `p` shows holds auxiliary traces (the record list's
  ## count, from the index).
  if p.layers.len > 0 and p.layers[0].source.kind == lsRecord:
    let i = st.findSession(p.layers[0].source.file)
    let g = p.layers[0].source.gather
    result = i >= 0 and g in 0 ..< st.sessions[i].records.len and
      st.sessions[i].records[g].aux > 0

func shownSignature(st: AppState; p: Panel): bool =
  ## Whether `p` shows a vibrator signature file (one record: the Page keys step to the next
  ## file instead).
  if p.layers.len > 0 and p.layers[0].source.kind == lsRecord:
    let i = st.findSession(p.layers[0].source.file)
    result = i >= 0 and st.sessions[i].isSignature

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
  ## says (the one shown now drawn selected), or to right-click, for a menu
  ## that applies, renames or deletes it without drawing it first; a box for
  ## a name, Save (the display shown, under that name), Rename and Delete
  ## (the preset clicked or right-clicked last).
  let presets = st.settings.displayPresets
  let shown = presets.shownPreset(p.layers[0].display)
  template command(action: PresetAction; name: string; newName = "") =
    res.commands.add Command(kind: ckDisplayPreset, panel: p.id, presetAction: action,
      presetName: name, presetNewName: newName)
  let typed = ($cast[cstring](addr tp.presetBox[0])).strip
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
    tip("Click: draw the plot as \"" & q.name & "\" says (it stays turned as it is).\n" &
      "Right-click: apply, rename or delete it, without drawing it first.")
    if igBeginPopupContextItem(("##presetmenu" & $i).cstring,
        ImGui_PopupFlags_MouseButtonRight.cint):
      tp.presetPicked = q.name # the Rename and Delete buttons act on it too
      marks.markWindow("plot.preset menu")
      if igMenuItem_Bool("Apply", nil, false, true): command(paApply, q.name)
      marks.mark("plot.preset menu apply")
      # its new name typed in the menu itself: one trip
      if igIsWindowAppearing():
        zeroMem(addr tp.renameBox[0], tp.renameBox.len)
        copyMem(addr tp.renameBox[0], q.name.cstring, min(q.name.len, tp.renameBox.len - 1))
      igAlignTextToFramePadding()
      igTextUnformatted("Rename to", nil)
      igSameLine(0, -1)
      igSetNextItemWidth(round(igCalcTextSize("A preset's long name", nil, false, -1).x +
        2 * igGetStyle().FramePadding.x))
      let renamed = igInputText("##presetrename", cast[cstring](addr tp.renameBox[0]),
        csize_t(tp.renameBox.len), (ImGui_InputTextFlags_EnterReturnsTrue.cint or
        ImGui_InputTextFlags_AutoSelectAll.cint).ImGuiInputTextFlags, nil, nil)
      marks.mark("plot.preset menu name")
      let newName = ($cast[cstring](addr tp.renameBox[0])).strip
      igSameLine(0, -1)
      igBeginDisabled(newName.len == 0 or newName == q.name)
      let clicked = igButton("Rename##presetmenu", ImVec2_c(x: 0, y: 0))
      igEndDisabled()
      marks.mark("plot.preset menu rename")
      if (clicked or renamed) and newName.len > 0 and newName != q.name:
        command(paRename, q.name, newName)
        tp.presetPicked = newName
        igCloseCurrentPopup()
      if igMenuItem_Bool(("Delete \"" & q.name & "\"").cstring, nil, false, true):
        command(paDelete, q.name)
        tp.presetPicked = ""
      marks.mark("plot.preset menu delete")
      igEndPopup()
  igSetNextItemWidth(round(igCalcTextSize("A preset's long name", nil, false, -1).x +
    2 * igGetStyle().FramePadding.x))
  let entered = igInputTextWithHint("##presetname", "a name", cast[cstring](addr tp.presetBox[0]),
    csize_t(tp.presetBox.len), ImGui_InputTextFlags_EnterReturnsTrue.cint, nil, nil)
  marks.mark("plot.preset name")
  tip("The name to save the display shown under, or to give the preset clicked last")
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
            else: "Click or right-click a preset first, then type its new name")
  igSameLine(0, -1)
  igBeginDisabled(not known)
  if igButton("Delete##preset", ImVec2_c(x: 0, y: 0)):
    command(paDelete, tp.presetPicked)
    tp.presetPicked = ""
  igEndDisabled()
  marks.mark("plot.preset delete")
  tipAlways(if known: "Forget \"" & tp.presetPicked & "\""
            else: "Click or right-click a preset first")

proc componentToggle(label: string; on: bool; colour: Rgba; t: Theme): bool =
  ## A short letter on the component's colour. Off: the colour washed toward
  ## the button, so it stays recognisable and clearly not on.
  let face = if on: colour else: mix(colour, t.roles[rlFrame], 0.72)
  let ink = if luminance(face) > 0.45: Black else: White
  igPushStyleColor_Vec4(ImGui_Col_Button.cint, vec4(face))
  igPushStyleColor_Vec4(ImGui_Col_ButtonHovered.cint, vec4(mix(face, ink, 0.12)))
  igPushStyleColor_Vec4(ImGui_Col_ButtonActive.cint, vec4(mix(face, ink, 0.22)))
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(ink))
  result = igButton(label.cstring, ImVec2_c(x: 0, y: 0))
  igPopStyleColor(4)

func breakTip(on: bool; b: FirstBreaks): string =
  ## The overlay button's tooltip after its name: what the two bars are,
  ## whether it is on, and what it lacks.
  result = (if on: " (on)" else: " (off)") &
    "\nA bar across each trace at the time a refraction model fitted to the picks" &
    "\nexpects its first break (the cool colour), and another where the first" &
    "\nbreak was picked (the warm one; a pick low in confidence is shown only with" &
    "\nShow weak picks, in the overlay's settings)." &
    "\nA line joins them where the fit finds the pick off the model: further from" &
    "\nits neighbours' residuals than its threshold (12 ms or more)." &
    "\nThe model needs source-receiver offsets: a survey, or coordinates in the file." &
    "\nA record with several components is fitted from one kind of sensor."
  if on and b.statusWords.len > 0: result.add "\n" & b.statusWords

func templateTip*(v: TemplateView; on: bool): string =
  ## The tooltip of the "Only traces in the template" button.
  if not v.available:
    return "Needs a relation file in the project: it says which traces each shot's " &
      "template holds."
  let count = if v.known: " (" & $v.shown & " of " & $v.total & ")" else: ""
  result = "Show only the traces in this shot's template" & count
  if on and v.waiting: result.add "\nChecking the record against the template."
  elif on and not v.known:
    result.add "\nThis record has no template: every trace is shown."

func templateCaption*(v: TemplateView): string =
  ## What the Seismic window's title adds while the template's traces only are asked for.
  if not (v.on and v.available): ""
  elif v.known: "template only: " & $v.shown & " of " & $v.total
  elif v.waiting: "template only: checking"
  else: "no template for this record: every trace shown"

proc drawControls(tp: var TracePanelUi; st: AppState; p: Panel; t: Theme; marks: var Marks;
    res: var PanelOutput; ask: var ViewAsk; ppi: float64; mon: MonitorInfo) =
  ## The strip at the top of the window, in groups that wrap onto more lines
  ## when the window is narrow. The gear stays at the right end of the first
  ## line: a group on that line wraps when it would reach the gear's place,
  ## and the gear does not move when other groups wrap.
  let icon = round(igGetFontSize() * IconScale + 2 * igGetStyle().FramePadding.y)
  let lift = round((icon - igGetFrameHeight()) / 2) # centres a text control on the symbols
  let origin = igGetCursorScreenPos()
  let fullRight = origin.x + igGetContentRegionAvail().x
  let gearReserve = max(tp.gearWidth, igGetFrameHeight() + igGetStyle().FramePadding.x)
  let firstEdge = fullRight - gearReserve - 14 # a group gap before the gear
  var started = false
  var onFirst = true
  let caps = p.caps
  let d = p.layers[0].display
  let turn = d.turn
  let turned = d.orientation == orTimeAcross # the plot's symbols turn with it
  let f = p.layers[0].filter
  let (current, count) = recordOf(st, p)
  let u = st.settings.scale
  tp.refreshScaleText(u, ppi)
  if tp.openSort:
    tp.openSort = false
    tp.sortKeys.openSortKeys(p, st.settings)
  let compCols = drawnComponentColours(st.settings.componentColours, plotInk(t, d).background)
  const MaxStripLines = 8
  var lineTop, lineRight, lineEdge: array[MaxStripLines, float32]
  var nLines = 0
  for g in stripGroups(showTraceToggles(hasAux(st, p), f.seismic, f.auxiliary),
      showComponentToggles(p.componentCodes.len), caps):
    case g
    of sgRecord:
      tp.stripGroup(g, firstEdge, fullRight, 14, lift, started, onFirst):
        igBeginDisabled(current <= 0)
        if button(IconRecordBack & "##prevrecord", t, marks, "plot.previous record"):
          res.commands.add Command(kind: ckGather, panel: p.id, gather: current - 1)
        igEndDisabled()
        tipAlways("Previous record (Page Up; Home: the first)")
        igSameLine(0, 2)
        if button($(current + 1) & " / " & $count & "##record", t, marks, "plot.record"):
          tp.goto.open = true
        tip("Record " & $(current + 1) & " of " & $count &
          " in the file: click to go to another (Ctrl+G)")
        igSameLine(0, 2)
        igBeginDisabled(current >= count - 1)
        if button(IconRecordNext & "##nextrecord", t, marks, "plot.next record"):
          res.commands.add Command(kind: ckGather, panel: p.id, gather: current + 1)
        igEndDisabled()
        tipAlways("Next record (Page Down; End: the last)")
    of sgZoom:
      tp.stripGroup(g, firstEdge, fullRight, 14, lift, started, onFirst):
        if button(IconZoomOut & "##zoomout", t, marks, "plot.zoom out"):
          ask = ViewAsk(kind: vaZoomOut)
        tip("Zoom out (-, or the wheel)")
        igSameLine(0, 2)
        if button(IconZoomIn & "##zoomin", t, marks, "plot.zoom in"):
          ask = ViewAsk(kind: vaZoomIn)
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
          igTextUnformatted("Back to the view before (Backspace)", nil)
          igEndTooltip()
    of sgDisplay:
      tp.stripGroup(g, firstEdge, fullRight, 14, 0, started, onFirst):
        var first = true
        template gap() =
          if not first: igSameLine(0, 2)
          first = false
        if caps.modes.card > 1:
          for m in caps.modes:
            gap()
            if symbolButton(modeSymbols[m], icon, t, marks, selected = m == d.mode,
                markPrefix = "plot.", turned = turned) and m != d.mode:
              var nd = d
              nd.mode = m
              res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
        if showFills(d.mode):
          for wf in WiggleFill:
            gap()
            if symbolButton(fillSymbols[wf], icon, t, marks, selected = wf in d.fills,
                markPrefix = "plot.", turned = turned):
              var nd = d
              if wf in nd.fills: nd.fills.excl wf else: nd.fills.incl wf
              res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
        let pk = st.findPanel(p.id)
        if caps.templateButton:
          gap()
          let tv = st.templateView(pk)
          if iconButton(IconTable, "Only traces in the template", "", icon, t, marks,
              selected = f.templateOnly, tipText = templateTip(tv, f.templateOnly),
              enabled = tv.available, markName = "plot.template only"):
            var nf = f
            nf.templateOnly = not f.templateOnly
            res.commands.add Command(kind: ckFilter, panel: p.id, filter: nf)
        if caps.breaks:
          gap()
          let shownBreaks = st.shownBreaks(pk)
          if symbolButton(syFirstBreaks, icon, t, marks, selected = d.firstBreaks,
              markPrefix = "plot.", turned = turned, note = breakTip(d.firstBreaks,
              shownBreaks)):
            var nd = d
            nd.firstBreaks = not d.firstBreaks
            res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
          if d.firstBreaks:
            let unit = st.breakOffsetUnit(pk)
            let chosen = drawBreakKey(shownBreaks, unit, st.breakUnitFromSurvey(pk), d,
              plotInk(t, d), t, icon, marks)
            if chosen.changed:
              res.commands.add Command(kind: ckDisplay, panel: p.id, display: chosen.display)
    of sgGain:
      tp.stripGroup(g, firstEdge, fullRight, 14, lift, started, onFirst):
        drawGainControls(p, tp.gainBox, t, marks, res.commands, res.notes,
          if onFirst: firstEdge else: fullRight)
    of sgFilters:
      tp.stripGroup(g, firstEdge, fullRight, 14, lift, started, onFirst):
        var named = st.ownLine(p)
        let rev = st.reverseLine(p)
        if rev.len > 0:
          if named.len > 0: named.add "\n"
          named.add rev
        let shifted = st.shiftLine(p)
        if shifted.len > 0:
          if named.len > 0: named.add "\n"
          named.add shifted
        drawFilterControls(p, hasAux(st, p), st.filterReach(p), t, marks, res.commands,
          named)
    of sgSort:
      tp.stripGroup(g, firstEdge, fullRight, 14, lift, started, onFirst):
        tp.sortShown = sortLabel(p.layers[0].order, st.settings.sortPresets)
        if drawSortCombo(p, st.settings, marks, res.commands):
          tp.openSort = true # next frame, in the window's ID scope
    of sgTraces:
      tp.stripGroup(g, firstEdge, fullRight, 14, lift, started, onFirst):
        for (aux, name, what) in [(false, "Seismic", "seismic"), (true, "Aux", "auxiliary")]:
          let shown = if aux: f.auxiliary else: f.seismic
          let other = if aux: f.seismic else: f.auxiliary
          if toggle(name & "##traces", shown, t) and (not shown or other):
            var nf = f
            if aux: nf.auxiliary = not shown else: nf.seismic = not shown
            res.commands.add Command(kind: ckFilter, panel: p.id, filter: nf)
          marks.mark("plot.traces." & name)
          tip("Show the record's " & what & " traces" & (if shown: " (on)" else: " (off)") &
            (if shown and not other: ": the plot shows them alone, so this one stays on" else: "") &
            ". With both, the auxiliary traces stand in the file's order among the seismic ones.")
          if not aux: igSameLine(0, 2)
    of sgComponents:
      tp.stripGroup(g, firstEdge, fullRight, 14, lift, started, onFirst):
        var compFirst = true
        let lineInk = plotInk(t, d).wiggle.line
        let faces = buttonFaces(p.componentCodes, p.componentSensors, p.componentCounts)
        for face in faces:
          if not compFirst: igSameLine(0, 2)
          compFirst = false
          let colour = if face.slot == 0: lineInk else: compCols[face.slot - 1]
          let on = componentShown(f.components, face.code)
          if componentToggle(face.letter & "##c" & $face.code, on, colour, t) and
              toggled(p.componentCodes, f.components, face.code) != f.components:
            var nf = f
            nf.components = toggled(p.componentCodes, f.components, face.code)
            res.commands.add Command(kind: ckFilter, panel: p.id, filter: nf)
          marks.mark("plot.component." & $face.code)
          marks.mark("plot.component.letter." & face.letter)
          tip(face.name & ", " & $face.count & " traces" & (if on: " (on)" else: " (off)") &
            (if on and toggled(p.componentCodes, f.components, face.code) == f.components:
              ": the plot shows it alone, so this one stays on" else: ""))
    let mn = igGetItemRectMin()
    let mx = igGetItemRectMax()
    let edge = if mn.y < origin.y + icon: firstEdge else: fullRight
    if nLines == 0 or mn.y > lineTop[nLines - 1] + icon * 0.5:
      if nLines < MaxStripLines:
        lineTop[nLines] = mn.y
        lineRight[nLines] = mx.x
        lineEdge[nLines] = edge
        inc nLines
    else:
      if mn.y < lineTop[nLines - 1]: lineTop[nLines - 1] = mn.y
      if mx.x > lineRight[nLines - 1]: lineRight[nLines - 1] = mx.x
  if caps.filters and nLines > 0:
    var slot = -1
    var gap = 2.0'f32
    for i in 0 ..< nLines:
      let spare = lineEdge[i] - lineRight[i]
      if spare >= icon + 14:
        slot = i
        gap = 14
        break
      elif slot < 0 and spare >= icon + 2:
        slot = i
        gap = 2
    if slot >= 0:
      let back = igGetCursorScreenPos()
      igSetCursorScreenPos(ImVec2_c(x: lineRight[slot] + gap, y: lineTop[slot]))
      let hasRef = st.chosenReference.len > 0
      let hint = st.auxHint(st.findPanel(p.id))
      let corrTip = if not hasRef: NoReferenceChosen
                    elif st.correlateOn: "Correlate with the selected reference (on)"
                    elif hint.len > 0: "Correlate with the selected reference\n" & hint
                    else: "Correlate with the selected reference"
      if iconButton(IconCorrelation, "Correlate", "C", icon, t, marks,
          selected = st.correlateOn, tipText = corrTip, enabled = hasRef,
          markName = "plot.correlate"):
        res.commands.add Command(kind: ckCorrelate, panel: p.id,
          correlate: not st.correlateOn)
      igSetCursorScreenPos(back)
  # the gear: the right end of the first line, whatever wrapped below it
  let resume = igGetCursorScreenPos()
  igSetCursorScreenPos(ImVec2_c(x: fullRight - gearReserve, y: origin.y + lift))
  if button(IconSettings & "##more", t, marks, "plot.more"):
    igOpenPopup_Str(moreId, 0)
  tip(if caps.settingsTabs == {stLook, stTraces, stScales}:
        "Display presets, colours, component colours, density's colour map, the cursor " &
        "time line, time across, killed traces, trace overlap, display header, the scale " &
        "boxes, scale units and screen calibration"
      else: "Colours, the cursor time line, time across, killed traces, trace overlap and " &
        "the display header")
  tp.gearWidth = igGetItemRectSize().x
  let gearMax = igGetItemRectMax()
  if igIsPopupOpen_Str(moreId, 0):
    # below the gear, its right edge at the gear's, moved as far as needed to
    # stay inside the main window: past its edge the popover would be a
    # window of the desktop's own
    let vp = igGetMainViewport()
    let pop = tp.moreSize
    let x = max(vp.WorkPos.x, min(gearMax.x - pop.x, vp.WorkPos.x + vp.WorkSize.x - pop.x))
    let y = max(vp.WorkPos.y, min(gearMax.y, vp.WorkPos.y + vp.WorkSize.y - pop.y))
    igSetNextWindowPos(ImVec2_c(x: x, y: y), ImGui_Cond_Always.cint, ImVec2_c(x: 0, y: 0))
    # never larger than the window: a tab taller than it scrolls
    igSetNextWindowSizeConstraints(ImVec2_c(x: 0, y: 0), vp.WorkSize, nil, nil)
  if igBeginPopup(moreId, 0):
    tp.moreSize = igGetWindowSize()
    marks.markWindow("plot.more popover")
    # in tabs, so the popover fits a small window (1152 x 720 at 125 %):
    # how the traces look; the wiggles, killed traces and the header; the
    # scales (each tab as tall as its own content; the tab chosen is kept)
    if igBeginTabBar("##moretabs", 0):
      template tab(name, markName: string; body: untyped) =
        let open = igBeginTabItem(name, nil, 0)
        marks.mark(markName)
        if open:
          body
          igEndTabItem()
      if stLook in caps.settingsTabs: tab("Look", "plot.more tab look"):
        igSeparatorText("Plot")
        var line = st.settings.cursorLine
        if igCheckbox("Cursor time line", addr line):
          var s = st.settings
          s.cursorLine = line
          res.commands.add Command(kind: ckSettings, settings: s)
        marks.mark("plot.Cursor time line")
        let way = if turn.along[axTraces] == saX: "across" else: "down"
        tip("Cursor time line" & (if line: " (on): a line from the pointer " & way &
          " to the time axis, and its time"
          else: " (off): click for a line from the pointer " & way & " to the time axis"))
        var across = turned
        if igCheckbox("Time across", addr across):
          var nd = d
          nd.orientation = if across: orTimeAcross else: orTimeDown
          res.commands.add Command(kind: ckDisplay, panel: p.id, display: nd)
        marks.mark("plot.Time across")
        const stacked = if FirstTraceAtTop: "from the top down" else: "from the bottom up"
        tip("Time across" & (if across: " (on): time runs from left to right, the traces " &
          "stacked " & stacked & "; click to draw time downwards again"
          else: " (off): click to draw time from left to right, the traces stacked " &
          stacked & ", a positive amplitude up"))
        if caps.displayPresets:
          igSeparatorText("Display presets")
          tp.drawPresets(st, p, marks, res)
        igSeparatorText("Colours")
        tp.drawColours(p, t, marks, res)
        if caps.densityMap:
          igSeparatorText("Density colour map")
          drawColourMaps(p, t, marks, res)
        if caps.componentColours:
          igSeparatorText("Component colours")
          tp.drawComponentColours(st, t, marks, res)
      if stTraces in caps.settingsTabs: tab("Traces", "plot.more tab traces"):
        igSeparatorText("Wiggles")
        drawWiggleSettings(p, marks, res)
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
        drawHeaderChoice(p, st, marks, "plot.more.header.", res)
      if stScales in caps.settingsTabs: tab("Scales", "plot.more tab scales"):
        tp.drawScaleSettings(st, marks, res, ppi, mon, ask)
      igEndTabBar()
    igEndPopup()
  igSetCursorScreenPos(ImVec2_c(x: origin.x,
    y: max(resume.y, gearMax.y + igGetStyle().ItemSpacing.y)))
  igDummy(ImVec2_c(x: 0, y: 0)) # the cursor jump above must submit an item

proc drawStartScreen(t: Theme; recent, folders: openArray[string]; marks: var Marks;
    res: var PanelOutput) =
  ## What the window shows with no file: the ways to open one, and the
  ## folders and files opened last.
  let avail = igGetContentRegionAvail()
  let big = ImVec2_c(x: round(igGetFontSize() * 14), y: round(igGetFontSize() * 2.6))
  let top = igGetCursorPos()
  igSetCursorPos(ImVec2_c(x: top.x + max(0, (avail.x - big.x) / 2),
    y: top.y + max(0, avail.y / 2 - big.y * 1.6)))
  if igButton((IconOpenFile & "  " & menuLabel(maOpenFile)).cstring, big):
    res.actions.incl maOpenFile
  marks.mark("plot.open file")
  tip(menuLabel(maOpenFile) & "\nShortcut: " & shortcutName(maOpenFile), t.roles[rlTextDim])
  igSetCursorPosX(top.x + max(0, (avail.x - big.x) / 2))
  if igButton((IconOpenFolder & "  " & menuLabel(maOpenFolder)).cstring, big):
    res.actions.incl maOpenFolder
  marks.mark("plot.open folder")
  tip(menuLabel(maOpenFolder) & "\nShortcut: " & shortcutName(maOpenFolder), t.roles[rlTextDim])
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

proc drawHeader(tp: var TracePanelUi; tiles: openArray[Tile]; fields: openArray[HeaderRef];
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
      let (have, v, set) = headerValue(tiles, fields, i, pos)
      if have:
        let text = headerLabel(f, v, set)
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

proc fillShift(buf: var array[32, char]; text: string) =
  ## Copies `text` into `buf`, the rest zero, so the popover's field shows it.
  zeroMem(addr buf[0], buf.len)
  if text.len > 0: copyMem(addr buf[0], text.cstring, min(text.len, buf.len - 1))

func startingShift(st: AppState; ids: openArray[int]): tuple[text: string; mixed: bool] =
  ## The shift the popover starts from: the one every trace of `ids` has,
  ## or empty when they differ (`mixed`). None is "0".
  var seen = false
  var ms = 0.0
  for id in ids:
    let cur = st.shownShift(id)
    if not seen:
      ms = cur
      seen = true
    elif cur != ms:
      return ("", true)
  (shiftField(ms), false)

proc askShift(tp: var TracePanelUi; st: AppState; ids: openArray[int]; pos: ImVec2_c) =
  ## Opens the time-shift popover next frame on `ids`, from their current shift.
  let start = st.startingShift(ids)
  fillShift(tp.shiftText, start.text)
  tp.shiftMixed = start.mixed
  tp.shiftTraces = @ids
  tp.shiftPos = pos
  tp.shiftAsk = true

func startingFilter(st: AppState; ids: openArray[int]): tuple[filter: OwnFilter; mixed: bool] =
  ## The filter the popover starts from: the one every trace of `ids` has,
  ## or empty when they differ (`mixed`) or none has one.
  var seen = false
  for id in ids:
    let i = st.findTrace(id)
    let cur = if i < 0: OwnFilter()
              else:
                let (has, f) = st.ownAt(st.sessions[i].path, id - st.sessions[i].base)
                if has: f else: OwnFilter()
    if not seen:
      result.filter = cur
      seen = true
    elif cur != result.filter:
      return (OwnFilter(), true)

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

proc menuHeading(marks: var Marks; text, mark: string) =
  ## A group's heading in the right-click menu: its name in muted text on a
  ## separator line, not clickable.
  let a = igGetCursorScreenPos()
  igSeparatorText(text.cstring)
  let b = igGetCursorScreenPos()
  let right = igGetWindowPos().x + igGetWindowWidth()
  marks.markRect(mark, a, ImVec2_c(x: right - igGetStyle().WindowPadding.x, y: max(b.y, a.y + 1)))

proc drawTraceMenu(tp: var TracePanelUi; st: AppState; k: int; marks: var Marks;
    res: var PanelOutput) =
  ## The plot's right-click menu: functions on the data only. Its first
  ## line says what the trace operations act on, then three or four short
  ## groups: that trace's edits; Analyse (New plot, with the FFT first,
  ## Compare, Store as reference); Find (its own filter, its station on the
  ## map); Whole record (every trace, clearing the edits); last, Undo and Redo.
  template p: untyped = st.panels[k]
  if not igBeginPopup(menuId, 0): return
  marks.markWindow("plot.menu")
  igTextDisabled("%s", tp.menuTarget.cstring)
  marks.mark("plot.menu.target")
  igSeparator()
  let under = tp.menuUnder
  let caps = p.caps
  let has = st.traceEdits(under)
  # Ticked while the trace under the pointer is reversed: a click puts it back.
  if igMenuItem_Bool("Reverse polarity", "R", teReversed in has, under >= 0):
    res.commands.add editCommand(st, p, under, teReversed)
  marks.mark("plot.menu.reverse")
  tip("Reverse this trace's polarity (R). A tick means it is reversed; a click puts it back.")
  if igMenuItem_Bool((if teKilled in has: "Restore" else: "Kill").cstring, "K", false,
      under >= 0):
    res.commands.add editCommand(st, p, under, teKilled)
  marks.mark("plot.menu.kill")
  tip(if teKilled in has: "Restore this killed trace (K)"
      else: "Kill this trace: leave it out of the plot and the processing (K)")
  let targets = if under >= 0: st.selection.targets(under) else: @[]
  if caps.menuFilters:
    # Ticked while the trace under the pointer is excluded from the plot's filters.
    if igMenuItem_Bool("Exclude from plot filters", "E", teExcluded in has, under >= 0):
      res.commands.add editCommand(st, p, under, teExcluded)
    marks.mark("plot.menu.exclude")
    tip("Never filter this trace with the plot's filters (E), the Aux traces too option " &
      "included. A tick means it is excluded; a click puts it back. A filter of its own " &
      "(Filter this trace...) still runs.")
  let filterMany = targets.len > 1
  let filterItem = if filterMany: "Filter " & $targets.len & " selected traces..."
                   else: "Filter this trace..."
  if caps.menuFilters:
    if igMenuItem_Bool((IconFilter & "  " & filterItem).cstring, nil, false, under >= 0):
      tp.ownAsk = true
      tp.ownTraces = targets
      tp.ownPos = igGetIO_Nil().MousePos
      let start = st.startingFilter(targets)
      tp.ownDraft = start.filter
      tp.ownMixed = start.mixed
    marks.mark("plot.menu.filter")
    marks.mark("plot.menu.filter.item " & filterItem)
    tip("Give this trace its own frequency filter, after the plot's filters or instead of them")
  let seismic = if under >= 0: st.seismicIds(targets) else: @[]
  let onSeismic = under >= 0 and under in seismic
  if caps.menuFilters and onSeismic:
    let shiftMany = seismic.len > 1
    let shiftItem = if shiftMany: "Time shift of " & $seismic.len & " selected traces..."
                    else: "Time shift..."
    if igMenuItem_Bool((IconShift & "  " & shiftItem).cstring, nil, false, true):
      tp.askShift(st, seismic, igGetIO_Nil().MousePos)
    marks.mark("plot.menu.shift")
    marks.mark("plot.menu.shift.item " & shiftItem)
    tip("Move these traces in time, in milliseconds, positive later. Snapped to a whole sample.")
    var anyShift = false
    for id in seismic:
      if st.shownShift(id) != 0.0: anyShift = true
    if anyShift:
      let removeItem = if shiftMany: "Remove the time shifts of " & $seismic.len & " traces"
                       else: "Remove the time shift"
      if igMenuItem_Bool((IconShift & "  " & removeItem).cstring, nil, false, true):
        res.commands.add Command(kind: ckTimeShift, panel: p.id, edited: seismic, on: false)
      marks.mark("plot.menu.removeshift")
      marks.mark("plot.menu.removeshift.item " & removeItem)
      tip("Take the time shift away")
  var anyFilter = false
  for id in targets:
    let file = st.findTrace(id)
    if file >= 0 and st.ownAt(st.sessions[file].path, id - st.sessions[file].base).has:
      anyFilter = true
  if anyFilter and caps.menuFilters:
    let removeItem = if filterMany: "Remove the filters of " & $targets.len & " traces"
                     else: "Remove the trace's filter"
    if igMenuItem_Bool((IconFilter & "  " & removeItem).cstring, nil, false, true):
      res.commands.add Command(kind: ckOwnFilter, panel: p.id, edited: targets, on: false)
    marks.mark("plot.menu.removefilter")
    marks.mark("plot.menu.removefilter.item " & removeItem)
    tip("Take this trace's own filter away (the plot's filters stay)")
  menuHeading(marks, "Analyse", "plot.menu.heading.analyse")
  let newPlot = igBeginMenu((IconPulse & "  New plot").cstring, under >= 0)
  marks.mark("plot.menu.newplot")
  tip("Open a plot of the selected traces")
  if newPlot:
    for e in PlotEntries:
      if igMenuItem_Bool((e.icon & "  " & e.name).cstring,
          (if e.fft: e.shortcut.cstring else: nil), false, true):
        res.commands.add(if e.fft: fftCommand(st, p, under)
          else: Command(kind: ckOpenPlot, plotOf: p.id, plotView: e.view,
            plotTraces: st.selection.targets(under)))
      tip(e.sentence)
      marks.mark(if e.fft: "plot.menu.newplot.fft" else: "plot.menu.newplot." & $e.view)
    igEndMenu()
  let compare = igBeginMenu((IconPulse & "  Compare").cstring, under >= 0)
  marks.mark("plot.menu.compare")
  tip("Copy this trace into one of the two compare slots")
  if compare:
    # The trace under the pointer, not the selection: a comparison is one trace a slot.
    if igMenuItem_Bool("Set as A", nil, false, under >= 0):
      res.commands.add Command(kind: ckSetCompare, compareSlot: cwA, compareTrace: under)
    marks.mark("plot.menu.compareA")
    tip("Copy this trace into compare slot A. The copy stays when the plot moves on.")
    if igMenuItem_Bool("Set as B", nil, false, under >= 0):
      res.commands.add Command(kind: ckSetCompare, compareSlot: cwB, compareTrace: under)
    marks.mark("plot.menu.compareB")
    tip("Copy this trace into compare slot B. Filling the second slot opens the compare window.")
    igEndMenu()
  if igMenuItem_Bool((IconReference & "  Store as reference...").cstring, nil, false, under >= 0):
    let i = st.findTrace(under)
    if i >= 0:
      let s = st.sessions[i]
      let local = under - s.base
      let span = indexedSpan(s.filePtr, local)
      let dt = if span.intervalUs > 0: span.intervalUs / 1000
               elif p.laidOut and not p.layout.noInterval: p.layout.dtMs else: 2.0
      let lastMs = if span.samples > 1: float64(span.samples - 1) * dt else: 0.0
      let sweep = span.sweepMs > 0
      let toMs = if sweep: sweepStoreToMs(span.sweepMs, dt) elif lastMs > 0: lastMs else: -1.0
      let g = s.gatherOf(local)
      let rec = if g >= 0 and g < s.records.len and abs(s.records[g].record) < 1e15:
                  $int(s.records[g].record) else: $(max(g, 0) + 1)
      let stem = s.name.splitFile.name
      tp.store.openStore(under, stem & " rec " & rec & " tr " & $(local + 1), 0, toMs,
        int(span.samples), dt, sweep)
  marks.mark("plot.menu.store")
  tip("Keep this trace as a reference: as recorded, reversed when the trace is reversed; " &
    "never the plot's filters, reverse-all or gain, and no filter")
  if tp.menuAux > 0:
    tp.aux.drawAuxGroup(st, under, tp.menuAux, tp.menuMouse, marks, res.commands)
  if caps.menuMap:
    menuHeading(marks, "Map", "plot.menu.heading.find")
    # Its station on the map: the receiver (in a receiver gather, the source).
    let role = $st.stationRole(k)
    let many = under >= 0 and under in st.selection.selected and st.selection.selectedCount > 1
    let station = if many: "Select their " & role & "s on the map"
                  else: "Select its " & role & " on the map"
    if igMenuItem_Bool(station.cstring, "M", false, tp.menuStations.points.len > 0):
      res.commands.add tp.menuStations
    marks.mark("plot.menu.station")
    tip("Select this trace's station on the map (M)")
    if under >= 0: tp.station.drawStationMoveGroup(st, under, tp.menuMouse, marks, res.commands)
  template e: untyped = st.editsOf(k) # not copied
  if caps.menuWholeRecord:
    menuHeading(marks, "Whole record", "plot.menu.heading.record")
    let canCorrelate = st.chosenReference.len > 0
    if igMenuItem_Bool((IconCorrelation & "  Correlate").cstring, "C", st.correlateOn,
        canCorrelate):
      res.commands.add Command(kind: ckCorrelate, panel: p.id,
        correlate: not st.correlateOn)
    marks.mark("plot.menu.correlate")
    let hint = st.auxHint(k)
    if canCorrelate: tip("Correlate with the selected reference" &
      (if hint.len > 0: "\n" & hint else: ""))
    else: tipAlways(NoReferenceChosen)
    # An operation on the samples (processSEG's polarityOp), not a colour.
    let reversed = p.layers[0].reversed
    if igMenuItem_Bool("Reverse polarity of all traces", nil, reversed, true):
      res.commands.add Command(kind: ckReverseAll, panel: p.id, reverse: not reversed)
    marks.mark("plot.menu.reverse all")
    tip("Reverse the polarity of every trace in the plot")
    if igMenuItem_Bool((IconClearAll & "  Clear all edits for this file").cstring, nil, false,
        not e.isEmpty):
      res.commands.add Command(kind: ckClearEdits, panel: p.id)
    marks.mark("plot.menu.clear")
    tipAlways("Kills, polarity reversals, a trace's own filter and its time shift are remembered " &
      "beside the file, never written into it;\nclearing them shows the traces as the file " &
      "has them (Ctrl+Z brings them back).")
  igSeparator()
  # What it was, cut to a steady width; the whole text is in the tooltip.
  let wide = igGetFontSize() * 14
  let undo = if e.canUndo: shortenEnd("Undo " & e.undoText, wide) else: "Undo"
  if igMenuItem_Bool((IconUndo & "  " & undo).cstring, "Ctrl+Z", false, e.canUndo):
    res.commands.add Command(kind: ckUndoEdit, panel: p.id)
  marks.mark("plot.menu.undo")
  tip((if e.canUndo: "Undo " & e.undoText & "\n" else: "") &
    "Take back the last edit of this file (Ctrl+Z)")
  let redo = if e.canRedo: shortenEnd("Redo " & e.redoText, wide) else: "Redo"
  if igMenuItem_Bool((IconRedo & "  " & redo).cstring, "Ctrl+Shift+Z", false, e.canRedo):
    res.commands.add Command(kind: ckRedoEdit, panel: p.id)
  marks.mark("plot.menu.redo")
  tip((if e.canRedo: "Redo " & e.redoText & "\n" else: "") &
    "Make the last undone edit again (Ctrl+Shift+Z)")
  explainEntry("plot.explain", marks)
  igEndPopup()

func stationCommand(st: AppState; k, under: int): Command =
  ## `M` over trace `under` (survey-wide): its station selected on the map
  ## (with the station's traces), or those of the selection that holds it;
  ## the receiver, or in a receiver gather the source.
  Command(kind: ckSelectPoints, points: st.stationsOf(st.selection.targets(under),
    st.stationRole(k)), pointMode: smReplace)

proc editKeys(st: AppState; k, under: int; res: var PanelOutput) =
  ## The trace operations' keys, while the plot has the focus, or while the
  ## pointer is over a trace (a menu click can leave the focus elsewhere):
  ## `R` reverses the polarity of the trace under the pointer (or of the
  ## selection that holds it) or puts it back, `K` kills or restores it,
  ## `E` excludes it from the plot's filters or puts it back,
  ## `M` selects its station on the map, `F` opens its FFT window. Undo and
  ## redo are the Edit menu's, from any window.
  if igGetIO_Nil().WantTextInput: return
  template p: untyped = st.panels[k]
  let over = under >= 0
  if over:
    if plotPressed("plot.reverse", over):
      res.commands.add editCommand(st, p, under, teReversed)
    if plotPressed("plot.kill", over):
      res.commands.add editCommand(st, p, under, teKilled)
    if p.caps.menuFilters and plotPressed("plot.exclude", over):
      res.commands.add editCommand(st, p, under, teExcluded)
    if p.caps.menuMap and plotPressed("plot.station", over):
      let c = stationCommand(st, k, under)
      if c.points.len > 0: res.commands.add c
    if plotPressed("plot.fft", over):
      res.commands.add fftCommand(st, p, under)

func editColour*(has: set[TraceEdit]; shownFilter: bool; shownShift = false): Role =
  ## The colour of an edit mark: error when the trace is killed, accent when
  ## a reversal, a filter or a time shift is shown, dim when only a remembered
  ## edit is hidden.
  if teKilled in has: rlError
  elif has != {} or shownFilter or shownShift: rlAccent
  else: rlTextDim

func editStar*(has, kept: set[TraceEdit]; shownF, keptF: bool; shown, keptFilter: OwnFilter;
    shownShift = 0.0; keptShift = 0.0): bool =
  ## Whether the mark has a star: an edit shown but not remembered, a filter
  ## that differs from the one remembered with the file, or a time shift shown
  ## that differs from the one remembered. A shift only remembered, not shown,
  ## is not a star.
  (has - kept) != {} or (shownF and not keptF) or (shownF and keptF and shown != keptFilter) or
    (shownShift != 0.0 and shownShift != keptShift)

func holds(t: Tile; position: int): bool {.inline.} =
  ## Whether `t` has a row at `position`.
  let r = t.request
  r.count > 0 and position >= r.first and position <= r.last and
    (position - r.first) mod r.stride == 0

proc drawEditRow(tp: var TracePanelUi; e: FileEdits; tiles: openArray[Tile]; view: Viewport;
    layout: PanelLayout; m: Turn; bands: HeaderBands; plotPos, plotSize: ImVec2_c; t: Theme;
    marks: var Marks; filePath, slotAPath, slotBPath: string; slotATrace, slotBTrace: int;
    slotAOn, slotBOn: bool) =
  ## The display header's band of edits, its last (a row under its other
  ## rows; a column next to the plot when time is across): over each edited
  ## trace in view, as the file's edits `e` are now, "K" (killed, in the
  ## theme's error colour), "R" (reversed, in its accent colour) or "E"
  ## (excluded from the plot's filters), "KRE" for all, and the filter icon in the accent colour (the error colour when
  ## the trace is also killed); a thin bar where traces are too close for
  ## the letters. An edit shown but not remembered (an agent's, for the
  ## session), or a filter that differs from the one remembered, has a "*"
  ## after it, its bar an outline; one remembered but hidden for the session
  ## (an agent's undo of the user's) is in brackets, "(K)", in the dim text
  ## colour: it comes back at the next run. Hovering a mark highlights it;
  ## the tooltip names the edit and ends with "Right-click to remove".
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
  let vis = visiblePositions(layout, view)
  # Gather the marks first, so a hover can light the ones a click would take
  # before they are drawn.
  var spans: seq[EditMark]
  var badges: seq[string]
  var drawn: seq[tuple[text: string; colour: ImU32; lo, hi: ImVec2_c; bar, outlineBar,
    session, hidden, filter, shift: bool]]
  for k in countdown(tiles.high, 0):
    for row in 0 ..< min(tiles[k].request.count, tiles[k].traces.len):
      let pos = tiles[k].request.position(row)
      var newer = false
      for j in k + 1 .. tiles.high:
        if tiles[j].holds(pos): newer = true
      let trace = tiles[k].traces[row]
      let has = if pos in vis and not newer: e.editsOf(trace) else: {}
      let kept = if pos in vis and not newer: e.keptOf(trace) else: {}
      let (shownF, shownFilter) = if pos in vis and not newer: e.ownOf(trace)
                                  else: (false, OwnFilter())
      let (keptF, keptFilter) = if pos in vis and not newer: e.keptFilter(trace)
                                else: (false, OwnFilter())
      let shownShift = if pos in vis and not newer: e.shiftOf(trace) else: 0.0
      let keptMs = if pos in vis and not newer: e.keptShift(trace) else: 0.0
      var badge = ""
      if pos in vis and not newer and filePath.len > 0:
        if slotAOn and filePath == slotAPath and trace + 1 == slotATrace: badge.add "A"
        if slotBOn and filePath == slotBPath and trace + 1 == slotBTrace: badge.add "B"
      if has != {} or kept != {} or shownF or keptF or shownShift != 0.0 or
          keptMs != 0.0 or badge.len > 0:
        func letters(s: set[TraceEdit]; filtered, shifted: bool): string =
          (if teKilled in s: "K" else: "") & (if teReversed in s: "R" else: "") &
            (if teExcluded in s: "E" else: "") &
            (if filtered: IconFilter else: "") & (if shifted: IconShift else: "")
        let session = has - kept # shown, not remembered
        let hidden = kept - has # remembered, not shown
        let hiddenShift = keptMs != 0.0 and shownShift == 0.0
        let starred = editStar(has, kept, shownF, keptF, shownFilter, keptFilter,
          shownShift, keptMs)
        var text = letters(has, shownF, shownShift != 0.0)
        if starred: text.add "*"
        if hidden != {} or (keptF and not shownF) or hiddenShift:
          text.add "(" & letters(hidden, keptF and not shownF, hiddenShift) & ")"
        var colour = u32(t.roles[editColour(has, shownF, shownShift != 0.0)])
        if text.len == 0 and badge.len > 0:
          colour = u32(if 'A' in badge: t.roles[rlAccent] else: t.series[1])
        if badge.len > 0: text.add badge
        badges.add badge
        let c = traceAt(view, m, plotPos, plotSize, float64(pos))
        let ts = igCalcTextSize(text.cstring, nil, false, -1)
        let w = ts.along(ta)
        var lo, hi: ImVec2_c
        let asBar = perPos < w + 2
        if not asBar:
          let b = bands.inBand(i, ts.along(bands.axis))
          lo = vec(ta, round(c - w / 2), b)
          hi = vec(ta, lo.along(ta) + w, b + ts.along(bands.axis))
        else:
          let half = max(0.5'f32, perPos / 2 - 0.5'f32)
          lo = vec(ta, c - half, bs + round(bz * 0.2))
          hi = vec(ta, c + half, bs + round(bz * 0.8))
        let note = if shownF: filterWords(shownFilter)
                   elif keptF: filterWords(keptFilter) else: ""
        let shifted = if shownShift != 0.0: shiftWords(shownShift)
                      elif keptMs != 0.0: shiftWords(keptMs) else: ""
        # A pixel of pad so the edge of a letter still counts as the mark.
        let pad = if asBar: 0'f32 else: 1'f32
        spans.add EditMark(trace: trace, centre: c,
          lo: lo.along(ta) - pad, hi: hi.along(ta) + pad,
          cross0: if asBar: bs else: lo.along(bands.axis) - pad,
          cross1: if asBar: bs + bz else: hi.along(bands.axis) + pad,
          edits: has, hasFilter: shownF, outline: asBar, filterNote: note,
          shiftNote: shifted)
        drawn.add (text, colour, lo, hi, asBar, has == {} or session == has,
          session != {} or (shownF and not keptF) or starred, hidden != {} or hiddenShift,
          shownF or keptF, shownShift != 0.0 or keptMs != 0.0)
  tp.editMarks = spans
  tp.editBand0 = bs
  tp.editBand1 = bs + bz
  tp.editAxis = ta
  let mouse = igGetIO_Nil().MousePos
  let rowLo = vec(ta, t0, bs)
  let rowHi = vec(ta, t0 + plotSize.along(ta), bs + bz)
  let rowHovered = igIsMouseHoveringRect(rowLo, rowHi, true)
  var hit = MarkHit()
  if rowHovered:
    hit = marksAt(spans, mouse.along(ta), mouse.along(bands.axis), bs, bs + bz)
  ImDrawList_PushClipRect(dl, rowLo, rowHi, true)
  var marked = 0
  for n, span in spans:
    let d = drawn[n]
    let lit = span.trace in hit.traces
    if lit:
      let (h0, h1) = ordered(vec(ta, span.lo, span.cross0), vec(ta, span.hi, span.cross1))
      ImDrawList_AddRectFilled(dl, h0, h1, u32(withAlpha(t.roles[rlHover], 160)), 2, 0)
      ImDrawList_AddRect(dl, h0, h1, u32(t.roles[rlHighlight]), 2, 1, 0)
    if d.bar:
      if d.outlineBar: ImDrawList_AddRect(dl, d.lo, d.hi, d.colour, 0, 1, 0)
      else: ImDrawList_AddRectFilled(dl, d.lo, d.hi, d.colour, 0, 0)
    else: ImDrawList_AddText_Vec2(dl, d.lo, d.colour, d.text.cstring, nil)
    if marked < 200: # for tests
      marks.markRect("plot.header.edit " & $(span.trace + 1), d.lo, d.hi)
      if d.session: marks.markRect("plot.header.edit " & $(span.trace + 1) & " session", d.lo, d.hi)
      if d.hidden: marks.markRect("plot.header.edit " & $(span.trace + 1) & " hidden", d.lo, d.hi)
      if d.filter: marks.markRect("plot.header.filter " & $(span.trace + 1), d.lo, d.hi)
      if d.shift: marks.markRect("plot.header.shift " & $(span.trace + 1), d.lo, d.hi)
      if n < badges.len and 'A' in badges[n]:
        marks.markRect("plot.header.compareA " & $(span.trace + 1), d.lo, d.hi)
      if n < badges.len and 'B' in badges[n]:
        marks.markRect("plot.header.compareB " & $(span.trace + 1), d.lo, d.hi)
      if lit: marks.markRect("plot.header.edit hover", d.lo, d.hi)
      inc marked
  if hit.traces.len > 0:
    let tip = markTip(hit, spans)
    if tip.len > 0:
      igSetTooltip("%s", tip.cstring)
      marks.mark("plot.header.edit tip " & tip.replace("\n", " | "))
  ImDrawList_PopClipRect(dl)

proc openMarkMenu(tp: var TracePanelUi; st: AppState; k, base: int; hit: MarkHit;
    mouse: ImVec2_c) =
  ## Snapshots the menu for `hit` (file indices) of the file panel `k`
  ## shows, whose first survey-wide id is `base`. Nothing is opened when
  ## the traces have no edit to take away. The selection is met with the
  ## file's edit lists, not walked trace by trace.
  var rows: seq[TraceEditView]
  var selected: seq[int]
  let i = st.findTrace(base)
  if i < 0: return
  let path = st.sessions[i].path
  let span = 0 ..< st.sessions[i].len
  var wanted = hit.traces
  for edit in TraceEdit:
    for t in st.editsOf(k).listIn(edit, span):
      if base + t in st.selection.selected:
        selected.add t
        wanted.add t
  for f in st.editsOf(k).filtersIn(span):
    if base + f.trace in st.selection.selected:
      selected.add f.trace
      wanted.add f.trace
  for s in st.editsOf(k).shiftsIn(span):
    if base + s.trace in st.selection.selected:
      selected.add s.trace
      wanted.add s.trace
  wanted.sort()
  var n = 0
  for t in wanted:
    if n == 0 or wanted[n - 1] != t:
      wanted[n] = t
      inc n
  wanted.setLen n
  selected.sort()
  n = 0
  for t in selected:
    if n == 0 or selected[n - 1] != t:
      selected[n] = t
      inc n
  selected.setLen n
  for t in wanted:
    let (has, _) = st.ownAt(path, t)
    rows.add TraceEditView(trace: t, edits: st.traceEdits(base + t), hasFilter: has,
      hasShift: st.editsOf(k).hasShift(t))
  let entries = markEntries(hit, rows, selected)
  if entries.len == 0: return
  tp.markAsk = true
  tp.markMouse = mouse
  tp.markTitle = markTitle(hit)
  tp.markChoices.setLen 0
  for e in entries:
    var ids = newSeq[int](e.traces.len)
    for k, t in e.traces: ids[k] = base + t
    tp.markChoices.add MarkChoice(text: entryText(e, hit.shared), item: e.item, traces: ids)

proc drawMarkMenu(tp: var TracePanelUi; st: AppState; k: int; marks: var Marks;
    res: var PanelOutput) =
  ## The menu a right click on an edit mark opened: that trace's edits, or
  ## the traces that shared its pixel.
  if not igBeginPopup(markMenuId, 0): return
  marks.markWindow("plot.editmenu")
  if tp.markTitle.len > 0:
    igTextDisabled("%s", tp.markTitle.cstring)
    marks.mark("plot.editmenu.title")
  template p: untyped = st.panels[k]
  for choice in tp.markChoices:
    if igMenuItem_Bool(choice.text.cstring, nil, false, choice.traces.len > 0):
      case choice.item
      of miRemoveKill, miRemoveKillSelected:
        res.commands.add Command(kind: ckEdit, panel: p.id, edit: teKilled,
          edited: choice.traces, on: false)
      of miRemoveReverse, miRemoveReverseSelected:
        res.commands.add Command(kind: ckEdit, panel: p.id, edit: teReversed,
          edited: choice.traces, on: false)
      of miRemoveExclude, miRemoveExcludeSelected:
        res.commands.add Command(kind: ckEdit, panel: p.id, edit: teExcluded,
          edited: choice.traces, on: false)
      of miRemoveFilter, miRemoveFilterSelected:
        res.commands.add Command(kind: ckOwnFilter, panel: p.id, edited: choice.traces,
          on: false)
      of miRemoveAll:
        res.commands.add Command(kind: ckEdit, panel: p.id, edit: teKilled,
          edited: choice.traces, on: false, alsoDrop: {teReversed, teExcluded},
          alsoFilter: true, alsoShift: true)
      of miEditFilter:
        let start = st.startingFilter(choice.traces)
        tp.ownDraft = start.filter
        tp.ownMixed = start.mixed
        tp.ownTraces = choice.traces
        tp.ownPos = tp.markMouse
        tp.ownAsk = true
      of miRemoveShift, miRemoveShiftSelected:
        res.commands.add Command(kind: ckTimeShift, panel: p.id, edited: choice.traces,
          on: false)
      of miEditShift:
        tp.askShift(st, choice.traces, tp.markMouse)
    marks.mark("plot.editmenu.item " & choice.text)
  igEndPopup()

proc drawHeaderMenu(p: Panel; st: AppState; marks: var Marks; res: var PanelOutput) =
  ## The display header's own menu (a right click on its rows or their
  ## names): its fields, automatic or the ones ticked.
  if not igBeginPopup(headerMenuId, 0): return
  marks.markWindow("plot.header menu")
  igSeparatorText("Display header")
  drawHeaderChoice(p, st, marks, "plot.header menu.", res)
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
    fields: openArray[HeaderRef]; position: int; view: Viewport; m: Turn;
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
    let (have, v, set) = headerValue(tiles, fields, i, position)
    let text = if have: headerLabel(f, v, set) else: ""
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
    m: Turn; lim: ViewLimits; hovered, held: bool; t: Theme; remember, menu: var bool;
    click: var ClickKind) =
  ## The wheel and the buttons over the plot (the invisible button just
  ## drawn over it), turned as `m` says. A left press released where it went
  ## down is a click. A right press on the plot while its menu is open
  ## (`held`), which closes the menu, starts a right click there too, as on
  ## a desktop: released where it went down, the menu opens again there.
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
  elif held and tp.drag.kind == dkNone and
      igIsMouseClicked_Bool(ImGui_MouseButton_Right.cint, false) and
      igIsItemHovered(ImGui_HoveredFlags_AllowWhenBlockedByPopup.cint):
    tp.drag = Drag(kind: dkBox, button: ImGui_MouseButton_Right.cint, press: mouse, start: after)
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
    sweep: bool; remember: var bool; res: var PanelOutput) =
  ## The plot's keys, while its window has the focus (docs/plot-window.md),
  ## in the screen's directions on a plot turned `m`.
  let io = igGetIO_Nil()
  if io.WantTextInput: return # typing into a box
  # A menu click can leave the focus on another window. A key while the
  # pointer is over the plot still acts on the plot.
  let route = if hovered and not igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint):
      ImGui_InputFlags_RouteGlobal.cint or ImGui_InputFlags_RouteOverFocused.cint
    else: 0
  template held(chord: cint): bool =
    igShortcut_Nil(chord, ImGui_InputFlags_Repeat.cint or route)
  template once(chord: cint): bool = igShortcut_Nil(chord, route)
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
  if plotPressed("plot.back", hovered):
    res.commands.add Command(kind: ckBack, panel: p.id)
  # Alt + the arrows along the traces: the next or previous trace selected
  # (Left / Right, or Up / Down when time is across).
  for (key, dx, dy) in [(ImGui_Key_LeftArrow, -1.0, 0.0), (ImGui_Key_RightArrow, 1.0, 0.0),
      (ImGui_Key_UpArrow, 0.0, -1.0), (ImGui_Key_DownArrow, 0.0, 1.0)]:
    let (alongTraces, _) = m.dataDelta(dx, dy)
    if alongTraces != 0 and held(alt or key.cint):
      res.commands.add Command(kind: ckStepTrace, spectrumOf: p.id,
        stepBy: (if alongTraces > 0: 1 else: -1))
  # Records: Page Down / Up, Home / End, Ctrl+G.
  let (current, count) = if p.caps.stepsRecords: record else: (0, 0)
  var to = current
  if held(ImGui_Key_PageDown.cint): to = current + 1
  if held(ImGui_Key_PageUp.cint): to = current - 1
  if once(ImGui_Key_Home.cint): to = 0
  if once(ImGui_Key_End.cint): to = count - 1
  if count > 0 and clamp(to, 0, count - 1) != current:
    res.commands.add Command(kind: ckGather, panel: p.id, gather: clamp(to, 0, count - 1))
  elif sweep and to != current and (to > count - 1 or to < 0):
    res.stepFile = if to > current: 1 else: -1 # the last record's Page Down: the next sweep
  if p.caps.stepsRecords and plotPressed("plot.goto", hovered): tp.goto.open = true
  gainKeys(p, hovered, res.commands)
  if p.caps.filters: filterKeys(p, hovered, res.commands)
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
  tp.editMarks.setLen 0
  let headerTop = igGetCursorScreenPos()
  # The display header: a row per field above the plot, or a column per
  # field left of it when time is across (their names above them), and a
  # band for the edits while the gather has one.
  let edited = st.gatherEdited(k) or st.compareOnGather(k)
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
      bands.size.add round(max(caption, float32(max(max(chars[i], p.widest[f.field]), 1)) *
          charW)) +
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
  let held = igIsPopupOpen_Str(menuId, 0) # the plot's menu, opened by a right click
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
    # Every label as wide as the longest the record can have, so the axis,
    # and the plot's left edge, stay put as the labels change length. The
    # first and last time in view are always labelled: a round tick near one
    # gives way to it (`timeEnds`).
    let timeAxis = if turn.along[axTime] == saY: ImAxis_Y1.cint else: ImAxis_X1.cint
    let chars = timeLabelChars(p.layout)
    let across = turn.along[axTime] == saX
    let ppm = (if across: max(1, avail.x - room.x) else: max(1, avail.y - room.y)) /
      max(1e-9, next.timeMs.hi - next.timeMs.lo)
    let gap = if across: float32(chars + 1) * igCalcTextSize("0", nil, false, -1).x
      else: 1.5 * lineH
    let ends = timeEnds(next.timeMs, lim[axTime].bounds, p.layout.dtMs, chars, ppm, gap)
    axisEnds = ends
    axisChars = chars
    ImPlot_SetupAxisFormat_PlotFormatter(timeAxis, axisLabel, nil)
    var endTimes = [ends.last, ends.first]
    var endTexts = [ends.lastText.cstring, ends.firstText.cstring]
    ImPlot_SetupAxisTicks_doublePtr(timeAxis, addr endTimes[0], (if ends.showFirst: 2 else: 1).cint,
      cast[ptr UncheckedArray[cstring]](addr endTexts[0]), true)
    let (xs, ys) = (next.span(turn.axisAlong(saX)), next.span(turn.axisAlong(saY)))
    ImPlot_SetupAxesLimits(xs.lo, xs.hi, ys.lo, ys.hi, ImPlot_Cond_Always.cint)
    ImPlot_SetupFinish()
    let lim2 = ImPlot_GetPlotLimits(ImAxis_X1.cint, ImAxis_Y1.cint)
    let pos = ImPlot_GetPlotPos()
    let size = ImPlot_GetPlotSize()
    let fb = igGetIO_Nil().DisplayFramebufferScale
    let view = next.sized(turn, int(round(size.x * fb.x)), int(round(size.y * fb.y)))
    marks.markRect("plot.data", pos, ImVec2_c(x: pos.x + size.x, y: pos.y + size.y))
    block endLabels:
      # where the time axis writes its first and last time
      let tw = igCalcTextSize(ends.lastText.cstring, nil, false, -1)
      for (name, t, shown) in [("plot.time end", ends.last, true),
          ("plot.time start", ends.first, ends.showFirst)]:
        if not shown: continue
        let at = if across: ImPlot_PlotToPixels_double(t, ys.lo, ImAxis_X1.cint, ImAxis_Y1.cint)
          else: ImPlot_PlotToPixels_double(xs.lo, t, ImAxis_X1.cint, ImAxis_Y1.cint)
        if across:
          marks.markRect(name, ImVec2_c(x: at.x - tw.x / 2, y: pos.y + size.y),
            ImVec2_c(x: at.x + tw.x / 2, y: pos.y + size.y + tw.y))
        else:
          marks.markRect(name, ImVec2_c(x: pos.x - tw.x, y: at.y - tw.y / 2),
            ImVec2_c(x: pos.x, y: at.y + tw.y / 2))
    if tp.gpuError.len == 0 and tp.started:
      let faces = buttonFaces(p.componentCodes, p.componentSensors, p.componentCounts)
      let slots = componentSlots(faces)
      tp.sync(tiles, base, st.selection, slots, faces.len > 1)
      let d = layer.display
      let scale = displayScale(p.reference, d.appliedGainDb(p.kind))
      var shown = view # what ImPlot shows along each screen axis
      let (sx, sy) = (Span(lo: lim2.X.Min, hi: lim2.X.Max), Span(lo: lim2.Y.Min, hi: lim2.Y.Max))
      (shown.traces, shown.timeMs) = if turn.axisAlong(saX) == axTraces: (sx, sy) else: (sy, sx)
      # one pixel of line at 100 % (no more than a quarter of a trace spacing:
      # `styleFor`), two for a hovered or selected trace
      let width = max(1.0, round(float64(fb.x)))
      let multi = p.componentCodes.len > 1
      let cols = drawnComponentColours(st.settings.componentColours, ink.background)
      let tex = tp.renderer.render(PlotFrame(view: shown, turn: turn,
        background: ink.background, density: d.drawsDensity, colourMap: d.colourMap,
        wiggles: d.drawsWiggles, scale: scale,
        style: d.styleFor(shown, scale, width, 2 * width), ink: ink.wiggle,
        tint: DensityTint, marks: tp.marks, componentInk: multi and d.drawsWiggles,
        componentColours: cols,
        bandPx: (if multi and d.drawsDensity and not d.drawsWiggles: densityBandPx(fb.x)
        else: 0),
        bandEdge: (if turn.along[axTime] == saX: 1 else: 0)), tiles, tp.textures)
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
    tp.drawSelectionMarkers(tiles, base, st.selection, view, p.layout, turn, pos, size, t, marks)
    block noiseArea:
      let q = st.recordQc
      if q.noise.ready and st.settings.map.filters * NoiseFilters != {} and
          layer.source.kind == lsRecord and q.key.file == layer.source.file and
          q.key.gather == layer.source.gather:
        drawAreaBands(areaBands(q.noise, p.shown, p.layout, view, turn,
          Rect(pos: vec2(pos.x, pos.y), size: vec2(size.x, size.y))), ink, marks)
    block firstBreaks:
      let bi = st.breaksIndex(k)
      let derived = source >= 0 and st.sessions[source].derived
      if layer.display.firstBreaks and bi >= 0 and not derived:
        let g = breakGeometry(st.shownBreaks(k), p.shown, p.layout, view, turn,
          Rect(pos: vec2(pos.x, pos.y), size: vec2(size.x, size.y)), layer.display.breakSize,
          max(1'f32, igGetFontSize() / 15), layer.display.breakShowWeak, st.editsOf(k))
        drawBreakMarks(g, ink, layer.display, marks)
    if edited:
      let path = if source >= 0: st.sessions[source].path else: ""
      drawEditRow(tp, st.editsOf(k), tiles, view, p.layout, turn, bands, pos, size, t, marks,
        path, st.compareA.path, st.compareB.path, st.compareA.trace, st.compareB.trace,
        st.compareA.filled, st.compareB.filled)
    ImPlot_EndPlot()
    marks.markRect("plot.explain", pos, ImVec2_c(x: pos.x + size.x, y: pos.y + size.y))
    explainShow("plot.explain", marks, st.explainSeismic(k))
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
        let mouse = igGetIO_Nil().MousePos
        if tp.editMarks.len > 0 and base >= 0:
          let along = mouse.along(tp.editAxis)
          let cross = mouse.along(if tp.editAxis == saX: saY else: saX)
          let hit = marksAt(tp.editMarks, along, cross, tp.editBand0, tp.editBand1)
          if hit.traces.len > 0: tp.openMarkMenu(st, k, base, hit, mouse)
        if not tp.markAsk: igOpenPopup_Str(headerMenuId, 0)
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
    tp.handleMouse(after, view, plot, turn, limNow, hovered, held, t, remember, menu, click)
    case tp.bars.drawScrollBars(after, view, pos, size, barsUnder, limNow, turn, t, marks)
    of beNone, beDrag: discard
    of beGrab:
      remember = true
      tp.gesture = gsNone
    of bePage: (if tp.burst(gsPage): remember = true)
    of beWheel: (if tp.burst(gsBarWheel): remember = true)
    tp.handleKeys(after, view, plot, turn, limNow, hovered, p,
      st.selection.anySelected, recordOf(st, p), shownSignature(st, p) and p.caps.stepsRecords,
      remember, res)
    if p.caps.filters and st.chosenReference.len > 0 and not igGetIO_Nil().WantTextInput and
        plotPressed("plot.correlate", hovered):
      res.commands.add Command(kind: ckCorrelate, panel: p.id, correlate: not st.correlateOn)
    tp.cursorText = ""
    tp.cursorHeader.setLen 0
    # While the plot's menu is open, what was under the pointer at the right
    # click is held: its trace stays the hover, the read-outs (the status
    # bar, the cursor's time line and header values) say what they said
    # then, wherever the pointer goes over the menu.
    if hovered or held:
      let mouse = if held: tp.menuMouse else: igGetIO_Nil().MousePos
      res.pick = if held: tp.menuPick
                 else: pick(tiles, p.layout, view, plot, vec2(mouse.x, mouse.y), turn)
      if layer.display.firstBreaks and res.pick.found and res.pick.trace >= 0:
        let bi = st.breaksIndex(k)
        if bi >= 0:
          res.pick.breaks = st.shownBreaks(k).readoutText(res.pick.trace, st.editsOf(k))
      if st.settings.cursorLine and res.pick.inside:
        tp.drawCursorLine(mouse, pos, size, turn, res.pick.at.tMs, p.layout.dtMs, ink, t, marks)
        if res.pick.found and res.pick.position >= 0:
          tp.drawCursorHeader(tiles, fields, res.pick.position, view, turn, bands, pos, size,
            ink, t, marks)
    # The trace under the pointer is the hover; a click selects it.
    let under = if res.pick.found and res.pick.trace >= 0 and base >= 0: base + res.pick.trace
                else: -1
    if held: discard # the menu's trace stays the hover until the menu closes
    elif hovered and under != st.selection.hover:
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
      tp.menuAux = if under >= 0: st.auxPositionOf(under) else: 0
      tp.menuPick = res.pick
      tp.menuMouse = igGetIO_Nil().MousePos
      tp.menuStations = if under >= 0: stationCommand(st, k, under)
                        else: Command(kind: ckSelectPoints)
      if under >= 0: res.commands.add Command(kind: ckOwnPosition, ownTrace: under)
    tp.cur = after
    if after != p.view:
      res.commands.add Command(kind: ckView, panel: p.id, view: after, remember: remember)
  ImPlot_PopStyleColor(1)
  if menu: igOpenPopup_Str(menuId, 0)
  tp.drawTraceMenu(st, k, marks, res)
  if tp.markAsk:
    tp.markAsk = false
    igOpenPopup_Str(markMenuId, 0)
  tp.drawMarkMenu(st, k, marks, res)
  if tp.ownAsk:
    tp.ownAsk = false
    igSetNextWindowPos(tp.ownPos, ImGui_Cond_Appearing.cint, ImVec2_c(x: 0, y: 0))
    openOwnFilter()
  if tp.shiftAsk:
    tp.shiftAsk = false
    igSetNextWindowPos(tp.shiftPos, ImGui_Cond_Appearing.cint, ImVec2_c(x: 0, y: 0))
    openTimeShift()
  if tp.shiftTraces.len > 0:
    var applied = 0.0
    case drawTimeShift(tp.shiftText, tp.shiftMixed, tp.shiftTraces.len,
        st.panels[k].layout.dtMs, marks, applied)
    of scNone: discard
    of scClear:
      res.commands.add Command(kind: ckTimeShift, panel: st.panels[k].id,
        edited: tp.shiftTraces, on: false)
      tp.shiftTraces.setLen 0
    of scApply:
      res.commands.add Command(kind: ckTimeShift, panel: st.panels[k].id,
        edited: tp.shiftTraces, on: true, ms: applied)
      tp.shiftTraces.setLen 0
  if tp.ownTraces.len > 0 and drawOwnFilter(tp.ownDraft, tp.ownMixed, tp.ownTraces.len,
      st.panels[k].layout.dtMs, tp.ownPos, marks):
    # Nothing set and "after" takes the filter away (no mark; no step when
    # there was none). "Instead" with nothing set is kept: the trace is shown
    # without the plot's filters.
    let remove = not tp.ownDraft.spec.hasFilters and tp.ownDraft.place == fpAfter
    if remove:
      res.commands.add Command(kind: ckOwnFilter, panel: st.panels[k].id, edited: tp.ownTraces,
        on: false)
    else:
      res.commands.add Command(kind: ckOwnFilter, panel: st.panels[k].id, edited: tp.ownTraces,
        on: true, processing: tp.ownDraft.spec, filterPlace: tp.ownDraft.place)
  for c in tp.store.drawStore(st, t, marks): res.commands.add c
  tp.aux.drawAuxShift(st, marks, res.commands)
  tp.station.drawStationMoveDialog(st, marks, res.commands)
  drawHeaderMenu(p, st, marks, res)
  tp.sortKeys.drawSortKeys(p, st, marks, res.commands)
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
  let pk = st.findPanel(panel)
  let shown = st.shownFile(pk)
  # Edits brought back on the file's size, ends and time are marked until
  # the hash of every byte confirms they are this file's.
  let checking = shown >= 0 and st.editsChecking(st.sessions[shown].path)
  let opened = if shown >= 0: st.sessions[shown].facts.opened.choice else: OpenChoice()
  let aux = pk >= 0 and st.panels[pk].role == prAux
  var hidden = ""
  if pk >= 0 and st.panels[pk].layers.len > 0 and not aux:
    let faces = buttonFaces(st.panels[pk].componentCodes, st.panels[pk].componentSensors,
      st.panels[pk].componentCounts)
    hidden = hiddenCaption(faces, st.panels[pk].layers[0].filter.components,
      st.panels[pk].layout.traces)
  let note = if pk >= 0 and not aux: templateCaption(st.templateView(pk)) else: ""
  var corr = ""
  if panel == MainPanel and not aux:
    if st.correlating: corr = "  \u00b7  correlating"
    elif shown >= 0 and st.sessions[shown].derived: corr = "  \u00b7  correlated"
  let title = IconPlot & "  " & name & (if opened.isDefault: "" else: "  \u00b7  " &
    choiceMark(opened)) & (if hidden.len > 0: "  \u00b7  " & hidden else: "") &
    (if note.len > 0: "  \u00b7  " & note else: "") & corr &
    (if checking: "  (edits being checked)" else: "") & "###" & id
  # Arrow keys pan the plot, so they do not move ImGui's keyboard focus here;
  # the wheel zooms, so it does not scroll the window.
  const windowFlags = ImGui_WindowFlags_NoNavInputs.cint or
    ImGui_WindowFlags_NoScrollWithMouse.cint or ImGui_WindowFlags_NoScrollbar.cint
  var plotted = false
  tp.instead = ""
  template say(text: string; colour: Rgba) =
    let words = text
    tp.instead = words
    centredText(words, colour)
  let begun =
    if aux: beginClosable(awAux, title.cstring, windowFlags)
    else: igBegin(title.cstring, nil, windowFlags)
  if begun:
    tp.focus.watch()
    # The window never scrolls as a whole: the strip wraps and the plot fits.
    igSetScrollX_Float(0)
    igSetScrollY_Float(0)
    marks.markWindow(name.toLowerAscii)
    let k = st.findPanel(panel)
    if k < 0 or st.panels[k].layers.len == 0:
      if aux:
        say("Show a file in the Seismic window: its auxiliary traces appear here.",
          t.roles[rlTextDim])
      else:
        drawStartScreen(t, st.settings.recentFiles, st.settings.recentFolders, marks, result)
    else:
      template p: untyped = st.panels[k]
      let mon = monitorOf(igGetWindowViewport())
      let ppi = st.settings.ppiFor(mon.name, mon.displayScale)
      var ask = ViewAsk()
      # The strip wraps onto more lines as the window narrows; where they
      # would leave the plot less than `MinPlotLines`, they scroll in a
      # region of their own instead, so the plot keeps its room.
      let keep = round(igGetFontSize() * MinPlotLines)
      let room = igGetContentRegionAvail().y - keep
      let cramped = tp.stripHeight > room
      if cramped:
        discard igBeginChild_Str("##strip", ImVec2_c(x: 0,
          y: max(igGetFrameHeightWithSpacing(), room)), 0.ImGuiChildFlags, 0.ImGuiWindowFlags)
      let top = igGetCursorPosY()
      tp.drawControls(st, p, t, marks, result, ask, ppi, mon)
      tp.stripHeight = igGetCursorPosY() - top
      if cramped:
        igEndChild()
        marks.mark("plot.strip scrolls")
      let source = p.layers[0].source
      let s = if source.kind == lsRecord: st.findSession(source.file) else: -1
      let name = if s >= 0: st.sessions[s].name else: "the file"
      if s >= 0 and not st.sessions[s].facts.opened.choice.isDefault:
        # Not read as the defaults read it: said above the plot, in full on hover.
        let c = st.sessions[s].facts.opened.choice
        igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
        igTextUnformatted(("Opened " & choiceMark(c)).cstring, nil)
        igPopStyleColor(1)
        marks.mark("plot.opened as")
        tip("Opened with options: " & choiceText(c) & ".\nFile > Reopen with options... changes them.")
      let again = if s < 0: st.reopening(panel) else: ("", false)
      let wait = st.waiting(k)
      if tp.gpuError.len > 0:
        say("The plot cannot be drawn: " & tp.gpuError, t.roles[rlError])
      elif wait.kind != wkNone and not p.laidOut:
        drawWaiting(wait, panel, t, marks, result, centred = true)
      elif again.path.len > 0:
        let changed = again.path.extractFilename
        say(if again.waiting: changed & " is being changed by another program: it " &
            "is shown again once it stops changing."
          else: "Opening " & changed & " again...", t.roles[rlTextDim])
      elif not p.laidOut:
        say("Reading " & name & "...", t.roles[rlTextDim])
      elif s >= 0 and st.sessions[s].gathers.len == 0:
        say(name & " has no traces to show (see Messages).", t.roles[rlTextDim])
      elif p.layout.traces == 0 and aux:
        say(st.auxEmptyText(k), t.roles[rlTextDim])
      elif p.layout.traces == 0:
        let f = p.layers[0].filter
        let which = if f.seismic and not f.auxiliary: " (it shows seismic traces only)"
                    elif f.auxiliary and not f.seismic: " (it shows auxiliary traces only)"
                    else: ""
        say("The trace filter hides every trace of this gather" & which & ".",
          t.roles[rlTextDim])
      elif p.layout.samples == 0:
        say("The traces of this gather have no samples (see Messages).",
          t.roles[rlTextDim])
      else:
        if wait.kind != wkNone:
          drawWaiting(wait, panel, t, marks, result, centred = false)
        tp.drawPlot(st, k, t, fonts, marks, result, ask, ppi)
        plotted = true
  tp.focus.settle()
  igEnd()
  tp.plotted = plotted
  # No plot this frame (a new gather or file is being read, the window is
  # hidden): the trace this plot hovered is not shown, so it is not hovered.
  if not plotted and tp.hovering:
    result.commands.add Command(kind: ckHover, trace: -1)
    tp.hovering = false
