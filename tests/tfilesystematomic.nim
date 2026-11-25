## `fs.writeTextAtomic` (`core/filesystem`): the text lands whole, and a write
## or a move that fails leaves the old file as it was and no temporary file
## beside it.
##
## Seen to fail: with the clean-up of the temporary file removed from
## `writeTextAtomic`, "a temporary file was left behind".

import std/[os, strutils]
import viewSEG/core/filesystem

var failNext = ""

proc faulty(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  {.cast(gcsafe).}:
    if op == foWrite and failNext.len > 0 and
        ((failNext == "write" and path.endsWith(".tmp")) or
        (failNext == "move" and not path.endsWith(".tmp"))):
      failNext = ""
      raise newException(OSError, "disk full (simulated)")

proc leftovers(dir: string): seq[string] =
  for kind, p in walkDir(dir):
    result.add p.extractFilename

proc main*() =
  let dir = getTempDir() / ("vs-atomic-" & $getCurrentProcessId())
  createDir(dir)
  let target = dir / "log.txt"
  block whole:
    fs.writeTextAtomic(target, "hello")
    doAssert readFile(target) == "hello"
    fs.writeTextAtomic(target, "")
    doAssert readFile(target) == ""
    writeFile(target, "old")
    doAssert leftovers(dir) == @["log.txt"], $leftovers(dir)
  for failure in ["write", "move"]:
    writeFile(target, "old")
    setFsHook(faulty)
    failNext = failure
    var raised = false
    try:
      fs.writeTextAtomic(target, "new text")
    except CatchableError:
      raised = true
    setFsHook(nil)
    doAssert raised, failure & " did not raise"
    doAssert readFile(target) == "old", "the old file changed"
    doAssert leftovers(dir) == @["log.txt"], "a temporary file was left behind: " & $leftovers(dir)
  removeDir(dir)
  echo "tfilesystematomic: ok"

when isMainModule:
  main()
