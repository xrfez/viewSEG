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
## (h) A pilot reference (the auxiliary trace of each record, cut by the project's
## rule) is read from each file written and equals the button's sample for
## sample; two files each use their own pilot; the records of one file each
## use theirs; a file without the auxiliary trace fails with a sentence and
## leaves no file; a stored sweep's bytes are the same as before pilots.
## Seen to fail (h): with every record given the first record's plan, record 2's
## trace 0 differed from its own pilot's output (`record 2 trace 0`).
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
## 800 samples (1600 ms of listen time)." was missing. With the unread trace
## written as zeros, a file cut while it was open was renamed into place: "a
## cut file was written correlated". SEG-D to SEG-D with trace 0 an
## auxiliary at 4 ms kept that interval in the template: "trace 0 interval
## 4000.0". A file cut after its traces were read lost every note: "missing
## 5 traces, 800 samples (1600 ms of listen time). in @[]".
## (h, many records and options) Samples are also compared with a correlation
## computed by its definition. Seen to fail: the model given the first pilot for
## every record (`record 1 trace 0 sample 0 0.0265 vs -0.0438`); the model's
## pilot left unreversed with the reversal option on (`on trace 0 sample 0
## 0.0438 vs -0.0438`).

import std/[hashes, math, options, os, sequtils, strutils]
import parseSEG
import parseSEG/model/traceindex
import processSEG
import viewSEG/core/[correlatejobs, cutfile, edits, filememory, jobs, outputbatch, outputjobs,
  processing, references, session]
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
  LeadMarks = @[AuxMarkEntry(position: 1, marked: true, ms: 500.0)]
    ## the first auxiliary position, shifted 500 ms: what the reference trace of these
    ## files was given before marks
  AuxFirstMarks = @[AuxMarkEntry(position: 2, marked: true, ms: 500.0)]
    ## the reference trace of the file whose trace 0 is an auxiliary of its own
  StoredHash = -8343397523865439994
    ## The bytes of the stored-sweep write: those of before pilots, except the reference
    ## trace's delay field (bytes 109-110 of its header), 0 then and -500 ms now.

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc samplesOf(f: SeismicFile; trace: int): seq[float32] =
  let x = f.readTraces(trace .. trace)
  result.setLen x.shape[1]
  for j in 0 ..< result.len: result[j] = x[0, j]

proc naiveCorrelation(raw, pilot: openArray[float32]; listen: int; before = 0): seq[float32] =
  ## The normalised cross-correlation by its definition, with no FFT: sample m is
  ## sum(raw[m - before + j] * pilot[j]) over the pilot, divided by the pilot's
  ## energy; `before` samples of earlier lags come first.
  var energy = 0.0
  for v in pilot: energy += float64(v) * float64(v)
  result = newSeq[float32](listen)
  for m in 0 ..< listen:
    var acc = 0.0
    for j in 0 ..< pilot.len:
      let at = m - before + j
      if at >= 0 and at < raw.len: acc += float64(raw[at]) * float64(pilot[j])
    result[m] = float32(acc / energy)

proc nearModel(got, model: seq[float32]; what: string) =
  ## Every sample within 1e-3 of the model, which peaks at 1.
  doAssert got.len == model.len, what & " has " & $got.len & " samples, not " & $model.len
  for j in 0 ..< got.len:
    doAssert abs(got[j] - model[j]) < 1e-3, what & " sample " & $j & " " & $got[j] &
      " vs " & $model[j]

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

proc correlate(file: var SeismicFile; path: string; sweep: seq[float32];
    refs = @[RefAux]): CorrelateResult =
  var jobs = initJobs()
  result.opened = nil
  result.lines = @[]
  try:
    let id = jobs.submit(spec(path), correlateWork(CorrelateAsk(
      file: addr file, path: path, reference: sweep, referenceDtMs: DtMs,
      marked: marksOf(refs, 500.0)), addr result))
    doAssert waitUntil(state(jobs, id) in {jsDone, jsFailed, jsCancelled})
    doAssert state(jobs, id) == jsDone, result.failure
  finally:
    jobs.stop()
  doAssert result.ok, result.failure

proc option(sweep: seq[float32]; format: OutputFormat; marks = LeadMarks): OutputOptions =
  OutputOptions(format: format, correlation: some(OutputCorrelation(
    reference: sweep, referenceDtMs: DtMs, projectMarks: marks)))

proc withCorrelation(opts: OutputOptions; sweep: seq[float32]): OutputOptions =
  result = opts
  result.format = ofSegy
  result.correlation = some(OutputCorrelation(reference: sweep, referenceDtMs: DtMs,
    projectMarks: LeadMarks))

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

proc writeRecords(path: string; sweeps: seq[seq[float32]]) =
  ## One record for each of `sweeps`: two live traces that are that record's
  ## sweep, delayed, then its auxiliary trace (the pilot, in trace code 5).
  ## Each record is numbered 7, 8, ...
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, text: @["C01 a pilot of its own in each record"]))
  for r, sweep in sweeps:
    for i in 0 .. 2:
      var k = initTraceKeys()
      let buf = delayedSweep(sweep, Record, if i == 2: 0 else: Delays[i])
      if i == 2: (k.traceCode, k.status) = (5'i16, tsAuxiliary)
      else: (k.traceCode, k.status) = (1'i16, tsLive)
      k.record = float64(7 + r)
      k.channel = float64(i + 1)
      k.intervalUs = DtMs * 1000.0
      k.t0Ms = 0.0
      k.time = 1_700_000_000.0
      w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the records file did not close"

proc pilotOutput(sweep: seq[float32]): OutputOptions =
  ## The rule: the first auxiliary trace, from 0 ms, as long as the sweep.
  OutputOptions(format: ofSegy, correlation: some(OutputCorrelation(
    referenceDtMs: DtMs, projectMarks: LeadMarks, pilot: some(PilotRule(aux: true,
    trace: 1, startMs: 0.0, spanMs: float64(sweep.len) * DtMs)))))

proc buttonPilot(file: var SeismicFile; path: string; rule: PilotRule; trace: int):
    seq[float32] =
  ## The pilot the Correlate button loads for `trace` of `file`.
  var got: seq[float32] = @[]
  let at = addr file
  let work = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      got = loadSweep(at, path, CorrelateLoad(pilotTrace: trace, pilot: rule,
        record: "FFID 7")).samples
  let jobs = initJobs()
  let id = jobs.submit(JobSpec(title: "Load a pilot", lane: jlBackground, reads: @[path]), work)
  doAssert waitUntil(state(jobs, id) in {jsDone, jsFailed, jsCancelled})
  doAssert state(jobs, id) == jsDone, jobs.info(id).get.error
  got

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
        projectMarks: LeadMarks))))
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
    var optedOpts = option(sweep, ofSegd, AuxFirstMarks)
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

  block oddIntervalSegdToSegd:
    ## SEG-D to SEG-D: trace 0 is an auxiliary at 4 ms, the record at 2 ms.
    ## It is written as zeros at 2 ms, so the record length is the listen
    ## time, and the notes say so.
    let auxFirst = srcDir / "oddlike.sgd"
    writeAuxFirst(auxFirst, sweep)
    patchChannelInterval(auxFirst, uint8(ord(sctOther)), 4000)
    var src = openSeismic(auxFirst, keys = true)
    defer: src.close()
    doAssert src.sampleIntervalUs(0) == 4000.0, $src.sampleIntervalUs(0)
    let fromOption = outDir / "oddlike-option.sgd"
    let opted = runWrite(src, auxFirst, fromOption, option(sweep, ofSegd, AuxFirstMarks))
    doAssert opted.st == jsDone, opted.error & " / " & opted.wrote.reason
    var a = openSeismic(fromOption, keys = true)
    defer: a.close()
    doAssert a.sampleIntervalUs(0) == DtMs * 1000.0, "trace 0 interval " &
      $a.sampleIntervalUs(0)
    doAssert int(a.traceEntry(0).numSamples) == Listen, $a.traceEntry(0).numSamples
    for v in samplesOf(a, 0): doAssert v == 0.0, $v
    doAssert a.summary.recordLengthMs == float64(Listen) * DtMs, "record length " &
      $a.summary.recordLengthMs
    var said = false
    for line in opted.wrote.lines:
      if "written as zeros every 2 ms, the output's interval." in line: said = true
    doAssert said, $opted.wrote.lines

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
    ## Trace 4's samples are cut after the file is open. The correlated write
    ## fails in the correlation job's words and leaves no file; so does a
    ## plain write. Windows will not shrink a mapped file.
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
      let opted = runWrite(src, cutPath, outDir / "unread-option.sgy", option(sweep, ofSegy))
      doAssert opted.st == jsFailed, "a cut file was written correlated"
      doAssert opted.wrote.reason.startsWith(cutWords(false) & "."), opted.wrote.reason
      doAssert opted.wrote.removed, opted.wrote.reason
      noPart(outDir, "unread-option.sgy")
      let plain = runWrite(src, cutPath, outDir / "unread-plain.sgy", OutputOptions())
      doAssert plain.st == jsFailed, "a cut file was written"
      doAssert plain.wrote.removed, plain.wrote.reason
      noPart(outDir, "unread-plain.sgy")

  block notesAfterLateCut:
    ## The file is cut after every trace was read: the write is whole, and
    ## the notes that need only the index are the button's, though the
    ## binary header can no longer be read.
    when not defined(windows):
      let latePath = srcDir / "late.sgy"
      writeMixed(latePath, sweep)
      var src = openSeismic(latePath, keys = true)
      defer: src.close()
      let made = correlate(src, latePath, sweep)
      made.opened.filePtr[].close()
      let half = int(getFileSize(latePath) div 2)
      let dest = outDir / "late-option.sgy"
      let at = addr src
      let opts = option(sweep, ofSegy)
      let sink = OutputSink()
      let cutAtEnd = proc (done, total: int): bool {.gcsafe.} =
        if done == total:
          {.cast(gcsafe).}:
            writeFile(latePath, readFile(latePath)[0 ..< half])
            discard at[].cutShort
        true
      let work = proc (ctx: JobContext) {.gcsafe.} =
        {.cast(gcsafe).}:
          writeOutput(ctx, at, latePath, dest, opts, FileEdits(), @[latePath], sink, cutAtEnd)
      let jobs = initJobs()
      let id = jobs.submit(outputSpec(latePath, dest), work)
      doAssert waitUntil(state(jobs, id) in {jsDone, jsFailed, jsCancelled})
      doAssert state(jobs, id) == jsDone, jobs.info(id).get.error & " / " & sink.result.reason
      doAssert src.cutShort, "the file was not cut"
      for line in made.lines:
        if "binary header" notin line:
          doAssert line in sink.result.lines, "missing " & line & " in " & $sink.result.lines

  block pilotReference:
    let other = linearSweep(20.0, 60.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
    doAssert other != sweep, "the two sweeps are the same"
    let aPath = srcDir / "pilot-a.sgy"
    let bPath = srcDir / "pilot-b.sgy"
    writeRecords(aPath, @[sweep])
    writeRecords(bPath, @[other])
    var a = openSeismic(aPath, keys = true)
    var b = openSeismic(bPath, keys = true)
    let opts = pilotOutput(sweep)
    let rule = opts.correlation.get.pilot.get

    block likeButton:
      ## (a) the button's pilot, then the stored-sweep Output, equal this Output.
      let loaded = buttonPilot(a, aPath, rule, 2)
      doAssert loaded == sweep, "the button's pilot is not the sweep"
      let made = correlate(a, aPath, loaded, @[2])
      var opened = made.opened.filePtr
      let fromButton = outDir / "pilot-button.sgy"
      let fromPilot = outDir / "pilot-option.sgy"
      let button = runWrite(opened[], aPath, fromButton, OutputOptions(format: ofSegy))
      doAssert button.st == jsDone, button.error & " / " & button.wrote.reason
      let got = runWrite(a, aPath, fromPilot, opts)
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      var x = openSeismic(fromPilot, keys = true)
      var y = openSeismic(fromButton, keys = true)
      sameTraces(x, y, Listen)
      x.close()
      y.close()
      opened[].close()

    block eachFileItsOwn:
      ## (b) the second file takes its own pilot, not the first file's.
      let outA = outDir / "own-a.sgy"
      let outB = outDir / "own-b.sgy"
      doAssert runWrite(a, aPath, outA, opts).st == jsDone
      doAssert runWrite(b, bPath, outB, opts).st == jsDone
      var viaA = openSeismic(outA, keys = true)
      var viaB = openSeismic(outB, keys = true)
      let storedB = outDir / "own-b-stored.sgy"
      let gotStored = runWrite(b, bPath, storedB, OutputOptions(format: ofSegy,
        correlation: some(OutputCorrelation(reference: other, referenceDtMs: DtMs,
        projectMarks: LeadMarks))))
      doAssert gotStored.st == jsDone, gotStored.error
      var stored = openSeismic(storedB, keys = true)
      sameTraces(viaB, stored, Listen)
      doAssert samplesOf(viaA, 0) != samplesOf(viaB, 0), "both files gave the same trace"
      viaA.close()
      viaB.close()
      stored.close()

    block eachRecordItsOwn:
      ## The records of one file each take their own pilot.
      let twoPath = srcDir / "pilot-two.sgy"
      writeRecords(twoPath, @[sweep, other])
      var two = openSeismic(twoPath, keys = true)
      let outTwo = outDir / "own-two.sgy"
      let got = runWrite(two, twoPath, outTwo, pilotOutput(sweep))
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      var made = openSeismic(outTwo, keys = true)
      var firstOne = openSeismic(outDir / "own-a.sgy", keys = true)
      var secondOne = openSeismic(outDir / "own-b.sgy", keys = true)
      doAssert made.len == 6, "trace count " & $made.len
      for t in 0 .. 2:
        doAssert samplesOf(made, t) == samplesOf(firstOne, t), "record 1 trace " & $t
        doAssert samplesOf(made, 3 + t) == samplesOf(secondOne, t), "record 2 trace " & $t
      made.close()
      firstOne.close()
      secondOne.close()
      two.close()

    block manyRecords:
      ## A file of 300 records, alternating two pilots: every record's traces equal
      ## those of the first record that had its pilot.
      ## Seen to fail: the plan of the wrong record used for a trace (the plan kept
      ## from the first record), so record 2 differed from record 0.
      let manyPath = srcDir / "pilot-many.sgy"
      var many: seq[seq[float32]] = @[]
      for r in 0 ..< 300: many.add (if r mod 2 == 0: sweep else: other)
      writeRecords(manyPath, many)
      var big = openSeismic(manyPath, keys = true)
      let outMany = outDir / "own-many.sgy"
      let got = runWrite(big, manyPath, outMany, pilotOutput(sweep))
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      var made = openSeismic(outMany, keys = true)
      doAssert made.len == 900, "trace count " & $made.len
      doAssert samplesOf(made, 0) != samplesOf(made, 3), "the two pilots gave one trace"
      for r in 2 ..< 300:
        for t in 0 .. 2:
          doAssert samplesOf(made, 3 * r + t) == samplesOf(made, 3 * (r mod 2) + t),
            "record " & $r & " trace " & $t
      # records of both pilots against a correlation computed by its definition
      for r in [0, 1, 2, 3, 150, 297, 298, 299]:
        let pilot = if r mod 2 == 0: sweep else: other
        for t in 0 .. 2:
          let raw = delayedSweep(pilot, Record, if t == 2: 0 else: Delays[t])
          # the reference trace is written 500 ms (250 samples) later: its delay is -500 ms
          let model = naiveCorrelation(raw, pilot, Listen, if t == 2: 250 else: 0)
          nearModel(samplesOf(made, 3 * r + t), model,
            "record " & $r & " trace " & $t)
          doAssert int(made.traceEntry(3 * r + t).numSamples) == Listen
          let fld = made.traceField(3 * r + t, "trace.correlated")
          doAssert fld.kind == fvInt and fld.intVal == CorrelatedYes,
            "record " & $r & " trace " & $t & " correlated " & $fld
      made.close()
      big.close()

    block optionsOfOutput:
      ## The pilot follows Output's options: its reversal is applied only with
      ## "apply reversals", so the sweep is the recorded one with the option off and
      ## the negated one with it on, as the stored-sweep Output of each gives.
      ## Seen to fail: the reversal taken whatever the option, so the option-off
      ## file was the negated sweep's.
      var edits: FileEdits
      doAssert edits.change(teReversed, [2], true) == 1
      var negated = sweep
      for v in negated.mitems: v = -v
      for on in [true, false]:
        var viaPilot = pilotOutput(sweep)
        viaPilot.applyReversals = on
        var viaSweep = option(if on: negated else: sweep, ofSegy)
        viaSweep.applyReversals = on
        viaSweep.correlation.get.projectMarks = LeadMarks
        let name = if on: "on" else: "off"
        let gotPilot = runWrite(a, aPath, outDir / ("opt-pilot-" & name & ".sgy"), viaPilot,
          edits)
        doAssert gotPilot.st == jsDone, gotPilot.error & " / " & gotPilot.wrote.reason
        let gotSweep = runWrite(a, aPath, outDir / ("opt-sweep-" & name & ".sgy"), viaSweep,
          edits)
        doAssert gotSweep.st == jsDone, gotSweep.error & " / " & gotSweep.wrote.reason
        var x = openSeismic(outDir / ("opt-pilot-" & name & ".sgy"), keys = true)
        var y = openSeismic(outDir / ("opt-sweep-" & name & ".sgy"), keys = true)
        sameTraces(x, y, Listen)
        x.close()
        y.close()
      var onFile = openSeismic(outDir / "opt-pilot-on.sgy", keys = true)
      var offFile = openSeismic(outDir / "opt-pilot-off.sgy", keys = true)
      doAssert samplesOf(onFile, 0) != samplesOf(offFile, 0), "the option changed nothing"
      # against the definition: with the option on, trace 2 and the pilot are both
      # reversed (the product is positive), traces 0 and 1 come out negated
      for on in [true, false]:
        var written = openSeismic(outDir / (if on: "opt-pilot-on.sgy" else: "opt-pilot-off.sgy"),
          keys = true)
        for t in 0 .. 2:
          var raw = delayedSweep(sweep, Record, if t == 2: 0 else: Delays[t])
          var pilot = sweep
          if on:
            for v in pilot.mitems: v = -v
            if t == 2:
              for v in raw.mitems: v = -v
          let model = naiveCorrelation(raw, pilot, Listen, if t == 2: 250 else: 0)
          nearModel(samplesOf(written, t), model,
            (if on: "on" else: "off") & " trace " & $t)
          doAssert int(written.traceEntry(t).numSamples) == Listen
        written.close()
      onFile.close()
      offFile.close()

    block missingTrace:
      ## (c) a record without the auxiliary trace fails, in words, and writes nothing.
      let lonePath = srcDir / "pilot-none.sgy"
      var w = openSeismicWriter(lonePath, SegyOutputOptions(traceSorting: 1,
        measurementSystem: 1))
      var k = initTraceKeys()
      (k.traceCode, k.status, k.record, k.channel) = (1'i16, tsLive, 7.0, 1.0)
      (k.intervalUs, k.t0Ms, k.time) = (DtMs * 1000.0, 0.0, 1_700_000_000.0)
      w.writeTrace(k, delayedSweep(sweep, Record, 40))
      doAssert w.close().len == 0
      var lone = openSeismic(lonePath, keys = true)
      let got = runWrite(lone, lonePath, outDir / "pilot-none-out.sgy", opts)
      doAssert got.st == jsFailed, "a file without the pilot was written"
      doAssert got.wrote.reason == "FFID 7 has no auxiliary trace, not an auxiliary trace 1.",
        got.wrote.reason
      noPart(outDir, "pilot-none-out.sgy")
      lone.close()
      # a record of a two-record file without it fails the whole file
      let halfPath = srcDir / "pilot-half.sgy"
      writeRecords(halfPath, @[sweep, other])
      var tail = openSeismic(halfPath, keys = true)
      var strict = pilotOutput(sweep)
      strict.correlation.get.pilot.get.trace = 2
      let bad = runWrite(tail, halfPath, outDir / "pilot-half-out.sgy", strict)
      doAssert bad.st == jsFailed and bad.wrote.reason.endsWith("."), bad.wrote.reason
      noPart(outDir, "pilot-half-out.sgy")
      tail.close()
    a.close()
    b.close()

  block pilotBatch:
    ## The batch loads no sweep: each file's records take their own pilot, and a
    ## file without one fails on its own.
    let from1 = srcDir / "batch"
    createDir(from1)
    let other = linearSweep(20.0, 60.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
    writeRecords(from1 / "a.sgy", @[sweep])
    writeRecords(from1 / "b.sgy", @[other])
    var w = openSeismicWriter(from1 / "c.sgy", SegyOutputOptions(traceSorting: 1))
    var k = initTraceKeys()
    (k.traceCode, k.status, k.record, k.channel) = (1'i16, tsLive, 7.0, 1.0)
    (k.intervalUs, k.t0Ms, k.time) = (DtMs * 1000.0, 0.0, 1_700_000_000.0)
    w.writeTrace(k, delayedSweep(sweep, Record, 40))
    doAssert w.close().len == 0
    let ask = BatchAsk(root: from1, items: @[
      BatchItem(source: from1 / "a.sgy", relative: "a.sgy"),
      BatchItem(source: from1 / "b.sgy", relative: "b.sgy"),
      BatchItem(source: from1 / "c.sgy", relative: "c.sgy")],
      destRoot: outDir / "batch", options: OutputOptions(format: ofSegy),
      correlate: BatchCorrelate(on: true, name: "Pilot", projectMarks: LeadMarks,
      pilot: some(PilotRule(aux: true, trace: 1, startMs: 0.0,
      spanMs: float64(SweepLen) * DtMs))))
    let jobs = initJobs()
    let sink = BatchSink()
    let id = jobs.submit(outputBatchSpec(ask), outputBatchWork(ask, Store(), @[], sink))
    doAssert waitUntil(state(jobs, id) in {jsDone, jsFailed, jsCancelled})
    doAssert state(jobs, id) == jsDone, jobs.info(id).get.error
    let done = sink.result
    doAssert done.written == 2 and done.failed == 1, $done.written & " " & $done.failed
    doAssert done.referenceLoads == 0, "a sweep was loaded"
    for it in done.items:
      if it.relative == "c.sgy":
        doAssert it.outcome == boFailed and it.why.endsWith("."), it.why
    var viaA = openSeismic(outDir / "batch" / "a.sgy", keys = true)
    var viaB = openSeismic(outDir / "batch" / "b.sgy", keys = true)
    var ownA = openSeismic(outDir / "own-a.sgy", keys = true)
    var ownB = openSeismic(outDir / "own-b.sgy", keys = true)
    sameTraces(viaA, ownA, Listen)
    sameTraces(viaB, ownB, Listen)
    for f in [addr viaA, addr viaB, addr ownA, addr ownB]: f[].close()

  proc noted(lines: seq[string]): bool =
    RefDelayScalar in lines or RefDelaySharedSet in lines or RefDelayKeptHeaders in lines

  block referenceDelay:
    ## A correlated file's reference trace is written shifted by the lead, so its
    ## header delay is the source's own less that lead; seismic delays are kept.
    ## Checked by writing the file without the delay (the field set back to the
    ## source's value) and seeing this test fail.
    const Lead = 500.0
    proc delayFile(path: string; sweep: openArray[float32]; segd: bool; refMs, seisMs: float64;
        withOther: bool) =
      var w =
        if segd:
          openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: DtMs * 1000.0,
            numSamples: Record, time: 1_700_000_000.0, format: sd8058))
        else:
          openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
      for i in 0 .. 4:
        if i == 4 and not withOther: break
        var buf: seq[float32]
        var k = initTraceKeys()
        if i < Delays.len:
          buf = delayedSweep(sweep, Record, Delays[i])
          (k.traceCode, k.status) = (1'i16, tsLive)
          k.t0Ms = seisMs
        elif i == RefAux:
          buf = delayedSweep(sweep, Record, 0)
          (k.traceCode, k.status) = (5'i16, tsAuxiliary)
          k.t0Ms = refMs
        else:
          buf = newSeq[float32](Record)
          for j in 0 ..< Record: buf[j] = float32(j + 1)
          (k.traceCode, k.status) = (6'i16, tsAuxiliary)
          k.t0Ms = refMs
        k.record = 7.0
        k.channel = float64(i + 1)
        k.intervalUs = DtMs * 1000.0
        k.time = 1_700_000_000.0
        let ct = if k.status == tsAuxiliary: sctOther else: sctSeismic
        w.writeTrace(k, buf, channelType = ct)
      doAssert w.close().len == 0, "the delay file did not close"
    proc delaysOf(path: string): seq[float64] =
      var f = openSeismic(path, keys = true)
      defer: f.close()
      for t in 0 ..< f.len: result.add f.traceKeys(t).t0Ms

    for (name, segdIn, segdOut) in [("yy", false, false), ("yd", false, true),
        ("dy", true, false)]:
      for refMs in [0.0, 100.0]:
        let src = srcDir / ("delay-" & name & ".src" & (if segdIn: ".sgd" else: ".sgy"))
        delayFile(src, sweep, segdIn, refMs, 10.0, withOther = not segdIn)
        var f = openSeismic(src, keys = true)
        let dest = outDir / ("delay-" & name & $int(refMs) &
          (if segdOut: ".sgd" else: ".sgy"))
        let got = runWrite(f, src, dest, option(sweep, if segdOut: ofSegd else: ofSegy))
        doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
        let d = delaysOf(dest)
        for t in 0 ..< d.len:
          let want =
            if t == RefAux and not (segdOut and not segdIn): refMs - Lead
            elif t == RefAux: refMs # SEG-Y source, SEG-D out: one set holds trace 4 too
            elif t < Delays.len: 10.0
            else: refMs
          doAssert d[t] == want, name & " ref " & $refMs & " trace " & $t & " delay " &
            $d[t] & ", not " & $want
        # The seismic traces' samples and the note.
        doAssert noted(got.wrote.lines) == (segdOut and not segdIn),
          name & " notes: " & $got.wrote.lines
        if segdOut and not segdIn:
          doAssert got.wrote.lines.count(RefDelaySharedSet) == 1 and
            RefDelayKeptHeaders notin got.wrote.lines, "sentence: " & $got.wrote.lines
          doAssert "Headers were built from the trace keys. Template headers were not copied." in
            got.wrote.lines, "keys-path line missing"
        f.close()
    block everyAuxiliaryIsReference:
      ## SEG-Y in, SEG-D out from the keys, the one auxiliary trace a reference: its
      ## delay is the source's less the lead, and nothing is noted.
      let src = srcDir / "delay-one-aux.sgy"
      delayFile(src, sweep, false, 100.0, 10.0, withOther = false)
      var f = openSeismic(src, keys = true)
      defer: f.close()
      let dest = outDir / "delay-one-aux.sgd"
      let got = runWrite(f, src, dest, option(sweep, ofSegd))
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      doAssert not noted(got.wrote.lines), "notes: " & $got.wrote.lines
      let d = delaysOf(dest)
      doAssert d == @[10.0, 10.0, 10.0, 100.0 - Lead], "delays " & $d

    block segdSetsFit:
      ## Only the reference is auxiliary: SEG-D to SEG-D keeps the template and its delay.
      let src = srcDir / "delay-sets.sgd"
      var w = openSeismicWriter(src, SegdOutputOptions(sampleIntervalUs: DtMs * 1000.0,
        numSamples: Record, time: 1_700_000_000.0, format: sd8058))
      for i in 0 .. RefAux:
        var k = initTraceKeys()
        k.record = 7.0
        k.channel = float64(i + 1)
        k.intervalUs = DtMs * 1000.0
        k.time = 1_700_000_000.0
        if i < RefAux:
          (k.traceCode, k.status) = (1'i16, tsLive)
          k.t0Ms = 10.0
          w.writeTrace(k, delayedSweep(sweep, Record, Delays[i]))
        else:
          (k.traceCode, k.status) = (5'i16, tsAuxiliary)
          k.t0Ms = 100.0
          w.writeTrace(k, delayedSweep(sweep, Record, 0), channelType = sctOther)
      doAssert w.close().len == 0, "the SEG-D delay file did not close"
      var f = openSeismic(src, keys = true)
      defer: f.close()
      for format in [ofSegd, ofSegy]:
        let dest = outDir / ("delay-sets" & (if format == ofSegd: ".sgd" else: ".sgy"))
        let got = runWrite(f, src, dest, option(sweep, format))
        doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
        let d = delaysOf(dest)
        if format == ofSegd:
          # Same-format SEG-D keeps the source's own headers, so the delay stays.
          doAssert got.wrote.lines.count(RefDelayKeptHeaders) == 1 and
            RefDelayScalar notin got.wrote.lines and RefDelaySharedSet notin got.wrote.lines,
            "no note: " & $got.wrote.lines
          doAssert "Headers were built from the trace keys. Template headers were not copied." notin
            got.wrote.lines, "the template path was left: " & $got.wrote.lines
          doAssert d == @[10.0, 10.0, 10.0, 100.0], "SEG-D delays " & $d
        else:
          doAssert not noted(got.wrote.lines), "notes: " & $got.wrote.lines
          doAssert d == @[10.0, 10.0, 10.0, 100.0 - Lead], "SEG-Y delays " & $d

  block referenceDelayScalar:
    ## A SEG-Y reference trace's delay is stored in the trace's own time scalar, and
    ## a Rev 0 file has none: bytes 215-216 hold whatever they held, and the library
    ## does not read them. Seen to fail: with the scalar read on a Rev 0 file whose
    ## reference trace had -10 there, the delay was stored as -5000, not -500.
    proc scalarFile(path: string; rev: SegyRevision; scalar: int16; lagA: int16 = 0) =
      var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
        measurementSystem: 1, revision: rev))
      for i in 0 .. RefAux:
        var k = initTraceKeys()
        var buf: seq[float32]
        if i < RefAux:
          buf = delayedSweep(sweep, Record, Delays[i])
          (k.traceCode, k.status) = (1'i16, tsLive)
        else:
          buf = delayedSweep(sweep, Record, 0)
          (k.traceCode, k.status) = (5'i16, tsAuxiliary)
        k.record = 7.0
        k.channel = float64(i + 1)
        k.intervalUs = DtMs * 1000.0
        k.t0Ms = 0.0
        k.time = 1_700_000_000.0
        w.writeTrace(k, buf)
      doAssert w.close().len == 0, "the scalar file did not close"
      var f = openSeismic(path)
      let base = int(f.traceEntry(RefAux).offset)
      f.close()
      var bytes = readFile(path)
      for (at, v) in [(base + 214, scalar), (base + 104, lagA)]: # bytes 215 and 105
        bytes[at] = char((uint16(v) shr 8) and 0xFF)
        bytes[at + 1] = char(uint16(v) and 0xFF)
      writeFile(path, bytes)
    proc peakTime(f: SeismicFile; t: int): float64 =
      let x = samplesOf(f, t)
      var best = 0
      for j in 0 ..< x.len:
        if abs(x[j]) > abs(x[best]): best = j
      f.traceKeys(t).t0Ms + float64(best) * DtMs

    block scalarKept:
      ## Scalar -10 stores -500 ms as -5000; the scalar and the other scaled time
      ## fields (lag A, 70 here) are untouched. Seen to fail: with the delay written
      ## through scalar 0 the stored bytes were -500 and the output read t0 -50.
      let src = srcDir / "scalar-m10.sgy"
      scalarFile(src, SegyRevision(major: 2, minor: 1), -10, 70)
      var f = openSeismic(src, keys = true)
      let dest = outDir / "scalar-m10.sgy"
      let got = runWrite(f, src, dest, option(sweep, ofSegy))
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      f.close()
      doAssert not noted(got.wrote.lines), "notes: " & $got.wrote.lines
      var o = openSeismic(dest, keys = true)
      defer: o.close()
      proc field(name: string): int64 =
        let v = o.findTraceField(RefAux, name)
        if v.isSome: v.get.intVal else: -999999
      doAssert field("trace.delayRecordingTime") == -5000, "stored " &
        $field("trace.delayRecordingTime")
      doAssert field("trace.timeScalar") == -10 and field("trace.lagTimeA") == 70,
        "scalar " & $field("trace.timeScalar") & " lag A " & $field("trace.lagTimeA")
      doAssert o.traceKeys(RefAux).t0Ms == -500.0, "t0 " & $o.traceKeys(RefAux).t0Ms

    block delayNotRead:
      ## No fixture gives a NaN delay (it takes a header layout that moves the field), so
      ## the helper is tried on its own: a NaN delay adds no override, a read one does.
      ## Seen to fail: with the NaN branch removed the helper answered dwScalar, not dwUnread.
      let src = srcDir / "scalar-nan.sgy"
      scalarFile(src, SegyRevision(major: 2, minor: 1), 0)
      var f = openSeismic(src, keys = true)
      defer: f.close()
      var over: seq[HeaderOverride] = @[]
      doAssert referenceDelay(f, RefAux, NaN, 500.0, over) == dwUnread and over.len == 0,
        "an unread delay was written"
      doAssert referenceDelay(f, RefAux, 0.0, 500.0, over) == dwAdded and over.len == 1
      doAssert RefDelayUnread.endsWith(".") and RefDelayUnread.count('.') == 1

    block scalarTooCoarse:
      ## Scalar -1000 stores a delay in 1/1000 ms: -500 ms would be -500000, past 16 bits.
      let src = srcDir / "scalar-m1000.sgy"
      scalarFile(src, SegyRevision(major: 2, minor: 1), -1000)
      var f = openSeismic(src, keys = true)
      let dest = outDir / "scalar-m1000.sgy"
      let got = runWrite(f, src, dest, option(sweep, ofSegy))
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      f.close()
      doAssert got.wrote.lines.count(RefDelayScalar) == 1 and
        RefDelaySharedSet notin got.wrote.lines and RefDelayKeptHeaders notin got.wrote.lines,
        "notes: " & $got.wrote.lines
      var o = openSeismic(dest, keys = true)
      defer: o.close()
      doAssert o.traceKeys(RefAux).t0Ms == 0.0, "t0 " & $o.traceKeys(RefAux).t0Ms

    block rev0Junk:
      let src = srcDir / "scalar-rev0.sgy"
      scalarFile(src, SegyRevision(major: 0), -10)
      var f = openSeismic(src, keys = true)
      let dest = outDir / "scalar-rev0.sgy"
      let got = runWrite(f, src, dest, option(sweep, ofSegy))
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      f.close()
      var o = openSeismic(dest, keys = true)
      defer: o.close()
      doAssert o.traceKeys(RefAux).t0Ms == -500.0, "t0 " & $o.traceKeys(RefAux).t0Ms
      let raw = o.findTraceField(RefAux, "trace.delayRecordingTime")
      doAssert raw.isSome and raw.get.intVal == -500, "stored " & $raw
      doAssert peakTime(o, RefAux) == 0.0, "peak at " & $peakTime(o, RefAux)

  block storedBytesUnchanged:
    ## (d) The stored-sweep Output is as it was before pilots existed.
    let dest = outDir / "stored-hash.sgy"
    let got = runWrite(file, path, dest, option(sweep, ofSegy))
    doAssert got.st == jsDone, got.error
    doAssert hash(readFile(dest)) == StoredHash, "stored-sweep bytes changed: " &
      $hash(readFile(dest))

when isMainModule:
  main()
