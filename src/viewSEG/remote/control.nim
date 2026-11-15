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
## up. Every
## call, connection and disconnection goes to the log (source `agent`), and
## so does what was refused.

import std/[json, monotimes, strutils, tables, times]
import ../core/state
import protocol, server, tools

export Frontend, Shot, ShotTargets, ToolNames

const
  CallsPerFrame* = 8
  LogSource* = "agent"
  ShownArguments = 300 ## characters of a call's arguments the log shows

type
  Waiting = object
    call: Call
    deadline: MonoTime
    quiet: int ## frames in a row that found nothing busy

  AgentControl* = object
    ## Owned by the UI thread, beside the application state. Off until
    ## `start`; move-only (it holds the server).
    server: Server
    queue: seq[Call] ## taken, not answered yet
    waits: seq[Waiting]
    calls: seq[Call] ## scratch
    events: seq[Event] ## scratch
    frame: int ## `serve` calls so far
    commandFrame: int ## the frame a command was last applied in
    names: Table[int, string] ## what each client said it is

proc running*(c: AgentControl): bool {.inline.} = c.server.running
  ## Whether agent control is on: the server listens.

proc path*(c: AgentControl): string = c.server.path
  ## The socket agents connect through; "" while off.

proc clients*(c: AgentControl): int = c.server.clients
  ## How many agents are connected.

proc clientNames*(c: AgentControl): seq[string] =
  ## What the connected agents said they are, as far as they did.
  for n in c.names.values:
    if n.len > 0: result.add n

proc start*(c: var AgentControl; state: var AppState; path, version: string): bool =
  ## Turns agent control on at socket `path`, saying so in the log; false,
  ## with the reason logged, when it cannot.
  if c.running: return true
  let (s, why) = startServer(path, toolList(), version, @ToolNames)
  if why.len > 0:
    state.report(sevError, LogSource, "Agent control could not be turned on: " & why & ".")
    false
  else:
    c.server = s
    state.report(sevInfo, LogSource, "Agent control is on: an MCP client connects through " &
      path & " (it starts `viewSEG --mcp-stdio=" & path & "`). Every call it makes is " &
      "written here.")
    true

proc stop*(c: var AgentControl; state: var AppState) =
  ## Turns agent control off: the agents are disconnected, the socket removed.
  if c.running:
    let path = c.server.path
    c.server.stop()
    c.queue.setLen 0
    c.waits.setLen 0
    c.names.clear()
    state.report(sevInfo, LogSource, "Agent control is off; " & path & " is removed.")

proc who(c: AgentControl; client: int): string =
  let name = c.names.getOrDefault(client)
  if name.len > 0: name & " (agent " & $client & ")" else: "Agent " & $client

func shown(arguments: string): string =
  if arguments.len <= ShownArguments: arguments
  else: arguments.substr(0, ShownArguments - 1) & "..."

proc note(c: var AgentControl; state: var AppState; e: Event) =
  case e.kind
  of ekConnected:
    c.names[e.client] = ""
    state.report(sevInfo, LogSource, "Agent " & $e.client & " connected.")
  of ekIdentified:
    if e.text.len > 0:
      c.names[e.client] = e.text
      state.report(sevInfo, LogSource, "Agent " & $e.client & " is " & e.text & ".")
  of ekDisconnected:
    state.report(sevInfo, LogSource, c.who(e.client) & " disconnected" &
      (if e.text.len > 0: ": " & e.text else: "") & ".")
    c.names.del e.client
  of ekRefused:
    state.report(sevWarning, LogSource, (if e.client > 0: c.who(e.client) & ": " else: "") &
      "refused: " & e.text & ".")

proc respond(c: var AgentControl; state: var AppState; call: Call; answer: string) =
  ## Sends `answer` (a tool result made by `remote/tools`); one that is an
  ## error is logged as a warning with the reason it gives first.
  if answer.contains("\"isError\":true"):
    let why = parseJson(answer)["content"][0]["text"].getStr
    state.report(sevWarning, LogSource, c.who(call.client) & ": " & call.tool & ": " &
      shown(why))
  c.server.answer(call.serial, answer)

proc serve*(c: var AgentControl; state: var AppState; fe: Frontend; now = getMonoTime()) =
  ## Answers what the agents asked since the last frame (see the module's
  ## documentation). Call it once per frame, after the frame is drawn; it
  ## never waits.
  inc c.frame
  if not c.running: return
  c.server.takeCalls(c.calls, c.events)
  for e in c.events: c.note(state, e)
  for call in c.calls.mitems: c.queue.add move call
  var done = 0
  var shot = false
  var applied = false
  while c.queue.len > 0 and done < CallsPerFrame and not applied and
      not (shot and c.queue[0].tool == "screenshot"):
    let call = c.queue[0]
    c.queue.delete 0
    inc done
    state.report(sevInfo, LogSource, c.who(call.client) & ": " & call.tool & " " &
      shown(call.arguments))
    case call.tool
    of "command":
      let answer = state.runCommand(fe, call.arguments, applied)
      if applied: c.commandFrame = c.frame
      c.respond(state, call, answer)
    of "state": c.respond(state, call, state.stateReport(fe, call.arguments))
    of "headers": c.respond(state, call, state.traceHeaderReport(call.arguments))
    of "screenshot":
      shot = true
      c.respond(state, call, screenshot(fe, call.arguments))
    of "wait":
      var seconds: float
      let refusal = waitArgs(call.arguments, seconds)
      if refusal.len > 0: c.respond(state, call, refusal)
      else:
        c.waits.add Waiting(call: call, deadline: call.received +
          initDuration(milliseconds = int(seconds * 1000)))
    else:
      c.respond(state, call, textResult("no tool " & call.tool, isError = true))
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
