## The part of the Model Context Protocol (MCP) agent control speaks:
## JSON-RPC 2.0 messages, one per line (MCP's stdio framing, used on the
## socket too), the handshake (`initialize`, `ping`) and the tool list.
##
## Everything here reads input that comes from outside the program, so it
## is bounded: a line holds `MaxMessageBytes` at most (`LineBuffer`), JSON is
## nested `MaxDepth` deep at most (checked before `parseJson` sees it), and
## every problem becomes a JSON-RPC error, never an exception to the caller. Nothing here touches the application state.

import std/[json, strutils]

const
  MaxMessageBytes* = 1 shl 20
    ## the longest message a client may send (its line, without the line end)
  MaxDepth* = 64        ## arrays and objects nested deeper than this are refused
  ProtocolVersions* = ["2025-06-18", "2025-03-26", "2024-11-05"]
    ## the MCP revisions understood, newest first: the tools need nothing
    ## that differs between them
  ServerName* = "viewSEG"
  MaxWaitSeconds* = 300 ## the longest a `wait` call may wait

  ParseError* = -32700
  InvalidRequest* = -32600
  MethodNotFound* = -32601
  InvalidParams* = -32602
  InternalError* = -32603
  ServerBusy* = -32000 ## too many calls at once, a call not answered in time, closing

  Instructions* = "viewSEG is a seismic viewer the user is watching while you operate " &
    "it. Read `state` first: the panels (the Seismic window is panel 1), the files, the " &
    "selection. Change what is shown with `command` (the same commands the windows " &
    "issue). Commands that read data (opening, showing another record, sorting, a new " &
    "gain) return at once: call `wait` before `screenshot` or `state` to see their " &
    "result. Every call is written in the program's Messages window. No export or " &
    "other new file is offered; a station move, a sensor and the project's patterns are " &
    "kept in the open project. Options carry their own explanation under `options` " &
    "in `state`."

type
  LineStatus* = enum
    lsWaiting ## no whole line yet
    lsLine    ## a line was taken
    lsTooLong ## more than the limit came without a line end: the stream cannot go on

  LineBuffer* = object
    ## Bytes read from a stream, cut into lines. Holds `limit` bytes of an
    ## unfinished line at most.
    data: string
    start: int ## where the next line begins in `data`
    limit: int

  Request* = object
    ## A JSON-RPC request or notification, as parsed.
    id*: string       ## the request's id as JSON text (`1`, `"a"`); "" for a notification
    meth*: string     ## the method; "" for a message that is not a request (a response)
    params*: JsonNode ## nil when there are none

func initLineBuffer*(limit = MaxMessageBytes): LineBuffer =
  LineBuffer(limit: limit)

proc feed*(b: var LineBuffer; bytes: openArray[char]) =
  ## Adds `bytes` read from the stream.
  if b.start > 0 and b.start * 2 >= b.data.len: # the lines taken so far go
    b.data = b.data.substr(b.start)
    b.start = 0
  let n = b.data.len
  b.data.setLen n + bytes.len
  if bytes.len > 0:
    copyMem(addr b.data[n], addr bytes[0], bytes.len)

proc next*(b: var LineBuffer; line: var string): LineStatus =
  ## Takes the next whole line (without its line end, a `\r` before the `\n`
  ## dropped too) into `line`. `lsTooLong` once more than the limit came with
  ## no line end, or a line is longer than the limit.
  let nl = b.data.find('\n', b.start)
  if nl < 0:
    result = if b.data.len - b.start > b.limit: lsTooLong else: lsWaiting
  else:
    var stop = nl
    if stop > b.start and b.data[stop - 1] == '\r': dec stop
    if stop - b.start > b.limit:
      result = lsTooLong
    else:
      line = b.data.substr(b.start, stop - 1)
      b.start = nl + 1
      result = lsLine

func pending*(b: LineBuffer): int {.inline.} =
  ## Bytes of an unfinished line held.
  b.data.len - b.start

func nestingDepth*(text: string): int =
  ## How deep arrays and objects nest in JSON `text` (strings skipped); a
  ## malformed text gives what its brackets say, which the parser then refuses.
  var depth = 0
  var inString = false
  var escaped = false
  for c in text:
    if inString:
      if escaped: escaped = false
      elif c == '\\': escaped = true
      elif c == '"': inString = false
    else:
      case c
      of '"': inString = true
      of '[', '{':
        inc depth
        result = max(result, depth)
      of ']', '}': dec depth
      else: discard

func hasComment*(text: string): bool =
  ## Whether `text` has a `/` outside its strings: the start of a comment,
  ## which JSON does not have. `parseJson` skips comments, and a quote in
  ## one would hide brackets from `nestingDepth`, so they are refused.
  var inString = false
  var escaped = false
  for c in text:
    if inString:
      if escaped: escaped = false
      elif c == '\\': escaped = true
      elif c == '"': inString = false
    elif c == '"': inString = true
    elif c == '/': return true
  false

proc parseBounded*(text: string; node: var JsonNode): string =
  ## Parses JSON `text` into `node`; "" when it is JSON nested at most
  ## `MaxDepth` deep, else why not.
  result = ""
  if text.hasComment:
    result = "not JSON: a comment (/)"
  elif text.nestingDepth > MaxDepth:
    result = "nested deeper than " & $MaxDepth & " levels"
  else:
    try:
      node = parseJson(text)
    except JsonParsingError as e:
      result = "not JSON: " & e.msg
    except ValueError as e:
      result = "not JSON: " & e.msg
    except IOError as e: # parseJson reads through a stream
      result = "not JSON: " & e.msg
    except OSError as e:
      result = "not JSON: " & e.msg

proc parseRequest*(line: string; req: var Request): tuple[code: int; message: string] =
  ## Parses one message. `code` 0: `req` holds it (a response a client sends
  ## has `meth` ""); else the JSON-RPC error to answer, with `req.id` set
  ## when it could be read.
  req = Request()
  var n: JsonNode
  let problem = parseBounded(line, n)
  if problem.len > 0:
    let code = if problem.startsWith("nested"): InvalidRequest else: ParseError
    return (code, problem)
  if n.kind == JArray:
    return (InvalidRequest, "batches are not supported: send one message per line")
  if n.kind != JObject:
    return (InvalidRequest, "a message is a JSON object")
  let id = n.getOrDefault("id")
  if id != nil:
    case id.kind
    of JInt, JString: req.id = $id
    of JNull: discard
    else: return (InvalidRequest, "an id is a string or an integer")
  let version = n.getOrDefault("jsonrpc")
  if version == nil or version.kind != JString or version.str != "2.0":
    return (InvalidRequest, "\"jsonrpc\" must be \"2.0\"")
  let meth = n.getOrDefault("method")
  if meth == nil:
    if n.hasKey("result") or n.hasKey("error"): return (0, "") # a response: nothing asked
    return (InvalidRequest, "no \"method\"")
  if meth.kind != JString or meth.str.len == 0:
    return (InvalidRequest, "\"method\" is a string")
  req.meth = meth.str
  let params = n.getOrDefault("params")
  if params != nil and params.kind notin {JObject, JArray}:
    return (InvalidRequest, "\"params\" is an object")
  req.params = params
  (0, "")

func response*(id, body: string): string =
  ## A JSON-RPC result line for request `id` (JSON text), `body` being the
  ## result's JSON text.
  "{\"jsonrpc\":\"2.0\",\"id\":" & id & ",\"result\":" & body & "}"

func errorResponse*(id: string; code: int; message: string): string =
  ## A JSON-RPC error line; `id` "" answers a request whose id is unknown.
  "{\"jsonrpc\":\"2.0\",\"id\":" & (if id.len == 0: "null" else: id) &
    ",\"error\":{\"code\":" & $code & ",\"message\":" & escapeJson(message) & "}}"

func textResult*(text: string; isError = false): string =
  ## A tool result holding one text, as JSON text.
  "{\"content\":[{\"type\":\"text\",\"text\":" & escapeJson(text) & "}],\"isError\":" &
    $isError & "}"

func negotiated*(asked: string): string =
  ## The revision to speak with a client that asks for `asked`: that one when
  ## it is understood, else the newest.
  result = ProtocolVersions[0]
  for v in ProtocolVersions:
    if v == asked: result = v

proc initializeResult*(params: JsonNode; version: string): string =
  ## The answer to `initialize`: the revision, what the server offers, who it is.
  var asked = ""
  if params != nil and params.kind == JObject:
    let v = params.getOrDefault("protocolVersion")
    if v != nil and v.kind == JString: asked = v.str
  $(%*{"protocolVersion": negotiated(asked),
    "capabilities": {"tools": {"listChanged": false}},
    "serverInfo": {"name": ServerName, "version": version},
    "instructions": Instructions})

func clientName*(params: JsonNode): string =
  ## "name version" of the client, from `initialize`'s params; "" when not said.
  result = ""
  if params != nil and params.kind == JObject:
    let info = params.getOrDefault("clientInfo")
    if info != nil and info.kind == JObject:
      for key in ["name", "version"]:
        let v = info.getOrDefault(key)
        if v != nil and v.kind == JString and v.str.len > 0:
          if result.len > 0: result.add ' '
          result.add v.str.substr(0, 79)

type
  MetaAnswer* = enum
    maAnswered   ## answered here (`answer`; "" for a notification)
    maToolCall   ## a `tools/call`: `tool` and `arguments` name it
    maInitialize ## answered (`answer`), and it says who the client is

proc answerMeta*(req: Request; toolList, version: string; toolNames: openArray[string];
    answer, tool, arguments: var string): MetaAnswer =
  ## Answers what needs no state: the handshake, `ping`, `tools/list`, unknown
  ## methods, notifications. A `tools/call` of a known tool is handed back as
  ## `maToolCall` with its arguments as JSON text.
  answer = ""
  result = maAnswered
  if req.meth.len == 0 or req.id.len == 0: # a response, or a notification: no answer
    return
  case req.meth
  of "initialize":
    answer = response(req.id, initializeResult(req.params, version))
    result = maInitialize
  of "ping":
    answer = response(req.id, "{}")
  of "tools/list":
    answer = response(req.id, toolList)
  of "tools/call":
    let p = req.params
    let name = if p != nil and p.kind == JObject: p.getOrDefault("name") else: nil
    if name == nil or name.kind != JString:
      answer = errorResponse(req.id, InvalidParams, "tools/call needs the tool's \"name\"")
    elif name.str notin toolNames:
      answer = errorResponse(req.id, InvalidParams, "no tool \"" & name.str.substr(0, 79) &
        "\"; the tools are " & toolNames.join(", "))
    else:
      let args = p.getOrDefault("arguments")
      if args != nil and args.kind notin {JObject, JNull}:
        answer = errorResponse(req.id, InvalidParams, "\"arguments\" is an object")
      else:
        tool = name.str
        arguments = if args == nil or args.kind == JNull: "{}" else: $args
        result = maToolCall
  else:
    answer = errorResponse(req.id, MethodNotFound, "viewSEG offers tools only; no method \"" &
      req.meth.substr(0, 79) & "\"")
