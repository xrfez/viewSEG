## The plot turned in the running frontend, headless, driven by SDL events
## as the user's mouse and keyboard send them: a zoomed-in plot of the
## fixture's record is turned by the strip's toggle, and
##
## - it shows the same traces and times, nothing is read for it (no new
##   request, no tile taken in) and no texture is uploaded again; the image
##   is the plot's size the other way round;
## - time runs along the bottom and the traces down: the trace under the
##   pointer is the one at its row, the status bar's time the one at its
##   column; the scroll bars are time's below the plot and the traces' at
##   its right, each thumb where the view lies along it;
## - the display header stands beside the plot, a column per field left of
##   it, the first field farthest;
## - the cursor's time line runs from the pointer down to the time axis,
##   with the time under the plot, and the header's boxes stand at the
##   trace's row in each column, with its values;
## - the wheel with Ctrl zooms up and down (the traces), with Shift across
##   (time); the arrow keys pan the way they point; a drag carries the data
##   with the pointer; a right drag zooms to the box; dragging the traces'
##   thumb down shows later traces;
## - every display mode, with a trace hovered, two selected, one killed and
##   the traces sorted, is the CPU reference's picture, transposed
##   (`tests/utils/plotref` reads the image through the plot's turn);
## - turned back, it shows the same traces and times again, time down.
##
## Seen to fail: with a turn taken as a new plot size (`resized`), "turn"
## found the view's time 145 to 998 ms where it was 244 to 754; with the
## cursor's line drawn across as when time is down, "pointer on a trace"
## found it across the plot; with the scroll bars placed by data axis (the
## traces' always below), "turn" found time's bar at the plot's right; with
## the arrow keys panning along the data's axes, not the screen's, "right
## arrow" moved the traces; with the header's bands laid out as rows above
## the plot, "turn" found its bands out of order.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves turn-*.png there, and with the example
## files present the Morgantown and sweep pilot screenshots, both ways, and
## frame times while panning in each orientation.

import std/[algorithm, math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/view/[displayheader, timeaxis]
import viewSEG/ui/imgui/app
import utils/[fixtures, plotref]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func near(a, b: float64; eps = 1e-4): bool = abs(a - b) <= eps * max(1.0, abs(b))

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

func bottom(r: Rect): float32 = r.pos.y + r.size.y
func right(r: Rect): float32 = r.pos.x + r.size.x

proc main() =
  withFixtures fx:
    let path = fx.surveySegy()
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var failed = ""
    var plot: Rect # the plot's data area, framebuffer pixels
    var q: Vec2 # a point over the plot
    var was: Viewport # the view before a step
    var gen, taken, uploads: int
    var shots: seq[(string, int, int)] # pixel checks: name, pixels off, looked at
    var drawnAt = 0 # images drawn when a picture was asked for
    let dir = getEnv("VIEWSEG_SCREENSHOTS")

    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

    proc answered(f: FrameInfo): bool =
      let tiles = f.core.tiles(f.core.findPanel(MainPanel))
      tiles.len > 0 and tiles[^1].request == f.panel.pending and
        f.tracePanel.drawnView.sameSpans(f.panel.view)

    proc turn(f: FrameInfo): Turn = f.panel.layers[0].display.turn

    proc changed(f: FrameInfo): bool =
      not f.panel.view.sameSpans(was) and f.tracePanel.drawnView.sameSpans(f.panel.view)

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc click(f: FrameInfo; at: Vec2; button = 1) =
      f.pressMouse(at, true, button)
      f.pressMouse(at, false, button)

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

    proc counts(f: FrameInfo): (int, int, int) =
      (int(f.panel.requestGen), f.core.tilesTaken, f.tracePanel.tilesUploaded)

    proc display(f: FrameInfo; change: proc (d: var DisplaySettings)) =
      var d = f.panel.layers[0].display
      change(d)
      f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)

    proc quiet(f: FrameInfo): bool =
      ## Two frames without a new image, and the view's tiles drawn.
      result = f.answered and f.tracePanel.imagesDrawn == drawnAt
      drawnAt = f.tracePanel.imagesDrawn

    proc picture(name: string) =
      ## The plot as it is now against the CPU reference, read through its
      ## turn (and saved, with `VIEWSEG_SCREENSHOTS`).
      step(name, proc (f: FrameInfo) = drawnAt = -1, proc (f: FrameInfo): bool =
        result = f.quiet and drawnAt >= 0 and wait >= 4
        if result:
          let s = f.capture
          doAssert s.turn == f.turn
          let (off, seen) = s.mismatches
          shots.add (name, off, seen)
          if dir.len > 0:
            createDir(dir)
            doAssert f.savePng(dir / ("turn-" & name.replace(' ', '-') & ".png")))

    # -------------------------------------------------------------- steps --
    step("the file opens", noop, proc (f: FrameInfo): bool =
      result = f.panel.laidOut and f.answered and f.markOf("plot.data").size.x > 0
      if result: plot = f.markOf("plot.data"))

    step("the cursor's time line on", proc (f: FrameInfo) =
      f.moveMouse(centre(f.markOf("plot.Cursor time line")))
      f.click(centre(f.markOf("plot.Cursor time line"))), proc (f: FrameInfo): bool =
      f.core.settings.cursorLine)

    step("zoom in", proc (f: FrameInfo) =
      was = f.panel.view
      f.moveMouse(centre(plot))
      f.scrollWheel(centre(plot), 3), proc (f: FrameInfo): bool =
      result = f.changed and f.answered
      if result:
        doAssert f.markOf("plot.bar.traces").size.x > 0 and f.markOf("plot.bar.time").size.x > 0)

    step("turn", proc (f: FrameInfo) =
      was = f.panel.view
      (gen, taken, uploads) = f.counts
      f.moveMouse(centre(f.markOf("plot.Time across")))
      f.click(centre(f.markOf("plot.Time across"))), proc (f: FrameInfo): bool =
      result = f.turn.orientation == orTimeAcross and f.markOf("plot.data").size.x > 0 and
        f.tracePanel.drawnView.columns == int(round(f.markOf("plot.data").size.y)) and
        f.tracePanel.drawnView.sameSpans(f.panel.view) and
        f.panel.view.columns == f.tracePanel.drawnView.columns
      if result:
        plot = f.markOf("plot.data")
        let v = f.panel.view
        # the same traces and times, nothing read, no texture made again
        doAssert v.traces == was.traces and v.timeMs == was.timeMs,
          "the view moved at the turn: " & $v & " was " & $was
        doAssert f.counts == (gen, taken, uploads), "read at the turn: " & $f.counts & " was " &
          $(gen, taken, uploads)
        # the plot's pixels the other way round
        doAssert v.columns == int(round(plot.size.y)) and v.rows == int(round(plot.size.x))
        let (_, w, h) = f.tracePanel.plotImage
        doAssert (w, h) == (int(round(plot.size.x)), int(round(plot.size.y))), $(w, h)
        # time's bar below the plot, the traces' at its right
        let (bt, bx) = (f.markOf("plot.bar.time"), f.markOf("plot.bar.traces"))
        doAssert bt.pos.y >= plot.bottom and near(bt.size.x, plot.size.x, 0.01),
          "time's bar " & $bt & " for the plot " & $plot
        doAssert bx.pos.x >= plot.right and near(bx.size.y, plot.size.y, 0.01),
          "the traces' bar " & $bx & " for the plot " & $plot
        let lim = f.panel.viewLimits(v.columns)
        for (a, bar, thumb, along) in [(axTime, bt, f.markOf("plot.thumb.time"), saX),
            (axTraces, bx, f.markOf("plot.thumb.traces"), saY)]:
          let b = lim[a].bounds
          let want = (v.span(a).lo - b.lo) / (b.width - v.span(a).width)
          let (start, length, track) = if along == saX:
              (thumb.pos.x - bar.pos.x, thumb.size.x, bar.size.x)
            else: (thumb.pos.y - bar.pos.y, thumb.size.y, bar.size.y)
          doAssert abs(start / (track - length) - want) < 0.02,
            $a & "'s thumb at " & $(start / (track - length)) & ", the view at " & $want
        # the header's columns left of the plot, the first field farthest
        let fields = f.panel.shownFields
        var left = 0'f32
        for i, field in fields:
          let band = f.markOf("plot.header." & $field)
          doAssert band.size.x > 0 and band.right <= plot.pos.x + 1 and
            near(band.pos.y, plot.pos.y, 0.01) and near(band.size.y, plot.size.y, 0.01),
            $field & "'s band " & $band & " for the plot " & $plot
          doAssert band.pos.x >= left, "the header's columns out of order"
          left = band.right)

    step("pointer on a trace", proc (f: FrameInfo) =
      q = vec2(round(plot.pos.x + plot.size.x * 0.4), round(plot.pos.y + plot.size.y * 0.3))
      f.moveMouse(q), proc (f: FrameInfo): bool =
      let p = f.pick
      result = p.inside and p.found and f.tracePanel.cursorText.len > 0 and
        f.markOf("plot.cursor line").size.y > 0
      if result:
        let v = f.panel.view
        # by hand: the traces down from the top, time from the left
        let x = v.traces.lo + (float64(q.y) - plot.pos.y) / plot.size.y * v.traces.width
        let tm = v.timeMs.lo + (float64(q.x) - plot.pos.x) / plot.size.x * v.timeMs.width
        doAssert near(p.at.x, x) and near(p.at.tMs, tm), $p.at & " not " & $(x, tm)
        doAssert p.position == int(round(x)) and p.trace == p.position
        doAssert f.tracePanel.cursorText == cursorTimeText(tm, DtMs)
        # the line from the pointer down to the time axis, the time under it
        let line = f.markOf("plot.cursor line")
        doAssert line.size.x <= 2 and abs(line.pos.x - q.x) <= 1 and
          abs(line.pos.y - q.y) <= 1 and abs(line.bottom - plot.bottom) <= 1,
          "the line " & $line & " for the pointer " & $q & " on the plot " & $plot
        let box = f.markOf("plot.cursor time")
        doAssert box.pos.y >= plot.bottom - 1 and box.pos.x <= q.x and box.right >= q.x,
          "the time's box " & $box
        # the header's boxes at the trace's row, in each column
        let row = v.screenAt(plot, DataPoint(x: float64(p.position), tMs: tm), f.turn).y
        doAssert f.tracePanel.cursorHeader == @[$FirstRecord, $(p.position + 1)],
          $f.tracePanel.cursorHeader
        for field in f.panel.shownFields:
          let b = f.markOf("plot.cursor header " & $field)
          let band = f.markOf("plot.header." & $field)
          doAssert b.pos.y <= row and b.bottom >= row and b.pos.x >= band.pos.x - 1 and
            b.right <= band.right + 1, $field & ": the box " & $b & " for the row " & $row)

    step("ctrl wheel zooms the traces", proc (f: FrameInfo) =
      was = f.panel.view
      f.pressKey(skCtrl, true, {smCtrl})
      f.scrollWheel(q, 1), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        doAssert v.timeMs == was.timeMs, "Ctrl + wheel changed the time"
        doAssert near(v.traces.width, was.traces.width / WheelStep), $v
        f.pressKey(skCtrl, false))

    step("shift wheel zooms time", proc (f: FrameInfo) =
      was = f.panel.view
      f.pressKey(skShift, true, {smShift})
      f.scrollWheel(q, 1), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        doAssert v.traces == was.traces, "Shift + wheel changed the traces"
        doAssert near(v.timeMs.width, was.timeMs.width / WheelStep), $v
        f.pressKey(skShift, false))

    step("focus the plot", proc (f: FrameInfo) = f.click(q), proc (f: FrameInfo): bool = true)

    step("right arrow", proc (f: FrameInfo) =
      was = f.panel.view
      f.chord(skRight), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        doAssert v.traces == was.traces, "the right arrow moved the traces"
        doAssert near(v.timeMs.lo, was.timeMs.lo + PanStep * was.timeMs.width), $v)

    step("down arrow", proc (f: FrameInfo) =
      was = f.panel.view
      f.chord(skDown), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        doAssert v.timeMs == was.timeMs, "the down arrow moved the time"
        doAssert near(v.traces.lo, was.traces.lo + PanStep * was.traces.width), $v)

    step("drag", proc (f: FrameInfo) =
      was = f.panel.view
      f.pressMouse(q, true)
      f.moveMouse(vec2(q.x - 40, q.y - 30)), proc (f: FrameInfo): bool =
      result = f.changed
      if result:
        let v = f.panel.view
        let grabbed = was.dataAt(plot, q, f.turn)
        let now = v.dataAt(plot, vec2(q.x - 40, q.y - 30), f.turn)
        doAssert near(now.x, grabbed.x) and near(now.tMs, grabbed.tMs), $now & " " & $grabbed
        f.pressMouse(vec2(q.x - 40, q.y - 30), false))

    step("box zoom", proc (f: FrameInfo) =
      was = f.panel.view
      f.moveMouse(q)
      f.pressMouse(q, true, 3), proc (f: FrameInfo): bool =
      if wait == 3: f.moveMouse(vec2(q.x + 120, q.y + 60))
      if wait == 6: f.pressMouse(vec2(q.x + 120, q.y + 60), false, 3)
      result = wait > 6 and f.changed
      if result:
        let v = f.panel.view
        # the box's time across, its traces down (at least `MinTraces` of them)
        let (a, b) = (was.dataAt(plot, q, f.turn), was.dataAt(plot, vec2(q.x + 120, q.y + 60),
          f.turn))
        doAssert near(v.timeMs.lo, a.tMs) and near(v.timeMs.hi, b.tMs), $v
        let want = was.boxed(a, b, BothAxes, f.panel.viewLimits(v.columns))
        doAssert near(v.traces.lo, want.traces.lo) and near(v.traces.hi, want.traces.hi) and
          v.traces.lo <= min(a.x, b.x) + 1e-9 and v.traces.hi >= max(a.x, b.x) - 1e-9, $v)

    step("drag the traces' thumb down", proc (f: FrameInfo) =
      was = f.panel.view
      let thumb = f.markOf("plot.thumb.traces")
      f.moveMouse(centre(thumb))
      f.pressMouse(centre(thumb), true), proc (f: FrameInfo): bool =
      let thumb = f.markOf("plot.thumb.traces")
      if wait == 3: f.moveMouse(vec2(centre(thumb).x, centre(thumb).y + 25))
      result = wait > 3 and f.changed
      if result:
        doAssert f.panel.view.traces.lo > was.traces.lo and f.panel.view.timeMs == was.timeMs
        f.pressMouse(vec2(centre(thumb).x, centre(thumb).y), false))

    step("hover, select, kill, sort", proc (f: FrameInfo) =
      let base = f.core.sessions[0].base
      f.moveMouse(q)
      f.apply Command(kind: ckSelect, traces: @[base + 3, base + 9], mode: smReplace)
      f.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base + 6],
        on: true)
      f.apply Command(kind: ckSort, panel: MainPanel,
        order: @[SortKey(field: hfChannel, descending: true)])
      f.showView(Viewport(traces: Span(lo: -0.5, hi: 23.5), timeMs: f.panel.view.timeMs)),
      proc (f: FrameInfo): bool = f.answered and not f.core.sorting(f.core.findPanel(MainPanel)))
    proc modeSteps(m: DisplayMode) =
      # a proc per mode: closures made in a loop would share its variable
      step("mode " & $m, proc (f: FrameInfo) = f.display(proc (d: var DisplaySettings) =
        d.mode = m), proc (f: FrameInfo): bool = f.panel.layers[0].display.mode == m)
      picture("across " & $m)
    for mode in DisplayMode: modeSteps(mode)

    step("turn back", proc (f: FrameInfo) =
      was = f.panel.view
      (gen, taken, uploads) = f.counts
      f.moveMouse(centre(f.markOf("plot.Time across")))
      f.click(centre(f.markOf("plot.Time across"))), proc (f: FrameInfo): bool =
      result = f.turn.orientation == orTimeDown and
        f.tracePanel.drawnView.columns == int(round(f.markOf("plot.data").size.x)) and
        f.tracePanel.drawnView.sameSpans(f.panel.view)
      if result:
        plot = f.markOf("plot.data")
        doAssert f.panel.view.traces == was.traces and f.panel.view.timeMs == was.timeMs
        doAssert f.counts == (gen, taken, uploads), "read at the turn back"
        let band = f.markOf("plot.header.FFID")
        doAssert band.bottom <= plot.pos.y + 1 and near(band.size.x, plot.size.x, 0.01),
          "time down: the header's rows above the plot")
    picture("down wiggle over density")

    proc onFrame(f: FrameInfo) =
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
        elif wait > 400:
          failed = steps[at].name & " did not happen"
          f.stop()

    let code = run(RunOptions(maxFrames: 8000, openPaths: @[path], windowSize: (1280, 900),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    for (name, off, seen) in shots:
      echo "tguiturn: ", name, ": ", off, " of ", seen, " pixels off the reference"
    doAssert shots.len == 4
    for (name, off, seen) in shots:
      doAssert off == 0, name & ": " & $off & " of " & $seen & " pixels off the reference"

main()

# ------------------------------------- real data: screenshots, frame times --
# With `VIEWSEG_SCREENSHOTS=<dir>` and the example files present (local
# only), the Morgantown record and the sweep pilot are saved both ways, and
# the frame times while panning along the traces are measured in each
# orientation (the time between frames, a key held down).

const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

proc realShots(path, name: string; view: Viewport; measure: bool) =
  ## Opens `path` in a 1600 x 1000 window, shows `view` and saves
  ## turn-`name`-down.png, turns the plot and saves turn-`name`-across.png;
  ## or, with `measure`, holds the key that pans along the traces for 150
  ## frames in each orientation and prints the frame times.
  let dir = getEnv("VIEWSEG_SCREENSHOTS")
  let tmp = getTempDir() / ("viewseg_tguiturn_" & $getCurrentProcessId())
  var stage = 0
  var settle = 0
  var frames: seq[float64]
  var last = getMonoTime()
  var times: array[Orientation, seq[float64]]
  proc onFrame(f: FrameInfo) =
    let k = f.core.findPanel(MainPanel)
    let now = getMonoTime()
    let dt = float64((now - last).inNanoseconds) / 1e6
    last = now
    if k < 0 or f.core.panels[k].layers.len == 0: return # no file shown yet
    let p = f.core.panels[k]
    let tiles = f.core.tiles(k)
    let answered = p.laidOut and tiles.len > 0 and tiles[^1].request == p.pending and
      f.tracePanel.drawnView.sameSpans(p.view)
    let o = p.layers[0].display.orientation
    case stage
    of 0:
      if p.laidOut and p.layout.traces == 0 and p.layers[0].filter.seismic:
        # a pilot is an auxiliary trace: Aux alone, each trace at its own
        # level (the record's level counts seismic traces only)
        f.apply Command(kind: ckFilter, panel: MainPanel,
          filter: TraceFilter(seismic: false, auxiliary: true))
        var d = p.layers[0].display
        d.gain = dgNormalized
        d.gainDb = -9 # most of the sweep within its trace spacing
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      elif p.laidOut and p.layout.traces > 0:
        f.showView(view)
        f.moveMouse(vec2(5, 5)) # off the plot: nothing hovered (measuring, it clicks)
        stage = 1
    of 1, 3:
      if answered and f.tracePanel.drawnView.sameSpans(p.view):
        inc settle
        if settle == 5 and measure: # the plot takes the keys once it has the focus
          let c = f.markOf("plot.data")
          let at = vec2(round(c.pos.x + 300), round(c.pos.y + 120))
          f.moveMouse(at)
          f.pressMouse(at, true)
          f.pressMouse(at, false)
        if settle > 10:
          let c = f.markOf("plot.data")
          if stage == 1:
            echo "tguiturn: ", name, " time down: the plot ", c.size.x, " x ", c.size.y,
              " pixels, ", p.view.traces.width, " traces"
          else:
            echo "tguiturn: ", name, " time across: the plot ", c.size.x, " x ", c.size.y,
              " pixels, ", p.view.traces.width, " traces"
          if not measure:
            doAssert f.savePng(dir / ("turn-" & name & "-" & (if o == orTimeDown: "down"
              else: "across") & ".png"))
          settle = 0
          if measure:
            # pan along the traces: right when time is down, down when across
            f.pressKey(if o == orTimeDown: skRight else: skDown, true)
            frames.setLen 0
            stage = if stage == 1: 10 else: 30
          else: stage = if stage == 1: 2 else: 4
    of 10, 30:
      frames.add dt
      if frames.len >= 150:
        f.pressKey(if o == orTimeDown: skRight else: skDown, false)
        times[o] = frames
        stage = if stage == 10: 2 else: 4
    of 2:
      var d = p.layers[0].display
      d.orientation = orTimeAcross
      f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      f.showView(view)
      stage = 3
    else: f.stop()
  let code = run(RunOptions(maxFrames: 3000, openPaths: @[path], windowSize: (1600, 1000),
    theme: forceDark, indexCacheDir: some(tmp), userThemeDir: some(tmp / "no-user-themes"),
    onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0 and stage >= 4, "no screenshots of " & path & " (stage " & $stage & ")"
  if measure:
    for o in Orientation:
      var s = times[o]
      s.sort
      echo "tguiturn: ", name, " panning along the traces, ", o, ": median ",
        formatFloat(s[s.len div 2], ffDecimal, 1), " ms, 90 % ",
        formatFloat(s[s.len * 9 div 10], ffDecimal, 1), " ms, slowest ",
        formatFloat(s[^1], ffDecimal, 1), " ms (", s.len, " frames)"

if getEnv("VIEWSEG_SCREENSHOTS").len > 0:
  createDir(getEnv("VIEWSEG_SCREENSHOTS"))
  let morgantown = examples / "00000151_12900_11300.sgd"
  if fileExists(morgantown):
    # lines 100 to 108 near the source: the first breaks and the ground roll
    realShots(morgantown, "morgantown", Viewport(traces: Span(lo: 99.5, hi: 159.5),
      timeMs: Span(lo: 0, hi: 1500)), measure = false)
    realShots(morgantown, "morgantown", Viewport(traces: Span(lo: 1000, hi: 1400),
      timeMs: Span(lo: 0, hi: 2000)), measure = true)
  let sweep = examples / "Sweep0.sgy"
  if fileExists(sweep):
    realShots(sweep, "pilot", Viewport(traces: Span(lo: -1, hi: 1e9),
      timeMs: Span(lo: 0, hi: 600)), measure = false)
