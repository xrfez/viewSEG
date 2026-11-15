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
## - `plantedSps()`: the same S, R and X files with planted problems:
##   stations given twice (once at other coordinates), at (0, 0) and without
##   coordinates (`PlantedSps` says which).
## - `surveyP1()`: a SEG P1 file of `P1Shots` shotpoints on line `P1Line`,
##   one shot again (a reshoot) and one at (0, 0).
## - `hostileSurvey(h)`: survey files that are damaged or not survey files
##   at all (`HostileSurvey`).
## - `twoSetSegd()`: SEG-D Rev 3.0, format 8058, one record: a time break, a
##   pilot, and two seismic channel sets (receiver lines 100 and 101).
## - `recordOnlySegd()`: SEG-D Rev 3.0, one record whose headers give the
##   record and channel numbers only (no station, no position), and
##   `segdRelation()`, the X file that places its channels.
## - `areasSegd()`: `twoSetSegd()`'s record with an extended header and an
##   external header (`SegdExtendedText`, `SegdExternalText`).
## - `threeComponentSegd()`: SEG-D Rev 3.0, one record: a time break and three
##   seismic channel sets, one per component (group index 1, 2, 3) at the same
##   stations.
## - `mixedOrderSegd()`: SEG-D Rev 3.0, one record: a time break and the three
##   components of receiver lines 100 and 101, a channel set each, in a
##   scrambled order (`MixedSets`), for sorting.
## - `pilotSegy()`: SEG-Y, one sweep trace (trace code 6, auxiliary).
## - `spectrumSegy()`: SEG-Y, one record of `SpectrumTraces` traces of
##   `SpectrumSamples` samples at `DtMs`: channels 1 to 8 a sine of
##   `SpectrumSineHz` (on a bin of the whole trace's spectrum) and white
##   noise (`spectrumSample`), channel 9 a loud `SpectrumLoudHz` sine.
## - `longSpreadSegy()`: SEG-Y, one shot record of `LongSpread` channels of
##   `LongSamples` samples (a 25 Hz sine), more traces than a plot has room
##   for as wiggles.
## - `oneTraceSegy()`: SEG-Y, one record of a single trace of `LongSamples`
##   samples (the same sine), whose lobes swing as far as the overlap lets
##   them on both sides.
## - `longTraceSegy(samples)`: SEG-Y, one trace of `samples` samples at 1 ms
##   (`longSample`).
## - `longRecordSegy()`: SEG-Y, one shot record of `Channels` traces of
##   `LongRecordSamples` samples (6 s at `DtMs`), whose times run from one to
##   four digits.
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

import std/[algorithm, math, options, os, sequtils, strutils, tempfiles]
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
  MixedSets*: array[6, (float64, int)] = [(RcvLine + 1, 2), (RcvLine, 3), (RcvLine, 1),
    (RcvLine + 1, 1), (RcvLine, 2), (RcvLine + 1, 3)]
    ## the mixed-order record's seismic channel sets, in the file's order:
    ## (receiver line, component)
  PilotSamples* = 1001 ## the pilot: 2 s at `DtMs`, 8 to 80 Hz
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

  HostileSurvey* = enum
    ## A damaged survey file, or one that only looks like one by its name.
    hsTruncated = "truncated"      ## an R file cut short in its last record's coordinates
    hsHugeLine = "huge-line"       ## an R file with a 6 MB line of `x` after its tenth record
    hsJunkTail = "junk-tail"
      ## an R file of `JunkTailReceivers` records (more than the 4 KiB a file is
      ## told by), then 24 MiB of random bytes
    hsBinary = "binary" ## 64 KiB of random bytes, named as an R file
    hsEmpty = "empty" ## no bytes, named as an S file
    hsHeadersOnly = "headers-only" ## SPS header records and nothing else, named as an R file
    hsNoLineEnds = "no-line-ends" ## an R file's records as 80-byte cards without line ends
    hsBinaryTail = "binary-tail"
      ## an R file of `JunkTailReceivers` records, then 24 MiB of control bytes
      ## (1 to 8) and no line end

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

const
  PatchyShort* = 2
    ## the shot of `patchySegy` short of traces: channels 20 to 24 left out
  PatchyDead* = [3, 9]
    ## the channels of its shot 1 marked dead

proc patchySegy*(fx: Fixtures): string =
  ## The survey with shot `PatchyShort` short of five traces (channels 20 to
  ## 24 left out) and shot 1's channels `PatchyDead` marked dead (their
  ## samples as recorded); its binary header declares `Channels` data
  ## traces per ensemble (bytes 3213-3214).
  result = fx.dir / "patchy.sgy"
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
    text: @["C01 viewSEG test fixture: a short record and dead traces"]))
  var buf = newSeq[float32](Samples)
  for shot in 0 ..< Shots:
    for channel in 1 .. Channels:
      if shot != PatchyShort or channel < 20:
        var k = initTraceKeys()
        (k.record, k.channel) = (float64(FirstRecord + shot), float64(channel))
        k.srcPoint = FirstSrcPoint + float64(shot)
        (k.t0Ms, k.intervalUs) = (0.0, DtMs * 1000)
        k.status = if shot == 1 and channel in PatchyDead: tsDead else: tsLive
        for i in 0 ..< Samples: buf[i] = surveySample(shot, channel, i)
        w.writeTrace(k, buf)
  w.checkClose()
  var f = open(result, fmReadWriteExisting)
  f.setFilePos(3212)
  # big-endian int16
  let declared = [uint8(Channels shr 8), uint8(Channels and 0xff)]
  doAssert f.writeBytes(declared, 0, 2) == 2
  f.close()

const
  LongSpread* = 400  ## channels of `longSpreadSegy`
  LongSamples* = 200 ## its samples per trace, at `DtMs`

proc deadAndNotANumberSegy*(fx: Fixtures): string =
  ## The survey's first shot at 1000 times its amplitude, with channel 5
  ## marked dead (its samples as they were), one NaN sample in channel 7 and
  ## one infinite sample in channel 11.
  result = fx.dir / "dead-and-nan.sgy"
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
    text: @["C01 viewSEG test: a dead trace, a NaN sample, an infinite sample"]))
  var buf = newSeq[float32](Samples)
  for channel in 1 .. Channels:
    var k = initTraceKeys()
    (k.record, k.channel, k.srcPoint) = (11.0, float64(channel), FirstSrcPoint)
    (k.rcvLine, k.rcvPoint) = (RcvLine, FirstRcvPoint + float64(channel - 1))
    (k.t0Ms, k.intervalUs, k.status) = (0.0, DtMs * 1000, tsLive)
    for i in 0 ..< Samples: buf[i] = 1000 * surveySample(0, channel, i)
    if channel == 5: k.status = tsDead
    if channel == 7: buf[100] = NaN
    if channel == 11: buf[200] = Inf
    w.writeTrace(k, buf)
  doAssert w.close().len == 0

const
  WideTraces* = 2000  ## channels of `wideShotSegy`
  WideSamples* = 2500 ## its samples per trace (5 s at `DtMs`)

proc wideShotSegy*(fx: Fixtures): string =
  ## One shot record of `WideTraces` traces of `WideSamples` samples, each a
  ## 25 Hz sine whose amplitude changes with the channel and with time: a
  ## whole view of it is read at a coarser resolution than a view zoomed in.
  result = fx.dir / "wide-shot.sgy"
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: one shot of " & $WideTraces & " channels"]))
  var buf = newSeq[float32](WideSamples)
  for channel in 1 .. WideTraces:
    for i in 0 ..< WideSamples:
      let t = float64(i) * DtMs / 1000
      buf[i] = float32(sin(2 * PI * WaveHz * t + float64(channel) / 7) *
        (1 + 0.5 * sin(float64(channel) / 50 + t)))
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(channel), 0.0,
      DtMs * 1000, tsLive)
    w.writeTrace(k, buf)
  w.checkClose()

proc longSpreadSegy*(fx: Fixtures): string =
  ## One shot record of `LongSpread` traces, channel 1 .. `LongSpread`, each
  ## a 25 Hz sine.
  result = fx.dir / "long-spread.sgy"
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: one shot of " & $LongSpread & " channels"]))
  var buf = newSeq[float32](LongSamples)
  for i in 0 ..< LongSamples:
    buf[i] = float32(sin(2 * PI * WaveHz * float64(i) * DtMs / 1000))
  for channel in 1 .. LongSpread:
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(channel), 0.0,
      DtMs * 1000, tsLive)
    w.writeTrace(k, buf)
  w.checkClose()

proc oneTraceSegy*(fx: Fixtures): string =
  ## One record of one trace, channel 1, a 25 Hz sine of `LongSamples`
  ## samples.
  result = fx.dir / "one-trace.sgy"
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: one trace"]))
  var buf = newSeq[float32](LongSamples)
  for i in 0 ..< LongSamples:
    buf[i] = float32(sin(2 * PI * WaveHz * float64(i) * DtMs / 1000))
  var k = initTraceKeys()
  (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, 1.0, 0.0, DtMs * 1000, tsLive)
  w.writeTrace(k, buf)
  w.checkClose()

const LongRecordSamples* = 3000 ## samples per trace of `longRecordSegy`: 6 s at `DtMs`

proc longRecordSegy*(fx: Fixtures): string =
  ## One shot record of `Channels` traces, channel 1 .. `Channels`, of
  ## `LongRecordSamples` samples: a 25 Hz sine fading over the record.
  result = fx.dir / "long-record.sgy"
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: one shot of " & $LongRecordSamples & " samples"]))
  var buf = newSeq[float32](LongRecordSamples)
  for i in 0 ..< LongRecordSamples:
    let t = float64(i) * DtMs / 1000
    buf[i] = float32(sin(2 * PI * WaveHz * t) * exp(-t / 3))
  for channel in 1 .. Channels:
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(channel), 0.0,
      DtMs * 1000, tsLive)
    w.writeTrace(k, buf)
  w.checkClose()

const
  ManyRecords* = 100_000 ## records of `manyRecordsSegy`
  ManySamples* = 8       ## its samples per trace

proc manyRecordsSegy*(fx: Fixtures): string =
  ## `ManyRecords` one-trace shot records of `ManySamples` samples: record k
  ## (from 0) has FFID 1001 + k and source point 5001 + k, and its sample i
  ## is k + i / 10. About 27 MB, written once per fixture folder.
  result = fx.dir / "many-records.sgy"
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: " & $ManyRecords & " one-trace records"]))
  var buf = newSeq[float32](ManySamples)
  for r in 0 ..< ManyRecords:
    var k = initTraceKeys()
    (k.record, k.channel, k.srcPoint, k.t0Ms, k.intervalUs, k.status) = (
      float64(1001 + r), 1.0, float64(5001 + r), 0.0, DtMs * 1000, tsLive)
    for i in 0 ..< ManySamples: buf[i] = float32(r) + float32(i) / 10
    w.writeTrace(k, buf)
  w.checkClose()

func longSample*(i: int): float32 =
  ## Sample `i` of `longTraceSegy`'s trace.
  float32(sin(float64(i) / 10))

proc longTraceSegy*(fx: Fixtures; samples: int; traces = 1): string =
  ## One record of `traces` traces (channel 1 ..) of `samples` samples at 1
  ## ms (`longSample`): traces whose Data table has as many rows.
  result = fx.dir / ("long-trace-" & $samples & (if traces > 1: "x" & $traces else: "") &
    ".sgy")
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: " & $traces & " traces of " & $samples & " samples"]))
  var buf = newSeq[float32](samples)
  for i in 0 ..< samples: buf[i] = longSample(i)
  for c in 1 .. traces:
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(c), 0.0, 1000.0,
      tsLive)
    w.writeTrace(k, buf)
  w.checkClose()

proc manyTracesSegy*(fx: Fixtures; traces: int; samples = 4): string =
  ## One record of `traces` traces of `samples` samples each (1 ms apart,
  ## 1, -1, 0.5, 0 over and over): a selection as large as a survey's, in a
  ## small file.
  result = fx.dir / ("many-traces-" & $traces & (if samples == 4: "" else: "x" & $samples) &
    ".sgy")
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: " & $traces & " short traces"]))
  var buf = newSeq[float32](samples)
  for i in 0 ..< samples: buf[i] = [1'f32, -1, 0.5, 0][i mod 4]
  for c in 1 .. traces:
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(c), 0.0, 1000.0,
      tsLive)
    w.writeTrace(k, buf)
  w.checkClose()

proc noIntervalSegy*(fx: Fixtures): string =
  ## One record of 4 traces of `LongSamples` samples (a 25 Hz sine at 2 ms)
  ## whose headers give no sample interval (0).
  result = fx.dir / "no-interval.sgy"
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: no sample interval"]))
  var buf = newSeq[float32](LongSamples)
  for i in 0 ..< LongSamples:
    buf[i] = float32(sin(2 * PI * WaveHz * float64(i) * DtMs / 1000))
  for channel in 1 .. 4:
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(channel), 0.0,
      DtMs * 1000, tsLive)
    w.writeTrace(k, buf)
  w.checkClose()
  # (the writer wants an interval): the binary header's (bytes 3217-3218,
  # and its extended one, 3273-3280) and each trace header's (bytes 117-118,
  # and its extension's, 145-152, when it has one) set to 0
  var bytes = readFile(result)
  let extended = ord(bytes[3504]) * 256 + ord(bytes[3505]) # textual headers after the binary
  let first = 3600 + 3200 * extended
  let traceBytes = (bytes.len - first) div 4
  for at in [3216, 3217]: bytes[at] = '\0'
  for at in 3272 .. 3279: bytes[at] = '\0'
  for t in 0 ..< 4:
    let start = first + t * traceBytes
    for at in [116, 117]: bytes[start + at] = '\0'
    if traceBytes - 4 * LongSamples >= 480:
      for at in 240 + 144 .. 240 + 151: bytes[start + at] = '\0'
  writeFile(result, bytes)

const
  SpectrumTraces* = 9       ## traces of `spectrumSegy`
  SpectrumSamples* = 2048   ## its samples per trace: the FFT's length, so bins are 1000 / 4096 Hz
  SpectrumSineBin* = 100    ## the sine's bin: 24.4140625 Hz
  SpectrumSineHz* = float64(SpectrumSineBin) * 1000 / (SpectrumSamples * DtMs)
  SpectrumNoise* = 0.3      ## the noise's amplitude (uniform in ± this)
  SpectrumLoudHz* = 100.0   ## channel 9's sine, 10 times as loud

func spectrumSample*(channel, i: int): float32 =
  ## Sample `i` of `spectrumSegy`'s channel `channel` (1 ..).
  let t = float64(i) * DtMs / 1000
  if channel == SpectrumTraces: return float32(10 * sin(2 * PI * SpectrumLoudHz * t))
  var x = uint32(channel * 1_000_003 + i * 7919) # an integer hash: noise without a state
  x = (x xor (x shr 16)) * 0x45d9f3b'u32
  x = (x xor (x shr 16)) * 0x45d9f3b'u32
  x = x xor (x shr 16)
  let noise = (float64(x) / float64(high(uint32)) * 2 - 1) * SpectrumNoise
  float32(sin(2 * PI * SpectrumSineHz * t) + noise)

proc spectrumSegy*(fx: Fixtures): string =
  ## One record of `SpectrumTraces` traces for spectra (`spectrumSample`).
  result = fx.dir / "spectrum.sgy"
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: a sine in noise, for spectra"]))
  var buf = newSeq[float32](SpectrumSamples)
  for c in 1 .. SpectrumTraces:
    for i in 0 ..< SpectrumSamples: buf[i] = spectrumSample(c, i)
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (5.0, float64(c), 0.0,
      DtMs * 1000, tsLive)
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

const PlantedSps* = (sourceAgain: FirstSrcPoint, sourceZero: FirstSrcPoint + 3,
    sourceMissing: FirstSrcPoint + 4, receiverAgain: FirstRcvPoint + 4,
    receiverMoved: FirstRcvPoint + 9, receiverZero: FirstRcvPoint + 24,
    receiverMissing: FirstRcvPoint + 25)
  ## The planted problems of `plantedSps`, stations of `SrcLine` and
  ## `RcvLine`: a station given twice at the same coordinates (`sourceAgain`,
  ## `receiverAgain`), one given again 1 m further east (`receiverMoved`: the
  ## second is kept), one at (0, 0) (`...Zero`) and one without coordinates
  ## (`...Missing`) of each. It has `Shots` sources and `Channels` receivers
  ## placed.

proc spsPoint(kind: SpsPointKind; line, pt, x, y: float64): SpsPoint =
  SpsPoint(kind: kind, line: line, point: pt, index: 1, code: "G1", easting: x, northing: y,
    elevation: Elevation, dayOfYear: -1, hour: -1, minute: -1, second: -1)

proc plantedSps*(fx: Fixtures): SpsPaths =
  ## The survey's S, R and X files (SPS 2.1) with the problems of
  ## `PlantedSps`.
  result = (fx.dir / "planted.s", fx.dir / "planted.r", fx.dir / "planted.x")
  if fileExists(result.x): return
  let header = SpsHeader(code: "00", description: "SPS format version num.",
    data: "SPS 2.1;")
  let p = PlantedSps
  var s, r, x = SpsFile(headers: @[header])
  for shot in 0 ..< Shots:
    s.points.add spsPoint(pkSource, SrcLine, FirstSrcPoint + float64(shot), srcX(shot), OriginY)
  s.points.add spsPoint(pkSource, SrcLine, p.sourceAgain, srcX(0), OriginY)
  s.points.add spsPoint(pkSource, SrcLine, p.sourceZero, 0, 0)
  s.points.add spsPoint(pkSource, SrcLine, p.sourceMissing, NaN, NaN)
  for channel in 1 .. Channels:
    r.points.add spsPoint(pkReceiver, RcvLine, FirstRcvPoint + float64(channel - 1),
      rcvX(channel), OriginY)
  r.points.add spsPoint(pkReceiver, RcvLine, p.receiverAgain, rcvX(5), OriginY)
  r.points.add spsPoint(pkReceiver, RcvLine, p.receiverMoved, rcvX(10) + 1, OriginY)
  r.points.add spsPoint(pkReceiver, RcvLine, p.receiverZero, 0, 0)
  r.points.add spsPoint(pkReceiver, RcvLine, p.receiverMissing, NaN, NaN)
  for shot in 0 ..< Shots:
    x.relations.add SpsRelation(fieldRecord: FirstRecord + shot, recordIncrement: 1,
      instrumentCode: '1', srcLine: SrcLine, srcPoint: FirstSrcPoint + float64(shot),
      srcIndex: 1, fromChannel: 1, toChannel: Channels, channelIncrement: 1,
      rcvLine: RcvLine, fromReceiver: FirstRcvPoint,
      toReceiver: FirstRcvPoint + float64(Channels - 1), rcvIndex: 1)
  for (f, path) in [(s, result.s), (r, result.r), (x, result.x)]:
    let log = writeSps(f, path)
    doAssert log.len == 0, $log

const
  MapRcvLines* = [100.0, 102.0, 104.0] ## `mapSps`'s receiver lines, west to east
  MapRcvSpacing* = 25.0                ## receiver spacing along a line (metres)
  MapRcvPoints* = 21                   ## receivers per line: points 101 .. 121
  MapLineGap* = 200.0                  ## between receiver lines, northward
  MapSrcLines* = [1.0, 3.0]            ## `mapSps`'s source lines, running north
  MapSrcSpacing* = 62.5                ## source spacing along a line
  MapSrcPoints* = 8
    ## sources per line: points 1001 .. 1008 (so north and south differ)

func mapRcv*(line, k: int): (float64, float64) =
  ## Where receiver `k` (0-based) of `mapSps`'s receiver line `line`
  ## (0-based) is: lines run east from `OriginX`, one `MapLineGap` north of
  ## the one before.
  (OriginX + MapRcvSpacing * float64(k), OriginY + MapLineGap * float64(line))

func mapSrc*(line, k: int): (float64, float64) =
  ## Where source `k` (0-based) of `mapSps`'s source line `line` (0-based)
  ## is: lines run north from 50 m south of the receivers, between their
  ## points 5 and 6 and 15 and 16.
  (OriginX + MapRcvSpacing * (4.5 + 10 * float64(line)),
    OriginY - 50 + MapSrcSpacing * float64(k))

proc mapSpsIn*(fx: Fixtures; name, gridUnits, factor: string): tuple[s, r: string] =
  ## `mapSps`'s S and R files with other grid units in their headers: H20
  ## `gridUnits` and H201 `factor` (metres a unit), each left out when "".
  result = (fx.dir / (name & ".s"), fx.dir / (name & ".r"))
  if fileExists(result.r): return
  var headers = @[SpsHeader(code: "00", description: "SPS format version num.",
    data: "SPS 2.1;")]
  if gridUnits.len > 0:
    headers.add SpsHeader(code: "20", description: "Description of grid units",
      data: gridUnits & ";")
  if factor.len > 0:
    headers.add SpsHeader(code: "201", description: "Factor to metres", data: factor & ";")
  var s, r = SpsFile(headers: headers)
  for i, line in MapRcvLines:
    for k in 0 ..< MapRcvPoints:
      let (x, y) = mapRcv(i, k)
      r.points.add spsPoint(pkReceiver, line, 101 + float64(k), x, y)
  for i, line in MapSrcLines:
    for k in 0 ..< MapSrcPoints:
      let (x, y) = mapSrc(i, k)
      s.points.add spsPoint(pkSource, line, 1001 + float64(k), x, y)
  for (f, path) in [(s, result.s), (r, result.r)]:
    let log = writeSps(f, path)
    doAssert log.len == 0, $log

proc mapSps*(fx: Fixtures): tuple[s, r: string] =
  ## An S and an R file (SPS 2.1, grid units metres) of a small 3D land
  ## spread: receiver lines running east, source lines running north across
  ## them (`mapRcv`, `mapSrc`), so a source is never on a receiver.
  fx.mapSpsIn("map", "Metres", "1.0")

const MapPlanned* = 10
  ## receivers per line `mapXps` plans for a shot: points 101 .. 110 for
  ## source line 1 (its sources stand between points 105 and 106), 111 .. 120
  ## for source line 3 (between 115 and 116), on all three receiver lines

func mapRecord*(line, k: int): int64 =
  ## The field record (FFID) of `mapSps`'s source `k` (0-based) of source
  ## line `line` (0-based): 1 .. 16.
  int64(1 + line * MapSrcPoints + k)

func mapPlannedFirst*(line: int): int =
  ## The first receiver (0-based along its line) `mapXps` plans for a
  ## source of source line `line` (0-based); `MapPlanned` from there.
  line * MapPlanned

const MapOddSpread* = (line: 1, k: 7)
  ## the source whose X record in `mapXps` lists its receivers one point
  ## further on than its template plans (points 112 .. 121)

proc mapXps*(fx: Fixtures): string =
  ## The X file of `mapSps`: one X record per source (`mapRecord`), its
  ## channels 1 .. 30 at receivers `mapPlannedFirst` .. + `MapPlanned` - 1 of
  ## lines 100, 102, 104 (but `MapOddSpread`'s, one further on).
  result = fx.dir / "map.x"
  if fileExists(result): return
  var x = SpsFile(headers: @[SpsHeader(code: "00", description: "SPS format version num.",
    data: "SPS 2.1;")])
  for i, sl in MapSrcLines:
    for k in 0 ..< MapSrcPoints:
      for j, rl in MapRcvLines:
        let odd = i == MapOddSpread.line and k == MapOddSpread.k
        let first = 101 + float64(mapPlannedFirst(i)) + (if odd: 1.0 else: 0.0)
        x.relations.add SpsRelation(fieldRecord: mapRecord(i, k), recordIncrement: 1,
          instrumentCode: '1', srcLine: sl, srcPoint: 1001 + float64(k), srcIndex: 1,
          fromChannel: int64(1 + j * MapPlanned), toChannel: int64((j + 1) * MapPlanned),
          channelIncrement: 1, rcvLine: rl, fromReceiver: first,
          toReceiver: first + float64(MapPlanned - 1), rcvIndex: 1)
  let log = writeSps(x, result)
  doAssert log.len == 0, $log

proc mapOps*(fx: Fixtures): string =
  ## The receiver-domain (O) records of `mapXps`, as parseSEG's
  ## `receiverRelations` makes them: one gather per receiver, its traces the
  ## sources whose X record lists it.
  result = fx.dir / "map.o"
  if fileExists(result): return
  var g = initSurveyGeometry()
  g.addSps(fx.mapXps)
  var o = SpsFile(headers: @[SpsHeader(code: "00", description: "SPS format version num.",
    data: "SPS 2.1;")], relations: g.receiverRelations())
  let log = writeSps(o, result)
  doAssert log.len == 0, $log

func mapWave(offset: float64; i: int): float32 =
  ## Sample `i` of a map fixture's trace `offset` metres from its source.
  sample(offset, float64(i) * DtMs / 1000)

proc mapTrace(w: var SeismicWriter; record: int64; channel: int; sl, sk, rl, rk: int;
    ensemble = 0.0; status = tsLive; scale = 1.0) =
  ## One trace of field record `record` from `mapSps`'s source `sk` of source
  ## line `sl` to receiver `rk` of receiver line `rl` (0-based), with
  ## coordinates (and stations, which SEG-Y does not keep) in its keys.
  var k = initTraceKeys()
  let (sx, sy) = mapSrc(sl, sk)
  let (rx, ry) = mapRcv(rl, rk)
  (k.record, k.channel, k.ensemble) = (float64(record), float64(channel), ensemble)
  (k.srcLine, k.srcPoint, k.srcIndex) = (MapSrcLines[sl], 1001 + float64(sk), 1'i16)
  (k.rcvLine, k.rcvPoint, k.rcvIndex) = (MapRcvLines[rl], 101 + float64(rk), 1'i16)
  (k.srcX, k.srcY, k.srcZ, k.rcvX, k.rcvY, k.rcvZ) = (sx, sy, Elevation, rx, ry, Elevation)
  k.offset = hypot(rx - sx, ry - sy)
  (k.t0Ms, k.intervalUs, k.status) = (0.0, DtMs * 1000, status)
  var buf = newSeq[float32](Samples)
  for i in 0 ..< Samples: buf[i] = float32(scale * float64(mapWave(k.offset, i)))
  w.writeTrace(k, buf)

const MapFfid* = 1000
  ## `mapShotSegy`'s FFIDs are their X records' numbers plus this: the X
  ## record is found by the source's station, as a recorder numbers its
  ## files its own way

proc mapShotSegy*(fx: Fixtures; line, k: int; name = ""): string =
  ## The shot record of `mapSps`'s source `k` of source line `line` (0-based;
  ## FFID `MapFfid + mapRecord`): a trace for each of its 63 receivers, line
  ## by line, with coordinates in the headers (SEG-Y keeps no stations
  ## without a header layout naming them).
  result = fx.dir / (if name.len > 0: name else: "shot-" & $mapRecord(line, k) & ".sgy")
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
    text: @["C01 viewSEG test fixture: a shot of the map's spread"]))
  for rl in 0 ..< MapRcvLines.len:
    for rk in 0 ..< MapRcvPoints:
      w.mapTrace(MapFfid + mapRecord(line, k), rl * MapRcvPoints + rk + 1, line, k, rl, rk)
  w.checkClose()

proc mapReceiverSegy*(fx: Fixtures; line, k: int): string =
  ## The receiver gather of `mapSps`'s receiver `k` of receiver line `line`
  ## (0-based): a trace from each of its 16 sources, the SEG-Y binary header
  ## saying common-receiver gathers.
  result = fx.dir / ("receiver-" & $(101 + k) & "-" & $int(MapRcvLines[line]) & ".sgy")
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 6, measurementSystem: 1,
    text: @["C01 viewSEG test fixture: a receiver gather of the map's spread"]))
  var n = 0
  for sl in 0 ..< MapSrcLines.len:
    for sk in 0 ..< MapSrcPoints:
      inc n
      w.mapTrace(mapRecord(sl, sk), n, sl, sk, line, k, ensemble = 1)
  w.checkClose()

proc bigSps*(fx: Fixtures; lines, points: int; spacing = 5.0; gap = 50.0): string =
  ## An R file of `lines` × `points` receivers (lines `gap` apart running
  ## east, `spacing` apart along them, each line wavering north and south a
  ## little), written as 80-column cards directly: a million in a second or
  ## two.
  result = fx.dir / ("big-" & $lines & "x" & $points & ".r")
  if fileExists(result): return
  var f = open(result, fmWrite)
  defer: f.close()
  f.writeLine alignLeft("H00 SPS format version num.     SPS 2.1;", 80)
  f.writeLine alignLeft("H20 Description of grid units   Metres;", 80)
  var card = newString(80)
  for j in 0 ..< lines:
    for k in 0 ..< points:
      let x = OriginX + spacing * float64(k)
      let y = OriginY + gap * float64(j) + 3 * sin(float64(k) / 40)
      # R, line (2-11), point (12-21), index (24), code (25-26), easting
      # (47-55), northing (56-65), elevation (66-71): SPS 2.1's columns
      card = "R" & align($(1000 + j), 10) & align($(1 + k), 10) & "  1G1" & spaces(20) &
        align(formatFloat(x, ffDecimal, 1), 9) & align(formatFloat(y, ffDecimal, 1), 10) &
        align("100.0", 6) & spaces(9)
      f.writeLine card

const
  P1Line* = 7.0          ## the shot line of `surveyP1`
  P1Shots* = 5           ## its shotpoints 1 .. P1Shots
  P1OriginX* = 600_000.0 ## easting of shotpoint 1 (metres); each next one 50 m east
  P1Y* = 6_100_000.0     ## northing of every shotpoint but the reshoot
  P1Reshot* = 3.0        ## shotpoint 3 is shot again (reshoot `A`, point index 2) 10 m north
  P1Zero* = 9.0          ## shotpoint 9 is at (0, 0)

func p1X*(point: float64): float64 =
  ## Easting of shotpoint `point` of `surveyP1`.
  P1OriginX + 50 * (point - 1)

proc surveyP1*(fx: Fixtures): string =
  ## A SEG P1 file (whole metres): shotpoints 1 .. `P1Shots` of line `P1Line`,
  ## then the reshoot of `P1Reshot` and shotpoint `P1Zero` at (0, 0).
  result = fx.dir / "survey.p1"
  if fileExists(result): return
  proc shot(point: float64; reshoot: char; x, y: float64): P1Record =
    result = initP1Record()
    (result.lineName, result.pointName, result.point, result.reshoot) = ($int(P1Line),
      $int(point), point, reshoot)
    (result.latitude, result.longitude) = (55.0 + point / 1000, -2.0)
    (result.easting, result.northing, result.depthOrElevation) = (x, y, 12.0)
  var lf = PLogicalFile(format: pfP1, header: @["H SEG P1 viewSEG test fixture: line " &
    $int(P1Line), " PROJECTION UTM 30N, GRID UNITS METRES"])
  for point in 1 .. P1Shots:
    lf.records.add shot(float64(point), ' ', p1X(float64(point)), P1Y)
  lf.records.add shot(P1Reshot, 'A', p1X(P1Reshot), P1Y + 10)
  lf.records.add shot(P1Zero, ' ', 0, 0)
  let log = writeP1(P1File(files: @[lf]), result)
  doAssert log.len == 0, $log

const JunkTailReceivers* = 5 * Channels
  ## the receivers of `hostileSurvey(hsJunkTail)`: lines 100 .. 104, points
  ## as the survey's

proc hostileSurvey*(fx: Fixtures; h: HostileSurvey): string =
  ## A survey file damaged as `h` says (written on first use).
  const names: array[HostileSurvey, string] = ["truncated.rps", "huge-line.rps",
    "junk-tail.rps", "binary.rps", "empty.sps", "headers-only.rps", "no-line-ends.rps",
    "binary-tail.rps"]
  result = fx.dir / "hostile" / names[h]
  if fileExists(result): return
  createDir(fx.dir / "hostile")
  let header = SpsHeader(code: "00", description: "SPS format version num.",
    data: "SPS 2.1;")
  var r = SpsFile(headers: @[header])
  for channel in 1 .. Channels:
    r.points.add spsPoint(pkReceiver, RcvLine, FirstRcvPoint + float64(channel - 1),
      rcvX(channel), OriginY)
  var cards: seq[string]
  for line in spsText(r).text.splitLines:
    if line.len > 0: cards.add line
  var random = 12345'u32
  proc junk(n: int): string =
    result = newString(n)
    for c in result.mitems:
      random = random * 1664525'u32 + 1013904223'u32
      c = char(random shr 24)
  var text = ""
  case h
  of hsTruncated: text = cards.join("\n")[0 ..< ^40] # in the last record's coordinates
  of hsHugeLine:
    text = cards[0 .. 10].join("\n") & "\n" & 'x'.repeat(6_000_000) & "\n" &
      cards[11 .. ^1].join("\n") & "\n"
  of hsJunkTail:
    var more = SpsFile(headers: @[header])
    for line in 0 ..< JunkTailReceivers div Channels:
      for channel in 1 .. Channels:
        more.points.add spsPoint(pkReceiver, RcvLine + float64(line), FirstRcvPoint +
          float64(channel - 1), rcvX(channel), OriginY + 50 * float64(line))
    text = spsText(more).text & junk(24 * 1024 * 1024)
  of hsBinary: text = junk(65_536)
  of hsEmpty: text = ""
  of hsHeadersOnly:
    for i in 0 ..< 80: text.add alignLeft("H" & align($i, 2, '0') & " Header record " & $i,
      80) & "\n"
  of hsNoLineEnds:
    for c in cards: text.add alignLeft(c, 80)
  of hsBinaryTail:
    var more = SpsFile(headers: @[header])
    for line in 0 ..< JunkTailReceivers div Channels:
      for channel in 1 .. Channels:
        more.points.add spsPoint(pkReceiver, RcvLine + float64(line), FirstRcvPoint +
          float64(channel - 1), rcvX(channel), OriginY + 50 * float64(line))
    text = spsText(more).text
    let start = text.len
    text.setLen start + 24 * 1024 * 1024
    for i in start ..< text.len: text[i] = char(1 + (i mod 8))
  writeFile(result, text)

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

const
  SegdExtendedText* = "viewSEG test: extended header"
    ## the start of `areasSegd`'s extended header
  SegdExternalText* = "viewSEG test: external header, shot 1001"
    ## the start of its external header

proc areaBytes(text: string; blocks: int): seq[byte] =
  ## `blocks` 32-byte blocks holding `text`, then spaces.
  result = newSeq[byte](32 * blocks)
  for i in 0 ..< result.len: result[i] = (if i < text.len: byte(text[i]) else: 0x20'u8)

proc writeSegdRecord(path: string; sets: openArray[SetSpec]; placed = true; stations = true;
    positioned = true; areas = false) =
  ## One Rev 3.0 record (file number `SegdRecordNo`, format 8058) with the
  ## channel sets `sets`: an auxiliary set holds one trace, a seismic set
  ## `SegdChannels`. The source is line 1, point 1001, at mid-spread; not
  ## `placed`, every position block holds (0, 0) (stations only, as field
  ## records often have). Without `stations`, the source and receiver
  ## stations are 0 / 0 (none: record and channel numbers only); not
  ## `positioned`, the record has no position blocks at all.
  ## With `areas`, an extended header of one block (`SegdExtendedText`) and
  ## an external header of two (`SegdExternalText`).
  let fmt = sd8058
  var r = SegdRecord(layout: slRev3, format: some(fmt),
    revision: SegdRevision(major: 3, minor: 0))
  r.generalBlocks.add blk(0x11, "viewSEG test record")
  let src = SegdSourceDescription(extFileNumber: SegdRecordNo,
    sourceLineNumber: (if stations: 1 else: 0), sourcePointNumber: (if stations: 1001 else: 0),
    sourcePointIndex: 1, sourceSetNumber: 1, blockType: 0x16)
  r.generalBlocks.add @(src.encoded)
  if positioned:
    r.generalBlocks.add @(if placed: position(SegdSourceX, OriginY, Elevation).encoded
      else: position(0, 0, 0).encoded)
  let nOpt = r.generalBlocks.len div 32
  r.gh1 = SegdGeneralHeader1(fileNumber: SegdRecordNo, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: uint8(2 + nOpt), julianDay: 313, hour: 9, minute: 41, second: 7,
    manufacturerCode: 20, baseScanInterval16: 32, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: (if sets.len > 99: BcdAllF else: sets.len),
    skewBlocks: 0, extendedHeaderBlocks: (if areas: 1 else: 0),
    externalHeaderBlocks: (if areas: 2 else: 0))
  if areas:
    r.extended = areaBytes(SegdExtendedText, 1)
    r.external = areaBytes(SegdExternalText, 2)
  let endUs = int32(DtMs * 1000 * float64(SegdSamples - 1))
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: SegdRecordNo, revisionMajor: 3,
    extRecordLength: uint32(endUs), blockType: 2,
    extChannelSetsPerScanType: (if sets.len > 99: uint16(sets.len) else: 0))
  r.gh3 = SegdGeneralHeader3(timeZero: 1_478_000_000_000_000, blockType: 3)
  var descs: seq[SegdChannelSetDescriptorRev3]
  for n, s in sets:
    let seismic = s.channelType == 0x10
    descs.add SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: uint16(n + 1),
      channelType: s.channelType, endTime: endUs, numSamples: SegdSamples,
      descaleMultiplier: 1.0, channelsInSet: uint32(if seismic: SegdChannels else: 1),
      samplingInterval: uint32(DtMs * 1000),
      traceHeaderExtensions: (if seismic and positioned: 4 else: 1),
      verticalStack: 1, blockType1: 0x30, blockType2: 0x31, blockType3: 0x32)
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: descs)]
  var traces: seq[SegdTrace]
  for n, s in sets:
    let seismic = s.channelType == 0x10
    for tn in 1 .. (if seismic: SegdChannels else: 1):
      var t = SegdTrace(layout: slRev3, index: traces.len, numSamples: SegdSamples)
      t.header = SegdTraceHeader(fileNumber: SegdRecordNo, scanTypeNumber: 1,
        channelSetNumber: (if n + 1 > 99: BcdAllF else: n + 1),
        extChannelSetNumber: (if n + 1 > 99: uint16(n + 1) else: 0), traceNumber: tn,
        traceHeaderExtensions: (if seismic and positioned: 4'u8 else: 1'u8))
      let named = seismic and stations
      t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(
        receiverLineNumber: (if named: int32(s.line) else: 0),
        receiverPointNumber: (if named: int32(FirstRcvPoint) + int32(tn - 1) else: 0),
        receiverPointIndex: 1, groupIndex: s.group, numSamples: SegdSamples,
        sensorType: (if seismic: 2'u8 else: 0'u8), blockType: 0x40)
      var v = newSeq[float32](SegdSamples)
      if seismic:
        if positioned:
          t.extensions = @(if placed: position(OriginX + GroupM * float64(tn - 1), s.y,
            Elevation).encoded else: position(0, 0, 0).encoded)
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

type MapDefect* = enum
  ## A problem planted in `mapShotSegd`'s record, at the receiver
  ## `MapDefectAt` names.
  mdDead = "dead" ## its trace marked dead (trace edit 2), its samples as recorded
  mdClipped = "clipped" ## its samples cut at a third of its largest: long runs at the maximum
  mdNoisy = "noisy" ## its samples 100 times larger
  mdMissing = "missing" ## not recorded: no trace of it
  mdDuplicate = "duplicate" ## recorded twice (one more trace at the end of its line's set)
  mdUnplaced = "unplaced"
    ## its trace at (0, 0) and named receiver point `MapUnplacedPoint`, which
    ## no survey file has: the map cannot place it

const
  MapDefectAt*: array[MapDefect, tuple[line, k: int]] = [(1, 2), (0, 4), (2, 6), (1, 5),
    (0, 8), (2, 1)]
    ## each planted problem's receiver: line (0-based) and receiver (0-based along it),
    ## all among the ten `mapXps` plans for source line 1 (`mapPlannedFirst(0)`)
  MapUnplacedPoint* = 199 ## the receiver point `mdUnplaced` names

proc mapShotSegd*(fx: Fixtures; line, k: int; defects: set[MapDefect] = {}; name = ""): string =
  ## The shot record of `mapSps`'s source `k` of source line `line` (0-based) as
  ## a SEG-D Rev 3.0 file (format 8058), its file number its X record's
  ## (`mapRecord`): a time break (trace 0), then a channel set per receiver
  ## line, a trace for each of its 21 receivers, with the stations and
  ## positions of source and receivers in the headers; with `defects`
  ## planted (`MapDefectAt`).
  result = fx.dir / (if name.len > 0: name else: "shot-" & $mapRecord(line, k) & ".sgd")
  if fileExists(result): return
  let fmt = sd8058
  let (sx, sy) = mapSrc(line, k)
  let record = int(mapRecord(line, k))
  var r = SegdRecord(layout: slRev3, format: some(fmt), revision: SegdRevision(major: 3, minor: 0))
  r.generalBlocks.add blk(0x11, "viewSEG map test record")
  let src = SegdSourceDescription(extFileNumber: uint32(record),
    sourceLineNumber: MapSrcLines[line], sourcePointNumber: float64(1001 + k),
    sourcePointIndex: 1, sourceSetNumber: 1, blockType: 0x16)
  r.generalBlocks.add @(src.encoded)
  r.generalBlocks.add @(position(sx, sy, Elevation).encoded)
  let nOpt = r.generalBlocks.len div 32
  # the receivers of each set: (k, a duplicate)
  var sets: seq[seq[int]]
  for rl in 0 ..< MapRcvLines.len:
    var ks: seq[int]
    for rk in 0 ..< MapRcvPoints:
      if not (mdMissing in defects and MapDefectAt[mdMissing] == (rl, rk)): ks.add rk
    if mdDuplicate in defects and MapDefectAt[mdDuplicate].line == rl:
      ks.add MapDefectAt[mdDuplicate].k
    sets.add ks
  r.gh1 = SegdGeneralHeader1(fileNumber: record, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: uint8(2 + nOpt), julianDay: 313, hour: 9, minute: 41, second: 7,
    manufacturerCode: 20, baseScanInterval16: 32, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 1 + sets.len, skewBlocks: 0,
    extendedHeaderBlocks: 0, externalHeaderBlocks: 0)
  let endUs = int32(DtMs * 1000 * float64(SegdSamples - 1))
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: uint32(record), revisionMajor: 3,
    extRecordLength: uint32(endUs), blockType: 2)
  r.gh3 = SegdGeneralHeader3(timeZero: 1_478_000_000_000_000, blockType: 3)
  var descs = @[SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1,
    channelType: 0x20, endTime: endUs, numSamples: SegdSamples, descaleMultiplier: 1.0,
    channelsInSet: 1, samplingInterval: uint32(DtMs * 1000), traceHeaderExtensions: 1,
    verticalStack: 1, blockType1: 0x30, blockType2: 0x31, blockType3: 0x32)]
  for n, ks in sets:
    descs.add SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: uint16(n + 2),
      channelType: 0x10, endTime: endUs, numSamples: SegdSamples, descaleMultiplier: 1.0,
      channelsInSet: uint32(ks.len), samplingInterval: uint32(DtMs * 1000),
      traceHeaderExtensions: 4, verticalStack: 1, blockType1: 0x30, blockType2: 0x31,
      blockType3: 0x32)
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: descs)]
  var traces: seq[SegdTrace]
  block: # the time break
    var t = SegdTrace(layout: slRev3, index: 0, numSamples: SegdSamples)
    t.header = SegdTraceHeader(fileNumber: record, scanTypeNumber: 1, channelSetNumber: 1,
      traceNumber: 1, traceHeaderExtensions: 1)
    t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(receiverPointIndex: 1, numSamples: SegdSamples,
      blockType: 0x40)
    var v = newSeq[float32](SegdSamples)
    v[0] = 1
    t.samples = newSeq[byte](dataBytes(fmt, SegdSamples))
    encodeSamples(fmt, v, t.samples)
    traces.add t
  for n, ks in sets:
    for tn, rk in ks:
      let rl = n
      let (rx, ry) = mapRcv(rl, rk)
      var t = SegdTrace(layout: slRev3, index: traces.len, numSamples: SegdSamples)
      let dead = mdDead in defects and MapDefectAt[mdDead] == (rl, rk)
      t.header = SegdTraceHeader(fileNumber: record, scanTypeNumber: 1,
        channelSetNumber: n + 2, traceNumber: tn + 1,
        traceHeaderExtensions: 4, traceEdit: (if dead: 2'u8 else: 0'u8))
      let unplaced = mdUnplaced in defects and MapDefectAt[mdUnplaced] == (rl, rk)
      t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(receiverLineNumber: int32(MapRcvLines[rl]),
        receiverPointNumber: int32(if unplaced: MapUnplacedPoint else: 101 + rk),
        receiverPointIndex: 1, numSamples: SegdSamples, sensorType: 2, blockType: 0x40)
      t.extensions = @((if unplaced: position(0, 0, 0) else: position(rx, ry,
        Elevation)).encoded)
      let offset = hypot(rx - sx, ry - sy)
      var v = newSeq[float32](SegdSamples)
      for i in 0 ..< SegdSamples: v[i] = mapWave(offset, i)
      if mdNoisy in defects and MapDefectAt[mdNoisy] == (rl, rk):
        for x in v.mitems: x *= 100
      if mdClipped in defects and MapDefectAt[mdClipped] == (rl, rk):
        var top = 0'f32
        for x in v: top = max(top, abs(x))
        for x in v.mitems: x = clamp(x, -top / 3, top / 3)
      t.samples = newSeq[byte](dataBytes(fmt, SegdSamples))
      encodeSamples(fmt, v, t.samples)
      traces.add t
  computeRev3Sizes(r, traces)
  r.traceCount = traces.len
  let sink = openDiskSink(result)
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

proc areasSegd*(fx: Fixtures): string =
  ## `twoSetSegd`'s record with an extended header (one block, starting
  ## with `SegdExtendedText`) and an external header (two blocks, starting
  ## with `SegdExternalText`).
  result = fx.dir / "areas.sgd"
  if not fileExists(result):
    writeSegdRecord(result, [SetSpec(channelType: 0x20), SetSpec(channelType: 0x98),
      SetSpec(channelType: 0x10, line: RcvLine, y: OriginY, scale: 1),
      SetSpec(channelType: 0x10, line: RcvLine + 1, y: OriginY + 50, scale: 1)], areas = true)

proc stationsSegd*(fx: Fixtures): string =
  ## A record whose headers name stations but give no coordinates (every
  ## position at (0, 0)): a time break (trace 0), then receiver line 100,
  ## points 101 .. 112 (traces 1 .. 12, the stations of `surveySps`'s R file)
  ## and line 101, points 101 .. 112 (traces 13 .. 24, in no survey file);
  ## the source line 1, point 1001 (`surveySps`'s first source).
  result = fx.dir / "stations-only.sgd"
  if not fileExists(result):
    writeSegdRecord(result, [SetSpec(channelType: 0x20),
      SetSpec(channelType: 0x10, line: RcvLine, y: OriginY, scale: 1),
      SetSpec(channelType: 0x10, line: RcvLine + 1, y: OriginY + 50, scale: 1)], placed = false)

proc manySetsSegd*(fx: Fixtures; sets: int): string =
  ## `writeSegdRecord`'s record with `sets` channel sets of one time-break
  ## trace each (more than 99: counted in General Header #2, as parseSEG
  ## reads up to 65 535 a scan type).
  result = fx.dir / ("sets" & $sets & ".sgd")
  if not fileExists(result):
    writeSegdRecord(result, newSeqWith(sets, SetSpec(channelType: 0x20)), stations = false,
      positioned = false)

proc recordOnlySegd*(fx: Fixtures): string =
  ## A record whose headers give neither stations nor coordinates (no
  ## position block), only the record (`SegdRecordNo`) and the channels: a
  ## time break (trace 0), then channels 1 .. `SegdChannels` (traces 1 ..
  ## 12), which `segdRelation`'s X record places at receiver line 100,
  ## points 101 .. 112, from source line 1, point 1001.
  result = fx.dir / "record-only.sgd"
  if not fileExists(result):
    writeSegdRecord(result, [SetSpec(channelType: 0x20),
      SetSpec(channelType: 0x10, line: RcvLine, y: OriginY, scale: 1)], stations = false,
      positioned = false)

proc segdRelation*(fx: Fixtures): string =
  ## An X file (SPS 2.1) with the one X record of the SEG-D records (field
  ## record `SegdRecordNo`): channels 1 .. `SegdChannels` from source line 1,
  ## point 1001 to receiver line 100, points 101 .. 112 (`surveySps`'s
  ## stations).
  result = fx.dir / "segd.x"
  if fileExists(result): return
  var x = SpsFile(headers: @[SpsHeader(code: "00", description: "SPS format version num.",
    data: "SPS 2.1;")])
  x.relations.add SpsRelation(fieldRecord: SegdRecordNo, recordIncrement: 1,
    instrumentCode: '1', srcLine: SrcLine, srcPoint: FirstSrcPoint, srcIndex: 1, fromChannel: 1,
    toChannel: SegdChannels, channelIncrement: 1, rcvLine: RcvLine, fromReceiver: FirstRcvPoint,
    toReceiver: FirstRcvPoint + float64(SegdChannels - 1), rcvIndex: 1)
  let log = writeSps(x, result)
  doAssert log.len == 0, $log

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

proc mixedOrderSegd*(fx: Fixtures): string =
  ## A record with a time break (set 1), then the three components of
  ## receiver lines 100 and 101 (50 m north), points 101 .. 112, one channel
  ## set each, in the scrambled order of `MixedSets`: so every way of sorting
  ## them gives another order, and a station's components come neither in
  ## order nor side by side in the file. Trace `1 + s * SegdChannels + n` is
  ## set `MixedSets[s]`'s point `FirstRcvPoint + n`.
  result = fx.dir / "mixed-order.sgd"
  if not fileExists(result):
    var sets = @[SetSpec(channelType: 0x20)]
    for (line, component) in MixedSets:
      sets.add SetSpec(channelType: 0x10, line: line, y: OriginY + 50 * (line - RcvLine),
        group: uint8(component), scale: ComponentScale[component - 1])
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
