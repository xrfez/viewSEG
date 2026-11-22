## The first-break overlay in the running frontend, headless, driven by real
## clicks: the Seismic window's strip has its button ("plot.First-break
## overlay") and the Analysis menu its ticked item ("menu.First-break
## overlay"), off at first; each turns the overlay on and off, and it is the
## same setting. With it on, the plot draws a bar across each trace at the
## time the model expects the first break and another at the pick, marked
## "plot.first break model N" and "plot.first break pick N" (N the position),
## where the position is where the traces are drawn: each bar centred on its
## trace's column and at the pixel row of its time, as the view's own mapping
## (`screenAt`) gives them, the planted mis-positioned trace's pick below its
## model by about its delay, with a link between the two, and no link on a
## trace that agrees. Hovering the planted trace says model, pick and the
## difference in the status bar; a file with no offsets draws the picks alone and says in
## the plot's key that the model needs a survey or coordinates. The overlay
## is the window's: the next run of the program, in the same settings
## folder, starts with it on.
##
## With `VIEWSEG_SCREENSHOTS=<dir>` the window is saved with the overlay on,
## wiggle and density, zoomed on the planted trace, and with the button's
## tooltip, in both themes (firstbreaks-*.png).
##
## Seen to fail: with the bars' trace taken as the position instead of the trace the
## plot's order puts there, "position 0 model bar at 225.0, its time at 392.55" (the
## sorted step); with the menu's action not toggling, "the menu did not turn the
## overlay off"; with the pick bar drawn at the model's time, "position 20 pick bar at
## 296.0, its time at 310.77".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, orientation, state, viewport]
import viewSEG/ui/imgui/app
import utils/[breakfiles, fixtures, waiting]

var waited = 0 ## frames since the step's action

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc ready(f: FrameInfo): bool =
  f.panel.laidOut and f.core.tiles(f.core.findPanel(MainPanel)).len > 0 and
    f.core.jobs.active.len == 0 and f.markOf("plot.data").size.x > 0

proc shown(f: FrameInfo): bool =
  ## The overlay's result is in and drawn.
  let i = f.core.breaksIndex(f.core.findPanel(MainPanel))
  i >= 0 and f.core.firstBreaks[i].state == bkDone and f.markOf("plot.first break key").size.x > 0

proc barsOnTheTraces(f: FrameInfo; planted: int) =
  ## Every bar of the frame is on its trace's column and at its time (the
  ## view's own mapping), the planted trace (at position `planted`, where the
  ## plot's order puts it) is the one with a link.
  let plot = f.markOf("plot.data")
  let view = f.panel.view
  let ppm = plot.size.y / float32(view.timeMs.hi - view.timeMs.lo)
  let layout = f.panel.layout
  let want = f.core.firstBreaks[f.core.breaksIndex(f.core.findPanel(MainPanel))]
  var checked = 0
  for p in 0 ..< layout.traces:
    let (mm, pm) = (f.markOf("plot.first break model " & $p),
      f.markOf("plot.first break pick " & $p))
    if mm.size.x > 0 and pm.size.x > 0:
      let trace = f.panel.shown[p]
      let (tm, tp) = (want.modelOf(trace), want.pickOf(trace))
      let (sm, sp) = (view.screenAt(plot, DataPoint(x: float64(p), tMs: tm)),
        view.screenAt(plot, DataPoint(x: float64(p), tMs: tp)))
      doAssert abs(mm.centre.x - sm.x) <= 1.5 and abs(pm.centre.x - sp.x) <= 1.5,
        "position " & $p & " bars are not on its column"
      doAssert abs(mm.centre.y - sm.y) <= 2.5, "position " & $p & " model bar at " &
        $mm.centre.y & ", its time at " & $sm.y
      doAssert abs(pm.centre.y - sp.y) <= 2.5, "position " & $p & " pick bar at " &
        $pm.centre.y & ", its time at " & $sp.y
      let linked = f.markOf("plot.first break link " & $p).size.y > 0
      doAssert linked == (trace == PlantedTrace), "position " & $p & " (trace " & $trace &
        "): link " & $linked & ", difference " & $(tp - tm)
      inc checked
  doAssert checked >= Traces - 4, "bars on " & $checked & " traces"
  let (mm, pm) = (f.markOf("plot.first break model " & $planted),
    f.markOf("plot.first break pick " & $planted))
  doAssert f.panel.shown[planted] == PlantedTrace, "the planted trace is not at " & $planted
  doAssert pm.centre.y - mm.centre.y >= 0.5 * PlantedMs * ppm,
    "the planted pick is not below its model: " & $(pm.centre.y - mm.centre.y)

proc runSteps(name: string; opts: RunOptions; steps: seq[Step]) =
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
      waited = wait
      if wait >= 3 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 400, since):
        failed = name & ": " & steps[at].name & " did not happen"
        f.stop()
  var o = opts
  o.onFrame = onFrame
  let code = run(o)
  doAssert code == 0, name & ": run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, name & ": stopped at " & steps[min(at, steps.high)].name

proc session(fx: Fixtures; name: string; choice: ThemeChoice; file: string;
    wantOn: bool; assertions: bool) =
  ## One run of the program on `file`: with `wantOn` the overlay is on from
  ## the start (the setting kept by the run before), else it is turned on
  ## and off by the button and the menu; `assertions` also checks the geometry.
  let config = fx.dir / ("config-" & name)
  createDir(config)
  let shots = getEnv("VIEWSEG_SCREENSHOTS")
  let opts = RunOptions(openPaths: @[file], windowSize: (1400, 900), theme: choice,
    persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
    indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
    assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]))
  var steps: seq[Step]
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard
  proc shoot(f: FrameInfo; what: string) =
    if shots.len > 0:
      createDir(shots)
      doAssert f.savePng(shots / ("firstbreaks-" & what & ".png")), "cannot save " & what
  proc setDisplay(f: FrameInfo; mode: DisplayMode) =
    var d = f.panel.layers[0].display
    d.mode = mode
    f.apply(Command(kind: ckDisplay, panel: MainPanel, display: d))

  if wantOn:
    step("on from the start", noop, proc (f: FrameInfo): bool =
      result = f.ready and f.core.breaksOn(MainPanel) and f.shown
      if result: doAssert f.markOf("plot.first break model 3").size.x > 0, "no bars")
  else:
    step("off at first", noop, proc (f: FrameInfo): bool =
      result = f.ready
      if result:
        doAssert f.markOf("plot.First-break overlay").size.x > 0, "no button on the strip"
        doAssert not f.core.breaksOn(MainPanel), "on by default"
        doAssert f.markOf("plot.first break key").size.x == 0 and
          f.markNames("plot.first break").len == 0, "bars drawn while off"
        doAssert f.core.firstBreaks.len == 0, "work done while off")
    step("the button turns it on", proc (f: FrameInfo) =
      f.click(f.markOf("plot.First-break overlay").centre), proc (f: FrameInfo): bool =
      f.core.breaksOn(MainPanel) and f.shown)
  if assertions:
    step("the bars are on the traces", noop, proc (f: FrameInfo): bool =
      f.barsOnTheTraces(PlantedTrace)
      true)
    step("sorted: the other way round", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSort, panel: MainPanel,
        order: @[SortKey(field: hfChannel, descending: true)])), proc (f: FrameInfo): bool =
      result = f.panel.shown.len == Traces and f.panel.shown[0] == Traces - 1 and f.shown and
        f.markOf("plot.first break pick " & $(Traces - 1 - PlantedTrace)).size.x > 0 and
        not f.core.sorting(f.core.findPanel(MainPanel))
      if result: f.barsOnTheTraces(Traces - 1 - PlantedTrace))
    step("back to the file's order", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSort, panel: MainPanel, order: @[])), proc (f: FrameInfo): bool =
      f.panel.shown.len == Traces and f.panel.shown[0] == 0 and
        not f.core.sorting(f.core.findPanel(MainPanel)))
    step("hover the planted trace", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.first break pick " & $PlantedTrace).centre),
      proc (f: FrameInfo): bool =
      result = f.markOf("status.firstbreak").size.x > 0
      if result:
        let say = f.pick.breaks
        doAssert "model" in say and "pick" in say and "+" in say and " ms" in say, say)
  step("a shot of it", proc (f: FrameInfo) = f.moveMouse(vec2(2, 2)),
    proc (f: FrameInfo): bool =
    f.shoot(name & "-wiggle")
    true)
  if shots.len > 0:
    step("density", proc (f: FrameInfo) = f.setDisplay(dmDensity), proc (f: FrameInfo): bool =
      result = f.panel.layers[0].display.mode == dmDensity and f.shown and f.ready
      if result: f.shoot(name & "-density"))
    step("wiggle over density", proc (f: FrameInfo) = f.setDisplay(dmWiggleDensity),
      proc (f: FrameInfo): bool =
      result = f.panel.layers[0].display.mode == dmWiggleDensity and f.shown and f.ready
      if result: f.shoot(name & "-wiggle-over-density"))
    step("wiggle", proc (f: FrameInfo) = f.setDisplay(dmWiggle), proc (f: FrameInfo): bool =
      f.panel.layers[0].display.mode == dmWiggle and f.shown and f.ready)
    step("zoomed on the planted trace", proc (f: FrameInfo) =
      let i = f.core.breaksIndex(f.core.findPanel(MainPanel))
      let tm = f.core.firstBreaks[i].modelOf(PlantedTrace)
      var v = f.panel.view
      v.traces = Span(lo: float64(PlantedTrace) - 3.5, hi: float64(PlantedTrace) + 3.5)
      v.timeMs = Span(lo: tm - 60, hi: tm + 200)
      f.showView(v),
      proc (f: FrameInfo): bool =
      result = f.panel.view.traces.hi - f.panel.view.traces.lo < 10 and f.ready and f.shown
      if result: f.shoot(name & "-zoomed"))
    step("the button's tooltip", proc (f: FrameInfo) =
      f.keepInMainWindow()
      f.moveMouse(f.markOf("plot.First-break overlay").centre), proc (f: FrameInfo): bool =
      result = waited > 60
      if result: f.shoot(name & "-tooltip"))
  if not wantOn:
    step("the menu turns it off", proc (f: FrameInfo) =
      f.click(f.markOf("menu.Analysis").centre), proc (f: FrameInfo): bool =
      f.markOf("menu.First-break overlay").size.x > 0)
    step("the menu item", proc (f: FrameInfo) =
      f.click(f.markOf("menu.First-break overlay").centre), proc (f: FrameInfo): bool =
      result = not f.core.breaksOn(MainPanel)
      doAssert waited < 200 or result, "the menu did not turn the overlay off"
      if result: doAssert f.markOf("plot.first break key").size.x == 0, "still drawn")
    step("the menu turns it on", proc (f: FrameInfo) =
      f.click(f.markOf("menu.Analysis").centre), proc (f: FrameInfo): bool =
      f.markOf("menu.First-break overlay").size.x > 0)
    step("the menu item again", proc (f: FrameInfo) =
      f.click(f.markOf("menu.First-break overlay").centre), proc (f: FrameInfo): bool =
      doAssert waited < 200 or f.core.breaksOn(MainPanel),
        "the menu did not turn the overlay on"
      f.core.breaksOn(MainPanel) and f.shown)
  runSteps(name, opts, steps)

proc main*() =

  withFixtures fx:
    let file = fx.shotSegy("gui.sgy", gHeaderOffset)
    session(fx, "dark", forceDark, file, wantOn = false, assertions = true)
    # the setting is the window's: the next run starts with it on
    session(fx, "dark", forceDark, file, wantOn = true, assertions = true)
    session(fx, "light", forceLight, file, wantOn = false, assertions = false)

  block noOffsetsPicksAloneAndWhy:
    withFixtures fx:
      let file = fx.shotSegy("none.sgy", gNothing)
      var steps: seq[Step]
      let config = fx.dir / "config-none"
      createDir(config)
      let opts = RunOptions(openPaths: @[file], windowSize: (1400, 900), theme: forceDark,
        persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
        indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
        assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]))
      steps.add Step(name: "on", act: proc (f: FrameInfo) = discard,
        done: proc (f: FrameInfo): bool =
        if not f.ready: return false
        if not f.core.breaksOn(MainPanel):
          var d = f.panel.layers[0].display
          d.firstBreaks = true
          f.apply(Command(kind: ckDisplay, panel: MainPanel, display: d))
          return false
        result = f.shown and f.markOf("plot.first break pick 3").size.x > 0
        if result:
          doAssert f.markOf("plot.first break model 3").size.x == 0, "a model without offsets"
          doAssert f.markOf("plot.first break note").size.x > 0,
            "the key does not say why there is no model")
      runSteps("no offsets", opts, steps)

  echo "tguifirstbreaks: ok"

when isMainModule:
  main()
