## The compare window: two traces, A and B, overlaid for QC. One window.
## Stacked panels, not tabs: a field QC comparison wants the signal and the
## phase on screen together, the same way an FFT window stacks its phase
## under the amplitude. The window reads the state and issues commands.

import std/[math, strutils]
import imguin/cimgui
import ../../core/state
import ../../view/[compareview, curveplot, theme]
import curveplot as curves, icons, marks, placement, style

type
  CompareUi* = object
    signal, spec, phase, corr: CurvePlotUi
    fromMs, toMs, shiftMs: float64
    typedShift: bool
    synced: int

proc chip(label, text: string; ink: Rgba; markName: string; marks: var Marks) =
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(ink))
  igTextUnformatted(label.cstring, nil)
  igPopStyleColor(1)
  igSameLine(0, -1)
  igTextUnformatted(text.cstring, nil)
  marks.mark(markName)

proc drawCompare*(ui: var CompareUi; st: AppState; t: Theme; scale: float32;
    marks: var Marks): seq[Command] =
  ## The compare window, when it is open. Closing it, or a control, is a command.
  if not st.compareOpen: return
  placeNext(3, (760'f32, 920'f32), scale)
  var open = true
  let title = IconPulse & "  Compare two traces###compare"
  if not igBegin(title.cstring, addr open, 0):
    igEnd()
    if not open: result.add Command(kind: ckCompareWindow, compareOpen: false)
    return
  marks.markWindow("compare")
  let pic = st.comparePicture
  chip("A", st.compareChip(cwA), inkA(t), "compare.chip.A", marks)
  if st.compareA.recordText.len > 0 or st.compareA.channelText.len > 0 or
      st.compareA.stationText.len > 0:
    igTextDisabled("%s", (st.compareA.recordText & "  " & st.compareA.channelText & "  " &
      st.compareA.stationText).cstring)
  chip("B", st.compareChip(cwB), inkB(t), "compare.chip.B", marks)
  if st.compareB.recordText.len > 0 or st.compareB.channelText.len > 0 or
      st.compareB.stationText.len > 0:
    igTextDisabled("%s", (st.compareB.recordText & "  " & st.compareB.channelText & "  " &
      st.compareB.stationText).cstring)
  if st.compareA.filterWords.len > 0:
    igTextDisabled("%s", ("A, own filter: " & st.compareA.filterWords).cstring)
  if st.compareB.filterWords.len > 0:
    igTextDisabled("%s", ("B, own filter: " & st.compareB.filterWords).cstring)
  if igSmallButton("Swap"):
    result.add Command(kind: ckSwapCompare)
  marks.mark("compare.swap")
  igSameLine(0, -1)
  if igSmallButton("Clear A"):
    result.add Command(kind: ckClearCompare, compareSlot: cwA)
  marks.mark("compare.clearA")
  igSameLine(0, -1)
  if igSmallButton("Clear B"):
    result.add Command(kind: ckClearCompare, compareSlot: cwB)
  marks.mark("compare.clearB")
  igSameLine(0, -1)
  if igSmallButton("Clear both"):
    result.add Command(kind: ckClearCompare, compareSlot: cwBoth)
  marks.mark("compare.clear")
  if pic.note.len > 0:
    igTextWrapped("%s", pic.note.cstring)
  var opt = st.compareOptions
  var changed = false
  if igCheckbox("Difference (B − A)", addr opt.difference): changed = true
  marks.mark("compare.difference")
  igSameLine(0, -1)
  if igCheckbox("Shift B by the correlation peak", addr opt.shiftPeak): changed = true
  marks.mark("compare.shiftPeak")
  if ui.synced != st.compareRevision:
    ui.fromMs = pic.usedFromMs
    ui.toMs = pic.usedToMs
    ui.shiftMs = shiftBoxMs(opt.shiftMs, pic.appliedShiftMs, st.compareB.dtMs)
    ui.typedShift = not opt.shiftMs.isNaN
    ui.synced = st.compareRevision
  if igCheckbox("Shift B by", addr ui.typedShift):
    if ui.typedShift: ui.shiftMs = appliedShiftMs(ui.shiftMs, st.compareB.dtMs)
    opt.shiftMs = if ui.typedShift: ui.shiftMs else: NaN
    changed = true
  igSameLine(0, -1)
  igSetNextItemWidth(90)
  if igInputDouble("ms##compare.shift", addr ui.shiftMs, 0, 0, "%.1f", 0) and ui.typedShift:
    ui.shiftMs = appliedShiftMs(ui.shiftMs, st.compareB.dtMs)
    opt.shiftMs = ui.shiftMs
    changed = true
  marks.mark("compare.shiftMs")
  if igCheckbox("Match amplitudes (RMS)", addr opt.matchRms): changed = true
  marks.mark("compare.match")
  igSameLine(0, -1)
  if igCheckbox("Flip B's polarity", addr opt.flip): changed = true
  marks.mark("compare.flip")
  igSetNextItemWidth(90)
  if igInputDouble("From ms##compare.from", addr ui.fromMs, 0, 0, "%.1f", 0):
    opt.fromMs = ui.fromMs
    changed = true
  marks.mark("compare.from")
  igSameLine(0, -1)
  igSetNextItemWidth(90)
  if igInputDouble("To ms##compare.to", addr ui.toMs, 0, 0, "%.1f", 0):
    opt.toMs = ui.toMs
    changed = true
  marks.mark("compare.to")
  igSameLine(0, -1)
  if igSmallButton("Whole"):
    opt.fromMs = NaN
    opt.toMs = NaN
    changed = true
  marks.mark("compare.whole")
  igSetNextItemWidth(160)
  if igBeginCombo("##compare.phasePicture", ($opt.phasePicture).cstring, 0):
    for v in PhasePicture:
      if igSelectable_Bool(($v).cstring, v == opt.phasePicture, 0, ImVec2_c(x: 0, y: 0)) and
          v != opt.phasePicture:
        opt.phasePicture = v
        changed = true
    igEndCombo()
  marks.mark("compare.phasePicture")
  if changed:
    result.add Command(kind: ckCompareDisplay, compareShow: opt)
  if pic.refusal.len > 0:
    igTextWrapped("%s", pic.refusal.cstring)
    marks.mark("compare.refusal")
  let h = igGetFontSize() * 11
  let key = $st.compareRevision
  discard ui.signal.drawCurvePlot("compare.signal", signalPlot(pic, t), t,
    ImVec2_c(x: -1, y: h), key, marks)
  discard ui.spec.drawCurvePlot("compare.spectrum", spectrumPlot(pic, t), t,
    ImVec2_c(x: -1, y: h), "s" & key, marks)
  discard ui.phase.drawCurvePlot("compare.phase", phasePlot(pic, t), t,
    ImVec2_c(x: -1, y: h), "p" & key & $opt.phasePicture, marks)
  discard ui.corr.drawCurvePlot("compare.correlation", correlationPlot(pic, t), t,
    ImVec2_c(x: -1, y: h), "c" & key, marks)
  if pic.table.available:
    igTextUnformatted(("Peak " & formatFloat(pic.table.peak, ffDecimal, 3) &
      "    shift " & formatFloat(pic.table.shiftMs, ffDecimal, 1) &
      " ms    polarity " & pic.table.polarity).cstring, nil)
    marks.mark("compare.table")
  elif pic.table.whyNot.len > 0:
    igTextWrapped("%s", pic.table.whyNot.cstring)
  igEnd()
  if not open: result.add Command(kind: ckCompareWindow, compareOpen: false)
