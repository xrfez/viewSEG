## The Node orientation plot in the running frontend, headless, on
## samples/obn/obn_receiver.sgd with node 104's record (the fifth) on show:
##
## - it opens with no trace selected, of the 32 traces the plot shows, and
##   draws three lines (roll, pitch, azimuth) with no problem said;
## - it shows its Explain icon, `new plot 1.explain`, and hovering it shows
##   the words `core/explain` gives for the plot, with no two items under the
##   pointer sharing an id (`idConflict`).
##
## Seen to fail: with the view's Explain kind set to the f-k's, the hover's
## `"the node moved" in text` (the f-k's words were shown).

## Needs a display: run under the tester (it gives each test its own).
## `VIEWSEG_SCREENSHOTS=<dir>` saves orient-104.png (the lines) and orient-104-explain.png (the tooltip) there.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[explain, geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

const root = currentSourcePath().parentDir.parentDir

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc tipOf(f: FrameInfo; mark: string): string =
  ## The words the tooltip of `mark`'s icon shows now; "" for none.
  let prefix = mark & ".tip:"
  for n in f.markNames(prefix): return n[prefix.len .. ^1]

proc main*() =
  let obn = root / "samples" / "obn" / "obn_receiver.sgd"
  doAssert fileExists(obn)
  let shots = getEnv("VIEWSEG_SCREENSHOTS")
  withFixtures fx:
    var steps: seq[Step] = @[]
    var wait = 0
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard

    step("the file", noop, proc (f: FrameInfo): bool =
      f.core.sessions.len == 1 and f.panel.laidOut)
    step("node 104's record", proc (f: FrameInfo) =
      f.apply(Command(kind: ckGather, panel: MainPanel, gather: 3)),
      proc (f: FrameInfo): bool = f.panel.laidOut and f.panel.shown.len == 32)
    step("open the plot", proc (f: FrameInfo) =
      f.apply(Command(kind: ckOpenPlot, plotView: avOrientation)),
      proc (f: FrameInfo): bool =
        result = f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.plots.len == 1 and f.markOf("new plot 1.explain").size.x > 0
        if result:
          doAssert f.core.plots[0].traces.len == 32, "the plot is of " & $f.core.plots[0].traces.len
          doAssert f.core.plots[0].result.problem.len == 0, f.core.plots[0].result.problem
          doAssert f.core.plots[0].result.plots[0].curves.len == 3)
    var calm = 0
    step("the lines, the pointer away", proc (f: FrameInfo) =
      f.moveMouse(vec2(2, 500)),
      proc (f: FrameInfo): bool =
        inc calm
        result = calm >= 6
        if result and shots.len > 0: discard f.savePng(shots / "orient-104.png"))
    step("right-click the plot", proc (f: FrameInfo) =
      let at = f.markOf("new plot 1.explain").centre
      f.moveMouse(at)
      f.pressMouse(at, true, 3)
      f.pressMouse(at, false, 3),
      proc (f: FrameInfo): bool = f.markOf("new plot 1.explain.menu.explain").size.x > 0)
    step("Explain in its menu", proc (f: FrameInfo) =
      let at = f.markOf("new plot 1.explain.menu.explain").centre
      f.moveMouse(at)
      f.pressMouse(at, true, 1)
      f.pressMouse(at, false, 1),
      proc (f: FrameInfo): bool =
        let text = f.tipOf("new plot 1.explain")
        result = text.len > 0
        if result:
          doAssert not f.idConflict, "two items under the pointer share an id"
          let want = f.core.explainPane(f.core.plots[0], 0)
          doAssert text == want, "the icon says\n" & text & "\nnot\n" & want
          doAssert "Reading it: " in text and "the node moved" in text, text
          if shots.len > 0: discard f.savePng(shots / "orient-104-explain.png"))

    var at = 0
    var started = false
    var failed = ""
    var since = getMonoTime()
    proc onFrame(f: FrameInfo) =
      inc wait
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if not started:
        steps[at].act(f)
        started = true
        since = getMonoTime()
        wait = 0
      elif wait >= 2 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 900, since):
        failed = steps[at].name & " did not happen"
        for e in f.core.log: echo "  log: ", e.text
        for w in f.core.plots: echo "  plot ", w.id, ": ", w.result.problem, " ",
          w.result.plots.len, " waiting ", w.waiting, " ", w.traces.len
        f.stop()
    let code = run(RunOptions(openPaths: @[obn], windowSize: (1600, 1000), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguiorientation: ", steps.len, " steps"

when isMainModule: main()
