## Generate O file in the Imported Survey window, in the running frontend,
## headless, driven by the mouse: with a survey of S and R files only the
## button is there and dim; once the X file is loaded it is not dim; a click
## asks for a file (the dialog starts at the X file's name with `.ops`) and a
## job writes the O records, which the library reads back as the same pairs
## the X records give; Messages say what was written and that it is not
## imported; naming the X file itself is refused and the file keeps its bytes.
##
## Seen to fail: with the button's dim state left off, "the button was not dim
## without X records"; with the dialog's answer never reaching the command, "the
## O file was not written"; with the refusal left out, "the X file was
## overwritten".
##
## Needs a display: run under
## `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves ofile-window.png there.

import std/[monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc hasMark(f: FrameInfo; prefix: string): bool =
  f.markNames(prefix).len > 0

proc said(st: AppState; text: string): bool =
  for e in st.log:
    if text in e.text: return true
  false

type Step = object
  name: string
  limit: int
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

proc main*() =
  withFixtures fx:
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let root = currentSourcePath().parentDir.parentDir
    let sps = fx.surveySps()
    let xBytes = readFile(sps.x)
    let made = fx.dir / "out" / "made.ops"
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var nextDest = fx.dir / "out" / "made" # no extension: the program adds `.ops`
    var asked: seq[(DialogKind, string)]
    let hook = proc (kind: DialogKind; location: string): seq[string] =
      asked.add (kind, location)
      case kind
      of dkGenerateOFile: @[nextDest]
      else: @[]
    var steps: seq[Step]
    var wait = 0
    var since = getMonoTime()
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool;
        limit = 600) =
      steps.add Step(name: name, limit: limit, act: act, done: done)
    proc noop(f: FrameInfo) = discard

    step("the bar", proc (f: FrameInfo) =
      f.resizeWindow(1920, 1080)
      f.keepInMainWindow()
      f.apply(Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r])),
      proc (f: FrameInfo): bool =
        f.markOf("menu.Project").size.x > 0 and f.windowSize == (1920, 1080) and
          f.core.survey.layers.len == 2)
    step("Project", proc (f: FrameInfo) = f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool = f.markOf("menu.Import survey...").size.x > 0)
    step("Import survey...", proc (f: FrameInfo) =
      f.click(f.markOf("menu.Import survey...").centre),
      proc (f: FrameInfo): bool = f.hasMark("join.ofile.dim"))
    step("clicking the dim button does nothing", proc (f: FrameInfo) =
      f.click(f.markOf("join.ofile").centre),
      proc (f: FrameInfo): bool =
        doAssert f.hasMark("join.ofile.dim"), "the button was not dim without X records"
        doAssert asked.len == 0 and not f.core.oFileRunning, "a dim button asked for a file"
        wait > 10)
    step("the X file loaded", proc (f: FrameInfo) =
      f.apply(Command(kind: ckLoadSurvey, paths: @[sps.x])),
      proc (f: FrameInfo): bool = f.core.relationLayer >= 0 and not f.hasMark("join.ofile.dim"))
    step("the X file itself is refused", proc (f: FrameInfo) =
      nextDest = sps.x
      f.click(f.markOf("join.ofile").centre),
      proc (f: FrameInfo): bool =
        if asked.len == 0: return false
        doAssert asked[0] == (dkGenerateOFile, sps.x.changeFileExt(".ops")),
          "the dialog started at " & $asked[0]
        doAssert readFile(sps.x) == xBytes, "the X file was overwritten"
        doAssert not f.core.oFileRunning and f.core.oFileWritten.len == 0
        f.core.oFileOutcome.startsWith("The O file was not written") and
          f.hasMark("join.ofile.outcome"))
    step("Generate O file...", proc (f: FrameInfo) =
      nextDest = fx.dir / "out" / "made"
      f.click(f.markOf("join.ofile").centre),
      proc (f: FrameInfo): bool =
        if not fileExists(made) or f.core.oFileRunning or f.core.oFileWritten.len == 0:
          if wait mod 40 == 39 and not f.core.oFileRunning and not fileExists(made):
            f.click(f.markOf("join.ofile").centre)
          return false
        doAssert asked.len >= 2 and asked[^1][0] == dkGenerateOFile
        doAssert readFile(sps.x) == xBytes, "the X file was opened for writing"
        var x = initSurveyGeometry()
        x.addSps(sps.x)
        var o = initSurveyGeometry()
        o.addSps(made)
        doAssert o.relationCount(rdReceiver) == x.receiverRelations(1, 'O').len
        doAssert f.core.said("O records to made.ops") and f.core.said("not imported"),
          "Messages do not say what was written"
        doAssert f.hasMark("join.ofile.outcome")
        if shots.len > 0:
          createDir(shots)
          doAssert f.savePng(shots / "ofile-window.png"), "the screenshot was not written"
        true)

    var at = 0
    var started = false
    var failed = ""
    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.keepInMainWindow()
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
        elif overdue(wait, steps[at].limit, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    var opts = RunOptions(windowSize: (1920, 1080), theme: forceDark, persist: true,
      configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"),
      userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[root / "assets"]), dialogs: hook)
    opts.onFrame = onFrame
    let code = run(opts)
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguiofile: ", steps.len, " steps"

when isMainModule:
  main()
