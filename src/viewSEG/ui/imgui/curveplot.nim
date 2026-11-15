## Draws a `CurvePlot` (`view/curveplot`) with ImPlot: each curve a line
## in its colour, named in the legend (a click there hides it); the axes
## named with their units, the frequency axis logarithmic when asked; x
## across from the left, or the plot turned with x down from the top
## (`CurvePlot.along`). ImPlot's own gestures move the view (the wheel
## zooms about the pointer, a drag pans, a right drag zooms to a box, a
## double click fits the data), held within the data's limits so that no
## view shows past it. Under the pointer, a line across the plot at the
## nearest x and a dot on each curve; the reading (`readingAt`) goes back
## to the caller, which says it in words (`readoutText`).

import std/math
import imguin/cimgui
import ../../view/[curveplot, theme]
import marks, style

type
  CurvePlotUi* = object
    ## A curve plot's state between frames.
    fitted: string ## the key of the data the view was last fitted to

  CurveOutput* = object
    reading*: Reading ## what the pointer reads; `index` -1 when it is not over the plot
    hovered*: bool

proc drawCurvePlot*(ui: var CurvePlotUi; id: string; p: CurvePlot; t: Theme; size: ImVec2_c;
    fitKey: string; marks: var Marks): CurveOutput =
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
    let n = min(c.ys.len, p.xs.len) - first
    if n > 0:
      ImPlot_SetNextLineStyle(vec4(c.colour), 1.5 * width)
      let xs = cast[ptr cdouble](unsafeAddr p.xs[first])
      let ys = cast[ptr cdouble](unsafeAddr c.ys[first])
      if turned:
        ImPlot_PlotLine_doublePtrdoublePtr(c.name.cstring, ys, xs, cint(n), 0, 0,
          cint(sizeof(float64)))
      else:
        ImPlot_PlotLine_doublePtrdoublePtr(c.name.cstring, xs, ys, cint(n), 0, 0,
          cint(sizeof(float64)))
  if ImPlot_IsPlotHovered() and not p.isEmpty:
    let m = ImPlot_GetPlotMousePos(ImAxis_X1.cint, ImAxis_Y1.cint)
    result.hovered = true
    result.reading = p.readingAt(if turned: m.y else: m.x)
    if result.reading.index >= 0:
      let dl = ImPlot_GetPlotDrawList()
      let cross = u32(t.roles[rlCrosshair])
      let at = result.reading.x
      ImDrawList_PushClipRect(dl, pos, ImVec2_c(x: pos.x + area.x, y: pos.y + area.y), true)
      let a = if turned: ImPlot_PlotToPixels_double(0, at, ImAxis_X1.cint, ImAxis_Y1.cint)
              else: ImPlot_PlotToPixels_double(at, 0, ImAxis_X1.cint, ImAxis_Y1.cint)
      if turned:
        ImDrawList_AddLine(dl, ImVec2_c(x: pos.x, y: round(a.y)),
          ImVec2_c(x: pos.x + area.x, y: round(a.y)), cross, width)
      else:
        ImDrawList_AddLine(dl, ImVec2_c(x: round(a.x), y: pos.y),
          ImVec2_c(x: round(a.x), y: pos.y + area.y), cross, width)
      for i, c in p.curves:
        let j = result.reading.index # the dot on the curve as drawn
        let v = if j < c.ys.len: c.ys[j] else: NaN
        if v.classify notin {fcNan, fcInf, fcNegInf}:
          let q = if turned: ImPlot_PlotToPixels_double(v, at, ImAxis_X1.cint, ImAxis_Y1.cint)
                  else: ImPlot_PlotToPixels_double(at, v, ImAxis_X1.cint, ImAxis_Y1.cint)
          ImDrawList_AddCircleFilled(dl, q, 3 * width, u32(c.colour), 12)
      ImDrawList_PopClipRect(dl)
  if p.isEmpty and p.note.len > 0:
    let dl = ImPlot_GetPlotDrawList()
    let ts = igCalcTextSize(p.note.cstring, nil, false, -1)
    ImDrawList_AddText_Vec2(dl, ImVec2_c(x: pos.x + max(0, (area.x - ts.x) / 2),
      y: pos.y + max(0, (area.y - ts.y) / 2)), u32(t.roles[rlTextDim]), p.note.cstring, nil)
  ImPlot_EndPlot()
