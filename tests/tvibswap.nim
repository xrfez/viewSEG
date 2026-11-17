## A vibrator signature's roles chosen by hand (the swap of mass and baseplate, say)
## are remembered per file layout (the record's trace count and its code sequence): in
## the project when one is open, else in the user's settings, and applied to every later
## file of that layout without touching the window again; a different layout is not
## affected. "Roles from the codes" puts the codes' roles back and forgets the choice.
##
## On synthetic files: `vibFourSegy` (codes 21, 19, 18, 20), `vibFourAgainSegy` (the same
## layout), `vibOtherFourSegy` (21, 18, 19, 20) and `vibThirteenSegy`.
##
## - the window says who is who in one line, with the codes' words, and where the roles
##   came from;
## - in a project: swap, close the project, a new app state reopens it, another file of
##   the layout opens with the swapped roles ("remembered for this file layout"); the
##   other layouts keep the codes' roles;
## - with no project: the same through the settings file;
## - "Roles from the codes" forgets it: a later file of the layout has the codes' roles;
## - a command from an agent is not kept (`keeps`).
##
## Seen to fail: with the choice kept nowhere (`rememberRoles` not called), the file of the
## same layout opened with the codes' roles ("remembered" not found).

import std/[os, strutils]
import viewSEG/core/[analysis, settings, state]
import utils/[fixtures, vibfiles, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc showFile(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  var at = -1
  doAssert st.settle((at = -1; (for i, s in st.sessions: (if s.path == path: at = i)); at >= 0) and
    st.panel(MainPanel).laidOut and st.shownFile(st.findPanel(MainPanel)) == at), path

proc open(st: var AppState; path: string): int =
  ## A vibrator signature opened on the first trace of the file shown.
  st.showFile(path)
  var base = 0
  for s in st.sessions:
    if s.path == path: base = s.base
  st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[base])
  result = st.plots.high
  doAssert st.settle(st.plots[result].result.gen > 0 and not st.plots[result].waiting)

func places(r: VibRoles): (int, int, int, int) =
  (r.reference, r.groundForce, r.mass, r.baseplate)

proc swap(st: var AppState; w: int; origin = coWindow) =
  var p = st.plots[w].params
  swap(p.roles.mass, p.roles.baseplate)
  st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p, origin: origin)
  doAssert st.settle(not st.plots[w].waiting)

proc main*() =
  withFixtures fx:
    let dir = fx.dir / "config"
    createDir(dir)
    let proj = fx.dir / "job"
    block inAProject:
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      st.apply Command(kind: ckNewProject, projectPath: proj, projectName: "Job")
      doAssert st.settle(st.inProject)
      let w = st.open(fx.vibFourSegy())
      doAssert st.plots[w].params.roles.places == (0, 3, 2, 1), $st.plots[w].params.roles
      doAssert st.plots[w].params.roles.source == rsCodes
      let line = st.vibRolesLine(st.plots[w])
      doAssert line == "Reference: trace 1 (vibrator reference (21)) · Ground force: trace 4 " &
        "(vibrator estimated ground force (20)) · Mass: trace 3 (vibrator reaction mass " &
        "(18)) · Baseplate: trace 2 (vibrator baseplate (19)) — from the trace " &
        "identification codes", line
      st.swap(w)
      doAssert st.plots[w].params.roles.places == (0, 3, 1, 2)
      doAssert st.plots[w].params.roles.source == rsHand
      doAssert st.vibRolesLine(st.plots[w]).endsWith("chosen by hand")
      st.apply Command(kind: ckClosePlot, plot: st.plots[w].id)
      st.apply Command(kind: ckCloseProject)
      doAssert st.settle(not st.inProject)
      discard st.shutdown()

    block reopened:
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      st.apply Command(kind: ckOpenProject, projectPath: proj)
      doAssert st.settle(st.inProject)
      let w = st.open(fx.vibFourAgainSegy())
      let r = st.plots[w].params.roles
      doAssert r.places == (0, 3, 1, 2) and r.source == rsRemembered, $r
      doAssert st.vibRolesLine(st.plots[w]).endsWith("remembered for this file layout")
      st.apply Command(kind: ckClosePlot, plot: st.plots[w].id)
      # another layout, and the thirteen-trace one: the codes' roles, the swap not applied
      let o = st.open(fx.vibOtherFourSegy())
      doAssert st.plots[o].params.roles.places == (0, 3, 1, 2) and
        st.plots[o].params.roles.source == rsCodes, $st.plots[o].params.roles
      # (codes 21, 18, 19, 20: mass is trace 2 and baseplate trace 3 by the codes)
      st.apply Command(kind: ckClosePlot, plot: st.plots[o].id)
      let t = st.open(fx.vibThirteenSegy())
      doAssert st.plots[t].params.roles.places == (0, 3, 2, 1) and
        st.plots[t].params.roles.source == rsCodes, $st.plots[t].params.roles
      doAssert st.plots[t].traces.len == 13, "every trace of the record can be picked"
      doAssert st.vibTraceNames(st.plots[t])[4] == "trace 5 · code 29 (not in the standard)",
        $st.vibTraceNames(st.plots[t])
      st.apply Command(kind: ckClosePlot, plot: st.plots[t].id)
      # "Roles from the codes" forgets the choice
      let a = st.open(fx.vibFourAgainSegy())
      var p = st.plots[a].params
      p.roles = st.codeRoles(a)
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[a].id, plotParams: p,
        origin: coWindow)
      doAssert st.settle(not st.plots[a].waiting)
      doAssert st.plots[a].params.roles.source == rsCodes and
        st.plots[a].params.roles.places == (0, 3, 2, 1)
      st.apply Command(kind: ckClosePlot, plot: st.plots[a].id)
      st.apply Command(kind: ckCloseProject)
      doAssert st.settle(not st.inProject)
      discard st.shutdown()

    block forgotten:
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      st.apply Command(kind: ckOpenProject, projectPath: proj)
      doAssert st.settle(st.inProject)
      let w = st.open(fx.vibFourSegy())
      doAssert st.plots[w].params.roles.source == rsCodes, "the choice was not forgotten"
      st.apply Command(kind: ckCloseProject)
      discard st.shutdown()

    block inTheSettings:
      let dir2 = fx.dir / "config2"
      createDir(dir2)
      var st = initAppState()
      st.keepSettingsIn(dir2, loadSettings(dir2 / "settings.nif"))
      let w = st.open(fx.vibFourSegy())
      st.swap(w)
      doAssert st.settings.vibRoles.len == 1, $st.settings.vibRoles
      discard st.shutdown()
      var back = initAppState()
      back.keepSettingsIn(dir2, loadSettings(dir2 / "settings.nif"))
      let v = back.open(fx.vibFourAgainSegy())
      doAssert back.plots[v].params.roles.places == (0, 3, 1, 2) and
        back.plots[v].params.roles.source == rsRemembered, $back.plots[v].params.roles
      discard back.shutdown()

    block anAgentsChoiceIsNotKept:
      let dir3 = fx.dir / "config3"
      createDir(dir3)
      var st = initAppState()
      st.keepSettingsIn(dir3, loadSettings(dir3 / "settings.nif"))
      let w = st.open(fx.vibFourSegy())
      st.swap(w, coAgent)
      doAssert st.plots[w].params.roles.source == rsHand # for this run
      discard st.shutdown()
      doAssert loadSettings(dir3 / "settings.nif").settings.vibRoles.len == 0,
        "an agent's choice was saved"
  echo "tvibswap: ok"

when isMainModule:
  main()
