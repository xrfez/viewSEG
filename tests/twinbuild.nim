## The program compiles for Windows: the whole of `src/viewSEG.nim` is
## translated to C for `--os:windows` (`--compileOnly`, about ten seconds), so
## a name that only another system's branch declares (`when not
## defined(windows)`) fails here, not first in a release build. The C
## compile and the link are `nim winRelease`'s (zig and the Windows SDL3
## build, which CI's release job has and this suite does not).
##
## Seen to fail: with `ServerStopWait` declared in `remote/server`'s POSIX
## branch only (as `remote/control` names it on every system), "undeclared
## identifier: 'ServerStopWait'".
##
## The resource compiler `platform/winres` runs at compile time is replaced
## by `true` (`-d:windresExe`): the resources are linked, never compiled to C.

import std/[os, osproc, strutils]

proc main*() =

  when defined(windows):
    echo "twinbuild: skipped on Windows (a native build is the check there)"
  else:
    let
      root = currentSourcePath().parentDir.parentDir
      cache = getTempDir() / "viewSEG-twinbuild-" & $getCurrentProcessId()
    # imguin asks `nimble path glfw` when it compiles for Windows: the stub in
    # tools/winbuild answers nothing, as `nim winRelease` has it.
    putEnv("PATH", root / "tools" / "winbuild" & ":" & getEnv("PATH"))
    try:
      let build = execCmdEx(quoteShellCommand([getCurrentCompilerExe(), "c", "--hints:off",
        "--warnings:off", "--os:windows", "--cpu:amd64", "--compileOnly", "-d:release",
        "-d:danger", "-d:windresExe=true", "--nimcache:" & cache, root / "src" / "viewSEG.nim"]),
        workingDir = root)
      doAssert build.exitCode == 0, "the program does not compile for Windows:\n" &
        build.output.strip
    finally:
      removeDir(cache)
    block versionsAreFound:
      # Seen to fail: with `nimbleVersionIn` joining with `/` (the target's
      # backslash in a cross-build), the Windows build said "viewSEG unknown
      # (parseSEG unknown, processSEG unknown)".
      # under the repository, where nim.cfg's paths apply
      let src = root / "bin" / ("twinbuildversions" & $getCurrentProcessId() & ".nim")
      createDir(root / "bin")
      writeFile(src, "import viewSEG/core/versions\n" &
        "static:\n  doAssert ViewSEGVersion != \"unknown\", ViewSEGVersion\n" &
        "  doAssert ProcessSEGVersion != \"unknown\", ProcessSEGVersion\n" &
        "echo ViewSEGVersion\n")
      try:
        let built = execCmdEx(quoteShellCommand([getCurrentCompilerExe(), "c", "--hints:off",
          "--warnings:off", "--os:windows", "--cpu:amd64", "--compileOnly",
          "--path:" & root / "src",
          "--nimcache:" & cache & "-v", src]), workingDir = root)
        doAssert built.exitCode == 0, "the versions are not found in a Windows build:\n" &
          built.output.strip
      finally:
        removeFile(src)
        removeDir(cache & "-v")
    echo "twinbuild: ok"

when isMainModule:
  main()
