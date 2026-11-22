## The gain amount from -300 to +300 dB, headless, on the survey shot as
## the user changes it: a click on + is 3 dB more and with Shift 12 dB; the
## + button held down goes on adding 3 dB steps until it is let go; `]` held
## repeats as well, Shift + `]` is 12 dB more and Shift + `[` 12 dB less;
## 1000 typed into the box is +300 dB and -1000 is -300. At both ends, in
## density and in wiggles, the plot's image is what the CPU reference draws:
## at +300 dB with a Fixed amplitude so small that the display scale passes
## what a float32 holds, every sample that is not 0 is full black or white
## (the clip holds where amplitude times scale is an infinity), and at -300
## dB the density is mid grey and the wiggles lie on their baselines.
##
## Under the type none the + button is greyed: "+ under none changed the amount" with it
## left enabled.
##
## Seen to fail: with `MaxGainDb` at 60, "typed 1000: 60.0 dB, not 300.0";
## with the buttons not repeating (no `ButtonRepeat`), "+ held did not
## happen"; with `displayScale` giving 0 past a float32 (as it did), "+300
## dB, Fixed 1e-30: 0.0 % of the plot full black or white" (mid grey: more
## gain drew less).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, plotref, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc saturated(s: Shot): float64 =
  ## Of the image's pixels that are neither the background nor mid grey (a
  ## sample of 0 in density), the share that is full black or full white.
  var n, inked = 0
  for c in s.image:
    if not close(c, s.ink.background, 2) and not close(c, Rgba(r: 128, g: 128, b: 128, a: 255), 2):
      inc inked
      if close(c, Rgba(r: 0, g: 0, b: 0, a: 255), 2) or
          close(c, Rgba(r: 255, g: 255, b: 255, a: 255), 2): inc n
  if inked == 0: 0.0 else: n / inked

proc inked(s: Shot): int =
  ## The image's pixels that are not the background.
  for c in s.image:
    if not close(c, s.ink.background, 2): inc result

proc offBaselines(s: Shot): int =
  ## The image's pixels of ink more than 1.5 pixels from a trace's baseline.
  for j in 0 ..< s.h:
    for i in 0 ..< s.w:
      let x = s.xOf(i)
      if not close(s.at(i, j), s.ink.background, 2) and
          abs(x - round(x)) * s.style.pixelsPerTrace > 1.5: inc result

proc main*() =

  withFixtures fx:
    let path = fx.surveySegy()
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
    var failed = ""
    var images, quiet = 0
    var pointAt: Vec2
    var before = 0.0
    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
    proc db(f: FrameInfo): float64 =
      if f.panel.layers.len > 0: f.panel.layers[0].display.gainDb else: NaN
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    proc settled(f: FrameInfo): bool =
      let tiles = f.core.tiles(f.core.findPanel(MainPanel))
      tiles.len > 0 and tiles[^1].request == f.panel.pending and
        f.tracePanel.drawnView.sameSpans(f.panel.view) and quiet >= 2
    proc note(f: FrameInfo) = before = f.db
    proc moveTo(mark: string) =
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = r.centre
        f.moveMouse(pointAt), after(2))
    proc click(mark: string; shift = false; adds: float64) =
      moveTo(mark)
      proc act(f: FrameInfo) =
        f.note
        if shift: f.pressKey(skShift, true, {smShift})
        f.pressMouse(pointAt, true)
        f.pressMouse(pointAt, false)
        if shift: f.pressKey(skShift, false)
      proc done(f: FrameInfo): bool =
        result = f.db != before and quiet >= 1
        if result:
          doAssert f.db == before + adds, mark & ": " & $f.db & " dB, not " & $(before + adds)
      step("click " & mark & (if shift: " with Shift" else: ""), act, done)
    proc key(k: SimKey; shift: bool; adds: float64) =
      proc act(f: FrameInfo) =
        f.note
        let mods = if shift: {smShift} else: {}
        if shift: f.pressKey(skShift, true, mods)
        f.pressKey(k, true, mods)
        f.pressKey(k, false, mods)
        if shift: f.pressKey(skShift, false)
      proc done(f: FrameInfo): bool =
        result = f.db != before and quiet >= 1
        if result:
          doAssert f.db == before + adds, $k & ": " & $f.db & " dB, not " & $(before + adds)
      step($k & (if shift: " with Shift" else: ""), act, done)
    proc typeInto(text: string; want: float64) =
      moveTo("plot.gain dB")
      step("click the box", proc (f: FrameInfo) =
        f.pressMouse(pointAt, true)
        f.pressMouse(pointAt, false), after(3))
      var frames = 0
      step("type " & text, proc (f: FrameInfo) =
        doAssert f.typing, "the gain box does not take the keys"
        f.pressKey(skCtrl, true, {smCtrl})
        f.typeText("a")
        f.pressKey(skCtrl, false)
        f.typeText(text)
        f.pressKey(skEnter, true)
        f.pressKey(skEnter, false),
        proc (f: FrameInfo): bool =
          inc frames
          result = f.db == want
          if not result and frames > 20:
            doAssert false, "typed " & text & ": " & $f.db & " dB, not " & $want)
      step("leave the box", proc (f: FrameInfo) =
        f.pressKey(skEscape, true)
        f.pressKey(skEscape, false),
        proc (f: FrameInfo): bool = not f.typing)
    var shot: Shot
    proc shows(mode: DisplayMode; gain: DisplayGain; fixed = NaN): proc (f: FrameInfo) =
      result = proc (f: FrameInfo) =
        var d = f.panel.layers[0].display
        (d.mode, d.gain, d.fixedClip) = (mode, gain, fixed)
        f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    proc picture(what: string; mode: DisplayMode; db: float64): proc (f: FrameInfo): bool =
      ## Done once the plot shows `mode` at `db` dB, drawn as the CPU reference
      ## draws it; the image is then in `shot`.
      result = proc (f: FrameInfo): bool =
        result = f.panel.layers[0].display.mode == mode and f.db == db and f.settled
        if result:
          shot = f.capture
          doAssert shot.scale.classify in {fcNormal, fcSubnormal, fcZero},
            what & ": scale " & $shot.scale
          let (bad, seen) = shot.mismatches()
          doAssert bad <= seen div 1000, what & ": " & $bad & " of " & $seen &
            " pixels off the reference" # a few, where a sample is about 0
    proc saturates(what: string; least, most: float64): proc (f: FrameInfo): bool =
      result = proc (f: FrameInfo): bool =
        let share = shot.saturated
        doAssert share >= least and share <= most, what & ": " & $round(share * 100, 1) &
          " % of the plot full black or white"
        true

    step("the file is shown", noop, proc (f: FrameInfo): bool =
      f.panel.laidOut and f.panel.layers.len > 0 and f.settled and f.db == 0)
    step("density", shows(dmDensity, dgAuto), after(2))
    # the type none applies no gain: its - and + are greyed and a click on them does nothing
    step("none", shows(dmDensity, dgNone), after(3))
    moveTo("plot.gain more")
    step("+ under none", proc (f: FrameInfo) =
      f.note
      f.pressMouse(pointAt, true)
      f.pressMouse(pointAt, false), after(8))
    step("none ignored it", noop, proc (f: FrameInfo): bool =
      doAssert f.db == before, "+ under none changed the amount: " & $f.db
      true)
    step("auto again", shows(dmDensity, dgAuto), after(3))
    click("plot.gain more", adds = 3)
    click("plot.gain more", shift = true, adds = 12)
    click("plot.gain less", adds = -3)
    # held: repeats until let go
    moveTo("plot.gain more")
    step("+ held", proc (f: FrameInfo) =
      f.note
      f.pressMouse(pointAt, true),
      proc (f: FrameInfo): bool = f.db >= before + 4 * 3)
    step("+ let go", proc (f: FrameInfo) =
      f.pressMouse(pointAt, false)
      f.note, after(30))
    step("no more after it", noop, proc (f: FrameInfo): bool =
      doAssert f.db == before, "+ went on after it was let go: " & $f.db
      true)
    key(skRightBracket, false, 3)
    key(skRightBracket, true, 12)
    key(skLeftBracket, true, -12)
    step("] held", proc (f: FrameInfo) =
      f.note
      f.pressKey(skRightBracket, true),
      proc (f: FrameInfo): bool = f.db >= before + 4 * 3)
    step("] let go", proc (f: FrameInfo) = f.pressKey(skRightBracket, false), after(3))
    typeInto("1000", 300)
    moveTo("plot.gain more")
    step("+ at the top", proc (f: FrameInfo) =
      f.pressMouse(pointAt, true)
      f.pressMouse(pointAt, false), after(6))
    step("still +300", noop, proc (f: FrameInfo): bool =
      doAssert f.db == 300, "+ at the top: " & $f.db
      true)
    step("+300 dB, density", noop, picture("+300 dB, density", dmDensity, 300))
    step("saturated", noop, saturates("+300 dB, density", 0.99, 1))
    step("Fixed 1e-30", shows(dmDensity, dgFixed, 1e-30), after(2))
    step("+300 dB, Fixed 1e-30", noop, picture("+300 dB, Fixed 1e-30", dmDensity, 300))
    step("saturated past a float32", noop, saturates("+300 dB, Fixed 1e-30", 0.99, 1))
    step("wiggles", shows(dmWiggle, dgFixed, 1e-30), after(2))
    var loud = 0
    step("+300 dB, wiggles", noop, picture("+300 dB, Fixed 1e-30, wiggles", dmWiggle, 300))
    step("the loud ink", proc (f: FrameInfo) = loud = shot.inked, after(2))
    step("Automatic again", shows(dmWiggle, dgAuto), after(2))
    typeInto("-1000", -300)
    step("-300 dB, wiggles", noop, picture("-300 dB, wiggles", dmWiggle, -300))
    step("baselines", noop, proc (f: FrameInfo): bool =
      doAssert shot.inked < loud, "-300 dB, wiggles: " & $shot.inked & " pixels of ink, " &
        "+300 dB: " & $loud
      doAssert shot.offBaselines == 0, "-300 dB, wiggles: " & $shot.offBaselines &
        " pixels of ink off the baselines"
      true)
    step("density again", shows(dmDensity, dgAuto), after(2))
    step("-300 dB, density", noop, picture("-300 dB, density", dmDensity, -300))
    step("mid grey", noop, saturates("-300 dB, density", 0, 0))

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
        wait = 0
        since = getMonoTime()
      else:
        inc wait
        if wait >= 2 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 600, since):
          failed = steps[at].name & " did not happen"
          f.stop()

    let code = run(RunOptions(openPaths: @[path], windowSize: (1300, 900),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguigainamount: ", steps.len, " steps"

when isMainModule:
  main()
