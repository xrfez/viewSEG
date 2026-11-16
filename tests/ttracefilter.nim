## The Seismic / Aux choice is kept where the plot's other display choices are
## kept: across records of a file, when another file is shown and when the
## first is shown again, for a new plot and a second panel, in the next run,
## and when a project is opened again. A file with no auxiliary traces shows
## its seismic traces and does not change the remembered choice, so a folder
## being watched keeps the same traces on the next shot that has them. A
## record the choice leaves empty stays empty.
##
## Seen to fail: with `ckFilter` not keeping the choice in the plot defaults
## and `show` not applying it, a file with no auxiliary traces showed none
## (`a file with no auxiliary traces showed none`).

import std/[os, times]
import parseSEG
import viewSEG/core/[openchoice, state]
import utils/[fixtures, waiting]

const Look = initDuration(milliseconds = 40)

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond) and (discard st.drainInbox(); cond))

proc appIn(dir: string): AppState =
  result = initAppState()
  result.keepSettingsIn(dir, loadSettings(dir / SettingsFileName))
  result.rememberFilesIn(dir)

proc shown(st: AppState): string =
  let i = st.shownFile(st.findPanel(MainPanel))
  if i >= 0: st.sessions[i].path else: ""

proc laidOut(st: AppState): bool =
  let p = st.panel(MainPanel)
  p.laidOut and p.layers.len > 0

proc showFile(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.shown == path and st.laidOut), "not shown: " & path

proc auxOnly(st: var AppState; panel = MainPanel) =
  st.apply Command(kind: ckFilter, panel: panel,
    filter: TraceFilter(seismic: false, auxiliary: true))
  doAssert st.settle(st.panel(panel).laidOut)

proc choice(st: AppState; panel = MainPanel): tuple[seismic, auxiliary: bool] =
  let f = st.panel(panel).layers[0].filter
  (f.seismic, f.auxiliary)

proc twoShots(dir: string): string =
  ## Two records, each an auxiliary trace and a seismic trace.
  result = dir / "two-shots.sgy"
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: two shots, each with an auxiliary trace"]))
  var buf = newSeq[float32](8)
  for shot in 1 .. 2:
    for c in 1 .. 2:
      var k = initTraceKeys()
      (k.record, k.channel, k.intervalUs) = (float64(shot), float64(c), 2000.0)
      if c == 1: (k.traceCode, k.status) = (6'i16, tsAuxiliary)
      else: k.status = tsLive
      w.writeTrace(k, buf)
  doAssert w.close().len == 0

withFixtures fx:
  let dir = fx.dir / "config"
  createDir(dir)
  let aux = fx.twoSetSegd()
  let plain = fx.surveySegy()
  let shots = twoShots(fx.dir)

  block acrossRecordsAndBack:
    var st = appIn(dir)
    st.showFile(shots)
    doAssert st.sessions[0].gathers.len == 2 and st.sessions[0].records[0].aux > 0
    st.auxOnly()
    doAssert st.choice == (false, true)
    var d = st.panel(MainPanel).layers[0].display
    d.gainDb = 6
    d.orientation = orTimeAcross
    st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    st.apply Command(kind: ckSort, panel: MainPanel, order: @[SortKey(field: hfChannel)])
    doAssert st.choice == (false, true), "a gain or a sort dropped the choice"
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
    doAssert st.settle(st.panel(MainPanel).layers[0].source.gather == 1 and st.laidOut)
    doAssert st.choice == (false, true), "the next record dropped the choice"
    st.showFile(aux)
    doAssert st.choice == (false, true), "another file dropped the choice"
    doAssert st.panel(MainPanel).layers[0].display.gainDb == 6
    st.showFile(shots)
    doAssert st.choice == (false, true), "coming back dropped the choice"
    doAssert st.panel(MainPanel).layers[0].source.gather == 0
    # a file with no auxiliary traces shows its seismic traces, and the
    # remembered choice stays Aux alone
    st.showFile(plain)
    doAssert st.panel(MainPanel).layout.traces > 0, "a file with no auxiliary traces " &
      "showed none"
    doAssert st.choice == (true, false), "a file with no auxiliary traces kept Aux alone on screen"
    doAssert not st.settings.plot.seismic and st.settings.plot.auxiliary,
      "showing it overwrote the remembered choice"
    st.showFile(aux)
    doAssert st.choice == (false, true), "the next file with auxiliary traces did not " &
      "take the remembered choice"
    # an explicit choice that leaves this record empty stays empty
    st.showFile(plain)
    st.apply Command(kind: ckFilter, panel: MainPanel,
      filter: TraceFilter(seismic: false, auxiliary: true))
    doAssert st.settle(st.panel(MainPanel).laidOut and st.panel(MainPanel).layout.traces == 0),
      "a record left with nothing to show was filled in"
    st.shutdown()

  block restartAndSecondPanel:
    var st = appIn(dir)
    st.showFile(aux)
    doAssert st.choice == (false, true), "restart: " & $st.choice
    doAssert st.settings.plot.auxiliary and not st.settings.plot.seismic
    let second = st.addPanel()
    st.apply Command(kind: ckShowFile, panel: second, path: aux)
    doAssert st.settle(st.panel(second).laidOut)
    doAssert st.choice(second) == (false, true), "a second panel started at the default"
    st.apply Command(kind: ckClose, file: st.sessions[0].id)
    doAssert st.settle(st.sessions.len == 0)
    st.showFile(shots)
    doAssert st.choice == (false, true), "a new plot after a close started at the default"
    var ch = OpenChoice(verifyAll: true)
    st.apply Command(kind: ckReopen, reopenPath: shots, openChoice: ch)
    doAssert st.settle(st.shown == shots and st.laidOut and
      st.sessions[0].facts.opened.choice.verifyAll)
    doAssert st.choice == (false, true), "reopen dropped the choice"
    st.shutdown()

  block projectAgain:
    let job = fx.dir / "Job"
    let data = fx.dir / "data"
    createDir(data)
    block made:
      var st = appIn(dir / "project")
      st.showFile(aux)
      st.auxOnly()
      var d = st.panel(MainPanel).layers[0].display
      d.orientation = orTimeAcross
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[data])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0), "the project was not made"
      doAssert st.choice == (false, true)
      st.shutdown()
    var st = appIn(dir / "project")
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject and st.projectOpening.len == 0), "the project was not opened"
    doAssert st.settings.plot.display.orientation == orTimeAcross
    st.showFile(aux)
    doAssert st.choice == (false, true), "opening the project again dropped the choice: " &
      $st.choice
    doAssert st.panel(MainPanel).layers[0].display.orientation == orTimeAcross
    st.shutdown()

  block watch:
    let folder = fx.dir / "line"
    createDir(folder)
    copyFile(aux, folder / "shot1.sgd")
    var st = initAppState(watchEvery = Look)
    st.keepSettingsIn(dir / "watch", loadSettings(dir / "watch" / SettingsFileName))
    st.apply Command(kind: ckBrowse, paths: @[folder], showFirst: true)
    doAssert st.settle(st.shown == folder / "shot1.sgd" and st.laidOut and
      st.panel(MainPanel).layout.traces > 0)
    st.auxOnly()
    var s = st.settings
    s.files.followLatest = true
    st.apply Command(kind: ckSettings, settings: s)
    sleep 30
    copyFile(plain, folder / "shot2.sgy")
    doAssert st.settle(st.shown == folder / "shot2.sgy" and st.laidOut),
      "the new file was not followed"
    doAssert st.panel(MainPanel).layout.traces > 0, "a shot with no auxiliary traces " &
      "showed none"
    doAssert not st.settings.plot.seismic and st.settings.plot.auxiliary,
      "following it overwrote the remembered choice"
    sleep 30
    copyFile(aux, folder / "shot3.sgd")
    doAssert st.settle(st.shown == folder / "shot3.sgd" and st.laidOut)
    doAssert st.choice == (false, true), "the next shot did not take the remembered choice: " &
      $st.choice
    doAssert st.panel(MainPanel).layout.traces > 0
    st.shutdown()

echo "ttracefilter: ok"
