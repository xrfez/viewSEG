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
import cutfile, filelist, filesystem, inbox, jobs, leapfile, log, recordingprobe,
  session, sweepinfo, threads, vendormaps
from project import ProjectFileName

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

func damagedSegyWhy*(f: SeismicFile): string =
  ## Why a SEG-Y file is refused as damaged, else "". A file whose binary header says 0
  ## samples per trace and whose first trace header says 0 samples too gives no trace
  ## length at all; it is refused when what follows the first trace header does not
  ## parse as trace headers either (parseSEG's log has an error or a fatal entry: the
  ## bytes cut into "traces" at random). A headers-only file (every trace empty), a
  ## variable-length file whose first trace is empty and one whose binary header is 0
  ## with valid trace headers all open.
  if f.kind == skSegy and f.len > 0 and f.index.segy.binary.effectiveSamplesPerTrace == 0 and
      f.index.entries[0].numSamples == 0:
    var bad = false
    for d in f.log:
      if d.severity in {sevError, sevFatal}: bad = true
    if bad:
      result = "the binary header and the first trace header both say 0 samples per trace " &
        "and what follows is not made of trace headers, so the file looks damaged or is " &
        "not SEG-Y"

proc openSession*(path: string; progress: Progress = nil; cache = "";
    choice = OpenChoice()): Session =
  ## Opens `path` read-only, with its keys and gathers, reading its index
  ## from the index cache file `cache` when that is current, with the
  ## options `choice` (which may leave the cache alone: `usesCache`). Worker-only: it
  ## reads the file. Raises `IOError` or `OSError` when the file cannot be
  ## opened or is a damaged SEG-Y file (`damagedSegyWhy`), and parseSEG's
  ## `SegCancelledError` when `progress` returns false; problems with the data are in the file's log instead. The
  ## session keeps the file's size and time from when the open finishes
  ## (`Session.size`), not from before it. A file cut while this open reads
  ## is the file the session holds, so the watch does not open it again for
  ## that cut. Reading the size at the start and refusing a session that no
  ## longer matches would not stop while the file keeps changing: each open
  ## would mismatch and another would start.
  assertWorkerThread()
  # Checked here too, for a plainer message, and because parseSEG 0.11 loses
  # a small allocation when it cannot open the file it is given.
  if not fs.fileExists(path):
    raise newException(IOError, "there is no such file")
  fs.mappedRead(path) # the walk of its headers reads the map
  # parseSEG's record sources are objects with methods, which Nim cannot
  # prove GC-safe. Opening touches no global GC'd memory: parseSEG's viewer
  # guide opens files on a job thread, as here.
  let before = leapGenNow()
  var opened: SeismicFile
  {.cast(gcsafe).}:
    opened = openSeismic(path, keys = true, progress = progress,
      opts = openOptions(choice, cache, currentVendors()))
  let after = leapGenNow()
  let damaged = damagedSegyWhy(opened)
  if damaged.len > 0: raise newException(IOError, damaged)
  let info = fs.getFileInfo(path)
  result = newSession(path, move opened, info.size, info.lastWriteTime, choice)
  result.noteLeapRead(if before == after: before else: -1)

func endsEarly*(f: SeismicFile): bool =
  ## Whether the file ended before a structure it announces was complete when
  ## it was opened (parseSEG's `truncated` diagnostic in its log): a file
  ## still being written, or cut short before. (A cut while it is open is
  ## parseSEG's `cutShort`.)
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
    whole: bool; choice = OpenChoice()): Session =
  ## Opens `path` on job `ctx` with `choice`, through the index cache
  ## `cache` (read when current, saved after a walk; see `openWork`), when
  ## `choice` may use it.
  let cache = if choice.usesCache: cache else: ""
  let cached = cache.len > 0 and fs.fileExists(cache)
  ctx.setPhase(if cached: "reading the index cache" else: "indexing")
  let progress: Progress = proc (done, total: int64): bool {.gcsafe, raises: [].} =
    try:
      fs.mappedRead(path) # (tests: the walk's next pages come late)
    except OSError:
      discard             # a real drive that fails here ends the walk in parseSEG
    ctx.progress(done, total)
  result = openSession(path, progress, if cached: cache else: "", choice)
  ctx.checkCancelled() # the file closes here, on the thread that opened it
  if cache.len > 0 and result.file.kind != skUnknown:
    if result.file.fromCache:
      try:
        fs.setLastModificationTime(cache, getTime()) # used now: pruned last
      except OSError:
        discard
    elif result.file.demuxPath.len == 0 and not (whole and result.file.endsEarly):
      # (a demultiplexed copy is never cached)
      ctx.setPhase "saving the index cache"
      result.saveCache(cache, budget, to, ctx.id)
      ctx.checkCancelled()

proc openWork*(path: string; to: Poster; cache = "";
    cacheBudget = DefaultIndexCacheBudget; whole = false; choice = OpenChoice()): JobWork =
  ## The work of a job that opens `path` and posts its session (`mkOpened`).
  ## With a `cache` file (`indexCacheFile`), a current cache is read instead
  ## of walking the file, and a file that had none gets one. A cancel asked
  ## for at any point before the session is posted closes the file again and
  ## posts nothing. With `whole` (an open the file list's "Follow the
  ## latest" made, which shows the file only when it is complete), a file
  ## cut short gets no cache: it is still being written. `choice` gives the
  ## options of "Reopen with options" (`core/openchoice`); one that changes
  ## how the index is made leaves the cache alone.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var s = openCached(path, ctx, to, cache, cacheBudget, whole, choice)
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
          discard pf.close() # false when a worker stuck in a read is left to finish
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
  ## away. A file cut short while it is open is found by parseSEG's guard
  ## (`cutWhy`) and fails the job in plain words.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading a trace's headers"
    if not file[].inMemory: fs.mappedRead(path, headers = true) # (tests: the drive holds the thread)
    var keys: TraceKeys
    var rows: seq[HeaderRow]
    var vendor: VendorShown
    {.cast(gcsafe).}:
      let why = cutWhy(file[])
      if why.len > 0: raise newException(IOError, why)
      keys = file[].traceKeys([index])[0]
      rows = file[].traceHeaders(index)
      let (reg, choice) = currentVendorSet()
      vendor = vendorTrace(file[], index, reg, 0, choice)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkTraceRead, readKeys: keys, headerRows: move rows,
      readVendor: vendor)

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

proc treeNames*(root: string; cap: int; capped: var bool;
    visit: proc (found: int): bool {.gcsafe, raises: [].}): seq[string] =
  ## The files of folder `root` and of every folder below it (normalized): not
  ## hidden files or folders, and no folder that is a symbolic link is entered, so
  ## a loop of links ends. Stops at `cap` files (`capped` says so) and when `visit`,
  ## called every 256 files with how many were found, returns false (then what was
  ## found so far is returned). Raises `OSError` when `root` cannot be read; a
  ## folder below it that cannot be is left out.
  var stack = @[root]
  var n = 0
  while stack.len > 0:
    let dir = stack.pop()
    try:
      for kind, path in fs.walkDir(dir, checkDir = true):
        let name = path.extractFilename
        if name.startsWith("."): continue
        if kind == pcDir:
          stack.add path
        elif kind in {pcFile, pcLinkToFile}:
          if result.len >= cap:
            capped = true
            return
          result.add path.normalizedPath
        inc n
        if n mod 256 == 0 and not visit(result.len): return
    except OSError:
      if dir == root: raise

proc listedNames*(paths: openArray[string]; recursive = false; capped: var bool;
    visit: proc (found: int): bool {.gcsafe, raises: [].} = nil): seq[string] =
  ## The files `paths` name: each folder's files (and, when `recursive`, those of
  ## the folders below it: `treeNames`; otherwise not its subfolders), not hidden
  ## files, and each file itself; absolute, normalized, once each, in natural order
  ## of their names. Raises `OSError` when a folder cannot be read.
  for p in paths:
    if fs.dirExists(p):
      if recursive:
        result.add treeNames(p, MaxTreeFiles, capped, if visit.isNil:
          (proc (found: int): bool {.gcsafe, raises: [].} = true) else: visit)
      else:
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

func treeFolder(roots: openArray[string]; path: string): string =
  ## The subfolders of the first of `roots` that holds `path` (`folderOf`).
  for r in roots:
    if path.startsWith(r): return folderOf(r, path)

const ListPause = initDuration(milliseconds = 100) ## a scan posts at least this often

proc scanWork*(gen: uint64; paths: seq[string]; to: Poster; recursive = false): JobWork =
  ## The work of a job that lists the seismic and survey files `paths` name
  ## (folders and files, absolute) and posts them as `mkListed` messages for listing
  ## `gen`, in batches, the last one with `listDone`. One file alone stands
  ## for its folder: the folder is listed, and the first message names both
  ## (`listFolder`, `listChosen`); one folder is named in it too; the last
  ## one has every file it looked at (`listLooked`), for the folder's watch.
  ## With `recursive`, the folders' subfolders are listed too (`treeNames`: at
  ## most `MaxTreeFiles` files, each entry's `folder` is the path below the
  ## folder listed, and the scan says how many files it has looked at as it
  ## goes). Raises `OSError` when a folder cannot be read, `IOError` when the
  ## one path given does not exist; stops at a cancel.
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
      # A project's folder (or its project.nif named) is opened as the project;
      # a data folder never is, whatever it holds besides seismic files.
      if fs.fileExists(first.listFolder / ProjectFileName) and
          (first.listChosen.len == 0 or first.listChosen.extractFilename == ProjectFileName):
        first.listProject = first.listFolder
        first.listDone = true
        to.post move first
        return
      to.post move first
    var capped = false
    let post = to
    let jobId = ctx.id
    let names = listedNames(asked, recursive, capped, proc (found: int): bool {.gcsafe, raises: [].} =
      post.post Msg(job: jobId, kind: mkListed, listGen: gen, listVisited: found)
      not ctx.cancelled)
    if ctx.cancelled: raise newException(JobCancelledError, "cancelled")
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
          let sweep = if kind in SignatureFileKinds:
              readSweepInfo(path, kind.sweepKindOf, info.size)
            else: SweepInfo()
          looked.add WatchedFile(path: path, exists: true, kind: kind, size: info.size,
            modified: info.lastWriteTime, listed: true, unopened: not opened, sweep: sweep)
          if not opened: inc batch.unreadable
          elif kind == fkUnknown: inc batch.others
          else:
            batch.listed.add FileEntry(path: path, name: path.extractFilename, kind: kind,
              folder: if recursive: asked.treeFolder(path) else: "",
              size: info.size, modified: info.lastWriteTime, sweep: sweep)
      except OSError:
        inc batch.unreadable
      if batch.listed.len >= ListBatch or getMonoTime() - last >= ListPause:
        to.post move batch
        batch = Msg(job: ctx.id, kind: mkListed, listGen: gen)
        last = getMonoTime()
    discard ctx.progress(names.len, names.len)
    for p in asked:
      if fs.dirExists(p):
        try:
          for kind, path in fs.walkDir(p, checkDir = true):
            if kind in {pcDir, pcLinkToDir} and not path.extractFilename.startsWith("."):
              inc batch.subfolders
        except OSError:
          discard # the files were listed: the folder count is only a hint
    batch.listDone = true
    batch.listCapped = capped
    batch.listLooked = move looked
    to.post move batch

const KindBatch = 16 ## a kinds job posts at least this often (files)

proc kindsWork*(gen: uint64; vendorGen: int; asks: seq[WatchedFile]; vendors: VendorRegistry;
    to: Poster): JobWork =
  ## The work of a job that reads the kind of recording of each file of `asks` (path, size and
  ## time as listed) from the file (`kindOfFile`), a file at a time, and posts the
  ## answers as `mkKinds` messages for listing `gen` and the vendor maps' load `vendorGen`. A file that cannot be read has no kind;
  ## stops at a cancel (between files, and inside a file between its steps).
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading what the files are"
    var batch = Msg(job: ctx.id, kind: mkKinds, kindsGen: gen, kindsVendors: vendorGen)
    var last = getMonoTime()
    for i, a in asks:
      if not ctx.progress(i, asks.len): raise newException(JobCancelledError, "cancelled")
      var probe: KindProbe
      {.cast(gcsafe).}:
        probe = kindOfFile(a.path, vendors, proc () {.gcsafe.} = ctx.checkCancelled())
      let state = case probe.outcome
        of poNone: ksNone
        of poNotKnown: ksNotKnown
        of poMultiplexed: ksMultiplexed
        of poKnown: ksKnown
      batch.kinds.add KindAnswer(path: a.path, size: a.size, modified: a.modified, state: state,
        kind: probe.kind)
      if batch.kinds.len >= KindBatch or getMonoTime() - last >= ListPause:
        to.post move batch
        batch = Msg(job: ctx.id, kind: mkKinds, kindsGen: gen, kindsVendors: vendorGen)
        last = getMonoTime()
    if batch.kinds.len > 0: to.post move batch
