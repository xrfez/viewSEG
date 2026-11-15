## The file system seam (`core/fs`) and its test side (`tests/utils/faultyfs`):
## a slow, a hung and a failing path behave as a network drive would, and
## no module of `core` calls the file system but through the seam.
##
## Seen to fail: with `fs.walkDir` in `core/watch` written back as the
## `std/os` call, `everyCallGoesThroughTheSeam` names that line; with the
## hook's wait taken out of `fkHang`, `aHungCallWaits` fails.

import std/[monotimes, os, re, sequtils, strutils, times]
import viewSEG/core/[filejobs, filekinds, threads]
import utils/[faultyfs, waiting]

install()
let dir = getTempDir() / "viewSEG-tfilesystem-" & $getCurrentProcessId()
createDir(dir)
writeFile(dir / "a.txt", "hello")
let far = dir / "far"
createDir(far)
writeFile(far / "b.txt", "far away")

block aSlowCallMovesTheClockOn:
  fault(far, fkSlow, delay = initDuration(seconds = 3))
  let t0 = fs.now()
  doAssert fs.fileExists(far / "b.txt")
  doAssert fs.now() - t0 >= initDuration(seconds = 3), "a slow stat moves fs.now on"
  doAssert fs.fileExists(dir / "a.txt"), "another path is not slow"
  release(far)

block aFailingCallFails:
  fault(far, fkFail)
  doAssert not fs.fileExists(far / "b.txt"), "a failing drive: no such file"
  doAssert not fs.dirExists(far)
  doAssertRaises OSError: discard fs.getFileInfo(far / "b.txt")
  doAssertRaises IOError: discard fs.readFile(far / "b.txt")
  doAssert sniff(far / "b.txt") == fkUnknown
  doAssert fs.readFile(dir / "a.txt") == "hello"
  release(far)
  doAssert fs.readFile(far / "b.txt") == "far away", "the drive is back"

block aHungCallWaits:
  fault(far, fkHang, {foStat})
  var t: Thread[string]
  proc look(path: string) {.thread.} =
    markWorkerThread()
    doAssert fs.fileExists(path)
  createThread(t, look, far / "b.txt")
  doAssert waitUntil(hung() == 1), "the stat hangs"
  sleep 20
  doAssert hung() == 1, "and stays hung"
  release(far)
  joinThread(t)
  doAssert hung() == 0

block uiCallsAreKept:
  markUiThread()
  discard fs.fileExists(dir / "a.txt")
  doAssert uiCalls().len == 1 and "a.txt" in uiCalls()[0]
  markWorkerThread()

block everyCallGoesThroughTheSeam:
  # The std/os calls that touch the file system, called bare: each must be
  # `fs.<call>` in core (the seam itself excepted).
  let bare = re(r"(^|[^.A-Za-z_])(fileExists|dirExists|getFileInfo|getFileSize|" &
    r"getLastModificationTime|setLastModificationTime|walkDir|walkFiles|walkDirRec|" &
    r"readFile|writeFile|createDir|existsOrCreateDir|removeFile|tryRemoveFile|moveFile|" &
    r"copyFile|removeDir|readBuffer|expandFilename|open)\(")
  var found: seq[string]
  for path in walkFiles(currentSourcePath().parentDir.parentDir / "src/viewSEG/core/*.nim"):
    if path.extractFilename == "filesystem.nim": continue
    for i, line in toSeq(readFile(path).splitLines).pairs:
      let code = line.split("##")[0].split(" # ")[0]
      if code.strip.startsWith("#"): continue
      if code.contains(bare) and not code.contains(re"\b(w|tree|writer|nif)\.open\(|\bopen\(ctx\)"):
        found.add path.extractFilename & ":" & $(i + 1) & ": " & line.strip
  doAssert found.len == 0, "file-system calls past the seam:\n" & found.join("\n")

removeDir(dir)
echo "tfilesystem: ok"
