## The kind of a file on disk (`kindOfFile`): a file up to `ProbeWholeBytes` is opened whole
## (headers only) and gets the answer of `describeRecording`; a larger one is not known; none
## for what is not seismic, cannot be read or has no live trace.
##
## Seen to fail with a deliberate fault: the probe's answer made always a shot gather
## ("abut: some(rkShotGather)"); with the start-of-file probe put back for a file above the
## limit, the receiver written last is never seen ("late: (outcome: poKnown, kind:
## rkReceiverContinuous)"); with the multiplexed record not looked for in the first read,
## "mux: (outcome: poKnown, kind: rkShotGather)" (it was opened, a copy demultiplexed); with
## the channel number always part of a receiver, "rising.sgd: (ready: true, ... kind:
## rkReceiverSliced" (six receivers of one segment); with it never part, "uncoded" reads one
## receiver ("components: 1"); with the rule that some trace must follow on another taken out
## (`abutting == 0` not asked), the samples' shot records read "land/shots.sgd:
## rkReceiverContinuous", "wholeShots: ... rkReceiverContinuous" and "sliced: ...
## rkReceiverContinuous".

import std/[algorithm, assertions, os, sets, strutils, times]
import parseSEG
import viewSEG/core/[correlatejobs, cutgather, recordingkind, recordingprobe, segmentclock,
  vendormaps]
import utils/[fixtures, kindfiles]

proc whole(path: string; reg: VendorRegistry): RecordingFacts =
  var f = openSeismic(path, keys = true, opts = OpenOptions(vendors: reg))
  try:
    result = describeRecording(planRecording(addr f, path, SpecDtMs, reg))
  finally:
    f.close()

proc sampleFacts(path: string): tuple[facts: RecordingFacts; receivers: int] =
  ## The facts of a file of `samples/` opened whole, as the probe opens it, and how many
  ## receivers its plan has.
  var f = openSeismic(path, keys = true, opts = OpenOptions(vendors: VendorRegistry()))
  try:
    let dtMs = seismicDtMs(addr f)
    if f.len > 0 and dtMs > 0:
      let plan = planRecording(addr f, path, dtMs, VendorRegistry())
      result.facts = describeRecording(plan)
      result.receivers = plan.receivers.toHashSet.len
  finally:
    f.close()

proc same(dir, name: string; specs: openArray[Spec]; want: RecordingKind) =
  let path = writeSpecs(dir, name, specs)
  let got = kindOfFile(path, VendorRegistry())
  doAssert got.outcome == poKnown and got.kind == want, name & ": " & $got
  doAssert got.kind == whole(path, VendorRegistry()).kind, name & " differs from the whole"

proc shots(stations: int; starts: openArray[int]): seq[Spec] =
  ## A shot after shot, every station each time, in file order.
  for first in starts:
    for r in 0 ..< stations: result.add spec(r, first)

proc main*() =
  let dir = getTempDir() / "trecordingprobe"
  removeDir(dir)

  block the_same_answer_as_the_whole_file:
    same(dir, "abut", [spec(0, 0), spec(0, 1000), spec(0, 2000), spec(1, 0), spec(1, 1000),
      spec(1, 2000)], rkReceiverContinuous)
    same(dir, "gap", [spec(0, 0), spec(0, 1000), spec(0, 2150), spec(0, 3150)],
      rkReceiverSliced)
    same(dir, "one", [spec(0, 0)], rkReceiverContinuous)
    same(dir, "two", [spec(0, 0), spec(1, 0)], rkShotGather)
    var shot: seq[Spec] = @[]
    for r in 0 ..< 8:
      for c in 0 ..< 3: shot.add spec(r, 0, c)
    same(dir, "shot", shot, rkShotGather)
    var dense: seq[Spec] = @[]
    for i in 0 ..< 6: dense.add spec(0, i * 250)
    same(dir, "dense", dense, rkReceiverSliced)
    same(dir, "skips", [spec(0, 0), spec(0, 4000), spec(0, 5000), spec(0, 6000),
      spec(0, 47000), spec(0, 48000)], rkReceiverContinuous)

  block every_receiver_needs_its_own_starts:
    # receiver 0 has 57 segments before receiver 1 shows its first; receiver 1 leaves the
    # step at its fifth: 16 segments in all must not decide the kind
    var specs: seq[Spec] = @[]
    for i in 0 ..< 57: specs.add spec(0, i * 1000)
    for i in 0 ..< 40: specs.add spec(1, i * 1000 + (if i >= 4: 333 else: 0))
    same(dir, "perreceiver", specs, rkReceiverSliced)

  block the_same_answer_through_a_vendor_clock:
    let reg = clockRegistry(dir / "reg")
    var raw: seq[int64] = @[]
    for i in 0 ..< ClockSegments: raw.add clockStart(i)
    let path = dir / "clock.sgd"
    writeClockRecording(path, raw)
    let got = kindOfFile(path, reg)
    doAssert got.outcome == poKnown and got.kind == rkReceiverContinuous, $got
    doAssert got.kind == whole(path, reg).kind
    # without the map the six traces are six receivers of one station that start together
    let bare = kindOfFile(path, VendorRegistry())
    doAssert bare.outcome == poKnown and bare.kind == whole(path, VendorRegistry()).kind and
      bare != got, $bare

  block a_receiver_whose_channel_rises_per_trace_stays_one:
    # one station recorded continuously, its channel number the trace number, in SEG-D and
    # SEG-Y: one receiver, not six of one segment each
    var specs: seq[Spec] = @[]
    for i in 0 ..< 6: specs.add spec(0, i * 1000)
    for path in [writeSpecs(dir, "rising", specs, channelPerTrace = true),
        writeSegySpecs(dir, "risingy", specs, channelPerTrace = true)]:
      let f = whole(path, VendorRegistry())
      doAssert f.kind == rkReceiverContinuous and f.components == 1, path & ": " & $f
      doAssert f.abutting == 5, path & ": " & $f
      doAssert kindOfFile(path, VendorRegistry()).kind == f.kind, path

  block a_position_written_a_little_differently_is_one_receiver_point:
    # SEG-Y nodes placed by their group coordinates, every other trace 1 m off: one node is
    # one receiver, continuous; two nodes 50 m apart are two
    var one: seq[Spec] = @[]
    for i in 0 ..< 6: one.add spec(0, i * 1000)
    let path = writeSegySpecs(dir, "jitter", one, channelPerTrace = true, jitter = 1)
    let f = whole(path, VendorRegistry())
    doAssert f.kind == rkReceiverContinuous and f.components == 1 and f.stations == 1, $f
    doAssert kindOfFile(path, VendorRegistry()).kind == f.kind
    let two = whole(writeSegySpecs(dir, "jitter2", shots(2, [0, 1000, 2000, 3000]),
      jitter = 1), VendorRegistry())
    doAssert two.kind == rkReceiverContinuous and two.components == 2 and two.stations == 2,
      $two
    # the one place both the keys and the segment clock take a point from
    var g = openSeismic(path, keys = true)
    defer: g.close()
    let places = stationPlaces(g)
    for p in places: doAssert p == places[0] and p.how == 1, $places

  block uncoded_channels_that_start_together_keep_their_channels:
    # three channels of one station, every component 0, at each of four starts: the channel
    # tells them apart, three receivers
    var specs: seq[Spec] = @[]
    for i in 0 ..< 4:
      for c in 0 ..< 3: specs.add spec(0, i * 1000, c)
    let path = writeSpecs(dir, "uncoded", specs, coded = false)
    let f = whole(path, VendorRegistry())
    doAssert f.kind == rkReceiverContinuous and f.components == 3, $f
    doAssert f.abutting == 9 and f.stations == 1, $f

  block the_samples_read_as_what_they_are:
    # every seismic file of samples/: the probe and the whole file agree, kind and order
    type Want = tuple[name: string; outcome: ProbeOutcome; kind: RecordingKind;
      order: TraceOrder]
    const
      byTime = TraceOrder(grouping: tgNone, subSort: tsByTime)
      byStation = TraceOrder(grouping: tgNone, subSort: tsByStation)
      flagTime = TraceOrder(grouping: tgByFlag, subSort: tsByTime)
      flagStation = TraceOrder(grouping: tgByFlag, subSort: tsByStation)
      notKnown = TraceOrder(grouping: tgNotKnown, subSort: tsNotKnown)
      wants: seq[Want] = @[
        ("land/shots.sgd", poKnown, rkShotGather, byTime),
        ("land/shots.sgy", poKnown, rkShotGather, byTime),
        ("obn/obn.sgd", poKnown, rkShotGather, flagTime),
        ("obn/obn_receiver.sgd", poKnown, rkReceiverSliced, flagStation),
        ("vib/field/signature_13trace_a.sgy", poKnown, rkShotGather, notKnown),
        ("vib/field/signature_13trace_b.sgy", poKnown, rkShotGather, notKnown),
        ("vib/field/signature_4trace_a.sgy", poNone, rkShotGather, notKnown),
        ("vib/field/signature_4trace_b.sgy", poNone, rkShotGather, notKnown),
        ("vib/vib_correlated.sgd", poKnown, rkShotGather, byStation),
        ("vib/vib_signature.sgd", poNone, rkShotGather, notKnown),
        ("vib/vib_uncorrelated.sgd", poKnown, rkShotGather, byStation)]
    let root = currentSourcePath().parentDir.parentDir / "samples"
    var listed: seq[string] = @[]
    for path in walkDirRec(root, relative = true):
      if path.splitFile.ext in [".sgy", ".sgd"]: listed.add path.replace('\\', '/')
    listed.sort()
    var named: seq[string] = @[]
    for w in wants: named.add w.name
    doAssert listed == named, "samples/ holds " & $listed
    for w in wants:
      let path = root / w.name
      let probe = kindOfFile(path, VendorRegistry())
      let (facts, receivers) = sampleFacts(path)
      doAssert probe.outcome == w.outcome, w.name & ": " & $probe
      doAssert facts.ready == (w.outcome == poKnown), w.name & ": " & $facts
      if facts.ready:
        doAssert probe.kind == w.kind and facts.kind == w.kind, w.name & ": " & $facts.kind &
          ", probe " & $probe.kind
        doAssert probe.order == w.order and facts.order == w.order, w.name & ": " &
          $facts.order & ", probe " & $probe.order
      if w.name == "obn/obn_receiver.sgd":
        # four nodes of four components, eight shots each: one receiver per node and
        # component, none of whose traces follows on another
        doAssert receivers == 16 and facts.slicedWhy == swNoFollow, $facts
        doAssert facts.fewestSteps == 30, $facts

  block shot_records_a_whole_number_of_trace_lengths_apart_are_a_shot_gather:
    # six shots 15 trace lengths apart, ten stations each: every boundary of a station is on
    # the step, but none follows on the one before it
    let specs = block:
      var s: seq[Spec] = @[]
      for shot in 0 ..< 6:
        for r in 0 ..< 10: s.add spec(r, shot * 15000)
      s
    same(dir, "wholeShots", specs, rkShotGather)
    for path in [writeSpecs(dir, "wholeShots", specs), writeSegySpecs(dir, "wholeShotsy", specs)]:
      let f = whole(path, VendorRegistry())
      doAssert f.kind == rkShotGather and f.components == 10 and f.abutting == 0, $f
      doAssert f.skips == 50 and f.irregular == 0 and f.slicedWhy == swNoFollow, $f
      doAssert cutRefusal(f) == "This file is a shot gather (the receiver changes from trace " &
        "to trace), not a continuous receiver gather. No trace follows directly on the one " &
        "before it: each of a receiver's traces starts 15 trace lengths or more after the " &
        "last, as records sliced at shot times do.", cutRefusal(f)

  block shot_records_of_which_two_follow_on_each_other_are_a_shot_gather:
    # ten stations, shots at 0, 15, 30, 31 and 46 record lengths: one boundary of each
    # station follows on the one before it, three skip, and the receiver changes at every
    # trace; one station recorded so stays continuous
    let starts = [0, 15000, 30000, 31000, 46000]
    let f = whole(writeSpecs(dir, "fewFollow", shots(10, starts)), VendorRegistry())
    doAssert f.kind == rkShotGather and f.abutting == 10 and f.skips == 30, $f
    same(dir, "fewFollow", shots(10, starts), rkShotGather)
    same(dir, "fewFollow1", shots(1, starts), rkReceiverContinuous)

  block a_receiver_sliced_at_whole_trace_lengths_is_time_sliced:
    # one station, a 2 s trace every 20 s: on the step, nothing follows on the one before
    var specs: seq[Spec] = @[]
    for i in 0 ..< 6: specs.add spec(0, i * 10000)
    same(dir, "sliced", specs, rkReceiverSliced)
    let f = whole(dir / "sliced.sgd", VendorRegistry())
    doAssert f.slicedWhy == swNoFollow and f.skips == 5 and f.fewestSteps == 10, $f
    doAssert cutRefusal(f) == "This file is a time-sliced receiver gather, not a continuous " &
      "one. No trace follows directly on the one before it: each of a receiver's traces " &
      "starts 10 trace lengths or more after the last, as records sliced at shot times do.",
      cutRefusal(f)
    # one trace that follows on the one before it: a box switched off between the others
    specs.add spec(0, 51000)
    same(dir, "slicedOne", specs, rkReceiverContinuous)
    let one = whole(dir / "slicedOne.sgd", VendorRegistry())
    doAssert one.abutting == 1 and one.skips == 5 and one.missingSegments == 45, $one

  block not_seismic_unreadable_or_empty:
    createDir(dir)
    let text = dir / "notes.txt"
    writeFile(text, "this is not a seismic file\n")
    doAssert kindOfFile(text, VendorRegistry()).outcome == poNone
    doAssert kindOfFile(dir / "missing.sgy", VendorRegistry()).outcome == poNone
    let empty = dir / "empty.sgy"
    writeFile(empty, "")
    doAssert kindOfFile(empty, VendorRegistry()).outcome == poNone
    let junk = dir / "junk.bin"
    writeFile(junk, newString(3 * 1024 * 1024))
    doAssert kindOfFile(junk, VendorRegistry()).outcome == poNone

  block a_file_cut_short_is_still_told:
    let path = writeSpecs(dir, "cut", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
    let size = getFileSize(path)
    let cut = dir / "cutshort.sgd"
    writeFile(cut, readFile(path)[0 ..< size.int - 1500])
    doAssert kindOfFile(cut, VendorRegistry()).outcome != poNone

  block a_large_file_is_opened_whole:
    # 20000 traces of 1000 samples, ~85 MB: opened whole, headers only
    var specs: seq[Spec] = @[]
    for i in 0 ..< 20000: specs.add spec(0, i * 1000)
    let path = writeSpecs(dir, "large", specs)
    let t0 = cpuTime()
    let whole = kindOfFile(path, VendorRegistry())
    echo "kindOfFile of ", getFileSize(path) div (1024 * 1024), " MB: ", cpuTime() - t0, " s"
    doAssert whole.outcome == poKnown and whole.kind == rkReceiverContinuous, $whole
    removeFile(path)

  block a_file_above_the_limit_is_not_known:
    # three components of one station, each in a run of its own; the last one leaves the step
    # at its second start: only the whole file tells, so above the limit there is no kind
    var specs: seq[Spec] = @[]
    for c in 0 ..< 3:
      for i in 0 ..< 150: specs.add spec(0, i * 1000 + (if c == 2 and i == 1: 300 else: 0), c)
    let path = writeSpecs(dir, "late", specs)
    let size = getFileSize(path)
    let sliced = kindOfFile(path, VendorRegistry())
    doAssert sliced.outcome == poKnown and sliced.kind == rkReceiverSliced
    for limit in [0'i64, size div 2, size - 1]:
      let got = kindOfFile(path, VendorRegistry(), wholeBytes = limit)
      doAssert got == KindProbe(outcome: poNotKnown), "late: " & $got
    doAssert kindOfFile(path, VendorRegistry(), wholeBytes = size).outcome == poKnown
    # what is not seismic stays without a kind, whatever its size
    let text = dir / "big.txt"
    writeFile(text, "not a seismic file\n")
    doAssert kindOfFile(text, VendorRegistry(), wholeBytes = 0).outcome == poNone

  block multiplexed_segd_is_not_opened:
    # the open would demultiplex a copy of the whole file: the list does not, and says so
    createDir(dir)
    let path = dir / "mux.sgd"
    writeMultiplexed(path)
    var copies = 0
    for kind, f in walkDir(getTempDir()):
      if f.extractFilename.startsWith("parseseg_demux_"): inc copies
    let got = kindOfFile(path, VendorRegistry())
    doAssert got == KindProbe(outcome: poMultiplexed), "mux: " & $got
    var after = 0
    for kind, f in walkDir(getTempDir()):
      if f.extractFilename.startsWith("parseseg_demux_"): inc after
    doAssert after == copies, "a demultiplexed copy was made"

  removeDir(dir)

when isMainModule:
  main()
