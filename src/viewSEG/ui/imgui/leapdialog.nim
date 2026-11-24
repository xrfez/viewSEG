## Tools > Leap seconds: the GPS minus UTC table, a leap second to add, the
## date the table is known complete through, and the file it is saved in.
## A floating window. It posts commands; it does not read or write the file.

import std/math
import parseSEG
import imguin/cimgui
import ../../core/[leapfile, state]
import ../../view/[leapwords, theme]
import marks, style

type
  LeapUi* = object
    shown: bool
    bringUp: bool
    year: int32
    month: int32
    step: int32

proc open*(ui: var LeapUi) =
  ## Shows the window. The add fields start at 2027-01-01, step +1, so Apply
  ## can be used without typing; a later open keeps what was typed.
  if ui.year == 0:
    ui.year = 2027
    ui.month = 1
    ui.step = 1
  ui.shown = true
  ui.bringUp = true

proc button(label: string; enabled: bool; marks: var Marks; name: string): bool =
  if not enabled: igBeginDisabled(true)
  result = igButton(label.cstring, ImVec2_c(x: 0, y: 0))
  if not enabled: igEndDisabled()
  marks.mark(name)

proc clamp(n, lo, hi: int32): int32 =
  if n < lo: lo elif n > hi: hi else: n

proc steppedWidth(sample: string): float32 =
  ## An integer box with step buttons, wide enough that `sample` is not clipped.
  let style = igGetStyle()
  let field = igCalcTextSize(sample.cstring, nil, false, -1).x + 2 * style.FramePadding.x
  round(field + 2 * (igGetFrameHeight() + style.ItemInnerSpacing.x))

proc drawLeap*(ui: var LeapUi; st: AppState; t: Theme; marks: var Marks): seq[Command] =
  ## The window, while it is open. Apply, Remove, Reload and Reset post a
  ## command when they can; a candidate that would be refused is dim.
  if not ui.shown: return
  if ui.bringUp:
    igSetWindowFocus_Str(WindowTitle.cstring)
    ui.bringUp = false
  let vp = igGetMainViewport()
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + igGetFontSize() * 4,
    y: vp.WorkPos.y + igGetFontSize() * 2), ImGui_Cond_FirstUseEver.cint, ImVec2_c(x: 0, y: 0))
  igSetNextWindowSize(ImVec2_c(x: igGetFontSize() * 36, y: igGetFontSize() * 32),
    ImGui_Cond_FirstUseEver.cint)
  var open = true
  if igBegin(WindowTitle.cstring, addr open, ImGui_WindowFlags_NoDocking.cint):
    marks.markWindow("leap")
    igPushTextWrapPos(igGetCursorPos().x + igGetFontSize() * 28)
    igTextUnformatted(Intro.cstring, nil)
    igPopTextWrapPos()
    let path = st.leapFilePath()
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
    igPushTextWrapPos(igGetCursorPos().x + igGetFontSize() * 28)
    igTextUnformatted(pathLine(path).cstring, nil)
    igPopTextWrapPos()
    igPopStyleColor(1)
    marks.mark("leap.path")
    igSpacing()
    let table = currentLeapTable()
    igTextUnformatted(("Known complete through " & dateText(table.checkedTo)).cstring, nil)
    marks.mark("leap.checked")
    const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_Borders.cint or
      ImGui_TableFlags_SizingStretchProp.cint or ImGui_TableFlags_ScrollY.cint
    if igBeginTable("##leaps", 2, flags, ImVec2_c(x: 0, y: igGetFontSize() * 8), 0):
      igTableSetupColumn("Date", ImGui_TableColumnFlags_WidthStretch.cint, 0, 0)
      igTableSetupColumn("GPS minus UTC", ImGui_TableColumnFlags_WidthFixed.cint,
        igGetFontSize() * 8, 0)
      igTableHeadersRow()
      for i in countdown(table.entries.high, 0):
        let e = table.entries[i]
        igTableNextRow(0, 0)
        discard igTableNextColumn()
        let date = dateText(LeapDate(year: e.year, month: e.month, day: e.day))
        igTextUnformatted(date.cstring, nil)
        marks.mark("leap.row " & date & " " & $e.gpsMinusUtc)
        discard igTableNextColumn()
        igTextUnformatted(($e.gpsMinusUtc).cstring, nil)
      igEndTable()
    igSeparator()
    igTextUnformatted("Add a leap second", nil)
    igSetNextItemWidth(steppedWidth("0000"))
    if igInputInt("Year##leap".cstring, addr ui.year, 1, 10, 0):
      ui.year = clamp(ui.year, 1972, 2099)
    igSameLine(0, -1)
    igSetNextItemWidth(steppedWidth("00"))
    if igInputInt("Month##leap".cstring, addr ui.month, 1, 1, 0):
      ui.month = clamp(ui.month, 1, 12)
    igSameLine(0, -1)
    if igRadioButton_Bool("+1", ui.step == 1): ui.step = 1
    igSameLine(0, -1)
    if igRadioButton_Bool("-1", ui.step == -1): ui.step = -1
    marks.mark("leap.step")
    let addWhy = addLeapProblem(ui.year, ui.month, ui.step)
    let said = if addWhy.len > 0: addWhy else: AddHelp
    if addWhy.len > 0:
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
    igPushTextWrapPos(igGetCursorPos().x + igGetFontSize() * 28)
    igTextUnformatted(said.cstring, nil)
    igPopTextWrapPos()
    if addWhy.len > 0: igPopStyleColor(1)
    marks.mark("leap.why")
    if button("Apply", addWhy.len == 0, marks, "leap.apply"):
      result.add Command(kind: ckAddLeap, leapYear: ui.year, leapMonth: ui.month,
        leapStep: ui.step)
    igSeparator()
    let removeWhy = removeLeapProblem()
    if button("Remove last", removeWhy.len == 0, marks, "leap.remove"):
      result.add Command(kind: ckRemoveLeap)
    igSameLine(0, -1)
    if button("Reload", path.len > 0, marks, "leap.reload"):
      result.add Command(kind: ckReloadLeaps)
    igSameLine(0, -1)
    if button("Reset", true, marks, "leap.reset"):
      result.add Command(kind: ckResetLeaps)
    igPushTextWrapPos(igGetCursorPos().x + igGetFontSize() * 28)
    igTextUnformatted(NotUndoable.cstring, nil)
    igPopTextWrapPos()
    marks.mark("leap.undo")
  igEnd()
  if not open: ui.shown = false
