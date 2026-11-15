## A D-Bus session bus of a test's own, and a StatusNotifier watcher on it
## that says whether a host is registered, so that `platform/trayhost` and
## the tray can be tried as a desktop with a tray bar, or without one, would
## have them. The bus is `dbus-daemon --session` on a socket in the test's
## folder (`startBus`, `stopBus`: its own process); the watcher is a thread with a
## private libdbus connection that owns `org.kde.StatusNotifierWatcher`,
## answers `Get` of `IsStatusNotifierHostRegistered` with `host`, and answers
## every other method call (AppIndicator's `RegisterStatusNotifierItem`)
## with an empty return.

import std/[atomics, os, osproc, streams, strutils]
import viewSEG/platform/trayhost

type
  TestBus* = object
    address*: string ## "" when no bus could be started (no dbus-daemon)
    process: Process

  WatcherArgs = object
    address: string
    host: bool

var
  watcherThread: Thread[WatcherArgs]
  watcherStop: Atomic[bool]
  watcherReady: Atomic[int] ## 0 starting, 1 owns the name, 2 failed
  watcherRunning = false

proc startBus*(dir: string): TestBus =
  ## A session bus listening at `dir/bus`; `address` "" when `dbus-daemon`
  ## is not installed or does not start.
  result = TestBus()
  if findExe("dbus-daemon").len == 0: return
  # In the foreground (not --fork, whose child would hold the pipe open):
  # it prints its address once it listens.
  let p = startProcess("dbus-daemon", args = ["--session", "--nofork",
    "--address=unix:path=" & dir / "bus", "--print-address=1"], options = {poUsePath})
  var line = ""
  if p.outputStream.readLine(line) and line.startsWith("unix:"):
    result = TestBus(address: line.strip, process: p)
  else:
    p.terminate()
    discard p.waitForExit()
    p.close()

proc stopBus*(bus: TestBus) =
  ## Ends the bus (its own process, by its handle).
  if bus.process != nil:
    bus.process.terminate()
    discard bus.process.waitForExit()
    bus.process.close()

proc serve(args: WatcherArgs) {.thread.} =
  var api: DbusApi
  if not loadDbus(api):
    watcherReady.store 2
    return
  discard api.threadsInitDefault()
  var err: DbusError
  api.errorInit(addr err)
  let conn = api.openPrivate(args.address.cstring, addr err)
  if conn == nil or api.busRegister(conn, addr err) == 0 or
      api.requestName(conn, WatcherName, 4, addr err) != 1: # DO_NOT_QUEUE; 1 = primary owner
    api.errorFree(addr err)
    watcherReady.store 2
    return
  watcherReady.store 1
  while not watcherStop.load:
    discard api.readWrite(conn, 20)
    while true:
      let msg = api.popMessage(conn)
      if msg == nil: break
      if api.isMethodCall(msg, PropertiesInterface, "Get") != 0:
        let reply = api.newMethodReturn(msg)
        var it, sub: DbusIter
        api.iterInitAppend(reply, addr it)
        var value = if args.host: 1'u32 else: 0'u32
        discard api.iterOpen(addr it, DbusTypeVariant, "b", addr sub)
        discard api.iterAppendBasic(addr sub, DbusTypeBoolean, addr value)
        discard api.iterClose(addr it, addr sub)
        discard api.send(conn, reply, nil)
        api.messageUnref(reply)
      elif api.isMethodCall(msg, WatcherName, "RegisterStatusNotifierItem") != 0:
        let reply = api.newMethodReturn(msg)
        discard api.send(conn, reply, nil)
        api.messageUnref(reply)
      api.messageUnref(msg)
    api.flush(conn)
  api.close(conn)
  api.unref(conn)

proc startWatcher*(address: string; host: bool): bool =
  ## A watcher on the bus at `address`, saying `host` for
  ## `IsStatusNotifierHostRegistered`; true once it owns its name.
  watcherStop.store false
  watcherReady.store 0
  createThread(watcherThread, serve, WatcherArgs(address: address, host: host))
  watcherRunning = true
  for _ in 0 ..< 5000:
    if watcherReady.load != 0: break
    sleep 1
  watcherReady.load == 1

proc stopWatcher*() =
  if watcherRunning:
    watcherStop.store true
    joinThread(watcherThread)
    watcherRunning = false
