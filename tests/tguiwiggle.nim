## Wiggles in the running frontend, headless, on the survey fixture with a
## spike (`pdSpike`: one sample of 100 among values of at most 1):
##
## - each display mode (wiggle with no fill, positive fill, negative fill,
##   both, wiggle over density, density) draws the plot image the CPU
##   reference of `core/wiggle` and `core/tiles` predicts, pixel for pixel;
## - one known trace (channel 12: a plane wave arriving at 181.25 ms) is
##   filled right of its baseline at its peak and left of it at its trough
##   only with the negative fill, and its line swings about one trace
##   spacing at overlap 1;
## - the overlap clip: at overlap 0.5 the spike swings its trace half a
##   trace spacing and not a pixel further;
## - a plot in which nothing changes draws no new image;
## - the gain amount scales the wiggles under every gain type, as the
##   reference says, and reversed polarity swings them the other way, with
##   nothing read again;
## - where traces are closer than four pixels (a 400-trace record in a
##   small window), density is drawn and the strip says so, and
##   zoomed in on the traces, wiggles are drawn and the note goes;
## - the file is never changed.
##
## Seen to fail: with the shader's swing not clipped (`clamp` left out),
## the first look already had 35 pixels off the reference (the spike's
## line); with the fills' sides swapped in the shader, 1496 pixels of the
## positive fill were off; with the renderer drawing every frame,
## `idleDrawsNothing` counted 7 images while nothing changed; with wiggles drawn at any trace
## spacing, `densityTakesOver` found wiggles at 1.24 pixels a trace and no
## note; with the wiggles drawn at the reference's scale, without the gain
## amount and the polarity, `gainAmountUnderEveryType` found 969 pixels off
## under Automatic at +6 dB.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, options, os, times]
import viewSEG/core/[geometry, state, wiggle]
import viewSEG/view/[plotink, theme]
import viewSEG/ui/imgui/app
import utils/fixtures

const
  tolerance = 6     ## per channel: float rounding and 8-bit blending on the GPU
  knownChannel = 12 ## position 11 of shot 0: offset 162.5 m, arrival 181.25 ms
  arrivalMs = 181.25

type
  Shot = object
    ## A plot image and what it was drawn from.
    image: seq[Rgba]
    w, h: int
    view: Viewport
    tiles: seq[Tile]
    display: DisplaySettings
    ink: PlotInk
    style: WiggleStyle
    scale: float32
    density, wiggles: bool
    hover: int
    selection: Selection
    gen: uint64       ## the panel's request generation then
    ids: seq[uint64]  ## its tiles then
    screen: seq[Rgba] ## the whole frame
    width: int        ## the frame's width
    plot: Rect        ## where the plot lies in it

proc capture(f: FrameInfo): Shot =
  let k = f.core.findPanel(MainPanel)
  let p = f.core.panels[k]
  let d = p.layers[0].display
  let (img, w, h) = f.tracePanel.plotImage
  let v = f.tracePanel.drawnView
  let scale = displayScale(p.reference, d.gainDb, d.reversed)
  result = Shot(image: img, w: w, h: h, view: v, display: d, ink: plotInk(f.theme, d),
    style: d.styleFor(v, scale, 1, 2), scale: scale, density: d.drawsDensity(v),
    wiggles: d.drawsWiggles(v), hover: f.core.selection.hover,
    selection: f.core.selection, gen: p.requestGen, screen: f.readFrame, width: f.width,
    plot: f.markOf("plot.data"))
  for t in f.core.tiles(k):
    result.tiles.add t
    result.ids.add t.id

proc at(s: Shot; i, j: int): Rgba = s.image[j * s.w + i]

func xOf(s: Shot; i: int): float64 =
  s.view.traces.lo + (float64(i) + 0.5) / float64(s.w) * s.view.traces.width

func tOf(s: Shot; j: int): float64 =
  s.view.timeMs.lo + (float64(j) + 0.5) / float64(s.h) * s.view.timeMs.width

func column(s: Shot; position: float64): int =
  ## The image column whose centre is nearest to `position`.
  int(round((position - s.view.traces.lo) / s.view.traces.width * float64(s.w) - 0.5))

func row(s: Shot; tMs: float64): int =
  int(floor((tMs - s.view.timeMs.lo) / s.view.timeMs.width * float64(s.h)))

proc expected(s: Shot; i, j: int): Rgba =
  ## What image pixel (`i`, `j`) should show: the tiles oldest first, each
  ## its area (density or the background) then its wiggles, the marked
  ## traces again on top.
  let (x, t) = (s.xOf(i), s.tOf(j))
  result = s.ink.background
  for tile in s.tiles:
    let hover = tile.hoverRow(0, s.hover)
    var selected: seq[bool]
    tile.selectedRowsInto(0, s.selection, selected)
    if tile.contains(x, t):
      result = s.ink.background
      if s.density:
        let c = greyLut().densityColour(tile.amplitudeAt(x, t), s.scale)
        result = if s.wiggles: c
                 else: densityTint(c, markOf(tile.rowAt(x), hover, selected), s.ink.wiggle,
                   DensityTint)
    let (_, ts) = tile.span
    if s.wiggles and t >= ts.lo and t < ts.hi:
      let ser = tile.series
      for pass in 0 .. 1:
        for r in 0 ..< tile.request.count:
          let m = markOf(r, hover, selected)
          let pos = float64(tile.request.position(r))
          if (pass == 0 or m != tmNone) and abs(x - pos) <= s.style.reach:
            let ink = tile.traceInk(ser, r, (x - pos) * s.style.pixelsPerTrace, t, s.style,
              s.ink.wiggle, m)
            result = ink.onto(result)

func close(a, b: Rgba; tol = tolerance): bool = distance(a, b) <= tol

proc mismatches(s: Shot; step = 2): (int, int) =
  ## Image pixels on a grid that differ from `expected`, and the pixels
  ## looked at.
  for j in countup(0, s.h - 1, step):
    for i in countup(0, s.w - 1, step):
      inc result[1]
      let want = s.expected(i, j)
      if not close(s.at(i, j), want):
        if result[0] < 5:
          echo "  pixel (", i, ", ", j, "): ", toHex(s.at(i, j)), ", expected ", toHex(want)
        inc result[0]

proc baselineAt(f: FrameInfo; position: float64; tMs: float64): Vec2 =
  ## Where trace `position`'s baseline is at `tMs` on the screen.
  let r = f.markOf("plot.data")
  let v = f.tracePanel.drawnView
  vec2(round(r.pos.x + float32((position - v.traces.lo) / v.traces.width) * r.size.x),
    round(r.pos.y + float32((tMs - v.timeMs.lo) / v.timeMs.width) * r.size.y))

proc share(s: Shot; position: float64; colour: Rgba; t0, t1: float64; halfWidth = 2): float64 =
  ## The share of image rows from `t0` to `t1` ms with a pixel in `colour`
  ## within `halfWidth` pixels of trace `position`'s baseline.
  let c = s.column(position)
  var hit, rows = 0
  for j in s.row(t0) .. s.row(t1):
    inc rows
    var found = false
    for i in c - halfWidth .. c + halfWidth:
      if i in 0 ..< s.w and close(s.at(i, j), colour, 30): found = true
    if found: inc hit
  hit / max(rows, 1)

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

withFixtures fx:
  let path = fx.surveySegy(pdSpike)
  let before = snapshot(path)
  type Look = tuple[mode: DisplayMode; fills: set[WiggleFill]; overlap: float64]
  const looks: array[7, Look] = [(dmWiggle, {}, 1.0), (dmWiggle, {wfPositive}, 1.0),
    (dmWiggle, {wfNegative}, 1.0), (dmWiggle, {wfPositive, wfNegative}, 1.0),
    (dmWiggleDensity, {wfPositive}, 1.0), (dmDensity, {}, 1.0), (dmWiggle, {wfPositive}, 0.5)]
  var shots: seq[Shot]
  var idle: (int, int)
  type Amount = object
    ## A gain type's wiggles before and after +6.02 dB.
    gain: DisplayGain
    before, after: Shot
  var amounts: seq[Amount]
  var reversed: Shot
  var stage = 0
  var waited = 0
  var drawnBefore = 0
  proc answered(f: FrameInfo): bool =
    let k = f.core.findPanel(MainPanel)
    let p = f.core.panels[k]
    let tiles = f.core.tiles(k)
    p.laidOut and not p.pending.isEmpty and p.pending.gen == p.requestGen and tiles.len > 0 and
      tiles[^1].request == p.pending
  proc show(f: FrameInfo; look: Look) =
    var d = f.core.panels[f.core.findPanel(MainPanel)].layers[0].display
    (d.mode, d.fills, d.overlap) = look
    d.gain = dgNone # the samples as they are
    f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
  proc onFrame(f: FrameInfo) =
    inc waited
    let p = f.core.panels[f.core.findPanel(MainPanel)]
    if f.index == 0: f.moveMouse(vec2(4, 4)) # off the plot
    case stage
    of 0: # each look in turn, once drawn
      if p.laidOut and f.answered:
        if shots.len < looks.len:
          let want = looks[shots.len]
          let d = p.layers[0].display
          if d.mode == want.mode and d.fills == want.fills and d.overlap == want.overlap and
              d.gain == dgNone:
            if waited > 3:
              shots.add f.capture
              waited = 0
          else:
            f.show(want)
            waited = 0
        else:
          drawnBefore = f.tracePanel.imagesDrawn
          waited = 0
          stage = 6
    of 6: # nothing changes: nothing is drawn
      if waited > 6:
        idle = (drawnBefore, f.tracePanel.imagesDrawn)
        waited = 0
        stage = 7
    of 7: # each gain type, then +6.02 dB on top of it
      var d = p.layers[0].display.withGainDb(0)
      (d.mode, d.fills, d.overlap) = looks[1]
      if amounts.len <= ord(DisplayGain.high):
        d.gain = DisplayGain(amounts.len)
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        amounts.add Amount(gain: d.gain)
        stage = 8
      else: # and reversed polarity
        d.reversed = true
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        stage = 10
      waited = 0
    of 8:
      if f.answered and not p.reference.isNaN and waited > 3:
        amounts[^1].before = f.capture
        f.apply Command(kind: ckDisplay, panel: MainPanel,
          display: p.layers[0].display.withGainDb(20 * log10(2.0)))
        waited = 0
        stage = 9
    of 9:
      if waited > 3:
        amounts[^1].after = f.capture
        stage = 7
    of 10:
      if f.answered and waited > 3:
        reversed = f.capture
        stage = 11
        f.stop()
    else: discard
    if f.index > 1500: f.stop() # given up: the checks below say what is missing
  let code = run(RunOptions(maxFrames: 2000, openPaths: @[path], windowSize: (1280, 900),
    theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert stage == 11, "stopped at stage " & $stage & " with " & $shots.len & " looks, " &
    $amounts.len & " gain types"

  block everyModeAsTheReferenceSays:
    for k, s in shots:
      doAssert s.w > 300 and s.h > 200, $s.w & "x" & $s.h
      doAssert s.view.traces == Span(lo: -0.5, hi: float64(Channels) - 0.5), $s.view
      doAssert s.style.pixelsPerTrace > 20, "too narrow for wiggles: " & $s.style.pixelsPerTrace
      doAssert s.wiggles == (looks[k].mode != dmDensity) and
        s.density == (looks[k].mode != dmWiggle), $looks[k]
      let (bad, seen) = s.mismatches()
      echo "tguiwiggle: ", looks[k].mode, " ", looks[k].fills, " overlap ", looks[k].overlap,
        ": ", seen, " pixels, ", bad, " off the reference"
      doAssert bad == 0, $looks[k] & ": " & $bad & " of " & $seen & " pixels off the reference"

  block knownTrace:
    # channel 12's peak (191.25 ms) and trough (211.25 ms): the line swings
    # about a trace spacing each way; the fills follow the sides chosen
    let peak = arrivalMs + 10
    let trough = arrivalMs + 30
    for k in 0 .. 3:
      let s = shots[k]
      let ppt = s.style.pixelsPerTrace
      let c = s.column(knownChannel - 1)
      let fill = s.ink.wiggle.positive
      let neg = s.ink.wiggle.negative
      proc count(j, a, b: int; colour: Rgba): int =
        for i in a .. b:
          if close(s.at(i, j), colour): inc result
      let half = int(ppt / 2)
      # right of the baseline at the peak, left of it at the trough
      let rightFill = count(s.row(peak), c + 2, c + half, fill)
      let leftNeg = count(s.row(trough), c - half, c - 2, neg)
      let leftPos = count(s.row(trough), c - half, c - 2, fill)
      let want = half - 1
      doAssert (rightFill >= want) == (wfPositive in looks[k].fills),
        $looks[k] & ": " & $rightFill & " filled pixels right at the peak"
      doAssert (leftNeg >= want) == (wfNegative in looks[k].fills),
        $looks[k] & ": " & $leftNeg & " negative-fill pixels left at the trough"
      doAssert leftPos <= 3, $looks[k] & ": " & $leftPos & " pixels of positive fill (or " &
        "of line) on the negative side" # a line may cross the row
      # the line: the farthest ink right of the baseline at the peak
      var far = 0
      for i in c .. min(s.w - 1, c + int(1.5 * ppt)):
        if not close(s.at(i, s.row(peak)), s.ink.background): far = i - c
      doAssert abs(float64(far) - 0.98 * ppt) <= 2, $looks[k] & ": the peak swings " & $far &
        " px, a trace spacing is " & $ppt

  block overlapClip:
    # the spike (channel 15, 600 ms, 100 times the record's level) swings
    # its trace half a spacing at overlap 0.5, and not a pixel further
    let s = shots[6]
    let ppt = s.style.pixelsPerTrace
    let c = s.column(14)
    var farthest = 0
    for j in s.row(596) .. s.row(604):
      for i in c .. min(s.w - 1, c + int(ppt) - 3):
        if not close(s.at(i, j), s.ink.background): farthest = max(farthest, i - c)
    doAssert float64(farthest) >= 0.5 * ppt - 1.5 and float64(farthest) <= 0.5 * ppt + 1.5,
      "the spike swings " & $farthest & " px; the clip is " & $(0.5 * ppt)
    # with overlap 1 it reaches the next trace
    let wide = shots[1]
    var reach = 0
    for j in wide.row(596) .. wide.row(604):
      for i in c .. min(wide.w - 1, c + int(1.5 * ppt)):
        if not close(wide.at(i, j), wide.ink.background) and i - c < int(ppt) - 2:
          reach = max(reach, i - c)
    doAssert float64(reach) >= ppt - 4, "at overlap 1 the spike swings only " & $reach & " px"

  block idleDrawsNothing:
    doAssert idle[1] == idle[0], $(idle[1] - idle[0]) & " images drawn while nothing changed"

  block gainAmountUnderEveryType:
    # +6.02 dB doubles the scale: the wiggles swing twice as far, as the
    # reference says, and nothing is read again
    for a in amounts:
      doAssert a.before.gen == a.after.gen and a.before.ids == a.after.ids,
        $a.gain & ": the amount read again"
      doAssert abs(a.after.scale - 2 * a.before.scale) <= 1e-5 * abs(a.after.scale),
        $a.gain & ": scale " & $a.before.scale & " became " & $a.after.scale
      for s in [a.before, a.after]:
        doAssert s.wiggles, $a.gain & ": no wiggles"
        let (bad, seen) = s.mismatches(step = 3)
        doAssert bad == 0, $a.gain & ": " & $bad & " of " & $seen & " pixels off the reference"
      var changed = 0
      for k in countup(0, a.after.image.high, 7):
        if distance(a.before.image[k], a.after.image[k]) > 6: inc changed
      doAssert changed > a.after.image.len div 7 div 50, $a.gain & ": only " & $changed &
        " pixels changed"

  block polarity:
    let s = reversed
    let last = amounts[^1].after
    doAssert s.gen == last.gen and s.ids == last.ids, "reversing the polarity read again"
    let zero = amounts[^1].before # reversed at 0 dB, as this was drawn
    doAssert s.scale == -zero.scale, $s.scale & " after " & $zero.scale
    let (bad, seen) = s.mismatches(step = 3)
    doAssert bad == 0, "reversed: " & $bad & " of " & $seen & " pixels off the reference"

  doAssert snapshot(path) == before, "showing the file changed it"

  block densityTakesOver:
    # 400 traces on a plot about 500 pixels wide: under 4 px a trace
    let demo = fx.longSpreadSegy()
    var note, after: (bool, bool, float64) # note shown, wiggles drawn, px per trace
    var step = 0
    var count = 0
    proc onDemo(f: FrameInfo) =
      inc count
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      if step == 0 and f.answered and count > 5:
        let v = f.tracePanel.drawnView
        let d = p.layers[0].display
        note = (f.markOf("plot.density note").size.x > 0, d.drawsWiggles(v), pixelsPerTrace(v))
        var z = p.view
        z.traces = Span(lo: 49.5, hi: 99.5) # 50 traces: about 10 px each
        f.showView(z)
        step = 1
        count = 0
      elif step == 1 and f.answered and count > 5:
        let v = f.tracePanel.drawnView
        after = (f.markOf("plot.density note").size.x > 0,
          p.layers[0].display.drawsWiggles(v), pixelsPerTrace(v))
        step = 2
        f.stop()
      if f.index > 1500: f.stop()
    let code = run(RunOptions(maxFrames: 2000, openPaths: @[demo], windowSize: (900, 600),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onDemo))
    doAssert code == 0 and step == 2, "the demo line never showed: step " & $step
    doAssert note[2] < WiggleMinPixels and note[0] and not note[1],
      "narrow traces: " & $note
    doAssert after[2] >= WiggleMinPixels and not after[0] and after[1], "zoomed in: " & $after
