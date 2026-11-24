## A SEG-D recording cut into SEG-D keeps the source's own headers: the output
## is in the source's revision (Rev 2.1 here), its extended header and channel
## set descriptor (filter and gain fields) are the source's, each trace keeps
## the vendor header blocks of the segment that holds the shot's first sample,
## with the start time in them rewritten to the slice's first sample. The
## recording is built here: six segments of 40 samples at 2 ms per component,
## one or three components, each trace with two vendor blocks (a map names
## `firstSampleTime` in the first, in GPS microseconds).
##
## Seen failing with the keys path forced for every source: "output is Rev 3,
## not Rev 2.1", the extended header, the filter fields and the vendor blocks
## lost. Seen failing with the start time left as the segment's: "start time of
## trace 3 ..." with a shot spanning two segments; with the trace number left
## as the source's: "trace number of trace 4".

import std/[assertions, os, strutils, times]
import parseSEG
import parseSEG/model/traceindex
import parseSEG/segd/[reader, writer, headers, samples, rev3]
import parseSEG/io/diskio
import viewSEG/core/[cutcarry, cutgather, cutgatherjobs, jobs, segmentclock, shotlog, vendormaps]
import viewSEG/view/cutwords
import utils/waiting

const
  Segments = 6
  SegLen = 40
  DtUs = 2000'i64
  BaseUs = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC
  Leap = 18'i64                      # GPS minus UTC in 2026
  GpsEpochUs = 315_964_800_000_000'i64
  StartMs = -20.0                    ## ten samples before the shot
  LengthMs = 60.0                    ## thirty samples
  Window = 30
  # the first sample of each window: segment 0 whole, segments 2 and 3, segment 5
  FirstSamples = [10, 100, 200]
  Files = [101, 102, 103]
  Map = "(.nif27)\n(vendormap \"carry-test\" (version 1) (match (format segd) " &
    "(manufacturer 77))\n  (target (kind traceExt) (extension 2) (name vendorClock)\n" &
    "    (field firstSampleTime (at 1) (enc i64) (sentinel 0) (unit \"us GPS\")))\n" &
    "  (target (kind traceExt) (extension 3) (name vendorTag)\n" &
    "    (field tag (at 1) (enc u16))))\n"

var base = BaseUs ## the instant of the recording's first sample

func gpsOf(utcUs: int64): int64 =
  utcUs - GpsEpochUs + Leap * 1_000_000

proc sampleUs(k: int): int64 =
  base + int64(k) * DtUs

func value(comp, k: int): float32 =
  float32(1000 * comp + k)

proc makeRecording(path: string; comps: int; fmt = sd8058;
    missing: seq[(int, int)] = @[]; split = 0; trigger = false) =
  ## Rev 2.1, one record (two with `split`: the segments from it on are the second): an
  ## extended header, a source header, one channel set with filter and gain fields set, a
  ## trace per segment and component (segment by segment), each with two vendor blocks.
  ## With `trigger`, bytes 9-16 of the second vendor block repeat the first's start time.
  var r = SegdRecord(layout: slRev2, format: some(fmt),
    revision: SegdRevision(major: 2, minor: 1))
  r.gh1 = SegdGeneralHeader1(fileNumber: 5, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: 2, julianDay: 60, manufacturerCode: 77, baseScanInterval16: 32,
    recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 1,
    extendedHeaderBlocks: 1)
  r.gh2 = some SegdGeneralHeader2(extFileNumber: 5, revisionMajor: 2, revisionMinor: 1,
    extRecordLength: uint32(2 * SegLen * Segments), blockNumber: 2)
  r.sourceHeaders = @[SegdGeneralHeaderN(extFileNumber: 5, sourceLineNumber: 9,
    sourcePointNumber: 9, sourcePointIndex: 1, blockNumber: 3, sourceSetNumber: 1)]
  r.extended = newSeq[byte](32)
  for i in 0 ..< 32: r.extended[i] = byte(90 + i)
  r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[
    SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1, endTime: uint16(SegLen),
      channelCount: Segments * comps - missing.len, channelType: 1, traceHeaderExtensions: 3,
      aliasFilterFreq: 200, aliasFilterSlope: 72, lowCutFreq: 3, lowCutSlope: 18,
      notch1Freq: 500, gainControl: 3, verticalStack: 1)])]
  r.traceCount = Segments * comps - missing.len
  var all, all2: seq[SegdTrace]
  var order: seq[(int, int)] = @[]
  for seg in 0 ..< Segments:
    for c in 0 ..< comps:
      if (seg, c) notin missing: order.add (seg, c)
  for (seg, c) in order:
    let second = split > 0 and seg >= split
    template list: untyped = (if second: all2 else: all)
    var t = SegdTrace(layout: slRev2, index: list.len, numSamples: SegLen)
    t.header = SegdTraceHeader(fileNumber: 5, scanTypeNumber: 1, channelSetNumber: 1,
      traceNumber: list.len + 1, traceHeaderExtensions: 3'u8)
    t.ext1 = some SegdTraceHeaderExt1(receiverLineNumber: 2000, receiverPointNumber: 100,
      receiverPointIndex: 1, samplesPerTrace: uint32(SegLen), sensorType: uint8(2 + c))
    t.extensions = newSeq[byte](64)
    for i in 0 ..< 64: t.extensions[i] = byte(31 * list.len + 3 * i + 1)
    let start = gpsOf(sampleUs(seg * SegLen))
    for i in 0 .. 7: t.extensions[i] = byte((start shr (8 * (7 - i))) and 255)
    if trigger:
      for i in 0 .. 7: t.extensions[40 + i] = t.extensions[i]
    var v = newSeq[float64](SegLen)
    for j in 0 ..< SegLen: v[j] = float64(value(c, seg * SegLen + j))
    t.samples = newSeq[byte](dataBytes(fmt, SegLen))
    encodeSamples(fmt, v, t.samples)
    if second: all2.add t else: all.add t
  var records = @[SegdRecordData(record: r, traces: all)]
  if split > 0:
    var r2 = r
    r2.scanTypes[0].descriptors[0].channelCount = all2.len
    r2.traceCount = all2.len
    r2.gh1.fileNumber = 6
    records[0].record.scanTypes[0].descriptors[0].channelCount = all.len
    records[0].record.traceCount = all.len
    records.add SegdRecordData(record: r2, traces: all2)
  let sink = openDiskSink(path)
  try:
    let log = writeSegd(sink, SegdData(records: records))
    doAssert log.len == 0, $log
  finally:
    sink.close()

proc makeSegy(path: string; comps: int) =
  ## The same recording as SEG-Y (always cut from keys): the reference for the samples.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for seg in 0 ..< Segments:
    for c in 0 ..< comps:
      var samples = newSeq[float32](SegLen)
      for j in 0 ..< SegLen: samples[j] = value(c, seg * SegLen + j)
      var k = initTraceKeys()
      k.status = tsLive
      k.record = float64(seg + 1)
      k.channel = float64(c + 11)
      k.component = uint8(c + 1)
      k.intervalUs = 2000
      k.t0Ms = 0
      k.time = float64(sampleUs(seg * SegLen) div 1_000_000) +
        float64(sampleUs(seg * SegLen) mod 1_000_000) / 1e6
      k.rcvLine = 2000
      k.rcvPoint = 100
      w.writeTrace(k, samples)
  discard w.close()

proc shotUs(i: int): int64 =
  sampleUs(FirstSamples[i]) - int64(StartMs * 1000) + 123 * int64(i)

proc shotsOf(withFiles: bool): CutShots =
  var text = ""
  let roles = if withFiles: @[crFileNumber, crUtcMicros, crSourceLine, crShotPoint]
    else: @[crUtcMicros, crSourceLine, crShotPoint]
  for i in 0 ..< 3:
    if withFiles: text.add $Files[i] & ","
    text.add $shotUs(i) & "," & $(20 + i) & "," & $(30 + i) & "\n"
  var m = initShotLogMap()
  m.hasHeader = false
  m.roles = roles
  shotsInTime(shots(parseShotLog(text, m), m).rows)

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

proc samplesOf(f: SeismicFile; trace: int): seq[float32] =
  let x = f.readTraces(trace .. trace)
  result.setLen x.shape[1]
  for j in 0 ..< result.len: result[j] = x[0, j]

proc headerBytes(f: SeismicFile; trace: int): seq[byte] =
  let e = f.traceEntry(trace)
  f.copyBytes(e.offset, e.headerBytes)

proc check(dir: string; jobs: Jobs; comps: int; reg: VendorRegistry) =
  let tag = "c" & $comps
  let path = dir / "rec" / ("rec-" & tag & ".sgd")
  let sgy = dir / "rec" / ("rec-" & tag & ".sgy")
  makeRecording(path, comps)
  makeSegy(sgy, comps)
  var src = openSeismic(path, keys = true)
  var ref0 = openSeismic(sgy, keys = true)
  defer:
    src.close()
    ref0.close()
  let opts = initCutOptions(LengthMs, StartMs)
  let sh = shotsOf(true)
  doAssert sh.shots.len == 3

  # the same plan through the keys path: a SEG-Y source
  let keysDest = dir / "out" / ("keys-" & tag & ".sgd")
  let viaKeys = runCut(jobs, ref0, sgy, keysDest, sh, opts)
  doAssert viaKeys.st == jsDone and not viaKeys.res.carried, viaKeys.error
  var keys = openSeismic(keysDest, keys = true)
  defer: keys.close()
  doAssert keys.len == 3 * comps

  let dest = dir / "out" / ("carry-" & tag & ".sgd")
  let got = runCut(jobs, src, path, dest, sh, opts)
  doAssert got.st == jsDone, got.error & " / " & got.res.reason
  doAssert got.res.ok and got.res.carried and got.res.shotsWritten == 3 and
    got.res.shotsRefused == 0, $got.res
  doAssert got.res.revision == "Rev 2.1" and got.res.startRewritten == 3 * comps and
    got.res.startMissing == 0, $got.res
  doAssert "Rev 2.1" in got.res.lines[1] and "headers carried" in got.res.lines[1],
    got.res.lines.join("|")
  doAssert got.res.recordsFromFileNumbers
  doAssert abs(got.res.expectedBytes - got.res.bytesWritten) * 100 <= 5 * got.res.bytesWritten,
    "estimate " & $got.res.expectedBytes & ", written " & $got.res.bytesWritten
  doAssert got.res.sourceFormat == 0 and "format" notin got.res.lines.join("|")
  var g = openSeismic(dest, keys = true)
  defer: g.close()
  doAssert g.kind == skSegd and g.len == 3 * comps, "traces " & $g.len
  doAssert g.index.segdRecords.len == 3

  for s in 0 ..< 3:
    let rec = g.index.segdRecords[s]
    let from0 = src.index.segdRecords[0]
    # the source's revision, extended header and channel set (filters, gain)
    doAssert rec.layout == slRev2 and rec.revision.major == 2 and rec.revision.minor == 1,
      "output is not Rev 2.1"
    doAssert rec.extended == from0.extended, "extended header of record " & $s
    let d = rec.scanTypes[0].descriptors[0]
    let d0 = from0.scanTypes[0].descriptors[0]
    doAssert d.aliasFilterFreq == 200 and d.aliasFilterSlope == 72 and d.lowCutFreq == 3 and
      d.lowCutSlope == 18 and d.notch1Freq == 500 and d.gainControl == 3,
      "filter fields of record " & $s
    doAssert d.aliasFilterFreq == d0.aliasFilterFreq and d.channelCount == comps and
      d.channelType == d0.channelType
    # the file number and the time of the shot log
    doAssert rec.gh1.fileNumber == Files[s], "file number of record " & $s
    # the record's time is its first sample's (Rev 2 holds whole seconds)
    let firstUs = shotUs(s) + int64(StartMs * 1000)
    let t = fromUnix(firstUs div 1_000_000).utc
    doAssert rec.gh1.year == t.year mod 100 and rec.gh1.julianDay == t.yearday + 1 and
      rec.gh1.hour == t.hour and rec.gh1.minute == t.minute and rec.gh1.second == t.second,
      "time of record " & $s
    doAssert g.recordField(s, "gh3.sourceLineNumber").toFloat == float64(20 + s) and
      g.recordField(s, "gh3.sourcePointNumber").toFloat == float64(30 + s),
      "source line and point of record " & $s

    let seg = FirstSamples[s] div SegLen # the segment that holds the first sample
    for c in 0 ..< comps:
      let o = s * comps + c
      let sourceTrace = seg * comps + c
      let a = g.headerBytes(o)
      let b = src.headerBytes(sourceTrace)
      doAssert a.len == b.len, "header size of trace " & $o
      # the second vendor block and THE#1 are the source's; the first has the new start
      doAssert a[52 + 32 ..< 52 + 64] == b[52 + 32 ..< 52 + 64], "vendor block 3 of trace " & $o
      doAssert a[52 + 8 ..< 52 + 32] == b[52 + 8 ..< 52 + 32], "vendor block 2 of trace " & $o
      var start = 0'i64
      for i in 0 .. 7: start = (start shl 8) or int64(a[52 + i])
      doAssert start == gpsOf(firstUs), "start time of trace " & $o & ": " & $start
      doAssert int(g.traceField(o, "trace.traceNumber").intVal) == c + 1,
        "trace number of trace " & $o
      doAssert int(g.traceField(o, "ext1.receiverPointNumber").intVal) == 100
      # Rev 2 holds the record time in whole seconds, and the reader gives that as the time
      doAssert g.traceKeys(o).time == float64(firstUs div 1_000_000), "keys time of trace " & $o
      # the samples are the keys path's, bit for bit
      let mine = samplesOf(g, o)
      let theirs = samplesOf(keys, o)
      doAssert mine.len == Window and mine == theirs, "samples of trace " & $o
      for j in 0 ..< Window:
        doAssert mine[j] == value(c, FirstSamples[s] + j), "sample " & $j & " of trace " & $o

  # the viewer's own reader: a continuous gather whose segment starts are the shots' windows
  let clock = segmentClock(g, reg)
  doAssert clock.fromHeaders and clock.leftOut == 0
  for o in 0 ..< g.len:
    doAssert clock.times[o] == toPosixSeconds(shotUs(o div comps) + int64(StartMs * 1000)),
      "clock of trace " & $o

  # sequential numbers when the log has none
  let plain = runCut(jobs, src, path, dir / "out" / ("plain-" & tag & ".sgd"), shotsOf(false), opts)
  doAssert plain.st == jsDone and plain.res.carried and not plain.res.recordsFromFileNumbers
  var p = openSeismic(dir / "out" / ("plain-" & tag & ".sgd"), keys = true)
  defer: p.close()
  for s in 0 ..< 3:
    doAssert p.index.segdRecords[s].gh1.fileNumber == s + 1

  # SEG-Y output still builds its headers from keys
  var segyOpts = opts
  segyOpts.standard = csSegy
  let toSegy = runCut(jobs, src, path, dir / "out" / ("out-" & tag & ".sgy"), sh, segyOpts)
  doAssert toSegy.st == jsDone and not toSegy.res.carried, toSegy.error
  var y = openSeismic(dir / "out" / ("out-" & tag & ".sgy"), keys = true)
  defer: y.close()
  doAssert y.kind == skSegy and y.len == 3 * comps

proc gapShots(): CutShots =
  ## Time order: a shot of 1949 (a year the writer cannot hold), a shot three days before
  ## the recording (no segment reaches it), the three good shots, a shot of 2060.
  var text = ""
  var us = @[-631_152_000_000_000'i64 - 864_000_000_000'i64, BaseUs - 3 * 86_400_000_000'i64]
  for i in 0 ..< 3: us.add shotUs(i)
  us.add 2_840_140_800_000_000'i64
  for i, u in us: text.add $(200 + i) & "," & $u & "\n"
  var m = initShotLogMap()
  m.hasHeader = false
  m.roles = @[crFileNumber, crUtcMicros]
  shotsInTime(shots(parseShotLog(text, m), m).rows)

proc checkGapsAndRefusals(dir: string; jobs: Jobs) =
  ## A shot in a gap is a dead trace, as the keys path writes it; a shot the writer refuses
  ## is named with the library's message, the shots around it are written and the file is
  ## valid. Seen failing: the gap trace left live ("trace edit of trace 0 is 0").
  let comps = 3
  let path = dir / "rec" / "gaps.sgd"
  let sgy = dir / "rec" / "gaps.sgy"
  makeRecording(path, comps)
  makeSegy(sgy, comps)
  var src = openSeismic(path, keys = true)
  var ref0 = openSeismic(sgy, keys = true)
  defer:
    src.close()
    ref0.close()
  let opts = initCutOptions(LengthMs, StartMs)
  let all = gapShots()
  doAssert all.shots.len == 6, "the log kept " & $all.shots.len & " shots"
  let dest = dir / "out" / "gaps.sgd"
  let got = runCut(jobs, src, path, dest, all, opts)
  doAssert got.st == jsDone, got.error & " / " & got.res.reason
  doAssert got.res.carried and got.res.shotsWritten == 4 and got.res.shotsRefused == 2,
    $got.res
  let said = got.res.lines.join("|")
  doAssert "2 shots were refused" in said and "record 200" in said and "record 205" in said and
    "1950-2049" in said, said
  var g = openSeismic(dest, keys = true)
  defer: g.close()
  doAssert g.len == 4 * comps and g.index.segdRecords.len == 4, "records " &
    $g.index.segdRecords.len
  for s in 0 ..< 4:
    doAssert g.index.segdRecords[s].gh1.fileNumber == 201 + s
  # the same gap shot through the keys path
  let two = block:
    var text = $201 & "," & $(BaseUs - 3 * 86_400_000_000'i64) & "\n"
    var m = initShotLogMap()
    m.hasHeader = false
    m.roles = @[crFileNumber, crUtcMicros]
    shotsInTime(shots(parseShotLog(text, m), m).rows)
  let viaKeys = runCut(jobs, ref0, sgy, dir / "out" / "gapkeys.sgd", two, opts)
  doAssert viaKeys.st == jsDone and not viaKeys.res.carried, viaKeys.error & viaKeys.res.reason
  var k = openSeismic(dir / "out" / "gapkeys.sgd", keys = true)
  defer: k.close()
  for c in 0 ..< comps:
    let dead = g.traceField(c, "trace.traceEdit").intVal
    doAssert dead == 1 and dead == k.traceField(c, "trace.traceEdit").intVal,
      "trace edit of gap trace " & $c & " is " & $dead
    doAssert g.traceKeys(c).status == tsDead
    for v in samplesOf(g, c): doAssert v == 0'f32
  # the good shots follow, live, and the one before the refused 2060 shot is whole
  for s in 1 ..< 4:
    for c in 0 ..< comps:
      let o = s * comps + c
      doAssert g.traceField(o, "trace.traceEdit").intVal == 0, "trace " & $o & " is dead"
      let got = samplesOf(g, o)
      for j in 0 ..< Window:
        doAssert got[j] == value(c, FirstSamples[s - 1] + j), "sample " & $j & " of trace " & $o

proc checkSourceFormat(dir: string; jobs: Jobs) =
  ## A source in 24-bit integers: the output's samples are 32-bit floats, and it says so.
  let path = dir / "rec" / "int.sgd"
  makeRecording(path, 1, sd8036)
  var src = openSeismic(path, keys = true)
  defer: src.close()
  let got = runCut(jobs, src, path, dir / "out" / "int.sgd", shotsOf(true),
    initCutOptions(LengthMs, StartMs))
  doAssert got.st == jsDone and got.res.carried and got.res.sourceFormat == 8036, $got.res
  doAssert "format 8036" in got.res.lines.join("|") and
    "32-bit floats" in got.res.lines.join("|"), got.res.lines.join("|")
  var g = openSeismic(dir / "out" / "int.sgd", keys = true)
  defer: g.close()
  for s in 0 ..< 3:
    let x = samplesOf(g, s)
    for j in 0 ..< Window: doAssert x[j] == value(0, FirstSamples[s] + j)

proc blockOf(t: uint8): seq[byte] =
  result = newSeq[byte](32)
  result[31] = t

proc put64(b: var seq[byte]; at: int; v: int64) =
  for i in 0 .. 7: b[at + i] = byte((v shr (8 * (7 - i))) and 255)

proc get64(b: openArray[byte]; at: int): int64 =
  for i in 0 .. 7: result = (result shl 8) or int64(b[at + i])

proc makeRev3(path: string; comps: int; csUs = 0'i64; place = false) =
  ## Rev 3.0, one record, a trace per segment and component with a Timestamp block (0x42) and
  ## a vendor block (0xB0) holding the segment's start in GPS microseconds; the channel set
  ## starts `csUs` after the record's time zero. With `place`, each trace has a vibrator
  ## Source Description block (0x15) and a Position block (0x50-0x52) before those two.
  let fmt = sd8058
  var r = SegdRecord(layout: slRev3, format: some(fmt), revision: SegdRevision(major: 3, minor: 0))
  r.generalBlocks.add blockOf(0x11)
  r.gh1 = SegdGeneralHeader1(fileNumber: 7, formatCode: ord(fmt), year: 16,
    additionalGhBlocks: 3, julianDay: 366, manufacturerCode: 77, baseScanInterval16: 32,
    recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 1,
    extendedHeaderBlocks: 1)
  let endUs = int32(DtUs * (SegLen - 1))
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 7, revisionMajor: 3,
    extRecordLength: uint32(endUs), blockType: 2)
  r.gh3 = SegdGeneralHeader3(timeZero: utcUsToGpsUs(sampleUs(0)) - csUs, blockType: 3)
  r.extended = newSeq[byte](32)
  for i in 0 ..< 32: r.extended[i] = byte(90 + i)
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[
    SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1, channelType: 0x10,
      startTime: int32(csUs), endTime: endUs + int32(csUs), numSamples: SegLen,
      descaleMultiplier: 1.0, channelsInSet: uint32(Segments * comps),
      samplingInterval: uint32(DtUs), traceHeaderExtensions: (if place: 7 else: 3),
      verticalStack: 1, blockType1: 0x30, blockType2: 0x31,
      blockType3: 0x32)])]
  var all: seq[SegdTrace]
  for seg in 0 ..< Segments:
    for c in 0 ..< comps:
      var t = SegdTrace(layout: slRev3, index: all.len, numSamples: SegLen)
      t.header = SegdTraceHeader(fileNumber: 7, scanTypeNumber: 1, channelSetNumber: 1,
        traceNumber: all.len + 1, traceHeaderExtensions: (if place: 7'u8 else: 3'u8))
      t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(receiverLineNumber: 100,
        receiverPointNumber: 101, receiverPointIndex: 1, numSamples: SegLen,
        sensorType: uint8(2 + c), blockType: 0x40)
      let start = utcUsToGpsUs(sampleUs(seg * SegLen))
      var ts = blockOf(0x42)
      ts.put64(0, start)
      var vendor = blockOf(0xB0)
      vendor.put64(0, start)
      for i in 8 .. 30: vendor[i] = byte(31 * all.len + 3 * i + 1)
      t.extensions = ts & vendor
      if place:
        t.extensions = blockOf(0x15) & blockOf(0x50) & blockOf(0x51) & blockOf(0x52) &
          t.extensions
      var v = newSeq[float64](SegLen)
      for j in 0 ..< SegLen: v[j] = float64(value(c, seg * SegLen + j))
      t.samples = newSeq[byte](dataBytes(fmt, SegLen))
      encodeSamples(fmt, v, t.samples)
      all.add t
  computeRev3Sizes(r, all)
  r.traceCount = all.len
  let sink = openDiskSink(path)
  try:
    let log = writeSegd(sink, SegdData(records: @[SegdRecordData(record: r, traces: all)]))
    doAssert log.len == 0, $log
  finally:
    sink.close()

const
  Rev3Map = "(.nif27)\n(vendormap \"carry-test3\" (version 1) (match (format segd) " &
    "(rev 3.0 3.1) (manufacturer 77))\n  (target (kind block) (type 0xB0) " &
    "(where traceHeader) (name vendorClock)\n    (field firstSampleTime (at 1) (enc i64) " &
    "(sentinel 0) (unit \"us GPS\"))))\n"

func rev2Map(trigger: string; enc = "i64"; maker = 77): string =
  ## The Rev 2 map of manufacturer `maker` with a `triggerTime` field (encoding `enc`) in
  ## the second block, in unit `trigger` ("none": a field without a unit; "": no field).
  result = "(.nif27)\n(vendormap \"carry-test" & $maker & "\" (version 1) (match (format segd) " &
    "(rev 2.0 2.1) (manufacturer " & $maker & "))\n  (target (kind traceExt) (extension 2) " &
    "(name vendorClock)\n    (field firstSampleTime (at 1) (enc i64) (sentinel 0) " &
    "(unit \"us GPS\")))\n  (target (kind traceExt) (extension 3) (name vendorTag)\n" &
    "    (field tag (at 1) (enc u16))"
  if trigger == "none":
    result.add "\n    (field triggerTime (at 9) (enc " & enc & ") (sentinel 0))"
  elif trigger.len > 0:
    result.add "\n    (field triggerTime (at 9) (enc " & enc & ") (sentinel 0) (unit \"" & trigger &
      "\"))"
  result.add "))\n"

proc publishMaps(dir: string; texts: openArray[string]): VendorRegistry =
  let folder = dir / ("maps" & $texts.len & $texts[0].len & $texts[^1].len)
  removeDir(folder)
  createDir(folder)
  for i, t in texts: writeFile(folder / ("m" & $i & ".nif"), t)
  let load = loadVendorFolders(@[VendorFolder(dir: folder, origin: voProject)])
  doAssert load.registry.maps.len == texts.len, $load.problems
  publishVendors(load.registry)
  load.registry

proc checkRev2Time(dir: string; jobs: Jobs) =
  ## The first sample on a whole second: a Rev 2 record holds whole seconds, and the
  ## reader gives the first sample's time exactly. Fails with the record time left at
  ## the shot's ("record time of trace 0 is 0.02 s late").
  base = BaseUs - 20_000
  defer: base = BaseUs
  let reg = publishMaps(dir, [rev2Map("")])
  let path = dir / "rec" / "t2.sgd"
  makeRecording(path, 1)
  var src = openSeismic(path, keys = true)
  defer: src.close()
  let shotUs = BaseUs + 20_000 # first sample 10: start -20 ms, so the sample is at BaseUs
  var text = "101," & $shotUs & "\n"
  var m = initShotLogMap()
  m.hasHeader = false
  m.roles = @[crFileNumber, crUtcMicros]
  let sh = shotsInTime(shots(parseShotLog(text, m), m).rows)
  let got = runCut(jobs, src, path, dir / "out" / "t2.sgd", sh, initCutOptions(LengthMs, StartMs))
  doAssert got.st == jsDone and got.res.carried, got.error & got.res.reason
  doAssert "start of -20.0 ms" in got.res.lines.join("|"), got.res.lines.join("|")
  var g = openSeismic(dir / "out" / "t2.sgd", keys = true)
  defer: g.close()
  doAssert g.traceKeys(0).time == float64(BaseUs div 1_000_000) and
    g.traceKeys(0).time == toPosixSeconds(sampleUs(10)),
    "record time of trace 0 is " & $(g.traceKeys(0).time - toPosixSeconds(sampleUs(10))) &
    " s late"

proc checkRev3(dir: string; jobs: Jobs; comps: int; startMs: float64; origin: int64;
    csUs = 0'i64) =
  ## Rev 3: the Timestamp block, the vendor start and General Header #3's time zero equal
  ## the slice's first sample to the microsecond, for a start before, at and after the
  ## shot, also across a GPS leap second (origin 2016-12-31 23:59:59.8 UTC). Fails with the
  ## Timestamp left at the shot's instant ("timestamp of trace 0 is 20000 us off"). With a
  ## channel set that starts `csUs` after time zero, the Timestamp is still the first
  ## sample's: seen failing 4000 us off with the Timestamp override never sent (the
  ## writer's own patch adds the set's start to the record's time), and the samples are the
  ## first sample's: seen failing two samples early ("sample 0 of trace 0 is 8.0") with the
  ## headers' first-sample times taken as the traces' time zero.
  base = origin
  defer: base = BaseUs
  let reg = publishMaps(dir, [rev2Map(""), Rev3Map])
  let tag = "r3c" & $comps & "s" & $int(startMs) & "o" & $(origin div 100_000_000_000_000) &
    "cs" & $csUs
  let path = dir / "rec" / (tag & ".sgd")
  makeRev3(path, comps, csUs)
  var src = openSeismic(path, keys = true)
  defer: src.close()
  var text = ""
  for i in 0 ..< 3:
    text.add $(100 + i) & "," & $(sampleUs(FirstSamples[i]) - int64(startMs * 1000) +
      123 * int64(i)) & "\n"
  var m = initShotLogMap()
  m.hasHeader = false
  m.roles = @[crFileNumber, crUtcMicros]
  let sh = shotsInTime(shots(parseShotLog(text, m), m).rows)
  let dest = dir / "out" / (tag & ".sgd")
  let got = runCut(jobs, src, path, dest, sh, initCutOptions(LengthMs, startMs))
  doAssert got.st == jsDone and got.res.carried, got.error & got.res.reason
  doAssert got.res.startRewritten == 3 * comps and got.res.startMissing == 0, $got.res
  doAssert (startMs != 0) == ("Each record's time is its first sample's" in
    got.res.lines.join("|")), got.res.lines.join("|")
  var g = openSeismic(dest, keys = true)
  defer: g.close()
  doAssert g.len == 3 * comps
  for s in 0 ..< 3:
    let firstUs = sampleUs(FirstSamples[s]) + 123 * int64(s)
    if csUs == 0:
      doAssert g.index.segdRecords[s].gh3.timeZero == utcUsToGpsUs(firstUs),
        "time zero of record " & $s
    for c in 0 ..< comps:
      let o = s * comps + c
      let a = g.headerBytes(o)
      doAssert a.get64(a.len - 64) == utcUsToGpsUs(firstUs),
        "timestamp of trace " & $o & " is " & $(a.get64(a.len - 64) - utcUsToGpsUs(firstUs)) &
        " us off"
      doAssert a.get64(a.len - 32) == utcUsToGpsUs(firstUs), "vendor start of trace " & $o
      doAssert g.traceKeys(o).time == toPosixSeconds(firstUs), "keys time of trace " & $o
      for j in 0 ..< Window:
        doAssert samplesOf(g, o)[j] == value(c, FirstSamples[s] + j),
          "sample " & $j & " of trace " & $o & " is " & $samplesOf(g, o)[j]
  let clock = segmentClock(g, reg)
  doAssert clock.fromHeaders and clock.leftOut == 0
  for o in 0 ..< g.len:
    doAssert clock.times[o] == toPosixSeconds(sampleUs(FirstSamples[o div comps]) +
      123 * int64(o div comps))

proc checkNoSourcePlace(dir: string; jobs: Jobs) =
  ## A Rev 3 recording without Source Description or Position blocks: the shot's source place
  ## has none, the result says so in its own words, naming the output, and the library's
  ## warning about the recording's file does not stand alone.
  base = BaseUs
  discard publishMaps(dir, [rev2Map(""), Rev3Map])
  let path = dir / "rec" / "noplace.sgd"
  makeRev3(path, 1)
  var src = openSeismic(path, keys = true)
  defer: src.close()
  let got = runCut(jobs, src, path, dir / "out" / "noplace.sgd", shotsOf(true),
    initCutOptions(LengthMs, StartMs))
  doAssert got.st == jsDone and got.res.carried, got.error & got.res.reason
  let said = got.res.lines.join("|")
  doAssert "no place in the output" in said and "source line and point" in said, said
  doAssert "noplace.sgd" notin said.replace("noplace.sgd.part", ""), said
  # the receiver station is the recording's own, with source columns in the log too
  var g = openSeismic(dir / "out" / "noplace.sgd", keys = true)
  defer: g.close()
  for o in 0 ..< g.len:
    doAssert g.traceField(o, "ext1.receiverPointNumber").intVal == 101 and
      g.traceField(o, "ext1.receiverLineNumber").intVal == 100, "receiver station of trace " & $o

proc checkSourcePlace(dir: string; jobs: Jobs) =
  ## A Rev 3 recording whose traces have a Source Description block: the shot's source line
  ## and point are written there and read back, and the result does not say they have no
  ## place. Seen failing with the blocks looked for by field name, which the reader does not
  ## know for them ("no place in the output" said, the values written all the same).
  base = BaseUs
  discard publishMaps(dir, [rev2Map(""), Rev3Map])
  let path = dir / "rec" / "place.sgd"
  makeRev3(path, 1, place = true)
  var src = openSeismic(path, keys = true)
  defer: src.close()
  let got = runCut(jobs, src, path, dir / "out" / "place.sgd", shotsOf(true),
    initCutOptions(LengthMs, StartMs))
  doAssert got.st == jsDone and got.res.carried, got.error & got.res.reason
  let said = got.res.lines.join("|")
  doAssert "no place in the output" notin said and "source description" notin said, said
  var g = openSeismic(dir / "out" / "place.sgd", keys = true)
  defer: g.close()
  doAssert g.len == 3
  for o in 0 ..< g.len:
    var line, point = NaN
    for row in g.traceHeaders(o):
      if row.field == "sourceLineNumber": line = row.value.toFloat
      if row.field == "sourcePointNumber": point = row.value.toFloat
    doAssert line == float64(20 + o) and point == float64(30 + o),
      "source of trace " & $o & ": " & $line & " " & $point
    doAssert g.traceKeys(o).srcLine == float64(20 + o)
  # the trace's own Timestamp is set by name, whatever the record's time gives it
  var counts = StartCount()
  let over = traceOverrides(src, 0, 1, sampleUs(10), currentVendors(), true, false, counts)
  var stamp = -1'i64
  for o in over:
    if o.name == "timestamp.timeZeroOfData": stamp = int64(o.value.toFloat)
  doAssert stamp == utcUsToGpsUs(sampleUs(10)), "the Timestamp override is " & $stamp
  doAssert sourceBlocks(src, 0) == (true, true)

proc checkTrigger(dir: string; jobs: Jobs) =
  ## A map that declares `triggerTime` beside the start: both are set to the slice's first
  ## sample, exactly; a map with the start only leaves the second block as carried; a
  ## trigger in a unit the viewer does not convert is left and counted.
  base = BaseUs
  let path = dir / "rec" / "trig.sgd"
  makeRecording(path, 1)
  var src = openSeismic(path, keys = true)
  defer: src.close()
  for (unit, name) in [("us GPS", "both"), ("", "startonly"), ("ms of day", "other")]:
    discard publishMaps(dir, [rev2Map(unit)])
    let got = runCut(jobs, src, path, dir / "out" / ("trig-" & name & ".sgd"), shotsOf(true),
      initCutOptions(LengthMs, StartMs))
    doAssert got.st == jsDone and got.res.carried, got.error & got.res.reason
    var g = openSeismic(dir / "out" / ("trig-" & name & ".sgd"), keys = true)
    defer: g.close()
    for s in 0 ..< 3:
      let firstUs = shotUs(s) + int64(StartMs * 1000)
      let a = g.headerBytes(s)
      let b = src.headerBytes(FirstSamples[s] div SegLen)
      doAssert a.get64(52) == gpsOf(firstUs), name & ": start of trace " & $s
      if unit == "us GPS":
        doAssert a.get64(52 + 32 + 8) == gpsOf(firstUs), "trigger time of trace " & $s
      else:
        doAssert a.get64(52 + 32 + 8) == b.get64(52 + 32 + 8),
          name & ": trigger time of trace " & $s & " changed"
    let said = got.res.lines.join("|")
    case name
    of "both":
      doAssert got.res.triggerRewritten == 3 and got.res.triggerLeft == 0 and
        "start time was rewritten to the slice's in 3 traces and its trigger time in 3 traces" in
        said, said
    of "startonly":
      doAssert got.res.triggerRewritten == 0 and got.res.triggerLeft == 0 and
        "trigger" notin said, said
    else:
      doAssert got.res.triggerRewritten == 0 and got.res.triggerLeft == 3 and
        "3 traces keep the trigger time of the recording" in said, said

proc checkTriggerNoUnit(dir: string; jobs: Jobs) =
  ## A trigger field with no unit (a shipped map has one): in a recording whose trigger is
  ## its start time, in the same encoding, it takes the start's new value and is counted
  ## as rewritten; a trigger that differs from the start, or one in another encoding, is
  ## left and counted, with the sentence. Seen failing with the trigger left whatever it
  ## held ("same: trigger time of trace 0 is -20000 us off the first sample").
  base = BaseUs
  let same = dir / "rec" / "trig-same.sgd"
  let differs = dir / "rec" / "trig-differs.sgd"
  makeRecording(same, 1, trigger = true)
  makeRecording(differs, 1)
  for (name, path, enc) in [("same", same, "i64"), ("differs", differs, "i64"),
      ("encoding", same, "u64")]:
    discard publishMaps(dir, [rev2Map("none", enc)])
    var src = openSeismic(path, keys = true)
    defer: src.close()
    let dest = dir / "out" / ("trig-" & name & ".sgd")
    let got = runCut(jobs, src, path, dest, shotsOf(true), initCutOptions(LengthMs, StartMs))
    doAssert got.st == jsDone and got.res.carried, got.error & got.res.reason
    var g = openSeismic(dest, keys = true)
    defer: g.close()
    let said = got.res.lines.join("|")
    for s in 0 ..< 3:
      let firstUs = shotUs(s) + int64(StartMs * 1000)
      let a = g.headerBytes(s)
      let b = src.headerBytes(FirstSamples[s] div SegLen)
      doAssert a.get64(52) == gpsOf(firstUs), name & ": start of trace " & $s
      if name == "same":
        doAssert a.get64(52 + 32 + 8) == gpsOf(firstUs), name & ": trigger time of trace " & $s &
          " is " & $(a.get64(52 + 32 + 8) - gpsOf(firstUs)) & " us off the first sample"
      else:
        doAssert a.get64(52 + 32 + 8) == b.get64(52 + 32 + 8),
          name & ": trigger time of trace " & $s & " changed"
    if name == "same":
      doAssert got.res.triggerRewritten == 3 and got.res.triggerLeft == 0 and
        "its trigger time in 3 traces" in said, said
    else:
      doAssert got.res.triggerRewritten == 0 and got.res.triggerLeft == 3 and
        "3 traces keep the trigger time of the recording" in said, name & ": " & said

proc checkTriggerOtherMap(dir: string; jobs: Jobs) =
  ## A recording whose own map has no trigger field, with another manufacturer's map that
  ## has one loaded too: no trace is counted and nothing is said of a trigger. Seen failing
  ## with the count taken from every map loaded ("3 traces keep the trigger time").
  base = BaseUs
  discard publishMaps(dir, [rev2Map(""), rev2Map("ms of day", maker = 78)])
  let path = dir / "rec" / "trig-own.sgd"
  makeRecording(path, 1)
  var src = openSeismic(path, keys = true)
  defer: src.close()
  let got = runCut(jobs, src, path, dir / "out" / "trig-own.sgd", shotsOf(true),
    initCutOptions(LengthMs, StartMs))
  doAssert got.st == jsDone and got.res.carried, got.error & got.res.reason
  let said = got.res.lines.join("|")
  doAssert got.res.startRewritten == 3 and got.res.triggerRewritten == 0 and
    got.res.triggerLeft == 0 and "trigger" notin said, said

proc checkFallback(dir: string; jobs: Jobs) =
  ## A recording of two records cannot be carried (a subset is made of one record's traces):
  ## the headers are built from the options, and the result says why. Fails with the line
  ## missing; the window's Format entry says the same, in `facts.carryHeaderBytes`.
  base = BaseUs
  discard publishMaps(dir, [rev2Map("")])
  let path = dir / "rec" / "two.sgd"
  makeRecording(path, 1, split = 3)
  var src = openSeismic(path, keys = true)
  defer: src.close()
  let got = runCut(jobs, src, path, dir / "out" / "two.sgd", shotsOf(true),
    initCutOptions(LengthMs, StartMs))
  doAssert got.st == jsDone and not got.res.carried, got.error & got.res.reason
  let said = got.res.lines.join("|")
  doAssert "The headers were built from the options, not carried from the source: " &
    "the traces the shots read lie in more than one record" in said, said
  var g = openSeismic(dir / "out" / "two.sgd", keys = true)
  defer: g.close()
  doAssert g.index.segdRecords[0].revision.major == 3

proc checkOrder(dir: string; jobs: Jobs) =
  ## A gap in one component only: its trace comes from a later segment, so the source order
  ## puts it last, and the trace numbers still follow the components in every record.
  ## Fails with the trace numbers left in output order ("trace number of component 1").
  base = BaseUs
  discard publishMaps(dir, [rev2Map("")])
  let path = dir / "rec" / "order.sgd"
  makeRecording(path, 3, missing = @[(2, 1)])
  var src = openSeismic(path, keys = true)
  defer: src.close()
  let got = runCut(jobs, src, path, dir / "out" / "order.sgd", shotsOf(true),
    initCutOptions(LengthMs, StartMs))
  doAssert got.st == jsDone and got.res.carried and got.res.shotsRefused == 0, $got.res
  var g = openSeismic(dir / "out" / "order.sgd", keys = true)
  defer: g.close()
  var orders: seq[seq[int]] = @[]
  for s in 0 ..< 3:
    var comps: seq[int] = @[]
    for o in s * 3 ..< s * 3 + 3:
      let c = int(g.traceField(o, "ext1.sensorType").intVal) - 2
      comps.add c
      doAssert int(g.traceField(o, "trace.traceNumber").intVal) == c + 1,
        "trace number of component " & $c & " in record " & $s
    orders.add comps
  doAssert orders[1] == @[0, 2, 1], "the middle record is in source order: " & $orders

proc main*() =
  let dir = getTempDir() / ("viewseg-cutcarry-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  createDir(dir / "maps")
  createDir(dir / "rec")
  createDir(dir / "out")
  writeFile(dir / "maps" / "clock.nif", Map)
  let load = loadVendorFolders(@[VendorFolder(dir: dir / "maps", origin: voProject)])
  doAssert load.registry.maps.len == 1, $load.problems
  publishVendors(load.registry)
  defer: publishVendors(VendorRegistry())
  let jobs = initJobs()
  for comps in [1, 3]:
    check(dir, jobs, comps, load.registry)
  checkRev2Time(dir, jobs)
  for comps in [1, 3]:
    for startMs in [-20.0, 0.0, 10.0]:
      checkRev3(dir, jobs, comps, startMs, BaseUs)
  # a shot before a GPS leap second whose first sample comes after it
  checkRev3(dir, jobs, 3, 10.0, 1_483_228_799_800_000'i64)
  checkRev3(dir, jobs, 1, 100.0, 1_483_228_799_800_000'i64)
  for comps in [1, 3]:
    checkRev3(dir, jobs, comps, 0.0, BaseUs, csUs = 4000)
  checkNoSourcePlace(dir, jobs)
  checkSourcePlace(dir, jobs)
  checkTrigger(dir, jobs)
  checkTriggerNoUnit(dir, jobs)
  checkTriggerOtherMap(dir, jobs)
  checkOrder(dir, jobs)
  checkFallback(dir, jobs)
  publishVendors(load.registry)
  checkGapsAndRefusals(dir, jobs)
  checkSourceFormat(dir, jobs)
  # the window's Format entry: the source's revision for a SEG-D source, Rev 3 otherwise
  doAssert standardWords(csSegdRev3, true) == "SEG-D (the source's revision)"
  doAssert standardWords(csSegdRev3) == "SEG-D Rev 3" and standardWords(csSegy, true) == "SEG-Y"

when isMainModule:
  main()
