## The Files window's "Include subfolders", headless, with real clicks: a folder that
## holds only subfolders lists nothing and says "No seismic files here; 1 subfolder"
## beside a one-click "Include subfolders"; the click lists the seismic files of the
## tree, with a Folder column (and the filter matching what it shows); the checkbox
## beside the filter turns it off again.
##
## Seen to fail: with the note's button not adding the command, "the note's button did
## not list the tree".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves subfolders.png there.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/[fixtures, vibfiles, waiting]

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc main*() =
  withFixtures fx:
    let top = fx.dir / "survey day"
    createDir(top / "line1" / "shots")
    copyFile(fx.vibPlainSegy(), top / "line1" / "a.sgy")
    copyFile(fx.vibPlainSegy(), top / "line1" / "shots" / "b.sgy")
    createDir(top / "line2")
    copyFile(fx.vibPlainSegy(), top / "line2" / "c.sgy")
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var pointAt: Vec2
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc click(mark: string) =
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = r.centre
        f.moveMouse(pointAt), proc (f: FrameInfo): bool = true)
      step("press " & mark, proc (f: FrameInfo) = f.pressMouse(pointAt, true),
        proc (f: FrameInfo): bool = true)
      step("release " & mark, proc (f: FrameInfo) = f.pressMouse(pointAt, false),
        proc (f: FrameInfo): bool = true)
    proc browse(f: FrameInfo) = f.apply Command(kind: ckBrowse, paths: @[top])
    step("list the folder", browse,
      proc (f: FrameInfo): bool =
      result = f.core.fileList.title == top and not f.core.fileList.scanning and
        f.markOf("files.subfolders.note").size.x > 0
      if result:
        doAssert f.core.fileList.entries.len == 0 and not f.core.includesSubfolders
        doAssert f.markOf("files.subfolders").size.x > 0, "no switch beside the filter")
    click("files.subfolders.note")
    step("the tree", noop, proc (f: FrameInfo): bool =
      result = f.core.fileList.recursive and not f.core.fileList.scanning and
        f.core.fileList.entries.len == 3 and f.markOf("files.row b.sgy").size.x > 0
      if result:
        doAssert f.core.includesSubfolders
        doAssert f.markOf("files.subfolders.note").size.x == 0, "the note stayed"
        if shots.len > 0: doAssert f.savePng(shots / "subfolders.png"))
    click("files.subfolders")
    step("off again", noop, proc (f: FrameInfo): bool =
      result = not f.core.fileList.recursive and not f.core.fileList.scanning
      if result: doAssert not f.core.includesSubfolders)

    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
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
        elif overdue(wait, 600, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(windowSize: (1400, 900), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguisubfolders: ", steps.len, " steps"

when isMainModule:
  main()
