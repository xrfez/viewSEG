## The main menu bar and its keyboard shortcuts. Each item is reachable both
## ways, and its shortcut is shown in the menu. Drawing returns what the user
## asked for; the caller acts on it.

import imguin/cimgui

type
  MenuAction* = enum
    maOpenFile = "Open file...", maOpenFiles = "Open files...",
    maOpenFolder = "Open folder...", maQuit = "Quit"

const shortcuts: array[MenuAction, ImGuiKeyChord] = [
  maOpenFile: ImGui_Mod_Ctrl.cint or ImGui_Key_O.cint,
  maOpenFiles: ImGui_Mod_Ctrl.cint or ImGui_Mod_Shift.cint or ImGui_Key_O.cint,
  maOpenFolder: ImGui_Mod_Ctrl.cint or ImGui_Mod_Alt.cint or ImGui_Key_O.cint,
  maQuit: ImGui_Mod_Ctrl.cint or ImGui_Key_Q.cint]
  ## ImGui shows Ctrl as Cmd on macOS and matches it there.

proc drawMainMenu*(): set[MenuAction] =
  ## The menu bar over the main window, plus the shortcuts, which work whether
  ## or not a menu is open.
  result = {}
  for a in MenuAction:
    if igShortcut_Nil(shortcuts[a], ImGui_InputFlags_RouteGlobal.cint):
      result.incl a
  if igBeginMainMenuBar():
    if igBeginMenu("File", true):
      for a in MenuAction:
        if a == maQuit:
          igSeparator()
        if igMenuItem_Bool(cstring($a), igGetKeyChordName(shortcuts[a]), false, true):
          result.incl a
      igEndMenu()
    igEndMainMenuBar()
