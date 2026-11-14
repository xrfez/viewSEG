## The limits of the plot's view in each display mode, in the running
## frontend, headless, driven by SDL events as the user's mouse and keyboard
## send them, on a record of more traces than the plot has pixel columns
## (the long spread fixture: 400 traces, in a window that leaves the plot
## fewer than 400 columns):
##
## - in the wiggle mode (the default) the record opens at one pixel a trace
##   from its first trace, all of its time, with the scroll bar along the
##   traces; the image is what the CPU reference draws with wiggles and no
##   density;
## - zooming out with the wheel, with `-`, with Ctrl + Left, typing a huge
##   traces-per-inch value, the fit button, Ctrl + 0 and a larger window
##   all stop at one pixel a trace, so every trace in view is drawn;
## - zoomed in to two and three pixels a trace (where density took over
##   before), wiggles are drawn and no density;
## - in the density mode the wheel zooms out until the whole record fills
##   the plot, drawn as density;
## - back in the wiggle mode, a view wider than the limit is narrowed to
##   it, keeping its left edge;
## - the file is never changed.
##
## Seen to fail: with the 4-pixel hand-over to density put back in the
## frame the plot draws (density where `pixelsPerTrace < 4`), "opens at
## the limit: 10203 of 11648 pixels off the reference" (the image was
## density); with `viewLimits` giving the wiggle modes no widest view,
## "opens at the limit did not happen" (the whole record, 0.84 pixels a
## trace); with Ctrl + 0 fitting the whole record (`fitAll`, as it did),
## "Ctrl + 0 did not happen"; with a typed scale kept about its centre (as
## it was), "Enter did not happen" (the left edge moved).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, options, os, strutils, times]
import viewSEG/core/[geometry, state, wiggle]
import viewSEG/ui/imgui/app
import utils/[fixtures, plotref]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

func near(a, b: float64; eps = 1e-6): bool = abs(a - b) <= eps * max(1.0, abs(b))

proc main() =
  withFixtures fx:
    let path = fx.longSpreadSegy()
    let before = snapshot(path)
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var failed = ""
    var plot: Rect
    var mid: Vec2
    var columns = 0
    # Images drawn, and frames since the last: the image of a frame shows the
    # hover and selection of the frame before.
    var images, quiet = 0

    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

    proc answered(f: FrameInfo): bool =
      let tiles = f.core.tiles(f.core.findPanel(MainPanel))
      tiles.len > 0 and tiles[^1].request == f.panel.pending and
        f.tracePanel.drawnView.sameSpans(f.panel.view)

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc click(f: FrameInfo; at: Vec2) =
      f.pressMouse(at, true)
      f.pressMouse(at, false)

    proc chord(f: FrameInfo; key: SimKey; mods: set[SimMod] = {}) =
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

    proc centreOf(f: FrameInfo; mark: string): Vec2 =
      let b = f.markOf(mark)
      doAssert b.size.x > 0, "no " & mark
      vec2(round(b.pos.x + b.size.x / 2), round(b.pos.y + b.size.y / 2))

    proc display(f: FrameInfo; mode: DisplayMode) =
      var d = f.panel.layers[0].display
      d.mode = mode
      f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)

    proc pixels(f: FrameInfo): float64 = pixelsPerTrace(f.tracePanel.drawnView)

    proc atLimit(f: FrameInfo; what: string): bool =
      ## The view drawn is one pixel a trace, all of the record's time; the
      ## image is the reference's, with no density.
      result = f.answered and near(f.pixels, 1) and quiet >= 2
      if result:
        let v = f.tracePanel.drawnView
        let lim = limitsOf(f.panel.layout)
        doAssert v.timeMs == lim[axTime].bounds, what & ": " & $v.timeMs
        doAssert v.traces.lo >= lim[axTraces].bounds.lo and
          v.traces.hi <= lim[axTraces].bounds.hi, what & ": " & $v.traces
        let s = f.capture
        doAssert s.wiggles and not s.density
        let (bad, seen) = s.mismatches(step = 3)
        doAssert bad == 0, what & ": " & $bad & " of " & $seen & " pixels off the reference"

    proc wiggles(f: FrameInfo; px: float64; what: string): bool =
      ## Zoomed in to `px` pixels a trace: wiggles, no density.
      result = f.answered and near(f.pixels, px, 1e-3) and quiet >= 2
      if result:
        let s = f.capture
        let (bad, seen) = s.mismatches(step = 3)
        doAssert bad == 0, what & ": " & $bad & " of " & $seen & " pixels off the reference"

    # -------------------------------------------------------------- steps --
    step("opens at the limit", noop, proc (f: FrameInfo): bool =
      if not (f.panel.laidOut and f.answered and f.markOf("plot.data").size.x > 0): return
      plot = f.markOf("plot.data")
      columns = f.tracePanel.drawnView.columns
      doAssert columns < LongSpread, "the plot is too wide for the test: " & $columns &
        " columns for " & $LongSpread & " traces"
      mid = vec2(round(plot.pos.x + plot.size.x * 0.5), round(plot.pos.y + plot.size.y * 0.4))
      result = f.atLimit("opens at the limit")
      if result:
        let v = f.tracePanel.drawnView
        doAssert v.traces.lo == -0.5, "not from the first trace: " & $v.traces
        doAssert f.markOf("plot.bar.traces").size.x > 0, "no scroll bar along the traces")

    step("zoomed in to 3 pixels a trace", proc (f: FrameInfo) =
      var v = f.panel.view
      v.traces = Span(lo: 99.5, hi: 99.5 + float64(columns) / 3)
      f.showView(v), proc (f: FrameInfo): bool = f.wiggles(3, "3 pixels a trace"))

    step("zoomed in to 2 pixels a trace", proc (f: FrameInfo) =
      var v = f.panel.view
      v.traces = Span(lo: 99.5, hi: 99.5 + float64(columns) / 2)
      f.showView(v), proc (f: FrameInfo): bool = f.wiggles(2, "2 pixels a trace"))

    step("the wheel stops at the limit", proc (f: FrameInfo) =
      f.moveMouse(mid)
      f.scrollWheel(mid, -6), proc (f: FrameInfo): bool = f.atLimit("wheel"))

    step("Ctrl + 0 at the limit, from the first trace", proc (f: FrameInfo) =
      var v = f.panel.view
      v.traces = Span(lo: 199.5, hi: 219.5)
      f.showView(v), proc (f: FrameInfo): bool =
        result = f.answered and f.panel.view.traces.lo == 199.5
        if result:
          f.click(mid) # the keys go to the focused window
          f.chord(skZero, {smCtrl}))
    step("Ctrl + 0", noop, proc (f: FrameInfo): bool =
      result = f.atLimit("Ctrl + 0") and f.tracePanel.drawnView.traces.lo == -0.5)

    step("- stops at the limit", proc (f: FrameInfo) =
      var v = f.panel.view
      v.traces = Span(lo: 49.5, hi: 79.5)
      f.showView(v), proc (f: FrameInfo): bool =
        result = f.answered and f.panel.view.traces.lo == 49.5
        if result:
          for _ in 0 ..< 8: f.chord(skMinus))
    step("-", noop, proc (f: FrameInfo): bool = f.atLimit("-"))

    step("Ctrl + Left stops at the limit", proc (f: FrameInfo) =
      var v = f.panel.view
      v.traces = Span(lo: 49.5, hi: 79.5)
      f.showView(v), proc (f: FrameInfo): bool =
        result = f.answered and f.panel.view.traces.lo == 49.5
        if result:
          for _ in 0 ..< 8: f.chord(skLeft, {smCtrl}))
    step("Ctrl + Left", noop, proc (f: FrameInfo): bool = f.atLimit("Ctrl + Left"))

    step("a typed traces per inch stops at the limit", proc (f: FrameInfo) =
      var v = f.panel.view
      v.traces = Span(lo: 49.5, hi: 79.5)
      f.showView(v), proc (f: FrameInfo): bool =
        f.answered and f.panel.view.traces.lo == 49.5)
    step("to the trace scale box", proc (f: FrameInfo) =
      f.moveMouse(f.centreOf("plot.trace scale")), proc (f: FrameInfo): bool = true)
    step("the trace scale box", proc (f: FrameInfo) =
      f.click(f.centreOf("plot.trace scale")), proc (f: FrameInfo): bool = f.typing)
    step("typing", proc (f: FrameInfo) = f.typeText("100000"),
      proc (f: FrameInfo): bool = true)
    step("Enter", proc (f: FrameInfo) = f.chord(skEnter), proc (f: FrameInfo): bool =
      result = f.atLimit("typed scale") and f.tracePanel.drawnView.traces.lo == 49.5)

    step("the fit button stops at the limit", proc (f: FrameInfo) =
      var v = f.panel.view
      v.traces = Span(lo: 149.5, hi: 159.5)
      f.showView(v), proc (f: FrameInfo): bool =
        f.answered and f.panel.view.traces.lo == 149.5)
    step("to the fit button", proc (f: FrameInfo) =
      f.moveMouse(f.centreOf("plot.fit")), proc (f: FrameInfo): bool = true)
    step("fit", proc (f: FrameInfo) = f.click(f.centreOf("plot.fit")), proc (f: FrameInfo): bool =
      result = f.atLimit("fit") and f.tracePanel.drawnView.traces.lo == -0.5)

    step("a larger window stops at the limit", proc (f: FrameInfo) =
      let (w, h) = f.windowSize
      f.resizeWindow(w + 40, h), proc (f: FrameInfo): bool =
        result = f.tracePanel.drawnView.columns > columns and f.atLimit("larger window"))
    step("larger than the record: all of it, no wider", proc (f: FrameInfo) =
      let (w, h) = f.windowSize
      f.resizeWindow(w + 200, h), proc (f: FrameInfo): bool =
        let v = f.tracePanel.drawnView
        result = v.columns > LongSpread and f.answered and quiet >= 2
        if result:
          doAssert v.traces == limitsOf(f.panel.layout)[axTraces].bounds, $v
          let (bad, seen) = f.capture.mismatches(step = 3)
          doAssert bad == 0, "larger: " & $bad & " of " & $seen & " pixels off the reference")
    step("and back", proc (f: FrameInfo) =
      let (w, h) = f.windowSize
      f.resizeWindow(w - 240, h), proc (f: FrameInfo): bool =
        result = f.tracePanel.drawnView.columns == columns and f.atLimit("smaller window"))

    step("density zooms out to the whole record", proc (f: FrameInfo) =
      f.display(dmDensity)
      f.moveMouse(mid)
      f.scrollWheel(mid, -8), proc (f: FrameInfo): bool =
        let lim = limitsOf(f.panel.layout)
        result = f.answered and f.tracePanel.drawnView.traces == lim[axTraces].bounds
        if result:
          let s = f.capture
          doAssert s.density and not s.wiggles
          let (bad, seen) = s.mismatches(step = 3)
          doAssert bad == 0, "density: " & $bad & " of " & $seen & " pixels off the reference")

    step("back to wiggles, narrowed from the left edge", proc (f: FrameInfo) =
      var v = f.panel.view
      v.traces = Span(lo: 49.5, hi: 399.5)
      f.showView(v), proc (f: FrameInfo): bool =
        result = f.answered and f.panel.view.traces.lo == 49.5
        if result: f.display(dmWiggle))
    step("narrowed", noop, proc (f: FrameInfo): bool =
      result = f.atLimit("back to wiggles") and f.tracePanel.drawnView.traces.lo == 49.5)

    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
      if f.tracePanel.imagesDrawn != images:
        images = f.tracePanel.imagesDrawn
        quiet = 0
      else: inc quiet
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
        elif wait > 400:
          failed = steps[at].name & " did not happen"
          f.stop()

    let code = run(RunOptions(maxFrames: 8000, openPaths: @[path], windowSize: (760, 1000),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguilimits: ", steps.len, " steps on ", columns, " columns"
    doAssert snapshot(path) == before, "showing the file changed it"

main()
