## "Only traces in the template" in `core`, without a window, on `mapSps`'s spread with its X
## file and the SEG-D shot of source 1003 of line 1 (a time break, then 63 receivers; its X
## record plans 30 of them):
##
## - with one, it is available; off, nothing is read for it and every seismic trace shows;
## - on, the plot shows the 30 seismic traces the template lists (`layout.traces`), the
##   others (`unlisted`) are left out, and `templateView` says "30 of 63";
## - the auxiliary traces follow the Seismic / Aux choice, unchanged: Aux on adds the time
##   break; a killed trace hidden (`hideKilled`) is left out as well;
## - the choice is kept with the plot's other choices (`plot.templateOnly`), is read back from
##   the settings document, and the next plot starts with it;
## - off again: every trace shows once more;
## - the relation file unloaded: the option is not available, and turned on shows every trace.
##
## Seen to fail: with the job's `qcOnStations` not kept in `recordQc`, the template was never
## known and the plot kept 63 traces ("the template's traces only").

import std/os
import parseSEG
import viewSEG/core/[settingsnif, state]
import utils/[fixtures, waiting]

proc plan(st: AppState): TemplateView = st.templateView(st.findPanel(MainPanel))

proc traces(st: AppState): int = st.panel(MainPanel).layout.traces

proc filter(st: var AppState; f: TraceFilter) =
  st.apply Command(kind: ckFilter, panel: MainPanel, filter: f)

proc main*() =

  withFixtures fx:
    let sps = fx.mapSps()
    let shot = fx.mapShotSegd(0, 2)
    var st = initAppState()
    st.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r, fx.mapXps])
    doAssert st.settle(st.survey.layers.len == 3 and st.jobs.active.len == 0)
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: shot)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
      st.panel(MainPanel).layers.len > 0 and st.jobs.active.len == 0)
    let all = st.traces
    doAssert all == 63, "the seismic traces: " & $all
    doAssert st.plan.available and not st.plan.on
    doAssert st.recordQc.key.file == NoSession, "nothing is read while the option is off"

    block on:
      st.filter(TraceFilter(seismic: true, templateOnly: true))
      doAssert st.settle(st.plan.known and st.traces == MapPlanned * 3 and
        st.jobs.active.len == 0), "the template's traces only: " & $st.traces
      let v = st.plan
      doAssert v.on and v.shown == 30 and v.total == 63, $v
      doAssert st.panel(MainPanel).hidden.len == 33, $st.panel(MainPanel).hidden.len
      doAssert st.settings.plot.templateOnly, "kept with the plot's choices"

    block auxiliaryFollowsItsOwnFilter:
      st.filter(TraceFilter(seismic: true, auxiliary: true, templateOnly: true))
      doAssert st.settle(st.panel(MainPanel).laidOut and st.traces == 31), $st.traces
      st.filter(TraceFilter(seismic: false, auxiliary: true, templateOnly: true))
      doAssert st.settle(st.panel(MainPanel).laidOut and st.traces == 1), $st.traces
      st.filter(TraceFilter(seismic: true, templateOnly: true))
      doAssert st.settle(st.panel(MainPanel).laidOut and st.traces == 30), $st.traces

    block killedStillHidden:
      var s = st.settings
      s.hideKilled = true
      st.apply Command(kind: ckSettings, settings: s)
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[st.sessions[
          0].base + 1],
        on: true) # the first receiver: planned
      doAssert st.settle(st.panel(MainPanel).laidOut and st.traces == 29), $st.traces
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      doAssert st.settle(st.traces == 30), $st.traces

    block kept:
      var problems: seq[string]
      let back = readSettings(settingsDocument(st.settings), "settings.nif", Settings(), problems)
      doAssert problems.len == 0, $problems
      doAssert back.plot.templateOnly and not Settings().plot.templateOnly

    block off:
      st.filter(TraceFilter(seismic: true))
      doAssert st.settle(st.traces == all and st.recordQc.key.file == NoSession), $st.traces
      doAssert not st.settings.plot.templateOnly

    block noRelationFile:
      var id = NoSurveyLayer
      for l in st.survey.layers:
        if l.path == fx.mapXps: id = l.id
      st.apply Command(kind: ckUnloadSurvey, layer: id)
      doAssert st.settle(st.survey.layers.len == 3 and st.jobs.active.len == 0)
      doAssert not st.plan.available, "no relation file"
      st.filter(TraceFilter(seismic: true, templateOnly: true))
      doAssert st.settle(st.panel(MainPanel).laidOut and st.recordQc.job == NoJob)
      doAssert st.traces == all and st.plan.on and not st.plan.known,
        "every trace shows when there is no template"

when isMainModule:
  main()
