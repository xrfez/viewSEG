## The source, test and tool files stay as nimpretty writes them (the check
## CI runs: `--indent:2 --maxLineLen:100`): every `.nim` file under `src/`,
## `tests/` and `tools/`. (The `NotYet` list of files exempt from it was
## emptied once all of them were formatted, so the list is now empty.) Skipped
## without nimpretty.
##
## Seen to fail: with a comment's alignment changed by hand in
## `tests/utils/waiting.nim`, "not as nimpretty writes it: tests/utils/
## waiting.nim"; with `src/viewSEG/core/state.nim` back on the list after it
## was formatted, "formatted now: take it off NotYet"; with
## `docs/screenshots/old.png` written into README.md, the public-docs check
## named that mention and the image link that does not resolve. With a
## private sample's file name written into README.md, the private-names
## check named that file (skipped when `exampleFiles/names.cfg` is absent).

import std/[algorithm, os, osproc, strutils, tempfiles]
import privatefiles

const
  root = currentSourcePath().parentDir.parentDir
  NotYet: array[0, string] = [] ## no file is exempt: every file is checked

proc sources(): seq[string] =
  ## Every `.nim` file under src/, tests/ and tools/, relative to the root.
  for dir in ["src", "tests", "tools"]:
    for f in walkDirRec(root / dir):
      if f.endsWith(".nim"):
        result.add f.relativePath(root)
  result.sort()

let nimpretty = findExe("nimpretty")
if nimpretty.len == 0:
  echo "tformat: skipped, no nimpretty"
else:
  let tmp = createTempDir("viewseg-tformat-", "")
  try:
    let files = sources()
    for name in NotYet:
      doAssert name in files, name & " is on NotYet but not in the repository"
    var commands: seq[string]
    for i, f in files:
      commands.add quoteShellCommand([nimpretty, "--indent:2", "--maxLineLen:100",
        "--out:" & tmp / $i & ".nim", root / f])
    discard execProcesses(commands, n = max(1, countProcessors() div 4),
      options = {poStdErrToStdOut, poParentStreams})
    var problems: seq[string]
    for i, f in files:
      let pretty = tmp / $i & ".nim"
      doAssert fileExists(pretty), "nimpretty wrote nothing for " & f
      let same = readFile(pretty) == readFile(root / f)
      if f in NotYet and same:
        problems.add "formatted now: take it off NotYet: " & f
      elif f notin NotYet and not same:
        problems.add "not as nimpretty writes it: " & f &
          " (nimpretty --indent:2 --maxLineLen:100 " & f & " formats it)"
    doAssert problems.len == 0, "\n" & problems.join("\n")
    echo "tformat: ", files.len - NotYet.len, " of ", files.len, " files as nimpretty writes them"
  finally:
    removeDir(tmp)

proc publicDocs(): seq[string] =
  ## README, docs (not the old picture folder), and the READMEs a reader of
  ## the repository sees beside assets, samples and vendormaps.
  result.add root / "README.md"
  result.add root / "samples" / "README.md"
  result.add root / "vendormaps" / "README.md"
  let shots = root / "docs" / "screenshots"
  for f in walkDirRec(root / "docs"):
    if not f.startsWith(shots):
      result.add f
  for f in walkDirRec(root / "assets"):
    if f.endsWith("README.md"):
      result.add f

proc imageTargets(text: string): seq[string] =
  ## Markdown image links and `<img src>`, the target only.
  var i = 0
  while true:
    let at = text.find("![", i)
    if at < 0: break
    let open = text.find("](", at + 2)
    if open < 0: break
    let close = text.find(')', open + 2)
    if close < 0: break
    var target = text[open + 2 ..< close].strip
    let space = target.find(' ')
    if space >= 0: target = target[0 ..< space].strip
    if target.len > 0: result.add target
    i = close + 1
  i = 0
  while true:
    let at = text.find("<img", i)
    if at < 0: break
    let src = text.find("src=", at + 4)
    if src < 0 or src > at + 200: break
    let q = text[src + 4]
    if q notin {'\'', '"'}: break
    let close = text.find(q, src + 5)
    if close < 0: break
    result.add text[src + 5 ..< close]
    i = close + 1

block publicDocsStayLocal:
  ## No public page names the old picture folder, and every image link
  ## resolves to a file. Seen to fail with `docs/screenshots/old.png` written
  ## into README.md.
  var problems: seq[string]
  for f in publicDocs():
    if f.splitFile.ext notin [".md", ".html", ".txt", ".nif", ".toml"]:
      continue
    let text = readFile(f)
    let rel = f.relativePath(root)
    if "docs/screenshots" in text:
      problems.add rel & " mentions docs/screenshots"
    for target in imageTargets(text):
      if target.startsWith("http://") or target.startsWith("https://") or
          target.startsWith("data:"):
        problems.add rel & " image is not a file: " & target
      else:
        let path = absolutePath(f.parentDir / target)
        if not fileExists(path):
          problems.add rel & " image link does not resolve: " & target
  doAssert problems.len == 0, "\n" & problems.join("\n")
  echo "tformat: public docs name no private pictures, image links resolve"

block privateNamesStayOut:
  ## No tracked file contains a file name from exampleFiles/names.cfg, in
  ## its path or its text. Skipped when that mapping is absent.
  let names = listedNames()
  if names.len == 0:
    echo "tformat: private names not checked (no exampleFiles/names.cfg)"
  else:
    let (output, code) = execCmdEx("git ls-files -z", workingDir = root)
    doAssert code == 0, "git ls-files failed: " & output
    var problems: seq[string]
    for rel in output.split('\0'):
      if rel.len == 0:
        continue
      var hit = ""
      for name in names:
        if name in rel:
          hit = name
          break
      if hit.len > 0:
        problems.add rel & " path contains " & hit
      elif fileExists(root / rel):
        let text = readFile(root / rel)
        for name in names:
          if name in text:
            hit = name
            break
        if hit.len > 0:
          problems.add rel & " contains " & hit
    doAssert problems.len == 0, "a private file name is tracked:\n" & problems.join("\n")
    echo "tformat: no tracked file names a private sample"
