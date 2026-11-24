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
## Seen to fail: with `plain` a byte-identical copy of `edited` at the same
## time, `back.len == src.len` (that kill is this file's too).
##
## A chosen pattern replaces the leaf after the open. Seen to fail: with the
## rendered leaf ignored, the one-record file was `one.sgy` not
## `2001.0103.0001.sgy`; with only the first traces compared, shots.sgy was
## written (`a file of two shots was written`); with the clash check left
## off, the second file failed `The destination already exists.` not
## `2001.0103.0001.sgy is already the output of one.sgd.`; with the session
## station used, the name was `0999.sgy`; with signature facts left empty,
## the write failed `Controller is not in this file.`; with no pattern still
## locking the folder, exclusive was not the planned file names. With the
## folder left as given, `/tmp/out/` did not lock `/tmp/out` (`/tmp/out`,
## `/tmp/out/` and `/tmp/out/.` are one lock).
##
## Runs on copies of samples/land/shots.sgy, samples/land/shots.sgd and
## samples/vib/vib_uncorrelated.sgd.

import std/[options, os, strutils, times]
when defined(windows):
  from std/winlean import nil
import parseSEG
import parseSEG/model/traceindex
import processSEG/core/basic
import viewSEG/core/[edits, filememory, filesystem, identity, jobs, outputbatch,
  outputjobs, outputnames, sigtypes]
import utils/[faultyfs, sigfiles, waiting]

const root = currentSourcePath().parentDir.parentDir

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc dropDirLink(link: string) =
  ## Removes a directory symlink, not its target. Failure is ignored: cleanup
  ## of a temp link must not fail the test. `removeDir` walks into the target.
  try:
    when defined(windows):
      if winlean.removeDirectoryW(newWideCString(link)) == 0:
        raiseOSError(osLastError(), link)
    else:
      removeFile(link)
  except OSError:
    discard

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

proc differ(path: string) =
  ## Changes one sample of `path` inside the ends the quick identity hashes,
  ## so a copy of the same bytes is a different file and not merely a
  ## different time. The changed byte is a sample's least significant byte.
  var before: Time
  let old = quickIdentity(path, before)
  var f = openSeismic(path)
  let n = f.len
  doAssert n > 0, path
  let size = getFileSize(path)
  var at = -1
  for i in 0 ..< n:
    let e = f.traceEntry(i)
    if e.numSamples < 1: continue
    let lsb = e.offset + int64(e.headerBytes) + 3
    if lsb < 0 or lsb >= size: continue
    if lsb < QuickSpan or lsb >= size - QuickSpan:
      at = int(lsb)
      break
  f.close()
  doAssert at >= 0, "no sample in the ends of " & path
  var raw = readFile(path)
  raw[at] = char(ord(raw[at]) xor 0x01)
  writeFile(path, raw)
  var g = openSeismic(path)
  doAssert g.len == n, "changing a sample broke " & path
  g.close()
  var after: Time
  let now = quickIdentity(path, after)
  doAssert now.size != old.size or now.quick != old.quick,
    "the changed sample did not change the file's identity"

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
var refMaps = 0

proc countRef(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  if op == foMapped and path.endsWith("ref.sgy"):
    {.cast(gcsafe).}:
      inc refMaps

proc stopAtSecond(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if back or not phase.startsWith("file 2 of"): return
  discard lane.cancel(id)

proc itemOf(wrote: BatchResult; relative: string): BatchItemResult =
  for it in wrote.items:
    if it.relative == relative: return it
  doAssert false, "no result for " & relative

proc writeSweep(path: string; samples: openArray[float32]; us: float64) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  var k = initTraceKeys()
  k.intervalUs = us
  k.status = tsLive
  k.traceCode = 1
  w.writeTrace(k, @samples)
  doAssert w.close().len == 0, "the reference did not close"

proc writeRecord(path: string; n: int; us: float64) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for i in 0 .. 3:
    var buf = newSeq[float32](n)
    for j in 0 ..< n: buf[j] = float32(j + i + 1)
    var k = initTraceKeys()
    k.record = 7.0
    k.channel = float64(i + 1)
    k.intervalUs = us
    k.t0Ms = 0.0
    if i == 3: (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    else: (k.traceCode, k.status) = (1'i16, tsLive)
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the record did not close"

proc writeSame(source, dest: string; sweep: seq[float32]; dtMs: float64) =
  var file = openSeismic(source, keys = true)
  let opts = OutputOptions(format: ofSegy, correlation: some(OutputCorrelation(
    reference: sweep, referenceDtMs: dtMs, referenceTraces: @[3])))
  let jobs = initJobs()
  let sink = OutputSink()
  let id = jobs.submit(outputSpec(source, dest),
    outputWork(addr file, source, dest, opts, FileEdits(), @[source], sink))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the compared write did not finish"
  doAssert jobs.state(id) == jsDone, jobs.info(id).get.error & " / " & sink.result.reason
  file.close()

proc sameFile(a, b: string; listen: int) =
  var left = openSeismic(a, keys = true)
  var right = openSeismic(b, keys = true)
  doAssert left.len == right.len
  for t in 0 ..< left.len:
    let x = samplesOf(left, t)
    let y = samplesOf(right, t)
    doAssert x.len == listen and y.len == listen, "trace " & $t & " " & $x.len & " vs " & $y.len
    doAssert x == y, "trace " & $t & " differs"
  left.close()
  right.close()

proc main*() =
  block sameFolderLock:
    let shot = OutputPattern(name: "Shot", separator: nsDot,
      parts: @[NamePart(kind: npSrcLine, pad: 4)])
    proc locked(root: string): string =
      let ask = BatchAsk(destRoot: root, pattern: shot,
        items: @[BatchItem(source: "/tmp/in.sgy", relative: "in.sgy")])
      let spec = outputBatchSpec(ask)
      doAssert spec.exclusive.len == 1, $spec.exclusive
      spec.exclusive[0]
    let want = absolutePath("/tmp/out").normalizedPath
    let plain = locked("/tmp/out")
    let slashed = locked("/tmp/out/")
    let dotted = locked("/tmp/out/.")
    doAssert plain == slashed and slashed == dotted, plain & " / " & slashed & " / " & dotted
    doAssert plain == want, plain

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
  differ(plain)
  let plainBytes = readFile(plain)
  let editedBytes = readFile(edited)
  let segdBytes = readFile(segdCopy)
  var modified: Time
  let id = quickIdentity(edited, modified)
  var plainTime: Time
  let plainId = quickIdentity(plain, plainTime)
  doAssert plainId.size != id.size or plainId.quick != id.quick,
    "plain and edited are one file: the same size and ends"
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
    opens.add (path: edited, file: addr src, edits: passed, signature: SignatureFacts())
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

  block symlinkedRoot:
    ## Seen to fail: the destination root was resolved only through its parent,
    ## so a root that is itself a symlink to the source was not refused, a root
    ## linked to a sub folder or to the source's parent was not refused, and a
    ## root linked to an unrelated folder failed mirror mode ("No such file or
    ## directory" while creating the mirrored folder).
    let linkSrc = dir / "link-src"
    let linkSub = dir / "link-sub"
    let linkParent = dir / "link-parent"
    let unrelated = dir / "unrelated"
    let linkOk = dir / "link-ok"
    createDir(unrelated)
    var made = false
    try:
      createSymlink(srcRoot, linkSrc)
      createSymlink(srcRoot / "line1", linkSub)
      createSymlink(srcRoot.parentDir, linkParent)
      createSymlink(unrelated, linkOk)
      made = true
    except OSError:
      echo "symlinkedRoot: skipped, a directory symlink could not be created"
    if made:
      let one = @[BatchItem(source: plain, relative: "line1" / "shots.sgy")]
      let mirror = OutputOptions(format: ofSegy)
      proc runOne(dest: string): tuple[st: JobState; wrote: BatchResult; error: string] =
        runBatch(BatchAsk(root: srcRoot, items: one, destRoot: dest, options: mirror,
          mirrorFolders: true), Store(), @[])
      let toSource = runOne(linkSrc)
      doAssert toSource.st == jsFailed, "a root linked to the source was written: " &
        toSource.error
      doAssert "source folder" in toSource.wrote.reason, toSource.wrote.reason
      doAssert "inside" notin toSource.wrote.reason, toSource.wrote.reason
      doAssert toSource.wrote.written == 0 and toSource.wrote.items.len == 0
      let toSub = runOne(linkSub)
      doAssert toSub.st == jsFailed, "a root linked to a sub folder was written: " &
        toSub.error
      doAssert "inside the source" in toSub.wrote.reason, toSub.wrote.reason
      doAssert toSub.wrote.written == 0
      let toParent = runOne(linkParent)
      doAssert toParent.st == jsFailed, "a root linked to the source's parent was written: " &
        toParent.error
      doAssert "source folder is inside" in toParent.wrote.reason, toParent.wrote.reason
      doAssert toParent.wrote.written == 0
      let toOther = runOne(linkOk)
      doAssert toOther.st == jsDone, toOther.error & " / " & toOther.wrote.reason
      doAssert toOther.wrote.written == 1 and toOther.wrote.failed == 0
      let want = expandFilename(unrelated) / "line1" / "shots.sgy"
      doAssert fileExists(want), "mirror mode did not write into the linked folder"
      doAssert sameFile(toOther.wrote.items[0].destination, want),
        toOther.wrote.items[0].destination
      let missing = linkOk / "new-out"
      let toMissing = runOne(missing)
      doAssert toMissing.st == jsDone, toMissing.error & " / " & toMissing.wrote.reason
      let wantMissing = expandFilename(unrelated) / "new-out" / "line1" / "shots.sgy"
      doAssert fileExists(wantMissing), "a root under a symlink was not resolved"
      doAssert sameFile(toMissing.wrote.items[0].destination, wantMissing),
        toMissing.wrote.items[0].destination
      doAssert readFile(plain) == plainBytes and readFile(edited) == editedBytes
    dropDirLink(linkSrc)
    dropDirLink(linkSub)
    dropDirLink(linkParent)
    dropDirLink(linkOk)

  block editLines:
    ## Seen to fail: an item's lines never said which saved edits were applied,
    ## nor that none were found, nor that a pending document was left unapplied.
    let dest = dir / "lines"
    let ask = BatchAsk(root: srcRoot, items: @[
      BatchItem(source: edited, relative: "line1" / "shots.sgy"),
      BatchItem(source: segdCopy, relative: "other" / "extra.sgd")],
      destRoot: dest, options: opts, mirrorFolders: true)
    let got = runBatch(ask, store, @[])
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    let applied = itemOf(got.wrote, "line1" / "shots.sgy")
    doAssert applied.lines.len == 2, $applied.lines
    doAssert applied.lines[0] == "applied this file's saved edits: " & keptWords(lists),
      applied.lines[0]
    doAssert applied.lines[1] == BatchOwnPositions, applied.lines[1]
    doAssert "1 killed, 1 reversed" in applied.lines[0]
    let none = itemOf(got.wrote, "other" / "extra.sgd")
    doAssert "no saved edits were found for this file" in none.lines, $none.lines
    let held = srcRoot / "held.sgy"
    copyFile(segy, held)
    differ(held)
    var heldTime: Time
    let heldId = quickIdentity(held, heldTime)
    doAssert heldId.size != id.size or heldId.quick != id.quick,
      "held and edited are one file: the same size and ends"
    var heldLists: EditLists
    heldLists.lists[teKilled] = @[0]
    let heldRec = FileRecord(identity: heldId, name: "held.sgy", path: held,
      opened: getTime(), modified: heldTime, edits: heldLists, unconfirmed: true,
      doc: docName(heldId, 1))
    writeFile(store.docPath(heldRec.doc), memoryDocument(heldRec))
    let pend = srcRoot / "pend.sgy"
    copyFile(segy, pend)
    differ(pend)
    var pendTime: Time
    let pendId = quickIdentity(pend, pendTime)
    doAssert pendId.size != id.size or pendId.quick != id.quick,
      "pend and edited are one file: the same size and ends"
    writeFile(store.docPath(pendingName(pend)), "not a document")
    let ask2 = BatchAsk(root: srcRoot, items: @[
      BatchItem(source: held, relative: "held.sgy"),
      BatchItem(source: pend, relative: "pend.sgy")],
      destRoot: dest / "why", options: opts, mirrorFolders: false)
    let got2 = runBatch(ask2, store, @[])
    doAssert got2.st == jsDone, got2.error & " / " & got2.wrote.reason
    let unconf = itemOf(got2.wrote, "held.sgy")
    doAssert "Saved edits were left unconfirmed, so they were not applied." in unconf.lines,
      $unconf.lines
    doAssert unconf.droppedTraces == 0, "an unconfirmed kill was applied"
    let pending = itemOf(got2.wrote, "pend.sgy")
    doAssert "this file has edits that were not yet saved to its document: not applied" in
      pending.lines, $pending.lines
    doAssert pending.droppedTraces == 0, "a pending kill was applied"
    doAssert readFile(store.docPath(pendingName(pend))) == "not a document"

  block otherContent:
    ## Seen to fail: a record matched on size, ends and time was applied even
    ## when its stored hash of every byte was another file's, so a kill from
    ## that file was dropped from this one.
    let changed = srcRoot / "changed.sgy"
    let same = srcRoot / "same.sgy"
    copyFile(segy, changed)
    copyFile(segy, same)
    let originalFull = fullHash(changed)
    var raw = readFile(changed)
    let mid = raw.len div 2
    raw[mid] = char(ord(raw[mid]) xor 0xff)
    writeFile(changed, raw)
    # A whole second: setting the time keeps microseconds, not the file's
    # nanoseconds, and the store keeps the time it is given.
    let stamp = initTime(getTime().toUnix, 0)
    setLastModificationTime(changed, stamp)
    var changedTime: Time
    var changedId = quickIdentity(changed, changedTime)
    doAssert changedTime == stamp, "the changed file's time was not the one stored"
    changedId.full = originalFull
    changedId.fullKnown = true
    var kill: EditLists
    kill.lists[teKilled] = @[0]
    let hashHome = dir / "hashmem"
    createDir(hashHome)
    let hashStore = Store(home: hashHome)
    let changedRec = FileRecord(identity: changedId, name: "changed.sgy", path: changed,
      opened: getTime(), modified: changedTime, edits: kill, doc: docName(changedId, 1))
    writeFile(hashStore.docPath(changedRec.doc), memoryDocument(changedRec))
    var sameTime: Time
    var sameId = quickIdentity(same, sameTime)
    sameId.full = fullHash(same)
    sameId.fullKnown = true
    let sameRec = FileRecord(identity: sameId, name: "same.sgy", path: same,
      opened: getTime(), modified: sameTime, edits: kill, doc: docName(sameId, 2))
    writeFile(hashStore.docPath(sameRec.doc), memoryDocument(sameRec))
    let dest = dir / "hash-out"
    let ask = BatchAsk(root: srcRoot, items: @[
      BatchItem(source: changed, relative: "changed.sgy"),
      BatchItem(source: same, relative: "same.sgy")],
      destRoot: dest, options: opts, mirrorFolders: false)
    let got = runBatch(ask, hashStore, @[])
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    let wrong = itemOf(got.wrote, "changed.sgy")
    doAssert "saved edits belong to a file with other content: not applied" in wrong.lines,
      $wrong.lines
    doAssert wrong.droppedTraces == 0, "a kill from another file's content was applied"
    doAssert "applied this file's saved edits" notin wrong.lines.join(" ")
    let agreed = itemOf(got.wrote, "same.sgy")
    doAssert "applied this file's saved edits: 1 killed" in agreed.lines, $agreed.lines
    doAssert agreed.droppedTraces == 1, "a hash that agrees was not applied"

  block cancelBeforeFirst:
    ## Seen to fail: a cancel before the first item raised before any plan
    ## existed, so the result listed no items and the unwritten files were
    ## not skipped.
    install()
    defer: releaseAll()
    let dest = dir / "early-out"
    fault(dest, fkHang, {foStat})
    lane = initJobs()
    let sink = BatchSink()
    let ask = BatchAsk(root: srcRoot, items: items, destRoot: dest, options: opts,
      mirrorFolders: true)
    let id = lane.submit(outputBatchSpec(ask), outputBatchWork(ask, store, @[], sink))
    doAssert waitUntil(hung() >= 1), "the destination was not held before the first file"
    doAssert lane.cancel(id)
    release(dest)
    doAssert waitUntil(lane.state(id) in {jsDone, jsFailed, jsCancelled}),
      "the cancel did not finish: " & $lane.state(id)
    doAssert lane.state(id) == jsCancelled, "a cancel was not a cancel: " & $lane.state(id)
    doAssert sink.result.cancelled
    doAssert sink.result.written == 0 and sink.result.failed == 0
    doAssert sink.result.skipped == items.len, "unwritten files were not skipped: " &
      $sink.result.skipped & " items " & $sink.result.items.len
    doAssert sink.result.items.len == items.len
    for it in sink.result.items:
      doAssert it.outcome == boSkipped, $it.relative & " " & $it.outcome
    doAssert not dirExists(dest), "a destination was created after the cancel"
    doAssert readFile(plain) == plainBytes and readFile(edited) == editedBytes

  block sameFileTwoPaths:
    ## Two byte-identical copies with the same modification time are one file
    ## known under two paths: the saved edits are applied to both, and the
    ## item says so. Seen to fail: with the copies given different times,
    ## "applied this file's saved edits: 1 killed" was not in the second
    ## item's lines.
    let twinA = srcRoot / "twin-a.sgy"
    let twinB = srcRoot / "twin-b.sgy"
    copyFile(segy, twinA)
    copyFile(segy, twinB)
    let stamp = initTime(getTime().toUnix, 0)
    setLastModificationTime(twinA, stamp)
    setLastModificationTime(twinB, stamp)
    var timeA, timeB: Time
    let idA = quickIdentity(twinA, timeA)
    let idB = quickIdentity(twinB, timeB)
    doAssert timeA == stamp and timeB == stamp, "the copies' times were not the one stored"
    doAssert idA.size == idB.size and idA.quick == idB.quick, "the copies are not the same file"
    var kill: EditLists
    kill.lists[teKilled] = @[0]
    let shareHome = dir / "sharemem"
    createDir(shareHome)
    let shareStore = Store(home: shareHome)
    let shareRec = FileRecord(identity: idA, name: "twin-a.sgy", path: twinA,
      opened: getTime(), modified: timeA, edits: kill, doc: docName(idA, 1))
    writeFile(shareStore.docPath(shareRec.doc), memoryDocument(shareRec))
    let dest = dir / "share-out"
    let ask = BatchAsk(root: srcRoot, items: @[
      BatchItem(source: twinA, relative: "twin-a.sgy"),
      BatchItem(source: twinB, relative: "twin-b.sgy")],
      destRoot: dest, options: opts, mirrorFolders: false)
    let got = runBatch(ask, shareStore, @[])
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    for rel in ["twin-a.sgy", "twin-b.sgy"]:
      let it = itemOf(got.wrote, rel)
      doAssert "applied this file's saved edits: 1 killed" in it.lines, $it.lines
      doAssert it.droppedTraces == 1, rel & " did not share the kill"
    var src = openSeismic(twinA, keys = true)
    var back = openSeismic(dest / "twin-b.sgy", keys = true)
    doAssert back.len == src.len - 1, "the shared kill was not applied to the other path"
    back.close()
    src.close()
    doAssert readFile(twinA) == readFile(segy) and readFile(twinB) == readFile(segy)

  block patternNames:
    let vib = root / "samples" / "vib" / "vib_uncorrelated.sgd"
    doAssert fileExists(vib), "samples/vib/vib_uncorrelated.sgd is not here"
    let shot = OutputPattern(name: "Shot", separator: nsDot, parts: @[
      NamePart(kind: npSrcLine, pad: 4), NamePart(kind: npSrcPoint, pad: 4),
      NamePart(kind: npRecord, pad: 4)])
    let recOnly = OutputPattern(name: "Rec", separator: nsDot,
      parts: @[NamePart(kind: npRecord, pad: 4)])
    let src = dir / "namesrc"
    createDir(src)
    let one = src / "one.sgd"
    let two = src / "two.sgd"
    let plain = src / "plain.sgd"
    copyFile(vib, one)
    copyFile(vib, two)
    copyFile(vib, plain)
    let segyOpts = OutputOptions(format: ofSegy)

    block renders:
      let dest = dir / "named-one"
      let ask = BatchAsk(root: src, items: @[BatchItem(source: one, relative: "one.sgd")],
        destRoot: dest, options: segyOpts, pattern: shot)
      doAssert outputBatchSpec(ask).exclusive == @[absolutePath(dest).normalizedPath],
        "the folder was not the lock"
      let got = runBatch(ask, Store(), @[])
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      let it = itemOf(got.wrote, "one.sgd")
      doAssert it.outcome == boWritten, it.why
      doAssert it.destination.extractFilename == "2001.0103.0001.sgy", it.destination
      doAssert fileExists(dest / "2001.0103.0001.sgy")
      doAssert not fileExists(dest / "one.sgy"), "the pattern was ignored"

    block refusesRecord:
      let dest = dir / "named-shots"
      let ask = BatchAsk(root: src, items: @[
        BatchItem(source: segy, relative: "shots.sgy"),
        BatchItem(source: one, relative: "one.sgd")],
        destRoot: dest, options: segyOpts, pattern: recOnly)
      let got = runBatch(ask, Store(), @[])
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      let shots = itemOf(got.wrote, "shots.sgy")
      doAssert shots.outcome == boFailed, "a file of two shots was written"
      doAssert shots.why == "Record is not one value in this file.", shots.why
      doAssert not fileExists(dest / "shots.sgy")
      let kept = itemOf(got.wrote, "one.sgd")
      doAssert kept.outcome == boWritten, kept.why
      doAssert kept.destination.extractFilename == "0001.sgy", kept.destination

    block sameRenderedName:
      let dest = dir / "named-clash"
      let ask = BatchAsk(root: src, items: @[
        BatchItem(source: one, relative: "one.sgd"),
        BatchItem(source: two, relative: "two.sgd")],
        destRoot: dest, options: segyOpts, mirrorFolders: false, pattern: shot)
      let got = runBatch(ask, Store(), @[])
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      let first = itemOf(got.wrote, "one.sgd")
      let second = itemOf(got.wrote, "two.sgd")
      doAssert first.outcome == boWritten, first.why
      doAssert second.outcome == boFailed, "the second file was written"
      doAssert second.why == "2001.0103.0001.sgy is already the output of one.sgd.", second.why
      doAssert fileExists(dest / "2001.0103.0001.sgy")

    block alreadyThere:
      let dest = dir / "named-exists"
      createDir(dest)
      writeFile(dest / "2001.0103.0001.sgy", "taken")
      let ask = BatchAsk(root: src, items: @[BatchItem(source: one, relative: "one.sgd")],
        destRoot: dest, options: segyOpts, pattern: shot)
      let got = runBatch(ask, Store(), @[])
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      let it = itemOf(got.wrote, "one.sgd")
      doAssert it.outcome == boFailed, "an existing destination was written"
      doAssert it.why == "The destination already exists.", it.why
      doAssert readFile(dest / "2001.0103.0001.sgy") == "taken"

    block keepOwn:
      let held = src / "joined.sgd"
      copyFile(vib, held)
      var open = openSeismic(held, keys = true)
      for t in 0 ..< open.len: open.mindex.keys[t].srcPoint = 999.0
      open.mindex.joined = true
      let dest = dir / "named-own"
      let ask = BatchAsk(root: src, items: @[BatchItem(source: held, relative: "joined.sgd")],
        destRoot: dest, options: OutputOptions(format: ofSegy, writeSessionPositions: false),
        pattern: OutputPattern(name: "Point", separator: nsDot,
          parts: @[NamePart(kind: npSrcPoint, pad: 4)]))
      let got = runBatch(ask, Store(), @[(path: held, file: addr open,
        edits: FileEdits(), signature: SignatureFacts())])
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      let it = itemOf(got.wrote, "joined.sgd")
      doAssert it.outcome == boWritten, it.why
      doAssert it.destination.extractFilename == "0103.sgy", it.destination
      doAssert not fileExists(dest / "0999.sgy"), "the joined station was used"
      var back = openSeismic(dest / "0103.sgy", keys = true)
      doAssert back.traceKeys(0).srcPoint == 103.0, "the name does not match the bytes"
      back.close()
      open.close()

    block signatureFile:
      let dat = datFile(src, "ctrl.dat")
      let dest = dir / "named-dat"
      let ask = BatchAsk(root: src, items: @[BatchItem(source: dat, relative: "ctrl.dat")],
        destRoot: dest, options: segyOpts, pattern: OutputPattern(name: "Sig",
          separator: nsDot, parts: @[NamePart(kind: npController),
          NamePart(kind: npFileNumber)]))
      let got = runBatch(ask, Store(), @[])
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      let it = itemOf(got.wrote, "ctrl.dat")
      doAssert it.outcome == boWritten, it.why
      doAssert it.destination.extractFilename == "4321.7001.sgy", it.destination

    block noPattern:
      let dest = dir / "named-plain"
      let ask = BatchAsk(root: src, items: @[BatchItem(source: plain, relative: "plain.sgd")],
        destRoot: dest, options: segyOpts)
      doAssert outputBatchSpec(ask).exclusive == @[dest / "plain.sgy"]
      let got = runBatch(ask, Store(), @[])
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      let it = itemOf(got.wrote, "plain.sgd")
      doAssert it.outcome == boWritten, it.why
      doAssert it.destination.extractFilename == "plain.sgy", it.destination
      let sigDest = dir / "named-sigext"
      let dat = datFile(src, "same.dat")
      let vibSig = vibFile(src, "same.vib")
      let both = BatchAsk(root: src, items: @[
        BatchItem(source: dat, relative: "same.dat"),
        BatchItem(source: vibSig, relative: "same.vib")],
        destRoot: sigDest, options: segyOpts, mirrorFolders: false)
      let wrote = runBatch(both, Store(), @[])
      doAssert wrote.st == jsDone, wrote.error & " / " & wrote.wrote.reason
      doAssert itemOf(wrote.wrote, "same.dat").destination.extractFilename == "same.dat.sgy"
      doAssert itemOf(wrote.wrote, "same.vib").destination.extractFilename == "same.vib.sgy"
      doAssert fileExists(sigDest / "same.dat.sgy") and fileExists(sigDest / "same.vib.sgy")

    block leavesFolder:
      let dest = dir / "named-leave"
      let ask = BatchAsk(root: src, items: @[BatchItem(source: one, relative: ".." / "one.sgd")],
        destRoot: dest, options: segyOpts, pattern: shot)
      let got = runBatch(ask, Store(), @[])
      doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
      let it = itemOf(got.wrote, ".." / "one.sgd")
      doAssert it.outcome == boFailed, "a path that leaves the folder was written"
      doAssert "leaves the destination folder" in it.why, it.why

  block correlated:
    ## Seen to fail: with the correlation left off the write, `x.len == listen`
    ## was "trace 0 64 vs 48".
    let src = dir / "corr-src"
    let dest = dir / "corr-out"
    let alone = dir / "corr-alone"
    createDir(src)
    var sweep = newSeq[float32](16)
    for i in 0 ..< sweep.len: sweep[i] = float32(i + 1) * 0.25
    let refPath = src / "ref.sgy"
    writeSweep(refPath, sweep, 2000.0)
    let a = src / "a.sgy"
    let b = src / "b.sgy"
    writeRecord(a, 64, 2000.0)
    writeRecord(b, 64, 2000.0)
    refMaps = 0
    setFsHook(countRef)
    let ask = BatchAsk(root: src, items: @[
      BatchItem(source: a, relative: "a.sgy"),
      BatchItem(source: b, relative: "b.sgy")],
      destRoot: dest, options: OutputOptions(format: ofSegy),
      correlate: BatchCorrelate(on: true, name: "sweep", path: refPath))
    let got = runBatch(ask, Store(), @[])
    setFsHook(nil)
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    doAssert got.wrote.written == 2 and got.wrote.failed == 0, $got.wrote.failed
    doAssert got.wrote.referenceLoads == 1, "loaded " & $got.wrote.referenceLoads
    doAssert refMaps == 1, "the reference was mapped " & $refMaps & " times"
    doAssert got.wrote.correlatedWith == "sweep"
    createDir(alone)
    writeSame(a, alone / "a.sgy", sweep, 2.0)
    writeSame(b, alone / "b.sgy", sweep, 2.0)
    sameFile(dest / "a.sgy", alone / "a.sgy", 48)
    sameFile(dest / "b.sgy", alone / "b.sgy", 48)

  block intervalMismatch:
    ## Seen to fail: with the correlation left off the write, the other interval
    ## was written (`a refused file was written`).
    let src = dir / "bad-int"
    let dest = dir / "bad-int-out"
    createDir(src)
    var sweep = newSeq[float32](16)
    for i in 0 ..< sweep.len: sweep[i] = 1.0
    let refPath = src / "ref.sgy"
    writeSweep(refPath, sweep, 2000.0)
    let good = src / "good.sgy"
    let bad = src / "bad.sgy"
    writeRecord(good, 64, 2000.0)
    writeRecord(bad, 64, 4000.0)
    let ask = BatchAsk(root: src, items: @[
      BatchItem(source: good, relative: "good.sgy"),
      BatchItem(source: bad, relative: "bad.sgy")],
      destRoot: dest, options: OutputOptions(format: ofSegy),
      correlate: BatchCorrelate(on: true, name: "sweep", path: refPath))
    let got = runBatch(ask, Store(), @[])
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    doAssert got.wrote.written == 1 and got.wrote.failed == 1
    doAssert got.wrote.referenceLoads == 1, "loaded " & $got.wrote.referenceLoads
    let failed = itemOf(got.wrote, "bad.sgy")
    doAssert failed.outcome == boFailed
    doAssert "sampled every" in failed.why and "the record every" in failed.why, failed.why
    doAssert fileExists(dest / "good.sgy")
    doAssert not fileExists(dest / "bad.sgy"), "a refused file was written"
    let alone = dir / "bad-int-alone"
    createDir(alone)
    writeSame(good, alone / "good.sgy", sweep, 2.0)
    sameFile(dest / "good.sgy", alone / "good.sgy", 48)

  block signatureUncorrelated:
    ## Seen to fail: with the uncorrelated line left out, `said == 1` was
    ## `@["no saved edits were found for this file", "The batch wrote the file's own positions."]`.
    let src = dir / "sig-corr"
    let dest = dir / "sig-corr-out"
    createDir(src)
    var sweep = newSeq[float32](16)
    for i in 0 ..< sweep.len: sweep[i] = 0.5
    let refPath = src / "ref.sgy"
    writeSweep(refPath, sweep, 2000.0)
    let seismic = src / "rec.sgy"
    writeRecord(seismic, 64, 2000.0)
    let dat = datFile(src, "ctrl.dat")
    let ask = BatchAsk(root: src, items: @[
      BatchItem(source: seismic, relative: "rec.sgy"),
      BatchItem(source: dat, relative: "ctrl.dat")],
      destRoot: dest, options: OutputOptions(format: ofSegy),
      correlate: BatchCorrelate(on: true, name: "sweep", path: refPath))
    let got = runBatch(ask, Store(), @[])
    doAssert got.st == jsDone, got.error & " / " & got.wrote.reason
    doAssert got.wrote.referenceLoads == 1
    doAssert itemOf(got.wrote, "rec.sgy").outcome == boWritten
    let sig = itemOf(got.wrote, "ctrl.dat")
    doAssert sig.outcome == boWritten, sig.why
    var said = 0
    for line in sig.lines:
      if line == SignatureUncorrelated: inc said
    doAssert said == 1, $sig.lines
    var back = openSeismic(dest / "rec.sgy", keys = true)
    doAssert back.traceEntry(0).numSamples == 48
    back.close()

  doAssert readFile(segy) == sampleSegy and readFile(segd) == sampleSegd
  doAssert readFile(plain) == plainBytes and readFile(edited) == editedBytes and
    readFile(segdCopy) == segdBytes
  echo "toutputbatch: ok"

when isMainModule:
  main()
