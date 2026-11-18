## A GUI test run fails when Dear ImGui finds a mistake in what the program
## draws: a Pop...() with nothing to pop, a Begin without its End, a leaked ID.
## A debug build aborts at the check; a release build carries on, and `run`
## raises at its end for a run with a frame hook. `utils/imbalanceprobe.nim` is
## built in both modes and makes one such mistake on request.
##
## Seen to fail: with the guard left out of `run`, the release probe with
## `stray` exited 0 (the debug build aborts without any guard).
##
## Needs a display: run under the tester, which gives each file its own.

import std/[os, osproc, strutils]

proc probe(mode, arg: string): tuple[output: string, exitCode: int] =
  let
    testDir = currentSourcePath().parentDir
    exe = getTempDir() / ("viewseg_imbalance_" & mode & "_" & $getCurrentProcessId()).addFileExt(ExeExt)
  try:
    var args = @[getCurrentCompilerExe(), "c", "--hints:off", "--warnings:off",
      "--path:" & testDir.parentDir / "src", "-o:" & exe]
    if mode == "release": args.add "-d:release"
    args.add testDir / "utils" / "imbalanceprobe.nim"
    let build = execCmdEx(quoteShellCommand(args))
    doAssert build.exitCode == 0, "the probe did not build:\n" & build.output
    result = execCmdEx(quoteShellCommand([exe, arg]))
  finally:
    removeFile(exe)

proc main*() =
  for mode in ["debug", "release"]:
    let fine = probe(mode, "ok")
    doAssert fine.exitCode == 0, mode & ": a balanced run must pass:\n" & fine.output
    let bad = probe(mode, "stray")
    doAssert bad.exitCode != 0, mode & ": a Pop with nothing pushed must fail the run"
    doAssert "PopStyleColor" in bad.output, mode & ":\n" & bad.output
  echo "tguiimbalance: ok"

when isMainModule: main()
