## The "Reopen with options" dialog (File > Reopen with options..., or the
## button on the Headers window's Summary): the options a file is opened
## again with, for the cases detection gets wrong. Its standard (detected,
## or named: SEG-Y, SEG-D, SEG-2), every trace header checked at the open,
## two's-complement mantissas (SEG-D format 8015, SEG-2 format 3), how its
## bytes are reached (automatic, mapped, unmapped), and where a multiplexed
## SEG-D file's demultiplexed copy goes. Each says what it is for when
## pointed at; the dialog says what the file was opened with now. Reopen
## asks `core` for it (`ckReopen`): the file is read again, never written;
## its kills and polarity reversals stay (they are kept beside it).
##
## A modal popup: Enter reopens, Escape cancels.

import std/os
import imguin/cimgui
from parseSEG import faMapped, faUnmapped
import ../../core/state
import ../../view/theme
import marks, style

type
  ReopenUi* = object
    ## The dialog's own state between frames.
    ask: bool                ## open the popup next frame
    path: string             ## the file it reopens
    choice: OpenChoice       ## the options as chosen so far
    now: OpenFacts           ## how the file was opened last
    demux: array[1024, char] ## the demultiplexed copy's folder, being typed

const PopupId = "Reopen with options###reopen"

proc open*(ui: var ReopenUi; path: string; current: OpenChoice; now: OpenFacts) =
  ## Shows the dialog for file `path`, with the options it opens with now
  ## (`current`) and what its last open did (`now`).
  ui.ask = true
  ui.path = path
  ui.choice = current
  ui.now = now
  zeroMem(addr ui.demux[0], ui.demux.len)
  for i, c in current.demuxDir:
    if i < ui.demux.high: ui.demux[i] = c

func shown*(ui: ReopenUi): bool {.inline.} =
  ## Whether the dialog is asked for or open (for tests: `path` it is for).
  ui.path.len > 0

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc dim(t: Theme; text: string) =
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igPushTextWrapPos(igGetFontSize() * 34)
  igTextUnformatted(text.cstring, nil)
  igPopTextWrapPos()
  igPopStyleColor(1)

func standardTip(s: StandardChoice): string =
  case s
  of scDetect: "Recognise the standard from the file's first bytes (the default)"
  of scSegy: "Read the file as SEG-Y (a textual header, a binary header, then traces), " &
    "whatever its first bytes look like"
  of scSegd: "Read the file as SEG-D (general headers, channel sets, then traces)"
  of scSeg2: "Read the file as SEG-2 (a file descriptor block, then trace descriptors)"

func accessTip(a: AccessChoice): string =
  case a
  of acAuto: "A file on a network share is read unmapped, any other mapped (the default)"
  of acMapped: "The system pages the file in as it is read: the fastest on a local disk; " &
    "a drive that fails makes every later read of the file fail until it is opened again"
  of acUnmapped: "Read into viewSEG's own cache: a drive that fails fails only that read, " &
    "and the next read tries again; slower on a local disk"

proc drawReopen*(ui: var ReopenUi; t: Theme; marks: var Marks): seq[Command] =
  ## The dialog, when asked for: Reopen gives the `ckReopen` to apply.
  if ui.ask:
    igOpenPopup_Str(PopupId, 0)
    ui.ask = false
  igSetNextWindowSize(ImVec2_c(x: igGetFontSize() * 36, y: 0), ImGui_Cond_Appearing.cint)
  if not igBeginPopupModal(PopupId, nil, ImGui_WindowFlags_AlwaysAutoResize.cint):
    ui.path = ""
    return
  marks.markWindow("reopen")
  igPushTextWrapPos(igGetFontSize() * 34)
  igTextUnformatted((ui.path.extractFilename & " is read again with these options, in " &
    "the windows that show it; its kills and polarity reversals stay. The file is only " &
    "read, never changed.").cstring, nil)
  igPopTextWrapPos()
  igSpacing()
  igAlignTextToFramePadding()
  igTextUnformatted("Standard", nil)
  for s in StandardChoice:
    igSameLine(0, -1)
    let label = (if s == scDetect: "Detect" else: $s) & "##standard" & $ord(s)
    if igRadioButton_Bool(label.cstring, ui.choice.standard == s): ui.choice.standard = s
    marks.mark("reopen.standard " & $s)
    tip(standardTip(s))
  dim(t, "Read as " & standardName(ui.now.kind) & " now" &
    (if ui.now.choice.standard != scDetect: ", as chosen" else: ", detected") & ".")
  igSpacing()
  var verify = ui.choice.verifyAll
  if igCheckbox("Check every trace header", addr verify): ui.choice.verifyAll = verify
  marks.mark("reopen.verify")
  tip("Read every trace header at the open and report those that disagree with the " &
    "binary header. A fixed-length SEG-Y file is otherwise indexed from its size and 64 " &
    "of its headers. Slower on a large file")
  var twos = ui.choice.twosComplement
  if igCheckbox("Two's-complement mantissas (SEG-D format 8015, SEG-2 format 3)", addr twos):
    ui.choice.twosComplement = twos
  marks.mark("reopen.twos")
  tip("Some recorders write the mantissas of these 20-bit formats as two's complement, " &
    "not as the standard's sign and magnitude: tick this when such a file's traces look " &
    "like noise with spikes")
  igSpacing()
  igAlignTextToFramePadding()
  igTextUnformatted("Reading", nil)
  for a in AccessChoice:
    igSameLine(0, -1)
    let label = (case a
      of acAuto: "Automatic"
      of acMapped: "Mapped"
      of acUnmapped: "Unmapped") & "##access" & $ord(a)
    if igRadioButton_Bool(label.cstring, ui.choice.access == a): ui.choice.access = a
    marks.mark("reopen.access " & $a)
    tip(accessTip(a))
  dim(t, (case ui.now.access
    of faMapped: "Mapped now."
    of faUnmapped: "Unmapped now."
    else: "Not read now."))
  igSpacing()
  let segd = ui.choice.standard in {scDetect, scSegd}
  igBeginDisabled(not segd)
  igTextUnformatted("Folder of a demultiplexed copy", nil)
  igSetNextItemWidth(igGetFontSize() * 34)
  discard igInputTextWithHint("##demux", "the system's temporary folder",
    cast[cstring](addr ui.demux[0]), csize_t(ui.demux.len), 0, nil, nil)
  marks.mark("reopen.demux")
  tip("A multiplexed SEG-D file is read from a demultiplexed copy, written here and " &
    "deleted when the file is closed. Empty: the system's temporary folder")
  igEndDisabled()
  ui.choice.demuxDir = $cast[cstring](addr ui.demux[0])
  igSpacing()
  igSeparator()
  let enter = igIsKeyPressed_Bool(ImGui_Key_Enter, false) and
    not igGetIO_Nil().WantTextInput
  if igButton("Reopen", ImVec2_c(x: 0, y: 0)) or enter:
    result.add Command(kind: ckReopen, reopenPath: ui.path, openChoice: ui.choice)
    ui.path = ""
    igCloseCurrentPopup()
  marks.mark("reopen.reopen")
  tip("Close the file and open it again with these options")
  igSameLine(0, -1)
  if igButton("Defaults", ImVec2_c(x: 0, y: 0)):
    ui.choice = OpenChoice()
    zeroMem(addr ui.demux[0], ui.demux.len)
  marks.mark("reopen.defaults")
  tip("Every option back to its default (detect the standard, a sample of the headers, " &
    "automatic reading); Reopen then opens the file as at first")
  igSameLine(0, -1)
  if igButton("Cancel", ImVec2_c(x: 0, y: 0)) or igIsKeyPressed_Bool(ImGui_Key_Escape, false):
    ui.path = ""
    igCloseCurrentPopup()
  marks.mark("reopen.cancel")
  igEndPopup()
