# Strict build configuration and task orchestrator for viewSEG
import std/[os, strutils]

switch("outdir", "bin")

# parseSEG is compiled into this program, so these flags decide its decode
# speed (parseSEG README, "Build flags"). x86-64-v3 (AVX2: Intel 2013+ / AMD
# Zen 2017+) runs its sample decoders up to 2x faster than baseline x86-64; a
# v3 binary crashes with an illegal instruction on CPUs without AVX2, so the
# portable tasks pass -d:baselineCpu. Other CPUs (arm64) keep the default.
# zig cc rejects gcc's CPU names, so the zig tasks pass -d:zigcc for its own.
# -d:release is passed per task: a global define would make `nim test` and
# `nim nimDebug` release builds.
when defined(amd64) and not defined(baselineCpu):
  when defined(zigcc):
    switch("passC", "-mcpu=x86_64_v3")
  else:
    switch("passC", "-march=x86-64-v3")
  switch("define", "cpuTarget=x86-64-v3") # printed by the benchmarks

const baseTarget = when defined(amd64): " --passC:-march=x86-64 " else: " "

let zigccExe =
  if findExe("zigcc").len > 0:
    "zigcc"
  elif defined(windows):
    "tools/zigcc.cmd"
  else:
    "./tools/zigcc"

task nimRelease, "Build native host-optimized binary (aggressive speed, march=native)":
  ## Compiles high-performance binary optimized strictly for the current host CPU.
  selfExec "c -d:release -d:danger --opt:speed --passC:\"-march=native -mtune=native\" src/viewSEG.nim"

task nimPortable, "Build portable binary for generic CPUs (stripped, baseline instructions)":
  ## Compiles stripped, portable binary targeting generic CPU baseline compatibility.
  selfExec "c -d:release -d:baselineCpu --opt:size --passC:\"-mtune=generic\" --passL:\"-s\"" & baseTarget & "src/viewSEG.nim"

task nimDebug, "Build debug binary with stack traces and assertions":
  ## Compiles debug binary with full assertions, line tracing, and symbols.
  selfExec "c --debuginfo:on --assertions:on --lineTrace:on --stackTrace:on src/viewSEG.nim"

task zigRelease, "Build native host-optimized binary using Zig CC (O3, march=native)":
  ## Compiles native binary using Zig toolchain with -O3 optimization for host CPU.
  selfExec "c -d:zigcc --cc:clang --clang.exe:\"" & zigccExe & "\" --clang.linkerexe:\"" & zigccExe & "\" -d:release -d:danger --opt:speed --passC:\"-O3 -march=native\" src/viewSEG.nim"

task zigPortable, "Build portable binary for generic CPUs using Zig CC (stripped, baseline instructions)":
  ## Compiles stripped binary using Zig toolchain targeting generic baseline CPUs and size reduction.
  selfExec "c -d:zigcc --cc:clang --clang.exe:\"" & zigccExe & "\" --clang.linkerexe:\"" & zigccExe & "\" -d:release -d:baselineCpu --opt:size --passC:\"-Oz\" --passC:\"-mcpu=baseline\" --passL:\"-s\" src/viewSEG.nim"

task zigDebug, "Build debug binary using Zig CC with debug symbols":
  ## Compiles debug binary using Zig toolchain preserving debug symbols.
  selfExec "c -d:zigcc --cc:clang --clang.exe:\"" & zigccExe & "\" --clang.linkerexe:\"" & zigccExe & "\" --debuginfo:on src/viewSEG.nim"

task winRelease, "Cross-build bin/viewSEG.exe for Windows x86-64 with zig cc (no MinGW needed)":
  ## zig ships the MinGW-w64 headers and import libraries, a linker and a resource
  ## compiler (`zig rc`, used by src/viewSEG/platform/winres.nim), so this works
  ## from the Linux container. AVX2 build (x86-64-v3) like nimRelease; add
  ## -d:baselineCpu for older CPUs.
  selfExec "c -d:zigcc --os:windows --cpu:amd64 --cc:clang --clang.exe:\"" & zigccExe &
    "\" --clang.linkerexe:\"" & zigccExe & "\" --passC:\"-target x86_64-windows-gnu\"" &
    " --passL:\"-target x86_64-windows-gnu\" -d:release -d:danger --opt:speed" &
    " -o:bin/viewSEG.exe src/viewSEG.nim"

# Every test task builds the runner tests/tester.nim once, in debug; the runner
# compiles and runs each tests/t*.nim with the flags given after it.
const tester = "c -r --hints:off tests/tester.nim"

task test, "Run test suite":
  ## Runs every tests/t*.nim in a debug build.
  selfExec tester

task testRelease, "Run the test suite in -d:release and -d:danger builds":
  ## Runs the suite with the optimization levels the release builds use.
  selfExec tester & " -d:release"
  selfExec tester & " -d:danger"

task asan, "Run the test suite under AddressSanitizer (-d:useMalloc)":
  ## tests/config.nims turns -d:addressSanitizer into the ASan switches.
  selfExec tester & " -d:addressSanitizer"


proc nimSources(dir: string): seq[string] =
  ## Every .nim file under `dir`, recursively (NimScript has no walkDirRec).
  for f in listFiles(dir):
    if f.endsWith(".nim"):
      result.add f
  for d in listDirs(dir):
    result.add nimSources(d)

task fmt, "Format codebase via nimpretty":
  ## Formats every source, test and tool file in place.
  for dir in ["src", "tests", "tools", "bench"]:
    if dirExists(dir):
      for f in nimSources(dir):
        exec "nimpretty --indent:2 --maxLineLen:100 " & quoteShell(f)

task docs, "Generate HTML documentation":
  ## Emits HTML documentation into htmldocs directory.
  selfExec "doc --project --outdir:htmldocs src/viewSEG.nim"

# ------------------------------------------------------------ dependencies --
# atlas.lock is maintained by hand and by tools/deps.nim, never by Atlas: in
# the devcontainer deps/parseSEG and deps/processSEG are bind mounts of the
# real repositories, and Atlas would check out locked commits in them.
const depsTool = "r --hints:off --warnings:off tools/deps.nim "

task depsStatus, "Show each locked dependency: locked vs checked-out commit, mounts":
  selfExec depsTool & "status"

task depsSync, "Check out every unmounted dependency at its locked commit":
  selfExec depsTool & "sync"

task depsCheck, "Verify atlas.lock, nim.cfg and deps/ agree":
  selfExec depsTool & "check"

# --------------------------------------------------------------- libraries --
# deps/parseSEG and deps/processSEG are the real repositories (bind mounts).
# Use `git -C deps/<lib>` for them. Their suites run from their own directory
# with their own deps/ and config (--skipParentCfg keeps this file out).

task parseSEGTest, "Run parseSEG's own test suite in deps/parseSEG":
  ## Needs parseSEG's own deps/ (its Atlas checkouts); fill a missing one with
  ## `nim r tools/deps.nim sync --root:deps/parseSEG`.
  withDir "deps/parseSEG":
    exec quoteShell(getCurrentCompilerExe()) & " --skipParentCfg test"

task processSEGTest, "Run processSEG's own test suite in deps/processSEG":
  ## Builds against the real parseSEG: the devcontainer also mounts it over
  ## deps/processSEG/deps/parseSEG. Fill a missing deps/ with
  ## `nim r tools/deps.nim sync --root:deps/processSEG`.
  withDir "deps/processSEG":
    exec quoteShell(getCurrentCompilerExe()) & " --skipParentCfg test"
