## The pick: a screen point of a trace panel to the trace drawn there, its
## nearest sample, time and displayed value, and its keys. At the edges of
## tiles (first and last trace, first and last column, just past them), with
## the newest of overlapping tiles winning, and on a fixture gather read
## through the panel's reader at three zoom levels (the whole gather, zoomed
## out to every 4th trace in bins of 4 samples, zoomed in), where every
## point of a grid must name the trace the tile draws there and its exact
## sample value.
##
## Seen to fail: with `rowAt` leaving out the half cell before the first
## trace, `tileEdges` named position 4 at x 5.0 (row 1, position 6, covers
## 5 .. 7); with `pickAt` taking the oldest tile, `newestTileWins` read the
## value drawn underneath; with the column found by rounding down instead of
## to the nearest, `tileEdges` read column 0 at 138.1 ms.

import std/math
import parseSEG
import viewSEG/core/[geometry, state]
import utils/[fixtures, waiting]

proc keysOf(channel: int): TraceKeys =
  result = initTraceKeys()
  result.channel = float64(channel)
  result.record = 7

proc testTile(value = 0'f32): Tile =
  ## 6 traces of 9 columns: every 2nd position from 4 (x 3 .. 15), samples
  ## 8 .. 25 in bins of 2, at 4 ms from 100 ms (130 .. 202 ms).
  let r = ReadRequest(first: 4, count: 6, stride: 2, firstSample: 8, samples: 18,
    decimation: 2)
  result = Tile(request: r, dtMs: 4, t0Ms: 100, columns: r.columns)
  for row in 0 ..< r.count:
    result.traces.add 1000 + r.position(row)
    result.keys.add keysOf(r.position(row) + 1)
    for c in 0 ..< result.columns:
      result.data.add value + float32(row * 10 + c)

const layout = PanelLayout(traces: 20, samples: 40, dtMs: 4, t0Ms: 100)

block tileEdges:
  let t = testTile()
  let (xs, ts) = t.span
  doAssert xs == Span(lo: 3, hi: 15) and ts == Span(lo: 130, hi: 202), $xs & " " & $ts
  let tiles = [t]
  # the first trace from the tile's left edge, the last up to its right edge
  var p = pickAt(tiles, layout, DataPoint(x: 3, tMs: 134))
  doAssert p.found and p.position == 4 and p.trace == 1004 and p.keys.channel == 5
  doAssert p.amplitude == 0 and p.binned == 2
  # row 1 (position 6) covers 5 .. 7
  for x in [5.0, 5.2, 6.9]:
    p = pickAt(tiles, layout, DataPoint(x: x, tMs: 134))
    doAssert p.position == 6 and p.amplitude == 10, $x & ": position " & $p.position
  doAssert pickAt(tiles, layout, DataPoint(x: 4.99, tMs: 134)).position == 4
  p = pickAt(tiles, layout, DataPoint(x: 15 - 1e-9, tMs: 134))
  doAssert p.found and p.position == 14 and p.amplitude == 50
  # past the right edge: no trace there
  p = pickAt(tiles, layout, DataPoint(x: 15, tMs: 134))
  doAssert not p.found and p.position == -1 and p.trace == -1 and p.amplitude.isNaN
  doAssert p.keys.channel.isNaN and p.keys.record.isNaN
  p = pickAt(tiles, layout, DataPoint(x: 3 - 1e-9, tMs: 134))
  doAssert not p.found
  # the first and last columns, to the tile's top and bottom edges
  doAssert pickAt(tiles, layout, DataPoint(x: 4, tMs: 130)).amplitude == 0
  doAssert pickAt(tiles, layout, DataPoint(x: 4, tMs: 137.9)).amplitude == 0
  doAssert pickAt(tiles, layout, DataPoint(x: 4, tMs: 138.1)).amplitude == 1
  doAssert pickAt(tiles, layout, DataPoint(x: 4, tMs: 202 - 1e-9)).amplitude == 8
  # above or below the tile: the trace is known, its value is not held
  for tMs in [129.9, 202.0, 900.0]:
    p = pickAt(tiles, layout, DataPoint(x: 4, tMs: tMs))
    doAssert p.found and p.position == 4 and p.amplitude.isNaN, $tMs
  # the nearest sample of the record, and none past its ends
  doAssert pickAt(tiles, layout, DataPoint(x: 4, tMs: 100)).sample == 0
  doAssert pickAt(tiles, layout, DataPoint(x: 4, tMs: 101.9)).sample == 0
  doAssert pickAt(tiles, layout, DataPoint(x: 4, tMs: 102.1)).sample == 1
  doAssert pickAt(tiles, layout, DataPoint(x: 4, tMs: 256)).sample == 39
  doAssert pickAt(tiles, layout, DataPoint(x: 4, tMs: 258.1)).sample == -1
  doAssert pickAt(tiles, layout, DataPoint(x: 4, tMs: 97.9)).sample == -1
  # nothing to pick from
  p = pickAt([], layout, DataPoint(x: 4, tMs: 134))
  doAssert not p.found and p.sample == 9 and p.amplitude.isNaN

block newestTileWins:
  let old = testTile(value = 1000)
  var fresh = testTile(value = 2000)
  fresh.keys[0].channel = 99
  let p = pickAt([old, fresh], layout, DataPoint(x: 4, tMs: 134))
  doAssert p.amplitude == 2000 and p.keys.channel == 99
  # where only the older one reaches, it answers
  var narrow = testTile(value = 3000)
  narrow.request.count = 2 # positions 4 and 6 only
  narrow.data.setLen 2 * narrow.columns
  let q = pickAt([old, narrow], layout, DataPoint(x: 12, tMs: 134))
  doAssert q.amplitude == 1040 and q.position == 12

block screenPoints:
  let v = Viewport(traces: Span(lo: 2.5, hi: 16.5), timeMs: Span(lo: 100, hi: 240),
    columns: 140, rows: 70)
  let plot = Rect(pos: vec2(20, 10), size: vec2(140, 70))
  let tiles = [testTile()]
  doAssert not pick(tiles, layout, v, plot, vec2(19, 40)).inside
  doAssert not pick(tiles, layout, v, plot, vec2(160, 40)).inside
  doAssert not pick(tiles, layout, v, Rect(), vec2(0, 0)).inside
  let p = pick(tiles, layout, v, plot, vec2(20 + 15, 10 + 17))             # x 4.0, 134 ms
  doAssert p.inside and p.found and p.position == 4 and abs(p.at.x - 4) < 1e-9 and
    abs(p.at.tMs - 134) < 1e-9, $p.at

# ------------------------------------------------- a fixture, three zooms --

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc main(st: AppState): lent Panel = st.panel(MainPanel)

proc newest(st: AppState): Tile = st.tiles(st.findPanel(MainPanel))[^1]

proc answered(st: AppState): bool =
  let tiles = st.tiles(st.findPanel(MainPanel))
  tiles.len > 0 and tiles[^1].request == st.main.pending

func peakOf(channel, first, n: int): float32 =
  for i in first ..< min(first + n, Samples):
    let v = surveySample(0, channel, i)
    if abs(v) > abs(result): result = v

block fixtureAtThreeZooms:
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.surveySegy()])
    doAssert st.settle(st.main.layout.traces > 0)
    var d = st.main.layers[0].display
    d.gain = dgNone # the samples as they are
    st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    let lay = st.main.layout
    let whole = fitAll(lay, 800, 600)
    var zoomedIn = whole
    zoomedIn.traces = Span(lo: 4.5, hi: 15.5)
    zoomedIn.timeMs = Span(lo: 100, hi: 300)
    for (name, view) in [("whole", whole), ("zoomed out", fitAll(lay, 6, 100)),
        ("zoomed in", zoomedIn)]:
      st.apply Command(kind: ckView, panel: MainPanel, view: view)
      doAssert st.settle(st.answered), name & ": no tile"
      let t = st.newest
      let r = t.request
      let plot = Rect(pos: vec2(40, 25), size: vec2(float32(view.columns),
        float32(view.rows)))
      var looked, off = 0
      for gy in 0 .. 40:
        for gx in 0 .. 40:
          let at = vec2(plot.pos.x + plot.size.x * (float32(gx) + 0.5) / 41,
            plot.pos.y + plot.size.y * (float32(gy) + 0.5) / 41)
          let p = pick(st.tiles(st.findPanel(MainPanel)), lay, view, plot, at)
          doAssert p.inside and p.found, name & ": nothing at " & $at
          # Zoomed out, the strip right of the last trace read (a multiple of
          # the stride) still shows an older tile: the pick names its trace.
          if not t.contains(p.at.x, p.at.tMs):
            doAssert p.at.x >= t.span[0].hi and p.position > r.last, name & " at " & $p.at
          else:
            inc looked
            let row = t.rowAt(p.at.x)
            let channel = r.position(row) + 1
            let c = clamp(int(round((p.at.tMs - t.timeOf(0)) / (float64(r.decimation) *
              DtMs))), 0, t.columns - 1)
            let want = if r.decimation == 1: surveySample(0, channel, r.firstSample + c)
                       else: peakOf(channel, r.firstSample + c * r.decimation, r.decimation)
            if p.position != r.position(row) or p.trace != p.position or
                p.keys.channel != float64(channel) or p.keys.record != float64(FirstRecord) or
                p.amplitude != want or p.binned != r.decimation:
              if off < 3:
                echo "  ", name, " at ", p.at, ": position ", p.position, " trace ", p.trace,
                  " channel ", p.keys.channel, " value ", p.amplitude, ", want ", want
              inc off
            if r.decimation == 1:
              doAssert p.sample == int(round(p.at.tMs / DtMs)), name & ": sample " & $p.sample
      echo "tpick: ", name, " (stride ", r.stride, ", bins of ", r.decimation, "): ", looked,
        " points, ", off, " off"
      doAssert off == 0, name & ": " & $off & " of " & $looked & " points picked wrong"
      # the tile's own edges: its first and last traces
      let (xs, _) = t.span
      let tMid = (view.timeMs.lo + view.timeMs.hi) / 2
      doAssert pickAt([t], lay, DataPoint(x: xs.lo, tMs: tMid)).position == r.first
      doAssert pickAt([t], lay, DataPoint(x: xs.hi - 1e-9, tMs: tMid)).position == r.last
      doAssert not pickAt([t], lay, DataPoint(x: xs.hi, tMs: tMid)).found or
        r.last + r.stride < lay.traces
    doAssert st.log.count(sevError) == 0, $st.log.count(sevError) & " errors"
    st.shutdown()
