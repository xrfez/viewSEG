## "Reopen with options" and Help > About in the running frontend, headless,
## with real clicks and keys.
##
## A SEG-Y file shown: File > Reopen with options... opens the dialog; a
## click names SEG-Y, another ticks "Check every trace header", Reopen opens
## the file again with them (the dialog closes, the file is shown again at
## the record it showed), and the Headers window's Summary says how it was
## opened. Its "Reopen with options..." button opens the dialog again, with
## the options the file has now; Defaults then Reopen opens it as at first.
## Escape closes the dialog and opens nothing. Help > About viewSEG lists
## viewSEG's, parseSEG's and processSEG's versions; Close closes it. The
## file is never changed.
##
## Seen to fail: with the dialog's Reopen giving no command (`result.add`
## taken out of `drawReopen`), "Reopen did not happen"; with File >
## Reopen with options... not acted on (`maReopen` doing nothing in
## `onActions`), "File > Reopen with options... did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves reopen-*.png and about.png there.

import std/[math, monotimes, options, os, times]
import viewSEG/core/[geometry, properties, state]
import viewSEG/ui/imgui/[app, reopendialog]
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

withFixtures fx:
  let path = fx.surveySegy()
  let name = path.extractFilename
  let before = (readFile(path), getLastModificationTime(path))
  var steps: seq[Step]
  var at = 0
  var started = false
  var wait = 0
  var since = getMonoTime()
  var failed = ""
  let shots = getEnv("VIEWSEG_SCREENSHOTS")
  if shots.len > 0: createDir(shots)

  template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

  proc shown(f: FrameInfo): Session =
    let i = f.core.shownFile(f.core.findPanel(MainPanel))
    if i >= 0: f.core.sessions[i] else: nil

  proc opens(f: FrameInfo): int =
    for j in f.core.jobs.list:
      if j.spec.title == "Open " & name: inc result

  proc shoot(f: FrameInfo; file: string) =
    if shots.len > 0: doAssert f.savePng(shots / file), "cannot save " & file

  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)

  proc noop(f: FrameInfo) = discard

  proc click(f: FrameInfo; q: Vec2) =
    f.pressMouse(q, true, 1)
    f.pressMouse(q, false, 1)

  proc clickOn(name, mark: string; done: proc (f: FrameInfo): bool) =
    step(name & ": point", proc (f: FrameInfo) = f.moveMouse(f.markOf(mark).centre),
      proc (f: FrameInfo): bool = wait > 2 and f.markOf(mark).size.x > 0)
    step(name, proc (f: FrameInfo) = f.click(f.markOf(mark).centre), done)

  proc menu(name, top, item: string; done: proc (f: FrameInfo): bool) =
    clickOn(name & ": " & top, "menu." & top, proc (f: FrameInfo): bool =
      f.markOf("menu." & item).size.x > 0)
    clickOn(name, "menu." & item, done)

  proc dialogOpen(f: FrameInfo): bool = f.markOf("reopen").size.x > 0 and wait > 3

  var opensBefore = 0
  step("shown", noop, proc (f: FrameInfo): bool =
    f.panel.laidOut and f.shown != nil and f.markOf("headers").size.x > 0)
  step("record 2", proc (f: FrameInfo) =
    f.apply(Command(kind: ckGather, panel: MainPanel, gather: 1)), proc (f: FrameInfo): bool =
    f.panel.laidOut and f.panel.layers[0].source.gather == 1)
  menu("File > Reopen with options...", "File", "Reopen with options...", dialogOpen)
  clickOn("SEG-Y named", "reopen.standard SEG-Y", proc (f: FrameInfo): bool = wait > 3)
  clickOn("every header checked", "reopen.verify", proc (f: FrameInfo): bool =
    result = wait > 3
    if result:
      opensBefore = f.opens
      f.shoot("reopen-dialog.png"))
  clickOn("Reopen", "reopen.reopen", proc (f: FrameInfo): bool =
    f.markOf("reopen").size.x == 0 and f.shown != nil and
      f.shown.facts.opened.choice.verifyAll and f.shown.facts.opened.choice.standard == scSegy)
  step("shown again at record 2", noop, proc (f: FrameInfo): bool =
    result = f.panel.laidOut and f.panel.layers[0].source.gather == 1
    if result:
      doAssert f.opens == opensBefore + 1, "not opened again by the open job: " & $f.opens
      doAssert not f.reopenDialog.shown)
  clickOn("the Summary tab", "headers.tab summary", proc (f: FrameInfo): bool =
    wait > 3 and f.markOf("headers.summary Read as").size.x > 0 and
      f.markOf("headers.summary Options").size.x > 0)
  step("the Summary says how", noop, proc (f: FrameInfo): bool =
    result = wait > 2
    if result:
      let lines = summaryLines(f.shown, 1)
      var options = ""
      for l in lines:
        if l.label == "Options": options = l.value
      doAssert options == "read as SEG-Y, not detected; every trace header checked", options
      f.shoot("reopen-summary.png"))
  clickOn("the Summary's button", "headers.summary reopen", dialogOpen)
  clickOn("Defaults", "reopen.defaults", proc (f: FrameInfo): bool = wait > 3)
  clickOn("Reopen with the defaults", "reopen.reopen", proc (f: FrameInfo): bool =
    f.markOf("reopen").size.x == 0 and f.shown != nil and
      f.shown.facts.opened.choice.isDefault and f.panel.laidOut)
  menu("the dialog again", "File", "Reopen with options...", proc (f: FrameInfo): bool =
    result = dialogOpen(f)
    if result: opensBefore = f.opens)
  step("Escape", proc (f: FrameInfo) =
    f.pressKey(skEscape, true)
    f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
    result = wait > 5 and f.markOf("reopen").size.x == 0
    if result: doAssert f.opens == opensBefore, "Escape opened the file again")
  menu("Help > About viewSEG", "Help", "About viewSEG", proc (f: FrameInfo): bool =
    result = wait > 3 and f.markOf("about").size.x > 0 and
      f.markOf("about parseSEG").size.x > 0 and f.markOf("about processSEG").size.x > 0 and
      f.markOf("about viewSEG").size.x > 0
    if result: f.shoot("about.png"))
  clickOn("Close", "about.close", proc (f: FrameInfo): bool =
    wait > 3 and f.markOf("about").size.x == 0)

  proc onFrame(f: FrameInfo) =
    if at >= steps.len or failed.len > 0:
      f.stop()
      return
    if not started:
      steps[at].act(f)
      started = true
      (wait, since) = (0, getMonoTime())
    else:
      inc wait
      if wait >= 2 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 400, since):
        failed = steps[at].name & " did not happen"
        f.stop()

  let code = run(RunOptions(persist: false, logDir: some(fx.dir / "logs"), openPaths: @[path],
    windowSize: (1600, 1000), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
  echo "tguireopen: ", steps.len, " steps"
