## The Explain icon every plot carries: a small "i" in the top left corner of
## the plot's drawing area, drawn over the plot. Hovering it shows what the plot
## tells you (`core/explain` writes the words) in a wrapped tooltip at once.
##
## It is drawn on the window's list and found by the pointer's position, never
## an item of its own: it takes no click, no key and no focus from the plot
## under it, and has no ImGui id that could clash with the plot's.
## `explainIcon` marks it as `<mark>` (and the open tooltip as `<mark>.tip:<text>`),
## so tests can point at it and read what it says.

import std/math
import imguin/cimgui
import ../../view/theme
import icons, marks, style

const
  TipWidth = 32'f32 ## the tooltip's wrap width, in text heights
  CornerGap = 5'f32 ## from the plot's corner, at 100 %

proc explainSpace*(): float32 =
  ## The width the icon takes at a plot's left edge, with its gap: what a note
  ## drawn in that corner keeps clear of.
  round(igGetFontSize() * 1.35) + 2 * round(CornerGap * igGetFontSize() / 13)

proc drawExplainIcon*(mark: string; pos: ImVec2_c; t: Theme; marks: var Marks): bool =
  ## Draws the icon in the corner of the plot area whose top left is `pos`
  ## and marks it `mark`; whether the pointer is on it (and nothing is held
  ## down, nor another window above).
  let side = round(igGetFontSize() * 1.35)
  let gap = round(CornerGap * igGetFontSize() / 13)
  let lo = ImVec2_c(x: pos.x + gap, y: pos.y + gap)
  let hi = ImVec2_c(x: lo.x + side, y: lo.y + side)
  marks.markRect(mark, lo, hi)
  result = igIsWindowHovered(0) and igIsMouseHoveringRect(lo, hi, false)
  let dl = igGetWindowDrawList()
  let back = t.roles[rlWindow]
  ImDrawList_AddCircleFilled(dl, ImVec2_c(x: lo.x + side / 2, y: lo.y + side / 2),
    side / 2, u32(withAlpha(back, 200)), 24)
  let ink = if result: t.roles[rlAccent] else: t.roles[rlTextDim]
  ImDrawList_AddCircle(dl, ImVec2_c(x: lo.x + side / 2, y: lo.y + side / 2), side / 2,
    u32(ink), 24, 1)
  let (font, px) = (igGetFont(), round(side * 0.72))
  let ts = ImFont_CalcTextSizeA(font, px, high(float32), 0, IconInfo.cstring, nil, nil)
  ImDrawList_AddText_FontPtr(dl, font, px,
    ImVec2_c(x: round(lo.x + (side - ts.x) / 2), y: round(lo.y + (side - ts.y) / 2)),
    u32(ink), IconInfo.cstring, nil, 0, nil)

proc showExplain*(mark, text: string; marks: var Marks) =
  ## The tooltip: `text` wrapped, its lines apart; marked `<mark>.tip:<text>`.
  if igBeginTooltip():
    igPushTextWrapPos(igGetFontSize() * TipWidth)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    marks.markRect(mark & ".tip:" & text, igGetItemRectMin(), igGetItemRectMax())
    igEndTooltip()

template explainIcon*(mark: string; pos: ImVec2_c; t: Theme; marks: var Marks;
    text: untyped) =
  ## The icon at plot corner `pos`, marked `mark`; `text` (a string
  ## expression, worked out only while the pointer is on the icon) is its tooltip.
  if drawExplainIcon(mark, pos, t, marks): showExplain(mark, text, marks)
