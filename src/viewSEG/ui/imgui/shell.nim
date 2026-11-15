## SDL3-backed shell services, behind plain Nim types: native file dialogs, the
## system light/dark theme, the window icon, and the tray icon with its menu. Only `ui/` may import SDL
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
##
## The tray (`showTray`): SDL's, with the program's icon and a menu of
## `TrayAction`s, whose clicks arrive as `seTray` events. SDL calls a tray
## entry's callback on the main thread, while events are pumped (Windows:
## the tray's window procedure; Linux: GTK's loop), so it queues the event
## directly. On Linux SDL uses AppIndicator (libayatana-appindicator through
## GTK), which needs a StatusNotifier host in the desktop's bar to be seen;
## SDL makes the tray whether or not one is there, so `askTrayHost` asks the
## session bus first (`platform/trayhost`), off the UI thread.
## The icon goes when the tray is hidden and at `SDL_Quit`; on Windows a
## fatal signal and an exception no thread handles (a worker's ends the
## program before `SDL_Quit` can run) also remove it (`platform/trayguard`),
## so a crash leaves no ghost icon in the notification area.

import std/[atomics, locks, options, strutils, typedthreads]
from std/os import getEnv
import sdl3_nim
import ../../platform/[chrome, trayguard, trayhost]

export TrayHost

type
  SystemTheme* = enum
    ## The OS light/dark setting.
    stUnknown = "unknown", stLight = "light", stDark = "dark"

  DialogKind* = enum
    dkOpenFile = "Open file",               ## one seismic file
    dkOpenFiles = "Open files",             ## several seismic files
    dkOpenFolder = "Open folder",           ## one folder
    dkExportSettings = "Export settings",   ## a NIF file to write (a save dialog)
    dkImportSettings = "Import settings",   ## a NIF file to read
    dkExportLayout = "Export layout",       ## a NIF file to write (a save dialog)
    dkImportLayout = "Import layout",       ## a NIF file to read
    dkExportLog = "Export messages"         ## a text file to write (a save dialog)
    dkJoinFiles = "Add survey files"        ## survey files to import: SPS, SEG P1, CSV tables
    dkExportEdits = "Export trace edits"    ## a NIF or CSV file to write (a save dialog)
    dkImportEdits = "Import trace edits"    ## a NIF or CSV file of trace edits to read
    dkOpenProject = "Open project"          ## a project's folder
    dkProjectPlace = "Place of the project" ## the folder a new project is made in
    dkProjectData = "Add a data folder"     ## a data folder of a project
    dkLocateFolder = "Locate a data folder" ## where a project's missing data folder is now

  ShellEventKind* = enum
    sePathsChosen,  ## a dialog returned `paths` (at least one)
    seCancelled,    ## a dialog was closed without a choice
    seDialogFailed, ## a dialog could not be shown; `error` says why
    seThemeChanged  ## the OS switched to `theme`
    seTray          ## an entry of the tray's menu was clicked: `action`

  TrayAction* = enum
    ## The tray menu's entries, in order; the string is the label.
    taShow = "Show viewSEG", taOpenFile = "Open file...", taQuit = "Quit"

  ShellEvent* = object
    ## Something the OS shell reports to the application.
    case kind*: ShellEventKind
    of sePathsChosen, seCancelled, seDialogFailed:
      dialog*: DialogKind
      paths*: seq[string]
      error*: string
    of seThemeChanged:
      theme*: SystemTheme
    of seTray:
      action*: TrayAction

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
  SDL_DialogFileFilter(name: "Seismic and survey files",
    pattern: "sgy;segy;sgd;segd;sg2;sps;rps;xps;ops;s;r;x;p1"),
  SDL_DialogFileFilter(name: "Seismic files (SEG-Y, SEG-D, SEG-2)",
    pattern: "sgy;segy;sgd;segd;sg2"),
  SDL_DialogFileFilter(name: "Survey files (SPS, SEG P1)", pattern: "sps;rps;xps;ops;s;r;x;p1"),
  SDL_DialogFileFilter(name: "SEG-Y (*.sgy, *.segy)", pattern: "sgy;segy"),
  SDL_DialogFileFilter(name: "SEG-D (*.sgd, *.segd)", pattern: "sgd;segd"),
  SDL_DialogFileFilter(name: "SEG-2 (*.sg2)", pattern: "sg2"),
  SDL_DialogFileFilter(name: "All files", pattern: "*")]
  ## Module-lifetime storage: SDL reads the filters until the callback runs.
  ## Patterns match case-insensitively on every platform SDL supports.

let nifFilters = [
  SDL_DialogFileFilter(name: "viewSEG settings and layouts (*.nif)", pattern: "nif"),
  SDL_DialogFileFilter(name: "All files", pattern: "*")]

let joinFilters = [
  SDL_DialogFileFilter(name: "Survey files (SPS, SEG P1, CSV)",
    pattern: "sps;rps;xps;ops;s;r;x;p1;p190;csv;txt;tsv"),
  SDL_DialogFileFilter(name: "SPS (*.sps, *.rps, *.xps)", pattern: "sps;rps;xps;ops;s;r;x"),
  SDL_DialogFileFilter(name: "SEG P1 (*.p1)", pattern: "p1;p190"),
  SDL_DialogFileFilter(name: "Tables of stations (*.csv, *.txt)", pattern: "csv;txt;tsv"),
  SDL_DialogFileFilter(name: "All files", pattern: "*")]

let editsFilters = [
  SDL_DialogFileFilter(name: "Trace edits (*.csv, *.nif)", pattern: "csv;nif"),
  SDL_DialogFileFilter(name: "CSV table (*.csv)", pattern: "csv"),
  SDL_DialogFileFilter(name: "viewSEG's own (*.nif)", pattern: "nif"),
  SDL_DialogFileFilter(name: "All files", pattern: "*")]

let logFilters = [
  SDL_DialogFileFilter(name: "Text (*.log, *.txt)", pattern: "log;txt"),
  SDL_DialogFileFilter(name: "All files", pattern: "*")]

var startAt: string
  ## where the last dialog started: SDL may read it until the dialog is shown

const DialogParentEnvVar* = "VIEWSEG_DIALOG_PARENT"
  ## `none` opens dialogs without a parent window and `window` always gives them
  ## one. Unset, the desktop decides: see `wantsParent`.

func wantsParent(setting, videoDriver: string; waylandSession: bool): bool =
  ## Whether dialogs get a parent window. `setting` is the value of
  ## `DialogParentEnvVar`. Left to the desktop, an X11 window on a Wayland desktop
  ## (the app under Xwayland) gets none: the portal's dialog cannot attach to it and
  ## is then drawn with an outline larger than its box.
  case setting.strip.toLowerAscii
  of "none": false
  of "window": true
  else: not (waylandSession and videoDriver == "x11")

proc showDialog*(kind: DialogKind; parentWindowId = 0'u32; location = "") =
  ## Opens the native dialog for `kind` and returns at once; the outcome arrives
  ## later from `pollShellEvents`. The dialog is modal to the window with SDL id
  ## `parentWindowId` (0 for none), where the desktop can attach it (`wantsParent`),
  ## and starts in the folder or at the file `location` ("" for the desktop's
  ## choice; not every desktop honours it). Main thread only.
  let
    waylandSession = getEnv("WAYLAND_DISPLAY").len > 0 or
      getEnv("XDG_SESSION_TYPE") == "wayland"
    attach = parentWindowId != 0 and wantsParent(getEnv(DialogParentEnvVar),
      $SDL_GetCurrentVideoDriver(), waylandSession)
    parent = if attach: SDL_GetWindowFromID(parentWindowId) else: nil
    userdata = cast[pointer](kind.int)
  startAt = location
  let at = if startAt.len > 0: startAt.cstring else: nil
  case kind
  of dkOpenFile, dkOpenFiles:
    SDL_ShowOpenFileDialog(onDialogResult, userdata, parent, addr seismicFilters[0],
      seismicFilters.len.cint, at, kind == dkOpenFiles)
  of dkOpenFolder, dkOpenProject, dkProjectPlace, dkProjectData, dkLocateFolder:
    SDL_ShowOpenFolderDialog(onDialogResult, userdata, parent, at, false)
  of dkImportSettings, dkImportLayout:
    SDL_ShowOpenFileDialog(onDialogResult, userdata, parent, addr nifFilters[0],
      nifFilters.len.cint, at, false)
  of dkExportSettings, dkExportLayout:
    SDL_ShowSaveFileDialog(onDialogResult, userdata, parent, addr nifFilters[0],
      nifFilters.len.cint, at)
  of dkExportLog:
    SDL_ShowSaveFileDialog(onDialogResult, userdata, parent, addr logFilters[0],
      logFilters.len.cint, at)
  of dkJoinFiles:
    SDL_ShowOpenFileDialog(onDialogResult, userdata, parent, addr joinFilters[0],
      joinFilters.len.cint, at, true)
  of dkExportEdits:
    SDL_ShowSaveFileDialog(onDialogResult, userdata, parent, addr editsFilters[0],
      editsFilters.len.cint, at)
  of dkImportEdits:
    SDL_ShowOpenFileDialog(onDialogResult, userdata, parent, addr editsFilters[0],
      editsFilters.len.cint, at, false)

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

const
  iconPng = staticRead("../../../../res/viewSEG-64.png")
  iconFile = staticRead("../../../../res/viewSEG.ico") ## the executable's icon, every size

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

# ------------------------------------------------------------------- tray --

const
  TrayTooltip = "viewSEG"
  TrayWindowClass = "SDL_TRAY" ## the class of SDL's hidden tray window on Windows

var
  tray: ptr SDL_Tray
  trayEntries: array[TrayAction, ptr SDL_TrayEntry]
  traysMade = 0 ## trays made in this run (SDL's icon ids grow with each)

proc onTrayEntry(userdata: pointer; entry: ptr SDL_TrayEntry) {.cdecl.} =
  ## SDL's tray callback (main thread, during event pumping).
  postShellEvent ShellEvent(kind: seTray, action: TrayAction(cast[int](userdata)))

proc dropTrayIcons() {.nimcall, gcsafe, raises: [].} =
  ## The last thing done on a fatal signal: the tray icon taken away.
  discard removeTrayIcons()

var
  hostThread: Thread[void]
  hostAnswer: Atomic[int] ## -2 never asked, -1 asking, else a `TrayHost`
  hostThreadUsed = false
hostAnswer.store -2

proc askHost() {.thread.} =
  hostAnswer.store ord(probeTrayHost())

proc askTrayHost*() =
  ## Starts asking whether a tray icon would be seen (`platform/trayhost`),
  ## off this thread; `trayHostAnswer` gives the answer. Nothing when a
  ## question is still out. On Windows the answer is there at once.
  if hostAnswer.load != -1:
    when defined(windows) or defined(macosx):
      hostAnswer.store ord(thPresent)
    else:
      if hostThreadUsed: joinThread(hostThread) # the last question's, long done
      hostAnswer.store -1
      createThread(hostThread, askHost)
      hostThreadUsed = true

proc trayHostAnswer*(): Option[TrayHost] =
  ## The answer to the last `askTrayHost`; none while it is out or never asked.
  let a = hostAnswer.load
  if a >= 0: some(TrayHost(a)) else: none(TrayHost)

proc forgetTrayHost*() =
  ## Drops the last answer: `trayHostAnswer` is none until the next
  ## `askTrayHost` answers (the bar may have come or gone since).
  if hostAnswer.load >= 0: hostAnswer.store -2

proc trayShown*(): bool =
  ## The tray icon is there.
  not tray.isNil

proc showTray*(): string =
  ## Puts the program's icon in the tray, with its menu (`TrayAction`);
  ## nothing when it is there. Returns "" or why it cannot be shown (no
  ## AppIndicator library). Main thread. Ask `askTrayHost` first: SDL makes a
  ## tray on Linux whether or not anything will show it.
  result = ""
  if tray.isNil:
    # Windows: the icon file's own image at the notification area's size
    # (SDL's default is the 32-pixel icon, scaled down by the shell); elsewhere
    # SDL writes the image to a file for AppIndicator, which scales it.
    var icon: ptr SDL_Surface = nil
    let png = when defined(windows): iconImage(iconFile, trayIconSize()) else: iconPng
    if png.len > 0:
      let io = SDL_IOFromConstMem(png.cstring, png.len.csize_t)
      if not io.isNil: icon = SDL_LoadPNG_IO(io, true)
    tray = SDL_CreateTray(icon, TrayTooltip)
    if not icon.isNil: SDL_DestroySurface(icon)
    if tray.isNil:
      let why = $SDL_GetError()
      result = if why.len > 0: why else: "this desktop has no tray"
    else:
      let menu = SDL_CreateTrayMenu(tray)
      for a in TrayAction:
        if a == taQuit:
          discard SDL_InsertTrayEntryAt(menu, -1, nil, SDL_TRAYENTRY_BUTTON) # a separator
        trayEntries[a] = SDL_InsertTrayEntryAt(menu, -1, cstring($a), SDL_TRAYENTRY_BUTTON)
        if not trayEntries[a].isNil:
          SDL_SetTrayEntryCallback(trayEntries[a], onTrayEntry, cast[pointer](a.int))
      when defined(windows):
        inc traysMade
        let entries = ord(TrayAction.high) + 2 # the actions and the separator
        prepareTrayRemoval(TrayWindowClass, trayIdBound(traysMade, entries))
        guardFatalSignals(dropTrayIcons)
        guardUnhandled(dropTrayIcons)

proc hideTray*() =
  ## Takes the icon out of the tray; nothing when it is not there. Main
  ## thread. (`SDL_Quit` does it too.)
  if not tray.isNil:
    forgetTrayRemoval() # before its window goes
    SDL_DestroyTray(tray)
    tray = nil
    for a in TrayAction: trayEntries[a] = nil

proc trayMenu*(): seq[string] =
  ## The labels of the tray menu's entries as SDL holds them, "" for a
  ## separator; none while the tray is hidden.
  result = @[]
  if not tray.isNil:
    var n: cint = 0
    let entries = SDL_GetTrayEntries(SDL_GetTrayMenu(tray), addr n)
    if not entries.isNil:
      let list = cast[ptr UncheckedArray[ptr SDL_TrayEntry]](entries)
      for i in 0 ..< n.int:
        let label = SDL_GetTrayEntryLabel(list[i])
        result.add(if label.isNil: "" else: $label)

proc clickTray*(a: TrayAction) =
  ## Clicks entry `a` of the tray menu as the user would (tests); its event
  ## comes from `pollShellEvents`.
  if not trayEntries[a].isNil:
    SDL_ClickTrayEntry(trayEntries[a])
