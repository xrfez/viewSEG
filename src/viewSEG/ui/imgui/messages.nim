## The "Messages" window: the application's message log (`core/log`), newest
## last, one line per entry with an icon for its severity, who reported it
## and where (record, trace, header field); hovering a line shows all of it.
## Only the lines in view are drawn (ImGui's list clipper), so a log of
## thousands of parseSEG diagnostics costs no more per frame than a short one;
## the log itself is bounded.
##
## A strip over the lines: a toggle per severity (info, warnings, errors)
## with its count, **Auto-scroll** (on, the list follows new messages; off,
## it stays where the user left it), **Copy** (the lines shown, to the
## clipboard), **Clear** (empties the window; the session's log file keeps
## everything) and **Export...** (a text file). The toggles are settings.
## Clicking a line that names a trace shows that trace in the plot window,
## selected (opening its file first when it is no longer open), unless the
## click only brought the window forward (`focus`); a right click copies the
## line, or shows its trace.
##
## `Messages` collects what the frontend's own parts (theme, fonts) say
## before it goes into the log.

import std/[os, strutils, times]
import imguin/cimgui
import ../../core/[geometry, log, settings]
import ../../view/theme
import focus, icons, marks, style

type
  MessageLevel* = enum
    mlInfo = "info", mlWarning = "warning", mlError = "error"

  Message* = object
    level*: MessageLevel
    text*: string

  Messages* = object
    ## Messages waiting to go into the log.
    items*: seq[Message]

  LogView* = object
    ## The window's own state between frames.
    seen: int          ## the log's next serial when it was last drawn
    cleared: int       ## the serial from which lines are shown (Clear)
    rows: seq[int]     ## the entries shown, as serials, oldest first
    made: tuple[serial, cleared: int; hidden: set[Severity]]
      ## what `rows` was made for
    focus: FocusClicks ## a click on a line acts only in a window that had the focus

  LogOutput* = object
    ## What the window asks for.
    view*: MessagesView ## its toggles as they are now (the settings keep them)
    changed*: bool      ## ... and they changed
    exportLog*: bool    ## Export... was clicked: ask where
    showPath*: string   ## a line naming a trace was clicked: show it; "" for none
    showTrace*: int     ## ... this trace
    showRecord*: int    ## ... of this SEG-D record (-1: of the file)

func levelOf*(s: Severity): MessageLevel =
  ## How a log entry of severity `s` is shown.
  case s
  of sevInfo: mlInfo
  of sevWarning: mlWarning
  of sevError, sevFatal: mlError

func shown*(view: LogView): int {.inline.} =
  ## How many lines the window shows (for tests).
  view.rows.len

func severityOf*(level: MessageLevel): Severity =
  case level
  of mlInfo: sevInfo
  of mlWarning: sevWarning
  of mlError: sevError

proc add*(m: var Messages; text: string; level = mlInfo) =
  ## Keeps `text` for the log.
  m.items.add Message(level: level, text: text)

func contains*(m: Messages; part: string): bool =
  ## Whether any message contains `part`.
  for it in m.items:
    if part in it.text: return true
  false

func line*(e: LogEntry): string =
  ## Entry `e` as one line of the window. One that points into a file (a
  ## parseSEG diagnostic) starts with the file's name and where in it:
  ## "survey.sgy, trace 71: expected 2000 bytes, got 1300".
  result = ""
  if e.loc.file.len > 0:
    result = e.loc.file.extractFilename
    let at = where(e.loc)
    if at.len > 0: result.add ", " & at
    result.add ": "
  result.add e.text

proc details(e: LogEntry; jumps: bool) =
  ## The tooltip of a line: the whole message, wrapped, with its time and
  ## where it points.
  if igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 40)
    igTextUnformatted(e.text.cstring, nil)
    var facts = e.time.local.format("HH:mm:ss") & "   " & $e.severity
    if e.source.len > 0: facts.add "   " & e.source
    if e.loc.file.len > 0: facts.add "\n" & e.loc.file
    let at = where(e.loc)
    if at.len > 0: facts.add "\n" & at
    if e.offset >= 0: facts.add "\nbyte " & $e.offset
    if jumps: facts.add "\nClick to show this trace in the plot."
    igTextDisabled("%s", facts.cstring)
    igPopTextWrapPos()
    igEndTooltip()

func hides(hidden: set[Severity]; s: Severity): bool =
  ## Whether a line of severity `s` is hidden: errors and fatal ones go
  ## together.
  if s == sevFatal: sevError in hidden else: s in hidden

proc update(view: var LogView; log: MessageLog; hidden: set[Severity]) =
  ## The lines shown, made again when the log, Clear or a toggle changed.
  if view.made == (log.nextSerial, view.cleared, hidden): return
  view.made = (log.nextSerial, view.cleared, hidden)
  view.rows.setLen 0
  let first = log.nextSerial - log.len # the serial of log[0]
  for i in max(0, view.cleared - first) ..< log.len:
    if not hides(hidden, log[i].severity): view.rows.add first + i

proc toggle(label, mark, help: string; on: bool; t: Theme; marks: var Marks): bool =
  ## A small button that is drawn selected while `on`.
  if on: igPushStyleColor_Vec4(ImGui_Col_Button.cint, vec4(t.roles[rlSelection]))
  result = igSmallButton(label.cstring)
  if on: igPopStyleColor(1)
  marks.mark(mark)
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(help.cstring, nil)
    igEndTooltip()

proc strip(view: var LogView; log: MessageLog; t: Theme; marks: var Marks;
    res: var LogOutput) =
  ## The toggles and buttons over the lines.
  const kinds = [(sevInfo, IconInfo, "information"), (sevWarning, IconWarning, "warnings"),
    (sevError, IconError, "errors")]
  for (sev, icon, name) in kinds:
    let n = log.count(sev) + (if sev == sevError: log.count(sevFatal) else: 0)
    let shown = sev notin res.view.hidden
    if toggle(icon & " " & $n & "##" & name, "messages." & name,
        (if shown: "Hide " else: "Show ") & name, shown, t, marks):
      if shown: res.view.hidden.incl sev else: res.view.hidden.excl sev
      res.changed = true
    igSameLine(0, 4)
  igSameLine(0, 12)
  if toggle("Auto-scroll", "messages.autoscroll", "On: the list follows new messages. " &
      "Off: it stays where you scrolled.", res.view.autoScroll, t, marks):
    res.view.autoScroll = not res.view.autoScroll
    res.changed = true
  igSameLine(0, 12)
  if igSmallButton((IconCopy & " Copy").cstring):
    var text = ""
    for serial in view.rows:
      let e = log[serial - (log.nextSerial - log.len)]
      text.add line(e) & "\n"
    igSetClipboardText(text.cstring)
  marks.mark("messages.copy")
  igSameLine(0, 4)
  if igSmallButton((IconClearAll & " Clear").cstring):
    view.cleared = log.nextSerial
  marks.mark("messages.clear")
  igSameLine(0, 4)
  if igSmallButton((IconExport & " Export...").cstring):
    res.exportLog = true
  marks.mark("messages.export")

proc draw*(view: var LogView; log: MessageLog; title: string; t: Theme;
    settings: MessagesView; marks: var Marks): LogOutput =
  ## The window, docked or floating like any other, titled `title`; the
  ## caller places it. `settings` are its toggles.
  const icon: array[MessageLevel, string] = [IconInfo, IconWarning, IconError]
  let colour: array[MessageLevel, Rgba] = [t.roles[rlInfo], t.roles[rlWarning],
    t.roles[rlError]]
  result = LogOutput(view: settings, showTrace: -1, showRecord: -1)
  if igBegin(title.cstring, nil, 0):
    view.focus.watch()
    marks.markWindow("messages")
    view.strip(log, t, marks, result)
    view.update(log, result.view.hidden)
    if igBeginChild_Str("##lines", ImVec2_c(x: 0, y: 0), 0,
        ImGui_WindowFlags_HorizontalScrollbar.cint):
      if view.rows.len == 0:
        let note = if log.len == 0: "Nothing yet. File > Open file... opens a seismic file."
                   else: "No message to show here."
        igTextDisabled("%s", note.cstring)
      let following = igGetScrollY() >= igGetScrollMaxY() - 1
      let first = log.nextSerial - log.len
      let clipper = ImGuiListClipper_ImGuiListClipper()
      ImGuiListClipper_Begin(clipper, view.rows.len.cint, -1)
      while ImGuiListClipper_Step(clipper):
        for r in clipper.DisplayStart ..< clipper.DisplayEnd:
          let e = log[view.rows[r] - first]
          let level = levelOf(e.severity)
          igPushID_Int(cint(view.rows[r]))
          igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour[level]))
          igTextUnformatted(icon[level].cstring, nil)
          igPopStyleColor(1)
          igSameLine(0, -1)
          let text = line(e)
          let jumps = e.loc.file.len > 0 and e.loc.trace >= 0
          if igSelectable_Bool(text.cstring, false, 0, ImVec2_c(x: 0, y: 0)) and jumps and
              view.focus.acts:
            (result.showPath, result.showTrace, result.showRecord) = (e.loc.file, e.loc.trace,
              e.loc.record)
          if r == view.rows.high: marks.mark("messages.last")
          if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint):
            details(e, jumps)
          if igBeginPopupContextItem("##line", ImGui_PopupFlags_MouseButtonRight.cint):
            if igMenuItem_Bool((IconCopy & "  Copy this line").cstring, nil, false, true):
              igSetClipboardText(text.cstring)
            if jumps and igMenuItem_Bool("Show this trace", nil, false, true):
              (result.showPath, result.showTrace, result.showRecord) = (e.loc.file, e.loc.trace,
                e.loc.record)
            igEndPopup()
          igPopID()
      ImGuiListClipper_End(clipper)
      ImGuiListClipper_destroy(clipper)
      if log.nextSerial != view.seen and following and result.view.autoScroll:
        igSetScrollHereY(1)
      view.seen = log.nextSerial
    igEndChild()
    view.focus.settle()
  igEnd()
