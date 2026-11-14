## The main menu bar and its keyboard shortcuts. Each item is reachable both
## ways, and its shortcut is shown in the menu and in the toolbar's tooltips.
## Drawing returns what the user asked for; the caller acts on it.

import std/os
import imguin/cimgui
import ../../core/layouts
import ../../view/theme
import icons

type
  MenuAction* = enum
    maOpenFile = "Open file...", maOpenFiles = "Open files...",
    maOpenFolder = "Open folder...", maClose = "Close", maQuit = "Quit",
    maToggleTheme = "Light / dark",
    maExportSettings = "Export...", maImportSettings = "Import...",
    maResetSettings = "Reset to defaults",
    maSaveLayout = "Save as...", maResetLayout = "Reset",
    maExportLayout = "Export... ", maImportLayout = "Import... "

  MenuInput* = object
    ## What the menus show besides their fixed items.
    themes*: seq[ThemeFile]     ## listed under View > Theme
    theme*: string              ## the one checked; "" for following the system
    recent*: seq[string]        ## File > Open recent, newest first
    recentFolders*: seq[string] ## the folders there, newest first
    canClose*: bool             ## a file is shown, so File > Close closes it
    layouts*: seq[SavedLayout]  ## View > Layout > Load: the user's, then the presets
    keepsLayouts*: bool         ## layouts can be saved by name (the program keeps its settings)

  MenuResult* = object
    actions*: set[MenuAction]
    pickedTheme*: bool    ## a theme was chosen under View > Theme
    theme*: string        ## its file name, or "" for "Follow system"
    openRecent*: string   ## a recent file to open; "" for none
    browseRecent*: string ## a recent folder to list; "" for none
    clearRecent*: bool    ## "Clear the list" under File > Open recent
    loadLayout*: string   ## a layout file to load; "" for none

const
  shortcuts: array[MenuAction, ImGuiKeyChord] = [
    maOpenFile: ImGui_Mod_Ctrl.cint or ImGui_Key_O.cint,
    maOpenFiles: ImGui_Mod_Ctrl.cint or ImGui_Mod_Shift.cint or ImGui_Key_O.cint,
    maOpenFolder: ImGui_Mod_Ctrl.cint or ImGui_Mod_Alt.cint or ImGui_Key_O.cint,
    maClose: ImGui_Mod_Ctrl.cint or ImGui_Key_W.cint,
    maQuit: ImGui_Mod_Ctrl.cint or ImGui_Key_Q.cint,
    maToggleTheme: 0, maExportSettings: 0, maImportSettings: 0, maResetSettings: 0,
    maSaveLayout: 0, maResetLayout: 0, maExportLayout: 0, maImportLayout: 0]
    ## ImGui shows Ctrl as Cmd on macOS and matches it there; 0 = none.
  menuIcons: array[MenuAction, string] = [IconOpenFile, IconOpenFiles, IconOpenFolder,
    IconClose, IconQuit, IconTheme, IconSave, IconOpenFile, IconClose, IconSave, IconClose,
    IconSave, IconOpenFile]

proc shortcutName*(a: MenuAction): string =
  ## The shortcut of `a` as shown to the user ("Ctrl+O"), or "".
  if shortcuts[a] == 0: "" else: $igGetKeyChordName(shortcuts[a])

proc label(a: MenuAction): string =
  menuIcons[a] & "  " & $a

proc item(a: MenuAction; res: var MenuResult) =
  if igMenuItem_Bool(label(a).cstring, shortcutName(a).cstring, false, true):
    res.actions.incl a

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc drawRecent(recent, folders: openArray[string]; res: var MenuResult) =
  ## File > Open recent: the files, then the folders, newest first.
  if igBeginMenu((IconHistory & "  Open recent").cstring, true):
    if recent.len == 0 and folders.len == 0:
      igTextDisabled("Nothing opened yet")
    if recent.len > 0: igSeparatorText("Files")
    for i, path in recent:
      igPushID_Int(cint(i))
      if igMenuItem_Bool((IconOpenFile & "  " & path.extractFilename).cstring, nil, false, true):
        res.openRecent = path
      tip(path & "\nShown with its folder in the file list")
      igPopID()
    if folders.len > 0: igSeparatorText("Folders")
    for i, path in folders:
      igPushID_Int(cint(1000 + i))
      let name = if path.extractFilename.len > 0: path.extractFilename else: path
      if igMenuItem_Bool((IconFolder & "  " & name).cstring, nil, false, true):
        res.browseRecent = path
      tip(path & "\nIts seismic files in the file list")
      igPopID()
    if recent.len > 0 or folders.len > 0:
      igSeparator()
      if igMenuItem_Bool("Clear the list", nil, false, true):
        res.clearRecent = true
    igEndMenu()

proc drawLayoutMenu(input: MenuInput; res: var MenuResult) =
  ## View > Layout: how the windows are arranged.
  if igBeginMenu((IconLayers & "  Layout").cstring, true):
    igBeginDisabled(not input.keepsLayouts)
    item(maSaveLayout, res)
    tip("Keep the windows as they are now under a name, to load again")
    igEndDisabled()
    if igBeginMenu((IconFolder & "  Load").cstring, input.layouts.len > 0):
      var presets = false
      for i, e in input.layouts:
        if e.preset and not presets:
          if i > 0: igSeparator()
          igTextDisabled("Presets")
          presets = true
        igPushID_Int(cint(i))
        if igMenuItem_Bool(e.name.cstring, nil, false, true): res.loadLayout = e.path
        tip(e.path)
        igPopID()
      igEndMenu()
    item(maResetLayout, res)
    tip("The windows as they are when viewSEG first starts")
    igSeparator()
    item(maExportLayout, res)
    tip("Write the windows' arrangement to a file of your choice")
    item(maImportLayout, res)
    tip("Arrange the windows as such a file says, and keep it among the layouts")
    igEndMenu()

proc drawMainMenu*(input: MenuInput): MenuResult =
  ## The menu bar over the main window, plus the shortcuts, which work whether
  ## or not a menu is open.
  result = MenuResult()
  for a in MenuAction:
    if shortcuts[a] != 0 and igShortcut_Nil(shortcuts[a], ImGui_InputFlags_RouteGlobal.cint):
      result.actions.incl a
  igPushStyleVar_Float(ImGui_StyleVar_WindowBorderSize.cint, 0) # one block with the toolbar
  let open = igBeginMainMenuBar()
  igPopStyleVar(1)
  if open:
    if igBeginMenu("File", true):
      for a in maOpenFile .. maOpenFolder:
        item(a, result)
      drawRecent(input.recent, input.recentFolders, result)
      igBeginDisabled(not input.canClose)
      item(maClose, result)
      igEndDisabled()
      tip("Close the file the plot window shows")
      igSeparator()
      if igBeginMenu((IconSettings & "  Settings").cstring, true):
        item(maExportSettings, result)
        tip("Write every setting to a file of your choice, to keep or to take to " &
          "another computer")
        item(maImportSettings, result)
        tip("Take in the settings of such a file; those it does not hold stay as they are")
        igSeparator()
        item(maResetSettings, result)
        tip("Every setting back to its default (the recent files and the window's place " &
          "stay); the settings before are kept in a copy")
        igEndMenu()
      igSeparator()
      item(maQuit, result)
      igEndMenu()
    if igBeginMenu("View", true):
      if igBeginMenu((IconTheme & "  Theme").cstring, true):
        if igMenuItem_Bool("Follow system", nil, input.theme.len == 0, true):
          (result.pickedTheme, result.theme) = (true, "")
        if input.themes.len > 0:
          igSeparator()
        for f in input.themes:
          if igMenuItem_Bool(displayName(f.name).cstring, nil, f.name == input.theme, true):
            (result.pickedTheme, result.theme) = (true, f.name)
        igEndMenu()
      if igMenuItem_Bool(label(maToggleTheme).cstring, nil, false, true):
        result.actions.incl maToggleTheme
      igSeparator()
      drawLayoutMenu(input, result)
      igEndMenu()
    igEndMainMenuBar()
