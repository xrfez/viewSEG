## What the Headers window's Trace tab costs the UI thread while the
## pointer moves: with a large selection (a box on the map selects every
## trace recorded at its points), the tab is about the selection, so a
## new trace under the pointer changes nothing there and must cost
## nothing: 200 hovers with 200 000 traces selected take well under 200 ms
## (the traces the tab is about are found again only when the selection
## changes, and then the first 32 without sorting them all).
##
## Seen to fail: with the traces found again on every change of the
## selection's hover (`chosenTraces` sorting all 200 000 each time),
## "200 hovers" took 9 793 ms; with that fixed but the selection's size
## asked of the `IntSet` (`len` counts every element), 462 ms.
##
## Runs alone: it bounds a time (200 ms, about ten times what the old way
## of finding them took less than).

import std/[monotimes, times]
import viewSEG/core/[inspector, state]
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

block hoversWithALargeSelection:
  const Traces = 200_000
  withFixtures fx:
    var st = initAppState()
    let path = fx.manyTracesSegy(Traces)
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let base = st.sessions[0].base
    var all = newSeq[int](Traces)
    for i in 0 ..< Traces: all[i] = base + i
    st.apply Command(kind: ckSelect, traces: all, mode: smReplace)
    st.apply Command(kind: ckInspect, inspect: {ipTraceHeaders})
    doAssert st.inspection.chosen.total == Traces and
      st.inspection.chosen.traces.len == MaxInspected
    doAssert st.inspection.chosen.traces[0] == base and
      st.inspection.chosen.traces[^1] == base + MaxInspected - 1
    let start = getMonoTime()
    for i in 0 ..< 200:
      st.apply Command(kind: ckHover, trace: base + 100 + i mod 2)
    let ms = (getMonoTime() - start).inMilliseconds
    echo "theaderscost: 200 hovers with ", Traces, " traces selected: ", ms, " ms"
    doAssert st.selection.hover == base + 101
    doAssert st.inspection.chosen.total == Traces
    doAssert ms < 200, "200 hovers took " & $ms & " ms"
    st.shutdown()
