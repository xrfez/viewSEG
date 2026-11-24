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
## sample short refused (floats instead of samples); a repeat of 5% refused.

import std/[assertions, math, os, strutils]
import parseSEG
import viewSEG/core/[cutgather, recordingkind, vendormaps]
import viewSEG/view/recordingwords

const
  BaseS = 1_772_323_200.0 # 2026-03-01T00:00:00 UTC
  DtMs = 2.0

type Spec = tuple[rcv, first, comp: int, stationed: bool]

func spec(rcv, first: int; comp = 0; stationed = true): Spec =
  (rcv, first, comp, stationed)

proc factsOf(dir, name: string; specs: openArray[Spec]; n = 1000): RecordingFacts =
  createDir(dir)
  let path = dir / (name & ".sgd")
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: n))
  for i, s in specs:
    var k = initTraceKeys()
    k.status = tsLive
    k.record = float64(i + 1)
    k.channel = float64(s.rcv * 4 + s.comp + 1)
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
  var f = openSeismic(path)
  var plan: RecordingPlan
  try:
    plan = planRecording(addr f, path, DtMs, VendorRegistry())
    result = describeRecording(plan)
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
    doAssert f.slicedWhy == swShort and f.offTrace == 3, $f
    doAssert cutRefusal(f) == "This file is a time-sliced receiver gather, not a " &
      "continuous one. Its traces are 2 s long but start every 2.3 s, so there is dead " &
      "time between them.", cutRefusal(f)

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
    doAssert f.slicedWhy == swOverlap and f.offTrace == 2, $f
    doAssert cutRefusal(f) == "This file is a time-sliced receiver gather, not a " &
      "continuous one. Trace 2 overlaps a neighbouring trace by 0.6 s.", cutRefusal(f)
    doAssert kindWords(f.kind) == "time-sliced receiver gather"

  block sliced_every_half_second_of_thirty:
    var specs: seq[Spec]
    for i in 0 ..< 6: specs.add spec(0, i * 250)
    let f = factsOf(dir, "dense", specs, n = 15000)
    doAssert f.kind == rkReceiverSliced and f.irregular == 5 and f.abutting == 0, $f
    doAssert f.slicedWhy == swOverlap, $f

  block sliced_every_ten_seconds_of_six_names_the_trace:
    var specs: seq[Spec]
    for i in 0 ..< 5: specs.add spec(0, i * 5000)
    let f = factsOf(dir, "dead", specs, n = 3000)
    doAssert f.kind == rkReceiverSliced and f.abutting == 0 and f.irregular == 4, $f
    doAssert f.slicedWhy == swIrregular and f.offTrace == 2, $f
    doAssert cutRefusal(f) == "This file is a time-sliced receiver gather, not a " &
      "continuous one. Trace 2 starts 2 s off a whole number of steps after the one " &
      "before it (the traces start every 6 s).", cutRefusal(f)

  block a_trace_shorter_than_the_step_leaves_dead_time:
    var traces: seq[tuple[first, n: int]]
    for i in 0 ..< 5: traces.add (i * 1000, (if i == 2: 800 else: 1000))
    let f = lengthsOf(dir, "short", traces)
    doAssert f.kind == rkReceiverSliced and f.slicedWhy == swShort and f.uncovered == 1, $f
    doAssert f.abutting == 4 and f.offTrace == 3, $f
    doAssert cutRefusal(f) == "This file is a time-sliced receiver gather, not a " &
      "continuous one. Its traces are 1.6 s long but start every 2 s, so there is dead " &
      "time between them.", cutRefusal(f)

  block a_trace_far_longer_than_the_step_overlaps:
    var traces: seq[tuple[first, n: int]]
    for i in 0 ..< 5: traces.add (i * 1000, (if i == 4: 1300 else: 1000))
    let f = lengthsOf(dir, "long", traces)
    doAssert f.kind == rkReceiverSliced and f.slicedWhy == swOverlap and f.offTrace == 5, $f
    doAssert cutRefusal(f).endsWith("Trace 5 overlaps a neighbouring trace by 0.6 s."),
      cutRefusal(f)

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
    doAssert f.slicedWhy == swIrregular and f.offTrace == 3, $f
    doAssert abs(f.offSeconds - 1.0) < 1e-9, $f
    doAssert cutRefusal(f).startsWith("This file is a time-sliced receiver gather, not a " &
      "continuous one. Trace 3 starts 1 s off"), cutRefusal(f)

  block sliced_with_irregular_starts:
    let f = factsOf(dir, "irregular", [spec(0, 0), spec(0, 1300), spec(0, 2750),
      spec(0, 4150), spec(0, 5700)])
    doAssert f.kind == rkReceiverSliced and f.irregular == 4, $f
    doAssert f.slicedWhy == swShort, $f

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
      "continuous one. Every trace carries the same start time, so their own start times are " &
      "not in the headers viewSEG reads: they may be in a header that a vendor header map " &
      "has to describe.", cutRefusal(f)

  block one_segment_per_receiver_is_no_proof_of_continuity:
    # three channels of one station starting together: a receiver gather, not continuous,
    # whatever the channel count
    for n in [2, 3, 6]:
      var specs: seq[Spec]
      for c in 0 ..< n: specs.add spec(0, 0, c)
      let f = factsOf(dir, "channels" & $n, specs)
      doAssert f.kind == rkReceiverSliced and f.slicedWhy == swSameStart, $f
      doAssert f.segments == n and f.components == n, $f
      doAssert "Every trace carries the same start time" in cutRefusal(f), cutRefusal(f)
      doAssert "vendor header map" in cutRefusal(f), cutRefusal(f)

  block station_less_shot_record_is_a_shot_gather:
    var specs: seq[Spec]
    for c in 0 ..< 6: specs.add spec(c, 0, 0, stationed = false)
    let f = factsOf(dir, "noStation", specs)
    doAssert f.kind == rkShotGather and f.slicedWhy == swNone, $f
    doAssert not f.isContinuousGather and cutRefusal(f).startsWith("This file is a shot gather")

  block one_station_six_channel_record_is_a_receiver_gather:
    var specs: seq[Spec]
    for c in 0 ..< 6: specs.add spec(0, 0, c)
    let f = factsOf(dir, "sixChannels", specs)
    doAssert f.kind == rkReceiverSliced and f.slicedWhy == swSameStart, $f
    doAssert cutRefusal(f).startsWith("This file is a time-sliced receiver gather")

  block one_live_trace_is_continuous:
    let f = factsOf(dir, "single", [spec(0, 0, 0, stationed = false)])
    doAssert f.kind == rkReceiverContinuous and f.segments == 1, $f

  echo "trecording ok"
  removeDir(dir)

when isMainModule:
  main()
