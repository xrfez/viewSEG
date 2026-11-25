## The analysis windows (New plot): each a window of its own that docks,
## titled by what it shows ("Spectrogram 2: trace 12 · FFID 151 ·
## shot.sgd"), opened from Analysis > New plot or the plot's right-click menu
## on the selection or the trace under the pointer.
##
## Each shows a line of its view's settings (a spectrogram's frame length,
## overlap, floor and colour map; a phase spectrum's dB threshold and
## phase picture; a correlation's chosen reference and lags) and Freeze, a pin at the
## right of that line's first row, what it is
## of and through which filters, then its plots: an image in a density
## colour map with its scale (a spectrogram), or curve plots (`curveplot`)
## one under another, and what the cursor reads. The image's cursor follows
## the pointer, or is held by the keys while the window has the focus: Left
## and Right step a column (a frame), Up and Down a row (a frequency bin),
## Home and End go to the ends, Esc lets it go; its lines run to the axes,
## where its exact values are written. The windows read `core` and issue
## `Command`s: `ckPlotDisplay` for a setting, `ckPlotCursor` for a key,
## `ckClosePlot` when one is closed.

import std/[math, sets, strutils, tables]
import imguin/cimgui
import ../../core/[colourmaps, explain, geometry, plotcursor, plotoptions, state, units,
  vibprofile]
import ../../view/[analysisview, axisfit, curveplot, theme, vibfolderwords]
import chrome, curveplot as curves, explainmenu, fittext, overflow, icons, marks, placement,
    spectrumwindow,
  style

const
  CorrelationWidth = 900'f32    ## a correlation of several traces: room for its table's columns
  PlotSize = (640'f32, 620'f32) ## a window's first size, at 100 %
  VibratorSize = (780'f32, 980'f32)
    ## a vibrator signature's: its verdict, roles, limits table and all its plots, with
    ## nothing to scroll for one unit
  VibratorPlotLines = 5 ## the least a vibrator's plot is, in lines of text (others: 9)

type
  HeatCache = object
    ## An image cut down to the plot's pixels (`reduceImage`), kept while what it
    ## was made from (the answer, the view, the plot's size) is the same.
    gen: uint64
    view: array[4, float64]
    pixels: array[2, int]
    cells: ImageReduction

  PlotWindowsUi* = object
    ## The analysis windows' state between frames.
    curves: Table[int, seq[CurvePlotUi]]       ## per window id, per plot
    curveKeys: Table[int, seq[string]]
      ## per window id, what each of `curves` is the state of (a plot's axes), so a
      ## plot put in or taken out (the force from M and B, once both masses are
      ## entered) does not hand its neighbours its limits
    under: Table[int, PlotCursor] ## per window id: the cell under the pointer last frame
    readout*: Table[int, string] ## per window id: what its cursor read last frame (tests)
    toFront: HashSet[int] ## windows to bring forward when next drawn
    heat: Table[int, HeatCache] ## per window id: the image as drawn, cut to the pixels
    imageAxes: Table[int, AxisFit] ## per window id: what its image's axes were fitted to
    maps: array[ColourMap, int] ## ImPlot's index of each density colour map + 1; 0: not added
    findings: Table[int, seq[string]]
      ## per Vibrator window id: what its settings wheel's groups hold that is a finding, told
      ## under the verdict (the wheel carries a warning mark while there is one)
    how: Table[int, string]
      ## per Vibrator window id: what its numbers are measured against and what they are, in
      ## words, which is the Roles button's tooltip
    rolesAsk: Table[int, string]
      ## per Vibrator window id: the roles popover is to open, pointing at this row (the
      ## polarity line's "Roles..." button)
    rolesRow: Table[int, string] ## the row the open roles popover points at
    rolesSize, wheelSize, limitsSize: ImVec2_c ## the popovers' sizes as drawn last
    weights: tuple[revision, paired, entries: int; found: FleetWeights] = (-1, 0, 0,
      FleetWeights())
      ## the weights per vibrator, of the file list and so one for every window: keyed by its
      ## revision (bumped on every change of an entry or of the pairs) and sizes

  PlotWindowsOutput* = object
    commands*: seq[Command]
    notes*: seq[string]   ## a value the boxes refused, in the unit the user typed
    openReferences*: bool ## the References button was pressed

const PeakFromMassesTip = "Judged on GF from M and B: the peak force formed from the masses " &
  "and the accelerations can read lower than the vibrator's own peak force figure (about " &
  "5 % lower at the median on the files reviewed), so a peak near the limit may pass here " &
  "and be flagged there. The numbers are not adjusted"

var forcedVibratorSize*: (float32, float32) = (0'f32, 0'f32)
  ## tests: a vibrator window is held at this size (points), as a dock pane would hold it;
  ## 0: the window keeps its own

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

const ResetTip = "Back to the built-in options for this kind of plot. They are then what a " &
  "new window of this kind opens with"

const PhaseAgainstTips = [
  paReference: "The trace's instantaneous phase minus the chosen reference's, in degrees, " &
    "against time: 0 where the two keep step. Needs a reference chosen in References",
  paSelf: "The trace's own instantaneous phase: it turns once per cycle, so it only shows " &
    "the frequency"]

const PlotFreeze* = "keep these traces while the plot moves on"
  ## The Freeze pin's sentence. The pin's tooltip is that, after "Freeze: ".

proc follow(line: ControlLine; width: float32) =
  ## The next control of `width` on this line when it fits before the Freeze
  ## pin (or the window's right, once the line has wrapped), else the next.
  if line.fitsBefore(width, igGetStyle().ItemSpacing.x):
    igSameLine(0, -1)

proc textBoxWidth(text: string; box: float32): float32 =
  igCalcTextSize(text, nil, false, -1).x + igGetStyle().ItemSpacing.x + box

proc checkWidth(label: string): float32 =
  igGetFrameHeight() + igGetStyle().ItemInnerSpacing.x +
    igCalcTextSize(label.cstring, nil, false, -1).x

proc buttonWidth(text: string): float32 =
  igCalcTextSize(text, nil, false, -1).x + 2 * igGetStyle().FramePadding.x

func markName*(w: AnalysisWindow): string =
  ## The window's mark (and screenshot target): "new plot 2".
  "new plot " & $w.id

func windowTitle*(w: AnalysisWindow): string =
  ## Its ImGui title: its name, then its identity, which a layout keeps.
  IconPulse & "  " & w.title & "###newplot-" & $w.id

type Keys = object
  ## The cursor keys pressed this frame, while the window has the focus.
  left, right, up, down, home, ending, escape: bool

proc keysNow(focused: bool): Keys =
  ## The keys that move a cursor (repeating while held, as the spectrum
  ## windows' do); none while a box takes the keys or the window has no
  ## focus.
  if not focused or igGetIO_Nil().WantTextInput: return
  template held(k: untyped): bool = igShortcut_Nil(k.cint, ImGui_InputFlags_Repeat.cint)
  template once(k: untyped): bool = igShortcut_Nil(k.cint, 0)
  Keys(left: held(ImGui_Key_LeftArrow), right: held(ImGui_Key_RightArrow),
    up: held(ImGui_Key_UpArrow), down: held(ImGui_Key_DownArrow), home: once(ImGui_Key_Home),
    ending: once(ImGui_Key_End), escape: once(ImGui_Key_Escape))

proc numberBox(id: string; value: float64; width: float32; typed: var float64): bool =
  ## A box for a number: true once the user has finished typing into it.
  var v = cdouble(value)
  igSetNextItemWidth(width)
  discard igInputDouble(id.cstring, addr v, 0, 0, "%.9g", 0)
  typed = float64(v)
  igIsItemDeactivatedAfterEdit()

type HeldBox = object
  text: array[64, char]
  active: bool ## the box had the keyboard last frame: its text is the user's

var heldBoxes: Table[string, HeldBox]
  ## A limit box's text while it is being edited. Refilling from the stored
  ## value every frame wipes a number the user has not finished.

proc limitBox(id: string; value: float64; width: float32; typed: var float64): bool =
  ## A box for a limit, empty when it has none (NaN): true once the user
  ## has finished typing into it; nothing typed (or not a number) is none.
  if id notin heldBoxes: heldBoxes[id] = HeldBox()
  if not heldBoxes[id].active:
    zeroMem(addr heldBoxes[id].text[0], heldBoxes[id].text.len)
    let text = if value.isNaN: "" else: sensible(value)
    for i, c in text:
      if i < heldBoxes[id].text.high: heldBoxes[id].text[i] = c
  igSetNextItemWidth(width)
  discard igInputText(id.cstring, cast[cstring](addr heldBoxes[id].text[0]),
    csize_t(heldBoxes[id].text.len), ImGui_InputTextFlags_CharsScientific.cint, nil, nil)
  heldBoxes[id].active = igIsItemActive()
  let got = $cast[cstring](addr heldBoxes[id].text[0])
  typed = try: parseFloat(got.strip) except ValueError: NaN
  igIsItemDeactivatedAfterEdit()

proc drawReset(line: ControlLine; w: AnalysisWindow; name: string; marks: var Marks;
    p: var AnalysisParams; changed: var bool; signature = false) =
  ## "Reset options", on the control line: this kind's options back to the
  ## built-in ones (a plot of a kind with none has no button); a `signature`
  ## file's window keeps no typed drive level or 100 % force.
  if not w.view.hasOptions: return
  line.follow(buttonWidth("Reset options"))
  if igSmallButton("Reset options##reset"):
    p = builtin(w.view, p, signature)
    changed = true
  marks.mark(name & ".reset")
  tip(ResetTip)

proc phaseShowCombo(line: ControlLine; name: string; marks: var Marks;
    p: var AnalysisParams; changed: var bool) =
  ## "Phase: Absolute | Signed": the one rule of `core/phaseshow` for the phase plots.
  let width = round(igCalcTextSize("Absolute", nil, false, -1).x + igGetFrameHeight() +
    2 * igGetStyle().FramePadding.x)
  line.follow(textBoxWidth("Phase:", width))
  igAlignTextToFramePadding()
  igTextUnformatted("Phase:", nil)
  igSameLine(0, -1)
  igSetNextItemWidth(width)
  if igBeginCombo("##phaseshow", ($p.phaseShow).cstring, 0):
    for v in PhaseShow:
      if igSelectable_Bool(($v).cstring, v == p.phaseShow, 0, ImVec2_c(x: 0, y: 0)) and
          v != p.phaseShow:
        (p.phaseShow, changed) = (v, true)
      marks.mark(name & ".phase show " & $v)
    igEndCombo()
  marks.mark(name & ".phase show")
  tip(PhaseShowTip)

proc sameMass(a, b: float64): bool {.inline.} =
  a == b or (a.isNaN and b.isNaN)

proc cachedWeightFindings(ui: var PlotWindowsUi; st: AppState): FleetWeights =
  ## `vibWeightFindings`, worked out again only when the file list changed.
  let list = st.fileList
  if ui.weights.revision != list.revision or ui.weights.paired != list.pairs.len or
      ui.weights.entries != list.entries.len:
    ui.weights = (list.revision, list.pairs.len, list.entries.len, st.vibWeightFindings())
  ui.weights.found

proc placePopover(left, top: float32; size: ImVec2_c) =
  ## A popover's place: its left edge at `left`, its top at `top`, moved as far as needed to
  ## stay inside the main window (past its edge it would be a window of the desktop's own),
  ## and never larger than it.
  let vp = igGetMainViewport()
  let x = max(vp.WorkPos.x, min(left, vp.WorkPos.x + vp.WorkSize.x - size.x))
  let y = max(vp.WorkPos.y, min(top, vp.WorkPos.y + vp.WorkSize.y - size.y))
  igSetNextWindowPos(ImVec2_c(x: x, y: y), ImGui_Cond_Always.cint, ImVec2_c(x: 0, y: 0))
  igSetNextWindowSizeConstraints(ImVec2_c(x: 0, y: 0), vp.WorkSize, nil, nil)

proc group(title, name: string; marks: var Marks) =
  ## A headed group of the settings wheel, marked `name`.group `title`.
  igSeparatorText(title.cstring)
  marks.mark(name & ".group " & title)

proc wrapped(text: string; t: Theme; em = 30'f32; colour = rlTextDim) =
  ## A paragraph of `em` font sizes' width in the muted (or another role's) colour.
  igPushTextWrapPos(igGetCursorPos().x + em * igGetFontSize())
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[colour]))
  igTextUnformatted(text.cstring, nil)
  igPopStyleColor(1)
  igPopTextWrapPos()

func broken(text: string; cols = 70): string =
  ## `text` with a line break at a space near every `cols` characters, for a tooltip (which
  ## does not wrap).
  var width = 0
  for word in text.splitWhitespace:
    if width > 0 and width + 1 + word.len > cols:
      result.add '\n'
      width = 0
    elif width > 0:
      result.add ' '
      inc width
    result.add word
    width += word.len

func weightsFinding(found: FleetWeights): string =
  ## The weights finding in one line, for under the verdict ("" for none).
  if not found.flagged: return
  var who: seq[string] = @[]
  for v in found.vibrators:
    if v.differs or v.sensDiffers or v.unlike or v.sensUnlike: who.add "vibrator " & $v.vibrator
  let sets = setsWords(found)
  result = "Weights from the header differ across this folder" &
    (if who.len > 0: ": " & who.join(", ") elif sets.len > 0: ": " & sets[0] else: "") &
    " (listed in the settings wheel)"

proc vibFindings(ui: var PlotWindowsUi; st: AppState; w: AnalysisWindow; planeAt: int): seq[string] =
  ## What the settings wheel's groups hold that is a finding, one line each: the weights of the
  ## folder differ, a typed 100 % force not applied, the top frequency's warning, the
  ## controller's QC following set A while B is judged. They are told under the verdict, so
  ## that none is hidden behind the wheel.
  let kind = st.vibSignature(planeAt)
  if kind == sgVib:
    let line = weightsFinding(ui.cachedWeightFindings(st))
    if line.len > 0: result.add line
  if w.result.hundredProblem.len > 0: result.add w.result.hundredProblem
  if w.result.band.warning.len > 0: result.add w.result.band.warning
  if kind == sgVib and w.params.accelSet == asB and "follows set A" in w.result.controllerNote:
    result.add "The controller's QC report follows set A (probable) and this window judges " &
      "set B: choose set A in the settings wheel to compare like with like"

proc drawRolesPopover(ui: var PlotWindowsUi; st: AppState; w: AnalysisWindow; name: string;
    planeAt: int; forceNote: string; at: ImVec2_c; t: Theme; marks: var Marks;
    p: var AnalysisParams; changed: var bool) =
  ## The roles: a table (role, trace, polarity) in a popover under the Roles button. The one
  ## place to reverse a polarity: GF's, and M's with B following it. A signature file's
  ## channels are named by its codes: the traces cannot be changed, the polarity can.
  let names = st.vibTraceNames(w)
  var longest = igCalcTextSize("trace 00000", nil, false, -1).x
  for n in names: longest = max(longest, igCalcTextSize(n.cstring, nil, false, -1).x)
  let combo = round(longest + igGetFrameHeight() + 2 * igGetStyle().FramePadding.x)
  let polar = round(igCalcTextSize("as recorded", nil, false, -1).x + igGetFrameHeight() +
    2 * igGetStyle().FramePadding.x)
  # The project's chosen reference, offered first in the Ref role's list: what the unit
  # was meant to sweep, against the recorded trace of what it says it swept.
  var projectName = ""
  if st.referencesLoaded:
    let found = st.references.findId(st.chosenReference)
    if found >= 0 and not st.references.entries[found].missing:
      projectName = st.references.entries[found].name
  let projectLabel = "Project reference: " & projectName
  let projectOn = projectName.len > 0 and p.projectReference
  let refCombo = if projectName.len > 0:
                   max(combo, round(igCalcTextSize(projectLabel.cstring, nil, false, -1).x +
                     igGetFrameHeight() + 2 * igGetStyle().FramePadding.x))
                 else: combo
  let fileRefPlace = if planeAt >= 0: st.vibReferencePlace(planeAt) else: -1
  placePopover(at.x, at.y, ui.rolesSize)
  if not igBeginPopup("##roles", 0):
    ui.rolesRow.del w.id
    return
  ui.rolesSize = igGetWindowSize()
  marks.markWindow(name & ".roles popover")
  if planeAt >= 0:
    wrapped(st.vibRolesLine(w), t)
    marks.mark(name & ".roles line")
    let notes = st.vibChoiceNotes(w)
    if notes.len > 0:
      wrapped(notes[2 .. ^1].capitalizeAscii, t)
      marks.mark(name & ".choices")
  const flags = ImGui_TableFlags_SizingFixedFit.cint or ImGui_TableFlags_BordersInnerH.cint
  if igBeginTable(("##roles" & name).cstring, 3, flags, ImVec2_c(x: 0, y: 0), 0):
    igTableSetupColumn("Role", 0, 0, 0)
    igTableSetupColumn("Trace", 0, 0, 0)
    igTableSetupColumn("Polarity", 0, 0, 0)
    let pointed = ui.rolesRow.getOrDefault(w.id)
    template roleRow(role: string; field: untyped; what: string) =
      igTableNextRow(0, 0)
      if role == pointed:
        igTableSetBgColor(ImGui_TableBgTarget_RowBg1.cint,
          u32(withAlpha(t.roles[rlAccent], 60)), -1)
      discard igTableSetColumnIndex(0)
      igAlignTextToFramePadding()
      igTextUnformatted(role, nil)
      tip(what)
      discard igTableSetColumnIndex(1)
      let project = role == "Ref" and projectName.len > 0
      igSetNextItemWidth(if project: refCombo else: combo)
      let now = p.roles.field
      let fileRef = role == "Ref" and fileRefPlace >= 0
      let shown = if project and projectOn: projectLabel
                  elif fileRef and now == fileRefPlace: "This file's reference trace"
                  elif now in 0 ..< names.len: names[now]
                  else: "none"
      if igBeginCombo(("##" & role).cstring, shown.cstring, 0):
        if project:
          if igSelectable_Bool(projectLabel.cstring, projectOn, 0, ImVec2_c(x: 0, y: 0)) and
              not projectOn:
            (p.projectReference, changed) = (true, true)
          marks.mark(name & ".role Ref project")
          tip("What the unit was meant to sweep: the phase, frequency and force are " &
            "measured against the project's chosen reference. The recorded trace is then " &
            "measured against it too (Ref (recorded))")
        if fileRef:
          let on = now == fileRefPlace and not projectOn
          if igSelectable_Bool("This file's reference trace", on, 0, ImVec2_c(x: 0, y: 0)) and
              not on:
            (p.roles.field, changed) = (fileRefPlace, true)
            if project: p.projectReference = false
          marks.mark(name & ".role Ref file")
          tip("The record's trace with the vibrator reference code (21): the Ref role, " &
            "measured against by itself, not against the project reference")
        if igSelectable_Bool("none", now < 0 and not projectOn, 0,
            ImVec2_c(x: 0, y: 0)) and (now >= 0 or projectOn):
          (p.roles.field, changed) = (-1, true)
          if project: p.projectReference = false
        for i, n in names:
          igPushID_Int(cint(i))
          if igSelectable_Bool(n.cstring, i == now and not projectOn, 0,
              ImVec2_c(x: 0, y: 0)) and (i != now or projectOn):
            (p.roles.field, changed) = (i, true)
            if project: p.projectReference = false
          igPopID()
        igEndCombo()
      marks.mark(name & ".role " & role)
    template polarityCombo(role: string; field: untyped; what: string) =
      discard igTableSetColumnIndex(2)
      igSetNextItemWidth(polar)
      if igBeginCombo(("##polarity " & role).cstring, ($p.roles.field).cstring, 0):
        for v in Polarity:
          if v == poAutomatic and forceNote.len > 0: continue # (never offered for a signature file)
          if igSelectable_Bool(($v).cstring, v == p.roles.field, 0, ImVec2_c(x: 0, y: 0)) and
              v != p.roles.field:
            (p.roles.field, changed) = (v, true)
          marks.mark(name & ".polarity " & role & " " & $v)
        igEndCombo()
      marks.mark(name & ".polarity " & role)
      tip(what)
    # (a signature file's channels are named by its codes: its traces are not chosen, but a
    # polarity is)
    igBeginDisabled(forceNote.len > 0)
    roleRow("Ref", reference, "The reference: the pilot, the phase origin")
    discard igTableSetColumnIndex(2)
    if planeAt >= 0 and igSmallButton("Roles from the codes##codes"):
      p.roles = st.codeRoles(planeAt)
      changed = true
    marks.mark(name & ".roles from codes")
    tip("Ref is as recorded. This button: the roles as the traces' identification codes " &
      "give them, and the choice remembered for this file layout forgotten")
    igEndDisabled()
    igBeginDisabled(forceNote.len > 0)
    roleRow("GF", groundForce, "The ground force, as recorded")
    igEndDisabled()
    polarityCombo("GF", groundForcePolarity, "Reversed: times -1, for this analysis only: the " &
      "samples and the file stay as recorded. Remembered for this file layout. Automatic " &
      "(not for a signature file): reversed when its mean phase to the reference is past " &
      "±90° (wiring)")
    igBeginDisabled(forceNote.len > 0)
    roleRow("M", mass, "The reaction mass's acceleration")
    igEndDisabled()
    polarityCombo("M", massPolarity, "M's and B's polarity, together (the baseplate moves " &
      "against the mass). Automatic needs both and both masses: it is decided from the " &
      "force they make")
    igBeginDisabled(forceNote.len > 0)
    roleRow("B", baseplate, "The baseplate's acceleration")
    discard igTableSetColumnIndex(2)
    if igSmallButton("Swap mass and baseplate##swap"):
      swap(p.roles.mass, p.roles.baseplate)
      changed = true
    marks.mark(name & ".swap")
    tip("B has M's polarity. This button: the mass takes the baseplate's trace and the " &
      "baseplate the mass's. Remembered for files of this layout (the record's trace " &
      "count and codes), in the project when one is open")
    igEndDisabled()
    igEndTable()
  if forceNote.len > 0:
    igTextDisabled("from the controller's channels (trace codes)")
  igEndPopup()

proc drawGroundForceGroup(w: AnalysisWindow; name: string; planeAt: int; box: float32;
    t: Theme; marks: var Marks; p: var AnalysisParams; changed: var bool;
    res: var PlotWindowsOutput; st: AppState) =
  ## Which ground force is judged (when the unit has both), the harmonics, the phase picture
  ## and the top frequency.
  var typed = 0.0
  template label(text: string) =
    igAlignTextToFramePadding()
    igTextUnformatted(cstring(text), nil)
    igSameLine(0, -1)
  group("Ground force", name, marks)
  if w.result.bothSignals or w.result.canMake:
    const judgeNames = [joRecorded: "In the record", joWeighted: "Made from mass and baseplate"]
    label("Ground force:")
    igSetNextItemWidth(buttonWidth(judgeNames[joWeighted]) + igGetFrameHeight())
    if igBeginCombo("##judge", judgeNames[p.roles.judge].cstring, 0):
      for j in JudgeOn:
        if igSelectable_Bool(judgeNames[j].cstring, j == p.roles.judge, 0,
            ImVec2_c(x: 0, y: 0)) and j != p.roles.judge:
          (p.roles.judge, changed) = (j, true)
        marks.mark(name & ".judge " & $j)
      igEndCombo()
    marks.mark(name & ".judge")
    tip("Which ground force the window uses: its plots, the verdict and the limits table. " &
      "In the record is the trace coded as ground force, as it is. Made from mass and " &
      "baseplate is the weighted sum formed here, Mr·M + Mb·B, with the masses you typed (a " &
      "converter's SEG-Y file: its reaction-mass and baseplate weights, which undo the " &
      "converter's scaling). A .dat's channels are forces already (plain sum) and a .vib " &
      "uses its header's weights. Remembered with the roles, for this file layout")
    if w.result.madeNote.len > 0:
      wrapped(w.result.madeNote, t)
      marks.mark(name & ".judge note")
  label("Harmonics to")
  var h = cint(p.harmonics)
  igSetNextItemWidth(box)
  if igInputInt("##harmonics", addr h, 0, 0, 0) and HarmonicRange.allows(float64(h)) and
      h != p.harmonics:
    (p.harmonics, changed) = (int(h), true)
  marks.mark(name & ".harmonics")
  tip("The highest harmonic tracked (2 to 16): THD sums them from the 2nd")
  let line = beginControlLine()
  line.phaseShowCombo(name, marks, p, changed)
  # the top frequency of the sweep (the band distortion is judged in)
  let band = w.result.band
  let topKey = if planeAt >= 0: st.vibTopKey(st.plots[planeAt]) else: RecordedKey
  let typedTop = if planeAt >= 0: st.vibTyped(st.plots[planeAt]) else: p.tops.topOf(topKey)
  let shownTop = if typedTop.isNaN: (if band.hz.isNaN: NaN else: round(band.hz * 10) / 10)
                 else: typedTop
  label("Top frequency (Hz)")
  if limitBox("##topfrequency", shownTop, box, typed):
    if typed.isNaN:
      if not typedTop.isNaN: (p.tops, changed) = (p.tops.withTop(topKey, NaN), true)
    elif TopHzRange.allows(typed):
      if typed != shownTop: (p.tops, changed) = (p.tops.withTop(topKey, typed), true)
    else:
      res.notes.add "The top frequency must be " & TopHzRange.words & ", not " &
        sensible(typed) & "."
  marks.mark(name & ".top frequency")
  tip("The sweep's top frequency, Hz: distortion is the harmonics up to it (the in-band " &
    "distortion a vibrator controller reports), shown and judged here. A generated " &
    "reference fills it exactly with its end frequency; another is read from its " &
    "frequency track (a line to the sweep's end, to a whole hertz when it is within 0.5 % " &
    "of one: type the sweep's design value when it is not). Empty: from the reference. " &
    "What is typed is kept with the reference in the project")
  igSameLine(0, -1)
  igAlignTextToFramePadding()
  igTextDisabled(
    (if not typedTop.isNaN: "(typed)" elif band.hz.isNaN: "" else: "(from the reference)").cstring)
  marks.mark(name & ".top frequency source")

proc drawMassesGroup(w: AnalysisWindow; name: string; planeAt: int; box: float32;
    forceNote: string; t: Theme;
    marks: var Marks; p: var AnalysisParams; changed: var bool; res: var PlotWindowsOutput;
    st: AppState) =
  ## The reaction and baseplate masses, kg or lb: only where M and B are accelerations that
  ## need them. A signature file's channels are forces already (or its own weights are used):
  ## one muted line says so.
  var typed = 0.0
  template label(text: string) =
    igAlignTextToFramePadding()
    igTextUnformatted(cstring(text), nil)
    igSameLine(0, -1)
  if forceNote.len > 0:
    wrapped("No masses are asked for this file. " & forceNote & ". Made from mass and " &
      "baseplate (Ground force) uses the file's own weights.", t)
    marks.mark(name & ".masses note")
    return
  let units = st.settings.units
  let unitWord = massName(units)
  template takeMass(which: string; stored, shown: untyped) =
    # a number left as the box showed it is no edit (the box rounds a conversion)
    let kg = if typed.isNaN: NaN else: storeMass(typed, units)
    if not sameMass(typed, shown):
      if typed.isNaN or MassKgRange.allows(kg):
        if not sameMass(kg, stored): (stored, changed) = (kg, true)
      else:
        res.notes.add "The " & which & " must be " & massLimitWords(units) & ", not " &
          sensible(typed) & " " & unitWord & "."
  group("Masses", name, marks)
  # which trace each mass multiplies, as the roles say (the pickers can swap them)
  if planeAt >= 0 and p.roles.mass >= 0 and p.roles.baseplate >= 0:
    let names = st.vibTraceNames(w)
    if p.roles.mass < names.len and p.roles.baseplate < names.len:
      wrapped("The reaction mass multiplies " & names[p.roles.mass] & "; the baseplate mass " &
        names[p.roles.baseplate] & ". For a converter's SEG-Y file these are its reaction-" &
        "mass and baseplate weights, which undo the converter's scaling" &
        (if st.vibConverter(w): ", and its code 19 trace is the reaction mass's channel " &
          "(the roles are set that way; Swap mass and baseplate in Roles turns them)"
        else: "") & ".", t)
      marks.mark(name & ".masses traces")
  label("Reaction mass")
  let shownReaction = massBoxValue(p.reactionMassKg, units)
  if limitBox("##reaction." & $units, shownReaction, box, typed):
    takeMass("reaction mass", p.reactionMassKg, shownReaction)
  marks.mark(name & ".reaction mass")
  tip("The reaction mass, in " & unitWord & ": with the baseplate's, the ground force is " &
    "generated from M and B (Mr·M + Mb·B), drawn over the recorded one. Empty: none. " &
    "A mass is " & massLimitWords(units) & ".")
  igSameLine(0, -1)
  label("baseplate")
  let shownBase = massBoxValue(p.baseplateMassKg, units)
  if limitBox("##baseplate." & $units, shownBase, box, typed):
    takeMass("baseplate's mass", p.baseplateMassKg, shownBase)
  marks.mark(name & ".baseplate mass")
  tip("The baseplate's mass, in " & unitWord & ". Empty: none. A mass is " &
    massLimitWords(units) & ".")
  # kg | lb after both masses: it sets Units (the Settings window's switch), the
  # numbers convert in place and the stored kilograms stay; the unit shown is the
  # one selected.
  igSameLine(0, -1)
  for i, u in [usMetric, usImperial]:
    if i > 0: igSameLine(0, 0)
    let on = units == u
    if on:
      igPushStyleColor_Vec4(ImGui_Col_Button.cint, vec4(withAlpha(t.roles[rlAccent], 110)))
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlText]))
      igPushStyleColor_Vec4(ImGui_Col_Border.cint, vec4(t.roles[rlAccent]))
      igPushStyleVar_Float(ImGui_StyleVar_FrameBorderSize.cint, 1)
    else:
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
    if igButton((massName(u) & "##units").cstring, ImVec2_c(x: 0, y: 0)) and not on:
      var s = st.settings
      s.units = u
      res.commands.add Command(kind: ckSettings, settings: s)
    if on:
      igPopStyleVar(1)
      igPopStyleColor(3)
    else: igPopStyleColor(1)
    marks.mark(name & ".unit " & massName(u))
    tip("Show masses in " & massName(u) & " (" & systemName(u) & "). The numbers convert " &
      "in place, so the masses do not change; they are kept in kilograms. This is the " &
      "Units setting.")

proc drawForceGroup(w: AnalysisWindow; name: string; planeAt: int; box: float32;
    kind: SignatureKind; forceNote: string; t: Theme; marks: var Marks;
    p: var AnalysisParams; changed: var bool; res: var PlotWindowsOutput; st: AppState) =
  ## The 100 % force (and Set from this sweep), the target force and, for a signature file, the
  ## force scale. Nothing here changes a sample or a sign.
  var typed = 0.0
  template label(text: string) =
    igAlignTextToFramePadding()
    igTextUnformatted(cstring(text), nil)
    igSameLine(0, -1)
  let units = st.settings.units
  group("Force", name, marks)
  # the unit of the judged force (GF counts, or GF from M and B's kg x counts)
  let judgedAxis = if w.result.judgedAxis.len > 0: w.result.judgedAxis
                   else: forceAxisLabel(w.result.plots)
  let forceShown = forceLimitOf(judgedAxis, units)
  label("100 % force =")
  # the full scale of the signal judged (GF in counts, GF (M, B) in kg × counts)
  let weighted = w.result.judged == "GF (M, B)" and not w.result.sameAsRecorded
  let judgedUnit = unitOfLabel(judgedAxis)
  # (a signature file's typed 100 % force is shown as it is applied: in the unit now on the
  # axis, or not at all when it was typed in another unit and cannot be converted)
  let sigWin = forceNote.len > 0 and not weighted
  let shownHundred = if weighted: p.forceHundredWeighted
    elif sigWin and p.forceHundredPct > 0:
      (if w.result.hundredProblem.len > 0: NaN else: w.result.qc.hundredPct)
    else: p.forceHundredPct
  let hundred = showScaled(shownHundred, forceShown.divisor)
  if limitBox("##hundred." & (if weighted: "m." else: "g.") & forceShown.unit, hundred, box,
      typed):
    let stored = storeScaled(typed, forceShown.divisor)
    if typed.isNaN or MassKgRange.allows(stored):
      if sigWin and stored.isNaN:
        # emptied: no typed force (one not applied, shown empty, goes too)
        if not p.forceHundredPct.isNaN:
          (p.forceHundredPct, p.forceHundredUnit, changed) = (NaN, "", true)
      elif not (stored.isNaN and shownHundred.isNaN) and stored != shownHundred:
        if weighted: p.forceHundredWeighted = stored
        else: (p.forceHundredPct, p.forceHundredUnit) = (stored, judgedUnit)
        changed = true
    else:
      res.notes.add "100 % force must be above 0, not " & sensible(typed) & "."
  marks.mark(name & ".force target")
  tip("The force that is 100 % (full scale) of " &
    (if weighted: "the ground force made from M and B" else: "the ground force") &
    " (each has its own: counts, or kg x counts; a .dat's or .vib's two are the same), " &
    "in the unit of the signal judged" &
    (if forceShown.unit.len > 0: " (" & forceShown.unit & ")" else: "") &
    ". The file cannot tell it (no sensor sensitivities): take it from the vibrator's " &
    "own QC of one sweep. The peak force limit is in % of it; the average force limit is " &
    "in % of the target below. Empty: the force is not judged, and the limits table " &
    "says which box to fill")
  if forceShown.unit.len > 0:
    igSameLine(0, -1)
    igAlignTextToFramePadding()
    igTextUnformatted(forceShown.unit.cstring, nil)
    marks.mark(name & ".force unit")
  if w.result.hundredWords.len > 0 and p.forceHundredPct.isNaN:
    igSameLine(0, -1)
    igAlignTextToFramePadding()
    igTextDisabled(("(" & w.result.hundredWords & ")").cstring)
    marks.mark(name & ".hundred words")
  # (a problem is a finding, told under the verdict too; the hint is only help)
  let hint = if w.result.hundredProblem.len > 0: w.result.hundredProblem
             else: w.result.hundredHint
  if hint.len > 0:
    wrapped(hint, t, colour = rlWarning)
    marks.mark(name & ".hundred hint")
  # 100 % from this very sweep: its average force (the verdict's) over the target's share
  let average = w.result.qc.stats.avgForce
  let fromSweep = average / ((if p.targetPct > 0: p.targetPct else: 100.0) / 100)
  let fromSweepOk = MassKgRange.allows(fromSweep)
  igBeginDisabled(not fromSweepOk)
  if igSmallButton("Set from this sweep##hundred"):
    if weighted: p.forceHundredWeighted = fromSweep
    else: (p.forceHundredPct, p.forceHundredUnit) = (fromSweep, judgedUnit)
    changed = true
  igEndDisabled()
  marks.mark(name & ".set hundred")
  tip("Use on a sweep where the vibrator held its target force: 100 % force becomes this " &
    "sweep's average force divided by the target (" &
    (if p.targetPct > 0: sensible(p.targetPct) else: "100") & " %). Kept like a typed value" &
    (if fromSweepOk: "" else: ". Not available here: this sweep's value is " &
      (if fromSweep.isNaN: "not a number" else: sensible(fromSweep)) &
      ", which the setting does not take (" & MassKgRange.words & ")"))
  label("Target force (%)")
  # (a signature file's window: empty until typed, and emptied by clearing it; the limits
  # then take 100)
  let sigTarget = forceNote.len > 0
  if limitBox("##targetpct", p.targetPct, box, typed):
    if TargetPctRange.allows(typed):
      if typed != p.targetPct: (p.targetPct, changed) = (typed, true)
    elif typed.isNaN:
      if sigTarget:
        if not p.targetPct.isNaN: (p.targetPct, changed) = (NaN, true)
      elif p.targetPct != 100: (p.targetPct, changed) = (100.0, true)
    else:
      res.notes.add "The target force must be " & TargetPctRange.words & ", not " &
        sensible(typed) & "."
  marks.mark(name & ".target force")
  tip("The drive level the sweep was set to, % of 100 % force (the vibrator's force " &
    "setting, e.g. 60). The average force is judged as % of this target; the peak force " &
    "as % of the 100 % force. 100 when the sweep is at full scale. Empty: 100" &
    (if sigTarget: " for the limits, and not typed: a .dat's 100 % force from the " &
      "controller's target force needs the drive level typed here, in this window"
      else: ""))
  if kind != sgNone:
    let scale = st.settings.forceScale
    let (shown, id, what) = if kind == sgDat: (scale.datCountsPerLbf, "##datscale",
        "counts per lbf") else: (scale.vibAccMvPerCount, "##vibscale", "accelerometer constant")
    label("Force scale: " & what)
    if limitBox(id, shown, box, typed):
      if typed.isNaN or ForceScaleRange.allows(typed):
        if not sameMass(typed, shown):
          var s = st.settings
          if kind == sgDat: s.forceScale.datCountsPerLbf = typed
          else: s.forceScale.vibAccMvPerCount = typed
          res.commands.add Command(kind: ckSettings, settings: s)
      else:
        res.notes.add "The force scale must be " & ForceScaleRange.words & ", not " &
          sensible(typed) & "."
    marks.mark(name & ".force scale")
    tip((if kind == sgDat: "Your scale for a .dat's force channels: counts per pound-force. "
      else: "Your accelerometer constant: with the header's sensitivity it turns the pound-" &
        "counts of the ground force into pounds-force. ") &
      "Empty: the force stays in counts (pound-counts). It changes what is shown and judged, " &
      "never the samples. A local setting, kept in your settings and shipped with nothing")

proc drawAccelGroup(name: string; t: Theme; marks: var Marks; p: var AnalysisParams;
    changed: var bool) =
  ## A `.vib`'s accelerometer set: the window's own choice, not remembered for the next file.
  group("Accelerometer set", name, marks)
  igAlignTextToFramePadding()
  igTextUnformatted("Judge set", nil)
  for (which, text) in [(asB, "B"), (asA, "A")]:
    igSameLine(0, -1)
    if igRadioButton_Bool((text & "##set" & $which).cstring, p.accelSet == which) and
        p.accelSet != which:
      (p.accelSet, changed) = (which, true)
    marks.mark(name & ".set " & $which)
    tip((if which == asB: "B: the set the .dat file records (the default)"
      else: "A: the set the controller's QC report follows (probable)"))
  tip("Which of the two accelerometer sets the window judges: M, B and the ground force " &
    "computed from them. Set B is the default. This choice is this window's only: it is " &
    "not remembered for the next file")

proc drawWeightsGroup(ui: var PlotWindowsUi; st: AppState; planeAt: int; name: string;
    t: Theme; marks: var Marks) =
  ## A `.vib`'s weights from its header, and across the folder the weights per vibrator (a
  ## difference is a finding, in the warning colour; nothing is corrected).
  let found = ui.cachedWeightFindings(st)
  igSeparatorText((if found.flagged: "Weights from the header: a difference found"
    else: "Weights from the header").cstring)
  marks.mark(name & ".fleet header")
  marks.mark(name & ".group Weights from the header")
  let wts = st.vibWeights(planeAt)
  igPushTextWrapPos(igGetCursorPos().x + 34 * igGetFontSize())
  igTextUnformatted((weightsText(wts) & ".").cstring, nil)
  marks.mark(name & ".weights")
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextUnformatted(WeightsDepend.cstring, nil)
  igPopStyleColor(1)
  igAlignTextToFramePadding()
  igTextUnformatted("Weights per vibrator in this folder:", nil)
  template line(text: string; odd: bool) =
    if odd: igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
    igTextUnformatted(text.cstring, nil)
    if odd: igPopStyleColor(1)
  for v in found.vibrators:
    line(vibratorWords(v), v.differs or v.sensDiffers or v.unlike or v.sensUnlike)
  for i, l in setsWords(found): line(l, i == 0)
  if found.unknown > 0: line(unknownWords(found.unknown), false)
  marks.mark(name & ".fleet")
  igPopTextWrapPos()

proc drawJobWeightsGroup(st: AppState; name: string; box: float32; marks: var Marks;
    res: var PlotWindowsOutput) =
  ## The job's three weights, kept with the project and compared by the folder QC with each
  ## `.vib` header's (never applied). Empty is not set. Inactive without a project.
  let can = st.inProject
  igSeparatorText("Job weights (vibrator QC)")
  marks.mark(name & ".group Job weights")
  if not can: igBeginDisabled(true)
  let now = if can: st.project.doc.vibJobWeights else: VibJobWeights()
  var next = now
  var changed = false
  template one(label, id: string; field: untyped) =
    igAlignTextToFramePadding()
    igTextUnformatted(label, nil)
    igSameLine(0, -1)
    var typed = 0.0
    if limitBox(id, now.field, box, typed) and can:
      if typed.isNaN or MassKgRange.allows(typed):
        if typed != now.field and not (typed.isNaN and now.field.isNaN):
          next.field = typed
          changed = true
      else:
        res.notes.add "The weight must be " & MassKgRange.words & ", not " &
          sensible(typed) & "."
    marks.mark(name & ".job weight " & label)
    tip(if can: WeightsHint else: NeedProjectWeights)
    igSameLine(0, -1)
    igTextUnformatted("kg", nil)
  one(HoldDownLabel, "##jobholddown", holdDownKg)
  one(BaseplateLabel, "##jobbaseplate", baseplateMassKg)
  one(ReactionLabel, "##jobreaction", reactionMassKg)
  if not can: igEndDisabled()
  if changed: res.commands.add Command(kind: ckVibWeights, vibWeights: next)

proc drawWheel(ui: var PlotWindowsUi; st: AppState; w: AnalysisWindow; name: string;
    planeAt: int; kind: SignatureKind; forceNote: string; box: float32; at: ImVec2_c;
    t: Theme; marks: var Marks; p: var AnalysisParams; changed: var bool;
    res: var PlotWindowsOutput) =
  ## The settings wheel's popover, right-aligned under the wheel: headed groups, and only
  ## those that apply to the file shown.
  placePopover(at.x - ui.wheelSize.x, at.y, ui.wheelSize)
  if not igBeginPopup("##wheel", 0): return
  ui.wheelSize = igGetWindowSize()
  marks.markWindow(name & ".wheel popover")
  drawGroundForceGroup(w, name, planeAt, box, t, marks, p, changed, res, st)
  drawMassesGroup(w, name, planeAt, box, forceNote, t, marks, p, changed, res, st)
  drawForceGroup(w, name, planeAt, box, kind, forceNote, t, marks, p, changed, res, st)
  if kind != sgNone: drawJobWeightsGroup(st, name, box, marks, res)
  if kind == sgVib:
    drawAccelGroup(name, t, marks, p, changed)
    ui.drawWeightsGroup(st, planeAt, name, t, marks)
  igSeparator()
  if w.view.hasOptions:
    if igSmallButton("Reset options##reset"):
      p = builtin(w.view, p, kind != sgNone)
      changed = true
    marks.mark(name & ".reset")
    tip(ResetTip)
  igEndPopup()

proc drawVibratorSettings(ui: var PlotWindowsUi; st: AppState; w: AnalysisWindow; name: string;
    box: float32; t: Theme; marks: var Marks; p: var AnalysisParams; frozen, changed: var bool;
    res: var PlotWindowsOutput) =
  ## A vibrator signature's controls: one strip under the verdict (Roles, Limits..., Details,
  ## the settings wheel and Freeze at the right). Roles opens the roles
  ## table (the one place to reverse a polarity), the wheel the settings, in headed groups for
  ## the file shown, Limits... the six limits of the verdict and the window they are judged in.
  ## What is set here is kept as the project's vibrator QC profile as it is set.
  let planeAt = st.findPlot(w.id)
  let forceNote = st.vibForceNote(planeAt)
  let kind = st.vibSignature(planeAt)
  let findings = ui.findings.getOrDefault(w.id)
  let strip = beginControlLine()
  let gap = igGetStyle().ItemSpacing.x
  let size = strip.size
  # Roles
  let rolesAt = ImVec2_c(x: strip.left, y: strip.top + size)
  let rolesTip = (if planeAt >= 0: st.vibRolesLine(w).broken & "\n" else: "") &
    "Roles: which trace is Ref, GF, M and B, their polarity (the one place to reverse the " &
    "ground force), and the project reference" &
    (if forceNote.len > 0: "\n" & forceNote.broken else: "") &
    (if ui.how.getOrDefault(w.id).len > 0: "\n" & ui.how[w.id].broken else: "")
  if iconButton(IconTable, "Roles", "", size, t, marks,
      selected = igIsPopupOpen_Str("##roles", 0), tipText = rolesTip, markName = name & ".roles"):
    igOpenPopup_Str("##roles", 0)
  # Limits
  igSameLine(0, 2)
  let limitsAt = ImVec2_c(x: igGetCursorScreenPos().x, y: strip.top + size)
  if iconButton(IconRuler, "Limits...", "", size, t, marks,
      selected = igIsPopupOpen_Str("##limits", 0), tipText = "Limits...: the six limits of " &
      "the verdict, and the length of the windows they are judged in",
      markName = name & ".limits"):
    igOpenPopup_Str("##limits", 0)
  # Details
  igSameLine(0, 2)
  if iconButton(IconList, "Details", "", size, t, marks, selected = p.details,
      tipText = "Details" & (if p.details: " (on)" else: " (off)") & ": off, the judged signal " &
      "alone, one force plot, the limits table.\nOn, the other ground force, M and B, the " &
      "recorded pilot and the harmonics too, and a table of every signal",
      markName = name & ".details"):
    p.details = not p.details
    changed = true
  # the settings wheel and Freeze, at the right
  let wheelX = strip.rowRight - size
  igSetCursorScreenPos(ImVec2_c(x: wheelX, y: strip.top))
  let wheelAt = ImVec2_c(x: wheelX + size, y: strip.top + size)
  let wheelTip = "Settings: the ground force judged, harmonics, phase picture and top " &
    "frequency" & (if forceNote.len == 0: ", the masses" else: "") &
    ", the force" & (if kind == sgVib: ", the accelerometer set, the header's weights" else: "") &
    ", and Reset options" & (if findings.len > 0: "\nFindings kept here:\n" &
    findings.join("\n").broken else: "")
  if iconButton(IconSettings, "Settings", "", size, t, marks,
      selected = igIsPopupOpen_Str("##wheel", 0), tipText = wheelTip,
      markName = name & ".wheel", badge = findings.len > 0):
    igOpenPopup_Str("##wheel", 0)
  if strip.drawFreeze(name, PlotFreeze, name & ".freeze", frozen, t, marks):
    frozen = not frozen
    changed = true
  # the roles asked for from the polarity line: the popover opens at the ground force's row
  if w.id in ui.rolesAsk:
    ui.rolesRow[w.id] = ui.rolesAsk[w.id]
    ui.rolesAsk.del w.id
    igOpenPopup_Str("##roles", 0)
  ui.drawRolesPopover(st, w, name, planeAt, forceNote, rolesAt, t, marks, p, changed)
  ui.drawWheel(st, w, name, planeAt, kind, forceNote, box, wheelAt, t, marks, p, changed, res)
  placePopover(limitsAt.x, limitsAt.y, ui.limitsSize)
  var typed = 0.0
  if igBeginPopup("##limits", 0):
    ui.limitsSize = igGetWindowSize()
    igTextUnformatted("The verdict's limits (judged on the flat part of the sweep)", nil)
    template qcLimit(text, id: string; field: untyped; unit, what: string) =
      igAlignTextToFramePadding()
      igTextUnformatted(cstring(text), nil)
      marks.mark(name & ".qc limit " & text)
      igSameLine(0, -1)
      if limitBox(id, p.qc.field, box, typed) and
          not (typed.isNaN and p.qc.field.isNaN) and typed != p.qc.field:
        (p.qc.field, changed) = (typed, true)
      tip(what & ". Empty: that limit is off")
      igSameLine(0, -1)
      igTextUnformatted(cstring(unit), nil)
    qcLimit("Average phase ≤", "##qcavgphase", avgPhaseDeg, "°",
      "The largest average of the windows' mean |phase|, degrees")
    qcLimit("Peak phase ≤", "##qcpeakphase", peakPhaseDeg, "°",
      "The largest window's mean |phase|, degrees")
    qcLimit("Average distortion ≤", "##qcavgdist", avgDistortionPct, "%",
      "The largest average of the windows' mean in-band distortion, %")
    qcLimit("Peak distortion ≤", "##qcpeakdist", peakDistortionPct, "%",
      "The largest window's mean in-band distortion, %")
    qcLimit("Average force ≥", "##qcavgforce", avgForcePct, "% of target",
      "The smallest average of the windows' mean force, % of the target force")
    qcLimit("Peak force ≤", "##qcpeakforce", peakForcePct, "% of 100 %",
      "The largest peak of a window, % of the 100 % force")
    igSeparator()
    igAlignTextToFramePadding()
    igTextUnformatted("QC window", nil)
    igSameLine(0, -1)
    if limitBox("##qcwindow", p.qcWindowMs, box, typed):
      if WindowMsRange.allows(typed):
        if typed != p.qcWindowMs: (p.qcWindowMs, changed) = (typed, true)
      elif not typed.isNaN:
        res.notes.add "The window must be " & WindowMsRange.words & ", not " &
            sensible(typed) & "."
    marks.mark(name & ".qc window")
    tip("The sweep is cut into pieces of this length; each limit is checked on the average " &
      "inside a piece. Average = mean of all pieces; peak = the worst piece.")
    igSameLine(0, -1)
    igTextUnformatted("ms", nil)
    igEndPopup()

proc drawSettings(ui: var PlotWindowsUi; st: AppState; w: AnalysisWindow; name: string;
    t: Theme; marks: var Marks; res: var PlotWindowsOutput) =
  ## The view's settings, wrapping before the Freeze pin at the right of the
  ## first row; a change is a `ckPlotDisplay`.
  var p = w.params
  var frozen = w.frozen
  var changed = false
  let box = round(igCalcTextSize("00000.0", nil, false, -1).x + 2 * igGetStyle().FramePadding.x)
  var typed = 0.0
  template label(text: string) =
    igAlignTextToFramePadding()
    igTextUnformatted(cstring(text), nil)
    igSameLine(0, -1)
  template unit(text: string) =
    igAlignTextToFramePadding()
    igTextUnformatted(cstring(text), nil)
  template mapCombo() =
    igSetNextItemWidth(round(igCalcTextSize("Red-white-blue", nil, false, -1).x +
      igGetFrameHeight() + 2 * igGetStyle().FramePadding.x))
    if igBeginCombo("##map", ($p.colourMap).cstring, 0):
      for m in ColourMap:
        if igSelectable_Bool(($m).cstring, m == p.colourMap, 0, ImVec2_c(x: 0, y: 0)) and
            m != p.colourMap:
          (p.colourMap, changed) = (m, true)
      igEndCombo()
    marks.mark(name & ".map")
    tip("The colour map, as density's")
  let planeAt = st.findPlot(w.id)
  let fileRefOffered = w.view in {avCorrelation, avEnvelope} and planeAt >= 0 and
    (p.fileReference or st.hasFileReference(planeAt))
  template fileReferenceButton(line: untyped) =
    ## Beside the reference: the record's own reference trace instead of the project's
    ## (and back); never turned on by itself.
    if fileRefOffered:
      let text = if p.fileReference: "Use the project reference"
                 else: "Use this file's reference trace"
      line.follow(buttonWidth(text))
      if igSmallButton((text & "##filereference").cstring):
        (p.fileReference, changed) = (not p.fileReference, true)
      marks.mark(name & ".filereference")
      tip("The record's trace with the vibrator reference code (21), whole, as the " &
        "reference, instead of the project's chosen one; the same button goes back")
  let mapW = round(igCalcTextSize("Red-white-blue", nil, false, -1).x +
    igGetFrameHeight() + 2 * igGetStyle().FramePadding.x)
  if w.view == avVibrator:
    ui.drawVibratorSettings(st, w, name, box, t, marks, p, frozen, changed, res)
  else:
    let line = beginControlLine()
    case w.view
    of avSpectrogram:
      label("Frame")
      if numberBox("##window", p.windowMs, box, typed) and WindowMsRange.allows(typed):
        (p.windowMs, changed) = (typed, true)
      marks.mark(name & ".frame")
      tip("Each frame's length (a Hann window): longer resolves frequency finer and time " &
        "coarser (a frame of W ms resolves about 2/W kHz)")
      line.follow(textBoxWidth("ms  overlap", box))
      label("ms  overlap")
      if numberBox("##overlap", p.overlap, box, typed) and OverlapRange.allows(typed):
        (p.overlap, changed) = (typed, true)
      marks.mark(name & ".overlap")
      tip("How much a frame overlaps the next, % (0 to 95)")
      line.follow(textBoxWidth("%  floor", box) + igGetStyle().ItemSpacing.x +
        igCalcTextSize("dB", nil, false, -1).x)
      label("%  floor")
      if numberBox("##floor", p.floorDb, box, typed) and FloorDbRange.allows(typed):
        (p.floorDb, changed) = (typed, true)
      marks.mark(name & ".floor")
      tip("The lowest dB drawn: the colour map's low end (0 dB is the largest amplitude)")
      igSameLine(0, -1)
      unit("dB")
      line.follow(mapW)
      mapCombo()
    of avOrientation: discard
    of avEnvelope:
      let againstW = round(igCalcTextSize("Against the reference", nil, false, -1).x +
        igGetFrameHeight() + 2 * igGetStyle().FramePadding.x)
      label("Phase:")
      igSetNextItemWidth(againstW)
      if igBeginCombo("##against", ($p.phaseAgainst).cstring, 0):
        for v in PhaseAgainst:
          if igSelectable_Bool(($v).cstring, v == p.phaseAgainst, 0, ImVec2_c(x: 0, y: 0)) and
              v != p.phaseAgainst:
            (p.phaseAgainst, changed) = (v, true)
          marks.mark(name & ".against " & $v)
          tip(PhaseAgainstTips[v])
        igEndCombo()
      marks.mark(name & ".against")
      tip(PhaseAgainstTips[p.phaseAgainst])
      if p.phaseAgainst == paReference: line.phaseShowCombo(name, marks, p, changed)
      if w.reference.len > 0:
        line.follow(textBoxWidth("Reference: " & w.reference, 0))
        unit("Reference: " & w.reference) # no same-line: Reset options decides its own
      if p.phaseAgainst == paReference: fileReferenceButton(line)
    of avPhase:
      label("Phase where within")
      if numberBox("##within", p.phaseWithinDb, box, typed) and PhaseWithinRange.allows(typed):
        (p.phaseWithinDb, changed) = (typed, true)
      marks.mark(name & ".within")
      tip("The phase is drawn where the amplitude is within this many dB of its peak: " &
        "elsewhere it is noise")
      igSameLine(0, -1)
      unit("dB of the peak")
      let pictureW = round(igCalcTextSize("Magnitude 0-180", nil, false, -1).x +
        igGetFrameHeight() + 2 * igGetStyle().FramePadding.x)
      line.follow(textBoxWidth("Phase:", pictureW))
      label("Phase:")
      igSetNextItemWidth(pictureW)
      if igBeginCombo("##picture", ($p.phasePicture).cstring, 0):
        for v in PhasePicture:
          if igSelectable_Bool(($v).cstring, v == p.phasePicture, 0, ImVec2_c(x: 0, y: 0)) and
              v != p.phasePicture:
            (p.phasePicture, changed) = (v, true)
        igEndCombo()
      marks.mark(name & ".phase picture")
      tip(phasePictureTip(p.phasePicture))
    of avCorrelation:
      label("Reference: " & (if w.reference.len > 0: w.reference else: "none"))
      line.follow(buttonWidth("References"))
      if igSmallButton("References##bar"): res.openReferences = true
      marks.mark(name & ".references")
      tip("Open References, where the reference is chosen")
      fileReferenceButton(line)
      line.follow(textBoxWidth("lags ±", box) + igGetStyle().ItemSpacing.x +
        igCalcTextSize("ms", nil, false, -1).x)
      label("lags ±")
      if numberBox("##lags", p.maxLagMs, box, typed) and LagMsRange.allows(typed):
        (p.maxLagMs, changed) = (typed, true)
      marks.mark(name & ".lags")
      tip("The lags shown either side of 0, ms")
      igSameLine(0, -1)
      unit("ms")
      line.phaseShowCombo(name, marks, p, changed)
    of avFk:
      label("From")
      if limitBox("##from", p.fkFromMs, box, typed) and
          not (typed.isNaN and p.fkFromMs.isNaN) and typed != p.fkFromMs:
        (p.fkFromMs, changed) = (typed, true)
      marks.mark(name & ".from")
      tip("The box's first time, ms (empty: the traces' start)")
      line.follow(textBoxWidth("to", box))
      label("to")
      if limitBox("##to", p.fkToMs, box, typed) and
          not (typed.isNaN and p.fkToMs.isNaN) and typed != p.fkToMs:
        (p.fkToMs, changed) = (typed, true)
      marks.mark(name & ".to")
      tip("The box's last time, ms (empty: the traces' end)")
      line.follow(textBoxWidth("ms  floor", box) + igGetStyle().ItemSpacing.x +
        igCalcTextSize("dB", nil, false, -1).x)
      label("ms  floor")
      if numberBox("##floor", p.floorDb, box, typed) and FloorDbRange.allows(typed):
        (p.floorDb, changed) = (typed, true)
      tip("The lowest dB drawn: the colour map's low end (0 dB is the largest amplitude)")
      igSameLine(0, -1)
      unit("dB")
      line.follow(mapW)
      mapCombo()
      line.follow(checkWidth("Raw"))
      if igCheckbox("Raw", addr p.fkRaw): changed = true
      marks.mark(name & ".raw")
      tip("On: the traces as recorded. Off: through the Seismic window's filters, so the " &
        "effect of a filter shows")
    of avVibrator: discard
    line.drawReset(w, name, marks, p, changed)
    if line.drawFreeze(name, PlotFreeze, name & ".freeze", frozen, t, marks):
      frozen = not frozen
      changed = true
  if changed:
    res.commands.add Command(kind: ckPlotDisplay, plot: w.id, plotParams: p,
      plotFrozen: frozen)

proc colourMapOf(ui: var PlotWindowsUi; m: ColourMap): int =
  ## ImPlot's index of density colour map `m`, added once.
  if ui.maps[m] == 0:
    let name = "viewSEG " & $m
    var index = int(ImPlot_GetColormapIndex(name.cstring))
    if index < 0:
      let lut = lutOf(m)
      var cols = newSeq[ImU32](lut.len)
      for i, c in lut: cols[i] = u32(c)
      index = int(ImPlot_AddColormap_U32Ptr(name.cstring, addr cols[0], cint(cols.len), false))
    ui.maps[m] = index + 1
  ui.maps[m] - 1

proc axisBox(dl: ptr ImDrawList; text: string; across: bool; at: float32; pos,
    area: ImVec2_c; t: Theme): tuple[lo, hi: ImVec2_c] =
  ## `text` in a box on the plot's bottom axis (`across`: centred at x `at`)
  ## or its left axis (centred at y `at`), over the tick labels, as the
  ## Seismic window's cursor writes its time.
  let ts = igCalcTextSize(text.cstring, nil, false, -1)
  var lo, hi: ImVec2_c
  if across:
    lo = ImVec2_c(x: round(at - ts.x / 2) - 3, y: pos.y + area.y + 1)
    hi = ImVec2_c(x: lo.x + ts.x + 6, y: lo.y + ts.y + 4)
  else:
    lo = ImVec2_c(x: pos.x - ts.x - 8, y: round(at - ts.y / 2) - 2)
    hi = ImVec2_c(x: pos.x - 1, y: lo.y + ts.y + 4)
  ImDrawList_AddRectFilled(dl, lo, hi, u32(t.roles[rlWindow]), 0, 0)
  ImDrawList_AddRect(dl, lo, hi, u32(t.roles[rlCrosshair]), 0, 1, 0)
  ImDrawList_AddText_Vec2(dl, ImVec2_c(x: lo.x + 3, y: lo.y + 2), u32(t.roles[rlText]),
    text.cstring, nil)
  (lo, hi)

func axisNumber(x: float64): string =
  if abs(x) >= 100 or x == round(x): formatFloat(x, ffDecimal, 1)
  else: formatFloat(x, ffDecimal, 2)

proc drawImage(ui: var PlotWindowsUi; st: AppState; w: AnalysisWindow; name: string;
    t: Theme; size: ImVec2_c; marks: var Marks; focused: bool;
    res: var PlotWindowsOutput): string =
  ## The image (a spectrogram) in its colour map with its scale beside, the
  ## cursor's lines and values; what the cursor reads.
  result = ""
  let img = w.result.image
  if img.isEmpty: return
  let scaleW = round(igGetFontSize() * 4.5)
  let cmap = ui.colourMapOf(w.params.colourMap)
  ImPlot_PushColormap_PlotColormap(ImPlotColormap(cmap))
  let x0 = img.x0 - img.dx / 2
  let x1 = img.xOf(img.cols - 1) + img.dx / 2
  let y0 = img.y0 - img.dy / 2
  let y1 = img.yOf(img.rows - 1) + img.dy / 2
  const flags = ImPlot_Flags_NoLegend.cint or ImPlot_Flags_NoMenus.cint or
    ImPlot_Flags_NoMouseText.cint or ImPlot_Flags_NoTitle.cint
  var under = PlotCursor(x: -1, y: -1)
  if ImPlot_BeginPlot(("##" & name).cstring, ImVec2_c(x: max(80, size.x - scaleW), y: size.y),
      flags):
    ImPlot_SetupAxes(img.xLabel.cstring, img.yLabel.cstring, 0, 0)
    # the axes follow the data by `view/axisfit`'s rule, as a curve plot's do: an option
    # fits both, other data (another trace, record or file) the axes not zoomed by hand
    var options = w.params
    options.colourMap = AnalysisParams().colourMap # a colour map moves no axis
    let fit = ui.imageAxes.mgetOrPut(w.id, AxisFit()).plan(
      $w.view & $options & img.xLabel & img.yLabel, Span(lo: x0, hi: x1), Span(lo: y0, hi: y1))
    ImPlot_SetupAxisLimits(ImAxis_X1.cint, x0, x1,
      if fit.x: ImPlot_Cond_Always.cint else: ImPlot_Cond_Once.cint)
    ImPlot_SetupAxisLimits(ImAxis_Y1.cint, y0, y1,
      if fit.y: ImPlot_Cond_Always.cint else: ImPlot_Cond_Once.cint)
    ImPlot_SetupAxisLimitsConstraints(ImAxis_X1.cint, x0, x1)
    ImPlot_SetupAxisLimitsConstraints(ImAxis_Y1.cint, y0, y1)
    let pos = ImPlot_GetPlotPos()
    let area = ImPlot_GetPlotSize()
    notePlot(pos, area)
    # only what is in view, cut to the pixels (the largest value of each bin),
    # redone when the answer, the view or the size changes: never a copy of
    # every cell a frame
    let lim = ImPlot_GetPlotLimits(ImAxis_X1.cint, ImAxis_Y1.cint)
    let view = [lim.X.Min, lim.X.Max, lim.Y.Min, lim.Y.Max]
    let pixels = [max(1, int(area.x)), max(1, int(area.y))]
    if w.id notin ui.heat or ui.heat[w.id].gen != w.result.gen or ui.heat[w.id].view != view or
        ui.heat[w.id].pixels != pixels:
      ui.heat[w.id] = HeatCache(gen: w.result.gen, view: view, pixels: pixels,
        cells: img.reduceImage(view[0], view[1], view[2], view[3], pixels[0], pixels[1]))
    template cut: untyped = ui.heat[w.id].cells
    if cut.cols > 0:
      ImPlot_PlotHeatmap_FloatPtr("##image", addr cut.values[0], cint(cut.rows), cint(cut.cols),
        cdouble(img.lo), cdouble(img.hi), nil, ImPlotPoint_c(x: cut.xMin, y: cut.yMin),
        ImPlotPoint_c(x: cut.xMax, y: cut.yMax), 0)
    marks.markRect(name & ".image", pos, ImVec2_c(x: pos.x + area.x, y: pos.y + area.y))
    if ImPlot_IsPlotHovered():
      let m = ImPlot_GetPlotMousePos(ImAxis_X1.cint, ImAxis_Y1.cint)
      under = img.cellAt(m.x, m.y)
    let c = if w.cursor.held: w.cursor.clamped([img.cols, img.rows]) else: under
    if c.x >= 0:
      let dl = ImPlot_GetPlotDrawList()
      let q = ImPlot_PlotToPixels_double(img.xOf(c.x), img.yOf(c.y), ImAxis_X1.cint,
        ImAxis_Y1.cint)
      let cross = u32(t.roles[rlCrosshair])
      ImDrawList_PushClipRect(dl, pos, ImVec2_c(x: pos.x + area.x, y: pos.y + area.y), true)
      ImDrawList_AddLine(dl, ImVec2_c(x: round(q.x) + 0.5, y: pos.y),
        ImVec2_c(x: round(q.x) + 0.5, y: pos.y + area.y), cross, 1)
      ImDrawList_AddLine(dl, ImVec2_c(x: pos.x, y: round(q.y) + 0.5),
        ImVec2_c(x: pos.x + area.x, y: round(q.y) + 0.5), cross, 1)
      ImDrawList_PopClipRect(dl)
      # on the window's own list, clipped to the window: a window in front hides them
      let wl = igGetWindowDrawList()
      let wp = igGetWindowPos()
      let ws = igGetWindowSize()
      ImDrawList_PushClipRect(wl, wp, ImVec2_c(x: wp.x + ws.x, y: wp.y + ws.y), true)
      let (xlo, xhi) = axisBox(wl, axisNumber(img.xOf(c.x)), true, q.x, pos, area, t)
      let (ylo, yhi) = axisBox(wl, axisNumber(img.yOf(c.y)), false, q.y, pos, area, t)
      ImDrawList_PopClipRect(wl)
      marks.markRect(name & ".cursor x", xlo, xhi)
      marks.markRect(name & ".cursor y", ylo, yhi)
      result = img.readingText(c)
    let ended = ImPlot_GetPlotLimits(ImAxis_X1.cint, ImAxis_Y1.cint)
    let seenX = Span(lo: ended.X.Min, hi: ended.X.Max)
    let seenY = Span(lo: ended.Y.Min, hi: ended.Y.Max)
    ui.imageAxes[w.id].seen(seenX, seenY)
    curves.noteAxes(name & ".image", (seenX, seenY), (ui.imageAxes[w.id].userZoomed(true),
      ui.imageAxes[w.id].userZoomed(false)))
    ImPlot_EndPlot()
    explainMenu(name & ".explain", pos, t, marks, st.explainPane(w, 0))
  igSameLine(0, -1)
  ImPlot_ColormapScale(("dB##" & name).cstring, cdouble(img.lo), cdouble(img.hi),
    ImVec2_c(x: scaleW - igGetStyle().ItemSpacing.x, y: size.y), "%g", 0, ImPlotColormap(cmap))
  ImPlot_PopColormap(1)
  ui.under[w.id] = under
  # The keys, while the window has the focus: a step from where the cursor
  # is held, else from the cell under the pointer.
  let k = keysNow(focused)
  let move = keyMove(k.up, k.down, k.left, k.right, k.home, k.ending)
  if move != cmNone:
    let start = if w.cursor.held: w.cursor
                elif under.x >= 0: under
                else: PlotCursor()
    res.commands.add Command(kind: ckPlotCursor, plot: w.id,
      plotCursor: start.moved(move, [img.cols, img.rows]))
  elif w.cursor.held and k.escape:
    res.commands.add Command(kind: ckPlotCursor, plot: w.id, plotCursor: PlotCursor())
  if w.cursor.held and under.x >= 0 and igGetIO_Nil().MouseDelta.x != 0:
    # the pointer moved over the image: it takes the cursor back
    res.commands.add Command(kind: ckPlotCursor, plot: w.id, plotCursor: PlotCursor())

proc drawTable(name: string; table: seq[seq[string]]; t: Theme; marks: var Marks) =
  ## A table of a row per signal (a vibrator signature's, a correlation's), its
  ## first row the columns' names; a cell that says "fail" in the error colour.
  let cols = table[0].len
  const flags = ImGui_TableFlags_SizingFixedFit.cint or ImGui_TableFlags_BordersInnerH.cint or
    ImGui_TableFlags_ScrollX.cint
  let h = igGetTextLineHeightWithSpacing() * float32(table.len + 1)
  if igBeginTable(("##table" & name).cstring, cint(cols), flags, ImVec2_c(x: 0, y: h), 0):
    for c in table[0]: igTableSetupColumn(c.cstring, 0, 0, 0)
    igTableHeadersRow()
    for row in table[1 .. ^1]:
      igTableNextRow(0, 0)
      for i, cell in row:
        discard igTableSetColumnIndex(cint(i))
        if cell.startsWith("fail"):
          igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlError]))
          igTextUnformatted(cell.cstring, nil)
          igPopStyleColor(1)
        else:
          igTextUnformatted(cell.cstring, nil)
    # a table wider than its window scrolls sideways: said, so a test can see it does not
    if igGetScrollMaxX() > 0: marks.mark(name & ".table scrolls")
    igEndTable()
    marks.mark(name & ".table")

proc drawIdentity(w: AnalysisWindow; name: string; t: Theme; marks: var Marks) =
  ## Which sweep this is, in one line above the verdict (when it was triggered, controller,
  ## vibrator, the point when the file gives it): a click on it (or on its copy icon) copies it
  ## as a line of text with the file name and the verdict.
  let words = w.sweep.identityLine
  if words.len == 0: return
  let copy = w.identityCopy
  igPushStyleColor_Vec4(ImGui_Col_Button.cint, vec4(Rgba()))
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  var clicked = igSmallButton((IconCopy & "##copyidentity").cstring)
  igPopStyleColor(2)
  marks.mark(name & ".copy identity")
  tip("Copy this line (the file name, this sweep's identity and the verdict) as text")
  igSameLine(0, -1)
  igAlignTextToFramePadding()
  igPushTextWrapPos(igGetCursorPos().x + igGetContentRegionAvail().x)
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextUnformatted(words.cstring, nil)
  igPopStyleColor(1)
  igPopTextWrapPos()
  if igIsItemClicked(0): clicked = true
  marks.mark(name & ".identity")
  tip("Click to copy this line, with the file name and the verdict, as one line of text")
  if clicked: igSetClipboardText(copy.cstring)

proc drawVerdict(name: string; q: QcReport; t: Theme; marks: var Marks) =
  ## A vibrator signature's verdict, one line, in words and a sign (never colour alone):
  ## pass, fail with the worst failing value and its time, or not judged.
  let colour = case q.verdict
    of qvPass: t.roles[rlOk]
    of qvFail: t.roles[rlError]
    of qvNotJudged: t.roles[rlWarning]
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour))
  fittedText(q.line, igGetContentRegionAvail().x)
  igPopStyleColor(1)
  marks.mark(name & ".verdict")
  tip("The sweep judged as a vibrator controller's QC does: the mean of each " &
    $q.stats.windowMs.int & " ms window of the sweep's flat part (its tapers are left out), " &
    "then the average and the worst window against the limits below. Distortion is the " &
    "in-band one (harmonics up to the sweep's top frequency)")

proc columnWidth(cells: openArray[string]; most = 320'f32): float32 =
  ## The width a column of fixed-fit table needs for `cells`, so its first frame is right
  ## (ImGui sizes a clipped table's columns to nothing).
  for c in cells: result = max(result, igCalcTextSize(c.cstring, nil, false, -1).x)
  result = min(result, most) + 12

proc drawPolarity(ui: var PlotWindowsUi; w: AnalysisWindow; name: string; signature: bool;
    t: Theme; marks: var Marks) =
  ## The ground force against the reference, in words: a finding, reported and never changed.
  ## When it is opposite (or the user has reversed it), the line ends with "Roles...", which
  ## opens the roles at the ground force's row, the one place to reverse it or take it back.
  let pol = w.result.polarity
  # (a SEG-Y window keeps its roles' table for the polarity; the line is in its result)
  if pol.line.len == 0 or not signature: return
  let odd = pol.kind in {pkOpposite, pkOther, pkUnclear} and not pol.reversed
  let link = pol.kind == pkOpposite or w.params.roles.groundForcePolarity == poReversed
  if odd: igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
  # (the line wraps before the link's place, so the link ends it)
  let linkRoom = if link: buttonWidth("Roles...") + igGetStyle().ItemSpacing.x else: 0
  igPushTextWrapPos(igGetCursorPos().x + igGetContentRegionAvail().x - linkRoom)
  igTextUnformatted(pol.line.cstring, nil)
  igPopTextWrapPos()
  if odd: igPopStyleColor(1)
  marks.mark(name & ".polarity")
  tip("The mean phase of the ground force to the reference over the judged part, as " &
    "recorded. It is reported, never changed: reverse it only by your own choice, in the " &
    "roles, which affects this analysis alone (the samples and the file stay as recorded)")
  if link:
    igSameLine(0, -1)
    igPushStyleColor_Vec4(ImGui_Col_Button.cint, vec4(Rgba()))
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlAccent]))
    if igSmallButton("Roles...##polarity"):
      ui.rolesAsk[w.id] = "GF"
    igPopStyleColor(2)
    marks.mark(name & ".reverse")
    tip("Open the roles, at the ground force: its polarity is chosen there. Remembered for " &
      "this file layout (in the project when one is open, else in your settings)")

proc drawController(name: string; r: AnalysisResult; t: Theme; marks: var Marks) =
  ## The controller's own QC numbers beside this window's.
  if r.controller.len == 0: return
  const flags = ImGui_TableFlags_SizingFixedFit.cint or ImGui_TableFlags_BordersInnerH.cint
  # (the first column's heading says where the numbers are from, the note is its tooltip)
  let at = r.controllerNote.find("from ")
  let source = if at >= 0: r.controllerNote[at + 5 .. ^1].split(", beside")[0] else: ""
  igPushStyleVar_Vec2(ImGui_StyleVar_CellPadding.cint, ImVec2_c(x: 4, y: 1))
  defer: igPopStyleVar(1)
  if igBeginTable(("##controller" & name).cstring, 3, flags, ImVec2_c(x: 0, y: 0), 0):
    var labels, mine, theirs: seq[string] = @[]
    for row in r.controller:
      labels.add row.label
      mine.add row.viewseg
      theirs.add row.controller
    let head = "Controller's QC, from " & source
    igTableSetupColumn(head.cstring, 0, columnWidth(labels & head), 0)
    igTableSetupColumn("This window", 0, columnWidth(mine & "This window"), 0)
    igTableSetupColumn("Controller", 0, columnWidth(theirs & "Controller"), 0)
    igTableHeadersRow()
    for row in r.controller:
      igTableNextRow(0, 0)
      for k, cell in [row.label, row.viewseg, row.controller]:
        discard igTableSetColumnIndex(cint(k))
        igTextUnformatted(cell.cstring, nil)
        if row.tip.len > 0 and k > 0: tip(row.tip)
    igEndTable()
    marks.mark(name & ".controller")

proc drawQcTable(name: string; q: QcReport; judged: string; t: Theme; marks: var Marks) =
  ## The limits table, always shown: a row per limit with the measured value, the limit and
  ## a sign as text (a tick, a cross, or a dash when not judged), then where the worst
  ## window is, or why the limit was not judged.
  # columns drag to a width (ImGui keeps them for the session), and the sign is the first
  # column, so a narrow window never cuts it off
  const flags = ImGui_TableFlags_SizingFixedFit.cint or
      ImGui_TableFlags_BordersInnerH.cint or ImGui_TableFlags_Resizable.cint or
      ImGui_TableFlags_BordersInnerV.cint
  let table = q.tableOf
  igPushStyleVar_Vec2(ImGui_StyleVar_CellPadding.cint, ImVec2_c(x: 4, y: 1))
  defer: igPopStyleVar(1)
  if igBeginTable(("##qctable" & name).cstring, 5, flags, ImVec2_c(x: 0, y: 0), 0):
    for k, c in table[0]:
      var cells: seq[string] = @[]
      for row in table: cells.add row[k]
      igTableSetupColumn(c.cstring, 0, columnWidth(cells), 0)
    igTableHeadersRow()
    for i, row in table[1 .. ^1]:
      igTableNextRow(0, 0)
      let status = q.rows[i].status
      for k, cell in row:
        discard igTableSetColumnIndex(cint(k))
        if k == 0 and status != qsNotJudged:
          igPushStyleColor_Vec4(ImGui_Col_Text.cint,
            vec4(if status == qsFail: t.roles[rlError] else: t.roles[rlOk]))
          igTextUnformatted(cell.cstring, nil)
          igPopStyleColor(1)
        elif k == 4:
          # the last column: cut to what is left, the whole text in a tooltip
          if status == qsNotJudged:
            igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
          fittedText(cell, igGetContentRegionAvail().x)
          if status == qsNotJudged: igPopStyleColor(1)
        else:
          igTextUnformatted(cell.cstring, nil)
          if k == 1 and q.rows[i].limit == qlPeakForce and judged == "GF (M, B)":
            tip(PeakFromMassesTip)
    igEndTable()
    marks.mark(name & ".qc table")
  let s = q.stats
  if s.windows > 0:
    var line = $s.windows & " windows of " & plain(s.windowMs, 0) &
        " ms; minimum force " &
      (if s.minForcePct.isNaN: forceNumber(s.minForce) else: plain(
          s.minForcePct) & " %") &
      " at " & seconds(s.minForceAtMs)
    if q.forceNote.len > 0: line.add "; force not judged: " & q.forceNote
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
    fittedText(line, igGetContentRegionAvail().x)
    igPushTextWrapPos(igGetCursorPos().x + igGetContentRegionAvail().x)
    igPopTextWrapPos()
    igPopStyleColor(1)
    marks.mark(name & ".qc windows")

proc drawBody(ui: var PlotWindowsUi; st: AppState; w: AnalysisWindow; t: Theme;
    marks: var Marks; res: var PlotWindowsOutput) =
  ## A window's contents: its settings, its words, its plots and reading.
  let name = w.markName
  marks.markWindow(name)
  if w.view == avVibrator and w.result.problem.len == 0 and
      w.result.qc.rows.len > 0:
    drawIdentity(w, name, t, marks)
    drawVerdict(name, w.result.qc, t, marks)
    let how = (if w.result.against.len > 0: w.result.against & ". " else: "") &
      (if w.result.note.len > 0: shownNote(w.result.note, w.params.reactionMassKg,
        w.params.baseplateMassKg, st.settings.units) else: "")
    ui.how[w.id] = how
    ui.drawPolarity(w, name, st.vibSignature(st.findPlot(w.id)) != sgNone, t, marks)
    if w.result.judgeWarning.len > 0:
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
      fittedText(w.result.judgeWarning, igGetContentRegionAvail().x)
      igPopStyleColor(1)
      marks.mark(name & ".judge warning")
    # what the settings wheel holds that is a finding, in words (muted, wrapped)
    let found = ui.vibFindings(st, w, st.findPlot(w.id))
    ui.findings[w.id] = found
    if found.len > 0:
      for line in found: wrapped(line, t, em = igGetContentRegionAvail().x / igGetFontSize())
      marks.mark(name & ".findings")
    # a limit the controller tripped is a finding too (told here, not behind the wheel)
    if w.sweep.limits.card > 0:
      wrapped("The controller tripped: " & w.sweep.limits.limitsWords, t,
        em = igGetContentRegionAvail().x / igGetFontSize())
      marks.mark(name & ".tripped")
      tip(LimitsProbable)
  ui.drawSettings(st, w, name, t, marks, res)
  let r = w.result
  var words = if w.frozen: "Frozen · " & w.label else: w.label
  # against a reference (one actually used) nothing is filtered: the filters' words are not
  # shown, and a trace's own filter is said not to be applied (the note says so too)
  let rawWindow = w.view in {avCorrelation, avVibrator} or
    (w.view == avEnvelope and r.plots.len > 1 and r.plots[1].title == "Phase against the reference")
  let own = w.ownLine
  if own.len > 0: words.add " · " & own & (if rawWindow: " (not applied here)" else: "")
  let rev = w.reverseLine
  if rev.len > 0: words.add " · " & rev
  let shifted = w.shiftLine
  if shifted.len > 0: words.add " · " & shifted
  if w.filters.len > 0 and not rawWindow:
    words.add " · filters: " & w.filters
    if r.passedBy > 0: words.add " (" & passedWords(r.passedBy) & ")"
  if r.notDrawn > 0:
    words.add " · " & $r.notDrawn & " more traces not read (the window draws " &
      $MaxAnalysisCurves & ")"
  if r.leftOut > 0:
    words.add " · " & $r.leftOut & " left out (killed, dead or unreadable" &
      (if r.notNumber > 0: "; " & $r.notNumber & " with a sample that is not a number" else: "") &
      ")"
  if r.zeroed > 0:
    words.add " · " & $r.zeroed & " with a sample that is not a number, taken as zeros"
  if r.atOtherInterval > 0: words.add " · " & $r.atOtherInterval & " at another interval"
  if w.waiting: words.add " · working it out..."
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  # (a vibrator window's plain line goes under its fold, with the note)
  let plainWords = if w.frozen: "Frozen · " & w.label else: w.label
  let foldedWords = w.view == avVibrator and words == plainWords and
      r.problem.len == 0
  if not foldedWords: igTextWrapped("%s", words.cstring)
  # The warning and the note may be many lines (eight traces' words): above a third of the
  # window they scroll in a child of their own, so that the plots keep their room.
  let wrapW = igGetContentRegionAvail().x
  let warnShown = r.warning.len > 0 and r.problem.len == 0 and not w.waiting
  let refProblem = w.view == avCorrelation and not w.waiting and r.problem.len > 0 and
    r.plots.len == 0 and r.image.isEmpty
  # (a vibrator window's note is in its Roles button's tooltip: the plots keep their room)
  let noteShown = w.goneNote.len == 0 and r.problem.len == 0 and r.note.len >
      0 and not refProblem and w.view != avVibrator
  let measured = if noteShown: shownNote(r.note, w.params.reactionMassKg,
                   w.params.baseplateMassKg, st.settings.units) else: ""
  # a vibrator window's note folds under one line, so that its plots keep their room
  let folds = false
  let said = if noteShown and not folds:
               (if r.against.len > 0: r.against & ". " else: "") & measured
             else: ""
  var wordsH = 0.0'f32
  if warnShown: wordsH += igCalcTextSize(r.warning.cstring, nil, false, wrapW).y
  if noteShown: wordsH += igCalcTextSize(said.cstring, nil, false, wrapW).y
  let wordsCap = max(igGetContentRegionAvail().y * 0.34'f32, igGetTextLineHeightWithSpacing() * 6)
  let scrollWords = w.view == avCorrelation and wordsH > wordsCap
  if scrollWords:
    discard igBeginChild_Str(("##words" & name).cstring, ImVec2_c(x: 0, y: wordsCap), 0, 0)
  if warnShown:
    # a trace that cannot be matched to the whole of its reference, before anything else
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlWarning]))
    if w.view == avVibrator:
      # a line each, cut to the width (the whole line in a tooltip)
      for line in r.warning.splitLines: fittedText(line, igGetContentRegionAvail().x)
    else:
      igPushTextWrapPos(igGetCursorPos().x + igGetContentRegionAvail().x)
      igTextUnformatted(r.warning.cstring, nil)
      igPopTextWrapPos()
    igPopStyleColor(1)
    marks.mark(name & ".warning")
  if w.goneNote.len > 0 and not refProblem: igTextWrapped("%s", w.goneNote.cstring)
  elif r.problem.len > 0 and not refProblem:
    igTextWrapped("%s", (if r.awaiting: r.problem else: "Nothing to show: " & r.problem).cstring)
  elif folds:
    igPushTextWrapPos(igGetCursorPos().x + igGetContentRegionAvail().x)
    let head = if r.against.len > 0: r.against else: "How this was measured"
    let shownHead = shortenEnd(head, igGetContentRegionAvail().x - 3 * igGetFontSize())
    igSetNextItemOpen(w.params.noteOpen, ImGui_Cond_Always.cint)
    let noteOpen = igTreeNodeEx_Str((shownHead & "##notes" & name).cstring, 0)
    marks.mark(name & ".against")
    tip((if shownHead != head: head & "\n" else: "") &
      "Click for what the numbers are, in words")
    if noteOpen != w.params.noteOpen:
      var q = w.params
      q.noteOpen = noteOpen
      res.commands.add Command(kind: ckPlotDisplay, plot: w.id, plotParams: q,
        plotFrozen: w.frozen)
    if noteOpen:
      if foldedWords: igTextUnformatted(plainWords.cstring, nil)
      igTextUnformatted(measured.cstring, nil)
      igTreePop()
    igPopTextWrapPos()
  elif noteShown:
    # wrapped at the window's width (the settings rows above are wider than a note)
    igPushTextWrapPos(igGetCursorPos().x + igGetContentRegionAvail().x)
    igTextUnformatted(said.cstring, nil)
    igPopTextWrapPos()
  if scrollWords: igEndChild()
  igPopStyleColor(1)
  marks.mark(name & ".summary")
  # a vibrator signature's table, with its limits on; a correlation's, of several traces
  if w.view == avVibrator and r.problem.len == 0 and r.qc.rows.len > 0:
    drawQcTable(name, r.qc, r.judged, t, marks)
    drawController(name, r, t, marks)
  let tabled = if w.view == avCorrelation: r.table.len > 2
               elif w.view == avVibrator: r.table.len > 1 and w.params.details
               else: false
  if tabled and r.problem.len == 0:
    drawTable(name, shownTable(r.table, r.forceUnits, st.settings.units), t, marks)
  let focused = igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint)
  let lineH = igGetTextLineHeightWithSpacing()
  let avail = igGetContentRegionAvail()
  var text = ""
  if refProblem:
    igTextWrapped("%s", r.problem.cstring)
    if igSmallButton("References##area"): res.openReferences = true
    marks.mark(name & ".references")
    tip("Open References, where the reference is chosen")
    let at = st.findPlot(w.id)
    if not w.params.fileReference and at >= 0 and st.hasFileReference(at):
      igSameLine(0, -1)
      if igSmallButton("Use this file's reference trace##area"):
        var p = w.params
        p.fileReference = true
        res.commands.add Command(kind: ckPlotDisplay, plot: w.id, plotParams: p,
          plotFrozen: w.frozen)
      marks.mark(name & ".filereference area")
      tip("The record's trace with the vibrator reference code (21), whole, as the reference")
  elif not r.image.isEmpty:
    text = ui.drawImage(st, w, name, t, ImVec2_c(x: avail.x, y: max(80'f32, avail.y - lineH)),
      marks, focused, res)
  else:
    let plots = r.curvePlots(t, st.settings.units)
    var uis = ui.curves.getOrDefault(w.id)
    var keys: seq[string] = @[]
    for p in plots: keys.add p.xLabel & "|" & p.yLabel
    let oldKeys = ui.curveKeys.getOrDefault(w.id)
    if oldKeys != keys:
      var moved = newSeq[CurvePlotUi](plots.len)
      for j, key in keys:
        let at = oldKeys.find(key)
        if at in 0 ..< uis.len: moved[j] = uis[at]
      uis = moved
      ui.curveKeys[w.id] = keys
    let gap = igGetStyle().ItemSpacing.y
    # Each plot the room shared out, but no lower than nine lines: below
    # that the plots scroll, in a region of their own.
    let room = avail.y - lineH
    var each = (room - gap * float32(max(plots.len - 1, 0))) / float32(max(
        plots.len, 1))
    let minLines = if w.view == avVibrator: VibratorPlotLines else: 9
    let scrolls = each < round(igGetFontSize() * float32(minLines))
    # Words and a table that leave no room for a plot (eight traces' lines): the plots
    # follow below them at their least height and the window scrolls, none is left out.
    let inWindow = scrolls and room < round(igGetFontSize() * 12)
    var wide = avail.x
    if scrolls:
      each = round(igGetFontSize() * float32(minLines))
      if not inWindow:
        discard igBeginChild_Str(("##plots" & name).cstring, ImVec2_c(x: 0, y: max(room, 60)),
          0, 0)
        wide = igGetContentRegionAvail().x
        marks.mark(name & ".plots scroll")
    # The cursor: held by the keys in one plot (and at the same x in the
    # plots that share its x axis), else under the pointer.
    let on = clamp(w.cursorOn, 0, max(plots.len - 1, 0))
    func sameXs(a, b: CurvePlot): bool =
      a.xs.len == b.xs.len and (a.xs.len == 0 or (a.xs[0] == b.xs[0] and a.xs[^1] == b.xs[^1]))
    # What the options draw: another one fits the axes again (`view/axisfit`);
    # a colour map is no part of a curve plot.
    var options = w.params
    options.colourMap = AnalysisParams().colourMap
    var areas: seq[(float32, float32)] = @[] # each plot's area, left and right edge
    var hoveredOn = -1
    var under = PlotCursor(x: -1, y: -1)
    var moved = false
    for i, p in plots:
      let key = $w.view & $i & $options & $st.settings.units & $p.xs.len &
        (if p.xs.len > 0: $p.xs[0] & $p.xs[^1] else: "") & p.xLabel & p.yLabel
      let held = if w.cursor.held and plots.len > 0 and (i == on or p.sameXs(plots[on])):
                   PlotCursor(held: true, x: w.cursor.x, y: (if i == on: w.cursor.y else: 0))
                 else: PlotCursor()
      if uis[i].shift > 0: igIndent(uis[i].shift)
      let o = uis[i].drawCurvePlot(name & ".plot " & $i, p, t,
        ImVec2_c(x: max(80'f32, wide - uis[i].shift + uis[i].widen), y: each), key, marks, held)
      if uis[i].shift > 0: igUnindent(uis[i].shift)
      areas.add (o.plotPos.x, o.plotPos.x + o.plotSize.x)
      explainMenu(name & ".explain" & (if i == 0: "" else: " " & $(i + 1)), o.plotPos, t, marks,
        st.explainPane(w, i))
      if o.hovered:
        (hoveredOn, under, moved) = (i, o.under, o.moved)
        text = p.readoutText(o.reading)
      elif held.held and i == on:
        text = p.readoutText(o.reading)
    if scrolls and not inWindow: igEndChild()
    if w.view == avVibrator and areas.len == plots.len and plots.len > 1:
      # The plots' legends and tick labels differ in width, so their areas would too: each
      # is indented and made wider or narrower by what its own left (tick labels) and right
      # (legend) edges are off the common ones, so that the time axes of the stacked plots
      # line up. Worked from the edges the plot would have with no change, so that nothing
      # accumulates.
      var left = float32(-Inf)
      var right = float32(Inf)
      for i, a in areas:
        if a[1] > a[0]:
          left = max(left, a[0] - uis[i].shift)
          right = min(right, a[1] - uis[i].widen)
      for i, a in areas:
        if a[1] <= a[0]: continue
        let shift = left - (a[0] - uis[i].shift)
        let widen = right - (a[1] - uis[i].widen)
        if abs(shift - uis[i].shift) > 0.5 or abs(widen - uis[i].widen) > 0.5:
          (uis[i].shift, uis[i].widen) = (shift, widen)
    ui.curves[w.id] = uis
    for p in plots:
      if p.aside.len > 0 and text.find(p.aside) < 0: text.add "   " & p.aside
    if w.cursor.held and text.len > 0: text = HeldNote & text
    # The keys: Left / Right a point, Home / End the ends, Up / Down another
    # curve, from where the cursor is held, else from under the pointer.
    let k = keysNow(focused)
    var move = cmNone
    if k.left: move = cmPrevious
    if k.right: move = cmNext
    if k.home: move = cmFirst
    if k.ending: move = cmLast
    if k.up: move = cmUp
    if k.down: move = cmDown
    let at = if w.cursor.held: on elif hoveredOn >= 0: hoveredOn else: 0
    if move != cmNone and at < plots.len and plots[at].xs.len > 0:
      var start = if w.cursor.held: w.cursor
                  elif hoveredOn >= 0 and under.x >= 0: under
                  else: PlotCursor()
      if start.y < 0: start.y = 0
      res.commands.add Command(kind: ckPlotCursor, plot: w.id, plotCursorOn: at,
        plotCursor: start.moved(move, [plots[at].xs.len, plots[at].curves.len]))
    elif w.cursor.held and (k.escape or (hoveredOn >= 0 and moved)):
      res.commands.add Command(kind: ckPlotCursor, plot: w.id, plotCursor: PlotCursor())
  ui.readout[w.id] = text
  igTextUnformatted((if text.len > 0: text else: " ").cstring, nil)
  # a window that has to scroll, said, so a test can see a unit fits (a vibrator's does)
  if igGetScrollMaxY() > 0: marks.mark(name & ".scrolls")
  if w.view == avFk and r.image.velocityUnit.len > 0:
    tip(fkVelocityTip(r.image.velocityUnit, st.settings.units))
  marks.mark(name & ".readout")

proc drawPlotWindows*(ui: var PlotWindowsUi; st: AppState; t: Theme; scale: float32;
    marks: var Marks; res: var PlotWindowsOutput) =
  ## The analysis windows, each with its close button; the first time one
  ## of a number is shown, beside the middle of the main window, a step
  ## lower and to the right for each number, inside it (`placement`).
  var ids: seq[int] = @[]
  block:
    let vp = igGetMainViewport()
    marks.markRect("new plots.room", vp.WorkPos, ImVec2_c(x: vp.WorkPos.x + vp.WorkSize.x,
      y: vp.WorkPos.y + vp.WorkSize.y))
  for w in st.plots:
    ids.add w.id
    # a correlation of several traces has a line or two each above its plots: taller
    let size = if w.view == avVibrator: VibratorSize
               elif w.view == avCorrelation and w.traces.len > 2:
                 (CorrelationWidth, PlotSize[1] + 5 * float32(min(w.traces.len, 8)) *
                   igGetFontSize() / scale)
               else: PlotSize
    placeNext(w.id, size, scale)
    if forcedVibratorSize[0] > 0 and w.view == avVibrator:
      let vp = igGetMainViewport()
      igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + 20, y: vp.WorkPos.y + 10),
        ImGui_Cond_Always.cint, ImVec2_c(x: 0, y: 0))
      igSetNextWindowSize(ImVec2_c(x: forcedVibratorSize[0], y: forcedVibratorSize[1]),
        ImGui_Cond_Always.cint)
    if w.id in ui.toFront:
      ui.toFront.excl w.id
      igSetNextWindowFocus()
    var open = true
    if igBegin(w.windowTitle.cstring, addr open, 0):
      ui.drawBody(st, w, t, marks, res)
      marks.markOverflow(w.markName)
    igEnd()
    if not open: res.commands.add Command(kind: ckClosePlot, plot: w.id)
  var gone: seq[int] = @[]
  for id in ui.readout.keys:
    if id notin ids: gone.add id
  for id in gone:
    ui.findings.del id
    ui.how.del id
    ui.rolesAsk.del id
    ui.rolesRow.del id
    ui.curves.del id
    ui.curveKeys.del id
    ui.under.del id
    ui.heat.del id
    ui.imageAxes.del id
    ui.readout.del id

func readoutOf*(ui: PlotWindowsUi; id: int): string =
  ## What window `id`'s cursor read last frame; "" for nothing (tests).
  ui.readout.getOrDefault(id, "")

func cellsDrawn*(ui: PlotWindowsUi; id: int): int =
  ## The cells window `id`'s image hands ImPlot to draw (tests).
  if id in ui.heat: ui.heat[id].cells.cols * ui.heat[id].cells.rows else: 0

proc coveredBy*(ui: var PlotWindowsUi; id: int; area: Rect; others: openArray[int]): string =
  ## Which of the other analysis windows `others` is in front of window `id` and
  ## hides part of `area` (where it was drawn); "" when none does. A covered
  ## window is brought forward at the next frame, so that asking again finds it
  ## whole.
  let target = igFindWindowByName(("###newplot-" & $id).cstring)
  if target == nil: return ""
  for o in others:
    if o == id: continue
    let w = igFindWindowByName(("###newplot-" & $o).cstring)
    if w == nil or not w.Active or w.Hidden or not igIsWindowAbove(w, target): continue
    if w.Pos.x < area.pos.x + area.size.x and w.Pos.x + w.Size.x > area.pos.x and
        w.Pos.y < area.pos.y + area.size.y and w.Pos.y + w.Size.y > area.pos.y:
      ui.toFront.incl id
      return "new plot " & $o
  ""
