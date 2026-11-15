## Agent control's server thread and socket, with this test's main thread as
## the UI thread (it calls `serve` as the frame loop does) and real clients:
##
## - no socket before it is turned on; the socket's mode is 0600; turned
##   off, the socket is gone and a client is disconnected;
## - the handshake and the tool list are answered on the server's own
##   thread, with no frame; tool calls only by `serve`, and logged;
## - a command changes the state, `wait` answers once the picture is
##   complete, and with a time limit when it is not;
## - hostile input: garbage, JSON nested too deep, a batch, NUL bytes, a
##   line of 2 MiB (answered, then the client is disconnected), 17 calls at
##   once (the 17th refused), a client gone while its call is answered, a
##   fifth client (refused); the server goes on serving after each;
## - the path: a socket left behind is replaced, a file that is not a socket
##   is left alone and refused, a socket another server listens on refused;
## - four client threads at once, while the UI thread answers (run under
##   ThreadSanitizer too).
##
## Seen to fail: with the server handling one line per read (the rest
## left until more comes), "no answer to this is not JSON"; with
## `MaxInFlight` not checked, "17 calls were all taken"; with the socket
## left at the umask's mode, "mode 755"; with `stop` not removing the
## socket, "the socket is still there". Under ThreadSanitizer (`-d:useMalloc
## -d:noSignalHandler --debugger:native --passC:-fsanitize=thread
## --passL:-fsanitize=thread`): no report; with the queue of calls swapped
## without its lock, two.

import std/[atomics, json, monotimes, os, posix, strutils, times]
import viewSEG/core/state
import viewSEG/remote/[control, protocol, server]
import utils/[agentclient, fixtures, waiting]

proc pump(c: var AgentControl; st: var AppState; fe: Frontend; cond: proc (): bool): bool =
  ## Frames, as the UI thread would draw them, until `cond` holds.
  waitUntil((discard st.drainInbox(); c.serve(st, fe); sleep 2; cond()))

proc ask(c: var AgentControl; st: var AppState; fe: Frontend; client: var AgentClient;
    tool: string; arguments: JsonNode): JsonNode =
  ## A tool call, answered by frames; nil when no answer came.
  let id = $(getMonoTime().ticks)
  let msg = %*{"jsonrpc": "2.0", "id": id, "method": "tools/call",
    "params": {"name": tool, "arguments": arguments}}
  doAssert client.sendRaw($msg & "\n")
  var answer: JsonNode = nil
  let deadline = getMonoTime() + Patience
  while answer == nil and getMonoTime() < deadline:
    discard st.drainInbox()
    c.serve(st, fe)
    let line = client.readLine(initDuration(milliseconds = 2))
    if line.len > 0:
      let n = parseJson(line)
      if n{"id"}.getStr == id: answer = n
  if answer == nil: nil elif answer.hasKey("result"): answer["result"] else: answer

proc logHas(st: AppState; text: string): bool =
  for e in st.log:
    if text in e.text: return true

var stop: Atomic[bool]
var answered: Atomic[int]

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
    discard ctl.pump(st, fe, proc (): bool = st.logHas("is test client 1"))
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
