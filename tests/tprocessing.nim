## A plot's filters (`ckProcessing`, `core/processing`) in `core`, without a
## window:
##
## - with a band-pass and a notch, the tiles the panel's reader makes hold
##   exactly what processSEG's plan of those filters makes of the file's own
##   samples (read with parseSEG, the plan run directly, on one thread);
## - the traces passed to the pool (`Tile.filtered`) are the request's, so
##   they follow the zoom: on a 20 000-trace record a whole view filters no
##   more traces than the plot has pixels, a zoomed one fewer still;
## - a parameter moved reads nothing from the file (the tile is made from
##   the samples at hand), even while the drive does not answer;
## - changed every few ms (a slider dragged), the plot follows: tiles of
##   changes already replaced are drawn as they come, each after the first
##   of the view alone (no read-ahead), which the next view brings back;
## - raw shows the samples as recorded, and processed again the filtered
##   ones; the corners are kept in order and within Nyquist;
## - the auxiliary traces are left as recorded unless the layer asks for
##   them to be filtered (`Processing.aux`), then they are filtered as the
##   plan does with them taken for live; a plot of an auxiliary trace alone
##   takes its level from it (none would draw nothing under most gains);
## - the filters stay on for the next record; the settings keep them for a
##   new plot (processed, not raw), written to the settings file and read
##   back as they were, and the file is never changed.
##
## Seen to fail: with `requestView` sending no filters, "0 traces filtered
## of 24"; with the panel's margin not taken to whole traces, "f1 and f4
## moved: the tile was read from the file (2 reads)"; with the auxiliary
## rows not made live (`auxLiveRows` not used), "the time break is not
## filtered with Aux on"; with `levelOf` not taking the auxiliary traces of
## a plot that has no other, "no level for the auxiliary trace alone: (rms:
## nan, peak: nan, clip: nan)"; with `drainInbox` taking only the newest
## request's tile, "0 tiles drawn while the filters changed"; with the run's
## requests reading ahead, "a tile of the run: 405 traces, ...".

import std/[os, strutils, times]
import parseSEG
import processSEG/[adapters, pipeline]
import processSEG/core/[types, workspace]
import viewSEG/core/[processing, settings, settingsnif, state]
import utils/[faultyfs, fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc answered(st: AppState): bool =
  let p = st.panel(MainPanel)
  not p.pending.isEmpty and st.tiles(0).len > 0 and st.tiles(0)[^1].request == p.pending

proc process(st: var AppState; pr: Processing) =
  st.apply Command(kind: ckProcessing, panel: MainPanel, processing: pr)

proc showAll(st: var AppState) =
  ## Gain none (nothing else on the samples) and every trace and sample at
  ## one tile cell each.
  var d = st.panel(MainPanel).layers[0].display
  (d.gain, d.mode) = (dgNone, dmDensity)
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
  let lay = st.panel(MainPanel).layout
  st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 640, 2 * lay.samples))
  doAssert st.settle(st.answered)

proc expected(path: string; t: Tile; dtMs: float64; pr: Processing; aux = false): Tensor[float32] =
  ## The tile's traces as processSEG's plan of `pr` makes them, whole.
  var f = openSeismic(path, keys = true)
  var log: DiagLog
  result = f.readTraces(t.traces, log)
  doAssert log.len == 0
  let plan = pr.filterPipeline(dtMs).compile(float32, dtMs, result.shape[1])
  var ws = initWorkspace()
  ws.reserve(plan)
  if aux:
    var keys: seq[TraceKeys]
    var lengths: seq[int]
    let rows = f.rowsOf(t.traces).auxLiveRows(keys, lengths)
    plan.apply(result, initChunkMeta(rows, dtMs), ws)
  else:
    plan.apply(result, f.chunkMeta(t.traces, dtMs = dtMs), ws)
  f.close()

proc sameAs(t: Tile; want: Tensor[float32]; what: string) =
  for row in 0 ..< t.request.count:
    for j in 0 ..< t.columns:
      let w = want[row, t.request.firstSample + j]
      doAssert t.data[row * t.columns + j] == w, what & ": trace " & $t.traces[row] &
        " sample " & $(t.request.firstSample + j) & ": " & $t.data[row * t.columns + j] &
        " in the tile, the plan gives " & $w

withFixtures fx:
  install()
  let path = fx.surveySegy()
  let before = (readFile(path), getLastModificationTime(path))
  var st = initAppState()
  st.apply Command(kind: ckOpen, paths: @[path])
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  st.showAll()
  let lay = st.panel(MainPanel).layout
  let recorded = st.tiles(0)[^1]
  doAssert recorded.filtered == 0, $recorded.filtered & " traces filtered with no filter"
  var pr = Processing(band: pbBandPass, f1: 4, f2: 8, f3: 60, f4: 80,
    notches: @[NotchFilter(hz: 50, widthHz: 4)], dc: dcMean)

  block filtered:
    st.process(pr)
    doAssert st.panel(MainPanel).layers[0].processing == pr
    doAssert st.tiles(0).len > 0, "the tiles from before are drawn until the new one comes"
    doAssert st.settle(st.answered)
    let t = st.tiles(0)[^1]
    doAssert t.request.stride == 1 and t.request.decimation == 1, $t.request
    doAssert t.filtered == t.request.count, $t.filtered & " traces filtered of " &
      $t.request.count
    t.sameAs(expected(path, t, lay.dtMs, pr), "band-pass and notch")
    var differs = false
    for i in 0 ..< t.data.len:
      if t.data[i] != recorded.data[i]: differs = true
    doAssert differs, "the filtered tile holds what the file holds"

  block moved:
    # zoomed in time, where the filters' margin decides what is decoded:
    # a narrower low-cut ramp has a longer one
    var v = st.panel(MainPanel).view
    v.timeMs = Span(lo: 300, hi: 400)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert st.settle(st.answered)
    # the next record, read from the file as zoomed (the same scales)
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
    doAssert st.settle(st.panel(MainPanel).laidOut and st.answered and
      st.panel(MainPanel).view.timeMs == v.timeMs)
    doAssert not st.tiles(0)[^1].cached
    resetCounts()
    (pr.f1, pr.f4) = (7.0, 95.0)
    st.process(pr)
    doAssert st.settle(st.answered)
    let t = st.tiles(0)[^1]
    doAssert t.request.firstSample > 0, $t.request
    doAssert t.cached and t.chunks == 0, "f1 and f4 moved: the tile was read from the file (" &
      $t.chunks & " reads)"
    doAssert calls(foMapped, path) == 0, "f1 and f4 moved: the file was read"
    t.sameAs(expected(path, t, lay.dtMs, pr), "f1 at 7, f4 at 95 Hz")
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 0)
    doAssert st.settle(st.panel(MainPanel).laidOut and st.answered)
    st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 640, 2 * lay.samples))
    doAssert st.settle(st.answered)

  block hungDrive:
    fault(path, fkHang)
    pr.f1 = 2
    st.process(pr)
    doAssert st.settle(st.answered), "no tile while the drive does not answer"
    doAssert st.tiles(0)[^1].cached
    st.tiles(0)[^1].sameAs(expected(path, st.tiles(0)[^1], lay.dtMs, pr), "f1 at 2 Hz")
    fault(path, fkNone)
    releaseAll()

  block raw:
    var r = pr
    r.raw = true
    st.process(r)
    doAssert st.settle(st.answered)
    let t = st.tiles(0)[^1]
    doAssert t.filtered == 0 and t.data == recorded.data, "raw is not as recorded"
    st.process(pr)
    doAssert st.settle(st.answered)
    st.tiles(0)[^1].sameAs(expected(path, st.tiles(0)[^1], lay.dtMs, pr), "processed again")

  block bounded:
    var b = Processing(band: pbBandPass, f1: 30, f2: 10, f3: 5, f4: 1e9, notches: @[
      NotchFilter(hz: -1, widthHz: 0, harmonics: 99)])
    st.process(b)
    let got = st.panel(MainPanel).layers[0].processing
    doAssert got.f1 == 30 and got.f2 > got.f1 and got.f3 >= got.f2 and got.f4 > got.f3 and
      got.f4 <= MaxFilterHz, $got
    doAssert got.notches[0].hz > 0 and got.notches[0].widthHz > 0 and
      got.notches[0].harmonics == MaxHarmonics, $got.notches
    # past Nyquist (250 Hz at 2 ms): the high side is ended there, said, and
    # the filter still runs
    b = Processing(band: pbBandPass, f1: 4, f2: 8, f3: 200, f4: 400,
      notches: @[NotchFilter(hz: 60, harmonics: 5)])
    doAssert b.limitNote(lay.dtMs).len > 0
    let flow = b.filterPipeline(lay.dtMs)
    doAssert flow.len == 1
    discard flow.compile(float32, lay.dtMs, lay.samples) # within Nyquist: compiles
    st.process(b)
    doAssert st.settle(st.answered)
    doAssert st.tiles(0)[^1].filtered > 0
    st.process(pr)
    doAssert st.settle(st.answered)

  block nextGather:
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
    doAssert st.settle(st.panel(MainPanel).laidOut and st.answered)
    doAssert st.panel(MainPanel).layers[0].processing == pr, "the next gather is not filtered"
    let t = st.tiles(0)[^1]
    doAssert t.filtered == t.request.count
    t.sameAs(expected(path, t, lay.dtMs, pr), "the next gather")

  block remembered:
    doAssert st.settings.plot.processing == pr
    var r = pr
    r.raw = true
    st.process(r)
    doAssert not st.settings.plot.processing.raw, "raw was kept for a new plot"
    st.apply Command(kind: ckClose, file: st.sessions[0].id)
    doAssert st.settle(st.sessions.len == 0)
    st.apply Command(kind: ckOpen, paths: @[path])
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    doAssert st.panel(MainPanel).layers[0].processing == pr, "a new plot starts with " &
      $st.panel(MainPanel).layers[0].processing
  st.shutdown()
  doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"

  block zoom:
    # Only the view's traces: a whole record of 20 000 traces filters no
    # more than the plot has pixels, a zoomed view fewer (the 101 traces in
    # view and a view and a half more on each side, read ahead).
    let many = fx.manyTracesSegy(20_000, samples = 64)
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[many])
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    st.showAll()
    st.process(Processing(band: pbBandPass, f1: 4, f2: 8, f3: 60, f4: 80))
    doAssert st.settle(st.answered)
    let whole = st.tiles(0)[^1]
    doAssert whole.filtered == whole.request.count and whole.filtered <= 2 * 640,
      $whole.filtered & " traces filtered for a view 640 pixels wide"
    var v = st.panel(MainPanel).view
    v.traces = Span(lo: 1000, hi: 1100)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert st.settle(st.answered)
    let zoomed = st.tiles(0)[^1]
    doAssert zoomed.filtered == zoomed.request.count and zoomed.filtered < whole.filtered and
      zoomed.filtered <= 101 * 4 + 1, $zoomed.filtered & " traces filtered for 100 in view"
    echo "tprocessing: traces filtered: ", whole.filtered, " for the whole record, ",
      zoomed.filtered, " zoomed to 100"
    # A slider dragged: a change every few ms, nothing else between. The plot
    # follows (tiles of changes already replaced are drawn as they come),
    # and after the first change each asks for the view alone.
    var f2 = 8.0
    var seen = zoomed.id
    var drawn: seq[Tile]
    let until = getTime() + initDuration(seconds = 3)
    while getTime() < until:
      f2 += 0.05
      st.process(Processing(band: pbBandPass, f1: 4, f2: f2, f3: 60, f4: 80))
      discard st.drainInbox()
      if st.tiles(0).len > 0 and st.tiles(0)[^1].id != seen:
        seen = st.tiles(0)[^1].id
        drawn.add st.tiles(0)[^1]
      sleep 2
    doAssert drawn.len >= 3, $drawn.len & " tiles drawn while the filters changed"
    for t in drawn[1 .. ^1]:
      doAssert t.request.count <= 102 and t.filtered == t.request.count and t.cached,
        "a tile of the run: " & $t.request.count & " traces, " & $t.filtered & " filtered"
    doAssert st.settle(st.answered)
    # the next view brings the read-ahead back
    v.traces = Span(lo: 1010, hi: 1110)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert st.settle(st.answered)
    doAssert st.tiles(0)[^1].request.count > 300, $st.tiles(0)[^1].request.count
    echo "tprocessing: ", drawn.len, " tiles drawn in 3 s of changes"
    st.shutdown()

  block aux:
    let segd = fx.threeComponentSegd() # a time break, then 36 seismic traces
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[segd])
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    st.apply Command(kind: ckFilter, panel: MainPanel, filter: TraceFilter(seismic: true,
      auxiliary: true))
    doAssert st.settle(st.panel(MainPanel).laidOut and st.panel(MainPanel).layout.traces == 37)
    st.showAll()
    let dt = st.panel(MainPanel).layout.dtMs
    let asRecorded = st.tiles(0)[^1]
    var p = Processing(band: pbLowCut, f1: 2, f2: 6)
    st.process(p)
    doAssert st.settle(st.answered)
    var t = st.tiles(0)[^1]
    doAssert t.keys[0].status == tsAuxiliary
    for j in 0 ..< t.columns:
      doAssert t.data[j] == asRecorded.data[j], "the time break is filtered with Aux off"
    t.sameAs(expected(segd, t, dt, p), "Aux off")
    p.aux = true
    st.process(p)
    doAssert st.settle(st.answered)
    t = st.tiles(0)[^1]
    var changed = false
    for j in 0 ..< t.columns:
      if t.data[j] != asRecorded.data[j]: changed = true
    doAssert changed, "the time break is not filtered with Aux on"
    t.sameAs(expected(segd, t, dt, p, aux = true), "Aux on")
    # the time break alone: its level is its own (no seismic trace to take
    # one from), so the plot draws it
    st.apply Command(kind: ckFilter, panel: MainPanel, filter: TraceFilter(seismic: false,
      auxiliary: true))
    doAssert st.settle(st.panel(MainPanel).laidOut and st.panel(MainPanel).layout.traces == 1)
    st.showAll()
    let lvl = st.panel(MainPanel).level
    doAssert lvl.clip > 0 and lvl.peak > 0, "no level for the auxiliary trace alone: " & $lvl
    st.shutdown()
  block settingsFile:
    var s = Settings()
    s.plot.processing = Processing(aux: true, dc: dcTrend, band: pbHighCut, f1: 1, f2: 3,
      f3: 90, f4: 120.5, notches: @[NotchFilter(hz: 50, widthHz: 1.5, harmonics: 4),
      NotchFilter(on: false, hz: 16.7)])
    let doc = settingsDocument(s)
    doAssert "(processing" in doc and "(band highCut)" in doc, doc
    var problems: seq[string]
    let back = readSettings(doc, "settings.nif", Settings(), problems)
    doAssert problems.len == 0, $problems
    doAssert back.plot.processing == s.plot.processing, $back.plot.processing
    # a value it cannot use keeps that one setting, and says so
    let bad = doc.replace("(f3 90.0)", "(f3 \"loud\")").replace("(band highCut)", "(band x)")
    let read = readSettings(bad, "settings.nif", Settings(), problems)
    doAssert problems.len == 2, $problems
    doAssert read.plot.processing.f3 == Processing().f3 and
      read.plot.processing.band == pbNone and read.plot.processing.f4 == 120.5
  doAssert uiCalls().len == 0, $uiCalls()
  echo "tprocessing: passed"
