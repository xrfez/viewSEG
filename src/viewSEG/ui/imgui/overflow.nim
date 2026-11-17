## A window's check that none of its items reaches past its right edge: text that is
## wider than the window, a control line that did not wrap. Tests read the mark.

import imguin/cimgui
import ../../core/geometry
import marks

proc markOverflow*(marks: var Marks; name: string) =
  ## Records `name & ".overflow"`: a rectangle as wide as the part of the current window's
  ## content that is past its right work edge, in points (0 when everything fits), and as
  ## high as the window's content. Call it last in the window, before `igEnd`.
  let w = igGetCurrentWindow()
  let over = max(0'f32, w.DC.CursorMaxPos.x - w.WorkRect.Max.x)
  marks.add (name & ".overflow", Rect(pos: vec2(0, 0), size: vec2(over, 1)))
