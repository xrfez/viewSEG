## The map window: the survey's sources and receivers in survey
## coordinates, north up, always at equal aspect, with no basemap (nothing
## is fetched from anywhere). One layer per loaded survey file's sources and
## receivers (discs: the Preplot group), the open file's own positions
## (rings: the Recorded group) and the highlight on top (`view/maplayers`);
## each layer and each group can be hidden ("Layers" in the strip; a layer
## also from the right-click menu of one of its points).
##
## The window reads `core` and issues `Command`s; it never changes the
## state itself. ImPlot only frames the plot (its axes show no values: the
## scale bar, the north arrow and the status bar's coordinates say what is
## needed, and nothing resizes the plot area from frame to frame): the window handles the mouse
## and keys itself, with the plot window's gestures wherever they carry over
## (docs/plot-window.md, "The map"), and moves the view with `core/mapview`:
## wheel zoom about the pointer, `+` / `-`, drag to pan (left or middle
## button), right drag to zoom to a box, arrows to pan (a tenth of the view;
## Shift: a whole view), Ctrl + 0 to fit, Backspace or Alt + Left for back,
## Shift + drag to select the points in a box (and their traces), Ctrl +
## drag to measure a distance. A measure turns the Ruler on, so the button
## lights whichever way the line was started (Ctrl + drag, or a plain drag
## while the button is on). Clicking the lit button turns it off and takes
## the line and its reading away; the next line starts fresh. Esc takes the
## line away and leaves the button on. Esc cancels the
## innermost: a drag, the ruler, the selection. No view loses the survey,
## and a new window size keeps the scale from the top-left corner. Each new
## view goes to `core` (`ckMapView`); the first of a gesture with
## `mapRemember`, so back returns to the view before it.
##
## The image comes from `gpu/mappoints`: each layer's points uploaded once,
## drawn at the level of detail the scale needs, so a pan or a zoom draws at
## once from what the GPU holds. The point under the pointer is described
## (its station, coordinates, the traces and records it belongs to) in a
## popup beside the pointer or in a strip along the map's bottom, as the
## user chooses in the map's settings (the gear); the pointer's coordinates,
## with their units, go to the status bar. A scale bar and a north arrow
## stand in the plot's corners.
##
## **Linked to the plot** (through `core`'s selection only): the points
## under the pointer go to `core` (`ckHoverPoints`), and the plot draws the
## traces recorded there in the hover colour; the plot's hovered trace's
## source and receiver are drawn in it here (`Selection.hoverAt`), and the
## points of the record on show are always marked (its receivers in a
## darker shade, its source larger and outlined). A click on a source shows
## its record (on a receiver of a file of receiver gathers, its gather); on
## any other point it selects the point and its traces. Ctrl + click adds or
## takes out; Shift + click selects the stations along the line from the
## point clicked last.

import std/[bitops, math, strutils]
import imguin/cimgui
import ../../core/[explain, foldactual, foldgrid, foldjobs, geometry, join, jobs, mapthin,
  noisearea, state]
import ../../gpu/mappoints
import ../../view/[maplayers, theme]
import explainmenu, focus, icons, marks, style
from windows import awMap, beginClosable

export MapRenderer

const
  menuId = "##mapmenu"
  layersId = "##maplayers"
  moreId = "##mapmore"
  burstSeconds = 0.6    ## wheel turns or key presses closer than this are one gesture
  boxMinPixels = 4'f32  ## a box narrower than this is no box
  pickRadius = 7'f32    ## how near the pointer a point is found, in pixels at 100 %
  ringWidth = 1.5'f32   ## an open file's ring, pixels at 100 %
  activeReceiverRoom = 1'f32
    ## how much larger than the receivers drawn a receiver of the gather on
    ## show is (a darker disc), pixels at 100 %
  activeSourceSize = 10'f32
    ## its source
  selectedSize = 8'f32
  shotRing = 6'f32
    ## how much wider than its source's disc the ring round a source with a
    ## file in the folder is, pixels at 100 %
  MarkSizes: array[FlagFamily, float32] = [26'f32, 22, 30, 18]
    ## the marks of each kind of finding (failed, amplitude, edits, the
    ## spread), pixels across at 100 %: apart, so marks of two kinds on one
    ## station nest (the spread's triangle inside the amplitude's circle,
    ## inside the failed traces' square, inside the edits' diamond), each
    ## with room inside for its filter's symbol
  Glyphs: array[FlagShape, GlyphKind] = [gkSquare, gkCircle, gkDiamond, gkTriangle]
  MarkStroke = 2.5'f32
  DiamondMin = 5'f32 ## the smallest diamond of a shot log's shot, pixels at 100 %
                       ## their outlines' width
  MarkHalo = 1.5'f32
    ## the halo on each side of it
  hoveredSize = 12'f32
  menuShots = 20 ## files that hold a source's shot named one by one in its menu
  scalePixels = 150'f32 ## the longest the scale bar may be, at 100 %

type
  MapDragKind = enum
    mdNone, mdPan, mdZoom, mdSelect, mdMeasure

  MapDrag = object
    ## A mouse button held down over the map.
    kind: MapDragKind
    button: cint
    press: ImVec2_c ## where it went down, in ImGui's coordinates
    start: MapView  ## the view then
    moved: bool     ## the pointer moved past ImGui's drag threshold
    adding: bool    ## a box select with Ctrl held too: adds to the selection

  MapGesture = enum
    mgNone, mgWheel, mgKeyZoom, mgKeyPan

  MapAskKind = enum
    maNone, maFit, maZoomIn, maZoomOut

  MapUi* = object
    ## The map window's own state between frames.
    renderer: MapRenderer
    gpuError: string
    started: bool
    cur: MapView
      ## the view the map shows, with the plot's size last frame
    jumps: int                                         ## the map's `jumps` last followed
    drag: MapDrag
    ruler: MapRuler                                    ## on or off: the button, and the line when one is drawn
    gesture: MapGesture
    gestureAt: float64
    focus: FocusClicks
    hovered: seq[PointRef] ## under the pointer: the nearest point, and others on its spot
    info: seq[PointInfo]                               ## what the map says of them
    infoFor: tuple[survey, shots, files, marks: int]
      ## what `info` was made from, besides the points
    sentHover: seq[PointRef]
      ## the hover last sent to `core` (`ckHoverPoints`)
    highlight: MapHighlight
    selectedFor: tuple[selected, survey: int]
      ## what `highlight` was made from
    active: array[PointRole, seq[PointRef]]
      ## the gather on show's points
    activeAt: array[PointRole, seq[MapPoint]]
      ## where they are
    selectedAt: seq[MapPoint]
      ## where `highlight.selected` are
    selectedDrawn: seq[MapPoint]
      ## of `selectedAt`, those drawn: all, or when there are more than
      ## `ThinAbove`, those in `thin`'s area round the view, one a cell
      ## (`core/mapthin`)
    thin: ThinArea ## where and how `selectedDrawn` was thinned; unset: not thinned
    drawnAll: bool ## `selectedDrawn` is all of `selectedAt`
    thinTaken: seq[uint64] ## the thinning's bitmap, kept between thinnings
    activeFor: tuple[gather: GatherRef; survey: int]
      ## what `active` was made from
    visibleFor: tuple[hidden: seq[MapLayerKey]; groups: set[MapGroup]]
      ## the layers and groups hidden when the highlight's places were found
    spreadShown, spreadHovered: PlannedSpread
      ## the spreads planned for the record on show and for the shot under the pointer
    spreadFor: tuple[gather: GatherRef; survey, spreads, checked: int; domain: RelationDomain;
      on: bool]
      ## what `spreadShown` was found from
    spreadHoverFor: tuple[point, survey, spreads: int; domain: RelationDomain; on: bool]
      ## what `spreadHovered` was found from
    boxes: seq[tuple[name: string; corners: array[4, Vec2]]]
      ## the template boxes drawn last frame, ImGui's coordinates (for tests)
    marksFor: tuple[shots, survey: int; on: bool; hidden: seq[MapLayerKey];
      groups: set[MapGroup]; filters: set[MapFilter]; qc, spreads, edits: int;
      gather: GatherRef]
      ## what the marked points were found from
    hits: array[MapFilter, FilterHits]
      ## what each filter found, as the marks show it
    hitIndex: FilterIndex
      ## `hits`' traces as sets
    markSpots: seq[(MapFilter, MarkSpots)]
      ## what each filter shown marks, merged by place, and where (`followMarks`)
    near: seq[(MapFilter, int)]
      ## what the marks under the pointer mark (`markedHere`), when the info was made
    nearFound: MarksNear ## `markedHere`'s last finding, reset when the marks change
    markCounts: array[MapFilter, tuple[places, glyphs: int]]
      ## per filter shown, the places it marks (a thing at each of its
      ## points) and the glyphs uploaded for them (one a place)
    marked: seq[seq[MapPoint]]
      ## the marked points: the sources with a file in the folder listed
    marksRev: int
    highlightRev: int
    drawnHover, drawnPlotHover: seq[PointRef]
      ## the map's own hover and the plot's hovered trace's points the GPU's
      ## highlight holds
    drawnHidden: bool ## the highlight was hidden when it was last made
    menuPoints: seq[PointRef]
    menuTitle: string
    menuShows: bool ## the menu's point shows its record on a click
    menuSelect: string ## its select item's words, as drawn last
    menuCursor: string ## the status bar's coordinates when it opened, held while it is open
    menuAt: ImVec2_c ## where the pointer was then
    menuRect: Rect ## where the menu was drawn last frame, ImGui's coordinates
    stripWidths: array[4, float32]
    rulerText, scaleText: string
    scale: ScaleBar ## the scale bar drawn last
    plot: Rect
      ## the plot's area last frame, framebuffer pixels
    wanted: MapView ## a view to give the map next frame (`show`)
    want: bool
    fold: FoldTracker
      ## the pre-plot fold layer's job and results (`core/foldjobs`)
    foldGrid: FoldGrid ## `fold.shown` with the levels made for it
    foldFor: int ## the `fold.revision` `foldGrid` is of
    foldBin: int ## the fold bin under the pointer; -1 for none
    foldSpans: seq[FoldSpan] ## the runs of fold blocks the view touches (kept between frames)
    foldLabel: string ## the pre-plot layer's line in the Layers popover, as drawn last
    foldLabels: array[FoldKind, string] ## each fold layer's line, as drawn last
    foldActual: ref ActualInputs ## the files the recorded fold counts, as built for `foldStamp`
    foldStamp: int
    foldStampSet: bool
    foldLegend: string ## the title of the colour bar drawn last
    foldBufs: tuple[along, across: array[24, char]]
    foldBufsFor: tuple[along, across: float64] ## the settings the text boxes show
    foldBufsSet: bool
    foldSplitBufs: tuple[offsets: array[160, char]; sectors: array[8, char]]
    foldSplitFor: tuple[offsets: string; sectors: int] ## the settings the text boxes show
    foldSplitSet: bool
    foldSplitError: tuple[offsets, sectors: string]
    toleranceBuf: array[24, char] ## the position filter's tolerance as typed
    toleranceFor: float64 ## the tolerance the box shows
    toleranceSet: bool
      ## why the last text typed in each box was refused (the setting keeps its last value)

  MapOutput* = object
    ## What the map window asks for.
    commands*: seq[Command]
    cursor*: string ## the pointer's coordinates for the status bar; "" off the map

proc startGpu*(mu: var MapUi): string =
  ## Makes the map's renderer, with the GL context current and the GL
  ## functions loaded (the plot's `startGpu`). "" when it can draw.
  mu.started = true
  let (r, err) = newMapRenderer()
  mu.renderer = r
  mu.gpuError = err
  err

proc stopGpu*(mu: var MapUi) =
  ## Frees the GPU objects, with the GL context still current.
  if mu.renderer.ready: mu.renderer.free()

proc keepForStragglers*(mu: MapUi) =
  ## At a quit that left a thread running: what the fold's count may still read stays.
  mu.fold.keepForStragglers()

proc show*(mu: var MapUi; v: MapView) =
  ## Gives the map the centre and scale of `v` next frame, as a pan or zoom
  ## of the user's would (its pixel size is the map's own).
  mu.wanted = v
  mu.want = true

func mapShown*(mu: MapUi): MapView {.inline.} = mu.cur
  ## The view the map showed last frame (for tests).

func hoveredPoints*(mu: MapUi): lent seq[PointRef] {.inline.} = mu.hovered
  ## The points under the pointer last frame (for tests).

func pointTexts*(mu: MapUi): seq[string] =
  ## What the map said of the points under the pointer, a line each (for
  ## tests).
  for i in mu.info:
    result.add i.title
    for l in i.lines: result.add l

func rulerText*(mu: MapUi): lent string {.inline.} = mu.rulerText
  ## What the ruler says ("1250.0 ft, bearing 090.0°"); "" with none (for tests).

func rulerOn*(mu: MapUi): bool {.inline.} = mu.ruler.on
  ## Whether the Ruler is on: the button is lit, and a plain left drag
  ## measures (for tests).

func scaleText*(mu: MapUi): lent string {.inline.} = mu.scaleText
func scaleBarShown*(mu: MapUi): ScaleBar {.inline.} = mu.scale
  ## The scale bar drawn last: its length (in the unit it names) and its
  ## length in framebuffer pixels.
  ## What the scale bar says ("500 ft"); "" with none (for tests).

func mapMenuTitle*(mu: MapUi): lent string {.inline.} = mu.menuTitle
  ## What the right-click menu said it acts on when it last opened (for tests).

func mapMenuSelect*(mu: MapUi): lent string {.inline.} = mu.menuSelect
  ## Its "Select it and its N traces" item, as drawn last (for tests).

func mapSelectedDrawn*(mu: MapUi): int {.inline.} = mu.selectedDrawn.len
  ## The selected points the highlight draws: all of them, or about one a
  ## pixel and a half when there are many (for tests).

func mapMarkCounts*(mu: MapUi; f: MapFilter): tuple[places, glyphs: int] {.inline.} =
  ## Of filter `f`'s marks, the places it marks (a thing at each of its
  ## points) and the glyphs uploaded for them: one a place (for tests).
  mu.markCounts[f]

func mapImagesDrawn*(mu: MapUi): int {.inline.} = mu.renderer.imagesDrawn
  ## How many map images were drawn (an idle map draws none; for tests).

func mapPointsDrawn*(mu: MapUi): int {.inline.} = mu.renderer.pointsDrawn
  ## How many points the last image drew (for tests).

func mapLayersUploaded*(mu: MapUi): int {.inline.} = mu.renderer.layersUploaded
  ## How many layers' points went to the GPU (for tests: a hover uploads none).

func foldLayerLine*(mu: MapUi): lent string {.inline.} = mu.foldLabel
  ## The pre-plot fold layer's line in the Layers popover as drawn last (for tests).

func foldLayerLine*(mu: MapUi; kind: FoldKind): lent string {.inline.} = mu.foldLabels[kind]
  ## The line of fold layer `kind` as drawn last (for tests).

func foldStatus*(mu: MapUi): FoldStatus {.inline.} = mu.fold.status
  ## Where the pre-plot fold layer stands (for tests).

func foldResult*(mu: MapUi): ref FoldResult {.inline.} = mu.fold.shown
  ## The fold map the layer draws; nil for none (for tests).

func foldLegendTitle*(mu: MapUi): lent string {.inline.} = mu.foldLegend
  ## The title of the fold colour bar as drawn last (for tests).

func foldBlocksDrawn*(mu: MapUi): int {.inline.} = mu.renderer.foldDrawn
  ## The blocks of bins the last image's fold layer drew (for tests).

func activeMarked*(mu: MapUi): lent array[PointRole, seq[PointRef]] {.inline.} = mu.active
  ## The points of the gather on show the map marks (for tests).

proc mapImage*(mu: MapUi): (seq[Rgba], int, int) =
  ## The last map image, row by row from the top, and its size (for tests;
  ## with the GL context current).
  let (w, h) = mu.renderer.imageSize
  (mu.renderer.readImage, w, h)

func mapPlot*(mu: MapUi): Rect {.inline.} = mu.plot
  ## The plot's area last frame, in framebuffer pixels (for tests).

func templateBoxes*(mu: MapUi): lent seq[tuple[name: string; corners: array[4, Vec2]]] {.inline.} =
  ## The template boxes drawn last frame ("map.template shown", "map.template
  ## hovered"), their corners a few pixels outside the planned stations, in
  ## ImGui's coordinates (for tests).
  mu.boxes

func spreadsShown*(mu: MapUi): (PlannedSpread, PlannedSpread) {.inline.} =
  ## The spreads planned for the record on show and for the shot under the
  ## pointer, as the map drew them last (for tests).
  (mu.spreadShown, mu.spreadHovered)

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc button(label: string; marks: var Marks; mark: string): bool =
  result = igButton(label.cstring, ImVec2_c(x: 0, y: 0))
  marks.mark(mark)

proc burst(mu: var MapUi; g: MapGesture): bool =
  ## Whether a wheel turn or key press of kind `g` starts a new gesture (for
  ## back): another kind, or a pause since the last one.
  let now = igGetTime()
  result = mu.gesture != g or now - mu.gestureAt > burstSeconds
  mu.gesture = g
  mu.gestureAt = now

template stripGroup(mu: var MapUi; i: int; right, spacing: float32; body: untyped) =
  ## Group `i` of the strip, on the line of the group before it when it fits
  ## left of `right` (its width as drawn last frame), else on a new line.
  if i > 0 and igGetItemRectMax().x + spacing + mu.stripWidths[i] <= right:
    igSameLine(0, spacing)
  igBeginGroup()
  body
  igEndGroup()
  mu.stripWidths[i] = igGetItemRectSize().x

func roleWord(r: PointRole): string =
  if r == prSource: "sources" else: "receivers"

proc swatch(c: Rgba; id: string) =
  let s = igGetFrameHeight() * 0.6
  discard igColorButton(id.cstring, vec4(c), ImGui_ColorEditFlags_NoTooltip.cint or
    ImGui_ColorEditFlags_NoPicker.cint, ImVec2_c(x: s, y: s))

proc glyphIcon(c, background: Rgba; shape: FlagShape; symbol: FlagSymbol; id: string) =
  ## A filter's mark as the map draws it, on the map's background, the size
  ## of a swatch: the legend of the filters' marks.
  let s = igGetFrameHeight() * 0.8
  let at = igGetCursorScreenPos()
  discard igInvisibleButton(id.cstring, ImVec2_c(x: s, y: s), 0)
  let dl = igGetWindowDrawList()
  ImDrawList_AddRectFilled(dl, at, ImVec2_c(x: at.x + s, y: at.y + s), u32(background), 2, 0)
  let (cx, cy, r) = (at.x + s / 2, at.y + s / 2, s / 2 - 1.5)
  let (col, w) = (u32(c), 1.6'f32)
  template p(dx, dy: float32): ImVec2_c = ImVec2_c(x: cx + dx, y: cy + dy)
  case shape
  of shCircle: ImDrawList_AddCircle(dl, p(0, 0), r, col, 0, w)
  of shSquare: ImDrawList_AddRect(dl, p(-0.82 * r, -0.82 * r), p(0.82 * r, 0.82 * r), col, 0, w, 0)
  of shDiamond: ImDrawList_AddQuad(dl, p(0, -r), p(r, 0), p(0, r), p(-r, 0), col, w)
  of shTriangle: ImDrawList_AddTriangle(dl, p(0, -r), p(0.866 * r, 0.5 * r),
    p(-0.866 * r, 0.5 * r), col, w)
  # the symbol inside, as the map's shader draws it
  let k = 0.6 * r * (case shape
    of shCircle: 1'f32
    of shSquare: 0.82
    of shDiamond: 0.7071
    of shTriangle: 0.6)
  let ws = w * 0.8
  case symbol
  of syNone: discard
  of syCross:
    let q = 0.8 * k
    ImDrawList_AddLine(dl, p(-q, -q), p(q, q), col, ws)
    ImDrawList_AddLine(dl, p(-q, q), p(q, -q), col, ws)
  of syPlus:
    ImDrawList_AddLine(dl, p(-k, 0), p(k, 0), col, ws)
    ImDrawList_AddLine(dl, p(0, -k), p(0, k), col, ws)
  of syBar: ImDrawList_AddLine(dl, p(-k, 0), p(k, 0), col, ws)
  of syUpright: ImDrawList_AddLine(dl, p(0, -k), p(0, k), col, ws)
  of syRing: ImDrawList_AddCircle(dl, p(0, 0), 0.7 * k, col, 0, ws)
  of syDot: ImDrawList_AddCircleFilled(dl, p(0, 0), 0.35 * k, col, 0)
  of syDash: ImDrawList_AddLine(dl, p(-0.7 * k, 0.7 * k), p(0.7 * k, -0.7 * k), col, ws)
  of syBackslash: ImDrawList_AddLine(dl, p(-0.7 * k, -0.7 * k), p(0.7 * k, 0.7 * k), col, ws)

proc layerRow(l: MapLayerView; i: int; marks: var Marks; res: var MapOutput) =
  ## One layer of the popover: its colour, its own toggle and its points.
  igPushID_Int(cint(i))
  swatch(l.colour, "##colour")
  tip("This layer's colour")
  igSameLine(0, -1)
  var on = l.own
  let label = l.name & (if l.points > 0: "  (" & $l.points & ")" else: "")
  if igCheckbox(label.cstring, addr on):
    res.commands.add Command(kind: ckMapLayer, mapLayer: l.key, shown: on)
  marks.mark("map.layer " & (if l.key.kind == mlHighlight: "highlight"
    else: l.file & " " & roleWord(l.role)))
  tip("Show or hide this layer")
  igPopID()

const groupTips: array[MapGroup, string] = [
  "The survey files (SPS, SEG P1): the sources and receivers the survey planned",
  "What the seismic files say: their traces' own positions, as their headers give " &
    "them or as a join with the survey files made them"]

proc numberEntry(id: string; value: float64; format: string; typed: var float64): bool =
  ## A box for a number: true once the user has finished typing into it
  ## (Enter, or clicking away), the value in `typed`.
  var v = cdouble(value)
  igSetNextItemWidth(round(igCalcTextSize("0000000.0", nil, false, -1).x +
    2 * igGetStyle().FramePadding.x))
  discard igInputDouble(id.cstring, addr v, 0, 0, format.cstring, 0)
  typed = float64(v)
  igIsItemDeactivatedAfterEdit()

proc wrapped(text: string) =
  ## Dim text, wrapped at the popover's width.
  igPushTextWrapPos(igGetCursorPosX() + 34 * igGetFontSize())
  igTextDisabled("%s", text.cstring)
  igPopTextWrapPos()

const TemplateLabel = "Template box: the spread planned for the shot"
const templateTip = "Off by default. A box round the receivers the relation (X) records " &
  "plan for the record shown (dark) and for the source under the pointer (the hover " &
  "colour); for a file of receiver gathers, round the shots the O records plan for the " &
  "receiver. With no relation file loaded, the planned spreads are generated from the " &
  "template given here."

proc drawTemplateRow(st: AppState; marks: var Marks; res: var MapOutput) =
  ## The template box's tick, under the Preplot: what the planned spreads
  ## come from, and the template they are generated from when no relation
  ## file is loaded.
  var s = st.settings
  var on = s.map.templateBox
  if igCheckbox(TemplateLabel, addr on):
    s.map.templateBox = on
    res.commands.add Command(kind: ckSettings, settings: s)
  marks.mark("map.template")
  tip(templateTip)
  if not on: return
  igIndent(0)
  let listed = st.survey.listedLayer(st.shownDomain)
  if listed >= 0:
    wrapped("From the relation records of " & st.survey.layers[listed].name & ".")
  for w in st.spreads.words: wrapped(w)
  if st.spreads.job != NoJob: wrapped("Making the planned spreads...")
  if st.recordQc.job != NoJob: wrapped("Checking the record shown...")
  if st.survey.listedLayer(rdSource) < 0:
    var t = s.map.spreadTemplate
    var changed = false
    igTextUnformatted("Template (no relation file is loaded):", nil)
    for (shape, label) in [(tsPatch, "Lines × stations"), (tsBox, "A distance box")]:
      if igRadioButton_Bool(label.cstring, t.shape == shape) and t.shape != shape:
        t.shape = shape
        changed = true
      marks.mark("map.template " & (if shape == tsPatch: "patch" else: "box"))
      igSameLine(0, -1)
    igNewLine()
    var typed = 0.0
    case t.shape
    of tsPatch:
      if numberEntry("##lines", float64(t.lines), "%.0f", typed):
        (t.lines, changed) = (int(clamp(typed, 1, MaxTemplateLines)), true)
      marks.mark("map.template lines")
      igSameLine(0, -1)
      igTextUnformatted("lines ×", nil)
      igSameLine(0, -1)
      if numberEntry("##channels", float64(t.channels), "%.0f", typed):
        (t.channels, changed) = (int(clamp(typed, 1, MaxTemplateChannels)), true)
      marks.mark("map.template channels")
      igSameLine(0, -1)
      igTextUnformatted("stations, centred on the source", nil)
    of tsBox:
      igTextUnformatted("±", nil)
      igSameLine(0, 2)
      if numberEntry("##inline", t.inlineHalf, "%.1f", typed) and typed > 0:
        (t.inlineHalf, changed) = (typed, true)
      marks.mark("map.template inline")
      igSameLine(0, -1)
      igTextUnformatted("along the receiver lines, ±", nil)
      igSameLine(0, 2)
      if numberEntry("##crossline", t.crosslineHalf, "%.1f", typed) and typed > 0:
        (t.crosslineHalf, changed) = (typed, true)
      marks.mark("map.template crossline")
      igSameLine(0, -1)
      igTextUnformatted(("across " & st.unitsOf).cstring, nil)
    if changed:
      s.map.spreadTemplate = bounded(t)
      res.commands.add Command(kind: ckSettings, settings: s)
  igUnindent(0)

const shotsTip = "The survey's sources whose record is in a file of the folder listed are " &
  "ringed, and a click on one shows that file at its record. The files are read in the " &
  "background (their shots are kept beside the index cache, so the folder listed again " &
  "reads none), while a survey file with sources is loaded."

proc drawShotsRow(st: AppState; marks: var Marks; res: var MapOutput) =
  ## The folder's shots' tick, under the Recorded: how many of the survey's
  ## sources have a file, and how far the files' reading is.
  var s = st.settings
  var on = s.map.folderShots
  template x: untyped = st.shots
  var sources = 0
  for i in 0 ..< st.survey.layers.len:
    if st.survey.layers[i].origin == loSurveyFile:
      sources += st.survey.layers[i].points[prSource].len
  let label = if sources == 0: "Shots in the folder (with a survey file's sources loaded)"
              else: "Shots in the folder: " & $x.pointRefs.len & " of " & $sources &
                " sources have a file"
  if igCheckbox(label.cstring, addr on):
    s.map.folderShots = on
    res.commands.add Command(kind: ckSettings, settings: s)
  marks.mark("map.shots")
  tip(shotsTip)
  if on and sources > 0:
    igIndent(0)
    let left = x.pending.len + x.jobPaths.len
    if left > 0:
      wrapped("Reading the folder's files: " & $x.shotFiles & " read, " & $left & " to go.")
    let lost = x.unplacedShots
    if lost > 0:
      wrapped($lost & (if lost == 1: " shot has" else: " shots have") &
        " no source line and point and " & (if lost == 1: "is" else: "are") &
        " not on the map.")
    if x.waiting:
      wrapped("The folder does not answer: its files are read on once it does.")
    elif x.later.len > 0:
      wrapped($x.later.len & (if x.later.len == 1: " file does" else: " files do") &
        " not answer: tried again in a minute.")
    igUnindent(0)

const
  foldTip = "Off by default. The pre-plot fold: how many source-receiver pairs the " &
    "relation (X) records plan for each bin of a grid laid on the survey's midpoints, as a " &
    "heat map under the points. The grid follows the receiver lines; the bin is half the " &
    "receiver interval by half the source interval unless you give one below. One fold layer " &
    "is drawn at a time: ticking one unticks the others."
  actualTip = "Off by default. The fold of the traces recorded in the seismic files the Files " &
    "window lists (its subfolders' files when it includes them), over the same bins as the " &
    "pre-plot fold. Each trace is counted once, at the midpoint of its source and receiver " &
    "(the map's survey and the station moves applied in memory; the files are not changed); " &
    "traces that are not live, that you killed, that have no positions or that fall outside " &
    "the grid are left out and counted. A file reached twice through a link is counted once, " &
    "but copies of one recording in the folder (a converted copy beside its original) are " &
    "counted twice. Files are read with the default options, also one opened with Reopen " &
    "with options. One fold layer is drawn at a time: ticking one unticks the others."
  differenceTip = "Off by default. The pre-plot fold less the recorded fold, per bin: " &
    "positive is short of the plan (red), negative is more than planned (blue), 0 (as planned) " &
    "is a light grey; a bin with neither a plan nor a trace is left clear. " &
    "The files are those of the recorded fold layer. One fold layer is drawn at a time: " &
    "ticking one unticks the others."
  splitTip = "Restricts the fold layers to one class of offsets (the distance from source to " &
    "receiver; the edges are in the survey's length unit, such as 0, 1000, 2000, 4000: a " &
    "class holds its first edge up to but not including the next) or to one sector of the " &
    "bearing from source to receiver (2 to 36 sectors, the first starting at north, " &
    "clockwise; many sectors on a fine grid need much memory, and are refused beyond the " &
    "budget). Draw one of them, or All. Only one restriction applies at a time: " &
    "choosing an offset class sets the azimuth to All, and the reverse. The recorded fold " &
    "of every class is counted at once, so another class draws without reading the files " &
    "again."
  FoldNames: array[FoldKind, string] = ["Pre-plot fold", "Actual fold", "Fold difference"]

func foldOn(m: MapOptions; kind: FoldKind): bool =
  case kind
  of fkPreplot: m.foldLayer
  of fkActual: m.foldActual
  of fkDifference: m.foldDifference

func foldAny(m: MapOptions): bool = m.foldLayer or m.foldActual or m.foldDifference

func foldKindOf(m: MapOptions): FoldKind =
  ## The layer drawn: the difference, else the recorded fold, else the pre-plot.
  if m.foldDifference: fkDifference elif m.foldActual: fkActual else: fkPreplot

func foldWords(mu: MapUi; st: AppState; kind: FoldKind): string =
  ## The line of fold layer `kind` in the Layers popover.
  let name = FoldNames[kind]
  if not st.settings.map.foldOn(kind): return name
  let r = mu.fold.shown
  let most = if r.isNil: "" elif r.kind == fkDifference: ": largest " & $r.maxFold
             else: ": max fold " & $r.maxFold
  case mu.fold.status
  of fmComputing: name & (if mu.fold.updating: most & ", updating..." else: ": computing...")
  of fmReady: name & most
  else: name

proc foldWant(mu: var MapUi; st: AppState): FoldWant =
  ## What the follower is asked for this frame: the layer ticked and, for the recorded fold
  ## and the difference, the files to count (built again only when the stamp moved).
  let m = st.settings.map
  result = FoldWant(kind: m.foldKindOf, on: m.foldAny,
    scope: st.fileList.folder & "|" & $st.fileList.recursive,
    split: splitOf(m.foldOffsets, m.foldOffsetClass, m.foldSectors, m.foldSector))
  if result.on and result.kind != fkPreplot:
    result.why = actualReason(st)
    result.waiting = result.why == Listing
    if result.why.len == 0:
      let stamp = actualStamp(st)
      if mu.foldActual.isNil or not mu.foldStampSet or stamp != mu.foldStamp:
        mu.foldActual = actualInputs(st)
        (mu.foldStamp, mu.foldStampSet) = (stamp, true)
      result.actual = mu.foldActual
      result.stamp = stamp
    else:
      result.stamp = -1 - result.why.len

proc binBox(id: string; buf: var array[24, char]; hint: string): bool =
  ## A text box for a bin size: true once the user has finished typing into it.
  igSetNextItemWidth(round(igCalcTextSize("00000000", nil, false, -1).x +
    2 * igGetStyle().FramePadding.x))
  discard igInputTextWithHint(id.cstring, hint.cstring, cast[cstring](addr buf[0]),
    csize_t(buf.len), 0, nil, nil)
  igIsItemDeactivatedAfterEdit()

func boxText(v: float64): string = (if v > 0: $v else: "")

func numberText(v: float64): string =
  ## `v` as a box shows it: "5", "0.5".
  if v == round(v) and abs(v) < 1e15: $int64(v) else: $v

proc fillBox(buf: var array[24, char]; text: string) =
  for i in 0 ..< buf.len: buf[i] = '\0'
  for i in 0 ..< min(text.len, buf.len - 1): buf[i] = text[i]

proc boxValue(buf: array[24, char]): float64 =
  var text = ""
  for c in buf:
    if c == '\0': break
    text.add c
  text = text.strip
  if text.len == 0: return 0
  try: result = parseFloat(text)
  except ValueError: result = -1
  if not (result > 0 and result < 1e12): result = -1

proc fillText(buf: var openArray[char]; text: string) =
  for i in 0 ..< buf.len: buf[i] = '\0'
  for i in 0 ..< min(text.len, buf.len - 1): buf[i] = text[i]

func bufText(buf: openArray[char]): string =
  for c in buf:
    if c == '\0': break
    result.add c

proc splitBox(id: string; buf: var openArray[char]; hint: string; chars: int): bool =
  ## A text box `chars` wide for what restricts the fold layers: true once the user has
  ## finished typing into it.
  igSetNextItemWidth(round(igCalcTextSize("0".cstring, nil, false, -1).x * float32(chars) +
    2 * igGetStyle().FramePadding.x))
  discard igInputTextWithHint(id.cstring, hint.cstring, cast[cstring](addr buf[0]),
    csize_t(buf.len), 0, nil, nil)
  igIsItemDeactivatedAfterEdit()

proc splitPick(split: FoldSplit; id, mark: string; unit: string; picked: int;
    marks: var Marks): int =
  ## The choice of which class or sector is drawn: -1 for no change, else 0 for all or the
  ## class + 1.
  result = -1
  let now = if split.drawn: split.classLabel(split.pick, unit) else: "All"
  igSetNextItemWidth(round(igCalcTextSize("0".cstring, nil, false, -1).x * 22 +
    2 * igGetStyle().FramePadding.x))
  if igBeginCombo(id.cstring, now.cstring, 0):
    for k in 0 .. split.classes:
      let label = if k == 0: "All" else: split.classLabel(k - 1, unit)
      if igSelectable_Bool((label & "##" & id & $k).cstring, k == picked, 0,
          ImVec2_c(x: 0, y: 0)):
        result = k
      marks.mark(mark & " " & $k)
    igEndCombo()
  marks.mark(mark)

proc drawSplitRows(mu: var MapUi; st: AppState; marks: var Marks; res: var MapOutput) =
  ## The restriction of the fold layers to one offset class or one azimuth sector: the class
  ## edges and the number of sectors typed in boxes, and which class or sector is drawn.
  var s = st.settings
  let unit = st.unitsOf
  if not mu.foldSplitSet or mu.foldSplitFor != (s.map.foldOffsets, s.map.foldSectors):
    mu.foldSplitBufs.offsets.fillText(s.map.foldOffsets)
    mu.foldSplitBufs.sectors.fillText(if s.map.foldSectors > 0: $s.map.foldSectors else: "")
    mu.foldSplitFor = (s.map.foldOffsets, s.map.foldSectors)
    mu.foldSplitSet = true
    mu.foldSplitError = ("", "")
  var changed = false
  igTextUnformatted("Offsets:", nil)
  igSameLine(0, -1)
  if splitBox("##foldoffsets", mu.foldSplitBufs.offsets, "all, or 0, 1000, 2000", 22):
    let text = bufText(mu.foldSplitBufs.offsets)
    let edges = parseEdges(text)
    mu.foldSplitError.offsets = edges.error
    if edges.error.len == 0:
      let good = edgesText(edges.edges)
      if good != s.map.foldOffsets: (s.map.foldOffsets, s.map.foldOffsetClass) = (good, 0)
      changed = true
  marks.mark("map.fold offsets")
  tip(splitTip)
  igSameLine(0, -1)
  igTextUnformatted(unit.cstring, nil)
  if mu.foldSplitError.offsets.len > 0: wrapped(mu.foldSplitError.offsets)
  if s.map.foldOffsets.len > 0:
    igIndent(0)
    igTextUnformatted("Draw:", nil)
    igSameLine(0, -1)
    let edges = parseEdges(s.map.foldOffsets).edges
    let k = splitPick(FoldSplit(kind: spOffset, edges: edges, pick: s.map.foldOffsetClass - 1),
      "##foldoffsetpick", "map.fold offsets pick", unit, s.map.foldOffsetClass, marks)
    tip(splitTip)
    if k >= 0:
      (s.map.foldOffsetClass, changed) = (k, true)
      if k > 0: s.map.foldSector = 0
    igUnindent(0)
  igTextUnformatted("Azimuth sectors:", nil)
  igSameLine(0, -1)
  if splitBox("##foldsectors", mu.foldSplitBufs.sectors, "all", 3):
    let sectors = parseSectors(bufText(mu.foldSplitBufs.sectors))
    mu.foldSplitError.sectors = sectors.error
    if sectors.error.len == 0:
      if sectors.sectors != s.map.foldSectors: (s.map.foldSectors, s.map.foldSector) = (
        sectors.sectors, 0)
      changed = true
  marks.mark("map.fold sectors")
  tip(splitTip)
  if mu.foldSplitError.sectors.len > 0: wrapped(mu.foldSplitError.sectors)
  if s.map.foldSectors >= MinSectors:
    igIndent(0)
    igTextUnformatted("Draw:", nil)
    igSameLine(0, -1)
    let k = splitPick(FoldSplit(kind: spAzimuth, sectors: s.map.foldSectors,
      pick: s.map.foldSector - 1), "##foldsectorpick", "map.fold sectors pick", unit,
      s.map.foldSector, marks)
    tip(splitTip)
    if k >= 0:
      (s.map.foldSector, changed) = (k, true)
      if k > 0: s.map.foldOffsetClass = 0
    igUnindent(0)
  if changed: res.commands.add Command(kind: ckSettings, settings: s)

proc foldTick(mu: var MapUi; st: AppState; marks: var Marks; res: var MapOutput;
    kind: FoldKind) =
  ## The tick of fold layer `kind`, dim with the reason when it cannot be made. Ticking one
  ## layer unticks the others.
  var reason = st.survey.foldReason
  if reason.len == 0 and kind != fkPreplot: reason = actualReason(st)
  var s = st.settings
  var on = s.map.foldOn(kind)
  mu.foldLabels[kind] = mu.foldWords(st, kind)
  if kind == fkPreplot: mu.foldLabel = mu.foldLabels[kind]
  igBeginDisabled(reason.len > 0 and not on)
  if igCheckbox((mu.foldLabels[kind] & "###fold" & $ord(kind)).cstring, addr on):
    (s.map.foldLayer, s.map.foldActual, s.map.foldDifference) = (false, false, false)
    case kind
    of fkPreplot: s.map.foldLayer = on
    of fkActual: s.map.foldActual = on
    of fkDifference: s.map.foldDifference = on
    res.commands.add Command(kind: ckSettings, settings: s)
  igEndDisabled()
  marks.mark(["map.fold", "map.fold actual", "map.fold difference"][ord(kind)])
  tip(if reason.len > 0: reason else: [foldTip, actualTip, differenceTip][ord(kind)])
  if reason.len > 0 and not on and (kind == fkPreplot or st.survey.foldReason.len == 0):
    igIndent(0)
    wrapped(reason)
    igUnindent(0)

proc drawFoldRow(mu: var MapUi; st: AppState; marks: var Marks; res: var MapOutput) =
  ## The fold layers' ticks, under the Preplot: the pre-plot fold, the recorded fold and the
  ## difference (one is drawn at a time), each dim with the reason when the survey or the
  ## files cannot give one; the bin sizes and the totals under them once one is ticked.
  for kind in FoldKind: mu.foldTick(st, marks, res, kind)
  var s = st.settings
  if s.map.foldAny:
    igIndent(0)
    if not mu.foldBufsSet or mu.foldBufsFor != (s.map.foldAlong, s.map.foldAcross):
      mu.foldBufs.along.fillBox(boxText(s.map.foldAlong))
      mu.foldBufs.across.fillBox(boxText(s.map.foldAcross))
      mu.foldBufsFor = (s.map.foldAlong, s.map.foldAcross)
      mu.foldBufsSet = true
    let unit = st.unitsOf
    var changed = false
    igTextUnformatted("Bin along the receiver lines:", nil)
    igSameLine(0, -1)
    if binBox("##foldalong", mu.foldBufs.along, "natural"):
      let v = boxValue(mu.foldBufs.along)
      if v >= 0: (s.map.foldAlong, changed) = (v, true)
      else: mu.foldBufsSet = false
    marks.mark("map.fold along")
    igSameLine(0, -1)
    igTextUnformatted(unit.cstring, nil)
    igTextUnformatted("Bin across them:", nil)
    igSameLine(0, -1)
    if binBox("##foldacross", mu.foldBufs.across, "natural"):
      let v = boxValue(mu.foldBufs.across)
      if v >= 0: (s.map.foldAcross, changed) = (v, true)
      else: mu.foldBufsSet = false
    marks.mark("map.fold across")
    igSameLine(0, -1)
    igTextUnformatted(unit.cstring, nil)
    if changed: res.commands.add Command(kind: ckSettings, settings: s)
    mu.drawSplitRows(st, marks, res)
    case mu.fold.status
    of fmReady:
      let r = mu.fold.shown
      wrapped(r[].totalsText(unit))
      marks.mark("map.fold totals")
    of fmFailed, fmImpossible: wrapped(mu.fold.reason)
    of fmComputing:
      if mu.fold.updating:
        # the last map counted stays while the files changed are counted
        wrapped("Updating... " & (if mu.fold.reason.len > 0: mu.fold.reason & " " else: "") &
          mu.fold.shown[].totalsText(unit))
        marks.mark("map.fold totals")
      elif mu.fold.reason.len > 0: wrapped(mu.fold.reason)
    else: discard
    igUnindent(0)

const filterTips: array[MapFilter, string] = [
  "Traces the file marks dead in their headers",
  "Traces whose samples could not be decoded",
  "Traces you killed (the plot's menu, K)",
  "Traces outside the exclusion area (near the source) whose RMS is far above the others'" &
    " (robust z over 3.5)",
  "Traces with runs of samples at their maximum: a recorder or a conversion that saturated",
  "Traces with samples far above their neighbours (spikes)",
  "Traces whose every sample is the same value, not zero",
  "Traces whose RMS is far below the others' (robust z under -3.5), judged against the traces" &
    " outside the exclusion area",
  "Traces whose mean is large against their deviation",
  "Traces whose every sample is 0, whatever the header says",
  "Traces with a sample that is not a number, or infinite",
  "Stations the template (the relation records) plans for the record that it has no trace of",
  "Traces at stations the template does not list for the record",
  "Stations recorded twice in one component",
  "Traces that are not seismic (time breaks, pilots): counted, they have no place on the map",
  "Seismic traces the map cannot place (no coordinates, and no survey file has their station)",
  "Traces whose polarity you reversed (the plot's menu, R)",
  "Shots whose listed receivers are not those of the template the relation records describe",
  "Traces outside the exclusion area far louder than those either side of them on their own" &
    " line (a station that is loud against its neighbours, not noisy against the record)",
  "Traces whose noise was not judged: inside the exclusion area, whose sensor or station is" &
    " not known, or of a node with a component missing. They are not shown as good",
  "Traces whose own header receiver or source position is not where the survey puts their" &
    " station (a station that moved, or a survey that is not the file's). Any format. In the" &
    " station-move menu, \"Move this station to the position in this trace's headers\"" &
    " follows it"]

const NoiseWrapEm = 30'f32 ## the words' lines wrap at this many font sizes

func geometryShown(st: AppState): seq[string] =
  ## The lines the position filter's words take under "Filters": why it is not judged, what
  ## the header positions share (none while it is off).
  if mfPositionOff in st.settings.map.filters: st.recordQc.geometry.geometryLines else: @[]

func noiseLines(st: AppState): seq[string] =
  ## The lines the noisy-trace test's words take under "Filters" (none while no
  ## noise filter is on or the record has no result), each as the list shows it.
  let n = st.recordQc.noise
  if n.ready and st.settings.map.filters * NoiseFilters != {}:
    for line in [n.areaWords & ".", n.notesWords, "Not judged: " & n.notJudgedWords & "."]:
      if line.len > 1: result.add line

const FilterOrder = [mfDead, mfUndecodable, mfKilled, mfNoisy, mfLouder, mfWeak, mfNotJudged,
  mfClipped, mfSpiky, mfConstant, mfDcOffset, mfAllZero, mfNotANumber, mfMissing, mfUnlisted,
  mfDuplicate, mfAuxiliary, mfNoPosition, mfReversed, mfSpreadDiffers, mfPositionOff]
  ## the order the filters are listed in: the noisy-trace test's findings together
static: doAssert FilterOrder.len == ord(high(MapFilter)) + 1, "a filter is not listed"

proc toleranceRow(mu: var MapUi; st: AppState; marks: var Marks; res: var MapOutput) =
  ## Beside the position filter: how far a header position may be from the position in
  ## force, in the survey's unit ("more than [ 5 ] m from the survey"); emptied, the default.
  let g = st.recordQc.geometry
  let unit = if g.ready and g.tolerance > 0: g.positionUnit else: st.surveyUnit
  let shown = positionTolerance(st.settings.map.positionTolerance, unit)
  if not mu.toleranceSet or mu.toleranceFor != shown:
    mu.toleranceBuf.fillBox(numberText(shown))
    (mu.toleranceFor, mu.toleranceSet) = (shown, true)
  igIndent(0)
  igAlignTextToFramePadding()
  igTextUnformatted("more than", nil)
  igSameLine(0, -1)
  if binBox("##positiontolerance", mu.toleranceBuf, numberText(positionTolerance(0, unit))):
    let v = boxValue(mu.toleranceBuf)
    if v == 0 or v in MinPositionTolerance .. MaxPositionTolerance:
      var s = st.settings
      s.map.positionTolerance = v
      res.commands.add Command(kind: ckSettings, settings: s)
    mu.toleranceSet = false # (refused: the box shows the tolerance in force again)
  marks.mark("map.filter tolerance")
  tip("How far a trace's own header position may be from its station's position in force " &
    "(the survey's, or a station move's) before it is marked, in the survey's unit: from " &
    $MinPositionTolerance & " to " & $MaxPositionTolerance & ". Empty: " &
    lengthWords(DefaultMetres, suMetres) & ", or " & lengthWords(DefaultFeet, suFeet) &
    " when the survey is in feet. A number typed is kept as typed: when a survey in another " &
    "unit is loaded it is read in that unit, not converted.")
  igSameLine(0, -1)
  let words = if unit.abbreviation.len > 0: unit.abbreviation & " from the survey"
              else: "from the survey (in its unit)"
  igTextUnformatted(words.cstring, nil)
  igUnindent(0)

proc drawFilters(mu: var MapUi; st: AppState; hits: array[MapFilter, FilterHits]; t: Theme;
    marks: var Marks; res: var MapOutput) =
  ## The map's filters on the record shown: each with its colour, its tick
  ## and what it found (a count, "..." while its job runs, "not checked"
  ## with the reason in its tooltip), and Select for those that found
  ## traces (they are selected in the plot).
  igSeparatorText("Filters: the record shown")
  let words = noiseLines(st)
  if words.len > 0:
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
    igPushTextWrapPos(igGetCursorPosX() + NoiseWrapEm * igGetFontSize())
    for line in words: igTextUnformatted(line.cstring, nil)
    igPopTextWrapPos()
    igPopStyleColor(1)
    marks.mark("map.noise area")
    tip("The noisy-trace test leaves the traces near the source out of the judgement. " &
      "Choose how the area is set in Tools > Settings.")
  let ink = mapInk(t, st.settings.plot.display.colours, st.settings.plot.display.custom)
  for f in FilterOrder:
    igPushID_Int(cint(ord(f) + 1000))
    # its mark, as the map draws it: a shape of its own, the colour of its kind
    glyphIcon(filterInk(t, f, ink.background), ink.background, f.shapeOf, FilterMarks[f].symbol,
      "##mark")
    marks.mark("map.filter mark " & $f)
    igSameLine(0, -1)
    var on = f in st.settings.map.filters
    let h = if on: hits[f] else: FilterHits()
    if igCheckbox(filterLabel(f, h).cstring, addr on):
      var s = st.settings
      if on: s.map.filters.incl f else: s.map.filters.excl f
      res.commands.add Command(kind: ckSettings, settings: s)
    marks.mark("map.filter " & $f)
    tip(filterTips[f] & (if h.note.len > 0 and h.state == fsNotChecked: ".\nNot checked: " &
      h.note & "." elif h.note.len > 0 and h.state == fsDone: " (" & h.note & ")." else: ".") &
      "\nMarked on the map with a " & $f.shapeOf & (if FilterMarks[f].symbol == syNone: ""
      else: " with " & $FilterMarks[f].symbol & " inside") & ": the shape and the colour of " &
      $FilterMarks[f].family & ".")
    if on and h.traces.len > 0:
      igSameLine(0, -1)
      if igSmallButton("Select"):
        res.commands.add Command(kind: ckSelect, traces: h.traces, mode: smReplace)
      marks.mark("map.filter select " & $f)
      tip("Select these " & $h.traces.len & " traces in the plot")
    if f == mfPositionOff and on: mu.toleranceRow(st, marks, res)
    igPopID()
  let geometry = geometryShown(st)
  if geometry.len > 0:
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
    igPushTextWrapPos(igGetCursorPosX() + NoiseWrapEm * igGetFontSize())
    for line in geometry: igTextUnformatted(line.cstring, nil)
    igPopTextWrapPos()
    igPopStyleColor(1)
    marks.mark("map.geometry")
    tip("The file's own header positions are compared with the positions in force: the " &
      "survey's stations, or their station moves. A trace with no position, or whose station " &
      "the survey lacks, cannot be compared." & (if st.recordQc.geometry.projectSurvey:
      " This file is not joined to the project's survey: its headers are compared with it " &
      "by the stations they name." else: ""))

proc drawLayers(mu: var MapUi; st: AppState; layers: openArray[MapLayerView]; marks: var Marks;
    res: var MapOutput; hits: array[MapFilter, FilterHits]; t: Theme) =
  ## The layers popover, in groups: the Preplot (the survey files), then the
  ## Recorded (the open files' own positions), each with its own toggle and
  ## its layers under it (each with its colour and toggle; greyed out while
  ## the group is hidden), then the highlight. Units the files disagree on
  ## are said first.
  let disagree = st.unitsDisagree
  if disagree.len > 0:
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
    igPushTextWrapPos(igGetCursorPosX() + 34 * igGetFontSize())
    igTextUnformatted((disagree & ".").cstring, nil)
    igPopTextWrapPos()
    igPopStyleColor(1)
    marks.mark("map.units disagree")
  for g in MapGroup:
    var on = g notin st.settings.map.hiddenGroups
    let label = $g & (if g == mgPreplot: ": the survey files" else: ": the seismic files")
    if igCheckbox(label.cstring, addr on):
      var s = st.settings
      if on: s.map.hiddenGroups.excl g else: s.map.hiddenGroups.incl g
      res.commands.add Command(kind: ckSettings, settings: s)
    marks.mark("map.group " & ($g).toLowerAscii)
    tip(groupTips[g])
    igIndent(0)
    var any = false
    igBeginDisabled(not on)
    for i, l in layers:
      if l.key.kind notin {mlHighlight, mlShotLog} and l.group == g:
        any = true
        layerRow(l, i, marks, res)
    igEndDisabled()
    if not any:
      let none = if g == mgPreplot: "No survey file loaded (open SPS or SEG P1 files)"
                 else: "No seismic file whose traces carry positions is open"
      igTextDisabled("%s", none.cstring)
    if g == mgPreplot:
      drawTemplateRow(st, marks, res)
      mu.drawFoldRow(st, marks, res)
    else: drawShotsRow(st, marks, res)
    igUnindent(0)
  var shotLogs = false # a log with positions only: no entry, not even an empty one, else
  for l in layers: shotLogs = shotLogs or l.key.kind == mlShotLog
  if shotLogs:
    igTextUnformatted("Shot log".cstring, nil)
    marks.mark("map.shotlogs")
    tip("The shots of a loaded shot log whose columns give positions")
    igIndent(0)
    for i, l in layers:
      if l.key.kind == mlShotLog: layerRow(l, i, marks, res)
    igUnindent(0)
  mu.drawFilters(st, hits, t, marks, res)
  igSeparator()
  for i, l in layers:
    if l.key.kind == mlHighlight: layerRow(l, i, marks, res)

proc widest(texts: openArray[string]): float32 =
  for t in texts: result = max(result, igCalcTextSize(t.cstring, nil, false, -1).x)

proc placePopover(at: ImVec2_c; width: float32) =
  ## Opens the next popup with its top-left corner at `at`, moved left as
  ## far as needed for a popup `width` wide (its widest line) to stay inside
  ## the main window: past its edge it would become a window of its own,
  ## which takes the keyboard focus.
  let vp = igGetMainViewport()
  let room = width + 2 * igGetStyle().WindowPadding.x + 3 * igGetFrameHeight()
  let x = max(vp.WorkPos.x, min(at.x, vp.WorkPos.x + vp.WorkSize.x - room))
  igSetNextWindowPos(ImVec2_c(x: x, y: at.y), ImGui_Cond_Always.cint, ImVec2_c(x: 0, y: 0))
  # Never past the main window's bottom either: a longer one scrolls.
  igSetNextWindowSizeConstraints(ImVec2_c(x: 0, y: 0), ImVec2_c(x: vp.WorkSize.x,
    y: max(igGetFrameHeight() * 4, vp.WorkPos.y + vp.WorkSize.y - at.y - 8)), nil, nil)

proc layersWidth(layers: openArray[MapLayerView]; words: openArray[string]): float32 =
  ## The widest line of the Layers popover.
  var lines = @[$mgPreplot & ": the survey files", TemplateLabel,
    "Shots in the folder: 10000 of 10000 sources have a file",
    "Missing from the template  (not checked)  Select",
    "No survey file loaded (open SPS or SEG P1 files)",
    "No seismic file whose traces carry positions is open",
    "Pre-plot fold: max fold 99999", "Bin along the receiver lines:  natural  US survey ft"]
  for l in layers: lines.add l.name & "  (" & $l.points & ")"
  max(widest(lines), min(widest(words), NoiseWrapEm * igGetFontSize())) +
    igGetStyle().IndentSpacing

proc drawStrip(mu: var MapUi; st: AppState; layers: openArray[MapLayerView]; marks: var Marks;
    res: var MapOutput; ask: var MapAskKind; t: Theme) =
  ## The strip at the top of the window, in groups that wrap.
  let right = igGetCursorScreenPos().x + igGetContentRegionAvail().x
  var under: array[2, ImVec2_c] # below the Layers button and below the gear
  mu.stripGroup(0, right, 0):
    if button(IconLayers & "  Layers##layers", marks, "map.layers"):
      igOpenPopup_Str(layersId, 0)
    under[0] = ImVec2_c(x: igGetItemRectMin().x, y: igGetItemRectMax().y)
    tip("Show or hide each group of layers and each layer: the Preplot (the survey " &
      "files' sources and receivers), the Recorded (the seismic files' own positions), " &
      "the highlight")
  mu.stripGroup(1, right, 14):
    if button(IconZoomOut & "##zoomout", marks, "map.zoom out"): ask = maZoomOut
    tip("Zoom out (-, or the wheel)")
    igSameLine(0, 2)
    if button(IconZoomIn & "##zoomin", marks, "map.zoom in"): ask = maZoomIn
    tip("Zoom in (+, or the wheel)")
    igSameLine(0, 2)
    if button(IconFit & "##fit", marks, "map.fit"): ask = maFit
    tip("Fit all: the whole survey (Ctrl+0)")
    igSameLine(0, 2)
    igBeginDisabled(st.map.back.len == 0)
    if button(IconPrevious & "##back", marks, "map.back"):
      res.commands.add Command(kind: ckMapBack)
    igEndDisabled()
    tip("Back to the view before (Backspace, Alt+Left)")
  mu.stripGroup(2, right, 14):
    let on = mu.ruler.on
    if on:
      igPushStyleColor_Vec4(ImGui_Col_Button.cint, vec4(t.roles[rlSelection]))
      igPushStyleColor_Vec4(ImGui_Col_ButtonHovered.cint, vec4(t.roles[rlHover]))
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlAccent]))
    if button(IconRuler & "  Ruler##ruler", marks, "map.ruler button"):
      mu.ruler.clickRuler()
      if not mu.ruler.on: mu.rulerText = ""
    if on: igPopStyleColor(3)
    tip("Ruler (on/off): drag on the map to measure a distance and bearing, in " &
      lengthUnitName(st.shownLengths.unit) & ". Ctrl+drag measures and turns it on. " &
      "Clicking it while it is on takes the line away.")
  mu.stripGroup(3, right, 14):
    if button(IconSettings & "##more", marks, "map.more"): igOpenPopup_Str(moreId, 0)
    under[1] = ImVec2_c(x: igGetItemRectMin().x, y: igGetItemRectMax().y)
    tip("Where the map describes the point under the pointer, and the unit of its lengths")
  placePopover(under[0], layersWidth(layers, noiseLines(st)))
  if igBeginPopup(layersId, 0):
    mu.drawLayers(st, layers, marks, res, mu.hits, t)
    igEndPopup()
  placePopover(under[1], widest(["In US survey feet (ftUS: 1200/3937 m)",
    "As the survey gives them (US survey feet, ftUS)", "In a strip along the map's bottom"]))
  if igBeginPopup(moreId, 0):
    igSeparatorText("The point under the pointer")
    let now = st.settings.map.info
    for (m, label) in [(miPopup, "In a popup beside the pointer"),
        (miStrip, "In a strip along the map's bottom")]:
      if igRadioButton_Bool(label.cstring, now == m) and now != m:
        var s = st.settings
        s.map.info = m
        res.commands.add Command(kind: ckSettings, settings: s)
      marks.mark("map.more." & $m)
      tip(if m == miPopup: "Describe the point in a popup beside the pointer"
          else: "Describe the point in a strip along the map's bottom")
    igSeparatorText("Lengths (the scale bar, the ruler)")
    let u = st.surveyUnit
    let convertible = not metresPerUnit(u).isNaN
    let own = if u == suNotGiven: "not given" else: $u & ", " & u.abbreviation
    for (m, label) in [(dlSurvey, "As the survey gives them (" & own & ")"),
        (dlMetres, "In metres (m)"), (dlFeet, "In feet (ft: 0.3048 m)"),
        (dlUsFeet, "In US survey feet (ftUS: 1200/3937 m)")]:
      igBeginDisabled(m != dlSurvey and not convertible)
      let now = st.settings.map.lengths
      if igRadioButton_Bool(label.cstring, now == m) and now != m:
        var s = st.settings
        s.map.lengths = m
        res.commands.add Command(kind: ckSettings, settings: s)
      igEndDisabled()
      marks.mark("map.more." & $m)
      if m != dlSurvey and not convertible and igIsItemHovered(
          ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
        igTextUnformatted("Nothing says what the survey's unit is, so lengths cannot be " &
          "converted (the scale bar says \"units\")", nil)
        igEndTooltip()
      elif igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
        igTextUnformatted("The unit of the scale bar, the ruler and the lengths read out", nil)
        igEndTooltip()
    igEndPopup()

func clampTo(p: ImVec2_c; r: Rect): ImVec2_c =
  ImVec2_c(x: clamp(p.x, r.pos.x, r.pos.x + r.size.x), y: clamp(p.y, r.pos.y, r.pos.y + r.size.y))

func v2(p: ImVec2_c): Vec2 {.inline.} = vec2(p.x, p.y)

proc drawBox(a, b: ImVec2_c; c: Rgba) =
  let dl = igGetWindowDrawList()
  let (lo, hi) = (ImVec2_c(x: min(a.x, b.x), y: min(a.y, b.y)),
    ImVec2_c(x: max(a.x, b.x), y: max(a.y, b.y)))
  ImDrawList_AddRectFilled(dl, lo, hi, u32(withAlpha(c, 40)), 0, 0)
  ImDrawList_AddRect(dl, lo, hi, u32(c), 0, 1.5, 0)

proc selectBox(st: AppState; view: MapView; plot: Rect; a, b: ImVec2_c; adding: bool;
    res: var MapOutput) =
  ## Selects the points of the shown layers in the box from `a` to `b`, and
  ## their traces.
  let (p, q) = (view.mapAt(plot, v2(a)), view.mapAt(plot, v2(b)))
  let box = Bounds(minX: min(p.x, q.x), minY: min(p.y, q.y), maxX: max(p.x, q.x),
    maxY: max(p.y, q.y))
  res.commands.add Command(kind: ckSelectPoints, points: st.pointsIn(box),
    pointMode: (if adding: smAdd else: smReplace))

proc sendHover(mu: var MapUi; res: var MapOutput) =
  ## The points under the pointer to `core` when they change (none: off
  ## every point), so the plot lights up the traces recorded there.
  if mu.hovered != mu.sentHover:
    mu.sentHover = mu.hovered
    res.commands.add Command(kind: ckHoverPoints, points: mu.sentHover)

proc handleMouse(mu: var MapUi; st: AppState; after: var MapView; view: MapView; plot: Rect;
    lim: MapLimits; hovered, held: bool; t: Theme; remember, menu: var bool; click: var int;
    res: var MapOutput) =
  ## The wheel and the buttons over the map (the invisible button just drawn
  ## over it). A left press released where it went down is a click: `click`
  ## 1, 2 with Ctrl, 3 with Shift. A right press on the map while its menu is
  ## open (`held`), which closes the menu, starts a right click there too, as
  ## on a desktop: released where it went down, the menu opens again there.
  let io = igGetIO_Nil()
  let mouse = io.MousePos
  # Equal aspect always: Ctrl, Shift and the sideways wheel zoom nothing.
  if hovered and io.MouseWheel != 0 and not io.KeyCtrl and not io.KeyShift:
    after = after.zoomedMap(pow(WheelStep, float64(io.MouseWheel)), view.mapAt(plot,
      v2(mouse)), lim)
    if mu.burst(mgWheel): remember = true
    if mu.drag.kind == mdPan: # go on dragging from here
      mu.drag.start = after
      mu.drag.press = mouse
  if igIsItemActivated():
    for b in [ImGui_MouseButton_Left, ImGui_MouseButton_Middle, ImGui_MouseButton_Right]:
      if mu.drag.kind == mdNone and igIsMouseClicked_Bool(b.cint, false):
        let kind = if b == ImGui_MouseButton_Right: mdZoom
                   elif b == ImGui_MouseButton_Middle: mdPan
                    elif io.KeyShift: mdSelect
                    elif io.KeyCtrl or mu.ruler.on: mdMeasure
                    else: mdPan
        mu.drag = MapDrag(kind: kind, button: b.cint, press: mouse, start: after,
          adding: io.KeyCtrl and io.KeyShift)
  elif held and mu.drag.kind == mdNone and
      igIsMouseClicked_Bool(ImGui_MouseButton_Right.cint, false) and
      igIsItemHovered(ImGui_HoveredFlags_AllowWhenBlockedByPopup.cint):
    mu.drag = MapDrag(kind: mdZoom, button: ImGui_MouseButton_Right.cint, press: mouse,
      start: after)
  if mu.drag.kind == mdNone: return
  let moved = vec2(mouse.x - mu.drag.press.x, mouse.y - mu.drag.press.y)
  if not mu.drag.moved and max(abs(moved.x), abs(moved.y)) > io.MouseDragThreshold:
    mu.drag.moved = true
    if mu.drag.kind == mdPan:
      remember = true
      mu.gesture = mgNone
  let down = igIsMouseDown_Nil(mu.drag.button)
  let (a, b) = (clampTo(mu.drag.press, plot), clampTo(mouse, plot))
  case mu.drag.kind
  of mdNone: discard
  of mdPan:
    if mu.drag.moved:
      after = draggedMap(mu.drag.start, plot, moved, lim)
      igSetMouseCursor(ImGui_MouseCursor_ResizeAll.cint)
    if not down:
      if not mu.drag.moved and mu.drag.button == ImGui_MouseButton_Left.cint and hovered and
          mu.focus.acts:
        click = if io.KeyCtrl: 2 else: 1 # the click that brings the window forward: nothing
      mu.drag = MapDrag()
  of mdZoom:
    if mu.drag.moved and down: drawBox(a, b, t.roles[rlAccent])
    if not down:
      if mu.drag.moved:
        if abs(a.x - b.x) >= boxMinPixels and abs(a.y - b.y) >= boxMinPixels:
          after = view.boxedMap(view.mapAt(plot, v2(a)), view.mapAt(plot, v2(b)), lim)
          remember = true
          mu.gesture = mgNone
      elif hovered:
        menu = true # a right click: the menu
      mu.drag = MapDrag()
  of mdSelect:
    if mu.drag.moved and down: drawBox(a, b, t.roles[rlHighlight])
    if not down:
      if mu.drag.moved and abs(a.x - b.x) >= boxMinPixels and abs(a.y - b.y) >= boxMinPixels:
        selectBox(st, view, plot, a, b, mu.drag.adding, res)
      elif not mu.drag.moved and hovered and mu.focus.acts:
        click = 3 # Shift + click: a range along the line
      mu.drag = MapDrag()
  of mdMeasure:
    if mu.drag.moved:
      mu.ruler.placeRuler(view.mapAt(plot, v2(mu.drag.press)), view.mapAt(plot, v2(b)))
    if not down:
      if not mu.drag.moved and hovered and mu.focus.acts:
        # Ctrl + click adds; a click with the Ruler on, and no drag, selects
        click = if io.KeyCtrl: 2 else: 1
      mu.drag = MapDrag()

proc handleKeys(mu: var MapUi; st: AppState; after: var MapView; view: MapView; plot: Rect;
    lim: MapLimits; hovered: bool; remember: var bool; res: var MapOutput) =
  ## The map's keys, while its window has the focus (docs/plot-window.md).
  let io = igGetIO_Nil()
  if io.WantTextInput: return
  template held(chord: cint): bool = igShortcut_Nil(chord, ImGui_InputFlags_Repeat.cint)
  template once(chord: cint): bool = igShortcut_Nil(chord, 0)
  const
    ctrl = ImGui_Mod_Ctrl.cint
    shift = ImGui_Mod_Shift.cint
    alt = ImGui_Mod_Alt.cint
  let zoomIn = held(ImGui_Key_Equal.cint) or held(shift or ImGui_Key_Equal.cint) or
    held(ImGui_Key_KeypadAdd.cint)
  let zoomOut = held(ImGui_Key_Minus.cint) or held(ImGui_Key_KeypadSubtract.cint)
  let at = if hovered: view.mapAt(plot, v2(io.MousePos)) else: after.centre
  if zoomIn: after = after.zoomedMap(KeyStep, at, lim)
  if zoomOut: after = after.zoomedMap(1 / KeyStep, at, lim)
  if (zoomIn or zoomOut) and mu.burst(mgKeyZoom): remember = true
  var fx, fy = 0.0
  for (key, dx, dy) in [(ImGui_Key_LeftArrow, -1.0, 0.0), (ImGui_Key_RightArrow, 1.0, 0.0),
      (ImGui_Key_UpArrow, 0.0, 1.0), (ImGui_Key_DownArrow, 0.0, -1.0)]:
    if held(key.cint):
      fx += dx * PanStep
      fy += dy * PanStep
    if held(shift or key.cint):
      fx += dx
      fy += dy
  if fx != 0 or fy != 0:
    after = after.steppedMap(fx, fy, lim)
    if mu.burst(mgKeyPan): remember = true
  if once(ctrl or ImGui_Key_0.cint) or once(ctrl or ImGui_Key_Keypad0.cint):
    after = fitMap(lim, after.columns, after.rows)
    remember = true
    mu.gesture = mgNone
  if once(ImGui_Key_Backspace.cint) or once(alt or ImGui_Key_LeftArrow.cint):
    res.commands.add Command(kind: ckMapBack)
  if once(ImGui_Key_Escape.cint): # innermost first: a drag, the ruler, the selection
    if mu.drag.kind != mdNone:
      if mu.drag.kind == mdPan and mu.drag.moved: after = mu.drag.start
      if mu.drag.kind == mdMeasure: mu.ruler.endRulerLine()
      mu.drag = MapDrag()
    elif mu.ruler.shown: mu.ruler.endRulerLine()
    elif st.selection.anySelected or st.selection.points.len > 0:
      res.commands.add Command(kind: ckClearSelection)

func shownAt(st: AppState; p: PointRef): MapPoint =
  ## Where point `p` is drawn: NaN (not drawn) while its layer or its
  ## layer's group is hidden, so the highlight of a hidden layer is hidden
  ## too.
  let i = st.survey.find(p.layer)
  if i >= 0 and st.layerShown(st.survey.layers[i], p.role): st.positionOf(p)
  else: mapPoint(NaN, NaN)

proc addShownAt(dst: var seq[MapPoint]; st: AppState; points: openArray[PointRef]) =
  ## `shownAt` of each of `points`, its layer looked up once for a run of
  ## points of one layer (a box of half a million points looked each up
  ## twice).
  dst.setLen 0
  if dst.capacity < points.len: dst = newSeqOfCap[MapPoint](points.len)
  var last = (NoSurveyLayer, -1)
  var shown: array[PointRole, bool]
  for p in points:
    if p.layer != last[0]:
      last = (p.layer, st.survey.find(p.layer))
      if last[1] >= 0:
        for r in PointRole: shown[r] = st.layerShown(st.survey.layers[last[1]], r)
    let i = last[1]
    if i >= 0 and shown[p.role] and p.point in 0 ..< st.survey.layers[i].points[p.role].len:
      let ix = addr st.survey.layers[i].points[p.role].index
      dst.add mapPoint(ix[].x(p.point), ix[].y(p.point))
    else: dst.add mapPoint(NaN, NaN)

const ThinAbove = 50_000
  ## more selected points than this are drawn one a cell of about a pixel
  ## and a half: half a million highlighted discs took llvmpipe 100-250 ms a
  ## drawing

proc followHighlight(mu: var MapUi; st: AppState; view: MapView; hidden: bool) =
  ## The highlighted points on the GPU: the gather on show's, the
  ## selection's, the plot's hovered trace's and the map's own hover, each
  ## found again (with where they are) only when what it comes from changes,
  ## so a hover finds its own few points alone; uploaded when one changed.
  ## Points of a hidden layer are not drawn. `view`: the view drawn this
  ## frame.
  let visible = (st.map.hidden, st.settings.map.hiddenGroups)
  var changed = mu.highlightRev == 0 or hidden != mu.drawnHidden or visible != mu.visibleFor
  if visible != mu.visibleFor:
    mu.visibleFor = visible
    mu.selectedFor = (-1, -1) # where the points are drawn, found again
    mu.activeFor.survey = -1
  let selected = (st.selection.selectedRevision, st.survey.revision)
  if selected != mu.selectedFor:
    mu.highlight = st.highlightOf
    mu.selectedAt.addShownAt(st, mu.highlight.selected)
    mu.selectedFor = selected
    mu.thin = ThinArea() # thinned again below
    mu.drawnAll = false
    changed = true
  # Many points selected: those round the view drawn about one a pixel and
  # a half at this scale, thinned again when the view leaves that area or
  # its scale changes by half or more (one pass over the points and a
  # bitmap of the area's cells: a few milliseconds for 842 000 points).
  if mu.selectedAt.len > ThinAbove and view.isSet:
    if not mu.thin.thinFits(view):
      let b = st.survey.bounds
      mu.thin = thinArea(view, if b.isEmpty: mapPoint(0, 0) else: mapPoint(b.minX, b.minY))
      mu.selectedDrawn.thinned(mu.selectedAt, mu.thin, mu.thinTaken)
      mu.drawnAll = false
      changed = true
  elif not mu.drawnAll:
    mu.selectedDrawn = mu.selectedAt
    mu.thin = ThinArea()
    mu.drawnAll = true
    changed = true
  let active = (st.selection.activeGather, st.survey.revision)
  if active != mu.activeFor:
    mu.active = st.activePoints
    for r in PointRole:
      mu.activeAt[r].setLen 0
      for p in mu.active[r]: mu.activeAt[r].add st.shownAt(p)
    mu.activeFor = active
    changed = true
  if st.selection.hoverAt != mu.drawnPlotHover:
    mu.drawnPlotHover = st.selection.hoverAt
    changed = true
  if mu.hovered != mu.drawnHover:
    mu.drawnHover = mu.hovered
    changed = true
  if changed:
    var hovered: seq[MapPoint]
    for p in mu.drawnPlotHover: hovered.add st.shownAt(p)
    for p in mu.hovered: hovered.add st.positionOf(p)
    let b = st.survey.bounds
    let origin = if b.isEmpty: mapPoint(0, 0) else: mapPoint(b.minX, b.minY)
    if hidden:
      var none: array[PointRole, seq[MapPoint]]
      mu.renderer.setHighlight(origin, none, [], [])
    else: mu.renderer.setHighlight(origin, mu.activeAt, mu.selectedDrawn, hovered)
    mu.drawnHidden = hidden
    inc mu.highlightRev

proc followMarks(mu: var MapUi; st: AppState) =
  ## The marked points on the GPU: the survey's sources whose record is in a
  ## file of the folder listed (while the Recorded group and its tick are
  ## on, and the source's layer is drawn), then what each filter shown
  ## found (`filterHits`, in `MapFilter`'s order); found again and uploaded
  ## only when what they come from changes.
  let on = st.settings.map.folderShots and mgRecorded notin st.settings.map.hiddenGroups
  let k = st.findPanel(MainPanel)
  let edits = if k >= 0: st.editsOf(k).revision else: 0
  let now = (st.shots.revision, st.survey.revision, on, st.map.hidden,
    st.settings.map.hiddenGroups, st.settings.map.filters, st.recordQc.revision,
    st.spreads.revision, edits, st.selection.activeGather)
  if now == mu.marksFor and mu.marksRev > 0: return
  mu.marksFor = now
  mu.marked.setLen 1
  mu.marked[0].setLen 0
  if on:
    for p in st.shots.pointRefs: mu.marked[0].add st.shownAt(p)
  mu.hits = st.filterHits
  mu.hitIndex = filterIndex(mu.hits)
  mu.markSpots.setLen 0
  mu.nearFound = MarksNear()
  reset mu.markCounts
  for f in MapFilter:
    if f in st.settings.map.filters:
      # one glyph a place, however many things it marks there (a station
      # with 5 000 dead traces: one mark, its count in the hover)
      let places = st.filterPlaces(f, mu.hits[f])
      let spots = markSpots(places)
      mu.marked.add spots.positions
      mu.markCounts[f] = (places.len, spots.spots.len)
      mu.markSpots.add (f, spots)
  let b = st.survey.bounds
  mu.renderer.setMarks(if b.isEmpty: mapPoint(0, 0) else: mapPoint(b.minX, b.minY), mu.marked)
  inc mu.marksRev

proc drawScaleBar(mu: var MapUi; view: MapView; pos, size: ImVec2_c; fb: float32;
    lengths: tuple[unit: SurveyUnit; factor: float64]; ink: MapInk; t: Theme;
    marks: var Marks): tuple[lo, hi: ImVec2_c] =
  ## The scale bar in the plot's bottom-left corner, in the unit the map
  ## states lengths in (`shownLengths`), and a north arrow in its top-right one.
  ## Returns the bar's box (empty when there is none).
  let bar = scaleBar(view.perPixel * lengths.factor, float64(scalePixels * fb))
  mu.scaleText = ""
  mu.scale = bar
  if bar.length <= 0: return
  let dl = igGetWindowDrawList()
  let px = float32(bar.pixels) / fb # ImGui pixels
  let text = lengthText(bar.length, lengths.unit.abbreviation)
  mu.scaleText = text
  let ts = igCalcTextSize(text.cstring, nil, false, -1)
  let pad = 6'f32
  let lo = ImVec2_c(x: pos.x + 10, y: pos.y + size.y - 10 - ts.y - 14)
  let hi = ImVec2_c(x: lo.x + max(px, ts.x) + 2 * pad, y: pos.y + size.y - 10)
  ImDrawList_AddRectFilled(dl, lo, hi, u32(withAlpha(ink.background, 210)), 3, 0)
  let y = hi.y - pad - 2
  let (x0, x1) = (lo.x + pad, lo.x + pad + px)
  let c = u32(ink.outline)
  ImDrawList_AddLine(dl, ImVec2_c(x: x0, y: y), ImVec2_c(x: x1, y: y), c, 2)
  for x in [x0, (x0 + x1) / 2, x1]:
    ImDrawList_AddLine(dl, ImVec2_c(x: x, y: y - (if x == (x0 + x1) / 2: 3 else: 6)),
      ImVec2_c(x: x, y: y), c, 1.5)
  ImDrawList_AddText_Vec2(dl, ImVec2_c(x: lo.x + pad, y: lo.y + 2), c, text.cstring, nil)
  marks.markRect("map.scale bar", lo, hi)
  result = (lo, hi)
  # north: grid north is up
  let n = ImVec2_c(x: pos.x + size.x - 22, y: pos.y + 12)
  ImDrawList_AddTriangleFilled(dl, ImVec2_c(x: n.x, y: n.y), ImVec2_c(x: n.x - 6, y: n.y + 16),
    ImVec2_c(x: n.x + 6, y: n.y + 16), c)
  let nt = igCalcTextSize("N", nil, false, -1)
  ImDrawList_AddText_Vec2(dl, ImVec2_c(x: n.x - nt.x / 2, y: n.y + 18), c, "N", nil)
  marks.markRect("map.north", ImVec2_c(x: n.x - 7, y: n.y), ImVec2_c(x: n.x + 7,
    y: n.y + 18 + nt.y))

proc drawRuler(mu: var MapUi; view: MapView; plot: Rect;
    lengths: tuple[unit: SurveyUnit; factor: float64]; ink: MapInk; t: Theme;
    marks: var Marks) =
  ## The distance measured, from its first point to its second, with its
  ## length and grid bearing beside it.
  mu.rulerText = ""
  if not mu.ruler.on or not mu.ruler.shown: return
  let (a, b) = (view.screenAt(plot, mu.ruler.a), view.screenAt(plot, mu.ruler.b))
  let dl = igGetWindowDrawList()
  let (pa, pb) = (ImVec2_c(x: a.x, y: a.y), ImVec2_c(x: b.x, y: b.y))
  let c = u32(t.roles[rlAccent])
  ImDrawList_AddLine(dl, pa, pb, u32(ink.background), 4)
  ImDrawList_AddLine(dl, pa, pb, c, 2)
  ImDrawList_AddCircleFilled(dl, pa, 3.5, c, 12)
  ImDrawList_AddCircleFilled(dl, pb, 3.5, c, 12)
  let d = distance(mu.ruler.a, mu.ruler.b)
  let br = bearing(mu.ruler.a, mu.ruler.b)
  mu.rulerText = rulerReading(d, lengths) & (if br.isNaN: ""
    else: ", bearing " & align(formatFloat(br, ffDecimal, 1), 5, '0') & "°")
  let ts = igCalcTextSize(mu.rulerText.cstring, nil, false, -1)
  let pad = igGetStyle().FramePadding
  # beside the line's middle, inside the plot
  let at = ImVec2_c(x: clamp((pa.x + pb.x) / 2 + 8, plot.pos.x + pad.x,
    max(plot.pos.x + pad.x, plot.pos.x + plot.size.x - ts.x - pad.x)),
    y: clamp((pa.y + pb.y) / 2 - ts.y - 6, plot.pos.y + pad.y,
    max(plot.pos.y + pad.y, plot.pos.y + plot.size.y - ts.y - pad.y)))
  let lo = ImVec2_c(x: at.x - pad.x, y: at.y - pad.y)
  let hi = ImVec2_c(x: at.x + ts.x + pad.x, y: at.y + ts.y + pad.y)
  ImDrawList_AddRectFilled(dl, lo, hi, u32(t.roles[rlPopup]), igGetStyle().FrameRounding, 0)
  ImDrawList_AddText_Vec2(dl, at, u32(t.roles[rlText]), mu.rulerText.cstring, nil)
  marks.markRect("map.ruler", lo, hi)

proc followSpreads(mu: var MapUi; st: AppState) =
  ## The spreads planned for the record on show and for the shot under the
  ## pointer (a source; in a file of receiver gathers, a receiver), found
  ## again only when what they come from changes.
  let on = st.settings.map.templateBox
  let domain = st.shownDomain
  let shown = (st.selection.activeGather, st.survey.revision, st.spreads.revision,
    st.recordQc.revision, domain, on)
  if shown != mu.spreadFor:
    mu.spreadFor = shown
    mu.spreadShown = if on: st.shownSpread else: PlannedSpread()
  let role = if domain == rdSource: prSource else: prReceiver
  var at = PointRef()
  var point = -1
  for p in mu.hovered:
    if point < 0 and p.role == role: (point, at) = (p.key, p)
  let hovered = (point, st.survey.revision, st.spreads.revision, domain, on)
  if hovered != mu.spreadHoverFor:
    mu.spreadHoverFor = hovered
    mu.spreadHovered = if on and point >= 0: st.spreadAt(at) else: PlannedSpread()

func spreadText(sp: PlannedSpread): string =
  ## What a template box says of itself: "X record 77: 1127 receivers
  ## planned", "Generated: 8 receivers planned".
  let what = if sp.domain == rdSource: "receiver" else: "shot"
  result = (if sp.generated: "Generated"
    elif sp.domain == rdSource: "X record " & $sp.record
    else: "O gather " & $sp.record) &
    (if sp.byPlace: " (by the " & (if sp.domain == rdSource: "source" else: "receiver") &
      " at its place)" else: "") & ": " & $sp.stations & " " & what &
    (if sp.stations == 1: "" else: "s") & " planned"
  if sp.unplaced > 0: result.add ", " & $sp.unplaced & " not on the map"

proc drawSpreadBox(mu: var MapUi; sp: PlannedSpread; view: MapView; plot: Rect; c: Rgba;
    ink: MapInk; t: Theme; name: string; below: bool; marks: var Marks) =
  ## The box round spread `sp`'s places, a few pixels outside them, in `c`,
  ## with what it is above its top corner (`below`: below its bottom one, so
  ## two boxes on one line of receivers do not write over each other);
  ## marked `name`.
  if not sp.box.shown: return
  var q: array[4, Vec2]
  for i in 0 .. 3: q[i] = view.screenAt(plot, sp.box.corners[i])
  func unit(a, b: Vec2): Vec2 =
    let n = hypot(b.x - a.x, b.y - a.y)
    if n > 0.5: vec2((b.x - a.x) / n, (b.y - a.y) / n) else: vec2(0, 0)
  var u = unit(q[0], q[1])
  var v = unit(q[0], q[3])
  if u.x == 0 and u.y == 0: u = if v.x == 0 and v.y == 0: vec2(1, 0) else: vec2(-v.y, v.x)
  if v.x == 0 and v.y == 0: v = vec2(-u.y, u.x)
  const pad = 7'f32
  let su = [-1'f32, 1, 1, -1]
  let sv = [-1'f32, -1, 1, 1]
  var e: array[4, ImVec2_c]
  var lo = ImVec2_c(x: Inf, y: Inf)
  var hi = ImVec2_c(x: -Inf, y: -Inf)
  var top = 0
  for i in 0 .. 3:
    e[i] = ImVec2_c(x: q[i].x + pad * (su[i] * u.x + sv[i] * v.x),
      y: q[i].y + pad * (su[i] * u.y + sv[i] * v.y))
    lo = ImVec2_c(x: min(lo.x, e[i].x), y: min(lo.y, e[i].y))
    hi = ImVec2_c(x: max(hi.x, e[i].x), y: max(hi.y, e[i].y))
    let higher = if below: e[i].y > e[top].y else: e[i].y < e[top].y
    if higher or (e[i].y == e[top].y and e[i].x < e[top].x): top = i
  let dl = igGetWindowDrawList()
  for i in 0 .. 3:
    ImDrawList_AddLine(dl, e[i], e[(i + 1) mod 4], u32(withAlpha(ink.background, 200)), 4)
  for i in 0 .. 3:
    ImDrawList_AddLine(dl, e[i], e[(i + 1) mod 4], u32(c), 1.6)
  let text = spreadText(sp)
  let ts = igCalcTextSize(text.cstring, nil, false, -1)
  let y = if below: e[top].y + 3 else: e[top].y - ts.y - 3
  let at = ImVec2_c(x: clamp(e[top].x, plot.pos.x + 2, max(plot.pos.x + 2,
    plot.pos.x + plot.size.x - ts.x - 2)), y: clamp(y, plot.pos.y + 2,
    max(plot.pos.y + 2, plot.pos.y + plot.size.y - ts.y - 2)))
  ImDrawList_AddRectFilled(dl, ImVec2_c(x: at.x - 3, y: at.y - 1), ImVec2_c(x: at.x + ts.x + 3,
    y: at.y + ts.y + 1), u32(withAlpha(ink.background, 215)), 2, 0)
  ImDrawList_AddText_Vec2(dl, at, u32(c), text.cstring, nil)
  marks.markRect(name, lo, hi)
  var drawn: array[4, Vec2]
  for i in 0 .. 3: drawn[i] = vec2(e[i].x, e[i].y)
  mu.boxes.add (name, drawn)

proc drawSpreads(mu: var MapUi; view: MapView; plot: Rect; ink: MapInk; t: Theme;
    marks: var Marks) =
  ## The template boxes: the record on show's in the outline colour, the
  ## shot under the pointer's in the hover colour.
  mu.boxes.setLen 0
  mu.drawSpreadBox(mu.spreadShown, view, plot, ink.outline, ink, t, "map.template shown",
    false, marks)
  if mu.spreadHovered.record != mu.spreadShown.record or
      mu.spreadHovered.generated != mu.spreadShown.generated:
    mu.drawSpreadBox(mu.spreadHovered, view, plot, ink.hover, ink, t, "map.template hovered",
      true, marks)

func overlaps(a, b: Rect): bool =
  a.pos.x < b.pos.x + b.size.x and b.pos.x < a.pos.x + a.size.x and
    a.pos.y < b.pos.y + b.size.y and b.pos.y < a.pos.y + a.size.y

proc textWidth(text: string): float32 =
  igCalcTextSize(text.cstring, nil, false, -1).x

proc wrapped(text: string; width: float32): seq[string] =
  ## `text` broken at its spaces into lines no wider than `width` (a word wider
  ## than that is broken between letters).
  var line = ""
  for word in text.split(' '):
    let joined = if line.len == 0: word else: line & " " & word
    if line.len == 0 or joined.textWidth <= width:
      line = joined
    else:
      result.add line
      line = word
    while line.textWidth > width and line.len > 1:
      var n = line.len - 1
      while n > 1 and line[0 ..< n].textWidth > width: dec n
      result.add line[0 ..< n]
      line = line[n .. ^1]
  result.add line

proc drawInfoBox(info: openArray[PointInfo]; at: ImVec2_c; plotPos, plotSize: ImVec2_c;
    t: Theme; marks: var Marks; menu = Rect()) =
  ## What the map says of the points under the pointer, in a box beside the
  ## pointer, kept inside the plot (drawn in the window, not as a window of
  ## its own: a tooltip past the main window's edge would become a window of
  ## its own and take the keyboard focus from the map). With the right-click
  ## `menu` open (its area, not empty), on a side of the pointer where the
  ## menu does not cover it, if the plot has room there.
  var all: seq[(string, bool)] # text, a title
  for i in info.merged:
    if i.title.len > 0: all.add (i.title, true)
    for l in i.lines: all.add (l, false)
  let pad = igGetStyle().WindowPadding
  let lineH = igGetTextLineHeightWithSpacing()
  type Box = object
    rows: seq[(string, bool)]
    size, lo: ImVec2_c
    clear: bool ## inside the bounds and not covering the pointer
  proc layout(bpos, bsize: ImVec2_c): Box =
    # lines wider than the bounds are broken at their spaces
    let room = max(bsize.x - 2 * pad.x - 2, 1'f32)
    var w = 0'f32
    for (text, title) in all:
      for part in text.wrapped(room):
        result.rows.add (part, title)
        w = max(w, part.textWidth)
    result.size = ImVec2_c(x: w + 2 * pad.x, y: float32(result.rows.len) * lineH + 2 * pad.y -
      igGetStyle().ItemSpacing.y)
    let size = result.size
    var lo = ImVec2_c(x: at.x + 18, y: at.y + 18)
    if lo.x + size.x > bpos.x + bsize.x: lo.x = at.x - 18 - size.x
    if lo.y + size.y > bpos.y + bsize.y: lo.y = at.y - 18 - size.y
    lo = ImVec2_c(x: max(lo.x, bpos.x), y: max(lo.y, bpos.y))
    let covers = at.x >= lo.x and at.x <= lo.x + size.x and at.y >= lo.y and
      at.y <= lo.y + size.y
    if covers:
      # a box as wide as a narrow bounds would cover the pointer: above or below it
      let x = clamp(at.x - size.x / 2, bpos.x, max(bpos.x, bpos.x + bsize.x - size.x))
      if at.y + 18 + size.y <= bpos.y + bsize.y: lo = ImVec2_c(x: x, y: at.y + 18)
      elif at.y - 18 - size.y >= bpos.y: lo = ImVec2_c(x: x, y: at.y - 18 - size.y)
    result.lo = lo
    result.clear = lo.x >= bpos.x and lo.y >= bpos.y and lo.x + size.x <= bpos.x + bsize.x and
      lo.y + size.y <= bpos.y + bsize.y and not (at.x >= lo.x and at.x <= lo.x + size.x and
      at.y >= lo.y and at.y <= lo.y + size.y)
  var box = layout(plotPos, plotSize)
  var dl = igGetWindowDrawList()
  if not box.clear and menu.size.x <= 0:
    # A plot too small for it (a map docked narrow): over what lies beside the
    # map, kept inside the window.
    let vp = igGetMainViewport()
    let other = layout(vp.Pos, vp.Size)
    if other.clear:
      box = other
      dl = igGetForegroundDrawList_ViewportPtr(vp)
  let (rows, size) = (box.rows, box.size)
  var lo = box.lo
  if menu.size.x > 0:
    # Beside the pointer, beside the menu, or above or below it, kept inside
    # the plot (a box wider than the plot from its left edge, cut there).
    let plot = Rect(pos: vec2(plotPos.x, plotPos.y), size: vec2(plotSize.x, plotSize.y))
    let right = max(plot.pos.x, plot.pos.x + plot.size.x - size.x)
    for c in [vec2(at.x + 18, at.y + 18), vec2(at.x - 18 - size.x, at.y + 18),
        vec2(at.x + 18, at.y - 18 - size.y), vec2(at.x - 18 - size.x, at.y - 18 - size.y),
        vec2(menu.pos.x - 8 - size.x, menu.pos.y), vec2(menu.pos.x + menu.size.x + 8, menu.pos.y),
        vec2(at.x - size.x / 2, menu.pos.y + menu.size.y + 8),
        vec2(at.x - size.x / 2, menu.pos.y - 8 - size.y)]:
      let r = Rect(pos: vec2(clamp(c.x, plot.pos.x, right), c.y), size: vec2(size.x, size.y))
      if r.pos.y >= plot.pos.y and r.pos.y + r.size.y <= plot.pos.y + plot.size.y and
          not r.overlaps(menu):
        lo = ImVec2_c(x: r.pos.x, y: r.pos.y)
        break
  let hi = ImVec2_c(x: lo.x + size.x, y: lo.y + size.y)
  ImDrawList_AddRectFilled(dl, lo, hi, u32(t.roles[rlPopup]), igGetStyle().PopupRounding, 0)
  ImDrawList_AddRect(dl, lo, hi, u32(t.roles[rlBorder]), igGetStyle().PopupRounding, 1, 0)
  var y = lo.y + pad.y
  for (text, title) in rows:
    ImDrawList_AddText_Vec2(dl, ImVec2_c(x: lo.x + pad.x, y: y),
      u32(if title: t.roles[rlAccent] else: t.roles[rlText]), text.cstring, nil)
    y += lineH
  marks.markRect("map.info", lo, hi)

proc drawMenu(mu: var MapUi; st: AppState; marks: var Marks; res: var MapOutput) =
  ## The right-click menu: only what acts on the point under the pointer.
  mu.menuRect = Rect()
  if igBeginPopup(menuId, 0):
    marks.markWindow("map menu")
    let (at, size) = (igGetWindowPos(), igGetWindowSize())
    mu.menuRect = Rect(pos: vec2(at.x, at.y), size: vec2(size.x, size.y))
    if mu.menuPoints.len == 0:
      igTextDisabled("No point here")
    else:
      igTextDisabled("%s", mu.menuTitle.cstring)
      igSeparator()
      let traces = st.survey.tracesAt(mu.menuPoints).len # each once, as selected
      let selected = mu.menuPoints[0].key in st.selection.pointKeys
      var places: seq[ShotPlace] # the listed files that hold a source's shot
      for p in mu.menuPoints:
        if places.len == 0: places = st.shots.shotsAt(p)
      if mu.menuShows and traces > 0:
        if igMenuItem_Bool("Show its record", "Click", false, true):
          res.commands.add Command(kind: ckShowPoints, points: mu.menuPoints)
        marks.mark("map menu.show")
        tip("Show the record this point belongs to (Click)")
      # Each listed file that holds the shot; a click shows the first when no
      # open file has its traces.
      for k in 0 ..< min(places.len, menuShots):
        let label = "Show " & places[k].shotName & "##shot" & $k
        let key: cstring = if k == 0 and traces == 0: "Click" else: nil
        if igMenuItem_Bool(label.cstring, key, false, true):
          res.commands.add Command(kind: ckShowPoints, points: mu.menuPoints,
            shotPath: places[k].path)
        marks.mark(if k == 0 and traces == 0: "map menu.show" else: "map menu.shot " & $k)
        tip("Show this file's record of the shot")
      if places.len > menuShots:
        igTextDisabled("%s", ("... and " & $(places.len - menuShots) & " more").cstring)
      let what = if traces == 0: "Select it"
                 elif traces == 1: "Select it and its trace"
                 else: "Select it and its " & $traces & " traces"
      let key: cstring = if mu.menuShows: nil else: "Click"
      mu.menuSelect = what
      if igMenuItem_Bool(what.cstring, key, false, true):
        res.commands.add Command(kind: ckSelectPoints, points: mu.menuPoints,
          pointMode: smReplace)
      marks.mark("map menu.select")
      tip("Select this point, and its traces in the plot when it has them")
      let toggle = if selected: "Take it out of the selection" else: "Add it to the selection"
      if igMenuItem_Bool(toggle.cstring, "Ctrl+Click", false, true):
        res.commands.add Command(kind: ckSelectPoints, points: mu.menuPoints,
          pointMode: (if selected: smRemove else: smAdd))
      marks.mark("map menu.add")
      tip(if selected: "Take this point out of the selection (Ctrl+Click)"
          else: "Add this point to the selection (Ctrl+Click)")
      igSeparator()
      let i = st.survey.find(mu.menuPoints[0].layer)
      if i >= 0:
        let key = st.survey.layers[i].keyOf(mu.menuPoints[0].role)
        let name = roleWord(mu.menuPoints[0].role) & " of " & st.survey.layers[i].name
        if igMenuItem_Bool(("Hide the " & name).cstring, nil, false, true):
          res.commands.add Command(kind: ckMapLayer, mapLayer: key, shown: false)
        marks.mark("map menu.hide")
        tip("Hide this layer (show it again from Layers)")
    explainEntry("map.explain", marks)
    igEndPopup()

func markStyle(t: Theme; f: MapFilter; ink: MapInk; scale: float32): MapStyle =
  ## How filter `f`'s points are marked, at UI scale `scale`.
  let (family, symbol) = FilterMarks[f]
  MapStyle(colour: filterInk(t, f, ink.background), edge: ink.background,
    size: MarkSizes[family] * scale, edgeWidth: MarkStroke * scale, halo: MarkHalo * scale,
    glyph: Glyphs[FamilyShapes[family]], symbol: GlyphSymbol(ord(symbol)))

proc foldFrame(mu: var MapUi; st: AppState; area: Bounds; perPixel: float64): FoldDraw =
  ## What the fold layer draws for map area `area` at `perPixel` map units a
  ## framebuffer pixel: the level whose blocks are wide enough, uploaded when it
  ## changed, and the block rows the area touches.
  let r = mu.fold.shown
  if not mu.fold.showing or not st.settings.map.foldAny or
      mgPreplot in st.settings.map.hiddenGroups or r.counts.len == 0:
    return
  if mu.foldGrid.res != r or mu.foldFor != mu.fold.revision:
    mu.foldGrid = initFoldGrid(r)
    mu.foldFor = mu.fold.revision
  let factor = mu.foldGrid.factorFor(perPixel)
  r[].visibleSpans(factor, area, mu.foldSpans)
  let key = mu.fold.revision * 64 + factor.countTrailingZeroBits + 1
  let l = mu.foldGrid.level(factor)
  if mu.renderer.foldKey != key:
    mu.renderer.setFoldCells(key, l.cols, l.rows, l.colours)
  let named = mu.renderer.setFoldSpans(mu.foldSpans)
  FoldDraw(on: named.count > 0, key: key, x0: r.x0, y0: r.y0, azimuthDeg: r.azimuthDeg,
    binAlong: r.binAlong, binAcross: r.binAcross, crosslines: r.crosslines,
    inlines: r.inlines, factor: factor, cols: l.cols, rows: l.rows, spans: named.count,
    spansSum: named.sum)

proc drawFoldLegend(mu: var MapUi; pos, size: ImVec2_c; scale: tuple[lo, hi: ImVec2_c];
    unit: string; ink: MapInk; marks: var Marks) =
  ## The fold's colour bar in the plot's bottom-right corner: 0 to the highest fold, or for
  ## the difference the diverging bar from the most short of the plan to the most more than
  ## planned. Where it would cover the scale bar (`scale`, bottom-left: a narrow window) it
  ## stands above it.
  let r = mu.fold.shown
  mu.foldLegend = ""
  if not mu.fold.showing or mu.renderer.foldKey == 0: return
  let dl = igGetWindowDrawList()
  let diff = r.kind == fkDifference
  let title = r[].layerTitle(unit) & (if mu.fold.updating: " (updating...)" else: "")
  mu.foldLegend = title
  let top = if diff: $r.maxFold & " short" else: "0"
  let mid = if diff: "0" else: ""
  let high = if diff: $r.maxFold & " more" else: $r.maxFold
  let ts = igCalcTextSize(title.cstring, nil, false, -1)
  let hs = igCalcTextSize(high.cstring, nil, false, -1)
  let pad = 6'f32
  let barW = if diff: 150'f32 else: 110'f32
  let barH = 10'f32
  let w = max(barW, ts.x) + 2 * pad
  let h = ts.y + barH + hs.y + 2 * pad + 2
  var hi = ImVec2_c(x: pos.x + size.x - 10, y: pos.y + size.y - 10)
  if scale.hi.x > scale.lo.x and hi.x - w < scale.hi.x + 6:
    hi.y = scale.lo.y - 6 # beside it there is no room: above it
  let lo = ImVec2_c(x: hi.x - w, y: hi.y - h)
  ImDrawList_AddRectFilled(dl, lo, hi, u32(withAlpha(ink.background, 210)), 3, 0)
  let c = u32(ink.outline)
  ImDrawList_AddText_Vec2(dl, ImVec2_c(x: lo.x + pad, y: lo.y + pad), c, title.cstring, nil)
  let y0 = lo.y + pad + ts.y + 2
  let steps = 32
  for k in 0 ..< steps:
    let a = lo.x + pad + barW * float32(k) / float32(steps)
    let b = lo.x + pad + barW * float32(k + 1) / float32(steps)
    let t = (float64(k) + 0.5) / float64(steps)
    let col = if diff: diffLegendColour(t) else: legendColour(t)
    ImDrawList_AddRectFilled(dl, ImVec2_c(x: a, y: y0), ImVec2_c(x: b + 0.5, y: y0 + barH),
      u32(col), 0, 0)
  ImDrawList_AddRect(dl, ImVec2_c(x: lo.x + pad, y: y0), ImVec2_c(x: lo.x + pad + barW,
    y: y0 + barH), c, 0, 1, 0)
  ImDrawList_AddText_Vec2(dl, ImVec2_c(x: lo.x + pad, y: y0 + barH + 1), c, top.cstring, nil)
  if mid.len > 0:
    let ms = igCalcTextSize(mid.cstring, nil, false, -1)
    ImDrawList_AddText_Vec2(dl, ImVec2_c(x: lo.x + pad + (barW - ms.x) / 2, y: y0 + barH + 1),
      c, mid.cstring, nil)
  ImDrawList_AddText_Vec2(dl, ImVec2_c(x: lo.x + pad + barW - hs.x, y: y0 + barH + 1), c,
    high.cstring, nil)
  marks.markRect("map.fold legend", lo, hi)

proc drawPlot(mu: var MapUi; st: AppState; layers: openArray[MapLayerView]; ink: MapInk;
    t: Theme; marks: var Marks; res: var MapOutput; ask: MapAskKind) =
  ## The map's plot and the mouse and keys over it.
  let lim = st.map.limits
  var remember = false
  if mu.jumps != st.map.jumps: # back, a new survey: a drag does not undo it
    mu.cur = st.map.view
    mu.jumps = st.map.jumps
    mu.drag = MapDrag()
  var next = mu.cur
  if mu.want: # a view asked for from outside the window (agent control)
    next.centre = mu.wanted.centre
    if mu.wanted.perPixel > 0: next.perPixel = mu.wanted.perPixel
    next = keptMap(next, lim)
    mu.want = false
    remember = true
  case ask
  of maNone: discard
  of maFit:
    next = fitMap(lim, next.columns, next.rows)
    remember = true
    mu.gesture = mgNone
  of maZoomIn, maZoomOut:
    next = next.zoomedMap((if ask == maZoomIn: KeyStep else: 1 / KeyStep), next.centre, lim)
    if mu.burst(mgKeyZoom): remember = true
  let units = st.unitsOf # of coordinates
  let lengths = st.shownLengths # of the scale bar and the ruler
  let infoRows = if st.settings.map.info == miStrip: 2 else: 0
  let lineH = igGetTextLineHeightWithSpacing()
  let avail = igGetContentRegionAvail()
  ImPlot_PushStyleColor_Vec4(ImPlot_Col_PlotBg.cint, vec4(ink.background))
  const flags = ImPlot_Flags_NoTitle.cint or ImPlot_Flags_NoLegend.cint or
    ImPlot_Flags_NoMenus.cint or ImPlot_Flags_NoMouseText.cint or ImPlot_Flags_NoInputs.cint
  var menu = false
  let held = igIsPopupOpen_Str(menuId, 0) # the map's menu, opened by a right click
  let plotH = max(1'f32, avail.y - float32(infoRows) * lineH - (if infoRows > 0: 4 else: 0))
  if ImPlot_BeginPlot("##map", ImVec2_c(x: max(1, avail.x), y: plotH), flags):
    # No values, ticks or titles on the axes (the scale bar, the north arrow
    # and the status bar's coordinates say what is needed), so nothing sizes
    # the plot area from one frame to the next: it is the plot's from the first.
    const axis = ImPlot_AxisFlags_NoMenus.cint or ImPlot_AxisFlags_NoDecorations.cint
    ImPlot_SetupAxis(ImAxis_X1.cint, nil, axis)
    ImPlot_SetupAxis(ImAxis_Y1.cint, nil, axis)
    let b = lim.bounds
    let shown = if next.isSet: next.visible else: b
    ImPlot_SetupAxesLimits(shown.minX, shown.maxX, shown.minY, shown.maxY,
      ImPlot_Cond_Always.cint)
    ImPlot_SetupFinish()
    let limits = ImPlot_GetPlotLimits(ImAxis_X1.cint, ImAxis_Y1.cint)
    let pos = ImPlot_GetPlotPos()
    let size = ImPlot_GetPlotSize()
    let fb = igGetIO_Nil().DisplayFramebufferScale
    let (columns, rows) = (int(round(size.x * fb.x)), int(round(size.y * fb.y)))
    var view = next
    (view.columns, view.rows) = (columns, rows)
    marks.markRect("map.data", pos, ImVec2_c(x: pos.x + size.x, y: pos.y + size.y))
    let origin = igGetMainViewport().Pos # framebuffer pixels of the main window, as marks
    mu.plot = Rect(pos: vec2((pos.x - origin.x) * fb.x, (pos.y - origin.y) * fb.y),
      size: vec2(size.x * fb.x, size.y * fb.y))
    if mu.gpuError.len == 0 and mu.started and next.isSet:
      mu.followHighlight(st, view, not st.map.shown(HighlightKey))
      mu.followMarks(st)
      let s = fb.x
      var frame = MapFrame(area: Bounds(minX: limits.X.Min, minY: limits.Y.Min,
        maxX: limits.X.Max, maxY: limits.Y.Max), columns: columns, rows: rows,
        background: ink.background, highlight: mu.highlightRev, survey: st.survey.revision,
        active: [MapStyle(colour: ink.roles[prSource], edge: ink.outline,
          size: activeSourceSize * s, edgeWidth: s), MapStyle(colour: ink.active)],
        selected: MapStyle(colour: ink.selected, edge: ink.outline, size: selectedSize * s,
          edgeWidth: s),
        hovered: MapStyle(colour: ink.hover, edge: ink.outline, size: hoveredSize * s,
          edgeWidth: 1.5 * s))
      # The record's receivers a pixel larger than the receivers drawn, so
      # the spread darkens what is there and covers nothing else.
      let pixel = view.perPixel * float64(s) # survey units a pixel at 100 %
      var receivers = MinMarker
      for l in layers:
        if l.shown and l.key.kind != mlHighlight and l.role == prReceiver:
          receivers = max(receivers, markerSize(l.spacing, pixel))
      frame.active[prReceiver].size = (receivers + activeReceiverRoom) * s
      # A source with a file in the folder: ringed, a little outside its disc.
      var sources = MinMarker
      for l in layers:
        if l.shown and l.key.kind == mlSurveyFile and l.role == prSource:
          sources = max(sources, markerSize(l.spacing, pixel))
      frame.marks = @[MapStyle(colour: ink.outline, edge: ink.outline,
        size: (sources + shotRing) * s, edgeWidth: 1.5 * s, shape: skRing)]
      # A point a filter marks: its glyph (`FilterMarks`) in its kind's colour,
      # of a size on the screen that holds at every zoom, over the highlight,
      # with a halo of the background round it so it reads over the stations.
      frame.marksAbove = frame.marks.len
      for f in MapFilter: # (in the order `followMarks` gives their sets)
        if f in st.settings.map.filters: frame.marks.add markStyle(t, f, ink, s)
      frame.marked = mu.marksRev
      for l in layers:
        if l.shown and l.key.kind != mlHighlight:
          let disc = markerSize(l.spacing, pixel)
          let ring = ringSize(l.spacing, pixel)
          frame.draws.add MapDraw(layer: l.layer, role: l.role, style:
            if l.shape == msRing and ring >= MaxMarker:
              MapStyle(colour: l.colour, edge: l.colour, size: ring * s,
                edgeWidth: ringWidth * s, shape: skRing)
            elif l.shape == msRing: MapStyle(colour: l.colour, size: ring * s)
            elif l.shape == msDiamond:
              MapStyle(colour: l.colour, size: max(disc, DiamondMin) * s, shape: skDiamond)
            else: MapStyle(colour: l.colour, size: disc * s))
      frame.fold = mu.foldFrame(st, frame.area, (limits.X.Max - limits.X.Min) / float64(columns))
      let tex = mu.renderer.render(frame, st.survey)
      if tex != 0:
        ImPlot_PlotImage("##points", ImTextureRef_c(internal_TexID: ImTextureID(tex)),
          ImPlotPoint_c(x: limits.X.Min, y: limits.Y.Min),
          ImPlotPoint_c(x: limits.X.Max, y: limits.Y.Max),
          # ImPlot puts uv0 at (x min, y max), the top: the image's last row, north
          ImVec2_c(x: 0, y: 1), ImVec2_c(x: 1, y: 0), ImVec4_c(x: 1, y: 1, z: 1, w: 1),
          ImPlot_ItemFlags_NoFit.cint)
    ImPlot_EndPlot()
    let plot = Rect(pos: vec2(pos.x, pos.y), size: vec2(size.x, size.y))
    igSetCursorScreenPos(pos)
    discard igInvisibleButton("##mapinput", size, ImGui_ButtonFlags_MouseButtonLeft.cint or
      ImGui_ButtonFlags_MouseButtonRight.cint or ImGui_ButtonFlags_MouseButtonMiddle.cint)
    let hovered = igIsItemHovered(0)
    # A new plot size keeps the scale from the top left, but a map that shows
    # the whole survey goes on showing all of it (a map has no scroll bars to
    # reach what a smaller plot would cut off); a view never set fits.
    var after = if not next.isSet: fitMap(lim, columns, rows)
      elif columns == next.columns and rows == next.rows: view
      elif next.showsAll(lim): fitMap(lim, columns, rows)
      else: next.resizedMap(columns, rows, lim)
    let dl = igGetWindowDrawList()
    ImDrawList_PushClipRect(dl, pos, ImVec2_c(x: pos.x + size.x, y: pos.y + size.y), true)
    var click = 0
    mu.handleMouse(st, after, view, plot, lim, hovered, held, t, remember, menu, click, res)
    mu.handleKeys(st, after, view, plot, lim, hovered, remember, res)
    # The point under the pointer, and what the map says of it. While the
    # map's menu is open, what was under the pointer at the right click is
    # held: its points stay the hover (drawn so here, their traces lit up in
    # the plot), and what the map says of them and the status bar's
    # coordinates are what they were then, wherever the pointer goes over
    # the menu.
    var under: seq[PointRef] = @[]
    var near: seq[(MapFilter, int)] = @[] # what the marks under the pointer mark
    var foldBin = -1
    let foldShown = mu.fold.showing and
      st.settings.map.foldAny and mgPreplot notin st.settings.map.hiddenGroups
    if held:
      under = mu.menuPoints
      near = mu.near
      foldBin = mu.foldBin
      res.cursor = mu.menuCursor
    elif hovered and mu.drag.kind in {mdNone, mdMeasure}:
      let m = igGetIO_Nil().MousePos
      let at = view.mapAt(plot, v2(m))
      if foldShown: foldBin = mu.fold.shown[].binAt(at.x, at.y)
      res.cursor = coordinatesText(at, view.perPixel, units)
      under = st.pointsAt(at, float64(pickRadius) * view.width / float64(max(size.x, 1)))
      # survey units of half a pixel at 100 %
      let perMark = view.perPixel * float64(fb.x) / 2
      near = mu.nearFound.markedHere(mu.markSpots, at, proc (f: MapFilter): float64 =
        float64(MarkSizes[FilterMarks[f].family]) * perMark)
    elif hovered:
      res.cursor = coordinatesText(view.mapAt(plot, v2(igGetIO_Nil().MousePos)),
        view.perPixel, units)
    let infoFor = (st.survey.revision, st.shots.revision, st.sessions.len, mu.marksRev)
    if foldBin >= 0 and not foldShown: foldBin = -1
    if under != mu.hovered or infoFor != mu.infoFor or near != mu.near or
        foldBin != mu.foldBin or (foldShown and mu.foldFor != mu.fold.revision):
      mu.foldBin = foldBin
      # (what it says may have changed too)
      mu.hovered = under
      mu.infoFor = infoFor
      mu.near = near
      mu.info.setLen 0
      for i in 0 ..< min(under.len, 3):
        mu.info.add st.pointInfo(under[i], units)
        mu.info[^1].lines.add st.filterLines(under[i], mu.hits, mu.hitIndex)
      # Where marks crowd onto one spot (zoomed out), how many of each lie
      # under the pointer, when that is more than the point described says.
      var things = 0
      for (_, n) in near: things += n
      let said = if under.len > 0: st.filterLines(under[0], mu.hits, mu.hitIndex) else: @[]
      let named = if said.len > 0: said[0].count(", ") + 1 else: 0
      if things > named:
        if mu.info.len == 0: mu.info.add PointInfo(title: "Marks here")
        mu.info[0].lines.add markedHereText(near)
      if foldBin >= 0:
        if mu.info.len == 0: mu.info.add PointInfo(title: mu.fold.shown[].layerTitle(st.unitsOf))
        mu.info[0].lines.add mu.fold.shown[].foldText(foldBin, st.unitsOf)
    mu.sendHover(res)
    # A click on a source shows its record (on a receiver in a file of
    # receiver gathers, its gather; on a source of a receiver gather, the
    # gather of its first trace, its traces selected); on a shot log's point it
    # chooses the rows of the shot and their traces; on any other point it selects the
    # point and its traces. Ctrl + click adds or takes out; Shift + click
    # selects the stations along the line from the point clicked last.
    if click > 0 and under.len > 0:
      let c = if click == 3: Command(kind: ckSelectPoints, points: @[under[0]],
                pointMode: smRange)
              elif click == 2: Command(kind: ckSelectPoints, points: under, pointMode: smToggle)
              elif st.opensRecord(under[0]): Command(kind: ckShowPoints, points: under)
              else: Command(kind: ckSelectPoints, points: under, pointMode: smReplace,
                jump: under[0].role == prSource)
      res.commands.add c
    if menu:
      mu.menuPoints = under
      mu.menuTitle = if under.len > 0: mu.info[0].title else: "No point here"
      mu.menuShows = under.len > 0 and st.opensRecord(under[0])
      mu.menuCursor = res.cursor
      mu.menuAt = igGetIO_Nil().MousePos
    if view.isSet:
      mu.followSpreads(st)
      mu.drawSpreads(view, plot, ink, t, marks)
      mu.drawRuler(view, plot, lengths, ink, t, marks)
      let scale = mu.drawScaleBar(view, pos, size, fb.x, lengths, ink, t, marks)
      mu.drawFoldLegend(pos, size, scale, st.unitsOf, ink, marks)
    if (hovered or held) and mu.info.len > 0 and st.settings.map.info == miPopup and
        mu.drag.kind == mdNone:
      # (beside the menu, not under it)
      drawInfoBox(mu.info, (if held: mu.menuAt else: igGetIO_Nil().MousePos), pos, size, t,
        marks, (if held: mu.menuRect else: Rect()))
    ImDrawList_PopClipRect(dl)
    marks.markRect("map.explain", pos, ImVec2_c(x: pos.x + size.x, y: pos.y + size.y))
    explainShow("map.explain", marks,
      explain(pkMap, st.mapFacts(units, lengths.unit.abbreviation)))
    mu.cur = after
    if after != st.map.view:
      res.commands.add Command(kind: ckMapView, mapView: after, mapRemember: remember)
  ImPlot_PopStyleColor(1)
  if infoRows > 0: # the strip along the bottom: always there, so the plot keeps its size
    igSetCursorPosY(igGetCursorPosY() + 2)
    igBeginGroup()
    if mu.info.len > 0:
      var lines: seq[string]
      for i in mu.info.merged:
        if i.title.len > 0 and lines.len > 0: lines.add i.title
        lines.add i.lines
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlAccent]))
      igTextUnformatted(mu.info[0].title.cstring, nil)
      igPopStyleColor(1)
      igSameLine(0, 12)
      igTextUnformatted((if lines.len > 0: lines[0] else: "").cstring, nil)
      igTextUnformatted((if lines.len > 1: lines[1 .. ^1].join("   ") else: "").cstring, nil)
    else:
      igTextDisabled("Point at a source or a receiver for its station, coordinates and traces.")
      igTextUnformatted("", nil)
    igEndGroup()
    marks.mark("map.info")
  if menu: igOpenPopup_Str(menuId, 0)
  mu.drawMenu(st, marks, res)

proc centred(text: string; c: Rgba) =
  let avail = igGetContentRegionAvail()
  let w = min(igCalcTextSize(text.cstring, nil, false, -1).x, avail.x)
  let at = igGetCursorPos()
  igSetCursorPos(ImVec2_c(x: at.x + max(0, (avail.x - w) / 2), y: at.y + avail.y / 2 - 10))
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(c))
  igPushTextWrapPos(igGetCursorPosX() + w + 1)
  igTextUnformatted(text.cstring, nil)
  igPopTextWrapPos()
  igPopStyleColor(1)

proc drawMap*(mu: var MapUi; id: string; st: AppState; t: Theme; marks: var Marks): MapOutput =
  ## The map window, titled "Map" with the ImGui ID `id` (`"###" & id`),
  ## marked "map": its strip, then the map or a note when there is no survey.
  let title = IconMap & "  Map###" & id
  # Arrow keys pan the map, so they do not move ImGui's keyboard focus here;
  # the wheel zooms, so it does not scroll the window.
  const windowFlags = ImGui_WindowFlags_NoNavInputs.cint or
    ImGui_WindowFlags_NoScrollWithMouse.cint or ImGui_WindowFlags_NoScrollbar.cint
  var drawn = false
  if beginClosable(awMap, title.cstring, windowFlags):
    mu.focus.watch()
    igSetScrollX_Float(0)
    igSetScrollY_Float(0)
    marks.markWindow("map")
    let map = st.settings.map
    mu.fold.follow(st.jobs, st.survey, mu.foldWant(st),
      (if map.foldAlong > 0: map.foldAlong else: NaN),
      (if map.foldAcross > 0: map.foldAcross else: NaN))
    let ink = mapInk(t, st.settings.plot.display.colours, st.settings.plot.display.custom)
    let layers = mapLayers(st, ink)
    var points = 0
    for l in layers: points += l.points
    var ask = maNone
    mu.drawStrip(st, layers, marks, result, ask, t)
    if mu.gpuError.len > 0:
      centred("The map cannot be drawn: " & mu.gpuError, t.roles[rlError])
    elif points == 0:
      mu.hovered.setLen 0
      mu.info.setLen 0
      centred("No survey on the map yet: open SPS or SEG P1 files (File > Open, or drop " &
        "them on the window), or a seismic file whose traces carry coordinates.",
        t.roles[rlTextDim])
    else:
      mu.drawPlot(st, layers, ink, t, marks, result, ask)
      drawn = true
  mu.focus.settle()
  igEnd()
  # No map this frame (hidden behind another tab, nothing to draw): its
  # pointer lights nothing up in the plot.
  if not drawn: mu.hovered.setLen 0
  mu.sendHover(result)
