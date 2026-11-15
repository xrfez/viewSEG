## A plain MCP client for tests of agent control: a blocking connection to
## the socket, one JSON-RPC message per line, every read with a deadline.

import std/[json, monotimes, posix, strutils, times]

type
  AgentClient* = object
    fd*: cint
    buffer: string
    next: int ## the next request's id

proc connectAgent*(path: string): AgentClient =
  ## A connection to the socket at `path`; `fd` -1 when nothing listens.
  result = AgentClient(fd: -1, next: 1)
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  var a: Sockaddr_un
  a.sun_family = TSa_Family(AF_UNIX)
  copyMem(addr a.sun_path[0], path.cstring, min(path.len, a.sun_path.len - 1))
  if connect(fd, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) == 0: result.fd = fd.cint
  else: discard close(fd.cint)

proc close*(c: var AgentClient) =
  if c.fd >= 0: discard posix.close(c.fd)
  c.fd = -1

proc sendRaw*(c: AgentClient; text: string): bool =
  ## Writes `text` as it is; false when the connection is gone.
  var sent = 0
  while sent < text.len:
    let n = send(SocketHandle(c.fd), addr text[sent], text.len - sent, MSG_NOSIGNAL)
    if n <= 0: return false
    sent += n
  true

proc readLine*(c: var AgentClient; timeout = initDuration(seconds = 30)): string =
  ## The next line the server writes; "" when the connection ends or the
  ## time is up.
  let deadline = getMonoTime() + timeout
  var buf = newString(65536)
  while '\n' notin c.buffer:
    let left = (deadline - getMonoTime()).inMicroseconds
    var fds = [TPollfd(fd: c.fd, events: POLLIN)]
    if left < 0 or poll(addr fds[0], 1, cint((left + 999) div 1000)) <= 0: return ""
    let n = recv(SocketHandle(c.fd), addr buf[0], buf.len, 0)
    if n <= 0: return ""
    c.buffer.add buf.substr(0, n - 1)
  let nl = c.buffer.find('\n')
  result = c.buffer.substr(0, nl - 1)
  c.buffer = c.buffer.substr(nl + 1)

proc request*(c: var AgentClient; meth: string; params: JsonNode;
    timeout = initDuration(seconds = 30)): JsonNode =
  ## Sends a request and returns its response (other lines are passed by);
  ## nil when none came.
  let id = c.next
  inc c.next
  var msg = %*{"jsonrpc": "2.0", "id": id, "method": meth}
  if params != nil: msg["params"] = params
  if not c.sendRaw($msg & "\n"): return nil
  while true:
    let line = c.readLine(timeout)
    if line.len == 0: return nil
    let n = parseJson(line)
    if n{"id"}.getInt(-1) == id: return n

proc initialize*(c: var AgentClient; name = "test client"): JsonNode =
  result = c.request("initialize", %*{"protocolVersion": "2025-06-18", "capabilities": {},
    "clientInfo": {"name": name, "version": "1"}})
  discard c.sendRaw("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n")

proc call*(c: var AgentClient; tool: string; arguments: JsonNode = newJObject();
    timeout = initDuration(seconds = 60)): JsonNode =
  ## Calls `tool`; its result (`content`, `isError`), or the whole response
  ## when it is an error; nil when none came.
  let r = c.request("tools/call", %*{"name": tool, "arguments": arguments}, timeout)
  if r == nil: nil
  elif r.hasKey("result"): r["result"]
  else: r

func text*(r: JsonNode): string =
  ## The first text of a tool result; "" when it has none.
  result = ""
  if r != nil and r.hasKey("content"):
    for item in r["content"]:
      if item{"type"}.getStr == "text": return item["text"].getStr

func failed*(r: JsonNode): bool =
  ## Whether a tool result is an error (or no result came).
  r == nil or r.hasKey("error") or r{"isError"}.getBool
