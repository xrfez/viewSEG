## A made-up vendor map and a synthetic SEG-D Rev 2 file of two records of three traces
## it decodes (`tvendorlines`, `tvendorfields`, `tguivendorfields`): a trace-level counter,
## a status holding a sentinel in one trace, a serial that two blocks both define, a
## text label, a repeat and a record-level batch number.

import std/options
import parseSEG
import parseSEG/io/diskio
import parseSEG/segd/blocks

const
  MapText* = """(.nif27)
(vendormap "lines-test" (version 1) (match (format segd) (rev 2.0 2.0) (manufacturer 77))
  (target (kind traceExt) (extension 2) (name unitInfo)
    (field counter (at 1) (enc u32))
    (field status (at 5) (enc u16) (sentinel 0xFFFF))
    (field serial (at 7) (enc u16))
    (field label (at 9) (len 4) (enc ascii) (trim right)))
  (target (kind traceExt) (extension 3) (name aux)
    (field serial (at 1) (enc u16))
    (repeat (count 2) (stride 2) (at 3) (field rep (at 1) (enc u16))))
  (target (kind extendedHeader) (blockIndex 1) (name session)
    (field batch (at 3) (enc u8))))"""
  Records* = 2
  PerRecord* = 3

var bump* = 0 # added to each counter: a file written again with other values

proc counter*(r, j: int): int = 1000 * r + j + bump
func serialOf*(r, j: int): int = 500 + 10 * r + j
func batch*(r: int): int = 40 + r

proc put(b: var seq[byte]; at, bytes, v: int) =
  for k in 0 ..< bytes: b[at + k] = byte((v shr (8 * (bytes - 1 - k))) and 0xFF)

proc ext2(r, j: int): seq[byte] =
  result = newSeq[byte](32)
  result.put(0, 4, counter(r, j))
  result.put(4, 2, if j == 1: 0xFFFF else: 10 * r + j)
  result.put(6, 2, serialOf(r, j))
  for i, c in "AB" & $r & $j: result[8 + i] = byte(c)

proc ext3(r, j: int): seq[byte] =
  result = newSeq[byte](32)
  result.put(0, 2, 900 + 10 * r + j)

proc record(r: int): SegdRecordData =
  var rec = SegdRecord(layout: slRev2, format: some(sd8058),
    revision: SegdRevision(major: 2, minor: 0))
  rec.gh1 = SegdGeneralHeader1(fileNumber: r + 1, formatCode: 8058, year: 24,
    additionalGhBlocks: 1, julianDay: 1, manufacturerCode: 77,
    baseScanInterval16: 32, recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1,
    channelSetsPerScanType: 1, extendedHeaderBlocks: 1)
  rec.gh2 = some SegdGeneralHeader2(extFileNumber: uint32(r + 1), revisionMajor: 2,
      revisionMinor: 0,
    extRecordLength: 1000, blockNumber: 2)
  rec.extended = newSeq[byte](32)
  rec.extended[2] = byte(batch(r))
  let c = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1, startTime: 1,
    endTime: 2, channelCount: PerRecord, channelType: 1, gainControl: 1,
    traceHeaderExtensions: 3, verticalStack: 1, arrayForming: 1)
  rec.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[c])]
  rec.traceCount = PerRecord
  result.record = rec
  for j in 0 ..< PerRecord:
    var t = SegdTrace(layout: slRev2, index: j, numSamples: 1)
    t.ext1 = some(SegdTraceHeaderExt1())
    t.header = SegdTraceHeader(fileNumber: r + 1, scanTypeNumber: 1, channelSetNumber: 1,
      traceNumber: j + 1, traceHeaderExtensions: 3)
    t.extensions.add ext2(r, j)
    t.extensions.add ext3(r, j)
    t.samples = newSeq[byte](dataBytes(sd8058, 1))
    encodeSamples(sd8058, [1.0'f32], t.samples)
    result.traces.add t

proc writeRecords*(path: string; which: openArray[int]) =
  ## The file with only the records `which` (each 0 or 1): its record-level batch number is
  ## that record's, `batch(r)`.
  var d: SegdData
  for r in which: d.records.add record(r)
  let sink = openDiskSink(path)
  try:
    doAssert writeSegd(sink, d).count(sevError) == 0
  finally:
    sink.close()

proc writeLines*(path: string) =
  writeRecords(path, [0, 1])

proc registry*(): VendorRegistry =
  result.addMap loadVendorMap(MapText)
