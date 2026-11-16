## The sort drop-down in the running frontend, headless, driven by SDL mouse
## events as the user's mouse sends them, on a record whose sets of
## components are in a scrambled order (`mixedOrderSegd`): each of the
## list's three presets (Line/Station, By Flag, By Component) sorts the
## traces in its known order, and the drop-down then says that preset, and
## the trace under the pointer (the pick, which the status bar reads
## out) and the display header's values there are the ones of that order,
## and so is the hover, drawn in the hover colour there and not three traces
## away;
## picking the preset already in use does nothing; "File order" gives the
## file's order back; Custom... opens the popover of the user's own
## keys, where a key's direction is turned to descending and "Sort" sorts
## by them, and the drop-down then says "custom"; on traces
## with none of a preset's keys (the survey has
## no receiver line, point or component) the rows are greyed out and a
## click changes nothing; and the file is never changed.
##
## Seen to fail: with the buttons not drawn selected (`toggle` ignoring
## `selected`), Line/Station's first pick step found 0.2 % of its button's
## pixels in the selection colour; with a click on the selected button
## sending its keys again instead of the file's order, `click again: the
## file's order` never saw the order go; with the popover opened inside the
## menu's ID scope (`openSortKeys` called in the menu), it never opened;
## with Custom... not drawn selected under keys of the user's own (`own`
## false), "Custom... is not drawn selected: 0.0026"; with
## the buttons never greyed out, `buttonsWithoutTheirKeys` found the survey
## sorted by line and point; with a tile's hovered row found by position
## instead of by trace (`hoverRow`), the file's order already had the hover
## colour on none of the rows at position 71. A first version checked nothing at the pick
## steps (their closures, made in a loop, shared one position) and still
## passed; the steps are now made by a proc each, and counted.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[algorithm, math, monotimes, options, os, sequtils, times]
import parseSEG
import viewSEG/core/[geometry, state]
import viewSEG/view/[plotink, theme]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

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
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
    var failed = ""
    var plot: Rect # the plot's data area, framebuffer pixels
    var want: seq[int] # the order expected
    var theme: Theme
    var picked = 0 # positions whose pick was checked
    var looked = 0 # times the buttons' look was checked
    var hovered = 0 # positions whose hover and highlight were checked

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
      ## The drop-down says the order in use (`selected`: -1 the file's
      ## order; `SortPresets.len` the user's own keys).
      let want =
        if selected < 0: "Sort: file order"
        elif selected < SortPresets.len: "Sort: " & SortPresets[selected].name
        else: "Sort: custom"
      doAssert f.tracePanel.sortShown == want, "the drop-down says " &
        f.tracePanel.sortShown & ", not " & want
      doAssert f.markOf("plot.sort").size.x > 0, "the sort drop-down is not drawn"
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

    proc highlighted(f: FrameInfo; position: int; halfWidth: float64): int =
      ## The rows of the plot image with a pixel in the hover colour within
      ## `halfWidth` trace spacings of `position`'s baseline.
      let (img, w, h) = f.tracePanel.plotImage
      let v = f.tracePanel.drawnView
      let hover = plotInk(f.theme, f.panel.layers[0].display).wiggle.hover
      let ppt = float64(w) / v.traces.width
      let c = (float64(position) - v.traces.lo) * ppt
      for j in 0 ..< h:
        for i in max(0, int(c - halfWidth * ppt)) .. min(w - 1, int(c + halfWidth * ppt)):
          if distance(img[j * w + i], hover) <= 30:
            inc result
            break

    proc hoverAgrees(f: FrameInfo; position: int) =
      ## The hover, with the pointer still over `position`, is the trace the
      ## expected order puts there, and that trace is the one drawn in the
      ## hover colour (the file is the only one open: its traces' survey-wide
      ## ids are their indices).
      let trace = want[position]
      doAssert f.core.selection.hover == trace, "position " & $position & ": trace " &
        $f.core.selection.hover & " is hovered, the order puts " & $trace & " there"
      let (_, _, h) = f.tracePanel.plotImage
      let lit = f.highlighted(position, 1.0)
      doAssert lit > h div 2, "position " & $position & ": the hover colour on " & $lit &
        " of " & $h & " rows"
      for n in [position - 3, position + 3]:
        if n in 0 ..< seismic.len:
          doAssert f.highlighted(n, 0.5) == 0, "position " & $n & " is drawn hovered"
      inc hovered

    proc pickStep(name: string; position, selected: int) =
      ## Steps: the pointer over `position`, the pick and the header checked
      ## there (at position 0 also the buttons' look), then the hover and its
      ## highlight, drawn a frame later. (A proc per step: closures made in a
      ## loop would share the loop's variables.)
      step(name & ": pick at " & $position, proc (f: FrameInfo) =
        f.moveMouse(f.pointAt(position)), proc (f: FrameInfo): bool =
        result = f.pickAgrees(position)
        if result and position == 0: f.checkLit(selected))
      step(name & ": hover at " & $position, noop, proc (f: FrameInfo): bool =
        f.hoverAgrees(position)
        true)

    proc checkPicks(name: string; selected: int) =
      ## Steps: the pointer over a few positions, the first of them 0.
      for position in [0, 5, 13, 36, 71]: pickStep(name, position, selected)

    proc openRow(name, mark: string) =
      ## Opens the drop-down, if the row is not already shown. The pointer
      ## moves a frame before the click, as the mouse does.
      step("point at the sort list: " & name, proc (f: FrameInfo) =
        if f.markOf(mark).size.x > 0: return
        let combo = f.markOf("plot.sort")
        doAssert combo.size.x > 0, "no sort drop-down"
        f.moveMouse(combo.centre), proc (f: FrameInfo): bool = true)
      step("open the sort list: " & name, proc (f: FrameInfo) =
        if f.markOf(mark).size.x == 0: f.click(f.markOf("plot.sort").centre),
        proc (f: FrameInfo): bool = f.markOf(mark).size.x > 0)

    proc clickPreset(i: int) =
      let s = SortPresets[i]
      openRow(s.name, "plot.sort." & s.name)
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
        doAssert f.markOf("plot.sort").size.x > 0, "no sort drop-down"
        doAssert f.tracePanel.sortShown == "Sort: file order", f.tracePanel.sortShown
        f.apply Command(kind: ckHeader, panel: MainPanel, header: HeaderChoice(auto: false,
          fields: @[hfRcvLine, hfRcvPoint, hfComponent])))
    step("the header's rows", noop, proc (f: FrameInfo): bool = f.answered)
    checkPicks("the file's order", -1)
    for i in 0 ..< SortPresets.len: clickPreset(i)
    # By Component is in use: picking it again does nothing; File order
    # gives the file's order back
    let last = SortPresets[^1]
    openRow(last.name & " again", "plot.sort." & last.name)
    step("point at " & last.name & " again", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.sort." & last.name).centre), proc (f: FrameInfo): bool = true)
    step("the preset in use does nothing", proc (f: FrameInfo) =
      f.click(f.markOf("plot.sort." & last.name).centre), proc (f: FrameInfo): bool =
      f.panel.layers[0].order == last.keys and f.answered)
    openRow("File order", "plot.sort.file order")
    step("point at File order", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.sort.file order").centre), proc (f: FrameInfo): bool = true)
    step("click File order: the file's order", proc (f: FrameInfo) =
      f.click(f.markOf("plot.sort.file order").centre), proc (f: FrameInfo): bool =
      result = f.panel.layers[0].order.len == 0 and f.answered
      if result: want = seismic)
    checkPicks("the file's order again", -1)
    clickPreset(SortPresets.high)
    # the user's own keys, from the drop-down's Custom... row
    openRow("Custom...", "plot.sort.custom")
    step("point at Custom...", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.sort.custom").centre), proc (f: FrameInfo): bool = true)
    step("the popover opens", proc (f: FrameInfo) =
      f.click(f.markOf("plot.sort.custom").centre), proc (f: FrameInfo): bool =
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
    checkPicks("component descending", SortPresets.len)

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
    echo "tguisort: ", steps.len, " steps, ", picked, " picks and ", hovered,
      " hovers checked, the buttons' look ", looked, " times"
    doAssert picked == 35 and hovered == 35 and looked == 7, $picked & " picks, " & $hovered &
      " hovers, " & $looked & " looks"
    doAssert snapshot(path) == before, "sorting changed the file"

main()

block buttonsWithoutTheirKeys:
  # The survey's traces have no receiver line, point or component: the
  # three buttons are greyed out, and a click on one changes nothing.
  withFixtures fx:
    var stage = 0
    var wait = 0 # frames since the stage began, at `since`
    var since = getMonoTime()
    var clicks = 0
    var order: seq[SortKey] = @[SortKey(field: hfTrace)] # not what is checked for
    var b: Vec2
    proc onFrame(f: FrameInfo) =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      inc wait
      case stage
      of 0:
        if p.laidOut and f.markOf("plot.sort").size.x > 0 and wait > 10:
          b = f.markOf("plot.sort").centre
          f.moveMouse(b)
          (stage, wait, since) = (1, 0, getMonoTime())
      of 1:
        if wait > 2:
          f.pressMouse(b, true)
          f.pressMouse(b, false)
          (stage, wait, since) = (2, 0, getMonoTime())
      of 2:
        if f.markOf("plot.sort.Line/Station").size.x > 0:
          b = f.markOf("plot.sort.Line/Station").centre
          f.moveMouse(b)
          (stage, wait, since) = (3, 0, getMonoTime())
      of 3:
        if wait > 2:
          f.pressMouse(b, true)
          f.pressMouse(b, false)
          inc clicks
          (stage, wait, since) = (4, 0, getMonoTime())
      of 4:
        if wait > 12:
          order = p.layers[0].order
          f.stop()
      else: discard
      if overdue(wait, 1500, since): f.stop()
    let code = run(RunOptions(openPaths: @[fx.surveySegy()],
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0 and stage == 4 and clicks == 1, "stage " & $stage
    doAssert order.len == 0, "a greyed-out button sorted: " & $order

# ------------------------------------------------------------ screenshots --
# With `VIEWSEG_SCREENSHOTS=<dir>`, the sort buttons are saved on the
# mixed-order fixture (sort-components.png: By Flag, the display header
# showing line, point and component), and, when the example files are
# present (they are local only), the popover of the user's own keys on a
# real record sorted by offset, opened by the strip's Custom... button
# (sort-morgantown.png): docs/screenshots/
# holds the committed ones.

const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

proc click(f: FrameInfo; at: Vec2) =
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc sortShot(path, file: string; order: seq[SortKey]; header: seq[HeaderField];
    traces: Span; popover: bool) =
  ## Opens `path` in a 1600 x 1000 window, sorts it by `order` (with the
  ## display header `header` when not empty), shows `traces` (all when
  ## empty), opens the popover of the user's own keys with the strip's
  ## Custom... button when `popover`, and saves the frame.
  let dir = getEnv("VIEWSEG_SCREENSHOTS")
  var stage = 0
  var wait = 0 # frames since the stage began, at `since`
  var since = getMonoTime()
  var saved = false
  var q: Vec2
  proc onFrame(f: FrameInfo) =
    template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
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
        next 1
    of 1:
      if answered and wait > 3 and (traces.hi <= traces.lo or
          f.tracePanel.drawnView.traces == traces):
        let v = p.view.screenAt(plot, DataPoint(x: (p.view.traces.lo + p.view.traces.hi) / 2,
          tMs: (p.view.timeMs.lo + p.view.timeMs.hi) / 3))
        q = vec2(round(v.x), round(v.y))
        f.moveMouse(q)
        next(if popover: 2 else: 5)
    of 2:
      if wait == 3:
        q = f.markOf("plot.sort").centre
        f.moveMouse(q)
        next 3
    of 3:
      if wait == 3: f.click(q)
      if f.markOf("plot.sort.custom").size.x > 0:
        q = f.markOf("plot.sort.custom").centre
        f.moveMouse(q)
        next 4
    of 4:
      if wait == 3: f.click(q)
      if wait > 6 and f.markOf("plot.sort keys").size.x > 0:
        let r = f.markOf("plot.sort keys")
        f.moveMouse(vec2(r.pos.x + r.size.x + 40, r.pos.y + r.size.y + 120)) # no hover
        next 5
    of 5:
      if wait > 6:
        saved = f.savePng(dir / file)
        f.stop()
    else: discard
    if overdue(wait, 1500, since): f.stop()
  let tmp = getTempDir() / ("viewseg-sortshots-" & $getCurrentProcessId())
  let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000),
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
