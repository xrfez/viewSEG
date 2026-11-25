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

import std/[atomics, monotimes, os, strutils, times]

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
  hook: Atomic[pointer]   # an `FsHook`; nil for none
  ioHook: Atomic[pointer] # a test seam: raises `IOError` (an unmapped read that fails)
  offset: Atomic[int64]   # ns `now` is ahead of the monotonic clock

proc setFsHook*(h: FsHook) =
  ## Calls `h` before every call from now on; nil for none (tests).
  hook.store(cast[pointer](h))

proc setIoHook*(h: proc (path: string) {.nimcall, gcsafe, raises: [IOError].}) =
  ## Calls `h` from `mappedRead` after the file-system hook; nil for none.
  ## A test uses it to make a read raise `IOError`, as an unmapped read that
  ## fails does (`parseSEG`'s `raiseReadFailed`).
  ioHook.store(cast[pointer](h))

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
  ## `os.getFileSize`; of the file a link points to, on Windows too (where
  ## `os.getFileSize` answers the link's own size, 0).
  enter(foStat, path)
  when defined(windows):
    os.getFileInfo(path).size
  else:
    os.getFileSize(path)

proc getLastModificationTime*(_: FileSystem; path: string): Time {.raises: [OSError].} =
  ## `os.getLastModificationTime`.
  enter(foStat, path)
  os.getLastModificationTime(path)

when defined(windows):
  from std/winlean import nil

  proc finalPathNameByHandle(h: winlean.Handle; buf: WideCString; size: int32;
    flags: int32): int32 {.importc: "GetFinalPathNameByHandleW", dynlib: "kernel32", stdcall.}

  proc finalPath(path: string): string =
    ## The path `path` leads to with its links resolved, as Windows gives it
    ## (the file's own letter case); "" when it cannot be had.
    let h = winlean.createFileW(newWideCString(path), 0'i32,
      winlean.FILE_SHARE_READ or winlean.FILE_SHARE_WRITE or winlean.FILE_SHARE_DELETE, nil,
      winlean.OPEN_EXISTING, winlean.FILE_FLAG_BACKUP_SEMANTICS, 0)
    if h == winlean.INVALID_HANDLE_VALUE:
      return ""
    var buf = newWideCString(1024)
    var got = finalPathNameByHandle(h, buf, 1024, 0)
    if got > 1024:
      buf = newWideCString(got)
      got = finalPathNameByHandle(h, buf, got, 0)
    discard winlean.closeHandle(h)
    if got > 0:
      result = $buf
      if result.startsWith("\\\\?\\UNC\\"):
        result = "\\\\" & result.substr(8)
      elif result.startsWith("\\\\?\\"):
        result = result.substr(4)

proc expandFilename*(_: FileSystem; path: string): string {.raises: [OSError].} =
  ## `os.expandFilename`: the full path, with its links resolved (on Windows
  ## `os.expandFilename` leaves links alone, so `GetFinalPathNameByHandle`
  ## does it, when it can).
  enter(foStat, path)
  when defined(windows):
    result = os.expandFilename(path)
    let final = finalPath(result)
    if final.len > 0:
      result = final
  else:
    result = os.expandFilename(path)

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

proc unmappedFail*(_: FileSystem; path: string) {.raises: [IOError].} =
  ## A test seam: raises `IOError` when a test has asked for an unmapped
  ## read that fails (`setIoHook`). Nothing in production. The Headers
  ## reader calls it beside `mappedRead`, so that failure stays in the part
  ## that read.
  let r = cast[proc (path: string) {.nimcall, gcsafe, raises: [IOError].}](ioHook.load(moRelaxed))
  if r != nil: r(path)

# ---------------------------------------------------------------- write --

proc writeBuffer*(_: FileSystem; f: File; path: string; buffer: pointer; len: Natural): int {.
    raises: [IOError].} =
  ## `writeBuffer` to `f`, opened here from `path`.
  try:
    enter(foWrite, path)
  except OSError as e:
    raise newException(IOError, e.msg)
  writeBuffer(f, buffer, len)

proc createDir*(_: FileSystem; dir: string) {.raises: [OSError, IOError].} =
  ## `os.createDir`.
  enter(foWrite, dir)
  os.createDir(dir)

proc moveFile*(_: FileSystem; source, dest: string) {.raises: [OSError, IOError, Exception].} =
  ## `os.moveFile`. On Windows, a file another program has open (a reader of
  ## the document, a virus scanner, the indexer) cannot be replaced until that
  ## program lets go, which takes milliseconds: the move is tried again for
  ## about a fifth of a second when Windows says access denied, sharing or lock
  ## violation, before it fails.
  enter(foWrite, dest)
  when defined(windows):
    var attempt = 0
    while true:
      try:
        os.moveFile(source, dest)
        return
      except OSError as e:
        inc attempt
        if attempt >= 10 or e.errorCode notin [5'i32, 32, 33]:
          raise
        sleep 20
  else:
    os.moveFile(source, dest)

proc copyFile*(_: FileSystem; source, dest: string) {.raises: [OSError, IOError, Exception].} =
  ## `os.copyFile`.
  enter(foWrite, dest)
  os.copyFile(source, dest)

proc removeFile*(_: FileSystem; path: string) {.raises: [OSError].} =
  ## `os.removeFile`.
  enter(foWrite, path)
  os.removeFile(path)

proc tryRemoveDir*(_: FileSystem; dir: string): bool {.raises: [].} =
  ## `os.removeDir` of an empty folder: false when it stays (not empty, or
  ## the drive failing too).
  try:
    enter(foWrite, dir)
    os.removeDir(dir)
    true
  except OSError:
    false

proc tryRemoveFile*(_: FileSystem; path: string): bool {.raises: [].} =
  ## `os.tryRemoveFile`: false when the file stays (the drive failing too).
  try:
    enter(foWrite, path)
  except OSError:
    return false
  when defined(windows):
    # a file another program has open stays until it lets go (see `moveFile`):
    # tried again on access denied, sharing and lock violations only
    for attempt in 1 .. 5:
      if os.tryRemoveFile(path): return true
      if attempt == 5 or osLastError().int32 notin [5'i32, 32, 33]: return false
      sleep 20
    false
  else:
    os.tryRemoveFile(path)

proc writeTextAtomic*(_: FileSystem; path, text: string) {.raises: [IOError, OSError, Exception].} =
  ## `text` written to `path` through a temporary file beside it, flushed, then
  ## moved over `path`: a reader sees the old file or the whole new one. A
  ## failure leaves no temporary file behind.
  let tmp = path & "." & $getCurrentProcessId() & ".tmp"
  var f: File
  if not fs.open(f, tmp, fmWrite): raise newException(IOError, "cannot write " & tmp)
  try:
    if text.len > 0 and fs.writeBuffer(f, tmp, unsafeAddr text[0], text.len) != text.len:
      raise newException(IOError, "the disk did not take " & tmp)
    flushFile(f)
  finally:
    close(f)
  var moved = false
  try:
    fs.moveFile(tmp, path)
    moved = true
  finally:
    if not moved: discard fs.tryRemoveFile(tmp)

proc setLastModificationTime*(_: FileSystem; path: string; t: Time) {.raises: [OSError].} =
  ## `os.setLastModificationTime`.
  enter(foWrite, path)
  os.setLastModificationTime(path, t)

# ----------------------------------------------------------------- lock --

when defined(windows):
  from std/winlean import nil
else:
  from std/posix import nil
  proc c_flock(fd: cint; op: cint): cint {.importc: "flock", header: "<sys/file.h>".}
  const LockEx = 2.cint # LOCK_EX
  const LockNb = 4.cint # LOCK_NB

type
  FileLock* = object
    ## A lock between programs taken on a file (`lockFile`); none when not
    ## `locked`.
    when defined(windows):
      handle: winlean.Handle
    else:
      fd: cint
    locked*: bool
    failure*: string ## why the file could not be opened (not locked by another); "" otherwise

proc lockFile*(_: FileSystem; path: string; wait: Duration): FileLock {.raises: [].} =
  ## Takes the lock of `path` (made when there is none) that other programs
  ## (and other `FileLock`s of this one) taking it wait for, waiting up to
  ## `wait` for one that holds it; not `locked` when it could not be taken
  ## by then, or the drive fails. The system lets it go when the program
  ## ends, however it ends. Let it go with `unlock`.
  try:
    enter(foOpen, path)
  except OSError as e:
    return FileLock(failure: e.msg)
  let deadline = getMonoTime() + wait
  when defined(windows):
    let name = newWideCString(path)
    while true:
      # opened with no sharing: a second open fails while this one is open
      let h = winlean.createFileW(name, winlean.GENERIC_READ or winlean.GENERIC_WRITE, 0, nil,
        winlean.OPEN_ALWAYS, winlean.FILE_ATTRIBUTE_NORMAL, 0)
      if h != winlean.INVALID_HANDLE_VALUE: return FileLock(handle: h, locked: true)
      let err = osLastError()
      # a sharing or lock violation is another program holding it; any other
      # failure is the file itself
      if err.int32 != 32 and err.int32 != 33: return FileLock(failure: osErrorMsg(err))
      if getMonoTime() >= deadline: return
      sleep 5
  else:
    let fd = posix.open(path.cstring, posix.O_RDWR or posix.O_CREAT or posix.O_CLOEXEC, 0o666)
    if fd < 0: return FileLock(failure: osErrorMsg(osLastError()))
    while true:
      # per open file: two locks of one program on the same file exclude each other too
      if c_flock(fd, LockEx or LockNb) == 0: return FileLock(fd: fd, locked: true)
      if getMonoTime() >= deadline:
        discard posix.close(fd)
        return
      sleep 5

proc unlock*(_: FileSystem; l: var FileLock) {.raises: [].} =
  ## Lets the lock `lockFile` took go.
  if l.locked:
    when defined(windows): discard winlean.closeHandle(l.handle)
    else: discard posix.close(l.fd)
    l.locked = false

proc createExclusive*(_: FileSystem; path: string): bool {.raises: [OSError].} =
  ## Creates a new empty file at `path`. True when it did. False when `path`
  ## already exists: that file is left as it is and never opened. Raises
  ## `OSError` when it cannot be created for another reason (no folder, a
  ## drive that does not answer).
  enter(foWrite, path)
  when defined(windows):
    let name = newWideCString(path)
    let h = winlean.createFileW(name, winlean.GENERIC_WRITE, 0, nil, winlean.CREATE_NEW,
      winlean.FILE_ATTRIBUTE_NORMAL, 0)
    if h != winlean.INVALID_HANDLE_VALUE:
      discard winlean.closeHandle(h)
      return true
    if osLastError().int32 == 80: return false # ERROR_FILE_EXISTS
    raiseOSError(osLastError())
  else:
    let fd = posix.open(cstring(path), posix.O_WRONLY or posix.O_CREAT or posix.O_EXCL or
      posix.O_CLOEXEC, 0o666)
    if fd >= 0:
      discard posix.close(fd)
      return true
    if posix.errno == posix.EEXIST: return false
    raiseOSError(osLastError())

type
  MoveStep* = enum
    ## The ways `moveNoReplace` moves a file, in the order it tries them.
    msRename ## one call that renames and refuses to replace (Linux, macOS)
    msLink   ## a hard link at `dst`, then `src` removed
    msCopy   ## `dst` created exclusively and filled, then `src` removed

when not defined(windows):
  type StepResult = enum
    srMoved
    srExists      ## `dst` exists: nothing was changed
    srUnsupported ## this drive or system cannot do the step: try the next

  const AtFdcwd = -100.cint # AT_FDCWD
  when defined(linux):
    proc syscall(n: clong): clong {.importc, header: "<unistd.h>", varargs.}
    let sysRenameat2 {.importc: "SYS_renameat2", header: "<sys/syscall.h>".}: clong
  elif defined(macosx):
    proc renamexNp(src, dst: cstring; flags: cuint): cint
      {.importc: "renamex_np", header: "<stdio.h>".}

  proc noHardLinks*(err: int): bool =
    ## Whether `err` (an `errno`) from `link` says that the drive has no
    ## hard links or not here (FAT, exFAT, many network shares and FUSE
    ## mounts), so that the step must give way to a copy.
    err in [int(posix.EPERM), int(posix.EOPNOTSUPP), int(posix.ENOTSUP), int(posix.ENOSYS),
      int(posix.EMLINK), int(posix.EXDEV), int(posix.EINVAL)]

  proc noRenameFlag*(err: int): bool =
    ## Whether `err` from the no-replace rename says that the kernel or the
    ## drive does not know the flag (or the two names are on different
    ## drives), so that the step must give way to a link.
    err in [int(posix.ENOSYS), int(posix.EINVAL), int(posix.EOPNOTSUPP), int(posix.ENOTSUP),
      int(posix.EXDEV), int(posix.EPERM)]

  proc failWith(err: int) {.noreturn, raises: [OSError].} =
    raiseOSError(OSErrorCode(err))

  proc renameStep(src, dst: string): StepResult {.raises: [OSError].} =
    when defined(linux) or defined(macosx):
      when defined(linux):
        let rc = syscall(sysRenameat2, clong(AtFdcwd), cstring(src), clong(AtFdcwd),
          cstring(dst), clong(1)) # RENAME_NOREPLACE
      else:
        let rc = renamexNp(cstring(src), cstring(dst), 4.cuint)             # RENAME_EXCL
      if rc == 0: return srMoved
      let err = int(posix.errno)
      if err == int(posix.EEXIST): return srExists
      if noRenameFlag(err): return srUnsupported
      failWith(err)
    else:
      discard src
      discard dst
      srUnsupported

  type MoveFault* = enum
    ## What a test makes go wrong in `moveNoReplaceUsing`.
    mfUnlinkGone  ## removing `src` removes it but reports an error (a retried unlink)
    mfUnlinkFails ## removing `src` fails and leaves it
    mfDstSwapped  ## the `dst` this call made is replaced by another file before cleanup
    mfStatFails   ## looking at `src` after a failed removal answers EIO
    mfSrcRemoved  ## `src` is removed after the copy loop, as if by another program

  type FileId = tuple[dev: posix.Dev; ino: posix.Ino]

  proc idOf(st: posix.Stat): FileId =
    (st.st_dev, st.st_ino)

  proc idOfPath(path: string; id: var FileId): bool =
    ## False when `path` cannot be examined; its errno is then in `posix.errno`.
    var st: posix.Stat
    result = posix.lstat(cstring(path), st) == 0
    if result: id = idOf(st)

  proc dropOurs(dst: string; ours: FileId; faults: set[MoveFault]) =
    ## Removes `dst` only while it is still the file this call made.
    if mfDstSwapped in faults:
      discard posix.unlink(cstring(dst))
      let fd = posix.open(cstring(dst), posix.O_WRONLY or posix.O_CREAT or posix.O_EXCL, 0o666)
      if fd >= 0: discard posix.close(fd)
    var now: FileId
    if idOfPath(dst, now) and now == ours: discard posix.unlink(cstring(dst))

  proc removeSrc(src: string; faults: set[MoveFault]): int =
    ## Removes `src`; the errno of a failure, else 0.
    if mfUnlinkFails in faults: return int(posix.EIO)
    let rc = posix.unlink(cstring(src))
    if mfUnlinkGone in faults: return int(posix.EIO)
    if rc != 0: int(posix.errno) else: 0

  type SrcState = enum
    ssPresent ## `src` is certainly there
    ssGone    ## `src` is certainly not there
    ssUnknown ## the drive could not say

  proc srcState(src: string; faults: set[MoveFault]): SrcState =
    ## An unlink that reported an error may still have removed the file (a
    ## retried unlink on a network drive): then the move is complete.
    var id: FileId
    if mfStatFails in faults: ssUnknown
    elif idOfPath(src, id): ssPresent
    elif posix.errno == posix.ENOENT: ssGone
    else: ssUnknown

  proc failKept(err: int) {.noreturn, raises: [OSError].} =
    ## The removal of `src` failed and the drive cannot say whether `src` is
    ## still there: `dst` stays, so that the data is on the drive in any case.
    raiseOSError(OSErrorCode(err), "the destination was kept, the source may be gone")

  proc finishRemoval(src, dst: string; ours: FileId; err: int;
      faults: set[MoveFault]) {.raises: [OSError].} =
    ## After a failed removal of `src`: returns when the move is complete
    ## (`src` is certainly gone); else raises, and drops `dst` only while
    ## `src` is certainly present.
    case srcState(src, faults)
    of ssGone: discard
    of ssPresent:
      dropOurs(dst, ours, faults)
      failWith(err)
    of ssUnknown: failKept(err)

  proc linkStep(src, dst: string; faults: set[MoveFault]): StepResult {.raises: [OSError].} =
    var ours: FileId # the link shares `src`'s file
    if not idOfPath(src, ours): failWith(int(posix.errno))
    if posix.link(cstring(src), cstring(dst)) == 0:
      let err = removeSrc(src, faults)
      if err != 0: finishRemoval(src, dst, ours, err, faults)
      return srMoved
    let err = int(posix.errno)
    if err == int(posix.EEXIST): return srExists
    if noHardLinks(err): return srUnsupported
    failWith(err)

  proc copyStep(src, dst: string; failAfter: int;
      faults: set[MoveFault]): StepResult {.raises: [OSError].} =
    ## Creates `dst` exclusively, so an existing file is never touched and
    ## the one made here is ours to remove again on any failure.
    let inFd = posix.open(cstring(src), posix.O_RDONLY or posix.O_CLOEXEC)
    if inFd < 0: failWith(int(posix.errno))
    let outFd = posix.open(cstring(dst), posix.O_WRONLY or posix.O_CREAT or posix.O_EXCL or
      posix.O_CLOEXEC, 0o666)
    if outFd < 0:
      let err = int(posix.errno)
      discard posix.close(inFd)
      if err == int(posix.EEXIST): return srExists
      failWith(err)
    var
      ours: FileId # made by the open above, so ours to remove again
      st: posix.Stat
    if posix.fstat(outFd, st) == 0: ours = idOf(st)
    else:
      let err = int(posix.errno)
      discard posix.close(inFd)
      discard posix.close(outFd)
      discard posix.unlink(cstring(dst)) # just made by the open above
      failWith(err)
    var
      buf: array[65536, byte]
      err = 0
      written = 0
    while err == 0:
      if failAfter >= 0 and written >= failAfter:
        err = int(posix.EIO) # injected by a test
      else:
        let n = posix.read(inFd, addr buf[0], buf.len)
        if n == 0: break
        if n < 0:
          if posix.errno != posix.EINTR: err = int(posix.errno)
        else:
          var at = 0
          while at < n and err == 0:
            let w = posix.write(outFd, addr buf[at], n - at)
            if w < 0:
              if posix.errno != posix.EINTR: err = int(posix.errno)
            elif w == 0:
              err = int(posix.EIO) # no progress: not a reason to spin
            else:
              at += w
          written += n
    if err == 0 and posix.fsync(outFd) != 0: err = int(posix.errno)
    if posix.close(outFd) != 0 and err == 0: err = int(posix.errno)
    discard posix.close(inFd)
    if mfSrcRemoved in faults: discard posix.unlink(cstring(src))
    if err != 0: # the copy itself failed: whatever became of `src`, `dst` is partial
      dropOurs(dst, ours, faults)
      failWith(err)
    let removed = removeSrc(src, faults)
    if removed != 0: finishRemoval(src, dst, ours, removed, faults)
    srMoved

  proc moveNoReplaceUsing*(src, dst: string; steps: set[MoveStep] = {msRename, msLink, msCopy};
      failCopyAfter = -1; faults: set[MoveFault] = {}): bool {.raises: [OSError].} =
    ## `moveNoReplace` without the hook, limited to `steps`: a step left out
    ## answers as a drive that cannot do it would, so the next one runs.
    ## `failCopyAfter >= 0` makes the copy fail once that many bytes were
    ## written, and `faults` make the removal of `src` or the cleanup go wrong
    ## (both for tests). Raises `OSError` when no step can move the file.
    var r = srUnsupported
    if msRename in steps: r = renameStep(src, dst)
    if r == srUnsupported and msLink in steps: r = linkStep(src, dst, faults)
    if r == srUnsupported and msCopy in steps: r = copyStep(src, dst, failCopyAfter, faults)
    case r
    of srMoved: true
    of srExists: false
    of srUnsupported: failWith(int(posix.EOPNOTSUPP))

proc moveNoReplace*(_: FileSystem; src, dst: string): bool {.raises: [OSError].} =
  ## Moves `src` onto `dst` only when `dst` does not exist. True when it did:
  ## `src` is gone and `dst` is that file. False when `dst` already exists:
  ## both files are left as they are, and neither is opened. Raises `OSError`
  ## for any other failure (no folder, a drive that does not answer). Never
  ## replaces a file, even when two movers race for `dst`. Atomic where the
  ## system can rename without replacing or link (so another program cannot
  ## see a partial `dst`); on a drive with neither (FAT, exFAT, some network
  ## shares) or across drives it copies into a `dst` created exclusively, and
  ## removes that `dst` again when the copy fails.
  enter(foWrite, dst)
  when defined(windows):
    const
      ErrorAlreadyExists = 183'i32 # not a winlean constant
      ErrorFileExists = 80'i32
    let fromName = newWideCString(src)
    let toName = newWideCString(dst)
    # no MOVEFILE_REPLACE_EXISTING: fail when `dst` exists. COPY_ALLOWED (2)
    # lets a move across drives copy, and never replaces either; WRITE_THROUGH
    # (8) flushes such a copy before the call returns.
    if winlean.moveFileExW(fromName, toName, 2 or 8) != 0: return true
    let err = osLastError().int32
    if err == ErrorAlreadyExists or err == ErrorFileExists: return false
    raiseOSError(osLastError())
  else:
    moveNoReplaceUsing(src, dst)
