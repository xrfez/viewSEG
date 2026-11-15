## The Headers window in the running frontend, headless, with real pointer
## and key events. A SEG-Y file shown: the Summary tab says what it is and
## counts the record shown; a click on the File headers tab shows it, and
## the settings remember it.
##
## Seen to fail: with the tab chosen not put in the settings (no
## `ckSettings` when the tab changes), "the File headers tab was not
## remembered".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves headers-*.png there.

import std/[math, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/fixtures

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc laidOut(f: FrameInfo): bool =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  p.laidOut and p.layout.traces > 0

let shots = getEnv("VIEWSEG_SCREENSHOTS")
if shots.len > 0: createDir(shots)

proc shoot(f: FrameInfo; name: string) =
  if shots.len > 0:
    doAssert f.savePng(shots / name), "cannot save " & name
    echo "tguiheaders: saved ", shots / name

withFixtures fx:
  var
    stage = 0
    wait = 0
    at: Vec2
    reached: seq[string]
  proc click(f: FrameInfo; mark: string) =
    if wait == 1:
      at = f.markOf(mark).centre
      f.moveMouse(at)
    if wait == 3: f.pressMouse(at, true)
    if wait == 5: f.pressMouse(at, false)
  proc onFrame(f: FrameInfo) =
    inc wait
    if f.index == 0: f.moveMouse(vec2(4, 4))
    proc next(name: string) =
      reached.add name
      inc stage
      wait = 0
    case stage
    of 0: # the Summary tab, the default
      if f.laidOut and f.markOf("headers.summary value Traces").size.x > 0 and wait > 5:
        doAssert f.core.settings.headers.tab == htSummary
        doAssert f.markOf("headers.summary value Sample interval").size.x > 0
        doAssert f.markOf("headers.summary.heading").size.x > 0
        f.shoot("headers-summary-segy.png")
        next "summary"
    of 1: # a click on File headers shows it and the settings keep it
      f.click("headers.tab file")
      if wait > 8:
        doAssert f.core.settings.headers.tab == htFile,
          "the File headers tab was not remembered"
        doAssert f.markOf("headers.summary").size.x == 0, "the summary is still shown"
        next "file headers"
    else: f.stop()
  let code = run(RunOptions(maxFrames: 2000, openPaths: @[fx.surveySegy()],
    windowSize: (1600, 1000), indexCacheDir: some(fx.dir / "cache"), theme: forceDark,
    onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert stage == 2, "stopped at stage " & $stage & " after " & $reached
  echo "tguiheaders: ", reached.join(", ")
