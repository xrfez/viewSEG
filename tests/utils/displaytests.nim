## Which test files need a display: the runner's `--no-display` leaves them
## out, for a machine that has no X server or no OpenGL (the Windows job in
## CI, which runs the rest natively).
##
## Also here: which files a run leaves out (`leftOut`), as the runner's
## switches and the platform decide.
##
## A file needs a display when it is named `tgui*`, or imports the GUI toolkit, the
## window code (`viewSEG/ui/...`), the GL layer (`viewSEG/gpu/...`) or the
## program's main module (`viewSEG`, which pulls in the window code), directly
## or through a helper in `tests/utils`. The scan reads import statements only
## (as tests/tlayers does), so it is cheap and needs no compile.

import std/[os, sequtils, strutils, times]

const
  AloneLine* = "## Runs alone:"
  NotWindowsLine* = "## Not on Windows:" ## left out on Windows; the rest says why
  UiFolder = "ui"
  GpuFolder = "gpu"
  Toolkits = ["imguin", "imgui", "implot", "sdl3", "sdl3_nim", "opengl", "glad"]

proc importsOf*(text: string): seq[string] =
  ## The module paths named by the import, from and include statements in
  ## `text`, bracketed and multi-line lists included (a list's prefix and
  ## its names come out as separate items: `a/[b, c]` is `a/`, `b`, `c`).
  var inList = false
  for raw in text.splitLines:
    let line = raw.split('#')[0].strip
    if line.len == 0:
      continue
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
      if name.len > 0:
        result.add name
    inList = line.endsWith(",") or ('[' in line and ']' notin line)

func windowImport(imp: string): bool =
  ## Whether `imp` names the toolkit, the window code, the GL layer or the
  ## main module.
  let parts = imp.replace('\\', '/').split('/')
  if parts.len == 1 and parts[0] == "viewSEG":
    return true # the main module: `import viewSEG`
  for p in parts:
    if p in Toolkits:
      return true
  for i in 1 ..< parts.len:
    if parts[i] in [UiFolder, GpuFolder] and parts[i - 1] in ["viewSEG", ".."]:
      return true
  parts[0] in [UiFolder, GpuFolder] # relative to src/viewSEG

proc needsDisplay*(path: string; seen: seq[string] = @[]): bool =
  ## Whether the test file (or helper) at `path` needs a display. `seen`
  ## holds the helpers already looked at (an import cycle ends there).
  let name = path.extractFilename
  if name.startsWith("tgui"):
    return true
  for imp in importsOf(readFile(path)):
    if windowImport(imp):
      return true
    let utils = if path.parentDir.lastPathPart == "utils": path.parentDir
                else: path.parentDir / "utils"
    let candidate = utils / imp.replace('\\', '/').split('/')[^1] & ".nim"
    if imp.startsWith("std/") or candidate in seen or not fileExists(candidate):
      continue
    if needsDisplay(candidate, seen & path):
      return true
  false

func processFailure*(code: int; took, limit: Duration): string =
  ## Why a run that ended with exit code `code` after `took` failed ("" when it
  ## did not). A run past `limit` failed whatever its code: Windows gives a
  ## process it ended the code its caller asked for, which may be 0.
  if took >= limit: "timed out after " & $limit.inSeconds & " s, stopped"
  elif code != 0: "exit code " & $code
  else: ""

proc leftOut*(path: string; head: seq[string]; noDisplay, noTiming, windows: bool;
    onlyTiming = false): string =
  ## Why a run leaves the test file at `path` (header lines `head`) out:
  ## "" when it runs. `onlyTiming` keeps only the files that run alone.
  if windows and head.anyIt(it.startsWith(NotWindowsLine)):
    "not on Windows"
  elif onlyTiming and not head.anyIt(it.startsWith(AloneLine)):
    "does not measure times"
  elif noTiming and head.anyIt(it.startsWith(AloneLine)):
    "measures times"
  elif noDisplay and needsDisplay(path):
    "needs a display"
  else:
    ""
