## Roles from the codes do not outlive the codes, and a window opened on any trace of a
## coded record holds the coded traces:
##
## - a window on a file with the vibrator codes, followed to a file with none, has its roles
##   in the window's order and says nothing of codes;
## - opened on a seismic trace of a record whose first four traces are coded, the window holds
##   the coded traces (and those after the first of them, 16 in all) and its roles are the
##   codes'.
##
## Seen to fail: with `rolesOf` keeping the code-given roles on a file without codes, `noCodes`
## read roles 0/3/2/1 from the trace identification codes; with the window opened from the
## selected trace on, `fromASeismicTrace` held none of the coded traces.

import std/strutils
import viewSEG/core/[analysis, state]
import utils/[fixtures, vibfiles, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc baseOf(st: AppState; path: string): int =
  for s in st.sessions:
    if s.path == path: result = s.base

proc main*() =
  withFixtures fx:
    block noCodes:
      var st = initAppState()
      let coded = fx.vibFourSegy()
      let plain = fx.vibPlainSegy()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: coded)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      st.apply Command(kind: ckOpenPlot, plotView: avVibrator,
        plotTraces: @[st.baseOf(coded)])
      doAssert st.settle(st.plots.len == 1 and not st.plots[0].waiting and
        st.plots[0].result.gen > 0)
      doAssert st.plots[0].params.roles.source == rsCodes
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: plain)
      doAssert st.settle(st.plots[0].file == "vib-plain.sgy" and not st.plots[0].waiting and
        st.plots[0].result.gen > 0)
      let r = st.plots[0].params.roles
      doAssert r.source == rsPosition and
        (r.reference, r.groundForce, r.mass, r.baseplate) == (0, 1, 2, 3), $r
      doAssert "trace identification codes" notin st.plots[0].result.note
      discard st.shutdown()
    block fromASeismicTrace:
      var st = initAppState()
      let path = fx.vibLongSegy()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let base = st.baseOf(path)
      st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[base + 10])
      doAssert st.settle(st.plots.len == 1 and not st.plots[0].waiting)
      let w = st.plots[0]
      doAssert w.traces.len == 16 and w.traces[0] == base and w.traces[3] == base + 3, $w.traces
      let r = w.params.roles
      doAssert r.source == rsCodes and
        (r.reference, r.groundForce, r.mass, r.baseplate) == (0, 3, 2, 1), $r
      discard st.shutdown()
  echo "tvibreview: ok"

when isMainModule:
  main()
