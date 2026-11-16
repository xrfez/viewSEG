## A trace's own filter from the plot's menu, headless, on samples/land/shots.sgy:
## the context menu entry, the popover, Apply, the mark in the header strip,
## Remove, and undo.
##
## Seen to fail: with the menu item not opening the popover (`ownAsk` left
## false), "the popover did not open"; with Apply not posting `ckOwnFilter`,
## "Apply did not set the filter"; with the header row leaving the filter
## icon out, "no filter mark over trace 1"; with Remove posting nothing,
## "Remove did not take the filter away"; with undo not restoring it,
## "undo did not bring the filter back". With Apply always storing a filter,
## "Apply with nothing set did not remove the filter". With a filter-only
## mark in the dim colour, `editColour({}, true)` was not the accent. With
## the star only when a filter was added or removed, a changed filter the
## file already remembered had no star.
##
## Needs a display: run under xvfb-run.

import std/[math, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/[app, tracepanel]
import viewSEG/view/theme
import utils/waiting

const root = currentSourcePath().parentDir.parentDir
let land = root / "samples" / "land" / "shots.sgy"
let shot = root / ".scratch" / "ownfilter-land.png"

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc answered(f: FrameInfo): bool =
  let p = f.panel
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  p.laidOut and not p.pending.isEmpty and p.pending.gen == p.requestGen and tiles.len > 0 and
    tiles[^1].request == p.pending and f.tracePanel.drawnView.sameSpans(p.view)

proc pointAt(f: FrameInfo; position: int): Vec2 =
  let v = f.panel.view.screenAt(f.markOf("plot.data"), DataPoint(x: float64(position), tMs: 400))
  vec2(round(v.x), round(v.y))

proc click(f: FrameInfo; q: Vec2; button = 1) =
  f.pressMouse(q, true, button)
  f.pressMouse(q, false, button)

proc chord(f: FrameInfo; key: SimKey; mods: set[SimMod] = {}) =
  const modKeys: array[SimMod, SimKey] = [skCtrl, skShift, skAlt]
  for m in mods: f.pressKey(modKeys[m], true, mods)
  f.pressKey(key, true, mods)
  f.pressKey(key, false, mods)
  for m in mods: f.pressKey(modKeys[m], false)

doAssert fileExists(land), "samples/land/shots.sgy is not here"

block markColour:
  # Seen to fail with a filter-only mark in the dim colour: editColour({}, true)
  # was rlTextDim. A filter that differs from the one remembered had no star.
  doAssert editColour({}, true) == rlAccent
  doAssert editColour({teReversed}, false) == rlAccent
  doAssert editColour({teKilled}, true) == rlError
  doAssert editColour({}, false) == rlTextDim
  let a = OwnFilter(spec: Processing(band: pbBandPass), place: fpAfter)
  let b = OwnFilter(spec: Processing(band: pbHighCut), place: fpAfter)
  doAssert editStar({}, {}, true, true, b, a)
  doAssert not editStar({}, {}, true, true, a, a)
  doAssert editStar({}, {}, true, false, a, OwnFilter())

var steps: seq[Step]
var at = 0
var started = false
var wait = 0
var since = getMonoTime()
var failed = ""

proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
  steps.add Step(name: name, act: act, done: done)

proc noop(f: FrameInfo) = discard

proc hasFilter(f: FrameInfo; trace: int): bool =
  f.core.ownAt(f.core.sessions[0].path, trace).has

step("the file opens", noop, proc (f: FrameInfo): bool =
  f.panel.laidOut and f.panel.layout.traces > 8 and f.answered)
step("the first traces", proc (f: FrameInfo) =
  var v = f.panel.view
  v.traces = Span(lo: -0.5, hi: 15.5)
  f.showView(v), proc (f: FrameInfo): bool = f.answered and wait > 4)
var q: Vec2
step("point", proc (f: FrameInfo) =
  q = f.pointAt(0)
  f.moveMouse(q), proc (f: FrameInfo): bool = wait > 3)
step("focus", proc (f: FrameInfo) = f.click(q), proc (f: FrameInfo): bool = wait > 3)
step("the menu", proc (f: FrameInfo) = f.click(q, button = 3), proc (f: FrameInfo): bool =
  f.markOf("plot.menu.filter").size.x > 0 and wait > 2)
var item: Vec2
step("point at Filter", proc (f: FrameInfo) =
  item = f.markOf("plot.menu.filter").centre
  f.moveMouse(item), proc (f: FrameInfo): bool = wait > 2)
step("Filter this trace...", proc (f: FrameInfo) = f.click(item), proc (f: FrameInfo): bool =
  result = f.markOf("plot.ownfilter popup").size.x > 0 and wait > 2
  if not result and wait > 40: failed = "the popover did not open")
var band, apply: Vec2
step("point at Band-pass", proc (f: FrameInfo) =
  band = f.markOf("plot.ownfilter band band-pass").centre
  f.moveMouse(band), proc (f: FrameInfo): bool = wait > 2)
step("Band-pass", proc (f: FrameInfo) = f.click(band), proc (f: FrameInfo): bool =
  f.markOf("plot.ownfilter apply").size.x > 0 and wait > 2)
step("point at Apply", proc (f: FrameInfo) =
  apply = f.markOf("plot.ownfilter apply").centre
  f.moveMouse(apply), proc (f: FrameInfo): bool = wait > 2)
step("Apply", proc (f: FrameInfo) = f.click(apply), proc (f: FrameInfo): bool =
  result = f.hasFilter(0) and f.answered and wait > 3
  if not result and wait > 80: failed = "Apply did not set the filter")
step("the mark", noop, proc (f: FrameInfo): bool =
  result = f.markOf("plot.header.filter 1").size.x > 0 and wait > 3
  if not result and wait > 40: failed = "no filter mark over trace 1")
# a second trace, then the popover again, for the picture
var q1: Vec2
step("point at the next", proc (f: FrameInfo) =
  q1 = f.pointAt(1)
  f.moveMouse(q1), proc (f: FrameInfo): bool = wait > 3)
step("its menu", proc (f: FrameInfo) = f.click(q1, button = 3), proc (f: FrameInfo): bool =
  f.markOf("plot.menu.filter").size.x > 0 and wait > 2)
step("point at Filter again", proc (f: FrameInfo) =
  item = f.markOf("plot.menu.filter").centre
  f.moveMouse(item), proc (f: FrameInfo): bool = wait > 2)
step("Filter the next", proc (f: FrameInfo) = f.click(item), proc (f: FrameInfo): bool =
  f.markOf("plot.ownfilter popup").size.x > 0 and wait > 2)
step("point at Band-pass again", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.ownfilter band band-pass").centre), proc (f: FrameInfo): bool = wait > 2)
step("Band-pass again", proc (f: FrameInfo) =
  f.click(f.markOf("plot.ownfilter band band-pass").centre), proc (f: FrameInfo): bool = wait > 2)
step("point at Apply again", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.ownfilter apply").centre), proc (f: FrameInfo): bool = wait > 2)
step("Apply the next", proc (f: FrameInfo) =
  f.click(f.markOf("plot.ownfilter apply").centre), proc (f: FrameInfo): bool =
  f.hasFilter(1) and f.answered and wait > 3)
step("point again", proc (f: FrameInfo) =
  q1 = f.pointAt(1)
  f.moveMouse(q1), proc (f: FrameInfo): bool =
  f.markOf("plot.ownfilter popup").size.x == 0 and wait > 4)
step("its menu again", proc (f: FrameInfo) = f.click(q1, button = 3), proc (f: FrameInfo): bool =
  f.markOf("plot.menu.filter").size.x > 0 and wait > 2)
step("point at Filter for the picture", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool = wait > 2)
step("open the popover", proc (f: FrameInfo) =
  f.click(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool =
  f.markOf("plot.ownfilter popup").size.x > 0 and f.markOf("plot.header.filter 1").size.x > 0 and
    f.markOf("plot.header.filter 2").size.x > 0 and wait > 3)
step("the picture", proc (f: FrameInfo) =
  if not f.savePng(shot): failed = "cannot save " & shot, proc (f: FrameInfo): bool = wait > 2)
step("point at Apply to close", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.ownfilter apply").centre), proc (f: FrameInfo): bool = wait > 2)
step("close the popover", proc (f: FrameInfo) =
  f.click(f.markOf("plot.ownfilter apply").centre), proc (f: FrameInfo): bool =
  f.markOf("plot.ownfilter popup").size.x == 0 and wait > 2)
step("point for Remove", proc (f: FrameInfo) =
  f.moveMouse(q), proc (f: FrameInfo): bool = wait > 3)
step("menu for Remove", proc (f: FrameInfo) = f.click(q, button = 3), proc (f: FrameInfo): bool =
  f.markOf("plot.menu.removefilter").size.x > 0 and wait > 2)
step("point at Remove", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.menu.removefilter").centre), proc (f: FrameInfo): bool = wait > 2)
step("Remove", proc (f: FrameInfo) =
  f.click(f.markOf("plot.menu.removefilter").centre), proc (f: FrameInfo): bool =
  result = not f.hasFilter(0) and f.answered and wait > 3
  if not result and wait > 80: failed = "Remove did not take the filter away")
step("undo", proc (f: FrameInfo) = f.chord(skZ, {smCtrl}), proc (f: FrameInfo): bool =
  result = f.hasFilter(0) and f.answered and wait > 3
  if not result and wait > 80: failed = "undo did not bring the filter back")
# both traces filtered the same way: select them and read the N-trace menu
step("point at the first", proc (f: FrameInfo) =
  q = f.pointAt(0)
  q1 = f.pointAt(1)
  f.moveMouse(q), proc (f: FrameInfo): bool = wait > 2)
step("select the first", proc (f: FrameInfo) = f.click(q), proc (f: FrameInfo): bool =
  let id = f.core.sessions[0].base
  result = f.core.selection.selectedCount == 1 and id in f.core.selection.selected and wait > 2
  if not result and wait > 40:
    var ids: seq[int]
    for t in f.core.selection.selected: ids.add t
    failed = "trace 1 was not selected alone: " & $ids)
step("point at the next to add", proc (f: FrameInfo) =
  f.moveMouse(q1), proc (f: FrameInfo): bool = wait > 2)
step("shift-click the next", proc (f: FrameInfo) =
  f.pressKey(skShift, true, {smShift})
  f.click(q1)
  f.pressKey(skShift, false), proc (f: FrameInfo): bool =
  f.core.selection.selectedCount == 2 and wait > 2)
step("menu of the selection", proc (f: FrameInfo) = f.click(q1, button = 3),
  proc (f: FrameInfo): bool =
  f.markOf("plot.menu.filter.item Filter 2 selected traces...").size.x > 0 and
    f.markOf("plot.menu.removefilter.item Remove the filters of 2 traces").size.x > 0 and
    wait > 2)
step("close that menu", proc (f: FrameInfo) =
  f.pressKey(skEscape, true)
  f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
  f.markOf("plot.menu").size.x == 0 and wait > 2)
# make the second trace's filter differ (it alone), then the mixed message
step("point at only the next", proc (f: FrameInfo) =
  q1 = f.pointAt(1)
  f.moveMouse(q1), proc (f: FrameInfo): bool = wait > 2)
step("select only the next", proc (f: FrameInfo) = f.click(q1), proc (f: FrameInfo): bool =
  let id = f.core.sessions[0].base + 1
  result = f.core.selection.selectedCount == 1 and id in f.core.selection.selected and wait > 2
  if not result and wait > 40: failed = "trace 2 was not selected alone")
step("point at the next for instead", proc (f: FrameInfo) =
  f.moveMouse(q1), proc (f: FrameInfo): bool = wait > 2)
step("its menu for instead", proc (f: FrameInfo) = f.click(q1, button = 3),
  proc (f: FrameInfo): bool = f.markOf("plot.menu.filter").size.x > 0 and wait > 2)
step("point at Filter for instead", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool = wait > 1)
step("open instead", proc (f: FrameInfo) =
  f.click(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool =
  f.markOf("plot.ownfilter popup").size.x > 0 and wait > 2)
step("point at Instead", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.ownfilter instead").centre), proc (f: FrameInfo): bool = wait > 1)
step("Instead", proc (f: FrameInfo) =
  f.click(f.markOf("plot.ownfilter instead").centre), proc (f: FrameInfo): bool = wait > 1)
step("point at Apply instead", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.ownfilter apply").centre), proc (f: FrameInfo): bool = wait > 1)
step("Apply instead", proc (f: FrameInfo) =
  f.click(f.markOf("plot.ownfilter apply").centre), proc (f: FrameInfo): bool =
  f.hasFilter(1) and f.markOf("plot.ownfilter popup").size.x == 0 and wait > 2)
step("point at the first again", proc (f: FrameInfo) =
  q = f.pointAt(0)
  q1 = f.pointAt(1)
  f.moveMouse(q), proc (f: FrameInfo): bool = wait > 2)
step("select the first again", proc (f: FrameInfo) = f.click(q), proc (f: FrameInfo): bool =
  let id = f.core.sessions[0].base
  result = f.core.selection.selectedCount == 1 and id in f.core.selection.selected and wait > 2)
step("point at the next for the range", proc (f: FrameInfo) =
  f.moveMouse(q1), proc (f: FrameInfo): bool = wait > 2)
step("shift-click for mixed", proc (f: FrameInfo) =
  f.pressKey(skShift, true, {smShift})
  f.click(q1)
  f.pressKey(skShift, false), proc (f: FrameInfo): bool =
  f.core.selection.selectedCount == 2 and wait > 2)
step("menu for mixed", proc (f: FrameInfo) = f.click(q1, button = 3),
  proc (f: FrameInfo): bool = f.markOf("plot.menu.filter").size.x > 0 and wait > 2)
step("point at Filter for mixed", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool = wait > 1)
step("open mixed", proc (f: FrameInfo) =
  f.click(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool =
    result = f.markOf("plot.ownfilter mixed the selected traces have different filters").size.x > 0 and
      wait > 2
    if not result and wait > 40: failed = "the mixed-filters message did not show")
step("point at Cancel", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.ownfilter cancel").centre), proc (f: FrameInfo): bool = wait > 1)
step("Cancel", proc (f: FrameInfo) =
  f.click(f.markOf("plot.ownfilter cancel").centre), proc (f: FrameInfo): bool =
    result = f.markOf("plot.ownfilter popup").size.x == 0 and f.hasFilter(1) and wait > 2
    if not result and wait > 40: failed = "Cancel applied or did not close")
step("point for Escape", proc (f: FrameInfo) =
  q = f.pointAt(0)
  f.moveMouse(q), proc (f: FrameInfo): bool = wait > 2)
step("menu for Escape", proc (f: FrameInfo) = f.click(q, button = 3),
  proc (f: FrameInfo): bool = f.markOf("plot.menu.filter").size.x > 0 and wait > 2)
step("point at Filter for Escape", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool = wait > 1)
step("open for Escape", proc (f: FrameInfo) =
  f.click(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool =
  f.markOf("plot.ownfilter popup").size.x > 0 and wait > 2)
step("Escape", proc (f: FrameInfo) =
  f.pressKey(skEscape, true)
  f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
    result = f.markOf("plot.ownfilter popup").size.x == 0 and f.hasFilter(0) and wait > 2
    if not result and wait > 40: failed = "Escape applied the filter")
step("point for outside", proc (f: FrameInfo) =
  q = f.pointAt(0)
  f.moveMouse(q), proc (f: FrameInfo): bool = wait > 2)
step("menu for outside", proc (f: FrameInfo) = f.click(q, button = 3),
  proc (f: FrameInfo): bool = f.markOf("plot.menu.filter").size.x > 0 and wait > 2)
step("point at Filter for outside", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool = wait > 1)
step("open for outside", proc (f: FrameInfo) =
  f.click(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool =
  f.markOf("plot.ownfilter popup").size.x > 0 and wait > 2)
step("point outside", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("statusbar").centre), proc (f: FrameInfo): bool = wait > 1)
step("click outside", proc (f: FrameInfo) =
  f.click(f.markOf("statusbar").centre), proc (f: FrameInfo): bool =
    result = f.markOf("plot.ownfilter popup").size.x == 0 and f.hasFilter(0) and wait > 2
    if not result and wait > 40: failed = "a click outside applied the filter")
# Clear then Apply takes the filter away
step("point for Clear", proc (f: FrameInfo) =
  q = f.pointAt(0)
  f.moveMouse(q), proc (f: FrameInfo): bool = wait > 2)
step("menu for Clear", proc (f: FrameInfo) = f.click(q, button = 3),
  proc (f: FrameInfo): bool = f.markOf("plot.menu.filter").size.x > 0 and wait > 2)
step("point at Filter for Clear", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool = wait > 1)
step("open for Clear", proc (f: FrameInfo) =
  f.click(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool =
  f.markOf("plot.ownfilter clear").size.x > 0 and wait > 2)
step("point at Clear", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.ownfilter clear").centre), proc (f: FrameInfo): bool = wait > 1)
step("Clear", proc (f: FrameInfo) =
  f.click(f.markOf("plot.ownfilter clear").centre), proc (f: FrameInfo): bool = wait > 1)
step("point at Apply clear", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.ownfilter apply").centre), proc (f: FrameInfo): bool = wait > 1)
step("Apply clear", proc (f: FrameInfo) =
  f.click(f.markOf("plot.ownfilter apply").centre), proc (f: FrameInfo): bool =
    result = not f.hasFilter(0) and f.answered and wait > 3
    if not result and wait > 80: failed = "Apply with nothing set did not remove the filter")
# nothing set, after, on a trace that has none: no step
var undoBefore = ""
step("point at a trace with none", proc (f: FrameInfo) =
  q = f.pointAt(0)
  f.moveMouse(q), proc (f: FrameInfo): bool = wait > 2)
step("menu on a trace with none", proc (f: FrameInfo) =
  undoBefore = f.core.editsOf(0).undoText
  f.click(q, button = 3), proc (f: FrameInfo): bool = f.markOf("plot.menu.filter").size.x > 0 and
      wait > 2)
step("point at Filter empty", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool = wait > 1)
step("open empty", proc (f: FrameInfo) =
  f.click(f.markOf("plot.menu.filter").centre), proc (f: FrameInfo): bool =
  f.markOf("plot.ownfilter apply").size.x > 0 and wait > 2)
step("point at Apply empty", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("plot.ownfilter apply").centre), proc (f: FrameInfo): bool = wait > 1)
step("Apply empty", proc (f: FrameInfo) =
  f.click(f.markOf("plot.ownfilter apply").centre), proc (f: FrameInfo): bool =
    result = not f.hasFilter(0) and f.core.editsOf(0).undoText == undoBefore and wait > 2
    if not result and wait > 40: failed = "Apply with nothing set stored a filter")
# the Headers table's tooltip
var tableMark = ""
step("a filter for the table", proc (f: FrameInfo) =
  let b = f.core.sessions[0].base
  f.apply(Command(kind: ckOwnFilter, panel: MainPanel, edited: @[b + 1], on: true,
    processing: Processing(band: pbBandPass, f1: 4, f2: 8, f3: 60, f4: 80),
    filterPlace: fpAfter)), proc (f: FrameInfo): bool = f.hasFilter(1) and wait > 2)
step("point at the table tab", proc (f: FrameInfo) =
  f.moveMouse(f.markOf("headers.tab table").centre), proc (f: FrameInfo): bool = wait > 1)
step("headers table", proc (f: FrameInfo) =
  f.click(f.markOf("headers.tab table").centre), proc (f: FrameInfo): bool =
  for n in f.markNames("table.filter "):
    if not strutils.contains(n, "tip") and f.markOf(n).size.x > 0: tableMark = n
  result = tableMark.len > 0 and wait > 3
  if not result and wait > 80:
    var names: seq[string]
    for n in f.markNames("headers.tab"): names.add n
    for n in f.markNames("table."): names.add n
    failed = "headers table: " & names.join(", "))
step("point at the table's filter", proc (f: FrameInfo) =
  let r = f.markOf(tableMark)
  f.moveMouse(vec2(r.pos.x + 12, r.pos.y + r.size.y / 2)), proc (f: FrameInfo): bool =
    var tip = ""
    for n in f.markNames("table.filter tip "): tip = n
    result = strutils.contains(tip, "Band-pass") and wait > 2
    if not result and wait > 80: failed = "the Headers table tooltip did not show over " &
        $f.markOf(tableMark))

proc onFrame(f: FrameInfo) =
  if failed.len > 0 or at >= steps.len:
    f.stop()
    return
  if not started:
    steps[at].act(f)
    started = true
    wait = 0
    since = getMonoTime()
  else:
    inc wait
    if steps[at].done(f):
      if failed.len == 0:
        inc at
        started = false
    elif overdue(wait, 300, since):
      if failed.len == 0: failed = steps[at].name & " did not happen"
      f.stop()

let code = run(RunOptions(openPaths: @[land], windowSize: (1600, 1000), theme: forceDark,
  persist: false, configDir: some(root / ".scratch" / "ownfilter-config"),
  indexCacheDir: some(root / ".scratch" / "ownfilter-cache"),
  logDir: some(root / ".scratch" / "ownfilter-log"), onFrame: onFrame))
doAssert code == 0, "run() exit code " & $code
doAssert failed.len == 0, failed
doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
doAssert fileExists(shot), "no picture at " & shot
echo "tguiownfilter: ok"
