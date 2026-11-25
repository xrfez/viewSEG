## The Output window's "Processing" tick, headless, in the running frontend.
## It starts off, whatever the Seismic window's filters; ticked, a line in the
## warning colour names the filters that will be written. A write with the
## tick off holds the source's samples untouched while the plot has a
## band-pass on; with it ticked the samples differ.
##
## Seen to fail: with `processingOn` back to true, "the Processing tick starts
## on"; with the sentence left out, "no sentence for the filter"; with the
## options given the plot's filters whatever the tick, "the default write was
## filtered".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## With VIEWSEG_SCREENSHOTS set, the options with the sentence are saved as PNG.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, processing, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo): bool
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc clickWhen(f: FrameInfo; name: string): bool =
  let r = f.markOf(name)
  if r.size.x <= 0: return false
  f.click(r.centre)
  true

proc reveal(f: FrameInfo; name: string): bool =
  let r = f.markOf(name)
  let pane = f.markOf("output.pane.right")
  if r.size.x > 0 and pane.size.y > 0 and r.pos.y >= pane.pos.y + 2 and
      r.pos.y + r.size.y <= pane.pos.y + pane.size.y - 2: return true
  if pane.size.y > 0: f.scrollWheel(pane.centre, if r.pos.y > pane.pos.y: -2 else: 2)
  false

proc firstTrace(path: string): seq[float32] =
  var back = openSeismic(path, keys = false)
  let x = back.readTraces(1 .. 1)
  result.setLen x.shape[1]
  for j in 0 ..< result.len: result[j] = x[0, j]
  back.close()

proc main*() =
  var wait = 0
  var since = getMonoTime()
  withFixtures fx:
    let field = fx.dir / "data"
    let plain = fx.dir / "plain"
    let filtered = fx.dir / "filtered"
    for d in [field, plain, filtered, fx.dir / "config", fx.dir / "logs", fx.dir / "cache"]:
      createDir(d)
    copyFile(fx.surveySegy(), field / "shots.sgy")
    let shotsDir = getEnv("VIEWSEG_SCREENSHOTS")
    var answer: seq[string] = @[]
    let hook = proc (kind: DialogKind; location: string): seq[string] = answer
    var steps: seq[Step]
    proc step(name: string; act: proc (f: FrameInfo): bool; done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo): bool = true

    proc browse(f: FrameInfo): bool =
      f.apply Command(kind: ckBrowse, paths: @[field], showFirst: true)
      true
    proc listed(f: FrameInfo): bool =
      not f.core.fileList.scanning and f.core.fileList.folder.len > 0 and
        f.core.shownFile(f.core.findPanel(MainPanel)) >= 0
    step("the folder is listed and a file shown", browse, listed)

    proc band(f: FrameInfo): bool =
      f.apply Command(kind: ckProcessing, panel: MainPanel,
        processing: bounded(Processing(band: pbBandPass, f1: 5, f2: 10, f3: 40, f4: 60)))
      true
    proc banded(f: FrameInfo): bool =
      f.core.panels[f.core.findPanel(MainPanel)].layers[0].processing.band == pbBandPass
    step("the plot has a band-pass", band, banded)

    var opened = false
    proc openOutput(f: FrameInfo): bool =
      if opened: return true
      let it = f.markOf("menu.Output...")
      if it.size.x == 0 or f.markOf("menu.Output.disabled").size.x > 0:
        discard clickWhen(f, "menu.File")
        return false
      f.click(it.centre)
      opened = true
      true
    proc outputUp(f: FrameInfo): bool =
      if f.markOf("output.processing off").size.x == 0 and
          f.markOf("output.processing on").size.x == 0: return false
      doAssert f.markOf("output.processing off").size.x > 0, "the Processing tick starts on"
      doAssert f.markNames("output.processing.says").len == 0,
        "a sentence is shown with the tick off"
      true
    step("Output is open with Processing off", openOutput, outputUp)

    proc tickAll(f: FrameInfo): bool =
      if f.markOf("output.file shots.sgy on").size.x > 0: return true
      clickWhen(f, "output.all")
    proc ticked(f: FrameInfo): bool = f.markOf("output.file shots.sgy on").size.x > 0
    step("shots.sgy is ticked", tickAll, ticked)

    proc setDest(dest: string): proc (f: FrameInfo): bool =
      result = proc (f: FrameInfo): bool =
        answer = @[dest]
        if not reveal(f, "output.changeDest"): return false
        clickWhen(f, "output.changeDest")
    proc destIs(dest: string): proc (f: FrameInfo): bool =
      result = proc (f: FrameInfo): bool =
        f.markOf("output.destination " & dest).size.x > 0 and
          f.markOf("output.run").size.x > 0
    step("the first destination is set", setDest(plain), destIs(plain))

    proc run(f: FrameInfo): bool =
      if not reveal(f, "output.run"): return false
      clickWhen(f, "output.run")
    proc wroteTo(dest: string): proc (f: FrameInfo): bool =
      result = proc (f: FrameInfo): bool =
        if f.markOf("output.summary 0 1 0").size.x > 0:
          doAssert false, "the write failed: " & $f.markNames("output.row")
        fileExists(dest / "shots.sgy") and f.markOf("output.summary 1 0 0").size.x > 0
    step("Run writes with the default", run, wroteTo(plain))

    proc tick(f: FrameInfo): bool =
      if not reveal(f, "output.processing.tick"): return false
      clickWhen(f, "output.processing.tick")
    proc says(f: FrameInfo): bool =
      if f.markNames("output.processing.says The written traces will be filtered: " &
          "band-pass").len == 0: return false
      if shotsDir.len > 0:
        createDir(shotsDir)
        doAssert f.savePng(shotsDir / "output-processing.png"), "cannot save the picture"
      true
    step("ticked, the sentence names the band-pass", tick, says)

    step("the second destination is set", setDest(filtered), destIs(filtered))
    step("Run writes with Processing ticked", run, wroteTo(filtered))

    var at = 0
    var started = false
    var failed = ""
    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if not started:
        if steps[at].act(f):
          started = true
          wait = 0
          since = getMonoTime()
        elif overdue(wait, 800, since):
          failed = steps[at].name & " did not happen"
          f.stop()
        else:
          inc wait
      else:
        inc wait
        if wait >= 3 and steps[at].done(f):
          inc at
          started = false
          wait = 0
          since = getMonoTime()
        elif overdue(wait, 800, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(windowSize: (1920, 1080), theme: forceDark, persist: true,
      configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"),
      userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]),
      dialogs: hook, onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    let source = firstTrace(field / "shots.sgy")
    doAssert firstTrace(plain / "shots.sgy") == source, "the default write was filtered"
    doAssert firstTrace(filtered / "shots.sgy") != source, "the ticked write was not filtered"
    echo "tguioutputprocessing: ", steps.len, " steps"

when isMainModule:
  main()
