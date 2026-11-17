## Time across, the display header's columns stand left of the plot: in the
## running frontend, headless, on a record of 20 000 traces of 500 ms whose
## channel numbers grow from one digit to five,
##
## - a pan along the traces, from the first to the last, leaves the plot
##   where it was: each column is as wide as its field's longest value over
##   the whole gather (the reader's count), not over the traces seen so far;
## - fields added to the header make the plot narrower, and the time span
##   shown stays whole (the whole record), as when the header's rows change
##   time down: a plot made shorter along time by the header keeps the time
##   span, not the scale.
##
## Seen to fail: with the columns as wide as the labels seen so far (the
## reader's `widest` not taken in `drawPlot`), "the plot moved by 7.0
## pixels as the view panned"; with a new header width taken as a new plot
## size (`resized`, keeping the scale), "the time shown is (lo: 0.0, hi:
## 438.87...) of (lo: 0.0, hi: 499.0)" once the fields were added.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

const Traces = 20_000

type Step = proc (f: FrameInfo; wait: int): bool {.closure.}

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc answered(f: FrameInfo): bool =
  ## The view's tile taken in and drawn.
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.tracePanel.drawnView.sameSpans(f.panel.view)

proc wholeTime(f: FrameInfo): Span =
  ## The record's time, as far as the view can show it.
  f.panel.viewLimits(f.panel.view.columns)[axTime].bounds

proc view(f: FrameInfo; first, last: float64) =
  ## The traces `first` to `last`, the whole record's time.
  var v = f.panel.view
  v.traces = Span(lo: first - 0.5, hi: last + 0.5)
  v.timeMs = f.wholeTime
  f.showView(v)

proc fields(f: FrameInfo; shown: seq[HeaderField]) =
  f.apply Command(kind: ckHeader, panel: MainPanel, header: HeaderChoice(auto: false,
    fields: shown))

proc sameTime(a, b: Span): bool = abs(a.lo - b.lo) < 1e-6 and abs(a.hi - b.hi) < 1e-6

proc main*() =

  withFixtures fx:
    var plotX = 0'f32
    var stage = 0
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
    var reached: seq[string]
    let steps: seq[(string, Step)] = @[
      ("shown", Step(proc (f: FrameInfo; wait: int): bool =
        result = f.panel.laidOut and f.answered and wait > 3)),
      ("time across, the channel", Step(proc (f: FrameInfo; wait: int): bool =
        if wait == 1:
          var d = f.panel.layers[0].display
          d.mode = dmDensity # (no limit of a trace a pixel)
          d.orientation = orTimeAcross
          f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
          f.fields(@[hfChannel])
        if wait == 6: f.view(0, 99)
        result = wait > 12 and f.answered and f.panel.view.traces.lo < 1)),
      ("the first traces", Step(proc (f: FrameInfo; wait: int): bool =
        result = wait > 4 and f.answered
        if result:
          doAssert f.panel.widest[hfChannel] == len($Traces), $f.panel.widest
          plotX = f.markOf("plot.data").pos.x
          doAssert sameTime(f.panel.view.timeMs, f.wholeTime),
            "the time shown is " & $f.panel.view.timeMs & " of " & $f.wholeTime)),
      ("the last traces", Step(proc (f: FrameInfo; wait: int): bool =
        if wait == 1: f.view(Traces - 100, Traces - 1)
        result = wait > 4 and f.answered and f.panel.view.traces.hi > Traces - 2
        if result:
          let x = f.markOf("plot.data").pos.x
          doAssert x == plotX, "the plot moved by " & $(x - plotX) & " pixels as the view panned"
          doAssert sameTime(f.panel.view.timeMs, f.wholeTime),
            "the time shown is " & $f.panel.view.timeMs & " of " & $f.wholeTime)),
      ("more fields", Step(proc (f: FrameInfo; wait: int): bool =
        if wait == 1: f.fields(@[hfRecord, hfTrace, hfChannel])
        result = wait > 8 and f.answered
        if result:
          doAssert f.markOf("plot.data").pos.x > plotX, "the header is no wider"
          doAssert sameTime(f.panel.view.timeMs, f.wholeTime),
            "the time shown is " & $f.panel.view.timeMs & " of " & $f.wholeTime)),
      ("time down, fewer fields", Step(proc (f: FrameInfo; wait: int): bool =
        if wait == 1:
          var d = f.panel.layers[0].display
          d.orientation = orTimeDown
          f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        if wait == 6: f.view(0, 99)
        if wait == 12: f.fields(@[hfChannel])
        result = wait > 20 and f.answered
        if result:
          doAssert sameTime(f.panel.view.timeMs, f.wholeTime),
            "time down: the time shown is " & $f.panel.view.timeMs & " of " & $f.wholeTime))]
    proc onFrame(f: FrameInfo) =
      inc wait
      if stage < steps.len:
        if steps[stage][1](f, wait):
          reached.add steps[stage][0]
          inc stage
          (wait, since) = (0, getMonoTime())
        else: doAssert not overdue(wait, 400, since), "stopped at \"" & steps[stage][0] &
          "\" after " & $reached
      else: f.stop()
    let code = run(RunOptions(openPaths: @[fx.manyTracesSegy(Traces, 500)],
      windowSize: (1600, 1000), theme: forceDark, onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert stage == steps.len, "stopped at stage " & $stage & " after " & $reached
    echo "tguiturnheader: ", reached.join(", ")

when isMainModule:
  main()
