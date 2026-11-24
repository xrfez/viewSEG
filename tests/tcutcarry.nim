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
import parseSEG/segd/[reader, writer, headers, samples]
import parseSEG/io/diskio
import viewSEG/core/[cutgather, cutgatherjobs, jobs, segmentclock, shotlog, vendormaps]
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

func gpsOf(utcUs: int64): int64 =
  utcUs - GpsEpochUs + Leap * 1_000_000

func sampleUs(k: int): int64 =
  BaseUs + int64(k) * DtUs

func value(comp, k: int): float32 =
  float32(1000 * comp + k)

proc makeRecording(path: string; comps: int; fmt = sd8058) =
  ## Rev 2.1, one record: an extended header, a source header, one channel set
  ## with filter and gain fields set, a trace per segment and component (segment
  ## by segment), each with two vendor blocks.
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
      channelCount: Segments * comps, channelType: 1, traceHeaderExtensions: 3,
      aliasFilterFreq: 200, aliasFilterSlope: 72, lowCutFreq: 3, lowCutSlope: 18,
      notch1Freq: 500, gainControl: 3, verticalStack: 1)])]
  r.traceCount = Segments * comps
  var all: seq[SegdTrace]
  for seg in 0 ..< Segments:
    for c in 0 ..< comps:
      var t = SegdTrace(layout: slRev2, index: all.len, numSamples: SegLen)
      t.header = SegdTraceHeader(fileNumber: 5, scanTypeNumber: 1, channelSetNumber: 1,
        traceNumber: all.len + 1, traceHeaderExtensions: 3'u8)
      t.ext1 = some SegdTraceHeaderExt1(receiverLineNumber: 2000, receiverPointNumber: 100,
        receiverPointIndex: 1, samplesPerTrace: uint32(SegLen), sensorType: uint8(2 + c))
      t.extensions = newSeq[byte](64)
      for i in 0 ..< 64: t.extensions[i] = byte(31 * all.len + 3 * i + 1)
      let start = gpsOf(sampleUs(seg * SegLen))
      for i in 0 .. 7: t.extensions[i] = byte((start shr (8 * (7 - i))) and 255)
      var v = newSeq[float64](SegLen)
      for j in 0 ..< SegLen: v[j] = float64(value(c, seg * SegLen + j))
      t.samples = newSeq[byte](dataBytes(fmt, SegLen))
      encodeSamples(fmt, v, t.samples)
      all.add t
  let sink = openDiskSink(path)
  try:
    let log = writeSegd(sink, SegdData(records: @[SegdRecordData(record: r, traces: all)]))
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

func shotUs(i: int): int64 =
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
  doAssert got.res.revision == "Rev 2.1" and got.res.startRewritten, $got.res
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
    let t = fromUnix(shotUs(s) div 1_000_000).utc
    doAssert rec.gh1.year == t.year mod 100 and rec.gh1.julianDay == t.yearday + 1 and
      rec.gh1.hour == t.hour and rec.gh1.minute == t.minute and rec.gh1.second == t.second,
      "time of record " & $s
    doAssert g.recordField(s, "gh3.sourceLineNumber").toFloat == float64(20 + s) and
      g.recordField(s, "gh3.sourcePointNumber").toFloat == float64(30 + s),
      "source line and point of record " & $s

    let firstUs = shotUs(s) + int64(StartMs * 1000)
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
  checkGapsAndRefusals(dir, jobs)
  checkSourceFormat(dir, jobs)
  # the window's Format entry: the source's revision for a SEG-D source, Rev 3 otherwise
  doAssert standardWords(csSegdRev3, true) == "SEG-D (the source's revision)"
  doAssert standardWords(csSegdRev3) == "SEG-D Rev 3" and standardWords(csSegy, true) == "SEG-Y"

when isMainModule:
  main()
