## The sort buttons in the running frontend, headless, driven by SDL mouse
## events as the user's mouse sends them, on a record whose sets of
## components are in a scrambled order (`mixedOrderSegd`): each of the
## strip's three buttons (Line/Station, By Flag, By Component) sorts the
## traces in its known order, is then drawn selected while the others are
## not, and the trace under the pointer (the pick, which the status bar reads
## out) and the display header's values there are the ones of that order;
## clicking the selected button again gives the file's order back; the
## plot's menu opens the popover of the user's own keys, where a key's
## direction is turned to descending and "Sort" sorts by them, with no
## button selected; on traces with none of a button's keys (the survey has
## no receiver line, point or component) the buttons are greyed out and a
## click changes nothing; and the file is never changed.
##
## Seen to fail: with the buttons not drawn selected (`toggle` ignoring
## `selected`), Line/Station's first pick step found 0.2 % of its button's
## pixels in the selection colour; with a click on the selected button
## sending its keys again instead of the file's order, `click again: the
## file's order` never saw the order go; with the popover opened inside the
## menu's ID scope (`openSortKeys` called in the menu), it never opened; with
## the buttons never greyed out, `buttonsWithoutTheirKeys` found the survey
## sorted by line and point. A first version checked nothing at the pick
## steps (their closures, made in a loop, shared one position) and still
## passed; the steps are now made by a proc each, and counted.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[algorithm, math, options, os, sequtils, times]
import parseSEG
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/fixtures

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

proc expected(keys: seq[TraceKeys]; traces: seq[int]; order: openArray[SortKey]): seq[int] =
  ## `traces` sorted by `order` with a stable comparison sort (`keys[t]` is
  ## trace `t`'s): the oracle.
  var rows = traces
  let o = @order
  proc cmpKeys(a, b: int): int =
    for k in o:
      var (x, y) = (keys[a].value(k.field, a), keys[b].value(k.field, b))
      if k.descending: (x, y) = (-x, -y)
      let c = if x.isNaN and y.isNaN: 0 elif x.isNaN: 1 elif y.isNaN: -1 else: cmp(x, y)
      if c != 0: return c
    0
  rows.sort(cmpKeys)
  rows

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc main() =
  withFixtures fx:
    let path = fx.mixedOrderSegd()
    let before = snapshot(path)
    var file = openSeismic(path, keys = true)
    let keys = file.traceKeys(0 ..< file.len)
    file.close()
    let seismic = toSeq(1 ..< keys.len)
    var steps: seq[Step]
    var at = 0 # the step running
    var started = false # its action is done
    var wait = 0 # frames since
    var failed = ""
    var plot: Rect # the plot's data area, framebuffer pixels
    var want: seq[int] # the order expected
    var theme: Theme
    var picked = 0 # positions whose pick was checked
    var looked = 0 # times the buttons' look was checked

    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

    proc answered(f: FrameInfo): bool =
      let p = f.panel
      let tiles = f.core.tiles(f.core.findPanel(MainPanel))
      tiles.len > 0 and tiles[^1].request == p.pending and p.pending.gen >= p.orderGen and
        f.tracePanel.drawnView.sameSpans(p.view)

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc click(f: FrameInfo; at: Vec2) =
      f.pressMouse(at, true)
      f.pressMouse(at, false)

    proc lit(f: FrameInfo; r: Rect): float64 =
      ## The share of `r`'s pixels in the selection colour.
      var n = 0
      for y in int(r.pos.y) ..< int(r.pos.y + r.size.y):
        for x in int(r.pos.x) ..< int(r.pos.x + r.size.x):
          if distance(f.readPixel(x, y), theme.roles[rlSelection]) <= 2: inc n
      float64(n) / max(1.0, float64(r.size.x * r.size.y))

    proc checkLit(f: FrameInfo; selected: int) =
      ## Button `selected` (-1: none) is drawn on the selection colour, the
      ## others are not.
      for i, s in SortPresets:
        let share = f.lit(f.markOf("plot.sort." & s.name))
        if i == selected: doAssert share > 0.4, s.name & " is not drawn selected: " & $share
        else: doAssert share < 0.05, s.name & " is drawn selected: " & $share
      inc looked

    proc pointAt(f: FrameInfo; position: int): Vec2 =
      let v = f.panel.view.screenAt(plot, DataPoint(x: float64(position), tMs: 300))
      vec2(round(v.x), round(v.y))

    proc pickAgrees(f: FrameInfo; position: int): bool =
      ## The pick under the pointer, over `position`, names the trace the
      ## expected order puts there, and so does the display header.
      let p = f.pick
      result = p.inside and p.found and p.position == position
      if result:
        let trace = want[position]
        doAssert p.trace == trace, "position " & $position & ": the pick names trace " &
          $p.trace & ", the order " & $trace
        doAssert p.keys.rcvLine == keys[trace].rcvLine and p.keys.rcvPoint ==
          keys[trace].rcvPoint and p.keys.component == keys[trace].component
        let tiles = f.core.tiles(f.core.findPanel(MainPanel))
        let t = tiles[^1]
        let row = (position - t.request.first) div t.request.stride
        for i, field in t.fields:
          doAssert t.header[i][row] == keys[trace].value(field, trace),
            "the display header's " & $field & " at position " & $position
        inc picked

    proc pickStep(name: string; position, selected: int) =
      ## A step: the pointer over `position`, the pick and the header checked
      ## there; at position 0 also the buttons' look. (A proc per step:
      ## closures made in a loop would share the loop's variables.)
      step(name & ": pick at " & $position, proc (f: FrameInfo) =
        f.moveMouse(f.pointAt(position)), proc (f: FrameInfo): bool =
        result = f.pickAgrees(position)
        if result and position == 0: f.checkLit(selected))

    proc checkPicks(name: string; selected: int) =
      ## Steps: the pointer over a few positions, the first of them 0.
      for position in [0, 5, 13, 36, 71]: pickStep(name, position, selected)

    proc clickPreset(i: int) =
      let s = SortPresets[i]
      step("point at " & s.name, proc (f: FrameInfo) =
        f.moveMouse(f.markOf("plot.sort." & s.name).centre), proc (f: FrameInfo): bool = true)
      step("click " & s.name, proc (f: FrameInfo) =
        f.click(f.markOf("plot.sort." & s.name).centre), proc (f: FrameInfo): bool =
        result = f.panel.layers[0].order == s.keys and f.answered
        if result: want = expected(keys, seismic, s.keys))
      checkPicks(s.name, i)

    # -------------------------------------------------------------- steps --
    step("the file opens", noop, proc (f: FrameInfo): bool =
      result = f.panel.laidOut and f.answered and f.markOf("plot.data").size.x > 0
      if result:
        plot = f.markOf("plot.data")
        theme = f.theme
        want = seismic
        for s in SortPresets:
          doAssert f.markOf("plot.sort." & s.name).size.x > 0, "no " & s.name & " button"
        f.apply Command(kind: ckHeader, panel: MainPanel, header: HeaderChoice(auto: false,
          fields: @[hfRcvLine, hfRcvPoint, hfComponent])))
    step("the header's rows", noop, proc (f: FrameInfo): bool = f.answered)
    checkPicks("the file's order", -1)
    for i in 0 ..< SortPresets.len: clickPreset(i)
    # By Component is selected: a click on it gives the file's order back
    let last = SortPresets[^1]
    step("point at " & last.name & " again", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.sort." & last.name).centre), proc (f: FrameInfo): bool = true)
    step("click again: the file's order", proc (f: FrameInfo) =
      f.click(f.markOf("plot.sort." & last.name).centre), proc (f: FrameInfo): bool =
      result = f.panel.layers[0].order.len == 0 and f.answered
      if result: want = seismic)
    checkPicks("the file's order again", -1)
    clickPreset(SortPresets.high)
    # the user's own keys, from the plot's menu
    var q: Vec2
    step("right click on the plot", proc (f: FrameInfo) =
      q = f.pointAt(20)
      f.moveMouse(q), proc (f: FrameInfo): bool = true)
    step("the menu opens", proc (f: FrameInfo) =
      f.pressMouse(q, true, button = 3)
      f.pressMouse(q, false, button = 3), proc (f: FrameInfo): bool =
      f.markOf("plot.menu.sort keys").size.x > 0)
    step("point at Sort by keys", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.menu.sort keys").centre), proc (f: FrameInfo): bool = true)
    step("the popover opens", proc (f: FrameInfo) =
      f.click(f.markOf("plot.menu.sort keys").centre), proc (f: FrameInfo): bool =
      f.markOf("plot.sort keys").size.x > 0 and f.markOf("plot.sort keys.direction 0").size.x > 0)
    step("point at the first key's direction", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.sort keys.direction 0").centre), proc (f: FrameInfo): bool =
      true)
    step("turn it to descending", proc (f: FrameInfo) =
      f.click(f.markOf("plot.sort keys.direction 0").centre), proc (f: FrameInfo): bool =
      wait > 4)
    step("point at Sort", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.sort keys.sort").centre), proc (f: FrameInfo): bool = true)
    let custom = @[SortKey(field: hfComponent, descending: true), SortKey(field: hfRcvLine),
      SortKey(field: hfRcvPoint)]
    step("click Sort", proc (f: FrameInfo) =
      f.click(f.markOf("plot.sort keys.sort").centre), proc (f: FrameInfo): bool =
      result = f.panel.layers[0].order == custom and f.answered and
        f.markOf("plot.sort keys").size.x == 0
      if result: want = expected(keys, seismic, custom))
    checkPicks("component descending", -1)

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

    let code = run(RunOptions(maxFrames: 8000, openPaths: @[path], windowSize: (1600, 1000),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguisort: ", steps.len, " steps, ", picked, " picks checked, the buttons' look ",
      looked, " times"
    doAssert picked == 35 and looked == 7, $picked & " picks, " & $looked & " looks"
    doAssert snapshot(path) == before, "sorting changed the file"

main()

block buttonsWithoutTheirKeys:
  # The survey's traces have no receiver line, point or component: the
  # three buttons are greyed out, and a click on one changes nothing.
  withFixtures fx:
    var stage = 0
    var wait = 0
    var clicks = 0
    var order: seq[SortKey] = @[SortKey(field: hfTrace)] # not what is checked for
    var b: Vec2
    proc onFrame(f: FrameInfo) =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      inc wait
      case stage
      of 0:
        if p.laidOut and f.markOf("plot.sort.Line/Station").size.x > 0 and wait > 10:
          b = f.markOf("plot.sort.Line/Station").centre
          f.moveMouse(b)
          wait = 0
          stage = 1
      of 1:
        if wait == 3: # once: a second click on a selected button would undo it
          f.pressMouse(b, true)
          f.pressMouse(b, false)
          inc clicks
        if wait > 12:
          order = p.layers[0].order
          f.stop()
      else: discard
      if f.index > 1500: f.stop()
    let code = run(RunOptions(maxFrames: 2000, openPaths: @[fx.surveySegy()],
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0 and stage == 1 and clicks == 1, "stage " & $stage
    doAssert order.len == 0, "a greyed-out button sorted: " & $order

# ------------------------------------------------------------ screenshots --
# With `VIEWSEG_SCREENSHOTS=<dir>`, the sort buttons are saved on the
# mixed-order fixture (sort-components.png: By Flag, the display header
# showing line, point and component), and, when the example files are
# present (they are local only), the popover of the user's own keys on a
# real record sorted by offset (sort-morgantown.png): docs/screenshots/
# holds the committed ones.

const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

proc click(f: FrameInfo; at: Vec2) =
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc sortShot(path, file: string; order: seq[SortKey]; header: seq[HeaderField];
    traces: Span; popover: bool) =
  ## Opens `path` in a 1600 x 1000 window, sorts it by `order` (with the
  ## display header `header` when not empty), shows `traces` (all when
  ## empty), opens the popover of the user's own keys from the plot's menu
  ## when `popover`, and saves the frame.
  let dir = getEnv("VIEWSEG_SCREENSHOTS")
  var stage = 0
  var wait = 0
  var saved = false
  var q: Vec2
  proc onFrame(f: FrameInfo) =
    let p = f.core.panels[f.core.findPanel(MainPanel)]
    let tiles = f.core.tiles(f.core.findPanel(MainPanel))
    let answered = tiles.len > 0 and tiles[^1].request == p.pending and
      p.pending.gen >= p.orderGen and f.tracePanel.drawnView.sameSpans(p.view)
    let plot = f.markOf("plot.data")
    inc wait
    case stage
    of 0:
      if p.laidOut and answered and plot.size.x > 0:
        f.apply Command(kind: ckSort, panel: MainPanel, order: order)
        if header.len > 0:
          f.apply Command(kind: ckHeader, panel: MainPanel, header: HeaderChoice(auto: false,
            fields: header))
        if traces.hi > traces.lo:
          var v = p.view
          v.traces = traces
          f.showView(v)
        stage = 1
    of 1:
      if answered and wait > 3 and (traces.hi <= traces.lo or
          f.tracePanel.drawnView.traces == traces):
        let v = p.view.screenAt(plot, DataPoint(x: (p.view.traces.lo + p.view.traces.hi) / 2,
          tMs: (p.view.timeMs.lo + p.view.timeMs.hi) / 3))
        q = vec2(round(v.x), round(v.y))
        f.moveMouse(q)
        wait = 0
        stage = if popover: 2 else: 5
    of 2:
      if wait == 3:
        f.pressMouse(q, true, button = 3)
        f.pressMouse(q, false, button = 3)
      if wait > 6 and f.markOf("plot.menu.sort keys").size.x > 0:
        q = f.markOf("plot.menu.sort keys").centre
        f.moveMouse(q)
        wait = 0
        stage = 3
    of 3:
      if wait == 3: f.click(q)
      if wait > 6 and f.markOf("plot.sort keys").size.x > 0:
        let r = f.markOf("plot.sort keys")
        f.moveMouse(vec2(r.pos.x + r.size.x + 40, r.pos.y + r.size.y + 120)) # no hover
        wait = 0
        stage = 5
    of 5:
      if wait > 6:
        saved = f.savePng(dir / file)
        f.stop()
    else: discard
    if f.index > 1500: f.stop()
  let tmp = getTempDir() / ("viewseg-sortshots-" & $getCurrentProcessId())
  let code = run(RunOptions(maxFrames: 2000, openPaths: @[path], windowSize: (1600, 1000),
    theme: forceDark, indexCacheDir: some(tmp), userThemeDir: some(tmp / "no-user-themes"),
    onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0 and saved, "no screenshot of " & path & " (stage " & $stage & ")"
  echo "tguisort: saved ", dir / file

if getEnv("VIEWSEG_SCREENSHOTS").len > 0:
  createDir(getEnv("VIEWSEG_SCREENSHOTS"))
  withFixtures fx:
    sortShot(fx.mixedOrderSegd(), "sort-components.png", SortPresets[1].keys,
      @[hfRcvLine, hfRcvPoint, hfComponent], Span(lo: -0.5, hi: 17.5), popover = false)
  let morgantown = examples / "00000151_12900_11300.sgd"
  if fileExists(morgantown):
    sortShot(morgantown, "sort-morgantown.png", @[SortKey(field: hfOffset)], @[], Span(),
      popover = true)
