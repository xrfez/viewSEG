## The map's Layers list in groups, in the running frontend, headless, with
## real clicks: `mapSps`'s S and R files (the Preplot) and the survey's
## seismic file, whose headers place its sources and receivers (the
## Recorded: rings on the receivers of line 100, its three sources between
## them).
##
## - The Layers popover lists the Preplot group (its tick, then the S and R
##   files' layers under it), then the Recorded group (its tick, then the
##   seismic file's own layers), then the highlight; each layer view says its
##   group.
## - Unticking the Preplot hides the survey files' points (a Preplot source
##   is no longer drawn, nor found under the pointer) and keeps the Recorded
##   ones; the settings say so (`map.hiddenGroups`), the layers keep their
##   own ticks.
## - Ticking it again and unticking the Recorded: the seismic file's own
##   source is gone, with its highlight as the record on show, and the
##   Preplot is back.
##
## Seen to fail: with `drawn` ignoring the groups, "the Preplot hidden" found
## 12 pixels of the sources' colour at the Preplot source still drawn; with
## the highlight drawn for hidden layers, "the Recorded hidden" found 39 at
## the record's own source.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves map-groups-*.png there.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/maplayers
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func same(a, b: Rgba): bool = a.r == b.r and a.g == b.g and a.b == b.b

proc screen(f: FrameInfo; x, y: float64): Vec2 =
  ## Where survey point (`x`, `y`) is drawn now, framebuffer pixels.
  f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, mapPoint(x, y))

proc around(f: FrameInfo; at: Vec2; c: Rgba; reach = 7): int =
  ## The pixels of colour `c` within `reach` pixels of `at`.
  for dy in -reach .. reach:
    for dx in -reach .. reach:
      if same(f.readPixel(int(floor(at.x)) + dx, int(floor(at.y)) + dy), c): inc result

proc centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc tick(r: Rect): Vec2 =
  ## A checkbox's box: at the left of its item.
  vec2(round(r.pos.x + r.size.y / 2), round(r.pos.y + r.size.y / 2))

proc main() =
  withFixtures fx:
    let sps = fx.mapSps()
    let segy = fx.surveySegy()
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
    var failed = ""
    var ink: MapInk
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc shot(f: FrameInfo; name: string) =
      if shots.len > 0:
        createDir(shots)
        discard f.savePng(shots / name)
    proc click(f: FrameInfo; p: Vec2) =
      f.moveMouse(p)
      f.pressMouse(p, true)
      f.pressMouse(p, false)
    # A Preplot source no recorded point is near, and the seismic file's
    # first source (the record on show's: drawn as a filled disc 10 px
    # across), whose nearest Preplot source is 12.5 m (7 px) north.
    let (px, py) = mapSrc(1, 6)
    let (rx, ry) = (srcX(0), OriginY)
    proc preplot(f: FrameInfo): int = f.around(f.screen(px, py), ink.roles[prSource])
    proc recorded(f: FrameInfo): int = f.around(f.screen(rx, ry), ink.roles[prSource], 3)

    step("loaded", noop, proc (f: FrameInfo): bool =
      result = f.core.survey.layers.len == 3 and f.mapWindow.mapImagesDrawn > 0 and
        f.mapWindow.mapShown.isSet and wait > 8 and f.core.sessions.len == 1
      if result:
        ink = mapInk(f.theme, pcPaper)
        doAssert f.preplot > 0 and f.recorded > 0, $(f.preplot, f.recorded)
        let layers = mapLayers(f.core, ink)
        for l in layers:
          if l.key.kind == mlSurveyFile: doAssert l.group == mgPreplot, l.name
          elif l.key.kind == mlTraces: doAssert l.group == mgRecorded, l.name)

    step("the Layers popover in groups", proc (f: FrameInfo) =
      f.click(f.markOf("map.layers").centre), proc (f: FrameInfo): bool =
      result = wait > 3 and f.markOf("map.group preplot").size.x > 0
      if result:
        let pre = f.markOf("map.group preplot")
        let rec = f.markOf("map.group recorded")
        let s = f.markOf("map.layer map.s sources")
        let r = f.markOf("map.layer map.r receivers")
        let own = f.markOf("map.layer " & segy.extractFilename & " sources")
        let hl = f.markOf("map.layer highlight")
        for (name, m) in [("preplot", pre), ("recorded", rec), ("S", s), ("R", r),
            ("own", own), ("highlight", hl)]:
          doAssert m.size.x > 0, name & " not listed"
        doAssert pre.pos.y < s.pos.y and pre.pos.y < r.pos.y, "the Preplot's layers under it"
        doAssert s.pos.y < rec.pos.y and r.pos.y < rec.pos.y, "the Recorded after them"
        doAssert rec.pos.y < own.pos.y and own.pos.y < hl.pos.y, "the seismic file's under it"
        doAssert s.pos.x > pre.pos.x and own.pos.x > rec.pos.x, "indented"
        f.shot("map-groups-popover.png"))

    proc closePopover(f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false)
    proc closed(f: FrameInfo): bool = wait > 4 and f.markOf("map.group preplot").size.x == 0

    step("the Preplot unticked", proc (f: FrameInfo) =
      f.click(f.markOf("map.group preplot").tick), proc (f: FrameInfo): bool =
      f.core.settings.map.hiddenGroups == {mgPreplot})
    step("the Preplot hidden", closePopover, proc (f: FrameInfo): bool =
      result = f.closed
      if result:
        doAssert f.preplot == 0, $f.preplot & " pixels of the Preplot source still drawn"
        doAssert f.recorded > 0, "the Recorded went too"
        for l in mapLayers(f.core, ink):
          if l.key.kind == mlSurveyFile: doAssert l.own and not l.shown, l.name
          elif l.key.kind == mlTraces: doAssert l.own and l.shown, l.name
        f.shot("map-groups-preplot-hidden.png"))

    step("a hidden Preplot point is not found under the pointer", proc (f: FrameInfo) =
      let p = f.screen(px, py)
      f.moveMouse(vec2(round(p.x), round(p.y))), proc (f: FrameInfo): bool =
      result = wait > 6
      if result:
        doAssert f.mapWindow.hoveredPoints.len == 0, "found under the pointer")

    step("the popover again", proc (f: FrameInfo) =
      f.click(f.markOf("map.layers").centre), proc (f: FrameInfo): bool =
      wait > 3 and f.markOf("map.group recorded").size.x > 0)
    step("the Preplot ticked", proc (f: FrameInfo) =
      f.click(f.markOf("map.group preplot").tick), proc (f: FrameInfo): bool =
      f.core.settings.map.hiddenGroups == {} and wait > 3)
    step("the Recorded unticked", proc (f: FrameInfo) =
      f.click(f.markOf("map.group recorded").tick), proc (f: FrameInfo): bool =
      f.core.settings.map.hiddenGroups == {mgRecorded})
    step("the Recorded hidden", closePopover, proc (f: FrameInfo): bool =
      result = f.closed
      if result:
        doAssert f.preplot > 0, "the Preplot is not back"
        doAssert f.recorded == 0, $f.recorded & " pixels of the recorded source still drawn"
        f.shot("map-groups-recorded-hidden.png"))

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
        elif overdue(wait, 600, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(openPaths: @[sps.s, sps.r, segy],
      windowSize: (1400, 900), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

main()
