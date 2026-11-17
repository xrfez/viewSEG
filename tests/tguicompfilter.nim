## The component filter across records, headless, with real clicks.
##
## The set stores what is switched off. On a file of three records, turning
## component 1 off leaves a component first seen on the next record shown.
## The record after that has only component 1: every component present is
## off, so all are shown again and one message says so.
##
## Seen to fail: with the filter storing which components are on, the new
## component on the second record stayed hidden; with no restore, the third
## record drew no trace and logged nothing.
##
## Needs a display: the tester gives it one.

import std/[monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[components, geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc answered(f: FrameInfo): bool =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

proc saidRestore(f: FrameInfo): int =
  for m in f.messages:
    if m.text.find(ComponentsRestored) >= 0: inc result

proc writeRecords(path: string) =
  ## Record 1: components 1 and 2. Record 2: 1 and a new 5. Record 3: only 1.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 4,
    time: 1_700_000_000.0))
  var samples = newSeq[float32](4)
  proc trace(record: float64; channel, component, sensor: uint8) =
    var k = initTraceKeys()
    k.record = record
    k.channel = float64(channel)
    k.component = component
    k.sensorType = sensor
    k.intervalUs = 2000
    k.t0Ms = 0
    k.status = tsLive
    w.writeTrace(k, samples)
  trace(1, 1, 1, 2)
  trace(1, 2, 1, 2)
  trace(1, 3, 2, 3)
  trace(1, 4, 2, 3)
  trace(2, 1, 1, 2)
  trace(2, 2, 1, 2)
  trace(2, 3, 5, 4)
  trace(2, 4, 5, 4)
  trace(3, 1, 1, 2)
  trace(3, 2, 1, 2)
  doAssert w.close().len == 0, "the three-record file was not written"

proc main*() =

  withFixtures fx:
    let path = fx.dir / "comp-across.sgd"
    writeRecords(path)
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
    step("record 1, both components", noop, proc (f: FrameInfo): bool =
      result = f.answered and f.panel.layout.traces == 4 and
        f.panel.componentCodes == @[1'u8, 2]
      if result:
        doAssert f.panel.layers[0].filter.components.card == 0
        doAssert f.saidRestore == 0)
    click("plot.component.1")
    step("component 1 off", noop, proc (f: FrameInfo): bool =
      result = f.answered and f.panel.layout.traces == 2
      if result: doAssert f.panel.layers[0].filter.components == {1'u8})
    click("plot.next record")
    step("a component first seen later is shown", noop, proc (f: FrameInfo): bool =
      result = f.answered and f.panel.componentCodes == @[1'u8, 5] and f.panel.layout.traces == 2
      if result:
        doAssert f.panel.layers[0].filter.components == {1'u8},
          "the new component was stored as off: " & $f.panel.layers[0].filter.components
        doAssert f.markOf("plot.component.5").size.x > 0
        doAssert f.saidRestore == 0)
    click("plot.next record")
    step("every component off is shown again", noop, proc (f: FrameInfo): bool =
      result = f.answered and f.panel.layout.traces == 2 and f.panel.componentCodes == @[1'u8]
      if result:
        doAssert f.panel.layers[0].filter.components.card == 0, "the off set was kept"
        doAssert f.saidRestore == 1, "restore was logged " & $f.saidRestore & " times")
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
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
    let code = run(RunOptions(openPaths: @[path], windowSize: (1400, 900), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguicompfilter: ok"

when isMainModule:
  main()
