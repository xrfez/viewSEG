## The imports and exports in their menus (Tools, Window, Project) in the
## running frontend, headless, driven by real clicks on the menu bar, with the
## settings in a folder of the test's own and the system's file dialogs
## answered by the test (`RunOptions.dialogs`): each entry asks for the dialog
## the old entry asked for and does what it did.
##
## - Tools > Import settings...: the settings of a file are taken in (the
##   cursor line on);
## - Tools > Export settings...: the settings are written to the file chosen;
## - Window > Export layout...: the arrangement is written to the file chosen;
## - Window > Import layout...: a layout file arranges the windows and is kept
##   among the user's layouts (Window > Load);
## - Tools > Export messages...: the messages are written to the file chosen;
## - Project > Import survey...: the survey's window opens;
## - Tools > Reset the settings: back to the defaults (the cursor line off);
## - the old places are gone: File has no Import or Export submenu and none of
##   their items.
##
## Seen to fail: with Import settings... asking for the layout's dialog,
## "Tools > Import settings... asked for @[Import layout]"; with Export
## messages... left out of Tools, "Tools > Export messages... did not happen".
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

proc main*() =

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

    proc fileMenu(menu, item: string; chosen: seq[string]; wanted: DialogKind;
        then: proc (f: FrameInfo): bool) =
      ## Steps: the menu `menu`, then a click on its item `item`, the dialog
      ## answered with `chosen`; the dialog asked for must be `wanted`.
      step(menu & " > " & item, proc (f: FrameInfo) =
        asked.setLen 0
        answer = chosen
        f.click(f.markOf("menu." & menu).centre), proc (f: FrameInfo): bool =
        let it = f.markOf("menu." & item)
        if it.size.x > 0 and wait mod 5 == 0: f.click(it.centre)
        asked.len > 0)
      let check = proc (f: FrameInfo) =
        doAssert asked == @[wanted], menu & " > " & item & " asked for " & $asked
      step(item & " does what it did", check, then)

    step("the file is shown", noop, proc (f: FrameInfo): bool =
      f.core.panels[f.core.findPanel(MainPanel)].laidOut and f.layoutText.len > 0)
    # -------------------------------------------------------- settings --
    var theirs = Settings()
    theirs.cursorLine = true
    writeFile(outDir / "theirs.nif", settingsDocument(theirs))
    fileMenu("Tools", "Import settings...", @[outDir / "theirs.nif"], dkImportSettings,
      proc (f: FrameInfo): bool = f.core.settings.cursorLine)
    fileMenu("Tools", "Export settings...", @[outDir / "mine.nif"], dkExportSettings,
      proc (f: FrameInfo): bool =
      fileExists(outDir / "mine.nif") and "(cursorLine true)" in readFile(outDir / "mine.nif"))
    # --------------------------------------------------------- layouts --
    fileMenu("Window", "Export layout...", @[outDir / "arranged.nif"], dkExportLayout,
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
    fileMenu("Window", "Import layout...", @[outDir / "Theirs.nif"], dkImportLayout,
      proc (f: FrameInfo): bool =
      result = f.core.layoutLoads > loads
      if result:
        var kept = false
        for l in f.core.layouts:
          if not l.preset and l.name == "Wide plot": kept = true
        result = kept)
    # -------------------------------------------------------- messages --
    fileMenu("Tools", "Export messages...", @[outDir / "messages.log"], dkExportLog,
      proc (f: FrameInfo): bool =
      fileExists(outDir / "messages.log") and "Session log:" in readFile(outDir / "messages.log"))
    # ---------------------------------------------------------- survey --
    step("Project > Import survey...", proc (f: FrameInfo) =
      f.click(f.markOf("menu.Project").centre), proc (f: FrameInfo): bool =
      let it = f.markOf("menu.Import survey...")
      if it.size.x > 0 and wait mod 5 == 0: f.click(it.centre)
      f.joinWindow.shown)
    # ------------------------------------------------- reset, old places --
    step("Tools > Reset the settings", proc (f: FrameInfo) =
      f.click(f.markOf("menu.Tools").centre), proc (f: FrameInfo): bool =
      let it = f.markOf("menu.Reset the settings")
      if it.size.x > 0 and wait mod 5 == 0: f.click(it.centre)
      not f.core.settings.cursorLine)
    step("File has no import, export or settings", proc (f: FrameInfo) =
      f.click(f.markOf("menu.File").centre), proc (f: FrameInfo): bool =
      result = f.markOf("menu.Quit").size.x > 0
      if result:
        for old in ["menu.Import", "menu.Export", "menu.Settings...", "menu.Import settings...",
            "menu.Export settings...", "menu.Reset the settings", "menu.Export messages...",
            "menu.Import survey..."]:
          doAssert f.markOf(old).size.x == 0, "File still has " & old)

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

when isMainModule:
  main()
