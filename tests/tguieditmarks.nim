## Right-click an edit mark in the Seismic plot to remove the edit, headless,
## on samples/land/shots.sgy.
##
## Kill one trace, reverse another, filter a third. A right-click on each
## mark opens a menu for that trace; choosing the removal takes the mark
## away, and undo brings it back. The same for a selection, for a trace that
## has more than one edit (one undo), and zoomed out, where the marks are
## outlines and a click on the row names the traces that share the pixel.
##
## Seen to fail: with the mark menu never opened, "the menu did not open on
## the kill mark"; with the removal sending nothing, "the kill mark stayed";
## with undo not restoring it, "undo did not bring the kill mark back".
##
## Needs a display: the tester gives it one.

import std/[math, monotimes, os]
import viewSEG/core/[geometry, processing, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

const root = currentSourcePath().parentDir.parentDir

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc answered(f: FrameInfo): bool =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

proc runSteps(file: string; steps: seq[Step]; dir: string) =
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
      wait = 0
      since = getMonoTime()
    else:
      inc wait
      if wait >= 2 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 500, since):
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(openPaths: @[file], windowSize: (480, 760),
    theme: forceDark, userThemeDir: some(dir / "no-user-themes"),
    indexCacheDir: some(dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

withFixtures fx:
  let land = root / "samples" / "land" / "shots.sgy"
  doAssert fileExists(land), "samples/land/shots.sgy is not there"
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
  proc baseOf(f: FrameInfo): int = f.core.sessions[0].base
  proc idOf(f: FrameInfo; trace: int): int = f.baseOf + trace
  proc has(f: FrameInfo; trace: int; edit: TraceEdit): bool =
    edit in f.core.traceEdits(f.idOf(trace))
  proc filtered(f: FrameInfo; trace: int): bool =
    f.core.ownAt(f.core.sessions[0].path, trace).has

  proc zoom(lo, hi: float64) =
    step("zoom " & $lo & ".." & $hi, proc (f: FrameInfo) =
      var v = f.panel.view
      v.traces = Span(lo: lo, hi: hi)
      f.showView(v), proc (f: FrameInfo): bool =
        f.answered and abs(f.panel.view.traces.lo - lo) < 0.2)

  proc point(name, mark: string) =
    step(name, proc (f: FrameInfo) =
      let r = f.markOf(mark)
      doAssert r.size.x > 0, mark & " is not shown"
      pointAt = r.centre
      f.moveMouse(pointAt), after(3))

  proc rightClick(name: string) =
    step(name, proc (f: FrameInfo) =
      f.pressMouse(pointAt, true, 3)
      f.pressMouse(pointAt, false, 3), proc (f: FrameInfo): bool =
        f.markOf("plot.editmenu").size.x > 0)

  proc choose(name, item: string) =
    var at: Vec2
    step(name & ": point", proc (f: FrameInfo) =
      let r = f.markOf("plot.editmenu.item " & item)
      doAssert r.size.x > 0, "the menu has no \"" & item & "\""
      at = r.centre
      f.moveMouse(at), after(2))
    step(name, proc (f: FrameInfo) =
      f.pressMouse(at, true)
      f.pressMouse(at, false), proc (f: FrameInfo): bool =
        f.markOf("plot.editmenu").size.x == 0)

  proc undo() =
    step("undo", proc (f: FrameInfo) =
      f.apply(Command(kind: ckUndoEdit, panel: MainPanel)), after(2))

  step("the file opens", noop, proc (f: FrameInfo): bool = f.answered)
  zoom(-0.5, 7.5)
  step("focus the plot", proc (f: FrameInfo) =
    pointAt = f.markOf("plot.data").centre
    f.moveMouse(pointAt)
    f.pressMouse(pointAt, true)
    f.pressMouse(pointAt, false), after(4))
  step("kill, reverse, filter", proc (f: FrameInfo) =
    let b = f.baseOf
    let spec = Processing(band: pbBandPass, f1: 8, f2: 10, f3: 40, f4: 48)
    f.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[b + 1], on: true)
    f.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[b + 3], on: true)
    f.apply(Command(kind: ckOwnFilter, panel: MainPanel, edited: @[b + 5], on: true,
      processing: spec, filterPlace: fpAfter)), proc (f: FrameInfo): bool =
      f.answered and f.has(1, teKilled) and f.has(3, teReversed) and f.filtered(5) and
        f.markOf("plot.header.edit 2").size.x > 4 and
        f.markOf("plot.header.edit 4").size.x > 4 and
        f.markOf("plot.header.filter 6").size.x > 4)

  point("point at the kill mark", "plot.header.edit 2")
  rightClick("the menu did not open on the kill mark")
  step("the kill menu", noop, proc (f: FrameInfo): bool =
    f.markOf("plot.editmenu.title").size.x > 0 and
      f.tracePanel.menuTarget.len >= 0 and
      f.markOf("plot.editmenu.item Remove kill").size.x > 0)
  choose("remove the kill", "Remove kill")
  step("the kill mark stayed", noop, proc (f: FrameInfo): bool =
    not f.has(1, teKilled) and f.markOf("plot.header.edit 2").size.x == 0 and f.answered)
  undo()
  step("undo did not bring the kill mark back", noop, proc (f: FrameInfo): bool =
    f.has(1, teKilled) and f.markOf("plot.header.edit 2").size.x > 0 and f.answered)

  point("point at the reversal", "plot.header.edit 4")
  rightClick("the menu did not open on the reversal")
  choose("remove the reversal", "Remove reversal")
  step("the reversal mark stayed", noop, proc (f: FrameInfo): bool =
    not f.has(3, teReversed) and f.markOf("plot.header.edit 4").size.x == 0)
  undo()
  step("undo did not bring the reversal back", noop, proc (f: FrameInfo): bool =
    f.has(3, teReversed) and f.markOf("plot.header.edit 4").size.x > 0)

  point("point at the filter", "plot.header.filter 6")
  rightClick("the menu did not open on the filter")
  step("the filter menu offers edit", noop, proc (f: FrameInfo): bool =
    f.markOf("plot.editmenu.item Edit the trace's filter...").size.x > 0 and
      f.markOf("plot.editmenu.item Remove the trace's filter").size.x > 0)
  choose("remove the filter", "Remove the trace's filter")
  step("the filter mark stayed", noop, proc (f: FrameInfo): bool =
    not f.filtered(5) and f.markOf("plot.header.filter 6").size.x == 0)
  undo()
  step("undo did not bring the filter back", noop, proc (f: FrameInfo): bool =
    f.filtered(5) and f.markOf("plot.header.filter 6").size.x > 0)

  step("select three killed traces", proc (f: FrameInfo) =
    let b = f.baseOf
    f.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
      edited: @[b + 2, b + 3], on: true)
    f.apply(Command(kind: ckSelect, traces: @[b + 1, b + 2, b + 3], mode: smReplace)),
      proc (f: FrameInfo): bool =
      f.core.selection.selectedCount == 3 and f.has(1, teKilled) and f.has(2, teKilled) and
        f.has(3, teKilled) and f.markOf("plot.header.edit 2").size.x > 0)
  point("point at a selected kill", "plot.header.edit 2")
  rightClick("the selection menu did not open")
  step("the selection line", noop, proc (f: FrameInfo): bool =
    f.markOf("plot.editmenu.item Remove kill from 3 selected traces").size.x > 0)
  choose("remove the selection", "Remove kill from 3 selected traces")
  step("the selected kills stayed", noop, proc (f: FrameInfo): bool =
    not f.has(1, teKilled) and not f.has(2, teKilled) and not f.has(3, teKilled))
  undo()
  step("undo did not bring the selected kills back", noop, proc (f: FrameInfo): bool =
    f.has(1, teKilled) and f.has(2, teKilled) and f.has(3, teKilled))

  step("kill and reverse one trace", proc (f: FrameInfo) =
    let b = f.baseOf
    f.apply Command(kind: ckClearSelection)
    f.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[b + 6], on: true)
    f.apply(Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[b + 6],
      on: true)), proc (f: FrameInfo): bool =
      f.has(6, teKilled) and f.has(6, teReversed) and
        f.markOf("plot.header.edit 7").size.x > 0)
  point("point at both edits", "plot.header.edit 7")
  rightClick("the menu did not open on both edits")
  step("remove all is offered", noop, proc (f: FrameInfo): bool =
    f.markOf("plot.editmenu.item Remove all edits of this trace").size.x > 0)
  choose("remove all", "Remove all edits of this trace")
  step("an edit stayed", noop, proc (f: FrameInfo): bool =
    not f.has(6, teKilled) and not f.has(6, teReversed) and
      f.markOf("plot.header.edit 7").size.x == 0)
  undo()
  step("one undo did not bring both edits back", noop, proc (f: FrameInfo): bool =
    f.has(6, teKilled) and f.has(6, teReversed))

  step("density", proc (f: FrameInfo) =
    var d = f.panel.layers[0].display
    d.mode = dmDensity
    f.apply(Command(kind: ckDisplay, panel: MainPanel, display: d)),
    proc (f: FrameInfo): bool =
      f.answered and f.panel.layers[0].display.mode == dmDensity)
  zoom(-0.5, 199.5)
  step("the zoomed-out marks", noop, proc (f: FrameInfo): bool =
    let m = f.markOf("plot.header.edit 2")
    result = m.size.x > 0 and m.size.x < 4 and f.markOf("plot.header.edits").size.x > 0)
  point("point at the zoomed-out row", "plot.header.edit 2")
  rightClick("the zoomed-out menu did not open")
  step("the zoomed-out menu", noop, proc (f: FrameInfo): bool =
    let title = f.markOf("plot.editmenu.title")
    result = title.size.x > 0 and
      (f.markOf("plot.editmenu.item Remove kill").size.x > 0 or
        f.markOf("plot.editmenu.item Remove all edits of these traces").size.x > 0))
  choose("remove the zoomed-out kills", "Remove kill")
  step("the zoomed-out kill stayed", noop, proc (f: FrameInfo): bool =
    not f.has(1, teKilled) and f.markOf("plot.header.edit 2").size.x == 0)
  undo()
  step("undo did not bring the zoomed-out kill back", noop, proc (f: FrameInfo): bool =
    f.has(1, teKilled) and f.markOf("plot.header.edit 2").size.x > 0)

  runSteps(land, steps, fx.dir)

echo "tguieditmarks: ok"
