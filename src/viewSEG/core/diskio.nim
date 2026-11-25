## The thread that reads and writes the program's own files, so the UI
## thread never waits for a disk: the session log, appended to as the log
## grows; documents (the settings, layouts) replaced whole; and documents
## the user imports, read.
##
## The UI thread only leaves work under a lock (`append`, `replace`,
## `prune`, `read`) and goes on; the thread does it in order. What it could
## not do comes back as a warning through the inbox, in plain words, and a
## document read comes back as an `mkRead` message.
##
## - **Replace** writes a document atomically: to a temporary file next to
##   it, flushed to the disk, then renamed over it, so a crash or a full
##   disk leaves the old document or the new one, never half of one. A
##   replace of a path waiting to be written takes the place of the one
##   before it: only the newest is written.
## - **Append** adds text to the end of a file, kept open between appends
##   and flushed after each, so a crash keeps every line written. When a
##   file cannot be written, that is said once, and nothing more is tried
##   for it until an append to another file.
## - **Log entries** given to an append or a replace are written as the
##   session log's lines (`fileLine`) here, not on the UI thread: a line
##   costs a few microseconds (the local time zone), so a full log is a
##   tenth of a second.
## - **Prune** keeps the newest files of a folder whose names match.
## - **Remove** deletes one of the program's own files (a document of what
##   is remembered about a file), and takes the place of a replace of it
##   waiting to be written.
## - **Two programs, one document.** A document of what is remembered may
##   be written by a second viewSEG at the same time (the same file open in
##   both). Before it replaces (or removes) one, the thread compares the
##   document's size and modification time with those this run read or
##   wrote last; when they moved, it reads the other's and writes both
##   programs' edits (`merged`, from what this run had last), and posts the
##   result (`mkMemoryMerged`) so the screen shows them too. From that look
##   to the stamp taken after the rename it holds the store's lock between
##   programs (`StoreLockSuffix`), so that no other viewSEG writes the
##   document in between, which would lose one of the two changes.
## - **What a file is treated as.** The `treat` node of a document of the
##   store (`core/treatas`) has one writer: a treat (`treat`), which reads the
##   document as it is then, under the store's lock, sets the parts of that node
##   the user changed (the kind, the grouping, the sort: each on its own, so a
##   second viewSEG's choice of another part stays) and writes it back (or writes a new document, or removes one left with
##   nothing). Every other write of a document keeps the node as it is on
##   disk: as this thread last wrote it, else as the UI thread last read it,
##   else, when another program changed the document, as that one left it.
## - **Read** reads a whole file up to a size, and posts it (or why it could
##   not be read) for the UI thread, with its NIF tree (`parseNif`) or why
##   it is not NIF, so the UI thread only takes in a tree.
## - **Sweep** removes the temporary files of the store of what is
##   remembered (`<document>.<process id>.tmp`) that a write cut short left
##   (the program killed between the write and the rename): only in that
##   folder, only names of the store's own documents, and only those last
##   written `SweepMargin` or more before the program started. A write takes
##   milliseconds, so such a file is never one another viewSEG is writing.
##
## The thread takes one task at a time, in order; a task left `first` (the
## settings and the layout at the quit) goes before those waiting.
##
## `flush` waits until everything left so far is done (tests); `stop` (and
## destroying the `DiskIo`) does what is left, then ends the thread, waiting
## for it until a deadline only: a slow disk that goes on writing is waited
## for, but a configuration or log folder on a drive that does not answer
## must not hold the quit. A drive answers when, before a task, the thread
## looks at the task's folder and the look comes back (or a task in that
## folder ended before); a task whose folder has not answered is given only
## `stuckAfter`. The thread is then left to end on its own, with its memory,
## and what it had left is not written (`stuckOn` says what it was held
## on). While it is held so, the tasks left `first` (the settings and the
## layout at the quit) are written by a thread of their own, so a drive that
## held the thread before the quit does not keep them from their folder.

import std/[algorithm, locks, monotimes, os, strutils, tables, times]
import edits, filememory, filesystem, inbox, jobs, layouts, log, nif, threads, treatas

when not defined(windows):
  import std/posix

type
  TaskKind = enum
    tkAppend, tkReplace, tkPrune, tkRead, tkList, tkRemove, tkSweep, tkTreat

  Task = object
    kind: TaskKind
    path: string           ## the file; for a prune, the folder
    text: string           ## what to write; for a prune, the names' start
    entries: seq[LogEntry] ## an append or a replace: written after `text`, a line each
    what: string           ## what the file is, for a message: "the settings"
    failNote: string       ## appended to a failed save, when not ""
    keep: int              ## a prune: how many to keep
    suffix: string         ## a prune: the names' end
    spare: string          ## a prune: a file never removed
    done: string           ## a replace: what to say once it is written ("" for nothing)
    fresh: bool            ## a replace: under a name no file has (`-2`, `-3` ... before the extension)
    purpose: ReadPurpose   ## a read: what for
    limit: int             ## a read: the largest file read, in bytes
    dirs: seq[string]      ## a list of the layouts: the folders of the presets
    memory: FileRecord     ## a replace with `render`, a treat: the document's record (`treatFor`)
    render: bool           ## a replace: the text is `memoryDocument(memory)`, made here
    before: times.Time     ## a sweep: the files last written before this are removed
    merging: bool
      ## a replace with `render`, or a remove: a document of the store,
      ## merged with another program's change (`base`, `expect`)
    base: EditLists ## `merging`: the edits the document held as this run read or wrote it
    expect: DocStamp ## `merging`: its stamp then; size -1 for no document
    parts: set[TreatPart] ## a treat: the parts of `memory.treat` it sets
    src: string ## a treat that moves: the document the parts come from, left once it is done
    srcRec: FileRecord ## ... its record, with no treat
    leave: set[TreatPart] ## ... the parts taken from it
    srcStamp: DocStamp ## ... its stamp as this run last read it
    first: bool ## left before the tasks waiting (after those left so before it)

  DiskObj = object
    lock: Lock
    changed, idle: Cond
    tasks: seq[Task]
    busy, quit, started, ended, abandoned: bool
    since: MonoTime       ## `busy`: when the task in hand was taken
    current: string       ## `busy`: what it writes, and where ("the settings (/home/...)")
    answering: bool       ## `busy`: the task's folder answered (`answered`, or a look just now)
    holding: string       ## `busy`: the file of the task in hand
    answered: seq[string] ## the folders a task ended in, this run
    helper: Thread[ptr DiskObj]
      ## writes the tasks left `first` while the thread is held (`stop`)
    helperStarted, helperEnded, helperBusy, helperAnswering: bool
    helperSince: MonoTime
    helperCurrent: string
    poster: Poster
    thread: Thread[ptr DiskObj]

  DiskIo* = object
    ## The disk thread. Move-only; destroying it does what is left, then
    ## stops the thread. A default `DiskIo` is none: work given to it is
    ## dropped.
    p: ptr DiskObj

  Writer = object
    ## The thread's own state.
    d: ptr DiskObj
    log: File      ## the file appended to last; nil for none
    logPath: string
    failed: string ## the file an append failed on last; "" for none
    written: Table[string, tuple[stamp: DocStamp; edits: EditLists; treat: TreatAs]]
      ## the documents of the store written (or removed) here: their stamp
      ## after it, and the edits and the `treat` they held

proc `=destroy`*(x: DiskIo)
proc `=wasMoved`*(x: var DiskIo) = x.p = nil
proc `=copy`*(dest: var DiskIo; src: DiskIo) {.error.}
proc `=dup`*(src: DiskIo): DiskIo {.error.}

func isNil*(x: DiskIo): bool {.inline.} =
  ## Whether `x` is none (never started).
  x.p == nil

# ------------------------------------------------------------ the thread --

proc say(w: Writer; severity: Severity; text: string) =
  w.d.poster.post Msg(job: NoJob, kind: mkLog, entry: LogEntry(time: getTime(),
    severity: severity, source: "files", text: text))

proc warn(w: Writer; text: string) = w.say(sevWarning, text)

proc body(t: Task): string =
  ## What `t` writes: its text (or its record's document), then its log
  ## entries, a line each.
  result = if t.render: memoryDocument(t.memory) else: t.text
  for e in t.entries: result.add fileLine(e)

proc freshName(path: string): string =
  ## `path`, or, when a file has that name, the first of `<stem>-2<ext>`,
  ## `<stem>-3<ext>` ... that none has.
  result = path
  let (dir, name, ext) = path.splitFile
  var n = 2
  while fs.fileExists(result):
    result = dir / name & "-" & $n & ext
    inc n

const NoDoc* = (size: -1'i64, modified: times.Time(), file: 0'i64)
  ## the stamp of a document that is not there

proc stampOf(path: string): DocStamp =
  ## The size and modification time of `path`; size -1 when there is none.
  try:
    let info = fs.getFileInfo(path)
    (info.size, info.lastWriteTime, int64(info.id.file))
  except OSError:
    NoDoc

proc mergeOthers(w: var Writer; t: var Task; removing: bool): bool =
  ## For a document of the store (`t.merging`): when another program
  ## changed it since this run read or wrote it, its edits and those of
  ## `t` merged into `t.memory`, and posted. False when it changed and
  ## cannot be read: nothing is written then.
  ## The `treat` of `t.memory` becomes the document's as it is on disk (the module
  ## documentation): only a treat changes it.
  result = true
  var (expect, base) = (t.expect, t.base)
  if t.path in w.written: (expect, base, t.memory.treat) = w.written[t.path]
  let now = stampOf(t.path)
  if now == expect: return
  var theirs = FileRecord()
  if now.size >= 0:
    try:
      var problems: seq[string]
      theirs = readMemoryFile(t.path, problems)
      if theirs.damaged:
        raise newException(NifError, "it has parts this version cannot read")
      template a: untyped = theirs.identity
      template b: untyped = t.memory.identity
      if t.path.extractFilename.isPendingName and (a.size != b.size or
          theirs.path != t.memory.path or theirs.modified != t.memory.modified):
        # an earlier run's edits of the file at that path as it was then:
        # they would not be applied (`takePending`), so they are said and
        # written over
        var lists: seq[string]
        for edit in [teKilled, teReversed, teExcluded]:
          if theirs.edits.lists[edit].len > 0:
            lists.add $edit & " " & runsText(theirs.edits.lists[edit])
        if theirs.edits.filters.len > 0:
          lists.add $theirs.edits.filters.len & " filtered"
        if theirs.edits.allReversed: lists.add "all reversed"
        w.warn("The edits of " & t.memory.name & " kept by its path in an earlier run are " &
          "not applied: it changed since (its size or time is not the same). They were: " &
          lists.join("; ") & ".")
        return
      if a.size != b.size or a.quick != b.quick or (a.fullKnown and b.fullKnown and a.full != b.full):
        raise newException(NifError, "it is about another file (its bytes differ)")
    except NifError, IOError, OSError:
      w.warn("Could not save " & t.what & " in " & t.path & ": another program changed it " &
        "meanwhile, and it cannot be read (" & getCurrentExceptionMsg() & "); it is left as " &
        "that program wrote it.")
      return false
  t.memory.treat = theirs.treat # (none when there is no document now)
  let sent = if removing: EditLists() else: t.memory.edits
  let both = merged(base, sent, theirs.edits)
  if both == theirs.edits and now.size >= 0 and not removing and both == sent: return
  if not t.memory.identity.fullKnown and theirs.identity.fullKnown and
      theirs.identity.size == t.memory.identity.size and
      theirs.identity.quick == t.memory.identity.quick:
    (t.memory.identity.full, t.memory.identity.fullKnown) = (theirs.identity.full, true)
  if t.memory.later.len == 0: t.memory.later = theirs.later
  if removing: t.memory = theirs
  t.memory.edits = both
  w.d.poster.post Msg(job: NoJob, kind: mkMemoryMerged, mergedDoc: t.path.extractFilename,
    mergedEdits: both, mergedSent: sent, mergedRemoved: removing)

const
  StoreLockSuffix* = ".lock"
    ## beside the store's folder (`files.lock`): the file whose lock a
    ## program holds from the look at a document's stamp to the stamp after
    ## its rename (`lockStore`); outside the folder, which lists documents only
  StoreLockWait* = initDuration(seconds = 2)
    ## how long a write waits for another program's (it takes milliseconds):
    ## longer, and it goes on without (that program's drive does not answer)

proc lockStore(path: string): FileLock =
  ## The lock between programs of the store `path`'s document is in, so
  ## that no other viewSEG writes it between this one's look at its stamp
  ## and its rename, or between the rename and the stamp taken after it:
  ## either would lose that program's change, or this one's.
  try:
    fs.createDir(path.parentDir)
  except IOError, OSError:
    discard # said by the write
  fs.lockFile(path.parentDir & StoreLockSuffix, StoreLockWait)

proc replaceFile(w: var Writer; t: Task): bool {.discardable.} =
  ## Writes the document; true when it is written (merged with another program's changes or not).
  var t = t
  if t.fresh: t.path = freshName(t.path)
  var lock = if t.merging: lockStore(t.path) else: FileLock()
  defer: fs.unlock(lock)
  if t.merging and not w.mergeOthers(t, removing = false): return
  result = true
  let tmp = t.path & "." & $getCurrentProcessId() & ".tmp"
  try:
    fs.createDir(t.path.parentDir)
    var f: File
    if not fs.open(f, tmp, fmWrite):
      raise newException(IOError, "it cannot be created")
    try:
      f.write t.body
      f.flushFile()
      syncToDisk(f)
    finally:
      f.close()
    fs.moveFile(tmp, t.path)
    if t.render: # what this thread wrote last, merged or not: never another program's
      w.written[t.path] = (stampOf(t.path), t.memory.edits, t.memory.treat)
    if t.done.len > 0: w.say(sevInfo, if t.fresh: t.done & t.path & "." else: t.done)
  except IOError, OSError:
    result = false
    let why = getCurrentExceptionMsg()
    try:
      fs.removeFile(tmp)
    except OSError:
      discard
    var msg = "Could not save " & t.what & " in " & t.path & ": " & why
    if t.failNote.len > 0:
      msg.add " "
      msg.add t.failNote
    w.warn(msg)

proc closeLog(w: var Writer) =
  if w.log != nil:
    w.log.close()
    w.log = nil
  w.logPath = ""

proc appendTo(w: var Writer; t: Task) =
  if t.path != w.logPath:
    w.closeLog()
    if t.path == w.failed: return # said once already
    w.failed = ""
    try:
      fs.createDir(t.path.parentDir)
      if not fs.open(w.log, t.path, fmAppend):
        raise newException(IOError, "it cannot be opened")
      w.logPath = t.path
    except IOError, OSError:
      w.log = nil
      w.failed = t.path
      w.warn("Could not write " & t.what & " to " & t.path & ": " & getCurrentExceptionMsg() &
        ". The Messages window still has every message.")
      return
  try:
    w.log.write t.body
    w.log.flushFile()
  except IOError:
    let path = w.logPath
    w.closeLog()
    w.failed = path
    w.warn("Could not write " & t.what & " to " & path & ": " & getCurrentExceptionMsg() &
      ". The Messages window still has every message.")

proc pruneDir(w: var Writer; t: Task) =
  var names: seq[string]
  try:
    for kind, path in fs.walkDir(t.path):
      let name = path.extractFilename
      if kind == pcFile and name.startsWith(t.text) and name.endsWith(t.suffix) and
          path != t.spare:
        names.add path
  except OSError:
    discard # nothing to prune
  names.sort()
  for i in 0 ..< names.len - t.keep:
    try:
      fs.removeFile(names[i])
    except OSError:
      w.warn("Could not remove the old file " & names[i] & ": " & getCurrentExceptionMsg())

proc removeFor(w: var Writer; t: Task) =
  var lock = if t.merging: lockStore(t.path) else: FileLock()
  defer: fs.unlock(lock)
  if t.merging:
    var t = t
    if not w.mergeOthers(t, removing = true): return
    if not t.memory.edits.isEmpty or t.memory.treat.isSet:
      # another program's edits, or what the file is treated as: kept, not removed
      (t.render, t.merging) = (true, false) # merged already
      w.replaceFile(t)
      return
    w.written[t.path] = (NoDoc, EditLists(), TreatAs())
  else: w.written.del t.path # its next write is as the UI thread knows it
  try:
    if fs.fileExists(t.path): fs.removeFile(t.path)
    if t.done.len > 0: w.say(sevInfo, t.done)
  except OSError:
    w.warn("Could not remove " & t.what & " (" & t.path & "): " & getCurrentExceptionMsg())

proc treatOne(w: var Writer; t: Task): bool =
  ## Sets the `treat` of the document `t.path` to `t.memory.treat` and nothing else of it (the
  ## module documentation); a new document when there is none and something is forced, none
  ## when it is left with nothing.
  var lock = lockStore(t.path)
  defer: fs.unlock(lock)
  result = true
  let expect = if t.path in w.written: w.written[t.path].stamp else: t.expect
  let now = stampOf(t.path)
  let name = t.memory.name
  var rec = t.memory
  if now.size >= 0:
    try:
      var problems: seq[string]
      rec = readMemoryFile(t.path, problems)
      if rec.damaged: raise newException(NifError, "it has parts this version cannot read")
      template a: untyped = rec.identity
      template b: untyped = t.memory.identity
      if a.size != b.size or a.quick != b.quick or
          (a.fullKnown and b.fullKnown and a.full != b.full):
        raise newException(NifError, "it is about another file (its bytes differ)")
      if b.fullKnown and not a.fullKnown: (a.full, a.fullKnown) = (b.full, true)
    except NifError, IOError, OSError:
      w.warn("What " & name & " is treated as is kept for this session only: its document " &
        t.path & " cannot be read (" & getCurrentExceptionMsg() & "), and it is left as it is.")
      return false
    rec.treat = rec.treat.merged(t.memory.treat, t.parts)
  else:
    rec.treat = TreatAs().merged(t.memory.treat, t.parts)
    if not rec.treat.isSet: return # nothing forced and no document
  rec.doc = t.path.extractFilename
  # the document as this run knew it, until now: what it holds next is known here too; a
  # document another program changed meanwhile is merged at this run's next write of it
  let known = now == expect
  if rec.edits.isEmpty and not rec.treat.isSet and rec.later.len == 0:
    try:
      fs.removeFile(t.path)
      w.written[t.path] = (NoDoc, EditLists(), TreatAs())
    except OSError:
      w.warn("Could not remove " & t.what & " (" & t.path & "): " & getCurrentExceptionMsg())
    return
  var x = Task(kind: tkReplace, path: t.path, memory: rec, render: true, what: t.what)
  let before = w.written.getOrDefault(t.path)
  let had = t.path in w.written
  result = w.replaceFile(x)
  if not known: # not what this run last knew: its next write merges with it
    if had: w.written[t.path] = before
    else: w.written.del t.path

proc treatFor(w: var Writer; t: Task) =
  ## `treatOne`; for a task that moves a choice, once it is in the document, the parts taken
  ## are left out of the document they came from (`DiskIo.moveTreat`).
  let done = t.parts == {} or w.treatOne(t)
  if done and t.src.len > 0:
    discard w.treatOne(Task(kind: tkTreat, path: t.src, memory: t.srcRec,
      parts: t.leave, what: t.what, expect: t.srcStamp))

func isLeftover*(name: string): bool =
  ## Whether `name` is a temporary file a write of a document of the store
  ## makes: `<document>.<process id>.tmp`.
  if not name.endsWith(".tmp"): return false
  let stem = name[0 ..< name.len - 4]
  let dot = stem.rfind('.')
  dot > 0 and dot < stem.high and stem[dot + 1 .. ^1].allCharsInSet(Digits) and
    isStoreName(stem[0 ..< dot])

proc sweepDir(w: var Writer; t: Task) =
  var removed = 0
  try:
    for kind, path in fs.walkDir(t.path):
      if kind == pcFile and path.extractFilename.isLeftover:
        try:
          if fs.getLastModificationTime(path) < t.before:
            fs.removeFile(path)
            inc removed
        except OSError:
          w.warn("Could not remove the temporary file " & path & " a write cut short left: " &
            getCurrentExceptionMsg())
  except OSError:
    discard # no store yet: nothing left
  if removed > 0:
    w.say(sevInfo, "Removed " & $removed & (if removed == 1: " temporary file" else:
      " temporary files") & " a write cut short (the program ended between a write and its " &
      "rename) left in " & t.path & ".")

proc readFor(w: var Writer; t: Task) =
  var msg = Msg(job: NoJob, kind: mkRead, purpose: t.purpose, readPath: t.path)
  try:
    let size = fs.getFileSize(t.path)
    if not fs.fileExists(t.path): # a named pipe would hold this thread until written to
      msg.readError = "it is not a regular file"
    elif size > t.limit:
      msg.readError = "it is larger than " & $(t.limit shr 20) & " MB"
    else:
      msg.content = fs.readFile(t.path)
  except IOError, OSError:
    msg.readError = getCurrentExceptionMsg()
    if msg.readError.len == 0: msg.readError = "it cannot be read"
  if msg.readError.len == 0:
    try:
      msg.doc = parseNif(msg.content, t.path.extractFilename)
    except NifError as e:
      msg.docError = e.msg
  w.d.poster.post msg

func named(t: Task): string =
  ## What `t` is about, and where, for a message.
  let what = if t.what.len > 0: t.what
             else:
               case t.kind
               of tkPrune: "the old files of a folder"
               of tkList: "the list of the layouts"
               of tkSweep: "the files a write cut short left"
               of tkRead: "a file to read"
               else: "a file"
  what & " (" & t.path & ")"

func folder(t: Task): string =
  ## The folder `t` works in.
  if t.kind in {tkPrune, tkList, tkSweep}: t.path else: t.path.parentDir

proc knows(d: ptr DiskObj; t: Task): bool =
  ## Whether a task ended in `t`'s folder before, this run.
  withLock d.lock:
    result = t.folder in d.answered

proc look(t: Task) =
  ## Looks at `t`'s folder: what it says does not matter, only that it came
  ## back (a drive that does not answer holds it).
  discard fs.dirExists(t.folder)

proc take(d: ptr DiskObj; t: Task) =
  ## Before a task (the thread's): whether its folder answers, by a look at
  ## it, unless a task ended there before.
  let known = d.knows(t)
  withLock d.lock:
    d.answering = known
  if not known:
    look(t)
    withLock d.lock:
      d.answering = true

proc answeredIn(d: ptr DiskObj; t: Task) =
  ## After a task (the thread's): its folder answered.
  withLock d.lock:
    if t.folder notin d.answered: d.answered.add t.folder

proc run(d: ptr DiskObj) {.thread.} =
  markWorkerThread()
  var w = Writer(d: d)
  while true:
    var t: Task
    withLock d.lock:
      while d.tasks.len == 0 and not d.quit:
        wait(d.changed, d.lock)
      if d.tasks.len == 0:
        break # quit, and nothing is left
      t = move d.tasks[0]
      d.tasks.delete 0
      d.busy = true
      d.since = getMonoTime()
      d.current = t.named
      d.holding = t.path
    d.take(t)
    case t.kind
    of tkAppend: w.appendTo(t)
    of tkReplace: w.replaceFile(t)
    of tkPrune: w.pruneDir(t)
    of tkRead: w.readFor(t)
    of tkRemove: w.removeFor(t)
    of tkSweep: w.sweepDir(t)
    of tkTreat: w.treatFor(t)
    of tkList:
      w.d.poster.post Msg(job: NoJob, kind: mkRead, purpose: rpLayouts, readPath: t.path,
        layouts: listLayouts(t.path, t.dirs))
    d.answeredIn(t)
    withLock d.lock:
      d.busy = false
      if d.tasks.len == 0: broadcast(d.idle)
  w.closeLog()
  clearCycleRoots() # e.g. a caught exception's; and free the list before the thread ends
  withLock d.lock:
    d.ended = true
    broadcast(d.idle)

proc rescue(d: ptr DiskObj) {.thread.} =
  ## The helper: writes the tasks left `first`, one at a time, while the
  ## thread is held on a task in a folder that does not answer (`stop`);
  ## never the file the thread holds (its newer version waits for it).
  markWorkerThread()
  var w = Writer(d: d)
  while true:
    var t = Task()
    var found = false
    withLock d.lock:
      var i = 0
      while i < d.tasks.len and d.tasks[i].first and not found:
        if d.tasks[i].path != d.holding or not d.busy:
          t = move d.tasks[i]
          d.tasks.delete i
          found = true
        else:
          inc i
      if found:
        d.helperBusy = true
        d.helperSince = getMonoTime()
        d.helperCurrent = t.named
        d.helperAnswering = false
    if not found: break
    if not d.knows(t): look(t)
    withLock d.lock:
      d.helperAnswering = true
    w.replaceFile(t) # (only replaces are left first)
    d.answeredIn(t)
    withLock d.lock:
      d.helperBusy = false
  clearCycleRoots()
  withLock d.lock:
    d.helperEnded = true

# ------------------------------------------------------------- the handle --

const DiskStopWait* = initDuration(milliseconds = 800)
  ## how long `stop` waits for the thread by default

proc askStop*(x: DiskIo) =
  ## Asks the thread to end once it has done what is left, without waiting.
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true
      signal(x.p.changed)

proc stop*(x: DiskIo; deadline = getMonoTime() + DiskStopWait;
    stuckAfter = DiskStopWait; tick: proc () {.closure, raises: [].} = nil): bool {.discardable.} =
  ## Does what is left, then ends the thread, waiting for it until
  ## `deadline`, and no longer once a task whose folder has not answered
  ## (the module documentation) has been in hand for `stuckAfter`, after
  ## the tasks left `first` were given to the helper (`rescue`) and it is
  ## done or held too: true when it has ended; false when it is held by a
  ## drive that does not answer (or `deadline` came first), and it is then
  ## left to end on its own. `tick`, when given, is called about every 16 ms
  ## meanwhile (the caller draws). Idempotent; destroying the `DiskIo` does
  ## it.
  if x.p == nil or not x.p.started: return true
  if x.p.abandoned: return false
  x.askStop()
  var ended = false
  var ticked = getMonoTime()
  while true:
    var stuck, firsts, helped, helperDone = false
    let now = getMonoTime()
    withLock x.p.lock:
      helped = x.p.helperStarted
      ended = x.p.ended and (not helped or x.p.helperEnded)
      stuck = x.p.busy and not x.p.answering and now - x.p.since >= stuckAfter
      firsts = x.p.tasks.len > 0 and x.p.tasks[0].first
      helperDone = x.p.helperEnded or (x.p.helperBusy and not x.p.helperAnswering and
        now - x.p.helperSince >= stuckAfter)
    if ended or now >= deadline: break
    if stuck:
      if not helped and firsts:
        withLock x.p.lock:
          x.p.helperStarted = true
        createThread(x.p.helper, rescue, x.p)
      elif not helped or helperDone: break
    if tick != nil and now - ticked >= initDuration(milliseconds = 16):
      ticked = now
      tick()
    sleep 1
  if ended:
    joinThread(x.p.thread)
    if x.p.helperStarted: joinThread(x.p.helper)
    x.p.started = false
  else:
    x.p.abandoned = true
  ended

proc stuckOn*(x: DiskIo): string =
  ## What the thread is held on, when `stop` left it: the task in hand
  ## ("the settings (/home/...)"), and how many more wait; "" for nothing.
  if x.p != nil and x.p.abandoned:
    withLock x.p.lock:
      if x.p.busy: result = x.p.current
      if x.p.helperBusy:
        result.add (if result.len > 0: ", " else: "") & x.p.helperCurrent
      if x.p.tasks.len > 0:
        result.add (if result.len > 0: ", and " else: "") & $x.p.tasks.len &
          (if x.p.tasks.len == 1: " more file" else: " more files") & " to write"

proc `=destroy`*(x: DiskIo) =
  if x.p != nil:
    try: discard x.stop()
    except ResourceExhaustedError: discard # stop's own wait failed: the thread keeps its memory
    if not x.p.started: # else the thread still runs: its memory stays with it
      deinitCond(x.p.changed)
      deinitCond(x.p.idle)
      deinitLock(x.p.lock)
      `=destroy`(x.p[])
      deallocShared(x.p)

proc newDiskIo*(poster: sink Poster): DiskIo =
  ## Starts the disk thread; it reports through `poster`.
  let p = cast[ptr DiskObj](allocShared0(sizeof(DiskObj)))
  initLock p.lock
  initCond p.changed
  initCond p.idle
  p.poster = poster
  result = DiskIo(p: p)
  createThread(p.thread, run, p)
  p.started = true

proc leave(x: DiskIo; t: sink Task) =
  ## Hands `t` to the thread: after the tasks waiting, or, `t.first`, before
  ## them (after those left `first` before it).
  withLock x.p.lock:
    if x.p.quit: return
    case t.kind
    of tkTreat: # the newest choice for a document: it carries every one before it
      for i in countdown(x.p.tasks.high, 0):
        if x.p.tasks[i].kind == tkTreat and x.p.tasks[i].path == t.path and
            t.src.len == 0 and x.p.tasks[i].src.len == 0:
          t.expect = x.p.tasks[i].expect
          t.parts.incl x.p.tasks[i].parts # (the newer has the newest of every part)
          x.p.tasks.delete(i)
    of tkReplace, tkRemove: # only the newest document of a path is written (or removed)
      # ... but a write under a name no file has (`fresh`: a backup) is a
      # file of its own, whatever name it was asked under: two resets in one
      # second ask for one name and must keep two backups
      if not t.fresh:
        for i in countdown(x.p.tasks.high, 0):
          if x.p.tasks[i].kind in {tkReplace, tkRemove} and not x.p.tasks[i].fresh and
              x.p.tasks[i].path == t.path:
            if x.p.tasks[i].merging and t.merging: # never written: what was there before it
              (t.base, t.expect) = (x.p.tasks[i].base, x.p.tasks[i].expect)
            x.p.tasks.delete(i)
    of tkAppend: # one write for a run of appends to one file
      if x.p.tasks.len > 0 and x.p.tasks[^1].kind == tkAppend and
          x.p.tasks[^1].path == t.path:
        template last: untyped = x.p.tasks[^1]
        if last.entries.len == 0: # its text, then this one's text and entries
          last.text.add t.text
          last.entries = move t.entries
          return
        if t.text.len == 0:
          last.entries.add t.entries
          return
    of tkPrune, tkRead, tkList, tkSweep: discard
    if t.first:
      var at = 0
      while at < x.p.tasks.len and x.p.tasks[at].first: inc at
      x.p.tasks.insert(t, at)
    else: x.p.tasks.add t
    signal(x.p.changed)

proc replace*(x: DiskIo; path: string; text: sink string; what: string; done = "";
    entries: sink seq[LogEntry] = @[]; fresh = false; first = false; failNote = "") =
  ## Writes `text`, then each of `entries` as a line (`fileLine`), to `path`
  ## atomically, soon (the module documentation); `what` names the document
  ## in a message ("the settings"), and `done`, when not "", is logged once
  ## it is written. With `fresh`, never over a file: under the first name
  ## no file has (`path`, or `-2`, `-3` ... before its extension), and
  ## `done` is followed by that path and a full stop. With `first`, before
  ## what waits to be written. `failNote`, when not "", ends the warning if
  ## the save fails.
  if x.p != nil:
    x.leave Task(kind: tkReplace, path: path, text: text, what: what, done: done,
      entries: entries, fresh: fresh, first: first, failNote: failNote)

proc replace*(x: DiskIo; path: string; record: sink FileRecord; what: string) =
  ## Writes `record`'s document (`memoryDocument`, made on the disk thread:
  ## a list of a million traces is tens of milliseconds' work) to `path` as
  ## `replace` writes a text.
  if x.p != nil:
    x.leave Task(kind: tkReplace, path: path, memory: record, render: true, what: what)

proc replace*(x: DiskIo; path: string; record: sink FileRecord; what: string;
    base: EditLists; expect: DocStamp) =
  ## `replace` of a document of the store that another program may write
  ## too: when its stamp is no longer `expect` (or what this thread wrote
  ## last), the other's edits are merged in (the module documentation);
  ## `base` is what it held then.
  if x.p != nil:
    x.leave Task(kind: tkReplace, path: path, memory: record, render: true, what: what,
      merging: true, base: base, expect: expect)

proc removeMerging*(x: DiskIo; path: string; record: sink FileRecord; what: string;
    base: EditLists; expect: DocStamp) =
  ## `remove` of a document of the store whose file keeps nothing now: when
  ## another program changed it since (`replace`'s `expect`), what that one
  ## added is kept instead (`record` names the file).
  if x.p != nil:
    x.leave Task(kind: tkRemove, path: path, memory: record, what: what, merging: true,
      base: base, expect: expect)

proc treat*(x: DiskIo; path: string; record: sink FileRecord; parts: set[TreatPart];
    what: string; expect: DocStamp) =
  ## Sets the `parts` of what the file of `record` is treated as (as `record.treat` has them)
  ## in the document of the store `path`, as it is when it is written, and nothing else of it
  ## (the module documentation): `record` is the new document when there is none. `expect` is
  ## the document's stamp as this run last read it (`replace`'s).
  if x.p != nil and parts != {}:
    x.leave Task(kind: tkTreat, path: path, memory: record, what: what, expect: expect,
      parts: parts)

proc moveTreat*(x: DiskIo; path: string; record: sink FileRecord; parts: set[TreatPart];
    source: string; sourceRecord: sink FileRecord; leaving: set[TreatPart]; what: string;
    expect, sourceStamp: DocStamp) =
  ## `treat`, and once the document `path` holds the `parts`, the `leaving` parts leave the
  ## document `source` (`sourceRecord` says which file it is): if the first cannot be written,
  ## the source keeps what it says. `parts` may be empty (the document has every part of its
  ## own).
  if x.p != nil:
    x.leave Task(kind: tkTreat, path: path, memory: record, what: what, expect: expect,
      parts: parts, src: source, srcRec: sourceRecord, leave: leaving,
      srcStamp: sourceStamp)

proc read*(x: DiskIo; path: string; purpose: ReadPurpose; limit: int) =
  ## Reads `path`, soon, and posts it as an `mkRead` message for `purpose`,
  ## with its NIF tree; a file larger than `limit` bytes is not read (the
  ## message says so).
  if x.p != nil:
    x.leave Task(kind: tkRead, path: path, purpose: purpose, limit: limit)

proc append*(x: DiskIo; path: string; text: sink string; what: string;
    entries: sink seq[LogEntry] = @[]) =
  ## Adds `text`, then each of `entries` as a line (`fileLine`), to the end
  ## of `path`, soon; `what` names the file in a message ("the session
  ## log").
  if x.p != nil and (text.len > 0 or entries.len > 0):
    x.leave Task(kind: tkAppend, path: path, text: text, what: what, entries: entries)

proc remove*(x: DiskIo; path: string; what: string; done = "") =
  ## Removes the file `path`, soon, in place of a replace of it waiting to
  ## be written; `what` names it in a message, and `done`, when not "", is
  ## logged once it is removed. A file that is not there is no problem.
  if x.p != nil:
    x.leave Task(kind: tkRemove, path: path, what: what, done: done)

proc prune*(x: DiskIo; dir, prefix, suffix: string; keep: Natural; spare = "") =
  ## Removes the files of `dir` whose names start with `prefix` and end with
  ## `suffix`, all but the `keep` last in name order, and never `spare`.
  if x.p != nil:
    x.leave Task(kind: tkPrune, path: dir, text: prefix, suffix: suffix, keep: keep,
      spare: spare)

const SweepMargin* = initDuration(minutes = 1)
  ## how long before the program's start a temporary file of the store was
  ## last written, at least, for a sweep to remove it

proc sweep*(x: DiskIo; dir: string; started: times.Time) =
  ## Removes, soon, the temporary files a write cut short left in the
  ## store's folder `dir` (the module documentation), those last written
  ## `SweepMargin` or more before `started`, the program's start.
  if x.p != nil:
    x.leave Task(kind: tkSweep, path: dir, before: started - SweepMargin)

proc listLayouts*(x: DiskIo; configDir: string; presetDirs: seq[string]) =
  ## Lists the layouts in `configDir` and the presets in `presetDirs`
  ## (`layouts.listLayouts`), soon, and posts them as an `mkRead` message
  ## (`rpLayouts`).
  if x.p != nil:
    x.leave Task(kind: tkList, path: configDir, dirs: presetDirs)

proc flush*(x: DiskIo) =
  ## Waits until everything left so far is done.
  if x.p != nil:
    withLock x.p.lock:
      while x.p.started and (x.p.tasks.len > 0 or x.p.busy):
        wait(x.p.idle, x.p.lock)

proc flush*(x: ptr DiskIo) {.gcsafe.} =
  ## `flush` of the disk thread `x` points at, for a job that must read a
  ## document a queued write has not landed yet. The pointer is not owned.
  if x == nil or x.p == nil: return
  withLock x.p.lock:
    while x.p.started and (x.p.tasks.len > 0 or x.p.busy):
      wait(x.p.idle, x.p.lock)
