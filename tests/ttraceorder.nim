## The order the traces of a file are written in (`traceOrder`): one component by station or by
## time; several components grouped by flag or by component, each with a sub-sort; none that
## holds, a constant key and a single trace are not known. The probe of a file on disk and the
## open of the shown file carry the order to the row of the Files panel with the kind, and an
## answer for a changed file is dropped.
##
## Seen to fail with a deliberate fault: with `holds` letting the key fall ("unordered");
## with `contiguousComponents` always true, "flagStation" is read as by component.

import std/[assertions, os, times]
import parseSEG
import viewSEG/core/[recordingkind, recordingprobe, traceorder, vendormaps]
import viewSEG/view/[filetable, recordingwords]
import viewSEG/core/filelist
import utils/[fixtures, kindfiles]

const Dt = 0.002

proc names(t: FileTable; f: FileList): seq[string] =
  for r in t.rows: result.add f.entries[r].name

func tr(comp: int; line, point: float64; start: int): OrderTrace =
  OrderTrace(component: uint8(comp), place: (0'i8, line, point, 0'i16),
    start: float64(start) * Dt, record: int64(start div 500))

func order(g: TraceGrouping; s: TraceSubSort): TraceOrder = TraceOrder(grouping: g, subSort: s)

proc probeOrder(dir, name: string; specs: openArray[Spec]): TraceOrder =
  let got = kindOfFile(writeSpecs(dir, name, specs), VendorRegistry())
  doAssert got.outcome == poKnown, name & ": " & $got
  got.order

proc main*() =
  let none = order(tgNotKnown, tsNotKnown)
  block oneComponent:
    var byStation, byTime, flat: seq[OrderTrace] = @[]
    for i in 0 ..< 6:
      byStation.add tr(1, 1, float64(i + 1), 0)
      byTime.add tr(1, 1, 5, i * 1000)
      flat.add tr(1, 1, 5, 7)
    doAssert traceOrder(byStation, Dt, true) == order(tgNone, tsByStation)
    doAssert traceOrder(byStation, Dt, false) == order(tgNone, tsByStation)
    doAssert traceOrder(byTime, Dt, true) == order(tgNone, tsByTime)
    doAssert traceOrder(flat, Dt, true) == none, "a constant key is not an order"
    doAssert traceOrder(flat[0 .. 0], Dt, true) == none, "one trace"
    doAssert traceOrder([], Dt, false) == none
    # ties do not break it
    byStation.insert(byStation[2], 2)
    doAssert traceOrder(byStation, Dt, true) == order(tgNone, tsByStation)
    # unordered: the station and the time both fall somewhere
    var mixed = @[tr(1, 1, 3, 0), tr(1, 1, 1, 1000), tr(1, 1, 2, 500)]
    doAssert traceOrder(mixed, Dt, true) == none, "unordered"
    # both hold: the shot gather says its stations, the receiver gather its times
    var both: seq[OrderTrace] = @[]
    for i in 0 ..< 5: both.add tr(1, 1, float64(i + 1), i * 1000)
    doAssert traceOrder(both, Dt, true) == order(tgNone, tsByStation)
    doAssert traceOrder(both, Dt, false) == order(tgNone, tsByTime)

  block severalComponents:
    var flagStation, flagTime, compStation, compTime, tangled: seq[OrderTrace] = @[]
    for p in 0 ..< 4:
      for c in 1 .. 3:
        flagStation.add tr(c, 1, float64(p + 1), 0)
        flagTime.add tr(c, 1, 9, p * 1000 + c) # components start a sample apart
    for c in 1 .. 3:
      for p in 0 ..< 4:
        compStation.add tr(c, 1, float64(p + 1), 0)
        compTime.add tr(c, 1, 9, p * 1000)
    doAssert traceOrder(flagStation, Dt, true) == order(tgByFlag, tsByStation)
    doAssert traceOrder(flagTime, Dt, false) == order(tgByFlag, tsByTime), "flag by time"
    doAssert traceOrder(compStation, Dt, true) == order(tgByComponent, tsByStation)
    doAssert traceOrder(compTime, Dt, false) == order(tgByComponent, tsByTime)
    # a hydrophone's times are never set against a geophone's: component 2 starts earlier
    # than component 1's last trace but each is in order
    var apart = flagTime
    for t in apart.mitems:
      if t.component == 2: t.start -= 500 * Dt
    doAssert traceOrder(apart, Dt, false) == order(tgByFlag, tsByTime)
    # the components in no regular grouping: not known
    tangled = @[tr(1, 1, 1, 0), tr(1, 1, 2, 0), tr(2, 1, 2, 0), tr(1, 1, 3, 0),
      tr(2, 1, 3, 0), tr(2, 1, 4, 0)]
    doAssert traceOrder(tangled, Dt, true) == none, "tangled"
    # the stations of a flag not the same: by station does not hold
    var split = flagStation
    split[1].place = (0'i8, 1.0, 99.0, 0'i16)
    doAssert traceOrder(split, Dt, true) == none

  block shotRecordsSortedByStationInside:
    # a shot gather: the station restarts at every record, only the time holds over the file
    # (seen to fail with `stationInRecords` never called: these read as time)
    let inRec = TraceOrder(grouping: tgNone, subSort: tsByStation, sortInRecords: true,
        groupInRecords: true)
    var recs: seq[OrderTrace] = @[]
    for r in 0 ..< 3:
      for p in 1 .. 4: recs.add tr(1, 1, float64(p), r * 1000)
    doAssert traceOrder(recs, Dt, true) == inRec, "records each sorted by station"
    doAssert traceOrder(recs, Dt, false) == order(tgNone, tsByTime), "a receiver gather: time"
    # one record out of order: the whole-file time is what holds
    var bad = recs
    swap(bad[4], bad[5])
    doAssert traceOrder(bad, Dt, true) == order(tgNone, tsByTime), "one record out of order"
    # also out of time: not known
    for i in 0 ..< bad.len: bad[i].start = float64((i * 7) mod 5 * 1000) * Dt
    doAssert traceOrder(bad, Dt, true) == none
    # descending stations inside every record: not a station order
    var down: seq[OrderTrace] = @[]
    for r in 0 ..< 3:
      for p in countdown(4, 1): down.add tr(1, 1, float64(p), r * 1000)
    doAssert traceOrder(down, Dt, true) == order(tgNone, tsByTime), "descending in records"
    # a record with a missing station is still sorted
    var gap = recs
    gap.delete(5)
    doAssert traceOrder(gap, Dt, true) == inRec, "a station missing in one record"
    # one trace per record: no station rise inside a record
    var single: seq[OrderTrace] = @[]
    for r in 0 ..< 4: single.add tr(1, 1, float64(4 - r), r * 1000)
    doAssert traceOrder(single, Dt, true) == order(tgNone, tsByTime)
    # several components by flag inside each record
    var flag, comp, mixed: seq[OrderTrace] = @[]
    for r in 0 ..< 3:
      for p in 1 .. 4:
        for c in 1 .. 3: flag.add tr(c, 1, float64(p), r * 1000)
      for c in 1 .. 3:
        for p in 1 .. 4: comp.add tr(c, 1, float64(p), r * 1000)
    doAssert traceOrder(flag, Dt, true) ==
      TraceOrder(grouping: tgByFlag, subSort: tsByStation, sortInRecords: true,
        groupInRecords: true), "flag in records"
    doAssert traceOrder(comp, Dt, true) ==
      TraceOrder(grouping: tgByComponent, subSort: tsByStation, sortInRecords: true,
        groupInRecords: true),
      "component in records"
    # records laid out differently from one another: no grouping, so time is told
    mixed = flag[0 ..< 12] & comp[12 ..< 24] & flag[24 ..< 36]
    doAssert traceOrder(mixed, Dt, true).sortInRecords == false
    doAssert orderShort(traceOrder(flag, Dt, true)) == "Flag · station"
    doAssert orderTitle(traceOrder(recs, Dt, true)) ==
      "Inside each record, traces are sorted by station."
    doAssert orderTitle(traceOrder(flag, Dt, true)) ==
      "Traces are grouped by flag (the components of a station together) inside each " &
      "record, and sorted by station."
    doAssert orderTitle(traceOrder(comp, Dt, true)) ==
      "Inside each record, traces are grouped by component, and inside each component " &
      "sorted by station."
    # the record is the file's own, not the start time: starts that spread inside one record
    # (s1 s5 at b, s2 s6 at b + 2 samples) leave the record one record, unsorted: not station
    # (seen to fail with records cut by start within a sample)
    var drift: seq[OrderTrace] = @[]
    for r in 0 ..< 3:
      let b = r * 1000
      for (p, dt) in [(1, 0), (5, 0), (2, 2), (6, 2)]:
        drift.add tr(1, 1, float64(p), b + dt)
        drift[^1].record = int64(r)
    doAssert traceOrder(drift, Dt, true) == order(tgNone, tsByTime), "starts spread in a record"
    # two records one sample apart in start stay two records
    var close: seq[OrderTrace] = @[]
    for r in 0 ..< 3:
      for p in 1 .. 4:
        close.add tr(1, 1, float64(p), 0)
        close[^1].start = float64(r) * Dt
        close[^1].record = int64(r)
    doAssert traceOrder(close, Dt, true) == inRec, "records one sample apart"
    # a record in two separate runs: no within-record answer
    var inter = @[tr(1, 1, 3, 0), tr(1, 1, 4, 0), tr(1, 1, 1, 1000), tr(1, 1, 2, 1000),
      tr(1, 1, 5, 0), tr(1, 1, 6, 0)]
    doAssert traceOrder(inter, Dt, true) == none, "interleaved records"
    # no record structure: one record, or the record not told
    var oneRec = recs
    for t in oneRec.mitems: t.record = 0
    doAssert not traceOrder(oneRec, Dt, true).sortInRecords, "one record"
    var unknown = recs
    for t in unknown.mitems: t.record = NoRecord
    doAssert not traceOrder(unknown, Dt, true).sortInRecords, "no record number"
    # forcing one part keeps what is still true of the other
    var forced = traceOrder(flag, Dt, true)
    forced.grouping = tgByComponent
    forced.groupInRecords = false
    doAssert orderTitle(forced) == "Traces are grouped by component, and inside each " &
      "component sorted by station inside each record."
    forced = traceOrder(flag, Dt, true)
    forced.subSort = tsByTime
    forced.sortInRecords = false
    doAssert orderTitle(forced) == "Traces are grouped by flag (the components of a time " &
      "together) inside each record, sorted by time."
    # a station order over the whole file keeps today's words
    var whole: seq[OrderTrace] = @[]
    for i in 0 ..< 5: whole.add tr(1, 1, float64(i + 1), i * 1000)
    doAssert orderTitle(traceOrder(whole, Dt, true)) == "Traces are sorted by station."

  block theFlagIsOneStationWhateverTheSubSort:
    # (the review's cases) components of one time at different stations are no flag
    var crossed: seq[OrderTrace] = @[]
    var pairs: seq[OrderTrace] = @[]
    for k in 0 ..< 5:
      crossed.add [tr(1, 1, 1, k * 1000), tr(2, 1, 2, k * 1000), tr(2, 1, 1, k * 1000),
        tr(1, 1, 2, k * 1000)]
      pairs.add [tr(1, 1, 1, k * 1000), tr(2, 1, 7, k * 1000 + 1)]
    doAssert traceOrder(crossed, Dt, false) == none, "crossed stations in a flag by time"
    doAssert traceOrder(pairs, Dt, false) == none, "pairs of different stations"
    # placed by the channel alone: the grouping cannot be told, and a rising channel is no
    # station order
    var channels: seq[OrderTrace] = @[]
    for k in 0 ..< 5:
      for c in 1 .. 3:
        channels.add OrderTrace(component: uint8(c), place: (2'i8, float64(c), 0.0, 0'i16),
          start: float64(k * 1000) * Dt)
    doAssert traceOrder(channels, Dt, false) == none, "channel-only flag by time"
    var oneChannel: seq[OrderTrace] = @[]
    for k in 0 ..< 5:
      for c in 1 .. 3:
        oneChannel.add OrderTrace(component: uint8(c), place: (2'i8, 7.0, 0.0, 0'i16),
          start: float64(k * 1000) * Dt)
    doAssert traceOrder(oneChannel, Dt, false) == none, "components on one channel number"
    var rising: seq[OrderTrace] = @[]
    for c in 1 .. 8:
      rising.add OrderTrace(component: 1, place: (2'i8, float64(c), 0.0, 0'i16), start: 0)
    doAssert traceOrder(rising, Dt, true) == none, "a rising channel is not a station order"
    for i, t in rising.mpairs: t.start = float64(i * 1000) * Dt
    doAssert traceOrder(rising, Dt, true) == order(tgNone, tsByTime), "time of channel-only"

  block uncodedComponents:
    # component 0 for every trace: several at one station and start are components that
    # cannot be told apart; the sub-sort is still said, the grouping is not
    var flat, byComp, one: seq[OrderTrace] = @[]
    for s in 1 .. 4:
      for c in 1 .. 3: flat.add tr(0, 1, float64(s), 0)
    doAssert traceOrder(flat, Dt, true) == order(tgNotKnown, tsByStation), "uncoded 3C"
    for k in 0 ..< 5:
      for c in 1 .. 3: byComp.add tr(0, 1, 1, k * 1000)
    doAssert traceOrder(byComp, Dt, false) == order(tgNotKnown, tsByTime)
    for s in 1 .. 4: one.add tr(0, 1, float64(s), 0)
    doAssert traceOrder(one, Dt, true) == order(tgNone, tsByStation), "uncoded, one per station"
    doAssert orderShort(order(tgNotKnown, tsByStation)) == "Station"
    doAssert orderTitle(order(tgNotKnown, tsByStation)) == "Traces are sorted by station. " &
      "Some traces share a station and start time without a component code, so the " &
      "grouping cannot be told."

  block backwardCreep:
    # many steps under half a sample, each rounding to a tie, are not sorted
    var creep: seq[OrderTrace] = @[tr(1, 1, 1, 0)]
    for k in 1 .. 100: creep.add OrderTrace(component: 1, place: (0'i8, 1.0, 1.0, 0'i16),
      start: 10.0 - float64(k) * 0.0009)
    creep.insert(tr(1, 1, 1, 0), 0)
    creep[1].start = 10.0
    doAssert traceOrder(creep, Dt, false) == none, "creeping back"

  block words:
    doAssert orderShort(order(tgNone, tsByStation)) == "Station"
    doAssert orderShort(order(tgNone, tsByTime)) == "Time"
    doAssert orderShort(order(tgByFlag, tsByStation)) == "Flag · station"
    doAssert orderShort(order(tgByComponent, tsByTime)) == "Component · time"
    doAssert orderShort(none) == "?"
    doAssert orderTitle(none) == "No order by station or time could be told: the traces are " &
      "out of order, their grouping is irregular, the key never changes, or there are too few."
    doAssert orderTitle(order(tgByComponent, tsByTime)) ==
      "Traces are grouped by component, and inside each component sorted by time."
    doAssert kindShort(rkReceiverSliced) == "Sliced" and kindShort(rkReceiverContinuous) ==
      "Continuous" and kindShort(rkShotGather) == "Shot"

  block theProbeAndTheOpenGiveTheSameOrder:
    let dir = getTempDir() / "ttraceorder"
    removeDir(dir)
    var specs: seq[Spec] = @[]
    for r in 0 ..< 5: specs.add spec(r, 0)
    doAssert probeOrder(dir, "station", specs) == order(tgNone, tsByStation),
      "the probe left the order out"
    specs = @[]
    for i in 0 ..< 5: specs.add spec(0, i * 1000)
    doAssert probeOrder(dir, "time", specs) == order(tgNone, tsByTime)
    specs = @[]
    for r in 0 ..< 4:
      for c in 0 ..< 3: specs.add spec(r, 0, c)
    let path = writeSpecs(dir, "flag", specs)
    let probe = kindOfFile(path, VendorRegistry())
    doAssert probe.order == order(tgByFlag, tsByStation), $probe
    var f = openSeismic(path, keys = true, opts = OpenOptions(vendors: VendorRegistry()))
    try:
      let facts = describeRecording(planRecording(addr f, path, SpecDtMs, VendorRegistry()))
      doAssert facts.order == probe.order
    finally:
      f.close()
    specs = @[]
    for c in 0 ..< 3:
      for r in 0 ..< 4: specs.add spec(r, 0, c)
    doAssert probeOrder(dir, "component", specs) == order(tgByComponent, tsByStation)
    doAssert probeOrder(dir, "one", [spec(0, 0)]) == none
    doAssert probeOrder(dir, "shuffled", [spec(2, 0), spec(0, 0), spec(1, 0)]) == none
    removeDir(dir)

  block theRowShowsIt:
    var list = FileList(gen: 1, revision: 1)
    var e = FileEntry(path: "/d/a.sgd", name: "a.sgd", kind: fkSegd, size: 1,
      kindState: ksKnown, recording: rkShotGather,
      traceOrder: order(tgByFlag, tsByTime))
    var far = FileEntry(path: "/d/b.sgd", name: "b.sgd", kind: fkSegd, size: 1,
      kindState: ksNotKnown)
    var unread = FileEntry(path: "/d/c.sgd", name: "c.sgd", kind: fkSegd, size: 1)
    var plain = FileEntry(path: "/d/d.sgd", name: "d.sgd", kind: fkSegd, size: 1,
      kindState: ksKnown, recording: rkReceiverContinuous, traceOrder: order(tgNone, tsByStation))
    list.merge([e, far, unread, plain])
    doAssert orderText(list.entries[0]) == "Flag · time"
    doAssert orderTip(list.entries[0]).len > 0
    doAssert orderText(list.entries[1]) == "?" and orderTip(list.entries[1]) == NotKnownWords
    doAssert orderText(list.entries[2]) == "" and orderText(list.entries[3]) == "Station"
    var t: FileTable
    t.update(list, "", FileOrder(column: fcOrder))
    doAssert t.names(list) == @["c.sgd", "b.sgd", "d.sgd", "a.sgd"], $t.names(list)

when isMainModule:
  main()
