## Small synthetic seismic files for tests, written with parseSEG's own writers
## into a temporary folder. CI has no seismic data, so every test that needs a
## file takes one from here. Each call returns the path of one file, written on
## first use and then reused; `withFixtures` removes the folder afterwards, also
## when the test fails.
##
## ```nim
## import utils/fixtures
## withFixtures fx:
##   var f = openSeismic(fx.surveySegy(), keys = true)
##   doAssert f.len == SurveyTraces
##   f.close()
## # the folder and its files are gone here
## ```
##
## The files (every one opens without a diagnostic):
## - `surveySegy()`: SEG-Y Rev 2.1, IEEE float, `Shots` shot records of
##   `Channels` traces of `Samples` samples at `DtMs`; field record, channel,
##   source point, and source and receiver coordinates in metres. No station
##   lines: those come from the SPS join.
## - `surveySegy(planted)`: the same survey with one `PlantedDefect`.
## - `surveySps()`: the S, R and X files (SPS 2.1) that match the survey.
## - `twoSetSegd()`: SEG-D Rev 3.0, format 8058, one record: a time break, a
##   pilot, and two seismic channel sets (receiver lines 100 and 101).
## - `threeComponentSegd()`: SEG-D Rev 3.0, one record: a time break and three
##   seismic channel sets, one per component (group index 1, 2, 3) at the same
##   stations.
## - `pilotSegy()`: SEG-Y, one sweep trace (trace code 6, auxiliary).
## - `demoFile(name)`: parseSEG's demo files (`demoFileNames`: a post-stack
##   line, a SEG-D shot with three auxiliaries, a Rev 2 record, a SEG-2 line).
##
## **Known values.** The seismic traces hold two events, so tests can assert
## sample values: a plane wave (two cycles of a `WaveHz` sine starting at
## `DirectS + |offset| / VelocityMps`) and a flat event at `FlatS` (one cycle,
## half amplitude, opposite sign). `sample(offset, t)` is the value at time `t`
## for a receiver at `offset`; `surveySample(shot, channel, i)` that of the
## clean survey's sample `i`, `segdSample` that of a SEG-D trace and
## `pilotSample` that of the pilot. Every value is computed in float64 and
## stored as float32, so the formula and the file agree exactly.

import std/[algorithm, math, options, os, strutils, tempfiles]
import parseSEG
import parseSEG/io/diskio # openDiskSink, for a raw SEG-D record
import parseSEG/segd/blocks # encoded, for its general and trace header blocks
# parseSEG's demo-file writer is a tool beside its sources, not part of the
# package's modules: it is found through parseSEG's own search path.
import parseSEG/../../tools/demofiles

export demoFileNames

const
  Shots* = 3              ## shot records in the survey
  Channels* = 24          ## receivers per shot record (channels 1 .. Channels)
  SurveyTraces* = Shots * Channels
  Samples* = 500          ## samples per trace
  DtMs* = 2.0             ## sample interval (ms)
  FirstRecord* = 11       ## field record (FFID) of shot 0; shot k is FirstRecord + k
  SrcLine* = 1.0          ## source line of every shot
  FirstSrcPoint* = 1001.0 ## source point of shot 0; shot k is FirstSrcPoint + k
  RcvLine* = 100.0        ## receiver line of the survey
  FirstRcvPoint* = 101.0  ## receiver point of channel 1; channel c is FirstRcvPoint + c - 1
  OriginX* = 500_000.0    ## easting of receiver point 101 (metres)
  OriginY* = 6_000_000.0  ## northing of receiver line 100
  GroupM* = 25.0          ## receiver spacing
  Elevation* = 100.0      ## of every source and receiver
  WaveHz* = 25.0
  VelocityMps* = 2000.0
  DirectS* = 0.1          ## plane-wave arrival at zero offset
  FlatS* = 0.7            ## flat event
  SegdRecordNo* = 7       ## file number of the SEG-D records
  SegdChannels* = 12      ## traces per seismic channel set
  SegdSamples* = 500
  ComponentScale*: array[3, float64] = [1.0, 0.5, -0.25]
    ## the three-component record's components: the plane wave times these
  PilotSamples* = 1001    ## the pilot: 2 s at `DtMs`, 8 to 80 Hz
  PilotHz* = (8.0, 80.0)

type
  PlantedDefect* = enum
    ## One planted problem in the survey (`surveySegy(planted)`).
    pdNone = "clean"
    pdDeadTrace = "dead-trace"               ## shot 1, channel 5: all zero, marked live
    pdSpike = "spike"                        ## shot 0, channel 15, sample 300: 100.0
    pdMissingTraces = "missing-traces"       ## shot 2: channels 20 .. 24 not written
    pdDuplicateStation = "duplicate-station" ## shot 0: channel 12 written twice
    pdSwappedReceivers = "swapped-receivers"
      ## shot 0: the data of channels 6 and 10 swapped (their headers are right)
    pdZeroCoordinates = "zero-coordinates"
      ## shot 1: source X and Y written as 0 (parseSEG reads (0, 0) back as NaN)

  Fixtures* = object
    ## A temporary folder of fixture files. `remove` deletes it.
    dir*: string

  SpsPaths* = tuple[s, r, x: string]

proc newFixtures*(): Fixtures =
  ## A new, empty temporary folder.
  Fixtures(dir: createTempDir("viewseg-fixtures-", ""))

proc remove*(fx: Fixtures) =
  ## Deletes the folder and everything written into it.
  removeDir(fx.dir)

template withFixtures*(fx, body: untyped) =
  ## Runs `body` with `fx` a new `Fixtures`, removed afterwards.
  let fx = newFixtures()
  try:
    body
  finally:
    fx.remove()

# ------------------------------------------------------------- geometry --

func srcX*(shot: int): float64 =
  ## Easting of shot `shot` (0-based): between receivers, inside the spread.
  OriginX + GroupM * float64(4 + 8 * shot) + GroupM / 2

func rcvX*(channel: int): float64 =
  ## Easting of the receiver of `channel` (1-based) on line 100.
  OriginX + GroupM * float64(channel - 1)

func sample*(offset, t: float64): float32 =
  ## The value at time `t` (s) of a trace whose receiver is `offset` metres
  ## from the source.
  var v = 0.0
  let d = t - (DirectS + abs(offset) / VelocityMps)
  if d >= 0 and d < 2 / WaveHz:
    v += sin(2 * PI * WaveHz * d)
  let f = t - FlatS
  if f >= 0 and f < 1 / WaveHz:
    v -= 0.5 * sin(2 * PI * WaveHz * f)
  float32(v)

func surveySample*(shot, channel, i: int): float32 =
  ## Sample `i` of the clean survey's trace for `shot` (0-based) and
  ## `channel` (1-based).
  sample(rcvX(channel) - srcX(shot), float64(i) * DtMs / 1000)

func surveyTraces*(planted: PlantedDefect): int =
  ## The number of traces in `surveySegy(planted)`.
  case planted
  of pdMissingTraces: SurveyTraces - 5
  of pdDuplicateStation: SurveyTraces + 1
  else: SurveyTraces

func pilotSample*(i: int): float32 =
  ## Sample `i` of the pilot sweep: unit amplitude, frequency rising linearly.
  let t = float64(i) * DtMs / 1000
  let span = float64(PilotSamples - 1) * DtMs / 1000
  float32(sin(2 * PI * (PilotHz[0] * t + (PilotHz[1] - PilotHz[0]) / (2 * span) * t * t)))

# ---------------------------------------------------------------- SEG-Y --

proc checkClose(w: var SeismicWriter) =
  let log = w.close()
  doAssert log.len == 0, $log

proc surveySegy*(fx: Fixtures; planted = pdNone): string =
  ## The survey (see the module documentation), with `planted` in it.
  result = fx.dir / ("survey-" & $planted & ".sgy")
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
    text: @["C01 viewSEG test fixture: " & $Shots & " shots of " & $Channels & " channels",
      "C02 plane wave at " & $VelocityMps & " m/s and a flat event at " & $FlatS & " s",
      "C03 planted defect: " & $planted]))
  var buf = newSeq[float32](Samples)
  for shot in 0 ..< Shots:
    for channel in 1 .. Channels:
      if planted == pdMissingTraces and shot == 2 and channel >= 20:
        continue
      var k = initTraceKeys()
      k.record = float64(FirstRecord + shot)
      k.channel = float64(channel)
      k.srcPoint = FirstSrcPoint + float64(shot)
      (k.srcX, k.srcY, k.srcZ) = (srcX(shot), OriginY, Elevation)
      (k.rcvX, k.rcvY, k.rcvZ) = (rcvX(channel), OriginY, Elevation)
      k.offset = abs(rcvX(channel) - srcX(shot))
      (k.t0Ms, k.intervalUs, k.status) = (0.0, DtMs * 1000, tsLive)
      if planted == pdZeroCoordinates and shot == 1:
        (k.srcX, k.srcY) = (0.0, 0.0)
      var data = channel
      if planted == pdSwappedReceivers and shot == 0:
        if channel == 6: data = 10
        elif channel == 10: data = 6
      for i in 0 ..< Samples:
        buf[i] = surveySample(shot, data, i)
      if planted == pdDeadTrace and shot == 1 and channel == 5:
        buf.fill(0)
      if planted == pdSpike and shot == 0 and channel == 15:
        buf[300] = 100
      w.writeTrace(k, buf)
      if planted == pdDuplicateStation and shot == 0 and channel == 12:
        w.writeTrace(k, buf)
  w.checkClose()

proc pilotSegy*(fx: Fixtures): string =
  ## One sweep trace (`pilotSample`), trace identification code 6 (sweep).
  result = fx.dir / "pilot.sgy"
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(text: @["C01 viewSEG test pilot"]))
  var k = initTraceKeys()
  (k.record, k.channel, k.t0Ms, k.intervalUs) = (1.0, 1.0, 0.0, DtMs * 1000)
  # The writer keeps a trace code only when the status agrees with it.
  (k.traceCode, k.status) = (6'i16, tsAuxiliary)
  var buf = newSeq[float32](PilotSamples)
  for i in 0 ..< PilotSamples:
    buf[i] = pilotSample(i)
  w.writeTrace(k, buf)
  w.checkClose()

# ------------------------------------------------------------------ SPS --

proc surveySps*(fx: Fixtures): SpsPaths =
  ## The survey's source (S), receiver (R) and relation (X) files, SPS 2.1.
  result = (fx.dir / "survey.s", fx.dir / "survey.r", fx.dir / "survey.x")
  if fileExists(result.x): return
  let header = SpsHeader(code: "00", description: "SPS format version num.",
    data: "SPS 2.1;")
  proc point(kind: SpsPointKind; line, pt, x: float64): SpsPoint =
    SpsPoint(kind: kind, line: line, point: pt, index: 1, code: "G1", easting: x,
      northing: OriginY, elevation: Elevation, dayOfYear: -1, hour: -1, minute: -1,
      second: -1)
  var s, r, x = SpsFile(headers: @[header])
  for shot in 0 ..< Shots:
    s.points.add point(pkSource, SrcLine, FirstSrcPoint + float64(shot), srcX(shot))
    x.relations.add SpsRelation(fieldRecord: FirstRecord + shot, recordIncrement: 1,
      instrumentCode: '1', srcLine: SrcLine, srcPoint: FirstSrcPoint + float64(shot),
      srcIndex: 1, fromChannel: 1, toChannel: Channels, channelIncrement: 1,
      rcvLine: RcvLine, fromReceiver: FirstRcvPoint,
      toReceiver: FirstRcvPoint + float64(Channels - 1), rcvIndex: 1)
  for channel in 1 .. Channels:
    r.points.add point(pkReceiver, RcvLine, FirstRcvPoint + float64(channel - 1),
      rcvX(channel))
  for (f, path) in [(s, result.s), (r, result.r), (x, result.x)]:
    let log = writeSps(f, path)
    doAssert log.len == 0, $log

# ---------------------------------------------------------------- SEG-D --

type SetSpec = object
  ## One channel set of a SEG-D fixture record.
  channelType: uint8 ## 0x10 seismic, 0x20 time break, 0x98 pilot
  line: float64      ## receiver line (seismic)
  y: float64         ## its northing
  group: uint8       ## component (group index); 0 for none
  scale: float64     ## of the plane wave (seismic)

const SegdSourceX* = OriginX + GroupM * 5.5
  ## Easting of the SEG-D records' source (line 1, point 1001): mid-spread,
  ## at the northing of receiver line 100

proc blk(t: uint8; text = ""): seq[byte] =
  ## A raw 32-byte Rev 3 block of type `t`, `text` in bytes 1-31.
  result = newSeq[byte](32)
  for i, c in text: result[i] = byte(c)
  result[31] = t

proc position(x, y, z: float64): SegdPositionBlock =
  SegdPositionBlock(timeOfPosition: 1_478_000_000_000_000, tuple1Coord1: x,
    tuple1Coord2: y, tuple1Coord3: z, stanzaId1: 1, position1Valid: 1, position1Quality: 1,
    tuple2Coord1: Inf, tuple2Coord2: Inf, tuple2Coord3: Inf, blockType1: 0x50,
    blockType2: 0x51, blockType3: 0x52)

func segdSample*(scale, line, channel: float64; i: int): float32 =
  ## Sample `i` of a SEG-D fixture's seismic trace: the plane wave times
  ## `scale`, for the receiver of `channel` (1-based) on receiver `line`
  ## (100 at the source's northing, 101 at 50 m north).
  let dx = OriginX + GroupM * (channel - 1) - SegdSourceX
  let dy = (line - RcvLine) * 50
  float32(scale * float64(sample(sqrt(dx * dx + dy * dy), float64(i) * DtMs / 1000)))

proc writeSegdRecord(path: string; sets: openArray[SetSpec]) =
  ## One Rev 3.0 record (file number `SegdRecordNo`, format 8058) with the
  ## channel sets `sets`: an auxiliary set holds one trace, a seismic set
  ## `SegdChannels`. The source is line 1, point 1001, at mid-spread.
  let fmt = sd8058
  var r = SegdRecord(layout: slRev3, format: some(fmt),
    revision: SegdRevision(major: 3, minor: 0))
  r.generalBlocks.add blk(0x11, "viewSEG test record")
  let src = SegdSourceDescription(extFileNumber: SegdRecordNo, sourceLineNumber: 1,
    sourcePointNumber: 1001, sourcePointIndex: 1, sourceSetNumber: 1, blockType: 0x16)
  r.generalBlocks.add @(src.encoded)
  r.generalBlocks.add @(position(SegdSourceX, OriginY, Elevation).encoded)
  let nOpt = r.generalBlocks.len div 32
  r.gh1 = SegdGeneralHeader1(fileNumber: SegdRecordNo, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: uint8(2 + nOpt), julianDay: 313, hour: 9, minute: 41, second: 7,
    manufacturerCode: 20, baseScanInterval16: 32, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: sets.len, skewBlocks: 0,
    extendedHeaderBlocks: 0, externalHeaderBlocks: 0)
  let endUs = int32(DtMs * 1000 * float64(SegdSamples - 1))
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: SegdRecordNo, revisionMajor: 3,
    extRecordLength: uint32(endUs), blockType: 2)
  r.gh3 = SegdGeneralHeader3(timeZero: 1_478_000_000_000_000, blockType: 3)
  var descs: seq[SegdChannelSetDescriptorRev3]
  for n, s in sets:
    let seismic = s.channelType == 0x10
    descs.add SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: uint16(n + 1),
      channelType: s.channelType, endTime: endUs, numSamples: SegdSamples,
      descaleMultiplier: 1.0, channelsInSet: uint32(if seismic: SegdChannels else: 1),
      samplingInterval: uint32(DtMs * 1000), traceHeaderExtensions: (if seismic: 4 else: 1),
      verticalStack: 1, blockType1: 0x30, blockType2: 0x31, blockType3: 0x32)
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: descs)]
  var traces: seq[SegdTrace]
  for n, s in sets:
    let seismic = s.channelType == 0x10
    for tn in 1 .. (if seismic: SegdChannels else: 1):
      var t = SegdTrace(layout: slRev3, index: traces.len, numSamples: SegdSamples)
      t.header = SegdTraceHeader(fileNumber: SegdRecordNo, scanTypeNumber: 1,
        channelSetNumber: n + 1, traceNumber: tn,
        traceHeaderExtensions: (if seismic: 4'u8 else: 1'u8))
      t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(
        receiverLineNumber: (if seismic: int32(s.line) else: 0),
        receiverPointNumber: (if seismic: int32(FirstRcvPoint) + int32(tn - 1) else: 0),
        receiverPointIndex: 1, groupIndex: s.group, numSamples: SegdSamples,
        sensorType: (if seismic: 2'u8 else: 0'u8), blockType: 0x40)
      var v = newSeq[float32](SegdSamples)
      if seismic:
        t.extensions = @(position(OriginX + GroupM * float64(tn - 1), s.y, Elevation).encoded)
        for i in 0 ..< SegdSamples:
          v[i] = segdSample(s.scale, s.line, float64(tn), i)
      elif s.channelType == 0x20:
        v[0] = 1 # the time break at time zero
      else:
        for i in 0 ..< SegdSamples: v[i] = pilotSample(i)
      t.samples = newSeq[byte](dataBytes(fmt, SegdSamples))
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

proc twoSetSegd*(fx: Fixtures): string =
  ## A record with a time break (set 1), a pilot (set 2) and two seismic
  ## channel sets: receiver line 100 (set 3) and line 101, 50 m north (set 4),
  ## points 101 .. 112 on each.
  result = fx.dir / "two-sets.sgd"
  if not fileExists(result):
    writeSegdRecord(result, [SetSpec(channelType: 0x20), SetSpec(channelType: 0x98),
      SetSpec(channelType: 0x10, line: RcvLine, y: OriginY, scale: 1),
      SetSpec(channelType: 0x10, line: RcvLine + 1, y: OriginY + 50, scale: 1)])

proc threeComponentSegd*(fx: Fixtures): string =
  ## A record with a time break (set 1) and the three components of receiver
  ## line 100, points 101 .. 112 (sets 2, 3, 4: group index 1, 2, 3, the plane
  ## wave times `ComponentScale`).
  result = fx.dir / "three-component.sgd"
  if not fileExists(result):
    var sets = @[SetSpec(channelType: 0x20)]
    for c in 0 ..< 3:
      sets.add SetSpec(channelType: 0x10, line: RcvLine, y: OriginY, group: uint8(c + 1),
        scale: ComponentScale[c])
    writeSegdRecord(result, sets)

# ------------------------------------------------------------------ demo --

proc demoFile*(fx: Fixtures; name: string): string =
  ## One of parseSEG's demo files (`demoFileNames`); all of them are written
  ## on first use.
  if name notin demoFileNames:
    raise newException(ValueError, name & " is not a parseSEG demo file: " &
      demoFileNames.join(", "))
  result = fx.dir / "demo" / name
  if not fileExists(result):
    writeDemoFiles(fx.dir / "demo")
