## What is set by hand in the Vibrator signature window survives a restart, with a project
## open and with none (temporary config folders, never the real one), headless, on the
## synthetic four-trace files of `utils/vibfiles` (codes 21, 19, 18, 20):
##
## - the polarity of GF and of M and B, chosen by hand, is remembered with the roles for the
##   file layout: in the project when one is open, else in the settings; a later file of
##   that layout opens with it ("remembered for this file layout"), after a restart;
## - a choice kept before polarities were (no polarity in its text) loads as recorded;
## - a polarity set through the agent is for the session: nothing is saved (settings file
##   and project document alike);
## - the other boxes (masses, harmonics, point limits and whether they are on, the six pass or
##   fail limits, the window length, "100 % force =") are plot options, kept in the user's
##   settings whether or not a project is open; the top frequency typed per reference is kept
##   in the project too, so it travels with it (a second user's empty settings, the same
##   project: it is there).
##
## Seen to fail: with `rememberRoles` storing the places only (polarity dropped), "the polarity
## did not come back" in both the project and the settings; with a polarity-only change not
## remembered (the places unchanged), the same.
##
## Which store holds what: the roles and polarity per layout `vibRole` (project) or
## `vibRoles` (settings); the plot options `plotOptions.vibrator.*` (settings); the typed top
## frequency `plotOptions.vibrator.tops` (settings) and `vibTop` (project).

import std/[math, os]
import viewSEG/core/[analysis, persist, settings, state]
import utils/[fixtures, vibfiles, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc open(st: var AppState; path: string): int =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  var at = -1
  doAssert st.settle((at = -1; (for i, s in st.sessions: (if s.path == path: at = i)); at >= 0) and
    st.panel(MainPanel).laidOut and st.shownFile(st.findPanel(MainPanel)) == at), path
  var base = 0
  for s in st.sessions:
    if s.path == path: base = s.base
  st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[base])
  result = st.plots.high
  doAssert st.settle(st.plots[result].result.gen > 0 and not st.plots[result].waiting)

proc reverse(st: var AppState; w: int; origin = coWindow) =
  var p = st.plots[w].params
  p.roles.groundForcePolarity = poReversed
  p.roles.massPolarity = poReversed
  st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p, origin: origin)
  doAssert st.settle(not st.plots[w].waiting)

proc started(dir: string): AppState =
  result = initAppState()
  result.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))

proc main*() =
  withFixtures fx:
    block in_a_project:
      let dir = fx.dir / "config-a"
      createDir(dir)
      let proj = fx.dir / "job"
      var st = started(dir)
      st.apply Command(kind: ckNewProject, projectPath: proj, projectName: "Job")
      doAssert st.settle(st.inProject)
      let w = st.open(fx.vibFourSegy())
      st.reverse(w)
      doAssert st.plots[w].params.roles.groundForcePolarity == poReversed
      st.apply Command(kind: ckCloseProject)
      doAssert st.settle(not st.inProject)
      discard st.shutdown()
      var back = started(dir)
      back.apply Command(kind: ckOpenProject, projectPath: proj)
      doAssert back.settle(back.inProject)
      let v = back.open(fx.vibFourAgainSegy())
      let r = back.plots[v].params.roles
      doAssert r.groundForcePolarity == poReversed and r.massPolarity == poReversed and
        r.source == rsRemembered, "the polarity did not come back: " & $r
      back.apply Command(kind: ckCloseProject)
      discard back.shutdown()

    block with_no_project:
      let dir = fx.dir / "config-b"
      createDir(dir)
      var st = started(dir)
      let w = st.open(fx.vibFourSegy())
      st.reverse(w)
      doAssert st.settings.vibRoles.len == 1, $st.settings.vibRoles
      discard st.shutdown()
      var back = started(dir)
      let v = back.open(fx.vibFourAgainSegy())
      let r = back.plots[v].params.roles
      doAssert r.groundForcePolarity == poReversed and r.massPolarity == poReversed and
        r.source == rsRemembered, "the polarity did not come back: " & $r
      # (another layout is not affected)
      let o = back.open(fx.vibOtherFourSegy())
      doAssert back.plots[o].params.roles.groundForcePolarity == poAsRecorded
      discard back.shutdown()

    block an_agents_polarity_is_for_the_session:
      let dir = fx.dir / "config-c"
      createDir(dir)
      let proj = fx.dir / "job-c"
      var st = started(dir)
      st.apply Command(kind: ckNewProject, projectPath: proj, projectName: "Job")
      doAssert st.settle(st.inProject)
      let w = st.open(fx.vibFourSegy())
      st.reverse(w, coAgent)
      doAssert st.plots[w].params.roles.groundForcePolarity == poReversed # for this run
      doAssert st.settings.vibRoles.len == 0 and st.project.doc.vibRoles.len == 0,
        "an agent's polarity was kept"
      st.apply Command(kind: ckCloseProject)
      doAssert st.settle(not st.inProject)
      discard st.shutdown()
      doAssert loadSettings(dir / "settings.nif").settings.vibRoles.len == 0
      var back = started(dir)
      back.apply Command(kind: ckOpenProject, projectPath: proj)
      doAssert back.settle(back.inProject)
      let v = back.open(fx.vibFourAgainSegy())
      doAssert back.plots[v].params.roles.groundForcePolarity == poAsRecorded,
        "an agent's polarity was saved"
      back.apply Command(kind: ckCloseProject)
      discard back.shutdown()

    block an_older_choice_is_as_recorded:
      var places: array[4, int]
      var polarity = [poReversed, poReversed]
      doAssert ["4/21.19.18.20 0.3.2.1"].choiceFor("4/21.19.18.20", places, polarity)
      doAssert places == [0, 3, 2, 1] and polarity == Recorded
      doAssert choiceText("4/21.19.18.20", [0, 3, 2, 1]) == "4/21.19.18.20 0.3.2.1"
      doAssert choiceText("4/21.19.18.20", [0, 3, 2, 1], [poReversed, poAutomatic]) ==
        "4/21.19.18.20 0.3.2.1 r.u"

    proc setBoxes(p: var AnalysisParams; key: string) =
      p.reactionMassKg = 3600
      p.baseplateMassKg = 1800
      p.harmonics = 7
      p.limitsOn = true
      p.limits.phaseDeg = 12
      p.qcWindowMs = 250
      p.qc.avgPhaseDeg = 4
      p.qc.peakForcePct = NaN
      p.forceHundredPct = 4000
      p.tops = p.tops.withTop(key, 180)

    proc checkBoxes(p: AnalysisParams; key: string; what: string) =
      doAssert p.reactionMassKg == 3600 and p.baseplateMassKg == 1800, what & ": masses"
      doAssert p.harmonics == 7 and p.limitsOn and p.limits.phaseDeg == 12, what & ": limits"
      doAssert p.qcWindowMs == 250 and p.qc.avgPhaseDeg == 4 and p.qc.peakForcePct.isNaN and
        p.qc.peakDistortionPct == 60, what & ": pass or fail limits"
      doAssert p.forceHundredPct == 4000, what & ": 100 % force"
      doAssert p.tops.topOf(key) == 180, what & ": top frequency"

    block the_other_boxes_with_no_project:
      let dir = fx.dir / "config-d"
      createDir(dir)
      var st = started(dir)
      let w = st.open(fx.vibFourSegy())
      var p = st.plots[w].params
      p.setBoxes(RecordedKey)
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p,
        origin: coWindow)
      doAssert st.settle(not st.plots[w].waiting)
      discard st.shutdown()
      var back = started(dir)
      let v = back.open(fx.vibFourAgainSegy())
      back.plots[v].params.checkBoxes(RecordedKey, "no project")
      discard back.shutdown()

    block the_other_boxes_in_a_project:
      let dir = fx.dir / "config-e"
      createDir(dir)
      let proj = fx.dir / "job-e"
      var st = started(dir)
      st.apply Command(kind: ckNewProject, projectPath: proj, projectName: "Job")
      doAssert st.settle(st.inProject)
      let w = st.open(fx.vibFourSegy())
      var p = st.plots[w].params
      p.setBoxes(RecordedKey)
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p,
        origin: coWindow)
      doAssert st.settle(not st.plots[w].waiting)
      doAssert st.project.doc.vibTops.len == 1, $st.project.doc.vibTops
      st.apply Command(kind: ckCloseProject)
      doAssert st.settle(not st.inProject)
      discard st.shutdown()
      var back = started(dir)
      back.apply Command(kind: ckOpenProject, projectPath: proj)
      doAssert back.settle(back.inProject)
      let v = back.open(fx.vibFourAgainSegy())
      back.plots[v].params.checkBoxes(RecordedKey, "project")
      back.apply Command(kind: ckCloseProject)
      discard back.shutdown()
      # the top frequency travels with the project: other settings, the same project
      let other = fx.dir / "config-f"
      createDir(other)
      var fresh = started(other)
      fresh.apply Command(kind: ckOpenProject, projectPath: proj)
      doAssert fresh.settle(fresh.inProject)
      let u = fresh.open(fx.vibFourAgainSegy())
      doAssert fresh.plots[u].params.tops.topOf(RecordedKey) == 180,
        "the top frequency is not in the project"
      doAssert fresh.vibTyped(fresh.plots[u]) == 180
      # cleared on the window: gone from the project too
      var q = fresh.plots[u].params
      q.tops = q.tops.withTop(RecordedKey, NaN)
      fresh.apply Command(kind: ckPlotDisplay, plot: fresh.plots[u].id, plotParams: q,
        origin: coWindow)
      doAssert fresh.settle(not fresh.plots[u].waiting)
      doAssert fresh.project.doc.vibTops.len == 0, $fresh.project.doc.vibTops
      fresh.apply Command(kind: ckCloseProject)
      discard fresh.shutdown()
  echo "tvibpersist: ok"

when isMainModule:
  main()
