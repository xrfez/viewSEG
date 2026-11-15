## The map's template box in the running frontend, headless, with real
## clicks: `mapSps`'s S, R and X files and the shot of source 1003 of line 1
## (`mapShotSegy`).
##
## - Off by default: no box is drawn.
## - Ticked in the Layers popover (under the Preplot): the box of the record
##   on show is drawn round the 30 receivers its X record plans (points 101
##   to 110 of the three lines), a few pixels outside them, in the outline
##   colour, saying "X record 3: 30 receivers planned"; the receivers past it
##   (point 111) are outside.
## - The pointer on a source of the other line: its box round points 111 to
##   120, in the hover colour.
## - The X file unloaded and a template of 2 lines × 4 stations given: the
##   spreads are generated on a job, the box is round the receivers
##   processSEG's `generateRelations` gives that shot, and it says
##   "Generated".
##
## Seen to fail: with the box made round the first half of the planned
## receivers' places only, "the record's box" found it 135 px high round
## receivers 242 px apart.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves map-template-*.png there.

import std/[math, options, os, strutils]
import parseSEG
import processSEG/survey/patch
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/maplayers
import utils/fixtures

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

proc screen(f: FrameInfo; x, y: float64): Vec2 =
  f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, mapPoint(x, y))

proc centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc tick(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.y / 2), round(r.pos.y + r.size.y / 2))

func close(a, b: Rgba; by = 60): bool =
  abs(int(a.r) - int(b.r)) + abs(int(a.g) - int(b.g)) + abs(int(a.b) - int(b.b)) < by

proc around(points: openArray[(float64, float64)]; f: FrameInfo): Rect =
  ## The screen rectangle round survey points `points`.
  var (lo, hi) = (vec2(Inf, Inf), vec2(-Inf, -Inf))
  for (x, y) in points:
    let p = f.screen(x, y)
    (lo, hi) = (vec2(min(lo.x, p.x), min(lo.y, p.y)), vec2(max(hi.x, p.x), max(hi.y, p.y)))
  Rect(pos: lo, size: vec2(hi.x - lo.x, hi.y - lo.y))

proc receivers(lines: openArray[int]; first, count: int): seq[(float64, float64)] =
  for l in lines:
    for k in first ..< first + count: result.add mapRcv(l, k)

proc encloses(box, inner: Rect; pad = 7.0'f32): bool =
  ## Whether `box` is `inner` grown by `pad` pixels on each side (within 2).
  abs(box.pos.x - (inner.pos.x - pad)) <= 2 and abs(box.pos.y - (inner.pos.y - pad)) <= 2 and
    abs(box.pos.x + box.size.x - (inner.pos.x + inner.size.x + pad)) <= 2 and
    abs(box.pos.y + box.size.y - (inner.pos.y + inner.size.y + pad)) <= 2

proc main() =
  withFixtures fx:
    let sps = fx.mapSps()
    let xps = fx.mapXps()
    let shotPath = fx.mapShotSegy(0, 2)
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
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
    proc boxShown(f: FrameInfo; name: string): Rect = f.markOf("map.template " & name)

    step("loaded, no box", noop, proc (f: FrameInfo): bool =
      result = f.core.survey.layers.len == 4 and f.core.sessions.len == 1 and
        f.mapWindow.mapShown.isSet and wait > 8 and f.core.jobs.active.len == 0
      if result:
        ink = mapInk(f.theme, pcPaper)
        doAssert not f.core.settings.map.templateBox, "on by default"
        doAssert f.boxShown("shown").size.x == 0 and f.mapWindow.templateBoxes.len == 0)
    step("the Layers popover", proc (f: FrameInfo) =
      f.click(f.markOf("map.layers").centre), proc (f: FrameInfo): bool =
      wait > 3 and f.markOf("map.template").size.x > 0)
    step("ticked", proc (f: FrameInfo) =
      f.click(f.markOf("map.template").tick), proc (f: FrameInfo): bool =
      f.core.settings.map.templateBox)
    step("the record's box", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false)
      f.moveMouse(vec2(4, 4)), proc (f: FrameInfo): bool =
      result = wait > 4 and f.markOf("map.template").size.x == 0 and
        f.boxShown("shown").size.x > 0
      if result:
        let (sp, _) = f.mapWindow.spreadsShown
        doAssert sp.record == mapRecord(0, 2) and sp.stations == 30 and not sp.generated,
          $sp.record & " " & $sp.stations
        let want = receivers([0, 1, 2], 0, MapPlanned).around(f)
        let box = f.boxShown("shown")
        doAssert box.encloses(want), "the box " & $box & " round " & $want
        # its left edge, half way down: drawn in the outline colour
        let y = int(round(box.pos.y + box.size.y / 2))
        var edge = false
        for dx in -2 .. 2:
          if close(f.readPixel(int(round(box.pos.x)) + dx, y), ink.outline): edge = true
        doAssert edge, "no edge at " & $box.pos.x
        # the next receiver out is outside it
        let (ox, oy) = mapRcv(1, MapPlanned)
        let o = f.screen(ox, oy)
        doAssert o.x > box.pos.x + box.size.x, "point 111 inside the box"
        f.shot("map-template-shown.png"))
    step("a source under the pointer", proc (f: FrameInfo) =
      let (x, y) = mapSrc(1, 3)
      let p = f.screen(x, y)
      f.moveMouse(vec2(round(p.x), round(p.y))), proc (f: FrameInfo): bool =
      result = wait > 4 and f.boxShown("hovered").size.x > 0
      if result:
        let (_, sp) = f.mapWindow.spreadsShown
        doAssert sp.record == mapRecord(1, 3), $sp.record
        let want = receivers([0, 1, 2], mapPlannedFirst(1), MapPlanned).around(f)
        doAssert f.boxShown("hovered").encloses(want), $f.boxShown("hovered") & " " & $want
        f.shot("map-template-hovered.png"))
    proc unloadX(f: FrameInfo) =
      f.moveMouse(vec2(4, 4))
      var id = NoSurveyLayer
      for l in f.core.survey.layers:
        if l.path == xps: id = l.id
      f.apply Command(kind: ckUnloadSurvey, layer: id)
      var s = f.core.settings
      s.map.spreadTemplate = TemplateSpec(shape: tsPatch, lines: 2, channels: 4)
      f.apply Command(kind: ckSettings, settings: s)
    step("generated from a template", unloadX, proc (f: FrameInfo): bool =
      result = wait > 4 and f.core.spreads.job == NoJob and
        not f.core.spreads.relations.isNil and f.boxShown("shown").size.x > 0
      if result:
        let (sp, _) = f.mapWindow.spreadsShown
        doAssert sp.generated and sp.stations == 8, $sp.stations
        var g = initSurveyGeometry()
        g.addSps(sps.s)
        g.addSps(sps.r)
        let xs = g.generateRelations([PatchShot(record: 1, source: stationKey(MapSrcLines[0],
          1003, 1))], initPatchTemplate(2, 4))
        var planned: seq[(float64, float64)]
        for x in xs:
          let line = MapRcvLines.find(x.rcvLine)
          for p in int(x.fromReceiver) .. int(x.toReceiver): planned.add mapRcv(line, p - 101)
        doAssert planned.len == 8
        doAssert f.boxShown("shown").encloses(planned.around(f)), $f.boxShown("shown")
        doAssert "Generated" in f.core.spreads.words[0]
        f.shot("map-template-generated.png"))

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
        if wait >= 3 and steps[at].done(f):
          inc at
          started = false
        elif wait > 600:
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(maxFrames: 6000, openPaths: @[sps.s, sps.r, xps, shotPath],
      windowSize: (1400, 900), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

main()
