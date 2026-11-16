## Component colours and on/off buttons in the Seismic window, headless, with
## real clicks.
##
## On samples/obn/obn.sgd (four components a station: hydrophone, vertical,
## inline, crossline) the strip shows four buttons, H Z X Y. Turning
## hydrophone off drops a quarter of the traces and lays the rest out again;
## the buttons stay. The last one on cannot be turned off. A click after the
## filter selects the file trace the plot shows there, not a blank column.
## samples/land/shots.sgy has one component: no buttons, and the plot image
## has none of the component colours (the same ink as a record that is not
## multi-component; the shader's component path stays off).
##
## Seen to fail: with the buttons never drawn, "four component buttons"; with
## the filter ignored, "turning hydrophone off did not drop a quarter"; with
## the last button still sending a filter, "the last component turned off".
##
## Needs a display: the tester gives it one. Screenshots go to .scratch/.

import std/[monotimes, options, os]
import parseSEG
import viewSEG/core/[components, geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

const root = currentSourcePath().parentDir.parentDir
let shots = root / ".scratch"

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc answered(f: FrameInfo): bool =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

proc near(a, b: Rgba; d = 48): bool =
  abs(a.r.int - b.r.int) <= d and abs(a.g.int - b.g.int) <= d and abs(a.b.int - b.b.int) <= d

proc colourCounts(f: FrameInfo): array[4, int] =
  let (img, _, _) = f.tracePanel.plotImage
  for px in img:
    for i, c in DefaultComponentColours:
      if near(px, c): inc result[i]

proc componentAt(f: FrameInfo; position: int): uint8 =
  ## The component of the file trace the plot shows at `position`.
  result = 0
  if position notin 0 .. f.panel.shown.high: return
  let trace = f.panel.shown[position]
  for t in f.core.tiles(f.core.findPanel(MainPanel)):
    for row, tr in t.traces:
      if tr == trace and row < t.keys.len: return t.keys[row].component

proc runSteps(file: string; steps: seq[Step]; dir: string) =
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
  let code = run(RunOptions(openPaths: @[file], windowSize: (1400, 900),
    theme: forceDark, userThemeDir: some(dir / "no-user-themes"),
    indexCacheDir: some(dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc save(f: FrameInfo; name: string) =
  createDir(shots)
  doAssert f.savePng(shots / name), "could not write " & name

withFixtures fx:
  let obn = root / "samples" / "obn" / "obn.sgd"
  let land = root / "samples" / "land" / "shots.sgy"
  doAssert fileExists(obn) and fileExists(land)
  var steps: seq[Step]
  var pointAt: Vec2
  var before = 0
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

  step("four component buttons", noop, proc (f: FrameInfo): bool =
    result = f.answered and f.panel.layout.traces > 0 and f.panel.layout.traces mod 4 == 0
    if result:
      before = f.panel.layout.traces
      for code in [1'u8, 2, 3, 4]:
        doAssert f.markOf("plot.component." & $code).size.x > 0, "button " & $code & " missing"
      for letter in ["H", "Z", "X", "Y"]:
        doAssert f.markOf("plot.component.letter." & letter).size.x > 0, "letter " & letter
      doAssert f.markOf("plot.traces.Seismic").size.x == 0, "aux toggles on a seismic-only record"
      doAssert f.panel.componentCodes == @[1'u8, 2, 3, 4], $f.panel.componentCodes
      doAssert f.panel.layers[0].filter.components.card == 0)
  click("plot.component.1")
  step("turning hydrophone off did not drop a quarter", noop, proc (f: FrameInfo): bool =
    result = f.answered and f.panel.layout.traces == before * 3 div 4
    if result:
      doAssert f.panel.layers[0].filter.components == {1'u8}
      doAssert f.panel.shown.len == before * 3 div 4
      for code in [1'u8, 2, 3, 4]:
        doAssert f.markOf("plot.component." & $code).size.x > 0, "button " & $code & " went"
      # not blank columns: the first column is the next file trace, vertical
      doAssert f.panel.shown[0] != 0, "hydrophone still in the first column"
      doAssert f.componentAt(0) == 2, "first column component " & $f.componentAt(0)
      f.save("obn-one-off.png"))
  step("to the first column", proc (f: FrameInfo) =
    let r = f.markOf("plot.data")
    let v = f.tracePanel.drawnView
    pointAt = vec2(round(r.pos.x + float32((0.0 - v.traces.lo) / v.traces.width) * r.size.x),
      round(r.pos.y + r.size.y / 2))
    f.moveMouse(pointAt), after(4))
  step("selection maps to the file trace", proc (f: FrameInfo) =
    f.pressMouse(pointAt, true)
    f.pressMouse(pointAt, false), proc (f: FrameInfo): bool =
      if f.core.selection.selected.len == 0: return false
      let i = f.core.shownFile(f.core.findPanel(MainPanel))
      let id = f.core.sessions[i].base + f.panel.shown[0]
      result = f.core.selection.selected.len == 1
      if result:
        var got = 0
        for t in f.core.selection.selected: got = t
        doAssert got == id, "selected " & $got & ", file trace " & $id
        doAssert f.componentAt(0) == 2
  )
  click("plot.component.2")
  step("vertical off", noop, proc (f: FrameInfo): bool =
    f.answered and f.panel.layout.traces == before div 2)
  click("plot.component.3")
  step("inline off, crossline alone", noop, proc (f: FrameInfo): bool =
    result = f.answered and f.panel.layout.traces == before div 4
    if result:
      doAssert f.panel.layers[0].filter.components == {1'u8, 2, 3}
  )
  click("plot.component.4")
  step("the last component turned off", noop, proc (f: FrameInfo): bool =
    result = f.answered and f.panel.layout.traces == before div 4
    if result:
      doAssert f.panel.layers[0].filter.components == {1'u8, 2, 3}
      doAssert f.markOf("plot.component.4").size.x > 0
  )
  # back to all on, for the colour picture: turn the three back on
  click("plot.component.1")
  step("hydrophone back", noop, proc (f: FrameInfo): bool =
    f.answered and f.panel.layout.traces == before div 2 and f.panel.shown.len == before div 2)
  click("plot.component.2")
  step("vertical back", noop, proc (f: FrameInfo): bool =
    f.answered and f.panel.layout.traces == before * 3 div 4)
  click("plot.component.3")
  step("all on again", noop, proc (f: FrameInfo): bool =
    result = f.answered and f.panel.layout.traces == before and
      f.panel.layers[0].filter.components.card == 0
    if result:
      f.moveMouse(vec2(4, 4))
      let counts = f.colourCounts
      for i, n in counts:
        doAssert n > 20, "component colour " & $i & " has " & $n & " pixels"
      f.save("obn-wiggle.png"))
  click("plot.Greyscale density")
  step("density band", noop, proc (f: FrameInfo): bool =
    result = f.answered and f.panel.layers[0].display.mode == dmDensity
    if result:
      let (img, w, h) = f.tracePanel.plotImage
      var band = 0
      let rows = min(6, h)
      for y in 0 ..< rows:
        for x in 0 ..< w:
          for c in DefaultComponentColours:
            if near(img[y * w + x], c): inc band
      doAssert band > 20, "density band pixels " & $band
      f.save("obn-density.png"))
  click("plot.more")
  step("component colour pickers", noop, proc (f: FrameInfo): bool =
    result = f.markOf("plot.component colour.hydrophone").size.x > 0 and
      f.markOf("plot.component colour.reset").size.x > 0
    if result: f.save("gear-component-colours.png"))

  runSteps(obn, steps, fx.dir)
  echo "tguicomponents: obn ok, ", before, " traces"

  var landSteps: seq[Step]
  proc lstep(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    landSteps.add Step(name: name, act: act, done: done)
  lstep("land, no buttons, same ink", noop, proc (f: FrameInfo): bool =
    result = f.answered and f.panel.layout.traces == 96
    if result:
      doAssert f.panel.componentCodes.len <= 1, $f.panel.componentCodes
      doAssert f.markOf("plot.component.1").size.x == 0, "a component button on the land record"
      f.moveMouse(vec2(4, 4))
      let counts = f.colourCounts
      for i, n in counts:
        doAssert n == 0, "land plot has component colour " & $i & " (" & $n & " pixels)"
      f.save("land-unchanged.png"))
  runSteps(land, landSteps, fx.dir / "land")
  echo "tguicomponents: land ok"

  var threeSteps: seq[Step]
  proc tstep(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    threeSteps.add Step(name: name, act: act, done: done)
  tstep("three-component letters are 1 2 3, not H Z X", noop, proc (f: FrameInfo): bool =
    result = f.answered and f.panel.componentCodes == @[1'u8, 2, 3]
    if result:
      for letter in ["1", "2", "3"]:
        doAssert f.markOf("plot.component.letter." & letter).size.x > 0, "letter " & letter
      for letter in ["H", "Z", "X", "Y"]:
        doAssert f.markOf("plot.component.letter." & letter).size.x == 0,
          "three-component.sgd showed " & letter)
  runSteps(fx.threeComponentSegd(), threeSteps, fx.dir / "three")
  echo "tguicomponents: three-component ok"

# The land file's components, read here so a button that filtered the wrong
# code would not match the sample (hydrophone is sensor type 1).
block obn_codes:
  var o = openSeismic(root / "samples" / "obn" / "obn.sgd", keys = true)
  doAssert o.len >= 96
  for i in 0 ..< 96:
    doAssert o.traceKeys(i).component == uint8(i mod 4 + 1)
  o.close()
