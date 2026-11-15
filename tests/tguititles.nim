## The plot window of seismic traces is titled "Seismic" in the running
## frontend, headless, and keeps the ImGui ID `###plot` that saved layouts
## name: started on the `settings.nif` and `layout.nif` a build of 0.1.0
## wrote (`tests/data/saved-0.1.0`, when the window was "Plot"; its recent
## folder made the fixtures' folder), every window is docked where that
## layout puts it (each window's `DockId` in the arrangement Dear ImGui
## would save now is the one the file gives it), and
## nothing is said about either file (no warning, no error); the map, which
## that layout does not name, joins the Headers window's place; then each
## preset in `assets/layouts/` is loaded and puts every window it names, the
## map too, in its place. A layout of the new build names the window as the
## old one did (`[Window][plot]`).
##
## Seen to fail (the map): without the map docked where Headers is when a
## layout does not name it, "the map is not docked" (it floated).
##
## Seen to fail: with the window's ID taken from its title (`"  Seismic"`,
## no `###plot`), no window `###plot` was found ("the window is titled ");
## with the title a fixed "Plot", "the window is titled   Plot###plot".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[monotimes, options, os, strutils, tables]
import viewSEG/core/state
import viewSEG/ui/imgui/[app, icons]
import utils/[fixtures, waiting]

const saved = currentSourcePath().parentDir / "data" / "saved-0.1.0"

func dockIds(ini: string): Table[string, string] =
  ## Each window's DockId in Dear ImGui's layout text ("none" for a window
  ## that is not docked).
  var name = ""
  for line in ini.splitLines:
    if line.startsWith("[Window][") and line.endsWith("]"):
      name = line["[Window][".len .. ^2]
      result[name] = "none"
    elif line.startsWith("["):
      name = ""
    elif name.len > 0 and line.startsWith("DockId="):
      result[name] = line["DockId=".len .. ^1].split(',')[0]

const windows = ["plot", "files", "records", "headers", "jobs", "Messages", "map"]

proc inPlace(now, wanted: string; what: string; all = true) =
  ## Every window `wanted` docks is docked so in `now`; with `all`, it names
  ## every window.
  let (a, b) = (dockIds(now), dockIds(wanted))
  for w in windows:
    if w notin b and not all: continue
    doAssert w in b, what & " does not name " & w
    doAssert a.getOrDefault(w, "none") == b[w], what & ": " & w & ": DockId " &
      a.getOrDefault(w, "none") & ", the file says " & b[w]

withFixtures fx:
  let config = fx.dir / "config"
  createDir(config)
  discard fx.surveySegy() # the last folder listed: the fixtures', not the one 0.1.0 listed
  for f in [SettingsFileName, LayoutFileName]:
    writeFile(config / f, readFile(saved / f).replace("/workspaces/viewSEG/exampleFiles", fx.dir))
  var problems: seq[string]
  let old = readLayout(readFile(saved / LayoutFileName), LayoutFileName, problems).imgui
  doAssert problems.len == 0 and dockIds(old)["plot"] == "0x00000007", $problems
  var stage = 0
  var wait = 0 # frames since the stage began, at `since`
  var since = getMonoTime()
  var loads = 0
  var loadedAt = -1 # the frame of the stage the load was seen at
  var presets: seq[SavedLayout]
  var checked: seq[string]
  proc onFrame(f: FrameInfo) =
    inc wait
    template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
    case stage
    of 0:
      if wait == 10:
        doAssert f.windowName("plot") == IconPlot & "  Seismic###plot",
          "the window is titled " & f.windowName("plot")
        doAssert f.markOf("seismic").size.x > 0, "no window marked seismic"
        inPlace(f.layoutText, old, "the layout saved by 0.1.0", all = false)
        let ids = dockIds(f.layoutText)
        doAssert ids.getOrDefault("map", "none") != "none", "the map is not docked"
        doAssert ids["map"] == ids["headers"], "the map is not where Headers is: " & ids["map"] &
          ", " & ids["headers"]
        checked.add "saved"
        for e in f.core.log:
          doAssert e.severity == sevInfo, "said at start: " & e.text
      if wait >= 10: # the presets, listed by the disk thread
        presets = @[]
        for l in f.core.layouts:
          if l.preset: presets.add l
        if presets.len >= 2: next 1
        else: doAssert not overdue(wait, 200, since), "the presets are not listed"
    of 1: # load the next preset
      if checked.len - 1 == presets.len:
        f.stop()
        stage = 3
      else:
        loads = f.core.layoutLoads
        f.apply Command(kind: ckLoadLayout, docPath: presets[checked.len - 1].path)
        loadedAt = -1
        next 2
    of 2: # read by the disk thread, then arranged: checked a few frames later
      if f.core.layoutLoads > loads and loadedAt < 0: loadedAt = wait
      if loadedAt >= 0 and wait > loadedAt + 6:
        let l = presets[checked.len - 1]
        inPlace(f.layoutText, readLayout(readFile(l.path), l.path, problems).imgui,
          "the preset " & l.name)
        doAssert f.windowName("plot") == IconPlot & "  Seismic###plot"
        checked.add l.name
        next 1
      doAssert not overdue(wait, 200, since), "the preset did not load"
    else: discard
  doAssert run(RunOptions(persist: true, configDir: some(config),
    logDir: some(fx.dir / "logs"), indexCacheDir: some(fx.dir / "cache"),
    assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]),
    userThemeDir: some(fx.dir / "no-user-themes"), onFrame: onFrame)) == 0
  doAssert stage == 3, "stopped at stage " & $stage & " after " & $checked
  doAssert "Wide plot" in checked and "Side by side" in checked and "Plot and map" in checked,
    $checked
  # what this build saves at exit names the window as before
  let now = readLayout(readFile(config / LayoutFileName), LayoutFileName, problems).imgui
  doAssert "[Window][plot]" in now and "Seismic" notin now, now
  echo "tguititles: in place: ", checked.join(", ")
