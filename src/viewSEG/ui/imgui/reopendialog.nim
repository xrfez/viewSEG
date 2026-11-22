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

import std/[os, strutils]
import imguin/cimgui
from parseSEG import faMapped, faUnmapped
import ../../core/state
import ../../view/theme
import marks, placement, style

type
  ReopenUi* = object
    ## The dialog's own state between frames.
    ask: bool                 ## open the popup next frame
    path: string              ## the file it reopens
    choice: OpenChoice        ## the options as chosen so far
    now: OpenFacts            ## how the file was opened last
    demux: array[1024, char]  ## the demultiplexed copy's folder, being typed
    kind: SignatureKind       ## a vibrator signature file's kind: it has options of its own
    interval: array[32, char] ## its sample interval in us, being typed
    all: bool                 ## the options are for every file of its kind in the listing
    problem: string           ## why the interval typed cannot be used

const PopupId = "Reopen with options###reopen"

proc setInterval(ui: var ReopenUi; us: float64) =
  zeroMem(addr ui.interval[0], ui.interval.len)
  let text = if us > 0: ($us).replace(".0", "") else: ""
  for i, c in text:
    if i < ui.interval.high: ui.interval[i] = c

proc open*(ui: var ReopenUi; path: string; current: OpenChoice; now: OpenFacts;
    kind = sgNone) =
  ## Shows the dialog for file `path`, with the options it opens with now
  ## (`current`) and what its last open did (`now`). A vibrator signature file (`kind`) is
  ## offered its own options instead: its sample interval, its force wiring (`.dat`) or its
  ## time zero (`.vib`), and whether they hold for every file of its kind in the listing.
  ui.ask = true
  ui.path = path
  ui.choice = current
  ui.now = now
  ui.kind = kind
  ui.all = false
  ui.problem = ""
  ui.setInterval(if current.signature.intervalUs > 0: current.signature.intervalUs
    else: (if kind == sgNone: 0.0 else: defaultIntervalUs(kind)))
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

proc drawSignatureOptions(ui: var ReopenUi; t: Theme; marks: var Marks): seq[Command] =
  ## The dialog's body for a vibrator signature file: it is decoded, not read as SEG-Y or SEG-D,
  ## so only what the decoding may be told is offered.
  let name = ui.path.extractFilename
  let dat = ui.kind == sgDat
  let ext = if dat: ".dat" else: ".vib"
  igPushTextWrapPos(igGetFontSize() * 34)
  igTextUnformatted((name & " is decoded again with these options, in the windows that show " &
    "it. The file is only read, never changed.").cstring, nil)
  igPopTextWrapPos()
  igSpacing()
  igAlignTextToFramePadding()
  igTextUnformatted("Sample interval (us)", nil)
  igSameLine(0, -1)
  igSetNextItemWidth(igGetFontSize() * 8)
  discard igInputText("##interval", cast[cstring](addr ui.interval[0]), csize_t(ui.interval.len),
    0, nil, nil)
  marks.mark("reopen.interval")
  tip("The file does not state its sample interval: " & $defaultIntervalUs(ui.kind) &
    " us is assumed for a " & ext & ". Type the interval the controller was set to.")
  if dat:
    var swap = ui.choice.signature.swapForces
    if igCheckbox("This unit's force channels are wired the other way round", addr swap):
      ui.choice.signature.swapForces = swap
    marks.mark("reopen.swap")
    tip("Swaps which force channel is the reaction mass and which the baseplate. The trace " &
      "codes follow, so the Vibrator window's roles follow too. No sign is changed.")
  else:
    var first = ui.choice.signature.fromFirstFrame
    if igCheckbox("t = 0 at the first frame", addr first):
      ui.choice.signature.fromFirstFrame = first
    marks.mark("reopen.firstframe")
    tip("For when the trigger estimated from the reference is wrong: time zero is then the " &
      "first frame of the file, not the trigger.")
  igSpacing()
  igCheckbox(("Use these for every " & ext & " file of this listing##all").cstring, addr ui.all)
  marks.mark("reopen.all")
  tip("For this run only, and while the folder listed stays: every " & ext & " file shown " &
    "from the list opens with these options. Not saved.")
  if ui.problem.len > 0:
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
    igTextUnformatted(ui.problem.cstring, nil)
    igPopStyleColor(1)
    marks.mark("reopen.problem")
  igSpacing()
  igSeparator()
  let enter = igIsKeyPressed_Bool(ImGui_Key_Enter, false) and not igGetIO_Nil().WantTextInput
  if igButton("Reopen", ImVec2_c(x: 0, y: 0)) or enter:
    let typed = ($cast[cstring](addr ui.interval[0])).strip
    var us = 0.0
    var good = true
    if typed.len > 0:
      try:
        us = parseFloat(typed)
      except ValueError:
        good = false
      good = good and us > 0 and us < Inf
    if not good:
      ui.problem = "The sample interval must be a number of microseconds above 0."
    else:
      ui.choice.signature.intervalUs = if us == defaultIntervalUs(ui.kind): 0.0 else: us
      result.add Command(kind: ckReopen, reopenPath: ui.path, openChoice: ui.choice,
        reopenAll: ui.all)
      ui.path = ""
      igCloseCurrentPopup()
  marks.mark("reopen.reopen")
  tip("Decode the file again with these options")
  igSameLine(0, -1)
  if igButton("Defaults", ImVec2_c(x: 0, y: 0)):
    ui.choice = OpenChoice()
    ui.setInterval(defaultIntervalUs(ui.kind))
    ui.problem = ""
  marks.mark("reopen.defaults")
  tip("Every option back to its default")
  igSameLine(0, -1)
  if igButton("Cancel", ImVec2_c(x: 0, y: 0)) or igIsKeyPressed_Bool(ImGui_Key_Escape, false):
    ui.path = ""
    igCloseCurrentPopup()
  marks.mark("reopen.cancel")
  igEndPopup()

proc drawReopen*(ui: var ReopenUi; t: Theme; marks: var Marks): seq[Command] =
  ## The dialog, when asked for: Reopen gives the `ckReopen` to apply.
  if ui.ask:
    igOpenPopup_Str(PopupId, 0)
    ui.ask = false
  igSetNextWindowSize(ImVec2_c(x: igGetFontSize() * 36, y: 0), ImGui_Cond_Appearing.cint)
  centreModal(PopupId)
  if not igBeginPopupModal(PopupId, nil, ImGui_WindowFlags_AlwaysAutoResize.cint):
    ui.path = ""
    return
  marks.markWindow("reopen")
  if ui.kind != sgNone:
    return ui.drawSignatureOptions(t, marks)
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
  tip("Close this box without reopening the file (Escape)")
  igEndPopup()
