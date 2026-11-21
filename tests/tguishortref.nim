## A trace shorter than its reference, in the Cross-correlation window, headless: a 4 000 ms
## reference (generated) against the four-trace file's 3 000 ms traces gives a warning line
## in the window's note ("trace is 3 000 ms, the reference is 4 000 ms: the last 1 000 ms of
## the reference have no data"), marked `warning`, and one warning in Messages for the file,
## however many windows (and redraws) show it; a reference as long as the trace gives none.
##
## Seen to fail: with the warning logged by each answer (not once per file), "2 messages".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves short-reference.png there.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[analysis, geometry, references, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, vibfiles, waiting]

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

const Said = "the last 1 000 ms of the reference have no data"

proc said(f: FrameInfo): int =
  for e in f.core.log:
    if Said in e.text: inc result

proc main*() =
  withFixtures fx:
    let path = fx.vibFourSegy()
    let config = fx.dir / "config"
    createDir(config)
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var longId, sameId = ""
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    step("the file opens", noop, proc (f: FrameInfo): bool =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      p.laidOut and f.core.referencesLoaded and f.core.shownIntervalMs > 0)
    proc generate(f: FrameInfo) =
      for (name, ms) in [("Long", 4000.0), ("Same", 3000.0)]:
        f.apply Command(kind: ckGenerateReference, refGenerate: GeneratedReference(name: name,
          law: rlLinear, f1Hz: 10, f2Hz: 200, durationMs: ms, dtMs: f.core.shownIntervalMs,
          amplitude: 1))
    step("two references", generate, proc (f: FrameInfo): bool =
      for e in f.core.references.entries:
        if e.name == "Long": longId = e.id
        elif e.name == "Same": sameId = e.id
      longId.len > 0 and sameId.len > 0)
    proc chooseLong(f: FrameInfo) =
      f.apply Command(kind: ckSelectReference, refId: longId)
      let base = f.core.sessions[0].base
      f.apply Command(kind: ckOpenPlot, plotView: avCorrelation, plotTraces: @[base + 3])
    step("a short trace", chooseLong, proc (f: FrameInfo): bool =
      result = f.core.plots.len == 1 and not f.core.plots[0].waiting and
        f.core.plots[0].result.problem == "" and f.markOf("new plot 1.warning").size.x > 0
      if result:
        doAssert f.core.plots[0].result.warning.startsWith("trace is 3 000 ms, the reference " &
          "is 4 000 ms: " & Said), f.core.plots[0].result.warning
        if shots.len > 0: doAssert f.savePng(shots / "short-reference.png"))
    proc another(f: FrameInfo) =
      let base = f.core.sessions[0].base
      f.apply Command(kind: ckOpenPlot, plotView: avCorrelation, plotTraces: @[base + 1])
    step("a second window", another, proc (f: FrameInfo): bool =
      result = f.core.plots.len == 2 and not f.core.plots[1].waiting and
        f.core.plots[1].result.warning.len > 0
      if result:
        doAssert f.said == 1, $f.said & " messages for one file")
    proc chooseSame(f: FrameInfo) = f.apply Command(kind: ckSelectReference, refId: sameId)
    step("a reference as long as the trace", chooseSame, proc (f: FrameInfo): bool =
      result = f.core.chosenReference == sameId and not f.core.plots[0].waiting and
        not f.core.plots[1].waiting and f.core.plots[0].result.plots.len > 0
      if result:
        doAssert f.core.plots[0].result.warning == "", f.core.plots[0].result.warning
        doAssert f.markOf("new plot 1.warning").size.x == 0, "the warning stayed"
        doAssert f.said == 1)

    proc onFrame(f: FrameInfo) =
      inc wait
      if at >= steps.len or failed.len > 0: f.stop()
      elif not started:
        steps[at].act(f)
        started = true
        since = getMonoTime()
      elif wait >= 3 and steps[at].done(f):
        inc at
        started = false
        wait = 0
      elif overdue(wait, 500, since):
        failed = steps[at].name & " did not happen"
        f.stop()
    let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000), theme: forceDark,
      persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguishortref: ", steps.len, " steps"

when isMainModule:
  main()
