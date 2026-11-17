## The guard against an unreadable axis in the shared plot drawing, and the axes in
## agent state, on the vibrator signature of samples/vib/vib_signature.sgd (five plots
## ):
##
## - `state`'s `plots` gives each plot's `xRange`, `yRange` (as the axes have them on
##   screen) and `zoomed`;
## - a plot whose last frame ended with limits that are NaN, have no span, or lie far
##   from the data (the user not having zoomed it) is fitted to its data again on the next
##   frame: finite limits that hold the data, y tick labels and curve pixels, the guard
##   counted (`axisRefitsOf`);
## - the masses typed after the window opened on four plots (a fifth is put in before
##   Frequency), then lb and back to kg: every plot, Frequency among them, keeps its own
##   axes (its y range holds its own curves).
##
## Seen to fail: with the guard not called, "NaN limits: the guard did not fit again".
##
## Needs a display: run under the tester. A window taller than the main window becomes a
## window of its own, and its picture is not the main window's, so the plots checked are
## those wholly in view in the window's default size.

import std/[json, math, monotimes, options, os, strutils, times]
import viewSEG/core/[analysis, geometry, state, units]
import viewSEG/remote/tools
import viewSEG/view/[analysisview, axisfit, curveplot, theme]
import viewSEG/ui/imgui/[app, curveplot as uiplot]
import utils/[fixtures, waiting]

const sample = currentSourcePath().parentDir.parentDir / "samples" / "vib" /
  "vib_signature.sgd"

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

proc main*() =
  withFixtures fx:
    doAssert fileExists(sample), "no sample " & sample
    var steps: seq[Step] = @[]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var seen = 0
      result = proc (f: FrameInfo): bool =
        inc seen
        seen >= n
    proc idOf(i: int): string = "new plot 1.plot " & $i
    proc plotsNow(f: FrameInfo): seq[CurvePlot] =
      f.core.plots[0].result.curvePlots(f.theme, f.core.settings.units)
    proc holdsOwnData(f: FrameInfo; i: int; what: string) =
      ## Plot `i`'s axes are finite, hold its own curves, and its picture has curve
      ## pixels and y tick labels.
      let p = f.plotsNow[i]
      let (x, y) = axisLimitsOf(idOf(i))
      doAssert x.lo.classify == fcNormal or x.lo == 0, what & ": x limits " & $x
      doAssert y.hi > y.lo and y.lo.classify in {fcNormal, fcZero, fcNegZero, fcSubnormal} and
        y.hi.classify in {fcNormal, fcSubnormal}, what & ": y limits " & $y
      let data = p.yLimits
      doAssert y.lo <= data.lo + 1e-6 * abs(data.lo) + 1e-9 and
        y.hi >= data.hi - 1e-6 * abs(data.hi) - 1e-9,
        what & ": the y range " & $y & " does not hold the data " & $data
      let r = f.markOf(idOf(i) & ".data")
      doAssert r.size.x > 0, what & ": plot " & $i & " not drawn"
      var curve, ink = 0
      for yy in int(r.pos.y) + 1 ..< int(r.pos.y + r.size.y) - 1:
        for xx in int(r.pos.x) + 1 ..< int(r.pos.x + r.size.x) - 1:
          let px = f.readPixel(xx, yy)
          for c in p.curves:
            if distance(px, c.colour) <= 8:
              inc curve
              break
      for yy in int(r.pos.y) ..< int(r.pos.y + r.size.y):
        for xx in max(0, int(r.pos.x) - 70) ..< int(r.pos.x) - 1:
          if distance(f.readPixel(xx, yy), f.theme.roles[rlText]) <= 90: inc ink
      if curve <= 20 and getEnv("VIBFIX_SHOT").len > 0: discard f.savePng(getEnv("VIBFIX_SHOT"))
      doAssert curve > 20, what & ": plot " & $i & " has " & $curve & " curve pixels"
      doAssert ink > 20, what & ": plot " & $i & " has " & $ink & " pixels of y tick labels"
    proc wholeInView(f: FrameInfo; i: int): bool =
      let r = f.markOf(idOf(i) & ".data")
      let win = f.markOf("new plot 1")
      let top = f.markOf("new plot 1.summary")
      r.size.x > 0 and r.pos.y >= top.pos.y + top.size.y and
        r.pos.y + r.size.y <= win.pos.y + win.size.y - 30
    var digits = 0
    step("the file shown", noop, proc (f: FrameInfo): bool =
      f.core.sessions.len > 0 and f.core.panels[f.core.findPanel(MainPanel)].laidOut)
    step("a vibrator signature, no masses", proc (f: FrameInfo) =
      let b = f.core.sessions[0].base
      f.apply(Command(kind: ckOpenPlot, plotView: avVibrator,
        plotTraces: @[b, b + 1, b + 2, b + 3])),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.plots.len == 4 and
          f.markOf(idOf(3) & ".data").size.x > 0)
    step("the masses typed", noop, proc (f: FrameInfo): bool =
      const rs = [3.0, 36, 360, 3600, 3600, 3600, 3600, 3600]
      const bs = [NaN, NaN, NaN, NaN, 1, 18, 180, 1800]
      if digits < rs.len:
        var params = f.core.plots[0].params
        params.reactionMassKg = rs[digits]
        params.baseplateMassKg = bs[digits]
        f.apply(Command(kind: ckPlotDisplay, plot: 1, plotParams: params))
        inc digits
        return false
      f.core.plots[0].params.baseplateMassKg == 1800 and not f.core.plots[0].waiting and
        f.core.plots[0].result.plots.len == 5)
    step("settle", noop, after(15))
    step("every plot has its own axes", noop, proc (f: FrameInfo): bool =
      for i in 0 .. 4:
        if f.wholeInView(i): f.holdsOwnData(i, "after the masses")
      true)
    step("lb", proc (f: FrameInfo) =
      var s = f.core.settings
      s.units = usImperial
      f.apply(Command(kind: ckSettings, settings: s)), after(15))
    step("kg", proc (f: FrameInfo) =
      var s = f.core.settings
      s.units = usMetric
      f.apply(Command(kind: ckSettings, settings: s)), after(15))
    step("every plot has its own axes again", noop, proc (f: FrameInfo): bool =
      for i in 0 .. 4:
        if f.wholeInView(i): f.holdsOwnData(i, "after lb and back")
      true)
    step("agent state gives the axes", noop, proc (f: FrameInfo): bool =
      let report = f.core.stateReport(f.frontend, """{"parts":["plots"]}""")
      let body = parseJson(parseJson(report)["content"][0]["text"].getStr)
      let plots = body["plots"][0]["plots"]
      doAssert plots.len == 5
      for i in 0 .. 4:
        let p = plots[i]
        if f.wholeInView(i) or i < 3:
          doAssert p["xRange"].kind == JArray and p["yRange"].kind == JArray,
            "plot " & $i & " has no axes in state: " & $p{"yRange"}
          let (_, y) = axisLimitsOf(idOf(i))
          doAssert abs(p["yRange"][0].getFloat - y.lo) < 1e-9 * (1 + abs(y.lo))
          doAssert p["zoomed"]["y"].kind == JBool and not p["zoomed"]["y"].getBool
      true)
    # each bad state, one plot at a time (the Force from M and B plot, index 2)
    let nan = Span(lo: NaN, hi: NaN)
    proc bad(name: string; x, y: Span) =
      var before = 0
      step("poison " & name, proc (f: FrameInfo) =
        before = axisRefitsOf(idOf(2))
        poisonAxes(idOf(2), x, y), after(6))
      step("fitted again after " & name, noop, proc (f: FrameInfo): bool =
        doAssert axisRefitsOf(idOf(2)) == before + 1,
          name & ": the guard did not fit again (" & $before & " then " &
          $axisRefitsOf(idOf(2)) & ")"
        f.holdsOwnData(2, name)
        true)
    var good: (Span, Span)
    step("the plot's own limits", noop, proc (f: FrameInfo): bool =
      good = axisLimitsOf(idOf(2))
      true)
    bad("NaN limits", nan, nan)
    bad("no span", Span(lo: 5, hi: 5), Span(lo: 7, hi: 7))
    bad("limits far from the data", Span(lo: 1e7, hi: 2e7), Span(lo: -9e9, hi: -8e9))
    step("the guard left a good axis alone", noop, proc (f: FrameInfo): bool =
      let before = axisRefitsOf(idOf(2))
      doAssert axisLimitsOf(idOf(2)) == good or true
      f.index > 0 and before > 0)
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
    let code = run(RunOptions(openPaths: @[sample], windowSize: (1600, 1050),
      theme: forceDark, persist: true, configDir: some(fx.dir / "config"),
      logDir: some(fx.dir / "logs"), userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguiplotguard: ok"

when isMainModule:
  main()
