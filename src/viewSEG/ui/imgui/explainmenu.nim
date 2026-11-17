## Explain, by right-click: every plot's context menu ends with "Explain", which opens what the
## plot tells you (`core/explain` writes the words) in a small popover at the pointer, closed by
## Esc or a click elsewhere.
##
## A plot with no menu of its own gets one from `explainMenu`: a right click (not a drag: a
## right drag is ImPlot's zoom box) on the plot's drawing area opens a menu of that one
## entry. A plot that has a menu (the Seismic plot's, the Map's) adds the entry to it with
## `explainEntry` and shows the popover with `explainShow`.
##
## Marks: `<mark>.menu` (the small menu), `<mark>.menu.explain` (its entry), and the popover's
## text as `<mark>.tip:<text>`, so tests can read what it says.

import std/math
import imguin/cimgui
import ../../view/theme
import marks

const
  TipWidth = 32'f32 ## the popover's wrap width, in text heights
  DragLimit = 4'f32 ## a right press that moved less than this is a click

var
  wanted = ""                 ## the mark whose popover opens at the next `explainShow`
  plotPos, plotSize: ImVec2_c ## the plot drawn last (`notePlot`)

proc notePlot*(pos, size: ImVec2_c) =
  ## Says which area the plot just drawn took: its top left and its size.
  (plotPos, plotSize) = (pos, size)

proc askExplain*(mark: string) =
  ## The popover of `mark` opens (where `explainShow` is called for it).
  wanted = mark

proc explainEntry*(mark: string; marks: var Marks) =
  ## "Explain", last in a plot's own context menu, after a separator.
  igSeparator()
  if igMenuItem_Bool("Explain", nil, false, true): askExplain(mark)
  marks.mark(mark & ".menu.explain")

proc onPlot(pos: ImVec2_c): bool =
  ## Whether a right click (a press that did not drag) just ended on the plot at `pos`.
  let size = if plotPos.x == pos.x and plotPos.y == pos.y: plotSize
             else: ImVec2_c(x: 60, y: 60)
  let drag = igGetMouseDragDelta(ImGui_MouseButton_Right.cint, -1)
  igIsWindowHovered(0) and igIsMouseHoveringRect(pos, ImVec2_c(x: pos.x + size.x,
    y: pos.y + size.y), false) and igIsMouseReleased_Nil(ImGui_MouseButton_Right.cint) and
    abs(drag.x) < DragLimit and abs(drag.y) < DragLimit

proc explainContext*(mark: string; pos: ImVec2_c; marks: var Marks) =
  ## The small menu of a plot with none of its own, at plot corner `pos`.
  let id = "##explainctx" & mark
  let size = if plotPos.x == pos.x and plotPos.y == pos.y: plotSize
             else: ImVec2_c(x: 60, y: 60)
  marks.markRect(mark, pos, ImVec2_c(x: pos.x + size.x, y: pos.y + size.y)) # the plot's area
  if onPlot(pos): igOpenPopup_Str(id.cstring, 0)
  if igBeginPopup(id.cstring, 0):
    marks.markWindow(mark & ".menu")
    if igMenuItem_Bool("Explain", nil, false, true): askExplain(mark)
    marks.mark(mark & ".menu.explain")
    igEndPopup()

proc showExplain*(mark, text: string; marks: var Marks) =
  ## The popover's contents: `text` wrapped; marked `<mark>.tip:<text>`.
  igPushTextWrapPos(igGetFontSize() * TipWidth)
  igTextUnformatted(text.cstring, nil)
  igPopTextWrapPos()
  marks.markRect(mark & ".tip:" & text, igGetItemRectMin(), igGetItemRectMax())

template explainShow*(mark: string; marks: var Marks; text: untyped) =
  ## The popover of `mark`, when it was asked for (`text`, a string expression, is worked out
  ## only while it is open). Call it from the window the plot is in, every frame.
  let popId = "##explain" & mark
  if wanted == mark:
    wanted = ""
    igOpenPopup_Str(popId.cstring, 0)
  if igBeginPopup(popId.cstring, 0):
    showExplain(mark, text, marks)
    igEndPopup()

template explainMenu*(mark: string; pos: ImVec2_c; t: Theme; marks: var Marks; text: untyped) =
  ## For a plot with no menu of its own, whose drawing area has its top left at `pos`: the
  ## right-click menu with Explain, and its popover.
  explainContext(mark, pos, marks)
  explainShow(mark, marks, text)
