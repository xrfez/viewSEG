## The source, test and tool files stay as nimpretty writes them (the check
## CI runs: `--indent:2 --maxLineLen:100`): every `.nim` file under `src/`,
## `tests/` and `tools/` but those in `NotYet`, written before the check and
## not formatted since. A file of that list that nimpretty leaves as it is
## must be taken off it, so the list only shrinks. Skipped without nimpretty.
##
## Seen to fail: with a comment's alignment changed by hand in
## `tests/utils/waiting.nim`, "not as nimpretty writes it: tests/utils/
## waiting.nim"; with `src/viewSEG/core/state.nim` back on the list after it
## was formatted, "formatted now: take it off NotYet"; with
## `docs/screenshots/old.png` written into README.md, the public-docs check
## named that mention and the image link that does not resolve.

import std/[algorithm, os, osproc, strutils, tempfiles]

const
  root = currentSourcePath().parentDir.parentDir
  NotYet = [
    "src/viewSEG/core/diskio.nim", "src/viewSEG/core/edits.nim", "src/viewSEG/core/filejobs.nim",
    "src/viewSEG/core/filememory.nim", "src/viewSEG/core/identity.nim",
    "src/viewSEG/core/panels.nim", "src/viewSEG/core/processing.nim",
    "src/viewSEG/core/reader.nim", "src/viewSEG/core/recordqc.nim",
    "src/viewSEG/core/spectra.nim",
    "src/viewSEG/core/spectrumreader.nim", "src/viewSEG/core/spread.nim",
    "src/viewSEG/core/tiles.nim", "src/viewSEG/core/watch.nim", "src/viewSEG/remote/control.nim",
    "src/viewSEG/ui/imgui/icons.nim", "src/viewSEG/ui/imgui/memorywindow.nim",
    "src/viewSEG/ui/imgui/menus.nim", "src/viewSEG/ui/imgui/spectrumwindow.nim",
    "src/viewSEG/view/curveplot.nim",
    "src/viewSEG/view/filetable.nim", "tests/tguiprocessing.nim",
    "tests/tguiroutes.nim", "tests/tguispectra.nim", "tests/tnetwork.nim", "tests/treadout.nim",
    "tests/trecordqc.nim", "tests/tshotcache.nim", "tests/utils/fixtures.nim", "tools/coverage.nim"]
    ## relative to the repository's root

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
