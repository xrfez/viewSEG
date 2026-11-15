## Linked highlighting in the running frontend, headless, driven by SDL
## events as the user's mouse and keyboard send them: the plot and the map
## light each other up, and both are checked in their pixels.
##
## On the SEG-Y survey (coordinates in its headers, its own positions drawn
## as rings), in the file's order and sorted by channel descending:
##
## - the pointer on a receiver on the map: its trace is drawn in the hover
##   colour in the plot, and its neighbours are not; the whole plot image
##   is what the CPU reference draws with that trace lit;
## - the pointer on a trace in the plot: its receiver on the map is in the
##   hover colour, and the neighbouring receivers are not;
## - neither reads a tile, asks for a view, makes or uploads a layer again;
## - the record on show's source is marked on the map, the others not; a
##   click on another source shows its record (and the mark moves); a click
##   on a receiver selects its traces; `M` over a trace in the plot selects
##   its receiver on the map; Esc clears.
##
## On a record whose headers name stations but give no coordinates, with
## the survey's S and R files (the map zoomed in a little): the same both
## ways through the stations, in
## a panel sorted by point too; a receiver no trace was recorded at, and a
## trace no survey file has a station for, light nothing up and the status
## bar says why; Shift + click selects the stations along a line.
##
## A hover in the plot draws the stripes of the two traces it changes, not
## the whole image (Morgantown in wiggles: about 40 ms a hover on software
## OpenGL before), and the image is the reference's after it. Seen to fail:
## with every hover drawing the whole image, "to the next trace" found every
## column drawn; with stripes a fifth of a trace wide, 750 pixels differed
## from the reference there (and `tguiwiggle`'s hover failed too).
##
## Seen to fail: with the plot's marks not following the map's hover
## (`hoveredRevision` left out of `sync`), "the map lights up channel 5" did
## not happen (the trace never drawn lit); with the wiggle shader ignoring
## the mark's lit bit, the same; with the map sending no `ckHoverPoints`,
## "to receiver 5" did not happen; with the gather's points left out of the
## highlight, "the record on show is marked" found 3 pixels of the source's
## colour round it.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves link-*.png there, and with the example
## files present the Morgantown screenshots and frame times.

import std/[algorithm, math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/[maplayers, plotink]
import utils/[fixtures, plotref]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func same(a, b: Rgba; tol = 2): bool =
  abs(int(a.r) - int(b.r)) <= tol and abs(int(a.g) - int(b.g)) <= tol and
    abs(int(a.b) - int(b.b)) <= tol

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc chord(f: FrameInfo; key: SimKey; mods: set[SimMod] = {}) =
  const modKeys: array[SimMod, SimKey] = [skCtrl, skShift, skAlt]
  var held: set[SimMod]
  for m in mods:
    held.incl m
    f.pressKey(modKeys[m], true, held)
  f.pressKey(key, true, held)
  f.pressKey(key, false, held)
  for m in mods:
    held.excl m
    f.pressKey(modKeys[m], false, held)

proc onMap(f: FrameInfo; x, y: float64): Vec2 =
  ## Where survey point (`x`, `y`) is drawn now, framebuffer pixels, rounded
  ## as SDL puts the pointer.
  let p = f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, mapPoint(x, y))
  vec2(round(p.x), round(p.y))

proc mapPixel(f: FrameInfo; x, y: float64): Rgba =
  let p = f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, mapPoint(x, y))
  f.readPixel(int(floor(p.x)), int(floor(p.y)))

proc marked(f: FrameInfo; x, y: float64): int =
  ## The pixels within 3 pixels of source (`x`, `y`) on the map in the
  ## sources' colour: the disc the map marks the record's source with fills
  ## them, the ring of an open file's other sources leaves them empty.
  let ink = mapInk(f.theme, pcPaper)
  let p = f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, mapPoint(x, y))
  for dy in -3 .. 3:
    for dx in -3 .. 3:
      if dx * dx + dy * dy <= 9 and
          same(f.readPixel(int(floor(p.x)) + dx, int(floor(p.y)) + dy), ink.roles[prSource], 40):
        inc result

proc inPlot(f: FrameInfo; position: int): Vec2 =
  ## The pointer over `position`'s baseline, half way down the plot.
  let r = f.markOf("plot.data")
  let v = f.tracePanel.drawnView
  vec2(round(r.pos.x + float32((float64(position) - v.traces.lo) / v.traces.width) *
    r.size.x), round(r.pos.y + r.size.y / 2))

proc litRows(f: FrameInfo; position: int; halfWidth = 0.15): int =
  ## The rows of the plot image with a pixel in the hover colour within
  ## `halfWidth` trace spacings of `position`'s baseline.
  let (img, w, h) = f.tracePanel.plotImage
  let v = f.tracePanel.drawnView
  let hover = plotInk(f.theme, f.panel.layers[0].display).wiggle.hover
  let ppt = float64(w) / v.traces.width
  let c = (float64(position) - v.traces.lo) * ppt
  for j in 0 ..< h:
    var found = false
    for i in max(0, int(c - halfWidth * ppt - 1)) .. min(w - 1, int(c + halfWidth * ppt + 1)):
      if distance(img[j * w + i], hover) <= 30: found = true
    if found: inc result

proc litAnywhere(f: FrameInfo): int =
  ## The pixels of the plot image in the hover colour.
  let (img, _, _) = f.tracePanel.plotImage
  let hover = plotInk(f.theme, f.panel.layers[0].display).wiggle.hover
  for c in img:
    if distance(c, hover) <= 30: inc result

proc positionOf(f: FrameInfo; trace: int): int =
  ## The position of trace `trace` (its index in the file) in the order shown.
  f.panel.shown.find(trace)

proc lights(f: FrameInfo; position: int; what: string) =
  ## Trace `position` is drawn in the hover colour, its neighbours are not,
  ## and the image is the CPU reference's.
  let (_, _, h) = f.tracePanel.plotImage
  let on = f.litRows(position)
  doAssert on > h div 2, what & ": the trace at " & $position & " is lit on " & $on & " of " &
    $h & " rows"
  for n in [position - 1, position + 1]:
    if n in 0 ..< f.panel.layout.traces:
      let off = f.litRows(n)
      doAssert off < h div 8, what & ": its neighbour at " & $n & " is lit on " & $off & " rows"
  let (bad, looked) = f.capture.mismatches(step = 3)
  doAssert bad == 0, what & ": " & $bad & " of " & $looked & " pixels differ from the reference"

type Counts = tuple[taken, gen, survey, layers, uploads: int]

proc counts(f: FrameInfo): Counts =
  (f.core.tilesTaken, int(f.panel.requestGen), f.core.survey.revision,
    f.mapWindow.mapLayersUploaded, f.tracePanel.tilesUploaded)

proc drive(steps: seq[Step]; paths: seq[string]; dir: string) =
  ## Runs the program on `paths` and goes through `steps`, each until its
  ## `done` holds (300 frames at most).
  var at = 0
  var started = false
  var wait = 0
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
    else:
      inc wait
      if wait >= 3 and steps[at].done(f):
        inc at
        started = false
      elif wait > 300:
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(maxFrames: 8000, openPaths: paths, windowSize: (1600, 1000),
    theme: forceDark, userThemeDir: some(dir / "no-user-themes"),
    indexCacheDir: some(dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

let shots = getEnv("VIEWSEG_SCREENSHOTS")

proc shot(f: FrameInfo; name: string) =
  if shots.len > 0:
    createDir(shots)
    discard f.savePng(shots / name)

proc fromTheHeaders() =
  withFixtures fx:
    let path = fx.surveySegy()
    var steps: seq[Step]
    var before: Counts
    var ink: MapInk
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc hoverMap(name: string; channel: int) =
      ## The pointer on the file's own receiver of `channel` on the map.
      step("to receiver " & $channel, proc (f: FrameInfo) =
        f.moveMouse(f.onMap(rcvX(channel), OriginY)), proc (f: FrameInfo): bool =
        f.core.selection.hoverTraces.len == Shots)
      step(name, noop, proc (f: FrameInfo): bool =
        result = f.tracePanel.imagesDrawn > 0 and f.litRows(f.positionOf(channel - 1)) > 0
        if result: f.lights(f.positionOf(channel - 1), name))
    proc hoverPlot(name: string; channel: int) =
      ## The pointer on the trace of `channel` in the plot: its receiver lit.
      step(name, proc (f: FrameInfo) = f.moveMouse(f.inPlot(f.positionOf(channel - 1))),
        proc (f: FrameInfo): bool =
        result = f.core.selection.hover == channel - 1 and
          same(f.mapPixel(rcvX(channel), OriginY), ink.hover)
        if result:
          for n in [channel - 1, channel + 1]:
            doAssert not same(f.mapPixel(rcvX(n), OriginY), ink.hover),
              name & ": receiver " & $n & " is lit too")

    step("loaded", noop, proc (f: FrameInfo): bool =
      result = f.core.survey.layers.len == 1 and f.panel.laidOut and
        f.core.tiles(f.core.findPanel(MainPanel)).len > 0 and f.mapWindow.mapShown.isSet and
        f.mapWindow.mapImagesDrawn > 0 and f.panel.shown.len == Channels
      if result:
        ink = mapInk(f.theme, pcPaper)
        f.moveMouse(vec2(4, 4)))
    step("the record on show is marked", noop, proc (f: FrameInfo): bool =
      result = f.mapWindow.activeMarked[prSource].len == 1
      if result:
        f.shot("link-marked.png")
        let n = f.marked(srcX(0), OriginY)
        doAssert n > 20, "the record's source is not marked: " & $n
        doAssert f.marked(srcX(1), OriginY) < 8, "another record's source is marked"
        before = f.counts)
    hoverMap("the map lights up channel 5", 5)
    step("shot", noop, proc (f: FrameInfo): bool =
      f.shot("link-map-to-plot.png")
      true)
    hoverPlot("the plot lights up receiver 10", 10)
    var drawn = 0
    step("to the next trace: its stripes drawn again", proc (f: FrameInfo) =
      drawn = f.tracePanel.imagesDrawn
      f.moveMouse(f.inPlot(f.positionOf(10))), proc (f: FrameInfo): bool =
      result = f.core.selection.hover == 10 and f.tracePanel.imagesDrawn > drawn
      if result:
        let columns = f.tracePanel.drawnView.columns
        doAssert f.tracePanel.columnsDrawn < columns div 4, "a hover drew " &
          $f.tracePanel.columnsDrawn & " of the plot's " & $columns & " columns again"
        let (bad, looked) = f.capture.mismatches(step = 1)
        doAssert bad == 0, "after a hover: " & $bad & " of " & $looked & " pixels differ from " &
          "the reference")
    step("nothing read", noop, proc (f: FrameInfo): bool =
      f.shot("link-plot-to-map.png")
      doAssert f.counts == before, "a hover read or rebuilt something: " & $before & " to " &
        $f.counts
      true)
    step("sorted by channel, descending", proc (f: FrameInfo) =
      f.moveMouse(vec2(4, 4))
      f.apply(Command(kind: ckSort, panel: MainPanel,
        order: @[SortKey(field: hfChannel, descending: true)])), proc (f: FrameInfo): bool =
      f.panel.shown.len == Channels and f.panel.shown[0] == Channels - 1 and
        not f.core.sorting(f.core.findPanel(MainPanel)) and f.core.selection.hover < 0)
    hoverMap("sorted: the map lights up channel 5", 5)
    hoverPlot("sorted: the plot lights up receiver 22", 22)
    step("a focusing click on the map", proc (f: FrameInfo) =
      let p = f.onMap(srcX(2), OriginY)
      f.moveMouse(vec2(p.x, p.y - 60)) # above the line: no point
      f.pressMouse(vec2(p.x, p.y - 60), true)
      f.pressMouse(vec2(p.x, p.y - 60), false), proc (f: FrameInfo): bool =
      f.core.selection.hoverPoints.len == 0)
    step("a click on a source shows its record", proc (f: FrameInfo) =
      let p = f.onMap(srcX(2), OriginY)
      f.moveMouse(p), proc (f: FrameInfo): bool =
      let p = f.onMap(srcX(2), OriginY)
      if f.core.selection.hoverPoints.len > 0 and f.panel.layers[0].source.gather == 0:
        f.pressMouse(p, true)
        f.pressMouse(p, false)
      result = f.panel.layers[0].source.gather == 2 and f.panel.laidOut and
        f.mapWindow.activeMarked[prSource].len == 1
      if result:
        doAssert f.core.selection.selected.len == 0, "showing a record selected its traces")
    step("the mark moves", proc (f: FrameInfo) = f.moveMouse(vec2(4, 4)),
      proc (f: FrameInfo): bool =
      result = f.core.selection.hoverPoints.len == 0 and f.marked(srcX(2), OriginY) > 20
      if result:
        doAssert f.marked(srcX(0), OriginY) < 8, "the record before is still marked")
    step("a click on a receiver selects its traces", proc (f: FrameInfo) =
      f.moveMouse(f.onMap(rcvX(7), OriginY)), proc (f: FrameInfo): bool =
      if f.core.selection.hoverPoints.len > 0 and f.core.selection.selected.len == 0:
        let p = f.onMap(rcvX(7), OriginY)
        f.pressMouse(p, true)
        f.pressMouse(p, false)
      result = f.core.selection.selected.len == Shots
      if result:
        for s in 0 ..< Shots: doAssert s * Channels + 6 in f.core.selection.selected)
    step("a focusing click on the plot", proc (f: FrameInfo) =
      # record 3's channel 12
      let p = f.inPlot(f.positionOf(2 * Channels + 11))
      f.moveMouse(p)
      f.pressMouse(p, true)
      f.pressMouse(p, false), proc (f: FrameInfo): bool =
      f.core.selection.hover >= 0)
    step("M selects the trace's receiver", proc (f: FrameInfo) = f.chord(skM),
      proc (f: FrameInfo): bool =
      result = f.core.selection.points.len == 1
      if result:
        let p = f.core.selection.points[0]
        doAssert p.role == prReceiver and abs(f.core.positionOf(p).x - rcvX(12)) < 1e-6
        doAssert f.core.selection.selected.len == Shots and
          2 * Channels + 11 in f.core.selection.selected)
    step("Esc clears", proc (f: FrameInfo) = f.chord(skEscape), proc (f: FrameInfo): bool =
      f.core.selection.points.len == 0 and f.core.selection.selected.len == 0)
    drive(steps, @[path], fx.dir)
    echo "tguilink: the file's own positions, ", steps.len, " steps"

proc byStation() =
  withFixtures fx:
    let path = fx.stationsSegd()
    let sps = fx.surveySps()
    var steps: seq[Step]
    var ink: MapInk
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc hoverMap(name: string; point: int) =
      ## The pointer on the R file's receiver of line 100, `point`: the trace
      ## of that station (trace `point - 100`) lit.
      step("to receiver " & $point, proc (f: FrameInfo) =
        f.moveMouse(f.onMap(rcvX(point - 100), OriginY)), proc (f: FrameInfo): bool =
        f.core.selection.hoverTraces.len == 1)
      step(name, noop, proc (f: FrameInfo): bool =
        let position = f.positionOf(point - 100)
        result = f.litRows(position) > 0
        if result: f.lights(position, name))

    step("loaded", noop, proc (f: FrameInfo): bool =
      result = f.core.survey.layers.len == 3 and f.panel.laidOut and
        f.core.tiles(f.core.findPanel(MainPanel)).len > 0 and f.mapWindow.mapShown.isSet and
        f.mapWindow.mapImagesDrawn > 0 and f.panel.shown.len == 2 * SegdChannels
      if result: ink = mapInk(f.theme, pcPaper))
    var fit: float64
    step("the map zoomed in", proc (f: FrameInfo) =
      # receivers 104 to 115 in view, the source 8 pixels from its neighbours
      fit = f.mapWindow.mapShown.perPixel
      let p = f.onMap(OriginX + 212.5, OriginY)
      f.moveMouse(p)
      f.scrollWheel(p, 2), proc (f: FrameInfo): bool =
      result = f.mapWindow.mapShown.perPixel < fit * 0.7
      if result:
        let v = f.mapWindow.mapShown.visible
        doAssert v.minX < rcvX(4) and v.maxX > rcvX(15), $v)
    hoverMap("receiver 107 lights up its trace", 107)
    step("receiver 115 has no trace", proc (f: FrameInfo) =
      f.moveMouse(f.onMap(rcvX(15), OriginY)), proc (f: FrameInfo): bool =
      result = f.core.selection.hoverPoints.len > 0 and f.markOf("status.link").size.x > 0
      if result:
        doAssert f.core.hoverNote == "No trace of the open files was recorded at this receiver.",
          f.core.hoverNote
        doAssert f.litAnywhere == 0, "a trace is lit")
    step("trace 5 lights up receiver 105", proc (f: FrameInfo) =
      f.moveMouse(f.inPlot(f.positionOf(5))), proc (f: FrameInfo): bool =
      result = f.core.selection.hover == 5 and same(f.mapPixel(rcvX(5), OriginY), ink.hover)
      if result:
        for n in [4, 6]:
          doAssert not same(f.mapPixel(rcvX(n), OriginY), ink.hover), "receiver " & $n & " is lit"
        doAssert same(f.mapPixel(srcX(0), OriginY), ink.hover), "its source is not lit"
        f.shot("link-by-station.png"))
    step("a trace of line 101 is not on the map", proc (f: FrameInfo) =
      f.moveMouse(f.inPlot(f.positionOf(17))), proc (f: FrameInfo): bool =
      result = f.core.selection.hover == 17 and f.markOf("status.link").size.x > 0
      if result:
        doAssert f.core.hoverNote == "Trace 18's receiver is not on the map: no loaded survey " &
          "file has its receiver station (line 101, point 105).", f.core.hoverNote
        doAssert not same(f.mapPixel(rcvX(5), OriginY), ink.hover))
    step("a focusing click on the map", proc (f: FrameInfo) =
      let p = f.onMap(rcvX(4), OriginY)
      f.moveMouse(vec2(p.x, p.y - 60))
      f.pressMouse(vec2(p.x, p.y - 60), true)
      f.pressMouse(vec2(p.x, p.y - 60), false), proc (f: FrameInfo): bool =
      f.core.selection.hoverPoints.len == 0 and f.core.selection.hover < 0)
    step("a click on receiver 104", proc (f: FrameInfo) =
      f.moveMouse(f.onMap(rcvX(4), OriginY)), proc (f: FrameInfo): bool =
      if f.core.selection.hoverPoints.len > 0 and f.core.selection.points.len == 0:
        let p = f.onMap(rcvX(4), OriginY)
        f.pressMouse(p, true)
        f.pressMouse(p, false)
      f.core.selection.points.len == 1 and f.core.selection.selected.len == 1)
    step("Shift + click on receiver 108: the stations between", proc (f: FrameInfo) =
      f.moveMouse(f.onMap(rcvX(8), OriginY)), proc (f: FrameInfo): bool =
      if f.core.selection.hoverPoints.len > 0 and f.core.selection.points.len == 1 and
          f.core.selection.hoverTraces.len == 1 and 8 in f.core.selection.hoverTraces:
        let p = f.onMap(rcvX(8), OriginY)
        f.pressKey(skShift, true, {smShift})
        f.pressMouse(p, true)
        f.pressMouse(p, false)
        f.pressKey(skShift, false)
      result = f.core.selection.points.len == 5
      if result:
        var traces: seq[int]
        for t in f.core.selection.selected: traces.add t
        doAssert traces.sorted == @[4, 5, 6, 7, 8], $traces)
    step("Esc clears", proc (f: FrameInfo) = f.chord(skEscape), proc (f: FrameInfo): bool =
      f.core.selection.points.len == 0)
    step("sorted by point, descending", proc (f: FrameInfo) =
      f.moveMouse(vec2(4, 4))
      f.apply(Command(kind: ckSort, panel: MainPanel,
        order: @[SortKey(field: hfRcvPoint, descending: true)])), proc (f: FrameInfo): bool =
      f.panel.shown.len == 2 * SegdChannels and f.panel.shown[0] == SegdChannels and
        not f.core.sorting(f.core.findPanel(MainPanel)))
    hoverMap("sorted: receiver 109 lights up its trace", 109)
    step("sorted: trace 11 lights up receiver 111", proc (f: FrameInfo) =
      f.moveMouse(f.inPlot(f.positionOf(11))), proc (f: FrameInfo): bool =
      result = f.core.selection.hover == 11 and same(f.mapPixel(rcvX(11), OriginY), ink.hover)
      if result:
        for n in [10, 12]:
          doAssert not same(f.mapPixel(rcvX(n), OriginY), ink.hover), "receiver " & $n & " is lit")
    drive(steps, @[path, sps.s, sps.r], fx.dir)
    echo "tguilink: stations matched to the survey files, ", steps.len, " steps"

fromTheHeaders()
byStation()

# ------------------------------------------- Morgantown: screenshots, times --
# With `VIEWSEG_SCREENSHOTS=<dir>` and the example files present (local
# only), the Morgantown record with its S, R and X files, in the "Plot and
# map" layout: the pointer on a trace in the plot (its source and receiver
# lit on the map, the record's spread marked), then on a receiver on the map
# (its trace lit in the plot); and the frame times while the pointer sweeps
# over each (printed, for the record).

const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

func median(xs: seq[float64]): float64 =
  let s = xs.sorted
  if s.len == 0: NaN else: s[s.len div 2]

func ms(x: float64): string = formatFloat(x, ffDecimal, 1)

proc morgantown(dir: string) =
  let base = examples / "sps" / "PGI_NNE_West_Morgantown_3D_Post261019_NAD27_SPCS_WV_N_USFeet"
  let record = examples / "00000151_12900_11300.sgd"
  let preset = currentSourcePath().parentDir.parentDir / "assets" / "layouts" / "Plot and map.nif"
  var stage = 0
  var wait = 0
  var saved = 0
  var loads = 0
  var last = getMonoTime()
  var idle, overPlot, overMap: seq[float64]
  var a, b: Vec2
  var rcv = mapPoint(NaN, NaN)
  proc onFrame(f: FrameInfo) =
    let now = getMonoTime()
    let frame = float64((now - last).inMicroseconds) / 1000
    last = now
    inc wait
    let k = f.core.findPanel(MainPanel)
    case stage
    of 0:
      if f.index == 2:
        loads = f.core.layoutLoads
        f.apply Command(kind: ckLoadLayout, docPath: preset)
      if f.core.survey.layers.len >= 4 and f.core.panels[k].laidOut and
          f.core.tiles(k).len > 0 and f.core.layoutLoads > loads and wait > 30 and
          f.mapWindow.mapShown.isSet and f.mapWindow.activeMarked[prReceiver].len > 0:
        let plot = f.markOf("plot.data")
        a = vec2(round(plot.pos.x + plot.size.x * 0.1), round(plot.pos.y + plot.size.y * 0.4))
        b = vec2(round(plot.pos.x + plot.size.x * 0.9), round(plot.pos.y + plot.size.y * 0.4))
        (stage, wait) = (1, 0)
    of 1: # idle frames, then the pointer across the plot, a few pixels a frame
      if wait in 5 ..< 35: idle.add frame
      if wait >= 35 and wait < 155:
        if wait > 36: overPlot.add frame
        let s = float32(wait - 35) / 120
        f.moveMouse(vec2(round(a.x + (b.x - a.x) * s), a.y))
      if wait == 120 and shots.len > 0: # the pointer on a trace: its points lit
        discard
      if wait == 160:
        let plot = f.markOf("plot.data")
        f.moveMouse(vec2(round(plot.pos.x + plot.size.x * 0.62), round(plot.pos.y +
          plot.size.y * 0.4)))
      if wait == 185:
        if f.core.selection.hoverAt.len > 0 and f.savePng(dir / "link-morgantown-1.png"):
          inc saved
        for p in f.core.selection.hoverAt:
          if p.role == prReceiver: rcv = f.core.positionOf(p)
        let m = f.markOf("map.data")
        a = vec2(round(m.pos.x + m.size.x * 0.15), round(m.pos.y + m.size.y * 0.5))
        b = vec2(round(m.pos.x + m.size.x * 0.85), round(m.pos.y + m.size.y * 0.5))
        (stage, wait) = (2, 0)
    of 2: # the pointer across the map, over its points
      if wait < 120:
        if wait > 1: overMap.add frame
        let s = float32(wait) / 120
        f.moveMouse(vec2(round(a.x + (b.x - a.x) * s), round(a.y + (b.y - a.y) * s * 0.3)))
      if wait == 125 and not rcv.x.isNaN: # a receiver of the record, near the source
        let p = f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, rcv)
        f.moveMouse(vec2(round(p.x), round(p.y)))
      if wait == 150:
        if f.core.selection.hoverTraces.len > 0 and f.savePng(dir / "link-morgantown-2.png"):
          inc saved
        echo "tguilink: Morgantown: the map's pointer on ", f.mapWindow.pointTexts.join(" | "),
          "; ", f.core.selection.hoverTraces.len, " traces lit"
        f.stop()
    else: discard
    if f.index > 8000: f.stop()
  let tmp = getTempDir() / ("viewseg-linkshots-" & $getCurrentProcessId())
  let code = run(RunOptions(maxFrames: 9000, openPaths: @[record, base & ".sps", base & ".rps",
    base & ".xps"], windowSize: (1600, 1000), theme: forceDark, indexCacheDir: some(tmp),
    userThemeDir: some(tmp / "no-user-themes"), onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0 and saved == 2, "no screenshots of Morgantown (stage " & $stage & ")"
  echo "tguilink: Morgantown frames: idle ", ms(median(idle)), " ms; pointer over the plot ",
    ms(median(overPlot)), " ms median (slowest ", ms(max(overPlot)), "); over the map ",
    ms(median(overMap)), " ms median (slowest ", ms(max(overMap)), "); saved ",
    dir / "link-morgantown-1.png", " and -2.png"

if shots.len > 0 and fileExists(examples / "00000151_12900_11300.sgd"):
  createDir(shots)
  morgantown(shots)
