## What a plot's filters say about a file they cannot run on, in `core`,
## without a window: on a file whose headers give no sample interval, the
## filters are not run (a frequency means nothing without one), the
## drop-down's note says why (`intervalNote`), and the log says it once for
## the file, not at every change of a slider.
##
## Seen to fail: with `requestView` sending the filters made for the 1 ms
## the time axis counts samples by (`filterPipeline(dtMs)`), "filtered at an
## interval that is not known".

import std/strutils
import viewSEG/core/[log, processing, state, zoom]
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc answered(st: AppState): bool =
  let p = st.panel(MainPanel)
  not p.pending.isEmpty and st.tiles(0).len > 0 and st.tiles(0)[^1].request == p.pending

proc aboutFilters(st: AppState): int =
  for e in st.log:
    if "filter" in e.text.toLowerAscii: inc result

withFixtures fx:
  var st = initAppState()
  st.apply Command(kind: ckOpen, paths: @[fx.noIntervalSegy()])
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  st.apply Command(kind: ckView, panel: MainPanel,
    view: fitAll(st.panel(MainPanel).layout, 800, 600))
  doAssert st.settle(st.answered)
  let before = st.aboutFilters
  var pr = Processing(band: pbBandPass, f1: 4, f2: 8, f3: 60, f4: 80)
  for i in 0 ..< 6:
    pr.f3 = 60 + float64(i)
    st.apply Command(kind: ckProcessing, panel: MainPanel, processing: pr)
    doAssert st.settle(st.answered)
  let said = st.aboutFilters - before
  doAssert said <= 1, $said & " messages about the filters for 6 changes"
  let p = st.panel(MainPanel)
  doAssert st.tiles(0)[^1].filtered == 0, "filtered at an interval that is not known"
  let note = pr.intervalNote(p.layout)
  doAssert "sample interval" in note, note
  doAssert Processing().intervalNote(p.layout) == "", "a note with no filter set"
  st.shutdown()
