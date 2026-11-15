## Reversing the polarity of every trace (`ckReverseAll`) is an operation on
## the data: the tiles the panel's reader makes then hold exactly what
## processSEG's `polarityOp` makes of the file's own samples (read with
## parseSEG, run through a compiled pipeline of that one op), so the
## status bar's amplitude is the reversed one; the tiles from before stay
## until the first reversed tile comes, which replaces them; it stays on
## for the next gather; turned off, the samples are as recorded again; it
## is never a setting but an edit of the file, so the file opened again is
## reversed and another file is not; and the file is never changed.
##
## Seen to fail: with `displayPipeline` leaving `polarityOp` out, "trace 0
## sample 79: 0.27144045 in the tile, processSEG's polarityOp gives
## -0.27144045"; with `drainInbox` keeping the tiles from before the
## reversal after the first new one (`samplesGen` not looked at), "2 tiles
## after the reversal".

import std/[os, strutils, times]
import parseSEG
import processSEG/[adapters, pipeline]
import processSEG/core/workspace
import viewSEG/core/state
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc answered(st: AppState): bool =
  let p = st.panel(MainPanel)
  not p.pending.isEmpty and st.tiles(0).len > 0 and st.tiles(0)[^1].request == p.pending

proc reverse(st: var AppState; on: bool) =
  st.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: on)

withFixtures fx:
  let path = fx.surveySegy()
  let before = (readFile(path), getLastModificationTime(path))
  var st = initAppState()
  st.apply Command(kind: ckOpen, paths: @[path])
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  var d = st.panel(MainPanel).layers[0].display
  d.gain = dgNone # nothing else on the samples: the tile holds them as decoded
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
  let lay = st.panel(MainPanel).layout
  # one tile row per trace, one column per sample: nothing decimated
  st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 640, 2 * lay.samples))
  doAssert st.settle(st.answered)
  let recorded = st.tiles(0)[^1]
  doAssert recorded.request.stride == 1 and recorded.request.decimation == 1,
    $recorded.request
  var at = DataPoint(x: 7, tMs: 0)
  while abs(pickAt(st.tiles(0), lay, at).amplitude) < 0.05 and at.tMs < 990: at.tMs += 2
  let p0 = pickAt(st.tiles(0), lay, at)
  doAssert p0.found and abs(p0.amplitude) >= 0.05, $p0.amplitude

  block reversed:
    st.reverse(true)
    doAssert st.panel(MainPanel).layers[0].reversed
    doAssert st.tiles(0).len > 0, "the tiles from before are drawn until the new one comes"
    doAssert st.settle(st.answered)
    doAssert st.tiles(0).len == 1, $st.tiles(0).len & " tiles after the reversal"
    let t = st.tiles(0)[^1]
    doAssert t.request.first == recorded.request.first and
      t.request.count == recorded.request.count and
      t.request.firstSample == recorded.request.firstSample and
      t.request.samples == recorded.request.samples, "another view was read"
    # processSEG's polarityOp on the file's own samples
    var f = openSeismic(path, keys = true)
    var log: DiagLog
    var x = f.readTraces(t.traces, log)
    doAssert log.len == 0
    let plan = initPipeline([polarityOp()]).compile(float32, lay.dtMs, x.shape[1])
    var ws = initWorkspace()
    ws.reserve(plan)
    plan.apply(x, f.chunkMeta(t.traces, dtMs = lay.dtMs), ws)
    var same = true
    for row in 0 ..< t.request.count:
      for j in 0 ..< t.columns:
        let want = x[row, t.request.firstSample + j]
        doAssert t.data[row * t.columns + j] == want, "trace " & $t.traces[row] & " sample " &
          $(t.request.firstSample + j) & ": " & $t.data[row * t.columns + j] &
          " in the tile, processSEG's polarityOp gives " & $want
        if recorded.data[row * t.columns + j] != want: same = false
    doAssert not same, "the reversed tile holds what the file holds"
    f.close()
    # the readout's amplitude is the reversed one
    var p1 = pickAt(st.tiles(0), lay, at)
    doAssert p1.found and p1.amplitude == -p0.amplitude, $p1.amplitude & " for " &
      $p0.amplitude
    var shown = p0 # as the status bar has them: over the plot
    (shown.inside, p1.inside) = (true, true)
    doAssert p1.text(rfAmplitude) == significant(-p0.amplitude) and
      p1.text(rfAmplitude) != shown.text(rfAmplitude), "the status bar reads " &
      p1.text(rfAmplitude) & " where it read " & shown.text(rfAmplitude)

  block nextGather:
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
    doAssert st.settle(st.panel(MainPanel).laidOut and st.answered)
    doAssert st.panel(MainPanel).layers[0].reversed, "the next gather is not reversed"
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 0)
    doAssert st.settle(st.panel(MainPanel).laidOut and st.answered)

  block off:
    st.reverse(false)
    doAssert st.settle(st.answered)
    st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 640, 2 * lay.samples))
    doAssert st.settle(st.answered)
    let p2 = pickAt(st.tiles(0), lay, at)
    doAssert p2.amplitude == p0.amplitude, $p2.amplitude & ", recorded " & $p0.amplitude

  block notASetting:
    st.reverse(true)
    doAssert "revers" notin settingsDocument(st.settings)
    st.apply Command(kind: ckClose, file: st.sessions[0].id)
    doAssert st.settle(st.sessions.len == 0)
    st.apply Command(kind: ckOpen, paths: @[path])
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    doAssert st.panel(MainPanel).layers[0].reversed, "the file opened again is not reversed"
    let other = fx.patchySegy()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: other)
    doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == other and
      st.panel(MainPanel).laidOut)
    doAssert not st.panel(MainPanel).layers[0].reversed, "another file is shown reversed"
  st.shutdown()
  doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
