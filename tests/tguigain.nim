## Every setting of the gain drop-down survives a restart, headless, set as
## the user sets it, with real clicks and typing in the drop-down: a first
## run on a new installation (a settings folder of its own) opens the shot
## with the defaults (Automatic: AGC over 500 ms; Exponential 6 dB per
## second until 2 000 ms; Normalized each trace to its 99th percentile; no
## Fixed amplitude yet; 0 dB), then sets the AGC window (300 ms), picks
## Fixed (its amplitude taken from the record) and types one (0.5),
## Normalized for the whole record to its RMS, Exponential at 9 dB per
## second, then the power of time at 1.5 until 3 000 ms, and +6 dB, and
## quits. The second run opens the shot as Exponential, t^1.5 until 3 000
## ms at +6 dB, and every other type's settings are as they were set: the
## AGC window 300 ms, the Fixed amplitude 0.5, Normalized for the record
## to its RMS, 9 dB per second. A third run, after Fixed's amplitude was
## taken from the record ("From this record") and the program quit, opens
## another file (of other amplitudes) with that amplitude, not one taken
## again from the file.
##
## The second run also clicks the explanation of Fixed (not its radio): picked,
## and the explanations start in one column. Seen to fail: with the explanation's
## click ignored, "picked by its explanation"; with the explanations not
## aligned, "the explanation of ... is not in the column".
##
## Seen to fail: with the plot's display not kept in the settings
## (`ckDisplay` not changing `Settings.plot`), and with the cutoff left out
## of `settings.nif`'s writer, "`"(untilMs 3000" in saved`" after the first
## run; with the amplitude taken from the record kept in the plot only
## (`settleGain` not changing the settings), "the third run: the Fixed
## amplitude is nan, not 0.98...".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc display(f: FrameInfo): DisplaySettings = f.panel.layers[0].display

proc shown(f: FrameInfo): bool =
  f.panel.laidOut and f.panel.layers.len > 0 and f.markOf("plot.data").size.x > 0

proc runSteps(name: string; config, file: string; steps: seq[Step]) =
  ## Runs the program on `config`'s settings with `file` open, through `steps`.
  var at = 0
  var started = false
  var wait = 0 # frames since the step began, at `since`
  var since = getMonoTime()
  var failed = ""
  proc onFrame(f: FrameInfo) =
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
      elif overdue(wait, 300, since):
        failed = name & ": " & steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(persist: true, configDir: some(config),
    logDir: some(config / "logs"), openPaths: @[file], windowSize: (1400, 900),
    indexCacheDir: some(config / "cache"), onFrame: onFrame))
  doAssert code == 0, name & ": run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, name & ": stopped at " & steps[min(at, steps.high)].name

proc main*() =

  withFixtures fx:
    let file = fx.surveySegy()
    let config = fx.dir / "config"
    var steps: seq[Step]
    var pointAt: Vec2
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    proc click(mark: string) =
      ## Moves to the control marked `mark`, then clicks it.
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = r.centre
        f.moveMouse(pointAt), after(2))
      step("click " & mark, proc (f: FrameInfo) =
        f.pressMouse(pointAt, true)
        f.pressMouse(pointAt, false), after(3))
    proc typeInto(mark, text: string) =
      ## Types `text` into the box marked `mark`, replacing what it holds.
      click(mark)
      step("type " & text & " into " & mark, proc (f: FrameInfo) =
        doAssert f.typing, mark & " does not take the keys"
        f.pressKey(skCtrl, true, {smCtrl})
        f.typeText("a")
        f.pressKey(skCtrl, false)
        f.typeText(text), after(2))
      step("enter " & text, proc (f: FrameInfo) =
        f.pressKey(skEnter, true)
        f.pressKey(skEnter, false), after(3))

    # ------------------------------------------------------------ first run --
    step("the defaults", noop, proc (f: FrameInfo): bool =
      result = f.shown
      if result:
        let d = f.display
        doAssert d.gain == dgAuto and d.agcWindowMs == 500 and d.gainDb == 0
        doAssert d.timeGain == tgDbPerSecond and d.dbPerS == 6 and d.power == 2 and
          d.untilMs == 2000
        doAssert d.normScope == perTrace and d.normStat == normPercentile and
          d.clipPercentile == 99
        doAssert d.fixedClip.isNaN)
    click("plot.gain")
    click("plot.gain type " & $dgAgc)
    typeInto("plot.gain agc window", "300")
    click("plot.gain type " & $dgFixed)
    step("fixed from the record", noop, proc (f: FrameInfo): bool =
      f.display.gain == dgFixed and f.display.fixedClip > 0)
    typeInto("plot.gain fixed amplitude", "0.5")
    click("plot.gain type " & $dgNormalized)
    click("plot.gain " & $perPanel)
    click("plot.gain " & $normRms)
    click("plot.gain type " & $dgExponential)
    typeInto("plot.gain dB per second box", "9")
    typeInto("plot.gain power box", "1.5")
    typeInto("plot.gain until", "3000")
    step("close the drop-down", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false), after(3))
    click("plot.gain more")
    click("plot.gain more")
    step("all set", noop, proc (f: FrameInfo): bool =
      let d = f.display
      doAssert d.gain == dgExponential and d.timeGain == tgPower, $d
      doAssert d.agcWindowMs == 300 and d.fixedClip == 0.5 and d.normScope == perPanel and
        d.normStat == normRms and d.dbPerS == 9 and d.power == 1.5 and d.untilMs == 3000 and
        d.gainDb == 6, $d
      true)
    runSteps("the first run", config, file, steps)
    let saved = readFile(config / SettingsFileName)
    doAssert "(untilMs 3000" in saved, saved

    # ----------------------------------------------------------- second run --
    steps.setLen 0
    step("as set", noop, proc (f: FrameInfo): bool =
      result = f.shown
      if result:
        let d = f.display
        doAssert d.gain == dgExponential and d.timeGain == tgPower and d.power == 1.5,
          "the second run: " & $d.gain & ", " & $d.timeGain & ", " & $d.power
        doAssert d.untilMs == 3000, "the second run: until " & $d.untilMs & ", not 3000.0"
        doAssert d.gainDb == 6, "the second run: " & $d.gainDb & " dB"
        doAssert d.agcWindowMs == 300, "the second run: AGC window " & $d.agcWindowMs &
          ", not 300.0"
        doAssert d.fixedClip == 0.5, "the second run: the Fixed amplitude is " & $d.fixedClip
        doAssert d.normScope == perPanel and d.normStat == normRms, "the second run: " &
          $d.normScope & ", " & $d.normStat
        doAssert d.dbPerS == 9, "the second run: " & $d.dbPerS & " dB/s")
    click("plot.gain")
    step("the label", noop, proc (f: FrameInfo): bool =
      f.markOf("plot.gain until").size.x > 0)
    step("the explanations line up", noop, proc (f: FrameInfo): bool =
      result = f.markOf("plot.gain explain " & $dgAgc).size.x > 0
      if result:
        let x = f.markOf("plot.gain explain " & $dgNone).pos.x
        for g in [dgNone, dgFixed, dgNormalized, dgExponential, dgFloat, dgAgc]:
          doAssert f.markOf("plot.gain explain " & $g).pos.x == x,
            "the explanation of " & $g & " is not in the column of None's")
    # a click on the explanation (not on the radio) picks the type: the second run
    # opens as Exponential
    click("plot.gain explain " & $dgFixed)
    step("picked by its explanation", noop, proc (f: FrameInfo): bool =
      f.display.gain == dgFixed)
    click("plot.gain type " & $dgFixed)
    click("plot.gain from this record")
    step("taken from the record", noop, proc (f: FrameInfo): bool =
      f.display.fixedClip > 0 and f.display.fixedClip != 0.5)
    var taken = 0.0
    step("noted", proc (f: FrameInfo) = taken = f.display.fixedClip, after(2))
    runSteps("the second run", config, file, steps)

    # ------------------------------------------------------------ third run --
    steps.setLen 0
    step("the amplitude taken", noop, proc (f: FrameInfo): bool =
      result = f.shown
      if result:
        let d = f.display
        doAssert d.gain == dgFixed
        doAssert d.fixedClip == taken, "the third run: the Fixed amplitude is " &
          $d.fixedClip & ", not " & $taken)
    runSteps("the third run", config, fx.longSpreadSegy(), steps)
    echo "tguigain: ok"

when isMainModule:
  main()
