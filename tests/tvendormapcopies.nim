## The vendor header maps live in three repositories: viewSEG's `vendormaps/` (shipped with
## the program), parseSEG's `vendormaps/` and parseSSDAT's `vendormaps/` (each shipped with
## its library). Every `.nif` in a library's folder is byte-identical to the same-named file
## in viewSEG's, and viewSEG's folder has no `.nif` that neither library has.
##
## Seen to fail: with one byte of a map changed in viewSEG's copy, "differs"; with a map
## copied into viewSEG's folder alone, "has no counterpart"; with a library's map missing
## from viewSEG's folder, "has no counterpart".

import std/[os, sets]

const root = currentSourcePath().parentDir.parentDir

proc names(dir: string): HashSet[string] =
  for kind, p in walkDir(dir):
    if kind == pcFile and p.splitFile.ext == ".nif": result.incl p.extractFilename

proc main*() =
  let ours = root / "vendormaps"
  let libs = [root / "deps" / "parseSEG" / "vendormaps",
    root / "deps" / "parseSSDAT" / "vendormaps"]
  doAssert dirExists(ours), "viewSEG's vendormaps folder is missing"
  let a = names(ours)
  doAssert a.len > 0, "no maps"
  var theirs = initHashSet[string]()
  for lib in libs:
    doAssert dirExists(lib), lib & " is missing"
    let b = names(lib)
    for n in b - a: doAssert false, n & " has no counterpart in viewSEG's vendormaps"
    for n in b: doAssert readFile(ours / n) == readFile(lib / n), n & " differs"
    theirs.incl b
  for n in a - theirs: doAssert false, n & " has no counterpart in a library's vendormaps"
  echo "tvendormapcopies: ", a.len, " maps"

when isMainModule:
  main()
