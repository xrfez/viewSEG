## Operations > References, the Store dialog and the archive table, driven
## headless. Screenshots of the three dialogs are written under .scratch
## (the sample file only).
##
## Seen to fail: with no Operations menu, "Operations > Generate a reference...
## did not happen"; with the store item missing from the plot's menu, "the
## store dialog did not happen".

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

const root = currentSourcePath().parentDir.parentDir
const shots = root / ".scratch"

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

withFixtures fx:
  let path = root / "samples" / "land" / "shots.sgy"
  doAssert fileExists(path), path
  let config = fx.dir / "config"
  createDir(config)
  createDir(shots)
  var steps: seq[Step]
  var at = 0
  var started = false
  var wait = 0
  var since = getMonoTime()
  var failed = ""
  var plot: Rect
  var shotGen, shotStore, shotArchive = false

  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)

  proc noop(f: FrameInfo) = discard

  proc clickMark(f: FrameInfo; mark: string): bool =
    let r = f.markOf(mark)
    if r.size.x > 0 and wait mod 6 == 3:
      f.click(r.centre)
      true
    else: false

  step("the file opens", noop, proc (f: FrameInfo): bool =
    let p = f.core.panels[f.core.findPanel(MainPanel)]
    result = p.laidOut and f.markOf("plot.data").size.x > 0 and f.core.referencesLoaded
    if result: plot = f.markOf("plot.data"))

  step("Operations > Generate a reference...", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("menu.Operations").centre), proc (f: FrameInfo): bool =
    let it = f.markOf("menu.Generate a reference...")
    let bar = f.markOf("menu.Operations")
    if it.size.x == 0:
      if wait == 2: f.click(bar.centre)
      elif wait mod 10 == 0: f.click(bar.centre)
    elif wait mod 6 == 3: f.click(it.centre)
    result = f.markOf("generate").size.x > 0
    if result and not shotGen: shotGen = f.savePng(shots / "generate-reference.png"))

  step("the generate dialog closes", noop, proc (f: FrameInfo): bool =
    discard f.clickMark("generate.cancel")
    f.markOf("generate").size.x == 0)

  step("the plot's menu offers Store as reference", proc (f: FrameInfo) =
    f.moveMouse(plot.centre), proc (f: FrameInfo): bool =
    if wait == 3: f.click(plot.centre, button = 3)
    f.markOf("plot.menu.store").size.x > 0)

  step("Store as reference...", noop, proc (f: FrameInfo): bool =
    if f.markOf("store").size.x == 0: discard f.clickMark("plot.menu.store")
    result = f.markOf("store").size.x > 0 and f.markOf("store.raw").size.x > 0
    if result and not shotStore: shotStore = f.savePng(shots / "store-reference.png"))

  step("the trace is stored", noop, proc (f: FrameInfo): bool =
    if f.markOf("store").size.x > 0: discard f.clickMark("store.ok")
    f.markOf("store").size.x == 0 and f.core.references.entries.len >= 1)

  step("a synthetic sweep is stored", proc (f: FrameInfo) =
    var g = GeneratedReference(name: "AAA synthetic", law: rlLinear, f1Hz: 8, f2Hz: 40,
      durationMs: 200, dtMs: 2, amplitude: 1)
    f.apply(Command(kind: ckGenerateReference, refGenerate: g)), proc (f: FrameInfo): bool =
      var found = false
      for e in f.core.references.entries:
        if e.name == "AAA synthetic": found = true
      found)

  step("Operations > Reference archive...", proc (f: FrameInfo) =
    f.click(f.markOf("menu.Operations").centre), proc (f: FrameInfo): bool =
    let it = f.markOf("menu.Reference archive...")
    if it.size.x == 0:
      if wait mod 8 == 0: f.click(f.markOf("menu.Operations").centre)
    elif wait mod 6 == 3: f.click(it.centre)
    result = f.markOf("references").size.x > 0 and f.markOf("references.row.0").size.x > 0 and
      wait > 6
    if result and not shotArchive:
      shotArchive = f.savePng(shots / "reference-archive.png"))

  step("Use selects it", noop, proc (f: FrameInfo): bool =
    if f.core.chosenReference.len == 0: discard f.clickMark("references.use.0")
    f.core.chosenReference.len > 0)

  step("View opens the reference in its own window", noop, proc (f: FrameInfo): bool =
    # The file under QC stays open. The reference is a window of its own.
    if f.markOf("reference.view.time.data").size.x == 0:
      discard f.clickMark("references.view.0")
    let still = f.core.sessions.len == 1 and f.core.sessions[0].name.endsWith("shots.sgy")
    let shown = f.markOf("reference.view").size.x > 0 and
      f.markOf("reference.view.time.data").size.x > 0 and
      f.markOf("reference.view.spectrum.data").size.x > 0
    result = still and shown and f.core.refViews.len >= 1 and not f.core.refViews[0].waiting and
      f.core.refViews[0].name == "AAA synthetic"
    if result:
      discard f.savePng(shots / "reference-view.png")
      if f.core.refViews.len > 0:
        f.apply Command(kind: ckCloseRefView, refWindow: f.core.refViews[0].id))

  step("Delete asks, and confirms", noop, proc (f: FrameInfo): bool =
    if f.core.references.entries.len == 0: return true
    if f.markOf("references.confirm").size.x == 0: discard f.clickMark("references.delete.0")
    elif wait mod 6 == 3: f.click(f.markOf("references.confirm.delete").centre)
    false)

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
      failed = steps[at].name & " did not happen; Operations " & $f.markOf("menu.Operations") &
        " item " & $f.markOf("menu.Generate a reference...")
      for e in f.core.log: echo "  log: ", e.text
      discard f.savePng(shots / "references-failed.png")
      f.stop()

  let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000), theme: forceDark,
    persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
    indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
    onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  doAssert shotGen and shotStore and shotArchive, "a dialog was not saved"
  echo "tguireferences: ", steps.len, " steps"
