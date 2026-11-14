## A trace panel's reader, driven through the application state on fixture
## files: showing a gather holds the file and posts its layout; a view gets
## a tile with the file's exact samples and the display header's values; a
## zoomed-out view reads every n-th trace and keeps peak-decimated samples; a
## pre-stack gather is shown with AGC by default, decoded with its margin;
## auxiliary traces are left out; a pan inside the read-ahead reads nothing,
## a pan past it reads again; tiles answering an older request are dropped;
## the reader lets go of a file it no longer shows, so a close completes;
## and the files are never changed.
##
## Seen to fail: with `drainInbox` taking in tiles of any generation,
## `staleTilesAreDropped` kept the old one; with the reader not ending its
## hold in `letGo`, `rawSamplesOnScreen` still found the file held after shutdown;
## with the trace filter keeping auxiliary traces, `auxiliaryTracesLeftOut`
## found 26 positions; with the panel requesting on every view,
## `panInsideTheReadAhead` saw the request generation move.

import std/[algorithm, math, os, sequtils, strutils, times]
import parseSEG
import viewSEG/core/state {.all.}
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  ## Takes in the inbox every millisecond until `cond` holds.
  waitUntil((discard st.drainInbox(); cond))

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

proc openCmd(path: string): Command = Command(kind: ckOpen, paths: @[path])

func has(log: MessageLog; part: string): bool =
  for e in log:
    if part in e.text: return true
  false

proc main(st: AppState): lent Panel = st.panel(MainPanel)

proc shown(st: AppState): lent seq[Tile] = st.tiles(st.findPanel(MainPanel))

proc setGain(st: var AppState; gain: DisplayGain) =
  var d = st.main.layers[0].display
  d.gain = gain
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)

proc look(st: var AppState; columns = 800; rows = 600) =
  ## The whole gather on a plot of `columns` × `rows` pixels.
  st.apply Command(kind: ckView, panel: MainPanel,
    view: fitAll(st.main.layout, columns, rows))

proc lookAt(st: var AppState; first, last: float64; columns = 800; rows = 600) =
  ## Positions `first .. last`, all samples.
  var v = fitAll(st.main.layout, columns, rows)
  v.traces = Span(lo: first - 0.5, hi: last + 0.5)
  st.apply Command(kind: ckView, panel: MainPanel, view: v)

func percentile99(t: Tile): float64 =
  var a: seq[float32]
  for v in t.data: a.add abs(v)
  a.sort
  a[int(0.99 * float64(a.len - 1))]

block rawSamplesOnScreen:
  withFixtures fx:
    let path = fx.surveySegy()
    let before = snapshot(path)
    var st = initAppState()
    st.apply openCmd(path)
    doAssert st.settle(st.main.layout.traces > 0)
    doAssert st.main.layout == PanelLayout(traces: Channels, samples: Samples, dtMs: DtMs,
      t0Ms: 0), $st.main.layout
    doAssert st.main.fits == 1
    doAssert st.jobs.held(path) == 1, "the panel holds the file it shows"
    doAssert st.main.shownFields == @[hfRecord, hfChannel], $st.main.shownFields
    st.setGain(dgNone) # the samples as they are, for an exact comparison
    st.look()
    doAssert st.settle(st.shown.len == 1)
    let t = st.shown[0]
    let r = t.request
    doAssert r.gen == st.main.requestGen and r == st.main.pending
    doAssert r.first == 0 and r.count == Channels and r.stride == 1, $r
    doAssert r.firstSample == 0 and r.samples == Samples and r.decimation == 1 and
      r.margin == 0, $r
    doAssert t.columns == Samples and t.data.len == Channels * Samples and t.failed == 0
    for row in 0 ..< Channels:
      for i in 0 ..< Samples:
        doAssert t.data[row * Samples + i] == surveySample(0, row + 1, i),
          "trace " & $row & " sample " & $i
    doAssert t.fields == @[hfRecord, hfChannel]
    for row in 0 ..< Channels:
      doAssert t.header[0][row] == float64(FirstRecord) and t.header[1][row] == float64(row + 1)
    let want = t.percentile99
    doAssert abs(t.clip - want) <= 0.01 * want, "clip " & $t.clip & ", want " & $want
    doAssert st.main.clip == t.clip
    doAssert t.id > 0
    doAssert st.log.count(sevWarning) == 0 and st.log.count(sevError) == 0
    st.shutdown()
    doAssert st.jobs.held(path) == 0, "the reader let go of the file when it stopped"
    doAssert snapshot(path) == before, "reading changed the file"

block zoomedOut:
  # 24 traces on 6 columns: every 4th; 500 samples on 100 rows: peaks of 4.
  withFixtures fx:
    var st = initAppState()
    st.apply openCmd(fx.surveySegy())
    doAssert st.settle(st.main.layout.traces > 0)
    st.setGain(dgNone)
    st.look(columns = 6, rows = 100)
    doAssert st.settle(st.shown.len == 1)
    let t = st.shown[0]
    let r = t.request
    doAssert r.stride == 4 and r.count == 6 and r.count <= 6, $r
    doAssert r.decimation == 4 and t.columns == 125, $r
    var bin: array[4, float32]
    for row in 0 ..< r.count:
      let channel = r.position(row) + 1
      for c in 0 ..< t.columns:
        for k in 0 ..< 4: bin[k] = surveySample(0, channel, 4 * c + k)
        var peak = 0'f32
        for v in bin:
          if abs(v) > abs(peak): peak = v
        doAssert t.data[row * t.columns + c] == peak, "row " & $row & " column " & $c
    st.shutdown()

block agcOnShotsByDefault:
  withFixtures fx:
    var st = initAppState()
    st.apply openCmd(fx.surveySegy())
    doAssert st.settle(st.main.layout.traces > 0)
    doAssert st.main.layers[0].display.gain == dgAuto
    doAssert st.main.layers[0].display.effectiveGain(gkShot) == dgAgc
    st.look()
    doAssert st.settle(st.shown.len == 1)
    let t = st.shown[0]
    doAssert t.request.margin == 125, "half of a 500 ms window at 2 ms: " & $t.request
    var peak = 0'f32
    for v in t.data:
      doAssert v.classify in {fcNormal, fcSubnormal, fcZero, fcNegZero}
      peak = max(peak, abs(v))
    # the raw peak is 1; AGC lifts the events well above the window's RMS
    doAssert peak > 1.5 and t.clip > 0, "peak " & $peak & ", clip " & $t.clip
    st.shutdown()

block auxiliaryTracesLeftOut:
  withFixtures fx:
    var st = initAppState()
    st.apply openCmd(fx.twoSetSegd())
    doAssert st.settle(st.main.layout.traces > 0)
    doAssert st.main.layout.traces == 2 * SegdChannels, $st.main.layout
    doAssert st.main.shownFields == @[hfRcvLine, hfRcvPoint], $st.main.shownFields
    st.setGain(dgNone)
    st.look()
    doAssert st.settle(st.shown.len == 1)
    let t = st.shown[0]
    for row in 0 ..< t.request.count:
      let line = RcvLine + float64(row div SegdChannels)
      let channel = float64(row mod SegdChannels + 1)
      doAssert t.header[0][row] == line and t.header[1][row] == FirstRcvPoint + channel - 1
      for i in 0 ..< SegdSamples:
        doAssert t.data[row * t.columns + i] == segdSample(1, line, channel, i),
          "row " & $row & " sample " & $i
    st.shutdown()

block panInsideTheReadAhead:
  withFixtures fx:
    var st = initAppState()
    st.apply openCmd(fx.surveySegy())
    doAssert st.settle(st.main.layout.traces > 0)
    st.lookAt(8, 11) # 4 traces; 2 more on each side are read
    let gen = st.main.requestGen
    let r = st.main.pending
    doAssert r.first == 6 and r.last == 13, $r
    st.lookAt(9, 12)
    st.lookAt(7, 10)
    doAssert st.main.requestGen == gen, "a pan inside the read-ahead read again"
    st.lookAt(14, 17)
    doAssert st.main.requestGen > gen, "a pan past the read-ahead read nothing"
    # a burst of views: only the newest is answered
    for first in 0 .. 15:
      st.lookAt(float64(first), float64(first + 3))
    let last = st.main.pending
    doAssert st.settle(st.shown.len > 0 and st.shown[^1].request == last)
    var ids: seq[uint64]
    for t in st.shown:
      doAssert t.request.gen <= last.gen
      ids.add t.id
    doAssert ids.sorted == ids and ids.deduplicate.len == ids.len
    doAssert st.shown.len <= MaxTiles
    st.shutdown()

block staleTilesAreDropped:
  withFixtures fx:
    var st = initAppState()
    st.apply openCmd(fx.surveySegy())
    doAssert st.settle(st.main.layout.traces > 0)
    st.look()
    doAssert st.settle(st.shown.len == 1)
    let gen = st.main.requestGen
    let poster = st.mailbox
    let req = ReadRequest(gen: gen - 1, count: 1, stride: 1, samples: 1, decimation: 1)
    poster.post Msg(job: NoJob, kind: mkTile, tile: Tile(panel: MainPanel, request: req,
      columns: 1, data: @[1'f32]))
    discard st.drainInbox()
    doAssert st.shown.len == 1, "a tile of an older request was taken in"
    var fresh = req
    fresh.gen = gen
    poster.post Msg(job: NoJob, kind: mkTile, tile: Tile(panel: MainPanel, request: fresh,
      columns: 1, data: @[1'f32]))
    poster.post Msg(job: NoJob, kind: mkLayout, panel: MainPanel,
      sourceGen: st.main.sourceGen - 1, layout: PanelLayout(traces: 3))
    discard st.drainInbox()
    doAssert st.shown.len == 2 and st.shown[1].request == fresh
    doAssert st.main.layout.traces == Channels, "a layout of an older source was taken in"
    st.shutdown()

block holdsFollowTheShownFile:
  withFixtures fx:
    let path = fx.surveySegy()
    let name = path.extractFilename
    var st = initAppState()
    st.apply openCmd(path)
    doAssert st.settle(st.main.layout.traces > 0)
    st.look()
    doAssert st.settle(st.shown.len == 1)
    let first = st.main.sourceGen
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
    doAssert st.shown.len == 0 and st.main.layout.traces == 0, "the old gather's tiles stay"
    doAssert st.settle(st.main.layout.traces > 0 and st.main.sourceGen > first)
    doAssert st.settle(st.jobs.held(path) == 1), $st.jobs.held(path) & " holds"
    st.apply Command(kind: ckClose, file: st.sessions[0].id)
    doAssert st.settle(st.log.has("Closed " & name & "."))
    doAssert st.jobs.held(path) == 0
    doAssert st.main.layout.traces == 0
    st.shutdown()
