## Sorting a panel's traces: the sort buttons' orders as data (Line/Station,
## By Flag, By Component), the sorting kernel on known keys (each key
## ascending or descending, unknown values last either way, ties in the
## order given, a stop between runs), and each button through the
## application state on fixture records whose order is known: the tile's
## traces, the display header's values and the pick at every position follow
## the sorted order; a view inside the gather reads only its own traces in
## that order; the view stays where it was; the old order stays drawn until
## the new one comes, then is dropped; the order carries over to the next
## gather; a newer order wins over one being sorted; the file's order comes
## back with no keys; and the files are never changed.
##
## The expected orders are worked out here with std/algorithm's (stable)
## merge sort over each trace's keys, not with parseSEG's radix sort.
##
## Seen to fail: with `arrange` keeping the file's order instead of the
## sorted list, `buttonsOnTheMixedRecord` found Line/Station's tile holding
## traces 1, 2, 3 ...; with the reader not sorting a new source in the
## layer's order (`adopt` without `arrange`), `orderCarriesOverAndNewestWins`
## found gather 1 in the file's order; with a descending key not negated in
## `sortRowsInto`, `kernelOnKnownKeys` found the offsets ascending; with
## `drainInbox` keeping the tiles of the old order, `oldOrderDropped` found
## 3 tiles kept, two in the old order; with By Flag's keys given as line and
## point only, `presetsAreTheUsersOrders` failed.
##
## Runs alone: it measures the time the sort command and the sorted tile take.

import std/[algorithm, math, os, sequtils, strutils, times]
import parseSEG
import viewSEG/core/[sorting, state]
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

proc main(st: AppState): lent Panel = st.panel(MainPanel)

proc shown(st: AppState): lent seq[Tile] = st.tiles(st.findPanel(MainPanel))

proc answered(st: AppState): bool =
  ## The newest tile answers the newest request.
  let p = st.main
  not p.pending.isEmpty and p.pending.gen == p.requestGen and st.shown.len > 0 and
    st.shown[^1].request == p.pending

proc sortBy(st: var AppState; order: seq[SortKey]) =
  st.apply Command(kind: ckSort, panel: MainPanel, order: order)

proc look(st: var AppState; first, last: float64; columns = 800; rows = 600) =
  ## Positions `first .. last`, all samples.
  var v = fitAll(st.main.layout, columns, rows)
  v.traces = Span(lo: first - 0.5, hi: last + 0.5)
  st.apply Command(kind: ckView, panel: MainPanel, view: v)

func same(a, b: float64): bool = a == b or (a.isNaN and b.isNaN)

func key(f: HeaderField; descending = false): SortKey = SortKey(field: f, descending: descending)

func preset(name: string): seq[SortKey] =
  for s in SortPresets:
    if s.name == name: return s.keys
  raise newException(KeyError, "no preset " & name)

proc expected(f: SeismicFile; traces: seq[int]; order: openArray[SortKey]): seq[int] =
  ## `traces` sorted by `order` with a stable comparison sort: the oracle.
  var rows = traces.mapIt((trace: it, keys: f.traceKeys(it)))
  let keys = @order
  proc cmpKeys(a, b: tuple[trace: int; keys: TraceKeys]): int =
    for k in keys:
      var (x, y) = (a.keys.value(k.field, a.trace), b.keys.value(k.field, b.trace))
      if k.descending: (x, y) = (-x, -y)
      let c = if x.isNaN and y.isNaN: 0 elif x.isNaN: 1 elif y.isNaN: -1 else: cmp(x, y)
      if c != 0: return c
    0
  rows.sort(cmpKeys) # merge sort: stable
  rows.mapIt(it.trace)

proc checkShown(st: AppState; f: SeismicFile; want: seq[int]; what: string) =
  ## The newest tile holds `want` at positions `first ..`, its display
  ## header's values and the pick at each of them agree.
  let t = st.shown[^1]
  let r = t.request
  doAssert r.stride == 1, what & ": " & $r
  doAssert t.traces == want[r.first .. r.last], what & ": traces " & $t.traces & ", want " &
    $want[r.first .. r.last]
  for row, trace in t.traces:
    let k = f.traceKeys(trace)
    for i, field in t.fields:
      let v = k.value(field, trace)
      doAssert same(t.header[i][row], v), what & ": " & $field & " at row " & $row
    let at = DataPoint(x: float64(r.position(row)), tMs: 100)
    let p = pickAt(st.shown, st.main.layout, at)
    doAssert p.found and p.trace == trace and p.position == r.position(row),
      what & ": the pick at position " & $r.position(row) & " found trace " & $p.trace &
      ", want " & $trace
    doAssert same(p.keys.rcvLine, k.rcvLine) and same(p.keys.rcvPoint, k.rcvPoint) and
      same(p.keys.offset, k.offset) and p.keys.component == k.component,
      what & ": the pick's keys at row " & $row

block presetsAreTheUsersOrders:
  # The three buttons, in the strip's order, as the user named them.
  doAssert SortPresets.mapIt(it.name) == @["Line/Station", "By Flag", "By Component"]
  doAssert preset("Line/Station") == @[key(hfRcvLine), key(hfRcvPoint)]
  doAssert preset("By Flag") == @[key(hfRcvLine), key(hfRcvPoint), key(hfComponent)]
  doAssert preset("By Component") == @[key(hfComponent), key(hfRcvLine), key(hfRcvPoint)]
  for i, s in SortPresets: doAssert presetOf(s.keys) == i
  doAssert presetOf([]) == -1 and presetOf([key(hfRcvLine, true), key(hfRcvPoint)]) == -1
  doAssert describe(preset("By Flag")) == "line, then point, then component"
  doAssert describe([key(hfOffset, true)]) == "offset (descending)"
  doAssert describe([]) == "the file's order"

block kernelOnKnownKeys:
  # 8 traces: line, point, component and offset, some unknown (NaN, or
  # component 0); `numSamples` only has to be there.
  let lines = [101.0, 100, 101, 100, 100, NaN, 101, 100]
  let points = [5.0, 7, 5, 5, 7, 1, 3, 5]
  let comps = [2'u8, 1, 1, 3, 2, 1, 0, 1]
  let offsets = [30.0, -10, NaN, 20, 0, 5, -0.0, 50]
  var keys: seq[TraceKeys]
  for i in 0 ..< 8:
    var k = initTraceKeys()
    (k.rcvLine, k.rcvPoint, k.component, k.offset) = (lines[i], points[i], comps[i], offsets[i])
    keys.add k
  let counts = newSeq[int](8)
  let rows = rowsOf(keys, counts)
  var got: seq[int]
  doAssert sortRowsInto(rows, [], got) and got == toSeq(0 ..< 8), "no keys: as given"
  doAssert sortRowsInto(rows, preset("Line/Station"), got)
  doAssert got == @[3, 7, 1, 4, 6, 0, 2, 5], $got # ties in the order given; NaN line last
  doAssert sortRowsInto(rows, preset("By Flag"), got)
  doAssert got == @[7, 3, 1, 4, 6, 2, 0, 5], $got # component 0 is unknown: last at its station
  doAssert sortRowsInto(rows, preset("By Component"), got)
  doAssert got == @[7, 1, 2, 5, 4, 0, 3, 6], $got
  doAssert sortRowsInto(rows, [key(hfOffset, descending = true)], got)
  doAssert got == @[7, 0, 3, 5, 4, 6, 1, 2], $got # -0 equals 0; NaN last also descending
  doAssert sortRowsInto(rows, [key(hfOffset)], got)
  doAssert got == @[1, 4, 6, 5, 3, 0, 7, 2], $got
  doAssert sortRowsInto(rows, [key(hfTrace, descending = true)], got)
  doAssert got == @[7, 6, 5, 4, 3, 2, 1, 0], $got
  # a stop gives up, and says so
  var calls = 0
  doAssert not sortRowsInto(rows, preset("By Flag"), got, proc (): bool = (inc calls; true))
  doAssert calls == 1
  withFixtures fx:
    var f = openSeismic(fx.surveySegy(), keys = false)
    doAssertRaises ValueError:
      discard sortRowsInto(f.rowsOf(0 ..< 4), [key(hfChannel)], got)
    f.close()

block buttonsOnTheMixedRecord:
  withFixtures fx:
    let path = fx.mixedOrderSegd()
    let before = snapshot(path)
    var f = openSeismic(path, keys = true) # the oracle's keys
    let seismic = toSeq(1 ..< f.len)
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[path])
    doAssert st.settle(st.main.layout.traces > 0)
    doAssert st.main.layout.traces == MixedSets.len * SegdChannels
    st.apply Command(kind: ckHeader, panel: MainPanel, header: HeaderChoice(auto: false,
      fields: @[hfRcvLine, hfRcvPoint, hfComponent]))
    st.look(0, float64(seismic.len - 1))
    doAssert st.settle(st.answered)
    st.checkShown(f, seismic, "the file's order")
    let view = st.main.view
    let jumps = st.main.jumps
    var orders: seq[seq[int]]
    for s in SortPresets:
      st.sortBy(s.keys)
      doAssert st.sorting(0), s.name & ": not said to be sorting"
      doAssert st.settle(st.answered and st.shown[^1].request.gen >= st.main.orderGen)
      doAssert not st.sorting(0)
      let want = f.expected(seismic, s.keys)
      st.checkShown(f, want, s.name)
      doAssert st.main.view == view and st.main.jumps == jumps, s.name & ": the view moved"
      orders.add want
    # every button gives another order, none the file's
    doAssert orders.deduplicate.len == 3 and seismic notin orders
    # the user's words: By Flag puts a station's components side by side, in
    # order; By Component groups the traces by component, each by line, then
    # station; Line/Station keeps the file's order within a station
    for k in 0 ..< orders[1].len:
      let kk = f.traceKeys(orders[1][k])
      doAssert int(kk.component) == k mod 3 + 1 and kk.rcvPoint == FirstRcvPoint +
        float64(k div 3 mod SegdChannels), "By Flag at " & $k
    for k in 0 ..< orders[2].len:
      let kk = f.traceKeys(orders[2][k])
      doAssert int(kk.component) == k div (2 * SegdChannels) + 1 and
        kk.rcvLine == RcvLine + float64(k div SegdChannels mod 2), "By Component at " & $k
    doAssert orders[0][0 .. 2].mapIt(int(f.traceKeys(it).component)) == @[3, 1, 2],
      "Line/Station: the file's order of station 100/101's components"
    # a view inside the gather reads only its own traces, in the order shown
    # (the zoom alone reads nothing new: the whole gather's tile covers it)
    st.sortBy(preset("Line/Station"))
    st.look(30, 41)
    st.sortBy(preset("By Component"))
    doAssert st.settle(st.answered and st.shown[^1].request.gen >= st.main.orderGen)
    let r = st.shown[^1].request
    doAssert r.first > 0 and r.last < seismic.len - 1, "not bounded by the view: " & $r
    st.checkShown(f, orders[2], "By Component, zoomed")
    # a custom order: component descending, then line, then point
    let custom = @[key(hfComponent, true), key(hfRcvLine), key(hfRcvPoint)]
    st.sortBy(custom)
    doAssert st.settle(st.answered and st.shown[^1].request.gen >= st.main.orderGen)
    st.checkShown(f, f.expected(seismic, custom), "component descending")
    # no keys: the file's order again
    st.sortBy(@[])
    doAssert st.main.layers[0].order.len == 0
    doAssert st.settle(st.answered and st.shown[^1].request.gen >= st.main.orderGen)
    st.checkShown(f, seismic, "the file's order again")
    doAssert st.log.count(sevWarning) == 0 and st.log.count(sevError) == 0, $st.log.count(
      sevWarning)
    st.shutdown()
    f.close()
    doAssert snapshot(path) == before, "sorting changed the file"

block threeComponentRecord:
  # Its sets are components 1, 2, 3 of the same stations: Line/Station and
  # By Flag interleave them (101/1, 101/2, 101/3, 102/1, ...), By Component
  # is the file's order.
  withFixtures fx:
    let path = fx.threeComponentSegd()
    var f = openSeismic(path, keys = true)
    let seismic = toSeq(1 ..< f.len)
    var interleaved: seq[int]
    for n in 0 ..< SegdChannels:
      for c in 0 ..< 3: interleaved.add 1 + c * SegdChannels + n
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[path])
    doAssert st.settle(st.main.layout.traces > 0)
    st.look(0, float64(seismic.len - 1))
    doAssert st.settle(st.answered)
    for (name, want) in [("Line/Station", interleaved), ("By Flag", interleaved),
        ("By Component", seismic)]:
      st.sortBy(preset(name))
      doAssert st.settle(st.answered and st.shown[^1].request.gen >= st.main.orderGen)
      st.checkShown(f, want, name)
    st.shutdown()
    f.close()

block oldOrderDropped:
  # The tiles in the old order stay drawn until the first one in the new
  # order comes; then only tiles in the new order are kept.
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.mixedOrderSegd()])
    doAssert st.settle(st.main.layout.traces > 0)
    st.look(0, 20)
    doAssert st.settle(st.answered)
    st.look(30, 50)
    doAssert st.settle(st.answered and st.shown.len == 2)
    st.sortBy(preset("By Flag"))
    doAssert st.shown.len == 2, "the old order was dropped before the new one came"
    let gen = st.main.orderGen
    doAssert st.settle(st.answered and st.shown[^1].request.gen >= gen)
    for t in st.shown:
      doAssert t.request.gen >= gen, "a tile in the old order is still kept: " &
        $st.shown.len & " tiles"
    st.shutdown()

block orderCarriesOverAndNewestWins:
  # On the survey (three shot gathers), offset descending: kept for the next
  # gather; two orders in a row: the second is what is shown.
  withFixtures fx:
    let path = fx.surveySegy()
    var f = openSeismic(path, keys = true)
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[path])
    doAssert st.settle(st.main.layout.traces > 0)
    st.look(0, Channels - 1)
    doAssert st.settle(st.answered)
    let far = @[key(hfOffset, true)]
    st.sortBy(@[key(hfChannel, true)])
    st.sortBy(far) # before the reader has taken the first
    doAssert st.settle(st.answered and st.shown[^1].request.gen >= st.main.orderGen)
    st.checkShown(f, f.expected(toSeq(0 ..< Channels), far), "offset descending")
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
    doAssert st.main.layers[0].order == far
    doAssert st.settle(st.main.layout.traces > 0)
    st.look(0, Channels - 1)
    doAssert st.settle(st.answered)
    doAssert not st.sorting(0), "a new gather is read, not sorted"
    st.checkShown(f, f.expected(toSeq(Channels ..< 2 * Channels), far), "gather 1")
    st.shutdown()
    f.close()

block bigGatherSortsOffTheUiThread:
  # 60 000 traces in one gather: the command returns at once (the reader
  # sorts), the plot is said to be sorting until the first tile in the new
  # order, and that tile is in order. Timed for the log.
  withFixtures fx:
    const n = 60_000
    let path = fx.dir / "big.sgy"
    var w = openSeismicWriter(path, SegyOutputOptions(text: @["C01 viewSEG sort test"]))
    let buf = [1'f32, -1, 0.5, 0]
    for i in 0 ..< n:
      var k = initTraceKeys()
      k.record = 1
      k.channel = float64(i + 1)
      k.offset = float64((i * 7919) mod n) # a permutation of 0 ..< n
      (k.t0Ms, k.intervalUs, k.status) = (0.0, 2000.0, tsLive)
      w.writeTrace(k, buf)
    doAssert w.close().len == 0
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[path])
    doAssert st.settle(st.main.layout.traces == n)
    var v = fitAll(st.main.layout, 800, 600)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert st.settle(st.answered)
    let t0 = epochTime()
    st.sortBy(@[key(hfOffset)])
    let applied = epochTime() - t0
    doAssert st.sorting(0)
    doAssert st.settle(st.answered and st.shown[^1].request.gen >= st.main.orderGen)
    let sorted = epochTime() - t0
    let t = st.shown[^1]
    var f = openSeismic(path, keys = true)
    for row in 1 ..< t.traces.len:
      doAssert f.traceKeys(t.traces[row - 1]).offset < f.traceKeys(t.traces[row]).offset
    f.close()
    echo "tsorting: ", n, " traces: the command took ", formatFloat(applied * 1000, ffDecimal,
      2), " ms, the sorted tile came after ", formatFloat(sorted * 1000, ffDecimal, 1), " ms"
    doAssert applied < sorted
    st.shutdown()
