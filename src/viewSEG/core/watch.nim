## The folder's watch: a thread that looks at the files the file list shows
## (a folder's, or files chosen one by one) and at the open files, about
## once a second, and posts what changed (`mkWatched`): a seismic file that
## appeared (or became one: a file being written is too short to tell at
## first), a file whose size or time changed since the look before, one that
## stopped changing, one that went.
##
## No operating system notification is used: a look reads the folder's
## names and each file's size and time (`stat`), the same on every system
## and on network shares, where notifications are not reliable. It reads the
## first 4 KiB of a file (`sniff`) only when a file not known to be seismic
## appears or changes, and never opens what is not a regular file (a named
## pipe waits for a writer).
##
## - **What it starts from.** `watch` gives it the listing's `gen`, the paths
##   the listing names and what the scan found of each file (`listLooked`),
##   so a file that changed between the scan and the first look is reported,
##   and a file the scan found not to be seismic is not read again until it
##   changes. Hidden files and subfolders are left out, as the scan leaves
##   them out.
## - **Open files.** `watchOpen` names the open files; each is reported at
##   the first look after it is named, then whenever it changes, so the UI
##   can compare it with the file it opened (`Session.size`).
## - **Steady.** A file is `changing` at the look that finds it changed (or
##   new) and steady at the next look that finds it the same: what "its size
##   has stopped changing" means here.
## - **Cost.** A look stats every file; the pause after it is `interval`, or
##   ten times the look when that is longer (a slow network share), so a
##   slow folder is looked at less often instead of all the time.
## - **A folder that cannot be read** (gone, no permission, a share that went
##   away) is said once (`watchProblem`), and nothing in it is taken for
##   gone; it is looked at again at each turn.
## - **A share that does not answer.** No call on the file system is made
##   under the lock the UI thread takes (a `stat` there held every open and
##   close while a share did not answer): the thread copies its notes out,
##   then looks. A look under way says since when (`lookingFor`), so the UI
##   can say that the folder does not answer.
## - **Stop.** `stop` (and destroying the watch) asks the thread to end and
##   waits for it until a deadline (`StopWait` by default): a look held by
##   a network share that no longer answers would otherwise hold the quit.
##   Such a thread is left to the end of the process, with its memory.

import std/[locks, monotimes, os, sets, strutils, tables, times]
import filejobs, filelist, filesystem, inbox, jobs, sweepinfo, threads

export filelist

const
  WatchInterval* = initDuration(seconds = 1)   ## the pause between looks, at least
  StopWait* = initDuration(milliseconds = 800) ## how long `stop` waits for a look to end
  SlowFactor = 10                              ## a slow look: the pause is this many looks
  Nap = 20                                     ## ms the thread sleeps between checks of its notes

type
  WatchObj = object
    ## Shared by the UI thread and the watch's thread; every field under `lock`.
    lock: Lock
    gen: uint64              ## the listing watched; 0: none
    paths: seq[string]       ## what the listing names: a folder, or files
    recursive: bool          ## the folders' subfolders are watched too
    looked: seq[WatchedFile] ## what its scan found, until the thread takes it
    fresh: bool              ## a new listing (or none) to take
    open: seq[string]
    openFresh: bool          ## new open files to take
    lookNow: bool
    quit, ended: bool
    gaveUp: bool             ## `stop` waited `StopWait` in vain: the thread is left
    interval: Duration
    lastLook: Duration       ## how long the last look took
    lookStart: MonoTime      ## when the look under way started (`fs.now`); zero between looks
    poster: Poster
    thread: Thread[ptr WatchObj]
    started: bool

  FolderWatch* = object
    ## The watch's thread. Move-only; a default `FolderWatch` is none.
    p: ptr WatchObj

  Seen = object
    ## The thread's own: a file as the last look found it.
    size: int64
    modified: Time
    kind: FileKind
    changing: bool
    listed: bool
    unopened: bool ## it could not be opened to tell what it is: tried again each look
    turn: int      ## the look that saw it last

  Watcher = object
    ## The thread's own state.
    p: ptr WatchObj
    gen: uint64
    paths: seq[string]
    recursive: bool
    isDir: seq[bool]          ## per path: a folder, when the listing was taken
    open: seq[string]
    announce: HashSet[string] ## open files to report at the next look, changed or not
    seen: Table[string, Seen]
    turn: int
    problem: string           ## why the folder could not be looked at last; "" for none

proc `=destroy`*(x: FolderWatch)
proc `=wasMoved`*(x: var FolderWatch) = x.p = nil
proc `=copy`*(dest: var FolderWatch; src: FolderWatch) {.error.}
proc `=dup`*(src: FolderWatch): FolderWatch {.error.}

func isNil*(x: FolderWatch): bool {.inline.} =
  ## Whether `x` is none (never started).
  x.p == nil

# ------------------------------------------------------------ the thread --

proc quitting(p: ptr WatchObj): bool =
  withLock p.lock:
    result = p.quit

proc report(s: Seen; path: string): WatchedFile =
  result = WatchedFile(path: path, exists: true, kind: s.kind, size: s.size,
    modified: s.modified, changing: s.changing, listed: s.listed)
  if s.kind in SignatureFileKinds: # (its header says what a list shows of it)
    result.sweep = readSweepInfo(path, s.kind.sweepKindOf, s.size)

proc see(w: var Watcher; path: string; listed: bool; news: var seq[WatchedFile]) =
  ## Looks at `path` once this turn and adds what is news about it to `news`.
  var info: FileInfo
  try:
    info = fs.getFileInfo(path)
  except OSError as e:
    # Gone: taken for gone below, when the look is whole. Not to be looked at
    # now (its folder's permissions changed during the look): kept as it was.
    when defined(windows):
      const gone = [2'i32, 3] # ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND
    else:
      const gone = [2'i32, 20] # ENOENT, ENOTDIR
    if e.errorCode notin gone and path in w.seen: w.seen[path].turn = w.turn
    return
  # A named pipe, a socket, a device: never opened, not watched.
  if info.kind notin {pcFile, pcLinkToFile} or info.isSpecial: return
  let announced = w.announce.len > 0 and path in w.announce
  if announced: w.announce.excl path
  var opened = true
  if path in w.seen:
    template s: untyped = w.seen[path]
    if s.turn == w.turn: return # a listed file that is also open
    s.turn = w.turn
    s.listed = s.listed or listed
    if s.size != info.size or s.modified != info.lastWriteTime:
      let wasKnown = s.kind != fkUnknown
      s.size = info.size
      s.modified = info.lastWriteTime
      if s.kind == fkUnknown: s.kind = sniff(path, opened) # long enough to tell now?
      s.unopened = not opened
      s.changing = true
      if s.kind != fkUnknown or wasKnown or announced: news.add s.report(path)
    elif s.unopened:
      # Not readable when last looked at; its permissions may have changed.
      s.kind = sniff(path, opened)
      s.unopened = not opened
      if s.kind != fkUnknown or announced: news.add s.report(path)
    elif s.changing:
      s.changing = false
      if s.kind != fkUnknown or announced: news.add s.report(path)
    elif announced:
      news.add s.report(path)
  else:
    let kind = sniff(path, opened)
    let s = Seen(size: info.size, modified: info.lastWriteTime, kind: kind,
      changing: true, listed: listed, unopened: not opened, turn: w.turn)
    w.seen[path] = s
    if s.kind != fkUnknown or announced: news.add s.report(path)

proc look(w: var Watcher): seq[WatchedFile] =
  ## One look at the listed files and the open ones: what changed.
  inc w.turn
  var problem = ""
  var incomplete = false # a tree cut at the cap: what is not seen is not gone
  if w.gen != 0:
    for i, p in w.paths:
      if not w.isDir[i]:
        w.see(p, true, result) # a file chosen
      else:
        try:
          var n = 0
          if w.recursive:
            # every file below it, as the scan listed them (`treeNames`)
            var capped = false
            let quit = w.p
            for path in treeNames(p, MaxTreeFiles, capped,
                proc (found: int): bool {.gcsafe, raises: [].} = not quit.quitting):
              w.see(path, true, result)
            if w.p.quitting: return
            if capped: incomplete = true
            continue
          for kind, name in fs.walkDir(p, relative = true, checkDir = true):
            # `p` is normalized, so `p / name` is the path the scan listed.
            if kind in {pcFile, pcLinkToFile} and not name.startsWith("."):
              w.see(p / name, true, result)
            inc n
            if n mod 256 == 0 and w.p.quitting: return
        except OSError as e:
          problem = p & " cannot be read" & (if e.msg.len > 0: " (" & e.msg & ")" else: "")
  for p in w.open: w.see(p, false, result)
  # What no look saw this turn is gone, unless the folder could not be read.
  if problem.len == 0 and not incomplete:
    var gone: seq[string]
    for path, s in w.seen:
      if s.turn != w.turn: gone.add path
    for path in gone:
      let s = w.seen[path]
      w.seen.del path
      if s.kind != fkUnknown or path in w.open:
        result.add WatchedFile(path: path, exists: false, kind: s.kind, listed: s.listed)
  if problem != w.problem:
    w.problem = problem
    w.p.poster.post Msg(job: NoJob, kind: mkWatched, watchGen: w.gen, watched: result,
      watchProblem: problem, problemChanged: true)
    result.setLen 0

proc take(w: var Watcher) =
  ## Takes the notes the UI thread left: a new listing, new open files. The
  ## notes are copied under the lock; the folders are looked at after it.
  var fresh = false
  var looked: seq[WatchedFile]
  withLock w.p.lock:
    if w.p.fresh:
      fresh = true
      w.p.fresh = false
      w.gen = w.p.gen
      w.paths = w.p.paths
      w.recursive = w.p.recursive
      looked = move w.p.looked
      w.p.looked.setLen 0
    if w.p.openFresh:
      w.p.openFresh = false
      for p in w.p.open:
        if p notin w.open: w.announce.incl p
      w.open = w.p.open
    w.p.lookNow = false
  if fresh:
    w.isDir.setLen 0
    for p in w.paths: w.isDir.add fs.dirExists(p)
    w.seen.clear()
    w.problem = ""
    for f in looked:
      w.seen[f.path] = Seen(size: f.size, modified: f.modified, kind: f.kind, listed: true,
        unopened: f.unopened)

proc run(p: ptr WatchObj) {.thread.} =
  markWorkerThread()
  var w = Watcher(p: p)
  var next = getMonoTime()
  while true:
    var quit, due: bool
    withLock p.lock:
      quit = p.quit
      due = p.fresh or p.openFresh or p.lookNow
    if quit: break
    if not due and getMonoTime() < next:
      sleep Nap
    else:
      withLock p.lock:
        p.lookStart = fs.now()
      w.take()
      if w.gen != 0 or w.open.len > 0:
        let t0 = getMonoTime()
        var news = w.look()
        let took = getMonoTime() - t0
        if news.len > 0:
          p.poster.post Msg(job: NoJob, kind: mkWatched, watchGen: w.gen, watched: move news)
        var pause: Duration
        withLock p.lock:
          pause = p.interval
          p.lastLook = took
          p.lookStart = MonoTime()
        next = getMonoTime() + max(pause, took * SlowFactor)
      else:
        withLock p.lock:
          p.lookStart = MonoTime()
        next = getMonoTime() + initDuration(days = 1) # nothing to watch until a note comes
  clearCycleRoots()
  withLock p.lock:
    p.ended = true

# ------------------------------------------------------------- the handle --

proc askStop*(x: FolderWatch) =
  ## Asks the thread to end, without waiting (`stop` waits).
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true

proc stop*(x: FolderWatch; deadline = getMonoTime() + StopWait) =
  ## Ends the thread: at once, or after the look under way, waiting for it
  ## until `deadline`. Idempotent; destroying the watch does it.
  if x.p == nil or not x.p.started or x.p.gaveUp: return
  x.askStop()
  var ended = false
  while not ended and getMonoTime() < deadline:
    withLock x.p.lock:
      ended = x.p.ended
    if not ended: sleep 1
  if ended:
    joinThread(x.p.thread)
    x.p.started = false
  else:
    x.p.gaveUp = true

proc `=destroy`*(x: FolderWatch) =
  if x.p != nil:
    x.stop()
    if not x.p.started: # else the thread still runs: its memory stays with it
      deinitLock(x.p.lock)
      `=destroy`(x.p[])
      deallocShared(x.p)

proc newFolderWatch*(poster: sink Poster; interval = WatchInterval): FolderWatch =
  ## Starts the watch's thread, with nothing to watch yet; it reports
  ## through `poster`, looking every `interval` at most.
  let p = cast[ptr WatchObj](allocShared0(sizeof(WatchObj)))
  initLock p.lock
  p.poster = poster
  p.interval = interval
  result = FolderWatch(p: p)
  createThread(p.thread, run, p)
  p.started = true

proc watch*(x: FolderWatch; gen: uint64; paths: seq[string]; looked: sink seq[WatchedFile];
    recursive = false) =
  ## Watches the files of listing `gen`: those of the folders and the files
  ## `paths` names (and of the folders below them when `recursive`), starting
  ## from what its scan found (`looked`).
  if x.p != nil:
    withLock x.p.lock:
      x.p.gen = gen
      x.p.paths = paths
      x.p.recursive = recursive
      x.p.looked = looked
      x.p.fresh = true

proc unwatch*(x: FolderWatch) =
  ## Watches no listing (the open files still).
  if x.p != nil:
    withLock x.p.lock:
      x.p.gen = 0
      x.p.paths.setLen 0
      x.p.looked.setLen 0
      x.p.fresh = true

proc watchOpen*(x: FolderWatch; paths: seq[string]) =
  ## The open files: each is reported at the next look, then when it changes.
  if x.p != nil:
    withLock x.p.lock:
      x.p.open = paths
      x.p.openFresh = true

proc lookingFor*(x: FolderWatch; now = fs.now()): Duration =
  ## How long the look under way has taken so far (a folder that does not
  ## answer holds it); zero between looks.
  if x.p != nil:
    withLock x.p.lock:
      if x.p.lookStart != MonoTime(): result = now - x.p.lookStart

proc lookTime*(x: FolderWatch): Duration =
  ## How long the last look took; zero before the first (or with none).
  if x.p != nil:
    withLock x.p.lock:
      result = x.p.lastLook

proc lookNow*(x: FolderWatch) =
  ## Looks again without waiting for the pause to end.
  if x.p != nil:
    withLock x.p.lock:
      x.p.lookNow = true
