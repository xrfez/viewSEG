## The other end of agent control's socket:
##
## - `bridge` (`viewSEG --mcp-stdio`): the process an MCP client starts. It
##   speaks MCP on stdin and stdout, answers the handshake and the tool list
##   itself (from this build's own list), and relays tool calls to the
##   program listening on the socket, connecting at the first call and again
##   after the program restarts; with no program listening, a call is
##   answered with an error that says how to start one.
## - `callOnce` (`viewSEG --mcp-call`): one tool call from a shell; its text
##   goes to stdout, an image to the file asked for.
##
## Neither opens a window or touches the application state, and both talk
## only to a program of their own user: what answers on a socket another
## user made could put words in an agent's mouth.

import std/[base64, json, monotimes, strutils, times]
import protocol, server, tools

const
  MaxAnswerBytes* = 32 * 1024 * 1024 ## the longest answer read from the program
  BridgeId = "\"viewSEG-bridge\""    ## the id of the bridge's own `initialize`
  CallTimeout = initDuration(seconds = MaxWaitSeconds + 30)

when not defined(windows):
  import std/posix

  proc connectTo*(path: string; why: var string; owner = int(getuid())): cint =
    ## A socket connected to `path`; -1 when nothing listens there, or when
    ## what listens runs as another user than `owner` (`why` says so).
    result = -1
    why = ""
    if path.len > 0 and path.len <= SocketNameLimit:
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      if fd.cint >= 0:
        var a: Sockaddr_un
        a.sun_family = TSa_Family(AF_UNIX)
        copyMem(addr a.sun_path[0], path.cstring, path.len)
        if connect(fd, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) != 0:
          discard posix.close(fd.cint)
        else:
          let uid = peerUid(fd.cint)
          if uid == owner:
            result = fd.cint
          else:
            discard posix.close(fd.cint)
            why = "the program listening on " & path & " runs as " & (if uid < 0:
              "a user that cannot be told" else: "another user (id " & $uid & ")") &
              "; agent control talks to a viewSEG of your own user only"

  proc writeAll(fd: cint; text: string): bool =
    ## Writes all of `text` to `fd`; false when the other end is gone.
    var sent = 0
    while sent < text.len:
      let n = write(fd, addr text[sent], text.len - sent)
      if n > 0: sent += n
      elif n < 0 and errno == EINTR: discard
      else: return false
    true

  proc readSome(fd: cint; into: var LineBuffer): bool =
    ## Reads what `fd` has; false at its end or on an error.
    var buf = newString(256 * 1024)
    let n = read(fd, addr buf[0], buf.len)
    if n > 0:
      into.feed(buf.toOpenArray(0, n - 1))
      true
    else:
      n < 0 and errno == EINTR

func idOf(line: string): string =
  ## The id of a response the program wrote (JSON text); "" when it has none.
  const head = "{\"jsonrpc\":\"2.0\",\"id\":"
  result = ""
  if line.startsWith(head):
    var stop = line.find(",\"result\":", head.len)
    let e = line.find(",\"error\":", head.len)
    if stop < 0 or (e >= 0 and e < stop): stop = e
    if stop > head.len: result = line.substr(head.len, stop - 1)

proc notRunning(path: string): string =
  "viewSEG is not running with agent control on at " & path & ". Start it with " &
    "`viewSEG --mcp` (with the same socket: `--mcp=" & path & "`), or turn on Tools > " &
    "Agent control in the running program, then call again."

proc bridge*(path, version: string; input: cint = 0; output = stdout): int =
  ## Serves an MCP client on `input` and `output` (stdin and stdout) until
  ## `input` ends and the calls it made are answered (see the module's
  ## documentation). Returns the exit code.
  when defined(windows):
    stderr.writeLine "viewSEG: agent control is not available on Windows in this version"
    result = 1
  else:
    signal(SIGPIPE, SIG_IGN)
    let toolList = toolList()
    var asked = initLineBuffer(MaxMessageBytes)
    var answers = initLineBuffer(MaxAnswerBytes)
    var sock: cint = -1
    var initParams = "{}"
    var inFlight: seq[string]
    var line: string
    var open = true # `input` has not ended
    var until: MonoTime # once it has: how long the calls in flight are waited for

    proc toClient(text: string) =
      output.write text
      output.write '\n'
      output.flushFile()

    proc lost(why: string) =
      if sock >= 0: discard posix.close(sock)
      sock = -1
      answers = initLineBuffer(MaxAnswerBytes)
      for id in inFlight:
        toClient response(id, textResult(why, isError = true))
      inFlight.setLen 0

    var refusal = "" # why the program on the socket was not taken

    proc connected(): bool =
      if sock < 0:
        sock = connectTo(path, refusal)
        if sock >= 0 and not sock.writeAll("{\"jsonrpc\":\"2.0\",\"id\":" & BridgeId &
            ",\"method\":\"initialize\",\"params\":" & initParams & "}\n" &
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"):
          lost("viewSEG closed the connection")
      sock >= 0

    # A client may send its calls and close its end at once (`echo ... |`):
    # their answers are still relayed, for `CallTimeout` at most.
    while open or (sock >= 0 and inFlight.len > 0 and getMonoTime() < until):
      var fds: seq[TPollfd]
      if open: fds.add TPollfd(fd: input, events: POLLIN)
      let at = fds.len # the socket's place
      if sock >= 0: fds.add TPollfd(fd: sock, events: POLLIN)
      let wait = if open: -1 else: int(max(0, (until - getMonoTime()).inMilliseconds))
      if poll(addr fds[0], Tnfds(fds.len), cint(wait)) < 0 and errno != EINTR:
        break
      if sock >= 0 and (fds[at].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        if not readSome(sock, answers):
          lost("viewSEG closed the connection (it was closed, or agent control was " &
            "turned off); call again once it runs")
        var more = sock >= 0
        while more:
          case answers.next(line)
          of lsWaiting: more = false
          of lsTooLong:
            lost("an answer from viewSEG was longer than " & $MaxAnswerBytes & " bytes")
            more = false
          of lsLine:
            let id = idOf(line)
            if id != BridgeId:
              let k = inFlight.find(id)
              if k >= 0: inFlight.delete k
              toClient line
      if open and (fds[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        if not readSome(input, asked):
          open = false
          until = getMonoTime() + CallTimeout
        var more = true
        while more:
          case asked.next(line)
          of lsWaiting: more = false
          of lsTooLong:
            toClient errorResponse("", InvalidRequest, "a message is longer than " &
              $MaxMessageBytes & " bytes")
            open = false
            until = getMonoTime() # the stream cannot go on: nothing more is relayed
            more = false
          of lsLine:
            if line.strip.len > 0:
              var req: Request
              let (code, message) = parseRequest(line, req)
              var answer, tool, arguments: string
              if code != 0:
                toClient errorResponse(req.id, code, message)
              else:
                case answerMeta(req, toolList, version, ToolNames, answer, tool, arguments)
                of maAnswered:
                  if answer.len > 0: toClient answer
                of maInitialize:
                  if req.params != nil and req.params.kind == JObject: initParams = $req.params
                  toClient answer
                of maToolCall:
                  if not connected():
                    toClient response(req.id, textResult(if refusal.len > 0: refusal
                      else: notRunning(path), isError = true))
                  elif sock.writeAll(line & "\n"):
                    inFlight.add req.id
                  else:
                    lost("viewSEG closed the connection")
                    toClient response(req.id, textResult(notRunning(path), isError = true))
    if sock >= 0: discard posix.close(sock)
    result = 0

proc callOnce*(path, tool, arguments, pngPath: string): int =
  ## Calls `tool` with `arguments` (JSON text) on the program listening on
  ## `path`, prints the answer's text and writes an image it holds to
  ## `pngPath` (when given). Returns 0, 1 for a refused call or an error,
  ## 2 when nothing listens on `path`.
  when defined(windows):
    stderr.writeLine "viewSEG: agent control is not available on Windows in this version"
    result = 2
  else:
    # The arguments are checked here: sent as they are, text that is not one
    # JSON object would be a message the program cannot answer by its id.
    var given = "{}"
    if arguments.strip.len > 0:
      var n: JsonNode
      let why = parseBounded(arguments, n)
      if why.len > 0 or n.kind != JObject:
        stderr.writeLine "viewSEG: the arguments are not a JSON object (",
          (if why.len > 0: why else: "a " & $n.kind), "): ",
          arguments.substr(0, 79).replace("\n", "\\n")
        return 1
      given = $n
    var refusal = ""
    let sock = connectTo(path, refusal)
    if sock < 0:
      stderr.writeLine "viewSEG: ", (if refusal.len > 0: refusal else: notRunning(path))
      return 2
    defer: discard posix.close(sock)
    let request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":" &
      "{\"protocolVersion\":\"" & ProtocolVersions[0] & "\",\"capabilities\":{}," &
      "\"clientInfo\":{\"name\":\"viewSEG --mcp-call\",\"version\":\"1\"}}}\n" &
      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n" &
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":" &
      escapeJson(tool) & ",\"arguments\":" & given & "}}\n"
    if not sock.writeAll(request):
      stderr.writeLine "viewSEG: the connection to ", path, " failed"
      return 2
    var answers = initLineBuffer(MaxAnswerBytes)
    var line = ""
    var got = false
    let deadline = getMonoTime() + CallTimeout
    while not got:
      case answers.next(line)
      of lsLine: got = idOf(line) in ["2", "null"] # null: the program refused the connection
      of lsTooLong:
        stderr.writeLine "viewSEG: the answer is longer than ", MaxAnswerBytes, " bytes"
        return 1
      of lsWaiting:
        var fds = [TPollfd(fd: sock, events: POLLIN)]
        let left = int((deadline - getMonoTime()).inMilliseconds)
        if left <= 0 or poll(addr fds[0], 1, cint(left)) == 0:
          stderr.writeLine "viewSEG: no answer in time"
          return 1
        if not readSome(sock, answers):
          stderr.writeLine "viewSEG: the program closed the connection"
          return 1
    try:
      let n = parseJson(line)
      if n.hasKey("error"):
        stderr.writeLine "viewSEG: ", n["error"]["message"].getStr
        return 1
      let r = n["result"]
      for item in r["content"]:
        case item["type"].getStr
        of "text": echo item["text"].getStr
        of "image":
          let png = decode(item["data"].getStr)
          if pngPath.len > 0:
            writeFile(pngPath, png)
            echo "image: ", pngPath, " (", png.len, " bytes)"
          else:
            echo "image: ", png.len, " bytes (give --png=<file> to keep it)"
        else: discard
      result = if r{"isError"}.getBool: 1 else: 0
    except IOError as e:
      stderr.writeLine "viewSEG: cannot write ", pngPath, ": ", e.msg
      result = 1
    except CatchableError as e:
      stderr.writeLine "viewSEG: the answer is not understood: ", e.msg
      result = 1
