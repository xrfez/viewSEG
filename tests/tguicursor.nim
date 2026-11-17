## The cursor's time line in the running frontend, headless, driven by SDL
## mouse events: off by default (nothing drawn under the pointer); a click on
## its toggle in the gear's Look tab turns it on and the settings keep it; then, on paper
## and on the theme's colours, in wiggle and in density mode, a thin line in
## the crosshair colour runs along the pointer's pixel row from the plot's
## left edge to the pointer, and not past it nor on the rows beside it, and
## the pointer's time, written to the sample interval, sits at the time
## axis on that row; moving the pointer along a trace moves the line with it
## while nothing is read (no new request), no tile is uploaded and no new
## image of the data is drawn (counted); with the pointer off the plot,
## neither the line nor the time is drawn; and the file is never changed.
## With the line, the display header's values of the trace under the
## pointer stand in a box over each of the header's rows, at the trace's
## column, as the tiles hold them, in every look and as the pointer moves;
## none with the line off or the pointer off the plot.
##
## Seen to fail: with the header's boxes not drawn (`drawCursorHeader` not
## called), "wiggle on paper: @[] for the rows @[FFID, channel]". With the
## line not drawn (`drawCursorLine` not called), "wiggle
## on paper: the line's colour on 0.0 of its row"; with the plot's image
## drawn again whenever the line moves (its marks bumped), "moving the
## pointer along a trace: (images: 35, ...) became (63, ...)". A first
## version drew the line with `AddLine` at a row's middle: Dear ImGui's
## anti-aliasing spread it over two rows at half strength, so it is a
## rectangle one pixel high.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/view/[displayheader, plotink, theme, timeaxis]
import viewSEG/ui/imgui/[app, symbols]
import privatefiles
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

# With `VIEWSEG_SCREENSHOTS=<dir>` and the example files present (they are
# local only), the cursor's time line is saved on the private land record,
# zoomed in, as wiggles on paper (cursor-land.png) and as density on
# the theme's colours (cursor-land-density.png): docs/images/
# holds the committed ones.

proc cursorShot(path, file: string; mode: DisplayMode; colours: PlotColours;
    traces, timeMs: Span) =
  ## Opens `path` in a 1600 × 1000 window with the cursor's time line on,
  ## shows `traces` and `timeMs` in `mode` and `colours`, puts the pointer a
  ## third of the way across and 0.55 of the way down, and saves the frame.
  let dir = getEnv("VIEWSEG_SCREENSHOTS")
  var stage = 0
  var wait = 0
  var since = getMonoTime() # when the stage began
  var saved = false
  proc onFrame(f: FrameInfo) =
    let k = f.core.findPanel(MainPanel)
    let p = f.core.panels[k]
    inc wait
    template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
    case stage
    of 0:
      if p.laidOut and p.layout.traces > 0:
        var s = f.core.settings
        s.cursorLine = true
        f.apply Command(kind: ckSettings, settings: s)
        var v = p.view
        (v.traces, v.timeMs) = (traces, timeMs)
        f.showView(v)
        var d = p.layers[0].display
        (d.mode, d.colours) = (mode, colours)
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        next 1
    of 1:
      let tiles = f.core.tiles(k)
      if wait > 10 and tiles.len > 0 and tiles[^1].request == p.pending:
        let plot = f.markOf("plot.data")
        let at = p.view.screenAt(plot, DataPoint(x: traces.lo + traces.width / 3,
          tMs: timeMs.lo + 0.55 * timeMs.width))
        f.moveMouse(vec2(round(at.x), round(at.y)))
        next 2
    of 2:
      if wait > 8:
        saved = f.savePng(dir / file)
        f.stop()
    else: discard
    if overdue(f.index, 3000, since): f.stop()
  let tmp = getTempDir() / ("viewseg-cursorshot-" & $getCurrentProcessId())
  let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000),
    theme: forceDark, indexCacheDir: some(tmp), userThemeDir: some(tmp / "no-user-themes"),
    onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0 and saved, "no screenshot of " & path
  echo "tguicursor: saved ", dir / file

proc main*() =

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
    var looks = 0 # looks whose line and time were checked
    var counted: tuple[images, uploads: int; gen: uint64; hover: int]
    var moves = 0 # pointer moves along a trace checked
    var lastRow = 0

    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

    proc answered(f: FrameInfo): bool =
      let p = f.panel
      let tiles = f.core.tiles(f.core.findPanel(MainPanel))
      p.laidOut and tiles.len > 0 and tiles[^1].request == p.pending and
        f.tracePanel.drawnView.sameSpans(p.view)

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc pointAt(f: FrameInfo; position: float64; tMs: float64): Vec2 =
      let v = f.panel.view.screenAt(plot, DataPoint(x: position, tMs: tMs))
      vec2(round(v.x), round(v.y))

    proc lineColour(f: FrameInfo): Rgba =
      readableOn(f.theme.roles[rlCrosshair], plotInk(f.theme, f.panel.layers[0].display).background)

    proc share(f: FrameInfo; row, x0, x1: int): float64 =
      ## The share of pixels `x0 ..< x1` of `row` in the line's colour (drawn
      ## opaque, unblended: density's greys can come within 26 of it).
      let c = f.lineColour
      var n = 0
      for x in x0 ..< x1:
        if distance(f.readPixel(x, row), c) <= 4: inc n
      float64(n) / float64(max(1, x1 - x0))

    proc lineAt(f: FrameInfo; q: Vec2; what: string) =
      ## The line runs from the plot's left edge to `q` on `q`'s row, and the
      ## time of `q` is written at the axis on that row.
      let row = int(q.y)
      let left = int(plot.pos.x)
      let along = f.share(row, left + 2, int(q.x) - 3)
      doAssert along >= 0.95, what & ": the line's colour on " & $along & " of its row"
      let past = f.share(row, int(q.x) + 4, int(plot.pos.x + plot.size.x) - 2)
      doAssert past <= 0.02, what & ": the line runs on past the pointer: " & $past
      for r in [row - 4, row + 4]:
        let beside = f.share(r, left + 2, int(q.x) - 3)
        doAssert beside <= 0.02, what & ": the line's colour on row " & $r & ": " & $beside
      let label = f.markOf("plot.cursor time")
      doAssert label.size.x > 0, what & ": no time at the axis"
      doAssert label.pos.x + label.size.x <= plot.pos.x + 1 and label.pos.x >= 0,
        what & ": the time is not at the axis: " & $label
      doAssert abs(label.pos.y + label.size.y / 2 - q.y) <= 2, what & ": the time is on another row"
      let want = cursorTimeText(f.pick.at.tMs, DtMs)
      doAssert f.tracePanel.cursorText == want and want.len > 0, what & ": the axis says " &
        f.tracePanel.cursorText & ", the pointer is at " & want
      var ink = 0
      for y in int(label.pos.y) ..< int(label.pos.y + label.size.y):
        for x in int(label.pos.x) ..< int(label.pos.x + label.size.x):
          if distance(f.readPixel(x, y), f.theme.roles[rlText]) <= 60: inc ink
      doAssert ink > 5, what & ": the time is not drawn (" & $ink & " pixels of text)"
      # the display header's values of the trace under the pointer, a box over
      # each row at its column, as the tiles hold them
      let fields = f.panel.shownFields
      let tile = f.core.tiles(f.core.findPanel(MainPanel))[^1]
      let r = tile.request
      let position = f.pick.position
      doAssert position >= r.first and (position - r.first) mod r.stride == 0
      let header = f.markOf("plot.header")
      doAssert f.tracePanel.cursorHeader.len == fields.len, what & ": " &
        $f.tracePanel.cursorHeader & " for the rows " & $fields
      for i, field in fields:
        let want = headerText(tile.header[i][(position - r.first) div r.stride])
        doAssert f.tracePanel.cursorHeader[i] == want and want.len > 0, what & ": row " & $field &
          " says " & f.tracePanel.cursorHeader[i] & ", the trace has " & want
        let box = f.markOf("plot.cursor header " & $field)
        doAssert box.size.x > 0, what & ": no box over the " & $field & " row"
        let mid = box.pos.y + box.size.y / 2
        doAssert mid > header.pos.y + float32(i) * box.size.y * 0.9 and mid < plot.pos.y,
          what & ": the " & $field & " box is not over its row: " & $box
        let x = plot.pos.x + float32((float64(position) - f.tracePanel.drawnView.traces.lo) /
          f.tracePanel.drawnView.traces.width) * plot.size.x
        doAssert abs(box.pos.x + box.size.x / 2 - x) <= 2, what & ": the " & $field &
          " box is not at the trace's column: " & $box & ", the trace at " & $x
        var letters = 0
        for y in int(box.pos.y) ..< int(box.pos.y + box.size.y):
          for bx in int(box.pos.x) ..< int(box.pos.x + box.size.x):
            if distance(f.readPixel(bx, y), f.theme.roles[rlText]) <= 60: inc letters
        doAssert letters > 5, what & ": the " & $field & " box's value is not drawn"
      lastRow = row

    proc lookStep(mode: DisplayMode; colours: PlotColours) =
      let what = $mode & " on " & $colours
      var q: Vec2
      step(what, proc (f: FrameInfo) =
        var d = f.panel.layers[0].display
        (d.mode, d.colours) = (mode, colours)
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        q = f.pointAt(6.3, 412)
        f.moveMouse(q), proc (f: FrameInfo): bool =
        result = f.answered and wait > 4 and f.pick.inside
        if result:
          f.lineAt(q, what)
          inc looks)

    proc moveStep(tMs: float64) =
      var q: Vec2
      step("along the trace to " & $tMs & " ms", proc (f: FrameInfo) =
        q = f.pointAt(6.3, tMs)
        f.moveMouse(q), proc (f: FrameInfo): bool =
        result = wait > 3
        if result:
          f.lineAt(q, "moved to " & $tMs & " ms")
          inc moves)

    # -------------------------------------------------------------- steps --
    step("the file opens", noop, proc (f: FrameInfo): bool =
      result = f.answered and f.markOf("plot.data").size.x > 0
      if result: plot = f.markOf("plot.data"))
    var q: Vec2
    step("off: the pointer over the plot", proc (f: FrameInfo) =
      doAssert not f.core.settings.cursorLine, "on by default"
      q = f.pointAt(6.3, 412)
      f.moveMouse(q), proc (f: FrameInfo): bool =
      result = wait > 4 and f.pick.inside
      if result:
        doAssert f.markOf("plot.cursor line").size.x == 0 and f.tracePanel.cursorText == "" and
          f.tracePanel.cursorHeader.len == 0, "drawn while off"
        doAssert f.share(int(q.y), int(plot.pos.x) + 2, int(q.x) - 3) <= 0.02, "a line while off")
    step("to the gear", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.more").centre), proc (f: FrameInfo): bool = true)
    step("the gear", proc (f: FrameInfo) =
      let c = f.markOf("plot.more").centre
      f.pressMouse(c, true)
      f.pressMouse(c, false), proc (f: FrameInfo): bool =
      f.markOf("plot.more popover").size.x > 100 and wait > 4)
    step("to Look", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.more tab look").centre), proc (f: FrameInfo): bool = wait > 2)
    step("Look", proc (f: FrameInfo) =
      let c = f.markOf("plot.more tab look").centre
      f.pressMouse(c, true)
      f.pressMouse(c, false), proc (f: FrameInfo): bool =
      f.markOf("plot.Cursor time line").size.x > 0)
    step("point at the toggle", proc (f: FrameInfo) =
      q = f.markOf("plot." & $syCursorTime).centre
      doAssert q.x > 0, "no toggle in the gear's Look tab"
      f.moveMouse(q), proc (f: FrameInfo): bool = wait > 2)
    step("turn it on", proc (f: FrameInfo) =
      f.pressMouse(q, true)
      f.pressMouse(q, false), proc (f: FrameInfo): bool = f.core.settings.cursorLine)
    step("close the gear", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
      f.markOf("plot.more popover").size.x == 0)
    lookStep(dmWiggle, pcPaper)
    lookStep(dmDensity, pcPaper)
    lookStep(dmWiggle, pcTheme)
    lookStep(dmDensity, pcTheme)
    step("count", noop, proc (f: FrameInfo): bool =
      result = wait > 6
      if result:
        counted = (f.tracePanel.imagesDrawn, f.tracePanel.tilesUploaded, f.panel.requestGen,
          f.core.selection.hover))
    for t in [250.0, 330, 571, 702, 850]: moveStep(t)
    step("nothing read or drawn again", noop, proc (f: FrameInfo): bool =
      result = true
      let now = (f.tracePanel.imagesDrawn, f.tracePanel.tilesUploaded, f.panel.requestGen,
        f.core.selection.hover)
      doAssert now == counted, "moving the pointer along a trace: " & $counted & " became " & $now)
    step("the pointer off the plot", proc (f: FrameInfo) =
      q = f.markOf("plot.more").centre
      f.moveMouse(q), proc (f: FrameInfo): bool =
      result = wait > 4
      if result:
        doAssert not f.pick.inside
        let (line, time) = (f.markOf("plot.cursor line"), f.markOf("plot.cursor time"))
        doAssert line.size.x == 0 and time.size.x == 0 and f.tracePanel.cursorText == "" and
          f.tracePanel.cursorHeader.len == 0, "drawn with the pointer off the plot"
        doAssert f.share(lastRow, int(plot.pos.x) + 2, int(plot.pos.x + plot.size.x) - 2) <= 0.02,
          "the line stayed on the plot")
    step("kept in the settings", noop, proc (f: FrameInfo): bool =
      doAssert "(cursorLine true)" in settingsDocument(f.core.settings)
      true)

    # ------------------------------------------------------------ driver --
    proc onFrame(f: FrameInfo) =
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
        elif overdue(wait, 300, since):
          failed = steps[at].name & " did not happen"
          f.stop()

    let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    doAssert looks == 4 and moves == 5, $looks & " looks, " & $moves & " moves"
    doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
    echo "tguicursor: ", steps.len, " steps, ", looks, " looks, ", moves, " moves"

  if getEnv("VIEWSEG_SCREENSHOTS").len > 0:
    let landSegd = privateFile("landSegd")
    if landSegd.len > 0:
      createDir(getEnv("VIEWSEG_SCREENSHOTS"))
      cursorShot(landSegd, "cursor-land.png", dmWiggle, pcPaper,
        Span(lo: 999.5, hi: 1039.5), Span(lo: 400, hi: 1000))
      cursorShot(landSegd, "cursor-land-density.png", dmDensity, pcTheme,
        Span(lo: 799.5, hi: 1199.5), Span(lo: 0, hi: 2000))

when isMainModule:
  main()
