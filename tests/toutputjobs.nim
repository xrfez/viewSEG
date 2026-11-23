## A background job writes one open seismic file as SEG-Y or SEG-D, with the
## edits asked for, and never the source. No option: samples and key headers
## match. Each option changes only what it names. A path that exists, or that
## sits in an open file's folder, is refused. A cancel and a write that the
## drive refuses leave no file.
##
## Seen to fail: with `dropKilled` ignored, the killed-trace counts failed
## (`written == n - 1`); with a reversal left unapplied, "a reversed trace
## was not negated".
##
## Runs on samples/land/shots.sgy and samples/land/shots.sgd.

import std/[math, os, sequtils, strutils]
import parseSEG
import processSEG/pipeline
import processSEG/core/[basic, rows, types, workspace]
import viewSEG/core/[edits, jobs, outputjobs, panels, processing, sorting]
import utils/[faultyfs, waiting]

const root = currentSourcePath().parentDir.parentDir

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc runJob(file: var SeismicFile; source, dest: string; opts: OutputOptions;
    edits: FileEdits; opens: seq[string]): tuple[st: JobState; wrote: OutputResult; error: string] =
  let jobs = initJobs()
  let sink = OutputSink()
  let id = jobs.submit(outputSpec(source, dest),
    outputWork(addr file, source, dest, opts, edits, opens, sink))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the write did not finish: " & $jobs.state(id)
  let info = jobs.info(id).get
  (info.state, sink.result, info.error)

proc samplesOf(f: SeismicFile; trace: int): seq[float32] =
  let x = f.readTraces(trace .. trace)
  result.setLen x.shape[1]
  for j in 0 ..< result.len: result[j] = x[0, j]

proc sameNum(a, b: float64): bool =
  if a.isNaN: b.isNaN else: a == b

proc sameKeys(a, b: TraceKeys): bool =
  sameNum(a.record, b.record) and sameNum(a.channel, b.channel) and
    sameNum(a.srcLine, b.srcLine) and sameNum(a.srcPoint, b.srcPoint) and
    sameNum(a.rcvLine, b.rcvLine) and sameNum(a.rcvPoint, b.rcvPoint) and
    a.component == b.component and sameNum(a.inline, b.inline) and
    sameNum(a.crossline, b.crossline) and sameNum(a.intervalUs, b.intervalUs) and
    a.status == b.status

proc keyText(k: TraceKeys): string =
  "record " & $k.record & " channel " & $k.channel & " status " & $k.status

proc filtered(samples: seq[float32]; dtMs: float64; pipe: Pipeline): seq[float32] =
  ## `samples` through `pipe`, as the plot runs a filter, with no gain.
  result = samples
  if pipe.len == 0 or result.len == 0 or not (dtMs > 0): return
  var keys = @[initTraceKeys()]
  keys[0].status = tsLive
  let rows = rowsOf(keys, @[result.len])
  let plan = pipe.compile(float32, dtMs, result.len, recordSamples = result.len)
  var ws = initWorkspace()
  ws.reserve(plan)
  plan.apply(rowBlock(result, 1, result.len), initChunkMeta(rows, dtMs), ws)

proc sortedTraces(file: SeismicFile; traces: seq[int]; keys: openArray[SortKey]): seq[int] =
  if traces.len < 2: return traces
  var perm: seq[int] = @[]
  let rows = file.rowsOf(traces)
  doAssert sortRowsInto(rows, keys, perm)
  result.setLen traces.len
  for i, row in perm: result[i] = traces[row]

proc recordsOf(file: SeismicFile): seq[seq[int]] =
  var rec = -1
  for i in 0 ..< file.len:
    let r = if file.kind == skSegd: int(file.traceEntry(i).record) else: 0
    if result.len == 0 or r != rec:
      result.add @[]
      rec = r
    result[^1].add i

proc main*() =
  install()
  let
    land = root / "samples" / "land"
    segy = land / "shots.sgy"
    segd = land / "shots.sgd"
  doAssert fileExists(segy) and fileExists(segd), "samples/land shots are not here"
  let dir = getTempDir() / ("viewseg-output-" & $getCurrentProcessId())
  createDir(dir)
  var srcBytes = readFile(segy)
  var sgdBytes = readFile(segd)

  block noOptions:
    for (path, kind, name) in [(segy, ofSegy, "shots.sgy"), (segd, ofSegd, "shots.sgd")]:
      var src = openSeismic(path, keys = true)
      let dest = dir / ("plain-" & name)
      let got = runJob(src, path, dest, OutputOptions(format: kind), FileEdits(), @[path])
      doAssert got.st == jsDone, name & " " & got.error & " / " & got.wrote.reason
      doAssert got.wrote.ok and got.wrote.written == src.len and got.wrote.dropped == 0
      var back = openSeismic(dest, keys = true)
      doAssert back.len == src.len, name & " wrote " & $back.len
      for i in 0 ..< src.len:
        doAssert samplesOf(back, i) == samplesOf(src, i), name & " trace " & $i & " samples"
        doAssert sameKeys(back.traceKeys(i), src.traceKeys(i)),
          name & " trace " & $i & " keys " & keyText(back.traceKeys(i)) & " vs " &
          keyText(src.traceKeys(i))
      back.close()
      src.close()
      removeFile(dest)

  block eachOption:
    var src = openSeismic(segy, keys = true)
    let n = src.len
    let dt = src.sampleIntervalUs(0) / 1000.0
    block reversed:
      var edits: FileEdits
      doAssert edits.change(teReversed, [3], true) == 1
      let dest = dir / "reversed.sgy"
      let got = runJob(src, segy, dest, OutputOptions(format: ofSegy, applyReversals: true),
        edits, @[segy])
      doAssert got.st == jsDone, got.error
      var back = openSeismic(dest, keys = true)
      var expect = samplesOf(src, 3)
      reversePolarity(expect)
      doAssert samplesOf(back, 3) == expect, "a reversed trace was not negated"
      doAssert samplesOf(back, 2) == samplesOf(src, 2), "a neighbour was reversed"
      back.close()
      removeFile(dest)
    block killed:
      var edits: FileEdits
      doAssert edits.change(teKilled, [5], true) == 1
      let dest = dir / "killed.sgy"
      let got = runJob(src, segy, dest, OutputOptions(format: ofSegy, dropKilled: true),
        edits, @[segy])
      doAssert got.st == jsDone, got.error
      doAssert got.wrote.written == n - 1 and got.wrote.dropped == 1
      var back = openSeismic(dest, keys = true)
      doAssert back.len == n - 1
      doAssert samplesOf(back, 4) == samplesOf(src, 4)
      doAssert samplesOf(back, 5) == samplesOf(src, 6), "a killed trace was written"
      back.close()
      removeFile(dest)
    block ownFilter:
      var edits: FileEdits
      let own = bounded(OwnFilter(spec: Processing(band: pbBandPass, f1: 8, f2: 12, f3: 40,
        f4: 50)))
      doAssert edits.setOwnFilters([2], own) == 1
      let dest = dir / "own.sgy"
      let got = runJob(src, segy, dest,
        OutputOptions(format: ofSegy, applyOwnFilters: true), edits, @[segy])
      doAssert got.st == jsDone, got.error
      var back = openSeismic(dest, keys = true)
      let expect = filtered(samplesOf(src, 2), dt, own.ownPipeline(dt))
      doAssert samplesOf(back, 2) == expect, "the own filter is not the plot path"
      doAssert samplesOf(back, 1) == samplesOf(src, 1), "a neighbour was filtered"
      back.close()
      removeFile(dest)
    block plotFilter:
      let plot = bounded(Processing(band: pbHighCut, f3: 40, f4: 50))
      let dest = dir / "plot.sgy"
      let got = runJob(src, segy, dest,
        OutputOptions(format: ofSegy, applyProcessing: true, processing: plot), FileEdits(),
        @[segy])
      doAssert got.st == jsDone, got.error
      var back = openSeismic(dest, keys = true)
      let expect = filtered(samplesOf(src, 1), dt, plot.filterPipeline(dt))
      doAssert samplesOf(back, 1) == expect, "the plot filter is not the plot path"
      doAssert samplesOf(back, 1) != samplesOf(src, 1), "the plot filter changed nothing"
      back.close()
      removeFile(dest)
    block sorted:
      let keys = @[SortKey(field: hfChannel, descending: true)]
      let dest = dir / "sorted.sgy"
      let got = runJob(src, segy, dest, OutputOptions(format: ofSegy, sortKeys: keys),
        FileEdits(), @[segy])
      doAssert got.st == jsDone, got.error
      var back = openSeismic(dest, keys = true)
      let want = sortedTraces(src, toSeq(0 ..< n), keys)
      doAssert back.len == n
      for i, t in want:
        doAssert sameKeys(back.traceKeys(i), src.traceKeys(t)),
          "sort place " & $i & " is not trace " & $t
      back.close()
      removeFile(dest)
    src.close()

  block segdSortStaysInRecords:
    var src = openSeismic(segd, keys = true)
    let keys = @[SortKey(field: hfChannel, descending: true)]
    let dest = dir / "sorted.sgd"
    let got = runJob(src, segd, dest, OutputOptions(format: ofSegd, sortKeys: keys),
      FileEdits(), @[segd])
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    var said = false
    for line in got.wrote.lines:
      if "within each record" in line: said = true
    doAssert said, "a sort that crosses records was not said: " & got.wrote.lines.join("; ")
    var back = openSeismic(dest, keys = true)
    var at = 0
    for g in recordsOf(src):
      let want = sortedTraces(src, g, keys)
      for t in want:
        doAssert sameNum(back.traceKeys(at).channel, src.traceKeys(t).channel),
          "SEG-D sort place " & $at
        inc at
    back.close()
    src.close()
    removeFile(dest)

  block segdOptions:
    var src = openSeismic(segd, keys = true)
    let n = src.len
    let dt = src.sampleIntervalUs(0) / 1000.0
    block reversed:
      var edits: FileEdits
      doAssert edits.change(teReversed, [3], true) == 1
      let dest = dir / "rev.sgd"
      let got = runJob(src, segd, dest, OutputOptions(format: ofSegd, applyReversals: true),
        edits, @[segd])
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      var back = openSeismic(dest, keys = true)
      var expect = samplesOf(src, 3)
      reversePolarity(expect)
      doAssert samplesOf(back, 3) == expect, "a SEG-D reversed trace was not negated"
      doAssert samplesOf(back, 2) == samplesOf(src, 2)
      back.close()
      removeFile(dest)
    block killed:
      var edits: FileEdits
      doAssert edits.change(teKilled, [5], true) == 1
      let dest = dir / "kill.sgd"
      let got = runJob(src, segd, dest, OutputOptions(format: ofSegd, dropKilled: true),
        edits, @[segd])
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      doAssert got.wrote.written == n - 1 and got.wrote.dropped == 1
      var back = openSeismic(dest, keys = true)
      doAssert back.len == n - 1
      doAssert samplesOf(back, 4) == samplesOf(src, 4)
      doAssert samplesOf(back, 5) == samplesOf(src, 6), "a killed SEG-D trace was written"
      back.close()
      removeFile(dest)
    block ownFilter:
      var edits: FileEdits
      let own = bounded(OwnFilter(spec: Processing(band: pbBandPass, f1: 8, f2: 12, f3: 40,
        f4: 50)))
      doAssert edits.setOwnFilters([2], own) == 1
      let dest = dir / "own.sgd"
      let got = runJob(src, segd, dest, OutputOptions(format: ofSegd, applyOwnFilters: true),
        edits, @[segd])
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      var back = openSeismic(dest, keys = true)
      doAssert samplesOf(back, 2) == filtered(samplesOf(src, 2), dt, own.ownPipeline(dt))
      doAssert samplesOf(back, 1) == samplesOf(src, 1)
      back.close()
      removeFile(dest)
    src.close()

  block acrossFormats:
    var src = openSeismic(segy, keys = true)
    createDir(dir / "a")
    createDir(dir / "b")
    let mid = dir / "a" / "across.sgd"
    let back = dir / "b" / "across.sgy"
    let toSegd = runJob(src, segy, mid, OutputOptions(format: ofSegd), FileEdits(), @[segy])
    doAssert toSegd.st == jsDone, toSegd.error & " / " & toSegd.wrote.reason
    var midFile = openSeismic(mid, keys = true)
    let toSegy = runJob(midFile, mid, back, OutputOptions(format: ofSegy), FileEdits(), @[mid])
    doAssert toSegy.st == jsDone, toSegy.error & " / " & toSegy.wrote.reason
    var round = openSeismic(back, keys = true)
    doAssert round.len == src.len
    for i in 0 ..< src.len:
      doAssert samplesOf(round, i) == samplesOf(src, i), "SEG-Y to SEG-D and back, trace " & $i
    round.close()
    midFile.close()
    src.close()
    removeFile(mid)
    removeFile(back)

  block refused:
    var src = openSeismic(segy, keys = true)
    let marker = dir / "exists.sgy"
    writeFile(marker, "hello")
    let got = runJob(src, segy, marker, OutputOptions(format: ofSegy), FileEdits(), @[segy])
    doAssert got.st == jsFailed, "an existing file was overwritten"
    doAssert "already exists" in got.wrote.reason
    doAssert readFile(marker) == "hello"
    doAssert readFile(segy) == srcBytes
    let inside = land / "refused-output.sgy"
    let folder = runJob(src, segy, inside, OutputOptions(format: ofSegy), FileEdits(), @[segy])
    doAssert folder.st == jsFailed, "a file in the source folder was written"
    doAssert not fileExists(inside), inside
    doAssert "folder" in folder.wrote.reason
    doAssert readFile(segy) == srcBytes
    src.close()
    removeFile(marker)

  block cancelRemovesTheFile:
    var src = openSeismic(segy, keys = true)
    let dest = dir / "cancelled.sgy"
    fault(segy, fkHang, {foMapped})
    let jobs = initJobs()
    let sink = OutputSink()
    let id = jobs.submit(outputSpec(segy, dest),
      outputWork(addr src, segy, dest, OutputOptions(format: ofSegy), FileEdits(), @[segy], sink))
    doAssert waitUntil(hung() > 0), "the write did not reach the file"
    doAssert jobs.cancel(id)
    release(segy)
    doAssert waitUntil(jobs.state(id) == jsCancelled), "cancel did not stop the write: " &
      $jobs.state(id) & " " & sink.result.reason
    doAssert not fileExists(dest), "a cancelled write left a file"
    doAssert "removed" in sink.result.reason
    src.close()

  block writeFailure:
    var src = openSeismic(segy, keys = true)
    let dest = dir / "failed.sgy"
    fault(dest, fkFail, {foWrite})
    let got = runJob(src, segy, dest, OutputOptions(format: ofSegy), FileEdits(), @[segy])
    doAssert got.st == jsFailed, "a refused write was said done"
    doAssert got.wrote.reason.len > 0, "a refused write gave no reason"
    doAssert not fileExists(dest)
    doAssert readFile(segy) == srcBytes
    release(dest)
    src.close()

  doAssert readFile(segy) == srcBytes and readFile(segd) == sgdBytes
  removeDir(dir)
  echo "toutputjobs: ok"

when isMainModule:
  main()
