## The like path writes survey-join and station-move positions into the output
## headers, and says so. The option off keeps the source headers and says the
## session's positions were not written. Nothing joined or moved stays the
## template writer, byte for byte, for SEG-Y and SEG-D. A value with no slot
## is counted in the result lines, and the sentence is what was stored, after
## the writer closed. The keys path (another format, or a dropped trace) honours
## the same tick: off writes the session's positions and says so; on writes the
## file's own header positions and says which source.
##
## Seen to fail: the like path copied the source headers, so a joined receiver
## stayed at 1 (`rcvX` 1, not the survey easting) and the result had no
## "traces changed" line. The keys path wrote the session's 500000 with the
## tick on and no line saying so. A Rev 2.1 file with no coordinate slot said
## "1 traces changed" while the bytes matched a write that stored nothing.
##
## A batch of files this job opens itself takes the project's survey join and
## station moves per file, as one open file written alone does: both files of
## a batch carry the joined and moved positions, equal to writing each alone;
## a file the survey does not cover keeps its own positions and the result
## line says so; nothing set keeps the old line.
##
## Seen to fail: with `BatchAsk.project` ignored, the batch files kept the
## header easting 1 (`a batch file kept the header easting 1`) and said the
## batch wrote the file's own positions.
##
## Synthetic files only, from the join fixtures' survey.

import std/[math, options, os, strutils, tempfiles]
import parseSEG
import parseSEG/model/traceindex
import viewSEG/core/[edits, filememory, jobs, join, outputbatch, outputjobs, sigtypes, stationmoves]
import utils/[fixtures, waiting]

func near(a, b: float64; tol = 0.05): bool =
  if a.isNaN or b.isNaN: a.isNaN and b.isNaN
  else: abs(a - b) <= tol

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc runWrite(file: var SeismicFile; source, dest: string; opts: OutputOptions;
    edits = FileEdits(); signature = SignatureFacts()):
    tuple[st: JobState; wrote: OutputResult; error: string] =
  let jobs = initJobs()
  let sink = OutputSink()
  let id = jobs.submit(outputSpec(source, dest),
    outputWork(addr file, source, dest, opts, edits, @[source], sink, signature))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the write did not finish: " & $jobs.state(id)
  let info = jobs.info(id).get
  (info.state, sink.result, info.error)

proc loadSurvey(paths: SpsPaths): SurveyGeometry =
  result = initSurveyGeometry()
  result.addSps(paths.s)
  result.addSps(paths.r)
  result.addSps(paths.x)

proc twoTimes(dir: string; name = "two-times.sgy"; first = FirstRecord): string =
  ## Two shots, two channels, header coordinates (1, 1), so a join replaces
  ## them. Times are stamped on the keys after open: the writer does not
  ## store `TraceKeys.time` in these headers.
  result = dir / name
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1))
  var buf = newSeq[float32](8)
  for i in 0 ..< buf.len: buf[i] = float32(i + 1)
  for shot in 0 .. 1:
    for channel in 1 .. 2:
      var k = initTraceKeys()
      k.record = float64(first + shot)
      k.channel = float64(channel)
      (k.srcX, k.srcY, k.rcvX, k.rcvY) = (1.0, 1.0, 1.0, 1.0)
      (k.t0Ms, k.intervalUs, k.status) = (0.0, DtMs * 1000, tsLive)
      w.writeTrace(k, buf)
  let log = w.close()
  doAssert log.len == 0, $log

proc stampTime(f: var SeismicFile; t: int; time: float64) =
  f.mindex.keys[t].time = time

proc likeCopy(file: var SeismicFile; dest: string) =
  ## The template writer the like path uses when nothing was joined or moved.
  var w = openSeismicWriter(dest, like = file)
  var samples = newSeq[float32]()
  for t in 0 ..< file.len:
    let x = file.readTraces(t .. t)
    samples.setLen x.shape[1]
    for j in 0 ..< samples.len: samples[j] = x[0, j]
    w.writeTrace(file, t, samples)
  discard w.close()

proc tinySegd(dir: string): string =
  result = dir / "tiny.sgd"
  var o = SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 4)
  var w = openSeismicWriter(result, o)
  var buf = @[1.0'f32, 2, 3, 4]
  var k = initTraceKeys()
  (k.record, k.channel, k.time, k.t0Ms, k.intervalUs, k.status) =
    (1.0, 1.0, 1_700_000_000.0, 0.0, 2000.0, tsLive)
  w.writeTrace(k, buf, channelType = sctSeismic)
  let log = w.close()
  doAssert log.len == 0, $log

func holds(line, text: string): bool = line.find(text) >= 0

func says(lines: seq[string]; text: string): bool =
  for line in lines:
    if holds(line, text): return true

proc segdAt(dir, name: string; x: float64; traces: int): string =
  ## SEG-D Rev 3 traces whose headers hold receiver X `x`.
  result = dir / name
  var w = openSeismicWriter(result, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 4))
  var buf = @[1.0'f32, 2, 3, 4]
  for i in 0 ..< traces:
    var k = initTraceKeys()
    (k.record, k.channel, k.time, k.rcvX, k.rcvY, k.srcX, k.srcY) =
      (1.0, float64(i + 1), 1_700_000_000.0, x, 2.0, 3.0, 4.0)
    (k.t0Ms, k.intervalUs, k.status) = (0.0, 2000.0, tsLive)
    w.writeTrace(k, buf, channelType = sctSeismic)
  let log = w.close()
  doAssert log.len == 0, $log

proc markReceiver(f: var SeismicFile; x: float64) =
  ## Puts receiver X `x` on every trace and marks it as a join, so the writer
  ## treats it as a session position. A missing Y is filled too: both
  ## coordinates have to be known before a writer tries to store them.
  for t in 0 ..< f.len:
    f.mindex.keys[t].rcvX = x
    if f.mindex.keys[t].rcvY.isNaN: f.mindex.keys[t].rcvY = 2.0
    f.mindex.markJoined(t, {jgReceiverXy})

proc rev21(dir: string): string =
  ## One Rev 2.1 trace, no trace-header extension: no coordinate slot.
  result = dir / "rev21.sgd"
  let ns = 4
  let fmt = sd8058
  var r = SegdRecord(layout: slRev2, format: some(fmt),
    revision: SegdRevision(major: 2, minor: 1))
  r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: 2, julianDay: 311, hour: 12, minute: 30, second: 5,
    manufacturerCode: 9, baseScanInterval16: 32, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 1, skewBlocks: 0,
    extendedHeaderBlocks: 0, externalHeaderBlocks: 0)
  r.gh2 = some SegdGeneralHeader2(extFileNumber: 1, revisionMajor: 2, revisionMinor: 1,
    generalTrailerBlocks: 0, extRecordLength: uint32(2 * ns), blockNumber: 2)
  r.sourceHeaders = @[SegdGeneralHeaderN(sourceLineNumber: 1, sourcePointNumber: 1,
    sourcePointIndex: 1, blockNumber: 3, sourceSetNumber: 1)]
  let seis = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1,
    endTime: uint16(ns), channelCount: 1, channelType: 1, gainControl: 3,
    traceHeaderExtensions: 0, verticalStack: 1, arrayForming: 1)
  r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[seis])]
  r.traceCount = 1
  var t = SegdTrace(layout: slRev2, index: 0, numSamples: ns)
  t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1, channelSetNumber: 1,
    traceNumber: 1, traceHeaderExtensions: 0)
  var vals = newSeq[float64](ns)
  for i in 0 ..< ns: vals[i] = float64(i + 1)
  t.samples = newSeq[byte](dataBytes(fmt, ns))
  encodeSamples(fmt, vals, t.samples)
  var d = SegdData(records: @[SegdRecordData(record: r, traces: @[t])])
  var sink = openDiskSink(result)
  try:
    let log = writeSegd(sink, d)
    doAssert log.count(sevError) + log.count(sevFatal) == 0, $log
  finally:
    sink.close()

proc hasCount(lines: seq[string]): bool =
  for line in lines:
    if holds(line, "not written in ") and holds(line, " traces"): return true

proc runCases(fx: Fixtures; outDir: string) =
  let survey = loadSurvey(fx.surveySps())
  let path = twoTimes(fx.dir)
  var f = openSeismic(path, keys = true)
  let t0 = 1_700_000_000.0
  let t1 = 1_700_001_000.0
  stampTime(f, 0, t0)
  stampTime(f, 1, t0)
  stampTime(f, 2, t1)
  stampTime(f, 3, t1)
  doAssert f.applySurvey(survey, overwrite = true) == 4, "the join did not change every trace"
  var moves = StationMoves()
  moves.add StationMove(station: StationKey(line: RcvLine, point: FirstRcvPoint, index: 0),
    fromTime: some(t1), x: 7000, y: OriginY)
  var bases: seq[ReceiverBase] = @[]
  doAssert f.applyFileMoves(moves, bases) > 0, "the move changed nothing"
  doAssert near(f.traceKeys(0).rcvX, rcvX(1)), "before the time the survey stands"
  doAssert near(f.traceKeys(2).rcvX, 7000), "at the time the move stands"
  let movedOff = abs(7000.0 - srcX(1))

  block written:
    let dest = outDir / "joined.sgy"
    let got = runWrite(f, path, dest, OutputOptions(format: ofSegy))
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    var back = openSeismic(dest, keys = true)
    doAssert near(back.traceKeys(0).rcvX, rcvX(1)) and near(back.traceKeys(0).rcvY, OriginY),
      "a joined trace kept the source easting " & $back.traceKeys(0).rcvX
    doAssert near(back.traceKeys(1).rcvX, rcvX(2)), "channel 2 was not the survey"
    doAssert near(back.traceKeys(2).rcvX, 7000) and near(back.traceKeys(2).rcvY, OriginY),
      "the moved station was not written at its time"
    doAssert near(back.traceKeys(3).rcvX, rcvX(2)), "the other station was moved too"
    doAssert near(back.traceKeys(0).offset, abs(rcvX(1) - srcX(0)), 1.0),
      "the offset did not follow the survey position"
    doAssert near(back.traceKeys(2).offset, movedOff, 1.0),
      "the offset did not follow the move"
    doAssert near(back.traceKeys(0).srcX, srcX(0), 1.0), "the source position was not written"
    var note = false
    for line in got.wrote.lines:
      if holds(line, "traces changed"): note = true
    doAssert note, "no note that positions were written: " & $got.wrote.lines
    back.close()

  block kept:
    let dest = outDir / "own.sgy"
    var opts = OutputOptions(format: ofSegy)
    opts.writeSessionPositions = false
    let got = runWrite(f, path, dest, opts)
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    var said = false
    for line in got.wrote.lines:
      if holds(line, "session's positions were not written"): said = true
    doAssert said, "the result did not say positions were not written: " & $got.wrote.lines
    var back = openSeismic(dest, keys = true)
    doAssert near(back.traceKeys(0).rcvX, 1) and near(back.traceKeys(2).rcvX, 1),
      "the option off wrote the session position " & $back.traceKeys(2).rcvX
    back.close()

  block sameBytes:
    let segy = fx.dir / "plain.sgy"
    var w = openSeismicWriter(segy, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
    var buf = @[1.0'f32, 2, 3, 4]
    var k = initTraceKeys()
    (k.record, k.channel, k.srcX, k.srcY, k.rcvX, k.rcvY) = (1.0, 1.0, 10.0, 20.0, 30.0, 40.0)
    (k.t0Ms, k.intervalUs, k.status) = (0.0, 2000.0, tsLive)
    w.writeTrace(k, buf)
    doAssert w.close().len == 0
    var plain = openSeismic(segy, keys = true)
    doAssert not plain.index.joined
    let copied = outDir / "plain-out.sgy"
    let twin = outDir / "plain-like.sgy"
    let got = runWrite(plain, segy, copied, OutputOptions(format: ofSegy))
    doAssert got.st == jsDone, got.error
    likeCopy(plain, twin)
    doAssert readFile(copied) == readFile(twin), "SEG-Y with no join was not the template writer"
    plain.close()

    let segd = tinySegd(fx.dir)
    var sd = openSeismic(segd, keys = true)
    doAssert not sd.index.joined
    let sdOut = outDir / "tiny-out.sgd"
    let sdTwin = outDir / "tiny-like.sgd"
    let gotd = runWrite(sd, segd, sdOut, OutputOptions(format: ofSegd))
    doAssert gotd.st == jsDone, gotd.error & " / " & gotd.wrote.reason
    likeCopy(sd, sdTwin)
    doAssert readFile(sdOut) == readFile(sdTwin), "SEG-D with no join was not the template writer"
    sd.close()

  block noSlot:
    let src = fx.stationsSegd()
    var g = openSeismic(src, keys = true)
    doAssert g.applySurvey(survey, overwrite = true) > 0, "the stations file did not join"
    let dest = outDir / "joined.sgd"
    let got = runWrite(g, src, dest, OutputOptions(format: ofSegd))
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    doAssert hasCount(got.wrote.lines),
      "a value with no slot was not counted: " & $got.wrote.lines
    doAssert says(got.wrote.lines, "where the format has a place for them"),
      "a partial write still claimed every trace changed: " & $got.wrote.lines
    g.close()

  block droppedNotCounted:
    var edits: FileEdits
    doAssert edits.change(teKilled, [0], true) == 1
    let dest = outDir / "dropped.sgy"
    var opts = OutputOptions(format: ofSegy, dropKilled: true)
    let got = runWrite(f, path, dest, opts, edits)
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    doAssert says(got.wrote.lines, "(3 traces changed)"),
      "a dropped joined trace was counted: " & $got.wrote.lines
    doAssert says(got.wrote.lines, "where the format has a place for them"),
      "stations with no slot were claimed stored: " & $got.wrote.lines
    doAssert not says(got.wrote.lines, "(4 traces changed)"), $got.wrote.lines

  block keysOwn:
    let src = segdAt(fx.dir, "own-x.sgd", 1.0, 1)
    var g = openSeismic(src, keys = true)
    doAssert near(g.traceKeys(0).rcvX, 1), "the file's own X was not 1"
    markReceiver(g, 500_000)
    let dest = outDir / "own-x.sgy"
    var opts = OutputOptions(format: ofSegy)
    opts.writeSessionPositions = false
    let got = runWrite(g, src, dest, opts)
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    doAssert says(got.wrote.lines, "file's own positions were written"),
      "the keys path did not say the file's own positions were written: " & $got.wrote.lines
    doAssert says(got.wrote.lines, "header keys"),
      "the result did not say which source: " & $got.wrote.lines
    var back = openSeismic(dest, keys = true)
    doAssert near(back.traceKeys(0).rcvX, 1),
      "the tick on wrote the session X " & $back.traceKeys(0).rcvX
    back.close()
    g.close()

  block keysSession:
    let src = segdAt(fx.dir, "session-x.sgd", 1.0, 2)
    var g = openSeismic(src, keys = true)
    markReceiver(g, 500_000)
    var edits: FileEdits
    doAssert edits.change(teKilled, [1], true) == 1
    let dest = outDir / "session-x.sgy"
    let got = runWrite(g, src, dest, OutputOptions(format: ofSegy, dropKilled: true), edits)
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    doAssert says(got.wrote.lines, "(1 traces changed)"),
      "the keys path did not say the session positions were written: " & $got.wrote.lines
    doAssert not says(got.wrote.lines, "(2 traces changed)"), $got.wrote.lines
    var back = openSeismic(dest, keys = true)
    doAssert back.len == 1
    doAssert near(back.traceKeys(0).rcvX, 500_000),
      "the tick off did not write the session X " & $back.traceKeys(0).rcvX
    back.close()
    g.close()

  block noSlotRev21:
    let src = rev21(fx.dir)
    var g = openSeismic(src, keys = true)
    doAssert g.len == 1, "the Rev 2.1 file did not open"
    markReceiver(g, 500_000)
    let dest = outDir / "rev21-out.sgd"
    let twin = outDir / "rev21-like.sgd"
    let got = runWrite(g, src, dest, OutputOptions(format: ofSegd))
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    likeCopy(g, twin)
    doAssert readFile(dest) == readFile(twin), "a no-slot write changed the header bytes"
    doAssert says(got.wrote.lines, "could not be written in this format"),
      "a no-slot write claimed positions were written: " & $got.wrote.lines
    doAssert not says(got.wrote.lines, "traces changed"), $got.wrote.lines
    g.close()

  block tooLarge:
    let src = fx.dir / "huge.sgy"
    var w = openSeismicWriter(src, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
      revision: SegyRevision(major: 1, minor: 0)))
    var buf = @[1.0'f32, 2, 3, 4]
    var k = initTraceKeys()
    (k.record, k.channel, k.rcvX, k.rcvY) = (1.0, 1.0, 10.0, 20.0)
    (k.t0Ms, k.intervalUs, k.status) = (0.0, 2000.0, tsLive)
    w.writeTrace(k, buf)
    doAssert w.close().len == 0
    var g = openSeismic(src, keys = true)
    markReceiver(g, 1e16)
    let dest = outDir / "huge-out.sgy"
    let got = runWrite(g, src, dest, OutputOptions(format: ofSegy))
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    doAssert says(got.wrote.lines, "could not be written in this format"),
      "a value too large was counted as written: " & $got.wrote.lines
    doAssert not says(got.wrote.lines, "traces changed"), $got.wrote.lines
    var back = openSeismic(dest, keys = true)
    doAssert near(back.traceKeys(0).rcvX, 10),
      "a value too large was stored: " & $back.traceKeys(0).rcvX
    back.close()
    g.close()

  block signatureKeys:
    let src = fx.dir / "sig-image.sgy"
    var w = openSeismicWriter(src, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
    var buf = @[1.0'f32, 2, 3, 4]
    var k = initTraceKeys()
    (k.record, k.channel, k.time, k.rcvX, k.rcvY) = (1.0, 1.0, 1_700_000_000.0, 1.0, 2.0)
    (k.t0Ms, k.intervalUs, k.status) = (0.0, 2000.0, tsLive)
    w.writeTrace(k, buf)
    doAssert w.close().len == 0
    let raw = readFile(src)
    var bytes = newSeq[byte](raw.len)
    if raw.len > 0: copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
    # A different file at the path, so a second open of the path is not the image.
    writeFile(src, "not a seismic file")
    var mem = openSeismicBytes(bytes, src, keys = true)
    markReceiver(mem, 500_000)
    let sig = SignatureFacts(kind: sgVib)
    block noted:
      let dest = outDir / "sig-session.sgd"
      var opts = OutputOptions(format: ofSegd, applyReversals: true)
      let got = runWrite(mem, src, dest, opts, signature = sig)
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      doAssert says(got.wrote.lines, "(1 traces changed)"),
        "a signature on the keys path stored positions with no note: " & $got.wrote.lines
    block kept:
      let dest = outDir / "sig-own.sgd"
      var opts = OutputOptions(format: ofSegd, applyReversals: true)
      opts.writeSessionPositions = false
      let got = runWrite(mem, src, dest, opts, signature = sig)
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      doAssert says(got.wrote.lines, "file's own positions were written"),
        "a signature kept no note of its own positions: " & $got.wrote.lines
      var back = openSeismic(dest, keys = true)
      doAssert near(back.traceKeys(0).rcvX, 1),
        "the signature wrote the session X " & $back.traceKeys(0).rcvX
      back.close()
    mem.close()

  f.close()

proc runBatchCases(fx: Fixtures; outDir: string) =
  var survey = loadSurvey(fx.surveySps())
  let inDir = outDir / "batch-in"
  createDir(inDir)
  let a = twoTimes(inDir, "a.sgy")
  let b = twoTimes(inDir, "b.sgy")
  let c = twoTimes(inDir, "c.sgy", first = 9000)
  var moves = StationMoves()
  moves.add StationMove(station: StationKey(line: RcvLine, point: FirstRcvPoint, index: 0),
    x: 7000, y: OriginY)
  let withProject = BatchProject(survey: addr survey, options: JoinOptions(coordinates: hcReplace),
    moves: moves)

  proc runIt(ask: BatchAsk): BatchResult =
    let jobs = initJobs()
    let sink = BatchSink()
    let id = jobs.submit(outputBatchSpec(ask), outputBatchWork(ask, Store(), @[], sink))
    doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
      "the batch did not finish"
    doAssert jobs.state(id) == jsDone, jobs.info(id).get.error & " / " & sink.result.reason
    sink.result

  proc items(names: varargs[string]): seq[BatchItem] =
    for n in names: result.add BatchItem(source: inDir / n, relative: n)

  # What writing each file alone gives: the session's join, then the moves.
  proc alone(path, dest: string; join = true) =
    var f = openSeismic(path, keys = true)
    if join:
      doAssert f.applySurvey(survey, overwrite = true) > 0, "the join changed nothing"
      var bases: seq[ReceiverBase] = @[]
      doAssert f.applyFileMoves(moves, bases) > 0, "the move changed nothing"
    let got = runWrite(f, path, dest, OutputOptions(format: ofSegy))
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    f.close()

  proc sameBytes(x, y: string) =
    var fx = openSeismic(x, keys = true)
    var fy = openSeismic(y, keys = true)
    doAssert fx.len == fy.len
    for t in 0 ..< fx.len:
      let (p, q) = (fx.traceKeys(t), fy.traceKeys(t))
      doAssert near(p.rcvX, q.rcvX) and near(p.rcvY, q.rcvY) and near(p.srcX, q.srcX) and
        near(p.srcY, q.srcY) and near(p.offset, q.offset, 1.0),
        "trace " & $t & " differs from writing the file alone: rcvX " & $p.rcvX & " vs " & $q.rcvX
    fx.close()
    fy.close()

  let ask = BatchAsk(root: inDir, items: items("a.sgy", "b.sgy", "c.sgy"),
    destRoot: outDir / "batch-out", options: OutputOptions(format: ofSegy,
    writeSessionPositions: true), mirrorFolders: true, project: withProject)
  let got = runIt(ask)
  doAssert got.written == 3 and got.failed == 0, $got
  for n in ["a.sgy", "b.sgy"]:
    let dest = outDir / "batch-out" / n
    var back = openSeismic(dest, keys = true)
    doAssert near(back.traceKeys(0).rcvX, 7000) and near(back.traceKeys(0).rcvY, OriginY),
      "a batch file kept the header easting " & $back.traceKeys(0).rcvX
    doAssert near(back.traceKeys(1).rcvX, rcvX(2)), "channel 2 was not the survey's: " &
        $back.traceKeys(1).rcvX & " vs " & $rcvX(2)
    doAssert near(back.traceKeys(3).rcvX, rcvX(2)), "channel 2 of shot 2 was not the survey's"
    back.close()
    alone(inDir / n, outDir / ("alone-" & n))
    sameBytes(dest, outDir / ("alone-" & n))
    let r = got.items[if n == "a.sgy": 0 else: 1]
    doAssert says(r.lines, BatchJoinedPositions), "no joined line: " & $r.lines
    doAssert not says(r.lines, BatchOwnPositions), $r.lines
  # The file the survey does not cover keeps its own positions, even with the move
  # (the move names a station its traces do not have), and says so.
  var cover = openSeismic(outDir / "batch-out" / "c.sgy", keys = true)
  doAssert near(cover.traceKeys(0).rcvX, 1), "an uncovered file was changed"
  cover.close()
  doAssert says(got.items[2].lines, BatchSurveyNotCovered), $got.items[2].lines
  # Nothing set: the old line, and the file's own positions.
  var bare = ask
  bare.project = BatchProject()
  bare.destRoot = outDir / "batch-bare"
  bare.items = items("a.sgy")
  let plain = runIt(bare)
  doAssert says(plain.items[0].lines, BatchOwnPositions), $plain.items[0].lines
  var own = openSeismic(outDir / "batch-bare" / "a.sgy", keys = true)
  doAssert near(own.traceKeys(0).rcvX, 1), "no project: the file was changed"
  own.close()

proc main*() =
  let outDir = createTempDir("viewseg-outpos-", "")
  try:
    withFixtures fx:
      runCases(fx, outDir)
      runBatchCases(fx, outDir)
  finally:
    removeDir(outDir)

when isMainModule:
  main()
