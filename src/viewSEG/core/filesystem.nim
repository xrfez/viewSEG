## The file system, as the viewer calls it: every call the viewer makes to
## the file system itself, for the user's files and its own, goes through
## `fs` (`fs.getFileInfo(path)`, `fs.walkDir(dir)`, `fs.open(f, path)`), so
## that a drive that answers slowly, stops answering or fails can be tested
## without one.
##
## A network drive can take seconds over a `stat`, stop answering for
## minutes, or go away while a file is open. The viewer copes by never
## calling the file system on the UI thread (docs/architecture.md,
## "Network drives") and by never waiting without a bound for a thread that
## may be stuck in it; this module is where that is tested from.
##
## - **The calls.** Each mirrors the `std/os` call of its name, with the same
##   results and errors, and is preceded by the *hook* (`setFsHook`): none in
##   the program, so a call costs one atomic load more than the call itself.
##   A test's hook (`tests/utils/faultyfs`) sees each call's kind (`FsOp`) and
##   path, and may make it slow (it returns late, or moves `now` on), hang
##   (it blocks until the test lets it go) or fail (it raises `OSError`, as a
##   drive that went away does: then a call that answers with a `bool` says
##   false, and a read raises `IOError`, as `std/os` does).
## - **Mapped reads.** parseSEG reads a seismic file through a memory map, and
##   its reads cannot go through here: a page of the map that the drive does
##   not deliver holds the thread that touched it, in the kernel, and one it
##   cannot deliver at all ends the program (SIGBUS on POSIX, an in-page
##   error on Windows) until parseSEG guards its maps. `mappedRead` marks the
##   places where such a read is about to happen (the open's walk of the
##   headers, each chunk a panel's reader takes in): it does nothing but call
##   the hook, so a test hangs or slows the thread there as the kernel would.
##   A read of header blocks alone (a file's own headers read with its open,
##   a record's or a trace's the Headers window shows) is marked apart
##   (`headers = true`, `foHeaders`), so that a test can hold those alone.
##   What stays untestable: a fault inside parseSEG's own decode threads, and
##   the crash on a page that cannot be read.
## - **Its clock.** `fs.now` is the monotonic clock plus what a test hook has
##   moved it on (`advanceFsClock`): the times the viewer measures against
##   the file system (how long a read took, how long a job has not answered)
##   are taken from it, so a test simulates a slow drive or a minute's hang
##   without waiting for it.
##
## Paths are made absolute and normalized without the file system
## (`core/state`'s `canonical`): that touches no drive. The program's
## assets (themes, fonts: `view/theme`, `ui/imgui/fonts`) and the probe of
## its own folders at start (`platform/paths`) are read outside this module,
## from the program's folder and the configuration folder.

import std/[atomics, monotimes, os, times]

export FileInfo, PathComponent, FileMode, MonoTime

type
  FsOp* = enum
    ## What a call does, for the hook.
    foStat = "stat"          ## asks a file's or a folder's kind, size or time, or whether it exists
    foList = "list"          ## reads a folder's names
    foOpen = "open"          ## opens a file, to read or to write
    foRead = "read"          ## reads bytes from a file opened here
    foWrite = "write"        ## makes a folder, moves, copies or removes a file, sets its time
    foMapped = "mapped read" ## the mapped memory of a seismic file is read next (parseSEG)
    foHeaders = "header read"
      ## the same, for header blocks alone: a file's own, a record's, a trace's

  FileSystem* = object
    ## The file system the viewer calls: `fs`. Its calls are those of
    ## `std/os` of the same names, through the hook.

  FsHook* = proc (op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].}
    ## Called before each call, on the thread that makes it; it may sleep,
    ## block, or raise `OSError` to fail the call.

const fs* = FileSystem()
  ## The file system: `fs.getFileInfo(path)`.

var
  hook: Atomic[pointer] # an `FsHook`; nil for none
  offset: Atomic[int64] # ns `now` is ahead of the monotonic clock

proc setFsHook*(h: FsHook) =
  ## Calls `h` before every call from now on; nil for none (tests).
  hook.store(cast[pointer](h))

proc advanceFsClock*(d: Duration) =
  ## Moves `fs.now` on by `d`, as if that much time had passed (tests: a slow
  ## or a hung drive, without waiting).
  discard offset.fetchAdd(d.inNanoseconds)

proc now*(_: FileSystem): MonoTime {.inline.} =
  ## The clock the viewer measures its waits on the file system with: the
  ## monotonic clock, plus what a test moved it on.
  getMonoTime() + initDuration(nanoseconds = offset.load(moRelaxed))

template enter(op: FsOp; path: string) =
  let h = cast[FsHook](hook.load(moRelaxed))
  if h != nil: h(op, path)

# ----------------------------------------------------------------- stat --

proc getFileInfo*(_: FileSystem; path: string; followSymlink = true): FileInfo {.
    raises: [OSError].} =
  ## `os.getFileInfo`: raises `OSError` when `path` cannot be looked at.
  enter(foStat, path)
  os.getFileInfo(path, followSymlink)

proc fileExists*(_: FileSystem; path: string): bool {.raises: [].} =
  ## `os.fileExists`: false also when the drive does not answer.
  try:
    enter(foStat, path)
  except OSError:
    return false
  os.fileExists(path)

proc dirExists*(_: FileSystem; path: string): bool {.raises: [].} =
  ## `os.dirExists`: false also when the drive does not answer.
  try:
    enter(foStat, path)
  except OSError:
    return false
  os.dirExists(path)

proc getFileSize*(_: FileSystem; path: string): int64 {.raises: [OSError].} =
  ## `os.getFileSize`.
  enter(foStat, path)
  os.getFileSize(path)

proc getLastModificationTime*(_: FileSystem; path: string): Time {.raises: [OSError].} =
  ## `os.getLastModificationTime`.
  enter(foStat, path)
  os.getLastModificationTime(path)

# ----------------------------------------------------------------- list --

iterator walkDir*(_: FileSystem; dir: string; relative = false;
    checkDir = false): tuple[kind: PathComponent; path: string] =
  ## `os.walkDir`: raises `OSError` when `dir` cannot be read (and, without
  ## `checkDir`, when the drive fails it).
  enter(foList, dir)
  for x in os.walkDir(dir, relative = relative, checkDir = checkDir):
    yield x

iterator walkFiles*(_: FileSystem; pattern: string): string =
  ## `os.walkFiles`.
  enter(foList, pattern.parentDir)
  for x in os.walkFiles(pattern):
    yield x

# ----------------------------------------------------------- open, read --

proc open*(_: FileSystem; f: var File; path: string; mode = fmRead): bool {.raises: [].} =
  ## `open(File)`: false when it cannot be opened, the drive failing too.
  try:
    enter(foOpen, path)
  except OSError:
    return false
  open(f, path, mode)

proc readBuffer*(_: FileSystem; f: File; path: string; buffer: pointer; len: Natural): int {.
    raises: [IOError].} =
  ## `readBuffer` from `f`, opened here from `path`.
  try:
    enter(foRead, path)
  except OSError as e:
    raise newException(IOError, e.msg)
  readBuffer(f, buffer, len)

proc readFile*(_: FileSystem; path: string): string {.raises: [IOError].} =
  ## `os.readFile`.
  try:
    enter(foOpen, path)
    enter(foRead, path)
  except OSError as e:
    raise newException(IOError, e.msg)
  system.readFile(path)

proc mappedRead*(_: FileSystem; path: string; headers = false) {.raises: [OSError].} =
  ## Marks that the mapped memory of seismic file `path` is read next (by
  ## parseSEG), its header blocks alone with `headers`: nothing but the hook,
  ## which may hold the thread as a drive that does not answer would, or
  ## raise as one that went away.
  enter(if headers: foHeaders else: foMapped, path)

# ---------------------------------------------------------------- write --

proc createDir*(_: FileSystem; dir: string) {.raises: [OSError, IOError].} =
  ## `os.createDir`.
  enter(foWrite, dir)
  os.createDir(dir)

proc moveFile*(_: FileSystem; source, dest: string) {.raises: [OSError, IOError, Exception].} =
  ## `os.moveFile`.
  enter(foWrite, dest)
  os.moveFile(source, dest)

proc copyFile*(_: FileSystem; source, dest: string) {.raises: [OSError, IOError, Exception].} =
  ## `os.copyFile`.
  enter(foWrite, dest)
  os.copyFile(source, dest)

proc removeFile*(_: FileSystem; path: string) {.raises: [OSError].} =
  ## `os.removeFile`.
  enter(foWrite, path)
  os.removeFile(path)

proc tryRemoveFile*(_: FileSystem; path: string): bool {.raises: [].} =
  ## `os.tryRemoveFile`: false when the file stays (the drive failing too).
  try:
    enter(foWrite, path)
  except OSError:
    return false
  os.tryRemoveFile(path)

proc setLastModificationTime*(_: FileSystem; path: string; t: Time) {.raises: [OSError].} =
  ## `os.setLastModificationTime`.
  enter(foWrite, path)
  os.setLastModificationTime(path, t)
