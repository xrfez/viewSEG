## The Generate dialog, headless: both plots, the preview key, and the
## parameter field.
##
## Seen to fail: with the signal drawn as a line through points again (no dense
## signal given to the plot), "both plots appear" did not happen (no
## `generate.preview.band`); with the preview key leaving out the taper shape,
## "Kaiser shows its parameter and changes the key did not happen".

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; q: Vec2; button = 1) =
  f.moveMouse(q)
  f.pressMouse(q, true, button)
  f.pressMouse(q, false, button)

proc main*() =
  const root = currentSourcePath().parentDir.parentDir
  withFixtures fx:
    let path = root / "samples" / "land" / "shots.sgy"
    doAssert fileExists(path), path
    let config = fx.dir / "config"
    createDir(config)
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var keyBefore = ""

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc clickMark(f: FrameInfo; mark: string): bool =
      let r = f.markOf(mark)
      if r.size.x > 0 and wait mod 6 == 3:
        f.click(r.centre)
        true
      else: false

    proc previewKey(f: FrameInfo): string =
      let names = f.markNames("generate.previewkey.")
      if names.len == 0: "" else: names[^1]

    proc pickShape(f: FrameInfo; shape: string): bool =
      let item = f.markOf("generate.shape " & shape)
      if item.size.x > 0 and wait mod 4 == 0: f.click(item.centre)
      elif item.size.x == 0 and wait mod 8 == 0: f.click(f.markOf("generate.shape").centre)
      item.size.x == 0 and f.previewKey.len > 0 and shape in f.previewKey

    step("the file opens", noop, proc (f: FrameInfo): bool =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      p.laidOut and f.markOf("plot.data").size.x > 0 and f.core.referencesLoaded)

    step("Analysis > Generate a reference...", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("menu.Analysis").centre), proc (f: FrameInfo): bool =
      let it = f.markOf("menu.Generate a reference...")
      let bar = f.markOf("menu.Analysis")
      if it.size.x == 0:
        if wait mod 8 == 0: f.click(bar.centre)
      elif wait mod 6 == 3: f.click(it.centre)
      f.markOf("generate").size.x > 0)

    step("both plots appear", noop, proc (f: FrameInfo): bool =
      result = f.markOf("generate.preview.data").size.x > 0 and
        f.markOf("generate.spectrum.data").size.x > 0 and
        f.markOf("generate.param").size.x == 0 and
        f.markOf("generate.phase").size.x > 0 and
        f.markOf("generate.preview.band").size.x > 0 and
        f.markOf("generate.preview.samples").size.x == 0 and
        f.markOf("generate.computing").size.x == 0
      if result: keyBefore = f.previewKey)

    step("Kaiser shows its parameter and changes the key", noop, proc (f: FrameInfo): bool =
      if not f.pickShape("tpKaiser"): return false
      result = f.markOf("generate.param").size.x > 0 and f.previewKey != keyBefore and
        "tpKaiser" in f.previewKey
      if result: keyBefore = f.previewKey)

    step("cosine squared hides the parameter", noop, proc (f: FrameInfo): bool =
      if not f.pickShape("tpCos2"): return false
      result = f.markOf("generate.param").size.x == 0 and f.previewKey != keyBefore)

    step("Gaussian shows the parameter", noop, proc (f: FrameInfo): bool =
      if not f.pickShape("tpGaussian"): return false
      f.markOf("generate.param").size.x > 0 and "tpGaussian" in f.previewKey)

    step("power shows the parameter", noop, proc (f: FrameInfo): bool =
      if not f.pickShape("tpPower"): return false
      f.markOf("generate.param").size.x > 0 and "tpPower" in f.previewKey)

    step("linear hides the parameter", noop, proc (f: FrameInfo): bool =
      if not f.pickShape("tpLinear"): return false
      f.markOf("generate.param").size.x == 0 and "tpLinear" in f.previewKey)

    var phaseOpened = false
    step("a trace of the record: the Phase choice", noop, proc (f: FrameInfo): bool =
      if f.markOf("generate.pilot.phase").size.x > 0:
        if not phaseOpened:
          if wait mod 6 == 3: f.click(f.markOf("generate.pilot.phase").centre)
          if f.markOf("generate.pilot.deg 180").size.x > 0:
            phaseOpened = true
            f.click(f.markOf("generate.pilot.deg 180").centre)
          return false
        let shot = getEnv("PILOT_PHASE_SHOT")
        if shot.len > 0 and wait > 8: discard f.savePng(shot)
        return wait > 8
      let src = f.markOf("generate.source 1")
      if src.size.x > 0:
        if wait mod 6 == 3: f.click(src.centre)
      elif wait mod 8 == 0: f.click(f.markOf("generate.source").centre)
      false)

    step("the dialog closes", noop, proc (f: FrameInfo): bool =
      discard f.clickMark("generate.cancel")
      f.markOf("generate").size.x == 0)

    proc onFrame(f: FrameInfo) =
      inc wait
      if at >= steps.len: f.stop()
      elif not started:
        steps[at].act(f)
        started = true
        since = getMonoTime()
      elif steps[at].done(f):
        inc at
        started = false
        wait = 0
      elif overdue(wait, 400, since):
        failed = steps[at].name & " did not happen; key " & f.previewKey &
          " param " & $f.markOf("generate.param") &
          " signal " & $f.markOf("generate.preview.data") &
          " spectrum " & $f.markOf("generate.spectrum.data")
        discard f.savePng(currentSourcePath().parentDir.parentDir / ".scratch" /
          "generate-failed.png")
        f.stop()

    let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000), theme: forceDark,
      persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguigenerate: ", steps.len, " steps"

when isMainModule: main()
