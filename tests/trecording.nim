## What a file is as a recording (`describeRecording`): the two levels of its
## kind and the sentences that refuse a file. Files are built here: SEG-D,
## 2 ms, a trace per `Spec` (station, first sample, component) of one length, written as
## SEG-D Rev 3, one record per trace (SEG-Y has no slot for the receiver line).
##
## Seen to fail with a deliberate fault: the shot gather read as a receiver
## gather when the stations are not compared; a 30% overlap accepted as a
## small repeat; one late start accepted as continuous (a share of boundaries
## instead of every boundary); a step taken as the commonest start difference,
## so dropouts at most boundaries made the dead time the step; a trace one
## sample short refused (floats instead of samples); a repeat of 5% refused; the receiver
## change in file order never asked ("and false"): the shots read as time sliced; the traces
## of one station and start not taken as one segment (the uncoded channels compared with each
## other): "uncoded shots, Rev 3: rkReceiverSliced"; the group coordinates not asked before the
## channel: "coordinates: rkShotGather"; the measured reason dropped from a shot gather told by
## the order of the file (`slicedWhy` reset): the uneven shots and "offonce" refused with the
## kind alone.

import std/[assertions, math, os, strutils]
import parseSEG
import viewSEG/core/[cutgather, recordingkind, vendormaps]
import viewSEG/view/recordingwords

const
  BaseS = 1_772_323_200.0 # 2026-03-01T00:00:00 UTC
  DtMs = 2.0

type Spec = tuple[rcv, first, comp: int, stationed: bool, extra: int]

func spec(rcv, first: int; comp = 0; stationed = true; extra = 0): Spec =
  ## `extra` moves the channel number alone: another channel of the same component type.
  (rcv, first, comp, stationed, extra)

proc writeSpecs(dir, name: string; specs: openArray[Spec]; n: int): string =
  createDir(dir)
  result = dir / (name & ".sgd")
  var w = openSeismicWriter(result, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: n))
  for i, s in specs:
    var k = initTraceKeys()
    k.status = tsLive
    k.record = float64(i + 1)
    k.channel = float64(s.rcv * 4 + s.comp + 1 + s.extra * 100)
    k.component = uint8(s.comp + 1)
    k.intervalUs = 2000
    k.t0Ms = 0
    k.time = BaseS + float64(s.first) * DtMs / 1000
    if s.stationed:
      k.rcvLine = 1
      k.rcvPoint = float64(s.rcv + 1)
    var samples = newSeq[float32](n)
    for j in 0 ..< n: samples[j] = float32(s.first + j)
    w.writeTrace(k, samples)
  discard w.close()

proc factsOf(dir, name: string; specs: openArray[Spec]; n = 1000;
    starts = KindStarts): RecordingFacts =
  let path = writeSpecs(dir, name, specs, n)
  var f = openSeismic(path)
  try:
    result = describeRecording(planRecording(addr f, path, DtMs, VendorRegistry()), starts)
  finally:
    f.close()

proc receiversOf(dir, name: string; specs: openArray[Spec]): seq[int] =
  let path = writeSpecs(dir, name, specs, 1000)
  var f = openSeismic(path)
  try:
    result = planRecording(addr f, path, DtMs, VendorRegistry()).receivers
  finally:
    f.close()

proc lengthsOf(dir, name: string; traces: openArray[tuple[first, n: int]]): RecordingFacts =
  ## One receiver (no station, one channel) in a SEG-Y file, whose traces may differ in length.
  createDir(dir)
  let path = dir / (name & ".sgy")
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for i, t in traces:
    var k = initTraceKeys()
    k.status = tsLive
    k.record = 1
    k.channel = 1
    k.intervalUs = 2000
    k.t0Ms = 0
    k.time = BaseS + float64(t.first) * DtMs / 1000
    var samples = newSeq[float32](t.n)
    for j in 0 ..< t.n: samples[j] = float32(t.first + j)
    w.writeTrace(k, samples)
  discard w.close()
  var f = openSeismic(path)
  try:
    result = describeRecording(planRecording(addr f, path, DtMs, VendorRegistry()))
  finally:
    f.close()

proc segyFacts(dir, name: string; specs: openArray[Spec]; n = 1000): RecordingFacts =
  ## The same traces as `specs` in a SEG-Y file (one channel per station, a line and point).
  createDir(dir)
  let path = dir / (name & ".sgy")
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for i, s in specs:
    var k = initTraceKeys()
    k.status = tsLive
    k.record = 1
    k.channel = float64(s.rcv + 1)
    k.intervalUs = 2000
    k.t0Ms = 0
    k.time = BaseS + float64(s.first) * DtMs / 1000
    k.rcvLine = 1
    k.rcvPoint = float64(s.rcv + 1)
    w.writeTrace(k, newSeq[float32](n))
  discard w.close()
  var f = openSeismic(path, keys = true)
  try:
    result = describeRecording(planRecording(addr f, path, DtMs, VendorRegistry()))
  finally:
    f.close()

proc uncodedShots(dir, name: string; rev2: bool): RecordingFacts =
  ## Six shots, uneven in time, of 60 stations of three channels each whose component is not
  ## coded (0), in SEG-D Rev 3 or, converted, Rev 2.1 (whose records keep their time to the
  ## second).
  createDir(dir)
  let rev3 = dir / (name & (if rev2: ".r3" else: ".sgd"))
  var w = openSeismicWriter(rev3, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 1000))
  const firsts = [0, 1650, 4050, 5750, 8950, 10600] # no step between them, also by the second
  for shot, first in firsts:
    for r in 0 ..< 60:
      for c in 0 ..< 3:
        var k = initTraceKeys()
        k.status = tsLive
        k.record = float64(shot + 1)
        k.channel = float64(r * 3 + c + 1)
        k.component = 0
        k.intervalUs = 2000
        k.t0Ms = 0
        k.time = BaseS + float64(first) * DtMs / 1000
        k.rcvLine = 1
        k.rcvPoint = float64(r + 1)
        w.writeTrace(k, newSeq[float32](1000))
  discard w.close()
  var path = rev3
  if rev2:
    path = dir / (name & ".sgd")
    for d in convertSegdRevision(rev3, path, SegdConvertOptions(revision: SegdRevision(
        major: 2, minor: 1))):
      doAssert d.severity != sevFatal, $d
  var f = openSeismic(path)
  try:
    result = describeRecording(planRecording(addr f, path, DtMs, VendorRegistry()))
  finally:
    f.close()

proc placedByCoordinates(dir, name: string; starts: openArray[int]): RecordingFacts =
  ## One receiver of a SEG-Y file with group coordinates and no line or point, whose channel
  ## number goes up from trace to trace.
  createDir(dir)
  let path = dir / (name & ".sgy")
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for i, first in starts:
    var k = initTraceKeys()
    k.status = tsLive
    k.record = float64(i + 1)
    k.channel = float64(i + 1)
    k.intervalUs = 2000
    k.t0Ms = 0
    k.time = BaseS + float64(first) * DtMs / 1000
    k.rcvX = 512_300
    k.rcvY = 6_401_200
    w.writeTrace(k, newSeq[float32](1000))
  discard w.close()
  var f = openSeismic(path, keys = true)
  try:
    result = describeRecording(planRecording(addr f, path, DtMs, VendorRegistry()))
  finally:
    f.close()

proc shots(stations: int; starts: openArray[int]): seq[Spec] =
  ## A shot after shot, every station each time, in file order.
  for first in starts:
    for r in 0 ..< stations: result.add spec(r, first)

proc main*() =
  let dir = getTempDir() / "trecording"
  removeDir(dir)

  block continuous_abutting:
    let f = factsOf(dir, "abut", [spec(0, 0), spec(0, 1000), spec(0, 2000),
      spec(1, 0), spec(1, 1000), spec(1, 2000)])
    doAssert f.ready and f.kind == rkReceiverContinuous, $f
    doAssert f.components == 2 and f.stations == 2 and f.segments == 6, $f
    doAssert f.boundaries == 4 and f.abutting == 4 and f.irregular == 0, $f
    doAssert abs(f.firstTime - BaseS) < 1e-6 and abs(f.lastTime - (BaseS + 6.0)) < 1e-6, $f
    doAssert f.isContinuousGather and cutRefusal(f) == ""
    doAssert kindWords(f.kind) == "continuous receiver gather"

  block one_late_start_is_not_continuous:
    # no variance: a start 150 samples (0.3 s) late makes the file time sliced
    let f = factsOf(dir, "gap", [spec(0, 0), spec(0, 1000), spec(0, 2150), spec(0, 3150)])
    doAssert f.kind == rkReceiverSliced and f.irregular == 1 and f.abutting == 2, $f
    doAssert f.slicedWhy == swOffStep and f.offTrace == 3, $f
    doAssert cutRefusal(f) == "This file is a time-sliced receiver gather, not a " &
      "continuous one. Trace 3 starts 2.3 s after the one before it; the traces are 2 s " &
      "long, so it is not a whole number of trace lengths later.", cutRefusal(f)

  block continuous_after_a_box_off_for_an_hour:
    # 60 s traces starting at minutes 0, 1, 2 and 70
    let f = factsOf(dir, "hour", [spec(0, 0), spec(0, 30000), spec(0, 60000),
      spec(0, 2_100_000)], n = 30000)
    doAssert f.kind == rkReceiverContinuous and f.skips == 1 and f.missingSegments == 67, $f
    doAssert f.abutting == 2 and f.irregular == 0, $f
    doAssert skipWords(f.skips, f.missingSegments) == "The recorder did not record for " &
      "67 segments (in 1 place); those times are written as zeros."

  block continuous_with_skipped_segments:
    let f = factsOf(dir, "skips", [spec(0, 0), spec(0, 4000), spec(0, 5000),
      spec(0, 6000), spec(0, 47000), spec(0, 48000)])
    doAssert f.kind == rkReceiverContinuous and f.skips == 2 and f.missingSegments == 43, $f
    doAssert f.irregular == 0 and f.abutting == 3, $f
    doAssert skipWords(f.skips, f.missingSegments) == "The recorder did not record for " &
      "43 segments (in 2 places); those times are written as zeros."

  block continuous_repeating_data_at_the_ends:
    # 60.02 s traces every 60 s
    var specs: seq[Spec]
    for i in 0 ..< 5: specs.add spec(0, i * 30000)
    let f = factsOf(dir, "repeat", specs, n = 30010)
    doAssert f.kind == rkReceiverContinuous and f.abutting == 4 and f.uncovered == 0, $f

  block continuous_repeating_five_percent:
    var specs: seq[Spec]
    for i in 0 ..< 5: specs.add spec(0, i * 950)
    let f = factsOf(dir, "five", specs)
    doAssert f.kind == rkReceiverContinuous and f.abutting == 4, $f

  block sliced_overlapping_thirty_percent:
    var specs: seq[Spec]
    for i in 0 ..< 5: specs.add spec(0, i * 700)
    let f = factsOf(dir, "thirty", specs)
    doAssert f.kind == rkReceiverSliced and f.irregular == 4 and f.abutting == 0, $f
    doAssert f.slicedWhy == swOffStep and f.offTrace == 2, $f
    doAssert cutRefusal(f) == "This file is a time-sliced receiver gather, not a " &
      "continuous one. Trace 2 starts 1.4 s after the one before it; the traces are 2 s " &
      "long, so it is not a whole number of trace lengths later.", cutRefusal(f)
    doAssert "overlap" notin cutRefusal(f)
    doAssert kindWords(f.kind) == "time-sliced receiver gather"

  block sliced_every_half_second_of_thirty:
    var specs: seq[Spec]
    for i in 0 ..< 6: specs.add spec(0, i * 250)
    let f = factsOf(dir, "dense", specs, n = 15000)
    doAssert f.kind == rkReceiverSliced and f.irregular == 5 and f.abutting == 0, $f
    doAssert f.slicedWhy == swOffStep, $f
    doAssert cutRefusal(f).endsWith("Trace 2 starts 0.5 s after the one before it; the " &
      "traces are 30 s long, so it is not a whole number of trace lengths later."),
      cutRefusal(f)

  block sliced_every_ten_seconds_of_six_names_the_trace:
    var specs: seq[Spec]
    for i in 0 ..< 5: specs.add spec(0, i * 5000)
    let f = factsOf(dir, "dead", specs, n = 3000)
    doAssert f.kind == rkReceiverSliced and f.abutting == 0 and f.irregular == 4, $f
    doAssert f.slicedWhy == swOffStep and f.offTrace == 2, $f
    doAssert cutRefusal(f) == "This file is a time-sliced receiver gather, not a " &
      "continuous one. Trace 2 starts 10 s after the one before it; the traces are 6 s " &
      "long, so it is not a whole number of trace lengths later.", cutRefusal(f)
    doAssert "every" notin cutRefusal(f)

  block a_trace_shorter_than_the_step_leaves_dead_time:
    var traces: seq[tuple[first, n: int]]
    for i in 0 ..< 5: traces.add (i * 1000, (if i == 2: 800 else: 1000))
    let f = lengthsOf(dir, "short", traces)
    doAssert f.kind == rkReceiverSliced and f.slicedWhy == swOffStep and f.uncovered == 1, $f
    doAssert f.abutting == 4 and f.offTrace == 3, $f
    doAssert cutRefusal(f) == "This file is a time-sliced receiver gather, not a " &
      "continuous one. Trace 3 is 1.6 s long; the others are 2 s.", cutRefusal(f)

  block a_trace_far_longer_than_the_step_overlaps:
    var traces: seq[tuple[first, n: int]]
    for i in 0 ..< 5: traces.add (i * 1000, (if i == 4: 1300 else: 1000))
    let f = lengthsOf(dir, "long", traces)
    doAssert f.kind == rkReceiverSliced and f.slicedWhy == swOffStep and f.offTrace == 5, $f
    doAssert cutRefusal(f).endsWith("Trace 5 is 2.6 s long; the others are 2 s."),
      cutRefusal(f)

  block traces_of_1000_500_500_1000_1000_name_the_short_one_by_its_length:
    let f = lengthsOf(dir, "halves", [(0, 1000), (1000, 500), (1500, 500), (2000, 1000),
      (3000, 1000)])
    doAssert f.kind == rkReceiverSliced and f.slicedWhy == swOffStep and f.offTrace == 2, $f
    doAssert cutRefusal(f) == "This file is a time-sliced receiver gather, not a " &
      "continuous one. Trace 2 is 1 s long; the others are 2 s.", cutRefusal(f)
    doAssert "overlap" notin cutRefusal(f)

  block a_step_of_999_or_950_with_every_other_trace_missing_is_measured_but_not_continuous:
    # the step is found (every boundary two steps), but no trace follows on another
    for step in [999, 950, 1000]:
      var specs: seq[Spec]
      for k in [0, 2, 4, 6]: specs.add spec(0, k * step)
      let f = factsOf(dir, "every" & $step, specs)
      doAssert f.kind == rkReceiverSliced and f.skips == 3 and f.irregular == 0, $f
      doAssert f.missingSegments == 3 and f.abutting == 0, $f
      doAssert f.slicedWhy == swNoFollow and f.fewestSteps == 2, $f
      # one trace that follows on the one before it makes it continuous
      specs.add spec(0, 7 * step)
      let one = factsOf(dir, "everyOne" & $step, specs)
      doAssert one.kind == rkReceiverContinuous and one.abutting == 1 and one.skips == 3, $one

  block two_components_of_a_station_at_different_single_starts:
    let f = factsOf(dir, "twoStarts", [spec(0, 0, 0), spec(0, 1300, 1)])
    doAssert f.kind == rkReceiverSliced and f.slicedWhy == swOffStep and f.offTrace == 2, $f
    doAssert cutRefusal(f) == "This file is a time-sliced receiver gather, not a " &
      "continuous one. Trace 2 starts 2.6 s after the one before it; the traces are 2 s " &
      "long, so it is not a whole number of trace lengths later.", cutRefusal(f)
    doAssert "same start time" notin cutRefusal(f)

  block a_trace_one_sample_short_still_covers_the_step:
    var traces: seq[tuple[first, n: int]]
    for i in 0 ..< 5: traces.add (i * 1000, (if i == 2: 999 else: 1000))
    let f = lengthsOf(dir, "oneShort", traces)
    doAssert f.kind == rkReceiverContinuous and f.abutting == 4 and f.uncovered == 0, $f

  block dropouts_at_most_boundaries_are_still_continuous:
    # starts at 0, 1, 3, 5, 7 and 9 trace lengths: the step is one length
    var specs: seq[Spec]
    for k in [0, 1, 3, 5, 7, 9]: specs.add spec(0, k * 1000)
    let f = factsOf(dir, "dropouts", specs)
    doAssert f.kind == rkReceiverContinuous and f.abutting == 1 and f.skips == 4, $f
    doAssert f.missingSegments == 4 and f.irregular == 0, $f

  block two_of_five_starts_half_a_length_off:
    var specs: seq[Spec]
    for first in [0, 1000, 2500, 3500, 5000, 6000]: specs.add spec(0, first)
    let f = factsOf(dir, "half", specs)
    doAssert f.kind == rkReceiverSliced and f.irregular == 2 and f.abutting == 3, $f
    doAssert f.slicedWhy == swOffStep and f.offTrace == 3, $f
    doAssert abs(f.offSeconds - 3.0) < 1e-9, $f
    doAssert cutRefusal(f).startsWith("This file is a time-sliced receiver gather, not a " &
      "continuous one. Trace 3 starts 3 s after"), cutRefusal(f)

  block sliced_with_irregular_starts:
    let f = factsOf(dir, "irregular", [spec(0, 0), spec(0, 1300), spec(0, 2750),
      spec(0, 4150), spec(0, 5700)])
    doAssert f.kind == rkReceiverSliced and f.irregular == 4, $f
    doAssert f.slicedWhy == swOffStep and f.offTrace == 2, $f
    doAssert cutRefusal(f).endsWith("Trace 2 starts 2.6 s after the one before it; the " &
      "traces are 2 s long, so it is not a whole number of trace lengths later."),
      cutRefusal(f)

  block shot_gather_of_three_components:
    var specs: seq[Spec]
    for r in 0 ..< 8:
      for c in 0 ..< 3: specs.add spec(r, 0, c)
    let f = factsOf(dir, "shot", specs)
    doAssert f.kind == rkShotGather and f.stations == 8 and f.components == 24, $f
    doAssert not f.isContinuousGather
    doAssert cutRefusal(f) == "This file is a shot gather (the receiver changes from trace " &
      "to trace), not a continuous receiver gather."
    doAssert kindWords(f.kind) == "shot gather"

  block two_stations_of_one_trace_are_a_shot_gather:
    let f = factsOf(dir, "long", [spec(0, 0), spec(1, 0)])
    doAssert f.kind == rkShotGather, $f

  block one_station_one_segment_is_a_receiver_gather:
    let f = factsOf(dir, "one", [spec(0, 0)])
    doAssert f.kind == rkReceiverContinuous and f.boundaries == 0, $f

  block stations_of_one_and_of_several_segments_fall_through:
    # not a shot gather (one station has two segments); continuous by the test
    let f = factsOf(dir, "mixed", [spec(0, 0), spec(0, 1000), spec(1, 0), spec(2, 0)])
    doAssert f.kind == rkReceiverContinuous and f.stations == 3, $f

  block same_start_time_for_many_traces:
    # twelve traces of one station and component, all starting together
    var specs: seq[Spec]
    for i in 0 ..< 12: specs.add spec(0, 0)
    let f = factsOf(dir, "same", specs)
    doAssert f.kind == rkReceiverSliced and f.slicedWhy == swSameStart, $f
    doAssert cutRefusal(f) == "This file is a time-sliced receiver gather, not a " &
      "continuous one. Every trace of a component carries the same start time, so the start " &
      "times could not be read. A recorder that keeps each trace's start time in its own " &
      "trace header extension needs a vendor header map that names that field.", cutRefusal(f)

  block distinct_components_at_one_start_are_one_continuous_segment:
    # one Z, one X, one Y and one hydrophone of one station, one start
    for n in [2, 3, 4]:
      var specs: seq[Spec]
      for c in 0 ..< n: specs.add spec(0, 0, c)
      let f = factsOf(dir, "channels" & $n, specs)
      doAssert f.kind == rkReceiverContinuous and f.slicedWhy == swNone, $f
      doAssert f.segments == n and f.components == n and f.isContinuousGather, $f
      doAssert cutRefusal(f) == "", cutRefusal(f)

  block like_components_at_one_start_are_not_continuous:
    # two traces of one component type at one station and start: segments or channels?
    let f = factsOf(dir, "like", [spec(0, 0, 0), spec(0, 0, 1), spec(0, 0, 1, extra = 1)])
    doAssert f.kind == rkReceiverSliced and f.slicedWhy == swSameStart, $f
    doAssert f.segments == 3 and f.components == 3, $f
    doAssert cutRefusal(f) == "This file is a time-sliced receiver gather, not a " &
      "continuous one. Every trace of a component carries the same start time, so the start " &
      "times could not be read. A recorder that keeps each trace's start time in its own " &
      "trace header extension needs a vendor header map that names that field.", cutRefusal(f)

  block station_less_shot_record_is_a_shot_gather:
    var specs: seq[Spec]
    for c in 0 ..< 6: specs.add spec(c, 0, 0, stationed = false)
    let f = factsOf(dir, "noStation", specs)
    doAssert f.kind == rkShotGather and f.slicedWhy == swNone, $f
    doAssert not f.isContinuousGather and cutRefusal(f).startsWith("This file is a shot gather")

  block one_station_six_channel_record_is_a_receiver_gather:
    var specs: seq[Spec]
    for c in 0 ..< 6: specs.add spec(0, 0, c, extra = c mod 2)
    let f = factsOf(dir, "sixChannels", specs)
    doAssert f.kind == rkReceiverContinuous, $f

  block receivers_come_in_the_order_the_file_shows_them:
    # stations 102 then 101; at each a geophone Z (comp 2), a hydrophone (0), a geophone X (1)
    var specs: seq[Spec]
    for seg in [0, 1, 3]: # a dropout after the second
      for rcv in [1, 0]:
        for comp in [2, 0, 1]: specs.add spec(rcv, seg * 1000, comp)
    let receivers = receiversOf(dir, "order", specs)
    for row in 0 ..< specs.len:
      doAssert receivers[row] == row mod 6, "row " & $row & ": " & $receivers

  block the_kind_follows_the_first_few_starts:
    # twelve traces, the tenth 150 samples late: the kind looks at the first KindStarts
    # starts and calls it continuous; the check of every start (the cut's) does not
    var specs: seq[Spec]
    for i in 0 ..< 12: specs.add spec(0, i * 1000 + (if i == 9: 150 else: 0))
    let few = factsOf(dir, "late", specs)
    doAssert KindStarts == 8
    doAssert few.kind == rkReceiverContinuous and few.boundaries == KindStarts - 1, $few
    let all = factsOf(dir, "late", specs, starts = AllStarts)
    doAssert all.kind == rkReceiverSliced and all.boundaries == 11 and all.irregular == 2, $all
    doAssert all.slicedWhy == swOffStep and all.offTrace == 10, $all
    # a late start among the first few is seen at once
    var early: seq[Spec]
    for i in 0 ..< 12: early.add spec(0, i * 1000 + (if i == 4: 150 else: 0))
    doAssert factsOf(dir, "early", early).kind == rkReceiverSliced

  block a_trace_that_follows_on_another_after_the_first_few_starts_is_seen:
    # every gap two trace lengths for the first KindStarts starts, then traces that follow on
    # each other: the kind looks on for one and says continuous, as the slice does
    var specs: seq[Spec]
    for i in 0 ..< KindStarts: specs.add spec(0, i * 2000)
    for i in 0 ..< 4: specs.add spec(0, (2 * KindStarts + i) * 1000)
    let late = factsOf(dir, "lateFollow", specs)
    doAssert late.kind == rkReceiverContinuous and late.abutting == 0, $late
    let sliced = factsOf(dir, "lateFollow", specs, starts = AllStarts)
    doAssert sliced.kind == rkReceiverContinuous and cutRefusal(sliced) == "", $sliced
    # two lengths apart to the end: time sliced, whatever is looked at
    var gaps: seq[Spec]
    for i in 0 ..< KindStarts + 4: gaps.add spec(0, i * 2000)
    for starts in [KindStarts, AllStarts]:
      let f = factsOf(dir, "allGaps", gaps, starts = starts)
      doAssert f.kind == rkReceiverSliced and f.slicedWhy == swNoFollow, $f

  block traces_sharing_a_start_are_the_components_of_one_segment:
    # the same receiver twice at each start: the step is compared with the next DIFFERENT start
    let f = factsOf(dir, "pairs", [spec(0, 0), spec(0, 0), spec(0, 1000), spec(0, 1000),
      spec(0, 2000), spec(0, 2000)])
    doAssert f.kind == rkReceiverContinuous and f.abutting == 2 and f.irregular == 0, $f
    doAssert f.boundaries == 2 and f.segments == 6, $f

  block facts_that_are_not_ready_are_not_a_shot_gather:
    doAssert cutRefusal(RecordingFacts()) == "No live trace with a start time."

  block one_live_trace_is_continuous:
    let f = factsOf(dir, "single", [spec(0, 0, 0, stationed = false)])
    doAssert f.kind == rkReceiverContinuous and f.segments == 1, $f

  block uneven_shots_of_many_stations_are_a_shot_gather:
    # 3 shots x 50 stations, the shots 1.3 and 2.4 s apart: every station has three segments
    # that are no step apart, but the receiver changes from trace to trace in the file
    let specs = shots(50, [0, 1300, 3700])
    for f in [factsOf(dir, "shots", specs), segyFacts(dir, "shotsy", specs)]:
      doAssert f.ready and f.kind == rkShotGather and f.slicedWhy == swOffStep, $f
      doAssert f.components == 50 and f.segments == 150, $f
      doAssert cutRefusal(f) == "This file is a shot gather (the receiver changes from trace " &
        "to trace), not a continuous receiver gather. Trace 51 starts 2.6 s after the one " &
        "before it; the traces are 2 s long, so it is not a whole number of trace lengths " &
        "later.", cutRefusal(f)

  block a_shot_gather_by_file_order_says_what_was_measured:
    # three receivers in time order, the second off the step once (at its fourth start): not
    # continuous, and the receiver changes at every trace: a shot gather, and the trace that
    # left the step is said
    var specs: seq[Spec]
    for i in 0 ..< 20:
      for r in 0 ..< 3: specs.add spec(r, i * 1000 + (if r == 1 and i >= 3: 333 else: 0))
    let f = factsOf(dir, "offonce", specs)
    doAssert f.kind == rkShotGather and f.slicedWhy == swOffStep and f.offTrace == 11, $f
    doAssert cutRefusal(f) == "This file is a shot gather (the receiver changes from trace " &
      "to trace), not a continuous receiver gather. Trace 11 starts 2.666 s after the one " &
      "before it; the traces are 2 s long, so it is not a whole number of trace lengths " &
      "later.", cutRefusal(f)

  block one_station_of_irregular_segments_is_time_sliced:
    var specs: seq[Spec]
    for i in 0 ..< 40: specs.add spec(0, i * 1000 + (i * i) mod 70)
    for f in [factsOf(dir, "irr1", specs), segyFacts(dir, "irr1y", specs)]:
      doAssert f.kind == rkReceiverSliced and f.slicedWhy == swOffStep, $f

  block two_stations_grouped_by_station_are_time_sliced:
    var specs: seq[Spec]
    for r in 0 ..< 2:
      for i in 0 ..< 20: specs.add spec(r, i * 1000 + (i * i) mod 70)
    for f in [factsOf(dir, "irr2", specs), segyFacts(dir, "irr2y", specs)]:
      doAssert f.kind == rkReceiverSliced, $f

  block continuous_stations_stay_continuous_in_any_file_order:
    # every station on the step, the file ordered by time: the receiver changes at every trace
    let specs = shots(5, [0, 1000, 2000, 3000])
    for f in [factsOf(dir, "ordered", specs), segyFacts(dir, "orderedy", specs)]:
      doAssert f.kind == rkReceiverContinuous, $f

  block uncoded_channels_of_a_station_are_one_segment:
    for rev2 in [false, true]:
      let f = uncodedShots(dir, "uncoded" & $rev2, rev2)
      doAssert f.ready and f.kind == rkShotGather,
        "uncoded shots, Rev " & (if rev2: "2.1" else: "3") & ": " & $f.kind

  block a_receiver_is_placed_by_its_coordinates_before_its_channel:
    var starts: seq[int] = @[]
    for i in 0 ..< 40: starts.add i * 3000 + (i * i) mod 70
    let f = placedByCoordinates(dir, "coords", starts)
    doAssert f.ready and f.kind == rkReceiverSliced, "coordinates: " & $f.kind
    doAssert f.stations == 1, $f

  echo "trecording ok"
  removeDir(dir)

when isMainModule:
  main()
