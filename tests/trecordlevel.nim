## The record's level (the amplitude the gain draws at full scale) is the
## record's whatever the view, in `core`, without a window: on a record
## whose last 10 traces are 10 times as loud in their last 100 samples, the same
## steps (a clip percentile of 98, back to 99, the loudest trace killed, a
## band-pass) taken zoomed into that loud corner and with the whole record
## in view give the same level, the record's, each time: taken over what
## the record's first view read, not over the view's tile.
##
## Seen to fail: with the level taken from the first tile after a change
## (the view's, as it was), "clip 98: zoomed 18.92659375, the whole record
## 1.91795" (~10 times too bright).

import std/[math, os]
import parseSEG
import viewSEG/core/[edits, processing, state, zoom]
import utils/[fixtures, waiting]

const
  Traces = 200
  Samples = 1000
  Loud = 190     ## the first loud trace
  LoudFrom = 900 ## its first loud sample

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc answered(st: AppState): bool =
  let p = st.panel(MainPanel)
  not p.pending.isEmpty and st.tiles(0).len > 0 and st.tiles(0)[^1].request == p.pending

proc levelled(st: AppState): bool = st.answered and not st.panel(MainPanel).relevel

proc why(st: AppState): string =
  "answered " & $st.answered & ", relevel " & $st.panel(MainPanel).relevel

proc loudCorner(fx: Fixtures): string =
  result = fx.dir / "loud-corner.sgy"
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: a loud corner"]))
  var buf = newSeq[float32](Samples)
  for k in 0 ..< Traces:
    for i in 0 ..< Samples:
      let loud = if k >= Loud and i >= LoudFrom: 10.0 else: 1.0
      buf[i] = float32(loud * (1 + k / Traces) * sin(2 * PI * 25 * float64(i) * 0.002))
    var keys = initTraceKeys()
    (keys.record, keys.channel, keys.t0Ms, keys.intervalUs, keys.status) = (1.0,
      float64(k + 1), 0.0, 2000.0, tsLive)
    w.writeTrace(keys, buf)
  doAssert w.close().len == 0

proc steps(path: string; zoomed: bool): seq[(string, float64)] =
  ## The panel's level after each step, zoomed into the loud corner or not.
  var st = initAppState()
  st.apply Command(kind: ckOpen, paths: @[path])
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  var d = st.panel(MainPanel).layers[0].display
  (d.gain, d.mode) = (dgNone, dmDensity)
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
  var v = fitAll(st.panel(MainPanel).layout, 400, 300)
  st.apply Command(kind: ckView, panel: MainPanel, view: v)
  doAssert st.settle(st.levelled)
  result.add ("open", st.panel(MainPanel).level.clip)
  if zoomed:
    v.traces = Span(lo: float64(Loud), hi: float64(Traces))
    v.timeMs = Span(lo: 2 * LoudFrom, hi: 2 * Samples)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert st.settle(st.levelled)
  template step(name: string; cmd: Command) =
    st.apply cmd
    doAssert st.settle(st.levelled), name & ": not levelled (" & st.why & ")"
    result.add (name, st.panel(MainPanel).level.clip)
  d.clipPercentile = 98
  step("clip 98", Command(kind: ckDisplay, panel: MainPanel, display: d))
  d.clipPercentile = 99
  step("clip 99", Command(kind: ckDisplay, panel: MainPanel, display: d))
  step("kill", Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
    edited: @[st.sessions[0].base + Traces - 1], on: true))
  step("band-pass", Command(kind: ckProcessing, panel: MainPanel,
    processing: Processing(band: pbBandPass, f1: 5, f2: 10, f3: 40, f4: 60)))
  discard st.shutdown()

withFixtures fx:
  let path = fx.loudCorner()
  let whole = steps(path, zoomed = false)
  let zoomed = steps(path, zoomed = true)
  for i in 0 ..< whole.len:
    let (name, want) = whole[i]
    let got = zoomed[i][1]
    echo "trecordlevel: ", name, ": zoomed ", got, ", the whole record ", want
    doAssert abs(got - want) <= 1e-6 * abs(want), name & ": zoomed " & $got &
      ", the whole record " & $want
  doAssert whole[1][1] < whole[0][1] and whole[2][1] == whole[0][1], $whole
  echo "trecordlevel: ok"
