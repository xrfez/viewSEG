## Where a floating window of a numbered kind (an FFT window, a New plot
## window) opens the first time it is shown: beside the middle of the main
## window, a step lower and to the right for each number, and always inside
## the main window's work area. One past its edge would open, with
## viewports, as a window of its own outside the main window, where
## nobody looks.

import std/[math, tables]
import imguin/cimgui

const Step = 28'f32 ## the cascade's step, in points at 100 %

proc placeNext*(number: int; size: (float32, float32); scale: float32) =
  ## Sets the next window's first position and size: `size` (points at 100
  ## %, made smaller to fit the work area), centred on the work area for
  ## number 1, each further number `Step` lower and to the right, round
  ## again from the middle once the next step would leave the work area.
  let vp = igGetMainViewport()
  let room = vp.WorkSize
  let w = min(size[0] * scale, room.x)
  let h = min(size[1] * scale, room.y)
  let step = Step * scale
  let x0 = (room.x - w) / 2
  let y0 = (room.y - h) / 2
  # the steps that fit: from the middle to the right and the bottom edges
  let fit = max(0, int(floor(min(room.x - w - x0, room.y - h - y0) / step)))
  let k = float32((number - 1) mod (fit + 1))
  igSetNextWindowPos(ImVec2_c(x: round(vp.WorkPos.x + x0 + k * step),
    y: round(vp.WorkPos.y + y0 + k * step)), ImGui_Cond_FirstUseEver.cint,
    ImVec2_c(x: 0, y: 0))
  igSetNextWindowSize(ImVec2_c(x: round(w), y: round(h)), ImGui_Cond_FirstUseEver.cint)

var framesOpen: Table[string, int] ## per modal: the frames it has been open

proc centreModal*(id: string) =
  ## Call just before `igBeginPopupModal(id)`: the confirmation or dialog opens
  ## in the middle of the main window's work area, whichever window asked for
  ## it. An auto-sized window has no size in its first frames, so the middle is
  ## kept for the first few; after that the user may move it.
  let n = if igIsPopupOpen_Str(id.cstring, 0): framesOpen.getOrDefault(id) + 1 else: 0
  framesOpen[id] = n
  if n <= 4:
    let vp = igGetMainViewport()
    igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + vp.WorkSize.x / 2,
      y: vp.WorkPos.y + vp.WorkSize.y / 2), ImGui_Cond_Always.cint, ImVec2_c(x: 0.5, y: 0.5))
