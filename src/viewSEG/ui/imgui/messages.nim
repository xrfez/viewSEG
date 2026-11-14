## A small "Messages" window: what the shell, the theme and the font loader
## reported, newest last, each with an icon for its level. Each message is also
## echoed to stdout. The real log window comes later (1.1).

import std/strutils
import imguin/cimgui
import ../../core/geometry
import ../../view/theme
import icons, style

type
  MessageLevel* = enum
    mlInfo = "info", mlWarning = "warning", mlError = "error"

  Message* = object
    level*: MessageLevel
    text*: string

  Messages* = object
    items*: seq[Message]
    scrollToEnd: bool

proc add*(m: var Messages; text: string; level = mlInfo) =
  ## Appends `text` and echoes it.
  echo (if level == mlInfo: "" else: $level & ": "), text
  m.items.add Message(level: level, text: text)
  m.scrollToEnd = true

func contains*(m: Messages; part: string): bool =
  ## Whether any message contains `part`.
  for it in m.items:
    if part in it.text: return true
  false

proc draw*(m: var Messages; title: string; t: Theme) =
  ## The window, docked or floating like any other, titled `title`; the
  ## caller places it.
  const icon: array[MessageLevel, string] = [IconInfo, IconWarning, IconError]
  let colour: array[MessageLevel, Rgba] = [t.roles[rlInfo], t.roles[rlWarning],
    t.roles[rlError]]
  if igBegin(title.cstring, nil, 0):
    if m.items.len == 0:
      igTextDisabled("Nothing yet. File > Open file... shows the chosen paths here.")
    for it in m.items:
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour[it.level]))
      igTextUnformatted(icon[it.level].cstring, nil)
      igPopStyleColor(1)
      igSameLine(0, -1)
      igPushTextWrapPos(0) # wrap at the window's edge
      igTextUnformatted(it.text.cstring, nil)
      igPopTextWrapPos()
    if m.scrollToEnd:
      igSetScrollHereY(1)
      m.scrollToEnd = false
  igEnd()
