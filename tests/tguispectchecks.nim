## Locked spectrum check boxes, headless, with real clicks, on `spectrumSegy`:
##
## - with no filter on, Processed and Response are drawn unticked and a click
##   does not change the stored choice (it stays ticked);
## - a filter on, that stored choice shows again (both ticked);
## - a trace's own filter alone, the plot's filters off, enables Processed
##   (its stored tick shows), and, the spectrum being of that one trace,
##   Response too: its response is what that trace went through.
##
## Phase, when the spectrum is not of one trace, is the same: drawn unticked
## while disabled, the stored choice kept. The New plot windows have no
## checkbox that is disabled while still showing a stored tick.
##
## Seen to fail: with the disabled box still given the stored flag (`shown =
## stored` instead of `enabled and stored`), "processed drawn ticked while
## no filter is on".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, processing, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

func boxOf(r: Rect): Rect =
  ## A checkbox's box: the square at the left of its item, as high as the line.
  Rect(pos: r.pos, size: vec2(r.size.y, r.size.y))

proc accentIn(f: FrameInfo; r: Rect): int =
  ## Pixels of the accent (a checkbox's tick) inside `r`.
  if r.size.x <= 0: return 0
  let pixels = f.readFrame()
  let accent = f.theme.roles[rlAccent]
  let x0 = max(0, int(r.pos.x))
  let y0 = max(0, int(r.pos.y))
  let x1 = min(f.width, int(ceil(r.pos.x + r.size.x)))
  let y1 = min(f.height, int(ceil(r.pos.y + r.size.y)))
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      if distance(pixels[y * f.width + x], accent) <= 48: inc result

proc ticked(f: FrameInfo; mark: string): bool =
  f.accentIn(f.markOf(mark).boxOf) > 4

withFixtures fx:
  var steps: seq[Step]
  var pointAt: Vec2
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

  proc answered(f: FrameInfo): bool =
    let k = f.core.findPanel(MainPanel)
    let tiles = f.core.tiles(k)
    let p = f.core.panels[k]
    p.laidOut and tiles.len > 0 and tiles[^1].request == p.pending and
      p.pending.gen == p.requestGen

  proc traceX(f: FrameInfo; position: int): Vec2 =
    let plot = f.markOf("plot.data")
    let v = f.core.panels[f.core.findPanel(MainPanel)].view
    let x = plot.pos.x + float32((float64(position) - v.traces.lo) / v.traces.width) * plot.size.x
    vec2(round(x), round(plot.pos.y + 8))

  step("the record", noop, answered)
  step("over trace 1", proc (f: FrameInfo) = f.moveMouse(f.traceX(0)),
    proc (f: FrameInfo): bool = f.pick.found and f.pick.position == 0)
  step("the plot's focus", proc (f: FrameInfo) =
    pointAt = f.traceX(0)
    f.pressMouse(pointAt, true)
    f.pressMouse(pointAt, false), after(3))
  step("F", proc (f: FrameInfo) =
    f.pressKey(skF, true)
    f.pressKey(skF, false), after(3))
  step("the FFT window", noop, proc (f: FrameInfo): bool =
    f.core.spectra.len == 2 and f.markOf("fft 1.processed").size.x > 0 and
      not f.core.spectra[1].waiting and f.core.spectra[1].spectrum.raw.len > 0)
  step("no filter: stored, drawn unticked", noop, proc (f: FrameInfo): bool =
    let w = f.core.spectra[1]
    doAssert w.display.processed and w.display.response, "the stored choice is not ticked"
    doAssert not w.processing.hasFilters
    result = f.markOf("fft 1.processed").size.x > 0 and f.markOf("fft 1.response").size.x > 0
    if result:
      doAssert not f.ticked("fft 1.processed"), "processed drawn ticked while no filter is on"
      doAssert not f.ticked("fft 1.response"), "response drawn ticked while no filter is on")
  click("fft 1.processed")
  click("fft 1.response")
  step("a click did not overwrite the stored choice", noop, proc (f: FrameInfo): bool =
    let w = f.core.spectra[1]
    doAssert w.display.processed and w.display.response,
      "the stored Processed choice was overwritten"
    not f.ticked("fft 1.processed") and not f.ticked("fft 1.response"))
  let band = Processing(band: pbBandPass, f1: 8, f2: 12, f3: 40, f4: 50)
  step("a filter on", proc (f: FrameInfo) =
    f.apply(Command(kind: ckProcessing, panel: MainPanel, processing: band)),
    proc (f: FrameInfo): bool =
      let w = f.core.spectra[1]
      w.processing.hasFilters and not w.waiting and w.spectrum.processed.len > 0)
  step("the stored choice shows", noop, proc (f: FrameInfo): bool =
    let w = f.core.spectra[1]
    doAssert w.display.processed and w.display.response
    result = f.ticked("fft 1.processed") and f.ticked("fft 1.response")
    if not result:
      doAssert false, "filter on, the stored choice is not drawn")
  step("the plot's filters off", proc (f: FrameInfo) =
    f.apply(Command(kind: ckProcessing, panel: MainPanel, processing: Processing())),
    proc (f: FrameInfo): bool =
      not f.core.spectra[1].processing.hasFilters and not f.core.spectra[1].waiting)
  step("unticked again, choice kept", noop, proc (f: FrameInfo): bool =
    doAssert f.core.spectra[1].display.processed
    not f.ticked("fft 1.processed") and not f.ticked("fft 1.response"))
  let own = Processing(band: pbBandPass, f1: 8, f2: 12, f3: 40, f4: 50)
  step("the trace's own filter", proc (f: FrameInfo) =
    let base = f.core.sessions[0].base
    f.apply(Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base], on: true,
      processing: own, filterPlace: fpAfter)),
    proc (f: FrameInfo): bool =
      let w = f.core.spectra[1]
      f.core.ownChangesSamples(w) and not w.waiting and w.spectrum.processed.len > 0)
  step("an own filter enables Processed", noop, proc (f: FrameInfo): bool =
    doAssert f.core.spectra[1].display.processed
    doAssert not f.core.spectra[1].processing.hasFilters
    result = f.ticked("fft 1.processed")
    if not result:
      doAssert false, "an own filter did not enable Processed"
    doAssert f.core.spectra[1].spectrum.hasResponse and f.ticked("fft 1.response"),
      "one trace's own filter: its response is not drawn")

  var at = 0
  var started = false
  var wait = 0
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
      if wait >= 2 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 500, since):
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(openPaths: @[fx.spectrumSegy()],
    windowSize: (1600, 1000), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  echo "tguispectchecks: ok"
