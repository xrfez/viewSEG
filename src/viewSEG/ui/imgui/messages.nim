## The "Messages" window: the application's message log (`core/log`), newest
## last, one line per entry with an icon for its severity, who reported it
## and where (record, trace, header field); hovering a line shows all of it.
## Only the lines in view are drawn (ImGui's list clipper), so a log of
## thousands of parseSEG diagnostics costs no more per frame than a short one;
## the log itself is bounded. It follows new entries while scrolled to the
## end, and stays put while the user reads further up.
##
## `Messages` collects what the frontend's own parts (theme, fonts) say
## before it goes into the log.

import std/[os, strutils, times]
import imguin/cimgui
import ../../core/[geometry, log]
import ../../view/theme
import icons, style

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
    seen: int ## the log's next serial when it was last drawn

func levelOf*(s: Severity): MessageLevel =
  ## How a log entry of severity `s` is shown.
  case s
  of sevInfo: mlInfo
  of sevWarning: mlWarning
  of sevError, sevFatal: mlError

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

func where*(loc: Location): string =
  ## Where a log entry points, in plain words: "record 2, trace 71, GH1.formatCode";
  ## "" when it names no place inside the file.
  var parts: seq[string]
  if loc.record >= 0: parts.add "record " & $loc.record
  if loc.channelSet >= 0: parts.add "channel set " & $loc.channelSet
  if loc.trace >= 0: parts.add "trace " & $loc.trace
  if loc.field.len > 0: parts.add loc.field
  parts.join(", ")

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

proc details(e: LogEntry) =
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
    igTextDisabled("%s", facts.cstring)
    igPopTextWrapPos()
    igEndTooltip()

proc draw*(view: var LogView; log: MessageLog; title: string; t: Theme) =
  ## The window, docked or floating like any other, titled `title`; the
  ## caller places it.
  const icon: array[MessageLevel, string] = [IconInfo, IconWarning, IconError]
  let colour: array[MessageLevel, Rgba] = [t.roles[rlInfo], t.roles[rlWarning],
    t.roles[rlError]]
  if igBegin(title.cstring, nil, ImGui_WindowFlags_HorizontalScrollbar.cint):
    if log.len == 0:
      igTextDisabled("Nothing yet. File > Open file... opens a seismic file.")
    let following = igGetScrollY() >= igGetScrollMaxY() - 1
    let clipper = ImGuiListClipper_ImGuiListClipper()
    ImGuiListClipper_Begin(clipper, log.len.cint, -1)
    while ImGuiListClipper_Step(clipper):
      for i in clipper.DisplayStart ..< clipper.DisplayEnd:
        let e = log[i]
        let level = levelOf(e.severity)
        igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour[level]))
        igTextUnformatted(icon[level].cstring, nil)
        igPopStyleColor(1)
        igSameLine(0, -1)
        let text = line(e)
        igTextUnformatted(text.cstring, nil)
        if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint):
          details(e)
    ImGuiListClipper_End(clipper)
    ImGuiListClipper_destroy(clipper)
    if log.nextSerial != view.seen and following:
      igSetScrollHereY(1)
    view.seen = log.nextSerial
  igEnd()
