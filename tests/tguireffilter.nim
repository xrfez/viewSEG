## The Generate dialog's "Recording filter" section, headless: None is the default and
## shows nothing more; Linear phase shows its typed fields and the delay computed from the
## taps; Minimum phase offers coefficients or a family, a typed delay and a suggestion that
## is not applied. A screenshot goes to $VIEWSEG_FILTER_SHOT when that is set.
##
## Seen to fail: with the section drawn for None too, "None shows nothing more" did not
## hold; with the delay not computed from the taps, the key never carried 105 for 211 taps.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, references, state, threads]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

var readBack: seq[float32]

proc readStored(path: string): seq[float32] =
  ## A stored reference's samples, read on a worker thread as the program does.
  var t: Thread[string]
  proc look(p: string) {.thread.} =
    markWorkerThread()
    {.cast(gcsafe).}:
      readBack = readReferenceFile(p).samples
  createThread(t, look, path)
  joinThread(t)
  result = readBack

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

    proc has(f: FrameInfo; mark: string): bool = f.markOf(mark).size.x > 0

    proc previewKey(f: FrameInfo): string =
      let names = f.markNames("generate.previewkey.")
      if names.len == 0: "" else: names[^1]

    proc pick(comboMark, itemMark: string): proc (f: FrameInfo): bool =
      ## Opens the combo and clicks the item; done when the item has gone again.
      result = proc (f: FrameInfo): bool =
        let item = f.markOf(itemMark)
        if item.size.x > 0 and wait mod 4 == 0: f.click(item.centre)
        elif item.size.x == 0 and wait mod 8 == 0: f.click(f.markOf(comboMark).centre)
        item.size.x == 0 and wait > 12

    proc scrollTo(mark: string) =
      ## The settings are a column that scrolls (the dialog opens as tall as the screen
      ## allows): wheel it until `mark` is in view.
      step("scroll to " & mark, noop, proc (f: FrameInfo): bool =
        let (win, item, ok) = (f.markOf("generate"), f.markOf(mark), f.markOf("generate.ok"))
        if item.size.x == 0: return false
        result = item.pos.y >= win.pos.y + 3 * ok.size.y and
          item.pos.y + item.size.y <= ok.pos.y - ok.size.y
        if not result and wait mod 3 == 1:
          f.scrollWheel(vec2(win.pos.x + win.size.x / 4, win.pos.y + win.size.y / 2),
            if item.pos.y < win.pos.y + win.size.y / 2: 3 else: -3))

    proc enter(mark, text: string) =
      scrollTo(mark)
      step("click " & mark, proc (f: FrameInfo) = f.click(f.markOf(mark).centre),
        proc (f: FrameInfo): bool = wait >= 3)
      step("type " & text & " in " & mark, proc (f: FrameInfo) =
        f.pressKey(skCtrl, true, {smCtrl})
        f.typeText("a")
        f.pressKey(skCtrl, false)
        f.typeText(text)
        f.pressKey(skEnter, true)
        f.pressKey(skEnter, false), proc (f: FrameInfo): bool = wait >= 4)

    step("the file opens", noop, proc (f: FrameInfo): bool =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      p.laidOut and f.markOf("plot.data").size.x > 0 and f.core.referencesLoaded)

    step("Operations > Generate a reference...", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("menu.Operations").centre), proc (f: FrameInfo): bool =
      let it = f.markOf("menu.Generate a reference...")
      let bar = f.markOf("menu.Operations")
      if it.size.x == 0:
        if wait mod 8 == 0: f.click(bar.centre)
      elif wait mod 6 == 3: f.click(it.centre)
      f.markOf("generate").size.x > 0)

    step("None is the default and shows nothing more", noop, proc (f: FrameInfo): bool =
      result = f.has("generate.preview.data") and f.has("generate.filter.kind") and
        not f.has("generate.filter.taps") and not f.has("generate.filter.shift") and
        not f.has("generate.filter.high") and "nofilter" in f.previewKey
      if result: keyBefore = f.previewKey)

    step("Linear phase", noop, pick("generate.filter.kind", "generate.filter.kind linear phase"))
    step("Linear phase shows its fields", noop, proc (f: FrameInfo): bool =
      result = f.has("generate.filter.taps") and f.has("generate.filter.high") and
        f.has("generate.filter.highslope") and f.has("generate.filter.low") and
        f.has("generate.filter.lowslope") and f.has("generate.filter.shift") and
        f.has("generate.filter.by") and
        not f.has("generate.filter.coef") and f.previewKey != keyBefore and
        "linear phase" in f.previewKey
      if result: keyBefore = f.previewKey)
    enter("generate.filter.taps", "211")
    step("the delay is computed from the taps", noop, proc (f: FrameInfo): bool =
      result = f.previewKey != keyBefore and " 105 " in f.previewKey
      if result: keyBefore = f.previewKey)
    enter("generate.filter.high", "100")
    enter("generate.filter.highslope", "48")
    step("the filtered preview is shown", noop, proc (f: FrameInfo): bool =
      result = "100.0 48.0" in f.previewKey and f.has("generate.preview.data") and
        not f.has("generate.computing") and not f.has("generate.message")
      if result: keyBefore = f.previewKey)
    step("a screenshot of the linear-phase fields", proc (f: FrameInfo) =
      let shot = getEnv("VIEWSEG_FILTER_SHOT")
      if shot.len > 0: discard f.savePng(shot & ".linear.png"),
      proc (f: FrameInfo): bool = wait >= 3)

    step("Minimum phase", noop, pick("generate.filter.kind", "generate.filter.kind minimum phase"))
    step("Minimum phase shows a family", noop, proc (f: FrameInfo): bool =
      result = f.has("generate.filter.by") and f.has("generate.filter.family") and
        f.has("generate.filter.highorder") and f.has("generate.filter.shift") and
        not f.has("generate.filter.taps") and not f.has("generate.filter.coef") and
        "minimum phase" in f.previewKey and f.previewKey != keyBefore
      if result: keyBefore = f.previewKey)
    enter("generate.filter.highorder", "6")
    step("a suggestion is offered and not applied", noop, proc (f: FrameInfo): bool =
      result = f.has("generate.filter.suggested") and " 6 0 0.0 0 0 0" in f.previewKey
      if result: keyBefore = f.previewKey)
    step("coefficients are typed in a text field", noop,
      pick("generate.filter.by", "generate.filter.by Coefficients"))
    step("the coefficients field is shown", noop, proc (f: FrameInfo): bool =
      f.has("generate.filter.coef") and not f.has("generate.filter.highorder"))
    step("a screenshot", proc (f: FrameInfo) =
      let shot = getEnv("VIEWSEG_FILTER_SHOT")
      if shot.len > 0: discard f.savePng(shot), proc (f: FrameInfo): bool = wait >= 3)
    # a coefficient that overflows the sample type: refused in the dialog, Generate disabled
    scrollTo("generate.filter.coef")
    step("click the coefficients", proc (f: FrameInfo) = f.click(f.markOf(
        "generate.filter.coef").centre),
      proc (f: FrameInfo): bool = wait >= 3)
    step("type an overflowing coefficient", proc (f: FrameInfo) = f.typeText("1e300"),
      proc (f: FrameInfo): bool = f.has("generate.message"))
    step("back to the family", noop, pick("generate.filter.by", "generate.filter.by Family"))
    step("the family is back and the message gone", noop, proc (f: FrameInfo): bool =
      f.has("generate.filter.highorder") and not f.has("generate.message") and
        not f.has("generate.filter.coef"))
    # a typed minimum-phase delay reaches the preview and the stored reference
    enter("generate.filter.shift", "3")
    step("the typed delay is in the settings", noop, proc (f: FrameInfo): bool =
      " 6 0 0.0 3 0 0" in f.previewKey and f.has("generate.preview.data") and
        not f.has("generate.computing"))
    step("Generate", proc (f: FrameInfo) = f.click(f.markOf("generate.ok").centre),
      proc (f: FrameInfo): bool =
      f.markOf("generate").size.x == 0 and f.core.references.entries.len == 1)
    step("the stored reference is the filtered, shifted sweep", noop, proc (f: FrameInfo): bool =
      let e = f.core.references.entries[0]
      doAssert e.origin.filter.shiftSamples == 3 and e.origin.filter.kind == rfMinimum
      let g = GeneratedReference(law: rlLinear, f1Hz: 8, f2Hz: 80, durationMs: 8000, dtMs: 2,
        taperStartMs: 200, taperEndMs: 200, taperShape: tpCos2, amplitude: 1,
        filter: RefFilter(kind: rfMinimum, family: rfButterworth, highCutHz: 100, highOrder: 6,
        shiftSamples: 3, shiftTyped: true))
      let want = generateSamples(g)
      doAssert readStored(f.core.referencesHome / e.file) == want, "stored file is not the " &
        "filtered sweep with the typed delay"
      true)

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
        if getEnv("VIEWSEG_FILTER_SHOT").len > 0:
          discard f.savePng(getEnv("VIEWSEG_FILTER_SHOT") & ".failed.png")
        f.stop()

    let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000), theme: forceDark,
      persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguireffilter: ", steps.len, " steps"

when isMainModule: main()
