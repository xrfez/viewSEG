## The toolbar under the menu bar in the running frontend, headless, driven
## by real clicks: its buttons are told by their marks ("tool." and the
## button's name), in the order they are drawn, so a button moved or left out
## fails here. Reopen with options opens its dialog, Undo and Redo take a
## trace edit back and make it again (they do nothing with nothing to undo),
## and Reference archive opens the archive window. With
## `VIEWSEG_SCREENSHOTS=<dir>` the window is saved in both themes
## (toolbar-dark.png, toolbar-light.png).
##
## Seen to fail: with the Redo button drawn before Undo, "the toolbar reads
## @[..., "Redo", "Undo", ...]"; with Undo sending nothing, "Undo did not
## take the edit back".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[monotimes, options, os, strutils]
import viewSEG/core/[edits, geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

const Buttons = ["Open file", "Open folder", "Reopen with options", "Undo", "Redo", "FFT",
  "Spectrogram", "Envelope and instantaneous phase", "Phase spectrum", "Cross-correlation",
  "Vibrator signature", "f-k", "Node orientation", "Reference archive", "Jobs"]

func centre(r: Rect): Vec2 = vec2(r.pos.x + r.size.x / 2, r.pos.y + r.size.y / 2)

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc run(fx: Fixtures; choice: ThemeChoice; file: string) =
  let path = fx.surveySegy()
  let config = fx.dir / ("config-" & file)
  createDir(config)
  let opts = RunOptions(openPaths: @[path], windowSize: (1400, 900),
    theme: choice, persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
    indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
    assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]))
  let shots = getEnv("VIEWSEG_SCREENSHOTS")
  var steps: seq[Step]
  var wait = 0
  var got: seq[string]
  var since = getMonoTime()
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard
  proc edits(f: FrameInfo): FileEdits = f.core.editsOf(f.core.findPanel(MainPanel))
  proc buttons(f: FrameInfo): seq[string] =
    for n in f.markNames("tool."):
      let name = n["tool.".len .. ^1]
      if not name.startsWith("project"): result.add name

  step("the buttons", noop, proc (f: FrameInfo): bool =
    got = f.buttons
    result = f.core.panels[f.core.findPanel(MainPanel)].laidOut and f.core.sessions.len == 1 and
      got.len == Buttons.len
    if result:
      doAssert got == @Buttons, "the toolbar reads " & $got
      if shots.len > 0: doAssert f.savePng(shots / file), "cannot save " & file)
  step("Undo with nothing to undo", proc (f: FrameInfo) =
    doAssert f.edits.undoText.len == 0 and f.edits.redoText.len == 0
    f.click(f.markOf("tool.Undo").centre), proc (f: FrameInfo): bool =
    f.edits.undoText.len == 0 and f.edits.redoText.len == 0)
  step("a trace killed", proc (f: FrameInfo) =
    f.apply(Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[0], on: true)),
    proc (f: FrameInfo): bool = f.edits.undoText.len > 0 and wait > 4)
  step("Undo", proc (f: FrameInfo) = f.click(f.markOf("tool.Undo").centre),
    proc (f: FrameInfo): bool =
    doAssert f.edits.undoText.len == 0 or wait < 100, "Undo did not take the edit back"
    f.edits.undoText.len == 0 and f.edits.redoText.len > 0)
  step("Redo", proc (f: FrameInfo) = f.click(f.markOf("tool.Redo").centre),
    proc (f: FrameInfo): bool = f.edits.undoText.len > 0 and f.edits.redoText.len == 0)
  step("Reopen with options", proc (f: FrameInfo) =
    f.click(f.markOf("tool.Reopen with options").centre), proc (f: FrameInfo): bool =
    f.markOf("reopen").size.x > 0)
  step("Reopen closed", proc (f: FrameInfo) = f.pressKey(skEscape, true),
    proc (f: FrameInfo): bool =
    f.pressKey(skEscape, false)
    f.markOf("reopen").size.x == 0)
  step("Reference archive", proc (f: FrameInfo) =
    f.click(f.markOf("tool.Reference archive").centre), proc (f: FrameInfo): bool =
    f.markOf("references").size.x > 0)

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
      (wait, since) = (0, getMonoTime())
    else:
      inc wait
      if wait >= 3 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 300, since):
        failed = steps[at].name & " did not happen; the toolbar reads " & $got
        f.stop()
  var o = opts
  o.onFrame = onFrame
  let code = run(o)
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc main*() =
  withFixtures fx:
    run(fx, forceDark, "toolbar-dark.png")
    run(fx, forceLight, "toolbar-light.png")

when isMainModule:
  main()
