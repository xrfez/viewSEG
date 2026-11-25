## The Vibrator signature window judges against the plan, on synthetic sweeps (no field data):
## a file whose pilot sweeps 8-80 Hz in 10 s, its ground force following that pilot, against a
## stored reference (the plan) that sweeps the same band in 12 s.
##
## - the verdict fails first on the recorded pilot ("the recorded pilot is not the project's
##   reference sweep"), says how the two sweeps differ, and is in view whole (wrapped, never
##   cut);
## - the phase plot has two lines: the ground force against the file's reference (near 0°)
##   and against the stored reference (far off), in two colours of the theme's series; the
##   frequency plot has three: the file's reference, the stored reference and the ground force;
## - the phase plot's long names stand in rows above it, not over its lines; the readout under
##   the plots names them short ("GF/stored ref") and is in view whole;
## - with no reference chosen, the verdict says it was judged against the file's own pilot.
##
## `REFPLAN_SHOT_FAIL` and `REFPLAN_SHOT_OWN` name PNG files the two states are saved to.
##
## Seen to fail: with the verdict drawn as one fitted line (cut with "..."), "the verdict is
## one line"; with the legend in the phase plot's corner and the readout one line of the long
## names, "the legend is not above the phase plot" and "the readout is cut".
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[analysis, geometry, state, references, vibanalysis, vibjudge]
import viewSEG/view/[analysisview, theme]
import viewSEG/ui/imgui/app
import utils/[fixtures, vibsynth, waiting]

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

proc unitFile(path: string; seconds: float64) =
  ## A SEG-Y of one record: Ref, GF (1° off its pilot), M and B of an 8-80 Hz sweep.
  let gf = SynthSweep(f0: 8, f1: 80, seconds: seconds, tailS: 0.001, amp: 1000, phaseDeg: 1,
    h2: 0.02)
  let ref0 = gf.referenceOf
  var m = ref0
  (m.amp, m.phaseDeg) = (30.0, 10.0)
  var b = ref0
  (b.amp, b.phaseDeg) = (25.0, -170.0)
  writeVibSegy(path, [ref0.sweepRow, gf.sweepRow, m.sweepRow, b.sweepRow], 1.0)

func inside(r, win: Rect): bool =
  r.size.x > 0 and r.size.y > 0 and r.pos.x >= win.pos.x - 1 and r.pos.y >= win.pos.y - 1 and
    r.pos.x + r.size.x <= win.pos.x + win.size.x + 1 and
    r.pos.y + r.size.y <= win.pos.y + win.size.y + 1

func names(r: AnalysisResult; plot: int): seq[string] =
  for c in r.plots[plot].curves:
    if c.style == csLine: result.add c.name

proc main*() =
  withFixtures fx:
    let plan = fx.dir / "plan-12s.sgy"
    let file = fx.dir / "file-10s.sgy"
    unitFile(plan, 12)
    unitFile(file, 10)
    var steps: seq[Step] = @[]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var seen = 0
      result = proc (f: FrameInfo): bool =
        inc seen
        seen >= n
    proc sessionOf(f: FrameInfo; path: string): int =
      result = -1
      for i, s in f.core.sessions:
        if s.path == path: result = i
    var refId = ""
    proc whole(f: FrameInfo; what: string) =
      ## The verdict in view, wrapped whole: no line of it cut off.
      let win = f.markOf("new plot 1")
      doAssert f.markOf("new plot 1.verdict").inside(win), what & ": the verdict is not in view"
      doAssert f.markOf("new plot 1.verdict").size.y > 20, what & ": the verdict is one line"
    step("the plan shown", noop, proc (f: FrameInfo): bool = f.sessionOf(plan) >= 0)
    step("the plan stored", proc (f: FrameInfo) =
      f.apply(Command(kind: ckStoreReference, refStore: StoredReference(name: "plan 12 s",
        trace: f.core.sessions[f.sessionOf(plan)].base, fromMs: 0, toMs: -1))),
      proc (f: FrameInfo): bool =
        for e in f.core.references.entries:
          if e.name == "plan 12 s": refId = e.id
        refId.len > 0)
    step("chosen", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelectReference, refId: refId)),
      proc (f: FrameInfo): bool = f.core.chosenReference == refId)
    step("the 10 s file shown", proc (f: FrameInfo) =
      f.apply(Command(kind: ckShowFile, panel: MainPanel, path: file)),
      proc (f: FrameInfo): bool =
        f.sessionOf(file) >= 0 and f.core.panels[f.core.findPanel(MainPanel)].laidOut)
    step("a vibrator signature of the 10 s file", proc (f: FrameInfo) =
      let b = f.core.sessions[f.sessionOf(file)].base
      f.apply(Command(kind: ckOpenPlot, plotView: avVibrator,
        plotTraces: @[b, b + 1, b + 2, b + 3],
        plotParams: AnalysisParams(forceHundredPct: 1000, setupOpen: true, setupSet: true))),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.problem.len == 0 and f.core.plots[0].result.qc.rows.len == 6)
    step("settle", noop, after(25))
    step("against the 12 s plan: the pilot fails, two phase lines, three frequency lines", noop,
      proc (f: FrameInfo): bool =
      let r = f.core.plots[0].result
      doAssert r.qc.verdict == qvFail and r.qc.line.startsWith("✗ FAIL: the recorded pilot " &
        "is not the project's reference sweep"), r.qc.line
      doAssert names(r, 0) == @["GF " & AgainstFile, "GF " & AgainstStored, RecordedRef],
        $names(r, 0)
      doAssert names(r, 2) == @[FileRefName, StoredRefName, "GF"], $names(r, 2)
      let plots = r.curvePlots(f.theme, f.core.settings.units)
      doAssert plots[0].legend and plots[0].curves[0].colour != plots[0].curves[1].colour
      # the phase plot's long names in rows above it, not over its lines; short in the readout
      doAssert plots[0].legendAbove and not plots[2].legendAbove
      doAssert plots[0].curves[0].short == "GF/file ref" and
        plots[0].curves[1].short == "GF/stored ref", plots[0].curves[0].short
      let row = f.markOf("new plot 1.plot 0.legendrow")
      let area = f.markOf("new plot 1.plot 0.data")
      doAssert row.size.y > 0 and row.pos.y + row.size.y <= area.pos.y + 1,
        "the legend is not above the phase plot: " & $row & " " & $area
      f.whole("against the plan")
      true)
    step("the cursor held on the phase plot", proc (f: FrameInfo) =
      f.apply(Command(kind: ckPlotCursor, plot: f.core.plots[0].id, plotCursorOn: 0,
        plotCursor: PlotCursor(held: true, x: 560, y: 0))),
      after(10))
    step("the readout in view whole", noop, proc (f: FrameInfo): bool =
      let text = f.plotWindows.readoutOf(f.core.plots[0].id)
      doAssert "GF/stored ref" in text and AgainstStored notin text, text
      let win = f.markOf("new plot 1")
      let readout = f.markOf("new plot 1.readout")
      doAssert readout.pos.x + readout.size.x <= win.pos.x + win.size.x and
        readout.pos.y + readout.size.y <= win.pos.y + win.size.y,
        "the readout is cut: " & $readout & " in " & $win
      let shot = getEnv("REFPLAN_SHOT_FAIL")
      if shot.len > 0: discard f.savePng(shot)
      true)
    step("no reference chosen", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelectReference, refId: "")),
      proc (f: FrameInfo): bool =
        f.core.chosenReference.len == 0 and not f.core.plots[0].waiting and
          f.core.plots[0].result.qc.ownPilot)
    step("settle again", noop, after(25))
    step("against its own pilot: said", noop, proc (f: FrameInfo): bool =
      let r = f.core.plots[0].result
      doAssert r.qc.line.endsWith("; " & OwnPilotWords), r.qc.line
      doAssert names(r, 0) == @["GF " & AgainstFile], $names(r, 0)
      let shot = getEnv("REFPLAN_SHOT_OWN")
      if shot.len > 0: discard f.savePng(shot)
      f.whole("against its own pilot")
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
        elif overdue(wait, 600, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(openPaths: @[plan], windowSize: (1600, 1050),
      theme: forceDark, persist: true, configDir: some(fx.dir / "config"),
      logDir: some(fx.dir / "logs"), userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguirefplan: ok"

when isMainModule:
  main()
