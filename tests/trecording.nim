## What a file is as a recording (`describeRecording`): the verdict the cut
## goes by and the sentences that refuse a file. Files are built here: SEG-Y,
## 2 ms, a trace per `Spec` (receiver, first sample, length, source point).
##
## Seen to fail with a deliberate fault: the sources not compared (the sliced
## gather with overlapping times was `rkContinuous`); the heavy overlap not counted
## (the dense file with no source was `rkContinuous`); gaps counted as abutting
## (the file of five separate records was `rkContinuous`); the single-trace
## rule reading `<` 60 s as long (a 4 s file was accepted).

import std/[assertions, math, os, strutils]
import parseSEG
import viewSEG/core/[cutgather, recordingkind, vendormaps]

const
  BaseS = 1_772_323_200.0 # 2026-03-01T00:00:00 UTC
  DtMs = 2.0

type Spec = tuple[rcv, first, n: int; source: float64]

func spec(rcv, first, n: int; source = NaN): Spec =
  (rcv, first, n, source)

proc factsOf(dir, name: string; specs: openArray[Spec]): RecordingFacts =
  createDir(dir)
  let path = dir / (name & ".sgy")
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for s in specs:
    var k = initTraceKeys()
    k.status = tsLive
    k.record = 1
    k.channel = float64(s.rcv + 1)
    k.intervalUs = 2000
    k.t0Ms = 0
    k.time = BaseS + float64(s.first) * DtMs / 1000
    k.rcvLine = 1
    k.rcvPoint = float64(s.rcv + 1)
    k.srcPoint = s.source
    var samples = newSeq[float32](s.n)
    for j in 0 ..< s.n: samples[j] = float32(s.first + j)
    w.writeTrace(k, samples)
  discard w.close()
  var f = openSeismic(path)
  var plan: RecordingPlan
  try:
    plan = planRecording(addr f, path, DtMs, VendorRegistry())
    result = describeRecording(plan)
  finally:
    f.close()

proc main*() =
  let dir = getTempDir() / "trecording"
  removeDir(dir)

  block continuous_abutting:
    let f = factsOf(dir, "abut", [spec(0, 0, 3000), spec(0, 3000, 3000), spec(0, 6000, 3000),
      spec(1, 0, 3000), spec(1, 3000, 3000), spec(1, 6000, 3000)])
    doAssert f.ready and f.kind == rkContinuous, $f
    doAssert f.components == 2 and f.stations == 2 and f.segments == 6, $f
    doAssert f.boundaries == 4 and f.abutting == 4 and f.gapped == 0, $f
    doAssert abs(f.firstTime - BaseS) < 1e-6 and abs(f.lastTime - (BaseS + 18.0)) < 1e-6, $f
    doAssert cutRefusal(f) == ""

  block continuous_one_gap:
    let f = factsOf(dir, "gap", [spec(0, 0, 3000), spec(0, 3000, 3000), spec(0, 6150, 3000),
      spec(0, 9150, 3000)])
    doAssert f.kind == rkContinuous and f.gapped == 1 and f.abutting == 2, $f

  block continuous_same_source:
    let f = factsOf(dir, "same", [spec(0, 0, 3000, 5), spec(0, 3000, 3000, 5),
      spec(0, 6000, 3000, 5)])
    doAssert f.kind == rkContinuous and f.sourcePoints == 1, $f

  block continuous_overlapping_no_source:
    let f = factsOf(dir, "over", [spec(0, 0, 3000), spec(0, 2950, 3000), spec(0, 5900, 3000)])
    doAssert f.kind == rkContinuous and f.overlapping == 2, $f

  block shot_record:
    var specs: seq[Spec]
    for r in 0 ..< 8: specs.add spec(r, 0, 2000)
    let f = factsOf(dir, "shot", specs)
    doAssert f.kind == rkShotRecord and f.components == 8, $f
    doAssert cutRefusal(f) ==
      "This file is a shot record (every receiver has one trace), not a continuous recording."

  block one_long_trace_per_receiver:
    let f = factsOf(dir, "long", [spec(0, 0, 31000), spec(1, 0, 31000)])
    doAssert f.kind == rkContinuous and f.longest > LongTraceSeconds, $f

  block sliced_by_gaps:
    let f = factsOf(dir, "gaps", [spec(0, 0, 1000), spec(0, 3000, 1000), spec(0, 6000, 1000),
      spec(0, 9000, 1000), spec(0, 12000, 1000)])
    doAssert f.kind == rkSlicedGather and f.slicedBy == sbGaps and f.gapped == 4, $f
    doAssert cutRefusal(f) == "This recording is already cut into separate records " &
      "(gaps at 4 of 4 segment boundaries), not continuous.", cutRefusal(f)

  block sliced_by_sources_with_overlapping_times:
    # a trace every 0.5 s of 4 s: the times overlap, the shots differ
    let f = factsOf(dir, "shots", [spec(0, 0, 2000, 101), spec(0, 250, 2000, 102),
      spec(0, 500, 2000, 103), spec(0, 750, 2000, 104)])
    doAssert f.kind == rkSlicedGather and f.slicedBy == sbSources, $f
    doAssert f.overlapping == 3 and f.sourcePoints == 4, $f
    doAssert cutRefusal(f) == "This file already holds one trace per shot (the traces carry " &
      "4 different source points), so it is not a continuous recording."
  block sliced_by_overlap_without_sources:
    # a trace every 0.5 s of 30 s, the keys carry no source
    var specs: seq[Spec]
    for i in 0 ..< 6: specs.add spec(0, i * 250, 15000)
    let f = factsOf(dir, "dense", specs)
    doAssert f.kind == rkSlicedGather and f.slicedBy == sbOverlap, $f
    doAssert f.heavy == 5 and f.boundaries == 5, $f
    doAssert cutRefusal(f) == "This file's traces mostly cover the same time as their " &
      "neighbours (5 of 5 overlap by more than half), as records cut by shot do, so it is " &
      "not a continuous recording.", cutRefusal(f)

  block continuous_repeating_a_few_samples:
    var specs: seq[Spec]
    for i in 0 ..< 5: specs.add spec(0, i * 2990, 3000)
    let f = factsOf(dir, "repeat", specs)
    doAssert f.kind == rkContinuous and f.overlapping == 4 and f.heavy == 0, $f

  echo "trecording ok"
  removeDir(dir)

when isMainModule:
  main()
