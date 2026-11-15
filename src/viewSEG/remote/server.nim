## The agent server: a thread of its own that listens on a Unix-domain
## socket, takes MCP clients, frames and parses what they send, answers the
## handshake and the tool list itself, and queues tool calls for the UI
## thread, which answers them at a frame boundary (`remote/control`). It
## never reads or changes the application state.
##
## The UI thread and this one share a `Hub`: a lock over the calls going to
## the UI, the answers coming back and the events (a client connected, said
## who it is, went), and a pipe whose read end this thread polls, so an
## answer is written out at once. Only strings cross; each side parses what
## it uses.
##
## Bounds (docs/architecture.md, "Agent control"): `MaxClients` clients,
## `MaxMessageBytes` a message, `MaxInFlight` calls in flight per client,
## `MaxUnsent` bytes of answers a client has not read, a deadline per call
## (`CallPatience`; a `wait` its own time and `WaitSlack`), after which the
## call is answered with an error and a late answer dropped.
##
## Safety: the socket is made with mode 0600 (its owner only); on Linux a
## client must run as the program's user (`SO_PEERCRED`). A socket left by a
## run that ended without removing it is replaced; one another program
## listens on is left alone; a path that is not a socket is never removed.

import std/[json, monotimes, strutils, times]
import ../core/threads
import protocol, tools

const
  MaxClients* = 4
  MaxInFlight* = 16                          ## calls a client may have unanswered
  MaxUnsent* = 64 * 1024 * 1024              ## bytes of answers waiting for a client to read them
  MaxEvents = 256                            ## events kept for the UI thread; the rest are counted
  CallPatience* = initDuration(seconds = 60) ## a call's answer comes within this, or an error
  WaitSlack* = initDuration(seconds = 10)    ## a `wait`'s deadline: its own time and this

type
  Call* = object
    ## A tool call, for the UI thread to answer.
    client*: int       ## the connection it came on, from 1
    serial*: int       ## its number, from 1: `answer` names it
    tool*: string
    arguments*: string ## JSON text of an object
    received*: MonoTime

  EventKind* = enum
    ekConnected = "connected"
    ekIdentified = "identified" ## `initialize` said who the client is (`text`)
    ekDisconnected = "disconnected"
    ekRefused = "refused"       ## a connection or a message refused (`text` says why)

  Event* = object
    kind*: EventKind
    client*: int
    text*: string

when not defined(windows):
  import std/[locks, os, posix]

  type
    Answer = object
      serial: int
      text: string
      picture: Picture ## a screenshot to scale and encode here, off the UI thread

    HubObj = object
      lock: Lock
      calls: seq[Call]
      answers: seq[Answer]
      events: seq[Event]
      droppedEvents: int
      clients: int    ## connected now
      stopping: bool
      wakeWrite: cint ## written to after answers are queued, and to stop
      thread: Thread[ServerArg]

    ServerArg = object
      hub: ptr HubObj
      listener, wakeRead: cint
      toolList, version: string
      toolNames: seq[string]
      encode: PngEncoder

    InFlight = object
      serial: int
      id: string ## the request's id, JSON text
      deadline: MonoTime

    Client = object
      fd: cint
      number: int
      input: LineBuffer
      output: string
      sent: int     ## bytes of `output` written
      inFlight: seq[InFlight]
      closing: bool ## closed once `output` is written

  proc addEvent(hub: ptr HubObj; e: sink Event) =
    withLock hub.lock:
      if hub.events.len < MaxEvents: hub.events.add e
      else: inc hub.droppedEvents

  proc nonBlocking(fd: cint) =
    discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)
    discard fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) or FD_CLOEXEC)

  when defined(linux):
    var SO_PEERCRED {.importc, header: "<sys/socket.h>".}: cint
    const SendFlags = MSG_NOSIGNAL
  else:
    proc getpeereid(fd: cint; uid: var Uid; gid: var Gid): cint {.importc,
      header: "<unistd.h>".}
    const SendFlags = 0.cint

  proc peerUid(fd: cint): int =
    ## The user id of the process at the other end of `fd`; -1 when unknown.
    result = -1
    when defined(linux):
      var cred: array[3, int32] # struct ucred: pid, uid, gid
      var size = SockLen(sizeof(cred))
      if getsockopt(SocketHandle(fd), SOL_SOCKET, SO_PEERCRED, addr cred, addr size) == 0:
        result = int(cred[1])
    else:
      var uid: Uid
      var gid: Gid
      if getpeereid(fd, uid, gid) == 0: result = int(uid)

  proc sendNow(c: var Client): bool =
    ## Writes what it can of `c.output`; false when the connection failed.
    result = true
    while c.sent < c.output.len:
      let n = send(SocketHandle(c.fd), addr c.output[c.sent], c.output.len - c.sent, SendFlags)
      if n > 0:
        c.sent += n
      else:
        let e = errno
        if n < 0 and (e == EAGAIN or e == EWOULDBLOCK or e == EINTR):
          return true
        return false
    c.output.setLen 0
    c.sent = 0

  proc queue(c: var Client; line: string) =
    if not c.closing:
      c.output.add line
      c.output.add '\n'

  func waitDeadline(arguments: JsonNode): Duration =
    ## How long a `wait` call may take before the server gives up on it.
    var seconds = 30
    if arguments != nil and arguments.kind == JObject:
      let t = arguments.getOrDefault("timeout")
      if t != nil and t.kind == JInt: seconds = int(clamp(t.num, 0, MaxWaitSeconds))
      elif t != nil and t.kind == JFloat and t.fnum == t.fnum:
        seconds = int(clamp(t.fnum, 0.0, float(MaxWaitSeconds))) + 1
    initDuration(seconds = seconds) + WaitSlack

  proc handle(arg: ServerArg; c: var Client; line: string; serial: var int) =
    ## Answers one message, or queues its tool call for the UI thread.
    var req: Request
    let (code, message) = parseRequest(line, req)
    if code != 0:
      c.queue errorResponse(req.id, code, message)
      arg.hub.addEvent Event(kind: ekRefused, client: c.number, text: message)
      return
    var answer, tool, arguments: string
    case answerMeta(req, arg.toolList, arg.version, arg.toolNames, answer, tool, arguments)
    of maAnswered:
      if answer.len > 0: c.queue answer
    of maInitialize:
      c.queue answer
      arg.hub.addEvent Event(kind: ekIdentified, client: c.number, text: clientName(req.params))
    of maToolCall:
      if c.inFlight.len >= MaxInFlight:
        c.queue errorResponse(req.id, ServerBusy, "more than " & $MaxInFlight &
          " calls at once: wait for the answers")
      else:
        inc serial
        let now = getMonoTime()
        let patience = if tool == "wait": waitDeadline(req.params.getOrDefault("arguments"))
                       else: CallPatience
        c.inFlight.add InFlight(serial: serial, id: req.id, deadline: now + patience)
        withLock arg.hub.lock:
          arg.hub.calls.add Call(client: c.number, serial: serial, tool: tool,
            arguments: arguments, received: now)

  proc closeClient(hub: ptr HubObj; c: var Client; why: string) =
    discard posix.close(c.fd)
    c.fd = -1
    withLock hub.lock: dec hub.clients
    hub.addEvent Event(kind: ekDisconnected, client: c.number, text: why)

  proc accepted(arg: ServerArg; clients: var seq[Client]; number: var int) =
    ## Takes the connections waiting, refusing those of another user and
    ## those beyond `MaxClients`.
    while true:
      let fd = cint(accept(SocketHandle(arg.listener), nil, nil))
      if fd < 0: return
      nonBlocking(fd)
      inc number
      let uid = peerUid(fd)
      var c = Client(fd: fd, number: number, input: initLineBuffer())
      if uid >= 0 and uid != int(getuid()):
        c.queue errorResponse("", InvalidRequest, "this viewSEG takes agents of its own user only")
        discard c.sendNow()
        discard posix.close(fd)
        arg.hub.addEvent Event(kind: ekRefused, client: number,
          text: "a connection from another user (id " & $uid & ") was refused")
      elif clients.len >= MaxClients:
        c.queue errorResponse("", ServerBusy, $MaxClients & " agents are connected already")
        discard c.sendNow()
        discard posix.close(fd)
        arg.hub.addEvent Event(kind: ekRefused, client: number,
          text: "a connection was refused: " & $MaxClients & " agents are connected already")
      else:
        clients.add move c
        withLock arg.hub.lock: inc arg.hub.clients
        arg.hub.addEvent Event(kind: ekConnected, client: number)

  proc serve(arg: ServerArg) {.thread.} =
    markWorkerThread()
    var clients: seq[Client]
    var number, serial = 0
    var buf = newString(64 * 1024)
    var answers: seq[Answer]
    var fds: seq[TPollfd]
    while true:
      fds.setLen 0
      fds.add TPollfd(fd: arg.wakeRead, events: POLLIN)
      fds.add TPollfd(fd: arg.listener, events: POLLIN)
      let now = getMonoTime()
      var timeout = 1000
      for c in clients:
        var events: cshort = 0
        if not c.closing: events = events or POLLIN
        if c.output.len > c.sent: events = events or POLLOUT
        fds.add TPollfd(fd: c.fd, events: events)
        for f in c.inFlight:
          timeout = min(timeout, max(0, int((f.deadline - now).inMilliseconds) + 1))
      discard poll(addr fds[0], Tnfds(fds.len), cint(timeout))
      if (fds[0].revents and POLLIN) != 0:
        while read(arg.wakeRead, addr buf[0], buf.len) > 0: discard
      var stopping = false
      withLock arg.hub.lock:
        stopping = arg.hub.stopping
        swap(answers, arg.hub.answers)
      if stopping: break
      for a in answers.mitems:
        if a.picture.shot.width > 0: a.text = pictureAnswer(a.picture, arg.encode)
        for c in clients.mitems:
          for i in countdown(c.inFlight.high, 0):
            if c.inFlight[i].serial == a.serial:
              c.queue response(c.inFlight[i].id, a.text)
              c.inFlight.delete i
      answers.setLen 0
      let later = getMonoTime()
      for c in clients.mitems:
        for i in countdown(c.inFlight.high, 0):
          if c.inFlight[i].deadline <= later:
            c.queue errorResponse(c.inFlight[i].id, ServerBusy,
              "viewSEG did not answer in time (is its window minimized, or busy?)")
            c.inFlight.delete i
      if (fds[1].revents and POLLIN) != 0:
        arg.accepted(clients, number)
      for k, c in clients.mpairs:
        let revents = if k + 2 < fds.len: fds[k + 2].revents else: 0
        if (revents and (POLLIN or POLLHUP or POLLERR)) != 0 and not c.closing:
          let n = recv(SocketHandle(c.fd), addr buf[0], buf.len, 0)
          if n > 0:
            c.input.feed(buf.toOpenArray(0, n - 1))
            var line: string
            var more = true
            while more and not c.closing:
              case c.input.next(line)
              of lsWaiting: more = false
              of lsLine:
                if line.strip.len > 0: arg.handle(c, line, serial)
              of lsTooLong:
                c.queue errorResponse("", InvalidRequest, "a message is longer than " &
                  $MaxMessageBytes & " bytes; the connection is closed")
                arg.hub.addEvent Event(kind: ekRefused, client: c.number,
                  text: "a message longer than " & $MaxMessageBytes & " bytes")
                c.closing = true
          elif n == 0 or (errno != EAGAIN and errno != EWOULDBLOCK and errno != EINTR):
            c.closing = true
            c.output.setLen 0 # nobody reads it
            c.sent = 0
      for c in clients.mitems:
        if c.fd >= 0:
          if not c.sendNow():
            arg.hub.closeClient(c, "the connection failed")
          elif c.output.len - c.sent > MaxUnsent:
            arg.hub.closeClient(c, "it did not read its answers")
          elif c.closing and c.output.len == 0:
            arg.hub.closeClient(c, "")
      var k = 0
      while k < clients.len:
        if clients[k].fd < 0: clients.delete k
        else: inc k
    for c in clients.mitems:
      for f in c.inFlight:
        c.queue errorResponse(f.id, ServerBusy, "viewSEG is closing")
      discard c.sendNow()
      arg.hub.closeClient(c, "viewSEG is closing")
    clearCycleRoots()

type
  Server* = object
    ## The UI thread's handle on a running server. Move-only; destroying it
    ## stops the server.
    when not defined(windows):
      hub: ptr HubObj
      listener, wakeRead: cint
      device, inode: uint64 ## the socket's, to remove only that one
    path: string

when not defined(windows):
  proc shutDown(hub: ptr HubObj; listener, wakeRead: cint; path: string;
      device, inode: uint64) =
    withLock hub.lock: hub.stopping = true
    var b = 's'
    discard write(hub.wakeWrite, addr b, 1)
    joinThread(hub.thread)
    discard posix.close(listener)
    discard posix.close(wakeRead)
    discard posix.close(hub.wakeWrite)
    var st: Stat
    if lstat(path.cstring, st) == 0 and uint64(st.st_dev) == device and
        uint64(st.st_ino) == inode:
      discard unlink(path.cstring)
    deinitLock hub.lock
    `=destroy`(hub[])
    deallocShared hub

  proc stop*(s: var Server) =
    ## Disconnects the clients, stops the thread and removes the socket.
    ## Does nothing on a server that is not running.
    if s.hub != nil:
      shutDown(s.hub, s.listener, s.wakeRead, s.path, s.device, s.inode)
      s.hub = nil

  proc `=destroy`*(s: Server) =
    if s.hub != nil:
      shutDown(s.hub, s.listener, s.wakeRead, s.path, s.device, s.inode)
    `=destroy`(s.path)

  proc `=wasMoved`*(s: var Server) =
    s.hub = nil
    wasMoved(s.path) # not an assignment: that would free what was moved away

else:
  proc stop*(s: var Server) = discard

proc `=copy`*(dest: var Server; src: Server) {.error.}
proc `=dup`*(src: Server): Server {.error.}

func running*(s: Server): bool =
  ## Whether the server listens.
  when defined(windows): false
  else: s.hub != nil

func path*(s: Server): lent string {.inline.} =
  ## The socket's path.
  s.path

const SocketNameLimit* = 107
  ## the longest socket path the system takes (`sun_path`, less its end)

when not defined(windows):
  proc listening(path: string): bool =
    ## Whether a program accepts connections on the socket at `path`.
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd.cint < 0: return true # cannot tell: assume so, and leave it
    nonBlocking(fd.cint)
    var a: Sockaddr_un
    a.sun_family = TSa_Family(AF_UNIX)
    copyMem(addr a.sun_path[0], path.cstring, path.len)
    let r = connect(fd, cast[ptr SockAddr](addr a), SockLen(sizeof(a)))
    let e = errno
    discard posix.close(fd.cint)
    r == 0 or e == EAGAIN or e == EINPROGRESS

proc startServer*(path, toolList, version: string; toolNames: seq[string];
    encode: PngEncoder = nil): (Server, string) =
  ## A server listening on a socket at `path`, answering with `toolList` (the
  ## JSON text `tools/list` returns) for `toolNames`, encoding screenshots
  ## with `encode`; "" when it started, else why not, in plain words.
  result = (Server(path: path), "")
  when defined(windows):
    result[1] = "agent control is not available on Windows in this version"
  else:
    if path.len == 0:
      return (result[0], "no socket path was given")
    if path.len > SocketNameLimit:
      return (result[0], "the socket path " & path & " is longer than the " &
        $SocketNameLimit & " bytes a socket's name may have; give a shorter one with --mcp=<path>")
    let dir = path.parentDir
    if dir.len > 0 and not dirExists(dir):
      try:
        createDir(dir)
        setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
      except OSError as e:
        return (result[0], "cannot make the folder " & dir & ": " & e.msg)
    var st: Stat
    if lstat(path.cstring, st) == 0:
      if not S_ISSOCK(st.st_mode):
        return (result[0], path & " exists and is not a socket; it is left as it is")
      if listening(path):
        return (result[0], "another program listens on " & path &
          " (another viewSEG with agent control on?)")
      discard unlink(path.cstring) # left by a run that ended without removing it
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd.cint < 0:
      return (result[0], "cannot make a socket: " & $strerror(errno))
    var a: Sockaddr_un
    a.sun_family = TSa_Family(AF_UNIX)
    copyMem(addr a.sun_path[0], path.cstring, path.len)
    # Made with the umask's mode (other users cannot write it, so cannot
    # connect), then narrowed to the owner before anybody may connect.
    if bindSocket(fd, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) != 0:
      let why = $strerror(errno)
      discard posix.close(fd.cint)
      return (result[0], "cannot make the socket " & path & ": " & why)
    if chmod(path.cstring, Mode(0o600)) != 0 or listen(fd, 8) != 0 or
        lstat(path.cstring, st) != 0:
      let why = $strerror(errno)
      discard posix.close(fd.cint)
      discard unlink(path.cstring)
      return (result[0], "cannot listen on " & path & ": " & why)
    nonBlocking(fd.cint)
    var wake: array[2, cint]
    if pipe(wake) != 0:
      let why = $strerror(errno)
      discard posix.close(fd.cint)
      discard unlink(path.cstring)
      return (result[0], "cannot make a pipe: " & why)
    nonBlocking(wake[0])
    nonBlocking(wake[1])
    let hub = cast[ptr HubObj](allocShared0(sizeof(HubObj)))
    initLock hub.lock
    hub.wakeWrite = wake[1]
    result[0].hub = hub
    result[0].listener = fd.cint
    result[0].wakeRead = wake[0]
    result[0].device = uint64(st.st_dev)
    result[0].inode = uint64(st.st_ino)
    createThread(hub.thread, serve, ServerArg(hub: hub, listener: fd.cint,
      wakeRead: wake[0], toolList: toolList, version: version, toolNames: toolNames,
      encode: encode))

proc takeCalls*(s: Server; calls: var seq[Call]; events: var seq[Event]) =
  ## Moves the calls and events queued since the last call into `calls` and
  ## `events` (emptied first). Never waits beyond the lock's swap.
  calls.setLen 0
  events.setLen 0
  when not defined(windows):
    if s.hub == nil: return
    var dropped = 0
    withLock s.hub.lock:
      swap(calls, s.hub.calls)
      swap(events, s.hub.events)
      dropped = s.hub.droppedEvents
      s.hub.droppedEvents = 0
    if dropped > 0:
      events.add Event(kind: ekRefused, text: $dropped & " more events were not kept")

proc answer*(s: Server; serial: int; result: sink string) =
  ## Sends `result` (a tool result, JSON text) as the answer to call `serial`.
  when not defined(windows):
    if s.hub == nil: return
    withLock s.hub.lock:
      s.hub.answers.add Answer(serial: serial, text: result)
    var b = 'a'
    discard write(s.hub.wakeWrite, addr b, 1)

proc answerPicture*(s: Server; serial: int; picture: sink Picture) =
  ## Answers call `serial` with `picture`, which the server thread scales
  ## down and encodes (`pictureAnswer`).
  when not defined(windows):
    if s.hub == nil: return
    withLock s.hub.lock:
      s.hub.answers.add Answer(serial: serial, picture: picture)
    var b = 'a'
    discard write(s.hub.wakeWrite, addr b, 1)

proc clients*(s: Server): int =
  ## How many clients are connected now.
  when not defined(windows):
    if s.hub != nil:
      withLock s.hub.lock: result = s.hub.clients
