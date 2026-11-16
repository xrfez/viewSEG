## New plot windows in the running frontend, on samples/land/shots.sgy, then
## samples/vib/vib_uncorrelated.sgd in the same plot.
##
## Spectrogram, envelope and phase, then an FFT window and the Spectrum panel:
## a selection change is followed; Freeze keeps one on its traces; opening
## another file leaves the frozen one and moves the others; unfreezing
## follows; closing the file leaves a frozen window's numbers. The Headers
## window has no Freeze pin: its Trace tab follows the selection, and a new
## file.
##
## Seen to fail: with the windows locked to the traces that opened them,
## "an unfrozen window did not follow the selection".
##
## Break to see it fail: in `followPlots`, skip the repick.
##
## Needs a display: run under the tester (it gives each test its own).

import std/[math, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/headerviews
import utils/fixtures

const root = currentSourcePath().parentDir.parentDir
let land = root / "samples" / "land" / "shots.sgy"
let vib = root / "samples" / "vib" / "vib_uncorrelated.sgd"
let obn = root / "samples" / "obn" / "obn.sgd"

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

doAssert fileExists(land) and fileExists(vib) and fileExists(obn)

withFixtures fx:
  var steps: seq[Step] = @[]
  var pointAt: Vec2
  var frozenTraces: seq[int] = @[]
  var frozenFile = ""
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard
  proc after(n: int): proc (f: FrameInfo): bool =
    var frames = 0
    result = proc (f: FrameInfo): bool =
      inc frames
      frames >= n
  proc to(mark: string) =
    step("to " & mark, proc (f: FrameInfo) =
      let r = f.markOf(mark)
      doAssert r.size.x > 0, mark & " is not shown"
      pointAt = r.centre
      f.moveMouse(pointAt), after(3))
  proc click(mark: string) =
    to(mark)
    step("click " & mark, proc (f: FrameInfo) =
      f.pressMouse(pointAt, true, 1)
      f.pressMouse(pointAt, false, 1), after(3))

  step("shots.sgy", noop, proc (f: FrameInfo): bool =
    f.answered and f.core.sessions.len == 1 and f.core.sessions[0].name == "shots.sgy")
  step("two selected", proc (f: FrameInfo) =
    let b = f.core.sessions[0].base
    f.apply(Command(kind: ckSelect, traces: @[b, b + 1], mode: smReplace)),
    proc (f: FrameInfo): bool = f.core.selection.selectedCount == 2)
  step("three plots", proc (f: FrameInfo) =
    f.apply(Command(kind: ckOpenPlot, plotView: avSpectrogram))
    f.apply(Command(kind: ckOpenPlot, plotView: avEnvelope))
    f.apply(Command(kind: ckOpenPlot, plotView: avPhase)),
    proc (f: FrameInfo): bool =
      result = f.core.plots.len == 3 and not f.core.plots[0].waiting and
        not f.core.plots[1].waiting and not f.core.plots[2].waiting
      if result:
        let b = f.core.sessions[0].base
        doAssert f.core.plots[0].traces == @[b, b + 1]
        doAssert f.core.plots[1].traces == @[b] and f.core.plots[2].traces == @[b])
  step("selection of three", proc (f: FrameInfo) =
    let b = f.core.sessions[0].base
    f.apply(Command(kind: ckSelect, traces: @[b + 4, b + 5, b + 6], mode: smReplace)),
    proc (f: FrameInfo): bool =
      let b = f.core.sessions[0].base
      doAssert f.core.plots[0].traces == @[b + 4, b + 5, b + 6],
        "an unfrozen window did not follow the selection: " & $f.core.plots[0].traces
      doAssert f.core.plots[1].traces == @[b + 4] and f.core.plots[2].traces == @[b + 4]
      true)
  click("new plot 3.freeze")
  step("phase frozen", noop, proc (f: FrameInfo): bool =
    result = f.core.plots[2].frozen
    if result:
      frozenTraces = f.core.plots[2].traces
      frozenFile = f.core.plots[2].file)
  step("selection while frozen", proc (f: FrameInfo) =
    let b = f.core.sessions[0].base
    f.apply(Command(kind: ckSelect, traces: @[b + 8, b + 9], mode: smReplace)),
    proc (f: FrameInfo): bool =
      let b = f.core.sessions[0].base
      doAssert f.core.plots[2].traces == frozenTraces and f.core.plots[2].file == frozenFile,
        "a frozen window followed the selection"
      doAssert f.core.plots[0].traces == @[b + 8, b + 9],
        "an unfrozen window did not follow: " & $f.core.plots[0].traces
      true)
  step("open the vib file", proc (f: FrameInfo) =
    f.apply(Command(kind: ckShowFile, panel: MainPanel, path: vib)),
    proc (f: FrameInfo): bool =
      let k = f.core.findPanel(MainPanel)
      let i = f.core.shownFile(k)
      result = i >= 0 and f.core.sessions[i].path == vib and f.answered
      if result:
        doAssert f.core.plots[2].traces == frozenTraces and f.core.plots[2].file == frozenFile,
          "a frozen window followed the new file: " & f.core.plots[2].file
        doAssert "vib_uncorrelated.sgd" in f.core.plots[0].file,
          "an unfrozen window did not follow the new file: " & f.core.plots[0].file
        doAssert "vib_uncorrelated.sgd" in f.core.plots[1].file, f.core.plots[1].file)
  click("new plot 3.freeze")
  step("unfrozen, it follows", noop, proc (f: FrameInfo): bool =
    result = not f.core.plots[2].frozen and "vib_uncorrelated.sgd" in f.core.plots[2].file and
      f.core.plots[2].traces != frozenTraces)
  step("FFT of the plot", proc (f: FrameInfo) =
    let i = f.core.shownFile(f.core.findPanel(MainPanel))
    let b = f.core.sessions[i].base
    f.apply(Command(kind: ckSpectrum, spectrumTraces: @[b])),
    proc (f: FrameInfo): bool =
      f.core.spectra.len == 2 and not f.core.spectra[1].waiting and
        f.markOf("fft 1.freeze").size.x > 0)
  click("menu.Window")
  click("menu.window.spectrum")
  step("spectrum on screen", noop, proc (f: FrameInfo): bool =
    f.core.spectra[0].shown and f.markOf("spectrum.freeze").size.x > 0 and
      f.markOf("headers").size.x > 0 and f.markOf("headers.freeze").size.x == 0)
  step("select two on the vib file", proc (f: FrameInfo) =
    let i = f.core.shownFile(f.core.findPanel(MainPanel))
    let b = f.core.sessions[i].base
    f.apply(Command(kind: ckSelect, traces: @[b + 2, b + 3], mode: smReplace)),
    proc (f: FrameInfo): bool =
      let i = f.core.shownFile(f.core.findPanel(MainPanel))
      let b = f.core.sessions[i].base
      result = not f.core.spectra[1].waiting and not f.core.spectra[0].waiting and
        not f.core.plots[0].waiting
      if result:
        doAssert f.core.spectra[1].traces == @[b + 2, b + 3],
          "the FFT window did not follow: " & $f.core.spectra[1].traces
        doAssert f.core.spectra[0].traces == @[b + 2, b + 3],
          "the Spectrum panel did not follow: " & $f.core.spectra[0].traces
        doAssert f.core.plots[0].traces == @[b + 2, b + 3]
        doAssert "vib_uncorrelated.sgd" in chosenLine(f.core, true),
          chosenLine(f.core, true))
  click("fft 1.freeze")
  click("spectrum.freeze")
  step("fft and spectrum frozen", noop, proc (f: FrameInfo): bool =
    result = f.core.spectra[1].frozen and f.core.spectra[0].frozen
    if result:
      frozenTraces = f.core.spectra[1].traces
      frozenFile = f.core.spectra[1].file)
  step("open obn", proc (f: FrameInfo) =
    f.apply(Command(kind: ckShowFile, panel: MainPanel, path: obn)),
    proc (f: FrameInfo): bool =
      let i = f.core.shownFile(f.core.findPanel(MainPanel))
      result = i >= 0 and f.core.sessions[i].path == obn and f.answered and
        not f.core.plots[0].waiting
      if result:
        doAssert f.core.spectra[1].traces == frozenTraces and f.core.spectra[1].file == frozenFile,
          "a frozen FFT window followed the new file"
        doAssert f.core.spectra[0].frozen and f.core.spectra[0].file == frozenFile,
          "a frozen Spectrum panel followed the new file"
        doAssert "obn.sgd" in f.core.plots[0].file, f.core.plots[0].file
        # the selection is still the vib traces: the frozen windows keep that
        # file open, and Headers follows the selection, not the file on show
        doAssert "vib_uncorrelated.sgd" in chosenLine(f.core, true), chosenLine(f.core, true))
  click("fft 1.freeze")
  step("fft unfrozen follows obn", noop, proc (f: FrameInfo): bool =
    result = not f.core.spectra[1].frozen and not f.core.spectra[1].waiting and
      "obn.sgd" in f.core.spectra[1].file and f.core.spectra[1].traces != frozenTraces)
  click("spectrum.freeze")
  step("spectrum unfrozen follows obn", noop, proc (f: FrameInfo): bool =
    result = not f.core.spectra[0].frozen and not f.core.spectra[0].waiting and
      "obn.sgd" in f.core.spectra[0].file)
  step("select on obn, headers follow", proc (f: FrameInfo) =
    let i = f.core.shownFile(f.core.findPanel(MainPanel))
    let b = f.core.sessions[i].base
    f.apply(Command(kind: ckSelect, traces: @[b], mode: smReplace)),
    proc (f: FrameInfo): bool =
      "obn.sgd" in chosenLine(f.core, true))
  click("fft 1.freeze")
  step("fft frozen again", noop, proc (f: FrameInfo): bool =
    result = f.core.spectra[1].frozen and f.core.spectra[1].spectrum.raw.len > 0
    if result:
      frozenTraces = f.core.spectra[1].traces
      frozenFile = f.core.spectra[1].file)
  step("close the file", proc (f: FrameInfo) =
    let i = f.core.shownFile(f.core.findPanel(MainPanel))
    f.apply(Command(kind: ckClose, file: f.core.sessions[i].id)),
    proc (f: FrameInfo): bool =
      result = f.core.shownFile(f.core.findPanel(MainPanel)) < 0
      if result:
        doAssert f.core.spectra[1].frozen and f.core.spectra[1].traces == frozenTraces and
          f.core.spectra[1].file == frozenFile and f.core.spectra[1].spectrum.raw.len > 0,
          "closing the file dropped the frozen FFT window"
        doAssert not f.core.spectra[1].waiting)

  var at = 0
  var started = false
  var wait = 0
  var failed = ""
  proc onFrame(f: FrameInfo) =
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
      elif wait > 900:
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(openPaths: @[land], windowSize: (1600, 1000), theme: forceDark,
    userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
    onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
