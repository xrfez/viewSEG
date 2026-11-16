## The shortcut table: every menu shortcut is a row generated from the menu's
## action table, no two rows of one group claim the same keys, a filter
## matches keys and words, and every key tested in ui/imgui is in some row.
## The user-guide page is that table (`nim shortcuts` rewrites it;
## `tools/shortcutspage.nim check` is what this runs).
##
## Seen to fail: with `F` taken out of the FFT row's covers, "ImGui_Key_F is
## in no row"; with the Open file chord dropped from the generated rows,
## "menu shortcut Ctrl+O is in no row"; with two Seismic plot rows given the
## same keys, "Seismic plot: Left / Right / Up / Down"; with the page's first
## heading changed, "keyboard-shortcuts.md is not the table's page".

import std/[os, sequtils, strutils]
import viewSEG/core/shortcuts
import ../tools/shortcutspage

const
  root = currentSourcePath().parentDir.parentDir
  imguiDir = root / "src" / "viewSEG" / "ui" / "imgui"

func codeOf(line: string): string =
  ## `line` without a comment (a `#` starts one; these files do not put a
  ## key name in a string).
  let hash = line.find('#')
  if hash >= 0: line[0 ..< hash] else: line

func keySuffixes(text: string): seq[string] =
  ## Every `ImGui_Key_` suffix named in `text`'s code.
  const prefix = "ImGui_Key_"
  for line in text.splitLines:
    let code = codeOf(line)
    var i = 0
    while i < code.len:
      let at = code.find(prefix, i)
      if at < 0: break
      var j = at + prefix.len
      while j < code.len and code[j] in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}: inc j
      let name = code[at + prefix.len ..< j]
      if name.len > 0 and name notin result: result.add name
      i = j

proc keysHandled(): seq[string] =
  ## Toolkit keys named in ui/imgui, where the program tests them.
  for f in walkDirRec(imguiDir):
    if f.endsWith(".nim"):
      for name in keySuffixes(readFile(f)):
        if name notin result: result.add name

block menu_shortcuts_are_rows:
  let menus = readFile(root / "src" / "viewSEG" / "ui" / "imgui" / "menus.nim")
  doAssert undescribedMenus(menus).len == 0, "a menu shortcut has no words: " &
    undescribedMenus(menus).join(", ")
  let rows = shortcutRows()
  for r in menuRowsFrom(menus):
    var found = false
    for row in rows:
      if row.id == r.id and r.keys in row.keys: found = true
    doAssert found, "menu shortcut " & r.keys & " is in no row (" & r.id & ")"
  doAssert rows.anyIt(it.id == "menu.maOpenFile" and "Ctrl+O" in it.keys)
  doAssert rows.anyIt(it.id == "menu.maRedo" and "Ctrl+Y" in it.keys),
    "Redo's other binding is missing"

block no_two_rows_claim_the_same_keys:
  let dup = sameKeys(shortcutRows())
  doAssert dup.len == 0, "two rows claim the same keys: " & dup.join("; ")
  var doubled = shortcutRows()
  doubled.add doubled[0]
  doAssert sameKeys(doubled).len == 1, "a repeated keys string was not seen"

block filter_matches_keys_and_words:
  let rows = shortcutRows()
  let zoom = filtered(rows, "zoom")
  doAssert zoom.len > 0, "zoom matched nothing"
  for r in zoom:
    doAssert r.matches("zoom")
  doAssert not shortcutRows()[0].matches("zoom") or "zoom" in shortcutRows()[0].what.toLowerAscii
  let ctrl = filtered(rows, "CTRL")
  doAssert ctrl.len > 0 and ctrl.anyIt("Ctrl" in it.keys)
  doAssert filtered(rows, "").len == rows.len
  doAssert filtered(rows, "no-such-gesture").len == 0

block every_handled_key_is_in_a_row:
  let covered = coveredKeys()
  var missing: seq[string] = @[]
  for name in keysHandled():
    if name notin covered: missing.add "ImGui_Key_" & name & " is in no row"
  doAssert missing.len == 0, missing.join("\n")
  # The scan sees a key, and a key the table names is not reported missing.
  doAssert "F" in keySuffixes("if igShortcut_Nil(ImGui_Key_F.cint, 0):")
  doAssert keySuffixes("## ImGui_Key_F in a comment").len == 0
  doAssert "Zed" notin covered

block the_page_is_the_table:
  let problems = checkPage()
  doAssert problems.len == 0, problems.join("\n")
  let page = keyboardPage()
  doAssert page.startsWith("# Keyboard shortcuts\n")
  doAssert "Ctrl+O" in page and "Ctrl + drag" in page and "F1" in page
  doAssert "Open a file" in page
