## A background job writes many files of one folder as SEG-Y or SEG-D, one
## file at a time, with that file's saved edits, and never the sources. A
## mirrored write keeps the sub folder. A killed trace is left out and a
## reversed trace is negated, in the file that has those edits only. A flat
## write that would reuse a name fails that file. A destination inside the
## source folder is refused before anything is written. One file the drive
## will not read is recorded and the rest are written. A cancel after the
## first file leaves that file and no part file.
##
## Seen to fail: with the store's edits not applied, "a killed trace was written".
##
## Runs on copies of samples/land/shots.sgy and samples/land/shots.sgd.

import std/[os, strutils, times]
import parseSEG
import processSEG/core/basic
import viewSEG/core/[edits, filememory, identity, jobs, outputbatch, outputjobs]
import utils/[faultyfs, waiting]

const root = currentSourcePath().parentDir.parentDir

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

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

proc partLeft(dir: string): bool =
  if not dirExists(dir): return false
  for kind, path in walkDir(dir):
    if kind == pcDir and partLeft(path): return true
    elif kind == pcFile and ".part-" in path.extractFilename: return true

proc runBatch(ask: BatchAsk; store: Store; openFiles: seq[OpenFile]):
    tuple[st: JobState; wrote: BatchResult; error: string] =
  let jobs = initJobs()
  let sink = BatchSink()
  let id = jobs.submit(outputBatchSpec(ask), outputBatchWork(ask, store, openFiles, sink))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the batch did not finish: " & $jobs.state(id)
  let info = jobs.info(id).get
  (info.state, sink.result, info.error)

var lane: Jobs

proc stopAtSecond(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if back or not phase.startsWith("file 2 of"): return
  discard lane.cancel(id)

proc itemOf(wrote: BatchResult; relative: string): BatchItemResult =
  for it in wrote.items:
    if it.relative == relative: return it
  doAssert false, "no result for " & relative

proc main*() =
  let
    land = root / "samples" / "land"
    segy = land / "shots.sgy"
    segd = land / "shots.sgd"
  doAssert fileExists(segy) and fileExists(segd), "samples/land shots are not here"
  let sampleSegy = readFile(segy)
  let sampleSegd = readFile(segd)
  let dir = getTempDir() / ("viewseg-outb-" & $getCurrentProcessId())
  let srcRoot = dir / "src"
  let mem = dir / "mem"
  createDir(srcRoot / "line1")
  createDir(srcRoot / "other")
  createDir(mem)
  let plain = srcRoot / "shots.sgy"
  let edited = srcRoot / "line1" / "shots.sgy"
  let segdCopy = srcRoot / "other" / "extra.sgd"
  copyFile(segy, plain)
  copyFile(segy, edited)
  copyFile(segd, segdCopy)
  let plainBytes = readFile(plain)
  let editedBytes = readFile(edited)
  let segdBytes = readFile(segdCopy)
  var modified: Time
  let id = quickIdentity(edited, modified)
  var lists: EditLists
  lists.lists[teKilled] = @[0]
  lists.lists[teReversed] = @[1]
  let rec = FileRecord(identity: id, name: "shots.sgy", path: edited, opened: getTime(),
    modified: modified, edits: lists, doc: docName(id, 1))
  let store = Store(home: mem)
  writeFile(store.docPath(rec.doc), memoryDocument(rec))
  let opts = OutputOptions(format: ofSegy, applyReversals: true, dropKilled: true)
  let items = @[
    BatchItem(source: plain, relative: "shots.sgy"),
    BatchItem(source: edited, relative: "line1" / "shots.sgy"),
    BatchItem(source: segdCopy, relative: "other" / "extra.sgd")]

  block mirrored:
    let dest = dir / "mirror"
    let ask = BatchAsk(root: srcRoot, items: items, destRoot: dest, options: opts,
      mirrorFolders: true)
    let spec = outputBatchSpec(ask)
    doAssert spec.lane == jlBackground
    doAssert spec.reads == @[plain, edited, segdCopy]
    doAssert spec.exclusive == @[dest / "shots.sgy", dest / "line1" / "shots.sgy",
      dest / "other" / "extra.sgy"]
    let got = runBatch(ask, store, @[])
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    doAssert got.wrote.reason.len == 0 and not got.wrote.cancelled
    doAssert got.wrote.written == 3 and got.wrote.failed == 0 and got.wrote.skipped == 0
    doAssert $boWritten == "written" and $boFailed == "failed" and $boSkipped == "skipped"
    var src = openSeismic(plain, keys = true)
    var back = openSeismic(dest / "shots.sgy", keys = true)
    doAssert back.len == src.len
    for i in 0 ..< src.len:
      doAssert samplesOf(back, i) == samplesOf(src, i), "an unedited file changed, trace " & $i
      doAssert sameKeys(back.traceKeys(i), src.traceKeys(i)), "keys of an unedited file changed"
    back.close()
    src.close()
    var ed = openSeismic(edited, keys = true)
    var wrote = openSeismic(dest / "line1" / "shots.sgy", keys = true)
    doAssert wrote.len == ed.len - 1, "a killed trace was written"
    var expect = samplesOf(ed, 1)
    reversePolarity(expect)
    doAssert samplesOf(wrote, 0) == expect, "a reversed trace was not negated"
    doAssert samplesOf(wrote, 1) == samplesOf(ed, 2), "a neighbour was reversed or dropped"
    doAssert sameKeys(wrote.traceKeys(0), ed.traceKeys(1))
    let editedItem = itemOf(got.wrote, "line1" / "shots.sgy")
    doAssert editedItem.outcome == boWritten and editedItem.droppedTraces == 1
    doAssert editedItem.writtenTraces == ed.len - 1
    wrote.close()
    ed.close()
    var sgd = openSeismic(segdCopy, keys = true)
    var sgdOut = openSeismic(dest / "other" / "extra.sgy", keys = true)
    doAssert sgdOut.len == sgd.len
    for i in 0 ..< sgd.len:
      doAssert samplesOf(sgdOut, i) == samplesOf(sgd, i), "SEG-D written as SEG-Y, trace " & $i
    sgdOut.close()
    sgd.close()
    doAssert not partLeft(dest)
    doAssert readFile(plain) == plainBytes and readFile(edited) == editedBytes and
      readFile(segdCopy) == segdBytes

  block flatClash:
    let dest = dir / "flat"
    let ask = BatchAsk(root: srcRoot, items: items, destRoot: dest, options: opts,
      mirrorFolders: false)
    let got = runBatch(ask, store, @[])
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    doAssert got.wrote.written == 2 and got.wrote.failed == 1
    let clash = itemOf(got.wrote, "line1" / "shots.sgy")
    doAssert clash.outcome == boFailed
    doAssert "already the output of" in clash.why, clash.why
    doAssert fileExists(dest / "shots.sgy") and fileExists(dest / "extra.sgy")
    doAssert not fileExists(dest / "line1" / "shots.sgy")
    doAssert not partLeft(dest)

  block destInsideSource:
    let dest = srcRoot / "inside"
    let ask = BatchAsk(root: srcRoot, items: items, destRoot: dest, options: opts,
      mirrorFolders: true)
    let got = runBatch(ask, store, @[])
    doAssert got.st == jsFailed, "a destination inside the source was written"
    doAssert "inside" in got.wrote.reason, got.wrote.reason
    doAssert "inside" in got.error, got.error
    doAssert got.wrote.written == 0 and got.wrote.items.len == 0
    doAssert not dirExists(dest), "a refused destination was created"
    doAssert readFile(plain) == plainBytes

  block oneUnreadable:
    install()
    defer: releaseAll()
    let badRoot = dir / "bad-src"
    let bad = badRoot / "gone" / "shots.sgy"
    createDir(bad.parentDir)
    copyFile(segy, bad)
    let dest = dir / "bad-out"
    let badItems = @[
      BatchItem(source: plain, relative: "shots.sgy"),
      BatchItem(source: bad, relative: "gone" / "shots.sgy"),
      BatchItem(source: segdCopy, relative: "other" / "extra.sgd")]
    fault(bad, fkFail)
    let ask = BatchAsk(root: badRoot, items: badItems, destRoot: dest, options: opts,
      mirrorFolders: true)
    let got = runBatch(ask, Store(), @[])
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    doAssert got.wrote.written == 2 and got.wrote.failed == 1
    let failed = itemOf(got.wrote, "gone" / "shots.sgy")
    doAssert failed.outcome == boFailed and failed.why.len > 0, failed.why
    doAssert fileExists(dest / "shots.sgy") and fileExists(dest / "other" / "extra.sgy")
    doAssert not dirExists(dest / "gone"), "an empty mirror folder was left"
    doAssert not partLeft(dest)
    doAssert readFile(bad) == sampleSegy

  block cancelAfterFirst:
    let dest = dir / "cancel"
    let ask = BatchAsk(root: srcRoot, items: items, destRoot: dest, options: opts,
      mirrorFolders: true)
    lane = initJobs()
    let sink = BatchSink()
    setJobHook(stopAtSecond)
    defer: setJobHook(nil)
    let id = lane.submit(outputBatchSpec(ask), outputBatchWork(ask, store, @[], sink))
    doAssert waitUntil(lane.state(id) in {jsDone, jsFailed, jsCancelled}),
      "the cancel did not finish: " & $lane.state(id)
    doAssert lane.state(id) == jsCancelled, "a cancel was not a cancel: " & $lane.state(id) &
      " " & sink.result.reason
    doAssert sink.result.cancelled and sink.result.written == 1
    doAssert sink.result.skipped == 2, "unstarted files were not skipped: " & $sink.result.skipped
    doAssert fileExists(dest / "shots.sgy")
    doAssert not fileExists(dest / "line1" / "shots.sgy")
    doAssert not partLeft(dest)
    doAssert readFile(plain) == plainBytes and readFile(edited) == editedBytes

  block openFileOverridesStore:
    var src = openSeismic(edited, keys = true)
    var passed: FileEdits
    doAssert passed.change(teKilled, [2], true) == 1
    let dest = dir / "open-file"
    createDir(dest)
    let ask = BatchAsk(root: srcRoot, items: @[BatchItem(source: edited,
      relative: "line1" / "shots.sgy")], destRoot: dest, options: opts, mirrorFolders: false)
    var opens: seq[OpenFile] = @[]
    opens.add (path: edited, file: addr src, edits: passed)
    let got = runBatch(ask, store, opens)
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    var back = openSeismic(dest / "shots.sgy", keys = true)
    doAssert back.len == src.len - 1, "the open file's kill was not the one written"
    doAssert samplesOf(back, 0) == samplesOf(src, 0), "the store's kill was applied instead"
    doAssert samplesOf(back, 1) == samplesOf(src, 1), "the store's reversal was applied instead"
    doAssert samplesOf(back, 2) == samplesOf(src, 3), "the passed kill was not left out"
    back.close()
    doAssert src.len > 0, "the passed file was closed"
    src.close()
    doAssert readFile(edited) == editedBytes

  doAssert readFile(segy) == sampleSegy and readFile(segd) == sampleSegd
  doAssert readFile(plain) == plainBytes and readFile(edited) == editedBytes and
    readFile(segdCopy) == segdBytes
  echo "toutputbatch: ok"

when isMainModule:
  main()
