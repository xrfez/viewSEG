## The map's scale bar names the survey's unit and is as long as it says, in
## the running frontend, headless: on `mapSps`'s spread with its grid units
## given as metres, international feet and US survey feet (H20 `feet`, H201
## 0.3048006096, as the Morgantown survey gives them), and not given; then
## with the map's settings showing lengths in metres for the US survey feet
## survey. Each time: the bar's label ("m", "ft", "ftUS", "units"), its
## length in pixels against the map's scale (and the factor), its line drawn
## that long; and the status bar's coordinates name the unit.
##
## Seen to fail: with the bar drawn at the survey's scale but labelled in
## metres, "lengths in metres" found 200 m drawn 100 pixels long at 0.6096 m
## a pixel.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, mapview, state]
import viewSEG/ui/imgui/app
import viewSEG/view/maplayers
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

proc main() =
  withFixtures fx:
    let metres = fx.mapSpsIn("metres", "Metres", "1.0")
    let feet = fx.mapSpsIn("feet", "Feet", "0.3048")
    let usFeet = fx.mapSpsIn("usfeet", "feet", "0.3048006096")
    let none = fx.mapSpsIn("none", "", "")
    var steps: seq[Step]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc swap(to: tuple[s, r: string]): proc (f: FrameInfo) =
      result = proc (f: FrameInfo) =
        var ids: seq[SurveyLayerId]
        for l in f.core.survey.layers: ids.add l.id
        for id in ids: f.apply Command(kind: ckUnloadSurvey, layer: id)
        f.apply Command(kind: ckLoadSurvey, paths: @[to.s, to.r])
    proc bar(name, unit: string; factor: float64): proc (f: FrameInfo): bool =
      ## The bar names `unit` and is drawn as long as its length is at the
      ## map's scale times `factor`.
      result = proc (f: FrameInfo): bool =
        let text = f.mapWindow.scaleText
        result = f.core.survey.layers.len == 2 and text.endsWith(" " & unit) and
          f.mapWindow.mapShown.isSet
        if result:
          let b = f.mapWindow.scaleBarShown
          let perPixel = f.mapWindow.mapShown.perPixel * factor
          doAssert b.length > 0 and abs(b.pixels - b.length / perPixel) < 1e-6,
            name & ": " & $b & " at " & $perPixel & " a pixel"
          doAssert text == lengthText(b.length, if unit == "units": "" else: unit), text
          # its line: drawn to its end, and not past it
          let r = f.markOf("map.scale bar")
          let ink = mapInk(f.theme, pcPaper).outline
          let y = int(r.pos.y + r.size.y) - 6 - 2
          let x0 = int(r.pos.x) + 6
          proc dark(x: int): bool =
            let c = f.readPixel(x, y)
            abs(int(c.r) - int(ink.r)) + abs(int(c.g) - int(ink.g)) +
              abs(int(c.b) - int(ink.b)) < 60
          doAssert dark(x0 + 2) and dark(x0 + int(b.pixels) - 2), name & ": the line"
          if r.size.x > b.pixels + 20: doAssert not dark(x0 + int(b.pixels) + 4), name & ": past it"
          echo "tguimapunits: ", name, ": ", text, ", ", formatFloat(b.pixels, ffDecimal, 1), " px"
    step("metres", noop, bar("metres", "m", 1))
    step("feet", swap(feet), bar("feet", "ft", 1))
    step("US survey feet", swap(usFeet), bar("US survey feet", "ftUS", 1))
    step("the status bar's coordinates", proc (f: FrameInfo) =
      let d = f.markOf("map.data")
      f.moveMouse(vec2(round(d.pos.x + d.size.x / 2), round(d.pos.y + d.size.y / 3))),
      proc (f: FrameInfo): bool = f.mapCursor.endsWith(" ftUS"))
    step("lengths in metres", proc (f: FrameInfo) =
      var s = f.core.settings
      s.map.lengths = dlMetres
      f.apply(Command(kind: ckSettings, settings: s)), bar("lengths in metres", "m",
      1200 / 3937))
    step("not given", swap(none), bar("not given", "units", 1))
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
        (wait, since) = (0, getMonoTime())
      else:
        inc wait
        if wait >= 3 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 600, since):
          failed = steps[at].name & " did not happen (the bar says \"" &
            f.mapWindow.scaleText & "\")"
          f.stop()
    let code = run(RunOptions(openPaths: @[metres.s, metres.r],
      windowSize: (1200, 800), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

main()
