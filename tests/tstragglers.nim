## What a thread left running at the quit reads is still there when it goes
## on: `utils/stragglers.nim`, built under AddressSanitizer, quits while a
## thread is held where a drive that does not answer, or a long step, holds
## it, destroys the state, lets the thread go on and waits for it. A read of
## freed memory is ASan's report and a failed run (scenarios: the probe's
## module documentation).
##
## Seen to fail: `joinStep`, with `keepForStragglers` not keeping the survey
## a join's step applies (`joining.geometry`): "heap-use-after-free" in
## parseSEG's `applySurvey`, under `joinApplyWork`. `leftReader`, with the
## quit not counting the holds left (a reader left earlier is none of the
## panels' readers): the quit said every thread had ended, and the file was
## closed under the reader ("heap-use-after-free" in parseSEG's
## `joinedGroups`, under the reader's `serve`). `leftCheck`, with the
## relations of an abandoned check let go when it was listed cancelled:
## "heap-use-after-free" in processSEG's `recordCompleteness`, under
## `checkWork`. `leftInspector` (the Headers window's reader left in a
## drive, then the quit), with the jobs' memory freed at the destruction
## although holds were left (`Jobs.=destroy` not counting them):
## "heap-use-after-free" in `jobs.endHold`, under the inspector's `run`.
##
## The probe's first build compiles the core with ASan (a minute or two);
## later runs reuse its cache.

import std/[os, osproc, strutils]

const Scenarios = ["joinStep", "leftReader", "leftCheck", "leftInspector"]

when not defined(posix):
  echo "tstragglers: skipped (AddressSanitizer: gcc or clang on POSIX)"
else:
  let
    testDir = currentSourcePath().parentDir
    exe = getTempDir() / ("viewseg_stragglers_" & $getCurrentProcessId())
  try:
    let build = execCmdEx(quoteShellCommand([getCurrentCompilerExe(), "c",
      "-d:addressSanitizer", "--hints:off", "--warnings:off",
      "--path:" & testDir.parentDir / "src", "--path:" & testDir, "-o:" & exe,
      testDir / "utils" / "stragglers.nim"]))
    doAssert build.exitCode == 0, "the probe did not build:\n" & build.output
    # The memory a quit leaves to its stragglers is kept to the end, by design.
    putEnv("ASAN_OPTIONS", "detect_leaks=0:abort_on_error=0")
    for s in Scenarios:
      let (output, code) = execCmdEx(quoteShell(exe) & " " & s)
      echo output.strip
      doAssert code == 0 and "AddressSanitizer" notin output,
        "scenario " & s & " exited with " & $code & ":\n" & output
  finally:
    removeFile(exe)
  echo "tstragglers: ok"
