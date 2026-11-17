## The envelope window's phase drop-down, headless, with real clicks, on
## `spectrumSegy`: the window opens "Against the reference" (the default; no
## reference is chosen, so it draws the trace's own phase and says to choose
## one); the drop-down lists "Against the reference" and "Of the trace
## itself"; choosing the second sets the window's setting and is remembered
## for the next envelope window; the window's Reset options (a real click)
## puts the first back.
##
## Seen to fail: with the drop-down's entries not sending the setting,
## "of the trace itself did not happen"; with the Reset button left out of the
## envelope's line, "an envelope did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[analysis, geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc main*() =
  withFixtures fx:
    var steps: seq[Step] = @[]
    var pointAt: Vec2
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    proc click(mark: string) =
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = r.centre
        f.moveMouse(pointAt), after(3))
      step("click " & mark, proc (f: FrameInfo) =
        f.pressMouse(pointAt, true)
        f.pressMouse(pointAt, false), after(3))

    step("the record", noop, proc (f: FrameInfo): bool =
      let tiles = f.core.tiles(f.core.findPanel(MainPanel))
      f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
        f.panel.pending.gen == f.panel.requestGen)
    step("an envelope", proc (f: FrameInfo) =
      f.apply(Command(kind: ckOpenPlot, plotView: avEnvelope, plotTraces: @[0])),
      proc (f: FrameInfo): bool =
        result = f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.markOf("new plot 1.against").size.x > 0 and f.markOf("new plot 1.reset").size.x > 0
        if result:
          let w = f.core.plots[0]
          doAssert w.params.phaseAgainst == paReference
          doAssert w.result.plots[1].title == "Instantaneous phase of the trace",
            "no reference is chosen: " & w.result.plots[1].title
          doAssert "choose a reference to compare" in w.result.note, w.result.note)
    click("new plot 1.against")
    step("the entries", noop, proc (f: FrameInfo): bool =
      result = f.markOf("new plot 1.against " & $paSelf).size.x > 0
      if result: doAssert f.markOf("new plot 1.against " & $paReference).size.x > 0)
    click("new plot 1.against " & $paSelf)
    step("of the trace itself", noop, proc (f: FrameInfo): bool =
      result = f.core.plots[0].params.phaseAgainst == paSelf and not f.core.plots[0].waiting
      if result:
        doAssert f.core.settings.plotOptions.envelope.phaseAgainst == paSelf,
          "the choice was not remembered")
    step("another envelope", proc (f: FrameInfo) =
      f.apply(Command(kind: ckOpenPlot, plotView: avEnvelope, plotTraces: @[1])),
      proc (f: FrameInfo): bool =
        result = f.core.plots.len == 2
        if result: doAssert f.core.plots[1].params.phaseAgainst == paSelf)
    click("new plot 2.reset") # the second window is in front of the first
    step("reset", noop, proc (f: FrameInfo): bool =
      result = f.core.plots[1].params.phaseAgainst == paReference
      if result: doAssert f.core.settings.plotOptions.envelope.phaseAgainst == paReference)
    step("no id conflict", noop, proc (f: FrameInfo): bool =
      doAssert not f.idConflict
      true)

    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
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
        if wait >= 2 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 400, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(openPaths: @[fx.spectrumSegy()],
      windowSize: (1400, 900), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguienvelope: ok"

when isMainModule: main()
