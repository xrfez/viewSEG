## The Headers window in the running frontend, headless, with real pointer
## and key events.
##
## A SEG-Y file shown: the Summary tab says what it is and counts the record
## shown; a click on the File headers tab shows it, and the settings
## remember it; its Text tab holds the textual header, its Binary tab the
## binary header's fields, without the Name column until the settings ask
## for it. A SEG-D record shown: its General tab lists the general headers
## (read off the UI thread), Channel sets puts the channel sets side by side
## with the fields that differ marked, and External header shows the
## external header's bytes.
##
## Seen to fail: with the tab chosen not put in the settings (no
## `ckSettings` when the tab changes), "the File headers tab was not
## remembered"; with the columns set up without `syncColumns` (every column
## shown), "stopped at binary" (the value pushed out of view by the Name and
## Offset columns); with `ckInspect` never sent, "the record's general
## headers never came".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves headers-*.png there.

import std/[math, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/fixtures

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc laidOut(f: FrameInfo): bool =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  p.laidOut and p.layout.traces > 0

func shown(f: FrameInfo; mark: string): bool = f.markOf(mark).size.x > 0

let shots = getEnv("VIEWSEG_SCREENSHOTS")
if shots.len > 0: createDir(shots)

proc shoot(f: FrameInfo; name: string) =
  if shots.len > 0:
    doAssert f.savePng(shots / name), "cannot save " & name
    echo "tguiheaders: saved ", shots / name

type Step = proc (f: FrameInfo; wait: int): bool {.nimcall.}
  ## One step of a run: true once it is done; it asserts what must hold.

proc runSteps(path: string; steps: openArray[(string, Step)]; cache: string) =
  ## Shows `path` and takes `steps` one after another, each given up to 400
  ## frames.
  var stage = 0
  var wait = 0
  var reached: seq[string]
  let all = @steps
  proc onFrame(f: FrameInfo) =
    inc wait
    if f.index == 0: f.moveMouse(vec2(4, 4))
    if stage < all.len:
      if all[stage][1](f, wait):
        reached.add all[stage][0]
        inc stage
        wait = 0
      else: doAssert wait < 400, "stopped at \"" & all[stage][0] & "\" after " & $reached
    else: f.stop()
  let code = run(RunOptions(maxFrames: 4000, openPaths: @[path], windowSize: (1600, 1000),
    indexCacheDir: some(cache), theme: forceDark, onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert stage == all.len, "stopped at stage " & $stage & " after " & $reached
  echo "tguiheaders: ", path.extractFilename, ": ", reached.join(", ")

var at: Vec2
proc click(f: FrameInfo; wait: int; mark: string) =
  ## A click on `mark` over frames 1 to 5 of a step.
  if wait == 1:
    at = f.markOf(mark).centre
    doAssert at.x > 0, "nothing to click: " & mark
    f.moveMouse(at)
  if wait == 3: f.pressMouse(at, true)
  if wait == 5: f.pressMouse(at, false)

withFixtures fx:
  runSteps(fx.surveySegy(), [
    ("summary", Step(proc (f: FrameInfo; wait: int): bool =
      result = f.laidOut and f.shown("headers.summary value Traces") and wait > 5
      if result:
        doAssert f.core.settings.headers.tab == htSummary
        doAssert f.shown("headers.summary value Sample interval")
        doAssert f.shown("headers.summary.heading")
        f.shoot("headers-summary-segy.png"))),
    ("file headers", Step(proc (f: FrameInfo; wait: int): bool =
      f.click(wait, "headers.tab file")
      result = wait > 8
      if result:
        doAssert f.core.settings.headers.tab == htFile,
          "the File headers tab was not remembered"
        doAssert not f.shown("headers.summary"), "the summary is still shown"
        doAssert f.shown("headers.file tab Text") and f.shown("##text")
        f.shoot("headers-text-segy.png"))),
    ("binary", Step(proc (f: FrameInfo; wait: int): bool =
      f.click(wait, "headers.file tab Binary")
      result = wait > 8 and f.shown("headers.binary binary.jobId 0")
      if result:
        doAssert not f.shown("headers.binary name binary.jobId"), "the Name column is shown"
        f.shoot("headers-binary-segy.png"))),
    ("name column", Step(proc (f: FrameInfo; wait: int): bool =
      if wait == 1:
        var s = f.core.settings
        s.headers.columns = {hcDescription, hcName, hcBytes}
        f.apply Command(kind: ckSettings, settings: s)
      result = wait > 4
      if result:
        doAssert f.shown("headers.binary name binary.jobId"),
          "the Name column did not follow the settings"
        doAssert f.core.settings.headers.columns == {hcDescription, hcName, hcBytes},
          "the table changed the settings: " & $f.core.settings.headers.columns))],
    fx.dir / "cache")

  runSteps(fx.areasSegd(), [
    ("shown", Step(proc (f: FrameInfo; wait: int): bool = f.laidOut and wait > 3)),
    ("file headers", Step(proc (f: FrameInfo; wait: int): bool =
      f.click(wait, "headers.tab file")
      result = wait > 8 and f.shown("headers.general gh1.fileNumber 0")
      if wait == 300: doAssert false, "the record's general headers never came"
      if result:
        doAssert ipRecord in f.core.inspection.parts
        f.shoot("headers-general-segd.png"))),
    ("channel sets", Step(proc (f: FrameInfo; wait: int): bool =
      f.click(wait, "headers.file tab Channel sets")
      result = wait > 8 and f.shown("headers.sets st1cs1.channelType 0")
      if result:
        doAssert f.shown("headers.sets differs st1cs1.channelType"),
          "the channel types that differ are not marked"
        doAssert not f.shown("headers.sets differs st1cs1.scanTypeNumber")
        f.shoot("headers-sets-segd.png"))),
    ("external", Step(proc (f: FrameInfo; wait: int): bool =
      f.click(wait, "headers.file tab External")
      result = wait > 8 and f.shown("headers.bytes external line 0")
      if result: f.shoot("headers-external-segd.png")))],
    fx.dir / "cache")
