## Layouts: how the windows are arranged (where each is docked and how
## large, which float and where), kept as NIF documents:
##
## ```
## (.nif27)
## (.vendor "viewSEG")
## (layout
##  (version 1)
##  (name "Wide plot")
##  (imgui "[Window][###plot]
## Pos=8,64
## ..."))
## ```
##
## The arrangement itself is the GUI toolkit's own text (Dear ImGui's layout
## text, in its `.ini` form), carried as a string: `core` stores it and
## never reads it. Three places hold layouts:
##
## - `<config>/layout.nif`: the arrangement when the program last closed,
##   restored at start (`loadLayoutFile`, which moves a damaged file aside as
##   `loadSettings` does);
## - `<config>/layouts/<name>.nif`: the layouts the user saved by name;
## - `<assets>/layouts/*.nif`: presets that ship with the program.

import std/[algorithm, os, strutils]
import log, nif, persist

export nif

const
  LayoutVersion* = 1             ## the version `layoutDocument` writes
  LayoutFileName* = "layout.nif" ## the arrangement at the last exit, in the config folder
  LayoutsDirName* = "layouts"    ## named layouts, in the config folder; presets, in an assets folder
  LayoutExt* = ".nif"
  MaxLayoutName* = 64            ## the longest name a layout is given

type
  Layout* = object
    ## An arrangement of the windows.
    name*: string  ## what the user called it; "" for none
    imgui*: string ## the toolkit's own layout text

  SavedLayout* = object
    ## A layout that can be loaded.
    name*: string
    path*: string
    preset*: bool ## shipped with the program, not the user's

  LoadedLayout* = object
    ## What `loadLayoutFile` found.
    found*: bool ## a usable layout: `layout` holds it
    layout*: Layout
    notes*: seq[Note]

func layoutDocument*(l: Layout): string =
  ## `l` as a NIF document.
  var w = initNifWriter()
  w.open("layout")
  w.open("version")
  w.add int64(LayoutVersion)
  w.close()
  if l.name.len > 0:
    w.open("name")
    w.add l.name
    w.close()
  w.open("imgui")
  w.add l.imgui
  w.close()
  w.close()
  w.finish

proc readLayout*(text, name: string; problems: var seq[string]): Layout =
  ## The layout in the document `text` (error messages call it `name`); what
  ## it holds that is not used goes to `problems`. Raises `NifError` when it
  ## is not NIF, or holds no layout.
  let doc = parseNif(text, name)
  var root = -1
  for i, n in doc:
    if n.kind == nkTree and n.tag.startsWith("."): discard
    elif root < 0 and n.isTree("layout"): root = i
    else: problems.add name & " line " & $n.line & ": " & describe(n) & " is not part of a " &
      "layout; skipped."
  var imgui = false
  var version = 0
  if root >= 0:
    for c in doc[root].kids:
      let one = c.kind == nkTree and c.kids.len == 1
      if one and c.tag == "version" and c.kids[0].kind == nkInt:
        version = int(clamp(c.kids[0].intVal, 0, high(int32)))
      elif one and c.tag == "name" and c.kids[0].kind == nkString:
        result.name = c.kids[0].text
      elif one and c.tag == "imgui" and c.kids[0].kind == nkString:
        result.imgui = c.kids[0].text
        imgui = true
      else:
        problems.add name & " line " & $c.line & ": " & describe(c) & " in (layout) is " &
          "not known or not usable; skipped."
  if not imgui:
    var e = newException(NifError, name & " holds no layout (no (layout ... (imgui \"...\")))")
    e.line = (if root >= 0: doc[root].line else: 0)
    raise e
  if version > LayoutVersion:
    problems.add name & ": written by a newer viewSEG (layout version " & $version &
      "); read as far as this one can."

func layoutNameProblem*(name: string): string =
  ## Why `name` cannot name a layout file on every system; "" when it can.
  const forbidden = {'<', '>', ':', '"', '/', '\\', '|', '?', '*'}
  let n = name.strip
  if n.len == 0: "a layout needs a name"
  elif n.len > MaxLayoutName: "a layout's name has at most " & $MaxLayoutName & " characters"
  elif n.contains(forbidden) or n.contains({'\0'..'\31', '\127'}):
    "a layout's name cannot hold < > : \" / \\ | ? * or control characters"
  elif n[^1] == '.' or n.startsWith("."): "a layout's name cannot start or end with a dot"
  elif n.split('.')[0].toUpperAscii in ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3",
      "COM4", "LPT1", "LPT2", "LPT3"]: "\"" & n & "\" is a name Windows keeps for itself"
  else: ""

func layoutPath*(configDir, name: string): string =
  ## Where the user's layout `name` is kept.
  configDir / LayoutsDirName / (name.strip & LayoutExt)

func byName(a, b: SavedLayout): int = cmp(a.name.toLowerAscii, b.name.toLowerAscii)

func added*(list: openArray[SavedLayout]; e: SavedLayout): seq[SavedLayout] =
  ## `list` (as `listLayouts` gives it) with the user's layout `e` among the
  ## user's, in place of one of its name (and hiding a preset of its name).
  var mine, shipped: seq[SavedLayout]
  for x in list:
    if x.name.toLowerAscii == e.name.toLowerAscii: discard
    elif x.preset: shipped.add x
    else: mine.add x
  mine.add e
  mine.sort(byName)
  mine & shipped

proc listLayouts*(configDir: string; presetDirs: openArray[string]): seq[SavedLayout] =
  ## The user's layouts (by name), then the presets in `presetDirs` (each
  ## its `layouts/` folder), each name once: a user's layout hides a preset
  ## of its name. Reads only the folders.
  var mine, shipped: seq[SavedLayout]
  proc scan(dir: string; preset: bool; into: var seq[SavedLayout]) =
    for kind, f in walkDir(dir):
      let (_, stem, ext) = f.splitFile
      if kind in {pcFile, pcLinkToFile} and ext.toLowerAscii == LayoutExt and stem.len > 0:
        into.add SavedLayout(name: stem, path: f, preset: preset)
  if configDir.len > 0: scan(configDir / LayoutsDirName, false, mine)
  for d in presetDirs: scan(d / LayoutsDirName, true, shipped)
  mine.sort(byName)
  shipped.sort(byName)
  result = mine
  for s in shipped:
    var taken = false
    for r in result:
      if r.name.toLowerAscii == s.name.toLowerAscii: taken = true
    if not taken: result.add s

proc loadLayoutFile*(path: string): LoadedLayout =
  ## The layout at `path` (the arrangement at the last exit), if there is a
  ## usable one; a file that cannot be read is moved aside as a backup and
  ## the notes say so. Never raises.
  result = LoadedLayout()
  if not fileExists(path): return
  var text = ""
  var why = readDocument(path, text)
  var problems: seq[string]
  if why.len == 0:
    try:
      result.layout = readLayout(text, path.extractFilename, problems)
      result.found = true
    except NifError as e:
      why = e.msg
  if why.len > 0:
    let backup = backupPath(path)
    try:
      moveFile(path, backup)
      result.notes.add (sevWarning, "The window layout could not be read: " & why &
        ". The file was moved to " & backup & ", and the windows start as they are by " &
        "default.")
    except OSError, IOError:
      result.notes.add (sevWarning, "The window layout in " & path & " could not be read (" &
        why & "); the windows start as they are by default.")
    pruneBackups(path)
  result.notes.addProblems(problems)
