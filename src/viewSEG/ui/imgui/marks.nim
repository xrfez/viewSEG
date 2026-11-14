## Named screen rectangles of the frame drawn: where each part (a button, a
## row, a window) lies, in framebuffer pixels of the main window, so tests
## can point at it and screenshots can be checked.

import imguin/cimgui
import ../../core/geometry

type
  Marks* = seq[(string, Rect)]
    ## Named screen rectangles of the last frame (framebuffer pixels).

func toRect(a, b: ImVec2_c): Rect =
  Rect(pos: vec2(a.x, a.y), size: vec2(b.x - a.x, b.y - a.y))

proc markRect*(marks: var Marks; name: string; a, b: ImVec2_c) =
  ## Records the screen rectangle `a`..`b` as `name`, in framebuffer pixels of
  ## the main window (ImGui's coordinates are the desktop's, with viewports).
  let s = igGetIO_Nil().DisplayFramebufferScale
  let o = igGetMainViewport().Pos
  marks.add (name, toRect(ImVec2_c(x: (a.x - o.x) * s.x, y: (a.y - o.y) * s.y),
    ImVec2_c(x: (b.x - o.x) * s.x, y: (b.y - o.y) * s.y)))

proc mark*(marks: var Marks; name: string) =
  ## Records the last item's rectangle as `name`.
  marks.markRect(name, igGetItemRectMin(), igGetItemRectMax())

proc markWindow*(marks: var Marks; name: string) =
  ## Records the current window's rectangle as `name`.
  let (pos, size) = (igGetWindowPos(), igGetWindowSize())
  marks.markRect(name, pos, ImVec2_c(x: pos.x + size.x, y: pos.y + size.y))
