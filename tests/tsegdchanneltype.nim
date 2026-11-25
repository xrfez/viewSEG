## A SEG-D trace is told seismic or auxiliary by its channel set's type, the same way
## whether the file is opened with its trace keys or without them (the index entries
## alone): synthetic records with one one-trace channel set per type, Rev 2 types 0 to
## 15 and Rev 3 types 0x00 to 0x02, 0x10 to 0x1F, 0x20 to 0x22, 0x28, 0x30, 0x98 and
## 0xFF. Only Rev 1/2 type 1 and Rev 3 types 0x10 and 0x11 are seismic; every other
## type, listed in the code or not, is auxiliary.
##
## Seen to fail: with the rule here narrowed to Rev 3 type 0x10 alone, the 0x11 trace
## failed.

import std/[options, os, strutils]
import parseSEG
import parseSEG/io/diskio
import parseSEG/segd/blocks
import utils/fixtures

const Rev3Types = [0x00, 0x01, 0x02, 0x10, 0x11, 0x12, 0x13, 0x18, 0x1F, 0x20, 0x21, 0x22,
  0x28, 0x30, 0x98, 0xFF]

func seismicByRule(rev3: bool; channelType: int): bool =
  if rev3: channelType in [0x10, 0x11] else: channelType == 1

proc rev2Record(types: openArray[int]): SegdRecordData =
  var rec = SegdRecord(layout: slRev2, format: some(sd8058),
    revision: SegdRevision(major: 2, minor: 0))
  rec.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: 8058, year: 24,
    additionalGhBlocks: 1, julianDay: 1, manufacturerCode: 77, baseScanInterval16: 32,
    recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1,
    channelSetsPerScanType: types.len)
  rec.gh2 = some SegdGeneralHeader2(extFileNumber: 1, revisionMajor: 2, revisionMinor: 0,
    extRecordLength: 1000, blockNumber: 2)
  var sets: seq[SegdChannelSetDescriptor]
  for n, ct in types:
    sets.add SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: n + 1,
      startTime: 1, endTime: 2, channelCount: 1, channelType: uint8(ct), gainControl: 1,
      traceHeaderExtensions: 1, verticalStack: 1, arrayForming: 1)
  rec.scanTypes = @[SegdScanType(layout: slRev2, descriptors: sets)]
  rec.traceCount = types.len
  result.record = rec
  for n in 0 ..< types.len:
    var t = SegdTrace(layout: slRev2, index: n, numSamples: 1)
    t.ext1 = some(SegdTraceHeaderExt1())
    t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1, channelSetNumber: n + 1,
      traceNumber: 1, traceHeaderExtensions: 1)
    t.samples = newSeq[byte](dataBytes(sd8058, 1))
    encodeSamples(sd8058, [1.0'f32], t.samples)
    result.traces.add t

proc rev3Record(types: openArray[int]): SegdRecordData =
  var r = SegdRecord(layout: slRev3, format: some(sd8058),
    revision: SegdRevision(major: 3, minor: 0))
  r.generalBlocks.add newSeq[byte](31) & @[0x11'u8]
  r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: 8058, year: 26,
    additionalGhBlocks: 3, julianDay: 1, manufacturerCode: 77, baseScanInterval16: 32,
    recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1,
    channelSetsPerScanType: types.len)
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 1, revisionMajor: 3,
    extRecordLength: 1000, blockType: 2)
  r.gh3 = SegdGeneralHeader3(timeZero: 1_478_000_000_000_000, blockType: 3)
  var descs: seq[SegdChannelSetDescriptorRev3]
  for n, ct in types:
    descs.add SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: uint16(n + 1),
      channelType: uint8(ct), endTime: 1000, numSamples: 1, descaleMultiplier: 1.0,
      channelsInSet: 1, samplingInterval: 1000, traceHeaderExtensions: 1, verticalStack: 1,
      blockType1: 0x30, blockType2: 0x31, blockType3: 0x32)
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: descs)]
  var traces: seq[SegdTrace]
  for n in 0 ..< types.len:
    var t = SegdTrace(layout: slRev3, index: n, numSamples: 1)
    t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1, channelSetNumber: n + 1,
      traceNumber: 1, traceHeaderExtensions: 1)
    t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(receiverPointIndex: 1, numSamples: 1,
      blockType: 0x40)
    t.samples = newSeq[byte](dataBytes(sd8058, 1))
    encodeSamples(sd8058, [1.0'f32], t.samples)
    traces.add t
  computeRev3Sizes(r, traces)
  r.traceCount = traces.len
  result = SegdRecordData(record: r, traces: traces)

proc write(path: string; rec: SegdRecordData) =
  let sink = openDiskSink(path)
  try:
    doAssert writeSegd(sink, SegdData(records: @[rec])).count(sevError) == 0
  finally:
    sink.close()

proc check(path: string; rev3: bool; types: openArray[int]) =
  var keyed = openSeismic(path, keys = true)
  var plain = openSeismic(path, keys = false)
  try:
    doAssert keyed.len == types.len and plain.len == types.len, path
    for t, ct in types:
      let want = seismicByRule(rev3, ct)
      let name = (if rev3: "Rev 3 0x" else: "Rev 2 type ") & (if rev3: toHex(ct, 2) else: $ct)
      doAssert isSeismic(keyed.index, t) == want, name & ": with keys"
      doAssert isSeismic(plain.index, t) == want, name & ": without keys"
      doAssert (keyed.traceKeys(t).status == tsAuxiliary) == not want, name & ": status"
      echo "tsegdchanneltype: ", name, ": ", if want: "seismic" else: "auxiliary"
  finally:
    keyed.close()
    plain.close()

proc main*() =
  withFixtures fx:
    let rev2 = fx.dir / "types-rev2.sgd"
    var types2: seq[int]
    for ct in 0 .. 15: types2.add ct
    write(rev2, rev2Record(types2))
    check(rev2, false, types2)
    let rev3 = fx.dir / "types-rev3.sgd"
    write(rev3, rev3Record(Rev3Types))
    check(rev3, true, Rev3Types)

when isMainModule:
  main()
