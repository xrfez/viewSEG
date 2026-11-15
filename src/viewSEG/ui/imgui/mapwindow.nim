## The map window: the survey's sources and receivers in survey
## coordinates, north up, always at equal aspect, with no basemap (nothing
## is fetched from anywhere). One layer per loaded survey file's sources and
## receivers (discs), the open file's own positions (rings) and the
## highlight on top (`view/maplayers`); each can be hidden ("Layers" in the
## strip, or the right-click menu of one of its points).
##
## The window reads `core` and issues `Command`s; it never changes the
## state itself. ImPlot only draws the axes: the window handles the mouse
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
## stand in the plot's corners. A click on a point selects it and its traces
## (Ctrl + click adds or takes it out).

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
  selectedSize = 8'f32
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
    highlight: MapHighlight
    highlightFor: tuple[selected, hover, survey: int]
      ## what `highlight` was made from
    highlightRev: int
    drawnHover: seq[PointRef]
      ## the map's own hover the GPU's highlight holds
    menuPoints: seq[PointRef]
    menuTitle: string
    stripWidths: array[4, float32]
    rulerText, scaleText: string
    plot: Rect
      ## the plot's area last frame, framebuffer pixels

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
  ## What the scale bar says ("500 ft"); "" with none (for tests).

func mapMenuTitle*(mu: MapUi): lent string {.inline.} = mu.menuTitle
  ## What the right-click menu said it acts on when it last opened (for tests).

func mapImagesDrawn*(mu: MapUi): int {.inline.} = mu.renderer.imagesDrawn
  ## How many map images were drawn (an idle map draws none; for tests).

func mapPointsDrawn*(mu: MapUi): int {.inline.} = mu.renderer.pointsDrawn
  ## How many points the last image drew (for tests).

proc mapImage*(mu: MapUi): (seq[Rgba], int, int) =
  ## The last map image, row by row from the top, and its size (for tests;
  ## with the GL context current).
  let (w, h) = mu.renderer.imageSize
  (mu.renderer.readImage, w, h)

func mapPlot*(mu: MapUi): Rect {.inline.} = mu.plot
  ## The plot's area last frame, in framebuffer pixels (for tests).

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

proc drawLayers(st: AppState; layers: openArray[MapLayerView]; marks: var Marks;
    res: var MapOutput) =
  ## The layers popover: each layer with its colour, shown or not.
  for i, l in layers:
    igPushID_Int(cint(i))
    swatch(l.colour, "##colour")
    igSameLine(0, -1)
    var on = l.shown
    let label = l.name & (if l.points > 0: "  (" & $l.points & ")" else: "")
    if igCheckbox(label.cstring, addr on):
      res.commands.add Command(kind: ckMapLayer, mapLayer: l.key, shown: on)
    marks.mark("map.layer " & (if l.key.kind == mlHighlight: "highlight"
      else: l.file & " " & roleWord(l.role)))
    igPopID()

proc drawStrip(mu: var MapUi; st: AppState; layers: openArray[MapLayerView]; marks: var Marks;
    res: var MapOutput; ask: var MapAskKind) =
  ## The strip at the top of the window, in groups that wrap.
  let right = igGetCursorScreenPos().x + igGetContentRegionAvail().x
  mu.stripGroup(0, right, 0):
    if button(IconLayers & "  Layers##layers", marks, "map.layers"):
      igOpenPopup_Str(layersId, 0)
    tip("Show or hide each layer: the survey files' sources and receivers, the open " &
      "file's own positions, the highlight")
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
    tip("Where the map describes the point under the pointer")
  if igBeginPopup(layersId, 0):
    drawLayers(st, layers, marks, res)
    igEndPopup()
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

proc handleMouse(mu: var MapUi; st: AppState; after: var MapView; view: MapView; plot: Rect;
    lim: MapLimits; hovered: bool; t: Theme; remember, menu: var bool; click: var int;
    res: var MapOutput) =
  ## The wheel and the buttons over the map (the invisible button just drawn
  ## over it). A left press released where it went down is a click: `click`
  ## 1, or 2 with Ctrl.
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
      mu.drag = MapDrag()
  of mdMeasure:
    if mu.drag.moved:
      mu.ruler = Ruler(shown: true, a: view.mapAt(plot, v2(mu.drag.press)),
        b: view.mapAt(plot, v2(b)))
    if not down: mu.drag = MapDrag()

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

proc followHighlight(mu: var MapUi; st: AppState; hidden: bool) =
  ## The highlighted points on the GPU: the plot's hovered trace's, the
  ## selection's and the map's own hover, made again when one changes.
  let key = (st.selection.selectedRevision, st.selection.hover, st.survey.revision)
  var changed = false
  if key != mu.highlightFor:
    mu.highlight = st.highlightOf
    mu.highlightFor = key
    changed = true
  if mu.hovered != mu.drawnHover:
    mu.drawnHover = mu.hovered
    changed = true
  if changed or mu.highlightRev == 0:
    var selected, hovered: seq[MapPoint]
    if not hidden:
      for p in mu.highlight.selected: selected.add st.positionOf(p)
      for p in mu.highlight.hovered: hovered.add st.positionOf(p)
      for p in mu.hovered: hovered.add st.positionOf(p)
    let b = st.survey.bounds
    let origin = if b.isEmpty: mapPoint(0, 0) else: mapPoint(b.minX, b.minY)
    mu.renderer.setHighlight(origin, selected, hovered)
    inc mu.highlightRev

proc drawScaleBar(mu: var MapUi; view: MapView; pos, size: ImVec2_c; fb: float32;
    units: string; ink: MapInk; t: Theme; marks: var Marks) =
  ## The scale bar in the plot's bottom-left corner, and a north arrow in its
  ## top-right one.
  let bar = scaleBar(view.perPixel, float64(scalePixels * fb))
  mu.scaleText = ""
  if bar.length <= 0: return
  let dl = igGetWindowDrawList()
  let px = float32(bar.pixels) / fb # ImGui pixels
  let text = lengthText(bar.length, units)
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

proc drawRuler(mu: var MapUi; view: MapView; plot: Rect; units: string; ink: MapInk;
    t: Theme; marks: var Marks) =
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
  mu.rulerText = lengthText(d, units) & (if br.isNaN: ""
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
      let what = if traces == 0: "Select it"
                 elif traces == 1: "Select it and its trace"
                 else: "Select it and its " & $traces & " traces"
      if igMenuItem_Bool(what.cstring, "Click", false, true):
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
  case ask
  of maNone: discard
  of maFit:
    next = fitMap(lim, next.columns, next.rows)
    remember = true
    mu.gesture = mgNone
  of maZoomIn, maZoomOut:
    next = next.zoomedMap((if ask == maZoomIn: KeyStep else: 1 / KeyStep), next.centre, lim)
    if mu.burst(mgKeyZoom): remember = true
  let units = st.unitsOf
  let infoRows = if st.settings.map.info == miStrip: 2 else: 0
  let lineH = igGetTextLineHeightWithSpacing()
  let avail = igGetContentRegionAvail()
  ImPlot_PushStyleColor_Vec4(ImPlot_Col_PlotBg.cint, vec4(ink.background))
  const flags = ImPlot_Flags_NoTitle.cint or ImPlot_Flags_NoLegend.cint or
    ImPlot_Flags_NoMenus.cint or ImPlot_Flags_NoMouseText.cint or ImPlot_Flags_NoInputs.cint
  var menu = false
  let plotH = max(1'f32, avail.y - float32(infoRows) * lineH - (if infoRows > 0: 4 else: 0))
  if ImPlot_BeginPlot("##map", ImVec2_c(x: max(1, avail.x), y: plotH), flags):
    # Tick values only, as wide as the survey's largest coordinate always,
    # so the plot's edge stays put as the labels change.
    let b = lim.bounds
    let digits = max(len($int64(max(abs(b.minY), abs(b.maxY)))), 1)
    let most = decimalsFor(lim.leastPerPixel * 100)
    let d = min(decimalsFor(next.perPixel * 100), most)
    let width = digits + (if most > 0: most + 1 else: 0) + (if b.minY < 0: 1 else: 0)
    ImPlot_SetupAxis(ImAxis_X1.cint, nil, ImPlot_AxisFlags_NoMenus.cint or
      ImPlot_AxisFlags_NoGridLines.cint)
    ImPlot_SetupAxis(ImAxis_Y1.cint, nil, ImPlot_AxisFlags_NoMenus.cint or
      ImPlot_AxisFlags_NoGridLines.cint)
    ImPlot_SetupAxisFormat_Str(ImAxis_X1.cint, ("%." & $d & "f").cstring)
    ImPlot_SetupAxisFormat_Str(ImAxis_Y1.cint, ("%" & $width & "." & $d & "f").cstring)
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
      let s = fb.x
      var frame = MapFrame(area: Bounds(minX: limits.X.Min, minY: limits.Y.Min,
        maxX: limits.X.Max, maxY: limits.Y.Max), columns: columns, rows: rows,
        background: ink.background, highlight: mu.highlightRev, survey: st.survey.revision,
        selected: MapStyle(colour: ink.selected, edge: ink.outline, size: selectedSize * s,
          edgeWidth: s),
        hovered: MapStyle(colour: ink.hover, edge: ink.outline, size: hoveredSize * s,
          edgeWidth: 1.5 * s))
      let pixel = view.perPixel * float64(s) # survey units a pixel at 100 %
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
    if under != mu.hovered:
      mu.hovered = under
      mu.info.setLen 0
      for i in 0 ..< min(under.len, 3): mu.info.add st.pointInfo(under[i], units)
    if click > 0 and under.len > 0:
      res.commands.add Command(kind: ckSelectPoints, points: under,
        pointMode: (if click == 2: smToggle else: smReplace))
    if menu:
      mu.menuPoints = under
      mu.menuTitle = if under.len > 0: mu.info[0].title else: "No point here"
    if view.isSet:
      mu.drawRuler(view, plot, units, ink, t, marks)
      mu.drawScaleBar(view, pos, size, fb.x, units, ink, t, marks)
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
  mu.focus.settle()
  igEnd()
