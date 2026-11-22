## Draws the first-break overlay (`view/breakbars`) over a Seismic plot: the
## model's bar and the pick's, each with a thin halo in the plot's background
## colour so it reads over the waveform and over density, and, in the Seismic
## window's strip beside the overlay's button, a small key naming the two
## colours and what the overlay cannot show (never over the traces).
## The bars are marked ("plot.first break model N", "plot.first break pick N",
## "plot.first break link N" for the first few in view) for tests.

import imguin/cimgui
import ../../core/[firstbreaks, geometry, join, orientation, viewport]
import ../../view/[areabands, breakbars, plotink, theme]
import marks, style

const
  MarkedBars = 400 ## the marks of one frame that are named, at most
  KeyMarks* = ["plot.first break key", "plot.first break note"]
    ## the key and the note beside it

func mix(c: Rgba; a: float32): Rgba =
  Rgba(r: c.r, g: c.g, b: c.b, a: uint8(clamp(a, 0, 1) * 255))

proc vec(v: Vec2): ImVec2_c {.inline.} = ImVec2_c(x: v.x, y: v.y)

proc drawBreakMarks*(g: BreakGeometry; ink: PlotInk; marks: var Marks) =
  ## The marks of `g` in the current plot's clip rectangle: the halo under
  ## each, then the mark in its colour.
  if g.marks.len == 0: return
  let dl = igGetWindowDrawList()
  let u = max(1'f32, igGetFontSize() / 15)
  ImPlot_PushPlotClipRect(0)
  let halo = mix(ink.background, 0.75)
  var drawn = 0
  for pass in 0 .. 1: # halos first, so no bar is covered by another's halo
    for mk in g.marks:
      let thick = case mk.kind
        of bmLink: 1.2 * u
        of bmModel: (if g.lines: 1.6 * u else: 2.6 * u)
        of bmPick: (if g.lines: 1.6 * u elif mk.heavy: 4 * u else: 3.2 * u)
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
          ImDrawList_AddLine(dl, vec(mk.a), vec(mk.b), u32(halo), thick + 2 * u)
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

proc drawBreakKey*(b: FirstBreaks; unit: SurveyUnit; t: Theme; height: float32;
    marks: var Marks) =
  ## The key, in the strip right of the overlay's button (never over the
  ## traces): a swatch and a word for each bar, then the overlay's own words
  ## while it is working, failed or has no model or fits one kind of sensor
  ## (`statusWords`), in dim text. One item `height` high. Hovering the key says what the
  ## model is (`modelWords`; `unit` is the offsets').
  let dl = igGetWindowDrawList()
  let u = max(1'f32, igGetFontSize() / 15)
  let words = ["model", "pick"]
  let swatch = 18 * u
  let h = igGetTextLineHeight()
  let note = b.statusWords
  var width = 0'f32
  for w in words: width += swatch + 4 * u + igCalcTextSize(w.cstring, nil, false, -1).x + 10 * u
  let keyWidth = width
  if note.len > 0: width += igCalcTextSize(note.cstring, nil, false, -1).x
  igSameLine(0, 12 * u)
  let top = igGetCursorScreenPos()
  igDummy(ImVec2_c(x: width, y: height))
  let what = b.modelWords(unit)
  if what.len > 0 and igIsItemHovered(0):
    igSetTooltip("%s", what.cstring)
  let y = top.y + (height - h) / 2
  var x = top.x
  for i, w in words:
    let role = if i == 0: rlBreakModel else: rlBreakPick
    ImDrawList_AddLine(dl, ImVec2_c(x: x, y: y + h / 2), ImVec2_c(x: x + swatch, y: y + h / 2),
      u32(readableOn(t.roles[role], t.roles[rlWindow])), 3 * u)
    x += swatch + 4 * u
    ImDrawList_AddText_Vec2(dl, ImVec2_c(x: x, y: y), u32(t.roles[rlText]), w.cstring, nil)
    x += igCalcTextSize(w.cstring, nil, false, -1).x + 10 * u
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
