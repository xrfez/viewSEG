## The Vibrator signature window held at the sizes it is used at, on synthetic sweeps (no field
## data): floating at its default (780 x 980 points) and as a dock pane would hold it in a wide,
## short centre pane (1230 x 850), one 4-trace unit, a record that passes then one that fails,
## the project reference named with 40 characters:
##
## - in each size and for each record nothing scrolls (no scrollbar of the window, none of the
##   plots' own region) and the verdict, the limits table and the bottom of each of the four plots
##   are inside the window; the plots share what the rest leaves;
## - with the note folded nothing above the limits table takes more than one line, whatever the
##   length of the reference's name (cut with an ellipsis, the whole in a tooltip);
## - the limits table's first column is the sign (so it can never be cut off on the right);
## - the folded state of the roles and the note is part of the window's options and is kept in the
##   settings.
##
## `VIBQC2_DOCKED` and `VIBQC2_FLOAT` name PNG files the 1230 x 850 and the default views are
## saved to.
##
## Seen to fail: with the plots' least height at nine lines, the 1230 x 850 pane scrolled
## ("the plots scroll in a child of their own"); with the long reference name wrapped, the line
## above the table was two lines high.
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[analysis, geometry, state, references]
import viewSEG/view/[analysisview, theme]
import viewSEG/ui/imgui/[app, plotwindows]
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
        doAssert f.markOf("new plot 1." & part).inside(win), what & ": " & part &
          " is not in view: " & $f.markOf("new plot 1." & part) & " in " & $win
      let plots = f.core.plots[0].result.curvePlots(f.theme, f.core.settings.units)
      doAssert plots.len == 4, what & ": " & $plots.len & " plots"
      for i in 0 ..< plots.len:
        let d = f.markOf("new plot 1.plot " & $i & ".data")
        doAssert d.inside(win), what & ": plot " & $i & " is not in view: " & $d
        doAssert d.size.y >= 50, what & ": plot " & $i & " is only " & $d.size.y & " high"
      # nothing above the table wraps: each of these lines is one line high
      for part in ["verdict", "roles line", "against", "top frequency warning", "warning"]:
        let r = f.markOf("new plot 1." & part)
        doAssert r.size.y <= 26, what & ": " & part & " is " & $r.size.y & " high (wrapped)"
      # the sign is the table's first column
      doAssert f.core.plots[0].result.qc.tableOf[0][0] == "Met"
    proc phase(label: string; size: (float32, float32); shot: string) =
      ## The window held at `size` (0: its own): a good record, a bad one, the good again.
      step(label & ": sized", proc (f: FrameInfo) =
        forcedVibratorSize = size, after(30))
      step(label & ": a good record", noop, proc (f: FrameInfo): bool =
        let r = f.core.plots[0].result
        result = not f.core.plots[0].waiting and r.qc.verdict == qvPass
        if result:
          let path = getEnv(shot)
          if path.len > 0: discard f.savePng(path)
          f.fits(label & " (good)")
          if size[0] > 0:
            let win = f.markOf("new plot 1")
            doAssert abs(win.size.x - size[0]) < 3 and abs(win.size.y - size[1]) < 3,
              label & ": the window is " & $win.size & ", not " & $size)
      step(label & ": the next record", proc (f: FrameInfo) =
        f.apply(Command(kind: ckGather, panel: MainPanel, gather: 1)),
        proc (f: FrameInfo): bool =
          result = not f.core.plots[0].waiting and f.core.plots[0].result.qc.verdict == qvFail
          if result: f.fits(label & " (bad)"))
      step(label & ": back to the first", proc (f: FrameInfo) =
        f.apply(Command(kind: ckGather, panel: MainPanel, gather: 0)),
        proc (f: FrameInfo): bool =
          not f.core.plots[0].waiting and f.core.plots[0].result.qc.verdict == qvPass)
    step("the file shown", noop, proc (f: FrameInfo): bool =
      f.core.sessions.len > 0 and f.core.panels[f.core.findPanel(MainPanel)].laidOut)
    step("a reference with a long name stored", proc (f: FrameInfo) =
      f.apply(Command(kind: ckStoreReference, refStore: StoredReference(
        name: "Project reference of the north survey, July",
        trace: f.core.sessions[0].base, fromMs: 115, toMs: -1))),
      proc (f: FrameInfo): bool =
        for e in f.core.references.entries:
          if e.name.len == 43: refId = e.id
        refId.len > 0)
    step("chosen", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelectReference, refId: refId)),
      proc (f: FrameInfo): bool = f.core.chosenReference == refId)
    step("a vibrator signature", proc (f: FrameInfo) =
      let b = f.core.sessions[0].base
      f.apply(Command(kind: ckOpenPlot, plotView: avVibrator,
        plotTraces: @[b, b + 1, b + 2, b + 3],
        plotParams: AnalysisParams(forceHundredPct: 1000))),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.problem.len == 0 and f.core.plots[0].result.qc.rows.len == 6)
    step("settle", noop, after(25))
    phase("floating", (0'f32, 0'f32), "VIBQC2_FLOAT")
    phase("docked", (1230'f32, 850'f32), "VIBQC2_DOCKED")
    # the folded state is part of the window's options, kept in the settings
    step("the note opened", proc (f: FrameInfo) =
      let r = f.markOf("new plot 1.against")
      let c = vec2(r.pos.x + 20, r.pos.y + r.size.y / 2)
      f.moveMouse(c)
      f.pressMouse(c, true)
      f.pressMouse(c, false),
      proc (f: FrameInfo): bool =
        result = f.core.plots[0].params.noteOpen
        if result:
          doAssert f.core.settings.plotOptions.vibrator.noteOpen, "not kept in the settings")
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
    let code = run(RunOptions(openPaths: @[path], windowSize: (1900, 1068),
      theme: forceDark, persist: true, configDir: some(fx.dir / "config"),
      logDir: some(fx.dir / "logs"), userThemeDir: some(fx.dir /
          "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguivibdock: ok"

when isMainModule:
  main()
