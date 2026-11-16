## The shell's chrome around the docked panels: the icon toolbar under the menu
## bar, the status bar along the bottom (the running job's progress bar and
## its Cancel button, then the cursor readout: the fields the user chose,
## from `core/readout`, and whether the trace under the pointer is killed or
## its polarity reversed; a right click on the bar chooses them and their
## order), and tool buttons (a Nerd Font icon or
## a seismic `Symbol`) with tooltips that name their shortcut. The toolbar holds
## application-level actions only (open a file, a folder or a project, the
## jobs, the theme); display and gather controls belong to the
## plot windows, which use `symbolButton`. Also the sample header table that
## shows the look until the real header table exists.
##
## Each piece records where it drew its named parts in `Marks`, so tests can
## look at the right pixels.

import std/[math, strutils]
import imguin/cimgui
import ../../core/[geometry, jobs, pick, readout]
import ../../view/[jobstatus, theme]
import fonts, icons, marks, menus, plotviews, style, symbols

export marks

const IconScale* = 1.3'f32
  ## toolbar icons and symbols, relative to the text size

type
  AgentSign* = object
    ## Agent control, as the status bar shows it.
    on*: bool           ## the server listens
    clients*: int       ## agents connected
    names*: seq[string] ## what they said they are
    socket*: string     ## where they connect
    lastCall*: string   ## what an agent asked last, in words ("state"); "" for nothing yet
    lingering*: bool    ## none connected, its last call a few seconds ago

  ChromeInfo* = object
    ## Facts the status bar shows.
    themeName*: string
    scale*: float32
    agent*: AgentSign

  StatusOutput* = object
    ## What the status bar asks for.
    cancel*: JobId             ## the job to cancel, or `NoJob`
    showJobs*: bool            ## the job field was clicked: bring the Jobs window forward
    chose*: bool               ## the user changed the readout's fields
    fields*: seq[ReadoutField] ## ... to these, in this order

const readoutMenu = "##readoutfields"

proc tooltip(text, shortcut: string; t: Theme) =
  ## The last item's tooltip: `text` (one line a `\n`), then the shortcut in
  ## dim text. Shown on a disabled item too.
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    var rest = text
    while rest.len > 0:
      let nl = rest.find('\n')
      let line = if nl >= 0: rest[0 ..< nl] else: rest
      rest = if nl >= 0: rest[nl + 1 .. ^1] else: ""
      igTextUnformatted(line.cstring, nil)
    if shortcut.len > 0:
      if '\n' notin text: igSameLine(0, -1)
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
      igTextUnformatted(shortcut.cstring, nil)
      igPopStyleColor(1)
    igEndTooltip()

proc toolButton(id: string; size: float32; selected: bool; t: Theme): (bool, ImVec2_c) =
  ## A square, frameless button: the hover and selection backgrounds only.
  ## Returns whether it was clicked and its top-left corner.
  let pos = igGetCursorScreenPos()
  let clicked = igInvisibleButton(id.cstring, ImVec2_c(x: size, y: size), 0)
  let bg = if igIsItemActive(): t.roles[rlActive]
           elif igIsItemHovered(0): t.roles[rlHover]
           elif selected: t.roles[rlSelection]
           else: Rgba()
  if bg.a > 0:
    ImDrawList_AddRectFilled(igGetWindowDrawList(), pos,
      ImVec2_c(x: pos.x + size, y: pos.y + size), u32(bg), igGetStyle().FrameRounding, 0)
  (clicked, pos)

proc iconButton*(icon, text, shortcut: string; size: float32; t: Theme;
    marks: var Marks; selected = false; tipText = ""; enabled = true): bool =
  ## A toolbar button showing a Nerd Font `icon`, centred. `tipText` replaces
  ## the tooltip built from `text` and `shortcut`. A button that is not
  ## `enabled` is drawn dim and does not click, and its tooltip still shows.
  if not enabled: igBeginDisabled(true)
  let (clicked, pos) = toolButton("##" & text, size, selected, t)
  if not enabled: igEndDisabled()
  marks.mark("tool." & text)
  # Codicons sit small in their em box: draw them at two thirds of the button
  let (font, px) = (igGetFont(), round(size * 0.68))
  let ts = ImFont_CalcTextSizeA(font, px, high(float32), 0, icon.cstring, nil, nil)
  let col = if not enabled: t.roles[rlTextDim]
            elif selected: t.roles[rlAccent]
            else: t.roles[rlText]
  ImDrawList_AddText_FontPtr(igGetWindowDrawList(), font, px,
    ImVec2_c(x: round(pos.x + (size - ts.x) / 2), y: round(pos.y + (size - ts.y) / 2)),
    u32(col), icon.cstring, nil, 0, nil)
  if tipText.len > 0: tooltip(tipText, shortcut, t) else: tooltip(text, shortcut, t)
  clicked

type
  ControlLine* = object
    ## A control line with the Freeze pin reserved at the right of its first row.
    left*, top*, right*, rowRight*, size*: float32

proc beginControlLine*(): ControlLine =
  ## The line about to be drawn: Freeze's width is kept at its right, and
  ## `rowRight` is as far as another control on that first row may reach.
  let pos = igGetCursorScreenPos()
  let style = igGetStyle()
  let size = round(igGetFontSize() * IconScale + 2 * style.FramePadding.y)
  let right = pos.x + igGetContentRegionAvail().x
  ControlLine(left: pos.x, top: pos.y, right: right, size: size,
    rowRight: right - size - style.ItemSpacing.x)

proc fitsBefore*(line: ControlLine; width, gap: float32): bool =
  ## Whether a control of `width`, `gap` after the previous item, fits on
  ## that item's line: before the Freeze pin on the first row, else before
  ## the window's right edge.
  let first = igGetItemRectMin().y <= line.top + 1
  let edge = if first: line.rowRight else: line.right
  igGetItemRectMax().x + gap + width <= edge

proc drawFreeze*(line: ControlLine; id, sentence, mark: string; frozen: bool; t: Theme;
    marks: var Marks): bool =
  ## The pin at the right end of the first row, drawn selected while
  ## `frozen`. `sentence` follows "Freeze (on): " or "Freeze (off): ". The
  ## cursor is left below the line, at its left, for what comes under it.
  let after = igGetCursorScreenPos()
  igSetCursorScreenPos(ImVec2_c(x: line.right - line.size, y: line.top))
  let (clicked, pos) = toolButton("##freeze" & id, line.size, frozen, t)
  marks.mark(mark)
  let (font, px) = (igGetFont(), round(line.size * 0.68))
  let ts = ImFont_CalcTextSizeA(font, px, high(float32), 0, IconPin.cstring, nil, nil)
  let col = if frozen: t.roles[rlAccent] else: t.roles[rlText]
  ImDrawList_AddText_FontPtr(igGetWindowDrawList(), font, px,
    ImVec2_c(x: round(pos.x + (line.size - ts.x) / 2), y: round(pos.y + (line.size - ts.y) / 2)),
    u32(col), IconPin.cstring, nil, 0, nil)
  tooltip("Freeze (" & (if frozen: "on" else: "off") & "): " & sentence, "", t)
  let y = max(after.y, line.top + line.size + igGetStyle().ItemSpacing.y)
  igSetCursorScreenPos(ImVec2_c(x: line.left, y: y))
  clicked

proc symbolButton*(sym: Symbol; size: float32; t: Theme; marks: var Marks;
    selected = false; note = ""; markPrefix = "tool."; turned = false): bool =
  ## A tool button showing a seismic symbol, for a plot window's own controls,
  ## `turned` with a plot whose time runs across; its mark is `markPrefix`
  ## and the symbol's name.
  let (clicked, pos) = toolButton("##" & $sym, size, selected, t)
  marks.mark(markPrefix & $sym)
  let inset = round(size * 0.17)
  drawSymbol(igGetWindowDrawList(), sym, ImVec2_c(x: pos.x + inset, y: pos.y + inset),
    size - 2 * inset, symbolColours(t, selected), turned)
  tooltip($sym & note, "", t)
  clicked

const
  ButtonGap = 2'f32 ## between buttons of one group
  GroupGap = 14'f32 ## between groups, as on the Seismic strip

type
  ToolbarResult* = object
    ## What the toolbar asks for.
    actions*: set[MenuAction]
    openProject*: string ## a recent project chosen from Open project's menu
    fft*: bool           ## FFT of the Seismic window's selection
    plot*: bool          ## a New plot view of that selection
    plotView*: AnalysisView

const barFlags = ImGui_WindowFlags_NoScrollbar.cint or ImGui_WindowFlags_NoSavedSettings.cint or
  ImGui_WindowFlags_NoScrollWithMouse.cint or ImGui_WindowFlags_NoDecoration.cint

proc beginBar(name: string; dir: ImGuiDir; height: float32; t: Theme): bool =
  ## A strip along an edge of the main viewport, in the bar colour, with a
  ## border line towards the panels.
  let vp = igGetMainViewport()
  igPushStyleColor_Vec4(ImGui_Col_WindowBg.cint, vec4(t.roles[rlBar]))
  igPushStyleVar_Float(ImGui_StyleVar_WindowBorderSize.cint, 0)
  igPushStyleVar_Vec2(ImGui_StyleVar_WindowPadding.cint,
    ImVec2_c(x: igGetStyle().WindowPadding.x, y: 0))
  result = igBeginViewportSideBar(name.cstring, vp, dir, height, barFlags)
  igPopStyleVar(2)
  igPopStyleColor(1)
  if result:
    let wp = igGetWindowPos()
    let ws = igGetWindowSize()
    let y = if dir == ImGui_Dir_Down: wp.y + 0.5 else: wp.y + ws.y - 0.5
    ImDrawList_AddLine(igGetWindowDrawList(), ImVec2_c(x: wp.x, y: y),
      ImVec2_c(x: wp.x + ws.x, y: y), u32(t.roles[rlBorder]), 1)

proc drawToolbar*(t: Theme; marks: var Marks; recentProjects: openArray[string];
    plotTraces: int): ToolbarResult =
  ## The icon toolbar under the menu bar: opening files, folders and
  ## projects, a button per plot of the Seismic window's selection, the
  ## jobs, and the theme toggle. A right click on Open project opens the
  ## recent projects. Plot buttons are greyed while `plotTraces` is 0.
  let style = igGetStyle()
  let size = round(igGetFontSize() * IconScale + 2 * style.FramePadding.y + 2)
  let height = size + 2 * round(style.FramePadding.y)
  if beginBar("##toolbar", ImGuiDir_Up, height, t):
    marks.markWindow("toolbar")
    igSetCursorPosY(round((height - size) / 2))
    if iconButton(IconOpenFile, "Open file", shortcutName(maOpenFile), size, t, marks):
      result.actions.incl maOpenFile
    igSameLine(0, ButtonGap)
    if iconButton(IconOpenFolder, "Open folder", shortcutName(maOpenFolder), size, t, marks):
      result.actions.incl maOpenFolder
    igSameLine(0, GroupGap)
    if iconButton(IconProject, "Open project", "", size, t, marks,
        tipText = "Open project: a project's folder (the folder that holds its project.nif)"):
      result.actions.incl maOpenProject
    if igBeginPopupContextItem("##recentprojects", ImGui_PopupFlags_MouseButtonRight.cint):
      drawRecentProjects(recentProjects, result.openProject, addr marks, "tool.project.")
      igEndPopup()
    let plotsOn = plotTraces > 0
    igSameLine(0, GroupGap)
    for i, e in PlotEntries:
      if i > 0: igSameLine(0, ButtonGap)
      # the shortcut is in the tip's text, so it is not appended again
      if iconButton(e.icon, e.name, "", size, t, marks, enabled = plotsOn,
          tipText = e.tip(plotsOn)):
        if e.fft: result.fft = true
        else: (result.plot, result.plotView) = (true, e.view)
    igSameLine(0, GroupGap)
    if iconButton(IconTasks, "Jobs", "", size, t, marks):
      result.actions.incl maShowJobs
    igSameLine(0, ButtonGap)
    # the theme toggle sits at the right end
    let avail = igGetContentRegionAvail().x
    if avail > size:
      igSetCursorPosX(igGetCursorPosX() + avail - size)
    if iconButton(IconTheme, "Light / dark theme", "", size, t, marks):
      result.actions.incl maToggleTheme
  igEnd()

func valueChars(f: ReadoutField): int =
  ## The room a field's value takes at least, in characters, so the bar
  ## does not jump as the cursor moves.
  case f
  of rfTime: 10
  of rfTrace, rfSample, rfRecord, rfEnsemble: 6
  of rfChannel, rfInline, rfCrossline: 5
  of rfReceiver, rfSource: 12
  of rfOffset, rfSourceZ, rfReceiverZ: 8
  of rfAmplitude, rfRawAmplitude: 9
  of rfShotTime, rfCursorUtc: 23
  of rfSourceXY, rfReceiverXY, rfMidpointXY: 21
  of rfComponent: 2
  of rfStatus: 9

proc readoutField(fonts: Fonts; f: ReadoutField; value: string; t: Theme;
    marks: var Marks; joined = false) =
  ## One field of the readout: its caption, dim, then its value in mono,
  ## given room for `valueChars`; a value a geometry join gave (`joined`) in
  ## the accent colour.
  igSameLine(0, -1)
  igBeginGroup()
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextUnformatted(caption(f).cstring, nil)
  igPopStyleColor(1)
  igSameLine(0, 6)
  fonts.withFont(frMono, 0):
    let room = igCalcTextSize(repeat('0', valueChars(f)).cstring, nil, false, -1).x
    if joined: igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlAccent]))
    igTextUnformatted(value.cstring, nil)
    if joined: igPopStyleColor(1)
    let used = igGetItemRectSize().x
    if used < room:
      igSameLine(0, 0)
      igDummy(ImVec2_c(x: room - used, y: 1))
  igEndGroup()
  marks.mark("status." & $f)
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(($f & (if f == rfAmplitude: ", as displayed (after processing and " &
      "gain)" else: "") & (if joined: ", from the survey, not the trace header"
      else: "") & ". Right-click the bar to choose the fields.").cstring, nil)
    igEndTooltip()
  igSameLine(0, 16)

proc drawReadoutMenu(fields: openArray[ReadoutField]; res: var StatusOutput) =
  ## The status bar's menu: which fields it shows, and in what order.
  igSeparatorText("Status bar fields")
  var chosen = @fields
  var changed = false
  for i, f in fields:
    igPushID_Int(cint(ord(f)))
    var on = true
    if igCheckbox("##on", addr on):
      chosen.delete(chosen.find(f))
      changed = true
    igSameLine(0, -1)
    igBeginDisabled(i == 0)
    if igArrowButton("##up", ImGui_Dir_Up) and not changed:
      swap(chosen[i], chosen[i - 1])
      changed = true
    igEndDisabled()
    igSameLine(0, 2)
    igBeginDisabled(i == fields.high)
    if igArrowButton("##down", ImGui_Dir_Down) and not changed:
      swap(chosen[i], chosen[i + 1])
      changed = true
    igEndDisabled()
    igSameLine(0, -1)
    igTextUnformatted(($f).cstring, nil)
    igPopID()
  igSeparator()
  if igBeginMenu("Add a field", fields.len < ReadoutField.high.ord + 1):
    for f in ReadoutField:
      if f notin fields and igMenuItem_Bool(($f).cstring, nil, false, true):
        chosen.add f
        changed = true
    igEndMenu()
  if igButton("Restore the defaults", ImVec2_c(x: 0, y: 0)):
    chosen = @DefaultReadout
    changed = true
  if changed:
    res.chose = true
    res.fields = chosen

proc jobField(job: JobStatus; t: Theme; marks: var Marks; res: var StatusOutput) =
  ## The running job: a progress bar labelled with what it does and how far
  ## it is, Cancel, and what else runs or waits. Clicking the bar or the
  ## words asks for the Jobs window.
  igSameLine(0, -1)
  if job.job != NoJob:
    let style = igGetStyle()
    let width = round(igGetFontSize() * 22)
    let height = igGetFontSize() + 2 * round(style.FramePadding.y / 2)
    # A negative fraction draws ImGui's moving "busy" bar: progress unknown.
    let fraction = if job.fraction >= 0: job.fraction else: -float32(igGetTime())
    igPushStyleVar_Vec2(ImGui_StyleVar_FramePadding.cint,
      ImVec2_c(x: style.FramePadding.x, y: round(style.FramePadding.y / 2)))
    igProgressBar(fraction, ImVec2_c(x: width, y: height), "")
    marks.mark("status.progress")
    if igIsItemClicked(0): res.showJobs = true
    if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
      igTextUnformatted(job.text.cstring, nil)
      igTextDisabled("Click for the Jobs window")
      igEndTooltip()
    # The label beside the bar, so a long title never hides the bar itself.
    igSameLine(0, 6)
    igTextUnformatted(job.text.cstring, nil)
    marks.mark("status.job")
    if igIsItemClicked(0): res.showJobs = true
    if job.cancellable:
      igSameLine(0, 8)
      igBeginDisabled(job.cancelling)
      if igSmallButton((IconClose & " Cancel##job").cstring):
        res.cancel = job.job
      igEndDisabled()
      marks.mark("status.cancel")
    igPopStyleVar(1)
  let others = job.others
  if others.len > 0:
    igSameLine(0, 12)
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
    igTextUnformatted(others.cstring, nil)
    igPopStyleColor(1)
    marks.mark("status.others")
    if igIsItemClicked(0): res.showJobs = true
  igSameLine(0, 18)

func signText*(a: AgentSign): string =
  ## The sign's words: what an agent asked last while one is connected and
  ## a few seconds after ("agent: state"), else that agent control is on.
  let who = if a.clients > 1: $a.clients & " agents" else: "agent"
  let words = if (a.clients > 0 or a.lingering) and a.lastCall.len > 0: who & ": " & a.lastCall
              elif a.clients > 0: who & " connected"
              else: "agents: on"
  IconAgent & " " & words

func signColour*(a: AgentSign; t: Theme): Rgba =
  ## The sign's colour: the warning colour while an agent is connected (it
  ## may change what is shown), halfway to dim while its last call lingers,
  ## dim else.
  if a.clients > 0: t.roles[rlWarning]
  elif a.lingering: mix(t.roles[rlWarning], t.roles[rlTextDim], 0.5)
  else: t.roles[rlTextDim]

proc agentField(a: AgentSign; t: Theme; marks: var Marks) =
  ## The sign that agent control is on (`signText`, `signColour`).
  igSameLine(0, -1)
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(a.signColour(t)))
  igTextUnformatted(a.signText.cstring, nil)
  igPopStyleColor(1)
  marks.mark("status.agent")
  if a.clients > 0: marks.mark("status.agent connected")
  elif a.lingering: marks.mark("status.agent lingering")
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(("Agent control is on: MCP clients connect through\n" & a.socket).cstring,
      nil)
    if a.names.len > 0:
      igTextUnformatted(("Connected: " & a.names.join(", ")).cstring, nil)
    igTextDisabled("Every call an agent makes is in Messages. File > Agent control turns it off.")
    igEndTooltip()
  igSameLine(0, 16)

proc drawStatusBar*(fonts: Fonts; t: Theme; info: ChromeInfo; job: JobStatus;
    fields: openArray[ReadoutField]; at: Pick; marks: var Marks;
    mapCursor = ""; linkNote = ""): StatusOutput =
  ## The status strip along the bottom of the main window: the sign that
  ## agent control is on (`info.agent`), the running job, then the readout
  ## of `fields` at `at` (blank where a value is not known),
  ## or, with the pointer over the map, its coordinates (`mapCursor`); why
  ## the hover lights nothing up in the other view (`linkNote`); the theme
  ## and the scale on the right. A right click on it opens the menu that
  ## chooses the fields.
  result = StatusOutput(cancel: NoJob)
  let style = igGetStyle()
  let height = round(igGetFontSize() + 2 * style.FramePadding.y + 2)
  if beginBar("##statusbar", ImGui_Dir_Down, height, t):
    marks.markWindow("statusbar")
    igSetCursorPosY(round((height - igGetFontSize()) / 2))
    igDummy(ImVec2_c(x: 0, y: 0))
    # First: whatever else the bar holds (a job, the readout, a long note),
    # the sign that agents may act is in view.
    if info.agent.on:
      agentField(info.agent, t, marks)
    if job.shown:
      jobField(job, t, marks, result)
    if mapCursor.len > 0:
      igTextUnformatted(mapCursor.cstring, nil)
      marks.mark("status.map")
      igSameLine(0, 16)
    else:
      for f in fields:
        readoutField(fonts, f, at.text(f), t, marks, at.joined(f))
    let note = if mapCursor.len > 0: "" else: at.editNote # whatever the fields: the trace's edits
    if note.len > 0:
      igSameLine(0, -1)
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
      igTextUnformatted(note.cstring, nil)
      igPopStyleColor(1)
      marks.mark("status.edits")
      igSameLine(0, 16)
    if linkNote.len > 0:
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
      igTextUnformatted(linkNote.cstring, nil)
      igPopStyleColor(1)
      marks.mark("status.link")
      igSameLine(0, 16)
    let right = info.themeName & "   " & $int(round(info.scale * 100)) & " %"
    let w = igCalcTextSize(right.cstring, nil, false, -1).x
    let avail = igGetContentRegionAvail().x
    if avail > w:
      igSetCursorPosX(igGetCursorPosX() + avail - w)
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
      igTextUnformatted(right.cstring, nil)
      igPopStyleColor(1)
    if igIsWindowHovered(0) and igIsMouseReleased_Nil(ImGui_MouseButton_Right.cint):
      igOpenPopup_Str(readoutMenu, 0)
    # Above the bar, inside the window: placed against the monitor, a menu
    # opened from the bottom edge would become a window of its own below it.
    igSetNextWindowPos(ImVec2_c(x: igGetIO_Nil().MousePos.x, y: igGetWindowPos().y),
      ImGui_Cond_Appearing.cint, ImVec2_c(x: 0, y: 1))
    if igBeginPopup(readoutMenu, 0):
      drawReadoutMenu(fields, result)
      igEndPopup()
  igEnd()

# ------------------------------------------------------------- tables --

proc rightAlign*(text: string) =
  ## Moves the cursor so that `text` ends at the right of the space left.
  let w = igCalcTextSize(text.cstring, nil, false, -1).x
  let avail = igGetContentRegionAvail().x
  if avail > w:
    igSetCursorPosX(igGetCursorPosX() + avail - w)
