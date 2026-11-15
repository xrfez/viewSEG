## The analysis windows (New plot) in the running frontend, headless, by
## real clicks and keys, on a record of four seismic traces and a pilot
## (an auxiliary trace):
##
## - Window > New plot > Spectrogram, with two traces selected, opens a
##   window of them: an image in many colours (the colour map), and its
##   scale;
## - its cursor, the window focused, steps a frame with Right and a
##   frequency bin with Up, held where the keys put it, and reads its time,
##   frequency and dB; Esc lets it go;
## - the plot's right-click menu > New plot > Cross-correlation opens a
##   window of the trace under the pointer against the record's pilot;
## - closed (`close plot`), a window goes.
##
## Seen to fail: with the image's keys not read (`keyMove` never called),
## "Right did not move the cursor"; with the menu's entry not sent
## (`newPlot` dropped in the app), "Window > New plot did not open a window".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, options, os, sets, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/fixtures

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

proc traceX(f: FrameInfo; position: int): Vec2 =
  let plot = f.markOf("plot.data")
  let v = f.panel.view
  let x = plot.pos.x + float32((float64(position) - v.traces.lo) / v.traces.width) * plot.size.x
  vec2(round(x), round(plot.pos.y + 8))

withFixtures fx:
  var steps: seq[Step] = @[]
  var pointAt: Vec2
  var held = PlotCursor()
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
  proc click(mark: string; button = 1) =
    to(mark)
    step("click " & mark, proc (f: FrameInfo) =
      f.pressMouse(pointAt, true, button)
      f.pressMouse(pointAt, false, button), after(3))
  proc key(name: string; k: SimKey) =
    step(name, proc (f: FrameInfo) =
      f.pressKey(k, true)
      f.pressKey(k, false), after(3))

  step("the record", noop, proc (f: FrameInfo): bool = f.answered)
  step("two selected", proc (f: FrameInfo) =
    f.apply(Command(kind: ckSelect, traces: @[0, 1], mode: smReplace)),
    proc (f: FrameInfo): bool = f.core.selection.selectedCount == 2)
  click("menu.Window")
  to("menu.window.newplot")
  click("menu.newplot." & $avSpectrogram)
  step("its window", noop, proc (f: FrameInfo): bool =
    doAssert f.core.plots.len == 1, "Window > New plot did not open a window"
    result = not f.core.plots[0].waiting and f.markOf("new plot 1.image").size.x > 0
    if result:
      let w = f.core.plots[0]
      doAssert w.view == avSpectrogram and w.traces == @[0, 1] and w.result.problem == "",
        w.result.problem
      # the image in many colours: the colour map, not a plain background
      let r = f.markOf("new plot 1.image")
      let pixels = f.readFrame()
      var colours = initHashSet[(uint8, uint8, uint8)]()
      for y in countup(int(r.pos.y) + 2, int(r.pos.y + r.size.y) - 3, 3):
        for x in countup(int(r.pos.x) + 2, int(r.pos.x + r.size.x) - 3, 3):
          let p = pixels[y * f.width + x]
          colours.incl (p.r, p.g, p.b)
      doAssert colours.len > 20, $colours.len & " colours in the image")
  # the cursor: the window focused by a click on its image, then the keys
  click("new plot 1.image")
  key("Right", skRight)
  step("held", noop, proc (f: FrameInfo): bool =
    held = f.core.plots[0].cursor
    doAssert held.held, "Right did not move the cursor"
    true)
  key("Right again", skRight)
  key("Up", skUp)
  step("a frame on, a bin up", noop, proc (f: FrameInfo): bool =
    let c = f.core.plots[0].cursor
    doAssert c.held and c.x == held.x + 1 and c.y == held.y + 1, $c & " after " & $held
    let text = f.plotWindows.readoutOf(1)
    doAssert " ms · " in text and " Hz: " in text and text.endsWith(" dB"), text
    true)
  key("Esc", skEscape)
  step("let go", noop, proc (f: FrameInfo): bool = not f.core.plots[0].cursor.held)
  # closed (it floats over the plot's middle), its number free again
  step("closed", proc (f: FrameInfo) =
    f.apply(Command(kind: ckClosePlot, plot: 1)),
    proc (f: FrameInfo): bool = f.core.plots.len == 0)
  # the plot's menu over a trace: its cross-correlation against the pilot
  step("over trace 3", proc (f: FrameInfo) = f.moveMouse(f.traceX(2)),
    proc (f: FrameInfo): bool = f.pick.found and f.pick.position == 2)
  step("the plot's menu", proc (f: FrameInfo) =
    pointAt = f.traceX(2)
    f.pressMouse(pointAt, true, 3)
    f.pressMouse(pointAt, false, 3),
    proc (f: FrameInfo): bool = f.markOf("plot.menu.newplot").size.x > 0)
  to("plot.menu.newplot")
  click("plot.menu.newplot." & $avCorrelation)
  step("a correlation", noop, proc (f: FrameInfo): bool =
    result = f.core.plots.len == 1 and not f.core.plots[0].waiting
    if result:
      let w = f.core.plots[0]
      doAssert w.id == 1, "the number of the window closed is not taken again"
      doAssert w.traces == @[2] and w.result.problem == "" and "pilot" in w.reference,
        $w.traces & " " & w.result.problem & " " & w.reference)

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
  echo "tguiplots: ok"
