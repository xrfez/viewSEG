## View > Theme: "Follow system", then the dark themes, then the light ones,
## each by its own name in alphabetical order, with a swatch of its window,
## text and accent colours beside the name, the theme in use ticked.
##
## Resting the pointer on an entry previews it: the menu says which entry
## (`ThemeMenu.rested`) and the caller draws the whole program in that theme
## until the pointer rests on another or the submenu closes; a click keeps it
## (`picked`), closing it otherwise goes back to the theme before.
##
## Marks: the submenu "menu.Theme", "Follow system" "menu.theme.follow", each
## theme "menu.theme." and its file name.

import std/algorithm
import imguin/cimgui
import ../../view/theme
import marks, style

type
  ThemeMenu* = object
    ## What happened in the submenu this frame.
    open*: bool     ## the submenu is open
    picked*: bool   ## an entry was clicked
    theme*: string  ## its file name; "" for "Follow system"
    rests*: bool    ## the pointer rests on an entry
    rested*: string ## that entry's file name; "" for "Follow system"

const SwatchLines = 2.4'f32 ## the swatch's width, in text lines

proc swatchRoom(): string =
  ## Spaces as wide as the swatch, for the item's icon column.
  let want = igGetTextLineHeight() * SwatchLines
  let space = max(1'f32, igCalcTextSize(" ", nil, false, -1).x)
  result = ""
  while result.len.float32 * space < want: result.add ' '

proc drawSwatch(at: ImVec2_c; t: Theme) =
  ## The theme's window colour, with its text and accent colours in it.
  let h = igGetTextLineHeight()
  let dl = igGetWindowDrawList()
  let (top, bottom) = (at.y + h * 0.12, at.y + h * 0.88)
  let x = at.x
  let w = h * SwatchLines
  ImDrawList_AddRectFilled(dl, ImVec2_c(x: x, y: top), ImVec2_c(x: x + w, y: bottom),
    u32(t.roles[rlWindow]), 2, 0)
  let inner = (top + h * 0.2, bottom - h * 0.2)
  ImDrawList_AddRectFilled(dl, ImVec2_c(x: x + w * 0.16, y: inner[0]),
    ImVec2_c(x: x + w * 0.5, y: inner[1]), u32(t.roles[rlText]), 1, 0)
  ImDrawList_AddRectFilled(dl, ImVec2_c(x: x + w * 0.58, y: inner[0]),
    ImVec2_c(x: x + w * 0.84, y: inner[1]), u32(t.roles[rlAccent]), 1, 0)
  ImDrawList_AddRect(dl, ImVec2_c(x: x, y: top), ImVec2_c(x: x + w, y: bottom),
    igGetColorU32_Col(ImGui_Col_Border.cint, 1), 2, 1, 0)

proc entry(label, file: string; t: Theme; ticked: bool; room: string; res: var ThemeMenu;
    marks: var Marks) =
  let at = igGetCursorScreenPos()
  if igMenuItemEx(label.cstring, room.cstring, nil, ticked, true):
    (res.picked, res.theme) = (true, file)
  marks.mark("menu.theme." & (if file.len == 0: "follow" else: file))
  if igIsItemHovered(ImGui_HoveredFlags_Stationary.cint or ImGui_HoveredFlags_DelayShort.cint):
    (res.rests, res.rested) = (true, file)
  drawSwatch(at, t)

proc drawThemeMenu*(themes: openArray[ThemeFile]; current, follows: string; label: string;
    marks: var Marks): ThemeMenu =
  ## The submenu, labelled `label`. `current` is the file of the theme chosen
  ## ("" for following the system), `follows` the file "Follow system" uses
  ## now.
  result = ThemeMenu()
  result.open = igBeginMenu(label.cstring, true)
  marks.mark("menu.Theme")
  if result.open:
    let room = swatchRoom()
    var followed = builtinTheme(tmDark)
    for f in themes:
      if f.name == follows: followed = f.theme
    entry("Follow system##follow", "", followed, current.len == 0, room, result, marks)
    for mode in ThemeMode:
      var listed: seq[(string, int)]
      for i, f in themes:
        if f.theme.mode == mode: listed.add (f.title, i)
      listed.sort()
      if listed.len > 0:
        igSeparatorText(cstring(if mode == tmDark: "Dark" else: "Light"))
      for (_, i) in listed:
        let f = themes[i]
        entry(f.title & "##" & f.name, f.name, f.theme, f.name == current, room, result,
          marks)
    igEndMenu()
