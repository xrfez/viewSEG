## File > Settings: the Units choice, Metric (the default) or Imperial. What a
## plot shows and what its boxes ask for follow it. What is stored stays in
## SI. An ordinary dockable window.

import imguin/cimgui
import ../../core/[state, units]
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

proc drawSettingsWindow*(ui: var SettingsUi; st: AppState; t: Theme; marks: var Marks):
    seq[Command] =
  ## The window, when it is open. A change of Units is a `ckSettings`.
  if not ui.shown: return
  if not ui.placed:
    let vp = igGetMainViewport()
    igSetNextWindowViewport(vp.ID)
    igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + 220, y: vp.WorkPos.y + 48),
      ImGui_Cond_FirstUseEver.cint, ImVec2_c(x: 0, y: 0))
    igSetNextWindowSize(ImVec2_c(x: 420, y: 180), ImGui_Cond_FirstUseEver.cint)
    ui.placed = true
  var open = true
  if igBegin(Title.cstring, addr open, 0):
    marks.markWindow("settings")
    igTextUnformatted("Units", nil)
    marks.mark("settings.units")
    tip("How a plot shows a mass, a force, a velocity, an acceleration or a pressure, " &
      "and how a mass box reads what you type. What is saved stays in kilograms, " &
      "metres and newtons.")
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
    igTextWrapped("A mass box has the same switch beside it. The number converts in place, " &
      "so the mass does not change. An f-k's velocity follows the file's own units when " &
      "the file names them.")
    igPopStyleColor(1)
  igEnd()
  if not open: ui.shown = false
