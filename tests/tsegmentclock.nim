## Where a continuous recording's segments start, read from the trace headers
## through a vendor map (`segmentClock`), and the cut that uses it. The
## recording is a SEG-D Rev 3 record of six traces of 40 samples at 2 ms, made
## by a made-up manufacturer (code 77): every trace is the same receiver
## (line 100, point 101) and has the record's one general-header time, its
## channel is its trace number, and a vendor block (type 0xB0) holds its own
## start time as a 64-bit count of microseconds. Trace i holds the values
## i * 40 + j, so a sample names its instant. No Rev 2 writer is available,
## so Rev 3 stands in: the trace-header vendor block is the same code path.
##
## Seen to fail with a deliberate fault: the cut's streams made from the keys
## with the clock unused ("components 6"); "us GPS" read as UTC ("start of 0:
## 1456358418.0").

import std/[algorithm, assertions, math, options, os, strutils]
import parseSEG
import parseSEG/io/diskio
import parseSEG/segd/blocks
import processSEG
import processSEG/continuous/slice
import viewSEG/core/[cutgather, cutgatherjobs, edits, jobs, outputjobs, panels, recordingkind,
  segmentclock, shotlog, state, vendormaps]
import utils/[fixtures, waiting]

const
  Segments = 6
  SegLen = 40
  DtUs = 2000'i64
  BaseUs = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC
  Leap = 18'i64                      # GPS minus UTC in 2026
  GpsEpochUs = 315_964_800_000_000'i64

func gpsOf(utcUs: int64): int64 =
  utcUs - GpsEpochUs + Leap * 1_000_000

func segStart(i: int): int64 =
  BaseUs + int64(i) * SegLen * DtUs

func mapText(unit: string): string =
  "(.nif27)\n(vendormap \"clock-test\" (version 1) (match (format segd) (rev 3.0 3.1) " &
    "(manufacturer 77))\n  (target (kind block) (type 0xB0) (where traceHeader) " &
    "(name vendorClock)\n    (field firstSampleTime (at 1) (enc i64) (sentinel 0) " &
    "(unit \"" & unit & "\"))))\n"

proc registryOf(dir, unit: string): VendorRegistry =
  createDir(dir)
  writeFile(dir / "clock.nif", mapText(unit))
  let load = loadVendorFolders(@[VendorFolder(dir: dir, origin: voProject)])
  doAssert load.registry.maps.len == 1, $load.problems
  load.registry

proc blk(t: uint8): seq[byte] =
  result = newSeq[byte](32)
  result[31] = t

proc makeRecording(path: string; raw: openArray[int64]; noStation = false;
    sensor: openArray[uint8] = []; points: openArray[int32] = []) =
  ## One record, a trace per entry of `raw`: its vendor start-time count
  ## (0: the absent sentinel).
  let fmt = sd8058
  var r = SegdRecord(layout: slRev3, format: some(fmt),
    revision: SegdRevision(major: 3, minor: 0))
  r.generalBlocks.add blk(0x11)
  r.gh1 = SegdGeneralHeader1(fileNumber: 7, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: 3, julianDay: 60, hour: 0, minute: 0, second: 0,
    manufacturerCode: 77, baseScanInterval16: 32, recordType: 8,
    recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 1)
  let endUs = int32(DtUs * (SegLen - 1))
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 7, revisionMajor: 3,
    extRecordLength: uint32(endUs), blockType: 2)
  r.gh3 = SegdGeneralHeader3(timeZero: BaseUs, blockType: 3)
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[
    SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1, channelType: 0x10,
      endTime: endUs, numSamples: SegLen, descaleMultiplier: 1.0, channelsInSet: uint32(raw.len),
      samplingInterval: uint32(DtUs), traceHeaderExtensions: 2, verticalStack: 1,
      blockType1: 0x30, blockType2: 0x31, blockType3: 0x32)])]
  var traces: seq[SegdTrace]
  for tn in 1 .. raw.len:
    var t = SegdTrace(layout: slRev3, index: traces.len, numSamples: SegLen)
    t.header = SegdTraceHeader(fileNumber: 7, scanTypeNumber: 1, channelSetNumber: 1,
      traceNumber: tn, traceHeaderExtensions: 2)
    t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(
      receiverLineNumber: (if noStation: 0 else: 100),
      receiverPointNumber: (if noStation: 0 elif points.len > 0: points[tn - 1] else: 101),
      receiverPointIndex: 1, numSamples: SegLen,
      sensorType: (if sensor.len > 0: sensor[tn - 1] else: 2'u8), blockType: 0x40)
    var vendor = blk(0xB0)
    for i in 0 .. 7: vendor[i] = byte((raw[tn - 1] shr (8 * (7 - i))) and 255)
    t.extensions = vendor
    var v = newSeq[float32](SegLen)
    for j in 0 ..< SegLen: v[j] = float32((tn - 1) * SegLen + j)
    t.samples = newSeq[byte](dataBytes(fmt, SegLen))
    encodeSamples(fmt, v, t.samples)
    traces.add t
  computeRev3Sizes(r, traces)
  r.traceCount = traces.len
  let sink = openDiskSink(path)
  try:
    let log = writeSegd(sink, SegdData(records: @[SegdRecordData(record: r, traces: traces)]))
    doAssert log.len == 0, $log
  finally:
    sink.close()

proc gpsStarts(): seq[int64] =
  for i in 0 ..< Segments: result.add gpsOf(segStart(i))

proc planOf(f: var SeismicFile; c: SegmentClock): SliceStreams =
  let meta = chunkMeta(f, 0 ..< f.len, dtMs = 2.0)
  if c.fromHeaders: initSliceStreams(meta, c.times, c.receivers) else: initSliceStreams(meta)

proc samplesOf(f: SeismicFile; trace: int): seq[float32] =
  let x = f.readTraces(trace .. trace)
  result.setLen x.shape[1]
  for j in 0 ..< result.len: result[j] = x[0, j]

type Ran = tuple[st: JobState; res: CutResult; error: string]

proc runCut(jobs: Jobs; f: var SeismicFile; source, dest: string; shots: CutShots;
    opts: CutOptions): Ran =
  let sink = CutSink()
  let id = jobs.submit(cutGatherSpec(source, dest),
    cutGatherWork(addr f, source, dest, shots, opts, sink))
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the cut did not finish"
  let info = jobs.info(id).get
  (info.state, sink.result, info.error)

proc shotsAt(offsetsUs: openArray[int64]): CutShots =
  var text = ""
  for i, o in offsetsUs: text.add $(101 + i) & "," & $(BaseUs + o) & "\n"
  var m = initShotLogMap()
  m.hasHeader = false
  m.roles = @[crFileNumber, crUtcMicros]
  shotsInTime(shots(parseShotLog(text, m), m).rows)

proc main*() =
  withFixtures fx:
    let rec = fx.dir / "rec"
    createDir(rec)
    let gps = registryOf(fx.dir / "gps", "us GPS")
    let utc = registryOf(fx.dir / "utc", "us UTC")
    let good = rec / "good.sgd"
    makeRecording(good, gpsStarts())
    var f = openSeismic(good, keys = true)
    defer: f.close()
    doAssert f.len == Segments
    for i in 1 ..< Segments:
      doAssert f.traceKeys(i).time == f.traceKeys(0).time, "the keys' time differs"

    block six_segments_are_one_receiver:
      let c = segmentClock(f, gps)
      doAssert c.fromHeaders and c.leftOut == 0
      for i in 0 ..< Segments:
        doAssert c.times[i] == toPosixSeconds(segStart(i)), "start of " & $i & ": " & $c.times[i]
        doAssert c.receivers[i] == 0, "receivers " & $c.receivers
      let streams = planOf(f, c)
      doAssert streams.receiverCount == 1, "receivers " & $streams.receiverCount
      doAssert streams.overlaps.len == 0
      let window = SliceWindow(startMs: -20.0, lengthMs: 40.0)
      let shot = initSliceShot(toPosixSeconds(BaseUs + 90_000), 1.0)
      let plan = planSlices(streams, [shot], window, soShotRecords, saNearest)
      doAssert plan.receiverCount == 1 and plan.timingIssues.len == 0

    block the_dialog_facts_follow_the_clock:
      # what the dialog shows: one component, one recording, not six receivers
      let with = describeRecording(planRecording(addr f, good, 2.0, gps))
      doAssert with.ready and with.kind == rkReceiverContinuous, $with
      doAssert with.components == 1 and with.segments == Segments and with.boundaries == 5 and
        with.abutting == 5, $with
      doAssert abs(with.lastTime - with.firstTime - 6 * 40 * 0.002) < 1e-6, $with
      let without = describeRecording(planRecording(addr f, good, 2.0, VendorRegistry()))
      doAssert without.components == Segments and without.segments == Segments, $without

    block without_the_map_the_keys_are_used:
      let c = segmentClock(f, VendorRegistry())
      doAssert not c.fromHeaders and c.leftOut == 0 and c.times.len == 0
      doAssert planOf(f, c).receiverCount == Segments, "N receivers of one trace each"

    block gps_and_utc_differ_by_the_leap_seconds:
      let g = segmentClock(f, gps)
      let u = segmentClock(f, utc)
      doAssert u.fromHeaders
      let want = float64(GpsEpochUs - Leap * 1_000_000) / 1e6
      for i in 0 ..< Segments:
        doAssert abs((g.times[i] - u.times[i]) - want) < 1e-3,
          "start differs by " & $(g.times[i] - u.times[i]) & " s, not " & $want
      let raw = gpsStarts()[0]
      doAssert abs(u.times[0] - float64(raw) / 1e6) < 1e-6, "UTC is used as is"
      doAssert gpsMicrosToUtcMicros(raw) == BaseUs, "the leap seconds are 18"

    block a_trace_without_the_field_is_left_out:
      var raw = gpsStarts()
      raw[2] = 0
      let path = rec / "one-missing.sgd"
      makeRecording(path, raw)
      var g = openSeismic(path, keys = true)
      defer: g.close()
      let c = segmentClock(g, gps)
      doAssert c.fromHeaders and c.leftOut == 1, "left out " & $c.leftOut
      doAssert c.times[2].isNaN, "the time is NaN, not the keys' time"
      doAssert c.times[3] == toPosixSeconds(segStart(3))
      let streams = planOf(g, c)
      doAssert streams.untimed == @[2], "untimed " & $streams.untimed
      var none = gpsStarts()
      for v in none.mitems: v = 0
      let path2 = rec / "none.sgd"
      makeRecording(path2, none)
      var h = openSeismic(path2, keys = true)
      defer: h.close()
      let d = segmentClock(h, gps)
      doAssert not d.fromHeaders and d.leftOut == 0, "no trace had the field"

    block another_unit_or_a_wild_value_falls_back:
      let other = registryOf(fx.dir / "feet", "ft")
      let c = segmentClock(f, other)
      doAssert not c.fromHeaders, "a unit that is no time was used"
      var raw = gpsStarts()
      raw[1] = high(int64) - 5
      raw[4] = -3
      let path = rec / "wild.sgd"
      makeRecording(path, raw)
      var g = openSeismic(path, keys = true)
      defer: g.close()
      let d = segmentClock(g, gps)
      doAssert d.fromHeaders and d.leftOut == 2, "left out " & $d.leftOut

    block starts_closer_than_a_trace_are_an_overlap:
      # (equal starts are two channels now, not an overlap)
      var raw = gpsStarts()
      raw[3] = raw[2] + 20_000
      let path = rec / "overlap.sgd"
      makeRecording(path, raw)
      var g = openSeismic(path, keys = true)
      defer: g.close()
      let streams = planOf(g, segmentClock(g, gps))
      doAssert streams.receiverCount == 1 and streams.overlaps.len >= 1,
        "overlaps " & $streams.overlaps.len

    block the_cut_equals_the_model:
      # Shots at 90 ms and 250 ms: windows of 40 ms from 20 ms before, across
      # the boundaries at 80 ms and 240 ms. Fails when the clock is unused.
      let jobs = initJobs()
      let outDir = fx.dir / "out"
      createDir(outDir)
      let shots = shotsAt([90_000'i64, 250_000])
      let opts = initCutOptions(40.0, -20.0)
      publishVendors(gps)
      defer: publishVendors(VendorRegistry())
      let dest = outDir / "cut.sgd"
      let got = runCut(jobs, f, good, dest, shots, opts)
      doAssert got.st == jsDone, got.error & " / " & got.res.reason
      doAssert got.res.components == 1, "components " & $got.res.components
      doAssert got.res.segmentsFromHeaders and got.res.segmentsWithoutTime == 0
      doAssert "Segment times were read from the trace headers." in got.res.lines
      doAssert got.res.timingIssues == 0 and got.res.overlapsMismatched == 0
      var o = openSeismic(dest, keys = true)
      defer: o.close()
      doAssert o.len == 2
      for s in 0 .. 1:
        let shotUs = shots.shots[s].timeUs
        let zero = o.recordTimeZeroUs(s)
        doAssert zero.isSome and zero.get == shotUs, "time zero of record " & $s
        let g0 = int((shotUs - 20_000 - BaseUs + DtUs div 2) div DtUs)
        let got = samplesOf(o, s)
        doAssert got.len == 20
        for j in 0 ..< 20:
          doAssert got[j] == float32(g0 + j), "record " & $s & " sample " & $j & ": " &
            $got[j] & " vs " & $(g0 + j)

    block the_result_counts_the_traces_without_a_time:
      var raw = gpsStarts()
      raw[5] = 0
      let path = rec / "missing-last.sgd"
      makeRecording(path, raw)
      var g = openSeismic(path, keys = true)
      defer: g.close()
      publishVendors(gps)
      defer: publishVendors(VendorRegistry())
      let got = runCut(initJobs(), g, path, fx.dir / "out" / "cut2.sgd",
        shotsAt([90_000'i64]), initCutOptions(40.0, -20.0))
      doAssert got.st == jsDone, got.error & " / " & got.res.reason
      doAssert got.res.segmentsWithoutTime == 1
      doAssert "1 trace has no start time in its headers and was left out." in got.res.lines,
        $got.res.lines
      # the trace left out does not replace the data of segment 1 (record 0 at 90 ms)
      var o = openSeismic(fx.dir / "out" / "cut2.sgd", keys = true)
      defer: o.close()
      let s0 = samplesOf(o, 0)
      for j in 0 ..< s0.len:
        doAssert s0[j] == float32(35 + j), "sample " & $j & ": " & $s0[j]

    block three_like_typed_components_keep_their_channels:
      # 3 channels x 2 segments at one station, all of one component code
      var raw: seq[int64]
      for seg in 0 .. 1:
        for c in 0 .. 2: raw.add gpsOf(segStart(seg))
      let path = rec / "comp.sgd"
      makeRecording(path, raw)
      var g = openSeismic(path, keys = true)
      defer: g.close()
      let c = segmentClock(g, gps)
      doAssert c.receivers[0] == c.receivers[3] and c.receivers[1] == c.receivers[4] and
        c.receivers[2] == c.receivers[5], $c.receivers
      doAssert c.receivers[0] != c.receivers[1] and c.receivers[1] != c.receivers[2], $c.receivers
      doAssert c.unevenChannels == 0
      doAssert planOf(g, c).receiverCount == 3
      publishVendors(gps)
      defer: publishVendors(VendorRegistry())
      let got = runCut(initJobs(), g, path, fx.dir / "out" / "comp.sgd",
        shotsAt([60_000'i64]), initCutOptions(40.0, -20.0))
      doAssert got.st == jsDone, got.error & " / " & got.res.reason
      doAssert got.res.components == 3, "components " & $got.res.components
      var o = openSeismic(fx.dir / "out" / "comp.sgd", keys = true)
      defer: o.close()
      doAssert o.len == 3, "traces " & $o.len
      for t in 0 .. 2:
        let v = samplesOf(o, t)
        doAssert v.len == 20 and v[0] == float32(t * 40 + 20) and v[19] == float32(t * 40 + 39),
          "trace " & $t & ": " & $v

    block uneven_channels_are_counted:
      # three traces at the first start time, two at the second
      let raw = @[gpsOf(segStart(0)), gpsOf(segStart(0)), gpsOf(segStart(0)),
        gpsOf(segStart(1)), gpsOf(segStart(1))]
      let path = rec / "uneven.sgd"
      makeRecording(path, raw)
      var g = openSeismic(path, keys = true)
      defer: g.close()
      doAssert segmentClock(g, gps).unevenChannels == 1

    block a_channel_that_misses_a_segment_refuses_the_cut:
      # three like-typed channels of one station, the second missing its third segment: the
      # later channel would take its place, so no record is written
      var raw: seq[int64]
      for seg in 0 ..< 5:
        for c in 0 ..< 3:
          if not (seg == 2 and c == 1): raw.add gpsOf(segStart(seg))
      let path = rec / "s7.sgd"
      makeRecording(path, raw)
      var g = openSeismic(path, keys = true)
      defer: g.close()
      publishVendors(gps)
      defer: publishVendors(VendorRegistry())
      let facts = describeRecording(planRecording(addr g, path, 2.0, gps))
      doAssert facts.kind == rkReceiverContinuous and facts.unevenChannels == 1, $facts
      doAssert cutRefusal(facts) == "The channels of one component type at a station cannot " &
        "be told apart and one of them misses a segment, so the records cannot be " &
        "assembled safely.", cutRefusal(facts)
      let dest = fx.dir / "out" / "s7.sgd"
      let got = runCut(initJobs(), g, path, dest, shotsAt([190_000'i64]),
        initCutOptions(40.0, -20.0))
      doAssert got.st == jsFailed and "cannot be told apart" in got.res.reason, got.res.reason
      doAssert not fileExists(dest)

    block like_typed_geophones_with_a_hydrophone_one_missing_a_segment:
      # a hydrophone and three geophones of one type; the third channel misses segment 1
      var raw: seq[int64]
      var sensors: seq[uint8]
      for seg in 0 ..< 4:
        for c in 0 ..< 4:
          if not (seg == 1 and c == 2):
            raw.add gpsOf(segStart(seg))
            sensors.add [1'u8, 2, 2, 2][c]
      let path = rec / "u5b.sgd"
      makeRecording(path, raw, sensor = sensors)
      var g = openSeismic(path, keys = true)
      defer: g.close()
      let facts = describeRecording(planRecording(addr g, path, 2.0, gps))
      doAssert facts.unevenChannels == 1 and cutRefusal(facts).len > 0, $facts
      # all four channels present in every segment: the cut goes on
      var even: seq[int64]
      for seg in 0 ..< 4:
        for c in 0 ..< 4: even.add gpsOf(segStart(seg))
      makeRecording(rec / "u5.sgd", even, sensor = [1'u8, 2, 2, 2, 1, 2, 2, 2, 1, 2, 2, 2,
        1, 2, 2, 2])
      var h = openSeismic(rec / "u5.sgd", keys = true)
      defer: h.close()
      let ok = describeRecording(planRecording(addr h, rec / "u5.sgd", 2.0, gps))
      doAssert ok.unevenChannels == 0 and cutRefusal(ok) == "", $ok

    block the_kind_looks_at_the_first_starts_and_the_cut_at_all:
      # twelve segments of one receiver, the tenth ten samples late: the dialog's facts (the
      # first KindStarts starts) say continuous, the cut places every segment and refuses
      var raw: seq[int64]
      for seg in 0 ..< 12:
        raw.add gpsOf(segStart(seg) + (if seg == 9: 10 * DtUs else: 0))
      let path = rec / "late.sgd"
      makeRecording(path, raw)
      var g = openSeismic(path, keys = true)
      defer: g.close()
      let plan = planRecording(addr g, path, 2.0, gps)
      doAssert describeRecording(plan).kind == rkReceiverContinuous
      let all = describeRecording(plan, AllStarts)
      doAssert all.kind == rkReceiverSliced and all.offTrace == 10, $all
      publishVendors(gps)
      defer: publishVendors(VendorRegistry())
      let dest = fx.dir / "out" / "late.sgd"
      let got = runCut(initJobs(), g, path, dest, shotsAt([90_000'i64]),
        initCutOptions(40.0, -20.0))
      doAssert got.st == jsFailed and "time-sliced receiver gather" in got.res.reason,
        got.res.reason
      doAssert not fileExists(dest)

    block type_codes_of_zero_still_tell_the_channels_apart:
      # three channels of one station, every sensor type 0, four segments
      var raw: seq[int64]
      for seg in 0 ..< 4:
        for c in 0 ..< 3: raw.add gpsOf(segStart(seg))
      let path = rec / "zeros.sgd"
      makeRecording(path, raw, sensor = [0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
      var g = openSeismic(path, keys = true)
      defer: g.close()
      let facts = describeRecording(planRecording(addr g, path, 2.0, gps))
      doAssert facts.kind == rkReceiverContinuous and facts.components == 3, $facts
      doAssert facts.abutting == 9 and facts.unevenChannels == 0, $facts

    block records_keep_the_order_of_the_file:
      # at stations 102 then 101, a geophone Z (sensor 2), a hydrophone (1), a geophone X (3):
      # every record is 102 Z, 102 H, 102 X, 101 Z, 101 H, 101 X, also after a dropout
      var raw: seq[int64]
      var sensors: seq[uint8]
      var points: seq[int32]
      let present = [0, 1, 3, 4] # segment 2 was not recorded
      for seg in present:
        for point in [102'i32, 101]:
          for sensor in [2'u8, 1, 3]:
            raw.add gpsOf(segStart(seg))
            sensors.add sensor
            points.add point
      let path = rec / "order.sgd"
      makeRecording(path, raw, sensor = sensors, points = points)
      var g = openSeismic(path, keys = true)
      defer: g.close()
      let clock = segmentClock(g, gps)
      for row in 0 ..< raw.len:
        doAssert clock.receivers[row] == row mod 6, "row " & $row & ": " & $clock.receivers
      publishVendors(gps)
      defer: publishVendors(VendorRegistry())
      let dest = fx.dir / "out" / "order.sgd"
      # shots at the start of segments 0, 3 and 4 (the one after the dropout)
      let got = runCut(initJobs(), g, path,
        dest, shotsAt([20_000'i64, 20_000 + 3 * 80_000, 20_000 + 4 * 80_000]),
        initCutOptions(40.0, -20.0))
      doAssert got.st == jsDone, got.error & " / " & got.res.reason
      var o = openSeismic(dest, keys = true)
      defer: o.close()
      doAssert o.len == 18, "traces " & $o.len
      let segmentIndex = [0, 2, 3] # the position of the shot's segment among those recorded
      for shot in 0 ..< 3:
        for t in 0 ..< 6:
          let source = segmentIndex[shot] * 6 + t
          let v = samplesOf(o, shot * 6 + t)
          doAssert v[0] == float32(source * 40), "shot " & $shot & " trace " & $t & ": " & $v[0]

    block traces_without_a_station_are_not_merged:
      var raw: seq[int64]
      for c in 0 ..< 6: raw.add gpsOf(segStart(0))
      let path = rec / "nostation.sgd"
      makeRecording(path, raw, noStation = true)
      var g = openSeismic(path, keys = true)
      defer: g.close()
      let c = segmentClock(g, gps)
      doAssert c.fromHeaders
      doAssert planOf(g, c).receiverCount == 6, "receivers " & $planOf(g, c).receiverCount
      publishVendors(gps)
      defer: publishVendors(VendorRegistry())
      let got = runCut(initJobs(), g, path, fx.dir / "out" / "nostation.sgd",
        shotsAt([30_000'i64]), initCutOptions(40.0, -20.0))
      # no receiver line and point and one segment each: a shot gather, refused before
      # any output
      doAssert got.st == jsFailed, "the cut was not refused"
      doAssert "shot gather" in got.res.reason, got.res.reason
      doAssert not fileExists(fx.dir / "out" / "nostation.sgd")

    block no_declaring_map_means_no_header_pass:
      # a map that applies but names no start time field, and one that names it
      # for another format, are not read for the clock
      let other = registryOf(fx.dir / "feet2", "ft")
      doAssert startFieldDeclared(f, gps)
      doAssert not startFieldDeclared(f, VendorRegistry())
      var bare = VendorRegistry()
      let text = "(.nif27)\n(vendormap \"bare\" (version 1) (match (format segd))\n" &
        "  (target (kind block) (type 0xB0) (where traceHeader) (name other)\n" &
        "    (field somethingElse (at 1) (enc i64))))\n"
      createDir(fx.dir / "bare")
      writeFile(fx.dir / "bare" / "bare.nif", text)
      let load = loadVendorFolders(@[VendorFolder(dir: fx.dir / "bare", origin: voProject)])
      doAssert load.registry.maps.len == 1, $load.problems
      doAssert not startFieldDeclared(f, load.registry)
      doAssert not segmentClock(f, load.registry).fromHeaders
      doAssert other.maps.len == 1

    block twelve_traces_with_and_without_their_map:
      var raw: seq[int64]
      for i in 0 ..< 12: raw.add gpsOf(segStart(i))
      let path = rec / "twelve.sgd"
      makeRecording(path, raw)
      var g = openSeismic(path, keys = true)
      defer: g.close()
      let with = describeRecording(planRecording(addr g, path, 2.0, gps))
      doAssert with.kind == rkReceiverContinuous and with.components == 1, $with
      let without = describeRecording(planRecording(addr g, path, 2.0, VendorRegistry()))
      doAssert without.kind == rkReceiverSliced and without.slicedWhy == swSameStart, $without
      publishVendors(VendorRegistry())
      let dest = fx.dir / "out" / "cut3.sgd"
      let got = runCut(initJobs(), g, path, dest, shotsAt([90_000'i64]),
        initCutOptions(40.0, -20.0))
      doAssert got.st == jsFailed, "the cut was not refused"
      doAssert "time-sliced receiver gather" in got.res.reason, got.res.reason
      doAssert "vendor header map" in got.res.reason, got.res.reason
      doAssert not fileExists(dest)

    block sorting_by_time_reads_the_recorders_own_starts:
      # The six segments are in the file latest first, and share the keys' one
      # time: the Time order (core/sorting) puts them earliest first only by the
      # start times of the trace headers, which the panel's reader takes from
      # `segmentClock`. Without the map the traces tie, and stay in the file's
      # order.
      # Seen to fail with the reader not passing `startOf`: the tile held 0 ..< 6.
      var raw = gpsStarts()
      raw.reverse
      let path = rec / "backwards.sgd"
      makeRecording(path, raw)
      proc tileOrder(withMap: bool): seq[int] =
        publishVendors(if withMap: gps else: VendorRegistry())
        var st = initAppState()
        st.apply Command(kind: ckOpen, paths: @[path])
        doAssert st.settle(st.panel(MainPanel).layout.traces == Segments)
        let id = st.findPanel(MainPanel)
        var v = fitAll(st.panel(MainPanel).layout, 800, 600)
        v.traces = Span(lo: -0.5, hi: float64(Segments) - 0.5)
        st.apply Command(kind: ckView, panel: MainPanel, view: v)
        st.apply Command(kind: ckSort, panel: MainPanel,
          order: @[SortKey(field: hfStartTime)])
        let main = st.panel(MainPanel)
        doAssert st.settle(st.tiles(id).len > 0 and not main.pending.isEmpty and
          st.tiles(id)[^1].request == main.pending and
          st.tiles(id)[^1].request.gen >= main.orderGen)
        result = st.tiles(id)[^1].traces
        st.shutdown()
      defer: publishVendors(VendorRegistry())
      doAssert tileOrder(true) == @[5, 4, 3, 2, 1, 0], "with the map"
      doAssert tileOrder(false) == @[0, 1, 2, 3, 4, 5], "without the map"

    block output_sorts_by_the_recorders_own_starts:
      # The same file as the plot's Time order, written with that sort: the
      # traces come out earliest first as the plot shows them (5 ... 0), by
      # the vendor start times, not tied and left in the file's order.
      # Seen to fail with the output job not passing `startOf`: the written
      # file held 0 ..< 6.
      var raw = gpsStarts()
      raw.reverse
      let path = rec / "outsort.sgd"
      makeRecording(path, raw)
      proc written(withMap: bool): seq[int] =
        publishVendors(if withMap: gps else: VendorRegistry())
        var src = openSeismic(path, keys = true)
        defer: src.close()
        let dest = fx.dir / "out" / (if withMap: "sorted-map.sgd" else: "sorted-none.sgd")
        let sink = OutputSink()
        let jobs = initJobs()
        let id = jobs.submit(outputSpec(path, dest), outputWork(addr src, path, dest,
          OutputOptions(format: ofSegd, sortKeys: @[SortKey(field: hfStartTime)]),
          FileEdits(), @[path], sink))
        doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
          "the write did not finish"
        doAssert jobs.info(id).get.state == jsDone, jobs.info(id).get.error
        var back = openSeismic(dest, keys = true)
        defer: back.close()
        doAssert back.len == Segments
        for k in 0 ..< Segments: result.add int(samplesOf(back, k)[0]) div SegLen
      defer: publishVendors(VendorRegistry())
      doAssert written(true) == @[5, 4, 3, 2, 1, 0], "with the map"
      doAssert written(false) == @[0, 1, 2, 3, 4, 5], "without the map"

  echo "tsegmentclock ok"

when isMainModule:
  main()
