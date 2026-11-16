## The analysis windows (New plot): each a window of its own that docks,
## titled by what it shows ("Spectrogram 2: trace 12 · FFID 151 ·
## shot.sgd"), opened from Window > New plot or the plot's right-click menu
## on the selection or the trace under the pointer.
##
## Each shows a line of its view's settings (a spectrogram's frame length,
## overlap, floor and colour map; a phase spectrum's dB threshold and
## unwrapping; a correlation's reference and lags) and Freeze, a pin at the
## right of that line's first row, what it is
## of and through which filters, then its plots: an image in a density
## colour map with its scale (a spectrogram), or curve plots (`curveplot`)
## one under another, and what the cursor reads. The image's cursor follows
## the pointer, or is held by the keys while the window has the focus: Left
## and Right step a column (a frame), Up and Down a row (a frequency bin),
## Home and End go to the ends, Esc lets it go; its lines run to the axes,
## where its exact values are written. The windows read `core` and issue
## `Command`s: `ckPlotDisplay` for a setting, `ckPlotCursor` for a key,
## `ckClosePlot` when one is closed.

import std/[math, sets, strutils, tables]
import imguin/cimgui
import ../../core/[colourmaps, geometry, plotcursor, state]
import ../../view/[analysisview, curveplot, theme]
import chrome, curveplot as curves, icons, marks, placement, spectrumwindow, style

const
  PlotSize = (640'f32, 620'f32)     ## a window's first size, at 100 %
  VibratorSize = (760'f32, 900'f32) ## a vibrator signature's: its roles and four plots

type
  HeatCache = object
    ## An image cut down to the plot's pixels (`reduceImage`), kept while what it
    ## was made from (the answer, the view, the plot's size) is the same.
    gen: uint64
    view: array[4, float64]
    pixels: array[2, int]
    cells: ImageReduction

  PlotWindowsUi* = object
    ## The analysis windows' state between frames.
    curves: Table[int, seq[CurvePlotUi]] ## per window id, per plot
    under: Table[int, PlotCursor]        ## per window id: the cell under the pointer last frame
    readout*: Table[int, string]         ## per window id: what its cursor read last frame (tests)
    toFront: HashSet[int]                ## windows to bring forward when next drawn
    heat: Table[int, HeatCache]          ## per window id: the image as drawn, cut to the pixels
    maps: array[ColourMap, int]          ## ImPlot's index of each density colour map + 1; 0: not added

  PlotWindowsOutput* = object
    commands*: seq[Command]

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

const PlotFreeze* = "the window keeps what it shows. Off: it follows the Seismic " &
  "window's filters (and Aux toggle) and the kills of its traces"
  ## The Freeze pin's sentence, after "Freeze (on): " or "Freeze (off): "

proc follow(line: ControlLine; width: float32) =
  ## The next control of `width` on this line when it fits before the Freeze
  ## pin (or the window's right, once the line has wrapped), else the next.
  if line.fitsBefore(width, igGetStyle().ItemSpacing.x):
    igSameLine(0, -1)

proc textBoxWidth(text: string; box: float32): float32 =
  igCalcTextSize(text, nil, false, -1).x + igGetStyle().ItemSpacing.x + box

proc checkWidth(label: string): float32 =
  igGetFrameHeight() + igGetStyle().ItemInnerSpacing.x +
    igCalcTextSize(label.cstring, nil, false, -1).x

proc buttonWidth(text: string): float32 =
  igCalcTextSize(text, nil, false, -1).x + 2 * igGetStyle().FramePadding.x

func markName*(w: AnalysisWindow): string =
  ## The window's mark (and screenshot target): "new plot 2".
  "new plot " & $w.id

func windowTitle*(w: AnalysisWindow): string =
  ## Its ImGui title: its name, then its identity, which a layout keeps.
  IconPulse & "  " & w.title & "###newplot-" & $w.id

type Keys = object
  ## The cursor keys pressed this frame, while the window has the focus.
  left, right, up, down, home, ending, escape: bool

proc keysNow(focused: bool): Keys =
  ## The keys that move a cursor (repeating while held, as the spectrum
  ## windows' do); none while a box takes the keys or the window has no
  ## focus.
  if not focused or igGetIO_Nil().WantTextInput: return
  template held(k: untyped): bool = igShortcut_Nil(k.cint, ImGui_InputFlags_Repeat.cint)
  template once(k: untyped): bool = igShortcut_Nil(k.cint, 0)
  Keys(left: held(ImGui_Key_LeftArrow), right: held(ImGui_Key_RightArrow),
    up: held(ImGui_Key_UpArrow), down: held(ImGui_Key_DownArrow), home: once(ImGui_Key_Home),
    ending: once(ImGui_Key_End), escape: once(ImGui_Key_Escape))

proc numberBox(id: string; value: float64; width: float32; typed: var float64): bool =
  ## A box for a number: true once the user has finished typing into it.
  var v = cdouble(value)
  igSetNextItemWidth(width)
  discard igInputDouble(id.cstring, addr v, 0, 0, "%.4g", 0)
  typed = float64(v)
  igIsItemDeactivatedAfterEdit()

proc limitBox(id: string; value: float64; width: float32; typed: var float64): bool =
  ## A box for a limit, empty when it has none (NaN): true once the user
  ## has finished typing into it; nothing typed (or not a number) is none.
  var buf: array[32, char]
  let text = if value.isNaN: ""
             elif value == round(value) and abs(value) < 1e15: $int64(value)
             else: $value
  for i, c in text:
    if i < buf.high: buf[i] = c
  igSetNextItemWidth(width)
  discard igInputText(id.cstring, cast[cstring](addr buf[0]), csize_t(buf.len),
    ImGui_InputTextFlags_CharsScientific.cint, nil, nil)
  let got = $cast[cstring](addr buf[0])
  typed = try: parseFloat(got.strip) except ValueError: NaN
  igIsItemDeactivatedAfterEdit()

proc drawVibratorSettings(st: AppState; w: AnalysisWindow; name: string; box: float32;
    t: Theme; marks: var Marks; p: var AnalysisParams; frozen, changed: var bool) =
  ## A vibrator signature's roles (a table: role, trace, polarity), then its
  ## masses, harmonics and Limits..., with Freeze at the right of that line.
  ## Limits... opens the check and the eight boxes.
  let names = st.traceNames(w)
  let combo = round(igCalcTextSize("trace 00000", nil, false, -1).x + igGetFrameHeight() +
    2 * igGetStyle().FramePadding.x)
  let polar = round(igCalcTextSize("as recorded", nil, false, -1).x + igGetFrameHeight() +
    2 * igGetStyle().FramePadding.x)
  const flags = ImGui_TableFlags_SizingFixedFit.cint or ImGui_TableFlags_BordersInnerH.cint
  if igBeginTable(("##roles" & name).cstring, 3, flags, ImVec2_c(x: 0, y: 0), 0):
    igTableSetupColumn("Role", 0, 0, 0)
    igTableSetupColumn("Trace", 0, 0, 0)
    igTableSetupColumn("Polarity", 0, 0, 0)
    igTableHeadersRow()
    template roleRow(role: string; field: untyped; what: string) =
      igTableNextRow(0, 0)
      discard igTableSetColumnIndex(0)
      igAlignTextToFramePadding()
      igTextUnformatted(role, nil)
      tip(what)
      discard igTableSetColumnIndex(1)
      igSetNextItemWidth(combo)
      let now = p.roles.field
      let shown = if now in 0 ..< names.len: names[now] else: "none"
      if igBeginCombo(("##" & role).cstring, shown.cstring, 0):
        if igSelectable_Bool("none", now < 0, 0, ImVec2_c(x: 0, y: 0)) and now >= 0:
          (p.roles.field, changed) = (-1, true)
        for i, n in names:
          igPushID_Int(cint(i))
          if igSelectable_Bool(n.cstring, i == now, 0, ImVec2_c(x: 0, y: 0)) and i != now:
            (p.roles.field, changed) = (i, true)
          igPopID()
        igEndCombo()
      marks.mark(name & ".role " & role)
    template polarityCombo(role: string; field: untyped; what: string) =
      discard igTableSetColumnIndex(2)
      igSetNextItemWidth(polar)
      if igBeginCombo(("##polarity " & role).cstring, ($p.roles.field).cstring, 0):
        for v in Polarity:
          if igSelectable_Bool(($v).cstring, v == p.roles.field, 0, ImVec2_c(x: 0, y: 0)) and
              v != p.roles.field:
            (p.roles.field, changed) = (v, true)
        igEndCombo()
      tip(what)
    roleRow("Ref", reference, "The reference: the pilot, the phase origin")
    discard igTableSetColumnIndex(2)
    igTextUnformatted("as recorded", nil)
    roleRow("GF", groundForce, "The ground force, as recorded")
    polarityCombo("GF", groundForcePolarity, "Reversed: times -1. Automatic: reversed " &
      "when its mean phase to the reference is past ±90° (wiring)")
    roleRow("M", mass, "The reaction mass's acceleration")
    polarityCombo("M", massPolarity, "M's and B's polarity, together (the baseplate moves " &
      "against the mass). Automatic needs both and both masses: it is decided from the " &
      "force they make")
    roleRow("B", baseplate, "The baseplate's acceleration")
    discard igTableSetColumnIndex(2)
    igTextUnformatted("with M", nil)
    igEndTable()
  var typed = 0.0
  template label(text: string) =
    igAlignTextToFramePadding()
    igTextUnformatted(cstring(text), nil)
    igSameLine(0, -1)
  let line = beginControlLine()
  label("Masses: reaction")
  if limitBox("##reaction", p.reactionMassKg, box, typed) and
      (typed.isNaN or MassKgRange.allows(typed)) and typed != p.reactionMassKg:
    (p.reactionMassKg, changed) = (typed, true)
  marks.mark(name & ".reaction mass")
  tip("The reaction mass, kg: with the baseplate's, the ground force is generated from M " &
    "and B (Mr·M + Mb·B), drawn over the recorded one. Empty: none")
  line.follow(textBoxWidth("kg  baseplate", box))
  label("kg  baseplate")
  if limitBox("##baseplate", p.baseplateMassKg, box, typed) and
      (typed.isNaN or MassKgRange.allows(typed)) and typed != p.baseplateMassKg:
    (p.baseplateMassKg, changed) = (typed, true)
  marks.mark(name & ".baseplate mass")
  tip("The baseplate's mass, kg. Empty: none")
  line.follow(textBoxWidth("kg  harmonics to", box))
  label("kg  harmonics to")
  var h = cint(p.harmonics)
  igSetNextItemWidth(box)
  if igInputInt("##harmonics", addr h, 0, 0, 0) and HarmonicRange.allows(float64(h)) and h != p.harmonics:
    (p.harmonics, changed) = (int(h), true)
  tip("The highest harmonic tracked (2 to 16): THD sums them from the 2nd")
  line.follow(buttonWidth("Limits..."))
  if p.limitsOn:
    igPushStyleColor_Vec4(ImGui_Col_Button.cint, vec4(t.roles[rlSelection]))
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlAccent]))
  let openLimits = igButton("Limits...", ImVec2_c(x: 0, y: 0))
  if p.limitsOn: igPopStyleColor(2)
  if openLimits: igOpenPopup_Str("##limits", 0)
  marks.mark(name & ".limits")
  tip("The limits (" & (if p.limitsOn: "on" else: "off") & "): click to set them and " &
    "whether they are checked. On, they are drawn on the plots, the points past them " &
    "marked, and a pass or fail table shown per signal; judged on the ground forces " &
    "over the sweep less its tapers")
  if igBeginPopup("##limits", 0):
    if igCheckbox("Check against limits", addr p.limitsOn): changed = true
    marks.mark(name & ".limits.check")
    tip("On: the limits drawn on the plots, the points past them marked, and a pass or " &
      "fail table per signal; judged on the ground forces over the sweep less its tapers")
    igBeginDisabled(not p.limitsOn)
    template limit(text, id: string; field: untyped; unit, what: string) =
      igAlignTextToFramePadding()
      igTextUnformatted(cstring(text), nil)
      marks.mark(name & ".limit " & text)
      igSameLine(0, -1)
      if limitBox(id, p.limits.field, box, typed) and
          not (typed.isNaN and p.limits.field.isNaN) and typed != p.limits.field:
        (p.limits.field, changed) = (typed, true)
      tip(what)
      if unit.len > 0:
        igSameLine(0, -1)
        igTextUnformatted(cstring(unit), nil)
    limit("Phase ±", "##phase", phaseDeg, "°", "The largest |phase| at a point, degrees")
    limit("Phase mean", "##meanphase", meanPhaseDeg, "°", "The largest mean |phase|, degrees")
    limit("THD", "##thd", thdPct, "%", "The largest THD at a point, %")
    limit("THD mean", "##meanthd", meanThdPct, "%", "The largest mean THD, %")
    limit("Harmonic", "##harmonic", harmonicPct, "%",
      "The largest level of any one harmonic at a point, % of the fundamental")
    limit("Force from", "##forcelow", forceLow, "", "The smallest fundamental at a point")
    limit("Force to", "##forcehigh", forceHigh, "", "The largest fundamental at a point")
    limit("Peak force", "##peak", peakForce, "", "The largest peak at a point (the hold-down weight)")
    igEndDisabled()
    igEndPopup()
  if line.drawFreeze(name, PlotFreeze, name & ".freeze", frozen, t, marks):
    frozen = not frozen
    changed = true

proc drawSettings(st: AppState; w: AnalysisWindow; name: string; t: Theme; marks: var Marks;
    res: var PlotWindowsOutput) =
  ## The view's settings, wrapping before the Freeze pin at the right of the
  ## first row; a change is a `ckPlotDisplay`.
  var p = w.params
  var frozen = w.frozen
  var changed = false
  let box = round(igCalcTextSize("00000.0", nil, false, -1).x + 2 * igGetStyle().FramePadding.x)
  var typed = 0.0
  template label(text: string) =
    igAlignTextToFramePadding()
    igTextUnformatted(cstring(text), nil)
    igSameLine(0, -1)
  template unit(text: string) =
    igAlignTextToFramePadding()
    igTextUnformatted(cstring(text), nil)
  template mapCombo() =
    igSetNextItemWidth(round(igCalcTextSize("Red-white-blue", nil, false, -1).x +
      igGetFrameHeight() + 2 * igGetStyle().FramePadding.x))
    if igBeginCombo("##map", ($p.colourMap).cstring, 0):
      for m in ColourMap:
        if igSelectable_Bool(($m).cstring, m == p.colourMap, 0, ImVec2_c(x: 0, y: 0)) and
            m != p.colourMap:
          (p.colourMap, changed) = (m, true)
      igEndCombo()
    marks.mark(name & ".map")
    tip("The colour map, as density's")
  let mapW = round(igCalcTextSize("Red-white-blue", nil, false, -1).x +
    igGetFrameHeight() + 2 * igGetStyle().FramePadding.x)
  if w.view == avVibrator:
    drawVibratorSettings(st, w, name, box, t, marks, p, frozen, changed)
  else:
    let line = beginControlLine()
    case w.view
    of avSpectrogram:
      label("Frame")
      if numberBox("##window", p.windowMs, box, typed) and WindowMsRange.allows(typed):
        (p.windowMs, changed) = (typed, true)
      marks.mark(name & ".frame")
      tip("Each frame's length (a Hann window): longer resolves frequency finer and time " &
        "coarser (a frame of W ms resolves about 2/W kHz)")
      line.follow(textBoxWidth("ms  overlap", box))
      label("ms  overlap")
      if numberBox("##overlap", p.overlap, box, typed) and OverlapRange.allows(typed):
        (p.overlap, changed) = (typed, true)
      marks.mark(name & ".overlap")
      tip("How much a frame overlaps the next, % (0 to 95)")
      line.follow(textBoxWidth("%  floor", box) + igGetStyle().ItemSpacing.x +
        igCalcTextSize("dB", nil, false, -1).x)
      label("%  floor")
      if numberBox("##floor", p.floorDb, box, typed) and FloorDbRange.allows(typed):
        (p.floorDb, changed) = (typed, true)
      marks.mark(name & ".floor")
      tip("The lowest dB drawn: the colour map's low end (0 dB is the largest amplitude)")
      igSameLine(0, -1)
      unit("dB")
      line.follow(mapW)
      mapCombo()
    of avEnvelope: discard
    of avPhase:
      label("Phase where within")
      if numberBox("##within", p.phaseWithinDb, box, typed) and PhaseWithinRange.allows(typed):
        (p.phaseWithinDb, changed) = (typed, true)
      marks.mark(name & ".within")
      tip("The phase is drawn where the amplitude is within this many dB of its peak: " &
        "elsewhere it is noise")
      igSameLine(0, -1)
      unit("dB of the peak")
      line.follow(checkWidth("Unwrapped"))
      if igCheckbox("Unwrapped", addr p.unwrap): changed = true
      marks.mark(name & ".unwrap")
      tip("On: the phase unwrapped along frequency (a delay is a straight line). Off: within " &
        "-180 to 180 degrees")
    of avCorrelation:
      label("Reference: " & (if w.reference.len > 0: w.reference else: "the first trace"))
      let sel = st.selection
      var first = -1
      for tr in sel.selected:
        if first < 0 or tr < first: first = tr
      igBeginDisabled(first < 0)
      if igSmallButton("The selected trace"):
        (p.reference, changed) = (first, true)
      igEndDisabled()
      marks.mark(name & ".reference selected")
      tip("Correlate against the selected trace (the first, when several are): a pilot, in " &
        "this file or another one open (Sweep0's pilot, say)")
      line.follow(buttonWidth("The first auxiliary trace"))
      igBeginDisabled(p.reference < 0)
      if igSmallButton("The first auxiliary trace"):
        (p.reference, changed) = (-1, true)
      igEndDisabled()
      marks.mark(name & ".reference pilot")
      tip("Correlate against the record's first auxiliary trace (its pilot when it is a " &
        "sweep, a time break on a dynamite record), else the first trace of the window")
      line.follow(textBoxWidth("lags ±", box) + igGetStyle().ItemSpacing.x +
        igCalcTextSize("ms", nil, false, -1).x)
      label("lags ±")
      if numberBox("##lags", p.maxLagMs, box, typed) and LagMsRange.allows(typed):
        (p.maxLagMs, changed) = (typed, true)
      marks.mark(name & ".lags")
      tip("The lags shown either side of 0, ms")
      igSameLine(0, -1)
      unit("ms")
    of avFk:
      label("From")
      if limitBox("##from", p.fkFromMs, box, typed) and
          not (typed.isNaN and p.fkFromMs.isNaN) and typed != p.fkFromMs:
        (p.fkFromMs, changed) = (typed, true)
      marks.mark(name & ".from")
      tip("The box's first time, ms (empty: the traces' start)")
      line.follow(textBoxWidth("to", box))
      label("to")
      if limitBox("##to", p.fkToMs, box, typed) and
          not (typed.isNaN and p.fkToMs.isNaN) and typed != p.fkToMs:
        (p.fkToMs, changed) = (typed, true)
      marks.mark(name & ".to")
      tip("The box's last time, ms (empty: the traces' end)")
      line.follow(textBoxWidth("ms  floor", box) + igGetStyle().ItemSpacing.x +
        igCalcTextSize("dB", nil, false, -1).x)
      label("ms  floor")
      if numberBox("##floor", p.floorDb, box, typed) and FloorDbRange.allows(typed):
        (p.floorDb, changed) = (typed, true)
      tip("The lowest dB drawn: the colour map's low end (0 dB is the largest amplitude)")
      igSameLine(0, -1)
      unit("dB")
      line.follow(mapW)
      mapCombo()
      line.follow(checkWidth("Raw"))
      if igCheckbox("Raw", addr p.fkRaw): changed = true
      marks.mark(name & ".raw")
      tip("On: the traces as recorded. Off: through the Seismic window's filters, so the " &
        "effect of a filter shows")
    of avVibrator: discard
    if line.drawFreeze(name, PlotFreeze, name & ".freeze", frozen, t, marks):
      frozen = not frozen
      changed = true
  if changed:
    res.commands.add Command(kind: ckPlotDisplay, plot: w.id, plotParams: p,
      plotFrozen: frozen)

proc colourMapOf(ui: var PlotWindowsUi; m: ColourMap): int =
  ## ImPlot's index of density colour map `m`, added once.
  if ui.maps[m] == 0:
    let name = "viewSEG " & $m
    var index = int(ImPlot_GetColormapIndex(name.cstring))
    if index < 0:
      let lut = lutOf(m)
      var cols = newSeq[ImU32](lut.len)
      for i, c in lut: cols[i] = u32(c)
      index = int(ImPlot_AddColormap_U32Ptr(name.cstring, addr cols[0], cint(cols.len), false))
    ui.maps[m] = index + 1
  ui.maps[m] - 1

proc axisBox(dl: ptr ImDrawList; text: string; across: bool; at: float32; pos,
    area: ImVec2_c; t: Theme): tuple[lo, hi: ImVec2_c] =
  ## `text` in a box on the plot's bottom axis (`across`: centred at x `at`)
  ## or its left axis (centred at y `at`), over the tick labels, as the
  ## Seismic window's cursor writes its time.
  let ts = igCalcTextSize(text.cstring, nil, false, -1)
  var lo, hi: ImVec2_c
  if across:
    lo = ImVec2_c(x: round(at - ts.x / 2) - 3, y: pos.y + area.y + 1)
    hi = ImVec2_c(x: lo.x + ts.x + 6, y: lo.y + ts.y + 4)
  else:
    lo = ImVec2_c(x: pos.x - ts.x - 8, y: round(at - ts.y / 2) - 2)
    hi = ImVec2_c(x: pos.x - 1, y: lo.y + ts.y + 4)
  ImDrawList_AddRectFilled(dl, lo, hi, u32(t.roles[rlWindow]), 0, 0)
  ImDrawList_AddRect(dl, lo, hi, u32(t.roles[rlCrosshair]), 0, 1, 0)
  ImDrawList_AddText_Vec2(dl, ImVec2_c(x: lo.x + 3, y: lo.y + 2), u32(t.roles[rlText]),
    text.cstring, nil)
  (lo, hi)

func axisNumber(x: float64): string =
  if abs(x) >= 100 or x == round(x): formatFloat(x, ffDecimal, 1)
  else: formatFloat(x, ffDecimal, 2)

proc drawImage(ui: var PlotWindowsUi; w: AnalysisWindow; name: string; t: Theme;
    size: ImVec2_c; marks: var Marks; focused: bool; res: var PlotWindowsOutput): string =
  ## The image (a spectrogram) in its colour map with its scale beside, the
  ## cursor's lines and values; what the cursor reads.
  result = ""
  let img = w.result.image
  if img.isEmpty: return
  let scaleW = round(igGetFontSize() * 4.5)
  let cmap = ui.colourMapOf(w.params.colourMap)
  ImPlot_PushColormap_PlotColormap(ImPlotColormap(cmap))
  let x0 = img.x0 - img.dx / 2
  let x1 = img.xOf(img.cols - 1) + img.dx / 2
  let y0 = img.y0 - img.dy / 2
  let y1 = img.yOf(img.rows - 1) + img.dy / 2
  const flags = ImPlot_Flags_NoLegend.cint or ImPlot_Flags_NoMenus.cint or
    ImPlot_Flags_NoMouseText.cint or ImPlot_Flags_NoTitle.cint
  var under = PlotCursor(x: -1, y: -1)
  if ImPlot_BeginPlot(("##" & name).cstring, ImVec2_c(x: max(80, size.x - scaleW), y: size.y),
      flags):
    ImPlot_SetupAxes(img.xLabel.cstring, img.yLabel.cstring, 0, 0)
    ImPlot_SetupAxesLimits(x0, x1, y0, y1, ImPlot_Cond_Once.cint)
    ImPlot_SetupAxisLimitsConstraints(ImAxis_X1.cint, x0, x1)
    ImPlot_SetupAxisLimitsConstraints(ImAxis_Y1.cint, y0, y1)
    let pos = ImPlot_GetPlotPos()
    let area = ImPlot_GetPlotSize()
    # only what is in view, cut to the pixels (the largest value of each bin),
    # redone when the answer, the view or the size changes: never a copy of
    # every cell a frame
    let lim = ImPlot_GetPlotLimits(ImAxis_X1.cint, ImAxis_Y1.cint)
    let view = [lim.X.Min, lim.X.Max, lim.Y.Min, lim.Y.Max]
    let pixels = [max(1, int(area.x)), max(1, int(area.y))]
    if w.id notin ui.heat or ui.heat[w.id].gen != w.result.gen or ui.heat[w.id].view != view or
        ui.heat[w.id].pixels != pixels:
      ui.heat[w.id] = HeatCache(gen: w.result.gen, view: view, pixels: pixels,
        cells: img.reduceImage(view[0], view[1], view[2], view[3], pixels[0], pixels[1]))
    template cut: untyped = ui.heat[w.id].cells
    if cut.cols > 0:
      ImPlot_PlotHeatmap_FloatPtr("##image", addr cut.values[0], cint(cut.rows), cint(cut.cols),
        cdouble(img.lo), cdouble(img.hi), nil, ImPlotPoint_c(x: cut.xMin, y: cut.yMin),
        ImPlotPoint_c(x: cut.xMax, y: cut.yMax), 0)
    marks.markRect(name & ".image", pos, ImVec2_c(x: pos.x + area.x, y: pos.y + area.y))
    if ImPlot_IsPlotHovered():
      let m = ImPlot_GetPlotMousePos(ImAxis_X1.cint, ImAxis_Y1.cint)
      under = img.cellAt(m.x, m.y)
    let c = if w.cursor.held: w.cursor.clamped([img.cols, img.rows]) else: under
    if c.x >= 0:
      let dl = ImPlot_GetPlotDrawList()
      let q = ImPlot_PlotToPixels_double(img.xOf(c.x), img.yOf(c.y), ImAxis_X1.cint,
        ImAxis_Y1.cint)
      let cross = u32(t.roles[rlCrosshair])
      ImDrawList_PushClipRect(dl, pos, ImVec2_c(x: pos.x + area.x, y: pos.y + area.y), true)
      ImDrawList_AddLine(dl, ImVec2_c(x: round(q.x) + 0.5, y: pos.y),
        ImVec2_c(x: round(q.x) + 0.5, y: pos.y + area.y), cross, 1)
      ImDrawList_AddLine(dl, ImVec2_c(x: pos.x, y: round(q.y) + 0.5),
        ImVec2_c(x: pos.x + area.x, y: round(q.y) + 0.5), cross, 1)
      ImDrawList_PopClipRect(dl)
      # on the window's own list, clipped to the window: a window in front hides them
      let wl = igGetWindowDrawList()
      let wp = igGetWindowPos()
      let ws = igGetWindowSize()
      ImDrawList_PushClipRect(wl, wp, ImVec2_c(x: wp.x + ws.x, y: wp.y + ws.y), true)
      let (xlo, xhi) = axisBox(wl, axisNumber(img.xOf(c.x)), true, q.x, pos, area, t)
      let (ylo, yhi) = axisBox(wl, axisNumber(img.yOf(c.y)), false, q.y, pos, area, t)
      ImDrawList_PopClipRect(wl)
      marks.markRect(name & ".cursor x", xlo, xhi)
      marks.markRect(name & ".cursor y", ylo, yhi)
      result = img.readingText(c)
    ImPlot_EndPlot()
  igSameLine(0, -1)
  ImPlot_ColormapScale(("dB##" & name).cstring, cdouble(img.lo), cdouble(img.hi),
    ImVec2_c(x: scaleW - igGetStyle().ItemSpacing.x, y: size.y), "%g", 0, ImPlotColormap(cmap))
  ImPlot_PopColormap(1)
  ui.under[w.id] = under
  # The keys, while the window has the focus: a step from where the cursor
  # is held, else from the cell under the pointer.
  let k = keysNow(focused)
  let move = keyMove(k.up, k.down, k.left, k.right, k.home, k.ending)
  if move != cmNone:
    let start = if w.cursor.held: w.cursor
                elif under.x >= 0: under
                else: PlotCursor()
    res.commands.add Command(kind: ckPlotCursor, plot: w.id,
      plotCursor: start.moved(move, [img.cols, img.rows]))
  elif w.cursor.held and k.escape:
    res.commands.add Command(kind: ckPlotCursor, plot: w.id, plotCursor: PlotCursor())
  if w.cursor.held and under.x >= 0 and igGetIO_Nil().MouseDelta.x != 0:
    # the pointer moved over the image: it takes the cursor back
    res.commands.add Command(kind: ckPlotCursor, plot: w.id, plotCursor: PlotCursor())

proc drawTable(name: string; table: seq[seq[string]]; t: Theme; marks: var Marks) =
  ## A vibrator signature's table: a row per signal, its first the
  ## columns' names; a cell that says "fail" in the error colour.
  let cols = table[0].len
  const flags = ImGui_TableFlags_SizingFixedFit.cint or ImGui_TableFlags_BordersInnerH.cint or
    ImGui_TableFlags_ScrollX.cint
  let h = igGetTextLineHeightWithSpacing() * float32(table.len + 1)
  if igBeginTable(("##table" & name).cstring, cint(cols), flags, ImVec2_c(x: 0, y: h), 0):
    for c in table[0]: igTableSetupColumn(c.cstring, 0, 0, 0)
    igTableHeadersRow()
    for row in table[1 .. ^1]:
      igTableNextRow(0, 0)
      for i, cell in row:
        discard igTableSetColumnIndex(cint(i))
        if cell.startsWith("fail"):
          igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlError]))
          igTextUnformatted(cell.cstring, nil)
          igPopStyleColor(1)
        else:
          igTextUnformatted(cell.cstring, nil)
    igEndTable()
    marks.mark(name & ".table")

proc drawBody(ui: var PlotWindowsUi; st: AppState; w: AnalysisWindow; t: Theme;
    marks: var Marks; res: var PlotWindowsOutput) =
  ## A window's contents: its settings, its words, its plots and reading.
  let name = w.markName
  marks.markWindow(name)
  drawSettings(st, w, name, t, marks, res)
  let r = w.result
  var words = w.label
  if w.filters.len > 0:
    words.add " · filters: " & w.filters
    if r.passedBy > 0: words.add " (" & passedWords(r.passedBy) & ")"
  if r.notDrawn > 0:
    words.add " · " & $r.notDrawn & " more traces not read (the window draws " &
      $MaxAnalysisCurves & ")"
  if r.leftOut > 0: words.add " · " & $r.leftOut & " left out (killed, dead or unreadable)"
  if r.atOtherInterval > 0: words.add " · " & $r.atOtherInterval & " at another interval"
  if w.waiting: words.add " · working it out..."
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextWrapped("%s", words.cstring)
  if r.problem.len > 0: igTextWrapped("%s", ("Nothing to show: " & r.problem).cstring)
  elif r.note.len > 0: igTextWrapped("%s", r.note.cstring)
  igPopStyleColor(1)
  marks.mark(name & ".summary")
  if r.table.len > 1 and w.params.limitsOn and r.problem.len == 0:
    drawTable(name, r.table, t, marks)
  let focused = igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint)
  let lineH = igGetTextLineHeightWithSpacing()
  let avail = igGetContentRegionAvail()
  var text = ""
  if not r.image.isEmpty:
    text = ui.drawImage(w, name, t, ImVec2_c(x: avail.x, y: max(80'f32, avail.y - lineH)),
      marks, focused, res)
  else:
    let plots = r.curvePlots(t)
    var uis = ui.curves.getOrDefault(w.id)
    if uis.len != plots.len: uis.setLen plots.len
    let gap = igGetStyle().ItemSpacing.y
    # Each plot the room shared out, but no lower than nine lines: below
    # that the plots scroll, in a region of their own.
    let room = avail.y - lineH
    var each = (room - gap * float32(max(plots.len - 1, 0))) / float32(max(plots.len, 1))
    let scrolls = each < round(igGetFontSize() * 9)
    var wide = avail.x
    if scrolls:
      each = round(igGetFontSize() * 9)
      discard igBeginChild_Str(("##plots" & name).cstring, ImVec2_c(x: 0, y: max(room, 60)),
        0, 0)
      wide = igGetContentRegionAvail().x
    # The cursor: held by the keys in one plot (and at the same x in the
    # plots that share its x axis), else under the pointer.
    let on = clamp(w.cursorOn, 0, max(plots.len - 1, 0))
    func sameXs(a, b: CurvePlot): bool =
      a.xs.len == b.xs.len and (a.xs.len == 0 or (a.xs[0] == b.xs[0] and a.xs[^1] == b.xs[^1]))
    var hoveredOn = -1
    var under = PlotCursor(x: -1, y: -1)
    var moved = false
    for i, p in plots:
      let key = $w.view & $i & $p.xs.len & (if p.xs.len > 0: $p.xs[0] & $p.xs[^1] else: "")
      let held = if w.cursor.held and plots.len > 0 and (i == on or p.sameXs(plots[on])):
                   PlotCursor(held: true, x: w.cursor.x, y: (if i == on: w.cursor.y else: 0))
                 else: PlotCursor()
      let o = uis[i].drawCurvePlot(name & ".plot " & $i, p, t, ImVec2_c(x: wide, y: each),
        key, marks, held)
      if o.hovered:
        (hoveredOn, under, moved) = (i, o.under, o.moved)
        text = p.readoutText(o.reading)
      elif held.held and i == on:
        text = p.readoutText(o.reading)
    if scrolls: igEndChild()
    ui.curves[w.id] = uis
    if w.cursor.held and text.len > 0: text = HeldNote & text
    # The keys: Left / Right a point, Home / End the ends, Up / Down another
    # curve, from where the cursor is held, else from under the pointer.
    let k = keysNow(focused)
    var move = cmNone
    if k.left: move = cmPrevious
    if k.right: move = cmNext
    if k.home: move = cmFirst
    if k.ending: move = cmLast
    if k.up: move = cmUp
    if k.down: move = cmDown
    let at = if w.cursor.held: on elif hoveredOn >= 0: hoveredOn else: 0
    if move != cmNone and at < plots.len and plots[at].xs.len > 0:
      var start = if w.cursor.held: w.cursor
                  elif hoveredOn >= 0 and under.x >= 0: under
                  else: PlotCursor()
      if start.y < 0: start.y = 0
      res.commands.add Command(kind: ckPlotCursor, plot: w.id, plotCursorOn: at,
        plotCursor: start.moved(move, [plots[at].xs.len, plots[at].curves.len]))
    elif w.cursor.held and (k.escape or (hoveredOn >= 0 and moved)):
      res.commands.add Command(kind: ckPlotCursor, plot: w.id, plotCursor: PlotCursor())
  ui.readout[w.id] = text
  igTextUnformatted((if text.len > 0: text else: " ").cstring, nil)
  marks.mark(name & ".readout")

proc drawPlotWindows*(ui: var PlotWindowsUi; st: AppState; t: Theme; scale: float32;
    marks: var Marks; res: var PlotWindowsOutput) =
  ## The analysis windows, each with its close button; the first time one
  ## of a number is shown, beside the middle of the main window, a step
  ## lower and to the right for each number, inside it (`placement`).
  var ids: seq[int] = @[]
  block:
    let vp = igGetMainViewport()
    marks.markRect("new plots.room", vp.WorkPos, ImVec2_c(x: vp.WorkPos.x + vp.WorkSize.x,
      y: vp.WorkPos.y + vp.WorkSize.y))
  for w in st.plots:
    ids.add w.id
    placeNext(w.id, (if w.view == avVibrator: VibratorSize else: PlotSize), scale)
    if w.id in ui.toFront:
      ui.toFront.excl w.id
      igSetNextWindowFocus()
    var open = true
    if igBegin(w.windowTitle.cstring, addr open, 0):
      ui.drawBody(st, w, t, marks, res)
    igEnd()
    if not open: res.commands.add Command(kind: ckClosePlot, plot: w.id)
  var gone: seq[int] = @[]
  for id in ui.readout.keys:
    if id notin ids: gone.add id
  for id in gone:
    ui.curves.del id
    ui.under.del id
    ui.heat.del id
    ui.readout.del id

func readoutOf*(ui: PlotWindowsUi; id: int): string =
  ## What window `id`'s cursor read last frame; "" for nothing (tests).
  ui.readout.getOrDefault(id, "")

func cellsDrawn*(ui: PlotWindowsUi; id: int): int =
  ## The cells window `id`'s image hands ImPlot to draw (tests).
  if id in ui.heat: ui.heat[id].cells.cols * ui.heat[id].cells.rows else: 0

proc coveredBy*(ui: var PlotWindowsUi; id: int; area: Rect; others: openArray[int]): string =
  ## Which of the other analysis windows `others` is in front of window `id` and
  ## hides part of `area` (where it was drawn); "" when none does. A covered
  ## window is brought forward at the next frame, so that asking again finds it
  ## whole.
  let target = igFindWindowByName(("###newplot-" & $id).cstring)
  if target == nil: return ""
  for o in others:
    if o == id: continue
    let w = igFindWindowByName(("###newplot-" & $o).cstring)
    if w == nil or not w.Active or w.Hidden or not igIsWindowAbove(w, target): continue
    if w.Pos.x < area.pos.x + area.size.x and w.Pos.x + w.Size.x > area.pos.x and
        w.Pos.y < area.pos.y + area.size.y and w.Pos.y + w.Size.y > area.pos.y:
      ui.toFront.incl id
      return "new plot " & $o
  ""
