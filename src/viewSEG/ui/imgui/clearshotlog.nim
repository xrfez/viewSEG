## The confirmation of Clear shot log (Project > Clear shot log...): one dialog, one command
## (`ckClearShotLog`). It opens in the middle of the main window.
##
## The shot log's rows, its columns and the project's copy are taken away at once and cannot be
## brought back by undo (cell edits are not kept), so the confirmation says what is removed
## and what is not (the log file on disk).

import imguin/cimgui
import ../../core/state
import chrome, icons, marks, placement

type
  ClearShotLogUi* = object
    ## The dialog's own state between frames.
    asked: bool ## open it next frame

const
  ClearShotLogWords* = "Clear shot log"
  ClearShotLogId = "Clear shot log?###shotlog.clear"

func clearShotLogQuestion*(count: int): string =
  ## What the dialog asks for `count` logs, loaded or kept by the project (a copy that could
  ## not be read is one of them).
  (if count == 1: "Remove the shot log? "
    else: "Remove all " & $count & " shot logs? ") &
     "The Shot log window empties and the map loses the shots, and an open project keeps no " &
     "copy of " & (if count == 1: "it" else: "them") & ". The log files on disk are not touched."

proc ask*(ui: var ClearShotLogUi) =
  ## Opens the confirmation next frame.
  ui.asked = true

proc drawClearShotLog*(ui: var ClearShotLogUi; count: int; marks: var Marks): seq[Command] =
  ## The confirmation while it is open: Clear shot log sends `ckClearShotLog`, Cancel (or
  ## Escape) changes nothing. `count` is how many logs there are to remove (`shotLogsHeld`).
  if ui.asked:
    igOpenPopup_Str(ClearShotLogId.cstring, 0)
    ui.asked = false
  centreModal(ClearShotLogId)
  igSetNextWindowSizeConstraints(ImVec2_c(x: igGetFontSize() * 26, y: 0),
    ImVec2_c(x: igGetFontSize() * 34, y: 4000), nil, nil)
  if igBeginPopupModal(ClearShotLogId.cstring, nil, ImGui_WindowFlags_AlwaysAutoResize.cint):
    marks.markWindow("shotlog.clear")
    igTextWrapped("%s", clearShotLogQuestion(count).cstring)
    igSeparator()
    if igButton((IconTrash & "  " & ClearShotLogWords).cstring, ImVec2_c(x: 0, y: 0)):
      result.add Command(kind: ckClearShotLog)
      igCloseCurrentPopup()
    marks.mark("shotlog.clear.confirm")
    igSameLine(0, -1)
    if igButton("Cancel", ImVec2_c(x: 0, y: 0)) or igIsKeyPressed_Bool(ImGui_Key_Escape,
        false):
      igCloseCurrentPopup()
    marks.mark("shotlog.clear.cancel")
    igEndPopup()
