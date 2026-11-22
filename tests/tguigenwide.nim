## The Generate dialog at the size it opens with, headless: wide enough, it has the
## settings in a column of their own (it scrolls) and the two preview plots in
## another, so that a Recording filter's extra rows no longer squeeze the plots; every
## field, both plots and the buttons stay inside the window with no filter and
## with a linear-phase one. `VIEWSEG_SCREENSHOTS=<dir>` saves generate-none.png and
## generate-linear.png there. (The dialog at its smallest, stacked: `tguigenmin`.)
##
## Seen to fail: with the dialog never wide (one column, as it was), "the dialog opened
## narrow" (and, before that, the plots of the old one column were squeezed under 8 font
## heights by the filter's rows).
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os, strutils]
import imguin/cimgui
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; q: Vec2) =
  f.moveMouse(q)
  f.pressMouse(q, true, 1)
  f.pressMouse(q, false, 1)

proc fontPx(): float32 =
  igGetFontSize() * igGetIO_Nil().DisplayFramebufferScale.x

proc inside(item, win: Rect): bool =
  item.size.x > 0 and item.size.y > 0 and item.pos.x >= win.pos.x - 1 and
    item.pos.y >= win.pos.y - 1 and item.pos.x + item.size.x <= win.pos.x + win.size.x + 1 and
    item.pos.y + item.size.y <= win.pos.y + win.size.y + 1

proc main*() =
  const root = currentSourcePath().parentDir.parentDir
  withFixtures fx:
    let path = root / "samples" / "land" / "shots.sgy"
    doAssert fileExists(path), path
    let config = fx.dir / "config"
    createDir(config)
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
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

    proc has(f: FrameInfo; mark: string): bool = f.markOf(mark).size.x > 0

    proc previewKey(f: FrameInfo): string =
      let names = f.markNames("generate.previewkey.")
      if names.len == 0: "" else: names[^1]

    proc layout(f: FrameInfo; fields: openArray[string]): string =
      ## "" when every field, both plots and the buttons are in the window, the plots
      ## beside the settings and tall enough; else what is wrong.
      let win = f.markOf("generate")
      let font = fontPx()
      let (signal, spec) = (f.markOf("generate.preview.data"), f.markOf("generate.spectrum.data"))
      if win.size.x < font * 70: return "the dialog opened narrow: " & $win
      for m in ["generate.ok", "generate.cancel", "generate.preview.data",
          "generate.spectrum.data", "generate.name"]:
        if not inside(f.markOf(m), win): return m & " is not in the window " & $win
      for m in fields:
        if not f.has(m): return m & " is missing"
      if signal.size.y < font * 8 or spec.size.y < font * 8:
        return "the plots are squeezed: " & $signal.size.y & " and " & $spec.size.y & " (font " &
          $font & ")"
      let name = f.markOf("generate.f1")
      if name.pos.x + name.size.x > signal.pos.x or name.pos.x + name.size.x > spec.pos.x:
        return "the plots are not beside the settings"
      ""

    proc pick(comboMark, itemMark: string): proc (f: FrameInfo): bool =
      result = proc (f: FrameInfo): bool =
        let item = f.markOf(itemMark)
        if item.size.x > 0 and wait mod 4 == 0: f.click(item.centre)
        elif item.size.x == 0 and wait mod 8 == 0: f.click(f.markOf(comboMark).centre)
        item.size.x == 0 and wait > 12

    proc enter(mark, text: string) =
      step("click " & mark, proc (f: FrameInfo) = f.click(f.markOf(mark).centre),
        proc (f: FrameInfo): bool = wait >= 3)
      step("type " & text & " in " & mark, proc (f: FrameInfo) =
        f.typeText(text)
        f.pressKey(skEnter, true)
        f.pressKey(skEnter, false), proc (f: FrameInfo): bool = wait >= 4)

    proc shoot(f: FrameInfo; name: string) =
      if shots.len > 0:
        createDir(shots)
        discard f.savePng(shots / name)

    step("the file opens", proc (f: FrameInfo) = f.keepInMainWindow, proc (f: FrameInfo): bool =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      p.laidOut and f.markOf("plot.data").size.x > 0 and f.core.referencesLoaded)

    step("Analysis > Generate a reference...", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("menu.Analysis").centre), proc (f: FrameInfo): bool =
      let it = f.markOf("menu.Generate a reference...")
      let bar = f.markOf("menu.Analysis")
      if it.size.x == 0:
        if wait mod 8 == 0: f.click(bar.centre)
      elif wait mod 6 == 3: f.click(it.centre)
      f.markOf("generate").size.x > 0 and f.has("generate.preview.data") and
        f.has("generate.spectrum.data") and "nofilter" in f.previewKey)

    step("no filter: the plots are beside the settings", noop, proc (f: FrameInfo): bool =
      result = wait > 12 and f.layout(["generate.f1", "generate.f2", "generate.length",
        "generate.dt", "generate.amplitude", "generate.law", "generate.shape",
        "generate.taper0", "generate.taper1", "generate.phase", "generate.filter.kind"]).len == 0
      if wait > 60 and not result:
        failed = f.layout(["generate.f1"])
        f.stop()
      if result:
        f.shoot("generate-none.png")
        keyBefore = f.previewKey)

    step("Linear phase", noop, pick("generate.filter.kind", "generate.filter.kind linear phase"))

    step("the settings scroll to the filter's fields", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("generate.name").centre),
      proc (f: FrameInfo): bool =
        if wait mod 3 == 1: f.scrollWheel(f.markOf("generate.name").centre, -3)
        let win = f.markOf("generate")
        wait > 8 and inside(f.markOf("generate.filter.taps"), win) and
          f.markOf("generate.filter.taps").pos.y + 4 * fontPx() < win.pos.y + win.size.y)
    # (a filter needs its taps, a cut and its slope before it is drawn)
    enter("generate.filter.taps", "211")
    enter("generate.filter.high", "60")
    enter("generate.filter.highslope", "24")

    step("linear phase: every field, both plots tall enough", noop, proc (f: FrameInfo): bool =
      let why = f.layout(["generate.f1", "generate.phase", "generate.filter.kind",
        "generate.filter.taps", "generate.filter.high", "generate.filter.highslope",
        "generate.filter.low", "generate.filter.lowslope", "generate.filter.shift",
        "generate.filter.by"])
      result = wait > 12 and why.len == 0 and f.previewKey != keyBefore and
        "linear phase" in f.previewKey
      if wait > 60 and not result:
        failed = "linear phase: " & (if why.len > 0: why else: "the preview did not change")
        f.stop()
      if result: f.shoot("generate-linear.png"))

    proc onFrame(f: FrameInfo) =
      inc wait
      if failed.len > 0: return
      if at >= steps.len: f.stop()
      elif not started:
        steps[at].act(f)
        started = true
        since = getMonoTime()
      elif steps[at].done(f):
        inc at
        started = false
        wait = 0
      elif overdue(wait, 500, since):
        failed = steps[at].name & " did not happen; window " & $f.markOf("generate") & " key " &
          f.previewKey
        f.stop()

    let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000), theme: forceDark,
      persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguigenwide: ", steps.len, " steps"

when isMainModule: main()
