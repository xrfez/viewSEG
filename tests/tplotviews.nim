## The plot table the toolbar and both menus read (`ui/imgui/plotviews`):
## FFT, then the six New plot views in Window > New plot's order, each with
## its own icon and one sentence. The names are the views' own, so a menu
## that reads the table cannot drift from `viewName`.
##
## Seen to fail: with the FFT row moved after Spectrogram, "FFT is first";
## with Spectrogram and Envelope given the same icon, "icons are distinct".

import std/[sets, strutils]
import viewSEG/core/analysis
import viewSEG/ui/imgui/[icons, plotviews]

block order:
  doAssert PlotEntries.len == 7
  doAssert PlotEntries[0].fft and PlotEntries[0].name == "FFT", "FFT is first"
  doAssert PlotEntries[0].shortcut == "F"
  var i = 0
  for v in AnalysisView:
    inc i
    let e = PlotEntries[i]
    doAssert not e.fft and e.view == v, "New plot order: " & $v
    doAssert e.name == v.viewName, e.name & " is not " & v.viewName
    doAssert e.shortcut.len == 0, $v
    doAssert entry(v) == e

block ownIcons:
  var icons: HashSet[string]
  var sentences: HashSet[string]
  for e in PlotEntries:
    doAssert e.icon.len == 3 and e.sentence.len > 0, e.name
    doAssert e.icon notin icons, "icons are distinct: " & e.name
    doAssert e.sentence notin sentences, "sentences are distinct: " & e.name
    icons.incl e.icon
    sentences.incl e.sentence
  # none of the glyphs already used for another action
  const taken = [IconOpenFile, IconOpenFiles, IconOpenFolder, IconFolder, IconProject,
    IconSave, IconSettings, IconLog, IconMap, IconFilter, IconEye, IconEyeOff, IconZoomIn,
    IconZoomOut, IconFit, IconPlay, IconStep, IconPrevious, IconNext, IconWarning,
    IconError, IconInfo, IconClose, IconCheck, IconTheme, IconTable, IconPlot, IconPulse,
    IconLayers, IconTarget, IconLocation, IconRefresh, IconArrowUp, IconArrowDown,
    IconTrash, IconCopy, IconClearAll, IconTasks, IconList, IconGoTo, IconExport,
    IconHistory, IconRecordBack, IconRecordNext, IconRecords, IconNew, IconWriting,
    IconFollow, IconAgent, IconUndo, IconRedo, IconTray, IconMinimize]
  for e in PlotEntries:
    doAssert e.icon notin taken, e.name & " reuses an action icon"

block tip:
  let off = PlotEntries[0].tip(false)
  doAssert off.startsWith("FFT\n")
  doAssert SelectTracesFirst in off
  doAssert SelectTracesFirst notin PlotEntries[0].tip(true)

echo "tplotviews: ok"
