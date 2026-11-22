## Dear ImGui's checks do not abort a release build: `utils/assertprobe.nim` is
## built with `-d:release` and makes two checks fail while the frontend runs. It
## must carry on and show both in the Messages window.
##
## Seen to fail: without the force-included `imassert.h` (asserts.nim's
## `passC`), the release probe died with SIGABRT at the first check.
##
## The first build of the probe compiles Dear ImGui in release mode, which
## takes a minute; later runs reuse its cache. Needs a display, like tgui.
##
## Needs a display: it builds and starts the window code, which the Windows
## job (no display, no GLFW) does not.

import std/[os, osproc, strutils]

proc main*() =

  let
    testDir = currentSourcePath().parentDir
    exe = getTempDir() / ("viewseg_assertprobe_" & $getCurrentProcessId()).addFileExt(ExeExt)
  try:
    let build = execCmdEx(quoteShellCommand([getCurrentCompilerExe(), "c", "-d:release",
      "--hints:off", "--warnings:off", "--path:" & testDir.parentDir / "src", "-o:" & exe,
      testDir / "utils" / "assertprobe.nim"]))
    doAssert build.exitCode == 0, "the probe did not build:\n" & build.output
    let (output, code) = execCmdEx(quoteShell(exe))
    # (the probe's output holds the two checks it makes fail on purpose, so it is shown
    # only when an assertion below fails)
    doAssert code == 0, "the release probe exited with " & $code & ":\n" & output
    doAssert "Internal display error: Dear ImGui's check" in output, output
  finally:
    removeFile(exe)

when isMainModule:
  main()
