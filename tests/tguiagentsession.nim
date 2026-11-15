## What an agent does through agent control is for the session only, in the
## running program, headless, across a restart:
##
## - a first run with its settings in a folder of its own opens a file from
##   the command line (the user's); then an agent, a client on a thread of
##   its own through the socket, changes the display mode and the gain,
##   sorts, chooses the display header's rows and shows a file of another
##   folder: the plot shows all of it (`state` says so, and the program
##   holds it), and the session's recent files have the agent's file; the
##   settings kept are as before the agent connected. Then the user clicks
##   another display mode in the strip, and the run quits: the settings file
##   holds the user's mode and, for everything else, what it held before the
##   agent connected (the gain, the sort, the display header, the recent
##   files and folders); the session log holds the agent's commands;
## - a second run lists only the user's file on its start screen; a click
##   opens it as the user left the plot (the user's mode, gain, order and
##   display header). The same changes as the agent's, made through the
##   windows, and the agent's file shown from Files, are saved when it quits.
##
## Seen to fail: with `keeps` true for agents, "the agent changed the
## settings kept"; the same with the command tool not marking its commands
## as an agent's, and with the show's origin not carried to the end of its
## open (`adopt` taking every open as a window's); with `ckDisplay` keeping
## the whole display, "the agent's gain was saved: normalized" (through the
## user's click on a mode); with `keeps` false for windows, "the user's file
## is not among the recent files kept: @[]".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[json, math, options, os, strutils]
import viewSEG/core/[geometry, settingsnif, state]
import viewSEG/ui/imgui/[app, symbols]
import utils/[agentclient, fixtures]

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc laidOut(f: FrameInfo): bool =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  p.layers.len > 0 and p.laidOut and f.markOf("plot.data").size.x > 0

proc shownDisplay(f: FrameInfo): DisplaySettings =
  f.core.panels[f.core.findPanel(MainPanel)].layers[0].display

proc readBack(file: string): Settings =
  ## The settings in `file`, as the next run reads them.
  var problems: seq[string]
  result = readSettings(readFile(file), file.extractFilename, Settings(), problems)
  doAssert problems.len == 0, $problems

const
  AgentOrder = @[SortKey(field: hfChannel, descending: true)]
  AgentHeader = @[hfChannel, hfRecord]

# ---------------------------------------------------- the agent's thread --

type Scenario = tuple[socket, file: string]

var results: Channel[(string, string)] ## what the agent found, for the main thread

proc agent(s: Scenario) {.thread.} =
  ## The client: ("problem", why) ends it early, ("done", the panel's
  ## state) at the end.
  template fail(why: string) =
    results.send(("problem", why))
    return
  template check(r: JsonNode; what: string) =
    if r.failed: fail(what & ": " & (if r == nil: "no answer" else: $r))
  var c = connectAgent(s.socket)
  for i in 0 ..< 200:
    if c.fd < 0:
      sleep 50
      c = connectAgent(s.socket)
  if c.fd < 0: fail("cannot connect to " & s.socket)
  if c.initialize("test agent") == nil: fail("the agent's first call: no answer")
  check(c.call("command", %*{"kind": "display", "display": {"mode": "density",
    "gain": "normalized"}}), "display")
  check(c.call("command", %*{"kind": "sort", "order": [{"field": "channel",
    "descending": true}]}), "sort")
  check(c.call("command", %*{"kind": "display header", "header": {"auto": false,
    "fields": ["channel", "FFID"]}}), "display header")
  check(c.call("wait", %*{"timeout": 30}), "wait")
  check(c.call("command", %*{"kind": "show file", "path": s.file, "listFolder": true}),
    "show file")
  let r = c.call("wait", %*{"timeout": 30})
  check(r, "wait after show file")
  if not parseJson(r.text)["idle"].getBool: fail("not idle after the show: " & r.text)
  let st = c.call("state", %*{"parts": ["panels"]})
  check(st, "state")
  c.close()
  results.send(("done", $parseJson(st.text)["panels"][0]))

withFixtures fx:
  let mine = fx.surveySegy()
  let folder = fx.dir / "agent"
  createDir(folder)
  let theirs = folder / "theirs.sgy"
  copyFile(fx.longSpreadSegy(), theirs)
  let config = fx.dir / "config"
  let logs = fx.dir / "logs"
  let socket = fx.dir / "agent.sock"
  let settingsFile = config / SettingsFileName
  var before: Settings # kept when the agent connected

  block withAnAgent:
    results.open()
    var thread: Thread[Scenario]
    var stage = 0
    var wait = 0
    var at: Vec2
    var problem = ""
    proc onFrame(f: FrameInfo) =
      inc wait
      template fail(why: string) =
        problem = why
        f.stop()
      case stage
      of 0: # the user's file shown: the agent connects
        if f.laidOut and wait > 3:
          before = f.core.keptSettings
          doAssert before.recentFiles == @[mine],
            "the user's file is not among the recent files kept: " & $before.recentFiles
          createThread(thread, agent, (socket, theirs))
          (stage, wait) = (1, 0)
      of 1:
        let (ok, msg) = results.tryRecv()
        if ok and msg[0] == "problem": fail(msg[1])
        elif ok and msg[0] == "done":
          # what is shown is the agent's
          let p = parseJson(msg[1])
          doAssert p["file"]["path"].getStr == theirs, $p["file"]
          doAssert p["display"]["mode"].getStr == "density" and
            p["display"]["gain"].getStr == "normalized", $p["display"]
          doAssert p["order"] == %*[{"field": "channel", "descending": true}], $p["order"]
          doAssert p["header"] == %*{"auto": false, "fields": ["channel", "FFID"]}, $p["header"]
          doAssert f.shownDisplay.mode == dmDensity and f.shownDisplay.gain == dgNormalized
          doAssert f.core.settings.recentFiles[0] == theirs and
            f.core.settings.plot.order == AgentOrder, "the session does not hold the agent's"
          doAssert settingsDocument(f.core.keptSettings) == settingsDocument(before),
            "the agent changed the settings kept"
          # the user: another mode, with a real click in the strip
          at = f.markOf("plot." & $syWiggleDensity).centre
          doAssert at.x > 0, "no mode button"
          f.moveMouse(at)
          (stage, wait) = (2, 0)
        elif wait > 3000: fail("the agent did not finish")
      of 2:
        if wait == 2: f.pressMouse(at, true)
        if wait == 3: f.pressMouse(at, false)
        if f.shownDisplay.mode == dmWiggleDensity:
          doAssert f.shownDisplay.gain == dgNormalized, "the click changed the gain"
          f.stop()
          stage = 3
        elif wait > 60: fail("the click did not change the mode")
      else: discard
    let code = run(RunOptions(windowSize: (1600, 1000), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      persist: true, configDir: some(config), logDir: some(logs), openPaths: @[mine],
      agent: true, agentSocket: socket, maxFrames: 4000, onFrame: onFrame))
    joinThread(thread)
    results.close()
    doAssert code == 0 and problem.len == 0, problem
    doAssert stage == 3, "the first run stopped at stage " & $stage
  let first = readBack(settingsFile)
  doAssert first.plot.display.mode == dmWiggleDensity, "the user's mode was not saved: " &
    $first.plot.display.mode
  doAssert first.plot.display.gain == before.plot.display.gain,
    "the agent's gain was saved: " & $first.plot.display.gain
  doAssert first.plot.order == before.plot.order, "the agent's sort was saved"
  doAssert first.plot.header == before.plot.header, "the agent's display header was saved"
  doAssert theirs notin first.recentFiles, "the agent's file is in the recent files"
  doAssert first.recentFiles == before.recentFiles and
    first.recentFolders == before.recentFolders, $first.recentFiles & " " & $first.recentFolders
  var expected = before
  expected.plot.display.mode = dmWiggleDensity
  expected.window = first.window # where the window was: the user's
  doAssert settingsDocument(first) == settingsDocument(expected),
    "the settings saved are not the user's: " & settingsDocument(first)
  var logged = ""
  for kind, f in walkDir(logs):
    if f.extractFilename.startsWith(SessionLogPrefix): logged.add readFile(f)
  doAssert "test agent 1 (agent 1): command {\"kind\":\"display\"" in logged and
    "\"kind\":\"show file\"" in logged, "the session log lacks the agent's commands"
  echo "tguiagentsession: the agent's display, sort, header and file not saved; the user's ",
    "mode saved"

  block byHand:
    var stage = 0
    var wait = 0
    var at: Vec2
    proc onFrame(f: FrameInfo) =
      inc wait
      case stage
      of 0: # the start screen lists the user's file only
        if wait == 3:
          doAssert f.markOf("plot.recent 0").size.x > 0, "no recent file on the start screen"
          doAssert f.markOf("plot.recent 1").size.x <= 0 and
            f.markOf("plot.recent folder 1").size.x <= 0,
            "the start screen lists what the agent opened"
          at = f.markOf("plot.recent 0").centre
          f.moveMouse(at)
        if wait == 5: f.pressMouse(at, true)
        if wait == 6:
          f.pressMouse(at, false)
          (stage, wait) = (1, 0)
      of 1: # as the user left the plot
        if f.laidOut:
          doAssert f.core.sessions[0].path == mine
          let p = f.core.panels[f.core.findPanel(MainPanel)]
          doAssert p.layers[0].display.mode == dmWiggleDensity and
            p.layers[0].display.gain == before.plot.display.gain, $p.layers[0].display
          doAssert p.layers[0].order == before.plot.order and p.header == before.plot.header
          # the agent's changes, made through the windows
          var d = p.layers[0].display
          d.mode = dmDensity
          d.gain = dgNormalized
          f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
          f.apply Command(kind: ckSort, panel: MainPanel, order: AgentOrder)
          f.apply Command(kind: ckHeader, panel: MainPanel,
            header: HeaderChoice(auto: false, fields: AgentHeader))
          f.apply Command(kind: ckShowFile, panel: MainPanel, path: theirs, listFolder: true)
          (stage, wait) = (2, 0)
        doAssert wait < 300, "the recent file did not open"
      of 2:
        if f.core.sessions.len == 1 and f.core.sessions[0].path == theirs and f.laidOut:
          f.stop()
          stage = 3
        doAssert wait < 300, "the file was not shown"
      else: discard
    doAssert run(RunOptions(windowSize: (1600, 1000), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      persist: true, configDir: some(config), logDir: some(logs), maxFrames: 2000,
      onFrame: onFrame)) == 0
    doAssert stage == 3, "the second run stopped at stage " & $stage
  let second = readBack(settingsFile)
  doAssert second.plot.display.mode == dmDensity and
    second.plot.display.gain == dgNormalized, $second.plot.display
  doAssert second.plot.order == AgentOrder and second.plot.header.fields == AgentHeader and
    not second.plot.header.auto, $second.plot
  doAssert second.recentFiles == @[theirs, mine] and folder in second.recentFolders,
    $second.recentFiles & " " & $second.recentFolders
  echo "tguiagentsession: the same changes through the windows saved; ok"
