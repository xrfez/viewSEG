## The like path writes survey-join and station-move positions into the output
## headers, and says so. The option off keeps the source headers and says the
## session's positions were not written. Nothing joined or moved stays the
## template writer, byte for byte, for SEG-Y and SEG-D. A value with no slot
## is counted in the result lines.
##
## Seen to fail: the like path copied the source headers, so a joined receiver
## stayed at 1 (`rcvX` 1, not the survey easting) and the result had no
## "traces changed" line.
##
## Synthetic files only, from the join fixtures' survey.

import std/[math, options, os, strutils, tempfiles]
import parseSEG
import parseSEG/model/traceindex
import viewSEG/core/[edits, jobs, outputjobs, stationmoves]
import utils/[fixtures, waiting]

func near(a, b: float64; tol = 0.05): bool =
  if a.isNaN or b.isNaN: a.isNaN and b.isNaN
  else: abs(a - b) <= tol

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc runWrite(file: var SeismicFile; source, dest: string; opts: OutputOptions):
    tuple[st: JobState; wrote: OutputResult; error: string] =
  let jobs = initJobs()
  let sink = OutputSink()
  let id = jobs.submit(outputSpec(source, dest),
    outputWork(addr file, source, dest, opts, FileEdits(), @[source], sink))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the write did not finish: " & $jobs.state(id)
  let info = jobs.info(id).get
  (info.state, sink.result, info.error)

proc loadSurvey(paths: SpsPaths): SurveyGeometry =
  result = initSurveyGeometry()
  result.addSps(paths.s)
  result.addSps(paths.r)
  result.addSps(paths.x)

proc twoTimes(dir: string): string =
  ## Two shots, two channels, header coordinates (1, 1), so a join replaces
  ## them. Times are stamped on the keys after open: the writer does not
  ## store `TraceKeys.time` in these headers.
  result = dir / "two-times.sgy"
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1))
  var buf = newSeq[float32](8)
  for i in 0 ..< buf.len: buf[i] = float32(i + 1)
  for shot in 0 .. 1:
    for channel in 1 .. 2:
      var k = initTraceKeys()
      k.record = float64(FirstRecord + shot)
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
    g.close()

  f.close()

proc main*() =
  let outDir = createTempDir("viewseg-outpos-", "")
  try:
    withFixtures fx:
      runCases(fx, outDir)
  finally:
    removeDir(outDir)

when isMainModule:
  main()
