## Tools > Settings: the Units choice, Metric (the default) or Imperial. What a
## plot shows and what its boxes ask for follow it. What is stored stays in
## SI. An ordinary dockable window.

import std/math
import imguin/cimgui
import ../../core/[firstbreaks, noisearea, state, units]
import ../../view/theme
import icons, marks, style

type
  SettingsUi* = object
    shown*: bool
    placed: bool

const Title = IconSettings & "  Settings###settings"

proc open*(ui: var SettingsUi) =
  ## Shows the window.
  ui.shown = true

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

const NoiseTips: array[NoiseChoice, string] = [
  "The area is found from the record: the first-break model's arrival when there is one, " &
    "else a radius from the offsets or from the header coordinates, else a number of " &
    "stations either side of the source; with none of these every trace is judged. " &
    "The result says which one it used.",
  "The traces whose first break the model puts earlier than this time are left out of the " &
    "judgement. It needs the first-break model: a record without one has every trace judged.",
  "The traces nearer the source than this distance are left out of the judgement, in the " &
    "length unit of the offsets (metres or feet). It needs offsets or coordinates.",
  "The traces within this many stations of the source, along each receiver line, are left " &
    "out of the judgement. Each line is counted on its own: the count never runs onto " &
    "another receiver line."]

proc numberBox(id: string; value: float64; format: string; typed: var float64): bool =
  ## A box for a number that acts as it is typed: true on each change, the value in `typed`.
  var v = cdouble(value)
  igSetNextItemWidth(round(igCalcTextSize("0000000.0", nil, false, -1).x +
    2 * igGetStyle().FramePadding.x))
  result = igInputDouble(id.cstring, addr v, 0, 0, format.cstring, 0)
  typed = float64(v)

proc noModelNote(st: AppState): string =
  ## Why the record shown has no first-break model, when it is known that it has none.
  let k = st.recordQc.key.breaks
  for b in st.firstBreaks:
    if b.key == k and b.state == bkDone and not b.hasModel:
      return "The record shown has no first-break model, so no time can be used there."

proc drawNoiseSettings(st: AppState; s: var NoiseSettings; marks: var Marks; t: Theme): bool =
  ## The noisy-trace test's choice of exclusion area; true when it changed.
  igSeparatorText("Noisy traces: the area left out of the judgement")
  marks.mark("settings.noise")
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextWrapped("Traces near the source are loud, and not noisy. The test leaves them out " &
    "and judges the rest. Choose how that area is set.")
  igPopStyleColor(1)
  var typed = 0.0
  for c in NoiseChoice:
    if igRadioButton_Bool(($c).cstring, s.choice == c) and s.choice != c:
      s.choice = c
      result = true
    marks.mark("settings.noise choice " & NoiseChoiceNames[c])
    tip(NoiseTips[c])
    case c
    of ncAuto: discard
    of ncTime:
      igSameLine(0, -1)
      if numberBox("##noiseTime", s.edgeMs, "%.1f", typed):
        s.edgeMs = typed
        result = true
      marks.mark("settings.noise time")
      tip(NoiseTips[ncTime])
      igSameLine(0, -1)
      igTextUnformatted("ms, on the first-break model", nil)
      let note = noModelNote(st)
      if note.len > 0:
        igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
        igTextWrapped(note.cstring)
        igPopStyleColor(1)
        marks.mark("settings.noise no model")
    of ncRadius:
      igSameLine(0, -1)
      if numberBox("##noiseRadius", s.radius, "%.1f", typed):
        s.radius = typed
        result = true
      marks.mark("settings.noise radius")
      tip(NoiseTips[ncRadius])
      igSameLine(0, -1)
      igTextUnformatted("from the source, in the offsets' unit", nil)
    of ncSteps:
      igSameLine(0, -1)
      if numberBox("##noiseSteps", float64(s.steps), "%.0f", typed):
        s.steps = clamp(int(typed), 0, MaxStations)
        result = true
      marks.mark("settings.noise steps")
      tip(NoiseTips[ncSteps])
      igSameLine(0, -1)
      igTextUnformatted("stations either side of the source", nil)
  igSeparator()
  if igCheckbox("Count on every line, not only the lines the shot reaches", addr s.allLines):
    result = true
  marks.mark("settings.noise all lines")
  tip("For a count of stations: every receiver line is counted on its own. Off, a line " &
    "counts only when the shot is loud on it. The automatic choice falls back to the " &
    "count (default 8) when it has neither a model nor offsets.")
  if s.choice == ncAuto:
    var n = float64(s.steps)
    igTextUnformatted("Fallback count when nothing better is known:", nil)
    igSameLine(0, -1)
    if numberBox("##noiseFallback", n, "%.0f", typed):
      s.steps = clamp(int(typed), 0, MaxStations)
      result = true
    marks.mark("settings.noise fallback steps")
    tip(NoiseTips[ncSteps])
  if igCheckbox("Only inside the template, when a relation file gives one",
      addr s.templateOnly):
    result = true
  marks.mark("settings.noise template only")
  tip("With a relation file, the record's template is the stations it plans for the " &
    "record. Traces outside it are not judged for noise, and do not count in what the " &
    "others are judged against. Off, every trace is judged. Without a relation file " &
    "there is no template, and every trace is judged.")
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextWrapped("Whatever you choose, the components of unrotated nodes are never compared " &
    "across nodes: the hydrophone is judged on its own, and nodes on the energy of their " &
    "motion traces.")
  igPopStyleColor(1)

proc drawSettingsWindow*(ui: var SettingsUi; st: AppState; t: Theme; marks: var Marks):
    seq[Command] =
  ## The window, when it is open. A change of Units is a `ckSettings`.
  if not ui.shown: return
  if not ui.placed:
    let vp = igGetMainViewport()
    igSetNextWindowViewport(vp.ID)
    igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + 220, y: vp.WorkPos.y + 48),
      ImGui_Cond_FirstUseEver.cint, ImVec2_c(x: 0, y: 0))
    igSetNextWindowSize(ImVec2_c(x: 540, y: 520), ImGui_Cond_FirstUseEver.cint)
    ui.placed = true
  var open = true
  if igBegin(Title.cstring, addr open, 0):
    marks.markWindow("settings")
    igTextUnformatted("Units", nil)
    marks.mark("settings.units")
    tip("How the Vibrator window shows masses (kg or lb) and forces (N or lbf), and how a " &
      "mass box reads what you type. What is saved stays in kilograms and newtons. " &
      "Distances, offsets and velocities are not changed by it.")
    var s = st.settings
    var changed = false
    for u in UnitSystem:
      if igRadioButton_Bool(systemName(u).cstring, s.units == u) and s.units != u:
        s.units = u
        changed = true
      marks.mark("settings.unit " & systemName(u))
      tip(if u == usMetric: "Kilograms, metres per second, newtons (the default)"
          else: "Pounds, feet per second, pounds-force")
    if changed: result.add Command(kind: ckSettings, settings: s)
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
    igTextWrapped("Changes masses and forces in the Vibrator window (kg and N, or lb and " &
      "lbf). It does not change distances, offsets or velocities: they always follow the " &
      "file's or the survey's own units.")
    igTextWrapped("A mass box has the same switch beside it. The number converts in place, " &
      "so the mass does not change.")
    igPopStyleColor(1)
    var noise = s.noise
    if drawNoiseSettings(st, noise, marks, t):
      s.noise = noise
      result.add Command(kind: ckSettings, settings: s)
  igEnd()
  if not open: ui.shown = false
