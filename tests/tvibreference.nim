## A vibrator signature is measured against the project's chosen reference by
## default (what the unit was meant to sweep), and the window says which
## reference it used, in one sentence. On samples/vib/vib_signature.sgd, with
## the sample's first trace stored as the reference:
##
## - the default: "Measured against the project reference ...", and the recorded
##   R trace is measured against it as a signal of its own, a table row "Ref
##   (recorded)" after Ref;
## - `projectReference` false: against the recorded Ref trace, said, no such row;
## - no reference chosen (with the default on): the same fallback, said;
## - the choice is part of the plot's options: remembered (`optionsOf`) and put
##   back by Reset options (`builtin`).
##
## Seen to fail: with the project reference used whatever `projectReference` says,
## "an opted-out window still measured against the project reference"; with the
## recorded trace dropped when the archive's reference is used, "no row Ref
## (recorded)"; with the fallback silent, "the fallback is not said".

import std/[os, strutils]
import viewSEG/core/[analysis, plotoptions, state]
import utils/[chosenref, fixtures, waiting]

const sample = currentSourcePath().parentDir.parentDir / "samples" / "vib" /
  "vib_signature.sgd"

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func hasRecorded(r: AnalysisResult): bool =
  for row in r.table:
    if row[0] == "Ref (recorded)": return true

proc main*() =
  withFixtures fx:
    doAssert fileExists(sample), "no sample " & sample
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: sample)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let base = st.sessions[0].base
    discard st.chooseStored(fx.dir / "refs", base, "intended")
    st.apply Command(kind: ckOpenPlot, plotView: avVibrator,
      plotTraces: @[base, base + 1, base + 2, base + 3],
      plotParams: AnalysisParams(reactionMassKg: 3600, baseplateMassKg: 1800))
    doAssert st.settle(st.plots.len == 1 and st.plots[0].result.gen > 0 and
      not st.plots[0].waiting)
    doAssert st.plots[0].params.projectReference, "the project reference is not the default"
    let first = st.plots[0].result
    doAssert first.problem == "", first.problem
    doAssert first.against == "Measured against the project reference intended", first.against
    doAssert first.hasRecorded, "no row Ref (recorded): " & $first.table
    doAssert first.table[2][0] == "Ref (recorded)", $first.table

    var p = st.plots[0].params
    p.projectReference = false
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: p)
    doAssert st.settle(not st.plots[0].waiting and not st.plots[0].result.hasRecorded and
      st.plots[0].result.gen > first.gen)
    let own = st.plots[0].result
    doAssert own.against == "Measured against the recorded reference, trace 1 " &
      "(the project reference is not used)", "an opted-out window still measured against " &
      "the project reference: " & own.against

    st.apply Command(kind: ckSelectReference, refId: "")
    p.projectReference = true
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: p)
    doAssert st.settle(not st.plots[0].waiting and st.plots[0].result.gen > own.gen and
      "no project reference is chosen" in st.plots[0].result.against),
      "the fallback is not said: " & st.plots[0].result.against
    doAssert not st.plots[0].result.hasRecorded

    # remembered with the plot's options, back to the default by Reset options
    var o = PlotOptions()
    p.projectReference = false
    o.remember(avVibrator, p)
    doAssert not o.vibrator.projectReference
    doAssert o.applied(avVibrator, AnalysisParams()).projectReference == false
    doAssert builtin(avVibrator, p).projectReference
    discard st.shutdown()
  echo "tvibreference: ok"

when isMainModule:
  main()
