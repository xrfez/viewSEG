## A slice built from header keys takes the filters, the gain and the sensor from the
## recording's own headers, each output trace from the segment that holds its first sample,
## and says in the text header (SEG-Y) or the external header (SEG-D) that it was sliced.
## The recordings are built here: six segments of 40 samples at 2 ms per component, two
## components; the SEG-D one in two records with different channel set descriptors (filters
## and gain), the SEG-Y one with different trace header fields in its first and last segments.
##
## Seen failing (by breaking the code under test): the facts not passed to the writer ("low-cut
## of trace 0: 0 vs 3"); the facts of the first segment used for every trace ("gain type of
## trace 2: 1 vs 2"); the trace code not set ("trace id code of trace 0: 1 vs 12"); the text
## lines not given to the writer ("card 2"); a name's bad character left as it is (the library
## refused the header); the sentence of what has no field not added ("Not written");
## the external header not passed ("external header of record 0"); the SEG-Y source's fields
## not read ("gain constant of trace 0: 0 vs 24"); and, for a source with no such facts, the
## bytes after the text header differ from the code before the change (`NoFactsHash`).

import std/[assertions, os, strutils, hashes]
import parseSEG
import parseSEG/model/traceindex
import parseSEG/segd/[writer, headers, samples]
import parseSEG/io/diskio
import viewSEG/core/[cutfills, cutgather, cutgatherjobs, jobs, shotlog, vendormaps, versions]
import utils/waiting

const
  Segments = 6
  SegLen = 40
  DtUs = 2000'i64
  BaseUs = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC
  Leap = 18'i64                      # GPS minus UTC in 2026
  GpsEpochUs = 315_964_800_000_000'i64
  StartMs = -20.0
  LengthMs = 60.0
  Window = 30
  FirstSamples = [10, 200]           ## the first record's segment 0; the second's segment 5
  Files = [101, 102]
  NoFactsHash = 1224185169010730424  ## FNV of the bytes after the text header; set from the code before the change
  Map = "(.nif27)\n(vendormap \"fills-test\" (version 1) (match (format segd) " &
    "(manufacturer 77))\n  (target (kind traceExt) (extension 2) (name vendorClock)\n" &
    "    (field firstSampleTime (at 1) (enc i64) (sentinel 0) (unit \"us GPS\"))))\n"

func gpsOf(utcUs: int64): int64 =
  utcUs - GpsEpochUs + Leap * 1_000_000

func sampleUs(k: int): int64 =
  BaseUs + int64(k) * DtUs

func value(comp, k: int): float32 =
  float32(1000 * comp + k)

func shotUs(i: int): int64 =
  sampleUs(FirstSamples[i]) - int64(StartMs * 1000) + 123 * int64(i)

proc makeSegd(path: string; facts: bool) =
  ## Rev 2.1, two records (segments 0 to 2, then 3 to 5), one channel set each. With
  ## `facts`: record one has a 3 Hz low-cut of 18 dB/octave, an alias filter of 200 Hz,
  ## 72 dB/octave, a notch at 50.0 Hz and fixed gain; record two 5 Hz, 12, 300 Hz, 96,
  ## 60.0 Hz, a second notch and binary gain. The sensors are types 2 and 3.
  let fmt = sd8058
  var r = SegdRecord(layout: slRev2, format: some(fmt),
    revision: SegdRevision(major: 2, minor: 1))
  r.gh1 = SegdGeneralHeader1(fileNumber: 5, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: 1, julianDay: 60, manufacturerCode: 77, baseScanInterval16: 32,
    recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 1,
    extendedHeaderBlocks: 0)
  r.gh2 = some SegdGeneralHeader2(extFileNumber: 5, revisionMajor: 2, revisionMinor: 1,
    extRecordLength: uint32(2 * SegLen * Segments), blockNumber: 2)
  var d = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1, startTime: 0,
    endTime: uint16(SegLen), channelCount: 0, channelType: 1, traceHeaderExtensions: 3,
    verticalStack: 1)
  if facts:
    d.aliasFilterFreq = 200
    d.aliasFilterSlope = 72
    d.lowCutFreq = 3
    d.lowCutSlope = 18
    d.notch1Freq = 500
    d.gainControl = 3
  r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[d])]
  var records: seq[SegdRecordData] = @[]
  for part in 0 .. 1:
    var rec = r
    rec.gh1.fileNumber = 5 + part
    rec.gh2.get.extFileNumber = uint32(5 + part)
    if facts and part == 1:
      var d2 = d
      d2.lowCutFreq = 5
      d2.lowCutSlope = 12
      d2.aliasFilterFreq = 300
      d2.aliasFilterSlope = 96
      d2.notch1Freq = 600
      d2.notch2Freq = 1200
      d2.gainControl = 8
      rec.scanTypes[0].descriptors[0] = d2
    var all: seq[SegdTrace] = @[]
    for seg in part * 3 ..< part * 3 + 3:
      for c in 0 .. 1:
        var t = SegdTrace(layout: slRev2, index: all.len, numSamples: SegLen)
        t.header = SegdTraceHeader(fileNumber: 5 + part, scanTypeNumber: 1,
          channelSetNumber: 1, traceNumber: all.len + 1, traceHeaderExtensions: 3'u8)
        t.ext1 = some SegdTraceHeaderExt1(receiverLineNumber: 2000, receiverPointNumber: 100,
          receiverPointIndex: 1, samplesPerTrace: uint32(SegLen),
          sensorType: (if facts: uint8(2 + c) else: 0'u8))
        t.extensions = newSeq[byte](64)
        let start = gpsOf(sampleUs(seg * SegLen))
        for i in 0 .. 7: t.extensions[i] = byte((start shr (8 * (7 - i))) and 255)
        var v = newSeq[float64](SegLen)
        for j in 0 ..< SegLen: v[j] = float64(value(c, seg * SegLen + j))
        t.samples = newSeq[byte](dataBytes(fmt, SegLen))
        encodeSamples(fmt, v, t.samples)
        all.add t
    rec.scanTypes[0].descriptors[0].channelCount = all.len
    rec.traceCount = all.len
    records.add SegdRecordData(record: rec, traces: all)
  let sink = openDiskSink(path)
  try:
    let log = writeSegd(sink, SegdData(records: records))
    doAssert log.len == 0, $log
  finally:
    sink.close()

proc makeSegy(path: string; facts: bool) =
  ## The same recording as SEG-Y keys. With `facts`, segments 0 to 2 say gain type 1,
  ## constant 24 dB, initial 12 dB, low-cut 8 Hz at 18, high-cut 125 Hz at 72, alias 200 at
  ## 48, notch 50 at 12; segments 3 to 5 gain type 2, 36, 6, 10 at 24, 250 at 36, 180 at 96,
  ## 60 at 6. The first component is a vertical sensor (code 12), the second in-line (14).
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for seg in 0 ..< Segments:
    for c in 0 .. 1:
      var samples = newSeq[float32](SegLen)
      for j in 0 ..< SegLen: samples[j] = value(c, seg * SegLen + j)
      var k = initTraceKeys()
      k.status = tsLive
      k.record = float64(seg + 1)
      k.channel = float64(c + 11)
      k.intervalUs = 2000
      k.t0Ms = 0
      k.time = float64(sampleUs(seg * SegLen) div 1_000_000) +
        float64(sampleUs(seg * SegLen) mod 1_000_000) / 1e6
      k.rcvLine = 2000
      k.rcvPoint = 100
      var over: seq[HeaderOverride] = @[]
      if facts:
        k.traceCode = (if c == 0: 12 else: 14)
        let late = seg >= 3
        for (name, early, later) in [("gainType", 1, 2), ("instrumentGainConstant", 24, 36),
            ("instrumentInitialGain", 12, 6), ("lowCutFreq", 8, 10), ("lowCutSlope", 18, 24),
            ("highCutFreq", 125, 250), ("highCutSlope", 72, 36), ("aliasFilterFreq", 200, 180),
            ("aliasFilterSlope", 48, 96), ("notchFilterFreq", 50, 60),
            ("notchFilterSlope", 12, 6)]:
          over.add headerOverride("trace." & name, if late: later else: early)
      w.writeTrace(k, samples, over)
  discard w.close()

proc shotsOf(): CutShots =
  var text = ""
  for i in 0 ..< 2: text.add $Files[i] & "," & $shotUs(i) & "\n"
  var m = initShotLogMap()
  m.hasHeader = false
  m.roles = @[crFileNumber, crUtcMicros]
  shotsInTime(shots(parseShotLog(text, m), m).rows)

type Ran = tuple[st: JobState; res: CutResult; error: string]

proc runCut(jobs: Jobs; f: var SeismicFile; source, dest: string; opts: CutOptions): Ran =
  let sink = CutSink()
  let id = jobs.submit(cutGatherSpec(source, dest),
    cutGatherWork(addr f, source, dest, shotsOf(), opts, sink))
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the cut did not finish"
  let info = jobs.info(id).get
  (info.state, sink.result, info.error)

proc cut(jobs: Jobs; source, dest: string; standard: CutStandard; logName = "shots.csv"): Ran =
  var src = openSeismic(source, keys = true)
  defer: src.close()
  var opts = initCutOptions(LengthMs, StartMs, standard = standard)
  opts.logName = logName
  result = runCut(jobs, src, source, dest, opts)
  doAssert result.st == jsDone and result.res.ok, result.error & " / " & result.res.reason

proc intField(f: SeismicFile; trace: int; name: string): int =
  int(f.traceField(trace, "trace." & name).intVal)

func fnv(bytes: string): int =
  var h = 14695981039346656037'u64
  for c in bytes:
    h = (h xor uint64(ord(c))) * 1099511628211'u64
  int(h and 0x3FFF_FFFF_FFFF_FFFF'u64)

const Fields = ["lowCutFreq", "lowCutSlope", "aliasFilterFreq", "aliasFilterSlope",
  "highCutFreq", "highCutSlope", "notchFilterFreq", "notchFilterSlope", "gainType",
  "instrumentGainConstant", "instrumentInitialGain"]

proc check(dir: string; jobs: Jobs) =
  # --- a SEG-D source: each shot takes the filters, gain and sensor of its own segment
  let sgd = dir / "rec" / "a.sgd"
  makeSegd(sgd, facts = true)
  let a = cut(jobs, sgd, dir / "out" / "a.sgy", csSegy)
  var f = openSeismic(dir / "out" / "a.sgy", keys = true)
  defer: f.close()
  doAssert f.len == 4
  # [low-cut, slope, alias, slope, high-cut, slope, notch, slope, gain type, gain, initial]
  let record = [[3, 18, 200, 72, 0, 0, 50, 0, 1, 0, 0], [5, 12, 300, 96, 0, 0, 60, 0, 2, 0, 0]]
  for s in 0 .. 1:
    for c in 0 .. 1:
      let t = s * 2 + c
      for i, name in Fields:
        doAssert f.intField(t, name) == record[s][i],
          name & " of trace " & $t & ": " & $f.intField(t, name) & " vs " & $record[s][i]
      let code = if c == 0: 12 else: 14
      doAssert f.intField(t, "traceIdCode") == code,
        "trace id code of trace " & $t & ": " & $f.intField(t, "traceIdCode") & " vs " & $code
  let said = a.res.lines.join("|")
  doAssert "Filters and gain were taken from the recording's own headers." in said, said
  doAssert "sensor type of each trace was taken" in said, said
  doAssert "Not written in the output: second and third notch filters (no field for them in " &
    "SEG-Y revision 2.1)." in said, said
  doAssert "rounded" notin said and "does not fit" notin said, said
  # the text header: the writer's own card, then the two of this program, exact
  let cards = f.textHeader.split('\n')
  doAssert cards[1].strip == "C 2 SLICED BY viewSEG " & ViewSEGVersion & " FROM a.sgd",
    "card 2: " & cards[1]
  doAssert cards[2].strip == "C 3 SHOT LOG shots.csv, 2 SHOTS, RECORDS START AT THE SHOT TIME",
    "card 3: " & cards[2]
  doAssert cards[0].startsWith("C 1 WRITTEN BY parseSEG "), cards[0]
  doAssert cards[1].len == 80 and cards[2].len == 80 and "?" notin f.textHeader
  doAssert "textual header says" in said, said

  # --- a SEG-Y source: its own fields, per segment, and a SEG-D output with the note
  let sgy = dir / "rec" / "b.sgy"
  makeSegy(sgy, facts = true)
  let b = cut(jobs, sgy, dir / "out" / "b.sgy", csSegy)
  var g = openSeismic(dir / "out" / "b.sgy", keys = true)
  defer: g.close()
  doAssert g.len == 4
  let early = [8, 18, 200, 48, 125, 72, 50, 12, 1, 24, 12]
  let late = [10, 24, 180, 96, 250, 36, 60, 6, 2, 36, 6]
  for s in 0 .. 1:
    for c in 0 .. 1:
      let t = s * 2 + c
      let want = if s == 0: early else: late
      for i, name in Fields:
        doAssert g.intField(t, name) == want[i],
          name & " of trace " & $t & ": " & $g.intField(t, name) & " vs " & $want[i]
      doAssert g.intField(t, "traceIdCode") == (if c == 0: 12 else: 14)
  doAssert "Not written" notin b.res.lines.join("|"), b.res.lines.join("|")
  let toD = cut(jobs, sgy, dir / "out" / "b.sgd", csSegdRev3)
  var h = openSeismic(dir / "out" / "b.sgd", keys = true)
  defer: h.close()
  doAssert h.len == 4 and h.index.segdRecords.len == 2
  for r in 0 .. 1:
    let text = cast[string](h.index.segdRecords[r].external)
    doAssert h.index.segdRecords[r].external.len mod 32 == 0
    doAssert text.startsWith("SLICED BY viewSEG " & ViewSEGVersion & " FROM b.sgy"),
      "external header of record " & $r
    doAssert "SHOT LOG shots.csv, 2 SHOTS, RECORDS START AT THE SHOT TIME" in text, text
  let said2 = toD.res.lines.join("|")
  doAssert "Not written in the output: low-cut filter frequency, low-cut filter slope" in said2 and
    "no field for them in the SEG-D output" in said2, said2
  doAssert "external header says" in said2, said2
  doAssert abs(toD.res.expectedBytes - toD.res.bytesWritten) * 1000 <= toD.res.expectedBytes,
    "estimate " & $toD.res.expectedBytes & ", written " & $toD.res.bytesWritten

  # --- a source with none of these facts: only the cards differ from the code before
  let bare = dir / "rec" / "c.sgd"
  makeSegd(bare, facts = false)
  let c = cut(jobs, bare, dir / "out" / "c.sgy", csSegy)
  let bytes = readFile(dir / "out" / "c.sgy")
  doAssert bytes.len > 3200
  let tail = bytes[3200 .. ^1]
  echo "no-facts hash ", fnv(tail)
  doAssert fnv(tail) == NoFactsHash, "bytes after the text header: " & $fnv(tail)
  let saidC = c.res.lines.join("|")
  doAssert "Filters and gain" notin saidC and "Not written" notin saidC, saidC

  # --- a name the character set cannot hold, in the source and in the log
  let odd = dir / "rec" / "d\xC3\xA9.sgd"
  makeSegd(odd, facts = true)
  let d = cut(jobs, odd, dir / "out" / "d.sgy", csSegy, logName = "log\xE2\x82\xAC.csv")
  var e = openSeismic(dir / "out" / "d.sgy", keys = true)
  defer: e.close()
  let oddCards = e.textHeader.split('\n')
  doAssert oddCards[1].strip == "C 2 SLICED BY viewSEG " & ViewSEGVersion & " FROM d?.sgd",
    "card 2: " & oddCards[1]
  doAssert oddCards[2].strip.startsWith("C 3 SHOT LOG log?.csv, 2 SHOTS"), oddCards[2]
  doAssert d.res.textReplaced == 2, $d.res.textReplaced
  doAssert "2 characters of those file names cannot be written in the textual header" in
    d.res.lines.join("|"), d.res.lines.join("|")

  # --- a long name goes on in the next card, none longer than 80 columns
  let long = dir / "rec" / ("l".repeat(100) & ".sgd")
  makeSegd(long, facts = true)
  discard cut(jobs, long, dir / "out" / "l.sgy", csSegy)
  var l = openSeismic(dir / "out" / "l.sgy", keys = true)
  defer: l.close()
  let longCards = l.textHeader.split('\n')
  doAssert longCards[2].startsWith("C 3   ") and longCards.len == 40
  for card in longCards: doAssert card.len == 80

proc main*() =
  let dir = getTempDir() / ("viewseg-cutfills-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir / "maps")
  createDir(dir / "rec")
  createDir(dir / "out")
  defer: removeDir(dir)
  writeFile(dir / "maps" / "clock.nif", Map)
  let load = loadVendorFolders(@[VendorFolder(dir: dir / "maps", origin: voProject)])
  doAssert load.registry.maps.len == 1, $load.problems
  publishVendors(load.registry)
  defer: publishVendors(VendorRegistry())
  check(dir, initJobs())

when isMainModule:
  main()
