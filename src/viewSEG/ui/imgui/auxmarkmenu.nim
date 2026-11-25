## The plot menu's group for an auxiliary trace: whether the trace is correlated, in this
## file or in the project, and the shift before it is. An auxiliary trace is correlated only
## when its position (from 1 among a record's auxiliary traces) is marked; the file's mark
## wins over the project's. A click sends `ckFileAuxMark` or `ckProjectAuxMark`.

import std/[math, parseutils, sequtils, strutils]
import imguin/cimgui
import ../../core/[edits, state]
import marks

const
  AuxMarkHint* = "Right-click an auxiliary trace and mark it for correlation."
    ## what to do when a file of auxiliary traces has none marked
  ShiftTip = "The marked trace is moved later by this many milliseconds before it is " &
    "correlated, so a pilot's wavelet shows its start; 500 ms is usual for a pilot."
  NeedProject = "Open a project that can be written to keep a mark in it."
  popId = "##auxshift"

type
  AuxMarkUi* = object
    ## The group's own state: the shift popover asked for, and what it edits.
    ask: bool    ## the menu asked for the popover: open it next frame
    active: bool ## the popover is being drawn
    position: int
    file: string
    text: array[32, char]
    pos: ImVec2_c

  InForce* = object
    ## What decides whether an auxiliary position is correlated.
    marked*: bool
    ms*: float64
    byFile*: bool ## the file's entry decides (marked or not)

func anyMarked*(file, project: openArray[AuxMarkEntry]): bool =
  ## Whether any position is correlated by the file's marks or, where the file has no entry,
  ## the project's.
  for e in file:
    if e.marked: return true
  for e in project:
    if e.marked and not file.anyIt(it.position == e.position): return true

func inForce*(file, project: openArray[AuxMarkEntry]; position: int): InForce =
  ## The entry in force for `position`: the file's, else the project's, else none.
  for e in file:
    if e.position == position: return InForce(marked: e.marked, ms: e.ms, byFile: true)
  for e in project:
    if e.position == position and e.marked: return InForce(marked: true, ms: e.ms)

func projectEntry(project: openArray[AuxMarkEntry]; position: int): InForce =
  for e in project:
    if e.position == position and e.marked: return InForce(marked: true, ms: e.ms)

func shiftText*(ms: float64): string =
  ## A shift as typed: whole when it is, else with its decimals.
  if ms == trunc(ms) and abs(ms) < 1e15: $int64(ms) else: formatFloat(ms, ffDecimal, 3)

func forceWords*(f: InForce; projectMarks: bool): string =
  ## The line that says what is in force.
  if f.marked:
    let where = if f.byFile: "this file" else: "the project"
    "Marked in " & where & ", shift " & shiftText(f.ms) & " ms"
  elif f.byFile and projectMarks:
    "Not marked in this file, though the project marks it: this trace is cut to the " &
      "listen time, not correlated"
  else: "Not marked: this trace is cut to the listen time, not correlated"

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc fill(buf: var array[32, char]; text: string) =
  zeroMem(addr buf[0], buf.len)
  if text.len > 0: copyMem(addr buf[0], text.cstring, min(text.len, buf.len - 1))

proc fileCommand(path: string; position: int; state: AuxMarkState; ms: float64): Command =
  Command(kind: ckFileAuxMark, auxFile: path, auxPosition: position, auxMarked: state,
    auxShiftMs: ms)

proc projectCommand(position: int; state: AuxMarkState; ms: float64): Command =
  Command(kind: ckProjectAuxMark, auxPosition: position, auxMarked: state, auxShiftMs: ms)

proc drawAuxGroup*(ui: var AuxMarkUi; st: AppState; under, position: int; mouse: ImVec2_c;
    marks: var Marks; cmds: var seq[Command]) =
  ## The "Correlate auxiliary trace N" sub-menu for the auxiliary trace `under`
  ## (survey-wide), whose position among its record's auxiliary traces is `position`.
  let i = st.findTrace(under)
  if i < 0 or position < 1: return
  let path = st.sessions[i].diskPath
  let fileMarks = st.editsAt(path).auxMarks
  let projectMarks = st.projectAuxMarks
  let now = inForce(fileMarks, projectMarks, position)
  let inProject = projectEntry(projectMarks, position)
  let title = "Correlate auxiliary trace " & $position
  let open = igBeginMenu(title.cstring, true)
  marks.mark("plot.menu.aux")
  marks.mark("plot.menu.aux " & $position)
  tip("Whether this auxiliary trace is correlated with the reference, and its shift")
  if open:
    let line = forceWords(now, inProject.marked)
    igTextDisabled("%s", line.cstring)
    marks.mark("plot.menu.aux.state " & line)
    let fileOn = now.byFile and now.marked
    if igMenuItem_Bool("In this file", nil, fileOn, true):
      if fileOn:
        cmds.add fileCommand(path, position,
          if inProject.marked: amNotMarked else: amForget, 0.0)
      else:
        cmds.add fileCommand(path, position, amMarked, if now.marked: now.ms else: 0.0)
    marks.mark("plot.menu.aux.file")
    tip("Correlate this auxiliary trace in this file. It is kept with the file's edits and " &
      "Undo takes it back.")
    let writable = st.inProject and not st.project.readOnly
    if igMenuItem_Bool("In the project (every file)", nil, inProject.marked, writable):
      if inProject.marked: cmds.add projectCommand(position, amForget, 0.0)
      else: cmds.add projectCommand(position, amMarked, if now.marked: now.ms else: 0.0)
    marks.mark("plot.menu.aux.project")
    tip(if not st.inProject: NeedProject
        elif st.project.readOnly: "The project is open read-only."
        else: "Correlate this auxiliary position in every file of the project. A file's own " &
          "mark wins over it.")
    if igMenuItem_Bool("Shift...", nil, false, now.marked):
      fill(ui.text, shiftText(now.ms))
      (ui.position, ui.file, ui.pos, ui.ask) = (position, path, mouse, true)
    marks.mark("plot.menu.aux.shift")
    tip(if now.marked: ShiftTip
        else: "Mark this trace for correlation first. " & ShiftTip)
    igEndMenu()

proc parseShift(text: string): tuple[ms: float64; ok: bool] =
  let s = text.strip
  if s.len == 0: return
  var v = 0.0
  if parseutils.parseFloat(s, v) == s.len: (v, true) else: (0.0, false)

proc drawAuxShift*(ui: var AuxMarkUi; st: AppState; marks: var Marks; cmds: var seq[Command]) =
  ## The small popover that sets the shift of the position in force: the file's entry when it
  ## has one, else the project's. Apply or Enter sends it; Cancel or Escape closes it.
  if ui.ask:
    ui.ask = false
    ui.active = true
    igSetNextWindowPos(ui.pos, ImGui_Cond_Appearing.cint, ImVec2_c(x: 0, y: 0))
    igOpenPopup_Str(popId, 0)
  if not ui.active: return
  if not igBeginPopup(popId, 0):
    ui.active = false
    return
  marks.markWindow("plot.auxshift popup")
  igTextUnformatted(("Shift of auxiliary trace " & $ui.position).cstring, nil)
  if igIsWindowAppearing(): igSetKeyboardFocusHere(0)
  igSetNextItemWidth(round(igGetFontSize() * 8))
  const flags = ImGui_InputTextFlags_EnterReturnsTrue.cint or
    ImGui_InputTextFlags_AutoSelectAll.cint
  let entered = igInputText("ms", cast[cstring](addr ui.text[0]), csize_t(ui.text.len), flags,
    nil, nil)
  marks.mark("plot.auxshift field")
  tip(ShiftTip)
  let typed = ($cast[cstring](addr ui.text[0])).strip
  marks.mark("plot.auxshift typed " & typed)
  let parsed = parseShift(typed)
  var refused = ""
  if typed.len > 0 and not parsed.ok: refused = "a shift of " & typed & " ms is not kept"
  elif parsed.ok and not shiftStorable(parsed.ms): refused = shiftRefusal(parsed.ms)
  if refused.len > 0:
    igPushTextWrapPos(igGetFontSize() * 28)
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, ImVec4_c(x: 1, y: 0.75, z: 0.25, w: 1))
    igTextWrapped("%s", refused.cstring)
    igPopStyleColor(1)
    igPopTextWrapPos()
    marks.mark("plot.auxshift refused " & refused)
  igSeparator()
  if igButton("Cancel", ImVec2_c(x: 0, y: 0)) or igIsKeyPressed_Bool(ImGui_Key_Escape, false):
    igCloseCurrentPopup()
  marks.mark("plot.auxshift cancel")
  tip("Close without changing the shift")
  igSameLine(0, -1)
  let canApply = parsed.ok and refused.len == 0
  igBeginDisabled(not canApply)
  if igButton("Apply", ImVec2_c(x: 0, y: 0)) or (entered and canApply):
    let now = inForce(st.editsAt(ui.file).auxMarks, st.projectAuxMarks, ui.position)
    if now.marked:
      cmds.add(if now.byFile: fileCommand(ui.file, ui.position, amMarked, parsed.ms)
               else: projectCommand(ui.position, amMarked, parsed.ms))
    igCloseCurrentPopup()
  igEndDisabled()
  marks.mark("plot.auxshift apply")
  tip("Set the shift of this auxiliary trace's mark")
  igEndPopup()

func withAuxHint*(note: string): string =
  ## A status sentence that says no auxiliary trace is marked, with what to do about it.
  if "no auxiliary trace is marked for correlation" in note and AuxMarkHint notin note:
    note & " " & AuxMarkHint
  else: note
