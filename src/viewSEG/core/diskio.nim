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
## - **Read** reads a whole file up to a size, and posts it (or why it could
##   not be read) for the UI thread, with its NIF tree (`parseNif`) or why
##   it is not NIF, so the UI thread only takes in a tree.
##
## `flush` waits until everything left so far is done; `stop` (and
## destroying the `DiskIo`) does what is left, then ends the thread.

import std/[algorithm, locks, os, strutils, times]
import filesystem, inbox, jobs, log, nif, threads

when not defined(windows):
  import std/posix

type
  TaskKind = enum
    tkAppend, tkReplace, tkPrune, tkRead

  Task = object
    kind: TaskKind
    path: string           ## the file; for a prune, the folder
    text: string           ## what to write; for a prune, the names' start
    entries: seq[LogEntry] ## an append or a replace: written after `text`, a line each
    what: string           ## what the file is, for a message: "the settings"
    keep: int              ## a prune: how many to keep
    suffix: string         ## a prune: the names' end
    spare: string          ## a prune: a file never removed
    done: string           ## a replace: what to say once it is written ("" for nothing)
    purpose: ReadPurpose   ## a read: what for
    limit: int             ## a read: the largest file read, in bytes

  DiskObj = object
    lock: Lock
    changed, idle: Cond
    tasks: seq[Task]
    busy, quit, started: bool
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

proc syncToDisk(f: File) =
  ## Asks the OS to put what was written on the disk (POSIX; on Windows the
  ## rename that follows is enough for a document this small).
  when not defined(windows):
    discard fsync(getFileHandle(f))

proc body(t: Task): string =
  ## What `t` writes: its text, then its log entries, a line each.
  result = t.text
  for e in t.entries: result.add fileLine(e)

proc replaceFile(w: var Writer; t: Task) =
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
    if t.done.len > 0: w.say(sevInfo, t.done)
  except IOError, OSError:
    let why = getCurrentExceptionMsg()
    try:
      fs.removeFile(tmp)
    except OSError:
      discard
    w.warn("Could not save " & t.what & " in " & t.path & ": " & why)

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

proc run(d: ptr DiskObj) {.thread.} =
  markWorkerThread()
  var w = Writer(d: d)
  var work: seq[Task]
  while true:
    withLock d.lock:
      while d.tasks.len == 0 and not d.quit:
        wait(d.changed, d.lock)
      if d.tasks.len == 0:
        break # quit, and nothing is left
      swap(work, d.tasks)
      d.busy = true
    for t in work:
      case t.kind
      of tkAppend: w.appendTo(t)
      of tkReplace: w.replaceFile(t)
      of tkPrune: w.pruneDir(t)
      of tkRead: w.readFor(t)
    work.setLen 0
    withLock d.lock:
      d.busy = false
      if d.tasks.len == 0: broadcast(d.idle)
  w.closeLog()
  clearCycleRoots() # e.g. a caught exception's; and free the list before the thread ends
  withLock d.lock:
    broadcast(d.idle)

# ------------------------------------------------------------- the handle --

proc stop*(x: DiskIo) =
  ## Does what is left, then ends the thread and waits for it. Idempotent;
  ## destroying the `DiskIo` does it.
  if x.p != nil and x.p.started:
    withLock x.p.lock:
      x.p.quit = true
      signal(x.p.changed)
    joinThread(x.p.thread)
    x.p.started = false

proc `=destroy`*(x: DiskIo) =
  if x.p != nil:
    x.stop()
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
  withLock x.p.lock:
    if x.p.quit: return
    case t.kind
    of tkReplace: # only the newest document of a path is written
      for i in countdown(x.p.tasks.high, 0):
        if x.p.tasks[i].kind == tkReplace and x.p.tasks[i].path == t.path:
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
    of tkPrune, tkRead: discard
    x.p.tasks.add t
    signal(x.p.changed)

proc replace*(x: DiskIo; path: string; text: sink string; what: string; done = "";
    entries: sink seq[LogEntry] = @[]) =
  ## Writes `text`, then each of `entries` as a line (`fileLine`), to `path`
  ## atomically, soon (the module documentation); `what` names the document
  ## in a message ("the settings"), and `done`, when not "", is logged once
  ## it is written.
  if x.p != nil:
    x.leave Task(kind: tkReplace, path: path, text: text, what: what, done: done,
      entries: entries)

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

proc prune*(x: DiskIo; dir, prefix, suffix: string; keep: Natural; spare = "") =
  ## Removes the files of `dir` whose names start with `prefix` and end with
  ## `suffix`, all but the `keep` last in name order, and never `spare`.
  if x.p != nil:
    x.leave Task(kind: tkPrune, path: dir, text: prefix, suffix: suffix, keep: keep,
      spare: spare)

proc flush*(x: DiskIo) =
  ## Waits until everything left so far is done.
  if x.p != nil:
    withLock x.p.lock:
      while x.p.started and (x.p.tasks.len > 0 or x.p.busy):
        wait(x.p.idle, x.p.lock)
