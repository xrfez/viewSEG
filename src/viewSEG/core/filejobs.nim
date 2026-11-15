## The jobs that open and close files, and parseSEG's index cache.
##
## Opening reads the whole index (and the keys), so it runs on the
## interactive lane, never on the UI thread; the open session goes back to
## the UI thread through the inbox. Closing waits, by asking for the file
## exclusively, until no job reads it; the UI thread then closes the file
## itself, so that the file's objects are only ever released on the thread
## that holds them (`core/threads`, "Handing objects to another thread").
##
## **The index cache.** The first open of a file walks its headers, which
## takes seconds on a large file; the open job then saves the index in the
## cache folder it is given, and later opens of the same, unchanged file read
## it back instead. parseSEG checks each cache against the file (path, size,
## modification time, first and last bytes), so a stale one is never used.
## The folder is kept under a size budget: when a save takes it over, the
## caches used longest ago are deleted. A cache is a copy of what the file
## says, so losing one costs only time; the seismic file itself is never
## written.

import std/[algorithm, monotimes, os, strutils, times]
import parseSEG
import filelist, filesystem, inbox, jobs, log, session, threads

const
  IndexCacheExt* = ".pidx" ## the extension of an index cache file
  DefaultIndexCacheBudget*: int64 = 4 * 1024 * 1024 * 1024
    ## bytes the index cache folder may hold

func fnv1a(text: string): uint64 =
  ## A 64-bit FNV-1a hash: the same on every run and machine.
  result = 14695981039346656037'u64
  for c in text:
    result = (result xor uint64(ord(c))) * 1099511628211'u64

func indexCacheFile*(dir, path: string): string =
  ## Where the index cache of seismic file `path` (as opened: absolute and
  ## normalized) goes in folder `dir`: its name, then a hash of the whole
  ## path, so files of one name in different folders keep their own caches.
  ## "" when `dir` is "" (no cache).
  if dir.len == 0: return ""
  let key = when defined(windows): path.toLowerAscii else: path
  var stem = path.extractFilename
  if stem.len > 64: stem.setLen 64
  dir / (stem & "-" & toHex(fnv1a(key)).toLowerAscii & IndexCacheExt)

proc pruneIndexCache*(dir: string; budget: int64; keep = ""): seq[string] =
  ## Deletes the index caches (`*.pidx`) in `dir` used longest ago until the
  ## rest fit in `budget` bytes, never `keep`; returns the deleted paths. A
  ## cache that cannot be deleted is left. Reading a cache marks it used
  ## (`openWork` sets its modification time).
  var caches: seq[tuple[used: Time; size: int64; path: string]]
  var total = 0'i64
  for path in fs.walkFiles(dir / "*" & IndexCacheExt):
    try:
      let size = fs.getFileSize(path)
      caches.add (fs.getLastModificationTime(path), size, path)
      total += size
    except OSError:
      discard # gone meanwhile
  caches.sort(proc (a, b: typeof(caches[0])): int = cmp(a.used, b.used))
  for c in caches:
    if total <= budget: break
    if c.path != keep and fs.tryRemoveFile(c.path):
      total -= c.size
      result.add c.path

proc openSession*(path: string; progress: Progress = nil; cache = ""): Session =
  ## Opens `path` read-only, with its keys and gathers, reading its index
  ## from the index cache file `cache` when that is current. Worker-only: it
  ## reads the file. Raises `IOError` or `OSError` when the file cannot be
  ## opened, and parseSEG's `SegCancelledError` when `progress` returns
  ## false; problems with the data are in the file's log instead. The
  ## session keeps the file's size and time from just before it was opened,
  ## so a change made meanwhile is seen as one (`Session.size`).
  assertWorkerThread()
  # Checked here too, for a plainer message, and because parseSEG 0.11 loses
  # a small allocation when it cannot open the file it is given.
  if not fs.fileExists(path):
    raise newException(IOError, "there is no such file")
  let info = fs.getFileInfo(path)
  fs.mappedRead(path) # the walk of its headers reads the map
  # parseSEG's record sources are objects with methods, which Nim cannot
  # prove GC-safe. Opening touches no global GC'd memory: parseSEG's viewer
  # guide opens files on a job thread, as here.
  {.cast(gcsafe).}:
    result = newSession(path, openSeismic(path, keys = true, progress = progress,
      opts = OpenOptions(cache: cache)), info.size, info.lastWriteTime)

func cutShort*(f: SeismicFile): bool =
  ## Whether the file ends before a structure it announces is complete
  ## (parseSEG's `truncated` diagnostic): a file still being written, or
  ## cut short.
  for d in f.log:
    if d.code == dcTruncated: return true
  false

proc note(to: Poster; job: JobId; severity: Severity; path, text: string) =
  ## Posts `text` for the log, about file `path` (which `text` names).
  to.post Msg(job: job, kind: mkLog, entry: LogEntry(time: getTime(), severity: severity,
    source: path.extractFilename, text: text))

proc saveCache(s: Session; cache: string; budget: int64; to: Poster; job: JobId) =
  ## Saves the index of `s` as `cache` and keeps the cache folder in
  ## `budget`. A file whose index cannot be cached (a multiplexed SEG-D
  ## file's demultiplexed copy, a file still being written) is opened all
  ## the same; the log says why.
  let name = s.name
  try:
    fs.createDir(cache.parentDir)
    {.cast(gcsafe).}:
      s.file.saveIndex(cache)
    discard pruneIndexCache(cache.parentDir, budget, keep = cache)
  except ValueError as e:
    to.note(job, sevInfo, s.path, "The index of " & name & " was not cached: " & e.msg & ".")
  except IOError, OSError:
    to.note(job, sevWarning, s.path, "Cannot save the index cache of " & name & " in " &
      cache.parentDir & " (" & getCurrentExceptionMsg() & "): the next open walks the " &
      "file again.")

proc openCached(path: string; ctx: JobContext; to: Poster; cache: string; budget: int64;
    whole: bool): Session =
  ## Opens `path` on job `ctx`, through the index cache `cache` (read when
  ## current, saved after a walk; see `openWork`).
  let cached = cache.len > 0 and fs.fileExists(cache)
  ctx.setPhase(if cached: "reading the index cache" else: "indexing")
  let progress: Progress = proc (done, total: int64): bool {.gcsafe, raises: [].} =
    try:
      fs.mappedRead(path) # (tests: the walk's next pages come late)
    except OSError:
      discard # a real drive that fails here ends the walk in parseSEG
    ctx.progress(done, total)
  result = openSession(path, progress, if cached: cache else: "")
  ctx.checkCancelled() # the file closes here, on the thread that opened it
  if cache.len > 0 and result.file.kind != skUnknown:
    if result.file.fromCache:
      try:
        fs.setLastModificationTime(cache, getTime()) # used now: pruned last
      except OSError:
        discard
    elif result.file.demuxPath.len == 0 and not (whole and result.file.cutShort):
      # (a demultiplexed copy is never cached)
      ctx.setPhase "saving the index cache"
      result.saveCache(cache, budget, to, ctx.id)
      ctx.checkCancelled()

proc openWork*(path: string; to: Poster; cache = "";
    cacheBudget = DefaultIndexCacheBudget; whole = false): JobWork =
  ## The work of a job that opens `path` and posts its session (`mkOpened`).
  ## With a `cache` file (`indexCacheFile`), a current cache is read instead
  ## of walking the file, and a file that had none gets one. A cancel asked
  ## for at any point before the session is posted closes the file again and
  ## posts nothing. With `whole` (an open the file list's "Follow the
  ## latest" made, which shows the file only when it is complete), a file
  ## cut short gets no cache: it is still being written.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var s = openCached(path, ctx, to, cache, cacheBudget, whole)
    clearCycleRoots() # the UI thread may release the file's objects at once
    to.post Msg(job: ctx.id, kind: mkOpened, session: move s)

const WarmChunk = 256 ## traces per read when a prepared file's first view is read

proc prepareWork*(path: string; to: Poster; cache: string; positions: Slice[int];
    stride: int; samples: Slice[int]; cacheBudget = DefaultIndexCacheBudget): JobWork =
  ## The work of a background job that prepares `path`, the file the user
  ## is likely to step to next: opens it (through the index cache, which a
  ## walk fills), then reads the samples of its first view, as the plot
  ## shows the file before it (`positions` of its first gather at
  ## `stride`, `samples` of each trace), so that the drive's pages are at
  ## hand, and posts its session (`mkOpened`), which the UI keeps unshown
  ## until the user steps to it. Stops at a cancel; posts nothing then.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var s = openCached(path, ctx, to, cache, cacheBudget, whole = false)
    if s.file.kind != skUnknown and s.gathers.len > 0 and positions.len > 0:
      ctx.setPhase "reading its first view"
      let g = s.gathers[0].traces
      var list: seq[int]
      var k = positions.a
      while k <= positions.b and g.a + k <= g.b:
        list.add g.a + k
        k += max(1, stride)
      if list.len > 0:
        {.cast(gcsafe).}:
          let most = s.file.maxSamples(g)
          let first = clamp(samples.a, 0, max(0, most - 1))
          let cols = clamp(samples.len, 1, max(1, most - first))
          var pf = newPrefetcher[float32](s.file, list, chunkTraces = WarmChunk, cols = cols,
            firstSample = first, workers = 2, uniform = true)
          var c: PrefetchChunk[float32]
          var n = 0
          while pf.nextInto(c):
            try:
              fs.mappedRead(path)
            except OSError:
              break
            n += c.count
            pf.recycle(move c)
            if not ctx.progress(n, list.len): break
          pf.close() # false when a worker stuck in a read is left to finish
          discard
      ctx.checkCancelled()
    clearCycleRoots() # the UI thread may release the file's objects at once
    to.post Msg(job: ctx.id, kind: mkOpened, session: move s)

proc traceHeadersWork*(file: ptr SeismicFile; path: string; size: int64; index: int;
    to: Poster): JobWork =
  ## The work of a job that reads trace `index` of open file `file` (at
  ## `path`, `size` bytes when it was opened): its keys and the fields of its
  ## headers, read from the file's map (`mkTraceRead`). A drive that does
  ## not answer holds this job, never the UI thread. Submitted with the file
  ## in `reads`, so no join changes its keys meanwhile and no close takes it
  ## away. A file shorter than it was opened is not read: its map's pages
  ## past the end would end the program.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading a trace's headers"
    if size >= 0 and fs.getFileInfo(path).size < size:
      raise newException(IOError, "the file is shorter than when it was opened")
    fs.mappedRead(path, headers = true) # (tests: the drive holds the thread here)
    var keys: TraceKeys
    var rows: seq[HeaderRow]
    {.cast(gcsafe).}:
      keys = file[].traceKeys([index])[0]
      rows = file[].traceHeaders(index)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkTraceRead, readKeys: keys, headerRows: move rows)

proc closeWork*(): JobWork =
  ## The work of a close job: none. Submitted with the file in `exclusive`,
  ## the job starts only once no job reads it, and when it has finished
  ## the UI thread closes the file.
  result = proc (ctx: JobContext) {.gcsafe.} =
    discard

proc sniff*(path: string; opened: var bool): FileKind =
  ## What the file at `path` is, from its first `SniffBytes`
  ## (`filekinds.fileKindOf`: SEG-Y, SEG-D, SEG-2, SPS or P1); `fkUnknown`
  ## when it is none, or cannot be read, and then `opened` says whether it
  ## could be opened at all (false: no permission, say, so it may be known
  ## later). Reads the file and changes nothing in it. What is not a regular
  ## file (a named pipe, a socket, a device) is not opened at all: opening a
  ## named pipe waits until something writes to it, which may be never.
  opened = true
  if not fs.fileExists(path): return fkUnknown
  var head = newSeq[byte](SniffBytes)
  var f: File
  if not fs.open(f, path, fmRead):
    opened = false
    return fkUnknown
  try:
    head.setLen fs.readBuffer(f, path, addr head[0], SniffBytes)
  except IOError:
    head.setLen 0
  finally:
    close(f)
  fileKindOf(head, path.extractFilename, whole = head.len < SniffBytes)

proc sniff*(path: string): FileKind =
  ## What the file at `path` is (`sniff` above), whether it could be opened
  ## or not.
  var opened: bool
  sniff(path, opened)

proc listedNames(paths: openArray[string]): seq[string] =
  ## The files `paths` name: each folder's files (not its subfolders, nor
  ## hidden files), and each file itself; absolute, normalized, once each,
  ## in natural order of their names. Raises `OSError` when a folder cannot
  ## be read.
  for p in paths:
    if fs.dirExists(p):
      for kind, path in fs.walkDir(p, checkDir = true):
        if kind in {pcFile, pcLinkToFile} and not path.extractFilename.startsWith("."):
          result.add path.normalizedPath
    elif p.len > 0:
      result.add p.normalizedPath
  result.sort(proc (a, b: string): int =
    result = naturalCmp(a.extractFilename, b.extractFilename)
    if result == 0: result = cmp(a, b))
  var unique: seq[string]
  for p in result:
    if unique.len == 0 or unique[^1] != p: unique.add p
  result = unique

const ListPause = initDuration(milliseconds = 100) ## a scan posts at least this often

proc scanWork*(gen: uint64; paths: seq[string]; to: Poster): JobWork =
  ## The work of a job that lists the seismic and survey files `paths` name
  ## (folders and files, absolute) and posts them as `mkListed` messages for listing
  ## `gen`, in batches, the last one with `listDone`. One file alone stands
  ## for its folder: the folder is listed, and the first message names both
  ## (`listFolder`, `listChosen`); one folder is named in it too; the last
  ## one has every file it looked at (`listLooked`), for the folder's watch.
  ## Raises `OSError` when a folder cannot be read, `IOError` when the one
  ## path given does not exist; stops at a cancel.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading the folder"
    var asked = paths
    if paths.len == 1:
      var first = Msg(job: ctx.id, kind: mkListed, listGen: gen)
      if fs.dirExists(paths[0]):
        first.listFolder = paths[0]
      elif fs.fileExists(paths[0]):
        (first.listFolder, first.listChosen) = (paths[0].parentDir, paths[0])
        asked = @[first.listFolder]
      else:
        raise newException(IOError, "there is no file or folder at " & paths[0])
      to.post move first
    let names = listedNames(asked)
    ctx.setPhase "looking at the files"
    var batch = Msg(job: ctx.id, kind: mkListed, listGen: gen)
    var looked = newSeqOfCap[WatchedFile](names.len)
    var last = getMonoTime()
    for i, path in names:
      if not ctx.progress(i, names.len): raise newException(JobCancelledError, "cancelled")
      try:
        let info = fs.getFileInfo(path)
        if info.kind notin {pcFile, pcLinkToFile}:
          inc batch.unreadable
        elif not fs.fileExists(path): # a named pipe, a socket, a device: never opened
          inc batch.others
        else:
          var opened: bool
          let kind = sniff(path, opened)
          looked.add WatchedFile(path: path, exists: true, kind: kind, size: info.size,
            modified: info.lastWriteTime, listed: true, unopened: not opened)
          if not opened: inc batch.unreadable
          elif kind == fkUnknown: inc batch.others
          else:
            batch.listed.add FileEntry(path: path, name: path.extractFilename, kind: kind,
              size: info.size, modified: info.lastWriteTime)
      except OSError:
        inc batch.unreadable
      if batch.listed.len >= ListBatch or getMonoTime() - last >= ListPause:
        to.post move batch
        batch = Msg(job: ctx.id, kind: mkListed, listGen: gen)
        last = getMonoTime()
    discard ctx.progress(names.len, names.len)
    batch.listDone = true
    batch.listLooked = move looked
    to.post move batch
