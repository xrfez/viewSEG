## The main menu bar and its keyboard shortcuts. Each item is reachable both
## ways, and its shortcut is shown in the menu and in the toolbar's tooltips.
## Drawing returns what the user asked for; the caller acts on it.

import imguin/cimgui
import ../../view/theme
import icons

type
  MenuAction* = enum
    maOpenFile = "Open file...", maOpenFiles = "Open files...",
    maOpenFolder = "Open folder...", maQuit = "Quit",
    maToggleTheme = "Light / dark"

  MenuResult* = object
    actions*: set[MenuAction]
    pickedTheme*: bool  ## a theme was chosen under View > Theme
    theme*: string      ## its file name, or "" for "Follow system"

const
  shortcuts: array[MenuAction, ImGuiKeyChord] = [
    maOpenFile: ImGui_Mod_Ctrl.cint or ImGui_Key_O.cint,
    maOpenFiles: ImGui_Mod_Ctrl.cint or ImGui_Mod_Shift.cint or ImGui_Key_O.cint,
    maOpenFolder: ImGui_Mod_Ctrl.cint or ImGui_Mod_Alt.cint or ImGui_Key_O.cint,
    maQuit: ImGui_Mod_Ctrl.cint or ImGui_Key_Q.cint,
    maToggleTheme: 0]
    ## ImGui shows Ctrl as Cmd on macOS and matches it there; 0 = none.
  menuIcons: array[MenuAction, string] = [IconOpenFile, IconOpenFiles, IconOpenFolder,
    IconQuit, IconTheme]

proc shortcutName*(a: MenuAction): string =
  ## The shortcut of `a` as shown to the user ("Ctrl+O"), or "".
  if shortcuts[a] == 0: "" else: $igGetKeyChordName(shortcuts[a])

proc label(a: MenuAction): string =
  menuIcons[a] & "  " & $a

proc drawMainMenu*(themes: openArray[ThemeFile]; selected: string): MenuResult =
  ## The menu bar over the main window, plus the shortcuts, which work whether
  ## or not a menu is open. `themes` are listed under View > Theme, with
  ## `selected` ("" for following the system) checked.
  result = MenuResult()
  for a in MenuAction:
    if shortcuts[a] != 0 and igShortcut_Nil(shortcuts[a], ImGui_InputFlags_RouteGlobal.cint):
      result.actions.incl a
  igPushStyleVar_Float(ImGui_StyleVar_WindowBorderSize.cint, 0) # one block with the toolbar
  let open = igBeginMainMenuBar()
  igPopStyleVar(1)
  if open:
    if igBeginMenu("File", true):
      for a in maOpenFile .. maQuit:
        if a == maQuit:
          igSeparator()
        if igMenuItem_Bool(label(a).cstring, shortcutName(a).cstring, false, true):
          result.actions.incl a
      igEndMenu()
    if igBeginMenu("View", true):
      if igBeginMenu((IconTheme & "  Theme").cstring, true):
        if igMenuItem_Bool("Follow system", nil, selected.len == 0, true):
          (result.pickedTheme, result.theme) = (true, "")
        if themes.len > 0:
          igSeparator()
        for f in themes:
          if igMenuItem_Bool(displayName(f.name).cstring, nil, f.name == selected, true):
            (result.pickedTheme, result.theme) = (true, f.name)
        igEndMenu()
      if igMenuItem_Bool(label(maToggleTheme).cstring, nil, false, true):
        result.actions.incl maToggleTheme
      igEndMenu()
    igEndMainMenuBar()
