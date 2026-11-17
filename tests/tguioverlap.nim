## The trace overlap in the plot window's strip, headless, driven by real
## clicks and typing, on the survey fixture with a spike (`pdSpike`: one
## sample of 100 among values of at most 1, so it is clipped at the
## overlap), gain None, wiggles with the positive fill:
##
## - "+" steps the overlap from 1 to 1.25: the image is what the CPU
##   reference draws, and the spike swings its trace 1.25 trace spacings
##   (the clip), as `swingIsClipped` in twiggle predicts;
## - 0.5 typed into the box: the spike swings half a trace spacing, and not
##   a pixel further;
## - "-" steps from 0.5 to 0.25;
## - a value out of range typed into the box changes nothing and says so in
##   Messages;
## - in the density mode the controls are greyed: "+" changes nothing.
##
## Seen to fail: with "+" sending the overlap unchanged, "+ did not
## happen"; with the box's value not sent, "typed 0.5 did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
##
## Runs alone: under the others' load the typed 0.5 did not take (2 of 4
##   parallel runs; never alone).

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, plotref, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc spikeSwing(s: Shot): (int, float64) =
  ## How far the spike (channel 15, position 14, at 600 ms) puts ink right
  ## of its baseline, in pixels (ink that is not there at 570 ms, where the
  ## record is quiet: the neighbours' lines are), and the trace spacing.
  let ppt = s.style.pixelsPerTrace
  let c = s.column(14)
  let quiet = s.row(570)
  var farthest = 0
  for j in s.row(596) .. s.row(604):
    for i in c .. min(s.w - 1, c + int(2.5 * ppt)):
      if not close(s.at(i, j), s.ink.background) and close(s.at(i, quiet), s.ink.background):
        farthest = max(farthest, i - c)
  (farthest, ppt)

proc main*() =

  withFixtures fx:
    let path = fx.surveySegy(pdSpike)
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
    var failed = ""
    var images, quiet = 0
    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc click(f: FrameInfo; at: Vec2) =
      f.pressMouse(at, true)
      f.pressMouse(at, false)
    proc chord(f: FrameInfo; key: SimKey) =
      f.pressKey(key, true)
      f.pressKey(key, false)
    proc overlap(f: FrameInfo): float64 = f.panel.layers[0].display.overlap
    proc settled(f: FrameInfo): bool =
      let tiles = f.core.tiles(f.core.findPanel(MainPanel))
      tiles.len > 0 and tiles[^1].request == f.panel.pending and
        f.tracePanel.drawnView.sameSpans(f.panel.view) and quiet >= 2
    proc swings(f: FrameInfo; o: float64; what: string): bool =
      ## The image is the reference's, the spike swings `o` trace spacings.
      result = f.overlap == o and f.settled
      if result:
        let s = f.capture
        let (bad, seen) = s.mismatches()
        doAssert bad == 0, what & ": " & $bad & " of " & $seen & " pixels off the reference"
        let (far, ppt) = s.spikeSwing
        doAssert abs(float64(far) - o * ppt) <= 1.5, what & ": the spike swings " & $far &
          " px; the clip is " & $(o * ppt)

    step("the file is shown", noop, proc (f: FrameInfo): bool =
      if not (f.panel.laidOut and f.panel.layers.len > 0): return
      if f.panel.layers[0].display.gain != dgNone:
        var d = f.panel.layers[0].display
        d.gain = dgNone
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        return
      result = f.swings(1, "overlap 1"))
    step("to the gear", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.more").centre), proc (f: FrameInfo): bool = true)
    step("the gear", proc (f: FrameInfo) = f.click(f.markOf("plot.more").centre),
      proc (f: FrameInfo): bool =
      # the popover's place is set from its size last frame: wait until that
      # size is known, so the tab does not jump out from under the pointer
      f.markOf("plot.more popover").size.x > 100 and wait > 4)
    step("to Traces", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.more tab traces").centre), proc (f: FrameInfo): bool =
      wait > 2)
    step("Traces", proc (f: FrameInfo) = f.click(f.markOf("plot.more tab traces").centre),
      proc (f: FrameInfo): bool = f.markOf("plot.overlap").size.x > 0)
    var aimed: Vec2
    var held = 0
    proc aim(mark: string) =
      ## Moves to `mark` and waits until it has stopped moving (the gear
      ## popover's place is set from its size last frame).
      held = 0
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        aimed = r.centre
        f.moveMouse(aimed), proc (f: FrameInfo): bool =
        let c = f.markOf(mark).centre
        if abs(c.x - aimed.x) < 1 and abs(c.y - aimed.y) < 1: inc held
        else:
          aimed = c
          f.moveMouse(c)
          held = 0
        held >= 2)
    proc hit(mark: string; done: proc (f: FrameInfo): bool) =
      aim(mark)
      step(mark, proc (f: FrameInfo) =
        f.pressMouse(aimed, true)
        f.pressMouse(aimed, false), done)
    hit("plot.overlap more", proc (f: FrameInfo): bool = f.swings(1.25, "+"))
    hit("plot.overlap", proc (f: FrameInfo): bool = f.typing)
    step("typed", proc (f: FrameInfo) =
      f.pressKey(skCtrl, true, {smCtrl}) # every character in the box, replaced
      f.typeText("a")
      f.pressKey(skCtrl, false)
      f.typeText("0.5"), proc (f: FrameInfo): bool = quiet > 2)
    step("typed 0.5", proc (f: FrameInfo) = f.chord(skEnter),
      proc (f: FrameInfo): bool = f.swings(0.5, "typed 0.5"))
    hit("plot.overlap less", proc (f: FrameInfo): bool = f.overlap == 0.25 and f.settled)
    hit("plot.overlap", proc (f: FrameInfo): bool = f.typing)
    step("typed 50", proc (f: FrameInfo) =
      f.pressKey(skCtrl, true, {smCtrl})
      f.typeText("a")
      f.pressKey(skCtrl, false)
      f.typeText("50"), proc (f: FrameInfo): bool = quiet > 2)
    step("50 is refused", proc (f: FrameInfo) = f.chord(skEnter), proc (f: FrameInfo): bool =
      var said = false
      for m in f.messages:
        if "trace overlap needs" in m.text: said = true
      result = said and quiet > 2
      if result: doAssert f.overlap == 0.25, $f.overlap)
    step("density", proc (f: FrameInfo) =
      var d = f.panel.layers[0].display
      d.mode = dmDensity
      f.apply(Command(kind: ckDisplay, panel: MainPanel, display: d)),
      proc (f: FrameInfo): bool = f.panel.layers[0].display.mode == dmDensity and quiet > 2)
    hit("plot.overlap more", proc (f: FrameInfo): bool =
      result = wait > 4
      if result: doAssert f.overlap == 0.25, "the greyed + changed the overlap: " & $f.overlap)

    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
      if f.tracePanel.imagesDrawn != images:
        images = f.tracePanel.imagesDrawn
        quiet = 0
      else: inc quiet
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
    echo "tguioverlap: ", steps.len, " steps"

when isMainModule:
  main()
