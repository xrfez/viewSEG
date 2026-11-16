## Each action has its own icon, and an icon is not reused for a different
## action. Reading again keeps the refresh glyph; reset, stop, remove and
## import survey do not borrow close, refresh or the map.
##
## Seen to fail: with IconQuit set back to IconClose, "icons are distinct";
## with maResetSettings given IconRefresh, "reset settings is not a re-read";
## with Import survey labelled "Survey..." again, "survey words"; with
## redoShortcut returning "nope" instead of the chord name, "redo shows its
## real binding".

import std/[sets, strutils]
import imguin/cimgui
import viewSEG/ui/imgui/[headerstable, icons, menus]

block glyphs:
  var seen: HashSet[string]
  for icon in AllIcons:
    doAssert icon notin seen, "icons are distinct: U+" & toHex(codepoint(icon), 4)
    seen.incl icon
  doAssert IconQuit != IconClose, "quit is not close"
  doAssert IconStop != IconClose, "stop is not close"
  doAssert IconRemove != IconClose, "remove is not close"
  doAssert IconSurvey != IconMap, "import survey is not the map"

block readAgain:
  doAssert menuIcon(maReopen) == IconRefresh, "reopen reads the file again"
  doAssert menuIcon(maResetSettings) == IconReset, "reset settings is not a re-read"
  doAssert menuIcon(maResetWindows) == IconHome, "reset windows is not a re-read"
  doAssert menuIcon(maResetSettings) != menuIcon(maResetWindows)

block oneEach:
  doAssert menuIcon(maImportSurvey) == IconSurvey
  doAssert menuIcon(maShowMap) == IconMap
  doAssert menuIcon(maImportSettings) == IconSliders
  doAssert menuIcon(maExportSettings) == IconSliders
  doAssert menuIcon(maImportSettings) != IconSettings, "a settings file is not the gear"
  doAssert menuIcon(maImportLayout) == IconLayout
  doAssert menuIcon(maExportLayout) == IconLayout
  doAssert menuIcon(maImportLayout) != IconLayers, "a layout is not the map's layers"
  doAssert menuIcon(maFileMemory) == IconMemory
  doAssert menuIcon(maFileMemory) != IconHistory
  doAssert menuIcon(maExportLog) == IconExport
  doAssert menuIcon(maExportLog) != IconLog
  doAssert menuIcon(maShowMessages) == IconLog
  doAssert menuIcon(maQuit) == IconQuit
  doAssert menuIcon(maClose) == IconClose
  doAssert menuIcon(maCloseProject) == IconClose

block words:
  doAssert menuLabel(maOpenFile) == "Open file...", "open file words"
  doAssert menuLabel(maOpenFolder) == "Open folder..."
  doAssert menuLabel(maToggleTheme) == "Light / dark", "theme words"
  doAssert menuLabel(maImportSurvey) == "Import survey", "survey words"
  doAssert menuLabel(maExportLog) == "Export messages...", "export messages words"
  doAssert menuLabel(maImportSettings) == "Import settings..."
  doAssert menuLabel(maExportSettings) == "Export settings..."
  doAssert FollowWords == "Follow the latest file"
  doAssert "kills and polarity reversals stay" in ReopenTip
  doAssert FindRangeExample in findValueTip()
  doAssert "1001..1010" notin findValueTip(), "one range example"

block redoBinding:
  let ctx = igCreateContext(nil)
  defer: igDestroyContext(ctx)
  let y = $igGetKeyChordName(ImGui_Mod_Ctrl.cint or ImGui_Key_Y.cint)
  doAssert redoShortcut() == shortcutName(maRedo) & ", " & y, "redo shows its real binding"

echo "ticons: ok"
