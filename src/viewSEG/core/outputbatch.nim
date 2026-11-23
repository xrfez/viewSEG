## Writes many files of one folder as SEG-Y or SEG-D, one file at a time.
## A background job (`outputBatchWork`): each source is opened the way a
## session is, or taken from the caller when that file is already open, and
## written by the same writer as one file (`writeOutput`). The source is
## never modified. A file that cannot be written is recorded and the batch
## goes on. A destination folder that is the source folder, inside it, or
## holding it, is refused before anything is written.
##
## Submit it with `outputBatchSpec`. That spec does not touch the file
## system, so the UI thread may build it: the paths it lists are the
## strings given here, not resolved. `refuseOutputRoot` does read the file
## system (parent links), so a window calls it on a job, and this job calls
## it before the first write.

import std/[os, sets, strutils, tables, times]
import parseSEG
import edits, filejobs, filememory, filesystem, identity, jobs, outputjobs, session, threads

const BatchScale = 1_000_000 ## one file's share of the job's progress

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

  OpenFile* = tuple[path: string; file: ptr SeismicFile; edits: FileEdits]
    ## A file already open in the program: its path, the open file, and the
    ## edits to write. Used only when `path` is that item's `source`.

  Plan = object
    dest: string
    why: string

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

proc planDest(destRoot, relative: string; mirror: bool; format: OutputFormat): Plan =
  ## The destination of one relative path, or why it cannot be written.
  ## Strings only: no file system.
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
  let dest = changeFileExt(destRoot / leaf, extOf(format))
  if not stringInside(normalizedPath(dest), normalizedPath(destRoot)):
    return Plan(why: "The relative path leaves the destination folder.")
  Plan(dest: dest)

proc planned(ask: BatchAsk): seq[Plan] =
  ## Each item's destination. A second item that lands on a name already
  ## taken fails with a sentence; the first keeps the name. Strings only.
  result = newSeq[Plan](ask.items.len)
  var owner = initTable[string, string]()
  for i, item in ask.items:
    let plan = planDest(ask.destRoot, item.relative, ask.mirrorFolders, ask.options.format)
    if plan.why.len > 0 or plan.dest.len == 0:
      result[i] = plan
      if result[i].why.len == 0: result[i].why = "No destination was given."
    else:
      let key = destKey(plan.dest)
      if owner.hasKey(key):
        result[i] = Plan(dest: plan.dest, why: plan.dest.extractFilename &
          " is already the output of " & owner[key] & ".")
      else:
        owner[key] = item.relative
        result[i] = plan

proc outputBatchSpec*(ask: BatchAsk): JobSpec =
  ## The job that writes `ask`: background, reading each source, needing
  ## each planned destination to itself. Does not touch the file system.
  ## An open file passed to the job must use that item's `source` as its
  ## path, so `reads` keeps a close from taking it.
  var reads: seq[string] = @[]
  var exclusive: seq[string] = @[]
  var seen = initHashSet[string]()
  let plans = planned(ask)
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

proc refuseOutputRoot*(sourceRoot, destRoot: string): string =
  ## "" when `destRoot` may receive files from `sourceRoot`. Equal to the
  ## source folder, inside it, or holding it: one sentence, and nothing
  ## should be written. Reads the file system (parent links): not for the
  ## UI thread.
  if destRoot.len == 0: return "No destination folder was given."
  if sourceRoot.len == 0: return "No source folder was given."
  let src = canonPath(sourceRoot)
  let dest = canonPath(destRoot)
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

proc savedEdits(store: Store; path: string; modified: Time; lines: var seq[string]): FileEdits =
  ## The edits a session would bring back at once: the store record of this
  ## file's quick identity whose modification time is `modified`. A record
  ## that waits on the hash of every byte, an unconfirmed one, and a pending
  ## one are not applied. A store that cannot be read is a note, not a failure.
  if store.isNowhere or path.len == 0: return
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
  var matched = false
  var other = false
  var unconfirmed = false
  for c in records:
    if c.unconfirmed:
      unconfirmed = true
    elif not matched and c.modified == modified:
      result.remembered(c.edits)
      matched = true
    else:
      other = true
  if not matched and unconfirmed:
    lines.add "Saved edits were left unconfirmed, so they were not applied."
  elif not matched and other:
    lines.add "Saved edits were not applied: none match this file's time."

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
  let refused = refuseOutputRoot(ask.root, ask.destRoot)
  if refused.len > 0: failBatch(sink, refused)
  let count = ask.items.len
  if count == 0: return
  if ctx.cancelled:
    if sink != nil: sink.result.cancelled = true
    raise newException(JobCancelledError, "Cancelled.")
  let plans = planned(ask)
  var willWrite = false
  for p in plans:
    if p.why.len == 0: willWrite = true
  if willWrite: ensureRoot(sink, ask.destRoot)
  var guard: seq[string] = @[]
  for o in openFiles:
    if o.path.len > 0: guard.add o.path
  for item in ask.items:
    if item.source.len > 0: guard.add item.source
  var doneFiles = 0
  for i, item in ask.items:
    ctx.setPhase(filePhase(i, count, item.relative))
    if ctx.cancelled: stopBatch(sink, ask, plans, i)
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
      for d in newDirs(plans[i].dest, ask.destRoot):
        fs.createDir(d)
        made.add d
      var file: ptr SeismicFile = nil
      var edits: FileEdits
      let at = passed(openFiles, item.source)
      if at >= 0:
        file = openFiles[at].file
        edits = openFiles[at].edits
      else:
        let progress = proc (done, total: int64): bool {.gcsafe, raises: [].} =
          ctx.progress(int64(doneFiles) * BatchScale + shareOf(done, total),
            int64(count) * BatchScale)
        s = openSession(item.source, progress)
        file = s.filePtr
        edits = savedEdits(store, item.source, s.modified, itemLines)
      if ctx.cancelled: raise newException(JobCancelledError, "Cancelled.")
      outSink = OutputSink()
      let report = proc (done, total: int): bool {.gcsafe.} =
        ctx.progress(int64(doneFiles) * BatchScale + shareOf(int64(done), int64(total)),
          int64(count) * BatchScale)
      {.cast(gcsafe).}:
        writeOutput(ctx, file, item.source, plans[i].dest, ask.options, edits, guard,
          outSink, report)
      var lines = itemLines
      for x in outSink.result.lines: lines.add x
      note(sink, item.relative, plans[i].dest, boWritten, outSink.result.written,
        outSink.result.dropped, lines, "")
    except JobCancelledError:
      dropEmpty(made)
      note(sink, item.relative, plans[i].dest, boSkipped, 0, 0, itemLines, cancelWhy(outSink))
      stopBatch(sink, ask, plans, i + 1)
    except SegCancelledError:
      dropEmpty(made)
      note(sink, item.relative, plans[i].dest, boSkipped, 0, 0, itemLines, "Cancelled.")
      stopBatch(sink, ask, plans, i + 1)
    except CatchableError as e:
      if ctx.cancelled:
        dropEmpty(made)
        note(sink, item.relative, plans[i].dest, boSkipped, 0, 0, itemLines,
          cancelWhy(outSink))
        stopBatch(sink, ask, plans, i + 1)
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
  ## opened and closed here, and its saved edits are the store record a
  ## session would bring back at once (the same quick identity and
  ## modification time). One file is open at a time. One file failing does
  ## not stop the batch. A cancel stops between files and inside a file,
  ## removes the current part file, leaves finished files, and says how many
  ## were written. `sink.result` is set before the job returns, fails or is
  ## cancelled.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      runBatch(ctx, ask, store, openFiles, sink)
