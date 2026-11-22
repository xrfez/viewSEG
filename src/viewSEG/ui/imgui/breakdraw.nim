## Draws the first-break overlay (`view/breakbars`) over a Seismic plot: the
## model's bar and the pick's, each with a thin halo in the plot's background
## colour so it reads over the waveform and over density, and, in the plot's
## corner, a small key naming the two colours and what the overlay cannot show.
## The bars are marked ("plot.first break model N", "plot.first break pick N",
## "plot.first break link N" for the first few in view) for tests.

import imguin/cimgui
import ../../core/[firstbreaks, geometry, orientation, viewport]
import ../../view/[breakbars, plotink, theme]
import marks, style

const
  MarkedBars = 400 ## the marks of one frame that are named, at most
  KeyMarks* = ["plot.first break key", "plot.first break note"]
    ## the key and the note under it

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

proc drawBreakKey*(b: FirstBreaks; ink: PlotInk; t: Theme; pos: ImVec2_c; marks: var Marks) =
  ## The key at the plot's top-left: a swatch and a word for each bar, and
  ## under it the overlay's own words while it is working, failed or has no
  ## model (`statusWords`).
  let dl = igGetWindowDrawList()
  let pad = igGetStyle().FramePadding
  let u = max(1'f32, igGetFontSize() / 15)
  let words = ["model", "pick"]
  let swatch = 22 * u
  let h = igGetTextLineHeight()
  var width = 0'f32
  for w in words: width += swatch + 4 * u + igCalcTextSize(w.cstring, nil, false, -1).x + 10 * u
  let note = b.statusWords
  var noteW = 0'f32
  if note.len > 0: noteW = igCalcTextSize(note.cstring, nil, false, -1).x
  let (boxW, boxH) = (max(width, noteW) + 2 * pad.x, h * (if note.len > 0: 2.0 else: 1.0) +
    2 * pad.y + (if note.len > 0: 2 * u else: 0'f32))
  let top = ImVec2_c(x: pos.x + 6, y: pos.y + 6)
  ImDrawList_AddRectFilled(dl, top, ImVec2_c(x: top.x + boxW, y: top.y + boxH),
    u32(mix(t.roles[rlPopup], 0.9)), igGetStyle().FrameRounding, 0)
  var x = top.x + pad.x
  let y = top.y + pad.y
  for i, w in words:
    let c = if i == 0: ink.breakModel else: ink.breakPick
    ImDrawList_AddLine(dl, ImVec2_c(x: x, y: y + h / 2), ImVec2_c(x: x + swatch, y: y + h / 2),
      u32(c), 3 * u)
    x += swatch + 4 * u
    ImDrawList_AddText_Vec2(dl, ImVec2_c(x: x, y: y), u32(t.roles[rlText]), w.cstring, nil)
    x += igCalcTextSize(w.cstring, nil, false, -1).x + 10 * u
  marks.markRect(KeyMarks[0], top, ImVec2_c(x: top.x + boxW, y: top.y + h + 2 * pad.y))
  if note.len > 0:
    ImDrawList_AddText_Vec2(dl, ImVec2_c(x: top.x + pad.x, y: y + h + 2 * u),
      u32(t.roles[rlTextDim]), note.cstring, nil)
    marks.markRect(KeyMarks[1], ImVec2_c(x: top.x, y: top.y + h + 2 * pad.y),
      ImVec2_c(x: top.x + boxW, y: top.y + boxH))
