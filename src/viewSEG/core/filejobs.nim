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

import std/[algorithm, os, strutils, times]
import parseSEG
import inbox, jobs, log, session, threads

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
  for path in walkFiles(dir / "*" & IndexCacheExt):
    try:
      let size = getFileSize(path)
      caches.add (getLastModificationTime(path), size, path)
      total += size
    except OSError:
      discard # gone meanwhile
  caches.sort(proc (a, b: typeof(caches[0])): int = cmp(a.used, b.used))
  for c in caches:
    if total <= budget: break
    if c.path != keep and tryRemoveFile(c.path):
      total -= c.size
      result.add c.path

proc openSession*(path: string; progress: Progress = nil; cache = ""): Session =
  ## Opens `path` read-only, with its keys and gathers, reading its index
  ## from the index cache file `cache` when that is current. Worker-only: it
  ## reads the file. Raises `IOError` or `OSError` when the file cannot be
  ## opened, and parseSEG's `SegCancelledError` when `progress` returns
  ## false; problems with the data are in the file's log instead.
  assertWorkerThread()
  # Checked here too, for a plainer message, and because parseSEG 0.11 loses
  # a small allocation when it cannot open the file it is given.
  if not fileExists(path):
    raise newException(IOError, "there is no such file")
  # parseSEG's record sources are objects with methods, which Nim cannot
  # prove GC-safe. Opening touches no global GC'd memory: parseSEG's viewer
  # guide opens files on a job thread, as here.
  {.cast(gcsafe).}:
    result = newSession(path, openSeismic(path, keys = true, progress = progress,
      opts = OpenOptions(cache: cache)))

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
    createDir(cache.parentDir)
    {.cast(gcsafe).}:
      s.file.saveIndex(cache)
    discard pruneIndexCache(cache.parentDir, budget, keep = cache)
  except ValueError as e:
    to.note(job, sevInfo, s.path, "The index of " & name & " was not cached: " & e.msg & ".")
  except IOError, OSError:
    to.note(job, sevWarning, s.path, "Cannot save the index cache of " & name & " in " &
      cache.parentDir & " (" & getCurrentExceptionMsg() & "): the next open walks the " &
      "file again.")

proc openWork*(path: string; to: Poster; cache = "";
    cacheBudget = DefaultIndexCacheBudget): JobWork =
  ## The work of a job that opens `path` and posts its session (`mkOpened`).
  ## With a `cache` file (`indexCacheFile`), a current cache is read instead
  ## of walking the file, and a file that had none gets one. A cancel asked
  ## for at any point before the session is posted closes the file again and
  ## posts nothing.
  result = proc (ctx: JobContext) {.gcsafe.} =
    let cached = cache.len > 0 and fileExists(cache)
    ctx.setPhase(if cached: "reading the index cache" else: "indexing")
    let progress: Progress = proc (done, total: int64): bool {.gcsafe, raises: [].} =
      ctx.progress(done, total)
    var s = openSession(path, progress, if cached: cache else: "")
    ctx.checkCancelled() # the file closes here, on the thread that opened it
    if cache.len > 0 and s.file.kind != skUnknown:
      if s.file.fromCache:
        try:
          setLastModificationTime(cache, getTime()) # used now: pruned last
        except OSError:
          discard
      elif s.file.demuxPath.len == 0: # a demultiplexed copy is never cached
        ctx.setPhase "saving the index cache"
        s.saveCache(cache, cacheBudget, to, ctx.id)
        ctx.checkCancelled()
    clearCycleRoots() # the UI thread may release the file's objects at once
    to.post Msg(job: ctx.id, kind: mkOpened, session: move s)

proc closeWork*(): JobWork =
  ## The work of a close job: none. Submitted with the file in `exclusive`,
  ## the job starts only once no job reads it, and when it has finished
  ## the UI thread closes the file.
  result = proc (ctx: JobContext) {.gcsafe.} =
    discard
