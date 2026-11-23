## "Only traces in the template" while the record's check has not answered, in `core`, without
## a window, on `mapSps`'s spread with its X file and the SEG-D shots of source 1003 and 1004
## of line 1 (a time break, then 63 receivers; the X record of each plans 30 of them):
##
## - with the option on, showing another record never lays out more seismic traces than the
##   template lists: the plot waits (`templateWait`, `templateView.waiting`, the agent's
##   picture "waiting for the check ...") and is read once, with the unlisted traces left out;
##   in every frame the test looks at, the layout is empty or holds the 30;
## - the check is made once: no job is started again over 200 frames;
## - a check stopped before it ends is an answer: every trace shows, once, and the plot does
##   not wait for ever;
## - the option turned off while the plot waits reads every trace at once;
## - with the option off, showing a record reads it at once (no waiting, no check).
##
## Seen to fail: with `newSource` reading the record at once whatever `templatePending` says
## (`if false and`), the plot never waited (`waited`) and laid out all 63 traces first.

import std/os
import parseSEG
import viewSEG/core/[settingsnif, state]
import utils/[fixtures, waiting]

proc plan(st: AppState): TemplateView = st.templateView(st.findPanel(MainPanel))

proc panel(st: AppState): Panel = st.panel(MainPanel)

proc show(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)

proc filter(st: var AppState; f: TraceFilter) =
  st.apply Command(kind: ckFilter, panel: MainPanel, filter: f)

proc main*() =

  withFixtures fx:
    let sps = fx.mapSps()
    let first = fx.mapShotSegd(0, 2)
    let second = fx.mapShotSegd(0, 3)
    var st = initAppState()
    st.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r, fx.mapXps])
    doAssert st.settle(st.survey.layers.len == 3 and st.jobs.active.len == 0)
    st.filter(TraceFilter(seismic: true)) # (a plot of its own to choose with)
    st.show first
    doAssert st.settle(st.sessions.len == 1 and st.panel.laidOut and st.panel.layers.len > 0 and
      st.jobs.active.len == 0)
    doAssert st.panel.layout.traces == 63

    block offReadsAtOnce:
      st.show second
      doAssert not st.panel.templateWait, "nothing to wait for with the option off"
      doAssert st.settle(st.sessions.len > 0 and st.sessions[^1].path == second and
        st.panel.laidOut and st.panel.layout.traces == 63)
      doAssert st.recordQc.key.file == NoSession, "no check with the option off"

    st.filter(TraceFilter(seismic: true, templateOnly: true))
    doAssert st.settle(st.plan.known and st.panel.laidOut and st.panel.layout.traces == 30)

    block stepping:
      var seen: seq[int]
      var loads = 0
      var waited = false
      var was = st.panel.laidOut
      st.show first
      for frame in 0 ..< 200:
        discard st.drainInbox()
        let p = st.panel
        waited = waited or p.templateWait
        if p.templateWait: doAssert st.plan.waiting and not p.laidOut
        if p.laidOut and p.layout.traces > 0:
          seen.add p.layout.traces
        if p.laidOut and not was: inc loads
        was = p.laidOut
        if frame < 150 and not (p.laidOut and p.layout.traces == 30): sleep 5
      doAssert waited
      for n in seen:
        doAssert n == 30, "a layout of " & $n & " traces was seen"
      doAssert seen.len > 0 and loads == 1, "one read of the record: " & $loads
      doAssert st.jobs.active.len == 0 and not st.panel.templateWait
      let rev = st.recordQc.revision
      for frame in 0 ..< 200: discard st.drainInbox()
      doAssert st.recordQc.revision == rev, "the check is not made again"
      doAssert st.jobs.active.len == 0

    block stopped:
      st.show second
      doAssert st.settle(st.panel.templateWait or st.recordQc.job != NoJob)
      discard st.jobs.cancel(st.recordQc.job)
      doAssert st.settle(st.panel.laidOut and not st.panel.templateWait and
        st.jobs.active.len == 0)
      let n = st.panel.layout.traces
      doAssert (st.recordQc.hits[mfUnlisted].state == fsDone and n == 30) or
        (st.recordQc.hits[mfUnlisted].state != fsDone and n == 63),
        "a stopped check shows every trace: " & $n
      let rev = st.recordQc.revision
      for frame in 0 ..< 200: discard st.drainInbox()
      doAssert st.recordQc.revision == rev, "a stopped check is not made again"

    block offWhileWaiting:
      st.show first
      doAssert st.settle(st.panel.templateWait or st.panel.laidOut and st.panel.layout.traces == 30)
      st.filter(TraceFilter(seismic: true))
      doAssert not st.panel.templateWait
      doAssert st.settle(st.panel.laidOut and st.panel.layout.traces == 63 and
        st.jobs.active.len == 0)

when isMainModule:
  main()
