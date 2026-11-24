## Output correlates one trace at a time with a loaded reference.
##
## Seen to fail: the correlation call was omitted, so trace 0 sample 0 stayed
## 0.0 against the button's sample. A one-count change with the option off
## made the SEG-Y bytes differ from the template writer. With the interval
## check off, the failure was the kernel's resample sentence, not the
## correlation job's. With the listen-time check off, a record no longer than
## the sweep failed as "reference trace 3 is outside 0 .. 0".
##
## (a) Output with the option matches Output of the correlate-button result,
## every sample and the sample count, for SEG-Y and SEG-D.
## (b) with no option, the bytes match the template writer.
## (c) an interval that differs refuses and leaves no file.
## (d) a record that is not longer than the sweep refuses the same way.
## (e) a dead seismic trace is written dead, as zeros, equal to the button.
## (f) a time shift, an own filter and a polarity reversal, each applied with
## the option, match the button then Output.
## (g) a joined source X is written when session positions are on, and the
## file's own when they are off. The button's file keeps its own.
##
## Seen to fail: trace 1 was marked live and correlated, so sample 0 was 1.0
## against the button's 0.0. A +8 ms shift before correlation left trace 0
## sample 0 at -0.2962032 against the button's 0.0. An own filter on the raw
## trace left sample 0 at 0.43718278 against the button's 0.2898751. Polarity
## left off left sample 0 at 1.0 against the button's -1.0. With the session
## keys left out of a correlated write, joined source X stayed 10.0, not 111.
## An int16 source with the option on kept format code 3 (`option format 3`).
## An 8036 SEG-D source kept format 8036 (`option format 8036`). An 8015
## source whose listen length was 94 refused: "SEG-D format 8015 holds
## samples in groups of 4". With the interval left on the keys, SEG-D from
## keys refused "the keys' sample interval is 4000.0 µs, the output's is 2000.0".
## With the filter designed at trace 0's interval, an own filter on a seismic
## trace left sample 0 at -0.015427755 against the button's -0.01319716.
## With no correlation notes, the result's lines were empty, so "5 traces,
## 800 samples (1600 ms of listen time)." was missing. A file cut while it
## was open failed the write ("was cut short while it was open") instead of
## writing the unreadable trace as zeros.

import std/[math, options, os, strutils]
import parseSEG
import parseSEG/model/traceindex
import processSEG
import viewSEG/core/[correlatejobs, edits, jobs, outputjobs, processing, session]
import utils/waiting

const
  DtMs = 2.0
  Record = 1000
  SweepLen = 200
  Listen = 800
  Delays = [40, 100, 200]
  RefAux = 3
  DeadRecord = 400
  DeadTrace = 1
  DeadListen = DeadRecord - SweepLen
  ShortSweep = 32
  ShortRecord = 400
  ShortListen = ShortRecord - ShortSweep
  OwnSrcX = 10.0
  JoinedSrcX = 111.0
  OwnSrcY = 20.0

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc samplesOf(f: SeismicFile; trace: int): seq[float32] =
  let x = f.readTraces(trace .. trace)
  result.setLen x.shape[1]
  for j in 0 ..< result.len: result[j] = x[0, j]

proc delayedSweep(sweep: openArray[float32]; samples, delay: int): seq[float32] =
  result = newSeq[float32](samples)
  for i in 0 ..< samples:
    let j = i - delay
    if j >= 0 and j < sweep.len: result[i] = sweep[j]

proc writeRaw(path: string; sweep: openArray[float32]; fmt = st5) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, format: fmt, text: @["C01 output correlation"]))
  for i in 0 .. 4:
    var buf: seq[float32]
    var k = initTraceKeys()
    if i < Delays.len:
      buf = delayedSweep(sweep, Record, Delays[i])
      (k.traceCode, k.status) = (1'i16, tsLive)
    elif i == RefAux:
      buf = delayedSweep(sweep, Record, 0)
      (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    else:
      buf = newSeq[float32](Record)
      for j in 0 ..< Record: buf[j] = float32(j + 1)
      (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    k.record = 7.0
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the raw file did not close"

proc writeDead(path: string; sweep: openArray[float32]) =
  ## SEG-Y, 2 ms, 400 samples. Trace 1 is dead and holds the sweep, so a
  ## live correlation of it is not zeros. The reference auxiliary is trace 3.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, text: @["C01 a dead trace stays dead"]))
  for i in 0 .. 4:
    var buf: seq[float32]
    var k = initTraceKeys()
    if i == DeadTrace:
      buf = delayedSweep(sweep, DeadRecord, 0)
      buf[0] = 1
      (k.traceCode, k.status) = (2'i16, tsDead)
    elif i < Delays.len:
      buf = delayedSweep(sweep, DeadRecord, Delays[i])
      (k.traceCode, k.status) = (1'i16, tsLive)
    elif i == RefAux:
      buf = delayedSweep(sweep, DeadRecord, 0)
      (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    else:
      buf = newSeq[float32](DeadRecord)
      for j in 0 ..< DeadRecord: buf[j] = float32(j + 1)
      (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    k.record = 7.0
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the dead-trace file did not close"

proc writeShort(path: string; sweep: openArray[float32]) =
  ## SEG-Y, 2 ms, 400 samples, a 32-sample sweep at sample 0 of trace 0.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, text: @["C01 correlate then edit"]))
  for i in 0 .. 4:
    var buf: seq[float32]
    var k = initTraceKeys()
    if i < Delays.len:
      let delay = if i == 0: 0 else: Delays[i]
      buf = delayedSweep(sweep, ShortRecord, delay)
      (k.traceCode, k.status) = (1'i16, tsLive)
    elif i == RefAux:
      buf = delayedSweep(sweep, ShortRecord, 0)
      (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    else:
      buf = newSeq[float32](ShortRecord)
      for j in 0 ..< ShortRecord: buf[j] = float32(j + 1)
      (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    k.record = 7.0
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the short-sweep file did not close"

proc writePlaced(path: string; sweep: openArray[float32]) =
  ## SEG-Y whose headers hold source X 10. A later join can replace that.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, text: @["C01 positions stay the output rule"]))
  for i in 0 .. 4:
    var buf: seq[float32]
    var k = initTraceKeys()
    if i < Delays.len:
      buf = delayedSweep(sweep, Record, Delays[i])
      (k.traceCode, k.status) = (1'i16, tsLive)
    elif i == RefAux:
      buf = delayedSweep(sweep, Record, 0)
      (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    else:
      buf = newSeq[float32](Record)
      for j in 0 ..< Record: buf[j] = float32(j + 1)
      (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    k.record = 7.0
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    (k.srcX, k.srcY) = (OwnSrcX, OwnSrcY)
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the placed file did not close"

proc writeAuxFirst(path: string; sweep: openArray[float32]) =
  ## SEG-D. Trace 0 is an auxiliary of its own channel type; the reference
  ## auxiliary is another type, so the two can be given different intervals.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: DtMs * 1000.0,
    numSamples: Record, time: 1_700_000_000.0))
  for i in 0 .. 4:
    var buf: seq[float32]
    var k = initTraceKeys()
    var ct: SegdChannelType
    if i == 0:
      buf = newSeq[float32](Record)
      for j in 0 ..< Record: buf[j] = float32(j + 1)
      (k.traceCode, k.status) = (6'i16, tsAuxiliary)
      ct = sctOther
    elif i == RefAux:
      buf = delayedSweep(sweep, Record, 0)
      (k.traceCode, k.status) = (5'i16, tsAuxiliary)
      ct = sctTimeBreak
    else:
      buf = delayedSweep(sweep, Record, Delays[0])
      (k.traceCode, k.status) = (1'i16, tsLive)
      ct = sctSeismic
    k.record = 7.0
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf, channelType = ct)
  doAssert w.close().len == 0, "the auxiliary-first file did not close"

proc patchChannelInterval(path: string; code: uint8; us: int) =
  ## Sets one channel set's sampling interval. The keys writer stores one
  ## interval; a file with two is made by editing that field.
  var f = openSeismic(path, keys = true)
  let rec = f.index.segdRecords[0]
  var which = -1
  for i, d in rec.scanTypes[0].descriptorsRev3:
    if d.channelType == code: which = i
  doAssert which >= 0, "channel type " & $code & " was not written"
  let at = int(rec.offset) + 3 * SegdBlockSize + rec.generalBlocks.len + which * 96 + 23
  f.close()
  var bytes = readFile(path)
  doAssert ord(bytes[at]) == 0 and ord(bytes[at + 1]) == 0x07 and ord(bytes[at + 2]) == 0xD0,
    "interval bytes at " & $at & " are not 2000"
  bytes[at] = chr((us shr 16) and 0xFF)
  bytes[at + 1] = chr((us shr 8) and 0xFF)
  bytes[at + 2] = chr(us and 0xFF)
  writeFile(path, bytes)

proc writeMixed(path: string; sweep: openArray[float32]) =
  ## SEG-Y, 2 ms, with the last auxiliary trace at 4 ms.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, text: @["C01 an auxiliary at another interval"]))
  for i in 0 .. 4:
    var buf: seq[float32]
    var k = initTraceKeys()
    if i < Delays.len:
      buf = delayedSweep(sweep, Record, Delays[i])
      (k.traceCode, k.status) = (1'i16, tsLive)
    elif i == RefAux:
      buf = delayedSweep(sweep, Record, 0)
      (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    else:
      buf = newSeq[float32](Record)
      for j in 0 ..< Record: buf[j] = float32(j + 1)
      (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    k.record = 7.0
    k.channel = float64(i + 1)
    k.intervalUs = if i == 4: 4000.0 else: DtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the mixed-interval file did not close"

proc writeSegd(path: string; sweep: openArray[float32]; fmt = sd8058; n = Record) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: DtMs * 1000.0,
    numSamples: n, time: 1_700_000_000.0, format: fmt))
  for i in 0 .. 4:
    var buf: seq[float32]
    var k = initTraceKeys()
    if i < Delays.len:
      let delay = if n > Delays[i]: Delays[i] else: 0
      buf = delayedSweep(sweep, n, delay)
      (k.traceCode, k.status) = (1'i16, tsLive)
    elif i == RefAux:
      buf = delayedSweep(sweep, n, 0)
      (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    else:
      buf = newSeq[float32](n)
      for j in 0 ..< n: buf[j] = float32(j + 1)
      (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    k.record = 7.0
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    let ct = if k.status == tsAuxiliary: sctOther else: sctSeismic
    w.writeTrace(k, buf, channelType = ct)
  doAssert w.close().len == 0, "the SEG-D file did not close"

proc likeCopy(file: var SeismicFile; dest: string) =
  var w = openSeismicWriter(dest, like = file)
  var samples = newSeq[float32]()
  for t in 0 ..< file.len:
    let x = file.readTraces(t .. t)
    samples.setLen x.shape[1]
    for j in 0 ..< samples.len: samples[j] = x[0, j]
    w.writeTrace(file, t, samples)
  doAssert w.close().len == 0, "the template copy did not close"

proc runWrite(file: var SeismicFile; source, dest: string; opts: OutputOptions;
    edits = FileEdits()): tuple[st: JobState; wrote: OutputResult; error: string] =
  let jobs = initJobs()
  let sink = OutputSink()
  let id = jobs.submit(outputSpec(source, dest),
    outputWork(addr file, source, dest, opts, edits, @[source], sink))
  doAssert waitUntil(state(jobs, id) in {jsDone, jsFailed, jsCancelled}),
    "the write did not finish: " & $state(jobs, id)
  let info = jobs.info(id).get
  (info.state, sink.result, info.error)

proc spec(path: string): JobSpec =
  JobSpec(title: "Correlate " & path.extractFilename, lane: jlBackground,
    reads: @[path], cancellable: true)

proc correlate(file: var SeismicFile; path: string; sweep: seq[float32]): CorrelateResult =
  var jobs = initJobs()
  result.opened = nil
  result.lines = @[]
  try:
    let id = jobs.submit(spec(path), correlateWork(CorrelateAsk(
      file: addr file, path: path, reference: sweep, referenceDtMs: DtMs,
      referenceTraces: @[RefAux]), addr result))
    doAssert waitUntil(state(jobs, id) in {jsDone, jsFailed, jsCancelled})
    doAssert state(jobs, id) == jsDone, result.failure
  finally:
    jobs.stop()
  doAssert result.ok, result.failure

proc option(sweep: seq[float32]; format: OutputFormat): OutputOptions =
  OutputOptions(format: format, correlation: some(OutputCorrelation(
    reference: sweep, referenceDtMs: DtMs, referenceTraces: @[RefAux])))

proc withCorrelation(opts: OutputOptions; sweep: seq[float32]): OutputOptions =
  result = opts
  result.format = ofSegy
  result.correlation = some(OutputCorrelation(reference: sweep, referenceDtMs: DtMs,
    referenceTraces: @[RefAux]))

proc withoutCorrelation(opts: OutputOptions): OutputOptions =
  result = opts
  result.format = ofSegy
  result.correlation = none(OutputCorrelation)

proc sameTraces(a, b: SeismicFile; listen: int) =
  doAssert a.len == b.len, "trace count " & $a.len & " vs " & $b.len
  for t in 0 ..< a.len:
    let x = samplesOf(a, t)
    let y = samplesOf(b, t)
    doAssert x.len == y.len and x.len == listen, "trace " & $t & " count " & $x.len &
      " vs " & $y.len
    for j in 0 ..< x.len:
      doAssert x[j] == y[j], "trace " & $t & " sample " & $j & " " & $x[j] & " vs " & $y[j]

proc sameWritten(a, b: SeismicFile; segy: bool) =
  doAssert a.len == b.len, "trace count " & $a.len & " vs " & $b.len
  for t in 0 ..< a.len:
    let x = samplesOf(a, t)
    let y = samplesOf(b, t)
    doAssert x.len == y.len, "trace " & $t & " count " & $x.len & " vs " & $y.len
    doAssert int(a.traceEntry(t).numSamples) == int(b.traceEntry(t).numSamples),
      "trace " & $t & " header count " & $a.traceEntry(t).numSamples & " vs " &
      $b.traceEntry(t).numSamples
    doAssert x.len == Listen, "trace " & $t & " has " & $x.len & " samples, not " & $Listen
    for j in 0 ..< x.len:
      doAssert x[j] == y[j], "trace " & $t & " sample " & $j & " " & $x[j] & " vs " & $y[j]
    if segy:
      let fa = a.traceField(t, "trace.correlated")
      let fb = b.traceField(t, "trace.correlated")
      doAssert fa.kind == fvInt and fa.intVal == CorrelatedYes, "trace " & $t &
        " correlated " & $fa
      doAssert fb.kind == fvInt and fb.intVal == CorrelatedYes, "trace " & $t &
        " button correlated " & $fb

proc noPart(dir, stem: string) =
  doAssert not fileExists(dir / stem), stem & " was written"
  for kind, p in walkDir(dir):
    let name = extractFilename(p)
    doAssert not name.startsWith(stem & ".part"), "a partial file was left: " & name

proc main*() =
  let dir = getTempDir() / ("toutputcorrelate-" & $getCurrentProcessId())
  let srcDir = dir / "src"
  let outDir = dir / "out"
  createDir(srcDir)
  createDir(outDir)
  defer: removeDir(dir)
  let specSweep = linearSweep(8.0, 80.0, float64(SweepLen) * DtMs, DtMs)
  let sweep = specSweep.sweepSamples(float32)
  doAssert sweep.len == SweepLen
  let path = srcDir / "raw.sgy"
  writeRaw(path, sweep)
  var file = openSeismic(path, keys = true)
  defer: file.close()

  block unchangedBytes:
    let copied = outDir / "plain.sgy"
    let twin = outDir / "plain-like.sgy"
    let got = runWrite(file, path, copied, OutputOptions(format: ofSegy))
    doAssert got.st == jsDone, got.error
    likeCopy(file, twin)
    doAssert readFile(copied) == readFile(twin), "SEG-Y with no option was not the template writer"
    let segd = srcDir / "raw.sgd"
    writeSegd(segd, sweep)
    var sd = openSeismic(segd, keys = true)
    defer: sd.close()
    let sdOut = outDir / "plain.sgd"
    let sdTwin = outDir / "plain-like.sgd"
    let gotd = runWrite(sd, segd, sdOut, OutputOptions(format: ofSegd))
    doAssert gotd.st == jsDone, gotd.error
    likeCopy(sd, sdTwin)
    doAssert readFile(sdOut) == readFile(sdTwin), "SEG-D with no option was not the template writer"

  block matchesButton:
    let made = correlate(file, path, sweep)
    var opened = made.opened.filePtr
    for format in [ofSegy, ofSegd]:
      let ext = if format == ofSegy: ".sgy" else: ".sgd"
      let fromButton = outDir / ("button" & ext)
      let fromOption = outDir / ("option" & ext)
      let button = runWrite(opened[], path, fromButton, OutputOptions(format: format))
      doAssert button.st == jsDone, button.error & " / " & button.wrote.reason
      let opted = runWrite(file, path, fromOption, option(sweep, format))
      doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
      var a = openSeismic(fromOption, keys = true)
      var b = openSeismic(fromButton, keys = true)
      sameWritten(a, b, format == ofSegy)
      a.close()
      b.close()
    opened[].close()

  block deadStaysDead:
    ## SEG-Y, 2 ms, 400 samples, trace 1 dead with a nonzero sample.
    ## Seen to fail: the option correlated it, so sample 0 was not the button's 0.
    let deadPath = srcDir / "dead.sgy"
    writeDead(deadPath, sweep)
    var dead = openSeismic(deadPath, keys = true)
    doAssert dead.traceKeys(DeadTrace).status == tsDead, "trace 1 was not stored dead"
    doAssert samplesOf(dead, DeadTrace)[0] != 0, "trace 1 had no nonzero sample"
    let made = correlate(dead, deadPath, sweep)
    var opened = made.opened.filePtr
    let fromButton = outDir / "dead-button.sgy"
    let fromOption = outDir / "dead-option.sgy"
    let button = runWrite(opened[], deadPath, fromButton, OutputOptions(format: ofSegy))
    doAssert button.st == jsDone, button.error & " / " & button.wrote.reason
    let opted = runWrite(dead, deadPath, fromOption, option(sweep, ofSegy))
    doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
    var a = openSeismic(fromOption, keys = true)
    var b = openSeismic(fromButton, keys = true)
    doAssert a.len == b.len, "trace count " & $a.len & " vs " & $b.len
    doAssert a.traceKeys(DeadTrace).status == tsDead, "the option wrote trace 1 live"
    doAssert b.traceKeys(DeadTrace).status == tsDead, "the button wrote trace 1 live"
    var live = false
    for t in 0 ..< a.len:
      let x = samplesOf(a, t)
      let y = samplesOf(b, t)
      doAssert x.len == y.len and x.len == DeadListen, "trace " & $t & " count " & $x.len &
        " vs " & $y.len
      for j in 0 ..< x.len:
        doAssert x[j] == y[j], "trace " & $t & " sample " & $j & " " & $x[j] & " vs " & $y[j]
      if t != DeadTrace:
        for v in x:
          if v != 0: live = true
    for j, v in samplesOf(a, DeadTrace):
      doAssert v == 0, "dead trace sample " & $j & " is " & $v & ", not 0"
    doAssert live, "a live trace was written as zeros"
    a.close()
    b.close()
    opened[].close()
    dead.close()

  block editsAfterCorrelate:
    ## Sweep of 32 samples, 2 ms. A +8 ms shift, an own filter and a polarity
    ## reversal, each equal to the button then Output.
    let specSweep = linearSweep(8.0, 80.0, float64(ShortSweep) * DtMs, DtMs)
    let short = specSweep.sweepSamples(float32)
    doAssert short.len == ShortSweep
    let shortPath = srcDir / "short-sweep.sgy"
    writeShort(shortPath, short)
    var raw = openSeismic(shortPath, keys = true)
    let made = correlate(raw, shortPath, short)
    var opened = made.opened.filePtr
    block shifted:
      ## Trace 0, +8 ms. Seen to fail: the shift ran before correlation, so
      ## sample 0 was -0.2962032 against the button's 0.0.
      var edits: FileEdits
      doAssert edits.setTimeShifts([0], 8.0, DtMs) == 1
      doAssert edits.shiftOf(0) == 8.0
      let flags = OutputOptions(applyShifts: true)
      let fromButton = outDir / "shift-button.sgy"
      let fromOption = outDir / "shift-option.sgy"
      let button = runWrite(opened[], shortPath, fromButton, withoutCorrelation(flags), edits)
      doAssert button.st == jsDone, button.error & " / " & button.wrote.reason
      let opted = runWrite(raw, shortPath, fromOption, withCorrelation(flags, short), edits)
      doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
      var a = openSeismic(fromOption, keys = true)
      var b = openSeismic(fromButton, keys = true)
      sameTraces(a, b, ShortListen)
      doAssert samplesOf(b, 0)[3] == 0, "button sample 3 was " & $samplesOf(b, 0)[3]
      a.close()
      b.close()
    block ownFilter:
      ## An own filter on trace 0. Seen to fail: it filtered the raw trace, so
      ## sample 0 was 0.43718278 against the button's 0.2898751.
      var edits: FileEdits
      let own = bounded(OwnFilter(spec: Processing(band: pbBandPass, f1: 8, f2: 12,
        f3: 40, f4: 50)))
      doAssert edits.setOwnFilters([0], own) == 1
      let flags = OutputOptions(applyOwnFilters: true)
      let fromButton = outDir / "own-button.sgy"
      let fromOption = outDir / "own-option.sgy"
      let plain = outDir / "own-plain.sgy"
      let button = runWrite(opened[], shortPath, fromButton, withoutCorrelation(flags), edits)
      doAssert button.st == jsDone, button.error & " / " & button.wrote.reason
      let opted = runWrite(raw, shortPath, fromOption, withCorrelation(flags, short), edits)
      doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
      let bare = runWrite(raw, shortPath, plain, withCorrelation(OutputOptions(), short))
      doAssert bare.st == jsDone, bare.error & " / " & bare.wrote.reason
      var a = openSeismic(fromOption, keys = true)
      var b = openSeismic(fromButton, keys = true)
      var p = openSeismic(plain, keys = true)
      sameTraces(a, b, ShortListen)
      doAssert samplesOf(a, 0) != samplesOf(p, 0), "the own filter changed nothing"
      a.close()
      b.close()
      p.close()
    block polarity:
      ## Polarity still equal. Seen to fail: left off, sample 0 was 1.0 against
      ## the button's -1.0.
      var edits: FileEdits
      doAssert edits.change(teReversed, [0], true) == 1
      let flags = OutputOptions(applyReversals: true)
      let fromButton = outDir / "flip-button.sgy"
      let fromOption = outDir / "flip-option.sgy"
      let button = runWrite(opened[], shortPath, fromButton, withoutCorrelation(flags), edits)
      doAssert button.st == jsDone, button.error & " / " & button.wrote.reason
      let opted = runWrite(raw, shortPath, fromOption, withCorrelation(flags, short), edits)
      doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
      var a = openSeismic(fromOption, keys = true)
      var b = openSeismic(fromButton, keys = true)
      sameTraces(a, b, ShortListen)
      var negated = false
      let plain = samplesOf(opened[], 0)
      let wrote = samplesOf(a, 0)
      for j in 0 ..< wrote.len:
        if wrote[j] == -plain[j] and wrote[j] != 0: negated = true
      doAssert negated, "polarity did not negate trace 0"
      a.close()
      b.close()
    opened[].close()
    raw.close()

  block segdSource:
    let segd = srcDir / "src.sgd"
    writeSegd(segd, sweep)
    var sd = openSeismic(segd, keys = true)
    let made = correlate(sd, segd, sweep)
    var opened = made.opened.filePtr
    let fromButton = outDir / "button-sd.sgd"
    let fromOption = outDir / "option-sd.sgd"
    let button = runWrite(opened[], segd, fromButton, OutputOptions(format: ofSegd))
    doAssert button.st == jsDone, button.error & " / " & button.wrote.reason
    let opted = runWrite(sd, segd, fromOption, option(sweep, ofSegd))
    doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
    var a = openSeismic(fromOption, keys = true)
    var b = openSeismic(fromButton, keys = true)
    sameWritten(a, b, false)
    a.close()
    b.close()
    opened[].close()
    sd.close()

  block intervalRefuses:
    let dest = outDir / "mismatch.sgy"
    let got = runWrite(file, path, dest, OutputOptions(format: ofSegy,
      correlation: some(OutputCorrelation(reference: sweep, referenceDtMs: 4.0,
        referenceTraces: @[RefAux]))))
    doAssert got.st == jsFailed, "an interval mismatch was written"
    doAssert got.wrote.reason.find(
      "the reference sweep is sampled every 4 ms and the record every 2 ms.") >= 0,
      got.wrote.reason
    noPart(outDir, "mismatch.sgy")

  block shortRecord:
    let short = srcDir / "short.sgy"
    var w = openSeismicWriter(short, SegyOutputOptions())
    var k = initTraceKeys()
    (k.traceCode, k.status, k.record, k.channel) = (1'i16, tsLive, 1.0, 1.0)
    (k.intervalUs, k.t0Ms, k.time) = (DtMs * 1000.0, 0.0, 1_700_000_000.0)
    var buf = newSeq[float32](SweepLen)
    for j in 0 ..< SweepLen: buf[j] = sweep[j]
    w.writeTrace(k, buf)
    doAssert w.close().len == 0
    var sf = openSeismic(short, keys = true)
    let dest = outDir / "short-out.sgy"
    let got = runWrite(sf, short, dest, option(sweep, ofSegy))
    doAssert got.st == jsFailed, "a record no longer than the sweep was written"
    doAssert got.wrote.reason.find(
      "the reference sweep is as long as the record or longer, so there is no listen time.") >= 0,
      got.wrote.reason
    noPart(outDir, "short-out.sgy")
    sf.close()

  block positions:
    ## A joined source X is written when session positions are on, and the
    ## file's own when they are off. Seen to fail: the session keys were left
    ## out, so source X stayed 10.0, not 111.
    let placed = srcDir / "placed.sgy"
    writePlaced(placed, sweep)
    var raw = openSeismic(placed, keys = true)
    doAssert raw.traceKeys(0).srcX == OwnSrcX, "the file did not store source X 10"
    for t in 0 ..< raw.len:
      raw.mindex.keys[t].srcX = JoinedSrcX
      raw.mindex.markJoined(t, {jgSourceXy})
    let made = correlate(raw, placed, sweep)
    var opened = made.opened.filePtr
    let fromButton = outDir / "pos-button.sgy"
    let fromOption = outDir / "pos-option.sgy"
    let fromOwn = outDir / "pos-own.sgy"
    let button = runWrite(opened[], placed, fromButton, OutputOptions(format: ofSegy))
    doAssert button.st == jsDone, button.error & " / " & button.wrote.reason
    let opted = runWrite(raw, placed, fromOption, option(sweep, ofSegy))
    doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
    var kept = option(sweep, ofSegy)
    kept.writeSessionPositions = false
    let own = runWrite(raw, placed, fromOwn, kept)
    doAssert own.st == jsDone, own.error & " / " & own.wrote.reason
    var a = openSeismic(fromOption, keys = true)
    var b = openSeismic(fromButton, keys = true)
    var c = openSeismic(fromOwn, keys = true)
    doAssert a.traceKeys(0).srcX == JoinedSrcX, "joined source X was " & $a.traceKeys(0).srcX
    doAssert b.traceKeys(0).srcX == OwnSrcX, "the button wrote source X " & $b.traceKeys(0).srcX
    doAssert c.traceKeys(0).srcX == OwnSrcX, "own positions wrote source X " & $c.traceKeys(0).srcX
    a.close()
    b.close()
    c.close()
    opened[].close()
    raw.close()

  block integerSource:
    var scaled = newSeq[float32](sweep.len)
    for i, v in sweep: scaled[i] = v * 1000
    let intPath = srcDir / "int16.sgy"
    writeRaw(intPath, scaled, st3)
    var src = openSeismic(intPath, keys = true)
    defer: src.close()
    let plain = outDir / "int16-plain.sgy"
    let twin = outDir / "int16-like.sgy"
    let off = runWrite(src, intPath, plain, OutputOptions(format: ofSegy))
    doAssert off.st == jsDone, off.error
    likeCopy(src, twin)
    doAssert readFile(plain) == readFile(twin), "option off did not keep the int16 bytes"
    let made = correlate(src, intPath, scaled)
    var opened = made.opened.filePtr
    let fromButton = outDir / "int16-button.sgy"
    let fromOption = outDir / "int16-option.sgy"
    let button = runWrite(opened[], intPath, fromButton, OutputOptions(format: ofSegy))
    doAssert button.st == jsDone, button.error & " / " & button.wrote.reason
    let opted = runWrite(src, intPath, fromOption, option(scaled, ofSegy))
    doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
    var a = openSeismic(fromOption, keys = true)
    var b = openSeismic(fromButton, keys = true)
    doAssert a.summary.formatCode == 5, "option format " & $a.summary.formatCode
    sameWritten(a, b, true)
    a.close()
    b.close()
    opened[].close()

  block segdFloat:
    ## An 8036 source written as SEG-D with correlation is IEEE float32, the
    ## same samples as the button, not the source's whole counts.
    let coded = srcDir / "fmt8036.sgd"
    writeSegd(coded, sweep, sd8036)
    var src = openSeismic(coded, keys = true)
    defer: src.close()
    doAssert src.summary.formatCode == 8036, "source format " & $src.summary.formatCode
    let made = correlate(src, coded, sweep)
    var opened = made.opened.filePtr
    defer: opened[].close()
    let fromButton = outDir / "fmt8036-button.sgd"
    let fromOption = outDir / "fmt8036-option.sgd"
    let button = runWrite(opened[], coded, fromButton, OutputOptions(format: ofSegd))
    doAssert button.st == jsDone, button.error & " / " & button.wrote.reason
    let opted = runWrite(src, coded, fromOption, option(sweep, ofSegd))
    doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
    var a = openSeismic(fromOption, keys = true)
    var b = openSeismic(fromButton, keys = true)
    defer:
      a.close()
      b.close()
    doAssert a.summary.formatCode == 8058, "option format " & $a.summary.formatCode
    sameTraces(a, b, Listen)

  block segd8015Listen:
    ## An 8015 source whose listen length is not a multiple of 4 still writes.
    const
      N8015 = 104
      Sweep8015 = 10
    let spec8015 = linearSweep(8.0, 80.0, float64(Sweep8015) * DtMs, DtMs)
    let short = spec8015.sweepSamples(float32)
    doAssert short.len == Sweep8015, "sweep " & $short.len
    doAssert (N8015 - short.len) mod 4 != 0, "listen length is a multiple of 4"
    let coded = srcDir / "fmt8015.sgd"
    writeSegd(coded, short, sd8015, N8015)
    var src = openSeismic(coded, keys = true)
    defer: src.close()
    doAssert src.summary.formatCode == 8015, "source format " & $src.summary.formatCode
    let made = correlate(src, coded, short)
    var opened = made.opened.filePtr
    defer: opened[].close()
    let fromOption = outDir / "fmt8015-option.sgd"
    let opted = runWrite(src, coded, fromOption, option(short, ofSegd))
    doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
    var a = openSeismic(fromOption, keys = true)
    defer: a.close()
    doAssert a.summary.formatCode == 8058, "option format " & $a.summary.formatCode
    doAssert int(a.traceEntry(0).numSamples) == N8015 - Sweep8015

  block oddIntervalSegd:
    ## SEG-D from keys, an auxiliary at 4 ms and the record at 2 ms, writes
    ## and matches the button.
    let mixed = srcDir / "mixed.sgy"
    writeMixed(mixed, sweep)
    var src = openSeismic(mixed, keys = true)
    defer: src.close()
    doAssert src.traceKeys(4).intervalUs == 4000.0, $src.traceKeys(4).intervalUs
    let made = correlate(src, mixed, sweep)
    var opened = made.opened.filePtr
    defer: opened[].close()
    let fromButton = outDir / "mixed-button.sgy"
    let fromOption = outDir / "mixed-option.sgd"
    let button = runWrite(opened[], mixed, fromButton, OutputOptions(format: ofSegy))
    doAssert button.st == jsDone, button.error & " / " & button.wrote.reason
    let opted = runWrite(src, mixed, fromOption, option(sweep, ofSegd))
    doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
    var a = openSeismic(fromOption, keys = true)
    var b = openSeismic(fromButton, keys = true)
    defer:
      a.close()
      b.close()
    sameTraces(a, b, Listen)

  block oddAuxFilter:
    ## Trace 0 is an auxiliary at 4 ms, the seismic traces at 2 ms. An own
    ## filter on a seismic trace matches the button then Output.
    let auxFirst = srcDir / "auxfirst.sgd"
    writeAuxFirst(auxFirst, sweep)
    patchChannelInterval(auxFirst, uint8(ord(sctOther)), 4000)
    var src = openSeismic(auxFirst, keys = true)
    defer: src.close()
    doAssert src.traceKeys(0).status == tsAuxiliary, $src.traceKeys(0).status
    doAssert src.sampleIntervalUs(0) == 4000.0, $src.sampleIntervalUs(0)
    doAssert src.traceKeys(1).intervalUs == 2000.0, $src.traceKeys(1).intervalUs
    doAssert src.traceKeys(RefAux).status == tsAuxiliary
    doAssert src.traceKeys(RefAux).intervalUs == 2000.0, $src.traceKeys(RefAux).intervalUs
    let made = correlate(src, auxFirst, sweep)
    var opened = made.opened.filePtr
    defer: opened[].close()
    doAssert opened[].sampleIntervalUs(0) == 2000.0, $opened[].sampleIntervalUs(0)
    var edits: FileEdits
    let own = bounded(OwnFilter(spec: Processing(band: pbBandPass, f1: 8, f2: 12,
      f3: 40, f4: 50)))
    doAssert edits.setOwnFilters([1], own) == 1
    var optedOpts = option(sweep, ofSegd)
    optedOpts.applyOwnFilters = true
    let fromButton = outDir / "auxfirst-button.sgd"
    let fromOption = outDir / "auxfirst-option.sgd"
    let button = runWrite(opened[], auxFirst, fromButton,
      OutputOptions(format: ofSegd, applyOwnFilters: true), edits)
    doAssert button.st == jsDone, button.error & " / " & button.wrote.reason
    let opted = runWrite(src, auxFirst, fromOption, optedOpts, edits)
    doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
    var a = openSeismic(fromOption, keys = true)
    var b = openSeismic(fromButton, keys = true)
    defer:
      a.close()
      b.close()
    sameTraces(a, b, Listen)
    doAssert samplesOf(a, 1) != samplesOf(opened[], 1), "the own filter changed nothing"

  block correlationNotes:
    ## A reference auxiliary and an auxiliary at another interval: the lines
    ## are the button's, in its order.
    let mixed = srcDir / "notes.sgy"
    writeMixed(mixed, sweep)
    var src = openSeismic(mixed, keys = true)
    defer: src.close()
    let made = correlate(src, mixed, sweep)
    let fromOption = outDir / "notes-option.sgy"
    let opted = runWrite(src, mixed, fromOption, option(sweep, ofSegy))
    doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
    var at = 0
    for line in made.lines:
      var found = false
      while at < opted.wrote.lines.len:
        if opted.wrote.lines[at] == line:
          found = true
          inc at
          break
        inc at
      doAssert found, "missing " & line & " in " & $opted.wrote.lines
    doAssert made.lines.len >= 3, $made.lines
    doAssert "delayed by" in made.lines[1], made.lines[1]
    var oddNote = false
    for line in made.lines:
      if "written as zeros." in line: oddNote = true
    doAssert oddNote, $made.lines

  block unreadTrace:
    ## Trace 4's samples are cut after the file is open. That trace is written
    ## as zeros, and the result says so. Windows will not shrink a mapped file.
    when not defined(windows):
      let cutPath = srcDir / "unread.sgy"
      writeMixed(cutPath, sweep)
      var src = openSeismic(cutPath, keys = true)
      defer: src.close()
      let earlier = src.traceEntry(3)
      let last = src.traceEntry(4)
      let earlierData = earlier.offset + int64(earlier.headerBytes)
      let span = last.offset - earlierData
      doAssert span mod int64(earlier.numSamples) == 0, "samples are not a whole number of bytes"
      let sampleBytes = span div int64(earlier.numSamples)
      let data = last.offset + int64(last.headerBytes)
      let cutAt = data + (int64(last.numSamples) div 2) * sampleBytes
      doAssert cutAt > data and cutAt < getFileSize(cutPath), "the cut is not inside the last trace"
      writeFile(cutPath, readFile(cutPath)[0 ..< int(cutAt)])
      let fromOption = outDir / "unread-option.sgy"
      let opted = runWrite(src, cutPath, fromOption, option(sweep, ofSegy))
      doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
      var said = false
      for line in opted.wrote.lines:
        if "could not be read and" in line and "written as zeros." in line: said = true
      doAssert said, $opted.wrote.lines
      var written = openSeismic(fromOption, keys = true)
      defer: written.close()
      for v in samplesOf(written, 4):
        doAssert v == 0.0, $v

when isMainModule:
  main()
