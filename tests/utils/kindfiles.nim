## Synthetic recordings of known kinds, written as SEG-D, for the tests of what a file is as
## a recording: `writeSpecs` (a trace per `Spec`, SEG-D Rev 3, 2 ms, one record per trace),
## `writeSegySpecs` (the same in SEG-Y) and `writeClockRecording` (six traces of one receiver whose vendor block holds each start
## time, read through `clockRegistry`); `writeMultiplexed`, a multiplexed SEG-D record.

import std/[options, os]
import parseSEG
import parseSEG/io/diskio
import parseSEG/segd/blocks
import viewSEG/core/vendormaps

const
  BaseS* = 1_772_323_200.0 # 2026-03-01T00:00:00 UTC
  SpecDtMs* = 2.0

type Spec* = tuple[rcv, first, comp: int, stationed: bool, extra: int]

func spec*(rcv, first: int; comp = 0; stationed = true; extra = 0): Spec =
  ## `extra` moves the channel number alone: another channel of the same component type.
  (rcv, first, comp, stationed, extra)

func specKeys(i: int; s: Spec; channelPerTrace, coded: bool): TraceKeys =
  result = initTraceKeys()
  result.status = tsLive
  result.record = float64(i + 1)
  result.channel =
    if channelPerTrace: float64(i + 1)
    else: float64(s.rcv * 4 + s.comp + 1 + s.extra * 100)
  result.component = if coded: uint8(s.comp + 1) else: 0'u8
  result.intervalUs = 2000
  result.t0Ms = 0
  result.time = BaseS + float64(s.first) * SpecDtMs / 1000
  if s.stationed:
    result.rcvLine = 1
    result.rcvPoint = float64(s.rcv + 1)

proc writeSpecs*(dir, name: string; specs: openArray[Spec]; n = 1000;
    channelPerTrace = false; coded = true): string =
  ## A file of one trace per spec: its receiver, first sample (its start), component.
  ## `channelPerTrace`: the channel number is the trace number, as some recorders write it;
  ## `coded` false: every component is 0 (not coded).
  createDir(dir)
  result = dir / (name & ".sgd")
  var w = openSeismicWriter(result, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: n))
  for i, s in specs:
    var samples = newSeq[float32](n)
    for j in 0 ..< n: samples[j] = float32(s.first + j)
    w.writeTrace(specKeys(i, s, channelPerTrace, coded), samples)
  discard w.close()

proc writeSegySpecs*(dir, name: string; specs: openArray[Spec]; n = 1000;
    channelPerTrace = false): string =
  ## `writeSpecs` as a SEG-Y file, one record. SEG-Y keeps no receiver line, so a station
  ## is placed by its group coordinates.
  createDir(dir)
  result = dir / (name & ".sgy")
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for i, s in specs:
    var k = specKeys(i, s, channelPerTrace, coded = true)
    k.record = 1
    if s.stationed:
      k.rcvX = 512_300 + 50 * float64(s.rcv)
      k.rcvY = 6_401_200
    w.writeTrace(k, newSeq[float32](n))
  discard w.close()

const
  ClockSegments* = 6
  ClockLen = 40
  ClockDtUs = 2000'i64
  ClockBaseUs = 1_772_323_200_000_000'i64
  Leap = 18'i64
  GpsEpochUs = 315_964_800_000_000'i64

func clockStart*(i: int): int64 =
  ## The vendor start count of segment `i` (GPS microseconds).
  ClockBaseUs + int64(i) * ClockLen * ClockDtUs - GpsEpochUs + Leap * 1_000_000

proc clockRegistry*(dir: string): VendorRegistry =
  ## The made-up map (manufacturer 77) that reads the vendor block's start, as GPS time.
  createDir(dir)
  writeFile(dir / "clock.nif", "(.nif27)\n(vendormap \"clock-test\" (version 1) (match " &
    "(format segd) (rev 3.0 3.1) (manufacturer 77))\n  (target (kind block) (type 0xB0) " &
    "(where traceHeader) (name vendorClock)\n    (field firstSampleTime (at 1) (enc i64) " &
    "(sentinel 0) (unit \"us GPS\"))))\n")
  let load = loadVendorFolders(@[VendorFolder(dir: dir, origin: voProject)])
  doAssert load.registry.maps.len == 1, $load.problems
  result = load.registry

proc blk(t: uint8): seq[byte] =
  result = newSeq[byte](32)
  result[31] = t

proc writeClockRecording*(path: string; raw: openArray[int64]) =
  ## One record, a trace per entry of `raw`: its vendor start-time count.
  let fmt = sd8058
  var r = SegdRecord(layout: slRev3, format: some(fmt),
    revision: SegdRevision(major: 3, minor: 0))
  r.generalBlocks.add blk(0x11)
  r.gh1 = SegdGeneralHeader1(fileNumber: 7, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: 3, julianDay: 60, hour: 0, minute: 0, second: 0,
    manufacturerCode: 77, baseScanInterval16: 32, recordType: 8,
    recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 1)
  let endUs = int32(ClockDtUs * (ClockLen - 1))
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 7, revisionMajor: 3,
    extRecordLength: uint32(endUs), blockType: 2)
  r.gh3 = SegdGeneralHeader3(timeZero: ClockBaseUs, blockType: 3)
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[
    SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1, channelType: 0x10,
      endTime: endUs, numSamples: ClockLen, descaleMultiplier: 1.0, channelsInSet: uint32(raw.len),
      samplingInterval: uint32(ClockDtUs), traceHeaderExtensions: 2, verticalStack: 1,
      blockType1: 0x30, blockType2: 0x31, blockType3: 0x32)])]
  var traces: seq[SegdTrace]
  for tn in 1 .. raw.len:
    var t = SegdTrace(layout: slRev3, index: traces.len, numSamples: ClockLen)
    t.header = SegdTraceHeader(fileNumber: 7, scanTypeNumber: 1, channelSetNumber: 1,
      traceNumber: tn, traceHeaderExtensions: 2)
    t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(
      receiverLineNumber: 100,
      receiverPointNumber: 101,
      receiverPointIndex: 1, numSamples: ClockLen,
      sensorType: 2'u8, blockType: 0x40)
    var vendor = blk(0xB0)
    for i in 0 .. 7: vendor[i] = byte((raw[tn - 1] shr (8 * (7 - i))) and 255)
    t.extensions = vendor
    var v = newSeq[float32](ClockLen)
    for j in 0 ..< ClockLen: v[j] = float32((tn - 1) * ClockLen + j)
    t.samples = newSeq[byte](dataBytes(fmt, ClockLen))
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

proc writeMultiplexed*(path: string) =
  ## One multiplexed SEG-D record (format 0058): four channels of six scans of 2 ms.
  const channels = 4
  const scans = 6
  const bytesPerScan = 8 + 4 * channels
  func bcd6(n: int): array[3, byte] =
    var v = n
    for i in countdown(2, 0):
      result[i] = byte((v mod 10) or ((v div 10 mod 10) shl 4))
      v = v div 100
  let g = SegdGeneralHeader1(fileNumber: 12, formatCode: 58, year: 26, julianDay: 60,
    hour: 0, minute: 0, second: 0, manufacturerCode: 9, baseScanInterval16: 32,
    unused20: bcd6(bytesPerScan), recordType: 8, recordLength: 1, scanTypesPerRecord: 1,
    channelSetsPerScanType: 1, skewBlocks: 1)
  var data: seq[byte] = @(g.encoded)
  let d = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1, startTime: 0,
    endTime: uint16(scans), channelCount: channels, channelType: 1, gainControl: 3)
  data.add @(d.encoded)
  for i in 0 ..< 32: data.add 0
  for scan in 0 ..< scans:
    let t = uint32(scan * 2 * 256)
    data.add [0xFF'u8, 0xFF, 0xFF, 0x41, byte(t shr 16), byte((t shr 8) and 0xFF),
      byte(t and 0xFF), 0]
    for ch in 0 ..< channels: data.add [0x3F'u8, 0x80, 0, 0]
  writeFile(path, cast[string](data))
