## Whether a tray icon can be seen at all. On Windows (and macOS) the
## notification area is always there. On Linux a tray icon is a
## StatusNotifier item: it shows only when the desktop's bar runs a
## StatusNotifier host, which registers with the watcher
## `org.kde.StatusNotifierWatcher` on the D-Bus session bus (waybar, KDE,
## GNOME with the AppIndicator extension). SDL makes its tray whatever the
## desktop has, so a program that hid its window "in the tray" of a desktop
## without a host would leave it with no way back. `probeTrayHost` asks the
## session bus whether the watcher is there and has a host
## (`IsStatusNotifierHostRegistered`).
##
## libdbus is loaded at run time (`libdbus-1.so.3`, on every Linux desktop):
## no build dependency, and none at all where it is missing. The bus is
## reached at the address its environment gives
## (`DBUS_SESSION_BUS_ADDRESS`, else `$XDG_RUNTIME_DIR/bus`), on a private
## connection that is closed again, never by starting a bus
## (`dbus-launch`). The call takes milliseconds; `timeoutMs` bounds it when
## the bus does not answer, so run it off the UI thread.
##
## The raw calls (`DbusApi`) are exported for tests, which stand up their
## own watcher on a bus of their own.

import std/[dynlib, os]

type
  TrayHost* = enum
    ## What the session bus says about a tray here.
    thPresent = "a StatusNotifier host shows tray icons"
    thNoBus = "there is no D-Bus session bus"
    thNoLibDbus = "libdbus-1 is not installed, so the session bus cannot be asked"
    thBusFailed = "the D-Bus session bus did not answer"
    thNoWatcher = "the desktop's bar shows no tray icons (no StatusNotifier watcher " &
      "on the session bus)"
    thNoHost = "the desktop's bar shows no tray icons (a StatusNotifier watcher, but no " &
      "host)"

  DbusError* {.bycopy.} = object
    ## `DBusError`: two pointers, a bit field and a pointer (32 bytes); more
    ## room kept.
    name*, message*: cstring
    rest: array[6, uint64]

  DbusIter* {.bycopy.} = object
    ## `DBusMessageIter` (72 bytes on 64-bit systems), opaque; more room kept.
    data: array[16, uint64]

  DbusApi* = object
    ## The libdbus functions used here and by the tests' watcher.
    errorInit*: proc (e: ptr DbusError) {.cdecl, gcsafe, raises: [].}
    errorFree*: proc (e: ptr DbusError) {.cdecl, gcsafe, raises: [].}
    errorIsSet*: proc (e: ptr DbusError): uint32 {.cdecl, gcsafe, raises: [].}
    threadsInitDefault*: proc (): uint32 {.cdecl, gcsafe, raises: [].}
    openPrivate*: proc (address: cstring; e: ptr DbusError): pointer {.cdecl, gcsafe,
      raises: [].}
    busRegister*: proc (conn: pointer; e: ptr DbusError): uint32 {.cdecl, gcsafe, raises: [].}
    close*: proc (conn: pointer) {.cdecl, gcsafe, raises: [].}
    unref*: proc (conn: pointer) {.cdecl, gcsafe, raises: [].}
    newMethodCall*: proc (dest, path, iface, meth: cstring): pointer {.cdecl, gcsafe,
      raises: [].}
    newMethodReturn*: proc (call: pointer): pointer {.cdecl, gcsafe, raises: [].}
    setAutoStart*: proc (msg: pointer; on: uint32) {.cdecl, gcsafe, raises: [].}
    messageUnref*: proc (msg: pointer) {.cdecl, gcsafe, raises: [].}
    iterInitAppend*: proc (msg: pointer; it: ptr DbusIter) {.cdecl, gcsafe, raises: [].}
    iterAppendBasic*: proc (it: ptr DbusIter; kind: cint; value: pointer): uint32 {.cdecl,
      gcsafe, raises: [].}
    iterOpen*: proc (it: ptr DbusIter; kind: cint; signature: cstring;
      sub: ptr DbusIter): uint32 {.cdecl, gcsafe, raises: [].}
    iterClose*: proc (it, sub: ptr DbusIter): uint32 {.cdecl, gcsafe, raises: [].}
    iterInit*: proc (msg: pointer; it: ptr DbusIter): uint32 {.cdecl, gcsafe, raises: [].}
    iterArgType*: proc (it: ptr DbusIter): cint {.cdecl, gcsafe, raises: [].}
    iterRecurse*: proc (it, sub: ptr DbusIter) {.cdecl, gcsafe, raises: [].}
    iterGetBasic*: proc (it: ptr DbusIter; value: pointer) {.cdecl, gcsafe, raises: [].}
    sendWithReplyAndBlock*: proc (conn, msg: pointer; timeoutMs: cint;
      e: ptr DbusError): pointer {.cdecl, gcsafe, raises: [].}
    send*: proc (conn, msg: pointer; serial: pointer): uint32 {.cdecl, gcsafe, raises: [].}
    flush*: proc (conn: pointer) {.cdecl, gcsafe, raises: [].}
    readWrite*: proc (conn: pointer; timeoutMs: cint): uint32 {.cdecl, gcsafe, raises: [].}
    popMessage*: proc (conn: pointer): pointer {.cdecl, gcsafe, raises: [].}
    isMethodCall*: proc (msg: pointer; iface, meth: cstring): uint32 {.cdecl, gcsafe,
      raises: [].}
    requestName*: proc (conn: pointer; name: cstring; flags: uint32;
      e: ptr DbusError): cint {.cdecl, gcsafe, raises: [].}

const
  DbusTypeBoolean* = cint('b')
  DbusTypeString* = cint('s')
  DbusTypeVariant* = cint('v')
  WatcherName* = "org.kde.StatusNotifierWatcher"
  WatcherPath* = "/StatusNotifierWatcher"
  PropertiesInterface* = "org.freedesktop.DBus.Properties"
  HostRegistered* = "IsStatusNotifierHostRegistered"

proc loadDbus*(api: var DbusApi): bool =
  ## Fills `api` from `libdbus-1.so.3`; false when the library or one of the
  ## functions is missing. The library stays loaded.
  result = false
  when defined(linux) or defined(bsd):
    let lib = loadLib("libdbus-1.so.3")
    if lib != nil:
      result = true
      template get(field: untyped; name: string) =
        let p = lib.symAddr(name)
        if p == nil: result = false
        else: api.field = cast[typeof(api.field)](p)
      get errorInit, "dbus_error_init"
      get errorFree, "dbus_error_free"
      get errorIsSet, "dbus_error_is_set"
      get threadsInitDefault, "dbus_threads_init_default"
      get openPrivate, "dbus_connection_open_private"
      get busRegister, "dbus_bus_register"
      get close, "dbus_connection_close"
      get unref, "dbus_connection_unref"
      get newMethodCall, "dbus_message_new_method_call"
      get newMethodReturn, "dbus_message_new_method_return"
      get setAutoStart, "dbus_message_set_auto_start"
      get messageUnref, "dbus_message_unref"
      get iterInitAppend, "dbus_message_iter_init_append"
      get iterAppendBasic, "dbus_message_iter_append_basic"
      get iterOpen, "dbus_message_iter_open_container"
      get iterClose, "dbus_message_iter_close_container"
      get iterInit, "dbus_message_iter_init"
      get iterArgType, "dbus_message_iter_get_arg_type"
      get iterRecurse, "dbus_message_iter_recurse"
      get iterGetBasic, "dbus_message_iter_get_basic"
      get sendWithReplyAndBlock, "dbus_connection_send_with_reply_and_block"
      get send, "dbus_connection_send"
      get flush, "dbus_connection_flush"
      get readWrite, "dbus_connection_read_write"
      get popMessage, "dbus_connection_pop_message"
      get isMethodCall, "dbus_message_is_method_call"
      get requestName, "dbus_bus_request_name"
  else:
    discard api

proc sessionBusAddress*(): string =
  ## Where the session bus is: `DBUS_SESSION_BUS_ADDRESS`, else the socket
  ## `$XDG_RUNTIME_DIR/bus` when it exists; "" for no bus.
  result = getEnv("DBUS_SESSION_BUS_ADDRESS")
  let runtime = getEnv("XDG_RUNTIME_DIR")
  if result.len == 0 and runtime.len > 0:
    try:
      if getFileInfo(runtime / "bus").kind == pcFile: # a socket: not a directory or link
        result = "unix:path=" & runtime / "bus"
    except OSError:
      discard # no bus there

proc probeTrayHost*(address = sessionBusAddress(); timeoutMs = 1000): TrayHost =
  ## Whether a tray icon would be seen (the module doc). Windows and macOS:
  ## always `thPresent`. Any thread; blocks at most about `timeoutMs`.
  when defined(windows) or defined(macosx):
    discard address
    discard timeoutMs
    thPresent
  else:
    if address.len == 0:
      return thNoBus
    var api: DbusApi
    if not loadDbus(api):
      return thNoLibDbus
    discard api.threadsInitDefault() # SDL's tray and the caller may use libdbus too
    var err: DbusError
    api.errorInit(addr err)
    let conn = api.openPrivate(address.cstring, addr err)
    if conn == nil or api.busRegister(conn, addr err) == 0:
      api.errorFree(addr err)
      if conn != nil:
        api.close(conn)
        api.unref(conn)
      return thBusFailed
    result = thBusFailed
    let call = api.newMethodCall(WatcherName, WatcherPath, PropertiesInterface, "Get")
    if call != nil:
      api.setAutoStart(call, 0) # a watcher that is not running is not started
      var it: DbusIter
      api.iterInitAppend(call, addr it)
      var iface: cstring = WatcherName
      var prop: cstring = HostRegistered
      discard api.iterAppendBasic(addr it, DbusTypeString, addr iface)
      discard api.iterAppendBasic(addr it, DbusTypeString, addr prop)
      let reply = api.sendWithReplyAndBlock(conn, call, cint(timeoutMs), addr err)
      api.messageUnref(call)
      if reply == nil:
        let name = if api.errorIsSet(addr err) != 0 and err.name != nil: $err.name else: ""
        result = if name in ["org.freedesktop.DBus.Error.ServiceUnknown",
            "org.freedesktop.DBus.Error.NameHasNoOwner", "org.freedesktop.DBus.Error.UnknownObject",
            "org.freedesktop.DBus.Error.UnknownMethod"]: thNoWatcher
          else: thBusFailed
        api.errorFree(addr err)
      else:
        var top, inner: DbusIter
        var registered = 0'u32
        if api.iterInit(reply, addr top) != 0 and api.iterArgType(addr top) == DbusTypeVariant:
          api.iterRecurse(addr top, addr inner)
          if api.iterArgType(addr inner) == DbusTypeBoolean:
            api.iterGetBasic(addr inner, addr registered)
        result = if registered != 0: thPresent else: thNoHost
        api.messageUnref(reply)
    api.close(conn)
    api.unref(conn)
