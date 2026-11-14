## Zoom, pan and the readout in the running frontend, headless, driven by
## SDL events as the user's mouse and keyboard send them: the wheel zooms
## about the pointer (both axes; Ctrl: time only; Shift: traces only),
## `+` and `-` and Ctrl + arrows zoom from the keyboard, the arrows pan, a
## left drag pans with the data under the pointer, a right drag zooms to the
## box, Backspace goes back to the view before the last gesture, Ctrl + 0
## fits, the zoom buttons zoom; typing into the scale boxes sets the zoom
## and zooming updates the boxes; zooming in asks for fewer traces; the
## status bar reads out the trace under the pointer; and the file is never
## changed.
##
## Seen to fail: with the wheel's notches ignored, `wheelZooms` zoomed by
## 1.25 where two notches give 1.5625; with the drag moving the view the
## wrong way, `dragPans` never found the grabbed point under the pointer;
## with Ctrl + wheel zooming both axes, `ctrlWheel` found the traces
## changed; with `remember` never sent, `wheelZooms` found no view to go
## back to.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/fixtures

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func near(a, b: float64; eps = 1e-4): bool = abs(a - b) <= eps * max(1.0, abs(b))

func nearSpan(a, b: Span; eps = 1e-4): bool = near(a.lo, b.lo, eps) and near(a.hi, b.hi, eps)

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

proc main() =
  withFixtures fx:
    let path = fx.surveySegy()
    let before = snapshot(path)
    var steps: seq[Step]
    var at = 0 # the step running
    var started = false # its action is done
    var wait = 0 # frames since
    var failed = ""
    var plot: Rect # the plot's data area, framebuffer pixels
    var q, r: Vec2 # points over the plot
    var was: Viewport # the view before a step
    var lim: ViewLimits
    var counts: seq[int]

    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

    proc answered(f: FrameInfo): bool =
      let tiles = f.core.tiles(f.core.findPanel(MainPanel))
      tiles.len > 0 and tiles[^1].request == f.panel.pending

    proc changed(f: FrameInfo): bool =
      not f.panel.view.sameSpans(was) and f.tracePanel.drawnView.sameSpans(f.panel.view)

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc click(f: FrameInfo; at: Vec2) =
      f.pressMouse(at, true)
      f.pressMouse(at, false)

    proc chord(f: FrameInfo; key: SimKey; mods: set[SimMod] = {}) =
      ## `key` pressed and released with `mods` held, as a keyboard sends it:
      ## the modifier keys go down first and come up last.
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

    # -------------------------------------------------------------- steps --
    step("the file opens", noop, proc (f: FrameInfo): bool =
      result = f.panel.laidOut and f.answered and f.markOf("plot.data").size.x > 0
      if result:
        plot = f.markOf("plot.data")
        # whole pixels: the pointer is warped to one
        q = vec2(round(plot.pos.x + plot.size.x * 0.3), round(plot.pos.y + plot.size.y * 0.4))
        r = vec2(round(plot.pos.x + plot.size.x * 0.7), round(plot.pos.y + plot.size.y * 0.75))
        lim = limitsOf(f.panel.layout)
        counts.add f.panel.pending.count)

    step("readout", proc (f: FrameInfo) = f.moveMouse(q), proc (f: FrameInfo): bool =
      let p = f.pick
      if p.inside and p.found:
        let want = f.panel.view.dataAt(plot, q)
        doAssert near(p.at.x, want.x) and near(p.at.tMs, want.tMs), $p.at & " not " & $want
        doAssert p.position == int(round(want.x)) and p.trace == p.position
        doAssert p.keys.channel == float64(p.position + 1) and p.keys.record == FirstRecord
        doAssert p.sample == int(round(want.tMs / DtMs))
        doAssert p.text(rfTrace) == $(p.position + 1) and p.text(rfRecord) == $FirstRecord
        doAssert p.text(rfAmplitude).len > 0 and p.text(rfTime).endsWith(" ms")
        for field in DefaultReadout:
          doAssert f.markOf("status." & $field).size.x > 0, "no " & $field & " in the status bar"
        result = true)

    step("wheelZooms", proc (f: FrameInfo) =
      was = f.panel.view
      f.scrollWheel(q, 2), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        let want = was.zoomed(WheelStep * WheelStep, was.dataAt(plot, q), BothAxes, lim)
        doAssert nearSpan(v.traces, want.traces) and nearSpan(v.timeMs, want.timeMs),
          $v & " not " & $want
        # the data under the pointer stays there
        let a = was.dataAt(plot, q)
        let b = v.dataAt(plot, q)
        doAssert near(a.x, b.x) and near(a.tMs, b.tMs)
        doAssert f.panel.back.len == 1, $f.panel.back.len & " views to go back to")

    step("ctrlWheel", proc (f: FrameInfo) =
      was = f.panel.view
      f.pressKey(skCtrl, true, {smCtrl})
      f.scrollWheel(q, 1), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        doAssert v.traces == was.traces, "Ctrl + wheel changed the traces"
        doAssert near(v.timeMs.width, was.timeMs.width / WheelStep)
        f.pressKey(skCtrl, false))

    step("shiftWheel", proc (f: FrameInfo) =
      was = f.panel.view
      f.pressKey(skShift, true, {smShift})
      f.scrollWheel(q, 1), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        doAssert v.timeMs == was.timeMs, "Shift + wheel changed the time axis"
        doAssert near(v.traces.width, was.traces.width / WheelStep)
        f.pressKey(skShift, false))

    step("sidewaysWheel", proc (f: FrameInfo) =
      was = f.panel.view
      f.scrollWheel(q, 0, sideways = -1), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        doAssert v.timeMs == was.timeMs and near(v.traces.width, was.traces.width / WheelStep),
          "sideways: " & $v)

    step("focus the plot", proc (f: FrameInfo) = f.click(q), proc (f: FrameInfo): bool = true)

    step("plusKey", proc (f: FrameInfo) =
      was = f.panel.view
      f.chord(skEquals), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        doAssert near(v.traces.width, max(was.traces.width / KeyStep, MinTraces)) and
          near(v.timeMs.width, was.timeMs.width / KeyStep), $v)

    step("minusKey", proc (f: FrameInfo) =
      was = f.panel.view
      f.chord(skKeypadMinus), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        doAssert near(f.panel.view.timeMs.width, was.timeMs.width * KeyStep))

    step("ctrlArrows", proc (f: FrameInfo) =
      was = f.panel.view
      f.chord(skUp, {smCtrl}), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        doAssert f.panel.view.traces == was.traces and
          near(f.panel.view.timeMs.width, was.timeMs.width / KeyStep))

    step("arrowPans", proc (f: FrameInfo) =
      was = f.panel.view
      f.chord(skDown), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        doAssert near(v.timeMs.lo, was.timeMs.lo + PanStep * was.timeMs.width) and
          v.traces == was.traces, $v)

    step("dragPans", proc (f: FrameInfo) =
      was = f.panel.view
      f.pressMouse(q, true)
      f.moveMouse(vec2(q.x + 40, q.y + 30))
      f.moveMouse(vec2(q.x + 80, q.y + 60)), proc (f: FrameInfo): bool =
      result = f.changed and near(f.panel.view.traces.lo,
        was.traces.lo - 80 / plot.size.x * was.traces.width, 1e-3)
      if result:
        f.pressMouse(vec2(q.x + 80, q.y + 60), false)
        let v = f.panel.view
        # the grabbed point is under the pointer
        let grabbed = was.dataAt(plot, q)
        let now = v.dataAt(plot, vec2(q.x + 80, q.y + 60))
        doAssert near(grabbed.x, now.x, 1e-3) and near(grabbed.tMs, now.tMs, 1e-3),
          $grabbed & " is at " & $now)

    step("boxZoom", proc (f: FrameInfo) =
      f.moveMouse(q)
      was = f.panel.view, proc (f: FrameInfo): bool = true)
    step("boxZoom", proc (f: FrameInfo) =
      f.pressMouse(q, true, button = 3)
      f.moveMouse(vec2((q.x + r.x) / 2, (q.y + r.y) / 2))
      f.moveMouse(r), proc (f: FrameInfo): bool =
      f.pressMouse(r, false, button = 3)
      true)
    step("boxZoom", noop, proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        let want = was.boxed(was.dataAt(plot, q), was.dataAt(plot, r), BothAxes, lim)
        doAssert nearSpan(v.traces, want.traces, 1e-3) and nearSpan(v.timeMs, want.timeMs, 1e-3),
          $v & " not " & $want
        doAssert f.core.log.count(sevWarning) == 0)

    # The whole gather's tile covers every view inside it at full
    # resolution, so zooming in reads nothing new; a change of gain reads
    # the view on screen again, and that read asks for fewer traces.
    step("zoomedInReadsFewerTraces", proc (f: FrameInfo) =
      doAssert f.panel.pending.covers(f.panel.layout, f.panel.view, f.panel.pending.margin)
      var d = f.panel.layers[0].display
      d.gain = dgNone
      f.apply(Command(kind: ckDisplay, panel: MainPanel, display: d)), proc (f: FrameInfo): bool =
      result = f.answered
      if result:
        counts.add f.panel.pending.count
        doAssert counts[^1] < counts[0], "zoomed in, " & $counts[^1] & " of " & $counts[0] &
          " traces read"
        doAssert counts[^1] == requestFor(f.panel.layout, f.panel.view, 0).count)

    step("back", proc (f: FrameInfo) =
      was = f.panel.view
      f.chord(skBackspace), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        doAssert f.panel.back.len >= 1, "nothing more to go back to"
        # the view before the box zoom: where the drag left it
        doAssert f.tracePanel.drawnView.sameSpans(f.panel.view))

    step("fitKey", proc (f: FrameInfo) =
      was = f.panel.view
      f.chord(skZero, {smCtrl}), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let fit = fitAll(f.panel.layout, 0, 0)
        doAssert f.panel.view.sameSpans(fit), $f.panel.view)

    step("zoomButton", proc (f: FrameInfo) =
      was = f.panel.view
      let b = f.markOf("plot.zoom in")
      doAssert b.size.x > 0, "no zoom-in button"
      f.moveMouse(vec2(b.pos.x + b.size.x / 2, b.pos.y + b.size.y / 2)), proc (f: FrameInfo): bool =
      true)
    step("zoomButton", proc (f: FrameInfo) =
      let b = f.markOf("plot.zoom in")
      f.click(vec2(b.pos.x + b.size.x / 2, b.pos.y + b.size.y / 2)), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        doAssert near(f.panel.view.timeMs.width, was.timeMs.width / KeyStep))

    # The scale boxes: what they show, then a value typed into each.
    step("boxesShowTheScale", noop, proc (f: FrameInfo): bool =
      let (tr, tm) = f.tracePanel.scaleTexts
      let v = f.panel.view
      let wantTr = significant(traceScale(v, DefaultDpi, ScaleUnits()), 4)
      let wantTm = significant(timeScale(v, DefaultDpi, ScaleUnits()), 4)
      result = tr == wantTr and tm == wantTm
      if not result and wait > 100:
        doAssert false, "the boxes show " & tr & " and " & tm & ", not " & wantTr & " and " &
          wantTm)

    step("typeTraceScale", proc (f: FrameInfo) =
      let b = f.markOf("plot.trace scale")
      doAssert b.size.x > 0, "no trace scale box"
      let c = vec2(b.pos.x + b.size.x / 2, b.pos.y + b.size.y / 2)
      f.moveMouse(c), proc (f: FrameInfo): bool = true)
    step("typeTraceScale", proc (f: FrameInfo) =
      let b = f.markOf("plot.trace scale")
      f.click(vec2(b.pos.x + b.size.x / 2, b.pos.y + b.size.y / 2)), proc (f: FrameInfo): bool =
      true)
    step("typeTraceScale", proc (f: FrameInfo) =
      was = f.panel.view
      doAssert f.typing, "the trace scale box does not have the keyboard"
      f.typeText("2"), proc (f: FrameInfo): bool = true)
    step("typeTraceScale", proc (f: FrameInfo) =
      f.chord(skEnter), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        doAssert near(traceScale(v, DefaultDpi, ScaleUnits()), 2, 1e-6),
          $traceScale(v, DefaultDpi, ScaleUnits()) & " traces/in"
        doAssert v.traces.lo == was.traces.lo and v.timeMs == was.timeMs, $v)

    step("typeTimeScale", proc (f: FrameInfo) =
      let b = f.markOf("plot.time scale")
      f.moveMouse(vec2(b.pos.x + b.size.x / 2, b.pos.y + b.size.y / 2)),
      proc (f: FrameInfo): bool = true)
    step("typeTimeScale", proc (f: FrameInfo) =
      let b = f.markOf("plot.time scale")
      f.click(vec2(b.pos.x + b.size.x / 2, b.pos.y + b.size.y / 2)), proc (f: FrameInfo): bool =
      true)
    step("typeTimeScale", proc (f: FrameInfo) =
      was = f.panel.view
      f.typeText("100"), proc (f: FrameInfo): bool = true)
    step("typeTimeScale", proc (f: FrameInfo) =
      f.chord(skEnter), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        doAssert near(timeScale(v, DefaultDpi, ScaleUnits()), 100, 1e-6)
        doAssert v.timeMs.lo == was.timeMs.lo and v.traces == was.traces)

    step("aBadScaleIsSaid", proc (f: FrameInfo) =
      let b = f.markOf("plot.time scale")
      f.click(vec2(b.pos.x + b.size.x / 2, b.pos.y + b.size.y / 2)), proc (f: FrameInfo): bool =
      true)
    step("aBadScaleIsSaid", proc (f: FrameInfo) =
      was = f.panel.view
      f.typeText("-"), proc (f: FrameInfo): bool = true)
    step("aBadScaleIsSaid", proc (f: FrameInfo) =
      f.chord(skEnter), proc (f: FrameInfo): bool =
      result = f.core.log.count(sevWarning) == 1
      if result:
        doAssert f.panel.view.sameSpans(was)
        var said = false
        for m in f.messages:
          if "time scale needs a positive number" in m.text: said = true
        doAssert said)

    # ------------------------------------------------------------ driver --
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
        elif wait > 300:
          failed = steps[at].name & " did not happen"
          f.stop()

    let code = run(RunOptions(maxFrames: 6000, openPaths: @[path], theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguizoom: ", steps.len, " steps; traces read: ", counts
    doAssert snapshot(path) == before, "showing the file changed it"

main()

# ------------------------------------------------- screenshots of real data --
# With `VIEWSEG_SCREENSHOTS=<dir>` and the example files present (they are
# local only), the plot window is saved on a real record at two zoom levels
# as zoom-*.png, with the pointer on a trace so the status bar reads it out:
# docs/screenshots/ holds the committed ones.

const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

proc zoomShots(path, name: string; tracesPerInch, msPerInch: float64; centre: DataPoint;
    notches: float32; hover1, hover2: DataPoint) =
  ## Opens `path` in a 1600 x 1000 window, sets the scales from the
  ## record's start (as typed into the boxes), saves `name`-1.png with the
  ## pointer on `hover1`, turns the wheel `notches` about `centre` and saves
  ## `name`-2.png with the pointer on `hover2`.
  let dir = getEnv("VIEWSEG_SCREENSHOTS")
  var stage = 0
  var wait = 0
  var saved = 0
  var was: Viewport
  proc onFrame(f: FrameInfo) =
    let p = f.core.panels[f.core.findPanel(MainPanel)]
    let tiles = f.core.tiles(f.core.findPanel(MainPanel))
    let answered = tiles.len > 0 and tiles[^1].request == p.pending and
      f.tracePanel.drawnView.sameSpans(p.view)
    let plot = f.markOf("plot.data")
    proc at(d: DataPoint): Vec2 =
      let v = p.view.screenAt(plot, d)
      vec2(round(v.x), round(v.y))
    inc wait
    case stage
    of 0:
      if p.laidOut and answered and plot.size.x > 0:
        let lim = limitsOf(p.layout)
        var v = p.view
        v.traces = Span(lo: -0.5, hi: 99.5)
        v.timeMs = Span(lo: p.layout.t0Ms, hi: p.layout.t0Ms + 1000)
        v = withTimeScale(withTraceScale(v, tracesPerInch, DefaultDpi, ScaleUnits(), lim),
          msPerInch, DefaultDpi, ScaleUnits(), lim)
        f.showView(v)
        stage = 1
    of 1:
      if answered and p.back.len > 0:
        f.moveMouse(at(hover1))
        wait = 0
        stage = 2
    of 2:
      if wait > 4 and f.pick.found:
        if f.savePng(dir / (name & "-1.png")): inc saved
        was = p.view
        f.moveMouse(at(centre))
        wait = 0
        stage = 3
    of 3:
      if wait == 3: f.scrollWheel(at(centre), notches)
      if wait > 3 and answered and not p.view.sameSpans(was):
        f.moveMouse(at(hover2))
        wait = 0
        stage = 4
    of 4:
      if wait > 4 and answered and f.pick.found:
        if f.savePng(dir / (name & "-2.png")): inc saved
        echo "tguizoom: ", name, " at ", significant(traceScale(was, DefaultDpi, ScaleUnits())),
          " and ", significant(traceScale(p.view, DefaultDpi, ScaleUnits())), " traces/in; ",
          "read ", p.pending.count, " traces at the second"
        f.stop()
    else: discard
    if f.index > 3000: f.stop()
  let tmp = getTempDir() / ("viewseg-zoomshots-" & $getCurrentProcessId())
  let code = run(RunOptions(maxFrames: 4000, openPaths: @[path], windowSize: (1600, 1000),
    theme: forceDark, indexCacheDir: some(tmp), userThemeDir: some(tmp / "no-user-themes"),
    onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0 and saved == 2, "no screenshots of " & path & " (stage " & $stage & ")"
  echo "tguizoom: saved ", dir / (name & "-1.png"), " and -2.png"

if getEnv("VIEWSEG_SCREENSHOTS").len > 0:
  let morgantown = examples / "00000151_12900_11300.sgd"
  if fileExists(morgantown):
    createDir(getEnv("VIEWSEG_SCREENSHOTS"))
    zoomShots(morgantown, "zoom-morgantown", 50, 400, DataPoint(x: 240, tMs: 250), 6,
      DataPoint(x: 120, tMs: 700), DataPoint(x: 232, tMs: 330))
