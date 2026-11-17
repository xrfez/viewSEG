## A pilot taken from the record, headless: in the Generate dialog the source
## "A trace of the record" previews the record on show, Generate stores the rule,
## and a correlation that uses it follows the record.
##
## Seen to fail: with the source choice never switching the dialog, "the source
## choice offers a trace of the record" did not happen.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[analysis, geometry, references, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

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
  const root = currentSourcePath().parentDir.parentDir
  withFixtures fx:
    let path = root / "samples" / "land" / "shots.sgd"
    doAssert fileExists(path), path
    let config = fx.dir / "config"
    createDir(config)
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var window = -1
    var noteFirst = ""
    var asksFirst = 0

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc clickMark(f: FrameInfo; mark: string): bool =
      let r = f.markOf(mark)
      if r.size.x > 0 and wait mod 6 == 3:
        f.click(r.centre)
        true
      else: false

    step("the file opens", noop, proc (f: FrameInfo): bool =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      p.laidOut and f.markOf("plot.data").size.x > 0 and f.core.referencesLoaded)

    step("Operations > Generate a reference...", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("menu.Operations").centre), proc (f: FrameInfo): bool =
      let it = f.markOf("menu.Generate a reference...")
      let bar = f.markOf("menu.Operations")
      if it.size.x == 0:
        if wait mod 8 == 0: f.click(bar.centre)
      elif wait mod 6 == 3: f.click(it.centre)
      f.markOf("generate").size.x > 0 and f.markOf("generate.source").size.x > 0)

    step("the sweep source is the first", noop, proc (f: FrameInfo): bool =
      f.markOf("generate.f1").size.x > 0 and f.markOf("generate.pilot.n").size.x == 0)

    step("the source choice offers a trace of the record", noop, proc (f: FrameInfo): bool =
      if f.markOf("generate.source 1").size.x == 0:
        discard f.clickMark("generate.source")
      else:
        discard f.clickMark("generate.source 1")
      f.markOf("generate.pilot.n").size.x > 0)

    step("the record source's fields appear", noop, proc (f: FrameInfo): bool =
      f.markOf("generate.pilot.start").size.x > 0 and
        f.markOf("generate.pilot.length").size.x > 0 and f.markOf("generate.f1").size.x == 0)

    step("the pilot of the record on show is previewed", noop, proc (f: FrameInfo): bool =
      result = f.markOf("generate.preview.data").size.x > 0 and
        f.markOf("generate.spectrum.data").size.x > 0 and
        f.core.pilotPreview.samples.len > 1 and f.core.pilotPreview.problem.len == 0 and
        f.markOf("generate.pilot.record").size.x > 0)

    step("Generate stores the rule", noop, proc (f: FrameInfo): bool =
      if f.markOf("generate").size.x > 0: discard f.clickMark("generate.ok")
      var found = false
      for e in f.core.references.entries:
        if e.isPilot: found = true
      found and f.markOf("generate").size.x == 0)

    proc chooseAndOpen(f: FrameInfo) =
      var id = ""
      for e in f.core.references.entries:
        if e.isPilot: id = e.id
      f.apply Command(kind: ckSelectReference, refId: id)
      let s = f.core.sessions[0]
      let g = s.gathers[0].traces
      f.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
        plotTraces: @[s.base + g.b - 1, s.base + g.b])

    step("choosing it draws a correlation of the record on show", chooseAndOpen,
      proc (f: FrameInfo): bool =
      if window < 0 and f.core.plots.len > 0: window = f.core.plots.high
      if window < 0: return false
      let w = f.core.plots[window]
      result = w.result.gen > 0 and not w.waiting and w.result.plots.len > 0 and
        w.result.problem == "" and "auxiliary trace 1" in w.result.note
      if result:
        noteFirst = w.result.note
        asksFirst = w.asks)

    proc nextRecord(f: FrameInfo) =
      f.apply Command(kind: ckGather, panel: MainPanel, gather: 1)

    step("the next record has its own pilot", nextRecord, proc (f: FrameInfo): bool =
      let w = f.core.plots[window]
      result = w.asks > asksFirst and not w.waiting and w.result.problem == "" and
        w.result.plots.len > 0 and w.result.note != noteFirst)

    proc viewIt(f: FrameInfo) =
      for e in f.core.references.entries:
        if e.isPilot: f.apply Command(kind: ckViewReference, refId: e.id)

    step("View shows the pilot of the record on screen", viewIt, proc (f: FrameInfo): bool =
      f.core.refViews.len > 0 and not f.core.refViews[0].waiting and
        f.core.refViews[0].ys.len > 1 and f.core.refViews[0].record.len > 0 and
        f.markOf("reference.view.record").size.x > 0 and
        f.markOf("reference.view.fix").size.x > 0)

    step("Store this pilot as a fixed reference opens the store dialog", noop,
      proc (f: FrameInfo): bool =
      if f.markOf("store").size.x == 0: discard f.clickMark("reference.view.fix")
      f.markOf("store").size.x > 0 and f.markOf("store.ok").size.x > 0)

    step("the fixed copy is stored as a waveform", noop, proc (f: FrameInfo): bool =
      if f.markOf("store").size.x > 0: discard f.clickMark("store.ok")
      var fixed = false
      for e in f.core.references.entries:
        if not e.isPilot and e.samples > 1 and not e.origin.generated: fixed = true
      fixed and f.markOf("store").size.x == 0)

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
      elif overdue(wait, 600, since):
        failed = steps[at].name & " did not happen; pilot " &
          $f.core.pilotPreview.problem & " samples " & $f.core.pilotPreview.samples.len &
          (if window >= 0: " window " & f.core.plots[window].result.problem & " / " &
            f.core.plots[window].result.note else: "")
        createDir(root / ".scratch")
        discard f.savePng(root / ".scratch" / "pilotref-failed.png")
        f.stop()

    let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000), theme: forceDark,
      persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguipilotref: ", steps.len, " steps"

when isMainModule: main()
