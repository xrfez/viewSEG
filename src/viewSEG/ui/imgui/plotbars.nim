## The plot window's scroll bars: one under the plot when not every trace is
## in view, one right of it when not all of the record's time is, none when
## everything is (`core/zoom`: `showsAll`, `thumbOf`, `scrolled`, `paged`).
##
## The thumb is as long as the share of the data in view. Dragging it pans;
## a click on the track pans by a whole view towards the click, again and
## again while the button is held, until the thumb reaches the pointer; the
## wheel over a bar pans along it. Every change is a new view, which the
## plot window sends to `core` like any other gesture's, so reads stay
## bounded by the view and "back" returns to the view before. Esc lets go
## of a held bar (a dragged thumb puts the view back where it was), and so
## does a view `core` sets itself (back, a new gather): the bar does nothing
## more until it is pressed again.
##
## The bars sit in room kept for them right of and below the plot's data
## area (`barRoom`), so the plot neither moves nor changes size when a bar
## appears or goes.

import imguin/cimgui
import ../../core/state
import ../../view/theme
import chrome, style

const barGap = 2'f32 ## between the data area and a bar, and beyond it

type
  BarEvent* = enum
    beNone  ## nothing happened
    beGrab  ## a thumb began to move: a gesture starts
    beDrag  ## a thumb moved on
    bePage  ## a click on a track, or its repeat, moved the view by a whole view
    beWheel ## the wheel over a bar panned

  ScrollBars* = object
    ## The bars' state between frames: the thumb being dragged, or the track
    ## being held. `ScrollBars()` lets go of both until the button is pressed
    ## again (Esc, or a view `core` sets itself).
    grabbed: bool
    axis: Axis
    press: float32 ## the pointer along the bar when the thumb was grabbed
    start: Viewport ## the view then
    moved: bool
    paging: bool ## a press on a track pages on while it is held

proc barRoom*(): ImVec2_c =
  ## The room to keep right of and below the plot's frame for the bars,
  ## beyond ImPlot's own padding (which they also use).
  let bar = igGetStyle().ScrollbarSize
  let pad = ImPlot_GetStyle().PlotPadding
  ImVec2_c(x: max(0, bar + 2 * barGap - pad.x), y: max(0, bar + 2 * barGap - pad.y))

func grabbed*(sb: ScrollBars): bool {.inline.} = sb.grabbed
  ## Whether a thumb is being dragged.

proc cancel*(sb: var ScrollBars; after: var Viewport): bool =
  ## Drops the thumb being dragged, the view back where it was when it was
  ## grabbed, or stops a held track paging (Esc); the bar does nothing more
  ## until it is pressed again. False when no thumb was dragged.
  result = sb.grabbed
  if sb.grabbed and sb.moved: after = sb.start
  sb = ScrollBars()

proc drawScrollBars*(sb: var ScrollBars; after: var Viewport; view: Viewport;
    pos, size: ImVec2_c; lim: ViewLimits; t: Theme; marks: var Marks): BarEvent =
  ## The bars of the plot whose data area lies at `pos`, `size` (ImGui's
  ## coordinates) and shows `view`, each with its mouse handling; `after` is
  ## this frame's view so far, and what the user does with a bar moves it.
  ## Says what happened, for "back".
  result = beNone
  let io = igGetIO_Nil()
  let style = igGetStyle()
  let bar = style.ScrollbarSize
  let least = float64(max(style.GrabMinSize, bar))
  let dl = igGetWindowDrawList()
  for a in Axis:
    let length = if a == axTraces: size.x else: size.y
    let shown = not view.showsAll(a, lim) or (sb.grabbed and sb.axis == a)
    if shown and length >= 1 and bar >= 1:
      let lo = if a == axTraces: ImVec2_c(x: pos.x, y: pos.y + size.y + barGap)
               else: ImVec2_c(x: pos.x + size.x + barGap, y: pos.y)
      let hi = if a == axTraces: ImVec2_c(x: pos.x + size.x, y: lo.y + bar)
               else: ImVec2_c(x: lo.x + bar, y: pos.y + size.y)
      igSetCursorScreenPos(lo)
      discard igInvisibleButton((if a == axTraces: "##bar.traces" else: "##bar.time").cstring,
        ImVec2_c(x: hi.x - lo.x, y: hi.y - lo.y), ImGui_ButtonFlags_MouseButtonLeft.cint)
      let hovered = igIsItemHovered(0)
      let along = float64(if a == axTraces: io.MousePos.x - lo.x else: io.MousePos.y - lo.y)
      let track = float64(length)
      let th = thumbOf(after, a, lim, track, least)
      let onThumb = along >= th.start and along <= th.start + th.length
      if igIsItemActivated():
        if onThumb:
          sb = ScrollBars(grabbed: true, axis: a, press: float32(along), start: after)
        else:
          sb = ScrollBars(axis: a, paging: true)
          after = after.paged(a, (if along < th.start: -1.0 else: 1.0), lim)
          result = bePage
      elif igIsItemActive() and sb.paging and sb.axis == a and
          igIsMouseClicked_Bool(ImGui_MouseButton_Left.cint, true):
        # held on the track: page on until the thumb is under the pointer
        if along < th.start:
          after = after.paged(a, -1, lim)
          result = bePage
        elif along > th.start + th.length:
          after = after.paged(a, 1, lim)
          result = bePage
      if sb.grabbed and sb.axis == a:
        let moved = along - float64(sb.press)
        if moved != 0 and not sb.moved:
          sb.moved = true
          result = beGrab
        elif sb.moved:
          result = beDrag
        if sb.moved:
          after = scrolled(sb.start, a, lim, track, least, moved)
        if not igIsMouseDown_Nil(ImGui_MouseButton_Left.cint):
          sb = ScrollBars()
      elif sb.paging and sb.axis == a and not igIsMouseDown_Nil(ImGui_MouseButton_Left.cint):
        sb = ScrollBars()
      if hovered and not sb.grabbed:
        let notches = if a == axTraces and io.MouseWheelH != 0: -io.MouseWheelH
                      else: io.MouseWheel
        if notches != 0:
          after = after.paged(a, -float64(notches) * PanStep, lim)
          result = beWheel
      # drawn where this frame leaves the view, so the thumb keeps up
      let now = thumbOf(after, a, lim, track, least)
      let (t0, t1) = (float32(now.start), float32(now.start + now.length))
      let (g0, g1) = if a == axTraces:
          (ImVec2_c(x: lo.x + t0, y: lo.y), ImVec2_c(x: lo.x + t1, y: hi.y))
        else: (ImVec2_c(x: lo.x, y: lo.y + t0), ImVec2_c(x: hi.x, y: lo.y + t1))
      let grab = if sb.grabbed and sb.axis == a: ImGui_Col_ScrollbarGrabActive
                 elif hovered and onThumb: ImGui_Col_ScrollbarGrabHovered
                 else: ImGui_Col_ScrollbarGrab
      ImDrawList_AddRectFilled(dl, lo, hi, u32(withAlpha(t.roles[rlBorder], 70)), bar / 2, 0)
      ImDrawList_AddRectFilled(dl, g0, g1, igGetColorU32_Col(grab.cint, 1), bar / 2, 0)
      marks.markRect("plot.bar." & $a, lo, hi)
      marks.markRect("plot.thumb." & $a, g0, g1)
