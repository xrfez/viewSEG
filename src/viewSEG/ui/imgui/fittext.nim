## Text that has to fit a width: cut with an ellipsis, the whole text in a tooltip.
## What a table cell, a pane's rotated label or a long line does when the room is short.

import std/unicode
import imguin/cimgui

const Ellipsis* = "…"

proc textWidth*(text: string): float32 =
  ## The width `text` takes in the current font.
  igCalcTextSize(text.cstring, nil, false, -1).x

proc shortenEnd*(text: string; maxWidth: float32): string =
  ## `text` as it fits `maxWidth`, its end cut off with an ellipsis; `text` itself
  ## when it fits; "" when not even the ellipsis does.
  if text.len == 0 or maxWidth <= 0: return ""
  if textWidth(text) <= maxWidth: return text
  if textWidth(Ellipsis) > maxWidth: return ""
  let rs = text.toRunes
  var lo = 0
  var hi = rs.len - 1
  while lo <= hi:
    let keep = (lo + hi) div 2
    let candidate = $rs[0 ..< keep] & Ellipsis
    if textWidth(candidate) <= maxWidth:
      result = candidate
      lo = keep + 1
    else:
      hi = keep - 1

proc shortenPath*(path: string; maxWidth: float32): string =
  ## A relative path that fits `maxWidth`. The file name is kept; folders are
  ## cut from the left with an ellipsis. The name is cut from the end only when
  ## it alone does not fit.
  if path.len == 0 or maxWidth <= 0: return ""
  if textWidth(path) <= maxWidth: return path
  var slashAt = -1
  for i, c in path:
    if c == '/' or c == '\\': slashAt = i
  let name = if slashAt < 0: path else: path.substr(slashAt + 1)
  if textWidth(name) > maxWidth: return shortenEnd(name, maxWidth)
  if textWidth(Ellipsis) > maxWidth: return name
  let rs = path.toRunes
  let least = name.toRunes.len
  var lo = least
  var hi = rs.len
  result = if textWidth(Ellipsis & name) <= maxWidth: Ellipsis & name else: name
  while lo <= hi:
    let keep = (lo + hi) div 2
    let suffix = $rs[rs.len - keep .. ^1]
    let candidate = if keep == rs.len: path else: Ellipsis & suffix
    if textWidth(candidate) <= maxWidth:
      result = candidate
      lo = keep + 1
    else:
      hi = keep - 1

proc fittedText*(text: string; maxWidth: float32) =
  ## Draws `text` in `maxWidth`, shortened with an ellipsis, and the whole text in a
  ## tooltip when it was shortened.
  let shown = shortenEnd(text, maxWidth)
  igTextUnformatted(shown.cstring, nil)
  if shown != text and igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and
      igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()
