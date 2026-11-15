## A new window size keeps the plot's scale and its top-left corner, in the
## running frontend, headless, the main window resized as the user resizes
## it (the Seismic window with it), on the survey fixture (24 traces, 1 s):
##
## - the whole record in view, a smaller window: the same traces and ms per
##   inch (the scale boxes say the same), the same top-left corner, and
##   scroll bars for what no longer fits; the same size again: all of it,
##   no bars;
## - a window larger than the record at that scale: the scale grows, only
##   as much as fills the plot (all of the record, nothing past it);
## - zoomed in, smaller and larger windows: the same scales and top-left
##   corner.
##
## Seen to fail: with `resized` keeping the whole record along an axis that
## showed it (as it did), "smaller: the scale changed" (the time axis
## stretched to the new height).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func perPixel(v: Viewport): (float64, float64) =
  ## The view's scale: positions and ms per pixel.
  (v.traces.width / float64(v.columns), v.timeMs.width / float64(v.rows))

func same(a, b: float64): bool = abs(a - b) <= 1e-9 * max(1.0, max(abs(a), abs(b)))

func sameView(a, b: Viewport): bool =
  ## The same spans, but for the rounding of two rescalings.
  same(a.traces.lo, b.traces.lo) and same(a.traces.hi, b.traces.hi) and
    same(a.timeMs.lo, b.timeMs.lo) and same(a.timeMs.hi, b.timeMs.hi)

withFixtures fx:
  let path = fx.surveySegy()
  var steps: seq[Step]
  var at = 0
  var started = false
  var wait = 0 # frames since the step began, at `since`
  var since = getMonoTime()
  var failed = ""
  var images, quiet = 0
  var before: Viewport
  var texts: (string, string)
  var size: (int, int)
  template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard
  proc settled(f: FrameInfo): bool =
    let tiles = f.core.tiles(f.core.findPanel(MainPanel))
    f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
      f.tracePanel.drawnView.sameSpans(f.panel.view) and quiet >= 3
  proc bounds(f: FrameInfo): ViewLimits = f.panel.viewLimits(f.panel.view.columns)
  proc bars(f: FrameInfo): (bool, bool) =
    (f.markOf("plot.bar.traces").size.x > 0, f.markOf("plot.bar.time").size.y > 0)
  proc keptScale(f: FrameInfo; what: string): bool =
    ## The plot has another size than `before` and the same scale and
    ## top-left corner.
    let v = f.tracePanel.drawnView
    result = f.settled and (v.columns, v.rows) != (before.columns, before.rows)
    if result:
      let (a, b) = (perPixel(v), perPixel(before))
      doAssert same(a[0], b[0]) and same(a[1], b[1]), what & ": the scale changed: " &
        $a & " for " & $b
      doAssert v.traces.lo == before.traces.lo and v.timeMs.lo == before.timeMs.lo,
        what & ": the top-left corner moved: " & $v & " from " & $before
      doAssert f.tracePanel.scaleTexts == texts, what & ": the boxes say " &
        $f.tracePanel.scaleTexts & " for " & $texts
  proc note(f: FrameInfo) =
    before = f.tracePanel.drawnView
    texts = f.tracePanel.scaleTexts
    size = f.windowSize

  # The dock gives a smaller main window's loss to the windows beside the
  # plot, so the window grows first, then goes back to its size.
  step("the whole record", noop, proc (f: FrameInfo): bool =
    result = f.settled
    if result:
      let l = f.bounds
      doAssert f.panel.view.traces == l[axTraces].bounds and
        f.panel.view.timeMs == l[axTime].bounds, $f.panel.view
      doAssert f.bars == (false, false)
      f.note())
  step("larger than the record", proc (f: FrameInfo) =
    f.resizeWindow(size[0] + 300, size[1] + 250), proc (f: FrameInfo): bool =
      let v = f.tracePanel.drawnView
      result = f.settled and v.columns > before.columns and v.rows > before.rows
      if result:
        let l = f.bounds
        doAssert v.traces == l[axTraces].bounds and v.timeMs == l[axTime].bounds,
          "not all of the record, or past it: " & $v
        let (a, b) = (perPixel(v), perPixel(before))
        doAssert a[0] < b[0] and a[1] < b[1], "the scale did not grow: " & $a & " for " & $b
        doAssert f.bars == (false, false)
        f.note())
  step("smaller", proc (f: FrameInfo) = f.resizeWindow(size[0] - 300, size[1] - 250),
    proc (f: FrameInfo): bool =
    result = f.keptScale("smaller")
    if result:
      doAssert f.bars == (true, true), "no scroll bars for what no longer fits: " & $f.bars)
  step("the larger size again", proc (f: FrameInfo) = f.resizeWindow(size[0], size[1]),
    proc (f: FrameInfo): bool =
    let v = f.tracePanel.drawnView
    result = f.settled and v.columns == before.columns and v.rows == before.rows
    if result:
      doAssert v.sameView(before), $v & ", was " & $before
      doAssert f.bars == (false, false) and f.tracePanel.scaleTexts == texts)
  step("zoomed in", proc (f: FrameInfo) =
    var v = f.panel.view
    v.traces = Span(lo: 4.5, hi: 12.5)
    v.timeMs = Span(lo: 100, hi: 300)
    f.showView(v), proc (f: FrameInfo): bool =
      result = f.settled and f.panel.view.traces.lo == 4.5
      if result: f.note())
  step("zoomed in, smaller", proc (f: FrameInfo) =
    f.resizeWindow(size[0] - 300, size[1] - 250), proc (f: FrameInfo): bool =
      f.keptScale("zoomed in, smaller"))
  step("zoomed in, larger again", proc (f: FrameInfo) =
    f.resizeWindow(size[0], size[1]), proc (f: FrameInfo): bool =
      let v = f.tracePanel.drawnView
      result = f.settled and v.columns == before.columns and v.rows == before.rows
      if result:
        doAssert v.sameView(before), "zoomed in, larger again: " & $v & ", was " & $before
        doAssert f.tracePanel.scaleTexts == texts)

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

  let code = run(RunOptions(openPaths: @[path], windowSize: (1000, 700),
    theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  echo "tguiresize: ", steps.len, " steps"
