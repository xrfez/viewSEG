## A trace the file marks dead is never drawn, headless, on a shot whose
## channel 5 is marked dead in the file while it holds samples (1000 times
## the survey's, as loud as its neighbours), at overlap 0.4 so that no
## neighbour's lobe reaches its baseline: under every gain type (Automatic,
## None, Fixed, Normalized per trace and for the record, Exponential, Float,
## AGC) and in every display mode (wiggles, wiggles over density, density),
## the plot's image is what the CPU reference draws, and the dead trace's
## column is the plot's background from top to bottom (no line, no fill, no
## grey), where its live neighbour's is not. Over it, the status bar says
## "dead".
##
## Seen to fail: with `Tile.isBlank` left out of the GPU's marks
## (`textures.marksOf` marking killed traces only), "wiggle, none: 165 of
## 51480 pixels off the reference" (the dead trace's line of zeros drawn
## down its baseline). The reader's side (the dead trace's samples blanked
## under every gain, its level left out) is `tgain`'s `deadAndNotANumber`.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, plotref, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

const
  Dead = 4 ## channel 5's position
  Live = 3

proc ink(s: Shot; position: int): int =
  ## The pixels of the image column at `position`'s baseline that are not
  ## the plot's background.
  let c = s.column(float64(position))
  for j in 0 ..< s.h:
    if not close(s.at(c, j), s.ink.background): inc result

proc offReference(s: Shot): (int, int) =
  ## `mismatches`, but for the image columns whose centre lies on the edge
  ## of two traces' cells, where the nearest trace is the GPU's rounding or
  ## the CPU's (at some plot widths a cell edge falls on a pixel centre).
  var first = 0
  for i in 0 .. s.w:
    let edge = i == s.w or abs(s.xOf(i) + 0.5 - round(s.xOf(i) + 0.5)) < 1e-6
    if edge:
      if i > first:
        let (bad, seen) = s.mismatches(columns = first .. i - 1)
        result = (result[0] + bad, result[1] + seen)
      first = i + 1

withFixtures fx:
  let path = fx.deadAndNotANumberSegy()
  var steps: seq[Step]
  var at = 0
  var started = false
  var wait = 0 # frames since the step began, at `since`
  var since = getMonoTime()
  var failed = ""
  var images, quiet = 0
  template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard
  proc settled(f: FrameInfo): bool =
    let tiles = f.core.tiles(f.core.findPanel(MainPanel))
    tiles.len > 0 and tiles[^1].request == f.panel.pending and
      f.tracePanel.drawnView.sameSpans(f.panel.view) and quiet >= 2

  proc shows(mode: DisplayMode; g: DisplayGain; scope: NormScope): proc (f: FrameInfo) =
    result = proc (f: FrameInfo) =
      var d = f.panel.layers[0].display
      (d.mode, d.gain, d.normScope, d.overlap, d.fixedClip) = (mode, g, scope, 0.4, NaN)
      f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)

  proc blank(mode: DisplayMode; g: DisplayGain; scope: NormScope): proc (f: FrameInfo): bool =
    let what = $mode & ", " & $g & (if g == dgNormalized: " " & $scope else: "")
    result = proc (f: FrameInfo): bool =
      let d = f.panel.layers[0].display
      result = d.mode == mode and d.gain == g and d.normScope == scope and f.settled
      if result:
        let s = f.capture
        let (bad, seen) = s.offReference()
        doAssert bad == 0, what & ": " & $bad & " of " & $seen & " pixels off the reference"
        doAssert s.ink(Dead) == 0, what & ": the dead trace's column has " & $s.ink(Dead) &
          " pixels of ink"
        doAssert s.ink(Live) > s.h div 4, what & ": the live trace's column has " &
          $s.ink(Live) & " pixels of ink"

  step("the file is shown", noop, proc (f: FrameInfo): bool =
    result = f.panel.laidOut and f.panel.layers.len > 0 and f.settled)
  for mode in [dmWiggle, dmWiggleDensity, dmDensity]:
    for (g, scope) in [(dgNone, perTrace), (dgAuto, perTrace), (dgFixed, perTrace),
        (dgNormalized, perTrace), (dgNormalized, perPanel), (dgExponential, perTrace),
        (dgFloat, perTrace), (dgAgc, perTrace)]:
      step($mode & " " & $g, shows(mode, g, scope), blank(mode, g, scope))
  step("over the dead trace", proc (f: FrameInfo) =
    let s = f.capture
    let plot = f.markOf("plot.data")
    let x = plot.pos.x + (float32(s.column(float64(Dead))) + 0.5) * plot.size.x / float32(s.w)
    f.moveMouse(vec2(round(x), round(plot.pos.y + plot.size.y / 2))),
    proc (f: FrameInfo): bool =
      result = f.pick.found and f.pick.position == Dead and quiet > 1
      if result: doAssert "dead" in editNote(f.pick), editNote(f.pick))

  proc onFrame(f: FrameInfo) =
    if f.index == 0: f.moveMouse(vec2(4, 4))
    if f.tracePanel.imagesDrawn != images:
      images = f.tracePanel.imagesDrawn
      quiet = 0
    else: inc quiet
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

  let code = run(RunOptions(openPaths: @[path], windowSize: (1300, 900),
    theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  echo "tguidead: ", steps.len, " steps"
