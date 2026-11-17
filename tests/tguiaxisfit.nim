## The axes of the graph windows are fitted again after an option or the
## data changes (`view/axisfit`), headless, on `spectrumSegy` (a sine in
## noise, trace 9 ten times as loud):
##
## - an FFT window of one trace, linear: stepped to the loud trace, its
##   amplitude axis holds the new curve and the curve fills a good part of it
##   (it stayed at the first trace's limits);
## - the same window set to dB, then back: the curve lies inside its limits;
## - a phase spectrum window, its phase picture changed: the phase plot's
##   limits hold the new curve;
## - a vibrator signature window, its highest harmonic changed: every plot's
##   limits hold its curves;
## - the live Spectrum panel's limits stay as they were when its data
##   changes (it keeps its view).
##
## Seen to fail: with the axes never following new data (`plan` called with
## `follow` false), "the loud trace did not happen" (the amplitude axis
## stayed as the quieter trace's); with the new plot window's key as it was
## (its view, plot number and x range only), the phase picture's and the
## harmonic's plots stayed at the old limits.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[analysis, geometry, phasepicture, spectra, state, viewport]
import viewSEG/view/[analysisview, curveplot, spectrumview, theme]
import viewSEG/ui/imgui/[app, curveplot as uiplot]
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc answered(f: FrameInfo): bool =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

proc dataRange(p: CurvePlot): (float64, float64) =
  ## The finite values the plot draws, lowest and highest (from its floor).
  var (lo, hi) = (Inf, -Inf)
  for c in p.curves:
    for y in c.ys:
      if y.classify notin {fcNan, fcInf, fcNegInf}:
        lo = min(lo, y)
        hi = max(hi, y)
  if not p.yFloor.isNaN: lo = max(lo, p.yFloor)
  (lo, hi)

proc fits(id: string; p: CurvePlot; what: string; fill = 0.3) =
  ## The plot `id`'s value axis holds the curves' range, and they fill part of it.
  let (_, y) = axisLimitsOf(id)
  let (lo, hi) = p.dataRange
  doAssert not y.lo.isNaN, what & ": " & id & " was not drawn"
  let slack = 1e-6 * max(1.0, y.hi - y.lo)
  doAssert lo >= y.lo - slack and hi <= y.hi + slack,
    what & ": the curve " & $(lo, hi) & " is off the axis " & $(y.lo, y.hi)
  if hi > lo:
    doAssert (hi - lo) / (y.hi - y.lo) >= fill,
      what & ": the curve " & $(lo, hi) & " fills little of the axis " & $(y.lo, y.hi)

proc main*() =

  withFixtures fx:
    var steps: seq[Step] = @[]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    var before: (Span, Span)

    step("the record", noop, proc (f: FrameInfo): bool = f.answered)
    step("an FFT of trace 8, linear", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: @[7],
        spectrumShow: SpectrumDisplay(scale: ssLinear))),
      proc (f: FrameInfo): bool =
        result = f.core.spectra.len == 2 and not f.core.spectra[1].waiting and
          f.core.spectra[1].spectrum.raw.len > 0 and f.markOf("fft 1.data").size.x > 0
        if result:
          doAssert f.core.spectra[1].display.scale == ssLinear
          fits("fft 1", f.core.spectra[1].spectrumPlot(f.theme), "linear"))
    step("the loud trace", proc (f: FrameInfo) =
      before = axisLimitsOf("fft 1")
      f.apply(Command(kind: ckStepTrace, spectrum: 1, stepBy: 1)),
      proc (f: FrameInfo): bool =
        result = not f.core.spectra[1].waiting and f.core.spectra[1].traces == @[8] and
          f.core.spectra[1].spectrum.raw.len > 0
        if result:
          let (_, y) = axisLimitsOf("fft 1")
          # the loud sine reaches ten times the noise: the axis is not the old one
          result = y.hi != before[1].hi
          if result:
            fits("fft 1", f.core.spectra[1].spectrumPlot(f.theme), "new data"))
    step("dB", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSpectrumDisplay, spectrum: 1,
        spectrumShow: SpectrumDisplay(scale: ssDb))),
      proc (f: FrameInfo): bool =
        result = f.core.spectra[1].display.scale == ssDb and not f.core.spectra[1].waiting
        if result:
          let (_, y) = axisLimitsOf("fft 1")
          result = y.lo < 0 # dB values are negative here
          if result: fits("fft 1", f.core.spectra[1].spectrumPlot(f.theme), "dB"))
    step("a phase spectrum", proc (f: FrameInfo) =
      f.apply(Command(kind: ckOpenPlot, plotView: avPhase, plotTraces: @[0])),
      proc (f: FrameInfo): bool =
        result = f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.markOf("new plot 1.plot 1.data").size.x > 0
        if result: doAssert f.core.plots[0].result.problem == "", f.core.plots[0].result.problem)
    step("another phase picture", proc (f: FrameInfo) =
      var params = f.core.plots[0].params
      params.phasePicture = ppMagnitude
      params.phaseWithinDb = 60
      f.apply(Command(kind: ckPlotDisplay, plot: 1, plotParams: params)),
      proc (f: FrameInfo): bool =
        result = f.core.plots[0].params.phasePicture == ppMagnitude and
          not f.core.plots[0].waiting and f.markOf("new plot 1.plot 1.data").size.x > 0
        if result:
          let plots = f.core.plots[0].result.curvePlots(f.theme, f.core.settings.units)
          result = plots.len == 2
          if result:
            for i, p in plots: fits("new plot 1.plot " & $i, p, "the phase picture", 0.0))
    step("a vibrator signature", proc (f: FrameInfo) =
      f.apply(Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[0, 1, 2, 3])),
      proc (f: FrameInfo): bool =
        result = f.core.plots.len == 2 and not f.core.plots[1].waiting and
          f.markOf("new plot 2.plot 3.data").size.x > 0)
    step("another harmonic", proc (f: FrameInfo) =
      var params = f.core.plots[1].params
      params.harmonics = 2
      f.apply(Command(kind: ckPlotDisplay, plot: 2, plotParams: params)),
      proc (f: FrameInfo): bool =
        result = f.core.plots[1].params.harmonics == 2 and not f.core.plots[1].waiting and
          f.markOf("new plot 2.plot 3.data").size.x > 0
        if result:
          let plots = f.core.plots[1].result.curvePlots(f.theme, f.core.settings.units)
          for i, p in plots: fits("new plot 2.plot " & $i, p, "the harmonic", 0.0))
    # an analysis window that follows the selection: other traces, new axes
    step("an envelope of the selected trace", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelect, traces: @[7], mode: smReplace))
      f.apply(Command(kind: ckOpenPlot, plotView: avEnvelope)),
      proc (f: FrameInfo): bool =
        result = f.core.plots.len == 3 and not f.core.plots[2].waiting and
          f.core.plots[2].traces == @[7] and f.markOf("new plot 3.plot 0.data").size.x > 0
        if result:
          let plots = f.core.plots[2].result.curvePlots(f.theme, f.core.settings.units)
          for i, p in plots: fits("new plot 3.plot " & $i, p, "the first trace", 0.0))
    step("the loud trace selected", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelect, traces: @[8], mode: smReplace)),
      proc (f: FrameInfo): bool =
        result = f.core.plots[2].traces == @[8] and not f.core.plots[2].waiting and
          f.markOf("new plot 3.plot 0.data").size.x > 0
        if result:
          let plots = f.core.plots[2].result.curvePlots(f.theme, f.core.settings.units)
          for i, p in plots: fits("new plot 3.plot " & $i, p, "another trace selected", 0.0))
    step("settled", noop, after(5))
    step("still fitted", noop, proc (f: FrameInfo): bool =
      let plots = f.core.plots[2].result.curvePlots(f.theme, f.core.settings.units)
      for i, p in plots: fits("new plot 3.plot " & $i, p, "the same data again", 0.0)
      true)
    # the live Spectrum panel keeps its view when the data changes
    var live: (Span, Span)
    step("the panel shown", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSpectrumPanel, onScreen: true, origin: coAgent)),
      proc (f: FrameInfo): bool =
        result = f.core.spectra[0].shown and f.markOf("spectrum.data").size.x > 0 and
          f.core.spectra[0].spectrum.averaged > 0 and not f.core.spectra[0].waiting
        if result: live = axisLimitsOf("spectrum"))
    step("other traces", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelect, traces: @[8], mode: smReplace)),
      proc (f: FrameInfo): bool =
        result = f.core.spectra[0].traces == @[8] and not f.core.spectra[0].waiting
        if result:
          doAssert not live[0].lo.isNaN
          doAssert axisLimitsOf("spectrum") == live,
            "the live panel's limits moved with its data: " & $live & " then " &
            $axisLimitsOf("spectrum"))
    step("settle", noop, after(5))
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
    echo "tguiaxisfit: ok"

when isMainModule:
  main()
