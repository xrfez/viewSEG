## No window's text or controls reach past the window's right edge: each kind of analysis
## window (spectrogram, envelope, phase spectrum, cross-correlation, vibrator signature,
## f-k, node orientation) and the FFT window, on the vibrator sample, at the default size
## and with the main window made narrow (the windows are then as narrow as they can open).
## The windows' check is `markOverflow` ("<window>.overflow": points past the right edge).
## The Reference archive window's cells are checked in tguireferences.
##
## Seen to fail: with a long line of text drawn unwrapped in the plot windows, "default size,
## spectrogram: new plot 1.overflow reaches 158 points past its right edge"; with the envelope's
## reference label followed by a same-line call (as it was), "Reset options runs under the
## Freeze pin".
##
## Screenshots of the samples go under `.scratch` (set `HANDTEST_SHOTS` to move them).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[monotimes, options, os]
import viewSEG/core/[analysis, geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

const root = currentSourcePath().parentDir.parentDir

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

proc main*() =
  withFixtures fx:
    let path = root / "samples" / "vib" / "vib_signature.sgd"
    doAssert fileExists(path), path
    let shots = getEnv("HANDTEST_SHOTS", root / ".scratch")
    createDir(shots)
    var steps: seq[Step] = @[]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    proc fits(f: FrameInfo; mark, what: string) =
      let r = f.markOf(mark)
      doAssert r.size.y > 0, mark & " is not shown (" & what & ")"
      doAssert r.size.x <= 0.5, what & ": " & mark & " reaches " & $r.size.x &
        " points past its right edge"

    var base = 0
    var refId = ""
    proc apart(f: FrameInfo; window, what: string) =
      ## the controls on the first row end before the Freeze pin begins
      let pin = f.markOf(window & ".freeze")
      let reset = f.markOf(window & ".reset")
      if pin.size.x > 0 and reset.size.x > 0:
        doAssert reset.pos.x + reset.size.x <= pin.pos.x + 0.5 or
            reset.pos.y >= pin.pos.y + pin.size.y - 1,
          what & ": Reset options runs under the Freeze pin in " & window
    proc labelled(f: FrameInfo; window, what: string) =
      ## a rotated y label is no longer than its pane is high
      for k in 0 .. 5:
        let label = f.markOf(window & ".plot " & $k & ".ylabel")
        let data = f.markOf(window & ".plot " & $k & ".data")
        if data.size.y > 0 and label.size.y > 0:
          doAssert label.size.y <= data.size.y, what & ": " & window & " plot " & $k &
            "'s y label is " & $label.size.y & " points long in a pane " & $data.size.y & " high"
    step("the file shown", noop, proc (f: FrameInfo): bool =
      result = f.core.sessions.len > 0 and f.core.panels[f.core.findPanel(MainPanel)].laidOut
      if result: base = f.core.sessions[0].base)
    step("a reference stored and chosen", proc (f: FrameInfo) =
      f.apply(Command(kind: ckStoreReference, refStore: StoredReference(name: "pilot",
        trace: base, fromMs: 0, toMs: -1))),
      proc (f: FrameInfo): bool =
        for e in f.core.references.entries:
          if e.name == "pilot": refId = e.id
        if refId.len > 0 and f.core.chosenReference != refId:
          f.apply(Command(kind: ckSelectReference, refId: refId))
        f.core.chosenReference == refId and refId.len > 0)
    proc openStep(kind: AnalysisView; want: int) =
      step("open " & $kind, proc (f: FrameInfo) =
        f.apply(Command(kind: ckOpenPlot, plotView: kind,
          plotTraces: @[base, base + 1, base + 2, base + 3])),
        proc (f: FrameInfo): bool =
          f.core.plots.len == want and not f.core.plots[^1].waiting)
    var n = 0
    for view in [avSpectrogram, avEnvelope, avPhase, avCorrelation, avVibrator, avFk,
        avOrientation]:
      inc n
      openStep(view, n)
    step("settle", noop, after(20))
    step("an FFT window", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: @[base])),
      proc (f: FrameInfo): bool = f.core.spectra.len >= 2)
    step("settle again", noop, after(20))
    var shot = false
    step("default size: every window fits", proc (f: FrameInfo) =
      for i in 1 .. 7:
        f.fits("new plot " & $i & ".overflow", "default size, " & $f.core.plots[i - 1].view)
        f.apart("new plot " & $i, "default size")
        f.labelled("new plot " & $i, "default size")
      f.fits("fft 1.overflow", "default size, FFT")
      shot = f.savePng(shots / "handtest-windows.png"), after(2))
    step("a narrow window", proc (f: FrameInfo) = f.resizeWindow(760, 640), after(30))
    step("narrow: every window fits", proc (f: FrameInfo) =
      for i in 1 .. 7:
        f.fits("new plot " & $i & ".overflow", "narrow, " & $f.core.plots[i - 1].view)
        f.apart("new plot " & $i, "narrow")
        f.labelled("new plot " & $i, "narrow")
      f.fits("fft 1.overflow", "narrow, FFT")
      discard f.savePng(shots / "handtest-windows-narrow.png"), after(2))

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
    let code = run(RunOptions(openPaths: @[path],
      windowSize: (1400, 900), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      persist: true, configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguiclipped: ok"

when isMainModule: main()
