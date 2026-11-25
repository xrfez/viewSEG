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
## - "Actual fold" counts the shot files of the Files window's folder (one file for each
##   shot of the survey, positions in their headers): ticking it unticks the other layers,
##   the bins have the Viridis colour of the recorded fold, the legend is titled "Actual
##   fold", and the hover says "recorded N (planned M)". With one shot file taken out of the
##   folder, "Fold difference" draws the diverging colours (short bins blue, 0 white), the
##   legend is titled "Fold difference (planned − recorded)", and the hover says "N short of
##   the plan"; ticking the pre-plot fold unticks it.
## - A bin size typed in the popover is saved, and a restart brings the layer
##   back with it, counting again with that bin.
##
## Seen to fail: with the bins' inline axis mirrored in the shader (`vAxis` negated),
## "the colour at the centre of the bins" found 8 of 64 bins right; with the hover
## bin looked up on the unrotated grid, "the hover names the bin" found another bin's fold.
##
## Seen to fail (the layers): with a tick leaving the other fold layers on, "Actual fold
## ticked did not happen".
##
## Needs a display: run under `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves map-fold-*.png there.

import std/[math, monotimes, options, os, strformat, strutils, tables]
import parseSEG
import viewSEG/core/[colourmaps, foldgrid, foldjobs, geometry, state]
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

type Spot = tuple[x, y: float64]

proc spots(path: string; role: char): Table[(int, int), Spot] =
  ## The stations of an SPS S or R file, by line and point (columns as `rotated` reads them).
  for line in lines(path):
    if line.len >= 65 and line[0] == role:
      result[(int(parseFloat(line[1 .. 10].strip)), int(parseFloat(line[11 .. 20].strip)))] =
        (parseFloat(line[46 .. 54].strip), parseFloat(line[55 .. 64].strip))

proc shotFile(path: string; shot: int; sources, receivers: Table[(int, int), Spot]) =
  ## Shot `shot` (1 to 6) of the sample: a trace for each of its 96 receivers, the stations
  ## and positions in the headers.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 2))
  var ch = 0
  for line in [1001, 1002]:
    for point in 101 .. 148:
      inc ch
      var k = initTraceKeys()
      k.record = float64(shot)
      k.channel = float64(ch)
      (k.srcLine, k.srcPoint, k.srcIndex) = (2001.0, float64(100 + shot), 1'i16)
      (k.rcvLine, k.rcvPoint, k.rcvIndex) = (float64(line), float64(point), 1'i16)
      let (s, r) = (sources[(2001, 100 + shot)], receivers[(line, point)])
      (k.srcX, k.srcY, k.rcvX, k.rcvY) = (s.x, s.y, r.x, r.y)
      (k.intervalUs, k.status) = (2000.0, tsLive)
      w.writeTrace(k, @[0'f32, 0, 0, 0])
  doAssert w.close().len == 0, "shot file was not written: " & path

func unpack(c: uint32): Rgba =
  Rgba(r: uint8(c and 255), g: uint8((c shr 8) and 255), b: uint8((c shr 16) and 255),
    a: uint8(c shr 24))

proc probe(f: FrameInfo; r: FoldResult; bins: seq[int];
    want: proc (bin: int): Rgba): tuple[tried, right: int] =
  ## How many of a sample of `bins` that are on the screen have the colour `want(bin)` at
  ## their centre.
  let plot = f.mapWindow.mapPlot
  let stride = max(1, bins.len div 60)
  var k = 0
  while k < bins.len:
    let (x, y) = binCentre(r, bins[k])
    let p = f.screen(x, y)
    if p.x > plot.pos.x + 4 and p.x < plot.pos.x + plot.size.x - 4 and
        p.y > plot.pos.y + 4 and p.y < plot.pos.y + plot.size.y - 4:
      inc result.tried
      if near(f.readPixel(int(round(p.x)), int(round(p.y))), want(bins[k]), 8): inc result.right
    k += stride

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
    let (sources, receivers) = (spots(sFile, 'S'), spots(rFile, 'R'))
    for shot in 1 .. 6: shotFile(fx.dir / ("shot" & $shot & ".sgy"), shot, sources, receivers)

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

      # ---- the recorded fold and the difference
      proc hovered(f: FrameInfo; want: string): bool =
        for t in f.mapWindow.pointTexts:
          if want in t: return true
      proc seismicListed(f: FrameInfo): int =
        for e in f.core.fileList.entries:
          if e.kind in {fkSegy, fkSegd, fkSeg2}: inc result
      proc browse(f: FrameInfo) = f.apply Command(kind: ckBrowse, paths: @[fx.dir])
      proc openLayers(f: FrameInfo) = f.click(f.markOf("map.layers").centre)
      step("the shot files listed", browse, proc (f: FrameInfo): bool =
        f.seismicListed == 6 and not f.core.fileList.scanning)
      step("the popover for the layers", openLayers, proc (f: FrameInfo): bool =
        f.popoverOpen("map.fold actual"))
      proc tickActual(f: FrameInfo) = f.click(f.markOf("map.fold actual").tick)
      proc actualCounted(f: FrameInfo): bool =
        let m = f.core.settings.map
        result = m.foldActual and not m.foldLayer and not m.foldDifference and
          f.mapWindow.foldStatus == fmReady and f.mapWindow.foldResult.kind == fkActual
        if result:
          doAssert "max fold" in f.mapWindow.foldLayerLine(fkActual),
            f.mapWindow.foldLayerLine(fkActual)
          let r = f.mapWindow.foldResult
          doAssert r.files == 6 and r.traces == 576 and r.binned == 576 and r.unplaced == 0,
            "the shots were not all counted: " & $(r.files, r.traces, r.binned, r.unplaced)
      step("Actual fold ticked", tickActual, actualCounted)
      step("the popover closed", closePopover, proc (f: FrameInfo): bool =
        wait > 4 and f.markOf("map.fold").size.x == 0)
      proc actualDrawn(f: FrameInfo): bool =
        result = wait > 6 and f.markOf("map.fold legend").size.x > 0 and
          f.mapWindow.foldLegendTitle == "Actual fold" and f.mapWindow.foldBlocksDrawn > 0
        if result:
          f.shot("map-fold-actual.png")
          let r = f.mapWindow.foldResult[]
          var bins: seq[int] = @[]
          for k in 0 ..< r.counts.len:
            if r.counts[k] > 0: bins.add k
          let (tried, right) = f.probe(r, bins, proc (k: int): Rgba =
            legendColour(float64(r.counts[k]) / float64(r.maxFold)))
          doAssert tried >= 20, "too few bins on the screen to probe: " & $tried
          doAssert right * 10 >= tried * 6, "the recorded fold's colours: " & $right & " of " &
            $tried & " right"
      step("the recorded fold is drawn", noop, actualDrawn)
      var actualBin = 0
      proc hoverActual(f: FrameInfo) =
        let r = f.mapWindow.foldResult[]
        for q in 0 ..< r.counts.len:
          if r.counts[q] == r.maxFold:
            actualBin = q
            break
        let (x, y) = binCentre(r, actualBin)
        f.moveMouse(f.screen(x, y))
      proc actualHovered(f: FrameInfo): bool =
        let r = f.mapWindow.foldResult[]
        let want = "recorded " & $r.counts[actualBin] & " (planned " & $r.planned[actualBin] & ")"
        result = f.hovered(want)
        if wait > 20 and not result:
          doAssert false, "the hover says what was recorded: wanted " & want & ", got " &
            $f.mapWindow.pointTexts
      step("hover on the recorded fold", hoverActual, actualHovered)
      proc takeOut(f: FrameInfo) =
        removeFile fx.dir / "shot3.sgy"
        f.browse
      step("a shot file taken out", takeOut, proc (f: FrameInfo): bool =
        f.seismicListed == 5 and not f.core.fileList.scanning)
      step("the popover for the difference", openLayers, proc (f: FrameInfo): bool =
        f.popoverOpen("map.fold difference"))
      proc tickDifference(f: FrameInfo) = f.click(f.markOf("map.fold difference").tick)
      proc differenceCounted(f: FrameInfo): bool =
        let m = f.core.settings.map
        result = m.foldDifference and not m.foldLayer and not m.foldActual and
          f.mapWindow.foldStatus == fmReady and f.mapWindow.foldResult.kind == fkDifference and
          f.mapWindow.foldResult.files == 5
        if result:
          doAssert "largest" in f.mapWindow.foldLayerLine(fkDifference),
            f.mapWindow.foldLayerLine(fkDifference)
      step("Fold difference ticked", tickDifference, differenceCounted)
      step("the popover closed again", closePopover, proc (f: FrameInfo): bool =
        wait > 4 and f.markOf("map.fold").size.x == 0)
      proc differenceDrawn(f: FrameInfo): bool =
        result = wait > 6 and f.markOf("map.fold legend").size.x > 0 and
          f.mapWindow.foldLegendTitle == "Fold difference (planned − recorded)" and
          f.mapWindow.foldBlocksDrawn > 0
        if result:
          f.shot("map-fold-difference.png")
          let r = f.mapWindow.foldResult[]
          doAssert r.maxFold > 0, "the missing shot left no difference"
          var bins: seq[int] = @[]
          for k in 0 ..< r.counts.len:
            if r.counts[k] != 0 or r.planned[k] != 0: bins.add k
          let lut = lutOf(cmRedWhiteBlue)
          let (tried, right) = f.probe(r, bins, proc (k: int): Rgba =
            unpack(diffColour(lut, r.counts[k], r.maxFold)))
          doAssert tried >= 20, "too few bins on the screen to probe: " & $tried
          doAssert right * 10 >= tried * 6, "the difference's colours: " & $right & " of " &
            $tried & " right"
      step("the difference is drawn", noop, differenceDrawn)
      var diffBin = 0
      proc hoverDifference(f: FrameInfo) =
        let r = f.mapWindow.foldResult[]
        for q in 0 ..< r.counts.len:
          if r.counts[q] == r.maxFold:
            diffBin = q
            break
        let (x, y) = binCentre(r, diffBin)
        f.moveMouse(f.screen(x, y))
      proc differenceHovered(f: FrameInfo): bool =
        let r = f.mapWindow.foldResult[]
        let want = $r.counts[diffBin] & " short of the plan"
        result = f.hovered(want)
        if wait > 20 and not result:
          doAssert false, "the hover says how short: wanted " & want & ", got " &
            $f.mapWindow.pointTexts
      step("hover on the difference", hoverDifference, differenceHovered)
      step("the popover once more", openLayers, proc (f: FrameInfo): bool =
        f.popoverOpen("map.fold"))
      proc tickPreplot(f: FrameInfo) = f.click(f.markOf("map.fold").tick)
      step("Pre-plot fold ticked again", tickPreplot, proc (f: FrameInfo): bool =
        let m = f.core.settings.map
        m.foldLayer and not m.foldActual and not m.foldDifference and
          f.mapWindow.foldStatus == fmReady and f.mapWindow.foldResult.kind == fkPreplot and
          f.mapWindow.foldLegendTitle == "Pre-plot fold")
      step("the popover closed last", closePopover, proc (f: FrameInfo): bool =
        wait > 4 and f.markOf("map.fold").size.x == 0)

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
