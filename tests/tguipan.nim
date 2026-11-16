## Panning with the arrow keys shows data at once, headless, with real key
## events, on a wide shot (2000 traces of 5 s) zoomed in to 20 traces and
## 100 ms: before each key the tiles on hand already hold, at the view's
## resolution (the first tile, of the whole record, is coarser), the
## whole view a step of a whole view (Shift + arrow) would show, in each
## direction where the record goes on; and after each step (arrows, Shift +
## arrows, along the traces and in time, each once the reader has caught
## up) no frame shows paper where the record has data. A burst of arrow
## presses (a key held down) is followed too: the view's data is on hand
## again once the reads have come in.
##
## Seen to fail: with the read-ahead of half a view and a new request made
## only once the view leaves it (`ReadAhead` 0.5, `covers` without
## `keep`), "before Right 1: a whole view's step right is not on
## hand".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc onHand(f: FrameInfo; v: Viewport): bool =
  ## Whether the tiles on hand hold the data `v` shows, at the resolution it
  ## needs (a grid of points over the part of it the record has data in): a
  ## coarser tile, of the whole record, would be drawn there, a picture to
  ## be replaced, not the data.
  let k = f.core.findPanel(MainPanel)
  let p = f.core.panels[k]
  let need = requestFor(p.layout, v, readAhead = 0, wiggles = true)
  let lo = max(v.traces.lo, -0.5)
  let hi = min(v.traces.hi, float64(p.layout.traces) - 0.5)
  let t0 = max(v.timeMs.lo, p.layout.t0Ms)
  let t1 = min(v.timeMs.hi, p.layout.t0Ms + float64(p.layout.samples - 1) * p.layout.dtMs)
  if not (lo < hi and t0 < t1): return true
  const n = 16
  for i in 0 ..< n:
    for j in 0 ..< n:
      let x = lo + (hi - lo) * (float64(i) + 0.5) / n
      let t = t0 + (t1 - t0) * (float64(j) + 0.5) / n
      var hit = false
      for tl in f.core.tiles(k):
        if tl.contains(x, t) and tl.request.stride <= need.stride and
            tl.request.decimation <= need.decimation:
          hit = true
      if not hit: return false
  true

proc caughtUp(f: FrameInfo): bool =
  ## The reader answered the request sent last.
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen and
    f.tracePanel.drawnView.sameSpans(f.panel.view)

func shifted(v: Viewport; dx, dt: float64): Viewport =
  result = v
  result.traces = Span(lo: v.traces.lo + dx, hi: v.traces.hi + dx)
  result.timeMs = Span(lo: v.timeMs.lo + dt, hi: v.timeMs.hi + dt)

withFixtures fx:
  let path = fx.wideShotSegy()
  var steps: seq[Step]
  var at = 0
  var started = false
  var wait = 0 # frames since the step began, at `since`
  var since = getMonoTime()
  var failed = ""
  var paper = 0 # frames that showed paper since the step's key
  var paperFrames: seq[(string, int)]
  var burstPaper = 0
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard
  proc settled(n: int): proc (f: FrameInfo): bool =
    var quiet = 0
    result = proc (f: FrameInfo): bool =
      if f.caughtUp: inc quiet else: quiet = 0
      quiet >= n

  step("the record", noop, proc (f: FrameInfo): bool =
    result = f.panel.laidOut and f.caughtUp and f.markOf("plot.data").size.x > 0)
  step("zoomed in", proc (f: FrameInfo) =
    let v = f.panel.view
    f.showView(Viewport(traces: Span(lo: 999.5, hi: 1019.5), timeMs: Span(lo: 2000, hi: 2100),
      columns: v.columns, rows: v.rows)), settled(4))
  step("focus the plot", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("plot.data").centre), settled(2))
  step("click", proc (f: FrameInfo) =
    let c = f.markOf("plot.data").centre
    f.pressMouse(c, true)
    f.pressMouse(c, false), settled(3))
  step("click again", proc (f: FrameInfo) =
    let c = f.markOf("plot.data").centre
    f.pressMouse(c, true)
    f.pressMouse(c, false), settled(3))
  step("pointer away", proc (f: FrameInfo) =
    let d = f.markOf("plot.data")
    f.moveMouse(vec2(d.pos.x + 2, d.pos.y + 2)), settled(3))

  proc keyStep(name: string; key: SimKey; mods: set[SimMod]; whole: bool) =
    ## A key step taken once the reader has caught up: first, what a whole
    ## view's step would show is on hand; then no frame shows paper.
    step("before " & name, proc (f: FrameInfo) =
      let v = f.panel.view
      let lim = f.panel.viewLimits(v.columns)
      let w = v.traces.width
      let h = v.timeMs.width
      for (dx, dt, side) in [(w, 0.0, "right"), (-w, 0.0, "left"), (0.0, h, "down"),
          (0.0, -h, "up")]:
        let next = kept(v.shifted(dx, dt), lim)
        if not next.sameSpans(v):
          doAssert f.onHand(next), "before " & name & ": a whole view's step " & side &
            " is not on hand"
      paper = 0
      f.pressKey(key, true, mods), proc (f: FrameInfo): bool =
        if not f.onHand(f.tracePanel.drawnView): inc paper
        result = true)
    step(name, proc (f: FrameInfo) = f.pressKey(key, false, mods), proc (f: FrameInfo): bool =
      if not f.onHand(f.tracePanel.drawnView): inc paper
      result = f.caughtUp and paper >= 0
      if result: paperFrames.add (name, paper))
    step("settle after " & name, noop, settled(3))

  for i in 1 .. 3: keyStep("Right " & $i, skRight, {}, false)
  for i in 1 .. 4: keyStep("Shift+Right " & $i, skRight, {smShift}, true)
  for i in 1 .. 2: keyStep("Shift+Left " & $i, skLeft, {smShift}, true)
  for i in 1 .. 3: keyStep("Down " & $i, skDown, {}, false)
  for i in 1 .. 3: keyStep("Shift+Down " & $i, skDown, {smShift}, true)
  keyStep("Shift+Up", skUp, {smShift}, true)
  # a burst of presses, a frame apart, as a key held down sends them
  for i in 1 .. 12:
    step("burst " & $i, proc (f: FrameInfo) = f.pressKey(skRight, true),
      proc (f: FrameInfo): bool =
      if not f.onHand(f.tracePanel.drawnView): inc burstPaper
      true)
    step("burst up " & $i, proc (f: FrameInfo) = f.pressKey(skRight, false),
      proc (f: FrameInfo): bool =
      if not f.onHand(f.tracePanel.drawnView): inc burstPaper
      true)
  step("after the burst", noop, proc (f: FrameInfo): bool =
    result = f.caughtUp and f.onHand(f.tracePanel.drawnView))

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
      if steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 300, since):
        failed = steps[at].name & " did not happen"
        f.stop()

  let code = run(RunOptions(openPaths: @[path], windowSize: (1400, 900),
    theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  var total = 0
  for (name, n) in paperFrames:
    total += n
    doAssert n == 0, name & ": " & $n & " frames showed paper"
  echo "tguipan: ", paperFrames.len, " key steps, ", total, " frames with paper; a burst of 12 ",
    "presses: ", burstPaper, " frames with paper"
