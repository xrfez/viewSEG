## The published files speak for themselves: no source file, test, tool or
## document points at the local development plan or its numbered phases, which
## are not part of the repository.

import std/[os, strutils]

const root = currentSourcePath().parentDir.parentDir

func mentionsPlan(line: string): bool =
  ## `PLAN.md`, or "Phase" / "phase" followed by a number.
  result = "PLAN.md" in line
  var at = line.find("hase ")
  while not result and at >= 1:
    let after = at + "hase ".len
    result = line[at - 1] in {'P', 'p'} and (at == 1 or line[at - 2] notin Letters) and
      after < line.len and line[after] in Digits
    at = line.find("hase ", at + 1)

proc published(): seq[string] =
  ## The text files a clone of the repository holds, apart from this test.
  result = @[root / "README.md", root / "config.nims", root / "viewSEG.nimble"]
  for dir in ["src", "tests", "tools", "docs", "config", "assets", "vendormaps",
      ".github"]:
    for f in walkDirRec(root / dir):
      if f.splitFile.ext in [".nim", ".nims", ".md", ".html", ".txt", ".toml", ".yml",
          ".sh", ".cmd"] and f != currentSourcePath():
        result.add f

block detector:
  doAssert mentionsPlan("see PLAN.md") and mentionsPlan("until Phase 1 brings")
  doAssert mentionsPlan("(phase 2)") and not mentionsPlan("zero phase filter")
  doAssert not mentionsPlan("Phase") and not mentionsPlan("emphase 2")

block noPlanReferences:
  var found: seq[string]
  for f in published():
    if fileExists(f):
      var n = 0
      for line in readFile(f).splitLines:
        inc n
        if mentionsPlan(line):
          found.add f.relativePath(root) & ":" & $n & ": " & line.strip
  doAssert found.len == 0, "references to the local plan:\n  " & found.join("\n  ")
