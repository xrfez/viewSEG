## The plot's right-click menu in the running frontend, headless, driven by
## SDL mouse and key events as the user's hardware sends them: a right
## click on a trace opens a menu that holds only the functions on data (its
## first line, what they act on; Reverse polarity, Kill, and FFT in a new
## window, not available yet; Reverse polarity of all traces; Undo last edit
## and Clear all edits for this file: `tguiedits` uses them) and nothing
## about the display (the menu ends below its last item, so nothing else is
## drawn in it); its first line names the trace under the pointer, or "3
## selected traces" when that trace is one of three selected (Ctrl + click
## adds them); "Reverse polarity of all traces" reverses every trace (read
## again, the trace under the pointer reads out the negated amplitude) and
## is shown ticked when the menu opens again. A right click on the display
## header (its values above the plot, or their names at the left) opens the
## header's own menu, not the plot's: Automatic fields turned off (the
## survey's FFID and channel stay) and offset ticked there change the rows;
## a left click there does nothing; the gear popover keeps the header's
## fields too. The file is never changed.
##
## Seen to fail: with the old menu's display entries put back after the
## trace operations (Fit all, Back, Colours, the display header), "the menu
## goes on 599.0 pixels below its last item"; with the target always the
## trace under the pointer (the selection ignored in `targetOf`), "the menu
## acts on Trace 9, not 3 selected traces"; with the all-traces item never
## ticked, "the tick: 0 pixels"; with the header's right click opening
## nothing (no `igOpenPopup` on its button), "the header's values: the
## header's menu opens did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, times]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

const menuItems = ["plot.menu.target", "plot.menu.reverse", "plot.menu.kill", "plot.menu.fft",
  "plot.menu.reverse all", "plot.menu.undo", "plot.menu.clear"]

proc menuMarks(f: FrameInfo): seq[string] =
  ## The marks drawn in the plot's menu this frame, in order.
  for n in menuItems:
    if f.markOf(n).size.x > 0: result.add n

withFixtures fx:
  let path = fx.surveySegy()
  let before = (readFile(path), getLastModificationTime(path))
  var steps: seq[Step]
  var at = 0
  var started = false
  var wait = 0 # frames since the step began, at `since`
  var since = getMonoTime()
  var failed = ""
  var plot: Rect
  var theme: Theme
  var amplitude = NaN # under the pointer before the reversal
  var ticks: seq[int] # text-coloured pixels where the all-traces item's tick goes

  template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

  proc answered(f: FrameInfo): bool =
    let p = f.panel
    let tiles = f.core.tiles(f.core.findPanel(MainPanel))
    p.laidOut and tiles.len > 0 and tiles[^1].request == p.pending and
      f.tracePanel.drawnView.sameSpans(p.view)

  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)

  proc noop(f: FrameInfo) = discard

  proc pointAt(f: FrameInfo; position: int): Vec2 =
    let v = f.panel.view.screenAt(plot, DataPoint(x: float64(position), tMs: 702))
    vec2(round(v.x), round(v.y))

  proc click(f: FrameInfo; q: Vec2; button = 1) =
    f.pressMouse(q, true, button)
    f.pressMouse(q, false, button)

  proc tick(f: FrameInfo): int =
    ## Text-coloured pixels in the right quarter of the all-traces item,
    ## where Dear ImGui draws a menu item's tick.
    let r = f.markOf("plot.menu.reverse all")
    for y in int(r.pos.y) ..< int(r.pos.y + r.size.y):
      for x in int(r.pos.x + r.size.x * 0.75) ..< int(r.pos.x + r.size.x):
        if distance(f.readPixel(x, y), theme.roles[rlText]) <= 60: inc result

  proc checkMenu(f: FrameInfo; target: string) =
    ## The menu shows the trace operations only, the first line `target`.
    doAssert f.menuMarks == @menuItems, "the menu holds " & $f.menuMarks
    doAssert f.tracePanel.menuTarget == target, "the menu acts on " &
      f.tracePanel.menuTarget & ", not " & target
    let win = f.markOf("plot.menu")
    let last = f.markOf("plot.menu.clear")
    let below = win.pos.y + win.size.y - (last.pos.y + last.size.y)
    doAssert below <= last.size.y, "the menu goes on " & $below & " pixels below its last item"
    doAssert f.markOf("plot.menu.target").pos.y - win.pos.y <= last.size.y,
      "something is drawn above the menu's first line"

  proc rightClickStep(name: string; position: int; target: string) =
    var q: Vec2
    step(name & ": point", proc (f: FrameInfo) =
      q = f.pointAt(position)
      f.moveMouse(q), proc (f: FrameInfo): bool = true)
    step(name & ": the menu opens", proc (f: FrameInfo) =
      f.click(q, button = 3), proc (f: FrameInfo): bool =
      result = f.markOf("plot.menu").size.x > 0 and wait > 3
      if result:
        f.checkMenu(target)
        ticks.add f.tick)
    step(name & ": Esc closes it", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
      f.markOf("plot.menu").size.x == 0)

  # -------------------------------------------------------------- steps --
  step("the file opens", noop, proc (f: FrameInfo): bool =
    result = f.answered and f.markOf("plot.data").size.x > 0
    if result:
      plot = f.markOf("plot.data")
      theme = f.theme)
  rightClickStep("a trace", 20, "Trace 21")
  # three traces selected: a right click on one of them acts on all three
  proc selectStep(name: string; position: int; ctrl: bool) =
    ## Steps: the pointer over `position`, then a click there (with Ctrl
    ## held from the frame before, as a hand would: it adds the trace).
    var q: Vec2
    step(name & ": point", proc (f: FrameInfo) =
      q = f.pointAt(position)
      f.moveMouse(q), proc (f: FrameInfo): bool = wait > 3)
    step(name, proc (f: FrameInfo) =
      if ctrl: f.pressKey(skCtrl, true, {smCtrl}), proc (f: FrameInfo): bool =
      if wait == 2: f.click(q)
      if wait == 4 and ctrl: f.pressKey(skCtrl, false)
      wait > 6)
  selectStep("select 4", 4, false)
  selectStep("add 8", 8, true)
  selectStep("add 12", 12, true)
  step("three selected", noop, proc (f: FrameInfo): bool =
    f.core.selection.selected.len == 3)
  rightClickStep("a selected trace", 8, "3 selected traces")
  rightClickStep("a trace not selected", 10, "Trace 11")
  # Reverse polarity of all traces, from the menu
  var q: Vec2
  step("point at a trace", proc (f: FrameInfo) =
    q = f.pointAt(15)
    f.moveMouse(q), proc (f: FrameInfo): bool =
    result = f.pick.found and wait > 3
    if result: amplitude = f.pick.amplitude)
  step("the menu opens", proc (f: FrameInfo) = f.click(q, button = 3),
    proc (f: FrameInfo): bool = f.markOf("plot.menu.reverse all").size.x > 0 and wait > 3)
  var item: Vec2
  step("point at Reverse polarity of all traces", proc (f: FrameInfo) =
    item = f.markOf("plot.menu.reverse all").centre
    f.moveMouse(item), proc (f: FrameInfo): bool = true)
  step("click it", proc (f: FrameInfo) = f.click(item), proc (f: FrameInfo): bool =
    f.panel.layers[0].reversed and f.markOf("plot.menu").size.x == 0)
  step("back over the trace", proc (f: FrameInfo) = f.moveMouse(q), proc (f: FrameInfo): bool =
    result = f.answered and f.pick.found and wait > 3
    if result:
      doAssert f.pick.amplitude == -amplitude, "the readout says " & $f.pick.amplitude &
        " after " & $amplitude)
  rightClickStep("reversed", 15, "Trace 16")
  # The display header's own menu: a right click on its values, or on their
  # names left of the plot, opens it (and not the plot's menu)
  var h: Vec2
  proc headerStep(name: string; where: proc (f: FrameInfo): Vec2) =
    step(name & ": point", proc (f: FrameInfo) =
      h = where(f)
      f.moveMouse(h), proc (f: FrameInfo): bool = wait > 3)
    step(name & ": the header's menu opens", proc (f: FrameInfo) = f.click(h, button = 3),
      proc (f: FrameInfo): bool =
      result = f.markOf("plot.header menu").size.x > 0 and wait > 3
      if result:
        doAssert f.markOf("plot.menu").size.x == 0, "the plot's menu opened too"
        for n in ["plot.header menu.auto", "plot.header menu.line", "plot.header menu.offset"]:
          doAssert f.markOf(n).size.x > 0, "no " & n)
  proc headerRow(f: FrameInfo): Vec2 =
    ## Over the display header's first row, in the middle.
    let (r, data) = (f.markOf("plot.header"), f.markOf("plot.data"))
    doAssert r.size.y > 0 and r.pos.y + r.size.y <= data.pos.y + 1, "no header area above the plot"
    vec2(round(data.pos.x + data.size.x / 2), round(r.pos.y + 5))
  headerStep("the header's values", headerRow)
  var box: Vec2
  step("point at Automatic fields", proc (f: FrameInfo) =
    box = f.markOf("plot.header menu.auto").centre
    f.moveMouse(box), proc (f: FrameInfo): bool = wait > 2)
  step("click it off", proc (f: FrameInfo) = f.click(box), proc (f: FrameInfo): bool =
    not f.panel.header.auto)
  step("point at offset", proc (f: FrameInfo) =
    doAssert f.panel.header.fields == @[hfRecord, hfChannel], $f.panel.header
    box = f.markOf("plot.header menu.offset").centre
    f.moveMouse(box), proc (f: FrameInfo): bool = wait > 2)
  step("tick offset", proc (f: FrameInfo) = f.click(box), proc (f: FrameInfo): bool =
    hfOffset in f.panel.header.fields and f.panel.header.fields.len == 3)
  step("Esc closes the header's menu", proc (f: FrameInfo) =
    f.pressKey(skEscape, true)
    f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
    f.markOf("plot.header menu").size.x == 0 and f.answered)
  headerStep("the header's names", proc (f: FrameInfo): Vec2 =
    vec2(f.markOf("plot.data").pos.x - 12, f.headerRow.y))
  step("Esc again", proc (f: FrameInfo) =
    f.pressKey(skEscape, true)
    f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
    f.markOf("plot.header menu").size.x == 0)
  # a left click on the header does nothing: no selection, no menu
  var selected: int
  step("left click on the header", proc (f: FrameInfo) =
    selected = f.core.selection.selected.len
    h = f.headerRow
    f.moveMouse(h), proc (f: FrameInfo): bool = wait > 3)
  step("nothing happens", proc (f: FrameInfo) = f.click(h), proc (f: FrameInfo): bool =
    result = wait > 6
    if result:
      doAssert f.core.selection.selected.len == selected, "a click on the header selected"
      doAssert f.markOf("plot.header menu").size.x == 0 and f.markOf("plot.menu").size.x == 0)
  # the gear popover keeps the display header's fields
  step("point at the gear", proc (f: FrameInfo) =
    h = f.markOf("plot.more").centre
    f.moveMouse(h), proc (f: FrameInfo): bool = wait > 2)
  step("the gear's popover", proc (f: FrameInfo) = f.click(h), proc (f: FrameInfo): bool =
    f.markOf("plot.more.header.auto").size.x > 0 and f.markOf("plot.more.header.offset").size.x > 0)

  # ------------------------------------------------------------ driver --
  proc onFrame(f: FrameInfo) =
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
      elif overdue(wait, 300, since):
        failed = steps[at].name & " did not happen"
        f.stop()

  let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000),
    theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  doAssert ticks.len == 4 and ticks[0] == 0 and ticks[1] == 0 and ticks[2] == 0,
    "a tick before the reversal: " & $ticks
  doAssert ticks[3] > 5, "the tick: " & $ticks[3] & " pixels"
  doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
  echo "tguimenus: ", steps.len, " steps; the tick ", ticks

# With `VIEWSEG_SCREENSHOTS=<dir>` and the example files present (they are
# local only), the plot's menu is saved open over a trace of the Morgantown
# record (menu-morgantown.png), and the display header's menu
# (header-menu-morgantown.png): docs/screenshots/ holds the committed ones.

const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

proc menuShot(path, file: string; header: bool) =
  ## Opens `path` in a 1600 × 1000 window zoomed in on 40 traces, right-clicks
  ## a trace (or the display header when `header`) and saves the frame with
  ## the menu open.
  let dir = getEnv("VIEWSEG_SCREENSHOTS")
  var stage = 0
  var wait = 0
  var saved = false
  var q: Vec2
  let start = getMonoTime()
  proc onFrame(f: FrameInfo) =
    let k = f.core.findPanel(MainPanel)
    let p = f.core.panels[k]
    inc wait
    case stage
    of 0:
      if p.laidOut and p.layout.traces > 0:
        var v = p.view
        (v.traces, v.timeMs) = (Span(lo: 999.5, hi: 1039.5), Span(lo: 400, hi: 1000))
        f.showView(v)
        (stage, wait) = (1, 0)
    of 1:
      let tiles = f.core.tiles(k)
      if wait > 10 and tiles.len > 0 and tiles[^1].request == p.pending:
        let plot = f.markOf("plot.data")
        if header:
          let r = f.markOf("plot.header")
          q = vec2(round(plot.pos.x + plot.size.x * 0.3), round(r.pos.y + 5))
        else:
          let at = p.view.screenAt(plot, DataPoint(x: 1012, tMs: 640))
          q = vec2(round(at.x), round(at.y))
        f.moveMouse(q)
        (stage, wait) = (2, 0)
    of 2:
      if wait == 4:
        f.pressMouse(q, true, button = 3)
        f.pressMouse(q, false, button = 3)
      if wait > 12:
        saved = f.savePng(dir / file)
        f.stop()
    else: discard
    if overdue(f.index, 3000, start): f.stop()
  let tmp = getTempDir() / ("viewseg-menushot-" & $getCurrentProcessId())
  let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000),
    theme: forceDark, indexCacheDir: some(tmp), userThemeDir: some(tmp / "no-user-themes"),
    onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0 and saved, "no screenshot of " & path
  echo "tguimenus: saved ", dir / file

if getEnv("VIEWSEG_SCREENSHOTS").len > 0:
  let morgantown = examples / "00000151_12900_11300.sgd"
  if fileExists(morgantown):
    createDir(getEnv("VIEWSEG_SCREENSHOTS"))
    menuShot(morgantown, "menu-morgantown.png", header = false)
    menuShot(morgantown, "header-menu-morgantown.png", header = true)
