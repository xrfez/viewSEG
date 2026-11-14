## SDL3-backed shell services, behind plain Nim types: native open dialogs, the
## system light/dark theme, and the window icon. Only `ui/` may import SDL
## (docs/architecture.md), so these live here rather than in `platform/`.
##
## Results reach the frame loop as `ShellEvent`s on a thread-safe queue that it
## drains once per frame with `pollShellEvents`. SDL calls a dialog's callback
## later, on whatever thread it likes: the main thread during event pumping
## (Linux portal) or a short-lived thread of its own (Windows). That callback
## therefore touches no Nim heap: it copies the result into SDL-allocated memory
## and links it into a mutex-protected list, which `pollShellEvents` turns into
## events on the main thread.
##
## The window icon (`res/viewSEG-64.png`) is the 64-pixel PNG image of
## `res/viewSEG.ico`, extracted as is; replace both together.

import std/[locks, strutils]
from std/os import getEnv
import sdl3_nim

type
  SystemTheme* = enum
    ## The OS light/dark setting.
    stUnknown = "unknown", stLight = "light", stDark = "dark"

  DialogKind* = enum
    dkOpenFile = "Open file",    ## one seismic file
    dkOpenFiles = "Open files",  ## several seismic files
    dkOpenFolder = "Open folder" ## one folder

  ShellEventKind* = enum
    sePathsChosen,  ## a dialog returned `paths` (at least one)
    seCancelled,    ## a dialog was closed without a choice
    seDialogFailed, ## a dialog could not be shown; `error` says why
    seThemeChanged  ## the OS switched to `theme`

  ShellEvent* = object
    ## Something the OS shell reports to the application.
    case kind*: ShellEventKind
    of sePathsChosen, seCancelled, seDialogFailed:
      dialog*: DialogKind
      paths*: seq[string]
      error*: string
    of seThemeChanged:
      theme*: SystemTheme

  ShellQueue* = object
    ## A FIFO of shell events: any Nim thread pushes, the frame loop drains.
    lock: Lock
    items: seq[ShellEvent]

proc initShellQueue*(q: var ShellQueue) =
  initLock(q.lock)
  q.items = @[]

proc deinitShellQueue*(q: var ShellQueue) =
  deinitLock(q.lock)

proc push*(q: var ShellQueue; ev: sink ShellEvent) =
  ## Appends `ev`; safe from any Nim thread.
  withLock q.lock:
    q.items.add ev

proc drain*(q: var ShellQueue): seq[ShellEvent] =
  ## Every queued event, oldest first, leaving the queue empty.
  withLock q.lock:
    result = move(q.items)

# ------------------------------------------------- dialog results, C side --
# What a dialog callback hands over: one SDL_malloc block per result, with the
# strings packed after the header as NUL-terminated runs.

type
  Pending = object
    next: ptr Pending
    dialog: DialogKind
    outcome: ShellEventKind
    count: int ## strings in `text`: paths, or 1 for the error
    text: UncheckedArray[char]

var
  pendingLock: Lock
  pendingHead, pendingTail: ptr Pending
  events: ShellQueue
initLock(pendingLock)
events.initShellQueue()

{.push stackTrace: off, checks: off.}
proc enqueueResult(dialog: DialogKind; filelist: ptr UncheckedArray[cstring];
    errorText: cstring) {.raises: [], gcsafe.} =
  ## Copies a dialog result into C memory and links it into the pending list.
  ## No Nim allocation: it may run on a thread Nim does not know.
  let errorText = if errorText.isNil: cstring"" else: errorText
  var
    outcome = sePathsChosen
    count = 0
    bytes = 0
  if filelist.isNil:
    outcome = seDialogFailed
    count = 1
    bytes = errorText.len + 1
  else:
    while not filelist[count].isNil:
      bytes += filelist[count].len + 1
      inc count
    if count == 0:
      outcome = seCancelled
  let p = cast[ptr Pending](SDL_malloc(csize_t(sizeof(Pending) + bytes)))
  if not p.isNil:
    p.next = nil
    p.dialog = dialog
    p.outcome = outcome
    p.count = count
    var at = 0
    for i in 0 ..< count:
      let s = if filelist.isNil: errorText else: filelist[i]
      let n = s.len + 1
      copyMem(addr p.text[at], s, n)
      at += n
    withLock pendingLock:
      if pendingTail.isNil:
        pendingHead = p
      else:
        pendingTail.next = p
      pendingTail = p

proc onDialogResult(userdata: pointer; filelist: ptr cstring; filter: cint) {.cdecl.} =
  ## SDL's dialog callback. `filelist` is nil on error, empty when cancelled.
  enqueueResult(DialogKind(cast[int](userdata)), cast[ptr UncheckedArray[cstring]](filelist),
    if filelist.isNil: SDL_GetError() else: nil)
{.pop.}

proc takePending(): seq[ShellEvent] =
  ## Converts the pending dialog results into events (main thread).
  var p: ptr Pending
  withLock pendingLock:
    p = pendingHead
    pendingHead = nil
    pendingTail = nil
  result = @[]
  while not p.isNil:
    var strings: seq[string]
    var at = 0
    for _ in 0 ..< p.count:
      let s = cast[cstring](addr p.text[at])
      strings.add $s
      at += s.len + 1
    case p.outcome
    of seDialogFailed:
      result.add ShellEvent(kind: seDialogFailed, dialog: p.dialog,
        error: if strings.len > 0 and strings[0].len > 0: strings[0] else: "unknown error")
    of seCancelled:
      result.add ShellEvent(kind: seCancelled, dialog: p.dialog)
    else:
      result.add ShellEvent(kind: sePathsChosen, dialog: p.dialog, paths: strings)
    let next = p.next
    SDL_free(p)
    p = next

proc flushPending() =
  ## Moves the pending dialog results into the queue, so that they keep their
  ## place before any event queued after them.
  for ev in takePending():
    events.push ev

proc pollShellEvents*(): seq[ShellEvent] =
  ## Every shell event since the last call, oldest first. Call it once per frame
  ## on the main thread.
  flushPending()
  events.drain()

proc postShellEvent*(ev: sink ShellEvent) =
  ## Queues `ev` as if the shell had produced it; safe from any Nim thread.
  flushPending()
  events.push ev

# ---------------------------------------------------------------- dialogs --

let seismicFilters = [
  SDL_DialogFileFilter(name: "Seismic files (SEG-Y, SEG-D, SEG-2)",
    pattern: "sgy;segy;sgd;segd;sg2"),
  SDL_DialogFileFilter(name: "SEG-Y (*.sgy, *.segy)", pattern: "sgy;segy"),
  SDL_DialogFileFilter(name: "SEG-D (*.sgd, *.segd)", pattern: "sgd;segd"),
  SDL_DialogFileFilter(name: "SEG-2 (*.sg2)", pattern: "sg2"),
  SDL_DialogFileFilter(name: "All files", pattern: "*")]
  ## Module-lifetime storage: SDL reads the filters until the callback runs.
  ## Patterns match case-insensitively on every platform SDL supports.

const DialogParentEnvVar* = "VIEWSEG_DIALOG_PARENT"
  ## Set to `none` to open dialogs without a parent window. On a Wayland desktop an
  ## X11 window (the app under Xwayland) is a parent the portal's dialog cannot attach to.

func wantsParent(setting: string): bool =
  ## Whether dialogs get a parent window, given the value of `DialogParentEnvVar`.
  setting.strip.toLowerAscii != "none"

proc showOpenDialog*(kind: DialogKind; parentWindowId = 0'u32) =
  ## Opens the native dialog for `kind` and returns at once; the outcome arrives
  ## later from `pollShellEvents`. The dialog is modal to the window with SDL id
  ## `parentWindowId` (0 for none, as is `DialogParentEnvVar=none`). Main thread only.
  let
    parent =
      if parentWindowId == 0 or not wantsParent(getEnv(DialogParentEnvVar)): nil
      else: SDL_GetWindowFromID(parentWindowId)
    userdata = cast[pointer](kind.int)
  case kind
  of dkOpenFile, dkOpenFiles:
    SDL_ShowOpenFileDialog(onDialogResult, userdata, parent, addr seismicFilters[0],
      seismicFilters.len.cint, nil, kind == dkOpenFiles)
  of dkOpenFolder:
    SDL_ShowOpenFolderDialog(onDialogResult, userdata, parent, nil, false)

# ------------------------------------------------------------------ theme --

proc systemTheme*(): SystemTheme =
  ## The OS light/dark setting now. Main thread only.
  case SDL_GetSystemTheme()
  of SDL_SYSTEM_THEME_LIGHT: stLight
  of SDL_SYSTEM_THEME_DARK: stDark
  else: stUnknown

proc noteSdlEvent*(eventType: uint32) =
  ## Lets the shell see the type of each SDL event the frame loop polls; a
  ## system theme change becomes a `seThemeChanged` event.
  if eventType == SDL_EVENT_SYSTEM_THEME_CHANGED.uint32:
    postShellEvent ShellEvent(kind: seThemeChanged, theme: systemTheme())

# ------------------------------------------------------------------ icons --

const iconPng = staticRead("../../../../res/viewSEG-64.png")

proc setIconHints*() =
  ## Windows: SDL takes the window and taskbar icons from the executable's
  ## icon resource 1 (`platform/winres`). Call before creating a window.
  discard SDL_SetHint(SDL_HINT_WINDOWS_INTRESOURCE_ICON, "1")
  discard SDL_SetHint(SDL_HINT_WINDOWS_INTRESOURCE_ICON_SMALL, "1")

proc setWindowIcon*(windowId: uint32): bool =
  ## Sets the window icon from the embedded PNG (X11; elsewhere the OS takes it
  ## from the executable or the .desktop file). False, with SDL's error in
  ## `SDL_GetError`, when the image or the window is unusable.
  let window = SDL_GetWindowFromID(windowId)
  let io = SDL_IOFromConstMem(iconPng.cstring, iconPng.len.csize_t)
  let icon = if io.isNil: nil else: SDL_LoadPNG_IO(io, true)
  if window.isNil or icon.isNil:
    result = false
  else:
    result = SDL_SetWindowIcon(window, icon)
  if not icon.isNil:
    SDL_DestroySurface(icon)
