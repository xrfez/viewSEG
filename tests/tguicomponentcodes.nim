## A SEG-Y trace identification code counts as a component only when it names a sensor
## component (11 to 17). A record whose codes are a vibrator's (18 to 21) or a
## manufacturer's own (28, 29, 30, 33 to 36) has no component buttons and no component
## colours; a record of codes 12, 13, 14 still has its three.
##
## Needs a display: run under the tester.
##
## Seen to fail: with `componentOf` giving parseSEG's `component` for every code, the
## thirteen-trace file had buttons for 28, 29, 30 and 33 to 36 (`noButtons`).

import std/[options, os]
import parseSEG
import viewSEG/core/[components, geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, vibfiles]

func answered(f: FrameInfo): bool =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  p.laidOut and tiles.len > 0 and tiles[^1].request == p.pending and
    p.pending.gen == p.requestGen

proc buttonsOf(path, dir: string): tuple[codes: seq[uint8], marks: bool] =
  ## The component buttons the Seismic window has for `path` once its record is drawn:
  ## the codes the reader found, and whether any button is on screen.
  var frames = 0
  var done = false
  var got: tuple[codes: seq[uint8], marks: bool]
  proc onFrame(f: FrameInfo) =
    if f.index == 0: f.moveMouse(vec2(4, 4))
    if done or frames > 600: f.stop()
    elif f.answered:
      inc frames
      if frames > 20:
        got.codes = f.core.panels[f.core.findPanel(MainPanel)].componentCodes
        for code in 1 .. 60:
          if f.markOf("plot.component." & $code).size.x > 0: got.marks = true
        done = true
    else: inc frames
  let code = run(RunOptions(openPaths: @[path], windowSize: (1400, 900), theme: forceDark,
    userThemeDir: some(dir / "no-user-themes"), indexCacheDir: some(dir / "cache"),
    onFrame: onFrame))
  doAssert code == 0 and done, "no answer for " & path
  result = got

proc main*() =
  block unit:
    var k = initTraceKeys()
    (k.traceCode, k.component) = (29'i16, 29'u8)
    doAssert componentOf(k) == 0
    (k.traceCode, k.component) = (19'i16, 19'u8)
    doAssert componentOf(k) == 0
    (k.traceCode, k.component) = (13'i16, 13'u8)
    doAssert componentOf(k) == 13
    (k.traceCode, k.component) = (0'i16, 2'u8) # SEG-D: the group index or sensor type
    doAssert componentOf(k) == 2
  withFixtures fx:
    block noButtons:
      for path in [fx.vibThirteenSegy(), fx.vibFourSegy()]:
        let got = buttonsOf(path, fx.dir)
        doAssert got.codes.len == 0 and not got.marks, $got
    block sensorsStay:
      let got = buttonsOf(fx.sensorsSegy(), fx.dir)
      doAssert got.codes.len == 3 and got.marks, $got
  echo "tguicomponentcodes: ok"

when isMainModule:
  main()
