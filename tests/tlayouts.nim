## Window layouts: a layout survives a round trip, its text byte for byte;
## a document that is not a layout raises `NifError`; layout names that no
## system can hold are refused; the user's layouts are listed before the
## presets and hide a preset of their name; a damaged `layout.nif` is moved
## aside with a message, and one with thousands of unused nodes says the
## first and counts the rest; every shipped preset reads. `AppState` saves
## the arrangement a moment after it changes and at shutdown, saves it under
## a name, loads, exports and imports layouts, and says what failed.
##
## Seen to fail: with `layoutDocument` not writing `(name ...)`, `roundTrip`
## lost the name; with `added` keeping the entries of the new one's name,
## `listing` still listed the preset of that name; with `ckLayout` not
## noting the change, `lastExit` found no `layout.nif`; with every problem
## of a layout or an imported settings file said, `thousandsOfProblems` got
## 5 000 notes at start, and 5 001 lines logged by a load.

import std/[os, strutils]
import viewSEG/core/state
import utils/waiting

let tmp = getTempDir() / ("viewseg_tlayouts_" & $getCurrentProcessId())
removeDir(tmp)
createDir(tmp)

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func has(log: MessageLog; part: string; severity = sevInfo): bool =
  for e in log:
    if part in e.text and e.severity == severity: return true
  false

const ini = "[Window][###plot]\nPos=8,64\nSize=800,500\nCollapsed=0\nDockId=0x00000003,0\n\n" &
  "[Window][Headers (example)###headers]\nPos=820,64\n\n[Docking][Data]\n" &
  "DockSpace   ID=0x8B93E3BD Window=0xA787BDB4 Pos=0,47 Size=1280,729 Split=X\n" &
  "  DockNode  ID=0x00000001 Parent=0x8B93E3BD SizeRef=817,729 Split=Y\n"

block roundTrip:
  let l = Layout(name: "Wide plot", imgui: ini & "odd: \"quotes\" \\ (parens) é\r\n\t\x01")
  var problems: seq[string]
  let back = readLayout(layoutDocument(l), "x.nif", problems)
  doAssert problems.len == 0, $problems
  doAssert back == l
  doAssert "[Window]" notin layoutDocument(l), "brackets are escaped"
  doAssert "Pos=8,64\n" in layoutDocument(l), "line breaks stay"
  let crlf = layoutDocument(l).replace("\n", "\r\n")
  doAssert readLayout(crlf, "x.nif", problems).name == "Wide plot"
  for bad in ["", "(layout (name \"x\"))", "(settings (version 1))", "(layout (imgui 5))",
      "(layout (imgui \"a\"", "garbage"]:
    try:
      discard readLayout(bad, "x.nif", problems)
      doAssert false, "read " & bad
    except NifError:
      discard
  problems.setLen 0
  discard readLayout("(layout (version 9) (imgui \"a\") (colour red))", "x.nif", problems)
  doAssert problems.len == 2 and "(colour" in problems[0] and "newer viewSEG" in problems[1],
    $problems

block names:
  for good in ["Mine", "Wide plot", "QC – night shift", "a.b"]:
    doAssert layoutNameProblem(good) == "", good
  for bad in ["", "  ", "a/b", "a\\b", "c:d", "x?", "CON", "nul.txt", ".hidden", "end.",
      repeat("x", MaxLayoutName + 1), "tab\there"]:
    doAssert layoutNameProblem(bad).len > 0, bad
  doAssert layoutPath("/c", " Mine ") == "/c" / LayoutsDirName / "Mine.nif"

block listing:
  let cfg = tmp / "cfg"
  let assets = tmp / "assets"
  createDir(cfg / LayoutsDirName)
  createDir(assets / LayoutsDirName)
  for n in ["b", "A", "Shared"]: writeFile(cfg / LayoutsDirName / (n & ".nif"), "")
  for n in ["shared", "Preset"]: writeFile(assets / LayoutsDirName / (n & ".nif"), "")
  writeFile(cfg / LayoutsDirName / "notes.txt", "")
  let list = listLayouts(cfg, [assets, tmp / "missing"])
  var names: seq[string]
  for e in list: names.add e.name & (if e.preset: "*" else: "")
  doAssert names == @["A", "b", "Shared", "Preset*"], $names
  let more = list.added(SavedLayout(name: "preset", path: "/p"))
  names.setLen 0
  for e in more: names.add e.name & (if e.preset: "*" else: "")
  doAssert names == @["A", "b", "preset", "Shared"], $names

block damagedLastLayout:
  let dir = tmp / "damaged"
  createDir(dir)
  writeFile(dir / LayoutFileName, "(layout (imgui \"[Window")
  let got = loadLayoutFile(dir / LayoutFileName)
  doAssert not got.found and not fileExists(dir / LayoutFileName)
  doAssert got.notes.len == 1 and "moved to" in got.notes[0].text, $got.notes
  doAssert not loadLayoutFile(dir / "none.nif").found

proc appIn(dir: string; presets: openArray[string] = []): AppState =
  result = initAppState()
  result.keepSettingsIn(dir, loadSettings(dir / SettingsFileName))
  result.keepLayoutsIn(dir, presets)

block lastExit:
  let dir = tmp / "app1"
  var st = appIn(dir)
  st.apply Command(kind: ckLayout, arrangement: ini)
  st.shutdown()
  let got = loadLayoutFile(dir / LayoutFileName)
  doAssert got.found and got.layout.imgui == ini

block saveAs:
  let dir = tmp / "app2"
  var st = appIn(dir)
  st.apply Command(kind: ckSaveLayout, layoutName: "Mine")
  doAssert st.log.has("the window layout is not known yet", sevWarning)
  st.apply Command(kind: ckLayout, arrangement: ini)
  st.apply Command(kind: ckSaveLayout, layoutName: "a/b")
  doAssert st.log.has("cannot hold", sevWarning)
  st.apply Command(kind: ckSaveLayout, layoutName: " Mine ")
  st.apply Command(kind: ckLayout, arrangement: ini & "\n; second")
  st.apply Command(kind: ckSaveLayout, layoutName: "Mine")
  st.flushFiles()
  doAssert st.settle(st.log.has("Layout \"Mine\" saved in "))
  doAssert st.layouts.len == 1 and st.layouts[0].name == "Mine", $st.layouts
  var problems: seq[string]
  let saved = readLayout(readFile(layoutPath(dir, "Mine")), "Mine.nif", problems)
  doAssert saved.name == "Mine" and saved.imgui == ini & "\n; second"
  # Load it: the frontend sees a new load.
  let loads = st.layoutLoads
  st.apply Command(kind: ckLoadLayout, docPath: layoutPath(dir, "Mine"))
  doAssert st.settle(st.layoutLoads == loads + 1)
  doAssert st.loadedLayout.imgui == ini & "\n; second" and st.loadedLayout.name == "Mine"
  doAssert st.log.has("Layout \"Mine\" loaded.")
  # Export, then import under the same name: kept as "Mine 2".
  let exported = tmp / "out" / "Mine.nif"
  st.apply Command(kind: ckExportLayout, docPath: exported)
  st.flushFiles()
  doAssert st.settle(st.log.has("Layout exported to " & exported & "."))
  st.apply Command(kind: ckImportLayout, docPath: exported)
  doAssert st.settle(st.layoutLoads == loads + 2)
  st.flushFiles()
  doAssert fileExists(layoutPath(dir, "Mine 2"))
  doAssert st.layouts.len == 2 and st.layouts[1].name == "Mine 2", $st.layouts
  # Failures are said, and change nothing.
  st.apply Command(kind: ckLoadLayout, docPath: tmp / "missing.nif")
  doAssert st.settle(st.log.has("Cannot load the layout in " & tmp / "missing.nif", sevError))
  writeFile(tmp / "bad.nif", "(layout")
  st.apply Command(kind: ckLoadLayout, docPath: tmp / "bad.nif")
  doAssert st.settle(st.log.has("Cannot load the layout: ", sevError))
  doAssert st.layoutLoads == loads + 2
  st.shutdown()

block thousandsOfProblems:
  # A layout file can hold thousands of nodes this version does not use:
  # the first ones are said one by one, the rest counted, at start and at
  # an import alike.
  let dir = tmp / "noisy"
  createDir(dir)
  let text = "(layout (imgui \"[Window][x]\n\")" & repeat(" (gadget 1)", 5000) & ")"
  writeFile(dir / LayoutFileName, text)
  let got = loadLayoutFile(dir / LayoutFileName)
  doAssert got.found
  doAssert got.notes.len == MaxProblemLines + 1, $got.notes.len & " notes"
  doAssert "4980 more problems" in got.notes[^1].text, got.notes[^1].text
  var st = appIn(tmp / "noisyApp")
  let before = st.log.len
  st.apply Command(kind: ckLoadLayout, docPath: dir / LayoutFileName)
  doAssert st.settle(st.log.has("loaded."))
  doAssert st.log.len - before <= MaxProblemLines + 2, $(st.log.len - before) & " lines logged"
  writeFile(dir / "noisy settings.nif", "(settings (version 1)" & repeat(" (gadget 1)", 5000) &
    ")")
  st.apply Command(kind: ckImportSettings, docPath: dir / "noisy settings.nif")
  doAssert st.settle(st.log.has("Settings imported from"))
  doAssert st.log.len - before <= 2 * (MaxProblemLines + 2), $(st.log.len - before) &
    " lines logged"
  st.shutdown()

block notKept:
  var st = initAppState() # no folder: layouts are not saved
  st.apply Command(kind: ckLayout, arrangement: ini)
  st.apply Command(kind: ckSaveLayout, layoutName: "Mine")
  doAssert st.log.has("layouts are not kept in this run", sevWarning)
  st.shutdown()

block shippedPresets:
  # Every preset that ships reads, and arranges the dockspace (the frontend
  # builds the default arrangement when a layout holds none).
  let dir = currentSourcePath().parentDir.parentDir / "assets"
  var names: seq[string]
  for e in listLayouts("", [dir]):
    doAssert e.preset
    var problems: seq[string]
    let l = readLayout(readFile(e.path), e.path, problems)
    doAssert problems.len == 0, $problems
    doAssert l.name == e.name, l.name & " in " & e.path
    doAssert "[Docking][Data]" in l.imgui and "DockSpace" in l.imgui, e.path
    for id in ["[Window][plot]", "[Window][headers]", "[Window][Messages]",
        "[Window][files]", "[Window][records]", "[Window][jobs]", "[Window][map]"]:
      doAssert id in l.imgui, id & " not in " & e.path
    names.add e.name
  doAssert names == @["Plot and map", "Side by side", "Wide plot"], $names

removeDir(tmp)
