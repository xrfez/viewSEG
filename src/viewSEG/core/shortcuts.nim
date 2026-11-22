## Keyboard and mouse gestures, as Help lists them and the user guide prints
## them. Toolkit-free: keys are the words the user reads ("Ctrl+O",
## "Alt+Left / Alt+Right", "Ctrl + drag"), not a toolkit's key codes.
##
## Menu shortcuts are not retyped. Their rows are read from the menu's own
## action table (`ui/imgui/menus.nim`, the `shortcuts` array), so a changed
## chord changes this list at the next compile. The window replaces those
## names with the ones the toolkit reports for this platform. The other
## rows are this module's. A row's `chord` is the one token handling code
## can test; `covers` names every toolkit key the row accounts for.

import std/strutils

type
  ShortcutGroup* = enum
    ## A section of the list, in the order Help shows them.
    sgFiles = "Files and projects"
    sgPlot = "Seismic plot"
    sgEdits = "Selection and edits"
    sgSpectrum = "Spectrum and graphs"
    sgMap = "Map"
    sgTables = "Tables"
    sgWindows = "Windows"

  Gesture* = enum
    ## A key, or a mouse gesture (listed after the keys of its group).
    gsKey, gsMouse

  ShortcutRow* = object
    group*: ShortcutGroup
    keys*: string   ## as shown: "Ctrl+O", "Alt+Left / Alt+Right", "Ctrl + drag"
    what*: string   ## a few plain words
    gesture*: Gesture
    id*: string     ## stable name, for marks and for handling code
    covers*: string ## toolkit key suffixes this row accounts for, by spaces
    chord*: string  ## one token handling code can test ("F", "Ctrl+G"); "" if none
    menu*: string   ## the menu item's label, when the row comes from the action table

const
  menusSource = staticRead("../ui/imgui/menus.nim")
    ## The menu module, read at compile time so a changed shortcut changes
    ## this list. Not an import: this module stays free of the toolkit.

  menuDescribed = [
    ("maOpenFile", "Open file...", sgFiles, "Open a file"),
    ("maOpenFiles", "Open files...", sgFiles, "Open several files"),
    ("maOpenFolder", "Open folder...", sgFiles, "Open a folder and list its files"),
    ("maClose", "Close", sgFiles, "Close the file the plot shows"),
    ("maQuit", "Quit", sgFiles, "Quit"),
    ("maUndo", "Undo", sgEdits, "Undo the last edit of the file shown"),
    ("maSelectAll", "Select all traces", sgEdits,
      "Select every trace the Seismic window shows"),
    ("maRedo", "Redo", sgEdits, "Redo the edit undone last"),
    ("maResetWindows", "Reset the windows", sgWindows,
      "Put every window back as at a first start"),
    ("maShortcuts", "Keyboard shortcuts", sgWindows, "Open this list")]
    ## Words for each menu action that has a shortcut. An action in the
    ## table with a chord and no words here is a gap (`undescribedMenus`).

  gestures = [
    ShortcutRow(group: sgFiles, gesture: gsMouse, id: "files.drop",
      keys: "Drop files or a folder",
      what: "List them, and show the first seismic file"),
    ShortcutRow(group: sgPlot, gesture: gsKey, id: "plot.pan",
      keys: "Left / Right / Up / Down",
      what: "Pan a tenth of the view, the way the key points",
      covers: "LeftArrow RightArrow UpArrow DownArrow"),
    ShortcutRow(group: sgPlot, gesture: gsKey, id: "plot.panView",
      keys: "Shift+Left / Shift+Right / Shift+Up / Shift+Down",
      what: "Pan a whole view"),
    ShortcutRow(group: sgPlot, gesture: gsKey, id: "plot.zoomKeys",
      keys: "+ / -",
      what: "Zoom in or out about the pointer (keypad + and - do the same)",
      covers: "Equal Minus KeypadAdd KeypadSubtract"),
    ShortcutRow(group: sgPlot, gesture: gsKey, id: "plot.zoomUp",
      keys: "Ctrl+Up / Ctrl+Down",
      what: "Zoom the up-down axis only"),
    ShortcutRow(group: sgPlot, gesture: gsKey, id: "plot.zoomAcross",
      keys: "Ctrl+Left / Ctrl+Right",
      what: "Zoom the across axis only"),
    ShortcutRow(group: sgPlot, gesture: gsKey, id: "plot.fit",
      keys: "Ctrl+0",
      what: "Fit the whole record (keypad 0 does the same)",
      covers: "0 Keypad0"),
    ShortcutRow(group: sgPlot, gesture: gsKey, id: "plot.gain",
      keys: "] / [",
      what: "More or less gain, 3 dB; with Shift, 12 dB (keypad * and / do the same)",
      covers: "RightBracket LeftBracket KeypadMultiply KeypadDivide"),
    ShortcutRow(group: sgPlot, gesture: gsKey, id: "plot.back",
      keys: "Backspace", what: "Back to the previous view",
      covers: "Backspace", chord: "Backspace"),
    ShortcutRow(group: sgPlot, gesture: gsKey, id: "plot.step",
      keys: "Alt+Left / Alt+Right",
      what: "Select the previous or next trace (Alt+Up / Alt+Down when time is across)"),
    ShortcutRow(group: sgPlot, gesture: gsKey, id: "plot.record",
      keys: "Page Down / Page Up", what: "Next or previous record",
      covers: "PageDown PageUp"),
    ShortcutRow(group: sgPlot, gesture: gsKey, id: "plot.recordEnds",
      keys: "Home / End", what: "First or last record",
      covers: "Home End"),
    ShortcutRow(group: sgPlot, gesture: gsKey, id: "plot.goto",
      keys: "Ctrl+G", what: "Go to a record number",
      covers: "G", chord: "Ctrl+G"),
    ShortcutRow(group: sgPlot, gesture: gsKey, id: "plot.raw",
      keys: "P", what: "Show the traces raw, or through the filters",
      covers: "P", chord: "P"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.hover",
      keys: "Move the pointer",
      what: "The trace under it is highlighted, and read out on the status bar"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.click",
      keys: "Left click", what: "Select that trace"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.ctrlClick",
      keys: "Ctrl + click", what: "Add the trace to the selection, or take it out"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.shiftClick",
      keys: "Shift + click", what: "Select from the trace clicked last to this one"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.drag",
      keys: "Left drag", what: "Pan"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.middle",
      keys: "Middle drag", what: "Pan"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.box",
      keys: "Right drag", what: "Zoom to the box"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.menu",
      keys: "Right-click", what: "The menu of the trace under the pointer"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.headerMenu",
      keys: "Right-click the display header", what: "Choose the header fields"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.wheel",
      keys: "Wheel", what: "Zoom both axes about the pointer"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.ctrlWheel",
      keys: "Ctrl + wheel", what: "Zoom the up-down axis only"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.shiftWheel",
      keys: "Shift + wheel", what: "Zoom the across axis only"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.wheelH",
      keys: "Sideways wheel", what: "Zoom the across axis only"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.barDrag",
      keys: "Drag a scroll bar", what: "Pan along that bar"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.barTrack",
      keys: "Click a scroll bar's track", what: "Pan by a whole view; held, it repeats"),
    ShortcutRow(group: sgPlot, gesture: gsMouse, id: "plot.barWheel",
      keys: "Wheel over a scroll bar", what: "Pan along that bar"),
    ShortcutRow(group: sgEdits, gesture: gsKey, id: "plot.reverse",
      keys: "R", what: "Reverse the polarity of the trace under the pointer, or put it back",
      covers: "R", chord: "R"),
    ShortcutRow(group: sgEdits, gesture: gsKey, id: "plot.kill",
      keys: "K", what: "Kill the trace under the pointer, or restore it",
      covers: "K", chord: "K"),
    ShortcutRow(group: sgEdits, gesture: gsKey, id: "plot.exclude",
      keys: "E", what: "Exclude the trace under the pointer from the plot's filters, or put it back",
      covers: "E", chord: "E"),
    ShortcutRow(group: sgEdits, gesture: gsKey, id: "plot.fft",
      keys: "F", what: "Open the amplitude spectrum of the trace under the pointer",
      covers: "F", chord: "F"),
    ShortcutRow(group: sgEdits, gesture: gsKey, id: "plot.station",
      keys: "M", what: "Select the trace's station on the map",
      covers: "M", chord: "M"),
    ShortcutRow(group: sgEdits, gesture: gsKey, id: "plot.cancel",
      keys: "Escape",
      what: "Cancel the drag, or clear the selection",
      covers: "Escape", chord: "Escape"),
    ShortcutRow(group: sgSpectrum, gesture: gsMouse, id: "plot.explain",
      keys: "Right-click a plot",
      what: "Explain: what the plot shows and how to read it (Esc closes it)"),
    ShortcutRow(group: sgSpectrum, gesture: gsKey, id: "spectrum.move",
      keys: "Left / Right",
      what: "Move the held cursor a bin, or a sample in a graph"),
    ShortcutRow(group: sgSpectrum, gesture: gsKey, id: "spectrum.curve",
      keys: "Up / Down",
      what: "Move the held cursor to another curve, or a frequency bin in a spectrogram"),
    ShortcutRow(group: sgSpectrum, gesture: gsKey, id: "spectrum.ends",
      keys: "Home / End", what: "Move the held cursor to the ends"),
    ShortcutRow(group: sgSpectrum, gesture: gsKey, id: "spectrum.letGo",
      keys: "Escape", what: "Let the held cursor go"),
    ShortcutRow(group: sgSpectrum, gesture: gsKey, id: "spectrum.step",
      keys: "Alt+Left / Alt+Right",
      what: "The previous or next trace of the record"),
    ShortcutRow(group: sgSpectrum, gesture: gsMouse, id: "spectrum.pointer",
      keys: "Move the pointer",
      what: "The cursor follows it; moving it lets a held cursor go"),
    ShortcutRow(group: sgSpectrum, gesture: gsMouse, id: "spectrum.wheel",
      keys: "Wheel", what: "Zoom the graph about the pointer"),
    ShortcutRow(group: sgSpectrum, gesture: gsMouse, id: "spectrum.drag",
      keys: "Drag", what: "Pan the graph"),
    ShortcutRow(group: sgSpectrum, gesture: gsMouse, id: "spectrum.box",
      keys: "Right drag", what: "Zoom the graph to the box"),
    ShortcutRow(group: sgSpectrum, gesture: gsMouse, id: "spectrum.fit",
      keys: "Double-click", what: "Fit the graph to its data"),
    ShortcutRow(group: sgSpectrum, gesture: gsMouse, id: "spectrum.legend",
      keys: "Click a legend entry", what: "Hide that curve, or show it again"),
    ShortcutRow(group: sgMap, gesture: gsKey, id: "map.zoomKeys",
      keys: "+ / -", what: "Zoom in or out about the pointer (keypad + and - do the same)"),
    ShortcutRow(group: sgMap, gesture: gsKey, id: "map.pan",
      keys: "Left / Right / Up / Down", what: "Pan a tenth of the view"),
    ShortcutRow(group: sgMap, gesture: gsKey, id: "map.panView",
      keys: "Shift+Left / Shift+Right / Shift+Up / Shift+Down",
      what: "Pan a whole view"),
    ShortcutRow(group: sgMap, gesture: gsKey, id: "map.fit",
      keys: "Ctrl+0", what: "Fit the whole survey (keypad 0 does the same)"),
    ShortcutRow(group: sgMap, gesture: gsKey, id: "map.back",
      keys: "Backspace / Alt+Left", what: "Back to the previous view"),
    ShortcutRow(group: sgMap, gesture: gsKey, id: "map.cancel",
      keys: "Escape",
      what: "Cancel the drag, or end the ruler, or clear the selection"),
    ShortcutRow(group: sgMap, gesture: gsMouse, id: "map.hover",
      keys: "Move the pointer",
      what: "The point under it is described, and its traces light up in the plot"),
    ShortcutRow(group: sgMap, gesture: gsMouse, id: "map.click",
      keys: "Left click",
      what: "Select the point, or show a source's record"),
    ShortcutRow(group: sgMap, gesture: gsMouse, id: "map.ctrlClick",
      keys: "Ctrl + click", what: "Add the point to the selection, or take it out"),
    ShortcutRow(group: sgMap, gesture: gsMouse, id: "map.shiftClick",
      keys: "Shift + click", what: "Select the stations along the line to this point"),
    ShortcutRow(group: sgMap, gesture: gsMouse, id: "map.drag",
      keys: "Left drag", what: "Pan"),
    ShortcutRow(group: sgMap, gesture: gsMouse, id: "map.middle",
      keys: "Middle drag", what: "Pan"),
    ShortcutRow(group: sgMap, gesture: gsMouse, id: "map.ruler",
      keys: "Ctrl + drag", what: "Measure a line; its length is shown until Escape"),
    ShortcutRow(group: sgMap, gesture: gsMouse, id: "map.rulerOn",
      keys: "Drag with the ruler on", what: "Measure, as Ctrl + drag does"),
    ShortcutRow(group: sgMap, gesture: gsMouse, id: "map.boxSelect",
      keys: "Shift + drag", what: "Select the points in the box, and their traces"),
    ShortcutRow(group: sgMap, gesture: gsMouse, id: "map.boxAdd",
      keys: "Ctrl+Shift + drag", what: "Add the points in the box to the selection"),
    ShortcutRow(group: sgMap, gesture: gsMouse, id: "map.box",
      keys: "Right drag", what: "Zoom to the box"),
    ShortcutRow(group: sgMap, gesture: gsMouse, id: "map.menu",
      keys: "Right-click", what: "The menu of the point under the pointer"),
    ShortcutRow(group: sgMap, gesture: gsMouse, id: "map.wheel",
      keys: "Wheel", what: "Zoom about the pointer"),
    ShortcutRow(group: sgTables, gesture: gsKey, id: "tables.step",
      keys: "Up / Down",
      what: "The next or previous file or record (not in the filter box)"),
    ShortcutRow(group: sgTables, gesture: gsKey, id: "tables.page",
      keys: "Page Down / Page Up", what: "A page of rows on or back"),
    ShortcutRow(group: sgTables, gesture: gsKey, id: "tables.ends",
      keys: "Home / End", what: "The first or last row"),
    ShortcutRow(group: sgTables, gesture: gsKey, id: "tables.tab",
      keys: "Tab / Shift+Tab", what: "The next or previous control of the window",
      covers: "Tab"),
    ShortcutRow(group: sgTables, gesture: gsKey, id: "tables.activate",
      keys: "Enter / Space", what: "Act on the control Tab reached"),
    ShortcutRow(group: sgTables, gesture: gsKey, id: "tables.copy",
      keys: "Ctrl+C", what: "Copy the header value, or the row, that has the focus",
      covers: "C", chord: "Ctrl+C"),
    ShortcutRow(group: sgTables, gesture: gsKey, id: "references.delete",
      keys: "Delete", what: "Delete the selected reference in the Reference archive (it asks first)",
      covers: "Delete", chord: "Delete"),
    ShortcutRow(group: sgTables, gesture: gsKey, id: "references.rename",
      keys: "F2", what: "Rename the selected reference in the Reference archive",
      covers: "F2", chord: "F2"),
    ShortcutRow(group: sgTables, gesture: gsMouse, id: "tables.click",
      keys: "Click a row",
      what: "Show that file or record (when the window already had the focus)"),
    ShortcutRow(group: sgTables, gesture: gsMouse, id: "tables.double",
      keys: "Double-click a header row", what: "Show that trace's record in the plot"),
    ShortcutRow(group: sgTables, gesture: gsMouse, id: "tables.shiftClick",
      keys: "Shift + click a header row", what: "Select the traces from the row clicked last"),
    ShortcutRow(group: sgTables, gesture: gsMouse, id: "tables.ctrlClick",
      keys: "Ctrl + click a header row", what: "Add that trace to the selection, or take it out"),
    ShortcutRow(group: sgTables, gesture: gsMouse, id: "tables.rowMenu",
      keys: "Right-click a header row", what: "Copy the row, or the rows read"),
    ShortcutRow(group: sgWindows, gesture: gsKey, id: "windows.close",
      keys: "Escape",
      what: "Close a dialog, or this list",
      covers: "Escape", chord: "Escape"),
    ShortcutRow(group: sgWindows, gesture: gsKey, id: "windows.confirm",
      keys: "Enter", what: "Confirm the dialog (Reopen, Save layout)",
      covers: "Enter", chord: "Enter"),
    ShortcutRow(group: sgWindows, gesture: gsMouse, id: "windows.dock",
      keys: "Drag a window's title bar", what: "Dock it onto another window"),
    ShortcutRow(group: sgWindows, gesture: gsMouse, id: "windows.readout",
      keys: "Right-click the status bar", what: "Choose what the status bar reads out"),
    ShortcutRow(group: sgWindows, gesture: gsMouse, id: "windows.notice",
      keys: "Click a notice", what: "Show the Jobs window"),
    ShortcutRow(group: sgWindows, gesture: gsMouse, id: "windows.tray",
      keys: "Click the tray icon",
      what: "Its menu: Show viewSEG, Open file, Quit")]

func keySuffix(expr: string): string =
  ## The `ImGui_Key_` name in `expr` (`O`, `LeftArrow`); "" when there is none.
  const prefix = "ImGui_Key_"
  let at = expr.find(prefix)
  if at >= 0:
    var j = at + prefix.len
    while j < expr.len and expr[j] in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}: inc j
    result = expr[at + prefix.len ..< j]

func shownKey(name: string): string =
  ## `name` (an `ImGui_Key_` suffix) as the user reads it.
  case name
  of "LeftArrow": "Left"
  of "RightArrow": "Right"
  of "UpArrow": "Up"
  of "DownArrow": "Down"
  of "PageDown": "Page Down"
  of "PageUp": "Page Up"
  of "Equal": "+"
  of "Minus": "-"
  of "KeypadAdd": "Keypad +"
  of "KeypadSubtract": "Keypad -"
  of "KeypadMultiply": "Keypad *"
  of "KeypadDivide": "Keypad /"
  of "Keypad0": "Keypad 0"
  of "LeftBracket": "["
  of "RightBracket": "]"
  of "": ""
  else: name

func formatChord(expr: string): string =
  ## "Ctrl+Shift+O" from an action-table expression; "" when it names no key.
  let key = shownKey(keySuffix(expr))
  if key.len == 0: return
  var parts: seq[string] = @[]
  if "ImGui_Mod_Ctrl" in expr: parts.add "Ctrl"
  if "ImGui_Mod_Shift" in expr: parts.add "Shift"
  if "ImGui_Mod_Alt" in expr: parts.add "Alt"
  parts.add key
  parts.join("+")

func arrayBody(text: string): string =
  ## The `shortcuts` array's text, brackets included; "" when it is not there.
  let start = text.find("shortcuts: array[MenuAction")
  if start < 0: return
  let eq = text.find("= [", start)
  if eq < 0: return
  let open = eq + "= ".len # the array literal's '['
  var depth = 0
  for i in open ..< text.len:
    if text[i] == '[': inc depth
    elif text[i] == ']':
      dec depth
      if depth == 0: return text[open .. i]

func described(name: string): (string, ShortcutGroup, string) =
  ## The label, group and words of menu action `name` (`maOpenFile`); the
  ## label is "" when this list has no words for it.
  for (n, label, group, what) in menuDescribed:
    if n == name: return (label, group, what)

proc menuRowsFrom*(text: string): seq[ShortcutRow] =
  ## The rows of the menu's action table in `text`: each action with a
  ## chord, named as on Linux (the window substitutes the platform's names).
  ## Ctrl+Y, Redo's other binding, is appended to Redo's row.
  let body = arrayBody(text)
  for raw in body.splitLines:
    let s = raw.strip(chars = {' ', '\t', ','})
    if not s.startsWith("ma") or ':' notin s: continue
    let colon = s.find(':')
    let name = s[0 ..< colon].strip
    let expr = s[colon + 1 .. ^1]
    if expr.strip.startsWith("0"): continue
    let keys = formatChord(expr)
    if keys.len == 0: continue
    let (label, group, what) = described(name)
    result.add ShortcutRow(group: group, keys: keys, what: what, gesture: gsKey,
      id: "menu." & name, covers: keySuffix(expr), menu: label)
  let yAt = text.find("ImGui_Key_Y")
  if yAt >= 0:
    var lineStart = yAt
    while lineStart > 0 and text[lineStart - 1] != '\n': dec lineStart
    var lineEnd = yAt
    while lineEnd < text.len and text[lineEnd] != '\n': inc lineEnd
    let extra = formatChord(text[lineStart ..< lineEnd])
    if extra.len > 0:
      for i, r in result.mpairs:
        if r.id == "menu.maRedo" and extra notin r.keys:
          r.keys.add ", " & extra
          r.covers.add " Y"

proc undescribedMenus*(text: string): seq[string] =
  ## Menu actions with a chord and no words in this module.
  for r in menuRowsFrom(text):
    if r.menu.len == 0: result.add r.id

proc shortcutRows*(): seq[ShortcutRow] =
  ## The whole list: menu shortcuts generated from the action table, then
  ## the other keys, then the mouse gestures, each group in its order.
  result = menuRowsFrom(menusSource)
  result.add gestures

func chordOf*(id: string): string =
  ## The chord token of row `id` (`"F"`, `"Ctrl+G"`); "" when it has none
  ## or there is no such row.
  for r in shortcutRows():
    if r.id == id: return r.chord

func coveredKeys*(): seq[string] =
  ## Every toolkit key suffix some row accounts for, once, in order.
  for r in shortcutRows():
    for part in r.covers.splitWhitespace:
      if part.len > 0 and part notin result: result.add part

func sameKeys*(rows: openArray[ShortcutRow]): seq[string] =
  ## "group: keys" for a keys string two rows of one group both claim.
  for g in ShortcutGroup:
    var seen: seq[string] = @[]
    for r in rows:
      if r.group == g and r.keys.len > 0:
        if r.keys in seen and ($g & ": " & r.keys) notin result:
          result.add $g & ": " & r.keys
        else: seen.add r.keys

func matches*(row: ShortcutRow; filter: string): bool =
  ## Whether `filter` (a few letters, any case) occurs in the keys, the
  ## words or the group. An empty filter matches every row.
  let f = filter.strip.toLowerAscii
  if f.len == 0: return true
  f in row.keys.toLowerAscii or f in row.what.toLowerAscii or f in ($row.group).toLowerAscii

func filtered*(rows: openArray[ShortcutRow]; filter: string): seq[ShortcutRow] =
  for r in rows:
    if r.matches(filter): result.add r

func keyboardPage*(): string =
  ## The user-guide page, generated from the table.
  result = "# Keyboard shortcuts\n\n"
  result.add "Help > Keyboard shortcuts (F1) opens this list in the program. " &
    "The window shows the names this computer uses (Ctrl, or Cmd on macOS). " &
    "A box at the top narrows it: typing matches the keys and the words. " &
    "Escape closes the window.\n\n"
  result.add "Mouse gestures are listed after the keys of each group.\n\n"
  let rows = shortcutRows()
  for g in ShortcutGroup:
    var mine: seq[ShortcutRow] = @[]
    for r in rows:
      if r.group == g: mine.add r
    if mine.len == 0: continue
    result.add "## " & $g & "\n\n"
    result.add "| Keys | What it does |\n|---|---|\n"
    for r in mine:
      result.add "| " & r.keys & " | " & r.what & " |\n"
    result.add "\n"
