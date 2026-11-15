## Whether a tray icon can be seen (`platform/trayhost`), asked of real
## session buses: none at all, one that is not there, a bus of the test's
## own without a StatusNotifier watcher, with a watcher that has no host,
## and with one that has: only the last is a tray. The bus is `dbus-daemon`
## on a socket in the test's folder and the watcher a thread of the test's
## (`utils/fakewatcher`); without `dbus-daemon` those parts are skipped.
##
## Seen to fail: with the answer's boolean not read (`registered` left 0),
## "a watcher with a host: the desktop's bar shows no tray icons (a
## StatusNotifier watcher, but no host)".

import std/[os, strutils, tempfiles]
import viewSEG/platform/trayhost
import utils/fakewatcher

when defined(windows) or defined(macosx):
  doAssert probeTrayHost() == thPresent
  echo "ttrayhost: ok (the notification area is always there)"
else:
  let dir = createTempDir("viewSEG-ttrayhost-", "")
  try:
    doAssert probeTrayHost("") == thNoBus
    # The address: the environment's, else the runtime folder's socket.
    let (busEnv, runtimeEnv) = (getEnv("DBUS_SESSION_BUS_ADDRESS"), getEnv("XDG_RUNTIME_DIR"))
    putEnv("DBUS_SESSION_BUS_ADDRESS", "")
    putEnv("XDG_RUNTIME_DIR", dir)
    doAssert sessionBusAddress() == "", "a bus in an empty runtime folder"
    doAssert probeTrayHost() == thNoBus
    putEnv("DBUS_SESSION_BUS_ADDRESS", "unix:path=" & dir / "nothing")
    doAssert sessionBusAddress() == "unix:path=" & dir / "nothing"
    let gone = probeTrayHost(timeoutMs = 500)
    doAssert gone == thBusFailed, "a bus that is not there: " & $gone
    putEnv("DBUS_SESSION_BUS_ADDRESS", busEnv)
    putEnv("XDG_RUNTIME_DIR", runtimeEnv)

    let bus = startBus(dir)
    if bus.address.len == 0:
      echo "ttrayhost: the bus parts are skipped (no dbus-daemon)"
    else:
      try:
        let none = probeTrayHost(bus.address)
        doAssert none == thNoWatcher, "a bus with no watcher: " & $none
        doAssert startWatcher(bus.address, host = false), "the watcher did not start"
        let noHost = probeTrayHost(bus.address)
        doAssert noHost == thNoHost, "a watcher with no host: " & $noHost
        stopWatcher()
        doAssert startWatcher(bus.address, host = true), "the watcher did not start again"
        let host = probeTrayHost(bus.address)
        doAssert host == thPresent, "a watcher with a host: " & $host
        stopWatcher()
        doAssert "no tray icons" in $thNoWatcher and "no tray icons" in $thNoHost
      finally:
        stopWatcher()
        stopBus(bus)
  finally:
    removeDir(dir)
  echo "ttrayhost: ok"
