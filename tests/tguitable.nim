## The Headers window's Trace table tab in the running frontend, headless,
## with real pointer and key events.
##
## A SEG-Y file shown, its second record: the tab lists a row per trace of
## the record, the keys as columns. The rows are linked with the plot and the
## map: the pointer over a row points at its trace (the plot's hover, and
## the map's points of its source and receiver), a click selects it, Ctrl +
## click adds another, the trace under the plot's pointer marks its row. A
## click on a column's header sorts by it, a second the other way; Find
## keeps the rows whose channel is in a range, Clear takes it back; Columns...
## adds a header field (source X) and the settings keep it; a column graphed
## draws the graph above the rows; the whole file's rows; a double-click on
## a row of another record shows that record; a right-click offers to copy.
##
## A million traces (1000 records of 1000): the whole file's rows scroll by the
## wheel with the frame time near the idle one (only the rows on screen are
## read; 27 ms a frame in a debug build, idle 29).
##
## Seen to fail: with the hover not sent from a row (`ckHover` taken out of
## `drawTraceTable`), "a row points at its trace did not happen"; with the
## rows on screen taken from the clipper's first step (as first written:
## that step measures row 0), the million rows' "the rows on screen are not
## read".
##
## Runs alone: it bounds the frame times while a million rows scroll.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves table-*.png there.

import std/[algorithm, math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))
func left(r: Rect): Vec2 = vec2(round(r.pos.x + 12), round(r.pos.y + r.size.y / 2))
  ## a point in a row, at its start (a row spans every column: its centre
  ## may be past the window's edge)

let shots = getEnv("VIEWSEG_SCREENSHOTS")
if shots.len > 0: createDir(shots)

proc shoot(f: FrameInfo; file: string) =
  if shots.len > 0: doAssert f.savePng(shots / file), "cannot save " & file

withFixtures fx:
  let path = fx.surveySegy()
  let before = (readFile(path), getLastModificationTime(path))
  var steps: seq[Step]
  var at = 0
  var started = false
  var wait = 0
  var since = getMonoTime()
  var failed = ""

  template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
  template answer(f: FrameInfo): untyped = f.core.inspection.answer.table

  proc base(f: FrameInfo): int = f.core.sessions[0].base

  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)

  proc noop(f: FrameInfo) = discard

  proc click(f: FrameInfo; q: Vec2; button = 1) =
    f.pressMouse(q, true, button)
    f.pressMouse(q, false, button)

  proc clickOn(name, mark: string; done: proc (f: FrameInfo): bool; button = 1) =
    step(name & ": point", proc (f: FrameInfo) = f.moveMouse(f.markOf(mark).centre),
      proc (f: FrameInfo): bool = wait > 2 and f.markOf(mark).size.x > 0)
    step(name, proc (f: FrameInfo) = f.click(f.markOf(mark).centre, button), done)

  proc traceOfRow(f: FrameInfo; row: int): int =
    ## The survey-wide id of the trace of table row `row`; -1 when not read.
    let r = row - f.answer.first
    if r in 0 ..< f.answer.rowTraces.len: f.base + f.answer.rowTraces[r] else: -1

  var rowTwo = -1
  step("shown", noop, proc (f: FrameInfo): bool =
    f.panel.laidOut and f.core.sessions.len == 1 and f.markOf("headers").size.x > 0)
  step("record 2", proc (f: FrameInfo) =
    f.apply(Command(kind: ckGather, panel: MainPanel, gather: 1)), proc (f: FrameInfo): bool =
    f.panel.laidOut and f.panel.layers[0].source.gather == 1)
  clickOn("the Trace table tab", "headers.tab table", proc (f: FrameInfo): bool =
    result = f.markOf("table.row 2").size.x > 0 and f.answer.count == Channels and
      f.markOf("table.cell 2 1").size.x > 0
    if result:
      rowTwo = f.traceOfRow(2)
      doAssert rowTwo == f.base + Channels + 2, $rowTwo
      f.shoot("table-record.png"))
  step("a row points at its trace", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("table.row 2").left), proc (f: FrameInfo): bool =
    f.core.selection.hover == rowTwo and f.core.selection.hoverAt.len > 0)
  step("a click selects it", proc (f: FrameInfo) = f.click(f.markOf("table.row 2").left),
    proc (f: FrameInfo): bool =
    rowTwo in f.core.selection.selected and f.core.selection.selectedCount == 1 and
      f.markOf("table.selected 2").size.x > 0)
  step("Ctrl + click adds another", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("table.row 0").left), proc (f: FrameInfo): bool =
    let q = f.markOf("table.row 0").left
    if wait == 3:
      f.pressKey(skCtrl, true, {smCtrl})
      f.pressMouse(q, true)
    if wait == 5:
      f.pressMouse(q, false)
      f.pressKey(skCtrl, false)
    wait > 6 and f.core.selection.selectedCount == 2 and
      f.markOf("table.selected 0").size.x > 0)
  step("the plot's pointer marks its row", proc (f: FrameInfo) =
    let v = f.panel.view.screenAt(f.markOf("plot.data"), DataPoint(x: 1, tMs: 702))
    f.moveMouse(vec2(round(v.x), round(v.y))), proc (f: FrameInfo): bool =
    result = f.core.selection.hover == f.base + Channels + 1 and
      f.markOf("table.pointed 1").size.x > 0
    if result: f.shoot("table-linked.png"))
  clickOn("sorted by channel", "table.header keys.channel", proc (f: FrameInfo): bool =
    wait > 3 and f.answer.view.sortBy == "keys.channel" and not f.answer.view.descending)
  clickOn("the other way", "table.header keys.channel", proc (f: FrameInfo): bool =
    f.answer.view.descending and f.answer.values.len > 0 and
      f.answer.values[0][1] == float64(Channels))
  clickOn("Find's column", "table.find field", proc (f: FrameInfo): bool =
    f.markOf("table.find field keys.channel").size.x > 0)
  clickOn("Find in the channel", "table.find field keys.channel", proc (f: FrameInfo): bool =
    wait > 3)
  clickOn("Find's value", "table.find value", proc (f: FrameInfo): bool = wait > 3)
  step("channels 3 to 5", proc (f: FrameInfo) = f.typeText("3..5"), proc (f: FrameInfo): bool =
    result = f.answer.view.findValue == "3..5" and f.answer.count == 3
    if result:
      for row in f.answer.values: doAssert row[1] in [3.0, 4.0, 5.0], $row
      f.shoot("table-find.png"))
  clickOn("Clear", "table.find clear", proc (f: FrameInfo): bool =
    f.answer.view.findValue == "" and f.answer.count == Channels)
  clickOn("Columns...", "table.columns", proc (f: FrameInfo): bool =
    result = f.markOf("table.chooser").size.x > 0 and
      f.markOf("table.field trace.sourceX").size.x > 0
    if result: f.shoot("table-columns.png"))
  step("its filter", proc (f: FrameInfo) = f.typeText("sourceX"), proc (f: FrameInfo): bool =
    wait > 3 and f.markOf("table.field keys.record").size.x == 0)
  clickOn("source X added", "table.field trace.sourceX", proc (f: FrameInfo): bool =
    "trace.sourceX" in f.core.settings.headers.tableFields)
  step("the chooser closed", proc (f: FrameInfo) =
    let q = f.markOf("messages").centre # (outside the chooser: it closes)
    f.moveMouse(q)
    f.click(q), proc (f: FrameInfo): bool =
    wait > 3 and f.markOf("table.chooser").size.x == 0 and
      f.answer.view.fields[^1] == "trace.sourceX" and f.answer.values.len > 0 and
      f.answer.values[0][^1] > 0)
  clickOn("the graph's choice", "table.graph choice", proc (f: FrameInfo): bool =
    f.markOf("table.graph keys.offset").size.x > 0)
  clickOn("offset graphed", "table.graph keys.offset", proc (f: FrameInfo): bool =
    result = wait > 3 and f.answer.graphMax.len == Channels and f.markOf("table.graph").size.x > 0
    if result: f.shoot("table-graph.png"))
  clickOn("the graph's choice again", "table.graph choice", proc (f: FrameInfo): bool =
    f.markOf("table.graph none").size.x > 0)
  clickOn("no graph", "table.graph none", proc (f: FrameInfo): bool =
    wait > 3 and f.answer.graphMax.len == 0)
  clickOn("the whole file", "table.scope file", proc (f: FrameInfo): bool =
    f.core.settings.headers.tableScope == tsFile and f.answer.count == SurveyTraces and
      f.answer.view.scope == tsFile)
  clickOn("in the file's order", "table.header keys.channel", proc (f: FrameInfo): bool =
    wait > 3 and f.answer.view.sortBy == "keys.channel")
  var third = -1
  step("a row of the third record", noop, proc (f: FrameInfo): bool =
    # sorted by channel: row 2 is channel 1 of the third record
    third = f.traceOfRow(2)
    third == f.base + 2 * Channels)
  step("double-click: its record", proc (f: FrameInfo) =
    let q = f.markOf("table.row 2").left
    f.moveMouse(q)
    f.click(q), proc (f: FrameInfo): bool = wait > 1)
  step("double-click: shown", proc (f: FrameInfo) = f.click(f.markOf("table.row 2").left),
    proc (f: FrameInfo): bool =
    f.panel.layers[0].source.gather == 2 and third in f.core.selection.selected)
  step("its menu: point", proc (f: FrameInfo) = f.moveMouse(f.markOf("table.row 1").left),
    proc (f: FrameInfo): bool = wait > 2)
  step("its menu", proc (f: FrameInfo) = f.click(f.markOf("table.row 1").left, 3),
    proc (f: FrameInfo): bool =
    result = wait > 3 and f.markOf("table.copy rows").size.x > 0
    if result: f.shoot("table-menu.png"))
  step("menu closed", proc (f: FrameInfo) =
    f.pressKey(skEscape, true)
    f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
    wait > 3 and f.markOf("table.copy rows").size.x == 0)

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
      elif overdue(wait, 400, since):
        failed = steps[at].name & " did not happen"
        f.stop()

  let code = run(RunOptions(persist: false, logDir: some(fx.dir / "logs"), openPaths: @[path],
    windowSize: (1600, 1000), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
  echo "tguitable: ", steps.len, " steps"

  # A million traces: the whole file's rows, the wheel over them.
  const Million = 1_000_000
  let many = fx.millionTracesSegy()
  var stage = 0
  wait = 0
  since = getMonoTime()
  var
    idle, scrolling: seq[float64]
    last = getMonoTime()
    where: Vec2
    readFar = false
  proc onMany(f: FrameInfo) =
    inc wait
    let now = getMonoTime()
    let ms = (now - last).inMicroseconds.float64 / 1000
    last = now
    template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
    case stage
    of 0:
      if f.panel.laidOut and f.markOf("headers.tab table").size.x > 0:
        f.moveMouse(f.markOf("headers.tab table").centre)
        next 1
    of 1:
      if wait == 3: f.click(f.markOf("headers.tab table").centre)
      if wait > 6 and f.markOf("table.scope file").size.x > 0:
        f.moveMouse(f.markOf("table.scope file").centre)
        next 2
    of 2:
      if wait == 3: f.click(f.markOf("table.scope file").centre)
      if wait > 6 and f.answer.count == Million and f.markOf("table.row 2").size.x > 0:
        where = f.markOf("table").left # (its centre may be past the window's edge)
        f.moveMouse(where)
        next 3
    of 3: # idle frames, then the wheel, a notch a frame
      if wait in 5 .. 64: idle.add ms
      if wait >= 66 and wait < 186:
        if wait > 66: scrolling.add ms
        f.scrollWheel(where, -10)
      if wait == 186: next 4
    of 4: # the rows on screen, far down, are read
      if f.answer.first > 1000 and f.answer.rowTraces.len > 0:
        readFar = true
        f.shoot("table-million.png")
        f.stop()
    else: f.stop()
    if overdue(wait, 3000, since): f.stop()
  let code2 = run(RunOptions(persist: false, openPaths: @[many], windowSize: (1600, 1000),
    indexCacheDir: some(fx.dir / "cache"), theme: forceDark,
    userThemeDir: some(fx.dir / "no-user-themes"), onFrame: onMany))
  doAssert code2 == 0
  doAssert stage >= 3, "the million rows were not listed (stage " & $stage & ")"
  doAssert readFar, "the rows on screen are not read"
  doAssert scrolling.len >= 100 and idle.len >= 50, $scrolling.len & " " & $idle.len
  let medIdle = idle.sorted[idle.len div 2]
  let medScroll = scrolling.sorted[scrolling.len div 2]
  echo "tguitable: a million rows: frames idle ", formatFloat(medIdle, ffDecimal, 1),
    " ms, scrolling median ", formatFloat(medScroll, ffDecimal, 1), " ms, slowest ",
    formatFloat(scrolling.max, ffDecimal, 1), " ms"
  doAssert medScroll < 50 and medScroll < medIdle * 3 + 10,
    "the table lags: median " & $medScroll & " ms a frame while scrolling, " & $medIdle & " idle"
