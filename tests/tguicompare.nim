## The compare window, driven headless on samples/vib: set A and B from two
## files and from one file, chips, badges, swap, clear.
##
## Seen to fail: with the plot menu's compare items missing, "the plot's menu
## offers Compare did not happen".

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, spectra, state]
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
    var other = ""
    var shot = false
    var fileBefore = ""
    var spectraBefore = -1

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc clickMark(f: FrameInfo; mark: string; button = 1): bool =
      let r = f.markOf(mark)
      if r.size.x > 0 and wait mod 6 == 3:
        f.click(r.centre, button)
        true
      else: false

    step("the folder's first file opens", noop, proc (f: FrameInfo): bool =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      result = p.laidOut and f.markOf("plot.data").size.x > 0 and f.core.sessions.len >= 1
      if result:
        plot = f.markOf("plot.data")
        let shown = f.core.sessions[0].name
        other = if "uncorrelated" in shown: "vib_correlated.sgd" else: "vib_uncorrelated.sgd")

    step("the plot's menu is grouped: headings, no top-level FFT", proc (f: FrameInfo) =
      f.moveMouse(plot.centre), proc (f: FrameInfo): bool =
      if wait == 3: f.click(plot.centre, button = 3)
      result = f.markOf("plot.menu.compare").size.x > 0 and f.markOf("plot.menu").size.x > 100
      if result:
        for h in ["analyse", "find", "record"]:
          doAssert f.markOf("plot.menu.heading." & h).size.x > 0, "no heading " & h
        doAssert f.markOf("plot.menu.fft").size.x == 0, "the top-level FFT item is back"
        doAssert f.markOf("plot.menu.compareA").size.x == 0, "Compare is not a submenu")

    step("the plot's menu offers Compare", proc (f: FrameInfo) =
      f.moveMouse(plot.centre), proc (f: FrameInfo): bool =
      if f.markOf("plot.menu.compare").size.x == 0 and wait mod 8 == 2:
        f.click(plot.centre, button = 3)
      elif f.markOf("plot.menu.compareA").size.x == 0 and
          f.markOf("plot.menu.compare").size.x > 0 and wait mod 6 == 3:
        f.click(f.markOf("plot.menu.compare").centre)
      f.markOf("plot.menu.compareA").size.x > 0 and f.markOf("plot.menu.compareB").size.x > 0)

    step("Compare: set as A from the first file", noop, proc (f: FrameInfo): bool =
      if not f.core.compareA.filled: discard f.clickMark("plot.menu.compareA")
      f.core.compareA.filled and f.core.compareA.samples.len > 0)

    step("the other file is shown", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("files.row " & other).centre), proc (f: FrameInfo): bool =
      if f.core.sessions.len == 0 or other notin f.core.sessions[0].name:
        discard f.clickMark("files.row " & other)
      other in f.core.sessions[0].name and f.core.panel(MainPanel).laidOut and
        f.markOf("plot.data").size.x > 0)

    step("the plot's menu offers Compare on the other file", proc (f: FrameInfo) =
      plot = f.markOf("plot.data")
      f.moveMouse(plot.centre), proc (f: FrameInfo): bool =
      if f.markOf("plot.menu.compare").size.x == 0 and wait mod 8 == 2:
        f.click(plot.centre, button = 3)
      elif f.markOf("plot.menu.compareB").size.x == 0 and
          f.markOf("plot.menu.compare").size.x > 0 and wait mod 6 == 3:
        f.click(f.markOf("plot.menu.compare").centre)
      f.markOf("plot.menu.compareB").size.x > 0)

    step("Compare: set as B from the second file", noop, proc (f: FrameInfo): bool =
      if not f.core.compareB.filled: discard f.clickMark("plot.menu.compareB")
      result = f.core.compareB.filled and f.core.compareOpen and
        f.markOf("compare.chip.A").size.x > 0 and f.markOf("compare.chip.B").size.x > 0
      if result:
        doAssert f.core.compareA.fileName != f.core.compareB.fileName, f.core.compareChip(cwA) &
          " | " & f.core.compareChip(cwB)
        doAssert f.markOf("files.compareA vib_uncorrelated.sgd").size.x > 0 or
          f.markOf("files.compareA vib_correlated.sgd").size.x > 0
        doAssert f.markOf("files.compareB vib_uncorrelated.sgd").size.x > 0 or
          f.markOf("files.compareB vib_correlated.sgd").size.x > 0
        doAssert f.markOf("plot.header.compareB " & $f.core.compareB.trace).size.x > 0,
          "no B mark on trace " & $f.core.compareB.trace
        if not shot: shot = f.savePng(shots / "compare-window.png"))

    step("swap exchanges the chips", proc (f: FrameInfo) =
      fileBefore = f.core.compareA.fileName, proc (f: FrameInfo): bool =
      if f.core.compareA.fileName == fileBefore: discard f.clickMark("compare.swap")
      result = f.core.compareA.fileName != fileBefore and f.core.compareB.fileName == fileBefore)

    step("clear both empties the slots", noop, proc (f: FrameInfo): bool =
      if f.core.compareA.filled or f.core.compareB.filled:
        discard f.clickMark("compare.clear")
      not f.core.compareA.filled and not f.core.compareB.filled)

    step("set A and B from one file", proc (f: FrameInfo) =
      f.apply Command(kind: ckCompareWindow, compareOpen: false)
      plot = f.markOf("plot.data")
      f.moveMouse(plot.centre), proc (f: FrameInfo): bool =
      if f.core.compareOpen:
        f.apply Command(kind: ckCompareWindow, compareOpen: false)
        return false
      if f.core.sessions.len == 0: return false
      let base = f.core.sessions[0].base
      if not f.core.compareA.filled:
        if f.markOf("plot.menu.compare").size.x == 0 and wait mod 8 == 2:
          f.click(vec2(plot.pos.x + plot.size.x * 0.25, plot.pos.y + plot.size.y * 0.5), 3)
        elif f.markOf("plot.menu.compareA").size.x == 0 and
            f.markOf("plot.menu.compare").size.x > 0 and wait mod 6 == 3:
          f.click(f.markOf("plot.menu.compare").centre)
        elif f.markOf("plot.menu.compareA").size.x > 0 and wait mod 6 == 3:
          f.click(f.markOf("plot.menu.compareA").centre)
      elif not f.core.compareB.filled:
        if f.markOf("plot.menu.compare").size.x == 0 and wait mod 8 == 2:
          f.click(vec2(plot.pos.x + plot.size.x * 0.72, plot.pos.y + plot.size.y * 0.5), 3)
        elif f.markOf("plot.menu.compareB").size.x == 0 and
            f.markOf("plot.menu.compare").size.x > 0 and wait mod 6 == 3:
          f.click(f.markOf("plot.menu.compare").centre)
        elif f.markOf("plot.menu.compareB").size.x > 0 and wait mod 6 == 3:
          f.click(f.markOf("plot.menu.compareB").centre)
      result = f.core.compareA.filled and f.core.compareB.filled and
        f.core.compareA.fileName == f.core.compareB.fileName and
        f.core.compareA.trace != f.core.compareB.trace and
        f.core.compareA.trace >= 1 and f.core.compareB.trace >= 1 and
        f.core.sessions[0].base == base)

    step("FFT is reachable through New plot", proc (f: FrameInfo) =
      plot = f.markOf("plot.data")
      spectraBefore = f.core.spectra.len
      f.moveMouse(plot.centre), proc (f: FrameInfo): bool =
      if f.markOf("plot.menu.newplot").size.x == 0:
        if wait mod 8 == 2: f.click(plot.centre, button = 3)
      elif f.markOf("plot.menu.newplot.fft").size.x == 0:
        if wait mod 6 == 3: f.click(f.markOf("plot.menu.newplot").centre)
      elif wait mod 6 == 3: f.click(f.markOf("plot.menu.newplot.fft").centre)
      f.core.spectra.len > spectraBefore)

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
        for e in f.core.log: echo "  log: ", e.text
        discard f.savePng(shots / "compare-failed.png")
        f.stop()

    let code = run(RunOptions(openPaths: @[folder], windowSize: (1600, 1000), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    doAssert shot, "the compare window was not saved"
    echo "tguicompare: ", steps.len, " steps"

when isMainModule:
  main()
