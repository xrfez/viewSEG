## The spectrum windows' cursor and stepping through a record, headless,
## with real keys, on `spectrumSegy` (channels 1 to 8 a sine on bin 100 in
## noise):
##
## - the pointer over an FFT window's plot puts the cursor at the nearest
##   bin, with its frequency and value written on the axes (lines from the
##   point to both), and the readout rounded as the axes need (dB to a
##   tenth);
## - Right holds the cursor a bin on, and it stays where the keys put it
##   when the pointer leaves the plot (the readout starts "Held", its tooltip says how
##   to let it go); End and Home go to the last and first bin; Esc lets it
##   go;
## - Alt + Right in the FFT window of one trace selects the next trace and
##   the window shows it;
## - Alt + Right and Alt + Left in the Seismic window select the next and
##   previous trace, the plot scrolled to keep it in view; with time
##   across, Alt + Down and Alt + Up do (the arrows along the traces); Alt +
##   Left no longer goes back (Backspace does).
##
## Seen to fail: with the cursor keys left out (`cursorKeys` not called),
## "Right did not hold the cursor"; with the axis boxes not drawn, "no
## frequency on the axis"; with Alt + Left still Back in the plot (and no
## stepping), "Alt + Right in the plot did not select the next trace";
## with the scroll not told to the frontend (no `jumps`), "the plot did not
## keep the trace in view".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves cursor-held.png there.

import std/[math, options, os, sequtils, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/view/[curveplot, spectrumview]
import viewSEG/ui/imgui/[app, spectrumwindow]
import utils/fixtures

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

proc chord(f: FrameInfo; key: SimKey; mods: set[SimMod] = {}) =
  ## `key` pressed and released with `mods` held.
  const modKeys: array[SimMod, SimKey] = [skCtrl, skShift, skAlt]
  var held: set[SimMod]
  for m in mods:
    held.incl m
    f.pressKey(modKeys[m], true, held)
  f.pressKey(key, true, held)
  f.pressKey(key, false, held)
  for m in mods:
    held.excl m
    f.pressKey(modKeys[m], false, held)

proc selectedNow(f: FrameInfo): seq[int] = toSeq(f.core.selection.selected.items)

proc main*() =

  withFixtures fx:
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var failed = ""
    var pointAt: Vec2
    var bin = -1
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    proc key(k: SimKey; mods: set[SimMod] = {}) =
      step("key " & $mods & " " & $k, proc (f: FrameInfo) = f.chord(k, mods), after(4))
    proc click(mark: string) =
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = r.centre
        f.moveMouse(pointAt), after(2))
      step("click " & mark, proc (f: FrameInfo) =
        f.pressMouse(pointAt, true)
        f.pressMouse(pointAt, false), after(3))
    template fft(f: FrameInfo): untyped = f.core.spectra[^1]

    step("the record", noop, proc (f: FrameInfo): bool =
      f.answered and f.panel.layout.traces == SpectrumTraces)
    step("an FFT window of trace 3", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSpectrum, spectrumOf: MainPanel,
        spectrumTraces: @[f.core.sessions[0].base + 2], spectrumShow: SpectrumDisplay())),
      proc (f: FrameInfo): bool =
        f.core.spectra.len == 2 and not f.fft.waiting and f.fft.spectrum.raw.len > 0 and
          f.markOf("fft 1.data").size.x > 0)
    step("the pointer at the sine", proc (f: FrameInfo) =
      let r = f.markOf("fft 1.data")
      let x = r.pos.x + float32(SpectrumSineHz / 250) * r.size.x
      pointAt = vec2(round(x), round(r.pos.y + r.size.y / 2))
      f.moveMouse(pointAt),
      proc (f: FrameInfo): bool =
        let (text, k) = f.spectraWindows.readoutOf(1)
        result = text.len > 0 and k >= 0
        if result:
          bin = k
          doAssert f.markOf("fft 1.cursor x").size.x > 0, "no frequency on the axis"
          doAssert f.markOf("fft 1.cursor value").size.x > 0, "no value on the axis"
          let plot = f.fft.spectrumPlot(f.theme)
          doAssert text.startsWith(plot.xText(float64(k) * f.fft.spectrum.binHz) & " Hz   raw "),
            text
          let db = text.split("raw ")[1].split(" dB")[0]
          doAssert db.len >= 3 and db[^2] == '.', "dB not to a tenth: " & text)
    step("click the plot: the window has the focus", proc (f: FrameInfo) =
      f.pressMouse(pointAt, true)
      f.pressMouse(pointAt, false), after(3))
    key(skRight)
    step("held a bin on", noop, proc (f: FrameInfo): bool =
      doAssert f.fft.cursor.held, "Right did not hold the cursor"
      doAssert f.fft.cursor.x == bin + 1, "Right moved the cursor to " & $f.fft.cursor.x &
        ", not " & $(bin + 1)
      true)
    step("the pointer leaves the plot", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("fft 1.summary").centre), after(4))
    step("still held there", noop, proc (f: FrameInfo): bool =
      let (text, k) = f.spectraWindows.readoutOf(1)
      doAssert f.fft.cursor.held and k == bin + 1, "the cursor left with the pointer: " & $k
      doAssert text.startsWith(HeldNote), "the readout does not say it is held: " & text
      doAssert f.markOf("fft 1.cursor x").size.x > 0
      if shots.len > 0: doAssert f.savePng(shots / "cursor-held.png")
      true)
    key(skEnd)
    step("the last bin", noop, proc (f: FrameInfo): bool =
      doAssert f.fft.cursor.x == f.fft.spectrum.raw.high, $f.fft.cursor.x
      true)
    key(skHome)
    step("the first bin", noop, proc (f: FrameInfo): bool =
      doAssert f.fft.cursor.x == 0, $f.fft.cursor.x
      true)
    key(skEscape)
    step("let go", noop, proc (f: FrameInfo): bool =
      doAssert not f.fft.cursor.held, "Esc did not let the cursor go"
      true)
    key(skRight, {smAlt})
    step("the FFT window shows the next trace", noop, proc (f: FrameInfo): bool =
      let next = f.core.sessions[0].base + 3
      result = f.fft.traces == @[next] and not f.fft.waiting
      if result: doAssert f.selectedNow == @[next], $f.selectedNow)
    step("close it: the plot is clicked, not the window over it", proc (f: FrameInfo) =
      f.apply(Command(kind: ckCloseSpectrum, spectrum: f.fft.id)),
      proc (f: FrameInfo): bool = f.core.spectra.len == 1 and f.markOf("fft 1.data").size.x == 0)
    var start = -1
    proc clicked(f: FrameInfo): bool =
      # a click on the plot selects the trace under it: the steps go from it
      let now = f.selectedNow
      result = now.len == 1
      if result: start = now[0]
    click("plot.data")
    step("the trace clicked", noop, clicked)
    key(skRight, {smAlt})
    step("the plot's next trace", noop, proc (f: FrameInfo): bool =
      doAssert f.selectedNow == @[start + 1], "Alt + Right in the plot did not select the " &
        "next trace: " & $f.selectedNow & " from " & $start
      true)
    key(skLeft, {smAlt})
    step("the plot's previous trace", noop, proc (f: FrameInfo): bool =
      doAssert f.selectedNow == @[start], $f.selectedNow
      true)
    # A trace past the view's edge: the plot scrolls to it, and stays there.
    step("a narrow view, its last trace selected", proc (f: FrameInfo) =
      var v = f.panel.view
      v.traces = Span(lo: -0.5, hi: 3.5)
      f.showView(v)
      f.apply(Command(kind: ckSelect, traces: @[f.core.sessions[0].base + 3], mode: smReplace)),
      proc (f: FrameInfo): bool = f.panel.view.traces.hi < 4)
    key(skRight, {smAlt})
    step("scrolled to the next trace", noop, after(6))
    step("still there", noop, proc (f: FrameInfo): bool =
      doAssert f.selectedNow == @[f.core.sessions[0].base + 4], $f.selectedNow
      doAssert f.panel.view.traces.hi >= 4.5, "the plot did not keep the trace in view: " &
        $f.panel.view.traces
      true)
    step("time across", proc (f: FrameInfo) =
      var d = f.panel.layers[0].display
      d.orientation = orTimeAcross
      f.apply(Command(kind: ckDisplay, panel: MainPanel, display: d)),
      proc (f: FrameInfo): bool = f.answered and f.panel.layers[0].display.orientation ==
        orTimeAcross)
    click("plot.data")
    step("the trace clicked", noop, clicked)
    key(skDown, {smAlt})
    step("Alt + Down: the next trace", noop, proc (f: FrameInfo): bool =
      doAssert f.selectedNow == @[start + 1], "Alt + Down with time across: " &
        $f.selectedNow & " from " & $start
      true)
    key(skUp, {smAlt})
    step("Alt + Up: the previous trace", noop, proc (f: FrameInfo): bool =
      doAssert f.selectedNow == @[start], $f.selectedNow
      true)

    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if not started:
        steps[at].act(f)
        started = true
        wait = 0
      else:
        inc wait
        if wait >= 2 and steps[at].done(f):
          inc at
          started = false
        elif wait > 600:
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(maxFrames: 6000, openPaths: @[fx.spectrumSegy()],
      windowSize: (1400, 900), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguispeccursor: ", steps.len, " steps"

when isMainModule:
  main()
