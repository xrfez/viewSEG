## Filters that reach none of the traces shown, headless, on a SEG-D record
## with a time break and a pilot beside its 24 seismic traces, its
## auxiliary traces shown alone (Aux on, Seismic off) and a notch set: the
## filters' button is not lit but drawn in the warning colour (it is lit,
## in the accent colour, while they apply), its drop-down says why next to
## "Filter the Aux traces too"; an FFT window of the two auxiliary traces
## has no processed curve and offers "Filter the Aux traces too", whose
## click ticks the plot's toggle: the plot's filters then reach every trace
## shown, the button is lit again, and the FFT window follows (both traces
## through the filters). With the seismic traces shown too and the toggle
## off, the filters reach the seismic ones (lit; the drop-down says the
## auxiliary ones are not filtered).
##
## Seen to fail: with the button drawn lit whatever the filters reach
## (`pr.filtering` alone), "the button is lit (accent 30 px) while the
## filters reach no trace"; with the spectrum window's button not drawn,
## "fft 1.filter aux is not shown".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves filters-unreached.png there.

import std/[math, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/theme
import utils/fixtures

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc answered(f: FrameInfo): bool =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

proc inked(f: FrameInfo; mark: string; role: Role): int =
  ## The pixels of `mark`'s rectangle inked in the theme's `role` colour:
  ## those away from its background (its corner's colour) whose step from
  ## it points to `role` more than to the text, accent or warning colour
  ## (a glyph's thin lines are blended with the background).
  let r = f.markOf(mark)
  let bg = f.readPixel(int(r.pos.x) + 1, int(r.pos.y) + 1)
  proc toward(c, ink: Rgba): float64 =
    let (a, b) = ([float64(c.r) - float64(bg.r), float64(c.g) - float64(bg.g),
      float64(c.b) - float64(bg.b)], [float64(ink.r) - float64(bg.r),
      float64(ink.g) - float64(bg.g), float64(ink.b) - float64(bg.b)])
    let n = sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]) *
      sqrt(b[0] * b[0] + b[1] * b[1] + b[2] * b[2])
    if n > 0: (a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) / n else: -1.0
  for y in int(r.pos.y) ..< int(r.pos.y + r.size.y):
    for x in int(r.pos.x) ..< int(r.pos.x + r.size.x):
      let c = f.readPixel(x, y)
      if distance(c, bg) >= 40:
        var best = rlText
        for ink in [rlAccent, rlWarning]:
          if toward(c, f.theme.roles[ink]) > toward(c, f.theme.roles[best]): best = ink
        if best == role: inc result

withFixtures fx:
  var steps: seq[Step]
  var at = 0
  var started = false
  var wait = 0
  var failed = ""
  var pointAt: Vec2
  let shots = getEnv("VIEWSEG_SCREENSHOTS")
  let notch = Processing(notches: @[NotchFilter(hz: 60, widthHz: 2, harmonics: 3)])
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard
  proc after(n: int): proc (f: FrameInfo): bool =
    var frames = 0
    result = proc (f: FrameInfo): bool =
      inc frames
      frames >= n
  proc click(mark: string) =
    step("to " & mark, proc (f: FrameInfo) =
      let r = f.markOf(mark)
      doAssert r.size.x > 0, mark & " is not shown"
      pointAt = r.centre
      f.moveMouse(pointAt), after(2))
    step("click " & mark, proc (f: FrameInfo) =
      f.pressMouse(pointAt, true)
      f.pressMouse(pointAt, false), after(3))

  step("the record", noop, proc (f: FrameInfo): bool =
    f.answered and f.panel.layout.traces == 24)
  step("auxiliary traces alone, a notch", proc (f: FrameInfo) =
    f.apply Command(kind: ckFilter, panel: MainPanel,
      filter: TraceFilter(seismic: false, auxiliary: true))
    f.apply(Command(kind: ckProcessing, panel: MainPanel, processing: notch)),
    proc (f: FrameInfo): bool = f.answered and f.panel.layout.traces == 2)
  step("not lit, in the warning colour", noop, proc (f: FrameInfo): bool =
    doAssert f.core.filterReach(f.panel) == frNoTrace, $f.core.filterReach(f.panel)
    let (warn, accent) = (f.inked("plot.filters", rlWarning), f.inked("plot.filters", rlAccent))
    doAssert accent == 0, "the button is lit (accent " & $accent &
      " px) while the filters reach no trace"
    doAssert warn > 10, "the button is not in the warning colour: " & $warn & " px"
    true)
  click("plot.filters")
  step("the drop-down says why", noop, proc (f: FrameInfo): bool =
    result = f.markOf("plot.filters aux").size.x > 0
    if result:
      doAssert f.markOf("plot.filters reach").size.x > 0, "the drop-down does not say why"
      if shots.len > 0:
        doAssert f.savePng(shots / "filters-unreached.png"))
  step("close it", proc (f: FrameInfo) =
    f.pressKey(skEscape, true)
    f.pressKey(skEscape, false), after(3))
  step("an FFT window of the auxiliary traces", proc (f: FrameInfo) =
    let base = f.core.sessions[0].base
    f.apply(Command(kind: ckSpectrum, spectrumOf: MainPanel,
      spectrumTraces: @[base + f.panel.shown[0], base + f.panel.shown[1]],
      spectrumShow: SpectrumDisplay())),
    proc (f: FrameInfo): bool =
      let w = f.core.spectra.high
      result = w > 0 and not f.core.spectra[w].waiting and
        f.core.spectra[w].spectrum.raw.len > 0
      if result:
        doAssert f.core.spectra[w].spectrum.processed.len == 0 and
          f.core.spectra[w].spectrum.passedBy == 2, $f.core.spectra[w].spectrum.passedBy)
  step("its button", noop, proc (f: FrameInfo): bool =
    result = true
    doAssert f.markOf("fft 1.filter aux").size.x > 0, "fft 1.filter aux is not shown")
  click("fft 1.filter aux")
  step("the plot's toggle ticked, the window following", noop, proc (f: FrameInfo): bool =
    let w = f.core.spectra.high
    result = f.panel.layers[0].processing.aux and f.answered and
      not f.core.spectra[w].waiting and f.core.spectra[w].spectrum.filtered == 2
    if result:
      doAssert f.core.filterReach(f.panel) == frAll
      doAssert f.core.spectra[w].spectrum.processed.len > 0)
  step("lit again", noop, proc (f: FrameInfo): bool =
    result = f.markOf("fft 1.filter aux").size.x == 0 # gone: nothing left to filter
    if result:
      doAssert f.inked("plot.filters", rlAccent) > 10, "the button is not lit"
      doAssert f.inked("plot.filters", rlWarning) == 0)
  step("seismic and auxiliary, the toggle off", proc (f: FrameInfo) =
    f.apply Command(kind: ckFilter, panel: MainPanel,
      filter: TraceFilter(seismic: true, auxiliary: true))
    f.apply(Command(kind: ckProcessing, panel: MainPanel, processing: notch)),
    proc (f: FrameInfo): bool = f.answered and f.panel.layout.traces == 26)
  step("the seismic traces reached", noop, proc (f: FrameInfo): bool =
    doAssert f.core.filterReach(f.panel) == frSeismic
    doAssert f.inked("plot.filters", rlAccent) > 10, "the button is not lit"
    true)

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
      if wait >= 2 and steps[at].done(f):
        inc at
        started = false
      elif wait > 600:
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(maxFrames: 6000, openPaths: @[fx.twoSetSegd()],
    windowSize: (1400, 900), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  echo "tguifilterreach: ", steps.len, " steps"
