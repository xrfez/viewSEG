## The plots of the special views open with a file shown and no trace selected,
## in the running frontend, headless, by real clicks:
##
## - Analysis > New plot > each view (spectrogram, envelope, phase spectrum,
##   cross-correlation, vibrator signature, f-k) with no trace selected opens a
##   window that is shown and says what to click (`awaitingWords`), not a
##   refusal;
## - the toolbar's FFT button does the same, with its spectrum's words;
## - selecting traces then fills each window in without reopening it (the
##   vibrator signature of a record with no pilot says so instead).
##
## Seen to fail: with `openPlot` ignoring a command that has no trace (the old
## refusal), "Analysis > New plot > spectrogram opened no window"; with the menu's
## New plot greyed while `plotTraces` is 0, the same step; with the toolbar greyed
## while no trace is selected, "the FFT button opened no window"; with the empty window
## not following the selection, "the windows filled in did not happen".
##
## `VIEWSEG_SCREENSHOTS=<dir>` saves the menu open, an empty spectrogram window and
## an empty FFT window there (the synthetic fixture).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, options, os]
import viewSEG/core/[analysis, geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/fixtures

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

const Views = [avSpectrogram, avEnvelope, avPhase, avCorrelation, avVibrator, avFk]

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc answered(f: FrameInfo): bool =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

proc main*() =

  withFixtures fx:
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

    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    proc shot(name: string; park = true) =
      ## With VIEWSEG_SCREENSHOTS=<dir>, saves the frame as <dir>/<name>.png.
      if shots.len == 0: return
      var saved = false
      step("screenshot " & name, proc (f: FrameInfo) =
        if park: f.moveMouse(vec2(700, 880)),
        proc (f: FrameInfo): bool =
        if not saved:
          createDir(shots)
          doAssert f.savePng(shots / (name & ".png")), name & ".png was not saved"
          saved = true
        true)

    step("the record", noop, proc (f: FrameInfo): bool = f.answered)
    step("no trace selected", proc (f: FrameInfo) =
      f.apply(Command(kind: ckClearSelection)),
      proc (f: FrameInfo): bool = f.core.selection.selectedCount == 0)
    proc openView(n: int; v: AnalysisView) =
      click("menu.Analysis")
      to("menu.window.newplot")
      if n == 0: shot("menu-enabled-no-trace", park = false)
      click("menu.newplot." & $v)
      step("Analysis > New plot > " & $v & " opened its window", noop,
        proc (f: FrameInfo): bool =
        doAssert f.core.plots.len == n + 1, "Analysis > New plot > " & $v &
          " opened no window: " & $f.core.plots.len
        let w = f.core.plots[n]
        doAssert w.view == v and w.traces.len == 0 and w.result.awaiting and
          w.result.problem == awaitingWords(v), $v & " window: " & w.result.problem
        f.markOf("new plot " & $w.id).size.x > 0)
      if n == 0: shot("spectrogram-empty")
    for n, v in Views: openView(n, v)
    click("tool.FFT")
    step("the toolbar's FFT opened its window", noop, proc (f: FrameInfo): bool =
      doAssert f.core.spectra.len == 2, "the FFT button opened no window"
      let w = f.core.spectra[^1]
      doAssert w.traces.len == 0, "the empty FFT window has traces"
      f.markOf("fft " & $w.id).size.x > 0)
    shot("fft-empty")
    step("four traces selected", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelect, traces: @[0, 1, 2, 3], mode: smReplace)),
      proc (f: FrameInfo): bool = f.core.selection.selectedCount == 4)
    step("the windows filled in", noop, proc (f: FrameInfo): bool =
      result = f.core.spectra[^1].traces.len == 4
      for n, v in Views:
        let w = f.core.plots[n]
        if w.result.awaiting: result = false
        elif v != avVibrator and w.traces.len == 0: result = false)

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
        elif wait > 600:
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(openPaths: @[fx.spectrumAuxSegy()],
      windowSize: (1400, 900), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguiplotopen: ok"

when isMainModule:
  main()
