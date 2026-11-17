## Checks what `nim package` wrote to dist/: each release folder and archive has
## the layout of README.md ("Packaging"), and the packaged Linux binary, run
## from its unpacked archive, uses that folder's own config/, logs/ and
## vendormaps/ (portable mode), or the per-user directories once config/ is gone.
##
## Slow and dependent on a fresh `nim package`, so it is not part of `nim test`:
## `nim packageTest` packages, then runs this. `-d:packageTargets=linux` (or
## windows) checks one OS, like `nim package`.

import std/[algorithm, assertions, os, osproc, sequtils, streams, strtabs, strutils, tempfiles]

const packageTargets {.strdefine.} = "linux,windows"

let
  root = currentSourcePath().parentDir.parentDir.parentDir
  dist = root / "dist"

proc nimbleVersion(): string =
  result = ""
  for line in lines(root / "viewSEG.nimble"):
    if result.len == 0 and line.startsWith("version"):
      result = line.split('=', 1)[1].strip.strip(chars = {'"'})

let version = nimbleVersion()

proc releaseName(os: string): string = "viewSEG-" & version & "-" & os & "-x64"

proc exeName(os: string): string =
  if os == "windows": "viewSEG.exe" else: "viewSEG"

proc expectedTop(os: string): seq[string] =
  sorted(@[exeName(os), "vendormaps", "config", "assets", "logs", "licences", "docs"])

proc expectedFiles(os: string): seq[string] =
  ## Files every release must hold (relative to its folder).
  result = @[exeName(os), "vendormaps/README.md", "vendormaps/WRITING-A-MAP.md", "config/README.md",
    "config/vendormaps/README.md", "logs/README.md", "docs/README.md", "docs/QUICKSTART.md",
    "docs/BUILD.txt", "licences/README.md", "licences/viewSEG-LICENSE.txt",
    "licences/SDL3-LICENSE.txt", "licences/DearImGui-LICENSE.txt",
    "licences/ImPlot-LICENSE.txt", "licences/cimgui-LICENSE.txt",
    "licences/imguin-LICENSE.txt", "licences/sdl3_nim-LICENSE.txt",
    "licences/parseSEG-LICENSE.txt"]
  # every theme, and the licences of the palettes
  for f in walkFiles(root / "assets" / "themes" / "*"):
    result.add "assets/themes/" & f.extractFilename
  for f in walkFiles(root / "licences" / "themes" / "*"):
    result.add "licences/themes/" & f.extractFilename

proc run(cmd: string; workingDir = ""): string =
  let (output, code) = execCmdEx(cmd, workingDir = workingDir)
  doAssert code == 0, "`" & cmd & "` failed:\n" & output
  output

proc archiveEntries(archive: string): seq[string] =
  ## The paths inside `archive`, from tar (.tar.gz) or CMake (.zip).
  let cmd =
    if archive.endsWith(".zip"): "cmake -E tar tf " & quoteShell(archive)
    else: "tar -tzf " & quoteShell(archive)
  for line in run(cmd).splitLines:
    if line.strip.len > 0:
      result.add line.strip.replace('\\', '/')

proc topOf(entries: seq[string]; prefix: string): seq[string] =
  ## The distinct first components below `prefix/` of `entries`.
  for e in entries:
    doAssert e.startsWith(prefix & "/") or e == prefix, "stray entry " & e
    if e.len > prefix.len + 1:
      let first = e[prefix.len + 1 .. ^1].split('/')[0]
      if first.len > 0 and first notin result:
        result.add first
  result.sort()

let targets = packageTargets.split(',')

for os in targets:
  block releaseFolder:
    let dir = dist / releaseName(os)
    doAssert dirExists(dir), dir & " missing: run `nim package` first"
    var top: seq[string]
    for kind, path in walkDir(dir, relative = true):
      top.add path
    doAssert sorted(top) == expectedTop(os), $sorted(top)
    for f in expectedFiles(os):
      doAssert fileExists(dir / f), "missing " & f
    for d in ["vendormaps", "config", "assets", "logs", "licences", "docs"]:
      doAssert dirExists(dir / d), "missing folder " & d

  block archiveEntriesMatch:
    let archive = dist / releaseName(os) & (if os == "windows": ".zip" else: ".tar.gz")
    doAssert fileExists(archive), archive & " missing"
    let entries = archiveEntries(archive)
    doAssert topOf(entries, releaseName(os)) == expectedTop(os),
      $topOf(entries, releaseName(os))
    for f in expectedFiles(os):
      doAssert releaseName(os) & "/" & f in entries, "archive lacks " & f
    echo "ok ", archive.extractFilename, ": ", entries.len, " entries"

if "linux" in targets:
  let
    tmp = createTempDir("viewSEG-package-", "")
    pkg = tmp / releaseName("linux")
    home = tmp / "home"
    archive = dist / releaseName("linux") & ".tar.gz"
  createDir(home)
  discard run("tar -xzf " & quoteShell(archive) & " -C " & quoteShell(tmp))

  proc env(): StringTableRef =
    ## This process's environment with home and XDG directories in `home`, and
    ## no display (nothing may open a window) or extra vendor-map path.
    result = newStringTable(modeCaseSensitive)
    for k, v in envPairs():
      result[k] = v
    for k in ["DISPLAY", "WAYLAND_DISPLAY", "PARSESEG_VENDOR_PATH"]:
      if result.hasKey(k):
        result.del k
    result["HOME"] = home
    result["XDG_CONFIG_HOME"] = home / "xdg-config"
    result["XDG_STATE_HOME"] = home / "xdg-state"
    result["XDG_CACHE_HOME"] = home / "xdg-cache"

  proc viewSEG(args: varargs[string]): string =
    let p = startProcess(pkg / "viewSEG", workingDir = tmp, args = args, env = env(),
      options = {poStdErrToStdOut})
    result = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    doAssert code == 0, "viewSEG " & args.join(" ") & " exited with " & $code & ":\n" & result

  proc paths(): seq[(string, string)] =
    ## `viewSEG --paths` as (name, path) pairs, in order.
    for line in viewSEG("--paths").splitLines:
      if line.len > 0:
        let parts = line.split(": ", 1)
        doAssert parts.len == 2, "bad --paths line: " & line
        result.add (parts[0], parts[1])

  proc values(ps: seq[(string, string)]; name: string): seq[string] =
    ps.filterIt(it[0] == name).mapIt(it[1])

  block staticSdl:
    let libs = run("ldd " & quoteShell(pkg / "viewSEG"))
    doAssert "libSDL3" notin libs, libs

  block versionOption:
    let output = viewSEG("--version")
    doAssert output.startsWith("viewSEG " & version & " "), output

  block portable:
    let ps = paths()
    echo "portable:\n", ps.mapIt(it[0] & ": " & it[1]).join("\n")
    doAssert ps.values("app") == @[pkg]
    doAssert ps.values("portable") == @["yes"]
    doAssert ps.values("config") == @[pkg / "config"]
    doAssert ps.values("logs") == @[pkg / "logs"]
    doAssert ps.values("cache") == @[pkg / "cache"]
    doAssert ps.values("assets") == @[pkg / "assets"]
    doAssert ps.values("vendormaps") == @[pkg / "config" / "vendormaps", pkg / "vendormaps"]

  block perUser:
    removeDir(pkg / "config")
    let ps = paths()
    echo "without config/:\n", ps.mapIt(it[0] & ": " & it[1]).join("\n")
    doAssert ps.values("portable") == @["no"]
    doAssert ps.values("config") == @[home / "xdg-config" / "viewSEG"]
    doAssert ps.values("logs") == @[home / "xdg-state" / "viewSEG" / "logs"]
    doAssert ps.values("cache") == @[home / "xdg-cache" / "viewSEG"]
    doAssert ps.values("vendormaps") == @[pkg / "vendormaps"]
    # --paths only reports: nothing was created in the home directory.
    doAssert toSeq(walkDir(home)).len == 0, $toSeq(walkDir(home))

  removeDir(tmp)

echo "tpackage: ok (", targets.join(", "), ")"
