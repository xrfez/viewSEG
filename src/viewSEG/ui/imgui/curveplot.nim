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

import std/[hashes, math, strutils, tables]
import imguin/cimgui
import ../../core/[geometry, plotcursor, references]
import ../../view/[axisfit, curveplot, plotink, theme]
import explainmenu, fittext, marks, style

type
  CurvePlotUi* = object
    ## A curve plot's state between frames.
    axes: AxisFit        ## what the axes were last fitted to (`view/axisfit`)
    screenLo, screenHi: float64
    screenPx: int
    screenKey: string
    screenStamp: Hash    ## of the data the screen copy was made from
    screen: seq[Curve]   ## peak-kept for the range on screen; redone when it changes
    haveScreen: bool
    band: SignalBand     ## a dense signal's columns for the range on screen
    seen: array[2, Span] ## the limits the last frame ended with, x then y
    haveSeen: bool

  CurveOutput* = object
    reading*: Reading
      ## what the cursor reads (held, or under the pointer); `index` -1 for none
    curve*: int    ## the curve the cursor's lines go from; -1 for none
    hovered*: bool ## the pointer is over the plot
    moved*: bool   ## ... and moved this frame
    under*: PlotCursor
      ## the point and the curve under the pointer (not held); `x` -1 when
      ## it is not over the plot
    plotPos*, plotSize*: ImVec2_c
      ## the plotting area, on the screen (zero when the plot was not drawn):
      ## where the Explain icon goes

var shownLimits: Table[string, (Span, Span)]
  ## per plot id, the x and y limits it ended its last frame with (for tests and
  ## agent control)
var shownZoom: Table[string, (bool, bool)]
  ## per plot id, whether the user has moved the x and the y axis off its fit
var poisoned: Table[string, (Span, Span)]
  ## tests: limits a plot takes as the ones its last frame ended with
var refits: Table[string, int]
  ## per plot id, how many times the guard fitted an unreadable axis again

proc poisonAxes*(id: string; x, y: Span) =
  ## Tests: the next frame of plot `id` takes `x` and `y` as the limits the last
  ## frame ended with (a state ImPlot itself would not leave: NaN, no span, far from
  ## the data), so that the guard against an unreadable axis is seen at work.
  poisoned[id] = (x, y)

proc axisRefitsOf*(id: string): int =
  ## How many times the guard fitted plot `id`'s axes to its data again.
  refits.getOrDefault(id, 0)

proc axisZoomedOf*(id: string): (bool, bool) =
  ## Whether the user has zoomed or panned plot `id`'s x and y axis since it was
  ## fitted (false for a plot not drawn).
  shownZoom.getOrDefault(id, (false, false))

proc axisLimitsOf*(id: string): (Span, Span) =
  ## The x and y limits the plot `id` ended its last frame with, as it is
  ## laid out (x across, y up; a plot turned has its x down); NaN limits
  ## for a plot not drawn.
  shownLimits.getOrDefault(id, (Span(lo: NaN, hi: NaN), Span(lo: NaN, hi: NaN)))

proc noteAxes*(id: string; seen: (Span, Span); zoomed: (bool, bool)) =
  ## What a plot that is not a curve plot (an analysis window's image) ended its last
  ## frame with, for `axisLimitsOf` and `axisZoomedOf`.
  shownLimits[id] = seen
  shownZoom[id] = zoomed

func stampOf(p: CurvePlot): Hash =
  ## A cheap fingerprint of the data: the curves' lengths and a few of their values.
  var h: Hash = 0
  for c in p.curves:
    h = h !& hash(c.name) !& hash(c.ys.len)
    if c.ys.len > 0:
      for k in 0 .. 15: h = h !& hash(c.ys[k * (c.ys.len - 1) div 15])
  h = h !& hash(p.xs.len) !& hash(p.dense.count)
  !$h

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
    fitKey: string; marks: var Marks; held = PlotCursor(); follow = true): CurveOutput =
  ## Draws `p` in a plot of `size` (ImPlot's: 0 or less takes the room
  ## left); `id` names it (`marks`: `id & ".data"`, the plotting area).
  ## The axes are fitted by `view/axisfit`'s rule: both whenever `fitKey`
  ## (the plot's options: another scale, axis or unit) changes; with the
  ## same options, an axis whose data's limits changed unless the user
  ## zoomed it. `follow` false: only `fitKey` fits, as for a panel whose
  ## view stays where the user left it.
  result.reading = Reading(index: -1, x: NaN)
  let flags = ImPlot_Flags_NoTitle.cint or ImPlot_Flags_NoMenus.cint or
    ImPlot_Flags_NoMouseText.cint or (if p.legend: 0 else: ImPlot_Flags_NoLegend.cint)
  # The last x tick label is centred on the plot's right edge: leave it room.
  let pad = ImPlot_GetStyle().PlotPadding
  if p.roomRight:
    ImPlot_PushStyleVar_Vec2(ImPlot_StyleVar_PlotPadding.cint,
      ImVec2_c(x: max(pad.x, igGetFontSize() * 2), y: pad.y))
  let began = ImPlot_BeginPlot(("##" & id).cstring, size, flags)
  if not began:
    if p.roomRight: ImPlot_PopStyleVar(1)
    return
  let turned = p.along == saY
  let (xAxis, yAxis) = if turned: (ImAxis_Y1.cint, ImAxis_X1.cint)
                       else: (ImAxis_X1.cint, ImAxis_Y1.cint)
  let axisFlags = ImPlot_AxisFlags_NoMenus.cint
  # ImPlot's X1 runs across, Y1 up: turned, x runs down from the top.
  # The label that runs up the left (rotated) is cut to the pane's height, so that stacked
  # panes' labels do not run into each other; the whole label is the axis's tooltip.
  let upLabel = if turned: p.xLabel else: p.yLabel
  # (on a short plot the unit's bracket goes before the word is cut: "Phase", not "Phase (...")
  var upFit = upLabel
  if size.y > 0 and textWidth(upLabel) > size.y - igGetFontSize() * 4.5 and " (" in upLabel:
    upFit = upLabel[0 ..< upLabel.find(" (")]
  let upShown = if size.y > 0: shortenEnd(upFit, size.y - igGetFontSize() * 4.5)
                else: upLabel
  let bare = p.bareX and not turned
  ImPlot_SetupAxis(ImAxis_X1.cint, (if turned: p.yLabel else: p.xLabel).cstring,
    axisFlags or (if bare: ImPlot_AxisFlags_NoLabel.cint or ImPlot_AxisFlags_NoTickLabels.cint
    else: 0))
  marks.add (id & ".ylabel", Rect(pos: vec2(0, 0), size: vec2(0, textWidth(upShown))))
  ImPlot_SetupAxis(ImAxis_Y1.cint, upShown.cstring,
    axisFlags or (if turned: ImPlot_AxisFlags_Invert.cint else: 0))
  if p.logX: ImPlot_SetupAxisScale_PlotScale(xAxis, ImPlot_Scale_Log10.cint)
  let xl = p.xLimits
  let yl = p.yLimits
  ImPlot_SetupAxisLimitsConstraints(xAxis, xl.lo, xl.hi)
  ImPlot_SetupAxisLimitsConstraints(yAxis, yl.lo, yl.hi)
  # The guard: an axis the last frame ended unreadable (limits not numbers, no span, or
  # none of the data in view with the user not having zoomed it) is fitted to the data
  # again on this frame.
  if id in poisoned:
    let (px, py) = poisoned[id]
    ui.seen = [px, py]
    ui.haveSeen = true
    poisoned.del id
  if ui.haveSeen:
    let badX = degenerate(ui.seen[0], Span(lo: xl.lo, hi: xl.hi), ui.axes.userZoomed(true))
    let badY = degenerate(ui.seen[1], Span(lo: yl.lo, hi: yl.hi), ui.axes.userZoomed(false))
    if badX or badY:
      ui.axes = AxisFit()
      refits[id] = refits.getOrDefault(id, 0) + 1
  let fit = ui.axes.plan(fitKey, Span(lo: xl.lo, hi: xl.hi), Span(lo: yl.lo, hi: yl.hi), follow)
  ImPlot_SetupAxisLimits(xAxis, xl.lo, xl.hi,
    if fit.x: ImPlot_Cond_Always.cint else: ImPlot_Cond_Once.cint)
  ImPlot_SetupAxisLimits(yAxis, yl.lo, yl.hi,
    if fit.y: ImPlot_Cond_Always.cint else: ImPlot_Cond_Once.cint)
  # One rule for every plot: the legend is outside the drawing area, never over the curves,
  # at the right when the pane is wide enough or short, else in a row above it.
  let legendRight = size.x <= 0 or size.x >= igGetFontSize() * 40 or
    size.y < igGetFontSize() * 12 # (a short pane has no room for a row above)
  if legendRight:
    ImPlot_SetupLegend(ImPlot_Location_NorthEast.cint, ImPlot_LegendFlags_Outside.cint)
  else:
    ImPlot_SetupLegend(ImPlot_Location_North.cint,
      ImPlot_LegendFlags_Outside.cint or ImPlot_LegendFlags_Horizontal.cint)
  marks.add (id & ".legend", Rect(pos: vec2(0, 0), size: vec2(if legendRight: 1 else: 2, 0)))
  ImPlot_SetupFinish()
  let pos = ImPlot_GetPlotPos()
  let area = ImPlot_GetPlotSize()
  (result.plotPos, result.plotSize) = (pos, area)
  notePlot(pos, area)
  marks.markRect(id & ".data", pos, ImVec2_c(x: pos.x + area.x, y: pos.y + area.y))
  # Min and max kept per bin for the pixels of the range on screen, redone when the view
  # or the data changes. The cursor still reads the full series.
  let lim = ImPlot_GetPlotLimits(xAxis, yAxis)
  let px = max(1, int(if turned: area.y else: area.x))
  let stamp = p.stampOf
  if not ui.haveScreen or ui.screenKey != fitKey or ui.screenStamp != stamp or ui.screenPx != px or
      ui.screenLo != lim.X.Min or ui.screenHi != lim.X.Max:
    ui.screen = if p.dense.count > 0: @[] else: p.forScreen(lim.X.Min, lim.X.Max, px)
    if p.dense.count > 0:
      ui.band = signalBand(toOpenArray(p.dense.values, 0, p.dense.count - 1), p.dense.x0,
        p.dense.dx, lim.X.Min, lim.X.Max, px)
    ui.screenLo = lim.X.Min
    ui.screenHi = lim.X.Max
    ui.screenPx = px
    ui.screenKey = fitKey
    ui.screenStamp = stamp
    ui.haveScreen = true
  let width = max(1'f32, round(igGetIO_Nil().DisplayFramebufferScale.x))
  if p.dense.count > 0 and ui.band.xs.len > 0 and p.curves.len > 0:
    let colour = p.curves[0].colour
    let b = addr ui.band
    let xs = cast[ptr cdouble](unsafeAddr b.xs[0])
    let lo = cast[ptr cdouble](unsafeAddr b.lo[0])
    let hi = cast[ptr cdouble](unsafeAddr b.hi[0])
    let n = cint(b.xs.len)
    # which way it is drawn, for the tests
    marks.markRect(id & (if b.exact: ".samples" else: ".band"), pos,
      ImVec2_c(x: pos.x + area.x, y: pos.y + area.y))
    if not b.exact:
      ImPlot_SetNextFillStyle(vec4(colour), 0.55)
      ImPlot_PlotShaded_doublePtrdoublePtrdoublePtr("##band".cstring, xs, lo, hi, n, 0, 0,
        cint(sizeof(float64)))
      ImPlot_SetNextLineStyle(vec4(colour), 1 * width)
      ImPlot_PlotLine_doublePtrdoublePtr("##hi".cstring, xs, hi, n, 0, 0, cint(sizeof(float64)))
    ImPlot_SetNextLineStyle(vec4(colour), (if b.exact: 1.5 else: 1) * width)
    ImPlot_PlotLine_doublePtrdoublePtr("##lo".cstring, xs, lo, n, 0, 0, cint(sizeof(float64)))
  for c in ui.screen:
    let cxs = p.xsOf(c)
    var from0 = 0
    if p.logX:
      while from0 < cxs.len and not (cxs[from0] > 0): inc from0
    let n = min(c.ys.len, cxs.len) - from0
    if n > 0:
      let xs = cast[ptr cdouble](unsafeAddr cxs[from0])
      let ys = cast[ptr cdouble](unsafeAddr c.ys[from0])
      if not turned and not c.shadeTo.isNaN:
        ImPlot_SetNextFillStyle(vec4(c.colour), 0.16)
        ImPlot_PlotShaded_doublePtrdoublePtrInt(c.name.cstring, xs, ys, cint(n),
          c.shadeTo, 0, 0, cint(sizeof(float64)))
      if c.marks:
        let size = 2.5 * c.width * width
        ImPlot_SetNextMarkerStyle(ImPlot_Marker_Circle.cint, size, vec4(c.colour), 0,
          vec4(c.colour))
        if turned:
          ImPlot_PlotScatter_doublePtrdoublePtr(c.name.cstring, ys, xs, cint(n), 0, 0,
            cint(sizeof(float64)))
        else:
          ImPlot_PlotScatter_doublePtrdoublePtr(c.name.cstring, xs, ys, cint(n), 0, 0,
            cint(sizeof(float64)))
        continue
      ImPlot_SetNextLineStyle(vec4(c.colour), c.width * width)
      if turned:
        ImPlot_PlotLine_doublePtrdoublePtr(c.name.cstring, ys, xs, cint(n), 0, 0,
          cint(sizeof(float64)))
      else:
        ImPlot_PlotLine_doublePtrdoublePtr(c.name.cstring, xs, ys, cint(n), 0, 0,
          cint(sizeof(float64)))
  # The stretches left out of a judgement (a sweep's tapers), dimmed over the curves.
  if p.dimmed.len > 0 and not turned:
    let dl = ImPlot_GetPlotDrawList()
    ImDrawList_PushClipRect(dl, pos, ImVec2_c(x: pos.x + area.x, y: pos.y +
        area.y), true)
    for d in p.dimmed:
      let a = ImPlot_PlotToPixels_double(d.a, lim.Y.Min, ImAxis_X1.cint,
          ImAxis_Y1.cint)
      let b = ImPlot_PlotToPixels_double(d.b, lim.Y.Min, ImAxis_X1.cint,
          ImAxis_Y1.cint)
      ImDrawList_AddRectFilled(dl, ImVec2_c(x: min(a.x, b.x), y: pos.y),
        ImVec2_c(x: max(a.x, b.x), y: pos.y + area.y),
        u32(withAlpha(t.roles[rlPlotBackground], 170)), 0, 0)
      marks.markRect(id & ".dim", ImVec2_c(x: min(a.x, b.x), y: pos.y),
        ImVec2_c(x: max(a.x, b.x), y: pos.y + area.y))
    ImDrawList_PopClipRect(dl)
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
  let ended = ImPlot_GetPlotLimits(xAxis, yAxis)
  let seenX = Span(lo: ended.X.Min, hi: ended.X.Max)
  let seenY = Span(lo: ended.Y.Min, hi: ended.Y.Max)
  if upShown != upLabel and ImPlot_IsAxisHovered(ImAxis_Y1.cint) and igBeginItemTooltip():
    igTextUnformatted(upLabel.cstring, nil)
    igEndTooltip()
  ui.axes.seen(seenX, seenY)
  shownLimits[id] = (seenX, seenY)
  shownZoom[id] = (ui.axes.userZoomed(true), ui.axes.userZoomed(false))
  ui.seen = [seenX, seenY]
  ui.haveSeen = true
  ImPlot_EndPlot()
  if p.roomRight: ImPlot_PopStyleVar(1)
