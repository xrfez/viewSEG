## Auxiliary traces in the Seismic window, headless, with real clicks: on a
## SEG-D record with a time break and a pilot beside its 24 seismic traces,
## the strip shows two toggles, Seismic (on) and Aux (off); Aux on draws the
## record's 26 traces in the file's order (the two auxiliary ones first, as
## the file has them) and the window is titled "Seismic + Aux", at the same
## scales; the pointer over the pilot reads out an auxiliary trace; Seismic
## off leaves the two auxiliary traces ("Aux"), and Aux, then the only one
## on, stays on when clicked; Seismic on again gives both. A record without
## auxiliary traces has no such toggles.
##
## Seen to fail: with the toggles drawn for every record, "the toggles are
## shown for a record without auxiliary traces"; with the filter's command
## ignored (`ckFilter` changing nothing), "seismic + aux did not happen".
## (Aux stays on as the only one twice over: the strip does not send a
## filter of neither, and `ckFilter` refuses one.)
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves aux-land.png and gain-exponential.png
## there when the private land record is present (local only).

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/[app, icons]
import privatefiles
import utils/[fixtures, waiting]

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

proc title(f: FrameInfo): string =
  f.windowName("plot").replace(IconPlot & "  ", "").split("###")[0]

proc runSteps(file: string; steps: seq[Step]; dir: string) =
  var at = 0
  var started = false
  var wait = 0 # frames since the step began, at `since`
  var since = getMonoTime()
  var failed = ""
  proc onFrame(f: FrameInfo) =
    if f.index == 0: f.moveMouse(vec2(4, 4))
    if at >= steps.len or failed.len > 0:
      f.stop()
      return
    if not started:
      steps[at].act(f)
      started = true
      wait = 0
      since = getMonoTime()
    else:
      inc wait
      if wait >= 2 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 300, since):
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(openPaths: @[file], windowSize: (1400, 900),
    theme: forceDark, userThemeDir: some(dir / "no-user-themes"),
    indexCacheDir: some(dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

withFixtures fx:
  var steps: seq[Step]
  var pointAt: Vec2
  var scale: float64
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
      f.pressMouse(pointAt, false), after(2))
  proc shows(traces: int; name: string; seismic, aux: bool; what: string):
      proc (f: FrameInfo): bool =
    result = proc (f: FrameInfo): bool =
      let flt = f.panel.layers[0].filter
      result = f.answered and f.panel.layout.traces == traces and f.title == name
      if result:
        doAssert flt.seismic == seismic and flt.auxiliary == aux, what & ": " & $flt
        doAssert f.markOf("plot.traces.Seismic").size.x > 0 and
          f.markOf("plot.traces.Aux").size.x > 0, what & ": the toggles went"

  step("the record", noop, proc (f: FrameInfo): bool =
    result = f.answered and f.title == "Seismic" and f.panel.layout.traces == 24
    if result:
      doAssert f.markOf("plot.traces.Seismic").size.x > 0 and
        f.markOf("plot.traces.Aux").size.x > 0, "no toggles for a record with auxiliary traces"
      scale = f.panel.view.traces.width / float64(f.panel.view.columns))
  click("plot.traces.Aux")
  step("seismic + aux", noop, shows(26, "Seismic + Aux", true, true,
    "Aux did not add the auxiliary traces"))
  step("the same scales", noop, proc (f: FrameInfo): bool =
    let s = f.panel.view.traces.width / float64(f.panel.view.columns)
    doAssert abs(s - scale) <= 1e-9 * scale or f.panel.view.traces.width >= 26,
      "the scale changed: " & $scale & " -> " & $s
    true)
  step("over the pilot", proc (f: FrameInfo) =
    # the auxiliary traces come first in the file: positions 0 and 1
    let plot = f.markOf("plot.data")
    let v = f.panel.view
    let x = plot.pos.x + float32((1.0 - v.traces.lo) / v.traces.width) * plot.size.x
    f.moveMouse(vec2(round(x), round(plot.pos.y + plot.size.y / 3))),
    proc (f: FrameInfo): bool =
      result = f.pick.found and f.pick.position == 1
      if result: doAssert f.pick.keys.status == tsAuxiliary, $f.pick.keys.status)
  click("plot.traces.Seismic")
  step("aux alone", noop, shows(2, "Aux", false, true, "Seismic did not go off"))
  click("plot.traces.Aux")
  step("aux stays", noop, proc (f: FrameInfo): bool =
    result = true
    doAssert f.panel.layers[0].filter.auxiliary, "Aux went off: nothing would be shown"
    doAssert f.title == "Aux")
  click("plot.traces.Seismic")
  step("both again", noop, shows(26, "Seismic + Aux", true, true, "Seismic did not come back"))
  runSteps(fx.twoSetSegd(), steps, fx.dir)

  # A record without auxiliary traces: no toggles.
  steps.setLen 0
  step("no aux", noop, proc (f: FrameInfo): bool =
    result = f.answered
    if result:
      doAssert f.markOf("plot.traces.Aux").size.x == 0,
        "the toggles are shown for a record without auxiliary traces")
  runSteps(fx.surveySegy(), steps, fx.dir)
  echo "tguiaux: ok"

# ------------------------------------------------------------ screenshots --

let landSegd = privateFile("landSegd")

if getEnv("VIEWSEG_SCREENSHOTS").len > 0 and landSegd.len > 0:
  # The private land record with its three auxiliary traces shown among the
  # seismic ones (aux-land.png); then the gain drop-down open on the
  # Exponential type's settings, with its cutoff (gain-exponential.png).
  let shots = getEnv("VIEWSEG_SCREENSHOTS")
  createDir(shots)
  let tmp = getTempDir() / ("viewseg-aux-" & $getCurrentProcessId())
  var stage, wait = 0
  var since = getMonoTime() # when the stage began
  var saved: seq[string]
  proc onShot(f: FrameInfo) =
    inc wait
    template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
    if f.index == 0: f.moveMouse(vec2(4, 4))
    case stage
    of 0:
      if f.answered and wait > 10:
        let v = f.panel.view
        f.showView(Viewport(traces: Span(lo: -0.5, hi: 24.5), timeMs: Span(lo: 0, hi: 1500),
          columns: v.columns, rows: v.rows))
        var flt = f.panel.layers[0].filter
        flt.auxiliary = true
        f.apply Command(kind: ckFilter, panel: MainPanel, filter: flt)
        next 1
    of 1:
      if f.answered and wait > 30 and f.title == "Seismic + Aux":
        if f.savePng(shots / "aux-land.png"): saved.add "aux-land.png"
        var d = f.panel.layers[0].display
        d.gain = dgExponential
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        next 2
    of 2:
      if wait == 10: f.moveMouse(f.markOf("plot.gain").centre)
      if wait == 13: f.pressMouse(f.markOf("plot.gain").centre, true)
      if wait == 14: f.pressMouse(f.markOf("plot.gain").centre, false)
      if wait == 20: f.moveMouse(f.markOf("plot.gain until").centre)
      if wait > 40 and f.answered and f.markOf("plot.gain until").size.x > 0:
        if f.savePng(shots / "gain-exponential.png"): saved.add "gain-exponential.png"
        f.stop()
    else: f.stop()
    if overdue(f.index, 3000, since): f.stop()
  let code = run(RunOptions(openPaths: @[landSegd], windowSize: (1600, 1000),
    theme: forceDark, indexCacheDir: some(tmp), userThemeDir: some(tmp / "no-user-themes"),
    onFrame: onShot))
  removeDir(tmp)
  doAssert code == 0 and saved.len == 2, "screenshots saved: " & $saved
  echo "tguiaux: saved ", saved
