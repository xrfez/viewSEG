## Writes many files of one folder as SEG-Y or SEG-D, one file at a time.
## A background job (`outputBatchWork`): each source is opened the way the
## application opens it by kind, or taken from the caller when that file is
## already open, and written by the same writer as one file (`writeOutput`).
## A vibrator signature file that is not already open is decoded in memory
## (`openSignature`) and dropped after the write. The source is never
## modified. A file that cannot be written, or a signature file that cannot
## be decoded, is recorded and the batch goes on. A destination folder that
## is the source folder, inside it, or holding it, is refused before anything
## is written. A file this job opens is not joined to the project survey and
## does not take station moves; the result says the batch wrote that file's
## own positions. A file already open is written as the session holds it.
##
## Submit it with `outputBatchSpec`. That spec does not touch the file
## system, so the UI thread may build it: the paths it lists are the
## strings given here, not resolved. `refuseOutputRoot` does read the file
## system (the destination's own links, and the nearest existing ancestor
## when it is not there yet), so a window calls it on a job, and this job
## calls it before the first write.

import std/[os, sets, strutils, tables, times]
import parseSEG
import edits, filejobs, filekinds, filememory, filesystem, identity, jobs, outputjobs,
  session, signatures, sigtypes, threads

const
  BatchScale = 1_000_000 ## one file's share of the job's progress
  BatchOwnPositions* = "The batch wrote the file's own positions."
    ## A file this job opened itself was not joined and took no station move.

type
  BatchItem* = object
    ## One file of the folder.
    source*: string
      ## absolute path
    relative*: string
      ## path relative to the source root, sub folders kept

  BatchOutcome* = enum
    ## What happened to one file. `$` is the word.
    boWritten = "written"
    boSkipped = "skipped"
    boFailed = "failed"

  BatchItemResult* = object
    ## One file's outcome.
    relative*: string
    destination*: string
    outcome*: BatchOutcome
    writtenTraces*: int
    droppedTraces*: int
    lines*: seq[string] ## the writer's diagnostics, and notes about saved edits
    why*: string        ## a sentence when this file was not written; "" when it was

  BatchAsk* = object
    ## What to write. `options` is the one set every file is written with,
    ## the same `OutputOptions` `outputWork` takes, including `processing`.
    root*: string
    items*: seq[BatchItem]
    destRoot*: string
    options*: OutputOptions
    mirrorFolders*: bool
      ## true: `destRoot / relative` with the new extension, creating sub
      ## folders. false: every file in `destRoot`; a second file that would
      ## take a name already used is a failure of that file, not an overwrite.

  BatchResult* = object
    ## What the batch did. `reason` is set when the batch itself was refused,
    ## before any file was written. Read it after the job is no longer running.
    items*: seq[BatchItemResult]
    written*: int
    skipped*: int
    failed*: int
    writtenTraces*: int
    droppedTraces*: int
    cancelled*: bool
    reason*: string

  BatchSink* = ref object
    ## Filled when the job ends, including when it fails or is cancelled.
    result*: BatchResult

  OpenFile* = tuple[path: string; file: ptr SeismicFile; edits: FileEdits;
    signature: SignatureFacts]
    ## A file already open in the program: its path, the open file, the edits
    ## to write, and its signature facts (empty for any other file). Used only
    ## when `path` is that item's `source`.

  Plan = object
    dest: string
    why: string
    note: string

func extOf(format: OutputFormat): string =
  if format == ofSegy: ".sgy" else: ".sgd"

func withSep(path: string): string =
  result = newStringOfCap(path.len)
  for c in path:
    if c == AltSep: result.add DirSep
    else: result.add c

func destKey(path: string): string =
  when defined(windows): path.toLowerAscii
  else: path

func stringInside(path, folder: string): bool =
  ## Whether `path` lies inside `folder`, by the strings only.
  if folder.len == 0: return false
  let prefix = if folder.endsWith(DirSep): folder else: folder & DirSep
  when defined(windows): path.toLowerAscii.startsWith(prefix.toLowerAscii)
  else: path.startsWith(prefix)

proc planDest(destRoot, relative: string; mirror: bool; format: OutputFormat;
    keepExt = false): Plan =
  ## The destination of one relative path, or why it cannot be written.
  ## Strings only: no file system. `keepExt` appends the output extension
  ## and leaves the source extension in the name.
  if relative.len == 0: return Plan(why: "No relative path was given.")
  if isAbsolute(relative): return Plan(why: "The relative path is absolute.")
  let rel = withSep(relative)
  for part in rel.split({DirSep}):
    if part == "..":
      return Plan(why: "The relative path leaves the destination folder.")
  let leaf = if mirror: rel else: rel.extractFilename
  let name = leaf.extractFilename
  if name.len == 0 or name == "." or name == "..":
    return Plan(why: "The relative path leaves the destination folder.")
  if destRoot.len == 0: return Plan(why: "No destination folder was given.")
  let dest = if keepExt: destRoot / (leaf & extOf(format))
             else: changeFileExt(destRoot / leaf, extOf(format))
  if not stringInside(normalizedPath(dest), normalizedPath(destRoot)):
    return Plan(why: "The relative path leaves the destination folder.")
  Plan(dest: dest)

func isSignature(kinds: openArray[FileKind]; i: int): bool =
  ## Whether item `i` is a signature file. A missing kind is not one.
  i < kinds.len and kinds[i] in SignatureFileKinds

proc planned(ask: BatchAsk; kinds: openArray[FileKind]): seq[Plan] =
  ## Each item's destination. A second item that lands on a name already
  ## taken fails with a sentence; the first keeps the name. When two or more
  ## signature files would land on one name, those files keep the source
  ## extension, so they are not written as one file. A file that is not a
  ## signature file keeps the replaced extension. `kinds[i]` is item i's
  ## kind, told from its first bytes; a shorter `kinds` means the kind is
  ## not known yet (no file is read here). The sentence is attached only
  ## when that item's name actually changed. Strings only.
  result = newSeq[Plan](ask.items.len)
  var byDest = initTable[string, seq[int]]()
  for i, item in ask.items:
    let plan = planDest(ask.destRoot, item.relative, ask.mirrorFolders,
      ask.options.format)
    result[i] = plan
    if plan.why.len > 0 or plan.dest.len == 0:
      if result[i].why.len == 0: result[i].why = "No destination was given."
    else:
      let key = destKey(plan.dest)
      var row = byDest.getOrDefault(key)
      row.add i
      byDest[key] = row
  for _, idxs in byDest.pairs:
    var sigs = 0
    for i in idxs:
      if isSignature(kinds, i): inc sigs
    if sigs >= 2:
      for i in idxs:
        if isSignature(kinds, i):
          let before = result[i].dest
          var plan = planDest(ask.destRoot, ask.items[i].relative,
            ask.mirrorFolders, ask.options.format, keepExt = true)
          if plan.why.len == 0 and plan.dest.len > 0:
            if plan.dest != before:
              plan.note = "The source extension was kept in the name so two " &
                "signature files are not written as one file."
          elif plan.why.len == 0:
            plan.why = "No destination was given."
          result[i] = plan
  var owner = initTable[string, string]()
  for i, item in ask.items:
    if result[i].why.len == 0 and result[i].dest.len > 0:
      let key = destKey(result[i].dest)
      if owner.hasKey(key):
        result[i] = Plan(dest: result[i].dest, why: result[i].dest.extractFilename &
          " is already the output of " & owner[key] & ".")
      else:
        owner[key] = item.relative

proc outputBatchSpec*(ask: BatchAsk): JobSpec =
  ## The job that writes `ask`: background, reading each source, needing
  ## each planned destination to itself. Does not touch the file system,
  ## so no kind is known and a kept extension is not in these names; the
  ## job plans again from each file's first bytes. An open file passed to
  ## the job must use that item's `source` as its path, so `reads` keeps a
  ## close from taking it.
  var reads: seq[string] = @[]
  var exclusive: seq[string] = @[]
  var seen = initHashSet[string]()
  let plans = planned(ask, [])
  for i, item in ask.items:
    if item.source.len > 0: reads.add item.source
    if i < plans.len and plans[i].why.len == 0 and plans[i].dest.len > 0:
      let key = destKey(plans[i].dest)
      if key notin seen:
        seen.incl key
        exclusive.add plans[i].dest
  let name = ask.destRoot.extractFilename
  JobSpec(title: if name.len == 0: "Write files" else: "Write files to " & name,
    lane: jlBackground, reads: reads, exclusive: exclusive)

proc resolvedRoot(path: string): string =
  ## Absolute path, with this path's own links resolved. An existing path is
  ## the seam's `expandFilename`. A path that is not there yet is its nearest
  ## existing ancestor resolved, with the missing parts joined. Reads the
  ## file system: not for the UI thread.
  if path.len == 0: return ""
  try:
    return fs.expandFilename(path).normalizedPath
  except OSError, ValueError:
    discard
  var abs = path
  try:
    abs = absolutePath(path)
  except OSError, ValueError:
    discard
  abs = abs.normalizedPath
  var missing: seq[string] = @[]
  var cur = abs
  var guard = 0
  while cur.len > 0 and guard < 64:
    inc guard
    let name = cur.extractFilename
    let parent = cur.parentDir
    if parent == cur or parent.len == 0 or name.len == 0: break
    missing.add name
    if fs.dirExists(parent) or fs.fileExists(parent):
      var base = parent
      try:
        base = fs.expandFilename(parent)
      except OSError, ValueError:
        discard
      base = base.normalizedPath
      for i in countdown(missing.high, 0):
        base = base / missing[i]
      return base.normalizedPath
    cur = parent
  abs

proc refuseOutputRoot*(sourceRoot, destRoot: string): string =
  ## "" when `destRoot` may receive files from `sourceRoot`. The destination
  ## is resolved first (its own links, not only its parent's): equal to the
  ## source folder, inside it, or holding it, one sentence, and nothing
  ## should be written. Reads the file system: not for the UI thread.
  if destRoot.len == 0: return "No destination folder was given."
  if sourceRoot.len == 0: return "No source folder was given."
  let src = resolvedRoot(sourceRoot)
  let dest = resolvedRoot(destRoot)
  if pathsEqual(src, dest): return "The destination folder is the source folder."
  if pathInside(dest, src):
    return "The destination folder is inside the source folder."
  if pathInside(src, dest):
    return "The source folder is inside the destination folder."

proc failBatch(sink: BatchSink; why: string) =
  if sink != nil:
    if sink.result.items.len == 0: sink.result.items = @[]
    sink.result.reason = why
  raise newException(ValueError, why)

proc note(sink: BatchSink; relative, dest: string; outcome: BatchOutcome;
    written, dropped: int; lines: seq[string]; why: string) =
  if sink == nil: return
  sink.result.items.add BatchItemResult(relative: relative, destination: dest,
    outcome: outcome, writtenTraces: written, droppedTraces: dropped, lines: lines,
    why: why)
  case outcome
  of boWritten:
    inc sink.result.written
    sink.result.writtenTraces += written
    sink.result.droppedTraces += dropped
  of boSkipped: inc sink.result.skipped
  of boFailed: inc sink.result.failed

proc skipFrom(sink: BatchSink; ask: BatchAsk; plans: seq[Plan]; frm: int) =
  for j in frm ..< ask.items.len:
    let dest = if j < plans.len: plans[j].dest else: ""
    note(sink, ask.items[j].relative, dest, boSkipped, 0, 0, @[], "Cancelled.")

proc stopBatch(sink: BatchSink; ask: BatchAsk; plans: seq[Plan]; frm: int) =
  skipFrom(sink, ask, plans, frm)
  if sink != nil: sink.result.cancelled = true
  raise newException(JobCancelledError, "Cancelled.")

func shareOf(done, total: int64): int64 =
  ## `done` of `total` as a share of one file's progress, never a whole file.
  if total <= 0 or done <= 0: return 0
  if done >= total: return BatchScale - 1
  let scaled = int64(float64(done) / float64(total) * float64(BatchScale))
  if scaled >= BatchScale: BatchScale - 1 else: scaled

proc filePhase(i, n: int; relative: string): string =
  "file " & $(i + 1) & " of " & $n & ": " & relative.extractFilename

proc passed(openFiles: seq[OpenFile]; source: string): int =
  ## The open file whose path is `source`, or -1. A nil file is not open.
  result = -1
  if source.len == 0: return
  let want = canonPath(source)
  for i, o in openFiles:
    if o.file == nil or o.path.len == 0: continue
    if pathsEqual(o.path, source) or pathsEqual(canonPath(o.path), want): return i

proc fileStill(path: string; id: FileIdentity; modified: Time): bool =
  ## Whether `path` still has quick identity `id` and time `modified`.
  var now: Time
  let got = quickIdentity(path, now)
  got.size == id.size and got.quick == id.quick and now == modified

proc contentHash(ctx: JobContext; path: string; id: FileIdentity; modified: Time;
    doneFiles, count: int): uint64 =
  ## The hash of every byte, the proc a session uses, on this job's thread.
  ## A cancel stops the read (`IOError`, "stopped"). A file that changed
  ## before or during the read raises `IOError`.
  if not fileStill(path, id, modified):
    raise newException(IOError, "it changed since it was opened")
  let progress = proc (done, total: int64): bool {.gcsafe, raises: [].} =
    if ctx.cancelled: return false
    ctx.progress(int64(doneFiles) * BatchScale + shareOf(done, total),
      int64(count) * BatchScale)
  result = fullHash(path, progress)
  if not fileStill(path, id, modified):
    raise newException(IOError, "it changed while it was read")

proc savedEdits(ctx: JobContext; store: Store; path: string; modified: Time;
    lines: var seq[string]; doneFiles, count: int): FileEdits =
  ## The edits a session would bring back once the hash of every byte is
  ## known: a record whose stored hash equals this file's, or, when the
  ## record has no such hash, the one whose modification time is `modified`.
  ## A stored hash that differs is not applied. An unconfirmed record and a
  ## pending one are not applied. Exactly one line says what was applied,
  ## that none was found, or why edits were left out. A pending document is
  ## not read. A store that cannot be read is a note, not a failure.
  if store.isNowhere or path.len == 0:
    lines.add "no saved edits were found for this file"
    return
  if fs.fileExists(store.docPath(pendingName(path))):
    lines.add "this file has edits that were not yet saved to its document: not applied"
    return
  var seen: Time
  var id: FileIdentity
  try:
    id = quickIdentity(path, seen)
  except IOError, OSError:
    lines.add "Saved edits were not read (" & getCurrentExceptionMsg() & ")."
    return
  if seen != modified:
    lines.add "The file changed while it was opened; saved edits were not applied."
    return
  var taken: seq[string] = @[]
  var problems: seq[string] = @[]
  var records: seq[FileRecord] = @[]
  try:
    records = store.recordsOf(id, taken, problems)
  except OSError as e:
    lines.add "Saved edits were not read (" & e.msg & ")."
    return
  for p in problems: lines.add p
  var needHash = false
  for c in records:
    if not c.unconfirmed and c.identity.fullKnown: needHash = true
  var hashed = false
  var full: uint64
  if needHash:
    try:
      full = contentHash(ctx, path, id, modified, doneFiles, count)
      hashed = true
    except IOError as e:
      if e.msg == "stopped" or ctx.cancelled:
        raise newException(JobCancelledError, "Cancelled.")
      if "changed" in e.msg:
        lines.add "The file changed while it was opened; saved edits were not applied."
      else:
        lines.add "Saved edits were not read (" & e.msg & ")."
      return
    except OSError as e:
      lines.add "Saved edits were not read (" & e.msg & ")."
      return
  var hashHit = -1
  var timeHit = -1
  var hashMiss = false
  var other = false
  var unconfirmed = false
  for i, c in records:
    if c.unconfirmed:
      unconfirmed = true
    elif hashed and c.identity.fullKnown and c.identity.full == full:
      if hashHit < 0 or c.modified == modified: hashHit = i
    elif c.modified == modified and not c.identity.fullKnown:
      if timeHit < 0: timeHit = i
    elif c.modified == modified and c.identity.fullKnown:
      hashMiss = true
    else:
      other = true
  var applied: EditLists
  var matched = false
  if hashHit >= 0:
    applied = records[hashHit].edits
    result.remembered(applied)
    matched = true
  elif timeHit >= 0:
    applied = records[timeHit].edits
    result.remembered(applied)
    matched = true
  if matched:
    lines.add "applied this file's saved edits: " & keptWords(applied)
  elif hashMiss:
    lines.add "saved edits belong to a file with other content: not applied"
  elif unconfirmed:
    lines.add "Saved edits were left unconfirmed, so they were not applied."
  elif other:
    lines.add "Saved edits were not applied: none match this file's time."
  else:
    lines.add "no saved edits were found for this file"

proc newDirs(dest, destRoot: string): seq[string] =
  ## Folders from `dest`'s parent up to, not including, `destRoot` that do
  ## not exist yet, shallowest first.
  result = @[]
  if dest.len == 0 or destRoot.len == 0: return
  let root = canonPath(destRoot)
  var chain: seq[string] = @[]
  var dir = dest.parentDir
  var guard = 0
  while dir.len > 0 and guard < 64:
    inc guard
    let here = canonPath(dir)
    if pathsEqual(here, root) or not pathInside(here, root): break
    chain.add dir
    let parent = dir.parentDir
    if parent == dir or parent.len == 0: break
    dir = parent
  for i in countdown(chain.high, 0):
    if not fs.dirExists(chain[i]): result.add chain[i]

proc dropEmpty(dirs: seq[string]) =
  ## Removes `dirs` deepest first, and only when empty. Never a folder that
  ## still holds a file.
  for i in countdown(dirs.high, 0):
    if fs.dirExists(dirs[i]): discard fs.tryRemoveDir(dirs[i])

proc ensureRoot(sink: BatchSink; destRoot: string) =
  if fs.fileExists(destRoot) and not fs.dirExists(destRoot):
    failBatch(sink, "The destination is a file.")
  if not fs.dirExists(destRoot):
    try:
      fs.createDir(destRoot)
    except OSError, IOError:
      failBatch(sink, "The destination folder could not be created (" &
        getCurrentExceptionMsg() & ").")

proc cancelWhy(outSink: OutputSink): string =
  if outSink != nil and outSink.result.reason.len > 0: outSink.result.reason
  else: "Cancelled."

proc runBatch(ctx: JobContext; ask: BatchAsk; store: Store; openFiles: seq[OpenFile];
    sink: BatchSink) =
  if sink != nil: sink.result = BatchResult(items: @[])
  let destRoot = resolvedRoot(ask.destRoot)
  var writing = ask
  writing.destRoot = destRoot
  let refused = refuseOutputRoot(writing.root, writing.destRoot)
  if refused.len > 0: failBatch(sink, refused)
  let count = writing.items.len
  if count == 0: return
  var kinds = newSeq[FileKind](count)
  for i, item in writing.items:
    if item.source.len > 0:
      kinds[i] = sniff(item.source)
  let plans = planned(writing, kinds)
  if ctx.cancelled: stopBatch(sink, writing, plans, 0)
  var willWrite = false
  for p in plans:
    if p.why.len == 0: willWrite = true
  if willWrite: ensureRoot(sink, writing.destRoot)
  var guard: seq[string] = @[]
  for o in openFiles:
    if o.path.len > 0: guard.add o.path
  for item in writing.items:
    if item.source.len > 0: guard.add item.source
  var doneFiles = 0
  for i, item in writing.items:
    ctx.setPhase(filePhase(i, count, item.relative))
    if ctx.cancelled: stopBatch(sink, writing, plans, i)
    discard ctx.progress(int64(doneFiles) * BatchScale, int64(count) * BatchScale)
    if plans[i].why.len > 0:
      note(sink, item.relative, plans[i].dest, boFailed, 0, 0, @[], plans[i].why)
      inc doneFiles
      discard ctx.progress(int64(doneFiles) * BatchScale, int64(count) * BatchScale)
      continue
    var made: seq[string] = @[]
    var s: Session = nil
    var outSink: OutputSink = nil
    var itemLines: seq[string] = @[]
    try:
      for d in newDirs(plans[i].dest, writing.destRoot):
        fs.createDir(d)
        made.add d
      var file: ptr SeismicFile = nil
      var edits: FileEdits
      var signature = SignatureFacts()
      let at = passed(openFiles, item.source)
      if at >= 0:
        file = openFiles[at].file
        edits = openFiles[at].edits
        signature = openFiles[at].signature
      else:
        let progress = proc (done, total: int64): bool {.gcsafe, raises: [].} =
          ctx.progress(int64(doneFiles) * BatchScale + shareOf(done, total),
            int64(count) * BatchScale)
        let kind = kinds[i]
        if kind in SignatureFileKinds:
          s = openSignature(item.source)
        elif kind == fkUnknown:
          let why = refusalOf(item.source)
          if why.len > 0: raise newException(SignatureError, why)
          s = openSession(item.source, progress)
        else:
          s = openSession(item.source, progress)
        file = s.filePtr
        edits = savedEdits(ctx, store, item.source, s.modified, itemLines, doneFiles, count)
        itemLines.add BatchOwnPositions
      if plans[i].note.len > 0: itemLines.add plans[i].note
      if ctx.cancelled: raise newException(JobCancelledError, "Cancelled.")
      outSink = OutputSink()
      let report = proc (done, total: int): bool {.gcsafe.} =
        ctx.progress(int64(doneFiles) * BatchScale + shareOf(int64(done), int64(total)),
          int64(count) * BatchScale)
      {.cast(gcsafe).}:
        writeOutput(ctx, file, item.source, plans[i].dest, writing.options, edits, guard,
          outSink, report, signature)
      var lines = itemLines
      for x in outSink.result.lines: lines.add x
      note(sink, item.relative, plans[i].dest, boWritten, outSink.result.written,
        outSink.result.dropped, lines, "")
    except JobCancelledError:
      dropEmpty(made)
      note(sink, item.relative, plans[i].dest, boSkipped, 0, 0, itemLines, cancelWhy(outSink))
      stopBatch(sink, writing, plans, i + 1)
    except SegCancelledError:
      dropEmpty(made)
      note(sink, item.relative, plans[i].dest, boSkipped, 0, 0, itemLines, "Cancelled.")
      stopBatch(sink, writing, plans, i + 1)
    except CatchableError as e:
      if ctx.cancelled:
        dropEmpty(made)
        note(sink, item.relative, plans[i].dest, boSkipped, 0, 0, itemLines,
          cancelWhy(outSink))
        stopBatch(sink, writing, plans, i + 1)
      dropEmpty(made)
      var lines = itemLines
      var why = if e.msg.len > 0: e.msg else: $e.name
      if outSink != nil and outSink.result.reason.len > 0:
        why = outSink.result.reason
        for x in outSink.result.lines: lines.add x
      note(sink, item.relative, plans[i].dest, boFailed, 0, 0, lines, why)
    finally:
      s = nil
      clearCycleRoots()
    inc doneFiles
    discard ctx.progress(int64(doneFiles) * BatchScale, int64(count) * BatchScale)

proc outputBatchWork*(ask: BatchAsk; store: Store; openFiles: seq[OpenFile];
    sink: BatchSink): JobWork =
  ## Writes each of `ask.items` in order, on a job thread (`outputBatchSpec`).
  ## A file in `openFiles` whose path is that item's source is written as it
  ## stands, edits included, and is not closed here; every other file is
  ## opened and closed here (a signature file through `openSignature`, with
  ## the default choice), and its saved edits are the store record a
  ## session would bring back once the hash of every byte agrees (or, when
  ## that hash was not stored, the same quick identity and modification
  ## time). One file is open at a time. One file failing, including a
  ## signature file that cannot be decoded, does
  ## not stop the batch. A cancel stops before the first file, between files
  ## and inside a file, and every file not written is listed as skipped. It
  ## removes the current part file, leaves finished files, and says how many
  ## were written. `sink.result` is set before the job returns, fails or is
  ## cancelled.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      runBatch(ctx, ask, store, openFiles, sink)
