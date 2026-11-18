## The Vibrator signature window's five plots fit their axes to the record shown, headless,
## on synthetic sweeps (no field data): record 1 a quiet good sweep, record 2 one with three
## times the force, a phase excursion and more distortion.
##
## At every state (first record, next record, back again, Judge changed, 100 % force and
## target force changed) each plot's axes, as ImPlot ended the frame with them
## (`axisLimitsOf`, not the state's computed range), are the data's fit (`xLimits`,
## `yLimits` of the curve plot), differ from the other record's where the data differ, and
## the phase axis's top covers the judged signal's own curve. The five plots' plotting
## areas have the same left and right edges (their time axes line up).
##
## Seen to fail: with the phase axis's top taken from the judged signal's raw phase and capped
## at 180 (signed phase of a ground force a half turn out), "the judged curve is clipped"; with
## a view found off its fit with no hand on the plot taken for the user's zoom (the old
## `seen`), "Force ... y drawn ..., fit ..." after another file is shown; with the plots'
## indents and widths left out, "plot areas differ".
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[analysis, geometry, state, references]
import viewSEG/view/[analysisview, curveplot, theme]
import viewSEG/ui/imgui/[app, curveplot as uiplot]
import utils/[fixtures, vibsynth, waiting]
import parseSEG

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

proc recordRows(kind: int): array[4, seq[float32]] =
  let big = kind == 1
  var gf = SynthSweep(amp: 1000, phaseDeg: 1.5, h2: 0.04)
  if kind == 2: # a ground force a half turn out: its phase flips between +180 and -180
    gf.phaseDeg = 180
    gf.h2 = 0.1
  if big:
    gf.amp = 3000
    gf.phaseDeg = 22
    gf.h2 = 0.15
    gf.burstAtS = 3.0
    gf.burstLenS = 1.0
    gf.burstPhaseDeg = 40
  let ref0 = gf.referenceOf
  var m = ref0
  (m.amp, m.phaseDeg) = (30.0 * (if big: 3.0 else: 1.0), 10.0)
  var b = ref0
  (b.amp, b.phaseDeg) = (25.0 * (if big: 3.0 else: 1.0), -170.0)
  [ref0.sweepRow, gf.sweepRow, m.sweepRow, b.sweepRow]

proc writeRecords(path: string; records: openArray[(float64, int)]) =
  var w = openSeismicWriter(path, SegyOutputOptions(revision: SegyRevision(
      major: 1, minor: 0),
    traceSorting: 1, measurementSystem: 1, text: @[
        "C01 viewSEG test fixture: synthetic sweeps"]))
  for (record, kind) in records:
    let rows = recordRows(kind)
    for n in 0 ..< 4:
      var k = initTraceKeys()
      (k.record, k.channel, k.t0Ms, k.intervalUs) = (record, float64(n + 1),
          0.0, 1000.0)
      k.traceCode = [21'i16, 20, 18, 19][n]
      k.status = tsAuxiliary
      w.writeTrace(k, rows[n])
  let log = w.close()
  doAssert log.len == 0, $log

func near(a, b: float64): bool = abs(a - b) <= 1e-6 * max(1.0, max(abs(a), abs(b)))

func biggest(ys: seq[float64]): float64 =
  result = 0
  for y in ys:
    if not y.isNaN: result = max(result, y)

func curveMax(p: CurvePlot; name: string): float64 =
  ## The largest finite value of the curve whose name starts with `name`; NaN for none.
  result = NaN
  for c in p.curves:
    if c.name.startsWith(name):
      for y in c.ys:
        if not y.isNaN and (result.isNaN or y > result): result = y

proc main*() =
  withFixtures fx:
    let path = fx.dir / "two-records.sgy"
    writeRecords(path, [(1.0, 0), (2.0, 1)])
    let small = fx.dir / "small.sgy"
    let large = fx.dir / "large.sgy"
    writeRecords(small, [(1.0, 0)])
    writeRecords(large, [(1.0, 1)])
    let flip = fx.dir / "flip.sgy"
    writeRecords(flip, [(1.0, 2)])
    var steps: seq[Step] = @[]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (
        f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var seen = 0
      result = proc (f: FrameInfo): bool =
        inc seen
        seen >= n
    var last: seq[Span] # the y limits of the last check, per plot
    proc check(f: FrameInfo; what: string; changed: bool): bool =
      ## Each plot's drawn axes are its data's fit; `changed`: no y axis is as at the last check
      ## (where the plot's data differ).
      let w = f.core.plots[0]
      doAssert not w.waiting and w.result.problem.len == 0, what & ": " &
          w.result.problem
      let plots = w.result.curvePlots(f.theme, f.core.settings.units)
      doAssert plots.len == 5, what & ": " & $plots.len & " plots"
      var now: seq[Span] = @[]
      var lefts, rights: seq[float32] = @[]
      for i, p in plots:
        let id = "new plot 1.plot " & $i
        let (x, y) = axisLimitsOf(id)
        let (xl, yl) = (p.xLimits, p.yLimits)
        doAssert near(x.lo, xl.lo) and near(x.hi, xl.hi),
          what & ": " & p.yLabel & " x drawn " & $x & ", fit " & $xl
        doAssert near(y.lo, yl.lo) and near(y.hi, yl.hi),
          what & ": " & p.yLabel & " y drawn " & $y & ", fit " & $yl &
              " zoomed " & $axisZoomedOf(id)
        now.add y
        let r = f.markOf(id & ".data")
        if r.size.x == 0: return false # a frame the plot was not drawn in: look again
        lefts.add r.pos.x
        rights.add r.pos.x + r.size.x
      for i in 1 ..< plots.len:
        doAssert abs(lefts[i] - lefts[0]) <= 1 and abs(rights[i] - rights[0]) <= 1,
          what & ": plot areas differ: " & $lefts & " " & $rights
      # the phase axis holds the judged signal's own curve
      let ph = plots[0]
      let judged = if w.result.judged == "GF": "GF" else: "GF (M, B)"
      for c in ph.curves:
        if c.name == judged or c.name == w.result.judged:
          for y in c.ys:
            if not y.isNaN:
              doAssert y <= now[0].hi + 1e-9 and y >= now[0].lo - 1e-9,
                what & ": the judged curve is clipped: " & $y & " in " & $now[0]
      if changed and last.len == 5:
        for i in 0 ..< 5:
          if i in [3, 4]: continue # frequency: the same sweep; distortion: its fit is the tapers
          doAssert not (near(now[i].lo, last[i].lo) and near(now[i].hi, last[
              i].hi)),
            what & ": plot " & $i & " kept the axis " & $now[i]
      last = now
      true
    step("the file shown", noop, proc (f: FrameInfo): bool =
      f.core.sessions.len > 0 and f.core.panels[f.core.findPanel(
          MainPanel)].laidOut)
    step("a vibrator signature", proc (f: FrameInfo) =
      let b = f.core.sessions[0].base
      var p = AnalysisParams(forceHundredPct: 1000, reactionMassKg: 3600,
          baseplateMassKg: 1800)
      f.apply(Command(kind: ckOpenPlot, plotView: avVibrator,
        plotTraces: @[b, b + 1, b + 2, b + 3], plotParams: p)),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.problem.len == 0 and f.core.plots[
              0].result.plots.len == 5)
    step("settle", noop, after(25))
    step("record 1", noop, proc (f: FrameInfo): bool = f.check("record 1", false))
    step("the next record", proc (f: FrameInfo) =
      f.apply(Command(kind: ckGather, panel: MainPanel, gather: 1)),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.plots.len == 5 and
          f.core.plots[0].result.plots[1].curves[0].ys.biggest > 2000)
    step("settle 2", noop, after(25))
    step("record 2 (larger)", noop, proc (f: FrameInfo): bool = f.check(
        "record 2", true))
    step("the previous record", proc (f: FrameInfo) =
      f.apply(Command(kind: ckGather, panel: MainPanel, gather: 0)),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.plots.len == 5 and
          f.core.plots[0].result.plots[1].curves[0].ys.biggest < 2000)
    step("settle 3", noop, after(25))
    step("record 1 again (smaller)", noop, proc (f: FrameInfo): bool = f.check(
        "record 1 again", true))
    step("another file shown, larger", proc (f: FrameInfo) =
      f.apply(Command(kind: ckShowFile, panel: MainPanel, path: large)),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.plots.len == 5 and
          f.core.plots[0].result.plots[1].curves[0].ys.biggest > 2000)
    step("settle 6", noop, after(25))
    step("another file (larger)", noop, proc (f: FrameInfo): bool = f.check(
        "file large", true))
    step("another file shown, smaller", proc (f: FrameInfo) =
      f.apply(Command(kind: ckShowFile, panel: MainPanel, path: small)),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.plots.len == 5 and
          f.core.plots[0].result.plots[1].curves[0].ys.biggest < 2000)
    step("settle 7", noop, after(25))
    step("another file (smaller)", noop, proc (f: FrameInfo): bool = f.check(
        "file small", true))
    step("judged on M and B, signed phase", proc (f: FrameInfo) =
      var p = f.core.plots[0].params
      p.roles.judge = joWeighted
      p.roles.massPolarity = poReversed
      p.phaseShow = psSigned
      f.apply(Command(kind: ckPlotDisplay, plot: 1, plotParams: p)),
      proc (f: FrameInfo): bool =
        f.core.plots[0].result.judged == "GF (M, B)" and not f.core.plots[0].waiting)
    step("settle 4", noop, after(25))
    step("judge changed", noop, proc (f: FrameInfo): bool = f.check(
        "judge changed", false))
    step("100 % force and target changed", proc (f: FrameInfo) =
      var p = f.core.plots[0].params
      p.roles.massPolarity = poAsRecorded
      p.forceHundredWeighted = 3.0e7
      p.targetPct = 60
      f.apply(Command(kind: ckPlotDisplay, plot: 1, plotParams: p)),
      proc (f: FrameInfo): bool = not f.core.plots[0].waiting)
    step("settle 5", noop, after(25))
    step("force settings changed", noop, proc (f: FrameInfo): bool =
      f.check("force settings changed", false))
    step("a ground force half a turn out, signed phase", proc (f: FrameInfo) =
      var p = f.core.plots[0].params
      p.roles.judge = joRecorded
      p.roles.massPolarity = poAsRecorded
      p.phaseShow = psSigned
      f.apply(Command(kind: ckPlotDisplay, plot: 1, plotParams: p))
      f.apply(Command(kind: ckShowFile, panel: MainPanel, path: flip)),
      proc (f: FrameInfo): bool =
        f.core.plots[0].result.judged == "GF" and not f.core.plots[
            0].waiting and
          f.core.plots[0].params.phaseShow == psSigned and
          f.core.plots[0].result.plots.len == 5 and
          f.core.plots[0].result.plots[0].curves.len > 0 and
          f.core.plots[0].result.plots[0].curves[0].ys.biggest > 170)
    step("settle 8", noop, after(25))
    step("a ground force half a turn out", noop, proc (f: FrameInfo): bool =
      f.check("a ground force half a turn out", true))
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
          let shot = getEnv("VIBFIT_SHOT")
          if shot.len > 0 and steps[at - 1].name == "record 2 (larger)":
            discard f.savePng(shot)
        elif overdue(wait, 600, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1050),
      theme: forceDark, persist: true, configDir: some(fx.dir / "config"),
      logDir: some(fx.dir / "logs"), userThemeDir: some(fx.dir /
          "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguivibrefit: ok"

when isMainModule:
  main()
