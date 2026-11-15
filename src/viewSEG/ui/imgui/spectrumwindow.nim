## The spectrum windows: the FFT windows opened from the plot's menu (`F`),
## each a window of its own that docks, titled by what it shows, and the
## live Spectrum panel (Window > Spectrum), which follows the Seismic
## window's view or selection while it is on screen.
##
## Each shows a line of controls (dB or linear, the frequency axis
## logarithmic, the raw and processed curves, the whole trace or the time
## the plot showed; Freeze), what the spectrum is of and
## what was left out, the plot (`curveplot`), and what the pointer reads.
## The windows read `core` and issue `Command`s: `ckSpectrumDisplay` for a
## control, `ckCloseSpectrum` when an FFT window is closed,
## `ckSpectrumPanel` when the live panel comes on screen or leaves it (it
## works only while on screen).

import std/[math, tables]
import imguin/cimgui
import ../../core/state
import ../../view/[curveplot, spectrumview, theme]
import curveplot as curves, icons, marks, style

const
  SpectrumWindowTitle* = IconPulse & "  Spectrum###spectrum"
  FftSize = (560'f32, 380'f32) ## an FFT window's first size, at 100 %

type
  SpectraUi* = object
    ## The spectrum windows' state between frames.
    plots: Table[int, CurvePlotUi] ## per window id
    phases: Table[int, CurvePlotUi] ## per window id: its phase plot
    readout*: Table[int, string]   ## per window id: what the pointer read last frame (tests)
    readAt*: Table[int, int]       ## per window id: the bin it read; -1 for none (tests)
    front: int                     ## the live panel's `front` followed last

  SpectraOutput* = object
    commands*: seq[Command]
    bringForward*: bool ## the live panel is to be brought forward (an agent showed it)

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

func markName(w: SpectrumWindow): string =
  ## The window's mark (and screenshot target): "spectrum", "fft 1", ...
  if w.id == LiveSpectrum: "spectrum" else: "fft " & $w.id

func fftTitle*(w: SpectrumWindow): string =
  ## An FFT window's ImGui title: its name, then its identity, which a
  ## layout keeps ("###fft-2").
  IconPulse & "  " & w.title & "###fft-" & $w.id

proc toggleWidth(label: string): float32 =
  ## A checkbox's or radio button's width with its label.
  igGetFrameHeight() + igGetStyle().ItemInnerSpacing.x +
    igCalcTextSize(label.cstring, nil, true, -1).x

proc after(label: string) =
  ## The next control on the line of the one before when it fits, else on
  ## the next line: the controls wrap in a narrow window.
  let room = igGetCursorScreenPos().x + igGetContentRegionAvail().x # the right edge
  if igGetItemRectMax().x + igGetStyle().ItemSpacing.x + toggleWidth(label) <= room:
    igSameLine(0, -1)

proc drawControls(w: SpectrumWindow; name: string; marks: var Marks; res: var SpectraOutput) =
  ## The controls, wrapping in a narrow window; each change is a
  ## `ckSpectrumDisplay`.
  var d = w.display
  var frozen = w.frozen
  var changed = false
  if igRadioButton_Bool("dB", d.scale == ssDb):
    d.scale = ssDb
    changed = true
  marks.mark(name & ".db")
  tip("Amplitude in dB, 0 dB at the largest of the curves (raw and processed on one scale)")
  after("Linear")
  if igRadioButton_Bool("Linear", d.scale == ssLinear):
    d.scale = ssLinear
    changed = true
  marks.mark(name & ".linear")
  tip("Amplitude in the file's sample units: a sine of amplitude A on a bin reads A")
  after("Log frequency")
  if igCheckbox("Log frequency", addr d.logFrequency): changed = true
  marks.mark(name & ".log")
  tip("The frequency axis logarithmic (0 Hz left out)")
  after("Raw")
  if igCheckbox("Raw", addr d.raw): changed = true
  marks.mark(name & ".raw")
  tip("The samples as the file has them")
  after("Processed")
  igBeginDisabled(w.spectrum.processed.len == 0)
  if igCheckbox("Processed", addr d.processed): changed = true
  igEndDisabled()
  marks.mark(name & ".processed")
  tip(if w.spectrum.processed.len > 0: "Through the plot's filters: " & w.spectrum.filters
      elif w.spectrum.filters.len > 0: "No processed curve: " & w.filterText
      else: "The plot has no filters (Filters in the Seismic window's strip)")
  after("Visible time")
  var visible = d.time == stVisible
  if igCheckbox("Visible time", addr visible):
    d.time = if visible: stVisible else: stWhole
    changed = true
  marks.mark(name & ".time")
  tip(if w.id == LiveSpectrum: "The time the Seismic window shows; off: the whole trace"
      else: "The time the Seismic window showed when this window opened (" &
        valueText(w.visibleMs.lo) & " to " & valueText(w.visibleMs.hi) &
        " ms); off: the whole trace")
  after("Phase")
  igBeginDisabled(not w.hasPhase)
  if igCheckbox("Phase", addr d.phase): changed = true
  igEndDisabled()
  marks.mark(name & ".phase")
  tip(if w.hasPhase: "The phase of this trace (degrees, from the window's first sample), " &
        "under its amplitude"
      else: "The phase is drawn for the spectrum of one trace")
  after("Freeze")
  if igCheckbox("Freeze", addr frozen): changed = true
  marks.mark(name & ".freeze")
  tip(if w.id == LiveSpectrum: "Keep this spectrum while the Seismic window moves on"
      else: "Keep the filters this spectrum went through while the plot's change; off: " &
        "it follows the plot's filters and its Aux toggle (its traces stay those it was " &
        "opened on)")
  if changed:
    res.commands.add Command(kind: ckSpectrumDisplay, spectrum: w.id, spectrumShow: d,
      frozen: frozen)

proc drawBody(ui: var SpectraUi; w: SpectrumWindow; t: Theme; marks: var Marks;
    res: var SpectraOutput) =
  ## A window's contents: its controls, its words, its plot and reading.
  let name = w.markName
  marks.markWindow(name)
  drawControls(w, name, marks, res)
  # What it is of (the live panel's title does not say), and what was left out.
  let words = (if w.id == LiveSpectrum: w.label & " · " else: "") & w.summaryText &
    (if w.filterText.len > 0: " · " & w.filterText else: "")
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igTextWrapped("%s", words.cstring)
  igPopStyleColor(1)
  marks.mark(name & ".summary")
  let p = w.spectrumPlot(t)
  let lineH = igGetTextLineHeightWithSpacing()
  let avail = igGetContentRegionAvail()
  template sp: untyped = w.spectrum
  # Fitted again for other data: another scale, axis or bins (the linear
  # live panel at each answer, its range moves with the traces).
  let key = $w.display.scale & $w.display.logFrequency & $p.isEmpty & $sp.nfft &
    $sp.binHz & (if w.display.scale == ssLinear and w.id == LiveSpectrum: $sp.gen else: "")
  let phased = w.display.phase and w.hasPhase
  let h = max(80'f32, avail.y - lineH)
  let o = ui.plots.mgetOrPut(w.id, CurvePlotUi()).drawCurvePlot(name, p, t,
    ImVec2_c(x: avail.x, y: if phased: round(h * 0.6) else: h), key, marks)
  var text = if o.hovered: p.readoutText(o.reading) else: ""
  if phased:
    let q = w.phasePlot(t)
    let po = ui.phases.mgetOrPut(w.id, CurvePlotUi()).drawCurvePlot(name & ".phase", q, t,
      ImVec2_c(x: avail.x, y: max(60'f32, h - round(h * 0.6) - igGetStyle().ItemSpacing.y)),
      key, marks)
    if po.hovered: text = q.readoutText(po.reading)
  ui.readout[w.id] = text
  ui.readAt[w.id] = if o.hovered: o.reading.index else: -1
  igTextUnformatted((if text.len > 0: text else: " ").cstring, nil)
  marks.mark(name & ".readout")

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
      ui.drawBody(live, t, marks, res)
    igEnd()
  if visible != live.shown:
    res.commands.add Command(kind: ckSpectrumPanel, onScreen: visible)

proc drawFfts*(ui: var SpectraUi; st: AppState; t: Theme; scale: float32; marks: var Marks;
    res: var SpectraOutput) =
  ## The FFT windows, each with its close button; the first time one of a
  ## number is shown, beside the middle of the main window, a little lower
  ## and to the right for each number.
  var ids: seq[int]
  for w in st.spectra:
    if w.id != LiveSpectrum:
      ids.add w.id
      let vp = igGetMainViewport()
      let step = 28 * scale * float32((w.id - 1) mod 8)
      igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + vp.WorkSize.x / 2 + step,
        y: vp.WorkPos.y + vp.WorkSize.y / 2 + step), ImGui_Cond_FirstUseEver.cint,
        ImVec2_c(x: 0.5, y: 0.5))
      igSetNextWindowSize(ImVec2_c(x: FftSize[0] * scale, y: FftSize[1] * scale),
        ImGui_Cond_FirstUseEver.cint)
      var open = true
      if igBegin(w.fftTitle.cstring, addr open, 0):
        ui.drawBody(w, t, marks, res)
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

func readoutOf*(ui: SpectraUi; id: int): (string, int) =
  ## What window `id`'s pointer read last frame, and the bin; "" and -1
  ## for nothing (tests).
  (ui.readout.getOrDefault(id, ""), ui.readAt.getOrDefault(id, -1))
