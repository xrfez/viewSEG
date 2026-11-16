## The "Import survey" window in the running frontend, headless, driven by
## SDL events as the user's mouse and keyboard send them, on a SEG-D record
## whose headers name stations but give (0, 0) coordinates, with the
## survey's S, R and X files loaded:
##
## - File > Import > Survey... opens the window, titled "Import survey"
##   (and so named under Window); the loaded survey files are listed,
##   ticked; Tab moves between its controls;
## - Import matches them to the file's traces: the window says what it did
##   in plain words, the file's keys hold the survey's coordinates, the plot
##   shows the record again and the status bar draws a value from the survey
##   (the offset) in the accent colour; the map shows the file's own
##   receivers at the survey's places; what the user reads of it (the
##   window's title, the job's title, the messages, the words) says import
##   and matched, never join;
## - the survey files, loaded before, are on the map once, not twice;
## - "Select unmatched traces" selects the traces the survey has no
##   receiver for;
## - an option set in the window is remembered (the settings);
## - survey files not loaded before, added with "Add files..." (the dialog
##   answered by the test), are put on the map by Import: the S file's
##   sources and the R file's receivers beside the record's own points (its
##   headers' coordinates are (0, 0): none), the map showing the whole
##   survey;
## - with no seismic file open, Import puts the survey on the map, and says
##   that no trace was matched.
##
## Seen to fail: with `marked` not marking the focused control, "Tab moves
## between the controls" found no focused control; with the status bar's
## joined colour left out, "the offset is drawn as joined" found no pixel in
## the accent colour; with the window titled "Join geometry" as before, "the
## window is titled  Join geometry###join"; with the log's old words ("Joined
## to"), "the log does not say the survey was imported"; with the import's
## files not loaded onto the map (`loadSurvey` left out of `startJoin`), "the
## S file is not on the map"; with Import disabled while no file is open (as
## before), "Import, no file open did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves join-*.png there, and with the example
## files present the private land record joined with its S, R and X files
## (`join-land-1.png`: the record beside its map, a trace hovered;
## `join-land-2.png`: the window with what the join did).

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/theme
import privatefiles
import utils/[fixtures, waiting]

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

proc drive(steps: seq[Step]; paths: seq[string]; dir: string; size = (1400, 1000);
    dialogs: DialogHook = nil) =
  var at = 0
  var started = false
  var wait = 0 # frames since the step began, at `since`
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
      if wait >= 3 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 600, since):
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(openPaths: paths, windowSize: size,
    theme: forceDark, userThemeDir: some(dir / "no-user-themes"),
    indexCacheDir: some(dir / "cache"), dialogs: dialogs, onFrame: onFrame))
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
    step("the window says import", noop, proc (f: FrameInfo): bool =
      doAssert f.windowName("join").endsWith("  Import survey###join"),
        "the window is titled " & f.windowName("join")
      true)
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
        doAssert "12 of 24 seismic traces matched the survey" in f.core.joinReport.words[1]
        doAssert f.core.survey.layers.len == 4, "a survey file is on the map twice: " &
          $f.core.survey.layers.len
        for w in f.core.joinReport.words:
          doAssert "join" notin w.toLowerAscii, "the words say join: " & w
        var started, ended = false
        for e in f.core.log:
          if e.text.startsWith("Importing the survey (") and "for stations" in e.text:
            started = true
          if e.text.startsWith("Survey imported for stations"):
            ended = true
            doAssert "join" notin e.text.toLowerAscii, e.text
        doAssert started and ended, "the log does not say the survey was imported"
        var titled = false
        for j in f.core.jobs.list:
          if j.spec.title.startsWith("Import the survey for "): titled = true
          doAssert "join" notin j.spec.title.toLowerAscii, "a job is titled " & j.spec.title
        doAssert titled, "no job is titled Import the survey for ...")
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

proc onTheMap(f: FrameInfo; sps: SpsPaths) =
  ## The S file's sources and the R file's receivers are on the map, which
  ## shows the whole survey.
  let (s, r) = (f.core.survey.findFile(sps.s), f.core.survey.findFile(sps.r))
  doAssert s >= 0, "the S file is not on the map"
  doAssert f.core.survey.layers[s].points[prSource].len == Shots and r >= 0 and
    f.core.survey.layers[r].points[prReceiver].len == Channels
  doAssert f.core.map.view.showsAll(f.core.map.limits), "the map does not show the survey"

proc importSteps(steps: var seq[Step]; name: string; done: proc (f: FrameInfo): bool) =
  ## File > Import > Survey..., Add files... (the test's dialog answers),
  ## then Import, until `done`.
  var frames = 0
  steps.add Step(name: "File > Import > Survey...", act: proc (f: FrameInfo) =
    f.click(f.markOf("menu.File").centre), done: proc (f: FrameInfo): bool =
    let item = f.markOf("menu.Import survey...")
    if item.size.x > 0: f.click(item.centre)
    elif f.markOf("menu.Import").size.x > 0 and f.index mod 10 == 0:
      f.click(f.markOf("menu.Import").centre)
    f.markOf("join.add").size.x > 0)
  steps.add Step(name: "Add files...", act: proc (f: FrameInfo) =
    f.click(f.markOf("join.add").centre), done: proc (f: FrameInfo): bool =
    inc frames
    frames > 8)
  steps.add Step(name: name, act: proc (f: FrameInfo) = f.click(f.markOf("join.run").centre),
    done: done)

proc importAdded() =
  ## Survey files not loaded before, added in the window and imported.
  withFixtures fx:
    let path = fx.stationsSegd()
    let sps = fx.surveySps()
    var steps: seq[Step]
    let answer = proc (kind: DialogKind; location: string): seq[string] =
      if kind == dkJoinFiles: @[sps.s, sps.r, sps.x] else: @[]
    steps.add Step(name: "the record, no survey file", act: proc (f: FrameInfo) = discard,
      done: proc (f: FrameInfo): bool =
      f.panel.laidOut and f.core.survey.findTraces(f.core.sessions[0].id) >= 0 and
        f.core.survey.layers.len == 1)
    importSteps(steps, "Import", proc (f: FrameInfo): bool =
      result = f.core.joinReport.serial > 0 and not f.core.importing and
        f.markOf("join.report").size.x > 0
      if result:
        doAssert f.core.joinReport.outcome == joJoined, $f.core.joinReport.words
        f.onTheMap(sps)
        doAssert f.core.survey.findTraces(f.core.sessions[0].id) >= 0, "the record's points"
        doAssert f.core.joinReport.words[0].startsWith("On the map: " & $Shots &
          " source points and " & $Channels & " receiver points"), f.core.joinReport.words[0])
    drive(steps, @[path], fx.dir, dialogs = answer)
    echo "tguijoin: added and imported, ", steps.len, " steps"

proc importNoFile() =
  ## No seismic file open: the survey is put on the map only.
  withFixtures fx:
    let sps = fx.surveySps()
    var steps: seq[Step]
    let answer = proc (kind: DialogKind; location: string): seq[string] =
      if kind == dkJoinFiles: @[sps.s, sps.r] else: @[]
    importSteps(steps, "Import, no file open", proc (f: FrameInfo): bool =
      result = f.core.joinReport.serial > 0 and not f.core.importing and
        f.markOf("join.report").size.x > 0
      if result:
        doAssert f.core.joinReport.outcome == joMapOnly, $f.core.joinReport.outcome
        f.onTheMap(sps)
        doAssert "No seismic file is open, so no trace was matched" in
          f.core.joinReport.words.join(" "), $f.core.joinReport.words)
    drive(steps, @[], fx.dir, dialogs = answer)
    echo "tguijoin: no file open, ", steps.len, " steps"

importAdded()
importNoFile()

# ------------------------------------------------- land survey: shots --
# With `VIEWSEG_SCREENSHOTS=<dir>` and the private files present (local
# only): the land record in the "Plot and map" layout, its S, R and X
# files imported (put on the map, the headers' coordinates replaced by the
# survey's), a trace hovered: its source and receiver lit on the map.

proc landSurvey(dir: string) =
  let survey = privateFiles("landSps", "landRps", "landXps")
  let record = privateFile("landSegd")
  let preset = currentSourcePath().parentDir.parentDir / "assets" / "layouts" / "Plot and map.nif"
  var stage = 0
  var wait = 0
  var since = getMonoTime() # when the stage began
  var saved = 0
  var loads = 0
  proc onFrame(f: FrameInfo) =
    inc wait
    template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
    let k = f.core.findPanel(MainPanel)
    case stage
    of 0:
      if f.index == 2:
        loads = f.core.layoutLoads
        f.apply Command(kind: ckLoadLayout, docPath: preset)
      if f.core.survey.layers.len >= 1 and f.core.panels[k].laidOut and
          f.core.tiles(k).len > 0 and f.core.layoutLoads > loads and wait > 30:
        var files: seq[JoinFile]
        for p in survey: files.add JoinFile(path: p, kind: jkSps)
        f.apply Command(kind: ckJoin, joinFile: f.core.sessions[0].id, joinFiles: files,
          joinOptions: JoinOptions(coordinates: hcReplace), joinUnits: JoinUnits(
          survey: suUsFeet, file: suUsFeet))
        next 1
    of 1:
      if f.core.joinReport.serial > 0 and not f.core.importing and
          f.core.tiles(k).len > 0 and f.core.tiles(k)[^1].joined.len > 0 and wait > 20:
        echo "tguijoin: land survey: ", f.core.joinReport.words.join(" ")
        let plot = f.markOf("plot.data")
        f.moveMouse(vec2(round(plot.pos.x + plot.size.x * 0.62), round(plot.pos.y +
          plot.size.y * 0.4)))
        next 2
    of 2:
      if wait == 30:
        if f.core.selection.hoverAt.len > 0 and f.savePng(dir / "join-land-1.png"):
          inc saved
        f.moveMouse(vec2(4, 4))
        next 3
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
      if wait == 30: f.moveMouse(f.markOf("statusbar").centre) # no tooltip over the window
      if wait == 40:
        if f.markOf("join.report").size.x > 0 and f.savePng(dir / "join-land-2.png"):
          inc saved
        f.stop()
    else: discard
    if overdue(f.index, 9000, since): f.stop()
  let tmp = getTempDir() / ("viewseg-joinshots-" & $getCurrentProcessId())
  let code = run(RunOptions(openPaths: @[record], windowSize: (1600, 1000),
    theme: forceDark, indexCacheDir: some(tmp),
    userThemeDir: some(tmp / "no-user-themes"), onFrame: onFrame))
  removeDir(tmp)
  doAssert code == 0 and saved == 2, "no screenshots of the land survey (stage " & $stage &
    ", saved " & $saved & ")"
  echo "tguijoin: saved ", dir / "join-land-1.png", " and -2.png"

if shots.len > 0 and privateFile("landSegd").len > 0 and
    privateFiles("landSps", "landRps", "landXps").len == 3:
  createDir(shots)
  landSurvey(shots)
