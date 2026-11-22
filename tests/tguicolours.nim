## The plot's six colours in the running frontend, headless, driven by real
## clicks and typing, and kept across a restart:
##
## - the gear popover's Colours section shows the six swatches (background,
##   wiggle line, positive fill, negative fill, the trace under the pointer,
##   selected traces) whatever the scheme, each with its name;
## - a click on a swatch opens its picker; a colour typed as `#rrggbb` there
##   and Enter makes the scheme "My own", starting from the colours shown,
##   with that one colour changed;
## - with all six set, the plot draws them: the image is what the CPU
##   reference draws in those colours, and each is found among its pixels
##   (a trace hovered, another selected);
## - Paper puts the ready-made colours back, and "My own" brings the user's
##   colours back unchanged;
## - a second run in the same settings folder draws the same six colours.
##
## Seen to fail: with the swatches shown only under "My own" (as they
## were), "no swatch plot.colour.background" under Paper; with the picker's
## colour not sent (`changed` never set by the box), "background did not
## happen"; with the settings not saving the scheme (`colours` left out of
## `settingsDocument`), "second run: the colours are paper".
##
## The windows are kept inside the main one (`keepInMainWindow`): on a loaded machine a tooltip
## that reaches past the window edge becomes a window of its own in the very frame a click is
## sent, and Dear ImGui's SDL backend takes that window for the one under the pointer, so the
## click opens nothing (seen under `taskset -c 0` with busy loops: 14 of 20 runs failed, with
## no viewport but the main one 0 of 6).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/view/[plotink, theme]
import viewSEG/ui/imgui/app
import utils/[fixtures, plotref, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

const
  keys = ["background", "line", "positive", "negative", "hover", "selected"]
  wanted = [Rgba(r: 0x20, g: 0x24, b: 0x30, a: 255), Rgba(r: 0x40, g: 0xe0, b: 0x40, a: 255),
    Rgba(r: 0xe0, g: 0xc0, b: 0x20, a: 255), Rgba(r: 0x30, g: 0x80, b: 0xf0, a: 255),
    Rgba(r: 0xff, g: 0x20, b: 0xd0, a: 255), Rgba(r: 0xf0, g: 0xf0, b: 0xf0, a: 255)]

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

func colourOf(c: CustomColours; i: int): Rgba =
  [c.background, c.line, c.positive, c.negative, c.hover, c.selected][i]

proc found(s: Shot; c: Rgba; tol = 40): int =
  ## Pixels of the image within `tol` of `c`.
  for p in s.image:
    if distance(p, c) <= tol: inc result

proc runSteps(steps: seq[Step]; opts: RunOptions): string =
  ## Runs `steps` in a run of the frontend with `opts`; "" when every step
  ## happened, else the one that did not.
  var at = 0
  var started = false
  var wait = 0 # frames since the step's action, at `since`
  var since = getMonoTime()
  var failed = ""
  proc onFrame(f: FrameInfo) =
    if at >= steps.len or failed.len > 0:
      f.stop()
      return
    if f.index == 0: f.keepInMainWindow # (see the module doc)
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
  var o = opts
  o.onFrame = onFrame
  doAssert run(o) == 0
  if failed.len == 0 and at < steps.len: failed = "stopped at " & steps[at].name
  failed

proc main*() =

  withFixtures fx:
    let path = fx.surveySegy()
    let config = fx.dir / "config"
    let logs = fx.dir / "logs"
    var steps: seq[Step]
    var wait = 0
    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      ## A step; `wait` counts the frames since its action.
      steps.add Step(name: name, act: proc (f: FrameInfo) =
        wait = 0
        act(f), done: proc (f: FrameInfo): bool =
        inc wait
        done(f))
    proc noop(f: FrameInfo) = discard
    proc click(f: FrameInfo; at: Vec2) =
      ## A click at `at`, the pointer moved there first (the place may have
      ## moved since the step before pointed at it: the strip re-wraps when a
      ## label changes).
      f.moveMouse(at)
      f.pressMouse(at, true)
      f.pressMouse(at, false)
    proc chord(f: FrameInfo; key: SimKey) =
      f.pressKey(key, true)
      f.pressKey(key, false)
    proc baseline(f: FrameInfo; position: float64): Vec2 =
      let r = f.markOf("plot.data")
      let v = f.tracePanel.drawnView
      vec2(round(r.pos.x + float32((position - v.traces.lo) / v.traces.width) * r.size.x),
        round(r.pos.y + r.size.y * 0.6))
    proc shown(f: FrameInfo): bool =
      let tiles = f.core.tiles(f.core.findPanel(MainPanel))
      f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
        f.tracePanel.drawnView.sameSpans(f.panel.view)

    step("the file is shown", noop, proc (f: FrameInfo): bool =
      result = f.shown
      if result:
        var d = f.panel.layers[0].display
        d.fills = {wfPositive, wfNegative}
        d.gain = dgNone
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d))
    step("to the gear", proc (f: FrameInfo) = f.moveMouse(f.markOf("plot.more").centre),
      proc (f: FrameInfo): bool = wait > 2)
    step("the gear's popover", proc (f: FrameInfo) = f.click(f.markOf("plot.more").centre),
      proc (f: FrameInfo): bool =
      result = f.markOf("plot.colours.paper").size.x > 0
      if result:
        doAssert f.panel.layers[0].display.colours == pcPaper
        for k in keys:
          doAssert f.markOf("plot.colour." & k).size.x > 0, "no swatch plot.colour." & k)
    proc colourSteps(i: int) =
      ## The steps that set colour `i` (a proc of its own: closures made in a
      ## loop body share one environment, so they would all see the last `i`).
      step("to the " & keys[i] & " swatch", proc (f: FrameInfo) =
        f.moveMouse(f.markOf("plot.colour." & keys[i]).centre), proc (f: FrameInfo): bool =
          wait > 2)
      step("its picker", proc (f: FrameInfo) = f.click(f.markOf("plot.colour." & keys[i]).centre),
        proc (f: FrameInfo): bool = f.markOf("plot.colour hex").size.x > 0)
      step("to its box", proc (f: FrameInfo) = f.moveMouse(f.markOf("plot.colour hex").centre),
        proc (f: FrameInfo): bool = wait > 2)
      step("the box", proc (f: FrameInfo) = f.click(f.markOf("plot.colour hex").centre),
        proc (f: FrameInfo): bool = f.typing)
      step("typed", proc (f: FrameInfo) = f.typeText(toHex(wanted[i])),
        proc (f: FrameInfo): bool = wait > 2)
      step(keys[i], proc (f: FrameInfo) = f.chord(skEnter), proc (f: FrameInfo): bool =
        let d = f.panel.layers[0].display
        result = d.colours == pcCustom and d.custom.colourOf(i) == wanted[i]
        if result:
          for j in 0 ..< i: # the ones set before are kept
            doAssert d.custom.colourOf(j) == wanted[j], keys[j] & " changed: " & toHex(
                d.custom.colourOf(j)) & " for " & toHex(wanted[j]))
      step("the picker closes", proc (f: FrameInfo) = f.chord(skEscape),
        proc (f: FrameInfo): bool = f.markOf("plot.colour hex").size.x == 0)
    for i in 0 ..< keys.len: colourSteps(i)
    step("the popover closes", proc (f: FrameInfo) = f.chord(skEscape),
      proc (f: FrameInfo): bool = f.markOf("plot.colour.background").size.x == 0)
    step("to trace 5", proc (f: FrameInfo) = f.moveMouse(f.baseline(5)),
      proc (f: FrameInfo): bool = wait > 3)
    step("trace 5 selected", proc (f: FrameInfo) = f.click(f.baseline(5)),
      proc (f: FrameInfo): bool = wait > 3 and f.core.selection.selected.len > 0)
    step("trace 12 hovered", proc (f: FrameInfo) = f.moveMouse(f.baseline(12)),
      proc (f: FrameInfo): bool =
      result = wait > 8 and f.core.selection.hover == 12
      if result:
        let s = f.capture
        doAssert s.ink.background == wanted[0] and s.ink.wiggle.line == wanted[1] and
          s.ink.wiggle.selected == wanted[5]
        let (bad, seen) = s.mismatches()
        doAssert bad == 0, "own colours: " & $bad & " of " & $seen & " pixels off the reference"
        for k in 0 ..< keys.len:
          doAssert s.found(wanted[k]) > 0, "no pixel of the " & keys[k] & " colour")
    # Paper puts the ready-made colours back; My own brings the user's back
    step("to the gear again", proc (f: FrameInfo) = f.moveMouse(f.markOf("plot.more").centre),
      proc (f: FrameInfo): bool = wait > 2)
    step("the popover again", proc (f: FrameInfo) = f.click(f.markOf("plot.more").centre),
      proc (f: FrameInfo): bool = f.markOf("plot.colours.paper").size.x > 0)
    step("to Paper", proc (f: FrameInfo) = f.moveMouse(f.markOf("plot.colours.paper").centre),
      proc (f: FrameInfo): bool = wait > 2)
    step("Paper", proc (f: FrameInfo) = f.click(f.markOf("plot.colours.paper").centre),
      proc (f: FrameInfo): bool =
      result = f.panel.layers[0].display.colours == pcPaper and wait > 4
      if result:
        doAssert f.capture.ink.background == PaperBackground, "paper is not white")
    step("to My own", proc (f: FrameInfo) = f.moveMouse(f.markOf("plot.colours.custom").centre),
      proc (f: FrameInfo): bool = wait > 2)
    step("My own", proc (f: FrameInfo) = f.click(f.markOf("plot.colours.custom").centre),
      proc (f: FrameInfo): bool =
      let d = f.panel.layers[0].display
      result = d.colours == pcCustom
      if result:
        for k in 0 ..< keys.len: doAssert d.custom.colourOf(k) == wanted[k], keys[k] & " lost")
    let failed = runSteps(steps, RunOptions(persist: true, configDir: some(config),
      logDir: some(logs), openPaths: @[path], windowSize: (1280, 900), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache")))
    doAssert failed.len == 0, failed

    # A second run, in the same settings folder: the same colours.
    steps.setLen 0
    step("second run", noop, proc (f: FrameInfo): bool =
      result = f.shown and wait > 6
      if result:
        let d = f.panel.layers[0].display
        doAssert d.colours == pcCustom, "second run: the colours are " & $d.colours
        for k in 0 ..< keys.len: doAssert d.custom.colourOf(k) == wanted[k], keys[k]
        let s = f.capture
        let (bad, seen) = s.mismatches()
        doAssert bad == 0, "second run: " & $bad & " of " & $seen & " pixels off the reference"
        for k in 0 .. 3:
          doAssert s.found(wanted[k]) > 0, "second run: no pixel of the " & keys[k] & " colour")
    let again = runSteps(steps, RunOptions(persist: true, configDir: some(config),
      logDir: some(logs), openPaths: @[path], windowSize: (1280, 900), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache")))
    doAssert again.len == 0, again
    echo "tguicolours: six colours set by hand, drawn, and drawn again after a restart"

when isMainModule:
  main()
