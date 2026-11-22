## The layer rules of docs/architecture.md: only `ui/` may know the GUI toolkit,
## and the lower layers never import the ones above them. Checked from the import
## statements of every module under src/viewSEG/.
##
## parseSSDAT and parseSSVIB (deps/, libraries of their own) may be imported only from
## `core/`: parseSSDAT only by `core/sigdat.nim`, parseSSVIB only by `core/sigvib.nim`.
## Seen to fail: with `import parseSSDAT` planted in `src/viewSEG/view/x.nim`,
## `ssdatOnlyFromCore` names it; likewise `ssvibOnlyFromCore` for `import parseSSVIB`.
##
## And no file under src/, tests/ or tools/ imports `std/re`, `std/nre` or
## `std/pcre`: they load libpcre (PCRE1) at run time, which newer Linux
## releases no longer ship. Seen to fail: with tests/tfilesystem.nim importing
## `re` again, `noRegexEngine` names it. With `proc main*` taken out of this
## file, `testsExportMain` named it.

import std/[os, sequtils, strutils]

const
  srcDir = currentSourcePath().parentDir.parentDir / "src" / "viewSEG"
  toolkits = ["imguin", "imgui", "implot", "sdl2", "sdl3", "sdl2_nim", "sdl3_nim", "glad",
    "opengl", "glfw", "nimgl", "seaqt", "owlkettle", "windy", "boxy", "silky", "merenda",
    "stb_image"]
  # layer -> sibling layers (directories under src/viewSEG) it must not import
  forbidden = [
    ("core", @["ui", "gpu", "view", "platform", "remote"]),
    ("view", @["ui", "gpu", "platform", "remote"]),
    ("gpu", @["ui", "platform", "remote"]),
    ("platform", @["ui", "core", "view", "gpu", "remote"]),
    # agent control: a front end on core alone; only the frontend starts it
    ("remote", @["ui", "gpu", "view", "platform"])]

proc imports(text: string): seq[string] =
  ## The module paths named by the import/from/include statements in `text`,
  ## including bracketed and multi-line lists.
  var inList = false
  for raw in text.splitLines:
    let line = raw.split('#')[0].strip
    if line.len == 0: continue
    var body: string
    if line in ["import", "include"]: # a list on the following lines
      inList = true
      continue
    if line.startsWith("import ") or line.startsWith("from ") or line.startsWith("include "):
      body = line.split(' ', 1)[1].split(" import ")[0]
    elif inList and raw.startsWith(" "):
      body = line
    else:
      inList = false
      continue
    for part in body.multiReplace(("[", ","), ("]", ","), ("\"", "")).split(','):
      let name = part.strip
      if name.len > 0: result.add name
    inList = line.endsWith(",") or ('[' in line and ']' notin line)

const
  rootDir = currentSourcePath().parentDir.parentDir
  pcreModules = ["re", "nre", "pcre"] ## the std modules that load libpcre

proc pcreImports(file, text: string): seq[string] =
  ## Each import in `text` of a module that loads libpcre.
  for imp in imports(text):
    if imp.replace('\\', '/').split('/')[^1] in pcreModules:
      result.add file & " imports " & imp

proc violations(layer, file, text: string, banned: openArray[string]): seq[string] =
  for imp in imports(text):
    let parts = imp.replace('\\', '/').split('/')
    if parts.anyIt(it in toolkits):
      result.add file & " (" & layer & ") imports toolkit " & imp
    for b in banned:
      # `../ui/x`, `viewSEG/ui/x`, or `ui/x` relative to src/viewSEG
      if b in parts and (parts[0] in ["..", "viewSEG"] or parts[0] == b):
        result.add file & " (" & layer & ") imports " & imp

proc libraryUsers(lib, only, file, text: string): seq[string] =
  ## Each import of the library `lib` in `text`, when `file` (relative to src/viewSEG) is
  ## not the one module `only`.
  if file.replace('\\', '/') != only:
    for imp in imports(text):
      let name = imp.replace('\\', '/')
      if name == lib or name.startsWith(lib & "/"):
        result.add file & " imports " & imp

proc ssdatUsers(file, text: string): seq[string] =
  ## parseSSDAT: only `core/sigdat.nim` reads a `.dat` signature file.
  libraryUsers("parseSSDAT", "core/sigdat.nim", file, text)

proc ssvibUsers(file, text: string): seq[string] =
  ## parseSSVIB: only `core/sigvib.nim` reads a `.vib` signature file.
  libraryUsers("parseSSVIB", "core/sigvib.nim", file, text)

proc main*() =

  block layerRules:
    var problems: seq[string]
    for (layer, banned) in forbidden:
      let dir = srcDir / layer
      if not dirExists(dir): continue
      for file in walkDirRec(dir):
        if file.endsWith(".nim"):
          problems.add violations(layer, file.relativePath(srcDir), readFile(file), banned)
    doAssert problems.len == 0, "layer rule broken:\n  " & problems.join("\n  ")

  block checkerCatchesViolations:
    let bad = "import std/os\nimport ../ui/imgui/app, imguin/cimgui\nfrom ../gpu/textures import x\n" &
      "import\n  std/strutils,\n  ../platform/theme\n"
    let found = violations("core", "bad.nim", bad, ["ui", "gpu", "view", "platform"])
    # ../ui/imgui/app twice (layer ui, toolkit imgui), imguin, ../gpu, ../platform
    doAssert found.len == 5, $found
    doAssert found.anyIt("platform/theme" in it), $found
    doAssert violations("view", "v.nim", "import sdl3_nim\nimport imguin/glad/gl\n", []).len == 2
    doAssert violations("core", "ok.nim", "import std/[os, strutils]\nimport geometry\n",
      ["ui"]).len == 0
    doAssert violations("remote", "r.nim", "import ../core/state\nimport ../ui/imgui/app\n",
      ["ui", "gpu", "view", "platform"]).len == 2 # the layer and the toolkit
    doAssert violations("core", "c.nim", "from ../remote/tools import busy\n",
      ["remote"]).len == 1

  block ssdatOnlyFromCore:
    var problems: seq[string]
    for file in walkDirRec(srcDir):
      if file.endsWith(".nim"):
        problems.add ssdatUsers(file.relativePath(srcDir), readFile(file))
    doAssert problems.len == 0,
      "only core/sigdat.nim may import parseSSDAT:\n  " & problems.join("\n  ")

  block ssvibOnlyFromCore:
    var problems: seq[string]
    for file in walkDirRec(srcDir):
      if file.endsWith(".nim"):
        problems.add ssvibUsers(file.relativePath(srcDir), readFile(file))
    doAssert problems.len == 0,
      "only core/sigvib.nim may import parseSSVIB:\n  " & problems.join("\n  ")

  block ssdatCheckerCatchesViolations:
    doAssert ssdatUsers("view/x.nim", "import parseSSDAT\n").len == 1
    doAssert ssdatUsers("ui/imgui/x.nim", "import parseSSDAT/decode\n").len == 1
    doAssert ssdatUsers("view/x.nim", "import std/os, parseSSDAT/[types, decode]\n").len == 1
    doAssert ssdatUsers("core/sigvib.nim", "import parseSSDAT\n").len == 1
    doAssert ssdatUsers("core/signatures.nim", "import parseSSDAT/types\n").len == 1
    doAssert ssdatUsers("core/sigdat.nim", "import parseSSDAT\nimport parseSSDAT/decode\n").len == 0
    doAssert ssdatUsers("view/x.nim", "import parseSEG\nimport ../core/parseSSDATlike\n").len == 0

  block ssvibCheckerCatchesViolations:
    doAssert ssvibUsers("view/x.nim", "import parseSSVIB\n").len == 1
    doAssert ssvibUsers("ui/imgui/x.nim", "import parseSSVIB/decode\n").len == 1
    doAssert ssvibUsers("view/x.nim", "import std/os, parseSSVIB/[types, decode]\n").len == 1
    doAssert ssvibUsers("core/sigdat.nim", "import parseSSVIB\n").len == 1
    doAssert ssvibUsers("core/signatures.nim", "import parseSSVIB/types\n").len == 1
    doAssert ssvibUsers("core/sigvib.nim", "import parseSSVIB\nimport parseSSVIB/decode\n").len == 0
    doAssert ssvibUsers("view/x.nim", "import parseSEG\nimport ../core/parseSSVIBlike\n").len == 0

  block noRegexEngine:
    var problems: seq[string]
    for dir in ["src", "tests", "tools"]:
      for file in walkDirRec(rootDir / dir):
        if file.endsWith(".nim") or file.endsWith(".nims"):
          problems.add pcreImports(file.relativePath(rootDir), readFile(file))
    doAssert problems.len == 0, "libpcre at run time (write the match by hand):\n  " &
      problems.join("\n  ")

  block regexCheckerCatchesImports:
    doAssert pcreImports("a.nim", "import std/[os, re]\nfrom std/nre import find\n" &
      "import\n  strutils,\n  pure/re\nimport pcre\n").len == 4
    doAssert pcreImports("b.nim", "import std/[os, strutils]\nimport nre2, parseutils\n" &
      "import ../core/regions\n").len == 0

  block testsExportMain:
    ## One program imports every test and calls `main`. A file that must be
    ## its own binary says so; the runner reads the same line.
    const separateLine = "## Separate binary:"
    let testDir = currentSourcePath().parentDir
    var problems: seq[string] = @[]
    var separate = 0
    for f in walkFiles(testDir / "t*.nim"):
      let name = f.extractFilename
      if name == "tester.nim":
        continue
      let text = readFile(f)
      var head: seq[string] = @[]
      for line in text.splitLines:
        if not line.startsWith("#"):
          break
        head.add line
      var exported = false
      for line in text.splitLines:
        if line.strip.startsWith("proc main*()"):
          exported = true
          break
      if not exported:
        problems.add name & " has no exported main"
      if "when isMainModule:" notin text:
        problems.add name & " does not call main when it is the main module"
      if head.anyIt(it.startsWith(separateLine)):
        inc separate
        if head.filterIt(it.startsWith(separateLine)).join(" ").len <= separateLine.len + 1:
          problems.add name & " is a separate binary with no reason"
    let runner = readFile(testDir / "tester.nim")
    if separateLine notin runner:
      problems.add "the runner does not read `" & separateLine & "`"
    doAssert problems.len == 0, "\n" & problems.join("\n")
    doAssert separate == 2, "separate binaries: " & $separate & ", expected tchrome and tmapthin"

when isMainModule:
  main()
