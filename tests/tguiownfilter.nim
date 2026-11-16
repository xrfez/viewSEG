## A trace's own filter from the plot's menu, headless, on samples/land/shots.sgy:
## the context menu entry, the popover, Apply, the mark in the header strip,
## Remove, and undo.
##
## Seen to fail: with the menu item not opening the popover (`ownAsk` left
## false), "the popover did not open"; with Apply not posting `ckOwnFilter`,
## "Apply did not set the filter"; with the header row leaving the filter
## icon out, "no filter mark over trace 1"; with Remove posting nothing,
## "Remove did not take the filter away"; with undo not restoring it,
## "undo did not bring the filter back".
##
## Needs a display: run under xvfb-run.

import std/[math, os]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
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
