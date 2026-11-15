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
##   killed, `headers` gives its channel; a command that writes a file is
##   refused, and the whole window can be taken;
## - while it is connected the status bar shows "agent connected", and
##   Messages holds a line for each of its calls; the file is not changed.
##
## Seen to fail: with `serve` not called in the frame loop, "the agent did
## not finish"; with the kill applied as a reversal, "the killed trace's
## band: 1153 pixels of ink"; with no trace named to the kill (the
## selection not taken), "kill: ... ignored"; with the status bar's sign
## left out, "no sign while on"; with File > Agent control's way not
## starting the server, "no listening socket after turning it on".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[base64, json, math, options, os, posix, sequtils, strutils, tables]
import sdl3_nim
import viewSEG/core/[geometry, state]
import viewSEG/view/plotink
import viewSEG/ui/imgui/app
import viewSEG/remote/control
import utils/[agentclient, fixtures]

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
  for i in 0 ..< 200:
    if c.fd < 0:
      sleep 50
      c = connectAgent(s.socket)
  if c.fd < 0: fail("cannot connect to " & s.socket)
  let init = c.initialize("test agent")
  if init == nil: fail("the agent's first call: no answer")
  if c.request("tools/list", nil){"result"}{"tools"}.len != 5: fail("not five tools")
  results.send(("connected", ""))
  var r = c.call("command", %*{"kind": "show file", "path": s.fixture})
  check(r, "show file")
  check(c.call("wait", %*{"timeout": 30}), "wait")
  check(c.call("command", %*{"kind": "display", "display": {"mode": "wiggle", "fills": [],
    "overlap": 0.5, "gain": "none"}}), "display")
  check(c.call("command", %*{"kind": "sort", "order": [{"field": "channel",
    "descending": true}]}), "sort")
  r = c.call("wait", %*{"timeout": 30})
  check(r, "wait after sort")
  if not parseJson(r.text)["idle"].getBool: fail("not idle after the sort: " & r.text)
  r = c.call("state", %*{"parts": ["panels"]})
  check(r, "state")
  let panel = parseJson(r.text)["panels"][0]
  let trace = panel["positions"][3].getInt
  let id = panel["file"]["firstTrace"].getInt + trace
  check(c.call("command", %*{"kind": "select", "traces": [id], "mode": "replace"}), "select")
  check(c.call("wait"), "wait after select")
  r = c.call("screenshot", %*{"window": "plot", "maxSize": 4096})
  check(r, "screenshot before")
  results.send(("before", r["content"][0]["data"].getStr))
  check(c.call("command", %*{"kind": "edit traces", "edit": "killed"}), "kill")
  r = c.call("wait", %*{"timeout": 30})
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
  r = c.call("command", %*{"kind": "export messages", "docPath": s.fixture & ".txt"})
  if not r.failed: fail("an export was carried out")
  r = c.call("screenshot")
  check(r, "screenshot of the window")
  results.send(("window", r["content"][1]["text"].getStr))
  c.close()
  results.send(("done", ""))

withFixtures fx:
  let path = fx.surveySegy()
  let before = (readFile(path), getLastModificationTime(path))
  let socket = fx.dir / "agent.sock"

  block offByDefault:
    var frame = 0
    var problem = ""
    var stage = 0
    proc onFrame(f: FrameInfo) =
      inc frame
      template fail(why: string) =
        problem = why
        f.stop()
      if frame > 600: fail("stage " & $stage & " did not end")
      elif stage == 0 and frame == 10:
        if f.agentControl.running: fail("agent control is on by default")
        elif listeningSockets() != 0: fail("a listening socket by default")
        elif fileExists(socket) or symlinkExists(socket): fail("a socket by default")
        elif f.markOf("status.agent").size.x > 0: fail("a sign while off")
        else:
          f.setAgentControl(true)
          stage = 1
      elif stage == 1 and frame > 15:
        if listeningSockets() != 1: fail("no listening socket after turning it on")
        elif f.markOf("status.agent").size.x <= 0: fail("no sign while on")
        elif f.markOf("status.agent connected").size.x > 0: fail("connected, with nobody")
        elif not f.messages.anyIt("Agent control is on" in it.text): fail("not said")
        else:
          f.setAgentControl(false)
          stage = 2
      elif stage == 2 and frame > 20:
        if listeningSockets() != 0 or f.agentControl.running: fail("still listening")
        elif fileExists(socket) or symlinkExists(socket): fail("the socket is still there")
        elif f.markOf("status.agent").size.x > 0: fail("a sign while off")
        else: f.stop()
    let code = run(RunOptions(maxFrames: 2000, windowSize: (1200, 800), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      agentSocket: socket, onFrame: onFrame))
    doAssert code == 0 and problem.len == 0, problem
    echo "tguiagent: off by default, on and off from the menu's way"

  block anAgentKillsATrace:
    results.open()
    var thread: Thread[Scenario]
    var frame = 0
    var started, connected, signSeen, done = false
    var problem = ""
    var got: seq[(string, string)]
    var ink: PlotInk
    var lines = 0
    proc onFrame(f: FrameInfo) =
      inc frame
      if not started:
        createThread(thread, agent, (socket, path))
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
            ink = plotInk(f.theme, f.core.panels[0].layers[0].display)
            f.stop()
          else: discard
      if connected and not done and f.markOf("status.agent connected").size.x > 0:
        signSeen = true
      if frame > 5000:
        problem = "the agent did not finish"
        f.stop()
    let code = run(RunOptions(maxFrames: 6000, windowSize: (1600, 1000), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      agent: true, agentSocket: socket, onFrame: onFrame))
    joinThread(thread)
    results.close()
    doAssert code == 0, "run() exit code " & $code
    doAssert problem.len == 0, problem
    doAssert done, "the agent did not finish"
    doAssert signSeen, "no sign of the agent in the status bar"
    doAssert lines >= 14, "Messages holds " & $lines & " lines of the agent's calls"
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
    let killed = found["killed"].splitWhitespace
    doAssert parseJson(killed[0]) == %*[parseInt(killed[1])], found["killed"]
    doAssert parseFloat(found["channel"]) == float(Channels - 3), found["channel"]
    doAssert "window: " in found["window"], found["window"]
  doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
  doAssert not fileExists(path & ".txt"), "the export was written"
  echo "tguiagent: ok"
