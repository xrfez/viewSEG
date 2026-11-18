## The Vibrator signature window at its default size, on synthetic sweeps (no field data):
## one record of four traces (reference, ground force, reaction mass, baseplate) that is a
## good sweep, the next a bad one (a ground force 20 % low, a stretch of high phase).
##
## - at the default size nothing scrolls for one unit: the window and its plots child have
##   no scrollbar, the verdict line, the limits table and each of the four plots are in view
##   (inside the window, non-zero rectangles);
## - the first record says PASS, the limits table has a tick as text on every judged row;
## - stepping to the next record keeps the window's place and size, still nothing scrolls,
##   and the verdict reads FAIL naming the worst failing value (both with a stored reference
##   put 115 ms into the record, found by correlation and said);
## - the three boxes the verdict needs are always in view with their units: Top frequency
##   (Hz), 100 % force =, window (ms), and the force rows say which box to fill when empty.
##
## `VIBQC_SHOT_PASS` and `VIBQC_SHOT_FAIL` name PNG files the two states are saved to.
##
## Seen to fail: with the note drawn open and the plots at their old least height (nine
## lines), "nothing scrolls" failed (the plots child scrolled); with the limits table drawn
## only when limits are on, "the limits table is in view" failed.
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[analysis, geometry, state, references]
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
    traceSorting: 1, measurementSystem: 1, text: @[
        "C01 viewSEG test fixture: synthetic sweeps"]))
  for (record, bad) in [(1.0, false), (2.0, true)]:
    let rows = recordRows(bad)
    for n in 0 ..< 4:
      var k = initTraceKeys()
      (k.record, k.channel, k.t0Ms, k.intervalUs) = (record, float64(n + 1),
          0.0, 1000.0)
      k.traceCode = [21'i16, 20, 18, 19][n]
      k.status = tsAuxiliary
      w.writeTrace(k, rows[n])
  let log = w.close()
  doAssert log.len == 0, $log

func inside(r, win: Rect): bool =
  r.size.x > 0 and r.size.y > 0 and r.pos.x >= win.pos.x - 1 and r.pos.y >=
      win.pos.y - 1 and
    r.pos.x + r.size.x <= win.pos.x + win.size.x + 1 and
    r.pos.y + r.size.y <= win.pos.y + win.size.y + 1

proc main*() =
  withFixtures fx:
    let path = fx.dir / "two-records.sgy"
    writeTwoRecords(path)
    var steps: seq[Step] = @[]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (
        f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    var refId = ""
    var firstWin: Rect
    proc after(n: int): proc (f: FrameInfo): bool =
      var seen = 0
      result = proc (f: FrameInfo): bool =
        inc seen
        seen >= n
    proc fits(f: FrameInfo; what: string) =
      ## The unit in view and nothing to scroll, as the marks say.
      let win = f.markOf("new plot 1")
      doAssert win.size.x > 0, what & ": no window"
      doAssert f.markOf("new plot 1.scrolls").size.x == 0, what & ": the window scrolls"
      doAssert f.markOf("new plot 1.plots scroll").size.x == 0,
        what & ": the plots scroll in a child of their own"
      for part in ["verdict", "qc table", "top frequency", "force target", "qc window"]:
        doAssert f.markOf("new plot 1." & part).inside(win), what & ": " &
            part &
          " is not in view: " & $f.markOf("new plot 1." & part) & " in " & $win
      let plots = f.core.plots[0].result.curvePlots(f.theme,
          f.core.settings.units)
      doAssert plots.len == 4, what & ": " & $plots.len & " plots"
      for i in 0 ..< plots.len:
        doAssert f.markOf("new plot 1.plot " & $i & ".data").inside(win), what &
            ": plot " &
          $i & " is not in view: " & $f.markOf("new plot 1.plot " & $i & ".data")
    step("the file shown", noop, proc (f: FrameInfo): bool =
      f.core.sessions.len > 0 and f.core.panels[f.core.findPanel(
          MainPanel)].laidOut)
    step("a reference stored 115 ms in", proc (f: FrameInfo) =
      f.apply(Command(kind: ckStoreReference, refStore: StoredReference(
        name: "pilot",
        trace: f.core.sessions[0].base, fromMs: 115, toMs: -1))),
      proc (f: FrameInfo): bool =
        for e in f.core.references.entries:
          if e.name == "pilot": refId = e.id
        refId.len > 0)
    step("chosen", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelectReference, refId: refId)),
      proc (f: FrameInfo): bool = f.core.chosenReference == refId)
    step("a vibrator signature", proc (f: FrameInfo) =
      let b = f.core.sessions[0].base
      var p = AnalysisParams(forceHundredPct: 1000)
      f.apply(Command(kind: ckOpenPlot, plotView: avVibrator,
        plotTraces: @[b, b + 1, b + 2, b + 3], plotParams: p)),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.problem.len == 0 and f.core.plots[
              0].result.qc.rows.len == 6)
    step("settle", noop, after(25))
    step("a good record: PASS, all in view", noop, proc (f: FrameInfo): bool =
      let r = f.core.plots[0].result
      doAssert r.qc.verdict == qvPass, "the good record: " & r.qc.line
      doAssert r.alignment.kind == "aligned" and abs(r.alignment.shiftMs -
          115) < 1.5,
        "alignment: " & $r.alignment
      doAssert "stored reference aligned to the recorded reference: +115 ms" in
          r.note.toLowerAscii, r.note
      let shot = getEnv("VIBQC_SHOT_PASS")
      if shot.len > 0: discard f.savePng(shot)
      f.fits("the good record")
      firstWin = f.markOf("new plot 1")
      for x in r.qc.tableOf[1 .. ^1]: doAssert x[3] == "✓", $x
      true)
    step("the next record", proc (f: FrameInfo) =
      f.apply(Command(kind: ckGather, panel: MainPanel, gather: 1)),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.qc.verdict == qvFail)
    step("settle again", noop, after(25))
    step("a bad record: FAIL, all in view, the window as it was", noop,
      proc (f: FrameInfo): bool =
      let r = f.core.plots[0].result
      doAssert r.qc.verdict == qvFail and r.qc.line.startsWith("✗ FAIL"), r.qc.line
      doAssert "average force" in r.qc.line or "peak phase" in r.qc.line, r.qc.line
      let shot = getEnv("VIBQC_SHOT_FAIL")
      if shot.len > 0: discard f.savePng(shot)
      f.fits("the bad record")
      let win = f.markOf("new plot 1")
      doAssert win.pos == firstWin.pos and win.size == firstWin.size,
        "the window moved or changed size: " & $firstWin & " -> " & $win
      var crosses = 0
      for x in r.qc.tableOf[1 .. ^1]:
        if x[3] == "✗": inc crosses
      doAssert crosses >= 2, "crosses " & $crosses
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
      logDir: some(fx.dir / "logs"), userThemeDir: some(fx.dir /
          "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguivibqc: ok"

when isMainModule:
  main()
