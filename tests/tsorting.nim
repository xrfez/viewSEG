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
      var (x, y) = (a.keys.sortValue(k.field, a.trace), b.keys.sortValue(k.field, b.trace))
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

proc main*() =

  block presetsAreTheUsersOrders:
    # The drop-down's orders, as the user named them: a grouping (by flag, by
    # component) and, inside it, a sub-sort (line and station, or time).
    doAssert SortPresets.mapIt(it.name) == @["Line/Station", "Time", "By Flag, Line/Station",
      "By Flag, Time", "By Component, Line/Station", "By Component, Time"]
    doAssert preset("Line/Station") == @[key(hfRcvLine), key(hfRcvPoint)]
    doAssert preset("Time") == @[key(hfStartTime)]
    doAssert preset("By Flag, Line/Station") ==
      @[key(hfRcvLine), key(hfRcvPoint), key(hfComponent)]
    doAssert preset("By Flag, Time") ==
      @[key(hfRcvLine), key(hfRcvPoint), key(hfStartTime), key(hfComponent)]
    doAssert preset("By Component, Line/Station") ==
      @[key(hfComponent), key(hfRcvLine), key(hfRcvPoint)]
    doAssert preset("By Component, Time") == @[key(hfComponent), key(hfStartTime)]
    for i, s in SortPresets: doAssert presetOf(s.keys) == i
    doAssert presetOf([]) == -1 and presetOf([key(hfRcvLine, true), key(hfRcvPoint)]) == -1
    doAssert describe(preset("By Flag, Line/Station")) == "line, then point, then component"
    doAssert describe(preset("Time")) == "Start time"
    doAssert describe([key(hfOffset, true)]) == "offset (descending)"
    doAssert describe([]) == "the file's order"

  block presetsOnAScrambledRecord:
    # 2 stations (points 1, 2 of line 100) x 4 components (SEG-D sensor types:
    # hydrophone H, vertical Z, inline X, crossline Y) x 3 segments, in a file
    # order that is none of the sorted ones. A segment starts at the same time
    # at every component of a station; station 2 starts one second after station 1.
    # A name is point, component, segment: "2X1". Each expected order is written
    # out (ties keep the file's order).
    const
      names = ["1Z0", "1Y1", "2Z2", "1H0", "1X1", "2H2", "2Y0", "1Z1", "1Y2", "2X0", "1H1",
        "1X2", "2Z0", "2Y1", "1Z2", "2H0", "2X1", "1H2", "1Y0", "2Z1", "2Y2", "1X0", "2H1", "2X2"]
      sensorOf = [('H', 1'u8), ('Z', 2'u8), ('X', 3'u8), ('Y', 4'u8)]
    var keys: seq[TraceKeys]
    for n in names:
      var k = initTraceKeys()
      k.rcvLine = 100
      k.rcvPoint = float64(ord(n[0]) - ord('0'))
      for (letter, sensor) in sensorOf:
        if letter == n[1]: (k.sensorType, k.component) = (sensor, sensor)
      k.time = 1_770_000_000.0 + float64(ord(n[2]) - ord('0')) * 600 + k.rcvPoint
      keys.add k
    let rows = rowsOf(keys, newSeq[int](keys.len))
    proc orderOf(order: openArray[SortKey]): seq[string] =
      var got: seq[int]
      doAssert sortRowsInto(rows, order, got)
      got.mapIt(names[it])
    doAssert orderOf(preset("Line/Station")) == @["1Z0", "1Y1", "1H0", "1X1", "1Z1", "1Y2",
      "1H1", "1X2", "1Z2", "1H2", "1Y0", "1X0", "2Z2", "2H2", "2Y0", "2X0", "2Z0", "2Y1", "2H0",
      "2X1", "2Z1", "2Y2", "2H1", "2X2"]
    doAssert orderOf(preset("Time")) == @["1Z0", "1H0", "1Y0", "1X0", "2Y0", "2X0", "2Z0", "2H0",
      "1Y1", "1X1", "1Z1", "1H1", "2Y1", "2X1", "2Z1", "2H1", "1Y2", "1X2", "1Z2", "1H2", "2Z2",
      "2H2", "2Y2", "2X2"]
    doAssert orderOf(preset("By Flag, Line/Station")) == @["1Z0", "1Z1", "1Z2", "1X1", "1X2",
      "1X0", "1Y1", "1Y2", "1Y0", "1H0", "1H1", "1H2", "2Z2", "2Z0", "2Z1", "2X0", "2X1", "2X2",
      "2Y0", "2Y1", "2Y2", "2H2", "2H0", "2H1"]
    doAssert orderOf(preset("By Flag, Time")) == @["1Z0", "1X0", "1Y0", "1H0", "1Z1", "1X1",
      "1Y1", "1H1", "1Z2", "1X2", "1Y2", "1H2", "2Z0", "2X0", "2Y0", "2H0", "2Z1", "2X1", "2Y1",
      "2H1", "2Z2", "2X2", "2Y2", "2H2"]
    doAssert orderOf(preset("By Component, Line/Station")) == @["1Z0", "1Z1", "1Z2", "2Z2",
      "2Z0", "2Z1", "1X1", "1X2", "1X0", "2X0", "2X1", "2X2", "1Y1", "1Y2", "1Y0", "2Y0", "2Y1",
      "2Y2", "1H0", "1H1", "1H2", "2H2", "2H0", "2H1"]
    doAssert orderOf(preset("By Component, Time")) == @["1Z0", "2Z0", "1Z1", "2Z1", "1Z2", "2Z2",
      "1X0", "2X0", "1X1", "2X1", "1X2", "2X2", "1Y0", "2Y0", "1Y1", "2Y1", "1Y2", "2Y2", "1H0",
      "2H0", "1H1", "2H1", "1H2", "2H2"]
    # a descending component reverses the kinds: H, Y, X, Z
    doAssert orderOf([key(hfRcvPoint), key(hfComponent, true)])[0 .. 3] ==
      @["1H0", "1H1", "1H2", "1Y1"]

  block componentsOrderByKind:
    # vertical, inline (X), crossline (Y), hydrophone, any other by its code,
    # no component last; SEG-D by sensor type, SEG-Y by identification code.
    # Components of one kind order by code, so By Component still groups; equal
    # components keep the file's order.
    func segd(sensor, comp: uint8): TraceKeys =
      result = initTraceKeys()
      (result.sensorType, result.component) = (sensor, comp)
    func segy(code: int16): TraceKeys =
      result = initTraceKeys()
      (result.traceCode, result.component, result.status) = (code, uint8(code), tsLive)
    proc order(keys: seq[TraceKeys]; descending = false): seq[int] =
      let rows = rowsOf(keys, newSeq[int](keys.len))
      doAssert sortRowsInto(rows, [key(hfComponent, descending)], result)
    # SEG-D: H, Z, X, Y in the file; a component of no named sensor (9, 4), the
    # group indices 6 and 5 of two vertical sensors, and one without a component
    let d = @[segd(1, 1), segd(2, 2), segd(3, 3), segd(4, 4), segd(0, 9), segd(0, 4),
      segd(2, 6), segd(2, 5), segd(0, 0)]
    doAssert d.order == @[1, 7, 6, 2, 3, 0, 5, 4, 8], $d.order # Z Z Z X Y H, 4, 9, none
    doAssert d.order(true) == @[4, 5, 0, 3, 2, 6, 7, 1, 8], $d.order(true) # none stays last
    # SEG-Y: 11 hydrophone, 12 vertical, 13 crossline, 14 inline, 15 vertical (geophone Z)
    let y = @[segy(11), segy(12), segy(13), segy(14), segy(15)]
    doAssert y.order == @[1, 4, 3, 2, 0], $y.order # Z, Z, X, Y, H
    doAssert y.order(true) == @[0, 2, 3, 4, 1], $y.order(true)

  block unknownTimeLast:
    var keys: seq[TraceKeys]
    for t in [30.0, NaN, 10.0, NaN, 20.0]:
      var k = initTraceKeys()
      k.time = t
      keys.add k
    let rows = rowsOf(keys, newSeq[int](keys.len))
    var got: seq[int]
    doAssert sortRowsInto(rows, preset("Time"), got) and got == @[2, 4, 0, 1, 3], $got
    doAssert sortRowsInto(rows, [key(hfStartTime, true)], got) and got == @[0, 4, 2, 1, 3], $got
    doAssert keys[0].value(hfStartTime, 0) == 30.0e6 and keys[1].value(hfStartTime, 1).isNaN
    # a recorder's own times, given by `startOf`, win over the keys'
    let own = [5.0, 4.0, 3.0, NaN, 1.0]
    doAssert sortRowsInto(rows, preset("Time"), got, startOf = proc (t: int): float64 = own[t])
    doAssert got == @[4, 2, 1, 0, 3], $got

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
    doAssert sortRowsInto(rows, preset("By Flag, Line/Station"), got)
    doAssert got == @[7, 3, 1, 4, 6, 2, 0, 5], $got # component 0 is unknown: last at its station
    doAssert sortRowsInto(rows, preset("By Component, Line/Station"), got)
    doAssert got == @[7, 1, 2, 5, 4, 0, 3, 6], $got
    doAssert sortRowsInto(rows, [key(hfOffset, descending = true)], got)
    doAssert got == @[7, 0, 3, 5, 4, 6, 1, 2], $got # -0 equals 0; NaN last also descending
    doAssert sortRowsInto(rows, [key(hfOffset)], got)
    doAssert got == @[1, 4, 6, 5, 3, 0, 7, 2], $got
    doAssert sortRowsInto(rows, [key(hfTrace, descending = true)], got)
    doAssert got == @[7, 6, 5, 4, 3, 2, 1, 0], $got
    # a stop gives up, and says so
    var calls = 0
    doAssert not sortRowsInto(rows, preset("By Flag, Line/Station"), got,
      proc (): bool = (inc calls; true))
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
      # the line and station orders and the flag and component groupings differ,
      # none is the file's (the time orders are not: the fixture's traces share one time)
      doAssert seismic notin [orders[0], orders[2], orders[4]]
      doAssert orders[0] != orders[2] and orders[2] != orders[4] and orders[0] != orders[4]
      doAssert orders[1] == seismic and orders[3] == orders[2]
      # By Component, Time: with one time everywhere, each component's traces in the file's order
      doAssert orders[5].mapIt(int(f.traceKeys(it).component)) ==
        orders[4].mapIt(int(f.traceKeys(it).component)) and orders[5] != orders[4]
      # the user's words: By Flag puts a station's components side by side, in
      # order; By Component groups the traces by component, each by line, then
      # station; Line/Station keeps the file's order within a station
      for k in 0 ..< orders[2].len:
        let kk = f.traceKeys(orders[2][k])
        doAssert int(kk.component) == k mod 3 + 1 and kk.rcvPoint == FirstRcvPoint +
          float64(k div 3 mod SegdChannels), "By Flag at " & $k
      for k in 0 ..< orders[4].len:
        let kk = f.traceKeys(orders[4][k])
        doAssert int(kk.component) == k div (2 * SegdChannels) + 1 and
          kk.rcvLine == RcvLine + float64(k div SegdChannels mod 2), "By Component at " & $k
      doAssert orders[0][0 .. 2].mapIt(int(f.traceKeys(it).component)) == @[3, 1, 2],
        "Line/Station: the file's order of station 100/101's components"
      # a view inside the gather reads only its own traces, in the order shown
      # (the zoom alone reads nothing new: the whole gather's tile covers it)
      st.sortBy(preset("Line/Station"))
      st.look(30, 41)
      st.sortBy(preset("By Component, Line/Station"))
      doAssert st.settle(st.answered and st.shown[^1].request.gen >= st.main.orderGen)
      let r = st.shown[^1].request
      doAssert r.first > 0 and r.last < seismic.len - 1, "not bounded by the view: " & $r
      st.checkShown(f, orders[4], "By Component, zoomed")
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
    # is the file's order (its traces name no sensor, so the components order
    # by code, which is the file's order; the entry carries the new name of the
    # preset, "By Component" before the drop-down had a sub-sort).
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
      for (name, want) in [("Line/Station", interleaved), ("By Flag, Line/Station", interleaved),
          ("By Component, Line/Station", seismic)]:
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
      st.sortBy(preset("By Flag, Line/Station"))
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

when isMainModule:
  main()
