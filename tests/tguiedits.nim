## Killing traces and reversing their polarity in the running frontend,
## headless, driven by SDL mouse and key events, on the survey fixture with
## the gain None (the samples as they are), wiggles without fills at
## overlap 0.5 (so no neighbour reaches into a trace's own half spacing):
##
## - a right click on a trace opens the plot's menu with the trace
##   operations, the polarity of every trace, Undo, Redo and Clear all
##   edits for this file; Kill there kills it: the trace is blank (every
##   pixel within 0.4 of a trace spacing of its baseline is the paper), the
##   image is what the CPU reference draws from the tiles, the display
##   header has a row of edits with "K" over that trace, and the status bar
##   says "killed" over it; Ctrl + Z brings it back, pixel for pixel, and
##   the row goes;
## - Reverse polarity from the menu mirrors the trace: at every time its
##   line lies as far from the baseline as before, on the other side, and
##   its tile row is the negated row;
## - in density, `K` on the trace under the pointer blanks its column (the
##   paper), and `R` mirrors the grey of another (black where it was white);
##   Ctrl + Z undoes only the last; Clear all edits for this file gives the
##   picture as the file has it;
## - the same in a panel sorted by channel, descending, where a position
##   is another trace: the menu names the trace drawn there, and the
##   header's mark stands over it;
## - the file is never changed.
##
## With the Morgantown example present (local only), the time from a key to
## the new picture is measured, zoomed in on 40 traces, and with
## `VIEWSEG_SCREENSHOTS=<dir>` that record is saved with one trace killed and
## one reversed (`edits-morgantown.png`, `edits-morgantown-density.png`).
##
## Seen to fail: with the wiggle shader drawing killed traces (its collapse
## left out: a flat line at the baseline), "killed: 350 pixels of the
## trace's band are not the paper"; with the density shader not blanking
## them (mid grey), "killed density: 3072 of 76032 pixels off the
## reference"; with the menu's Kill sending nothing, "killed did not
## happen"; with the Edit menu's Ctrl+Z left out (`drawMainMenu`'s
## shortcuts), "Ctrl+Z did not happen"; with the display
## header's row of edits left out, "no mark of the edit over trace 10";
## with the status bar not saying the edits, "the status bar does not say
## killed".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
##
## Runs alone: it measures the time from a key to the new picture (on
##   Morgantown, where exampleFiles/ holds it).

import std/[algorithm, math, monotimes, options, os, sequtils, strutils, tables, times]
import viewSEG/core/[geometry, state]
import viewSEG/view/plotink
import viewSEG/ui/imgui/app
import utils/[fixtures, plotref]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc band(s: Shot; position: float64; share = 0.4): Slice[int] =
  ## The image columns within `share` of a trace spacing of `position`'s
  ## baseline.
  let ppt = float64(s.w) / s.view.traces.width
  let c = (position - s.view.traces.lo) * ppt - 0.5
  int(ceil(c - share * ppt)) .. int(floor(c + share * ppt))

proc inked(s: Shot; position: float64): int =
  ## Pixels within 0.4 of a trace spacing of `position`'s baseline that are
  ## not the paper.
  for j in 0 ..< s.h:
    for i in s.band(position):
      if not close(s.at(i, j), s.ink.background): inc result

proc offsetAt(s: Shot; position: float64; j: int): float64 =
  ## Where the ink lies in row `j` of `position`'s band: its darkness-weighted
  ## mean, in pixels right of the baseline; NaN for none.
  let ppt = float64(s.w) / s.view.traces.width
  let c = (position - s.view.traces.lo) * ppt - 0.5
  var sum, weight = 0.0
  for i in s.band(position):
    let v = s.at(i, j)
    let dark = 1 - (float64(v.r) + float64(v.g) + float64(v.b)) / (3 * 255)
    sum += dark * (float64(i) - c)
    weight += dark
  if weight > 0.3: sum / weight else: NaN

proc offsetAtTime(s: Shot; position, tMs: float64): float64 =
  ## `offsetAt` at time `tMs`, between the rows whose centres lie either
  ## side of it; NaN where either has no ink.
  let u = (tMs - s.view.timeMs.lo) / s.view.timeMs.width * float64(s.h) - 0.5
  let j = int(floor(u))
  if j < 0 or j + 1 >= s.h: return NaN
  let f = u - float64(j)
  s.offsetAt(position, j) * (1 - f) + s.offsetAt(position, j + 1) * f

proc mirrored(after, before: Shot; position: float64): (int, int) =
  ## Rows of `after` whose line lies at least 3 pixels off `position`'s
  ## baseline in `before` at the same time, and those of them where it lies
  ## on the other side, as far off within 1.5 pixels.
  for j in 0 ..< after.h:
    let now = after.offsetAt(position, j)
    let was = before.offsetAtTime(position, after.tOf(j))
    if not now.isNaN and abs(was) >= 3:
      inc result[0]
      if abs(now + was) <= 1.5: inc result[1]

proc greyMirrored(after, before: Shot; position: float64): (int, int) =
  ## Rows of `after` at `position`'s column centre, and those whose grey is
  ## the one `before`'s tiles give at the same time turned over (black where
  ## it was white), within the tolerance. (From the tiles, not `before`'s
  ## pixels: the two plots may differ in height, the edits row of the
  ## display header coming and going, and a pixel row's time with them.)
  let i = after.column(position)
  for j in 0 ..< after.h:
    let t = after.tOf(j)
    var grey = -1
    for k in countdown(before.tiles.high, 0):
      if grey < 0 and before.tiles[k].contains(position, t):
        grey = int(before.tiles[k].densityAt(greyLut(), position, t, before.scale,
          before.ink.background).r)
    if grey >= 0:
      inc result[0]
      if abs(int(after.at(i, j).r) + grey - 255) <= Tolerance:
        inc result[1]

proc same(a, b: Shot; position: float64): int =
  ## Pixels of `position`'s band that differ between `a` and `b`.
  doAssert a.w == b.w and a.h == b.h and a.view.sameSpans(b.view), "not the same view"
  for j in 0 ..< a.h:
    for i in a.band(position):
      if not close(a.at(i, j), b.at(i, j)): inc result

proc rowValues(s: Shot; trace: int): (int, int, seq[float32]) =
  ## The newest tile's values of trace `trace` (its index in the file), with
  ## the sample of the first and the decimation.
  let t = s.tiles[^1]
  let r = t.traces.find(trace)
  doAssert r >= 0, "trace " & $(trace + 1) & " is not in the newest tile"
  (t.request.firstSample, t.request.decimation, t.data[r * t.columns ..< (r + 1) * t.columns])

proc negated(after, before: Shot; trace: int): bool =
  ## Whether `after`'s values of `trace` are `before`'s negated, sample for
  ## sample where both have one.
  let (a0, ad, a) = after.rowValues(trace)
  let (b0, bd, b) = before.rowValues(trace)
  doAssert ad == 1 and bd == 1, "decimated"
  var n = 0
  for j, v in a:
    let k = a0 + j - b0
    if k in 0 ..< b.len:
      if v != -b[k]: return false
      inc n
  n > 100

withFixtures fx:
  let path = fx.surveySegy()
  let before = (readFile(path), getLastModificationTime(path))
  var steps: seq[Step]
  var at = 0
  var started = false
  var wait = 0
  var failed = ""
  var shots: Table[string, Shot]

  template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

  proc answered(f: FrameInfo): bool =
    let p = f.panel
    let tiles = f.core.tiles(f.core.findPanel(MainPanel))
    p.laidOut and not p.pending.isEmpty and p.pending.gen == p.requestGen and tiles.len > 0 and
      tiles[^1].request == p.pending and f.tracePanel.drawnView.sameSpans(p.view)

  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)

  proc noop(f: FrameInfo) = discard

  proc pointAt(f: FrameInfo; position: int; tMs = 702.0): Vec2 =
    let v = f.panel.view.screenAt(f.markOf("plot.data"), DataPoint(x: float64(position),
      tMs: tMs))
    vec2(round(v.x), round(v.y))

  proc click(f: FrameInfo; q: Vec2; button = 1) =
    f.pressMouse(q, true, button)
    f.pressMouse(q, false, button)

  proc chord(f: FrameInfo; key: SimKey; mods: set[SimMod] = {}) =
    ## `key` pressed and released with `mods` held, the modifiers first.
    const modKeys: array[SimMod, SimKey] = [skCtrl, skShift, skAlt]
    for m in mods: f.pressKey(modKeys[m], true, mods)
    f.pressKey(key, true, mods)
    f.pressKey(key, false, mods)
    for m in mods: f.pressKey(modKeys[m], false)

  proc look(mode: DisplayMode; fills: set[WiggleFill]): proc (f: FrameInfo) =
    result = proc (f: FrameInfo) =
      var d = f.panel.layers[0].display
      (d.mode, d.fills, d.overlap, d.gain) = (mode, fills, 0.5, dgNone)
      f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)

  proc traceOf(f: FrameInfo; trace: int): int = f.core.sessions[0].base + trace

  proc shootStep(name: string) =
    step("shot " & name, proc (f: FrameInfo) = f.moveMouse(vec2(4, 4)),
      proc (f: FrameInfo): bool =
      result = f.answered and wait > 6 and f.core.selection.hover < 0
      if result: shots[name] = f.capture)

  proc waitEdits(name: string; trace: int; want: set[TraceEdit]) =
    ## Waits until `trace` has the edits `want` and the view's tile, drawn,
    ## was made with them.
    step(name, noop, proc (f: FrameInfo): bool =
      if f.core.traceEdits(f.traceOf(trace)) != want or not f.answered or wait < 4: return false
      let t = f.core.tiles(f.core.findPanel(MainPanel))[^1]
      let r = t.traces.find(trace)
      r >= 0 and t.editsAt(r) == want)

  proc menuStep(name: string; position: int; target, item: string) =
    ## A right click on `position`, the menu checked, then `item` clicked.
    var q: Vec2
    step(name & ": point", proc (f: FrameInfo) =
      q = f.pointAt(position)
      f.moveMouse(q), proc (f: FrameInfo): bool = wait > 3)
    step(name & ": the menu opens", proc (f: FrameInfo) = f.click(q, button = 3),
      proc (f: FrameInfo): bool =
      result = f.markOf("plot.menu").size.x > 0 and wait > 3
      if result:
        var marks: seq[string]
        for n in ["target", "reverse", "kill", "fft", "reverse all", "undo", "clear"]:
          if f.markOf("plot.menu." & n).size.x > 0: marks.add n
        doAssert marks.len == 7, "the menu holds " & $marks
        doAssert f.tracePanel.menuTarget == target, "the menu acts on " &
          f.tracePanel.menuTarget & ", not " & target)
    var item0: Vec2
    step(name & ": point at it", proc (f: FrameInfo) =
      item0 = f.markOf("plot.menu." & item).centre
      f.moveMouse(item0), proc (f: FrameInfo): bool = wait > 2)
    step(name, proc (f: FrameInfo) = f.click(item0), proc (f: FrameInfo): bool =
      f.markOf("plot.menu").size.x == 0)

  proc keyStep(name: string; position: int; key: SimKey; mods: set[SimMod] = {}) =
    var q: Vec2
    step(name & ": point", proc (f: FrameInfo) =
      q = f.pointAt(position)
      f.moveMouse(q), proc (f: FrameInfo): bool = wait > 3 and f.pick.found)
    step(name, proc (f: FrameInfo) = f.chord(key, mods), proc (f: FrameInfo): bool = true)

  proc headerMarkStep(name: string; position, trace: int) =
    ## The display header's row of edits marks trace `trace` over `position`.
    step(name, noop, proc (f: FrameInfo): bool =
      result = wait > 4
      if result:
        let m = f.markOf("plot.header.edit " & $(trace + 1))
        doAssert m.size.x > 0, "no mark of the edit over trace " & $(trace + 1)
        doAssert f.markOf("plot.header.edits").size.x > 0, "the row has no name"
        let x = f.pointAt(position).x
        let spacing = f.markOf("plot.data").size.x / float32(f.panel.view.traces.width)
        doAssert abs(m.pos.x + m.size.x / 2 - x) <= spacing / 2, "the mark of trace " &
          $(trace + 1) & " is at " & $(m.pos.x + m.size.x / 2) & ", the trace at " & $x
        let data = f.markOf("plot.data")
        doAssert m.pos.y + m.size.y <= data.pos.y + 1, "the mark is not above the plot")

  # -------------------------------------------------------------- steps --
  step("the file opens", noop, proc (f: FrameInfo): bool = f.answered)
  step("wiggles, no fills", look(dmWiggle, {}), proc (f: FrameInfo): bool =
    f.answered and f.panel.layers[0].display.gain == dgNone and wait > 3)
  var q0: Vec2
  step("focus the plot", proc (f: FrameInfo) =
    q0 = f.pointAt(0)
    f.moveMouse(q0), proc (f: FrameInfo): bool = wait > 3)
  # the click that brings the window forward selects nothing; the next one does
  step("a focusing click", proc (f: FrameInfo) = f.click(q0), proc (f: FrameInfo): bool =
    wait > 4 and f.core.selection.selected.len == 0)
  step("click", proc (f: FrameInfo) = f.click(q0), proc (f: FrameInfo): bool =
    f.core.selection.selected.len == 1)
  step("Esc", proc (f: FrameInfo) = f.chord(skEscape), proc (f: FrameInfo): bool =
    f.core.selection.selected.len == 0)
  shootStep("plain")
  menuStep("Kill", 9, "Trace 10", "kill")
  waitEdits("killed", 9, {teKilled})
  headerMarkStep("the header marks it", 9, 9)
  var q: Vec2
  step("over the killed trace", proc (f: FrameInfo) =
    q = f.pointAt(9)
    f.moveMouse(q), proc (f: FrameInfo): bool =
    result = wait > 4 and f.pick.found and f.pick.trace == 9
    if result:
      doAssert f.pick.editNote == "killed", f.pick.editNote
      doAssert f.markOf("status.edits").size.x > 0, "the status bar does not say killed")
  shootStep("killed")
  step("Ctrl+Z", proc (f: FrameInfo) = f.chord(skZ, {smCtrl}), proc (f: FrameInfo): bool =
    f.core.traceEdits(f.traceOf(9)) == {})
  waitEdits("back", 9, {})
  step("the row of edits goes", noop, proc (f: FrameInfo): bool =
    f.markOf("plot.header.edits").size.x == 0 and f.answered and wait > 4)
  shootStep("back")
  menuStep("Reverse polarity", 14, "Trace 15", "reverse")
  waitEdits("reversed", 14, {teReversed})
  shootStep("reversed")
  menuStep("Undo last edit", 14, "Trace 15", "undo")
  waitEdits("put back", 14, {})
  # density: the keys
  step("density", look(dmDensity, {}), proc (f: FrameInfo): bool =
    f.answered and f.panel.layers[0].display.mode == dmDensity and wait > 3)
  shootStep("plain density")
  keyStep("K (density)", 9, skK)
  waitEdits("killed (density)", 9, {teKilled})
  shootStep("killed density")
  keyStep("R (density)", 14, skR)
  waitEdits("reversed (density)", 14, {teReversed})
  shootStep("reversed density")
  step("Ctrl+Z (density)", proc (f: FrameInfo) = f.chord(skZ, {smCtrl}),
    proc (f: FrameInfo): bool = f.core.traceEdits(f.traceOf(14)) == {})
  waitEdits("only the last undone", 9, {teKilled})
  menuStep("Clear all edits for this file", 3, "Trace 4", "clear")
  waitEdits("cleared", 9, {})
  step("the row of edits goes again", noop, proc (f: FrameInfo): bool =
    f.markOf("plot.header.edits").size.x == 0 and f.answered and wait > 4 and
      f.core.editsOf(0).isEmpty)
  shootStep("cleared density")
  # sorted by channel, descending: position p shows trace 23 - p
  step("sorted", proc (f: FrameInfo) =
    f.apply Command(kind: ckSort, panel: MainPanel,
      order: @[SortKey(field: hfChannel, descending: true)])
    look(dmWiggle, {})(f), proc (f: FrameInfo): bool =
    f.answered and wait > 3 and f.core.tiles(0)[^1].traces[0] == Channels - 1)
  shootStep("plain sorted")
  menuStep("Kill (sorted)", 3, "Trace 21", "kill")
  waitEdits("killed (sorted)", 20, {teKilled})
  keyStep("R (sorted)", 6, skR)
  waitEdits("reversed (sorted)", 17, {teReversed})
  headerMarkStep("the header marks it (sorted)", 3, 20)
  shootStep("edited sorted")
  step("density (sorted)", look(dmDensity, {}), proc (f: FrameInfo): bool =
    f.answered and f.panel.layers[0].display.mode == dmDensity and wait > 3)
  shootStep("edited sorted density")

  # ------------------------------------------------------------ driver --
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
      elif wait > 300:
        failed = steps[at].name & " did not happen"
        f.stop()

  let code = run(RunOptions(maxFrames: 6000, openPaths: @[path], windowSize: (1600, 1000),
    theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

  block asTheReferenceSays:
    for name, s in shots:
      doAssert s.w > 300 and s.h > 200, $s.w & "x" & $s.h
      let (bad, seen) = s.mismatches()
      echo "tguiedits: ", name, ": ", seen, " pixels, ", bad, " off the reference"
      doAssert bad == 0, name & ": " & $bad & " of " & $seen & " pixels off the reference"

  block killedIsBlank:
    for (name, plain, position) in [("killed", "plain", 9), ("killed density", "plain density",
        9), ("edited sorted", "plain sorted", 3), ("edited sorted density", "plain sorted", 3)]:
      let n = shots[name].inked(float64(position))
      doAssert n == 0, name & ": " & $n & " pixels of the trace's band are not the paper"
      doAssert shots[plain].inked(float64(position)) > 50, plain & ": the trace was blank before"

  block backAgain:
    for (a, b) in [("back", "plain"), ("cleared density", "plain density")]:
      var differ = 0
      doAssert shots[a].w == shots[b].w and shots[a].h == shots[b].h
      for k in 0 ..< shots[a].image.len:
        if not close(shots[a].image[k], shots[b].image[k]): inc differ
      doAssert differ == 0, a & ": " & $differ & " pixels differ from " & b

  block reversedIsMirrored:
    for (name, plain, position, trace) in [("reversed", "plain", 14, 14),
        ("edited sorted", "plain sorted", 6, 17)]:
      let (rows, matched) = mirrored(shots[name], shots[plain], float64(position))
      echo "tguiedits: ", name, ": ", matched, " of ", rows, " rows mirrored"
      doAssert rows >= 25 and matched >= rows * 9 div 10, name & ": " & $matched & " of " &
        $rows & " rows mirrored"
      doAssert negated(shots[name], shots[plain], trace), name & ": the values are not negated"
    let (rows, matched) = greyMirrored(shots["reversed density"], shots["plain density"], 14)
    doAssert rows > 100 and matched >= rows * 95 div 100, "density: " & $matched & " of " &
      $rows & " rows turned over"
  doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
  echo "tguiedits: ", steps.len, " steps"

# With the example files present (they are local only), the time from a key
# to the new picture on the Morgantown record, zoomed in on 40 traces, is
# measured; with `VIEWSEG_SCREENSHOTS=<dir>` the record is saved with one
# trace killed and one reversed: docs/screenshots/ holds the committed ones.

const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

proc morgantown(path: string) =
  ## Opens `path` in a 1600 × 1000 window zoomed in on 40 traces, presses K
  ## and R over two traces in turn, timing each from the key to the frame
  ## that draws the new picture, and leaves one trace killed and one
  ## reversed for the screenshots.
  let dir = getEnv("VIEWSEG_SCREENSHOTS")
  const keys = [(skK, 1012), (skK, 1012), (skR, 1020), (skR, 1020), (skK, 1012), (skR, 1020)]
  var stage = 0
  var wait = 0
  var press = 0
  var pressedAt: MonoTime
  var drawnAt = 0
  var gen = 0'u64
  var times: seq[float64]
  var frames: seq[int]
  var pressFrame = 0
  var saved = 0
  var focused = false
  var fromHeld = 0 # pictures made from the samples the reader held
  proc onFrame(f: FrameInfo) =
    let k = f.core.findPanel(MainPanel)
    let p = f.core.panels[k]
    inc wait
    proc screen(position: int): Vec2 =
      let at = p.view.screenAt(f.markOf("plot.data"), DataPoint(x: float64(position), tMs: 640))
      vec2(round(at.x), round(at.y))
    case stage
    of 0:
      if p.laidOut and p.layout.traces > 0:
        var v = p.view
        (v.traces, v.timeMs) = (Span(lo: 999.5, hi: 1039.5), Span(lo: 400, hi: 1000))
        f.showView(v)
        (stage, wait) = (1, 0)
    of 1: # the view drawn: the pointer over the first trace, then a key
      let tiles = f.core.tiles(k)
      if wait > 10 and tiles.len > 0 and tiles[^1].request == p.pending and
          not p.pending.isEmpty and p.pending.gen == p.requestGen:
        if press == keys.len:
          (stage, wait) = (3, 0)
        elif wait == 11:
          f.moveMouse(screen(keys[press][1]))
        elif not focused: # a click gives the plot the keys; Esc takes the selection away
          if wait == 14:
            f.pressMouse(screen(keys[press][1]), true)
            f.pressMouse(screen(keys[press][1]), false)
          if wait == 18:
            f.pressKey(skEscape, true)
            f.pressKey(skEscape, false)
          if wait > 22 and f.core.selection.selected.len == 0: (focused, wait) = (true, 11)
        elif wait > 16 and f.pick.found:
          gen = p.requestGen
          drawnAt = f.tracePanel.imagesDrawn
          f.pressKey(keys[press][0], true)
          f.pressKey(keys[press][0], false)
          pressedAt = getMonoTime()
          pressFrame = f.index
          (stage, wait) = (2, 0)
    of 2: # the new picture: a tile made after the key, drawn
      let tiles = f.core.tiles(k)
      if p.requestGen > gen and tiles.len > 0 and tiles[^1].request.gen == p.requestGen and
          tiles[^1].request == p.pending and f.tracePanel.imagesDrawn > drawnAt:
        times.add (getMonoTime() - pressedAt).inMicroseconds.float64 / 1000
        frames.add f.index - pressFrame
        if tiles[^1].cached: inc fromHeld
        inc press
        (stage, wait) = (1, 10) # the pointer to the next key's trace
      elif wait > 300:
        echo "tguiedits: key ", press, " brought no new picture"
        f.stop()
    of 3: # one trace killed and one reversed: the screenshots
      if dir.len == 0:
        f.stop()
      elif wait == 1:
        f.moveMouse(screen(1012))
      elif wait == 12:
        if f.savePng(dir / "edits-morgantown.png"): inc saved
        var d = p.layers[0].display
        d.mode = dmDensity
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        f.moveMouse(vec2(4, 4)) # off the plot: no hover tint on the blank column
      elif wait > 30 and f.core.tiles(k).len > 0 and f.core.tiles(k)[^1].request == p.pending:
        if f.savePng(dir / "edits-morgantown-density.png"): inc saved
        f.stop()
    else: discard
    if f.index > 5000: f.stop()
  let tmp = getTempDir() / ("viewseg-editshot-" & $getCurrentProcessId())
  let code = run(RunOptions(maxFrames: 6000, openPaths: @[path], windowSize: (1600, 1000),
    theme: forceDark, indexCacheDir: some(tmp), userThemeDir: some(tmp / "no-user-themes"),
    onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0, "run() exit code " & $code
  doAssert times.len == keys.len, "timed " & $times.len & " of " & $keys.len & " keys"
  var sorted = times
  sorted.sort()
  echo "tguiedits: Morgantown, key to new picture (ms): ", times.mapIt(it.formatFloat(ffDecimal,
    1)).join(", "), "; median ", sorted[sorted.len div 2].formatFloat(ffDecimal, 1),
    "; frames ", frames, "; ", fromHeld, " made from the samples held"
  doAssert fromHeld == keys.len, "an edit read the file"
  if dir.len > 0:
    doAssert saved == 2, "the screenshots were not saved"
    echo "tguiedits: saved ", dir / "edits-morgantown.png", ", ", dir /
      "edits-morgantown-density.png"

let example = examples / "00000151_12900_11300.sgd"
if fileExists(example):
  if getEnv("VIEWSEG_SCREENSHOTS").len > 0: createDir(getEnv("VIEWSEG_SCREENSHOTS"))
  morgantown(example)
