## The vendor header maps live in two repositories: viewSEG's `vendormaps/` (shipped with the
## program) and parseSEG's `vendormaps/` (shipped with the library). Every `.nif` in one is
## byte-identical to the same-named file in the other, and neither folder has a `.nif` the
## other lacks.
##
## Seen to fail: with one byte of a map changed in viewSEG's copy, "differs"; with a map
## copied into one folder alone, "has no counterpart".

import std/[os, sets]

const root = currentSourcePath().parentDir.parentDir

proc names(dir: string): HashSet[string] =
  for kind, p in walkDir(dir):
    if kind == pcFile and p.splitFile.ext == ".nif": result.incl p.extractFilename

proc main*() =
  let (ours, theirs) = (root / "vendormaps", root / "deps" / "parseSEG" / "vendormaps")
  doAssert dirExists(ours) and dirExists(theirs), "a vendormaps folder is missing"
  let (a, b) = (names(ours), names(theirs))
  doAssert a.len > 0, "no maps"
  for n in a - b: doAssert false, n & " has no counterpart in parseSEG's vendormaps"
  for n in b - a: doAssert false, n & " has no counterpart in viewSEG's vendormaps"
  for n in a: doAssert readFile(ours / n) == readFile(theirs / n), n & " differs"
  echo "tvendormapcopies: ", a.len, " maps"

when isMainModule:
  main()
