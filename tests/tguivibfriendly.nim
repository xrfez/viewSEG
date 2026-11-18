## The Vibrator signature window on a synthetic file with the vibrator codes shows who
## is who in one line and the two buttons (Swap mass and baseplate, Roles from the
## codes), and a damaged file is refused with one line in the Messages window and
## nothing shown.
##
## `VIBFRIENDLY_SHOT=<folder>` saves `vibfriendly-roles.png` and `vibfriendly-damaged.png`
## there.
##
## Needs a display: run under the tester.

import std/[options, os, strutils]
import viewSEG/core/[analysis, geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, vibfiles]

proc shotDir(): string = getEnv("VIBFRIENDLY_SHOT")

proc runOne(path, dir: string; onFrame: proc (f: FrameInfo)) =
  let code = run(RunOptions(openPaths: @[path], windowSize: (1500, 1000), theme: forceDark,
    userThemeDir: some(dir / "no-user-themes"), indexCacheDir: some(dir / "cache"),
    onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code

proc main*() =
  withFixtures fx:
    block roles:
      var frames = 0
      var opened = false
      var done = false
      var clicked = 0 # the roles' table is folded until its line is clicked
      proc onFrame(f: FrameInfo) =
        if f.index == 0: f.moveMouse(vec2(4, 4))
        inc frames
        let k = f.core.findPanel(MainPanel)
        if not opened and f.core.shownFile(k) >= 0 and f.core.panels[k].laidOut and frames > 20:
          opened = true
          frames = 0
          let base = f.core.sessions[f.core.shownFile(k)].base
          f.apply(Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[base]))
        elif opened and f.core.plots.len == 1 and not f.core.plots[0].waiting and frames > 40:
          doAssert f.core.plots[0].params.roles.source == rsCodes
          doAssert f.markOf("new plot 1.roles line").size.x > 0, "no roles line"
        let ready = opened and f.core.plots.len == 1 and frames > 40
        if ready and clicked < 3 and not f.core.plots[0].waiting:
          let r = f.markOf("new plot 1.roles header")
          let at = vec2(r.pos.x + r.size.x / 2, r.pos.y + r.size.y / 2)
          if clicked == 0: f.moveMouse(at)
          if clicked == 2:
            f.pressMouse(at, true, 1)
            f.pressMouse(at, false, 1)
          inc clicked
          if clicked == 3: frames = 40
        elif clicked >= 3 and f.core.plots.len == 1 and f.markOf(
            "new plot 1.swap").size.x > 0:
          doAssert f.markOf("new plot 1.swap").size.x > 0, "no swap button"
          doAssert f.markOf("new plot 1.roles from codes").size.x > 0, "no codes button"
          if shotDir().len > 0: discard f.savePng(shotDir() / "vibfriendly-roles.png")
          done = true
          f.stop()
        elif frames > 1500: f.stop()
      runOne(fx.vibFourSegy(), fx.dir, onFrame)
      doAssert done, "the window did not come"
    block damaged:
      var frames = 0
      var done = false
      proc onFrame(f: FrameInfo) =
        if f.index == 0: f.moveMouse(vec2(4, 4))
        inc frames
        var said = false
        for e in f.core.log:
          if "looks damaged" in e.text: said = true
        if said and frames > 40:
          doAssert f.core.sessions.len == 0, "the damaged file was opened"
          if shotDir().len > 0: discard f.savePng(shotDir() / "vibfriendly-damaged.png")
          done = true
          f.stop()
        elif frames > 1500: f.stop()
      runOne(fx.damagedSegy(), fx.dir, onFrame)
      doAssert done, "the damaged file was not refused"
  echo "tguivibfriendly: ok"

when isMainModule:
  main()
