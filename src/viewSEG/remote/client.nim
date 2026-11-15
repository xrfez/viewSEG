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
## Neither opens a window or touches the application state.

import std/[base64, json, monotimes, strutils, times]
import protocol, tools

const
  MaxAnswerBytes* = 32 * 1024 * 1024 ## the longest answer read from the program
  BridgeId = "\"viewSEG-bridge\""    ## the id of the bridge's own `initialize`
  CallTimeout = initDuration(seconds = MaxWaitSeconds + 30)

when not defined(windows):
  import std/posix

  proc connectTo(path: string): cint =
    ## A socket connected to `path`; -1 when nothing listens there.
    result = -1
    if path.len > 0 and path.len < 108:
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      if fd.cint >= 0:
        var a: Sockaddr_un
        a.sun_family = TSa_Family(AF_UNIX)
        copyMem(addr a.sun_path[0], path.cstring, path.len)
        if connect(fd, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) == 0:
          result = fd.cint
        else:
          discard posix.close(fd.cint)

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
    "`viewSEG --mcp` (with the same socket: `--mcp=" & path & "`), or turn on File > " &
    "Agent control in the running program, then call again."

proc bridge*(path, version: string): int =
  ## Serves an MCP client on stdin and stdout until stdin ends (see the
  ## module's documentation). Returns the exit code.
  when defined(windows):
    stderr.writeLine "viewSEG: agent control is not available on Windows in this version"
    result = 1
  else:
    signal(SIGPIPE, SIG_IGN)
    let toolList = toolList()
    var input = initLineBuffer(MaxMessageBytes)
    var answers = initLineBuffer(MaxAnswerBytes)
    var sock: cint = -1
    var initParams = "{}"
    var inFlight: seq[string]
    var line: string
    var open = true

    proc toClient(text: string) =
      stdout.write text
      stdout.write '\n'
      stdout.flushFile()

    proc lost(why: string) =
      if sock >= 0: discard posix.close(sock)
      sock = -1
      answers = initLineBuffer(MaxAnswerBytes)
      for id in inFlight:
        toClient response(id, textResult(why, isError = true))
      inFlight.setLen 0

    proc connected(): bool =
      if sock < 0:
        sock = connectTo(path)
        if sock >= 0 and not sock.writeAll("{\"jsonrpc\":\"2.0\",\"id\":" & BridgeId &
            ",\"method\":\"initialize\",\"params\":" & initParams & "}\n" &
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"):
          lost("viewSEG closed the connection")
      sock >= 0

    while open:
      var fds = @[TPollfd(fd: 0, events: POLLIN)]
      if sock >= 0: fds.add TPollfd(fd: sock, events: POLLIN)
      if poll(addr fds[0], Tnfds(fds.len), -1) < 0 and errno != EINTR:
        open = false
      if fds.len > 1 and (fds[1].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
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
      if (fds[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        if not readSome(0, input): open = false
        var more = true
        while more:
          case input.next(line)
          of lsWaiting: more = false
          of lsTooLong:
            toClient errorResponse("", InvalidRequest, "a message is longer than " &
              $MaxMessageBytes & " bytes")
            open = false
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
                    toClient response(req.id, textResult(notRunning(path), isError = true))
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
    let sock = connectTo(path)
    if sock < 0:
      stderr.writeLine "viewSEG: ", notRunning(path)
      return 2
    defer: discard posix.close(sock)
    let request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":" &
      "{\"protocolVersion\":\"" & ProtocolVersions[0] & "\",\"capabilities\":{}," &
      "\"clientInfo\":{\"name\":\"viewSEG --mcp-call\",\"version\":\"1\"}}}\n" &
      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n" &
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":" &
      escapeJson(tool) & ",\"arguments\":" & (if arguments.strip.len == 0: "{}"
      else: arguments) & "}}\n"
    if not sock.writeAll(request):
      stderr.writeLine "viewSEG: the connection to ", path, " failed"
      return 2
    var answers = initLineBuffer(MaxAnswerBytes)
    var line = ""
    var got = false
    let deadline = getMonoTime() + CallTimeout
    while not got:
      case answers.next(line)
      of lsLine: got = idOf(line) == "2"
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
