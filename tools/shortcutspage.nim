## The user-guide page of keyboard shortcuts, written from the shortcut table
## (`core/shortcuts`). `nim shortcuts` rewrites the page; `check` only
## compares it, which is what tests/tshortcuts.nim runs.
##
##   nim shortcuts
##   nim r tools/shortcutspage.nim check
##   nim r tools/shortcutspage.nim write

import std/os
import ../src/viewSEG/core/shortcuts

proc pagePath*(): string =
  ## docs/user/keyboard-shortcuts.md, beside this tool's repository.
  currentSourcePath().parentDir.parentDir / "docs" / "user" / "keyboard-shortcuts.md"

proc checkPage*(): seq[string] =
  ## Why the page is not the table's, or nothing when it is.
  let path = pagePath()
  if not fileExists(path):
    return @["docs/user/keyboard-shortcuts.md is missing (nim shortcuts writes it)"]
  if readFile(path) != keyboardPage():
    result.add "docs/user/keyboard-shortcuts.md is not the table's page (nim shortcuts)"

proc writePage*() =
  ## Rewrites the page from the table.
  writeFile(pagePath(), keyboardPage())

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
    quit "shortcutspage: check | write"
