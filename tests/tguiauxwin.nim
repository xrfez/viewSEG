## The Aux window, headless, with real clicks, on a SEG-Y of two records (the first with
## three seismic and two auxiliary traces, the second with no auxiliary one):
##
## - closed at the start: no panel, no window, nothing read for it;
## - View > Windows > Aux opens it, ticked (not among the hidden windows), docked below the
##   Seismic window, titled "Aux", showing the record's two auxiliary traces;
## - its strip has the zoom and fit buttons, the wiggle fills, the gain and nothing else (no
##   record stepper, filters, sort, Seismic / Aux toggles, template or first-break button, no
##   display modes); the fill buttons and the gain are its own (the Seismic window's stay);
##   the gain types are None, Fixed and Normalized; zoom in and Fit all work in it;
## - its gear holds the Look and Traces tabs only;
## - its right-click menu is the Seismic window's without Map, Whole record, Exclude and
##   Filter; its New plot > FFT opens an FFT of the aux trace; a click on an aux trace is THE
##   selection; Kill in it is the file's edit: the Seismic window, shown with its Aux traces
##   and the killed ones hidden, leaves the trace out too;
## - the Seismic window's next record updates it, a record with no auxiliary traces says so;
## - with both open and the first-break overlay on, 200 frames start a bounded number of
##   jobs and settle;
## - closed again from the menu, the panel shows nothing.
##
## `VIEWSEG_SCREENSHOTS=<dir>` saves aux-docked.png, aux-gear.png, aux-menu.png, aux-view.png
## (the View > Windows menu with the tick) and aux-none.png there.
##
## Seen to fail: with the Aux strip drawn for the Seismic window's groups, "the Aux strip
## has a record stepper"; with `capsOf(prAux).menuMap` true, "the Aux menu has aux.menu.station";
## with `ckAuxWindow` not opening the window, "the Aux entry did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, state, viewport]
import viewSEG/ui/imgui/app
import utils/[auxfiles, fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

const vibSample = currentSourcePath().parentDir.parentDir / "samples" / "vib" /
  "vib_uncorrelated.sgd"

proc vibShots(dir: string) =
  ## With `VIEWSEG_SCREENSHOTS`: the Aux window on the synthetic vibrator record (48 seismic
  ## traces, the pilot and the ground force): docked with the Seismic window
  ## (aux-vib-docked.png), its gear (aux-vib-gear.png), its right-click menu
  ## (aux-vib-menu.png) and View > Windows with its tick (aux-vib-view.png).
  var stage, wait = 0
  var since = getMonoTime()
  var saved: seq[string]
  var at: Vec2
  proc onFrame(f: FrameInfo) =
    inc wait
    template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
    if f.index == 0: f.moveMouse(vec2(4, 4))
    let k = f.core.findPanel(MainPanel)
    let a = f.core.auxIndex
    case stage
    of 0:
      if f.core.panels[k].laidOut and f.core.tiles(k).len > 0 and wait > 20:
        f.apply Command(kind: ckAuxWindow, onScreen: true)
        next 1
    of 1:
      if a >= 0 and f.core.panels[a].laidOut and f.core.tiles(a).len > 0 and wait > 40:
        if f.savePng(dir / "aux-vib-docked.png"): saved.add "aux-vib-docked.png"
        f.moveMouse(f.markOf("aux.more").centre)
        next 2
    of 2:
      if wait == 4: f.pressMouse(f.markOf("aux.more").centre, true)
      if wait == 5: f.pressMouse(f.markOf("aux.more").centre, false)
      if wait == 15:
        if f.savePng(dir / "aux-vib-gear.png"): saved.add "aux-vib-gear.png"
        f.pressKey(skEscape, true)
        f.pressKey(skEscape, false)
        next 3
    of 3:
      if wait == 6:
        let v = f.core.panels[a].view
        let r = f.markOf("aux.data")
        let q = v.screenAt(r, DataPoint(x: 0.0, tMs: v.timeMs.lo + (v.timeMs.hi - v.timeMs.lo) / 3))
        at = vec2(round(q.x), round(q.y))
        f.moveMouse(at)
      if wait == 10:
        f.pressMouse(at, true)
        f.pressMouse(at, false)
      if wait == 14:
        f.pressMouse(at, true, 3)
        f.pressMouse(at, false, 3)
      if wait == 24:
        if f.savePng(dir / "aux-vib-menu.png"): saved.add "aux-vib-menu.png"
        f.pressKey(skEscape, true)
        f.pressKey(skEscape, false)
        next 4
    of 4:
      if wait == 6:
        f.moveMouse(f.markOf("menu.View").centre)
      if wait == 8:
        f.pressMouse(f.markOf("menu.View").centre, true)
        f.pressMouse(f.markOf("menu.View").centre, false)
      if wait == 30:
        if f.savePng(dir / "aux-vib-view.png"): saved.add "aux-vib-view.png"
        f.stop()
    else: f.stop()
    if overdue(wait, 1500, since): f.stop()
  let tmp = getTempDir() / ("viewseg-auxshots-" & $getCurrentProcessId())
  let code = run(RunOptions(openPaths: @[vibSample], windowSize: (1600, 1000), theme: forceDark,
    indexCacheDir: some(tmp), userThemeDir: some(tmp / "no-user-themes"), onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0 and saved.len == 4, "screenshots saved: " & $saved
  echo "tguiauxwin: saved ", saved.join(", "), " in ", dir

proc main*() =

  withFixtures fx:
    let path = twoRecordsSegy(fx.dir)
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    if shots.len > 0: createDir(shots)
    var steps: seq[Step]
    var pointAt: Vec2
    var base = 0
    var jobsBefore = 0
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    proc shoot(f: FrameInfo; name: string) =
      if shots.len > 0: discard f.savePng(shots / name)
    proc click(f: FrameInfo; q: Vec2; button = 1) =
      f.moveMouse(q)
      f.pressMouse(q, true, button)
      f.pressMouse(q, false, button)
    proc clickMark(mark: string) =
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = r.centre
        f.moveMouse(pointAt), after(3))
      step("click " & mark, proc (f: FrameInfo) = f.click(pointAt), after(3))
    func mainAnswered(f: FrameInfo): bool =
      let k = f.core.findPanel(MainPanel)
      let p = f.core.panels[k]
      let tiles = f.core.tiles(k)
      p.laidOut and tiles.len > 0 and tiles[^1].request == p.pending and
        p.pending.gen == p.requestGen
    func auxAnswered(f: FrameInfo): bool =
      let k = f.core.auxIndex
      if k < 0 or f.core.panels[k].layers.len == 0: return false
      let p = f.core.panels[k]
      let tiles = f.core.tiles(k)
      p.laidOut and tiles.len > 0 and tiles[^1].request == p.pending and
        p.pending.gen == p.requestGen
    func aux(f: FrameInfo): Panel = f.core.panels[f.core.auxIndex]
    func main(f: FrameInfo): Panel = f.core.panels[f.core.findPanel(MainPanel)]
    func atPosition(f: FrameInfo; position: int; tMs = 120.0): Vec2 =
      let v = f.aux.view.screenAt(f.markOf("aux.data"), DataPoint(x: float64(position), tMs: tMs))
      vec2(round(v.x), round(v.y))
    func gone(f: FrameInfo; names: openArray[string]): string =
      ## The names among `names` that are marked (drawn) now.
      for n in names:
        if f.markOf(n).size.x > 0: result.add n & " "

    proc openView(f: FrameInfo) =
      let title = f.markOf("menu.View")
      f.click(title.centre)
      let last = f.markOf("menu.Help")
      f.moveMouse(vec2(last.pos.x + last.size.x + 40, title.centre.y))
    proc setHideKilled(on: bool): proc (f: FrameInfo) =
      result = proc (f: FrameInfo) =
        var s = f.core.settings
        s.hideKilled = on
        f.apply Command(kind: ckSettings, settings: s)
    proc setBreaks(on: bool): proc (f: FrameInfo) =
      result = proc (f: FrameInfo) =
        var d = f.main.layers[0].display
        d.firstBreaks = on
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    proc seismicAndAux(f: FrameInfo) =
      setHideKilled(true)(f)
      f.apply Command(kind: ckFilter, panel: MainPanel,
        filter: TraceFilter(seismic: true, auxiliary: true))
    proc seismicOnly(f: FrameInfo) =
      setHideKilled(false)(f)
      f.apply Command(kind: ckFilter, panel: MainPanel, filter: TraceFilter(seismic: true))
    proc newestJob(f: FrameInfo): int =
      for j in f.core.jobs.list: result = max(result, int(j.id))
    proc breaksOnAndCount(f: FrameInfo) =
      setBreaks(true)(f)
      jobsBefore = f.newestJob
    # ------------------------------------------------------------------ closed --
    step("the record, Aux closed", noop, proc (f: FrameInfo): bool =
      result = f.mainAnswered and f.main.layout.traces == 3
      if result:
        doAssert f.core.auxIndex < 0 and not f.core.auxOpen, "a panel for a closed window"
        doAssert f.markOf("aux.data").size.x == 0 and not f.windowPlace("aux").shown
        doAssert awAux in f.hiddenWindows, "the Aux window is not closed at the start"
        base = f.core.sessions[0].base
        jobsBefore = f.core.tilesTaken)
    # ------------------------------------------------------------ View > Windows --
    step("View", openView,
      proc (f: FrameInfo): bool =

      result = f.markOf("menu.window.aux").size.x > 0 and wait > 3
      if result: f.shoot("aux-view-closed.png"))
    step("the Aux entry", proc (f: FrameInfo) = f.click(f.markOf("menu.window.aux").centre),
      proc (f: FrameInfo): bool =
      result = f.core.auxOpen and f.auxAnswered
      if result:
        doAssert awAux notin f.hiddenWindows, "the entry is not ticked")
    step("docked below the Seismic window", noop, proc (f: FrameInfo): bool =
      result = f.windowPlace("aux").inSight and f.markOf("aux.data").size.x > 0 and wait > 8
      if result:
        let (a, m) = (f.windowPlace("aux"), f.windowPlace("plot"))
        doAssert a.docked and not a.apart, "the Aux window is not docked"
        doAssert a.rect.pos.y >= m.rect.pos.y + m.rect.size.y - 4,
          "the Aux window is not below the Seismic window: " & $a.rect & " and " & $m.rect
        doAssert f.windowName("aux").contains("Aux"), f.windowName("aux")
        doAssert f.aux.role == prAux and f.aux.layout.traces == 2
        doAssert f.aux.shown == @[3, 4], $f.aux.shown
        doAssert f.main.layout.traces == 3
        # nothing but its own tiles was read for it
        doAssert f.core.tilesTaken - jobsBefore <= 3, "reads: " & $(f.core.tilesTaken - jobsBefore)
        f.shoot("aux-docked.png"))
    step("View, ticked", openView,
      proc (f: FrameInfo): bool =
      result = f.markOf("menu.window.aux").size.x > 0 and wait > 3
      if result:
        f.shoot("aux-view.png")
        f.click(f.markOf("statusbar").centre)) # closes the menu
    # ------------------------------------------------------------------- strip --
    step("the strip", noop, proc (f: FrameInfo): bool =
      result = wait > 3 and f.markOf("aux.zoom in").size.x > 0
      if result:
        let present = ["aux.zoom in", "aux.zoom out", "aux.fit", "aux.Positive fill",
          "aux.Negative fill", "aux.gain", "aux.gain dB", "aux.more"]
        for n in present: doAssert f.markOf(n).size.x > 0, n & " is not on the Aux strip"
        doAssert f.markOf("aux.previous record").size.x == 0, "the Aux strip has a record stepper"
        let never = ["aux.previous record", "aux.next record", "aux.record", "aux.Wiggle",
          "aux.Greyscale density", "aux.Wiggle over density", "aux.template only",
          "aux.First breaks", "aux.traces.Seismic", "aux.traces.Aux", "aux.filters",
          "aux.raw", "aux.sort"]
        doAssert f.gone(never).len == 0, "on the Aux strip: " & f.gone(never)
        doAssert f.markOf("plot.previous record").size.x > 0, "the Seismic strip lost its stepper")
    # fills: the Aux window's own
    clickMark("aux.Negative fill")
    step("negative fill", noop, proc (f: FrameInfo): bool =
      result = wfNegative in f.aux.layers[0].display.fills
      if result:
        doAssert wfNegative notin f.main.layers[0].display.fills, "the Seismic fill changed"
        doAssert f.core.settings.aux.display.fills == {wfPositive, wfNegative})
    clickMark("aux.Positive fill")
    step("positive fill off", noop, proc (f: FrameInfo): bool =
      result = f.aux.layers[0].display.fills == {wfNegative}
      if result: doAssert wfPositive in f.main.layers[0].display.fills)
    clickMark("aux.Positive fill")
    # gain: its own, three types
    clickMark("aux.gain")
    step("the gain list", noop, proc (f: FrameInfo): bool =
      result = f.markOf("aux.gain type none").size.x > 0 and wait > 3
      if result:
        for t in ["none", "fixed", "normalized"]:
          doAssert f.markOf("aux.gain type " & t).size.x > 0, t & " is not offered"
        let never = ["aux.gain type exponential", "aux.gain type float", "aux.gain type AGC",
          "aux.gain choose"]
        doAssert f.gone(never).len == 0, "the Aux gain offers " & f.gone(never)
        doAssert f.aux.layers[0].display.gain == dgNormalized)
    clickMark("aux.gain type fixed")
    step("fixed", noop, proc (f: FrameInfo): bool =
      result = f.aux.layers[0].display.gain == dgFixed
      if result:
        doAssert f.main.layers[0].display.gain != dgFixed, "the Seismic gain changed"
        doAssert f.core.settings.plot.display.gain != dgFixed)
    step("fixed takes the record's level", noop, proc (f: FrameInfo): bool =
      let c = f.aux.layers[0].display.fixedClip
      result = c > 0 and c < 1e30
      if result: doAssert c > 100, "Fixed took the seismic level, not the auxiliary: " & $c)
    clickMark("aux.gain type none")
    step("none", noop, proc (f: FrameInfo): bool = f.aux.layers[0].display.gain == dgNone)
    clickMark("aux.gain type normalized")
    step("normalized", noop, proc (f: FrameInfo): bool = f.aux.layers[0].display.gain == dgNormalized)
    step("close the list", proc (f: FrameInfo) = f.click(f.markOf("statusbar").centre),
      after(4))
    # the gain amount
    step("more gain", proc (f: FrameInfo) =
      let r = f.markOf("aux.gain more")
      doAssert r.size.x > 0, "no + button"
      f.moveMouse(r.centre), after(3))
    step("click +", proc (f: FrameInfo) =
      f.click(f.markOf("aux.gain more").centre), proc (f: FrameInfo): bool =
      result = f.aux.layers[0].display.gainDb == 3.0
      if result: doAssert f.main.layers[0].display.gainDb == 0.0)
    # zoom and fit
    var span = 0.0
    var mainView: Viewport
    step("the view", noop, proc (f: FrameInfo): bool =
      span = f.aux.view.timeMs.hi - f.aux.view.timeMs.lo
      mainView = f.main.view
      span > 0)
    clickMark("aux.zoom in")
    step("zoomed in", noop, proc (f: FrameInfo): bool =
      result = f.aux.view.timeMs.hi - f.aux.view.timeMs.lo < span * 0.9
      if result:
        doAssert f.main.view.timeMs == mainView.timeMs, "the Seismic view zoomed")
    clickMark("aux.fit")
    step("fitted", noop, proc (f: FrameInfo): bool =
      result = abs(f.aux.view.timeMs.hi - f.aux.view.timeMs.lo - span) < 1e-6 * span)
    # ------------------------------------------------------------------- gear --
    clickMark("aux.more")
    step("the gear", noop, proc (f: FrameInfo): bool =
      result = f.markOf("aux.more popover").size.x > 0 and wait > 3
      if result:
        doAssert f.markOf("aux.more tab look").size.x > 0, "no Look tab"
        doAssert f.markOf("aux.more tab traces").size.x > 0, "no Traces tab"
        doAssert f.markOf("aux.more tab scales").size.x == 0, "the Aux gear has a Scales tab"
        f.shoot("aux-gear.png"))
    clickMark("aux.more tab traces")
    step("Traces tab", noop, proc (f: FrameInfo): bool =
      result = f.markOf("aux.more.hide killed").size.x > 0 and wait > 3
      if result:
        doAssert f.markOf("aux.overlap").size.x > 0, "no trace overlap"
        doAssert f.markOf("aux.more.header.auto").size.x > 0, "no display header rows")
    step("close the gear", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
      f.markOf("aux.more popover").size.x == 0)
    # --------------------------------------------------------------- selection --
    step("over an auxiliary trace", proc (f: FrameInfo) =
      pointAt = f.atPosition(0)
      f.moveMouse(pointAt), proc (f: FrameInfo): bool =
        result = f.pick.found and wait > 3
        if result: doAssert f.pick.keys.status == tsAuxiliary, $f.pick.keys.status)
    step("click it", proc (f: FrameInfo) = f.click(pointAt), proc (f: FrameInfo): bool =
      result = f.core.selection.selectedCount == 1 and (base + 3) in f.core.selection.selected
      if result: doAssert f.core.selection.activeGather.gather == 0)
    step("the status bar follows", noop, proc (f: FrameInfo): bool = wait > 3 and f.pick.found)
    # ------------------------------------------------------------------- menu --
    step("right click", proc (f: FrameInfo) = f.click(pointAt, button = 3),
      proc (f: FrameInfo): bool =
      result = f.markOf("aux.menu").size.x > 0 and wait > 3
      if result:
        for n in ["target", "reverse", "kill", "undo", "newplot", "compare", "store"]:
          doAssert f.markOf("aux.menu." & n).size.x > 0, "the Aux menu has no " & n
        let never = ["aux.menu.heading.find", "aux.menu.heading.record", "aux.menu.station",
          "aux.menu.reverse all", "aux.menu.clear", "aux.menu.exclude", "aux.menu.filter"]
        doAssert f.gone(never).len == 0, "the Aux menu has " & f.gone(never)
        doAssert f.auxTracePanel.menuTarget == "1 selected trace", f.auxTracePanel.menuTarget
        f.shoot("aux-menu.png"))
    step("Kill", proc (f: FrameInfo) = f.click(f.markOf("aux.menu.kill").centre),
      proc (f: FrameInfo): bool =
      result = teKilled in f.core.traceEdits(base + 3)
      if result: doAssert f.aux.layers[0].source.gather == 0)
    step("right click again", proc (f: FrameInfo) =
      pointAt = f.atPosition(0)
      f.moveMouse(pointAt), after(4))
    step("the menu", proc (f: FrameInfo) = f.click(pointAt, button = 3),
      proc (f: FrameInfo): bool = f.markOf("aux.menu.newplot").size.x > 0 and wait > 3)
    step("New plot", proc (f: FrameInfo) = f.click(f.markOf("aux.menu.newplot").centre),
      proc (f: FrameInfo): bool =
      f.markOf("aux.menu.newplot.fft").size.x > 0 and wait > 3)
    step("FFT", proc (f: FrameInfo) = f.click(f.markOf("aux.menu.newplot.fft").centre),
      proc (f: FrameInfo): bool =
      result = f.core.spectra.len > 1
      if result:
        doAssert f.core.spectra[^1].traces == @[base + 3], $f.core.spectra[^1].traces
        doAssert f.core.spectra[^1].panel == f.core.panels[f.core.auxIndex].id)
    proc closeFft(f: FrameInfo) =
      f.apply Command(kind: ckCloseSpectrum, spectrum: f.core.spectra[^1].id)
    step("close the FFT window", closeFft, proc (f: FrameInfo): bool = f.core.spectra.len == 1)
    # a kill made in the Aux window is the file's: the Seismic window, shown with its
    # Aux traces and the killed ones hidden, leaves the trace out
    step("Seismic + Aux, killed traces hidden", seismicAndAux,
      proc (f: FrameInfo): bool =
      result = f.mainAnswered and f.main.layout.traces == 4
      if result: doAssert f.main.shown == @[0, 1, 2, 4], "the Seismic window: " & $f.main.shown)
    step("back to seismic", seismicOnly,
      proc (f: FrameInfo): bool = f.mainAnswered and f.main.layout.traces == 3)
    # ---------------------------------------------------------------- following --
    step("settled before the next record", noop, after(10))
    clickMark("plot.next record")
    step("the next record", noop, proc (f: FrameInfo): bool =
      result = f.mainAnswered and f.aux.layers[0].source.gather == 1 and f.aux.laidOut and
        wait > 6
      if result:
        doAssert f.auxTracePanel.instead == "This record has no auxiliary traces.",
          "the Aux window says: " & f.auxTracePanel.instead
        f.shoot("aux-none.png"))
    clickMark("plot.previous record")
    step("the first record again", noop, proc (f: FrameInfo): bool =
      result = f.auxAnswered and f.aux.layers[0].source.gather == 0 and f.aux.layout.traces == 2 and
        wait > 4
      if result: doAssert f.auxTracePanel.instead.len == 0)
    # ------------------------------------------------------- 200 frames, settled --
    step("first breaks on", breaksOnAndCount, after(200))
    step("jobs settled", noop, proc (f: FrameInfo): bool =
      result = true
      let started = f.newestJob - jobsBefore
      doAssert started <= 4, "jobs started in 200 frames: " & $started
      doAssert f.core.jobs.active.len == 0, "jobs still running")
    step("first breaks off", setBreaks(false), after(2))
    # ---------------------------------------------------------------- closed again --
    step("View again", openView,
      proc (f: FrameInfo): bool = f.markOf("menu.window.aux").size.x > 0 and wait > 3)
    step("untick Aux", proc (f: FrameInfo) = f.click(f.markOf("menu.window.aux").centre),
      proc (f: FrameInfo): bool =
      result = not f.core.auxOpen and f.markOf("aux.data").size.x == 0
      if result:
        doAssert awAux in f.hiddenWindows
        doAssert f.aux.layers.len == 0, "closed, the Aux panel still shows a record")
    step("View, once more", openView,
      proc (f: FrameInfo): bool = f.markOf("menu.window.aux").size.x > 0 and wait > 3)
    step("tick Aux again", proc (f: FrameInfo) = f.click(f.markOf("menu.window.aux").centre),
      proc (f: FrameInfo): bool =
      result = f.core.auxOpen and f.auxAnswered and wait > 6
      if result:
        doAssert f.aux.layers[0].display.gain == dgNormalized and
          f.aux.layers[0].display.gainDb == 3.0, "opened again, its own display was lost"
        doAssert f.windowPlace("aux").docked)

    proc drive(steps: seq[Step]) =
      var at = 0
      var started = false
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
          elif overdue(wait, 400, since):
            failed = steps[at].name & " did not happen"
            f.stop()
      let code = run(RunOptions(openPaths: @[path], windowSize: (1500, 950), theme: forceDark,
        userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
        persist: true, configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
        onFrame: onFrame))
      doAssert code == 0, "run() exit code " & $code
      doAssert failed.len == 0, failed
      doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    drive(steps)

    # ------------------------------------------------------------- the next run --
    # The run ended with the window open (ticked again above): the layout kept it open and
    # below the Seismic window, the settings its own display, gain and fills.
    steps.setLen 0
    step("open at the start", noop, proc (f: FrameInfo): bool =
      result = f.core.auxOpen and f.auxAnswered and f.windowPlace("aux").inSight and wait > 8
      if result:
        let (a, m) = (f.windowPlace("aux"), f.windowPlace("plot"))
        doAssert a.docked and a.rect.pos.y >= m.rect.pos.y + m.rect.size.y - 4,
          "the Aux window did not keep its place: " & $a.rect
        doAssert awAux notin f.hiddenWindows
        let d = f.aux.layers[0].display
        doAssert d.gain == dgNormalized and d.gainDb == 3.0 and d.fills == {wfPositive, wfNegative},
          "the Aux window did not keep its display: " & $d.gain & " " & $d.gainDb
        doAssert f.main.layers[0].display.gainDb == 0.0)
    drive(steps)
    if shots.len > 0 and fileExists(vibSample): vibShots(shots)
    echo "tguiauxwin: ok"

when isMainModule: main()
