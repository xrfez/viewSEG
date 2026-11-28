## Assembles viewSEG's release folders and archives from binaries already built.
## `nim package` (config.nims) builds the binaries, then runs this:
##
##   nim r tools/package.nim --root:<repo> --nim:<nim compiler> [--out:<dir>]
##     [--linux:<viewSEG binary>] [--windows:<viewSEG.exe>]
##
## For each binary given it writes `<out>/viewSEG-<version>-<os>-x64/` (the layout
## of docs/building.md, "Packaging") and its archive next to it: `.tar.gz` for Linux,
## `.zip` for Windows. `<out>` defaults to `<repo>/dist`; the version comes from
## viewSEG.nimble. An earlier folder or archive of the same name is replaced, so
## running it twice gives the same result.
##
## Every input must exist or the run stops with an error; only the optional
## licences (`required = false` below) may be missing, and the generated
## licences/README.md lists them. Nothing here touches the network or writes
## outside `<out>`; the git queries are read-only (`--no-optional-locks`).

import std/[json, os, osproc, parseopt, strutils]

type
  Target = object
    os: string     ## "linux" or "windows"
    binary: string ## the built executable
    exeName: string

  Licence = object
    component, licence: string
    source: string ## absolute path of the licence file
    dest: string   ## file name under licences/
    windowsOnly, required: bool

  Packager = object
    root, outDir, version, nimExe: string

const
  Arch = "x64"
  TopLevel* = ["vendormaps", "config", "assets", "logs", "licences", "docs"]
    ## the folders of every release, beside the executable

proc fail(msg: string) {.noreturn.} =
  quit "package: error: " & msg, QuitFailure

proc warn(msg: string) =
  stderr.writeLine "package: warning: " & msg

proc requireFile(path, what: string) =
  if not fileExists(path):
    fail what & " not found: " & path

proc requireDir(path, what: string) =
  if not dirExists(path):
    fail what & " not found: " & path

proc nimbleVersion(root: string): string =
  result = ""
  let nimble = root / "viewSEG.nimble"
  requireFile(nimble, "viewSEG.nimble")
  for line in lines(nimble):
    if result.len == 0 and line.startsWith("version"):
      result = line.split('=', 1)[1].strip.strip(chars = {'"'})
  if result.len == 0:
    fail "no version line in " & nimble

proc git(dir: string; args: varargs[string]): string =
  ## Output of a read-only git query in `dir`, or "" when git or the repository
  ## is missing.
  result = ""
  if findExe("git").len > 0 and dirExists(dir):
    var cmd = "git --no-optional-locks -C " & quoteShell(dir)
    for a in args:
      cmd.add " " & quoteShell(a)
    let (output, code) = execCmdEx(cmd, options = {poUsePath})
    if code == 0:
      result = output.strip

proc revision(dir: string; paths: varargs[string]): string =
  ## `<commit>` of the checkout in `dir`, `+dirty` when `paths` (or the whole
  ## tree) have uncommitted changes; "unknown" without git.
  let commit = git(dir, "rev-parse", "HEAD")
  if commit.len == 0:
    result = "unknown"
  else:
    result = commit
    if git(dir, @["status", "--porcelain", "--"] & @paths).len > 0:
      result.add " +dirty"

proc lockedCommit(root, name: string): string =
  ## The commit atlas.lock pins for `name`, or "".
  result = ""
  let lock = root / "atlas.lock"
  if fileExists(lock):
    let items = parseFile(lock){"items"}
    if items != nil and items.hasKey(name):
      result = items[name]{"commit"}.getStr

proc zigLibDir(): string =
  ## zig's lib directory (libc++, mingw-w64 sources), or "" without zig.
  result = ""
  if findExe("zig").len > 0:
    let (output, code) = execCmdEx("zig env", options = {poUsePath})
    if code == 0:
      for line in output.splitLines:
        let s = line.strip
        if s.startsWith(".lib_dir"):
          result = s.split('"')[1]

proc licences(p: Packager): seq[Licence] =
  ## What is linked into the binaries or bundled with them, and where each
  ## licence comes from. Add a row when a library is linked or bundled.
  let
    imgui = p.root / "deps/imguin/src/imguin/private"
    nimHome = p.nimExe.parentDir.parentDir
    zig = zigLibDir()
  func row(component, licence, source, dest: string; required = true;
      windowsOnly = false): Licence =
    Licence(component: component, licence: licence, source: source, dest: dest,
      required: required, windowsOnly: windowsOnly)
  result = @[
    row("viewSEG", "MIT", p.root / "LICENSE", "viewSEG-LICENSE.txt"),
    row("parseSEG", "MIT", p.root / "deps/parseSEG/LICENSE", "parseSEG-LICENSE.txt"),
    row("processSEG", "MIT", p.root / "deps/processSEG/LICENSE", "processSEG-LICENSE.txt",
      required = false),
    row("SDL 3", "zlib", p.root / "deps/sdl3/src/sdl3_nim/private/SDL3/LICENSE.txt",
      "SDL3-LICENSE.txt"),
    row("sdl3_nim (SDL 3 bindings)", "MIT", p.root / "deps/sdl3/LICENSE",
      "sdl3_nim-LICENSE.txt"),
    row("Dear ImGui", "MIT", imgui / "cimgui/imgui/LICENSE.txt", "DearImGui-LICENSE.txt"),
    row("cimgui", "MIT", imgui / "cimgui/LICENSE", "cimgui-LICENSE.txt"),
    row("ImPlot", "MIT", imgui / "cimplot/implot/LICENSE", "ImPlot-LICENSE.txt"),
    row("cimplot", "MIT", imgui / "cimplot/LICENSE", "cimplot-LICENSE.txt"),
    row("imguin (Dear ImGui bindings)", "MIT", p.root / "deps/imguin/LICENSE",
      "imguin-LICENSE.txt"),
    row("glad OpenGL loader (generated, in imguin)", "public domain / Apache-2.0", "",
      "glad-LICENSE.txt", required = false),
    row("Arraymancer (laser CPU detection)", "Apache-2.0",
      p.root / "deps/arraymancer/LICENSE", "Arraymancer-LICENSE.txt"),
    row("Nim runtime and standard library", "MIT", nimHome / "copying.txt",
      "Nim-LICENSE.txt", required = false),
    row("LLVM libc++ (static, from zig)", "Apache-2.0 WITH LLVM-exception",
      (if zig.len > 0: zig / "libcxx/LICENSE.TXT" else: ""), "libcxx-LICENSE.txt",
      required = false, windowsOnly = true),
    row("LLVM libc++abi (static, from zig)", "Apache-2.0 WITH LLVM-exception",
      (if zig.len > 0: zig / "libcxxabi/LICENSE.TXT" else: ""), "libcxxabi-LICENSE.txt",
      required = false, windowsOnly = true),
    row("LLVM libunwind (static, from zig)", "Apache-2.0 WITH LLVM-exception",
      (if zig.len > 0: zig / "libunwind/LICENSE.TXT" else: ""), "libunwind-LICENSE.txt",
      required = false, windowsOnly = true),
    row("mingw-w64 runtime (static, from zig)", "ZPL-2.1 and others",
      (if zig.len > 0: zig / "libc/mingw/COPYING" else: ""), "mingw-w64-COPYING.txt",
      required = false, windowsOnly = true)]

proc checkBinary(t: Target) =
  ## The binary exists and is an executable for `t.os` (ELF or PE).
  requireFile(t.binary, t.os & " binary")
  var f = open(t.binary)
  var magic = newString(4)
  let n = f.readChars(toOpenArray(magic, 0, 3))
  f.close()
  let want = if t.os == "windows": "MZ" else: "\x7FELF"
  if n < want.len or not magic.startsWith(want):
    fail t.binary & " is not a " & t.os & " executable"

proc copyMaps(src, dest: string; seen: var seq[string]) =
  ## Copies the `*.nif` maps of `src` into `dest`, flat (parseSEG does not
  ## search subfolders). The shipped maps live in parseSEG and here: a second
  ## copy of the same bytes is skipped, two different maps of one name are an error.
  for f in walkFiles(src / "*.nif"):
    let name = f.extractFilename
    if name in seen:
      if readFile(f) != readFile(dest / name):
        fail "two different vendor maps named " & name & " (" & src & ")"
      continue
    seen.add name
    copyFile(f, dest / name)

proc writeVendormaps(p: Packager; dir: string) =
  let
    parseSEGMaps = p.root / "deps/parseSEG/vendormaps"
    ownMaps = p.root / "vendormaps"
  requireDir(parseSEGMaps, "parseSEG's vendormaps/")
  requireFile(ownMaps / "README.md", "vendormaps/README.md")
  requireFile(ownMaps / "WRITING-A-MAP.md", "vendormaps/WRITING-A-MAP.md")
  let dest = dir / "vendormaps"
  createDir(dest)
  var seen: seq[string]
  copyMaps(parseSEGMaps, dest, seen)
  copyMaps(ownMaps, dest, seen)
  copyFile(ownMaps / "README.md", dest / "README.md")
  copyFile(ownMaps / "WRITING-A-MAP.md", dest / "WRITING-A-MAP.md")

proc writeLicences(p: Packager; t: Target; dir: string) =
  let dest = dir / "licences"
  createDir(dest)
  var table, missing: seq[string]
  for l in p.licences:
    if l.windowsOnly and t.os != "windows":
      discard
    elif l.source.len > 0 and fileExists(l.source):
      copyFile(l.source, dest / l.dest)
      table.add "| " & l.component & " | " & l.licence & " | `" & l.dest & "` |"
    elif l.required:
      fail "licence of " & l.component & " not found: " & l.source
    else:
      missing.add "- " & l.component & " (" & l.licence & "): no licence file found" &
        (if l.source.len > 0: " at `" & l.source.relativePath(p.root) & "`" else: "") & "."
  var extra: seq[string]
  let repoLicences = p.root / "licences"
  if dirExists(repoLicences):
    for f in walkDirRec(repoLicences, relative = true):
      if fileExists(dest / f):
        fail "licences/" & f & " clashes with a collected licence"
      createDir((dest / f).parentDir)
      copyFile(repoLicences / f, dest / f)
      extra.add "- `" & f.replace('\\', '/') & "`"
  var text = "# Licences\n\n" &
    "viewSEG is released under the MIT licence (`viewSEG-LICENSE.txt`). This " &
    (if t.os == "windows": "Windows" else: "Linux") &
    " build includes the software below, each under its own licence.\n\n" &
    "| Component | Licence | File |\n|---|---|---|\n" & table.join("\n") & "\n"
  if extra.len > 0:
    text.add "\nBundled assets (fonts, icons) and their licences:\n\n" & extra.join("\n") & "\n"
  if missing.len > 0:
    text.add "\nNot found when this release was built (licence as the project declares " &
      "it):\n\n" & missing.join("\n") & "\n"
  if t.os == "linux":
    text.add "\nThe Linux build also uses the system's C and C++ runtime libraries (glibc, " &
      "libstdc++, libgcc) and its OpenGL driver; they are not part of this release.\n"
  writeFile(dest / "README.md", text)

proc writeDocs(p: Packager; dir: string) =
  let dest = dir / "docs"
  createDir(dest)
  requireFile(p.root / "README.md", "README.md")
  copyFile(p.root / "README.md", dest / "README.md")
  let userDocs = p.root / "docs/user"
  requireFile(userDocs / "QUICKSTART.md", "docs/user/QUICKSTART.md")
  for f in walkDirRec(userDocs, relative = true):
    createDir((dest / f).parentDir)
    copyFile(userDocs / f, dest / f)
  let parseSEGDir = p.root / "deps/parseSEG"
  let parseSEGRev = revision(parseSEGDir, "vendormaps")
  let locked = lockedCommit(p.root, "parseSEG")
  if locked.len > 0 and not parseSEGRev.startsWith(locked):
    warn "deps/parseSEG is at " & parseSEGRev & ", atlas.lock pins " & locked &
      "; its vendormaps/ are copied as checked out"
  writeFile(dest / "BUILD.txt",
    "viewSEG " & p.version & "\n" &
    "viewSEG commit: " & revision(p.root) & "\n" &
    "parseSEG commit (vendormaps/): " & parseSEGRev & "\n" &
    "processSEG commit: " & revision(p.root / "deps/processSEG") & "\n" &
    "Nim: " & NimVersion & " (packager)\n")

proc writeFolder(dir, readme: string) =
  createDir(dir)
  writeFile(dir / "README.md", readme)

proc archive(p: Packager; t: Target; name: string): string =
  ## Packs `<out>/<name>/` into `<out>/<name>.tar.gz` (Linux) or `.zip`
  ## (Windows, with CMake's built-in libarchive) and returns the archive's path.
  var cmd: string
  if t.os == "windows":
    if findExe("cmake").len == 0:
      fail "cmake is needed to write the .zip (it also builds SDL for Windows)"
    result = p.outDir / name & ".zip"
    cmd = "cmake -E tar cf " & quoteShell(result) & " --format=zip " & quoteShell(name)
  else:
    result = p.outDir / name & ".tar.gz"
    cmd = "tar --sort=name --owner=0 --group=0 --numeric-owner -czf " & quoteShell(result) &
      " " & quoteShell(name)
  removeFile(result)
  let (output, code) = execCmdEx(cmd, options = {poUsePath, poStdErrToStdOut},
    workingDir = p.outDir)
  if code != 0 or not fileExists(result):
    fail "`" & cmd & "` failed:\n" & output

proc package(p: Packager; t: Target): string =
  ## Writes the release folder of `t` and its archive; returns the archive.
  checkBinary(t)
  let name = "viewSEG-" & p.version & "-" & t.os & "-" & Arch
  let dir = p.outDir / name
  removeDir(dir)
  createDir(dir)
  copyFile(t.binary, dir / t.exeName)
  if t.os != "windows":
    setFilePermissions(dir / t.exeName, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  p.writeVendormaps(dir)
  requireFile(p.root / "config/README.md", "config/README.md")
  copyDir(p.root / "config", dir / "config")
  if dirExists(p.root / "assets"):
    copyDir(p.root / "assets", dir / "assets")
  else:
    warn "no assets/ in the repository; the release's assets/ is empty"
    writeFolder(dir / "assets", "# assets\n\nThemes, fonts and colour maps.\n")
  writeFolder(dir / "logs", "# logs\n\nIn portable mode (see `config/README.md`) viewSEG " &
    "writes one log file per session here. Old files are removed automatically.\n")
  p.writeLicences(t, dir)
  p.writeDocs(dir)
  result = p.archive(t, name)

proc main() =
  var p = Packager(root: getCurrentDir())
  var targets: seq[Target]
  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "root": p.root = val
      of "out": p.outDir = val
      of "nim": p.nimExe = val
      of "linux": targets.add Target(os: "linux", binary: val, exeName: "viewSEG")
      of "windows": targets.add Target(os: "windows", binary: val, exeName: "viewSEG.exe")
      else: fail "unknown option --" & key
    else:
      fail "unexpected argument " & key
  if targets.len == 0:
    fail "nothing to package: pass --linux:<binary> and/or --windows:<exe>"
  p.root = p.root.absolutePath
  if p.outDir.len == 0:
    p.outDir = p.root / "dist"
  p.outDir = p.outDir.absolutePath
  if p.nimExe.len == 0:
    p.nimExe = findExe("nim")
  p.version = nimbleVersion(p.root)
  createDir(p.outDir)
  for t in targets:
    var t = t
    t.binary = t.binary.absolutePath
    let file = p.package(t)
    echo "package: ", file, " (", getFileSize(file) div 1024, " KiB)"

when isMainModule:
  main()
