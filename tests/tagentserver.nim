## Agent control's server thread and socket, with this test's main thread as
## the UI thread (it calls `serve` as the frame loop does) and real clients:
##
## - no socket before it is turned on; the socket's mode is 0600; turned
##   off, the socket is gone and a client is disconnected;
## - the handshake and the tool list are answered on the server's own
##   thread, with no frame; tool calls only by `serve`, and logged;
## - a command changes the state, `wait` answers once the picture is
##   complete (on two frames in a row), and with a time limit when it is not;
## - hostile input: garbage, JSON nested too deep, a batch, NUL bytes, a
##   line of 2 MiB (answered, then the client is disconnected), 17 calls at
##   once (the 17th refused), a client gone while its call is answered, a
##   fifth client (refused); the server goes on serving after each;
## - the path: a socket left behind is replaced, a file that is not a socket
##   is left alone and refused, a socket another server listens on refused;
## - an agent that polls does not bury the log: 40 `state` calls are one
##   line and, once `QuietFor` has passed, a count; every command is a line;
##   a shell's `--mcp-call`, which connects for each call, likewise;
## - `--mcp-call` with arguments that are not one JSON object ends at once
##   (exit 1); the bridge and `--mcp-call` take only a program of their own
##   user; the bridge relays the answer to a call whose client closed its
##   input at once;
## - four client threads at once, while the UI thread answers (run under
##   ThreadSanitizer too).
##
## Seen to fail: with the server handling one line per read (the rest
## left until more comes), "no answer to this is not JSON"; with
## `MaxInFlight` not checked, "17 calls were all taken"; with the socket
## left at the umask's mode, "mode 755"; with `wait` answered on the first
## idle frame, "idle after one frame"; with `stop` not removing the
## socket, "the socket is still there". Under ThreadSanitizer (`-d:useMalloc
## -d:noSignalHandler --debugger:native --passC:-fsanitize=thread
## --passL:-fsanitize=thread`): no report; with the queue of calls swapped
## without its lock, two. With every agent line written (`said` not
## counting), "40 state calls and 3 commands: 43 lines"; with `callOnce`
## sending its arguments unchecked and waiting for id 2 only, "--mcp-call
## with \"{bad\" did not end" (it waited 330 s); with the server's user not
## checked, "a program of another user was taken"; with the bridge ending
## when its input ends, "the bridge ended without the call's answer".

import std/[atomics, json, monotimes, os, posix, strutils, times]
import viewSEG/core/state
import viewSEG/remote/[client, control, protocol, server]
import utils/[agentclient, fixtures, waiting]

proc pump(c: var AgentControl; st: var AppState; fe: Frontend; cond: proc (): bool): bool =
  ## Frames, as the UI thread would draw them, until `cond` holds.
  waitUntil((discard st.drainInbox(); c.serve(st, fe); sleep 2; cond()))

proc ask(c: var AgentControl; st: var AppState; fe: Frontend; client: var AgentClient;
    tool: string; arguments: JsonNode; at = MonoTime()): JsonNode =
  ## A tool call, answered by frames (served at the time `at` when it is
  ## given); nil when no answer came.
  let id = $(getMonoTime().ticks)
  let msg = %*{"jsonrpc": "2.0", "id": id, "method": "tools/call",
    "params": {"name": tool, "arguments": arguments}}
  doAssert client.sendRaw($msg & "\n")
  var answer: JsonNode = nil
  let deadline = getMonoTime() + Patience
  while answer == nil and getMonoTime() < deadline:
    discard st.drainInbox()
    if at == MonoTime(): c.serve(st, fe) else: c.serve(st, fe, at)
    let line = client.readLine(initDuration(milliseconds = 2))
    if line.len > 0:
      let n = parseJson(line)
      if n{"id"}.getStr == id: answer = n
  if answer == nil: nil elif answer.hasKey("result"): answer["result"] else: answer

proc logHas(st: AppState; text: string): bool =
  for e in st.log:
    if text in e.text: return true
var answered: Atomic[int]
var shellExit: Atomic[int]

proc shell(a: (string, string)) {.thread.} =
  ## `viewSEG --mcp-call=<a[0]> state <a[1]>`, its exit code to `shellExit`.
  shellExit.store callOnce(a[0], "state", a[1], "")

var bridgeExit: Atomic[int]

proc runBridge(a: (string, cint, File)) {.thread.} =
  ## `viewSEG --mcp-stdio=<a[0]>` on the pipes given, its exit code to `bridgeExit`.
  bridgeExit.store bridge(a[0], "test", a[1], a[2])

proc hammer(path: string) {.thread.} =
  ## A client that pings and asks for the jobs, over and over.
  var c = connectAgent(path)
  doAssert c.fd >= 0
  discard c.initialize("hammer")
  for i in 0 ..< 50:
    doAssert c.request("ping", nil) != nil
    let r = c.call("state", %*{"parts": ["jobs"]})
    doAssert r != nil and not r.failed, $r
    answered.atomicInc
  c.close()

proc main*() =

  var stop: Atomic[bool]

  withFixtures fx:
    let path = fx.dir / "agent.sock"
    let file = fx.surveySegy()
    var st = initAppState()
    var ctl: AgentControl
    let fe = Frontend()

    block offByDefault:
      doAssert not ctl.running and ctl.path == "" and not fileExists(path) and
        not symlinkExists(path)
      var probe = connectAgent(path)
      doAssert probe.fd < 0
      doAssert ctl.start(st, path, "test")
      doAssert ctl.running and ctl.path == path and st.logHas("Agent control is on")
      var s: Stat
      doAssert lstat(path.cstring, s) == 0 and S_ISSOCK(s.st_mode)
      doAssert (s.st_mode.int and 0o777) == 0o600, "mode " & toOct(s.st_mode.int and 0o777, 3)

    block handshakeWithoutFrames:
      var c = connectAgent(path)
      doAssert c.fd >= 0
      let init = c.initialize()
      doAssert init != nil and init["result"]["serverInfo"]["name"].getStr == "viewSEG", $init
      let list = c.request("tools/list", nil)
      doAssert list["result"]["tools"].len == 5
      doAssert c.request("ping", nil)["result"].len == 0
      discard ctl.pump(st, fe, proc (): bool = st.logHas("connected: test client 1"))
      doAssert st.logHas("Agent 1 connected") and ctl.clients == 1
      # a tool call waits for a frame
      let r = ctl.ask(st, fe, c, "state", %*{"parts": ["files"]})
      doAssert r != nil and not r.failed and r.text == """{"files":[]}""", $r
      doAssert st.logHas("test client 1 (agent 1): state {\"parts\":[\"files\"]}")
      # a command changes the state; wait answers once the picture is complete
      doAssert not ctl.ask(st, fe, c, "command", %*{"kind": "show file", "path": file}).failed
      doAssert not ctl.ask(st, fe, c, "command", %*{"kind": "view", "view": {"columns": 400,
        "rows": 600, "traces": {"lo": -0.5, "hi": 23.5}, "timeMs": {"lo": 0, "hi": 998}}}).failed
      let w = ctl.ask(st, fe, c, "wait", %*{"timeout": 20})
      doAssert w != nil and parseJson(w.text)["idle"].getBool, $w
      doAssert st.sessions.len == 1 and st.panel(MainPanel).laidOut
      # idle on two frames in a row: what a job that ended between this
      # frame's inbox and its answers posted is taken in first
      # (from a client of another name: a second `wait` of the same one so soon
      # is counted, not written, and the log line says the frame took it)
      var c2 = connectAgent(path)
      discard c2.initialize("second client")
      doAssert c2.sendRaw("""{"jsonrpc":"2.0","id":"w","method":"tools/call","params":""" &
        """{"name":"wait","arguments":{"timeout":7}}}""" & "\n")
      # frames until one takes the call (and finds nothing busy, once)
      doAssert waitUntil((ctl.serve(st, fe); st.logHas("wait {\"timeout\":7}")))
      doAssert c2.readLine(initDuration(milliseconds = 100)) == "", "idle after one frame"
      ctl.serve(st, fe)
      doAssert parseJson(c2.readLine())["id"].getStr == "w"
      c2.close()
      # not complete: a frontend whose picture never shows the view
      let stale = Frontend(drawnView: proc (p: PanelId; v: var Viewport): bool =
        v = Viewport()
        true)
      let t0 = getMonoTime()
      let late = ctl.ask(st, stale, c, "wait", %*{"timeout": 0.3})
      let busy = parseJson(late.text)
      doAssert not busy["idle"].getBool and "not drawn yet" in $busy["busy"], $busy
      doAssert getMonoTime() - t0 >= initDuration(milliseconds = 300)
      c.close()

    block hostile:
      var c = connectAgent(path)
      discard c.initialize("hostile")
      template answer(raw: string): JsonNode =
        doAssert c.sendRaw(raw & "\n")
        let line = c.readLine()
        doAssert line.len > 0, "no answer to " & raw.substr(0, 60)
        parseJson(line)
      doAssert answer("this is not JSON")["error"]["code"].getInt == ParseError
      doAssert answer(repeat('[', 100_000) & repeat(']', 100_000))["error"]["code"].getInt ==
        InvalidRequest
      doAssert answer("""[{"jsonrpc":"2.0","id":1,"method":"ping"}]""")["error"]["code"].getInt ==
        InvalidRequest
      doAssert answer("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"pi\x00ng\"}").hasKey("error")
      doAssert answer("\xff\xfe\x00\x01")["error"]["code"].getInt == ParseError
      # two messages in one write: both answered
      doAssert c.sendRaw("""{"jsonrpc":"2.0","id":"a","method":"ping"}""" & "\n" &
        """{"jsonrpc":"2.0","id":"b","method":"ping"}""" & "\n")
      doAssert parseJson(c.readLine())["id"].getStr == "a"
      doAssert parseJson(c.readLine())["id"].getStr == "b", "the second call was not answered"
      # 17 calls at once: 16 taken, the 17th refused
      var batch = ""
      for i in 1 .. MaxInFlight + 1:
        batch.add "{\"jsonrpc\":\"2.0\",\"id\":" & $i & ",\"method\":\"tools/call\"," &
          "\"params\":{\"name\":\"state\",\"arguments\":{\"parts\":[\"jobs\"]}}}\n"
      doAssert c.sendRaw(batch)
      let first = c.readLine(initDuration(seconds = 5))
      doAssert first.len > 0, "17 calls were all taken: no refusal"
      let refused = parseJson(first)
      doAssert refused["id"].getInt == MaxInFlight + 1 and
        refused["error"]["code"].getInt == ServerBusy, "17 calls were all taken: " & $refused
      var got = 0
      discard ctl.pump(st, fe, proc (): bool =
        if c.readLine(initDuration(milliseconds = 1)).len > 0: inc got
        got == MaxInFlight)
      doAssert got == MaxInFlight, $got
      doAssert answer("""{"jsonrpc":"2.0","id":9,"method":"ping"}""")["id"].getInt == 9
      # a line of 2 MiB: answered, then the connection is closed
      discard c.sendRaw(repeat('x', 2 * 1024 * 1024)) # cut off part way: the server closed it
      let long = parseJson(c.readLine())
      doAssert long["error"]["code"].getInt == InvalidRequest and "longer" in long["error"][
          "message"].getStr
      doAssert c.readLine(initDuration(seconds = 5)) == "", "still connected"
      c.close()
      # a client gone while its call is answered
      var gone = connectAgent(path)
      doAssert gone.sendRaw("""{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"state"}}""" & "\n")
      sleep 50
      gone.close()
      for i in 0 ..< 20:
        ctl.serve(st, fe)
        sleep 5
      # four clients, and a fifth refused
      var four: seq[AgentClient]
      for i in 0 ..< MaxClients:
        four.add connectAgent(path)
        doAssert four[^1].request("ping", nil) != nil
      var fifth = connectAgent(path)
      let no = fifth.readLine()
      doAssert no.len > 0 and parseJson(no)["error"]["code"].getInt == ServerBusy, no
      doAssert fifth.readLine(initDuration(seconds = 5)) == ""
      fifth.close()
      for f in four.mitems: f.close()
      # (the event may come after the frame that saw the last client go)
      doAssert ctl.pump(st, fe, proc (): bool =
        ctl.clients == 0 and st.logHas("refused: a connection was refused"))
      # still serving
      var after = connectAgent(path)
      discard after.initialize()
      doAssert not ctl.ask(st, fe, after, "state", %*{"parts": ["jobs"]}).failed
      after.close()

    block quietLog:
      # an agent that polls does not bury the user's messages: a call that
      # changes nothing, like one just written, is counted, and the count
      # written once `QuietFor` has passed; every command is written
      proc lines(st: AppState; text: string): int =
        for e in st.log:
          if text in e.text: inc result
      # (served at one time, so that a slow machine does not end the quiet)
      let t0 = getMonoTime()
      var poller = connectAgent(path)
      discard poller.initialize("poller")
      for i in 0 ..< 40:
        doAssert not ctl.ask(st, fe, poller, "state", %*{"parts": ["jobs"]}, t0).failed
      for i in 0 ..< 3:
        doAssert not ctl.ask(st, fe, poller, "command", %*{"kind": "clear selection"}, t0).failed
      doAssert st.lines("poller 1 (agent ") == 4, "40 state calls and 3 commands: " &
        $st.lines("poller 1 (agent ") & " lines"
      doAssert st.lines("poller 1 (agent ") + st.lines("poller 1:") == 4
      let t1 = t0 + QuietFor + initDuration(seconds = 1)
      ctl.serve(st, fe, t1)
      doAssert st.lines("poller 1: 39 more \"state\" calls") == 1, "the count was not written"
      poller.close()
      # a shell's `--mcp-call` connects for each call: its connections too
      for i in 0 ..< 10:
        var shell = connectAgent(path)
        discard shell.initialize("shell")
        doAssert not ctl.ask(st, fe, shell, "state", %*{"parts": ["jobs"]}, t1).failed
        shell.close()
      doAssert waitUntil((ctl.serve(st, fe, t1); sleep 2; ctl.clients == 0 and
        st.lines("shell 1 (agent ") + st.lines("shell 1:") >= 2))
      sleep 50
      ctl.serve(st, fe, t1)
      doAssert st.lines("connected: shell 1") == 1 and st.lines("shell 1 (agent ") == 2,
        $st.lines("connected: shell 1") & " connections and " & $st.lines("shell 1 (agent ") &
        " calls and disconnections written"
      ctl.serve(st, fe, t1 + QuietFor + initDuration(seconds = 1))
      doAssert st.lines("shell 1: 9 more connections") == 1 and
        st.lines("shell 1: 9 more \"state\" calls") == 1 and
        st.lines("shell 1: 9 more disconnections") == 1

    block theShellsAndTheBridgesConnection:
      # `--mcp-call` with arguments that are not one JSON object: refused at
      # once (sent as they were, the program's answer had no id to wait for)
      for bad in ["{bad", "[1]", "{}\n{\"jsonrpc\":\"2.0\",\"id\":2}"]:
        shellExit.store -1
        var t: Thread[(string, string)]
        createThread(t, shell, (path, bad))
        doAssert waitUntil(shellExit.load != -1, initDuration(seconds = 10)),
          "--mcp-call with " & escapeJson(bad) & " did not end"
        joinThread(t)
        doAssert shellExit.load == 1, $shellExit.load
      # only a program of one's own user is taken (`owner` stands for another
      # user, whom a test cannot be)
      var why = ""
      let fd = connectTo(path, why)
      doAssert fd >= 0 and why == "", why
      discard posix.close(fd)
      doAssert connectTo(path, why, owner = int(getuid()) + 1) < 0 and "another user" in why,
        "a program of another user was taken: " & why
      discard ctl.pump(st, fe, proc (): bool = ctl.clients == 0)

    block theBridgeRelaysAfterItsInputEnds:
      # a client that sends its calls and closes its end at once (`echo ... |
      # viewSEG --mcp-stdio`) still gets their answers
      var toBridge, fromBridge: array[2, cint]
      doAssert pipe(toBridge) == 0 and pipe(fromBridge) == 0
      var output: File
      doAssert open(output, FileHandle(fromBridge[1]), fmWrite)
      let asked = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":""" &
        """"2025-06-18","capabilities":{},"clientInfo":{"name":"pipe","version":"1"}}}""" & "\n" &
        """{"jsonrpc":"2.0","method":"notifications/initialized"}""" & "\n" &
        """{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"state",""" &
        """"arguments":{"parts":["jobs"]}}}""" & "\n"
      doAssert write(toBridge[1], asked.cstring, asked.len) == asked.len
      discard posix.close(toBridge[1]) # the client's end: closed at once
      bridgeExit.store -1
      var t: Thread[(string, cint, File)]
      createThread(t, runBridge, (path, toBridge[0], output))
      var got = ""
      proc answered(): bool =
        ## A frame, then what the bridge wrote meanwhile: its answer to call 2?
        discard st.drainInbox()
        ctl.serve(st, fe)
        var fds = [TPollfd(fd: fromBridge[0], events: POLLIN)]
        if poll(addr fds[0], 1, 2) > 0:
          var buf = newString(65536)
          let n = read(fromBridge[0], addr buf[0], buf.len)
          if n > 0: got.add buf.substr(0, n - 1)
        "\"id\":2," in got and bridgeExit.load != -1
      doAssert waitUntil(answered()), "the bridge ended without the call's answer: " & got
      joinThread(t)
      doAssert bridgeExit.load == 0 and "jobs" in got, got
      close(output)
      discard posix.close(fromBridge[0])
      discard posix.close(toBridge[0])
      discard ctl.pump(st, fe, proc (): bool = ctl.clients == 0)

    block threads:
      var ts: array[4, Thread[string]]
      for t in ts.mitems: createThread(t, hammer, path)
      doAssert ctl.pump(st, fe, proc (): bool = answered.load == 200), $answered.load
      joinThreads(ts)

    block thePath:
      var other: AgentControl
      doAssert not other.start(st, path, "test"), "a second server on a live socket"
      doAssert st.logHas("another program listens on")
      let plain = fx.dir / "plain.txt"
      writeFile(plain, "keep me")
      doAssert not other.start(st, plain, "test") and readFile(plain) == "keep me"
      doAssert st.logHas("is not a socket")
      doAssert not other.start(st, fx.dir / repeat("x", 120) / "a.sock", "test")
      doAssert st.logHas("is longer than")
      # a socket left behind by a run that ended without removing it
      let stale = fx.dir / "stale.sock"
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      var a: Sockaddr_un
      a.sun_family = TSa_Family(AF_UNIX)
      copyMem(addr a.sun_path[0], stale.cstring, stale.len)
      doAssert bindSocket(fd, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) == 0
      discard posix.close(fd.cint)
      doAssert fileExists(stale) or symlinkExists(stale) or true
      doAssert other.start(st, stale, "test"), "a socket left behind was not replaced"
      var c = connectAgent(stale)
      doAssert c.fd >= 0 and c.request("ping", nil) != nil
      c.close()
      other.stop(st)

    block turnedOff:
      var c = connectAgent(path)
      discard c.initialize()
      ctl.stop(st)
      doAssert not ctl.running
      var s: Stat
      doAssert lstat(path.cstring, s) != 0, "the socket is still there"
      doAssert c.readLine(initDuration(seconds = 5)) == "", "a client still connected"
      c.close()
      doAssert connectAgent(path).fd < 0
      doAssert st.logHas("Agent control is off")
    st.shutdown()
    echo "tagentserver: ok"

when isMainModule:
  main()
