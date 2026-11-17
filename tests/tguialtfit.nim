## The axes of an analysis window follow its data when the selection moves, headless, on
## samples/vib (the traces of a record differ a lot in amplitude: Ref, GF, M, B):
##
## - a Vibrator signature window and a Cross-correlation window (an archive reference
##   chosen), the selection stepped seven times with Alt+Right through the real key route
##   (the pointer over the Seismic plot): after each step every plot's value axis holds the
##   new curves;
## - a Spectrogram window (an image), its file changed from the 3 s traces to the 9 s traces:
##   the time axis fits the new image (it stayed at 0 to 3 s, the first image's extent).
## `HANDTEST_SHOTS=<dir>` saves altfit-<view>.png of each window after the steps.
##
## Seen to fail: the Spectrogram part, with the image's axes set once (`Cond_Once`, as they
## were): "the time axis stayed at (lo: -16.0, hi: 2992.0) for an image ending at 9008.0".
## The Vibrator and Cross-correlation parts passed before the change too: those windows'
## curves already refit by `view/axisfit`'s rule.
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os]
import viewSEG/core/[analysis, geometry, panels, references, state, viewport]
import viewSEG/view/[analysisview, curveplot]
import viewSEG/ui/imgui/[app, curveplot as uiplot]
import utils/[fixtures, waiting]

const sample = currentSourcePath().parentDir.parentDir / "samples" / "vib" / "vib_signature.sgd"

const Presses = 7

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc dataRange(p: CurvePlot): (float64, float64) =
  var (lo, hi) = (Inf, -Inf)
  for c in p.curves:
    for y in c.ys:
      if y.classify notin {fcNan, fcInf, fcNegInf}:
        lo = min(lo, y)
        hi = max(hi, y)
  if not p.yFloor.isNaN: lo = max(lo, p.yFloor)
  (lo, hi)

proc fits(id: string; p: CurvePlot; what: string) =
  ## The plot `id`'s value axis holds the curves' range.
  let (_, y) = axisLimitsOf(id)
  let (lo, hi) = p.dataRange
  doAssert not y.lo.isNaN, what & ": " & id & " was not drawn"
  let slack = 1e-6 * max(1.0, y.hi - y.lo)
  doAssert lo >= y.lo - slack and hi <= y.hi + slack,
    what & ": " & id & ": the curve " & $(lo, hi) & " is off the axis " & $(y.lo, y.hi)

proc main*() =
  withFixtures fx:
    doAssert fileExists(sample), sample
    let shots = getEnv("HANDTEST_SHOTS")
    var steps: seq[Step] = @[]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    var before: seq[float64] = @[]
    var firstTraces: seq[int] = @[]

    proc ready(f: FrameInfo; w: int; view: AnalysisView; mark: string): bool =
      f.core.plots.len > w and f.core.plots[w].view == view and not f.core.plots[w].waiting and
        f.core.plots[w].result.problem.len == 0 and f.markOf(mark).size.x > 0

    proc stepWindow(name: string; w: int; view: AnalysisView; prefix: string) =
      step(name & ": the first trace selected", proc (f: FrameInfo) =
        f.apply(Command(kind: ckSelect, traces: @[0], mode: smReplace))
        f.apply(Command(kind: ckOpenPlot, plotView: view)),
        proc (f: FrameInfo): bool =
          result = f.ready(w, view, prefix & ".plot 0.data")
          if result:
            firstTraces = f.core.plots[w].traces
            before = @[]
            for i in 0 ..< f.core.plots[w].result.plots.len:
              let (lo, hi) = f.core.plots[w].result.curvePlots(f.theme,
                f.core.settings.units)[i].dataRange
              before.add lo
              before.add hi
            discard)
      # the new window covers the plot: its uncovered strip takes the pointer and the focus
      step(name & ": the Seismic plot focused", proc (f: FrameInfo) =
        let q = vec2(358, 450)
        f.moveMouse(q)
        f.pressMouse(q, true, 1)
        f.pressMouse(q, false, 1),
        proc (f: FrameInfo): bool = not f.core.plots[w].waiting)
      step(name & ": the first trace selected again", proc (f: FrameInfo) =
        f.apply(Command(kind: ckSelect, traces: @[0], mode: smReplace)),
        proc (f: FrameInfo): bool =
          result = f.core.plots[w].traces == firstTraces and not f.core.plots[w].waiting and
            f.core.selection.selected.len == 1)
      for n in 1 .. Presses:
        step(name & ": Alt+Right " & $n, proc (f: FrameInfo) =
          firstTraces = f.core.plots[w].traces
          f.pressKey(skAlt, true, {smAlt})
          f.pressKey(skRight, true, {smAlt})
          f.pressKey(skRight, false, {smAlt})
          f.pressKey(skAlt, false),
          proc (f: FrameInfo): bool =
            result = f.core.plots[w].traces != firstTraces and
              f.ready(w, view, prefix & ".plot 0.data")
            if result:
              let plots = f.core.plots[w].result.curvePlots(f.theme, f.core.settings.units)
              for i, p in plots:
                fits(prefix & ".plot " & $i, p, "after Alt+Right " & $n & ", traces " &
                  $f.core.plots[w].traces))
        step(name & ": settled " & $n, noop, proc (f: FrameInfo): bool =
          result = f.markOf(prefix & ".plot 0.data").size.x > 0
          if result:
            let plots = f.core.plots[w].result.curvePlots(f.theme, f.core.settings.units)
            for i, p in plots: fits(prefix & ".plot " & $i, p, "settled after " & $n)
            if shots.len > 0 and n == Presses:
              createDir(shots)
              discard f.savePng(shots / ("altfit-" & $view & ".png")))

    steps.add Step(name: "the record", act: noop, done: proc (f: FrameInfo): bool =
      let k = f.core.findPanel(MainPanel)
      k >= 0 and f.core.panels[k].laidOut and f.core.panels[k].shown.len > 0 and
        f.markOf("plot.data").size.x > 0)
    stepWindow("vibrator", 0, avVibrator, "new plot 1")
    # the plain Cross-correlation: an archive reference (trace 1, stored) is the reference
    step("a reference stored", proc (f: FrameInfo) =
      f.apply(Command(kind: ckClosePlot, plot: 1))
      f.apply(Command(kind: ckStoreReference, refStore: StoredReference(name: "ref",
        trace: 0, fromMs: 0, toMs: -1))),
      proc (f: FrameInfo): bool =
        result = f.core.references.entries.len > 0 and f.core.plots.len == 0
        if result:
          for e in f.core.references.entries:
            if e.name == "ref": f.apply(Command(kind: ckSelectReference, refId: e.id)))
    stepWindow("correlation", 0, avCorrelation, "new plot 1")

    # a spectrogram (an image): another file, other extents, the axes fit the new ones
    var shown: (Span, Span)
    step("the shorter file", proc (f: FrameInfo) =
      f.apply(Command(kind: ckClosePlot, plot: 1))
      f.apply(Command(kind: ckShowFile, panel: MainPanel,
        path: sample.parentDir / "vib_correlated.sgd")),
      proc (f: FrameInfo): bool =
        let k = f.core.findPanel(MainPanel)
        f.core.plots.len == 0 and f.core.panels[k].laidOut and f.core.panels[k].shown.len > 0 and
          f.core.shownFile(k) >= 0 and
          f.core.sessions[f.core.shownFile(k)].name == "vib_correlated.sgd")
    step("a spectrogram", proc (f: FrameInfo) =
      let base = f.core.sessions[f.core.shownFile(f.core.findPanel(MainPanel))].base
      f.apply(Command(kind: ckOpenPlot, plotView: avSpectrogram, plotTraces: @[base])),
      proc (f: FrameInfo): bool =
        result = f.core.plots.len == 1 and f.core.plots[0].view == avSpectrogram and
          not f.core.plots[0].waiting and f.markOf("new plot 1.image").size.x > 0
        if result:
          shown = axisLimitsOf("new plot 1.image")
          doAssert shown[0].hi > shown[0].lo, "the image's axes are not shown")
    step("the longer file", proc (f: FrameInfo) =
      f.apply(Command(kind: ckShowFile, panel: MainPanel, path: sample)),
      proc (f: FrameInfo): bool =
        result = f.core.plots[0].file == "vib_signature.sgd" and not f.core.plots[0].waiting and
          f.markOf("new plot 1.image").size.x > 0
        if result:
          if shots.len > 0:
            createDir(shots)
            discard f.savePng(shots / "altfit-spectrogram.png")
          let img = f.core.plots[0].result.image
          let x1 = img.xOf(img.cols - 1) + img.dx / 2
          let now = axisLimitsOf("new plot 1.image")
          doAssert x1 != shown[0].hi, "both files' images end at " & $x1
          doAssert abs(now[0].hi - x1) < 1e-6 * x1,
            "the time axis stayed at " & $now[0] & " for an image ending at " & $x1)

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
          if f.core.plots.len > 0:
            let w = f.core.plots[0]
            failed.add " (window " & w.file & " " & $w.view & " traces " & $w.traces &
              ", waiting " & $w.waiting & ", problem " & w.result.problem & ")"
          else:
            var last = ""
            for e in f.core.log: last = e.text
            failed.add " (no window; the log says: " & last & ")"
          f.stop()
    let code = run(RunOptions(openPaths: @[sample], windowSize: (1500, 900), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      persist: true, configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguialtfit: ok"

when isMainModule:
  main()
