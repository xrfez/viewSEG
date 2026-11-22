## The noisy-trace test in the running frontend, headless, with real clicks, on
## a synthetic shot whose traces near the source are loud:
##
## - ticking "noisy" in the map's Layers popover reads the record; the popover
##   then says which rule set the area ("Area set by the first-break model")
##   and how many traces were not judged ("map.noise area");
## - the Seismic window marks the traces inside the area with a quiet band
##   behind them ("plot.noise area 1"), from the plot's left edge across the
##   traces not judged, and nothing while no noise filter is on;
## - Tools > Settings holds the choice: a radius typed into its box acts as it
##   is typed (the setting, and the band, follow before Enter), "every line" is
##   a tick, and there is no control for the components of unrotated nodes.
##
## Seen to fail: with the band drawn for the traces in file order (not the plot's), "the band is
## not at the right end of the sorted plot"; with the area's words left out of the popover,
## "the area said in the popover did not happen"; with the radius applied only on Enter, "the
## radius did not act as it was typed: 500.0". Not mutated: the quiet grey of the band (seen in
## the screenshots only), the tick "every line" beyond its setting.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves noisy-*.png there.

import std/[math, monotimes, options, os, strutils]
import processSEG/qc/exclusion
import viewSEG/core/[geometry, noisearea, state]
import viewSEG/ui/imgui/app
import viewSEG/view/maplayers
import utils/[fixtures, noisefiles, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

func tick(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.y / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc main*() =
  withFixtures fx:
    let path = fx.noisyShot("gui.sgy")
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var pointAt: Vec2
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc shot(f: FrameInfo; name: string) =
      if shots.len > 0:
        createDir(shots)
        doAssert f.savePng(shots / name), "cannot save " & name
    proc click(f: FrameInfo; p: Vec2) =
      f.moveMouse(p)
      f.pressMouse(p, true)
      f.pressMouse(p, false)
    proc clickMark(mark: string) =
      step("click " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        f.click(r.centre), proc (f: FrameInfo): bool = true)
    proc typeRadius(text: string; want: float64) =
      # click the box until it has the keys, empty it, type: the setting follows at once
      var phase = 0
      var held = 0
      var tries = 0
      step("type " & text & " into the radius", proc (f: FrameInfo) = discard,
        proc (f: FrameInfo): bool =
        let r = f.markOf("settings.noise radius")
        if r.size.x == 0: return false
        let c = r.centre
        if phase == 0:
          if not f.typing or c != pointAt:
            held = 0
            pointAt = c
            f.moveMouse(c)
            if not f.typing:
              f.pressMouse(c, true)
              f.pressMouse(c, false)
            return false
          inc held
          if held < 2: return false
          phase = 1
        elif phase == 1: # to the end of the text, then the old digits off, a key a frame
          f.pressKey(skEnd, true)
          f.pressKey(skEnd, false)
          phase = 2
          held = 0
        elif phase == 2:
          f.pressKey(skBackspace, true)
          f.pressKey(skBackspace, false)
          inc held
          if held >= 10:
            phase = 3
            held = 0
        elif phase == 3:
          f.typeText(text)
          phase = 4
          held = 0
        else:
          inc held
          # acting as it is typed: the number is in the setting while the box still has the keys
          if held >= 2 and f.typing and abs(f.core.settings.noise.radius - want) < 1e-9:
            return true
          if held > 12: # a key lost on a busy machine: again, from the click
            inc tries
            (phase, held) = (0, 0)
            if tries > 4:
              failed = "the radius did not act as it was typed: " &
                $f.core.settings.noise.radius
              f.stop()
        false)

    step("the shot shown", noop, proc (f: FrameInfo): bool =
      f.core.sessions.len == 1 and f.panel.laidOut and f.core.jobs.active.len == 0 and
        f.mapWindow.mapShown.isSet)
    step("no band, no work, while no noise filter is on", noop, proc (f: FrameInfo): bool =
      doAssert f.markNames("plot.noise area").len == 0, "a band without a filter"
      doAssert not f.core.recordQc.noise.ready and f.core.firstBreaks.len == 0, "work done"
      true)
    clickMark("map.layers")
    step("the Layers popover", noop, proc (f: FrameInfo): bool =
      f.markOf("map.filter " & $mfNoisy).size.x > 0)
    step("tick noisy", proc (f: FrameInfo) =
      f.click(f.markOf("map.filter " & $mfNoisy).tick), proc (f: FrameInfo): bool =
      mfNoisy in f.core.settings.map.filters)
    step("the area said in the popover", noop, proc (f: FrameInfo): bool =
      result = f.core.recordQc.noise.ready and f.markOf("map.noise area").size.x > 0
      if result:
        let n = f.core.recordQc.noise
        doAssert n.areaWords.startsWith("Area set by the first-break model"), n.areaWords
        doAssert n.inArea > 0, "nothing inside the area"
        f.shot("noisy-map-popover.png"))
    step("tick not judged", proc (f: FrameInfo) =
      f.click(f.markOf("map.filter " & $mfNotJudged).tick), proc (f: FrameInfo): bool =
      mfNotJudged in f.core.settings.map.filters and f.core.recordQc.job == NoJob)
    step("counted: not judged", noop, proc (f: FrameInfo): bool =
      let h = f.core.filterHits
      result = h[mfNotJudged].state == fsDone
      if result:
        doAssert h[mfNotJudged].count == f.core.recordQc.noise.notJudged and
          h[mfNotJudged].count > 0, $h[mfNotJudged].count
        doAssert filterLabel(mfNotJudged, h[mfNotJudged]).startsWith("Not judged for noise  ("),
          filterLabel(mfNotJudged, h[mfNotJudged]))
    step("close the popover", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false)
      f.moveMouse(vec2(4, 4)), proc (f: FrameInfo): bool =
      f.markOf("map.filter " & $mfNoisy).size.x == 0)
    step("the band behind the traces not judged", noop, proc (f: FrameInfo): bool =
      let b = f.markOf("plot.noise area 1")
      result = b.size.x > 0
      if result:
        let (plot, n, view) = (f.markOf("plot.data"), f.core.recordQc.noise, f.panel.view)
        let per = plot.size.x / float32(view.traces.hi - view.traces.lo)
        let left = plot.pos.x + float32(-0.5 - view.traces.lo) * per
        doAssert abs(b.pos.x - left) <= 2, "the band does not start at the first trace: " &
          $b.pos.x & ", it is at " & $left
        doAssert abs(b.size.x - float32(n.inArea) * per) <= 2.5, "band " & $b.size.x &
          " px wide for " & $n.inArea & " traces of " & $per & " px"
        doAssert abs(b.size.y - plot.size.y) <= 2, "the band does not span the time axis"
        doAssert f.markNames("plot.noise area").len == 1
        f.shot("noisy-seismic-window.png"))
    step("sorted the other way round, the band follows the traces", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSort, panel: MainPanel,
        order: @[SortKey(field: hfChannel, descending: true)])), proc (f: FrameInfo): bool =
      result = f.panel.shown.len == NoisyTraces and f.panel.shown[0] == NoisyTraces - 1 and
        not f.core.sorting(f.core.findPanel(MainPanel)) and
        f.markOf("plot.noise area 1").size.x > 0
      if result:
        let (b, plot, view) = (f.markOf("plot.noise area 1"), f.markOf("plot.data"),
          f.panel.view)
        let per = plot.size.x / float32(view.traces.hi - view.traces.lo)
        let right = plot.pos.x + float32(NoisyTraces - 0.5 - view.traces.lo) * per
        doAssert abs(b.pos.x + b.size.x - right) <= 2,
          "the band is not at the right end of the sorted plot: " & $(b.pos.x + b.size.x) &
          ", the last trace ends at " & $right)
    step("back to the file's order", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSort, panel: MainPanel, order: @[])), proc (f: FrameInfo): bool =
      f.panel.shown.len == NoisyTraces and f.panel.shown[0] == 0 and
        not f.core.sorting(f.core.findPanel(MainPanel)))
    clickMark("menu.Tools")
    clickMark("menu.Settings...")
    step("the Settings window holds the choice", noop, proc (f: FrameInfo): bool =
      result = f.markOf("settings.noise choice radius").size.x > 0
      if result:
        for c in NoiseChoice:
          doAssert f.markOf("settings.noise choice " & NoiseChoiceNames[c]).size.x > 0, $c
        doAssert f.core.settings.noise.choice == ncAuto, "not automatic by default"
        doAssert f.markNames("settings.noise component").len == 0, "a component control"
        f.shot("noisy-settings.png"))
    clickMark("settings.noise choice radius")
    step("a radius chosen", noop, proc (f: FrameInfo): bool =
      f.core.settings.noise.choice == ncRadius and f.markOf("settings.noise radius").size.x > 0)
    typeRadius("300", 300)
    step("the band follows the typed radius", noop, proc (f: FrameInfo): bool =
      let n = f.core.recordQc.noise
      result = n.ready and n.rule == arFixedRadius and abs(n.radius - 300) < 1e-9 and
        f.core.recordQc.job == NoJob
      if result:
        doAssert n.inArea == 8, "radius 300: " & $n.inArea
        let (b, plot, view) = (f.markOf("plot.noise area 1"), f.markOf("plot.data"),
          f.panel.view)
        let per = plot.size.x / float32(view.traces.hi - view.traces.lo)
        doAssert abs(b.size.x - 8 * per) <= 2.5, "band " & $b.size.x)
    clickMark("settings.noise all lines")
    step("every line", noop, proc (f: FrameInfo): bool = f.core.settings.noise.allLines)

    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if not started:
        steps[at].act(f)
        started = true
        (wait, since) = (0, getMonoTime())
      else:
        inc wait
        if wait >= 3 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 800, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    let config = fx.dir / "config"
    createDir(config)
    let code = run(RunOptions(openPaths: @[path], windowSize: (1400, 1000), theme: forceDark,
      persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguinoisy: ok"

when isMainModule:
  main()
