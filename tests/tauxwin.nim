## The Aux window's panel, in `core`, without a window: a second panel of the role `prAux`
## that shows the auxiliary traces of the record the Seismic window shows, and nothing it
## has no business with.
##
## - the capabilities of each role (`capsOf`): the Aux window has wiggles, the gain types
##   None, Fixed and Normalized, no record stepper, no filters, no sort, no first breaks,
##   no map group in its menu;
## - closed (the start), it has no panel and reads nothing; opened, its panel shows the
##   record's auxiliary traces (kills applied when killed traces are hidden), the file's
##   edits too;
## - it follows the Seismic window: another record, another file, a record with no
##   auxiliary trace (an empty layout, not a failed read), and it never has a record of its
##   own (`ckGather`, `ckShowFile`, `ckFilter`, `ckSort`, `ckProcessing` on it are refused);
## - its display is its own: gain None, Fixed or Normalized (another type becomes
##   Normalized), wiggles whatever is asked, and neither the Seismic window's display nor
##   its remembered defaults change; its display and header are remembered apart
##   (`settings.aux`) and written to and read from the settings file;
## - with both windows open the jobs settle: over 200 frames, with the first-break overlay
##   on, only the record's own jobs start, once each, and the Aux window starts none;
## - closed again, it reads nothing more, and the Seismic window's steps start no read of
##   it.
##
## Seen to fail: with `followAux` not retargeting when the record changed, `follows` found
## the Aux window on the first record; with `AuxRefused` empty, `refused` found its record
## moved; with the display not cleaned by `forAux`, `ownDisplay` found Exponential gain on it;
## with the gain written to the plot's remembered display, `ownDisplay` found the plot's
## defaults changed; with `(aux ...)` not read, `persisted` found the defaults back.

import std/[os, sequtils]
import parseSEG
import viewSEG/core/[settingsnif, state]
import utils/[auxfiles, fixtures, waiting]

proc aux(st: AppState): Panel = st.panels[st.auxIndex]

proc auxReady(st: AppState): bool =
  st.auxIndex >= 0 and st.aux.laidOut and st.aux.layers.len > 0

proc mainReady(st: AppState): bool =
  let p = st.panel(MainPanel)
  p.laidOut and p.layers.len > 0

proc main*() =

  withFixtures fx:
    let path = twoRecordsSegy(fx.dir)
    let other = fx.twoSetSegd()

    block capabilities:
      let main = capsOf(prSeismic)
      let aux = capsOf(prAux)
      doAssert main.stepsRecords and main.filters and main.sort and main.breaks
      doAssert not (aux.stepsRecords or aux.filters or aux.sort or aux.breaks or
        aux.templateButton or aux.traceChoice or aux.menuMap or aux.menuWholeRecord or
        aux.menuFilters or aux.chooseGain)
      doAssert aux.modes == {dmWiggle} and aux.gains == {dgNone, dgFixed, dgNormalized}
      doAssert aux.settingsTabs == {stLook, stTraces}
      doAssert main.gains.card > aux.gains.card

    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.mainReady)

    block closed:
      doAssert st.auxIndex < 0 and not st.auxOpen, "a panel before the window was opened"
      doAssert st.panels.len == 1
      let reads = st.tilesTaken
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
      doAssert st.settle(st.mainReady and st.panel(MainPanel).layers[0].source.gather == 1)
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 0)
      doAssert st.settle(st.mainReady and st.panel(MainPanel).layers[0].source.gather == 0)
      doAssert st.panels.len == 1, "closed, the Aux window made a panel"
      discard reads

    var base = 0
    block opened:
      st.apply Command(kind: ckAuxWindow, onScreen: true)
      doAssert st.auxOpen
      doAssert st.settle(st.auxReady)
      let a = st.aux
      doAssert a.role == prAux and a.id != MainPanel
      doAssert st.windowTitle(a.id) == "Aux", st.windowTitle(a.id)
      doAssert a.layers[0].filter == auxFilter()
      doAssert a.layers[0].source.gather == 0
      doAssert a.layers[0].source.file == st.panel(MainPanel).layers[0].source.file
      doAssert a.layout.traces == 2, "the record's two auxiliary traces: " & $a.layout.traces
      doAssert a.shown == @[3, 4], $a.shown
      doAssert a.layers[0].display.gain == dgNormalized and a.layers[0].display.mode == dmWiggle
      doAssert st.panel(MainPanel).layout.traces == 3, "the Seismic window changed"
      base = st.sessions[0].base

    block killed:
      # kills are the file's: shown in the Aux window as in the Seismic window's
      var s = st.settings
      s.hideKilled = true
      st.apply Command(kind: ckSettings, settings: s)
      st.apply Command(kind: ckEdit, panel: st.aux.id, edit: teKilled, on: true,
        edited: @[base + 3])
      doAssert st.settle(st.auxReady and st.aux.layout.traces == 1 and st.aux.shown == @[4]),
        "a killed auxiliary trace is still shown: " & $st.aux.shown
      st.apply Command(kind: ckUndoEdit, panel: st.aux.id)
      doAssert st.settle(st.auxReady and st.aux.shown == @[3, 4]), $st.aux.shown
      s.hideKilled = false
      st.apply Command(kind: ckSettings, settings: s)
      doAssert st.settle(st.auxReady and st.aux.shown == @[3, 4])

    block follows:
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
      doAssert st.settle(st.auxReady and st.aux.layers[0].source.gather == 1 and
        st.mainReady and st.panel(MainPanel).layers[0].source.gather == 1)
      doAssert st.aux.layout.traces == 0 and st.aux.laidOut,
        "a record with no auxiliary traces: an empty layout"
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 0)
      doAssert st.settle(st.auxReady and st.aux.layers[0].source.gather == 0 and
        st.aux.layout.traces == 2)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: other)
      doAssert st.settle(st.mainReady and st.auxReady and
        st.aux.layers[0].source.file == st.panel(MainPanel).layers[0].source.file and
        st.aux.layout.traces == 2)
      doAssert st.settle(st.sessions.len == 1), "the first file stayed open for the Aux window"
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.mainReady and st.auxReady and st.aux.layout.traces == 2 and
        st.aux.layers[0].source.file == st.panel(MainPanel).layers[0].source.file)

    block refused:
      let was = st.aux.layers[0]
      let id = st.aux.id
      st.apply Command(kind: ckGather, panel: id, gather: 1)
      st.apply Command(kind: ckFilter, panel: id, filter: TraceFilter(seismic: true))
      st.apply Command(kind: ckSort, panel: id, order: @[SortKey(field: hfChannel)])
      st.apply Command(kind: ckShowFile, panel: id, path: other)
      discard st.drainInbox()
      doAssert st.aux.layers[0].source.gather == was.source.gather and
        st.aux.layers[0].source.file == was.source.file, "its record moved on its own"
      doAssert st.aux.layers[0].filter == was.filter and st.aux.layers[0].order.len == 0
      doAssert st.settle(st.auxReady and st.aux.layout.traces == 2)

    block ownDisplay:
      let plotBefore = st.settings.plot.display
      let mainBefore = st.panel(MainPanel).layers[0].display
      func same(a, b: DisplaySettings): bool =
        a.gain == b.gain and a.gainDb == b.gainDb and a.fills == b.fills and a.mode == b.mode
      var d = st.aux.layers[0].display
      d.gain = dgExponential
      d.mode = dmDensity
      d.firstBreaks = true
      d.gainDb = 6
      d.fills = {wfPositive, wfNegative}
      st.apply Command(kind: ckDisplay, panel: st.aux.id, display: d)
      let got = st.aux.layers[0].display
      doAssert got.gain == dgNormalized, "Exponential on the Aux window: " & $got.gain
      doAssert got.mode == dmWiggle and not got.firstBreaks
      doAssert got.gainDb == 6 and got.fills == {wfPositive, wfNegative}
      for g in [dgNone, dgNormalized, dgFixed]:
        d = st.aux.layers[0].display
        d.gain = g
        st.apply Command(kind: ckDisplay, panel: st.aux.id, display: d)
        doAssert st.aux.layers[0].display.gain == g
      doAssert same(st.panel(MainPanel).layers[0].display, mainBefore),
        "the Seismic window's display changed with the Aux window's"
      doAssert same(st.settings.plot.display, plotBefore),
        "the plot's remembered defaults changed"
      doAssert st.settings.aux.display.gain == dgFixed and st.settings.aux.display.gainDb == 6
      # the Seismic window's gain is its own too
      var m = st.panel(MainPanel).layers[0].display
      m.gain = dgNone
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: m)
      doAssert st.aux.layers[0].display.gain == dgFixed
      doAssert st.settings.aux.display.gain == dgFixed
      st.apply Command(kind: ckHeader, panel: st.aux.id,
        header: HeaderChoice(auto: false, fields: @[hfTrace]))
      doAssert st.settings.aux.header.fields == @[hfTrace]
      doAssert st.settings.plot.header.auto, "the plot's header changed"

    block persisted:
      var problems: seq[string]
      let again = readSettings(settingsDocument(st.settings), "aux", Settings(), problems)
      doAssert problems.len == 0, $problems
      doAssert again.aux.display.gain == dgFixed and again.aux.display.gainDb == 6
      doAssert again.aux.display.fills == {wfPositive, wfNegative}
      doAssert again.aux.header.fields == @[hfTrace] and not again.aux.header.auto
      doAssert again.plot.display.gain == st.settings.plot.display.gain

    block jobs:
      # both windows on one record, the first-break overlay on: the record's own jobs start,
      # once, and settle; the Aux window starts none
      var m = st.panel(MainPanel).layers[0].display
      m.firstBreaks = true
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: m)
      func newest(st: AppState): int =
        for j in st.jobs.list: result = max(result, int(j.id))
      let before = st.newest
      var layouts = 0
      var was = st.aux.laidOut
      for frame in 0 ..< 200:
        discard st.drainInbox()
        if st.aux.laidOut and not was: inc layouts
        was = st.aux.laidOut
        if frame < 150 and st.jobs.active.len > 0: sleep 5
      let started = st.newest - before
      doAssert started <= 4, "jobs started over 200 frames: " & $started
      doAssert st.jobs.active.len == 0, "jobs still running"
      doAssert layouts == 0, "the Aux window was laid out again"
      let rev = st.newest
      for frame in 0 ..< 200: discard st.drainInbox()
      doAssert st.newest == rev, "jobs start again once settled"
      m.firstBreaks = false
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: m)

    block stepping:
      # the record steps: each read is the Seismic window's and the Aux window's, one each
      let reads = st.tilesTaken
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
      doAssert st.settle(st.mainReady and st.auxReady and st.aux.layers[0].source.gather == 1)
      for frame in 0 ..< 50: discard st.drainInbox()
      doAssert st.tilesTaken - reads <= 3, "reads for one step: " & $(st.tilesTaken - reads)
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 0)
      doAssert st.settle(st.mainReady and st.auxReady and st.aux.layers[0].source.gather == 0 and
        st.aux.layout.traces == 2)

    block closedAgain:
      st.apply Command(kind: ckAuxWindow, onScreen: false)
      doAssert not st.auxOpen
      doAssert st.aux.layers.len == 0, "closed, the Aux window still shows a record"
      doAssert st.tiles(st.auxIndex).len == 0
      let reads = st.tilesTaken
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
      doAssert st.settle(st.mainReady and st.panel(MainPanel).layers[0].source.gather == 1)
      for frame in 0 ..< 50: discard st.drainInbox()
      doAssert st.aux.layers.len == 0 and st.tiles(st.auxIndex).len == 0
      doAssert st.tilesTaken - reads <= 2, "closed, the Aux window cost reads"
      # opened again it takes its own display back
      st.apply Command(kind: ckAuxWindow, onScreen: true)
      doAssert st.settle(st.auxReady and st.aux.layers[0].source.gather == 1)
      doAssert st.aux.layers[0].display.gain == dgFixed and st.aux.layers[0].display.gainDb == 6

    st.shutdown()
  echo "tauxwin: ok"

when isMainModule:
  main()
