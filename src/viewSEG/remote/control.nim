## Agent control as the frontend owns it: turned on and off for the run,
## and `serve`d once per frame, after the frame is drawn and before its
## buffers swap, on the UI thread (docs/architecture.md, "Agent control").
##
## Each frame `serve` takes the calls the server thread queued and answers
## them in turn from the application state (`remote/tools`): at most
## `CallsPerFrame`; once one has applied a command, the rest wait for the
## next frame, so they see it drawn; one screenshot a frame. A `wait` is
## kept and looked at every frame until it holds on two frames in a row
## (what a job that ended meanwhile posted is then taken in) or its time is
## up. A `headers` call is kept until the job reading its trace has ended
## (the file's map may be on a drive that does not answer).
##
## What agents do goes to the log (source `agent`) without burying the
## user's own messages: every command, with what it said, and every
## failure; a call that changes nothing (`state`, `headers`, `screenshot`,
## `wait`), a connection, a disconnection or a refused message like one
## written less than `QuietFor` before is counted instead, and the count is
## written once `QuietFor` has passed (`said`).
##
## The status bar's sign says what an agent last asked (`lastCall`: "state",
## "command show file") while it is connected and for `SignLinger` after its
## last call: a shell's `--mcp-call` connects, calls and disconnects within
## milliseconds, and the sign would show it for one frame.

import std/[json, monotimes, os, strutils, tables, times]
import ../core/state
import protocol, server, tools

export Frontend, PlotAxes, PngEncoder, Shot, ShotTargets, ToolNames

const
  CallsPerFrame* = 8
  LogSource* = "agent"
  ShownArguments = 300 ## characters of a call's arguments the log shows
  QuietFor* = initDuration(seconds = 10)
    ## a line like one written less than this before is counted, not written
  SignLinger* = initDuration(seconds = 5)
    ## how long the status bar's sign names an agent's last call after it

type
  Waiting = object
    call: Call
    deadline: MonoTime
    quiet: int ## frames in a row that found nothing busy

  Quiet = object
    ## Lines of one kind from one agent: when one was written last, and how
    ## many like it were counted since.
    since: MonoTime
    held: int
    who, what: string ## for the count's line: "probe 1", "\"state\" calls"

  AgentControl* = object
    ## Owned by the UI thread, beside the application state. Off until
    ## `start`; move-only (it holds the server).
    server: Server
    starting: Starting ## a start under way (its folder slow to answer); none otherwise
    version: string ## for the start under way
    queue: seq[Call] ## taken, not answered yet
    waits: seq[Waiting]
    reading: seq[tuple[call: Call; ask: HeaderCall; written: bool]]
      ## `headers` calls whose trace is being read
    calls: seq[Call] ## scratch
    events: seq[Event] ## scratch
    frame: int ## `serve` calls so far
    commandFrame: int ## the frame a command was last applied in
    names: Table[int, string] ## what each client said it is
    announced: Table[int, bool] ## whether its connection was written
    quiet: Table[string, Quiet] ## by agent and kind of line: see `said`
    lastCall: string ## what an agent asked last, in words; "" for nothing yet
    lastCallAt: MonoTime ## when

proc running*(c: AgentControl): bool {.inline.} = c.server.running
  ## Whether agent control is on: the server listens.

proc path*(c: AgentControl): string = c.server.path
  ## The socket agents connect through; "" while off.

proc clients*(c: AgentControl): int = c.server.clients
  ## How many agents are connected.

func lastCall*(c: AgentControl): lent string {.inline.} = c.lastCall
  ## What an agent asked last, in words: the tool, and a command's kind
  ## ("state", "command show file"); "" when none has asked anything.

func lingers*(c: AgentControl; now: MonoTime): bool =
  ## Whether an agent's last call was less than `SignLinger` before `now`.
  c.lastCall.len > 0 and now - c.lastCallAt < SignLinger

proc callWords*(tool, arguments: string): string =
  ## A call in words, for the status bar's sign: the tool, and a command's
  ## kind ("command show file").
  result = tool
  if tool == "command":
    try:
      let kind = parseJson(arguments){"kind"}
      if kind != nil and kind.kind == JString and kind.getStr.len > 0:
        result.add " " & kind.getStr
    except CatchableError:
      discard # (the command's answer says what is wrong with it)

proc clientNames*(c: AgentControl): seq[string] =
  ## What the connected agents said they are, as far as they did.
  for n in c.names.values:
    if n.len > 0: result.add n

const StartWait* = initDuration(milliseconds = 500)
  ## how long `start` waits for the socket to be made before it goes on and
  ## takes the server in a later frame (its folder may not answer)

proc started(c: var AgentControl; state: var AppState; wait: Duration): bool =
  ## Takes in the start under way once it has ended (waiting at most
  ## `wait`), saying how it went. True when the server listens now.
  var s: Server
  var why, path: string
  if not c.starting.finished(s, why, path, wait): return false
  if why.len > 0:
    state.report(sevError, LogSource, "Agent control could not be turned on: " & why & ".")
    false
  else:
    c.server = move s
    state.report(sevInfo, LogSource, "Agent control is on: an MCP client connects through " &
      path & " (it starts `viewSEG --mcp-stdio=" & path & "`). Every call it makes is " &
      "written here.")
    true

proc start*(c: var AgentControl; state: var AppState; path, version: string;
    encode: PngEncoder = nil; find: SocketFinder = nil): bool =
  ## Turns agent control on at socket `path` (where `find` says when it is
  ## ""), saying so in the log; false, with the reason logged, when it
  ## cannot. Screenshots are encoded with `encode` (on the server thread);
  ## none without it. The socket is made on a thread of its own: a folder
  ## that does not answer within `StartWait` is said, and the server is
  ## taken in by `serve` once it is made (false meanwhile).
  if c.running: return true
  if not c.starting.isNil: return false # under way
  c.starting = beginServer(path, toolList(), version, @ToolNames, encode, find)
  result = c.started(state, StartWait)
  if not result and not c.starting.isNil:
    state.report(sevWarning, LogSource, "Agent control is being turned on: the folder of " &
      "its socket" & (if path.len > 0: " (" & path.parentDir & ")" else: "") &
      " does not answer yet.")

proc countsDue(c: var AgentControl; state: var AppState; now: MonoTime; all = false) =
  ## Writes the counts of the lines held back for `QuietFor` (all of them
  ## with `all`), and forgets the kinds of line that have been quiet as long.
  var gone: seq[string]
  for key, q in c.quiet.mpairs:
    if all or now - q.since >= QuietFor:
      if q.held > 0:
        let secs = max(1, int((now - q.since).inSeconds))
        state.report(sevInfo, LogSource, q.who & ": " & $q.held & " more " & q.what &
          " in the last " & $secs & " s, not written one by one.")
        q.held = 0
        q.since = now
      else:
        gone.add key
  for key in gone: c.quiet.del key

proc stop*(c: var AgentControl; state: var AppState; deadline = getMonoTime() + ServerStopWait) =
  ## Turns agent control off: the agents are disconnected, the socket
  ## removed, waiting for that until `deadline` (a socket's folder that does
  ## not answer is left to the thread that removes it). A start under way is
  ## left: what it starts is stopped.
  c.starting = Starting()
  if c.running:
    let path = c.server.path
    c.server.stop(deadline)
    c.queue.setLen 0
    c.waits.setLen 0
    c.reading.setLen 0
    c.names.clear()
    c.announced.clear()
    c.countsDue(state, getMonoTime(), all = true)
    c.quiet.clear()
    c.lastCall = ""
    state.report(sevInfo, LogSource, "Agent control is off; " & path & " is removed.")

proc who(c: AgentControl; client: int): string =
  let name = c.names.getOrDefault(client)
  if name.len > 0: name & " (agent " & $client & ")" else: "Agent " & $client

proc said(c: var AgentControl; state: var AppState; client: int; what, line: string;
    now: MonoTime; severity = sevInfo): bool =
  ## Writes `line`, unless a line of the same kind (`what`) from the same
  ## agent (by its name: a shell's `--mcp-call` connects for each call) was
  ## written less than `QuietFor` before: then it is counted, for
  ## `countsDue`. Whether it was written.
  let name = c.names.getOrDefault(client)
  let who = if name.len > 0: name else: "Agent " & $client
  let key = who & "\t" & what
  if key in c.quiet:
    inc c.quiet[key].held
    false
  else:
    c.quiet[key] = Quiet(since: now, who: who, what: what)
    state.report(severity, LogSource, line)
    true

proc announce(c: var AgentControl; state: var AppState; client: int; now: MonoTime) =
  ## Writes that `client` connected, once: when it says who it is, or else
  ## at its first call or when it goes.
  if not c.announced.getOrDefault(client, true):
    c.announced[client] = true
    let name = c.names.getOrDefault(client)
    discard c.said(state, client, "connections", "Agent " & $client & " connected" &
      (if name.len > 0: ": " & name else: "") & ".", now)

func shown(arguments: string): string =
  if arguments.len <= ShownArguments: arguments
  else: arguments.substr(0, ShownArguments - 1) & "..."

proc note(c: var AgentControl; state: var AppState; e: Event; now: MonoTime) =
  case e.kind
  of ekConnected:
    c.names[e.client] = ""
    c.announced[e.client] = false
  of ekIdentified:
    if e.text.len > 0 and e.client in c.names:
      c.names[e.client] = e.text
    c.announce(state, e.client, now)
  of ekDisconnected:
    c.announce(state, e.client, now)
    let line = c.who(e.client) & " disconnected" & (if e.text.len > 0: ": " & e.text
      else: "") & "."
    if e.text.len > 0: state.report(sevInfo, LogSource, line) # it failed: always said
    else: discard c.said(state, e.client, "disconnections", line, now)
    c.names.del e.client
    c.announced.del e.client
  of ekRefused:
    if e.client in c.names: # a message of a connected agent
      c.announce(state, e.client, now)
      discard c.said(state, e.client, "refused messages", c.who(e.client) & ": refused: " &
        e.text & ".", now, sevWarning)
    else: # a connection refused, or events not kept: always said
      state.report(sevWarning, LogSource, (if e.client > 0: "Agent " & $e.client & ": "
        else: "") & "refused: " & e.text & ".")

proc respond(c: var AgentControl; state: var AppState; call: Call; answer: string;
    written = true) =
  ## Sends `answer` (a tool result made by `remote/tools`); one that is an
  ## error is logged as a warning with the reason it gives first, when its
  ## call was (`written`).
  if written and answer.contains("\"isError\":true"):
    let why = parseJson(answer)["content"][0]["text"].getStr
    state.report(sevWarning, LogSource, c.who(call.client) & ": " & call.tool & ": " &
      shown(why))
  c.server.answer(call.serial, answer)

proc serve*(c: var AgentControl; state: var AppState; fe: Frontend; now = getMonoTime()) =
  ## Answers what the agents asked since the last frame (see the module's
  ## documentation). Call it once per frame, after the frame is drawn; it
  ## never waits.
  inc c.frame
  if not c.starting.isNil: discard c.started(state, initDuration()) # made at last?
  if not c.running: return
  c.server.takeCalls(c.calls, c.events)
  for e in c.events: c.note(state, e, now)
  for call in c.calls.mitems: c.queue.add move call
  var done = 0
  var shot = false
  var applied = false
  while c.queue.len > 0 and done < CallsPerFrame and not applied and
      not (shot and c.queue[0].tool == "screenshot"):
    let call = c.queue[0]
    c.queue.delete 0
    inc done
    c.lastCall = callWords(call.tool, call.arguments)
    c.lastCallAt = now
    c.announce(state, call.client, now)
    let line = c.who(call.client) & ": " & call.tool & " " & shown(call.arguments)
    # A command is always written (it changes what the user sees); a call
    # that changes nothing, like one just written, is counted.
    let written = if call.tool == "command": (state.report(sevInfo, LogSource, line); true)
                  else: c.said(state, call.client, "\"" & call.tool & "\" calls", line, now)
    case call.tool
    of "command":
      let answer = state.runCommand(fe, call.arguments, applied)
      if applied: c.commandFrame = c.frame
      c.respond(state, call, answer)
    of "state": c.respond(state, call, state.stateReport(fe, call.arguments), written)
    of "headers":
      var ask = state.askTraceHeaders(call.arguments)
      if ask.answer.len > 0: c.respond(state, call, ask.answer, written)
      else: c.reading.add (call, ask, written)
    of "screenshot":
      shot = true
      var picture: Picture
      let refusal = screenshot(fe, call.arguments, picture)
      if refusal.len > 0: c.respond(state, call, refusal, written)
      else: c.server.answerPicture(call.serial, move picture)
    of "wait":
      var seconds: float
      let refusal = waitArgs(call.arguments, seconds)
      if refusal.len > 0: c.respond(state, call, refusal, written)
      else:
        c.waits.add Waiting(call: call, deadline: call.received +
          initDuration(milliseconds = int(seconds * 1000)))
    else:
      c.respond(state, call, textResult("no tool " & call.tool, isError = true), written)
  var r = 0
  while r < c.reading.len:
    if state.headersAnswer(c.reading[r].ask):
      c.respond(state, c.reading[r].call, c.reading[r].ask.answer, c.reading[r].written)
      c.reading.delete r
    else:
      inc r
  c.countsDue(state, now)
  # Idle on two frames in a row: a job that ended between this frame's
  # inbox and now has what it posted taken in by the next frame's.
  let reasons = if c.frame > c.commandFrame: state.busy(fe)
                else: @["the last command, to be drawn"]
  var k = 0
  while k < c.waits.len:
    template w: untyped = c.waits[k]
    w.quiet = if reasons.len == 0: w.quiet + 1 else: 0
    if w.quiet >= 2 or now >= w.deadline:
      c.server.answer(w.call.serial, waited(reasons.len == 0, w.call.received, now, reasons))
      c.waits.delete k
    else:
      inc k
