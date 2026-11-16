## The spectrum windows, headless, with real keys and clicks, on
## `spectrumSegy` (channels 1 to 8 a sine on bin 100, 24.41 Hz, in noise):
##
## - `F` over trace 1 opens an FFT window titled by what it shows, which
##   draws its curve; the pointer over the plot at the sine's frequency
##   reads the nearest bin (within a pixel of it) and its level;
## - the plot's menu, over a selected trace, opens another FFT window of
##   the selection ("FFT 2: 3 traces"), averaged;
## - a click on Linear redraws it in sample units, asking nothing again;
##   its window closed (its close button), it is gone;
## - the live Spectrum panel shown (as an agent shows it) comes on screen,
##   says so to `core`, and shows the visible traces; hidden from the
##   Window menu, it leaves the screen and `core` stops asking;
## - "Hide killed traces" (the gear popover) leaves a trace killed with `K`
##   out of the plot, and back in when unticked;
## - the toolbar's FFT button is greyed with no trace selected (a click on it
##   opens nothing) and, with three selected, opens their FFT window.
##
## Seen to fail: with Freeze still a checkbox at the end of the line, "freeze
## not on the first row"; with Phase still after Visible time, "phase is not
## with the curves". With the `F` key left out of `editKeys`, "F over trace 1
## did not happen"; with the readout taken at the pointer's other axis,
## "the readout at 24.41 Hz: 0 Hz   raw -60.1 dB"; with the panel's
## on-screen report left out (`drawLive` sending nothing), "the panel
## hidden did not happen"; with the toolbar's FFT dispatch left out of the
## app, "the toolbar's FFT opens the selection's window did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/view/[curveplot, spectrumview, theme]
import viewSEG/ui/imgui/[app, icons]
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc answered(f: FrameInfo): bool =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

proc traceX(f: FrameInfo; position: int): Vec2 =
  ## The middle of the plot's column of `position`, near its top (an FFT
  ## window opens over the middle of the main window).
  let plot = f.markOf("plot.data")
  let v = f.panel.view
  let x = plot.pos.x + float32((float64(position) - v.traces.lo) / v.traces.width) * plot.size.x
  vec2(round(x), round(plot.pos.y + 8))

withFixtures fx:
  var steps: seq[Step]
  var pointAt: Vec2
  var asks = 0
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard
  proc after(n: int): proc (f: FrameInfo): bool =
    var frames = 0
    result = proc (f: FrameInfo): bool =
      inc frames
      frames >= n
  proc click(mark: string; button = 1) =
    step("to " & mark, proc (f: FrameInfo) =
      let r = f.markOf(mark)
      doAssert r.size.x > 0, mark & " is not shown"
      pointAt = r.centre
      f.moveMouse(pointAt), after(2))
    step("click " & mark, proc (f: FrameInfo) =
      f.pressMouse(pointAt, true, button)
      f.pressMouse(pointAt, false, button), after(3))
  proc key(name: string; k: SimKey) =
    step(name, proc (f: FrameInfo) =
      f.pressKey(k, true)
      f.pressKey(k, false), after(3))

  step("the record", noop, proc (f: FrameInfo): bool = f.answered)
  step("over trace 1", proc (f: FrameInfo) = f.moveMouse(f.traceX(0)),
    proc (f: FrameInfo): bool = f.pick.found and f.pick.position == 0)
  step("the plot's focus", proc (f: FrameInfo) =
    # the click that brings the window forward does only that: it selects nothing
    pointAt = f.traceX(0)
    f.pressMouse(pointAt, true)
    f.pressMouse(pointAt, false), after(3))
  key("F", skF)
  step("F over trace 1", noop, proc (f: FrameInfo): bool =
    f.core.spectra.len == 2 and f.markOf("fft 1.data").size.x > 0 and
      not f.core.spectra[1].waiting and f.core.spectra[1].spectrum.raw.len > 0)
  step("freeze at the right, phase with the curves", noop, proc (f: FrameInfo): bool =
    let win = f.markOf("fft 1")
    let pin = f.markOf("fft 1.freeze")
    let db = f.markOf("fft 1.db")
    let phase = f.markOf("fft 1.phase")
    let raw = f.markOf("fft 1.raw")
    let time = f.markOf("fft 1.time")
    result = pin.size.x > 0 and db.size.x > 0 and phase.size.x > 0 and time.size.x > 0
    if result:
      doAssert abs(pin.pos.y - db.pos.y) <= 8, "freeze not on the first row"
      doAssert pin.pos.x + pin.size.x > win.pos.x + win.size.x - 28, "freeze not at the right"
      doAssert db.pos.x + db.size.x < pin.pos.x, "a scale control reaches the freeze place"
      doAssert abs(phase.pos.y - raw.pos.y) <= 2 and phase.pos.x > raw.pos.x,
        "phase is not with the curves"
      doAssert time.pos.y > phase.pos.y + 2 or phase.pos.x < time.pos.x,
        "visible time is not after the curves")
  step("its title", noop, proc (f: FrameInfo): bool =
    doAssert f.windowName("fft-1").startsWith(IconPulse & "  FFT: trace 1 · FFID 5 · " &
      "spectrum.sgy"), f.windowName("fft-1")
    true)
  step("the pointer at the sine", proc (f: FrameInfo) =
    let r = f.markOf("fft 1.data")
    let x = r.pos.x + float32(SpectrumSineHz / 250) * r.size.x # 0 to Nyquist across
    f.moveMouse(vec2(round(x), round(r.pos.y + r.size.y / 2))),
    proc (f: FrameInfo): bool =
      let (text, k) = f.spectraWindows.readoutOf(1)
      result = text.len > 0
      if result:
        # the nearest bin to the pointer: within a pixel of the sine, and its level
        let w = f.core.spectra[1]
        let hz = float64(k) * w.spectrum.binHz
        let pixel = 250 / float64(f.markOf("fft 1.data").size.x)
        doAssert abs(hz - SpectrumSineHz) <= pixel + w.spectrum.binHz,
          "the readout at 24.41 Hz: " & text
        let plot = w.spectrumPlot(builtinTheme(tmDark))
        let db = plot.curves[0].ys[k]
        doAssert text == plot.xText(hz) & " Hz   raw " & yText(db, "dB") & " dB", text)
  # the plot's menu over a selected trace: the selection's FFT
  step("select three", proc (f: FrameInfo) =
    f.apply(Command(kind: ckSelect, traces: @[2, 3, 4], mode: smReplace)),
    proc (f: FrameInfo): bool = f.core.selection.selectedCount == 3)
  step("over trace 4", proc (f: FrameInfo) = f.moveMouse(f.traceX(3)),
    proc (f: FrameInfo): bool = f.pick.found and f.pick.position == 3)
  step("the menu", proc (f: FrameInfo) =
    pointAt = f.traceX(3)
    f.pressMouse(pointAt, true, 3)
    f.pressMouse(pointAt, false, 3),
    proc (f: FrameInfo): bool = f.markOf("plot.menu.fft").size.x > 0)
  click("plot.menu.fft")
  step("the selection's FFT", noop, proc (f: FrameInfo): bool =
    result = f.core.spectra.len == 3 and not f.core.spectra[2].waiting and
      f.core.spectra[2].spectrum.averaged == 3
    if result:
      doAssert f.core.spectra[2].title.startsWith("FFT 2: 3 traces"), f.core.spectra[2].title
      asks = f.core.spectra[2].asks)
  step("its window", noop, proc (f: FrameInfo): bool = f.markOf("fft 2.linear").size.x > 0)
  click("fft 2.linear")
  step("linear", noop, proc (f: FrameInfo): bool =
    result = f.core.spectra[2].display.scale == ssLinear
    if result: doAssert f.core.spectra[2].asks == asks, "a new scale asked again")
  step("closed", proc (f: FrameInfo) =
    f.apply(Command(kind: ckCloseSpectrum, spectrum: 2)),
    proc (f: FrameInfo): bool =
      f.core.spectra.len == 2 and f.markOf("fft 2").size.x == 0)
  step("clear the selection", proc (f: FrameInfo) =
    f.apply(Command(kind: ckClearSelection)), after(2))
  # the toolbar's FFT button, as the menu's FFT: greyed with no trace selected,
  # and with traces selected it opens their window
  var spectra = 0
  step("no trace selected", proc (f: FrameInfo) =
    doAssert f.core.selection.selectedCount == 0
    spectra = f.core.spectra.len, after(1))
  click("tool.FFT")
  step("a click on the greyed FFT opens nothing", noop, proc (f: FrameInfo): bool =
    doAssert f.core.spectra.len == spectra, "a greyed FFT button opened a window"
    true)
  step("three selected for the toolbar", proc (f: FrameInfo) =
    f.apply(Command(kind: ckSelect, traces: @[2, 3, 4], mode: smReplace)),
    proc (f: FrameInfo): bool = f.core.selection.selectedCount == 3)
  click("tool.FFT")
  step("the toolbar's FFT opens the selection's window", noop, proc (f: FrameInfo): bool =
    result = f.core.spectra.len == spectra + 1
    if result:
      let w = f.core.spectra[^1]
      doAssert w.traces.len == 3, "the toolbar's FFT has " & $w.traces.len & " traces"
      doAssert f.markOf("fft " & $w.id).size.x > 0, "its window is not shown")
  step("the toolbar's window closed", proc (f: FrameInfo) =
    f.apply(Command(kind: ckCloseSpectrum, spectrum: f.core.spectra[^1].id)),
    proc (f: FrameInfo): bool = f.core.spectra.len == spectra)
  step("clear the selection again", proc (f: FrameInfo) =
    f.apply(Command(kind: ckClearSelection)), after(2))
  # the live panel, as an agent shows it: brought forward, on screen
  step("the panel shown", proc (f: FrameInfo) =
    f.apply(Command(kind: ckSpectrumPanel, onScreen: true, origin: coAgent)), after(4))
  step("the panel on screen", noop, proc (f: FrameInfo): bool =
    f.core.spectra[0].shown and f.markOf("spectrum.data").size.x > 0 and
      f.core.spectra[0].spectrum.averaged > 0)
  step("of the visible traces", noop, proc (f: FrameInfo): bool =
    doAssert f.core.spectra[0].chosen == soVisible
    doAssert f.core.spectra[0].traces.len == f.panel.layout.traces
    true)
  click("menu.Window")
  click("menu.window.spectrum")
  step("the panel hidden", noop, proc (f: FrameInfo): bool =
    result = not f.core.spectra[0].shown
    if result: doAssert f.markOf("spectrum").size.x == 0)
  # killed traces hidden
  # the toolbar's clicks took the keyboard focus: a focusing click gives it back
  # to the plot (it selects nothing)
  step("the plot's focus again", proc (f: FrameInfo) =
    pointAt = f.traceX(1)
    f.pressMouse(pointAt, true)
    f.pressMouse(pointAt, false), after(3))
  step("over trace 2", proc (f: FrameInfo) = f.moveMouse(f.traceX(1)),
    proc (f: FrameInfo): bool = f.pick.found and f.pick.position == 1)
  key("K", skK)
  step("killed", noop, proc (f: FrameInfo): bool = teKilled in f.core.traceEdits(1))
  click("plot.more")
  click("plot.more tab traces")
  click("plot.more.hide killed")
  step("hidden", noop, proc (f: FrameInfo): bool =
    f.core.settings.hideKilled and f.answered and f.panel.layout.traces == SpectrumTraces - 1)
  click("plot.more.hide killed")
  step("back", noop, proc (f: FrameInfo): bool =
    not f.core.settings.hideKilled and f.answered and f.panel.layout.traces == SpectrumTraces)

  var at = 0
  var started = false
  var wait = 0 # frames since the step began, at `since`
  var since = getMonoTime()
  var failed = ""
  proc onFrame(f: FrameInfo) =
    if f.index == 0: f.moveMouse(vec2(4, 4))
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
  echo "tguispectra: ok"
