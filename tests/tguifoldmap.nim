## The map's "Pre-plot fold" layer in the running frontend, headless, with real
## clicks, on `samples/land` (a rotated survey: its receiver lines run along an
## azimuth, so its bins are quads):
##
## - With the S and R files alone the layer's line in the Layers popover is
##   dim: a click on it does not turn it on, and no fold is counted.
## - With the X file loaded the tick turns it on; the job runs ("computing"),
##   then the line names the highest fold.
## - The bins are drawn: at the centre of a bin of known fold the pixel has
##   the Viridis colour of that fold (so the grid is not mirrored, offset or
##   rotated the wrong way: neighbouring bins differ), and the centre of a bin
##   of no fold has the background's.
## - The legend (0 to the highest fold) is in a corner; the hover readout names
##   the bin under the pointer ("fold N (inline I, crossline X)").
## - A bin size typed in the popover is saved, and a restart brings the layer
##   back with it, counting again with that bin.
##
## Seen to fail: with the bins' inline axis mirrored in the shader (`vAxis` negated),
## "the colour at the centre of the bins" found 8 of 64 bins right; with the hover
## bin looked up on the unrotated grid, "the hover names the bin" found another bin's fold.
##
## Needs a display: run under `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves map-fold-*.png there.

import std/[math, monotimes, options, os, strformat, strutils]
import viewSEG/core/[foldgrid, foldjobs, geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/maplayers
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

const Land = "samples/land/land"

var wait = 0 ## frames since the step began

proc screen(f: FrameInfo; x, y: float64): Vec2 =
  f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, mapPoint(x, y))

proc centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc tick(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.y / 2), round(r.pos.y + r.size.y / 2))

func near(a, b: Rgba; by = 6): bool =
  abs(int(a.r) - int(b.r)) <= by and abs(int(a.g) - int(b.g)) <= by and
    abs(int(a.b) - int(b.b)) <= by

func binCentre(r: FoldResult; bin: int): (float64, float64) =
  let (i, j) = (float64(bin div r.crosslines), float64(bin mod r.crosslines))
  let (s, c) = (sin(degToRad(r.azimuthDeg)), cos(degToRad(r.azimuthDeg)))
  (r.x0 + j * r.binAlong * s + i * r.binAcross * c, r.y0 + j * r.binAlong * c - i * r.binAcross * s)

proc rotated(src, dest: string; degrees: float64) =
  ## `src`, an SPS S or R file, with its coordinates turned `degrees` about the
  ## middle of `samples/land` (easting in columns 47 to 55, northing in 56 to 65):
  ## the receiver lines then run at an azimuth that is not a quarter turn.
  let (cx, cy) = (2_001_000.0, 500_000.0)
  let (s, c) = (sin(degToRad(degrees)), cos(degToRad(degrees)))
  var text = ""
  for line in readFile(src).splitLines:
    var l = line
    if l.len >= 65 and l[0] in {'S', 'R'}:
      let x = parseFloat(l[46 .. 54].strip)
      let y = parseFloat(l[55 .. 64].strip)
      let (dx, dy) = (x - cx, y - cy)
      let (nx, ny) = (cx + dx * c - dy * s, cy + dx * s + dy * c)
      l = l[0 .. 45] & &"{nx:>9.1f}" & &"{ny:>10.1f}" & l[65 .. ^1]
    text.add l & "\n"
  writeFile(dest, text)

proc runStages(fx: Fixtures; config: string; paths: seq[string]; list: seq[Step];
    size = (1400, 900)) =
  let steps = list
  var at = 0
  var started = false
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
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(openPaths: paths, windowSize: size, theme: forceDark,
    userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
    persist: true, configDir: some(config), logDir: some(fx.dir / "logs"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc main*() =
  withFixtures fx:
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    let config = fx.dir / "config"
    let (sFile, rFile, xFile) = (fx.dir / "land.s", fx.dir / "land.r", absolutePath(Land & ".x"))
    rotated(Land & ".s", sFile, 30)
    rotated(Land & ".r", rFile, 30)
    var ink: MapInk

    block firstRun:
      var steps: seq[Step]
      proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
        steps.add Step(name: name, act: act, done: done)
      proc noop(f: FrameInfo) = discard
      proc click(f: FrameInfo; p: Vec2) =
        f.moveMouse(p)
        f.pressMouse(p, true)
        f.pressMouse(p, false)
      proc shot(f: FrameInfo; name: string) =
        if shots.len > 0:
          createDir(shots)
          discard f.savePng(shots / name)
      proc popoverOpen(f: FrameInfo; mark: string): bool =
        result = f.markOf(mark).size.x > 0
        if not result and wait mod 8 == 7: f.click(f.markOf("map.layers").centre)
      proc closePopover(f: FrameInfo) =
        f.pressKey(skEscape, true)
        f.pressKey(skEscape, false)

      step("loaded", noop, proc (f: FrameInfo): bool =
        result = f.core.survey.layers.len == 2 and f.mapWindow.mapImagesDrawn > 0 and
          f.mapWindow.mapShown.isSet and f.core.jobs.active.len == 0
        if result: ink = mapInk(f.theme, pcPaper))

      step("the popover without X", proc (f: FrameInfo) =
        f.click(f.markOf("map.layers").centre), proc (f: FrameInfo): bool =
        f.popoverOpen("map.fold"))
      proc dimClick(f: FrameInfo) =
        doAssert f.core.survey.foldReason == NoRelations
        f.click(f.markOf("map.fold").tick)
      step("a click on the dim tick", dimClick, proc (f: FrameInfo): bool =
        result = wait > 6
        if result:
          doAssert not f.core.settings.map.foldLayer, "the dim tick was turned on"
          doAssert f.mapWindow.foldStatus == fmOff and f.mapWindow.foldResult.isNil)
      step("the X file loaded", proc (f: FrameInfo) =
        f.apply(Command(kind: ckLoadSurvey, paths: @[xFile])), proc (f: FrameInfo): bool =
        f.core.survey.layers.len == 3 and f.core.jobs.active.len == 0 and
          f.core.survey.foldReason == "")
      step("the tick turns it on", proc (f: FrameInfo) =
        f.click(f.markOf("map.fold").tick), proc (f: FrameInfo): bool =
        f.core.settings.map.foldLayer and f.mapWindow.foldStatus in {fmComputing, fmReady})
      step("counted", noop, proc (f: FrameInfo): bool =
        result = f.mapWindow.foldStatus == fmReady and "max fold" in f.mapWindow.foldLayerLine
        if result:
          let r = f.mapWindow.foldResult
          doAssert ("max fold " & $r.maxFold) in f.mapWindow.foldLayerLine
          doAssert abs(sin(2 * degToRad(r.azimuthDeg))) > 0.5, "the grid is not turned: " &
            $r.azimuthDeg)
      step("popover closed", closePopover, proc (f: FrameInfo): bool =
        wait > 4 and f.markOf("map.fold").size.x == 0)
      step("the popover again", proc (f: FrameInfo) = f.click(f.markOf("map.layers").centre),
        proc (f: FrameInfo): bool =
        result = wait > 3 and f.popoverOpen("map.fold totals"))
      step("the popover seen", noop, proc (f: FrameInfo): bool =
        result = wait > 6
        if result: f.shot("map-fold-popover.png"))
      step("closed again", closePopover, proc (f: FrameInfo): bool =
        wait > 4 and f.markOf("map.fold").size.x == 0)
      step("fitted", proc (f: FrameInfo) = f.click(f.markOf("map.fit").centre),
        proc (f: FrameInfo): bool = wait > 8 and f.mapWindow.foldBlocksDrawn > 0)

      step("the bins are drawn where the grid puts them", noop, proc (f: FrameInfo): bool =
        result = wait > 4 and f.markOf("map.fold legend").size.x > 0
        if result:
          f.shot("map-fold-layer.png")
          let r = f.mapWindow.foldResult[]
          var right, tried = 0
          let stride = max(1, r.counts.len div 60)
          var k = 0
          while k < r.counts.len:
            if r.counts[k] > 0:
              let (x, y) = binCentre(r, k)
              let p = f.screen(x, y)
              let plot = f.mapWindow.mapPlot
              if p.x > plot.pos.x + 4 and p.x < plot.pos.x + plot.size.x - 4 and
                  p.y > plot.pos.y + 4 and p.y < plot.pos.y + plot.size.y - 4:
                inc tried
                let want = legendColour(float64(r.counts[k]) / float64(r.maxFold))
                if near(f.readPixel(int(round(p.x)), int(round(p.y))), want, 8): inc right
            k += stride
          doAssert tried >= 20, "too few bins on the screen to probe: " & $tried
          doAssert right * 10 >= tried * 6, # (stations are drawn over some bin centres)
            "the colour at the centre of the bins: " & $right & " of " & $tried & " right"
          # a bin of no fold, inside the grid, is the background's
          var empty = -1
          for q in 0 ..< r.counts.len:
            if r.counts[q] == 0 and empty < 0:
              let (x, y) = binCentre(r, q)
              let p = f.screen(x, y)
              let plot = f.mapWindow.mapPlot
              if p.x > plot.pos.x + 4 and p.x < plot.pos.x + plot.size.x - 4 and
                  p.y > plot.pos.y + 4 and p.y < plot.pos.y + plot.size.y - 4: empty = q
          if empty >= 0:
            let (x, y) = binCentre(r, empty)
            let p = f.screen(x, y)
            doAssert near(f.readPixel(int(round(p.x)), int(round(p.y))), ink.background, 4),
              "a bin of no fold was drawn")

      var hoverBin = 0
      proc hoverAct(f: FrameInfo) =
        let r = f.mapWindow.foldResult[]
        for q in 0 ..< r.counts.len:
          if r.counts[q] == r.maxFold:
            hoverBin = q
            break
        let (x, y) = binCentre(r, hoverBin)
        f.moveMouse(f.screen(x, y))
      proc hoverDone(f: FrameInfo): bool =
        let want = f.mapWindow.foldResult[].foldText(hoverBin)
        result = want in f.mapWindow.pointTexts
        if wait > 20 and not result:
          doAssert false, "the hover names the bin: wanted " & want & ", got " &
            $f.mapWindow.pointTexts
        if result: f.shot("map-fold-hover.png")
      step("hover", hoverAct, hoverDone)

      proc typeAct(f: FrameInfo) =
        var s = f.core.settings
        s.map.foldAlong = 40
        s.map.foldAcross = 40
        f.apply Command(kind: ckSettings, settings: s)
      proc typeDone(f: FrameInfo): bool =
        let r = f.mapWindow.foldResult
        result = f.mapWindow.foldStatus == fmReady and not r.isNil and abs(r.binAlong - 40) < 1e-6
        if result: doAssert abs(r.binAcross - 40) < 1e-6
      step("a bin size typed", typeAct, typeDone)

      runStages(fx, config, @[sFile, rFile], steps)

    block restart:
      var steps: seq[Step]
      steps.add Step(name: "the setting came back", act: proc (f: FrameInfo) = discard,
        done: proc (f: FrameInfo): bool =
        let m = f.core.settings.map
        doAssert m.foldLayer and m.foldAlong == 40 and m.foldAcross == 40,
          "the setting did not survive the restart"
        let r = f.mapWindow.foldResult
        result = f.mapWindow.foldStatus == fmReady and not r.isNil
        if result: doAssert abs(r.binAlong - 40) < 1e-6)
      runStages(fx, config, @[sFile, rFile, xFile], steps)

when isMainModule:
  main()
