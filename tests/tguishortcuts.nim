## Help > Keyboard shortcuts in the running frontend, headless, driven by
## real key events: F1 opens the window with the filter focused, typing
## "zoom" leaves only rows about zoom, and Escape closes it. A picture of
## the open list is written to .scratch/shortcuts.png.
##
## Seen to fail: with F1 left out of the menu's action table, "F1 did not
## open the list"; with the filter not applied to the rows, "zoom left Open
## file in the list"; with Escape not closing the window, "Escape did not
## close the list".
##
## Needs a display: run under the test runner, or
## `xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[monotimes, options, os]
import viewSEG/core/geometry
import viewSEG/ui/imgui/app
import utils/waiting

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

const repo = currentSourcePath().parentDir.parentDir

var wait = 0
var since = getMonoTime()

proc drive(steps: seq[Step]; opts: RunOptions) =
  var at = 0
  var started = false
  var failed = ""
  var o = opts
  o.onFrame = proc (f: FrameInfo) =
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
      elif overdue(wait, 300, since):
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(o)
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
var steps: seq[Step]
proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
  steps.add Step(name: name, act: act, done: done)
proc noop(f: FrameInfo) = discard

proc main*() =

  let tmp = getTempDir() / ("viewseg-shortcuts-" & $getCurrentProcessId())
  createDir(tmp)
  createDir(repo / ".scratch")

  step("the window is up", noop, proc (f: FrameInfo): bool =
    f.markOf("menu.Help").size.x > 0 and f.markOf("shortcuts").size.x == 0)
  step("F1 opens the list", proc (f: FrameInfo) =
    f.pressKey(skF1, true)
    f.pressKey(skF1, false), proc (f: FrameInfo): bool =
    let open = f.markOf("shortcuts").size.x > 40 and f.markOf("shortcuts.filter").size.x > 0 and
      f.markOf("shortcuts.row menu.maOpenFile").size.x > 0
    if open: discard f.savePng(repo / ".scratch" / "shortcuts.png")
    open)
  step("zoom filters the list", proc (f: FrameInfo) =
    f.typeText("zoom"), proc (f: FrameInfo): bool =
    f.markOf("shortcuts.row plot.zoomKeys").size.x > 0 and
      f.markOf("shortcuts.row menu.maOpenFile").size.x == 0)
  step("Escape closes the list", proc (f: FrameInfo) =
    f.pressKey(skEscape, true)
    f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
    f.markOf("shortcuts").size.x == 0)

  drive(steps, RunOptions(theme: forceDark, windowSize: (1400, 900),
    assetDirs: some(@[repo / "assets"]), userThemeDir: some(tmp / "themes"),
    configDir: some(tmp), logDir: some(tmp / "logs"), indexCacheDir: some(tmp / "cache"),
    persist: false))
  removeDir(tmp)

when isMainModule:
  main()
