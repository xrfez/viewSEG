## The vibrator signature's mass fields on samples/vib, in the running
## frontend: the kg / lb switch converts the number in place (the stored
## kilograms do not change), a value typed in pounds is stored in kilograms,
## and Tools > Settings sets the same Units. The 100 % force box names the
## unit the force axis shows. Its Threads for folder reports choice sets how many files the
## folder reports read at once.
##
## Seen to fail: with the unit switch not issuing `ckSettings`, "imperial
## from the mass field" found units still metric; with the box storing the
## typed pounds as kilograms, "5000 lb stored" found 5000.0. With the force
## boxes writing no unit, "the force unit beside the box" found no mark.
## With the mass typed in one same-frame burst (Ctrl, a, Ctrl up, the
## digits, Enter two frames later) and that burst run once, the step
## advanced before the pounds were stored.
##
## Needs a display: run under the tester, which gives each file its own.
## Runs alone: typing into the mass box is counted in frames, and a loaded
## machine drops the keys.

import std/[math, options, os]
import viewSEG/core/[geometry, state, units]
import viewSEG/ui/imgui/app
import utils/fixtures

const sample = currentSourcePath().parentDir.parentDir / "samples" / "vib" /
  "vib_uncorrelated.sgd"

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc main*() =

  withFixtures fx:
    doAssert fileExists(sample), "no sample " & sample
    var steps: seq[Step] = @[]
    var pointAt: Vec2
    var stored = NaN
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    proc to(mark: string) =
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = r.centre
        f.moveMouse(pointAt), after(3))
    proc click(mark: string) =
      to(mark)
      step("click " & mark, proc (f: FrameInfo) =
        f.pressMouse(pointAt, true)
        f.pressMouse(pointAt, false), after(3))
    proc key(k: SimKey) =
      step("key " & $k, proc (f: FrameInfo) =
        f.pressKey(k, true)
        f.pressKey(k, false), after(2))
    proc typeMass() =
      # Re-click until the box has the keys and its centre has held for 2
      # frames, then one typeText. A frame that also moves the pointer does not
      # take text. Advance only when the stored kilograms match. A miss tries again.
      var held = 0
      var phase = 0
      var wait = 0
      var again = false
      step("type 5000 into the mass", proc (f: FrameInfo) = discard,
        proc (f: FrameInfo): bool =
        if f.core.plots.len == 0: return false
        let kg = f.core.plots[0].params.reactionMassKg
        if not kg.isNaN and abs(kg - storeMass(5000.0, usImperial)) < 1e-6:
          stored = kg
          return true
        let r = f.markOf("new plot 1.reaction mass")
        if r.size.x == 0: return false
        let c = r.centre
        if phase == 0:
          if not f.typing or c != pointAt:
            held = 0
            pointAt = c
            f.moveMouse(c)
            if not f.typing:
              f.pressMouse(c, true)
              f.pressMouse(c, false)
            return false
          inc held
          if held < 2: return false
          phase = if again: 4 else: 1
          return false
        if phase == 4:
          f.pressKey(skCtrl, true, {smCtrl})
          f.typeText("a")
          f.pressKey(skCtrl, false)
          phase = 1
          return false
        if phase == 1:
          f.typeText("5000")
          phase = 2
          wait = 0
          return false
        if phase == 2:
          inc wait
          if wait < 2: return false
          f.pressKey(skEnter, true)
          f.pressKey(skEnter, false)
          phase = 3
          wait = 0
          return false
        inc wait
        if wait > 6:
          phase = 0
          held = 0
          again = true
        false)

    step("the vib file shown", noop, proc (f: FrameInfo): bool =
      f.core.sessions.len > 0 and panel(f).laidOut)
    step("a vibrator signature", proc (f: FrameInfo) =
      let base = f.core.sessions[0].base
      f.apply(Command(kind: ckOpenPlot, plotView: avVibrator,
        plotTraces: @[base, base + 1, base + 2, base + 3])),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.markOf("new plot 1.wheel").size.x > 0)
    click("new plot 1.wheel") # the masses are in the settings wheel
    step("the masses shown", noop, proc (f: FrameInfo): bool =
      f.markOf("new plot 1.reaction mass").size.x > 0 and
          f.markOf("new plot 1.unit kg").size.x > 0 and
          f.markOf("new plot 1.unit lb").size.x > 0)
    step("the force unit beside the box", noop, proc (f: FrameInfo): bool =
      f.markOf("new plot 1.force target").size.x > 0 and
        f.markOf("new plot 1.force unit").size.x > 0)
    click("new plot 1.unit lb")
    step("imperial from the mass field", proc (f: FrameInfo) =
      if f.core.settings.units != usImperial:
        let r = f.markOf("new plot 1.unit lb")
        if r.size.x > 0:
          let p = r.centre
          f.pressMouse(p, true)
          f.pressMouse(p, false),
      proc (f: FrameInfo): bool =
        doAssert f.core.plots[0].params.reactionMassKg.isNaN, "the switch stored a mass"
        f.core.settings.units == usImperial)
    typeMass()
    step("5000 lb stored", noop, proc (f: FrameInfo): bool =
      let kg = f.core.plots[0].params.reactionMassKg
      result = not kg.isNaN and abs(kg - storeMass(5000.0, usImperial)) < 1e-6
      if result: stored = kg)
    click("new plot 1.unit kg")
    step("back to metric, the mass unchanged", noop, proc (f: FrameInfo): bool =
      f.core.settings.units == usMetric and
        abs(f.core.plots[0].params.reactionMassKg - stored) < 1e-9)
    click("new plot 1.verdict") # closes the wheel
    click("menu.Tools")
    click("menu.Settings...")
    step("the Settings window", noop, proc (f: FrameInfo): bool =
      f.markOf("settings.units").size.x > 0 and f.markOf("settings.unit Imperial").size.x > 0)
    click("settings.unit Imperial")
    step("imperial from Settings", noop, proc (f: FrameInfo): bool =
      f.core.settings.units == usImperial and
        abs(f.core.plots[0].params.reactionMassKg - stored) < 1e-9)
    step("the threads row", noop, proc (f: FrameInfo): bool =
      result = f.markOf("settings.threads choice").size.x > 0
      if result:
        doAssert f.core.settings.itemThreads == 0, "not automatic by default"
        let shots = getEnv("VIEWSEG_SCREENSHOTS")
        if shots.len > 0:
          createDir(shots)
          doAssert f.savePng(shots / "threadset.png"), "cannot save the screenshot")
    click("settings.threads choice")
    click("settings.threads 2")
    step("two threads chosen", noop, proc (f: FrameInfo): bool =
      f.core.settings.itemThreads == 2 and f.core.itemThreads == 2)

    var at = 0
    var started = false
    var wait = 0
    var failed = ""
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
        elif wait > 800:
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(openPaths: @[sample], windowSize: (1400, 900),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguiunits: ok"

when isMainModule:
  main()
