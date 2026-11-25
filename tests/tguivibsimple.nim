## The Vibrator signature window, simplified, on synthetic sweeps (no field data): one record
## of four traces (reference, ground force, reaction mass, baseplate) that is a good sweep, the
## next one with a stretch of high phase and a force 22 % low.
##
## - by default the plots draw the judged ground force alone: four plots, no limit lines, no
##   table of every signal; Setup is open until the 100 % force is set and folds then;
## - "Judge" (both ground forces exist, the masses typed) is at the top, not inside Setup; the
##   one chosen is "GF" in every plot (and the verdict says which it is);
## - "Set from this sweep" puts the sweep's average force over the target's share into the
##   100 % force box of the signal judged (the average then reads 100 % of the target);
## - Details adds the other ground force, M and B and the table of every signal;
## - a record past a peak limit draws the failing windows in the error colour (pixels of it in
##   the phase plot), the good one none.
##
## `VIBSIMPLE_SHOT` and `VIBSIMPLE_SHOT_DETAILS` name PNG files the default and the Details
## views of the bad record are saved to.
##
## Seen to fail: with the failing stretches left out, "no error-colour pixel in the phase
## plot"; with Judge left inside Setup, "the Judge box is inside Setup"; with Details ignored,
## "details did not happen".
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[analysis, geometry, state]
import viewSEG/view/[analysisview, theme]
import viewSEG/ui/imgui/app
import utils/[fixtures, vibsynth, waiting]
import parseSEG

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

proc recordRows(bad: bool): array[4, seq[float32]] =
  var gf = SynthSweep(amp: 1000, phaseDeg: 1.5, h2: 0.04, delayMs: 115)
  if bad:
    gf.amp = 780
    gf.burstAtS = 3.0
    gf.burstLenS = 1.0
    gf.burstPhaseDeg = 30
  let ref0 = gf.referenceOf
  var m = ref0
  (m.amp, m.phaseDeg) = (30.0, 10.0)
  var b = ref0
  (b.amp, b.phaseDeg) = (25.0, -170.0)
  [ref0.sweepRow, gf.sweepRow, m.sweepRow, b.sweepRow]

proc writeTwoRecords(path: string) =
  var w = openSeismicWriter(path, SegyOutputOptions(revision: SegyRevision(
      major: 1, minor: 0),
    traceSorting: 1, measurementSystem: 1, text: @["C01 viewSEG test fixture: synthetic sweeps"]))
  for (record, bad) in [(1.0, false), (2.0, true)]:
    let rows = recordRows(bad)
    for n in 0 ..< 4:
      var k = initTraceKeys()
      (k.record, k.channel, k.t0Ms, k.intervalUs) = (record, float64(n + 1), 0.0, 1000.0)
      k.traceCode = [21'i16, 20, 18, 19][n]
      k.status = tsAuxiliary
      w.writeTrace(k, rows[n])
  let log = w.close()
  doAssert log.len == 0, $log

proc centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc main*() =
  withFixtures fx:
    let path = fx.dir / "two-records.sgy"
    writeTwoRecords(path)
    var steps: seq[Step] = @[]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var seen = 0
      result = proc (f: FrameInfo): bool =
        inc seen
        seen >= n
    proc click(mark: string) =
      step("click " & mark, proc (f: FrameInfo) =
        let c = f.markOf(mark).centre
        f.moveMouse(c)
        f.pressMouse(c, true)
        f.pressMouse(c, false), after(4))
    proc errorPixels(f: FrameInfo; plot: int): int =
      ## The pixels of the error colour in the plotting area of plot `plot`.
      let d = f.markOf("new plot 1.plot " & $plot & ".data")
      let c = f.theme.roles[rlError]
      for y in int(d.pos.y) ..< int(d.pos.y + d.size.y):
        for x in int(d.pos.x) ..< int(d.pos.x + d.size.x):
          if distance(f.readPixel(x, y), c) <= 12: inc result
    func ready(f: FrameInfo): bool =
      f.core.plots.len == 1 and not f.core.plots[0].waiting and
        f.core.plots[0].result.problem.len == 0 and f.core.plots[0].result.qc.rows.len == 6
    step("the file shown", noop, proc (f: FrameInfo): bool =
      f.core.sessions.len > 0 and f.core.panels[f.core.findPanel(MainPanel)].laidOut)
    step("a vibrator signature", proc (f: FrameInfo) =
      let b = f.core.sessions[0].base
      let p = AnalysisParams(reactionMassKg: 3600, baseplateMassKg: 1800)
      f.apply(Command(kind: ckOpenPlot, plotView: avVibrator,
        plotTraces: @[b, b + 1, b + 2, b + 3], plotParams: p)), ready)
    step("settle", noop, after(25))
    step("the default view", noop, proc (f: FrameInfo): bool =
      let w = f.core.plots[0]
      doAssert w.result.plots.len == 4, $w.result.plots.len & " plots"
      doAssert not w.params.details
      for p in w.result.plots:
        for c in p.curves: doAssert c.style != csLimit, "a limit line: " & c.name
      doAssert f.markOf("new plot 1.table").size.x == 0, "the table of every signal is shown"
      # the settings are behind the wheel: nothing of them is in the window until it is opened
      doAssert f.markOf("new plot 1.wheel").size.x > 0 and f.markOf("new plot 1.roles").size.x > 0,
        "no strip"
      doAssert f.markOf("new plot 1.judge").size.x == 0, "the Judge box is not behind the wheel"
      doAssert f.markOf("new plot 1.set hundred").size.x == 0, "settings in the window"
      # one ground force, simply GF, in every plot
      for p in w.result.plots:
        for c in p.curves:
          doAssert c.name notin ["GF as recorded", "GF from M and B", "GF (M, B)"], c.name
      true)
    click("new plot 1.wheel")
    step("the wheel: Judge is in its Ground force group", noop, proc (f: FrameInfo): bool =
      let judge = f.markOf("new plot 1.judge")
      result = judge.size.x > 0
      if result:
        doAssert f.markOf("new plot 1.group Ground force").size.x > 0
        # a SEG-Y record: the masses group, no signature file's groups, no identity line
        for g in ["Masses", "Force"]:
          doAssert f.markOf("new plot 1.group " & g).size.x > 0, "no group " & g
        doAssert f.markOf("new plot 1.group Accelerometer set").size.x == 0 and
          f.markOf("new plot 1.group Weights from the header").size.x == 0 and
          f.markOf("new plot 1.masses note").size.x == 0 and
          f.markOf("new plot 1.identity").size.x == 0, "a group of a signature file"
        doAssert judge.pos.y > f.markOf("new plot 1.group Ground force").pos.y,
          "the Judge box (both ground forces exist) is under its group's heading")
    click("new plot 1.set hundred")
    step("the 100 % force set from the sweep", noop, proc (f: FrameInfo): bool =
      let w = f.core.plots[0]
      result = not w.params.forceHundredPct.isNaN and ready(f)
      if result:
        let average = w.result.qc.stats.avgForce
        doAssert average > 0
        # (the box was set from the average, so the average reads 100 % of the target)
        doAssert abs(w.params.forceHundredPct - average) < 1e-6 * average or
          abs(w.result.qc.stats.avgForcePct - 100) < 0.5,
          $w.params.forceHundredPct & " / " & $average)
    step("settle after set", noop, after(25))
    click("new plot 1.verdict") # closes the wheel
    step("the force in %", noop, proc (f: FrameInfo): bool =
      let w = f.core.plots[0]
      doAssert f.markOf("new plot 1.wheel popover").size.x == 0, "the wheel stays open"
      doAssert abs(w.result.qc.stats.avgForcePct - 100) < 0.5, $w.result.qc.stats.avgForcePct
      doAssert w.result.plots[1].yLabel == "Force (% of 100 % force)", w.result.plots[1].yLabel
      doAssert w.result.qc.verdict == qvPass, w.result.qc.line
      doAssert f.errorPixels(0) == 0, "an error-colour stretch on the good record"
      true)
    step("the next record", proc (f: FrameInfo) =
      f.apply(Command(kind: ckGather, panel: MainPanel, gather: 1)),
      proc (f: FrameInfo): bool = ready(f) and f.core.plots[0].result.qc.verdict == qvFail)
    step("settle again", noop, after(25))
    click("new plot 1.wheel")
    step("the wheel's picture", noop, proc (f: FrameInfo): bool =
      result = f.markOf("new plot 1.group Masses").size.x > 0
      let shot = getEnv("VIBSIMPLE_SHOT_WHEEL")
      if result and shot.len > 0: discard f.savePng(shot)
    )
    click("new plot 1.verdict")
    step("the bad record: failing stretches in the error colour", noop,
      proc (f: FrameInfo): bool =
      let w = f.core.plots[0]
      doAssert w.result.qc.verdict == qvFail, w.result.qc.line
      var stretches = 0
      for c in w.result.plots[0].curves:
        if c.style == csFail: inc stretches
      doAssert stretches == 1, $stretches & " failing stretches in the phase plot"
      doAssert f.errorPixels(0) > 20, "no error-colour pixel in the phase plot"
      let shot = getEnv("VIBSIMPLE_SHOT")
      if shot.len > 0: discard f.savePng(shot)
      true)
    click("new plot 1.details")
    step("details on", noop, proc (f: FrameInfo): bool =
      let w = f.core.plots[0]
      result = w.params.details and ready(f) and w.result.plots.len == 5 and
        f.markOf("new plot 1.table").size.x > 0
      if result:
        var names: seq[string] = @[]
        for c in w.result.plots[0].curves: names.add c.name
        doAssert "GF as recorded" in names and "GF from M and B" in names and "M" in names,
          $names)
    step("settle details", noop, after(25))
    step("the Details view", noop, proc (f: FrameInfo): bool =
      let shot = getEnv("VIBSIMPLE_SHOT_DETAILS")
      if shot.len > 0: discard f.savePng(shot)
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
    let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1050),
      theme: forceDark, persist: true, configDir: some(fx.dir / "config"),
      logDir: some(fx.dir / "logs"), userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguivibsimple: ok"

when isMainModule:
  main()
