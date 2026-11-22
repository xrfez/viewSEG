## Neutral names for the private sample files.
##
## A test that needs a real survey file asks for it by a key that says what
## kind of file it is (`landSegd`, `landSps`), never whose. The mapping is
## read at run time from `exampleFiles/names.cfg` (lines `key = relative/path`,
## `#` comments), which lives in the private folder and is never tracked. No
## private name is compiled in.
##
## `privateFile` returns the full path, or "" when the folder, the mapping or
## the mapped file is missing, so a test skips as it does when the file is
## not there. A key absent from an existing mapping is an error that names
## the key.

import std/[os, strutils, tables]

const
  Examples = currentSourcePath().parentDir.parentDir / "exampleFiles"
  MappingName = "names.cfg"

var
  cachedRoot = ""
  cachedPresent = false
  cachedPaths: Table[string, string]

proc loadMapping(root: string): tuple[present: bool, paths: Table[string, string]] =
  ## `present` is false when `root` or its mapping is missing (a skip, not
  ## an error). A bad line is an error that quotes the line.
  if root == cachedRoot and cachedRoot.len > 0:
    return (cachedPresent, cachedPaths)
  var paths: Table[string, string]
  var present = false
  if dirExists(root):
    let cfg = root / MappingName
    if fileExists(cfg):
      for raw in lines(cfg):
        let line = raw.strip
        if line.len == 0 or line.startsWith('#'):
          continue
        let eq = line.find('=')
        let key = if eq > 0: line[0 ..< eq].strip else: ""
        let rel = if eq > 0: line[eq + 1 .. ^1].strip else: ""
        if key.len == 0 or rel.len == 0 or key in paths:
          raise newException(ValueError, cfg & ": not a new `key = path`: " & line)
        paths[key] = root / rel
      present = true
  cachedRoot = root
  cachedPresent = present
  cachedPaths = paths
  (present, cachedPaths)

proc privateFile*(key: string; root = ""): string =
  ## The full path of the private file `key` names, or "" when the folder,
  ## the mapping or that file is missing. A key absent from an existing
  ## mapping is an error that names the key. `root` defaults to
  ## `exampleFiles/` beside this repository; a test of the mapping passes
  ## another folder.
  let folder = if root.len == 0: Examples else: root
  let (present, paths) = loadMapping(folder)
  if not present:
    return ""
  if key notin paths:
    raise newException(ValueError, folder / MappingName & " has no key \"" & key & "\"")
  let path = paths[key]
  if fileExists(path): path else: ""

proc privateFiles*(keys: varargs[string]): seq[string] =
  ## The path of every key, or empty when any mapped file is missing, so
  ## the caller skips the whole set. A missing key is still an error.
  for key in keys:
    let path = privateFile(key)
    if path.len == 0:
      return @[]
    result.add path

proc listedNames*(root = ""): seq[string] =
  ## Every file name the mapping lists (the relative path and, when it
  ## differs, the basename), or empty when the folder or the mapping is
  ## missing.
  let folder = if root.len == 0: Examples else: root
  let (present, paths) = loadMapping(folder)
  if not present:
    return
  for path in paths.values:
    # as the mapping writes it
    let rel = relativePath(path, folder).replace('\\', '/')
    result.add rel
    let base = rel.extractFilename
    if base != rel:
      result.add base
