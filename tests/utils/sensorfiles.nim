## Synthetic SEG-D Rev 3 files whose traces carry a Sensor Info block, for the tests of the
## "Sensor serial" file-name part. Every number is made up.

import std/[options, os]
import parseSEG
import parseSEG/io/diskio
import parseSEG/segd/writer

proc sensorBlock(serial: string): seq[byte] =
  ## A Sensor Info block: the serial in bytes 14-31 (18 bytes), type 0x41.
  result = newSeq[byte](32)
  for i in 0 ..< min(serial.len, 18): result[13 + i] = byte(serial[i])
  for i in serial.len ..< 18: result[13 + i] = byte(' ')
  result[31] = 0x41

proc vendorBlock(serial: int64): seq[byte] =
  ## A vendor block of type 0xB0 holding `serial` (u32 big-endian) from byte 3.
  result = newSeq[byte](32)
  for i in 0 .. 3: result[2 + i] = byte((serial shr (8 * (3 - i))) and 255)
  result[31] = 0xB0

proc writeOneRecord(path, serial: string; vendor: int64) =
  ## One record of one trace; an empty `serial` writes no Sensor Info block, a negative
  ## `vendor` no vendor block.
  var ext = if serial.len > 0: sensorBlock(serial) else: newSeq[byte]()
  if vendor >= 0: ext.add vendorBlock(vendor)
  var r = SegdRecord(layout: slRev3, format: some(sd8058),
    revision: SegdRevision(major: 3, minor: 0))
  r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: 8058, year: 24,
    additionalGhBlocks: 2, julianDay: 61, hour: 6, minute: 7, second: 8,
    baseScanInterval16: 16, recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1,
    channelSetsPerScanType: 1)
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 1, revisionMajor: 3, revisionMinor: 0,
    extRecordLength: 1000, blockType: BlockTypeGeneralHeader2)
  r.gh3 = SegdGeneralHeader3(timeZero: unixToTimestamp(1_709_273_228.0),
    blockType: BlockTypeGeneralHeader3)
  var t = SegdTrace(layout: slRev3, index: 0, numSamples: 1)
  t.ext1Rev3 = some(SegdTraceHeaderExt1Rev3(numSamples: 1, sensorType: 1, depthIndex: 1,
    blockType: BlockTypeTraceHeaderExt1))
  t.extensions = ext
  let blocks = uint8(1 + ext.len div 32)
  t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1, channelSetNumber: 1,
    traceNumber: 1, traceHeaderExtensions: blocks)
  var d = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1,
    channelType: 0x10, endTime: 1000, numSamples: 1, descaleMultiplier: 1.0,
    channelsInSet: 1, samplingInterval: 1000, arrayForming: 1, traceHeaderExtensions: blocks,
    verticalStack: 1, blockType1: BlockTypeChannelSet1, blockType2: BlockTypeChannelSet2,
    blockType3: BlockTypeChannelSet3)
  for i in 0 ..< d.description.len: d.description[i] = ' '
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[d])]
  t.samples = newSeq[byte](dataBytes(sd8058, 1))
  encodeSamples(sd8058, [1.0'f32], t.samples)
  computeRev3Sizes(r, [t])
  r.traceCount = 1
  let sink = openDiskSink(path)
  var w = openSegdWriter(sink)
  w.writeRecordHeaders(r)
  w.writeTrace(t)
  w.endRecord()
  w.close()
  sink.close()

proc writeSensorFile*(path: string; serials: openArray[string]; vendor = -1'i64) =
  ## A SEG-D Rev 3 file of one record per entry, each of one trace whose Sensor Info
  ## block holds that serial (no block when the entry is empty). A `vendor` of 0 or more
  ## adds to every trace a vendor block (type 0xB0) holding it as a u32 from byte 3.
  var all = ""
  for i, s in serials:
    let part = path & ".part" & $i
    writeOneRecord(part, s, vendor)
    all.add readFile(part)
    removeFile(part)
  writeFile(path, all)
