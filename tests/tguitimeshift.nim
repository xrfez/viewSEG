## A trace's time shift from the plot's menu, headless, on samples/land/shots.sgy:
## the context menu entry, the popover (7 ms snaps to +8 ms), Apply, the mark
## and its tooltip, the samples moved, undo, Remove from the mark menu, a
## selection of seismic traces, and the entry absent on an auxiliary trace.
##
## Seen to fail: with the shown 0 left in place when the field is clicked,
## "typing 7 kept 07" (Enter still applies the snap of 7, not 0 or 70); with
## the menu item not opening the popover, "the popover did not open"; with the
## snap line wrong, "the snap line was not applies +8 ms"; with Apply not
## posting the shift, "Apply did not shift the trace"; with the header row
## leaving the clock out, "no shift mark over trace 1"; with the tooltip not
## naming the shift, "the mark tooltip did not say shifted"; with the samples
## unmoved, "the spike did not move by 4 samples"; with undo not restoring
## them, "undo did not take the shift away"; with Remove posting nothing,
## "Remove did not take the shift away"; with the selection menu naming one
## trace, "the selection was not Time shift of 2"; with the entry drawn on an
## auxiliary trace, "Time shift was offered on an auxiliary trace".
##
## Needs a display: run under xvfb-run.

import std/[math, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/[app, tracepanel]
import utils/[fixtures, waiting]

const root = currentSourcePath().parentDir.parentDir

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

proc named(f: FrameInfo; prefix, needle: string): bool =
  for n in f.markNames(prefix):
    if needle in n: return true

proc fieldText(f: FrameInfo): string =
  const prefix = "plot.timeshift typed "
  for n in f.markNames("plot.timeshift"):
    if n.startsWith(prefix): return n[prefix.len .. ^1]

proc rowOf(f: FrameInfo; trace: int): seq[float32] =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  doAssert tiles.len > 0, "no tile"
  let t = tiles[^1]
  let r = t.traces.find(trace)
  doAssert r >= 0, "trace " & $(trace + 1) & " is not in the tile"
  t.data[r * t.columns ..< (r + 1) * t.columns]

proc lagOf(before, after: seq[float32]): int =
  ## How many samples later `after` is than `before` (the lag with the best match).
  result = -999
  if before.len == 0 or after.len == 0: return
  var best = -1e300
  for lag in -12 .. 12:
    var score = 0.0
    let n = min(before.len, after.len)
    for i in 8 ..< n - 8:
      let j = i - lag
      if j >= 0 and j < before.len: score += float64(before[j]) * float64(after[i])
    if score > best:
      best = score
      result = lag

var steps: seq[Step]
var at = 0
var started = false
var wait = 0
var since = getMonoTime()
var failed = ""
var before: seq[float32]

proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
  steps.add Step(name: name, act: act, done: done)

proc noop(f: FrameInfo) = discard

proc shiftOf(f: FrameInfo; trace: int): float64 =
  f.core.shownShift(f.core.sessions[0].base + trace)

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

proc main*() =
  let land = root / "samples" / "land" / "shots.sgy"
  let shots = root / ".scratch" / "shots"
  createDir(shots)
  let popoverShot = shots / "timeshift-popover.png"
  let markShot = shots / "timeshift-mark.png"
  doAssert fileExists(land), "samples/land/shots.sgy is not here"

  var q: Vec2
  step("the file opens", noop, proc (f: FrameInfo): bool =
    f.panel.laidOut and f.panel.layout.traces > 8 and f.answered and f.panel.layout.dtMs == 2.0)
  step("the first traces", proc (f: FrameInfo) =
    var v = f.panel.view
    v.traces = Span(lo: -0.5, hi: 15.5)
    v.timeMs = Span(lo: 100, hi: 500)
    f.showView(v), proc (f: FrameInfo): bool = f.answered)
  var kept = ""
  step("point to replace", proc (f: FrameInfo) =
    q = f.pointAt(0)
    f.moveMouse(q), proc (f: FrameInfo): bool = f.markOf("plot.data").size.x > 0)
  step("menu to replace", proc (f: FrameInfo) = f.click(q, button = 3), proc (f: FrameInfo): bool =
    f.markOf("plot.menu.shift.item Time shift...").size.x > 0)
  step("point at Time shift to replace", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("plot.menu.shift").centre), proc (f: FrameInfo): bool =
    f.markOf("plot.menu.shift").size.x > 0 and wait > 2)
  step("open to replace", proc (f: FrameInfo) =
    f.click(f.markOf("plot.menu.shift").centre), proc (f: FrameInfo): bool =
    f.markOf("plot.timeshift popup").size.x > 0 and wait > 6)
  step("click the field to replace", proc (f: FrameInfo) =
    let q = f.markOf("plot.timeshift field").centre
    f.moveMouse(q)
    f.pressMouse(q, true)
    f.pressMouse(q, false), proc (f: FrameInfo): bool = f.typing and wait > 4)
  step("type 7 over the shown 0", proc (f: FrameInfo) = f.typeText("7"), proc (f: FrameInfo): bool =
    result = wait > 6
    if result: kept = f.fieldText)
  step("Enter applies the typed 7", proc (f: FrameInfo) = f.chord(skEnter), proc (
      f: FrameInfo): bool =
    # 7 ms on this file (2 ms samples) is stored as +8 ms. The bug leaves "07"
    # in the field; that still snaps to 8, so the text is what fails.
    result = kept == "7" and f.shiftOf(0) == 8.0 and f.answered and
      f.markOf("plot.timeshift popup").size.x == 0
    if not result and wait > 80:
      failed = "typing 7 kept " & kept & ", shift " & $f.shiftOf(0))
  step("undo the replaced shift", proc (f: FrameInfo) = f.chord(skZ, {smCtrl}),
    proc (f: FrameInfo): bool =
    result = f.shiftOf(0) == 0.0 and f.answered
    if not result and wait > 80: failed = "undo did not take the replaced shift away")
  step("point", proc (f: FrameInfo) =
    q = f.pointAt(0)
    f.moveMouse(q), proc (f: FrameInfo): bool = f.markOf("plot.data").size.x > 0)
  step("the menu", proc (f: FrameInfo) = f.click(q, button = 3), proc (f: FrameInfo): bool =
    f.markOf("plot.menu.shift.item Time shift...").size.x > 0)
  var item: Vec2
  step("point at Time shift", proc (f: FrameInfo) =
    item = f.markOf("plot.menu.shift").centre
    f.moveMouse(item), proc (f: FrameInfo): bool = f.markOf("plot.menu.shift").size.x > 0)
  step("Time shift...", proc (f: FrameInfo) = f.click(item), proc (f: FrameInfo): bool =
    result = f.markOf("plot.timeshift popup").size.x > 0
    if not result and wait > 40: failed = "the popover did not open")
  step("point at the field", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("plot.timeshift field").centre), proc (f: FrameInfo): bool = wait > 2)
  step("click the field", proc (f: FrameInfo) =
    let q = f.markOf("plot.timeshift field").centre
    f.pressMouse(q, true)
    f.pressMouse(q, false), proc (f: FrameInfo): bool = f.typing and wait > 4)
  step("type 7", proc (f: FrameInfo) =
    f.pressKey(skCtrl, true, {smCtrl})
    f.typeText("a")
    f.pressKey(skCtrl, false)
    f.typeText("7"), proc (f: FrameInfo): bool =
    result = f.named("plot.timeshift applies", "applies +8 ms")
    if not result and wait > 12:
      failed = "the snap line was not applies +8 ms: " & $f.markNames("plot.timeshift"))
  step("the popover picture", proc (f: FrameInfo) =
    if not f.savePng(popoverShot): failed = "cannot save " & popoverShot,
    proc (f: FrameInfo): bool = fileExists(popoverShot))
  step("point at Apply", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("plot.timeshift apply").centre),
    proc (f: FrameInfo): bool = f.markOf("plot.timeshift apply").size.x > 0)
  step("Apply", proc (f: FrameInfo) =
    before = f.rowOf(0)
    f.click(f.markOf("plot.timeshift apply").centre), proc (f: FrameInfo): bool =
    result = f.shiftOf(0) == 8.0 and f.answered and f.markOf("plot.timeshift popup").size.x == 0
    if not result and wait > 80: failed = "Apply did not shift the trace")
  step("the mark", noop, proc (f: FrameInfo): bool =
    result = f.markOf("plot.header.shift 1").size.x > 0
    if not result and wait > 40: failed = "no shift mark over trace 1")
  step("point at the mark", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("plot.header.shift 1").centre), proc (f: FrameInfo): bool =
    result = f.named("plot.header.edit tip", "shifted")
    if not result and wait > 40: failed = "the mark tooltip did not say shifted")
  step("the mark picture", proc (f: FrameInfo) =
    if not f.savePng(markShot): failed = "cannot save " & markShot,
    proc (f: FrameInfo): bool = fileExists(markShot))
  step("the spike moved", noop, proc (f: FrameInfo): bool =
    let after = f.rowOf(0)
    let tiles = f.core.tiles(f.core.findPanel(MainPanel))
    let dec = max(1, tiles[^1].request.decimation)
    let lag = lagOf(before, after)
    # a 4-sample file shift, in the tile's columns (one column is `dec` samples)
    result = f.answered and lag == 4 div dec and lag > 0
    if not result and wait > 40:
      failed = "the spike did not move by 4 samples: lag " & $lag & " decimation " & $dec)
  step("undo", proc (f: FrameInfo) = f.chord(skZ, {smCtrl}), proc (f: FrameInfo): bool =
    result = f.shiftOf(0) == 0.0 and f.answered and f.markOf("plot.header.shift 1").size.x == 0
    if not result and wait > 80: failed = "undo did not take the shift away")
  step("point again", proc (f: FrameInfo) =
    q = f.pointAt(0)
    f.moveMouse(q), proc (f: FrameInfo): bool = f.markOf("plot.data").size.x > 0)
  step("menu again", proc (f: FrameInfo) = f.click(q, button = 3), proc (f: FrameInfo): bool =
    f.markOf("plot.menu.shift").size.x > 0)
  step("point at Time shift again", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("plot.menu.shift").centre), proc (f: FrameInfo): bool =
    f.markOf("plot.menu.shift").size.x > 0 and wait > 2)
  step("open again", proc (f: FrameInfo) =
    f.click(f.markOf("plot.menu.shift").centre), proc (f: FrameInfo): bool =
    f.markOf("plot.timeshift popup").size.x > 0)
  step("point at the field again", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("plot.timeshift field").centre), proc (f: FrameInfo): bool = wait > 2)
  step("click the field again", proc (f: FrameInfo) =
    let q = f.markOf("plot.timeshift field").centre
    f.pressMouse(q, true)
    f.pressMouse(q, false), proc (f: FrameInfo): bool = f.typing and wait > 4)
  step("type 7 again", proc (f: FrameInfo) =
    f.pressKey(skCtrl, true, {smCtrl})
    f.typeText("a")
    f.pressKey(skCtrl, false)
    f.typeText("7"), proc (f: FrameInfo): bool =
    f.named("plot.timeshift applies", "applies +8 ms"))
  step("point at Apply again", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("plot.timeshift apply").centre), proc (f: FrameInfo): bool =
    f.markOf("plot.timeshift apply").size.x > 0 and wait > 2)
  step("Apply again", proc (f: FrameInfo) =
    f.click(f.markOf("plot.timeshift apply").centre), proc (f: FrameInfo): bool =
    f.shiftOf(0) == 8.0 and f.answered and f.markOf("plot.header.shift 1").size.x > 0)
  step("point at the mark to remove", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("plot.header.shift 1").centre),
    proc (f: FrameInfo): bool = f.markOf("plot.header.shift 1").size.x > 0 and wait > 2)
  step("the mark menu", proc (f: FrameInfo) =
    f.click(f.markOf("plot.header.shift 1").centre, button = 3), proc (f: FrameInfo): bool =
    f.markOf("plot.editmenu.item Remove the time shift").size.x > 0 and
      f.markOf("plot.editmenu.item Edit the time shift...").size.x > 0)
  step("point at Remove", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("plot.editmenu.item Remove the time shift").centre),
    proc (f: FrameInfo): bool = wait > 2)
  step("Remove", proc (f: FrameInfo) =
    f.click(f.markOf("plot.editmenu.item Remove the time shift").centre),
    proc (f: FrameInfo): bool =
    result = f.shiftOf(0) == 0.0 and f.answered
    if not result and wait > 80: failed = "Remove did not take the shift away")
  var q1: Vec2
  step("point at the first of two", proc (f: FrameInfo) =
    q = f.pointAt(0)
    q1 = f.pointAt(1)
    f.moveMouse(q), proc (f: FrameInfo): bool = f.markOf("plot.data").size.x > 0)
  step("select the first", proc (f: FrameInfo) = f.click(q), proc (f: FrameInfo): bool =
    f.core.selection.selectedCount == 1)
  step("point at the next", proc (f: FrameInfo) =
    f.moveMouse(q1), proc (f: FrameInfo): bool = f.markOf("plot.data").size.x > 0)
  step("shift-click the next", proc (f: FrameInfo) =
    f.pressKey(skShift, true, {smShift})
    f.click(q1)
    f.pressKey(skShift, false), proc (f: FrameInfo): bool =
    f.core.selection.selectedCount == 2)
  step("menu of the selection", proc (f: FrameInfo) = f.click(q1, button = 3),
    proc (f: FrameInfo): bool =
    result = f.markOf("plot.menu.shift.item Time shift of 2 selected traces...").size.x > 0
    if not result and wait > 40: failed = "the selection was not Time shift of 2")
  step("point at Time shift of 2", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("plot.menu.shift").centre), proc (f: FrameInfo): bool =
    f.markOf("plot.menu.shift").size.x > 0 and wait > 2)
  step("Time shift of 2", proc (f: FrameInfo) =
    f.click(f.markOf("plot.menu.shift").centre), proc (f: FrameInfo): bool =
    f.markOf("plot.timeshift popup").size.x > 0)
  step("point at the field of 2", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("plot.timeshift field").centre), proc (f: FrameInfo): bool = wait > 2)
  step("click the field of 2", proc (f: FrameInfo) =
    let q = f.markOf("plot.timeshift field").centre
    f.pressMouse(q, true)
    f.pressMouse(q, false), proc (f: FrameInfo): bool = f.typing and wait > 4)
  step("type 7 for both", proc (f: FrameInfo) =
    f.pressKey(skCtrl, true, {smCtrl})
    f.typeText("a")
    f.pressKey(skCtrl, false)
    f.typeText("7"), proc (f: FrameInfo): bool =
    f.named("plot.timeshift applies", "applies +8 ms"))
  step("point at Apply for both", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("plot.timeshift apply").centre), proc (f: FrameInfo): bool =
    f.markOf("plot.timeshift apply").size.x > 0 and wait > 2)
  step("Apply to both", proc (f: FrameInfo) =
    f.click(f.markOf("plot.timeshift apply").centre), proc (f: FrameInfo): bool =
    f.shiftOf(0) == 8.0 and f.shiftOf(1) == 8.0 and f.answered)
  step("point at another trace", proc (f: FrameInfo) =
    q = f.pointAt(3)
    f.moveMouse(q), proc (f: FrameInfo): bool = wait > 2)
  step("close the selection", proc (f: FrameInfo) =
    f.click(q), proc (f: FrameInfo): bool = f.core.selection.selectedCount <= 1)

  let code = run(RunOptions(openPaths: @[land], windowSize: (1600, 1000), theme: forceDark,
    persist: false, configDir: some(root / ".scratch" / "timeshift-config"),
    indexCacheDir: some(root / ".scratch" / "timeshift-cache"),
    logDir: some(root / ".scratch" / "timeshift-log"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  doAssert fileExists(popoverShot), "no popover picture"
  doAssert fileExists(markShot), "no mark picture"

  # shots.sgy has no auxiliary trace. A file that has one: the entry is absent
  # there, and present on a seismic trace of the same file.
  withFixtures fx:
    steps.setLen 0
    at = 0
    started = false
    failed = ""
    var aq: Vec2
    step("the file with an auxiliary trace", noop, proc (f: FrameInfo): bool =
      f.panel.laidOut and f.answered and f.core.firstAux(0) == 4)
    proc showAux(f: FrameInfo) =
      f.apply Command(kind: ckFilter, panel: MainPanel,
        filter: TraceFilter(seismic: true, auxiliary: true))
    proc auxShown(f: FrameInfo): bool =
      result = f.answered and f.panel.layout.traces >= 5 and f.panel.shown.find(4) >= 0
      if not result and wait > 80:
        failed = "auxiliary trace not shown: traces " & $f.panel.layout.traces
    step("show the auxiliary trace too", showAux, auxShown)
    step("show it", proc (f: FrameInfo) =
      var v = f.panel.view
      v.traces = Span(lo: -0.5, hi: 5.5)
      f.showView(v), proc (f: FrameInfo): bool = f.answered)
    step("point at the auxiliary trace", proc (f: FrameInfo) =
      aq = f.pointAt(f.panel.shown.find(4))
      f.moveMouse(aq), proc (f: FrameInfo): bool = wait > 2)
    step("its menu", proc (f: FrameInfo) = f.click(aq, button = 3), proc (f: FrameInfo): bool =
      result = f.markOf("plot.menu").size.x > 0 and f.markOf("plot.menu.shift").size.x == 0
      if f.markOf("plot.menu.shift").size.x > 0:
        failed = "Time shift was offered on an auxiliary trace"
      elif not result and wait > 40:
        failed = "no menu on the auxiliary trace: " & $f.markNames("plot.menu"))
    step("close that menu", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
      f.markOf("plot.menu").size.x == 0)
    step("point at a seismic trace", proc (f: FrameInfo) =
      aq = f.pointAt(0)
      f.moveMouse(aq), proc (f: FrameInfo): bool = wait > 2)
    step("its menu has Time shift", proc (f: FrameInfo) = f.click(aq, button = 3),
      proc (f: FrameInfo): bool =
      f.markOf("plot.menu.shift.item Time shift...").size.x > 0)
    let auxCode = run(RunOptions(openPaths: @[fx.spectrumAuxSegy()], windowSize: (1600, 1000),
      theme: forceDark, persist: false, configDir: some(fx.dir / "timeshift-config"),
      indexCacheDir: some(fx.dir / "timeshift-cache"),
      logDir: some(fx.dir / "timeshift-log"), onFrame: onFrame))
    doAssert auxCode == 0, "aux run() exit code " & $auxCode
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "aux stopped at " & steps[min(at, steps.high)].name
  echo "tguitimeshift: ok"

when isMainModule:
  main()
