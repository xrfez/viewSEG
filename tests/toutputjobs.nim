## A background job writes one open seismic file as SEG-Y or SEG-D, with the
## edits asked for, and never the source. No option: samples and key headers
## match. Each option changes only what it names. A path that exists, or that
## sits in an open file's folder, is refused. A cancel and a write that the
## drive refuses leave no file.
##
## Seen to fail: with `dropKilled` ignored, the killed-trace counts failed
## (`written == n - 1`); with a reversal left unapplied, "a reversed trace
## was not negated". With `applyPreparedTrace` passing no shift, "a spike at
## sample 100 was not written at 104". With that write not using the plot's
## sample path, "the written trace is not the panel reader's whole trace".
##
## Runs on samples/land/shots.sgy and samples/land/shots.sgd.
## Seen to fail: a cancel asked as a signature file's bytes were written was
## not looked for after the write, so the part was renamed and the job said
## done.
## Removing a directory link with `removeDir` deleted the marker in its target.

import std/[math, os, sequtils, strutils]
when defined(windows):
  from std/winlean import nil
import parseSEG
import processSEG/pipeline
import processSEG/core/[basic, rows, types, workspace]
import viewSEG/core/[edits, jobs, outputjobs, panels, processing, sorting, state]
import utils/[faultyfs, sigfiles, waiting]

const root = currentSourcePath().parentDir.parentDir

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc dropDirLink(link: string) =
  ## Removes a directory symlink, not its target. Failure is ignored: cleanup
  ## of a temp link must not fail the test.
  try:
    when defined(windows):
      if winlean.removeDirectoryW(newWideCString(link)) == 0:
        raiseOSError(osLastError(), link)
    else:
      removeFile(link)
  except OSError:
    discard

var sortLane: Jobs
var sigLane: Jobs

proc sortStopHook(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if back or phase != "writing": return
  discard sortLane.cancel(id)

proc sigWriteHook(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if back or phase != "writing the signature file": return
  discard sigLane.cancel(id)

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

  block streamsWithoutAWholeFileList:
    ## Seen to fail: `groups` held every trace, and a second `sortRowsInto`
    ## sorted the whole file again before anything was written.
    let text = readFile(currentSourcePath().parentDir.parentDir / "src/viewSEG/core/outputjobs.nim")
    var sorts = 0
    for line in text.splitLines:
      if "sortRowsInto(" in line.split('#')[0]: inc sorts
    doAssert sorts <= 1, "the whole file is sorted more than once: " & $sorts
    doAssert "seq[seq[int]]" notin text, "every record is listed before writing"

  block sortStopsWhenCancelled:
    ## Seen to fail: the sort was not given a stop, so a cancel asked as the
    ## write began was not seen until after the sort, and the job did not say
    ## the sort was stopped.
    var src = openSeismic(segy, keys = true)
    let dest = dir / "sort-cancel.sgy"
    sortLane = initJobs()
    let sink = OutputSink()
    setJobHook(sortStopHook)
    defer: setJobHook(nil)
    let keys = @[SortKey(field: hfChannel, descending: true)]
    let id = sortLane.submit(outputSpec(segy, dest),
      outputWork(addr src, segy, dest, OutputOptions(format: ofSegy, sortKeys: keys),
        FileEdits(), @[segy], sink))
    doAssert waitUntil(sortLane.state(id) in {jsDone, jsFailed, jsCancelled}),
      "the sort did not finish: " & $sortLane.state(id)
    doAssert sortLane.state(id) == jsCancelled, "a cancel during the sort was not a cancel: " &
      $sortLane.state(id) & " " & sink.result.reason
    doAssert "sort was stopped" in sink.result.reason, sink.result.reason
    doAssert not fileExists(dest), "a cancelled sort left a file"
    src.close()

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
    block everyTraceKilled:
      ## Seen to fail: every trace was left out, but dropped stayed 0.
      var edits: FileEdits
      doAssert edits.change(teKilled, toSeq(0 ..< n), true) == n
      let dest = dir / "all-killed.sgy"
      let got = runJob(src, segy, dest, OutputOptions(format: ofSegy, dropKilled: true),
        edits, @[segy])
      doAssert got.st == jsFailed, got.error & " / " & got.wrote.reason
      doAssert got.wrote.written == 0
      doAssert got.wrote.dropped == n, "dropped was " & $got.wrote.dropped & ", not " & $n
      doAssert not fileExists(dest), "a write of nothing left a file"
      doAssert "left out" in got.wrote.reason
    block keptKilled:
      ## Seen to fail: a killed trace that was kept was written as recorded,
      ## so the reversal was not applied.
      var edits: FileEdits
      doAssert edits.change(teKilled, [4], true) == 1
      doAssert edits.change(teReversed, [4], true) == 1
      let dest = dir / "kept-killed.sgy"
      let got = runJob(src, segy, dest, OutputOptions(format: ofSegy, dropKilled: false,
        applyReversals: true), edits, @[segy])
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      doAssert got.wrote.written == n and got.wrote.dropped == 0
      var back = openSeismic(dest, keys = true)
      doAssert back.len == n, "a kept killed trace was left out"
      var expect = samplesOf(src, 4)
      reversePolarity(expect)
      doAssert samplesOf(back, 4) == expect, "a kept killed trace was not reversed"
      doAssert samplesOf(back, 3) == samplesOf(src, 3), "a neighbour was reversed"
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

  block symlinkedFolder:
    ## Seen to fail: a destination under a symlinked folder was not resolved,
    ## so it was not refused as inside an open file's folder. Creating the
    ## link raises `OSError` where it is not allowed; the block is skipped.
    ## `removeFile` (DeleteFile) and `removeDir` on a directory link raise
    ## "Access is denied" or walk into the target.
    let real = dir / "real-folder"
    createDir(real)
    let marker = real / "kept.txt"
    writeFile(marker, "kept")
    let link = dir / "linked-folder"
    var made = false
    try:
      createSymlink(real, link)
      made = true
    except OSError:
      echo "symlinkedFolder: skipped, a directory symlink could not be created"
    if made:
      let why = refuseDestination(link / "out.sgy", @[real / "open.sgy"])
      doAssert "folder" in why, "a symlinked folder was not resolved: " & why
      doAssert refuseDestination(dir / "elsewhere.sgy", @[real / "open.sgy"]).len == 0,
        "a path outside the folder was refused"
      dropDirLink(link)
      doAssert readFile(marker) == "kept", "removing the link changed its target"
    dropDirLink(link)
    try:
      removeFile(marker)
      removeDir(real)
    except OSError:
      discard

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

  block aFileThatAppearsIsKept:
    ## Seen to fail: the writer renamed onto a file put at the destination
    ## while the write hung, so "kept" was gone and nothing said it appeared.
    var src = openSeismic(segy, keys = true)
    let dest = dir / "appeared.sgy"
    fault(segy, fkHang, {foMapped})
    let jobs = initJobs()
    let sink = OutputSink()
    let id = jobs.submit(outputSpec(segy, dest),
      outputWork(addr src, segy, dest, OutputOptions(format: ofSegy), FileEdits(), @[segy], sink))
    doAssert waitUntil(hung() > 0), "the write did not reach the file"
    writeFile(dest, "kept")
    release(segy)
    doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
      "the write did not finish: " & $jobs.state(id)
    doAssert jobs.state(id) == jsFailed, "a file that appeared was overwritten: " & $jobs.state(id)
    doAssert readFile(dest) == "kept", "the destination was replaced"
    doAssert "appeared while writing" in sink.result.reason, sink.result.reason
    doAssert sink.result.path.len > 0 and sink.result.path != dest, sink.result.path
    doAssert fileExists(sink.result.path), "the output was not kept as the part file"
    doAssert not sink.result.removed
    removeFile(dest)
    removeFile(sink.result.path)
    src.close()

  block cancelDoesNotDeleteTheirs:
    ## Seen to fail: cancel unlinked the destination, so a file put there
    ## while the write hung was deleted.
    var src = openSeismic(segy, keys = true)
    let dest = dir / "not-ours.sgy"
    fault(segy, fkHang, {foMapped})
    let jobs = initJobs()
    let sink = OutputSink()
    let id = jobs.submit(outputSpec(segy, dest),
      outputWork(addr src, segy, dest, OutputOptions(format: ofSegy), FileEdits(), @[segy], sink))
    doAssert waitUntil(hung() > 0), "the write did not reach the file"
    writeFile(dest, "kept")
    doAssert jobs.cancel(id)
    release(segy)
    doAssert waitUntil(jobs.state(id) == jsCancelled), "cancel did not stop the write: " &
      $jobs.state(id) & " " & sink.result.reason
    doAssert readFile(dest) == "kept", "cancel deleted a file that was not ours"
    doAssert "removed" in sink.result.reason
    var left = false
    for kind, path in walkDir(dir):
      if kind == pcFile and path.extractFilename.startsWith("not-ours.sgy.part-"): left = true
    doAssert not left, "cancel left the part file"
    removeFile(dest)
    src.close()

  block timeShift:
    ## A spike at sample 100, +8 ms at 2 ms, is written at 104, same length.
    ## With the option off it stays at 100. Seen to fail with the shift left
    ## off the write: the spike was still at sample 100.
    let srcDir = dir / "spike-src"
    let outDir = dir / "spike-out"
    createDir(srcDir)
    createDir(outDir)
    let path = srcDir / "spike.sgy"
    var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
      text: @["C01 viewSEG test: a spike at sample 100"]))
    var buf = newSeq[float32](200)
    buf[100] = 1
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, 1.0, 0.0, 2000.0, tsLive)
    w.writeTrace(k, buf)
    doAssert w.close().len == 0
    var src = openSeismic(path, keys = true)
    var edits: FileEdits
    doAssert edits.setTimeShifts([0], 8.0, 2.0) == 1
    doAssert edits.shiftOf(0) == 8.0
    let dest = outDir / "shifted.sgy"
    let got = runJob(src, path, dest, OutputOptions(format: ofSegy, applyShifts: true),
      edits, @[path])
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    var back = openSeismic(dest, keys = true)
    let wrote = samplesOf(back, 0)
    doAssert wrote.len == 200, "a shifted trace changed length: " & $wrote.len
    doAssert wrote[104] == 1'f32 and wrote[100] == 0'f32,
      "a spike at sample 100 was not written at 104"
    back.close()
    removeFile(dest)
    let destOff = outDir / "unshifted.sgy"
    let off = runJob(src, path, destOff, OutputOptions(format: ofSegy), edits, @[path])
    doAssert off.st == jsDone, off.error & " / " & off.wrote.reason
    var plain = openSeismic(destOff, keys = true)
    let kept = samplesOf(plain, 0)
    doAssert kept.len == 200 and kept[100] == 1'f32 and kept[104] == 0'f32,
      "a shift left off was written at 104"
    plain.close()
    removeFile(destOff)
    src.close()

  block sameAsThePlot:
    ## One trace with a reversal, a shift, an own filter and the plot's
    ## filters: the written samples are the panel reader's whole trace.
    ## Display gain is none, so the reader does not add a scale. Seen to fail
    ## with the shift left off the write.
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: segy)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    var d = st.panel(MainPanel).layers[0].display
    d.gain = dgNone
    st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    let lay = st.panel(MainPanel).layout
    var view = fitAll(lay, 800, 2 * lay.samples)
    view.traces = Span(lo: -0.5, hi: float64(min(lay.traces, 8)) - 0.5)
    st.apply Command(kind: ckView, panel: MainPanel, view: view)
    let base = st.sessions[0].base
    let trace = 2
    let plot = bounded(Processing(band: pbHighCut, f3: 40, f4: 50))
    let own = bounded(OwnFilter(spec: Processing(band: pbBandPass, f1: 8, f2: 12, f3: 40,
      f4: 50)))
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[base + trace],
      on: true)
    st.apply Command(kind: ckTimeShift, panel: MainPanel, edited: @[base + trace], on: true,
      ms: 8.0)
    st.apply Command(kind: ckProcessing, panel: MainPanel, processing: plot)
    st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base + trace], on: true,
      processing: own.spec, filterPlace: fpAfter)
    proc answered(st: AppState): bool =
      let p = st.panel(MainPanel)
      not p.pending.isEmpty and p.pending.gen == p.requestGen and st.tiles(0).len > 0 and
        st.tiles(0)[^1].request == p.pending
    doAssert st.settle(answered(st)), "the plot did not answer"
    let tile = st.tiles(0)[^1]
    doAssert tile.request.decimation == 1, $tile.request
    var row = -1
    for i, t in tile.traces:
      if t == trace: row = i
    doAssert row >= 0, "trace 3 is not in the tile"
    let shown = tile.data[row * tile.columns ..< (row + 1) * tile.columns]
    let edits = st.editsOf(0)
    doAssert edits.effectivelyReversed(trace) and edits.shiftOf(trace) == 8.0
    doAssert shown.len == lay.samples, "the reader did not keep the whole trace: " & $shown.len
    st.shutdown()
    var src = openSeismic(segy, keys = true)
    doAssert shown.len == samplesOf(src, trace).len
    let dest = dir / "same-as-plot.sgy"
    let got = runJob(src, segy, dest, OutputOptions(format: ofSegy, applyReversals: true,
      applyShifts: true, applyOwnFilters: true, applyProcessing: true, processing: plot),
      edits, @[segy])
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    var back = openSeismic(dest, keys = true)
    doAssert samplesOf(back, trace) == shown,
      "the written trace is not the panel reader's whole trace"
    doAssert samplesOf(back, trace) != samplesOf(src, trace), "the options changed nothing"
    back.close()
    src.close()
    removeFile(dest)

  block cancelDuringSignatureWrite:
    ## Seen to fail: the cancel asked as the signature bytes were written was
    ## not seen after the write, so the part was renamed into place.
    let path = vibFile(dir / "sig", "0007.VIB", SynthVib(afterTrigger: 40, taperFrames: 4))
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len >= 1), "did not open " & path.extractFilename
    let s = st.sessions[0]
    let dest = dir / "cancelled-sig.segd"
    sigLane = initJobs()
    let sink = OutputSink()
    setJobHook(sigWriteHook)
    defer: setJobHook(nil)
    let id = sigLane.submit(outputSpec(path, dest),
      outputWork(s.filePtr, path, dest, OutputOptions(format: ofSegd), FileEdits(),
        @[path], sink, s.signature))
    doAssert waitUntil(sigLane.state(id) in {jsDone, jsFailed, jsCancelled}),
      "the write did not finish: " & $sigLane.state(id)
    doAssert sigLane.state(id) == jsCancelled, "a cancel during the write was not a cancel: " &
      $sigLane.state(id) & " " & sink.result.reason
    doAssert not fileExists(dest), "a cancelled signature write left a file"
    doAssert "removed" in sink.result.reason, sink.result.reason
    var left = false
    for kind, part in walkDir(dir):
      if kind == pcFile and part.extractFilename.startsWith("cancelled-sig.segd.part-"):
        left = true
    doAssert not left, "cancel left the part file"
    st.shutdown()

  doAssert readFile(segy) == srcBytes and readFile(segd) == sgdBytes
  dropDirLink(dir / "linked-folder")
  try:
    removeDir(dir)
  except OSError:
    dropDirLink(dir / "linked-folder")
    try:
      removeDir(dir)
    except OSError:
      discard
  echo "toutputjobs: ok"

when isMainModule:
  main()
