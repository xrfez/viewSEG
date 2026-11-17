## The Correlation window, headless, on samples/ only: the two reference
## buttons are gone, References opens the archive, and choosing another
## reference changes an unfrozen window but not a frozen one.
##
## Seen to fail: with the old buttons still drawn, "new plot 1.reference
## selected" had a size. With the none control still marked fromfile,
## "References opens" did not happen.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, references, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

const root = currentSourcePath().parentDir.parentDir

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; q: Vec2) =
  f.moveMouse(q)
  f.pressMouse(q, true, 1)
  f.pressMouse(q, false, 1)

proc curveOf(f: FrameInfo; w: int): seq[float64] =
  if w < f.core.plots.len and f.core.plots[w].result.plots.len > 0 and
      f.core.plots[w].result.plots[0].curves.len > 0:
    result = f.core.plots[w].result.plots[0].curves[0].ys

proc main*() =
  withFixtures fx:
    let path = root / "samples" / "land" / "shots.sgy"
    doAssert fileExists(path), path
    let config = fx.dir / "config"
    createDir(config)
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var first, second = ""
    var frozenCurve: seq[float64] = @[]
    var before: seq[float64] = @[]

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc clickMark(f: FrameInfo; mark: string): bool =
      let r = f.markOf(mark)
      if r.size.x == 0: return false
      f.moveMouse(r.centre)
      if wait mod 8 == 5:
        f.pressMouse(r.centre, true, 1)
        f.pressMouse(r.centre, false, 1)
        true
      else: false

    step("the file opens", noop, proc (f: FrameInfo): bool =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      p.laidOut and f.markOf("plot.data").size.x > 0 and f.core.referencesLoaded and
        f.core.shownIntervalMs > 0)

    proc genTwo(f: FrameInfo) {.closure.} =
      let dt = f.core.shownIntervalMs
      f.apply Command(kind: ckGenerateReference, refGenerate: GeneratedReference(
        name: "AAA first", law: rlLinear, f1Hz: 8, f2Hz: 40, durationMs: 400,
        dtMs: dt, amplitude: 1))
      f.apply Command(kind: ckGenerateReference, refGenerate: GeneratedReference(
        name: "ZZZ second", law: rlLinear, f1Hz: 12, f2Hz: 60, durationMs: 400,
        dtMs: dt, amplitude: 1))

    step("two references", genTwo, proc (f: FrameInfo): bool =
      for e in f.core.references.entries:
        if e.name == "AAA first": first = e.id
        elif e.name == "ZZZ second": second = e.id
      first.len > 0 and second.len > 0)

    proc openCorr(f: FrameInfo) {.closure.} =
      let base = f.core.sessions[0].base
      f.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
        plotTraces: @[base, base + 1])

    step("a correlation", openCorr, proc (f: FrameInfo): bool =
      f.core.plots.len == 1 and not f.core.plots[0].waiting and
        f.markOf("new plot 1.references").size.x > 0)

    step("the old buttons are gone", noop, proc (f: FrameInfo): bool =
      doAssert f.markOf("new plot 1.reference selected").size.x == 0
      doAssert f.markOf("new plot 1.reference pilot").size.x == 0
      f.core.plots[0].result.problem == NoReferenceChosen and
        f.core.plots[0].result.plots.len == 0)

    step("References opens", noop, proc (f: FrameInfo): bool =
      if f.markOf("references").size.x == 0: discard f.clickMark("new plot 1.references")
      f.markOf("references").size.x > 0 and f.markOf("references.none").size.x > 0 and
        f.markOf("references.fromfile").size.x == 0)

    step("the first reference is chosen", noop, proc (f: FrameInfo): bool =
      if f.core.chosenReference != first: discard f.clickMark("references.use.0")
      result = f.core.chosenReference == first and not f.core.plots[0].waiting and
        f.core.plots[0].result.problem == "" and f.core.plots[0].result.plots.len > 0
      if result: before = f.curveOf(0))

    proc freezeSecond(f: FrameInfo) {.closure.} =
      let base = f.core.sessions[0].base
      f.apply Command(kind: ckOpenPlot, plotView: avCorrelation, plotTraces: @[base + 2])
      let id = f.core.plots[^1].id
      f.apply Command(kind: ckPlotDisplay, plot: id, plotParams: f.core.plots[^1].params,
        plotFrozen: true)

    step("a frozen window", freezeSecond, proc (f: FrameInfo): bool =
      result = f.core.plots.len == 2 and f.core.plots[1].frozen and not f.core.plots[1].waiting and
        f.core.plots[1].result.plots.len > 0
      if result: frozenCurve = f.curveOf(1))

    proc chooseSecond(f: FrameInfo) {.closure.} =
      f.apply Command(kind: ckSelectReference, refId: second)

    step("another reference changes the picture", chooseSecond, proc (f: FrameInfo): bool =
      let moved = f.curveOf(0)
      let held = f.curveOf(1)
      result = f.core.chosenReference == second and not f.core.plots[0].waiting and
        not f.core.plots[1].waiting and moved.len > 0 and moved != before and
        f.core.plots[1].frozen and held == frozenCurve
      if result:
        doAssert f.markOf("new plot 1.reference selected").size.x == 0
        doAssert f.markOf("new plot 1.reference pilot").size.x == 0)

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
        failed = steps[at].name & " did not happen; references " &
          $f.markOf("new plot 1.references") & " window " & $f.markOf("references")
        for e in f.core.log: echo "  log: ", e.text
        f.stop()

    let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000), theme: forceDark,
      persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguicorrref: ", steps.len, " steps"

when isMainModule: main()
