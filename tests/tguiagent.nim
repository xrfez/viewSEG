## Agent control in the running program, headless:
##
## - off by default: a run without it has no listening socket and no
##   server; File > Agent control's way (`setAgentControl`) turns it on (the
##   socket appears, the status bar shows the sign, Messages says so) and
##   off (the socket is gone);
## - an agent, a client on a thread of its own, opens a fixture, draws it as
##   wiggles at gain None without fills, sorts by channel descending, selects
##   the trace at position 3, kills it (the selected traces), and takes
##   screenshots of the plot before and after: in the PNG, the killed
##   trace's band (within 0.4 of a trace spacing of its baseline) holds
##   nothing but the paper, and it held ink before; `state` says it is
##   killed, `headers` gives its channel; turned time across, `state` says
##   so and shows the same view, and in the plot's PNG the killed trace's
##   band is a row of paper among inked ones; a command that writes a file
##   is refused, and the whole window can be taken;
## - the agent names the fixture relative to the program's folder; it hides
##   the map's receivers (the Map window's picture changes) and halves the
##   map's scale (the map takes the view, as a zoom of the user's); `state`
##   gives the Headers window's tab and the facts of the file shown, and the
##   Headers window can be taken alone;
## - while it is connected the status bar shows "agent connected", and
##   Messages holds a line for each of its commands and for its first call
##   of each other tool; the file is not changed;
## - with every trace hidden by the trace filter, `wait` settles, `state`
##   says the plot has nothing to draw, and a screenshot of the plot is
##   refused with what the window says, not the last picture drawn;
## - the sign comes first in the status bar: in view at 1280 pixels with
##   every readout field chosen;
## - the sign names an agent's last call: "agent: command show file" in the
##   warning colour while it is connected; once it has gone (as a shell's
##   `--mcp-call` does at once), "agent: state" stays, halfway to dim, for
##   `SignLinger` after the call, then "agents: on" again, dim.
##
## Seen to fail: with `serve` not called in the frame loop, "the agent did
## not finish"; with the kill applied as a reversal, "the killed trace's
## band: 1153 pixels of ink"; with no trace named to the kill (the
## selection not taken), "kill: ... ignored"; with the status bar's sign
## left out, "no sign while on"; with File > Agent control's way not
## starting the server, "no listening socket after turning it on"; with the
## map's view applied in `core` alone (no `showMapView`), "the map's view was
## not taken"; with the sign drawn after the readout, "the sign is out of
## view: it spans 2632.0 to 2715.0 in a bar 1280.0 wide". With "headers"
## left out of the screenshot's targets, "screenshot of the Headers window:
## ... window: one of window, plot, ...". With the plot's image drawn time
## down after the agent turned it, "turned: the killed trace's row 776"
## (pixels of ink). With the sign not lingering (`lingering` never set),
## "no lingering sign after the agent went". With `pictureOf` not knowing a
## panel with no trace to draw, "not idle with every trace hidden: ... not
## drawn yet"; with the plot's last image given whatever the window shows,
## "a screenshot of the plot with every trace hidden".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[base64, json, math, monotimes, options, os, posix, sequtils, strutils, tables, times]
import sdl3_nim
import viewSEG/core/[geometry, state]
import viewSEG/view/[plotink, theme]
import viewSEG/ui/imgui/app
import viewSEG/remote/control
import utils/[agentclient, fixtures, waiting]

const
  WaitSeconds = Patience.inSeconds ## the agent's `wait` calls: as long as any test waits
  WaitAnswer = Patience * 2        ## and how long it waits for their answers

proc listeningSockets(): int =
  ## Unix-domain sockets this process listens on (Linux: /proc).
  var mine: seq[string]
  for kind, link in walkDir("/proc/self/fd"):
    try:
      let target = expandSymlink(link)
      if target.startsWith("socket:["): mine.add target["socket:[".len .. ^2]
    except OSError:
      discard
  for line in lines("/proc/net/unix"):
    let parts = line.splitWhitespace
    # Num RefCount Protocol Flags Type St Inode [Path]; Flags 00010000: listening
    if parts.len >= 7 and parts[3] == "00010000" and parts[6] in mine: inc result

func decodedPng(png: string): (seq[Rgba], int, int) =
  {.cast(noSideEffect).}:
    let io = SDL_IOFromConstMem(addr png[0], csize_t(png.len))
    let loaded = SDL_LoadPNG_IO(io, true)
    doAssert loaded != nil, "not a PNG: " & $SDL_GetError()
    let s = SDL_ConvertSurface(loaded, SDL_PIXELFORMAT_RGBA32)
    SDL_DestroySurface(loaded)
    var pixels = newSeq[Rgba](s.w * s.h)
    for y in 0 ..< s.h.int:
      let row = cast[ptr UncheckedArray[uint8]](cast[int](s.pixels) + y * s.pitch.int)
      for x in 0 ..< s.w.int:
        pixels[y * s.w + x] = Rgba(r: row[4 * x], g: row[4 * x + 1], b: row[4 * x + 2], a: 255)
    result = (pixels, s.w.int, s.h.int)
    SDL_DestroySurface(s)

func close(a, b: Rgba): bool =
  abs(a.r.int - b.r.int) <= 6 and abs(a.g.int - b.g.int) <= 6 and abs(a.b.int - b.b.int) <= 6

# ---------------------------------------------------- the agent's thread --

proc connected(c: var AgentClient; socket: string): bool =
  ## Connects `c` to `socket` unless it is; whether it is now.
  if c.fd < 0: c = connectAgent(socket)
  c.fd >= 0

type Scenario = tuple[socket, fixture: string]

var results: Channel[(string, string)] ## what the agent found, for the main thread

proc agent(s: Scenario) {.thread.} =
  ## The client: each step's result goes to `results`; ("problem", why)
  ## ends it early, ("done", "") at the end.
  template fail(why: string) =
    results.send(("problem", why))
    return
  template check(r: JsonNode; what: string) =
    if r.failed: fail(what & ": " & (if r == nil: "no answer" else: $r))
  var c = connectAgent(s.socket)
  if not waitUntil(c.connected(s.socket)):
    fail("cannot connect to " & s.socket)
  let init = c.initialize("test agent")
  if init == nil: fail("the agent's first call: no answer")
  if c.request("tools/list", nil){"result"}{"tools"}.len != 5: fail("not five tools")
  results.send(("connected", ""))
  var r = c.call("command", %*{"kind": "show file", "path": s.fixture})
  check(r, "show file")
  check(c.call("wait", %*{"timeout": WaitSeconds}, WaitAnswer), "wait")
  check(c.call("command", %*{"kind": "display", "display": {"mode": "wiggle", "fills": [],
    "overlap": 0.5, "gain": "none"}}), "display")
  check(c.call("command", %*{"kind": "sort", "order": [{"field": "channel",
    "descending": true}]}), "sort")
  r = c.call("wait", %*{"timeout": WaitSeconds}, WaitAnswer)
  check(r, "wait after sort")
  if not parseJson(r.text)["idle"].getBool: fail("not idle after the sort: " & r.text)
  r = c.call("state", %*{"parts": ["panels"]})
  check(r, "state")
  let panel = parseJson(r.text)["panels"][0]
  let trace = panel["positions"][3].getInt
  let id = panel["file"]["firstTrace"].getInt + trace
  check(c.call("command", %*{"kind": "select", "traces": [id], "mode": "replace"}), "select")
  check(c.call("wait", %*{"timeout": WaitSeconds}, WaitAnswer), "wait after select")
  r = c.call("screenshot", %*{"window": "plot", "maxSize": 4096})
  check(r, "screenshot before")
  results.send(("before", r["content"][0]["data"].getStr))
  check(c.call("command", %*{"kind": "edit traces", "edit": "killed"}), "kill")
  r = c.call("wait", %*{"timeout": WaitSeconds}, WaitAnswer)
  check(r, "wait after kill")
  if not parseJson(r.text)["idle"].getBool: fail("not idle after the kill: " & r.text)
  r = c.call("screenshot", %*{"window": "plot", "maxSize": 4096})
  check(r, "screenshot after")
  results.send(("after", r["content"][0]["data"].getStr))
  r = c.call("state", %*{"parts": ["panels"]})
  check(r, "state after kill")
  let after = parseJson(r.text)["panels"][0]
  results.send(("view", $after["view"]))
  results.send(("killed", $after["killed"] & " " & $trace))
  r = c.call("headers", %*{"panel": 1, "position": 3})
  check(r, "headers")
  results.send(("channel", $parseJson(r.text)["keys"]["channel"].getFloat))
  # the plot turned, time across: `state` says so, the view stays, the
  # picture is turned
  check(c.call("command", %*{"kind": "display", "display": {"orientation": "time across"}}),
    "turn")
  r = c.call("wait", %*{"timeout": WaitSeconds}, WaitAnswer)
  check(r, "wait after the turn")
  r = c.call("state", %*{"parts": ["panels"]})
  check(r, "state after the turn")
  let turned = parseJson(r.text)["panels"][0]
  results.send(("turned", turned["display"]["orientation"].getStr & "|" & $turned["view"]))
  r = c.call("screenshot", %*{"window": "plot", "maxSize": 4096})
  check(r, "screenshot turned")
  results.send(("turned shot", r["content"][0]["data"].getStr))
  r = c.call("command", %*{"kind": "export messages", "docPath": s.fixture & ".txt"})
  if not r.failed: fail("an export was carried out")
  r = c.call("screenshot")
  check(r, "screenshot of the window")
  results.send(("window", r["content"][1]["text"].getStr))
  # the map: its state, a layer hidden, a view shown, in pictures of the Map window
  r = c.call("state", %*{"parts": ["map", "program"]})
  check(r, "state of the map")
  let st = parseJson(r.text)
  results.send(("program", st["program"]["folder"].getStr))
  var key = newJNull()
  for l in st["map"]["layers"]:
    if l["mapLayer"]["role"].getStr == "receiver": key = l["mapLayer"]
  if key.kind != JObject: fail("no receivers on the map: " & $st["map"])
  r = c.call("screenshot", %*{"window": "map", "maxSize": 4096})
  check(r, "screenshot of the map")
  results.send(("map shown", r["content"][0]["data"].getStr))
  check(c.call("command", %*{"kind": "map layer", "mapLayer": key, "shown": false}), "hide")
  check(c.call("wait", %*{"timeout": WaitSeconds}, WaitAnswer), "wait after hiding")
  r = c.call("screenshot", %*{"window": "map", "maxSize": 4096})
  check(r, "screenshot of the map without its receivers")
  results.send(("map hidden", r["content"][0]["data"].getStr))
  let asked = st["map"]["view"]["perPixel"].getFloat / 2
  check(c.call("command", %*{"kind": "map view", "mapView": {"perPixel": asked}}), "map view")
  check(c.call("wait", %*{"timeout": WaitSeconds}, WaitAnswer), "wait after the map view")
  r = c.call("state", %*{"parts": ["map"]})
  check(r, "state of the map after its view")
  results.send(("perPixel", $parseJson(r.text)["map"]["view"]["perPixel"].getFloat & " " &
    $asked))
  # the Headers window: its part of `state`, and its picture
  r = c.call("state", %*{"parts": ["headers"]})
  check(r, "state of the Headers window")
  let hs = parseJson(r.text)["headers"]
  if hs{"file"}.kind != JObject: fail("the Headers window has no file: " & $hs)
  results.send(("headers", hs["tab"].getStr & " " & hs["file"]["summary"]["standard"].getStr &
    " " & $hs["file"]["summary"]["traceCount"].getInt))
  r = c.call("screenshot", %*{"window": "headers", "maxSize": 4096})
  check(r, "screenshot of the Headers window")
  results.send(("headers shot", r["content"][1]["text"].getStr))
  # every trace hidden by the trace filter: `wait` settles, `state` says
  # there is nothing to draw, and the plot's screenshot says the window
  # shows no picture instead of giving the last one drawn
  check(c.call("command", %*{"kind": "trace filter", "filter": {"seismic": false,
    "auxiliary": true}}), "hide every trace")
  r = c.call("wait", %*{"timeout": 10})
  check(r, "wait with every trace hidden")
  if not parseJson(r.text)["idle"].getBool: fail("not idle with every trace hidden: " & r.text)
  r = c.call("state", %*{"parts": ["panels"]})
  check(r, "state with every trace hidden")
  results.send(("hidden picture", parseJson(r.text)["panels"][0]["picture"].getStr))
  r = c.call("screenshot", %*{"window": "plot", "maxSize": 4096})
  if r == nil or not r.failed: fail("a screenshot of the plot with every trace hidden")
  results.send(("hidden shot", r.text))
  c.close()
  results.send(("done", ""))

var calls: Channel[string] ## the short-lived agent's steps, for the main thread
var seen: Channel[bool] ## the main thread's word to it

proc shortLived(s: Scenario) {.thread.} =
  ## An agent that connects, gives a command, and while still connected says
  ## so and waits for the main thread's word; then a `state` call, and it
  ## disconnects at once, as `--mcp-call` does.
  var c = connectAgent(s.socket)
  if not waitUntil(c.connected(s.socket)):
    calls.send("problem: cannot connect")
    return
  if c.initialize("short agent") == nil or
      c.call("command", %*{"kind": "show file", "path": s.fixture}).failed:
    calls.send("problem: the command failed")
    return
  calls.send("connected")
  discard seen.recv() # the main thread saw the sign
  if c.call("state", %*{"parts": ["program"]}).failed:
    calls.send("problem: state failed")
    return
  c.close()
  calls.send("gone")

withFixtures fx:
  let path = fx.surveySegy()
  let before = (readFile(path), getLastModificationTime(path))
  let socket = fx.dir / "agent.sock"

  block offByDefault:
    var frame = 0
    var wait = 0 # frames since the stage began, at `since`
    var since = getMonoTime()
    var problem = ""
    var stage = 0
    proc onFrame(f: FrameInfo) =
      inc frame
      inc wait
      template fail(why: string) =
        problem = why
        f.stop()
      template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
      # The server starts and stops on threads of its own: stages 1 and 2
      # wait for what they check, and fail with what still does not hold.
      template waitFor(why: string) =
        if overdue(wait, 600, since): fail(why)
      if stage == 0 and frame == 10:
        if f.agentControl.running: fail("agent control is on by default")
        elif listeningSockets() != 0: fail("a listening socket by default")
        elif fileExists(socket) or symlinkExists(socket): fail("a socket by default")
        elif f.markOf("status.agent").size.x > 0: fail("a sign while off")
        else:
          f.setAgentControl(true)
          next 1
      elif stage == 1 and wait > 5:
        if f.markOf("status.agent connected").size.x > 0: fail("connected, with nobody")
        elif listeningSockets() != 1: waitFor("no listening socket after turning it on")
        elif f.markOf("status.agent").size.x <= 0: waitFor("no sign while on")
        elif not f.messages.anyIt("Agent control is on" in it.text): waitFor("not said")
        else:
          f.setAgentControl(false)
          next 2
      elif stage == 2 and wait > 5:
        if listeningSockets() != 0 or f.agentControl.running: waitFor("still listening")
        elif fileExists(socket) or symlinkExists(socket): waitFor("the socket is still there")
        elif f.markOf("status.agent").size.x > 0: waitFor("a sign while off")
        else: f.stop()
    let code = run(RunOptions(windowSize: (1200, 800), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      agentSocket: socket, onFrame: onFrame))
    doAssert code == 0 and problem.len == 0, problem
    echo "tguiagent: off by default, on and off from the menu's way"

  block theSignInView:
    # a full status bar at 1280 pixels: every readout field (wider than the
    # window); the sign comes first, so it is in view
    var frame = 0
    let since = getMonoTime()
    var problem = ""
    proc onFrame(f: FrameInfo) =
      inc frame
      if frame == 3:
        var s = f.core.settings
        s.readout.setLen 0
        for x in ReadoutField: s.readout.add x
        f.apply Command(kind: ckSettings, settings: s)
      elif frame >= 10:
        # the sign once the server, started on a thread of its own, listens
        let sign = f.markOf("status.agent")
        let bar = f.markOf("statusbar")
        if sign.size.x <= 0:
          if overdue(frame, 10, since):
            problem = "no sign"
            f.stop()
        else:
          if bar.size.x <= 0: problem = "no status bar"
          elif sign.pos.x < bar.pos.x or sign.pos.x + sign.size.x > bar.pos.x + bar.size.x:
            problem = "the sign is out of view: it spans " & $sign.pos.x & " to " &
              $(sign.pos.x + sign.size.x) & " in a bar " & $bar.size.x & " wide"
          f.stop()
    let code = run(RunOptions(windowSize: (1280, 800), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      agent: true, agentSocket: socket, onFrame: onFrame))
    doAssert code == 0 and problem.len == 0, problem
    echo "tguiagent: the sign in view in a full status bar at 1280 pixels"

  block theSignLingers:
    calls.open()
    seen.open()
    var thread: Thread[Scenario]
    var started = false
    var stage = 0 # 0 connecting, 1 connected, 2 gone: lingering, 3 back to "agents: on"
    var problem = ""
    let since = getMonoTime()
    var gone, back: MonoTime # when the agent went, and when the sign said so
    proc ink(f: FrameInfo): Rgba =
      ## The sign's colour: of its pixels, the one farthest from its
      ## background (the commonest), the core of a stroke.
      let shot = f.readFrame()
      let r = f.markOf("status.agent")
      var counts: CountTable[uint32]
      template key(c: Rgba): uint32 = (c.r.uint32 shl 16) or (c.g.uint32 shl 8) or c.b.uint32
      for y in int(r.pos.y) ..< int(r.pos.y + r.size.y):
        for x in int(r.pos.x) ..< int(r.pos.x + r.size.x):
          counts.inc key(shot[y * f.width + x])
      let bg = counts.largest[0]
      let back = Rgba(r: uint8(bg shr 16), g: uint8((bg shr 8) and 255), b: uint8(bg and 255))
      var far = -1
      for y in int(r.pos.y) ..< int(r.pos.y + r.size.y):
        for x in int(r.pos.x) ..< int(r.pos.x + r.size.x):
          let c = shot[y * f.width + x]
          if distance(c, back) > far: (result, far) = (c, distance(c, back))
    proc nearest(c: Rgba; choices: openArray[Rgba]): int =
      for i, x in choices:
        if distance(c, x) < distance(c, choices[result]): result = i
    proc onFrame(f: FrameInfo) =
      template fail(why: string) =
        problem = why
        if stage < 2: seen.send(false) # (the agent waits for it)
        stage = 3
        f.stop()
      if not started:
        createThread(thread, shortLived, (socket, path))
        started = true
      let (ok, msg) = calls.tryRecv()
      if ok and msg.startsWith("problem"): fail(msg)
      let warning = f.theme.roles[rlWarning]
      let dim = f.theme.roles[rlTextDim]
      let halfway = mix(warning, dim, 0.5)
      let colours = [warning, halfway, dim]
      case stage
      of 0:
        if ok and msg == "connected": stage = 1
      of 1:
        # (the command's answer came before the agent said it is connected)
        if f.markOf("status.agent connected").size.x > 0 and
            f.agentControl.lastCall == "command show file" and
            f.ink.nearest(colours) == 0:
          seen.send(true)
          stage = 2
      of 2:
        if ok and msg == "gone": gone = getMonoTime()
        if gone != MonoTime() and f.agentControl.clients == 0:
          if f.markOf("status.agent lingering").size.x > 0:
            if f.agentControl.lastCall != "state": fail("the last call: " &
              f.agentControl.lastCall)
            elif f.markOf("status.agent connected").size.x > 0: fail("connected, and lingering")
            elif f.ink.nearest(colours) != 1:
              fail("the lingering sign is not halfway to dim: " & $f.ink)
          elif getMonoTime() - gone < initDuration(seconds = 1):
            fail("no lingering sign after the agent went")
          else:
            back = getMonoTime()
            if f.ink.nearest(colours) != 2: fail("the sign is not dim again: " & $f.ink)
            else: stage = 3
      else: f.stop()
      if stage < 3 and getMonoTime() - since > Patience:
        fail("stopped at stage " & $stage & ": the last call " & f.agentControl.lastCall &
          ", " & $f.agentControl.clients & " connected, the sign " & $f.ink & " (warning " &
          $warning & ", dim " & $dim & ")")
    let code = run(RunOptions(windowSize: (1280, 800), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      agent: true, agentSocket: socket, onFrame: onFrame))
    joinThread(thread)
    calls.close()
    seen.close()
    doAssert code == 0 and problem.len == 0, problem
    let lingered = (back - gone).inMilliseconds
    # (the call was answered before the agent said it had gone)
    doAssert lingered >= SignLinger.inMilliseconds - 1000, "it lingered " & $lingered & " ms"
    echo "tguiagent: the sign said the agent's last call for ", lingered,
      " ms after it went"

  block anAgentKillsATrace:
    results.open()
    var thread: Thread[Scenario]
    var frame = 0
    let since = getMonoTime()
    var started, connected, signSeen, done = false
    var problem = ""
    var got: seq[(string, string)]
    var ink: PlotInk
    var lines, commands = 0
    proc onFrame(f: FrameInfo) =
      inc frame
      if not started:
        createThread(thread, agent, (socket, relativePath(path, getAppDir())))
        started = true
      var more = true
      while more:
        let (ok, msg) = results.tryRecv()
        more = ok
        if ok:
          got.add msg
          case msg[0]
          of "connected": connected = true
          of "problem":
            problem = msg[1]
            f.stop()
          of "done":
            done = true
            for m in f.messages:
              if "test agent 1 (agent " in m.text: inc lines
              if "test agent 1 (agent 1): command {" in m.text: inc commands
            ink = plotInk(f.theme, f.core.panels[0].layers[0].display)
            f.stop()
          else: discard
      if connected and not done and f.markOf("status.agent connected").size.x > 0:
        signSeen = true
      if getMonoTime() - since > Patience * 3: # frames are fast under Xvfb
        problem = "the agent did not finish"
        f.stop()
    # the agent names the fixture relative to the program's folder, as one in a
    # container must (it cannot know the program's own paths)
    let relative = relativePath(path, getAppDir())
    doAssert not relative.isAbsolute
    let code = run(RunOptions(windowSize: (1600, 1000), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      agent: true, agentSocket: socket, onFrame: onFrame))
    joinThread(thread)
    results.close()
    doAssert code == 0, "run() exit code " & $code
    doAssert problem.len == 0, problem
    doAssert done, "the agent did not finish"
    doAssert signSeen, "no sign of the agent in the status bar"
    # every command; the calls that change nothing once each (the rest so
    # soon after are counted, not written)
    doAssert commands == 10, "Messages holds " & $commands & " of the agent's 10 commands"
    doAssert lines >= 12, "Messages holds " & $lines & " lines of the agent's calls"
    var found: Table[string, string]
    for (k, v) in got: found[k] = v
    let view = parseJson(found["view"])
    let (lo, hi) = (view["traces"]["lo"].getFloat, view["traces"]["hi"].getFloat)

    proc inked(png: string): (int, int) =
      ## Pixels of position 3's band that are not the paper, of those looked at.
      let (pixels, w, h) = decodedPng(decode(png))
      let ppt = float(w) / (hi - lo)
      let centre = (3.0 - lo) * ppt - 0.5
      for y in 0 ..< h:
        for x in int(ceil(centre - 0.4 * ppt)) .. int(floor(centre + 0.4 * ppt)):
          inc result[1]
          if not close(pixels[y * w + x], ink.background): inc result[0]

    let (was, seen) = inked(found["before"])
    let (now, _) = inked(found["after"])
    echo "tguiagent: position 3's band: ", was, " of ", seen, " pixels inked before the kill, ",
      now, " after"
    doAssert seen > 1000 and was > 50, "the trace was blank before: " & $was
    doAssert now == 0, "the killed trace's band: " & $now & " pixels of ink"
    # turned: the same view, time across, the killed trace's band a row
    let parts = found["turned"].split('|')
    doAssert parts[0] == "time across", found["turned"]
    let tv = parseJson(parts[1])
    doAssert tv["traces"] == view["traces"] and tv["timeMs"] == view["timeMs"],
      "the turn moved the view: " & parts[1] & " was " & $view
    proc inkedRows(png: string; position: float): (int, int) =
      ## Pixels of `position`'s band, a row when time is across, that are not
      ## the paper, of those looked at.
      let (pixels, w, h) = decodedPng(decode(png))
      let ppt = float(h) / (hi - lo)
      let centre = (position - lo) * ppt - 0.5
      for y in int(ceil(centre - 0.4 * ppt)) .. int(floor(centre + 0.4 * ppt)):
        for x in 0 ..< w:
          inc result[1]
          if not close(pixels[y * w + x], ink.background): inc result[0]
    let (killedRow, rowSeen) = inkedRows(found["turned shot"], 3)
    let (nextRow, _) = inkedRows(found["turned shot"], 4)
    echo "tguiagent: turned, position 3's row: ", killedRow, " of ", rowSeen,
      " pixels inked, position 4's: ", nextRow
    doAssert rowSeen > 1000 and killedRow == 0 and nextRow > 50,
      "turned: the killed trace's row " & $killedRow & ", the next one's " & $nextRow
    let killed = found["killed"].splitWhitespace
    doAssert parseJson(killed[0]) == %*[parseInt(killed[1])], found["killed"]
    doAssert parseFloat(found["channel"]) == float(Channels - 3), found["channel"]
    doAssert "window: " in found["window"], found["window"]
    doAssert found["program"] == getAppDir(), found["program"]
    let (shownMap, sw, sh) = decodedPng(decode(found["map shown"]))
    let (hiddenMap, hw, hh) = decodedPng(decode(found["map hidden"]))
    doAssert (sw, sh) == (hw, hh) and sw > 100 and sh > 100, $(sw, sh, hw, hh)
    var gone = 0
    for i in 0 ..< shownMap.len:
      if not close(shownMap[i], hiddenMap[i]): inc gone
    echo "tguiagent: the map's receivers hidden: ", gone, " pixels changed"
    doAssert gone > 20, "hiding the receivers changed " & $gone & " pixels of the map"
    let pp = found["perPixel"].splitWhitespace
    doAssert abs(parseFloat(pp[0]) / parseFloat(pp[1]) - 1) < 1e-6,
      "the map's view was not taken: " & found["perPixel"]
    doAssert found["headers"] == "Summary SEG-Y " & $SurveyTraces, found["headers"]
    let size = found["headers shot"].splitWhitespace # "headers: W x H pixels"
    doAssert size[0] == "headers:" and parseInt(size[1]) > 100 and parseInt(size[3]) > 100,
      found["headers shot"]
    doAssert found["hidden picture"] == "nothing to draw", found["hidden picture"]
    doAssert "hides every trace" in found["hidden shot"], found["hidden shot"]
  doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
  doAssert not fileExists(path & ".txt"), "the export was written"
  echo "tguiagent: ok"
