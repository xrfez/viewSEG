## Last words for a program that dies with an icon in the tray. Windows keeps
## a notification-area icon until the program that added it removes it; a
## program that dies leaves a ghost there until the pointer passes over it.
## `guardFatalSignals` runs a cleanup on a fatal signal (an access violation,
## an abort, a bad instruction or a division fault) before the handler that
## was there (Nim's, which writes the stack trace and ends the program);
## `guardUnhandled` runs it when an exception is not handled on any thread;
## `removeTrayIcons` is the cleanup for icons added through a hidden window
## of a known class (SDL's tray, class `SDL_TRAY`).
##
## The cleanup runs inside a signal handler: it must not allocate or take a
## lock. `removeTrayIcons` looks up what it calls beforehand
## (`prepareTrayRemoval`) and then calls only the Shell and window functions.
## Elsewhere than Windows there is nothing to remove: a tray icon there
## belongs to the program's D-Bus or X connection, which ends with it.

type
  FatalCleanup* = proc () {.nimcall, gcsafe, raises: [].}
    ## Called once on the first fatal signal, before the previous handler.

  SignalHandler = proc (sig: cint) {.noconv.}

const fatalSignalCount = 4

var
  SIGSEGV {.importc, header: "<signal.h>".}: cint
  SIGABRT {.importc, header: "<signal.h>".}: cint
  SIGFPE {.importc, header: "<signal.h>".}: cint
  SIGILL {.importc, header: "<signal.h>".}: cint

proc c_signal(sig: cint; handler: SignalHandler): SignalHandler {.importc: "signal",
  header: "<signal.h>".}
proc c_raise(sig: cint): cint {.importc: "raise", header: "<signal.h>".}

var
  cleanup: FatalCleanup
  cleaned = false
  previous: array[fatalSignalCount, (cint, SignalHandler)]

proc onFatal(sig: cint) {.noconv.} =
  if not cleaned:
    cleaned = true
    if cleanup != nil: cleanup()
  for (s, handler) in previous:
    if s == sig and handler != nil and cast[int](handler) > 1: # not SIG_DFL (0) or SIG_IGN (1)
      handler(sig)
      return
  discard c_signal(sig, nil) # SIG_DFL: end as the system would
  discard c_raise(sig)

var
  previousUnhandled: proc (e: ref Exception) {.nimcall, tags: [], gcsafe, raises: [].}
  unhandledCleanup: FatalCleanup

proc onUnhandled(e: ref Exception) {.nimcall, tags: [], gcsafe, raises: [].} =
  {.cast(gcsafe), cast(tags: []).}:
    if not cleaned:
      cleaned = true
      if unhandledCleanup != nil: unhandledCleanup()
    if previousUnhandled != nil: previousUnhandled(e)

proc guardUnhandled*(onDeath: FatalCleanup) =
  ## Runs `onDeath` when an exception (a Defect too) is not handled, on any
  ## thread, before Nim writes it and ends the program. On a worker thread
  ## Nim ends the program there and then (`rawQuit`), so the main thread's
  ## cleanup (`SDL_Quit`'s, which removes the tray icon) never runs: this is
  ## what removes the icon then. Install once, at start, on the main thread.
  if unhandledCleanup == nil:
    previousUnhandled = unhandledExceptionHook
    unhandledExceptionHook = onUnhandled
  unhandledCleanup = onDeath

proc guardFatalSignals*(onDeath: FatalCleanup) =
  ## Runs `onDeath` on a fatal signal, then the handler installed before (or
  ## the system's default, which ends the program). Install once, at start, on the main
  ## thread; a second call only replaces `onDeath`.
  if cleanup == nil:
    let signals = [SIGSEGV, SIGABRT, SIGFPE, SIGILL]
    for i, s in signals:
      previous[i] = (s, c_signal(s, onFatal))
  cleanup = onDeath

when defined(windows):
  import std/dynlib

  type
    Hwnd = pointer
    NotifyIconDataV1 {.bycopy.} = object
      ## `NOTIFYICONDATAW` up to `szTip[64]`: what `NIM_DELETE` reads.
      size: uint32
      hwnd: Hwnd
      id: uint32
      flags: uint32
      callbackMessage: uint32
      icon: pointer
      tip: array[64, uint16]

    FindWindowExWFn = proc (parent, after: Hwnd; class, title: ptr uint16): Hwnd {.
      stdcall, gcsafe, raises: [].}
    GetWindowThreadProcessIdFn = proc (hwnd: Hwnd; pid: ptr uint32): uint32 {.
      stdcall, gcsafe, raises: [].}
    GetCurrentProcessIdFn = proc (): uint32 {.stdcall, gcsafe, raises: [].}
    ShellNotifyIconWFn = proc (msg: uint32; data: ptr NotifyIconDataV1): int32 {.
      stdcall, gcsafe, raises: [].}

  const NimDelete = 2'u32

  var
    findWindowEx: FindWindowExWFn
    getWindowThreadProcessId: GetWindowThreadProcessIdFn
    getCurrentProcessId: GetCurrentProcessIdFn
    shellNotifyIcon: ShellNotifyIconWFn
    trayClass: array[64, uint16]
    idBound = 0'u32 ## the highest icon id to remove (`prepareTrayRemoval`)

func trayIdBound*(trays, entries: int): int =
  ## The highest icon id SDL can have given the last of `trays` trays made in
  ## this run, each with a menu of `entries` entries (separators count): SDL
  ## numbers its tray icons and menu entries from one counter that never goes
  ## back, a tray taking one id and each entry one; plus room for 16 more.
  max(trays, 1) * (1 + max(entries, 0)) + 16

proc prepareTrayRemoval*(windowClass: string; maxId: int) =
  ## Looks up what `removeTrayIcons` needs, for icons added through hidden
  ## windows of class `windowClass` with ids up to `maxId` (`trayIdBound`).
  ## Main thread, before any fatal signal; again after each new tray.
  when defined(windows):
    idBound = uint32(clamp(maxId, 1, 100_000))
    let user32 = loadLib("user32.dll")
    let kernel32 = loadLib("kernel32.dll")
    let shell32 = loadLib("shell32.dll")
    if user32 != nil:
      findWindowEx = cast[FindWindowExWFn](user32.symAddr("FindWindowExW"))
      getWindowThreadProcessId = cast[GetWindowThreadProcessIdFn](
        user32.symAddr("GetWindowThreadProcessId"))
    if kernel32 != nil:
      getCurrentProcessId = cast[GetCurrentProcessIdFn](kernel32.symAddr("GetCurrentProcessId"))
    if shell32 != nil:
      shellNotifyIcon = cast[ShellNotifyIconWFn](shell32.symAddr("Shell_NotifyIconW"))
    let n = min(windowClass.len, trayClass.len - 1)
    for i in 0 ..< n: trayClass[i] = uint16(windowClass[i]) # an ASCII class name
    trayClass[n] = 0
  else:
    discard windowClass
    discard maxId

proc removeTrayIcons*(): int {.gcsafe, raises: [].} =
  ## Removes the tray icons this process added through windows of the class
  ## `prepareTrayRemoval` named; returns how many windows of it were found.
  ## Safe in a signal handler. 0 elsewhere than Windows.
  result = 0
  when defined(windows):
    {.cast(gcsafe).}:
      if findWindowEx != nil and getWindowThreadProcessId != nil and
          getCurrentProcessId != nil and shellNotifyIcon != nil and trayClass[0] != 0:
        let me = getCurrentProcessId()
        var hwnd: Hwnd = nil
        while true:
          hwnd = findWindowEx(nil, hwnd, addr trayClass[0], nil)
          if hwnd == nil: break
          var pid = 0'u32
          discard getWindowThreadProcessId(hwnd, addr pid)
          if pid == me:
            inc result
            for id in 1'u32 .. idBound:
              var data = NotifyIconDataV1(size: uint32(sizeof(NotifyIconDataV1)),
                hwnd: hwnd, id: id)
              discard shellNotifyIcon(NimDelete, addr data)
