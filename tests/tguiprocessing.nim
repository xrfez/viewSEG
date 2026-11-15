## The Seismic window's filters, headless, with real clicks and keys, on a
## SEG-D record with a time break and a pilot beside its 24 seismic traces:
## the strip has the filters' button and its Raw toggle is off and does
## nothing (nor does `P`) while there is no filter; the drop-down opens on a
## click and stays open while it is set: Band-pass gives the default
## corners and the plot is filtered (a tile whose reader filtered every
## trace of its request); dragging the f2 slider sends the new corner
## frame after frame, the plot following (at least three tiles made while
## the button is held, each from the samples at hand: no read), and the
## last tile is of the corner where the drag ended; "+ 60 Hz" adds a notch
## at 60 Hz with two harmonics; the Aux box filters the auxiliary traces
## too; `P` shows the traces raw (the strip says so) and processed again,
## and the settings keep the filters for a new plot.
##
## Seen to fail: with the drop-down's sliders sending only when let go
## (`igIsItemDeactivatedAfterEdit`), "0 tiles while f2 was dragged"; with
## `filterKeys` not called, "P did not show the traces raw".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves filters-popup.png there.

import std/[math, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/[app, plotfilters]
import utils/fixtures

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
template processing(f: FrameInfo): Processing = f.panel.layers[0].processing

proc answered(f: FrameInfo): bool =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

proc lastTile(f: FrameInfo): Tile =
  f.core.tiles(f.core.findPanel(MainPanel))[^1]

withFixtures fx:
  var steps: seq[Step]
  var at = 0
  var started = false
  var wait = 0
  var failed = ""
  var pointAt: Vec2
  var dragged: seq[float64] # f2 as each new tile came while the button was held
  var lastId = 0'u64
  var shots = getEnv("VIEWSEG_SCREENSHOTS")
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard
  proc after(n: int): proc (f: FrameInfo): bool =
    var frames = 0
    result = proc (f: FrameInfo): bool =
      inc frames
      frames >= n
  proc click(mark: string) =
    step("to " & mark, proc (f: FrameInfo) =
      let r = f.markOf(mark)
      doAssert r.size.x > 0, mark & " is not shown"
      pointAt = r.centre
      f.moveMouse(pointAt), after(2))
    step("click " & mark, proc (f: FrameInfo) =
      f.pressMouse(pointAt, true)
      f.pressMouse(pointAt, false), after(3))
  proc key(k: SimKey) =
    step("key " & $k, proc (f: FrameInfo) =
      f.pressKey(k, true)
      f.pressKey(k, false), after(3))

  step("the record", noop, proc (f: FrameInfo): bool =
    result = f.answered and f.panel.layout.traces == 24
    if result:
      doAssert f.markOf("plot.filters").size.x > 0 and f.markOf("plot.filters raw").size.x > 0,
        "no filters in the strip"
      doAssert not f.processing.hasFilters and f.lastTile.filtered == 0)
  # P with no filter: nothing (the plot has the focus once clicked)
  click("plot.data")
  key(skP)
  step("P with no filter", noop, proc (f: FrameInfo): bool =
    doAssert not f.processing.raw, "P turned raw on with no filter"
    true)
  click("plot.filters")
  step("the drop-down", noop, proc (f: FrameInfo): bool =
    f.markOf("plot.filters band band-pass").size.x > 0)
  click("plot.filters band band-pass")
  step("band-pass", noop, proc (f: FrameInfo): bool =
    result = f.processing.band == pbBandPass and f.answered and f.lastTile.filtered > 0
    if result:
      doAssert f.lastTile.filtered == f.lastTile.request.count
      doAssert f.markOf("plot.filters f2").size.x > 0, "the drop-down closed"
      lastId = f.lastTile.id)
  # drag f2 from the left of its slider to the right, over many frames
  step("press f2", proc (f: FrameInfo) =
    let r = f.markOf("plot.filters f2")
    pointAt = vec2(round(r.pos.x + 6), round(r.pos.y + r.size.y / 2))
    f.moveMouse(pointAt)
    f.pressMouse(pointAt, true), after(3))
  for i in 1 .. 12:
    step("drag f2 " & $i, proc (f: FrameInfo) =
      pointAt.x += 14
      f.moveMouse(pointAt),
      proc (f: FrameInfo): bool =
        let t = f.lastTile
        if t.id != lastId and t.request == f.panel.pending:
          lastId = t.id
          dragged.add f.processing.f2
          doAssert t.cached and t.chunks == 0, "a moved corner read the file"
        f.answered)
  step("let go of f2", proc (f: FrameInfo) = f.pressMouse(pointAt, false),
    proc (f: FrameInfo): bool =
      result = f.answered
      if result:
        doAssert dragged.len >= 3, $dragged.len & " tiles while f2 was dragged"
        doAssert f.processing.f2 > Processing().f2, "f2 did not move: " & $f.processing.f2
        echo "tguiprocessing: f2 while dragged: ", dragged)
  click("plot.filters notch add 60")
  step("a notch", noop, proc (f: FrameInfo): bool =
    result = f.processing.notches.len == 1 and f.answered
    if result:
      doAssert f.processing.notches[0].hz == 60 and f.processing.notches[0].harmonics == 3
      doAssert "notch 60 Hz x3" in label(f.processing), label(f.processing)
      if shots.len > 0:
        doAssert f.savePng(shots / "filters-popup.png"))
  click("plot.filters aux")
  step("aux", noop, proc (f: FrameInfo): bool =
    result = f.processing.aux and f.answered)
  key(skEscape)
  click("plot.data")
  key(skP)
  step("raw", noop, proc (f: FrameInfo): bool =
    result = f.answered
    if result:
      doAssert f.processing.raw, "P did not show the traces raw"
      doAssert f.lastTile.filtered == 0 and f.lastTile.cached)
  key(skP)
  step("processed", noop, proc (f: FrameInfo): bool =
    result = f.answered and not f.processing.raw and f.lastTile.filtered > 0)
  step("kept", noop, proc (f: FrameInfo): bool =
    var want = f.processing
    want.raw = false
    doAssert f.core.settings.plot.processing == want, $f.core.settings.plot.processing
    true)

  proc onFrame(f: FrameInfo) =
    if f.index == 0: f.moveMouse(vec2(4, 4))
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
  let code = run(RunOptions(maxFrames: 6000, openPaths: @[fx.twoSetSegd()],
    windowSize: (1400, 900), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  echo "tguiprocessing: ", steps.len, " steps"
