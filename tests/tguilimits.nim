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
##   all stop at one pixel a trace, so every trace in view is drawn; a
##   window larger than the record shows all of it, and smaller again keeps
##   that scale;
## - at the limit the wiggle line is thin (a quarter of the trace spacing),
##   so the sine's troughs are light, not a band of lines;
## - zoomed in to two and three pixels a trace (where density took over
##   before), wiggles are drawn and no density;
## - in the density mode the wheel zooms out until the whole record fills
##   the plot, drawn as density;
## - back in the wiggle mode, a view wider than the limit is narrowed to
##   it, keeping its left edge;
## - the file is never changed.
##
## Then the wiggle modes' margin, on the survey fixture (24 traces, gain
## None) and a record of one trace (`edges`):
##
## - at fit the view reaches past the first and last trace by the swing the
##   overlap allows (half a spacing at overlap 1), their full swing inside
##   it, their lobes drawn in the margins, the image the reference's, and no
##   scroll bar;
## - the pick finds trace 0 over its baseline and no trace in the margin;
## - overlap 2 at fit shows all of it again, margins included; zoomed in,
##   another overlap leaves the view where it is;
## - at either end of the scroll bar the edge trace swings whole;
## - density has no margin;
## - a record of one trace shows whole: its swing reaches within a pixel of
##   both edges of the plot.
##
## Seen to fail: with the 4-pixel hand-over to density put back in the
## frame the plot draws (density where `pixelsPerTrace < 4`), "opens at
## the limit: 10203 of 11648 pixels off the reference" (the image was
## density); with `viewLimits` giving the wiggle modes no widest view,
## "opens at the limit did not happen" (the whole record, 0.84 pixels a
## trace); with Ctrl + 0 fitting the whole record (`fitAll`, as it did),
## "Ctrl + 0 did not happen"; with the line drawn a full pixel wide at one
## pixel a trace (as it was), "opens at the limit: 134 of 104208 pixels
## light"; with a typed scale kept about its centre (as
## it was), "Enter did not happen" (the left edge moved). With no margin
## (`traceMargin` 0, as before), "opens with the margins" found the fit at
## -0.5 .. 23.5; with `relimited` keeping the view at a new overlap whatever
## it showed, "overlap 2 from fit: all of it did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
##
## Every step that compares pixels waits for two quiet frames first (the image
## of a frame shows the hover of the frame before). The density step once did
## not: on a busy machine the new tile came in the frame after the wheel, and
## the image still showed the trace hovered before it ("density: 104 of 11648
## pixels off the reference", one column tinted: 3 of 4 runs among the other
## tests, 1 of 8 alone under xvfb-run while other work loaded the machine).

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state, wiggle]
import viewSEG/ui/imgui/app
import utils/[fixtures, plotref, waiting]

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
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
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

    proc bounds(f: FrameInfo): Span =
      ## The traces the view may show: the record's and the margin of the
      ## edge traces' lobes in a wiggle mode.
      f.panel.viewLimits(f.tracePanel.drawnView.columns)[axTraces].bounds

    proc atLimit(f: FrameInfo; what: string): bool =
      ## The view drawn is one pixel a trace, all of the record's time; the
      ## image is the reference's, with no density.
      result = f.answered and near(f.pixels, 1) and quiet >= 2
      if result:
        let v = f.tracePanel.drawnView
        let lim = limitsOf(f.panel.layout)
        doAssert v.timeMs == lim[axTime].bounds, what & ": " & $v.timeMs
        doAssert v.traces.lo >= f.bounds.lo and v.traces.hi <= f.bounds.hi, what & ": " &
          $v.traces
        let s = f.capture
        doAssert s.wiggles and not s.density
        let (bad, seen) = s.mismatches(step = 3)
        doAssert bad == 0, what & ": " & $bad & " of " & $seen & " pixels off the reference"
        # a thin line where the traces are close: the troughs of the sine are
        # paper with a little line, not a band of lines (every column a line)
        var light = 0
        for c in s.image:
          if c.r > 160: inc light
        doAssert light * 10 > s.image.len, what & ": " & $light & " of " & $s.image.len &
          " pixels light (a band of lines)"

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
        doAssert v.traces.lo == f.bounds.lo, "not from the first trace: " & $v.traces
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
      result = f.atLimit("Ctrl + 0") and f.tracePanel.drawnView.traces.lo == f.bounds.lo)

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
    step("to the gear", proc (f: FrameInfo) =
      f.moveMouse(f.centreOf("plot.more")), proc (f: FrameInfo): bool = true)
    step("the gear", proc (f: FrameInfo) =
      f.click(f.centreOf("plot.more")), proc (f: FrameInfo): bool =
      f.markOf("plot.more popover").size.x > 100 and wait > 4)
    var tabAt: Vec2
    var tabHeld = 0
    step("the Scales tab steady", proc (f: FrameInfo) =
      let c = f.centreOf("plot.more tab scales")
      tabAt = c
      tabHeld = 0
      f.moveMouse(c), proc (f: FrameInfo): bool =
      let c = f.centreOf("plot.more tab scales")
      if abs(c.x - tabAt.x) < 1 and abs(c.y - tabAt.y) < 1: inc tabHeld
      else:
        tabAt = c
        f.moveMouse(c)
        tabHeld = 0
      tabHeld >= 2)
    step("the Scales tab", proc (f: FrameInfo) =
      f.pressMouse(tabAt, true)
      f.pressMouse(tabAt, false), proc (f: FrameInfo): bool =
      f.markOf("plot.trace scale").size.x > 0)
    var boxAt: Vec2
    var boxHeld = 0
    step("to the trace scale box", proc (f: FrameInfo) =
      boxAt = f.centreOf("plot.trace scale")
      boxHeld = 0
      f.moveMouse(boxAt), proc (f: FrameInfo): bool =
      let c = f.centreOf("plot.trace scale")
      if abs(c.x - boxAt.x) < 1 and abs(c.y - boxAt.y) < 1: inc boxHeld
      else:
        boxAt = c
        f.moveMouse(c)
        boxHeld = 0
      boxHeld >= 2)
    step("the trace scale box", proc (f: FrameInfo) =
      f.pressMouse(boxAt, true)
      f.pressMouse(boxAt, false), proc (f: FrameInfo): bool = f.typing)
    step("typing", proc (f: FrameInfo) = f.typeText("100000"),
      proc (f: FrameInfo): bool = true)
    step("Enter", proc (f: FrameInfo) = f.chord(skEnter), proc (f: FrameInfo): bool =
      result = f.atLimit("typed scale") and f.tracePanel.drawnView.traces.lo == 49.5)

    step("close the gear", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
      f.markOf("plot.more popover").size.x == 0)
    step("the fit button stops at the limit", proc (f: FrameInfo) =
      var v = f.panel.view
      v.traces = Span(lo: 149.5, hi: 159.5)
      f.showView(v), proc (f: FrameInfo): bool =
        f.answered and f.panel.view.traces.lo == 149.5)
    step("to the fit button", proc (f: FrameInfo) =
      f.moveMouse(f.centreOf("plot.fit")), proc (f: FrameInfo): bool = true)
    step("fit", proc (f: FrameInfo) = f.click(f.centreOf("plot.fit")), proc (f: FrameInfo): bool =
      result = f.atLimit("fit") and f.tracePanel.drawnView.traces.lo == f.bounds.lo)

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
          doAssert v.traces == f.bounds, $v
          let (bad, seen) = f.capture.mismatches(step = 3)
          doAssert bad == 0, "larger: " & $bad & " of " & $seen & " pixels off the reference")
    var larger: Viewport
    step("and back: the scale kept", proc (f: FrameInfo) =
      larger = f.tracePanel.drawnView
      let (w, h) = f.windowSize
      f.resizeWindow(w - 240, h), proc (f: FrameInfo): bool =
        let v = f.tracePanel.drawnView
        result = v.columns == columns and f.answered and quiet >= 2
        if result: # a new size keeps the scale, from the same left edge
          doAssert near(f.pixels, pixelsPerTrace(larger)) and v.traces.lo == larger.traces.lo,
            $v & " after " & $larger
          let (bad, seen) = f.capture.mismatches(step = 3)
          doAssert bad == 0, "smaller: " & $bad & " of " & $seen & " pixels off the reference")

    step("density zooms out to the whole record", proc (f: FrameInfo) =
      f.display(dmDensity)
      f.moveMouse(mid)
      f.scrollWheel(mid, -8), proc (f: FrameInfo): bool =
        let lim = limitsOf(f.panel.layout)
        result = f.answered and quiet >= 2 and
          f.tracePanel.drawnView.traces == lim[axTraces].bounds
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
        (wait, since) = (0, getMonoTime())
      else:
        inc wait
        if wait >= 2 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 400, since):
          failed = steps[at].name & " did not happen"
          f.stop()

    let code = run(RunOptions(openPaths: @[path], windowSize: (760, 1000),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguilimits: ", steps.len, " steps on ", columns, " columns"
    doAssert snapshot(path) == before, "showing the file changed it"

main()

proc edges() =
  ## The margin of the wiggle modes, on the survey fixture (24 traces, gain
  ## None: the samples as they are, the strongest clipped at the overlap)
  ## and on a record of one trace.
  withFixtures fx:
    let path = fx.surveySegy()
    let one = fx.oneTraceSegy()
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
    var failed = ""
    var images, quiet = 0
    var grab: Vec2

    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

    proc settled(f: FrameInfo): bool =
      let tiles = f.core.tiles(f.core.findPanel(MainPanel))
      tiles.len > 0 and tiles[^1].request == f.panel.pending and
        f.tracePanel.drawnView.sameSpans(f.panel.view) and quiet >= 2

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc display(f: FrameInfo; mode: DisplayMode; overlap: float64) =
      var d = f.panel.layers[0].display
      (d.mode, d.overlap, d.gain) = (mode, overlap, dgNone)
      f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)

    proc whole(f: FrameInfo; what: string): bool =
      ## The image is the reference's, the first and last trace's full swing
      ## inside the view, and their lobes drawn in the margin past their
      ## cells.
      let s = f.capture
      let n = float64(f.panel.layout.traces)
      let o = s.display.effectiveOverlap
      doAssert s.view.traces.lo <= -o + 1e-9 and s.view.traces.hi >= n - 1 + o - 1e-9,
        what & ": the edge traces' swing of " & $o & " is not in " & $s.view.traces
      let (bad, seen) = s.mismatches(step = 2)
      doAssert bad == 0, what & ": " & $bad & " of " & $seen & " pixels off the reference"
      # ink in the margin left of the first trace's cell, and right of the last
      var left, right = 0
      for j in 0 ..< s.h:
        for i in 0 ..< s.w:
          if not close(s.at(i, j), s.ink.background):
            if s.xOf(i) < -0.5: inc left
            if s.xOf(i) > n - 0.5: inc right
      doAssert left > 0 and right > 0, what & ": no lobes in the margins: " & $(left, right)
      true

    step("opens with the margins", proc (f: FrameInfo) =
      f.moveMouse(vec2(4, 4)), proc (f: FrameInfo): bool =
        if not (f.panel.laidOut and f.panel.layers.len > 0): return
        if f.panel.layers[0].display.gain != dgNone:
          f.display(dmWiggle, 1)
          return
        result = f.settled
        if result:
          doAssert f.tracePanel.drawnView.traces == Span(lo: -1, hi: 24), $f.tracePanel.drawnView
          doAssert f.markOf("plot.bar.traces").size.x == 0, "a scroll bar at fit"
          discard f.whole("fit"))

    step("the pick stays on the traces", proc (f: FrameInfo) =
      let r = f.markOf("plot.data")
      let v = f.tracePanel.drawnView
      f.moveMouse(vec2(round(r.pos.x + float32((0 - v.traces.lo) / v.traces.width) * r.size.x),
        round(r.pos.y + r.size.y / 2))), proc (f: FrameInfo): bool =
        result = f.pick.inside and f.pick.found
        if result: doAssert f.pick.trace == 0, "trace " & $f.pick.trace)
    step("none in the margin", proc (f: FrameInfo) =
      let r = f.markOf("plot.data")
      f.moveMouse(vec2(r.pos.x + 2, round(r.pos.y + r.size.y / 2))), proc (f: FrameInfo): bool =
        result = f.pick.inside and wait > 3
        if result: doAssert not f.pick.found, "a trace in the margin: " & $f.pick.trace)

    step("overlap 2 from fit: all of it", proc (f: FrameInfo) =
      f.moveMouse(vec2(4, 4))
      f.display(dmWiggle, 2), proc (f: FrameInfo): bool =
        result = f.settled and f.tracePanel.drawnView.traces == Span(lo: -2, hi: 25)
        if result: discard f.whole("overlap 2"))

    step("zoomed in: the view stays", proc (f: FrameInfo) =
      var v = f.panel.view
      v.traces = Span(lo: 4.5, hi: 12.5)
      f.showView(v), proc (f: FrameInfo): bool =
        result = f.settled and f.panel.view.traces.lo == 4.5
        if result:
          f.display(dmWiggle, 1.5))
    step("zoomed in, another overlap", noop, proc (f: FrameInfo): bool =
      result = f.settled and f.panel.layers[0].display.overlap == 1.5
      if result: doAssert f.panel.view.traces == Span(lo: 4.5, hi: 12.5), $f.panel.view)

    step("to the thumb", proc (f: FrameInfo) =
      let th = f.markOf("plot.thumb.traces")
      doAssert th.size.x > 0, "no scroll bar zoomed in"
      grab = vec2(round(th.pos.x + th.size.x / 2), round(th.pos.y + th.size.y / 2))
      f.moveMouse(grab), proc (f: FrameInfo): bool = true)
    step("the bar's left end", proc (f: FrameInfo) =
      f.pressMouse(grab, true)
      f.moveMouse(vec2(grab.x - 3000, grab.y)), proc (f: FrameInfo): bool =
        result = f.panel.view.traces.lo == -1.5 # overlap 1.5: a margin of 1
        if result: f.pressMouse(vec2(grab.x - 3000, grab.y), false))
    step("at the left end", noop, proc (f: FrameInfo): bool =
      result = f.settled
      if result:
        let s = f.capture
        doAssert s.view.traces.lo <= -1.5 + 1e-9
        let (bad, seen) = s.mismatches(step = 2)
        doAssert bad == 0, "left end: " & $bad & " of " & $seen & " pixels off the reference")
    step("to the thumb again", proc (f: FrameInfo) =
      let th = f.markOf("plot.thumb.traces")
      grab = vec2(round(th.pos.x + th.size.x / 2), round(th.pos.y + th.size.y / 2))
      f.moveMouse(grab), proc (f: FrameInfo): bool = true)
    step("the bar's right end", proc (f: FrameInfo) =
      f.pressMouse(grab, true)
      f.moveMouse(vec2(grab.x + 3000, grab.y)), proc (f: FrameInfo): bool =
        result = f.panel.view.traces.hi == 24.5
        if result: f.pressMouse(vec2(grab.x + 3000, grab.y), false))
    step("at the right end", noop, proc (f: FrameInfo): bool =
      result = f.settled
      if result:
        let s = f.capture
        doAssert s.view.traces.hi >= 23 + 1.5 - 1e-9
        let (bad, seen) = s.mismatches(step = 2)
        doAssert bad == 0, "right end: " & $bad & " of " & $seen & " pixels off the reference")

    step("density: no margin", proc (f: FrameInfo) =
      f.moveMouse(vec2(4, 4))
      f.display(dmDensity, 1.5)
      f.showView(fitAll(f.panel.layout, 0, 0)), proc (f: FrameInfo): bool =
        result = f.settled and f.panel.layers[0].display.mode == dmDensity
        if result:
          doAssert f.tracePanel.drawnView.traces == Span(lo: -0.5, hi: 23.5),
            $f.tracePanel.drawnView
          let (bad, seen) = f.capture.mismatches(step = 2)
          doAssert bad == 0, "density: " & $bad & " of " & $seen & " pixels off the reference")

    step("a record of one trace shows whole", proc (f: FrameInfo) =
      f.display(dmWiggle, 1)
      f.apply(Command(kind: ckOpen, paths: @[one])), proc (f: FrameInfo): bool =
        let s = f.core.findSession(f.panel.layers[0].source.file)
        result = s >= 0 and f.core.sessions[s].path.endsWith("one-trace.sgy") and f.settled
        if result:
          let v = f.tracePanel.drawnView
          doAssert v.traces == Span(lo: -1, hi: 1), $v
          let sh = f.capture
          let (bad, seen) = sh.mismatches(step = 2)
          doAssert bad == 0, "one trace: " & $bad & " of " & $seen & " pixels off the reference"
          # the sine's peaks reach the clip: its fill and line swing to
          # within a pixel of both edges, and no further
          var lo, hi = -1
          for j in 0 ..< sh.h:
            for i in 0 ..< sh.w:
              if not close(sh.at(i, j), sh.ink.background):
                if lo < 0 or i < lo: lo = i
                hi = max(hi, i)
          doAssert lo <= 1 and hi >= sh.w - 2, "the swing reaches " & $lo & " .. " & $hi &
            " of " & $sh.w & " columns")

    proc onFrame(f: FrameInfo) =
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
        (wait, since) = (0, getMonoTime())
      else:
        inc wait
        if wait >= 2 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 400, since):
          failed = steps[at].name & " did not happen"
          f.stop()

    let code = run(RunOptions(openPaths: @[path], windowSize: (1280, 900),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguilimits: ", steps.len, " steps of the margins"

edges()
