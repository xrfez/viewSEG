## Draws the first-break overlay (`view/breakbars`) over a Seismic plot: the
## model's bar and the pick's, each with a thin halo in the plot's background
## colour so it reads over the waveform and over density, and, in the Seismic
## window's strip beside the overlay's button, a small key naming the two
## colours and what the overlay cannot show (never over the traces).
## The bars are marked ("plot.first break model N", "plot.first break pick N",
## "plot.first break link N" for the first few in view) for tests.

import std/[algorithm, math, strutils]
import imguin/cimgui
import ../../core/[breakmodel, firstbreaks, geometry, join, orientation, panels, viewport]
import ../../view/[areabands, breakbars, plotink, theme]
import marks, style

const
  MarkedBars = 400 ## the marks of one frame that are named, at most
  KeyMarks* = ["plot.first break key", "plot.first break note"]
    ## the key and the note beside it

func mix(c: Rgba; a: float32): Rgba =
  Rgba(r: c.r, g: c.g, b: c.b, a: uint8(clamp(a, 0, 1) * 255))

proc vec(v: Vec2): ImVec2_c {.inline.} = ImVec2_c(x: v.x, y: v.y)

proc drawBreakMarks*(g: BreakGeometry; ink: PlotInk; size: BreakSize; marks: var Marks) =
  ## The marks of `g` in the current plot's clip rectangle: the halo under
  ## each, then the mark in its colour; `size` sets the thickness.
  if g.marks.len == 0: return
  let dl = igGetWindowDrawList()
  let u = max(1'f32, igGetFontSize() / 15)
  ImPlot_PushPlotClipRect(0)
  let halo = mix(ink.background, 0.85)
  var drawn = 0
  for pass in 0 .. 1: # halos first, so no bar is covered by another's halo
    for mk in g.marks:
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

proc numberBox(id: string; value: float64; format: string; typed: var float64): bool =
  ## A box for a number that acts as it is typed: true on each change, the value in `typed`.
  var v = cdouble(value)
  igSetNextItemWidth(round(igCalcTextSize("00000000.0", nil, false, -1).x +
    2 * igGetStyle().FramePadding.x))
  result = igInputDouble(id.cstring, addr v, 0, 0, format.cstring, 0)
  typed = float64(v)

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
  ## survey gave it); a click opens the popover: where the model comes from (fitted, or the
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
  for w in words: width += swatch + 4 * u + igCalcTextSize(w.cstring, nil, false, -1).x + 10 * u
  let wordsWidth = width
  width += givenW + offW
  let keyWidth = width
  if note.len > 0: width += igCalcTextSize(note.cstring, nil, false, -1).x
  igSameLine(0, 12 * u)
  let top = igGetCursorScreenPos()
  if igInvisibleButton("##breakKey", ImVec2_c(x: width, y: height), 0):
    igOpenPopup_Str(BreakPopup, 0)
  var what = b.modelWords(unit, fromSurvey)
  if what.len == 0: what = b.statusWords
  elif b.statusWords.len > 0 and not b.isGiven: what.add "\n" & b.statusWords
  if what.len > 0 and igIsItemHovered(0) and not igIsPopupOpen_Str(BreakPopup, 0):
    igSetTooltip("%s", what.cstring)
  var m = d.breakModel
  igSetNextWindowPos(ImVec2_c(x: top.x, y: top.y + height), ImGuiCond_Appearing.cint,
    ImVec2_c(x: 0, y: 0))
  if igBeginPopup(BreakPopup, 0):
    igPushTextWrapPos(igGetCursorPosX() + 28 * igGetFontSize())
    var nd = d
    if drawModelChoice(b, unit, m, t, marks):
      nd.breakModel = m
      result = (true, nd)
    if fromSurvey:
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
      igTextWrapped(UnitFromSurvey.cstring)
      igPopStyleColor(1)
    if drawLookChoice(nd, ink, marks):
      nd.breakModel = m
      result = (true, nd)
    igPopTextWrapPos()
    igEndPopup()
  let y = top.y + (height - h) / 2
  var x = top.x
  for i, w in words:
    let chosen = if i == 0: d.breakModelColour else: d.breakPickColour
    let role = if i == 0: rlBreakModel else: rlBreakPick
    let colour = if chosen.a != 0: chosen else: readableOn(t.roles[role], t.roles[rlWindow])
    ImDrawList_AddLine(dl, ImVec2_c(x: x, y: y + h / 2), ImVec2_c(x: x + swatch, y: y + h / 2),
      u32(colour), 3 * u)
    x += swatch + 4 * u
    ImDrawList_AddText_Vec2(dl, ImVec2_c(x: x, y: y), u32(t.roles[rlText]), w.cstring, nil)
    x += igCalcTextSize(w.cstring, nil, false, -1).x + 10 * u
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
