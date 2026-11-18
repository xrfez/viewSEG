## The Explain icon of every plot in the running frontend, headless, on files
## of samples/: the Seismic plot, the map, an FFT window's two plots and the
## live Spectrum panel, each analysis window (spectrogram, envelope, phase
## spectrum, cross-correlation, f-k, vibrator signature: every pane), the
## Compare window's four plots, a reference's window, the Generate dialog and
## the Headers window's graph:
##
## - each shows its icon, marked `<window>.explain` (`.explain 2` for the next
##   plot of the window, and so on);
## - hovering it shows a tooltip at once, and the tooltip is the words
##   `core/explain` gives for that plot now (the same the agents' `state`
##   reads), with no two items under the pointer sharing an id (`idConflict`);
## - the plot still takes a key and a click afterwards, and a click on the icon
##   goes to the trace under it: the icon is no item of its own.
##
## Seen to fail: with the Seismic plot's icon not drawn, "the record and the
## survey did not happen"; with the tooltip's text another plot's, the hover's
## "plot.explain says ..." mismatch; with the icon an InvisibleButton, "reaches
## the trace under it did not happen" (the icon took the click).
##
## Needs a display: run under the tester (it gives each test its own).
## `VIEWSEG_SCREENSHOTS=<dir>` saves explain-seismic.png and explain-spectrum.png there.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[explain, geometry, join, state]
import viewSEG/ui/imgui/[app, plotwindows]
import viewSEG/view/maplayers
import utils/[fixtures, waiting]

const root = currentSourcePath().parentDir.parentDir

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

proc tipOf(f: FrameInfo; mark: string): string =
  ## The words the tooltip of `mark`'s icon shows now; "" for none.
  let prefix = mark & ".tip:"
  for n in f.markNames(prefix): return n[prefix.len .. ^1]

proc main*() =
  let land = root / "samples" / "land" / "shots.sgy"
  let sps = (root / "samples" / "land" / "land.s", root / "samples" / "land" / "land.r")
  let vib = root / "samples" / "vib" / "vib_signature.sgd"
  doAssert fileExists(land) and fileExists(sps[0]) and fileExists(sps[1]) and fileExists(vib)
  let shots = getEnv("VIEWSEG_SCREENSHOTS")

  withFixtures fx:
    let config = fx.dir / "config"
    createDir(config)
    var steps: seq[Step] = @[]
    var wait = 0
    var pointAt: Vec2
    var selectedBefore = 0
    var gainBefore = 0.0
    var refId = ""
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    proc point(mark: string) =
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = r.centre
        f.moveMouse(pointAt), after(3))
    proc click(mark: string) =
      point(mark)
      step("click " & mark, proc (f: FrameInfo) =
        f.pressMouse(pointAt, true, 1)
        f.pressMouse(pointAt, false, 1), after(3))
    proc rightClick(mark: string) =
      ## A right click on plot `mark`, then Explain in the menu it opens.
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = vec2(r.pos.x + 40, r.pos.y + 20) # the part of the plot that is always in view
        f.moveMouse(pointAt), after(3))
      step("right-click " & mark, proc (f: FrameInfo) =
        f.pressMouse(pointAt, true, 3)
        f.pressMouse(pointAt, false, 3), proc (f: FrameInfo): bool =
        f.markOf(mark & ".menu.explain").size.x > 0)
      step("Explain in the menu of " & mark, proc (f: FrameInfo) =
        let at = f.markOf(mark & ".menu.explain").centre
        f.moveMouse(at)
        f.pressMouse(at, true, 1)
        f.pressMouse(at, false, 1), after(3))
    proc hover(mark: string; want: proc (f: FrameInfo): string; shot = "") =
      ## Right click on plot `mark`, Explain: its popover is `want`, no id clashes.
      rightClick(mark)
      step("hover " & mark, noop, proc (f: FrameInfo): bool =
        let text = f.tipOf(mark)
        result = text.len > 0
        if result:
          doAssert not f.idConflict, mark & ": two items under the pointer share an id"
          doAssert text == want(f), mark & " says\n" & text & "\nnot\n" & want(f)
          doAssert text.startsWith("Shows: ") and "Reading it: " in text, text
          if shots.len > 0 and shot.len > 0: discard f.savePng(shots / shot)
          f.pressKey(skEscape, true) # Esc closes the popover
          f.pressKey(skEscape, false))
    proc hoverHas(mark: string; parts: openArray[string]) =
      ## The pointer on `mark`'s icon: its tooltip holds each of `parts`.
      let wanted = @parts
      rightClick(mark)
      step("hover " & mark, noop, proc (f: FrameInfo): bool =
        let text = f.tipOf(mark)
        result = text.len > 0
        if result:
          doAssert not f.idConflict, mark & ": two items under the pointer share an id"
          for part in wanted: doAssert part in text, mark & ": no \"" & part & "\" in\n" & text
          f.pressKey(skEscape, true)
          f.pressKey(skEscape, false))
    proc hoverAll(window: string; panes: proc (f: FrameInfo): int;
        want: proc (f: FrameInfo; pane: int): string; reach = false) =
      ## The window's panes, each icon in turn (those drawn on the screen).
      var next = 0
      var phase = 0
      var tick = 0
      step("every pane of " & window, noop, proc (f: FrameInfo): bool =
        let n = panes(f)
        doAssert n >= 1, window & " has no plot"
        let mark = window & ".explain" & (if next == 0: "" else: " " & $(next + 1))
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        # (its corner is inside the window too: a plot below the window's edge is out of reach)
        let win = f.markOf(window)
        let inside = r.pos.y + r.size.y < 990 and r.pos.y > 60 and
          (win.size.y == 0 or r.pos.y + 25 < win.pos.y + win.size.y)
        doAssert inside or not reach, mark & " is out of reach: " & $r & " in " &
          $win & " (every pane of this window is in view at its default size)"
        if not inside:
          inc next
          return next >= n
        inc tick
        let corner = vec2(r.pos.x + 40, r.pos.y + 20) # the part that is always in view
        case phase
        of 0:
          f.moveMouse(corner)
          if tick >= 3: (phase, tick) = (1, 0)
        of 1:
          if tick == 1:
            f.pressMouse(corner, true, 3)
            f.pressMouse(corner, false, 3)
          if f.markOf(mark & ".menu.explain").size.x > 0: (phase, tick) = (2, 0)
        of 2:
          let at = f.markOf(mark & ".menu.explain").centre
          if tick == 1:
            f.moveMouse(at)
          if tick == 3:
            f.pressMouse(at, true, 1)
            f.pressMouse(at, false, 1)
          if tick >= 6: (phase, tick) = (3, 0)
        else:
          let text = f.tipOf(mark)
          if text.len > 0:
            doAssert not f.idConflict, mark & ": two items under the pointer share an id"
            doAssert text == want(f, next), mark & " says\n" & text & "\nnot\n" & want(f, next)
            inc next
            f.pressKey(skEscape, true)
            f.pressKey(skEscape, false)
            f.moveMouse(vec2(2, 500))
            (phase, tick) = (0, 0)
        next >= n)

    # --- the Seismic plot, and the map beside it
    step("the record and the survey", noop, proc (f: FrameInfo): bool =
      f.answered and f.markOf("map.data").size.x > 0 and f.markOf("plot.explain").size.x > 0)
    hover("plot.explain", proc (f: FrameInfo): string = f.core.explainSeismic(
      f.core.findPanel(MainPanel)), "explain-seismic.png")
    step("the pointer on a trace", proc (f: FrameInfo) =
      let plot = f.markOf("plot.data")
      let v = f.panel.view
      let x = plot.pos.x + float32((3.0 - v.traces.lo) / v.traces.width) * plot.size.x
      pointAt = vec2(round(x), round(plot.pos.y + 8))
      gainBefore = f.panel.layers[0].display.gainDb
      f.moveMouse(pointAt), after(3))
    step("]: more gain", proc (f: FrameInfo) =
      f.pressKey(skRightBracket, true)
      f.pressKey(skRightBracket, false), proc (f: FrameInfo): bool =
      f.panel.layers[0].display.gainDb > gainBefore)
    step("a focusing click", proc (f: FrameInfo) =
      f.pressMouse(pointAt, true, 1)
      f.pressMouse(pointAt, false, 1), after(8))
    step("a click selects the trace", proc (f: FrameInfo) =
      f.pressMouse(pointAt, true, 1)
      f.pressMouse(pointAt, false, 1), proc (f: FrameInfo): bool =
      f.core.selection.selectedCount == 1)
    step("a click on the icon", proc (f: FrameInfo) =
      selectedBefore = f.core.selection.selectedCount
      f.apply(Command(kind: ckClearSelection))
      pointAt = f.markOf("plot.explain").centre
      f.moveMouse(pointAt), after(3))
    step("reaches the trace under it", proc (f: FrameInfo) =
      f.pressMouse(pointAt, true, 1)
      f.pressMouse(pointAt, false, 1), proc (f: FrameInfo): bool =
      f.core.selection.selectedCount == 1) # the icon is no item: the plot has the click
    hover("map.explain", proc (f: FrameInfo): string =
      explain(pkMap, f.core.mapFacts(f.core.unitsOf, f.core.shownLengths.unit.abbreviation)))

    # --- an FFT window, its phase, and the live Spectrum panel
    step("two traces selected", proc (f: FrameInfo) =
      let b = f.core.sessions[0].base
      f.apply(Command(kind: ckSelect, traces: @[b, b + 1, b + 2, b + 3, b + 4],
        mode: smReplace)), proc (f: FrameInfo): bool = f.core.selection.selectedCount == 5)
    step("an FFT window", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSpectrum, spectrumTraces: @[f.core.sessions[0].base])),
      proc (f: FrameInfo): bool =
        f.core.spectra.len == 2 and not f.core.spectra[1].waiting and
          f.markOf("fft 1.explain").size.x > 0)
    hover("fft 1.explain", proc (f: FrameInfo): string =
      f.core.explainSpectrum(f.core.spectra[1], false), "explain-spectrum.png")
    step("its phase", proc (f: FrameInfo) =
      var d = f.core.spectra[1].display
      d.phase = true
      f.apply(Command(kind: ckSpectrumDisplay, spectrum: 1, spectrumShow: d)),
      proc (f: FrameInfo): bool = f.markOf("fft 1.explain 2").size.x > 0)
    hover("fft 1.explain 2", proc (f: FrameInfo): string =
      f.core.explainSpectrum(f.core.spectra[1], true))
    step("the FFT window closes", proc (f: FrameInfo) =
      f.apply(Command(kind: ckCloseSpectrum, spectrum: 1)),
      proc (f: FrameInfo): bool = f.core.spectra.len == 1)
    click("menu.Window")
    click("menu.window.spectrum")
    step("the Spectrum panel", noop, proc (f: FrameInfo): bool =
      f.core.spectra[0].shown and not f.core.spectra[0].waiting and
        f.markOf("spectrum.explain").size.x > 0)
    hover("spectrum.explain", proc (f: FrameInfo): string =
      f.core.explainSpectrum(f.core.spectra[0], false))
    click("menu.Window")
    click("menu.window.spectrum")
    step("the Spectrum panel closes", noop, proc (f: FrameInfo): bool =
      not f.core.spectra[0].shown)

    # --- a reference, a correlation against it, the reference's window
    step("a reference", proc (f: FrameInfo) =
      f.apply(Command(kind: ckGenerateReference, refGenerate: GeneratedReference(
        name: "AAA sweep", law: rlLinear, f1Hz: 8, f2Hz: 40, durationMs: 400,
        dtMs: f.core.shownIntervalMs, amplitude: 1))),
      proc (f: FrameInfo): bool =
        for e in f.core.references.entries:
          if e.name == "AAA sweep": refId = e.id
        refId.len > 0)
    step("chosen", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelectReference, refId: refId)),
      proc (f: FrameInfo): bool = f.core.chosenReference == refId)

    # --- each analysis window, one at a time, every pane
    proc window(view: AnalysisView) =
      step("open the " & $view, proc (f: FrameInfo) =
        let b = f.core.sessions[0].base
        f.apply(Command(kind: ckOpenPlot, plotView: view,
          plotTraces: @[b, b + 1, b + 2, b + 3, b + 4])),
        proc (f: FrameInfo): bool =
          f.core.plots.len == 1 and not f.core.plots[0].waiting and
            f.core.plots[0].result.problem.len == 0 and f.markOf("new plot 1.explain").size.x > 0)
      # (a window's number is the smallest free: 1 each time here)
      hoverAll("new plot 1", proc (f: FrameInfo): int =
        max(1, f.core.plots[0].result.plots.len), proc (f: FrameInfo; pane: int): string =
        f.core.explainPane(f.core.plots[0], pane))
      step("close the " & $view, proc (f: FrameInfo) =
        f.apply(Command(kind: ckClosePlot, plot: f.core.plots[0].id)),
        proc (f: FrameInfo): bool = f.core.plots.len == 0)
    for view in [avSpectrogram, avEnvelope, avPhase, avCorrelation, avFk]:
      window(view)
    step("the vibrator's file", proc (f: FrameInfo) =
      f.apply(Command(kind: ckShowFile, panel: MainPanel, path: vib)),
      proc (f: FrameInfo): bool =
        let i = f.core.shownFile(f.core.findPanel(MainPanel))
        i >= 0 and f.core.sessions[i].path == vib and f.panel.laidOut)
    step("no reference chosen", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelectReference, refId: "")),
      proc (f: FrameInfo): bool = f.core.chosenReference.len == 0)
    # (the window id was used by earlier windows, whose size ImGui remembers: the vibrator window
    # is held at its default size, 780 x 980 points, as a new one opens)
    step("the default size", proc (f: FrameInfo) =
      forcedVibratorSize = (780'f32, 980'f32), after(2))
    step("open the vibrator signature", proc (f: FrameInfo) =
      let b = f.core.sessions[f.core.shownFile(f.core.findPanel(MainPanel))].base
      f.apply(Command(kind: ckOpenPlot, plotView: avVibrator,
        plotTraces: @[b, b + 1, b + 2, b + 3],
        plotParams: AnalysisParams(reactionMassKg: 3600, baseplateMassKg: 1800))),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.problem.len == 0 and f.core.plots[0].result.plots.len == 4 and
          f.markOf("new plot 1.explain").size.x > 0)
    hoverAll("new plot 1", proc (f: FrameInfo): int = f.core.plots[0].result.plots.len,
      proc (f: FrameInfo; pane: int): string = f.core.explainPane(f.core.plots[0], pane),
      reach = true)
    # with Details the other ground force has its own force plot: its icon too (the window
    # then scrolls, so only the panes drawn on the screen are tried)
    step("Details on", proc (f: FrameInfo) =
      var p = f.core.plots[0].params
      p.details = true
      f.apply(Command(kind: ckPlotDisplay, plot: f.core.plots[0].id, plotParams: p)),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.plots.len == 5 and f.markOf("new plot 1.explain").size.x > 0)
    hoverAll("new plot 1", proc (f: FrameInfo): int = f.core.plots[0].result.plots.len,
      proc (f: FrameInfo; pane: int): string = f.core.explainPane(f.core.plots[0], pane))
    step("the vibrator window closes", proc (f: FrameInfo) =
      f.apply(Command(kind: ckClosePlot, plot: f.core.plots[0].id)),
      proc (f: FrameInfo): bool = f.core.plots.len == 0)

    # --- Compare, and a reference's window
    step("the reference chosen again", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelectReference, refId: refId)),
      proc (f: FrameInfo): bool = f.core.chosenReference == refId)
    step("traces A and B", proc (f: FrameInfo) =
      let b = f.core.sessions[0].base
      f.apply(Command(kind: ckSetCompare, compareSlot: cwA, compareTrace: b))
      f.apply(Command(kind: ckSetCompare, compareSlot: cwB, compareTrace: b + 1)),
      proc (f: FrameInfo): bool =
        f.core.compareA.filled and f.core.compareB.filled and f.core.compareOpen and
          f.markOf("compare.explain 4").size.x > 0)
    proc comparePlot(mark: string; kind: PlotKind) =
      hover(mark, proc (f: FrameInfo): string = f.core.explainCompare(kind))
    comparePlot("compare.explain", pkCompareSignal)
    comparePlot("compare.explain 2", pkCompareSpectrum)
    comparePlot("compare.explain 3", pkComparePhase)
    comparePlot("compare.explain 4", pkCompareCorrelation)
    step("Compare closes", proc (f: FrameInfo) =
      f.apply(Command(kind: ckCompareWindow, compareOpen: false)),
      proc (f: FrameInfo): bool = not f.core.compareOpen)
    step("view the reference", proc (f: FrameInfo) =
      f.apply(Command(kind: ckViewReference, refId: refId)), proc (f: FrameInfo): bool =
      f.core.refViews.len == 1 and not f.core.refViews[0].waiting and
        f.markOf("reference.view.explain 2").size.x > 0)
    hover("reference.view.explain", proc (f: FrameInfo): string =
      explain(pkReferenceSignal, refViewFacts(f.core.refViews[0])))
    hover("reference.view.explain 2", proc (f: FrameInfo): string =
      explain(pkReferenceSpectrum, refViewFacts(f.core.refViews[0])))
    step("the reference's window closes", proc (f: FrameInfo) =
      f.apply(Command(kind: ckCloseRefView, refWindow: f.core.refViews[0].id)),
      proc (f: FrameInfo): bool = f.core.refViews.len == 0)

    # --- the Generate dialog (a sweep), and the Headers window's graph
    click("menu.Operations")
    click("menu.Generate a reference...")
    step("the dialog", noop, proc (f: FrameInfo): bool =
      f.markOf("generate.explain 2").size.x > 0 and f.markOf("generate.explain").size.x > 0)
    hoverHas("generate.explain", ["a linear sweep from", " Hz over ", "Shows: "])
    hoverHas("generate.explain 2", ["Amplitude in dB below its peak", "Reading it: "])
    click("generate.cancel")
    step("the dialog closes", noop, proc (f: FrameInfo): bool =
      f.markOf("generate.explain").size.x == 0)
    click("headers.tab table")
    step("the table", noop, proc (f: FrameInfo): bool = f.markOf("table.row 0").size.x > 0)
    click("table.graph choice")
    click("table.graph keys.offset")
    step("the graph", noop, proc (f: FrameInfo): bool = f.markOf("table.explain").size.x > 0)
    hoverHas("table.explain", ["the column \"", "the record shown", "Reading it: "])

    var at = 0
    var started = false
    var failed = ""
    var since = getMonoTime()
    proc onFrame(f: FrameInfo) =
      inc wait
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if not started:
        steps[at].act(f)
        started = true
        since = getMonoTime()
        wait = 0
      elif wait >= 2 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 900, since):
        failed = steps[at].name & " did not happen"
        for e in f.core.log: echo "  log: ", e.text
        for w in f.core.plots: echo "  plot ", w.id, ": ", w.result.problem, " ",
            w.result.plots.len,
          " waiting ", w.waiting, " ", w.traces
        f.stop()
    let code = run(RunOptions(openPaths: @[land, sps[0], sps[1]], windowSize: (1600, 1000),
      theme: forceDark, persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguiexplain: ", steps.len, " steps"

when isMainModule: main()
