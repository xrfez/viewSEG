## Window > Bring all windows onto this screen covers every floating window, in the running
## frontend, headless: two analysis windows and an FFT window are put far off the screen (by
## `moveFloatingWindow`, the seam a loaded layout uses), the command runs, and each window's
## rectangle is inside the main window's work area (`new plots.room`), none larger than it.
## The command finds the windows in Dear ImGui's registry of windows, not in a list, so a new
## kind of window is covered.
##
## Seen to fail: with the command moving only the windows of the old list (the docked ones,
## "Import survey", memory, shortcuts, settings, the FFT windows), "new plot 1 is outside the
## main window".
##
## Needs a display: run under the tester, which gives each file its own.

import std/[monotimes, options, os]
import viewSEG/core/[analysis, geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

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
    proc inside(f: FrameInfo; name: string) =
      let room = f.markOf("new plots.room")
      let r = f.markOf(name)
      doAssert r.size.x > 0, name & " is not shown"
      doAssert r.pos.x >= room.pos.x - 1 and r.pos.y >= room.pos.y - 1 and
        r.pos.x + r.size.x <= room.pos.x + room.size.x + 1 and
        r.pos.y + r.size.y <= room.pos.y + room.size.y + 1,
        name & " is outside the main window: " & $r & " in " & $room

    step("the record", noop, proc (f: FrameInfo): bool =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      p.laidOut and p.shown.len > 0)
    step("two plots and an FFT", proc (f: FrameInfo) =
      f.apply(Command(kind: ckOpenPlot, plotView: avEnvelope, plotTraces: @[0]))
      f.apply(Command(kind: ckOpenPlot, plotView: avSpectrogram, plotTraces: @[1]))
      f.apply(Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: @[2])),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 2 and f.core.spectra.len >= 2 and
          f.markOf("new plot 2").size.x > 0 and f.markOf("fft 1").size.x > 0)
    proc putOff(f: FrameInfo) =
      doAssert f.moveFloatingWindow("Envelope", 9000, 7000), "no envelope window"
      doAssert f.moveFloatingWindow("Spectrogram", -4000, -3000), "no spectrogram window"
      doAssert f.moveFloatingWindow("FFT", 6000, -2000), "no FFT window"
    step("put off the screen", putOff, after(10))
    step("brought back", proc (f: FrameInfo) = f.bringAllWindows(), after(12))
    step("every window is in the main window", noop, proc (f: FrameInfo): bool =
      f.inside("new plot 1")
      f.inside("new plot 2")
      f.inside("fft 1")
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
    echo "tguibringwindows: ok"

when isMainModule: main()
