## The layer rules of docs/architecture.md: only `ui/` may know the GUI toolkit,
## and the lower layers never import the ones above them. Checked from the import
## statements of every module under src/viewSEG/.

import std/[os, sequtils, strutils]

const
  srcDir = currentSourcePath().parentDir.parentDir / "src" / "viewSEG"
  toolkits = ["imguin", "imgui", "implot", "sdl2", "sdl3", "glfw", "nimgl", "seaqt",
    "owlkettle", "windy", "boxy", "silky", "merenda"]
  # layer -> sibling layers (directories under src/viewSEG) it must not import
  forbidden = [
    ("core", @["ui", "gpu", "view", "platform"]),
    ("view", @["ui", "gpu", "platform"]),
    ("gpu", @["ui", "platform"]),
    ("platform", @["ui", "core", "view", "gpu"])]

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

proc violations(layer, file, text: string, banned: openArray[string]): seq[string] =
  for imp in imports(text):
    let parts = imp.replace('\\', '/').split('/')
    if parts.anyIt(it in toolkits):
      result.add file & " (" & layer & ") imports toolkit " & imp
    for b in banned:
      # `../ui/x`, `viewSEG/ui/x`, or `ui/x` relative to src/viewSEG
      if b in parts and (parts[0] in ["..", "viewSEG"] or parts[0] == b):
        result.add file & " (" & layer & ") imports " & imp

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
  doAssert violations("core", "ok.nim", "import std/[os, strutils]\nimport geometry\n",
    ["ui"]).len == 0
