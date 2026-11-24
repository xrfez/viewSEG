## The sort keys' popover offering a vendor field, in the running frontend, headless, on the
## synthetic file and map of `utils/vendorfile`: the sort drop-down's Custom... opens the
## popover, "Add a key" has a "Vendor fields" submenu that lists the file's numeric vendor
## fields (the names came by a job), a click on `counter` adds it as a key, its direction is
## turned to descending, and "Sort" sorts the traces by line, point, then the counter
## descending: the tile drawn has the traces last to first.
##
## Seen to fail: with the picked name not added as a key (`drawSortKeys` dropping it), "the key
## is in the popover did not happen"; with the menu items closing the popover (the item flag
## `AutoClosePopups` left on), the same step failed, the popover gone with the first click.
##
## `VIEWSEG_SCREENSHOTS=<dir>` saves vendorsort-menu.png (the submenu open) there.
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
    step("shown", noop, proc (f: FrameInfo): bool =
      result = f.answered and f.panel.layout.traces == PerRecord)
    proc setHeader(f: FrameInfo) =
      f.apply Command(kind: ckHeader, panel: MainPanel,
        header: HeaderChoice(auto: false, fields: @[headerRef(hfTrace)]))
    step("the header shows the trace number", setHeader, proc (f: FrameInfo): bool =
      f.answered and f.panel.header.fields == @[headerRef(hfTrace)])
    click("plot.sort")
    click("plot.sort.custom")
    step("the popover opens", noop, proc (f: FrameInfo): bool =
      f.markOf("plot.sort keys.add").size.x > 0)
    click("plot.sort keys.add")
    step("the vendor submenu is offered", noop, proc (f: FrameInfo): bool =
      f.markOf("plot.sort keys.add.vendor").size.x > 0)
    click("plot.sort keys.add.vendor")
    step("the fields are listed", noop, proc (f: FrameInfo): bool =
      result = f.markOf("plot.sort keys.add.vendor counter").size.x > 0
      if result:
        for name in ["status", "unitInfo.serial", "aux.serial", "batch"]:
          doAssert f.markOf("plot.sort keys.add.vendor " & name).size.x > 0,
            name & " is not listed"
        f.save("vendorsort-menu.png"))
    click("plot.sort keys.add.vendor counter")
    step("the key is in the popover", noop, proc (f: FrameInfo): bool =
      f.markOf("plot.sort keys.direction 2").size.x > 0)
    click("plot.sort keys.direction 2")
    click("plot.sort keys.sort")
    step("the traces are sorted by the counter, descending", noop, proc (f: FrameInfo): bool =
      result = f.panel.layers[0].order.len == 3 and f.answered and
        f.core.tiles(f.core.findPanel(MainPanel))[^1].header[0] == @[3.0, 2.0, 1.0]
      if result:
        doAssert f.panel.layers[0].order[2] == vendorKey("counter", true),
          $f.panel.layers[0].order)
    runSteps(path, steps, fx.dir,
      @[VendorFolder(dir: maps, origin: voProgram)])
    echo "tguivendorsort: ok"

when isMainModule:
  main()
