## Clicks on the plot's traces, headless, with real clicks and keys, on the
## survey fixture sorted by channel, descending, so that a position is not
## its trace's place in the file:
##
## - the click that brings the window forward selects nothing; the next
##   plain click selects the trace under the pointer;
## - Ctrl + click adds a trace to the selection, and on a selected trace
##   takes it out, the rest left as it is;
## - Shift + click selects every trace from the one clicked last to this
##   one, in the order shown (both ways), in place of the selection;
## - the reader tells the panel the traces in the order shown.
##
## Seen to fail: with Ctrl + click doing nothing (as it did), "Ctrl + click
## did not add: @[20]"; with Shift + click toggling one trace (as it did),
## "Shift + click selected @[12, 16]"; with the reader's order not posted,
## "sorted by channel, descending did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[algorithm, math, monotimes, options, os, sequtils, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

proc main*() =

  withFixtures fx:
    let path = fx.surveySegy()
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
    var failed = ""
    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc pointAt(f: FrameInfo; position: int): Vec2 =
      let r = f.markOf("plot.data")
      let v = f.tracePanel.drawnView
      vec2(round(r.pos.x + float32((float64(position) - v.traces.lo) / v.traces.width) *
        r.size.x), round(r.pos.y + r.size.y / 2))
    proc traceAt(f: FrameInfo; position: int): int =
      ## The survey-wide id of the trace at `position` (shot 0: its index).
      f.panel.shown[position]
    proc selected(f: FrameInfo): seq[int] =
      for t in f.core.selection.selected: result.add t
      result.sort()
    proc clickAt(name: string; position: int; mods: set[SimMod];
        done: proc (f: FrameInfo): bool) =
      ## Moves to `position`'s trace, then clicks it with `mods` held.
      step("to " & name, proc (f: FrameInfo) = f.moveMouse(f.pointAt(position)),
        proc (f: FrameInfo): bool = wait > 3)
      step(name, proc (f: FrameInfo) =
        let q = f.pointAt(position)
        if smCtrl in mods: f.pressKey(skCtrl, true, {smCtrl})
        if smShift in mods: f.pressKey(skShift, true, mods * {smShift} + mods * {smCtrl})
        f.pressMouse(q, true)
        f.pressMouse(q, false)
        if smShift in mods: f.pressKey(skShift, false, mods * {smCtrl})
        if smCtrl in mods: f.pressKey(skCtrl, false), proc (f: FrameInfo): bool =
          wait > 8 and done(f))

    step("sorted by channel, descending", proc (f: FrameInfo) = discard,
      proc (f: FrameInfo): bool =
      if not f.panel.laidOut: return
      if f.panel.layers[0].order.len == 0:
        f.apply(Command(kind: ckSort, panel: MainPanel,
          order: @[SortKey(field: hfChannel, descending: true)]))
        return
      result = f.panel.shown.len == Channels and wait > 10
      if result:
        # the reader's order: channel 24 first, the trace's index in the file
        doAssert f.panel.shown == toSeq(countdown(Channels - 1, 0)), $f.panel.shown)
    clickAt("a focusing click", 3, {}, proc (f: FrameInfo): bool =
      doAssert f.selected.len == 0, "a focusing click selected " & $f.selected
      true)
    clickAt("a click", 3, {}, proc (f: FrameInfo): bool =
      f.selected == @[f.traceAt(3)])
    clickAt("Ctrl + click adds", 7, {smCtrl}, proc (f: FrameInfo): bool =
      result = f.selected.len == 2
      if not result and overdue(wait, 30, since):
        doAssert false, "Ctrl + click did not add: " & $f.selected
      if result: doAssert f.selected == sorted(@[f.traceAt(3), f.traceAt(7)]))
    clickAt("Ctrl + click takes out", 3, {smCtrl}, proc (f: FrameInfo): bool =
      f.selected == @[f.traceAt(7)])
    clickAt("Shift + click: a range, in the order shown", 11, {smShift}, proc (f: FrameInfo): bool =
      # from trace 3, toggled last, to position 11
      var want: seq[int]
      for k in 3 .. 11: want.add f.traceAt(k)
      result = f.selected == sorted(want)
      if not result and overdue(wait, 30, since):
        doAssert false, "Shift + click selected " & $f.selected)
    clickAt("Shift + click the other way", 1, {smShift}, proc (f: FrameInfo): bool =
      # the anchor stays at position 3
      f.selected == sorted(@[f.traceAt(1), f.traceAt(2), f.traceAt(3)]))
    clickAt("a click replaces", 20, {}, proc (f: FrameInfo): bool =
      f.selected == @[f.traceAt(20)])

    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
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

    let code = run(RunOptions(openPaths: @[path], windowSize: (1280, 900),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguiselect: ", steps.len, " steps"

when isMainModule:
  main()
