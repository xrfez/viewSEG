## The plot window of seismic traces is titled "Seismic" in the running
## frontend, headless, and keeps the ImGui ID `###plot` that saved layouts
## name: started on the `settings.nif` and `layout.nif` a build of 0.1.0
## wrote (`tests/data/saved-0.1.0`, when the window was "Plot"; its recent
## folder made the fixtures' folder), every window is docked where that
## layout puts it (each window's `DockId` in the arrangement Dear ImGui
## would save now is the one the file gives it), and
## nothing is said about either file (no warning, no error); then each
## preset in `assets/layouts/` is loaded and puts every window it names in
## its place too. A layout of the new build names the window as the old one
## did (`[Window][plot]`).
##
## Seen to fail: with the window's ID taken from its title (`"  Seismic"`,
## no `###plot`), no window `###plot` was found ("the window is titled ");
## with the title a fixed "Plot", "the window is titled   Plot###plot".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[options, os, strutils, tables]
import viewSEG/core/state
import viewSEG/ui/imgui/[app, icons]
import utils/fixtures

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

const windows = ["plot", "files", "records", "headers", "jobs", "Messages"]

proc inPlace(now, wanted: string; what: string) =
  ## Every window `wanted` docks is docked so in `now`.
  let (a, b) = (dockIds(now), dockIds(wanted))
  for w in windows:
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
  var wait = 0
  var loads = 0
  var presets: seq[SavedLayout]
  var checked: seq[string]
  proc onFrame(f: FrameInfo) =
    inc wait
    case stage
    of 0:
      if wait == 10:
        doAssert f.windowName("plot") == IconPlot & "  Seismic###plot",
          "the window is titled " & f.windowName("plot")
        doAssert f.markOf("seismic").size.x > 0, "no window marked seismic"
        inPlace(f.layoutText, old, "the layout saved by 0.1.0")
        checked.add "saved"
        for e in f.core.log:
          doAssert e.severity == sevInfo, "said at start: " & e.text
        for l in f.core.layouts:
          if l.preset: presets.add l
        doAssert presets.len >= 2, "the presets are not listed"
        (stage, wait) = (1, 0)
    of 1: # load the next preset
      if checked.len - 1 == presets.len:
        f.stop()
        stage = 3
      else:
        loads = f.core.layoutLoads
        f.apply Command(kind: ckLoadLayout, docPath: presets[checked.len - 1].path)
        (stage, wait) = (2, 0)
    of 2:
      if f.core.layoutLoads > loads and wait > 6:
        let l = presets[checked.len - 1]
        inPlace(f.layoutText, readLayout(readFile(l.path), l.path, problems).imgui,
          "the preset " & l.name)
        doAssert f.windowName("plot") == IconPlot & "  Seismic###plot"
        checked.add l.name
        (stage, wait) = (1, 0)
      doAssert wait < 200, "the preset did not load"
    else: discard
  doAssert run(RunOptions(maxFrames: 1000, persist: true, configDir: some(config),
    logDir: some(fx.dir / "logs"), indexCacheDir: some(fx.dir / "cache"),
    assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]),
    userThemeDir: some(fx.dir / "no-user-themes"), onFrame: onFrame)) == 0
  doAssert stage == 3, "stopped at stage " & $stage & " after " & $checked
  doAssert "Wide plot" in checked and "Side by side" in checked, $checked
  # what this build saves at exit names the window as before
  let now = readLayout(readFile(config / LayoutFileName), LayoutFileName, problems).imgui
  doAssert "[Window][plot]" in now and "Seismic" notin now, now
  echo "tguititles: in place: ", checked.join(", ")
