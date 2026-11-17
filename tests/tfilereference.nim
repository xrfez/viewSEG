## "This file's reference trace": the record's trace with the vibrator reference code
## (21) as the reference of a cross-correlation and an envelope, chosen in the window,
## nothing stored in the archive. It is never chosen by itself: with no project
## reference a correlation still says "No reference is chosen" until the choice is
## made.
##
## - correlation on the baseplate trace: no reference chosen at first; with
##   `fileReference` it draws, against "This file's reference trace";
## - envelope: its phase against the reference is the reference trace's, named so;
## - the same choice on a record without the code says why and draws nothing;
## - `hasFileReference` and `vibReferencePlace` find the trace.
##
## Seen to fail: with `chosenReferenceFor` ignoring `fileReference`, the correlation
## still said "No reference is chosen".

import std/strutils
import viewSEG/core/[analysis, references, state]
import utils/[fixtures, vibfiles, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc answered(st: AppState; w: int): bool =
  not st.plots[w].waiting and st.plots[w].result.gen > 0 and
    st.plots[w].result.gen == st.plots[w].asked

proc main*() =
  withFixtures fx:
    var st = initAppState()
    let path = fx.vibFourSegy()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let base = st.sessions[0].base
    st.apply Command(kind: ckOpenPlot, plotView: avCorrelation, plotTraces: @[base + 1])
    doAssert st.settle(st.answered(0))
    doAssert st.plots[0].result.problem == NoReferenceChosen, st.plots[0].result.problem
    doAssert not st.plots[0].params.fileReference, "chosen by itself"
    doAssert st.hasFileReference(0)
    var p = st.plots[0].params
    p.fileReference = true
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: p)
    doAssert st.settle(st.answered(0) and st.plots[0].result.problem.len == 0 and
      st.plots[0].result.plots.len > 0), st.plots[0].result.problem
    doAssert st.plots[0].reference == FileReferenceName, st.plots[0].reference
    st.apply Command(kind: ckOpenPlot, plotView: avEnvelope, plotTraces: @[base + 1])
    doAssert st.settle(st.answered(1))
    var q = st.plots[1].params
    q.fileReference = true
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[1].id, plotParams: q)
    doAssert st.settle(st.answered(1) and st.plots[1].reference == FileReferenceName),
      st.plots[1].result.problem
    doAssert st.plots[1].result.problem == "", st.plots[1].result.problem
    st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[base])
    doAssert st.settle(st.answered(2))
    doAssert st.vibReferencePlace(2) == 0
    discard st.shutdown()

  withFixtures other:
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: other.vibPlainSegy())
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let base = st.sessions[0].base
    st.apply Command(kind: ckOpenPlot, plotView: avCorrelation, plotTraces: @[base + 1])
    doAssert st.settle(st.answered(0))
    doAssert not st.hasFileReference(0)
    var p = st.plots[0].params
    p.fileReference = true
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: p)
    doAssert st.settle(st.answered(0) and st.plots[0].result.problem == NoFileReference),
      st.plots[0].result.problem
    discard st.shutdown()
  echo "tfilereference: ok"

when isMainModule:
  main()
