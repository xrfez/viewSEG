## The plot window's gain controls, in its strip: the gain type, with its
## own settings in the same drop-down, and the gain amount in dB, which
## every type has (a box, - and + buttons, and keys).
##
## The amount only scales the drawing (`displayScale`), so it acts at once
## and reads nothing again; so does a change between the types that are a
## scale alone. A type whose gain runs on the samples (AGC, Exponential,
## Normalized per trace) reads the view again when it or its settings
## change (`core/panels`, "Display gain"). The clip percentile, the
## drop-down's last setting, never reads the file: the reader takes the
## level again from the samples it holds.

import std/math
import imguin/cimgui
import ../../core/[readout, state]
import ../../view/theme
import chrome

const
  gainTypes = [dgAuto, dgNone, dgFixed, dgNormalized, dgExponential, dgFloat, dgAgc]
  dbKeysTip = "] or keypad * for more, [ or keypad / for less; with Shift, " &
    "12 dB a step"

proc label(d: DisplaySettings; kind: GatherKind): string =
  ## What the type control says: the type in use and its main setting.
  result = case d.effectiveGain(kind)
    of dgAgc: "AGC " & $int(round(d.agcWindowMs)) & " ms"
    of dgNone: "none"
    of dgFixed: "fixed"
    of dgNormalized: "normalized, " & (if d.normScope == perTrace: "each trace" else: "record")
    of dgExponential:
      let shape = if d.timeGain == tgDbPerSecond: significant(d.dbPerS, 3) & " dB/s"
                  else: "t^" & significant(d.power, 3)
      "exponential, " & shape & " to " & $int(round(d.untilMs)) & " ms"
    of dgFloat: "float"
    of dgAuto: "automatic"
  if d.gain == dgAuto: result.add " (auto)"

func describe(g: DisplayGain; d: DisplaySettings): string =
  ## A type as the drop-down lists it.
  case g
  of dgAuto: "Automatic: AGC on shot and receiver records, none on stacked data"
  of dgNone: "None: the samples as recorded, one scale for the record"
  of dgFixed: "Fixed: one scale for every record and file, so they compare"
  of dgNormalized: "Normalized: every trace, or the record, to the same level"
  of dgExponential: "Exponential: more gain later in the record"
  of dgFloat: "Float: the scale follows the data in view"
  of dgAgc: "AGC: automatic gain control, " & $int(round(d.agcWindowMs)) & " ms window"

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc send(p: Panel; d: DisplaySettings; cmds: var seq[Command]) =
  cmds.add Command(kind: ckDisplay, panel: p.id, display: d)

proc numberBox(id: string; value: float64; format: string; width: float32;
    typed: var float64): bool =
  ## A box for a number: true once the user has finished typing into it
  ## (Enter, or clicking away), the value in `typed`.
  var v = cdouble(value)
  igSetNextItemWidth(width)
  discard igInputDouble(id.cstring, addr v, 0, 0, format.cstring, 0)
  typed = float64(v)
  igIsItemDeactivatedAfterEdit()

func clipSource(p: Panel; d: DisplaySettings): string =
  ## What the clip percentile is taken of, under the type `d` shows `p`'s
  ## gather with; "" when the type does not use it.
  case d.effectiveGain(p.kind)
  of dgFloat: "of the data in view"
  of dgNormalized:
    if d.normStat != normPercentile: ""
    elif d.normScope == perTrace: "of each trace"
    else: "of the record"
  of dgFixed: "of the record, for From this record"
  else: "of the record"

proc drawClip(p: Panel; d: DisplaySettings; marks: var Marks; cmds: var seq[Command];
    notes: var seq[string]) =
  ## The clip percentile: a box, what it is taken of, and the amplitude it
  ## gives now (drawn at full scale at 0 dB: the colour map's ends, a
  ## wiggle's full swing).
  igSeparatorText("Clip")
  let source = clipSource(p, d)
  igTextUnformatted("Full scale at the", nil)
  igSameLine(0, -1)
  var typed = 0.0
  let w = round(igCalcTextSize("000.00", nil, false, -1).x + 2 * igGetStyle().FramePadding.x)
  if numberBox("##clippercentile", d.clipPercentile, "%.4g", w, typed) and
      typed != d.clipPercentile:
    if typed >= MinClipPercentile and typed <= 100:
      var nd = d
      nd.clipPercentile = typed
      p.send(nd, cmds)
    else:
      notes.add "The clip percentile needs " & significant(MinClipPercentile) & " to 100, not " &
        significant(typed) & "."
  marks.mark("plot.gain clip percentile")
  tip("The percentile of |x| drawn at full scale at 0 dB (the colour map's ends: black and " &
    "white in grey, blue and red in red-white-blue; a wiggle's full swing): 98 clips harder " &
    "than 99, 100 is the " &
    "peak (" & significant(MinClipPercentile) & " to 100). A new value reads nothing from " &
    "the file.")
  igSameLine(0, -1)
  let what = if source.len == 0: "th percentile of |x| (not used: the " &
                 (if d.normStat == normRms: "RMS" else: "peak") & " is)"
             else: "th percentile of |x| " & source
  igTextUnformatted(what.cstring, nil)
  let r = p.reference
  if source.len > 0 and not (d.effectiveGain(p.kind) == dgNormalized and
      d.normScope == perTrace) and d.effectiveGain(p.kind) != dgFixed:
    let now = if r > 0 and r < Inf: "|x| = " & significant(r, 4) else: "not known yet"
    igTextUnformatted(("Now: " & now).cstring, nil)
    marks.mark("plot.gain clip amplitude")

proc settings(p: Panel; d: DisplaySettings; marks: var Marks; cmds: var seq[Command];
    notes: var seq[string]) =
  ## The settings of the type in use, under the list of types; each control
  ## is marked "plot.gain <what>" for tests.
  let w = round(igCalcTextSize("000000.00", nil, false, -1).x + 2 * igGetStyle().FramePadding.x)
  let pct = significant(d.clipPercentile, 3) & "th percentile"
  var typed = 0.0
  var nd = d
  case d.effectiveGain(p.kind)
  of dgAgc:
    igTextUnformatted("Window", nil)
    igSameLine(0, -1)
    if numberBox("##agcwindow", d.agcWindowMs, "%.0f", w, typed):
      if typed >= 10 and typed <= 20_000:
        nd.agcWindowMs = typed
        p.send(nd, cmds)
      else: notes.add "The AGC window needs 10 to 20 000 ms, not " & significant(typed) & "."
    marks.mark("plot.gain agc window")
    igSameLine(0, -1)
    igTextUnformatted("ms", nil)
    if d.gain == dgAuto:
      igTextUnformatted("Stacked data is shown with no gain.", nil)
  of dgNone:
    igTextUnformatted(("Amplitudes past the record's " & pct & " of |x|\n" &
      "are drawn at full scale (the colour map's ends).").cstring, nil)
  of dgFixed:
    igTextUnformatted("Full scale at |x| =", nil)
    igSameLine(0, -1)
    if numberBox("##fixedclip", d.fixedClip, "%.4g", w, typed):
      if typed > 0 and typed < Inf:
        nd.fixedClip = typed
        p.send(nd, cmds)
      else: notes.add "The fixed gain needs a positive amplitude, not " & significant(typed) & "."
    marks.mark("plot.gain fixed amplitude")
    igSameLine(0, -1)
    if igButton("From this record", ImVec2_c(x: 0, y: 0)):
      nd.fixedClip = NaN # core takes it from the record shown
      p.send(nd, cmds)
    marks.mark("plot.gain from this record")
    tip("Takes the " & pct & " of |x| of the record shown")
    igTextUnformatted("Kept for every record and file until changed.", nil)
  of dgNormalized:
    for (scope, text) in [(perTrace, "Each trace"), (perPanel, "The whole record")]:
      if igRadioButton_Bool(text.cstring, d.normScope == scope) and d.normScope != scope:
        nd.normScope = scope
        p.send(nd, cmds)
      marks.mark("plot.gain " & $scope)
      if scope == perTrace: igSameLine(0, -1)
    igTextUnformatted("to its", nil)
    for (stat, text) in [(normRms, "RMS"), (normMax, "peak"), (normPercentile, pct)]:
      igSameLine(0, -1)
      if igRadioButton_Bool(text.cstring, d.normStat == stat) and d.normStat != stat:
        nd.normStat = stat
        p.send(nd, cmds)
      marks.mark("plot.gain " & $stat)
    igTextUnformatted("drawn at full scale.", nil)
  of dgExponential:
    if igRadioButton_Bool("dB per second", d.timeGain == tgDbPerSecond) and
        d.timeGain != tgDbPerSecond:
      nd.timeGain = tgDbPerSecond
      p.send(nd, cmds)
    marks.mark("plot.gain " & $tgDbPerSecond)
    igSameLine(0, -1)
    if numberBox("##dbpers", d.dbPerS, "%.1f", w, typed):
      if abs(typed) <= 60:
        nd.dbPerS = typed
        nd.timeGain = tgDbPerSecond
        p.send(nd, cmds)
      else: notes.add "The exponential gain needs -60 to 60 dB/s, not " & significant(typed) & "."
    marks.mark("plot.gain dB per second box")
    if igRadioButton_Bool("Power of time, t^", d.timeGain == tgPower) and d.timeGain != tgPower:
      nd.timeGain = tgPower
      p.send(nd, cmds)
    marks.mark("plot.gain " & $tgPower)
    igSameLine(0, -1)
    if numberBox("##power", d.power, "%.2f", w, typed):
      if abs(typed) <= 5:
        nd.power = typed
        nd.timeGain = tgPower
        p.send(nd, cmds)
      else: notes.add "The power of time needs -5 to 5, not " & significant(typed) & "."
    marks.mark("plot.gain power box")
    igTextUnformatted("Until", nil)
    igSameLine(0, -1)
    if numberBox("##until", d.untilMs, "%.0f", w, typed):
      if typed >= MinUntilMs and typed <= MaxUntilMs:
        nd.untilMs = typed
        p.send(nd, cmds)
      else:
        notes.add "The exponential gain's cutoff needs " & significant(MinUntilMs) & " to " &
          significant(MaxUntilMs) & " ms, not " & significant(typed) & "."
    marks.mark("plot.gain until")
    tip("The gain rises until this time and holds its value after it, so late times " &
      "(the basement) are not blown out")
    igSameLine(0, -1)
    igTextUnformatted("ms, then held", nil)
  of dgFloat:
    igTextUnformatted(("Amplitudes past the " & pct & " of |x| of the data in view\n" &
      "are drawn at full scale (the colour map's ends), so the scale changes as you pan " &
      "and zoom.").cstring, nil)
  of dgAuto: discard # effectiveGain never gives it
  drawClip(p, d, marks, cmds, notes)

proc drawGainControls*(p: Panel; t: Theme; marks: var Marks; cmds: var seq[Command];
    notes: var seq[string]) =
  ## The gain type's drop-down (its settings in it), then the gain amount:
  ## -, a box in dB, +.
  let d = p.layers[0].display
  let text = "Gain: " & label(d, p.kind)
  let style = igGetStyle()
  igSetNextItemWidth(round(igCalcTextSize(text.cstring, nil, false, -1).x +
    igGetFrameHeight() + 3 * style.FramePadding.x))
  if igBeginCombo("##gain", text.cstring, ImGui_ComboFlags_HeightLargest.cint):
    for gt in gainTypes:
      # the drop-down stays open, so the type's settings can be set at once
      if igSelectable_Bool(describe(gt, d).cstring, d.gain == gt,
          ImGui_SelectableFlags_NoAutoClosePopups.cint, ImVec2_c(x: 0, y: 0)) and d.gain != gt:
        var nd = d
        nd.gain = gt
        p.send(nd, cmds)
      marks.mark("plot.gain type " & $gt)
    igSeparatorText("Settings")
    settings(p, d, marks, cmds, notes)
    igEndCombo()
  marks.mark("plot.gain")
  tip("Gain type: how amplitudes are scaled for display. Its settings are in this list.")
  # the amount: the buttons repeat while held, 12 dB a step with Shift
  let step = if igGetIO_Nil().KeyShift: GainShiftStepDb else: GainStepDb
  igSameLine(0, 8)
  igPushItemFlag(ImGui_ItemFlags_ButtonRepeat.cint, true)
  if igButton("-##gainless", ImVec2_c(x: 0, y: 0)):
    p.send(d.withGainDb(d.gainDb - step), cmds)
  marks.mark("plot.gain less")
  tip("Less gain, " & significant(GainStepDb, 2) & " dB; held, it repeats (" & dbKeysTip & ")")
  igSameLine(0, 2)
  var db = cdouble(d.gainDb)
  igSetNextItemWidth(round(igCalcTextSize("+000.0", nil, false, -1).x + 2 * style.FramePadding.x))
  if igInputDouble("##gaindb", addr db, 0, 0, "%+.1f", 0) and float64(db) != d.gainDb:
    p.send(d.withGainDb(float64(db)), cmds) # live: a scale only, nothing is read
  marks.mark("plot.gain dB")
  tip("Gain amount in dB, -" & significant(MaxGainDb) & " to +" & significant(MaxGainDb) &
    ", on top of any gain type: it rescales the display at once (" & dbKeysTip & ")")
  igSameLine(0, 2)
  if igButton("+##gainmore", ImVec2_c(x: 0, y: 0)):
    p.send(d.withGainDb(d.gainDb + step), cmds)
  marks.mark("plot.gain more")
  tip("More gain, " & significant(GainStepDb, 2) & " dB; held, it repeats (" & dbKeysTip & ")")
  igPopItemFlag()
  igSameLine(0, 4)
  igTextUnformatted("dB", nil)

proc gainKeys*(p: Panel; cmds: var seq[Command]) =
  ## The gain amount's keys, while the plot window has the focus: `]` or
  ## keypad `*` for more, `[` or keypad `/` for less, repeating while held;
  ## with Shift, 12 dB a step.
  template pressed(key: untyped; mods = 0): bool =
    igShortcut_Nil(cint(mods) or key.cint, ImGui_InputFlags_Repeat.cint)
  let d = p.layers[0].display
  var db = 0.0
  for (mods, step) in [(0, GainStepDb), (ImGui_Mod_Shift.int, GainShiftStepDb)]:
    if pressed(ImGui_Key_RightBracket, mods) or pressed(ImGui_Key_KeypadMultiply, mods):
      db += step
    if pressed(ImGui_Key_LeftBracket, mods) or pressed(ImGui_Key_KeypadDivide, mods):
      db -= step
  if db != 0:
    p.send(d.withGainDb(d.gainDb + db), cmds)
