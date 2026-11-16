## New plot windows follow the Seismic plot unless frozen, the same way an
## unfrozen spectrum window follows it.
##
## - not frozen (the default): the window shows the selection in the record
##   on show when there is one, else what that view shows of the record with
##   no selection; a change of the selection, the record, the sort, a kill
##   or the plot's filters asks again, and another file opened in the plot
##   is followed;
## - a file that cannot feed the view (a vibrator signature of a record with
##   no pilot) leaves the window open and says so, and a file that can
##   brings the numbers back;
## - frozen: the traces and the file stay through a selection change and a
##   new file, the title names that file and those traces, and unfreezing
##   follows at once;
## - closing the file a frozen window is frozen on keeps the numbers it has,
##   as a frozen spectrum window does, and waits for nothing;
## - several selection changes in a row leave one request of the window
##   waiting (the latest), not a pile.
##
## Seen to fail: with the windows locked to the traces that opened them,
## "the spectrogram did not follow the selection".
##
## Break to see it fail: in `followPlots`, skip the repick (the window keeps
## the traces it was opened on).

import std/strutils
import viewSEG/core/state
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc answered(st: AppState; w: int): bool =
  w < st.plots.len and st.plots[w].result.gen > 0 and not st.plots[w].waiting

proc ids(s: Session; traces: openArray[int]): seq[int] =
  for t in traces: result.add s.base + t

withFixtures fx:
  var st = initAppState()
  let path = fx.surveySegy()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
    st.panel(MainPanel).shown.len > 0)
  var s = st.sessions[0]

  block followsSelection:
    st.apply Command(kind: ckSelect, traces: ids(s, @[0, 1]), mode: smReplace)
    st.apply Command(kind: ckOpenPlot, plotView: avSpectrogram)
    st.apply Command(kind: ckOpenPlot, plotView: avEnvelope)
    st.apply Command(kind: ckOpenPlot, plotView: avPhase)
    doAssert st.plots.len == 3, st.log[st.log.len - 1].text
    doAssert st.plots[0].traces == ids(s, @[0, 1])
    doAssert st.plots[1].traces == ids(s, @[0]), "an envelope is of the first selected"
    doAssert not st.plots[0].frozen
    doAssert st.settle(st.answered(0) and st.answered(1) and st.answered(2))
    st.apply Command(kind: ckSelect, traces: ids(s, @[4, 5, 6]), mode: smReplace)
    doAssert st.plots[0].traces == ids(s, @[4, 5, 6]),
      "the spectrogram did not follow the selection: " & $st.plots[0].traces
    doAssert st.plots[1].traces == ids(s, @[4]),
      "the envelope did not follow the selection: " & $st.plots[1].traces
    doAssert st.plots[2].traces == ids(s, @[4])
    doAssert st.settle(st.answered(0) and st.plots[0].result.gen == st.plots[0].asked)

  block followsRecord:
    # no selection: the record's own traces; the next record is followed
    st.apply Command(kind: ckClearSelection)
    doAssert st.plots[1].traces == @[s.base],
      "with no selection the envelope is not the record's first trace: " & $st.plots[1].traces
    let asks = st.plots[0].asks
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
    doAssert st.settle(st.panel(MainPanel).laidOut and st.panel(MainPanel).shown.len > 0)
    s = st.sessions[0]
    doAssert st.plots[1].traces == @[s.base + Channels],
      "the envelope did not follow the record: " & $st.plots[1].traces
    doAssert st.plots[0].asks > asks, "the spectrogram did not ask again for the record"
    doAssert st.plots[0].record.len > 0

  block followsSort:
    st.apply Command(kind: ckClearSelection)
    doAssert st.settle(st.panel(MainPanel).shown.len > 0)
    let before = st.plots[1].traces
    st.apply Command(kind: ckSort, panel: MainPanel,
      order: @[SortKey(field: hfChannel, descending: true)])
    doAssert st.settle(st.panel(MainPanel).shown.len > 0 and
      st.panel(MainPanel).shown[0] != 0)
    doAssert st.plots[1].traces != before,
      "the envelope did not follow the sort: still " & $st.plots[1].traces
    doAssert st.plots[1].first == st.panel(MainPanel).shown[0]
    st.apply Command(kind: ckSort, panel: MainPanel, order: @[])
    doAssert st.settle(st.panel(MainPanel).shown.len > 0 and st.panel(MainPanel).shown[0] == Channels)

  block followsEditsAndFilters:
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 0)
    doAssert st.settle(st.panel(MainPanel).laidOut)
    s = st.sessions[0]
    st.apply Command(kind: ckSelect, traces: ids(s, @[0, 1, 2]), mode: smReplace)
    doAssert st.settle(st.answered(0) and st.plots[0].result.gen == st.plots[0].asked)
    let asks = st.plots[0].asks
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[s.base + 1],
      on: true)
    discard st.drainInbox()
    doAssert st.plots[0].asks == asks + 1, "the kill was not followed"
    doAssert st.settle(st.answered(0) and st.plots[0].result.leftOut == 1),
      $st.plots[0].result.leftOut
    let filterAsks = st.plots[0].asks
    st.apply Command(kind: ckProcessing, panel: MainPanel,
      processing: Processing(band: pbBandPass, f1: 5, f2: 8, f3: 40, f4: 50))
    doAssert st.plots[0].asks == filterAsks + 1, "the filters were not followed"
    doAssert st.plots[0].traces == ids(s, @[0, 1, 2]),
      "a filter change re-picked the traces: " & $st.plots[0].traces
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[s.base + 1],
      on: false)
    st.apply Command(kind: ckProcessing, panel: MainPanel, processing: Processing())
    discard st.drainInbox()

  block frozenKeepsTracesAndFile:
    var p = st.plots[0].params
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: p, plotFrozen: true)
    let frozen = st.plots[0].traces
    let file = st.plots[0].file
    let asks = st.plots[0].asks
    doAssert file in st.plots[0].title and "trace" in st.plots[0].title,
      "the title does not name the file and traces: " & st.plots[0].title
    st.apply Command(kind: ckSelect, traces: ids(s, @[8, 9]), mode: smReplace)
    doAssert st.plots[0].traces == frozen and st.plots[0].asks == asks,
      "a frozen window followed the selection"
    doAssert st.plots[1].traces == ids(s, @[8]), "the unfrozen envelope did not follow"
    let other = fx.pilotSegy()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: other)
    doAssert st.settle(st.sessions.len >= 1 and st.panel(MainPanel).laidOut and
      st.sessions[st.shownFile(st.findPanel(MainPanel))].path == other)
    doAssert st.plots[0].traces == frozen and st.plots[0].file == file,
      "a frozen window followed the new file: " & st.plots[0].file & " " & $st.plots[0].traces
    doAssert st.findTrace(frozen[0]) >= 0, "the frozen window's file was closed under it"
    doAssert st.plots[1].file != file, "an unfrozen window did not follow the new file: " &
      st.plots[1].file
    # unfreezing follows at once
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: p, plotFrozen: false)
    doAssert not st.plots[0].frozen and st.plots[0].file != file,
      "unfreezing did not follow: " & st.plots[0].file
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.panel(MainPanel).laidOut and
      st.sessions[st.shownFile(st.findPanel(MainPanel))].path == path)
    s = st.sessions[st.shownFile(st.findPanel(MainPanel))]

  block cannotFeedThenRecovers:
    let vib = fx.pilotSegy()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: vib)
    doAssert st.settle(st.sessions.len >= 1 and st.panel(MainPanel).laidOut and
      st.sessions[st.shownFile(st.findPanel(MainPanel))].path == vib)
    let vibS = st.sessions[st.shownFile(st.findPanel(MainPanel))]
    st.apply Command(kind: ckSelect, traces: @[vibS.base], mode: smReplace)
    st.apply Command(kind: ckOpenPlot, plotView: avVibrator)
    st.apply Command(kind: ckClearSelection)
    doAssert st.plots[^1].view == avVibrator, st.log[st.log.len - 1].text
    let vw = st.plots.high
    doAssert st.settle(st.answered(vw) and st.plots[vw].result.problem == ""),
      st.plots[vw].result.problem
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.panel(MainPanel).laidOut and
      st.sessions[st.shownFile(st.findPanel(MainPanel))].path == path)
    doAssert st.plots[vw].view == avVibrator, "the window was closed"
    doAssert "pilot" in st.plots[vw].result.problem, st.plots[vw].result.problem
    doAssert not st.plots[vw].waiting
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: vib)
    doAssert st.settle(st.panel(MainPanel).laidOut and
      st.sessions[st.shownFile(st.findPanel(MainPanel))].path == vib and
      st.answered(vw) and st.plots[vw].result.problem == ""),
      "it did not recover: " & st.plots[vw].result.problem
    st.apply Command(kind: ckClosePlot, plot: st.plots[vw].id)

  block closeFrozenFile:
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.panel(MainPanel).laidOut and
      st.sessions[st.shownFile(st.findPanel(MainPanel))].path == path)
    s = st.sessions[st.shownFile(st.findPanel(MainPanel))]
    # a frozen spectrum and a frozen analysis window of this file
    st.apply Command(kind: ckSelect, traces: @[s.base], mode: smReplace)
    st.apply Command(kind: ckSpectrum, spectrumTraces: @[s.base])
    doAssert st.settle(st.spectra.len > 1 and st.spectra[^1].spectrum.raw.len > 0)
    var show = st.spectra[^1].display
    st.apply Command(kind: ckSpectrumDisplay, spectrum: st.spectra[^1].id, spectrumShow: show,
      frozen: true)
    st.apply Command(kind: ckOpenPlot, plotView: avEnvelope, plotTraces: @[s.base])
    let pw = st.plots.high
    doAssert st.settle(st.answered(pw))
    var pp = st.plots[pw].params
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[pw].id, plotParams: pp, plotFrozen: true)
    let specId = st.spectra[^1].id
    let had = st.plots[pw].result.gen
    st.apply Command(kind: ckClose, file: s.id)
    doAssert st.settle(st.sessions.len == 0 or
      st.findSession(s.id) < 0)
    let sw = st.findSpectrum(specId)
    doAssert sw >= 0, "the frozen spectrum window was closed"
    doAssert not st.spectra[sw].waiting, "a frozen spectrum window still waits"
    doAssert st.spectra[sw].spectrum.raw.len > 0, "a frozen spectrum window lost its numbers"
    doAssert st.findPlot(st.plots[pw].id) >= 0
    doAssert not st.plots[pw].waiting, "a frozen analysis window still waits"
    doAssert st.plots[pw].result.gen == had and st.plots[pw].result.plots.len > 0,
      "a frozen analysis window lost its numbers: " & st.plots[pw].result.problem
    discard st.shutdown()

  block latestWins:
    var g = initAppState()
    g.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert g.settle(g.sessions.len == 1 and g.panel(MainPanel).laidOut)
    let gs = g.sessions[0]
    g.apply Command(kind: ckSelect, traces: @[gs.base], mode: smReplace)
    g.apply Command(kind: ckOpenPlot, plotView: avSpectrogram)
    doAssert g.plots.len == 1
    for n in 0 .. 7:
      g.apply Command(kind: ckSelect, traces: @[gs.base + n], mode: smReplace)
    doAssert g.analysisQueued <= 1, "selection changes queued " & $g.analysisQueued &
      " requests"
    doAssert g.settle(g.answered(0) and g.plots[0].result.gen == g.plots[0].asked)
    doAssert g.plots[0].traces == @[gs.base + 7], "the latest selection lost: " &
      $g.plots[0].traces
    discard g.shutdown()
