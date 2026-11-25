## The correlated Output correlates a block of traces in one pooled call. What
## it writes is what the one-trace call wrote, byte for byte.
##
## Each case is written twice from the same inputs, once with the pooled
## block call and once with `correlateInBlocks` off (one trace per call), and
## the two files, and the lines of their results, must be equal. The cases:
## SEG-Y to SEG-Y, SEG-D to SEG-D and SEG-D to SEG-Y; a stored sweep and a pilot
## in each record; dead traces, a marked auxiliary trace (shifted by its mark),
## an unmarked auxiliary trace, a reversed polarity, a time shift and an own
## filter; counts that are not a multiple of the block, exactly one block, one
## trace and one trace to a record.
##
## A cancel asked between blocks removes the part file; a file cut after it was
## opened fails that file only, and the next file is written.
##
## Seen to fail: block row `i` read at row `i + 1` of the source block (every
## trace differed); a dead row given the live status of its neighbour (a dead
## trace written as a correlation, not zeros).

import std/[os, options, strutils]
import parseSEG
import processSEG
import viewSEG/core/[edits, jobs, outputbatch, outputjobs, processing, references]
import utils/waiting

const
  DtMs = 2.0
  Record = 600
  SweepLen = 100
  Delays = [20, 50, 90]

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc delayedSweep(sweep: openArray[float32]; samples, delay: int): seq[float32] =
  result = newSeq[float32](samples)
  for i in 0 ..< samples:
    let j = i - delay
    if j >= 0 and j < sweep.len: result[i] = sweep[j]

type Layout = object
  records, live: int ## per record: live traces, then one dead, one pilot, one other auxiliary
  dead, aux: bool

proc traceCount(l: Layout): int = l.records * (l.live + ord(l.dead) + 2 * ord(l.aux))

proc writeSet(path: string; segd: bool; sweeps: seq[seq[float32]]; l: Layout) =
  ## One record for each of `sweeps`. Traces get their own noise-free content: a
  ## delayed sweep, scaled by its index, so every row of a block differs.
  let total = l.traceCount
  var wSegy: SeismicWriter
  if segd:
    wSegy = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: DtMs * 1000.0,
      numSamples: Record, time: 1_700_000_000.0))
  else:
    wSegy = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
      measurementSystem: 1, text: @["C01 correlated in blocks"]))
  var n = 0
  for r in 0 ..< l.records:
    let sweep = sweeps[r mod sweeps.len]
    var plan: seq[tuple[kind: char; at: int]] = @[]
    for i in 0 ..< l.live: plan.add (kind: 'L', at: i)
    if l.dead: plan.insert((kind: 'D', at: 0), min(1, plan.len))
    if l.aux:
      plan.add (kind: 'P', at: 0)
      plan.add (kind: 'O', at: 0)
    for (kind, at) in plan:
      var k = initTraceKeys()
      var buf: seq[float32]
      case kind
      of 'L':
        buf = delayedSweep(sweep, Record, Delays[at mod 3] + at)
        for v in buf.mitems: v *= 1.0'f32 + 0.01'f32 * float32(n mod 17)
        (k.traceCode, k.status) = (1'i16, tsLive)
      of 'D':
        buf = delayedSweep(sweep, Record, 0)
        buf[0] = 1
        (k.traceCode, k.status) = (2'i16, tsDead)
      of 'P':
        buf = delayedSweep(sweep, Record, 0)
        (k.traceCode, k.status) = (5'i16, tsAuxiliary)
      else:
        buf = newSeq[float32](Record)
        for j in 0 ..< Record: buf[j] = float32(j + 1)
        (k.traceCode, k.status) = (6'i16, tsAuxiliary)
      k.record = float64(7 + r)
      k.channel = float64(n + 1)
      k.intervalUs = DtMs * 1000.0
      k.t0Ms = 0.0
      k.time = 1_700_000_000.0
      if segd:
        wSegy.writeTrace(k, buf,
          channelType = if k.status == tsAuxiliary: sctOther else: sctSeismic)
      else: wSegy.writeTrace(k, buf)
      inc n
  doAssert n == total
  doAssert wSegy.close().len == 0, "the file did not close"

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

proc editsFor(total: int): FileEdits =
  ## A reversal, a time shift and an own filter, each on traces spread over blocks.
  var reversed, shifted, filtered: seq[int] = @[]
  for t in 0 ..< total:
    if t mod 5 == 2: reversed.add t
    if t mod 7 == 3: shifted.add t
    if t mod 11 == 4: filtered.add t
  doAssert result.change(teReversed, reversed, true) == reversed.len
  doAssert result.setTimeShifts(shifted, 8.0, DtMs) == shifted.len
  let own = bounded(OwnFilter(spec: Processing(band: pbBandPass, f1: 8, f2: 12,
    f3: 40, f4: 50)))
  doAssert result.setOwnFilters(filtered, own) == filtered.len

proc sameBytes(file: var SeismicFile; source, dir, name: string; opts: OutputOptions;
    edits: FileEdits) =
  ## The pooled and the one-row writes, compared.
  let old = dir / (name & "-old.out")
  let batched = dir / (name & "-new.out")
  correlateInBlocks = false
  let a = runWrite(file, source, old, opts, edits)
  correlateInBlocks = true
  let b = runWrite(file, source, batched, opts, edits)
  doAssert a.st == jsDone, name & ": " & a.error & " / " & a.wrote.reason
  doAssert b.st == jsDone, name & ": " & b.error & " / " & b.wrote.reason
  let x = readFile(old)
  let y = readFile(batched)
  doAssert x.len > 0, name & " wrote nothing"
  doAssert x.len == y.len, name & ": " & $x.len & " bytes vs " & $y.len
  for i in 0 ..< x.len:
    doAssert x[i] == y[i], name & ": byte " & $i & " differs"
  doAssert a.wrote.lines == b.wrote.lines, name & ": result lines differ"
  doAssert a.wrote.written == b.wrote.written, name & ": written differs"

proc noPart(dir, stem: string) =
  doAssert not fileExists(dir / stem), stem & " was written"
  for kind, p in walkDir(dir):
    doAssert not extractFilename(p).startsWith(stem & ".part"),
      "a partial file was left: " & extractFilename(p)

proc main*() =
  let dir = getTempDir() / ("toutputcorrblock-" & $getCurrentProcessId())
  let srcDir = dir / "src"
  let outDir = dir / "out"
  createDir(srcDir)
  createDir(outDir)
  defer: removeDir(dir)
  let sweep = linearSweep(8.0, 80.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
  let other = linearSweep(20.0, 60.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
  let marks = @[AuxMarkEntry(position: 1, marked: true, ms: 500.0)]
  let stored = OutputCorrelation(reference: sweep, referenceDtMs: DtMs, projectMarks: marks)
  let pilot = OutputCorrelation(referenceDtMs: DtMs, projectMarks: marks,
    pilot: some(PilotRule(aux: true, trace: 1, startMs: 0.0,
    spanMs: float64(SweepLen) * DtMs)))
  var flags = OutputOptions(applyReversals: true, applyShifts: true, applyOwnFilters: true)
  defer: correlateInBlocks = true

  type Case = tuple[name: string; segdIn: bool; format: OutputFormat; pilot: bool;
    layout: Layout; edited: bool]
  let cases: seq[Case] = @[
    ("segy-segy-stored", false, ofSegy, false,
      Layout(records: 1, live: 126, dead: true, aux: true), true),
    ("segy-segy-pilot", false, ofSegy, true,
      Layout(records: 7, live: 20, dead: true, aux: true), true),
    ("segd-segd-stored", true, ofSegd, false,
      Layout(records: 1, live: 126, dead: true, aux: true), true),
    ("segd-segy-stored", true, ofSegy, false,
      Layout(records: 1, live: 61, dead: true, aux: true), true),
    ("one-block", false, ofSegy, false,
      Layout(records: 1, live: 61, dead: true, aux: true), false),
    ("one-trace-records", false, ofSegy, false,
      Layout(records: 70, live: 1, dead: false, aux: false), false),
    ("one-trace", false, ofSegy, false,
      Layout(records: 1, live: 1, dead: false, aux: false), false),
    ("pilot-one-per-record", false, ofSegy, true,
      Layout(records: 70, live: 1, dead: false, aux: true), false)]
  for c in cases:
    let path = srcDir / (c.name & (if c.segdIn: ".sgd" else: ".sgy"))
    writeSet(path, c.segdIn, @[sweep, other], c.layout)
    var file = openSeismic(path, keys = true)
    var opts = if c.edited: flags else: OutputOptions()
    opts.format = c.format
    opts.correlation = some(if c.pilot: pilot else: stored)
    sameBytes(file, path, outDir, c.name, opts,
      if c.edited: editsFor(c.layout.traceCount) else: FileEdits())
    file.close()

  block cancelBetweenBlocks:
    ## The progress report says no after the first block: the part file goes.
    let path = srcDir / "cancel.sgy"
    writeSet(path, false, @[sweep], Layout(records: 1, live: 150, dead: false, aux: true))
    var file = openSeismic(path, keys = true)
    defer: file.close()
    let dest = outDir / "cancel.out"
    var opts = OutputOptions(format: ofSegy, correlation: some(stored))
    let at = addr file
    let sink = OutputSink()
    var calls = 0
    let report = proc (done, total: int): bool {.gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
        calls < 2
    let work = proc (ctx: JobContext) {.gcsafe.} =
      {.cast(gcsafe).}:
        writeOutput(ctx, at, path, dest, opts, FileEdits(), @[path], sink, report)
    let jobs = initJobs()
    let id = jobs.submit(outputSpec(path, dest), work)
    doAssert waitUntil(state(jobs, id) in {jsDone, jsFailed, jsCancelled})
    doAssert state(jobs, id) == jsCancelled, "state " & $state(jobs, id)
    doAssert calls == 2, "the report was called " & $calls & " times"
    noPart(outDir, "cancel.out")

  block cutFileFailsThatFileOnly:
    ## A file cut after it was opened fails with no file left; the next file is fine.
    when not defined(windows):
      let cutPath = srcDir / "cut.sgy"
      writeSet(cutPath, false, @[sweep], Layout(records: 1, live: 150, dead: false, aux: true))
      var cut = openSeismic(cutPath, keys = true)
      defer: cut.close()
      let mid = cut.traceEntry(30)
      writeFile(cutPath, readFile(cutPath)[0 ..< int(mid.offset) + 100])
      let opts = OutputOptions(format: ofSegy, correlation: some(stored))
      let failed = runWrite(cut, cutPath, outDir / "cut.out", opts)
      doAssert failed.st == jsFailed, "a cut file was written correlated"
      doAssert failed.wrote.removed, failed.wrote.reason
      noPart(outDir, "cut.out")
      let goodPath = srcDir / "good.sgy"
      writeSet(goodPath, false, @[sweep], Layout(records: 1, live: 70, dead: false, aux: true))
      var good = openSeismic(goodPath, keys = true)
      defer: good.close()
      let fine = runWrite(good, goodPath, outDir / "good.out", opts)
      doAssert fine.st == jsDone, fine.error & " / " & fine.wrote.reason
  echo "toutputcorrblock: ok"

when isMainModule: main()
