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
## drag to measure a distance, which stays until Esc. Esc cancels the
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

import std/[math, strutils]
import imguin/cimgui
import ../../core/[geometry, state]
import ../../gpu/mappoints
import ../../view/[maplayers, theme]
import focus, icons, marks, style

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
  hoveredSize = 12'f32
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

  Ruler = object
    ## The distance measured last, until Esc.
    shown: bool
    a, b: MapPoint

  MapAskKind = enum
    maNone, maFit, maZoomIn, maZoomOut

  MapUi* = object
    ## The map window's own state between frames.
    renderer: MapRenderer
    gpuError: string
    started: bool
    cur: MapView
      ## the view the map shows, with the plot's size last frame
    jumps: int             ## the map's `jumps` last followed
    drag: MapDrag
    ruler: Ruler
    gesture: MapGesture
    gestureAt: float64
    focus: FocusClicks
    hovered: seq[PointRef] ## under the pointer: the nearest point, and others on its spot
    info: seq[PointInfo]   ## what the map says of them
    infoFor: tuple[survey, shots, files: int]
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
    activeFor: tuple[gather: GatherRef; survey: int]
      ## what `active` was made from
    visibleFor: tuple[hidden: seq[MapLayerKey]; groups: set[MapGroup]]
      ## the layers and groups hidden when the highlight's places were found
    spreadShown, spreadHovered: PlannedSpread
      ## the spreads planned for the record on show and for the shot under the pointer
    spreadFor: tuple[gather: GatherRef; survey, spreads: int; domain: RelationDomain; on: bool]
      ## what `spreadShown` was found from
    spreadHoverFor: tuple[point, survey, spreads: int; domain: RelationDomain; on: bool]
      ## what `spreadHovered` was found from
    boxes: seq[tuple[name: string; corners: array[4, Vec2]]]
      ## the template boxes drawn last frame, ImGui's coordinates (for tests)
    marksFor: tuple[shots, survey: int; on: bool; hidden: seq[MapLayerKey];
      groups: set[MapGroup]]
      ## what the marked points were found from
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
    stripWidths: array[4, float32]
    rulerText, scaleText: string
    scale: ScaleBar ## the scale bar drawn last
    plot: Rect
      ## the plot's area last frame, framebuffer pixels
    wanted: MapView ## a view to give the map next frame (`show`)
    want: bool

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

func scaleText*(mu: MapUi): lent string {.inline.} = mu.scaleText
func scaleBarShown*(mu: MapUi): ScaleBar {.inline.} = mu.scale
  ## The scale bar drawn last: its length (in the unit it names) and its
  ## length in framebuffer pixels.
  ## What the scale bar says ("500 ft"); "" with none (for tests).

func mapMenuTitle*(mu: MapUi): lent string {.inline.} = mu.menuTitle
  ## What the right-click menu said it acts on when it last opened (for tests).

func mapImagesDrawn*(mu: MapUi): int {.inline.} = mu.renderer.imagesDrawn
  ## How many map images were drawn (an idle map draws none; for tests).

func mapPointsDrawn*(mu: MapUi): int {.inline.} = mu.renderer.pointsDrawn
  ## How many points the last image drew (for tests).

func mapLayersUploaded*(mu: MapUi): int {.inline.} = mu.renderer.layersUploaded
  ## How many layers' points went to the GPU (for tests: a hover uploads none).

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

proc layerRow(l: MapLayerView; i: int; marks: var Marks; res: var MapOutput) =
  ## One layer of the popover: its colour, its own toggle and its points.
  igPushID_Int(cint(i))
  swatch(l.colour, "##colour")
  igSameLine(0, -1)
  var on = l.own
  let label = l.name & (if l.points > 0: "  (" & $l.points & ")" else: "")
  if igCheckbox(label.cstring, addr on):
    res.commands.add Command(kind: ckMapLayer, mapLayer: l.key, shown: on)
  marks.mark("map.layer " & (if l.key.kind == mlHighlight: "highlight"
    else: l.file & " " & roleWord(l.role)))
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
    if x.later.len > 0:
      wrapped($x.later.len & (if x.later.len == 1: " file does" else: " files do") &
        " not answer: tried again in a minute.")
    igUnindent(0)

proc drawLayers(st: AppState; layers: openArray[MapLayerView]; marks: var Marks;
    res: var MapOutput) =
  ## The layers popover, in groups: the Preplot (the survey files), then the
  ## Recorded (the open files' own positions), each with its own toggle and
  ## its layers under it (each with its colour and toggle; greyed out while
  ## the group is hidden), then the highlight.
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
      if l.key.kind != mlHighlight and l.group == g:
        any = true
        layerRow(l, i, marks, res)
    igEndDisabled()
    if not any:
      let none = if g == mgPreplot: "No survey file loaded (open SPS or SEG P1 files)"
                 else: "No seismic file whose traces carry positions is open"
      igTextDisabled("%s", none.cstring)
    if g == mgPreplot: drawTemplateRow(st, marks, res)
    else: drawShotsRow(st, marks, res)
    igUnindent(0)
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

proc layersWidth(layers: openArray[MapLayerView]): float32 =
  ## The widest line of the Layers popover.
  var lines = @[$mgPreplot & ": the survey files", TemplateLabel,
    "Shots in the folder: 10000 of 10000 sources have a file",
    "No survey file loaded (open SPS or SEG P1 files)",
    "No seismic file whose traces carry positions is open"]
  for l in layers: lines.add l.name & "  (" & $l.points & ")"
  widest(lines) + igGetStyle().IndentSpacing

proc drawStrip(mu: var MapUi; st: AppState; layers: openArray[MapLayerView]; marks: var Marks;
    res: var MapOutput; ask: var MapAskKind) =
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
    if button(IconSettings & "##more", marks, "map.more"): igOpenPopup_Str(moreId, 0)
    under[1] = ImVec2_c(x: igGetItemRectMin().x, y: igGetItemRectMax().y)
    tip("Where the map describes the point under the pointer, and the unit of its lengths")
  placePopover(under[0], layersWidth(layers))
  if igBeginPopup(layersId, 0):
    drawLayers(st, layers, marks, res)
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
    lim: MapLimits; hovered: bool; t: Theme; remember, menu: var bool; click: var int;
    res: var MapOutput) =
  ## The wheel and the buttons over the map (the invisible button just drawn
  ## over it). A left press released where it went down is a click: `click`
  ## 1, 2 with Ctrl, 3 with Shift.
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
                   elif io.KeyCtrl: mdMeasure
                   else: mdPan
        mu.drag = MapDrag(kind: kind, button: b.cint, press: mouse, start: after,
          adding: io.KeyCtrl and io.KeyShift)
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
      mu.ruler = Ruler(shown: true, a: view.mapAt(plot, v2(mu.drag.press)),
        b: view.mapAt(plot, v2(b)))
    if not down:
      if not mu.drag.moved and hovered and mu.focus.acts:
        click = 2 # Ctrl + click (no drag, no ruler): adds the point or takes it out
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
      if mu.drag.kind == mdMeasure: mu.ruler = Ruler()
      mu.drag = MapDrag()
    elif mu.ruler.shown: mu.ruler = Ruler()
    elif st.selection.selected.len > 0 or st.selection.points.len > 0:
      res.commands.add Command(kind: ckClearSelection)

func shownAt(st: AppState; p: PointRef): MapPoint =
  ## Where point `p` is drawn: NaN (not drawn) while its layer or its
  ## layer's group is hidden, so the highlight of a hidden layer is hidden
  ## too.
  let i = st.survey.find(p.layer)
  if i >= 0 and st.layerShown(st.survey.layers[i], p.role): st.positionOf(p)
  else: mapPoint(NaN, NaN)

proc followHighlight(mu: var MapUi; st: AppState; hidden: bool) =
  ## The highlighted points on the GPU: the gather on show's, the
  ## selection's, the plot's hovered trace's and the map's own hover, each
  ## found again (with where they are) only when what it comes from changes,
  ## so a hover finds its own few points alone; uploaded when one changed.
  ## Points of a hidden layer are not drawn.
  let visible = (st.map.hidden, st.settings.map.hiddenGroups)
  var changed = mu.highlightRev == 0 or hidden != mu.drawnHidden or visible != mu.visibleFor
  if visible != mu.visibleFor:
    mu.visibleFor = visible
    mu.selectedFor = (-1, -1) # where the points are drawn, found again
    mu.activeFor.survey = -1
  let selected = (st.selection.selectedRevision, st.survey.revision)
  if selected != mu.selectedFor:
    mu.highlight = st.highlightOf
    mu.selectedAt.setLen 0
    for p in mu.highlight.selected: mu.selectedAt.add st.shownAt(p)
    mu.selectedFor = selected
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
    else: mu.renderer.setHighlight(origin, mu.activeAt, mu.selectedAt, hovered)
    mu.drawnHidden = hidden
    inc mu.highlightRev

proc followMarks(mu: var MapUi; st: AppState) =
  ## The marked points on the GPU: the survey's sources whose record is in a
  ## file of the folder listed (while the Recorded group and its tick are
  ## on, and the source's layer is drawn); found again and uploaded only when
  ## what they come from changes.
  let on = st.settings.map.folderShots and mgRecorded notin st.settings.map.hiddenGroups
  let now = (st.shots.revision, st.survey.revision, on, st.map.hidden,
    st.settings.map.hiddenGroups)
  if now == mu.marksFor and mu.marksRev > 0: return
  mu.marksFor = now
  mu.marked.setLen 1
  mu.marked[0].setLen 0
  if on:
    for p in st.shots.pointRefs: mu.marked[0].add st.shownAt(p)
  let b = st.survey.bounds
  mu.renderer.setMarks(if b.isEmpty: mapPoint(0, 0) else: mapPoint(b.minX, b.minY), mu.marked)
  inc mu.marksRev

proc drawScaleBar(mu: var MapUi; view: MapView; pos, size: ImVec2_c; fb: float32;
    lengths: tuple[unit: SurveyUnit; factor: float64]; ink: MapInk; t: Theme;
    marks: var Marks) =
  ## The scale bar in the plot's bottom-left corner, in the unit the map
  ## states lengths in (`shownLengths`), and a north arrow in its top-right one.
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
  if not mu.ruler.shown: return
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
  mu.rulerText = lengthText(d * lengths.factor, lengths.unit.abbreviation) & (if br.isNaN: ""
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
  let shown = (st.selection.activeGather, st.survey.revision, st.spreads.revision, domain, on)
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
    else: "O gather " & $sp.record) & ": " & $sp.stations & " " & what &
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

proc drawInfoBox(info: openArray[PointInfo]; at: ImVec2_c; plotPos, plotSize: ImVec2_c;
    t: Theme; marks: var Marks) =
  ## What the map says of the points under the pointer, in a box beside the
  ## pointer, kept inside the plot (drawn in the window, not as a window of
  ## its own: a tooltip past the main window's edge would become a window of
  ## its own and take the keyboard focus from the map).
  var rows: seq[(string, bool)] # text, a title
  for i in info.merged:
    if i.title.len > 0: rows.add (i.title, true)
    for l in i.lines: rows.add (l, false)
  let pad = igGetStyle().WindowPadding
  let lineH = igGetTextLineHeightWithSpacing()
  var w = 0'f32
  for (text, _) in rows: w = max(w, igCalcTextSize(text.cstring, nil, false, -1).x)
  let size = ImVec2_c(x: w + 2 * pad.x, y: float32(rows.len) * lineH + 2 * pad.y -
    igGetStyle().ItemSpacing.y)
  var lo = ImVec2_c(x: at.x + 18, y: at.y + 18)
  if lo.x + size.x > plotPos.x + plotSize.x: lo.x = at.x - 18 - size.x
  if lo.y + size.y > plotPos.y + plotSize.y: lo.y = at.y - 18 - size.y
  lo = ImVec2_c(x: max(lo.x, plotPos.x), y: max(lo.y, plotPos.y))
  let hi = ImVec2_c(x: lo.x + size.x, y: lo.y + size.y)
  let dl = igGetWindowDrawList()
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
  if igBeginPopup(menuId, 0):
    marks.markWindow("map menu")
    if mu.menuPoints.len == 0:
      igTextDisabled("No point here")
    else:
      igTextDisabled("%s", mu.menuTitle.cstring)
      igSeparator()
      var traces = 0
      for p in mu.menuPoints: traces += st.survey.tracesAt(p).len
      let selected = mu.menuPoints[0].key in st.selection.pointKeys
      if mu.menuShows:
        if igMenuItem_Bool("Show its record", "Click", false, true):
          res.commands.add Command(kind: ckShowPoints, points: mu.menuPoints)
        marks.mark("map menu.show")
      let what = if traces == 0: "Select it"
                 elif traces == 1: "Select it and its trace"
                 else: "Select it and its " & $traces & " traces"
      let key: cstring = if mu.menuShows: nil else: "Click"
      if igMenuItem_Bool(what.cstring, key, false, true):
        res.commands.add Command(kind: ckSelectPoints, points: mu.menuPoints,
          pointMode: smReplace)
      marks.mark("map menu.select")
      let toggle = if selected: "Take it out of the selection" else: "Add it to the selection"
      if igMenuItem_Bool(toggle.cstring, "Ctrl+Click", false, true):
        res.commands.add Command(kind: ckSelectPoints, points: mu.menuPoints,
          pointMode: (if selected: smRemove else: smAdd))
      marks.mark("map menu.add")
      igSeparator()
      let i = st.survey.find(mu.menuPoints[0].layer)
      if i >= 0:
        let key = st.survey.layers[i].keyOf(mu.menuPoints[0].role)
        let name = roleWord(mu.menuPoints[0].role) & " of " & st.survey.layers[i].name
        if igMenuItem_Bool(("Hide the " & name).cstring, nil, false, true):
          res.commands.add Command(kind: ckMapLayer, mapLayer: key, shown: false)
        marks.mark("map menu.hide")
    igEndPopup()

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
      mu.followHighlight(st, not st.map.shown(HighlightKey))
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
            else: MapStyle(colour: l.colour, size: disc * s))
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
    mu.handleMouse(st, after, view, plot, lim, hovered, t, remember, menu, click, res)
    mu.handleKeys(st, after, view, plot, lim, hovered, remember, res)
    # The point under the pointer, and what the map says of it.
    var under: seq[PointRef]
    if hovered and mu.drag.kind in {mdNone, mdMeasure}:
      let m = igGetIO_Nil().MousePos
      let at = view.mapAt(plot, v2(m))
      res.cursor = coordinatesText(at, view.perPixel, units)
      under = st.pointsAt(at, float64(pickRadius) * view.width / float64(max(size.x, 1)))
    elif hovered:
      res.cursor = coordinatesText(view.mapAt(plot, v2(igGetIO_Nil().MousePos)),
        view.perPixel, units)
    let infoFor = (st.survey.revision, st.shots.revision, st.sessions.len)
    if under != mu.hovered or infoFor != mu.infoFor: # (what it says may have changed too)
      mu.hovered = under
      mu.infoFor = infoFor
      mu.info.setLen 0
      for i in 0 ..< min(under.len, 3): mu.info.add st.pointInfo(under[i], units)
    mu.sendHover(res)
    # A click on a source shows its record (on a receiver in a file of
    # receiver gathers, its gather); on any other point it selects the
    # point and its traces. Ctrl + click adds or takes out; Shift + click
    # selects the stations along the line from the point clicked last.
    if click > 0 and under.len > 0:
      let c = if click == 3: Command(kind: ckSelectPoints, points: @[under[0]],
                pointMode: smRange)
              elif click == 2: Command(kind: ckSelectPoints, points: under, pointMode: smToggle)
              elif st.opensRecord(under[0]): Command(kind: ckShowPoints, points: under)
              else: Command(kind: ckSelectPoints, points: under, pointMode: smReplace)
      res.commands.add c
    if menu:
      mu.menuPoints = under
      mu.menuTitle = if under.len > 0: mu.info[0].title else: "No point here"
      mu.menuShows = under.len > 0 and st.opensRecord(under[0])
    if view.isSet:
      mu.followSpreads(st)
      mu.drawSpreads(view, plot, ink, t, marks)
      mu.drawRuler(view, plot, lengths, ink, t, marks)
      mu.drawScaleBar(view, pos, size, fb.x, lengths, ink, t, marks)
    if hovered and mu.info.len > 0 and st.settings.map.info == miPopup and
        mu.drag.kind == mdNone:
      drawInfoBox(mu.info, igGetIO_Nil().MousePos, pos, size, t, marks)
    ImDrawList_PopClipRect(dl)
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
  if igBegin(title.cstring, nil, windowFlags):
    mu.focus.watch()
    igSetScrollX_Float(0)
    igSetScrollY_Float(0)
    marks.markWindow("map")
    let ink = mapInk(t, st.settings.plot.display.colours, st.settings.plot.display.custom)
    let layers = mapLayers(st, ink)
    var points = 0
    for l in layers: points += l.points
    var ask = maNone
    mu.drawStrip(st, layers, marks, result, ask)
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
