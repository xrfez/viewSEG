## The plots remember their options across a restart, headless, with real
## clicks and settings kept in a folder of the test's own:
##
## - a first run opens an FFT window (clicks Linear) and a spectrogram (its
##   frame set), then quits;
## - a second run, started again on the same folder, opens another FFT
##   window and another spectrogram: each opens with what the first run left
##   (linear; the frame length); Reset options on each (real clicks) puts the
##   built-in options back in that window, and a third window then opens with
##   them.
##
## Seen to fail: with the writer leaving `plotOptions` out of the settings
## document, "the second spectrogram opened with 128 ms"; with the Reset
## button not sending its command, "reset options did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os]
import viewSEG/core/[analysis, geometry, persist, spectra, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc runSteps(steps: seq[Step]; path, config: string) =
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
        doAssert not f.idConflict, "an id conflict at " & steps[at].name
        inc at
        started = false
      elif overdue(wait, 400, since):
        failed = steps[at].name & " did not happen"
        f.stop()
  doAssert run(RunOptions(persist: true, configDir: some(config), logDir: some(config / "logs"),
    openPaths: @[path], windowSize: (1400, 900), theme: forceDark,
    userThemeDir: some(config / "no-user-themes"), indexCacheDir: some(config / "cache"),
    onFrame: onFrame)) == 0
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc main*() =

  withFixtures fx:
    let config = fx.dir / "config"
    createDir(config)
    let path = fx.spectrumSegy()
    var steps: seq[Step] = @[]
    var pointAt: Vec2
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    proc click(mark: string) =
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = r.centre
        f.moveMouse(pointAt), after(2))
      step("click " & mark, proc (f: FrameInfo) =
        f.pressMouse(pointAt, true)
        f.pressMouse(pointAt, false), after(3))
    proc record(f: FrameInfo): bool =
      let tiles = f.core.tiles(f.core.findPanel(MainPanel))
      f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
        f.panel.pending.gen == f.panel.requestGen
    proc openFft(first: bool) =
      step("the record", noop, record)
      step("an FFT window", proc (f: FrameInfo) =
        f.apply(Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: @[0],
          spectrumShow: f.core.settings.spectrum.window)),
        proc (f: FrameInfo): bool =
          result = f.core.spectra.len == 2 and not f.core.spectra[1].waiting and
            f.markOf("fft 1.data").size.x > 0
          if result:
            doAssert (f.core.spectra[1].display.scale == ssLinear) == not first,
              "the FFT window opened in " & $f.core.spectra[1].display.scale)
    proc openSpectrogram(first: bool) =
      step("a spectrogram", proc (f: FrameInfo) =
        f.apply(Command(kind: ckOpenPlot, plotView: avSpectrogram, plotTraces: @[0, 1],
          plotParams: AnalysisParams())),
        proc (f: FrameInfo): bool =
          result = f.core.plots.len == 1 and f.markOf("new plot 1.reset").size.x > 0
          if result:
            doAssert f.core.plots[0].params.windowMs == (if first: 128.0 else: 48.0),
              "the spectrogram opened with " & $f.core.plots[0].params.windowMs & " ms")

    # the first run: Linear by a click, the frame length by a command
    openFft(true)
    click("fft 1.linear")
    step("linear", noop, proc (f: FrameInfo): bool =
      f.core.spectra[1].display.scale == ssLinear and
        f.core.settings.spectrum.window.scale == ssLinear)
    openSpectrogram(true)
    step("frame 48 ms", proc (f: FrameInfo) =
      var p = f.core.plots[0].params
      p.windowMs = 48
      f.apply(Command(kind: ckPlotDisplay, plot: 1, plotParams: p)),
      proc (f: FrameInfo): bool = f.core.settings.plotOptions.spectrogram.windowMs == 48)
    runSteps(steps, path, config)
    steps.setLen 0

    # the second run: they open as left; Reset by a click on each
    openFft(false)
    click("fft 1.reset")
    step("reset the FFT window", noop, proc (f: FrameInfo): bool =
      f.core.spectra[1].display.scale == ssDb and
        f.core.settings.spectrum.window.scale == ssDb)
    openSpectrogram(false)
    click("new plot 1.reset")
    step("reset options", noop, proc (f: FrameInfo): bool =
      f.core.plots[0].params.windowMs == 128 and
        f.core.settings.plotOptions.spectrogram.windowMs == 128)
    step("another spectrogram", proc (f: FrameInfo) =
      f.apply(Command(kind: ckOpenPlot, plotView: avSpectrogram, plotTraces: @[0, 1])),
      proc (f: FrameInfo): bool =
        result = f.core.plots.len == 2
        if result:
          doAssert f.core.plots[1].params.windowMs == 128, "it did not open with the reset")
    runSteps(steps, path, config)
    echo "tguiplotoptions: ok"

when isMainModule: main()
