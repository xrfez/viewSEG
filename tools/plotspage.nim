## The user-guide page of what each plot tells you, written from the words the
## Explain icons show (`core/explain`). `nim plots` rewrites the page; `check`
## only compares it, which is what tests/texplain.nim runs.
##
##   nim plots
##   nim r tools/plotspage.nim check
##   nim r tools/plotspage.nim write

import std/[os, strutils]
import ../src/viewSEG/core/explain

proc pagePath*(): string =
  ## docs/user/plots.md, beside this tool's repository.
  currentSourcePath().parentDir.parentDir / "docs" / "user" / "plots.md"

proc checkPage*(): seq[string] =
  ## Why the page is not the explanations', or nothing when it is.
  let path = pagePath()
  if not fileExists(path):
    return @["docs/user/plots.md is missing (nim plots writes it)"]
  if readFile(path) != explainPage():
    result.add "docs/user/plots.md is not the explanations' page (nim plots)"

proc writePage*() =
  ## Rewrites the page from the explanations.
  writeFile(pagePath(), explainPage())

when isMainModule:
  let cmd = if paramCount() >= 1: paramStr(1) else: "write"
  if cmd == "check":
    let problems = checkPage()
    if problems.len > 0:
      quit problems.join("\n")
  elif cmd == "write":
    writePage()
    let problems = checkPage()
    if problems.len > 0:
      quit problems.join("\n")
  else:
    quit "plotspage: check | write"
