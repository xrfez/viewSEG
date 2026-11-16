## The spectrum windows: the FFT windows opened from the plot's menu (`F`),
## each a window of its own that docks, titled by what it shows, and the
## live Spectrum panel (Window > Spectrum), which follows the Seismic
## window's view or selection while it is on screen.
##
## Each shows a line of controls in three groups (the scale: dB or linear and
## a logarithmic frequency axis; the curves: raw, processed, the filters'
## response and the phase; then the whole trace or the time the plot showed),
## with Freeze, a pin at the right of the first row. Then what the spectrum
## is of and what was left out, the plot (`curveplot`), and what the pointer reads.
## The windows read `core` and issue `Command`s: `ckSpectrumDisplay` for a
## control, `ckCloseSpectrum` when an FFT window is closed,
## `ckSpectrumPanel` when the live panel comes on screen or leaves it (it
## works only while on screen).

import std/[math, sequtils, strutils, tables]
import imguin/cimgui
import ../../core/state
import ../../view/[curveplot, spectrumview, theme]
import chrome, curveplot as curves, icons, marks, placement, style

const
  SpectrumWindowTitle* = IconPulse & "  Spectrum###spectrum"
  FftSize = (560'f32, 380'f32) ## an FFT window's first size, at 100 %

type
  SpectraUi* = object
    ## The spectrum windows' state between frames.
    plots: Table[int, CurvePlotUi]        ## per window id
    phases: Table[int, CurvePlotUi]       ## per window id: its phase plot
    readout*: Table[int, string]          ## per window id: what the pointer read last frame (tests)
    readAt*: Table[int, int]              ## per window id: the bin it read; -1 for none (tests)
    widths: Table[int, array[3, float32]] ## per window id: the control groups, as drawn last frame
    front: int                            ## the live panel's `front` followed last

  SpectraOutput* = object
    commands*: seq[Command]
    bringForward*: bool ## the live panel is to be brought forward (an agent showed it)

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc lockedCheck(label: string; stored: var bool; enabled: bool): bool =
  ## The checkbox, drawn unticked while `enabled` is not, without writing
  ## that into `stored` (the choice shows again as soon as it is enabled).
  ## True when the stored choice changed.
  var shown = enabled and stored
  if not enabled: igBeginDisabled(true)
  let clicked = igCheckbox(label.cstring, addr shown)
  if not enabled: igEndDisabled()
  if enabled and clicked and shown != stored:
    stored = shown
    return true
  false

func markName(w: SpectrumWindow): string =
  ## The window's mark (and screenshot target): "spectrum", "fft 1", ...
  if w.id == LiveSpectrum: "spectrum" else: "fft " & $w.id

func fftTitle*(w: SpectrumWindow): string =
  ## An FFT window's ImGui title: its name, then its identity, which a
  ## layout keeps ("###fft-2").
  IconPulse & "  " & w.title & "###fft-" & $w.id

const GroupGap = 14'f32 ## between the spectrum line's groups, as on the Seismic strip

func processedReady(w: SpectrumWindow; ownChanges: bool): bool =
  ## Whether Processed can be ticked: a processed curve is there, or the
  ## plot's filters or a shown trace's own filter change the samples and the
  ## answer in hand has not already said they produced none.
  if w.spectrum.processed.len > 0: return true
  if not (w.processing.hasFilters or ownChanges): return false
  if w.spectrum.raw.len > 0 and not w.waiting: return false
  true

proc drawControls(st: AppState; w: SpectrumWindow; name: string; t: Theme;
    widths: var array[3, float32]; marks: var Marks; res: var SpectraOutput) =
  ## The controls in three groups that wrap as wholes (the scale, the curves,
  ## Visible time), before the Freeze pin; each change is a `ckSpectrumDisplay`.
  var d = w.display
  var frozen = w.frozen
  var changed = false
  let line = beginControlLine()
  template group(i: int; body: untyped) =
    if i > 0 and line.fitsBefore(widths[i], GroupGap):
      igSameLine(0, GroupGap)
    elif i == 0 and igGetCursorScreenPos().x + widths[0] > line.rowRight:
      # the first group is too wide for the row beside the pin: below it
      igSetCursorScreenPos(ImVec2_c(x: line.left,
        y: line.top + line.size + igGetStyle().ItemSpacing.y))
    igBeginGroup()
    body
    igEndGroup()
    widths[i] = igGetItemRectSize().x
  group(0):
    if igRadioButton_Bool("dB", d.scale == ssDb):
      d.scale = ssDb
      changed = true
    marks.mark(name & ".db")
    tip("Amplitude in dB, 0 dB at the largest of the curves (raw and processed on one scale)")
    igSameLine(0, -1)
    if igRadioButton_Bool("Linear", d.scale == ssLinear):
      d.scale = ssLinear
      changed = true
    marks.mark(name & ".linear")
    tip("Amplitude in the file's sample units: a sine of amplitude A on a bin reads A")
    igSameLine(0, -1)
    if igCheckbox("Log frequency", addr d.logFrequency): changed = true
    marks.mark(name & ".log")
    tip("The frequency axis logarithmic (0 Hz left out)")
  group(1):
    if igCheckbox("Raw", addr d.raw): changed = true
    marks.mark(name & ".raw")
    tip("The samples as the file has them")
    igSameLine(0, -1)
    let ownChanges = st.ownChangesSamples(w)
    let processedOn = w.processedReady(ownChanges)
    if lockedCheck("Processed", d.processed, processedOn): changed = true
    marks.mark(name & ".processed")
    tip(if processedOn and w.spectrum.filters.len > 0:
          (if ownChanges: "Through: " else: "Through the plot's filters: ") &
            w.spectrum.filters
        elif processedOn: "Through the shown trace's own filter"
        elif not w.processing.hasFilters and not ownChanges: "No filter is on in the plot"
        elif w.spectrum.filters.len > 0: "No processed curve: " & w.filterText
        else: "No filter is on in the plot")
    igSameLine(0, -1)
    let responseOn = w.spectrum.hasResponse
    if lockedCheck("Response", d.response, responseOn): changed = true
    marks.mark(name & ".response")
    let whose = if ownChanges and w.traces.len == 1: "this trace's filters"
                else: "the plot's filters"
    tip(if responseOn: "Under the curves, the gain " & whose & " apply at " &
          "each frequency (an impulse put through them, as the traces are), 0 dB at the top " &
          "of the curves: what they do, where the processed curve shows what the data and " &
          "the window make of it"
        elif not w.processing.hasFilters and not ownChanges: "No filter is on in the plot"
        elif w.spectrum.response.len > 0: "The filters reached none of these traces: their " &
          "response is not drawn"
        else: "The plot has no pass band or notch to draw")
    igSameLine(0, -1)
    if lockedCheck("Phase", d.phase, w.hasPhase): changed = true
    marks.mark(name & ".phase")
    tip(if w.hasPhase: "The phase of this trace, under its amplitude. " & PhaseHelp
        else: "The phase is drawn for the spectrum of one trace")
    igSameLine(0, -1)
    let pictureW = round(igCalcTextSize("Magnitude 0-180", nil, false, -1).x +
      igGetFrameHeight() + 2 * igGetStyle().FramePadding.x)
    igSetNextItemWidth(pictureW)
    if igBeginCombo("##phase picture", ($d.phasePicture).cstring, 0):
      for v in PhasePicture:
        if igSelectable_Bool(($v).cstring, v == d.phasePicture, 0, ImVec2_c(x: 0, y: 0)) and
            v != d.phasePicture:
          (d.phasePicture, changed) = (v, true)
      igEndCombo()
    marks.mark(name & ".phase picture")
    tip("Phase: " & $d.phasePicture & ". " & PhaseHelp)
  group(2):
    var visible = d.time == stVisible
    if igCheckbox("Visible time", addr visible):
      d.time = if visible: stVisible else: stWhole
      changed = true
    marks.mark(name & ".time")
    tip(if w.id == LiveSpectrum or not w.frozen:
          "The time the Seismic window shows; off: the whole trace"
        else: "The time this window is frozen on (" &
          valueText(w.visibleMs.lo) & " to " & valueText(w.visibleMs.hi) &
          " ms); off: the whole trace")
  const sentence = "keep these traces while the plot moves on"
  if line.drawFreeze(name, sentence, name & ".freeze", frozen, t, marks):
    frozen = not frozen
    changed = true
  if changed:
    res.commands.add Command(kind: ckSpectrumDisplay, spectrum: w.id, spectrumShow: d,
      frozen: frozen)

proc drawFilterAux(st: AppState; w: SpectrumWindow; name: string; marks: var Marks;
    res: var SpectraOutput) =
  ## When auxiliary traces of the spectrum were not filtered (the plot's Aux
  ## toggle off) and the window follows the plot: a button that ticks the
  ## toggle on the plot (`ckProcessing`), which the window then follows.
  if not w.auxUnfiltered or w.frozen: return
  let k = st.findPanel(w.panel)
  if k < 0 or st.panels[k].layers.len == 0: return
  var pr = st.panels[k].layers[0].processing
  if pr.aux: return # ticked already: the answer is on its way
  if igSmallButton("Filter the Aux traces too"):
    pr.aux = true
    res.commands.add Command(kind: ckProcessing, panel: w.panel, processing: pr)
  marks.mark(name & ".filter aux")
  tip("Ticks \"Filter the Aux traces too\" in the Seismic window's Filters, so its " &
    "auxiliary traces go through the filters in the plot and in the spectra (untick it " &
    "there to undo)")

const HeldNote* = "Held · "
  ## before the readout while the keys hold the cursor (its tooltip says how
  ## to let it go): first, so a narrow window does not cut it off

proc cursorKeys(w: SpectrumWindow; p: CurvePlot; o: CurveOutput; res: var SpectraOutput) =
  ## The window's keys, while it has the focus: Left / Right move the
  ## cursor a frequency bin, Home / End to the ends, Up / Down to another
  ## curve, each holding it (`ckSpectrumCursor`); Esc, or the pointer moved
  ## over the plot, lets it go; Alt + Left / Right select the previous or
  ## next trace of the record (`ckStepTrace`: an FFT window of one trace
  ## shows the new one).
  let io = igGetIO_Nil()
  if io.WantTextInput or not igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint):
    return
  template held(chord: cint): bool = igShortcut_Nil(chord, ImGui_InputFlags_Repeat.cint)
  template once(chord: cint): bool = igShortcut_Nil(chord, 0)
  const alt = ImGui_Mod_Alt.cint
  for (chord, by) in [(alt or ImGui_Key_LeftArrow.cint, -1), (alt or ImGui_Key_RightArrow.cint, 1)]:
    if held(chord):
      res.commands.add Command(kind: ckStepTrace, spectrum: w.id, stepBy: by)
  var move = cmNone
  if held(ImGui_Key_LeftArrow.cint): move = cmPrevious
  if held(ImGui_Key_RightArrow.cint): move = cmNext
  if once(ImGui_Key_Home.cint): move = cmFirst
  if once(ImGui_Key_End.cint): move = cmLast
  if held(ImGui_Key_UpArrow.cint): move = cmUp
  if held(ImGui_Key_DownArrow.cint): move = cmDown
  let counts = [p.xs.len, p.curves.len]
  if move != cmNone and counts[0] > 0 and counts[1] > 0:
    # from where it is held, else from under the pointer, else at the peak of
    # the curve drawn on top
    var start = if w.cursor.held: w.cursor
                elif o.under.x >= 0: o.under
                else: PlotCursor(x: max(w.spectrum.raw.peakBin, 0), y: counts[1] - 1)
    if start.y < 0: start.y = counts[1] - 1
    res.commands.add Command(kind: ckSpectrumCursor, spectrum: w.id,
      cursor: start.moved(move, counts))
  elif w.cursor.held and (once(ImGui_Key_Escape.cint) or (o.hovered and o.moved)):
    res.commands.add Command(kind: ckSpectrumCursor, spectrum: w.id) # let go

proc drawBody(ui: var SpectraUi; st: AppState; w: SpectrumWindow; t: Theme; marks: var Marks;
    res: var SpectraOutput) =
  ## A window's contents: its controls, its words (with a click that
  ## filters the auxiliary traces when they were not), its plot and reading.
  let name = w.markName
  marks.markWindow(name)
  var widths = ui.widths.getOrDefault(w.id)
  drawControls(st, w, name, t, widths, marks, res)
  ui.widths[w.id] = widths
  # What it is of (the live panel's title does not say), and what was left out.
  let head = if w.frozen: "Frozen · " & w.label & " · "
             elif w.id == LiveSpectrum: w.label & " · "
             else: ""
  let words = head & w.summaryText &
    (if w.filterText.len > 0: " · " & w.filterText else: "")
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextWrapped("%s", words.cstring)
  igPopStyleColor(1)
  marks.mark(name & ".summary")
  drawFilterAux(st, w, name, marks, res)
  let p = w.spectrumPlot(t)
  let lineH = igGetTextLineHeightWithSpacing()
  let avail = igGetContentRegionAvail()
  template sp: untyped = w.spectrum
  # Fitted again for other data: another scale, axis or bins (the linear
  # live panel at each answer, its range moves with the traces).
  let key = $w.display.scale & $w.display.logFrequency & $w.display.phasePicture &
    $p.isEmpty & $sp.nfft & $sp.binHz &
    (if w.display.scale == ssLinear and w.id == LiveSpectrum: $sp.gen else: "")
  let phased = w.display.phase and w.hasPhase
  let h = max(80'f32, avail.y - lineH)
  let o = ui.plots.mgetOrPut(w.id, CurvePlotUi()).drawCurvePlot(name, p, t,
    ImVec2_c(x: avail.x, y: if phased: round(h * 0.6) else: h), key, marks, w.cursor)
  var text = p.readoutText(o.reading)
  if phased:
    let q = w.phasePlot(t)
    let po = ui.phases.mgetOrPut(w.id, CurvePlotUi()).drawCurvePlot(name & ".phase", q, t,
      ImVec2_c(x: avail.x, y: max(60'f32, h - round(h * 0.6) - igGetStyle().ItemSpacing.y)),
      key, marks, (if w.cursor.held: PlotCursor(held: true, x: w.cursor.x,
                     y: max(q.curves.mapIt(it.name).find($w.cursorCurve), 0))
      else: PlotCursor()))
    if po.hovered: text = q.readoutText(po.reading)
    elif q.aside.len > 0 and text.find(q.aside) < 0: text.add "   " & q.aside
  if w.cursor.held and text.len > 0: text = HeldNote & text
  ui.readout[w.id] = text
  ui.readAt[w.id] = o.reading.index
  igTextUnformatted((if text.len > 0: text else: " ").cstring, nil)
  marks.mark(name & ".readout")
  if w.cursor.held: tip("The keys hold the cursor: Left / Right a frequency, Home / End the " &
    "ends, Up / Down another curve. Move the pointer over the plot, or press Esc, to let it go")
  cursorKeys(w, p, o, res)

proc drawLive*(ui: var SpectraUi; st: AppState; shown: bool; t: Theme; marks: var Marks;
    res: var SpectraOutput) =
  ## The live panel's window, when the Window menu shows it (`shown`); it
  ## tells `core` when it comes on screen and leaves it (behind another
  ## tab, hidden, collapsed).
  template live: untyped = st.spectra[0]
  if live.front != ui.front:
    ui.front = live.front
    res.bringForward = true
  var visible = false
  if shown:
    let open = igBegin(SpectrumWindowTitle.cstring, nil, 0)
    if open:
      visible = true
      ui.drawBody(st, live, t, marks, res)
    igEnd()
  if visible != live.shown:
    res.commands.add Command(kind: ckSpectrumPanel, onScreen: visible)

proc drawFfts*(ui: var SpectraUi; st: AppState; t: Theme; scale: float32; marks: var Marks;
    res: var SpectraOutput) =
  ## The FFT windows, each with its close button; the first time one of a
  ## number is shown, beside the middle of the main window, a step lower
  ## and to the right for each number, inside it (`placement`).
  var ids: seq[int]
  for w in st.spectra:
    if w.id != LiveSpectrum:
      ids.add w.id
      placeNext(w.id, FftSize, scale)
      var open = true
      if igBegin(w.fftTitle.cstring, addr open, 0):
        ui.drawBody(st, w, t, marks, res)
      igEnd()
      if not open: res.commands.add Command(kind: ckCloseSpectrum, spectrum: w.id)
  # The plots of windows that went.
  var gone: seq[int]
  for id in ui.plots.keys:
    if id != LiveSpectrum and id notin ids: gone.add id
  for id in gone:
    ui.plots.del id
    ui.phases.del id
    ui.readout.del id
    ui.readAt.del id
    ui.widths.del id

func readoutOf*(ui: SpectraUi; id: int): (string, int) =
  ## What window `id`'s pointer read last frame, and the bin; "" and -1
  ## for nothing (tests).
  (ui.readout.getOrDefault(id, ""), ui.readAt.getOrDefault(id, -1))
