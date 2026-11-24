## `fs.moveNoReplace` on drives without hard links or without the no-replace
## rename: each step is run alone (`moveNoReplaceUsing`, a step left out
## answers as such a drive would), so the copy fallback really runs; and
## eight movers racing for one name leave exactly one winner, intact.
##
## Seen to fail: with the copy's `O_EXCL` taken out, `copyKeepsExisting`
## fails (the existing file is replaced); with the removal of the partial
## `dst` taken out, `failedCopyLeavesNothing` fails.

import std/os
import viewSEG/core/filesystem

when not defined(windows):
  from std/posix import EPERM, EOPNOTSUPP, EMLINK, EXDEV, ENOENT, EEXIST, EINVAL, ENOSYS, ENOTSUP

const Movers = 8

when not defined(windows):
  let dir = getTempDir() / "tmovenoreplace"
  var wins: array[Movers, bool]

  proc payload(tag: string): string =
    result = tag & ":"
    for i in 0 ..< 70_000: result.add char(ord('a') + i mod 26) # more than one chunk

  proc mover(i: int) {.thread.} =
    {.gcsafe.}:
      writeFile(dir / ("race-src" & $i), payload($i))
      wins[i] = moveNoReplaceUsing(dir / ("race-src" & $i), dir / "race-dst")

proc main*() =
  when defined(windows):
    discard
  else:
    const AllSteps = [{msRename, msLink, msCopy}, {msLink, msCopy}, {msCopy}, {msRename},
      {msLink}]

    removeDir(dir)
    createDir(dir)

    block moveEachStep:
      for i, steps in AllSteps:
        let src = dir / ("s" & $i)
        let dst = dir / ("d" & $i)
        writeFile(src, payload("x"))
        doAssert moveNoReplaceUsing(src, dst, steps), $steps
        doAssert readFile(dst) == payload("x"), $steps
        doAssert not fileExists(src), $steps

    block existingKept:
      for i, steps in AllSteps:
        let src = dir / ("es" & $i)
        let dst = dir / ("ed" & $i)
        writeFile(src, "new")
        writeFile(dst, "old")
        doAssert not moveNoReplaceUsing(src, dst, steps), $steps
        doAssert readFile(src) == "new" and readFile(dst) == "old", $steps

    block copyKeepsExisting:
      writeFile(dir / "ck-src", "new")
      writeFile(dir / "ck-dst", "old")
      doAssert not moveNoReplaceUsing(dir / "ck-src", dir / "ck-dst", {msCopy})
      doAssert readFile(dir / "ck-dst") == "old"

    block noStepLeft:
      writeFile(dir / "ns-src", "x")
      doAssertRaises OSError:
        discard moveNoReplaceUsing(dir / "ns-src", dir / "ns-dst", {})
      doAssert fileExists(dir / "ns-src") and not fileExists(dir / "ns-dst")

    block missingSource:
      for steps in AllSteps:
        doAssertRaises OSError:
          discard moveNoReplaceUsing(dir / "nothing", dir / "nowhere", steps)
        doAssert not fileExists(dir / "nowhere")

    block failedCopyLeavesNothing:
      writeFile(dir / "fc-src", payload("y"))
      doAssertRaises OSError:
        discard moveNoReplaceUsing(dir / "fc-src", dir / "fc-dst", {msCopy}, failCopyAfter = 10)
      doAssert not fileExists(dir / "fc-dst"), "the partial copy was removed"
      doAssert readFile(dir / "fc-src") == payload("y"), "the source is kept"

    block unlinkReportsAnError:
      for steps in [{msLink}, {msCopy}]:
        # the file is gone although an error was reported: the move is done
        writeFile(dir / "ug-src", "data")
        removeFile(dir / "ug-dst")
        doAssert moveNoReplaceUsing(dir / "ug-src", dir / "ug-dst", steps,
          faults = {mfUnlinkGone}), $steps
        doAssert readFile(dir / "ug-dst") == "data" and not fileExists(dir / "ug-src"), $steps
        # the file is still there: the move failed and left only `src`
        writeFile(dir / "uf-src", "data")
        doAssertRaises OSError:
          discard moveNoReplaceUsing(dir / "uf-src", dir / "uf-dst", steps,
            faults = {mfUnlinkFails})
        doAssert readFile(dir / "uf-src") == "data" and not fileExists(dir / "uf-dst"), $steps

    block cleanupKeepsAnotherFile:
      for steps in [{msLink}, {msCopy}]:
        writeFile(dir / "sw-src", payload("z"))
        doAssertRaises OSError:
          discard moveNoReplaceUsing(dir / "sw-src", dir / "sw-dst", steps,
            failCopyAfter = 10, faults = {mfDstSwapped, mfUnlinkFails})
        doAssert fileExists(dir / "sw-dst"), "a file that is not ours was removed: " & $steps
        doAssert readFile(dir / "sw-src") == payload("z")
        removeFile(dir / "sw-dst")

    block unknownWhetherSrcIsGone:
      for steps in [{msLink}, {msCopy}]:
        writeFile(dir / "us-src", "data")
        removeFile(dir / "us-dst")
        doAssertRaises OSError:
          discard moveNoReplaceUsing(dir / "us-src", dir / "us-dst", steps,
            faults = {mfUnlinkGone, mfStatFails})
        doAssert readFile(dir / "us-dst") == "data", "dst is kept: " & $steps
        removeFile(dir / "us-dst")
        removeFile(dir / "us-src")

    block aFailedCopyIsNotForgiven:
      # the copy fails partway while `src` is removed: never "moved"
      writeFile(dir / "fg-src", payload("w"))
      doAssertRaises OSError:
        discard moveNoReplaceUsing(dir / "fg-src", dir / "fg-dst", {msCopy},
          failCopyAfter = 10, faults = {mfSrcRemoved})
      doAssert not fileExists(dir / "fg-dst"), "the partial copy was removed"

    block errnoTable:
      doAssert noHardLinks(int(EPERM)) and noHardLinks(int(EOPNOTSUPP))
      doAssert noHardLinks(int(ENOTSUP)) and noRenameFlag(int(ENOTSUP))
      doAssert noHardLinks(int(EMLINK)) and noHardLinks(int(EXDEV))
      doAssert not noHardLinks(int(ENOENT)) and not noHardLinks(int(EEXIST))
      doAssert noRenameFlag(int(EINVAL)) and noRenameFlag(int(ENOSYS))
      doAssert not noRenameFlag(int(EEXIST)) and not noRenameFlag(int(ENOENT))

    block aRaceHasOneWinner:
      var threads: array[Movers, Thread[int]]
      let dst = dir / "race-dst"
      for i in 0 ..< Movers: createThread(threads[i], mover, i)
      joinThreads(threads)
      var winner = -1
      for i in 0 ..< Movers:
        if wins[i]:
          doAssert winner < 0, "two movers won"
          winner = i
        else:
          doAssert fileExists(dir / ("race-src" & $i)), "a loser keeps its part"
      doAssert winner >= 0
      doAssert readFile(dst) == payload($winner), "the winner's content is intact"
      doAssert not fileExists(dir / ("race-src" & $winner))

    removeDir(dir)
    echo "tmovenoreplace: ok"

when isMainModule:
  main()
