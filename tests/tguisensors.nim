## The sensor table and the amplitude readout in physical units, in the running frontend,
## headless, with real clicks and typing.
##
## On samples/obn/obn.sgd (hydrophone, vertical, inline and crossline geophones a station):
## Project > Project... lists the four components under Sensors; 80 typed beside the vertical
## one (V/(m/s), the unit offered first with Units metric) is kept (no project is open: for
## this run, and the window says so); Physical units is chosen, which adds the raw amplitude to
## the status bar; hovering a vertical trace reads a value in m/s (or a prefix of it); with
## Units imperial the same sample reads in in/s; hovering the hydrophone says there is no
## sensor for it; Remove on the vertical row says "no sensor for component Z".
##
## Seen to fail: with `convertRaw` never called for the plot's pick, the readout stayed in
## counts ("a value in m/s"); with the unit taken from the sensitivity's and not the Units
## setting, the imperial run read m/s; with Remove doing nothing, "no sensor for component Z"
## never came.
##
## Needs a display: run under `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.
## Screenshots go to $VIEWSEG_SCREENSHOTS when it is set.

import std/[monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[components, geometry, readout, sensors, settings, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

const root = currentSourcePath().parentDir.parentDir

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc answered(f: FrameInfo): bool =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

proc positionOf(f: FrameInfo; component: uint8): int =
  ## The position of a trace of `component` the plot shows; -1 for none.
  result = -1
  for t in f.core.tiles(f.core.findPanel(MainPanel)):
    for row in 0 ..< t.keys.len:
      if row < t.traces.len and componentOf(t.keys[row]) == component:
        for p, tr in f.panel.shown:
          if tr == t.traces[row]: return p

proc runSteps(file: string; steps: seq[Step]; dir: string) =
  var at = 0
  var started = false
  var wait = 0
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
      if wait >= 3 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 600, since):
        failed = steps[at].name & " did not happen"
        for e in f.core.log: echo "  log: ", e.text
        echo "  pick: found ", f.pick.found, " raw ", f.pick.raw, " scale ", f.pick.hasScale,
            " text ", f.pick.text(rfRawAmplitude), " comp ", componentOf(f.pick.keys)
        f.stop()
  let code = run(RunOptions(openPaths: @[file], windowSize: (1400, 900),
    theme: forceDark, userThemeDir: some(dir / "no-user-themes"),
    indexCacheDir: some(dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc main*() =
  withFixtures fx:
    let obn = root / "samples" / "obn" / "obn.sgd"
    doAssert fileExists(obn)
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var steps: seq[Step]
    var pointAt: Vec2
    var typed = 0
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    proc click(f: FrameInfo; at: Vec2) =
      f.moveMouse(at)
      f.pressMouse(at, true)
      f.pressMouse(at, false)
    proc clickMark(mark: string; then: proc (f: FrameInfo): bool) =
      var looks = 0
      proc done(f: FrameInfo): bool =
        # a click can be lost on a slow frame: made again until it has its effect
        inc looks
        result = then(f)
        if not result and looks mod 6 == 1:
          let r = f.markOf(mark)
          doAssert r.size.x > 0, mark & " is not shown"
          f.click(r.centre)
      step("click " & mark, noop, done)
    proc shoot(name: string) =
      var frames = 0
      proc act(f: FrameInfo) = f.moveMouse(vec2(4, 4)) # no tooltip over the picture
      proc done(f: FrameInfo): bool =
        inc frames
        if frames == 4 and shots.len > 0:
          createDir(shots)
          doAssert f.savePng(shots / name), "cannot save " & name
        frames >= 4
      step("a picture " & name, act, done)
    proc hover(component: uint8; then: proc (f: FrameInfo): bool) =
      proc go(f: FrameInfo) =
        let p = f.positionOf(component)
        doAssert p >= 0, "no trace of component " & $component
        let r = f.markOf("plot.data")
        let v = f.tracePanel.drawnView
        pointAt = vec2(round(r.pos.x + float32((float64(p) - v.traces.lo) / v.traces.width) *
          r.size.x), round(r.pos.y + r.size.y / 2))
        f.moveMouse(pointAt)
      proc over(f: FrameInfo): bool =
        f.moveMouse(pointAt)
        f.pick.found and componentOf(f.pick.keys) == component and then(f)
      step("hover a trace of component " & $component, go, over)
    proc rawText(f: FrameInfo): string =
      ## the readout without the note that says how many samples a zoomed-out value peaks over
      result = f.pick.text(rfRawAmplitude)
      let note = result.find(" (peak of")
      if note >= 0: result.setLen note

    var tries = 0
    proc closeWindow() =
      proc done(f: FrameInfo): bool =
        inc tries
        let w = f.markOf("project")
        if f.projectWindows.shown and w.size.x > 0 and tries mod 6 == 1:
          f.click(vec2(w.pos.x + w.size.x - 17, w.pos.y + 13))
        not f.projectWindows.shown
      step("close the Project window", noop, done)
    proc reopenWindow() =
      proc done(f: FrameInfo): bool =
        inc tries
        if not f.projectWindows.shown and tries mod 6 == 1:
          f.click(f.markOf("menu.Project").centre)
        let it = f.markOf("menu.Project...")
        if it.size.x > 0 and not f.projectWindows.shown: f.click(it.centre)
        f.projectWindows.shown and f.markOf("project.sensors").size.x > 0
      step("open the Project window again", noop, done)
    step("the file is shown", noop, answered)
    proc openMenu(f: FrameInfo) = f.click(f.markOf("menu.Project").centre)
    proc windowOpen(f: FrameInfo): bool =
      let it = f.markOf("menu.Project...")
      if it.size.x > 0 and not f.projectWindows.shown: f.click(it.centre)
      f.projectWindows.shown and f.markOf("project.sensors").size.x > 0
    step("Project > Project...", openMenu, windowOpen)
    proc listed(f: FrameInfo): bool =
      for c in 1 .. 4: doAssert f.markOf("project.sensor.value." & $c).size.x > 0, $c
      doAssert f.core.settings.amplitudeIn == aiCounts
      true
    step("the four components are listed", noop, listed)
    var looks = 0
    proc focused(f: FrameInfo): bool =
      # a click can be lost on a frame that was slow: it is made again until the box has the keys
      inc looks
      if not f.typing and looks mod 6 == 1:
        let at = f.markOf("project.sensor.value.2").centre
        f.moveMouse(at)
        f.pressMouse(at, true)
        f.pressMouse(at, false)
      f.typing
    step("click the vertical sensitivity", noop, focused)
    proc typedIn(f: FrameInfo): bool =
      inc typed
      if typed == 4: f.typeText("80")
      if typed == 7: f.pressKey(skEnter, true)
      if typed == 8: f.pressKey(skEnter, false)
      f.core.project.doc.sensors.len == 1
    step("type 80 beside the vertical component", noop, typedIn)
    proc kept(f: FrameInfo): bool =
      let s = f.core.project.doc.sensors
      doAssert s[0].component == 2 and s[0].value == 80 and s[0].unit == suVPerMPerS,
        $(s[0].value, s[0].unit)
      doAssert not f.core.inProject
      true
    step("80 V/(m/s) is kept for this run", noop, kept)
    shoot("sensors-table.png")
    proc physical(f: FrameInfo): bool =
      f.core.settings.amplitudeIn == aiPhysical and rfRawAmplitude in f.core.settings.readout
    clickMark("project.amplitude.physical units", physical)
    proc summed(f: FrameInfo): bool =
      var n = 0
      for e in f.core.log:
        if e.text.startsWith("Physical units, "): inc n
      n == 1
    step("the record's summary is said once", noop, summed)
    closeWindow()
    proc velocity(f: FrameInfo): bool =
      let s = f.rawText
      s.endsWith("m/s") and not s.startsWith("no sensor") and not s.startsWith("volts")
    hover(2, velocity)
    proc named(f: FrameInfo): bool =
      let s = f.rawText
      doAssert s.endsWith("m/s") and not s.endsWith("in/s"), s
      doAssert s.split(' ')[^1] in ["m/s", "mm/s", "µm/s", "nm/s"], s
      true
    step("the readout names a velocity", noop, named)
    shoot("sensors-readout.png")
    proc setUnits(system: UnitSystem): proc (f: FrameInfo) =
      result = proc (f: FrameInfo) =
        var s = f.core.settings
        s.units = system
        f.apply Command(kind: ckSettings, settings: s)
    proc inInches(f: FrameInfo): bool =
      f.moveMouse(pointAt)
      f.core.settings.units == usImperial and f.rawText.endsWith("in/s")
    step("Units imperial", setUnits(usImperial), inInches)
    proc inMetres(f: FrameInfo): bool =
      f.moveMouse(pointAt)
      f.core.settings.units == usMetric and f.rawText.endsWith("m/s") and
        not f.rawText.endsWith("in/s")
    step("Units metric again", setUnits(usMetric), inMetres)
    proc noHydrophone(f: FrameInfo): bool =
      f.rawText == "no sensor for component H: Project > Project... > Sensors"
    hover(1, noHydrophone)
    reopenWindow()
    proc removed(f: FrameInfo): bool =
      inc tries
      if f.core.project.doc.sensors.len > 0 and tries mod 6 == 1:
        f.click(f.markOf("project.sensor.remove.2").centre)
      f.core.project.doc.sensors.len == 0
    step("Remove the vertical sensor", noop, removed)
    closeWindow()
    proc noVertical(f: FrameInfo): bool =
      f.rawText == "no sensor for component Z: Project > Project... > Sensors"
    hover(2, noVertical)
    runSteps(obn, steps, fx.dir)
  echo "tguisensors: done"

when isMainModule:
  main()
