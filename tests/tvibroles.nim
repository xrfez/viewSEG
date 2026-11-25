## A vibrator signature takes its roles from the traces' identification codes
## when they are the vibrator's (21 reference, 20 ground force, 18 reaction
## mass, 19 baseplate), on synthetic SEG-Y files:
##
## - `withCodeRoles`: roles from the codes of four traces in any order; a record
##   with no vibrator codes, or with the reference only, keeps the roles it had;
##   a choice made by hand on the same file stays, on another file the codes win;
## - in a window on a record of traces 21, 19, 18, 20 (the files' order), the roles are
##   Ref 0, GF 3, M 1, B 2 (the converter's layout: the reaction mass is the trace coded 19), `source` says the
##   codes did it and the window's note says "roles taken from the trace
##   identification codes";
## - a role changed in the window is a choice by hand, and stays;
## - a window that follows the panel to another file with codes takes the roles from
##   them and says so in the Messages, over a choice made by hand on the first file;
## - on a file with no vibrator codes the roles stay what they were (the window
##   order, then the persisted choice).
##
## Seen to fail: with the roles never taken from the codes (`rolesOf` giving the roles
## back), the check "the persisted choice won on the new file" failed.

import std/[json, os, strutils]
import parseSEG
import viewSEG/core/[analysis, log, state]
import viewSEG/remote/schema
import utils/[fixtures, vibfiles, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func has(log: MessageLog; part: string): bool =
  for e in log:
    if part in e.text: return true

proc sessionOf(st: AppState; path: string): int =
  result = -1
  for i, s in st.sessions:
    if s.path == path: result = i

proc showFile(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessionOf(path) >= 0 and st.panel(MainPanel).laidOut and
    st.shownFile(st.findPanel(MainPanel)) == st.sessionOf(path)), "no " & path

proc main*() =
  block pureRoles:
    let order = VibRoles()
    let a = order.withCodeRoles([21'i16, 19, 18, 20], "a")
    # (the external converter's layout: the reaction mass is the trace coded 19)
    doAssert (a.reference, a.mass, a.baseplate, a.groundForce) == (0, 1, 2, 3)
    doAssert a.source == rsCodes
    let b = order.withCodeRoles([20'i16, 18, 19, 21], "a")
    doAssert (b.reference, b.baseplate, b.mass, b.groundForce) == (3, 2, 1, 0)
    # only a record of exactly these four traces is the converter's: more traces keep the codes
    let longer = order.withCodeRoles([21'i16, 19, 18, 20, 30], "a")
    doAssert (longer.mass, longer.baseplate) == (2, 1), $longer
    # some codes missing: those roles are none
    let c = order.withCodeRoles([21'i16, 20], "a")
    doAssert (c.reference, c.groundForce, c.mass, c.baseplate) == (0, 1, -1, -1)
    # no vibrator codes, or the reference alone: as they were
    for codes in [@[6'i16, 6, 6, 6], @[21'i16, 1, 1, 1], @[19'i16, 18, 20]]:
      doAssert order.withCodeRoles(codes, "a") == order, $codes
    # by hand on this file stays; on another file the codes decide
    var hand = order
    (hand.reference, hand.groundForce, hand.source, hand.handFile) = (1, 0, rsHand, "a")
    doAssert hand.withCodeRoles([21'i16, 19, 18, 20], "a") == hand
    let other = hand.withCodeRoles([21'i16, 19, 18, 20], "b")
    doAssert other.source == rsCodes and other.reference == 0, $other
    doAssert hand.withCodeRoles([6'i16, 6, 6, 6], "b") == hand

  withFixtures fx:
    var st = initAppState()
    let plain = fx.vibPlainSegy()
    let coded = fx.vibFourSegy()
    st.showFile(plain)
    var base = st.sessions[0].base
    st.apply Command(kind: ckOpenPlot, plotView: avVibrator,
      plotTraces: @[base, base + 1, base + 2, base + 3])
    doAssert st.settle(st.plots.len == 1 and st.plots[0].result.gen > 0 and
      not st.plots[0].waiting)
    block noCodes:
      let r = st.plots[0].params.roles
      doAssert r.source == rsPosition and (r.reference, r.groundForce, r.mass, r.baseplate) ==
        (0, 1, 2, 3), $r
      doAssert "trace identification codes" notin st.plots[0].result.note
    # a choice by hand on the file without codes, kept across files
    var p = st.plots[0].params
    (p.roles.groundForce, p.roles.baseplate) = (3, 1)
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: p)
    doAssert st.plots[0].params.roles.source == rsHand
    doAssert st.plots[0].params.roles.handFile.len > 0
    st.showFile(coded)
    block otherFile:
      doAssert st.settle(st.plots[0].file == st.sessions[st.sessionOf(coded)].name and
        not st.plots[0].waiting and st.plots[0].result.gen > 0)
      let r = st.plots[0].params.roles
      doAssert r.source == rsCodes and (r.reference, r.mass, r.baseplate, r.groundForce) ==
        (0, 1, 2, 3), "the persisted choice won on the new file: " & $r
      doAssert st.log.has("do not apply here"), "not said in the Messages"
    # a window opened on the coded file: its codes in the files' order 21, 19, 18, 20
    st.apply Command(kind: ckClosePlot, plot: st.plots[0].id)
    base = st.sessions[st.sessionOf(coded)].base
    st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[base],
      plotParams: AnalysisParams())
    doAssert st.settle(st.plots.len == 1 and st.plots[0].result.gen > 0 and
      not st.plots[0].waiting)
    block fromCodes:
      let w = st.plots[0]
      doAssert w.traces.len == 4, $w.traces
      let r = w.params.roles
      doAssert r.source == rsCodes
      doAssert (r.reference, r.groundForce, r.mass, r.baseplate) == (0, 3, 1, 2), $r
      doAssert "the baseplate-coded trace is taken as the reaction mass" in st.vibRolesLine(w) and
        "Swap changes it" in st.vibRolesLine(w), st.vibRolesLine(w)
      doAssert "roles taken from the trace identification codes" in w.result.note,
        w.result.note
      doAssert w.result.problem == "", w.result.problem
      # an agent reads them from the window's params
      let shown = toJson(w.params)["roles"]
      doAssert shown["source"].getStr == "trace identification codes" and
        shown["groundForce"].getInt == 3, $shown
    block byHand:
      var q = st.plots[0].params
      (q.roles.mass, q.roles.baseplate) = (2, 1)
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: q)
      doAssert st.settle(not st.plots[0].waiting and st.plots[0].result.gen > 0)
      doAssert st.plots[0].params.roles.source == rsHand
      doAssert "roles taken from the trace" notin st.plots[0].result.note
      doAssert "taken as the reaction mass" notin st.vibRolesLine(st.plots[0])
    discard st.shutdown()
  echo "tvibroles: ok"

when isMainModule:
  main()
