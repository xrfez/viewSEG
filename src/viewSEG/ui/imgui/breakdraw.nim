## Draws the first-break overlay (`view/breakbars`) over a Seismic plot: the
## model's bar and the pick's, each with a thin halo in the plot's background
## colour so it reads over the waveform and over density, and, in the Seismic
## window's strip beside the overlay's button, a small key naming the two
## colours and what the overlay cannot show (never over the traces).
## The bars are marked ("plot.first break model N", "plot.first break pick N",
## "plot.first break link N" for the first few in view) for tests.

import std/[algorithm, math, strutils, tables]
import imguin/cimgui
import ../../core/[breakmodel, firstbreaks, geometry, join, orientation, panels, viewport]
import ../../view/[areabands, breakbars, plotink, theme]
import icons, marks, style

const
  MarkedBars = 400 ## the marks of one frame that are named, at most
  KeyMarks* = ["plot.first break key", "plot.first break note"]
    ## the key and the note beside it
  KeyToggleMarks* = ["plot.first break key model", "plot.first break key pick"]
    ## the key's two parts that hide or show the model bars and the pick bars
  KeyWheelMark* = "plot.first break key settings" ## the wheel at the key's end that opens the popover

func mix(c: Rgba; a: float32): Rgba =
  Rgba(r: c.r, g: c.g, b: c.b, a: uint8(clamp(a, 0, 1) * 255))

proc vec(v: Vec2): ImVec2_c {.inline.} = ImVec2_c(x: v.x, y: v.y)

proc drawBreakMarks*(g: BreakGeometry; ink: PlotInk; d: DisplaySettings; marks: var Marks) =
  ## The marks of `g` in the current plot's clip rectangle: the halo under
  ## each, then the mark in its colour; `d.breakSize` sets the thickness and the two
  ## `d.breakShow...` switches hide a kind (`shows`).
  if g.marks.len == 0: return
  let size = d.breakSize
  let dl = igGetWindowDrawList()
  let u = max(1'f32, igGetFontSize() / 15)
  ImPlot_PushPlotClipRect(0)
  let halo = mix(ink.background, 0.85)
  var drawn = 0
  for pass in 0 .. 1: # halos first, so no bar is covered by another's halo
    for mk in g.marks:
      if not mk.kind.shows(d.breakShowPicks, d.breakShowModel): continue
      let thick = barThickness(size, mk.kind, mk.heavy, g.lines) * u
      let colour = case mk.kind
        of bmModel: ink.breakModel
        of bmPick: ink.breakPick
        of bmLink: ink.breakPick
      let shade = case mk.kind
        of bmLink: 0.55'f32
        of bmPick: (if mk.faint: 0.45'f32 else: 1'f32)
        of bmModel: 1'f32
      if pass == 0:
        if mk.kind != bmLink:
          ImDrawList_AddLine(dl, vec(mk.a), vec(mk.b), u32(halo), thick + 2.4 * u)
      else:
        ImDrawList_AddLine(dl, vec(mk.a), vec(mk.b), u32(mix(colour, shade)), thick)
        if not g.lines and drawn < MarkedBars:
          let (lo, hi) = (ImVec2_c(x: min(mk.a.x, mk.b.x) - 1, y: min(mk.a.y, mk.b.y) - 1),
            ImVec2_c(x: max(mk.a.x, mk.b.x) + 1, y: max(mk.a.y, mk.b.y) + 1))
          let name = case mk.kind
            of bmModel: "plot.first break model "
            of bmPick: "plot.first break pick "
            of bmLink: "plot.first break link "
          marks.markRect(name & $mk.position, lo, hi)
          inc drawn
  ImPlot_PopPlotClipRect()

const BreakPopup = "##breakModel"

var typedBoxes: Table[string, float64] ## what a box being edited holds, until it is applied

proc numberBox(id: string; value: float64; format: string; typed: var float64): bool =
  ## A box for a number that is applied when Enter is pressed or the box loses focus, not as
  ## each key is typed (a given model starts a new picking when it changes): true then, the
  ## value in `typed`. Escape puts the value back and applies nothing.
  var v = cdouble(value)
  igSetNextItemWidth(round(igCalcTextSize("00000000.0", nil, false, -1).x +
    2 * igGetStyle().FramePadding.x))
  if igInputDouble(id.cstring, addr v, 0, 0, format.cstring, 0): typedBoxes[id] = float64(v)
  if igIsItemDeactivated():
    # (ImGui may say "deactivated after an edit" for a box left with Escape: its edits count)
    if id in typedBoxes and not igIsKeyPressed_Bool(ImGui_Key_Escape, false):
      typed = typedBoxes[id]
      result = true
    typedBoxes.del id

func medianOffset(b: FirstBreaks): float64 =
  ## The median of the record's offsets: where a second layer is first put; 1000 without any.
  var xs: seq[float64]
  for x in b.offsetAbs:
    if x == x and x < Inf: xs.add x
  if xs.len == 0: 1000.0 else: (xs.sort(); round(xs[xs.len div 2]))

proc colourChoice(id, label: string; chosen: Rgba; drawn: Rgba; marks: var Marks;
    markName: string): tuple[changed: bool; colour: Rgba] =
  ## A colour box (it opens a picker) and its name; `drawn` is what shows while none is chosen.
  let shown = if chosen.a != 0: chosen else: drawn
  var col: array[3, cfloat] = [cfloat(shown.r) / 255, cfloat(shown.g) / 255,
    cfloat(shown.b) / 255]
  result = (false, chosen)
  if igColorEdit3(id.cstring, col, (ImGui_ColorEditFlags_NoInputs.cint or
      ImGui_ColorEditFlags_NoLabel.cint).ImGuiColorEditFlags):
    func byte(v: cfloat): uint8 = uint8(clamp(round(v * 255), 0, 255))
    result = (true, Rgba(r: byte(col[0]), g: byte(col[1]), b: byte(col[2]), a: 255))
  marks.mark(markName)
  igSameLine(0, -1)
  igTextUnformatted(label.cstring, nil)

proc drawLookChoice(d: var DisplaySettings; ink: PlotInk; marks: var Marks): bool =
  ## The overlay's colours and size. True when `d` changed.
  igSeparatorText("Colours and size")
  if igCheckbox("Show picks", addr d.breakShowPicks): result = true
  marks.mark("plot.first break show picks")
  igSameLine(0, -1)
  if igCheckbox("Show model", addr d.breakShowModel): result = true
  marks.mark("plot.first break show model")
  if igCheckbox("Show weak picks", addr d.breakShowWeak): result = true
  marks.mark("plot.first break show weak")
  if igIsItemHovered(0):
    igSetTooltip("%s", ("Draw the picks that are not compared with the model (low in " &
      "confidence, or no break found) faint").cstring)
  var c = colourChoice("##breakPickColour", "pick bar", d.breakPickColour, ink.breakPick,
    marks, "plot.first break pick colour")
  if c.changed:
    d.breakPickColour = c.colour
    result = true
  c = colourChoice("##breakModelColour", "model bar", d.breakModelColour, ink.breakModel,
    marks, "plot.first break model colour")
  if c.changed:
    d.breakModelColour = c.colour
    result = true
  igBeginDisabled(d.breakPickColour.a == 0 and d.breakModelColour.a == 0)
  if igButton("Reset colours", ImVec2_c(x: 0, y: 0)):
    d.breakPickColour = Rgba()
    d.breakModelColour = Rgba()
    result = true
  igEndDisabled()
  marks.mark("plot.first break reset colours")
  igTextUnformatted("Size", nil)
  for sz in BreakSize:
    igSameLine(0, -1)
    if igRadioButton_Bool(capitalizeAscii($sz).cstring, d.breakSize == sz) and
        d.breakSize != sz:
      d.breakSize = sz
      result = true
    marks.mark("plot.first break size " & $sz)

func cutWords(b: FirstBreaks): string =
  ## "high cut 60 Hz": the cut the smoothed picking uses on `b`'s record (its sample interval),
  ## or says there is none at that interval.
  let cut = if b.dtMs > 0 and b.dtMs < Inf: pickCutHz(b.dtMs) else: PickHighCutHz
  if cut > 0: "high cut " & $int(round(cut)) & " Hz"
  else: "no high cut at this sample interval"

proc drawPickChoice(b: FirstBreaks; d: var DisplaySettings; t: Theme; marks: var Marks): bool =
  ## What the guided picking reads (`PickBasis`): true when `d` changed.
  igSeparatorText("Picking")
  igTextUnformatted("Pick on", nil)
  for basis in PickBasis:
    igSameLine(0, -1)
    let label = if basis == pbSmoothed: "Smoothed (" & b.cutWords & ")" else: "As recorded"
    if igRadioButton_Bool(label.cstring, d.breakPickOn == basis) and d.breakPickOn != basis:
      d.breakPickOn = basis
      result = true
    marks.mark("plot.first break pick on " & (if basis == pbSmoothed: "smoothed" else: "recorded"))
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextWrapped("Smoothed: the picker reads a zero-phase high-cut copy of each trace, so a " &
    "break that builds slowly is found nearer its start. The samples shown are not changed.")
  igPopStyleColor(1)
  if b.pickNote.len > 0:
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
    igTextWrapped(b.pickNote.cstring)
    igPopStyleColor(1)

proc drawModelChoice(b: FirstBreaks; unit: SurveyUnit; m: var BreakModel; t: Theme;
    marks: var Marks): bool =
  ## The popover's content: where the model comes from, the given one's numbers, and the
  ## button that keeps this record's fit as the given model. True when `m` changed.
  igTextUnformatted("Where the first-break model comes from", nil)
  for src in BreakModelSource:
    if igRadioButton_Bool(($src).cstring, m.source == src) and m.source != src:
      m.source = src
      result = true
    marks.mark("plot.first break model " & (if src == bmFitted: "fitted" else: "given"))
  if m.source == bmFitted:
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
    igTextWrapped("A straight-line refraction fit to this record's own picks. It follows " &
      "the record, so it cannot show a source at the wrong place: give a model for that.")
    igPopStyleColor(1)
  else:
    let v = unit.velocityShort
    var typed = 0.0
    if numberBox("##breakV1", m.v1, "%.1f", typed):
      m.v1 = typed
      result = true
    marks.mark("plot.first break model v1")
    igSameLine(0, -1)
    igTextUnformatted(("velocity, " & v).cstring, nil)
    if numberBox("##breakA", m.interceptMs, "%.1f", typed):
      m.interceptMs = typed
      result = true
    marks.mark("plot.first break model intercept")
    igSameLine(0, -1)
    igTextUnformatted("intercept, ms", nil)
    var two = m.segments == 2
    igBeginDisabled(m.v1 <= 0)
    if igCheckbox("Two layers", addr two):
      if two:
        m.crossover = medianOffset(b)
        m.v2 = round(m.v1 * 1.5)
      else:
        (m.v2, m.crossover) = (0.0, 0.0)
      result = true
    igEndDisabled()
    marks.mark("plot.first break model two layers")
    if two:
      if numberBox("##breakV2", m.v2, "%.1f", typed):
        m.v2 = typed
        result = true
      marks.mark("plot.first break model v2")
      igSameLine(0, -1)
      igTextUnformatted(("second velocity, " & v).cstring, nil)
      if numberBox("##breakXc", m.crossover, "%.1f", typed):
        m.crossover = typed
        result = true
      marks.mark("plot.first break model crossover")
      igSameLine(0, -1)
      igTextUnformatted("beyond this offset", nil)
    if m.v1 <= 0:
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
      igTextWrapped("Give a velocity: until then the model fitted to the record is shown.")
      igPopStyleColor(1)
  let fit = b.fitAsModel
  igBeginDisabled(fit.v1 <= 0)
  if igButton("Use this record's fit", ImVec2_c(x: 0, y: 0)):
    m = fit
    result = true
  igEndDisabled()
  marks.mark("plot.first break model use fit")
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextWrapped("Copies this record's fitted velocity, intercept and crossover and holds " &
    "them for every record: a pick off the model then points to a wrong source or station.")
  igPopStyleColor(1)
  m = m.bounded

proc drawBreakKey*(b: FirstBreaks; unit: SurveyUnit; fromSurvey: bool; d: DisplaySettings;
    ink: PlotInk; t: Theme; height: float32; marks: var Marks):
    tuple[changed: bool; display: DisplaySettings] =
  ## The key, in the strip right of the overlay's button (never over the
  ## traces), one width whatever the model: a swatch and a word for each bar ("model",
  ## "pick"), then a small "given" when the model is the given one and, in the warning
  ## colour, "358 off" when some traces are off it (`keyParts`). While the overlay is working,
  ## failed or has no model, its own words follow in dim text (`keyNote`). One item `height`
  ## high. Hovering the key says what the model is (`modelWords`: velocity, intercept, median,
  ## counts, where the offsets came from; `unit` is the offsets' and `fromSurvey` says the
  ## survey gave it); a click on the rest (or on the wheel at its end) opens the popover: where the model comes from (fitted, or the
  ## one the user gives), the bars' colours and size. The result says whether `d` changed.
  result = (false, d)
  let dl = igGetWindowDrawList()
  let u = max(1'f32, igGetFontSize() / 15)
  let words = ["model", "pick"]
  let parts = b.keyParts
  let swatch = 18 * u
  let h = igGetTextLineHeight()
  let note = b.keyNote
  let givenW = igCalcTextSize("given", nil, false, -1).x + 10 * u
  let offW = igCalcTextSize("0000 off", nil, false, -1).x
  var width = 0'f32
  var partW: array[2, float32]
  for i, w in words:
    partW[i] = swatch + 4 * u + igCalcTextSize(w.cstring, nil, false, -1).x + 10 * u
    width += partW[i]
  let wheelW = igGetFontSize() + 6 * u
  let keyWidth = width + givenW + offW
  width = keyWidth
  if note.len > 0: width += igCalcTextSize(note.cstring, nil, false, -1).x
  igSameLine(0, 12 * u)
  let top = igGetCursorScreenPos()
  var what = b.modelWords(unit, fromSurvey)
  if what.len == 0: what = b.statusWords
  elif b.statusWords.len > 0 and not b.isGiven: what.add "\n" & b.statusWords
  let shown = [d.breakShowModel, d.breakShowPicks]
  let kinds = ["model", "picks"]
  var nd = d
  var x = top.x
  for i in 0 .. 1:
    igSetCursorScreenPos(ImVec2_c(x: x, y: top.y))
    if igInvisibleButton(("##breakKey" & words[i]).cstring, ImVec2_c(x: partW[i], y: height), 0):
      if i == 0: nd.breakShowModel = not d.breakShowModel
      else: nd.breakShowPicks = not d.breakShowPicks
      result = (true, nd)
    marks.markRect(KeyToggleMarks[i], ImVec2_c(x: x, y: top.y),
      ImVec2_c(x: x + partW[i], y: top.y + height))
    if igIsItemHovered(0) and not igIsPopupOpen_Str(BreakPopup, 0):
      var tip = "Click to " & (if shown[i]: "hide" else: "show") & " the " & kinds[i]
      if what.len > 0: tip.add "\n" & what
      igSetTooltip("%s", tip.cstring)
    x += partW[i]
  igSetCursorScreenPos(ImVec2_c(x: x, y: top.y))
  if igInvisibleButton("##breakKey", ImVec2_c(x: width - (x - top.x), y: height), 0):
    igOpenPopup_Str(BreakPopup, 0)
  if what.len > 0 and igIsItemHovered(0) and not igIsPopupOpen_Str(BreakPopup, 0):
    igSetTooltip("%s", what.cstring)
  igSetCursorScreenPos(ImVec2_c(x: top.x + width, y: top.y))
  if igInvisibleButton("##breakKeySettings", ImVec2_c(x: wheelW, y: height), 0):
    igOpenPopup_Str(BreakPopup, 0)
  let wheelHovered = igIsItemHovered(0)
  if wheelHovered and not igIsPopupOpen_Str(BreakPopup, 0):
    igSetTooltip("%s", "Overlay settings: the model, picking, colours and size")
  marks.markRect(KeyWheelMark, ImVec2_c(x: top.x + width, y: top.y),
    ImVec2_c(x: top.x + width + wheelW, y: top.y + height))
  var m = d.breakModel
  igSetNextWindowPos(ImVec2_c(x: top.x, y: top.y + height), ImGuiCond_Appearing.cint,
    ImVec2_c(x: 0, y: 0))
  if igBeginPopup(BreakPopup, 0):
    igPushTextWrapPos(igGetCursorPosX() + 28 * igGetFontSize())
    nd = result.display
    if drawModelChoice(b, unit, m, t, marks):
      nd.breakModel = m
      result = (true, nd)
    if fromSurvey:
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
      igTextWrapped(UnitFromSurvey.cstring)
      igPopStyleColor(1)
    if drawPickChoice(b, nd, t, marks):
      nd.breakModel = m
      result = (true, nd)
    if drawLookChoice(nd, ink, marks):
      nd.breakModel = m
      result = (true, nd)
    igPopTextWrapPos()
    igEndPopup()
  let y = top.y + (height - h) / 2
  x = top.x
  let dim = Rgba(r: t.roles[rlText].r, g: t.roles[rlText].g, b: t.roles[rlText].b, a: 100)
  for i, w in words:
    let chosen = if i == 0: d.breakModelColour else: d.breakPickColour
    let role = if i == 0: rlBreakModel else: rlBreakPick
    var colour = if chosen.a != 0: chosen else: readableOn(t.roles[role], t.roles[rlWindow])
    let wordW = igCalcTextSize(w.cstring, nil, false, -1).x
    if shown[i]:
      ImDrawList_AddLine(dl, ImVec2_c(x: x, y: y + h / 2), ImVec2_c(x: x + swatch, y: y + h / 2),
        u32(colour), 3 * u)
      ImDrawList_AddText_Vec2(dl, ImVec2_c(x: x + swatch + 4 * u, y: y), u32(t.roles[rlText]),
        w.cstring, nil)
    else:
      # hidden: a hollow swatch and the word dimmed and struck through
      colour.a = 110
      ImDrawList_AddRect(dl, ImVec2_c(x: x, y: y + h / 2 - 2 * u),
        ImVec2_c(x: x + swatch, y: y + h / 2 + 2 * u), u32(colour), 0, 1.2 * u, 0)
      let wx = x + swatch + 4 * u
      ImDrawList_AddText_Vec2(dl, ImVec2_c(x: wx, y: y), u32(dim), w.cstring, nil)
      ImDrawList_AddLine(dl, ImVec2_c(x: wx, y: y + h / 2), ImVec2_c(x: wx + wordW, y: y + h / 2),
        u32(dim), u)
    x += partW[i]
  if parts.given:
    ImDrawList_AddText_Vec2(dl, ImVec2_c(x: x, y: y), u32(t.roles[rlTextDim]), "given", nil)
  x += givenW
  if parts.off.len > 0:
    ImDrawList_AddText_Vec2(dl, ImVec2_c(x: x, y: y), u32(t.roles[rlWarning]),
      parts.off.cstring, nil)
  x += offW
  marks.markRect(KeyMarks[0], top, ImVec2_c(x: top.x + keyWidth, y: top.y + height))
  if note.len > 0:
    ImDrawList_AddText_Vec2(dl, ImVec2_c(x: x, y: y), u32(t.roles[rlTextDim]), note.cstring, nil)
    marks.markRect(KeyMarks[1], ImVec2_c(x: x, y: top.y),
      ImVec2_c(x: top.x + width, y: top.y + height))
  ImDrawList_AddText_Vec2(dl, ImVec2_c(x: top.x + width + 3 * u, y: y),
    u32(if wheelHovered: t.roles[rlText] else: t.roles[rlTextDim]), IconSettings.cstring, nil)

proc drawAreaBands*(bands: openArray[AreaBand]; ink: PlotInk; marks: var Marks) =
  ## The exclusion area of the record's noisy-trace test in the current plot's
  ## clip rectangle: a quiet grey band behind the traces not judged, with a thin
  ## line at each end, so the data stays readable through it. Each is marked
  ## ("plot.noise area N", N from 1) for tests.
  if bands.len == 0: return
  let dl = igGetWindowDrawList()
  let u = max(1'f32, igGetFontSize() / 15)
  ImPlot_PushPlotClipRect(0)
  let fill = u32(Rgba(r: 128, g: 128, b: 128, a: 70))
  let edge = u32(Rgba(r: 150, g: 150, b: 150, a: 210))
  for i, bd in bands:
    let (lo, hi) = (ImVec2_c(x: min(bd.a.x, bd.b.x), y: min(bd.a.y, bd.b.y)),
      ImVec2_c(x: max(bd.a.x, bd.b.x), y: max(bd.a.y, bd.b.y)))
    ImDrawList_AddRectFilled(dl, lo, hi, fill, 0, 0)
    # the two ends across the traces' axis: the long sides of the band
    if hi.x - lo.x >= hi.y - lo.y:
      ImDrawList_AddLine(dl, ImVec2_c(x: lo.x, y: lo.y), ImVec2_c(x: lo.x, y: hi.y), edge, u)
      ImDrawList_AddLine(dl, ImVec2_c(x: hi.x, y: lo.y), ImVec2_c(x: hi.x, y: hi.y), edge, u)
    else:
      ImDrawList_AddLine(dl, ImVec2_c(x: lo.x, y: lo.y), ImVec2_c(x: hi.x, y: lo.y), edge, u)
      ImDrawList_AddLine(dl, ImVec2_c(x: lo.x, y: hi.y), ImVec2_c(x: hi.x, y: hi.y), edge, u)
    marks.markRect("plot.noise area " & $(i + 1), lo, hi)
  ImPlot_PopPlotClipRect()
