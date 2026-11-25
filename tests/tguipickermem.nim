## Every file and folder picker opens where it was last used, in the running
## frontend, headless, driven by real clicks on the menu bar with the system's file
## dialogs answered by the test (`RunOptions.dialogs`, which also sees where each
## dialog was asked to start). A first run answers three pickers from three
## different folders (File > Open folder, Tools > Import settings, Window > Import
## layout); a second run, started from the settings the first one saved, asks the
## same three and cancels them: each starts in its own folder, none in another's. A
## cancelled dialog remembers nothing (a third run finds the pickers where they were).
##
## Seen to fail: with the answer not remembered (`ckRememberPlace` ignored), "Open
## folder started at <the folder opened first>"; with every picker sharing one
## remembered folder, "Import settings started in the wrong folder"; with the table
## not kept in the settings file, the second run's pickers started at ''.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, settings, settingsnif, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

  Ask = object
    kind: DialogKind
    menu, item: string
    answer: seq[string]

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc session(fx: Fixtures; path: string; asks: seq[Ask]): seq[string] =
  ## One run of the frontend on the settings of `fx.dir / "config"`: each of `asks`
  ## from its menu, answered as it says; where each dialog was asked to start.
  var wait = 0
  var since = getMonoTime()
  var asked: seq[(DialogKind, string)]
  var answer: seq[string]
  var starts: seq[string]
  let hook = proc (kind: DialogKind; location: string): seq[string] =
    asked.add (kind, location)
    answer
  var steps: seq[Step]
  proc noop(f: FrameInfo) = discard
  steps.add Step(name: "the file is shown", act: noop, done: proc (f: FrameInfo): bool =
    f.core.panels[f.core.findPanel(MainPanel)].laidOut and f.layoutText.len > 0)
  proc askStep(a: Ask): Step =
    ## The step asking `a`; a proc of its own, so each step keeps its own `a`.
    Step(name: a.menu & " > " & a.item, act: proc (f: FrameInfo) =
      asked.setLen 0
      answer = a.answer
      f.click(f.markOf("menu." & a.menu).centre), done: proc (f: FrameInfo): bool =
      let it = f.markOf("menu." & a.item)
      if it.size.x > 0 and wait mod 5 == 0: f.click(it.centre)
      if asked.len > 0:
        doAssert asked[0][0] == a.kind, a.item & " asked for " & $asked
        starts.add $asked[0][0] & " started at '" & asked[0][1] & "'"
        true
      else: false)
  for a in asks: steps.add askStep(a)
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
    theme: forceDark, persist: true, configDir: some(fx.dir / "config"),
    logDir: some(fx.dir / "logs"), indexCacheDir: some(fx.dir / "cache"),
    userThemeDir: some(fx.dir / "no-user-themes"),
    assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]), dialogs: hook,
    onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  result = starts

proc main*() =
  withFixtures fx:
    let path = fx.surveySegy()
    for d in ["config", "folderA", "folderB", "folderC"]: createDir(fx.dir / d)
    let
      folderA = fx.dir / "folderA"
      folderB = fx.dir / "folderB"
      folderC = fx.dir / "folderC"
    writeFile(folderB / "theirs.nif", settingsDocument(Settings()))
    copyFile(currentSourcePath().parentDir.parentDir / "assets" / "layouts" / "Wide plot.nif",
      folderC / "Theirs.nif")
    let cancel = newSeq[string]()
    proc pickers(answers: array[3, seq[string]]): seq[Ask] =
      @[Ask(kind: dkOpenFolder, menu: "File", item: "Open folder...", answer: answers[0]),
        Ask(kind: dkImportSettings, menu: "Tools", item: "Import settings...",
          answer: answers[1]),
        Ask(kind: dkImportLayout, menu: "Window", item: "Import layout...",
          answer: answers[2])]
    let first = session(fx, path, pickers([@[folderA], @[folderB / "theirs.nif"],
      @[folderC / "Theirs.nif"]]))
    doAssert first[1] == "Import settings started at ''", first[1]
    doAssert first[2] == "Import layout started at ''", first[2]
    let second = session(fx, path, pickers([cancel, cancel, cancel]))
    doAssert second[0] == "Open folder started at '" & folderA & DirSep & "'", second[0]
    doAssert second[1] == "Import settings started at '" & folderB & DirSep & "'",
      "Import settings started in the wrong folder: " & second[1]
    doAssert second[2] == "Import layout started at '" & folderC & DirSep & "'", second[2]
    # the cancels of the second run changed nothing
    let third = session(fx, path, pickers([cancel, cancel, cancel]))
    doAssert third == second, $third
    echo "tguipickermem: ok"

when isMainModule:
  main()
