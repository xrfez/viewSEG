## File > Import and File > Export in the running frontend, headless, driven
## by real clicks on the menu bar, with the settings in a folder of the
## test's own and the system's file dialogs answered by the test
## (`RunOptions.dialogs`): each entry asks for the dialog the old entry
## asked for and does what it did.
##
## - Import > Settings...: the settings of a file are taken in (the cursor
##   line on);
## - Export > Settings...: the settings are written to the file chosen;
## - Export > Layout...: the arrangement is written to the file chosen;
## - Import > Layout...: a layout file arranges the windows and is kept among
##   the user's layouts (Window > Load);
## - Export > Messages...: the messages are written to the file chosen;
## - Import > Survey...: the survey's window opens;
## - Reset the settings: back to the defaults (the cursor line off);
## - the old places are gone: no Settings submenu in File, no layout export
##   or import under Window.
##
## Seen to fail: with Import > Settings... asking for the layout's dialog,
## "Import > Import settings... asked for @[Import layout]"; with Export >
## Messages... left out of the submenu, "File > Export > Export messages...
## did not happen" (items are marked by their names outside the submenus).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, layouts, settings, settingsnif, state]
import viewSEG/ui/imgui/app
import viewSEG/view/theme
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

var wait = 0 ## frames since the step began, at `since`
var since = getMonoTime()

withFixtures fx:
  let path = fx.surveySegy()
  let config = fx.dir / "config"
  let outDir = fx.dir / "out"
  createDir(config)
  createDir(outDir)
  var asked: seq[DialogKind]
  var answer: seq[string]
  let hook = proc (kind: DialogKind; location: string): seq[string] =
    asked.add kind
    answer
  var steps: seq[Step]
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard

  proc fileMenu(sub, item: string; chosen: seq[string]; wanted: DialogKind;
      then: proc (f: FrameInfo): bool) =
    ## Steps: File, then the submenu `sub` (by the pointer over it; "" for
    ## none), then a click on its item `item`, the dialog answered with
    ## `chosen`; the dialog asked for must be `wanted`.
    step("File > " & sub & " > " & item, proc (f: FrameInfo) =
      asked.setLen 0
      answer = chosen
      f.click(f.markOf("menu.File").centre), proc (f: FrameInfo): bool =
      let it = f.markOf("menu." & item)
      if it.size.x > 0 and wait mod 5 == 0: f.click(it.centre)
      elif sub.len > 0 and f.markOf("menu." & sub).size.x > 0 and wait mod 10 == 0:
        f.click(f.markOf("menu." & sub).centre)
      asked.len > 0)
    let check = proc (f: FrameInfo) =
      doAssert asked == @[wanted], sub & " > " & item & " asked for " & $asked
    step(item & " does what it did", check, then)

  step("the file is shown", noop, proc (f: FrameInfo): bool =
    f.core.panels[f.core.findPanel(MainPanel)].laidOut and f.layoutText.len > 0)
  # -------------------------------------------------------- settings --
  var theirs = Settings()
  theirs.cursorLine = true
  writeFile(outDir / "theirs.nif", settingsDocument(theirs))
  fileMenu("Import", "Import settings...", @[outDir / "theirs.nif"], dkImportSettings,
    proc (f: FrameInfo): bool = f.core.settings.cursorLine)
  fileMenu("Export", "Export settings...", @[outDir / "mine.nif"], dkExportSettings,
    proc (f: FrameInfo): bool =
    fileExists(outDir / "mine.nif") and "(cursorLine true)" in readFile(outDir / "mine.nif"))
  # --------------------------------------------------------- layouts --
  fileMenu("Export", "Export layout...", @[outDir / "arranged.nif"], dkExportLayout,
    proc (f: FrameInfo): bool =
    result = fileExists(outDir / "arranged.nif")
    if result:
      var problems: seq[string]
      let l = readLayout(readFile(outDir / "arranged.nif"), "arranged.nif", problems)
      doAssert "[Window][plot]" in l.imgui, l.imgui)
  var loads = 0
  step("the layouts before", noop, proc (f: FrameInfo): bool =
    loads = f.core.layoutLoads
    true)
  let preset = currentSourcePath().parentDir.parentDir / "assets" / "layouts" / "Wide plot.nif"
  copyFile(preset, outDir / "Theirs.nif")
  fileMenu("Import", "Import layout...", @[outDir / "Theirs.nif"], dkImportLayout,
    proc (f: FrameInfo): bool =
    result = f.core.layoutLoads > loads
    if result:
      var kept = false
      for l in f.core.layouts:
        if not l.preset and l.name == "Wide plot": kept = true
      result = kept)
  # -------------------------------------------------------- messages --
  fileMenu("Export", "Export messages...", @[outDir / "messages.log"], dkExportLog,
    proc (f: FrameInfo): bool =
    fileExists(outDir / "messages.log") and "Session log:" in readFile(outDir / "messages.log"))
  # ---------------------------------------------------------- survey --
  step("File > Import > Survey...", proc (f: FrameInfo) =
    f.click(f.markOf("menu.File").centre), proc (f: FrameInfo): bool =
    let it = f.markOf("menu.Import survey...")
    if it.size.x > 0 and wait mod 5 == 0: f.click(it.centre)
    elif f.markOf("menu.Import").size.x > 0 and wait mod 10 == 0:
      f.click(f.markOf("menu.Import").centre)
    f.joinWindow.shown)
  # ------------------------------------------------- reset, old places --
  step("File > Reset the settings", proc (f: FrameInfo) =
    f.click(f.markOf("menu.File").centre), proc (f: FrameInfo): bool =
    let it = f.markOf("menu.Reset the settings")
    if it.size.x > 0 and wait mod 5 == 0:
      for old in ["menu.Settings", "menu.Export...", "menu.Import..."]:
        doAssert f.markOf(old).size.x == 0, "File still has " & old
      f.click(it.centre)
    not f.core.settings.cursorLine)
  step("Window has no layout export or import", proc (f: FrameInfo) =
    f.click(f.markOf("menu.Window").centre), proc (f: FrameInfo): bool =
    result = f.markOf("menu.Reset the windows").size.x > 0
    if result:
      for old in ["menu.Export layout...", "menu.Import layout..."]:
        doAssert f.markOf(old).size.x == 0, "Window still has " & old
      doAssert f.markOf("menu.Save layout as...").size.x > 0)

  var at = 0
  var started = false
  var failed = ""
  proc onFrame(f: FrameInfo) =
    if at >= steps.len or failed.len > 0:
      f.stop()
      return
    if not started:
      steps[at].act(f)
      started = true
      wait = 0
      since = getMonoTime()
    else:
      inc wait
      if wait >= 3 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 400, since):
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(openPaths: @[path], windowSize: (1400, 900),
    theme: forceDark, persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
    indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
    assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]), dialogs: hook,
    onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  echo "tguiimportexport: ", steps.len, " steps"
