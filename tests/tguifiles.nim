## The Files window in the running frontend, headless, with real pointer and
## key events: a folder named on the command line is listed and its first
## file shown; a click on a row shows that file; with the window focused,
## Up, Tab, Shift + Tab, Home and End step through the files and show each
## in the same plot window; the same keys in the plot window do not; a
## folder dropped on the window is listed and its first file shown, a file
## dropped is shown with its folder listed; Ctrl + W closes the file shown;
## the filter box hides the rows that do not match; each file stepped away
## from is closed; the files are never changed.
##
## Seen to fail: with the window's keys handled only while the window
## itself (not its table) has the focus, it "stopped before up"; with
## SDL_EVENT_DROP_COMPLETE ignored, "stopped before drop folder"; with a
## row's click acted on only when the row is the file shown already,
## "stopped before click".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves files-<name>.png there, with the example
## files when they are present (local only).

import std/[math, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/fixtures

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc shownPath(f: FrameInfo): string =
  let i = f.core.shownFile(f.core.findPanel(MainPanel))
  if i >= 0: f.core.sessions[i].path else: ""

proc laidOut(f: FrameInfo): bool =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  p.laidOut and p.layout.traces > 0

func has(lines: seq[Message]; part: string): bool =
  for m in lines:
    if part in m.text: return true
  false

withFixtures fx:
  let dir = fx.dir / "line 7"
  createDir(dir)
  copyFile(fx.surveySegy(), dir / "shot10.sgy")
  copyFile(fx.twoSetSegd(), dir / "shot2.sgd")
  copyFile(fx.threeComponentSegd(), dir / "Shot1.sgd")
  writeFile(dir / "notes.txt", "Line 7.\n".repeat(500))
  let other = fx.dir / "line 8"
  createDir(other)
  copyFile(fx.longSpreadSegy(), other / "a.sgy")
  copyFile(fx.twoSetSegd(), other / "b.sgd")
  var before: seq[Snapshot]
  for name in ["shot10.sgy", "shot2.sgd", "Shot1.sgd"]: before.add snapshot(dir / name)

  var
    stage = 0
    wait = 0
    at: Vec2
    reached: seq[string] # what each stage saw
    lines: seq[Message]
    filtered = false
    plotKeysStepped = false
    maxOpen = 0
    closedToStart = false
  proc key(f: FrameInfo; k: SimKey; mods: set[SimMod] = {}) =
    ## Presses and releases `k` over this frame and the next two, as a
    ## keyboard does (modifiers first).
    case wait
    of 1:
      if smShift in mods: f.pressKey(skShift, true, {smShift})
      if smCtrl in mods: f.pressKey(skCtrl, true, {smCtrl})
    of 2: f.pressKey(k, true, mods)
    of 3: f.pressKey(k, false, mods)
    of 4:
      if smShift in mods: f.pressKey(skShift, false)
      if smCtrl in mods: f.pressKey(skCtrl, false)
    else: discard
  proc next(f: FrameInfo; what: string) =
    reached.add what
    inc stage
    wait = 0
  proc onFrame(f: FrameInfo) =
    inc wait
    maxOpen = max(maxOpen, f.core.sessions.len)
    if f.index == 0: f.moveMouse(vec2(4, 4))
    let shown = f.shownPath
    case stage
    of 0: # the command line's folder: listed, its first file shown
      if not f.core.fileList.scanning and shown == dir / "Shot1.sgd" and f.laidOut and
          f.markOf("files.row shot10.sgy").size.x > 0:
        at = f.markOf("files.row shot10.sgy").centre
        f.moveMouse(at)
        f.next "listed"
    of 1: # a click on shot10
      if wait == 3: f.pressMouse(at, true)
      if wait == 5: f.pressMouse(at, false)
      if wait > 5 and shown == dir / "shot10.sgy" and f.laidOut: f.next "click"
    of 2:
      f.key(skUp)
      if wait > 4 and shown == dir / "shot2.sgd" and f.laidOut: f.next "up"
    of 3:
      f.key(skTab)
      if wait > 4 and shown == dir / "shot10.sgy" and f.laidOut: f.next "tab"
    of 4:
      f.key(skTab, {smShift})
      if wait > 4 and shown == dir / "shot2.sgd" and f.laidOut: f.next "shift tab"
    of 5:
      f.key(skHome)
      if wait > 4 and shown == dir / "Shot1.sgd" and f.laidOut: f.next "home"
    of 6:
      f.key(skEnd)
      if wait > 4 and shown == dir / "shot10.sgy" and f.laidOut: f.next "end"
    of 7: # keys in the plot window are the plot's
      if wait == 1:
        at = f.markOf("plot.data").centre
        f.moveMouse(at)
      if wait == 3: f.pressMouse(at, true)
      if wait == 5: f.pressMouse(at, false)
      if wait == 8: f.pressKey(skDown, true)
      if wait == 10: f.pressKey(skDown, false)
      if wait > 30:
        plotKeysStepped = shown != dir / "shot10.sgy"
        f.dropPaths([other])
        f.next "plot keys"
    of 8: # a folder dropped
      if f.core.fileList.folder == other and shown == other / "a.sgy" and f.laidOut:
        f.dropPaths([dir / "shot2.sgd"])
        f.next "drop folder"
    of 9: # a file dropped
      if f.core.fileList.folder == dir and not f.core.fileList.scanning and
          shown == dir / "shot2.sgd" and f.laidOut:
        f.next "drop file"
    of 10: # Ctrl + W
      f.key(skW, {smCtrl})
      if wait > 4 and f.core.panels[0].layers.len == 0 and
          f.markOf("plot.open folder").size.x > 0:
        closedToStart = true
        at = f.markOf("files.filter").centre
        f.moveMouse(at)
        f.next "close"
    of 11: # the filter
      if wait == 3: f.pressMouse(at, true)
      if wait == 5: f.pressMouse(at, false)
      if wait == 7: f.typeText("shot1")
      if wait == 12:
        filtered = f.markOf("files.row Shot1.sgd").size.x > 0 and
          f.markOf("files.row shot10.sgy").size.x > 0 and
          f.markOf("files.row shot2.sgd").size.x == 0
        lines = f.messages
        f.stop()
    else: discard
    if f.index > 3000:
      lines = f.messages
      f.stop()

  let code = run(RunOptions(maxFrames: 4000, openPaths: @[dir], windowSize: (1600, 1000),
    indexCacheDir: some(fx.dir / "cache"), theme: forceDark,
    userThemeDir: some(fx.dir / "no-user-themes"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  const order = ["listed", "click", "up", "tab", "shift tab", "home", "end", "plot keys",
    "drop folder", "drop file", "close"]
  for i, s in order:
    doAssert reached.len > i, "stopped before \"" & s & "\": reached " & $reached &
      "; Messages: " & $lines
  doAssert not plotKeysStepped, "Down in the plot window stepped to another file"
  doAssert closedToStart
  doAssert filtered, "the filter did not hide shot2.sgd"
  doAssert maxOpen <= 2, $maxOpen & " files open at once: stepped-away files stay open"
  var closed: seq[string]
  for m in lines:
    if m.text.startsWith("Closed "): closed.add m.text
  doAssert closed == @["Closed shot2.sgd."], "only Ctrl + W's close is told: " & $closed
  var after: seq[Snapshot]
  for name in ["shot10.sgy", "shot2.sgd", "Shot1.sgd"]: after.add snapshot(dir / name)
  doAssert after == before, "stepping through the files changed one"
  echo "tguifiles: ", reached.len, " steps: ", reached.join(", ")

# ------------------------------------------------------------ screenshots --

const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

proc answered(f: FrameInfo): bool =
  let k = f.core.findPanel(MainPanel)
  let p = f.core.panels[k]
  let tiles = f.core.tiles(k)
  p.laidOut and not p.pending.isEmpty and p.pending.gen == p.requestGen and tiles.len > 0 and
    tiles[^1].request == p.pending

if getEnv("VIEWSEG_SCREENSHOTS").len > 0 and dirExists(examples):
  let shots = getEnv("VIEWSEG_SCREENSHOTS")
  createDir(shots)
  var saved = false
  var stage = 0
  var wait = 0
  proc onShot(f: FrameInfo) =
    inc wait
    if f.index == 0: f.moveMouse(vec2(4, 4))
    if stage == 0 and not f.core.fileList.scanning and f.answered:
      stage = 1
      wait = 0
    elif stage == 1 and wait > 5:
      saved = f.savePng(shots / "files-examples.png")
      f.stop()
    if f.index > 2000: f.stop()
  let tmp = getTempDir() / ("viewseg-files-" & $getCurrentProcessId())
  let code = run(RunOptions(maxFrames: 2500, openPaths: @[examples / "00000151_12900_11300.sgd"],
    windowSize: (1600, 1000), theme: forceDark, indexCacheDir: some(tmp),
    userThemeDir: some(tmp / "no-user-themes"), onFrame: onShot))
  removeDir(tmp)
  doAssert code == 0 and saved, "no screenshot of the example files"
  echo "tguifiles: saved ", shots / "files-examples.png"
