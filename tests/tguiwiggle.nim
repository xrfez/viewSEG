## Wiggles and trace highlighting in the running frontend, headless, on the
## survey fixture with a spike (`pdSpike`: one sample of 100 among values
## of at most 1):
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
## - moving the mouse over a trace draws it, line and fill, in the
##   highlight colour and its neighbours not, with nothing read again (no
##   request) and no tile uploaded again (counted); a click selects it (the
##   selection colour once the pointer has moved on), Ctrl + click adds
##   another, Esc clears them; under density alone the hovered trace's
##   column is tinted;
## - with the pointer still over the plot, the next gather and then another
##   file are shown: in no frame does the hover name a trace the plot does
##   not show, and once each is drawn the trace under the pointer is hovered;
## - a plot in which nothing changes draws no new image;
## - the gain amount scales the wiggles under every gain type, as the
##   reference says, with nothing read again; reversed polarity, an
##   operation on the data, reads the view again with every value negated
##   and swings the wiggles the other way;
## - the file is never changed.
##
## Seen to fail: with the shader's swing not clipped (`clamp` left out),
## the first look already had 35 pixels off the reference (the spike's
## line); with the fills' sides swapped in the shader, 1496 pixels of the
## positive fill were off; with the second pass of marked traces left out,
## `hoverHighlights` found 34 pixels off where a neighbour covered the
## hovered trace; with the plot not sending `ckHover`, the test waited for
## a hover that never came; with no `ckSelect` on a click, `clickSelects`
## found nothing selected; with the density shader not tinting,
## `densityTint` found 2610 pixels of the hovered column off; with the
## renderer drawing every frame, `idleDrawsNothing` counted 7 images while
## nothing changed; with the wiggles drawn at the reference's scale, without the gain
## amount, `gainAmountUnderEveryType` found 969 pixels off
## under Automatic at +6 dB; with the tiles uploaded again whenever the
## selection changed, `hoverHighlights` counted 1 tile uploaded for a
## hover; with the plot keeping its hover while it showed "Reading..."
## (as it did), `noStaleHover` found the trace of the file before hovered
## in the frame the new file came in.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
##
## Runs alone: it measures the frame times while panning (with
##   `VIEWSEG_SCREENSHOTS`).

import std/[algorithm, math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state, wiggle]
import viewSEG/view/[plotink, theme]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

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
    uploads: int      ## tiles uploaded to the GPU so far
    screen: seq[Rgba] ## the whole frame
    width: int        ## the frame's width
    plot: Rect        ## where the plot lies in it

proc capture(f: FrameInfo): Shot =
  let k = f.core.findPanel(MainPanel)
  let p = f.core.panels[k]
  let d = p.layers[0].display
  let (img, w, h) = f.tracePanel.plotImage
  let v = f.tracePanel.drawnView
  let scale = displayScale(p.reference, d.gainDb)
  result = Shot(image: img, w: w, h: h, view: v, display: d, ink: plotInk(f.theme, d),
    style: d.styleFor(v, scale, 1, 2), scale: scale, density: d.mode != dmWiggle,
    wiggles: d.mode != dmDensity, hover: f.core.selection.hover,
    selection: f.core.selection, gen: p.requestGen, uploads: f.tracePanel.tilesUploaded,
    screen: f.readFrame, width: f.width, plot: f.markOf("plot.data"))
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
  ## What image pixel (`i`, `j`) should show: the tiles oldest first (but
  ## for those a newer one covers in view: `hidden`), each its area
  ## (density or the background) then its wiggles, the marked traces again
  ## on top.
  let (x, t) = (s.xOf(i), s.tOf(j))
  result = s.ink.background
  for k, tile in s.tiles:
    if not s.tiles.hidden(k, s.view):
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
  var hovered, clicked, added, cleared, tinted: Shot
  var idle: (int, int)
  type Amount = object
    ## A gain type's wiggles before and after +6.02 dB.
    gain: DisplayGain
    before, after: Shot
  var amounts: seq[Amount]
  var reversed: Shot
  var stage = 0
  var waited = 0 # frames since the stage (or look) began, at `since`
  var since = getMonoTime()
  var drawnBefore = 0
  # the gather, then the file, changed under a still pointer: frames whose
  # hover named a trace the plot did not show, and the hovers that came after
  var watching = false
  var stale: seq[string]
  var newGather, newFile = -1
  let second = fx.surveySegy() # survey-clean.sgy: another file
  proc hoverShown(f: FrameInfo): bool =
    ## Whether the hover is none, or a trace of the gather the plot shows.
    let h = f.core.selection.hover
    if h < 0: return true
    let src = f.core.panels[f.core.findPanel(MainPanel)].layers[0].source
    let s = f.core.findSession(src.file)
    s >= 0 and h in f.core.sessions[s] and src.gather in 0 ..< f.core.sessions[s].gathers.len and
      h - f.core.sessions[s].base in f.core.sessions[s].gathers[src.gather].traces
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
  proc click(f: FrameInfo; at: Vec2) =
    f.pressMouse(at, true)
    f.pressMouse(at, false)
  proc onFrame(f: FrameInfo) =
    inc waited
    let p = f.core.panels[f.core.findPanel(MainPanel)]
    if f.index == 0: f.moveMouse(vec2(4, 4)) # off the plot: no hover until stage 1
    if watching and not f.hoverShown:
      stale.add "frame " & $f.index & " (stage " & $stage & "): hover " &
        $f.core.selection.hover & " is not shown"
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
              (waited, since) = (0, getMonoTime())
          else:
            f.show(want)
            (waited, since) = (0, getMonoTime())
        else:
          f.show(looks[1])
          f.moveMouse(f.baselineAt(knownChannel - 1, 450))
          (waited, since) = (0, getMonoTime())
          stage = 1
    of 1: # the pointer over the known trace
      if waited > 4 and f.core.selection.hover >= 0:
        hovered = f.capture
        # twice: the click that brings the window forward selects nothing, and
        # a plain click on a selected trace leaves it the selection
        f.click(f.baselineAt(knownChannel - 1, 450))
        f.click(f.baselineAt(knownChannel - 1, 450))
        (waited, since) = (0, getMonoTime())
        stage = 2
    of 2: # clicked; the pointer moves on to trace 5
      if waited == 3: f.moveMouse(f.baselineAt(5, 450))
      if waited > 8:
        clicked = f.capture
        f.pressKey(skCtrl, true, {smCtrl}) # the event carries the modifier, as SDL's do
        (waited, since) = (0, getMonoTime())
        stage = 3
    of 3: # Ctrl + click on trace 5, then on to trace 17
      if waited == 2: f.click(f.baselineAt(5, 450))
      if waited == 4: f.pressKey(skCtrl, false)
      if waited == 6: f.moveMouse(f.baselineAt(17, 450))
      if waited > 10:
        added = f.capture
        f.pressKey(skEscape, true)
        f.pressKey(skEscape, false)
        (waited, since) = (0, getMonoTime())
        stage = 4
    of 4: # Esc cleared the selection; then density alone, over trace 11
      if waited > 4:
        cleared = f.capture
        f.show(looks[5])
        f.moveMouse(f.baselineAt(knownChannel - 1, 450))
        (waited, since) = (0, getMonoTime())
        stage = 5
    of 5: # drawn in density: its limits are not the wiggles', so it may read again
      if waited > 6 and f.answered and f.tracePanel.drawnView.sameSpans(p.view):
        tinted = f.capture
        drawnBefore = f.tracePanel.imagesDrawn
        (waited, since) = (0, getMonoTime())
        stage = 6
    of 6: # nothing changes: nothing is drawn
      if waited > 6:
        idle = (drawnBefore, f.tracePanel.imagesDrawn)
        (waited, since) = (0, getMonoTime())
        stage = 7
    of 7: # each gain type, then +6.02 dB on top of it
      var d = p.layers[0].display.withGainDb(0)
      (d.mode, d.fills, d.overlap) = looks[1]
      if amounts.len <= ord(DisplayGain.high):
        d.gain = DisplayGain(amounts.len)
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        amounts.add Amount(gain: d.gain)
        stage = 8
      else: # and reversed polarity, at 0 dB
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        f.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: true)
        stage = 10
      (waited, since) = (0, getMonoTime())
    of 8:
      if f.answered and not p.reference.isNaN and waited > 3:
        amounts[^1].before = f.capture
        f.apply Command(kind: ckDisplay, panel: MainPanel,
          display: p.layers[0].display.withGainDb(20 * log10(2.0)))
        (waited, since) = (0, getMonoTime())
        stage = 9
    of 9:
      if waited > 3:
        amounts[^1].after = f.capture
        stage = 7
    of 10:
      if f.answered and waited > 3:
        reversed = f.capture
        f.moveMouse(f.baselineAt(3, 450))
        (waited, since) = (0, getMonoTime())
        stage = 11
    of 11: # a trace hovered; then the next gather, the pointer still
      if waited > 3 and f.core.selection.hover >= 0:
        watching = true
        f.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
        (waited, since) = (0, getMonoTime())
        stage = 12
    of 12: # the new gather drawn, and a trace of it hovered; then another file
      if f.answered and waited > 3 and f.core.selection.hover >= 0:
        newGather = f.core.selection.hover
        f.apply Command(kind: ckOpen, paths: @[second])
        (waited, since) = (0, getMonoTime())
        stage = 13
    of 13:
      if f.core.sessions.len == 2 and p.layers[0].source.file == f.core.sessions[1].id and
          f.answered and waited > 3 and f.core.selection.hover >= 0:
        newFile = f.core.selection.hover
        stage = 14
        f.stop()
    else: discard
    if overdue(waited, 2500, since): f.stop() # given up: the checks below say what is missing
  let code = run(RunOptions(openPaths: @[path], windowSize: (1280, 900),
    theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert stage == 14, "stopped at stage " & $stage & " with " & $shots.len & " looks, " &
    $amounts.len & " gain types"

  block everyModeAsTheReferenceSays:
    for k, s in shots:
      doAssert s.w > 300 and s.h > 200, $s.w & "x" & $s.h
      # the whole record, and in the wiggle modes the swing of the edge traces
      # past it (half a spacing at overlap 1, none at 0.5 or in density)
      let m = s.display.traceMargin
      doAssert s.view.traces == Span(lo: -0.5 - m, hi: float64(Channels) - 0.5 + m), $s.view
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

  block hoverHighlights:
    let s = hovered
    let hover = s.ink.wiggle.hover
    doAssert s.hover == knownChannel - 1, "the hover is trace " & $s.hover
    # no request (so nothing read or decimated again) and no tile uploaded
    doAssert s.gen == shots[1].gen and s.ids == shots[1].ids, "a hover read again"
    doAssert s.uploads == shots[1].uploads, $(s.uploads - shots[1].uploads) &
      " tiles uploaded for a hover"
    let lit = s.share(knownChannel - 1, hover, 400, 650)
    doAssert lit > 0.9, "the hovered trace is in the highlight colour on " & $lit & " of its rows"
    for n in [knownChannel - 2, knownChannel]:
      doAssert s.share(float64(n), hover, 400, 650, int(s.style.pixelsPerTrace / 2) - 2) == 0,
        "trace " & $n & " has the highlight colour"
    let (bad, seen) = s.mismatches()
    doAssert bad == 0, "hovered: " & $bad & " of " & $seen & " pixels off the reference"
    # and on the screen, where the plot shows the image
    let x = int(s.plot.pos.x + float32((float64(knownChannel - 1) - s.view.traces.lo) /
      s.view.traces.width) * s.plot.size.x)
    let y = int(s.plot.pos.y + s.plot.size.y * 0.4)
    var onScreen = false
    for i in x - 2 .. x + 2:
      if close(s.screen[y * s.width + i], hover, 30): onScreen = true
    doAssert onScreen, "no highlight colour on the screen at the trace"

  block clickSelects:
    let s = clicked
    doAssert knownChannel - 1 in s.selection.selected and s.selection.selected.len == 1
    doAssert s.hover == 5
    doAssert s.share(knownChannel - 1, s.ink.wiggle.selected, 400, 650) > 0.9,
      "the selected trace is not in the selection colour"
    doAssert s.share(5, s.ink.wiggle.hover, 400, 650) > 0.9, "trace 5 is not hovered"
    doAssert s.gen == shots[1].gen and s.ids == shots[1].ids, "a click read again"
    doAssert s.uploads == shots[1].uploads, $(s.uploads - shots[1].uploads) &
      " tiles uploaded for a click"
    let (bad, seen) = s.mismatches()
    doAssert bad == 0, "selected: " & $bad & " of " & $seen & " pixels off the reference"

  block ctrlClickAdds:
    let s = added
    doAssert s.selection.selected.len == 2 and 5 in s.selection.selected and
      knownChannel - 1 in s.selection.selected, "selected: " & $s.selection.selected
    doAssert s.share(5, s.ink.wiggle.selected, 400, 650) > 0.9 and
      s.share(knownChannel - 1, s.ink.wiggle.selected, 400, 650) > 0.9
    doAssert s.share(17, s.ink.wiggle.hover, 400, 650) > 0.9

  block escClears:
    let s = cleared
    doAssert s.selection.selected.len == 0, "Esc left " & $s.selection.selected
    for n in [5, knownChannel - 1]:
      doAssert s.share(float64(n), s.ink.wiggle.selected, 400, 650) == 0

  block densityTint:
    let s = tinted
    doAssert not s.wiggles and s.density and s.hover == knownChannel - 1
    let (bad, seen) = s.mismatches()
    doAssert bad == 0, "tinted: " & $bad & " of " & $seen & " pixels off the reference"
    # the column is tinted towards the hover colour; its neighbours are not
    let c = s.column(knownChannel - 1)
    let j = s.row(450)
    let plain = greyLut().densityColour(0, s.scale)
    doAssert close(s.at(c, j), densityTint(plain, tmHovered, s.ink.wiggle, DensityTint)) and
      not close(s.at(c, j), plain), "the hovered column is not tinted"
    let n = s.column(knownChannel)
    doAssert close(s.at(n, j), plain), "the neighbour's column is tinted"

  block noStaleHover:
    # while the next gather, then another file, was read, the pointer still
    # over the plot: the hover never named a trace the plot did not show,
    # and once each was drawn, the trace under the pointer was hovered
    doAssert stale.len == 0, $stale.len & " frames: " & stale[0 .. min(2, stale.high)].join("; ")
    doAssert newGather >= 0 and newFile >= 0, $(newGather, newFile)

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
    # An operation on the data: the view is read again, its samples
    # reversed (as processSEG's polarityOp makes them: tpolarity), at the
    # same scale, and drawn mirrored.
    let s = reversed
    let zero = amounts[^1].before # as it was at 0 dB, before the reversal
    doAssert s.gen > zero.gen, "reversing the polarity read nothing"
    doAssert s.scale == zero.scale, $s.scale & " after " & $zero.scale
    let (a, b) = (zero.tiles[^1], s.tiles[^1])
    doAssert a.request.first == b.request.first and a.request.count == b.request.count and
      a.data.len == b.data.len, "another view was read"
    for i in 0 ..< a.data.len:
      doAssert b.data[i] == -a.data[i], "value " & $i & ": " & $b.data[i] & " for " &
        $a.data[i]
    let (bad, seen) = s.mismatches(step = 3)
    doAssert bad == 0, "reversed: " & $bad & " of " & $seen & " pixels off the reference"
    var mirrored = 0
    for k in countup(0, s.image.high, 7):
      if distance(s.image[k], zero.image[k]) > 6: inc mirrored
    doAssert mirrored > s.image.len div 7 div 50, "only " & $mirrored & " pixels changed"

  doAssert snapshot(path) == before, "showing the file changed it"

# ------------------------------------------------- screenshots of real data --
# With `VIEWSEG_SCREENSHOTS=<dir>` and the example files present (they are
# local only), the plot window is saved zoomed in on the Morgantown record in
# every mode, and as it opens (at the wiggle mode's limit, a trace a pixel),
# one trace hovered and one selected, as wiggle-*.png
# (docs/screenshots/ holds the committed ones), and the frame times while
# panning in each mode are printed.

const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

proc wiggleShot(path, file: string; mode: DisplayMode; fills: set[WiggleFill];
    traces, timeMs: Span; colours = pcPaper) =
  ## Opens `path` in a 1600 × 1000 window, shows `traces` and `timeMs` in
  ## `mode` with `fills` (with no `traces`, the view the record opens at),
  ## selects the trace a fifth of the way across and hovers the one at the
  ## middle, saves the frame, then pans to and fro for 120 frames and prints
  ## their times.
  let dir = getEnv("VIEWSEG_SCREENSHOTS")
  var stage = 0
  var wait = 0 # frames since the stage began, at `since`
  var since = getMonoTime()
  var saved = false
  var times: seq[float64]
  var last = getMonoTime()
  var timeMs = timeMs
  var selected = traces.lo + 0.2 * traces.width + 0.5
  var hovered = traces.lo + 0.5 * traces.width + 0.5
  proc onFrame(f: FrameInfo) =
    let now = getMonoTime()
    let k = f.core.findPanel(MainPanel)
    let p = f.core.panels[k]
    inc wait
    case stage
    of 0:
      if f.index == 0: f.moveMouse(vec2(4, 4))
      if p.laidOut and p.layout.traces > 0:
        var v = p.view
        if traces.width > 0:
          v.traces = traces
          v.timeMs = timeMs
          f.showView(v)
        var d = p.layers[0].display
        (d.mode, d.fills, d.colours) = (mode, fills, colours)
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        (stage, wait, since) = (1, 0, getMonoTime())
    of 1:
      let tiles = f.core.tiles(k)
      if wait > 10 and tiles.len > 0 and tiles[^1].request == p.pending:
        if traces.width <= 0: # the view it opened at
          let w = p.view.traces
          timeMs = p.view.timeMs
          selected = w.lo + 0.2 * w.width + 0.5
          hovered = w.lo + 0.5 * w.width + 0.5
        f.moveMouse(f.baselineAt(floor(selected), timeMs.lo + 0.4 * timeMs.width))
        (stage, wait, since) = (2, 0, getMonoTime())
    of 2:
      # twice: the click that brings the window forward selects nothing
      if wait in [3, 9]: f.pressMouse(f.baselineAt(floor(selected), timeMs.lo + 0.4 *
        timeMs.width), true)
      if wait in [5, 11]: f.pressMouse(f.baselineAt(floor(selected), timeMs.lo + 0.4 *
        timeMs.width), false)
      if wait == 14: f.moveMouse(f.baselineAt(floor(hovered), timeMs.lo + 0.4 * timeMs.width))
      if wait > 20:
        saved = f.savePng(dir / file)
        (stage, wait, since) = (3, 0, getMonoTime())
    of 3: # frame times while panning, a trace every other frame
      if wait > 1: times.add float64((now - last).inMicroseconds) / 1000
      if wait mod 2 == 0:
        var v = p.view
        let dx = if (wait div 40) mod 2 == 0: 0.5 else: -0.5
        v.traces = Span(lo: v.traces.lo + dx, hi: v.traces.hi + dx)
        f.showView(v)
      if wait > 121: f.stop()
    else: discard
    last = now
    if overdue(wait, 3000, since): f.stop()
  let tmp = getTempDir() / ("viewseg-wiggleshot-" & $getCurrentProcessId())
  let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000),
    theme: forceDark, indexCacheDir: some(tmp), userThemeDir: some(tmp / "no-user-themes"),
    onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0 and saved, "no screenshot of " & path
  times.sort
  echo "tguiwiggle: saved ", dir / file, "; ", times.len, " frames panning: median ",
    formatFloat(times[times.len div 2], ffDecimal, 1), " ms, 90 % ",
    formatFloat(times[int(0.9 * float64(times.high))], ffDecimal, 1), " ms, slowest ",
    formatFloat(times[^1], ffDecimal, 1), " ms"

if getEnv("VIEWSEG_SCREENSHOTS").len > 0:
  let morgantown = examples / "00000151_12900_11300.sgd"
  if fileExists(morgantown):
    createDir(getEnv("VIEWSEG_SCREENSHOTS"))
    let traces = Span(lo: 999.5, hi: 1039.5)
    let timeMs = Span(lo: 400, hi: 1000)
    wiggleShot(morgantown, "wiggle-morgantown.png", dmWiggle, {wfPositive}, traces, timeMs)
    wiggleShot(morgantown, "wiggle-morgantown-line.png", dmWiggle, {}, traces, timeMs)
    wiggleShot(morgantown, "wiggle-morgantown-both.png", dmWiggle, {wfPositive, wfNegative},
      traces, timeMs)
    wiggleShot(morgantown, "wiggle-morgantown-density.png", dmWiggleDensity, {}, traces,
      timeMs)
    wiggleShot(morgantown, "wiggle-morgantown-theme.png", dmWiggle, {wfPositive}, traces,
      timeMs, pcTheme)
    wiggleShot(morgantown, "density-morgantown-highlight.png", dmDensity, {},
      Span(lo: 899.5, hi: 1299.5), Span(lo: 0, hi: 2500))
    # as it opens: wiggles at one pixel a trace, from the first trace
    wiggleShot(morgantown, "wiggle-morgantown-limit.png", dmWiggle, {wfPositive}, Span(),
      Span())
