## The compare window's phase drop-down has an id of its own: hovering it makes
## Dear ImGui report no "visible items with conflicting ID" (it did, with the
## phase plot).
##
## Seen to fail: with the drop-down named "##compare.phase" again (the id of
## the phase plot), "ImGui reports items with one id under the phase drop-down".

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

const root = currentSourcePath().parentDir.parentDir
const shots = root / ".scratch"

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; q: Vec2; button = 1) =
  f.moveMouse(q)
  f.pressMouse(q, true, button)
  f.pressMouse(q, false, button)

proc main*() =

  withFixtures fx:
    let folder = root / "samples" / "vib"
    doAssert dirExists(folder), folder
    createDir(shots)
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var plot: Rect
    var shot = false

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    step("the folder's first file opens", noop, proc (f: FrameInfo): bool =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      result = p.laidOut and f.markOf("plot.data").size.x > 0 and f.core.sessions.len >= 1
      if result: plot = f.markOf("plot.data"))

    step("set A and B from one file", proc (f: FrameInfo) =
      f.moveMouse(plot.centre), proc (f: FrameInfo): bool =
      if not f.core.compareA.filled:
        if f.markOf("plot.menu.compareA").size.x == 0 and wait mod 8 == 2:
          f.click(vec2(plot.pos.x + plot.size.x * 0.25, plot.pos.y + plot.size.y * 0.5), 3)
        elif f.markOf("plot.menu.compareA").size.x > 0 and wait mod 6 == 3:
          f.click(f.markOf("plot.menu.compareA").centre)
      elif not f.core.compareB.filled:
        if f.markOf("plot.menu.compareB").size.x == 0 and wait mod 8 == 2:
          f.click(vec2(plot.pos.x + plot.size.x * 0.72, plot.pos.y + plot.size.y * 0.5), 3)
        elif f.markOf("plot.menu.compareB").size.x > 0 and wait mod 6 == 3:
          f.click(f.markOf("plot.menu.compareB").centre)
      result = f.core.compareA.filled and f.core.compareB.filled and
        f.core.compareOpen and f.markOf("compare.phasePicture").size.x > 0)

    step("hovering the drop-down raises no id conflict", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("compare.phasePicture").centre), proc (f: FrameInfo): bool =
      if wait mod 4 == 1: f.moveMouse(f.markOf("compare.phasePicture").centre)
      doAssert not f.idConflict, "ImGui reports items with one id under the phase drop-down"
      if wait >= 20 and not shot: shot = f.savePng(shots / "compare-tip.png")
      wait >= 20)

    proc onFrame(f: FrameInfo) =
      inc wait
      if at >= steps.len: f.stop()
      elif not started:
        steps[at].act(f)
        started = true
        since = getMonoTime()
      elif steps[at].done(f):
        inc at
        started = false
        wait = 0
      elif overdue(wait, 500, since):
        failed = steps[at].name & " did not happen"
        discard f.savePng(shots / "compare-tip-failed.png")
        f.stop()

    let code = run(RunOptions(openPaths: @[folder], windowSize: (1600, 1000), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguicomparetip: ", steps.len, " steps"

when isMainModule:
  main()
