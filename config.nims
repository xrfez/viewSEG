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

# ------------------------------------------------------------- GUI stack --
# imguin compiles only the Dear ImGui add-ons that are defined.
switch("define", "ImPlot")

# Linux: SDL3 is linked statically, so the binary needs no libSDL3 at run time.
# - sdl3_nim loads "libSDL3.so" with {.dynlib.}; --dynlibOverride turns those
#   imports into plain symbols.
# - imguin's impl_sdl3 links `-lSDL3`, ahead of any flag given here. ld searches
#   every -L directory before its defaults, and a directory holding only
#   libSDL3.a (bin/sdl3-static, a symlink) makes that -lSDL3 the static archive.
# - pkg-config's static libs, minus SDL3's own, are what libSDL3.a needs (SDL
#   dlopens X11, Wayland and GL itself). Its rpath is dropped: nothing to find.
# - Without a static SDL3 (pkg-config fails), or with -d:sdlShared, the binary
#   needs libSDL3.so.0 at run time instead.
# - The headers: imguin's impl_sdl3 includes <SDL3/SDL.h> and sdl3_nim only
#   names its own Windows copy, so SDL's include folder comes from pkg-config
#   (an SDL installed outside /usr/local, as CI's, is found too).
when defined(linux):
  let (sdlCflags, sdlNoCflags) = gorgeEx("pkg-config --cflags sdl3")
  if sdlNoCflags == 0 and sdlCflags.strip.len > 0:
    switch("passC", sdlCflags.strip)
when defined(linux) and not defined(sdlShared):
  let
    (sdlLibDir, sdlMissing) = gorgeEx("pkg-config --variable=libdir sdl3")
    sdlArchive = sdlLibDir.strip / "libSDL3.a"
  if sdlMissing == 0 and fileExists(sdlArchive):
    let staticDir = thisDir() / "bin" / "sdl3-static"
    mkDir(staticDir)
    discard gorgeEx("ln -sfn " & quoteShell(sdlArchive) & " " &
      quoteShell(staticDir / "libSDL3.a")) # refreshed: SDL may have moved
    var sdlDeps: seq[string]
    for flag in gorgeEx("pkg-config --static --libs sdl3").output.splitWhitespace:
      if flag != "-lSDL3" and not flag.startsWith("-L") and not flag.startsWith("-Wl,"):
        sdlDeps.add flag
    switch("dynlibOverride", "SDL3")
    switch("passL", "-L" & quoteShell(staticDir) & " -lSDL3 " & sdlDeps.join(" "))
  else:
    echo "config.nims: no static SDL3 (pkg-config sdl3, libSDL3.a); linking libSDL3.so"

# Windows with zig (`nim winRelease`, also from this Linux container): SDL3 is
# linked statically too, from tools/sdl3-windows.sh's cross-build.
const sdl3WindowsVersion = "3.4.18" # = sdl3_nim's and the Linux SDL's version

proc sdl3WindowsPrefix(): string =
  ## Where tools/sdl3-windows.sh installs SDL3 for x86_64-windows-gnu.
  result = getEnv("SDL3_WINDOWS_PREFIX")
  if result.len == 0:
    result = getEnv("HOME") & "/.cache/viewSEG/sdl3-" & sdl3WindowsVersion &
      "-x86_64-windows-gnu"

# Each fix below is for a library that takes its Windows branch while the host
# is Linux; none needs a change under deps/.
# - imguin's cimgui.nim runs `nimble path glfw` on Windows (for a GLFW backend
#   viewSEG does not use) and passes the output as an -I flag; without that
#   package it is an error message, which zig reads as file names. The stub
#   `nimble` in tools/winbuild prints nothing, so the flag becomes a harmless
#   `-Iglfw/include`. config.nims runs inside the compiler, so putEnv reaches
#   imguin's staticExec.
# - sdl3_nim joins its header path with the target's `\`, so its -I is
#   `\workspaces\...` and finds nothing; the headers come from SDL's own install
#   instead (the same 3.4.18 headers).
# - impl_sdl3 links -lSDL3 on Linux only; here it is the static archive.
#   --dynlibOverride turns sdl3_nim's {.dynlib: "SDL3.dll".} imports into plain
#   symbols, so no SDL3.dll is needed; the Win32 libraries SDL needs come from
#   its sdl3.pc. -mwindows and -lm are left out: zig ignores the first (winres
#   sets the subsystem) and Windows has no libm.
# - Dear ImGui is C++ and zig cc links no C++ runtime by itself: -lc++ links
#   zig's libc++/libc++abi statically (no libstdc++ or libgcc DLLs).
# Paths here are joined with "/", not `/`: with --os:windows, `/` uses the
# target's `\` (sdl3_nim's bug above), which a Linux host cannot use.
when defined(windows) and defined(zigcc):
  putEnv("PATH", thisDir() & "/tools/winbuild" & (if buildOS == "windows": ";" else: ":") &
    getEnv("PATH"))
  let sdlPrefix = sdl3WindowsPrefix()
  if not fileExists(sdlPrefix & "/lib/libSDL3.a"):
    quit "config.nims: no static SDL3 for Windows in " & sdlPrefix &
      "; run tools/sdl3-windows.sh (nim winRelease does)"
  var sdlLibs: seq[string]
  for line in readFile(sdlPrefix & "/lib/pkgconfig/sdl3.pc").splitLines:
    if line.startsWith("Libs:"):
      for flag in line.splitWhitespace:
        if flag.startsWith("-l") and flag notin ["-lSDL3", "-lm"]:
          sdlLibs.add flag
  switch("dynlibOverride", "SDL3")
  switch("passC", "-I" & quoteShell(sdlPrefix & "/include"))
  switch("passL", "-L" & quoteShell(sdlPrefix & "/lib") & " -lSDL3 " & sdlLibs.join(" ") &
    " -lc++")

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

let winReleaseBuild = "c -d:zigcc --os:windows --cpu:amd64 --cc:clang --clang.exe:\"" &
  zigccExe & "\" --clang.linkerexe:\"" & zigccExe & "\" --passC:\"-target x86_64-windows-gnu\"" &
  " --passL:\"-target x86_64-windows-gnu\" -d:release -d:danger --opt:speed" &
  " -o:bin/viewSEG.exe src/viewSEG.nim"

task winRelease, "Cross-build bin/viewSEG.exe for Windows x86-64 with zig cc (no MinGW needed)":
  ## zig ships the MinGW-w64 headers and import libraries, a linker and a resource
  ## compiler (`zig rc`, used by src/viewSEG/platform/winres.nim), so this works
  ## from the Linux container. AVX2 build (x86-64-v3) like nimRelease; add
  ## -d:baselineCpu for older CPUs. SDL3 is linked statically: the first run
  ## cross-builds it (tools/sdl3-windows.sh, about two minutes, needs network).
  if buildOS != "windows":
    exec "bash tools/sdl3-windows.sh " & quoteShell(sdl3WindowsPrefix())
  selfExec winReleaseBuild

# ---------------------------------------------------------------- packaging --
# `nim package` builds the release binaries and assembles dist/ (README.md,
# "Packaging"); tools/package.nim does the assembly. It never reaches the
# network: the Windows SDL3 build must already exist (`nim winRelease` makes it).
# `nim -d:packageTargets=linux package` (or windows) packages one OS only.
const packageTargets {.strdefine.} = "linux,windows"

task package, "Build the release binaries and write dist/viewSEG-<version>-<os>-x64 and archives":
  ## Linux: the release settings of winRelease (-d:danger, x86-64-v3) with
  ## static SDL3, stripped, into bin/release/viewSEG. Windows: winRelease's
  ## bin/viewSEG.exe. Then tools/package.nim writes the folders and archives.
  if buildOS != "linux" or buildCPU != "amd64":
    quit "nim package: needs an x86-64 Linux host (the devcontainer or CI)"
  let root = thisDir()
  var toolArgs = " --root:" & quoteShell(root) & " --nim:" & quoteShell(getCurrentCompilerExe())
  let targets = packageTargets.split(',')
  for t in targets:
    if t notin ["linux", "windows"]:
      quit "nim package: unknown target " & t & " in -d:packageTargets (linux, windows)"
  if "linux" in targets:
    let (libDir, code) = gorgeEx("pkg-config --variable=libdir sdl3")
    if code != 0 or not fileExists(libDir.strip & "/libSDL3.a"):
      quit "nim package: no static SDL3 (pkg-config sdl3, libSDL3.a); a release must not " &
        "need libSDL3.so"
    let output = root & "/bin/release/viewSEG"
    selfExec "c --hints:off -d:release -d:danger --opt:speed --passL:-s --nimcache:" &
      quoteShell(getEnv("HOME") & "/.cache/nim/viewSEG_package_linux") & " -o:" &
      quoteShell(output) & " src/viewSEG.nim"
    toolArgs.add " --linux:" & quoteShell(output)
  if "windows" in targets:
    let sdl = sdl3WindowsPrefix()
    if not fileExists(sdl & "/lib/libSDL3.a"):
      quit "nim package: no SDL3 build for Windows in " & sdl & ". Run `nim winRelease` " &
        "once (it builds SDL3, which needs the network), then `nim package` again."
    selfExec winReleaseBuild
    toolArgs.add " --windows:" & quoteShell(root & "/bin/viewSEG.exe")
  selfExec "r --hints:off tools/package.nim" & toolArgs

task packageTest, "nim package, then check dist/ and run the packaged Linux binary":
  ## Slow (two release builds when the caches are cold): not part of `nim test`.
  ## Checks the targets of -d:packageTargets, like `nim package`.
  let define = " -d:packageTargets=" & packageTargets
  selfExec define & " package"
  selfExec "c -r --hints:off" & define & " tests/package/tpackage.nim"

# Every test task builds the runner tests/tester.nim once, in debug; the runner
# compiles and runs each tests/t*.nim with the flags given after it, several
# files at a time, each run on an Xvfb display of its own (its module doc).
const tester = "c -r --hints:off tests/tester.nim"

task test, "Run the test suite, several files at a time":
  ## Runs every tests/t*.nim in a debug build, as many files at a time as
  ## there are CPU cores; no xvfb-run needed.
  selfExec tester

task testSerial, "Run the test suite one file at a time":
  ## As `nim test`, a file after another: to compare, or to debug.
  selfExec tester & " --jobs:1"

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

# ------------------------------------------------------------------ samples --
task samples, "Write the synthetic sample set into samples/":
  ## tools/sampledata.nim writes samples/ once. The files are committed;
  ## nothing regenerates them and compares bytes.
  selfExec "r --hints:off --warnings:off tools/sampledata.nim"

# ---------------------------------------------------------------- coverage --
task shortcuts, "Rewrite docs/user/keyboard-shortcuts.md from the shortcut table":
  ## tools/shortcutspage.nim: the page is the table in core/shortcuts, menu
  ## rows included from the menu's action table. `nim r tools/shortcutspage.nim
  ## check` only checks; tests/tshortcuts.nim does that.
  selfExec "r --hints:off --warnings:off tools/shortcutspage.nim write"

task coverage, "Rewrite docs/coverage.md's summary, then check the page against the libraries":
  ## tools/coverage.nim: every name parseSEG and processSEG export (at the
  ## locked commits; the next releases when linked at deps/next/<library>) is
  ## named on the page, a `built` or `internal` row's names are named in src/,
  ## and the summary is the tables'. `nim r tools/coverage.nim check` only
  ## checks; tests/tcoverage.nim does that.
  selfExec "r --hints:off --warnings:off tools/coverage.nim write"

# -------------------------------------------------------------- benchmarks --
task surveyBench, "Time survey files at real scale: read, load, import, cancel, memory":
  ## tools/surveybench.nim in a release build: surveys of tests/utils/bigsurvey
  ## at a hundredth and a tenth of a real 3D survey (R 200 000, S 2 000 000,
  ## X about 30 million records at 1) written to a temporary folder, each
  ## measurement in a process of its own. For other sizes (0.3, 1: 2.5 GB of
  ## files and about 4 GB of memory) run the tool itself:
  ## `<bin> all <dir> 0.1 0.3 1`; the map's frames: tools/mapbench.nim.
  selfExec "c -d:release --hints:off --warnings:off -o:bin/surveybench tools/surveybench.nim"
  exec "bin" / "surveybench" & " all " & quoteShell(getTempDir() / "viewseg-surveybench") &
    " 0.01 0.1"

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
