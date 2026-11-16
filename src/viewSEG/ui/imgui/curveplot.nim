## Draws a `CurvePlot` (`view/curveplot`) with ImPlot: each curve a line
## in its colour, named in the legend (a click there hides it); the axes
## named with their units, the frequency axis logarithmic when asked; x
## across from the left, or the plot turned with x down from the top
## (`CurvePlot.along`). ImPlot's own gestures move the view (the wheel
## zooms about the pointer, a drag pans, a right drag zooms to a box, a
## double click fits the data), held within the data's limits so that no
## view shows past it.
##
## **The cursor**, as the Seismic window's: at the point nearest the
## pointer, on the curve nearest it (or where the keys hold it: a
## `PlotCursor` the caller keeps), a dot on each curve, and from the
## cursor's curve a line to each axis, with the exact x and value written
## on the axis over its tick labels (`xText`, `valueBoxText`: the value the
## readout says, where the curve is drawn clamped or in another unit too); the reading goes
## back to the caller, which says every curve's value in words
## (`readoutText`), with the point and curve under the pointer, for the
## keys to start from.

import std/math
import imguin/cimgui
import ../../core/plotcursor
import ../../view/[curveplot, plotink, theme]
import marks, style

type
  CurvePlotUi* = object
    ## A curve plot's state between frames.
    fitted: string ## the key of the data the view was last fitted to

  CurveOutput* = object
    reading*: Reading
      ## what the cursor reads (held, or under the pointer); `index` -1 for none
    curve*: int    ## the curve the cursor's lines go from; -1 for none
    hovered*: bool ## the pointer is over the plot
    moved*: bool   ## ... and moved this frame
    under*: PlotCursor
      ## the point and the curve under the pointer (not held); `x` -1 when
      ## it is not over the plot

proc axisBox(dl: ptr ImDrawList; text: string; along: ScreenAxis; at: float32; pos,
    area: ImVec2_c; frame: Rgba; t: Theme): (ImVec2_c, ImVec2_c) =
  ## `text` in a box on the plot's axis below it (`along` saX: centred at
  ## `at` across) or left of it (saY: right-aligned, centred at `at` down),
  ## over the tick labels, as the Seismic window's cursor writes its time.
  let ts = igCalcTextSize(text.cstring, nil, false, -1)
  let pad = ImPlot_GetStyle().LabelPadding
  var lo, hi, inside: ImVec2_c
  if along == saX:
    let edge = pos.y + area.y
    lo = ImVec2_c(x: round(at - ts.x / 2) - 3, y: edge)
    hi = ImVec2_c(x: lo.x + ts.x + 6, y: edge + pad.y + ts.y + 2)
    inside = ImVec2_c(x: lo.x + 3, y: edge + pad.y)
  else:
    let right = pos.x - pad.x
    lo = ImVec2_c(x: right - ts.x - 3, y: round(at - ts.y / 2) - 1)
    hi = ImVec2_c(x: pos.x, y: lo.y + ts.y + 2)
    inside = ImVec2_c(x: right - ts.x, y: lo.y + 1)
  ImDrawList_AddRectFilled(dl, lo, hi, u32(t.roles[rlWindow]), 0, 0)
  ImDrawList_AddRect(dl, lo, hi, u32(frame), 0, 1, 0)
  ImDrawList_AddText_Vec2(dl, inside, u32(t.roles[rlText]), text.cstring, nil)
  (lo, hi)

proc drawCurvePlot*(ui: var CurvePlotUi; id: string; p: CurvePlot; t: Theme; size: ImVec2_c;
    fitKey: string; marks: var Marks; held = PlotCursor()): CurveOutput =
  ## Draws `p` in a plot of `size` (ImPlot's: 0 or less takes the room
  ## left), its view fitted to the data whenever `fitKey` changes (new
  ## data of another kind: a new scale, another axis), else where the user
  ## left it; `id` names it (`marks`: `id & ".data"`, the plotting area).
  result.reading = Reading(index: -1, x: NaN)
  const flags = ImPlot_Flags_NoTitle.cint or ImPlot_Flags_NoMenus.cint or
    ImPlot_Flags_NoMouseText.cint
  if not ImPlot_BeginPlot(("##" & id).cstring, size, flags): return
  let turned = p.along == saY
  let (xAxis, yAxis) = if turned: (ImAxis_Y1.cint, ImAxis_X1.cint)
                       else: (ImAxis_X1.cint, ImAxis_Y1.cint)
  let axisFlags = ImPlot_AxisFlags_NoMenus.cint
  # ImPlot's X1 runs across, Y1 up: turned, x runs down from the top.
  ImPlot_SetupAxis(ImAxis_X1.cint, (if turned: p.yLabel else: p.xLabel).cstring, axisFlags)
  ImPlot_SetupAxis(ImAxis_Y1.cint, (if turned: p.xLabel else: p.yLabel).cstring,
    axisFlags or (if turned: ImPlot_AxisFlags_Invert.cint else: 0))
  if p.logX: ImPlot_SetupAxisScale_PlotScale(xAxis, ImPlot_Scale_Log10.cint)
  let xl = p.xLimits
  let yl = p.yLimits
  ImPlot_SetupAxisLimitsConstraints(xAxis, xl.lo, xl.hi)
  ImPlot_SetupAxisLimitsConstraints(yAxis, yl.lo, yl.hi)
  let fit = fitKey != ui.fitted
  ui.fitted = fitKey
  let cond = if fit: ImPlot_Cond_Always.cint else: ImPlot_Cond_Once.cint
  ImPlot_SetupAxisLimits(xAxis, xl.lo, xl.hi, cond)
  ImPlot_SetupAxisLimits(yAxis, yl.lo, yl.hi, cond)
  ImPlot_SetupLegend(ImPlot_Location_NorthEast.cint, 0)
  ImPlot_SetupFinish()
  let pos = ImPlot_GetPlotPos()
  let area = ImPlot_GetPlotSize()
  marks.markRect(id & ".data", pos, ImVec2_c(x: pos.x + area.x, y: pos.y + area.y))
  # Drawn from the first x the axis shows (a logarithmic one leaves 0 out).
  var first = 0
  if p.logX:
    while first < p.xs.len and not (p.xs[first] > 0): inc first
  let width = max(1'f32, round(igGetIO_Nil().DisplayFramebufferScale.x))
  for c in p.curves:
    let cxs = p.xsOf(c)
    var from0 = if c.xs.len > 0: 0 else: first
    if c.xs.len > 0 and p.logX:
      while from0 < cxs.len and not (cxs[from0] > 0): inc from0
    let n = min(c.ys.len, cxs.len) - from0
    if n > 0:
      let xs = cast[ptr cdouble](unsafeAddr cxs[from0])
      let ys = cast[ptr cdouble](unsafeAddr c.ys[from0])
      if not turned and not c.shadeTo.isNaN:
        ImPlot_SetNextFillStyle(vec4(c.colour), 0.16)
        ImPlot_PlotShaded_doublePtrdoublePtrInt(c.name.cstring, xs, ys, cint(n),
          c.shadeTo, 0, 0, cint(sizeof(float64)))
      ImPlot_SetNextLineStyle(vec4(c.colour), c.width * width)
      if turned:
        ImPlot_PlotLine_doublePtrdoublePtr(c.name.cstring, ys, xs, cint(n), 0, 0,
          cint(sizeof(float64)))
      else:
        ImPlot_PlotLine_doublePtrdoublePtr(c.name.cstring, xs, ys, cint(n), 0, 0,
          cint(sizeof(float64)))
  # The cursor: where the keys hold it, else under the pointer.
  result.under = PlotCursor(x: -1, y: -1)
  result.curve = -1
  let io = igGetIO_Nil()
  if ImPlot_IsPlotHovered() and not p.isEmpty:
    let m = ImPlot_GetPlotMousePos(ImAxis_X1.cint, ImAxis_Y1.cint)
    result.hovered = true
    result.moved = io.MouseDelta.x != 0 or io.MouseDelta.y != 0
    let r = p.readingAt(if turned: m.y else: m.x)
    if r.index >= 0:
      # the curve whose point is nearest the pointer on the screen
      var best = -1
      var gap = Inf
      for i, v in r.drawn:
        if v.classify notin {fcNan, fcInf, fcNegInf}:
          let q = if turned: ImPlot_PlotToPixels_double(v, r.x, ImAxis_X1.cint, ImAxis_Y1.cint)
                  else: ImPlot_PlotToPixels_double(r.x, v, ImAxis_X1.cint, ImAxis_Y1.cint)
          let d = if turned: abs(q.x - io.MousePos.x) else: abs(q.y - io.MousePos.y)
          if d < gap: (best, gap) = (i, float64(d))
      result.under = PlotCursor(x: r.index, y: best)
  if held.held and p.xs.len > 0:
    let c = held.clamped([p.xs.len, p.curves.len])
    (result.reading, result.curve) = (p.readingOf(c.x), c.y)
  elif result.under.x >= 0:
    (result.reading, result.curve) = (p.readingOf(result.under.x), result.under.y)
  if result.reading.index >= 0:
    let dl = ImPlot_GetPlotDrawList()
    let back = t.roles[rlPlotBackground]
    let cross = readableOn(t.roles[rlCrosshair], back)
    let at = result.reading.x
    ImDrawList_PushClipRect(dl, pos, ImVec2_c(x: pos.x + area.x, y: pos.y + area.y), true)
    for i, c in p.curves:
      let v = result.reading.drawn[i] # the dot on the curve as drawn
      if v.classify notin {fcNan, fcInf, fcNegInf}:
        let q = if turned: ImPlot_PlotToPixels_double(v, at, ImAxis_X1.cint, ImAxis_Y1.cint)
                else: ImPlot_PlotToPixels_double(at, v, ImAxis_X1.cint, ImAxis_Y1.cint)
        ImDrawList_AddCircleFilled(dl, q, 3 * width, u32(c.colour), 12)
    # From the cursor's point to each axis (the x axis's line the whole way
    # when its curve has no value there), a halo of the background under it.
    let v = if result.curve in 0 ..< result.reading.drawn.len: result.reading.drawn[result.curve]
            else: NaN
    let valued = v.classify notin {fcNan, fcInf, fcNegInf}
    let q = if turned: ImPlot_PlotToPixels_double(if valued: v else: 0, at, ImAxis_X1.cint,
                         ImAxis_Y1.cint)
            else: ImPlot_PlotToPixels_double(at, if valued: v else: 0, ImAxis_X1.cint,
                    ImAxis_Y1.cint)
    let (qx, qy) = (round(q.x) + 0.5, round(q.y) + 0.5)
    let bottom = pos.y + area.y
    var lines: seq[(ImVec2_c, ImVec2_c)] = @[]
    if turned: # x down the left axis, the values along the bottom
      lines.add (ImVec2_c(x: pos.x, y: qy), ImVec2_c(x: (if valued: qx else: pos.x + area.x),
        y: qy))
      if valued: lines.add (ImVec2_c(x: qx, y: qy), ImVec2_c(x: qx, y: bottom))
    else:
      lines.add (ImVec2_c(x: qx, y: (if valued: qy else: pos.y)), ImVec2_c(x: qx, y: bottom))
      if valued: lines.add (ImVec2_c(x: pos.x, y: qy), ImVec2_c(x: qx, y: qy))
    for (a, b) in lines: ImDrawList_AddLine(dl, a, b, u32(withAlpha(back, 150)), 3 * width)
    for (a, b) in lines: ImDrawList_AddLine(dl, a, b, u32(cross), width)
    ImDrawList_PopClipRect(dl)
    # the exact x and value on the axes
    let wl = igGetWindowDrawList()
    let xs = p.xText(at)
    let (xlo, xhi) = if turned: axisBox(wl, xs, saY, qy, pos, area, cross, t)
                     else: axisBox(wl, xs, saX, qx, pos, area, cross, t)
    marks.markRect(id & ".cursor x", xlo, xhi)
    let ys = p.valueBoxText(result.reading, result.curve) # the readout's value
    if valued and ys.len > 0:
      let (ylo, yhi) = if turned: axisBox(wl, ys, saX, qx, pos, area, cross, t)
                       else: axisBox(wl, ys, saY, qy, pos, area, cross, t)
      marks.markRect(id & ".cursor value", ylo, yhi)
  if p.isEmpty and p.note.len > 0:
    let dl = ImPlot_GetPlotDrawList()
    let ts = igCalcTextSize(p.note.cstring, nil, false, -1)
    ImDrawList_AddText_Vec2(dl, ImVec2_c(x: pos.x + max(0, (area.x - ts.x) / 2),
      y: pos.y + max(0, (area.y - ts.y) / 2)), u32(t.roles[rlTextDim]), p.note.cstring, nil)
  ImPlot_EndPlot()
