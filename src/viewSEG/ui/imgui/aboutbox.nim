## Help > About viewSEG: what the program is, its version and the versions
## of what it is built on (parseSEG, processSEG, Dear ImGui, SDL, the OpenGL
## driver it draws with, the compiler), for a bug report; Copy puts them on
## the clipboard. A modal popup: Escape or Close closes it.

import imguin/cimgui
import imguin/glad/gl
import sdl3_nim
import ../../core/versions
import ../../view/theme
import marks, style

type
  AboutUi* = object
    ask: bool             ## open the popup next frame
    lines: seq[AboutLine] ## made when it opens

const PopupId = "About viewSEG###about"

proc glText(name: GLenum): string =
  ## An OpenGL string (the renderer, the version); "" when none is known.
  if glGetString != nil:
    let p = glGetString(name)
    if p != nil: result = $cast[cstring](p)

proc toolkitLines*(): seq[AboutLine] =
  ## The frontend's own parts: Dear ImGui, SDL and the OpenGL driver. On
  ## the UI thread, with the GL context current.
  let v = SDL_GetVersion()
  result = @[("Dear ImGui", $igGetVersion()),
    ("SDL", $(v div 1_000_000) & "." & $(v div 1000 mod 1000) & "." & $(v mod 1000))]
  let gl = glText(GL_VERSION)
  if gl.len > 0: result.add ("OpenGL", gl & ", " & glText(GL_RENDERER))

proc open*(ui: var AboutUi) =
  ## Shows the box.
  ui.ask = true
  ui.lines = aboutLines(toolkitLines())

proc drawAbout*(ui: var AboutUi; t: Theme; marks: var Marks) =
  ## The box, when asked for.
  if ui.ask:
    igOpenPopup_Str(PopupId, 0)
    ui.ask = false
  if not igBeginPopupModal(PopupId, nil, ImGui_WindowFlags_AlwaysAutoResize.cint): return
  marks.markWindow("about")
  igTextUnformatted(("viewSEG " & ViewSEGVersion).cstring, nil)
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextUnformatted("A seismic viewer with quality control, for SEG-Y, SEG-D and SEG-2 " &
    "files.", nil)
  igTextUnformatted("It reads the files it shows and never changes them.", nil)
  igPopStyleColor(1)
  igSpacing()
  const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_BordersInnerV.cint or
    ImGui_TableFlags_SizingFixedFit.cint
  if igBeginTable("##versions", 2, flags, ImVec2_c(x: 0, y: 0), 0):
    for l in ui.lines:
      igTableNextRow(0, 0)
      discard igTableNextColumn()
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
      igTextUnformatted(l.name.cstring, nil)
      igPopStyleColor(1)
      discard igTableNextColumn()
      igTextUnformatted(l.version.cstring, nil)
      marks.mark("about " & l.name)
    igEndTable()
  igSpacing()
  if igButton("Copy", ImVec2_c(x: 0, y: 0)):
    igSetClipboardText(aboutText(ui.lines).cstring)
  marks.mark("about.copy")
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted("Copy the version lines to the clipboard", nil)
    igEndTooltip()
  igSameLine(0, -1)
  if igButton("Close", ImVec2_c(x: 0, y: 0)) or igIsKeyPressed_Bool(ImGui_Key_Escape, false):
    igCloseCurrentPopup()
  marks.mark("about.close")
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted("Close this box (Escape)", nil)
    igEndTooltip()
  igEndPopup()
