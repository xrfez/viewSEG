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
  OrderTrace(component: uint8(comp), place: (0'i8, line, point, 0'i16), start: float64(start) * Dt)

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

  block words:
    doAssert orderShort(order(tgNone, tsByStation)) == "Station"
    doAssert orderShort(order(tgNone, tsByTime)) == "Time"
    doAssert orderShort(order(tgByFlag, tsByStation)) == "Flag · station"
    doAssert orderShort(order(tgByComponent, tsByTime)) == "Component · time"
    doAssert orderShort(none) == "?"
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
