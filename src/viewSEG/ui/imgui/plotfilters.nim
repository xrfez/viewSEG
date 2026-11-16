## The plot window's filters, in its strip: a button one icon wide, lit while
## they are applied (drawn in the warning colour, not lit, when they are set
## but reach none of the traces shown: auxiliary traces alone with the Aux
## box off), whose drop-down says what the traces go through and
## holds every setting (DC removal, the pass band's corners, notches, the
## Aux traces), and a Raw toggle beside it that shows
## the traces without the filters (`P`). Every change goes to `core` as it
## is made (`ckProcessing`): a slider moved sends a command each frame, the
## panel's reader filters the samples it holds again off this thread, and
## the plot keeps what it drew until the new tile comes (`core/processing`).

import std/[math, strutils]
import imguin/cimgui
import ../../core/state
import ../../view/theme
import chrome, icons, plotsort, style

const
  bandNames: array[PassBand, string] = ["None", "Low-cut", "High-cut", "Band-pass"]
  dcNames: array[DcRemoval, string] = ["None", "Mean", "Mean and trend"]
  rawKeyTip = "P toggles raw and processed while the plot has the focus"

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc send(p: Panel; pr: Processing; cmds: var seq[Command]) =
  cmds.add Command(kind: ckProcessing, panel: p.id, processing: pr)

func label*(pr: Processing): string =
  ## What the filters' tooltip and drop-down say: "Filters: 4-8-60-80 Hz",
  ## "Filters: none", and "(raw)" while they are not applied.
  if not pr.hasFilters: return "Filters: none"
  result = "Filters: " & describe(pr)
  if pr.raw: result.add " (raw)"

proc hertz(id: string; value: var float64; lo, hi: float64; width: float32): bool =
  ## A slider in Hz from `lo` to `hi` (logarithmic: a low-cut's corners
  ## move finely), Ctrl + click to type; true while it changes.
  var v = cdouble(value)
  var a = cdouble(lo)
  var b = cdouble(max(hi, lo))
  igSetNextItemWidth(width)
  result = igSliderScalar(id.cstring, ImGui_DataType_Double.ImGuiDataType, addr v, addr a,
    addr b, "%.1f Hz", (ImGui_SliderFlags_Logarithmic.cint or
    ImGui_SliderFlags_AlwaysClamp.cint).ImGuiSliderFlags)
  if result: value = float64(v)

func reachText*(reach: FilterReach): string =
  ## What the filters' tooltip and drop-down say of the traces they do not
  ## reach; "" when they reach every one shown.
  case reach
  of frNoTrace: "They reach none of the traces shown: every one is auxiliary, and " &
    "\"Filter the Aux traces too\" is off."
  of frSeismic: "The auxiliary traces shown are not filtered: \"Filter the Aux traces " &
    "too\" is off."
  of frNone, frAll: ""

proc drawSettings(p: Panel; pr: Processing; hasAux: bool; reach: FilterReach;
    t: Theme; marks: var Marks; cmds: var seq[Command]) =
  ## The settings in the drop-down; each control is marked "plot.filters
  ## <what>" for tests.
  let dt = p.layout.dtMs
  let nyq = if dt > 0 and dt < Inf: 500 / dt else: MaxFilterHz
  let w = round(igGetFontSize() * 16)
  var n = pr
  igSeparatorText("DC removal")
  for dc in DcRemoval:
    if dc != DcRemoval.low: igSameLine(0, -1)
    if igRadioButton_Bool((dcNames[dc] & "##dc").cstring, pr.dc == dc) and pr.dc != dc:
      n.dc = dc
      p.send(n, cmds)
    marks.mark("plot.filters dc " & $dc)
  tip("Taken off each trace before the filter: its mean, or its mean and linear trend")
  igSeparatorText("Pass band")
  for b in PassBand:
    if b != PassBand.low: igSameLine(0, -1)
    if igRadioButton_Bool((bandNames[b] & "##band").cstring, pr.band == b) and pr.band != b:
      n.band = b
      p.send(n, cmds)
    marks.mark("plot.filters band " & $b)
  let half = round(w / 2)
  let lead = round(igCalcTextSize("High-cut", nil, false, -1).x + 2 * igGetStyle().ItemSpacing.x)
  template rampLabel(text: string) =
    igAlignTextToFramePadding()
    igTextUnformatted(text, nil)
    igSameLine(lead, -1)
  if pr.band.hasLow:
    rampLabel("Low-cut")
    if hertz("##f1", n.f1, 0, min(pr.f2, nyq) - MinRampHz, half): p.send(n, cmds)
    marks.mark("plot.filters f1")
    tip("f1: the gain is 0 below this frequency (Ctrl + click to type it)")
    igSameLine(0, -1)
    igTextUnformatted("to", nil)
    igSameLine(0, -1)
    if hertz("##f2", n.f2, pr.f1 + MinRampHz, if pr.band.hasHigh: min(pr.f3, nyq) else: nyq,
        half):
      p.send(n, cmds)
    marks.mark("plot.filters f2")
    tip("f2: the gain is 1 above this frequency, rising from f1 as a cos² ramp")
  if pr.band.hasHigh:
    rampLabel("High-cut")
    if hertz("##f3", n.f3, if pr.band.hasLow: pr.f2 else: MinRampHz,
        min(pr.f4, nyq) - MinRampHz, half):
      p.send(n, cmds)
    marks.mark("plot.filters f3")
    tip("f3: the gain is 1 below this frequency (Ctrl + click to type it)")
    igSameLine(0, -1)
    igTextUnformatted("to", nil)
    igSameLine(0, -1)
    if hertz("##f4", n.f4, pr.f3 + MinRampHz, nyq, half): p.send(n, cmds)
    marks.mark("plot.filters f4")
    tip("f4: the gain is 0 above this frequency, falling from f3 as a cos² ramp; " &
      "Nyquist is " & formatFloat(nyq, ffDecimal, 1) & " Hz")
  igSeparatorText("Notches")
  for i, notch in pr.notches:
    igPushID_Int(cint(i))
    var on = notch.on
    if igCheckbox("##on", addr on):
      n.notches[i].on = on
      p.send(n, cmds)
    marks.mark("plot.filters notch " & $i & " on")
    tip("This notch on or off")
    igSameLine(0, -1)
    igTextUnformatted("at", nil)
    igSameLine(0, -1)
    if hertz("##hz", n.notches[i].hz, 1, nyq, round(w * 0.5)): p.send(n, cmds)
    marks.mark("plot.filters notch " & $i & " hz")
    tip("The notch's frequency: the gain is 0 there")
    igSameLine(0, -1)
    igTextUnformatted("width", nil)
    igSameLine(0, -1)
    if hertz("##width", n.notches[i].widthHz, MinNotchWidthHz, 20, round(w * 0.4)):
      p.send(n, cmds)
    marks.mark("plot.filters notch " & $i & " width")
    tip("The notch's width: the gain is 1 again half of it away")
    igSameLine(0, -1)
    var h = cint(notch.harmonics)
    igSetNextItemWidth(round(w * 0.3))
    if igSliderInt("##harmonics", addr h, 1, cint(MaxHarmonics), "x%d", 0.ImGuiSliderFlags):
      n.notches[i].harmonics = int(h)
      p.send(n, cmds)
    marks.mark("plot.filters notch " & $i & " harmonics")
    tip("Notched at this many multiples of the frequency (x1: the frequency alone; " &
      "x3 at 60 Hz: 60, 120 and 180 Hz), below Nyquist")
    igSameLine(0, -1)
    if igSmallButton("Remove"):
      n.notches.delete(i)
      p.send(n, cmds)
    marks.mark("plot.filters notch " & $i & " remove")
    igPopID()
  igBeginDisabled(pr.notches.len >= MaxNotches)
  for hz in NotchPresets:
    if igButton(("+ " & $int(hz) & " Hz").cstring, ImVec2_c(x: 0, y: 0)):
      n.notches.add NotchFilter(hz: hz, harmonics: 3)
      p.send(n, cmds)
    marks.mark("plot.filters notch add " & $int(hz))
    tip("A notch at " & $int(hz) & " Hz and its next two harmonics: power-line hum")
    igSameLine(0, -1)
  if igButton("+ Notch", ImVec2_c(x: 0, y: 0)):
    n.notches.add NotchFilter()
    p.send(n, cmds)
  marks.mark("plot.filters notch add")
  igEndDisabled()
  igSeparatorText("Traces")
  var aux = pr.aux
  igBeginDisabled(not hasAux)
  if igCheckbox("Filter the Aux traces too", addr aux):
    n.aux = aux
    p.send(n, cmds)
  igEndDisabled()
  marks.mark("plot.filters aux")
  tip(if hasAux: "Off: the auxiliary traces (time breaks, pilots) are shown as recorded"
      else: "This record has no auxiliary traces")
  let unreached = reachText(reach)
  if unreached.len > 0:
    igPushTextWrapPos(w * 2.5)
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
    igTextWrapped("%s", unreached.cstring)
    igPopStyleColor(1)
    igPopTextWrapPos()
    marks.mark("plot.filters reach")
  let note = pr.filterNote(p.layout)
  if note.len > 0:
    igPushTextWrapPos(w * 2.5)
    igTextDisabled("%s", note.cstring)
    igPopTextWrapPos()
  if igButton("No filters", ImVec2_c(x: 0, y: 0)):
    p.send(Processing(aux: pr.aux), cmds)
  marks.mark("plot.filters none")
  tip("Takes every filter away (the corners and notches start from their defaults again)")

const filtersId = "##filterspopup"

proc drawFilterControls*(p: Panel; hasAux: bool; reach: FilterReach; t: Theme;
    marks: var Marks; cmds: var seq[Command]) =
  ## The filters' button, lit while they are applied, which opens their
  ## drop-down (what they are, then their settings), then the Raw toggle.
  ## The button is one icon wide whatever the filters are, so the strip
  ## keeps its lines: what they are is in its tooltip and the drop-down.
  ## Set but reaching none of the traces shown (`reach`), it is not lit but
  ## drawn in the warning colour, and both say why.
  let pr = p.layers[0].processing
  let text = label(pr)
  let unreached = reach == frNoTrace
  if unreached: igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
  if toggle(IconFilter & "##filters", pr.filtering and not unreached, t):
    igOpenPopup_Str(filtersId, 0)
  if unreached: igPopStyleColor(1)
  let below = ImVec2_c(x: igGetItemRectMin().x, y: igGetItemRectMax().y)
  marks.mark("plot.filters")
  let why = reachText(reach)
  tip(text & (if why.len > 0: "\n" & why else: "") &
    "\nWhat the traces go through before the gain (DC removal, low-cut, " &
    "high-cut, band-pass, notches): click to set them. The plot follows as you do.")
  igSetNextWindowPos(below, ImGui_Cond_Appearing.cint, ImVec2_c(x: 0, y: 0))
  if igBeginPopup(filtersId, 0):
    marks.markWindow("plot.filters popup")
    igTextUnformatted(text.cstring, nil)
    marks.mark("plot.filters says")
    # the sliders' tracks and the boxes stand out from the popup they are on
    let raised = vec4(mix(t.roles[rlFrame], t.roles[rlText], 0.12))
    igPushStyleColor_Vec4(ImGui_Col_FrameBg.cint, raised)
    igPushStyleColor_Vec4(ImGui_Col_Button.cint, raised)
    drawSettings(p, pr, hasAux, reach, t, marks, cmds)
    igPopStyleColor(2)
    igEndPopup()
  igSameLine(0, 2)
  igBeginDisabled(not pr.hasFilters)
  if toggle("Raw##filtersraw", pr.raw and pr.hasFilters, t):
    var n = pr
    n.raw = not pr.raw
    p.send(n, cmds)
  igEndDisabled()
  marks.mark("plot.filters raw")
  tip(if not pr.hasFilters: "Raw: no filter is set, so the traces are shown as recorded"
      elif pr.raw: "Raw (on): the traces without the filters, under the same gain; " &
        "click to see them filtered (" & rawKeyTip & ")"
      else: "Raw (off): click to see the traces without the filters, under the same " &
        "gain (" & rawKeyTip & ")")

const ownId = "##ownfilter"

proc drawOwnFilter*(draft: var OwnFilter; mixed: bool; n: int; dtMs: float64;
    pos: ImVec2_c; marks: var Marks): bool =
  ## The popover that sets a trace's own filter: the plot's filter controls,
  ## in the same order and words, then whether it runs after the plot's
  ## filters or instead of them, then Apply. True when Apply is clicked.
  ## Aux and Raw are the plot's switches, not a trace's, so they are not here.
  if not igBeginPopup(ownId, 0): return false
  marks.markWindow("plot.ownfilter popup")
  let title = if n == 1: "Filter this trace" else: "Filter " & $n & " traces"
  igTextUnformatted(title.cstring, nil)
  if mixed:
    igTextDisabled("the selected traces have different filters")
    marks.mark("plot.ownfilter mixed")
    marks.mark("plot.ownfilter mixed the selected traces have different filters")
  let dt = dtMs
  let nyq = if dt > 0 and dt < Inf: 500 / dt else: MaxFilterHz
  let w = round(igGetFontSize() * 16)
  var pr = draft.spec
  igSeparatorText("DC removal")
  for dc in DcRemoval:
    if dc != DcRemoval.low: igSameLine(0, -1)
    if igRadioButton_Bool((dcNames[dc] & "##odc").cstring, pr.dc == dc) and pr.dc != dc:
      pr.dc = dc
    marks.mark("plot.ownfilter dc " & $dc)
  igSeparatorText("Pass band")
  for b in PassBand:
    if b != PassBand.low: igSameLine(0, -1)
    if igRadioButton_Bool((bandNames[b] & "##oband").cstring, pr.band == b) and pr.band != b:
      pr.band = b
    marks.mark("plot.ownfilter band " & $b)
  let half = round(w / 2)
  let lead = round(igCalcTextSize("High-cut", nil, false, -1).x + 2 * igGetStyle().ItemSpacing.x)
  template rampLabel(text: string) =
    igAlignTextToFramePadding()
    igTextUnformatted(text, nil)
    igSameLine(lead, -1)
  if pr.band.hasLow:
    rampLabel("Low-cut")
    discard hertz("##of1", pr.f1, 0, min(pr.f2, nyq) - MinRampHz, half)
    marks.mark("plot.ownfilter f1")
    igSameLine(0, -1)
    igTextUnformatted("to", nil)
    igSameLine(0, -1)
    discard hertz("##of2", pr.f2, pr.f1 + MinRampHz, if pr.band.hasHigh: min(pr.f3, nyq) else: nyq,
      half)
    marks.mark("plot.ownfilter f2")
  if pr.band.hasHigh:
    rampLabel("High-cut")
    discard hertz("##of3", pr.f3, if pr.band.hasLow: pr.f2 else: MinRampHz,
      min(pr.f4, nyq) - MinRampHz, half)
    marks.mark("plot.ownfilter f3")
    igSameLine(0, -1)
    igTextUnformatted("to", nil)
    igSameLine(0, -1)
    discard hertz("##of4", pr.f4, pr.f3 + MinRampHz, nyq, half)
    marks.mark("plot.ownfilter f4")
  igSeparatorText("Notches")
  var drop = -1
  for i, notch in pr.notches:
    igPushID_Int(cint(i))
    var on = notch.on
    if igCheckbox("##on", addr on): pr.notches[i].on = on
    marks.mark("plot.ownfilter notch " & $i & " on")
    igSameLine(0, -1)
    igTextUnformatted("at", nil)
    igSameLine(0, -1)
    discard hertz("##hz", pr.notches[i].hz, 1, nyq, round(w * 0.5))
    igSameLine(0, -1)
    igTextUnformatted("width", nil)
    igSameLine(0, -1)
    discard hertz("##width", pr.notches[i].widthHz, MinNotchWidthHz, 20, round(w * 0.4))
    igSameLine(0, -1)
    var h = cint(notch.harmonics)
    igSetNextItemWidth(round(w * 0.3))
    if igSliderInt("##harmonics", addr h, 1, cint(MaxHarmonics), "x%d", 0.ImGuiSliderFlags):
      pr.notches[i].harmonics = int(h)
    igSameLine(0, -1)
    if igSmallButton("Remove"): drop = i
    igPopID()
  if drop >= 0: pr.notches.delete(drop)
  igBeginDisabled(pr.notches.len >= MaxNotches)
  for hz in NotchPresets:
    if igButton(("+ " & $int(hz) & " Hz").cstring, ImVec2_c(x: 0, y: 0)):
      pr.notches.add NotchFilter(hz: hz, harmonics: 3)
    igSameLine(0, -1)
  if igButton("+ Notch", ImVec2_c(x: 0, y: 0)): pr.notches.add NotchFilter()
  igEndDisabled()
  if igButton("Clear", ImVec2_c(x: 0, y: 0)):
    pr = Processing()
    draft.place = fpAfter
  marks.mark("plot.ownfilter clear")
  tip("Clear the controls, and run after the plot's filters")
  igSeparatorText("When")
  if igRadioButton_Bool("After the plot's filters", draft.place == fpAfter):
    draft.place = fpAfter
  marks.mark("plot.ownfilter after")
  if igRadioButton_Bool("Instead of the plot's filters", draft.place == fpInstead):
    draft.place = fpInstead
  marks.mark("plot.ownfilter instead")
  draft.spec = pr
  igSeparator()
  if igButton("Cancel", ImVec2_c(x: 0, y: 0)): igCloseCurrentPopup()
  marks.mark("plot.ownfilter cancel")
  tip("Close without changing the trace's filter")
  igSameLine(0, -1)
  result = igButton("Apply", ImVec2_c(x: 0, y: 0))
  marks.mark("plot.ownfilter apply")
  tip("Set this filter on the traces. With nothing set and \"After the plot's filters\", " &
    "it takes the trace's filter away")
  if result: igCloseCurrentPopup()
  igEndPopup()

proc openOwnFilter*() =
  ## Opens the trace-filter popover. Called the frame after the menu item.
  igOpenPopup_Str(ownId, 0)

proc filterKeys*(p: Panel; cmds: var seq[Command]) =
  ## `P`, while the plot window has the focus: raw or processed.
  let pr = p.layers[0].processing
  if not igGetIO_Nil().WantTextInput and pr.hasFilters and
      igShortcut_Nil(ImGui_Key_P.cint, 0):
    var n = pr
    n.raw = not pr.raw
    p.send(n, cmds)
