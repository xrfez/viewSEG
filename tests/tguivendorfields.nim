## The display-line menu's "Vendor fields" submenu, in the running frontend, headless, on
## the synthetic file and map of `utils/vendorfile`: from the plot's gear, Traces tab,
## with the automatic fields off,
##
## - the submenu opens and lists the file's numeric vendor fields (the names came by a job,
##   not from a read in the frame), text fields among them but disabled;
## - a click on `counter` ticks it: the display header has the vendor line, and the tile
##   drawn has the file's values of that field for each trace of the record;
## - a second click unticks it: the line is gone from the header.
##
## Seen to fail: with the tick not sending the header command (`res.commands.add` left out in
## `drawVendorFields`), "the vendor line was not chosen"; with `watchVendorFields` not called
## in the frame, the submenu stayed "Reading…" and "the fields are listed did not happen".
##
## `VIEWSEG_SCREENSHOTS=<dir>` saves vendorfields-menu.png (the submenu open) and
## vendorfields-line.png (the line shown with its values) there.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, sequtils]
import viewSEG/core/[geometry, panels, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, vendorfile, waiting]

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

let shots = getEnv("VIEWSEG_SCREENSHOTS")

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc answered(f: FrameInfo): bool =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

proc save(f: FrameInfo; name: string) =
  if shots.len > 0:
    createDir(shots)
    doAssert f.savePng(shots / name), "could not write " & name

proc runSteps(file: string; steps: seq[Step]; dir: string; maps: seq[VendorFolder]) =
  var at = 0
  var started = false
  var wait = 0
  var since = getMonoTime()
  var failed = ""
  proc onFrame(f: FrameInfo) =
    if f.index == 0:
      f.keepInMainWindow()
      f.moveMouse(vec2(4, 4))
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
      elif overdue(wait, 400, since):
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(openPaths: @[file], windowSize: (1400, 900), persist: true,
    theme: forceDark, configDir: some(dir / "config"), logDir: some(dir / "logs"),
    vendorFolders: some(maps), indexCacheDir: some(dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc main*() =
  withFixtures fx:
    let path = fx.dir / "lines.sgd"
    writeLines(path)
    let maps = fx.dir / "maps"
    createDir(maps)
    writeFile(maps / "lines.nif", MapText)
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
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = r.centre
        f.moveMouse(pointAt), after(2))
      step("click " & mark, proc (f: FrameInfo) =
        f.pressMouse(pointAt, true)
        f.pressMouse(pointAt, false), after(2))
    func vendorLines(f: FrameInfo): seq[string] =
      for l in f.panel.header.fields:
        if l.field == hfVendor: result.add l.name

    step("shown", noop, proc (f: FrameInfo): bool =
      result = f.answered and f.panel.layout.traces == PerRecord)
    click("plot.more")
    click("plot.more tab traces")
    proc autoOff(f: FrameInfo) =
      doAssert f.markOf("plot.more.header.auto").size.x > 0, "the header choice is not shown"
      if f.panel.header.auto:
        f.apply Command(kind: ckHeader, panel: MainPanel,
          header: HeaderChoice(auto: false, fields: @[headerRef(hfTrace)]))
    proc submenuShown(f: FrameInfo): bool =
      not f.panel.header.auto and f.markOf("plot.more.header.vendor").size.x > 0
    step("automatic fields off", autoOff, submenuShown)
    click("plot.more.header.vendor")
    step("the fields are listed", noop, proc (f: FrameInfo): bool =
      result = f.markOf("plot.more.header.vendor counter").size.x > 0
      if result:
        for name in ["status", "unitInfo.serial", "aux.serial", "batch", "label", "rep"]:
          doAssert f.markOf("plot.more.header.vendor " & name).size.x > 0, name & " is not listed"
        doAssert f.markOf("plot.more.header.vendor filter").size.x == 0, "a filter for 7 fields"
        f.save("vendorfields-menu.png"))
    click("plot.more.header.vendor counter")
    step("the line is chosen and drawn with the file's values", noop, proc (f: FrameInfo): bool =
      result = f.vendorLines == @["counter"] and f.answered
      if result:
        let t = f.core.tiles(f.core.findPanel(MainPanel))[^1]
        doAssert t.fields.anyIt(it == vendorRef("counter")), "the tile has no such line"
        let row = t.fields.find(vendorRef("counter"))
        for j in 0 ..< PerRecord:
          doAssert t.header[row][j] == float64(counter(0, j)), $t.header[row]
        f.save("vendorfields-line.png"))
    click("plot.more.header.vendor counter")
    step("the line is let go", noop, proc (f: FrameInfo): bool =
      result = f.vendorLines.len == 0 and f.answered)
    runSteps(path, steps, fx.dir,
      @[VendorFolder(dir: maps, origin: voProgram)])
    echo "tguivendorfields: ok"

when isMainModule:
  main()
