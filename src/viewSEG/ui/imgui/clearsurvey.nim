## The confirmation of Clear survey (File > Import > Clear survey, the button
## of the "Import survey" window and the Project window's): one dialog, one
## command (`ckClearSurvey`), asked from three places. It opens in the middle
## of the main window and gives the focus back to the window that asked.
##
## There is no undo for an import, so the confirmation is the safeguard: it
## says what changes (the traces show their own file's coordinates again) and
## what does not (the survey files on disk).

import imguin/cimgui
import ../../core/state
import chrome, focus, icons, marks, placement

type
  ClearSurveyUi* = object
    ## The dialog's own state between frames.
    asked: bool    ## open it next frame
    origin: string ## the title of the window that asked; "" for the menu
    wasOpen: bool

const
  ClearSurveyWords* = "Clear survey"
  ClearSurveyHelp* = "Remove the imported survey: the traces show their own file's " &
    "coordinates again, the map loses the survey's points, and a project keeps no survey. " &
    "The survey files on disk and the seismic files are not touched"
    ## The tooltip of every Clear survey button and menu item
  NoSurveyHelp* = "No survey is imported"
  ClearSurveyQuestion* = "Remove the imported survey? The traces show their own file's " &
    "coordinates again. The survey files on disk are not touched."
  ClearSurveyId = "Clear survey?###survey.clear"

proc ask*(ui: var ClearSurveyUi; origin = "") =
  ## Opens the confirmation next frame; `origin` is the title of the window
  ## that asked and gets the focus back ("" for the menu).
  ui.asked = true
  ui.origin = origin

proc drawClearSurvey*(ui: var ClearSurveyUi; marks: var Marks): seq[Command] =
  ## The confirmation while it is open: Clear survey sends `ckClearSurvey`,
  ## Cancel (or Escape) changes nothing.
  if ui.asked:
    igOpenPopup_Str(ClearSurveyId.cstring, 0)
    ui.asked = false
  centreModal(ClearSurveyId)
  igSetNextWindowSizeConstraints(ImVec2_c(x: igGetFontSize() * 26, y: 0),
    ImVec2_c(x: igGetFontSize() * 34, y: 4000), nil, nil)
  let showing = igBeginPopupModal(ClearSurveyId.cstring, nil,
    ImGui_WindowFlags_AlwaysAutoResize.cint)
  if ui.origin.len > 0: ui.wasOpen.handBack(showing, ui.origin) else: ui.wasOpen = showing
  if showing:
    marks.markWindow("survey.clear")
    igTextWrapped("%s", ClearSurveyQuestion.cstring)
    igSeparator()
    if igButton((IconTrash & "  " & ClearSurveyWords).cstring, ImVec2_c(x: 0, y: 0)):
      result.add Command(kind: ckClearSurvey)
      igCloseCurrentPopup()
    marks.mark("survey.clear.confirm")
    igSameLine(0, -1)
    if igButton("Cancel", ImVec2_c(x: 0, y: 0)) or igIsKeyPressed_Bool(ImGui_Key_Escape,
        false):
      igCloseCurrentPopup()
    marks.mark("survey.clear.cancel")
    igEndPopup()
