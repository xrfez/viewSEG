## A small "Messages" window: what the shell reported, newest last. Each message
## is also echoed to stdout. The real log window comes later; this one only
## shows that dialogs and theme changes arrive.

import imguin/cimgui

type
  Messages* = object
    lines*: seq[string]
    scrollToEnd: bool

proc add*(m: var Messages; line: string) =
  ## Appends `line` and echoes it.
  echo line
  m.lines.add line
  m.scrollToEnd = true

proc draw*(m: var Messages) =
  ## The window, docked or floating like any other; the caller places it.
  if igBegin("Messages", nil, 0):
    if m.lines.len == 0:
      igTextDisabled("Nothing yet. File > Open file... shows the chosen paths here.")
    igPushTextWrapPos(0) # wrap at the window's edge
    for line in m.lines:
      igTextUnformatted(line.cstring, nil)
    igPopTextWrapPos()
    if m.scrollToEnd:
      igSetScrollHereY(1)
      m.scrollToEnd = false
  igEnd()
