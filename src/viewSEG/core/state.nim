## The application state, and the only two ways it changes:
##
## - `apply(state, command)`: a user intent, issued by the UI;
## - `drainInbox(state)`, once per frame: what the workers posted and the
##   jobs that finished.
##
## Both run on the UI thread, which owns the state; `initAppState` marks the
## thread that calls it as the UI thread. The UI reads the state through the
## accessors below, which do not let it change anything.
##
## **Trace panels.** A panel that shows a file has a reader thread
## (`core/reader`). Showing a gather holds the file (`Jobs.hold`) and hands
## it to the reader, which posts the panel's layout; the view then fits the
## whole gather. The UI reports what its plot shows (`ckView`); when the
## request sent last does not cover that view (`covers`), a new one is made
## (`requestFor`) and the panel's `requestGen` goes up. A tile is taken in
## only when it answers the newest request: older ones are dropped. The
## newest `MaxTiles` tiles of each panel are kept, so a view keeps showing
## what it has (the previous tile, the coarser one) until the new tile comes.
##
## **Views.** The frontend moves a panel's view with the `core/zoom` forms
## and reports each new one (`ckView`); a view reported past the data is
## kept inside it (`core/zoom`'s limits). A view that starts a gesture (a
## drag, a box zoom, a burst of wheel turns, a typed scale, a fit) is sent
## with `remember`, and the one it replaces is kept for "back" (`ckBack`).
## When `core` sets a view itself (back, or the whole gather once it is laid
## out) it bumps the panel's `jumps`, and the frontend follows.
##
## **Order.** `ckSort` gives layer 0 an order (keys, or the file's order):
## the panel's reader sorts, off this thread, and the view stays where it
## is. The plot goes on drawing the tiles in the old order until the first
## tile in the new one comes (`sorting` says so meanwhile), then drops them.
##
## A command that does not fit the state (a file that is no longer open, a
## gather out of range) changes nothing and says why in the log, as a
## warning: the UI may issue a command in the same frame as the change that
## made it stale, and that must not crash anything. A hover is the
## exception: it comes with every move of the mouse, so a hover on a trace
## no open file has clears the hover and says nothing.
##
## **Highlighting.** The trace under the pointer (`ckHover`) and the
## selected traces (`ckSelect`, `ckClearSelection`) are survey-wide trace
## ids in the `Selection`, so the plot and the map show the same ones. A
## change of either only recolours traces: nothing is read again.
##
## **Settings.** The settings (`core/settings`) change only through
## commands: `ckSettings`, and the plot's display, order and display header,
## which a new plot window then starts with; opening a file adds it to the
## recent files. Given a folder (`keepSettingsIn`), they are saved there by
## the disk thread a moment after they last changed (`SaveDelay`, `persist`)
## and at `shutdown`; `ckExportSettings` and `ckImportSettings` write and
## read a file of the user's, and `ckResetSettings` goes back to the
## defaults, keeping a copy.
##
## **No undo history.** Edits to traces (kill, reverse polarity) are kept as
## lists beside an untouched file, so each one is undone by its inverse;
## header edits are a patch, undone by removing an entry; views have "back".
## None of these needs a general history of commands.

import std/[math, monotimes, os, sequtils, strutils, times]
import parseSEG
from processSEG/core/workspace import Workspace, initWorkspace
import diskio, filejobs, filelist, inbox, jobs, layouts, log, panels, persist, pick, reader,
  selection, session, settings, threads, tiles, zoom

export filelist, inbox, jobs, layouts, log, panels, persist, pick, selection, session, settings,
  threads, tiles, zoom

const
  MainPanel* = PanelId(1)
    ## The panel `initAppState` makes; opened files appear in it.
  MaxTiles* = 4         ## tiles kept per panel, newest last
  FloatValues* = 32_768 ## values in view the Float gain takes its level from, at most

type
  CommandKind* = enum
    ckOpen = "open"                      ## open files (one interactive job each) and keep them open
    ckBrowse = "browse"                  ## list files and folders in the file list
    ckShowFile = "show file"             ## show a file in a panel, in place of the one it shows
    ckClose = "close"                    ## close an open file
    ckCancelJob = "cancel job"
    ckReorderJob = "reorder job"
    ckRemoveJob = "remove job"
    ckGather = "go to gather"            ## show another gather of the file a panel shows
    ckView = "view"                      ## what a panel's plot shows (zoom, pan, size)
    ckDisplay = "display"                ## how a panel's layer 0 is drawn
    ckHeader = "display header"          ## the rows of a panel's display header
    ckSort = "sort"                      ## the order of a panel's traces
    ckBack = "back"                      ## a panel's view before the last gesture
    ckSettings = "settings"              ## replace the settings
    ckExportSettings = "export settings" ## write the settings to a file of the user's
    ckImportSettings = "import settings" ## take settings in from such a file
    ckResetSettings = "reset settings"   ## back to the defaults
    ckLayout = "window layout"           ## how the windows are arranged now
    ckSaveLayout = "save layout"         ## keep the arrangement under a name
    ckLoadLayout = "load layout"         ## arrange the windows as a layout file says
    ckExportLayout = "export layout"     ## write the arrangement to a file of the user's
    ckImportLayout = "import layout"     ## load such a file and keep it among the layouts
    ckHover = "hover"                    ## the trace under the cursor
    ckSelect = "select"                  ## change the selected traces
    ckClearSelection = "clear selection"

  Command* = object
    ## A user intent: the only way the UI changes the state.
    case kind*: CommandKind
    of ckOpen, ckBrowse:
      paths*: seq[string]
        ## relative or absolute: one file opens once, however it is named
      showFirst*: bool                ## ckBrowse: show the first file found in the main panel
    of ckClose: file*: SessionId
    of ckCancelJob, ckRemoveJob: job*: JobId
    of ckReorderJob:
      reordered*: JobId
      position*: int                  ## 0 runs next
    of ckGather, ckView, ckDisplay, ckHeader, ckSort, ckBack, ckShowFile:
      panel*: PanelId
      gather*: int                    ## ckGather: index into the file's gathers
      path*: string                   ## ckShowFile: the file to show
      listFolder*: bool               ## ckShowFile: the file list lists its folder too
      view*: Viewport                 ## ckView: what the panel's plot shows now
      remember*: bool                 ## ckView: a gesture starts; keep the view it replaces for back
      display*: DisplaySettings       ## ckDisplay: how layer 0 is drawn
      header*: HeaderChoice           ## ckHeader: the display header's rows
      order*: seq[SortKey]            ## ckSort: layer 0's keys, the first first; empty: the file's order
    of ckHover: trace*: int           ## survey-wide trace id; -1 for none
    of ckSelect:
      traces*: seq[int]               ## survey-wide trace ids
      mode*: SelectMode
    of ckClearSelection, ckResetSettings: discard
    of ckSettings: settings*: Settings
    of ckExportSettings, ckImportSettings, ckLoadLayout, ckExportLayout, ckImportLayout:
      docPath*: string                ## the file written or read
    of ckLayout: arrangement*: string ## the toolkit's layout text
    of ckSaveLayout: layoutName*: string

  Pending = object
    ## An open or close job the state waits for.
    job: JobId
    path: string
    session: Session ## a closing file's session, kept until its close job ends
    panel: PanelId   ## an open: the panel it is shown in (`ckShowFile`); NoPanel: the main one
    unwanted: bool   ## an open no longer wanted (another file was chosen): dropped when it comes
    quiet: bool      ## a close of a file the plot stepped away from: not logged

  AppState* = object
    ## Everything the views show. Move-only.
    log: MessageLog
    selection: Selection
    panels: seq[Panel]
    sessions: seq[Session]
    opening, closing: seq[Pending]
    files: FileList       ## the file list
    showFound: PanelId    ## show the first file the listing finds here; NoPanel for none
    oldScans: seq[JobId]  ## scans replaced by a newer listing: they end quietly
    mail: seq[Msg]
    indexCache: string    ## the index cache folder; "" for none
    settings: Settings
    nextFile, nextPanel, nextBase: int
    tiles: seq[seq[Tile]] ## per panel, as `panels`: the newest last
    nextTile: uint64
    scratch: Workspace    ## for the Float gain's level, on this thread
    inbox: Inbox
    disk: DiskIo          ## writes the session log and the settings; none until needed
    logFile: string       ## the session log; "" for none
    logged: int           ## the log's serial the session log has reached
    configDir: string     ## where the settings are saved; "" for nowhere
    defaults: Settings    ## what a reset goes back to
    settingsRev: int      ## bumped on every change of `settings`
    savedRev: int         ## the revision saved last
    changedAt: MonoTime   ## when `settings` last changed
    arrangement: string   ## how the windows are arranged now (the toolkit's text)
    layoutRev, layoutSaved: int
    layoutAt: MonoTime    ## when the arrangement last changed
    layoutList: seq[SavedLayout]
    loaded: Layout        ## the layout loaded last, for the frontend to show
    loads: int            ## bumped each time a layout is loaded
    jobs: Jobs
      ## Fields are destroyed last to first: the runners stop before
      ## anything a running job uses is freed.
    readers: seq[PanelReader]
      ## per panel, as `panels`; started when the panel first shows a file.
      ## Declared last: the readers stop (and end their holds) before the
      ## jobs and the files go.

proc initAppState*(logCapacity: Positive = DefaultLogCapacity;
    jobHistory: Natural = DefaultJobHistory; indexCache = ""): AppState =
  ## The state of a program with no file open and one empty panel
  ## (`MainPanel`), with both job lanes running. Marks the calling thread as
  ## the UI thread. `indexCache` is the folder for parseSEG's index caches
  ## (the frontend passes one under the cache directory; it is created when
  ## first needed); "" opens every file without one.
  markUiThread()
  result = AppState(log: initMessageLog(logCapacity), inbox: initInbox(),
    jobs: initJobs(jobHistory), indexCache: indexCache, nextFile: 1,
    nextPanel: int(MainPanel) + 1, nextTile: 1, scratch: initWorkspace(),
    files: FileList(job: NoJob))
  result.panels.add Panel(id: MainPanel)
  result.tiles.add newSeq[Tile]()
  result.readers.add PanelReader()

const SaveDelay* = initDuration(seconds = 1)
  ## settings are saved this long after their last change (and at shutdown)

proc diskIo(state: var AppState): lent DiskIo =
  ## The disk thread, started when first needed.
  if state.disk.isNil: state.disk = newDiskIo(state.inbox.poster)
  state.disk

proc logTo*(state: var AppState; dir: string) =
  ## From now on, writes the log to a new file in `dir`, this run's session
  ## log (`sessionLogPath`), off this thread, entries logged so far first;
  ## removes the oldest session logs there, keeping `KeptSessionLogs`.
  assertUiThread()
  discard state.diskIo
  state.logFile = sessionLogPath(dir)
  state.logged = state.log.nextSerial - state.log.len
  state.disk.prune(dir, SessionLogPrefix, SessionLogSuffix, KeptSessionLogs - 1,
    spare = state.logFile)

func logFile*(state: AppState): lent string {.inline.} =
  ## This run's session log; "" when the log is not written to a file.
  state.logFile

proc writeLog(state: var AppState) =
  ## Hands what was logged since the last call to the disk thread.
  if state.logFile.len == 0 or state.logged == state.log.nextSerial: return
  var text = ""
  let first = state.log.nextSerial - state.log.len
  if state.logged < first:
    text.add "(" & $(first - state.logged) & " messages were dropped before they " &
      "could be written)\n"
  for e in state.log.since(state.logged):
    text.add fileLine(e)
  state.logged = state.log.nextSerial
  state.disk.append(state.logFile, text, "the session log")

proc settingsFile*(state: AppState): string =
  ## Where the settings are saved; "" when they are not.
  if state.configDir.len == 0: "" else: state.configDir / SettingsFileName

proc keepSettingsIn*(state: var AppState; dir: string; loaded: LoadedSettings) =
  ## Takes the settings `loadSettings` read from `dir` and logs what it
  ## said; from now on, saves them in `dir`'s `SettingsFileName`, off this
  ## thread, `SaveDelay` after they last changed and at `shutdown` (unless
  ## `loaded` says they must not be: the file is left as it is).
  assertUiThread()
  for (severity, text) in loaded.notes:
    state.log.add(severity, "settings", text)
  state.settings = cleaned(loaded.settings)[0]
  state.defaults = cleaned(loaded.defaults)[0]
  state.configDir = if loaded.saveable: dir else: ""
  inc state.settingsRev
  state.savedRev = if loaded.rewrite: state.settingsRev - 1 else: state.settingsRev
  state.changedAt = getMonoTime()
  discard state.diskIo

proc saveNamed(state: var AppState; name, imgui: string) =
  ## Keeps `imgui` as the user's layout `name`, replacing one of that name.
  let path = layoutPath(state.configDir, name)
  state.diskIo.replace(path, layoutDocument(Layout(name: name, imgui: imgui)),
    "the layout \"" & name & "\"", done = "Layout \"" & name & "\" saved in " & path & ".")
  state.layoutList = state.layoutList.added(SavedLayout(name: name, path: path))

proc keepLayoutsIn*(state: var AppState; dir: string; presetDirs: openArray[string]) =
  ## From now on, saves the arrangement in `dir`'s `LayoutFileName` (a
  ## moment after it changes, and at `shutdown`) and named layouts in its
  ## `layouts/`; lists those and the presets in `presetDirs`' `layouts/`.
  assertUiThread()
  if state.configDir.len == 0: state.configDir = dir
  state.layoutList = listLayouts(dir, presetDirs)
  discard state.diskIo

func layouts*(state: AppState): lent seq[SavedLayout] {.inline.} =
  ## The layouts that can be loaded: the user's, then the presets.
  state.layoutList

func loadedLayout*(state: AppState): lent Layout {.inline.} =
  ## The layout loaded last (`ckLoadLayout`, `ckImportLayout`): the
  ## frontend arranges its windows so when `layoutLoads` goes up.
  state.loaded

func layoutLoads*(state: AppState): int {.inline.} =
  ## Bumped each time a layout is loaded.
  state.loads

func arrangement*(state: AppState): lent string {.inline.} =
  ## How the windows are arranged, as the frontend last said (`ckLayout`).
  state.arrangement

func settingsRevision*(state: AppState): int {.inline.} =
  ## Bumped on every change of the settings.
  state.settingsRev

proc saveSettings(state: var AppState) =
  if state.configDir.len > 0:
    state.disk.replace(state.settingsFile, settingsDocument(state.settings), "the settings")
  state.savedRev = state.settingsRev

proc saveArrangement(state: var AppState) =
  if state.configDir.len > 0 and state.arrangement.len > 0:
    state.disk.replace(state.configDir / LayoutFileName,
      layoutDocument(Layout(imgui: state.arrangement)), "the window layout")
  state.layoutSaved = state.layoutRev

proc persist*(state: var AppState; now = getMonoTime()) =
  ## Hands what is due to the disk thread: what was logged since the last
  ## call, and the settings and the arrangement once `SaveDelay` has passed
  ## since they last changed. Call it once per frame, after the frame's
  ## commands; it never waits.
  assertUiThread()
  state.writeLog()
  if state.savedRev != state.settingsRev and now - state.changedAt >= SaveDelay:
    state.saveSettings()
  if state.layoutSaved != state.layoutRev and now - state.layoutAt >= SaveDelay:
    state.saveArrangement()

proc flushFiles*(state: var AppState) =
  ## Saves what is due now, without waiting for `SaveDelay`, and waits
  ## until the disk thread has written everything handed to it (tests).
  assertUiThread()
  state.writeLog()
  if state.savedRev != state.settingsRev: state.saveSettings()
  if state.layoutSaved != state.layoutRev: state.saveArrangement()
  state.disk.flush()

proc shutdown*(state: var AppState) =
  ## Stops the panels' readers, cancels every job and waits for the running
  ## ones to stop, then writes what is left to the session log. Destroying
  ## the state does this too.
  assertUiThread()
  for r in state.readers:
    r.stop()
  state.jobs.stop()
  if state.savedRev != state.settingsRev: state.saveSettings()
  if state.layoutSaved != state.layoutRev: state.saveArrangement()
  state.writeLog()
  state.disk.stop()

# --------------------------------------------------------------- reading --

func log*(state: AppState): lent MessageLog {.inline.} =
  ## The message log.
  state.log

func selection*(state: AppState): lent Selection {.inline.} =
  ## The trace under the cursor, the selected traces, the gather on show.
  state.selection

func panels*(state: AppState): lent seq[Panel] {.inline.} =
  ## The trace panels, `MainPanel` first.
  state.panels

func sessions*(state: AppState): lent seq[Session] {.inline.} =
  ## The open files, in the order they were opened.
  state.sessions

func jobs*(state: AppState): lent Jobs {.inline.} =
  ## The jobs, for the Jobs window and the status bar (`list`, `info`).
  state.jobs

func fileList*(state: AppState): lent FileList {.inline.} =
  ## The file list: the files of the folder (or the files) listed last, and
  ## the one the main panel shows.
  state.files

func shownFile*(state: AppState; panelIndex: int): int =
  ## The index in `sessions` of the file `panels[panelIndex]` shows; -1 for
  ## none.
  template p: untyped = state.panels[panelIndex]
  result = -1
  if p.layers.len > 0 and p.layers[0].source.kind == lsRecord:
    for i, s in state.sessions:
      if s.id == p.layers[0].source.file: return i

func indexCache*(state: AppState): lent string {.inline.} =
  ## The folder of parseSEG's index caches; "" for none.
  state.indexCache

func settings*(state: AppState): lent Settings {.inline.} =
  ## The user's settings (`core/settings`).
  state.settings

func defaultSettings*(state: AppState): lent Settings {.inline.} =
  ## What a reset of the settings goes back to.
  state.defaults

func tiles*(state: AppState; panelIndex: int): lent seq[Tile] {.inline.} =
  ## The tiles kept for `panels[panelIndex]`, oldest first: draw them in
  ## that order. Each has its own `id`, never reused.
  state.tiles[panelIndex]

func sorting*(state: AppState; panelIndex: int): bool =
  ## Whether `panels[panelIndex]`'s traces were given a new order since it
  ## was shown and no tile in that order has come yet: the plot still shows
  ## the old order.
  template p: untyped = state.panels[panelIndex]
  template t: untyped = state.tiles[panelIndex]
  p.orderGen > p.sourceGen and (t.len == 0 or t[^1].request.gen < p.orderGen)

func findPanel*(state: AppState; id: PanelId): int =
  ## The index of panel `id` in `panels`; -1 when there is none.
  for i, p in state.panels:
    if p.id == id: return i
  -1

func findSession*(state: AppState; id: SessionId): int =
  ## The index of open file `id` in `sessions`; -1 when it is not open.
  for i, s in state.sessions:
    if s.id == id: return i
  -1

func findTrace*(state: AppState; trace: int): int =
  ## The index in `sessions` of the file that holds survey-wide trace id
  ## `trace`; -1 when no open file does.
  for i, s in state.sessions:
    if trace in s: return i
  -1

proc missing(what: string) {.noinline, noreturn.} =
  raise newException(KeyError, what)

func panel*(state: AppState; id: PanelId): lent Panel =
  ## Panel `id`. Raises `KeyError` when there is none.
  let i = state.findPanel(id)
  if i < 0: missing($id & " does not exist")
  state.panels[i]

func session*(state: AppState; id: SessionId): lent Session =
  ## Open file `id`. Raises `KeyError` when it is not open.
  let i = state.findSession(id)
  if i < 0: missing($id & " is not open")
  state.sessions[i]

proc mailbox(state: AppState): Poster =
  ## A handle to the inbox, as workers have (tests import this module with
  ## `{.all.}` to post as a reader would).
  state.inbox.poster

proc report*(state: var AppState; severity: Severity; source, text: string) =
  ## Adds a message to the log: for what the frontend itself has to say (a
  ## dialog that could not be shown, a slow frame).
  state.log.add(severity, source, text)

# ---------------------------------------------------------------- helpers --

func plural(n: int; word: string): string =
  $n & " " & word & (if n == 1: "" else: "s")

proc canonical(path: string): string =
  ## `path` made absolute and normalized ("./a.sgy", "data/../a.sgy" and the
  ## full path name one file), without touching the disk: jobs compare files
  ## by these strings. As given, normalized, when there is no current
  ## directory to resolve it against.
  try:
    absolutePath(path).normalizedPath
  except OSError, ValueError:
    path.normalizedPath

proc ignore(state: var AppState; cmd: Command; why: string) =
  state.log.add(sevWarning, "commands", "Ignored \"" & $cmd.kind & "\": " & why & ".")

proc change(state: var AppState; s: sink Settings) =
  ## Makes `s` the settings, noting a change when it is one (as saved:
  ## a value that is not a number equals itself).
  if settingsDocument(s) != settingsDocument(state.settings):
    state.settings = s
    inc state.settingsRev
    state.changedAt = getMonoTime()

proc reader(state: var AppState; k: int): lent PanelReader =
  ## The reader of `panels[k]`, started when first needed.
  if state.readers[k].isNil:
    state.readers[k] = newPanelReader(state.panels[k].id, state.inbox.poster,
      state.jobs.holdRelease)
  state.readers[k]

proc newSource(state: var AppState; k: int) =
  ## Forgets what `panels[k]` knew about its traces: its layer 0 now shows
  ## something else, or nothing. Tells its reader.
  template p: untyped = state.panels[k]
  # The next gather or file is shown at the same scales (`carried`); a panel
  # that showed nothing yet, or shows nothing now, fits the new one.
  if p.layers.len == 0:
    p.carry = Viewport()
  elif p.laidOut and p.layout.traces > 0 and p.view.traces.width > 0:
    p.carry = p.view
    p.carryLayout = p.layout
  inc p.requestGen
  p.sourceGen = p.requestGen
  p.layout = PanelLayout()
  p.known = {}
  p.kind = gkUnknown
  p.pending = ReadRequest()
  p.level = Level()
  p.viewLevel = Level()
  p.back.setLen 0
  inc p.revision
  state.tiles[k].setLen 0
  var src = ReaderSource(gen: p.sourceGen)
  var busy = false
  if p.layers.len > 0 and p.layers[0].source.kind == lsRecord:
    let i = state.findSession(p.layers[0].source.file)
    let g = p.layers[0].source.gather
    if i >= 0 and g in 0 ..< state.sessions[i].gathers.len:
      let s = state.sessions[i]
      p.kind = s.gathers[g].kind
      if state.jobs.hold(s.path):
        src = ReaderSource(gen: p.sourceGen, file: s.filePtr, path: s.path,
          traces: s.gathers[g].traces, filter: p.layers[0].filter, order: p.layers[0].order)
      else:
        busy = true
        state.log.add(sevWarning, s.name, s.name & " is busy (a job needs it to itself), " &
          "so it is not shown.")
  # Nothing to read (no file, or a file with no traces): the reader posts no
  # layout, so the empty one stands, and the panel says so instead of waiting.
  p.laidOut = src.file.isNil and not busy
  if not src.file.isNil or not state.readers[k].isNil:
    state.reader(k).show(src)

proc show(state: var AppState; panel: PanelId; file: SessionId; gather: int) =
  ## Points layer 0 of `panel` at `gather` of `file`, keeping its filter,
  ## pipeline and display; makes the layer when the panel has none.
  let k = state.findPanel(panel)
  if k < 0: return
  if state.panels[k].layers.len == 0: # a new plot: as the user last had one
    var layer = recordLayer(file, gather)
    layer.display = state.settings.plot.display
    layer.order = state.settings.plot.order
    state.panels[k].layers.add layer
    state.panels[k].header = state.settings.plot.header
  else:
    state.panels[k].layers[0].source = LayerSource(kind: lsRecord, file: file, gather: gather)
  state.newSource(k)
  state.selection.activeGather = GatherRef(file: file, gather: gather)
  inc state.selection.revision

func gatherKind(state: AppState; layer: Layer): GatherKind =
  ## The kind of the gather `layer` shows; unknown for none.
  result = gkUnknown
  if layer.source.kind == lsRecord:
    let i = state.findSession(layer.source.file)
    if i >= 0 and layer.source.gather in 0 ..< state.sessions[i].gathers.len:
      result = state.sessions[i].gathers[layer.source.gather].kind

proc requestView(state: var AppState; k: int) =
  ## Asks `panels[k]`'s reader for its view, unless the request sent last
  ## already covers it.
  template p: untyped = state.panels[k]
  if p.layers.len == 0 or p.layout.traces == 0 or state.readers[k].isNil: return
  let flow = p.layers[0].displayPipeline(state.gatherKind(p.layers[0]))
  let margin = displayMargin(flow, p.layout.dtMs)
  if p.pending.gen == p.requestGen and p.pending.covers(p.layout, p.view, margin): return
  var req = requestFor(p.layout, p.view, margin)
  if req.isEmpty: return
  inc p.requestGen
  req.gen = p.requestGen
  p.pending = req
  state.readers[k].request ReaderRequest(read: req, fields: p.shownFields, flow: flow,
    clipPercentile: p.layers[0].display.clipPercentile)

proc remember(state: var AppState; k: int) =
  ## Keeps `panels[k]`'s view for back, unless it is the one kept last or
  ## the panel shows nothing yet.
  template p: untyped = state.panels[k]
  if p.laidOut and p.view.traces.width > 0 and
      (p.back.len == 0 or not p.back[^1].sameSpans(p.view)):
    p.back.add p.view
    if p.back.len > MaxBack: p.back.delete(0)

proc refetch(state: var AppState; k: int; keepTiles: bool) =
  ## Drops the request sent last and asks again for `panels[k]`'s view:
  ## what a tile holds has changed.
  template p: untyped = state.panels[k]
  inc p.requestGen
  p.pending = ReadRequest()
  if not keepTiles:
    state.tiles[k].setLen 0
    p.level = Level()
    p.viewLevel = Level()
  inc p.revision
  state.requestView(k)

proc reorder(state: var AppState; k: int) =
  ## Tells `panels[k]`'s reader its layer 0's new order and asks again for
  ## the view, which stays as it is. The tiles in the old order are drawn
  ## until the first one in the new order comes (`drainInbox`), so the plot
  ## never goes blank; each tile names its own traces, so what the pick and
  ## the display header say always matches what is drawn.
  template p: untyped = state.panels[k]
  inc p.requestGen
  p.orderGen = p.requestGen
  p.pending = ReadRequest()
  inc p.revision
  if not state.readers[k].isNil:
    state.readers[k].sortBy(p.orderGen, p.layers[0].order)
  state.requestView(k)

func usable(x: float64): bool {.inline.} = x > 0 and x < Inf

proc settleGain(state: var AppState; k: int) =
  ## After a change of display, view or tiles of `panels[k]`: Fixed takes
  ## its amplitude from the data shown when it has none yet, and Float
  ## takes its level from the data now in view (keeping the one before
  ## when no tile holds any of it yet).
  template p: untyped = state.panels[k]
  if p.layers.len == 0: return
  template d: untyped = state.panels[k].layers[0].display
  case d.effectiveGain(p.kind)
  of dgFixed:
    if not usable(d.fixedClip) and usable(p.level.clip):
      d.fixedClip = p.level.clip
      inc p.revision
  of dgFloat:
    var values: seq[float32]
    for i in countdown(state.tiles[k].high, 0): # the newest tile that meets the view
      if values.len == 0:
        state.tiles[k][i].valuesInView(p.view, FloatValues, values)
    if values.len > 0:
      let level = levelOf(values, d.clipPercentile, state.scratch)
      if usable(level.clip):
        p.viewLevel = level
        inc p.revision
  else: discard

proc choose(state: var AppState; path: string) =
  ## Marks `path` as the file the main panel shows (or is opening).
  if state.files.chosen != path:
    state.files.chosen = path
    inc state.files.revision

proc chooseShown(state: var AppState) =
  ## Marks the file the main panel shows as chosen again (an open for it
  ## failed or was cancelled).
  let i = state.shownFile(state.findPanel(MainPanel))
  state.choose(if i >= 0: state.sessions[i].path else: "")

proc closeSession(state: var AppState; i: int; quiet = false) =
  ## Takes open file `i` out of every view at once, cancels the jobs that use
  ## it, and closes it once none does (after its close job, on this thread);
  ## `quiet` logs nothing when it is closed.
  var s = move state.sessions[i]
  state.sessions.delete(i)
  for job in state.jobs.list:
    if job.state in {jsQueued, jsRunning} and
        (s.path in job.spec.reads or s.path in job.spec.exclusive):
      discard state.jobs.cancel(job.id)
  state.selection.forget(s.id, s.traceIds)
  for k in 0 ..< state.panels.len:
    let before = state.panels[k].layers.len
    state.panels[k].layers.keepItIf(not it.shows(s.id))
    if state.panels[k].layers.len != before:
      state.newSource(k) # the reader lets go of the file, then the close may run
  # Not cancellable: the file must not be released while a job still reads it.
  let job = state.jobs.submit(JobSpec(title: "Close " & s.name, lane: jlInteractive,
    exclusive: @[s.path], cancellable: false), closeWork())
  if state.files.chosen == s.path and state.shownFile(state.findPanel(MainPanel)) < 0:
    state.choose("")
  state.closing.add Pending(job: job, path: s.path, session: s, quiet: quiet)

proc failed(state: var AppState; path: string) =
  ## Notes that `path` of the file list could not be shown.
  if path notin state.files.failed:
    state.files.failed.add path
    inc state.files.revision

proc showReplacing(state: var AppState; k: int; file: SessionId; gather: int) =
  ## Shows `gather` of `file` in `panels[k]`, in place of what it showed,
  ## and closes the file it showed when no other panel shows it: stepping
  ## through a folder keeps one file open, not every file seen.
  let shown = state.shownFile(k)
  let old = if shown >= 0: state.sessions[shown].id else: NoSession
  state.show(state.panels[k].id, file, gather)
  if old != NoSession and not (old == file) and
      not state.panels.anyIt(it.layers.anyIt(it.shows(old))):
    state.closeSession(state.findSession(old), quiet = true)

proc adopt(state: var AppState; s: sink Session; job: JobId) =
  ## Takes in a file an open job opened, and shows its first gather in the
  ## panel the open was for (the main panel unless `ckShowFile` named
  ## another); drops it when no longer wanted.
  var panel = MainPanel
  var replacing = false # `ckShowFile`: in place of the file the panel shows
  for p in state.opening:
    if p.job == job:
      if p.unwanted: return # another file was chosen meanwhile: closed here
      if p.panel != NoPanel: (panel, replacing) = (p.panel, true)
  if s.file.kind == skUnknown:
    state.log.add(s.file.log, s.name)
    state.log.add(sevError, s.name, s.name & " is not a SEG-Y, SEG-D or SEG-2 file, " &
      "so it was not opened.")
    if panel == MainPanel:
      state.failed(s.path)
      state.chooseShown()
    return # `s` is closed here, on the UI thread: nothing else has it
  let id = SessionId(state.nextFile)
  inc state.nextFile
  s.register(id, state.nextBase)
  state.nextBase += s.len
  state.log.add(s.file.log, s.name)
  state.log.add(sevInfo, "open", "Opened " & s.name & ": " & plural(s.len, "trace") &
    " in " & plural(s.gathers.len, "gather") &
    (if s.file.fromCache: " (index from the cache)." else: "."))
  let gather = if s.gathers.len > 0: 0 else: -1
  var st = state.settings
  st.recentFiles.addRecent(s.path, MaxRecent)
  st.recentFolders.addRecent(s.path.parentDir, MaxRecent)
  state.change st
  let path = s.path
  state.sessions.add s
  let k = state.findPanel(panel)
  if replacing and k >= 0: state.showReplacing(k, id, gather)
  else: state.show(MainPanel, id, gather)
  if panel == MainPanel: state.choose(path)

proc endOpening(state: var AppState; i: int; how: JobState; error = "") =
  ## Says how open job `opening[i]` ended, and forgets it. An open no longer
  ## wanted ends quietly.
  let o = state.opening[i]
  let p = o.path
  let name = p.extractFilename
  state.opening.delete(i)
  if o.unwanted: return
  case how
  of jsFailed: state.log.add(sevError, name, "Cannot open " & p & ": " & error)
  of jsCancelled: state.log.add(sevInfo, name, "Opening " & name & " was cancelled.")
  else: discard # done: `adopt` took the file
  if how in {jsFailed, jsCancelled} and o.panel == MainPanel:
    if how == jsFailed: state.failed(p)
    state.chooseShown()

proc onFinished(state: var AppState; job: JobInfo) =
  ## Says how a job ended, and lets go of what the state kept for it.
  for i, p in state.opening:
    if p.job == job.id:
      state.endOpening(i, job.state, job.error)
      return
  for i, p in state.closing:
    if p.job == job.id:
      let name = p.path.extractFilename
      if job.state == jsDone and not p.quiet: state.log.add(sevInfo, name, "Closed " & name & ".")
      state.closing.delete(i) # the file is closed here, on the UI thread
      return
  let old = state.oldScans.find(job.id)
  if old >= 0: # replaced by a newer listing: nothing to say
    state.oldScans.delete(old)
    return
  if job.id == state.files.job:
    state.files.scanning = false
    state.files.job = NoJob
    case job.state
    of jsFailed:
      state.files.error = job.error
      state.log.add(sevError, "files", "Cannot list " & state.files.title & ": " & job.error &
        ".")
    of jsCancelled: state.files.error = "the listing was stopped before the end"
    else: discard
    inc state.files.revision
    return
  case job.state
  of jsFailed: state.log.add(sevError, "jobs", job.spec.title & " failed: " & job.error)
  of jsCancelled: state.log.add(sevInfo, "jobs", job.spec.title & " was cancelled.")
  of jsDone:
    if job.spec.lane == jlBackground:
      state.log.add(sevInfo, "jobs", job.spec.title & " is done.")
  of jsQueued, jsRunning: discard

proc showPath(state: var AppState; k: int; path: string) =
  ## Shows the file at `path` (canonical) in `panels[k]`, in place of the
  ## one it shows: at once when it is open, else once an open job opened it.
  ## An open started earlier for this panel and another file is no longer
  ## wanted: it is cancelled, and dropped if it comes all the same.
  let panel = state.panels[k].id
  for o in state.opening.mitems:
    if o.panel == panel and o.path != path and not o.unwanted:
      o.unwanted = true
      discard state.jobs.cancel(o.job) # queued: never runs; running: asked to stop
  if panel == MainPanel: state.choose(path)
  var i = -1
  for j, s in state.sessions:
    if s.path == path: i = j
  if i >= 0:
    if state.shownFile(k) != i: state.showReplacing(k, state.sessions[i].id, 0)
  else:
    var o = -1
    for j, p in state.opening:
      if p.path == path and not p.unwanted: o = j
    if o >= 0: state.opening[o].panel = panel
    else:
      let job = state.jobs.submit(JobSpec(title: "Open " & path.extractFilename,
        lane: jlInteractive, reads: @[path]), openWork(path, state.inbox.poster,
        indexCacheFile(state.indexCache, path)))
      state.opening.add Pending(job: job, path: path, panel: panel)

proc startListing(state: var AppState; paths: seq[string]; title, folder: string) =
  ## Lists the files `paths` (canonical) name in the file list, in place of
  ## what it listed: a scan on the background lane (`scanWork`). The file
  ## chosen stays chosen.
  if state.files.job != NoJob:
    discard state.jobs.cancel(state.files.job)
    state.oldScans.add state.files.job # it ends quietly
  let gen = state.files.gen + 1
  state.files = FileList(title: title, folder: folder, asked: paths, scanning: true, gen: gen,
    chosen: state.files.chosen, revision: state.files.revision + 1)
  state.files.job = state.jobs.submit(JobSpec(title: "List the files in " &
    (if folder.len > 0: folder.extractFilename else: title), lane: jlBackground),
    scanWork(gen, paths, state.inbox.poster))

proc takeListed(state: var AppState; m: sink Msg) =
  ## What a scan found for the file list; shows the first file found (or the
  ## file named) when asked to.
  if m.listGen != state.files.gen: return # a listing replaced since
  template f: untyped = state.files
  if m.listFolder.len > 0:
    f.folder = m.listFolder
    f.title = m.listFolder
    var st = state.settings
    st.recentFolders.addRecent(m.listFolder, MaxRecent)
    state.change st
  f.merge(m.listed)
  f.others += m.others
  f.unreadable += m.unreadable
  if m.listDone: f.scanning = false
  inc f.revision
  if state.showFound != NoPanel:
    let target = if m.listChosen.len > 0: m.listChosen
                 elif f.entries.len > 0: f.entries[0].path
                 else: ""
    if target.len > 0 or m.listDone:
      let k = state.findPanel(state.showFound)
      state.showFound = NoPanel
      if k >= 0 and target.len > 0: state.showPath(k, target)

proc goToGather(state: var AppState; cmd: Command) =
  ## Shows gather `cmd.gather` of the file in layer 0 of `cmd.panel`.
  let k = state.findPanel(cmd.panel)
  if k < 0:
    state.ignore(cmd, $cmd.panel & " does not exist")
    return
  let shown = if state.panels[k].layers.len > 0: state.panels[k].layers[0].source
              else: LayerSource(kind: lsGenerated)
  let i = if shown.kind == lsRecord: state.findSession(shown.file) else: -1
  if i < 0:
    state.ignore(cmd, $cmd.panel & " shows no file")
  elif cmd.gather notin 0 ..< state.sessions[i].gathers.len:
    let s = state.sessions[i]
    state.ignore(cmd, "there is no gather " & $cmd.gather & ": " & s.name & " has " &
      plural(s.gathers.len, "gather") & ", from 0")
  elif cmd.gather != shown.gather:
    state.show(cmd.panel, shown.file, cmd.gather)

# ---------------------------------------------------------------- changes --

proc apply*(state: var AppState; cmd: Command) =
  ## Carries out `cmd`. Anything slow it starts runs as a job; `drainInbox`
  ## takes in the result.
  assertUiThread()
  case cmd.kind
  of ckOpen:
    if cmd.paths.len == 0: state.ignore(cmd, "no file was named")
    for given in cmd.paths:
      if given.len == 0:
        state.ignore(cmd, "a file name was empty")
        continue
      let path = canonical(given)
      let name = path.extractFilename
      if state.sessions.anyIt(it.path == path):
        state.log.add(sevInfo, name, name & " is already open.")
      elif state.opening.anyIt(it.path == path and not it.unwanted):
        state.log.add(sevInfo, name, name & " is already being opened.")
      else:
        let job = state.jobs.submit(JobSpec(title: "Open " & name, lane: jlInteractive,
          reads: @[path]), openWork(path, state.inbox.poster,
          indexCacheFile(state.indexCache, path)))
        state.opening.add Pending(job: job, path: path)
  of ckBrowse:
    var paths: seq[string]
    for p in cmd.paths:
      if p.len > 0: paths.add canonical(p)
    if paths.len == 0: state.ignore(cmd, "no file or folder was named")
    else:
      # A copy: as an argument beside `paths`, `paths[0]` would be moved.
      let title = if paths.len == 1: paths[0] else: $paths.len & " chosen files"
      state.startListing(paths, title, "")
      state.showFound = if cmd.showFirst: MainPanel else: NoPanel
  of ckShowFile:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif cmd.path.len == 0: state.ignore(cmd, "no file was named")
    else:
      let path = canonical(cmd.path)
      if cmd.panel == MainPanel: state.showFound = NoPanel # the user chose
      state.showPath(k, path)
      let folder = path.parentDir
      if cmd.listFolder and state.files.folder != folder:
        state.startListing(@[folder], folder, folder)
  of ckClose:
    let i = state.findSession(cmd.file)
    if i < 0: state.ignore(cmd, $cmd.file & " is not open")
    else: state.closeSession(i)
  of ckCancelJob:
    let job = state.jobs.info(cmd.job)
    if job.isNone: state.ignore(cmd, $cmd.job & " is not listed")
    elif state.jobs.cancel(cmd.job): discard
    elif job.get.spec.cancellable or job.get.state notin {jsQueued, jsRunning}:
      state.ignore(cmd, $cmd.job & " has finished")
    else: state.ignore(cmd, "\"" & job.get.spec.title & "\" cannot be cancelled")
  of ckReorderJob:
    if not state.jobs.reorder(cmd.reordered, cmd.position):
      state.ignore(cmd, $cmd.reordered & " is not queued")
  of ckRemoveJob:
    let job = state.jobs.info(cmd.job)
    if job.isNone: state.ignore(cmd, $cmd.job & " is not listed")
    elif state.jobs.remove(cmd.job):
      # A queued job never runs now, so it never finishes either: an open
      # left waiting would refuse every later open of its file.
      if job.get.state == jsQueued:
        for i, p in state.opening:
          if p.job == cmd.job:
            state.endOpening(i, jsCancelled)
            break
    elif job.get.state in {jsQueued, jsRunning} and not job.get.spec.cancellable:
      state.ignore(cmd, "\"" & job.get.spec.title & "\" cannot be removed before it has run")
    else: state.ignore(cmd, $cmd.job & " is running; cancel it first")
  of ckGather:
    state.goToGather(cmd)
  of ckView:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    else:
      # Never a view past the data, whoever asks (the frontend keeps its
      # own views inside already).
      var v = cmd.view
      if state.panels[k].layout.traces > 0:
        v = kept(v, limitsOf(state.panels[k].layout))
      if v != state.panels[k].view:
        if cmd.remember: state.remember(k)
        state.panels[k].view = v
        state.requestView(k)
        state.settleGain(k)
  of ckBack:
    # Nothing to go back to is not a mistake: the control is only disabled.
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].back.len > 0:
      template p: untyped = state.panels[k]
      var v = p.back.pop()
      v.columns = p.view.columns # the plot's size is its own
      v.rows = p.view.rows
      p.view = v
      inc p.jumps
      inc p.revision
      state.requestView(k)
      state.settleGain(k)
  of ckSettings:
    let (s, dropped) = cleaned(cmd.settings)
    if dropped > 0:
      state.log.add(sevWarning, "settings", $dropped & " of the settings given could not " &
        "be used (a calibration that is not a positive number, an entry given twice, a " &
        "sort preset without a name or keys) and were left out.")
    state.change s
  of ckExportSettings:
    if cmd.docPath.len == 0: state.ignore(cmd, "no file was named")
    else:
      state.diskIo.replace(cmd.docPath, settingsDocument(state.settings),
        "the exported settings", done = "Settings exported to " & cmd.docPath & ".")
  of ckImportSettings:
    if cmd.docPath.len == 0: state.ignore(cmd, "no file was named")
    else: state.diskIo.read(cmd.docPath, rpImportSettings, MaxNifBytes)
  of ckLayout:
    if cmd.arrangement != state.arrangement:
      state.arrangement = cmd.arrangement
      inc state.layoutRev
      state.layoutAt = getMonoTime()
  of ckSaveLayout:
    let why = layoutNameProblem(cmd.layoutName)
    if why.len > 0: state.ignore(cmd, why)
    elif state.configDir.len == 0: state.ignore(cmd, "layouts are not kept in this run")
    elif state.arrangement.len == 0: state.ignore(cmd, "the window layout is not known yet")
    else: state.saveNamed(cmd.layoutName.strip, state.arrangement)
  of ckLoadLayout, ckImportLayout:
    if cmd.docPath.len == 0: state.ignore(cmd, "no file was named")
    else:
      state.diskIo.read(cmd.docPath, (if cmd.kind == ckLoadLayout: rpLoadLayout
        else: rpImportLayout), MaxNifBytes)
  of ckExportLayout:
    if cmd.docPath.len == 0: state.ignore(cmd, "no file was named")
    elif state.arrangement.len == 0: state.ignore(cmd, "the window layout is not known yet")
    else:
      state.diskIo.replace(cmd.docPath, layoutDocument(Layout(
        name: cmd.docPath.splitFile.name, imgui: state.arrangement)), "the exported layout",
        done = "Layout exported to " & cmd.docPath & ".")
  of ckResetSettings:
    var s = state.defaults
    s.recentFiles = state.settings.recentFiles # memory, not preferences
    s.recentFolders = state.settings.recentFolders
    s.window = state.settings.window
    let file = state.settingsFile
    if file.len > 0:
      let backup = backupPath(file)
      state.diskIo.replace(backup, settingsDocument(state.settings), "a copy of the settings")
      state.log.add(sevInfo, "settings", "Settings reset to their defaults; the settings " &
        "before are kept in " & backup & ".")
    else:
      state.log.add(sevInfo, "settings", "Settings reset to their defaults.")
    state.change s
  of ckDisplay:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].layers.len == 0: state.ignore(cmd, $cmd.panel & " shows nothing")
    else:
      let was = state.panels[k].layers[0].display
      let d = cmd.display.withGainDb(cmd.display.gainDb)
      state.panels[k].layers[0].display = d
      inc state.panels[k].revision
      var s = state.settings
      s.plot.display = remembered(d)
      state.change s
      # Only a change of the samples reads again: the gain amount, a Fixed
      # amplitude and a type that is a scale alone change only the drawing.
      if not d.sameProcessing(was, state.panels[k].kind):
        state.refetch(k, keepTiles = false)
      state.settleGain(k)
  of ckHeader:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif not cmd.header.auto and cmd.header.fields.len == 0:
      state.ignore(cmd, "a display header needs at least one field")
    else:
      state.panels[k].header = cmd.header
      var s = state.settings
      s.plot.header = cmd.header
      state.change s
      state.refetch(k, keepTiles = true)
  of ckSort:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].layers.len == 0: state.ignore(cmd, $cmd.panel & " shows nothing")
    elif cmd.order != state.panels[k].layers[0].order:
      state.panels[k].layers[0].order = cmd.order
      var s = state.settings
      s.plot.order = cmd.order
      if cmd.order.len > 0 and presetOf(cmd.order, s.sortPresets) < 0:
        s.customOrder = cmd.order # the user's own keys, offered again
      state.change s
      state.reorder(k)
  of ckHover:
    # The UI sends a hover on every move, so one on a trace of a file closed
    # in the same frame is no mistake the user could act on: it clears the
    # hover, and says nothing.
    let known = cmd.trace >= 0 and state.findTrace(cmd.trace) >= 0
    discard state.selection.setHover(if known: cmd.trace else: -1)
  of ckSelect:
    var known: seq[int]
    for t in cmd.traces:
      if state.findTrace(t) >= 0: known.add t
    if known.len < cmd.traces.len:
      state.ignore(cmd, plural(cmd.traces.len - known.len, "trace") & " of " &
        $cmd.traces.len & " are in no open file")
    if known.len > 0 or cmd.mode == smReplace:
      state.selection.select(known, cmd.mode)
  of ckClearSelection:
    state.selection.clear()

proc takeLayout(state: var AppState; m: Msg) =
  ## A layout the disk thread read: shown, and with `rpImportLayout` kept
  ## among the user's layouts under its name.
  let file = m.readPath.extractFilename
  if m.readError.len > 0:
    state.log.add(sevError, "layouts", "Cannot load the layout in " & m.readPath & ": " &
      m.readError & ".")
    return
  var problems: seq[string]
  var l: Layout
  try:
    l = readLayout(m.content, file, problems)
  except NifError as e:
    state.log.add(sevError, "layouts", "Cannot load the layout: " & e.msg & ".")
    return
  for p in problems: state.log.add(sevWarning, "layouts", p)
  if l.name.len == 0 or layoutNameProblem(l.name).len > 0: l.name = m.readPath.splitFile.name
  if layoutNameProblem(l.name).len > 0: l.name = "Imported"
  state.loaded = l
  inc state.loads
  state.log.add(sevInfo, "layouts", "Layout \"" & l.name & "\" loaded.")
  if m.purpose == rpImportLayout and state.configDir.len > 0:
    var name = l.name
    var n = 2
    while state.layoutList.anyIt(not it.preset and it.name.toLowerAscii == name.toLowerAscii):
      name = l.name & " " & $n
      inc n
    state.saveNamed(name, l.imgui)

proc takeIn(state: var AppState; m: Msg) =
  ## A document the disk thread read: settings to import, a layout to load.
  let name = m.readPath.extractFilename
  case m.purpose
  of rpLoadLayout, rpImportLayout: state.takeLayout(m)
  of rpImportSettings:
    if m.readError.len > 0:
      state.log.add(sevError, "settings", "Cannot import the settings in " & m.readPath &
        ": " & m.readError & ".")
    else:
      var problems: seq[string]
      try:
        let s = readSettings(m.content, name, state.settings, problems)
        for p in problems: state.log.add(sevWarning, "settings", p)
        state.change cleaned(s)[0]
        state.log.add(sevInfo, "settings", "Settings imported from " & m.readPath &
          (if problems.len > 0: ", except what is said above." else: "."))
      except NifError as e:
        state.log.add(sevError, "settings", "Cannot import the settings: " & e.msg &
          ". Nothing was changed.")

proc drainInbox*(state: var AppState): bool =
  ## Takes in what the workers posted and how the jobs ended, in that order
  ## per job. Call it once per frame; it never waits. True when anything
  ## came in.
  assertUiThread()
  # Finished jobs first: a job posts before it finishes, so every message of
  # a job seen finishing here is in the mail drained next.
  let finished = state.jobs.takeFinished()
  state.inbox.drainInto(state.mail)
  result = finished.len > 0 or state.mail.len > 0
  for m in state.mail.mitems:
    case m.kind
    of mkOpened: state.adopt(move m.session, m.job)
    of mkLog: state.log.add(move m.entry)
    of mkRead: state.takeIn(m)
    of mkListed: state.takeListed(move m)
    of mkLayout:
      let k = state.findPanel(m.panel)
      if k >= 0 and m.sourceGen == state.panels[k].sourceGen:
        template p: untyped = state.panels[k]
        p.layout = m.layout
        p.laidOut = true
        p.known = m.known
        # The next gather at the scales of the one before; a first one fits.
        p.view = if p.carry.traces.width > 0:
            carried(Viewport(traces: p.carry.traces, timeMs: p.carry.timeMs,
              columns: p.view.columns, rows: p.view.rows), limitsOf(p.carryLayout),
              limitsOf(p.layout))
          else: fitAll(p.layout, p.view.columns, p.view.rows)
        p.carry = Viewport()
        inc p.jumps
        inc p.revision
        state.requestView(k)
    of mkTile:
      let k = state.findPanel(m.tile.panel)
      if k >= 0 and m.tile.request.gen == state.panels[k].requestGen:
        m.tile.id = state.nextTile
        inc state.nextTile
        if state.panels[k].level.clip.isNaN: state.panels[k].level = m.tile.level
        # The first tile in a new order replaces every tile in the old one.
        let orderGen = state.panels[k].orderGen
        state.tiles[k].keepItIf(it.request.gen >= orderGen)
        state.tiles[k].add move m.tile
        if state.tiles[k].len > MaxTiles: state.tiles[k].delete(0)
        inc state.panels[k].revision
        state.settleGain(k)
  state.mail.setLen 0
  for job in finished:
    state.onFinished(job)
