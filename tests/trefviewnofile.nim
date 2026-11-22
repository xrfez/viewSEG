## Viewing a stored reference whatever is or is not open in the viewer.
##
## Seen to fail: with the reference job's answer carrying trace id 0 (its default) instead
## of -1, the answer was dropped as a pilot of a closed file, so with no file open the View
## window stayed on "Reading..." ("still waiting"), and a failed read never said why.

import std/[os, sequtils, strutils, times]
import parseSEG
import viewSEG/core/[references, state]
import utils/[chosenref, fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond), initDuration(seconds = 8))

proc tiny(path: string; hz: float64) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test"]))
  var buf = newSeq[float32](200)
  for i in 0 ..< buf.len: buf[i] = float32(sin(2 * 3.14159265 * hz * float64(i) * 0.002))
  for c in 1 .. 2:
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs) = (1.0, float64(c), 0.0, 2000.0)
    k.status = tsLive
    w.writeTrace(k, buf)
  doAssert w.close().len == 0

import std/math

proc main*() =
  withFixtures fx:
    var st = initAppState()
    let a = fx.dir / "a.sgy"
    let b = fx.dir / "b.sgy"
    tiny(a, 20)
    tiny(b, 30)
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: a)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let id = st.chooseStored(fx.dir / "refs", st.sessions[0].base, "stored")
    st.apply Command(kind: ckClose, file: st.sessions[0].id)
    doAssert st.settle(st.sessions.len == 0)

    block no_file_open:
      st.apply Command(kind: ckViewReference, refId: id)
      let w = st.refViews.high
      doAssert st.settle(not st.refViews[w].waiting), "still waiting"
      doAssert st.refViews[w].ys.len == 200 and st.refViews[w].note.len == 0,
        "not shown: " & st.refViews[w].note

    block a_missing_file_is_said:
      var gone = ""
      for e in st.references.entries:
        if e.id == id: gone = st.referencesHome / e.file
      let keep = gone & ".kept"
      moveFile(gone, keep)
      st.apply Command(kind: ckViewReference, refId: id)
      # the entry is marked missing only after a rescan; the job's own read fails
      if st.refViews.high >= 0 and st.refViews[st.refViews.high].waiting:
        let w = st.refViews.high
        doAssert st.settle(not st.refViews[w].waiting), "an endless Reading..."
        doAssert st.refViews[w].ys.len == 0 and st.refViews[w].note.len > 0
      moveFile(keep, gone)

    block another_file_open:
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: b)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      st.apply Command(kind: ckViewReference, refId: id)
      let w = st.refViews.high
      doAssert st.settle(not st.refViews[w].waiting), "still waiting"
      doAssert st.refViews[w].ys.len == 200 and st.refViews[w].note.len == 0,
        "not shown: " & st.refViews[w].note
    block the_source_file_open:
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: a)
      doAssert st.settle(st.sessions.len == 2 or st.panel(MainPanel).laidOut)
      st.apply Command(kind: ckViewReference, refId: id)
      let w = st.refViews.high
      doAssert st.settle(not st.refViews[w].waiting), "still waiting"
      doAssert st.refViews[w].ys.len == 200, st.refViews[w].note
    discard st.shutdown()
  echo "trefviewnofile: ok"

when isMainModule: main()
