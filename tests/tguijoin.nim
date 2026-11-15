## The "Join geometry" window in the running frontend, headless, driven by
## SDL events as the user's mouse and keyboard send them, on a SEG-D record
## whose headers name stations but give (0, 0) coordinates, with the
## survey's S, R and X files loaded:
##
## - File > Import > Survey... opens the window; the loaded survey files are
##   listed, ticked; Tab moves between its controls;
## - Join joins them: the window says what it did in plain words, the file's
##   keys hold the survey's coordinates, the plot shows the joined record
##   again and the status bar draws a joined value (the offset) in the
##   accent colour; the map shows the file's own receivers at the survey's
##   places;
## - "Select unmatched traces" selects the traces the survey has no
##   receiver for;
## - an option set in the window is remembered (the settings).
##
## Seen to fail: with `marked` not marking the focused control, "Tab moves
## between the controls" found no focused control; with the status bar's
## joined colour left out, "the offset is drawn as joined" found no pixel in
## the accent colour.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves join-*.png there, and with the example
## files present the Morgantown record joined with its S, R and X files
## (`join-morgantown-1.png`: the record beside its map, a trace hovered;
## `join-morgantown-2.png`: the window with what the join did).

import std/[math, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/theme
import utils/fixtures

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc focused(f: FrameInfo): string =
  ## The window's control that has the keyboard focus; "" for none.
  for n in ["join.file", "join.file units", "join.survey survey.s", "join.survey survey.r",
      "join.survey survey.x", "join.add", "join.survey units", "join.options",
      "join.trailing digits", "join.line names", "join.components", "join.coordinates",
      "join.run", "join.close"]:
    if f.markOf("join.focused " & n).size.x > 0: return n
  ""

proc drive(steps: seq[Step]; paths: seq[string]; dir: string; size = (1400, 1000)) =
  var at = 0
  var started = false
  var wait = 0
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
    else:
      inc wait
      if wait >= 3 and steps[at].done(f):
        inc at
        started = false
      elif wait > 600:
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(maxFrames: 12000, openPaths: paths, windowSize: size,
    theme: forceDark, userThemeDir: some(dir / "no-user-themes"),
    indexCacheDir: some(dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

let shots = getEnv("VIEWSEG_SCREENSHOTS")

proc shot(f: FrameInfo; name: string) =
  if shots.len > 0:
    createDir(shots)
    discard f.savePng(shots / name)

proc inPlot(f: FrameInfo; position: int): Vec2 =
  let r = f.markOf("plot.data")
  let v = f.tracePanel.drawnView
  vec2(round(r.pos.x + float32((float64(position) - v.traces.lo) / v.traces.width) *
    r.size.x), round(r.pos.y + r.size.y / 2))

proc accentPixels(f: FrameInfo; mark: string): int =
  ## The pixels of `mark`'s rectangle in the theme's accent colour.
  let r = f.markOf(mark)
  let a = f.theme.roles[rlAccent]
  for y in int(r.pos.y) ..< int(r.pos.y + r.size.y):
    for x in int(r.pos.x) ..< int(r.pos.x + r.size.x):
      let c = f.readPixel(x, y)
      if abs(int(c.r) - int(a.r)) + abs(int(c.g) - int(a.g)) + abs(int(c.b) - int(a.b)) < 40:
        inc result

proc joinWindow() =
  withFixtures fx:
    let path = fx.stationsSegd()
    let sps = fx.surveySps()
    var steps: seq[Step]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    step("loaded", noop, proc (f: FrameInfo): bool =
      f.core.survey.layers.len == 4 and f.panel.laidOut and
        f.core.tiles(f.core.findPanel(MainPanel)).len > 0)
    step("File > Import > Survey...", proc (f: FrameInfo) =
      f.click(f.markOf("menu.File").centre), proc (f: FrameInfo): bool =
      let item = f.markOf("menu.Import survey...")
      if item.size.x > 0: f.click(item.centre)
      elif f.markOf("menu.Import").size.x > 0 and f.index mod 10 == 0:
        f.click(f.markOf("menu.Import").centre)
      f.joinWindow.shown and f.markOf("join").size.x > 0)
    step("the loaded survey files are listed", noop, proc (f: FrameInfo): bool =
      result = f.markOf("join.run").size.x > 0
      if result:
        for n in ["survey.s", "survey.r", "survey.x"]:
          doAssert f.markOf("join.survey " & n).size.x > 0, "no " & n
        f.shot("join-window.png"))
    var seen: seq[string]
    step("Tab moves between the controls", proc (f: FrameInfo) =
      let w = f.markOf("join")
      f.click(vec2(w.pos.x + w.size.x - 30, w.pos.y + 60)) # its background: the focus
      f.pressKey(skTab, true)
      f.pressKey(skTab, false), proc (f: FrameInfo): bool =
      let now = f.focused
      if now.len > 0 and now notin seen: seen.add now
      if now.len > 0 and seen.len < 4:
        f.pressKey(skTab, true)
        f.pressKey(skTab, false)
      seen.len >= 4)
    step("the options open", proc (f: FrameInfo) = f.click(f.markOf("join.options").centre),
      proc (f: FrameInfo): bool = f.markOf("join.components").size.x > 0)
    step("an option is remembered", proc (f: FrameInfo) =
      f.click(f.markOf("join.components").centre), proc (f: FrameInfo): bool =
      f.core.settings.join.multiComponent)
    step("and set back", proc (f: FrameInfo) = f.click(f.markOf("join.components").centre),
      proc (f: FrameInfo): bool = not f.core.settings.join.multiComponent)
    step("Join", proc (f: FrameInfo) = f.click(f.markOf("join.run").centre),
      proc (f: FrameInfo): bool =
      result = f.core.joinReport.serial > 0 and f.core.joinUnderWay.job == NoJob and
        f.markOf("join.report").size.x > 0 and f.markOf("join.unmatched").size.x > 0
      if result:
        doAssert f.core.joinReport.outcome == joJoined, $f.core.joinReport.words
        doAssert "12 of 24 seismic traces matched the survey" in f.core.joinReport.words[0])
    step("the window shows what the join did", noop, proc (f: FrameInfo): bool =
      let (w, r) = (f.markOf("join"), f.markOf("join.unmatched"))
      result = r.pos.y > w.pos.y and r.pos.y + r.size.y < w.pos.y + w.size.y
      if result: f.shot("join-done.png"))
    step("Select unmatched traces", proc (f: FrameInfo) =
      f.click(f.markOf("join.unmatched").centre), proc (f: FrameInfo): bool =
      result = f.core.selection.selected.len == SegdChannels
      if result:
        for t in SegdChannels + 1 .. 2 * SegdChannels:
          doAssert f.core.sessions[0].base + t in f.core.selection.selected)
    step("Close", proc (f: FrameInfo) = f.click(f.markOf("join.close").centre),
      proc (f: FrameInfo): bool = not f.joinWindow.shown and f.markOf("join").size.x == 0)
    step("the plot shows the joined record", proc (f: FrameInfo) =
      f.moveMouse(f.inPlot(f.panel.shown.find(3))), proc (f: FrameInfo): bool =
      let k = f.core.findPanel(MainPanel)
      result = f.core.tiles(k).len > 0 and f.core.tiles(k)[^1].joined.len > 0 and
        f.pick.found and f.pick.trace == 3 and jgReceiverXy in f.pick.joined)
    step("the offset is drawn as joined", noop, proc (f: FrameInfo): bool =
      result = f.accentPixels("status." & $rfOffset) > 5
      if result:
        doAssert f.accentPixels("status." & $rfChannel) == 0, "the channel is not joined"
        f.shot("join-hover.png"))
    step("the map shows the file's receivers", noop, proc (f: FrameInfo): bool =
      let own = f.core.survey.findTraces(f.core.sessions[0].id)
      own >= 0 and f.core.survey.layers[own].keysRevision == 1 and
        f.core.survey.layers[own].points[prReceiver].len == SegdChannels)
    drive(steps, @[path, sps.s, sps.r, sps.x], fx.dir)
    echo "tguijoin: the window, ", steps.len, " steps; Tab went through ", seen.join(", ")

joinWindow()

# ------------------------------------------------------ Morgantown: shots --
# With `VIEWSEG_SCREENSHOTS=<dir>` and the example files present (local
# only): the Morgantown record and its S, R and X files in the "Plot and
# map" layout, joined (the headers' coordinates replaced by the survey's),
# a trace hovered: its source and receiver lit on the map.

const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

proc morgantown(dir: string) =
  let base = examples / "sps" / "PGI_NNE_West_Morgantown_3D_Post261019_NAD27_SPCS_WV_N_USFeet"
  let record = examples / "00000151_12900_11300.sgd"
  let preset = currentSourcePath().parentDir.parentDir / "assets" / "layouts" / "Plot and map.nif"
  var stage = 0
  var wait = 0
  var saved = 0
  var loads = 0
  proc onFrame(f: FrameInfo) =
    inc wait
    let k = f.core.findPanel(MainPanel)
    case stage
    of 0:
      if f.index == 2:
        loads = f.core.layoutLoads
        f.apply Command(kind: ckLoadLayout, docPath: preset)
      if f.core.survey.layers.len >= 4 and f.core.panels[k].laidOut and
          f.core.tiles(k).len > 0 and f.core.layoutLoads > loads and wait > 30:
        var files: seq[JoinFile]
        for e in [".sps", ".rps", ".xps"]: files.add JoinFile(path: base & e, kind: jkSps)
        f.apply Command(kind: ckJoin, joinFile: f.core.sessions[0].id, joinFiles: files,
          joinOptions: JoinOptions(coordinates: hcReplace), joinUnits: JoinUnits(
          survey: suUsFeet, file: suUsFeet))
        (stage, wait) = (1, 0)
    of 1:
      if f.core.joinReport.serial > 0 and f.core.joinUnderWay.job == NoJob and
          f.core.tiles(k).len > 0 and f.core.tiles(k)[^1].joined.len > 0 and wait > 20:
        echo "tguijoin: Morgantown: ", f.core.joinReport.words.join(" ")
        let plot = f.markOf("plot.data")
        f.moveMouse(vec2(round(plot.pos.x + plot.size.x * 0.62), round(plot.pos.y +
          plot.size.y * 0.4)))
        (stage, wait) = (2, 0)
    of 2:
      if wait == 30:
        if f.core.selection.hoverAt.len > 0 and f.savePng(dir / "join-morgantown-1.png"):
          inc saved
        f.moveMouse(vec2(4, 4))
        (stage, wait) = (3, 0)
    of 3:
      if wait == 2:
        # The window, with what the join did.
        let m = f.markOf("menu.File")
        f.moveMouse(m.centre)
        f.pressMouse(m.centre, true)
        f.pressMouse(m.centre, false)
      if wait == 6:
        let sub = f.markOf("menu.Import")
        f.moveMouse(sub.centre)
        f.pressMouse(sub.centre, true)
        f.pressMouse(sub.centre, false)
      if wait == 14:
        let item = f.markOf("menu.Import survey...")
        if item.size.x > 0:
          f.moveMouse(item.centre)
          f.pressMouse(item.centre, true)
          f.pressMouse(item.centre, false)
      if wait == 40:
        if f.markOf("join.report").size.x > 0 and f.savePng(dir / "join-morgantown-2.png"):
          inc saved
        f.stop()
    else: discard
    if f.index > 9000: f.stop()
  let tmp = getTempDir() / ("viewseg-joinshots-" & $getCurrentProcessId())
  let code = run(RunOptions(maxFrames: 10000, openPaths: @[record, base & ".sps", base & ".rps",
    base & ".xps"], windowSize: (1600, 1000), theme: forceDark, indexCacheDir: some(tmp),
    userThemeDir: some(tmp / "no-user-themes"), onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0 and saved == 2, "no screenshots of Morgantown (stage " & $stage &
    ", saved " & $saved & ")"
  echo "tguijoin: saved ", dir / "join-morgantown-1.png", " and -2.png"

if shots.len > 0 and fileExists(examples / "00000151_12900_11300.sgd"):
  createDir(shots)
  morgantown(shots)
