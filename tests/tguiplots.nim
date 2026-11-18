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
## - an envelope window's curve plots take the same cursor: clicked, Right
##   holds it a sample on in that plot, with the time written on the axis
##   and the reading "Held · ...";
## - the plot's right-click menu > New plot > Cross-correlation opens a
##   window of the trace under the pointer; with no reference chosen it says
##   so and the old reference buttons are gone;
## - closed (`close plot`), a window goes;
## - Window > New plot > Vibrator signature on four selected traces shows
##   its roles' table and four plots; Limits... opens the check, and
##   checking it draws the phase limits and shows the table;
## - an f-k of the record: its image's cursor, held by the keys, reads the
##   wavenumber (per trace), the frequency, dB and the apparent velocity;
## - seven more windows each open inside the main window;
## - the toolbar's Spectrogram button is greyed with no trace selected (a
##   click on it opens nothing) and, with two selected, opens the window the
##   menu opens.
##
## - each Freeze pin toggles (the envelope and the vibrator signature): frozen
##   on, the window keeps its filters while the plot's change; off, it follows.
##
## Seen to fail: with the Limits label left as "harmonic", "no label Harmonic";
## with the pin's click not flipping `frozen`, "frozen new plot
## 1.freeze did not happen"; with the image's keys not read (`keyMove` never called),
## "Right did not move the cursor"; with the menu's entry not sent
## (`newPlot` dropped in the app), "Window > New plot did not open a window";
## with a curve view's Right not read, "Right did not hold the curve plot's
## cursor: (held: false, ...)"; with the windows placed a step further for
## each number from the middle, whether or not they fit (`placeNext` not
## used), "new plot 5 at (pos: (x: 492.0, y: 272.0), size: (x: 640.0, y:
## 620.0)) is not inside the main window's (pos: (x: 0.0, y: 67.0), size:
## (x: 1400.0, y: 806.0))" (it opened as a window of its own, outside); with
## the vibrator signature's table not drawn, "limits on did not happen";
## with an f-k's velocity not read, "0.0 /trace · 125.2 Hz: -49.35 dB";
## with the toolbar's Spectrogram dispatch left out of the app, "the toolbar's
## Spectrogram opens its window did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, options, os, sets, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/remote/tools
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

proc main*() =

  withFixtures fx:
    var steps: seq[Step] = @[]
    var pointAt: Vec2
    var edgeAt = 0
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

    let notch = Processing(notches: @[NotchFilter(hz: 60, widthHz: 2, harmonics: 3)])
    proc freezePin(mark: string; i: int) =
      ## The Freeze pin at `mark` (plot `i`): a click turns it on, and the plot's
      ## filters changed are not followed while it is on; a click again follows them.
      click(mark)
      step("frozen " & mark, noop, proc (f: FrameInfo): bool =
        f.core.plots[i].frozen)
      step("the plot's filters notched, " & mark, proc (f: FrameInfo) =
        f.apply(Command(kind: ckProcessing, panel: MainPanel, processing: notch)), after(30))
      step("frozen " & mark & " keeps its filters", noop, proc (f: FrameInfo): bool =
        doAssert f.core.plots[i].processing.notches.len == 0,
          "a frozen window followed the filters: " & mark
        true)
      click(mark)
      step("unfrozen " & mark & " follows the filters", noop, proc (f: FrameInfo): bool =
        result = not f.core.plots[i].frozen and f.core.plots[i].processing.notches.len == 1 and
          not f.core.plots[i].waiting)
      step("the plot's filters back, " & mark, proc (f: FrameInfo) =
        f.apply(Command(kind: ckProcessing, panel: MainPanel, processing: Processing())),
        proc (f: FrameInfo): bool = f.answered and not f.core.plots[i].waiting and
          f.core.plots[i].processing.notches.len == 0)

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
    # a curve view: the envelope; its cursor held by the keys in the plot
    # clicked, with its values on the axes
    step("an envelope", proc (f: FrameInfo) =
      f.apply(Command(kind: ckOpenPlot, plotView: avEnvelope, plotTraces: @[0])),
      proc (f: FrameInfo): bool =
        result = f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.markOf("new plot 1.plot 1.data").size.x > 0
        if result:
          let win = f.markOf("new plot 1")
          let pin = f.markOf("new plot 1.freeze")
          doAssert pin.size.x > 0, "no Freeze pin"
          doAssert pin.pos.x + pin.size.x > win.pos.x + win.size.x - 28,
            "freeze not at the right of the first row")
    freezePin("new plot 1.freeze", 0)
    click("new plot 1.plot 1.data")
    key("Right on the envelope", skRight)
    step("held on the phase plot", noop, proc (f: FrameInfo): bool =
      held = f.core.plots[0].cursor
      doAssert held.held and f.core.plots[0].cursorOn == 1, "Right did not hold the curve " &
        "plot's cursor: " & $held & " on " & $f.core.plots[0].cursorOn
      true)
    key("Right again on the envelope", skRight)
    step("a sample on", noop, proc (f: FrameInfo): bool =
      let c = f.core.plots[0].cursor
      doAssert c.held and c.x == held.x + 1, $c & " after " & $held
      let text = f.plotWindows.readoutOf(1)
      doAssert text.startsWith("Held · ") and " ms" in text, text
      doAssert f.markOf("new plot 1.plot 1.cursor x").size.x > 0, "no value on the time axis"
      true)
    step("the envelope closed", proc (f: FrameInfo) =
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
        doAssert w.traces == @[2] and w.result.problem == NoReferenceChosen and
          w.result.plots.len == 0, $w.traces & " " & w.result.problem
        doAssert f.markOf("new plot 1.reference selected").size.x == 0
        doAssert f.markOf("new plot 1.reference pilot").size.x == 0
        doAssert f.markOf("new plot 1.references").size.x > 0, "no References button")
    # a vibrator signature of four selected traces: its roles in a table
    # (Ref, GF, M, B, in their order), its four plots; Limits... opens the
    # check, and checking it shows the table
    step("four selected", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelect, traces: @[0, 1, 2, 3], mode: smReplace)),
      proc (f: FrameInfo): bool = f.core.selection.selectedCount == 4)
    click("menu.Window")
    to("menu.window.newplot")
    click("menu.newplot." & $avVibrator)
    step("a vibrator signature", noop, proc (f: FrameInfo): bool =
      result = f.core.plots.len == 2 and not f.core.plots[1].waiting and
        f.markOf("new plot 2.plot 3.data").size.x > 0
      if result:
        let w = f.core.plots[1]
        doAssert w.view == avVibrator and w.traces == @[0, 1, 2, 3], $w.traces
        doAssert w.result.problem == "" and w.result.plots.len in 4 .. 5,
            w.result.problem
        doAssert f.markOf("new plot 2.roles line").size.x > 0, "no roles line")
    click("new plot 2.roles header") # the roles' table is folded until it is opened
    step("the roles", noop, proc (f: FrameInfo): bool =
      result = f.markOf("new plot 2.role Ref").size.x > 0
      if result:
        for role in ["Ref", "GF", "M", "B"]:
          doAssert f.markOf("new plot 2.role " & role).size.x > 0, "no role " & role)
    click("new plot 2.roles header")
    click("new plot 2.limits")
    click("new plot 2.limits.check")
    step("limits on", noop, proc (f: FrameInfo): bool =
      result = f.core.plots[1].params.limitsOn and not f.core.plots[1].waiting and
        f.markOf("new plot 2.table").size.x > 0
      if result:
        var limits = 0
        for c in f.core.plots[1].result.plots[0].curves:
          if c.style == csLimit: inc limits
        doAssert limits == 1, $limits & " phase limits drawn (Absolute: the one size)"
        for label in ["Phase ±", "Phase mean", "THD", "THD mean", "Harmonic", "Force from",
            "Force to", "Peak force"]:
          doAssert f.markOf("new plot 2.limit " & label).size.x > 0, "no label " & label)
    key("Esc closes the limits", skEscape) # the popover is over the pin: Esc shuts it
    freezePin("new plot 2.freeze", 1)
    step("the vibrator signature closed", proc (f: FrameInfo) =
      f.apply(Command(kind: ckClosePlot, plot: 2)),
      proc (f: FrameInfo): bool = f.core.plots.len == 1)
    # an f-k of the record: an image, its cursor held by the keys reads
    # the wavenumber, the frequency, dB and the apparent velocity
    step("an f-k", proc (f: FrameInfo) =
      f.apply(Command(kind: ckOpenPlot, plotView: avFk, plotTraces: @[0, 1, 2, 3, 4])),
      proc (f: FrameInfo): bool =
        result = f.core.plots.len == 2 and not f.core.plots[1].waiting and
          f.markOf("new plot 2.image").size.x > 0
        if result: doAssert f.core.plots[1].result.problem == "", f.core.plots[1].result.problem)
    click("new plot 2.image")
    key("Right on the f-k", skRight)
    key("Up on the f-k", skUp)
    step("the f-k's reading", noop, proc (f: FrameInfo): bool =
      result = f.core.plots[1].cursor.held
      if result:
        let text = f.plotWindows.readoutOf(2)
        doAssert " /trace · " in text and " Hz: " in text and
          (text.endsWith(" traces/s") or text.endsWith("(k = 0)")), text)
    # a window in front hides the held cursor's boxes on the axes: an
    # envelope window (3), opened over the f-k's wavenumber box, shows its own
    # pixels there, not the box's frame
    proc edgeOf(f: FrameInfo; box: Rect): int =
      ## The most pixels of one row at the box's top edge that are in the crosshair's colour.
      let pixels = f.readFrame()
      let c = f.theme.roles[rlCrosshair]
      for y in int(box.pos.y) - 1 .. int(box.pos.y) + 1:
        var n = 0
        for x in int(box.pos.x) + 3 ..< int(box.pos.x + box.size.x) - 3:
          let p = pixels[y * f.width + x]
          if (p.r, p.g, p.b) == (c.r, c.g, c.b): inc n
        result = max(result, n)
    step("the box seen", noop, proc (f: FrameInfo): bool =
      let box = f.markOf("new plot 2.cursor x")
      doAssert box.size.x > 0, "the f-k's held cursor shows no box on its axis"
      edgeAt = f.edgeOf(box)
      doAssert edgeAt >= int(box.size.x) - 8, "the box's edge is not drawn (" & $edgeAt & " pixels)"
      true)
    step("an envelope in front", proc (f: FrameInfo) =
      f.apply(Command(kind: ckOpenPlot, plotView: avEnvelope, plotTraces: @[0])),
      proc (f: FrameInfo): bool = f.core.plots.len == 3 and not f.core.plots[2].waiting and
        f.markOf("new plot 3.plot 1.data").size.x > 0)
    step("the box hidden", noop, proc (f: FrameInfo): bool =
      let w = f.markOf("new plot 3")
      let box = f.markOf("new plot 2.cursor x")
      doAssert box.size.x > 0 and w.pos.x <= box.pos.x and w.pos.y <= box.pos.y and
        w.pos.x + w.size.x >= box.pos.x + box.size.x and
        w.pos.y + w.size.y >= box.pos.y + box.size.y,
        "the envelope window " & $w & " does not cover the box " & $box
      # the box's top edge is a line in the crosshair's colour: none of it is there now
      let same = f.edgeOf(box)
      doAssert same < edgeAt div 2, "the box's edge shows through the window in front (" &
        $same & " pixels of it)"
      true)
    step("a shot of the covered f-k", noop, proc (f: FrameInfo): bool =
      # the picture would be of what is in front of it: refused, and the window
      # brought forward for the next try
      let covered = f.screenshot("new plot 2")
      doAssert covered.error.len > 0 and "is covered by" in covered.error, "a shot of a covered " &
        "window: " & $covered.width & " x " & $covered.height & " " & covered.error
      let front = f.screenshot("new plot 3")
      doAssert front.error.len == 0 and front.width > 100, front.error
      true)
    step("the f-k's shot, after a frame", noop, proc (f: FrameInfo): bool =
      let again = f.screenshot("new plot 2")
      doAssert again.error.len == 0 and again.width > 100, again.error
      true)
    step("the envelope closed", proc (f: FrameInfo) =
      f.apply(Command(kind: ckClosePlot, plot: 3)),
      proc (f: FrameInfo): bool = f.core.plots.len == 2)
    step("the f-k closed", proc (f: FrameInfo) =
      f.apply(Command(kind: ckClosePlot, plot: 2)),
      proc (f: FrameInfo): bool = f.core.plots.len == 1)
    # more windows, each placed a step lower and to the right: every one
    # inside the main window (one past its edge would open as a window of its
    # own, outside it, where nobody looks)
    step("seven more", proc (f: FrameInfo) =
      for n in 0 ..< 7:
        f.apply(Command(kind: ckOpenPlot, plotView: avEnvelope, plotTraces: @[0])),
      proc (f: FrameInfo): bool =
        result = f.core.plots.len == 8 and f.markOf("new plot 8").size.x > 0
        if result:
          let room = f.markOf("new plots.room")
          doAssert room.size.x > 0, "the room the windows are placed in is not marked"
          for w in f.core.plots:
            let r = f.markOf("new plot " & $w.id)
            doAssert r.size.x > 0 and r.pos.x >= room.pos.x and r.pos.y >= room.pos.y and
              r.pos.x + r.size.x <= room.pos.x + room.size.x and
              r.pos.y + r.size.y <= room.pos.y + room.size.y,
              "new plot " & $w.id & " at " & $r & " is not inside the main window's " & $room)

    # the toolbar's Spectrogram button, as Window > New plot > Spectrogram: greyed
    # with no trace selected, and with two selected it opens their window
    var plots = 0
    step("no trace selected", proc (f: FrameInfo) =
      f.apply(Command(kind: ckClearSelection)), after(2))
    step("the greyed Spectrogram button", proc (f: FrameInfo) =
      doAssert f.core.selection.selectedCount == 0
      plots = f.core.plots.len, after(1))
    click("tool." & avSpectrogram.viewName)
    step("a click on it opens nothing", noop, proc (f: FrameInfo): bool =
      doAssert f.core.plots.len == plots, "a greyed Spectrogram button opened a window"
      true)
    step("two selected for the toolbar", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelect, traces: @[0, 1], mode: smReplace)),
      proc (f: FrameInfo): bool = f.core.selection.selectedCount == 2)
    click("tool." & avSpectrogram.viewName)
    step("the toolbar's Spectrogram opens its window", noop, proc (f: FrameInfo): bool =
      result = f.core.plots.len == plots + 1
      if result:
        let w = f.core.plots[^1]
        doAssert w.view == avSpectrogram and w.traces == @[0, 1], $w.view & " " & $w.traces)

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

when isMainModule:
  main()
